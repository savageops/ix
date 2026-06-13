import { existsSync, readFileSync } from "node:fs";
import path from "node:path";
import { pairOrderSummaryIsBalanced } from "./speed-compare-utils.mjs";

function isPlainObject(value) {
  return value !== null && typeof value === "object" && !Array.isArray(value);
}

export function ripgrepWindowFixedPass(window) {
  return isPlainObject(window) && window.ok === true;
}

export function ripgrepWindowStrongPass(window) {
  return (
    isPlainObject(window) &&
    window.ok === true &&
    (window.softOk === true || window.pairedOk === true)
  );
}

function ripgrepWindowRegressionPct(window) {
  const value = window?.metrics?.regressionPct;
  return typeof value === "number" && Number.isFinite(value) ? value : null;
}

export function ripgrepProofSummary(windows) {
  const present = windows.filter(isPlainObject);
  const fixedPasses = present.filter((window) => window.ok === true).length;
  const softPasses = present.filter((window) => window.softOk === true).length;
  const hardRegressionWindows = present.filter((window) => window.ok !== true).length;
  const patchNoRegressionPasses = present.filter((window) => window.patchNoRegressionOk === true).length;
  const pairedImprovementPasses = present.filter((window) => window.pairedOk === true).length;
  const incomparableBaselineWindows = present.filter((window) => window.baselineComparable === false).length;
  const regressionPcts = present.map(ripgrepWindowRegressionPct).filter((value) => value !== null);
  const worstRegressionPct = regressionPcts.length > 0 ? Math.max(...regressionPcts) : null;
  const bestRegressionPct = regressionPcts.length > 0 ? Math.min(...regressionPcts) : null;
  const spreadPct =
    worstRegressionPct !== null && bestRegressionPct !== null ? Math.abs(worstRegressionPct - bestRegressionPct) : null;
  let proofKind = "missing";
  if (present.length > 0 && incomparableBaselineWindows > 0) {
    proofKind = "incomparable_baseline_config";
  } else if (present.length > 0 && fixedPasses === present.length && softPasses === present.length) {
    proofKind = "fixed_baseline_improved";
  } else if (fixedPasses >= 2 && softPasses >= 1 && hardRegressionWindows === 0) {
    proofKind = "fixed_baseline_no_regression";
  } else if (pairedImprovementPasses >= 2 && fixedPasses >= 1) {
    proofKind = "historical_paired_improvement";
  } else if (fixedPasses > 0 && hardRegressionWindows > 0) {
    proofKind = "unstable_mixed_baseline";
  } else {
    proofKind = "failed_baseline";
  }
  return {
    proofKind,
    fixedPasses,
    softPasses,
    pairedImprovementPasses,
    patchNoRegressionPasses,
    incomparableBaselineWindows,
    hardRegressionWindows,
    worstRegressionPct,
    bestRegressionPct,
    spreadPct,
    windows: present.length,
  };
}

export function ripgrepProofInterpretation(summary) {
  switch (summary.proofKind) {
    case "fixed_baseline_improved":
      return "all measured windows beat the fixed baseline improvement floor; this is speed improvement evidence";
    case "fixed_baseline_no_regression":
      return "fixed-baseline windows passed, but at least one window missed the stronger improvement band; this is not enough speed progress";
    case "historical_paired_improvement":
      return "paired historical-source windows improved while fixed-baseline evidence stayed partially healthy";
    case "incomparable_baseline_config":
      return "ripgrep benchmark warmup configuration does not match the fixed baseline; rerun with the baseline warmup or provide a matching baseline";
    case "unstable_mixed_baseline":
      return "fixed-baseline windows disagreed; treat this as benchmark instability until a tighter attribution run explains the spread";
    case "failed_baseline":
      return "fixed-baseline windows failed and no stronger comparator evidence rescued the lane";
    default:
      return "ripgrep benchmark evidence is missing or incomplete";
  }
}

export function validateRipgrepLane(entry, failures) {
  if (entry.id !== "ripgrep_12_sample" || entry.status !== "ok") return;
  const fixedPasses = ["primary", "confirm", "tiebreaker"].filter((key) => ripgrepWindowFixedPass(entry[key])).length;
  if (fixedPasses === 0) {
    failures.push("ripgrep_12_sample: ok status requires at least one fixed-baseline passing window");
  }
  const windowKeys = ["primary", "confirm", "tiebreaker"].filter((key) => isPlainObject(entry[key]));
  const weakWindows = windowKeys.filter((key) => {
    const window = entry[key];
    return window.ok !== true && window.softOk !== true && window.pairedOk !== true && window.patchNoRegressionOk !== true;
  });
  const strongPasses = windowKeys.filter((key) => ripgrepWindowStrongPass(entry[key])).length;
  if (weakWindows.length > 0 && strongPasses < 2) {
    failures.push("ripgrep_12_sample: ok status with a hard-regression window requires two strong independent passes");
  }
  const sameSourcePairedPass = ["primary", "confirm", "tiebreaker"].some((key) => {
    const window = entry[key];
    return (
      isPlainObject(window) &&
      window.pairedOk === true &&
      window.metrics?.previousIxSourceRelation === "same_source_different_binary"
    );
  });
  if (sameSourcePairedPass) {
    failures.push("ripgrep_12_sample: same-source comparator artifact cannot provide paired improvement evidence");
  }
  const unbalancedPairedWindow = windowKeys.some((key) => {
    const window = entry[key];
    return (
      isPlainObject(window) &&
      window.pairedOk === true &&
      !pairOrderSummaryIsBalanced(window.metrics?.previousIxPairing?.pairOrderSummary, window.metrics?.previousIxPairing?.pairOrder?.length)
    );
  });
  if (unbalancedPairedWindow) {
    failures.push("ripgrep_12_sample: paired previous-build evidence requires balanced alternating pair order");
  }
  const noisyHostPass = windowKeys.some((key) => {
    const window = entry[key];
    return (
      isPlainObject(window) &&
      (window.ok === true || window.softOk === true || window.pairedOk === true || window.patchNoRegressionOk === true) &&
      window.metrics?.hostClean === false
    );
  });
  if (noisyHostPass) {
    failures.push("ripgrep_12_sample: ok status cannot rely on a warning-class host benchmark envelope");
  }
  if (entry.acceptanceMode === "same_source_patch_no_regression") {
    failures.push("ripgrep_12_sample: same-source patch no-regression is diagnostic only and cannot be an acceptance mode");
  }
  if (!isPlainObject(entry.proof)) {
    failures.push("ripgrep_12_sample: ok status requires proof classification");
  } else if (typeof entry.proof.proofKind !== "string") {
    failures.push("ripgrep_12_sample.proof.proofKind: must be a string");
  }
}

export function createRipgrepGateLane({
  root,
  benchmarkCorpus,
  quick,
  run,
  lane,
  hostBenchmarkIssues,
  hostBenchmarkClean,
  baselineIxMs,
  baselineTolerancePct,
  baselineSoftTolerancePct,
  pairedImprovementTolerancePct,
  patchNoRegressionTolerancePct,
  ripgrepWarmupSamples,
  baselineWarmupSamples,
  previousIxBinary,
}) {
  function ripgrepLane(controlLane = null) {
    const corpus = benchmarkCorpus;
    if (!existsSync(corpus)) return lane("ripgrep_12_sample", "skipped", { reason: "ripgrep benchsuite corpus missing", corpus });
    if (quick) return lane("ripgrep_12_sample", "skipped", { reason: "--quick", corpus });
    if (controlLane?.status === "failed" || controlLane?.status === "skipped") {
      return lane("ripgrep_12_sample", "skipped", {
        corpus,
        reason: "benchmark control did not pass; skipping source-regression attribution until the control window is valid",
        controlReason: controlLane.reason ?? null,
        controlMetrics: controlLane.metrics ?? null,
      });
    }
    const latestPath = path.join(root, "tools", "reports", "latest.json");
    const maxAllowed = baselineIxMs * (1 + baselineTolerancePct / 100);
    const softMaxAllowed = baselineIxMs * (1 + baselineSoftTolerancePct / 100);
    const pairedMaxRatio = 1 - pairedImprovementTolerancePct / 100;

    const runWindow = (label) => {
      const benchArgs = [
        "tools/scripts/run-once-benchmark.mjs",
        "--profile",
        "suite-linux-word",
        "--expression",
        "re:\\bPM_RESUME\\b",
        "--corpus",
        corpus,
        "--threads",
        "32",
        "--warmup",
        String(ripgrepWarmupSamples),
        "--samples",
        "12",
        "--quiet",
      ];
      if (previousIxBinary) benchArgs.push("--previous-ix-binary", previousIxBinary, "--paired-interleave");
      const bench = run(process.execPath, benchArgs);
      if (bench.exitCode !== 0) return { label, ok: false, hardFailure: true, evidence: bench };
      if (!existsSync(latestPath)) {
        return {
          label,
          ok: false,
          hardFailure: true,
          evidence: bench,
          reason: "benchmark completed but tools/reports/latest.json was not written",
        };
      }

      const latest = JSON.parse(readFileSync(latestPath, "utf8"));
      const ixMs = Number(latest.iexMs);
      const rgMs = Number(latest.rgMs);
      const matchCount = Number(latest.matchCount);
      const previousIxMs = Number(latest.competitors?.iex_previous?.durationMs);
      const pairedRatio = Number(latest.iexToPreviousRatio);
      const previousAuthority = latest.previousIexAuthority ?? null;
      const previousMatchCountParity = latest.previousIexMatchCountParity ?? null;
      const previousIxSourceRelation = latest.previousIxSourceRelation ?? null;
      const hostIssues = hostBenchmarkIssues(latest.host ?? null);
      const hostClean = hostBenchmarkClean(hostIssues);
      const previousIsHistoricalSource =
        previousIxSourceRelation === null ||
        previousIxSourceRelation === "unknown" ||
        previousIxSourceRelation === "different_source";
      const previousIsSameSourceComparator = previousIxSourceRelation === "same_source_different_binary";
      const baselineComparable = ripgrepWarmupSamples === baselineWarmupSamples;
      const regressionPct =
        baselineComparable && Number.isFinite(ixMs) && baselineIxMs > 0 ? ((ixMs - baselineIxMs) / baselineIxMs) * 100 : null;
      const pairedImprovementPct = Number.isFinite(pairedRatio) && pairedRatio > 0 ? (1 - pairedRatio) * 100 : null;
      const ok = hostClean && baselineComparable && Number.isFinite(ixMs) && ixMs <= maxAllowed;
      const softOk = hostClean && baselineComparable && Number.isFinite(ixMs) && ixMs <= softMaxAllowed;
      const patchNoRegressionMaxRatio = 1 + patchNoRegressionTolerancePct / 100;
      const pairedOk =
        previousIxBinary !== "" &&
        previousIsHistoricalSource &&
        previousAuthority === "authoritative" &&
        previousMatchCountParity !== false &&
        Number.isFinite(previousIxMs) &&
        Number.isFinite(pairedRatio) &&
        pairedRatio <= pairedMaxRatio;
      const patchNoRegressionOk =
        previousIxBinary !== "" &&
        previousIsSameSourceComparator &&
        previousAuthority === "authoritative" &&
        previousMatchCountParity !== false &&
        Number.isFinite(previousIxMs) &&
        Number.isFinite(pairedRatio) &&
        pairedRatio <= patchNoRegressionMaxRatio;
      return {
        label,
        ok,
        softOk,
        pairedOk,
        patchNoRegressionOk,
        hardFailure: false,
        evidence: bench,
        metrics: {
          profile: latest.profile,
          expression: latest.expression,
          samples: 12,
          warmup: ripgrepWarmupSamples,
          ixMs,
          rgMs,
          previousIxMs: Number.isFinite(previousIxMs) ? previousIxMs : null,
          ixBinaryIdentity: latest.ixBinaryIdentity ?? null,
          previousIxBinaryIdentity: latest.competitors?.iex_previous?.binaryIdentity ?? null,
          previousIxSourceRelation,
          previousIsHistoricalSource,
          previousIsSameSourceComparator,
          pairedRatio: Number.isFinite(pairedRatio) ? pairedRatio : null,
          pairedImprovementPct,
          previousAuthority,
          previousMatchCountParity,
          pairedImprovementTolerancePct,
          pairedMaxRatio,
          patchNoRegressionTolerancePct,
          patchNoRegressionMaxRatio,
          ixSampleDurationsMs: latest.iexSampleDurationsMs ?? [],
          ixEngineSampleDurationsMs: latest.iexEngineSampleDurationsMs ?? [],
          ixSampleSummary: latest.iexSampleSummary ?? null,
          ixEngineSampleSummary: latest.iexEngineSampleSummary ?? null,
          previousIxEngineSampleDurationsMs: latest.competitors?.iex_previous?.engineSampleDurationsMs ?? [],
          previousIxEngineSampleSummary: latest.competitors?.iex_previous?.engineSampleSummary ?? null,
          previousIxPairing: latest.competitors?.iex_previous?.pairing ?? null,
          rgSampleDurationsMs: latest.competitors?.ripgrep?.sampleDurationsMs ?? [],
          rgSampleSummary: latest.competitors?.ripgrep?.sampleSummary ?? null,
          speedupPct: latest.speedupPct,
          matchCount,
          phaseMs: latest.phaseMs ?? {},
          hostIssues,
          hostClean,
          host: latest.host ?? null,
          baselineIxMs,
          baselineWarmupSamples,
          baselineComparable,
          baselineTolerancePct,
          baselineSoftTolerancePct,
          maxAllowedIxMs: maxAllowed,
          softMaxAllowedIxMs: softMaxAllowed,
          regressionPct,
        },
      };
    };

    const primary = runWindow("primary");
    if (primary.hardFailure) return lane("ripgrep_12_sample", "failed", { corpus, primary });
    if (primary.metrics?.baselineComparable === false) {
      const proof = ripgrepProofSummary([primary]);
      return lane("ripgrep_12_sample", "failed", {
        corpus,
        primary,
        proof,
        interpretation: ripgrepProofInterpretation(proof),
      });
    }
    if (primary.ok && primary.softOk) {
      const proof = ripgrepProofSummary([primary]);
      return lane("ripgrep_12_sample", "ok", {
        corpus,
        primary,
        proof,
        interpretation: ripgrepProofInterpretation(proof),
      });
    }

    const confirm = runWindow("confirm");
    if (confirm.hardFailure) return lane("ripgrep_12_sample", "failed", { corpus, primary, confirm });

    const hardPasses = (primary.ok ? 1 : 0) + (confirm.ok ? 1 : 0);
    const strongPasses = (ripgrepWindowStrongPass(primary) ? 1 : 0) + (ripgrepWindowStrongPass(confirm) ? 1 : 0);
    const accepted = hardPasses === 2 && strongPasses >= 1;
    if (hardPasses === 0) {
      const proof = ripgrepProofSummary([primary, confirm]);
      return lane("ripgrep_12_sample", "failed", {
        corpus,
        primary,
        confirm,
        proof,
        interpretation: "benchmark windows missed the fixed historical improvement floor; same-source patch metrics are diagnostic only and do not override the baseline",
      });
    }
    if (hardPasses === 1) {
      const tiebreaker = runWindow("tiebreaker");
      if (tiebreaker.hardFailure) return lane("ripgrep_12_sample", "failed", { corpus, primary, confirm, tiebreaker });
      const tiebreakerHardPasses = hardPasses + (tiebreaker.ok ? 1 : 0);
      const tiebreakerStrongPasses = strongPasses + (ripgrepWindowStrongPass(tiebreaker) ? 1 : 0);
      const tiebreakerAccepted = tiebreakerHardPasses >= 2 && tiebreakerStrongPasses >= 2;
      const proof = ripgrepProofSummary([primary, confirm, tiebreaker]);
      return lane("ripgrep_12_sample", tiebreakerAccepted ? "ok" : "failed", {
        corpus,
        primary,
        confirm,
        tiebreaker,
        proof,
        interpretation: tiebreakerAccepted
          ? ripgrepProofInterpretation(proof)
          : "benchmark windows disagreed and did not produce two strong independent passes",
      });
    }

    const proof = ripgrepProofSummary([primary, confirm]);
    return lane("ripgrep_12_sample", accepted ? "ok" : "failed", {
      corpus,
      primary,
      confirm,
      proof,
      interpretation: accepted
        ? ripgrepProofInterpretation(proof)
        : "benchmark windows missed the fixed historical improvement floor; paired previous-binary metrics are diagnostic only and do not override the baseline",
    });
  }

  return { ripgrepLane };
}
