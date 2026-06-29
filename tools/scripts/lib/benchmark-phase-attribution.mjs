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

function optionalBoolean(value) {
  return typeof value === "boolean" ? value : null;
}

function ratioPct(part, whole) {
  const partNumber = Number(part);
  const wholeNumber = Number(whole);
  if (!Number.isFinite(partNumber) || !Number.isFinite(wholeNumber) || wholeNumber === 0) return null;
  return (partNumber / wholeNumber) * 100;
}

function delta(left, right) {
  const leftNumber = Number(left);
  const rightNumber = Number(right);
  if (!Number.isFinite(leftNumber) || !Number.isFinite(rightNumber)) return null;
  return leftNumber - rightNumber;
}

function nsToMs(value) {
  const number = Number(value);
  return Number.isFinite(number) ? number / 1_000_000 : null;
}

function subphaseTimingPresent(openMs, fileMs) {
  const open = Number(openMs);
  const file = Number(fileMs);
  return (Number.isFinite(open) && open > 0) || (Number.isFinite(file) && file > 0);
}

function optionalSummary(values) {
  const finite = finiteNumbers(values);
  return finite.length === 0 ? null : summary(finite);
}

function topWeightedEntries(entries, limit = 8) {
  const counts = new Map();
  for (const entry of entries) {
    const value = typeof entry === "string" ? entry : entry?.value;
    if (!value) continue;
    const count = Number(typeof entry === "string" ? 1 : entry?.count ?? 1);
    counts.set(value, (counts.get(value) ?? 0) + (Number.isFinite(count) ? count : 1));
  }
  return [...counts.entries()]
    .map(([value, count]) => ({ value, count }))
    .sort((left, right) => right.count - left.count || left.value.localeCompare(right.value))
    .slice(0, limit);
}

function pathClass(path) {
  const normalized = String(path ?? "").replaceAll("\\", "/").toLowerCase();
  if (normalized.includes("/linux/drivers/gpu/drm/amd/include/asic_reg/")) return "linux_amd_asic_reg_header";
  if (normalized.includes("/linux/")) return "linux_tree";
  if (normalized.endsWith(".h")) return "c_header";
  if (normalized.endsWith(".c")) return "c_source";
  if (normalized.endsWith(".rs")) return "rust_source";
  return normalized.length === 0 ? "unknown" : "other";
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
  const targetRounds = nextRepairTarget == null ? [] : roundsWithLeaks
    .filter((round) => Array.isArray(round.negativePhases) && round.negativePhases.some((phase) => phase.name === nextRepairTarget))
    .map((round) => {
      const phase = round.negativePhases.find((entry) => entry.name === nextRepairTarget) ?? {};
      const sourceRound = usableRounds.find((entry) => entry?.roundIndex === round.roundIndex) ?? {};
      const baselineScanSplitPresent = subphaseTimingPresent(
        sourceRound.baselineScanOpenMedianMs,
        sourceRound.baselineScanFileMedianMs,
      );
      const baselineScanOpenSharePct = baselineScanSplitPresent
        ? ratioPct(sourceRound.baselineScanOpenMedianMs, sourceRound.baselineScanWorkMedianMs)
        : null;
      const baselineScanFileSharePct = baselineScanSplitPresent
        ? ratioPct(sourceRound.baselineScanFileMedianMs, sourceRound.baselineScanWorkMedianMs)
        : null;
      const candidateScanOpenSharePct = ratioPct(sourceRound.candidateScanOpenMedianMs, sourceRound.candidateScanWorkMedianMs);
      const candidateScanFileSharePct = ratioPct(sourceRound.candidateScanFileMedianMs, sourceRound.candidateScanWorkMedianMs);
      return {
        roundIndex: round.roundIndex,
        baselineLabel: round.baselineLabel,
        pairedEngineMedianPct: round.pairedEngineMedianPct,
        teddyRangeMedianPct: round.teddyRangeMedianPct,
        targetPhase: nextRepairTarget,
        targetPhaseMedianPct: Number.isFinite(Number(phase.pairedMedianPct)) ? Number(phase.pairedMedianPct) : null,
        targetPhaseDeltaMs: Number.isFinite(Number(phase.pairedDeltaMedianMs)) ? Number(phase.pairedDeltaMedianMs) : null,
        baselineScanWorkMedianMs: optionalNumber(sourceRound.baselineScanWorkMedianMs),
        baselineScanOpenMedianMs: optionalNumber(sourceRound.baselineScanOpenMedianMs),
        baselineScanFileMedianMs: optionalNumber(sourceRound.baselineScanFileMedianMs),
        baselineScanOpenMsPerFileMedian: optionalNumber(sourceRound.baselineScanOpenMsPerFileMedian),
        baselineScanFileMsPerFileMedian: optionalNumber(sourceRound.baselineScanFileMsPerFileMedian),
        baselineFilesScanned: Array.isArray(sourceRound.baselineFilesScanned) ? sourceRound.baselineFilesScanned : null,
        candidateFilesScanned: Array.isArray(sourceRound.candidateFilesScanned) ? sourceRound.candidateFilesScanned : null,
        filesScannedParity: optionalBoolean(sourceRound.filesScannedParity),
        baselineScanSplitPresent,
        candidateScanWorkMedianMs: optionalNumber(sourceRound.candidateScanWorkMedianMs),
        candidateScanOpenMedianMs: optionalNumber(sourceRound.candidateScanOpenMedianMs),
        candidateScanFileMedianMs: optionalNumber(sourceRound.candidateScanFileMedianMs),
        candidateScanOpenMsPerFileMedian: optionalNumber(sourceRound.candidateScanOpenMsPerFileMedian),
        candidateScanFileMsPerFileMedian: optionalNumber(sourceRound.candidateScanFileMsPerFileMedian),
        scanWorkDeltaMs: delta(sourceRound.candidateScanWorkMedianMs, sourceRound.baselineScanWorkMedianMs),
        scanOpenDeltaMs: baselineScanSplitPresent ? delta(sourceRound.candidateScanOpenMedianMs, sourceRound.baselineScanOpenMedianMs) : null,
        scanFileDeltaMs: baselineScanSplitPresent ? delta(sourceRound.candidateScanFileMedianMs, sourceRound.baselineScanFileMedianMs) : null,
        scanOpenMsPerFileDelta: baselineScanSplitPresent ? delta(sourceRound.candidateScanOpenMsPerFileMedian, sourceRound.baselineScanOpenMsPerFileMedian) : null,
        scanFileMsPerFileDelta: baselineScanSplitPresent ? delta(sourceRound.candidateScanFileMsPerFileMedian, sourceRound.baselineScanFileMsPerFileMedian) : null,
        baselineScanOpenSharePct,
        baselineScanFileSharePct,
        candidateScanOpenSharePct,
        candidateScanFileSharePct,
        scanOpenShareDeltaPct: baselineScanSplitPresent ? delta(candidateScanOpenSharePct, baselineScanOpenSharePct) : null,
        scanFileShareDeltaPct: baselineScanSplitPresent ? delta(candidateScanFileSharePct, baselineScanFileSharePct) : null,
      };
    });
  const currentOnlyScanSplit = nextRepairTarget === "scanWork"
    ? (() => {
        const candidateSplitRounds = targetRounds.filter((round) =>
          subphaseTimingPresent(round.candidateScanOpenMedianMs, round.candidateScanFileMedianMs)
        );
        const predecessorSplitRounds = targetRounds.filter((round) => round.baselineScanSplitPresent);
        const candidateScanOpenShare = optionalSummary(candidateSplitRounds.map((round) => round.candidateScanOpenSharePct));
        const candidateScanFileShare = optionalSummary(candidateSplitRounds.map((round) => round.candidateScanFileSharePct));
        const candidateScanOpenMedianMs = optionalSummary(candidateSplitRounds.map((round) => round.candidateScanOpenMedianMs));
        const candidateScanFileMedianMs = optionalSummary(candidateSplitRounds.map((round) => round.candidateScanFileMedianMs));
        const candidateScanWorkMedianMs = optionalSummary(candidateSplitRounds.map((round) => round.candidateScanWorkMedianMs));
        const candidateScanOpenMsPerFileMedian = optionalSummary(candidateSplitRounds.map((round) => round.candidateScanOpenMsPerFileMedian));
        const candidateScanFileMsPerFileMedian = optionalSummary(candidateSplitRounds.map((round) => round.candidateScanFileMsPerFileMedian));
        const fileParityValues = candidateSplitRounds.map((round) => round.filesScannedParity);
        const filesScannedParity = fileParityValues.length === 0 || fileParityValues.some((value) => value == null)
          ? null
          : fileParityValues.every((value) => value === true);
        const scanFileResidualRounds = candidateSplitRounds.map((round) => {
          const sourceRound = usableRounds.find((entry) => entry?.roundIndex === round.roundIndex) ?? {};
          const teddyMs = nsToMs(sourceRound.candidateAlternateTeddyRangeElapsedNsMedian);
          const fullScanMs = nsToMs(sourceRound.candidateAlternateFullScanElapsedNsMedian);
          const residualAfterTeddyMs = delta(round.candidateScanFileMedianMs, teddyMs);
          const residualMs = fullScanMs == null ? residualAfterTeddyMs : delta(residualAfterTeddyMs, fullScanMs);
          return {
            roundIndex: round.roundIndex,
            baselineLabel: round.baselineLabel,
            candidateScanFileMedianMs: round.candidateScanFileMedianMs,
            candidateTeddyRangeMedianMs: teddyMs,
            candidateAlternateFullScanMedianMs: fullScanMs,
            candidateScanFileResidualMedianMs: residualMs,
            candidateTeddyShareOfScanFilePct: ratioPct(teddyMs, round.candidateScanFileMedianMs),
            candidateAlternateFullScanShareOfScanFilePct: ratioPct(fullScanMs, round.candidateScanFileMedianMs),
            candidateScanFileResidualSharePct: ratioPct(residualMs, round.candidateScanFileMedianMs),
          };
        });
        const scanFileResidualMedianMs = optionalSummary(scanFileResidualRounds.map((round) => round.candidateScanFileResidualMedianMs));
        const teddyShareOfScanFilePct = optionalSummary(scanFileResidualRounds.map((round) => round.candidateTeddyShareOfScanFilePct));
        const alternateFullScanShareOfScanFilePct = optionalSummary(scanFileResidualRounds.map((round) => round.candidateAlternateFullScanShareOfScanFilePct));
        const alternateFullScanMedianMs = optionalSummary(scanFileResidualRounds.map((round) => round.candidateAlternateFullScanMedianMs));
        const scanFileResidualSharePct = optionalSummary(scanFileResidualRounds.map((round) => round.candidateScanFileResidualSharePct));
        const candidateSlowestPathHotspots = topWeightedEntries(candidateSplitRounds.flatMap((round) => {
          const sourceRound = usableRounds.find((entry) => entry?.roundIndex === round.roundIndex) ?? {};
          return Array.isArray(sourceRound.candidateSlowestPathTop) ? sourceRound.candidateSlowestPathTop : [];
        }));
        const candidateSlowestPathClasses = topWeightedEntries(candidateSlowestPathHotspots.map((entry) => ({
          value: pathClass(entry.value),
          count: entry.count,
        })));
        const dominantCandidateSubphase =
          Number(candidateScanOpenShare?.median ?? 0) > Number(candidateScanFileShare?.median ?? 0)
            ? "scanOpen"
            : (candidateScanFileShare == null ? null : "scanFile");
        const regressingCandidateSubphase = [
          {
            name: "scanOpen",
            pairedMedianPct: averages.scanOpen,
            pairedDeltaMedianMs: deltaMsAverages.scanOpen,
          },
          {
            name: "scanFile",
            pairedMedianPct: averages.scanFile,
            pairedDeltaMedianMs: deltaMsAverages.scanFile,
          },
        ]
          .filter((entry) => Number.isFinite(Number(entry.pairedMedianPct)) && Number(entry.pairedMedianPct) < 0)
          .sort((left, right) =>
            Math.abs(Number(right.pairedDeltaMedianMs ?? 0)) - Math.abs(Number(left.pairedDeltaMedianMs ?? 0)) ||
            Number(left.pairedMedianPct) - Number(right.pairedMedianPct)
          )[0] ?? null;
        const dominantCandidateScanFileComponent = [
          { name: "teddyRange", share: teddyShareOfScanFilePct },
          { name: "alternateFullScan", share: alternateFullScanShareOfScanFilePct },
          { name: "scanFileResidual", share: scanFileResidualSharePct },
        ]
          .filter((entry) => entry.share != null)
          .sort((a, b) => Number(b.share?.median ?? 0) - Number(a.share?.median ?? 0))[0]?.name ?? null;
        return {
          targetRoundCount: targetRounds.length,
          candidateSplitRoundCount: candidateSplitRounds.length,
          predecessorSplitRoundCount: predecessorSplitRounds.length,
          predecessorSplitMissingCount: targetRounds.length - predecessorSplitRounds.length,
          predecessorComparisonLimited: predecessorSplitRounds.length < targetRounds.length,
          dominantCandidateSubphase,
          regressingCandidateSubphase: regressingCandidateSubphase?.name ?? null,
          regressingCandidateSubphaseMedianPct: Number.isFinite(Number(regressingCandidateSubphase?.pairedMedianPct)) ? Number(regressingCandidateSubphase.pairedMedianPct) : null,
          regressingCandidateSubphaseDeltaMs: Number.isFinite(Number(regressingCandidateSubphase?.pairedDeltaMedianMs)) ? Number(regressingCandidateSubphase.pairedDeltaMedianMs) : null,
          dominantCandidateScanFileComponent,
          candidateScanOpenSharePct: candidateScanOpenShare,
          candidateScanFileSharePct: candidateScanFileShare,
          candidateScanOpenMedianMs,
          candidateScanFileMedianMs,
          candidateScanWorkMedianMs,
          candidateScanOpenMsPerFileMedian,
          candidateScanFileMsPerFileMedian,
          filesScannedParity,
          candidateTeddyShareOfScanFilePct: teddyShareOfScanFilePct,
          candidateAlternateFullScanShareOfScanFilePct: alternateFullScanShareOfScanFilePct,
          candidateAlternateFullScanMedianMs: alternateFullScanMedianMs,
          candidateScanFileResidualSharePct: scanFileResidualSharePct,
          candidateScanFileResidualMedianMs: scanFileResidualMedianMs,
          scanFileResidualRounds,
          candidateSlowestPathHotspots,
          candidateSlowestPathClasses,
          interpretation: candidateSplitRounds.length === 0
            ? "scanWork is leaking, but current split telemetry is unavailable; rerun with --scan-open-timing"
            : (predecessorSplitRounds.length < targetRounds.length
                ? "scanWork is leaking; predecessor split telemetry is incomplete, so use current-only scanOpen/scanFile shares to choose the next owner"
                : "scanWork is leaking; predecessor and candidate scanOpen/scanFile split telemetry are comparable"),
        };
      })()
    : null;
  const protectedWinningRounds = roundsWithLeaks
    .filter((round) =>
      Number(round.teddyRangeMedianPct) > 0 &&
      Number(round.pairedEngineMedianPct) < 0
    )
    .map((round) => ({
      roundIndex: round.roundIndex,
      baselineLabel: round.baselineLabel,
      pairedEngineMedianPct: round.pairedEngineMedianPct,
      teddyRangeMedianPct: round.teddyRangeMedianPct,
    }));
  const nextProbe = nextRepairTarget === "scanWork"
    ? {
        id: "split_scan_work_open_vs_file",
        reason: "scanWork is leaking; use current-only scanOpen/scanFile medians when predecessor builds lack those counters",
        commandSuffix: "--scan-open-timing",
      }
    : (nextRepairTarget == null ? null : {
        id: `measure_${nextRepairTarget}_leak`,
        reason: `${nextRepairTarget} is the current whole-engine leak target`,
        commandSuffix: null,
      });
  return {
    averages,
    deltaMsAverages,
    negativeAverages,
    repairTargets,
    leakingPhaseCounts,
    worstRound,
    leakAttribution: {
      targetPhase: nextRepairTarget,
      targetRounds,
      currentOnlyScanSplit,
      protectedWinningRounds,
      nextProbe,
    },
    preservePositivePhase: shouldRepairLeak ? "teddyRange" : null,
    nextRepairTarget,
    diagnosis: shouldRepairLeak
      ? "preserve_positive_teddy_gain_and_repair_whole_engine_leak"
      : "no_positive_teddy_negative_engine_split_detected",
  };
}
