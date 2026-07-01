import { existsSync, readFileSync, rmSync } from "node:fs";
import path from "node:path";
import {
  buildAlternatesRoundLedger,
  buildAlternatesScorecard,
  pairOrderSummaryIsBalanced,
  roundLedgerMatchesExpected,
  scorecardMatchesExpected,
} from "./speed-compare-utils.mjs";

function isPlainObject(value) {
  return value !== null && typeof value === "object" && !Array.isArray(value);
}

function identityControlAttemptsComplete(identityControl) {
  const attemptsRequested = Number(identityControl?.attemptsRequested);
  const attemptsRun = Number(identityControl?.attemptsRun);
  return Number.isFinite(attemptsRequested) &&
    Number.isFinite(attemptsRun) &&
    attemptsRun >= attemptsRequested;
}

export function parseIntegerList(value) {
  if (value.length === 0) return [];
  return [...new Set(value.split(",")
    .map((part) => Number(part.trim()))
    .filter((entry) => Number.isInteger(entry)))]
    .sort((left, right) => left - right);
}

export function integerListsEqual(left, right) {
  if (!Array.isArray(left) || !Array.isArray(right) || left.length !== right.length) return false;
  return left.every((value, index) => value === right[index]);
}

export function summarizeAlternatesComparisons(comparisons) {
  const summary = {
    total: comparisons.length,
    improvements: 0,
    parity: 0,
    regressions: 0,
    candidateRegressions: 0,
    identityNoiseRegressions: 0,
    matchParityFailures: 0,
    pairOrderFailures: 0,
  };
  for (const comparison of comparisons) {
    if (comparison?.classification === "improvement") summary.improvements += 1;
    if (comparison?.classification === "parity") summary.parity += 1;
    if (comparison?.classification === "regression" || comparison?.regression === true) {
      summary.regressions += 1;
      if (comparison?.evidenceAuthority === "identity_noise_only") {
        summary.identityNoiseRegressions += 1;
      } else {
        summary.candidateRegressions += 1;
      }
    }
    if (comparison?.matchParity !== true) summary.matchParityFailures += 1;
    if (!pairOrderSummaryIsBalanced(comparison?.pairOrderSummary, comparison?.pairedEngine?.count)) summary.pairOrderFailures += 1;
  }
  return summary;
}

export function alternatesComparisonSummaryMatches(actual, expected) {
  if (!isPlainObject(actual)) return false;
  return [
    "total",
    "improvements",
    "parity",
    "regressions",
    "candidateRegressions",
    "identityNoiseRegressions",
    "matchParityFailures",
    "pairOrderFailures",
  ].every((key) => Number(actual[key]) === expected[key]);
}

export function alternatesScorecardMatches(comparisons, scorecard) {
  if (!Array.isArray(comparisons)) return false;
  return scorecardMatchesExpected(scorecard, buildAlternatesScorecard(comparisons));
}

export function alternatesRoundLedgerMatches(comparisons, roundLedger) {
  if (!Array.isArray(comparisons)) return false;
  return roundLedgerMatchesExpected(roundLedger, buildAlternatesRoundLedger(comparisons));
}

export function hasAlternatesProofMetadata(entry) {
  return (
    typeof entry?.proofCommand === "string" &&
    entry.proofCommand.includes("--alternates-decision") &&
    entry.proofCommand.includes("--min-retainable-speed-samples") &&
    Array.isArray(entry?.researchBasis) &&
    entry.researchBasis.length > 0 &&
    entry.researchBasis.every((basis) =>
      typeof basis?.name === "string" &&
      typeof basis?.url === "string" &&
      typeof basis?.invariant === "string" &&
      basis.invariant.length > 0
    )
  );
}

export function hasAlternatesExpectedGainScore(entry) {
  return (
    Number.isFinite(Number(entry?.expectedRecoverableMs)) &&
    Number(entry.expectedRecoverableMs) >= 0 &&
    Number.isFinite(Number(entry?.expectedGainScore)) &&
    Number(entry.expectedGainScore) >= 0
  );
}

export function hasAlternatesExpectedGainInputs(entry) {
  return (
    ["high", "medium", "low"].includes(entry?.expectedGainConfidence) &&
    isPlainObject(entry?.expectedGainInputs) &&
    Number.isFinite(Number(entry.expectedGainInputs?.deltaPct)) &&
    Number.isFinite(Number(entry.expectedGainInputs?.routeSharePct)) &&
    Number.isFinite(Number(entry.expectedGainInputs?.authorityWeight)) &&
    Number.isFinite(Number(entry.expectedGainInputs?.collisionWeight)) &&
    Number.isFinite(Number(entry.expectedGainInputs?.pairedWinRate))
  );
}

export function alternatesExpectedGainFormulaMatches(entry) {
  if (!hasAlternatesExpectedGainScore(entry) || !hasAlternatesExpectedGainInputs(entry)) return false;
  const inputs = entry.expectedGainInputs;
  const deltaPct = Math.max(0, Number(inputs.deltaPct));
  const routeSharePct = Math.min(100, Math.max(0, Number(inputs.routeSharePct)));
  const authorityWeight = Number(inputs.authorityWeight);
  const collisionWeight = Number(inputs.collisionWeight);
  const expected = deltaPct * (routeSharePct / 100) * authorityWeight * collisionWeight;
  return Math.abs(Number(entry.expectedGainScore) - expected) <= 0.000001;
}

export function alternatesExpectedGainSorted(entries) {
  if (!Array.isArray(entries)) return false;
  for (let i = 1; i < entries.length; i += 1) {
    if (Number(entries[i - 1]?.expectedGainScore) < Number(entries[i]?.expectedGainScore)) return false;
  }
  return true;
}

export function summarizeAlternateRoute(route) {
  const teddy = Array.isArray(route?.teddy) ? route.teddy.map(Number) : [];
  const pcre = Array.isArray(route?.pcre) ? route.pcre.map(Number) : [];
  const compiled = Array.isArray(route?.compiled) ? route.compiled.map(Number) : [];
  return {
    teddy,
    pcre,
    compiled,
    teddyObserved: teddy.some((value) => Number.isFinite(value) && value > 0),
    pcreObserved: pcre.some((value) => Number.isFinite(value) && value > 0),
    compiledObserved: compiled.some((value) => Number.isFinite(value) && value > 0),
  };
}

export function alternatesRepeatEvidenceFailures(repeatedEvidence) {
  if (!isPlainObject(repeatedEvidence)) return ["missing"];
  const comparableReportCount = Number(repeatedEvidence.comparableReportCount ?? 0);
  if (!Number.isFinite(comparableReportCount)) return ["invalid_comparable_report_count"];
  if (comparableReportCount <= 0) return [];
  if (repeatedEvidence.stable === true) return [];
  const branches = Array.isArray(repeatedEvidence.branches) ? repeatedEvidence.branches : [];
  if (branches.length === 0) return ["missing_branch_evidence"];
  return branches
    .filter((branch) => branch?.stable !== true)
    .map((branch) => {
      const branchCount = Number.isFinite(Number(branch?.branchCount)) ? Number(branch.branchCount) : "missing";
      const issues = Array.isArray(branch?.issues) && branch.issues.length > 0
        ? branch.issues.join(",")
        : "unknown";
      return `branch_${branchCount}:${issues}`;
    });
}

export function createAlternatesGateValidation({
  minRetainableSpeedSamples,
  validateHostPreflightSkipRemediation,
}) {
  function validateAlternatesDecisionLane(entry, failures) {
    if (entry.id !== "alternates_decision") return;
    validateHostPreflightSkipRemediation(
      entry,
      failures,
      "alternates_decision",
      "benchmark host preflight failed; skipping alternates decision sampling until host envelope is clean",
    );
    if (entry.status !== "ok") return;
    if (!isPlainObject(entry.report)) {
      failures.push("alternates_decision: ok status requires parsed decision report");
      return;
    }
    if (Number(entry.report.samples) !== Number(entry.samples)) {
      failures.push("alternates_decision: ok status requires parsed sample count to match requested samples");
    }
    if (Number(entry.report.samples) < minRetainableSpeedSamples) {
      failures.push("alternates_decision: ok status requires the retained sample floor");
    }
    if (!Array.isArray(entry.report.lanes) || entry.report.lanes.length === 0) {
      failures.push("alternates_decision: ok status requires decision lanes");
    }
    const requestedBranchCounts = parseIntegerList(entry.branchCounts ?? "");
    if (requestedBranchCounts.length > 0 && !integerListsEqual(entry.report.branchCounts, requestedBranchCounts)) {
      failures.push("alternates_decision: focused branch-count report must match requested branch counts");
    }
    if (!Array.isArray(entry.report.comparisons) || entry.report.comparisons.length === 0) {
      failures.push("alternates_decision: ok status requires same-host baseline comparisons");
    }
    if (!isPlainObject(entry.report.comparisonSummary)) {
      failures.push("alternates_decision: ok status requires comparison summary");
    } else if (Array.isArray(entry.report.comparisons)) {
      const expectedSummary = summarizeAlternatesComparisons(entry.report.comparisons);
      if (!alternatesComparisonSummaryMatches(entry.report.comparisonSummary, expectedSummary)) {
        failures.push("alternates_decision: comparison summary must match comparison rows");
      }
    }
    if (!isPlainObject(entry.report.scorecard)) {
      failures.push("alternates_decision: ok status requires branch scorecard");
      failures.push("alternates_decision: branch scorecard must prove one-at-a-time sequencing");
      failures.push("alternates_decision: ok status requires branch scorecard to be net positive");
      failures.push("alternates_decision: branch scorecard must match comparison rows");
    } else if (Array.isArray(entry.report.comparisons)) {
      if (entry.report.scorecard.testedOneAtATime !== true) {
        failures.push("alternates_decision: branch scorecard must prove one-at-a-time sequencing");
      }
      if (entry.report.scorecard.netPositive !== true) {
        failures.push("alternates_decision: ok status requires branch scorecard to be net positive");
      }
      if (!alternatesScorecardMatches(entry.report.comparisons, entry.report.scorecard)) {
        failures.push("alternates_decision: branch scorecard must match comparison rows");
      }
    }
    if (!Array.isArray(entry.report.roundLedger)) {
      failures.push("alternates_decision: ok status requires branch round ledger");
      failures.push("alternates_decision: branch round ledger must match comparison rows");
    } else if (Array.isArray(entry.report.comparisons) && !alternatesRoundLedgerMatches(entry.report.comparisons, entry.report.roundLedger)) {
      failures.push("alternates_decision: branch round ledger must match comparison rows");
    }
    if (!isPlainObject(entry.report.identityControls)) {
      failures.push("alternates_decision: ok status requires same-binary identity control evidence");
    }
    if (Array.isArray(entry.report.requiredGateFailures) && entry.report.requiredGateFailures.length > 0) {
      failures.push("alternates_decision: ok status requires no required gate failure envelope");
    }
    const repeatFailures = alternatesRepeatEvidenceFailures(entry.report.repeatedEvidence);
    if (repeatFailures.length > 0) {
      failures.push(`alternates_decision: repeat stability evidence must be stable (${repeatFailures.join(";")})`);
    }
    if (Array.isArray(entry.report.comparisons)) {
      const candidateRegressions = entry.report.comparisons.filter((comparison) =>
        comparison?.evidenceAuthority === "candidate_vs_baseline" &&
        (comparison?.classification === "regression" || comparison?.regression === true)
      );
      const confirmedCandidateRegressions = candidateRegressions.filter((comparison) =>
        comparison?.regressionConfirmation?.status === "confirmed_window"
      );
      const unconfirmedCandidateRegressions = candidateRegressions.filter((comparison) =>
        comparison?.regressionConfirmation?.status !== "confirmed_window"
      );
      if (unconfirmedCandidateRegressions.some((comparison) =>
        comparison?.regressionConfirmation?.status !== "needs_focused_repeat" ||
        typeof comparison?.regressionConfirmation?.recommendedCommand !== "string" ||
        comparison.regressionConfirmation.recommendedCommand.length === 0
      )) {
        failures.push("alternates_decision: unconfirmed regressions require focused-repeat commands");
      }
      const branchFourCompared = entry.report.comparisons.some((comparison) => Number(comparison?.branchCount) === 4);
      const routeContracts = Array.isArray(entry.report.routeContracts) ? entry.report.routeContracts : [];
      const branchFourRouteContract = routeContracts.find((contract) => contract?.id === "branch_4_no_pcre_handoff");
      if (branchFourCompared && !branchFourRouteContract) {
        failures.push("alternates_decision: branch-4 comparisons require no-PCRE route contract");
      }
      const routeContractBranchCounts = new Set(routeContracts.map((contract) => Number(contract?.branchCount)));
      const missingTeddyContract = entry.report.comparisons.some((comparison) =>
        comparison?.selectorFeatures?.teddyEligibility?.eligible === true &&
        !routeContractBranchCounts.has(Number(comparison?.branchCount))
      );
      if (missingTeddyContract) {
        failures.push("alternates_decision: Teddy-eligible comparisons require route contracts");
      }
      if (branchFourRouteContract) {
        if (branchFourRouteContract.expectedRoute !== "teddy" || branchFourRouteContract.observedRoute !== "teddy") {
          failures.push("alternates_decision: branch-4 route contract requires Teddy route");
        }
        if (branchFourRouteContract.passed !== true) {
          failures.push("alternates_decision: branch-4 route contract must pass");
        }
        const pcreObserved = (branchFourRouteContract.pcreRangeSamples ?? []).some((value) => Number(value) > 0);
        if (pcreObserved) {
          failures.push("alternates_decision: branch-4 route contract forbids PCRE range samples");
        }
      }
      const teddyEligibleContracts = routeContracts.filter((contract) => contract?.id === "teddy_eligible_no_pcre_handoff");
      for (const contract of teddyEligibleContracts) {
        if (contract.expectedRoute !== "teddy" || contract.observedRoute !== "teddy" || contract.passed !== true) {
          failures.push("alternates_decision: Teddy-eligible route contracts require Teddy route");
          break;
        }
        if ((contract.pcreRangeSamples ?? []).some((value) => Number(value) > 0)) {
          failures.push("alternates_decision: Teddy-eligible route contracts forbid PCRE range samples");
          break;
        }
      }
      if (confirmedCandidateRegressions.length > 0) {
        if (!Array.isArray(entry.report.optimizationTargets) || entry.report.optimizationTargets.length !== confirmedCandidateRegressions.length) {
          failures.push("alternates_decision: confirmed candidate regressions require optimization targets");
        } else {
          const targetBranchCounts = new Set(entry.report.optimizationTargets.map((target) => Number(target?.branchCount)));
          for (const comparison of confirmedCandidateRegressions) {
            if (!targetBranchCounts.has(Number(comparison.branchCount))) {
              failures.push("alternates_decision: optimization targets must cover every confirmed candidate regression branch");
              break;
            }
          }
          if (entry.report.optimizationTargets.some((target) => !["wall_share", "parallel_worker_sum", "missing"].includes(target?.candidateRouteElapsedAuthority))) {
            failures.push("alternates_decision: optimization targets require route elapsed authority");
          }
          if (entry.report.optimizationTargets.some((target) => !hasAlternatesExpectedGainScore(target))) {
            failures.push("alternates_decision: optimization targets require non-negative expected gain scoring");
          }
          if (entry.report.optimizationTargets.some((target) => !hasAlternatesExpectedGainInputs(target))) {
            failures.push("alternates_decision: optimization targets require auditable expected gain inputs");
          }
          if (entry.report.optimizationTargets.some((target) => !alternatesExpectedGainFormulaMatches(target))) {
            failures.push("alternates_decision: optimization target scores must match expected gain inputs");
          }
          if (entry.report.optimizationTargets.some((target) =>
            !hasAlternatesProofMetadata(target)
          )) {
            failures.push("alternates_decision: optimization targets require proof command and research basis");
          }
          if (!alternatesExpectedGainSorted(entry.report.optimizationTargets)) {
            failures.push("alternates_decision: optimization targets must be sorted by expected gain score");
          }
          if (!Array.isArray(entry.report.nextMoves) || entry.report.nextMoves.length !== confirmedCandidateRegressions.length) {
            failures.push("alternates_decision: confirmed candidate regressions require actionable next moves");
          } else {
            const moveBranchCounts = new Set(entry.report.nextMoves.map((move) => Number(move?.branchCount)));
            for (const comparison of confirmedCandidateRegressions) {
              if (!moveBranchCounts.has(Number(comparison.branchCount))) {
                failures.push("alternates_decision: next moves must cover every confirmed candidate regression branch");
                break;
              }
            }
            if (entry.report.nextMoves.some((move) =>
              typeof move?.priority !== "string" ||
              typeof move?.mechanism !== "string" ||
              move.mechanism.length === 0 ||
              typeof move?.rationale !== "string" ||
              move.rationale.length === 0
            )) {
              failures.push("alternates_decision: next moves require priority, mechanism, and rationale");
            }
            if (entry.report.nextMoves.some((move) =>
              move?.priority === "packed_simd_prefilter" &&
              move?.rejectedMechanism !== "generic_sparse_aho_corasick_or_scalar_teddy_lite"
            )) {
              failures.push("alternates_decision: packed SIMD next moves must reject scalar Teddy-lite");
            }
            if (entry.report.nextMoves.some((move) => !hasAlternatesExpectedGainScore(move))) {
              failures.push("alternates_decision: next moves require non-negative expected gain scoring");
            }
            if (entry.report.nextMoves.some((move) => !hasAlternatesExpectedGainInputs(move))) {
              failures.push("alternates_decision: next moves require auditable expected gain inputs");
            }
            if (entry.report.nextMoves.some((move) => !alternatesExpectedGainFormulaMatches(move))) {
              failures.push("alternates_decision: next move scores must match expected gain inputs");
            }
            if (entry.report.nextMoves.some((move) =>
              !hasAlternatesProofMetadata(move)
            )) {
              failures.push("alternates_decision: next moves require proof command and research basis");
            }
          }
        }
      }
    }
    if (
      entry.report.hostClean !== true ||
      entry.report.host?.beforeStatus !== "clean" ||
      entry.report.host?.afterStatus !== "clean"
    ) {
      failures.push("alternates_decision: ok status requires a clean benchmark host envelope");
    }
    for (const comparison of entry.report.comparisons ?? []) {
      if (!["same_binary", "different_binary"].includes(comparison?.binaryRelation)) {
        failures.push("alternates_decision: comparisons require binary relation evidence");
      }
      if (!["identity_noise_only", "candidate_vs_baseline"].includes(comparison?.evidenceAuthority)) {
        failures.push("alternates_decision: comparisons require evidence authority");
      }
      if (comparison?.matchParity !== true) {
        failures.push("alternates_decision: baseline comparisons require match-count parity");
      }
      if (!isPlainObject(comparison?.selectorFeatures)) {
        failures.push("alternates_decision: comparisons require selector feature evidence");
      } else if (!isPlainObject(comparison.selectorFeatures.teddyEligibility)) {
        failures.push("alternates_decision: selector features require teddy eligibility evidence");
      }
      if (
        typeof comparison?.candidateVsBaselineRatio !== "number" ||
        !Number.isFinite(comparison.candidateVsBaselineRatio)
      ) {
        failures.push("alternates_decision: comparisons require candidate-vs-baseline ratio");
      }
      if (
        !isPlainObject(comparison?.pairedEngine) ||
        !Number.isFinite(Number(comparison.pairedEngine.count)) ||
        !Number.isFinite(Number(comparison.pairedEngine.candidateWinRate))
      ) {
        failures.push("alternates_decision: comparisons require paired engine evidence");
      } else if (
        comparison?.evidenceAuthority === "candidate_vs_baseline" &&
        Number(comparison.pairedEngine.candidateWinRate) <= 0.5
      ) {
        failures.push("alternates_decision: candidate comparisons require paired win majority");
      }
      if (!pairOrderSummaryIsBalanced(comparison?.pairOrderSummary, comparison?.pairedEngine?.count ?? entry.report.samples)) {
        failures.push("alternates_decision: comparisons require balanced alternating pair order");
      }
      if (!isPlainObject(comparison?.score) || comparison.score.testedOneAtATime !== true) {
        failures.push("alternates_decision: comparisons require per-round score evidence");
        if (comparison?.evidenceAuthority === "candidate_vs_baseline") {
          failures.push("alternates_decision: candidate comparison scores must be net positive");
        }
      } else if (comparison?.evidenceAuthority === "candidate_vs_baseline" && comparison.score.netPositive !== true) {
        failures.push("alternates_decision: candidate comparison scores must be net positive");
      }
      if (comparison?.classification === "regression" || comparison?.regression === true) {
        if (comparison?.evidenceAuthority === "identity_noise_only") {
          failures.push("alternates_decision: ok status cannot contain same-binary identity-noise regressions");
        } else {
          const confirmation = comparison?.regressionConfirmation;
          if (confirmation?.status === "needs_focused_repeat") {
            continue;
          }
          failures.push("alternates_decision: ok status cannot contain confirmed candidate regressions");
        }
      }
      const identityControl = entry.report.identityControls?.[String(comparison?.branchCount)];
      if (
        !isPlainObject(identityControl) ||
        !Number.isFinite(Number(identityControl.medianDeltaPct)) ||
        identityControl.matchParity !== true ||
        identityControl.routeParity !== true ||
        !isPlainObject(identityControl.pairedEngine) ||
        !Number.isFinite(Number(identityControl.pairedEngine.candidateWinRate))
      ) {
        failures.push("alternates_decision: comparisons require same-binary identity control evidence");
      } else {
        if (!pairOrderSummaryIsBalanced(identityControl.pairOrderSummary, identityControl.samples)) {
          failures.push("alternates_decision: comparisons require balanced same-binary identity-control pair order");
        }
        if (!identityControlAttemptsComplete(identityControl)) {
          failures.push("alternates_decision: comparisons require full requested same-binary identity-control attempts");
        }
      }
    }
  }

  return { validateAlternatesDecisionLane };
}

export function createAlternatesDecisionGateLane({
  root,
  benchmarkCorpus,
  quick,
  alternatesDecision,
  alternatesDecisionSamples,
  alternatesDecisionMaxBranches,
  alternatesDecisionBranchCounts,
  minRetainableSpeedSamples,
  stateDir,
  run,
  lane,
  benchmarkHostRemediation,
  findBuiltIx,
  sha256File,
  nativeInstallIx,
  nativeInstallDir,
  latestDistinctNativeBackup,
}) {
  function alternatesDecisionLane(hostPreflight = null) {
    const corpus = benchmarkCorpus;
    if (quick) return lane("alternates_decision", "skipped", { reason: "--quick" });
    if (!alternatesDecision) {
      return lane("alternates_decision", "skipped", { reason: "enable with --alternates-decision" });
    }
    if (hostPreflight?.status === "failed") {
      const hostFailures = (hostPreflight.metrics?.hostIssues ?? [])
        .filter((issue) => issue?.severity === "warning")
        .map((issue) => `host:${issue.id}:${issue.detail}`);
      return lane("alternates_decision", "skipped", {
        corpus,
        samples: alternatesDecisionSamples,
        maxBranches: alternatesDecisionMaxBranches,
        branchCounts: alternatesDecisionBranchCounts.length > 0 ? alternatesDecisionBranchCounts : null,
        reason: "benchmark host preflight failed; skipping alternates decision sampling until host envelope is clean",
        requiredGateFailures: hostFailures.length > 0
          ? [
              {
                gate: "alternates_decision",
                reason: "clean benchmark host required before alternates sampling",
                failures: hostFailures,
              },
            ]
          : [],
        remediation: benchmarkHostRemediation(hostPreflight.metrics?.hostIssues ?? [], { corpus, stateDir }),
        hostPreflight: hostPreflight.metrics ?? null,
      });
    }
    if (!existsSync(corpus)) {
      return lane("alternates_decision", "skipped", { reason: "ripgrep benchsuite corpus missing", corpus });
    }
    const ix = findBuiltIx();
    if (!ix) {
      return lane("alternates_decision", "skipped", { reason: "zig-out binary missing; run build first", corpus });
    }
    const repoHash = sha256File(ix);
    const installedHash = existsSync(nativeInstallIx) ? sha256File(nativeInstallIx) : null;
    const backupBaseline = latestDistinctNativeBackup(repoHash);
    const baselineIx = installedHash && installedHash !== repoHash ? nativeInstallIx : backupBaseline?.path;
    if (!baselineIx || !existsSync(baselineIx)) {
      return lane("alternates_decision", "skipped", {
        reason: "distinct alternates baseline missing",
        installed: existsSync(nativeInstallIx) ? nativeInstallIx : null,
        installedHash,
        repoHash,
        backupPattern: path.join(nativeInstallDir, "ix.exe.backup-*"),
      });
    }

    const latestPath = path.join(root, "tools", "reports", "alternates-decision", "latest-alternates-decision.json");
    rmSync(latestPath, { force: true });
    const decisionArgs = [
      "tools/scripts/alternates-decision-table.mjs",
      "--corpus",
      corpus,
      "--ix-binary",
      ix,
      "--baseline-ix",
      baselineIx,
      "--samples",
      String(alternatesDecisionSamples),
      "--max-branches",
      String(alternatesDecisionMaxBranches),
      "--max-regression-pct",
      "0",
      "--quiet",
    ];
    if (alternatesDecisionBranchCounts.length > 0) {
      decisionArgs.push("--branch-counts", alternatesDecisionBranchCounts);
    }
    const evidence = run(process.execPath, decisionArgs);
    if (!existsSync(latestPath)) {
      return lane("alternates_decision", "failed", {
        corpus,
        samples: alternatesDecisionSamples,
        evidence,
        reason: "alternates decision table did not write latest-alternates-decision.json",
      });
    }

    const latest = JSON.parse(readFileSync(latestPath, "utf8"));
    const parsed = {
      runId: latest.runId ?? null,
      samples: latest.samples ?? null,
      branchCounts: Array.isArray(latest.branchCounts) ? latest.branchCounts : null,
      branchCountsArg: latest.branchCountsArg ?? null,
      caseInsensitive: latest.caseInsensitive === true,
      candidate: latest.ixBinary ?? null,
      baseline: latest.baselineIxBinary ?? null,
      binaryHashes: latest.binaryHashes ?? null,
      host: {
        beforeStatus: latest.host?.before?.benchmarkEnvironment?.status ?? null,
        afterStatus: latest.host?.after?.benchmarkEnvironment?.status ?? null,
        beforeIssues: latest.host?.before?.benchmarkEnvironment?.issues ?? [],
        afterIssues: latest.host?.after?.benchmarkEnvironment?.issues ?? [],
      },
      hostClean:
        latest.host?.before?.benchmarkEnvironment?.status === "clean" &&
        latest.host?.after?.benchmarkEnvironment?.status === "clean",
      lanes: Array.isArray(latest.lanes)
        ? latest.lanes.map((entry) => ({
            branchCount: entry.branchCount ?? null,
            expression: entry.expression ?? null,
            selectorFeatures: entry.selectorFeatures ?? null,
            engineMedianMs: entry.engineSummary?.median ?? null,
            pcreRanges: entry.counters?.alternatePcreRangeCalls ?? [],
            pcreElapsedNsTotal: entry.counters?.alternatePcreRangeElapsedNsTotal ?? [],
            pcreElapsedNsMax: entry.counters?.alternatePcreRangeElapsedNsMax ?? [],
            compiledRanges: entry.counters?.alternateCompiledRangeCalls ?? [],
            compiledElapsedNsTotal: entry.counters?.alternateCompiledRangeElapsedNsTotal ?? [],
            compiledElapsedNsMax: entry.counters?.alternateCompiledRangeElapsedNsMax ?? [],
            teddyRanges: entry.counters?.alternateTeddyRangeCalls ?? [],
            teddyElapsedNsTotal: entry.counters?.alternateTeddyRangeElapsedNsTotal ?? [],
            teddyElapsedNsMax: entry.counters?.alternateTeddyRangeElapsedNsMax ?? [],
          }))
        : [],
      comparisons: Array.isArray(latest.comparisons) ? latest.comparisons : [],
      comparisonSummary: latest.comparisonSummary ?? null,
      scorecard: isPlainObject(latest.scorecard) ? latest.scorecard : null,
      roundLedger: Array.isArray(latest.roundLedger) ? latest.roundLedger : null,
      routeContracts: Array.isArray(latest.routeContracts) ? latest.routeContracts : [],
      optimizationTargets: Array.isArray(latest.optimizationTargets) ? latest.optimizationTargets : [],
      nextMoves: Array.isArray(latest.nextMoves) ? latest.nextMoves : [],
      requiredGateFailures: latest.requiredGateFailures ?? [],
      repeatedEvidence: latest.repeatedEvidence ?? null,
      identityControls: latest.identityControls ?? null,
    };
    const laneFailures = [];
    if (evidence.exitCode !== 0) laneFailures.push("alternates decision script failed");
    if (Number(parsed.samples) !== Number(alternatesDecisionSamples)) {
      laneFailures.push("alternates decision sample count mismatch");
    }
    if (Number(parsed.samples) < minRetainableSpeedSamples) {
      laneFailures.push(`alternates decision requires at least ${minRetainableSpeedSamples} samples`);
    }
    const requestedBranchCounts = parseIntegerList(alternatesDecisionBranchCounts);
    if (requestedBranchCounts.length > 0 && !integerListsEqual(parsed.branchCounts, requestedBranchCounts)) {
      laneFailures.push("alternates decision branch-count selection mismatch");
    }
    if (parsed.hostClean !== true) {
      laneFailures.push("alternates decision requires a clean benchmark host envelope");
    }
    if (Array.isArray(parsed.requiredGateFailures) && parsed.requiredGateFailures.length > 0) {
      laneFailures.push("alternates decision has required gate failures");
    }
    const repeatFailures = alternatesRepeatEvidenceFailures(parsed.repeatedEvidence);
    if (repeatFailures.length > 0) {
      laneFailures.push(`alternates decision repeat stability evidence must be stable (${repeatFailures.join(";")})`);
    }
    if (!isPlainObject(parsed.scorecard)) {
      laneFailures.push("alternates decision requires branch scorecard");
    } else {
      if (parsed.scorecard.testedOneAtATime !== true) {
        laneFailures.push("alternates decision scorecard must prove one-at-a-time sequencing");
      }
      if (parsed.scorecard.netPositive !== true) {
        laneFailures.push("alternates decision scorecard must be net positive");
      }
      if (!alternatesScorecardMatches(parsed.comparisons, parsed.scorecard)) {
        laneFailures.push("alternates decision scorecard mismatch");
      }
    }
    if (!Array.isArray(parsed.roundLedger)) {
      laneFailures.push("alternates decision requires branch round ledger");
    } else if (!alternatesRoundLedgerMatches(parsed.comparisons, parsed.roundLedger)) {
      laneFailures.push("alternates decision round ledger mismatch");
    }
    if (!isPlainObject(parsed.identityControls)) {
      laneFailures.push("alternates decision requires same-binary identity control evidence");
    }
    if (parsed.comparisons.some((comparison) => comparison?.matchParity !== true)) {
      laneFailures.push("alternates decision baseline match parity failed");
    }
    if (parsed.comparisons.some((comparison) => !isPlainObject(comparison?.score) || comparison.score.testedOneAtATime !== true)) {
      laneFailures.push("alternates decision comparisons require per-round score evidence");
    }
    if (parsed.comparisons.some((comparison) =>
      comparison?.evidenceAuthority === "candidate_vs_baseline" &&
      comparison?.score?.netPositive !== true
    )) {
      laneFailures.push("alternates decision candidate comparison scores must be net positive");
    }
    if (parsed.comparisons.some((comparison) => {
      const identityControl = parsed.identityControls?.[String(comparison?.branchCount)];
      return (
        !isPlainObject(identityControl) ||
        !Number.isFinite(Number(identityControl.medianDeltaPct)) ||
        identityControl.matchParity !== true ||
        identityControl.routeParity !== true ||
        !isPlainObject(identityControl.pairedEngine) ||
        !Number.isFinite(Number(identityControl.pairedEngine.candidateWinRate))
      );
    })) {
      laneFailures.push("alternates decision comparisons require same-binary identity control evidence");
    }
    if (parsed.comparisons.some((comparison) =>
      !identityControlAttemptsComplete(parsed.identityControls?.[String(comparison?.branchCount)])
    )) {
      laneFailures.push("alternates decision comparisons require full requested same-binary identity-control attempts");
    }
    if (parsed.comparisons.some((comparison) =>
      (comparison?.classification === "regression" || comparison?.regression === true) &&
      comparison?.evidenceAuthority === "identity_noise_only"
    )) {
      laneFailures.push("alternates decision contains same-binary identity-noise regressions");
    }
    if (parsed.comparisons.some((comparison) =>
      (comparison?.classification === "regression" || comparison?.regression === true) &&
      comparison?.evidenceAuthority !== "identity_noise_only"
    )) {
      laneFailures.push("alternates decision contains candidate regressions");
    }
    const branchFourCompared = parsed.comparisons.some((comparison) => Number(comparison?.branchCount) === 4);
    const branchFourRouteContract = parsed.routeContracts.find((contract) => contract?.id === "branch_4_no_pcre_handoff");
    if (branchFourCompared && !branchFourRouteContract) {
      laneFailures.push("alternates decision branch-4 comparisons require no-PCRE route contract");
    }
    const routeContractBranchCounts = new Set(parsed.routeContracts.map((contract) => Number(contract?.branchCount)));
    if (parsed.comparisons.some((comparison) =>
      comparison?.selectorFeatures?.teddyEligibility?.eligible === true &&
      !routeContractBranchCounts.has(Number(comparison?.branchCount))
    )) {
      laneFailures.push("alternates decision Teddy-eligible comparisons require route contracts");
    }
    if (branchFourRouteContract) {
      if (branchFourRouteContract.expectedRoute !== "teddy" || branchFourRouteContract.observedRoute !== "teddy") {
        laneFailures.push("alternates decision branch-4 route contract requires Teddy route");
      }
      if (branchFourRouteContract.passed !== true) {
        laneFailures.push("alternates decision branch-4 route contract must pass");
      }
      if ((branchFourRouteContract.pcreRangeSamples ?? []).some((value) => Number(value) > 0)) {
        laneFailures.push("alternates decision branch-4 route contract forbids PCRE range samples");
      }
    }
    for (const contract of parsed.routeContracts.filter((entry) => entry?.id === "teddy_eligible_no_pcre_handoff")) {
      if (contract.expectedRoute !== "teddy" || contract.observedRoute !== "teddy" || contract.passed !== true) {
        laneFailures.push("alternates decision Teddy-eligible route contract requires Teddy route");
        break;
      }
      if ((contract.pcreRangeSamples ?? []).some((value) => Number(value) > 0)) {
        laneFailures.push("alternates decision Teddy-eligible route contract forbids PCRE range samples");
        break;
      }
    }
    const candidateRegressions = parsed.comparisons.filter((comparison) =>
      (comparison?.classification === "regression" || comparison?.regression === true) &&
      comparison?.evidenceAuthority !== "identity_noise_only"
    );
    const confirmedCandidateRegressions = candidateRegressions.filter((comparison) =>
      comparison?.regressionConfirmation?.status === "confirmed_window"
    );
    const unconfirmedCandidateRegressions = candidateRegressions.filter((comparison) =>
      comparison?.regressionConfirmation?.status !== "confirmed_window"
    );
    if (unconfirmedCandidateRegressions.some((comparison) =>
      comparison?.regressionConfirmation?.status !== "needs_focused_repeat" ||
      typeof comparison?.regressionConfirmation?.recommendedCommand !== "string" ||
      comparison.regressionConfirmation.recommendedCommand.length === 0
    )) {
      laneFailures.push("alternates decision unconfirmed regressions require focused-repeat commands");
    }
    if (confirmedCandidateRegressions.length > 0) {
      const targetBranchCounts = new Set(parsed.optimizationTargets.map((target) => Number(target?.branchCount)));
      const nextMoveBranchCounts = new Set(parsed.nextMoves.map((move) => Number(move?.branchCount)));
      if (parsed.optimizationTargets.length !== confirmedCandidateRegressions.length) {
        laneFailures.push("alternates decision confirmed candidate regressions require optimization targets");
      } else if (confirmedCandidateRegressions.some((comparison) => !targetBranchCounts.has(Number(comparison.branchCount)))) {
        laneFailures.push("alternates decision optimization targets are incomplete");
      }
      if (parsed.optimizationTargets.some((target) => !hasAlternatesExpectedGainScore(target))) {
        laneFailures.push("alternates decision optimization targets require non-negative expected gain scoring");
      }
      if (parsed.optimizationTargets.some((target) => !hasAlternatesExpectedGainInputs(target))) {
        laneFailures.push("alternates decision optimization targets require auditable expected gain inputs");
      }
      if (parsed.optimizationTargets.some((target) => !alternatesExpectedGainFormulaMatches(target))) {
        laneFailures.push("alternates decision optimization target scores must match expected gain inputs");
      }
      if (parsed.optimizationTargets.some((target) => !hasAlternatesProofMetadata(target))) {
        laneFailures.push("alternates decision optimization targets require proof command and research basis");
      }
      if (!alternatesExpectedGainSorted(parsed.optimizationTargets)) {
        laneFailures.push("alternates decision optimization targets must be sorted by expected gain score");
      }
      if (parsed.nextMoves.length !== confirmedCandidateRegressions.length) {
        laneFailures.push("alternates decision confirmed candidate regressions require actionable next moves");
      } else if (confirmedCandidateRegressions.some((comparison) => !nextMoveBranchCounts.has(Number(comparison.branchCount)))) {
        laneFailures.push("alternates decision next moves are incomplete");
      }
      if (parsed.nextMoves.some((move) => !hasAlternatesExpectedGainScore(move))) {
        laneFailures.push("alternates decision next moves require non-negative expected gain scoring");
      }
      if (parsed.nextMoves.some((move) => !hasAlternatesExpectedGainInputs(move))) {
        laneFailures.push("alternates decision next moves require auditable expected gain inputs");
      }
      if (parsed.nextMoves.some((move) => !alternatesExpectedGainFormulaMatches(move))) {
        laneFailures.push("alternates decision next move scores must match expected gain inputs");
      }
      if (parsed.nextMoves.some((move) => !hasAlternatesProofMetadata(move))) {
        laneFailures.push("alternates decision next moves require proof command and research basis");
      }
    }
    if (isPlainObject(parsed.comparisonSummary) && Array.isArray(parsed.comparisons)) {
      const expectedSummary = summarizeAlternatesComparisons(parsed.comparisons);
      if (!alternatesComparisonSummaryMatches(parsed.comparisonSummary, expectedSummary)) {
        laneFailures.push("alternates decision comparison summary mismatch");
      }
    }
    return lane("alternates_decision", evidence.exitCode === 0 && laneFailures.length === 0 ? "ok" : "failed", {
      corpus,
      samples: alternatesDecisionSamples,
      maxBranches: alternatesDecisionMaxBranches,
      branchCounts: alternatesDecisionBranchCounts.length > 0 ? alternatesDecisionBranchCounts : null,
      baseline: {
        path: baselineIx,
        source: baselineIx === nativeInstallIx ? "installed" : "latest_distinct_backup",
        repoHash,
        installedHash,
        baselineHash: sha256File(baselineIx),
      },
      evidence,
      report: parsed,
      failures: laneFailures,
      reason:
        evidence.exitCode !== 0
          ? "alternates decision script failed"
          : laneFailures.length > 0
            ? "alternates decision evidence gate failed"
            : undefined,
    });
  }

  return { alternatesDecisionLane };
}
