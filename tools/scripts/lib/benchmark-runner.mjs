import { appendFileSync, existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { execFileSync, spawnSync } from "node:child_process";
import { createHash } from "node:crypto";
import os from "node:os";
import path from "node:path";
import { classifyHotspot, computeRatio, computeSpeedupPct, summarizeSeries } from "./metrics.mjs";

const ROOT = process.cwd();
const REPORT_DIR = path.join(ROOT, "tools", "reports");
const COMPETITOR_CONFIG = path.join(ROOT, "tools", "scripts", "competitors.json");
const DEFAULT_CORPUS = path.join(ROOT, "tools", "data", "corpus");
const DEFAULT_EXPR = "lit:ERROR && lit:timeout";
const DEFAULT_SCENARIO_ID = "cli_stats_only_search";
let zigBuilt = false;

const REPORT_FILESETS = {
  [DEFAULT_SCENARIO_ID]: {
    liveJsonl: path.join(REPORT_DIR, "live-metrics.jsonl"),
    latestJson: path.join(REPORT_DIR, "latest.json"),
  },
};

export function resolveBenchmarkReportPaths(options = {}) {
  const scenarioId = options.scenarioId ?? DEFAULT_SCENARIO_ID;
  const reportPaths = REPORT_FILESETS[scenarioId];
  if (!reportPaths) {
    throw new Error(`unsupported benchmark scenario "${scenarioId}"`);
  }
  return reportPaths;
}

export function resolveExplicitBinaryPath(binaryPath, label = "ix binary") {
  if (!binaryPath) {
    return null;
  }

  const resolved = path.resolve(ROOT, binaryPath);
  if (!existsSync(resolved)) {
    throw new Error(`explicit ${label} not found at ${resolved}`);
  }

  return resolved;
}

function binaryName() {
  return process.platform === "win32" ? "ix-zig.exe" : "ix-zig";
}

function zigBinaryPath() {
  return path.join(ROOT, "zig-out", "bin", binaryName());
}

function resolveZigExe() {
  const envZig = process.env.ZIG_EXE;
  if (envZig && existsSync(envZig)) return envZig;

  // Well-known local install location (not on PATH)
  const localZig = path.join(
    os.homedir(),
    ".local",
    "zig",
    `zig-x86_64-${process.platform === "win32" ? "windows" : "linux"}-0.16.0`,
    process.platform === "win32" ? "zig.exe" : "zig",
  );
  if (existsSync(localZig)) return localZig;

  return "zig";
}

export function ensureBinaryPath() {
  const bin = zigBinaryPath();

  if (!zigBuilt || !existsSync(bin)) {
    const zigExe = resolveZigExe();
    execFileSync(zigExe, ["build", "-Doptimize=ReleaseFast"], {
      cwd: ROOT,
      env: process.env,
      stdio: "inherit",
    });
    zigBuilt = true;
  }

  return bin;
}

export function resolveIxBinaryPath(options = {}) {
  const explicit = resolveExplicitBinaryPath(options.ixBinaryPath, "ix-zig binary");
  if (explicit) {
    return explicit;
  }

  return ensureBinaryPath();
}

export function runTimedCommand(command, args, allowedCodes = [0], options = {}) {
  const captureStdout = options.captureStdout ?? true;
  const captureStderr = options.captureStderr ?? true;
  const stdio = captureStdout
    ? (captureStderr ? "pipe" : ["ignore", "pipe", "ignore"])
    : (captureStderr ? ["ignore", "ignore", "pipe"] : "ignore");

  const started = process.hrtime.bigint();
  const result = spawnSync(command, args, {
    cwd: ROOT,
    env: { ...process.env, ...(options.env ?? {}) },
    encoding: "utf8",
    stdio,
    maxBuffer: 128 * 1024 * 1024,
    windowsHide: true,
  });
  const ended = process.hrtime.bigint();
  const durationMs = Number(ended - started) / 1_000_000;

  const status = result.status ?? 0;
  if (!allowedCodes.includes(status)) {
    const stderr = result.stderr?.toString() ?? "";
    throw new Error(`command failed (${command} ${args.join(" ")}): code=${status}\n${stderr}`);
  }

  return {
    durationMs,
    stdout: captureStdout ? (result.stdout?.toString() ?? "") : "",
    stderr: captureStderr ? (result.stderr?.toString() ?? "") : "",
    status,
  };
}

function runMeasuredCommand(command, args, allowedCodes, options = {}) {
  const warmup = Math.max(0, Number(options.warmup ?? 0));
  const samples = Math.max(1, Number(options.samples ?? 1));

  for (let i = 0; i < warmup; i += 1) {
    runTimedCommand(command, args, allowedCodes, options);
  }

  const measuredRuns = [];
  for (let i = 0; i < samples; i += 1) {
    const current = runTimedCommand(command, args, allowedCodes, options);
    measuredRuns.push({
      ...current,
      sampleIndex: i,
    });
  }

  measuredRuns.sort((left, right) => left.durationMs - right.durationMs);
  const medianIndex = Math.floor(measuredRuns.length / 2);
  return {
    ...measuredRuns[medianIndex],
    selectionStrategy: "median_duration",
    sampleDurationsMs: measuredRuns.map((run) => run.durationMs),
  };
}

function buildIxSearchArgs({ expression, corpus, threads }) {
  const args = [
    "search",
    expression,
    corpus,
    "--json",
    "--stats-only",
  ];

  if (typeof threads === "number" && Number.isFinite(threads) && threads > 0) {
    args.push("--threads", String(Math.floor(threads)));
  }

  return args;
}

function parseIxReport(stdout) {
  try {
    return JSON.parse(stdout || "{}");
  } catch {
    return null;
  }
}

function fileSha256(filePath) {
  return createHash("sha256").update(readFileSync(filePath)).digest("hex");
}

function findGitRoot(startPath) {
  let current = path.resolve(startPath);
  if (!existsSync(current)) return null;
  while (true) {
    if (existsSync(path.join(current, ".git"))) return current;
    const parent = path.dirname(current);
    if (parent === current) return null;
    current = parent;
  }
}

function gitValue(root, args) {
  if (!root) return null;
  try {
    return execFileSync("git", ["-C", root, ...args], {
      cwd: ROOT,
      encoding: "utf8",
      stdio: ["ignore", "pipe", "ignore"],
      windowsHide: true,
    }).trim();
  } catch {
    return null;
  }
}

function binaryIdentity(binaryPath) {
  const resolved = path.resolve(ROOT, binaryPath);
  const gitRoot = findGitRoot(path.dirname(resolved));
  return {
    binaryPath: resolved,
    sha256: existsSync(resolved) ? fileSha256(resolved) : null,
    gitRoot,
    gitHead: gitValue(gitRoot, ["rev-parse", "HEAD"]),
    gitStatusShort: gitValue(gitRoot, ["status", "--short"]),
  };
}

function compareBinaryIdentities(currentIdentity, previousIdentity) {
  if (!currentIdentity || !previousIdentity) {
    return "unknown";
  }
  if (currentIdentity.sha256 && currentIdentity.sha256 === previousIdentity.sha256) {
    return "same_binary";
  }
  if (currentIdentity.gitHead && currentIdentity.gitHead === previousIdentity.gitHead) {
    return "same_source_different_binary";
  }
  if (currentIdentity.gitHead && previousIdentity.gitHead) {
    return "different_source";
  }
  return "different_binary_unknown_source";
}

function sampleSummary(values) {
  return summarizeSeries(values ?? []);
}

function safeCommand(command, args) {
  const result = spawnSync(command, args, {
    cwd: ROOT,
    encoding: "utf8",
    stdio: "pipe",
    maxBuffer: 1024 * 1024,
    windowsHide: true,
  });
  if (result.error || result.status !== 0) {
    return null;
  }
  return (result.stdout ?? "").toString().trim();
}

function parsePowerScheme(text) {
  if (!text) return null;
  const match = text.match(/Power Scheme GUID:\s+([^\s]+)\s+\(([^)]+)\)/i);
  if (!match) return { raw: text };
  return {
    guid: match[1],
    name: match[2],
    raw: text,
  };
}

function processSnapshot(sortProperty) {
  if (process.platform !== "win32") return [];
  const json = safeCommand("powershell", [
    "-NoProfile",
    "-Command",
    `Get-Process | Sort-Object ${sortProperty} -Descending | Select-Object -First 8 Id,ProcessName,CPU,WorkingSet64 | ConvertTo-Json -Compress`,
  ]);
  if (!json) return [];
  try {
    const parsed = JSON.parse(json);
    return Array.isArray(parsed) ? parsed : [parsed];
  } catch {
    return [];
  }
}

function topProcessSnapshot() {
  return processSnapshot("WorkingSet64");
}

function topCpuProcessSnapshot() {
  return processSnapshot("CPU");
}

function classifyHostForBenchmark(snapshot) {
  const issues = [];
  const powerName = snapshot.powerScheme?.name?.toLowerCase?.() ?? "";
  if (process.platform === "win32" && powerName && !powerName.includes("performance")) {
    issues.push({
      id: "non_performance_power_plan",
      severity: "warning",
      detail: snapshot.powerScheme?.name ?? "unknown",
    });
  }
  const topNames = new Set((snapshot.topProcessesByWorkingSet ?? []).map((entry) => String(entry.ProcessName ?? "").toLowerCase()));
  if (topNames.has("msmpeng")) {
    issues.push({
      id: "defender_active_in_top_working_set",
      severity: "warning",
      detail: "MsMpEng appeared among top working-set processes",
    });
  }
  const browserOrAgentCount = [...topNames].filter((name) => name === "chrome" || name === "codex").length;
  if (browserOrAgentCount >= 2) {
    issues.push({
      id: "interactive_workloads_present",
      severity: "info",
      detail: "Codex or Chrome processes appeared among top working-set processes",
    });
  }
  const freeMemRatio = snapshot.totalMemBytes > 0 ? snapshot.freeMemBytes / snapshot.totalMemBytes : 1;
  if (freeMemRatio < 0.2) {
    issues.push({
      id: "low_available_memory",
      severity: "warning",
      detail: `${Math.round(freeMemRatio * 100)}% free`,
    });
  }
  const warningCount = issues.filter((issue) => issue.severity === "warning").length;
  return {
    status: warningCount === 0 ? "clean" : "noisy",
    issues,
  };
}

export function hostSnapshot() {
  const cpus = os.cpus();
  const cpuSpeeds = cpus.map((cpu) => cpu.speed).filter((speed) => Number.isFinite(speed));
  const powerScheme = process.platform === "win32" ? parsePowerScheme(safeCommand("powercfg", ["/getactivescheme"])) : null;
  const snapshot = {
    timestamp: new Date().toISOString(),
    platform: process.platform,
    arch: process.arch,
    release: os.release(),
    uptimeSec: os.uptime(),
    availableParallelism: os.availableParallelism(),
    totalMemBytes: os.totalmem(),
    freeMemBytes: os.freemem(),
    loadavg: os.loadavg(),
    cpu: {
      model: cpus[0]?.model ?? null,
      logicalCount: cpus.length,
      speedMinMhz: cpuSpeeds.length ? Math.min(...cpuSpeeds) : null,
      speedMaxMhz: cpuSpeeds.length ? Math.max(...cpuSpeeds) : null,
      speedMeanMhz: cpuSpeeds.length ? Math.round(cpuSpeeds.reduce((sum, speed) => sum + speed, 0) / cpuSpeeds.length) : null,
    },
    powerScheme,
    topProcessesByWorkingSet: topProcessSnapshot(),
    topProcessesByCpu: topCpuProcessSnapshot(),
  };
  snapshot.benchmarkEnvironment = classifyHostForBenchmark(snapshot);
  return snapshot;
}

function measureIxSearch(binaryPath, context, measureOptions) {
  const args = buildIxSearchArgs(context);
  const warmup = Math.max(0, Number(measureOptions.warmup ?? 0));
  const samples = Math.max(1, Number(measureOptions.samples ?? 1));

  for (let i = 0; i < warmup; i += 1) {
    runTimedCommand(binaryPath, args, [0], measureOptions);
  }

  const measuredRuns = [];
  for (let i = 0; i < samples; i += 1) {
    const result = runTimedCommand(binaryPath, args, [0], measureOptions);
    const report = parseIxReport(result.stdout);
    if (result.stdout?.trim() && !report) {
      throw new Error(`IX-Zig benchmark output was not valid JSON for ${binaryPath}`);
    }
    const engineMs = report?.stats?.timings?.total_ms ?? result.durationMs;
    measuredRuns.push({
      result,
      report,
      engineMs,
      cliMs: result.durationMs,
      sampleIndex: i,
    });
  }

  const byEngine = [...measuredRuns].sort((left, right) => left.engineMs - right.engineMs);
  const medianIndex = Math.floor(byEngine.length / 2);
  const selected = byEngine[medianIndex];
  const engineSamples = byEngine.map((run) => run.engineMs);
  const cliSamples = [...measuredRuns].sort((left, right) => left.cliMs - right.cliMs).map((run) => run.cliMs);

  return {
    binaryPath,
    args,
    result: {
      ...selected.result,
      selectionStrategy: "median_engine_duration",
      sampleDurationsMs: cliSamples,
    },
    report: selected.report,
    engineMs: selected.engineMs,
    cliMs: selected.cliMs,
    processOverheadMs: Math.max(0, selected.cliMs - selected.engineMs),
    sampleDurationsMs: cliSamples,
    engineSampleDurationsMs: engineSamples,
    sampleSummary: sampleSummary(cliSamples),
    engineSampleSummary: sampleSummary(engineSamples),
    timingSource: selected.report?.stats?.timings?.total_ms ? "engine_total_ms" : "wall_clock_ms",
  };
}

function measuredIxEntry(binaryPath, args, result, sampleIndex) {
  const report = parseIxReport(result.stdout);
  if (result.stdout?.trim() && !report) {
    throw new Error(`IX-Zig benchmark output was not valid JSON for ${binaryPath}`);
  }
  const engineMs = report?.stats?.timings?.total_ms ?? result.durationMs;
  return {
    result,
    report,
    engineMs,
    cliMs: result.durationMs,
    sampleIndex,
  };
}

function summarizeIxEntries(binaryPath, args, measuredRuns) {
  const byEngine = [...measuredRuns].sort((left, right) => left.engineMs - right.engineMs);
  const medianIndex = Math.floor(byEngine.length / 2);
  const selected = byEngine[medianIndex];
  const engineSamples = byEngine.map((run) => run.engineMs);
  const cliSamples = [...measuredRuns].sort((left, right) => left.cliMs - right.cliMs).map((run) => run.cliMs);

  return {
    binaryPath,
    args,
    result: {
      ...selected.result,
      selectionStrategy: "median_engine_duration",
      sampleDurationsMs: cliSamples,
    },
    report: selected.report,
    engineMs: selected.engineMs,
    cliMs: selected.cliMs,
    processOverheadMs: Math.max(0, selected.cliMs - selected.engineMs),
    sampleDurationsMs: cliSamples,
    engineSampleDurationsMs: engineSamples,
    sampleSummary: sampleSummary(cliSamples),
    engineSampleSummary: sampleSummary(engineSamples),
    timingSource: selected.report?.stats?.timings?.total_ms ? "engine_total_ms" : "wall_clock_ms",
  };
}

function measurePairedIxSearch(currentBinaryPath, previousBinaryPath, context, measureOptions) {
  const currentArgs = buildIxSearchArgs(context);
  const previousArgs = buildIxSearchArgs(context);
  const resolvedPreviousBinaryPath = resolveExplicitBinaryPath(previousBinaryPath);
  const warmup = Math.max(0, Number(measureOptions.warmup ?? 0));
  const samples = Math.max(1, Number(measureOptions.samples ?? 1));

  for (let i = 0; i < warmup; i += 1) {
    runTimedCommand(currentBinaryPath, currentArgs, [0], measureOptions);
    runTimedCommand(resolvedPreviousBinaryPath, previousArgs, [0], measureOptions);
  }

  const currentRuns = [];
  const previousRuns = [];
  const pairOrder = [];
  for (let i = 0; i < samples; i += 1) {
    const currentFirst = i % 2 === 0;
    pairOrder.push(currentFirst ? "current,previous" : "previous,current");
    if (currentFirst) {
      currentRuns.push(measuredIxEntry(currentBinaryPath, currentArgs, runTimedCommand(currentBinaryPath, currentArgs, [0], measureOptions), i));
      previousRuns.push(measuredIxEntry(resolvedPreviousBinaryPath, previousArgs, runTimedCommand(resolvedPreviousBinaryPath, previousArgs, [0], measureOptions), i));
    } else {
      previousRuns.push(measuredIxEntry(resolvedPreviousBinaryPath, previousArgs, runTimedCommand(resolvedPreviousBinaryPath, previousArgs, [0], measureOptions), i));
      currentRuns.push(measuredIxEntry(currentBinaryPath, currentArgs, runTimedCommand(currentBinaryPath, currentArgs, [0], measureOptions), i));
    }
  }

  return {
    current: summarizeIxEntries(currentBinaryPath, currentArgs, currentRuns),
    previous: summarizeIxEntries(resolvedPreviousBinaryPath, previousArgs, previousRuns),
    pairing: {
      mode: "interleaved_current_previous",
      pairOrder,
    },
  };
}

function commandExists(command) {
  if (!command) {
    return false;
  }
  const result = spawnSync(command, ["--version"], {
    cwd: ROOT,
    encoding: "utf8",
    windowsHide: true,
  });
  return !result.error && result.status !== null;
}

export function resolveCompetitorCommand(competitor) {
  const probes = [];
  if (Array.isArray(competitor?.probes)) {
    probes.push(...competitor.probes);
  }
  if (competitor?.command) {
    probes.push(competitor.command);
  }

  for (const probe of probes) {
    if (commandExists(probe)) {
      return probe;
    }
  }
  return null;
}

function renderArgs(templateArgs, context) {
  return templateArgs.map((token) => {
    return token
      .replaceAll("{{regex}}", context.regex)
      .replaceAll("{{corpus}}", context.corpus)
      .replaceAll("{{expr}}", context.expression);
  });
}

const REGEX_META_CHARS = new Set([".", "*", "+", "?", "^", "$", "(", ")", "[", "]", "{", "}", "|"]);
const ESCAPABLE_LITERAL_CHARS = new Set(["\\", ".", "*", "+", "?", "^", "$", "(", ")", "[", "]", "{", "}", "|"]);

function hasFlag(args, flag) {
  return args.some((arg) => arg === flag || arg.startsWith(`${flag}=`));
}

function splitUnescapedAlternates(pattern) {
  const parts = [];
  let current = "";
  let escaped = false;

  for (const char of pattern) {
    if (escaped) {
      current += char;
      escaped = false;
      continue;
    }

    if (char === "\\") {
      current += char;
      escaped = true;
      continue;
    }

    if (char === "|") {
      parts.push(current);
      current = "";
      continue;
    }

    current += char;
  }

  parts.push(current);
  return parts;
}

function tryRegexLiteral(pattern) {
  let literal = "";
  let escaped = false;

  for (const char of pattern) {
    if (escaped) {
      if (!ESCAPABLE_LITERAL_CHARS.has(char)) {
        return null;
      }
      literal += char;
      escaped = false;
      continue;
    }

    if (char === "\\") {
      escaped = true;
      continue;
    }

    if (REGEX_META_CHARS.has(char)) {
      return null;
    }

    literal += char;
  }

  if (escaped) {
    return null;
  }

  return literal.length > 0 ? literal : null;
}

function fixedPlanFromRegexSource(regexSource) {
  let source = regexSource.trim();
  let ignoreCase = false;
  let wordRegexp = false;

  if (source.startsWith("(?i)")) {
    ignoreCase = true;
    source = source.slice(4);
  }

  if (source.startsWith("\\b") && source.endsWith("\\b") && source.length > 4) {
    wordRegexp = true;
    source = source.slice(2, -2);
  }

  if (source.startsWith("(") && source.endsWith(")")) {
    const alternates = splitUnescapedAlternates(source.slice(1, -1));
    if (alternates.length > 1) {
      const patterns = alternates.map((token) => tryRegexLiteral(token));
      if (patterns.every((token) => token !== null)) {
        return {
          mode: "fixed",
          patterns,
          ignoreCase,
          wordRegexp,
        };
      }
    }
  }

  const literal = tryRegexLiteral(source);
  if (literal !== null) {
    return {
      mode: "fixed",
      patterns: [literal],
      ignoreCase,
      wordRegexp,
    };
  }

  return null;
}

function fixedPlanFromExpression(expression) {
  const expr = expression.trim();
  if (!expr) {
    return null;
  }

  if (expr.startsWith("lit:")) {
    return {
      mode: "fixed",
      patterns: [expr.slice(4)],
      ignoreCase: false,
      wordRegexp: false,
    };
  }

  if (expr.startsWith("re:")) {
    return fixedPlanFromRegexSource(expr.slice(3));
  }

  if (!expr.includes("||")) {
    return null;
  }

  const tokens = expr
    .split("||")
    .map((token) => token.trim())
    .filter(Boolean);
  if (tokens.length === 0) {
    return null;
  }

  const literals = tokens.map((token) => (token.startsWith("lit:") ? token.slice(4) : null));
  if (literals.some((token) => token === null)) {
    return null;
  }

  return {
    mode: "fixed",
    patterns: literals,
    ignoreCase: false,
    wordRegexp: false,
  };
}

function buildOptimizedRipgrepInvocation(context, templateArgs) {
  const staticArgs = (templateArgs ?? []).filter((token) => !token.includes("{{"));
  const availableThreads = Math.max(1, Number(context.availableThreads ?? 1));
  const fixedPlan = fixedPlanFromExpression(context.expression) ?? fixedPlanFromRegexSource(context.regex);

  const args = [...staticArgs];
  if (!hasFlag(args, "--threads")) {
    args.push("--threads", String(availableThreads));
  }
  if (!hasFlag(args, "--mmap") && !hasFlag(args, "--no-mmap")) {
    args.push("--mmap");
  }

  if (fixedPlan) {
    args.push("--fixed-strings");
    if (fixedPlan.ignoreCase) {
      args.push("--ignore-case");
    }
    if (fixedPlan.wordRegexp) {
      args.push("--word-regexp");
    }
    for (const pattern of fixedPlan.patterns) {
      args.push("-e", pattern);
    }
    args.push(context.corpus);
    return {
      args,
      strategy: {
        mode: "fixed",
        patternCount: fixedPlan.patterns.length,
        ignoreCase: fixedPlan.ignoreCase,
        wordRegexp: fixedPlan.wordRegexp,
        threads: availableThreads,
      },
    };
  }

  args.push("-e", context.regex, context.corpus);
  return {
    args,
    strategy: {
      mode: "regex",
      patternCount: 1,
      threads: availableThreads,
    },
  };
}

function escapeRegex(value) {
  return value.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
}

function inferRegexFromExpression(expression) {
  const expr = expression.trim();
  if (!expr) {
    return ".*";
  }

  if (expr.includes("||")) {
    const tokens = expr
      .split("||")
      .map((token) => token.trim())
      .filter(Boolean);
    const parts = tokens.map(tokenToRegex).filter(Boolean);
    return parts.length ? parts.join("|") : ".*";
  }

  if (expr.includes("&&")) {
    const tokens = expr
      .split("&&")
      .map((token) => token.trim())
      .filter(Boolean);
    const parts = tokens.map(tokenToRegex).filter(Boolean);
    if (parts.length === 2) {
      return `${parts[0]}.*${parts[1]}|${parts[1]}.*${parts[0]}`;
    }
    return parts.length ? parts.join(".*") : ".*";
  }

  return tokenToRegex(expr) || ".*";
}

function tokenToRegex(token) {
  if (token.startsWith("lit:")) {
    return escapeRegex(token.slice(4));
  }
  if (token.startsWith("prefix:")) {
    return `^${escapeRegex(token.slice(7))}`;
  }
  if (token.startsWith("suffix:")) {
    return `${escapeRegex(token.slice(7))}$`;
  }
  if (token.startsWith("re:")) {
    return token.slice(3);
  }
  return escapeRegex(token);
}

function loadCompetitors() {
  if (!existsSync(COMPETITOR_CONFIG)) {
    return [];
  }

  const parsed = JSON.parse(readFileSync(COMPETITOR_CONFIG, "utf8"));
  return parsed.competitors ?? [];
}

function measureIxCompetitor(context, measureOptions, binaryPath, { label, kind, competitorKey }) {
  if (!binaryPath) {
    return null;
  }

  const plannedArgs = buildIxSearchArgs(context);
  let resolvedBinaryPath = null;

  try {
    resolvedBinaryPath = resolveExplicitBinaryPath(binaryPath);
  } catch (error) {
    return {
      available: false,
      label,
      kind,
      command: "ix",
      resolvedCommand: path.resolve(ROOT, binaryPath),
      binaryPath: path.resolve(ROOT, binaryPath),
      args: plannedArgs,
      durationMs: null,
      cliDurationMs: null,
      processOverheadMs: null,
      status: null,
      reason: "binary_not_found",
      error: String(error.message ?? error),
      timingSource: null,
    };
  }

  try {
    const measured = measureIxSearch(resolvedBinaryPath, context, measureOptions);
    return ixMeasurementToCompetitor(measured, { label, kind, pairing: null });
  } catch (error) {
    return {
      available: false,
      label,
      kind,
      command: "ix",
      resolvedCommand: resolvedBinaryPath,
      binaryPath: resolvedBinaryPath,
      args: plannedArgs,
      durationMs: null,
      cliDurationMs: null,
      processOverheadMs: null,
      status: null,
      reason: "execution_failed",
      error: String(error.message ?? error),
      timingSource: null,
    };
  }
}

function ixMeasurementToCompetitor(measured, { label, kind, pairing }) {
  return {
    available: true,
    label,
    kind,
    command: "ix",
    resolvedCommand: measured.binaryPath,
    binaryPath: measured.binaryPath,
    binaryIdentity: binaryIdentity(measured.binaryPath),
    args: measured.args,
    durationMs: measured.engineMs,
    cliDurationMs: measured.cliMs,
    processOverheadMs: measured.processOverheadMs,
    sampleDurationsMs: measured.sampleDurationsMs,
    engineSampleDurationsMs: measured.engineSampleDurationsMs,
    sampleSummary: measured.sampleSummary,
    engineSampleSummary: measured.engineSampleSummary,
    status: measured.result.status,
    timingSource: measured.timingSource,
    matchCount: measured.report?.stats?.matches_found ?? null,
    pairing,
  };
}

function measurePreviousIxCompetitor(context, measureOptions, previousIxBinaryPath) {
  return measureIxCompetitor(context, measureOptions, previousIxBinaryPath, {
    label: "Rust IX predecessor",
    kind: "self-history",
    competitorKey: "iex_previous",
  });
}

function measureRustIxCompetitor(context, measureOptions, rustIxBinaryPath) {
  return measureIxCompetitor(context, measureOptions, rustIxBinaryPath, {
    label: "Rust IX",
    kind: "rust-counterpart",
    competitorKey: "iex_rust",
  });
}

function runCompetitors(context, measureOptions) {
  const competitors = loadCompetitors();
  const results = {};

  for (const competitor of competitors) {
    const { name, command, args, allowedCodes } = competitor;
    const suppressOutput = competitor.suppressOutput ?? true;
    const captureStdout = !suppressOutput;
    const resolvedCommand = resolveCompetitorCommand(competitor);

    if (!resolvedCommand) {
      results[name] = {
        available: false,
        command,
        resolvedCommand: null,
        args,
        durationMs: null,
        status: null,
        reason: "command_not_found",
        suppressOutput,
      };
      continue;
    }

    const optimizedInvocation =
      name === "ripgrep"
        ? buildOptimizedRipgrepInvocation(context, args ?? [])
        : { args: renderArgs(args ?? [], context), strategy: null };
    const renderedArgs = optimizedInvocation.args;
    try {
      const run = runMeasuredCommand(
        resolvedCommand,
        renderedArgs,
        allowedCodes ?? [0],
        {
          ...measureOptions,
          captureStdout,
          captureStderr: true,
        },
      );
      results[name] = {
        available: true,
        command,
        resolvedCommand,
        args: renderedArgs,
        strategy: optimizedInvocation.strategy,
        durationMs: run.durationMs,
        sampleDurationsMs: run.sampleDurationsMs ?? [],
        sampleSummary: sampleSummary(run.sampleDurationsMs ?? []),
        status: run.status,
        suppressOutput,
      };
    } catch (error) {
      results[name] = {
        available: true,
        command,
        resolvedCommand,
        args: renderedArgs,
        strategy: optimizedInvocation.strategy,
        durationMs: null,
        status: null,
        reason: "execution_failed",
        error: String(error.message ?? error),
        suppressOutput,
      };
    }
  }

  return results;
}

function diagnose(hotspot) {
  if (hotspot === "scan") {
    return "scan dominates: improve predicate selectivity and line scanning hot loops";
  }
  if (hotspot === "discover") {
    return "discovery dominates: improve traversal filters and path pruning";
  }
  return "aggregation dominates: optimize match materialization and report serialization";
}

function isNonAsciiCaseInsensitiveRegexExpression(expression) {
  if (typeof expression !== "string") {
    return false;
  }

  return expression.includes("re:(?i)") && /[^\x00-\x7F]/.test(expression);
}

function describeComparatorDiscipline(expression) {
  if (isNonAsciiCaseInsensitiveRegexExpression(expression)) {
    return {
      correctnessSensitive: true,
      comparisonDiscipline: "match_count_parity_required",
      correctnessNotes:
        "Non-ASCII case-insensitive regex lanes require match-count parity before previous-IX timing can be treated as authoritative.",
    };
  }

  return {
    correctnessSensitive: false,
    comparisonDiscipline: "standard",
    correctnessNotes: null,
  };
}

export function assessPreviousIxComparatorAuthority(options = {}) {
  const expression = options.expression ?? "";
  const previousAvailable = options.previousAvailable ?? false;
  const candidateMatchCount = options.candidateMatchCount;
  const previousMatchCount = options.previousMatchCount;

  if (!previousAvailable) {
    return {
      authority: "unavailable",
      matchCountParity: null,
      caveat: null,
    };
  }

  if (!isNonAsciiCaseInsensitiveRegexExpression(expression)) {
    return {
      authority: "authoritative",
      matchCountParity: null,
      caveat: null,
    };
  }

  const candidateFinite = Number.isFinite(candidateMatchCount);
  const previousFinite = Number.isFinite(previousMatchCount);
  if (candidateFinite && previousFinite && candidateMatchCount !== previousMatchCount) {
    return {
      authority: "timing_only",
      matchCountParity: false,
      caveat:
        "previous IX match-count mismatch on non-ASCII case-insensitive regex workload; treat previous-IX ratio as timing-only until parity is explained.",
    };
  }

  return {
    authority: "authoritative",
    matchCountParity: candidateFinite && previousFinite ? true : null,
    caveat: null,
  };
}

export function describeBenchmarkScenario(options = {}) {
  const scenarioId = options.scenarioId ?? DEFAULT_SCENARIO_ID;
  const corpus = options.corpus ?? DEFAULT_CORPUS;
  const expression = options.expression ?? DEFAULT_EXPR;
  const comparatorDiscipline = describeComparatorDiscipline(expression);

  return {
    id: DEFAULT_SCENARIO_ID,
    label: "CLI stats-only corpus replay",
    intent:
      "Measure repeated end-to-end CLI search on the same corpus and expression with scenario metadata attached for apples-to-apples comparisons.",
    contract:
      "Each measured sample repays CLI startup plus discovery plus scan; scenario metadata makes that blended cost explicit instead of pretending it is a single universal benchmark.",
    corpus,
    expression,
    statsOnly: options.statsOnly ?? true,
    preparedTargets: false,
    correctnessSensitive: comparatorDiscipline.correctnessSensitive,
    comparisonDiscipline: comparatorDiscipline.comparisonDiscipline,
    correctnessNotes: comparatorDiscipline.correctnessNotes,
  };
}

const RUN_ONE_BENCHMARK_OPTION_KEYS = new Set([
  "corpus",
  "expression",
  "ixBinaryPath",
  "pairedPreviousInterleave",
  "previousIxBinaryPath",
  "profile",
  "regex",
  "rustIxBinaryPath",
  "samples",
  "threads",
  "warmup",
  "write",
]);

function validateOptionKeys(owner, options, allowedKeys) {
  const unknownKeys = Object.keys(options).filter((key) => !allowedKeys.has(key));
  if (unknownKeys.length > 0) {
    throw new Error(
      `${owner} received unknown option(s): ${unknownKeys.join(", ")}. ` +
        `Use ${[...allowedKeys].sort().join(", ")}.`,
    );
  }
}

export function validateRunOneBenchmarkOptions(options = {}) {
  validateOptionKeys("runOneBenchmark", options, RUN_ONE_BENCHMARK_OPTION_KEYS);
}

export function runOneBenchmark(options = {}) {
  validateRunOneBenchmarkOptions(options);

  const expression = options.expression ?? DEFAULT_EXPR;
  const profile = options.profile ?? "default";
  const corpus = options.corpus ?? DEFAULT_CORPUS;
  const write = options.write ?? true;
  const ixBinaryPath = options.ixBinaryPath;
  const previousIxBinaryPath = options.previousIxBinaryPath;
  const pairedPreviousInterleave = options.pairedPreviousInterleave ?? false;
  const rustIxBinaryPath = options.rustIxBinaryPath;
  const threads = options.threads;
  const warmup = Number(options.warmup ?? 0);
  const samples = Number(options.samples ?? 1);
  const measureOptions = {
    warmup,
    samples,
    env: {
      IX_INDEX: "0",
      IX_NEXUS: "0",
    },
  };
  const hostBefore = hostSnapshot();

  const ixBin = resolveIxBinaryPath({ ixBinaryPath });
  const searchContext = { expression, corpus, threads };
  let ixMeasurement = null;
  let previousIx = null;
  let pairedMeasurement = null;
  if (previousIxBinaryPath && pairedPreviousInterleave) {
    try {
      pairedMeasurement = measurePairedIxSearch(ixBin, previousIxBinaryPath, searchContext, measureOptions);
      ixMeasurement = pairedMeasurement.current;
      previousIx = ixMeasurementToCompetitor(pairedMeasurement.previous, {
        label: "Rust IX predecessor",
        kind: "self-history",
        pairing: pairedMeasurement.pairing,
      });
    } catch {
      ixMeasurement = measureIxSearch(ixBin, searchContext, measureOptions);
      previousIx = measurePreviousIxCompetitor(searchContext, measureOptions, previousIxBinaryPath);
    }
  } else {
    ixMeasurement = measureIxSearch(ixBin, searchContext, measureOptions);
    previousIx = measurePreviousIxCompetitor(searchContext, measureOptions, previousIxBinaryPath);
  }
  const ixReport = ixMeasurement.report;
  const ixEngineMs = ixMeasurement.engineMs;
  const rustIx = measureRustIxCompetitor(searchContext, measureOptions, rustIxBinaryPath);

  const regex = options.regex ?? inferRegexFromExpression(expression);
  const competitors = runCompetitors(
    {
      expression,
      corpus,
      threads,
      regex,
      availableThreads: os.availableParallelism(),
    },
    measureOptions,
  );
  if (previousIx) {
    const previousIxAssessment = assessPreviousIxComparatorAuthority({
      expression,
      previousAvailable: previousIx.available,
      candidateMatchCount: ixReport?.stats?.matches_found ?? null,
      previousMatchCount: previousIx.matchCount ?? null,
    });
    previousIx.comparatorAuthority = previousIxAssessment.authority;
    previousIx.matchCountParity = previousIxAssessment.matchCountParity;
    previousIx.caveat = previousIxAssessment.caveat;
    competitors.iex_previous = previousIx;
  }
  if (rustIx) {
    const rustIxAssessment = assessPreviousIxComparatorAuthority({
      expression,
      previousAvailable: rustIx.available,
      candidateMatchCount: ixReport?.stats?.matches_found ?? null,
      previousMatchCount: rustIx.matchCount ?? null,
    });
    rustIx.comparatorAuthority = rustIxAssessment.authority;
    rustIx.matchCountParity = rustIxAssessment.matchCountParity;
    rustIx.caveat = rustIxAssessment.caveat;
    competitors.iex_rust = rustIx;
  }
  const rgMs = competitors?.ripgrep?.durationMs ?? 0;
  const iexToRgRatio = computeRatio(ixEngineMs, rgMs);
  const speedupPct = computeSpeedupPct(ixEngineMs, rgMs);
  const previousIxMs = competitors?.iex_previous?.durationMs ?? 0;
  const ixBinaryIdentity = binaryIdentity(ixBin);
  const previousIxBinaryIdentity = competitors?.iex_previous?.binaryIdentity ?? null;
  const scenario = describeBenchmarkScenario({ corpus, expression, statsOnly: true });
  const reportPaths = resolveBenchmarkReportPaths({ scenarioId: scenario.id });
  const hostAfter = hostSnapshot();

  const run = {
    runId: `${Date.now()}-${Math.random().toString(16).slice(2, 10)}`,
    timestamp: new Date().toISOString(),
    scenario,
    profile,
    expression,
    corpus,
    host: {
      before: hostBefore,
      after: hostAfter,
    },
    ixBinaryPath: ixBin,
    ixBinaryIdentity,
    previousIxBinaryPath: competitors?.iex_previous?.binaryPath ?? null,
    previousIxSourceRelation: compareBinaryIdentities(ixBinaryIdentity, previousIxBinaryIdentity),
    iexMs: ixEngineMs,
    iexCliMs: ixMeasurement.cliMs,
    iexProcessOverheadMs: ixMeasurement.processOverheadMs,
    iexSampleDurationsMs: ixMeasurement.sampleDurationsMs,
    iexEngineSampleDurationsMs: ixMeasurement.engineSampleDurationsMs,
    iexSampleSummary: ixMeasurement.sampleSummary,
    iexEngineSampleSummary: ixMeasurement.engineSampleSummary,
    rgMs,
    iexToRgRatio,
    iexToPreviousRatio: computeRatio(ixEngineMs, previousIxMs),
    previousIexAuthority: competitors?.iex_previous?.comparatorAuthority ?? null,
    previousIexMatchCountParity: competitors?.iex_previous?.matchCountParity ?? null,
    previousIexCaveat: competitors?.iex_previous?.caveat ?? null,
    speedupPct,
    competitors,
    phaseMs: {
      discover: ixReport?.stats?.timings?.discover_ms ?? 0,
      scan: ixReport?.stats?.timings?.scan_ms ?? 0,
      aggregate: ixReport?.stats?.timings?.aggregate_ms ?? 0,
      total: ixReport?.stats?.timings?.total_ms ?? ixMeasurement.cliMs,
    },
    slowestFiles: ixReport?.stats?.slowest_files ?? [],
    concurrency: ixReport?.stats?.concurrency ?? {},
    linuxStrategy: ixReport?.stats?.linux_strategy ?? {},
    linuxDominantFile: ixReport?.stats?.linux_dominant_file ?? {},
    regexDecomposition: ixReport?.stats?.regex_decomposition ?? {},
    fallbackLineScan: ixReport?.stats?.fallback_line_scan ?? {},
    matchCount: ixReport?.stats?.matches_found ?? 0,
    filesScanned: ixReport?.stats?.files_scanned ?? 0,
    filesSkipped: ixReport?.stats?.files_skipped ?? 0,
  };

  const hotspot = classifyHotspot(run);
  run.hotspot = hotspot;
  run.analysis = diagnose(hotspot);
  run.goalGapPct = 50 - speedupPct;

  if (write) {
    mkdirSync(REPORT_DIR, { recursive: true });
    appendFileSync(reportPaths.liveJsonl, `${JSON.stringify(run)}\n`, "utf8");
    writeFileSync(reportPaths.latestJson, JSON.stringify(run, null, 2), "utf8");
  }

  return run;
}
