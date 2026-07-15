param(
  [string]$CandidateBin = (Join-Path $PSScriptRoot '..\zig-out\bin\ix-zig.exe'),
  [string[]]$BaselineBin = @(),
  [string]$Corpus = 'E:\Workspaces\01_Projects\01_Github\iEx\.refs\ripgrep\benchsuite\linux',
  [string]$Expression = 'lit:PM_RESUME',
  [int]$Threads = 16,
  [int]$ColdRuns = 3,
  [int]$Runs = 7,
  [int]$TimeoutSeconds = 600,
  [string]$OutputPath
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
[System.Threading.Thread]::CurrentThread.CurrentCulture = [System.Globalization.CultureInfo]::InvariantCulture
[System.Threading.Thread]::CurrentThread.CurrentUICulture = [System.Globalization.CultureInfo]::InvariantCulture
. (Join-Path $PSScriptRoot 'benchmark-metrics.ps1')

# Runs one fresh IX client process against either the exhaustive or indexed route.
function Invoke-IxPromotionSample {
  param(
    [string]$Bin,
    [string]$Engine,
    [string]$Lane,
    [int]$Sample,
    [string]$StateDir
  )

  $arguments = @('search', $Expression, (Resolve-Path -LiteralPath $Corpus).Path, '--json', '--stats-only', '--threads', [string]$Threads)
  $startInfo = [System.Diagnostics.ProcessStartInfo]::new()
  $startInfo.FileName = (Resolve-Path -LiteralPath $Bin).Path
  $startInfo.WorkingDirectory = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).Path
  $startInfo.UseShellExecute = $false
  $startInfo.RedirectStandardOutput = $true
  $startInfo.RedirectStandardError = $true
  $startInfo.CreateNoWindow = $true
  $startInfo.Arguments = (($arguments | ForEach-Object { '"' + ([string]$_).Replace('"', '\"') + '"' }) -join ' ')
  $startInfo.EnvironmentVariables['IX_STATE_DIR'] = $StateDir
  $startInfo.EnvironmentVariables['IX_INDEX'] = if ($Lane -eq 'indexed_warm') { '1' } else { '0' }
  $startInfo.EnvironmentVariables['IX_NEXUS'] = '0'

  $process = [System.Diagnostics.Process]::new()
  $process.StartInfo = $startInfo
  $clock = [System.Diagnostics.Stopwatch]::StartNew()
  [void]$process.Start()
  $stdoutTask = $process.StandardOutput.ReadToEndAsync()
  $stderrTask = $process.StandardError.ReadToEndAsync()
  $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
  $peak = [long]0
  while (-not $process.WaitForExit(100)) {
    try { $peak = [math]::Max($peak, [long]$process.WorkingSet64) } catch {}
    if ([DateTime]::UtcNow -lt $deadline) { continue }
    try { $process.Kill() } catch {}
    $process.WaitForExit()
    $clock.Stop()
    $process.Dispose()
    return [pscustomobject]@{ engine = $Engine; sample = $Sample; lane = $Lane; ok = $false; wall_ms = [math]::Round($clock.Elapsed.TotalMilliseconds, 4); route_lane = $null; fallback_reason = 'process_timeout'; error = 'process_timeout' }
  }
  try { $peak = [math]::Max($peak, [long]$process.PeakWorkingSet64) } catch {}
  $clock.Stop()
  $stdout = $stdoutTask.GetAwaiter().GetResult()
  $stderr = $stderrTask.GetAwaiter().GetResult()
  $exitCode = $process.ExitCode
  $process.Dispose()
  if ($exitCode -ne 0) {
    return [pscustomobject]@{ engine = $Engine; sample = $Sample; lane = $Lane; ok = $false; wall_ms = [math]::Round($clock.Elapsed.TotalMilliseconds, 4); route_lane = $null; fallback_reason = $null; error = $stderr.Trim() }
  }

  try {
    $payload = $stdout | ConvertFrom-Json
  } catch {
    return [pscustomobject]@{ engine = $Engine; sample = $Sample; lane = $Lane; ok = $false; wall_ms = [math]::Round($clock.Elapsed.TotalMilliseconds, 4); route_lane = $null; fallback_reason = $null; error = 'invalid_json' }
  }
  $routeLane = if ($payload.stats.postings_index.available) { 'warm' } else { 'cold' }
  $reportedPeak = if ($null -ne $payload.stats.PSObject.Properties['process_memory'] -and $null -ne $payload.stats.process_memory.peak_resident_bytes) { [long]$payload.stats.process_memory.peak_resident_bytes } else { $null }
  $effectivePeak = if ($null -eq $reportedPeak) { $peak } else { [math]::Max($peak, $reportedPeak) }
  $effectiveThreads = if ($null -eq $payload.stats.concurrency.outer_scan_threads) { 1 } else { [int]$payload.stats.concurrency.outer_scan_threads }
  return [pscustomobject]@{
    engine = $Engine
    sample = $Sample
    lane = $Lane
    ok = $true
    wall_ms = [math]::Round($clock.Elapsed.TotalMilliseconds, 4)
    total_ms = [double]$payload.stats.timings.total_ms
    scan_work_ms_total = [double]$payload.stats.timings.scan_work_ms_total
    matches = [int64]$payload.stats.matches_found
    files_discovered = [int64]$payload.stats.files_discovered
    files_scanned = [int64]$payload.stats.files_scanned
    route_lane = $routeLane
    fallback_reason = [string]$payload.stats.postings_index.fallback_reason
    refresh_status = [string]$payload.stats.generation_refresh.refresh_status
    threads = $effectiveThreads
    peak_resident_bytes = $effectivePeak
    normalized = Get-IxResourceNormalization -WallMs ([double]$payload.stats.timings.total_ms) -Threads $effectiveThreads -PeakResidentBytes $effectivePeak
    error = $null
  }
}

# Starts the persistent index owner in an isolated state directory for one binary.
function Start-IxPromotionIndexd {
  param([string]$Bin, [string]$StateDir)

  $arguments = @('__ix_indexd', (Resolve-Path -LiteralPath $Corpus).Path, '--foreground')
  $startInfo = [System.Diagnostics.ProcessStartInfo]::new()
  $startInfo.FileName = (Resolve-Path -LiteralPath $Bin).Path
  $startInfo.WorkingDirectory = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).Path
  $startInfo.UseShellExecute = $false
  $startInfo.CreateNoWindow = $true
  $startInfo.WindowStyle = [System.Diagnostics.ProcessWindowStyle]::Hidden
  $startInfo.Arguments = (($arguments | ForEach-Object { '"' + ([string]$_).Replace('"', '\"') + '"' }) -join ' ')
  $startInfo.EnvironmentVariables['IX_STATE_DIR'] = $StateDir
  $startInfo.EnvironmentVariables['IX_INDEX'] = '1'
  $startInfo.EnvironmentVariables['IX_NEXUS'] = '0'
  $process = [System.Diagnostics.Process]::new()
  $process.StartInfo = $startInfo
  [void]$process.Start()
  return $process
}

# Blocks promotion until telemetry proves the daemon serves the indexed route.
function Wait-IxPromotionWarmRoute {
  param([string]$Bin, [string]$Engine, [string]$StateDir, [System.Diagnostics.Process]$Indexd)

  $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
  $last = $null
  do {
    if ($Indexd.HasExited) { throw "indexd exited before $Engine reached the warm route (exit=$($Indexd.ExitCode))" }
    $liveMarker = Get-ChildItem -LiteralPath $StateDir -Filter 'index.live' -File -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($null -ne $liveMarker) {
      $last = Invoke-IxPromotionSample $Bin $Engine 'indexed_warm' 0 $StateDir
      if ($last.ok -and $last.route_lane -eq 'warm') { return $last }
    }
    Start-Sleep -Milliseconds 100
  } while ([DateTime]::UtcNow -lt $deadline)
  $reason = if ($null -eq $last) { 'no_probe' } elseif (-not $last.ok) { $last.error } else { $last.fallback_reason }
  throw "$Engine did not reach the warm route within $TimeoutSeconds seconds (reason=$reason)"
}

# Deletes only the isolated benchmark state directory created by this script.
function Remove-IxPromotionState {
  param([string]$StateDir)

  if (-not (Test-Path -LiteralPath $StateDir)) { return }
  $resolved = [System.IO.Path]::GetFullPath($StateDir)
  $temp = [System.IO.Path]::GetFullPath([System.IO.Path]::GetTempPath())
  $leaf = [System.IO.Path]::GetFileName($resolved)
  if (-not $resolved.StartsWith($temp, [System.StringComparison]::OrdinalIgnoreCase) -or -not $leaf.StartsWith('ix-promotion-speed-', [System.StringComparison]::Ordinal)) {
    throw "refusing to remove non-benchmark state directory: $resolved"
  }
  [System.IO.Directory]::Delete($resolved, $true)
}

# Reduces route-proven samples without conflating filesystem cache with indexing.
function Get-IxPromotionSummary {
  param($Rows, [string]$Engine)

  $set = @($Rows | Where-Object { $_.engine -eq $Engine -and $_.ok })
  $warm = @($set | Where-Object lane -eq 'indexed_warm')
  $cold = @($set | Where-Object lane -eq 'process_cold')
  return [pscustomobject]@{
    engine = $Engine
    valid_runs = $set.Count
    failed_runs = @($Rows | Where-Object { $_.engine -eq $Engine -and -not $_.ok }).Count
    matches = @($set | ForEach-Object matches | Sort-Object -Unique)
    cold_median_total_ms = Get-IxMedian @($cold | ForEach-Object { [double]$_.total_ms })
    cold_median_wall_ms = Get-IxMedian @($cold | ForEach-Object { [double]$_.wall_ms })
    warm_median_total_ms = Get-IxMedian @($warm | ForEach-Object { [double]$_.total_ms })
    warm_median_wall_ms = Get-IxMedian @($warm | ForEach-Object { [double]$_.wall_ms })
    warm_median_scan_work_ms_total = Get-IxMedian @($warm | ForEach-Object { [double]$_.scan_work_ms_total })
    warm_median_rough_one_thread_ms = Get-IxMedian @($warm | ForEach-Object { [double]$_.normalized.rough_linear_one_thread_ms })
    warm_median_peak_mib = Get-IxMedian @($warm | ForEach-Object { [double]$_.normalized.peak_resident_mib })
  }
}

if ([string]::IsNullOrWhiteSpace($OutputPath)) {
  $OutputPath = Join-Path $PSScriptRoot ("..\.docs\reports\promotion-speed-{0}.json" -f [DateTime]::UtcNow.ToString('yyyyMMdd-HHmmss'))
}
$engines = @([pscustomobject]@{ name = 'candidate'; bin = $CandidateBin })
$index = 0
foreach ($bin in $BaselineBin) { $index++; $engines += [pscustomobject]@{ name = "baseline_$index"; bin = $bin } }
$provenance = @($engines | ForEach-Object { [pscustomobject]@{ engine = $_.name; path = (Resolve-Path -LiteralPath $_.bin).Path; sha256 = (Get-FileHash -LiteralPath $_.bin -Algorithm SHA256).Hash.ToLowerInvariant() } })
$rows = [System.Collections.Generic.List[object]]::new()

foreach ($engine in $engines) {
  $stateDir = Join-Path ([System.IO.Path]::GetTempPath()) ("ix-promotion-speed-" + [guid]::NewGuid().ToString('N'))
  [void][System.IO.Directory]::CreateDirectory($stateDir)
  $indexd = $null
  try {
    for ($sample = 1; $sample -le $ColdRuns; $sample++) {
      $row = Invoke-IxPromotionSample $engine.bin $engine.name 'process_cold' $sample $stateDir
      $rows.Add($row)
      $engineMs = if ($row.ok) { $row.total_ms } else { 'n/a' }
      Write-Host ("{0} cold #{1}: ok={2} route={3} engine={4}ms wall={5}ms" -f $engine.name, $sample, $row.ok, $row.route_lane, $engineMs, $row.wall_ms)
    }
    $indexd = Start-IxPromotionIndexd $engine.bin $stateDir
    $ready = Wait-IxPromotionWarmRoute $engine.bin $engine.name $stateDir $indexd
    Write-Host ("{0} warm ready: engine={1}ms" -f $engine.name, $ready.total_ms)
    for ($sample = 1; $sample -le $Runs; $sample++) {
      $row = Invoke-IxPromotionSample $engine.bin $engine.name 'indexed_warm' $sample $stateDir
      $rows.Add($row)
      $engineMs = if ($row.ok) { $row.total_ms } else { 'n/a' }
      Write-Host ("{0} warm #{1}: ok={2} route={3} engine={4}ms wall={5}ms" -f $engine.name, $sample, $row.ok, $row.route_lane, $engineMs, $row.wall_ms)
    }
  } finally {
    if ($null -ne $indexd -and -not $indexd.HasExited) {
      try { $indexd.Kill() } catch {}
      $indexd.WaitForExit()
    }
    if ($null -ne $indexd) { $indexd.Dispose() }
    Remove-IxPromotionState $stateDir
  }
}

$summaries = @($engines | ForEach-Object { Get-IxPromotionSummary $rows $_.name })
$candidateMatches = @($summaries | Where-Object engine -eq 'candidate' | Select-Object -ExpandProperty matches)
$parity = @($summaries | ForEach-Object { [pscustomobject]@{ engine = $_.engine; matches = $_.matches; equal_to_candidate = (@($_.matches) -join ',') -eq ($candidateMatches -join ',') } })
$routeFailures = @($rows | Where-Object { $_.ok -and (($_.lane -eq 'process_cold' -and $_.route_lane -ne 'cold') -or ($_.lane -eq 'indexed_warm' -and $_.route_lane -ne 'warm')) })
$failedRows = @($rows | Where-Object { -not $_.ok })
$parityFailures = @($parity | Where-Object { -not $_.equal_to_candidate })
$report = [pscustomobject]@{
  schema = 'ix.promotion-speed.v3'
  generated_utc = [DateTime]::UtcNow.ToString('o')
  expression = $Expression
  corpus = (Resolve-Path -LiteralPath $Corpus).Path
  threads_requested = $Threads
  cold_runs = $ColdRuns
  warm_runs = $Runs
  cold_definition = 'fresh client process with IX_INDEX=0; no index route is admissible; filesystem cache is not forcibly cleared'
  warm_definition = 'fresh client process with IX_INDEX=1 against a live binary-matched __ix_indexd in an isolated state directory; postings_index.available must be true'
  provenance = $provenance
  rows = $rows.ToArray()
  summaries = $summaries
  parity = $parity
  gate = [pscustomobject]@{
    passed = $failedRows.Count -eq 0 -and $routeFailures.Count -eq 0 -and $parityFailures.Count -eq 0
    failed_rows = $failedRows.Count
    route_failures = $routeFailures.Count
    parity_failures = $parityFailures.Count
  }
  rule = 'promotion requires match parity and explicit route proof; OS-cache repeats are never called warm'
}
$directory = Split-Path -Parent $OutputPath
if (-not [string]::IsNullOrWhiteSpace($directory) -and -not (Test-Path -LiteralPath $directory)) { [void][System.IO.Directory]::CreateDirectory($directory) }
$report | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $OutputPath -Encoding UTF8
$report | ConvertTo-Json -Depth 10
if (-not $report.gate.passed) { throw "promotion speed gate failed; inspect $OutputPath" }
