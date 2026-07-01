import { existsSync, mkdirSync, readdirSync, statSync, writeFileSync } from "node:fs";
import os from "node:os";
import path from "node:path";
import { baseBenchEnv, defaultRepoIxPath, DEFAULT_ALTERNATES_EXPRESSION, DEFAULT_NATIVE_INSTALL_DIR, DEFAULT_RIPGREP_LINUX_CORPUS } from "./lib/benchmark-config.mjs";
import { hostSnapshot } from "./lib/benchmark-runner.mjs";
import { benchmarkEvidenceFailures, evidenceQualityFromFailures } from "./lib/benchmark-evidence-quality.mjs";
import { argValue, timestampSlug } from "./lib/script-helpers.mjs";
import { acquireBenchmarkLock, benchmarkEnvSnapshot, binarySnapshot, buildHistoricalComparisonScore, buildHistoricalGateDiagnostic, buildHistoricalRoundLedger, buildHistoricalScorecard, buildRoundLedgerSummary, dependencyTreeSnapshot, effectiveImprovementTargetPct, fileHash, measureIxOnce, measureRipgrep, measureRipgrepMmapComparison, measureSameBinaryIdentityControl, orderStratifiedEngineStats, pairedEngineStats, pairOrderSummary, phaseLeakSummaryFromRounds, requireOk, routeParityEvaluation, run, scanIxProcesses, summarizeIxRuns } from "./lib/speed-compare-utils.mjs";

const ROOT = process.cwd();
const REPORT_DIR = path.join(ROOT, "tools", "reports", "historical-speed");
const LATEST_HISTORICAL_PATH = path.join(REPORT_DIR, "latest-historical-speed.json");
const LATEST_RETAINABLE_HISTORICAL_PATH = path.join(REPORT_DIR, "latest-retainable-historical-speed.json");
const LATEST_FAILED_HISTORICAL_PATH = path.join(REPORT_DIR, "latest-failed-historical-speed.json");
const DEFAULT_CORPUS = DEFAULT_RIPGREP_LINUX_CORPUS;
const DEFAULT_EXPR = DEFAULT_ALTERNATES_EXPRESSION;
const DEFAULT_INSTALL_DIR = DEFAULT_NATIVE_INSTALL_DIR;
const DEFAULT_REPO_IX = defaultRepoIxPath(ROOT);
const BASE_BENCH_ENV = baseBenchEnv("historical");

const args = process.argv.slice(2);
if (args.includes("--help") || args.includes("-h")) {
  console.log(`Usage: node tools/scripts/compare-historical-speed.mjs [options]

Compares repo IX against native installed IX backups on the ripgrep linux
benchsuite, with ripgrep measured first and route/match parity recorded.

Options:
  --build                               Build repo IX ReleaseFast before measuring.
  --samples <n>                         Samples per comparison. Default: 6.
  --threads <n>                         IX/ripgrep thread count. Default: 32.
  --identity-control-samples <n>        Same-binary control pairs. Default: min(12, samples).
  --identity-control-attempts <n>       Same-binary control attempts; first stable attempt is selected. Default: 1.
  --no-identity-control                 Disable same-binary noise control.
  --max-backups <n>                     Unique installed backups to compare. Default: 6.
  --corpus <path>                       Corpus path.
  --expression <expr>                   Search expression.
  --repo-ix <path>                      Repo IX binary path.
  --install-dir <path>                  Native install bin directory.
  --include-current-install             Include current ix.exe as an identity-noise diagnostic.
  --min-retainable-samples <n>          Minimum samples for strict evidence.
  --min-previous-build-improvement-pct <n>
                                       Required improvement over previous builds. Default: 0.
  --identity-noise-multiplier <n>      Effective target multiplier for same-binary drift. Default: 0.
  --scan-open-timing                   Enable scan open/file subphase timing in IX telemetry.
  --linux-dominant-attribution         Enable Linux AMD ASIC register slow-file attribution in IX telemetry.
  --no-benchmark-lock                  Disable the cross-script benchmark lock.
  --require-strict                     Exit non-zero unless strict evidence passes. Default behavior.
  --no-require-strict                  Allow exploratory reports to exit zero when strict evidence fails.
  --quiet                               Write reports without printing summary.
  --help, -h                            Print this help and exit without measuring.
`);
  process.exit(0);
}
const corpus = argValue(args, "--corpus", DEFAULT_CORPUS);
const expression = argValue(args, "--expression", DEFAULT_EXPR);
const repoIx = argValue(args, "--repo-ix", DEFAULT_REPO_IX);
const installDir = argValue(args, "--install-dir", DEFAULT_INSTALL_DIR);
const samples = Number(argValue(args, "--samples", "6"));
const threads = Number(argValue(args, "--threads", "32"));
const identityControlSamples = Number(argValue(args, "--identity-control-samples", String(Math.min(12, samples))));
const identityControlAttempts = Number(argValue(args, "--identity-control-attempts", process.env.IX_IDENTITY_CONTROL_ATTEMPTS ?? "1"));
const identityControlEnabled = !args.includes("--no-identity-control");
const maxBackups = Number(argValue(args, "--max-backups", "6"));
const includeCurrentInstall = args.includes("--include-current-install");
const buildFirst = args.includes("--build");
const minRetainableSamples = Number(argValue(args, "--min-retainable-samples", process.env.IX_MIN_RETAINABLE_SPEED_SAMPLES ?? "12"));
const minPreviousBuildImprovementPct = Number(argValue(args, "--min-previous-build-improvement-pct", process.env.IX_MIN_PREVIOUS_BUILD_IMPROVEMENT_PCT ?? "0"));
const identityNoiseMultiplier = Number(argValue(args, "--identity-noise-multiplier", process.env.IX_IDENTITY_NOISE_MULTIPLIER ?? "0"));
const scanOpenTiming = args.includes("--scan-open-timing");
const linuxDominantAttribution = args.includes("--linux-dominant-attribution");
const diagnosticAttributionMode = scanOpenTiming || linuxDominantAttribution;
const benchmarkLock = !args.includes("--no-benchmark-lock");
const quiet = args.includes("--quiet");
const requireStrict = !args.includes("--no-require-strict");
const BENCH_ENV = {
  ...BASE_BENCH_ENV,
  IX_SCAN_OPEN_TIMING: scanOpenTiming ? "1" : "0",
  IX_LINUX_DOMINANT_ATTRIBUTION: linuxDominantAttribution ? "1" : "0",
};

function resolveZigExe() {
  const local = path.join(os.homedir(), ".local", "zig", "zig-x86_64-windows-0.16.0", "zig.exe");
  return existsSync(local) ? local : "zig";
}

function measurePairedHistory(history, ixArgs, effectivePreviousBuildImprovementPct) {
  const currentRuns = [];
  const historyRuns = [];
  const pairOrder = [];
  for (let pair = 0; pair < samples; pair += 1) {
    const historyFirst = pair % 2 === 0;
    pairOrder.push(historyFirst ? "history,current" : "current,history");
    if (historyFirst) {
      historyRuns.push(measureIxOnce(history.path, ixArgs, historyRuns.length + 1, { env: BENCH_ENV }));
      currentRuns.push(measureIxOnce(repoIx, ixArgs, currentRuns.length + 1, { env: BENCH_ENV }));
    } else {
      currentRuns.push(measureIxOnce(repoIx, ixArgs, currentRuns.length + 1, { env: BENCH_ENV }));
      historyRuns.push(measureIxOnce(history.path, ixArgs, historyRuns.length + 1, { env: BENCH_ENV }));
    }
  }

  const current = summarizeIxRuns(repoIx, "repo-current", currentRuns);
  const historical = summarizeIxRuns(history.path, history.label, historyRuns);
  const sameBinary = current.sha256 === historical.sha256;
  const currentVsHistoryEngineRatio = current.engineSummary.median / historical.engineSummary.median;
  const currentEngineDeltaMs = current.engineSummary.median - historical.engineSummary.median;
  const currentEngineImprovementPct = Number.isFinite(currentVsHistoryEngineRatio)
    ? (1 - currentVsHistoryEngineRatio) * 100
    : null;
  const promotionQualified = sameBinary
    ? null
    : Number.isFinite(currentEngineImprovementPct) && currentEngineImprovementPct >= effectivePreviousBuildImprovementPct;
  const paired = pairedEngineStats(historical.samples, current.samples, {
    baselineLabel: "historical",
    candidateLabel: "current",
  });
  const orderSummary = pairOrderSummary(pairOrder, { firstLabel: "history", secondLabel: "current" });
  const orderStratified = orderStratifiedEngineStats(historical.samples, current.samples, pairOrder, {
    baselineLabel: "history",
    candidateLabel: "current",
  });
  const matchParity =
    current.matchCounts.length === 1 &&
    historical.matchCounts.length === 1 &&
    current.matchCounts[0] === historical.matchCounts[0];
  const routes = routeParityEvaluation(historical, current);
  const score = buildHistoricalComparisonScore({
    roundIndex: history.roundIndex,
    baselineLabel: history.label,
    sameBinary,
    improvementPct: currentEngineImprovementPct,
    ratio: currentVsHistoryEngineRatio,
    deltaMs: currentEngineDeltaMs,
    pairedEngine: paired,
    minPreviousBuildImprovementPct: effectivePreviousBuildImprovementPct,
    matchParity,
    routeParity: routes.parity,
    routeParityComparable: routes.comparable,
    routeParityStatus: routes.status,
    routeParityAcceptable: routes.acceptable,
    pairOrderSummary: orderSummary,
    orderStratifiedEngine: orderStratified,
    historyEngineMedianMs: historical.engineSummary.median,
    currentEngineMedianMs: current.engineSummary.median,
  });
  return {
    roundIndex: history.roundIndex,
    label: history.label,
    path: history.path,
    sha256: historical.sha256,
    relation: sameBinary ? "same_binary" : "different_binary",
    current,
    historical,
    currentRoute: routes.candidateRoute,
    historicalRoute: routes.baselineRoute,
    currentRouteKinds: routes.candidateRouteKinds,
    historicalRouteKinds: routes.baselineRouteKinds,
    routeParity: routes.parity,
    routeCardinalityParity: routes.cardinalityParity,
    routeParityComparable: routes.comparable,
    routeParityStatus: routes.status,
    routeParityAcceptable: routes.acceptable,
    pairOrder,
    pairOrderSummary: orderSummary,
    orderStratifiedEngine: orderStratified,
    pairedEngine: paired,
    currentVsHistoryEngineRatio,
    currentEngineDeltaMs,
    currentEngineImprovementPct,
    minPreviousBuildImprovementPct: effectivePreviousBuildImprovementPct,
    configuredPreviousBuildImprovementPct: minPreviousBuildImprovementPct,
    effectivePreviousBuildImprovementPct,
    identityNoiseMultiplier,
    promotionQualified,
    matchParity: score.matchParity,
    historyEngineMedianMs: historical.engineSummary.median,
    currentEngineMedianMs: current.engineSummary.median,
    historicalByteShardFilesProfiledMedian: historical.byteShardFilesProfiledSummary.median,
    currentByteShardFilesProfiledMedian: current.byteShardFilesProfiledSummary.median,
    historicalByteShardRangesMedian: historical.byteShardRangesSummary.median,
    currentByteShardRangesMedian: current.byteShardRangesSummary.median,
    historicalByteShardLogicalRangeBytesMedian: historical.byteShardLogicalRangeBytesSummary.median,
    currentByteShardLogicalRangeBytesMedian: current.byteShardLogicalRangeBytesSummary.median,
    historicalByteShardWidenedRangeBytesMedian: historical.byteShardWidenedRangeBytesSummary.median,
    currentByteShardWidenedRangeBytesMedian: current.byteShardWidenedRangeBytesSummary.median,
    historicalByteShardOverlapBytesMedian: historical.byteShardOverlapBytesSummary.median,
    currentByteShardOverlapBytesMedian: current.byteShardOverlapBytesSummary.median,
    historicalByteShardRangeBytesAvgMedian: historical.byteShardRangeBytesAvgSummary.median,
    currentByteShardRangeBytesAvgMedian: current.byteShardRangeBytesAvgSummary.median,
    historicalByteShardRangeElapsedNsMedian: historical.byteShardRangeElapsedNsTotalSummary.median,
    currentByteShardRangeElapsedNsMedian: current.byteShardRangeElapsedNsTotalSummary.median,
    historicalByteShardRangeElapsedNsMaxMedian: historical.byteShardRangeElapsedNsMaxSummary.median,
    currentByteShardRangeElapsedNsMaxMedian: current.byteShardRangeElapsedNsMaxSummary.median,
    evidenceAuthority: sameBinary ? "identity_noise_only" : "previous_build",
    score,
  };
}

function backupCandidates() {
  const current = path.join(installDir, "ix.exe");
  const candidates = [];
  for (const name of readdirSync(installDir)) {
    if (!/^ix\.exe\.backup-/.test(name)) continue;
    const fullPath = path.join(installDir, name);
    candidates.push({ label: name.replace(/^ix\.exe\./, ""), path: fullPath, mtimeMs: statSync(fullPath).mtimeMs, source: "backup" });
  }
  if (includeCurrentInstall && existsSync(current)) {
    candidates.push({ label: "installed-current", path: current, mtimeMs: statSync(current).mtimeMs, source: "current_install" });
  }
  candidates.sort((left, right) => right.mtimeMs - left.mtimeMs);

  const seen = new Set();
  const unique = [];
  for (const candidate of candidates) {
    const sha256 = fileHash(candidate.path);
    if (seen.has(sha256)) continue;
    seen.add(sha256);
    unique.push({ ...candidate, sha256, roundIndex: unique.length + 1 });
    if (unique.length >= maxBackups) break;
  }
  return unique;
}

function strictEvidenceFailures(host, processScan, comparisons, identityControl) {
  const failures = benchmarkEvidenceFailures({
    samples,
    minRetainableSamples,
    host,
    processScan,
    identityControl,
    identityControlEnabled,
    requiredIdentitySamples: Math.min(12, samples),
  });
  if (diagnosticAttributionMode) failures.push("diagnostic_attribution_run_not_retainable_evidence");
  const previousBuilds = comparisons.filter((comparison) => comparison.evidenceAuthority === "previous_build");
  if (previousBuilds.length === 0) failures.push("missing_previous_build_comparison");
  for (const comparison of previousBuilds) {
    if (comparison.matchParity !== true) failures.push(`match_parity_failed:${comparison.label}`);
    if (Number.isFinite(comparison.currentVsHistoryEngineRatio) && comparison.currentVsHistoryEngineRatio > 1) {
      failures.push(`previous_build_regression:${comparison.label}:${comparison.currentVsHistoryEngineRatio}`);
    }
    const requiredImprovementPct = Number(comparison.score?.requiredImprovementPct ?? comparison.effectivePreviousBuildImprovementPct ?? comparison.minPreviousBuildImprovementPct);
    if (Number.isFinite(comparison.currentEngineImprovementPct) && comparison.currentEngineImprovementPct < requiredImprovementPct) {
      failures.push(`previous_build_improvement_below_target:${comparison.label}:${comparison.currentEngineImprovementPct}<${requiredImprovementPct}`);
    }
    const candidateWinRate = Number(comparison.pairedEngine?.candidateWinRate);
    if (!Number.isFinite(candidateWinRate) || candidateWinRate <= 0.5) {
      failures.push(`previous_build_paired_win_majority_required:${comparison.label}:${Number.isFinite(candidateWinRate) ? candidateWinRate : "missing"}`);
    }
    if (comparison.score?.teddyRouteObserved === true && comparison.score?.teddyRouteNetPositive !== true) {
      failures.push(`previous_build_teddy_route_not_net_positive:${comparison.label}`);
    }
  }
  return failures;
}

function median(values) {
  const finite = values.map(Number).filter(Number.isFinite).sort((left, right) => left - right);
  if (finite.length === 0) return null;
  return finite[Math.floor((finite.length - 1) / 2)];
}

if (!Number.isFinite(samples) || samples < 1) throw new Error("--samples must be a positive number");
if (!Number.isFinite(threads) || threads < 1) throw new Error("--threads must be a positive number");
if (!Number.isFinite(identityControlSamples) || identityControlSamples < 0) throw new Error("--identity-control-samples must be a non-negative number");
if (!Number.isFinite(identityControlAttempts) || identityControlAttempts < 1) throw new Error("--identity-control-attempts must be a positive number");
if (!Number.isFinite(maxBackups) || maxBackups < 1) throw new Error("--max-backups must be a positive number");
if (!Number.isFinite(minRetainableSamples) || minRetainableSamples < 1) throw new Error("--min-retainable-samples must be a positive number");
if (!Number.isFinite(minPreviousBuildImprovementPct) || minPreviousBuildImprovementPct < 0) throw new Error("--min-previous-build-improvement-pct must be a non-negative number");
if (!Number.isFinite(identityNoiseMultiplier) || identityNoiseMultiplier < 0) throw new Error("--identity-noise-multiplier must be a non-negative number");
if (!existsSync(corpus)) throw new Error(`corpus not found: ${corpus}`);
if (!existsSync(installDir)) throw new Error(`install dir not found: ${installDir}`);
if (benchmarkLock) acquireBenchmarkLock({ script: "compare-historical-speed.mjs" });
if (buildFirst) {
  requireOk(run(resolveZigExe(), ["build", "-Doptimize=ReleaseFast", "--summary", "all"]), "ReleaseFast build");
}
if (!existsSync(repoIx)) throw new Error(`repo IX not found: ${repoIx}`);

const ixArgs = ["search", expression, corpus, "--json", "--stats-only", "--threads", String(threads)];
const hostBefore = hostSnapshot();
const processBefore = scanIxProcesses({ ixBinary: repoIx, env: BENCH_ENV });
const ripgrep = measureRipgrep({ expression, defaultExpression: DEFAULT_EXPR, corpus, threads, samples, env: BENCH_ENV });
const ripgrepMmapComparison = measureRipgrepMmapComparison({ expression, defaultExpression: DEFAULT_EXPR, corpus, threads, samples, env: BENCH_ENV });
const currentIdentity = binarySnapshot(repoIx);
const installedIxPath = path.join(installDir, "ix.exe");
const installedIdentity = binarySnapshot(installedIxPath);
const identityControl = measureSameBinaryIdentityControl({
  binaryPath: repoIx,
  ixArgs,
  samples: identityControlSamples,
  attempts: identityControlAttempts,
  env: BENCH_ENV,
  enabled: identityControlEnabled,
  label: "repo-control",
});
const effectivePreviousBuildImprovementPct = effectiveImprovementTargetPct({
  configuredPct: minPreviousBuildImprovementPct,
  identityControl,
  noiseMultiplier: identityNoiseMultiplier,
});
const comparisons = backupCandidates().map((candidate) => measurePairedHistory(candidate, ixArgs, effectivePreviousBuildImprovementPct));
const processAfter = scanIxProcesses({ ixBinary: repoIx, env: BENCH_ENV });
const hostAfter = hostSnapshot();
const host = { before: hostBefore, after: hostAfter };
const processScan = { before: processBefore, after: processAfter };
const strictFailures = strictEvidenceFailures(host, processScan, comparisons, identityControl);
const strictEvidenceQuality = evidenceQualityFromFailures(strictFailures);
const scorecard = buildHistoricalScorecard(comparisons);
const roundLedger = buildHistoricalRoundLedger(comparisons);
const ledgerSummary = buildRoundLedgerSummary(roundLedger);
const phaseLeakSummary = phaseLeakSummaryFromRounds(roundLedger);
const historicalGateDiagnostic = buildHistoricalGateDiagnostic({
  currentIdentity,
  installedIdentity,
  roundLedger,
  scorecard,
  strictEvidenceFailures: strictFailures,
});
const medians = {
  ripgrepCliMs: ripgrep.summary?.median ?? null,
  ripgrepNoMmapCliMs: ripgrepMmapComparison?.never?.summary?.median ?? null,
  ripgrepFastestMmapMode: ripgrepMmapComparison?.fastest ?? null,
  currentEngineMs: median(comparisons.map((comparison) => comparison.current?.engineSummary?.median)),
  previousBuildEngineMs: median(comparisons
    .filter((comparison) => comparison.evidenceAuthority === "previous_build")
    .map((comparison) => comparison.historical?.engineSummary?.median)),
};
const requiredGateFailures = [];
if (requireStrict && strictFailures.length > 0) {
  requiredGateFailures.push({
    gate: "strict",
    reason: "strict historical evidence required",
    failures: strictFailures,
  });
}

const report = {
  runId: `historical-speed-${timestampSlug()}`,
  timestamp: new Date().toISOString(),
  corpus,
  expression,
  samples,
  buildFirst,
  identityControlSamples: identityControlEnabled ? identityControlSamples : 0,
  identityControlAttempts: identityControlEnabled ? identityControlAttempts : 0,
  minRetainableSamples,
  minPreviousBuildImprovementPct,
  effectivePreviousBuildImprovementPct,
  identityNoiseMultiplier,
  includeCurrentInstall,
  threads,
  scanOpenTiming,
  linuxDominantAttribution,
  diagnosticAttributionMode,
  benchEnv: BENCH_ENV,
  effectiveBenchEnv: benchmarkEnvSnapshot(BENCH_ENV),
  dependencyTrees: dependencyTreeSnapshot(ROOT),
  host,
  processScan,
  retainableStrictEvidence: strictFailures.length === 0,
  strictEvidenceFailures: strictFailures,
  evidenceQuality: strictEvidenceQuality,
  requiredGateFailures,
  ripgrep,
  ripgrepMmapComparison,
  currentIdentity,
  installedIdentity,
  identityControl,
  comparisons,
  medians,
  scorecard,
  roundLedger,
  ledgerSummary,
  phaseLeakSummary,
  historicalGateDiagnostic,
};

mkdirSync(REPORT_DIR, { recursive: true });
const outPath = path.join(REPORT_DIR, `${report.runId}.json`);
writeFileSync(outPath, `${JSON.stringify(report, null, 2)}\n`, "utf8");
writeFileSync(LATEST_HISTORICAL_PATH, `${JSON.stringify(report, null, 2)}\n`, "utf8");
if (report.retainableStrictEvidence && !diagnosticAttributionMode) {
  writeFileSync(LATEST_RETAINABLE_HISTORICAL_PATH, `${JSON.stringify(report, null, 2)}\n`, "utf8");
} else if (!diagnosticAttributionMode) {
  writeFileSync(LATEST_FAILED_HISTORICAL_PATH, `${JSON.stringify(report, null, 2)}\n`, "utf8");
}

if (!quiet) {
  console.log(JSON.stringify({
    outPath,
    retainableStrictEvidence: report.retainableStrictEvidence,
    strictEvidenceFailures: report.strictEvidenceFailures,
    requiredGateFailures: report.requiredGateFailures,
    currentIdentity,
    installedIdentity,
    historicalGateDiagnostic,
    identityControl: report.identityControl ? {
      samples: report.identityControl.samples,
      firstEngineMedianMs: report.identityControl.first.engineSummary.median,
      secondEngineMedianMs: report.identityControl.second.engineSummary.median,
      medianDeltaPct: report.identityControl.medianDeltaPct,
      pairedWinRate: report.identityControl.pairedEngine.candidateWinRate,
      matchParity: report.identityControl.matchParity,
      routeParity: report.identityControl.routeParity,
    } : null,
    evidenceQuality: report.evidenceQuality,
    ripgrepMedianMs: ripgrep.summary.median,
    ripgrepNoMmapMedianMs: ripgrepMmapComparison?.never?.summary?.median ?? null,
    ripgrepFastestMmapMode: ripgrepMmapComparison?.fastest ?? null,
    medians,
    comparisons: comparisons.map((comparison) => ({
      label: comparison.label,
      roundIndex: comparison.roundIndex,
      relation: comparison.relation,
      evidenceAuthority: comparison.evidenceAuthority,
      currentEngineMedianMs: comparison.current.engineSummary.median,
      historyEngineMedianMs: comparison.historyEngineMedianMs,
      currentVsHistoryEngineRatio: comparison.currentVsHistoryEngineRatio,
      currentEngineDeltaMs: comparison.currentEngineDeltaMs,
      currentEngineImprovementPct: comparison.currentEngineImprovementPct,
      pairedEngine: {
        currentWins: comparison.pairedEngine.candidateWins,
        historicalWins: comparison.pairedEngine.baselineWins,
        currentWinRate: comparison.pairedEngine.candidateWinRate,
        deltaMedianMs: comparison.pairedEngine.deltaSummary?.median ?? null,
        currentImprovementMedianPct: comparison.pairedEngine.candidateImprovementPctSummary?.median ?? null,
      },
      minPreviousBuildImprovementPct: comparison.minPreviousBuildImprovementPct,
      promotionQualified: comparison.promotionQualified,
      score: comparison.score,
      matchParity: comparison.matchParity,
      sha256: comparison.sha256,
    })),
    scorecard,
    roundLedger,
    ledgerSummary,
    phaseLeakSummary,
    staleProcessesBefore: processBefore.matched.length,
    staleProcessesAfter: processAfter.matched.length,
  }, null, 2));
}

if (report.requiredGateFailures.length > 0) {
  console.error(JSON.stringify({ status: "failed", failures: report.requiredGateFailures, outPath }, null, 2));
  process.exit(2);
}
