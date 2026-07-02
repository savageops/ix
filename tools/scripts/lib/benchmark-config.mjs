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
    IX_STATE_DIR: benchmarkStateDir(kind),
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
