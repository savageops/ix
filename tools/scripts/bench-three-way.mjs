#!/usr/bin/env node
// Fair three-way paired benchmark: repo vs installed vs June predecessor.
// Uses the ripgrep benchsuite linux corpus (6.6 GB).
// Alternates binary order per query to neutralize page-cache bias.
// Records match counts for parity verification.

import { execFileSync } from "node:child_process";
import { performance } from "node:perf_hooks";

const CORPUS = "E:/Workspaces/01_Projects/01_Github/iEx/.refs/ripgrep/benchsuite/linux";

const REPO = "./zig-out/bin/ix-zig.exe";
const INSTALLED = "C:/Users/Savage/AppData/ix/ix.exe";
const JUNE = ".docs/reports/bin/ix-zig-before-long-literal-anomaly-20260704-154546.exe";

// Diverse random query shapes covering different strategy paths.
// Each query has separate expressions for current (lit:/re:) and June (bare).
const QUERIES = [
  {
    name: "short-literal-7ch",
    current: "lit:struct",
    june: "struct",
    desc: "Short common literal, high hit count, literal scan path",
  },
  {
    name: "medium-literal-13ch",
    current: "lit:EXPORT_SYMBOL",
    june: "EXPORT_SYMBOL",
    desc: "Medium literal, the canonical bench query from prior passes",
  },
  {
    name: "long-literal-22ch",
    current: "lit:DEFINE_MUTEX_nodefs",
    june: "DEFINE_MUTEX_nodefs",
    desc: "Long literal, rare, tests long-pattern fast path",
  },
  {
    name: "rare-literal-19ch",
    current: "lit:schedule_mmio_read",
    june: "schedule_mmio_read",
    desc: "Rare literal, tests discovery-to-scan ratio",
  },
  {
    name: "case-insensitive-12ch",
    current: "lit:iMODULE_INIT",
    june: "iMODULE_INIT",
    desc: "Case-insensitive literal, tests casefold path",
  },
  {
    name: "regex-char-class",
    current: "re:spin_[a-z]_init",
    june: "re:spin_[a-z]_init",
    desc: "Regex with character class, tests regex engine",
  },
  {
    name: "regex-alternation",
    current: "re:(ERR_SYS|PME_TURN_OFF|LINK_REQ_RST)",
    june: "re:(ERR_SYS|PME_TURN_OFF|LINK_REQ_RST)",
    desc: "Regex alternation, the canonical alternates bench query",
  },
  {
    name: "regex-anchor",
    current: "re:^#define\\s+CONFIG",
    june: "re:^#define\\s+CONFIG",
    desc: "Regex with anchor, tests line-start scan optimization",
  },
];

const ROUNDS = 3; // alternating order rounds per query

function runOnce(binary, expr, isJune) {
  const args = isJune
    ? ["matches", expr, CORPUS]
    : ["search", expr, CORPUS];
  try {
    const start = performance.now();
    const stdout = execFileSync(binary, args, {
      maxBuffer: 512 * 1024 * 1024,
      encoding: "utf8",
      timeout: 120000,
      windowsHide: true,
    });
    const elapsed = performance.now() - start;
    const matchCount = stdout.split("\n").filter((l) => l.length > 0 && !l.includes("ix.error")).length;
    return { elapsed, matchCount, error: null };
  } catch (e) {
    return { elapsed: null, matchCount: 0, error: e.message?.slice(0, 120) || "unknown" };
  }
}

function median(arr) {
  const sorted = [...arr].sort((a, b) => a - b);
  const mid = Math.floor(sorted.length / 2);
  return sorted.length % 2 === 0 ? (sorted[mid - 1] + sorted[mid]) / 2 : sorted[mid];
}

function min(arr) {
  return Math.min(...arr);
}

// Warm the page cache once before any timed runs.
console.log("Warming page cache (single untimed run)...");
runOnce(REPO, "lit:EXPORT_SYMBOL", false);
console.log("Cache warm.\n");

console.log("=".repeat(96));
console.log("IX Three-Way Speed Comparison — repo vs installed vs June predecessor");
console.log(`Corpus: ${CORPUS}`);
console.log(`Queries: ${QUERIES.length} | Rounds: ${ROUNDS} (alternating order)`);
console.log("=".repeat(96) + "\n");

const results = [];

for (const q of QUERIES) {
  const repoTimes = [];
  const installedTimes = [];
  const juneTimes = [];
  let repoMatches = 0;
  let installedMatches = 0;
  let juneMatches = 0;

  // Alternate order each round to neutralize cache effects.
  for (let round = 0; round < ROUNDS; round++) {
    const order = round % 2 === 0
      ? [["repo", REPO, false], ["installed", INSTALLED, false], ["june", JUNE, true]]
      : [["june", JUNE, true], ["installed", INSTALLED, false], ["repo", REPO, false]];

    for (const [label, binary, isJune] of order) {
      const expr = isJune ? q.june : q.current;
      const r = runOnce(binary, expr, isJune);
      if (label === "repo") {
        if (r.elapsed !== null) repoTimes.push(r.elapsed);
        repoMatches = r.matchCount;
      } else if (label === "installed") {
        if (r.elapsed !== null) installedTimes.push(r.elapsed);
        installedMatches = r.matchCount;
      } else {
        if (r.elapsed !== null) juneTimes.push(r.elapsed);
        juneMatches = r.matchCount;
      }
    }
  }

  const repoMed = median(repoTimes);
  const instMed = median(installedTimes);
  const juneMed = median(juneTimes);
  const repoMin = min(repoTimes);
  const instMin = min(installedTimes);
  const juneMin = min(juneTimes);

  results.push({
    name: q.name,
    desc: q.desc,
    repoMed, instMed, juneMed,
    repoMin, instMin, juneMin,
    repoMatches, installedMatches, juneMatches,
  });

  const parity = (repoMatches === installedMatches && installedMatches === juneMatches) ? "✓" : "✗";
  console.log(`[${q.name}] ${q.desc}`);
  console.log(`  matches: repo=${repoMatches} installed=${installedMatches} june=${juneMatches} ${parity}`);
  console.log(`  median:  repo=${repoMed.toFixed(0)}ms  installed=${instMed.toFixed(0)}ms  june=${juneMed.toFixed(0)}ms`);
  if (juneMed > 0) {
    console.log(`  vs June: repo=${(juneMed / repoMed).toFixed(2)}x  installed=${(juneMed / instMed).toFixed(2)}x`);
  }
  console.log();
}

// Summary table
console.log("=".repeat(96));
console.log("SUMMARY (median ms, lower is faster)");
console.log("=".repeat(96));
console.log("Query".padEnd(28) + "Repo".padStart(12) + "Installed".padStart(12) + "June".padStart(12) + "Repo/June".padStart(12));
console.log("-".repeat(96));
for (const r of results) {
  const ratio = r.juneMed > 0 ? `${(r.juneMed / r.repoMed).toFixed(2)}x` : "—";
  console.log(
    r.name.padEnd(28) +
    r.repoMed.toFixed(0).padStart(12) +
    r.instMed.toFixed(0).padStart(12) +
    r.juneMed.toFixed(0).padStart(12) +
    ratio.padStart(12)
  );
}

// Aggregate
const repoSum = results.reduce((s, r) => s + r.repoMed, 0);
const instSum = results.reduce((s, r) => s + r.instMed, 0);
const juneSum = results.reduce((s, r) => s + r.juneMed, 0);
console.log("-".repeat(96));
console.log(
  "TOTAL".padEnd(28) +
  repoSum.toFixed(0).padStart(12) +
  instSum.toFixed(0).padStart(12) +
  juneSum.toFixed(0).padStart(12) +
  (juneSum > 0 ? `${(juneSum / repoSum).toFixed(2)}x`.padStart(12) : "—".padStart(12))
);
console.log();
