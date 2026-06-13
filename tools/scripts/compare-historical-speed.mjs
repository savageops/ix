import { existsSync, mkdirSync, readdirSync, statSync, writeFileSync } from "node:fs";
import os from "node:os";
import path from "node:path";
import { hostSnapshot } from "./lib/benchmark-runner.mjs";
import { benchmarkEvidenceFailures, evidenceQualityFromFailures } from "./lib/benchmark-evidence-quality.mjs";
import { argValue, timestampSlug } from "./lib/script-helpers.mjs";
import { acquireBenchmarkLock, buildHistoricalComparisonScore, buildHistoricalRoundLedger, buildHistoricalScorecard, buildRoundLedgerSummary, effectiveImprovementTargetPct, fileHash, measureIxOnce, measureRipgrep, measureSameBinaryIdentityControl, pairedEngineStats, pairOrderSummary, phaseLeakSummaryFromRounds, routeParityEvaluation, scanIxProcesses, summarizeIxRuns } from "./lib/speed-compare-utils.mjs";

const ROOT = process.cwd();
const REPORT_DIR = path.join(ROOT, "tools", "reports", "historical-speed");
const DEFAULT_CORPUS = "E:\\Workspaces\\01_Projects\\01_Github\\iEx\\.refs\\ripgrep\\benchsuite\\linux";
const DEFAULT_EXPR = "re:(?i)(ERR_SYS|PME_TURN_OFF|LINK_REQ_RST|CFG_BME_EVT)";
const DEFAULT_INSTALL_DIR = path.join(os.homedir(), "AppData", "Local", "Programs", "iEx", "bin");
const DEFAULT_REPO_IX = path.join(ROOT, "zig-out", "bin", process.platform === "win32" ? "ix-zig.exe" : "ix-zig");
const BENCH_STATE_DIR = path.join(os.tmpdir(), "ix-zig-historical-speed-state");
const BENCH_ENV = {
  IX_INDEX: "0",
  IX_NEXUS: "0",
  IX_SCAN_OPEN_TIMING: "0",
  IX_STATE_DIR: BENCH_STATE_DIR,
};

const args = process.argv.slice(2);
if (args.includes("--help") || args.includes("-h")) {
  console.log(`Usage: node tools/scripts/compare-historical-speed.mjs [options]

Compares repo IX against native installed IX backups on the ripgrep linux
benchsuite, with ripgrep measured first and route/match parity recorded.

Options:
  --samples <n>                         Samples per comparison. Default: 6.
  --threads <n>                         IX/ripgrep thread count. Default: 32.
  --identity-control-samples <n>        Same-binary control pairs. Default: min(12, samples).
  --no-identity-control                 Disable same-binary noise control.
  --max-backups <n>                     Unique installed backups to compare. Default: 6.
  --corpus <path>                       Corpus path.
  --expression <expr>                   Search expression.
  --repo-ix <path>                      Repo IX binary path.
  --install-dir <path>                  Native install bin directory.
  --include-current-install             Include current ix.exe as an identity-noise diagnostic.
  --min-retainable-samples <n>          Minimum samples for strict evidence.
  --min-previous-build-improvement-pct <n>
                                       Required improvement over previous builds. Default: 5.
  --identity-noise-multiplier <n>      Effective target multiplier for same-binary drift. Default: 3.
  --no-benchmark-lock                  Disable the cross-script benchmark lock.
  --require-strict                     Exit non-zero unless strict evidence passes.
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
const identityControlEnabled = !args.includes("--no-identity-control");
const maxBackups = Number(argValue(args, "--max-backups", "6"));
const includeCurrentInstall = args.includes("--include-current-install");
const minRetainableSamples = Number(argValue(args, "--min-retainable-samples", process.env.IX_MIN_RETAINABLE_SPEED_SAMPLES ?? "12"));
const minPreviousBuildImprovementPct = Number(argValue(args, "--min-previous-build-improvement-pct", process.env.IX_MIN_PREVIOUS_BUILD_IMPROVEMENT_PCT ?? "5"));
const identityNoiseMultiplier = Number(argValue(args, "--identity-noise-multiplier", process.env.IX_IDENTITY_NOISE_MULTIPLIER ?? "3"));
const benchmarkLock = !args.includes("--no-benchmark-lock");
const quiet = args.includes("--quiet");
const requireStrict = args.includes("--require-strict");

function measurePairedHistory(history, ixArgs, effectivePreviousBuildImprovementPct) {
  const currentRuns = [];
  const historyRuns = [];
  const pairOrder = [];
  for (let pair = 0; pair < samples; pair += 1) {
    const currentFirst = pair % 2 === 0;
    pairOrder.push(currentFirst ? "current,history" : "history,current");
    if (currentFirst) {
      currentRuns.push(measureIxOnce(repoIx, ixArgs, currentRuns.length + 1, { env: BENCH_ENV }));
      historyRuns.push(measureIxOnce(history.path, ixArgs, historyRuns.length + 1, { env: BENCH_ENV }));
    } else {
      historyRuns.push(measureIxOnce(history.path, ixArgs, historyRuns.length + 1, { env: BENCH_ENV }));
      currentRuns.push(measureIxOnce(repoIx, ixArgs, currentRuns.length + 1, { env: BENCH_ENV }));
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
  const orderSummary = pairOrderSummary(pairOrder, { firstLabel: "current", secondLabel: "history" });
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
    routeParity: routes.parity,
    routeParityComparable: routes.comparable,
    routeParityStatus: routes.status,
    routeParityAcceptable: routes.acceptable,
    pairOrder,
    pairOrderSummary: orderSummary,
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
if (!Number.isFinite(maxBackups) || maxBackups < 1) throw new Error("--max-backups must be a positive number");
if (!Number.isFinite(minRetainableSamples) || minRetainableSamples < 1) throw new Error("--min-retainable-samples must be a positive number");
if (!Number.isFinite(minPreviousBuildImprovementPct) || minPreviousBuildImprovementPct < 0) throw new Error("--min-previous-build-improvement-pct must be a non-negative number");
if (!Number.isFinite(identityNoiseMultiplier) || identityNoiseMultiplier < 0) throw new Error("--identity-noise-multiplier must be a non-negative number");
if (!existsSync(corpus)) throw new Error(`corpus not found: ${corpus}`);
if (!existsSync(repoIx)) throw new Error(`repo IX not found: ${repoIx}`);
if (!existsSync(installDir)) throw new Error(`install dir not found: ${installDir}`);
if (benchmarkLock) acquireBenchmarkLock({ script: "compare-historical-speed.mjs" });

const ixArgs = ["search", expression, corpus, "--json", "--stats-only", "--threads", String(threads)];
const hostBefore = hostSnapshot();
const processBefore = scanIxProcesses({ ixBinary: repoIx, env: BENCH_ENV });
const ripgrep = measureRipgrep({ expression, defaultExpression: DEFAULT_EXPR, corpus, threads, samples, env: BENCH_ENV });
const currentIdentity = { path: repoIx, sha256: fileHash(repoIx) };
const identityControl = measureSameBinaryIdentityControl({
  binaryPath: repoIx,
  ixArgs,
  samples: identityControlSamples,
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
const medians = {
  ripgrepCliMs: ripgrep.summary?.median ?? null,
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
  identityControlSamples: identityControlEnabled ? identityControlSamples : 0,
  minRetainableSamples,
  minPreviousBuildImprovementPct,
  effectivePreviousBuildImprovementPct,
  identityNoiseMultiplier,
  includeCurrentInstall,
  threads,
  benchEnv: BENCH_ENV,
  host,
  processScan,
  retainableStrictEvidence: strictFailures.length === 0,
  strictEvidenceFailures: strictFailures,
  evidenceQuality: strictEvidenceQuality,
  requiredGateFailures,
  ripgrep,
  currentIdentity,
  identityControl,
  comparisons,
  medians,
  scorecard,
  roundLedger,
  ledgerSummary,
  phaseLeakSummary,
};

mkdirSync(REPORT_DIR, { recursive: true });
const outPath = path.join(REPORT_DIR, `${report.runId}.json`);
writeFileSync(outPath, `${JSON.stringify(report, null, 2)}\n`, "utf8");
writeFileSync(path.join(REPORT_DIR, "latest-historical-speed.json"), `${JSON.stringify(report, null, 2)}\n`, "utf8");

if (!quiet) {
  console.log(JSON.stringify({
    outPath,
    retainableStrictEvidence: report.retainableStrictEvidence,
    strictEvidenceFailures: report.strictEvidenceFailures,
    requiredGateFailures: report.requiredGateFailures,
    currentIdentity,
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
