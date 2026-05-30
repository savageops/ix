import { spawnSync } from "node:child_process";
import { existsSync, mkdirSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import os from "node:os";
import path from "node:path";
import { argValue, timestampSlug } from "./lib/script-helpers.mjs";

const ROOT = process.cwd();
const REPORT_DIR = path.join(ROOT, "tools", "reports", "agent-eval");

const args = process.argv.slice(2);
const dryRun = args.includes("--dry-run");
const codexExe = argValue(args, "--codex", process.env.IX_CODEX_EXE ?? "codex");
const outPath = argValue(args, "--out", path.join(REPORT_DIR, `agent-eval-${timestampSlug()}.json`));
const timeoutMs = Number(argValue(args, "--timeout-ms", process.env.IX_AGENT_EVAL_TIMEOUT_MS ?? "180000"));
const model = argValue(args, "--model", process.env.IX_CODEX_AGENT_MODEL ?? process.env.CODEX_MODEL);

const scenario = [
  {
    id: "seed_project_memory",
    content:
      "For this evaluation session only, retain these IX seed facts in conversation context: orchard=delta-overlay, harbor=block-max-pruning, quartz=agent-recall. Do not write files, memory notes, or run shell commands.",
  },
  {
    id: "force_ix_tool_context",
    content:
      "Use IX concepts to explain why search, matches, and inspect should share one canonical query/search owner path. Keep the seed facts in this conversation only. Do not write files, memory notes, or run shell commands.",
  },
  {
    id: "compaction_pressure",
    content:
      "Now summarize the current task state as if a long-running agent context compaction happened. Preserve exact seed facts and the validation objective. Do not write files, memory notes, or run shell commands.",
  },
  {
    id: "recall_probe",
    content:
      "Recall the three seed key/value facts and connect each to the IX architecture validation spine. Do not write files, memory notes, or run shell commands.",
  },
];

function writeReport(report) {
  mkdirSync(path.dirname(outPath), { recursive: true });
  writeFileSync(outPath, `${JSON.stringify(report, null, 2)}\n`);
}

function result(status, extra = {}) {
  return {
    status,
    mode: dryRun ? "dry-run" : "codex-exec",
    codexExe,
    scenarioTurns: scenario.length,
    timeoutMs,
    ...extra,
  };
}

function commandPreview(commandArgs) {
  return [codexExe, ...commandArgs].join(" ");
}

function runCodex(commandArgs) {
  const started = process.hrtime.bigint();
  const response = spawnSync(codexExe, commandArgs, {
    cwd: ROOT,
    encoding: "utf8",
    maxBuffer: 64 * 1024 * 1024,
    timeout: timeoutMs,
    windowsHide: true,
  });
  const durationMs = Number(process.hrtime.bigint() - started) / 1_000_000;
  return {
    command: commandPreview(commandArgs),
    exitCode: response.status,
    signal: response.signal,
    error: response.error ? String(response.error.message ?? response.error) : null,
    durationMs,
    stdout: response.stdout ?? "",
    stderr: response.stderr ?? "",
  };
}

function tail(text, max = 4000) {
  if (!text || text.length <= max) return text ?? "";
  return text.slice(text.length - max);
}

function codexAvailable() {
  const check = runCodex(["--version"]);
  return {
    ok: check.exitCode === 0,
    evidence: {
      command: check.command,
      exitCode: check.exitCode,
      signal: check.signal,
      error: check.error,
      durationMs: check.durationMs,
      stdout: tail(check.stdout, 400),
      stderr: tail(check.stderr, 400),
    },
  };
}

function outputPath(turnId) {
  return path.join(os.tmpdir(), `ix-agent-eval-${process.pid}-${turnId}.txt`);
}

function readOutput(file) {
  if (!existsSync(file)) return "";
  return readFileSync(file, "utf8").trim();
}

function extractSessionId(stdout) {
  const headerMatch = stdout.match(/session id:\s*([0-9a-fA-F-]{36})/);
  if (headerMatch) return headerMatch[1];
  for (const line of stdout.split(/\r?\n/)) {
    if (!line.trim().startsWith("{")) continue;
    try {
      const event = JSON.parse(line);
      if (event?.type === "thread.started" && typeof event.thread_id === "string") return event.thread_id;
    } catch {
      // Ignore non-event lines mixed into Codex JSONL output.
    }
  }
  return null;
}

function runTurn(turn, index, sessionId) {
  const messagePath = outputPath(turn.id);
  rmSync(messagePath, { force: true });
  const commandArgs =
    index === 0
      ? [
          "exec",
          "--json",
          "--cd",
          ROOT,
          "--sandbox",
          "read-only",
          "--output-last-message",
          messagePath,
          ...(model ? ["--model", model] : []),
          turn.content,
        ]
      : [
          "exec",
          "resume",
          "--json",
          "--output-last-message",
          messagePath,
          ...(model ? ["--model", model] : []),
          sessionId,
          turn.content,
        ];
  const result = runCodex(commandArgs);
  const assistantText = readOutput(messagePath);
  rmSync(messagePath, { force: true });
  return {
    turn: turn.id,
    exitCode: result.exitCode,
    signal: result.signal,
    error: result.error,
    durationMs: result.durationMs,
    sessionId: index === 0 ? extractSessionId(result.stdout) : sessionId,
    assistantText,
    stdoutTail: tail(result.stdout),
    stderrTail: tail(result.stderr),
  };
}

function scoreRecall(text) {
  const required = ["orchard", "delta-overlay", "harbor", "block-max-pruning", "quartz", "agent-recall"];
  const lower = text.toLowerCase();
  const found = required.filter((token) => lower.includes(token));
  return {
    found,
    required,
    passed: found.length === required.length,
  };
}

const availability = codexAvailable();

if (dryRun) {
  const report = result(availability.ok ? "ok" : "missing_codex", {
    codexAvailable: availability.ok,
    evidence: availability.evidence,
    scenario,
    reportPath: outPath,
    acceptedEnv: ["IX_CODEX_EXE", "IX_CODEX_AGENT_MODEL", "CODEX_MODEL", "IX_AGENT_EVAL_TIMEOUT_MS"],
  });
  writeReport(report);
  console.log(JSON.stringify(report, null, 2));
  process.exit(availability.ok ? 0 : 1);
}

if (!availability.ok) {
  const report = result("missing_codex", {
    codexAvailable: false,
    evidence: availability.evidence,
    message: "Codex CLI is required for real agent evaluation; set IX_CODEX_EXE if codex is not on PATH.",
    reportPath: outPath,
  });
  writeReport(report);
  console.log(JSON.stringify(report, null, 2));
  process.exit(1);
}

let sessionId = null;
const transcript = [];
for (let index = 0; index < scenario.length; index += 1) {
  const turn = runTurn(scenario[index], index, sessionId);
  transcript.push(turn);
  if (turn.exitCode !== 0 || turn.signal || turn.error) {
    const report = result("codex_failed", {
      failedTurn: turn.turn,
      sessionId,
      transcript,
      reportPath: outPath,
    });
    writeReport(report);
    console.log(JSON.stringify(report, null, 2));
    process.exit(1);
  }
  sessionId = turn.sessionId ?? sessionId;
  if (!sessionId) {
    const report = result("session_id_missing", {
      failedTurn: turn.turn,
      transcript,
      reportPath: outPath,
    });
    writeReport(report);
    console.log(JSON.stringify(report, null, 2));
    process.exit(1);
  }
}

const finalText = transcript.at(-1)?.assistantText ?? "";
const recall = scoreRecall(finalText);
const report = result(recall.passed ? "ok" : "recall_failed", {
  sessionId,
  recall,
  transcript,
  reportPath: outPath,
});
writeReport(report);
console.log(JSON.stringify(report, null, 2));
process.exit(recall.passed ? 0 : 1);
