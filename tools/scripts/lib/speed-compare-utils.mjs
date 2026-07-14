import { createHash } from "node:crypto";
import { spawnSync } from "node:child_process";
import { existsSync, mkdirSync, readFileSync, readdirSync, rmSync, statSync, writeFileSync } from "node:fs";
import os from "node:os";
import path from "node:path";
import { benchmarkIsolationPlan, defaultBenchmarkIsolationResult, mergedEnv, runWithWindowsBenchmarkIsolation } from "./benchmark-isolation.mjs";
import { pairedAttributionLedgerFields, pairedEngineStats, phaseTimingResidualMs } from "./benchmark-phase-attribution.mjs";
import { identityNoiseDiagnostics } from "./benchmark-noise-diagnostics.mjs";
export { pairedAttributionLedgerFields, pairedEngineStats, phaseLeakSummaryFromRounds, phaseTimingResidualMs } from "./benchmark-phase-attribution.mjs";
export { identityNoiseDiagnostics } from "./benchmark-noise-diagnostics.mjs";

export const DEFAULT_ALTERNATES_EXPR = "re:(?i)(ERR_SYS|PME_TURN_OFF|LINK_REQ_RST|CFG_BME_EVT)";
// One owner preserves the benchmark telemetry wire contract: raw JSON serialization
// with hit retention disabled. Historical binaries may still require a capability probe.
export const IX_STATS_JSON_FLAGS = Object.freeze(["--json", "--stats-only"]);
const DEFAULT_BENCHMARK_LOCK_DIR = path.join(os.tmpdir(), "ix-zig-benchmark.lock");
const DEFAULT_STALE_BENCHMARK_LOCK_MS = 6 * 60 * 60 * 1000;
const DEFAULT_PENDING_BENCHMARK_LOCK_OWNER_GRACE_MS = 5 * 1000;
const RUNTIME_FRESHNESS_EXTENSIONS = new Set([".zig", ".c", ".h"]);
let cachedRipgrepPath = null;
const BENCHMARK_ENV_SNAPSHOT_KEYS = [
  "IX_INDEX",
  "IX_NEXUS",
  "IX_RESOURCE_PROFILE",
  "IX_STATE_DIR",
  "IX_SCAN_OPEN_TIMING",
  "IX_SCAN_INPUT_POLICY",
  "IX_LINUX_DOMINANT_ATTRIBUTION",
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
  "IX_BENCH_ISOLATION_MODE",
  "IX_BENCH_PRIORITY_CLASS",
  "IX_BENCH_AFFINITY_MODE",
  "IX_BENCH_AFFINITY_LOGICAL_CPU_COUNT",
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

export function binarySnapshot(binaryPath) {
  const resolved = path.resolve(binaryPath);
  if (!existsSync(resolved)) {
    return { path: resolved, exists: false, sizeBytes: null, sha256: null, executableSha256: null, pe: null };
  }
  const stat = statSync(resolved);
  const bytes = readFileSync(resolved);
  return {
    path: resolved,
    exists: true,
    sizeBytes: stat.size,
    sha256: fileHash(resolved),
    executableSha256: executableHash(bytes),
    pe: peSnapshot(bytes),
  };
}

function executableHash(bytes) {
  const normalized = Buffer.from(bytes);
  const pe = peLayout(normalized);
  if (pe == null) return createHash("sha256").update(normalized).digest("hex").toUpperCase();

  // PE timestamps and Zig/LLD build IDs change across equivalent rebuilds.
  // They do not describe executable search behavior, so zero them before
  // comparing benchmark candidates for identity-noise classification.
  normalized.fill(0, pe.coffTimestampOffset, pe.coffTimestampOffset + 4);
  const buildId = pe.sections.find((section) => section.name === ".buildid");
  if (buildId != null && buildId.rawPointer + buildId.rawSize <= normalized.length) {
    normalized.fill(0, buildId.rawPointer, buildId.rawPointer + buildId.rawSize);
  }
  return createHash("sha256").update(normalized).digest("hex").toUpperCase();
}

function peLayout(bytes) {
  if (bytes.length < 0x40 || bytes[0] !== 0x4d || bytes[1] !== 0x5a) return null;
  const peOffset = bytes.readUInt32LE(0x3c);
  if (peOffset + 24 > bytes.length) return null;
  if (bytes[peOffset] !== 0x50 || bytes[peOffset + 1] !== 0x45 || bytes[peOffset + 2] !== 0 || bytes[peOffset + 3] !== 0) return null;
  const sectionCount = bytes.readUInt16LE(peOffset + 6);
  const optionalHeaderSize = bytes.readUInt16LE(peOffset + 20);
  const optionalHeaderOffset = peOffset + 24;
  if (optionalHeaderOffset + optionalHeaderSize > bytes.length) return null;
  const sectionOffset = optionalHeaderOffset + optionalHeaderSize;
  const sections = [];
  for (let index = 0; index < sectionCount; index += 1) {
    const offset = sectionOffset + index * 40;
    if (offset + 40 > bytes.length) break;
    const nul = bytes.indexOf(0, offset);
    const nameEnd = nul >= offset && nul < offset + 8 ? nul : offset + 8;
    sections.push({
      name: bytes.subarray(offset, nameEnd).toString("ascii"),
      virtualSize: bytes.readUInt32LE(offset + 8),
      virtualAddress: bytes.readUInt32LE(offset + 12),
      rawSize: bytes.readUInt32LE(offset + 16),
      rawPointer: bytes.readUInt32LE(offset + 20),
    });
  }
  return {
    peOffset,
    coffTimestampOffset: peOffset + 8,
    sections,
  };
}

function peSnapshot(bytes) {
  const layout = peLayout(bytes);
  if (layout == null) return null;
  const peOffset = layout.peOffset;
  const machine = bytes.readUInt16LE(peOffset + 4);
  const sectionCount = bytes.readUInt16LE(peOffset + 6);
  const timestamp = bytes.readUInt32LE(peOffset + 8);
  const optionalHeaderSize = bytes.readUInt16LE(peOffset + 20);
  const characteristics = bytes.readUInt16LE(peOffset + 22);
  const optionalHeaderOffset = peOffset + 24;
  const optionalMagic = bytes.readUInt16LE(optionalHeaderOffset);
  return {
    machine,
    sectionCount,
    timestamp,
    optionalMagic,
    characteristics,
    sections: layout.sections,
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
  const env = mergedEnv(options.env ?? {});
  const isolationPlan = benchmarkIsolationPlan(env);
  if (process.platform === "win32" && isolationPlan.mode === "enforce" && isolationPlan.supported) {
    const isolated = runWithWindowsBenchmarkIsolation(command, commandArgs, {
      cwd: options.cwd ?? process.cwd(),
      env: options.env ?? {},
      captureStdout: true,
      captureStderr: true,
      maxBuffer: options.maxBuffer ?? 128 * 1024 * 1024,
    }, isolationPlan, { allowedCodes: [0] });
    return {
      command: [command, ...commandArgs].join(" "),
      exitCode: isolated.status == null ? null : isolated.status,
      stdout: isolated.stdout,
      stderr: isolated.stderr,
      durationMs: isolated.durationMs,
      processMetrics: isolated.processMetrics ?? null,
      benchmarkIsolation: isolated.benchmarkIsolation ?? defaultBenchmarkIsolationResult(isolationPlan),
    };
  }
  const result = spawnSync(command, commandArgs, {
    cwd: options.cwd ?? process.cwd(),
    encoding: "utf8",
    env,
    maxBuffer: options.maxBuffer ?? 128 * 1024 * 1024,
    windowsHide: true,
  });
  return {
    command: [command, ...commandArgs].join(" "),
    exitCode: result.status == null ? null : result.status,
    stdout: result.stdout ?? "",
    stderr: result.stderr ?? "",
    durationMs: Number(process.hrtime.bigint() - started) / 1_000_000,
    processMetrics: null,
    benchmarkIsolation: defaultBenchmarkIsolationResult(isolationPlan),
  };
}

export function requireOk(result, label) {
  if (result.exitCode == null || result.exitCode !== 0) {
    throw new Error(`${label} failed (${result.exitCode ?? "not-started"}): ${result.stderr || result.stdout}`);
  }
  return result;
}

/**
 * Resolves ripgrep to an executable path before Windows ProcessStartInfo sees it.
 * A bare `rg` may work through a shell but is not a reliable FileName for the
 * isolated helper; accepting that miss as exit code 0 corrupts timing evidence.
 */
export function resolveRipgrepPath() {
  if (cachedRipgrepPath != null) return cachedRipgrepPath;
  const configured = process.env.IX_RG_PATH?.trim();
  if (configured) {
    if (!existsSync(configured)) throw new Error(`IX_RG_PATH does not exist: ${configured}`);
    cachedRipgrepPath = configured;
    return cachedRipgrepPath;
  }
  const resolver = process.platform === "win32" ? "where.exe" : "which";
  const result = spawnSync(resolver, ["rg"], { encoding: "utf8", windowsHide: true });
  if (result.error || result.status !== 0) {
    throw new Error(`ripgrep executable not found; set IX_RG_PATH${result.stderr ? `: ${result.stderr.trim()}` : ""}`);
  }
  const candidate = String(result.stdout ?? "").split(/\r?\n/).map((line) => line.trim()).find(Boolean);
  if (!candidate || !existsSync(candidate)) throw new Error(`ripgrep resolver returned no executable path: ${candidate ?? "empty"}`);
  cachedRipgrepPath = candidate;
  return cachedRipgrepPath;
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

export function sleepMs(durationMs) {
  if (!Number.isFinite(durationMs) || durationMs <= 0) return;
  Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, durationMs);
}

/// Returns the inter-pair settle delay (ms) from env or explicit override.
/// Settle lets OS state (Defender real-time scan completion, page cache
/// settling, CPU thermal headroom) return to baseline between the two
/// launches of a paired sample. Without it, the second launch inherits
/// disturbed state from the first, producing positional skew that inflates
/// identity-control drift and masks sub-2% engine signals.
export function interPairSettleMs(explicit) {
  if (Number.isFinite(explicit) && explicit >= 0) return explicit;
  const envValue = Number(process.env.IX_INTER_PAIR_SETTLE_MS);
  return Number.isFinite(envValue) && envValue >= 0 ? envValue : 0;
}

function reclaimStaleBenchmarkLock(lockDir, { staleLockMs, pendingOwnerGraceMs }) {
  const owner = readBenchmarkLockOwner(lockDir);
  const ownerPid = Number(owner?.pid);
  if (Number.isInteger(ownerPid) && ownerPid > 0) {
    if (processIsAlive(ownerPid)) return { reclaimed: false, owner, reason: "owner_pid_alive" };
    rmSync(lockDir, { recursive: true, force: true });
    return { reclaimed: true, owner, reason: "owner_pid_not_alive" };
  }

  const ageMs = benchmarkLockAgeMs(lockDir);
  if (Number.isFinite(ageMs) && ageMs > pendingOwnerGraceMs) {
    rmSync(lockDir, { recursive: true, force: true });
    return { reclaimed: true, owner, reason: "owner_missing_or_invalid_after_grace" };
  }
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
  pendingOwnerGraceMs = Number(process.env.IX_BENCHMARK_LOCK_PENDING_OWNER_GRACE_MS ?? DEFAULT_PENDING_BENCHMARK_LOCK_OWNER_GRACE_MS),
} = {}) {
  try {
    mkdirSync(lockDir);
  } catch (err) {
    if (err?.code === "EEXIST") {
      const validStaleLockMs = Number.isFinite(staleLockMs) && staleLockMs >= 0 ? staleLockMs : DEFAULT_STALE_BENCHMARK_LOCK_MS;
      const validPendingOwnerGraceMs = Number.isFinite(pendingOwnerGraceMs) && pendingOwnerGraceMs >= 0
        ? pendingOwnerGraceMs
        : DEFAULT_PENDING_BENCHMARK_LOCK_OWNER_GRACE_MS;
      let reclaim = reclaimStaleBenchmarkLock(lockDir, {
        staleLockMs: validStaleLockMs,
        pendingOwnerGraceMs: validPendingOwnerGraceMs,
      });
      if (!reclaim.reclaimed && reclaim.reason === "owner_missing_or_invalid" && validPendingOwnerGraceMs > 0) {
        sleepMs(Math.min(validPendingOwnerGraceMs, 250));
        reclaim = reclaimStaleBenchmarkLock(lockDir, {
          staleLockMs: validStaleLockMs,
          pendingOwnerGraceMs: validPendingOwnerGraceMs,
        });
      }
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

function newestRuntimeInput(root) {
  let newest = null;
  const visitFile = (filePath) => {
    const stat = statSync(filePath);
    if (!newest || stat.mtimeMs > newest.mtimeMs) {
      newest = { path: filePath, mtimeMs: stat.mtimeMs, mtime: stat.mtime.toISOString() };
    }
  };
  const visitDir = (dirPath) => {
    for (const entry of readdirSync(dirPath, { withFileTypes: true })) {
      const fullPath = path.join(dirPath, entry.name);
      if (entry.isDirectory()) {
        visitDir(fullPath);
      } else if (entry.isFile() && RUNTIME_FRESHNESS_EXTENSIONS.has(path.extname(entry.name))) {
        visitFile(fullPath);
      }
    }
  };
  const srcDir = path.join(root, "src");
  if (existsSync(srcDir)) visitDir(srcDir);
  for (const fileName of ["build.zig", "build.zig.zon"]) {
    const filePath = path.join(root, fileName);
    if (existsSync(filePath)) visitFile(filePath);
  }
  return newest;
}

export function assertRepoBinaryFresh({ root, repoIx, label = "repo IX" } = {}) {
  if (!root) throw new Error("assertRepoBinaryFresh requires root");
  if (!repoIx) throw new Error("assertRepoBinaryFresh requires repoIx");
  if (!existsSync(repoIx)) throw new Error(`${label} not found: ${repoIx}`);
  const binaryStat = statSync(repoIx);
  const newestInput = newestRuntimeInput(root);
  if (newestInput && binaryStat.mtimeMs + 1 < newestInput.mtimeMs) {
    throw new Error(
      `${label} is stale: ${repoIx} mtime ${binaryStat.mtime.toISOString()} is older than ${newestInput.path} mtime ${newestInput.mtime}. Run the ReleaseFast build before benchmarking.`,
    );
  }
  return {
    ok: true,
    binaryPath: repoIx,
    binaryMtime: binaryStat.mtime.toISOString(),
    newestRuntimeInput: newestInput,
  };
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

function nsSummaryMedianToMs(summaryValue) {
  const ns = optionalNumber(summaryValue?.median);
  return ns == null ? null : ns / 1_000_000;
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

function median(values) {
  const finite = finiteNumbers(values).sort((left, right) => left - right);
  if (finite.length === 0) return null;
  const middle = Math.floor(finite.length / 2);
  return finite.length % 2 === 1 ? finite[middle] : (finite[middle - 1] + finite[middle]) / 2;
}

function improvementPct(baseline, candidate) {
  const baselineNumber = Number(baseline);
  const candidateNumber = Number(candidate);
  if (!Number.isFinite(baselineNumber) || !Number.isFinite(candidateNumber) || baselineNumber === 0) return null;
  return ((baselineNumber - candidateNumber) / baselineNumber) * 100;
}

export function orderStratifiedEngineStats(
  baselineSamples,
  candidateSamples,
  pairOrder,
  { baselineLabel = "baseline", candidateLabel = "candidate" } = {},
) {
  const firstStart = { baseline: [], candidate: [] };
  const secondStart = { baseline: [], candidate: [] };
  const count = Math.min(baselineSamples?.length ?? 0, candidateSamples?.length ?? 0, pairOrder?.length ?? 0);
  for (let index = 0; index < count; index += 1) {
    const order = String(pairOrder[index] ?? "");
    if (order.startsWith(`${baselineLabel},`)) {
      firstStart.baseline.push(baselineSamples[index]?.engineMs);
      secondStart.candidate.push(candidateSamples[index]?.engineMs);
    } else if (order.startsWith(`${candidateLabel},`)) {
      firstStart.candidate.push(candidateSamples[index]?.engineMs);
      secondStart.baseline.push(baselineSamples[index]?.engineMs);
    }
  }

  const firstStartBaselineMedianMs = median(firstStart.baseline);
  const firstStartCandidateMedianMs = median(firstStart.candidate);
  const secondStartBaselineMedianMs = median(secondStart.baseline);
  const secondStartCandidateMedianMs = median(secondStart.candidate);
  const firstStartCandidateImprovementPct = improvementPct(firstStartBaselineMedianMs, firstStartCandidateMedianMs);
  const secondStartCandidateImprovementPct = improvementPct(secondStartBaselineMedianMs, secondStartCandidateMedianMs);
  const finiteImprovements = finiteNumbers([firstStartCandidateImprovementPct, secondStartCandidateImprovementPct]);

  return {
    baselineLabel,
    candidateLabel,
    count,
    firstStartSampleCount: Math.min(firstStart.baseline.length, firstStart.candidate.length),
    secondStartSampleCount: Math.min(secondStart.baseline.length, secondStart.candidate.length),
    firstStartBaselineMedianMs,
    firstStartCandidateMedianMs,
    firstStartCandidateImprovementPct,
    secondStartBaselineMedianMs,
    secondStartCandidateMedianMs,
    secondStartCandidateImprovementPct,
    allStartPositionsNetPositive: finiteImprovements.length === 2 && finiteImprovements.every((value) => value >= 0),
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

function routeKindSummary(route) {
  return {
    fullScan: routeValuesAreObserved(route?.fullScan),
    teddy: routeValuesAreObserved(route?.teddy),
    pcre: routeValuesAreObserved(route?.pcre),
    compiled: routeValuesAreObserved(route?.compiled),
  };
}

export function routeParityEvaluation(baselineLane, candidateLane) {
  const baselineRoute = routeSummaryForLane(baselineLane);
  const candidateRoute = routeSummaryForLane(candidateLane);
  const baselineRouteKinds = routeKindSummary(baselineRoute);
  const candidateRouteKinds = routeKindSummary(candidateRoute);
  const baselineObserved = routeSummaryObserved(baselineRoute);
  const candidateObserved = routeSummaryObserved(candidateRoute);
  const comparable = baselineObserved && candidateObserved;
  const parity = comparable ? JSON.stringify(baselineRouteKinds) === JSON.stringify(candidateRouteKinds) : null;
  const cardinalityParity = comparable ? JSON.stringify(baselineRoute) === JSON.stringify(candidateRoute) : null;
  const status = comparable
    ? (parity ? "matched" : "mismatch")
    : (!baselineObserved && candidateObserved
        ? "baseline_unsupported"
        : (baselineObserved && !candidateObserved ? "candidate_unsupported" : "both_unsupported"));
  return {
    baselineRoute,
    candidateRoute,
    baselineRouteKinds,
    candidateRouteKinds,
    baselineObserved,
    candidateObserved,
    comparable,
    parity,
    cardinalityParity,
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
    baselineAlternatePcreRangeElapsedNsMedian: baseline?.alternatePcreRangeElapsedNsMaxSummary?.median ?? null,
    candidateAlternatePcreRangeElapsedNsMedian: candidate?.alternatePcreRangeElapsedNsMaxSummary?.median ?? null,
    baselineAlternateTeddyRangeElapsedNsMedian: baseline?.alternateTeddyRangeElapsedNsMaxSummary?.median ?? null,
    candidateAlternateTeddyRangeElapsedNsMedian: candidate?.alternateTeddyRangeElapsedNsMaxSummary?.median ?? null,
    baselineAlternateCompiledRangeElapsedNsMedian: baseline?.alternateCompiledRangeElapsedNsMaxSummary?.median ?? null,
    candidateAlternateCompiledRangeElapsedNsMedian: candidate?.alternateCompiledRangeElapsedNsMaxSummary?.median ?? null,
  };
}

function stageTimingMedianFields(baseline, candidate) {
  const baselineFilesScanned = Array.isArray(baseline?.filesScanned) ? baseline.filesScanned : null;
  const candidateFilesScanned = Array.isArray(candidate?.filesScanned) ? candidate.filesScanned : null;
  const filesScannedParity = baselineFilesScanned != null && candidateFilesScanned != null
    ? JSON.stringify(baselineFilesScanned) === JSON.stringify(candidateFilesScanned)
    : null;
  const baselineFilesDiscovered = Array.isArray(baseline?.filesDiscovered) ? baseline.filesDiscovered : null;
  const candidateFilesDiscovered = Array.isArray(candidate?.filesDiscovered) ? candidate.filesDiscovered : null;
  const filesDiscoveredParity = baselineFilesDiscovered != null && candidateFilesDiscovered != null
    ? JSON.stringify(baselineFilesDiscovered) === JSON.stringify(candidateFilesDiscovered)
    : null;
  const baselineFilesSkipped = Array.isArray(baseline?.filesSkipped) ? baseline.filesSkipped : null;
  const candidateFilesSkipped = Array.isArray(candidate?.filesSkipped) ? candidate.filesSkipped : null;
  const filesSkippedParity = baselineFilesSkipped != null && candidateFilesSkipped != null
    ? JSON.stringify(baselineFilesSkipped) === JSON.stringify(candidateFilesSkipped)
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
    baselineScanOpenPathMedianMs: baseline?.scanOpenPathSummary?.median ?? null,
    candidateScanOpenPathMedianMs: candidate?.scanOpenPathSummary?.median ?? null,
    baselineScanOpenSyscallMedianMs: baseline?.scanOpenSyscallSummary?.median ?? null,
    candidateScanOpenSyscallMedianMs: candidate?.scanOpenSyscallSummary?.median ?? null,
    baselineScanFileMedianMs: baseline?.scanFileSummary?.median ?? null,
    candidateScanFileMedianMs: candidate?.scanFileSummary?.median ?? null,
    baselineScanFileMmapMedianMs: baseline?.scanFileMmapSummary?.median ?? null,
    candidateScanFileMmapMedianMs: candidate?.scanFileMmapSummary?.median ?? null,
    baselineScanFileFastCountMedianMs: baseline?.scanFileFastCountSummary?.median ?? null,
    candidateScanFileFastCountMedianMs: candidate?.scanFileFastCountSummary?.median ?? null,
    baselineScanFileFastCountWallMedianMs: nsSummaryMedianToMs(baseline?.byteShardRangeElapsedNsMaxSummary),
    candidateScanFileFastCountWallMedianMs: nsSummaryMedianToMs(candidate?.byteShardRangeElapsedNsMaxSummary),
    baselineScanFileLineScanMedianMs: baseline?.scanFileLineScanSummary?.median ?? null,
    candidateScanFileLineScanMedianMs: candidate?.scanFileLineScanSummary?.median ?? null,
    baselineScanOpenMsPerFileMedian: baseline?.scanOpenMsPerFileSummary?.median ?? null,
    candidateScanOpenMsPerFileMedian: candidate?.scanOpenMsPerFileSummary?.median ?? null,
    baselineScanOpenPathMsPerFileMedian: baseline?.scanOpenPathMsPerFileSummary?.median ?? null,
    candidateScanOpenPathMsPerFileMedian: candidate?.scanOpenPathMsPerFileSummary?.median ?? null,
    baselineScanOpenSyscallMsPerFileMedian: baseline?.scanOpenSyscallMsPerFileSummary?.median ?? null,
    candidateScanOpenSyscallMsPerFileMedian: candidate?.scanOpenSyscallMsPerFileSummary?.median ?? null,
    baselineScanFileMsPerFileMedian: baseline?.scanFileMsPerFileSummary?.median ?? null,
    candidateScanFileMsPerFileMedian: candidate?.scanFileMsPerFileSummary?.median ?? null,
    baselineFilesScanned,
    candidateFilesScanned,
    filesScannedParity,
    baselineFilesDiscovered,
    candidateFilesDiscovered,
    filesDiscoveredParity,
    baselineFilesDiscoveredMedian: baseline?.filesDiscoveredSummary?.median ?? null,
    candidateFilesDiscoveredMedian: candidate?.filesDiscoveredSummary?.median ?? null,
    baselineFilesSkipped,
    candidateFilesSkipped,
    filesSkippedParity,
    baselineFilesSkippedMedian: baseline?.filesSkippedSummary?.median ?? null,
    candidateFilesSkippedMedian: candidate?.filesSkippedSummary?.median ?? null,
    baselineInputRootsMedian: baseline?.inputRootsSummary?.median ?? null,
    candidateInputRootsMedian: candidate?.inputRootsSummary?.median ?? null,
    baselineEffectiveRootsMedian: baseline?.effectiveRootsSummary?.median ?? null,
    candidateEffectiveRootsMedian: candidate?.effectiveRootsSummary?.median ?? null,
    baselinePrunedRootsMedian: baseline?.prunedRootsSummary?.median ?? null,
    candidatePrunedRootsMedian: candidate?.prunedRootsSummary?.median ?? null,
    baselineOverlapPrunedRootsMedian: baseline?.overlapPrunedRootsSummary?.median ?? null,
    candidateOverlapPrunedRootsMedian: candidate?.overlapPrunedRootsSummary?.median ?? null,
    baselineDiscoveredDuplicatePathsMedian: baseline?.discoveredDuplicatePathsSummary?.median ?? null,
    candidateDiscoveredDuplicatePathsMedian: candidate?.discoveredDuplicatePathsSummary?.median ?? null,
    baselineIgnoreFilesLoadedMedian: baseline?.ignoreFilesLoadedSummary?.median ?? null,
    candidateIgnoreFilesLoadedMedian: candidate?.ignoreFilesLoadedSummary?.median ?? null,
    baselineHiddenEntriesSkippedMedian: baseline?.hiddenEntriesSkippedSummary?.median ?? null,
    candidateHiddenEntriesSkippedMedian: candidate?.hiddenEntriesSkippedSummary?.median ?? null,
    baselineIgnoredEntriesSkippedMedian: baseline?.ignoredEntriesSkippedSummary?.median ?? null,
    candidateIgnoredEntriesSkippedMedian: candidate?.ignoredEntriesSkippedSummary?.median ?? null,
    baselineAccessErrorsTotalMedian: baseline?.accessErrorsTotalSummary?.median ?? null,
    candidateAccessErrorsTotalMedian: candidate?.accessErrorsTotalSummary?.median ?? null,
    baselineDiscoveryAccessErrorsMedian: baseline?.discoveryAccessErrorsSummary?.median ?? null,
    candidateDiscoveryAccessErrorsMedian: candidate?.discoveryAccessErrorsSummary?.median ?? null,
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
  const engineImproved = Number(improvementPct) > 0 && Number(pairedImprovementMedianPct) > 0;
  const teddyImproved = routeScore?.teddyRouteObserved === true &&
    routeScore?.teddyRouteNetPositive === true &&
    Number.isFinite(teddyMedianPct) &&
    teddyMedianPct > 0;
  const teddyRegressed = routeScore?.teddyRouteObserved === true &&
    routeScore?.teddyRouteNetPositive !== true &&
    Number.isFinite(teddyMedianPct) &&
    teddyMedianPct < 0;
  const targetPhase = [
    ["scanWork", scanWorkPct],
    ["scan", scanPct],
    ["discover", discoverPct],
  ].find(([, value]) => Number.isFinite(value) && value < 0)?.[0] ?? null;

  return {
    mixedKernelEngineSignal: teddyImproved && engineRegressed,
    repairDirective: teddyImproved && engineRegressed
      ? "preserve_teddy_gain_repair_whole_engine"
      : (engineRegressed ? "repair_whole_engine_regression" : (engineImproved && teddyRegressed ? "preserve_engine_gain_repair_teddy_route" : null)),
    repairTargetPhase: engineImproved && teddyRegressed ? "teddyRoute" : targetPhase,
  };
}

function pairedImprovementConfidenceFields(pairedEngine, requiredImprovementPct) {
  const ci = pairedEngine?.candidateImprovementPctBootstrap95 ?? null;
  const lower95Pct = Number(ci?.lower);
  const upper95Pct = Number(ci?.upper);
  return {
    pairedImprovementBootstrap95: ci,
    pairedImprovementLower95Pct: Number.isFinite(lower95Pct) ? lower95Pct : null,
    pairedImprovementUpper95Pct: Number.isFinite(upper95Pct) ? upper95Pct : null,
    pairedImprovementConclusiveAboveTarget:
      Number.isFinite(requiredImprovementPct) && Number.isFinite(lower95Pct)
        ? lower95Pct >= requiredImprovementPct
        : null,
    pairedImprovementConclusiveBelowZero:
      Number.isFinite(upper95Pct)
        ? upper95Pct < 0
        : null,
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
  const pairedConfidence = pairedImprovementConfidenceFields(pairedEngine, requiredImprovementPct);
  const routeParityAcceptable = comparison?.routeParityAcceptable ?? (comparison?.routeParity === true);
  const orderStratifiedPairedEngineAcceptable =
    comparison?.orderStratifiedEngine?.allStartPositionsNetPositive === true &&
    Number(comparison?.orderStratifiedEngine?.firstStartCandidateImprovementPct) >= requiredImprovementPct &&
    Number(comparison?.orderStratifiedEngine?.secondStartCandidateImprovementPct) >= requiredImprovementPct;
  const pairedEngineAcceptable =
    Number.isFinite(pairedImprovementMedianPct) &&
    pairedImprovementMedianPct >= requiredImprovementPct &&
    pairedConfidence.pairedImprovementConclusiveAboveTarget === true;
  const pairedWinAcceptable =
    Number(pairedEngine?.candidateWinRate) > 0.5 || orderStratifiedPairedEngineAcceptable;
  const rawEngineAcceptable = Number.isFinite(improvementPct) && improvementPct >= requiredImprovementPct;
  const engineAcceptable = rawEngineAcceptable || orderStratifiedPairedEngineAcceptable;
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
    installedPeakWorkingSetBytesMedian: comparison?.installedPeakWorkingSetBytesMedian ?? null,
    repoPeakWorkingSetBytesMedian: comparison?.repoPeakWorkingSetBytesMedian ?? null,
    installedPeakWorkingSetBytesMax: comparison?.installedPeakWorkingSetBytesMax ?? null,
    repoPeakWorkingSetBytesMax: comparison?.repoPeakWorkingSetBytesMax ?? null,
    installedScanWorkMedianMs: comparison?.installedScanWorkMedianMs ?? null,
    repoScanWorkMedianMs: comparison?.repoScanWorkMedianMs ?? null,
    installedScanOpenMedianMs: comparison?.installedScanOpenMedianMs ?? null,
    repoScanOpenMedianMs: comparison?.repoScanOpenMedianMs ?? null,
    installedScanOpenPathMedianMs: comparison?.installedScanOpenPathMedianMs ?? null,
    repoScanOpenPathMedianMs: comparison?.repoScanOpenPathMedianMs ?? null,
    installedScanOpenSyscallMedianMs: comparison?.installedScanOpenSyscallMedianMs ?? null,
    repoScanOpenSyscallMedianMs: comparison?.repoScanOpenSyscallMedianMs ?? null,
    installedScanFileMedianMs: comparison?.installedScanFileMedianMs ?? null,
    repoScanFileMedianMs: comparison?.repoScanFileMedianMs ?? null,
    installedScanFileMmapMedianMs: comparison?.installedScanFileMmapMedianMs ?? null,
    repoScanFileMmapMedianMs: comparison?.repoScanFileMmapMedianMs ?? null,
    installedScanFileFastCountMedianMs: comparison?.installedScanFileFastCountMedianMs ?? null,
    repoScanFileFastCountMedianMs: comparison?.repoScanFileFastCountMedianMs ?? null,
    installedScanFileLineScanMedianMs: comparison?.installedScanFileLineScanMedianMs ?? null,
    repoScanFileLineScanMedianMs: comparison?.repoScanFileLineScanMedianMs ?? null,
    installedAlternateFullScanCallsMedian: comparison?.installedAlternateFullScanCallsMedian ?? null,
    repoAlternateFullScanCallsMedian: comparison?.repoAlternateFullScanCallsMedian ?? null,
    installedAlternateFullScanBytesMedian: comparison?.installedAlternateFullScanBytesMedian ?? null,
    repoAlternateFullScanBytesMedian: comparison?.repoAlternateFullScanBytesMedian ?? null,
    installedAlternateFullScanMatchesMedian: comparison?.installedAlternateFullScanMatchesMedian ?? null,
    repoAlternateFullScanMatchesMedian: comparison?.repoAlternateFullScanMatchesMedian ?? null,
    installedAlternateTeddyRangeElapsedNsMedian: comparison?.installedAlternateTeddyRangeElapsedNsMedian ?? null,
    repoAlternateTeddyRangeElapsedNsMedian: comparison?.repoAlternateTeddyRangeElapsedNsMedian ?? null,
    repoEngineImprovementPct: improvementPct,
    repoEngineAcceptable: engineAcceptable,
    repoRawEngineAcceptable: rawEngineAcceptable,
    repoVsInstalledEngineRatio:
      Number(comparison?.installedEngineMedianMs) !== 0
        ? Number(comparison?.repoEngineMedianMs) / Number(comparison?.installedEngineMedianMs)
        : null,
    repoEngineDeltaMs: Number(comparison?.repoEngineMedianMs) - Number(comparison?.installedEngineMedianMs),
    pairedRepoWinRate: pairedEngine?.candidateWinRate,
    pairedRepoImprovementMedianPct: Number.isFinite(pairedImprovementMedianPct) ? pairedImprovementMedianPct : null,
    pairedRepoImprovementMeanPct: Number.isFinite(pairedImprovementMeanPct) ? pairedImprovementMeanPct : null,
    ...pairedConfidence,
    pairedRepoOrderStratifiedAcceptable: orderStratifiedPairedEngineAcceptable,
    pairedRepoEngineAcceptable: pairedEngineAcceptable || orderStratifiedPairedEngineAcceptable,
    pairedRepoWinAcceptable: pairedWinAcceptable,
    orderStratifiedFirstStartSampleCount: comparison?.orderStratifiedEngine?.firstStartSampleCount ?? null,
    orderStratifiedSecondStartSampleCount: comparison?.orderStratifiedEngine?.secondStartSampleCount ?? null,
    orderStratifiedFirstStartRepoImprovementPct: comparison?.orderStratifiedEngine?.firstStartCandidateImprovementPct ?? null,
    orderStratifiedSecondStartRepoImprovementPct: comparison?.orderStratifiedEngine?.secondStartCandidateImprovementPct ?? null,
    orderStratifiedAllStartPositionsNetPositive: comparison?.orderStratifiedEngine?.allStartPositionsNetPositive ?? null,
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
          engineAcceptable &&
          pairedEngineAcceptable &&
          pairedWinAcceptable,
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
            installedScanOpenPathMedianMs: score?.installedScanOpenPathMedianMs,
            repoScanOpenPathMedianMs: score?.repoScanOpenPathMedianMs,
            installedScanOpenSyscallMedianMs: score?.installedScanOpenSyscallMedianMs,
            repoScanOpenSyscallMedianMs: score?.repoScanOpenSyscallMedianMs,
            installedScanFileMedianMs: score?.installedScanFileMedianMs,
            repoScanFileMedianMs: score?.repoScanFileMedianMs,
            installedScanFileMmapMedianMs: score?.installedScanFileMmapMedianMs,
            repoScanFileMmapMedianMs: score?.repoScanFileMmapMedianMs,
            installedScanFileFastCountMedianMs: score?.installedScanFileFastCountMedianMs,
            repoScanFileFastCountMedianMs: score?.repoScanFileFastCountMedianMs,
            installedScanFileLineScanMedianMs: score?.installedScanFileLineScanMedianMs,
            repoScanFileLineScanMedianMs: score?.repoScanFileLineScanMedianMs,
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
            orderStratifiedFirstStartRepoImprovementPct: score?.orderStratifiedFirstStartRepoImprovementPct,
            orderStratifiedSecondStartRepoImprovementPct: score?.orderStratifiedSecondStartRepoImprovementPct,
            orderStratifiedAllStartPositionsNetPositive: score?.orderStratifiedAllStartPositionsNetPositive,
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
    baselineExecutableSha256: binaries?.installed?.executableSha256 ?? null,
    candidateExecutableSha256: binaries?.repo?.executableSha256 ?? null,
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
      baselinePeakWorkingSetBytesMedian: comparison?.installedPeakWorkingSetBytesMedian ?? null,
      candidatePeakWorkingSetBytesMedian: comparison?.repoPeakWorkingSetBytesMedian ?? null,
      baselinePeakWorkingSetBytesMax: comparison?.installedPeakWorkingSetBytesMax ?? null,
      candidatePeakWorkingSetBytesMax: comparison?.repoPeakWorkingSetBytesMax ?? null,
      baselineScanWorkMedianMs: comparison?.installedScanWorkMedianMs ?? null,
      candidateScanWorkMedianMs: comparison?.repoScanWorkMedianMs ?? null,
      baselineScanOpenMedianMs: comparison?.installedScanOpenMedianMs ?? null,
      candidateScanOpenMedianMs: comparison?.repoScanOpenMedianMs ?? null,
      baselineScanOpenPathMedianMs: comparison?.installedScanOpenPathMedianMs ?? null,
      candidateScanOpenPathMedianMs: comparison?.repoScanOpenPathMedianMs ?? null,
      baselineScanOpenSyscallMedianMs: comparison?.installedScanOpenSyscallMedianMs ?? null,
      candidateScanOpenSyscallMedianMs: comparison?.repoScanOpenSyscallMedianMs ?? null,
      baselineScanFileMedianMs: comparison?.installedScanFileMedianMs ?? null,
      candidateScanFileMedianMs: comparison?.repoScanFileMedianMs ?? null,
      baselineScanFileMmapMedianMs: comparison?.installedScanFileMmapMedianMs ?? null,
      candidateScanFileMmapMedianMs: comparison?.repoScanFileMmapMedianMs ?? null,
      baselineScanFileFastCountMedianMs: comparison?.installedScanFileFastCountMedianMs ?? null,
      candidateScanFileFastCountMedianMs: comparison?.repoScanFileFastCountMedianMs ?? null,
      baselineScanFileLineScanMedianMs: comparison?.installedScanFileLineScanMedianMs ?? null,
      candidateScanFileLineScanMedianMs: comparison?.repoScanFileLineScanMedianMs ?? null,
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
      orderStratifiedFirstStartSampleCount: score?.orderStratifiedFirstStartSampleCount,
      orderStratifiedSecondStartSampleCount: score?.orderStratifiedSecondStartSampleCount,
      orderStratifiedFirstStartCandidateImprovementPct: score?.orderStratifiedFirstStartRepoImprovementPct,
      orderStratifiedSecondStartCandidateImprovementPct: score?.orderStratifiedSecondStartRepoImprovementPct,
      orderStratifiedAllStartPositionsNetPositive: score?.orderStratifiedAllStartPositionsNetPositive,
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
  orderStratifiedEngine,
  historyEngineMedianMs,
  currentEngineMedianMs,
} = {}) {
  const pairedImprovementMedianPct = Number(pairedEngine?.candidateImprovementPctSummary?.median);
  const pairedImprovementMeanPct = Number(pairedEngine?.candidateImprovementPctSummary?.mean);
  const pairedAttribution = pairedAttributionLedgerFields(pairedEngine ?? null);
  const routeScore = teddyRouteScoreFields(pairedAttribution);
  const pairedConfidence = pairedImprovementConfidenceFields(
    pairedEngine,
    sameBinary ? null : minPreviousBuildImprovementPct,
  );
  const requiredImprovementPct = sameBinary ? null : minPreviousBuildImprovementPct;
  const orderStratifiedPairedEngineAcceptable =
    orderStratifiedEngine?.allStartPositionsNetPositive === true &&
    Number(orderStratifiedEngine?.firstStartCandidateImprovementPct) >= requiredImprovementPct &&
    Number(orderStratifiedEngine?.secondStartCandidateImprovementPct) >= requiredImprovementPct;
  const pairedWinAcceptable =
    Number(pairedEngine?.candidateWinRate) > 0.5 || orderStratifiedPairedEngineAcceptable;
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
      requiredImprovementPct,
      historyEngineMedianMs: historyEngineMedianMs ?? null,
      currentEngineMedianMs: currentEngineMedianMs ?? null,
      currentEngineImprovementPct: improvementPct,
      currentVsHistoryEngineRatio: ratio,
      currentEngineDeltaMs: deltaMs,
    pairedCurrentWinRate: pairedEngine?.candidateWinRate,
    pairedCurrentImprovementMedianPct: Number.isFinite(pairedImprovementMedianPct) ? pairedImprovementMedianPct : null,
    pairedCurrentImprovementMeanPct: Number.isFinite(pairedImprovementMeanPct) ? pairedImprovementMeanPct : null,
    ...pairedConfidence,
    orderStratifiedFirstStartSampleCount: orderStratifiedEngine?.firstStartSampleCount ?? null,
    orderStratifiedSecondStartSampleCount: orderStratifiedEngine?.secondStartSampleCount ?? null,
    orderStratifiedFirstStartCurrentImprovementPct: orderStratifiedEngine?.firstStartCandidateImprovementPct ?? null,
    orderStratifiedSecondStartCurrentImprovementPct: orderStratifiedEngine?.secondStartCandidateImprovementPct ?? null,
    orderStratifiedAllStartPositionsNetPositive: orderStratifiedEngine?.allStartPositionsNetPositive ?? null,
    pairedCurrentOrderStratifiedAcceptable: orderStratifiedPairedEngineAcceptable,
    pairedCurrentWinAcceptable: pairedWinAcceptable,
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
          pairedConfidence.pairedImprovementConclusiveAboveTarget === true &&
          pairedWinAcceptable &&
          matchParity === true &&
          (routeParityAcceptable ?? (routeParity === true)) === true,
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
      baselineExecutableSha256: comparison.executableSha256 ?? null,
      candidateSha256: comparison.current?.sha256 ?? null,
      candidateExecutableSha256: comparison.current?.executableSha256 ?? null,
      binaryRelation: comparison.relation,
      evidenceAuthority: comparison.score?.evidenceAuthority ?? comparison.evidenceAuthority,
      requiredImprovementPct: comparison.score?.requiredImprovementPct ?? comparison.minPreviousBuildImprovementPct,
      baselineEngineMedianMs: comparison.score?.historyEngineMedianMs ?? comparison.historyEngineMedianMs ?? comparison.historical?.engineSummary?.median ?? null,
      candidateEngineMedianMs: comparison.score?.currentEngineMedianMs ?? comparison.currentEngineMedianMs ?? comparison.current?.engineSummary?.median ?? null,
      engineImprovementPct: comparison.score?.currentEngineImprovementPct ?? comparison.currentEngineImprovementPct,
      engineRatio: comparison.score?.currentVsHistoryEngineRatio ?? comparison.currentVsHistoryEngineRatio,
      engineDeltaMs: comparison.score?.currentEngineDeltaMs ?? comparison.currentEngineDeltaMs,
    baselinePeakWorkingSetBytesMedian: comparison.historical?.peakWorkingSetBytesSummary?.median ?? null,
    candidatePeakWorkingSetBytesMedian: comparison.current?.peakWorkingSetBytesSummary?.median ?? null,
    baselinePeakWorkingSetBytesMax: comparison.historical?.peakWorkingSetBytesSummary?.max ?? null,
    candidatePeakWorkingSetBytesMax: comparison.current?.peakWorkingSetBytesSummary?.max ?? null,
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
    pairedCandidateImprovementLower95Pct:
      comparison.score?.pairedImprovementLower95Pct ??
      comparison.pairedEngine?.candidateImprovementPctBootstrap95?.lower ??
      null,
    pairedCandidateImprovementUpper95Pct:
      comparison.score?.pairedImprovementUpper95Pct ??
      comparison.pairedEngine?.candidateImprovementPctBootstrap95?.upper ??
      null,
    orderStratifiedFirstStartSampleCount: comparison.score?.orderStratifiedFirstStartSampleCount,
    orderStratifiedSecondStartSampleCount: comparison.score?.orderStratifiedSecondStartSampleCount,
    orderStratifiedFirstStartCandidateImprovementPct: comparison.score?.orderStratifiedFirstStartCurrentImprovementPct,
    orderStratifiedSecondStartCandidateImprovementPct: comparison.score?.orderStratifiedSecondStartCurrentImprovementPct,
    orderStratifiedAllStartPositionsNetPositive: comparison.score?.orderStratifiedAllStartPositionsNetPositive,
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
    scanSplitTelemetryEnabled: comparison.scanSplitTelemetryEnabled === true,
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
      orderStratifiedFirstStartCurrentImprovementPct: comparison.score?.orderStratifiedFirstStartCurrentImprovementPct,
      orderStratifiedSecondStartCurrentImprovementPct: comparison.score?.orderStratifiedSecondStartCurrentImprovementPct,
      orderStratifiedAllStartPositionsNetPositive: comparison.score?.orderStratifiedAllStartPositionsNetPositive,
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
      scanSplitTelemetryEnabled: comparison.scanSplitTelemetryEnabled === true,
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

function countHistoricalFailureClasses(rounds) {
  const counts = {
    engine: 0,
    pairedMedian: 0,
    pairedMean: 0,
    pairedWinRate: 0,
    matchParity: 0,
    routeParity: 0,
    teddyRoute: 0,
    underTargetOnly: 0,
  };
  for (const round of rounds) {
    const engineImprovementPct = Number(round?.engineImprovementPct);
    const pairedMedianPct = Number(round?.pairedCandidateImprovementMedianPct);
    const pairedMeanPct = Number(round?.pairedCandidateImprovementMeanPct);
    const pairedWinRate = Number(round?.pairedCandidateWinRate);
    const requiredImprovementPct = Number(round?.requiredImprovementPct ?? 0);
    let classified = false;
    if (Number.isFinite(engineImprovementPct) && engineImprovementPct < requiredImprovementPct) {
      counts.engine += 1;
      classified = true;
    }
    if (Number.isFinite(pairedMedianPct) && pairedMedianPct < requiredImprovementPct) {
      counts.pairedMedian += 1;
      classified = true;
    }
    if (Number.isFinite(pairedMeanPct) && pairedMeanPct < requiredImprovementPct) {
      counts.pairedMean += 1;
      classified = true;
    }
    if (Number.isFinite(pairedWinRate) && pairedWinRate <= 0.5) {
      counts.pairedWinRate += 1;
      classified = true;
    }
    if (round?.matchParity !== true) {
      counts.matchParity += 1;
      classified = true;
    }
    if (round?.routeParityAcceptable !== true) {
      counts.routeParity += 1;
      classified = true;
    }
    if (round?.teddyRouteObserved === true && round?.teddyRouteNetPositive !== true) {
      counts.teddyRoute += 1;
      classified = true;
    }
    if (!classified && round?.netPositive !== true) {
      counts.underTargetOnly += 1;
    }
  }
  return counts;
}

export function buildHistoricalGateDiagnostic({
  currentIdentity,
  installedIdentity,
  roundLedger,
  scorecard,
  strictEvidenceFailures,
} = {}) {
  const rounds = Array.isArray(roundLedger) ? roundLedger : [];
  const previousBuildRounds = rounds.filter((round) => round?.evidenceAuthority === "previous_build");
  const losingRounds = previousBuildRounds.filter((round) => round?.netPositive !== true);
  const candidateIsInstalledBinary =
    typeof currentIdentity?.sha256 === "string" &&
    typeof installedIdentity?.sha256 === "string" &&
    currentIdentity.sha256 === installedIdentity.sha256;
  const matchRouteParityStable = previousBuildRounds.length > 0 &&
    previousBuildRounds.every((round) => round?.matchParity === true && round?.routeParityAcceptable === true);
  const installedBinaryFailsHistoricalGate = candidateIsInstalledBinary && (
    losingRounds.length > 0 ||
    (Array.isArray(strictEvidenceFailures) && strictEvidenceFailures.length > 0) ||
    scorecard?.netPositive === false
  );
  return {
    candidateIsInstalledBinary,
    installedIdentity: installedIdentity ?? null,
    installedBinaryFailsHistoricalGate,
    previousBuildRounds: previousBuildRounds.length,
    losingRounds: losingRounds.length,
    matchRouteParityStable,
    failureClasses: countHistoricalFailureClasses(losingRounds),
    interpretation: installedBinaryFailsHistoricalGate
      ? "native_installed_candidate_failed_predecessor_ladder; treat as benchmark/ladder attribution input, not a source regression by itself"
      : candidateIsInstalledBinary
        ? "native_installed_candidate_passed_predecessor_ladder"
        : "repo_candidate_historical_gate",
  };
}

function historicalRoundRegressed(round) {
  return (
    Number(round.currentEngineImprovementPct) < 0 ||
    Number(round.pairedCurrentImprovementMedianPct) < 0
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
  settleMs = 0,
} = {}) {
  const lanes = { first: [], second: [] };
  const pairOrder = [];
  for (let pair = 0; pair < samples; pair += 1) {
    const firstLane = pair % 2 === 0 ? "first" : "second";
    const secondLane = firstLane === "first" ? "second" : "first";
    pairOrder.push(`${firstLane},${secondLane}`);
    lanes[firstLane].push(measureIxOnce(binaryPath, ixArgs, lanes[firstLane].length + 1, { env }));
    sleepMs(settleMs);
    lanes[secondLane].push(measureIxOnce(binaryPath, ixArgs, lanes[secondLane].length + 1, { env }));
    sleepMs(settleMs);
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
  const ranked = [...attempts].sort((left, right) => {
    const leftScore = identityAttemptScore(left);
    const rightScore = identityAttemptScore(right);
    return Number(rightScore.stable) - Number(leftScore.stable) ||
      leftScore.medianDeltaAbsPct - rightScore.medianDeltaAbsPct ||
      leftScore.pairedWinRateDistance - rightScore.pairedWinRateDistance;
  });
  const stable = ranked.find((attempt) => attempt?.diagnostics?.status === "stable");
  if (stable) return { selected: stable, reason: "lowest_stable_identity_drift_attempt" };
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
  settleMs = 0,
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
      settleMs,
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

function normalizeWindowsPath(value) {
  return path.resolve(String(value ?? "")).replaceAll("\\", "/").toLowerCase();
}

function processMatchesBenchmarkBinary(entry, ixBinary) {
  if (!ixBinary) return false;
  const target = normalizeWindowsPath(ixBinary);
  const executable = String(entry.ExecutablePath ?? "");
  if (executable && normalizeWindowsPath(executable) === target) return true;
  const commandLine = String(entry.CommandLine ?? "").replaceAll("\\", "/").toLowerCase();
  return commandLine.includes(target);
}

function cleanupBenchmarkOwnedIxProcesses({ matched, ixBinary, label }) {
  if (process.platform !== "win32") {
    return {
      attempted: false,
      reason: "non_windows",
      killed: [],
      skipped: [],
      failures: [],
    };
  }

  const entries = Array.isArray(matched) ? matched : [];
  const owned = entries.filter((entry) => processMatchesBenchmarkBinary(entry, ixBinary));
  const skipped = entries
    .filter((entry) => !processMatchesBenchmarkBinary(entry, ixBinary))
    .map((entry) => ({
      processId: Number(entry.ProcessId ?? 0),
      name: entry.Name ?? null,
      executablePath: entry.ExecutablePath ?? null,
      reason: "not_repo_benchmark_binary",
    }));
  if (owned.length === 0) {
    return {
      attempted: false,
      reason: entries.length === 0 ? "no_matches" : "no_repo_benchmark_owned_matches",
      killed: [],
      skipped,
      failures: [],
    };
  }

  const ids = owned
    .map((entry) => Number(entry.ProcessId ?? 0))
    .filter((pid) => Number.isInteger(pid) && pid > 0);
  const script = [
    `$ids = @(${ids.join(",")})`,
    "$killed = @()",
    "$failures = @()",
    "foreach ($id in $ids) {",
    "  try {",
    "    Stop-Process -Id $id -Force -ErrorAction Stop",
    "    $killed += $id",
    "  } catch {",
    "    $failures += ([pscustomobject]@{ ProcessId = $id; Error = $_.Exception.Message })",
    "  }",
    "}",
    "[pscustomobject]@{ Killed = $killed; Failures = $failures } | ConvertTo-Json -Compress",
  ].join("\n");
  const result = run("powershell", ["-NoProfile", "-Command", script]);
  if (result.exitCode !== 0) {
    return {
      attempted: true,
      label,
      killed: [],
      skipped,
      failures: [`${label}:cleanup_command_failed`],
      stderr: result.stderr.trim(),
      stdout: result.stdout.trim(),
    };
  }
  try {
    const parsed = JSON.parse(result.stdout || "{}");
    const killed = Array.isArray(parsed.Killed)
      ? parsed.Killed.map(Number)
      : (parsed.Killed == null ? [] : [Number(parsed.Killed)]);
    const failures = Array.isArray(parsed.Failures)
      ? parsed.Failures
      : (parsed.Failures == null ? [] : [parsed.Failures]);
    return {
      attempted: true,
      label,
      killed,
      skipped,
      failures: failures.length > 0 ? failures.map((failure) => `${label}:cleanup_failed:${failure.ProcessId ?? "unknown"}`) : [],
      details: failures,
    };
  } catch {
    return {
      attempted: true,
      label,
      killed: [],
      skipped,
      failures: [`${label}:cleanup_invalid_json`],
      stdout: result.stdout.trim(),
    };
  }
}

function scanIxProcessState({ ixBinary, env, label, cleanupOwned = false }) {
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
  const cleanup = cleanupOwned
    ? run(ixBinary, ["process", "cleanup", "--json"], { env })
    : null;
  if (cleanup && cleanup.exitCode !== 0) {
    return {
      ok: false,
      label,
      command: cleanup.command,
      report: null,
      failures: [`${label}:process_cleanup_exit_${cleanup.exitCode}`],
      stderr: cleanup.stderr.trim(),
      stdout: cleanup.stdout.trim(),
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
      cleanupCommand: cleanup?.command ?? null,
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

export function scanIxProcesses({ ixBinary, env, cleanupOwned = false } = {}) {
  const script = [
    "$matches = Get-CimInstance Win32_Process |",
    "  Where-Object { $_.ProcessId -ne $PID -and $_.Name -match '^(ix|iex|ix-zig|__ix_indexd|__ix_nexus)(\\.exe)?$' } |",
    "  Select-Object ProcessId,Name,ExecutablePath,CommandLine,WorkingSetSize",
    "if ($null -eq $matches) { '[]' } else { $matches | ConvertTo-Json -Compress }",
  ].join("\n");
  const result = run("powershell", ["-NoProfile", "-Command", script]);
  const defaultState = scanIxProcessState({ ixBinary, label: "default_state", cleanupOwned });
  const benchmarkState = env?.IX_STATE_DIR
    ? scanIxProcessState({ ixBinary, env, label: "benchmark_state", cleanupOwned })
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
      cleanup: cleanupBenchmarkOwnedIxProcesses({ matched: [], ixBinary, label: "process_scan" }),
    };
  }
  const parsed = JSON.parse(stdout);
  const matched = Array.isArray(parsed) ? parsed : [parsed];
  const cleanup = cleanupOwned
    ? cleanupBenchmarkOwnedIxProcesses({ matched, ixBinary, label: "process_scan" })
    : null;
  return {
    ok: stateFailures.length === 0,
    matched,
    command: result.command,
    stateReports,
    cleanup,
    failures: [...stateFailures, ...(cleanup?.failures ?? [])],
  };
}

export function parseIxReport(stdout) {
  const text = stdout.trim();
  if (text.length === 0) throw new Error("IX produced empty stdout");
  return JSON.parse(text);
}

export function inferRipgrepArgs({ expression, defaultExpression = DEFAULT_ALTERNATES_EXPR, corpus, threads, mmapMode = "force" }) {
  if (expression === defaultExpression) {
    const args = [
      "--color=never",
      "--threads",
      String(threads),
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
    if (mmapMode === "force") args.splice(3, 0, "--mmap");
    else if (mmapMode === "never") args.splice(3, 0, "--no-mmap");
    else if (mmapMode !== "auto") throw new Error(`unsupported ripgrep mmap mode: ${mmapMode}`);
    return args;
  }
  return ["--color=never", "--threads", String(threads), expression, corpus];
}

export function measureRipgrep({ expression, defaultExpression = DEFAULT_ALTERNATES_EXPR, corpus, threads, samples, env, mmapMode = "force", label = "ripgrep" }) {
  const args = inferRipgrepArgs({ expression, defaultExpression, corpus, threads, mmapMode });
  const command = resolveRipgrepPath();
  const runs = [];
  for (let sample = 1; sample <= samples; sample += 1) {
    const result = run(command, args, { env });
    if (result.exitCode !== 0 && result.exitCode !== 1) requireOk(result, `ripgrep sample ${sample}`);
    runs.push({ sample, durationMs: result.durationMs, exitCode: result.exitCode, command });
  }
  return { command, label, mmapMode, args, samples: runs, summary: summary(runs.map((entry) => entry.durationMs)) };
}

export function measureRipgrepBracketed({
  expression,
  defaultExpression = DEFAULT_ALTERNATES_EXPR,
  corpus,
  threads,
  samples,
  env,
  mmapMode = "force",
  label = "ripgrep",
  between,
} = {}) {
  const totalSamples = Math.max(1, Number(samples ?? 1));
  const beforeSamples = Math.max(1, Math.ceil(totalSamples / 2));
  const afterSamples = Math.max(0, totalSamples - beforeSamples);
  const before = measureRipgrep({
    expression,
    defaultExpression,
    corpus,
    threads,
    samples: beforeSamples,
    env,
    mmapMode,
    label: `${label}-before`,
  });
  const betweenResult = typeof between === "function" ? between() : null;
  const after = afterSamples > 0
    ? measureRipgrep({
        expression,
        defaultExpression,
        corpus,
        threads,
        samples: afterSamples,
        env,
        mmapMode,
        label: `${label}-after`,
      })
    : {
        command: before.command,
        label: `${label}-after`,
        mmapMode,
        args: before.args,
        samples: [],
        summary: summary([]),
      };
  const combinedSamples = [
    ...before.samples.map((entry) => ({ ...entry, phase: "before" })),
    ...after.samples.map((entry) => ({ ...entry, phase: "after" })),
  ];
  const beforeMedian = Number(before.summary?.median);
  const afterMedian = Number(after.summary?.median);
  const bracketDriftPct =
    Number.isFinite(beforeMedian) && beforeMedian !== 0 && Number.isFinite(afterMedian)
      ? ((afterMedian - beforeMedian) / beforeMedian) * 100
      : null;
  return {
    command: "rg",
    label,
    mmapMode,
    args: before.args,
    bracketed: true,
    bracketOrder: ["before", "after"],
    betweenResult,
    before,
    after,
    samples: combinedSamples,
    summary: summary(combinedSamples.map((entry) => entry.durationMs)),
    bracketDriftPct,
  };
}

export function measureRipgrepMmapComparison({ expression, defaultExpression = DEFAULT_ALTERNATES_EXPR, corpus, threads, samples, env }) {
  if (expression !== defaultExpression) return null;
  const force = measureRipgrep({ expression, defaultExpression, corpus, threads, samples, env, mmapMode: "force", label: "ripgrep-mmap" });
  const never = measureRipgrep({ expression, defaultExpression, corpus, threads, samples, env, mmapMode: "never", label: "ripgrep-no-mmap" });
  const forceMedian = Number(force.summary?.median);
  const neverMedian = Number(never.summary?.median);
  const noMmapImprovementPct =
    Number.isFinite(forceMedian) && forceMedian !== 0 && Number.isFinite(neverMedian)
      ? ((forceMedian - neverMedian) / forceMedian) * 100
      : null;
  return {
    force,
    never,
    fastest: Number.isFinite(forceMedian) && Number.isFinite(neverMedian)
      ? (neverMedian < forceMedian ? "never" : "force")
      : null,
    noMmapImprovementPct,
  };
}

export function measureIxOnce(binaryPath, ixArgs, sample, options = {}) {
  const result = requireOk(run(binaryPath, ixArgs, { env: options.env }), `${binaryPath} sample ${sample}`);
  const report = parseIxReport(result.stdout);
  const density = report.stats?.fast_count_density ?? {};
  const timings = report.stats?.timings ?? {};
  const admission = report.stats?.admission ?? {};
  const accessErrors = report.stats?.access_errors ?? {};
  const byteShard = report.stats?.byte_shard_kernel ?? {};
  const linuxDominant = report.stats?.linux_dominant_file ?? {};
  const ixProcessMemory = report.stats?.process_memory ?? {};
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
  const scanFileFastCountMsTotal = optionalNumber(timings.scan_file_fast_count_ms_total) ?? (
    byteShardRangeElapsedNsTotal > 0 ? byteShardRangeElapsedNsTotal / 1_000_000 : null
  );
  const engineMs = Number(report.stats?.timings?.total_ms ?? result.durationMs);
  return {
    sample,
    benchmarkIsolation: result.benchmarkIsolation ?? null,
    processMetrics: result.processMetrics ?? null,
    peakWorkingSetBytes: optionalNumber(result.processMetrics?.peakWorkingSetBytes) ?? optionalNumber(ixProcessMemory.peak_resident_bytes),
    peakPagedMemoryBytes: optionalNumber(result.processMetrics?.peakPagedMemoryBytes),
    peakVirtualMemoryBytes: optionalNumber(result.processMetrics?.peakVirtualMemoryBytes),
    ixProcessMemoryAvailable: ixProcessMemory.available === true,
    ixCurrentResidentBytes: optionalNumber(ixProcessMemory.current_resident_bytes),
    ixPeakResidentBytes: optionalNumber(ixProcessMemory.peak_resident_bytes),
    cliMs: result.durationMs,
    engineMs,
    discoverMs: Number(timings.discover_ms ?? 0),
    scanMs: Number(timings.scan_ms ?? 0),
    aggregateMs: Number(timings.aggregate_ms ?? 0),
    engineResidualMs: phaseTimingResidualMs(timings, engineMs),
    scanWorkMsTotal: Number(timings.scan_work_ms_total ?? 0),
    scanOpenMsTotal: optionalNumber(timings.scan_open_ms_total),
    scanOpenPathMsTotal: optionalNumber(timings.scan_open_path_ms_total),
    scanOpenSyscallMsTotal: optionalNumber(timings.scan_open_syscall_ms_total),
    scanFileMsTotal: optionalNumber(timings.scan_file_ms_total),
    scanFileMmapMsTotal: optionalNumber(timings.scan_file_mmap_ms_total),
    scanFileBufferedMsTotal: optionalNumber(timings.scan_file_buffered_ms_total),
    scanFileFastCountMsTotal,
    scanFileLineScanMsTotal: optionalNumber(timings.scan_file_line_scan_ms_total),
    scanInputPolicy: report.stats?.concurrency?.scan_input_policy ?? "auto",
    aggregateMergeMs: Number(timings.aggregate_merge_ms ?? 0),
    aggregateFinalizeMs: Number(timings.aggregate_finalize_ms ?? 0),
    matches: Number(report.stats?.matches_found ?? 0),
    inputRoots: Number(report.stats?.input_roots ?? 0),
    effectiveRoots: Number(report.stats?.effective_roots ?? 0),
    prunedRoots: Number(report.stats?.pruned_roots ?? 0),
    overlapPrunedRoots: Number(report.stats?.overlap_pruned_roots ?? 0),
    discoveredDuplicatePaths: Number(report.stats?.discovered_duplicate_paths ?? 0),
    filesDiscovered: Number(report.stats?.files_discovered ?? 0),
    filesScanned: Number(report.stats?.files_scanned ?? 0),
    filesSkipped: Number(report.stats?.files_skipped ?? 0),
    ignoreFilesLoaded: Number(admission.ignore_files_loaded ?? 0),
    hiddenEntriesSkipped: Number(admission.hidden_entries_skipped ?? 0),
    ignoredEntriesSkipped: Number(admission.ignored_entries_skipped ?? 0),
    accessErrorsTotal: Number(accessErrors.total ?? 0),
    discoveryAccessErrors: Number(accessErrors.discovery ?? 0),
    scanOpenMsPerFile: msPerFile(timings.scan_open_ms_total, report.stats?.files_scanned),
    scanOpenPathMsPerFile: msPerFile(timings.scan_open_path_ms_total, report.stats?.files_scanned),
    scanOpenSyscallMsPerFile: msPerFile(timings.scan_open_syscall_ms_total, report.stats?.files_scanned),
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
    byteShardFilesProfiled: Number(byteShard.files_profiled ?? 0),
    byteShardRanges: Number(byteShard.range_calls ?? 0),
    byteShardLogicalRangeBytes: Number(byteShard.logical_range_bytes ?? 0),
    byteShardWidenedRangeBytes: Number(byteShard.widened_range_bytes ?? 0),
    byteShardOverlapBytes: Number(byteShard.overlap_bytes ?? 0),
    byteShardRangeElapsedNsTotal,
    byteShardRangeElapsedNsMax,
    byteShardRangeBytesAvg: Number(byteShard.range_calls ?? 0) > 0
      ? Number(byteShard.logical_range_bytes ?? 0) / Number(byteShard.range_calls ?? 0)
      : 0,
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
    linuxDominantTargetClass: linuxDominant.target_class ?? null,
    linuxDominantTargetedFilesScanned: optionalNumber(linuxDominant.targeted_files_scanned),
    linuxDominantTargetedBytesScanned: optionalNumber(linuxDominant.targeted_bytes_scanned),
    linuxDominantTargetedSlowestFiles: optionalNumber(linuxDominant.targeted_slowest_files),
    linuxDominantTargetedSlowestBytes: optionalNumber(linuxDominant.targeted_slowest_bytes),
    linuxDominantEligibleFiles: optionalNumber(linuxDominant.eligible_files),
    linuxDominantActivatedFiles: optionalNumber(linuxDominant.activated_files),
    linuxDominantMaxRangeCount: optionalNumber(linuxDominant.max_range_count),
    linuxDominantMaxChunkBytes: optionalNumber(linuxDominant.max_chunk_bytes),
  };
}

function summarizeBenchmarkIsolation(runs) {
  const isolations = runs
    .map((entry) => entry?.benchmarkIsolation)
    .filter((entry) => entry != null && typeof entry === "object");
  return {
    modes: [...new Set(isolations.map((entry) => entry.mode ?? null))],
    requestedPriorityClasses: [...new Set(isolations.map((entry) => entry.requestedPriorityClass ?? null))],
    appliedPriorityClasses: [...new Set(isolations.map((entry) => entry.appliedPriorityClass ?? null))],
    requestedAffinityMasks: [...new Set(isolations.map((entry) => entry.requestedAffinityMaskHex ?? null))],
    appliedAffinityMasks: [...new Set(isolations.map((entry) => entry.appliedAffinityMaskHex ?? null))],
    selectionStrategies: [...new Set(isolations.map((entry) => entry.selectionStrategy ?? null))],
    topologyCheckedValues: [...new Set(isolations.map((entry) => entry.topology?.checked ?? null))],
    topologyFallbackValues: [...new Set(isolations.map((entry) => entry.topologyFallbackUsed ?? null))],
    priorityErrors: [...new Set(isolations.map((entry) => entry.priorityError ?? null).filter((entry) => entry != null))],
    affinityErrors: [...new Set(isolations.map((entry) => entry.affinityError ?? null).filter((entry) => entry != null))],
    supportedValues: [...new Set(isolations.map((entry) => entry.supported ?? null))],
    reasons: [...new Set(isolations.map((entry) => entry.reason ?? null).filter((entry) => entry != null))],
    sampleCount: isolations.length,
  };
}

export function summarizeIxRuns(binaryPath, label, runs) {
  const binary = binarySnapshot(binaryPath);
  return {
    label,
    path: binaryPath,
    sha256: binary.sha256,
    executableSha256: binary.executableSha256,
    binary,
    samples: runs,
    benchmarkIsolationSummary: summarizeBenchmarkIsolation(runs),
    peakWorkingSetBytesSummary: optionalSummary(runs.map((entry) => entry.peakWorkingSetBytes)),
    peakPagedMemoryBytesSummary: optionalSummary(runs.map((entry) => entry.peakPagedMemoryBytes)),
    peakVirtualMemoryBytesSummary: optionalSummary(runs.map((entry) => entry.peakVirtualMemoryBytes)),
    cliSummary: summary(runs.map((entry) => entry.cliMs)),
    engineSummary: summary(runs.map((entry) => entry.engineMs)),
    discoverSummary: summary(runs.map((entry) => entry.discoverMs)),
    scanSummary: summary(runs.map((entry) => entry.scanMs)),
    aggregateSummary: summary(runs.map((entry) => entry.aggregateMs)),
    engineResidualSummary: summary(runs.map((entry) => entry.engineResidualMs)),
    scanWorkSummary: summary(runs.map((entry) => entry.scanWorkMsTotal)),
    scanOpenSummary: summary(runs.map((entry) => entry.scanOpenMsTotal)),
    scanOpenPathSummary: optionalSummary(runs.map((entry) => entry.scanOpenPathMsTotal)),
    scanOpenSyscallSummary: optionalSummary(runs.map((entry) => entry.scanOpenSyscallMsTotal)),
    scanFileSummary: summary(runs.map((entry) => entry.scanFileMsTotal)),
    scanFileMmapSummary: optionalSummary(runs.map((entry) => entry.scanFileMmapMsTotal)),
    scanFileBufferedSummary: optionalSummary(runs.map((entry) => entry.scanFileBufferedMsTotal)),
    scanFileFastCountSummary: optionalSummary(runs.map((entry) => entry.scanFileFastCountMsTotal)),
    scanFileLineScanSummary: optionalSummary(runs.map((entry) => entry.scanFileLineScanMsTotal)),
    scanOpenMsPerFileSummary: summary(runs.map((entry) => entry.scanOpenMsPerFile)),
    scanOpenPathMsPerFileSummary: optionalSummary(runs.map((entry) => entry.scanOpenPathMsPerFile)),
    scanOpenSyscallMsPerFileSummary: optionalSummary(runs.map((entry) => entry.scanOpenSyscallMsPerFile)),
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
    inputRoots: [...new Set(runs.map((entry) => entry.inputRoots))],
    inputRootsSummary: summary(runs.map((entry) => entry.inputRoots)),
    effectiveRoots: [...new Set(runs.map((entry) => entry.effectiveRoots))],
    effectiveRootsSummary: summary(runs.map((entry) => entry.effectiveRoots)),
    prunedRoots: [...new Set(runs.map((entry) => entry.prunedRoots))],
    prunedRootsSummary: summary(runs.map((entry) => entry.prunedRoots)),
    overlapPrunedRoots: [...new Set(runs.map((entry) => entry.overlapPrunedRoots))],
    overlapPrunedRootsSummary: summary(runs.map((entry) => entry.overlapPrunedRoots)),
    discoveredDuplicatePaths: [...new Set(runs.map((entry) => entry.discoveredDuplicatePaths))],
    discoveredDuplicatePathsSummary: summary(runs.map((entry) => entry.discoveredDuplicatePaths)),
    filesDiscovered: [...new Set(runs.map((entry) => entry.filesDiscovered))],
    filesDiscoveredSummary: summary(runs.map((entry) => entry.filesDiscovered)),
    filesScanned: [...new Set(runs.map((entry) => entry.filesScanned))],
    filesSkipped: [...new Set(runs.map((entry) => entry.filesSkipped))],
    filesSkippedSummary: summary(runs.map((entry) => entry.filesSkipped)),
    ignoreFilesLoaded: [...new Set(runs.map((entry) => entry.ignoreFilesLoaded))],
    ignoreFilesLoadedSummary: summary(runs.map((entry) => entry.ignoreFilesLoaded)),
    hiddenEntriesSkipped: [...new Set(runs.map((entry) => entry.hiddenEntriesSkipped))],
    hiddenEntriesSkippedSummary: summary(runs.map((entry) => entry.hiddenEntriesSkipped)),
    ignoredEntriesSkipped: [...new Set(runs.map((entry) => entry.ignoredEntriesSkipped))],
    ignoredEntriesSkippedSummary: summary(runs.map((entry) => entry.ignoredEntriesSkipped)),
    accessErrorsTotal: [...new Set(runs.map((entry) => entry.accessErrorsTotal))],
    accessErrorsTotalSummary: summary(runs.map((entry) => entry.accessErrorsTotal)),
    discoveryAccessErrors: [...new Set(runs.map((entry) => entry.discoveryAccessErrors))],
    discoveryAccessErrorsSummary: summary(runs.map((entry) => entry.discoveryAccessErrors)),
    byteShardStrategy: [...new Set(runs.map((entry) => entry.byteShardStrategy))],
    byteShardFilesProfiled: [...new Set(runs.map((entry) => entry.byteShardFilesProfiled))],
    byteShardFilesProfiledSummary: summary(runs.map((entry) => entry.byteShardFilesProfiled)),
    byteShardRanges: [...new Set(runs.map((entry) => entry.byteShardRanges))],
    byteShardRangesSummary: summary(runs.map((entry) => entry.byteShardRanges)),
    byteShardLogicalRangeBytes: [...new Set(runs.map((entry) => entry.byteShardLogicalRangeBytes))],
    byteShardLogicalRangeBytesSummary: summary(runs.map((entry) => entry.byteShardLogicalRangeBytes)),
    byteShardWidenedRangeBytes: [...new Set(runs.map((entry) => entry.byteShardWidenedRangeBytes))],
    byteShardWidenedRangeBytesSummary: summary(runs.map((entry) => entry.byteShardWidenedRangeBytes)),
    byteShardOverlapBytes: [...new Set(runs.map((entry) => entry.byteShardOverlapBytes))],
    byteShardOverlapBytesSummary: summary(runs.map((entry) => entry.byteShardOverlapBytes)),
    byteShardRangeBytesAvgSummary: summary(runs.map((entry) => entry.byteShardRangeBytesAvg)),
    byteShardRangeElapsedNsTotal: [...new Set(runs.map((entry) => entry.byteShardRangeElapsedNsTotal))],
    byteShardRangeElapsedNsTotalSummary: summary(runs.map((entry) => entry.byteShardRangeElapsedNsTotal)),
    byteShardRangeElapsedNsMax: [...new Set(runs.map((entry) => entry.byteShardRangeElapsedNsMax))],
    byteShardRangeElapsedNsMaxSummary: summary(runs.map((entry) => entry.byteShardRangeElapsedNsMax)),
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
    linuxDominantTargetClass: [...new Set(runs.map((entry) => entry.linuxDominantTargetClass).filter(Boolean))],
    linuxDominantTargetedFilesScannedSummary: optionalSummary(runs.map((entry) => entry.linuxDominantTargetedFilesScanned)),
    linuxDominantTargetedBytesScannedSummary: optionalSummary(runs.map((entry) => entry.linuxDominantTargetedBytesScanned)),
    linuxDominantTargetedSlowestFilesSummary: optionalSummary(runs.map((entry) => entry.linuxDominantTargetedSlowestFiles)),
    linuxDominantTargetedSlowestBytesSummary: optionalSummary(runs.map((entry) => entry.linuxDominantTargetedSlowestBytes)),
    linuxDominantEligibleFilesSummary: optionalSummary(runs.map((entry) => entry.linuxDominantEligibleFiles)),
    linuxDominantActivatedFilesSummary: optionalSummary(runs.map((entry) => entry.linuxDominantActivatedFiles)),
    linuxDominantMaxRangeCountSummary: optionalSummary(runs.map((entry) => entry.linuxDominantMaxRangeCount)),
    linuxDominantMaxChunkBytesSummary: optionalSummary(runs.map((entry) => entry.linuxDominantMaxChunkBytes)),
  };
}
