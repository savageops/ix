import {
  buildHistoricalComparisonScore,
  buildHistoricalRoundLedger,
  buildHistoricalScorecard,
  buildInstalledComparisonScore,
  buildInstalledRoundLedger,
  buildInstalledScorecard,
  buildRoundLedgerSummary,
  pairOrderSummaryIsBalanced,
  phaseLeakSummaryFromRounds,
  roundLedgerMatchesExpected,
  scorecardMatchesExpected,
} from "./speed-compare-utils.mjs";

function isPlainObject(value) {
  return value !== null && typeof value === "object" && !Array.isArray(value);
}

function scoreMatchesExpected(actual, expected) {
  return JSON.stringify(actual) === JSON.stringify(expected);
}

function comparatorStateReportsClean(reports) {
  if (!Array.isArray(reports)) return false;
  const labels = new Set(reports.map((entry) => entry?.label));
  if (!labels.has("default_state") || !labels.has("benchmark_state")) return false;
  return reports.every((entry) => {
    if (!isPlainObject(entry) || entry.ok !== true || entry.skipped === true) return false;
    if (Array.isArray(entry.failures) && entry.failures.length > 0) return false;
    const report = entry.report;
    if (!isPlainObject(report)) return false;
    return (
      Number(report.live) === 0 &&
      Number(report.stale) === 0 &&
      Number(report.malformed) === 0 &&
      Number(report.warnings) === 0
    );
  });
}

function identityControlAttemptsComplete(identityControl) {
  const attemptsRequested = Number(identityControl?.attemptsRequested);
  const attemptsRun = Number(identityControl?.attemptsRun);
  return Number.isFinite(attemptsRequested) &&
    Number.isFinite(attemptsRun) &&
    attemptsRun >= attemptsRequested;
}

export function createSpeedGateValidation({
  minInstalledImprovementPct,
  minPreviousBuildImprovementPct,
  minRetainableSpeedSamples,
  validateHostPreflightSkipRemediation,
}) {
  function installedComparisonImprovementPct(comparison) {
    if (Number.isFinite(Number(comparison?.installedEngineDeltaPct))) {
      return Number(comparison.installedEngineDeltaPct);
    }
    if (
      Number.isFinite(Number(comparison?.installedEngineMedianMs)) &&
      Number(comparison.installedEngineMedianMs) !== 0 &&
      Number.isFinite(Number(comparison?.repoEngineMedianMs))
    ) {
      return ((Number(comparison.installedEngineMedianMs) - Number(comparison.repoEngineMedianMs)) / Number(comparison.installedEngineMedianMs)) * 100;
    }
    return Number(comparison?.score?.repoEngineImprovementPct);
  }

  function installedComparisonRawScore(comparison, hashesMatch) {
    if (!isPlainObject(comparison)) return null;
    const binaryRelation = hashesMatch === true ? "same_binary" : "different_binary";
    return buildInstalledComparisonScore({
      comparison,
      binaryRelation,
      improvementPct: installedComparisonImprovementPct(comparison),
      pairedEngine: comparison.pairedEngine,
      minInstalledImprovementPct: Number(
        comparison?.effectiveInstalledImprovementPct ??
          comparison?.minInstalledImprovementPct ??
          minInstalledImprovementPct,
      ),
    });
  }

  function installedComparisonWithRawScore(comparison, hashesMatch) {
    const score = installedComparisonRawScore(comparison, hashesMatch);
    return score == null ? null : { ...comparison, score };
  }

  function installedScoreMatchesRaw(comparison, hashesMatch) {
    if (!isPlainObject(comparison) || !isPlainObject(comparison.score)) return false;
    const expected = installedComparisonRawScore(comparison, hashesMatch);
    return expected != null && scoreMatchesExpected(comparison.score, expected);
  }

  function installedScorecardMatches(comparison, scorecard, hashesMatch) {
    if (!isPlainObject(comparison) || !isPlainObject(scorecard)) return false;
    const comparisonWithRawScore = installedComparisonWithRawScore(comparison, hashesMatch);
    if (!comparisonWithRawScore) return false;
    const expected = buildInstalledScorecard({
      score: comparisonWithRawScore.score,
      binaryRelation: hashesMatch === true ? "same_binary" : "different_binary",
    });
    return scorecardMatchesExpected(scorecard, expected);
  }

  function installedRoundLedgerMatches(comparison, roundLedger, hashesMatch, binaries) {
    if (!isPlainObject(comparison) || !Array.isArray(roundLedger)) return false;
    const comparisonWithRawScore = installedComparisonWithRawScore(comparison, hashesMatch);
    if (!comparisonWithRawScore) return false;
    const expected = buildInstalledRoundLedger({
      comparison: comparisonWithRawScore,
      score: comparisonWithRawScore.score,
      binaryRelation: hashesMatch === true ? "same_binary" : "different_binary",
      binaries,
    });
    return roundLedgerMatchesExpected(roundLedger, expected);
  }

  function historicalComparisonRawScore(comparison, index = 0) {
    if (!isPlainObject(comparison)) return null;
    return buildHistoricalComparisonScore({
      roundIndex: Number.isInteger(Number(comparison.roundIndex)) ? Number(comparison.roundIndex) : index + 1,
      baselineLabel: comparison.label ?? comparison.score?.baselineLabel,
      sameBinary: comparison.relation === "same_binary",
      improvementPct: Number(comparison.currentEngineImprovementPct),
      ratio: Number(comparison.currentVsHistoryEngineRatio),
      deltaMs: Number(comparison.currentEngineDeltaMs),
      pairedEngine: comparison.pairedEngine,
      minPreviousBuildImprovementPct: Number(
        comparison.effectivePreviousBuildImprovementPct ??
          comparison.minPreviousBuildImprovementPct ??
          comparison.score?.requiredImprovementPct,
      ),
      matchParity: comparison.matchParity,
      routeParity: comparison.routeParity,
      pairOrderSummary: comparison.pairOrderSummary ?? comparison.pairedEngine?.pairOrderSummary,
      historyEngineMedianMs: Number(comparison.historyEngineMedianMs ?? comparison.historical?.engineSummary?.median),
      currentEngineMedianMs: Number(comparison.currentEngineMedianMs ?? comparison.current?.engineSummary?.median),
    });
  }

  function historicalComparisonsWithRawScores(comparisons) {
    if (!Array.isArray(comparisons)) return null;
    return comparisons.map((comparison, index) => {
      const score = historicalComparisonRawScore(comparison, index);
      return score == null ? comparison : { ...comparison, score };
    });
  }

  function historicalScoreMatchesRaw(comparison, index = 0) {
    if (!isPlainObject(comparison) || !isPlainObject(comparison.score)) return false;
    const expected = historicalComparisonRawScore(comparison, index);
    return expected != null && scoreMatchesExpected(comparison.score, expected);
  }

  function historicalScorecardMatches(comparisons, scorecard) {
    if (!Array.isArray(comparisons) || !isPlainObject(scorecard)) return false;
    const comparisonsWithRawScores = historicalComparisonsWithRawScores(comparisons);
    const expected = buildHistoricalScorecard(comparisonsWithRawScores);
    return scorecardMatchesExpected(scorecard, expected);
  }

  function historicalRoundLedgerMatches(comparisons, roundLedger) {
    if (!Array.isArray(comparisons) || !Array.isArray(roundLedger)) return false;
    const comparisonsWithRawScores = historicalComparisonsWithRawScores(comparisons);
    const expected = buildHistoricalRoundLedger(comparisonsWithRawScores);
    return roundLedgerMatchesExpected(roundLedger, expected);
  }

  function historicalPhaseLeakSummaryMatches(roundLedger, phaseLeakSummary) {
    if (!Array.isArray(roundLedger) || !isPlainObject(phaseLeakSummary)) return false;
    return JSON.stringify(phaseLeakSummary) === JSON.stringify(phaseLeakSummaryFromRounds(roundLedger));
  }

  function ledgerSummaryMatches(roundLedger, ledgerSummary) {
    if (!Array.isArray(roundLedger) || !isPlainObject(ledgerSummary)) return false;
    return JSON.stringify(ledgerSummary) === JSON.stringify(buildRoundLedgerSummary(roundLedger));
  }

  function validateInstalledSpeedLane(entry, failures) {
    if (entry.id !== "installed_speed_compare") return;
    validateHostPreflightSkipRemediation(
      entry,
      failures,
      "installed_speed_compare",
      "benchmark host preflight failed; skipping speed comparison until host envelope is clean",
    );
    if (entry.status !== "ok") return;
    if (!isPlainObject(entry.report)) {
      failures.push("installed_speed_compare: ok status requires parsed comparator report");
      return;
    }
    if (entry.strictRequired === true && entry.report.retainableStrictEvidence !== true) {
      failures.push("installed_speed_compare: strict ok status requires retainable strict evidence");
    }
    if (entry.strictRequired === true && Number(entry.report.samples) < minRetainableSpeedSamples) {
      failures.push("installed_speed_compare: strict ok status requires the retained sample floor");
    }
    if (entry.strictRequired === true && entry.report.hashesMatch !== true && entry.report.promotionQualified !== true) {
      failures.push("installed_speed_compare: strict ok status requires repo promotion over installed");
    }
    if (entry.strictRequired === true && Array.isArray(entry.report.requiredGateFailures) && entry.report.requiredGateFailures.length > 0) {
      failures.push("installed_speed_compare: strict ok status requires no required gate failure envelope");
    }
    if (Number(entry.report.samples) !== Number(entry.samples)) {
      failures.push("installed_speed_compare: ok status requires parsed sample count to match requested samples");
    }
    const binaries = entry.report.binaries;
    if (
      !isPlainObject(binaries) ||
      typeof binaries.installed?.sha256 !== "string" ||
      binaries.installed.sha256.length === 0 ||
      typeof binaries.repo?.sha256 !== "string" ||
      binaries.repo.sha256.length === 0
    ) {
      failures.push("installed_speed_compare: ok status requires installed and repo binary hash evidence");
    }
    const processScan = entry.report.processScan;
    if (
      !isPlainObject(processScan) ||
      processScan.beforeOk !== true ||
      processScan.afterOk !== true ||
      processScan.beforeMatched !== 0 ||
      processScan.afterMatched !== 0
    ) {
      failures.push("installed_speed_compare: ok status requires clean after-run IX process scan");
    }
    if (
      !isPlainObject(processScan) ||
      (Array.isArray(processScan.beforeFailures) && processScan.beforeFailures.length > 0) ||
      (Array.isArray(processScan.afterFailures) && processScan.afterFailures.length > 0) ||
      !comparatorStateReportsClean(processScan.beforeStateReports) ||
      !comparatorStateReportsClean(processScan.afterStateReports)
    ) {
      failures.push("installed_speed_compare: ok status requires clean comparator process state reports");
    }
    const medians = entry.report.medians;
    if (!isPlainObject(medians) || !Number.isFinite(Number(medians.ripgrepCliMs)) || !Number.isFinite(Number(medians.repoCliMs))) {
      failures.push("installed_speed_compare: ok status requires ripgrep and repo median timings");
    }
    const identityControl = entry.report.identityControl;
    if (
      !isPlainObject(identityControl) ||
      !Number.isFinite(Number(identityControl.medianDeltaPct)) ||
      identityControl.matchParity !== true ||
      identityControl.routeParity !== true
    ) {
      failures.push("installed_speed_compare: ok status requires same-binary identity control evidence");
    } else {
      if (!pairOrderSummaryIsBalanced(identityControl.pairOrderSummary, identityControl.samples)) {
        failures.push("installed_speed_compare: ok status requires balanced same-binary identity-control pair order");
      }
      if (!identityControlAttemptsComplete(identityControl)) {
        failures.push("installed_speed_compare: ok status requires full requested same-binary identity-control attempts");
      }
    }
    const comparison = entry.report.installedRepoComparison;
    if (!isPlainObject(comparison)) {
      failures.push("installed_speed_compare: ok status requires installed-vs-repo comparison evidence");
    } else {
      if (entry.report.hashesMatch === true && entry.report.promotionMode !== "current_install_identity") {
        failures.push("installed_speed_compare: same-binary comparison must declare current_install_identity mode");
      }
      if (entry.report.hashesMatch !== true && entry.report.promotionMode !== "candidate_vs_installed") {
        failures.push("installed_speed_compare: distinct-binary comparison must declare candidate_vs_installed mode");
      }
      if (entry.report.hashesMatch === true && comparison.evidenceAuthority !== "identity_noise_only") {
        failures.push("installed_speed_compare: same-binary comparison must be identity-noise only");
      }
      if (entry.report.hashesMatch !== true && comparison.evidenceAuthority !== "installed_vs_repo") {
        failures.push("installed_speed_compare: distinct-binary comparison must use installed_vs_repo evidence");
      }
      if (!isPlainObject(comparison.score)) {
        failures.push("installed_speed_compare: installed-vs-repo comparison requires explicit score");
      } else {
        if (!Number.isInteger(Number(comparison.score.roundIndex)) || Number(comparison.score.roundIndex) < 1) {
          failures.push("installed_speed_compare: installed-vs-repo score requires a positive round index");
        }
        if (comparison.score.testedOneAtATime !== true) {
          failures.push("installed_speed_compare: installed-vs-repo score must prove one-at-a-time sequencing");
        }
        if (entry.report.hashesMatch !== true && entry.strictRequired === true && comparison.score.netPositive !== true) {
          failures.push("installed_speed_compare: strict ok status requires installed-vs-repo score to be net positive");
        }
        if (
          entry.report.hashesMatch !== true &&
          Number(comparison.score.requiredImprovementPct) !==
            Number(entry.report.effectiveInstalledImprovementPct ?? entry.report.minInstalledImprovementPct ?? minInstalledImprovementPct)
        ) {
          failures.push("installed_speed_compare: installed-vs-repo score must carry the configured installed improvement target");
        }
        if (!installedScoreMatchesRaw(comparison, entry.report.hashesMatch === true)) {
          failures.push("installed_speed_compare: installed-vs-repo score must match raw comparison evidence");
        }
      }
      if (comparison.matchParity !== true) {
        failures.push("installed_speed_compare: installed and repo lanes require match-count parity");
      }
      if (comparison.routeParity !== true) {
        failures.push("installed_speed_compare: installed and repo lanes require alternate-route parity");
      }
      if (entry.report.hashesMatch !== true) {
        const candidateWinRate = Number(comparison.pairedEngine?.candidateWinRate);
        if (!Number.isFinite(candidateWinRate) || candidateWinRate <= 0.5) {
          failures.push("installed_speed_compare: repo comparison requires paired win majority");
        }
      }
      if (!pairOrderSummaryIsBalanced(comparison.pairOrderSummary, comparison.pairedEngine?.count ?? entry.report.samples)) {
        failures.push("installed_speed_compare: installed-vs-repo comparison requires balanced alternating pair order");
      }
    }
    const scorecard = entry.report.scorecard;
    if (entry.strictRequired === true) {
      if (!isPlainObject(scorecard)) {
        failures.push("installed_speed_compare: strict ok status requires installed-vs-repo scorecard");
      } else {
        if (scorecard.testedOneAtATime !== true) {
          failures.push("installed_speed_compare: installed-vs-repo scorecard must prove one-at-a-time sequencing");
        }
        if (entry.report.hashesMatch !== true && scorecard.netPositive !== true) {
          failures.push("installed_speed_compare: strict ok status requires installed-vs-repo scorecard to be net positive");
        }
        if (!installedScorecardMatches(comparison, scorecard, entry.report.hashesMatch === true)) {
          failures.push("installed_speed_compare: installed-vs-repo scorecard must match comparison score");
        }
      }
    }
    const roundLedger = entry.report.roundLedger;
    if (entry.strictRequired === true) {
      if (!Array.isArray(roundLedger)) {
        failures.push("installed_speed_compare: strict ok status requires installed-vs-repo round ledger");
      } else if (!installedRoundLedgerMatches(comparison, roundLedger, entry.report.hashesMatch === true, binaries)) {
        failures.push("installed_speed_compare: installed-vs-repo round ledger must match comparison score");
      }
      if (!isPlainObject(entry.report.ledgerSummary)) {
        failures.push("installed_speed_compare: strict ok status requires installed-vs-repo ledger summary");
      }
    }
    if (
      isPlainObject(entry.report.ledgerSummary) &&
      !ledgerSummaryMatches(roundLedger, entry.report.ledgerSummary)
    ) {
      failures.push("installed_speed_compare: installed-vs-repo ledger summary must match round ledger");
    }
  }

  function validateHistoricalSpeedLane(entry, failures) {
    if (entry.id !== "historical_speed_compare") return;
    validateHostPreflightSkipRemediation(
      entry,
      failures,
      "historical_speed_compare",
      "benchmark host preflight failed; skipping speed comparison until host envelope is clean",
    );
    if (entry.status !== "ok") return;
    if (!isPlainObject(entry.report)) {
      failures.push("historical_speed_compare: ok status requires parsed comparator report");
      return;
    }
    if (Number(entry.report.samples) !== Number(entry.samples)) {
      failures.push("historical_speed_compare: ok status requires parsed sample count to match requested samples");
    }
    if (entry.strictRequired === true && entry.report.retainableStrictEvidence !== true) {
      failures.push("historical_speed_compare: strict ok status requires retainable strict evidence");
    }
    if (entry.strictRequired === true && Number(entry.report.samples) < minRetainableSpeedSamples) {
      failures.push("historical_speed_compare: strict ok status requires the retained sample floor");
    }
    if (entry.strictRequired === true && !Number.isFinite(Number(entry.report.minPreviousBuildImprovementPct))) {
      failures.push("historical_speed_compare: strict ok status requires a configured previous-build improvement target");
    }
    if (entry.strictRequired === true && Array.isArray(entry.report.requiredGateFailures) && entry.report.requiredGateFailures.length > 0) {
      failures.push("historical_speed_compare: strict ok status requires no required gate failure envelope");
    }
    if (entry.strictRequired === true && entry.report.includeCurrentInstall === true) {
      failures.push("historical_speed_compare: strict previous-build comparison must not include current install identity");
    }
    const processScan = entry.report.processScan;
    if (
      !isPlainObject(processScan) ||
      processScan.beforeOk !== true ||
      processScan.afterOk !== true ||
      processScan.beforeMatched !== 0 ||
      processScan.afterMatched !== 0
    ) {
      failures.push("historical_speed_compare: ok status requires clean after-run IX process scan");
    }
    if (
      !isPlainObject(processScan) ||
      (Array.isArray(processScan.beforeFailures) && processScan.beforeFailures.length > 0) ||
      (Array.isArray(processScan.afterFailures) && processScan.afterFailures.length > 0) ||
      !comparatorStateReportsClean(processScan.beforeStateReports) ||
      !comparatorStateReportsClean(processScan.afterStateReports)
    ) {
      failures.push("historical_speed_compare: ok status requires clean comparator process state reports");
    }
    const identityControl = entry.report.identityControl;
    if (
      !isPlainObject(identityControl) ||
      !Number.isFinite(Number(identityControl.medianDeltaPct)) ||
      identityControl.matchParity !== true ||
      identityControl.routeParity !== true
    ) {
      failures.push("historical_speed_compare: ok status requires same-binary identity control evidence");
    } else {
      if (!pairOrderSummaryIsBalanced(identityControl.pairOrderSummary, identityControl.samples)) {
        failures.push("historical_speed_compare: ok status requires balanced same-binary identity-control pair order");
      }
      if (!identityControlAttemptsComplete(identityControl)) {
        failures.push("historical_speed_compare: ok status requires full requested same-binary identity-control attempts");
      }
    }
    if (!Array.isArray(entry.report.comparisons) || entry.report.comparisons.length === 0) {
      failures.push("historical_speed_compare: ok status requires historical comparisons");
      return;
    }
    const previousBuilds = entry.report.comparisons.filter((comparison) => comparison?.evidenceAuthority === "previous_build");
    if (previousBuilds.length === 0) {
      failures.push("historical_speed_compare: ok status requires at least one different-binary previous-build comparison");
    }
    const requiredPreviousBuildImprovementPct = Number(
      entry.report.effectivePreviousBuildImprovementPct ??
        entry.report.minPreviousBuildImprovementPct ??
        minPreviousBuildImprovementPct,
    );
    for (const [comparisonIndex, comparison] of entry.report.comparisons.entries()) {
      if (comparison?.relation === "same_binary" && comparison?.evidenceAuthority !== "identity_noise_only") {
        failures.push("historical_speed_compare: same-binary comparisons must be identity-noise only");
      }
      if (comparison?.evidenceAuthority === "previous_build" && comparison?.matchParity !== true) {
        failures.push("historical_speed_compare: previous-build comparisons require match-count parity");
      }
      if (comparison?.evidenceAuthority === "previous_build" && comparison?.currentRoute?.teddyObserved !== true) {
        failures.push("historical_speed_compare: previous-build comparisons require current Teddy route evidence");
      }
      if (
        comparison?.evidenceAuthority === "previous_build" &&
        (comparison?.currentRoute?.pcreObserved === true || comparison?.currentRoute?.compiledObserved === true)
      ) {
        failures.push("historical_speed_compare: current previous-build lane must not use PCRE or compiled alternates");
      }
      if (
        entry.strictRequired === true &&
        comparison?.evidenceAuthority === "previous_build" &&
        Number.isFinite(Number(comparison.currentVsHistoryEngineRatio)) &&
        Number(comparison.currentVsHistoryEngineRatio) > 1
      ) {
        failures.push("historical_speed_compare: strict ok status requires current engine median no slower than every previous build");
      }
      if (
        entry.strictRequired === true &&
        comparison?.evidenceAuthority === "previous_build" &&
        Number.isFinite(Number(comparison.currentEngineImprovementPct)) &&
        Number(comparison.currentEngineImprovementPct) < requiredPreviousBuildImprovementPct
      ) {
        failures.push("historical_speed_compare: strict ok status requires current engine median to beat every previous build by the configured improvement target");
      }
      const candidateWinRate = Number(comparison?.pairedEngine?.candidateWinRate ?? comparison?.pairedEngine?.currentWinRate);
      if (
        entry.strictRequired === true &&
        comparison?.evidenceAuthority === "previous_build" &&
        (!Number.isFinite(candidateWinRate) || candidateWinRate <= 0.5)
      ) {
        failures.push("historical_speed_compare: strict ok status requires paired win majority over every previous build");
      }
      if (comparison?.evidenceAuthority === "previous_build") {
        if (!pairOrderSummaryIsBalanced(comparison.pairOrderSummary, comparison.pairedEngine?.count ?? entry.report.samples)) {
          failures.push("historical_speed_compare: previous-build comparisons require balanced alternating pair order");
        }
        if (!isPlainObject(comparison.score)) {
          failures.push("historical_speed_compare: previous-build comparisons require explicit round score");
        } else {
          if (!Number.isInteger(Number(comparison.score.roundIndex)) || Number(comparison.score.roundIndex) < 1) {
            failures.push("historical_speed_compare: previous-build round scores require a positive round index");
          }
          if (comparison.score.testedOneAtATime !== true) {
            failures.push("historical_speed_compare: previous-build round scores must prove one-at-a-time sequencing");
          }
          if (entry.strictRequired === true && comparison.score.netPositive !== true) {
            failures.push("historical_speed_compare: strict ok status requires every previous-build round score to be net positive");
          }
          if (
            Number(comparison.score.requiredImprovementPct) !==
            Number(comparison.effectivePreviousBuildImprovementPct ?? requiredPreviousBuildImprovementPct)
          ) {
            failures.push("historical_speed_compare: previous-build round score must carry the effective improvement target");
          }
          if (!historicalScoreMatchesRaw(comparison, comparisonIndex)) {
            failures.push("historical_speed_compare: previous-build round score must match raw comparison evidence");
          }
        }
      }
    }
    const scorecard = entry.report.scorecard;
    if (entry.strictRequired === true) {
      if (!isPlainObject(scorecard)) {
        failures.push("historical_speed_compare: strict ok status requires previous-build scorecard");
      } else {
        if (scorecard.testedOneAtATime !== true) {
          failures.push("historical_speed_compare: previous-build scorecard must prove one-at-a-time sequencing");
        }
        if (scorecard.netPositive !== true) {
          failures.push("historical_speed_compare: strict ok status requires previous-build scorecard to be net positive");
        }
        if (!Array.isArray(scorecard.losingRounds)) {
          failures.push("historical_speed_compare: previous-build scorecard requires losing-round ledger");
        }
        if (!historicalScorecardMatches(entry.report.comparisons, scorecard)) {
          failures.push("historical_speed_compare: previous-build scorecard must match comparison rows");
        }
      }
    }
    const roundLedger = entry.report.roundLedger;
    if (entry.strictRequired === true) {
      if (!Array.isArray(roundLedger)) {
        failures.push("historical_speed_compare: strict ok status requires previous-build round ledger");
      } else if (!historicalRoundLedgerMatches(entry.report.comparisons, roundLedger)) {
        failures.push("historical_speed_compare: previous-build round ledger must match comparison rows");
      }
      if (!isPlainObject(entry.report.ledgerSummary)) {
        failures.push("historical_speed_compare: strict ok status requires previous-build ledger summary");
      }
      if (!isPlainObject(entry.report.phaseLeakSummary)) {
        failures.push("historical_speed_compare: strict ok status requires phase leak summary");
      }
    }
    if (
      isPlainObject(entry.report.ledgerSummary) &&
      !ledgerSummaryMatches(roundLedger, entry.report.ledgerSummary)
    ) {
      failures.push("historical_speed_compare: previous-build ledger summary must match round ledger");
    }
    if (
      isPlainObject(entry.report.phaseLeakSummary) &&
      !historicalPhaseLeakSummaryMatches(roundLedger, entry.report.phaseLeakSummary)
    ) {
      failures.push("historical_speed_compare: phase leak summary must match previous-build round ledger");
    }
    const medians = entry.report.medians;
    if (!isPlainObject(medians) || !Number.isFinite(Number(medians.ripgrepCliMs)) || !Number.isFinite(Number(medians.currentEngineMs))) {
      failures.push("historical_speed_compare: ok status requires ripgrep and current engine median timings");
    }
  }

  function validateOlderSnapshotLane(entry, failures) {
    if (entry.id !== "older_snapshot_ladder") return;
    validateHostPreflightSkipRemediation(
      entry,
      failures,
      "older_snapshot_ladder",
      "benchmark host preflight failed; skipping speed comparison until host envelope is clean",
    );
    if (entry.status !== "ok") return;
    if (!isPlainObject(entry.report)) {
      failures.push("older_snapshot_ladder: ok status requires parsed ladder report");
      return;
    }
    if (Number(entry.report.samples) !== Number(entry.samples)) {
      failures.push("older_snapshot_ladder: ok status requires parsed sample count to match requested samples");
    }
    const retainedSampleFloorMet = Number(entry.report.samples) >= minRetainableSpeedSamples;
    const diagnosticOnly = entry.diagnosticOnly === true;
    if (diagnosticOnly && retainedSampleFloorMet) {
      failures.push("older_snapshot_ladder: diagnostic-only status is only allowed below the retained sample floor");
    }
    if (!diagnosticOnly && entry.report.retainableEvidence !== true) {
      failures.push("older_snapshot_ladder: ok status requires retainable ladder evidence");
    }
    if (!diagnosticOnly && Array.isArray(entry.report.failures) && entry.report.failures.length > 0) {
      failures.push("older_snapshot_ladder: ok status requires an empty failure ledger");
    }
    const failureSummary = entry.report.failureSummary;
    if (!isPlainObject(failureSummary) || !isPlainObject(failureSummary.categories)) {
      failures.push("older_snapshot_ladder: ok status requires categorized failure summary");
    } else {
      const summarizedTotal = Object.values(failureSummary.categories)
        .map(Number)
        .filter(Number.isFinite)
        .reduce((sum, count) => sum + count, 0);
      if (summarizedTotal !== Number(entry.report.rounds?.length ?? 0)) {
        failures.push("older_snapshot_ladder: failure summary categories must account for every round");
      }
      if (!Array.isArray(failureSummary.retainableLabels) || Number(failureSummary.retainableLabels.length) !== Number(entry.report.retainableSnapshots ?? 0)) {
        failures.push("older_snapshot_ladder: failure summary retainable labels must match retainable count");
      }
      if (!Array.isArray(failureSummary.blockedLabels) || !Array.isArray(failureSummary.skippedLabels)) {
        failures.push("older_snapshot_ladder: failure summary requires blocked and skipped label ledgers");
      }
      if (entry.strictRequired === true && Number(entry.report.retainableSnapshots ?? 0) > 0 && !isPlainObject(failureSummary.bestRetainableRound)) {
        failures.push("older_snapshot_ladder: strict retained evidence requires best retainable round summary");
      }
    }
    if (entry.strictRequired === true && entry.report.strictRequired !== true) {
      failures.push("older_snapshot_ladder: strict ok status requires strict comparator mode");
    }
    if (entry.strictRequired === true && Number(entry.report.samples) < minRetainableSpeedSamples) {
      failures.push("older_snapshot_ladder: strict ok status requires the retained sample floor");
    }
    if (entry.strictRequired === true && !Number.isFinite(Number(entry.report.identityControlAttempts))) {
      failures.push("older_snapshot_ladder: strict ok status requires identity-control attempt count");
    }
    if (entry.strictRequired === true && Number(entry.report.identityControlAttempts) < 2) {
      failures.push("older_snapshot_ladder: strict ok status requires multi-attempt identity control");
    }
    if (entry.strictRequired === true && !Number.isFinite(Number(entry.report.minEngineImprovementPct))) {
      failures.push("older_snapshot_ladder: strict ok status requires engine improvement target");
    }
    if (entry.strictRequired === true && !Number.isFinite(Number(entry.report.minPairedImprovementPct))) {
      failures.push("older_snapshot_ladder: strict ok status requires paired improvement target");
    }
    if (!Number.isInteger(Number(entry.report.runnableSnapshots)) || Number(entry.report.runnableSnapshots) < 1) {
      failures.push("older_snapshot_ladder: ok status requires at least one runnable older snapshot");
    }
    if (entry.strictRequired === true && !Number.isInteger(Number(entry.report.retainableSnapshots))) {
      failures.push("older_snapshot_ladder: strict ok status requires retainable snapshot count");
    }
    if (
      entry.strictRequired === true &&
      Number.isInteger(Number(entry.targetRetainableSnapshots)) &&
      Number(entry.report.retainableSnapshots) < Number(entry.targetRetainableSnapshots)
    ) {
      failures.push("older_snapshot_ladder: strict ok status requires requested retainable snapshot count");
    }
    if (!Array.isArray(entry.report.rounds) || entry.report.rounds.length === 0) {
      failures.push("older_snapshot_ladder: ok status requires per-snapshot rounds");
      return;
    }
    const runnableRounds = entry.report.rounds.filter((round) => round?.runnable === true);
    if (runnableRounds.length !== Number(entry.report.runnableSnapshots)) {
      failures.push("older_snapshot_ladder: runnable snapshot count must match runnable rounds");
    }
    for (const round of runnableRounds) {
      if (typeof round.label !== "string" || round.label.length === 0) {
        failures.push("older_snapshot_ladder: runnable rounds require snapshot labels");
      }
      if (entry.strictRequired === true && round.status !== "net_positive") {
        failures.push(`older_snapshot_ladder: strict runnable round must be net_positive: ${round.label ?? "unknown"}`);
      }
      if (!Number.isFinite(Number(round.baselineMedianMs)) || !Number.isFinite(Number(round.repoMedianMs))) {
        failures.push(`older_snapshot_ladder: runnable round requires baseline and repo medians: ${round.label ?? "unknown"}`);
      }
      if (!Number.isFinite(Number(round.enginePct)) || (!diagnosticOnly && Number(round.enginePct) < 0)) {
        failures.push(`older_snapshot_ladder: runnable round requires non-negative engine delta: ${round.label ?? "unknown"}`);
      }
      if (!Number.isFinite(Number(round.pairedPct)) || (!diagnosticOnly && Number(round.pairedPct) < 0)) {
        failures.push(`older_snapshot_ladder: runnable round requires non-negative paired delta: ${round.label ?? "unknown"}`);
      }
      if (!Number.isFinite(Number(round.winRate)) || (!diagnosticOnly && Number(round.winRate) <= 0.5)) {
        failures.push(`older_snapshot_ladder: runnable round requires paired win majority: ${round.label ?? "unknown"}`);
      }
      if (typeof round.sourceReportPath !== "string" || round.sourceReportPath.length === 0) {
        failures.push(`older_snapshot_ladder: runnable round requires source report path: ${round.label ?? "unknown"}`);
      }
      if (!isPlainObject(round.identityControl) || !Number.isFinite(Number(round.identityControl.medianDeltaPct))) {
        failures.push(`older_snapshot_ladder: runnable round requires same-binary noise diagnostics: ${round.label ?? "unknown"}`);
      }
      if (!isPlainObject(round.processScan) || Number(round.processScan.beforeMatched) !== 0 || Number(round.processScan.afterMatched) !== 0) {
        failures.push(`older_snapshot_ladder: runnable round requires clean process diagnostics: ${round.label ?? "unknown"}`);
      }
      if (round.matchParity !== true) {
        failures.push(`older_snapshot_ladder: runnable round requires match parity diagnostics: ${round.label ?? "unknown"}`);
      }
      if (!pairOrderSummaryIsBalanced(round.pairOrderSummary, round.pairedEngine?.count ?? entry.report.samples)) {
        failures.push(`older_snapshot_ladder: runnable round requires balanced pair-order diagnostics: ${round.label ?? "unknown"}`);
      }
      if (entry.strictRequired === true && round.strict !== true) {
        failures.push(`older_snapshot_ladder: strict ok status requires strict evidence for ${round.label ?? "unknown"}`);
      }
    }
    for (const round of entry.report.rounds.filter((item) => item?.runnable !== true)) {
      if (round.status !== "skipped" || typeof round.error !== "string" || round.error.length === 0) {
        failures.push(`older_snapshot_ladder: skipped rounds require status and error evidence: ${round.label ?? "unknown"}`);
      }
    }
  }

  return {
    historicalRoundLedgerMatches,
    historicalScorecardMatches,
    historicalScoreMatchesRaw,
    installedScoreMatchesRaw,
    validateHistoricalSpeedLane,
    validateInstalledSpeedLane,
    validateOlderSnapshotLane,
  };
}
