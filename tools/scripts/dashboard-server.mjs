import { createReadStream, existsSync, readFileSync, readdirSync, statSync } from "node:fs";
import { createServer } from "node:http";
import os from "node:os";
import path from "node:path";
import { loadHistory, latest } from "./lib/history.mjs";
import { summarizeHistory } from "./lib/summary.mjs";

const ROOT = process.cwd();
const DASHBOARD_HTML = path.join(ROOT, "dashboard", "index.html");
const REPORT_JSONL = path.join(ROOT, "tools", "reports", "live-metrics.jsonl");
const SELF_BASELINE_JSON = path.join(ROOT, "tools", "reports", "self-improvement-baseline.json");
const BENCH_REPORT_DIR = path.join(ROOT, "tools", "reports", "bench");
const PORT = Number(process.env.IX_DASHBOARD_PORT ?? 7373);
const HOST = process.env.IX_DASHBOARD_HOST ?? "0.0.0.0";
const MAX_PORT_ATTEMPTS = 15;

const clients = new Set();
let lastSize = 0;
let historyCache = [];

function sendEvent(client, event, data) {
  client.write(`event: ${event}\n`);
  client.write(`data: ${JSON.stringify(data)}\n\n`);
}

function broadcast(event, data) {
  for (const client of clients) {
    sendEvent(client, event, data);
  }
}

function relativeRepoPath(targetPath) {
  return path.relative(ROOT, targetPath).replaceAll("\\", "/");
}

function fileSnapshot(targetPath) {
  if (!existsSync(targetPath)) {
    return {
      available: false,
      artifactPath: relativeRepoPath(targetPath),
      updatedAt: null,
    };
  }

  return {
    available: true,
    artifactPath: relativeRepoPath(targetPath),
    updatedAt: new Date(statSync(targetPath).mtimeMs).toISOString(),
  };
}

function latestBenchsuiteRawArtifact() {
  if (!existsSync(BENCH_REPORT_DIR)) {
    return null;
  }

  const candidates = readdirSync(BENCH_REPORT_DIR, { withFileTypes: true })
    .filter((entry) => entry.isFile() && /^ripgrep-benchsuite-.*\.csv$/i.test(entry.name))
    .map((entry) => path.join(BENCH_REPORT_DIR, entry.name));

  if (candidates.length === 0) {
    return null;
  }

  return candidates.sort((left, right) => statSync(right).mtimeMs - statSync(left).mtimeMs)[0];
}

function sourcePayload() {
  const liveDiagnostics = fileSnapshot(REPORT_JSONL);
  const latestBenchsuite = latestBenchsuiteRawArtifact();

  return {
    liveDiagnostics: {
      label: "Live diagnostics summary",
      command: "npm run bench:loop",
      summaryKind: "live-metrics-jsonl",
      ...liveDiagnostics,
    },
    benchsuiteRaw: latestBenchsuite
      ? {
          label: "Latest ripgrep benchsuite raw artifact",
          command: "npm run bench:report",
          summaryKind: "raw-csv-artifact",
          ...fileSnapshot(latestBenchsuite),
        }
      : {
          label: "Latest ripgrep benchsuite raw artifact",
          command: "npm run bench:report",
          summaryKind: "raw-csv-artifact",
          available: false,
          artifactPath: null,
          updatedAt: null,
        },
  };
}

function summaryPayload() {
  let baselineSnapshot = null;
  if (existsSync(SELF_BASELINE_JSON)) {
    try {
      baselineSnapshot = JSON.parse(readFileSync(SELF_BASELINE_JSON, "utf8"));
    } catch {
      baselineSnapshot = null;
    }
  }
  return {
    latest: latest(historyCache),
    summary: summarizeHistory(historyCache, { baselineSnapshot }),
    sources: sourcePayload(),
  };
}

function bootstrapPayload() {
  return {
    history: historyCache,
    ...summaryPayload(),
  };
}

function refreshHistoryCache() {
  historyCache = loadHistory(REPORT_JSONL);
  if (!existsSync(REPORT_JSONL)) {
    lastSize = 0;
    return;
  }
  lastSize = statSync(REPORT_JSONL).size;
}

function checkForUpdates() {
  if (!existsSync(REPORT_JSONL)) {
    if (historyCache.length > 0 || lastSize !== 0) {
      refreshHistoryCache();
      broadcast("summary", summaryPayload());
    }
    return;
  }

  const stat = statSync(REPORT_JSONL);
  if (stat.size === lastSize) {
    return;
  }

  if (stat.size < lastSize) {
    refreshHistoryCache();
    broadcast("summary", summaryPayload());
    return;
  }

  const stream = createReadStream(REPORT_JSONL, {
    encoding: "utf8",
    start: lastSize,
    end: stat.size,
  });

  let chunk = "";
  stream.on("data", (data) => {
    chunk += data;
  });
  stream.on("end", () => {
    const appendedRuns = [];
    const lines = chunk
      .split(/\r?\n/)
      .map((line) => line.trim())
      .filter(Boolean);
    for (const line of lines) {
      try {
        const run = JSON.parse(line);
        historyCache.push(run);
        appendedRuns.push(run);
      } catch {
        // ignore malformed lines during live append
      }
    }
    for (const run of appendedRuns) {
      broadcast("run", run);
    }
    if (appendedRuns.length > 0) {
      broadcast("summary", summaryPayload());
    }
    lastSize = stat.size;
  });
}

function getWslIpv4Address() {
  if (!process.env.WSL_DISTRO_NAME) {
    return null;
  }

  const networkInterfaces = os.networkInterfaces();
  for (const addresses of Object.values(networkInterfaces)) {
    if (!addresses) {
      continue;
    }
    const match = addresses.find(
      (address) => address.family === "IPv4" && !address.internal,
    );
    if (match?.address) {
      return match.address;
    }
  }
  return null;
}

refreshHistoryCache();

function setNoStoreHeaders(res) {
  res.setHeader("cache-control", "no-store, no-cache, must-revalidate, proxy-revalidate");
  res.setHeader("pragma", "no-cache");
  res.setHeader("expires", "0");
}

const server = createServer((req, res) => {
  if (!req.url) {
    res.statusCode = 404;
    res.end();
    return;
  }

  if (req.url === "/") {
    setNoStoreHeaders(res);
    res.setHeader("content-type", "text/html; charset=utf-8");
    res.end(readFileSync(DASHBOARD_HTML, "utf8"));
    return;
  }

  if (req.url === "/api/history") {
    setNoStoreHeaders(res);
    res.setHeader("content-type", "application/json; charset=utf-8");
    res.end(JSON.stringify({ history: historyCache, latest: latest(historyCache) }));
    return;
  }

  if (req.url === "/api/summary") {
    setNoStoreHeaders(res);
    res.setHeader("content-type", "application/json; charset=utf-8");
    res.end(JSON.stringify(summaryPayload()));
    return;
  }

  if (req.url === "/events") {
    res.writeHead(200, {
      "content-type": "text/event-stream",
      "cache-control": "no-store, no-cache, must-revalidate, proxy-revalidate",
      pragma: "no-cache",
      expires: "0",
      connection: "keep-alive",
    });
    clients.add(res);
    sendEvent(res, "bootstrap", bootstrapPayload());

    req.on("close", () => {
      clients.delete(res);
    });
    return;
  }

  res.statusCode = 404;
  res.end("not found");
});

setInterval(checkForUpdates, 1000);

let listenPort = PORT;
let attempts = 0;

server.on("error", (error) => {
  if (error?.code === "EADDRINUSE" && attempts < MAX_PORT_ATTEMPTS) {
    attempts += 1;
    listenPort += 1;
    console.warn(
      `dashboard port ${listenPort - 1} in use, retrying on ${listenPort}`,
    );
    server.listen(listenPort, HOST);
    return;
  }
  throw error;
});

server.on("listening", () => {
  if (HOST === "0.0.0.0") {
    console.log(`IX-Zig dashboard live at http://0.0.0.0:${listenPort}`);
    console.log(`IX-Zig dashboard local loopback at http://127.0.0.1:${listenPort}`);
    const wslIpv4 = getWslIpv4Address();
    if (wslIpv4) {
      console.log(
        `IX-Zig dashboard Windows URL (WSL network) http://${wslIpv4}:${listenPort}`,
      );
    }
    return;
  }

  console.log(`IX-Zig dashboard live at http://${HOST}:${listenPort}`);
});

server.listen(listenPort, HOST);
