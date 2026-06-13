import { createHash } from "node:crypto";
import { copyFileSync, existsSync, mkdirSync, readFileSync, statSync } from "node:fs";
import { spawnSync } from "node:child_process";
import os from "node:os";
import path from "node:path";
import { argValue, timestampSlug } from "./lib/script-helpers.mjs";

const ROOT = process.cwd();
const DEFAULT_REPO_IX = path.join(ROOT, "zig-out", "bin", "ix-zig.exe");
const DEFAULT_INSTALL_DIR = path.join(os.homedir(), "AppData", "Local", "Programs", "iEx", "bin");

const args = process.argv.slice(2);
if (args.includes("--help") || args.includes("-h")) {
  console.log(`Usage: node tools/scripts/sync-native-install.mjs [options]

Builds or verifies the repo IX binary, backs up existing native aliases, copies
the repo binary to the native install path, and verifies alias hashes.

Options:
  --build                 Build repo IX ReleaseFast before syncing.
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

function run(command, commandArgs) {
  const result = spawnSync(command, commandArgs, {
    cwd: ROOT,
    encoding: "utf8",
    stdio: "inherit",
    windowsHide: true,
  });
  if ((result.status ?? 0) !== 0) {
    throw new Error(`${command} ${commandArgs.join(" ")} failed with exit code ${result.status}`);
  }
}

function backupAlias(aliasPath, slug) {
  if (!existsSync(aliasPath)) return null;
  const backupPath = `${aliasPath}.backup-${slug}`;
  if (!dryRun) copyFileSync(aliasPath, backupPath);
  return {
    path: backupPath,
    bytes: statSync(aliasPath).size,
    sha256: sha256File(aliasPath),
  };
}

if (process.platform !== "win32") {
  throw new Error("native install sync is currently Windows-only");
}

if (buildFirst) {
  run(resolveZigExe(), ["build", "-Doptimize=ReleaseFast", "--summary", "all"]);
}
if (!existsSync(repoIx)) {
  throw new Error(`repo IX binary missing: ${repoIx}`);
}

const repoHash = sha256File(repoIx);
const slug = timestampSlug();
const actions = [];
if (!dryRun) mkdirSync(installDir, { recursive: true });

for (const aliasPath of aliases) {
  const beforeHash = existsSync(aliasPath) ? sha256File(aliasPath) : null;
  const backup = beforeHash === repoHash ? null : backupAlias(aliasPath, slug);
  if (!dryRun) copyFileSync(repoIx, aliasPath);
  const afterHash = dryRun ? repoHash : sha256File(aliasPath);
  if (afterHash !== repoHash) {
    throw new Error(`${aliasPath}: copied hash ${afterHash} did not match repo hash ${repoHash}`);
  }
  actions.push({
    alias: aliasPath,
    beforeHash,
    afterHash,
    backup,
    changed: beforeHash !== repoHash,
  });
}

console.log(JSON.stringify({
  status: "ok",
  dryRun,
  repo: {
    path: repoIx,
    sha256: repoHash,
  },
  installDir,
  actions,
}, null, 2));
