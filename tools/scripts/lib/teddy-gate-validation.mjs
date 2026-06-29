import { existsSync, readFileSync, rmSync } from "node:fs";
import path from "node:path";

function isPlainObject(value) {
  return value !== null && typeof value === "object" && !Array.isArray(value);
}

function mixedTeddyGainNeedsLeakRepair(decision) {
  return (
    decision?.leakSummary?.diagnosis === "preserve_positive_teddy_gain_and_repair_whole_engine_leak" &&
    decision?.summary?.matchParity === true &&
    decision?.summary?.routeParity === true
  );
}

function benchmarkNoiseFailures(decision) {
  const evidenceQuality = decision?.evidenceQuality ?? {};
  return [
    ...(evidenceQuality.hostFailures ?? []),
    ...(evidenceQuality.identityFailures ?? []),
    ...(evidenceQuality.processFailures ?? []),
    ...(evidenceQuality.sampleFailures ?? []),
  ];
}

function evidenceBlockedByBenchmarkNoise(decision) {
  return benchmarkNoiseFailures(decision).length > 0;
}

function expectedScanWorkRepairMove(decision) {
  const split = decision?.leakSummary?.leakAttribution?.currentOnlyScanSplit;
  if (split?.regressingCandidateSubphase === "scanFile") return "scan_file_residual_hotspot_attribution";
  if (split?.dominantCandidateSubphase === "scanOpen") return "scan_open_path_pressure_attribution";
  return "whole_engine_leak_attribution";
}

function expectedTeddyNextMove(decision) {
  if (evidenceBlockedByBenchmarkNoise(decision)) {
    return "benchmark_host_noise_control";
  }
  if (
    mixedTeddyGainNeedsLeakRepair(decision) &&
    decision?.leakSummary?.nextRepairTarget === "scanWork" &&
    ["scan_file_residual_hotspot_attribution", "scan_open_path_pressure_attribution"].includes(expectedScanWorkRepairMove(decision))
  ) {
    return expectedScanWorkRepairMove(decision);
  }
  return mixedTeddyGainNeedsLeakRepair(decision)
    ? "whole_engine_leak_attribution"
    : "packed_nibble_shuffle_teddy_kernel";
}

function expectedTeddyRepairMove(decision) {
  return expectedScanWorkRepairMove(decision);
}

function rejectedMoveIds(decision) {
  return new Set((decision?.candidateMoves ?? [])
    .filter((move) => move?.status === "rejected")
    .map((move) => move.id));
}

function validateTeddyDecision(decision, evidence) {
  const failures = [];
  const rejectedIds = rejectedMoveIds(decision);
  if (evidence.exitCode !== 0) failures.push("teddy kernel decision script failed");
  if (decision.evidenceFresh !== true) failures.push("teddy kernel decision requires historical evidence for the current repo binary");
  if (decision.promotionAllowed === true) failures.push("teddy kernel decision should not promote a non-net-positive historical report");
  if (decision.summary?.matchParity !== true) failures.push("teddy kernel decision requires match parity");
  if (decision.summary?.routeParity !== true) failures.push("teddy kernel decision requires route parity");
  if (Number(decision.summary?.count ?? 0) < 1) failures.push("teddy kernel decision requires historical rounds");

  const expectedNextMove = expectedTeddyNextMove(decision);
  const evidenceBlockedByNoise = evidenceBlockedByBenchmarkNoise(decision);
  const preserveTeddyWin = mixedTeddyGainNeedsLeakRepair(decision);
  if (decision.nextAllowedMove?.id !== expectedNextMove) {
    failures.push(`teddy kernel decision must rank ${expectedNextMove} as next allowed move`);
  }
  if (
    preserveTeddyWin &&
    !evidenceBlockedByNoise &&
    !decision.candidateMoves?.some((move) =>
      move?.id === "packed_nibble_shuffle_teddy_kernel" &&
      move?.status === "allowed_after_whole_engine_leak_attribution")
  ) {
    failures.push("teddy kernel decision must preserve packed nibble/shuffle as follow-up after whole-engine leak attribution");
  }
  if (
    evidenceBlockedByNoise &&
    !decision.candidateMoves?.some((move) =>
      move?.id === "whole_engine_leak_attribution" &&
      move?.status === "blocked_by_benchmark_noise")
  ) {
    failures.push("teddy kernel decision must block runtime leak attribution when benchmark evidence is noisy");
  }
  if (!String(decision.nextAllowedMove?.proofCommand ?? "").includes("compare-historical-speed.mjs")) {
    failures.push("teddy kernel next move requires historical speed proof command");
  }
  if (
    String(decision.nextAllowedMove?.proofCommand ?? "").includes("--samples 12") &&
    !String(decision.nextAllowedMove?.proofCommand ?? "").includes("--identity-control-samples 12")
  ) {
    failures.push("teddy kernel next move requires 12 same-binary identity-control samples for 12-sample historical proof");
  }
  if (preserveTeddyWin) {
    if (decision.preservationPolicy?.preserveTeddyGain !== true) {
      failures.push("teddy kernel decision must explicitly preserve the positive Teddy gain");
    }
    if (decision.preservationPolicy?.nextEngineeringMoveId !== expectedTeddyRepairMove(decision)) {
      failures.push("teddy kernel decision must route mixed Teddy/engine evidence to the proved repair owner");
    }
    if (decision.nextEngineeringMove?.id !== "whole_engine_leak_attribution") {
      const split = decision.leakSummary?.leakAttribution?.currentOnlyScanSplit;
      if (decision.nextEngineeringMove?.id !== expectedScanWorkRepairMove(decision)) {
        failures.push("teddy kernel decision must expose the proved leak owner as the next engineering move");
      }
    }
    if (
      decision.leakSummary?.nextRepairTarget === "scanWork" &&
      !String(decision.nextAllowedMove?.proofCommand ?? "").includes("--scan-open-timing")
    ) {
      failures.push("scanWork leak attribution proof command must enable scan-open timing");
    }
    if (!String(decision.preservationPolicy?.rule ?? "").includes("do_not_revert_teddy_gain")) {
      failures.push("teddy kernel decision must encode the no-revert preservation rule for mixed gains");
    }
    if (decision.leakSummary?.nextRepairTarget === "scanWork") {
      const split = decision.leakSummary?.leakAttribution?.currentOnlyScanSplit;
      if (!isPlainObject(split)) {
        failures.push("scanWork leak attribution requires current-only scanOpen/scanFile split summary");
      } else {
        if (Number(split.targetRoundCount ?? 0) < 1) {
          failures.push("scanWork leak attribution requires at least one target round");
        }
        if (Number(split.candidateSplitRoundCount ?? 0) < Number(split.targetRoundCount ?? 0)) {
          failures.push("scanWork leak attribution requires candidate split telemetry for every target round");
        }
        if (!["scanOpen", "scanFile"].includes(split.dominantCandidateSubphase)) {
          failures.push("scanWork leak attribution requires a dominant candidate subphase");
        }
        if (split.regressingCandidateSubphase != null && !["scanOpen", "scanFile"].includes(split.regressingCandidateSubphase)) {
          failures.push("scanWork leak attribution requires a valid regressing candidate subphase");
        }
        if (
          split.regressingCandidateSubphase === "scanFile" &&
          !decision.candidateMoves?.some((move) =>
            move?.id === "scan_file_residual_hotspot_attribution" &&
            move?.status === "allowed_next")
        ) {
          failures.push("scanFile-regressing leak attribution must route to scan-file residual hotspots");
        }
        if (
          split.regressingCandidateSubphase === "scanFile" &&
          !Array.isArray(split.candidateSlowestPathHotspots)
        ) {
          failures.push("scanFile-regressing leak attribution requires candidate slowest-path hotspots");
        }
        if (
          split.dominantCandidateSubphase === "scanOpen" &&
          split.regressingCandidateSubphase !== "scanFile" &&
          !decision.candidateMoves?.some((move) =>
            move?.id === "scan_open_path_pressure_attribution" &&
            move?.status === "allowed_next")
        ) {
          failures.push("scanOpen-dominant leak attribution must route to scan-open path pressure");
        }
        if (
          split.dominantCandidateSubphase === "scanOpen" &&
          split.regressingCandidateSubphase !== "scanFile" &&
          Number(split.candidateScanOpenMsPerFileMedian?.median ?? 0) <= 0
        ) {
          failures.push("scanOpen-dominant leak attribution requires per-file open pressure");
        }
        if (
          split.dominantCandidateSubphase === "scanOpen" &&
          split.regressingCandidateSubphase !== "scanFile" &&
          split.filesScannedParity !== true
        ) {
          failures.push("scanOpen-dominant leak attribution requires scanned-file-count parity");
        }
        if (
          split.dominantCandidateSubphase === "scanFile" &&
          !["teddyRange", "alternateFullScan", "scanFileResidual"].includes(split.dominantCandidateScanFileComponent)
        ) {
          failures.push("scanFile leak attribution requires a dominant candidate scan-file component");
        }
        if (
          split.dominantCandidateScanFileComponent === "alternateFullScan" &&
          Number(split.candidateAlternateFullScanMedianMs?.median ?? 0) <= 0
        ) {
          failures.push("alternate full-scan attribution requires elapsed median timing");
        }
        if (
          split.dominantCandidateScanFileComponent === "scanFileResidual" &&
          !Array.isArray(split.candidateSlowestPathHotspots)
        ) {
          failures.push("scanFile residual attribution requires candidate slowest-path hotspots");
        }
      }
    }
  }
  if (!rejectedIds.has("scalar_start_byte_or_line_admission")) {
    failures.push("teddy kernel decision must reject scalar start-byte/line admission");
  }
  if (!rejectedIds.has("folded_trigram_admission_for_casefold_alternates")) {
    failures.push("teddy kernel decision must reject folded trigram admission for casefold alternates");
  }
  if (!rejectedIds.has("parallel_first_read_positional_transplant")) {
    failures.push("teddy kernel decision must reject parallel first-read positional transplant");
  }
  if (decision.researchBasis?.contractSignals?.requiresPackedSimdExtractor !== true) {
    failures.push("teddy kernel decision must cite packed-SIMD extractor contract");
  }
  if (decision.researchBasis?.contractSignals?.rejectsScalarTeddyLite !== true) {
    failures.push("teddy kernel decision must cite scalar Teddy rejection contract");
  }
  if (!Array.isArray(decision.researchBasis?.references) || decision.researchBasis.references.length === 0) {
    failures.push("teddy kernel decision requires Insect/reference basis");
  }
  return { failures, rejectedIds };
}

function decisionReport(decision, rejectedIds) {
  return {
    runId: decision.runId ?? null,
    evaluatedHistoricalRunId: decision.evaluatedHistoricalRunId ?? null,
    currentIxSha256: decision.currentIxSha256 ?? null,
    comparisonCurrentHashes: decision.comparisonCurrentHashes ?? [],
    evidenceFresh: decision.evidenceFresh === true,
    promotionAllowed: decision.promotionAllowed === true,
    summary: decision.summary ?? null,
    leakSummary: decision.leakSummary ?? null,
    preservationPolicy: decision.preservationPolicy ?? null,
    evidenceQuality: decision.evidenceQuality ?? null,
    nextAllowedMove: decision.nextAllowedMove ?? null,
    nextEngineeringMove: decision.nextEngineeringMove ?? null,
    rejectedIds: [...rejectedIds],
    researchBasis: decision.researchBasis ?? null,
  };
}

export function createTeddyGateValidation({ root, run, lane }) {
  function teddyKernelDecisionLane() {
    const latestHistorical = path.join(root, "tools", "reports", "historical-speed", "latest-historical-speed.json");
    if (!existsSync(latestHistorical)) {
      return lane("teddy_kernel_decision", "skipped", {
        reason: "latest historical speed report missing",
        expected: latestHistorical,
      });
    }
    const latestPath = path.join(root, "tools", "reports", "teddy-kernel-decision", "latest-teddy-kernel-decision.json");
    rmSync(latestPath, { force: true });
    const evidence = run(process.execPath, [
      "tools/scripts/teddy-kernel-decision.mjs",
      "--quiet",
    ]);
    if (!existsSync(latestPath)) {
      return lane("teddy_kernel_decision", "failed", {
        evidence,
        reason: "teddy kernel decision script did not write latest-teddy-kernel-decision.json",
      });
    }
    const decision = JSON.parse(readFileSync(latestPath, "utf8"));
    const { failures, rejectedIds } = validateTeddyDecision(decision, evidence);
    return lane("teddy_kernel_decision", failures.length === 0 ? "ok" : "failed", {
      evidence,
      report: decisionReport(decision, rejectedIds),
      failures,
      reason: failures.length > 0 ? "teddy kernel decision evidence gate failed" : undefined,
    });
  }

  function teddyKernelContractLane() {
    const latestDecision = path.join(root, "tools", "reports", "teddy-kernel-decision", "latest-teddy-kernel-decision.json");
    if (!existsSync(latestDecision)) {
      return lane("teddy_kernel_contract", "skipped", {
        reason: "latest Teddy kernel decision report missing",
        expected: latestDecision,
      });
    }
    const latestPath = path.join(root, "tools", "reports", "teddy-kernel-contract", "latest-teddy-kernel-contract.json");
    rmSync(latestPath, { force: true });
    const evidence = run(process.execPath, [
      "tools/scripts/teddy-kernel-contract-check.mjs",
      "--quiet",
    ]);
    if (!existsSync(latestPath)) {
      return lane("teddy_kernel_contract", "failed", {
        evidence,
        reason: "teddy kernel contract check did not write latest-teddy-kernel-contract.json",
      });
    }
    const parsed = JSON.parse(readFileSync(latestPath, "utf8"));
    const failures = Array.isArray(parsed.failures)
      ? [...parsed.failures]
      : ["teddy kernel contract check did not return failures array"];
    if (evidence.exitCode !== 0 && failures.length === 0) failures.push("teddy kernel contract check failed");
    if (parsed.status !== "ok" && failures.length === 0) failures.push("teddy kernel contract status is not ok");
    if (parsed.decision?.evidenceFresh !== true) failures.push("teddy kernel contract requires fresh decision evidence");
    if (parsed.decision?.promotionAllowed === true) failures.push("teddy kernel contract must not allow promotion from a non-net-positive decision");
    const expectedNextMove = expectedTeddyNextMove(parsed.decision);
    if (parsed.decision?.nextAllowedMove?.id !== expectedNextMove) {
      failures.push(`teddy kernel contract must preserve ${expectedNextMove} as the next move`);
    }
    if (
      isPlainObject(parsed.decision) &&
      mixedTeddyGainNeedsLeakRepair(parsed.decision) &&
      parsed.decision.preservationPolicy?.nextEngineeringMoveId !== expectedTeddyRepairMove(parsed.decision)
    ) {
      failures.push("teddy kernel contract must preserve Teddy gain and route engineering repair to the proved repair owner");
    }
    return lane("teddy_kernel_contract", failures.length === 0 ? "ok" : "failed", {
      evidence,
      report: {
        runId: parsed.runId ?? null,
        contract: parsed.contract ?? null,
        decision: parsed.decision ?? null,
        rejectedShapes: parsed.rejectedShapes ?? [],
        requiredProofCommands: parsed.requiredProofCommands ?? [],
      },
      failures,
      reason: failures.length > 0 ? "teddy kernel contract evidence gate failed" : undefined,
    });
  }

  return {
    teddyKernelContractLane,
    teddyKernelDecisionLane,
  };
}
