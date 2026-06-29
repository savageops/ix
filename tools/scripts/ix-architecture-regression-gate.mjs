import { spawnSync } from "node:child_process";
import { existsSync, mkdirSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import os from "node:os";
import path from "node:path";
import { hostSnapshot } from "./lib/benchmark-runner.mjs";
import { createBenchmarkAdmission } from "./lib/benchmark-admission.mjs";
import {
  createAlternatesDecisionGateLane,
  createAlternatesGateValidation,
  summarizeAlternateRoute,
} from "./lib/alternates-gate-validation.mjs";
import {
  createRipgrepGateLane,
  validateRipgrepLane,
} from "./lib/ripgrep-gate-validation.mjs";
import { createReportSchemaValidation } from "./lib/report-schema-validation.mjs";
import { createSpeedGateValidation } from "./lib/speed-gate-validation.mjs";
import { createTeddyGateValidation } from "./lib/teddy-gate-validation.mjs";
import { createRuntimeStateGateValidation } from "./lib/runtime-state-gate-validation.mjs";
import { createProcessGateValidation } from "./lib/process-gate-validation.mjs";
import { createAgentSurfaceGateValidation } from "./lib/agent-surface-gate-validation.mjs";
import { createPlanningGateValidation } from "./lib/planning-gate-validation.mjs";
import { createNativeInstallGateValidation } from "./lib/native-install-gate-validation.mjs";
import { argValue, timestampSlug } from "./lib/script-helpers.mjs";
import { runSchemaSelfTest } from "./lib/schema-self-test-gate.mjs";

const ROOT = process.cwd();
const REPORT_DIR = path.join(ROOT, "tools", "reports", "architecture-gate");
const LATEST_TEDDY_DECISION = path.join(ROOT, "tools", "reports", "teddy-kernel-decision", "latest-teddy-kernel-decision.json");
const NATIVE_INSTALL_DIR = path.join(os.homedir(), "AppData", "Local", "Programs", "iEx", "bin");
const NATIVE_INSTALL_IX = path.join(NATIVE_INSTALL_DIR, "ix.exe");
const NATIVE_INSTALL_IEX = path.join(NATIVE_INSTALL_DIR, "iex.exe");
const DEFAULT_BENCH_CORPUS = "E:\\Workspaces\\01_Projects\\01_Github\\iEx\\.refs\\ripgrep\\benchsuite\\linux";

const args = process.argv.slice(2);
if (args.includes("--help") || args.includes("-h")) {
  console.log(`Usage: node tools/scripts/ix-architecture-regression-gate.mjs [options]

Runs IX architecture validation lanes: schema self-test, quick process/native
checks, installed-speed, historical-speed, alternates decision, agent eval, and
path-sentinel probes. Lanes may be skipped when strict benchmark preflight fails.

Options:
  --quick                                  Run quick validation lanes.
  --speed-only                             Run only speed validation lanes.
  --schema-self-test                       Run gate schema self-test.
  --installed-speed                        Include installed-vs-repo speed lane.
  --strict-installed-speed                 Require installed speed strict evidence.
  --historical-speed                       Include previous-build speed lane.
  --strict-historical-speed                Require historical speed strict evidence.
  --older-snapshots                        Include older snapshot ladder speed lane.
  --strict-older-snapshots                 Require older snapshot strict evidence.
  --alternates-decision                    Include literal-alternates decision lane.
  --out <path>                             Report output path.
  --state-dir <path>                       Temporary state directory.
  --installed-speed-samples <n>            Installed speed samples. Default: 12.
  --historical-speed-samples <n>           Historical speed samples. Default: 12.
  --older-snapshot-samples <n>             Older snapshot samples. Default: 12.
  --older-snapshot-max <n>                 Older snapshot cap for smoke runs.
  --older-snapshot-retainable-target <n>   Retainable older snapshot target for strict runs.
  --older-snapshot-identity-attempts <n>   Same-binary control attempts. Default: 3.
  --min-older-snapshot-engine-pct <n>      Required older-snapshot engine improvement.
  --min-older-snapshot-paired-pct <n>      Required older-snapshot paired improvement.
  --alternates-decision-samples <n>        Alternates samples. Default: 12.
  --alternates-decision-max-branches <n>   Alternates max branch count. Default: 8.
  --alternates-decision-branch-counts <csv>
                                           Alternates branch counts, e.g. 2,4,8.
  --min-retainable-speed-samples <n>       Minimum samples for strict speed evidence.
  --min-installed-improvement-pct <n>      Required repo improvement over installed.
  --identity-noise-multiplier <n>          Effective target multiplier for same-binary drift.
  --baseline-ix-ms <n>                     Fixed IX baseline median.
  --baseline-tolerance-pct <n>             Hard fixed-baseline tolerance.
  --baseline-soft-tolerance-pct <n>        Soft fixed-baseline tolerance.
  --previous-ix-binary <path>              Previous IX binary for paired gate lanes.
  --help, -h                               Print this help and exit without validation.
`);
  process.exit(0);
}
const quick = args.includes("--quick");
const speedOnly = args.includes("--speed-only");
const schemaSelfTest = args.includes("--schema-self-test");
const installedSpeed = args.includes("--installed-speed");
const strictInstalledSpeed = args.includes("--strict-installed-speed");
const historicalSpeed = args.includes("--historical-speed");
const strictHistoricalSpeed = args.includes("--strict-historical-speed");
const olderSnapshots = args.includes("--older-snapshots");
const strictOlderSnapshots = args.includes("--strict-older-snapshots");
const alternatesDecision = args.includes("--alternates-decision");
const outPath = argValue(args, "--out", path.join(REPORT_DIR, `architecture-gate-${timestampSlug()}.json`));
const stateDir = argValue(args, "--state-dir", path.join(os.tmpdir(), `ix-architecture-gate-${process.pid}`));
const benchmarkCorpus = process.env.IX_BENCHSUITE_LINUX ?? DEFAULT_BENCH_CORPUS;
const installedSpeedSamples = Number(argValue(args, "--installed-speed-samples", process.env.IX_INSTALLED_SPEED_SAMPLES ?? "12"));
const historicalSpeedSamples = Number(
  argValue(args, "--historical-speed-samples", process.env.IX_HISTORICAL_SPEED_SAMPLES ?? "12"),
);
const olderSnapshotSamples = Number(
  argValue(args, "--older-snapshot-samples", process.env.IX_OLDER_SNAPSHOT_SAMPLES ?? "12"),
);
const olderSnapshotMax = argValue(args, "--older-snapshot-max", process.env.IX_OLDER_SNAPSHOT_MAX ?? "");
const olderSnapshotRetainableTarget = argValue(
  args,
  "--older-snapshot-retainable-target",
  process.env.IX_OLDER_SNAPSHOT_RETAINABLE_TARGET ?? olderSnapshotMax,
);
const olderSnapshotIdentityAttempts = Number(
  argValue(args, "--older-snapshot-identity-attempts", process.env.IX_OLDER_SNAPSHOT_IDENTITY_ATTEMPTS ?? "3"),
);
const alternatesDecisionSamples = Number(
  argValue(args, "--alternates-decision-samples", process.env.IX_ALTERNATES_DECISION_SAMPLES ?? "12"),
);
const alternatesDecisionMaxBranches = Number(
  argValue(args, "--alternates-decision-max-branches", process.env.IX_ALTERNATES_DECISION_MAX_BRANCHES ?? "8"),
);
const alternatesDecisionBranchCounts = argValue(
  args,
  "--alternates-decision-branch-counts",
  process.env.IX_ALTERNATES_DECISION_BRANCH_COUNTS ?? "",
);
const minRetainableSpeedSamples = Number(
  argValue(args, "--min-retainable-speed-samples", process.env.IX_MIN_RETAINABLE_SPEED_SAMPLES ?? "12"),
);
const minInstalledImprovementPct = Number(
  argValue(args, "--min-installed-improvement-pct", process.env.IX_MIN_INSTALLED_IMPROVEMENT_PCT ?? "5"),
);
const identityNoiseMultiplier = Number(argValue(args, "--identity-noise-multiplier", process.env.IX_IDENTITY_NOISE_MULTIPLIER ?? "3"));
const baselineIxMs = Number(argValue(args, "--baseline-ix-ms", process.env.IX_ARCH_GATE_BASELINE_IX_MS ?? "575.3829"));
const baselineTolerancePct = Number(argValue(args, "--baseline-tolerance-pct", process.env.IX_ARCH_GATE_BASELINE_TOLERANCE_PCT ?? "-5"));
const baselineSoftTolerancePct = Number(argValue(args, "--baseline-soft-tolerance-pct", process.env.IX_ARCH_GATE_BASELINE_SOFT_TOLERANCE_PCT ?? "-5"));
const ripgrepWarmupSamples = Number(argValue(args, "--ripgrep-warmup", process.env.IX_ARCH_GATE_RIPGREP_WARMUP ?? "2"));
const baselineWarmupSamples = Number(
  argValue(args, "--baseline-warmup", process.env.IX_ARCH_GATE_BASELINE_WARMUP ?? "2"),
);
const previousIxBinary = argValue(args, "--previous-ix-binary", process.env.IX_PREVIOUS_BINARY ?? "");
const pairedImprovementTolerancePct = Number(argValue(args, "--paired-improvement-tolerance-pct", process.env.IX_ARCH_GATE_PAIRED_IMPROVEMENT_TOLERANCE_PCT ?? "1.5"));
const patchNoRegressionTolerancePct = Number(argValue(args, "--patch-no-regression-tolerance-pct", process.env.IX_ARCH_GATE_PATCH_NO_REGRESSION_TOLERANCE_PCT ?? "0"));
const minPreviousBuildImprovementPct = Number(
  argValue(args, "--min-previous-build-improvement-pct", process.env.IX_MIN_PREVIOUS_BUILD_IMPROVEMENT_PCT ?? "5"),
);
const minOlderSnapshotEngineImprovementPct = Number(
  argValue(args, "--min-older-snapshot-engine-pct", process.env.IX_MIN_OLDER_SNAPSHOT_ENGINE_PCT ?? "5"),
);
const minOlderSnapshotPairedImprovementPct = Number(
  argValue(args, "--min-older-snapshot-paired-pct", process.env.IX_MIN_OLDER_SNAPSHOT_PAIRED_PCT ?? "5"),
);
const benchmarkControlDriftTolerancePct = Number(argValue(args, "--benchmark-control-drift-pct", process.env.IX_ARCH_GATE_CONTROL_DRIFT_PCT ?? "3"));
const benchmarkControlRobustCvPct = Number(argValue(args, "--benchmark-control-robust-cv-pct", process.env.IX_ARCH_GATE_CONTROL_ROBUST_CV_PCT ?? "8"));
const planningChainSlug = argValue(
  args,
  "--planning-chain",
  process.env.IX_ARCH_GATE_PLANNING_CHAIN ?? "149-nextgen-architecture-validation-spine",
);
const planningChainPhasesArg = argValue(args, "--planning-phases", process.env.IX_ARCH_GATE_PLANNING_PHASES ?? "auto");
const planningChainState = argValue(args, "--planning-state", process.env.IX_ARCH_GATE_PLANNING_STATE ?? "archived");
const benchmarkAdmission = createBenchmarkAdmission({
  root: ROOT,
  benchmarkCorpus,
  nativeInstallDir: NATIVE_INSTALL_DIR,
  stateDir,
  minRetainableSpeedSamples,
});
const {
  benchmarkHostPreflightLane: createBenchmarkHostPreflightLane,
  benchmarkHostRemediation,
  benchmarkLockSelfTest,
  benchmarkReadinessLane: createBenchmarkReadinessLane,
  hostBenchmarkClean,
  hostBenchmarkIssues,
  validateBenchmarkLockLane,
  validateBenchmarkHostPreflightLane,
  validateBenchmarkReadinessLane,
  validateHostPreflightSkipRemediation,
  validateNativeInstallIdentityLane,
} = benchmarkAdmission;
const speedGateValidation = createSpeedGateValidation({
  minInstalledImprovementPct,
  minPreviousBuildImprovementPct,
  minRetainableSpeedSamples,
  validateHostPreflightSkipRemediation,
});
const {
  historicalRoundLedgerMatches,
  historicalScorecardMatches,
  historicalScoreMatchesRaw,
  installedScoreMatchesRaw,
  validateHistoricalSpeedLane,
  validateInstalledSpeedLane,
  validateOlderSnapshotLane,
} = speedGateValidation;
const { validateAlternatesDecisionLane } = createAlternatesGateValidation({
  minRetainableSpeedSamples,
  validateHostPreflightSkipRemediation,
});
const { validateReport } = createReportSchemaValidation({
  validateAlternatesDecisionLane,
  validateBenchmarkHostPreflightLane,
  validateBenchmarkLockLane,
  validateBenchmarkReadinessLane,
  validateHistoricalSpeedLane,
  validateInstalledSpeedLane,
  validateOlderSnapshotLane,
  validateNativeInstallIdentityLane,
  validateRipgrepLane,
});
const {
  teddyKernelContractLane,
  teddyKernelDecisionLane,
} = createTeddyGateValidation({
  root: ROOT,
  run,
  lane,
});
const { scanIxProcesses } = createProcessGateValidation({
  run,
  lane,
  findBuiltIx,
});

function run(command, commandArgs, options = {}) {
  const started = process.hrtime.bigint();
  const env = { ...process.env, ...(options.env ?? {}) };
  for (const [key, value] of Object.entries(env)) {
    if (value === undefined) delete env[key];
  }
  const result = spawnSync(command, commandArgs, {
    cwd: options.cwd ?? ROOT,
    env,
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

function writeReport(report) {
  mkdirSync(path.dirname(outPath), { recursive: true });
  writeFileSync(outPath, `${JSON.stringify(report, null, 2)}\n`);
}

function isPlainObject(value) {
  return value !== null && typeof value === "object" && !Array.isArray(value);
}

function summarizeComparatorStateReports(scan) {
  if (!Array.isArray(scan?.stateReports)) return [];
  return scan.stateReports.map((entry) => ({
    label: entry?.label ?? null,
    ok: entry?.ok === true,
    skipped: entry?.skipped === true,
    failures: Array.isArray(entry?.failures) ? entry.failures : [],
    report: isPlainObject(entry?.report)
      ? {
          state_dir: entry.report.state_dir ?? null,
          live: Number(entry.report.live ?? 0),
          stale: Number(entry.report.stale ?? 0),
          malformed: Number(entry.report.malformed ?? 0),
          warnings: Number(entry.report.warnings ?? 0),
          removed: Number(entry.report.removed ?? 0),
        }
      : null,
  }));
}


if (schemaSelfTest) {
  runSchemaSelfTest({
    stateDir,
    outPath,
    validateReport,
    validateBenchmarkHostPreflightLane,
    validateBenchmarkLockLane,
    validateBenchmarkReadinessLane,
    validateNativeInstallIdentityLane,
    validateHostPreflightSkipRemediation,
    validateInstalledSpeedLane,
    validateHistoricalSpeedLane,
    validateAlternatesDecisionLane,
  });
}

function findBuiltIx() {
  const exe = process.platform === "win32" ? "ix-zig.exe" : "ix-zig";
  const candidate = path.join(ROOT, "zig-out", "bin", exe);
  return existsSync(candidate) ? candidate : null;
}

const {
  latestDistinctNativeBackup,
  nativeInstallIdentityLane,
  sha256File,
} = createNativeInstallGateValidation({
  latestTeddyDecisionPath: LATEST_TEDDY_DECISION,
  nativeInstallDir: NATIVE_INSTALL_DIR,
  nativeInstallIx: NATIVE_INSTALL_IX,
  nativeInstallIex: NATIVE_INSTALL_IEX,
  findBuiltIx,
  lane,
});

function speedHostPreflightSkipLane(id, hostPreflight, { corpus, samples, strictRequired }) {
  const hostFailures = (hostPreflight?.metrics?.hostIssues ?? [])
    .filter((issue) => issue?.severity === "warning")
    .map((issue) => `host:${issue.id}:${issue.detail}`);
  return lane(id, "skipped", {
    corpus,
    samples,
    strictRequired,
    reason: "benchmark host preflight failed; skipping speed comparison until host envelope is clean",
    requiredGateFailures: hostFailures.length > 0
      ? [
          {
            gate: id,
            reason: "clean benchmark host required before speed comparison",
            failures: hostFailures,
          },
        ]
      : [],
    remediation: benchmarkHostRemediation(hostPreflight?.metrics?.hostIssues ?? [], { corpus, stateDir }),
    hostPreflight: hostPreflight?.metrics ?? null,
  });
}

function installedSpeedLane(hostPreflight = null) {
  const corpus = benchmarkCorpus;
  const strictRequired = strictInstalledSpeed;
  if (quick) return lane("installed_speed_compare", "skipped", { reason: "--quick", strictRequired });
  if (!installedSpeed && !strictInstalledSpeed) {
    return lane("installed_speed_compare", "skipped", {
      reason: "enable with --installed-speed or --strict-installed-speed",
      strictRequired,
    });
  }
  if (hostPreflight?.status === "failed") {
    return speedHostPreflightSkipLane("installed_speed_compare", hostPreflight, {
      corpus,
      samples: installedSpeedSamples,
      strictRequired,
    });
  }
  if (!existsSync(corpus)) {
    return lane("installed_speed_compare", "skipped", { reason: "ripgrep benchsuite corpus missing", corpus, strictRequired });
  }
  const ix = findBuiltIx();
  if (!ix) {
    return lane("installed_speed_compare", "skipped", { reason: "zig-out binary missing; run build first", corpus, strictRequired });
  }

  const latestPath = path.join(ROOT, "tools", "reports", "manual-speed-compare", "latest-installed-speed.json");
  rmSync(latestPath, { force: true });
  const commandArgs = [
    "tools/scripts/compare-installed-speed.mjs",
    "--corpus",
    corpus,
    "--repo-ix",
    ix,
    "--samples",
    String(installedSpeedSamples),
    "--min-retainable-samples",
    String(minRetainableSpeedSamples),
    "--min-installed-improvement-pct",
    String(minInstalledImprovementPct),
    "--identity-noise-multiplier",
    String(identityNoiseMultiplier),
    "--quiet",
  ];
  if (strictRequired) {
    commandArgs.push("--require-strict", "--require-promotion");
  } else {
    commandArgs.push("--no-require-strict");
  }
  const evidence = run(process.execPath, commandArgs);
  if (!existsSync(latestPath)) {
    return lane("installed_speed_compare", "failed", {
      corpus,
      strictRequired,
      evidence,
      reason: "installed-speed comparator did not write latest-installed-speed.json",
    });
  }

  const latest = JSON.parse(readFileSync(latestPath, "utf8"));
  const installedHash = latest.binaries?.installed?.sha256 ?? null;
  const repoHash = latest.binaries?.repo?.sha256 ?? null;
  const parsed = {
    runId: latest.runId ?? null,
    samples: latest.samples ?? null,
    retainableStrictEvidence: latest.retainableStrictEvidence === true,
    strictEvidenceFailures: latest.strictEvidenceFailures ?? [],
    hashesMatch: typeof installedHash === "string" && installedHash.length > 0 && installedHash === repoHash,
    binaries: latest.binaries ?? null,
    processScan: {
      beforeOk: latest.processScan?.before?.ok === true,
      afterOk: latest.processScan?.after?.ok === true,
      beforeMatched: latest.processScan?.before?.matched?.length ?? null,
      afterMatched: latest.processScan?.after?.matched?.length ?? null,
      beforeFailures: latest.processScan?.before?.failures ?? [],
      afterFailures: latest.processScan?.after?.failures ?? [],
      beforeStateReports: summarizeComparatorStateReports(latest.processScan?.before),
      afterStateReports: summarizeComparatorStateReports(latest.processScan?.after),
    },
    medians: {
      ripgrepCliMs: latest.lanes?.ripgrep?.summary?.median ?? null,
      installedCliMs: latest.lanes?.installed?.cliSummary?.median ?? null,
      installedEngineMs: latest.lanes?.installed?.engineSummary?.median ?? null,
      repoCliMs: latest.lanes?.repo?.cliSummary?.median ?? null,
      repoEngineMs: latest.lanes?.repo?.engineSummary?.median ?? null,
    },
    identityControl: latest.lanes?.identityControl
      ? {
          samples: latest.lanes.identityControl.samples ?? null,
          firstEngineMedianMs: latest.lanes.identityControl.first?.engineSummary?.median ?? null,
          secondEngineMedianMs: latest.lanes.identityControl.second?.engineSummary?.median ?? null,
          medianDeltaPct: latest.lanes.identityControl.medianDeltaPct ?? null,
          pairedWinRate: latest.lanes.identityControl.pairedEngine?.candidateWinRate ?? null,
          matchParity: latest.lanes.identityControl.matchParity ?? null,
          routeParity: latest.lanes.identityControl.routeParity ?? null,
        }
      : null,
    installedRepoComparison: isPlainObject(latest.installedRepoComparison)
      ? {
          ...latest.installedRepoComparison,
          score: isPlainObject(latest.installedRepoComparison.score)
            ? {
                roundIndex: latest.installedRepoComparison.score.roundIndex ?? null,
                testedOneAtATime: latest.installedRepoComparison.score.testedOneAtATime ?? null,
                baselineLabel: latest.installedRepoComparison.score.baselineLabel ?? null,
                candidateLabel: latest.installedRepoComparison.score.candidateLabel ?? null,
                evidenceAuthority: latest.installedRepoComparison.score.evidenceAuthority ?? null,
                binaryRelation: latest.installedRepoComparison.score.binaryRelation ?? null,
                requiredImprovementPct: latest.installedRepoComparison.score.requiredImprovementPct ?? null,
                installedEngineMedianMs: latest.installedRepoComparison.score.installedEngineMedianMs ?? latest.installedRepoComparison.installedEngineMedianMs ?? null,
                repoEngineMedianMs: latest.installedRepoComparison.score.repoEngineMedianMs ?? latest.installedRepoComparison.repoEngineMedianMs ?? null,
                repoEngineImprovementPct: latest.installedRepoComparison.score.repoEngineImprovementPct ?? null,
                repoVsInstalledEngineRatio: latest.installedRepoComparison.score.repoVsInstalledEngineRatio ?? null,
                repoEngineDeltaMs: latest.installedRepoComparison.score.repoEngineDeltaMs ?? null,
                pairedRepoWinRate: latest.installedRepoComparison.score.pairedRepoWinRate ?? null,
                pairedRepoImprovementMedianPct: latest.installedRepoComparison.score.pairedRepoImprovementMedianPct ?? null,
                pairedRepoImprovementMeanPct: latest.installedRepoComparison.score.pairedRepoImprovementMeanPct ?? null,
                pairOrderBalanced: latest.installedRepoComparison.score.pairOrderBalanced ?? null,
                pairOrderAlternating: latest.installedRepoComparison.score.pairOrderAlternating ?? null,
                pairOrderFirstStarts: latest.installedRepoComparison.score.pairOrderFirstStarts ?? null,
                pairOrderSecondStarts: latest.installedRepoComparison.score.pairOrderSecondStarts ?? null,
                matchParity: latest.installedRepoComparison.score.matchParity ?? null,
                routeParity: latest.installedRepoComparison.score.routeParity ?? null,
                netPositive: latest.installedRepoComparison.score.netPositive ?? null,
              }
            : null,
        }
      : null,
    scorecard: isPlainObject(latest.scorecard) ? latest.scorecard : null,
    promotionMode: latest.promotionMode ?? null,
    promotionQualified: latest.promotionQualified === true,
    promotionFailures: latest.promotionFailures ?? [],
    requiredGateFailures: latest.requiredGateFailures ?? [],
    deltasPct: latest.deltasPct ?? null,
  };
  const laneFailures = [];
  if (strictRequired && parsed.retainableStrictEvidence !== true) {
    laneFailures.push("strict speed evidence is non-retainable");
  }
  if (strictRequired && Number(parsed.samples) < minRetainableSpeedSamples) {
    laneFailures.push(`strict speed evidence requires at least ${minRetainableSpeedSamples} samples`);
  }
  if (strictRequired && parsed.hashesMatch !== true && parsed.promotionQualified !== true) {
    laneFailures.push("strict installed speed requires repo promotion over installed");
  }
  if (strictRequired) {
    const score = parsed.installedRepoComparison?.score;
    if (!isPlainObject(score)) {
      laneFailures.push("installed-vs-repo score missing");
    } else if (score.testedOneAtATime !== true) {
      laneFailures.push("installed-vs-repo score was not recorded as one-at-a-time");
    } else if (parsed.hashesMatch !== true && score.netPositive !== true) {
      laneFailures.push("installed-vs-repo score was not net positive");
    } else if (!installedScoreMatchesRaw(parsed.installedRepoComparison, parsed.hashesMatch === true)) {
      laneFailures.push("installed-vs-repo score did not match raw comparison evidence");
    }
    if (!isPlainObject(parsed.scorecard)) {
      laneFailures.push("installed-vs-repo scorecard missing");
    } else if (parsed.hashesMatch !== true && parsed.scorecard.netPositive !== true) {
      laneFailures.push("installed-vs-repo scorecard was not net positive");
    } else if (!installedScorecardMatches(parsed.installedRepoComparison, parsed.scorecard, parsed.hashesMatch === true)) {
      laneFailures.push("installed-vs-repo scorecard did not match comparison score");
    }
  }
  return lane("installed_speed_compare", evidence.exitCode === 0 && laneFailures.length === 0 ? "ok" : "failed", {
    corpus,
    strictRequired,
    samples: installedSpeedSamples,
    evidence,
    report: parsed,
    failures: laneFailures,
    reason:
      evidence.exitCode !== 0
        ? "installed-speed comparator failed"
        : laneFailures.length > 0
          ? "installed-speed strict evidence gate failed"
          : undefined,
  });
}

function historicalSpeedLane(hostPreflight = null) {
  const corpus = benchmarkCorpus;
  const strictRequired = strictHistoricalSpeed;
  if (quick) return lane("historical_speed_compare", "skipped", { reason: "--quick", strictRequired });
  if (!historicalSpeed && !strictHistoricalSpeed) {
    return lane("historical_speed_compare", "skipped", {
      reason: "enable with --historical-speed or --strict-historical-speed",
      strictRequired,
    });
  }
  if (hostPreflight?.status === "failed") {
    return speedHostPreflightSkipLane("historical_speed_compare", hostPreflight, {
      corpus,
      samples: historicalSpeedSamples,
      strictRequired,
    });
  }
  if (!existsSync(corpus)) {
    return lane("historical_speed_compare", "skipped", { reason: "ripgrep benchsuite corpus missing", corpus, strictRequired });
  }
  const ix = findBuiltIx();
  if (!ix) {
    return lane("historical_speed_compare", "skipped", { reason: "zig-out binary missing; run build first", corpus, strictRequired });
  }

  const latestPath = path.join(ROOT, "tools", "reports", "historical-speed", "latest-historical-speed.json");
  rmSync(latestPath, { force: true });
  const commandArgs = [
    "tools/scripts/compare-historical-speed.mjs",
    "--corpus",
    corpus,
    "--repo-ix",
    ix,
    "--samples",
    String(historicalSpeedSamples),
    "--min-retainable-samples",
    String(minRetainableSpeedSamples),
    "--min-previous-build-improvement-pct",
    String(strictRequired ? minPreviousBuildImprovementPct : 0),
    "--identity-noise-multiplier",
    String(identityNoiseMultiplier),
    "--max-backups",
    "6",
    "--quiet",
  ];
  if (strictRequired) {
    commandArgs.push("--require-strict");
  } else {
    commandArgs.push("--no-require-strict");
  }
  const evidence = run(process.execPath, commandArgs);
  if (!existsSync(latestPath)) {
    return lane("historical_speed_compare", "failed", {
      corpus,
      strictRequired,
      evidence,
      reason: "historical-speed comparator did not write latest-historical-speed.json",
    });
  }

  const latest = JSON.parse(readFileSync(latestPath, "utf8"));
  const comparisons = Array.isArray(latest.comparisons)
    ? latest.comparisons.map((comparison) => ({
        label: comparison.label ?? null,
        path: comparison.path ?? null,
        roundIndex: comparison.roundIndex ?? comparison.score?.roundIndex ?? null,
        relation: comparison.relation ?? null,
        evidenceAuthority: comparison.evidenceAuthority ?? null,
        sha256: comparison.sha256 ?? null,
        matchParity: comparison.matchParity ?? null,
        currentEngineMedianMs: comparison.current?.engineSummary?.median ?? null,
        historyEngineMedianMs: comparison.historyEngineMedianMs ?? comparison.history?.engineSummary?.median ?? null,
        currentVsHistoryEngineRatio: comparison.currentVsHistoryEngineRatio ?? null,
        currentEngineDeltaMs: comparison.currentEngineDeltaMs ?? null,
        currentEngineImprovementPct: comparison.currentEngineImprovementPct ?? null,
        minPreviousBuildImprovementPct: comparison.minPreviousBuildImprovementPct ?? latest.minPreviousBuildImprovementPct ?? null,
        promotionQualified: comparison.promotionQualified ?? null,
        pairOrderSummary: comparison.pairOrderSummary ?? null,
        score: isPlainObject(comparison.score)
          ? {
              roundIndex: comparison.score.roundIndex ?? comparison.roundIndex ?? null,
              testedOneAtATime: comparison.score.testedOneAtATime ?? null,
              baselineLabel: comparison.score.baselineLabel ?? comparison.label ?? null,
              candidateLabel: comparison.score.candidateLabel ?? "repo-current",
              evidenceAuthority: comparison.score.evidenceAuthority ?? comparison.evidenceAuthority ?? null,
              requiredImprovementPct: comparison.score.requiredImprovementPct ?? comparison.minPreviousBuildImprovementPct ?? latest.minPreviousBuildImprovementPct ?? null,
              historyEngineMedianMs: comparison.score.historyEngineMedianMs ?? comparison.historyEngineMedianMs ?? comparison.historical?.engineSummary?.median ?? null,
              currentEngineMedianMs: comparison.score.currentEngineMedianMs ?? comparison.currentEngineMedianMs ?? comparison.current?.engineSummary?.median ?? null,
              currentEngineImprovementPct: comparison.score.currentEngineImprovementPct ?? comparison.currentEngineImprovementPct ?? null,
              currentVsHistoryEngineRatio: comparison.score.currentVsHistoryEngineRatio ?? comparison.currentVsHistoryEngineRatio ?? null,
              currentEngineDeltaMs: comparison.score.currentEngineDeltaMs ?? comparison.currentEngineDeltaMs ?? null,
              pairedCurrentWinRate: comparison.score.pairedCurrentWinRate ?? comparison.pairedEngine?.candidateWinRate ?? null,
              pairedCurrentImprovementMedianPct: comparison.score.pairedCurrentImprovementMedianPct ?? null,
              pairedCurrentImprovementMeanPct: comparison.score.pairedCurrentImprovementMeanPct ?? null,
              pairOrderBalanced: comparison.score.pairOrderBalanced ?? null,
              pairOrderAlternating: comparison.score.pairOrderAlternating ?? null,
              pairOrderFirstStarts: comparison.score.pairOrderFirstStarts ?? null,
              pairOrderSecondStarts: comparison.score.pairOrderSecondStarts ?? null,
              matchParity: comparison.score.matchParity ?? comparison.matchParity ?? null,
              routeParity: comparison.score.routeParity ?? comparison.routeParity ?? null,
              netPositive: comparison.score.netPositive ?? null,
            }
          : null,
        pairedEngine: comparison.pairedEngine
          ? {
              ...comparison.pairedEngine,
              candidateWinRate: comparison.pairedEngine.candidateWinRate ?? null,
              currentWins: comparison.pairedEngine.candidateWins ?? null,
              historicalWins: comparison.pairedEngine.baselineWins ?? null,
              currentWinRate: comparison.pairedEngine.candidateWinRate ?? null,
              deltaMedianMs: comparison.pairedEngine.deltaSummary?.median ?? null,
              deltaMeanMs: comparison.pairedEngine.deltaSummary?.mean ?? null,
              currentImprovementMedianPct: comparison.pairedEngine.candidateImprovementPctSummary?.median ?? null,
              currentImprovementMeanPct: comparison.pairedEngine.candidateImprovementPctSummary?.mean ?? null,
            }
          : null,
        currentRoute: summarizeAlternateRoute(comparison.currentRoute ?? {
          teddy: comparison.current?.alternateTeddyRangeCalls,
          pcre: comparison.current?.alternatePcreRangeCalls,
          compiled: comparison.current?.alternateCompiledRangeCalls,
        }),
        historicalRoute: summarizeAlternateRoute(comparison.historicalRoute ?? {
          teddy: comparison.historical?.alternateTeddyRangeCalls,
          pcre: comparison.historical?.alternatePcreRangeCalls,
          compiled: comparison.historical?.alternateCompiledRangeCalls,
        }),
        routeParity: comparison.routeParity ?? null,
      }))
    : [];
  const previousBuildEngineMedians = comparisons
    .filter((comparison) => comparison.evidenceAuthority === "previous_build")
    .map((comparison) => Number(comparison.currentEngineMedianMs))
    .filter(Number.isFinite);
  const parsed = {
    runId: latest.runId ?? null,
    samples: latest.samples ?? null,
    includeCurrentInstall: latest.includeCurrentInstall === true,
    minPreviousBuildImprovementPct: latest.minPreviousBuildImprovementPct ?? null,
    retainableStrictEvidence: latest.retainableStrictEvidence === true,
    strictEvidenceFailures: latest.strictEvidenceFailures ?? [],
    requiredGateFailures: latest.requiredGateFailures ?? [],
    currentIdentity: latest.currentIdentity ?? null,
    identityControl: latest.identityControl
      ? {
          samples: latest.identityControl.samples ?? null,
          firstEngineMedianMs: latest.identityControl.first?.engineSummary?.median ?? null,
          secondEngineMedianMs: latest.identityControl.second?.engineSummary?.median ?? null,
          medianDeltaPct: latest.identityControl.medianDeltaPct ?? null,
          pairedWinRate: latest.identityControl.pairedEngine?.candidateWinRate ?? null,
          matchParity: latest.identityControl.matchParity ?? null,
          routeParity: latest.identityControl.routeParity ?? null,
        }
      : null,
    medians: {
      ripgrepCliMs: latest.ripgrep?.summary?.median ?? null,
      currentEngineMs:
        previousBuildEngineMedians.length > 0
          ? previousBuildEngineMedians.reduce((sum, value) => sum + value, 0) / previousBuildEngineMedians.length
          : comparisons[0]?.currentEngineMedianMs ?? null,
    },
    processScan: {
      beforeOk: latest.processScan?.before?.ok === true,
      afterOk: latest.processScan?.after?.ok === true,
      beforeMatched: latest.processScan?.before?.matched?.length ?? null,
      afterMatched: latest.processScan?.after?.matched?.length ?? null,
      beforeFailures: latest.processScan?.before?.failures ?? [],
      afterFailures: latest.processScan?.after?.failures ?? [],
      beforeStateReports: summarizeComparatorStateReports(latest.processScan?.before),
      afterStateReports: summarizeComparatorStateReports(latest.processScan?.after),
    },
    comparisons,
    scorecard: isPlainObject(latest.scorecard) ? latest.scorecard : null,
    roundLedger: Array.isArray(latest.roundLedger) ? latest.roundLedger : null,
  };
  const laneFailures = [];
  if (strictRequired && parsed.retainableStrictEvidence !== true) {
    laneFailures.push("strict speed evidence is non-retainable");
  }
  if (strictRequired && Number(parsed.samples) < minRetainableSpeedSamples) {
    laneFailures.push(`strict speed evidence requires at least ${minRetainableSpeedSamples} samples`);
  }
  if (strictRequired) {
    if (parsed.includeCurrentInstall === true) {
      laneFailures.push("historical strict comparison included current install identity");
    }
    if (!isPlainObject(parsed.scorecard)) {
      laneFailures.push("previous build scorecard missing");
    } else if (parsed.scorecard.testedOneAtATime !== true) {
      laneFailures.push("previous build scorecard was not recorded as one-at-a-time");
    } else if (parsed.scorecard.netPositive !== true) {
      laneFailures.push("previous build scorecard was not net positive");
    } else if (!historicalScorecardMatches(comparisons, parsed.scorecard)) {
      laneFailures.push("previous build scorecard did not match comparison rows");
    }
    if (!Array.isArray(parsed.roundLedger)) {
      laneFailures.push("previous build round ledger missing");
    } else if (!historicalRoundLedgerMatches(comparisons, parsed.roundLedger)) {
      laneFailures.push("previous build round ledger did not match comparison rows");
    }
    for (const [comparisonIndex, comparison] of comparisons.entries()) {
      if (comparison.evidenceAuthority !== "previous_build") continue;
      if (comparison.promotionQualified !== true) {
        laneFailures.push(`previous build improvement target not met: ${comparison.label}`);
      }
      if (!isPlainObject(comparison.score)) {
        laneFailures.push(`previous build round score missing: ${comparison.label}`);
      } else if (comparison.score.testedOneAtATime !== true) {
        laneFailures.push(`previous build round was not recorded as one-at-a-time: ${comparison.label}`);
      } else if (comparison.score.netPositive !== true) {
        laneFailures.push(`previous build round was not net positive: ${comparison.label}`);
      } else if (!historicalScoreMatchesRaw(comparison, comparisonIndex)) {
        laneFailures.push(`previous build round score did not match raw comparison evidence: ${comparison.label}`);
      }
    }
  }
  return lane("historical_speed_compare", evidence.exitCode === 0 && laneFailures.length === 0 ? "ok" : "failed", {
    corpus,
    strictRequired,
    samples: historicalSpeedSamples,
    evidence,
    report: parsed,
    failures: laneFailures,
    reason:
      evidence.exitCode !== 0
        ? "historical-speed comparator failed"
        : laneFailures.length > 0
          ? "historical-speed strict evidence gate failed"
          : undefined,
  });
}

function olderSnapshotLadderLane(hostPreflight = null) {
  const corpus = benchmarkCorpus;
  const strictRequired = strictOlderSnapshots;
  if (quick) return lane("older_snapshot_ladder", "skipped", { reason: "--quick", strictRequired });
  if (!olderSnapshots && !strictOlderSnapshots) {
    return lane("older_snapshot_ladder", "skipped", {
      reason: "enable with --older-snapshots or --strict-older-snapshots",
      strictRequired,
    });
  }
  if (hostPreflight?.status === "failed") {
    return speedHostPreflightSkipLane("older_snapshot_ladder", hostPreflight, {
      corpus,
      samples: olderSnapshotSamples,
      strictRequired,
    });
  }
  if (!existsSync(corpus)) {
    return lane("older_snapshot_ladder", "skipped", { reason: "ripgrep benchsuite corpus missing", corpus, strictRequired });
  }
  const ix = findBuiltIx();
  if (!ix) {
    return lane("older_snapshot_ladder", "skipped", { reason: "zig-out binary missing; run build first", corpus, strictRequired });
  }

  const latestPath = path.join(ROOT, "tools", "reports", "older-snapshot-ladder", "latest-architecture-gate-older-snapshot-ladder.json");
  rmSync(latestPath, { force: true });
  const commandArgs = [
    "tools/scripts/compare-older-snapshots.mjs",
    "--samples",
    String(olderSnapshotSamples),
    "--identity-control-samples",
    String(Math.min(12, olderSnapshotSamples)),
    "--identity-control-attempts",
    String(olderSnapshotIdentityAttempts),
    "--min-retainable-samples",
    String(minRetainableSpeedSamples),
    "--min-engine-improvement-pct",
    String(strictRequired ? minOlderSnapshotEngineImprovementPct : 0),
    "--min-paired-improvement-pct",
    String(strictRequired ? minOlderSnapshotPairedImprovementPct : 0),
    "--no-child-benchmark-lock",
    "--latest-path",
    latestPath,
    "--quiet",
  ];
  if (olderSnapshotMax !== "") commandArgs.push("--max-snapshots", olderSnapshotMax);
  if (strictRequired && olderSnapshotRetainableTarget !== "") {
    commandArgs.push("--target-retainable-snapshots", olderSnapshotRetainableTarget);
  }
  if (strictRequired) commandArgs.push("--require-strict");
  const evidence = run(process.execPath, commandArgs);
  if (!existsSync(latestPath)) {
    return lane("older_snapshot_ladder", "failed", {
      corpus,
      strictRequired,
      evidence,
      reason: "older snapshot comparator did not write latest-older-snapshot-ladder.json",
    });
  }

  const latest = JSON.parse(readFileSync(latestPath, "utf8"));
  const parsedRounds = Array.isArray(latest.rounds)
    ? latest.rounds.map((round) => ({
        index: round.index ?? null,
        label: round.label ?? null,
        path: round.path ?? null,
        sourceReportPath: round.sourceReportPath ?? null,
        runnable: round.runnable === true,
        strict: round.strict === true,
        status: round.status ?? null,
        baselineMedianMs: round.baselineMedianMs ?? null,
        repoMedianMs: round.repoMedianMs ?? null,
        enginePct: round.enginePct ?? null,
        pairedPct: round.pairedPct ?? null,
        winRate: round.winRate ?? null,
        failures: round.failures ?? [],
        promotionFailures: round.promotionFailures ?? [],
        identityControl: round.identityControl ?? null,
        processScan: round.processScan ?? null,
        routeParityStatus: round.routeParityStatus ?? null,
        matchParity: round.matchParity ?? null,
        pairOrderSummary: round.pairOrderSummary ?? null,
        pairedEngine: round.pairedEngine ?? null,
        error: round.error ?? null,
      }))
    : [];
  const parsed = {
    runId: latest.runId ?? null,
    baselineDir: latest.baselineDir ?? null,
    samples: latest.samples ?? null,
    identityControlSamples: latest.identityControlSamples ?? null,
    identityControlAttempts: latest.identityControlAttempts ?? null,
    minRetainableSamples: latest.minRetainableSamples ?? null,
    targetRetainableSnapshots: latest.targetRetainableSnapshots ?? null,
    minEngineImprovementPct: latest.minEngineImprovementPct ?? null,
    minPairedImprovementPct: latest.minPairedImprovementPct ?? null,
    sort: latest.sort ?? null,
    runnableSnapshots: latest.runnableSnapshots ?? null,
    retainableSnapshots: latest.retainableSnapshots ?? null,
    nonRetainableRunnableSnapshots: latest.nonRetainableRunnableSnapshots ?? null,
    skippedSnapshots: latest.skippedSnapshots ?? null,
    strictRequired: latest.strictRequired === true,
    retainableEvidence: latest.retainableEvidence === true,
    failures: latest.failures ?? [],
    failureSummary: latest.failureSummary ?? null,
    rounds: parsedRounds,
  };
  const retainedSampleFloorMet = Number(parsed.samples) >= minRetainableSpeedSamples;
  const enforceRetainedSpeed = strictRequired || retainedSampleFloorMet;
  const laneFailures = [];
  if (enforceRetainedSpeed && parsed.retainableEvidence !== true) {
    laneFailures.push("older snapshot ladder evidence is non-retainable");
  }
  if (Number(parsed.runnableSnapshots) < 1) {
    laneFailures.push("older snapshot ladder requires at least one runnable snapshot");
  }
  if (strictRequired && Number(parsed.samples) < minRetainableSpeedSamples) {
    laneFailures.push(`strict older snapshot evidence requires at least ${minRetainableSpeedSamples} samples`);
  }
  if (strictRequired && Number(parsed.minRetainableSamples) !== minRetainableSpeedSamples) {
    laneFailures.push(`strict older snapshot child evidence must use retained sample floor ${minRetainableSpeedSamples}`);
  }
  if (strictRequired && parsed.strictRequired !== true) {
    laneFailures.push("strict older snapshot lane must run comparator in strict mode");
  }
  if (strictRequired && Number(parsed.identityControlAttempts) < olderSnapshotIdentityAttempts) {
    laneFailures.push(`strict older snapshot evidence requires at least ${olderSnapshotIdentityAttempts} identity-control attempts`);
  }
  if (strictRequired && Number(parsed.minEngineImprovementPct) < minOlderSnapshotEngineImprovementPct) {
    laneFailures.push(`strict older snapshot evidence requires engine improvement target ${minOlderSnapshotEngineImprovementPct}%`);
  }
  if (strictRequired && Number(parsed.minPairedImprovementPct) < minOlderSnapshotPairedImprovementPct) {
    laneFailures.push(`strict older snapshot evidence requires paired improvement target ${minOlderSnapshotPairedImprovementPct}%`);
  }
  if (strictRequired && olderSnapshotRetainableTarget !== "" && Number(parsed.retainableSnapshots) < Number(olderSnapshotRetainableTarget)) {
    laneFailures.push(`strict older snapshot evidence requires ${olderSnapshotRetainableTarget} retainable snapshots`);
  }
  for (const round of parsedRounds) {
    if (round.runnable !== true) continue;
    const requiredEnginePct = strictRequired ? minOlderSnapshotEngineImprovementPct : 0;
    const requiredPairedPct = strictRequired ? minOlderSnapshotPairedImprovementPct : 0;
    if (enforceRetainedSpeed && Number(round.enginePct) < requiredEnginePct) {
      laneFailures.push(`older snapshot engine improvement below target: ${round.label}`);
    }
    if (enforceRetainedSpeed && Number(round.pairedPct) < requiredPairedPct) {
      laneFailures.push(`older snapshot paired improvement below target: ${round.label}`);
    }
    if (strictRequired && round.strict !== true) laneFailures.push(`older snapshot strict evidence missing: ${round.label}`);
  }
  const comparatorExitAcceptable = evidence.exitCode === 0 || (!enforceRetainedSpeed && Number(parsed.runnableSnapshots) >= 1);
  return lane("older_snapshot_ladder", comparatorExitAcceptable && laneFailures.length === 0 ? "ok" : "failed", {
    corpus,
    strictRequired,
    samples: olderSnapshotSamples,
    maxSnapshots: olderSnapshotMax === "" ? null : Number(olderSnapshotMax),
    targetRetainableSnapshots: strictRequired && olderSnapshotRetainableTarget !== "" ? Number(olderSnapshotRetainableTarget) : null,
    identityControlAttempts: olderSnapshotIdentityAttempts,
    minEngineImprovementPct: strictRequired ? minOlderSnapshotEngineImprovementPct : 0,
    minPairedImprovementPct: strictRequired ? minOlderSnapshotPairedImprovementPct : 0,
    retainedSampleFloorMet,
    diagnosticOnly: !enforceRetainedSpeed,
    evidence,
    report: parsed,
    failures: laneFailures,
    reason:
      evidence.exitCode !== 0 && enforceRetainedSpeed
        ? "older snapshot comparator failed"
        : laneFailures.length > 0
          ? "older snapshot ladder gate failed"
          : undefined,
  });
}

const { alternatesDecisionLane } = createAlternatesDecisionGateLane({
  root: ROOT,
  benchmarkCorpus,
  quick,
  alternatesDecision,
  alternatesDecisionSamples,
  alternatesDecisionMaxBranches,
  alternatesDecisionBranchCounts,
  minRetainableSpeedSamples,
  stateDir,
  run,
  lane,
  benchmarkHostRemediation,
  findBuiltIx,
  sha256File,
  nativeInstallIx: NATIVE_INSTALL_IX,
  nativeInstallDir: NATIVE_INSTALL_DIR,
  latestDistinctNativeBackup,
});

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

const { planningLane, planningQueueLane } = createPlanningGateValidation({
  root: ROOT,
  lane,
  planningChainSlug,
  planningChainPhasesArg,
  planningChainState,
});

const {
  agentDryRunLane,
  agentRealLane,
  agentPathContractLane,
  buildLane,
  smokeLane,
  surfaceParityLane,
  warmColdParityLane,
} = createAgentSurfaceGateValidation({
  stateDir,
  speedOnly,
  quick,
  run,
  lane,
  psQuote,
  findBuiltIx,
  resolveZigExe,
});

const {
  defaultStateLocationLane,
  generationRecoveryLane,
  memoryCapLane,
  runtimeStateLocationLane,
  warmIndexLane,
} = createRuntimeStateGateValidation({
  root: ROOT,
  stateDir,
  speedOnly,
  run,
  lane,
  psQuote,
  findBuiltIx,
  resolveZigExe,
});

const { ripgrepLane } = createRipgrepGateLane({
  root: ROOT,
  benchmarkCorpus,
  quick,
  run,
  lane,
  hostBenchmarkIssues,
  hostBenchmarkClean,
  baselineIxMs,
  baselineTolerancePct,
  baselineSoftTolerancePct,
  pairedImprovementTolerancePct,
  patchNoRegressionTolerancePct,
  ripgrepWarmupSamples,
  baselineWarmupSamples,
  previousIxBinary,
});

function benchmarkLockLane() {
  const { failures, metrics } = benchmarkLockSelfTest();
  return lane("benchmark_lock", failures.length === 0 ? "ok" : "failed", {
    failures,
    metrics,
  });
}

function benchmarkHostPreflightLane() {
  return createBenchmarkHostPreflightLane({ lane, snapshot: hostSnapshot() });
}

function benchmarkControlLane(hostPreflight = null) {
  const corpus = benchmarkCorpus;
  if (!existsSync(corpus)) return lane("benchmark_control", "skipped", { reason: "ripgrep benchsuite corpus missing", corpus });
  if (quick) return lane("benchmark_control", "skipped", { reason: "--quick", corpus });
  if (hostPreflight?.status === "failed") {
    return lane("benchmark_control", "skipped", {
      corpus,
      reason: "benchmark host preflight failed; skipping same-binary control until host envelope is clean",
      remediation: benchmarkHostRemediation(hostPreflight.metrics?.hostIssues ?? [], { corpus, stateDir }),
      hostPreflight: hostPreflight.metrics ?? null,
    });
  }
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
  const host = latest.host ?? null;
  const hostIssues = hostBenchmarkIssues(host);
  const hostClean = hostBenchmarkClean(hostIssues);
  const ixMs = Number(latest.iexMs);
  const selfMs = Number(latest.competitors?.iex_previous?.durationMs);
  const selfRatio = Number(latest.iexToPreviousRatio);
  const driftPct = Number.isFinite(selfRatio) && selfRatio > 0 ? Math.abs(1 - selfRatio) * 100 : null;
  const baselineComparable = ripgrepWarmupSamples === baselineWarmupSamples;
  const baselineRegressionPct =
    baselineComparable && Number.isFinite(ixMs) && baselineIxMs > 0 ? ((ixMs - baselineIxMs) / baselineIxMs) * 100 : null;
  const baselineOk = baselineComparable && Number.isFinite(ixMs) && ixMs <= baselineIxMs * (1 + baselineTolerancePct / 100);
  const currentRobustCvPct = Number(latest.iexEngineSampleSummary?.robustCvPct);
  const previousRobustCvPct = Number(latest.competitors?.iex_previous?.engineSampleSummary?.robustCvPct);
  const robustCvOk =
    Number.isFinite(currentRobustCvPct) &&
    Number.isFinite(previousRobustCvPct) &&
    currentRobustCvPct <= benchmarkControlRobustCvPct &&
    previousRobustCvPct <= benchmarkControlRobustCvPct;
  const authority = latest.previousIexAuthority ?? null;
  const matchCountParity = latest.previousIexMatchCountParity ?? null;
  const selfOk =
    authority === "authoritative" &&
    matchCountParity !== false &&
    Number.isFinite(ixMs) &&
    Number.isFinite(selfMs) &&
    Number.isFinite(driftPct) &&
    driftPct <= benchmarkControlDriftTolerancePct;
  const ok = selfOk && robustCvOk && baselineComparable && hostClean && baselineOk;
  const failedChecks = [];
  if (!selfOk) failedChecks.push("self_drift");
  if (!robustCvOk) failedChecks.push("robust_cv");
  if (!baselineComparable) failedChecks.push("baseline_warmup");
  if (!hostClean) failedChecks.push("host_noise");
  if (!baselineOk) failedChecks.push("fixed_baseline");
  const failureSummary = {
    failedChecks,
    primary: failedChecks[0] ?? null,
    thresholds: {
      driftPct: benchmarkControlDriftTolerancePct,
      robustCvPct: benchmarkControlRobustCvPct,
      maxAllowedIxMs: baselineIxMs * (1 + baselineTolerancePct / 100),
      baselineTolerancePct,
    },
    observed: {
      driftPct,
      currentRobustCvPct,
      previousRobustCvPct,
      ixMs,
      selfMs,
      baselineRegressionPct,
      baselineComparable,
      hostClean,
    },
    sampleSpread: {
      ixEngine: latest.iexEngineSampleSummary ?? null,
      selfEngine: latest.competitors?.iex_previous?.engineSampleSummary ?? null,
    },
  };
  const reason = !selfOk
    ? "same-binary control drift exceeded tolerance; benchmark window is too noisy for attribution"
    : !hostClean
      ? "host benchmark envelope contains warning-class noise; rerun under a clean host before fixed-baseline attribution"
    : !robustCvOk
      ? "same-binary control sample spread exceeded robust CV tolerance; benchmark window is too noisy for fixed-baseline attribution"
    : !baselineComparable
      ? "control benchmark warmup does not match the fixed baseline; rerun with the baseline warmup or provide a matching baseline"
      : !baselineOk
        ? "control benchmark missed the fixed baseline improvement floor; benchmark window cannot prove speed improvement"
        : undefined;

  return lane("benchmark_control", ok ? "ok" : "failed", {
    corpus,
    evidence: bench,
    reason,
    metrics: {
      profile: latest.profile,
      expression: latest.expression,
      samples: 12,
      warmup: ripgrepWarmupSamples,
      ixMs,
      selfMs,
      baselineIxMs,
      baselineWarmupSamples,
      baselineComparable,
      baselineTolerancePct,
      maxAllowedIxMs: baselineIxMs * (1 + baselineTolerancePct / 100),
      baselineRegressionPct,
      baselineOk,
      robustCvOk,
      currentRobustCvPct,
      previousRobustCvPct,
      benchmarkControlRobustCvPct,
      ixBinaryIdentity: latest.ixBinaryIdentity ?? null,
      selfBinaryIdentity: latest.competitors?.iex_previous?.binaryIdentity ?? null,
      selfSourceRelation: latest.previousIxSourceRelation ?? null,
      selfRatio: Number.isFinite(selfRatio) ? selfRatio : null,
      driftPct,
      selfOk,
      benchmarkControlDriftTolerancePct,
      authority,
      matchCountParity,
      ixEngineSampleDurationsMs: latest.iexEngineSampleDurationsMs ?? [],
      ixEngineSampleSummary: latest.iexEngineSampleSummary ?? null,
      selfEngineSampleDurationsMs: latest.competitors?.iex_previous?.engineSampleDurationsMs ?? [],
      selfEngineSampleSummary: latest.competitors?.iex_previous?.engineSampleSummary ?? null,
      selfPairing: latest.competitors?.iex_previous?.pairing ?? null,
      rgSampleDurationsMs: latest.competitors?.ripgrep?.sampleDurationsMs ?? [],
      rgSampleSummary: latest.competitors?.ripgrep?.sampleSummary ?? null,
      hostIssues,
      hostClean,
      matchCount: latest.matchCount ?? null,
      phaseMs: latest.phaseMs ?? {},
      host,
      failureSummary,
    },
  });
}

function benchmarkReadinessLane(hostPreflight, benchmarkControl, speedLanes = []) {
  return createBenchmarkReadinessLane({ lane, hostPreflight, benchmarkControl, speedLanes });
}

const worktree = worktreeLane();
const planning = planningLane();
const planningQueue = planningQueueLane();
const diffCheck = diffCheckLane();
const benchmarkLock = benchmarkLockLane();
const benchmarkHostPreflight = benchmarkHostPreflightLane();
const benchmarkControl = benchmarkControlLane(benchmarkHostPreflight);
const installedSpeedCompare = installedSpeedLane(benchmarkHostPreflight);
const historicalSpeedCompare = historicalSpeedLane(benchmarkHostPreflight);
const olderSnapshotLadder = olderSnapshotLadderLane(benchmarkHostPreflight);
const benchmarkReadiness = benchmarkReadinessLane(benchmarkHostPreflight, benchmarkControl, [
  installedSpeedCompare,
  historicalSpeedCompare,
  olderSnapshotLadder,
]);
const ripgrep = ripgrepLane(benchmarkControl);
const teddyKernelDecision = teddyKernelDecisionLane();
const nativeInstallIdentity = nativeInstallIdentityLane();
const teddyKernelContract = teddyKernelContractLane();

const lanes = [
  worktree,
  planning,
  planningQueue,
  diffCheck,
  benchmarkLock,
  benchmarkHostPreflight,
  benchmarkReadiness,
  benchmarkControl,
  ripgrep,
  teddyKernelDecision,
  nativeInstallIdentity,
  installedSpeedCompare,
  historicalSpeedCompare,
  olderSnapshotLadder,
  teddyKernelContract,
  alternatesDecisionLane(benchmarkHostPreflight),
  agentDryRunLane(),
  agentRealLane(),
  buildLane(),
  smokeLane(),
  surfaceParityLane(),
  agentPathContractLane(),
  warmColdParityLane(),
  warmIndexLane(),
  generationRecoveryLane(),
  defaultStateLocationLane(),
  runtimeStateLocationLane(),
  memoryCapLane(),
  scanIxProcesses(),
];

const failed = lanes.filter((entry) => entry.status === "failed");
const report = {
  status: failed.length === 0 ? "ok" : "failed",
  mode: quick ? "quick" : speedOnly ? "speed-only" : "full",
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
