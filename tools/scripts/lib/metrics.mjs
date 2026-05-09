import assert from "node:assert/strict";

export function mean(values) {
  if (!values.length) {
    return 0;
  }
  return values.reduce((sum, value) => sum + value, 0) / values.length;
}

export function variance(values) {
  if (!values.length) {
    return 0;
  }
  const avg = mean(values);
  return values.reduce((sum, value) => {
    const delta = value - avg;
    return sum + delta * delta;
  }, 0) / values.length;
}

export function standardDeviation(values) {
  if (!values.length) {
    return 0;
  }
  return Math.sqrt(variance(values));
}

export function percentile(values, pct) {
  if (!values.length) {
    return 0;
  }
  const sorted = [...values].sort((a, b) => a - b);
  const idx = Math.min(sorted.length - 1, Math.floor((pct / 100) * sorted.length));
  return sorted[idx] ?? 0;
}

export function median(values) {
  return percentile(values, 50);
}

export function min(values) {
  if (!values.length) {
    return 0;
  }
  return values.reduce((current, value) => (value < current ? value : current), values[0]);
}

export function max(values) {
  if (!values.length) {
    return 0;
  }
  return values.reduce((current, value) => (value > current ? value : current), values[0]);
}

export function medianAbsoluteDeviation(values) {
  if (!values.length) {
    return 0;
  }
  const med = median(values);
  const absoluteDeviations = values.map((value) => Math.abs(value - med));
  return median(absoluteDeviations);
}

export function skewness(values) {
  if (values.length < 3) {
    return 0;
  }
  const avg = mean(values);
  const stdev = standardDeviation(values);
  if (stdev === 0) {
    return 0;
  }
  const thirdMoment = mean(values.map((value) => ((value - avg) / stdev) ** 3));
  return thirdMoment;
}

export function meanAbsoluteDelta(values) {
  if (values.length < 2) {
    return 0;
  }
  let total = 0;
  for (let i = 1; i < values.length; i += 1) {
    total += Math.abs(values[i] - values[i - 1]);
  }
  return total / (values.length - 1);
}

export function linearRegressionSlope(values) {
  if (values.length < 2) {
    return 0;
  }
  const n = values.length;
  const meanX = (n - 1) / 2;
  const meanY = mean(values);
  let numerator = 0;
  let denominator = 0;
  for (let i = 0; i < n; i += 1) {
    const deltaX = i - meanX;
    numerator += deltaX * (values[i] - meanY);
    denominator += deltaX * deltaX;
  }
  if (denominator === 0) {
    return 0;
  }
  return numerator / denominator;
}

export function semivarianceAbove(values, threshold) {
  if (!values.length) {
    return 0;
  }
  const penalties = values.map((value) => {
    const excess = Math.max(0, value - threshold);
    return excess * excess;
  });
  return mean(penalties);
}

export function computeRatio(numerator, denominator) {
  if (denominator <= 0) {
    return 0;
  }
  return numerator / denominator;
}

export function summarizeSeries(values) {
  const finite = values.filter((value) => Number.isFinite(value));
  if (!finite.length) {
    return {
      count: 0,
      min: 0,
      p05: 0,
      p10: 0,
      p25: 0,
      median: 0,
      p75: 0,
      p90: 0,
      p95: 0,
      p99: 0,
      max: 0,
      mean: 0,
      stdev: 0,
      variance: 0,
      range: 0,
      iqr: 0,
      mad: 0,
      skewness: 0,
      meanAbsDelta: 0,
      slopePerIndex: 0,
      cvPct: 0,
      robustCvPct: 0,
    };
  }

  return {
    count: finite.length,
    min: min(finite),
    p05: percentile(finite, 5),
    p10: percentile(finite, 10),
    p25: percentile(finite, 25),
    median: median(finite),
    p75: percentile(finite, 75),
    p90: percentile(finite, 90),
    p95: percentile(finite, 95),
    p99: percentile(finite, 99),
    max: max(finite),
    mean: mean(finite),
    stdev: standardDeviation(finite),
    variance: variance(finite),
    range: max(finite) - min(finite),
    iqr: percentile(finite, 75) - percentile(finite, 25),
    mad: medianAbsoluteDeviation(finite),
    skewness: skewness(finite),
    meanAbsDelta: meanAbsoluteDelta(finite),
    slopePerIndex: linearRegressionSlope(finite),
    cvPct: mean(finite) !== 0 ? (standardDeviation(finite) / mean(finite)) * 100 : 0,
    robustCvPct:
      median(finite) !== 0
        ? ((1.4826 * medianAbsoluteDeviation(finite)) / Math.abs(median(finite))) * 100
        : 0,
  };
}

export function computeSpeedupPct(iexMs, rgMs) {
  if (rgMs <= 0) {
    return 0;
  }
  return ((rgMs - iexMs) / rgMs) * 100;
}

export function classifyHotspot(run) {
  const discover = run?.phaseMs?.discover ?? 0;
  const scan = run?.phaseMs?.scan ?? 0;
  const aggregate = run?.phaseMs?.aggregate ?? 0;
  const max = Math.max(discover, scan, aggregate);
  if (max === scan) {
    return "scan";
  }
  if (max === discover) {
    return "discover";
  }
  return "aggregate";
}

export function parseJsonl(input) {
  return input
    .split(/\r?\n/)
    .map((line) => line.trim())
    .filter(Boolean)
    .map((line) => JSON.parse(line));
}

export function validateRun(run) {
  assert.ok(run.runId.length > 0);
  assert.ok(run.timestamp.length > 0);
  assert.ok(Number.isFinite(run.iexMs));
  assert.ok(Number.isFinite(run.rgMs));
  assert.ok(Number.isFinite(run.speedupPct));
  assert.ok(Number.isFinite(run.phaseMs.total));
  assert.ok(Array.isArray(run.slowestFiles));
}

export function rollingAverage(values, window) {
  if (window <= 0) {
    return [];
  }
  const out = [];
  for (let i = 0; i < values.length; i += 1) {
    const from = Math.max(0, i - window + 1);
    out.push(mean(values.slice(from, i + 1)));
  }
  return out;
}
