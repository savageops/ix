import {
  classifyHotspot,
  computeRatio,
  mean,
  semivarianceAbove,
  summarizeSeries,
} from "./metrics.mjs";

const RECENT_WINDOW_LIMIT = 100;
const SELF_TREND_MIN_WINDOW = 10;
const SELF_SNAPSHOT_MIN_WINDOW = 3;
const MAX_HINTS = 20;

function asNumber(value, fallback = 0) {
  const parsed = Number(value);
  return Number.isFinite(parsed) ? parsed : fallback;
}
function phaseMs(run, phase) {
  return asNumber(run?.phaseMs?.[phase], 0);
}

function clamp(value, min, max) {
  return Math.min(max, Math.max(min, value));
}

function withDerived(run) {
  const iexMs = asNumber(run?.iexMs, 0);
  const rgMs = asNumber(run?.rgMs, 0);
  const ratio = asNumber(run?.ratio, computeRatio(iexMs, rgMs));
  const speedupPct = asNumber(run?.speedupPct, 0);
  const discover = phaseMs(run, "discover");
  const scan = phaseMs(run, "scan");
  const aggregate = phaseMs(run, "aggregate");
  const total = phaseMs(run, "total");
  const hotspot = run?.hotspot ?? classifyHotspot({ phaseMs: { discover, scan, aggregate } });

  const phaseShareDenominator = total > 0 ? total : discover + scan + aggregate;
  const share = {
    discoverPct: phaseShareDenominator > 0 ? (discover / phaseShareDenominator) * 100 : 0,
    scanPct: phaseShareDenominator > 0 ? (scan / phaseShareDenominator) * 100 : 0,
    aggregatePct: phaseShareDenominator > 0 ? (aggregate / phaseShareDenominator) * 100 : 0,
  };

  return {
    ...run,
    iexMs,
    rgMs,
    ratio,
    speedupPct,
    hotspot,
    phaseMs: { discover, scan, aggregate, total },
    phaseShare: share,
  };
}

function toCounterMap(values) {
  const counts = {};
  for (const value of values) {
    if (!value) {
      continue;
    }
    counts[value] = (counts[value] ?? 0) + 1;
  }
  return counts;
}

function dominantFromCounter(counter) {
  let bestKey = "n/a";
  let bestCount = -1;
  for (const [key, count] of Object.entries(counter)) {
    if (count > bestCount) {
      bestKey = key;
      bestCount = count;
    }
  }
  return bestKey;
}

function dominantPhaseByMedianShare(shares) {
  return Object.entries({
    discover: shares.discoverPct.median,
    scan: shares.scanPct.median,
    aggregate: shares.aggregatePct.median,
  }).sort((left, right) => right[1] - left[1])[0]?.[0] ?? "n/a";
}

function summarizeRunSet(runs) {
  const ratios = runs.map((run) => run.ratio);
  const speedups = runs.map((run) => run.speedupPct);
  const iexMs = runs.map((run) => run.iexMs);
  const rgMs = runs.map((run) => run.rgMs);
  const deltaMs = runs.map((run) => run.iexMs - run.rgMs);
  const goalGapMs = runs.map((run) => run.iexMs - (run.rgMs * 0.5));
  const slowerRuns = runs.filter((run) => run.ratio > 1);
  const fasterRuns = runs.filter((run) => run.ratio < 1);
  const tieRuns = runs.length - slowerRuns.length - fasterRuns.length;
  const goalHits = runs.filter((run) => run.speedupPct >= 50);
  const hotspots = toCounterMap(runs.map((run) => run.hotspot));

  const phaseMsSeries = {
    discover: summarizeSeries(runs.map((run) => run.phaseMs.discover)),
    scan: summarizeSeries(runs.map((run) => run.phaseMs.scan)),
    aggregate: summarizeSeries(runs.map((run) => run.phaseMs.aggregate)),
    total: summarizeSeries(runs.map((run) => run.phaseMs.total)),
  };
  const phaseSharePctSeries = {
    discoverPct: summarizeSeries(runs.map((run) => run.phaseShare.discoverPct)),
    scanPct: summarizeSeries(runs.map((run) => run.phaseShare.scanPct)),
    aggregatePct: summarizeSeries(runs.map((run) => run.phaseShare.aggregatePct)),
  };

  return {
    runCount: runs.length,
    iexMs: summarizeSeries(iexMs),
    rgMs: summarizeSeries(rgMs),
    deltaMs: summarizeSeries(deltaMs),
    goalGapMs: summarizeSeries(goalGapMs),
    ratio: summarizeSeries(ratios),
    speedupPct: summarizeSeries(speedups),
    slowerRuns: {
      count: slowerRuns.length,
      pct: runs.length ? (slowerRuns.length / runs.length) * 100 : 0,
    },
    fasterRuns: {
      count: fasterRuns.length,
      pct: runs.length ? (fasterRuns.length / runs.length) * 100 : 0,
    },
    tieRuns: {
      count: tieRuns,
      pct: runs.length ? (tieRuns / runs.length) * 100 : 0,
    },
    goalHits: {
      count: goalHits.length,
      pct: runs.length ? (goalHits.length / runs.length) * 100 : 0,
    },
    phaseMs: phaseMsSeries,
    phaseSharePct: phaseSharePctSeries,
    hotspotCounts: hotspots,
    dominantHotspot: dominantFromCounter(hotspots),
    dominantPhaseByMedianShare: dominantPhaseByMedianShare(phaseSharePctSeries),
  };
}

function summarizeProfile(profile, runs) {
  const summary = summarizeRunSet(runs);
  return {
    profile,
    runs: runs.length,
    slowerRuns: summary.slowerRuns.count,
    slowerRunPct: summary.slowerRuns.pct,
    fasterRuns: summary.fasterRuns.count,
    ratio: summary.ratio,
    speedupPct: summary.speedupPct,
    dominantHotspot: summary.dominantHotspot,
    dominantPhaseByMedianShare: summary.dominantPhaseByMedianShare,
    hotspotCounts: summary.hotspotCounts,
    phaseMs: summary.phaseMs,
    phaseSharePct: summary.phaseSharePct,
    goalHitPct: summary.goalHits.pct,
  };
}

function summarizeCompetitors(runs) {
  const grouped = new Map();

  for (const run of runs) {
    for (const [name, competitor] of Object.entries(run.competitors ?? {})) {
      const bucket = grouped.get(name) ?? [];
      bucket.push({ run, competitor });
      grouped.set(name, bucket);
    }
  }

  const summary = [...grouped.entries()].map(([name, entries]) => {
    const measured = entries.filter((entry) =>
      entry.competitor?.available && Number.isFinite(entry.competitor?.durationMs),
    );
    const isIxVariant = name === "iex_previous" || name === "iex_rust";
    const authoritativeMeasured =
      isIxVariant
        ? measured.filter((entry) => entry.competitor?.comparatorAuthority === "authoritative")
        : measured;
    const ratioMeasured = isIxVariant ? authoritativeMeasured : measured;
    const durations = measured.map((entry) => entry.competitor.durationMs);
    const ratios = ratioMeasured
      .map((entry) => computeRatio(entry.run.iexMs, entry.competitor.durationMs))
      .filter((value) => Number.isFinite(value) && value > 0);
    const iexWins = ratios.filter((ratio) => ratio < 1).length;
    const iexLosses = ratios.filter((ratio) => ratio > 1).length;
    const timingOnlyRuns =
      isIxVariant
        ? measured.filter((entry) => entry.competitor?.comparatorAuthority === "timing_only").length
        : 0;
    const unknownAuthorityRuns =
      isIxVariant
        ? measured.filter((entry) => !entry.competitor?.comparatorAuthority).length
        : 0;

    return {
      name,
      label: entries.find((entry) => entry.competitor?.label)?.competitor?.label ?? name,
      kind: entries.find((entry) => entry.competitor?.kind)?.competitor?.kind ?? "external",
      runCount: entries.length,
      availableRuns: measured.length,
      authoritativeRuns: authoritativeMeasured.length,
      timingOnlyRuns,
      unknownAuthorityRuns,
      ratioBaseline:
        isIxVariant
          ? authoritativeMeasured.length > 0
            ? "authoritative"
            : "timing-only"
          : "all-available",
      availabilityPct: entries.length ? (measured.length / entries.length) * 100 : 0,
      durationMs: summarizeSeries(durations),
      iexRatio: summarizeSeries(ratios),
      iexWins,
      iexLosses,
      iexWinPct: ratioMeasured.length ? (iexWins / ratioMeasured.length) * 100 : 0,
      iexLossPct: ratioMeasured.length ? (iexLosses / ratioMeasured.length) * 100 : 0,
      command: entries.find((entry) => entry.competitor?.command)?.competitor?.command ?? null,
      resolvedCommand:
        entries.find((entry) => entry.competitor?.resolvedCommand)?.competitor?.resolvedCommand ?? null,
      status: measured.length > 0 ? "available" : "unavailable",
    };
  });

  return summary.sort((left, right) => {
    const preferredOrder = ["ripgrep", "iex_previous", "iex_rust"];
    const leftIndex = preferredOrder.indexOf(left.name);
    const rightIndex = preferredOrder.indexOf(right.name);
    if (leftIndex !== -1 || rightIndex !== -1) {
      if (leftIndex === -1) {
        return 1;
      }
      if (rightIndex === -1) {
        return -1;
      }
      if (leftIndex !== rightIndex) {
        return leftIndex - rightIndex;
      }
    }
    if (left.status !== right.status) {
      return left.status === "available" ? -1 : 1;
    }
    return left.durationMs.median - right.durationMs.median;
  });
}

function pickPrimaryChallenger(competitorSummary) {
  const available = competitorSummary.filter(
    (entry) => entry.status === "available" && entry.kind !== "self-history" && entry.name !== "iex_previous" && entry.name !== "iex_rust",
  );
  return available.find((entry) => entry.name !== "ripgrep") ?? null;
}

function buildOutlierSummary(normalized, ratioSeries) {
  const iqr = ratioSeries.p75 - ratioSeries.p25;
  const threshold = ratioSeries.p75 + 1.5 * iqr;
  const outlierRuns = normalized.filter((run) => run.ratio > threshold);
  const outlierProfiles = toCounterMap(outlierRuns.map((run) => run.profile ?? "unknown"));
  return {
    thresholdRatio: threshold,
    count: outlierRuns.length,
    pct: normalized.length ? (outlierRuns.length / normalized.length) * 100 : 0,
    severityMeanPct: outlierRuns.length
      ? mean(
          outlierRuns.map((run) =>
            Math.max(0, ((run.ratio - threshold) / threshold) * 100),
          ),
        )
      : 0,
    profileCounts: outlierProfiles,
    dominantProfile: dominantFromCounter(outlierProfiles),
    timeline: outlierRuns
      .slice()
      .sort((left, right) => right.ratio - left.ratio)
      .slice(0, 25)
      .map((run) => ({
        runId: run.runId,
        timestamp: run.timestamp,
        profile: run.profile,
        ratio: run.ratio,
        speedupPct: run.speedupPct,
        hotspot: run.hotspot,
        phaseMs: run.phaseMs,
      })),
  };
}

function summarizeIexByProfile(runs) {
  const grouped = new Map();
  for (const run of runs) {
    const key = run.profile ?? "unknown";
    const bucket = grouped.get(key) ?? [];
    bucket.push(run.iexMs);
    grouped.set(key, bucket);
  }

  const summary = new Map();
  for (const [profile, iexMs] of grouped.entries()) {
    summary.set(profile, {
      profile,
      runs: iexMs.length,
      iexMs: summarizeSeries(iexMs),
    });
  }
  return summary;
}

function unavailableSelfImprovement(overrides = {}) {
  return {
    available: false,
    windowSize: 0,
    baselineIexMs: 0,
    recentIexMs: 0,
    improvementPct: 0,
    direction: "insufficient-data",
    profileCoveragePct: 0,
    baselineRunCount: 0,
    recentRunCount: 0,
    source: "live-window",
    ...overrides,
  };
}

function classifyImprovementDirection(improvementPct) {
  if (improvementPct >= 2) {
    return "improving";
  }
  if (improvementPct <= -2) {
    return "worsening";
  }
  return "stable";
}

function computeSelfImprovementFromLiveWindow(normalized) {
  const maxWindow = Math.min(RECENT_WINDOW_LIMIT, Math.floor(normalized.length / 2));
  if (maxWindow < SELF_TREND_MIN_WINDOW) {
    return unavailableSelfImprovement({
      windowSize: maxWindow,
      source: "live-window",
    });
  }

  const recentRuns = normalized.slice(-maxWindow);
  const baselineRuns = normalized.slice(-(maxWindow * 2), -maxWindow);
  const recentByProfile = summarizeIexByProfile(recentRuns);
  const baselineByProfile = summarizeIexByProfile(baselineRuns);

  const comparableProfiles = [...recentByProfile.keys()].filter((profile) =>
    baselineByProfile.has(profile),
  );

  let weightedBaseline = 0;
  let weightedRecent = 0;
  let weightTotal = 0;

  for (const profile of comparableProfiles) {
    const recent = recentByProfile.get(profile);
    const baseline = baselineByProfile.get(profile);
    if (!recent || !baseline) {
      continue;
    }
    const weight = recent.runs;
    weightedRecent += recent.iexMs.median * weight;
    weightedBaseline += baseline.iexMs.median * weight;
    weightTotal += weight;
  }

  const recentIexMs = weightTotal > 0 ? weightedRecent / weightTotal : 0;
  const baselineIexMs = weightTotal > 0 ? weightedBaseline / weightTotal : 0;
  const improvementPct =
    baselineIexMs > 0 ? ((baselineIexMs - recentIexMs) / baselineIexMs) * 100 : 0;

  return {
    available: weightTotal > 0,
    windowSize: maxWindow,
    baselineIexMs,
    recentIexMs,
    improvementPct,
    direction: classifyImprovementDirection(improvementPct),
    profileCoveragePct:
      recentByProfile.size > 0
        ? (comparableProfiles.length / recentByProfile.size) * 100
        : 0,
    baselineRunCount: baselineRuns.length,
    recentRunCount: recentRuns.length,
    source: "live-window",
  };
}

function computeSelfImprovementFromSnapshot(normalized, baselineSnapshot) {
  const recentWindowSize = Math.min(RECENT_WINDOW_LIMIT, normalized.length);
  if (recentWindowSize < SELF_SNAPSHOT_MIN_WINDOW) {
    return unavailableSelfImprovement({
      windowSize: 0,
      baselineRunCount: asNumber(baselineSnapshot?.runCount, 0),
      recentRunCount: recentWindowSize,
      source: "snapshot",
    });
  }

  const baselineProfiles = new Map(
    (baselineSnapshot?.profiles ?? [])
      .filter((profile) =>
        profile?.profile &&
        Number.isFinite(Number(profile?.iexMedianMs)) &&
        Number(profile?.iexMedianMs) > 0
      )
      .map((profile) => [
        profile.profile,
        {
          runs: asNumber(profile.runs, 0),
          iexMedianMs: asNumber(profile.iexMedianMs, 0),
        },
      ]),
  );

  if (baselineProfiles.size === 0) {
    return unavailableSelfImprovement({
      windowSize: 0,
      baselineRunCount: asNumber(baselineSnapshot?.runCount, 0),
      recentRunCount: recentWindowSize,
      source: "snapshot",
    });
  }

  const recentRuns = normalized.slice(-recentWindowSize);
  const recentByProfile = summarizeIexByProfile(recentRuns);
  const comparableProfiles = [...recentByProfile.keys()].filter((profile) =>
    baselineProfiles.has(profile),
  );

  let weightedBaseline = 0;
  let weightedRecent = 0;
  let weightTotal = 0;

  for (const profile of comparableProfiles) {
    const recent = recentByProfile.get(profile);
    const baseline = baselineProfiles.get(profile);
    if (!recent || !baseline) {
      continue;
    }
    const weight = recent.runs;
    weightedRecent += recent.iexMs.median * weight;
    weightedBaseline += baseline.iexMedianMs * weight;
    weightTotal += weight;
  }

  const recentIexMs = weightTotal > 0 ? weightedRecent / weightTotal : 0;
  const baselineIexMs = weightTotal > 0 ? weightedBaseline / weightTotal : 0;
  const improvementPct =
    baselineIexMs > 0 ? ((baselineIexMs - recentIexMs) / baselineIexMs) * 100 : 0;

  return {
    available: weightTotal > 0,
    windowSize: 0,
    baselineIexMs,
    recentIexMs,
    improvementPct,
    direction: classifyImprovementDirection(improvementPct),
    profileCoveragePct:
      recentByProfile.size > 0
        ? (comparableProfiles.length / recentByProfile.size) * 100
        : 0,
    baselineRunCount: asNumber(baselineSnapshot?.runCount, 0),
    recentRunCount: recentRuns.length,
    source: "snapshot",
    label: baselineSnapshot?.label ?? "baseline",
  };
}

function computeSelfImprovement(normalized, baselineSnapshot = null) {
  const liveWindow = computeSelfImprovementFromLiveWindow(normalized);
  if (liveWindow.available || !baselineSnapshot) {
    return liveWindow;
  }

  const snapshotWindow = computeSelfImprovementFromSnapshot(normalized, baselineSnapshot);
  return snapshotWindow.available ? snapshotWindow : liveWindow;
}

function classifyPerformance(ratioSeries) {
  if (ratioSeries.count === 0) {
    return "no-data";
  }
  if (ratioSeries.median < 1 && ratioSeries.p95 < 1) {
    return "strong";
  }
  if (ratioSeries.median < 1 && ratioSeries.p95 < 1.2) {
    return "good";
  }
  if (ratioSeries.median < 1 && ratioSeries.p95 >= 1.2) {
    return "volatile";
  }
  if (ratioSeries.median >= 1 && ratioSeries.p95 >= 1) {
    return "regressed";
  }
  return "mixed";
}

function computeHealth(overall, recent, outliers) {
  const slowerPenalty = (recent.slowerRuns.pct * 1.2) + (overall.slowerRuns.pct * 0.4);
  const tailPenalty =
    (Math.max(0, (recent.ratio.p95 - 1) * 100) * 1.0) +
    (Math.max(0, (overall.ratio.p95 - 1) * 100) * 0.2);
  const variancePenalty =
    (Math.max(0, recent.ratio.cvPct - 35) * 0.2) +
    (Math.max(0, overall.ratio.cvPct - 80) * 0.05);
  const outlierPenalty = Math.min(20, outliers.pct * 0.6);
  const score = clamp(100 - slowerPenalty - tailPenalty - variancePenalty - outlierPenalty, 0, 100);
  let grade = "F";
  if (score >= 90) {
    grade = "A";
  } else if (score >= 80) {
    grade = "B";
  } else if (score >= 70) {
    grade = "C";
  } else if (score >= 60) {
    grade = "D";
  }
  let healthClass = "critical";
  if (score >= 85) {
    healthClass = "stable";
  } else if (score >= 70) {
    healthClass = "watch";
  } else if (score >= 50) {
    healthClass = "risk";
  }
  return {
    score,
    grade,
    classification: healthClass,
    performanceClass: classifyPerformance(overall.ratio),
    components: {
      slowerPenalty,
      tailPenalty,
      variancePenalty,
      outlierPenalty,
    },
  };
}

function computeTrend(overall, recent) {
  const overallMedian = overall.ratio.median;
  const recentMedian = recent.ratio.median;
  const driftPct = overallMedian > 0 ? ((recentMedian - overallMedian) / overallMedian) * 100 : 0;
  let direction = "stable";
  if (driftPct >= 8) {
    direction = "worsening";
  } else if (driftPct <= -8) {
    direction = "improving";
  }
  return {
    overallMedianRatio: overallMedian,
    recentMedianRatio: recentMedian,
    driftPct,
    direction,
  };
}

function comparePct(current, baseline) {
  if (!Number.isFinite(current) || !Number.isFinite(baseline) || baseline === 0) {
    return 0;
  }
  return ((current - baseline) / baseline) * 100;
}

function safeRatio(numerator, denominator, fallback = 0) {
  if (!Number.isFinite(numerator) || !Number.isFinite(denominator) || denominator === 0) {
    return fallback;
  }
  return numerator / denominator;
}

function topSharePct(counter) {
  const values = Object.values(counter);
  if (!values.length) {
    return 0;
  }
  const total = values.reduce((sum, value) => sum + value, 0);
  if (total <= 0) {
    return 0;
  }
  const top = values.reduce((best, value) => (value > best ? value : best), 0);
  return (top / total) * 100;
}

function classifySignal(value, goodMax, warnMax) {
  if (value <= goodMax) {
    return "good";
  }
  if (value <= warnMax) {
    return "warn";
  }
  return "bad";
}

function buildSignal(key, label, value, status, read, digits = 2, unit = "") {
  return {
    key,
    label,
    value,
    status,
    read,
    display: `${asNumber(value, 0).toFixed(digits)}${unit}`,
  };
}

function buildDiagnostics({
  normalized,
  overall,
  recent,
  slowerRuns,
  slowerPhaseSharePct,
  outliers,
  byProfile,
  selfImprovement,
}) {
  const recentRuns = recent.runCount > 0 ? normalized.slice(-recent.runCount) : [];
  const recentOutlierCount = recentRuns.filter((run) => run.ratio > outliers.thresholdRatio).length;
  const recentOutlierPct = recent.runCount > 0 ? (recentOutlierCount / recent.runCount) * 100 : 0;
  const outlierSeverityPct = outliers.severityMeanPct ?? 0;
  const outlierDominancePct = topSharePct(outliers.profileCounts);
  const hotspotDominancePct = topSharePct(overall.hotspotCounts);
  const profileDispersionPct = summarizeSeries(byProfile.map((profile) => profile.ratio.median)).cvPct;
  const worstProfile = byProfile[0] ?? null;
  const slowdownDebt = summarizeSeries(
    slowerRuns.map((run) => Math.max(0, run.iexMs - run.rgMs)),
  );
  const tailSpreadAbs = overall.ratio.p95 - overall.ratio.median;
  const tailSpreadPct = safeRatio(tailSpreadAbs, overall.ratio.median) * 100;
  const medianGapToGoalPct = Math.max(0, safeRatio(overall.ratio.median - 0.5, 0.5) * 100);
  const p95GapToGoalPct = Math.max(0, safeRatio(overall.ratio.p95 - 0.5, 0.5) * 100);
  const medianGapToParityPct = Math.max(0, (overall.ratio.median - 1) * 100);
  const p95GapToParityPct = Math.max(0, (overall.ratio.p95 - 1) * 100);
  const medianMsGapToGoal = Math.max(0, overall.goalGapMs.median);
  const medianMsGapToParity = Math.max(0, overall.deltaMs.median);
  const p95MsGapToParity = Math.max(0, overall.deltaMs.p95);
  const recentMedianDriftPct = comparePct(recent.ratio.median, overall.ratio.median);
  const recentP95DriftPct = comparePct(recent.ratio.p95, overall.ratio.p95);
  const recentMeanDriftPct = comparePct(recent.ratio.mean, overall.ratio.mean);
  const recentCvDriftPct = comparePct(recent.ratio.cvPct, overall.ratio.cvPct);
  const slowerRunDriftPts = recent.slowerRuns.pct - overall.slowerRuns.pct;
  const goalHitDriftPts = recent.goalHits.pct - overall.goalHits.pct;
  const outlierDriftPts = recentOutlierPct - outliers.pct;
  const winLossRatio =
    overall.slowerRuns.count > 0
      ? overall.fasterRuns.count / overall.slowerRuns.count
      : overall.fasterRuns.count > 0
        ? 999
        : 0;
  const downsideSemideviation = Math.sqrt(
    semivarianceAbove(normalized.map((run) => run.ratio), 1),
  );
  const scanPressureDeltaPts =
    slowerPhaseSharePct.scanPct.median - overall.phaseSharePct.scanPct.median;
  const discoverPressureDeltaPts =
    slowerPhaseSharePct.discoverPct.median - overall.phaseSharePct.discoverPct.median;
  const aggregatePressureDeltaPts =
    slowerPhaseSharePct.aggregatePct.median - overall.phaseSharePct.aggregatePct.median;
  const recentScanShareDriftPts =
    recent.phaseSharePct.scanPct.median - overall.phaseSharePct.scanPct.median;
  const recentRatioRangePct = safeRatio(recent.ratio.range, recent.ratio.median) * 100;
  const recentStepJitterPct = safeRatio(recent.ratio.meanAbsDelta, recent.ratio.median) * 100;
  const recentSlopePctPerRun = safeRatio(recent.ratio.slopePerIndex, recent.ratio.median) * 100;
  const slowdownDebtMeanPctOfRg = safeRatio(slowdownDebt.mean, overall.rgMs.median) * 100;
  const recentP99DriftPct = comparePct(recent.ratio.p99, overall.ratio.p99);
  const recentMadDriftPct = comparePct(recent.ratio.mad, overall.ratio.mad);
  const recentRobustCvDriftPct = comparePct(recent.ratio.robustCvPct, overall.ratio.robustCvPct);
  const recentStepJitterDriftPct = comparePct(recent.ratio.meanAbsDelta, overall.ratio.meanAbsDelta);

  const values = {
    medianGapToGoalPct,
    p95GapToGoalPct,
    medianGapToParityPct,
    p95GapToParityPct,
    medianMsGapToGoal,
    medianMsGapToParity,
    p95MsGapToParity,
    tailSpreadAbs,
    tailSpreadPct,
    ratioIqr: overall.ratio.iqr,
    ratioP99: overall.ratio.p99,
    ratioMad: overall.ratio.mad,
    ratioRobustCvPct: overall.ratio.robustCvPct,
    ratioSkewness: overall.ratio.skewness,
    ratioStepJitterPct: safeRatio(overall.ratio.meanAbsDelta, overall.ratio.median) * 100,
    recentSlopePctPerRun,
    recentMedianDriftPct,
    recentP95DriftPct,
    recentMeanDriftPct,
    recentCvDriftPct,
    slowerRunDriftPts,
    goalHitDriftPts,
    recentOutlierPct,
    outlierDriftPts,
    outlierSeverityPct,
    outlierDominancePct,
    hotspotDominancePct,
    profileDispersionPct,
    worstProfileMedianRatio: worstProfile?.ratio?.median ?? 0,
    worstProfileGoalGapPct: worstProfile
      ? Math.max(0, safeRatio(worstProfile.ratio.median - 0.5, 0.5) * 100)
      : 0,
    winLossRatio,
    downsideSemideviation,
    slowdownDebtMeanMs: slowdownDebt.mean,
    slowdownDebtP95Ms: slowdownDebt.p95,
    slowdownDebtMeanPctOfRg,
    scanPressureDeltaPts,
    discoverPressureDeltaPts,
    aggregatePressureDeltaPts,
    recentScanShareDriftPts,
    selfImprovementPct: selfImprovement.improvementPct,
    selfProfileCoveragePct: selfImprovement.profileCoveragePct,
    recentRatioRangePct,
    recentP99DriftPct,
    recentMadDriftPct,
    recentRobustCvDriftPct,
    recentStepJitterDriftPct,
  };

  const signals = [
    buildSignal(
      "median_gap_to_goal_pct",
      "Median Gap To 50% Goal",
      values.medianGapToGoalPct,
      classifySignal(values.medianGapToGoalPct, 0, 30),
      "How far typical performance is from the >=50% speedup target.",
      2,
      "%",
    ),
    buildSignal(
      "p95_gap_to_goal_pct",
      "P95 Gap To 50% Goal",
      values.p95GapToGoalPct,
      classifySignal(values.p95GapToGoalPct, 0, 50),
      "How far tail behavior is from the >=50% speedup target.",
      2,
      "%",
    ),
    buildSignal(
      "median_gap_to_parity_pct",
      "Median Gap To Parity",
      values.medianGapToParityPct,
      classifySignal(values.medianGapToParityPct, 0, 5),
      "Typical-run slowdown above ripgrep parity. Zero is ideal or better.",
      2,
      "%",
    ),
    buildSignal(
      "p95_gap_to_parity_pct",
      "P95 Gap To Parity",
      values.p95GapToParityPct,
      classifySignal(values.p95GapToParityPct, 0, 10),
      "Tail slowdown above ripgrep parity. Zero is ideal or better.",
      2,
      "%",
    ),
    buildSignal(
      "median_ms_gap_to_goal",
      "Median ms Gap To Goal",
      values.medianMsGapToGoal,
      classifySignal(values.medianMsGapToGoal, 0, 25),
      "Milliseconds iEx still needs to cut at the median to reach the 50% target.",
      2,
      " ms",
    ),
    buildSignal(
      "median_ms_gap_to_parity",
      "Median ms Gap To Parity",
      values.medianMsGapToParity,
      classifySignal(values.medianMsGapToParity, 0, 10),
      "Milliseconds iEx still needs to cut at the median to match ripgrep.",
      2,
      " ms",
    ),
    buildSignal(
      "p95_ms_gap_to_parity",
      "P95 ms Gap To Parity",
      values.p95MsGapToParity,
      classifySignal(values.p95MsGapToParity, 0, 20),
      "Milliseconds the tail still trails ripgrep at p95.",
      2,
      " ms",
    ),
    buildSignal(
      "tail_spread_abs",
      "Tail Spread",
      values.tailSpreadAbs,
      classifySignal(values.tailSpreadAbs, 0.05, 0.2),
      "Absolute p95-minus-median ratio spread.",
      3,
      "x",
    ),
    buildSignal(
      "tail_spread_pct",
      "Tail Spread Vs Median",
      values.tailSpreadPct,
      classifySignal(values.tailSpreadPct, 10, 30),
      "Tail spread normalized against the median ratio.",
      2,
      "%",
    ),
    buildSignal(
      "ratio_iqr",
      "Ratio IQR",
      values.ratioIqr,
      classifySignal(values.ratioIqr, 0.05, 0.15),
      "Middle-50% ratio spread. Lower means tighter consistency.",
      3,
      "x",
    ),
    buildSignal(
      "ratio_p99",
      "Ratio P99",
      values.ratioP99,
      classifySignal(values.ratioP99, 1, 1.2),
      "Near-worst-case tail ratio.",
      3,
      "x",
    ),
    buildSignal(
      "ratio_mad",
      "Ratio MAD",
      values.ratioMad,
      classifySignal(values.ratioMad, 0.02, 0.08),
      "Median absolute deviation. Robust spread measure resistant to outliers.",
      3,
      "x",
    ),
    buildSignal(
      "ratio_robust_cv_pct",
      "Ratio Robust CV",
      values.ratioRobustCvPct,
      classifySignal(values.ratioRobustCvPct, 5, 15),
      "MAD-scaled coefficient of variation. Better than plain CV for noisy tails.",
      2,
      "%",
    ),
    buildSignal(
      "ratio_skewness",
      "Ratio Skewness",
      values.ratioSkewness,
      classifySignal(Math.abs(values.ratioSkewness), 0.5, 1.0),
      "Positive skew means slowdown spikes stretch the right tail.",
      2,
      "",
    ),
    buildSignal(
      "ratio_step_jitter_pct",
      "Ratio Step Jitter",
      values.ratioStepJitterPct,
      classifySignal(values.ratioStepJitterPct, 3, 8),
      "Average run-to-run ratio movement relative to the median.",
      2,
      "%",
    ),
    buildSignal(
      "recent_ratio_slope_pct_per_run",
      "Recent Ratio Slope Per Run",
      values.recentSlopePctPerRun,
      values.recentSlopePctPerRun <= 0 ? "good" : values.recentSlopePctPerRun <= 0.2 ? "warn" : "bad",
      "Positive slope means the recent window is drifting slower run by run.",
      3,
      "%",
    ),
    buildSignal(
      "recent_median_drift_pct",
      "Recent Median Drift",
      values.recentMedianDriftPct,
      values.recentMedianDriftPct <= -3 ? "good" : values.recentMedianDriftPct <= 3 ? "warn" : "bad",
      "Recent median ratio compared with the overall median ratio.",
      2,
      "%",
    ),
    buildSignal(
      "recent_p95_drift_pct",
      "Recent P95 Drift",
      values.recentP95DriftPct,
      values.recentP95DriftPct <= -5 ? "good" : values.recentP95DriftPct <= 5 ? "warn" : "bad",
      "Recent tail drift compared with the overall tail.",
      2,
      "%",
    ),
    buildSignal(
      "recent_mean_drift_pct",
      "Recent Mean Drift",
      values.recentMeanDriftPct,
      values.recentMeanDriftPct <= -3 ? "good" : values.recentMeanDriftPct <= 3 ? "warn" : "bad",
      "Recent average ratio drift versus the full window.",
      2,
      "%",
    ),
    buildSignal(
      "recent_cv_drift_pct",
      "Recent CV Drift",
      values.recentCvDriftPct,
      values.recentCvDriftPct <= -5 ? "good" : values.recentCvDriftPct <= 5 ? "warn" : "bad",
      "Recent volatility drift versus the full window.",
      2,
      "%",
    ),
    buildSignal(
      "slower_run_drift_pts",
      "Slower-Run Drift",
      values.slowerRunDriftPts,
      values.slowerRunDriftPts <= 0 ? "good" : values.slowerRunDriftPts <= 2 ? "warn" : "bad",
      "Recent slower-run rate minus overall slower-run rate.",
      2,
      " pts",
    ),
    buildSignal(
      "goal_hit_drift_pts",
      "Goal-Hit Drift",
      values.goalHitDriftPts,
      values.goalHitDriftPts >= 0 ? "good" : values.goalHitDriftPts >= -5 ? "warn" : "bad",
      "Recent >=50% goal-hit rate minus overall goal-hit rate.",
      2,
      " pts",
    ),
    buildSignal(
      "recent_outlier_pct",
      "Recent Outlier Rate",
      values.recentOutlierPct,
      classifySignal(values.recentOutlierPct, 1, 4),
      "Recent runs that exceeded the outlier threshold.",
      2,
      "%",
    ),
    buildSignal(
      "outlier_drift_pts",
      "Outlier Drift",
      values.outlierDriftPts,
      values.outlierDriftPts <= 0 ? "good" : values.outlierDriftPts <= 1 ? "warn" : "bad",
      "Recent outlier rate minus overall outlier rate.",
      2,
      " pts",
    ),
    buildSignal(
      "outlier_severity_pct",
      "Outlier Severity",
      values.outlierSeverityPct,
      classifySignal(values.outlierSeverityPct, 5, 20),
      "Average excess over the outlier threshold among flagged runs.",
      2,
      "%",
    ),
    buildSignal(
      "outlier_dominance_pct",
      "Outlier Dominance",
      values.outlierDominancePct,
      classifySignal(values.outlierDominancePct, 35, 60),
      "How concentrated outliers are inside one profile.",
      2,
      "%",
    ),
    buildSignal(
      "hotspot_dominance_pct",
      "Hotspot Dominance",
      values.hotspotDominancePct,
      classifySignal(values.hotspotDominancePct, 45, 70),
      "How concentrated runtime pressure is inside one hotspot class.",
      2,
      "%",
    ),
    buildSignal(
      "profile_dispersion_pct",
      "Profile Dispersion",
      values.profileDispersionPct,
      classifySignal(values.profileDispersionPct, 10, 25),
      "Cross-profile spread of median ratios.",
      2,
      "%",
    ),
    buildSignal(
      "worst_profile_median_ratio",
      "Worst Profile Median",
      values.worstProfileMedianRatio,
      values.worstProfileMedianRatio <= 0.75 ? "good" : values.worstProfileMedianRatio <= 1 ? "warn" : "bad",
      "Median ratio of the worst profile in the suite.",
      3,
      "x",
    ),
    buildSignal(
      "worst_profile_goal_gap_pct",
      "Worst Profile Goal Gap",
      values.worstProfileGoalGapPct,
      classifySignal(values.worstProfileGoalGapPct, 0, 40),
      "How far the worst profile is from the 50% speedup goal.",
      2,
      "%",
    ),
    buildSignal(
      "win_loss_ratio",
      "Win/Loss Ratio",
      values.winLossRatio,
      values.winLossRatio >= 3 ? "good" : values.winLossRatio >= 1 ? "warn" : "bad",
      "How many faster runs iEx earns for every slower run.",
      2,
      "x",
    ),
    buildSignal(
      "downside_semideviation",
      "Downside Semideviation",
      values.downsideSemideviation,
      classifySignal(values.downsideSemideviation, 0.02, 0.08),
      "Penalty-weighted dispersion above parity only.",
      3,
      "x",
    ),
    buildSignal(
      "slowdown_debt_mean_ms",
      "Slowdown Debt Mean",
      values.slowdownDebtMeanMs,
      classifySignal(values.slowdownDebtMeanMs, 5, 20),
      "Average extra milliseconds iEx pays on runs where it loses.",
      2,
      " ms",
    ),
    buildSignal(
      "slowdown_debt_p95_ms",
      "Slowdown Debt P95",
      values.slowdownDebtP95Ms,
      classifySignal(values.slowdownDebtP95Ms, 10, 40),
      "P95 extra milliseconds iEx pays on losing runs.",
      2,
      " ms",
    ),
    buildSignal(
      "slowdown_debt_mean_pct_of_rg",
      "Slowdown Debt Vs rg",
      values.slowdownDebtMeanPctOfRg,
      classifySignal(values.slowdownDebtMeanPctOfRg, 5, 20),
      "Average losing-run debt normalized against ripgrep median time.",
      2,
      "%",
    ),
    buildSignal(
      "scan_pressure_delta_pts",
      "Scan Pressure Delta",
      values.scanPressureDeltaPts,
      classifySignal(values.scanPressureDeltaPts, 5, 15),
      "Extra scan-share concentration in slower runs versus all runs.",
      2,
      " pts",
    ),
    buildSignal(
      "discover_pressure_delta_pts",
      "Discover Pressure Delta",
      values.discoverPressureDeltaPts,
      classifySignal(values.discoverPressureDeltaPts, 5, 15),
      "Extra discover-share concentration in slower runs versus all runs.",
      2,
      " pts",
    ),
    buildSignal(
      "aggregate_pressure_delta_pts",
      "Aggregate Pressure Delta",
      values.aggregatePressureDeltaPts,
      classifySignal(values.aggregatePressureDeltaPts, 5, 15),
      "Extra aggregate-share concentration in slower runs versus all runs.",
      2,
      " pts",
    ),
    buildSignal(
      "recent_scan_share_drift_pts",
      "Recent Scan Share Drift",
      values.recentScanShareDriftPts,
      values.recentScanShareDriftPts <= 0 ? "good" : values.recentScanShareDriftPts <= 3 ? "warn" : "bad",
      "Recent scan-share median minus overall scan-share median.",
      2,
      " pts",
    ),
    buildSignal(
      "self_improvement_pct",
      "Self Improvement",
      values.selfImprovementPct,
      values.selfImprovementPct > 0 ? "good" : values.selfImprovementPct === 0 ? "warn" : "bad",
      "Recent iEx median time versus the prior iEx baseline window.",
      2,
      "%",
    ),
    buildSignal(
      "self_profile_coverage_pct",
      "Self Profile Coverage",
      values.selfProfileCoveragePct,
      values.selfProfileCoveragePct >= 90 ? "good" : values.selfProfileCoveragePct >= 70 ? "warn" : "bad",
      "How much of the recent profile mix is comparable to the self-baseline window.",
      2,
      "%",
    ),
    buildSignal(
      "recent_ratio_range_pct",
      "Recent Ratio Range",
      values.recentRatioRangePct,
      classifySignal(values.recentRatioRangePct, 20, 60),
      "Recent max-min ratio spread normalized against the recent median.",
      2,
      "%",
    ),
    buildSignal(
      "recent_p99_drift_pct",
      "Recent P99 Drift",
      values.recentP99DriftPct,
      values.recentP99DriftPct <= -5 ? "good" : values.recentP99DriftPct <= 5 ? "warn" : "bad",
      "Recent near-worst-case drift compared with the overall p99.",
      2,
      "%",
    ),
    buildSignal(
      "recent_mad_drift_pct",
      "Recent MAD Drift",
      values.recentMadDriftPct,
      values.recentMadDriftPct <= -5 ? "good" : values.recentMadDriftPct <= 5 ? "warn" : "bad",
      "Recent robust spread drift versus the overall MAD.",
      2,
      "%",
    ),
    buildSignal(
      "recent_robust_cv_drift_pct",
      "Recent Robust CV Drift",
      values.recentRobustCvDriftPct,
      values.recentRobustCvDriftPct <= -5 ? "good" : values.recentRobustCvDriftPct <= 5 ? "warn" : "bad",
      "Recent robust volatility drift versus the full window.",
      2,
      "%",
    ),
    buildSignal(
      "recent_step_jitter_drift_pct",
      "Recent Step Jitter Drift",
      values.recentStepJitterDriftPct,
      values.recentStepJitterDriftPct <= -5 ? "good" : values.recentStepJitterDriftPct <= 5 ? "warn" : "bad",
      "Recent run-to-run movement drift versus the full window.",
      2,
      "%",
    ),
  ];

  return {
    values,
    signals,
    worstProfile,
  };
}

function buildHints({
  totalRuns,
  overall,
  recent,
  outliers,
  trend,
  slowerRuns,
  selfImprovement,
  byProfile,
  diagnostics,
  primaryChallenger,
}) {
  const hints = [];
  const severityRank = {
    high: 0,
    medium: 1,
    info: 2,
  };

  function pushHint(entry) {
    if (hints.some((hint) => hint.title === entry.title)) {
      return;
    }
    hints.push({
      priority: entry.priority ?? 50,
      ...entry,
    });
  }

  const values = diagnostics?.values ?? {};
  const worstProfile = diagnostics?.worstProfile ?? null;

  if (primaryChallenger && primaryChallenger.iexRatio.median > 1) {
    pushHint({
      severity: primaryChallenger.iexRatio.median > 1.1 ? "high" : "medium",
      priority: 93,
      title: `${primaryChallenger.name} leads on median`,
      hint: `Treat ${primaryChallenger.name} as the active external target on this harness until iEx wins typical latency again.`,
      why: `Median iEx/${primaryChallenger.name} ratio is ${primaryChallenger.iexRatio.median.toFixed(3)}x across ${primaryChallenger.availableRuns} measured runs.`,
    });
  }

  if (primaryChallenger && primaryChallenger.iexRatio.p95 < 1) {
    pushHint({
      severity: "info",
      priority: 25,
      title: `iEx still owns tail vs ${primaryChallenger.name}`,
      hint: "Keep the stability advantage while closing the median gap.",
      why: `P95 iEx/${primaryChallenger.name} ratio is ${primaryChallenger.iexRatio.p95.toFixed(3)}x.`,
    });
  }

  if (totalRuns < 15) {
    pushHint({
      severity: "high",
      priority: 100,
      title: "Sample size too small",
      hint: "Do not trust this benchmark window yet. Run at least 30 iterations first.",
      why: `Current run count is ${totalRuns}. This is below the minimum stability floor for reliable tail analysis.`,
    });
  } else if (totalRuns < 30) {
    pushHint({
      severity: "info",
      priority: 30,
      title: "Low sample size",
      hint: "Collect at least 30-50 runs before trusting p95 stability.",
      why: `Current run count is ${totalRuns}. Tail percentiles are noisy under small samples.`,
    });
  }

  if (overall.ratio.median >= 1) {
    pushHint({
      severity: "high",
      priority: 98,
      title: "Median parity lost",
      hint: "Treat this as a blocking regression. Prioritize median scan-path optimizations first.",
      why: `Median ratio is ${overall.ratio.median.toFixed(3)}x, so iEx is slower than ripgrep on typical runs.`,
    });
  }

  if (overall.ratio.median > 0.5) {
    pushHint({
      severity: overall.ratio.median > 0.9 ? "high" : "medium",
      priority: 96,
      title: "Median speedup target is not met",
      hint: "For a sustained >=50% speedup claim, drive median ratio to <=0.500x across the active suite.",
      why: `Current median ratio is ${overall.ratio.median.toFixed(3)}x (${((1 - overall.ratio.median) * 100).toFixed(2)}% faster).`,
    });
  }

  if (recent.ratio.median >= 1) {
    pushHint({
      severity: "high",
      priority: 92,
      title: "Recent median is regressing",
      hint: "Focus on the latest code/config deltas and replay the last 100-run window in isolation.",
      why: `Recent median ratio is ${recent.ratio.median.toFixed(3)}x, indicating current behavior is slower than parity.`,
    });
  }

  if (overall.ratio.p95 > 1) {
    pushHint({
      severity: "high",
      priority: 97,
      title: "Tail regressions exist",
      hint: "Inspect top slowdown outliers first, then profile scan/discover hotspots.",
      why: `P95 ratio is ${overall.ratio.p95.toFixed(3)}x, which means slow tail runs remain.`,
    });
  }

  if (values.p95GapToGoalPct > 0) {
    pushHint({
      severity: values.p95GapToGoalPct > 75 ? "high" : "medium",
      priority: 88,
      title: "Tail still misses the 50% goal",
      hint: "Median wins are not enough. Push tail paths until p95 also clears the target.",
      why: `P95 is still ${values.p95GapToGoalPct.toFixed(2)}% away from the >=50% speedup goal.`,
    });
  }

  const tailGap = overall.ratio.p95 - overall.ratio.median;
  if (tailGap > 0.4) {
    pushHint({
      severity: tailGap > 1 ? "high" : "medium",
      priority: 85,
      title: "Tail spread is wide",
      hint: "Investigate run-to-run instability; median and tail are diverging too much.",
      why: `P95-median gap is ${tailGap.toFixed(3)}x (${overall.ratio.median.toFixed(3)}x -> ${overall.ratio.p95.toFixed(3)}x).`,
    });
  }

  if (values.tailSpreadPct > 35) {
    pushHint({
      severity: values.tailSpreadPct > 80 ? "high" : "medium",
      priority: 82,
      title: "Tail amplification is high",
      hint: "The slow tail grows much faster than the median. Hunt for intermittent branch or cache misses.",
      why: `Tail spread is ${values.tailSpreadPct.toFixed(2)}% of the median ratio.`,
    });
  }

  if (overall.ratio.p99 > 1.1) {
    pushHint({
      severity: overall.ratio.p99 > 1.5 ? "high" : "medium",
      priority: 80,
      title: "Extreme slow spikes exist",
      hint: "Inspect p99 cases and isolate what only happens in the worst 1% of runs.",
      why: `P99 ratio is ${overall.ratio.p99.toFixed(3)}x.`,
    });
  }

  if (overall.slowerRuns.pct > 8) {
    pushHint({
      severity: "high",
      priority: 95,
      title: "Too many slower runs",
      hint: "Treat this as a consistency issue, not a single-run anomaly.",
      why: `${overall.slowerRuns.pct.toFixed(2)}% of runs are slower than ripgrep.`,
    });
  }

  if (overall.slowerRuns.pct > 1 && overall.slowerRuns.pct <= 8) {
    pushHint({
      severity: "medium",
      priority: 76,
      title: "Consistency still leaks slower runs",
      hint: "Chase the remaining parity misses until slower-run rate approaches zero.",
      why: `${overall.slowerRuns.pct.toFixed(2)}% of runs still lose to ripgrep.`,
    });
  }

  const recentSlowerSpike = recent.slowerRuns.pct - overall.slowerRuns.pct;
  if (recentSlowerSpike >= 5) {
    pushHint({
      severity: "high",
      priority: 89,
      title: "Recent slower-run spike",
      hint: "Current loop conditions are degrading. Compare recent runs against a known-good baseline capture.",
      why: `Recent slower-run rate is ${recent.slowerRuns.pct.toFixed(2)}% vs ${overall.slowerRuns.pct.toFixed(2)}% overall (+${recentSlowerSpike.toFixed(2)} pts).`,
    });
  }

  if (values.slowerRunDriftPts <= -2) {
    pushHint({
      severity: "info",
      priority: 22,
      title: "Recent slower-run rate improved",
      hint: "Keep the current runtime conditions and verify the improvement survives a longer loop.",
      why: `Recent slower-run rate improved by ${Math.abs(values.slowerRunDriftPts).toFixed(2)} points versus overall.`,
    });
  }

  const volatilityAlert = Math.max(recent.ratio.cvPct, overall.ratio.cvPct);
  if (volatilityAlert > 40) {
    pushHint({
      severity: volatilityAlert > 80 ? "high" : "medium",
      priority: 78,
      title: "Volatility is elevated",
      hint: "Lock runtime conditions and isolate the noisiest profile to reduce benchmark jitter.",
      why: `Recent CV is ${recent.ratio.cvPct.toFixed(2)}% and overall CV is ${overall.ratio.cvPct.toFixed(2)}%.`,
    });
  }

  if (overall.ratio.robustCvPct > 15) {
    pushHint({
      severity: overall.ratio.robustCvPct > 25 ? "high" : "medium",
      priority: 74,
      title: "Robust volatility is elevated",
      hint: "Even after discounting outliers, the core distribution is still noisy. Tighten the steady-state path.",
      why: `Robust CV is ${overall.ratio.robustCvPct.toFixed(2)}%.`,
    });
  }

  if (values.ratioStepJitterPct > 8) {
    pushHint({
      severity: values.ratioStepJitterPct > 15 ? "high" : "medium",
      priority: 68,
      title: "Run-to-run jitter is high",
      hint: "Look for branch instability, cold-path churn, or corpus-order sensitivity.",
      why: `Average step jitter is ${values.ratioStepJitterPct.toFixed(2)}% of the median ratio.`,
    });
  }

  if (values.recentStepJitterDriftPct > 10) {
    pushHint({
      severity: values.recentStepJitterDriftPct > 25 ? "high" : "medium",
      priority: 64,
      title: "Recent jitter is worsening",
      hint: "The last window is oscillating more than the full run history. Compare with the last known smooth segment.",
      why: `Recent step jitter drift is +${values.recentStepJitterDriftPct.toFixed(2)}%.`,
    });
  }

  if (outliers.count > 0) {
    pushHint({
      severity: outliers.pct >= 5 ? "high" : "medium",
      priority: 83,
      title: "Outlier budget exceeded",
      hint: "Triage outliers by profile and isolate the dominant profile in a focused replay loop.",
      why: `${outliers.count} runs exceeded the outlier threshold (${outliers.thresholdRatio.toFixed(3)}x). Dominant profile: ${outliers.dominantProfile}.`,
    });
  }

  if (values.recentOutlierPct > 2) {
    pushHint({
      severity: values.recentOutlierPct > 5 ? "high" : "medium",
      priority: 72,
      title: "Recent outlier rate is elevated",
      hint: "The current loop still produces too many threshold-breaking runs. Reproduce the recent segment in isolation.",
      why: `Recent outlier rate is ${values.recentOutlierPct.toFixed(2)}%.`,
    });
  }

  if (values.outlierDriftPts > 0.5) {
    pushHint({
      severity: values.outlierDriftPts > 2 ? "high" : "medium",
      priority: 69,
      title: "Recent outlier drift is worsening",
      hint: "Outliers are not just present, they are becoming more frequent in the newest window.",
      why: `Recent outlier rate is up by ${values.outlierDriftPts.toFixed(2)} points versus overall.`,
    });
  }

  if (values.outlierSeverityPct > 10) {
    pushHint({
      severity: values.outlierSeverityPct > 30 ? "high" : "medium",
      priority: 75,
      title: "Outliers are too severe",
      hint: "Fix the magnitude of bad runs, not only the count. The rare failures are still expensive.",
      why: `Average outlier excess is ${values.outlierSeverityPct.toFixed(2)}% above threshold.`,
    });
  }

  if (values.outlierDominancePct > 50) {
    pushHint({
      severity: values.outlierDominancePct > 75 ? "high" : "medium",
      priority: 71,
      title: "Outliers are concentrated in one profile",
      hint: "Target the dominant failing profile first; fixing it will collapse a disproportionate share of instability.",
      why: `${values.outlierDominancePct.toFixed(2)}% of outliers come from the same profile (${outliers.dominantProfile}).`,
    });
  }

  if (slowerRuns.dominantPhaseByMedianShare === "scan") {
    const scanShare = slowerRuns.phaseSharePct?.scanPct?.median ?? 0;
    pushHint({
      severity: "medium",
      priority: 84,
      title: "Scan-phase pressure",
      hint: "Focus optimization on predicate selectivity and scan loop throughput.",
      why: `Slow runs are dominated by scan time share (${scanShare.toFixed(2)}% median share).`,
    });
  }

  if (slowerRuns.dominantPhaseByMedianShare === "discover") {
    const discoverShare = slowerRuns.phaseSharePct?.discoverPct?.median ?? 0;
    pushHint({
      severity: "medium",
      priority: 62,
      title: "Discover-phase pressure",
      hint: "Directory traversal or file selection is dominating slow runs. Tighten narrowing before scan starts.",
      why: `Slow runs are dominated by discover time share (${discoverShare.toFixed(2)}% median share).`,
    });
  }

  if (slowerRuns.dominantPhaseByMedianShare === "aggregate") {
    const aggregateShare = slowerRuns.phaseSharePct?.aggregatePct?.median ?? 0;
    pushHint({
      severity: "medium",
      priority: 61,
      title: "Aggregate-phase pressure",
      hint: "Result materialization is dominating slow runs. Reduce output or aggregation overhead.",
      why: `Slow runs are dominated by aggregate time share (${aggregateShare.toFixed(2)}% median share).`,
    });
  }

  if (values.scanPressureDeltaPts > 10) {
    pushHint({
      severity: values.scanPressureDeltaPts > 20 ? "high" : "medium",
      priority: 79,
      title: "Scan pressure sharply exceeds baseline",
      hint: "Slower runs spend much more time in scan than the suite average. This is likely the primary optimization lane.",
      why: `Scan pressure delta is +${values.scanPressureDeltaPts.toFixed(2)} points.`,
    });
  }

  if (values.discoverPressureDeltaPts > 10) {
    pushHint({
      severity: values.discoverPressureDeltaPts > 20 ? "high" : "medium",
      priority: 57,
      title: "Discover pressure sharply exceeds baseline",
      hint: "Slow runs overpay before matching begins. Revisit traversal, filtering, and file admission rules.",
      why: `Discover pressure delta is +${values.discoverPressureDeltaPts.toFixed(2)} points.`,
    });
  }

  if (values.aggregatePressureDeltaPts > 10) {
    pushHint({
      severity: values.aggregatePressureDeltaPts > 20 ? "high" : "medium",
      priority: 56,
      title: "Aggregate pressure sharply exceeds baseline",
      hint: "Slow runs are spending extra time after scanning. Check match materialization and output formatting.",
      why: `Aggregate pressure delta is +${values.aggregatePressureDeltaPts.toFixed(2)} points.`,
    });
  }

  if (values.recentScanShareDriftPts > 3) {
    pushHint({
      severity: values.recentScanShareDriftPts > 8 ? "high" : "medium",
      priority: 58,
      title: "Recent scan share is rising",
      hint: "The latest window is getting more scan-heavy than the full history. Inspect recent scan-path changes first.",
      why: `Recent scan share drift is +${values.recentScanShareDriftPts.toFixed(2)} points.`,
    });
  }

  if (trend.direction === "worsening") {
    pushHint({
      severity: "medium",
      priority: 73,
      title: "Recent trend is worsening",
      hint: "Compare recent run config/environment against earlier good windows.",
      why: `Recent median ratio drifted by +${trend.driftPct.toFixed(2)}% vs overall median.`,
    });
  }

  if (values.recentSlopePctPerRun > 0.2) {
    pushHint({
      severity: values.recentSlopePctPerRun > 1 ? "high" : "medium",
      priority: 70,
      title: "Recent ratio slope is positive",
      hint: "The newest runs are trending slower run by run. Treat this as an active regression, not background noise.",
      why: `Recent ratio slope is +${values.recentSlopePctPerRun.toFixed(3)}% per run.`,
    });
  }

  if (values.recentP95DriftPct > 5) {
    pushHint({
      severity: values.recentP95DriftPct > 20 ? "high" : "medium",
      priority: 67,
      title: "Recent tail drift is worsening",
      hint: "Tail behavior is degrading faster than the headline median. Replay the newest slow runs first.",
      why: `Recent p95 drift is +${values.recentP95DriftPct.toFixed(2)}%.`,
    });
  }

  if (values.recentMeanDriftPct > 3) {
    pushHint({
      severity: values.recentMeanDriftPct > 10 ? "high" : "medium",
      priority: 63,
      title: "Recent average speed is worsening",
      hint: "The full recent window is slowing, not just a few outliers.",
      why: `Recent mean drift is +${values.recentMeanDriftPct.toFixed(2)}%.`,
    });
  }

  if (values.recentCvDriftPct > 5) {
    pushHint({
      severity: values.recentCvDriftPct > 20 ? "high" : "medium",
      priority: 60,
      title: "Recent volatility drift is worsening",
      hint: "Benchmark noise is rising in the newest window. Lock the environment before judging code changes.",
      why: `Recent CV drift is +${values.recentCvDriftPct.toFixed(2)}%.`,
    });
  }

  if (values.recentP99DriftPct > 5) {
    pushHint({
      severity: values.recentP99DriftPct > 20 ? "high" : "medium",
      priority: 59,
      title: "Recent extreme tail is worsening",
      hint: "Worst-case runs are degrading even if the median looks stable. Study the newest p99 offenders.",
      why: `Recent p99 drift is +${values.recentP99DriftPct.toFixed(2)}%.`,
    });
  }

  if (values.recentMadDriftPct > 5) {
    pushHint({
      severity: values.recentMadDriftPct > 20 ? "high" : "medium",
      priority: 54,
      title: "Core spread is worsening",
      hint: "The central distribution is broadening, which points to a real steady-state regression.",
      why: `Recent MAD drift is +${values.recentMadDriftPct.toFixed(2)}%.`,
    });
  }

  if (values.recentRobustCvDriftPct > 5) {
    pushHint({
      severity: values.recentRobustCvDriftPct > 20 ? "high" : "medium",
      priority: 53,
      title: "Robust volatility drift is worsening",
      hint: "Even the outlier-resistant volatility signal is rising. This usually means the core path changed.",
      why: `Recent robust CV drift is +${values.recentRobustCvDriftPct.toFixed(2)}%.`,
    });
  }

  if (selfImprovement.available && selfImprovement.improvementPct < 0) {
    pushHint({
      severity: selfImprovement.improvementPct <= -5 ? "high" : "medium",
      priority: 87,
      title: "iEx regressing against itself",
      hint: "The latest iEx build is slower than its own recent baseline. Inspect recent code paths before tuning benchmarks.",
      why: `Self-improvement is ${selfImprovement.improvementPct.toFixed(2)}% (${selfImprovement.baselineIexMs.toFixed(2)}ms -> ${selfImprovement.recentIexMs.toFixed(2)}ms).`,
    });
  }

  if (selfImprovement.available && selfImprovement.profileCoveragePct < 70) {
    pushHint({
      severity: "medium",
      priority: 45,
      title: "Self-improvement coverage is thin",
      hint: "Expand profile mix in the loop before trusting iEx-vs-iEx trend conclusions.",
      why: `Only ${selfImprovement.profileCoveragePct.toFixed(2)}% of recent profiles were comparable to the baseline window.`,
    });
  }

  const topRegressedProfile = byProfile.find((profile) => profile.ratio.median > 1);
  if (topRegressedProfile) {
    pushHint({
      severity: topRegressedProfile.runs >= 5 ? "high" : "medium",
      priority: 86,
      title: "Profile-specific regression hotspot",
      hint: `Prioritize targeted replay for ${topRegressedProfile.profile}; it is dragging global parity down.`,
      why: `${topRegressedProfile.profile} median ratio is ${topRegressedProfile.ratio.median.toFixed(3)}x across ${topRegressedProfile.runs} runs (dominant phase: ${topRegressedProfile.dominantPhaseByMedianShare}).`,
    });
  }

  if (values.profileDispersionPct > 20) {
    pushHint({
      severity: values.profileDispersionPct > 40 ? "high" : "medium",
      priority: 65,
      title: "Profile behavior is too uneven",
      hint: "The suite is not failing uniformly. One or two workloads are much weaker than the rest.",
      why: `Profile dispersion is ${values.profileDispersionPct.toFixed(2)}%.`,
    });
  }

  if (worstProfile && values.worstProfileGoalGapPct > 25) {
    pushHint({
      severity: values.worstProfileGoalGapPct > 100 ? "high" : "medium",
      priority: 66,
      title: "Worst profile is far from target",
      hint: `Work the ${worstProfile.profile} profile as its own optimization lane until it stops dominating the suite risk.`,
      why: `${worstProfile.profile} is ${values.worstProfileGoalGapPct.toFixed(2)}% away from the 50% speedup goal.`,
    });
  }

  if (values.winLossRatio < 1.5) {
    pushHint({
      severity: values.winLossRatio < 1 ? "high" : "medium",
      priority: 77,
      title: "Win/loss ratio is weak",
      hint: "iEx needs more reliable wins per loss before the suite can be called strong.",
      why: `Current win/loss ratio is ${values.winLossRatio.toFixed(2)}x.`,
    });
  }

  if (values.downsideSemideviation > 0.05) {
    pushHint({
      severity: values.downsideSemideviation > 0.12 ? "high" : "medium",
      priority: 55,
      title: "Downside risk remains elevated",
      hint: "Losing runs are not only frequent enough to matter, they are materially far above parity.",
      why: `Downside semideviation is ${values.downsideSemideviation.toFixed(3)}x.`,
    });
  }

  if (values.slowdownDebtMeanMs > 10) {
    pushHint({
      severity: values.slowdownDebtMeanMs > 40 ? "high" : "medium",
      priority: 52,
      title: "Slowdown debt is meaningful",
      hint: "When iEx loses, it loses by enough milliseconds to justify targeted debt paydown work.",
      why: `Average losing-run debt is ${values.slowdownDebtMeanMs.toFixed(2)}ms.`,
    });
  }

  if (values.slowdownDebtP95Ms > 25) {
    pushHint({
      severity: values.slowdownDebtP95Ms > 75 ? "high" : "medium",
      priority: 51,
      title: "Tail slowdown debt is expensive",
      hint: "The worst losing runs are carrying heavy debt. Fixing only the median will leave visible latency cliffs.",
      why: `P95 losing-run debt is ${values.slowdownDebtP95Ms.toFixed(2)}ms.`,
    });
  }

  if (values.slowdownDebtMeanPctOfRg > 10) {
    pushHint({
      severity: values.slowdownDebtMeanPctOfRg > 30 ? "high" : "medium",
      priority: 49,
      title: "Losses are large relative to rg",
      hint: "The losing path is not narrowly behind; it is materially oversized relative to ripgrep runtime.",
      why: `Average losing-run debt equals ${values.slowdownDebtMeanPctOfRg.toFixed(2)}% of ripgrep median time.`,
    });
  }

  if (values.hotspotDominancePct > 70) {
    pushHint({
      severity: values.hotspotDominancePct > 85 ? "high" : "medium",
      priority: 48,
      title: "One hotspot dominates the suite",
      hint: "A single hotspot class explains most pressure. Fix that lane before spreading effort.",
      why: `${values.hotspotDominancePct.toFixed(2)}% of hotspot observations fall into the same class.`,
    });
  }

  if (overall.goalHits.pct < 90) {
    pushHint({
      severity: overall.goalHits.pct < 50 ? "high" : "medium",
      priority: 90,
      title: "Goal-hit coverage is weak",
      hint: "Raise consistency before claiming sustained performance superiority.",
      why: `Only ${overall.goalHits.pct.toFixed(2)}% of runs hit the >=50% speedup goal.`,
    });
  }

  if (overall.goalHits.count === 0) {
    pushHint({
      severity: "high",
      priority: 91,
      title: "No runs hit the 50% goal",
      hint: "The suite currently lacks proof that the target is reachable under present conditions.",
      why: "Zero runs in the current window cleared the >=50% speedup threshold.",
    });
  }

  if (values.goalHitDriftPts < 0) {
    pushHint({
      severity: values.goalHitDriftPts < -5 ? "high" : "medium",
      priority: 47,
      title: "Goal-hit trend is slipping",
      hint: "Recent runs are clearing the target less often than the overall window.",
      why: `Recent goal-hit drift is ${values.goalHitDriftPts.toFixed(2)} points.`,
    });
  }

  if (recent.ratio.p95 < overall.ratio.p95) {
    pushHint({
      severity: "info",
      priority: 28,
      title: "Recent tail improved",
      hint: "Keep current runtime conditions while reproducing older outliers in isolation.",
      why: `Recent p95 (${recent.ratio.p95.toFixed(3)}x) is lower than overall p95 (${overall.ratio.p95.toFixed(3)}x).`,
    });
  }

  if (values.outlierDriftPts <= -1) {
    pushHint({
      severity: "info",
      priority: 26,
      title: "Recent outlier rate improved",
      hint: "The newest window is cleaner than the broader history. Preserve the same conditions for confirmation.",
      why: `Recent outlier rate improved by ${Math.abs(values.outlierDriftPts).toFixed(2)} points.`,
    });
  }

  if (selfImprovement.available && selfImprovement.improvementPct > 2) {
    pushHint({
      severity: "info",
      priority: 24,
      title: "iEx is improving against itself",
      hint: "Recent code/runtime changes are helping. Keep validating that the gain also holds against ripgrep.",
      why: `Self-improvement is +${selfImprovement.improvementPct.toFixed(2)}%.`,
    });
  }

  if (values.medianGapToGoalPct > 0 && values.medianGapToGoalPct <= 15) {
    pushHint({
      severity: "info",
      priority: 27,
      title: "Median is within striking distance of target",
      hint: "A focused round on the dominant hotspot could push the median through the 50% goal.",
      why: `Median goal gap is down to ${values.medianGapToGoalPct.toFixed(2)}%.`,
    });
  }

  return hints
    .slice()
    .sort((left, right) => {
      const severityDelta = severityRank[left.severity] - severityRank[right.severity];
      if (severityDelta !== 0) {
        return severityDelta;
      }
      return right.priority - left.priority;
    })
    .slice(0, MAX_HINTS);
}

export const METRIC_INDEX = [
  {
    key: "ratio",
    label: "Ratio (iEx/rg)",
    read: "< 1.0 means iEx faster; > 1.0 means iEx slower.",
  },
  {
    key: "median",
    label: "Median Ratio",
    read: "Typical run speed. Use this as the headline baseline.",
  },
  {
    key: "p95",
    label: "P95 Ratio",
    read: "Tail behavior. High p95 means occasional bad slowdowns.",
  },
  {
    key: "slower_runs",
    label: "Slower Runs %",
    read: "How often iEx loses to ripgrep. Lower is better.",
  },
  {
    key: "outlier_budget",
    label: "Outlier Budget",
    read: "Runs above Tukey threshold (Q3 + 1.5*IQR). Shows instability spikes.",
  },
  {
    key: "dominant_phase",
    label: "Dominant Slow Phase",
    read: "Which phase (discover/scan/aggregate) dominates slow runs.",
  },
  {
    key: "health",
    label: "Health Score",
    read: "Composite score from slower %, p95 tail, variance, and outlier load.",
  },
  {
    key: "trend",
    label: "Recent Drift",
    read: "Recent median vs overall median. Negative drift is improving.",
  },
  {
    key: "self_improvement",
    label: "Self Improvement %",
    read: "iEx recent median runtime vs earlier iEx median runtime (profile-normalized). Positive means iEx improved against itself.",
  },
  {
    key: "goal_gap",
    label: "Goal Gap",
    read: "Distance from the >=50% speedup target. Lower is better; zero means the target is met.",
  },
  {
    key: "tail_spread",
    label: "Tail Spread",
    read: "Difference between p95 and median. Large spread means intermittent slow paths or instability.",
  },
  {
    key: "robust_cv",
    label: "Robust CV",
    read: "Outlier-resistant volatility using MAD instead of standard deviation.",
  },
  {
    key: "step_jitter",
    label: "Step Jitter",
    read: "Average run-to-run movement. High jitter means the loop is oscillating instead of staying steady.",
  },
  {
    key: "recent_slope",
    label: "Recent Slope",
    read: "Per-run direction of the recent window. Positive means the newest runs are trending slower.",
  },
  {
    key: "outlier_severity",
    label: "Outlier Severity",
    read: "How far outliers overshoot the threshold on average, not just how many there are.",
  },
  {
    key: "profile_dispersion",
    label: "Profile Dispersion",
    read: "How uneven performance is across benchmark profiles. High dispersion usually means one workload needs focused work.",
  },
  {
    key: "slowdown_debt",
    label: "Slowdown Debt",
    read: "Extra milliseconds iEx pays on losing runs. Useful for estimating practical optimization payoff.",
  },
  {
    key: "phase_pressure_delta",
    label: "Phase Pressure Delta",
    read: "How much more one phase dominates slower runs compared with the overall suite mix.",
  },
];

export function summarizeHistory(history, options = {}) {
  const normalized = history.map(withDerived);
  const baselineSnapshot = options?.baselineSnapshot ?? null;
  const slowerRuns = normalized.filter((run) => run.ratio > 1);
  const slowerHotspots = toCounterMap(slowerRuns.map((run) => run.hotspot));
  const competitorSummary = summarizeCompetitors(normalized);
  const primaryChallenger = pickPrimaryChallenger(competitorSummary);

  const grouped = new Map();
  for (const run of normalized) {
    const key = run.profile ?? "unknown";
    const runs = grouped.get(key) ?? [];
    runs.push(run);
    grouped.set(key, runs);
  }

  const byProfile = [...grouped.entries()]
    .map(([profile, runs]) => summarizeProfile(profile, runs))
    .sort((left, right) => right.ratio.median - left.ratio.median);

  const overall = summarizeRunSet(normalized);
  const recentWindowSize = Math.min(RECENT_WINDOW_LIMIT, normalized.length);
  const recentRuns = recentWindowSize > 0 ? normalized.slice(-recentWindowSize) : [];
  const recent = summarizeRunSet(recentRuns);
  const outliers = buildOutlierSummary(normalized, overall.ratio);
  const trend = computeTrend(overall, recent);
  const selfImprovement = computeSelfImprovement(normalized, baselineSnapshot);
  const slowerPhaseSharePct = {
    discoverPct: summarizeSeries(slowerRuns.map((run) => run.phaseShare.discoverPct)),
    scanPct: summarizeSeries(slowerRuns.map((run) => run.phaseShare.scanPct)),
    aggregatePct: summarizeSeries(slowerRuns.map((run) => run.phaseShare.aggregatePct)),
  };
  const diagnostics = buildDiagnostics({
    normalized,
    overall,
    recent,
    slowerRuns,
    slowerPhaseSharePct,
    outliers,
    byProfile,
    selfImprovement,
  });
  const health = computeHealth(overall, recent, outliers);
  const firstRun = normalized[0] ?? null;
  const lastRun = normalized[normalized.length - 1] ?? null;
  const firstSlow = slowerRuns[0] ?? null;
  const lastSlow = slowerRuns[slowerRuns.length - 1] ?? null;
  const slowdownTimeline = slowerRuns
    .slice()
    .sort((left, right) => right.ratio - left.ratio)
    .slice(0, 25)
    .map((run) => ({
      runId: run.runId,
      timestamp: run.timestamp,
      profile: run.profile,
      ratio: run.ratio,
      speedupPct: run.speedupPct,
      hotspot: run.hotspot,
      phaseMs: run.phaseMs,
    }));

  const hints = buildHints({
    totalRuns: normalized.length,
    overall,
    recent,
    outliers,
    trend,
    slowerRuns: {
      dominantPhaseByMedianShare: overall.dominantPhaseByMedianShare,
      phaseSharePct: slowerPhaseSharePct,
    },
    selfImprovement,
    byProfile,
    diagnostics,
    primaryChallenger,
  });

  return {
    generatedAt: new Date().toISOString(),
    runCount: normalized.length,
    window: {
      startTimestamp: firstRun?.timestamp ?? null,
      endTimestamp: lastRun?.timestamp ?? null,
      recentWindowSize,
    },
    latest: lastRun
      ? {
          runId: lastRun.runId,
          timestamp: lastRun.timestamp,
          profile: lastRun.profile,
          ratio: lastRun.ratio,
          speedupPct: lastRun.speedupPct,
          hotspot: lastRun.hotspot,
        }
      : null,
    ratio: overall.ratio,
    speedupPct: overall.speedupPct,
    phaseMs: overall.phaseMs,
    slowerRuns: {
      count: overall.slowerRuns.count,
      pct: overall.slowerRuns.pct,
      firstTimestamp: firstSlow?.timestamp ?? null,
      lastTimestamp: lastSlow?.timestamp ?? null,
      ratio: summarizeSeries(slowerRuns.map((run) => run.ratio)),
      hotspotCounts: slowerHotspots,
      dominantHotspot: dominantFromCounter(slowerHotspots),
      dominantPhaseByMedianShare: overall.dominantPhaseByMedianShare,
      phaseSharePct: slowerPhaseSharePct,
    },
    fasterRuns: overall.fasterRuns,
    tieRuns: overall.tieRuns,
    goalHits: overall.goalHits,
    hotspotCounts: overall.hotspotCounts,
    dominantHotspot: overall.dominantHotspot,
    byProfile,
    slowdownTimeline,
    outliers,
    recent,
    overall,
    trend,
    selfImprovement,
    health,
    hints,
    signals: diagnostics.signals,
    competitorSummary,
    primaryChallenger,
    metricIndex: METRIC_INDEX,
  };
}
