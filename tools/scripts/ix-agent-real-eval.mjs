import { spawnSync } from "node:child_process";
import { existsSync, mkdirSync, writeFileSync } from "node:fs";
import path from "node:path";
import { argValue, timestampSlug } from "./lib/script-helpers.mjs";

const ROOT = process.cwd();
const REPORT_DIR = path.join(ROOT, "tools", "reports", "agent-eval");

const args = process.argv.slice(2);
const dryRun = args.includes("--dry-run");
const openAiBaseUrl = process.env.OPENAI_BASE_URL?.replace(/\/+$/, "");
const endpoint = argValue(
  args,
  "--endpoint",
  process.env.IX_AGENT_EVAL_ENDPOINT ?? (openAiBaseUrl ? `${openAiBaseUrl}/chat/completions` : undefined),
);
const configuredModel = argValue(args, "--model", process.env.IX_AGENT_EVAL_MODEL ?? process.env.OPENAI_MODEL);
const authHeader = argValue(
  args,
  "--auth-header",
  process.env.IX_AGENT_EVAL_AUTH_HEADER ?? (process.env.OPENAI_API_KEY ? `Authorization: Bearer ${process.env.OPENAI_API_KEY}` : undefined),
);
const curlPath = argValue(args, "--curl", process.env.CURL_EXE ?? "curl");
const outPath = argValue(args, "--out", path.join(REPORT_DIR, `agent-eval-${timestampSlug()}.json`));

const scenario = [
  {
    id: "seed_project_memory",
    role: "user",
    content:
      "Remember this IX eval seed: orchard=delta-overlay, harbor=block-max-pruning, quartz=agent-recall. You will need these later after tool-use work.",
  },
  {
    id: "force_ix_tool_context",
    role: "user",
    content:
      "Use IX concepts to explain why search, matches, and inspect should share one canonical query/search owner path. Keep the seed facts in memory.",
  },
  {
    id: "compaction_pressure",
    role: "user",
    content:
      "Now summarize the current task state as if a long-running agent context compaction happened. Preserve exact seed facts and the validation objective.",
  },
  {
    id: "recall_probe",
    role: "user",
    content:
      "Recall the three seed key/value facts and connect each to the IX architecture validation spine.",
  },
];

function result(status, extra = {}) {
  return {
    status,
    mode: dryRun ? "dry-run" : "real",
    endpointConfigured: Boolean(endpoint),
    modelConfigured: Boolean(configuredModel),
    authConfigured: Boolean(authHeader),
    scenarioTurns: scenario.length,
    ...extra,
  };
}

function writeReport(report) {
  mkdirSync(path.dirname(outPath), { recursive: true });
  writeFileSync(outPath, `${JSON.stringify(report, null, 2)}\n`);
}

function authCurlArgs() {
  return authHeader ? ["-H", authHeader] : [];
}

function discoverModel() {
  if (configuredModel) return configuredModel;
  if (!openAiBaseUrl) return undefined;
  const response = spawnSync(curlPath, ["-sS", `${openAiBaseUrl}/models`, ...authCurlArgs()], {
    cwd: ROOT,
    encoding: "utf8",
    maxBuffer: 8 * 1024 * 1024,
    windowsHide: true,
  });
  if (response.status !== 0) return undefined;
  try {
    const parsed = JSON.parse(response.stdout ?? "{}");
    return parsed.data?.find((entry) => typeof entry?.id === "string")?.id;
  } catch {
    return undefined;
  }
}

function buildPayload(turns, model) {
  return JSON.stringify({
    model,
    messages: turns.map(({ role, content }) => ({ role, content })),
    temperature: 0,
  });
}

function runCurl(turns, model) {
  const curlArgs = [
    "-sS",
    "-X",
    "POST",
    endpoint,
    "-H",
    "Content-Type: application/json",
    ...authCurlArgs(),
    "--data-binary",
    buildPayload(turns, model),
  ];
  return spawnSync(curlPath, curlArgs, {
    cwd: ROOT,
    encoding: "utf8",
    maxBuffer: 32 * 1024 * 1024,
    windowsHide: true,
  });
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

if (dryRun) {
  const report = result("ok", {
    scenario,
    reportPath: outPath,
    acceptedEnv: [
      "IX_AGENT_EVAL_ENDPOINT",
      "IX_AGENT_EVAL_MODEL",
      "IX_AGENT_EVAL_AUTH_HEADER",
      "OPENAI_BASE_URL",
      "OPENAI_MODEL",
      "OPENAI_API_KEY",
    ],
  });
  writeReport(report);
  console.log(JSON.stringify(report, null, 2));
  process.exit(0);
}

const model = discoverModel();

if (!endpoint || !model) {
  const report = result("missing_config", {
    message:
      "Set IX_AGENT_EVAL_ENDPOINT and IX_AGENT_EVAL_MODEL, or provide OPENAI_BASE_URL plus OPENAI_MODEL or a reachable /models endpoint.",
    reportPath: outPath,
  });
  writeReport(report);
  console.log(JSON.stringify(report, null, 2));
  process.exit(0);
}

if (curlPath !== "curl" && !existsSync(curlPath)) {
  const report = result("missing_curl", {
    message: `Configured curl executable was not found: ${curlPath}`,
    reportPath: outPath,
  });
  writeReport(report);
  console.log(JSON.stringify(report, null, 2));
  process.exit(0);
}

const transcript = [];
for (let index = 0; index < scenario.length; index += 1) {
  const turns = scenario.slice(0, index + 1);
  const response = runCurl(turns, model);
  const stdout = response.stdout ?? "";
  const stderr = response.stderr ?? "";
  transcript.push({
    turn: scenario[index].id,
    exitCode: response.status,
    stdout,
    stderr,
  });
  if (response.status !== 0) {
    const report = result("curl_failed", {
      failedTurn: scenario[index].id,
      transcript,
      reportPath: outPath,
    });
    writeReport(report);
    console.log(JSON.stringify(report, null, 2));
    process.exit(1);
  }
}

const finalText = transcript.at(-1)?.stdout ?? "";
const recall = scoreRecall(finalText);
const report = result(recall.passed ? "ok" : "recall_failed", {
  recall,
  transcript,
  reportPath: outPath,
});
writeReport(report);
console.log(JSON.stringify(report, null, 2));
process.exit(recall.passed ? 0 : 1);
