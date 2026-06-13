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
  --max-snapshots <n>             Limit snapshots after mtime sort. Default: all.
  --latest-path <path>            Path for latest-report pointer. Default:
                                  tools/reports/older-snapshot-ladder/latest-older-snapshot-ladder.json.
  --newest-first                  Sort snapshots newest to oldest. Default: oldest first.
  --require-strict                Exit non-zero if any runnable snapshot lacks strict evidence.
  --dry-run                       Print selected snapshots and write no benchmark report.
  --quiet                         Suppress per-snapshot console summary.
  --help, -h                      Print this help.
`);
  process.exit(0);
}

const baselineDir = path.resolve(argValue(args, "--baseline-dir", DEFAULT_BASELINE_DIR));
const samples = Number(argValue(args, "--samples", "12"));
const identityControlSamples = Number(argValue(args, "--identity-control-samples", String(Math.min(12, samples))));
const maxSnapshotsRaw = argValue(args, "--max-snapshots", "");
const maxSnapshots = maxSnapshotsRaw === "" ? Infinity : Number(maxSnapshotsRaw);
const latestPath = path.resolve(argValue(args, "--latest-path", path.join(REPORT_DIR, "latest-older-snapshot-ladder.json")));
const newestFirst = args.includes("--newest-first");
const requireStrict = args.includes("--require-strict");
const dryRun = args.includes("--dry-run");
const quiet = args.includes("--quiet");

if (!existsSync(COMPARE_SCRIPT)) throw new Error(`compare script not found: ${COMPARE_SCRIPT}`);
if (!existsSync(baselineDir)) throw new Error(`baseline directory not found: ${baselineDir}`);
if (!Number.isFinite(samples) || samples < 1) throw new Error("--samples must be a positive number");
if (!Number.isFinite(identityControlSamples) || identityControlSamples < 0) throw new Error("--identity-control-samples must be a non-negative number");
if (maxSnapshots !== Infinity && (!Number.isFinite(maxSnapshots) || maxSnapshots < 1)) throw new Error("--max-snapshots must be a positive number");

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
  return candidates.slice(0, maxSnapshots);
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
    "--installed-ix", candidate.path,
    "--quiet",
  ];
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

const candidates = snapshotCandidates();
if (dryRun) {
  for (const [index, candidate] of candidates.entries()) {
    console.log(`${index + 1}\t${candidate.mtimeIso}\t${candidate.bytes}\t${candidate.path}`);
  }
  process.exit(0);
}

mkdirSync(REPORT_DIR, { recursive: true });
const rounds = [];
for (const [index, candidate] of candidates.entries()) {
  if (!quiet) console.log(`[${index + 1}/${candidates.length}] ${candidate.label}`);
  const result = runSnapshot(candidate, index + 1);
  rounds.push(result);
  if (!quiet) {
    if (result.runnable) {
      console.log(`  ${result.status}: repo ${result.repoMedianMs} ms vs snapshot ${result.baselineMedianMs} ms; engine ${result.enginePct}% paired ${result.pairedPct}%`);
    } else {
      console.log(`  skipped: ${result.error}`);
    }
  }
}

const runnable = rounds.filter((round) => round.runnable);
const failures = [];
if (runnable.length === 0) failures.push("no_runnable_snapshots");
for (const round of runnable) {
  if (round.enginePct < 0) failures.push(`engine_regression:${round.label}:${round.enginePct}`);
  if (round.pairedPct < 0) failures.push(`paired_regression:${round.label}:${round.pairedPct}`);
  if (requireStrict && round.strict !== true) failures.push(`strict_evidence_missing:${round.label}`);
}

const report = {
  runId: `older-snapshot-ladder-${timestampSlug()}`,
  generatedAt: new Date().toISOString(),
  baselineDir,
  samples,
  identityControlSamples,
  sort: newestFirst ? "newest_first" : "oldest_first",
  runnableSnapshots: runnable.length,
  skippedSnapshots: rounds.length - runnable.length,
  strictRequired: requireStrict,
  retainableEvidence: failures.length === 0,
  failures,
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
