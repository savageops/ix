import { createHash } from "node:crypto";
import { copyFileSync, existsSync, mkdirSync, mkdtempSync, readFileSync, readdirSync, renameSync, rmSync, statSync } from "node:fs";
import { spawnSync } from "node:child_process";
import os from "node:os";
import path from "node:path";
import { argValue } from "./lib/script-helpers.mjs";
import { assertRepoBinaryFresh } from "./lib/speed-compare-utils.mjs";

const ROOT = process.cwd();
const DEFAULT_REPO_IX = path.join(ROOT, "zig-out", "bin", "ix-zig.exe");
const DEFAULT_INSTALL_DIR = path.join(os.homedir(), "AppData", "ix");
const LEGACY_INSTALL_DIR = path.join(os.homedir(), "AppData", "Local", "Programs", "iEx", "bin");
const DEFAULT_STATE_DIR = path.join(os.homedir(), ".ix");
const LEGACY_STATE_DIR = path.join(os.homedir(), "AppData", "Local", "ix");

const args = process.argv.slice(2);
if (args.includes("--help") || args.includes("-h")) {
  console.log(`Usage: node tools/scripts/sync-native-install.mjs [options]

Proves the repo IX candidate, stages the single native executable, archives every
predecessor under ix/backups, atomically promotes, and verifies the owner path.

Options:
  --build                 Run tests and build repo IX ReleaseSmall before syncing.
  --repo-ix <path>        Repo IX binary. Default: zig-out/bin/ix-zig.exe.
  --install-dir <path>    Native install directory.
                          Default: ~/AppData/ix.
  --dry-run               Print planned actions without copying files.
  --help, -h              Print this help.
`);
  process.exit(0);
}

const buildFirst = args.includes("--build");
const dryRun = args.includes("--dry-run");
const repoIx = path.resolve(argValue(args, "--repo-ix", DEFAULT_REPO_IX));
const installDir = path.resolve(argValue(args, "--install-dir", DEFAULT_INSTALL_DIR));
const installedIx = path.join(installDir, "ix.exe");
const backupDir = path.join(installDir, "backups");
const isDefaultInstall = path.resolve(installDir) === path.resolve(DEFAULT_INSTALL_DIR);

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
  const stem = path.basename(aliasPath, extension);
  const base = path.join(backupDir, `${stem}.old.${date}${extension}`);
  if (!existsSync(base)) return base;
  for (let suffix = 2; ; suffix += 1) {
    const candidate = path.join(backupDir, `${stem}.old.${date}.${suffix}${extension}`);
    if (!existsSync(candidate)) return candidate;
  }
}

function uniqueBackupPath(fileName) {
  const base = path.join(backupDir, fileName);
  if (!existsSync(base)) return base;
  for (let suffix = 2; ; suffix += 1) {
    const candidate = path.join(backupDir, `${fileName}.${suffix}`);
    if (!existsSync(candidate)) return candidate;
  }
}

/// Removes the obsolete iex alias and root-level predecessor sprawl without deleting evidence.
function archiveLegacySiblings() {
  const moves = [];
  if (!existsSync(installDir)) return moves;
  for (const entry of readdirSync(installDir, { withFileTypes: true })) {
    if (!entry.isFile() || entry.name.toLowerCase() === "ix.exe") continue;
    const lower = entry.name.toLowerCase();
    if (!lower.startsWith("ix") && !lower.startsWith("iex")) continue;
    const source = path.join(installDir, entry.name);
    const destination = uniqueBackupPath(entry.name);
    if (!dryRun) renameSync(source, destination);
    moves.push({ source, destination });
  }
  return moves;
}

/// Moves a directory only when the canonical destination is absent; conflicts are
/// archived whole so partially compatible index generations are never interleaved.
function migrateStateRoot(source, destination, label) {
  if (!existsSync(source) || path.resolve(source) === path.resolve(destination)) return null;
  if (dryRun) return { source, destination: existsSync(destination) ? uniqueBackupPath(`${label}-state`) : destination, conflict: existsSync(destination) };
  if (!existsSync(destination)) {
    mkdirSync(path.dirname(destination), { recursive: true });
    renameSync(source, destination);
    return { source, destination, conflict: false };
  }
  const archived = uniqueBackupPath(`${label}-state`);
  renameSync(source, archived);
  return { source, destination: archived, conflict: true };
}

/// Consolidates predecessor files from an older backup directory without overwriting evidence.
function migrateBackupDirectory(sourceDir) {
  const moves = [];
  if (!existsSync(sourceDir) || path.resolve(sourceDir) === path.resolve(backupDir)) return moves;
  for (const entry of readdirSync(sourceDir, { withFileTypes: true })) {
    const source = path.join(sourceDir, entry.name);
    const destination = uniqueBackupPath(entry.name);
    if (!dryRun) renameSync(source, destination);
    moves.push({ source, destination });
  }
  if (!dryRun) rmSync(sourceDir, { recursive: true, force: true });
  return moves;
}

/// Retires the previous Programs/iEx/bin layout after its state and backups are safe.
function migrateLegacyInstall() {
  const moves = migrateBackupDirectory(path.join(LEGACY_INSTALL_DIR, "ix", "backups"));
  if (!existsSync(LEGACY_INSTALL_DIR)) return moves;
  for (const entry of readdirSync(LEGACY_INSTALL_DIR, { withFileTypes: true })) {
    const source = path.join(LEGACY_INSTALL_DIR, entry.name);
    if (entry.isDirectory()) continue;
    const lower = entry.name.toLowerCase();
    if (!lower.startsWith("ix") && !lower.startsWith("iex")) continue;
    const destination = uniqueBackupPath(entry.name);
    if (!dryRun) renameSync(source, destination);
    moves.push({ source, destination });
  }
  if (!dryRun) {
    const ixDir = path.join(LEGACY_INSTALL_DIR, "ix");
    if (existsSync(ixDir) && readdirSync(ixDir).length === 0) rmSync(ixDir, { recursive: true, force: true });
    if (readdirSync(LEGACY_INSTALL_DIR).length === 0) rmSync(LEGACY_INSTALL_DIR, { recursive: true, force: true });
  }
  return moves;
}

/// Updates only the persistent user PATH and removes the retired install entry.
/// The parent shell keeps its current process environment until restarted.
function updateUserPath() {
  if (dryRun || !isDefaultInstall) return { changed: false, reason: dryRun ? "dry_run" : "custom_install_dir" };
  const script = [
    "$parts = @([Environment]::GetEnvironmentVariable('Path','User') -split ';' | Where-Object { $_ })",
    "$legacy = $env:IX_LEGACY_INSTALL",
    "$current = $env:IX_CURRENT_INSTALL",
    "$next = @($parts | Where-Object { -not [string]::Equals($_.TrimEnd('\\'), $legacy.TrimEnd('\\'), [StringComparison]::OrdinalIgnoreCase) })",
    "if (-not ($next | Where-Object { [string]::Equals($_.TrimEnd('\\'), $current.TrimEnd('\\'), [StringComparison]::OrdinalIgnoreCase) })) { $next += $current }",
    "[Environment]::SetEnvironmentVariable('Path', ($next -join ';'), 'User')",
  ].join("; ");
  const result = spawnSync("powershell", ["-NoProfile", "-NonInteractive", "-Command", script], {
    encoding: "utf8",
    windowsHide: true,
    env: { ...process.env, IX_LEGACY_INSTALL: LEGACY_INSTALL_DIR, IX_CURRENT_INSTALL: installDir },
  });
  if (result.status !== 0) throw new Error(`user PATH migration failed: ${result.stderr.trim()}`);
  return { changed: true, removed: LEGACY_INSTALL_DIR, added: installDir };
}

function verifyCandidate(binaryPath) {
  // Promotion proof must never create, mutate, or warm the user's real index.
  const verificationState = mkdtempSync(path.join(os.tmpdir(), "ix-native-verify-"));
  try {
    run(binaryPath, ["help", "search"], { quiet: true });
    const probe = (indexEnabled) => {
      const result = spawnSync(binaryPath, ["search", "lit:pub", "src/main.zig", "--format", "json-compact", "--total-count", "1", "--max-bytes", "4096"], {
        cwd: ROOT,
        encoding: "utf8",
        windowsHide: true,
        env: { ...process.env, IX_INDEX: indexEnabled ? "1" : "0", IX_STATE_DIR: verificationState },
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
  } finally {
    rmSync(verificationState, { recursive: true, force: true });
  }
}

function promoteInstalledIx(installedPath, repoHash) {
  const beforeHash = existsSync(installedPath) ? sha256File(installedPath) : null;
  if (beforeHash === repoHash) return { path: installedPath, beforeHash, afterHash: repoHash, backup: null, changed: false };
  const backupPath = existsSync(installedPath) ? rollbackPath(installedPath) : null;
  const stagedPath = `${installedPath}.candidate-${process.pid}`;
  if (dryRun) return { path: installedPath, beforeHash, afterHash: repoHash, backup: backupPath, changed: true };

  copyFileSync(repoIx, stagedPath);
  if (sha256File(stagedPath) !== repoHash) {
    rmSync(stagedPath, { force: true });
    throw new Error(`${installedPath}: staged candidate hash mismatch`);
  }
  try {
    if (backupPath) renameSync(installedPath, backupPath);
    renameSync(stagedPath, installedPath);
    verifyCandidate(installedPath);
    if (sha256File(installedPath) !== repoHash) throw new Error(`${installedPath}: installed hash mismatch`);
  } catch (error) {
    rmSync(stagedPath, { force: true });
    rmSync(installedPath, { force: true });
    if (backupPath && existsSync(backupPath)) renameSync(backupPath, installedPath);
    throw error;
  }
  return {
    path: installedPath,
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
if (!dryRun) {
  mkdirSync(installDir, { recursive: true });
  mkdirSync(backupDir, { recursive: true });
}
verifyCandidate(repoIx);

try {
  actions.push(promoteInstalledIx(installedIx, repoHash));
} catch (error) {
  if (!dryRun) {
    for (const action of actions.reverse()) {
      if (!action.changed) continue;
      rmSync(action.path, { force: true });
      if (action.backup?.path && existsSync(action.backup.path)) renameSync(action.backup.path, action.path);
    }
  }
  throw error;
}
const archived = archiveLegacySiblings();
const stateMigrations = isDefaultInstall ? [
  migrateStateRoot(LEGACY_STATE_DIR, DEFAULT_STATE_DIR, "localappdata-ix"),
  migrateStateRoot(path.join(LEGACY_INSTALL_DIR, ".ix"), DEFAULT_STATE_DIR, "install-dot-ix"),
].filter(Boolean) : [];
const legacyInstallMoves = isDefaultInstall ? migrateLegacyInstall() : [];
const pathMigration = updateUserPath();

console.log(JSON.stringify({
  status: "ok",
  dryRun,
  repo: {
    path: repoIx,
    sha256: repoHash,
    freshness,
  },
  installDir,
  backupDir,
  actions,
  archived,
  stateMigrations,
  legacyInstallMoves,
  pathMigration,
}, null, 2));
