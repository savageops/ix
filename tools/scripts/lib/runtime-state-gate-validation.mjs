import { existsSync, mkdirSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { spawnSync } from "node:child_process";
import os from "node:os";
import path from "node:path";

export function createRuntimeStateGateValidation({
  root,
  stateDir,
  speedOnly,
  run,
  lane,
  psQuote,
  findBuiltIx,
  resolveZigExe,
}) {
  function warmIndexLane() {
    if (speedOnly) return lane("warm_index_live", "skipped", { reason: "--speed-only" });
    const ix = findBuiltIx();
    if (!ix) return lane("warm_index_live", "skipped", { reason: "zig-out binary missing; run build first" });
    const root = path.join(os.tmpdir(), `ix-warm-index-root-${process.pid}`);
    rmSync(root, { recursive: true, force: true });
    mkdirSync(root, { recursive: true });
    writeFileSync(path.join(root, "a.zig"), "pub const needle = \"needle\";\n");
    writeFileSync(path.join(root, "b.zig"), "pub fn main() void { _ = \"haystack\"; }\n");

    const script = `
  $ErrorActionPreference = 'Continue'
  $ix = ${psQuote(ix)}
  $root = ${psQuote(root)}
  $stateDir = ${psQuote(stateDir)}
  $env:IX_STATE_DIR = $stateDir
  $env:IX_INDEXD_MEMORY_LIMIT_MB = '256'
  $owner = Start-Process -FilePath $ix -ArgumentList @('__ix_indexd', $root, '--foreground') -PassThru -WindowStyle Hidden
  try {
    $live = $null
    $current = $null
    $catalog = $null
    $postings = $null
    for ($i = 0; $i -lt 80; $i++) {
      $live = Get-ChildItem -LiteralPath $stateDir -Recurse -Force -Filter 'index.live' -ErrorAction SilentlyContinue | Select-Object -First 1
      if ($live) {
        $indexDir = Split-Path -Parent $live.FullName
        $current = Get-ChildItem -LiteralPath $indexDir -Force -Filter 'current.ixgen' -ErrorAction SilentlyContinue | Select-Object -First 1
        $catalog = Get-ChildItem -LiteralPath $indexDir -Recurse -Force -Filter 'catalog.ixcat' -ErrorAction SilentlyContinue | Select-Object -First 1
        $postings = Get-ChildItem -LiteralPath $indexDir -Recurse -Force -Filter 'postings.ixpost' -ErrorAction SilentlyContinue | Select-Object -First 1
      }
      if ($live -and $current -and $catalog -and $postings) { break }
      Start-Sleep -Milliseconds 100
    }
    if (-not $live) {
      [pscustomobject]@{ status = 'no_live_marker'; ownerPid = $owner.Id } | ConvertTo-Json -Compress
      exit 2
    }
    if (-not $current) {
      [pscustomobject]@{ status = 'no_current_generation'; ownerPid = $owner.Id; liveMarker = $live.FullName } | ConvertTo-Json -Compress
      exit 3
    }
    if (-not $catalog -or -not $postings) {
      [pscustomobject]@{ status = 'no_generation_payloads'; ownerPid = $owner.Id; liveMarker = $live.FullName; currentGeneration = $current.FullName } | ConvertTo-Json -Compress
      exit 4
    }
    $env:IX_INDEX = '1'
    $env:IX_NEXUS = '0'
    $json = $null
    $searchAttempts = 0
    for ($i = 0; $i -lt 40; $i++) {
      $searchAttempts = $i + 1
      $out = & $ix search 'lit:needle' $root --json --max-hits 0
      $json = $out | ConvertFrom-Json
      $refresh = $json.stats.generation_refresh
      if ($refresh.available -eq $true -and @('live_pinned', 'live_query_cache', 'live_query_hits_cache', 'live_query_stats_cache') -contains $refresh.refresh_status) { break }
      Start-Sleep -Milliseconds 100
    }
    $refresh = $json.stats.generation_refresh
    [pscustomobject]@{
      status = 'ok'
      ownerPid = $owner.Id
      searchAttempts = $searchAttempts
      liveMarker = $live.FullName
      currentGeneration = $current.FullName
      catalog = $catalog.FullName
      postings = $postings.FullName
      refreshStatus = $refresh.refresh_status
      refreshAvailable = $refresh.available
      filesDiscovered = $json.stats.files_discovered
      filesScanned = $json.stats.files_scanned
      matchesFound = $json.stats.matches_found
      catalogAvailable = $json.stats.catalog_index.available
      postingsAvailable = $json.stats.postings_index.available
    } | ConvertTo-Json -Compress
  } finally {
    Get-CimInstance Win32_Process | Where-Object { $_.ProcessId -ne $PID -and $_.CommandLine -and $_.CommandLine.Contains($root) -and ($_.CommandLine.Contains('__ix_indexd') -or $_.Name -match '^(ix|iex|ix-zig)(\\.exe)?$') } | ForEach-Object {
      Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue
    }
    Stop-Process -Id $owner.Id -Force -ErrorAction SilentlyContinue
  }
  exit 0
  `;
    const probe = run("powershell", ["-NoProfile", "-Command", script]);
    rmSync(root, { recursive: true, force: true });
    let parsed;
    try {
      parsed = JSON.parse(probe.stdout || "{}");
    } catch {
      return lane("warm_index_live", "failed", { evidence: probe, reason: "warm index probe did not emit JSON" });
    }
    const failures = [];
    if (parsed.status !== "ok") failures.push(parsed.status ?? `powershell exited ${probe.exitCode}`);
    if (parsed.refreshAvailable !== true) failures.push("generation refresh was not available");
    if (!["live_pinned", "live_query_cache", "live_query_hits_cache", "live_query_stats_cache"].includes(parsed.refreshStatus)) {
      failures.push(`unexpected refresh status ${parsed.refreshStatus}`);
    }
    if (parsed.matchesFound !== 1) failures.push(`expected 1 match, got ${parsed.matchesFound}`);
    if (parsed.filesDiscovered < 1) failures.push("no files discovered");
    if (parsed.catalogAvailable !== true) failures.push("catalog index did not report available");
    if (parsed.postingsAvailable !== true) failures.push("postings index did not report available");
    return lane("warm_index_live", failures.length === 0 ? "ok" : "failed", {
      evidence: probe,
      parsed,
      failures,
    });
  }

  function generationRecoveryLane() {
    if (speedOnly) return lane("generation_recovery", "skipped", { reason: "--speed-only" });
    const ix = findBuiltIx();
    if (!ix) return lane("generation_recovery", "skipped", { reason: "zig-out binary missing; run build first" });
    const root = path.join(os.tmpdir(), `ix-generation-recovery-root-${process.pid}`);
    const localState = path.join(os.tmpdir(), `ix-generation-recovery-state-${process.pid}`);
    rmSync(root, { recursive: true, force: true });
    rmSync(localState, { recursive: true, force: true });
    mkdirSync(root, { recursive: true });
    writeFileSync(path.join(root, "needle.zig"), "pub const token = \"needle\";\n");
    writeFileSync(path.join(root, "other.zig"), "pub fn main() void { _ = \"haystack\"; }\n");

    const script = `
  $ErrorActionPreference = 'Continue'
  $ix = ${psQuote(ix)}
  $root = ${psQuote(root)}
  $stateDir = ${psQuote(localState)}
  $env:IX_STATE_DIR = $stateDir
  $env:IX_INDEXD_MEMORY_LIMIT_MB = '256'
  $env:IX_INDEX = '1'
  $env:IX_NEXUS = '0'
  $owner = $null

  function Publish-Generation {
    & $ix @('__ix_indexd', $root, '--foreground', '--once') | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "publish exited $LASTEXITCODE" }
  }

  function Stop-Owner {
    if ($owner -and -not $owner.HasExited) {
      Stop-Process -Id $owner.Id -Force -ErrorAction SilentlyContinue
      Wait-Process -Id $owner.Id -Timeout 2 -ErrorAction SilentlyContinue
    }
    Get-ChildItem -LiteralPath $stateDir -Recurse -Force -Filter 'index.live' -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue
    $script:owner = $null
  }

  function Start-Owner {
    Stop-Owner
    $script:owner = Start-Process -FilePath $ix -ArgumentList @('__ix_indexd', $root, '--foreground') -PassThru -WindowStyle Hidden
    for ($i = 0; $i -lt 120; $i++) {
      $live = Get-ChildItem -LiteralPath $stateDir -Recurse -Force -Filter 'index.live' -ErrorAction SilentlyContinue | Where-Object {
        (Get-Content -LiteralPath $_.FullName -Raw -ErrorAction SilentlyContinue) -match "pid=$($script:owner.Id)"
      } | Select-Object -First 1
      $current = Get-ChildItem -LiteralPath $stateDir -Recurse -Force -Filter 'current.ixgen' -ErrorAction SilentlyContinue | Select-Object -First 1
      if ($live -and $current) { return }
      if ($script:owner.HasExited) { throw "owner exited $($script:owner.ExitCode)" }
      Start-Sleep -Milliseconds 100
    }
    throw 'owner did not publish live generation'
  }

  function Current-Generation-Files {
    $current = Get-ChildItem -LiteralPath $stateDir -Recurse -Force -Filter 'current.ixgen' -ErrorAction SilentlyContinue | Sort-Object LastWriteTimeUtc -Descending | Select-Object -First 1
    if (-not $current) { throw 'missing current.ixgen' }
    $indexDir = Split-Path -Parent $current.FullName
    $generationDir = Get-ChildItem -LiteralPath (Join-Path $indexDir 'generations') -Directory -Force -ErrorAction SilentlyContinue | Sort-Object { [UInt64]$_.Name } -Descending | Select-Object -First 1
    if (-not $generationDir) { throw 'missing generation payload directory' }
    [pscustomobject]@{
      current = $current.FullName
      indexDir = $indexDir
      generationDir = $generationDir.FullName
      catalog = Join-Path $generationDir.FullName 'catalog.ixcat'
      postings = Join-Path $generationDir.FullName 'postings.ixpost'
    }
  }

  function Search-Needle {
    $out = & $ix search 'lit:needle' $root --json --stats-only
    $json = $out | ConvertFrom-Json
    [pscustomobject]@{
      status = $json.status
      matches = $json.stats.matches_found
      filesScanned = $json.stats.files_scanned
      refreshStatus = $json.stats.generation_refresh.refresh_status
      refreshAvailable = $json.stats.generation_refresh.available
      fallbackReason = $json.stats.generation_refresh.fallback_reason
    }
  }

  try {
    Start-Owner
    $initial = Search-Needle

    $files = Current-Generation-Files
    [System.IO.File]::WriteAllText($files.current, 'bad')
    $corruptManifest = Search-Needle

    Stop-Owner
    Publish-Generation
    Start-Owner
    $afterManifestRepair = Search-Needle

    $files = Current-Generation-Files
    Remove-Item -LiteralPath $files.postings -Force
    $missingSegment = Search-Needle

    Stop-Owner
    Publish-Generation
    Start-Owner
    $afterMissingRepair = Search-Needle

    $files = Current-Generation-Files
    $catalogBytes = [System.IO.File]::ReadAllBytes($files.catalog)
    if ($catalogBytes.Length -lt 1) { throw 'empty catalog fixture' }
    $catalogBytes[0] = $catalogBytes[0] -bxor 1
    [System.IO.File]::WriteAllBytes($files.catalog, $catalogBytes)
    $checksumMismatch = Search-Needle

    Stop-Owner
    Publish-Generation
    Start-Owner
    $final = Search-Needle

    [pscustomobject]@{
      status = 'ok'
      initial = $initial
      corruptManifest = $corruptManifest
      afterManifestRepair = $afterManifestRepair
      missingSegment = $missingSegment
      afterMissingRepair = $afterMissingRepair
      checksumMismatch = $checksumMismatch
      final = $final
    } | ConvertTo-Json -Compress -Depth 20
  } catch {
    [pscustomobject]@{ status = 'error'; message = $_.Exception.Message } | ConvertTo-Json -Compress
    exit 2
  } finally {
    Stop-Owner
    Get-CimInstance Win32_Process | Where-Object { $_.ProcessId -ne $PID -and $_.CommandLine -and $_.CommandLine.Contains($root) -and ($_.CommandLine.Contains('__ix_indexd') -or $_.Name -match '^(ix|iex|ix-zig)(\\.exe)?$') } | ForEach-Object {
      Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue
    }
  }
  exit 0
  `;
    const probe = run("powershell", ["-NoProfile", "-Command", script]);
    rmSync(root, { recursive: true, force: true });
    rmSync(localState, { recursive: true, force: true });

    let parsed;
    try {
      parsed = JSON.parse(probe.stdout || "{}");
    } catch {
      return lane("generation_recovery", "failed", { evidence: probe, reason: "generation recovery probe did not emit JSON" });
    }

    const failures = [];
    const expectWarmOk = (name, value) => {
      if (value?.status !== "ok") failures.push(`${name}.status expected ok`);
      if (value?.matches !== 1) failures.push(`${name}.matches expected 1, got ${value?.matches}`);
      if (value?.refreshAvailable !== true) failures.push(`${name}.refreshAvailable expected true`);
      if (!["live_pinned", "live_query_stats_cache"].includes(value?.refreshStatus)) {
        failures.push(`${name}.refreshStatus expected live_pinned/live_query_stats_cache, got ${value?.refreshStatus}`);
      }
    };
    const expectFallback = (name, value, reason) => {
      if (value?.status !== "ok") failures.push(`${name}.status expected ok`);
      if (value?.matches !== 1) failures.push(`${name}.matches expected cold fallback 1, got ${value?.matches}`);
      if (value?.refreshAvailable !== false) failures.push(`${name}.refreshAvailable expected false`);
      if (value?.refreshStatus !== "fallback") failures.push(`${name}.refreshStatus expected fallback, got ${value?.refreshStatus}`);
      if (value?.fallbackReason !== reason) failures.push(`${name}.fallbackReason expected ${reason}, got ${value?.fallbackReason}`);
    };

    if (probe.exitCode !== 0) failures.push(`powershell exited ${probe.exitCode}`);
    if (parsed.status !== "ok") failures.push(parsed.message ?? parsed.status ?? "probe status not ok");
    expectWarmOk("initial", parsed.initial);
    expectFallback("corruptManifest", parsed.corruptManifest, "TruncatedGenerationManifest");
    expectWarmOk("afterManifestRepair", parsed.afterManifestRepair);
    expectFallback("missingSegment", parsed.missingSegment, "MissingGenerationSegment");
    expectWarmOk("afterMissingRepair", parsed.afterMissingRepair);
    expectFallback("checksumMismatch", parsed.checksumMismatch, "GenerationSegmentChecksumMismatch");
    expectWarmOk("final", parsed.final);

    return lane("generation_recovery", failures.length === 0 ? "ok" : "failed", {
      evidence: probe,
      parsed,
      failures,
    });
  }

  function runtimeStateLocationLane() {
    if (speedOnly) return lane("runtime_state_location", "skipped", { reason: "--speed-only" });
    const ix = findBuiltIx();
    if (!ix) return lane("runtime_state_location", "skipped", { reason: "zig-out binary missing; run build first" });
    const root = path.join(os.tmpdir(), `ix-state-location-root-${process.pid}`);
    const localState = path.join(os.tmpdir(), `ix-state-location-state-${process.pid}`);
    rmSync(root, { recursive: true, force: true });
    rmSync(localState, { recursive: true, force: true });
    mkdirSync(root, { recursive: true });
    writeFileSync(path.join(root, "needle.zig"), "pub const needle = \"needle\";\n");
    writeFileSync(path.join(root, "other.zig"), "pub fn main() void { _ = \"haystack\"; }\n");

    const script = `
  $ErrorActionPreference = 'Continue'
  $ix = ${psQuote(ix)}
  $root = ${psQuote(root)}
  $stateDir = ${psQuote(localState)}
  $env:IX_STATE_DIR = $stateDir
  $env:IX_INDEXD_MEMORY_LIMIT_MB = '256'
  $owner = Start-Process -FilePath $ix -ArgumentList @('__ix_indexd', $root, '--foreground') -PassThru -WindowStyle Hidden
  try {
    $live = $null
    for ($i = 0; $i -lt 80; $i++) {
      $live = Get-ChildItem -LiteralPath $stateDir -Recurse -Force -Filter 'index.live' -ErrorAction SilentlyContinue | Select-Object -First 1
      if ($live) { break }
      Start-Sleep -Milliseconds 100
    }
    $env:IX_INDEX = '1'
    $env:IX_NEXUS = '0'
    $firstOut = & $ix search 'lit:needle' $root --json --max-hits 1
    $secondOut = & $ix search 'lit:needle' $root --json --max-hits 1
    $repair = & $ix __ix_indexd $root --foreground --once --repair
    $rootIx = Join-Path $root '.ix'
    $stateMarkers = @(Get-ChildItem -LiteralPath $stateDir -Recurse -Force -ErrorAction SilentlyContinue | Where-Object { $_.Name -in @('index.live', 'current.ixgen', 'repair.state') } | Select-Object -ExpandProperty FullName)
    $queryFiles = @(Get-ChildItem -LiteralPath $stateDir -Recurse -Force -Filter '*.ixq' -ErrorAction SilentlyContinue | Select-Object -ExpandProperty FullName)
    $first = $firstOut | ConvertFrom-Json
    $second = $secondOut | ConvertFrom-Json
    [pscustomobject]@{
      status = 'ok'
      rootIxExists = Test-Path -LiteralPath $rootIx
      rootIxIndexExists = Test-Path -LiteralPath (Join-Path $rootIx 'index')
      liveMarker = if ($live) { $live.FullName } else { $null }
      stateMarkers = $stateMarkers
      queryFiles = $queryFiles
      firstRefreshStatus = $first.stats.generation_refresh.refresh_status
      secondRefreshStatus = $second.stats.generation_refresh.refresh_status
      secondMatchesFound = $second.stats.matches_found
      repairExitCode = $LASTEXITCODE
    } | ConvertTo-Json -Compress
  } finally {
    Get-CimInstance Win32_Process | Where-Object { $_.ProcessId -ne $PID -and $_.CommandLine -and $_.CommandLine.Contains($root) -and ($_.CommandLine.Contains('__ix_indexd') -or $_.Name -match '^(ix|iex|ix-zig)(\\.exe)?$') } | ForEach-Object {
      Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue
    }
    Stop-Process -Id $owner.Id -Force -ErrorAction SilentlyContinue
  }
  exit 0
  `;
    const probe = run("powershell", ["-NoProfile", "-Command", script]);
    let parsed;
    try {
      parsed = JSON.parse(probe.stdout || "{}");
    } catch {
      rmSync(root, { recursive: true, force: true });
      rmSync(localState, { recursive: true, force: true });
      return lane("runtime_state_location", "failed", { evidence: probe, reason: "state-location probe did not emit JSON" });
    }

    const nativeProbe = run(resolveZigExe(), ["build", "test", "--summary", "all"], {
      env: {
        IX_INDEX: "0",
        IX_NEXUS: "0",
        IX_STATE_DIR: localState,
      },
    });
    const failures = [];
    if (probe.exitCode !== 0) failures.push(`powershell exited ${probe.exitCode}`);
    if (parsed.rootIxExists) failures.push("runtime created .ix under scanned root");
    if (parsed.rootIxIndexExists) failures.push("runtime created .ix/index under scanned root");
    if (!parsed.liveMarker || !String(parsed.liveMarker).startsWith(localState)) failures.push("live marker was not under IX_STATE_DIR");
    if (!Array.isArray(parsed.stateMarkers) || parsed.stateMarkers.length === 0) failures.push("no state markers were written under IX_STATE_DIR");
    if (!Array.isArray(parsed.queryFiles) || parsed.queryFiles.length === 0) failures.push("warm query cache was not written under IX_STATE_DIR");
    if (parsed.secondMatchesFound !== 1) failures.push(`expected cached search to find 1 match, got ${parsed.secondMatchesFound}`);
    if (nativeProbe.exitCode !== 0) failures.push("native root-helper test pass failed");

    rmSync(root, { recursive: true, force: true });
    rmSync(localState, { recursive: true, force: true });
    return lane("runtime_state_location", failures.length === 0 ? "ok" : "failed", {
      evidence: { runtime: probe, nativeProbe },
      parsed,
      failures,
    });
  }

  function defaultStateLocationLane() {
    if (speedOnly) return lane("default_state_location", "skipped", { reason: "--speed-only" });
    const ix = findBuiltIx();
    if (!ix) return lane("default_state_location", "skipped", { reason: "zig-out binary missing; run build first" });
    if (process.platform !== "win32") {
      return lane("default_state_location", "skipped", { reason: "default AppData state probe is currently implemented for Windows only" });
    }

    const base = path.join(os.tmpdir(), `ix-default-state-location-${process.pid}`);
    const localAppData = path.join(base, "localappdata");
    const rootA = path.join(base, "root-a");
    const rootB = path.join(base, "root-b");
    const cwdA = path.join(base, "cwd-a");
    const cwdB = path.join(base, "cwd-b");
    rmSync(base, { recursive: true, force: true });
    for (const dir of [localAppData, rootA, rootB, cwdA, cwdB]) mkdirSync(dir, { recursive: true });
    writeFileSync(path.join(rootA, "a.txt"), "needle a\n");
    writeFileSync(path.join(rootB, "b.txt"), "needle b\n");

    const env = {
      LOCALAPPDATA: localAppData,
      IX_STATE_DIR: undefined,
      IX_INDEXD_MEMORY_LIMIT_MB: "256",
    };
    const first = run(ix, ["__ix_indexd", rootA, "--foreground", "--once"], { cwd: cwdA, env });
    const second = run(ix, ["__ix_indexd", rootB, "--foreground", "--once"], { cwd: cwdB, env });
    const stateRoot = path.join(localAppData, "iEx", "ix");
    const currentMarkers = findFilesByName(stateRoot, "current.ixgen");
    const failures = [];
    if (first.exitCode !== 0) failures.push(`first default-state indexd exited ${first.exitCode}`);
    if (second.exitCode !== 0) failures.push(`second default-state indexd exited ${second.exitCode}`);
    if (!existsSync(stateRoot)) failures.push("default state root was not created under LOCALAPPDATA/iEx/ix");
    if (currentMarkers.length < 2) failures.push(`expected at least 2 current.ixgen markers under default state root, got ${currentMarkers.length}`);
    if (existsSync(path.join(rootA, ".ix"))) failures.push("first scanned root received .ix state");
    if (existsSync(path.join(rootB, ".ix"))) failures.push("second scanned root received .ix state");
    if (currentMarkers.some((marker) => !marker.startsWith(stateRoot))) failures.push("default markers escaped the resolved state root");

    rmSync(base, { recursive: true, force: true });
    return lane("default_state_location", failures.length === 0 ? "ok" : "failed", {
      evidence: { first, second },
      stateRoot,
      currentMarkers,
      cwdA,
      cwdB,
      failures,
    });
  }

  function findFilesByName(root, name, found = []) {
    if (!existsSync(root)) return found;
    const entries = spawnSync("powershell", [
      "-NoProfile",
      "-Command",
      `Get-ChildItem -LiteralPath ${JSON.stringify(root)} -Recurse -Force -Filter ${JSON.stringify(name)} | Select-Object -ExpandProperty FullName`,
    ], {
      cwd: root,
      encoding: "utf8",
      maxBuffer: 8 * 1024 * 1024,
      windowsHide: true,
    });
    if (entries.status !== 0) return found;
    for (const line of (entries.stdout ?? "").split(/\r?\n/)) {
      const trimmed = line.trim();
      if (trimmed) found.push(trimmed);
    }
    return found;
  }

  function memoryCapLane() {
    if (speedOnly) return lane("indexd_memory_cap", "skipped", { reason: "--speed-only" });
    const ix = findBuiltIx();
    if (!ix) return lane("indexd_memory_cap", "skipped", { reason: "zig-out binary missing; run build first" });
    const root = path.join(os.tmpdir(), `ix-memory-cap-root-${process.pid}`);
    rmSync(root, { recursive: true, force: true });
    mkdirSync(root, { recursive: true });
    writeFileSync(path.join(root, "sample.zig"), "pub fn main() void { @import(\"std\").debug.print(\"memory cap\", .{}); }\n");
    const probe = run(ix, ["__ix_indexd", root, "--foreground", "--once"], {
      env: {
        IX_STATE_DIR: stateDir,
        IX_INDEXD_MEMORY_LIMIT_MB: "1",
      },
    });
    const repairFiles = findFilesByName(stateDir, "repair.state");
    const repairContents = repairFiles.map((file) => ({ file, contents: readFileSync(file, "utf8") }));
    const hasMarker = repairContents.some((entry) => entry.contents.includes("memory_budget_exceeded"));
    rmSync(root, { recursive: true, force: true });
    return lane("indexd_memory_cap", hasMarker ? "ok" : "failed", {
      evidence: probe,
      repairFiles: repairContents,
      expectedExit: "nonzero is acceptable when memory cap rejects publication",
    });
  }

  return {
    defaultStateLocationLane,
    generationRecoveryLane,
    memoryCapLane,
    runtimeStateLocationLane,
    warmIndexLane,
  };
}
