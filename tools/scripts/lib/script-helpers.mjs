export function argValue(args, name, fallback) {
  const idx = args.indexOf(name);
  if (idx >= 0 && idx + 1 < args.length) {
    return args[idx + 1];
  }
  return fallback;
}

export function toPositiveInt(value, fallback) {
  const parsed = Number(value);
  if (!Number.isFinite(parsed) || parsed <= 0) {
    return fallback;
  }
  return Math.floor(parsed);
}

export function timestampSlug(date = new Date()) {
  return date.toISOString().replaceAll(":", "-").replaceAll(".", "-");
}

export function sleep(ms) {
  if (ms <= 0) {
    return Promise.resolve();
  }
  return new Promise((resolve) => setTimeout(resolve, ms));
}

export function historicalSelectionSeedEligible(report) {
  return report != null && report.diagnosticAttributionMode !== true;
}

function historicalSelectionSeedTimestamp(report) {
  const parsed = Date.parse(report?.timestamp ?? "");
  return Number.isFinite(parsed) ? parsed : Number.NEGATIVE_INFINITY;
}

function historicalSelectionSeedArrayLength(values) {
  return Array.isArray(values) ? values.length : 0;
}

function historicalSelectionSeedStable(report) {
  if (report?.retainableStrictEvidence === true) return true;
  if (report?.preflightAborted === true) return false;
  const samples = Number(report?.samples);
  const minRetainableSamples = Number(report?.minRetainableSamples);
  const retainsSampleFloor =
    Number.isFinite(samples) &&
    samples > 0 &&
    (!Number.isFinite(minRetainableSamples) || samples >= minRetainableSamples);
  const quality = report?.evidenceQuality;
  const cleanEnvelope =
    quality != null &&
    historicalSelectionSeedArrayLength(quality.hostFailures) === 0 &&
    historicalSelectionSeedArrayLength(quality.identityFailures) === 0 &&
    historicalSelectionSeedArrayLength(quality.processFailures) === 0 &&
    historicalSelectionSeedArrayLength(quality.sampleFailures) === 0;
  return retainsSampleFloor && cleanEnvelope;
}

function historicalSelectionSeedPriority(candidate) {
  if (candidate?.report?.retainableStrictEvidence === true) return 4;
  if (historicalSelectionSeedStable(candidate?.report)) return 3;
  const selectionPriority = {
    latest_failed: 2,
    latest_nondiagnostic: 1,
    latest_historical: 0,
    latest_retainable: 0,
  };
  return selectionPriority[candidate?.selectionClass] ?? 0;
}

export function preferHistoricalSelectionSeed(candidates = []) {
  const eligible = candidates
    .filter((candidate) => candidate?.report != null)
    .filter((candidate) => candidate.allowSelection !== false)
    .filter((candidate) => historicalSelectionSeedEligible(candidate.report))
    .map((candidate, index) => ({ ...candidate, __index: index }));
  if (eligible.length === 0) {
    return null;
  }
  eligible.sort((left, right) =>
    historicalSelectionSeedPriority(right) - historicalSelectionSeedPriority(left) ||
    historicalSelectionSeedTimestamp(right.report) - historicalSelectionSeedTimestamp(left.report) ||
    left.__index - right.__index);
  const { __index, ...selected } = eligible[0];
  return selected;
}

function historicalComparisonRouteComparable(comparison) {
  if (comparison?.routeParityAcceptable != null) return comparison.routeParityAcceptable === true;
  if (comparison?.routeParity != null) return comparison.routeParity === true;
  return false;
}

export function hardestComparableHistoricalLabel(report) {
  const comparisons = Array.isArray(report?.comparisons)
    ? report.comparisons.filter((comparison) =>
      comparison?.evidenceAuthority === "previous_build" &&
      typeof comparison?.label === "string" &&
      comparison.label.length > 0 &&
      comparison?.matchParity === true &&
      historicalComparisonRouteComparable(comparison))
    : [];
  if (comparisons.length === 0) return null;
  comparisons.sort((left, right) =>
    Number(left.currentEngineImprovementPct ?? Number.POSITIVE_INFINITY) -
      Number(right.currentEngineImprovementPct ?? Number.POSITIVE_INFINITY) ||
    Number(left.pairedEngine?.candidateWinRate ?? Number.POSITIVE_INFINITY) -
      Number(right.pairedEngine?.candidateWinRate ?? Number.POSITIVE_INFINITY) ||
    String(left.label).localeCompare(String(right.label)));
  return comparisons[0].label;
}
