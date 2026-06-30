import { createHash } from "node:crypto";
import { spawnSync } from "node:child_process";
import { existsSync, mkdirSync, readFileSync, readdirSync, rmSync, statSync, writeFileSync } from "node:fs";
import os from "node:os";
import path from "node:path";
import { pairedAttributionLedgerFields, pairedEngineStats, phaseTimingResidualMs } from "./benchmark-phase-attribution.mjs";
import { identityNoiseDiagnostics } from "./benchmark-noise-diagnostics.mjs";
export { pairedAttributionLedgerFields, pairedEngineStats, phaseLeakSummaryFromRounds, phaseTimingResidualMs } from "./benchmark-phase-attribution.mjs";
export { identityNoiseDiagnostics } from "./benchmark-noise-diagnostics.mjs";

export const DEFAULT_ALTERNATES_EXPR = "re:(?i)(ERR_SYS|PME_TURN_OFF|LINK_REQ_RST|CFG_BME_EVT)";
const DEFAULT_BENCHMARK_LOCK_DIR = path.join(os.tmpdir(), "ix-zig-benchmark.lock");
const DEFAULT_STALE_BENCHMARK_LOCK_MS = 6 * 60 * 60 * 1000;
const BENCHMARK_ENV_SNAPSHOT_KEYS = [
  "IX_INDEX",
  "IX_NEXUS",
  "IX_STATE_DIR",
  "IX_SCAN_OPEN_TIMING",
  "IX_TEDDY_FINGERPRINT_OFFSET",
  "IX_TEDDY_RANGE_FINGERPRINT_OFFSET",
  "IX_LITERAL_ALTERNATES_COUNTER_CACHE",
  "IX_BLOCK_PRUNING_PROOF",
  "IX_IDENTITY_CONTROL_ATTEMPTS",
  "IX_MIN_RETAINABLE_SPEED_SAMPLES",
  "IX_MIN_INSTALLED_IMPROVEMENT_PCT",
  "IX_MIN_PREVIOUS_BUILD_IMPROVEMENT_PCT",
  "IX_MIN_OLDER_SNAPSHOT_ENGINE_PCT",
  "IX_MIN_OLDER_SNAPSHOT_PAIRED_PCT",
  "IX_IDENTITY_NOISE_MULTIPLIER",
];

export function benchmarkEnvSnapshot(env = {}) {
  const effectiveEnv = { ...process.env, ...env };
  return Object.fromEntries(BENCHMARK_ENV_SNAPSHOT_KEYS.map((key) => [key, effectiveEnv[key] ?? null]));
}

export function dependencyTreeSnapshot(root = process.cwd()) {
  return {
    stringzilla: dependencyTreeHash(path.join(root, ".refs", "stringzilla")),
    pcre2: dependencyTreeHash(path.join(root, ".refs", "pcre2")),
  };
}

function dependencyTreeHash(root) {
  if (!existsSync(root)) return { path: root, exists: false, fileCount: 0, sha256: null };
  const hash = createHash("sha256");
  let fileCount = 0;
  function walk(dir) {
    for (const name of readdirSync(dir).sort()) {
      const entryPath = path.join(dir, name);
      const stat = statSync(entryPath);
      if (stat.isDirectory()) {
        walk(entryPath);
        continue;
      }
      const relative = path.relative(root, entryPath).replaceAll("\\", "/");
      hash.update(relative);
      hash.update("\0");
      hash.update(readFileSync(entryPath));
      hash.update("\0");
      fileCount += 1;
    }
  }
  walk(root);
  return {
    path: root,
    exists: true,
    fileCount,
    sha256: hash.digest("hex").toUpperCase(),
  };
}

export function run(command, commandArgs, options = {}) {
  const started = process.hrtime.bigint();
  const env = options.env ? { ...process.env, ...options.env } : process.env;
  const result = spawnSync(command, commandArgs, {
    cwd: options.cwd ?? process.cwd(),
    encoding: "utf8",
    env,
    maxBuffer: options.maxBuffer ?? 128 * 1024 * 1024,
    windowsHide: true,
  });
  return {
    command: [command, ...commandArgs].join(" "),
    exitCode: result.status ?? 0,
    stdout: result.stdout ?? "",
    stderr: result.stderr ?? "",
    durationMs: Number(process.hrtime.bigint() - started) / 1_000_000,
  };
}

export function requireOk(result, label) {
  if (result.exitCode !== 0) {
    throw new Error(`${label} failed (${result.exitCode}): ${result.stderr || result.stdout}`);
  }
  return result;
}

function processIsAlive(pid) {
  if (!Number.isInteger(pid) || pid <= 0) return false;
  try {
    process.kill(pid, 0);
    return true;
  } catch {
    return false;
  }
}

function readBenchmarkLockOwner(lockDir) {
  try {
    return JSON.parse(readFileSync(path.join(lockDir, "owner.json"), "utf8"));
  } catch {
    return null;
  }
}

function benchmarkLockAgeMs(lockDir) {
  try {
    return Date.now() - statSync(lockDir).mtimeMs;
  } catch {
    return null;
  }
}

function reclaimStaleBenchmarkLock(lockDir, { staleLockMs }) {
  const owner = readBenchmarkLockOwner(lockDir);
  const ownerPid = Number(owner?.pid);
  if (Number.isInteger(ownerPid) && ownerPid > 0) {
    if (processIsAlive(ownerPid)) return { reclaimed: false, owner, reason: "owner_pid_alive" };
    rmSync(lockDir, { recursive: true, force: true });
    return { reclaimed: true, owner, reason: "owner_pid_not_alive" };
  }

  const ageMs = benchmarkLockAgeMs(lockDir);
  if (Number.isFinite(ageMs) && ageMs > staleLockMs) {
    rmSync(lockDir, { recursive: true, force: true });
    return { reclaimed: true, owner, reason: "owner_missing_or_invalid_and_stale" };
  }
  return { reclaimed: false, owner, reason: "owner_missing_or_invalid" };
}

export function acquireBenchmarkLock({
  lockDir = process.env.IX_BENCHMARK_LOCK_DIR ?? DEFAULT_BENCHMARK_LOCK_DIR,
  script = path.basename(process.argv[1] ?? "unknown"),
  staleLockMs = Number(process.env.IX_BENCHMARK_LOCK_STALE_MS ?? DEFAULT_STALE_BENCHMARK_LOCK_MS),
} = {}) {
  try {
    mkdirSync(lockDir);
  } catch (err) {
    if (err?.code === "EEXIST") {
      const reclaim = reclaimStaleBenchmarkLock(lockDir, {
        staleLockMs: Number.isFinite(staleLockMs) && staleLockMs >= 0 ? staleLockMs : DEFAULT_STALE_BENCHMARK_LOCK_MS,
      });
      if (!reclaim.reclaimed) {
        const ownerText = reclaim.owner ? ` owner=${JSON.stringify(reclaim.owner)}` : "";
        throw new Error(`benchmark lock already held at ${lockDir}; reason=${reclaim.reason}; another IX benchmark may be running${ownerText}`);
      }
      mkdirSync(lockDir);
    } else {
      throw err;
    }
  }

  const owner = {
    pid: process.pid,
    script,
    cwd: process.cwd(),
    hostname: os.hostname(),
    startedAt: new Date().toISOString(),
  };
  writeFileSync(path.join(lockDir, "owner.json"), `${JSON.stringify(owner, null, 2)}\n`, "utf8");

  let released = false;
  const release = () => {
    if (released) return;
    released = true;
    try {
      rmSync(lockDir, { recursive: true, force: true });
    } catch {}
  };
  process.once("exit", release);
  process.once("SIGINT", () => {
    release();
    process.exit(130);
  });
  process.once("SIGTERM", () => {
    release();
    process.exit(143);
  });
  return { lockDir, release };
}

function percentile(sorted, p) {
  const index = Math.min(sorted.length - 1, Math.max(0, Math.ceil((p / 100) * sorted.length) - 1));
  return sorted[index];
}

export function summary(values) {
  const sorted = [...values].sort((left, right) => left - right);
  const mean = values.reduce((sum, value) => sum + value, 0) / values.length;
  const variance = values.reduce((sum, value) => sum + (value - mean) ** 2, 0) / values.length;
  return {
    count: values.length,
    min: sorted[0],
    p25: percentile(sorted, 25),
    median: percentile(sorted, 50),
    p75: percentile(sorted, 75),
    max: sorted[sorted.length - 1],
    mean,
    stdev: Math.sqrt(variance),
    range: sorted[sorted.length - 1] - sorted[0],
  };
}

function optionalSummary(values) {
  const finite = finiteNumbers(values);
  return finite.length === 0 ? null : summary(finite);
}

function finiteNumbers(values) {
  return values
    .filter((value) => value != null)
    .map(Number)
    .filter(Number.isFinite);
}

function topCounts(values, limit = 8) {
  const counts = new Map();
  for (const value of values) {
    if (value == null || value === "") continue;
    counts.set(value, (counts.get(value) ?? 0) + 1);
  }
  return [...counts.entries()]
    .sort((left, right) => right[1] - left[1] || String(left[0]).localeCompare(String(right[0])))
    .slice(0, limit)
    .map(([value, count]) => ({ value, count }));
}

function optionalNumber(value) {
  if (value == null) return null;
  const number = Number(value);
  return Number.isFinite(number) ? number : null;
}

function msPerFile(totalMs, filesScanned) {
  const total = Number(totalMs);
  const files = Number(filesScanned);
  if (!Number.isFinite(total) || !Number.isFinite(files) || files <= 0) return null;
  return total / files;
}

export function pairOrderSummary(pairOrder, { firstLabel, secondLabel } = {}) {
  if (!Array.isArray(pairOrder)) {
    return {
      count: 0,
      firstLabel: firstLabel ?? null,
      secondLabel: secondLabel ?? null,
      firstStarts: 0,
      secondStarts: 0,
      alternating: false,
      balanced: false,
    };
  }
  let firstStarts = 0;
  let secondStarts = 0;
  let alternating = pairOrder.length > 0;
  for (let index = 0; index < pairOrder.length; index += 1) {
    const expectedFirst = index % 2 === 0 ? firstLabel : secondLabel;
    const expectedSecond = index % 2 === 0 ? secondLabel : firstLabel;
    const expected = `${expectedFirst},${expectedSecond}`;
    if (pairOrder[index] !== expected) alternating = false;
    if (String(pairOrder[index]).startsWith(`${firstLabel},`)) firstStarts += 1;
    if (String(pairOrder[index]).startsWith(`${secondLabel},`)) secondStarts += 1;
  }
  return {
    count: pairOrder.length,
    firstLabel,
    secondLabel,
    firstStarts,
    secondStarts,
    alternating,
    balanced: alternating && Math.abs(firstStarts - secondStarts) <= 1,
  };
}

export function pairOrderSummaryIsBalanced(summaryValue, expectedCount = null) {
  if (summaryValue == null || typeof summaryValue !== "object" || Array.isArray(summaryValue)) return false;
  if (expectedCount != null && Number(summaryValue.count) !== Number(expectedCount)) return false;
  return summaryValue.alternating === true && summaryValue.balanced === true;
}

function pairOrderScoreFields(summaryValue) {
  if (summaryValue == null || typeof summaryValue !== "object" || Array.isArray(summaryValue)) return {};
  return {
    pairOrderBalanced: summaryValue.balanced === true,
    pairOrderAlternating: summaryValue.alternating === true,
    pairOrderFirstStarts: Number(summaryValue.firstStarts),
    pairOrderSecondStarts: Number(summaryValue.secondStarts),
  };
}

function routeValuesAreObserved(values) {
  return Array.isArray(values) && values.some((value) => Number(value) !== 0);
}

function routeSummaryObserved(summaryValue) {
  if (summaryValue == null || typeof summaryValue !== "object" || Array.isArray(summaryValue)) return false;
  return (
    routeValuesAreObserved(summaryValue.fullScan) ||
    routeValuesAreObserved(summaryValue.teddy) ||
    routeValuesAreObserved(summaryValue.pcre) ||
    routeValuesAreObserved(summaryValue.compiled)
  );
}

export function routeSummaryForLane(lane) {
  return {
    fullScan: lane?.alternateFullScanCalls ?? [],
    teddy: lane?.alternateTeddyRangeCalls ?? [],
    pcre: lane?.alternatePcreRangeCalls ?? [],
    compiled: lane?.alternateCompiledRangeCalls ?? [],
  };
}

export function routeParityEvaluation(baselineLane, candidateLane) {
  const baselineRoute = routeSummaryForLane(baselineLane);
  const candidateRoute = routeSummaryForLane(candidateLane);
  const baselineObserved = routeSummaryObserved(baselineRoute);
  const candidateObserved = routeSummaryObserved(candidateRoute);
  const comparable = baselineObserved && candidateObserved;
  const parity = comparable ? JSON.stringify(baselineRoute) === JSON.stringify(candidateRoute) : null;
  const status = comparable
    ? (parity ? "matched" : "mismatch")
    : (!baselineObserved && candidateObserved
        ? "baseline_unsupported"
        : (baselineObserved && !candidateObserved ? "candidate_unsupported" : "both_unsupported"));
  return {
    baselineRoute,
    candidateRoute,
    baselineObserved,
    candidateObserved,
    comparable,
    parity,
    status,
    acceptable: parity === true || status === "baseline_unsupported",
  };
}

function routeTimingMedianFields(baseline, candidate) {
  return {
    baselineAlternateFullScanCallsMedian: baseline?.alternateFullScanCallsSummary?.median ?? null,
    candidateAlternateFullScanCallsMedian: candidate?.alternateFullScanCallsSummary?.median ?? null,
    baselineAlternateFullScanBytesMedian: baseline?.alternateFullScanBytesSummary?.median ?? null,
    candidateAlternateFullScanBytesMedian: candidate?.alternateFullScanBytesSummary?.median ?? null,
    baselineAlternateFullScanMatchesMedian: baseline?.alternateFullScanMatchesSummary?.median ?? null,
    candidateAlternateFullScanMatchesMedian: candidate?.alternateFullScanMatchesSummary?.median ?? null,
    baselineAlternateFullScanElapsedNsMedian: baseline?.alternateFullScanElapsedNsTotalSummary?.median ?? null,
    candidateAlternateFullScanElapsedNsMedian: candidate?.alternateFullScanElapsedNsTotalSummary?.median ?? null,
    baselineAlternatePcreRangeElapsedNsMedian: baseline?.alternatePcreRangeElapsedNsTotalSummary?.median ?? null,
    candidateAlternatePcreRangeElapsedNsMedian: candidate?.alternatePcreRangeElapsedNsTotalSummary?.median ?? null,
    baselineAlternateTeddyRangeElapsedNsMedian: baseline?.alternateTeddyRangeElapsedNsTotalSummary?.median ?? null,
    candidateAlternateTeddyRangeElapsedNsMedian: candidate?.alternateTeddyRangeElapsedNsTotalSummary?.median ?? null,
    baselineAlternateCompiledRangeElapsedNsMedian: baseline?.alternateCompiledRangeElapsedNsTotalSummary?.median ?? null,
    candidateAlternateCompiledRangeElapsedNsMedian: candidate?.alternateCompiledRangeElapsedNsTotalSummary?.median ?? null,
  };
}

function stageTimingMedianFields(baseline, candidate) {
  const baselineFilesScanned = Array.isArray(baseline?.filesScanned) ? baseline.filesScanned : null;
  const candidateFilesScanned = Array.isArray(candidate?.filesScanned) ? candidate.filesScanned : null;
  const filesScannedParity = baselineFilesScanned != null && candidateFilesScanned != null
    ? JSON.stringify(baselineFilesScanned) === JSON.stringify(candidateFilesScanned)
    : null;
  return {
    baselineDiscoverMedianMs: baseline?.discoverSummary?.median ?? null,
    candidateDiscoverMedianMs: candidate?.discoverSummary?.median ?? null,
    baselineScanMedianMs: baseline?.scanSummary?.median ?? null,
    candidateScanMedianMs: candidate?.scanSummary?.median ?? null,
    baselineAggregateMedianMs: baseline?.aggregateSummary?.median ?? null,
    candidateAggregateMedianMs: candidate?.aggregateSummary?.median ?? null,
    baselineEngineResidualMedianMs: baseline?.engineResidualSummary?.median ?? null,
    candidateEngineResidualMedianMs: candidate?.engineResidualSummary?.median ?? null,
    baselineScanWorkMedianMs: baseline?.scanWorkSummary?.median ?? null,
    candidateScanWorkMedianMs: candidate?.scanWorkSummary?.median ?? null,
    baselineScanOpenMedianMs: baseline?.scanOpenSummary?.median ?? null,
    candidateScanOpenMedianMs: candidate?.scanOpenSummary?.median ?? null,
    baselineScanFileMedianMs: baseline?.scanFileSummary?.median ?? null,
    candidateScanFileMedianMs: candidate?.scanFileSummary?.median ?? null,
    baselineScanFileMmapMedianMs: baseline?.scanFileMmapSummary?.median ?? null,
    candidateScanFileMmapMedianMs: candidate?.scanFileMmapSummary?.median ?? null,
    baselineScanFileFastCountMedianMs: baseline?.scanFileFastCountSummary?.median ?? null,
    candidateScanFileFastCountMedianMs: candidate?.scanFileFastCountSummary?.median ?? null,
    baselineScanFileLineScanMedianMs: baseline?.scanFileLineScanSummary?.median ?? null,
    candidateScanFileLineScanMedianMs: candidate?.scanFileLineScanSummary?.median ?? null,
    baselineScanOpenMsPerFileMedian: baseline?.scanOpenMsPerFileSummary?.median ?? null,
    candidateScanOpenMsPerFileMedian: candidate?.scanOpenMsPerFileSummary?.median ?? null,
    baselineScanFileMsPerFileMedian: baseline?.scanFileMsPerFileSummary?.median ?? null,
    candidateScanFileMsPerFileMedian: candidate?.scanFileMsPerFileSummary?.median ?? null,
    baselineFilesScanned,
    candidateFilesScanned,
    filesScannedParity,
    baselineSlowestFileMedianMs: baseline?.slowestMsSummary?.median ?? null,
    candidateSlowestFileMedianMs: candidate?.slowestMsSummary?.median ?? null,
    baselineSlowestFileMedianBytes: baseline?.slowestBytesSummary?.median ?? null,
    candidateSlowestFileMedianBytes: candidate?.slowestBytesSummary?.median ?? null,
    baselineSlowestPathTop: baseline?.slowestPathTop ?? [],
    candidateSlowestPathTop: candidate?.slowestPathTop ?? [],
    baselineAggregateMergeMedianMs: baseline?.aggregateMergeSummary?.median ?? null,
    candidateAggregateMergeMedianMs: candidate?.aggregateMergeSummary?.median ?? null,
    baselineAggregateFinalizeMedianMs: baseline?.aggregateFinalizeSummary?.median ?? null,
    candidateAggregateFinalizeMedianMs: candidate?.aggregateFinalizeSummary?.median ?? null,
  };
}

function teddyRouteScoreFields(pairedAttribution, { minRouteImprovementPct = 0 } = {}) {
  const rawMedianPct = pairedAttribution?.pairedCandidateTeddyRangeImprovementMedianPct;
  const rawMeanPct = pairedAttribution?.pairedCandidateTeddyRangeImprovementMeanPct;
  const rawWinRate = pairedAttribution?.pairedCandidateTeddyRangeWinRate;
  const medianPct = Number(rawMedianPct);
  const meanPct = Number(rawMeanPct);
  const winRate = Number(rawWinRate);
  const hasMedian = rawMedianPct != null && Number.isFinite(medianPct);
  const hasMean = rawMeanPct != null && Number.isFinite(meanPct);
  const hasWinRate = rawWinRate != null && Number.isFinite(winRate);
  const observed = hasMedian || hasMean;
  const netPositive = !observed ||
    (hasMedian &&
      medianPct > minRouteImprovementPct &&
      hasMean &&
      meanPct > minRouteImprovementPct &&
      hasWinRate &&
      winRate > 0.5);
  return {
    teddyRouteObserved: observed,
    teddyRouteNetPositive: netPositive,
  };
}

function installedRepairDirective({ improvementPct, pairedImprovementMedianPct, pairedAttribution, routeScore } = {}) {
  const teddyMedianPct = Number(pairedAttribution?.pairedCandidateTeddyRangeImprovementMedianPct);
  const scanWorkPct = Number(pairedAttribution?.pairedCandidateScanWorkImprovementMedianPct);
  const scanPct = Number(pairedAttribution?.pairedCandidateScanImprovementMedianPct);
  const discoverPct = Number(pairedAttribution?.pairedCandidateDiscoverImprovementMedianPct);
  const engineRegressed = Number(improvementPct) < 0 || Number(pairedImprovementMedianPct) < 0;
  const teddyImproved = routeScore?.teddyRouteObserved === true &&
    routeScore?.teddyRouteNetPositive === true &&
    Number.isFinite(teddyMedianPct) &&
    teddyMedianPct > 0;
  const targetPhase = [
    ["scanWork", scanWorkPct],
    ["scan", scanPct],
    ["discover", discoverPct],
  ].find(([, value]) => Number.isFinite(value) && value < 0)?.[0] ?? null;

  return {
    mixedKernelEngineSignal: teddyImproved && engineRegressed,
    repairDirective: teddyImproved && engineRegressed
      ? "preserve_teddy_gain_repair_whole_engine"
      : (engineRegressed ? "repair_whole_engine_regression" : null),
    repairTargetPhase: targetPhase,
  };
}

export function buildInstalledComparisonScore({
  comparison,
  binaryRelation,
  improvementPct,
  pairedEngine,
  minInstalledImprovementPct = 0,
} = {}) {
  const pairedImprovementMedianPct = Number(pairedEngine?.candidateImprovementPctSummary?.median);
  const pairedImprovementMeanPct = Number(pairedEngine?.candidateImprovementPctSummary?.mean);
  const requiredImprovementPct = binaryRelation === "same_binary" ? null : Number(minInstalledImprovementPct);
  const pairedAttribution = pairedAttributionLedgerFields(pairedEngine ?? null);
  const routeScore = teddyRouteScoreFields(pairedAttribution);
  const routeParityAcceptable = comparison?.routeParityAcceptable ?? (comparison?.routeParity === true);
  const repairDirective = installedRepairDirective({
    improvementPct,
    pairedImprovementMedianPct,
    pairedAttribution,
    routeScore,
  });
  return {
    roundIndex: 1,
    testedOneAtATime: true,
    baselineLabel: "installed",
    candidateLabel: "repo",
    evidenceAuthority: comparison?.evidenceAuthority ?? (binaryRelation === "same_binary" ? "identity_noise_only" : "installed_vs_repo"),
    binaryRelation,
    requiredImprovementPct,
    installedEngineMedianMs: comparison?.installedEngineMedianMs ?? null,
    repoEngineMedianMs: comparison?.repoEngineMedianMs ?? null,
    installedDiscoverMedianMs: comparison?.installedDiscoverMedianMs ?? null,
    repoDiscoverMedianMs: comparison?.repoDiscoverMedianMs ?? null,
    installedScanMedianMs: comparison?.installedScanMedianMs ?? null,
    repoScanMedianMs: comparison?.repoScanMedianMs ?? null,
    installedAggregateMedianMs: comparison?.installedAggregateMedianMs ?? null,
    repoAggregateMedianMs: comparison?.repoAggregateMedianMs ?? null,
    installedEngineResidualMedianMs: comparison?.installedEngineResidualMedianMs ?? null,
    repoEngineResidualMedianMs: comparison?.repoEngineResidualMedianMs ?? null,
    installedScanWorkMedianMs: comparison?.installedScanWorkMedianMs ?? null,
    repoScanWorkMedianMs: comparison?.repoScanWorkMedianMs ?? null,
    installedScanOpenMedianMs: comparison?.installedScanOpenMedianMs ?? null,
    repoScanOpenMedianMs: comparison?.repoScanOpenMedianMs ?? null,
    installedScanFileMedianMs: comparison?.installedScanFileMedianMs ?? null,
    repoScanFileMedianMs: comparison?.repoScanFileMedianMs ?? null,
    installedAlternateFullScanCallsMedian: comparison?.installedAlternateFullScanCallsMedian ?? null,
    repoAlternateFullScanCallsMedian: comparison?.repoAlternateFullScanCallsMedian ?? null,
    installedAlternateFullScanBytesMedian: comparison?.installedAlternateFullScanBytesMedian ?? null,
    repoAlternateFullScanBytesMedian: comparison?.repoAlternateFullScanBytesMedian ?? null,
    installedAlternateFullScanMatchesMedian: comparison?.installedAlternateFullScanMatchesMedian ?? null,
    repoAlternateFullScanMatchesMedian: comparison?.repoAlternateFullScanMatchesMedian ?? null,
    installedAlternateTeddyRangeElapsedNsMedian: comparison?.installedAlternateTeddyRangeElapsedNsMedian ?? null,
    repoAlternateTeddyRangeElapsedNsMedian: comparison?.repoAlternateTeddyRangeElapsedNsMedian ?? null,
    repoEngineImprovementPct: improvementPct,
    repoVsInstalledEngineRatio:
      Number(comparison?.installedEngineMedianMs) !== 0
        ? Number(comparison?.repoEngineMedianMs) / Number(comparison?.installedEngineMedianMs)
        : null,
    repoEngineDeltaMs: Number(comparison?.repoEngineMedianMs) - Number(comparison?.installedEngineMedianMs),
    pairedRepoWinRate: pairedEngine?.candidateWinRate,
    pairedRepoImprovementMedianPct: Number.isFinite(pairedImprovementMedianPct) ? pairedImprovementMedianPct : null,
    pairedRepoImprovementMeanPct: Number.isFinite(pairedImprovementMeanPct) ? pairedImprovementMeanPct : null,
    ...pairedAttribution,
    ...routeScore,
    ...repairDirective,
    ...pairOrderScoreFields(comparison?.pairOrderSummary),
    matchParity: comparison?.matchParity,
    routeParity: comparison?.routeParity,
    routeParityComparable: comparison?.routeParityComparable ?? null,
    routeParityStatus: comparison?.routeParityStatus ?? null,
    routeParityAcceptable,
    fullScanCallsParity: comparison?.fullScanCallsParity ?? null,
    fullScanBytesParity: comparison?.fullScanBytesParity ?? null,
    fullScanMatchesParity: comparison?.fullScanMatchesParity ?? null,
    netPositive:
      binaryRelation === "same_binary"
        ? null
        : comparison?.matchParity === true &&
          routeParityAcceptable === true &&
          Number.isFinite(improvementPct) &&
          improvementPct >= requiredImprovementPct &&
          Number.isFinite(pairedImprovementMedianPct) &&
          pairedImprovementMedianPct >= requiredImprovementPct &&
          Number.isFinite(pairedImprovementMeanPct) &&
          pairedImprovementMeanPct > 0 &&
          Number(pairedEngine?.candidateWinRate) > 0.5 &&
          routeScore.teddyRouteNetPositive === true,
  };
}

export function effectiveImprovementTargetPct({
  configuredPct,
  identityControl,
  noiseMultiplier = 3,
} = {}) {
  const configured = Number(configuredPct);
  const medianDrift = Math.abs(Number(identityControl?.medianDeltaPct));
  const noiseTarget = Number.isFinite(medianDrift) ? medianDrift * Number(noiseMultiplier) : null;
  if (!Number.isFinite(configured)) return noiseTarget;
  if (!Number.isFinite(noiseTarget)) return configured;
  return Math.max(configured, noiseTarget);
}

export function buildInstalledScorecard({ score, binaryRelation } = {}) {
  return {
    totalRounds: 1,
    testedOneAtATime: score?.testedOneAtATime === true,
    strictCandidateRounds: binaryRelation === "same_binary" ? 0 : 1,
    netPositiveRounds: score?.netPositive === true ? 1 : 0,
    identityNoiseRounds: binaryRelation === "same_binary" ? 1 : 0,
    losingRounds:
      binaryRelation === "same_binary" || score?.netPositive === true
        ? []
        : [{
            roundIndex: score?.roundIndex,
            baselineLabel: score?.baselineLabel,
            candidateLabel: score?.candidateLabel,
            installedEngineMedianMs: score?.installedEngineMedianMs,
            repoEngineMedianMs: score?.repoEngineMedianMs,
            repoEngineImprovementPct: score?.repoEngineImprovementPct,
            installedDiscoverMedianMs: score?.installedDiscoverMedianMs,
            repoDiscoverMedianMs: score?.repoDiscoverMedianMs,
            installedScanMedianMs: score?.installedScanMedianMs,
            repoScanMedianMs: score?.repoScanMedianMs,
            installedAggregateMedianMs: score?.installedAggregateMedianMs,
            repoAggregateMedianMs: score?.repoAggregateMedianMs,
            installedEngineResidualMedianMs: score?.installedEngineResidualMedianMs,
            repoEngineResidualMedianMs: score?.repoEngineResidualMedianMs,
            installedScanWorkMedianMs: score?.installedScanWorkMedianMs,
            repoScanWorkMedianMs: score?.repoScanWorkMedianMs,
            installedScanOpenMedianMs: score?.installedScanOpenMedianMs,
            repoScanOpenMedianMs: score?.repoScanOpenMedianMs,
            installedScanFileMedianMs: score?.installedScanFileMedianMs,
            repoScanFileMedianMs: score?.repoScanFileMedianMs,
            installedAlternateFullScanCallsMedian: score?.installedAlternateFullScanCallsMedian,
            repoAlternateFullScanCallsMedian: score?.repoAlternateFullScanCallsMedian,
            installedAlternateFullScanBytesMedian: score?.installedAlternateFullScanBytesMedian,
            repoAlternateFullScanBytesMedian: score?.repoAlternateFullScanBytesMedian,
            installedAlternateFullScanMatchesMedian: score?.installedAlternateFullScanMatchesMedian,
            repoAlternateFullScanMatchesMedian: score?.repoAlternateFullScanMatchesMedian,
            installedAlternateTeddyRangeElapsedNsMedian: score?.installedAlternateTeddyRangeElapsedNsMedian,
            repoAlternateTeddyRangeElapsedNsMedian: score?.repoAlternateTeddyRangeElapsedNsMedian,
            pairedRepoWinRate: score?.pairedRepoWinRate,
            pairedRepoImprovementMedianPct: score?.pairedRepoImprovementMedianPct,
            pairedRepoImprovementMeanPct: score?.pairedRepoImprovementMeanPct,
            pairedCandidateTeddyRangeImprovementMedianPct: score?.pairedCandidateTeddyRangeImprovementMedianPct,
            pairedCandidateTeddyRangeImprovementMeanPct: score?.pairedCandidateTeddyRangeImprovementMeanPct,
            pairedCandidateTeddyRangeWinRate: score?.pairedCandidateTeddyRangeWinRate,
            pairedCandidateEngineResidualImprovementMedianPct: score?.pairedCandidateEngineResidualImprovementMedianPct,
            pairedCandidateEngineResidualImprovementMeanPct: score?.pairedCandidateEngineResidualImprovementMeanPct,
            pairedCandidateEngineResidualWinRate: score?.pairedCandidateEngineResidualWinRate,
            teddyRouteObserved: score?.teddyRouteObserved,
            teddyRouteNetPositive: score?.teddyRouteNetPositive,
            mixedKernelEngineSignal: score?.mixedKernelEngineSignal,
            repairDirective: score?.repairDirective,
            repairTargetPhase: score?.repairTargetPhase,
            requiredImprovementPct: score?.requiredImprovementPct,
            matchParity: score?.matchParity,
            routeParity: score?.routeParity,
            routeParityComparable: score?.routeParityComparable,
            routeParityStatus: score?.routeParityStatus,
            routeParityAcceptable: score?.routeParityAcceptable,
          }],
    netPositive:
      binaryRelation === "same_binary"
        ? null
        : score?.netPositive === true,
  };
}

export function buildInstalledRoundLedger({ comparison, score, binaryRelation, binaries } = {}) {
  return [
    {
      roundIndex: score?.roundIndex,
      testedOneAtATime: score?.testedOneAtATime === true,
      baselineLabel: score?.baselineLabel,
      candidateLabel: score?.candidateLabel,
      baselinePath: binaries?.installed?.path ?? null,
      candidatePath: binaries?.repo?.path ?? null,
      baselineSha256: binaries?.installed?.sha256 ?? null,
      candidateSha256: binaries?.repo?.sha256 ?? null,
      binaryRelation,
      evidenceAuthority: score?.evidenceAuthority ?? comparison?.evidenceAuthority,
      requiredImprovementPct: score?.requiredImprovementPct,
      baselineEngineMedianMs: comparison?.installedEngineMedianMs ?? null,
      candidateEngineMedianMs: comparison?.repoEngineMedianMs ?? null,
      engineImprovementPct: score?.repoEngineImprovementPct,
      engineRatio: score?.repoVsInstalledEngineRatio,
      engineDeltaMs: score?.repoEngineDeltaMs,
      baselineDiscoverMedianMs: comparison?.installedDiscoverMedianMs ?? null,
      candidateDiscoverMedianMs: comparison?.repoDiscoverMedianMs ?? null,
      baselineScanMedianMs: comparison?.installedScanMedianMs ?? null,
      candidateScanMedianMs: comparison?.repoScanMedianMs ?? null,
      baselineAggregateMedianMs: comparison?.installedAggregateMedianMs ?? null,
      candidateAggregateMedianMs: comparison?.repoAggregateMedianMs ?? null,
      baselineScanWorkMedianMs: comparison?.installedScanWorkMedianMs ?? null,
      candidateScanWorkMedianMs: comparison?.repoScanWorkMedianMs ?? null,
      baselineScanOpenMedianMs: comparison?.installedScanOpenMedianMs ?? null,
      candidateScanOpenMedianMs: comparison?.repoScanOpenMedianMs ?? null,
      baselineScanFileMedianMs: comparison?.installedScanFileMedianMs ?? null,
      candidateScanFileMedianMs: comparison?.repoScanFileMedianMs ?? null,
      baselineAlternateFullScanCallsMedian: comparison?.installedAlternateFullScanCallsMedian ?? null,
      candidateAlternateFullScanCallsMedian: comparison?.repoAlternateFullScanCallsMedian ?? null,
      baselineAlternateFullScanBytesMedian: comparison?.installedAlternateFullScanBytesMedian ?? null,
      candidateAlternateFullScanBytesMedian: comparison?.repoAlternateFullScanBytesMedian ?? null,
      baselineAlternateFullScanMatchesMedian: comparison?.installedAlternateFullScanMatchesMedian ?? null,
      candidateAlternateFullScanMatchesMedian: comparison?.repoAlternateFullScanMatchesMedian ?? null,
      baselineAlternateFullScanElapsedNsMedian: comparison?.installedAlternateFullScanElapsedNsMedian ?? null,
      candidateAlternateFullScanElapsedNsMedian: comparison?.repoAlternateFullScanElapsedNsMedian ?? null,
      baselineAlternateTeddyRangeElapsedNsMedian: comparison?.installedAlternateTeddyRangeElapsedNsMedian ?? null,
      candidateAlternateTeddyRangeElapsedNsMedian: comparison?.repoAlternateTeddyRangeElapsedNsMedian ?? null,
      pairedCandidateWinRate: score?.pairedRepoWinRate,
      pairedCandidateImprovementMedianPct: score?.pairedRepoImprovementMedianPct,
      pairedCandidateImprovementMeanPct: score?.pairedRepoImprovementMeanPct,
      pairedCandidateDiscoverImprovementMedianPct: score?.pairedCandidateDiscoverImprovementMedianPct,
      pairedCandidateDiscoverImprovementMeanPct: score?.pairedCandidateDiscoverImprovementMeanPct,
      pairedCandidateDiscoverDeltaMedianMs: score?.pairedCandidateDiscoverDeltaMedianMs,
      pairedCandidateDiscoverWinRate: score?.pairedCandidateDiscoverWinRate,
      pairedCandidateScanImprovementMedianPct: score?.pairedCandidateScanImprovementMedianPct,
      pairedCandidateScanImprovementMeanPct: score?.pairedCandidateScanImprovementMeanPct,
      pairedCandidateScanDeltaMedianMs: score?.pairedCandidateScanDeltaMedianMs,
      pairedCandidateScanWinRate: score?.pairedCandidateScanWinRate,
      pairedCandidateAggregateImprovementMedianPct: score?.pairedCandidateAggregateImprovementMedianPct,
      pairedCandidateAggregateImprovementMeanPct: score?.pairedCandidateAggregateImprovementMeanPct,
      pairedCandidateAggregateDeltaMedianMs: score?.pairedCandidateAggregateDeltaMedianMs,
      pairedCandidateAggregateWinRate: score?.pairedCandidateAggregateWinRate,
      pairedCandidateEngineResidualImprovementMedianPct: score?.pairedCandidateEngineResidualImprovementMedianPct,
      pairedCandidateEngineResidualImprovementMeanPct: score?.pairedCandidateEngineResidualImprovementMeanPct,
      pairedCandidateEngineResidualDeltaMedianMs: score?.pairedCandidateEngineResidualDeltaMedianMs,
      pairedCandidateEngineResidualWinRate: score?.pairedCandidateEngineResidualWinRate,
      pairedCandidateScanWorkImprovementMedianPct: score?.pairedCandidateScanWorkImprovementMedianPct,
      pairedCandidateScanWorkImprovementMeanPct: score?.pairedCandidateScanWorkImprovementMeanPct,
      pairedCandidateScanWorkDeltaMedianMs: score?.pairedCandidateScanWorkDeltaMedianMs,
      pairedCandidateScanWorkWinRate: score?.pairedCandidateScanWorkWinRate,
      pairedCandidateScanOpenImprovementMedianPct: score?.pairedCandidateScanOpenImprovementMedianPct,
      pairedCandidateScanOpenImprovementMeanPct: score?.pairedCandidateScanOpenImprovementMeanPct,
      pairedCandidateScanOpenDeltaMedianMs: score?.pairedCandidateScanOpenDeltaMedianMs,
      pairedCandidateScanOpenWinRate: score?.pairedCandidateScanOpenWinRate,
      pairedCandidateScanFileImprovementMedianPct: score?.pairedCandidateScanFileImprovementMedianPct,
      pairedCandidateScanFileImprovementMeanPct: score?.pairedCandidateScanFileImprovementMeanPct,
      pairedCandidateScanFileDeltaMedianMs: score?.pairedCandidateScanFileDeltaMedianMs,
      pairedCandidateScanFileWinRate: score?.pairedCandidateScanFileWinRate,
      pairedCandidateTeddyRangeImprovementMedianPct: score?.pairedCandidateTeddyRangeImprovementMedianPct,
      pairedCandidateTeddyRangeImprovementMeanPct: score?.pairedCandidateTeddyRangeImprovementMeanPct,
      pairedCandidateTeddyRangeDeltaMedianMs: score?.pairedCandidateTeddyRangeDeltaMedianMs,
      pairedCandidateTeddyRangeWinRate: score?.pairedCandidateTeddyRangeWinRate,
      teddyRouteObserved: score?.teddyRouteObserved,
      teddyRouteNetPositive: score?.teddyRouteNetPositive,
      pairCount: comparison?.pairedEngine?.count ?? null,
      ...pairOrderScoreFields(comparison?.pairOrderSummary),
      matchParity: score?.matchParity,
      routeParity: score?.routeParity,
      routeParityComparable: score?.routeParityComparable,
      routeParityStatus: score?.routeParityStatus,
      routeParityAcceptable: score?.routeParityAcceptable,
      netPositive: score?.netPositive,
    },
  ];
}

function roundStatus(round) {
  if (round?.binaryRelation === "same_binary" || round?.evidenceAuthority === "identity_noise_only") {
    return "identity";
  }
  if (round?.netPositive === true) return "net_positive";
  if (Number(round?.engineImprovementPct) < 0 || Number(round?.pairedCandidateImprovementMedianPct) < 0) {
    return "regression";
  }
  return "under_target";
}

export function buildRoundLedgerSummary(roundLedger) {
  const rounds = Array.isArray(roundLedger) ? roundLedger : [];
  const evidenceRounds = rounds.filter((round) => round?.evidenceAuthority !== "identity_noise_only");
  const netPositiveRounds = evidenceRounds.filter((round) => round?.netPositive === true);
  const regressionRounds = evidenceRounds.filter((round) => roundStatus(round) === "regression");
  const underTargetRounds = evidenceRounds.filter((round) => roundStatus(round) === "under_target");
  const unsupportedRouteRounds = evidenceRounds.filter((round) => round?.routeParityStatus === "baseline_unsupported");
  const mismatchedRouteRounds = evidenceRounds.filter((round) => round?.routeParityAcceptable !== true);
  const matchMismatchRounds = evidenceRounds.filter((round) => round?.matchParity !== true);
  return {
    totalRounds: rounds.length,
    evidenceRounds: evidenceRounds.length,
    identityRounds: rounds.length - evidenceRounds.length,
    netPositiveRounds: netPositiveRounds.length,
    regressionRounds: regressionRounds.length,
    underTargetRounds: underTargetRounds.length,
    unsupportedRouteRounds: unsupportedRouteRounds.length,
    mismatchedRouteRounds: mismatchedRouteRounds.length,
    matchMismatchRounds: matchMismatchRounds.length,
    netPositive: evidenceRounds.length > 0 && netPositiveRounds.length === evidenceRounds.length,
    rounds: rounds.map((round) => ({
      roundIndex: round?.roundIndex ?? null,
      baselineLabel: round?.baselineLabel ?? null,
      candidateLabel: round?.candidateLabel ?? null,
      evidenceAuthority: round?.evidenceAuthority ?? null,
      binaryRelation: round?.binaryRelation ?? null,
      status: roundStatus(round),
      baselineEngineMedianMs: round?.baselineEngineMedianMs ?? null,
      candidateEngineMedianMs: round?.candidateEngineMedianMs ?? null,
      engineImprovementPct: round?.engineImprovementPct ?? null,
      pairedCandidateImprovementMedianPct: round?.pairedCandidateImprovementMedianPct ?? null,
      pairedCandidateWinRate: round?.pairedCandidateWinRate ?? null,
      routeParityStatus: round?.routeParityStatus ?? null,
      routeParityAcceptable: round?.routeParityAcceptable ?? null,
      matchParity: round?.matchParity ?? null,
      netPositive: round?.netPositive ?? null,
    })),
  };
}

export function buildHistoricalComparisonScore({
  roundIndex,
  baselineLabel,
  sameBinary,
  improvementPct,
  ratio,
  deltaMs,
  pairedEngine,
  minPreviousBuildImprovementPct,
  matchParity,
  routeParity,
  routeParityComparable,
  routeParityStatus,
  routeParityAcceptable,
  pairOrderSummary,
  historyEngineMedianMs,
  currentEngineMedianMs,
} = {}) {
  const pairedImprovementMedianPct = Number(pairedEngine?.candidateImprovementPctSummary?.median);
  const pairedImprovementMeanPct = Number(pairedEngine?.candidateImprovementPctSummary?.mean);
  const pairedAttribution = pairedAttributionLedgerFields(pairedEngine ?? null);
  const routeScore = teddyRouteScoreFields(pairedAttribution);
  const repairDirective = installedRepairDirective({
    improvementPct,
    pairedImprovementMedianPct,
    pairedAttribution,
    routeScore,
  });
  return {
      roundIndex,
      testedOneAtATime: true,
      baselineLabel,
      candidateLabel: "repo-current",
      evidenceAuthority: sameBinary ? "identity_noise_only" : "previous_build",
      requiredImprovementPct: sameBinary ? null : minPreviousBuildImprovementPct,
      historyEngineMedianMs: historyEngineMedianMs ?? null,
      currentEngineMedianMs: currentEngineMedianMs ?? null,
      currentEngineImprovementPct: improvementPct,
      currentVsHistoryEngineRatio: ratio,
      currentEngineDeltaMs: deltaMs,
    pairedCurrentWinRate: pairedEngine?.candidateWinRate,
    pairedCurrentImprovementMedianPct: Number.isFinite(pairedImprovementMedianPct) ? pairedImprovementMedianPct : null,
    pairedCurrentImprovementMeanPct: Number.isFinite(pairedImprovementMeanPct) ? pairedImprovementMeanPct : null,
    ...pairedAttribution,
    ...routeScore,
    ...repairDirective,
    ...pairOrderScoreFields(pairOrderSummary),
    matchParity,
    routeParity,
    routeParityComparable: routeParityComparable ?? null,
    routeParityStatus: routeParityStatus ?? null,
    routeParityAcceptable: routeParityAcceptable ?? (routeParity === true),
    netPositive:
      sameBinary
        ? null
        : Number.isFinite(improvementPct) &&
          improvementPct >= minPreviousBuildImprovementPct &&
          Number.isFinite(pairedImprovementMedianPct) &&
          pairedImprovementMedianPct >= minPreviousBuildImprovementPct &&
          Number.isFinite(pairedImprovementMeanPct) &&
          pairedImprovementMeanPct >= minPreviousBuildImprovementPct &&
          Number(pairedEngine?.candidateWinRate) > 0.5 &&
          matchParity === true &&
          (routeParityAcceptable ?? (routeParity === true)) === true &&
          routeScore.teddyRouteNetPositive === true,
  };
}

export function buildHistoricalRoundLedger(comparisons) {
  return comparisons.map((comparison) => ({
    roundIndex: comparison.score?.roundIndex ?? comparison.roundIndex,
    testedOneAtATime: comparison.score?.testedOneAtATime === true,
    baselineLabel: comparison.score?.baselineLabel ?? comparison.label,
    candidateLabel: comparison.score?.candidateLabel ?? "repo-current",
      baselinePath: comparison.path ?? null,
      baselineSha256: comparison.sha256 ?? null,
      binaryRelation: comparison.relation,
      evidenceAuthority: comparison.score?.evidenceAuthority ?? comparison.evidenceAuthority,
      requiredImprovementPct: comparison.score?.requiredImprovementPct ?? comparison.minPreviousBuildImprovementPct,
      baselineEngineMedianMs: comparison.score?.historyEngineMedianMs ?? comparison.historyEngineMedianMs ?? comparison.historical?.engineSummary?.median ?? null,
      candidateEngineMedianMs: comparison.score?.currentEngineMedianMs ?? comparison.currentEngineMedianMs ?? comparison.current?.engineSummary?.median ?? null,
      engineImprovementPct: comparison.score?.currentEngineImprovementPct ?? comparison.currentEngineImprovementPct,
      engineRatio: comparison.score?.currentVsHistoryEngineRatio ?? comparison.currentVsHistoryEngineRatio,
      engineDeltaMs: comparison.score?.currentEngineDeltaMs ?? comparison.currentEngineDeltaMs,
    ...stageTimingMedianFields(comparison.historical, comparison.current),
    ...routeTimingMedianFields(comparison.historical, comparison.current),
    pairedCandidateWinRate: comparison.score?.pairedCurrentWinRate ?? comparison.pairedEngine?.candidateWinRate,
    pairedCandidateImprovementMedianPct:
      comparison.score?.pairedCurrentImprovementMedianPct ??
      comparison.pairedEngine?.candidateImprovementPctSummary?.median ??
      null,
    pairedCandidateImprovementMeanPct:
      comparison.score?.pairedCurrentImprovementMeanPct ??
      comparison.pairedEngine?.candidateImprovementPctSummary?.mean ??
      null,
    pairedCandidateDiscoverImprovementMedianPct: comparison.score?.pairedCandidateDiscoverImprovementMedianPct,
    pairedCandidateDiscoverImprovementMeanPct: comparison.score?.pairedCandidateDiscoverImprovementMeanPct,
    pairedCandidateDiscoverDeltaMedianMs: comparison.score?.pairedCandidateDiscoverDeltaMedianMs,
    pairedCandidateDiscoverWinRate: comparison.score?.pairedCandidateDiscoverWinRate,
    pairedCandidateScanImprovementMedianPct: comparison.score?.pairedCandidateScanImprovementMedianPct,
    pairedCandidateScanImprovementMeanPct: comparison.score?.pairedCandidateScanImprovementMeanPct,
    pairedCandidateScanDeltaMedianMs: comparison.score?.pairedCandidateScanDeltaMedianMs,
    pairedCandidateScanWinRate: comparison.score?.pairedCandidateScanWinRate,
    pairedCandidateAggregateImprovementMedianPct: comparison.score?.pairedCandidateAggregateImprovementMedianPct,
    pairedCandidateAggregateImprovementMeanPct: comparison.score?.pairedCandidateAggregateImprovementMeanPct,
    pairedCandidateAggregateDeltaMedianMs: comparison.score?.pairedCandidateAggregateDeltaMedianMs,
    pairedCandidateAggregateWinRate: comparison.score?.pairedCandidateAggregateWinRate,
    pairedCandidateEngineResidualImprovementMedianPct: comparison.score?.pairedCandidateEngineResidualImprovementMedianPct,
    pairedCandidateEngineResidualImprovementMeanPct: comparison.score?.pairedCandidateEngineResidualImprovementMeanPct,
    pairedCandidateEngineResidualDeltaMedianMs: comparison.score?.pairedCandidateEngineResidualDeltaMedianMs,
    pairedCandidateEngineResidualWinRate: comparison.score?.pairedCandidateEngineResidualWinRate,
    pairedCandidateScanWorkImprovementMedianPct: comparison.score?.pairedCandidateScanWorkImprovementMedianPct,
    pairedCandidateScanWorkImprovementMeanPct: comparison.score?.pairedCandidateScanWorkImprovementMeanPct,
    pairedCandidateScanWorkDeltaMedianMs: comparison.score?.pairedCandidateScanWorkDeltaMedianMs,
    pairedCandidateScanWorkWinRate: comparison.score?.pairedCandidateScanWorkWinRate,
    pairedCandidateScanOpenImprovementMedianPct: comparison.score?.pairedCandidateScanOpenImprovementMedianPct,
    pairedCandidateScanOpenImprovementMeanPct: comparison.score?.pairedCandidateScanOpenImprovementMeanPct,
    pairedCandidateScanOpenDeltaMedianMs: comparison.score?.pairedCandidateScanOpenDeltaMedianMs,
    pairedCandidateScanOpenWinRate: comparison.score?.pairedCandidateScanOpenWinRate,
    pairedCandidateScanFileImprovementMedianPct: comparison.score?.pairedCandidateScanFileImprovementMedianPct,
    pairedCandidateScanFileImprovementMeanPct: comparison.score?.pairedCandidateScanFileImprovementMeanPct,
    pairedCandidateScanFileDeltaMedianMs: comparison.score?.pairedCandidateScanFileDeltaMedianMs,
    pairedCandidateScanFileWinRate: comparison.score?.pairedCandidateScanFileWinRate,
    pairedCandidateTeddyRangeImprovementMedianPct: comparison.score?.pairedCandidateTeddyRangeImprovementMedianPct,
    pairedCandidateTeddyRangeImprovementMeanPct: comparison.score?.pairedCandidateTeddyRangeImprovementMeanPct,
    pairedCandidateTeddyRangeDeltaMedianMs: comparison.score?.pairedCandidateTeddyRangeDeltaMedianMs,
    pairedCandidateTeddyRangeWinRate: comparison.score?.pairedCandidateTeddyRangeWinRate,
    teddyRouteObserved: comparison.score?.teddyRouteObserved,
    teddyRouteNetPositive: comparison.score?.teddyRouteNetPositive,
    mixedKernelEngineSignal: comparison.score?.mixedKernelEngineSignal,
    repairDirective: comparison.score?.repairDirective,
    repairTargetPhase: comparison.score?.repairTargetPhase,
    pairCount: comparison.pairedEngine?.count ?? null,
    ...pairOrderScoreFields(comparison.pairOrderSummary ?? comparison.pairedEngine?.pairOrderSummary),
    matchParity: comparison.score?.matchParity ?? comparison.matchParity,
    routeParity: comparison.score?.routeParity ?? comparison.routeParity,
    routeParityComparable: comparison.score?.routeParityComparable ?? comparison.routeParityComparable ?? null,
    routeParityStatus: comparison.score?.routeParityStatus ?? comparison.routeParityStatus ?? null,
    routeParityAcceptable: comparison.score?.routeParityAcceptable ?? comparison.routeParityAcceptable ?? null,
    netPositive: comparison.score?.netPositive,
  }));
}

export function buildHistoricalScorecard(comparisons) {
  const previousBuildRounds = comparisons.filter((comparison) => comparison.evidenceAuthority === "previous_build");
  const losingRounds = previousBuildRounds
    .filter((comparison) => comparison.score?.netPositive !== true)
    .map((comparison) => ({
      roundIndex: comparison.score?.roundIndex ?? comparison.roundIndex,
      baselineLabel: comparison.score?.baselineLabel ?? comparison.label,
      candidateLabel: comparison.score?.candidateLabel ?? "repo-current",
      historyEngineMedianMs: comparison.score?.historyEngineMedianMs ?? comparison.historyEngineMedianMs ?? comparison.historical?.engineSummary?.median ?? null,
      currentEngineMedianMs: comparison.score?.currentEngineMedianMs ?? comparison.currentEngineMedianMs ?? comparison.current?.engineSummary?.median ?? null,
      currentEngineImprovementPct: comparison.score?.currentEngineImprovementPct ?? comparison.currentEngineImprovementPct,
      ...stageTimingMedianFields(comparison.historical, comparison.current),
      ...routeTimingMedianFields(comparison.historical, comparison.current),
      pairedCurrentWinRate: comparison.score?.pairedCurrentWinRate ?? comparison.pairedEngine?.candidateWinRate,
      pairedCurrentImprovementMedianPct: comparison.score?.pairedCurrentImprovementMedianPct,
      pairedCurrentImprovementMeanPct: comparison.score?.pairedCurrentImprovementMeanPct,
      pairedCandidateDiscoverImprovementMedianPct: comparison.score?.pairedCandidateDiscoverImprovementMedianPct,
      pairedCandidateDiscoverImprovementMeanPct: comparison.score?.pairedCandidateDiscoverImprovementMeanPct,
      pairedCandidateDiscoverDeltaMedianMs: comparison.score?.pairedCandidateDiscoverDeltaMedianMs,
      pairedCandidateDiscoverWinRate: comparison.score?.pairedCandidateDiscoverWinRate,
      pairedCandidateScanImprovementMedianPct: comparison.score?.pairedCandidateScanImprovementMedianPct,
      pairedCandidateScanImprovementMeanPct: comparison.score?.pairedCandidateScanImprovementMeanPct,
      pairedCandidateScanDeltaMedianMs: comparison.score?.pairedCandidateScanDeltaMedianMs,
      pairedCandidateScanWinRate: comparison.score?.pairedCandidateScanWinRate,
      pairedCandidateAggregateImprovementMedianPct: comparison.score?.pairedCandidateAggregateImprovementMedianPct,
      pairedCandidateAggregateImprovementMeanPct: comparison.score?.pairedCandidateAggregateImprovementMeanPct,
      pairedCandidateAggregateDeltaMedianMs: comparison.score?.pairedCandidateAggregateDeltaMedianMs,
      pairedCandidateAggregateWinRate: comparison.score?.pairedCandidateAggregateWinRate,
      pairedCandidateEngineResidualImprovementMedianPct: comparison.score?.pairedCandidateEngineResidualImprovementMedianPct,
      pairedCandidateEngineResidualImprovementMeanPct: comparison.score?.pairedCandidateEngineResidualImprovementMeanPct,
      pairedCandidateEngineResidualDeltaMedianMs: comparison.score?.pairedCandidateEngineResidualDeltaMedianMs,
      pairedCandidateEngineResidualWinRate: comparison.score?.pairedCandidateEngineResidualWinRate,
      pairedCandidateScanWorkImprovementMedianPct: comparison.score?.pairedCandidateScanWorkImprovementMedianPct,
      pairedCandidateScanWorkImprovementMeanPct: comparison.score?.pairedCandidateScanWorkImprovementMeanPct,
      pairedCandidateScanWorkDeltaMedianMs: comparison.score?.pairedCandidateScanWorkDeltaMedianMs,
      pairedCandidateScanWorkWinRate: comparison.score?.pairedCandidateScanWorkWinRate,
      pairedCandidateScanOpenImprovementMedianPct: comparison.score?.pairedCandidateScanOpenImprovementMedianPct,
      pairedCandidateScanOpenImprovementMeanPct: comparison.score?.pairedCandidateScanOpenImprovementMeanPct,
      pairedCandidateScanOpenDeltaMedianMs: comparison.score?.pairedCandidateScanOpenDeltaMedianMs,
      pairedCandidateScanOpenWinRate: comparison.score?.pairedCandidateScanOpenWinRate,
      pairedCandidateScanFileImprovementMedianPct: comparison.score?.pairedCandidateScanFileImprovementMedianPct,
      pairedCandidateScanFileImprovementMeanPct: comparison.score?.pairedCandidateScanFileImprovementMeanPct,
      pairedCandidateScanFileDeltaMedianMs: comparison.score?.pairedCandidateScanFileDeltaMedianMs,
      pairedCandidateScanFileWinRate: comparison.score?.pairedCandidateScanFileWinRate,
      pairedCandidateTeddyRangeImprovementMedianPct: comparison.score?.pairedCandidateTeddyRangeImprovementMedianPct,
      pairedCandidateTeddyRangeImprovementMeanPct: comparison.score?.pairedCandidateTeddyRangeImprovementMeanPct,
      pairedCandidateTeddyRangeDeltaMedianMs: comparison.score?.pairedCandidateTeddyRangeDeltaMedianMs,
      pairedCandidateTeddyRangeWinRate: comparison.score?.pairedCandidateTeddyRangeWinRate,
      teddyRouteObserved: comparison.score?.teddyRouteObserved,
      teddyRouteNetPositive: comparison.score?.teddyRouteNetPositive,
      mixedKernelEngineSignal: comparison.score?.mixedKernelEngineSignal,
      repairDirective: comparison.score?.repairDirective,
      repairTargetPhase: comparison.score?.repairTargetPhase,
      requiredImprovementPct: comparison.score?.requiredImprovementPct ?? comparison.minPreviousBuildImprovementPct,
      matchParity: comparison.score?.matchParity ?? comparison.matchParity,
      routeParity: comparison.score?.routeParity ?? comparison.routeParity,
      routeParityComparable: comparison.score?.routeParityComparable ?? comparison.routeParityComparable ?? null,
      routeParityStatus: comparison.score?.routeParityStatus ?? comparison.routeParityStatus ?? null,
      routeParityAcceptable: comparison.score?.routeParityAcceptable ?? comparison.routeParityAcceptable ?? null,
    }));
  const regressionRounds = losingRounds.filter((round) => historicalRoundRegressed(round));
  const underTargetRounds = losingRounds.filter((round) => !historicalRoundRegressed(round));
  return {
    totalRounds: comparisons.length,
    testedOneAtATime: comparisons.every((comparison) => comparison.score?.testedOneAtATime === true),
    previousBuildRounds: previousBuildRounds.length,
    netPositiveRounds: previousBuildRounds.filter((comparison) => comparison.score?.netPositive === true).length,
    identityNoiseRounds: comparisons.filter((comparison) => comparison.evidenceAuthority === "identity_noise_only").length,
    losingRounds,
    regressionRounds,
    underTargetRounds,
    regressionRoundCount: regressionRounds.length,
    underTargetRoundCount: underTargetRounds.length,
    netPositive: previousBuildRounds.length > 0 && losingRounds.length === 0,
  };
}

function historicalRoundRegressed(round) {
  return (
    Number(round.currentEngineImprovementPct) < 0 ||
    Number(round.pairedCurrentImprovementMedianPct) < 0 ||
    Number(round.pairedCurrentImprovementMeanPct) < 0
  );
}

export function buildAlternatesComparisonScore({
  comparison,
  roundIndex,
  minImprovementPct = 0,
} = {}) {
  const sameBinary = comparison?.binaryRelation === "same_binary";
  const improvementPct = -Number(comparison?.candidateEngineDeltaPct);
  const pairedImprovementMedianPct = Number(comparison?.pairedEngine?.candidateImprovementPctSummary?.median);
  const pairedImprovementMeanPct = Number(comparison?.pairedEngine?.candidateImprovementPctSummary?.mean);
  const pairedAttribution = pairedAttributionLedgerFields(comparison?.pairedEngine ?? null);
  const teddyRouteObserved = Array.isArray(comparison?.candidateTeddyRanges) &&
    comparison.candidateTeddyRanges.some((value) => Number(value) > 0);
  const teddyRouteImprovementMedianPct = Number(pairedAttribution.pairedCandidateTeddyRangeImprovementMedianPct);
  const teddyRouteImprovementMeanPct = Number(pairedAttribution.pairedCandidateTeddyRangeImprovementMeanPct);
  const teddyRouteWinRate = Number(pairedAttribution.pairedCandidateTeddyRangeWinRate);
  const teddyRouteNetPositive = !teddyRouteObserved ||
    (Number.isFinite(teddyRouteImprovementMedianPct) &&
      teddyRouteImprovementMedianPct > minImprovementPct &&
      Number.isFinite(teddyRouteImprovementMeanPct) &&
      teddyRouteImprovementMeanPct > minImprovementPct &&
      Number.isFinite(teddyRouteWinRate) &&
      teddyRouteWinRate > 0.5);
  const suppliedParityHolds = (key) => comparison?.[key] !== false;
  return {
    roundIndex,
    testedOneAtATime: true,
    baselineLabel: `baseline-branch-${comparison?.branchCount}`,
    candidateLabel: `candidate-branch-${comparison?.branchCount}`,
    branchCount: comparison?.branchCount,
    expression: comparison?.expression,
    evidenceAuthority: comparison?.evidenceAuthority ?? (sameBinary ? "identity_noise_only" : "candidate_vs_baseline"),
    binaryRelation: comparison?.binaryRelation,
    requiredImprovementPct: sameBinary ? null : minImprovementPct,
    candidateEngineImprovementPct: Number.isFinite(improvementPct) ? improvementPct : null,
    candidateVsBaselineEngineRatio: comparison?.candidateVsBaselineRatio,
    candidateEngineDeltaMs: comparison?.candidateEngineDeltaMs,
    pairedCandidateWinRate: comparison?.pairedEngine?.candidateWinRate,
    pairedCandidateImprovementMedianPct: Number.isFinite(pairedImprovementMedianPct) ? pairedImprovementMedianPct : null,
    pairedCandidateImprovementMeanPct: Number.isFinite(pairedImprovementMeanPct) ? pairedImprovementMeanPct : null,
    ...pairedAttribution,
    teddyRouteObserved,
    teddyRouteNetPositive,
    ...pairOrderScoreFields(comparison?.pairOrderSummary),
    matchParity: comparison?.matchParity,
    routeParity: comparison?.routeParity,
    fullScanCallsParity: comparison?.fullScanCallsParity ?? null,
    fullScanBytesParity: comparison?.fullScanBytesParity ?? null,
    fullScanMatchesParity: comparison?.fullScanMatchesParity ?? null,
    netPositive:
      sameBinary
        ? null
        : comparison?.matchParity === true &&
          Number.isFinite(improvementPct) &&
          improvementPct > minImprovementPct &&
          Number.isFinite(pairedImprovementMedianPct) &&
          pairedImprovementMedianPct > minImprovementPct &&
          Number.isFinite(pairedImprovementMeanPct) &&
          pairedImprovementMeanPct > minImprovementPct &&
          Number(comparison?.pairedEngine?.candidateWinRate) > 0.5 &&
          teddyRouteNetPositive &&
          comparison?.classification !== "regression" &&
          comparison?.regression !== true &&
          suppliedParityHolds("fullScanCallsParity") &&
          suppliedParityHolds("fullScanBytesParity") &&
          suppliedParityHolds("fullScanMatchesParity") &&
          pairOrderSummaryIsBalanced(comparison?.pairOrderSummary, comparison?.pairedEngine?.count),
  };
}

export function buildAlternatesRoundLedger(comparisons) {
  return comparisons.map((comparison, index) => ({
    roundIndex: comparison.score?.roundIndex ?? index + 1,
    testedOneAtATime: comparison.score?.testedOneAtATime === true,
    baselineLabel: comparison.score?.baselineLabel ?? `baseline-branch-${comparison.branchCount}`,
    candidateLabel: comparison.score?.candidateLabel ?? `candidate-branch-${comparison.branchCount}`,
    branchCount: comparison.score?.branchCount ?? comparison.branchCount,
    expression: comparison.score?.expression ?? comparison.expression,
    baselinePath: comparison.baselinePath ?? null,
    candidatePath: comparison.candidatePath ?? null,
    baselineSha256: comparison.baselineSha256 ?? null,
    candidateSha256: comparison.candidateSha256 ?? null,
    binaryRelation: comparison.score?.binaryRelation ?? comparison.binaryRelation,
    evidenceAuthority: comparison.score?.evidenceAuthority ?? comparison.evidenceAuthority,
    requiredImprovementPct: comparison.score?.requiredImprovementPct,
    engineImprovementPct: comparison.score?.candidateEngineImprovementPct,
    engineRatio: comparison.score?.candidateVsBaselineEngineRatio ?? comparison.candidateVsBaselineRatio,
    engineDeltaMs: comparison.score?.candidateEngineDeltaMs ?? comparison.candidateEngineDeltaMs,
    pairedCandidateWinRate: comparison.score?.pairedCandidateWinRate ?? comparison.pairedEngine?.candidateWinRate,
    pairedCandidateImprovementMedianPct:
      comparison.score?.pairedCandidateImprovementMedianPct ??
      comparison.pairedEngine?.candidateImprovementPctSummary?.median ??
      null,
    pairedCandidateImprovementMeanPct:
      comparison.score?.pairedCandidateImprovementMeanPct ??
      comparison.pairedEngine?.candidateImprovementPctSummary?.mean ??
      null,
    pairedCandidateTeddyRangeImprovementMedianPct:
      comparison.score?.pairedCandidateTeddyRangeImprovementMedianPct ??
      comparison.pairedEngine?.attribution?.teddyRangeNs?.candidateImprovementPctSummary?.median ??
      null,
    pairedCandidateTeddyRangeImprovementMeanPct:
      comparison.score?.pairedCandidateTeddyRangeImprovementMeanPct ??
      comparison.pairedEngine?.attribution?.teddyRangeNs?.candidateImprovementPctSummary?.mean ??
      null,
    pairedCandidateTeddyRangeWinRate:
      comparison.score?.pairedCandidateTeddyRangeWinRate ??
      comparison.pairedEngine?.attribution?.teddyRangeNs?.candidateWinRate ??
      null,
    teddyRouteObserved: comparison.score?.teddyRouteObserved ?? null,
    teddyRouteNetPositive: comparison.score?.teddyRouteNetPositive ?? null,
    pairCount: comparison.pairedEngine?.count ?? null,
    ...pairOrderScoreFields(comparison.pairOrderSummary),
    matchParity: comparison.score?.matchParity ?? comparison.matchParity,
    routeParity: comparison.score?.routeParity ?? comparison.routeParity,
    fullScanCallsParity: comparison.fullScanCallsParity ?? null,
    fullScanBytesParity: comparison.fullScanBytesParity ?? null,
    fullScanMatchesParity: comparison.fullScanMatchesParity ?? null,
    baselineAlternateFullScanCallsMedian: comparison.baselineAlternateFullScanCallsSummary?.median ?? null,
    candidateAlternateFullScanCallsMedian: comparison.candidateAlternateFullScanCallsSummary?.median ?? null,
    baselineAlternateFullScanBytesMedian: comparison.baselineAlternateFullScanBytesSummary?.median ?? null,
    candidateAlternateFullScanBytesMedian: comparison.candidateAlternateFullScanBytesSummary?.median ?? null,
    baselineAlternateFullScanMatchesMedian: comparison.baselineAlternateFullScanMatchesSummary?.median ?? null,
    candidateAlternateFullScanMatchesMedian: comparison.candidateAlternateFullScanMatchesSummary?.median ?? null,
    baselineAlternateFullScanElapsedNsMedian: comparison.baselineAlternateFullScanElapsedNsTotalSummary?.median ?? null,
    candidateAlternateFullScanElapsedNsMedian: comparison.candidateAlternateFullScanElapsedNsTotalSummary?.median ?? null,
    netPositive: comparison.score?.netPositive,
  }));
}

export function buildAlternatesScorecard(comparisons) {
  const candidateRounds = comparisons.filter((comparison) => comparison.evidenceAuthority === "candidate_vs_baseline");
  const losingRounds = candidateRounds
    .filter((comparison) => comparison.score?.netPositive !== true)
    .map((comparison) => ({
      roundIndex: comparison.score?.roundIndex,
      baselineLabel: comparison.score?.baselineLabel,
      candidateLabel: comparison.score?.candidateLabel,
      branchCount: comparison.score?.branchCount ?? comparison.branchCount,
      candidateEngineImprovementPct: comparison.score?.candidateEngineImprovementPct,
      pairedCandidateWinRate: comparison.score?.pairedCandidateWinRate,
      pairedCandidateImprovementMedianPct: comparison.score?.pairedCandidateImprovementMedianPct,
      pairedCandidateImprovementMeanPct: comparison.score?.pairedCandidateImprovementMeanPct,
      pairedCandidateTeddyRangeImprovementMedianPct: comparison.score?.pairedCandidateTeddyRangeImprovementMedianPct,
      pairedCandidateTeddyRangeImprovementMeanPct: comparison.score?.pairedCandidateTeddyRangeImprovementMeanPct,
      pairedCandidateTeddyRangeWinRate: comparison.score?.pairedCandidateTeddyRangeWinRate,
      teddyRouteObserved: comparison.score?.teddyRouteObserved,
      teddyRouteNetPositive: comparison.score?.teddyRouteNetPositive,
      requiredImprovementPct: comparison.score?.requiredImprovementPct,
      matchParity: comparison.score?.matchParity ?? comparison.matchParity,
      fullScanCallsParity: comparison.fullScanCallsParity ?? null,
      fullScanBytesParity: comparison.fullScanBytesParity ?? null,
      fullScanMatchesParity: comparison.fullScanMatchesParity ?? null,
    }));
  return {
    totalRounds: comparisons.length,
    testedOneAtATime: comparisons.every((comparison) => comparison.score?.testedOneAtATime === true),
    candidateRounds: candidateRounds.length,
    netPositiveRounds: candidateRounds.filter((comparison) => comparison.score?.netPositive === true).length,
    identityNoiseRounds: comparisons.filter((comparison) => comparison.evidenceAuthority === "identity_noise_only").length,
    losingRounds,
    netPositive: candidateRounds.length > 0 && losingRounds.length === 0,
  };
}

function scorecardValueMatches(actual, expected) {
  if (typeof expected === "number") return Number(actual) === expected;
  if (expected != null && typeof expected === "object") return JSON.stringify(actual) === JSON.stringify(expected);
  return actual === expected;
}

function losingRoundMatches(actual, expected) {
  if (actual == null || typeof actual !== "object" || Array.isArray(actual)) return false;
  const expectedKeys = Object.keys(expected);
  return expectedKeys.every((key) => scorecardValueMatches(actual[key], expected[key]));
}

export function scorecardMatchesExpected(actual, expected) {
  if (actual == null || typeof actual !== "object" || Array.isArray(actual)) return false;
  if (expected == null || typeof expected !== "object" || Array.isArray(expected)) return false;
  const diagnosticKeys = new Set([
    "losingRounds",
    "regressionRounds",
    "underTargetRounds",
    "regressionRoundCount",
    "underTargetRoundCount",
  ]);
  const expectedKeys = Object.keys(expected).filter((key) => !diagnosticKeys.has(key));
  if (!expectedKeys.every((key) => scorecardValueMatches(actual[key], expected[key]))) return false;
  if (!Array.isArray(actual.losingRounds) || !Array.isArray(expected.losingRounds)) return false;
  if (actual.losingRounds.length !== expected.losingRounds.length) return false;
  return expected.losingRounds.every((round, index) => losingRoundMatches(actual.losingRounds[index], round));
}

export function roundLedgerMatchesExpected(actual, expected) {
  if (!Array.isArray(actual) || !Array.isArray(expected) || actual.length !== expected.length) return false;
  return actual.every((entry, index) => JSON.stringify(entry) === JSON.stringify(expected[index]));
}

function measureSameBinaryIdentityControlAttempt({
  binaryPath,
  ixArgs,
  samples,
  env,
  label = "repo-control",
  attempt = 1,
} = {}) {
  const lanes = { first: [], second: [] };
  const pairOrder = [];
  for (let pair = 0; pair < samples; pair += 1) {
    const firstLane = pair % 2 === 0 ? "first" : "second";
    const secondLane = firstLane === "first" ? "second" : "first";
    pairOrder.push(`${firstLane},${secondLane}`);
    for (const lane of [firstLane, secondLane]) {
      lanes[lane].push(measureIxOnce(binaryPath, ixArgs, lanes[lane].length + 1, { env }));
    }
  }

  const first = summarizeIxRuns(binaryPath, `${label}-a`, lanes.first);
  const second = summarizeIxRuns(binaryPath, `${label}-b`, lanes.second);
  const medianDeltaPct = first.engineSummary.median === 0
    ? null
    : ((second.engineSummary.median - first.engineSummary.median) / first.engineSummary.median) * 100;
  const identityControl = {
    enabled: true,
    attempt,
    samples,
    binary: { path: binaryPath, sha256: first.sha256 },
    first,
    second,
    pairOrder,
    pairOrderSummary: pairOrderSummary(pairOrder, { firstLabel: "first", secondLabel: "second" }),
    pairedEngine: pairedEngineStats(first.samples, second.samples, {
      baselineLabel: "repoControlA",
      candidateLabel: "repoControlB",
    }),
    medianDeltaPct,
    matchParity:
      first.matchCounts.length === 1 &&
      second.matchCounts.length === 1 &&
      first.matchCounts[0] === second.matchCounts[0],
    routeParity:
      JSON.stringify(first.alternateTeddyRangeCalls) === JSON.stringify(second.alternateTeddyRangeCalls) &&
      JSON.stringify(first.alternatePcreRangeCalls) === JSON.stringify(second.alternatePcreRangeCalls) &&
      JSON.stringify(first.alternateCompiledRangeCalls) === JSON.stringify(second.alternateCompiledRangeCalls),
  };
  identityControl.diagnostics = identityNoiseDiagnostics(identityControl);
  return identityControl;
}

function identityAttemptScore(control) {
  const status = control?.diagnostics?.status ?? "missing";
  const medianDeltaAbsPct = Number(control?.diagnostics?.medianDeltaAbsPct);
  const pairedWinRate = Number(control?.diagnostics?.pairedWinRate);
  return {
    stable: status === "stable",
    medianDeltaAbsPct: Number.isFinite(medianDeltaAbsPct) ? medianDeltaAbsPct : Number.POSITIVE_INFINITY,
    pairedWinRateDistance: Number.isFinite(pairedWinRate) ? Math.abs(pairedWinRate - 0.5) : Number.POSITIVE_INFINITY,
  };
}

function selectIdentityControlAttempt(attempts) {
  const stable = attempts.find((attempt) => attempt?.diagnostics?.status === "stable");
  if (stable) return { selected: stable, reason: "first_stable_attempt" };
  const selected = [...attempts].sort((left, right) => {
    const leftScore = identityAttemptScore(left);
    const rightScore = identityAttemptScore(right);
    return leftScore.medianDeltaAbsPct - rightScore.medianDeltaAbsPct ||
      leftScore.pairedWinRateDistance - rightScore.pairedWinRateDistance;
  })[0] ?? null;
  return { selected, reason: "lowest_identity_drift_attempt" };
}

function identityAttemptSummary(control) {
  return {
    attempt: control?.attempt ?? null,
    status: control?.diagnostics?.status ?? null,
    medianDeltaPct: control?.diagnostics?.medianDeltaPct ?? null,
    medianDeltaAbsPct: control?.diagnostics?.medianDeltaAbsPct ?? null,
    pairedWinRate: control?.diagnostics?.pairedWinRate ?? null,
    dominantPhaseDrift: control?.diagnostics?.dominantPhaseDrift ?? null,
  };
}

export function measureSameBinaryIdentityControl({
  binaryPath,
  ixArgs,
  samples,
  env,
  enabled = true,
  label = "repo-control",
  attempts = 1,
} = {}) {
  if (!enabled || samples === 0) return null;
  const attemptCount = Math.max(1, Math.floor(Number(attempts) || 1));
  const attemptReports = [];
  for (let attempt = 1; attempt <= attemptCount; attempt += 1) {
    const report = measureSameBinaryIdentityControlAttempt({
      binaryPath,
      ixArgs,
      samples,
      env,
      label: `${label}-attempt-${attempt}`,
      attempt,
    });
    attemptReports.push(report);
  }

  const { selected, reason } = selectIdentityControlAttempt(attemptReports);
  return {
    ...selected,
    attemptsRequested: attemptCount,
    attemptsRun: attemptReports.length,
    selectedAttempt: selected?.attempt ?? null,
    attemptSelection: reason,
    attemptSummaries: attemptReports.map(identityAttemptSummary),
  };
}

export function identityControlFailures({
  identityControl,
  enabled = true,
  requiredSamples,
  maxMedianDeltaPct = 3,
  minWinRate = 0.25,
  maxWinRate = 0.75,
} = {}) {
  const failures = [];
  if (!enabled) return failures;
  if (identityControl == null) {
    failures.push("identity_control_missing");
    return failures;
  }
  if (Number.isFinite(requiredSamples) && identityControl.samples < requiredSamples) {
    failures.push(`identity_control_underpowered:${identityControl.samples}<${requiredSamples}`);
  }
  const attemptsRequested = Number(identityControl.attemptsRequested);
  const attemptsRun = Number(identityControl.attemptsRun);
  if (Number.isFinite(attemptsRequested) && Number.isFinite(attemptsRun) && attemptsRun < attemptsRequested) {
    failures.push(`identity_control_attempts_underpowered:${attemptsRun}<${attemptsRequested}`);
  }
  if (!pairOrderSummaryIsBalanced(identityControl.pairOrderSummary, identityControl.samples)) {
    failures.push("identity_control_pair_order_unbalanced");
  }
  if (identityControl.matchParity !== true) failures.push("identity_control_match_parity_failed");
  if (identityControl.routeParity !== true) failures.push("identity_control_route_parity_failed");
  const medianDeltaAbsPct = Math.abs(Number(identityControl.medianDeltaPct));
  if (!Number.isFinite(medianDeltaAbsPct)) {
    failures.push("identity_control_median_delta_missing");
  } else if (medianDeltaAbsPct > maxMedianDeltaPct) {
    failures.push(`identity_control_noise_exceeded:${medianDeltaAbsPct}>${maxMedianDeltaPct}`);
  }
  const winRate = Number(identityControl.pairedEngine?.candidateWinRate);
  if (Number.isFinite(winRate) && (winRate <= minWinRate || winRate >= maxWinRate)) {
    failures.push(`identity_control_paired_skew:${winRate}`);
  }
  return failures;
}

export function fileHash(filePath) {
  const escaped = filePath.replaceAll("'", "''");
  return requireOk(
    run("powershell", ["-NoProfile", "-Command", `(Get-FileHash -LiteralPath '${escaped}' -Algorithm SHA256).Hash`]),
    `hash ${filePath}`,
  ).stdout.trim();
}

function summarizeProcessReport(report) {
  if (!report || typeof report !== "object") return null;
  return {
    cmd: report.cmd ?? null,
    state_dir: report.state_dir ?? null,
    live: Number(report.live ?? 0),
    stale: Number(report.stale ?? 0),
    malformed: Number(report.malformed ?? 0),
    warnings: Number(report.warnings ?? 0),
    removed: Number(report.removed ?? 0),
  };
}

function scanIxProcessState({ ixBinary, env, label }) {
  if (!ixBinary || !existsSync(ixBinary)) {
    return {
      ok: true,
      label,
      skipped: true,
      reason: "ix binary missing",
      report: null,
      failures: [],
    };
  }
  const result = run(ixBinary, ["process", "status", "--json"], { env });
  if (result.exitCode !== 0) {
    return {
      ok: false,
      label,
      command: result.command,
      report: null,
      failures: [`${label}:process_status_exit_${result.exitCode}`],
      stderr: result.stderr.trim(),
      stdout: result.stdout.trim(),
    };
  }
  try {
    const report = summarizeProcessReport(JSON.parse(result.stdout || "{}"));
    const failures = [];
    if (Number(report.live) > 0) failures.push(`${label}:live_markers:${report.live}`);
    if (Number(report.stale) > 0) failures.push(`${label}:stale_markers:${report.stale}`);
    if (Number(report.malformed) > 0) failures.push(`${label}:malformed_markers:${report.malformed}`);
    if (Number(report.warnings) > 0) failures.push(`${label}:memory_warnings:${report.warnings}`);
    return {
      ok: failures.length === 0,
      label,
      command: result.command,
      report,
      failures,
    };
  } catch {
    return {
      ok: false,
      label,
      command: result.command,
      report: null,
      failures: [`${label}:process_status_invalid_json`],
      stdout: result.stdout.trim(),
    };
  }
}

export function scanIxProcesses({ ixBinary, env } = {}) {
  const script = [
    "$matches = Get-CimInstance Win32_Process |",
    "  Where-Object { $_.ProcessId -ne $PID -and $_.Name -match '^(ix|iex|ix-zig|__ix_indexd|__ix_nexus)(\\.exe)?$' } |",
    "  Select-Object ProcessId,Name,CommandLine,WorkingSetSize",
    "if ($null -eq $matches) { '[]' } else { $matches | ConvertTo-Json -Compress }",
  ].join("\n");
  const result = run("powershell", ["-NoProfile", "-Command", script]);
  const defaultState = scanIxProcessState({ ixBinary, label: "default_state" });
  const benchmarkState = env?.IX_STATE_DIR
    ? scanIxProcessState({ ixBinary, env, label: "benchmark_state" })
    : null;
  const stateReports = [defaultState, benchmarkState].filter(Boolean);
  const stateFailures = stateReports.flatMap((entry) => entry.failures ?? []);
  if (result.exitCode !== 0) {
    return {
      ok: false,
      matched: [],
      command: result.command,
      stderr: result.stderr.trim(),
      stdout: result.stdout.trim(),
      stateReports,
      failures: ["process_name_probe_failed", ...stateFailures],
    };
  }
  const stdout = result.stdout.trim();
  if (stdout.length === 0 || stdout === "[]") {
    return {
      ok: stateFailures.length === 0,
      matched: [],
      command: result.command,
      stateReports,
      failures: stateFailures,
    };
  }
  const parsed = JSON.parse(stdout);
  const matched = Array.isArray(parsed) ? parsed : [parsed];
  return {
    ok: stateFailures.length === 0,
    matched,
    command: result.command,
    stateReports,
    failures: stateFailures,
  };
}

export function parseIxReport(stdout) {
  const text = stdout.trim();
  if (text.length === 0) throw new Error("IX produced empty stdout");
  return JSON.parse(text);
}

export function inferRipgrepArgs({ expression, defaultExpression = DEFAULT_ALTERNATES_EXPR, corpus, threads }) {
  if (expression === defaultExpression) {
    return [
      "--color=never",
      "--threads",
      String(threads),
      "--mmap",
      "--fixed-strings",
      "--ignore-case",
      "-e",
      "ERR_SYS",
      "-e",
      "PME_TURN_OFF",
      "-e",
      "LINK_REQ_RST",
      "-e",
      "CFG_BME_EVT",
      corpus,
    ];
  }
  return ["--color=never", "--threads", String(threads), expression, corpus];
}

export function measureRipgrep({ expression, defaultExpression = DEFAULT_ALTERNATES_EXPR, corpus, threads, samples, env }) {
  const args = inferRipgrepArgs({ expression, defaultExpression, corpus, threads });
  const runs = [];
  for (let sample = 1; sample <= samples; sample += 1) {
    const result = run("rg", args, { env });
    if (result.exitCode !== 0 && result.exitCode !== 1) requireOk(result, `ripgrep sample ${sample}`);
    runs.push({ sample, durationMs: result.durationMs, exitCode: result.exitCode });
  }
  return { command: "rg", args, samples: runs, summary: summary(runs.map((entry) => entry.durationMs)) };
}

export function measureIxOnce(binaryPath, ixArgs, sample, options = {}) {
  const result = requireOk(run(binaryPath, ixArgs, { env: options.env }), `${binaryPath} sample ${sample}`);
  const report = parseIxReport(result.stdout);
  const density = report.stats?.fast_count_density ?? {};
  const timings = report.stats?.timings ?? {};
  const byteShard = report.stats?.byte_shard_kernel ?? {};
  const slowest = report.stats?.slowest ?? report.stats?.slowest_file ?? {};
  const slowestFiles = Array.isArray(report.stats?.slowest_files) ? report.stats.slowest_files : [];
  const byteShardStrategy = byteShard.strategy ?? "none";
  const byteShardRangeElapsedNsTotal = Number(byteShard.range_elapsed_ns_total ?? 0);
  const byteShardRangeElapsedNsMax = Number(byteShard.max_range_elapsed_ns ?? 0);
  const alternatePcreRangeCalls = Number(density.alternate_pcre_range_calls ?? 0);
  const alternateTeddyRangeCalls = Number(density.alternate_teddy_range_calls ?? 0);
  const alternateCompiledRangeCalls = Number(density.alternate_compiled_range_calls ?? 0);
  const derivedRouteTiming =
    byteShardStrategy === "literal_alternates" &&
    (alternatePcreRangeCalls + alternateTeddyRangeCalls + alternateCompiledRangeCalls) > 0;
  const alternatePcreRangeElapsedNsTotal = derivedRouteTiming && alternatePcreRangeCalls > 0 ? byteShardRangeElapsedNsTotal : Number(density.alternate_pcre_range_elapsed_ns_total ?? 0);
  const alternatePcreRangeElapsedNsMax = derivedRouteTiming && alternatePcreRangeCalls > 0 ? byteShardRangeElapsedNsMax : Number(density.alternate_pcre_range_elapsed_ns_max ?? 0);
  const alternateTeddyRangeElapsedNsTotal = derivedRouteTiming && alternateTeddyRangeCalls > 0 ? byteShardRangeElapsedNsTotal : Number(density.alternate_teddy_range_elapsed_ns_total ?? 0);
  const alternateTeddyRangeElapsedNsMax = derivedRouteTiming && alternateTeddyRangeCalls > 0 ? byteShardRangeElapsedNsMax : Number(density.alternate_teddy_range_elapsed_ns_max ?? 0);
  const alternateCompiledRangeElapsedNsTotal = derivedRouteTiming && alternateCompiledRangeCalls > 0 ? byteShardRangeElapsedNsTotal : Number(density.alternate_compiled_range_elapsed_ns_total ?? 0);
  const alternateCompiledRangeElapsedNsMax = derivedRouteTiming && alternateCompiledRangeCalls > 0 ? byteShardRangeElapsedNsMax : Number(density.alternate_compiled_range_elapsed_ns_max ?? 0);
  const engineMs = Number(report.stats?.timings?.total_ms ?? result.durationMs);
  return {
    sample,
    cliMs: result.durationMs,
    engineMs,
    discoverMs: Number(timings.discover_ms ?? 0),
    scanMs: Number(timings.scan_ms ?? 0),
    aggregateMs: Number(timings.aggregate_ms ?? 0),
    engineResidualMs: phaseTimingResidualMs(timings, engineMs),
    scanWorkMsTotal: Number(timings.scan_work_ms_total ?? 0),
    scanOpenMsTotal: optionalNumber(timings.scan_open_ms_total),
    scanFileMsTotal: optionalNumber(timings.scan_file_ms_total),
    scanFileMmapMsTotal: optionalNumber(timings.scan_file_mmap_ms_total),
    scanFileFastCountMsTotal: optionalNumber(timings.scan_file_fast_count_ms_total),
    scanFileLineScanMsTotal: optionalNumber(timings.scan_file_line_scan_ms_total),
    aggregateMergeMs: Number(timings.aggregate_merge_ms ?? 0),
    aggregateFinalizeMs: Number(timings.aggregate_finalize_ms ?? 0),
    matches: Number(report.stats?.matches_found ?? 0),
    filesScanned: Number(report.stats?.files_scanned ?? 0),
    scanOpenMsPerFile: msPerFile(timings.scan_open_ms_total, report.stats?.files_scanned),
    scanFileMsPerFile: msPerFile(timings.scan_file_ms_total, report.stats?.files_scanned),
    slowestPath: slowest.path ?? slowestFiles[0]?.path ?? "",
    slowestMs: Number(slowest.ms ?? slowest.duration_ms ?? slowestFiles[0]?.duration_ms ?? 0),
    slowestBytes: Number(slowest.bytes ?? slowestFiles[0]?.bytes ?? 0),
    slowestFiles: slowestFiles.slice(0, 5).map((entry) => ({
      path: entry?.path ?? "",
      durationMs: Number(entry?.duration_ms ?? 0),
      bytes: Number(entry?.bytes ?? 0),
      linuxDominantTarget: entry?.linux_dominant_target === true,
    })),
    byteShardStrategy,
    byteShardRanges: Number(byteShard.range_calls ?? 0),
    alternateFullScanCalls: Number(density.alternate_full_scan_calls ?? 0),
    alternateFullScanBytes: Number(density.alternate_full_scan_bytes ?? 0),
    alternateFullScanMatches: Number(density.alternate_full_scan_matches ?? 0),
    alternateFullScanElapsedNsTotal: Number(density.alternate_full_scan_elapsed_ns_total ?? 0),
    alternateFullScanElapsedNsMax: Number(density.alternate_full_scan_elapsed_ns_max ?? 0),
    alternatePcreRangeCalls,
    alternatePcreRangeElapsedNsTotal,
    alternatePcreRangeElapsedNsMax,
    alternateTeddyRangeCalls,
    alternateTeddyRangeElapsedNsTotal,
    alternateTeddyRangeElapsedNsMax,
    alternateCompiledRangeCalls,
    alternateCompiledRangeElapsedNsTotal,
    alternateCompiledRangeElapsedNsMax,
  };
}

export function summarizeIxRuns(binaryPath, label, runs) {
  return {
    label,
    path: binaryPath,
    sha256: fileHash(binaryPath),
    samples: runs,
    cliSummary: summary(runs.map((entry) => entry.cliMs)),
    engineSummary: summary(runs.map((entry) => entry.engineMs)),
    discoverSummary: summary(runs.map((entry) => entry.discoverMs)),
    scanSummary: summary(runs.map((entry) => entry.scanMs)),
    aggregateSummary: summary(runs.map((entry) => entry.aggregateMs)),
    engineResidualSummary: summary(runs.map((entry) => entry.engineResidualMs)),
    scanWorkSummary: summary(runs.map((entry) => entry.scanWorkMsTotal)),
    scanOpenSummary: summary(runs.map((entry) => entry.scanOpenMsTotal)),
    scanFileSummary: summary(runs.map((entry) => entry.scanFileMsTotal)),
    scanFileMmapSummary: optionalSummary(runs.map((entry) => entry.scanFileMmapMsTotal)),
    scanFileFastCountSummary: optionalSummary(runs.map((entry) => entry.scanFileFastCountMsTotal)),
    scanFileLineScanSummary: optionalSummary(runs.map((entry) => entry.scanFileLineScanMsTotal)),
    scanOpenMsPerFileSummary: summary(runs.map((entry) => entry.scanOpenMsPerFile)),
    scanFileMsPerFileSummary: summary(runs.map((entry) => entry.scanFileMsPerFile)),
    slowestMsSummary: summary(runs.map((entry) => entry.slowestMs)),
    slowestBytesSummary: summary(runs.map((entry) => entry.slowestBytes)),
    slowestPathTop: topCounts(runs.flatMap((entry) => {
      const paths = Array.isArray(entry.slowestFiles)
        ? entry.slowestFiles.map((slow) => slow.path).filter(Boolean)
        : [];
      return paths.length > 0 ? paths : [entry.slowestPath].filter(Boolean);
    })),
    aggregateMergeSummary: summary(runs.map((entry) => entry.aggregateMergeMs)),
    aggregateFinalizeSummary: summary(runs.map((entry) => entry.aggregateFinalizeMs)),
    matchCounts: [...new Set(runs.map((entry) => entry.matches))],
    filesScanned: [...new Set(runs.map((entry) => entry.filesScanned))],
    byteShardStrategy: [...new Set(runs.map((entry) => entry.byteShardStrategy))],
    byteShardRanges: [...new Set(runs.map((entry) => entry.byteShardRanges))],
    alternateFullScanCalls: [...new Set(runs.map((entry) => entry.alternateFullScanCalls))],
    alternateFullScanCallsSummary: summary(runs.map((entry) => entry.alternateFullScanCalls)),
    alternateFullScanBytes: [...new Set(runs.map((entry) => entry.alternateFullScanBytes))],
    alternateFullScanBytesSummary: summary(runs.map((entry) => entry.alternateFullScanBytes)),
    alternateFullScanMatches: [...new Set(runs.map((entry) => entry.alternateFullScanMatches))],
    alternateFullScanMatchesSummary: summary(runs.map((entry) => entry.alternateFullScanMatches)),
    alternateFullScanElapsedNsTotal: [...new Set(runs.map((entry) => entry.alternateFullScanElapsedNsTotal))],
    alternateFullScanElapsedNsTotalSummary: summary(runs.map((entry) => entry.alternateFullScanElapsedNsTotal)),
    alternateFullScanElapsedNsMax: [...new Set(runs.map((entry) => entry.alternateFullScanElapsedNsMax))],
    alternateFullScanElapsedNsMaxSummary: summary(runs.map((entry) => entry.alternateFullScanElapsedNsMax)),
    alternatePcreRangeCalls: [...new Set(runs.map((entry) => entry.alternatePcreRangeCalls))],
    alternatePcreRangeElapsedNsTotal: [...new Set(runs.map((entry) => entry.alternatePcreRangeElapsedNsTotal))],
    alternatePcreRangeElapsedNsTotalSummary: summary(runs.map((entry) => entry.alternatePcreRangeElapsedNsTotal)),
    alternatePcreRangeElapsedNsMax: [...new Set(runs.map((entry) => entry.alternatePcreRangeElapsedNsMax))],
    alternatePcreRangeElapsedNsMaxSummary: summary(runs.map((entry) => entry.alternatePcreRangeElapsedNsMax)),
    alternateTeddyRangeCalls: [...new Set(runs.map((entry) => entry.alternateTeddyRangeCalls))],
    alternateTeddyRangeElapsedNsTotal: [...new Set(runs.map((entry) => entry.alternateTeddyRangeElapsedNsTotal))],
    alternateTeddyRangeElapsedNsTotalSummary: summary(runs.map((entry) => entry.alternateTeddyRangeElapsedNsTotal)),
    alternateTeddyRangeElapsedNsMax: [...new Set(runs.map((entry) => entry.alternateTeddyRangeElapsedNsMax))],
    alternateTeddyRangeElapsedNsMaxSummary: summary(runs.map((entry) => entry.alternateTeddyRangeElapsedNsMax)),
    alternateCompiledRangeCalls: [...new Set(runs.map((entry) => entry.alternateCompiledRangeCalls))],
    alternateCompiledRangeElapsedNsTotal: [...new Set(runs.map((entry) => entry.alternateCompiledRangeElapsedNsTotal))],
    alternateCompiledRangeElapsedNsTotalSummary: summary(runs.map((entry) => entry.alternateCompiledRangeElapsedNsTotal)),
    alternateCompiledRangeElapsedNsMax: [...new Set(runs.map((entry) => entry.alternateCompiledRangeElapsedNsMax))],
    alternateCompiledRangeElapsedNsMaxSummary: summary(runs.map((entry) => entry.alternateCompiledRangeElapsedNsMax)),
  };
}
