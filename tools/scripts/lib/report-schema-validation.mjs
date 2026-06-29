function isPlainObject(value) {
  return value !== null && typeof value === "object" && !Array.isArray(value);
}

function validateCommandEvidence(pathLabel, evidence, failures) {
  if (!isPlainObject(evidence)) {
    failures.push(`${pathLabel}: evidence must be an object`);
    return;
  }
  if (Object.hasOwn(evidence, "command") && typeof evidence.command !== "string") {
    failures.push(`${pathLabel}.command: must be a string`);
  }
  if (Object.hasOwn(evidence, "exitCode") && typeof evidence.exitCode !== "number") {
    failures.push(`${pathLabel}.exitCode: must be a number`);
  }
  if (Object.hasOwn(evidence, "durationMs") && typeof evidence.durationMs !== "number") {
    failures.push(`${pathLabel}.durationMs: must be a number`);
  }
  for (const key of ["stdout", "stderr"]) {
    if (Object.hasOwn(evidence, key) && typeof evidence[key] !== "string") {
      failures.push(`${pathLabel}.${key}: must be a string`);
    }
  }
}

function validateNestedEvidence(pathLabel, value, failures) {
  if (!isPlainObject(value)) return;
  if (Object.hasOwn(value, "command") || Object.hasOwn(value, "exitCode") || Object.hasOwn(value, "durationMs")) {
    validateCommandEvidence(pathLabel, value, failures);
  }
  for (const [key, nested] of Object.entries(value)) {
    if (isPlainObject(nested)) validateNestedEvidence(`${pathLabel}.${key}`, nested, failures);
  }
}

export function createReportSchemaValidation({
  validateAlternatesDecisionLane,
  validateBenchmarkHostPreflightLane,
  validateBenchmarkLockLane,
  validateBenchmarkReadinessLane,
  validateHistoricalSpeedLane,
  validateInstalledSpeedLane,
  validateOlderSnapshotLane,
  validateNativeInstallIdentityLane,
  validateRipgrepLane,
}) {
  function validateReport(report) {
    const failures = [];
    const expectedLaneIds = new Set([
      "worktree",
      "planning_chain",
      "diff_check",
      "benchmark_host_preflight",
      "benchmark_lock",
      "benchmark_readiness",
      "benchmark_control",
      "ripgrep_12_sample",
      "native_install_identity",
      "installed_speed_compare",
      "historical_speed_compare",
      "older_snapshot_ladder",
      "teddy_kernel_decision",
      "teddy_kernel_contract",
      "alternates_decision",
      "agent_real_dry_run",
      "agent_real",
      "zig_test",
      "cold_smoke",
      "surface_parity",
      "agent_path_contract",
      "warm_cold_parity",
      "warm_index_live",
      "generation_recovery",
      "default_state_location",
      "runtime_state_location",
      "indexd_memory_cap",
      "process_scan",
      "report_schema",
    ]);
    const legalStatuses = new Set(["ok", "failed", "skipped"]);

    if (!isPlainObject(report)) failures.push("report: must be an object");
    if (!["ok", "failed"].includes(report.status)) failures.push("report.status: must be ok or failed");
    if (!["quick", "full", "speed-only"].includes(report.mode)) failures.push("report.mode: must be quick, full, or speed-only");
    if (typeof report.stateDir !== "string" || report.stateDir.length === 0) failures.push("report.stateDir: must be a non-empty string");
    if (typeof report.reportPath !== "string" || report.reportPath.length === 0) failures.push("report.reportPath: must be a non-empty string");
    if (!Array.isArray(report.lanes)) {
      failures.push("report.lanes: must be an array");
      return failures;
    }

    const seen = new Set();
    for (const [index, entry] of report.lanes.entries()) {
      const label = `report.lanes[${index}]`;
      if (!isPlainObject(entry)) {
        failures.push(`${label}: must be an object`);
        continue;
      }
      if (typeof entry.id !== "string" || entry.id.length === 0) {
        failures.push(`${label}.id: must be a non-empty string`);
        continue;
      }
      if (!expectedLaneIds.has(entry.id)) failures.push(`${entry.id}: unexpected lane id`);
      if (seen.has(entry.id)) failures.push(`${entry.id}: duplicate lane id`);
      seen.add(entry.id);

      if (!legalStatuses.has(entry.status)) failures.push(`${entry.id}.status: must be ok, failed, or skipped`);
      if (typeof entry.passed !== "boolean") failures.push(`${entry.id}.passed: must be a boolean`);
      if (entry.passed !== (entry.status === "ok")) {
        failures.push(`${entry.id}.passed: must agree with ok status`);
      }
      if (!Array.isArray(entry.failures) || entry.failures.some((failure) => typeof failure !== "string")) {
        failures.push(`${entry.id}.failures: must be an array of strings`);
      }
      if (!Object.hasOwn(entry, "evidence") || !isPlainObject(entry.evidence)) {
        failures.push(`${entry.id}.evidence: must be an object`);
      }
      if (entry.status === "skipped" && typeof entry.reason !== "string") {
        failures.push(`${entry.id}.reason: skipped lanes must explain the skip`);
      }
      if (
        entry.status === "failed" &&
        entry.failures.length === 0 &&
        !Object.hasOwn(entry, "reason") &&
        !Object.hasOwn(entry, "evidence") &&
        !Object.hasOwn(entry, "primary") &&
        !Object.hasOwn(entry, "confirm")
      ) {
        failures.push(`${entry.id}: failed lanes must expose evidence, failures, reason, or benchmark windows`);
      }
      if (Object.hasOwn(entry, "evidence")) validateNestedEvidence(`${entry.id}.evidence`, entry.evidence, failures);
      for (const key of ["primary", "confirm", "tiebreaker"]) {
        if (Object.hasOwn(entry, key)) validateNestedEvidence(`${entry.id}.${key}`, entry[key], failures);
      }
      if (entry.id === "benchmark_control" && entry.status === "ok" && entry.metrics?.hostClean === false) {
        failures.push("benchmark_control: ok status cannot rely on a warning-class host benchmark envelope");
      }
      if (entry.id === "benchmark_control" && entry.status === "failed" && isPlainObject(entry.metrics)) {
        const summary = entry.metrics.failureSummary;
        if (!isPlainObject(summary) || !Array.isArray(summary.failedChecks) || summary.failedChecks.length === 0) {
          failures.push("benchmark_control: failed status with metrics requires structured failure summary");
        }
        if (isPlainObject(summary) && !isPlainObject(summary.thresholds)) {
          failures.push("benchmark_control: failure summary requires threshold evidence");
        }
        if (isPlainObject(summary) && !isPlainObject(summary.observed)) {
          failures.push("benchmark_control: failure summary requires observed metric evidence");
        }
      }
      validateBenchmarkHostPreflightLane(entry, failures);
      validateBenchmarkLockLane(entry, failures);
      validateBenchmarkReadinessLane(entry, failures);
      validateRipgrepLane(entry, failures);
      validateNativeInstallIdentityLane(entry, failures);
      validateInstalledSpeedLane(entry, failures);
      validateHistoricalSpeedLane(entry, failures);
      validateOlderSnapshotLane(entry, failures);
      validateAlternatesDecisionLane(entry, failures);
    }

    const teddyDecisionIndex = report.lanes.findIndex((entry) => entry?.id === "teddy_kernel_decision");
    const nativeInstallIndex = report.lanes.findIndex((entry) => entry?.id === "native_install_identity");
    if (teddyDecisionIndex >= 0 && nativeInstallIndex >= 0 && teddyDecisionIndex > nativeInstallIndex) {
      failures.push("native_install_identity: teddy kernel decision lane must run first");
    }

    for (const id of [...expectedLaneIds].filter((expected) => expected !== "report_schema")) {
      if (!seen.has(id)) failures.push(`${id}: expected lane missing`);
    }

    return failures;
  }

  return { validateReport };
}
