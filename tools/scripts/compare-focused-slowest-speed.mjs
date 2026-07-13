import { existsSync, mkdirSync, readFileSync, readdirSync, statSync, writeFileSync } from "node:fs";
import { spawnSync } from "node:child_process";
import path from "node:path";
import { defaultInstalledIxPath, defaultRepoIxPath, DEFAULT_ALTERNATES_EXPRESSION } from "./lib/benchmark-config.mjs";
import { argValue, timestampSlug } from "./lib/script-helpers.mjs";

const ROOT = process.cwd();
const REPORT_DIR = path.join(ROOT, "tools", "reports", "focused-slowest-speed");
const MANUAL_REPORT_DIR = path.join(ROOT, "tools", "reports", "manual-speed-compare");
const DEFAULT_BACKUP = path.join(path.dirname(defaultInstalledIxPath()), "backups", "ix.exe.backup-2026-06-30T19-36-32-721Z");

const args = process.argv.slice(2);
if (args.includes("--help") || args.includes("-h")) {
  console.log(`Usage: node tools/scripts/compare-focused-slowest-speed.mjs [options]

Runs repeated installed-vs-repo comparisons against one slow file. This is a
diagnostic pre-gate for Teddy/scanFile work, not final promotion evidence.
Only retainable focused runs update latest-focused-slowest-speed.json;
underpowered smoke runs update latest-diagnostic-focused-slowest-speed.json.

Options:
  --corpus <path>                 Slow file path. Default: most common slowest file from recent reports.
  --rounds <n>                    Sequential compare-installed-speed rounds. Default: 3.
  --samples <n>                   Samples per round. Default: 12.
  --threads <n>                   IX/ripgrep thread count. Default: 32.
  --expression <expr>             Search expression. Default: alternates benchmark expression.
  --installed-ix <path>           Baseline IX binary. Default: June 30 native backup.
  --repo-ix <path>                Repo IX binary. Default: zig-out/bin/ix-zig.exe.
  --build                         Build repo IX ReleaseFast before each focused round.
  --quiet                         Do not print JSON.
  --help, -h                      Print this help.
`);
  process.exit(0);
}

const rounds = Number(argValue(args, "--rounds", "3"));
const samples = Number(argValue(args, "--samples", "12"));
const threads = Number(argValue(args, "--threads", "32"));
const expression = argValue(args, "--expression", DEFAULT_ALTERNATES_EXPRESSION);
const installedIx = argValue(args, "--installed-ix", DEFAULT_BACKUP);
const repoIx = argValue(args, "--repo-ix", defaultRepoIxPath(ROOT));
const corpus = argValue(args, "--corpus", selectSlowestCorpus());
const buildFirst = args.includes("--build");
const quiet = args.includes("--quiet");

if (!corpus || !existsSync(corpus)) throw new Error(`focused corpus not found: ${corpus}`);
if (!existsSync(installedIx)) throw new Error(`installed IX baseline not found: ${installedIx}`);
if (!existsSync(repoIx)) throw new Error(`repo IX binary not found: ${repoIx}`);
if (!Number.isFinite(rounds) || rounds < 1) throw new Error(`invalid --rounds: ${rounds}`);
if (!Number.isFinite(samples) || samples < 1) throw new Error(`invalid --samples: ${samples}`);

mkdirSync(REPORT_DIR, { recursive: true });

const runId = `focused-slowest-speed-${timestampSlug()}`;
const roundReports = [];
for (let round = 1; round <= rounds; round += 1) {
  const roundPath = path.join(REPORT_DIR, `${runId}-round-${round}.json`);
  const latestPath = path.join(REPORT_DIR, `${runId}-latest-round-${round}.json`);
  const result = spawnSync(process.execPath, [
    "tools/scripts/compare-installed-speed.mjs",
    "--installed-ix", installedIx,
    "--repo-ix", repoIx,
    "--corpus", corpus,
    "--expression", expression,
    "--samples", String(samples),
    "--threads", String(threads),
    "--identity-control-samples", String(Math.min(12, samples)),
    "--identity-control-attempts", "3",
    "--min-retainable-samples", String(samples),
    "--out", roundPath,
    "--latest-path", latestPath,
    "--no-require-strict",
    "--quiet",
    ...(buildFirst ? ["--build"] : []),
  ], {
    cwd: ROOT,
    env: process.env,
    encoding: "utf8",
    stdio: "pipe",
    maxBuffer: 128 * 1024 * 1024,
    windowsHide: true,
  });
  if (result.status !== 0) {
    throw new Error(`focused round ${round} failed with code ${result.status}\n${result.stderr}`);
  }
  roundReports.push({
    path: roundPath,
    report: JSON.parse(readFileSync(roundPath, "utf8")),
  });
}

const rows = roundReports.map(({ path: reportPath, report }, index) => {
  const score = report.roundLedger?.[0] ??
    report.roundLedger?.[0]?.score ??
    report.scorecard?.losingRounds?.[0] ??
    report.scorecard?.netPositiveRounds?.[0] ??
    report.scorecard?.strictCandidateRounds?.[0] ??
    {};
  const repoHash = report.binaries?.repo?.sha256 ?? null;
  const installedHash = report.binaries?.installed?.sha256 ?? null;
  const repoExecutableHash = report.binaries?.repo?.executableSha256 ?? null;
  const installedExecutableHash = report.binaries?.installed?.executableSha256 ?? null;
  return {
    round: index + 1,
    reportPath: path.relative(ROOT, reportPath),
    runId: report.runId ?? null,
    repoHash,
    installedHash,
    repoExecutableHash,
    installedExecutableHash,
    repoEngineImprovementPct: numberOrNull(score.repoEngineImprovementPct ?? score.engineImprovementPct),
    pairedRepoImprovementMedianPct: numberOrNull(score.pairedRepoImprovementMedianPct ?? score.pairedCandidateImprovementMedianPct),
    pairedRepoWinRate: numberOrNull(score.pairedRepoWinRate ?? score.pairedCandidateWinRate),
    pairedCandidateTeddyRangeImprovementMedianPct: numberOrNull(score.pairedCandidateTeddyRangeImprovementMedianPct),
    installedScanFileMedianMs: numberOrNull(score.installedScanFileMedianMs ?? score.baselineScanFileMedianMs),
    repoScanFileMedianMs: numberOrNull(score.repoScanFileMedianMs ?? score.candidateScanFileMedianMs),
    installedAlternateTeddyRangeElapsedNsMedian: numberOrNull(score.installedAlternateTeddyRangeElapsedNsMedian ?? score.baselineAlternateTeddyRangeElapsedNsMedian),
    repoAlternateTeddyRangeElapsedNsMedian: numberOrNull(score.repoAlternateTeddyRangeElapsedNsMedian ?? score.candidateAlternateTeddyRangeElapsedNsMedian),
    failures: report.promotionFailures ?? [],
  };
});

const experimentalFocusedEvidence = rows.some((row) =>
  row.failures.some((failure) => String(failure).startsWith("diagnostic_attribution_run_not_promotion_evidence")));
const retainableFocusedEvidence = rounds >= 3 && samples >= 12 && !experimentalFocusedEvidence;

const summary = {
  runId,
  timestamp: new Date().toISOString(),
  corpus,
  expression,
  installedIx,
  baselineKind: installedIx === DEFAULT_BACKUP ? "native_backup_2026_06_30" : "custom_installed_ix",
  repoIx,
  buildFirst,
  rounds,
  samples,
  evidenceQuality: retainableFocusedEvidence
    ? "retainable_focused"
    : (experimentalFocusedEvidence ? "diagnostic_experimental_env" : "diagnostic_smoke"),
  retainableFocusedEvidence,
  experimentalFocusedEvidence,
  latestPointerPolicy: retainableFocusedEvidence
    ? "updates latest-focused-slowest-speed.json"
    : "updates latest-diagnostic-focused-slowest-speed.json only",
  averages: {
    repoEngineImprovementPct: average(rows, "repoEngineImprovementPct"),
    pairedRepoImprovementMedianPct: average(rows, "pairedRepoImprovementMedianPct"),
    pairedRepoWinRate: average(rows, "pairedRepoWinRate"),
    pairedCandidateTeddyRangeImprovementMedianPct: average(rows, "pairedCandidateTeddyRangeImprovementMedianPct"),
    scanFileDeltaMs: averageDelta(rows, "repoScanFileMedianMs", "installedScanFileMedianMs"),
    teddyRangeDeltaNs: averageDelta(rows, "repoAlternateTeddyRangeElapsedNsMedian", "installedAlternateTeddyRangeElapsedNsMedian"),
  },
  binaryIdentity: summarizeBinaryIdentity(rows),
  failureSummary: summarizeFailures(rows),
  roundsDetail: rows,
};

const outPath = path.join(REPORT_DIR, `${runId}.json`);
writeFileSync(outPath, `${JSON.stringify(summary, null, 2)}\n`, "utf8");
const latestName = retainableFocusedEvidence
  ? "latest-focused-slowest-speed.json"
  : "latest-diagnostic-focused-slowest-speed.json";
writeFileSync(path.join(REPORT_DIR, latestName), `${JSON.stringify(summary, null, 2)}\n`, "utf8");

if (!quiet) console.log(JSON.stringify(summary, null, 2));

function numberOrNull(value) {
  const number = Number(value);
  return Number.isFinite(number) ? number : null;
}

function average(rows, key) {
  const values = rows.map((row) => row[key]).filter((value) => Number.isFinite(value));
  if (values.length === 0) return null;
  return values.reduce((sum, value) => sum + value, 0) / values.length;
}

function averageDelta(rows, rightKey, leftKey) {
  const values = rows
    .map((row) => Number.isFinite(row[rightKey]) && Number.isFinite(row[leftKey]) ? row[rightKey] - row[leftKey] : null)
    .filter((value) => Number.isFinite(value));
  if (values.length === 0) return null;
  return values.reduce((sum, value) => sum + value, 0) / values.length;
}

function summarizeBinaryIdentity(rows) {
  const unique = (key) => [...new Set(rows.map((row) => row[key]).filter(Boolean))];
  return {
    repoHashes: unique("repoHash"),
    installedHashes: unique("installedHash"),
    repoExecutableHashes: unique("repoExecutableHash"),
    installedExecutableHashes: unique("installedExecutableHash"),
    stableRepoBinary: unique("repoHash").length === 1 && unique("repoExecutableHash").length === 1,
    stableInstalledBinary: unique("installedHash").length === 1 && unique("installedExecutableHash").length === 1,
  };
}

function summarizeFailures(rows) {
  const counts = new Map();
  for (const row of rows) {
    for (const failure of row.failures ?? []) {
      const key = String(failure).split(":")[0];
      counts.set(key, (counts.get(key) ?? 0) + 1);
    }
  }
  return [...counts.entries()]
    .map(([id, count]) => ({ id, count }))
    .sort((left, right) => right.count - left.count || left.id.localeCompare(right.id));
}

function selectSlowestCorpus() {
  const counts = new Map();
  for (const report of recentJsonReports(MANUAL_REPORT_DIR, 80)) {
    collectSlowestPaths(report, counts);
  }
  const selected = [...counts.entries()]
    .filter(([file]) => existsSync(file) && statSync(file).isFile())
    .sort((left, right) => right[1] - left[1])[0]?.[0];
  if (selected) return selected;
  return null;
}

function recentJsonReports(dir, limit) {
  if (!existsSync(dir)) return [];
  return readdirSync(dir)
    .filter((name) => name.endsWith(".json"))
    .map((name) => ({ name, path: path.join(dir, name), mtimeMs: statSync(path.join(dir, name)).mtimeMs }))
    .sort((left, right) => right.mtimeMs - left.mtimeMs)
    .slice(0, limit)
    .flatMap((entry) => {
      try {
        return [JSON.parse(readFileSync(entry.path, "utf8"))];
      } catch {
        return [];
      }
    });
}

function collectSlowestPaths(report, counts) {
  const add = (file) => {
    if (typeof file === "string" && file.length > 0) counts.set(file, (counts.get(file) ?? 0) + 1);
  };
  for (const lane of Object.values(report.lanes ?? {})) {
    if (!lane) continue;
    const runs = Array.isArray(lane.runs) ? lane.runs : (Array.isArray(lane.samples) ? lane.samples : []);
    for (const run of runs) {
      add(run?.slowestPath);
      for (const slow of run?.slowestFiles ?? []) add(slow?.path);
    }
  }
  for (const comparison of report.comparisons ?? []) {
    for (const side of [comparison.current, comparison.historical]) {
      for (const sample of side?.samples ?? []) {
        add(sample?.slowestPath);
        for (const slow of sample?.slowestFiles ?? []) add(slow?.path);
      }
    }
  }
}
