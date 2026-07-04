import os from "node:os";
import path from "node:path";

export const DEFAULT_RIPGREP_LINUX_CORPUS = "E:\\Workspaces\\01_Projects\\01_Github\\iEx\\.refs\\ripgrep\\benchsuite\\linux";
export const DEFAULT_ALTERNATES_EXPRESSION = "re:(?i)(ERR_SYS|PME_TURN_OFF|LINK_REQ_RST|CFG_BME_EVT)";
export const DEFAULT_NATIVE_INSTALL_DIR = path.join(os.homedir(), "AppData", "Local", "Programs", "iEx", "bin");
export const EXPERIMENTAL_BENCH_ENV_KEYS = [
  "IX_TEDDY_FINGERPRINT_OFFSET",
  "IX_TEDDY_RANGE_FINGERPRINT_OFFSET",
  "IX_LITERAL_ALTERNATES_COUNTER_CACHE",
  "IX_BLOCK_PRUNING_PROOF",
];
export const BENCHMARK_HOST_NOISE_DEFAULTS = {
  activeCpuMinSec: 0.05,
  activeCpuHeavySec: 0.25,
  largeProcessWorkingSetBytes: 4 * 1024 * 1024 * 1024,
  largeProcessWarningFreeMemRatio: 0.5,
  largeProcessWarningShareOfTotalMem: 0.125,
  defenderResidentSeverity: "info",
  interactiveWorkloadSeverity: "info",
  interactiveWorkloadWarningCount: 2,
  interactiveWorkloadProcessNames: ["chrome", "codex"],
  schedulerCpuHighPct: 85,
  processorQueueLengthWarning: 2,
  contextSwitchesPerCpuWarning: 15000,
};
export const BENCHMARK_ISOLATION_DEFAULTS = {
  modeWindows: "enforce",
  modeOther: "telemetry",
  priorityClass: "High",
  affinityMode: "approx_physical_cores",
  minLogicalCpuCount: 2,
};
export const BENCHMARK_PROCESS_NAMES = [
  "ix",
  "iex",
  "ix-zig",
  "node",
  "powershell",
  "pwsh",
  "conhost",
  "windowsterminal",
];

export function defaultRepoIxPath(root) {
  return path.join(root, "zig-out", "bin", process.platform === "win32" ? "ix-zig.exe" : "ix-zig");
}

export function defaultInstalledIxPath() {
  return path.join(DEFAULT_NATIVE_INSTALL_DIR, "ix.exe");
}

export function benchmarkStateDir(kind) {
  return path.join(os.tmpdir(), kind === "historical" ? "ix-zig-historical-speed-state" : "ix-zig-speed-compare-state");
}

export function baseBenchEnv(kind) {
  return {
    IX_INDEX: "0",
    IX_NEXUS: "0",
    IX_RESOURCE_PROFILE: "high",
    IX_STATE_DIR: benchmarkStateDir(kind),
    IX_BENCH_ISOLATION_MODE: process.platform === "win32" ? "enforce" : "telemetry",
    IX_BENCH_PRIORITY_CLASS: BENCHMARK_ISOLATION_DEFAULTS.priorityClass,
    IX_BENCH_AFFINITY_MODE: BENCHMARK_ISOLATION_DEFAULTS.affinityMode,
  };
}

export function experimentalBenchEnvOverrides(env = process.env) {
  return Object.fromEntries(
    EXPERIMENTAL_BENCH_ENV_KEYS
      .map((key) => [key, env?.[key] ?? null])
      .filter(([, value]) => value != null && value !== ""),
  );
}

export function hasExperimentalBenchEnv(reportOrEnv = process.env) {
  if (reportOrEnv?.experimentalEnvMode === true) return true;
  const env = reportOrEnv?.effectiveBenchEnv ?? reportOrEnv;
  return EXPERIMENTAL_BENCH_ENV_KEYS.some((key) => {
    const value = env?.[key];
    return value != null && value !== "";
  });
}

function finitePositiveNumber(value, fallback) {
  const number = Number(value);
  return Number.isFinite(number) && number > 0 ? number : fallback;
}

function severityValue(value, fallback) {
  return value === "info" || value === "warning" ? value : fallback;
}

function csvList(value, fallback) {
  if (typeof value !== "string" || value.trim().length === 0) return fallback;
  const list = value
    .split(",")
    .map((entry) => entry.trim().toLowerCase())
    .filter((entry) => entry.length > 0);
  return list.length > 0 ? list : fallback;
}

function enumValue(value, allowed, fallback) {
  return allowed.includes(value) ? value : fallback;
}

export function benchmarkHostNoiseConfig(env = process.env) {
  return {
    activeCpuMinSec: finitePositiveNumber(env.IX_BENCH_HOST_ACTIVE_CPU_MIN_SEC, BENCHMARK_HOST_NOISE_DEFAULTS.activeCpuMinSec),
    activeCpuHeavySec: finitePositiveNumber(env.IX_BENCH_HOST_ACTIVE_CPU_HEAVY_SEC, BENCHMARK_HOST_NOISE_DEFAULTS.activeCpuHeavySec),
    largeProcessWorkingSetBytes: finitePositiveNumber(
      env.IX_BENCH_HOST_LARGE_WORKING_SET_BYTES,
      BENCHMARK_HOST_NOISE_DEFAULTS.largeProcessWorkingSetBytes,
    ),
    largeProcessWarningFreeMemRatio: finitePositiveNumber(
      env.IX_BENCH_HOST_LARGE_WORKING_SET_WARNING_FREE_MEM_RATIO,
      BENCHMARK_HOST_NOISE_DEFAULTS.largeProcessWarningFreeMemRatio,
    ),
    largeProcessWarningShareOfTotalMem: finitePositiveNumber(
      env.IX_BENCH_HOST_LARGE_WORKING_SET_WARNING_SHARE_OF_TOTAL_MEM,
      BENCHMARK_HOST_NOISE_DEFAULTS.largeProcessWarningShareOfTotalMem,
    ),
    defenderResidentSeverity: severityValue(
      env.IX_BENCH_HOST_DEFENDER_RESIDENT_SEVERITY,
      BENCHMARK_HOST_NOISE_DEFAULTS.defenderResidentSeverity,
    ),
    interactiveWorkloadSeverity: severityValue(
      env.IX_BENCH_HOST_INTERACTIVE_WORKLOAD_SEVERITY,
      BENCHMARK_HOST_NOISE_DEFAULTS.interactiveWorkloadSeverity,
    ),
    interactiveWorkloadWarningCount: finitePositiveNumber(
      env.IX_BENCH_HOST_INTERACTIVE_WORKLOAD_WARNING_COUNT,
      BENCHMARK_HOST_NOISE_DEFAULTS.interactiveWorkloadWarningCount,
    ),
    interactiveWorkloadProcessNames: csvList(
      env.IX_BENCH_HOST_INTERACTIVE_WORKLOAD_NAMES,
      BENCHMARK_HOST_NOISE_DEFAULTS.interactiveWorkloadProcessNames,
    ),
    schedulerCpuHighPct: finitePositiveNumber(
      env.IX_BENCH_HOST_SCHEDULER_CPU_HIGH_PCT,
      BENCHMARK_HOST_NOISE_DEFAULTS.schedulerCpuHighPct,
    ),
    processorQueueLengthWarning: finitePositiveNumber(
      env.IX_BENCH_HOST_PROCESSOR_QUEUE_LENGTH_WARNING,
      BENCHMARK_HOST_NOISE_DEFAULTS.processorQueueLengthWarning,
    ),
    contextSwitchesPerCpuWarning: finitePositiveNumber(
      env.IX_BENCH_HOST_CONTEXT_SWITCHES_PER_CPU_WARNING,
      BENCHMARK_HOST_NOISE_DEFAULTS.contextSwitchesPerCpuWarning,
    ),
    benchmarkProcessNames: BENCHMARK_PROCESS_NAMES,
  };
}

export function benchmarkIsolationConfig(env = process.env, platform = process.platform, availableParallelism = os.availableParallelism()) {
  const defaultMode = platform === "win32"
    ? BENCHMARK_ISOLATION_DEFAULTS.modeWindows
    : BENCHMARK_ISOLATION_DEFAULTS.modeOther;
  return {
    mode: enumValue(env.IX_BENCH_ISOLATION_MODE, ["off", "telemetry", "enforce"], defaultMode),
    priorityClass: enumValue(
      env.IX_BENCH_PRIORITY_CLASS,
      ["Idle", "BelowNormal", "Normal", "AboveNormal", "High", "RealTime"],
      BENCHMARK_ISOLATION_DEFAULTS.priorityClass,
    ),
    affinityMode: enumValue(
      env.IX_BENCH_AFFINITY_MODE,
      ["off", "approx_physical_cores", "all_logical"],
      BENCHMARK_ISOLATION_DEFAULTS.affinityMode,
    ),
    requestedLogicalCpuCount: finitePositiveNumber(
      env.IX_BENCH_AFFINITY_LOGICAL_CPU_COUNT,
      Math.max(
        BENCHMARK_ISOLATION_DEFAULTS.minLogicalCpuCount,
        Math.min(
          availableParallelism,
          Math.ceil(availableParallelism / 2),
        ),
      ),
    ),
    minLogicalCpuCount: BENCHMARK_ISOLATION_DEFAULTS.minLogicalCpuCount,
    platform,
    availableParallelism,
  };
}
