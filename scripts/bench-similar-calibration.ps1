param(
  [string]$CandidateBin = (Join-Path $PSScriptRoot '..\zig-out\bin\ix-zig.exe'),
  [string[]]$PredecessorBin = @(),
  [string]$Corpus = (Join-Path $PSScriptRoot '..\src'),
  [string]$FixturePath,
  [string[]]$FixtureId = @(),
  [int]$CandidateBudget = 12,
  [int]$ColdRuns = 1,
  [int]$WarmRuns = 2,
  [double]$ProbeMinSimilarity = 0.4000,
  [int]$ProcessTimeoutSeconds = 180,
  [double[]]$Thresholds = @(0.2000, 0.4000, 0.5000, 0.6000, 0.7000, 0.8000, 0.8500, 0.8777, 0.8800, 0.9000, 0.9100, 0.9400),
  [string]$OutputPath
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
[System.Threading.Thread]::CurrentThread.CurrentCulture = [System.Globalization.CultureInfo]::InvariantCulture
[System.Threading.Thread]::CurrentThread.CurrentUICulture = [System.Globalization.CultureInfo]::InvariantCulture
. (Join-Path $PSScriptRoot 'benchmark-metrics.ps1')
$script:CorpusPath = (Resolve-Path -LiteralPath $Corpus).Path
$script:CorpusKey = $script:CorpusPath.Replace('\', '/').TrimEnd('/').ToLowerInvariant()

# Normalizes paths so fixture labels survive Windows and JSON separator differences.
function ConvertTo-IxPathKey {
  param([string]$Path)
  $key = $Path.Replace('\', '/').ToLowerInvariant()
  if ($key.StartsWith("$script:CorpusKey/")) { return $key.Substring($script:CorpusKey.Length + 1) }
  return $key.TrimStart([char[]]'./')
}

# Defines a small owner-oriented dogfood set when no external labeled fixture is supplied.
function Get-IxDefaultFixtures {
  return @(
    [pscustomobject]@{ id = 'semantic-provider'; query = 'semantic similarity embeddings reranking provider negotiation'; expected = @('core/similar.zig') },
    [pscustomobject]@{ id = 'semantic-cursor'; query = 'cursor pagination request fingerprint and corpus signature'; expected = @('cli/cursor.zig', 'core/corpus_signature.zig') },
    [pscustomobject]@{ id = 'cli-contract'; query = 'command line parsing output formats help and validation'; expected = @('cli/command_spec.zig', 'cli/output.zig') },
    [pscustomobject]@{ id = 'index-generation'; query = 'persistent index generation delta refresh overlay and postings'; expected = @('core/delta_overlay.zig', 'core/usn.zig', 'core/generation.zig', 'core/indexd.zig', 'core/postings.zig') }
  )
}

# Probes the command contract before spending provider calls on an incompatible predecessor.
function Test-IxSimilarSupport {
  param([string]$Bin)
  if (-not (Test-Path -LiteralPath $Bin -PathType Leaf)) { return $false }
  $help = & $Bin help similar 2>&1
  return $LASTEXITCODE -eq 0 -and (($help -join "`n") -match 'Usage:\s+ix\s+similar')
}

# Executes one isolated process so wall time and peak resident memory share provenance.
function Invoke-IxSimilarSample {
  param(
    [string]$Bin,
    [string]$Engine,
    $Fixture,
    [string]$Lane,
    [int]$Sample
  )
  $arguments = @(
    'similar', [string]$Fixture.query, $script:CorpusPath,
    '--format', 'json-compact',
    '--candidate-budget', [string]$CandidateBudget,
    '--max-results', [string]$CandidateBudget,
    '--min-similarity', $ProbeMinSimilarity.ToString('F4', [System.Globalization.CultureInfo]::InvariantCulture),
    '--max-similarity', '1.0000'
  )
  $startInfo = [System.Diagnostics.ProcessStartInfo]::new()
  $startInfo.FileName = (Resolve-Path -LiteralPath $Bin).Path
  $startInfo.UseShellExecute = $false
  $startInfo.RedirectStandardOutput = $true
  $startInfo.RedirectStandardError = $true
  $startInfo.CreateNoWindow = $true
  $startInfo.Arguments = (($arguments | ForEach-Object { '"' + ([string]$_).Replace('"', '\"') + '"' }) -join ' ')
  $process = [System.Diagnostics.Process]::new()
  $process.StartInfo = $startInfo
  $clock = [System.Diagnostics.Stopwatch]::StartNew()
  [void]$process.Start()
  $stdoutTask = $process.StandardOutput.ReadToEndAsync()
  $stderrTask = $process.StandardError.ReadToEndAsync()
  $deadline = [DateTime]::UtcNow.AddSeconds($ProcessTimeoutSeconds)
  $peak = [long]0
  while (-not $process.WaitForExit(100)) {
    try { $peak = [math]::Max($peak, [long]$process.WorkingSet64) } catch {}
    if ([DateTime]::UtcNow -lt $deadline) { continue }
    try { $process.Kill() } catch {}
    $process.WaitForExit()
    $clock.Stop()
    $process.Dispose()
    return [pscustomobject]@{
      engine = $Engine; fixture = $Fixture.id; lane = $Lane; sample = $Sample
      ok = $false; wall_ms = [math]::Round($clock.Elapsed.TotalMilliseconds, 4)
      peak_resident_bytes = $null; error = 'process_timeout'; results = @()
    }
  }
  try { $peak = [math]::Max($peak, [long]$process.PeakWorkingSet64) } catch {}
  $clock.Stop()
  $stdout = $stdoutTask.GetAwaiter().GetResult()
  $stderr = $stderrTask.GetAwaiter().GetResult()
  $exitCode = $process.ExitCode
  $process.Dispose()
  if ($exitCode -ne 0) {
    return [pscustomobject]@{
      engine = $Engine; fixture = $Fixture.id; lane = $Lane; sample = $Sample
      ok = $false; wall_ms = [math]::Round($clock.Elapsed.TotalMilliseconds, 4)
      peak_resident_bytes = $peak; error = $stderr.Trim(); results = @()
    }
  }
  try {
    $payload = $stdout | ConvertFrom-Json
  } catch {
    return [pscustomobject]@{
      engine = $Engine; fixture = $Fixture.id; lane = $Lane; sample = $Sample
      ok = $false; wall_ms = [math]::Round($clock.Elapsed.TotalMilliseconds, 4)
      peak_resident_bytes = $peak; error = 'invalid_json_output'; results = @()
    }
  }
  $results = @($payload.results | ForEach-Object {
    [pscustomobject]@{
      path = ConvertTo-IxPathKey ([string]$_.path)
      similarity = if ($null -ne $_.PSObject.Properties['similarity']) { [double]$_.similarity } else { [double]$_.embedding }
      rerank = [double]$_.rerank
    }
  })
  return [pscustomobject]@{
    engine = $Engine; fixture = $Fixture.id; lane = $Lane; sample = $Sample
    ok = $true; wall_ms = [math]::Round($clock.Elapsed.TotalMilliseconds, 4)
    peak_resident_bytes = $peak; error = $null; results = $results
  }
}

# Scores reranker ordering against the labeled owner set without treating labels as exhaustive truth.
function Get-IxRankingQuality {
  param($Rows, $Fixtures, [string]$Engine)
  $firstRows = @($Rows | Where-Object { $_.engine -eq $Engine -and $_.ok } | Group-Object fixture | ForEach-Object { $_.Group | Sort-Object lane, sample | Select-Object -First 1 })
  $reciprocalRanks = New-Object System.Collections.Generic.List[double]
  $ownerAtOne = 0
  foreach ($fixture in $Fixtures) {
    $row = $firstRows | Where-Object { $_.fixture -eq $fixture.id } | Select-Object -First 1
    if ($null -eq $row) { $reciprocalRanks.Add(0); continue }
    $expected = @($fixture.expected | ForEach-Object { ConvertTo-IxPathKey $_ })
    $rank = 0
    for ($index = 0; $index -lt $row.results.Count; $index++) {
      if ($expected -contains $row.results[$index].path) { $rank = $index + 1; break }
    }
    if ($rank -eq 1) { $ownerAtOne++ }
    $reciprocalRanks.Add($(if ($rank -eq 0) { 0 } else { 1.0 / $rank }))
  }
  return [pscustomobject]@{
    fixtures = $Fixtures.Count
    owner_at_1 = $ownerAtOne
    owner_at_1_rate = if ($Fixtures.Count -eq 0) { 0 } else { [math]::Round($ownerAtOne / $Fixtures.Count, 6) }
    mean_reciprocal_rank = [math]::Round((($reciprocalRanks | Measure-Object -Average).Average), 6)
  }
}

# Sweeps fixed and observed four-decimal boundaries over one stable sample per fixture.
function Get-IxThresholdCalibration {
  param($Rows, $Fixtures, [string]$Engine)
  $firstRows = @($Rows | Where-Object { $_.engine -eq $Engine -and $_.ok } | Group-Object fixture | ForEach-Object { $_.Group | Sort-Object lane, sample | Select-Object -First 1 })
  $candidates = New-Object System.Collections.Generic.HashSet[double]
  foreach ($threshold in $Thresholds) {
    if ($threshold -ge $ProbeMinSimilarity) { [void]$candidates.Add([math]::Round($threshold, 4)) }
  }
  foreach ($row in $firstRows) {
    foreach ($result in $row.results) {
      $score = [math]::Round([double]$result.similarity, 4)
      [void]$candidates.Add($score)
      if ($score -lt 1.0) { [void]$candidates.Add([math]::Round($score + 0.0001, 4)) }
    }
  }
  $sweep = foreach ($threshold in @($candidates | Sort-Object)) {
    $tp = 0; $fp = 0; $fn = 0
    foreach ($fixture in $Fixtures) {
      $row = $firstRows | Where-Object { $_.fixture -eq $fixture.id } | Select-Object -First 1
      $expected = @($fixture.expected | ForEach-Object { ConvertTo-IxPathKey $_ })
      $admitted = if ($null -eq $row) { @() } else { @($row.results | Where-Object { $_.similarity -ge $threshold }) }
      $tp += @($admitted | Where-Object { $expected -contains $_.path }).Count
      $fp += @($admitted | Where-Object { $expected -notcontains $_.path }).Count
      $foundExpected = @($admitted | ForEach-Object { $_.path } | Where-Object { $expected -contains $_ } | Sort-Object -Unique).Count
      $fn += [math]::Max(0, $expected.Count - $foundExpected)
    }
    $precision = if (($tp + $fp) -eq 0) { 1.0 } else { $tp / ($tp + $fp) }
    $recall = if (($tp + $fn) -eq 0) { 1.0 } else { $tp / ($tp + $fn) }
    $f1 = if (($precision + $recall) -eq 0) { 0 } else { 2 * $precision * $recall / ($precision + $recall) }
    [pscustomobject]@{
      threshold = [math]::Round($threshold, 4); tp = $tp; fp = $fp; fn = $fn
      precision = [math]::Round($precision, 6); recall = [math]::Round($recall, 6); f1 = [math]::Round($f1, 6)
    }
  }
  $recommended = $sweep | Sort-Object @{ Expression = 'f1'; Descending = $true }, @{ Expression = 'threshold'; Descending = $true } | Select-Object -First 1
  return [pscustomobject]@{ recommended = $recommended; sweep = @($sweep) }
}

# Measures score determinism separately from ranking usefulness.
function Get-IxScoreStability {
  param($Rows, [string]$Engine)
  $ranges = @($Rows | Where-Object { $_.engine -eq $Engine -and $_.ok } | ForEach-Object {
    $row = $_
    $row.results | ForEach-Object { [pscustomobject]@{ key = "$($row.fixture)|$($_.path)"; score = [double]$_.similarity } }
  } | Group-Object key | ForEach-Object {
    $values = @($_.Group | ForEach-Object { $_.score })
    [pscustomobject]@{ key = $_.Name; spread = [math]::Round((($values | Measure-Object -Maximum).Maximum - ($values | Measure-Object -Minimum).Minimum), 8) }
  })
  return [pscustomobject]@{
    compared_pairs = $ranges.Count
    max_similarity_spread = if ($ranges.Count -eq 0) { $null } else { ($ranges | Measure-Object spread -Maximum).Maximum }
  }
}

# Summarizes cold and warm timings with the same resource vocabulary as the search bench.
function Get-IxSpeedSummary {
  param($Rows, [string]$Engine)
  $engineRows = @($Rows | Where-Object { $_.engine -eq $Engine -and $_.ok })
  $lanes = @{}
  foreach ($lane in @('cold', 'warm')) {
    $set = @($engineRows | Where-Object { $_.lane -eq $lane })
    if ($set.Count -eq 0) { continue }
    $lanes[$lane] = [pscustomobject]@{
      runs = $set.Count
      median_wall_ms = Get-IxMedian @($set | ForEach-Object { [double]$_.wall_ms })
      median_peak_resident_mib = Get-IxMedian @($set | Where-Object { $null -ne $_.peak_resident_bytes } | ForEach-Object { [double]$_.peak_resident_bytes / 1MB })
      resource_normalized = Get-IxResourceNormalization -WallMs (Get-IxMedian @($set | ForEach-Object { [double]$_.wall_ms })) -Threads 1 -PeakResidentBytes $(
        $peaks = @($set | Where-Object { $null -ne $_.peak_resident_bytes } | ForEach-Object { [long]$_.peak_resident_bytes })
        if ($peaks.Count -eq 0) { $null } else { [long](Get-IxMedian @($peaks | ForEach-Object { [double]$_ })) }
      )
    }
  }
  return [pscustomobject]$lanes
}

if ([string]::IsNullOrWhiteSpace($OutputPath)) {
  $stamp = [DateTime]::UtcNow.ToString('yyyyMMdd-HHmmss')
  $OutputPath = Join-Path $PSScriptRoot "..\.docs\reports\similar-calibration-$stamp.json"
}
$fixtures = if ([string]::IsNullOrWhiteSpace($FixturePath)) { @(Get-IxDefaultFixtures) } else { @((Get-Content -LiteralPath $FixturePath -Raw | ConvertFrom-Json)) }
if ($FixtureId.Count -ne 0) { $fixtures = @($fixtures | Where-Object { $FixtureId -contains $_.id }) }
if ($fixtures.Count -eq 0) { throw 'No calibration fixtures selected.' }
$engines = @([pscustomobject]@{ name = 'candidate'; bin = $CandidateBin })
$index = 0
foreach ($bin in $PredecessorBin) { $index++; $engines += [pscustomobject]@{ name = "predecessor_$index"; bin = $bin } }
$rows = New-Object System.Collections.Generic.List[object]
$support = @{}
foreach ($engine in $engines) {
  $supported = Test-IxSimilarSupport $engine.bin
  $support[$engine.name] = $supported
  if (-not $supported) { continue }
  foreach ($fixture in $fixtures) {
    for ($sample = 1; $sample -le $ColdRuns; $sample++) {
      $row = Invoke-IxSimilarSample $engine.bin $engine.name $fixture 'cold' $sample
      $rows.Add($row)
      Write-Host ("{0} {1} cold #{2}: ok={3} wall={4}ms" -f $engine.name, $fixture.id, $sample, $row.ok, $row.wall_ms)
    }
    for ($sample = 1; $sample -le $WarmRuns; $sample++) {
      $row = Invoke-IxSimilarSample $engine.bin $engine.name $fixture 'warm' $sample
      $rows.Add($row)
      Write-Host ("{0} {1} warm #{2}: ok={3} wall={4}ms" -f $engine.name, $fixture.id, $sample, $row.ok, $row.wall_ms)
    }
  }
}
$engineReports = @{}
foreach ($engine in $engines) {
  if (-not $support[$engine.name]) {
    $engineReports[$engine.name] = [pscustomobject]@{ supported = $false; reason = 'ix similar contract unavailable' }
    continue
  }
  $engineReports[$engine.name] = [pscustomobject]@{
    supported = $true
    quality = Get-IxRankingQuality $rows $fixtures $engine.name
    calibration = Get-IxThresholdCalibration $rows $fixtures $engine.name
    stability = Get-IxScoreStability $rows $engine.name
    speed = Get-IxSpeedSummary $rows $engine.name
  }
}
$report = [pscustomobject]@{
  schema = 'ix.similar.calibration.v1'
  generated_utc = [DateTime]::UtcNow.ToString('o')
  corpus = (Resolve-Path -LiteralPath $Corpus).Path
  candidate_budget = $CandidateBudget
  probe_min_similarity = $ProbeMinSimilarity
  threshold_precision = 4
  fixtures = $fixtures
  engines = [pscustomobject]$engineReports
  rows = $rows.ToArray()
  interpretation = @(
    'Cosine controls admission; rerank controls ordering inside the admitted set.',
    'The recommended threshold optimizes this labeled fixture only and must be rechecked on wider corpora.',
    'Predecessor speed claims require the same command contract; unsupported binaries are explicit, not estimated.',
    'Thread and memory context explain resource asymmetry but never override parity or measured one-thread evidence.'
  )
}
$directory = Split-Path -Parent $OutputPath
if (-not (Test-Path -LiteralPath $directory)) { [void](New-Item -ItemType Directory -Path $directory -Force) }
$report | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $OutputPath -Encoding UTF8
Write-Host "report=$((Resolve-Path -LiteralPath $OutputPath).Path)"
