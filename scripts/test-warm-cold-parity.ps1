param(
  [string]$Ix = (Join-Path $PSScriptRoot "..\zig-out\bin\ix-zig.exe"),
  [int]$Rounds = 7
)

$ErrorActionPreference = "Stop"
$Ix = (Resolve-Path $Ix).Path
$tempBase = [System.IO.Path]::GetTempPath()
$root = Join-Path $tempBase ("ix-warm-cold-parity-" + [guid]::NewGuid().ToString("N"))
[void][System.IO.Directory]::CreateDirectory($root)

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
    foreach ($hit in $property.Value) { $keys.Add("$($property.Name):$($hit.l):$($hit.c):$($hit.n)") }
  }
  return @($keys | Sort-Object)
}

function Median([double[]]$Values) {
  $sorted = @($Values | Sort-Object)
  return $sorted[[int][math]::Floor($sorted.Count / 2)]
}

try {
  for ($index = 1; $index -le 1000; $index++) {
    $body = if ($index % 10 -eq 0) { "alpha needle-$index`nsecond needle-$index`n" } else { "alpha filler-$index`n" }
    [System.IO.File]::WriteAllText((Join-Path $root ("f$index.txt")), $body, [System.Text.UTF8Encoding]::new($false))
  }

  & $Ix __ix_indexd $root --foreground --once | Out-Null
  Assert-True ($LASTEXITCODE -eq 0) "warm index build failed"

  foreach ($expression in @("lit:needle-", "lit:not-present-anywhere")) {
    $cold = Search $expression $false
    $warm = Search $expression $true
    Assert-True ($cold.stats.matches_found -eq $warm.stats.matches_found) "match count diverged for $expression"
    $coldKeys = @(Hit-Keys $cold)
    $warmKeys = @(Hit-Keys $warm)
    Assert-True ((Compare-Object $coldKeys $warmKeys).Count -eq 0) "retained evidence diverged for $expression"
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

  Write-Host ("PASS warm/cold parity: matches and evidence identical; files {0}->{1}; median {2:N3}->{3:N3} ms" -f `
    (Search "lit:needle-" $false).scan.files_scanned,
    (Search "lit:needle-" $true).scan.files_scanned,
    $coldMedian,
    $warmMedian)
} finally {
  $resolvedRoot = [System.IO.Path]::GetFullPath($root)
  $resolvedTemp = [System.IO.Path]::GetFullPath($tempBase)
  if ($resolvedRoot.StartsWith($resolvedTemp) -and [System.IO.Path]::GetFileName($resolvedRoot).StartsWith("ix-warm-cold-parity-")) {
    [System.IO.Directory]::Delete($resolvedRoot, $true)
  }
}
