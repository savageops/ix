import { existsSync, mkdirSync, readFileSync, readdirSync, statSync, writeFileSync } from "node:fs";
import path from "node:path";
import { spawnSync } from "node:child_process";
import { argValue, timestampSlug } from "./lib/script-helpers.mjs";

const ROOT = process.cwd();
const REPORT_DIR = path.join(ROOT, "tools", "reports", "older-snapshot-ladder");
const DEFAULT_BASELINE_DIR = path.join(ROOT, "tools", "reports", "manual-speed-compare", "tmp-baselines");
const COMPARE_SCRIPT = path.join(ROOT, "tools", "scripts", "compare-installed-speed.mjs");

const args = process.argv.slice(2);
if (args.includes("--help") || args.includes("-h")) {
  console.log(`Usage: node tools/scripts/compare-older-snapshots.mjs [options]

Runs older IX snapshot comparisons one executable at a time through the
canonical installed-speed comparator and writes a single ladder report.

Options:
  --baseline-dir <path>           Directory containing older IX .exe snapshots.
                                  Default: tools/reports/manual-speed-compare/tmp-baselines.
  --samples <n>                   Samples per snapshot. Default: 12.
  --identity-control-samples <n>  Same-binary control samples. Default: min(12, samples).
  --identity-control-attempts <n> Same-binary control attempts. Default: 1.
  --min-retainable-samples <n>    Minimum samples for child strict evidence.
                                  Default: 12.
  --max-snapshots <n>             Limit runnable snapshot comparisons after mtime sort.
                                  Skipped snapshots are still recorded. Default: all.
  --target-retainable-snapshots <n>
                                  Continue past noisy runnable snapshots until this many
                                  retainable snapshot rounds are collected. Default: off.
  --max-candidates <n>            Optional hard cap on candidate executables scanned.
  --min-engine-improvement-pct <n>
                                  Required per-runnable-snapshot engine improvement.
                                  Default: 0.
  --min-paired-improvement-pct <n>
                                  Required per-runnable-snapshot paired median improvement.
                                  Default: 0.
  --latest-path <path>            Path for latest-report pointer. Default:
                                  tools/reports/older-snapshot-ladder/latest-older-snapshot-ladder.json.
  --newest-first                  Sort snapshots newest to oldest. Default: oldest first.
  --require-strict                Exit non-zero if any runnable snapshot lacks strict evidence.
  --dry-run                       Print selected snapshots and write no benchmark report.
  --no-child-benchmark-lock       Forward --no-benchmark-lock to child comparators.
                                  Use only from an outer benchmark gate.
  --quiet                         Suppress per-snapshot console summary.
  --help, -h                      Print this help.
`);
  process.exit(0);
}

const baselineDir = path.resolve(argValue(args, "--baseline-dir", DEFAULT_BASELINE_DIR));
const samples = Number(argValue(args, "--samples", "12"));
const identityControlSamples = Number(argValue(args, "--identity-control-samples", String(Math.min(12, samples))));
const identityControlAttempts = Number(argValue(args, "--identity-control-attempts", process.env.IX_IDENTITY_CONTROL_ATTEMPTS ?? "1"));
const minRetainableSamples = Number(argValue(args, "--min-retainable-samples", process.env.IX_MIN_RETAINABLE_SPEED_SAMPLES ?? "12"));
const maxSnapshotsRaw = argValue(args, "--max-snapshots", "");
const maxSnapshots = maxSnapshotsRaw === "" ? Infinity : Number(maxSnapshotsRaw);
const targetRetainableSnapshotsRaw = argValue(args, "--target-retainable-snapshots", "");
const targetRetainableSnapshots = targetRetainableSnapshotsRaw === "" ? Infinity : Number(targetRetainableSnapshotsRaw);
const maxCandidatesRaw = argValue(args, "--max-candidates", "");
const maxCandidates = maxCandidatesRaw === "" ? Infinity : Number(maxCandidatesRaw);
const minEngineImprovementPct = Number(argValue(args, "--min-engine-improvement-pct", "0"));
const minPairedImprovementPct = Number(argValue(args, "--min-paired-improvement-pct", "0"));
const latestPath = path.resolve(argValue(args, "--latest-path", path.join(REPORT_DIR, "latest-older-snapshot-ladder.json")));
const newestFirst = args.includes("--newest-first");
const requireStrict = args.includes("--require-strict");
const dryRun = args.includes("--dry-run");
const childBenchmarkLock = !args.includes("--no-child-benchmark-lock");
const quiet = args.includes("--quiet");

if (!existsSync(COMPARE_SCRIPT)) throw new Error(`compare script not found: ${COMPARE_SCRIPT}`);
if (!existsSync(baselineDir)) throw new Error(`baseline directory not found: ${baselineDir}`);
if (!Number.isFinite(samples) || samples < 1) throw new Error("--samples must be a positive number");
if (!Number.isFinite(identityControlSamples) || identityControlSamples < 0) throw new Error("--identity-control-samples must be a non-negative number");
if (!Number.isFinite(identityControlAttempts) || identityControlAttempts < 1) throw new Error("--identity-control-attempts must be a positive number");
if (!Number.isFinite(minRetainableSamples) || minRetainableSamples < 1) throw new Error("--min-retainable-samples must be a positive number");
if (maxSnapshots !== Infinity && (!Number.isFinite(maxSnapshots) || maxSnapshots < 1)) throw new Error("--max-snapshots must be a positive number");
if (targetRetainableSnapshots !== Infinity && (!Number.isFinite(targetRetainableSnapshots) || targetRetainableSnapshots < 1)) {
  throw new Error("--target-retainable-snapshots must be a positive number");
}
if (maxCandidates !== Infinity && (!Number.isFinite(maxCandidates) || maxCandidates < 1)) throw new Error("--max-candidates must be a positive number");
if (!Number.isFinite(minEngineImprovementPct)) throw new Error("--min-engine-improvement-pct must be a finite number");
if (!Number.isFinite(minPairedImprovementPct)) throw new Error("--min-paired-improvement-pct must be a finite number");

function snapshotCandidates() {
  const candidates = readdirSync(baselineDir)
    .filter((name) => name.toLowerCase().endsWith(".exe"))
    .map((name) => {
      const fullPath = path.join(baselineDir, name);
      const stat = statSync(fullPath);
      return {
        label: name.replace(/\.exe$/i, ""),
        path: fullPath,
        bytes: stat.size,
        mtimeMs: stat.mtimeMs,
        mtimeIso: stat.mtime.toISOString(),
      };
    })
    .sort((left, right) => newestFirst ? right.mtimeMs - left.mtimeMs : left.mtimeMs - right.mtimeMs);
  return candidates.slice(0, maxCandidates);
}

function readLatestInstalledSummary() {
  const reportPath = path.join(ROOT, "tools", "reports", "manual-speed-compare", "latest-installed-speed.json");
  const report = JSON.parse(readFileSync(reportPath, "utf8").replace(/^\uFEFF/, ""));
  const sourceReportPath = path.join(ROOT, "tools", "reports", "manual-speed-compare", `${report.runId}.json`);
  const round = report.ledgerSummary?.rounds?.[0] ?? {};
  return {
    runId: report.runId,
    sourceReportPath: existsSync(sourceReportPath) ? sourceReportPath : null,
    strict: report.retainableStrictEvidence,
    promotion: report.promotionQualified,
    status: round.status ?? null,
    baselineMedianMs: round.baselineEngineMedianMs ?? null,
    repoMedianMs: round.candidateEngineMedianMs ?? null,
    enginePct: round.engineImprovementPct ?? null,
    pairedPct: round.pairedCandidateImprovementMedianPct ?? null,
    winRate: round.pairedCandidateWinRate ?? null,
    failures: report.strictEvidenceFailures ?? [],
    promotionFailures: report.promotionFailures ?? [],
    evidenceQuality: report.evidenceQuality ?? null,
    identityControl: report.identityControl
      ? {
          samples: report.identityControl.samples ?? null,
          attemptsRequested: report.identityControl.attemptsRequested ?? null,
          attemptsRun: report.identityControl.attemptsRun ?? null,
          selectedAttempt: report.identityControl.selectedAttempt ?? null,
          attemptSelection: report.identityControl.attemptSelection ?? null,
          attemptSummaries: report.identityControl.attemptSummaries ?? null,
          medianDeltaPct: report.identityControl.medianDeltaPct ?? null,
          diagnostics: report.identityControl.diagnostics ?? null,
          pairedWinRate: report.identityControl.pairedEngine?.candidateWinRate ?? null,
          matchParity: report.identityControl.matchParity ?? null,
          routeParity: report.identityControl.routeParity ?? null,
          firstEngineMedianMs: report.identityControl.first?.engineSummary?.median ?? null,
          secondEngineMedianMs: report.identityControl.second?.engineSummary?.median ?? null,
          firstEngineRobustCvPct: report.identityControl.first?.engineSummary?.robustCvPct ?? null,
          secondEngineRobustCvPct: report.identityControl.second?.engineSummary?.robustCvPct ?? null,
        }
      : null,
    processScan: {
      beforeMatched: report.processScan?.before?.matched?.length ?? null,
      afterMatched: report.processScan?.after?.matched?.length ?? null,
      beforeFailures: report.processScan?.before?.failures ?? [],
      afterFailures: report.processScan?.after?.failures ?? [],
    },
    routeParityStatus: report.installedRepoComparison?.routeParityStatus ?? null,
    matchParity: report.installedRepoComparison?.matchParity ?? null,
    pairOrderSummary: report.installedRepoComparison?.pairOrderSummary ?? null,
    pairedEngine: report.installedRepoComparison?.pairedEngine
      ? {
          count: report.installedRepoComparison.pairedEngine.count ?? null,
          candidateWinRate: report.installedRepoComparison.pairedEngine.candidateWinRate ?? null,
          candidateImprovementPctSummary:
            report.installedRepoComparison.pairedEngine.candidateImprovementPctSummary ?? null,
          attribution: report.installedRepoComparison.pairedEngine.attribution ?? null,
        }
      : null,
  };
}

function runSnapshot(candidate, index) {
  const compareArgs = [
    COMPARE_SCRIPT,
    "--samples", String(samples),
    "--identity-control-samples", String(identityControlSamples),
    "--identity-control-attempts", String(identityControlAttempts),
    "--min-retainable-samples", String(minRetainableSamples),
    "--installed-ix", candidate.path,
    "--quiet",
  ];
  if (!childBenchmarkLock) compareArgs.push("--no-benchmark-lock");
  const started = Date.now();
  const child = spawnSync(process.execPath, compareArgs, {
    cwd: ROOT,
    encoding: "utf8",
    windowsHide: true,
  });
  const elapsedMs = Date.now() - started;
  if (child.status !== 0) {
    return {
      index,
      ...candidate,
      runnable: false,
      strict: false,
      status: "skipped",
      elapsedMs,
      error: child.stderr?.trim() || child.stdout?.trim() || `compare exited ${child.status}`,
    };
  }
  return {
    index,
    ...candidate,
    runnable: true,
    elapsedMs,
    ...readLatestInstalledSummary(),
  };
}

function roundRetainable(round) {
  return (
    round.runnable === true &&
    Number(round.enginePct) >= minEngineImprovementPct &&
    Number(round.pairedPct) >= minPairedImprovementPct &&
    (!requireStrict || round.strict === true)
  );
}

function classifyRoundFailure(round) {
  if (round.runnable !== true) return "skipped";
  const failures = [
    ...(round.failures ?? []),
    ...(round.promotionFailures ?? []),
  ].map(String);
  if (failures.some((failure) => failure.startsWith("identity_control"))) return "identity_control";
  if (failures.some((failure) => failure.startsWith("host:"))) return "host";
  if (failures.some((failure) => failure.startsWith("process_") || failure.startsWith("stale_processes"))) return "process";
  if (Number(round.enginePct) < minEngineImprovementPct) return "engine_target";
  if (Number(round.pairedPct) < minPairedImprovementPct) return "paired_target";
  if (requireStrict && round.strict !== true) return "strict_evidence";
  if (failures.length > 0) return "other";
  return "none";
}

function bestRetainableRound(rounds) {
  const retainableRounds = rounds.filter(roundRetainable);
  return [...retainableRounds].sort((left, right) =>
    Number(right.pairedPct) - Number(left.pairedPct) ||
    Number(right.enginePct) - Number(left.enginePct)
  )[0] ?? null;
}

function worstBlockingRound(rounds) {
  const blocked = rounds
    .filter((round) => round.runnable === true && !roundRetainable(round))
    .map((round) => ({
      label: round.label,
      status: round.status ?? null,
      category: classifyRoundFailure(round),
      enginePct: round.enginePct ?? null,
      pairedPct: round.pairedPct ?? null,
      strict: round.strict === true,
      failures: round.failures ?? [],
    }));
  return blocked.sort((left, right) =>
    Number(left.pairedPct ?? Number.POSITIVE_INFINITY) - Number(right.pairedPct ?? Number.POSITIVE_INFINITY) ||
    Number(left.enginePct ?? Number.POSITIVE_INFINITY) - Number(right.enginePct ?? Number.POSITIVE_INFINITY)
  )[0] ?? null;
}

function buildFailureSummary({ rounds, failures }) {
  const categoryCounts = {};
  for (const round of rounds) {
    const category = classifyRoundFailure(round);
    categoryCounts[category] = (categoryCounts[category] ?? 0) + 1;
  }
  const retainableLabels = rounds.filter(roundRetainable).map((round) => round.label);
  const blockedLabels = rounds
    .filter((round) => round.runnable === true && !roundRetainable(round))
    .map((round) => round.label);
  const skippedLabels = rounds
    .filter((round) => round.runnable !== true)
    .map((round) => round.label);
  const best = bestRetainableRound(rounds);
  return {
    categories: categoryCounts,
    retainableLabels,
    blockedLabels,
    skippedLabels,
    bestRetainableRound: best
      ? {
          label: best.label,
          enginePct: best.enginePct ?? null,
          pairedPct: best.pairedPct ?? null,
          winRate: best.winRate ?? null,
        }
      : null,
    worstBlockingRound: worstBlockingRound(rounds),
    topLevelFailures: failures,
  };
}

const candidates = snapshotCandidates();
if (dryRun) {
  for (const [index, candidate] of candidates.entries()) {
    console.log(`${index + 1}\t${candidate.mtimeIso}\t${candidate.bytes}\t${candidate.path}`);
  }
  process.exit(0);
}

mkdirSync(REPORT_DIR, { recursive: true });
const rounds = [];
let runnableCount = 0;
let retainableCount = 0;
for (const [index, candidate] of candidates.entries()) {
  if (!quiet) console.log(`[${index + 1}/${candidates.length}] ${candidate.label}`);
  const result = runSnapshot(candidate, index + 1);
  rounds.push(result);
  if (result.runnable) runnableCount += 1;
  if (roundRetainable(result)) retainableCount += 1;
  if (!quiet) {
    if (result.runnable) {
      console.log(`  ${result.status}: repo ${result.repoMedianMs} ms vs snapshot ${result.baselineMedianMs} ms; engine ${result.enginePct}% paired ${result.pairedPct}%`);
    } else {
      console.log(`  skipped: ${result.error}`);
    }
  }
  if (targetRetainableSnapshots !== Infinity) {
    if (retainableCount >= targetRetainableSnapshots) break;
  } else if (runnableCount >= maxSnapshots) {
    break;
  }
}

const runnable = rounds.filter((round) => round.runnable);
const retainable = rounds.filter(roundRetainable);
const failures = [];
if (runnable.length === 0) failures.push("no_runnable_snapshots");
if (targetRetainableSnapshots !== Infinity) {
  if (retainable.length < targetRetainableSnapshots) {
    failures.push(`retainable_snapshots_below_requested:${retainable.length}<${targetRetainableSnapshots}`);
  }
} else if (maxSnapshots !== Infinity && runnable.length < maxSnapshots) {
  failures.push(`runnable_snapshots_below_requested:${runnable.length}<${maxSnapshots}`);
}
for (const round of runnable) {
  if (round.enginePct < minEngineImprovementPct) failures.push(`engine_improvement_below_target:${round.label}:${round.enginePct}<${minEngineImprovementPct}`);
  if (round.pairedPct < minPairedImprovementPct) failures.push(`paired_improvement_below_target:${round.label}:${round.pairedPct}<${minPairedImprovementPct}`);
  if (requireStrict && round.strict !== true) failures.push(`strict_evidence_missing:${round.label}`);
}

const report = {
  runId: `older-snapshot-ladder-${timestampSlug()}`,
  generatedAt: new Date().toISOString(),
  baselineDir,
  samples,
  identityControlSamples,
  identityControlAttempts,
  minRetainableSamples,
  maxSnapshots: maxSnapshots === Infinity ? null : maxSnapshots,
  targetRetainableSnapshots: targetRetainableSnapshots === Infinity ? null : targetRetainableSnapshots,
  maxCandidates: maxCandidates === Infinity ? null : maxCandidates,
  minEngineImprovementPct,
  minPairedImprovementPct,
  sort: newestFirst ? "newest_first" : "oldest_first",
  candidateSnapshotsScanned: rounds.length,
  runnableSnapshots: runnable.length,
  retainableSnapshots: retainable.length,
  nonRetainableRunnableSnapshots: runnable.length - retainable.length,
  skippedSnapshots: rounds.length - runnable.length,
  strictRequired: requireStrict,
  retainableEvidence: failures.length === 0,
  failures,
  failureSummary: buildFailureSummary({ rounds, failures }),
  rounds,
};

const reportPath = path.join(REPORT_DIR, `${report.runId}.json`);
writeFileSync(reportPath, `${JSON.stringify(report, null, 2)}\n`);
mkdirSync(path.dirname(latestPath), { recursive: true });
writeFileSync(latestPath, `${JSON.stringify(report, null, 2)}\n`);

if (!quiet) {
  console.log(`Report: ${reportPath}`);
  console.log(`Retainable evidence: ${report.retainableEvidence}`);
}
if (failures.length > 0) process.exit(1);
