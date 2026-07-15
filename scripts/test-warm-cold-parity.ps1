param(
  [string]$Ix = (Join-Path $PSScriptRoot "..\zig-out\bin\ix-zig.exe"),
  [int]$Rounds = 7
)

$ErrorActionPreference = "Stop"
$Ix = (Resolve-Path $Ix).Path
$tempBase = [System.IO.Path]::GetTempPath()
$sessionRoot = Join-Path $tempBase ("ix-warm-cold-parity-" + [guid]::NewGuid().ToString("N"))
$root = Join-Path $sessionRoot "corpus"
$stateRoot = Join-Path $sessionRoot "state"
$indexdStdout = Join-Path $sessionRoot "indexd.stdout.log"
$indexdStderr = Join-Path $sessionRoot "indexd.stderr.log"
[void][System.IO.Directory]::CreateDirectory($root)
[void][System.IO.Directory]::CreateDirectory($stateRoot)
$indexd = $null
$succeeded = $false
$previousStateDir = $env:IX_STATE_DIR
$env:IX_STATE_DIR = $stateRoot

function Assert-True([bool]$Condition, [string]$Message) {
  if (-not $Condition) { throw $Message }
}

function Search([string]$Expression, [bool]$Warm) {
  $previous = $env:IX_INDEX
  try {
    $env:IX_INDEX = if ($Warm) { "1" } else { "0" }
    $raw = & $Ix search $Expression $root --format json-compact
    Assert-True ($LASTEXITCODE -eq 0) "search failed for $Expression warm=$Warm"
    return ($raw | ConvertFrom-Json)
  } finally {
    if ($null -eq $previous) { Remove-Item Env:IX_INDEX -ErrorAction SilentlyContinue } else { $env:IX_INDEX = $previous }
  }
}

function Hit-Keys($Envelope) {
  $keys = [System.Collections.Generic.List[string]]::new()
  foreach ($property in $Envelope.hits.PSObject.Properties) {
    foreach ($hit in $property.Value) {
      $hitIdentity = $hit | Select-Object l, c, n, p, w | ConvertTo-Json -Compress -Depth 4
      $keys.Add("$($property.Name)|$hitIdentity")
    }
  }
  return @($keys | Sort-Object)
}

function Median([double[]]$Values) {
  $sorted = @($Values | Sort-Object)
  return $sorted[[int][math]::Floor($sorted.Count / 2)]
}

function Live-IndexdPids {
  $status = (& $Ix process status --json | ConvertFrom-Json)
  if ($LASTEXITCODE -ne 0) { return @() }
  return @($status.entries | Where-Object { $_.status -eq "live" } | ForEach-Object { [int]$_.pid } | Sort-Object -Unique)
}

function Wait-IndexdReady([int]$TimeoutSeconds = 30) {
  $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
  do {
    if ($indexd.HasExited) {
      $stdout = if (Test-Path $indexdStdout) { "$(Get-Content $indexdStdout -Raw)".Trim() } else { "" }
      $stderr = if (Test-Path $indexdStderr) { "$(Get-Content $indexdStderr -Raw)".Trim() } else { "" }
      throw "indexd exited during bootstrap (code=$($indexd.ExitCode), stdout='$stdout', stderr='$stderr')"
    }
    $liveMarker = Get-ChildItem -LiteralPath $stateRoot -Filter "index.live" -File -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($null -ne $liveMarker) { return }
    Start-Sleep -Milliseconds 50
  } while ([DateTime]::UtcNow -lt $deadline)
  throw "indexd did not publish a live marker within $TimeoutSeconds seconds"
}

function Wait-Warm([string]$Expression, [int]$TimeoutSeconds = 30) {
  $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
  do {
    # Background/foreground watch owners deliberately retire after observing a
    # mutation. The next indexed search launches the replacement generation.
    $result = Search $Expression $true
    if ($result.route.lane -eq "warm") { return $result }
    Start-Sleep -Milliseconds 100
  } while ([DateTime]::UtcNow -lt $deadline)
  throw "warm lane did not become ready within $TimeoutSeconds seconds"
}

try {
  for ($index = 1; $index -le 1000; $index++) {
    $body = if ($index % 10 -eq 0) { "alpha needle-$index`nsecond needle-$index`n" } else { "alpha filler-$index`n" }
    [System.IO.File]::WriteAllText((Join-Path $root ("f$index.txt")), $body, [System.Text.UTF8Encoding]::new($false))
  }

  $indexd = Start-Process -FilePath $Ix -ArgumentList @("__ix_indexd", $root, "--foreground") -WindowStyle Hidden -PassThru `
    -RedirectStandardOutput $indexdStdout -RedirectStandardError $indexdStderr
  Wait-IndexdReady
  $null = Wait-Warm "lit:needle-"

  foreach ($expression in @("lit:needle-", "lit:not-present-anywhere")) {
    $cold = Search $expression $false
    $warm = Search $expression $true
    Assert-True ($cold.stats.matches_found -eq $warm.stats.matches_found) "match count diverged for $expression"
    $coldKeys = @(Hit-Keys $cold)
    $warmKeys = @(Hit-Keys $warm)
    Assert-True ((Compare-Object $coldKeys $warmKeys).Count -eq 0) "retained evidence diverged for $expression"
    Assert-True ($cold.scan.state -eq $warm.scan.state) "scan completion diverged for $expression"
    Assert-True ($cold.scan.access_errors -eq $warm.scan.access_errors) "access-error truth diverged for $expression"
    Assert-True ($cold.projection.eligible -eq $warm.projection.eligible) "eligible projection count diverged for $expression"
    Assert-True ($warm.route.lane -eq "warm") "eligible query did not use the warm lane for $expression ($($warm.route.fallback_reason))"
    Assert-True ($warm.scan.files_scanned -le $cold.scan.files_scanned) "warm lane verified more files than cold for $expression"
  }

  $previousIndex = $env:IX_INDEX
  try {
    $env:IX_INDEX = "1"
    $pageOne = (& $Ix search "lit:needle-" $root --format json-compact --max-hits 5 | ConvertFrom-Json)
    Assert-True ($pageOne.route.lane -eq "warm") "bounded first page bypassed the warm lane"
    Assert-True ($null -ne $pageOne.projection.next_cursor) "bounded warm page omitted continuation"
    $pageTwo = (& $Ix search "lit:needle-" $root --format json-compact --max-hits 5 --cursor $pageOne.projection.next_cursor | ConvertFrom-Json)
    Assert-True ($pageTwo.route.lane -eq "warm") "warm cursor continuation fell back to cold"
    $pageOneKeys = @(Hit-Keys $pageOne)
    $pageTwoKeys = @(Hit-Keys $pageTwo)
    Assert-True (@($pageOneKeys | Where-Object { $pageTwoKeys -contains $_ }).Count -eq 0) "warm cursor continuation repeated evidence"
  } finally {
    if ($null -eq $previousIndex) { Remove-Item Env:IX_INDEX -ErrorAction SilentlyContinue } else { $env:IX_INDEX = $previousIndex }
  }

  [System.IO.File]::AppendAllText((Join-Path $root "f1.txt"), "mutated needle-1`n", [System.Text.UTF8Encoding]::new($false))
  $mutatedCold = Search "lit:needle-" $false
  $mutationDeadline = [DateTime]::UtcNow.AddSeconds(30)
  do {
    $mutatedWarm = Wait-Warm "lit:needle-"
    $mutationConverged = $mutatedCold.stats.matches_found -eq $mutatedWarm.stats.matches_found -and
      (Compare-Object @(Hit-Keys $mutatedCold) @(Hit-Keys $mutatedWarm)).Count -eq 0
    if (-not $mutationConverged) { Start-Sleep -Milliseconds 100 }
  } while (-not $mutationConverged -and [DateTime]::UtcNow -lt $mutationDeadline)
  Assert-True $mutationConverged "warm lane did not converge after mutation"

  $coldTimes = [System.Collections.Generic.List[double]]::new()
  $warmTimes = [System.Collections.Generic.List[double]]::new()
  for ($round = 0; $round -lt $Rounds; $round++) {
    $coldTimes.Add([double](Search "lit:needle-" $false).stats.total_ms)
    $warmTimes.Add([double](Search "lit:needle-" $true).stats.total_ms)
  }
  $coldMedian = Median $coldTimes
  $warmMedian = Median $warmTimes
  $allowedWarm = [math]::Max($coldMedian * 1.25, $coldMedian + 2.0)
  Assert-True ($warmMedian -le $allowedWarm) "warm median regressed: cold=$coldMedian ms warm=$warmMedian ms allowed=$allowedWarm ms"

  $succeeded = $true
  Write-Host ("PASS warm/cold parity: matches and evidence identical; files {0}->{1}; median {2:N3}->{3:N3} ms" -f `
    (Search "lit:needle-" $false).scan.files_scanned,
    (Search "lit:needle-" $true).scan.files_scanned,
    $coldMedian,
    $warmMedian)
} finally {
  if ($null -ne $indexd -and -not $indexd.HasExited) {
    Stop-Process -Id $indexd.Id -Force -ErrorAction SilentlyContinue
    $indexd.WaitForExit()
  }
  foreach ($livePid in @(Live-IndexdPids)) {
    Stop-Process -Id $livePid -Force -ErrorAction SilentlyContinue
  }
  if ($null -eq $previousStateDir) { Remove-Item Env:IX_STATE_DIR -ErrorAction SilentlyContinue } else { $env:IX_STATE_DIR = $previousStateDir }
  $resolvedRoot = [System.IO.Path]::GetFullPath($sessionRoot)
  $resolvedTemp = [System.IO.Path]::GetFullPath($tempBase)
  if ($succeeded -and $resolvedRoot.StartsWith($resolvedTemp) -and [System.IO.Path]::GetFileName($resolvedRoot).StartsWith("ix-warm-cold-parity-")) {
    [System.IO.Directory]::Delete($resolvedRoot, $true)
  } elseif (-not $succeeded) {
    Write-Warning "Preserved failed parity state at $resolvedRoot"
  }
}
