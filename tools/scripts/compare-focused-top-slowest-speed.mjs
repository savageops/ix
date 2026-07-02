import { existsSync, mkdirSync, readFileSync, readdirSync, statSync, writeFileSync } from "node:fs";
import { spawnSync } from "node:child_process";
import path from "node:path";
import { DEFAULT_ALTERNATES_EXPRESSION } from "./lib/benchmark-config.mjs";
import { argValue, timestampSlug } from "./lib/script-helpers.mjs";

const ROOT = process.cwd();
const FOCUSED_REPORT_DIR = path.join(ROOT, "tools", "reports", "focused-slowest-speed");
const REPORT_DIR = path.join(ROOT, "tools", "reports", "focused-top-slowest-speed");
const MANUAL_REPORT_DIR = path.join(ROOT, "tools", "reports", "manual-speed-compare");
const HISTORICAL_REPORT_DIR = path.join(ROOT, "tools", "reports", "historical-speed");

const args = process.argv.slice(2);
if (args.includes("--help") || args.includes("-h")) {
  console.log(`Usage: node tools/scripts/compare-focused-top-slowest-speed.mjs [options]

Runs compare-focused-slowest-speed.mjs over the top slowest files seen in
recent installed/historical reports. Diagnostic attribution only; final
promotion still requires the full installed, predecessor, and older-snapshot
speed gates.

Options:
  --top <n>                      Number of slow files. Default: 4.
  --rounds <n>                   Focused rounds per file. Default: 3.
  --samples <n>                  Samples per round. Default: 12.
  --threads <n>                  IX/ripgrep thread count. Default: 32.
  --expression <expr>            Search expression. Default: alternates benchmark expression.
  --quiet                        Do not print JSON.
  --help, -h                     Print this help.
`);
  process.exit(0);
}

const top = Number(argValue(args, "--top", "4"));
const rounds = Number(argValue(args, "--rounds", "3"));
const samples = Number(argValue(args, "--samples", "12"));
const threads = Number(argValue(args, "--threads", "32"));
const expression = argValue(args, "--expression", DEFAULT_ALTERNATES_EXPRESSION);
const quiet = args.includes("--quiet");

if (!Number.isFinite(top) || top < 1) throw new Error(`invalid --top: ${top}`);
if (!Number.isFinite(rounds) || rounds < 1) throw new Error(`invalid --rounds: ${rounds}`);
if (!Number.isFinite(samples) || samples < 1) throw new Error(`invalid --samples: ${samples}`);

mkdirSync(REPORT_DIR, { recursive: true });

const selected = selectSlowestCorpora(top);
if (selected.length === 0) throw new Error("no slowest file corpus candidates found");

const runId = `focused-top-slowest-speed-${timestampSlug()}`;
const rows = [];
for (const [index, entry] of selected.entries()) {
  const beforeRun = latestFocusedSummaryMtime();
  const result = spawnSync(process.execPath, [
    "tools/scripts/compare-focused-slowest-speed.mjs",
    "--corpus", entry.path,
    "--expression", expression,
    "--rounds", String(rounds),
    "--samples", String(samples),
    "--threads", String(threads),
    "--quiet",
  ], {
    cwd: ROOT,
    env: process.env,
    encoding: "utf8",
    stdio: "pipe",
    maxBuffer: 128 * 1024 * 1024,
    windowsHide: true,
  });
  if (result.status !== 0) {
    throw new Error(`focused top slowest file ${index + 1} failed: ${entry.path}\n${result.stderr}`);
  }
  const focusedPath = latestFocusedSummaryPathAfter(beforeRun);
  if (focusedPath == null) throw new Error(`focused child did not write a summary for ${entry.path}`);
  const focused = JSON.parse(readFileSync(focusedPath, "utf8"));
  rows.push({
    rank: index + 1,
    corpus: entry.path,
    sourceCount: entry.count,
    reportPath: path.relative(ROOT, focusedPath),
    runId: focused.runId ?? null,
    retainableFocusedEvidence: focused.retainableFocusedEvidence === true,
    experimentalFocusedEvidence: focused.experimentalFocusedEvidence === true,
    repoHash: focused.binaryIdentity?.repoHashes?.[0] ?? null,
    repoEngineImprovementPct: numberOrNull(focused.averages?.repoEngineImprovementPct),
    pairedRepoImprovementMedianPct: numberOrNull(focused.averages?.pairedRepoImprovementMedianPct),
    pairedRepoWinRate: numberOrNull(focused.averages?.pairedRepoWinRate),
    pairedCandidateTeddyRangeImprovementMedianPct: numberOrNull(focused.averages?.pairedCandidateTeddyRangeImprovementMedianPct),
    scanFileDeltaMs: numberOrNull(focused.averages?.scanFileDeltaMs),
    teddyRangeDeltaNs: numberOrNull(focused.averages?.teddyRangeDeltaNs),
    failureSummary: focused.failureSummary ?? [],
  });
}

const summary = {
  runId,
  timestamp: new Date().toISOString(),
  top,
  rounds,
  samples,
  threads,
  expression,
  selected,
  averages: {
    repoEngineImprovementPct: average(rows, "repoEngineImprovementPct"),
    pairedRepoImprovementMedianPct: average(rows, "pairedRepoImprovementMedianPct"),
    pairedRepoWinRate: average(rows, "pairedRepoWinRate"),
    pairedCandidateTeddyRangeImprovementMedianPct: average(rows, "pairedCandidateTeddyRangeImprovementMedianPct"),
    scanFileDeltaMs: average(rows, "scanFileDeltaMs"),
    teddyRangeDeltaNs: average(rows, "teddyRangeDeltaNs"),
  },
  negativeCounts: {
    engine: rows.filter((row) => Number(row.repoEngineImprovementPct) < 0).length,
    pairedEngine: rows.filter((row) => Number(row.pairedRepoImprovementMedianPct) < 0).length,
    teddy: rows.filter((row) => Number(row.pairedCandidateTeddyRangeImprovementMedianPct) < 0).length,
  },
  rows,
};

const outPath = path.join(REPORT_DIR, `${runId}.json`);
writeFileSync(outPath, `${JSON.stringify(summary, null, 2)}\n`, "utf8");
writeFileSync(path.join(REPORT_DIR, "latest-focused-top-slowest-speed.json"), `${JSON.stringify(summary, null, 2)}\n`, "utf8");

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

function selectSlowestCorpora(limit) {
  const counts = new Map();
  for (const report of [...recentJsonReports(MANUAL_REPORT_DIR, 80), ...recentJsonReports(HISTORICAL_REPORT_DIR, 80)]) {
    collectSlowestPaths(report, counts);
  }
  return [...counts.entries()]
    .filter(([file]) => existsSync(file) && statSync(file).isFile())
    .sort((left, right) => right[1] - left[1] || left[0].localeCompare(right[0]))
    .slice(0, limit)
    .map(([file, count]) => ({ path: file, count }));
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
  const add = (file, weight = 1) => {
    if (typeof file === "string" && file.length > 0) counts.set(file, (counts.get(file) ?? 0) + weight);
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
  for (const round of report.roundLedger ?? []) {
    for (const item of round.baselineSlowestPathTop ?? []) add(item.value, Number(item.count) || 1);
    for (const item of round.candidateSlowestPathTop ?? []) add(item.value, Number(item.count) || 1);
  }
}

function latestFocusedSummaryMtime() {
  const latest = latestFocusedSummaryPathAfter(-Infinity);
  return latest == null ? -Infinity : statSync(latest).mtimeMs;
}

function latestFocusedSummaryPathAfter(afterMtimeMs) {
  if (!existsSync(FOCUSED_REPORT_DIR)) return null;
  return readdirSync(FOCUSED_REPORT_DIR)
    .filter((name) => /^focused-slowest-speed-.*\.json$/.test(name) && !/-round-/.test(name) && !/-latest-round-/.test(name))
    .map((name) => ({ path: path.join(FOCUSED_REPORT_DIR, name), mtimeMs: statSync(path.join(FOCUSED_REPORT_DIR, name)).mtimeMs }))
    .filter((entry) => entry.mtimeMs > afterMtimeMs)
    .sort((left, right) => right.mtimeMs - left.mtimeMs)
    [0]?.path ?? null;
}
