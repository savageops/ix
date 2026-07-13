param(
  [string]$Ix = (Join-Path $PSScriptRoot "..\zig-out\bin\ix-zig.exe")
)

$ErrorActionPreference = "Stop"
$Ix = (Resolve-Path $Ix).Path
$tempBase = [System.IO.Path]::GetTempPath()
$root = Join-Path $tempBase ("ix-output-contract-" + [guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path $root | Out-Null

function Assert-True([bool]$Condition, [string]$Message) {
  if (-not $Condition) { throw $Message }
}

function Invoke-Raw([string[]]$Arguments) {
  $start = [System.Diagnostics.ProcessStartInfo]::new()
  $start.FileName = $Ix
  $start.UseShellExecute = $false
  $start.RedirectStandardOutput = $true
  $start.RedirectStandardError = $true
  Assert-True (-not ($Arguments | Where-Object { $_ -match '[\s"]' })) "test harness arguments must remain shell-free single tokens"
  $start.Arguments = $Arguments -join " "
  $process = [System.Diagnostics.Process]::new()
  $process.StartInfo = $start
  [void]$process.Start()
  $stdout = $process.StandardOutput.ReadToEnd()
  $stderr = $process.StandardError.ReadToEnd()
  $process.WaitForExit()
  [pscustomobject]@{ ExitCode = $process.ExitCode; Stdout = $stdout; Stderr = $stderr }
}

function Parse-Frame([string]$Text, [string]$Prefix) {
  $trimmed = $Text.Trim()
  $sample = if ($trimmed.Length -gt 160) { $trimmed.Substring(0, 160) } else { $trimmed }
  Assert-True ($trimmed.StartsWith($Prefix)) "missing frame prefix $Prefix; output starts: $sample"
  Assert-True ($trimmed.EndsWith(" --")) "frame is not complete"
  return ($trimmed.Substring($Prefix.Length, $trimmed.Length - $Prefix.Length - 3) | ConvertFrom-Json)
}

function Hit-Keys($Envelope) {
  $keys = [System.Collections.Generic.List[string]]::new()
  foreach ($property in $Envelope.hits.PSObject.Properties) {
    foreach ($hit in $property.Value) { $keys.Add("$($property.Name):$($hit.l):$($hit.c)") }
  }
  return $keys
}

try {
  $lines = [System.Collections.Generic.List[string]]::new()
  for ($index = 1; $index -le 180; $index++) {
    $suffix = "x" * (($index % 23) + 20)
    $lines.Add("line-$index needle-$('{0:d3}' -f $index) $suffix")
  }
  [System.IO.File]::WriteAllLines((Join-Path $root "many.txt"), $lines, [System.Text.UTF8Encoding]::new($false))
  [System.IO.File]::WriteAllText((Join-Path $root "unicode.txt"), "alpha`nβeta needle-777 界界界`nomega`n", [System.Text.UTF8Encoding]::new($false))

  for ($run = 0; $run -lt 20; $run++) {
    $raw = Invoke-Raw @("search", "lit:needle", $root, "--format", "agent-v3", "--max-hits", "3")
    Assert-True ($raw.ExitCode -eq 0) "v3 run failed: $($raw.Stderr)"
    Assert-True (([regex]::Matches($raw.Stdout, "-- ix\.result\.v3 ")).Count -eq 1) "raw child emitted more than one v3 envelope"
  }

  $legacy = Invoke-Raw @("search", "lit:needle", $root, "--agent", "--max-hits", "3")
  Assert-True ($legacy.ExitCode -eq 0) "legacy agent failed"
  Assert-True (([regex]::Matches($legacy.Stdout, "-- ix\.result\.v2 ")).Count -eq 1) "legacy agent emitted more than one envelope"

  $fullJson = Invoke-Raw @("search", "lit:needle", $root, "--json", "--max-hits", "3")
  Assert-True ($fullJson.ExitCode -eq 0) "legacy JSON failed"
  $fullObject = $fullJson.Stdout | ConvertFrom-Json
  Assert-True ($null -ne $fullObject.stats.timings) "legacy JSON lost debug telemetry"
  Assert-True ($fullObject.hits.Count -eq 3) "legacy JSON hit limit changed"

  $context = Invoke-Raw @("search", "lit:needle-777", $root, "--context", "1", "--format", "json-compact")
  Assert-True ($context.ExitCode -eq 0) "context search failed"
  $contextObject = $context.Stdout | ConvertFrom-Json
  Assert-True ($contextObject.context[0].lines.Count -eq 3) "context did not return the exact coalesced window"
  Assert-True ($contextObject.context[0].lines[1].t.Contains("needle-777")) "context lost the represented match line"

  $regex = Invoke-Raw @("search", "re:needle-[0-9]+", (Join-Path $root "unicode.txt"), "--format", "json-compact")
  Assert-True ($regex.ExitCode -eq 0) "regex search failed: $($regex.Stderr)"
  $regexObject = $regex.Stdout | ConvertFrom-Json
  $regexProperty = @($regexObject.hits.PSObject.Properties)[0]
  $regexHit = $regexProperty.Value[0]
  Assert-True ($regexHit.n -eq 10) "variable-width regex span was not exact"
  Assert-True ($regexHit.p.Contains("needle-777")) "UTF-8 preview lost the match"

  $pageOne = Invoke-Raw @("search", "lit:needle", $root, "--format", "agent-v3", "--max-hits", "2")
  Assert-True ($pageOne.ExitCode -eq 0) "first cursor page failed: $($pageOne.Stderr)"
  $pageOneObject = Parse-Frame $pageOne.Stdout "-- ix.result.v3 "
  Assert-True ($null -ne $pageOneObject.projection.next_cursor) "first page omitted its cursor"
  $pageTwo = Invoke-Raw @("search", "lit:needle", $root, "--format", "agent-v3", "--max-hits", "2", "--cursor", $pageOneObject.projection.next_cursor)
  Assert-True ($pageTwo.ExitCode -eq 0) "second cursor page failed: $($pageTwo.Stderr)"
  $pageTwoObject = Parse-Frame $pageTwo.Stdout "-- ix.result.v3 "
  $pageTwoKeys = Hit-Keys $pageTwoObject
  $overlap = @(Hit-Keys $pageOneObject | Where-Object { $pageTwoKeys -contains $_ })
  Assert-True ($overlap.Count -eq 0) "cursor traversal repeated a hit"

  foreach ($budget in @(1400, 4095, 4096, 4097)) {
    $bounded = Invoke-Raw @("search", "lit:needle", $root, "--format", "agent-v3", "--max-bytes", "$budget")
    Assert-True ($bounded.ExitCode -eq 0) "byte-budget search failed at $budget bytes"
    Assert-True (([regex]::Matches($bounded.Stdout, "-- ix\.result\.v3 ")).Count -eq 1) "byte-budget output duplicated at $budget bytes"
    $byteCount = [System.Text.Encoding]::UTF8.GetByteCount($bounded.Stdout)
    Assert-True ($byteCount -le $budget) "serialized output exceeded $budget bytes ($byteCount)"
    $boundedObject = Parse-Frame $bounded.Stdout "-- ix.result.v3 "
    Assert-True ($boundedObject.projection.reason -eq "byte_budget") "byte budget did not own truncation at $budget bytes"
  }

  [System.IO.File]::AppendAllText((Join-Path $root "many.txt"), "mutated needle-999`n", [System.Text.UTF8Encoding]::new($false))
  $stale = Invoke-Raw @("search", "lit:needle", $root, "--format", "agent-v3", "--max-hits", "2", "--cursor", $pageOneObject.projection.next_cursor)
  Assert-True ($stale.ExitCode -ne 0) "stale cursor was accepted after corpus mutation"
  Assert-True ($stale.Stderr.Contains('"code":"stale_cursor"')) "stale cursor recovery was not typed"

  Write-Host "PASS output contract: framing, legacy compatibility, spans, UTF-8, context, cursor, byte budgets, mutation"
} finally {
  $resolvedRoot = [System.IO.Path]::GetFullPath($root)
  $resolvedTemp = [System.IO.Path]::GetFullPath($tempBase)
  if ($resolvedRoot.StartsWith($resolvedTemp) -and [System.IO.Path]::GetFileName($resolvedRoot).StartsWith("ix-output-contract-")) {
    [System.IO.Directory]::Delete($resolvedRoot, $true)
  }
}
