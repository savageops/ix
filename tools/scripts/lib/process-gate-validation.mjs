function isPlainObject(value) {
  return value !== null && typeof value === "object" && !Array.isArray(value);
}

function compactCommandResult(result, { stdoutLimit = 4096, stderrLimit = 4096 } = {}) {
  if (!result) return null;
  const compact = { ...result };
  if (typeof compact.stdout === "string" && compact.stdout.length > stdoutLimit) {
    compact.stdout = `${compact.stdout.slice(0, stdoutLimit)}...<truncated ${compact.stdout.length - stdoutLimit} bytes>`;
  }
  if (typeof compact.stderr === "string" && compact.stderr.length > stderrLimit) {
    compact.stderr = `${compact.stderr.slice(0, stderrLimit)}...<truncated ${compact.stderr.length - stderrLimit} bytes>`;
  }
  return compact;
}

function summarizeProcessStatusReport(report) {
  if (!isPlainObject(report)) return null;
  return {
    cmd: report.cmd ?? null,
    state_dir: report.state_dir ?? null,
    live: Number(report.live ?? 0),
    stale: Number(report.stale ?? 0),
    malformed: Number(report.malformed ?? 0),
    warnings: Number(report.warnings ?? 0),
    removed: Number(report.removed ?? 0),
    entries_sample: Array.isArray(report.entries)
      ? report.entries.slice(0, 8).map((entry) => ({
          kind: entry?.kind ?? null,
          status: entry?.status ?? null,
          command: entry?.command ?? null,
          root: entry?.root ?? null,
          pid: entry?.pid ?? null,
          memory_bytes: entry?.memory_bytes ?? null,
          memory_limit_bytes: entry?.memory_limit_bytes ?? null,
          warning: entry?.warning ?? null,
          cleanup_action: entry?.cleanup_action ?? null,
          marker_path: entry?.marker_path ?? null,
        }))
      : [],
  };
}

export function createProcessGateValidation({ run, lane, findBuiltIx }) {
  function processNameProbe() {
    return run("powershell", [
      "-NoProfile",
      "-Command",
      "Get-CimInstance Win32_Process | Where-Object { $_.ProcessId -ne $PID -and $_.Name -match '^(ix|iex|ix-zig|__ix_indexd|__ix_nexus)(\\.exe)?$' -and -not ($_.CommandLine -match '\\sprocess\\s+status\\s+--json') } | Select-Object ProcessId,Name,CommandLine,WorkingSetSize | ConvertTo-Json -Compress",
    ]);
  }

  function scanIxProcesses() {
    const ix = findBuiltIx();
    const status = ix
      ? run(ix, ["process", "status", "--json"], {
          env: {
            IX_INDEXD_MEMORY_LIMIT_MB: "4096",
          },
        })
      : null;
    let processReport = null;
    let statusFailures = [];
    if (status) {
      if (status.exitCode !== 0) {
        statusFailures.push(`process status exited ${status.exitCode}`);
      } else {
        try {
          processReport = summarizeProcessStatusReport(JSON.parse(status.stdout || "{}"));
          if (Number(processReport.stale ?? 0) > 0) statusFailures.push(`stale markers: ${processReport.stale}`);
          if (Number(processReport.malformed ?? 0) > 0) statusFailures.push(`malformed markers: ${processReport.malformed}`);
          if (Number(processReport.warnings ?? 0) > 0) statusFailures.push(`memory warnings: ${processReport.warnings}`);
        } catch {
          statusFailures.push("process status did not emit valid JSON");
        }
      }
    }

    if (process.platform !== "win32") {
      return lane(statusFailures.length === 0 ? "process_scan" : "process_scan", statusFailures.length === 0 ? "ok" : "failed", {
        reason: ix ? undefined : "process status scan requires built ix binary; process-name scan is currently Windows only",
        processStatus: compactCommandResult(status),
        processReport,
        failures: statusFailures,
      });
    }

    let probe = processNameProbe();
    if (probe.exitCode !== 0) return lane("process_scan", "failed", { evidence: compactCommandResult(probe), processStatus: compactCommandResult(status), processReport, failures: [...statusFailures, "process-name probe failed"] });
    let text = probe.stdout.trim();
    let transientRescans = 0;
    while (text.length > 0 && transientRescans < 5) {
      run("powershell", ["-NoProfile", "-Command", "Start-Sleep -Milliseconds 500"]);
      const retry = processNameProbe();
      if (retry.exitCode !== 0) break;
      probe = retry;
      text = probe.stdout.trim();
      transientRescans += 1;
    }
    const failures = [...statusFailures];
    if (text.length > 0) failures.push("live IX-named processes matched process-name probe");
    return lane("process_scan", failures.length === 0 ? "ok" : "failed", {
      evidence: compactCommandResult(probe),
      processStatus: compactCommandResult(status),
      processReport,
      failures,
      matched: text || "[]",
      transientRescans,
    });
  }

  return {
    scanIxProcesses,
  };
}
