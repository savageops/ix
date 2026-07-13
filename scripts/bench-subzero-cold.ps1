param(
  [string]$ZigBin = "E:\Workspaces\01_Projects\01_Github\ix-zig\zig-out\bin\ix-zig.exe",
  [string]$RustBin = "E:\Workspaces\01_Projects\01_Github\iEx\target\release\ix.exe",
  [string]$LinuxCorpus = "E:\Workspaces\01_Projects\01_Github\iEx\.refs\ripgrep\benchsuite\linux",
  [int]$ColdRuns = 5,
  [int]$TransitionRuns = 5,
  [int]$SteadyRuns = 7
)

$ErrorActionPreference = "Stop"
[System.Threading.Thread]::CurrentThread.CurrentCulture = [System.Globalization.CultureInfo]::InvariantCulture
[System.Threading.Thread]::CurrentThread.CurrentUICulture = [System.Globalization.CultureInfo]::InvariantCulture

function Median([double[]]$Values) {
  if ($Values.Count -eq 0) { return $null }
  $sorted = @($Values | Sort-Object)
  return $sorted[[int][math]::Floor($sorted.Count / 2)]
}

function Invoke-IxSearch($Bin, $Engine, $Profile, [bool]$DisableNexus, [int]$Sample) {
  if ($DisableNexus) {
    $env:IX_NEXUS = "0"
  } else {
    Remove-Item Env:\IX_NEXUS -ErrorAction SilentlyContinue
  }

  $sw = [System.Diagnostics.Stopwatch]::StartNew()
  # Full JSON is the diagnostic projection; --stats-only is the framed v1
  # sentinel and cannot be combined with --json under the canonical parser.
  $out = & $Bin search $Profile.expr $Profile.corpus --json 2>&1
  $code = $LASTEXITCODE
  $sw.Stop()
  Remove-Item Env:\IX_NEXUS -ErrorAction SilentlyContinue

  if ($code -ne 0) {
    return [pscustomobject]@{
      profile = $Profile.name
      engine = $Engine
      sample = $Sample
      ok = $false
      comparison_valid = $false
      comparison_reason = "process_failed"
      wall_ms = [math]::Round($sw.Elapsed.TotalMilliseconds, 4)
      error = ($out -join "`n")
    }
  }

  $json = ($out -join "`n") | ConvertFrom-Json
  return [pscustomobject]@{
    profile = $Profile.name
    engine = $Engine
    sample = $Sample
    ok = $true
    wall_ms = [math]::Round($sw.Elapsed.TotalMilliseconds, 4)
    total_ms = [double]$json.stats.timings.total_ms
    discover_ms = [double]$json.stats.timings.discover_ms
    scan_ms = [double]$json.stats.timings.scan_ms
    scan_work_ms_total = [double]$json.stats.timings.scan_work_ms_total
    aggregate_ms = [double]$json.stats.timings.aggregate_ms
    matches = [int64]$json.stats.matches_found
    discovered = [int64]$json.stats.files_discovered
    scanned = [int64]$json.stats.files_scanned
    skipped = [int64]$json.stats.files_skipped
    access_errors = if ($null -eq $json.stats.access_errors -or $null -eq $json.stats.access_errors.total) { $null } else { [int64]$json.stats.access_errors.total }
    access_errors_known = $null -ne $json.stats.access_errors -and $null -ne $json.stats.access_errors.total
    comparison_valid = $false
    comparison_reason = "pending_parity_check"
    pruned = [int64]$json.stats.trigram_acceleration.pruned_files
    verified = [int64]$json.stats.trigram_acceleration.verified_files
    byte_shard = $json.stats.byte_shard_kernel
    regex_decomposition = $json.stats.regex_decomposition
    linux_dominant_file = $json.stats.linux_dominant_file
    concurrency = $json.stats.concurrency
    slowest_files = $json.stats.slowest_files
    generation_refresh = $json.stats.generation_refresh
  }
}

function Summarize($Rows, $ProfileName, $Engine) {
  $all = @($Rows | Where-Object { $_.profile -eq $ProfileName -and $_.engine -eq $Engine })
  $set = @($all | Where-Object { $_.ok -and $_.comparison_valid })
  $invalid = @($all | Where-Object { -not $_.comparison_valid })
  if ($set.Count -eq 0) {
    return [pscustomobject]@{ profile = $ProfileName; engine = $Engine; runs = 0; comparison_invalid_rows = $invalid.Count }
  }
  $first = $set | Select-Object -First 1
  $totals = @($set | ForEach-Object { [double]$_.total_ms })
  $walls = @($set | ForEach-Object { [double]$_.wall_ms })
  $discovers = @($set | ForEach-Object { [double]$_.discover_ms })
  $scans = @($set | ForEach-Object { [double]$_.scan_ms })
  $scanWork = @($set | ForEach-Object { [double]$_.scan_work_ms_total })

  return [pscustomobject]@{
    profile = $ProfileName
    engine = $Engine
    runs = $set.Count
    comparison_invalid_rows = $invalid.Count
    median_total_ms = Median $totals
    best_total_ms = (@($totals | Sort-Object))[0]
    median_wall_ms = Median $walls
    median_discover_ms = Median $discovers
    median_scan_ms = Median $scans
    median_scan_work_ms_total = Median $scanWork
    totals_ms = $totals
    matches = @($set | ForEach-Object { $_.matches })
    files_last = @($first.discovered, $first.scanned, $first.skipped)
    pruned_last = $first.pruned
    verified_last = $first.verified
    byte_shard_last = $first.byte_shard
    regex_decomposition_last = $first.regex_decomposition
    linux_dominant_file_last = $first.linux_dominant_file
  }
}

function Get-ExtensionProfile($Root) {
  $files = @(Get-ChildItem -LiteralPath $Root -Recurse -File -Force -ErrorAction SilentlyContinue)
  $totalBytes = [int64](($files | Measure-Object -Property Length -Sum).Sum)
  $buckets = $files |
    Group-Object { $ext = $_.Extension; if ([string]::IsNullOrWhiteSpace($ext)) { "<none>" } else { $ext.ToLowerInvariant() } } |
    ForEach-Object {
      $items = @($_.Group)
      [pscustomobject]@{
        extension = $_.Name
        files = $items.Count
        bytes = [int64](($items | Measure-Object -Property Length -Sum).Sum)
      }
    } |
    Sort-Object -Property bytes -Descending |
    Select-Object -First 40

  return [pscustomobject]@{
    total_files = $files.Count
    total_bytes = $totalBytes
    top_extensions = @($buckets)
  }
}

function Compress-Row($Row) {
  if (-not $Row.ok) { return $Row }
  return [pscustomobject]@{
    profile = $Row.profile
    engine = $Row.engine
    sample = $Row.sample
    ok = $Row.ok
    wall_ms = $Row.wall_ms
    total_ms = $Row.total_ms
    discover_ms = $Row.discover_ms
    scan_ms = $Row.scan_ms
    scan_work_ms_total = $Row.scan_work_ms_total
    aggregate_ms = $Row.aggregate_ms
    matches = $Row.matches
    discovered = $Row.discovered
    scanned = $Row.scanned
    skipped = $Row.skipped
    access_errors = $Row.access_errors
    access_errors_known = $Row.access_errors_known
    comparison_valid = $Row.comparison_valid
    comparison_reason = $Row.comparison_reason
    pruned = $Row.pruned
    verified = $Row.verified
    byte_shard = [pscustomobject]@{
      enabled = $Row.byte_shard.enabled
      strategy = $Row.byte_shard.strategy
      files_profiled = $Row.byte_shard.files_profiled
      range_calls = $Row.byte_shard.range_calls
      line_aligned_ranges = $Row.byte_shard.line_aligned_ranges
      logical_range_bytes = $Row.byte_shard.logical_range_bytes
      matches = $Row.byte_shard.matches
    }
    regex_decomposition = [pscustomobject]@{
      eligible_files = $Row.regex_decomposition.eligible_files
      counted_files = $Row.regex_decomposition.counted_files
      bailout_files = $Row.regex_decomposition.bailout_files
      candidate_lines_checked = $Row.regex_decomposition.candidate_lines_checked
      candidate_lines_matched = $Row.regex_decomposition.candidate_lines_matched
    }
    linux_dominant_file = $Row.linux_dominant_file
    concurrency = [pscustomobject]@{
      available_threads = $Row.concurrency.available_threads
      outer_scan_threads = $Row.concurrency.outer_scan_threads
      execution_mode = $Row.concurrency.execution_mode
      sharding_enabled = $Row.concurrency.sharding_enabled
      sharded_files = $Row.concurrency.sharded_files
    }
    slowest_files = @($Row.slowest_files)
    generation_refresh = [pscustomobject]@{
      enabled = $Row.generation_refresh.enabled
      available = $Row.generation_refresh.available
      refresh_status = $Row.generation_refresh.refresh_status
      fallback_reason = $Row.generation_refresh.fallback_reason
    }
  }
}

$profiles = @(
  @{ name = "literal-pm-resume"; expr = "lit:PM_RESUME"; corpus = $LinuxCorpus },
  @{ name = "regex-word-pm-resume"; expr = "re:\bPM_RESUME\b"; corpus = $LinuxCorpus },
  @{ name = "absent-literal"; expr = "lit:IX_ABSENT_NEEDLE_5E4C2D8F"; corpus = $LinuxCorpus }
)

$rows = New-Object System.Collections.Generic.List[object]
foreach ($profile in $profiles) {
  for ($i = 1; $i -le $ColdRuns; $i++) {
    $row = Invoke-IxSearch $RustBin "rust" $profile $false $i
    $rows.Add($row)
    Write-Host ("{0} rust #{1}: total={2} wall={3} discover={4} scan={5} matches={6}" -f $profile.name, $i, $row.total_ms, $row.wall_ms, $row.discover_ms, $row.scan_ms, $row.matches)
  }
  for ($i = 1; $i -le $ColdRuns; $i++) {
    $row = Invoke-IxSearch $ZigBin "zig_cold_nexus_off" $profile $true $i
    $rows.Add($row)
    Write-Host ("{0} zig cold #{1}: total={2} wall={3} discover={4} scan={5} matches={6} pruned={7}" -f $profile.name, $i, $row.total_ms, $row.wall_ms, $row.discover_ms, $row.scan_ms, $row.matches, $row.pruned)
  }
  for ($i = 1; $i -le $TransitionRuns; $i++) {
    $row = Invoke-IxSearch $ZigBin "zig_transition_default" $profile $false $i
    $rows.Add($row)
    Write-Host ("{0} zig transition #{1}: total={2} wall={3} discover={4} scan={5} matches={6} pruned={7}" -f $profile.name, $i, $row.total_ms, $row.wall_ms, $row.discover_ms, $row.scan_ms, $row.matches, $row.pruned)
  }
  for ($i = 1; $i -le $SteadyRuns; $i++) {
    $row = Invoke-IxSearch $ZigBin "zig_steady_hot" $profile $false $i
    $rows.Add($row)
    Write-Host ("{0} zig steady #{1}: total={2} wall={3} discover={4} scan={5} matches={6} pruned={7}" -f $profile.name, $i, $row.total_ms, $row.wall_ms, $row.discover_ms, $row.scan_ms, $row.matches, $row.pruned)
  }
}

foreach ($profile in $profiles) {
  $reference = @($rows | Where-Object { $_.profile -eq $profile.name -and $_.engine -eq "rust" -and $_.ok } | Select-Object -First 1)
  if ($reference.Count -eq 0) { throw "no valid Rust predecessor row for $($profile.name)" }
  $baseline = $reference[0]
  foreach ($row in @($rows | Where-Object { $_.profile -eq $profile.name })) {
    if (-not $row.ok) {
      $row.comparison_valid = $false
      $row.comparison_reason = "process_failed"
      continue
    }
    $match_ok = [int64]$row.matches -eq [int64]$baseline.matches
    $route_ok = $row.access_errors_known -and $baseline.access_errors_known -and
      ([int64]$row.discovered -eq [int64]$baseline.discovered) -and
      ([int64]$row.scanned -eq [int64]$baseline.scanned) -and
      ([int64]$row.skipped -eq [int64]$baseline.skipped) -and
      ([int64]$row.access_errors -eq [int64]$baseline.access_errors)
    $row.comparison_valid = $match_ok -and $route_ok
    if ($row.comparison_valid) {
      $row.comparison_reason = "match_and_route_parity"
    } elseif (-not $match_ok) {
      $row.comparison_reason = "match_parity_mismatch"
    } else {
      $row.comparison_reason = "route_parity_mismatch"
    }
  }
}

$summary = @()
foreach ($profile in $profiles) {
  foreach ($engine in @("rust", "zig_cold_nexus_off", "zig_transition_default", "zig_steady_hot")) {
    $summary += Summarize $rows $profile.name $engine
  }
}

$extensionProfile = Get-ExtensionProfile $LinuxCorpus
$processes = @(Get-CimInstance Win32_Process -Filter "name = 'ix-zig.exe'" | ForEach-Object {
  [pscustomobject]@{
    process_id = $_.ProcessId
    creation_date = [string]$_.CreationDate
    command_line = [string]$_.CommandLine
  }
})

$stamp = Get-Date -Format "yyyyMMdd-HHmmss"
$dir = ".docs\reports\subzero-cold-decomposition-$stamp"
New-Item -ItemType Directory -Force -Path $dir | Out-Null
$reportPath = Join-Path $dir "summary.json"

[pscustomobject]@{
  timestamp = (Get-Date).ToString("o")
  zig_bin = $ZigBin
  rust_bin = $RustBin
  linux_corpus = $LinuxCorpus
  profiles = @($profiles | ForEach-Object { [pscustomobject]@{ name = $_.name; expr = $_.expr; corpus = $_.corpus } })
  rows = @($rows | ForEach-Object { Compress-Row $_ })
  summary = @($summary)
  extension_profile = $extensionProfile
  processes = $processes
} | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $reportPath -Encoding UTF8

Write-Host "REPORT $reportPath"
