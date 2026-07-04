import { existsSync, mkdirSync, writeFileSync } from "node:fs";
import os from "node:os";
import path from "node:path";
import { baseBenchEnv, defaultInstalledIxPath, defaultRepoIxPath, DEFAULT_ALTERNATES_EXPRESSION, DEFAULT_RETAINED_BENCH_THREADS, DEFAULT_RIPGREP_LINUX_CORPUS, experimentalBenchEnvOverrides } from "./lib/benchmark-config.mjs";
import { hostSnapshot } from "./lib/benchmark-runner.mjs";
import { benchmarkDecisionGrade, benchmarkEvidenceFailures, benchmarkHostWarningFailures, evidenceQualityFromFailures } from "./lib/benchmark-evidence-quality.mjs";
import { argValue, timestampSlug } from "./lib/script-helpers.mjs";
import { acquireBenchmarkLock, assertRepoBinaryFresh, benchmarkEnvSnapshot, binarySnapshot, buildInstalledComparisonScore, buildInstalledRoundLedger, buildInstalledScorecard, buildRoundLedgerSummary, dependencyTreeSnapshot, effectiveImprovementTargetPct, identityControlFailures, measureIxOnce, measureRipgrepBracketed, measureRipgrepMmapComparison, measureSameBinaryIdentityControl, orderStratifiedEngineStats, pairedEngineStats, pairOrderSummary, requireOk, routeParityEvaluation, run, scanIxProcesses, summarizeIxRuns } from "./lib/speed-compare-utils.mjs";

const ROOT = process.cwd();
const REPORT_DIR = path.join(ROOT, "tools", "reports", "manual-speed-compare");
const LATEST_RETAINABLE_INSTALLED_PATH = path.join(REPORT_DIR, "latest-retainable-installed-speed.json");
const DEFAULT_CORPUS = DEFAULT_RIPGREP_LINUX_CORPUS;
const DEFAULT_EXPR = DEFAULT_ALTERNATES_EXPRESSION;
const DEFAULT_INSTALLED_IX = defaultInstalledIxPath();
const DEFAULT_REPO_IX = defaultRepoIxPath(ROOT);
const BASE_BENCH_ENV = baseBenchEnv("installed");
const RETAINABLE_INSTALLED_THREADS = DEFAULT_RETAINED_BENCH_THREADS;

const args = process.argv.slice(2);
if (args.includes("--help") || args.includes("-h")) {
  console.log(`Usage: node tools/scripts/compare-installed-speed.mjs [options]

Compares ripgrep, native installed IX, and the repo IX binary on the ripgrep
linux benchsuite. Sampling is paired between installed and repo IX.

Options:
  --build                         Build repo IX ReleaseFast before measuring.
  --samples <n>                   Samples per lane. Default: 12.
  --threads <n>                   IX/ripgrep thread count. Default: ${DEFAULT_RETAINED_BENCH_THREADS}.
  --identity-control-samples <n>  Same-binary control pairs. Default: min(12, samples).
  --identity-control-attempts <n> Same-binary control attempts; first stable attempt is selected. Default: 3.
  --no-identity-control           Disable same-binary noise control.
  --corpus <path>                 Corpus path.
  --expression <expr>             Search expression.
  --installed-ix <path>           Native installed IX path.
  --repo-ix <path>                Repo IX binary path.
  --out <path>                    Exact report output path. Default: run-id report in manual-speed-compare.
  --latest-path <path>            Latest-report pointer path. Default:
                                  tools/reports/manual-speed-compare/latest-installed-speed.json.
                                  Clean strict runs also update
                                  tools/reports/manual-speed-compare/latest-retainable-installed-speed.json.
  --min-retainable-samples <n>    Minimum samples for strict evidence.
  --min-installed-improvement-pct <n>
                                  Required repo improvement over installed. Default: 0.
  --identity-noise-multiplier <n> Effective target multiplier for same-binary drift. Default: 0.
  --scan-open-timing              Enable scan open/file subphase timing in IX telemetry.
  --linux-dominant-attribution    Enable Linux AMD ASIC register slow-file attribution in IX telemetry.
  --no-benchmark-lock             Disable the cross-script benchmark lock.
  --require-promotion             Exit non-zero unless repo is promotable over installed.
  --require-strict                Exit non-zero unless strict evidence passes. Default behavior.
  --no-require-strict             Allow exploratory reports to exit zero when strict evidence fails.
  --quiet                         Write reports without printing summary.
  --help, -h                      Print this help and exit without measuring.
`);
  process.exit(0);
}
const corpus = argValue(args, "--corpus", DEFAULT_CORPUS);
const expression = argValue(args, "--expression", DEFAULT_EXPR);
const installedIx = argValue(args, "--installed-ix", DEFAULT_INSTALLED_IX);
const repoIx = argValue(args, "--repo-ix", DEFAULT_REPO_IX);
const explicitOutPath = argValue(args, "--out", "");
const latestPath = path.resolve(argValue(args, "--latest-path", path.join(REPORT_DIR, "latest-installed-speed.json")));
const samples = Number(argValue(args, "--samples", "12"));
const threads = Number(argValue(args, "--threads", String(DEFAULT_RETAINED_BENCH_THREADS)));
const identityControlSamples = Number(argValue(args, "--identity-control-samples", String(Math.min(12, samples))));
const identityControlAttempts = Number(argValue(args, "--identity-control-attempts", process.env.IX_IDENTITY_CONTROL_ATTEMPTS ?? "3"));
const identityControlEnabled = !args.includes("--no-identity-control");
const buildFirst = args.includes("--build");
const quiet = args.includes("--quiet");
const requireStrict = !args.includes("--no-require-strict");
const requirePromotion = args.includes("--require-promotion");
const benchmarkLock = !args.includes("--no-benchmark-lock");
const minRetainableSamples = Number(argValue(args, "--min-retainable-samples", process.env.IX_MIN_RETAINABLE_SPEED_SAMPLES ?? "12"));
const minInstalledImprovementPct = Number(argValue(args, "--min-installed-improvement-pct", process.env.IX_MIN_INSTALLED_IMPROVEMENT_PCT ?? "0"));
const identityNoiseMultiplier = Number(argValue(args, "--identity-noise-multiplier", process.env.IX_IDENTITY_NOISE_MULTIPLIER ?? "0"));
const scanOpenTiming = args.includes("--scan-open-timing");
const linuxDominantAttribution = args.includes("--linux-dominant-attribution");
const experimentalEnvOverrides = experimentalBenchEnvOverrides();
const experimentalEnvMode = Object.keys(experimentalEnvOverrides).length > 0;
const diagnosticAttributionMode = scanOpenTiming || linuxDominantAttribution || experimentalEnvMode;
const BENCH_ENV = {
  ...BASE_BENCH_ENV,
  IX_SCAN_OPEN_TIMING: scanOpenTiming ? "1" : "0",
  IX_LINUX_DOMINANT_ATTRIBUTION: linuxDominantAttribution ? "1" : "0",
};

function resolveZigExe() {
  const local = path.join(os.homedir(), ".local", "zig", "zig-x86_64-windows-0.16.0", "zig.exe");
  return existsSync(local) ? local : "zig";
}

function nativeInstalledBaselinePath(filePath) {
  const normalizedPath = String(filePath ?? "").replaceAll("\\", "/").toLowerCase();
  return normalizedPath.endsWith("/appdata/local/programs/iex/bin/ix.exe");
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
  return benchmarkEvidenceFailures({
    samples,
    minRetainableSamples,
    host,
    processScan,
    identityControl,
    identityControlEnabled,
    requiredIdentitySamples: Math.min(12, samples),
  });
}

function promotionFailures(host, processScan, installedHash, repoHash, installedRepoComparison, identityControl) {
  const failures = benchmarkEvidenceFailures({
    samples,
    minRetainableSamples,
    host,
    processScan,
    identityControl,
    identityControlEnabled,
    requiredIdentitySamples: Math.min(12, samples),
  });
  if (diagnosticAttributionMode) failures.push("diagnostic_attribution_run_not_promotion_evidence");
  if (!installedRepoComparison.matchParity) failures.push("match_parity_failed");
  if (installedRepoComparison.routeParityAcceptable !== true) {
    failures.push(`route_parity_failed:${installedRepoComparison.routeParityStatus ?? "unknown"}`);
  }
  if (installedHash === repoHash) {
    failures.push("installed_repo_same_binary:no_promotion_evidence");
    return failures;
  }
  const requiredImprovementPct = Number(installedRepoComparison.score?.requiredImprovementPct ?? installedRepoComparison.effectiveInstalledImprovementPct ?? minInstalledImprovementPct);
  if (installedRepoComparison.score?.repoEngineAcceptable !== true && installedRepoComparison.repoEngineMedianMs >= installedRepoComparison.installedEngineMedianMs) {
    failures.push(`repo_not_faster:${installedRepoComparison.repoEngineMedianMs}>=${installedRepoComparison.installedEngineMedianMs}`);
  }
  if (
    installedRepoComparison.score?.repoEngineAcceptable !== true &&
    Number.isFinite(installedRepoComparison.installedEngineDeltaPct) &&
    installedRepoComparison.installedEngineDeltaPct < requiredImprovementPct
  ) {
    failures.push(`installed_improvement_below_target:${installedRepoComparison.installedEngineDeltaPct}<${requiredImprovementPct}`);
  }
  const pairedImprovementMedianPct = Number(installedRepoComparison.pairedEngine?.candidateImprovementPctSummary?.median);
  if (installedRepoComparison.score?.pairedRepoEngineAcceptable !== true) {
    failures.push(`installed_paired_improvement_below_target:${Number.isFinite(pairedImprovementMedianPct) ? pairedImprovementMedianPct : "missing"}<${requiredImprovementPct}`);
  }
  const pairedLower95Pct = Number(
    installedRepoComparison.score?.pairedImprovementLower95Pct ??
    installedRepoComparison.pairedEngine?.candidateImprovementPctBootstrap95?.lower,
  );
  if (!Number.isFinite(pairedLower95Pct) || pairedLower95Pct < requiredImprovementPct) {
    failures.push(
      `installed_paired_ci_below_target:${Number.isFinite(pairedLower95Pct) ? pairedLower95Pct : "missing"}<${requiredImprovementPct}`,
    );
  }
  const candidateWinRate = Number(installedRepoComparison.pairedEngine?.candidateWinRate);
  if (installedRepoComparison.score?.pairedRepoWinAcceptable !== true) {
    failures.push(`repo_paired_win_majority_required:${Number.isFinite(candidateWinRate) ? candidateWinRate : "missing"}`);
  }
  if (installedRepoComparison.score?.netPositive !== true) {
    failures.push("installed_scorecard_not_net_positive");
  }
  return failures;
}

function writePreflightFailureReport({
  hostBefore,
  processBefore = null,
  identityControl = null,
  strictFailures,
  reason,
}) {
  const host = { before: hostBefore, after: null };
  const evidenceQuality = evidenceQualityFromFailures(strictFailures);
  const processScan = processBefore == null ? null : { before: processBefore, after: null };
  const report = {
    runId: `installed-speed-${timestampSlug()}`,
    timestamp: new Date().toISOString(),
    corpus,
    expression,
    samples,
    minRetainableSamples,
    minInstalledImprovementPct,
    effectiveInstalledImprovementPct: minInstalledImprovementPct,
    identityNoiseMultiplier,
    identityControlSamples: identityControlEnabled ? identityControlSamples : 0,
    identityControlAttempts: identityControlEnabled ? identityControlAttempts : 0,
    threads,
    scanOpenTiming,
    linuxDominantAttribution,
    experimentalEnvMode,
    experimentalEnvOverrides,
    diagnosticAttributionMode,
    benchEnv: BENCH_ENV,
    effectiveBenchEnv: benchmarkEnvSnapshot(BENCH_ENV),
    dependencyTrees: dependencyTreeSnapshot(ROOT),
    host,
    processScan,
    decisionGrade: benchmarkDecisionGrade({
      preflightAborted: true,
      retainableStrictEvidence: false,
      diagnosticAttributionMode,
      requiredGateFailures: [
        {
          gate: "strict",
          reason,
          failures: strictFailures,
        },
        ...(requirePromotion
          ? [{
              gate: "promotion",
              reason,
              failures: strictFailures,
            }]
          : []),
      ],
    }),
    retainableStrictEvidence: false,
    strictEvidenceFailures: strictFailures,
    evidenceQuality,
    binaries: null,
    hashesMatch: null,
    lanes: null,
    identityControl,
    installedRepoComparison: null,
    scorecard: null,
    identityNoiseSummary: null,
    roundLedger: [],
    ledgerSummary: null,
    promotionMode: null,
    promotionQualified: false,
    promotionFailures: strictFailures,
    requiredGateFailures: [
      {
        gate: "strict",
        reason,
        failures: strictFailures,
      },
      ...(requirePromotion
        ? [{
            gate: "promotion",
            reason,
            failures: strictFailures,
          }]
        : []),
    ],
    deltasPct: null,
    preflightAborted: true,
    preflightReason: reason,
  };

  mkdirSync(REPORT_DIR, { recursive: true });
  const outPath = explicitOutPath.length > 0 ? path.resolve(explicitOutPath) : path.join(REPORT_DIR, `${report.runId}.json`);
  mkdirSync(path.dirname(outPath), { recursive: true });
  writeFileSync(outPath, `${JSON.stringify(report, null, 2)}\n`, "utf8");
  mkdirSync(path.dirname(latestPath), { recursive: true });
  writeFileSync(latestPath, `${JSON.stringify(report, null, 2)}\n`, "utf8");

  if (!quiet) {
    console.log(JSON.stringify({
      outPath,
      preflightAborted: true,
      decisionGrade: report.decisionGrade,
      strictEvidenceFailures: report.strictEvidenceFailures,
      requiredGateFailures: report.requiredGateFailures,
      evidenceQuality: report.evidenceQuality,
      hostStatus: hostBefore?.benchmarkEnvironment?.status ?? null,
      identityControl: identityControl == null ? null : {
        selectedAttempt: identityControl.selectedAttempt ?? null,
        attemptSelection: identityControl.attemptSelection ?? null,
        medianDeltaPct: identityControl.medianDeltaPct ?? null,
        pairedWinRate: identityControl.pairedEngine?.candidateWinRate ?? null,
        diagnostics: identityControl.diagnostics ?? null,
      },
    }, null, 2));
  }

  console.error(JSON.stringify({ status: "failed", failures: report.requiredGateFailures, outPath }, null, 2));
  process.exit(2);
}

if (samples < 1 || !Number.isFinite(samples)) throw new Error("--samples must be a positive number");
if (threads < 1 || !Number.isFinite(threads)) throw new Error("--threads must be a positive number");
if (identityControlSamples < 0 || !Number.isFinite(identityControlSamples)) throw new Error("--identity-control-samples must be a non-negative number");
if (identityControlAttempts < 1 || !Number.isFinite(identityControlAttempts)) throw new Error("--identity-control-attempts must be a positive number");
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
const repoBinaryFreshness = assertRepoBinaryFresh({ root: ROOT, repoIx, label: "repo IX" });

const hostBefore = hostSnapshot();
const hostPreflightFailures = requireStrict ? benchmarkHostWarningFailures({ before: hostBefore }) : [];
const processBefore = scanIxProcesses({ ixBinary: repoIx, env: BENCH_ENV, cleanupOwned: true });
const ixArgs = ["search", expression, corpus, "--json", "--stats-only", "--threads", String(threads)];
let strictIdentityPreflight = null;
if (requireStrict && identityControlEnabled && identityControlSamples > 0) {
  strictIdentityPreflight = measureSameBinaryIdentityControl({
    binaryPath: repoIx,
    ixArgs,
    samples: identityControlSamples,
    attempts: identityControlAttempts,
    env: BENCH_ENV,
    enabled: identityControlEnabled,
    label: "repo-control-preflight",
  });
  const preflightFailures = [
    ...hostPreflightFailures,
    ...(processBefore?.ok === false ? ["process_scan_before_failed"] : []),
    ...((processBefore?.failures ?? []).map((failure) => `process_scan_before:${failure}`)),
    ...(((processBefore?.matched?.length ?? 0) > 0) ? [`stale_processes_before:${processBefore.matched.length}`] : []),
    ...identityControlFailures({
      identityControl: strictIdentityPreflight,
      enabled: identityControlEnabled,
      requiredSamples: Math.min(12, samples),
    }),
  ];
  const blockingPreflightFailures = preflightFailures.filter((failure) => !String(failure).startsWith("host:"));
  if (blockingPreflightFailures.length > 0) {
    writePreflightFailureReport({
      hostBefore,
      processBefore,
      identityControl: strictIdentityPreflight,
      strictFailures: preflightFailures,
      reason: "benchmark identity preflight failed before retained run",
    });
  }
}
const ripgrep = measureRipgrepBracketed({
  expression,
  defaultExpression: DEFAULT_EXPR,
  corpus,
  threads,
  samples,
  env: BENCH_ENV,
  between: () => {
    const identityControl = strictIdentityPreflight ?? measureSameBinaryIdentityControl({
      binaryPath: repoIx,
      ixArgs,
      samples: identityControlSamples,
      attempts: identityControlAttempts,
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
    return {
      identityControl,
      effectiveInstalledImprovementPct,
      paired,
    };
  },
});
const ripgrepMmapComparison = measureRipgrepMmapComparison({ expression, defaultExpression: DEFAULT_EXPR, corpus, threads, samples, env: BENCH_ENV });
const identityControl = ripgrep.betweenResult?.identityControl ?? null;
const effectiveInstalledImprovementPct = ripgrep.betweenResult?.effectiveInstalledImprovementPct ?? minInstalledImprovementPct;
const paired = ripgrep.betweenResult?.paired;
if (paired == null) {
  throw new Error("measureRipgrepBracketed did not produce the installed-vs-repo paired comparison");
}
const processAfter = scanIxProcesses({ ixBinary: repoIx, env: BENCH_ENV, cleanupOwned: true });
const hostAfter = hostSnapshot();
const host = { before: hostBefore, after: hostAfter };
const processScan = { before: processBefore, after: processAfter };
const binaries = {
  installed: binarySnapshot(installedIx),
  repo: binarySnapshot(repoIx),
};
const installedHash = binaries.installed.sha256;
const repoHash = binaries.repo.sha256;
const installedExecutableHash = binaries.installed.executableSha256 ?? installedHash;
const repoExecutableHash = binaries.repo.executableSha256 ?? repoHash;
const strictFailures = strictEvidenceFailures(host, processScan, identityControl);
const installedRepoEngineDeltaPct =
  ((paired.installed.engineSummary.median - paired.repo.engineSummary.median) /
    paired.installed.engineSummary.median) *
  100;
const installedRepoBinaryRelation = installedExecutableHash === repoExecutableHash ? "same_binary" : "different_binary";
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
  installedEngineResidualMedianMs: paired.installed.engineResidualSummary.median,
  repoEngineResidualMedianMs: paired.repo.engineResidualSummary.median,
  installedScanWorkMedianMs: paired.installed.scanWorkSummary.median,
  repoScanWorkMedianMs: paired.repo.scanWorkSummary.median,
  installedScanOpenMedianMs: paired.installed.scanOpenSummary.median,
  repoScanOpenMedianMs: paired.repo.scanOpenSummary.median,
  installedScanOpenPathMedianMs: paired.installed.scanOpenPathSummary?.median ?? null,
  repoScanOpenPathMedianMs: paired.repo.scanOpenPathSummary?.median ?? null,
  installedScanOpenSyscallMedianMs: paired.installed.scanOpenSyscallSummary?.median ?? null,
  repoScanOpenSyscallMedianMs: paired.repo.scanOpenSyscallSummary?.median ?? null,
  installedScanFileMedianMs: paired.installed.scanFileSummary.median,
  repoScanFileMedianMs: paired.repo.scanFileSummary.median,
  installedScanFileMmapMedianMs: paired.installed.scanFileMmapSummary?.median ?? null,
  repoScanFileMmapMedianMs: paired.repo.scanFileMmapSummary?.median ?? null,
  installedScanFileFastCountMedianMs: paired.installed.scanFileFastCountSummary?.median ?? null,
  repoScanFileFastCountMedianMs: paired.repo.scanFileFastCountSummary?.median ?? null,
  installedScanFileLineScanMedianMs: paired.installed.scanFileLineScanSummary?.median ?? null,
  repoScanFileLineScanMedianMs: paired.repo.scanFileLineScanSummary?.median ?? null,
  installedAlternateFullScanCallsMedian: paired.installed.alternateFullScanCallsSummary.median,
  repoAlternateFullScanCallsMedian: paired.repo.alternateFullScanCallsSummary.median,
  installedAlternateFullScanBytesMedian: paired.installed.alternateFullScanBytesSummary.median,
  repoAlternateFullScanBytesMedian: paired.repo.alternateFullScanBytesSummary.median,
  installedAlternateFullScanMatchesMedian: paired.installed.alternateFullScanMatchesSummary.median,
  repoAlternateFullScanMatchesMedian: paired.repo.alternateFullScanMatchesSummary.median,
  installedAlternateTeddyRangeElapsedNsMedian: paired.installed.alternateTeddyRangeElapsedNsMaxSummary.median,
  repoAlternateTeddyRangeElapsedNsMedian: paired.repo.alternateTeddyRangeElapsedNsMaxSummary.median,
  installedByteShardFilesProfiledMedian: paired.installed.byteShardFilesProfiledSummary.median,
  repoByteShardFilesProfiledMedian: paired.repo.byteShardFilesProfiledSummary.median,
  installedByteShardRangesMedian: paired.installed.byteShardRangesSummary.median,
  repoByteShardRangesMedian: paired.repo.byteShardRangesSummary.median,
  installedByteShardLogicalRangeBytesMedian: paired.installed.byteShardLogicalRangeBytesSummary.median,
  repoByteShardLogicalRangeBytesMedian: paired.repo.byteShardLogicalRangeBytesSummary.median,
  installedByteShardWidenedRangeBytesMedian: paired.installed.byteShardWidenedRangeBytesSummary.median,
  repoByteShardWidenedRangeBytesMedian: paired.repo.byteShardWidenedRangeBytesSummary.median,
  installedByteShardOverlapBytesMedian: paired.installed.byteShardOverlapBytesSummary.median,
  repoByteShardOverlapBytesMedian: paired.repo.byteShardOverlapBytesSummary.median,
  installedByteShardRangeBytesAvgMedian: paired.installed.byteShardRangeBytesAvgSummary.median,
  repoByteShardRangeBytesAvgMedian: paired.repo.byteShardRangeBytesAvgSummary.median,
  installedByteShardRangeElapsedNsMedian: paired.installed.byteShardRangeElapsedNsTotalSummary.median,
  repoByteShardRangeElapsedNsMedian: paired.repo.byteShardRangeElapsedNsTotalSummary.median,
  installedByteShardRangeElapsedNsMaxMedian: paired.installed.byteShardRangeElapsedNsMaxSummary.median,
  repoByteShardRangeElapsedNsMaxMedian: paired.repo.byteShardRangeElapsedNsMaxSummary.median,
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
  installedRouteKinds: installedRepoRoute.baselineRouteKinds,
  repoRouteKinds: installedRepoRoute.candidateRouteKinds,
  routeParity: installedRepoRoute.parity,
  routeCardinalityParity: installedRepoRoute.cardinalityParity,
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
installedRepoComparison.orderStratifiedEngine = orderStratifiedEngineStats(
  paired.installed.samples,
  paired.repo.samples,
  paired.pairOrder,
  {
    baselineLabel: "installed",
    candidateLabel: "repo",
  },
);
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
const sameExecutableBinary = installedRepoBinaryRelation === "same_binary";
const identityNoiseSummary = {
  binaryRelation: installedRepoBinaryRelation,
  evidenceAuthority: installedRepoComparison.evidenceAuthority,
  candidatePromotionEvidence: !sameExecutableBinary,
  installedAndRepoExecutableSha256Match: sameExecutableBinary,
  installedExecutableSha256: installedExecutableHash,
  repoExecutableSha256: repoExecutableHash,
  identityControlMedianDeltaPct: identityControl?.medianDeltaPct ?? null,
  observedEngineDeltaPct: installedRepoEngineDeltaPct,
  observedPairedEngineMedianPct:
    installedRepoComparison.score?.pairedRepoImprovementMedianPct ?? null,
  observedPairedWinRate: installedRepoComparison.score?.pairedRepoWinRate ?? null,
  observedTeddyRangeMedianPct:
    installedRepoComparison.score?.pairedCandidateTeddyRangeImprovementMedianPct ?? null,
  interpretation: sameExecutableBinary
    ? "installed and repo normalize to the same executable code; this run measures benchmark drift/noise and cannot prove a runtime candidate"
    : "installed and repo are different executable code; this run can prove or reject promotion",
};
const roundLedger = buildInstalledRoundLedger({
  comparison: installedRepoComparison,
  score: installedRepoComparison.score,
  binaryRelation: installedRepoBinaryRelation,
  binaries,
});
const ledgerSummary = buildRoundLedgerSummary(roundLedger);
const promotionFailureList = promotionFailures(host, processScan, installedExecutableHash, repoExecutableHash, installedRepoComparison, identityControl);
const evidenceQuality = evidenceQualityFromFailures([...strictFailures, ...promotionFailureList]);
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
  identityControlAttempts: identityControlEnabled ? identityControlAttempts : 0,
  threads,
  scanOpenTiming,
  linuxDominantAttribution,
  experimentalEnvMode,
  experimentalEnvOverrides,
  diagnosticAttributionMode,
  benchEnv: BENCH_ENV,
  effectiveBenchEnv: benchmarkEnvSnapshot(BENCH_ENV),
  repoBinaryFreshness,
  dependencyTrees: dependencyTreeSnapshot(ROOT),
  host,
  processScan,
  decisionGrade: benchmarkDecisionGrade({
    preflightAborted: false,
    retainableStrictEvidence: strictFailures.length === 0,
    diagnosticAttributionMode,
    requiredGateFailures,
  }),
  retainableStrictEvidence: strictFailures.length === 0,
  strictEvidenceFailures: strictFailures,
  evidenceQuality,
  binaries,
  hashesMatch: sameExecutableBinary,
  lanes: {
    ripgrep,
    ripgrepMmapComparison,
    identityControl,
    installed: paired.installed,
    repo: paired.repo,
  },
  identityControl,
  installedRepoComparison,
  scorecard,
  identityNoiseSummary,
  roundLedger,
  ledgerSummary,
  promotionMode,
  promotionQualified: !diagnosticAttributionMode && promotionFailureList.length === 0,
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
  ripgrepNoMmapVsForcedMmap:
    report.lanes.ripgrepMmapComparison?.noMmapImprovementPct ?? null,
  ripgrepBracketDriftPct:
    report.lanes.ripgrep?.bracketDriftPct ?? null,
};

mkdirSync(REPORT_DIR, { recursive: true });
const outPath = explicitOutPath.length > 0 ? path.resolve(explicitOutPath) : path.join(REPORT_DIR, `${report.runId}.json`);
mkdirSync(path.dirname(outPath), { recursive: true });
writeFileSync(outPath, `${JSON.stringify(report, null, 2)}\n`, "utf8");
mkdirSync(path.dirname(latestPath), { recursive: true });
const diagnosticLatestPath = path.join(REPORT_DIR, "latest-diagnostic-installed-speed.json");
if (diagnosticAttributionMode) {
  writeFileSync(diagnosticLatestPath, `${JSON.stringify(report, null, 2)}\n`, "utf8");
} else {
  writeFileSync(latestPath, `${JSON.stringify(report, null, 2)}\n`, "utf8");
}
const retainableInstalledThreadConfig = threads === RETAINABLE_INSTALLED_THREADS;
if (requireStrict && report.retainableStrictEvidence && report.promotionQualified && !diagnosticAttributionMode && nativeInstalledBaselinePath(installedIx) && retainableInstalledThreadConfig) {
  writeFileSync(LATEST_RETAINABLE_INSTALLED_PATH, `${JSON.stringify(report, null, 2)}\n`, "utf8");
}

if (!quiet) {
  console.log(JSON.stringify({ outPath, decisionGrade: report.decisionGrade, retainableStrictEvidence: report.retainableStrictEvidence, promotionQualified: report.promotionQualified, binaries: report.binaries, medians: {
    ripgrepCliMs: report.lanes.ripgrep.summary.median,
    ripgrepBracketDriftPct: report.lanes.ripgrep.bracketDriftPct ?? null,
    ripgrepNoMmapCliMs: report.lanes.ripgrepMmapComparison?.never?.summary?.median ?? null,
    ripgrepFastestMmapMode: report.lanes.ripgrepMmapComparison?.fastest ?? null,
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
  } : null, evidenceQuality: report.evidenceQuality, identityNoiseSummary: report.identityNoiseSummary, installedRepoComparison: report.installedRepoComparison, scorecard: report.scorecard, roundLedger: report.roundLedger, ledgerSummary: report.ledgerSummary, strictEvidenceFailures: report.strictEvidenceFailures, promotionFailures: report.promotionFailures, requiredGateFailures: report.requiredGateFailures, staleProcessesBefore: report.processScan.before.matched.length, staleProcessesAfter: report.processScan.after.matched.length, deltasPct: report.deltasPct }, null, 2));
}

if (report.requiredGateFailures.length > 0) {
  console.error(JSON.stringify({ status: "failed", failures: report.requiredGateFailures, outPath, identityNoiseSummary: report.identityNoiseSummary }, null, 2));
  process.exit(report.requiredGateFailures.some((failure) => failure.gate === "promotion") ? 3 : 2);
}
