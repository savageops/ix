param(
    [string]$Candidate = "zig-out/bin/ix-zig.exe",
    [string]$CompactorScript = "C:/Users/Savage/.codex/skills/intelligent-compactor/scripts/compact.py",
    [string]$OutputPath = ".docs/reports/min-context-compaction-20260716.json"
)

$ErrorActionPreference = "Stop"
$repo = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$candidatePath = (Resolve-Path (Join-Path $repo $Candidate)).Path
$compactorPath = (Resolve-Path $CompactorScript).Path
$pythonPath = (Get-Command python -ErrorAction Stop).Source

# Builds a deterministic repetitive log whose required facts are distributed across the file.
function Initialize-RepetitiveLogFixture {
    $fixturePath = Join-Path $repo ".zig-cache/min-verification-repetitive.log"
    $lines = New-Object System.Collections.Generic.List[string]
    for ($index = 0; $index -lt 480; $index++) {
        $lines.Add("2026-07-16T12:00:00Z INFO worker=scan shard=7 state=healthy queue=0 repeated-heartbeat")
        if ($index -eq 3) { $lines.Add("BOUNDARY_FACT alpha admission rejects binary input before scoring") }
        if ($index -eq 97) { $lines.Add("RECOVERY_FACT beta retry ceiling is exactly 3 attempts") }
        if ($index -eq 191) { $lines.Add("OWNER_FACT gamma src/core/min.zig owns bounded compaction") }
        if ($index -eq 286) { $lines.Add("ERROR_FACT delta min_budget_too_small preserves honest failure") }
        if ($index -eq 382) { $lines.Add("PROOF_FACT epsilon output_bytes equals serialized UTF-8 bytes") }
        if ($index -eq 476) { $lines.Add("FINAL_FACT zeta source order survives selection") }
    }
    [IO.Directory]::CreateDirectory((Split-Path -Parent $fixturePath)) | Out-Null
    [IO.File]::WriteAllLines($fixturePath, $lines, (New-Object Text.UTF8Encoding($false)))
    return $fixturePath
}

$repetitiveLogPath = Initialize-RepetitiveLogFixture

# Builds additional deterministic corpus shapes required by the doctrine gate.
function Initialize-StructuredFixtures {
    $jsonlPath = Join-Path $repo ".zig-cache/min-verification-events.jsonl"
    $benchmarkPath = Join-Path $repo ".zig-cache/min-verification-benchmark.log"
    $prosePath = Join-Path $repo ".zig-cache/min-verification-low-redundancy.md"
    $jsonl = New-Object System.Collections.Generic.List[string]
    $bench = New-Object System.Collections.Generic.List[string]
    $prose = New-Object System.Collections.Generic.List[string]
    for ($index = 0; $index -lt 360; $index++) {
        $jsonl.Add((@{ ts = $index; kind = "heartbeat"; worker = 4; healthy = $true } | ConvertTo-Json -Compress))
        $bench.Add("round=$index route=literal matches=4096 elapsed_ms=12.750 status=ok")
        $prose.Add("Paragraph $index records a distinct observation about bounded evidence, source coordinates, deterministic selection, and failure honesty without repeating an exact sentence.")
        if ($index -eq 9) { $jsonl.Add('{"kind":"contract","code":"E_JSONL_17","must_preserve":true}') }
        if ($index -eq 174) { $jsonl.Add('{"kind":"owner","path":"src/core/min.zig","schema":"ix.min.v1"}') }
        if ($index -eq 351) { $jsonl.Add('{"kind":"failure","code":"min_budget_too_small","partial_stdout":false}') }
        if ($index -eq 11) { $bench.Add("BASELINE_FACT predecessor_sha=8e7c4f2 p50_ms=13.880") }
        if ($index -eq 179) { $bench.Add("PARITY_FACT matches=4096 route=literal binary_sha=4f12aa90") }
        if ($index -eq 348) { $bench.Add("DECISION_FACT candidate_p50_ms=12.750 improvement_pct=8.141") }
    }
    $prose.Insert(8, "EARLY_PROSE_FACT exact inspection remains the source-truth owner.")
    $prose.Insert(181, "MIDDLE_PROSE_FACT omission metadata must expose every missing source range.")
    $prose.Add("FINAL_PROSE_FACT compression ratio alone never proves retained knowledge is valuable.")
    [IO.File]::WriteAllLines($jsonlPath, $jsonl, (New-Object Text.UTF8Encoding($false)))
    [IO.File]::WriteAllLines($benchmarkPath, $bench, (New-Object Text.UTF8Encoding($false)))
    [IO.File]::WriteAllLines($prosePath, $prose, (New-Object Text.UTF8Encoding($false)))
    return [pscustomobject]@{ jsonl = $jsonlPath; benchmark = $benchmarkPath; prose = $prosePath }
}

$structuredFixtures = Initialize-StructuredFixtures

# Quotes one Windows process argument without delegating through a shell.
function ConvertTo-ProcessArgument {
    param([string]$Value)
    if ($Value -notmatch '[\s"]') { return $Value }
    return '"' + ($Value -replace '(\\*)"', '$1$1\"' -replace '(\\+)$', '$1$1') + '"'
}

# Captures exact stdout/stderr and elapsed time from one isolated process.
function Invoke-CapturedProcess {
    param([string]$FileName, [string[]]$Arguments)
    $start = New-Object System.Diagnostics.ProcessStartInfo
    $start.FileName = $FileName
    $start.Arguments = (($Arguments | ForEach-Object { ConvertTo-ProcessArgument $_ }) -join ' ')
    $start.WorkingDirectory = $repo
    $start.UseShellExecute = $false
    $start.CreateNoWindow = $true
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    $start.StandardOutputEncoding = [Text.Encoding]::UTF8
    $start.StandardErrorEncoding = [Text.Encoding]::UTF8
    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $start
    $clock = [Diagnostics.Stopwatch]::StartNew()
    [void]$process.Start()
    $stdoutTask = $process.StandardOutput.ReadToEndAsync()
    $stderrTask = $process.StandardError.ReadToEndAsync()
    [long]$peakWorkingSet = 0
    while (-not $process.HasExited) {
        try { $peakWorkingSet = [Math]::Max($peakWorkingSet, [Math]::Max($process.WorkingSet64, $process.PeakWorkingSet64)) } catch {}
        Start-Sleep -Milliseconds 5
    }
    $process.WaitForExit()
    $stdout = $stdoutTask.Result
    $stderr = $stderrTask.Result
    $clock.Stop()
    return [pscustomobject]@{
        exit_code = $process.ExitCode
        stdout = $stdout
        stderr = $stderr
        elapsed_ms = $clock.Elapsed.TotalMilliseconds
        peak_working_set_bytes = $peakWorkingSet
        output_bytes = [Text.Encoding]::UTF8.GetByteCount($stdout)
    }
}

# Scores exact required-fact retention; paraphrase cannot masquerade as source fidelity.
function Measure-Retention {
    param([string]$Text, [string[]]$Needles)
    $retained = @($Needles | Where-Object { $Text.Contains($_) })
    return [pscustomobject]@{
        required = $Needles.Count
        retained = $retained.Count
        recall = if ($Needles.Count -eq 0) { 1.0 } else { $retained.Count / $Needles.Count }
        missing = @($Needles | Where-Object { -not $Text.Contains($_) })
    }
}

$cases = @(
    [pscustomobject]@{
        name = "goal-doctrine"
        path = ".docs/goals/002-ix-min-context-compaction.md"
        native_level = "med"
        compactor_level = "balanced"
        max_bytes = 8192
        budget_tokens = 2048
        domain = "research"
        needles = @(
            'Research must prove that the knowledge is valuable.',
            'must not invoke the local intelligent-compactor skill by path',
            'never substring-cut unique retained material',
            'Use streaming or bounded-memory segmentation',
            'Compression ratio alone cannot select',
            'MCP only where the capability genuinely works'
        )
    },
    [pscustomobject]@{
        name = "search-owner"
        path = "src/core/search.zig"
        native_level = "med"
        compactor_level = "balanced"
        max_bytes = 16384
        budget_tokens = 4096
        domain = "code"
        needles = @(
            'pub fn run(io: std.Io, allocator: std.mem.Allocator',
            'pub const MAX_RETAINED_HITS = 4096;',
            'const WARM_QUERY_CACHE_MAGIC = "IXQUERY_FRONTIER1";',
            'Spawning 32 threads for 100 files adds ~3 ms',
            'Maps the entire file via NtCreateSection/NtMapViewOfSection',
            'const CASEFOLD_LINE_MAX = 2 * 1024;'
        )
    },
    [pscustomobject]@{
        name = "product-readme"
        path = "README.md"
        native_level = "med"
        compactor_level = "balanced"
        max_bytes = 16384
        budget_tokens = 4096
        domain = "code"
        needles = @(
            'ix min low path/to/large.log --max-bytes 32768',
            'ix min med src/core/search.zig',
            'ix min high path/to/report.md --max-bytes 8192 --format json',
            'IX_MEMORY_PERCENT=15 IX_THREAD_PERCENT=50 ix search',
            '### Strategy Routing',
            '### Tiered contraction'
        )
    },
    [pscustomobject]@{
        name = "operations-ledger"
        path = ".docs/log.md"
        native_level = "med"
        compactor_level = "balanced"
        max_bytes = 16384
        budget_tokens = 4096
        domain = "research"
        needles = @(
            '## 2026-07-15 - Tracked-index-only `.refs` collection',
            '## 2026-07-15 - Pass 018 condensed-changelog runtime-truth audit',
            '## 2026-07-13 - QC pass 001: max-2-words stress closure',
            '## 2026-07-12 - Post-byteset benchmark: +6.69% engine improvement',
            '## 2026-07-15 - Native promotion closure',
            '## 2026-07-16 - Native bounded-context compaction research and plan'
        )
    },
    [pscustomobject]@{
        name = "repetitive-generated-log"
        path = $repetitiveLogPath
        native_level = "med"
        compactor_level = "balanced"
        max_bytes = 8192
        budget_tokens = 2048
        domain = "research"
        needles = @(
            'BOUNDARY_FACT alpha admission rejects binary input before scoring',
            'RECOVERY_FACT beta retry ceiling is exactly 3 attempts',
            'OWNER_FACT gamma src/core/min.zig owns bounded compaction',
            'ERROR_FACT delta min_budget_too_small preserves honest failure',
            'PROOF_FACT epsilon output_bytes equals serialized UTF-8 bytes',
            'FINAL_FACT zeta source order survives selection'
        )
    },
    [pscustomobject]@{
        name = "structured-jsonl"
        path = $structuredFixtures.jsonl
        native_level = "med"
        compactor_level = "balanced"
        max_bytes = 8192
        budget_tokens = 2048
        domain = "research"
        needles = @(
            '"code":"E_JSONL_17"',
            '"path":"src/core/min.zig"',
            '"schema":"ix.min.v1"',
            '"code":"min_budget_too_small"',
            '"partial_stdout":false'
        )
    },
    [pscustomobject]@{
        name = "benchmark-journal"
        path = $structuredFixtures.benchmark
        native_level = "med"
        compactor_level = "balanced"
        max_bytes = 8192
        budget_tokens = 2048
        domain = "benchmark"
        needles = @(
            'BASELINE_FACT predecessor_sha=8e7c4f2 p50_ms=13.880',
            'PARITY_FACT matches=4096 route=literal binary_sha=4f12aa90',
            'DECISION_FACT candidate_p50_ms=12.750 improvement_pct=8.141'
        )
    },
    [pscustomobject]@{
        name = "low-redundancy-prose"
        path = $structuredFixtures.prose
        native_level = "med"
        compactor_level = "balanced"
        max_bytes = 8192
        budget_tokens = 2048
        domain = "research"
        needles = @(
            'EARLY_PROSE_FACT exact inspection remains the source-truth owner.',
            'MIDDLE_PROSE_FACT omission metadata must expose every missing source range.',
            'FINAL_PROSE_FACT compression ratio alone never proves retained knowledge is valuable.'
        )
    }
)

$results = @()
foreach ($case in $cases) {
    $casePath = if ([IO.Path]::IsPathRooted($case.path)) { $case.path } else { Join-Path $repo $case.path }
    $sourcePath = (Resolve-Path $casePath).Path
    $native = Invoke-CapturedProcess $candidatePath @("min", $case.native_level, $sourcePath, "--max-bytes", [string]$case.max_bytes, "--format", "json")
    $lowRun = Invoke-CapturedProcess $candidatePath @("min", "low", $sourcePath, "--max-bytes", "32768", "--format", "json")
    $highBudget = [Math]::Min([int]$case.max_bytes, 8192)
    $highRun = Invoke-CapturedProcess $candidatePath @("min", "high", $sourcePath, "--max-bytes", [string]$highBudget, "--format", "json")
    $compactorRun = Invoke-CapturedProcess $pythonPath @($compactorPath, "--input", $sourcePath, "--aggressiveness", $case.compactor_level, "--domain", $case.domain, "--budget-tokens", [string]$case.budget_tokens, "--output", "read")
    $sourceText = [IO.File]::ReadAllText($sourcePath)
    $prefix = if ($sourceText.Length -le $case.max_bytes) { $sourceText } else { $sourceText.Substring(0, $case.max_bytes) }
    $nativeEnvelope = if ($native.exit_code -eq 0) { $native.stdout | ConvertFrom-Json } else { $null }
    $nativeEvidence = if ($null -ne $nativeEnvelope) { [string](($nativeEnvelope.units | ForEach-Object { $_.content }) -join "`n") } else { $native.stdout }
    $nativeRetention = Measure-Retention $nativeEvidence $case.needles
    $compactorRetention = Measure-Retention $compactorRun.stdout $case.needles
    $prefixRetention = Measure-Retention $prefix $case.needles
    $lowEnvelope = if ($lowRun.exit_code -eq 0) { $lowRun.stdout | ConvertFrom-Json } else { $null }
    $highEnvelope = if ($highRun.exit_code -eq 0) { $highRun.stdout | ConvertFrom-Json } else { $null }
    $lowEvidence = if ($lowEnvelope) { [string](($lowEnvelope.units | ForEach-Object { $_.content }) -join "`n") } else { $lowRun.stdout }
    $highEvidence = if ($highEnvelope) { [string](($highEnvelope.units | ForEach-Object { $_.content }) -join "`n") } else { $highRun.stdout }
    $nativeLossy = $null
    if ($null -ne $nativeEnvelope) { $nativeLossy = [bool]$nativeEnvelope.lossy }
    $nativeError = if ($null -eq $native.stderr) { "" } else { [string]$native.stderr }
    $compactorError = if ($null -eq $compactorRun.stderr) { "" } else { [string]$compactorRun.stderr }
    $results += [pscustomobject]@{
        name = $case.name
        path = $case.path
        input_bytes = (Get-Item $sourcePath).Length
        required_facts = $case.needles
        native = [pscustomobject]@{
            exit_code = $native.exit_code
            elapsed_ms = [Math]::Round($native.elapsed_ms, 3)
            peak_working_set_bytes = $native.peak_working_set_bytes
            output_bytes = $native.output_bytes
            within_budget = ($native.output_bytes -le $case.max_bytes)
            valid = ($native.exit_code -eq 0 -and $native.output_bytes -le $case.max_bytes -and $null -ne $nativeEnvelope)
            declared_output_bytes = if ($nativeEnvelope) { $nativeEnvelope.output_bytes } else { $null }
            retained_units = if ($nativeEnvelope) { $nativeEnvelope.retained_units } else { $null }
            omitted_units = if ($nativeEnvelope) { $nativeEnvelope.omitted_units } else { $null }
            lossy = $nativeLossy
            retention = $nativeRetention
            stderr = $nativeError.Trim()
        }
        native_profiles = @(
            [pscustomobject]@{ level = "low"; max_bytes = 32768; exit_code = $lowRun.exit_code; output_bytes = $lowRun.output_bytes; peak_working_set_bytes = $lowRun.peak_working_set_bytes; valid = ($lowRun.exit_code -eq 0 -and $lowRun.output_bytes -le 32768); retention = (Measure-Retention $lowEvidence $case.needles) },
            [pscustomobject]@{ level = $case.native_level; max_bytes = $case.max_bytes; exit_code = $native.exit_code; output_bytes = $native.output_bytes; peak_working_set_bytes = $native.peak_working_set_bytes; valid = ($native.exit_code -eq 0 -and $native.output_bytes -le $case.max_bytes); retention = $nativeRetention },
            [pscustomobject]@{ level = "high"; max_bytes = $highBudget; exit_code = $highRun.exit_code; output_bytes = $highRun.output_bytes; peak_working_set_bytes = $highRun.peak_working_set_bytes; valid = ($highRun.exit_code -eq 0 -and $highRun.output_bytes -le $highBudget); retention = (Measure-Retention $highEvidence $case.needles) }
        )
        intelligent_compactor = [pscustomobject]@{
            exit_code = $compactorRun.exit_code
            elapsed_ms = [Math]::Round($compactorRun.elapsed_ms, 3)
            peak_working_set_bytes = $compactorRun.peak_working_set_bytes
            output_bytes = $compactorRun.output_bytes
            within_budget = ($compactorRun.output_bytes -le $case.max_bytes)
            valid = ($compactorRun.exit_code -eq 0 -and $compactorRun.output_bytes -le $case.max_bytes)
            retention = $compactorRetention
            stderr = $compactorError.Trim()
        }
        prefix_baseline = [pscustomobject]@{
            character_budget = $case.max_bytes
            retention = $prefixRetention
        }
    }
}

$report = [pscustomobject]@{
    schema = "ix.min-verification.v1"
    generated_at = (Get-Date).ToUniversalTime().ToString("o")
    candidate = $candidatePath
    candidate_sha256 = (Get-FileHash -Algorithm SHA256 $candidatePath).Hash
    compactor = $compactorPath
    host = [pscustomobject]@{
        os = [Environment]::OSVersion.VersionString
        powershell = $PSVersionTable.PSVersion.ToString()
    }
    interpretation = "Exact required-fact retention is measured under case-specific byte budgets and approximately equivalent four-bytes-per-token comparator budgets. Invalid or over-budget runs cannot win. Size reduction alone is not a pass criterion."
    cases = $results
}

$resolvedOutput = Join-Path $repo $OutputPath
$outputDir = Split-Path -Parent $resolvedOutput
if (-not (Test-Path $outputDir)) { New-Item -ItemType Directory -Path $outputDir | Out-Null }
$report | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $resolvedOutput -Encoding UTF8
Write-Output $resolvedOutput
