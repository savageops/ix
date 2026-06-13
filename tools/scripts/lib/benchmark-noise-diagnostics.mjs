const PHASES = [
  ["engine", null, 1],
  ["discover", "discover", 1],
  ["scan", "scan", 1],
  ["aggregate", "aggregate", 1],
  ["engineResidual", "engineResidual", 1],
  ["scanWork", "scanWork", 1],
  ["teddyRangeNs", "teddyRangeNs", 1 / 1_000_000],
];

function finiteNumber(value) {
  const number = Number(value);
  return Number.isFinite(number) ? number : null;
}

function absFinite(value) {
  const number = finiteNumber(value);
  return number == null ? null : Math.abs(number);
}

function phaseEntry(pairedEngine, name, attributionKey, deltaMsScale) {
  const source = attributionKey == null ? pairedEngine : pairedEngine?.attribution?.[attributionKey];
  const medianImprovementPct = finiteNumber(source?.candidateImprovementPctSummary?.median);
  const medianDeltaRaw = finiteNumber(source?.deltaSummary?.median);
  const medianDeltaMs = medianDeltaRaw == null ? null : medianDeltaRaw * deltaMsScale;
  const absMedianDeltaMs = absFinite(medianDeltaMs);
  return {
    name,
    medianDeltaRaw,
    medianDeltaMs,
    absMedianDeltaMs,
    deltaUnit: deltaMsScale === 1 ? "ms" : "ns",
    normalizedDeltaUnit: "ms",
    medianImprovementPct,
    absMedianImprovementPct: absFinite(medianImprovementPct),
    candidateWinRate: finiteNumber(source?.candidateWinRate),
    count: finiteNumber(source?.count),
  };
}

function dominantPhaseDrift(pairedEngine) {
  const phases = PHASES
    .map(([name, attributionKey, deltaMsScale]) => phaseEntry(pairedEngine, name, attributionKey, deltaMsScale))
    .filter((entry) => entry.absMedianDeltaMs != null || entry.absMedianImprovementPct != null)
    .sort((left, right) =>
      (right.absMedianDeltaMs ?? -1) - (left.absMedianDeltaMs ?? -1) ||
      (right.absMedianImprovementPct ?? -1) - (left.absMedianImprovementPct ?? -1)
    );
  return {
    dominant: phases[0] ?? null,
    phases,
  };
}

function diagnosisStatus({ medianDeltaAbsPct, maxMedianDeltaPct, winRate, minWinRate, maxWinRate, maxRobustCvPct }) {
  if (medianDeltaAbsPct == null) return "missing_median_delta";
  if (medianDeltaAbsPct > maxMedianDeltaPct) return "median_shift";
  if (winRate != null && (winRate <= minWinRate || winRate >= maxWinRate)) return "paired_lane_skew";
  if (maxRobustCvPct != null && maxRobustCvPct > maxMedianDeltaPct) return "sample_spread";
  return "stable";
}

function recommendedAction(status) {
  switch (status) {
    case "median_shift":
      return "rerun under a quieter host before using previous-build deltas; same-binary median drift is larger than the allowed attribution floor";
    case "paired_lane_skew":
      return "rerun with paired order preserved; one same-binary lane is winning too consistently for source attribution";
    case "sample_spread":
      return "increase retained samples or reduce host contention; same-binary robust CV is larger than the attribution floor";
    case "missing_median_delta":
      return "discard this report for runtime decisions; same-binary control did not produce a usable median delta";
    default:
      return "same-binary control is stable enough for the configured attribution floor";
  }
}

export function identityNoiseDiagnostics(identityControl, {
  maxMedianDeltaPct = 3,
  minWinRate = 0.25,
  maxWinRate = 0.75,
} = {}) {
  if (identityControl == null) return null;
  const medianDeltaPct = finiteNumber(identityControl.medianDeltaPct);
  const medianDeltaAbsPct = absFinite(medianDeltaPct);
  const pairedWinRate = finiteNumber(identityControl.pairedEngine?.candidateWinRate);
  const firstEngineRobustCvPct = finiteNumber(identityControl.first?.engineSummary?.robustCvPct);
  const secondEngineRobustCvPct = finiteNumber(identityControl.second?.engineSummary?.robustCvPct);
  const maxRobustCvPct = Math.max(firstEngineRobustCvPct ?? 0, secondEngineRobustCvPct ?? 0);
  const phaseDrift = dominantPhaseDrift(identityControl.pairedEngine);
  const status = diagnosisStatus({
    medianDeltaAbsPct,
    maxMedianDeltaPct,
    winRate: pairedWinRate,
    minWinRate,
    maxWinRate,
    maxRobustCvPct,
  });
  return {
    status,
    medianDeltaPct,
    medianDeltaAbsPct,
    maxMedianDeltaPct,
    pairedWinRate,
    allowedWinRateRange: [minWinRate, maxWinRate],
    firstEngineRobustCvPct,
    secondEngineRobustCvPct,
    maxRobustCvPct,
    dominantPhaseDrift: phaseDrift.dominant,
    phaseDrift: phaseDrift.phases,
    recommendation: recommendedAction(status),
  };
}
