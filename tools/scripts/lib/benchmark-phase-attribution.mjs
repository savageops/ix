function finiteNumbers(values) {
  return values
    .filter((value) => value != null)
    .map(Number)
    .filter(Number.isFinite);
}

function summary(values) {
  const finite = finiteNumbers(values);
  const sorted = [...finite].sort((left, right) => left - right);
  const mean = finite.reduce((sum, value) => sum + value, 0) / finite.length;
  const variance = finite.reduce((sum, value) => sum + (value - mean) ** 2, 0) / finite.length;
  return {
    count: finite.length,
    min: sorted[0],
    p25: sorted[Math.floor((sorted.length - 1) * 0.25)],
    median: sorted[Math.floor((sorted.length - 1) * 0.5)],
    p75: sorted[Math.floor((sorted.length - 1) * 0.75)],
    max: sorted[sorted.length - 1],
    mean,
    stdev: Math.sqrt(variance),
    range: sorted[sorted.length - 1] - sorted[0],
  };
}

function average(values) {
  const finite = finiteNumbers(values);
  if (finite.length === 0) return null;
  return finite.reduce((sum, value) => sum + value, 0) / finite.length;
}

function optionalNumber(value) {
  if (value == null) return null;
  const number = Number(value);
  return Number.isFinite(number) ? number : null;
}

export function phaseTimingResidualMs(timings, engineMs) {
  const discover = Number(timings?.discover_ms ?? 0);
  const scan = Number(timings?.scan_ms ?? 0);
  const aggregate = Number(timings?.aggregate_ms ?? 0);
  const total = Number(engineMs);
  if (![discover, scan, aggregate, total].every(Number.isFinite)) return null;
  return total - discover - scan - aggregate;
}

const PAIRED_ATTRIBUTION_METRICS = [
  { key: "discover", sampleField: "discoverMs" },
  { key: "scan", sampleField: "scanMs" },
  { key: "aggregate", sampleField: "aggregateMs" },
  { key: "engineResidual", sampleField: "engineResidualMs" },
  { key: "scanWork", sampleField: "scanWorkMsTotal" },
  { key: "scanOpen", sampleField: "scanOpenMsTotal" },
  { key: "scanFile", sampleField: "scanFileMsTotal" },
  { key: "teddyRangeNs", sampleField: "alternateTeddyRangeElapsedNsTotal" },
  { key: "pcreRangeNs", sampleField: "alternatePcreRangeElapsedNsTotal" },
  { key: "compiledRangeNs", sampleField: "alternateCompiledRangeElapsedNsTotal" },
];

function pairedMetricStats(baselineSamples, candidateSamples, count, metric) {
  const pairs = [];
  let candidateWins = 0;
  let baselineWins = 0;
  let ties = 0;
  for (let index = 0; index < count; index += 1) {
    const baseline = optionalNumber(baselineSamples[index]?.[metric.sampleField]);
    const candidate = optionalNumber(candidateSamples[index]?.[metric.sampleField]);
    if (!Number.isFinite(baseline) || !Number.isFinite(candidate)) continue;
    const delta = candidate - baseline;
    const improvementPct = baseline !== 0 ? ((baseline - candidate) / baseline) * 100 : null;
    if (delta < 0) candidateWins += 1;
    else if (delta > 0) baselineWins += 1;
    else ties += 1;
    pairs.push({
      pair: index + 1,
      baseline,
      candidate,
      delta,
      candidateImprovementPct: improvementPct,
    });
  }
  const finiteImprovementPct = pairs
    .map((pair) => pair.candidateImprovementPct)
    .filter(Number.isFinite);
  return {
    count: pairs.length,
    candidateWins,
    baselineWins,
    ties,
    candidateWinRate: pairs.length === 0 ? null : candidateWins / pairs.length,
    deltaSummary: pairs.length === 0 ? null : summary(pairs.map((pair) => pair.delta)),
    candidateImprovementPctSummary: finiteImprovementPct.length === 0 ? null : summary(finiteImprovementPct),
    pairs,
  };
}

export function pairedEngineStats(baselineSamples, candidateSamples, { baselineLabel = "baseline", candidateLabel = "candidate" } = {}) {
  const count = Math.min(baselineSamples.length, candidateSamples.length);
  const pairs = [];
  let candidateWins = 0;
  let baselineWins = 0;
  let ties = 0;
  for (let index = 0; index < count; index += 1) {
    const baseline = baselineSamples[index].engineMs;
    const candidate = candidateSamples[index].engineMs;
    const deltaMs = candidate - baseline;
    const improvementPct = Number.isFinite(baseline) && baseline !== 0 ? ((baseline - candidate) / baseline) * 100 : null;
    if (deltaMs < 0) candidateWins += 1;
    else if (deltaMs > 0) baselineWins += 1;
    else ties += 1;
    pairs.push({
      pair: index + 1,
      [`${baselineLabel}Ms`]: baseline,
      [`${candidateLabel}Ms`]: candidate,
      deltaMs,
      [`${candidateLabel}ImprovementPct`]: improvementPct,
    });
  }

  const finiteImprovementPct = pairs
    .map((pair) => pair[`${candidateLabel}ImprovementPct`])
    .filter(Number.isFinite);
  const attribution = Object.fromEntries(
    PAIRED_ATTRIBUTION_METRICS.map((metric) => [
      metric.key,
      pairedMetricStats(baselineSamples, candidateSamples, count, metric),
    ]),
  );
  return {
    baselineLabel,
    candidateLabel,
    count,
    candidateWins,
    baselineWins,
    ties,
    candidateWinRate: count === 0 ? null : candidateWins / count,
    deltaSummary: count === 0 ? null : summary(pairs.map((pair) => pair.deltaMs)),
    candidateImprovementPctSummary: finiteImprovementPct.length === 0 ? null : summary(finiteImprovementPct),
    attribution,
    pairs,
  };
}

export function pairedAttributionLedgerFields(pairedEngine) {
  const metric = (key) => pairedEngine?.attribution?.[key] ?? {};
  const deltaMedian = (key, scale = 1) => {
    const value = Number(metric(key)?.deltaSummary?.median);
    return Number.isFinite(value) ? value * scale : null;
  };
  const improvementMedian = (key) => {
    const value = Number(metric(key)?.candidateImprovementPctSummary?.median);
    return Number.isFinite(value) ? value : null;
  };
  const improvementMean = (key) => {
    const value = Number(metric(key)?.candidateImprovementPctSummary?.mean);
    return Number.isFinite(value) ? value : null;
  };
  const winRate = (key) => {
    const value = Number(metric(key)?.candidateWinRate);
    return Number.isFinite(value) ? value : null;
  };
  return {
    pairedCandidateDiscoverImprovementMedianPct: improvementMedian("discover"),
    pairedCandidateDiscoverImprovementMeanPct: improvementMean("discover"),
    pairedCandidateDiscoverDeltaMedianMs: deltaMedian("discover"),
    pairedCandidateDiscoverWinRate: winRate("discover"),
    pairedCandidateScanImprovementMedianPct: improvementMedian("scan"),
    pairedCandidateScanImprovementMeanPct: improvementMean("scan"),
    pairedCandidateScanDeltaMedianMs: deltaMedian("scan"),
    pairedCandidateScanWinRate: winRate("scan"),
    pairedCandidateAggregateImprovementMedianPct: improvementMedian("aggregate"),
    pairedCandidateAggregateImprovementMeanPct: improvementMean("aggregate"),
    pairedCandidateAggregateDeltaMedianMs: deltaMedian("aggregate"),
    pairedCandidateAggregateWinRate: winRate("aggregate"),
    pairedCandidateEngineResidualImprovementMedianPct: improvementMedian("engineResidual"),
    pairedCandidateEngineResidualImprovementMeanPct: improvementMean("engineResidual"),
    pairedCandidateEngineResidualDeltaMedianMs: deltaMedian("engineResidual"),
    pairedCandidateEngineResidualWinRate: winRate("engineResidual"),
    pairedCandidateScanWorkImprovementMedianPct: improvementMedian("scanWork"),
    pairedCandidateScanWorkImprovementMeanPct: improvementMean("scanWork"),
    pairedCandidateScanWorkDeltaMedianMs: deltaMedian("scanWork"),
    pairedCandidateScanWorkWinRate: winRate("scanWork"),
    pairedCandidateScanOpenImprovementMedianPct: improvementMedian("scanOpen"),
    pairedCandidateScanOpenImprovementMeanPct: improvementMean("scanOpen"),
    pairedCandidateScanOpenDeltaMedianMs: deltaMedian("scanOpen"),
    pairedCandidateScanOpenWinRate: winRate("scanOpen"),
    pairedCandidateScanFileImprovementMedianPct: improvementMedian("scanFile"),
    pairedCandidateScanFileImprovementMeanPct: improvementMean("scanFile"),
    pairedCandidateScanFileDeltaMedianMs: deltaMedian("scanFile"),
    pairedCandidateScanFileWinRate: winRate("scanFile"),
    pairedCandidateTeddyRangeImprovementMedianPct: improvementMedian("teddyRangeNs"),
    pairedCandidateTeddyRangeImprovementMeanPct: improvementMean("teddyRangeNs"),
    pairedCandidateTeddyRangeDeltaMedianMs: deltaMedian("teddyRangeNs", 1 / 1_000_000),
    pairedCandidateTeddyRangeWinRate: winRate("teddyRangeNs"),
  };
}

const PHASE_LEAK_FIELDS = [
  ["discover", "pairedCandidateDiscoverImprovementMedianPct", "pairedCandidateDiscoverDeltaMedianMs"],
  ["scan", "pairedCandidateScanImprovementMedianPct", "pairedCandidateScanDeltaMedianMs"],
  ["aggregate", "pairedCandidateAggregateImprovementMedianPct", "pairedCandidateAggregateDeltaMedianMs"],
  ["engineResidual", "pairedCandidateEngineResidualImprovementMedianPct", "pairedCandidateEngineResidualDeltaMedianMs"],
  ["scanWork", "pairedCandidateScanWorkImprovementMedianPct", "pairedCandidateScanWorkDeltaMedianMs"],
  ["scanOpen", "pairedCandidateScanOpenImprovementMedianPct", "pairedCandidateScanOpenDeltaMedianMs"],
  ["scanFile", "pairedCandidateScanFileImprovementMedianPct", "pairedCandidateScanFileDeltaMedianMs"],
  ["teddyRange", "pairedCandidateTeddyRangeImprovementMedianPct", "pairedCandidateTeddyRangeDeltaMedianMs"],
];

export function phaseLeakSummaryFromRounds(rounds) {
  const usableRounds = Array.isArray(rounds) ? rounds : [];
  const averages = Object.fromEntries(
    PHASE_LEAK_FIELDS.map(([name, key]) => [name, average(usableRounds.map((round) => round?.[key]))]),
  );
  const deltaMsAverages = Object.fromEntries(
    PHASE_LEAK_FIELDS.map(([name, , deltaKey]) => [name, average(usableRounds.map((round) => round?.[deltaKey]))]),
  );
  const leakingPhaseCounts = Object.fromEntries(PHASE_LEAK_FIELDS.map(([name]) => [name, 0]));
  const negativeAverages = Object.entries(averages)
    .filter(([, value]) => Number.isFinite(Number(value)) && Number(value) < 0)
    .sort((left, right) => Number(left[1]) - Number(right[1]))
    .map(([name, pairedMedianPct]) => ({
      name,
      pairedMedianPct,
      pairedDeltaMedianMs: Number.isFinite(Number(deltaMsAverages[name])) ? Number(deltaMsAverages[name]) : null,
      pairedDeltaMagnitudeMs: Number.isFinite(Number(deltaMsAverages[name])) ? Math.abs(Number(deltaMsAverages[name])) : null,
    }));
  const roundsWithLeaks = usableRounds.map((round) => {
    const phases = Object.fromEntries(PHASE_LEAK_FIELDS.map(([name, key, deltaKey]) => [
      name,
      {
        pairedMedianPct: Number(round?.[key]),
        pairedDeltaMedianMs: Number(round?.[deltaKey]),
      },
    ]));
    const negativePhases = Object.entries(phases)
      .filter(([, value]) => Number.isFinite(value.pairedMedianPct) && value.pairedMedianPct < 0)
      .sort((left, right) =>
        Math.abs(Number(right[1].pairedDeltaMedianMs ?? 0)) - Math.abs(Number(left[1].pairedDeltaMedianMs ?? 0)) ||
        left[1].pairedMedianPct - right[1].pairedMedianPct
      )
      .map(([name, value]) => {
        leakingPhaseCounts[name] += 1;
        return {
          name,
          pairedMedianPct: value.pairedMedianPct,
          pairedDeltaMedianMs: Number.isFinite(value.pairedDeltaMedianMs) ? value.pairedDeltaMedianMs : null,
          pairedDeltaMagnitudeMs: Number.isFinite(value.pairedDeltaMedianMs) ? Math.abs(value.pairedDeltaMedianMs) : null,
        };
      });
    return {
      roundIndex: round?.roundIndex ?? null,
      baselineLabel: round?.baselineLabel ?? null,
      pairedEngineMedianPct: round?.pairedCandidateImprovementMedianPct ?? null,
      teddyRangeMedianPct: round?.pairedCandidateTeddyRangeImprovementMedianPct ?? null,
      negativePhases,
    };
  });
  const worstRound = roundsWithLeaks
    .filter((round) => Number.isFinite(Number(round.pairedEngineMedianPct)))
    .sort((left, right) => Number(left.pairedEngineMedianPct) - Number(right.pairedEngineMedianPct))[0] ?? null;
  const averageEnginePairedMedianPct = average(usableRounds.map((round) => round?.pairedCandidateImprovementMedianPct));
  const teddyWinningEngineLeaking =
    Number(averages.teddyRange) > 0 &&
    Number(averageEnginePairedMedianPct) < 0;
  const roundLevelTeddyWinningEngineLeaking = roundsWithLeaks.some((round) =>
    Number(round.teddyRangeMedianPct) > 0 &&
    Number(round.pairedEngineMedianPct) < 0 &&
    Array.isArray(round.negativePhases) &&
    round.negativePhases.length > 0
  );
  const worstRoundRepairTarget = worstRound?.negativePhases?.[0]?.name ?? null;
  const shouldRepairLeak = teddyWinningEngineLeaking || roundLevelTeddyWinningEngineLeaking;
  const repairTargets = negativeAverages.map((entry) => ({
    ...entry,
    leakingRounds: leakingPhaseCounts[entry.name] ?? 0,
  })).sort((left, right) =>
    Number(right.pairedDeltaMagnitudeMs ?? 0) - Number(left.pairedDeltaMagnitudeMs ?? 0) ||
    Number(left.pairedMedianPct) - Number(right.pairedMedianPct)
  );
  if (
    shouldRepairLeak &&
    repairTargets.length === 0 &&
    Number.isFinite(Number(averageEnginePairedMedianPct)) &&
    Number(averageEnginePairedMedianPct) < 0
  ) {
    repairTargets.push({
      name: "unattributedEngine",
      pairedMedianPct: averageEnginePairedMedianPct,
      leakingRounds: roundsWithLeaks.filter((round) => Number(round.pairedEngineMedianPct) < 0).length,
    });
  }
  const nextRepairTarget = roundLevelTeddyWinningEngineLeaking
    ? worstRoundRepairTarget ?? repairTargets[0]?.name ?? null
    : repairTargets[0]?.name ?? worstRoundRepairTarget;
  return {
    averages,
    deltaMsAverages,
    negativeAverages,
    repairTargets,
    leakingPhaseCounts,
    worstRound,
    preservePositivePhase: shouldRepairLeak ? "teddyRange" : null,
    nextRepairTarget,
    diagnosis: shouldRepairLeak
      ? "preserve_positive_teddy_gain_and_repair_whole_engine_leak"
      : "no_positive_teddy_negative_engine_split_detected",
  };
}
