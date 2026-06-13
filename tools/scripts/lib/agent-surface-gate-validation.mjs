import { existsSync, mkdirSync, rmSync, writeFileSync } from "node:fs";
import os from "node:os";
import path from "node:path";

export function createAgentSurfaceGateValidation({
  stateDir,
  speedOnly,
  quick,
  run,
  lane,
  psQuote,
  findBuiltIx,
  resolveZigExe,
}) {
  function agentDryRunLane() {
    if (speedOnly) return lane("agent_real_dry_run", "skipped", { reason: "--speed-only" });
    const agent = run(process.execPath, ["tools/scripts/ix-agent-real-eval.mjs", "--dry-run"]);
    return lane("agent_real_dry_run", agent.exitCode === 0 ? "ok" : "failed", { evidence: agent });
  }

  function agentRealLane() {
    if (quick) return lane("agent_real", "skipped", { reason: "--quick" });
    if (speedOnly) return lane("agent_real", "skipped", { reason: "--speed-only" });
    const agent = run(process.execPath, ["tools/scripts/ix-agent-real-eval.mjs"]);
    if (agent.exitCode !== 0) return lane("agent_real", "failed", { evidence: agent });
    let parsed;
    try {
      parsed = JSON.parse(agent.stdout || "{}");
    } catch {
      return lane("agent_real", "failed", { evidence: agent, reason: "agent eval output was not JSON" });
    }
    const score = {
      recall: parsed.recall ?? null,
      architectureRecall: parsed.architectureRecall ?? null,
      toolDiscipline: parsed.toolDiscipline ?? null,
    };
    if (parsed.status === "ok") return lane("agent_real", "ok", { evidence: agent, statusDetail: parsed.status, score });
    if (parsed.status === "missing_config" || parsed.status === "missing_curl") {
      return lane("agent_real", "failed", {
        evidence: agent,
        statusDetail: parsed.status,
        reason: parsed.message,
        score,
      });
    }
    return lane("agent_real", "failed", { evidence: agent, statusDetail: parsed.status, score });
  }

  function buildLane() {
    if (speedOnly) return lane("zig_test", "skipped", { reason: "--speed-only" });
    if (quick) return lane("zig_test", "skipped", { reason: "--quick" });
    const test = run(resolveZigExe(), ["build", "test", "--summary", "all"], {
      env: {
        IX_INDEX: "0",
        IX_NEXUS: "0",
        IX_STATE_DIR: stateDir,
      },
    });
    return lane("zig_test", test.exitCode === 0 ? "ok" : "failed", { evidence: test });
  }

  function smokeLane() {
    if (speedOnly) return lane("cold_smoke", "skipped", { reason: "--speed-only" });
    const ix = findBuiltIx();
    if (!ix) return lane("cold_smoke", "skipped", { reason: "zig-out binary missing; run build or gate without --quick" });
    const search = run(ix, ["search", "lit:pub", "src", "--json", "--max-hits", "0"], {
      env: {
        IX_INDEX: "0",
        IX_NEXUS: "0",
        IX_STATE_DIR: stateDir,
      },
    });
    return lane("cold_smoke", search.exitCode === 0 && search.stdout.includes('"status":"ok"') ? "ok" : "failed", {
      evidence: search,
    });
  }

  function parseJsonLanePayload(id, commandResult) {
    if (commandResult.exitCode !== 0) {
      return { ok: false, reason: `${id} exited with ${commandResult.exitCode}` };
    }
    try {
      return { ok: true, value: JSON.parse(commandResult.stdout || "{}") };
    } catch {
      return { ok: false, reason: `${id} did not emit valid JSON` };
    }
  }

  function surfaceParityLane() {
    if (speedOnly) return lane("surface_parity", "skipped", { reason: "--speed-only" });
    const ix = findBuiltIx();
    if (!ix) return lane("surface_parity", "skipped", { reason: "zig-out binary missing; run build first" });
    const sharedEnv = {
      IX_INDEX: "0",
      IX_NEXUS: "0",
      IX_STATE_DIR: stateDir,
    };
    const search = run(ix, ["search", "lit:pub", "src", "--json", "--max-hits", "2"], { env: sharedEnv });
    const matches = run(ix, ["matches", "lit:pub", "src", "--json", "--max-hits", "2"], { env: sharedEnv });
    const inspect = run(ix, ["inspect", "--expr", "lit:pub", "src/core/inspect.zig", "--context", "1", "--json"], { env: sharedEnv });
    const parsedSearch = parseJsonLanePayload("search", search);
    const parsedMatches = parseJsonLanePayload("matches", matches);
    const parsedInspect = parseJsonLanePayload("inspect", inspect);
    const failures = [parsedSearch, parsedMatches, parsedInspect].filter((entry) => !entry.ok).map((entry) => entry.reason);
    if (failures.length !== 0) {
      return lane("surface_parity", "failed", {
        evidence: { search, matches, inspect },
        failures,
      });
    }

    const searchValue = parsedSearch.value;
    const matchesValue = parsedMatches.value;
    const inspectValue = parsedInspect.value;
    const searchHits = Array.isArray(searchValue.hits) ? searchValue.hits : [];
    const matchHits = Array.isArray(matchesValue.hits) ? matchesValue.hits : [];
    const inspectReports = Array.isArray(inspectValue.reports) ? inspectValue.reports : [];
    const parityFailures = [];
    if (searchValue.status !== "ok") parityFailures.push("search status is not ok");
    if (searchHits.length !== 2) parityFailures.push(`search hit count ${searchHits.length} != 2`);
    if (matchHits.length !== 2) parityFailures.push(`matches hit count ${matchHits.length} != 2`);
    if (searchValue.stats?.matches_found <= 0) parityFailures.push("search stats did not report positive matches");
    if (Object.hasOwn(matchesValue, "status") || Object.hasOwn(matchesValue, "stats")) {
      parityFailures.push("matches leaked terminal status/stats envelope");
    }
    if (JSON.stringify(searchHits) !== JSON.stringify(matchHits)) {
      parityFailures.push("search and matches first hit records diverged");
    }
    if (inspectValue.expression !== "lit:pub") parityFailures.push("inspect did not preserve expression");
    if (inspectReports.length === 0) parityFailures.push("inspect emitted no context reports");
    if (!inspectReports.some((report) => Array.isArray(report.lines) && report.lines.some((line) => line.role === "match"))) {
      parityFailures.push("inspect emitted no match context lines");
    }

    return lane("surface_parity", parityFailures.length === 0 ? "ok" : "failed", {
      evidence: { search, matches, inspect },
      checks: {
        searchHits: searchHits.length,
        matchHits: matchHits.length,
        inspectReports: inspectReports.length,
        matchesFound: searchValue.stats?.matches_found ?? null,
      },
      failures: parityFailures,
    });
  }

  function parseTextSentinel(stdout, marker) {
    const prefix = `-- ${marker} `;
    const line = String(stdout ?? "")
      .split(/\r?\n/)
      .find((entry) => entry.startsWith(prefix) && entry.endsWith(" --"));
    if (!line) return { ok: false, reason: `${marker} sentinel missing` };
    try {
      return { ok: true, value: JSON.parse(line.slice(prefix.length, -" --".length)) };
    } catch {
      return { ok: false, reason: `${marker} sentinel did not contain valid JSON`, line };
    }
  }

  function agentPathContractLane() {
    if (speedOnly) return lane("agent_path_contract", "skipped", { reason: "--speed-only" });
    const ix = findBuiltIx();
    if (!ix) return lane("agent_path_contract", "skipped", { reason: "zig-out binary missing; run build first" });
    const root = path.join(os.tmpdir(), `ix-agent-path-contract-root-${process.pid}`);
    const localState = path.join(os.tmpdir(), `ix-agent-path-contract-state-${process.pid}`);
    rmSync(root, { recursive: true, force: true });
    rmSync(localState, { recursive: true, force: true });

    const spacedDir = path.join(root, "dir with spaces");
    const searchFixture = path.join(spacedDir, "target file.txt");
    const inspectFixture = path.join(spacedDir, "window file.txt");
    mkdirSync(spacedDir, { recursive: true });
    writeFileSync(searchFixture, "alpha needle beta\n");
    writeFileSync(inspectFixture, "line one\nline two needle\nline three\nline four\nline five\n");

    const sharedEnv = {
      IX_INDEX: "0",
      IX_NEXUS: "0",
      IX_STATE_DIR: localState,
    };

    const search = run(ix, ["search", "lit:needle", root, "-n", "5"], { env: sharedEnv });
    const inspect = run(ix, ["inspect", inspectFixture, "--limit", "2"], { env: sharedEnv });
    const parsedSearch = parseTextSentinel(search.stdout, "ix.result.v1");
    const parsedInspect = parseTextSentinel(inspect.stdout, "ix.next.v1");
    const failures = [];
    const checks = {
      searchFixture,
      inspectFixture,
      searchExitCode: search.exitCode,
      inspectExitCode: inspect.exitCode,
      searchSentinel: parsedSearch.ok,
      inspectNextSentinel: parsedInspect.ok,
      hitAbsolutePath: null,
      hitAbsolutePathExists: false,
      inspectArgvPath: null,
      inspectArgvPathExists: false,
    };

    if (search.exitCode !== 0) failures.push(`search exited ${search.exitCode}`);
    if (inspect.exitCode !== 0) failures.push(`inspect exited ${inspect.exitCode}`);
    if (!parsedSearch.ok) failures.push(parsedSearch.reason);
    if (!parsedInspect.ok) failures.push(parsedInspect.reason);

    if (parsedSearch.ok) {
      const hit = Array.isArray(parsedSearch.value.hits) ? parsedSearch.value.hits[0] : null;
      checks.hitAbsolutePath = hit?.absolute_path ?? null;
      checks.hitAbsolutePathExists = typeof checks.hitAbsolutePath === "string" && existsSync(checks.hitAbsolutePath);
      if (parsedSearch.value.status !== "ok") failures.push("search sentinel status is not ok");
      if ((parsedSearch.value.matches ?? 0) <= 0) failures.push("search sentinel did not report positive matches");
      if (!hit) failures.push("search sentinel emitted no hit records");
      if (!checks.hitAbsolutePath) failures.push("search hit missing absolute_path");
      if (checks.hitAbsolutePath && !checks.hitAbsolutePathExists) failures.push("search hit absolute_path does not exist");
    }

    if (parsedInspect.ok) {
      const argv = Array.isArray(parsedInspect.value.argv) ? parsedInspect.value.argv : [];
      checks.inspectArgvPath = typeof argv[2] === "string" ? argv[2] : null;
      checks.inspectArgvPathExists = typeof checks.inspectArgvPath === "string" && existsSync(checks.inspectArgvPath);
      if (parsedInspect.value.cmd !== "inspect") failures.push("inspect next sentinel command is not inspect");
      if (!checks.inspectArgvPath) failures.push("inspect next sentinel missing argv path");
      if (checks.inspectArgvPath && !checks.inspectArgvPathExists) failures.push("inspect next argv path does not exist");
    }

    rmSync(root, { recursive: true, force: true });
    rmSync(localState, { recursive: true, force: true });

    return lane("agent_path_contract", failures.length === 0 ? "ok" : "failed", {
      evidence: { search, inspect },
      checks,
      failures,
    });
  }

  function normalizeHit(hit, root) {
    return {
      path: path.relative(root, hit.path ?? "").replaceAll("\\", "/"),
      line: hit.line ?? null,
      column: hit.column ?? null,
      preview: hit.preview ?? null,
    };
  }

  function sortHitsForParity(hits) {
    return [...hits].sort((a, b) =>
      String(a.path).localeCompare(String(b.path)) ||
      Number(a.line ?? 0) - Number(b.line ?? 0) ||
      Number(a.column ?? 0) - Number(b.column ?? 0) ||
      String(a.preview ?? "").localeCompare(String(b.preview ?? "")),
    );
  }

  function hitSignature(hit) {
    return `${hit.path}:${hit.line}:${hit.column}:${hit.preview}`;
  }

  function warmColdParityLane() {
    if (speedOnly) return lane("warm_cold_parity", "skipped", { reason: "--speed-only" });
    const ix = findBuiltIx();
    if (!ix) return lane("warm_cold_parity", "skipped", { reason: "zig-out binary missing; run build first" });
    const root = path.join(os.tmpdir(), `ix-warm-cold-parity-root-${process.pid}`);
    const localState = path.join(os.tmpdir(), `ix-warm-cold-parity-state-${process.pid}`);
    rmSync(root, { recursive: true, force: true });
    rmSync(localState, { recursive: true, force: true });
    mkdirSync(root, { recursive: true });
    writeFileSync(path.join(root, "alpha.zig"), "pub const needle = \"needle\";\r\npub const edge = \"line-boundary\";\r\n");
    writeFileSync(path.join(root, "nested.txt"), "haystack\nneedle\nneedle suffix\n");
    writeFileSync(path.join(root, "final-no-newline.txt"), "final needle");
    writeFileSync(path.join(root, "modified.txt"), "needle before mutation\n");
    writeFileSync(path.join(root, "deleted.txt"), "needle before deletion\n");
    writeFileSync(path.join(root, "binary-like.bin"), Buffer.from([0, 1, 2, 3, 0, 110, 101, 101, 100, 108, 101, 0]));
    writeFileSync(path.join(root, ".hidden.zig"), "pub const needle = \"hidden\";\n");

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
    if (-not $live) {
      [pscustomobject]@{ status = 'no_live_marker'; ownerPid = $owner.Id } | ConvertTo-Json -Compress
      exit 2
    }
    Remove-Item -LiteralPath (Join-Path $root 'deleted.txt') -Force
    Set-Content -LiteralPath (Join-Path $root 'modified.txt') -Value 'mutated away' -NoNewline
    $env:IX_NEXUS = '0'
    $env:IX_INDEX = '0'
    $coldStatsOut = & $ix search 'lit:needle' $root --json --stats-only
    $coldHitsOut = & $ix search 'lit:needle' $root --json --max-hits 20
    $coldCaseStatsOut = & $ix search 'lit:NEEDLE' $root --json --stats-only --ignore-case
    $env:IX_INDEX = '1'
    $warmStatsOut = & $ix search 'lit:needle' $root --json --stats-only
    $warmHitsOut = & $ix search 'lit:needle' $root --json --max-hits 20
    $warmCaseStatsOut = & $ix search 'lit:NEEDLE' $root --json --stats-only --ignore-case
    [pscustomobject]@{
      status = 'ok'
      ownerPid = $owner.Id
      liveMarker = $live.FullName
      coldStats = ($coldStatsOut | ConvertFrom-Json)
      coldHits = ($coldHitsOut | ConvertFrom-Json)
      coldCaseStats = ($coldCaseStatsOut | ConvertFrom-Json)
      warmStats = ($warmStatsOut | ConvertFrom-Json)
      warmHits = ($warmHitsOut | ConvertFrom-Json)
      warmCaseStats = ($warmCaseStatsOut | ConvertFrom-Json)
    } | ConvertTo-Json -Compress -Depth 30
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
    rmSync(localState, { recursive: true, force: true });
    let parsed;
    try {
      parsed = JSON.parse(probe.stdout || "{}");
    } catch {
      return lane("warm_cold_parity", "failed", { evidence: probe, reason: "warm/cold parity probe did not emit JSON" });
    }

    const failures = [];
    if (parsed.status !== "ok") failures.push(parsed.status ?? `powershell exited ${probe.exitCode}`);
    const coldStats = parsed.coldStats ?? {};
    const warmStats = parsed.warmStats ?? {};
    const coldCaseStats = parsed.coldCaseStats ?? {};
    const warmCaseStats = parsed.warmCaseStats ?? {};
    const coldHits = Array.isArray(parsed.coldHits?.hits) ? parsed.coldHits.hits.map((hit) => normalizeHit(hit, root)) : [];
    const warmHits = Array.isArray(parsed.warmHits?.hits) ? parsed.warmHits.hits.map((hit) => normalizeHit(hit, root)) : [];
    const coldHitsSorted = sortHitsForParity(coldHits);
    const warmHitsSorted = sortHitsForParity(warmHits);
    const sameHitOrder = JSON.stringify(coldHits) === JSON.stringify(warmHits);
    const coldMatches = coldStats.stats?.matches_found ?? null;
    const warmMatches = warmStats.stats?.matches_found ?? null;
    const coldCaseMatches = coldCaseStats.stats?.matches_found ?? null;
    const warmCaseMatches = warmCaseStats.stats?.matches_found ?? null;
    const coldSignatures = coldHitsSorted.map(hitSignature);
    const warmSignatures = warmHitsSorted.map(hitSignature);
    const signatureCounts = new Map();
    for (const signature of warmSignatures) signatureCounts.set(signature, (signatureCounts.get(signature) ?? 0) + 1);
    if (coldStats.status !== "ok") failures.push("lit:needle.stats.status cold is not ok");
    if (warmStats.status !== "ok") failures.push("lit:needle.stats.status warm is not ok");
    if (coldMatches !== warmMatches) failures.push(`lit:needle.stats.matches_found diverged cold=${coldMatches} warm=${warmMatches}`);
    if (JSON.stringify(coldHitsSorted) !== JSON.stringify(warmHitsSorted)) failures.push("lit:needle.hits.records diverged between cold and warm paths");
    if (coldMatches !== 6) failures.push(`lit:needle.fixture_count expected 6 text matches after stale mutations, got ${coldMatches}`);
    if (!coldSignatures.some((signature) => signature.includes("final-no-newline.txt:1:7:final needle"))) failures.push("final-no-newline fixture missing from cold hits");
    if (warmSignatures.some((signature) => signature.includes("deleted.txt"))) failures.push("deleted stale-index fixture leaked into warm hits");
    if (warmSignatures.some((signature) => signature.includes("modified.txt"))) failures.push("modified stale-index fixture leaked into warm hits");
    if (warmSignatures.some((signature) => (signatureCounts.get(signature) ?? 0) > 1)) failures.push("warm hit records contain duplicate contract signatures");
    if (coldHits.some((hit) => hit.path.includes("binary-like.bin")) || warmHits.some((hit) => hit.path.includes("binary-like.bin"))) failures.push("binary-like fixture leaked into hit records");
    if (coldCaseStats.status !== "ok") failures.push("case_policy.stats.status cold is not ok");
    if (warmCaseStats.status !== "ok") failures.push("case_policy.stats.status warm is not ok");
    if (coldCaseMatches !== warmCaseMatches) failures.push(`case_policy.stats.matches_found diverged cold=${coldCaseMatches} warm=${warmCaseMatches}`);
    if (warmCaseStats.stats?.generation_refresh?.refresh_status !== "fallback") failures.push("case_policy warm path did not report fallback");
    if (warmCaseStats.stats?.generation_refresh?.fallback_reason !== "case_insensitive") failures.push("case_policy warm fallback reason is not case_insensitive");

    return lane("warm_cold_parity", failures.length === 0 ? "ok" : "failed", {
      evidence: probe,
      checks: {
        coldMatches,
        warmMatches,
        coldHitCount: coldHits.length,
        warmHitCount: warmHits.length,
        coldCaseMatches,
        warmCaseMatches,
        sameHitOrder,
        coldHits,
        warmHits,
        coldHitsSorted,
        warmHitsSorted,
        warmRefreshStatus: warmStats.stats?.generation_refresh?.refresh_status ?? null,
        warmRefreshAvailable: warmStats.stats?.generation_refresh?.available ?? null,
        warmCaseRefreshStatus: warmCaseStats.stats?.generation_refresh?.refresh_status ?? null,
        warmCaseFallbackReason: warmCaseStats.stats?.generation_refresh?.fallback_reason ?? null,
      },
      failures,
    });
  }

  return {
    agentDryRunLane,
    agentRealLane,
    agentPathContractLane,
    buildLane,
    smokeLane,
    surfaceParityLane,
    warmColdParityLane,
  };
}
