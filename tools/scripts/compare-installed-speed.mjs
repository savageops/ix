import { existsSync, mkdirSync, writeFileSync } from "node:fs";
import os from "node:os";
import path from "node:path";
import { hostSnapshot } from "./lib/benchmark-runner.mjs";
import { argValue, timestampSlug } from "./lib/script-helpers.mjs";
import { acquireBenchmarkLock, buildInstalledComparisonScore, buildInstalledRoundLedger, buildInstalledScorecard, buildRoundLedgerSummary, effectiveImprovementTargetPct, fileHash, identityControlFailures, measureIxOnce, measureRipgrep, measureSameBinaryIdentityControl, pairedEngineStats, pairOrderSummary, requireOk, routeParityEvaluation, run, scanIxProcesses, summarizeIxRuns } from "./lib/speed-compare-utils.mjs";

const ROOT = process.cwd();
const REPORT_DIR = path.join(ROOT, "tools", "reports", "manual-speed-compare");
const DEFAULT_CORPUS = "E:\\Workspaces\\01_Projects\\01_Github\\iEx\\.refs\\ripgrep\\benchsuite\\linux";
const DEFAULT_EXPR = "re:(?i)(ERR_SYS|PME_TURN_OFF|LINK_REQ_RST|CFG_BME_EVT)";
const DEFAULT_INSTALLED_IX = path.join(os.homedir(), "AppData", "Local", "Programs", "iEx", "bin", "ix.exe");
const DEFAULT_REPO_IX = path.join(ROOT, "zig-out", "bin", "ix-zig.exe");
const BENCH_STATE_DIR = path.join(os.tmpdir(), "ix-zig-speed-compare-state");
const BENCH_ENV = {
  IX_INDEX: "0",
  IX_NEXUS: "0",
  IX_SCAN_OPEN_TIMING: "0",
  IX_STATE_DIR: BENCH_STATE_DIR,
};

const args = process.argv.slice(2);
if (args.includes("--help") || args.includes("-h")) {
  console.log(`Usage: node tools/scripts/compare-installed-speed.mjs [options]

Compares ripgrep, native installed IX, and the repo IX binary on the ripgrep
linux benchsuite. Sampling is paired between installed and repo IX.

Options:
  --build                         Build repo IX ReleaseFast before measuring.
  --samples <n>                   Samples per lane. Default: 12.
  --threads <n>                   IX/ripgrep thread count. Default: 32.
  --identity-control-samples <n>  Same-binary control pairs. Default: min(12, samples).
  --no-identity-control           Disable same-binary noise control.
  --corpus <path>                 Corpus path.
  --expression <expr>             Search expression.
  --installed-ix <path>           Native installed IX path.
  --repo-ix <path>                Repo IX binary path.
  --min-retainable-samples <n>    Minimum samples for strict evidence.
  --min-installed-improvement-pct <n>
                                  Required repo improvement over installed. Default: 5.
  --identity-noise-multiplier <n> Effective target multiplier for same-binary drift. Default: 3.
  --no-benchmark-lock             Disable the cross-script benchmark lock.
  --require-promotion             Exit non-zero unless repo is promotable over installed.
  --require-strict                Exit non-zero unless strict evidence passes.
  --quiet                         Write reports without printing summary.
  --help, -h                      Print this help and exit without measuring.
`);
  process.exit(0);
}
const corpus = argValue(args, "--corpus", DEFAULT_CORPUS);
const expression = argValue(args, "--expression", DEFAULT_EXPR);
const installedIx = argValue(args, "--installed-ix", DEFAULT_INSTALLED_IX);
const repoIx = argValue(args, "--repo-ix", DEFAULT_REPO_IX);
const samples = Number(argValue(args, "--samples", "12"));
const threads = Number(argValue(args, "--threads", "32"));
const identityControlSamples = Number(argValue(args, "--identity-control-samples", String(Math.min(12, samples))));
const identityControlEnabled = !args.includes("--no-identity-control");
const buildFirst = args.includes("--build");
const quiet = args.includes("--quiet");
const requireStrict = args.includes("--require-strict");
const requirePromotion = args.includes("--require-promotion");
const benchmarkLock = !args.includes("--no-benchmark-lock");
const minRetainableSamples = Number(argValue(args, "--min-retainable-samples", process.env.IX_MIN_RETAINABLE_SPEED_SAMPLES ?? "12"));
const minInstalledImprovementPct = Number(argValue(args, "--min-installed-improvement-pct", process.env.IX_MIN_INSTALLED_IMPROVEMENT_PCT ?? "5"));
const identityNoiseMultiplier = Number(argValue(args, "--identity-noise-multiplier", process.env.IX_IDENTITY_NOISE_MULTIPLIER ?? "3"));

function resolveZigExe() {
  const local = path.join(os.homedir(), ".local", "zig", "zig-x86_64-windows-0.16.0", "zig.exe");
  return existsSync(local) ? local : "zig";
}

function measurePairedIx() {
  const ixArgs = ["search", expression, corpus, "--json", "--stats-only", "--threads", String(threads)];
  const lanes = { installed: [], repo: [] };
  const pairOrder = [];
  for (let pair = 0; pair < samples; pair += 1) {
    const first = pair % 2 === 0 ? "installed" : "repo";
    const second = first === "installed" ? "repo" : "installed";
    pairOrder.push(`${first},${second}`);
    for (const lane of [first, second]) {
      const binaryPath = lane === "installed" ? installedIx : repoIx;
      lanes[lane].push(measureIxOnce(binaryPath, ixArgs, lanes[lane].length + 1, { env: BENCH_ENV }));
    }
  }
  return {
    installed: { command: installedIx, args: ixArgs, ...summarizeIxRuns(installedIx, "installed", lanes.installed) },
    repo: { command: repoIx, args: ixArgs, ...summarizeIxRuns(repoIx, "repo", lanes.repo) },
    pairOrder,
    pairOrderSummary: pairOrderSummary(pairOrder, { firstLabel: "installed", secondLabel: "repo" }),
  };
}

function strictEvidenceFailures(host, processScan, identityControl) {
  const failures = [];
  if (samples < minRetainableSamples) failures.push(`underpowered_samples:${samples}<${minRetainableSamples}`);
  const hostIssues = [
    ...(host.before?.benchmarkEnvironment?.issues ?? []),
    ...(host.after?.benchmarkEnvironment?.issues ?? []),
  ].filter((issue) => issue?.severity === "warning");
  for (const issue of hostIssues) {
    failures.push(`host:${issue.id}:${issue.detail}`);
  }
  if (!processScan.before.ok) failures.push("process_scan_before_failed");
  if (!processScan.after.ok) failures.push("process_scan_after_failed");
  for (const failure of processScan.before.failures ?? []) failures.push(`process_scan_before:${failure}`);
  for (const failure of processScan.after.failures ?? []) failures.push(`process_scan_after:${failure}`);
  if (processScan.before.matched.length > 0) failures.push(`stale_processes_before:${processScan.before.matched.length}`);
  if (processScan.after.matched.length > 0) failures.push(`stale_processes_after:${processScan.after.matched.length}`);
  failures.push(...identityControlFailures({
    identityControl,
    enabled: identityControlEnabled,
    requiredSamples: Math.min(12, samples),
  }));
  return failures;
}

function promotionFailures(host, processScan, installedHash, repoHash, installedRepoComparison, identityControl) {
  const failures = [];
  if (samples < minRetainableSamples) failures.push(`underpowered_samples:${samples}<${minRetainableSamples}`);
  const hostIssues = [
    ...(host.before?.benchmarkEnvironment?.issues ?? []),
    ...(host.after?.benchmarkEnvironment?.issues ?? []),
  ].filter((issue) => issue?.severity === "warning");
  for (const issue of hostIssues) {
    failures.push(`host:${issue.id}:${issue.detail}`);
  }
  if (!processScan.before.ok) failures.push("process_scan_before_failed");
  if (!processScan.after.ok) failures.push("process_scan_after_failed");
  for (const failure of processScan.before.failures ?? []) failures.push(`process_scan_before:${failure}`);
  for (const failure of processScan.after.failures ?? []) failures.push(`process_scan_after:${failure}`);
  if (processScan.before.matched.length > 0) failures.push(`stale_processes_before:${processScan.before.matched.length}`);
  if (processScan.after.matched.length > 0) failures.push(`stale_processes_after:${processScan.after.matched.length}`);
  failures.push(...identityControlFailures({
    identityControl,
    enabled: identityControlEnabled,
    requiredSamples: Math.min(12, samples),
  }));
  if (!installedRepoComparison.matchParity) failures.push("match_parity_failed");
  if (installedRepoComparison.routeParityAcceptable !== true) {
    failures.push(`route_parity_failed:${installedRepoComparison.routeParityStatus ?? "unknown"}`);
  }
  if (installedHash === repoHash) return failures;
  const requiredImprovementPct = Number(installedRepoComparison.score?.requiredImprovementPct ?? installedRepoComparison.effectiveInstalledImprovementPct ?? minInstalledImprovementPct);
  if (installedRepoComparison.repoEngineMedianMs >= installedRepoComparison.installedEngineMedianMs) {
    failures.push(`repo_not_faster:${installedRepoComparison.repoEngineMedianMs}>=${installedRepoComparison.installedEngineMedianMs}`);
  }
  if (
    Number.isFinite(installedRepoComparison.installedEngineDeltaPct) &&
    installedRepoComparison.installedEngineDeltaPct < requiredImprovementPct
  ) {
    failures.push(`installed_improvement_below_target:${installedRepoComparison.installedEngineDeltaPct}<${requiredImprovementPct}`);
  }
  const pairedImprovementMedianPct = Number(installedRepoComparison.pairedEngine?.candidateImprovementPctSummary?.median);
  if (!Number.isFinite(pairedImprovementMedianPct) || pairedImprovementMedianPct < requiredImprovementPct) {
    failures.push(`installed_paired_improvement_below_target:${Number.isFinite(pairedImprovementMedianPct) ? pairedImprovementMedianPct : "missing"}<${requiredImprovementPct}`);
  }
  const candidateWinRate = Number(installedRepoComparison.pairedEngine?.candidateWinRate);
  if (!Number.isFinite(candidateWinRate) || candidateWinRate <= 0.5) {
    failures.push(`repo_paired_win_majority_required:${Number.isFinite(candidateWinRate) ? candidateWinRate : "missing"}`);
  }
  if (
    installedRepoComparison.score?.teddyRouteObserved === true &&
    installedRepoComparison.score?.teddyRouteNetPositive !== true
  ) {
    failures.push("repo_teddy_route_not_net_positive");
  }
  return failures;
}

if (samples < 1 || !Number.isFinite(samples)) throw new Error("--samples must be a positive number");
if (threads < 1 || !Number.isFinite(threads)) throw new Error("--threads must be a positive number");
if (identityControlSamples < 0 || !Number.isFinite(identityControlSamples)) throw new Error("--identity-control-samples must be a non-negative number");
if (minRetainableSamples < 1 || !Number.isFinite(minRetainableSamples)) throw new Error("--min-retainable-samples must be a positive number");
if (minInstalledImprovementPct < 0 || !Number.isFinite(minInstalledImprovementPct)) throw new Error("--min-installed-improvement-pct must be a non-negative number");
if (identityNoiseMultiplier < 0 || !Number.isFinite(identityNoiseMultiplier)) throw new Error("--identity-noise-multiplier must be a non-negative number");
if (!existsSync(corpus)) throw new Error(`corpus not found: ${corpus}`);
if (!existsSync(installedIx)) throw new Error(`installed IX not found: ${installedIx}`);
if (benchmarkLock) acquireBenchmarkLock({ script: "compare-installed-speed.mjs" });
if (buildFirst) {
  requireOk(run(resolveZigExe(), ["build", "-Doptimize=ReleaseFast", "--summary", "all"]), "ReleaseFast build");
}
if (!existsSync(repoIx)) throw new Error(`repo IX not found: ${repoIx}`);

const hostBefore = hostSnapshot();
const processBefore = scanIxProcesses({ ixBinary: repoIx, env: BENCH_ENV });
const ripgrep = measureRipgrep({ expression, defaultExpression: DEFAULT_EXPR, corpus, threads, samples, env: BENCH_ENV });
const identityControl = measureSameBinaryIdentityControl({
  binaryPath: repoIx,
  ixArgs: ["search", expression, corpus, "--json", "--stats-only", "--threads", String(threads)],
  samples: identityControlSamples,
  env: BENCH_ENV,
  enabled: identityControlEnabled,
  label: "repo-control",
});
const effectiveInstalledImprovementPct = effectiveImprovementTargetPct({
  configuredPct: minInstalledImprovementPct,
  identityControl,
  noiseMultiplier: identityNoiseMultiplier,
});
const paired = measurePairedIx();
const processAfter = scanIxProcesses({ ixBinary: repoIx, env: BENCH_ENV });
const hostAfter = hostSnapshot();
const host = { before: hostBefore, after: hostAfter };
const processScan = { before: processBefore, after: processAfter };
const installedHash = fileHash(installedIx);
const repoHash = fileHash(repoIx);
const strictFailures = strictEvidenceFailures(host, processScan, identityControl);
const installedRepoEngineDeltaPct =
  ((paired.installed.engineSummary.median - paired.repo.engineSummary.median) /
    paired.installed.engineSummary.median) *
  100;
const installedRepoBinaryRelation = installedHash === repoHash ? "same_binary" : "different_binary";
const promotionMode = installedRepoBinaryRelation === "same_binary" ? "current_install_identity" : "candidate_vs_installed";
const installedRepoRoute = routeParityEvaluation(paired.installed, paired.repo);
const installedRepoComparison = {
  binaryRelation: installedRepoBinaryRelation,
  evidenceAuthority: installedRepoBinaryRelation === "same_binary" ? "identity_noise_only" : "installed_vs_repo",
  installedEngineMedianMs: paired.installed.engineSummary.median,
  repoEngineMedianMs: paired.repo.engineSummary.median,
  installedDiscoverMedianMs: paired.installed.discoverSummary.median,
  repoDiscoverMedianMs: paired.repo.discoverSummary.median,
  installedScanMedianMs: paired.installed.scanSummary.median,
  repoScanMedianMs: paired.repo.scanSummary.median,
  installedAggregateMedianMs: paired.installed.aggregateSummary.median,
  repoAggregateMedianMs: paired.repo.aggregateSummary.median,
  installedScanWorkMedianMs: paired.installed.scanWorkSummary.median,
  repoScanWorkMedianMs: paired.repo.scanWorkSummary.median,
  installedScanOpenMedianMs: paired.installed.scanOpenSummary.median,
  repoScanOpenMedianMs: paired.repo.scanOpenSummary.median,
  installedScanFileMedianMs: paired.installed.scanFileSummary.median,
  repoScanFileMedianMs: paired.repo.scanFileSummary.median,
  installedAlternateFullScanCallsMedian: paired.installed.alternateFullScanCallsSummary.median,
  repoAlternateFullScanCallsMedian: paired.repo.alternateFullScanCallsSummary.median,
  installedAlternateFullScanBytesMedian: paired.installed.alternateFullScanBytesSummary.median,
  repoAlternateFullScanBytesMedian: paired.repo.alternateFullScanBytesSummary.median,
  installedAlternateFullScanMatchesMedian: paired.installed.alternateFullScanMatchesSummary.median,
  repoAlternateFullScanMatchesMedian: paired.repo.alternateFullScanMatchesSummary.median,
  installedAlternateTeddyRangeElapsedNsMedian: paired.installed.alternateTeddyRangeElapsedNsTotalSummary.median,
  repoAlternateTeddyRangeElapsedNsMedian: paired.repo.alternateTeddyRangeElapsedNsTotalSummary.median,
  installedEngineDeltaPct: installedRepoEngineDeltaPct,
  minInstalledImprovementPct,
  effectiveInstalledImprovementPct,
  identityNoiseMultiplier,
  identityNoiseMedianDeltaPct: identityControl?.medianDeltaPct ?? null,
  matchParity:
    paired.installed.matchCounts.length === 1 &&
    paired.repo.matchCounts.length === 1 &&
    paired.installed.matchCounts[0] === paired.repo.matchCounts[0],
  installedRoute: installedRepoRoute.baselineRoute,
  repoRoute: installedRepoRoute.candidateRoute,
  routeParity: installedRepoRoute.parity,
  routeParityComparable: installedRepoRoute.comparable,
  routeParityStatus: installedRepoRoute.status,
  routeParityAcceptable: installedRepoRoute.acceptable,
  pairOrder: paired.pairOrder,
  pairOrderSummary: paired.pairOrderSummary,
};
installedRepoComparison.pairedEngine = pairedEngineStats(paired.installed.samples, paired.repo.samples, {
  baselineLabel: "installed",
  candidateLabel: "repo",
});
installedRepoComparison.score = buildInstalledComparisonScore({
  comparison: installedRepoComparison,
  binaryRelation: installedRepoBinaryRelation,
  improvementPct: installedRepoEngineDeltaPct,
  pairedEngine: installedRepoComparison.pairedEngine,
  minInstalledImprovementPct: effectiveInstalledImprovementPct,
});
const scorecard = buildInstalledScorecard({
  score: installedRepoComparison.score,
  binaryRelation: installedRepoBinaryRelation,
});
const binaries = {
  installed: { path: installedIx, sha256: installedHash },
  repo: { path: repoIx, sha256: repoHash },
};
const roundLedger = buildInstalledRoundLedger({
  comparison: installedRepoComparison,
  score: installedRepoComparison.score,
  binaryRelation: installedRepoBinaryRelation,
  binaries,
});
const ledgerSummary = buildRoundLedgerSummary(roundLedger);
const promotionFailureList = promotionFailures(host, processScan, installedHash, repoHash, installedRepoComparison, identityControl);
const requiredGateFailures = [];
if (requireStrict && strictFailures.length > 0) {
  requiredGateFailures.push({
    gate: "strict",
    reason: "strict evidence required",
    failures: strictFailures,
  });
}
if (requirePromotion && promotionFailureList.length > 0) {
  requiredGateFailures.push({
    gate: promotionMode === "current_install_identity" ? "installed_identity" : "promotion",
    reason: promotionMode === "current_install_identity" ? "clean installed identity evidence required" : "promotion evidence required",
    failures: promotionFailureList,
  });
}

const report = {
  runId: `installed-speed-${timestampSlug()}`,
  timestamp: new Date().toISOString(),
  corpus,
  expression,
  samples,
  minRetainableSamples,
  minInstalledImprovementPct,
  effectiveInstalledImprovementPct,
  identityNoiseMultiplier,
  identityControlSamples: identityControlEnabled ? identityControlSamples : 0,
  threads,
  benchEnv: BENCH_ENV,
  host,
  processScan,
  retainableStrictEvidence: strictFailures.length === 0,
  strictEvidenceFailures: strictFailures,
  binaries,
  lanes: {
    ripgrep,
    identityControl,
    installed: paired.installed,
    repo: paired.repo,
  },
  identityControl,
  installedRepoComparison,
  scorecard,
  roundLedger,
  ledgerSummary,
  promotionMode,
  promotionQualified: promotionFailureList.length === 0,
  promotionFailures: promotionFailureList,
  requiredGateFailures,
};

report.deltasPct = {
  installedEngineVsRepoEngine: installedRepoEngineDeltaPct,
  installedCliVsRipgrepCli:
    ((report.lanes.installed.cliSummary.median - report.lanes.ripgrep.summary.median) /
      report.lanes.ripgrep.summary.median) *
    100,
  repoCliVsRipgrepCli:
    ((report.lanes.repo.cliSummary.median - report.lanes.ripgrep.summary.median) /
      report.lanes.ripgrep.summary.median) *
    100,
};

mkdirSync(REPORT_DIR, { recursive: true });
const outPath = path.join(REPORT_DIR, `${report.runId}.json`);
writeFileSync(outPath, `${JSON.stringify(report, null, 2)}\n`, "utf8");
writeFileSync(path.join(REPORT_DIR, "latest-installed-speed.json"), `${JSON.stringify(report, null, 2)}\n`, "utf8");

if (!quiet) {
  console.log(JSON.stringify({ outPath, retainableStrictEvidence: report.retainableStrictEvidence, promotionQualified: report.promotionQualified, binaries: report.binaries, medians: {
    ripgrepCliMs: report.lanes.ripgrep.summary.median,
    installedCliMs: report.lanes.installed.cliSummary.median,
    installedEngineMs: report.lanes.installed.engineSummary.median,
    repoCliMs: report.lanes.repo.cliSummary.median,
    repoEngineMs: report.lanes.repo.engineSummary.median,
  }, identityControl: report.lanes.identityControl ? {
    samples: report.lanes.identityControl.samples,
    firstEngineMedianMs: report.lanes.identityControl.first.engineSummary.median,
    secondEngineMedianMs: report.lanes.identityControl.second.engineSummary.median,
    medianDeltaPct: report.lanes.identityControl.medianDeltaPct,
    pairedWinRate: report.lanes.identityControl.pairedEngine.candidateWinRate,
    matchParity: report.lanes.identityControl.matchParity,
    routeParity: report.lanes.identityControl.routeParity,
  } : null, installedRepoComparison: report.installedRepoComparison, scorecard: report.scorecard, roundLedger: report.roundLedger, ledgerSummary: report.ledgerSummary, strictEvidenceFailures: report.strictEvidenceFailures, promotionFailures: report.promotionFailures, requiredGateFailures: report.requiredGateFailures, staleProcessesBefore: report.processScan.before.matched.length, staleProcessesAfter: report.processScan.after.matched.length, deltasPct: report.deltasPct }, null, 2));
}

if (report.requiredGateFailures.length > 0) {
  console.error(JSON.stringify({ status: "failed", failures: report.requiredGateFailures, outPath }, null, 2));
  process.exit(report.requiredGateFailures.some((failure) => failure.gate === "promotion") ? 3 : 2);
}
