import { createHash } from "node:crypto";
import { copyFileSync, existsSync, mkdirSync, readFileSync, renameSync, rmSync, statSync } from "node:fs";
import { spawnSync } from "node:child_process";
import os from "node:os";
import path from "node:path";
import { argValue } from "./lib/script-helpers.mjs";
import { assertRepoBinaryFresh } from "./lib/speed-compare-utils.mjs";

const ROOT = process.cwd();
const DEFAULT_REPO_IX = path.join(ROOT, "zig-out", "bin", "ix-zig.exe");
const DEFAULT_INSTALL_DIR = path.join(os.homedir(), "AppData", "Local", "Programs", "iEx", "bin");

const args = process.argv.slice(2);
if (args.includes("--help") || args.includes("-h")) {
  console.log(`Usage: node tools/scripts/sync-native-install.mjs [options]

Proves the repo IX candidate, stages it beside the native aliases, rotates exact
rollback binaries, atomically promotes, and verifies the installed owner path.

Options:
  --build                 Run tests and build repo IX ReleaseSmall before syncing.
  --repo-ix <path>        Repo IX binary. Default: zig-out/bin/ix-zig.exe.
  --install-dir <path>    Native install directory.
                          Default: ~/AppData/Local/Programs/iEx/bin.
  --dry-run               Print planned actions without copying files.
  --help, -h              Print this help.
`);
  process.exit(0);
}

const buildFirst = args.includes("--build");
const dryRun = args.includes("--dry-run");
const repoIx = path.resolve(argValue(args, "--repo-ix", DEFAULT_REPO_IX));
const installDir = path.resolve(argValue(args, "--install-dir", DEFAULT_INSTALL_DIR));
const aliases = ["ix.exe", "iex.exe"].map((name) => path.join(installDir, name));

function sha256File(filePath) {
  return createHash("sha256").update(readFileSync(filePath)).digest("hex").toUpperCase();
}

function resolveZigExe() {
  if (process.env.ZIG_EXE && existsSync(process.env.ZIG_EXE)) return process.env.ZIG_EXE;
  const local = path.join(os.homedir(), ".local", "zig", "zig-x86_64-windows-0.16.0", process.platform === "win32" ? "zig.exe" : "zig");
  return existsSync(local) ? local : "zig";
}

function run(command, commandArgs, { quiet = false } = {}) {
  const result = spawnSync(command, commandArgs, {
    cwd: ROOT,
    encoding: "utf8",
    stdio: quiet ? "pipe" : "inherit",
    windowsHide: true,
  });
  if ((result.status ?? 0) !== 0) {
    throw new Error(`${command} ${commandArgs.join(" ")} failed with exit code ${result.status}`);
  }
}

function rollbackPath(aliasPath) {
  const now = new Date();
  const pad = (value) => String(value).padStart(2, "0");
  const date = `${pad(now.getDate())}${pad(now.getMonth() + 1)}${String(now.getFullYear()).slice(-2)}`;
  const extension = path.extname(aliasPath);
  const stem = aliasPath.slice(0, -extension.length);
  const base = `${stem}.old.${date}${extension}`;
  if (!existsSync(base)) return base;
  for (let suffix = 2; ; suffix += 1) {
    const candidate = `${stem}.old.${date}.${suffix}${extension}`;
    if (!existsSync(candidate)) return candidate;
  }
}

function verifyCandidate(binaryPath) {
  run(binaryPath, ["help", "search"], { quiet: true });
  const probe = (indexEnabled) => {
    const result = spawnSync(binaryPath, ["search", "lit:pub", "src/main.zig", "--format", "json-compact", "--total-count", "1", "--max-bytes", "4096"], {
      cwd: ROOT,
      encoding: "utf8",
      windowsHide: true,
      env: { ...process.env, IX_INDEX: indexEnabled ? "1" : "0" },
    });
    if (result.status !== 0) throw new Error(`${binaryPath}: ${indexEnabled ? "warm" : "cold"} output-contract probe failed: ${result.stderr.trim()}`);
    const payload = JSON.parse(result.stdout);
    if (payload.schema !== "ix.result.v3" || payload.scan?.state !== "complete") {
      throw new Error(`${binaryPath}: invalid ${indexEnabled ? "warm" : "cold"} v3 output contract`);
    }
    return payload;
  };
  const cold = probe(false);
  const warm = probe(true);
  if (cold.stats?.matches_found !== warm.stats?.matches_found || JSON.stringify(cold.hits) !== JSON.stringify(warm.hits)) {
    throw new Error(`${binaryPath}: warm/cold evidence parity failed`);
  }
}

function promoteAlias(aliasPath, repoHash) {
  const beforeHash = existsSync(aliasPath) ? sha256File(aliasPath) : null;
  if (beforeHash === repoHash) return { alias: aliasPath, beforeHash, afterHash: repoHash, backup: null, changed: false };
  const backupPath = existsSync(aliasPath) ? rollbackPath(aliasPath) : null;
  const stagedPath = `${aliasPath}.candidate-${process.pid}`;
  if (dryRun) return { alias: aliasPath, beforeHash, afterHash: repoHash, backup: backupPath, changed: true };

  copyFileSync(repoIx, stagedPath);
  if (sha256File(stagedPath) !== repoHash) {
    rmSync(stagedPath, { force: true });
    throw new Error(`${aliasPath}: staged candidate hash mismatch`);
  }
  try {
    if (backupPath) renameSync(aliasPath, backupPath);
    renameSync(stagedPath, aliasPath);
    verifyCandidate(aliasPath);
    if (sha256File(aliasPath) !== repoHash) throw new Error(`${aliasPath}: installed hash mismatch`);
  } catch (error) {
    rmSync(stagedPath, { force: true });
    rmSync(aliasPath, { force: true });
    if (backupPath && existsSync(backupPath)) renameSync(backupPath, aliasPath);
    throw error;
  }
  return {
    alias: aliasPath,
    beforeHash,
    afterHash: repoHash,
    backup: backupPath ? { path: backupPath, bytes: statSync(backupPath).size, sha256: sha256File(backupPath) } : null,
    changed: true,
  };
}

if (process.platform !== "win32") {
  throw new Error("native install sync is currently Windows-only");
}

if (buildFirst) {
  run(resolveZigExe(), ["build", "test", "-j1", "-Doptimize=ReleaseSmall"]);
  run(resolveZigExe(), ["build", "-j1", "-Doptimize=ReleaseSmall", "--summary", "all"]);
}
if (!existsSync(repoIx)) {
  throw new Error(`repo IX binary missing: ${repoIx}`);
}

const repoHash = sha256File(repoIx);
const freshness = assertRepoBinaryFresh({ root: ROOT, repoIx });
const actions = [];
if (!dryRun) mkdirSync(installDir, { recursive: true });
verifyCandidate(repoIx);

try {
  for (const aliasPath of aliases) actions.push(promoteAlias(aliasPath, repoHash));
} catch (error) {
  if (!dryRun) {
    for (const action of actions.reverse()) {
      if (!action.changed) continue;
      rmSync(action.alias, { force: true });
      if (action.backup?.path && existsSync(action.backup.path)) renameSync(action.backup.path, action.alias);
    }
  }
  throw error;
}

console.log(JSON.stringify({
  status: "ok",
  dryRun,
  repo: {
    path: repoIx,
    sha256: repoHash,
    freshness,
  },
  installDir,
  actions,
}, null, 2));
