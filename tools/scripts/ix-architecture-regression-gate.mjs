import { spawnSync } from "node:child_process";
import { existsSync, mkdirSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import os from "node:os";
import path from "node:path";
import { argValue, timestampSlug } from "./lib/script-helpers.mjs";

const ROOT = process.cwd();
const REPORT_DIR = path.join(ROOT, "tools", "reports", "architecture-gate");

const args = process.argv.slice(2);
const quick = args.includes("--quick");
const schemaSelfTest = args.includes("--schema-self-test");
const outPath = argValue(args, "--out", path.join(REPORT_DIR, `architecture-gate-${timestampSlug()}.json`));
const stateDir = argValue(args, "--state-dir", path.join(os.tmpdir(), `ix-architecture-gate-${process.pid}`));
const baselineIxMs = Number(argValue(args, "--baseline-ix-ms", process.env.IX_ARCH_GATE_BASELINE_IX_MS ?? "575.3829"));
const baselineTolerancePct = Number(argValue(args, "--baseline-tolerance-pct", process.env.IX_ARCH_GATE_BASELINE_TOLERANCE_PCT ?? "5"));
const baselineSoftTolerancePct = Number(argValue(args, "--baseline-soft-tolerance-pct", process.env.IX_ARCH_GATE_BASELINE_SOFT_TOLERANCE_PCT ?? "2.5"));
const ripgrepWarmupSamples = Number(argValue(args, "--ripgrep-warmup", process.env.IX_ARCH_GATE_RIPGREP_WARMUP ?? "6"));
const previousIxBinary = argValue(args, "--previous-ix-binary", process.env.IX_PREVIOUS_BINARY ?? "");
const pairedImprovementTolerancePct = Number(argValue(args, "--paired-improvement-tolerance-pct", process.env.IX_ARCH_GATE_PAIRED_IMPROVEMENT_TOLERANCE_PCT ?? "1.5"));
const patchNoRegressionTolerancePct = Number(argValue(args, "--patch-no-regression-tolerance-pct", process.env.IX_ARCH_GATE_PATCH_NO_REGRESSION_TOLERANCE_PCT ?? "1.5"));
const benchmarkControlDriftTolerancePct = Number(argValue(args, "--benchmark-control-drift-pct", process.env.IX_ARCH_GATE_CONTROL_DRIFT_PCT ?? "3"));
const planningChainSlug = argValue(
  args,
  "--planning-chain",
  process.env.IX_ARCH_GATE_PLANNING_CHAIN ?? "149-nextgen-architecture-validation-spine",
);
const planningChainPhases = parseCsvArg(
  argValue(args, "--planning-phases", process.env.IX_ARCH_GATE_PLANNING_PHASES ?? "a,b,c,d"),
);
const planningChainState = argValue(args, "--planning-state", process.env.IX_ARCH_GATE_PLANNING_STATE ?? "archived");

function run(command, commandArgs, options = {}) {
  const started = process.hrtime.bigint();
  const result = spawnSync(command, commandArgs, {
    cwd: ROOT,
    env: { ...process.env, ...(options.env ?? {}) },
    encoding: "utf8",
    maxBuffer: 64 * 1024 * 1024,
    windowsHide: true,
  });
  const durationMs = Number(process.hrtime.bigint() - started) / 1_000_000;
  return {
    command: [command, ...commandArgs].join(" "),
    exitCode: result.status ?? 0,
    durationMs,
    stdout: result.stdout ?? "",
    stderr: result.stderr ?? "",
  };
}

function psQuote(value) {
  return `'${String(value).replaceAll("'", "''")}'`;
}

function lane(id, status, evidence = {}) {
  const failures = Array.isArray(evidence.failures) ? evidence.failures : [];
  return {
    id,
    status,
    passed: status === "ok",
    failures,
    evidence: {},
    ...evidence,
  };
}

function parseCsvArg(value) {
  return String(value)
    .split(",")
    .map((entry) => entry.trim())
    .filter(Boolean);
}

function writeReport(report) {
  mkdirSync(path.dirname(outPath), { recursive: true });
  writeFileSync(outPath, `${JSON.stringify(report, null, 2)}\n`);
}

function isPlainObject(value) {
  return value !== null && typeof value === "object" && !Array.isArray(value);
}

function validateCommandEvidence(pathLabel, evidence, failures) {
  if (!isPlainObject(evidence)) {
    failures.push(`${pathLabel}: evidence must be an object`);
    return;
  }
  if (Object.hasOwn(evidence, "command") && typeof evidence.command !== "string") {
    failures.push(`${pathLabel}.command: must be a string`);
  }
  if (Object.hasOwn(evidence, "exitCode") && typeof evidence.exitCode !== "number") {
    failures.push(`${pathLabel}.exitCode: must be a number`);
  }
  if (Object.hasOwn(evidence, "durationMs") && typeof evidence.durationMs !== "number") {
    failures.push(`${pathLabel}.durationMs: must be a number`);
  }
  for (const key of ["stdout", "stderr"]) {
    if (Object.hasOwn(evidence, key) && typeof evidence[key] !== "string") {
      failures.push(`${pathLabel}.${key}: must be a string`);
    }
  }
}

function validateNestedEvidence(pathLabel, value, failures) {
  if (!isPlainObject(value)) return;
  if (Object.hasOwn(value, "command") || Object.hasOwn(value, "exitCode") || Object.hasOwn(value, "durationMs")) {
    validateCommandEvidence(pathLabel, value, failures);
  }
  for (const [key, nested] of Object.entries(value)) {
    if (isPlainObject(nested)) validateNestedEvidence(`${pathLabel}.${key}`, nested, failures);
  }
}

function ripgrepWindowFixedPass(window) {
  return isPlainObject(window) && window.ok === true;
}

function ripgrepWindowStrongPass(window) {
  return (
    isPlainObject(window) &&
    ((window.ok === true && (window.softOk === true || window.pairedOk === true)) || window.patchNoRegressionOk === true)
  );
}

function validateRipgrepLane(entry, failures) {
  if (entry.id !== "ripgrep_12_sample" || entry.status !== "ok") return;
  const fixedPasses = ["primary", "confirm", "tiebreaker"].filter((key) => ripgrepWindowFixedPass(entry[key])).length;
  if (fixedPasses === 0) {
    failures.push("ripgrep_12_sample: ok status requires at least one fixed-baseline passing window");
  }
  const windowKeys = ["primary", "confirm", "tiebreaker"].filter((key) => isPlainObject(entry[key]));
  const weakWindows = windowKeys.filter((key) => {
    const window = entry[key];
    return window.ok !== true && window.softOk !== true && window.pairedOk !== true && window.patchNoRegressionOk !== true;
  });
  const strongPasses = windowKeys.filter((key) => ripgrepWindowStrongPass(entry[key])).length;
  if (weakWindows.length > 0 && strongPasses < 2) {
    failures.push("ripgrep_12_sample: ok status with a hard-regression window requires two strong independent passes");
  }
  const sameSourcePairedPass = ["primary", "confirm", "tiebreaker"].some((key) => {
    const window = entry[key];
    return (
      isPlainObject(window) &&
      window.pairedOk === true &&
      window.metrics?.previousIxSourceRelation === "same_source_different_binary"
    );
  });
  if (sameSourcePairedPass) {
    failures.push("ripgrep_12_sample: same-source comparator artifact cannot provide paired improvement evidence");
  }
  const patchAccepted = entry.acceptanceMode === "same_source_patch_no_regression";
  if (patchAccepted) {
    const patchPasses = windowKeys.filter((key) => entry[key]?.patchNoRegressionOk === true).length;
    if (patchPasses < 2) {
      failures.push("ripgrep_12_sample: same-source patch no-regression acceptance requires two independent paired passes");
    }
  }
}

function validateReport(report) {
  const failures = [];
  const expectedLaneIds = new Set([
    "worktree",
    "planning_chain",
    "diff_check",
    "benchmark_control",
    "ripgrep_12_sample",
    "agent_real_dry_run",
    "agent_real",
    "zig_test",
    "cold_smoke",
    "surface_parity",
    "warm_cold_parity",
    "warm_index_live",
    "runtime_state_location",
    "indexd_memory_cap",
    "process_scan",
    "report_schema",
  ]);
  const legalStatuses = new Set(["ok", "failed", "skipped"]);

  if (!isPlainObject(report)) failures.push("report: must be an object");
  if (!["ok", "failed"].includes(report.status)) failures.push("report.status: must be ok or failed");
  if (!["quick", "full"].includes(report.mode)) failures.push("report.mode: must be quick or full");
  if (typeof report.stateDir !== "string" || report.stateDir.length === 0) failures.push("report.stateDir: must be a non-empty string");
  if (typeof report.reportPath !== "string" || report.reportPath.length === 0) failures.push("report.reportPath: must be a non-empty string");
  if (!Array.isArray(report.lanes)) {
    failures.push("report.lanes: must be an array");
    return failures;
  }

  const seen = new Set();
  for (const [index, entry] of report.lanes.entries()) {
    const label = `report.lanes[${index}]`;
    if (!isPlainObject(entry)) {
      failures.push(`${label}: must be an object`);
      continue;
    }
    if (typeof entry.id !== "string" || entry.id.length === 0) {
      failures.push(`${label}.id: must be a non-empty string`);
      continue;
    }
    if (!expectedLaneIds.has(entry.id)) failures.push(`${entry.id}: unexpected lane id`);
    if (seen.has(entry.id)) failures.push(`${entry.id}: duplicate lane id`);
    seen.add(entry.id);

    if (!legalStatuses.has(entry.status)) failures.push(`${entry.id}.status: must be ok, failed, or skipped`);
    if (typeof entry.passed !== "boolean") failures.push(`${entry.id}.passed: must be a boolean`);
    if (entry.passed !== (entry.status === "ok")) {
      failures.push(`${entry.id}.passed: must agree with ok status`);
    }
    if (!Array.isArray(entry.failures) || entry.failures.some((failure) => typeof failure !== "string")) {
      failures.push(`${entry.id}.failures: must be an array of strings`);
    }
    if (!Object.hasOwn(entry, "evidence") || !isPlainObject(entry.evidence)) {
      failures.push(`${entry.id}.evidence: must be an object`);
    }
    if (entry.status === "skipped" && typeof entry.reason !== "string") {
      failures.push(`${entry.id}.reason: skipped lanes must explain the skip`);
    }
    if (
      entry.status === "failed" &&
      entry.failures.length === 0 &&
      !Object.hasOwn(entry, "reason") &&
      !Object.hasOwn(entry, "primary") &&
      !Object.hasOwn(entry, "confirm")
    ) {
      failures.push(`${entry.id}: failed lanes must expose evidence, failures, reason, or benchmark windows`);
    }
    if (Object.hasOwn(entry, "evidence")) validateNestedEvidence(`${entry.id}.evidence`, entry.evidence, failures);
    for (const key of ["primary", "confirm", "tiebreaker"]) {
      if (Object.hasOwn(entry, key)) validateNestedEvidence(`${entry.id}.${key}`, entry[key], failures);
    }
    validateRipgrepLane(entry, failures);
  }

  for (const id of [...expectedLaneIds].filter((expected) => expected !== "report_schema")) {
    if (!seen.has(id)) failures.push(`${id}: expected lane missing`);
  }

  return failures;
}

function runSchemaSelfTest() {
  const malformedReport = {
    status: "ok",
    mode: "quick",
    stateDir: stateDir,
    reportPath: outPath,
    lanes: [
      {
        id: "worktree",
        status: "ok",
        passed: "yes",
        failures: "none",
        evidence: "not-an-object",
      },
      {
        id: "ripgrep_12_sample",
        status: "ok",
        passed: true,
        failures: [],
        evidence: {},
        primary: {
          ok: false,
          pairedOk: true,
          metrics: {
            ixMs: 607.7968,
            maxAllowedIxMs: 604.1520449999999,
          },
        },
      },
      {
        id: "ripgrep_12_sample",
        status: "ok",
        passed: true,
        failures: [],
        evidence: {},
        primary: { ok: false, softOk: false, pairedOk: false, metrics: { ixMs: 620 } },
        confirm: { ok: true, softOk: false, pairedOk: false, metrics: { ixMs: 594 } },
        tiebreaker: { ok: true, softOk: false, pairedOk: false, metrics: { ixMs: 595 } },
      },
      {
        id: "ripgrep_12_sample",
        status: "ok",
        passed: true,
        failures: [],
        evidence: {},
        primary: {
          ok: true,
          pairedOk: true,
          metrics: {
            ixMs: 580,
            maxAllowedIxMs: 604.1520449999999,
            previousIxSourceRelation: "same_source_different_binary",
          },
        },
      },
    ],
  };
  const failures = validateReport(malformedReport);
  const required = [
    "worktree.passed: must be a boolean",
    "worktree.passed: must agree with ok status",
    "worktree.failures: must be an array of strings",
    "worktree.evidence: must be an object",
    "ripgrep_12_sample: ok status requires at least one fixed-baseline passing window",
    "ripgrep_12_sample: ok status with a hard-regression window requires two strong independent passes",
    "ripgrep_12_sample: same-source comparator artifact cannot provide paired improvement evidence",
  ];
  const missing = required.filter((needle) => !failures.includes(needle));
  const report = {
    status: missing.length === 0 ? "ok" : "failed",
    mode: "schema-self-test",
    checkedFailures: failures,
    required,
    missing,
  };
  console.log(JSON.stringify(report, null, 2));
  process.exit(report.status === "ok" ? 0 : 1);
}

if (schemaSelfTest) {
  runSchemaSelfTest();
}

function findBuiltIx() {
  const exe = process.platform === "win32" ? "ix-zig.exe" : "ix-zig";
  const candidate = path.join(ROOT, "zig-out", "bin", exe);
  return existsSync(candidate) ? candidate : null;
}

function resolveZigExe() {
  if (process.env.ZIG_EXE && existsSync(process.env.ZIG_EXE)) return process.env.ZIG_EXE;
  const local = path.join(
    os.homedir(),
    ".local",
    "zig",
    `zig-x86_64-${process.platform === "win32" ? "windows" : "linux"}-0.16.0`,
    process.platform === "win32" ? "zig.exe" : "zig",
  );
  return existsSync(local) ? local : "zig";
}

function scanIxProcesses() {
  if (process.platform !== "win32") {
    return lane("process_scan", "skipped", { reason: "process scan is currently implemented for Windows only" });
  }
  const probe = run("powershell", [
    "-NoProfile",
    "-Command",
    "Get-CimInstance Win32_Process | Where-Object { $_.ProcessId -ne $PID -and ($_.Name -match '^(ix|iex|ix-zig|__ix_indexd|__ix_nexus)(\\.exe)?$' -or $_.CommandLine -match '__ix_indexd|__ix_nexus') } | Select-Object ProcessId,Name,CommandLine | ConvertTo-Json -Compress",
  ]);
  if (probe.exitCode !== 0) return lane("process_scan", "failed", { evidence: probe });
  const text = probe.stdout.trim();
  return lane("process_scan", text ? "failed" : "ok", { evidence: probe, matched: text || "[]" });
}

function worktreeLane() {
  const status = run("git", ["status", "--short"]);
  return lane(status.exitCode === 0 ? "worktree" : "worktree", status.exitCode === 0 ? "ok" : "failed", {
    evidence: status,
  });
}

function diffCheckLane() {
  const check = run("git", ["diff", "--check"]);
  return lane("diff_check", check.exitCode === 0 ? "ok" : "failed", { evidence: check });
}

function planningLane() {
  const match = planningChainSlug.match(/^(\d+)-(.+)$/);
  const chainConfigFailures = [];
  if (!match) chainConfigFailures.push(`planning chain slug must start with a numeric prefix: ${planningChainSlug}`);
  if (planningChainPhases.length === 0) chainConfigFailures.push("planning chain phases must not be empty");
  if (!["archived", "pending"].includes(planningChainState)) {
    chainConfigFailures.push(`planning state must be archived or pending: ${planningChainState}`);
  }
  const prefix = match?.[1] ?? "";
  const suffix = match?.[2] ?? planningChainSlug;
  const chainRoot = planningChainState === "pending" ? ".docs/todo/pending" : ".docs/todo/changelog";
  const oppositeRoot = planningChainState === "pending" ? ".docs/todo/changelog" : ".docs/todo/pending";
  const required = match
    ? [
        `${chainRoot}/${planningChainSlug}.md`,
        ...planningChainPhases.map((phase) => `${chainRoot}/${prefix}${phase}-${suffix}.md`),
      ]
    : [];
  const staleOpposite = required
    .map((file) => file.replace(chainRoot, oppositeRoot))
    .filter((file) => existsSync(path.join(ROOT, file)));
  const stalePending = planningChainState === "archived" ? staleOpposite : [];
  const missing = required.filter((file) => !existsSync(path.join(ROOT, file)));
  const incomplete = [];
  for (const file of required) {
    const absolute = path.join(ROOT, file);
    if (!existsSync(absolute)) continue;
    const body = readFileSync(absolute, "utf8");
    if (planningChainState === "archived") {
      if (!body.includes("status: done")) incomplete.push(`${file}: status is not done`);
      if (/^evidence:.*PLACEHOLDER/m.test(body)) incomplete.push(`${file}: evidence still contains PLACEHOLDER`);
    } else if (!body.includes("status: pending")) {
      incomplete.push(`${file}: status is not pending`);
    }
  }
  const failures = [
    ...chainConfigFailures,
    ...missing.map((file) => `${file}: missing`),
    ...staleOpposite.map((file) => `${file}: duplicate ${planningChainState === "pending" ? "changelog" : "pending"} file remains`),
    ...incomplete,
  ];
  return lane("planning_chain", failures.length === 0 ? "ok" : "failed", {
    chain: planningChainSlug,
    state: planningChainState,
    phases: planningChainPhases,
    required,
    missing,
    staleOpposite,
    stalePending,
    incomplete,
    failures,
  });
}

function agentDryRunLane() {
  const agent = run(process.execPath, ["tools/scripts/ix-agent-real-eval.mjs", "--dry-run"]);
  return lane("agent_real_dry_run", agent.exitCode === 0 ? "ok" : "failed", { evidence: agent });
}

function agentRealLane() {
  if (quick) return lane("agent_real", "skipped", { reason: "--quick" });
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

function warmColdParityLane() {
  const ix = findBuiltIx();
  if (!ix) return lane("warm_cold_parity", "skipped", { reason: "zig-out binary missing; run build first" });
  const root = path.join(os.tmpdir(), `ix-warm-cold-parity-root-${process.pid}`);
  const localState = path.join(os.tmpdir(), `ix-warm-cold-parity-state-${process.pid}`);
  rmSync(root, { recursive: true, force: true });
  rmSync(localState, { recursive: true, force: true });
  mkdirSync(root, { recursive: true });
  writeFileSync(path.join(root, "alpha.zig"), "pub const needle = \"needle\";\r\npub const edge = \"line-boundary\";\r\n");
  writeFileSync(path.join(root, "nested.txt"), "haystack\nneedle\nneedle suffix\n");
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
  $env:IX_NEXUS = '0'
  $env:IX_INDEX = '0'
  $coldStatsOut = & $ix search 'lit:needle' $root --json --stats-only
  $coldHitsOut = & $ix search 'lit:needle' $root --json --max-hits 20
  $env:IX_INDEX = '1'
  $warmStatsOut = & $ix search 'lit:needle' $root --json --stats-only
  $warmHitsOut = & $ix search 'lit:needle' $root --json --max-hits 20
  [pscustomobject]@{
    status = 'ok'
    ownerPid = $owner.Id
    liveMarker = $live.FullName
    coldStats = ($coldStatsOut | ConvertFrom-Json)
    coldHits = ($coldHitsOut | ConvertFrom-Json)
    warmStats = ($warmStatsOut | ConvertFrom-Json)
    warmHits = ($warmHitsOut | ConvertFrom-Json)
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
  const coldHits = Array.isArray(parsed.coldHits?.hits) ? parsed.coldHits.hits.map((hit) => normalizeHit(hit, root)) : [];
  const warmHits = Array.isArray(parsed.warmHits?.hits) ? parsed.warmHits.hits.map((hit) => normalizeHit(hit, root)) : [];
  const coldHitsSorted = sortHitsForParity(coldHits);
  const warmHitsSorted = sortHitsForParity(warmHits);
  const sameHitOrder = JSON.stringify(coldHits) === JSON.stringify(warmHits);
  const coldMatches = coldStats.stats?.matches_found ?? null;
  const warmMatches = warmStats.stats?.matches_found ?? null;
  if (coldStats.status !== "ok") failures.push("cold stats status is not ok");
  if (warmStats.status !== "ok") failures.push("warm stats status is not ok");
  if (coldMatches !== warmMatches) failures.push(`stats matches diverged cold=${coldMatches} warm=${warmMatches}`);
  if (JSON.stringify(coldHitsSorted) !== JSON.stringify(warmHitsSorted)) failures.push("hit records diverged between cold and warm paths");
  if (coldMatches !== 5) failures.push(`expected 5 text matches including default dotfile traversal, got ${coldMatches}`);
  if (coldHits.some((hit) => hit.path.includes("binary-like.bin"))) failures.push("binary-like fixture leaked into hit records");

  return lane("warm_cold_parity", failures.length === 0 ? "ok" : "failed", {
    evidence: probe,
    checks: {
      coldMatches,
      warmMatches,
      coldHitCount: coldHits.length,
      warmHitCount: warmHits.length,
      sameHitOrder,
      coldHits,
      warmHits,
      coldHitsSorted,
      warmHitsSorted,
      warmRefreshStatus: warmStats.stats?.generation_refresh?.refresh_status ?? null,
      warmRefreshAvailable: warmStats.stats?.generation_refresh?.available ?? null,
    },
    failures,
  });
}

function warmIndexLane() {
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

function runtimeStateLocationLane() {
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

function findFilesByName(root, name, found = []) {
  if (!existsSync(root)) return found;
  const entries = spawnSync("powershell", [
    "-NoProfile",
    "-Command",
    `Get-ChildItem -LiteralPath ${JSON.stringify(root)} -Recurse -Force -Filter ${JSON.stringify(name)} | Select-Object -ExpandProperty FullName`,
  ], {
    cwd: ROOT,
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

function ripgrepLane() {
  const corpus = process.env.IX_BENCHSUITE_LINUX ?? "E:\\Workspaces\\01_Projects\\01_Github\\iEx\\.refs\\ripgrep\\benchsuite\\linux";
  if (!existsSync(corpus)) return lane("ripgrep_12_sample", "skipped", { reason: "ripgrep benchsuite corpus missing", corpus });
  if (quick) return lane("ripgrep_12_sample", "skipped", { reason: "--quick", corpus });
  const latestPath = path.join(ROOT, "tools", "reports", "latest.json");
  const maxAllowed = baselineIxMs * (1 + baselineTolerancePct / 100);
  const softMaxAllowed = baselineIxMs * (1 + baselineSoftTolerancePct / 100);
  const pairedMaxRatio = 1 - pairedImprovementTolerancePct / 100;

  const runWindow = (label) => {
    const benchArgs = [
      "tools/scripts/run-once-benchmark.mjs",
      "--profile",
      "suite-linux-word",
      "--expression",
      "re:\\bPM_RESUME\\b",
      "--corpus",
      corpus,
      "--threads",
      "32",
      "--warmup",
      String(ripgrepWarmupSamples),
      "--samples",
      "12",
      "--quiet",
    ];
    if (previousIxBinary) benchArgs.push("--previous-ix-binary", previousIxBinary, "--paired-interleave");
    const bench = run(process.execPath, benchArgs);
    if (bench.exitCode !== 0) return { label, ok: false, hardFailure: true, evidence: bench };
    if (!existsSync(latestPath)) {
      return {
        label,
        ok: false,
        hardFailure: true,
        evidence: bench,
        reason: "benchmark completed but tools/reports/latest.json was not written",
      };
    }

    const latest = JSON.parse(readFileSync(latestPath, "utf8"));
    const ixMs = Number(latest.iexMs);
    const rgMs = Number(latest.rgMs);
    const matchCount = Number(latest.matchCount);
    const previousIxMs = Number(latest.competitors?.iex_previous?.durationMs);
    const pairedRatio = Number(latest.iexToPreviousRatio);
    const previousAuthority = latest.previousIexAuthority ?? null;
    const previousMatchCountParity = latest.previousIexMatchCountParity ?? null;
    const previousIxSourceRelation = latest.previousIxSourceRelation ?? null;
    const previousIsHistoricalSource =
      previousIxSourceRelation === null ||
      previousIxSourceRelation === "unknown" ||
      previousIxSourceRelation === "different_source";
    const previousIsSameSourceComparator = previousIxSourceRelation === "same_source_different_binary";
    const regressionPct = Number.isFinite(ixMs) && baselineIxMs > 0 ? ((ixMs - baselineIxMs) / baselineIxMs) * 100 : null;
    const pairedImprovementPct = Number.isFinite(pairedRatio) && pairedRatio > 0 ? (1 - pairedRatio) * 100 : null;
    const ok = Number.isFinite(ixMs) && ixMs <= maxAllowed;
    const softOk = Number.isFinite(ixMs) && ixMs <= softMaxAllowed;
    const patchNoRegressionMaxRatio = 1 + patchNoRegressionTolerancePct / 100;
    const pairedOk =
      previousIxBinary !== "" &&
      previousIsHistoricalSource &&
      previousAuthority === "authoritative" &&
      previousMatchCountParity !== false &&
      Number.isFinite(previousIxMs) &&
      Number.isFinite(pairedRatio) &&
      pairedRatio <= pairedMaxRatio;
    const patchNoRegressionOk =
      previousIxBinary !== "" &&
      previousIsSameSourceComparator &&
      previousAuthority === "authoritative" &&
      previousMatchCountParity !== false &&
      Number.isFinite(previousIxMs) &&
      Number.isFinite(pairedRatio) &&
      pairedRatio <= patchNoRegressionMaxRatio;
    return {
      label,
      ok,
      softOk,
      pairedOk,
      patchNoRegressionOk,
      hardFailure: false,
      evidence: bench,
      metrics: {
        profile: latest.profile,
        expression: latest.expression,
        samples: 12,
        warmup: ripgrepWarmupSamples,
        ixMs,
        rgMs,
        previousIxMs: Number.isFinite(previousIxMs) ? previousIxMs : null,
        ixBinaryIdentity: latest.ixBinaryIdentity ?? null,
        previousIxBinaryIdentity: latest.competitors?.iex_previous?.binaryIdentity ?? null,
        previousIxSourceRelation,
        previousIsHistoricalSource,
        previousIsSameSourceComparator,
        pairedRatio: Number.isFinite(pairedRatio) ? pairedRatio : null,
        pairedImprovementPct,
        previousAuthority,
        previousMatchCountParity,
        pairedImprovementTolerancePct,
        pairedMaxRatio,
        patchNoRegressionTolerancePct,
        patchNoRegressionMaxRatio,
        ixSampleDurationsMs: latest.iexSampleDurationsMs ?? [],
        ixEngineSampleDurationsMs: latest.iexEngineSampleDurationsMs ?? [],
        previousIxEngineSampleDurationsMs: latest.competitors?.iex_previous?.engineSampleDurationsMs ?? [],
        previousIxPairing: latest.competitors?.iex_previous?.pairing ?? null,
        rgSampleDurationsMs: latest.competitors?.ripgrep?.sampleDurationsMs ?? [],
        speedupPct: latest.speedupPct,
        matchCount,
        phaseMs: latest.phaseMs ?? {},
        baselineIxMs,
        baselineTolerancePct,
        baselineSoftTolerancePct,
        maxAllowedIxMs: maxAllowed,
        softMaxAllowedIxMs: softMaxAllowed,
        regressionPct,
      },
    };
  };

  const primary = runWindow("primary");
  if (primary.hardFailure) return lane("ripgrep_12_sample", "failed", { corpus, primary });
  if (primary.ok && primary.softOk) return lane("ripgrep_12_sample", "ok", { corpus, primary });

  const confirm = runWindow("confirm");
  if (confirm.hardFailure) return lane("ripgrep_12_sample", "failed", { corpus, primary, confirm });

  const hardPasses = (primary.ok ? 1 : 0) + (confirm.ok ? 1 : 0);
  const strongPasses = (ripgrepWindowStrongPass(primary) ? 1 : 0) + (ripgrepWindowStrongPass(confirm) ? 1 : 0);
  const patchNoRegressionPasses = (primary.patchNoRegressionOk ? 1 : 0) + (confirm.patchNoRegressionOk ? 1 : 0);
  const accepted = hardPasses === 2 && strongPasses >= 1;
  if (hardPasses === 0 && patchNoRegressionPasses > 0 && patchNoRegressionPasses < 2) {
    const tiebreaker = runWindow("tiebreaker");
    if (tiebreaker.hardFailure) return lane("ripgrep_12_sample", "failed", { corpus, primary, confirm, tiebreaker });
    const tiebreakerPatchPasses = patchNoRegressionPasses + (tiebreaker.patchNoRegressionOk ? 1 : 0);
    const tiebreakerAccepted = tiebreakerPatchPasses >= 2;
    return lane("ripgrep_12_sample", tiebreakerAccepted ? "ok" : "failed", {
      corpus,
      primary,
      confirm,
      tiebreaker,
      acceptanceMode: tiebreakerAccepted ? "same_source_patch_no_regression" : "failed",
      interpretation: tiebreakerAccepted
        ? "fixed historical benchmark windows crossed the guard, but two independent same-source comparator windows proved this worktree did not regress clean HEAD"
        : "benchmark windows crossed the fixed historical guard and did not produce two same-source patch no-regression passes",
    });
  }
  if (hardPasses === 0 && patchNoRegressionPasses >= 2) {
    return lane("ripgrep_12_sample", "ok", {
      corpus,
      primary,
      confirm,
      acceptanceMode: "same_source_patch_no_regression",
      interpretation:
        "fixed historical benchmark windows crossed the guard, but two independent same-source comparator windows proved this worktree did not regress clean HEAD",
    });
  }
  if (hardPasses === 1) {
    const tiebreaker = runWindow("tiebreaker");
    if (tiebreaker.hardFailure) return lane("ripgrep_12_sample", "failed", { corpus, primary, confirm, tiebreaker });
    const tiebreakerHardPasses = hardPasses + (tiebreaker.ok ? 1 : 0);
    const tiebreakerStrongPasses = strongPasses + (ripgrepWindowStrongPass(tiebreaker) ? 1 : 0);
    const tiebreakerAccepted = tiebreakerHardPasses >= 2 && tiebreakerStrongPasses >= 2;
    return lane("ripgrep_12_sample", tiebreakerAccepted ? "ok" : "failed", {
      corpus,
      primary,
      confirm,
      tiebreaker,
      interpretation: tiebreakerAccepted
        ? "one measured window crossed the hard guard, but two independent windows produced strong fixed-baseline or paired-improvement passes"
        : "benchmark windows disagreed and did not produce two strong independent passes",
    });
  }

  return lane("ripgrep_12_sample", accepted ? "ok" : "failed", {
    corpus,
    primary,
    confirm,
    interpretation: accepted
      ? "one measured window crossed the soft regression band, but the fixed historical control stayed inside it"
      : "benchmark windows crossed the fixed historical regression guard; paired previous-binary metrics are diagnostic only and do not override the baseline",
  });
}

function benchmarkControlLane() {
  const corpus = process.env.IX_BENCHSUITE_LINUX ?? "E:\\Workspaces\\01_Projects\\01_Github\\iEx\\.refs\\ripgrep\\benchsuite\\linux";
  if (!existsSync(corpus)) return lane("benchmark_control", "skipped", { reason: "ripgrep benchsuite corpus missing", corpus });
  if (quick) return lane("benchmark_control", "skipped", { reason: "--quick", corpus });
  const ix = findBuiltIx();
  if (!ix) return lane("benchmark_control", "skipped", { reason: "zig-out binary missing; run build first", corpus });

  const latestPath = path.join(ROOT, "tools", "reports", "latest.json");
  const bench = run(process.execPath, [
    "tools/scripts/run-once-benchmark.mjs",
    "--profile",
    "suite-linux-word-control",
    "--expression",
    "re:\\bPM_RESUME\\b",
    "--corpus",
    corpus,
    "--threads",
    "32",
    "--warmup",
    String(ripgrepWarmupSamples),
    "--samples",
    "12",
    "--ix-binary",
    ix,
    "--previous-ix-binary",
    ix,
    "--paired-interleave",
    "--quiet",
  ]);
  if (bench.exitCode !== 0) return lane("benchmark_control", "failed", { corpus, evidence: bench });
  if (!existsSync(latestPath)) {
    return lane("benchmark_control", "failed", {
      corpus,
      evidence: bench,
      reason: "benchmark completed but tools/reports/latest.json was not written",
    });
  }

  const latest = JSON.parse(readFileSync(latestPath, "utf8"));
  const ixMs = Number(latest.iexMs);
  const selfMs = Number(latest.competitors?.iex_previous?.durationMs);
  const selfRatio = Number(latest.iexToPreviousRatio);
  const driftPct = Number.isFinite(selfRatio) && selfRatio > 0 ? Math.abs(1 - selfRatio) * 100 : null;
  const authority = latest.previousIexAuthority ?? null;
  const matchCountParity = latest.previousIexMatchCountParity ?? null;
  const ok =
    authority === "authoritative" &&
    matchCountParity !== false &&
    Number.isFinite(ixMs) &&
    Number.isFinite(selfMs) &&
    Number.isFinite(driftPct) &&
    driftPct <= benchmarkControlDriftTolerancePct;

  return lane("benchmark_control", ok ? "ok" : "failed", {
    corpus,
    evidence: bench,
    reason: ok ? undefined : "same-binary control drift exceeded tolerance; benchmark window is too noisy for attribution",
    metrics: {
      profile: latest.profile,
      expression: latest.expression,
      samples: 12,
      warmup: ripgrepWarmupSamples,
      ixMs,
      selfMs,
      ixBinaryIdentity: latest.ixBinaryIdentity ?? null,
      selfBinaryIdentity: latest.competitors?.iex_previous?.binaryIdentity ?? null,
      selfSourceRelation: latest.previousIxSourceRelation ?? null,
      selfRatio: Number.isFinite(selfRatio) ? selfRatio : null,
      driftPct,
      benchmarkControlDriftTolerancePct,
      authority,
      matchCountParity,
      ixEngineSampleDurationsMs: latest.iexEngineSampleDurationsMs ?? [],
      selfEngineSampleDurationsMs: latest.competitors?.iex_previous?.engineSampleDurationsMs ?? [],
      selfPairing: latest.competitors?.iex_previous?.pairing ?? null,
      rgSampleDurationsMs: latest.competitors?.ripgrep?.sampleDurationsMs ?? [],
      matchCount: latest.matchCount ?? null,
      phaseMs: latest.phaseMs ?? {},
    },
  });
}

const lanes = [
  worktreeLane(),
  planningLane(),
  diffCheckLane(),
  benchmarkControlLane(),
  ripgrepLane(),
  agentDryRunLane(),
  agentRealLane(),
  buildLane(),
  smokeLane(),
  surfaceParityLane(),
  warmColdParityLane(),
  warmIndexLane(),
  runtimeStateLocationLane(),
  memoryCapLane(),
  scanIxProcesses(),
];

const failed = lanes.filter((entry) => entry.status === "failed");
const report = {
  status: failed.length === 0 ? "ok" : "failed",
  mode: quick ? "quick" : "full",
  stateDir,
  lanes,
  reportPath: outPath,
};

const reportSchemaFailures = validateReport(report);
if (reportSchemaFailures.length !== 0) {
  report.status = "failed";
  report.lanes.push(lane("report_schema", "failed", { failures: reportSchemaFailures }));
}

writeReport(report);
console.log(JSON.stringify(report, null, 2));
process.exit(report.status === "ok" ? 0 : 1);
