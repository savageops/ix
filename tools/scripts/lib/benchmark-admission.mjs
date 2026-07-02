import { existsSync, mkdirSync, rmSync, writeFileSync } from "node:fs";
import os from "node:os";
import path from "node:path";
import { acquireBenchmarkLock } from "./speed-compare-utils.mjs";

function isPlainObject(value) {
  return value !== null && typeof value === "object" && !Array.isArray(value);
}

function psSingleQuote(value) {
  return `'${String(value).replaceAll("'", "''")}'`;
}

function shellArg(value) {
  const text = String(value);
  return /\s/.test(text) ? `"${text.replaceAll('"', '\\"')}"` : text;
}

export function remediationEntries(remediation) {
  return [
    ...(Array.isArray(remediation?.actions) ? remediation.actions : []),
    ...(Array.isArray(remediation?.verificationCommands) ? remediation.verificationCommands : []),
  ];
}

function hasDefenderRemediation(remediation) {
  return remediationEntries(remediation).some((entry) =>
    entry?.issueId === "defender_active_in_top_working_set" ||
    entry?.issueId === "defender_active_cpu_sample"
  );
}

export function createBenchmarkAdmission({
  root,
  benchmarkCorpus,
  nativeInstallDir,
  stateDir,
  minRetainableSpeedSamples,
}) {
  function hostBenchmarkIssues(host) {
    const before = Array.isArray(host?.before?.benchmarkEnvironment?.issues) ? host.before.benchmarkEnvironment.issues : [];
    const after = Array.isArray(host?.after?.benchmarkEnvironment?.issues) ? host.after.benchmarkEnvironment.issues : [];
    const seen = new Set();
    const issues = [];
    for (const issue of [...before, ...after]) {
      if (!isPlainObject(issue) || typeof issue.id !== "string") continue;
      const key = `${issue.id}:${issue.detail ?? ""}`;
      if (seen.has(key)) continue;
      seen.add(key);
      issues.push(issue);
    }
    return issues;
  }

  function hostBenchmarkClean(issues) {
    return Array.isArray(issues) && issues.every((issue) => issue?.severity !== "warning");
  }

  function hasStableDefenderRemediationPaths(remediation) {
    if (!isPlainObject(remediation) || !Array.isArray(remediation.paths)) return false;
    const normalized = remediation.paths.filter((entry) => typeof entry === "string").map((entry) => path.resolve(entry));
    const required = [
      benchmarkCorpus,
      path.join(root, "zig-out"),
      path.join(root, "tools", "reports"),
      nativeInstallDir,
    ].map((entry) => path.resolve(entry));
    if (required.some((entry) => !normalized.includes(entry))) return false;
    return !normalized.some((entry) => /^architecture-gate-\d{4}-\d{2}-\d{2}T/.test(path.basename(entry)));
  }

  function benchmarkHostRemediation(issues, context = {}) {
    const corpus = context.corpus ?? benchmarkCorpus;
    const stableStateRoot = path.dirname(context.stateDir ?? stateDir);
    const paths = [...new Set([
      corpus,
      path.join(root, "zig-out"),
      path.join(root, "tools", "reports"),
      nativeInstallDir,
      stableStateRoot,
    ])];
    const actions = [];
    const verificationCommands = [];
    const seen = new Set();
    const seenVerification = new Set();
    const add = (issueId, action, command = null, reason = null, mutates = command !== null, requiresAdmin = false) => {
      if (seen.has(issueId)) return;
      seen.add(issueId);
      actions.push({ issueId, action, command, reason, mutates, requiresAdmin });
    };
    const addVerification = (issueId, command, reason, requiresAdmin = false) => {
      if (seenVerification.has(issueId)) return;
      seenVerification.add(issueId);
      verificationCommands.push({ issueId, command, reason, mutates: false, requiresAdmin });
    };
    for (const issue of issues ?? []) {
      if (issue?.severity !== "warning") continue;
      if (issue.id === "non_performance_power_plan") {
        addVerification(
          issue.id,
          "powercfg /getactivescheme",
          "Confirms the active Windows power plan before speed attribution.",
        );
        add(
          issue.id,
          "Switch Windows to a High performance or Ultimate Performance power plan before speed attribution.",
          "powercfg /setactive SCHEME_MIN",
          "Balanced power policy can change CPU frequency residency and make paired medians non-comparable.",
          true,
          true,
        );
      } else if (issue.id === "defender_active_in_top_working_set" || issue.id === "defender_active_cpu_sample") {
        addVerification(
          issue.id,
          "Get-MpPreference | Select-Object -ExpandProperty ExclusionPath",
          "Lists Defender exclusion paths without changing machine policy.",
          true,
        );
        add(
          issue.id,
          "Pause or exclude benchmark corpus, build, report, and temporary state paths from Defender while collecting retained speed evidence.",
          `Add-MpPreference -ExclusionPath ${paths.map(psSingleQuote).join(", ")}`,
          "Active Defender CPU during host preflight means filesystem and process sampling can be perturbed by scanning.",
          true,
          true,
        );
      } else if (issue.id === "low_available_memory") {
        add(
          issue.id,
          "Close memory-heavy workloads or reboot before benchmark collection.",
          null,
          "Low free memory increases paging and cache churn, invalidating small speed deltas.",
        );
      } else if (issue.id === "large_resident_workload") {
        add(
          issue.id,
          `Close or suspend ${issue.processName ?? "the memory-heavy workload"} before retained speed collection.`,
          null,
          `${issue.detail ?? "A large resident workload"} can perturb filesystem cache residency, paging pressure, and memory bandwidth.`,
        );
        addVerification(
          issue.id,
          "Get-Process | Sort-Object WorkingSet64 -Descending | Select-Object -First 8 Id,ProcessName,CPU,WorkingSet64",
          "Confirms no large resident foreground workload is competing with the benchmark.",
        );
      } else if (issue.id === "active_cpu_workload") {
        add(
          issue.id,
          `Stop or idle ${issue.processName ?? "the active CPU workload"} before retained speed collection.`,
          null,
          `${issue.detail ?? "An active CPU workload"} can distort paired medians and identity controls.`,
        );
        addVerification(
          issue.id,
          "Get-Process | Sort-Object CPU -Descending | Select-Object -First 8 Id,ProcessName,CPU,WorkingSet64",
          "Confirms no active foreground workload is consuming CPU during benchmark preflight.",
        );
      } else {
        add(
          issue.id ?? "unknown_warning",
          `Resolve benchmark host warning: ${issue.detail ?? issue.id ?? "unknown"}.`,
          null,
          "Warning-class host issues block retained speed attribution.",
        );
      }
    }
    return {
      blocked: actions.length > 0,
      actions,
      verificationCommands,
      paths,
      cleanHostRequiredFor: [
        "benchmark_control",
        "ripgrep_12_sample",
        "installed_speed_compare",
        "historical_speed_compare",
        "older_snapshot_ladder",
        "alternates_decision",
      ],
    };
  }

  function benchmarkReadinessNextCommands({ corpus = benchmarkCorpus } = {}) {
    const retainedSamples = Math.max(12, minRetainableSpeedSamples);
    const sampleArg = String(retainedSamples);
    const smokeSampleArg = "2";
    return [
      {
        id: "host_preflight_smoke",
        command: [
          "node",
          "tools/scripts/ix-architecture-regression-gate.mjs",
          "--speed-only",
          "--strict-installed-speed",
          "--strict-historical-speed",
          "--strict-older-snapshots",
          "--installed-speed-samples",
          smokeSampleArg,
          "--historical-speed-samples",
          smokeSampleArg,
          "--older-snapshot-samples",
          smokeSampleArg,
          "--older-snapshot-max",
          "1",
          "--older-snapshot-retainable-target",
          "1",
          "--older-snapshot-identity-attempts",
          "3",
          "--min-older-snapshot-engine-pct",
          "5",
          "--min-older-snapshot-paired-pct",
          "5",
          "--min-retainable-speed-samples",
          smokeSampleArg,
        ].join(" "),
        reason: "Confirms the host preflight is clean before spending full benchmark time.",
      },
      {
        id: "retained_installed_historical",
        command: [
          "node",
          "tools/scripts/ix-architecture-regression-gate.mjs",
          "--speed-only",
          "--strict-installed-speed",
          "--strict-historical-speed",
          "--strict-older-snapshots",
          "--installed-speed-samples",
          sampleArg,
          "--historical-speed-samples",
          sampleArg,
          "--older-snapshot-samples",
          sampleArg,
          "--older-snapshot-retainable-target",
          "2",
          "--older-snapshot-identity-attempts",
          "3",
          "--min-older-snapshot-engine-pct",
          "5",
          "--min-older-snapshot-paired-pct",
          "5",
          "--min-retainable-speed-samples",
          sampleArg,
        ].join(" "),
        reason: "Proves current repo IX against installed IX and older snapshots with retained sample depth.",
      },
      {
        id: "retained_alternates_route",
        command: [
          "node",
          "tools/scripts/ix-architecture-regression-gate.mjs",
          "--speed-only",
          "--alternates-decision",
          "--alternates-decision-samples",
          sampleArg,
          "--alternates-decision-branch-counts",
          "2,4,8",
          "--min-retainable-speed-samples",
          sampleArg,
        ].join(" "),
        reason: "Focuses alternates routing on branch counts that decide whether a hot-path change is worth retaining.",
      },
      {
        id: "direct_comparator_smoke",
        command: [
          "node",
          "tools/scripts/compare-installed-speed.mjs",
          "--corpus",
          shellArg(corpus),
          "--samples",
          smokeSampleArg,
          "--min-retainable-samples",
          smokeSampleArg,
          "--require-strict",
          "--require-promotion",
        ].join(" "),
        reason: "Runs the installed comparator directly when the gate wrapper needs isolated diagnosis.",
      },
    ];
  }

  function benchmarkPrivilegeSummary(hostPreflight, remediation) {
    const actions = Array.isArray(remediation?.actions) ? remediation.actions : [];
    const verificationCommands = Array.isArray(remediation?.verificationCommands) ? remediation.verificationCommands : [];
    const adminRequired = [...actions, ...verificationCommands].some((entry) => entry?.requiresAdmin === true);
    const beforeAdmin = hostPreflight?.metrics?.host?.before?.elevation?.isAdmin;
    const afterAdmin = hostPreflight?.metrics?.host?.after?.elevation?.isAdmin;
    let adminAvailable = null;
    if (beforeAdmin === true || afterAdmin === true) {
      adminAvailable = true;
    } else if (beforeAdmin === false && afterAdmin === false) {
      adminAvailable = false;
    }
    return {
      adminRequired,
      adminAvailable,
      unavailableAdminRequired: adminRequired === true && adminAvailable !== true,
      before: beforeAdmin ?? null,
      after: afterAdmin ?? null,
    };
  }

  function mergeBenchmarkRemediations(remediations, context = {}) {
    const paths = [];
    const actions = [];
    const verificationCommands = [];
    const cleanHostRequiredFor = new Set();
    const seenActions = new Set();
    const seenVerifications = new Set();
    let blocked = false;

    for (const remediation of remediations) {
      if (!isPlainObject(remediation)) continue;
      blocked = blocked || remediation.blocked === true;
      for (const entry of remediation.paths ?? []) {
        if (typeof entry === "string" && !paths.includes(entry)) paths.push(entry);
      }
      for (const entry of remediation.cleanHostRequiredFor ?? []) {
        if (typeof entry === "string") cleanHostRequiredFor.add(entry);
      }
      for (const action of remediation.actions ?? []) {
        if (!isPlainObject(action)) continue;
        const key = `${action.issueId ?? ""}:${action.action ?? ""}:${action.command ?? ""}`;
        if (seenActions.has(key)) continue;
        seenActions.add(key);
        actions.push(action);
      }
      for (const command of remediation.verificationCommands ?? []) {
        if (!isPlainObject(command)) continue;
        const key = `${command.issueId ?? ""}:${command.command ?? ""}`;
        if (seenVerifications.has(key)) continue;
        seenVerifications.add(key);
        verificationCommands.push(command);
      }
    }

    if (context.includeSpeedDiagnostics === true) {
      if (!seenActions.has("speed_regression:diagnose")) {
        actions.push({
          issueId: "speed_regression",
          action: "Inspect the latest installed, historical, and benchmark-control reports, then rerun the retained speed gate after the host envelope is clean.",
          command: null,
          reason: "Strict speed lanes failed; the next step is report-driven attribution, not blind hot-path edits.",
          mutates: false,
          requiresAdmin: false,
        });
        seenActions.add("speed_regression:diagnose");
      }
      if (!seenVerifications.has("speed_regression:latest-report-summary")) {
        verificationCommands.push({
          issueId: "speed_regression",
          command: "node -e \"const fs=require('fs'); for (const dir of ['tools/reports/architecture-gate','tools/reports/manual-speed-compare','tools/reports/historical-speed','tools/reports/older-snapshot-ladder']) { const files=fs.existsSync(dir)?fs.readdirSync(dir).filter(f=>f.endsWith('.json')).map(f=>dir+'/'+f).sort((a,b)=>fs.statSync(b).mtimeMs-fs.statSync(a).mtimeMs):[]; if (files[0]) console.log(files[0]); }\"",
          reason: "Lists the newest speed evidence reports to inspect before retaining or reverting a performance change.",
          mutates: false,
          requiresAdmin: false,
        });
        seenVerifications.add("speed_regression:latest-report-summary");
      }
    }

    return {
      blocked,
      actions,
      verificationCommands,
      paths,
      cleanHostRequiredFor: [...cleanHostRequiredFor],
    };
  }

  function benchmarkLockSelfTest() {
    const lockRoot = path.join(os.tmpdir(), `ix-benchmark-lock-gate-${process.pid}-${Date.now()}`);
    const staleLock = path.join(lockRoot, "stale.lock");
    const liveLock = path.join(lockRoot, "live.lock");
    const failures = [];
    const metrics = {
      staleReclaimed: false,
      liveRejected: false,
      lockReleased: false,
      root: lockRoot,
    };
    try {
      mkdirSync(staleLock, { recursive: true });
      writeFileSync(path.join(staleLock, "owner.json"), `${JSON.stringify({ pid: 2147483647, script: "dead-owner" })}\n`);
      const acquired = acquireBenchmarkLock({ lockDir: staleLock, script: "architecture-gate-stale-lock-self-test" });
      metrics.staleReclaimed = existsSync(path.join(staleLock, "owner.json"));
      acquired.release();
      metrics.lockReleased = !existsSync(staleLock);

      mkdirSync(liveLock, { recursive: true });
      writeFileSync(path.join(liveLock, "owner.json"), `${JSON.stringify({ pid: process.pid, script: "live-owner" })}\n`);
      try {
        acquireBenchmarkLock({ lockDir: liveLock, script: "architecture-gate-live-lock-self-test" });
        failures.push("live owner benchmark lock was acquired unexpectedly");
      } catch (err) {
        metrics.liveRejected = String(err?.message ?? "").includes("owner_pid_alive");
        if (!metrics.liveRejected) failures.push(`live owner benchmark lock failed for wrong reason: ${err?.message ?? err}`);
      }
    } catch (err) {
      failures.push(`benchmark lock self-test threw: ${err?.message ?? err}`);
    } finally {
      rmSync(lockRoot, { recursive: true, force: true });
    }
    if (metrics.staleReclaimed !== true) failures.push("stale dead-owner benchmark lock was not reclaimed");
    if (metrics.lockReleased !== true) failures.push("acquired benchmark lock was not released");
    if (metrics.liveRejected !== true) failures.push("live owner benchmark lock was not refused");
    return { failures, metrics };
  }

  function validateBenchmarkLockLane(entry, failures) {
    if (entry.id !== "benchmark_lock") return;
    if (entry.status !== "ok") return;
    if (
      !isPlainObject(entry.metrics) ||
      entry.metrics.staleReclaimed !== true ||
      entry.metrics.liveRejected !== true ||
      entry.metrics.lockReleased !== true
    ) {
      failures.push("benchmark_lock: ok status requires stale reclaim and live-lock refusal proof");
    }
  }

  function validateNativeInstallIdentityLane(entry, failures) {
    if (entry.id !== "native_install_identity") return;
    if (entry.status === "skipped" && String(entry.reason ?? "").includes("promotion blocked")) {
      if (!isPlainObject(entry.repo) || typeof entry.repo.sha256 !== "string" || entry.repo.sha256.length === 0) {
        failures.push("native_install_identity: promotion-blocked skip requires repo sha256 evidence");
        return;
      }
      if (!Array.isArray(entry.installed) || entry.installed.length === 0) {
        failures.push("native_install_identity: promotion-blocked skip requires installed alias hash evidence");
        return;
      }
      if (!Array.isArray(entry.mismatched) || entry.mismatched.length === 0) {
        failures.push("native_install_identity: promotion-blocked skip requires mismatched installed alias evidence");
      }
      if (!isPlainObject(entry.decision)) {
        failures.push("native_install_identity: promotion-blocked skip requires fresh Teddy decision evidence");
        return;
      }
      if (entry.decision.currentIxSha256 !== entry.repo.sha256) {
        failures.push("native_install_identity: promotion-blocked decision hash must match repo ix-zig.exe");
      }
      if (entry.decision.promotionAllowed !== false) {
        failures.push("native_install_identity: promotion-blocked skip requires promotionAllowed=false");
      }
      return;
    }
    if (entry.status !== "ok") return;
    if (!isPlainObject(entry.repo) || typeof entry.repo.sha256 !== "string" || entry.repo.sha256.length === 0) {
      failures.push("native_install_identity: ok status requires repo sha256 evidence");
      return;
    }
    if (!Array.isArray(entry.installed) || entry.installed.length === 0) {
      failures.push("native_install_identity: ok status requires installed alias hash evidence");
      return;
    }
    const mismatched = entry.installed.filter((installed) => !isPlainObject(installed) || installed.sha256 !== entry.repo.sha256);
    if (mismatched.length > 0) {
      failures.push("native_install_identity: ok status requires every installed alias hash to match repo ix-zig.exe");
    }
  }

  function benchmarkHostPreflightLane({ lane, snapshot }) {
    const host = { before: snapshot, after: snapshot };
    const hostIssues = hostBenchmarkIssues(host);
    const hostClean = hostBenchmarkClean(hostIssues);
    return lane("benchmark_host_preflight", hostClean ? "ok" : "failed", {
      reason: hostClean ? undefined : "host benchmark envelope contains warning-class noise; speed attribution is disabled before corpus sampling",
      metrics: {
        hostClean,
        hostIssues,
        remediation: benchmarkHostRemediation(hostIssues, { corpus: benchmarkCorpus, stateDir }),
        host,
      },
    });
  }

  function benchmarkReadinessLane({ lane, hostPreflight, benchmarkControl, speedLanes = [] }) {
    const blockers = [];
    const speedLaneFailureSummary = (speedLane) => ({
      lane: speedLane?.id ?? null,
      status: speedLane?.status ?? null,
      reason: speedLane?.reason ?? null,
      failures: speedLane?.failures ?? [],
      reportFailures: speedLane?.report?.failures ?? [],
      strictEvidenceFailures: speedLane?.report?.strictEvidenceFailures ?? [],
      requiredGateFailures: speedLane?.report?.requiredGateFailures ?? [],
      scorecard: isPlainObject(speedLane?.report?.scorecard)
        ? {
            testedOneAtATime: speedLane.report.scorecard.testedOneAtATime ?? null,
            netPositive: speedLane.report.scorecard.netPositive ?? null,
            losingRounds: Array.isArray(speedLane.report.scorecard.losingRounds)
              ? speedLane.report.scorecard.losingRounds.slice(0, 4)
              : [],
          }
        : null,
      reportFailureSummary: speedLane?.report?.failureSummary ?? null,
    });
    const hostRemediation = hostPreflight?.metrics?.remediation ?? null;
    const controlRemediation = benchmarkControl?.status === "failed"
      ? benchmarkHostRemediation(benchmarkControl.metrics?.hostIssues ?? [], { corpus: benchmarkCorpus, stateDir })
      : null;
    if (hostPreflight?.status === "failed") {
      blockers.push({
        id: "host_preflight",
        lane: "benchmark_host_preflight",
        reason: hostPreflight.reason ?? "benchmark host preflight failed",
        affectedLanes: hostRemediation?.cleanHostRequiredFor ?? [
          "benchmark_control",
          "ripgrep_12_sample",
          "installed_speed_compare",
          "historical_speed_compare",
          "older_snapshot_ladder",
          "alternates_decision",
        ],
      });
    }
    if (benchmarkControl?.status === "failed") {
      blockers.push({
        id: "benchmark_control",
        lane: "benchmark_control",
        reason: benchmarkControl.reason ?? "same-binary benchmark control failed",
        failureSummary: benchmarkControl.metrics?.failureSummary ?? null,
        affectedLanes: [
          "ripgrep_12_sample",
          "installed_speed_compare",
          "historical_speed_compare",
          "older_snapshot_ladder",
          "alternates_decision",
        ],
      });
    }
    for (const speedLane of speedLanes) {
      if (speedLane?.status === "failed") {
        blockers.push({
          id: `${speedLane.id}_failed`,
          lane: speedLane.id,
          reason: speedLane.reason ?? "speed comparison lane failed",
          failureSummary: speedLaneFailureSummary(speedLane),
          affectedLanes: [speedLane.id],
        });
      }
      if (
        speedLane?.status === "skipped" &&
        Array.isArray(speedLane.requiredGateFailures) &&
        speedLane.requiredGateFailures.length > 0
      ) {
        blockers.push({
          id: `${speedLane.id}_required_gate`,
          lane: speedLane.id,
          reason: speedLane.reason ?? "speed comparison required gate failed",
          failureSummary: speedLaneFailureSummary(speedLane),
          affectedLanes: [speedLane.id],
        });
      }
    }
    const admissible = blockers.length === 0;
    const remediation = admissible
      ? null
      : mergeBenchmarkRemediations(
          [
            hostRemediation,
            controlRemediation,
            ...speedLanes.map((entry) => entry?.remediation),
          ],
          {
            includeSpeedDiagnostics:
              benchmarkControl?.status === "failed" ||
              speedLanes.some((entry) => entry?.status === "failed"),
          },
        );
    const privilege = benchmarkPrivilegeSummary(hostPreflight, remediation);
    return lane("benchmark_readiness", admissible ? "ok" : "failed", {
      reason: admissible ? undefined : "speed attribution is not admissible until benchmark readiness blockers are cleared",
      metrics: {
        admissible,
        blockers,
        remediation,
        privilege,
        nextCommands: admissible ? [] : benchmarkReadinessNextCommands({ corpus: benchmarkCorpus }),
        hostStatus: hostPreflight?.status ?? null,
        benchmarkControlStatus: benchmarkControl?.status ?? null,
        speedLaneStatuses: Object.fromEntries(speedLanes.map((entry) => [entry.id, entry.status])),
      },
    });
  }

  function validateHostPreflightSkipRemediation(entry, failures, laneId, reason) {
    if (entry.status !== "skipped" || entry.reason !== reason) return;
    if (!Array.isArray(entry.requiredGateFailures) || entry.requiredGateFailures.length === 0) {
      failures.push(`${laneId}: host-preflight skip requires required gate failure envelope`);
    }
    if (!isPlainObject(entry.remediation) || !Array.isArray(entry.remediation.actions) || entry.remediation.actions.length === 0) {
      failures.push(`${laneId}: host-preflight skip requires remediation actions`);
    }
    if (hasDefenderRemediation(entry.remediation) && !hasStableDefenderRemediationPaths(entry.remediation)) {
      failures.push(`${laneId}: host-preflight skip Defender remediation must include stable benchmark exclusion paths`);
    }
  }

  function validateBenchmarkHostPreflightLane(entry, failures) {
    if (entry.id !== "benchmark_host_preflight") return;
    const hostBefore = entry.metrics?.host?.before;
    const hostAfter = entry.metrics?.host?.after;
    if (
      entry.status !== "skipped" &&
      (!isPlainObject(hostBefore?.elevation) ||
        !isPlainObject(hostAfter?.elevation) ||
        typeof hostBefore.elevation.checked !== "boolean" ||
        typeof hostAfter.elevation.checked !== "boolean")
    ) {
      failures.push("benchmark_host_preflight: host snapshots require elevation metadata");
    }
    if (entry.status !== "failed") return;
    const remediation = entry.metrics?.remediation;
    if (
      !isPlainObject(remediation) ||
      remediation.blocked !== true ||
      !Array.isArray(remediation.actions) ||
      remediation.actions.length === 0
    ) {
      failures.push("benchmark_host_preflight: failed status requires remediation actions");
    }
    if (
      !isPlainObject(remediation) ||
      !Array.isArray(remediation.actions) ||
      remediation.actions.some((action) => typeof action?.mutates !== "boolean" || typeof action?.requiresAdmin !== "boolean")
    ) {
      failures.push("benchmark_host_preflight: remediation actions must declare mutation and privilege behavior");
    }
    if (
      isPlainObject(remediation) &&
      Array.isArray(remediation.actions) &&
      remediation.actions.some((action) => typeof action?.command === "string" && action.command.length > 0 && action.mutates !== true)
    ) {
      failures.push("benchmark_host_preflight: command remediation actions must be marked mutating");
    }
    if (
      !isPlainObject(remediation) ||
      !Array.isArray(remediation.verificationCommands) ||
      remediation.verificationCommands.length === 0 ||
      remediation.verificationCommands.some((command) =>
        command?.mutates !== false || typeof command?.command !== "string" || typeof command?.requiresAdmin !== "boolean"
      )
    ) {
      failures.push("benchmark_host_preflight: failed status requires non-mutating verification commands with privilege metadata");
    }
    if (
      isPlainObject(remediation) &&
      Array.isArray(remediation.actions) &&
      remediation.actions.some((action) => action?.issueId === "defender_active_in_top_working_set" && action.requiresAdmin !== true)
    ) {
      failures.push("benchmark_host_preflight: Defender remediation must be marked admin-required");
    }
    if (
      isPlainObject(remediation) &&
      Array.isArray(remediation.verificationCommands) &&
      remediation.verificationCommands.some((command) => command?.issueId === "defender_active_in_top_working_set" && command.requiresAdmin !== true)
    ) {
      failures.push("benchmark_host_preflight: Defender verification must be marked admin-required");
    }
    if (hasDefenderRemediation(remediation) && !hasStableDefenderRemediationPaths(remediation)) {
      failures.push("benchmark_host_preflight: Defender remediation must include stable benchmark exclusion paths");
    }
  }

  function validateBenchmarkReadinessLane(entry, failures) {
    if (entry.id !== "benchmark_readiness") return;
    if (!isPlainObject(entry.metrics)) {
      failures.push("benchmark_readiness: status requires readiness metrics");
      return;
    }
    if (typeof entry.metrics.admissible !== "boolean") {
      failures.push("benchmark_readiness: metrics.admissible must be boolean");
    }
    if (!Array.isArray(entry.metrics.blockers)) {
      failures.push("benchmark_readiness: metrics.blockers must be an array");
    }
    if (Array.isArray(entry.metrics.blockers)) {
      const controlBlocker = entry.metrics.blockers.find((blocker) => blocker?.id === "benchmark_control");
      if (
        controlBlocker &&
        !isPlainObject(controlBlocker.failureSummary)
      ) {
        failures.push("benchmark_readiness: benchmark-control blocker requires propagated failure summary");
      }
      for (const blocker of entry.metrics.blockers) {
        if (
          typeof blocker?.id === "string" &&
          (blocker.id.endsWith("_failed") || blocker.id.endsWith("_required_gate")) &&
          !isPlainObject(blocker.failureSummary)
        ) {
          failures.push(`benchmark_readiness: speed blocker requires failure summary: ${blocker.id}`);
        }
      }
    }
    if (entry.status === "ok" && entry.metrics.admissible !== true) {
      failures.push("benchmark_readiness: ok status requires admissible true");
    }
    if (entry.status === "failed" && entry.metrics.admissible !== false) {
      failures.push("benchmark_readiness: failed status requires admissible false");
    }
    if (
      entry.status === "failed" &&
      (!isPlainObject(entry.metrics.remediation) ||
        !Array.isArray(entry.metrics.remediation.actions) ||
        entry.metrics.remediation.actions.length === 0)
    ) {
      failures.push("benchmark_readiness: failed status requires remediation actions");
    }
    if (
      entry.status === "failed" &&
      (!isPlainObject(entry.metrics.remediation) ||
        !Array.isArray(entry.metrics.remediation.actions) ||
        entry.metrics.remediation.actions.some((action) => typeof action?.mutates !== "boolean" || typeof action?.requiresAdmin !== "boolean"))
    ) {
      failures.push("benchmark_readiness: remediation actions must declare mutation and privilege behavior");
    }
    if (
      entry.status === "failed" &&
      isPlainObject(entry.metrics.remediation) &&
      Array.isArray(entry.metrics.remediation.actions) &&
      entry.metrics.remediation.actions.some((action) => typeof action?.command === "string" && action.command.length > 0 && action.mutates !== true)
    ) {
      failures.push("benchmark_readiness: command remediation actions must be marked mutating");
    }
    if (
      entry.status === "failed" &&
      (!isPlainObject(entry.metrics.remediation) ||
        !Array.isArray(entry.metrics.remediation.verificationCommands) ||
        entry.metrics.remediation.verificationCommands.length === 0 ||
        entry.metrics.remediation.verificationCommands.some((command) =>
          command?.mutates !== false || typeof command?.requiresAdmin !== "boolean"
        ))
    ) {
      failures.push("benchmark_readiness: failed status requires non-mutating verification commands with privilege metadata");
    }
    if (
      entry.status === "failed" &&
      isPlainObject(entry.metrics.remediation) &&
      Array.isArray(entry.metrics.remediation.actions) &&
      entry.metrics.remediation.actions.some((action) => action?.issueId === "defender_active_in_top_working_set" && action.requiresAdmin !== true)
    ) {
      failures.push("benchmark_readiness: Defender remediation must be marked admin-required");
    }
    if (
      entry.status === "failed" &&
      isPlainObject(entry.metrics.remediation) &&
      Array.isArray(entry.metrics.remediation.verificationCommands) &&
      entry.metrics.remediation.verificationCommands.some((command) =>
        command?.issueId === "defender_active_in_top_working_set" && command.requiresAdmin !== true
      )
    ) {
      failures.push("benchmark_readiness: Defender verification must be marked admin-required");
    }
    if (
      entry.status === "failed" &&
      hasDefenderRemediation(entry.metrics.remediation) &&
      !hasStableDefenderRemediationPaths(entry.metrics.remediation)
    ) {
      failures.push("benchmark_readiness: Defender remediation must include stable benchmark exclusion paths");
    }
    if (entry.status === "failed" && !isPlainObject(entry.metrics.privilege)) {
      failures.push("benchmark_readiness: failed status requires privilege readiness summary");
    }
    if (
      entry.status === "failed" &&
      isPlainObject(entry.metrics.privilege) &&
      (typeof entry.metrics.privilege.adminRequired !== "boolean" ||
        (entry.metrics.privilege.adminAvailable !== true &&
          entry.metrics.privilege.adminAvailable !== false &&
          entry.metrics.privilege.adminAvailable !== null) ||
        typeof entry.metrics.privilege.unavailableAdminRequired !== "boolean")
    ) {
      failures.push("benchmark_readiness: privilege summary must declare admin requirement and availability");
    }
    if (
      entry.status === "failed" &&
      isPlainObject(entry.metrics.remediation) &&
      isPlainObject(entry.metrics.privilege) &&
      [
        ...(Array.isArray(entry.metrics.remediation.actions) ? entry.metrics.remediation.actions : []),
        ...(Array.isArray(entry.metrics.remediation.verificationCommands) ? entry.metrics.remediation.verificationCommands : []),
      ].some(
        (item) => item?.requiresAdmin === true,
      ) &&
      entry.metrics.privilege.adminRequired !== true
    ) {
      failures.push("benchmark_readiness: admin remediation requires adminRequired privilege summary");
    }
    if (
      entry.status === "failed" &&
      isPlainObject(entry.metrics.privilege) &&
      entry.metrics.privilege.adminRequired === true &&
      entry.metrics.privilege.before === false &&
      entry.metrics.privilege.after === false &&
      entry.metrics.privilege.unavailableAdminRequired !== true
    ) {
      failures.push("benchmark_readiness: unavailable admin remediation must be surfaced");
    }
    if (
      entry.status === "failed" &&
      (!Array.isArray(entry.metrics.nextCommands) ||
        entry.metrics.nextCommands.length === 0 ||
        entry.metrics.nextCommands.some((next) => typeof next?.id !== "string" || typeof next?.command !== "string"))
    ) {
      failures.push("benchmark_readiness: failed status requires executable next commands");
    }
    if (entry.status === "failed" && Array.isArray(entry.metrics.nextCommands)) {
      const requiredCommandIds = [
        "host_preflight_smoke",
        "retained_installed_historical",
        "retained_alternates_route",
        "direct_comparator_smoke",
      ];
      const present = new Set(entry.metrics.nextCommands.map((next) => next?.id));
      if (requiredCommandIds.some((id) => !present.has(id))) {
        failures.push("benchmark_readiness: failed status requires the canonical speed recovery command set");
      }
      const commandById = new Map(entry.metrics.nextCommands.map((next) => [next?.id, next?.command]));
      const hostSmoke = String(commandById.get("host_preflight_smoke") ?? "");
      if (
        !hostSmoke.includes("--speed-only") ||
        !hostSmoke.includes("--strict-installed-speed") ||
        !hostSmoke.includes("--strict-historical-speed") ||
        !hostSmoke.includes("--strict-older-snapshots") ||
        !hostSmoke.includes("--installed-speed-samples 2") ||
        !hostSmoke.includes("--historical-speed-samples 2") ||
        !hostSmoke.includes("--older-snapshot-samples 2") ||
        !hostSmoke.includes("--older-snapshot-max 1") ||
        !hostSmoke.includes("--older-snapshot-retainable-target 1") ||
        !hostSmoke.includes("--older-snapshot-identity-attempts 3") ||
        !hostSmoke.includes("--min-older-snapshot-engine-pct 5") ||
        !hostSmoke.includes("--min-older-snapshot-paired-pct 5") ||
        !hostSmoke.includes("--min-retainable-speed-samples 2")
      ) {
        failures.push("benchmark_readiness: host preflight smoke command must run strict paired-smoke speed gates");
      }
      const retained = String(commandById.get("retained_installed_historical") ?? "");
      if (
        !retained.includes("--speed-only") ||
        !retained.includes("--strict-installed-speed") ||
        !retained.includes("--strict-historical-speed") ||
        !retained.includes("--strict-older-snapshots") ||
        !retained.includes("--installed-speed-samples 12") ||
        !retained.includes("--historical-speed-samples 12") ||
        !retained.includes("--older-snapshot-samples 12") ||
        !retained.includes("--older-snapshot-retainable-target 2") ||
        !retained.includes("--older-snapshot-identity-attempts 3") ||
        !retained.includes("--min-older-snapshot-engine-pct 5") ||
        !retained.includes("--min-older-snapshot-paired-pct 5") ||
        !retained.includes("--min-retainable-speed-samples 12")
      ) {
        failures.push("benchmark_readiness: retained installed/historical command must run strict retained sample gates");
      }
      const alternates = String(commandById.get("retained_alternates_route") ?? "");
      if (
        !alternates.includes("--speed-only") ||
        !alternates.includes("--alternates-decision") ||
        !alternates.includes("--alternates-decision-samples 12") ||
        !alternates.includes("--alternates-decision-branch-counts 2,4,8") ||
        !alternates.includes("--min-retainable-speed-samples 12")
      ) {
        failures.push("benchmark_readiness: retained alternates command must run branch-count route gates");
      }
      const direct = String(commandById.get("direct_comparator_smoke") ?? "");
      if (
        !direct.includes("tools/scripts/compare-installed-speed.mjs") ||
        !direct.includes("--samples 2") ||
        !direct.includes("--min-retainable-samples 2") ||
        !direct.includes("--require-strict") ||
        !direct.includes("--require-promotion")
      ) {
        failures.push("benchmark_readiness: direct comparator smoke command must require strict installed identity/promotion evidence with a matched sample floor");
      }
    }
  }

  return {
    benchmarkHostPreflightLane,
    benchmarkLockSelfTest,
    benchmarkReadinessLane,
    benchmarkHostRemediation,
    benchmarkPrivilegeSummary,
    benchmarkReadinessNextCommands,
    hostBenchmarkClean,
    hostBenchmarkIssues,
    mergeBenchmarkRemediations,
    validateBenchmarkLockLane,
    validateBenchmarkHostPreflightLane,
    validateBenchmarkReadinessLane,
    validateHostPreflightSkipRemediation,
    validateNativeInstallIdentityLane,
  };
}
