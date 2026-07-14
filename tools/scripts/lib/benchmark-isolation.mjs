import os from "node:os";
import path from "node:path";
import { spawnSync } from "node:child_process";
import { benchmarkIsolationConfig } from "./benchmark-config.mjs";

const ROOT = process.cwd();
const WINDOWS_BENCHMARK_ISOLATION_HELPER = path.join(ROOT, "tools", "scripts", "lib", "benchmark-isolation.ps1");
const WINDOWS_BENCHMARK_CPU_TOPOLOGY_HELPER = path.join(ROOT, "tools", "scripts", "lib", "benchmark-cpu-topology.ps1");
let cachedWindowsCpuTopology = null;

function quoteWindowsArgument(value) {
  const text = String(value);
  if (text.length === 0) return '""';
  if (!/[ \t"]/.test(text)) return text;
  let result = '"';
  let backslashes = 0;
  for (const char of text) {
    if (char === "\\") {
      backslashes += 1;
      continue;
    }
    if (char === '"') {
      result += "\\".repeat(backslashes * 2 + 1);
      result += '"';
      backslashes = 0;
      continue;
    }
    if (backslashes > 0) {
      result += "\\".repeat(backslashes);
      backslashes = 0;
    }
    result += char;
  }
  if (backslashes > 0) {
    result += "\\".repeat(backslashes * 2);
  }
  result += '"';
  return result;
}

export function mergedEnv(overrides = {}) {
  return { ...process.env, ...overrides };
}

function hexMaskFromBigInt(mask) {
  return `0x${mask.toString(16).toUpperCase()}`;
}

function parseJson(text) {
  try {
    return JSON.parse(text);
  } catch {
    return null;
  }
}

function cpuSetCoreKey(entry) {
  return `${entry.group}:${entry.coreIndex}`;
}

function cpuSetSort(left, right) {
  return (
    Number(right.efficiencyClass ?? 0) - Number(left.efficiencyClass ?? 0) ||
    Number(left.group ?? 0) - Number(right.group ?? 0) ||
    Number(left.coreIndex ?? 0) - Number(right.coreIndex ?? 0) ||
    Number(left.logicalProcessorIndex ?? 0) - Number(right.logicalProcessorIndex ?? 0)
  );
}

function usableCpuSets(entries) {
  return [...entries]
    .filter((entry) =>
      Number.isInteger(entry?.logicalProcessorIndex) &&
      entry.logicalProcessorIndex >= 0 &&
      Number.isInteger(entry?.group) &&
      entry.group >= 0 &&
      Number.isInteger(entry?.coreIndex) &&
      entry.coreIndex >= 0 &&
      entry.parked !== true
    )
    .sort(cpuSetSort);
}

function summarizeWindowsCpuTopology(entries) {
  const logicalProcessorIndices = new Set();
  const coreKeys = new Set();
  const groupIds = new Set();
  const numaNodeIds = new Set();
  const efficiencyClasses = new Set();
  let parkedCount = 0;
  for (const entry of entries) {
    logicalProcessorIndices.add(entry.logicalProcessorIndex);
    coreKeys.add(cpuSetCoreKey(entry));
    groupIds.add(entry.group);
    numaNodeIds.add(entry.numaNodeIndex);
    efficiencyClasses.add(entry.efficiencyClass);
    if (entry.parked === true) parkedCount += 1;
  }
  return {
    logicalProcessorCount: logicalProcessorIndices.size,
    physicalCoreCount: coreKeys.size,
    groupCount: groupIds.size,
    numaNodeCount: numaNodeIds.size,
    efficiencyClasses: [...efficiencyClasses].sort((left, right) => right - left),
    parkedCount,
  };
}

function readWindowsCpuTopology() {
  if (process.platform !== "win32") {
    return { checked: false, source: "GetSystemCpuSetInformation", reason: "non-windows", entries: [], summary: null };
  }
  if (cachedWindowsCpuTopology != null) return cachedWindowsCpuTopology;
  const result = spawnSync("powershell", [
    "-NoProfile",
    "-NonInteractive",
    "-ExecutionPolicy",
    "Bypass",
    "-File",
    WINDOWS_BENCHMARK_CPU_TOPOLOGY_HELPER,
  ], {
    cwd: ROOT,
    encoding: "utf8",
    stdio: "pipe",
    maxBuffer: 16 * 1024 * 1024,
    windowsHide: true,
  });
  if ((result.status ?? 0) !== 0) {
    cachedWindowsCpuTopology = {
      checked: false,
      source: "GetSystemCpuSetInformation",
      reason: `helper_failed:${String(result.stderr ?? result.stdout ?? "").trim() || `exit_${result.status ?? "unknown"}`}`,
      entries: [],
      summary: null,
    };
    return cachedWindowsCpuTopology;
  }
  const parsed = parseJson(result.stdout ?? "");
  const rows = Array.isArray(parsed) ? parsed : parsed != null ? [parsed] : [];
  const entries = rows
    .map((entry) => ({
      id: Number(entry?.id),
      group: Number(entry?.group),
      logicalProcessorIndex: Number(entry?.logicalProcessorIndex),
      coreIndex: Number(entry?.coreIndex),
      lastLevelCacheIndex: Number(entry?.lastLevelCacheIndex),
      numaNodeIndex: Number(entry?.numaNodeIndex),
      efficiencyClass: Number(entry?.efficiencyClass),
      parked: entry?.parked === true,
      allocated: entry?.allocated === true,
      allocatedToTargetProcess: entry?.allocatedToTargetProcess === true,
      realTime: entry?.realTime === true,
      allocationTag: entry?.allocationTag ?? null,
    }))
    .filter((entry) =>
      Number.isInteger(entry.id) &&
      Number.isInteger(entry.group) &&
      Number.isInteger(entry.logicalProcessorIndex) &&
      Number.isInteger(entry.coreIndex)
    );
  cachedWindowsCpuTopology = entries.length === 0
    ? {
        checked: false,
        source: "GetSystemCpuSetInformation",
        reason: "empty_or_invalid_topology",
        entries: [],
        summary: null,
      }
    : {
        checked: true,
        source: "GetSystemCpuSetInformation",
        reason: null,
        entries,
        summary: summarizeWindowsCpuTopology(entries),
      };
  return cachedWindowsCpuTopology;
}

function chooseTopologyAwareCpuSets(entries, targetLogicalCpuCount) {
  const usable = usableCpuSets(entries);
  const byCore = new Map();
  for (const entry of usable) {
    const key = cpuSetCoreKey(entry);
    if (!byCore.has(key)) byCore.set(key, entry);
  }
  const uniqueCoreEntries = [...byCore.values()].sort(cpuSetSort);
  const selected = uniqueCoreEntries.slice(0, targetLogicalCpuCount);
  return {
    usableCount: usable.length,
    uniqueCoreCount: uniqueCoreEntries.length,
    selected,
    strategy: "topology_unique_core",
    fallbackUsed: false,
  };
}

function buildAffinityMaskHex(selectedCpuSets) {
  if (!Array.isArray(selectedCpuSets) || selectedCpuSets.length === 0) return null;
  const groups = [...new Set(selectedCpuSets.map((entry) => entry.group))];
  if (groups.length !== 1 || groups[0] !== 0) return null;
  let mask = 0n;
  for (const entry of selectedCpuSets) {
    const index = Number(entry.logicalProcessorIndex);
    if (!Number.isInteger(index) || index < 0 || index > 63) return null;
    mask |= (1n << BigInt(index));
  }
  return hexMaskFromBigInt(mask);
}

export function benchmarkIsolationPlan(env = process.env, platform = process.platform, availableParallelism = os.availableParallelism()) {
  const config = benchmarkIsolationConfig(env, platform, availableParallelism);
  const logicalCount = Math.max(1, Number(config.availableParallelism ?? availableParallelism ?? 1));
  const requestedLogicalCpuCount = Math.max(
    config.minLogicalCpuCount,
    Math.min(logicalCount, Number(config.requestedLogicalCpuCount ?? logicalCount)),
  );
  const approximatePhysicalCoreCount = Math.max(1, Math.min(logicalCount, Math.ceil(logicalCount / 2)));
  const targetLogicalCpuCount = config.affinityMode === "off"
    ? logicalCount
    : config.affinityMode === "all_logical"
      ? logicalCount
      : Math.max(config.minLogicalCpuCount, Math.min(logicalCount, Math.min(approximatePhysicalCoreCount, requestedLogicalCpuCount)));
  const topology = platform === "win32" ? readWindowsCpuTopology() : null;
  let selectedCpuSets = [];
  let selectionStrategy = config.affinityMode;
  let topologyFallbackUsed = false;
  if (platform === "win32" && config.affinityMode === "approx_physical_cores" && topology?.checked === true) {
    const chosen = chooseTopologyAwareCpuSets(topology.entries, targetLogicalCpuCount);
    selectedCpuSets = chosen.selected;
    selectionStrategy = chosen.strategy;
    topologyFallbackUsed = chosen.fallbackUsed;
  } else if (platform === "win32" && config.affinityMode === "all_logical" && topology?.checked === true) {
    selectedCpuSets = usableCpuSets(topology.entries).slice(0, logicalCount);
    selectionStrategy = "topology_all_logical";
  } else if (platform === "win32" && config.affinityMode !== "off" && targetLogicalCpuCount > 0) {
    selectedCpuSets = Array.from({ length: Math.min(targetLogicalCpuCount, 64) }, (_, logicalProcessorIndex) => ({
      group: 0,
      logicalProcessorIndex,
      coreIndex: logicalProcessorIndex,
      efficiencyClass: 0,
    }));
    selectionStrategy = "fallback_low_bits";
    topologyFallbackUsed = true;
  }
  const affinityMaskHex = platform === "win32" && config.affinityMode !== "off"
    ? buildAffinityMaskHex(selectedCpuSets)
    : null;
  const supported = platform === "win32" && config.mode === "enforce"
    ? affinityMaskHex != null
    : platform === "win32";
  return {
    mode: config.mode,
    platform,
    priorityClass: config.priorityClass,
    affinityMode: config.affinityMode,
    supported,
    availableLogicalCpuCount: logicalCount,
    approximatePhysicalCoreCount,
    requestedLogicalCpuCount,
    targetLogicalCpuCount,
    affinityMaskHex,
    selectionStrategy,
    topologyFallbackUsed,
    selectedLogicalProcessors: selectedCpuSets.map((entry) => entry.logicalProcessorIndex),
    selectedCoreKeys: selectedCpuSets.map((entry) => cpuSetCoreKey(entry)),
    topology,
    reason: supported ? null : (
      platform !== "win32"
        ? "windows_enforcement_not_available_on_this_platform"
        : affinityMaskHex == null
          ? "topology_selection_not_expressible_as_single_group_affinity_mask"
          : "affinity_mask_unavailable_for_requested_cpu_count"
    ),
  };
}

export function defaultBenchmarkIsolationResult(isolationPlan) {
  return {
    mode: isolationPlan.mode,
    requestedPriorityClass: isolationPlan.priorityClass,
    appliedPriorityClass: null,
    requestedAffinityMaskHex: isolationPlan.affinityMaskHex,
    appliedAffinityMaskHex: null,
    selectionStrategy: isolationPlan.selectionStrategy ?? null,
    topologyFallbackUsed: isolationPlan.topologyFallbackUsed ?? null,
    selectedLogicalProcessors: isolationPlan.selectedLogicalProcessors ?? null,
    selectedCoreKeys: isolationPlan.selectedCoreKeys ?? null,
    topology: isolationPlan.topology ?? null,
    priorityError: null,
    affinityError: null,
    supported: isolationPlan.supported,
    reason: isolationPlan.reason,
  };
}

export function runWithWindowsBenchmarkIsolation(command, args, options, isolationPlan, { allowedCodes = [0] } = {}) {
  const captureStdout = options.captureStdout ?? true;
  const captureStderr = options.captureStderr ?? true;
  const envOverrides = options.env ?? {};
  const started = process.hrtime.bigint();
  const result = spawnSync("powershell", [
    "-NoProfile",
    "-NonInteractive",
    "-ExecutionPolicy",
    "Bypass",
    "-File",
    WINDOWS_BENCHMARK_ISOLATION_HELPER,
    command,
    args.map(quoteWindowsArgument).join(" "),
    options.cwd ?? ROOT,
    isolationPlan.priorityClass ?? "",
    isolationPlan.affinityMaskHex ?? "",
    JSON.stringify(envOverrides),
    captureStdout ? "1" : "0",
    captureStderr ? "1" : "0",
  ], {
    cwd: ROOT,
    env: mergedEnv(envOverrides),
    encoding: "utf8",
    stdio: "pipe",
    maxBuffer: options.maxBuffer ?? 128 * 1024 * 1024,
    windowsHide: true,
  });
  const ended = process.hrtime.bigint();
  const wrapperDurationMs = Number(ended - started) / 1_000_000;
  const wrapperStatus = result.status;
  if (result.error || wrapperStatus == null || wrapperStatus !== 0) {
    throw new Error(`isolation wrapper failed (${command} ${args.join(" ")}): code=${wrapperStatus ?? "not-started"}\n${result.stderr?.toString() ?? result.error?.message ?? ""}`);
  }
  let payload = null;
  try {
    payload = JSON.parse(result.stdout?.toString() ?? "{}");
  } catch {
    throw new Error(`isolation wrapper returned invalid JSON for ${command}`);
  }
  if (payload?.status == null) {
    throw new Error(`isolated command did not start (${command} ${args.join(" ")}): ${String(payload?.startError ?? payload?.stderr ?? "unknown start failure")}`);
  }
  const status = Number(payload.status);
  if (!allowedCodes.includes(status)) {
    const stderr = String(payload?.stderr ?? "");
    throw new Error(`command failed (${command} ${args.join(" ")}): code=${status}\n${stderr}`);
  }
  return {
    durationMs: Number(payload?.durationMs ?? wrapperDurationMs),
    stdout: captureStdout ? String(payload?.stdout ?? "") : "",
    stderr: captureStderr ? String(payload?.stderr ?? "") : "",
    status,
    processMetrics: payload?.processMetrics && typeof payload.processMetrics === "object"
      ? {
          peakWorkingSetBytes: Number(payload.processMetrics.peakWorkingSetBytes ?? 0),
          peakPagedMemoryBytes: Number(payload.processMetrics.peakPagedMemoryBytes ?? 0),
          peakVirtualMemoryBytes: Number(payload.processMetrics.peakVirtualMemoryBytes ?? 0),
        }
      : null,
    benchmarkIsolation: payload?.benchmarkIsolation
      ? {
          ...payload.benchmarkIsolation,
          supported: isolationPlan.supported,
          reason: isolationPlan.reason,
        }
      : defaultBenchmarkIsolationResult(isolationPlan),
  };
}
