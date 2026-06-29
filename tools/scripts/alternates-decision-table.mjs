import { spawnSync } from "node:child_process";
import { createHash } from "node:crypto";
import { existsSync, mkdirSync, readFileSync, readdirSync, statSync, writeFileSync } from "node:fs";
import os from "node:os";
import path from "node:path";
import { hostSnapshot } from "./lib/benchmark-runner.mjs";
import { argValue, timestampSlug } from "./lib/script-helpers.mjs";
import { acquireBenchmarkLock, buildAlternatesComparisonScore, buildAlternatesRoundLedger, buildAlternatesScorecard, identityControlFailures, measureSameBinaryIdentityControl, pairedEngineStats, pairOrderSummary, pairOrderSummaryIsBalanced } from "./lib/speed-compare-utils.mjs";

const ROOT = process.cwd();
const REPORT_DIR = path.join(ROOT, "tools", "reports", "alternates-decision");
const DEFAULT_CORPUS = "E:\\Workspaces\\01_Projects\\01_Github\\iEx\\.refs\\ripgrep\\benchsuite\\linux";
const DEFAULT_IX = path.join(ROOT, "zig-out", "bin", process.platform === "win32" ? "ix-zig.exe" : "ix-zig");
const DEFAULT_TERMS = ["ERR_SYS", "PME_TURN_OFF", "LINK_REQ_RST", "CFG_BME_EVT", "PM_RESUME", "PCI_WAKE", "DPM_FLAG", "ACPI_STATE"];

const args = process.argv.slice(2);
if (args.includes("--help") || args.includes("-h")) {
  console.log(`Usage: node tools/scripts/alternates-decision-table.mjs [options]

Measures literal-alternates branch counts on the ripgrep linux benchsuite and
records selector features, route contracts, match parity, and focused-repeat
guidance for candidate regressions.

Options:
  --samples <n>                       Samples per branch. Default: 5.
  --threads <n>                       IX thread count. Default: 32.
  --identity-control-samples <n>      Same-binary control pairs per branch. Default: min(12, samples).
  --identity-control-attempts <n>     Same-binary control attempts per branch; first stable attempt is selected. Default: 1.
  --no-identity-control               Disable same-binary noise control.
  --max-branches <n>                  Highest branch count when --branch-counts is omitted. Default: 8.
  --branch-counts <csv>               Explicit branch counts, e.g. 2,4,8.
  --corpus <path>                     Corpus path.
  --ix-binary <path>                  Candidate IX binary path.
  --baseline-ix <path>                Optional baseline IX binary path.
  --max-regression-pct <n>            Allowed candidate regression percent. Default: 0.
  --confirm-regression-samples <n>    Samples required to confirm a regression. Default: 24.
  --fingerprint-corpus                Rank Teddy fingerprint windows by corpus candidate counts.
  --fingerprint-max-bytes <n>         Corpus bytes to inspect for fingerprint analysis. Default: 134217728.
  --case-sensitive                    Disable default case-insensitive expressions.
  --no-benchmark-lock                 Disable the cross-script benchmark lock.
  --quiet                             Write reports without printing summary.
  --help, -h                          Print this help and exit without measuring.
`);
  process.exit(0);
}
const corpus = argValue(args, "--corpus", DEFAULT_CORPUS);
const ixBinary = argValue(args, "--ix-binary", DEFAULT_IX);
const baselineIxBinary = argValue(args, "--baseline-ix", "");
const samples = Number(argValue(args, "--samples", "5"));
const threads = Number(argValue(args, "--threads", "32"));
const identityControlSamples = Number(argValue(args, "--identity-control-samples", String(Math.min(12, samples))));
const identityControlAttempts = Number(argValue(args, "--identity-control-attempts", process.env.IX_IDENTITY_CONTROL_ATTEMPTS ?? "1"));
const identityControlEnabled = !args.includes("--no-identity-control");
const maxBranches = Number(argValue(args, "--max-branches", "8"));
const branchCountsArg = argValue(args, "--branch-counts", "");
const maxRegressionPct = Number(argValue(args, "--max-regression-pct", process.env.IX_ALTERNATES_MAX_REGRESSION_PCT ?? "0"));
const confirmRegressionSamples = Number(argValue(args, "--confirm-regression-samples", process.env.IX_ALTERNATES_CONFIRM_REGRESSION_SAMPLES ?? "24"));
const fingerprintCorpus = args.includes("--fingerprint-corpus");
const fingerprintMaxBytes = Number(argValue(args, "--fingerprint-max-bytes", process.env.IX_ALTERNATES_FINGERPRINT_MAX_BYTES ?? String(128 * 1024 * 1024)));
const teddyFingerprintOffsetEnv = process.env.IX_TEDDY_FINGERPRINT_OFFSET ?? null;
const caseInsensitive = !args.includes("--case-sensitive");
const benchmarkLock = !args.includes("--no-benchmark-lock");
const quiet = args.includes("--quiet");

const TEDDY_REFERENCE_BASIS = [
  {
    name: "teddy",
    url: "https://github.com/jneem/teddy",
    invariant: "packed multi-literal search should minimize per-chunk work and push expensive confirmation behind selective fingerprints",
  },
  {
    name: "regex-automata-prefilter",
    url: "https://github.com/rust-lang/regex/tree/master/regex-automata/src/util/prefilter",
    invariant: "literal prefilters are route selectors that preserve match semantics while reducing verifier traffic",
  },
];

function run(command, commandArgs) {
  const started = process.hrtime.bigint();
  const result = spawnSync(command, commandArgs, {
    cwd: ROOT,
    encoding: "utf8",
    maxBuffer: 128 * 1024 * 1024,
    windowsHide: true,
  });
  return {
    command: [command, ...commandArgs].join(" "),
    exitCode: result.status ?? 0,
    stdout: result.stdout ?? "",
    stderr: result.stderr ?? "",
    durationMs: Number(process.hrtime.bigint() - started) / 1_000_000,
  };
}

function percentile(sorted, p) {
  const index = Math.min(sorted.length - 1, Math.max(0, Math.ceil((p / 100) * sorted.length) - 1));
  return sorted[index];
}

function summary(values) {
  const sorted = [...values].sort((left, right) => left - right);
  const mean = values.reduce((sum, value) => sum + value, 0) / values.length;
  const variance = values.reduce((sum, value) => sum + (value - mean) ** 2, 0) / values.length;
  return {
    count: values.length,
    min: sorted[0],
    p25: percentile(sorted, 25),
    median: percentile(sorted, 50),
    p75: percentile(sorted, 75),
    max: sorted[sorted.length - 1],
    mean,
    stdev: Math.sqrt(variance),
  };
}

function numericSummary(values) {
  const sorted = [...values].sort((left, right) => left - right);
  const mean = values.reduce((sum, value) => sum + value, 0) / values.length;
  return {
    min: sorted[0],
    p50: percentile(sorted, 50),
    max: sorted[sorted.length - 1],
    mean,
  };
}

function parseIxReport(stdout) {
  const trimmed = stdout.trim();
  if (!trimmed) throw new Error("IX produced empty stdout");
  return JSON.parse(trimmed);
}

function fileSha256(filePath) {
  return createHash("sha256").update(readFileSync(filePath)).digest("hex").toUpperCase();
}

function expressionFor(branchCount) {
  const terms = DEFAULT_TERMS.slice(0, branchCount);
  const prefix = caseInsensitive ? "(?i)" : "";
  return `re:${prefix}(${terms.join("|")})`;
}

function parseBranchCounts(value, maxBranchCount) {
  if (value.length === 0) {
    return Array.from({ length: maxBranchCount - 1 }, (_, index) => index + 2);
  }
  const parsed = value.split(",")
    .map((part) => Number(part.trim()))
    .filter((count) => Number.isFinite(count));
  const unique = [...new Set(parsed)].sort((left, right) => left - right);
  if (unique.length === 0) {
    throw new Error("--branch-counts must include at least one integer branch count");
  }
  for (const count of unique) {
    if (!Number.isInteger(count) || count < 2 || count > DEFAULT_TERMS.length) {
      throw new Error(`invalid --branch-counts value ${count}; expected integer 2..${DEFAULT_TERMS.length}`);
    }
  }
  return unique;
}

function longestCommonPrefixLength(left, right) {
  const limit = Math.min(left.length, right.length);
  let index = 0;
  while (index < limit && left.charCodeAt(index) === right.charCodeAt(index)) index += 1;
  return index;
}

function selectorFeatures(branchCount) {
  const terms = DEFAULT_TERMS.slice(0, branchCount);
  const firstBytes = terms.map((term) => term.charCodeAt(0));
  const foldedFirstBytes = firstBytes.map((byte) => String.fromCharCode(byte).toLowerCase().charCodeAt(0));
  const uniqueFirstBytes = new Set(firstBytes);
  const uniqueFoldedFirstBytes = new Set(foldedFirstBytes);
  const branchLengths = terms.map((term) => term.length);
  const branchLengthSummary = numericSummary(branchLengths);
  let maxSharedPrefix = 0;
  let prefixCollisionPairs = 0;
  for (let left = 0; left < terms.length; left += 1) {
    for (let right = left + 1; right < terms.length; right += 1) {
      const shared = longestCommonPrefixLength(terms[left], terms[right]);
      maxSharedPrefix = Math.max(maxSharedPrefix, shared);
      if (shared === Math.min(terms[left].length, terms[right].length)) prefixCollisionPairs += 1;
    }
  }
  const pairCount = Math.max(1, (terms.length * (terms.length - 1)) / 2);
  const teddyFingerprintBytes = Math.min(3, branchLengthSummary.min);
  const teddyBucketCount = branchCount <= 8 ? 8 : 16;
  const teddyEligible =
    branchCount >= 2 &&
    branchCount <= 8 &&
    branchLengthSummary.min >= 3 &&
    prefixCollisionPairs === 0;
  return {
    terms,
    uniqueFirstBytes: uniqueFirstBytes.size,
    uniqueFoldedFirstBytes: uniqueFoldedFirstBytes.size,
    firstByteFanout: uniqueFirstBytes.size / terms.length,
    foldedFirstByteFanout: uniqueFoldedFirstBytes.size / terms.length,
    branchLengths: branchLengthSummary,
    maxSharedPrefix,
    prefixCollisionPairs,
    prefixCollisionDensity: prefixCollisionPairs / pairCount,
    teddyEligibility: {
      eligible: teddyEligible,
      fingerprintBytes: teddyFingerprintBytes,
      bucketCount: teddyBucketCount,
      bucketLoad: branchCount / teddyBucketCount,
      confirmation: prefixCollisionPairs === 0 ? "bucketed_literal_verify" : "ordered_prefix_collision_verify",
      rejectReason: teddyEligible ? null : (
        branchCount > 8 ? "too_many_branches" :
        branchLengthSummary.min < 3 ? "short_branch" :
        prefixCollisionPairs > 0 ? "prefix_collision" :
        "unsupported_shape"
      ),
    },
  };
}

function collectCorpusFiles(root, maxBytes) {
  const files = [];
  let queuedBytes = 0;
  const stack = [root];
  while (stack.length > 0 && queuedBytes < maxBytes) {
    const current = stack.pop();
    const stat = statSync(current);
    if (stat.isDirectory()) {
      const entries = readdirSync(current)
        .map((name) => path.join(current, name))
        .sort((left, right) => right.localeCompare(left));
      for (const entry of entries) stack.push(entry);
      continue;
    }
    if (!stat.isFile()) continue;
    files.push({ path: current, size: stat.size });
    queuedBytes += stat.size;
  }
  return files;
}

function asciiLowerByte(byte) {
  return byte >= 65 && byte <= 90 ? byte + 32 : byte;
}

function fingerprintNeedles(terms, offset) {
  return terms.map((term) => {
    const bytes = Buffer.from(term.slice(offset, offset + TEDDY_FINGERPRINT_BYTES), "ascii");
    return caseInsensitive ? Buffer.from(bytes.map(asciiLowerByte)) : bytes;
  });
}

const TEDDY_FINGERPRINT_BYTES = 3;

function analyzeFingerprintWindows(branchCount) {
  const terms = DEFAULT_TERMS.slice(0, branchCount);
  const minLen = Math.min(...terms.map((term) => term.length));
  if (minLen < TEDDY_FINGERPRINT_BYTES) {
    return { enabled: true, eligible: false, reason: "short_branch", windows: [] };
  }
  const files = collectCorpusFiles(corpus, fingerprintMaxBytes);
  const windows = [];
  for (let offset = 0; offset <= minLen - TEDDY_FINGERPRINT_BYTES; offset += 1) {
    const needles = fingerprintNeedles(terms, offset);
    const perNeedleCandidates = new Array(needles.length).fill(0);
    let candidatePositions = 0;
    let bytesAnalyzed = 0;
    let filesAnalyzed = 0;
    for (const file of files) {
      if (bytesAnalyzed >= fingerprintMaxBytes) break;
      const raw = readFileSync(file.path);
      const take = Math.min(raw.length, fingerprintMaxBytes - bytesAnalyzed);
      if (take < TEDDY_FINGERPRINT_BYTES) {
        bytesAnalyzed += take;
        filesAnalyzed += 1;
        continue;
      }
      const data = raw.subarray(0, take);
      for (let index = 0; index <= data.length - TEDDY_FINGERPRINT_BYTES; index += 1) {
        for (let needleIndex = 0; needleIndex < needles.length; needleIndex += 1) {
          const needle = needles[needleIndex];
          let matched = true;
          for (let byteIndex = 0; byteIndex < TEDDY_FINGERPRINT_BYTES; byteIndex += 1) {
            const hay = caseInsensitive ? asciiLowerByte(data[index + byteIndex]) : data[index + byteIndex];
            if (hay !== needle[byteIndex]) {
              matched = false;
              break;
            }
          }
          if (matched) {
            candidatePositions += 1;
            perNeedleCandidates[needleIndex] += 1;
            break;
          }
        }
      }
      bytesAnalyzed += take;
      filesAnalyzed += 1;
    }
    windows.push({
      offset,
      fingerprints: terms.map((term) => term.slice(offset, offset + TEDDY_FINGERPRINT_BYTES).toLowerCase()),
      candidatePositions,
      candidatesPerMiB: bytesAnalyzed > 0 ? candidatePositions / (bytesAnalyzed / (1024 * 1024)) : null,
      perNeedleCandidates,
      bytesAnalyzed,
      filesAnalyzed,
    });
  }
  windows.sort((left, right) => left.candidatePositions - right.candidatePositions || left.offset - right.offset);
  return {
    enabled: true,
    eligible: true,
    branchCount,
    corpus,
    maxBytes: fingerprintMaxBytes,
    bestOffset: windows[0]?.offset ?? null,
    windows,
  };
}

function summarizeCounterValues(values) {
  const numeric = (values ?? []).map(Number).filter((value) => Number.isFinite(value));
  return summary(numeric);
}

function nsSummaryToMs(summaryValue) {
  if (!summaryValue || !Number.isFinite(Number(summaryValue.median))) return null;
  return Number(summaryValue.median) / 1_000_000;
}

function medianSharePct(partMs, wholeMs) {
  if (!Number.isFinite(Number(partMs)) || !Number.isFinite(Number(wholeMs)) || Number(wholeMs) <= 0) return null;
  return (Number(partMs) / Number(wholeMs)) * 100;
}

function summarizeComparisons(comparisons) {
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
    if (comparison.classification === "improvement") summary.improvements += 1;
    if (comparison.classification === "parity") summary.parity += 1;
    if (comparison.classification === "regression" || comparison.regression === true) {
      summary.regressions += 1;
      if (comparison.evidenceAuthority === "identity_noise_only") {
        summary.identityNoiseRegressions += 1;
      } else {
        summary.candidateRegressions += 1;
      }
    }
    if (comparison.matchParity !== true) summary.matchParityFailures += 1;
    if (!pairOrderSummaryIsBalanced(comparison.pairOrderSummary, comparison.pairedEngine?.count)) summary.pairOrderFailures += 1;
  }
  return summary;
}

function confirmationForComparison(comparison) {
  if (comparison?.regression !== true || comparison?.evidenceAuthority !== "candidate_vs_baseline") {
    return {
      required: false,
      status: "not_required",
      reason: "comparison is not a candidate-vs-baseline regression",
    };
  }
  return {
    required: true,
    status: Number(samples) >= confirmRegressionSamples ? "confirmed_window" : "needs_focused_repeat",
    samples,
    requiredSamples: confirmRegressionSamples,
    recommendedCommand: `node tools/scripts/alternates-decision-table.mjs --branch-counts ${comparison.branchCount} --samples ${confirmRegressionSamples} --threads ${threads}${baselineIxBinary.length > 0 ? ` --baseline-ix \"${baselineIxBinary}\"` : ""} --max-regression-pct ${maxRegressionPct}`,
    reason: Number(samples) >= confirmRegressionSamples
      ? "regression observed in a focused-size sample window"
      : "single alternates windows are diagnostic only on noisy hosts; rerun this branch with focused paired samples before changing engine code",
  };
}

function candidateRoute(comparison) {
  if ((comparison.candidatePcreRanges ?? []).some((value) => Number(value) > 0)) return "pcre";
  if ((comparison.candidateTeddyRanges ?? []).some((value) => Number(value) > 0)) return "teddy";
  if ((comparison.candidateCompiledRanges ?? []).some((value) => Number(value) > 0)) return "compiled";
  return "none";
}

function routeMedianMs(comparison) {
  const route = candidateRoute(comparison);
  if (route === "pcre") return comparison.candidatePcreElapsedMedianMs;
  if (route === "teddy") return comparison.candidateTeddyElapsedMedianMs;
  if (route === "compiled") return comparison.candidateCompiledElapsedMedianMs;
  return null;
}

function routeSharePct(comparison) {
  const route = candidateRoute(comparison);
  if (route === "pcre") return comparison.candidatePcreEngineSharePct;
  if (route === "teddy") return comparison.candidateTeddyEngineSharePct;
  if (route === "compiled") return comparison.candidateCompiledEngineSharePct;
  return null;
}

function routeElapsedAuthority(comparison) {
  const share = routeSharePct(comparison);
  if (!Number.isFinite(Number(share))) return "missing";
  return Number(share) <= 100 ? "wall_share" : "parallel_worker_sum";
}

function expectedRecoverableMs(comparison) {
  const deltaMs = Math.max(0, Number(comparison.candidateEngineDeltaMs) || 0);
  const share = Number(routeSharePct(comparison));
  if (!Number.isFinite(share) || share <= 0) return 0;
  const boundedShare = Math.min(100, share) / 100;
  return deltaMs * boundedShare;
}

function expectedGainScore(comparison) {
  const deltaPct = Math.max(0, Number(comparison.candidateEngineDeltaPct) || 0);
  const share = Number(routeSharePct(comparison));
  const boundedShare = Number.isFinite(share) ? Math.min(100, Math.max(0, share)) : 0;
  const routeAuthority = routeElapsedAuthority(comparison);
  const inputs = expectedGainInputs(comparison);
  return deltaPct * (boundedShare / 100) * inputs.authorityWeight * inputs.collisionWeight;
}

function expectedGainInputs(comparison) {
  const routeAuthority = routeElapsedAuthority(comparison);
  const selector = comparison.selectorFeatures ?? {};
  const collisionDensity = Math.min(1, Math.max(0, Number(selector.prefixCollisionDensity ?? 0)));
  return {
    deltaPct: Math.max(0, Number(comparison.candidateEngineDeltaPct) || 0),
    routeSharePct: Number.isFinite(Number(routeSharePct(comparison))) ? Number(routeSharePct(comparison)) : null,
    authorityWeight: routeAuthority === "wall_share" ? 1 : routeAuthority === "parallel_worker_sum" ? 0.65 : 0.35,
    collisionWeight: 1 + collisionDensity,
    pairedWinRate: Number.isFinite(Number(comparison.pairedEngine?.candidateWinRate)) ? Number(comparison.pairedEngine.candidateWinRate) : null,
  };
}

function expectedGainConfidence(comparison) {
  const inputs = expectedGainInputs(comparison);
  const routeAuthority = routeElapsedAuthority(comparison);
  const share = Number(inputs.routeSharePct);
  const winRate = Number(inputs.pairedWinRate);
  if (!Number.isFinite(share) || share <= 0 || routeAuthority === "missing") return "low";
  if (routeAuthority === "wall_share" && Number(samples) >= confirmRegressionSamples && Number.isFinite(winRate) && winRate >= 0.66) {
    return "high";
  }
  if ((routeAuthority === "wall_share" || routeAuthority === "parallel_worker_sum") && Number.isFinite(winRate) && winRate > 0.5) {
    return "medium";
  }
  return "low";
}

function focusedProofCommand(branchCount) {
  return [
    "node",
    "tools/scripts/ix-architecture-regression-gate.mjs",
    "--speed-only",
    "--alternates-decision",
    "--alternates-decision-samples",
    String(confirmRegressionSamples),
    "--alternates-decision-branch-counts",
    String(branchCount),
    "--min-retainable-speed-samples",
    String(confirmRegressionSamples),
  ].join(" ");
}

function routeContracts(comparisons) {
  return comparisons
    .filter((comparison) => comparison.selectorFeatures?.teddyEligibility?.eligible === true)
    .map((comparison) => {
      const observedRoute = candidateRoute(comparison);
      const pcreSamples = (comparison.candidatePcreRanges ?? []).map(Number);
      const teddySamples = (comparison.candidateTeddyRanges ?? []).map(Number);
      const compiledSamples = (comparison.candidateCompiledRanges ?? []).map(Number);
      const pcreObserved = pcreSamples.some((value) => Number.isFinite(value) && value > 0);
      const teddyObserved = teddySamples.some((value) => Number.isFinite(value) && value > 0);
      const compiledObserved = compiledSamples.some((value) => Number.isFinite(value) && value > 0);
      return {
        id: Number(comparison.branchCount) === 4 ? "branch_4_no_pcre_handoff" : "teddy_eligible_no_pcre_handoff",
        branchCount: comparison.branchCount,
        expectedRoute: "teddy",
        observedRoute,
        passed: observedRoute === "teddy" && teddyObserved && !compiledObserved && !pcreObserved,
        rationale: "Teddy-eligible literal alternates should run through the packed SIMD extractor; PCRE and compiled routes are fallbacks for ineligible shapes, not this lane.",
        pcreRangeSamples: comparison.candidatePcreRanges,
        teddyRangeSamples: comparison.candidateTeddyRanges,
        compiledRangeSamples: comparison.candidateCompiledRanges,
      };
    });
}

function optimizationTargets(comparisons) {
  return comparisons
    .filter((comparison) =>
      comparison.evidenceAuthority === "candidate_vs_baseline" &&
      comparison.regression === true &&
      comparison.regressionConfirmation?.status === "confirmed_window"
    )
    .map((comparison) => ({
      branchCount: comparison.branchCount,
      expression: comparison.expression,
      candidateRoute: candidateRoute(comparison),
      candidateEngineMedianMs: comparison.candidateEngineMedianMs,
      baselineEngineMedianMs: comparison.baselineEngineMedianMs,
      candidateEngineDeltaMs: comparison.candidateEngineDeltaMs,
      candidateEngineDeltaPct: comparison.candidateEngineDeltaPct,
      candidateRouteMedianMs: routeMedianMs(comparison),
      candidateRouteEngineSharePct: routeSharePct(comparison),
      candidateRouteElapsedAuthority: routeElapsedAuthority(comparison),
      expectedRecoverableMs: expectedRecoverableMs(comparison),
      expectedGainScore: expectedGainScore(comparison),
      expectedGainConfidence: expectedGainConfidence(comparison),
      expectedGainInputs: expectedGainInputs(comparison),
      proofCommand: focusedProofCommand(comparison.branchCount),
      researchBasis: TEDDY_REFERENCE_BASIS,
      matchParity: comparison.matchParity,
      selectorFeatures: comparison.selectorFeatures,
    }))
    .sort((left, right) =>
      (right.expectedGainScore - left.expectedGainScore) ||
      (right.expectedRecoverableMs - left.expectedRecoverableMs) ||
      (right.candidateEngineDeltaMs - left.candidateEngineDeltaMs)
    );
}

function nextMovesForTargets(targets) {
  return targets.map((target) => {
    const route = target.candidateRoute;
    const selector = target.selectorFeatures ?? {};
    const routeAuthority = target.candidateRouteElapsedAuthority;
    const routeShare = Number(target.candidateRouteEngineSharePct);
    const branchCount = Number(target.branchCount);
    const firstByteFanout = Number(selector.foldedFirstByteFanout ?? selector.firstByteFanout);
    const prefixCollisionDensity = Number(selector.prefixCollisionDensity ?? 0);
    const teddy = selector.teddyEligibility ?? {};
    const routeDominates = Number.isFinite(routeShare) && routeShare >= 50;

    let priority = "benchmark_authority";
    let mechanism = "repeat clean-host A/B before changing engine code";
    let rejectedMechanism = null;
    let rationale = "candidate regression needs stronger route attribution before implementation";

    if (route === "compiled") {
      rejectedMechanism = "generic_sparse_aho_corasick_or_scalar_teddy_lite";
      priority = "packed_simd_prefilter";
      mechanism = "Teddy-style nibble-mask multi-literal prefilter with bucketed confirmation";
      rationale = "compiled/scalar candidate extraction regressed; Teddy references point to packed SIMD nibble masks plus bounded confirmation instead of range-level byte walking";
    } else if (route === "pcre" && routeDominates) {
      priority = "pcre_handoff_reduction";
      mechanism = "reduce PCRE range handoff cost or replace it with packed SIMD candidate extraction before regex verification";
      rationale = "PCRE range time dominates the branch lane, so threshold toggles are weak unless route worker-sum falls";
    } else if (route === "pcre") {
      priority = "selector_tuning";
      mechanism = "tighten alternates selector eligibility and compare route share under repeated clean-host samples";
      rationale = "PCRE is active but does not clearly dominate wall time";
    }

    if (Number.isFinite(firstByteFanout) && firstByteFanout < 0.5) {
      priority = "fingerprint_selection";
      mechanism = `choose rarer ${Number(teddy.fingerprintBytes) || 2}-byte fingerprints before confirmation`;
      rationale = "low first-byte fanout predicts too many verification candidates for first-byte-only selection";
    }
    if (Number.isFinite(prefixCollisionDensity) && prefixCollisionDensity > 0) {
      priority = "prefix_collision_confirmation";
      mechanism = "bucket literals by selected fingerprint and preserve leftmost/longest confirmation semantics";
      rationale = "prefix-sharing terms need confirmation ordering rather than plain route replacement";
    }

    return {
      branchCount,
      expression: target.expression,
      priority,
      mechanism,
      rejectedMechanism,
      route,
      routeElapsedAuthority: routeAuthority,
      routeSharePct: target.candidateRouteEngineSharePct,
      expectedRecoverableMs: target.expectedRecoverableMs,
      expectedGainScore: target.expectedGainScore,
      expectedGainConfidence: target.expectedGainConfidence,
      expectedGainInputs: target.expectedGainInputs,
      proofCommand: target.proofCommand,
      researchBasis: target.researchBasis,
      deltaPct: target.candidateEngineDeltaPct,
      rationale,
    };
  });
}

function benchmarkHostFailures(host) {
  const issues = [
    ...(host.before?.benchmarkEnvironment?.issues ?? []),
    ...(host.after?.benchmarkEnvironment?.issues ?? []),
  ].filter((issue) => issue?.severity === "warning");
  return issues.map((issue) => `host:${issue.id}:${issue.detail}`);
}

function requiredDecisionFailures({
  host,
  baselinePath,
  relation,
  comparisons,
  contracts,
  identityControls,
}) {
  const failures = [...benchmarkHostFailures(host)];
  if (!baselinePath) failures.push("missing_baseline");
  if (relation === "same_binary") failures.push("same_binary:identity_noise_only");
  for (const comparison of comparisons) {
    const branch = comparison.branchCount;
    failures.push(...identityControlFailures({
      identityControl: identityControls?.[String(branch)] ?? null,
      enabled: identityControlEnabled,
      requiredSamples: Math.min(6, samples),
    }).map((failure) => `${failure}:branch_${branch}`));
  }
  for (const comparison of comparisons) {
    const branch = comparison.branchCount;
    if (comparison.matchParity !== true) failures.push(`match_parity_failed:branch_${branch}`);
    if (comparison.fullScanCallsParity !== true) failures.push(`full_scan_call_parity_failed:branch_${branch}`);
    if (comparison.fullScanBytesParity !== true) failures.push(`full_scan_byte_parity_failed:branch_${branch}`);
    if (comparison.fullScanMatchesParity !== true) failures.push(`full_scan_match_parity_failed:branch_${branch}`);
    const paired = comparison.pairedEngine;
    const candidateWinRate = Number(paired?.candidateWinRate);
    if (
      comparison.evidenceAuthority === "candidate_vs_baseline" &&
      (!Number.isFinite(candidateWinRate) || candidateWinRate <= 0.5)
    ) {
      failures.push(`unstable_paired_evidence:branch_${branch}:${Number.isFinite(candidateWinRate) ? candidateWinRate : "missing"}`);
    }
    if (comparison.evidenceAuthority === "candidate_vs_baseline" && comparison.score?.netPositive !== true) {
      failures.push(`candidate_score_not_net_positive:branch_${branch}`);
    }
    if (
      comparison.evidenceAuthority === "candidate_vs_baseline" &&
      comparison.score?.teddyRouteObserved === true &&
      comparison.score?.teddyRouteNetPositive !== true
    ) {
      failures.push(`teddy_route_not_net_positive:branch_${branch}`);
    }
    if (!pairOrderSummaryIsBalanced(comparison.pairOrderSummary, comparison.pairedEngine?.count ?? samples)) {
      failures.push(`pair_order_unbalanced:branch_${branch}`);
    }
    if ((comparison.classification === "regression" || comparison.regression === true) && comparison.evidenceAuthority === "identity_noise_only") {
      failures.push(`identity_noise_regression:branch_${branch}`);
    }
    if ((comparison.classification === "regression" || comparison.regression === true) && comparison.evidenceAuthority !== "identity_noise_only") {
      failures.push(`candidate_regression:branch_${branch}:${comparison.candidateEngineDeltaPct}`);
    }
  }
  for (const contract of contracts) {
    if (contract.passed !== true) failures.push(`route_contract_failed:${contract.id}:branch_${contract.branchCount}`);
  }
  return failures;
}

function measureSample(binaryPath, ixArgs, expression, sample) {
  const result = run(binaryPath, ixArgs);
  if (result.exitCode !== 0) {
    throw new Error(`IX sample failed for ${expression}: ${result.stderr || result.stdout}`);
  }
  const report = parseIxReport(result.stdout);
  const density = report.stats?.fast_count_density ?? {};
  const byteShard = report.stats?.byte_shard_kernel ?? {};
  const byteShardStrategy = byteShard.strategy ?? "none";
  const byteShardRangeElapsedNsTotal = Number(byteShard.range_elapsed_ns_total ?? 0);
  const byteShardRangeElapsedNsMax = Number(byteShard.max_range_elapsed_ns ?? 0);
  const alternatePcreRangeCalls = Number(density.alternate_pcre_range_calls ?? 0);
  const alternateTeddyRangeCalls = Number(density.alternate_teddy_range_calls ?? 0);
  const alternateCompiledRangeCalls = Number(density.alternate_compiled_range_calls ?? 0);
  const derivedRouteTiming =
    byteShardStrategy === "literal_alternates" &&
    (alternatePcreRangeCalls + alternateTeddyRangeCalls + alternateCompiledRangeCalls) > 0;
  return {
    sample,
    cliMs: result.durationMs,
    engineMs: Number(report.stats?.timings?.total_ms ?? result.durationMs),
    matches: Number(report.stats?.matches_found ?? 0),
    filesScanned: Number(report.stats?.files_scanned ?? 0),
    alternateRangeCalls: Number(density.alternate_range_calls ?? 0),
    alternatePcreRangeCalls,
    alternatePcreRangeElapsedNsTotal: derivedRouteTiming && alternatePcreRangeCalls > 0 ? byteShardRangeElapsedNsTotal : Number(density.alternate_pcre_range_elapsed_ns_total ?? 0),
    alternatePcreRangeElapsedNsMax: derivedRouteTiming && alternatePcreRangeCalls > 0 ? byteShardRangeElapsedNsMax : Number(density.alternate_pcre_range_elapsed_ns_max ?? 0),
    alternateTeddyRangeCalls,
    alternateTeddyRangeElapsedNsTotal: derivedRouteTiming && alternateTeddyRangeCalls > 0 ? byteShardRangeElapsedNsTotal : Number(density.alternate_teddy_range_elapsed_ns_total ?? 0),
    alternateTeddyRangeElapsedNsMax: derivedRouteTiming && alternateTeddyRangeCalls > 0 ? byteShardRangeElapsedNsMax : Number(density.alternate_teddy_range_elapsed_ns_max ?? 0),
    alternateCompiledRangeCalls,
    alternateCompiledRangeElapsedNsTotal: derivedRouteTiming && alternateCompiledRangeCalls > 0 ? byteShardRangeElapsedNsTotal : Number(density.alternate_compiled_range_elapsed_ns_total ?? 0),
    alternateCompiledRangeElapsedNsMax: derivedRouteTiming && alternateCompiledRangeCalls > 0 ? byteShardRangeElapsedNsMax : Number(density.alternate_compiled_range_elapsed_ns_max ?? 0),
    alternateFullScanCalls: Number(density.alternate_full_scan_calls ?? 0),
    alternateFullScanBytes: Number(density.alternate_full_scan_bytes ?? 0),
    alternateFullScanMatches: Number(density.alternate_full_scan_matches ?? 0),
    alternateFullScanElapsedNsTotal: Number(density.alternate_full_scan_elapsed_ns_total ?? 0),
    alternateFullScanElapsedNsMax: Number(density.alternate_full_scan_elapsed_ns_max ?? 0),
    byteShardStrategy,
    byteShardRanges: Number(byteShard.range_calls ?? 0),
  };
}

function summarizeLane(binaryPath, label, branchCount, expression, runs) {
  return {
    label,
    binaryPath,
    branchCount,
    expression,
    selectorFeatures: selectorFeatures(branchCount),
    samples: runs,
    cliSummary: summary(runs.map((entry) => entry.cliMs)),
    engineSummary: summary(runs.map((entry) => entry.engineMs)),
    counters: {
      matchCounts: [...new Set(runs.map((entry) => entry.matches))],
      filesScanned: [...new Set(runs.map((entry) => entry.filesScanned))],
      alternateRangeCalls: [...new Set(runs.map((entry) => entry.alternateRangeCalls))],
      alternatePcreRangeCalls: [...new Set(runs.map((entry) => entry.alternatePcreRangeCalls))],
      alternatePcreRangeElapsedNsTotal: [...new Set(runs.map((entry) => entry.alternatePcreRangeElapsedNsTotal))],
      alternatePcreRangeElapsedNsMax: [...new Set(runs.map((entry) => entry.alternatePcreRangeElapsedNsMax))],
      alternateTeddyRangeCalls: [...new Set(runs.map((entry) => entry.alternateTeddyRangeCalls))],
      alternateTeddyRangeElapsedNsTotal: [...new Set(runs.map((entry) => entry.alternateTeddyRangeElapsedNsTotal))],
      alternateTeddyRangeElapsedNsMax: [...new Set(runs.map((entry) => entry.alternateTeddyRangeElapsedNsMax))],
      alternateCompiledRangeCalls: [...new Set(runs.map((entry) => entry.alternateCompiledRangeCalls))],
      alternateCompiledRangeElapsedNsTotal: [...new Set(runs.map((entry) => entry.alternateCompiledRangeElapsedNsTotal))],
      alternateCompiledRangeElapsedNsMax: [...new Set(runs.map((entry) => entry.alternateCompiledRangeElapsedNsMax))],
      alternateFullScanCalls: [...new Set(runs.map((entry) => entry.alternateFullScanCalls))],
      alternateFullScanCallsSummary: summary(runs.map((entry) => entry.alternateFullScanCalls)),
      alternateFullScanBytes: [...new Set(runs.map((entry) => entry.alternateFullScanBytes))],
      alternateFullScanBytesSummary: summary(runs.map((entry) => entry.alternateFullScanBytes)),
      alternateFullScanMatches: [...new Set(runs.map((entry) => entry.alternateFullScanMatches))],
      alternateFullScanMatchesSummary: summary(runs.map((entry) => entry.alternateFullScanMatches)),
      alternateFullScanElapsedNsTotal: [...new Set(runs.map((entry) => entry.alternateFullScanElapsedNsTotal))],
      alternateFullScanElapsedNsTotalSummary: summary(runs.map((entry) => entry.alternateFullScanElapsedNsTotal)),
      alternateFullScanElapsedNsMax: [...new Set(runs.map((entry) => entry.alternateFullScanElapsedNsMax))],
      alternateFullScanElapsedNsMaxSummary: summary(runs.map((entry) => entry.alternateFullScanElapsedNsMax)),
      byteShardStrategy: [...new Set(runs.map((entry) => entry.byteShardStrategy))],
      byteShardRanges: [...new Set(runs.map((entry) => entry.byteShardRanges))],
    },
  };
}

function measure(binaryPath, label, branchCount) {
  const expression = expressionFor(branchCount);
  const ixArgs = ["search", expression, corpus, "--json", "--stats-only", "--threads", String(threads)];
  const runs = [];
  for (let sample = 1; sample <= samples; sample += 1) {
    runs.push(measureSample(binaryPath, ixArgs, expression, sample));
  }
  return summarizeLane(binaryPath, label, branchCount, expression, runs);
}

function measurePaired(candidateBinaryPath, baselineBinaryPath, branchCount) {
  const expression = expressionFor(branchCount);
  const ixArgs = ["search", expression, corpus, "--json", "--stats-only", "--threads", String(threads)];
  const candidateRuns = [];
  const baselineRuns = [];
  const pairOrder = [];
  for (let sample = 1; sample <= samples; sample += 1) {
    const candidateFirst = sample % 2 === 1;
    pairOrder.push(candidateFirst ? "candidate,baseline" : "baseline,candidate");
    if (candidateFirst) {
      candidateRuns.push(measureSample(candidateBinaryPath, ixArgs, expression, sample));
      baselineRuns.push(measureSample(baselineBinaryPath, ixArgs, expression, sample));
    } else {
      baselineRuns.push(measureSample(baselineBinaryPath, ixArgs, expression, sample));
      candidateRuns.push(measureSample(candidateBinaryPath, ixArgs, expression, sample));
    }
  }
  return {
    candidate: {
      ...summarizeLane(candidateBinaryPath, "candidate", branchCount, expression, candidateRuns),
      pairOrder,
      pairOrderSummary: pairOrderSummary(pairOrder, { firstLabel: "candidate", secondLabel: "baseline" }),
    },
    baseline: {
      ...summarizeLane(baselineBinaryPath, "baseline", branchCount, expression, baselineRuns),
      pairOrder,
      pairOrderSummary: pairOrderSummary(pairOrder, { firstLabel: "candidate", secondLabel: "baseline" }),
    },
  };
}

if (!Number.isFinite(samples) || samples < 1) throw new Error("--samples must be a positive number");
if (!Number.isFinite(threads) || threads < 1) throw new Error("--threads must be a positive number");
if (!Number.isFinite(identityControlSamples) || identityControlSamples < 0) throw new Error("--identity-control-samples must be a non-negative number");
if (!Number.isFinite(identityControlAttempts) || identityControlAttempts < 1) throw new Error("--identity-control-attempts must be a positive number");
if (!Number.isFinite(fingerprintMaxBytes) || fingerprintMaxBytes < 1) throw new Error("--fingerprint-max-bytes must be a positive number");
if (!Number.isFinite(maxBranches) || maxBranches < 2 || maxBranches > DEFAULT_TERMS.length) {
  throw new Error(`--max-branches must be between 2 and ${DEFAULT_TERMS.length}`);
}
const branchCounts = parseBranchCounts(branchCountsArg, maxBranches);
if (!existsSync(corpus)) throw new Error(`corpus not found: ${corpus}`);
if (!existsSync(ixBinary)) throw new Error(`IX binary not found: ${ixBinary}`);
if (baselineIxBinary.length > 0 && !existsSync(baselineIxBinary)) throw new Error(`baseline IX binary not found: ${baselineIxBinary}`);

if (benchmarkLock) acquireBenchmarkLock({ script: "alternates-decision-table.mjs" });

const hostBefore = hostSnapshot();
const ixBinarySha256 = fileSha256(ixBinary);
const baselineIxBinarySha256 = baselineIxBinary.length > 0 ? fileSha256(baselineIxBinary) : null;
const binaryRelation = baselineIxBinarySha256 === null
  ? "unpaired"
  : ixBinarySha256 === baselineIxBinarySha256
    ? "same_binary"
    : "different_binary";
const lanes = [];
const baselineLanes = [];
const identityControls = {};
for (const branchCount of branchCounts) {
  const expression = expressionFor(branchCount);
  const ixArgs = ["search", expression, corpus, "--json", "--stats-only", "--threads", String(threads)];
  identityControls[String(branchCount)] = measureSameBinaryIdentityControl({
    binaryPath: ixBinary,
    ixArgs,
    samples: identityControlSamples,
    attempts: identityControlAttempts,
    enabled: identityControlEnabled,
    label: `candidate-control-branch-${branchCount}`,
  });
  if (baselineIxBinary.length > 0) {
    const paired = measurePaired(ixBinary, baselineIxBinary, branchCount);
    lanes.push(paired.candidate);
    baselineLanes.push(paired.baseline);
  } else {
    lanes.push(measure(ixBinary, "candidate", branchCount));
  }
}
const hostAfter = hostSnapshot();

const comparisons = lanes.map((lane) => {
  const baseline = baselineLanes.find((entry) => entry.branchCount === lane.branchCount) ?? null;
  if (!baseline) return null;
  const candidateMedian = lane.engineSummary.median;
  const baselineMedian = baseline.engineSummary.median;
  const deltaMs = candidateMedian - baselineMedian;
  const deltaPct = baselineMedian > 0 ? (deltaMs / baselineMedian) * 100 : null;
  const regression = typeof deltaPct === "number" && deltaPct > maxRegressionPct;
  const candidatePcreTotalSummary = summarizeCounterValues(lane.counters.alternatePcreRangeElapsedNsTotal);
  const baselinePcreTotalSummary = summarizeCounterValues(baseline.counters.alternatePcreRangeElapsedNsTotal);
  const candidatePcreMaxSummary = summarizeCounterValues(lane.counters.alternatePcreRangeElapsedNsMax);
  const baselinePcreMaxSummary = summarizeCounterValues(baseline.counters.alternatePcreRangeElapsedNsMax);
  const candidateTeddyTotalSummary = summarizeCounterValues(lane.counters.alternateTeddyRangeElapsedNsTotal);
  const baselineTeddyTotalSummary = summarizeCounterValues(baseline.counters.alternateTeddyRangeElapsedNsTotal);
  const candidateTeddyMaxSummary = summarizeCounterValues(lane.counters.alternateTeddyRangeElapsedNsMax);
  const baselineTeddyMaxSummary = summarizeCounterValues(baseline.counters.alternateTeddyRangeElapsedNsMax);
  const candidateCompiledTotalSummary = summarizeCounterValues(lane.counters.alternateCompiledRangeElapsedNsTotal);
  const baselineCompiledTotalSummary = summarizeCounterValues(baseline.counters.alternateCompiledRangeElapsedNsTotal);
  const candidateCompiledMaxSummary = summarizeCounterValues(lane.counters.alternateCompiledRangeElapsedNsMax);
  const baselineCompiledMaxSummary = summarizeCounterValues(baseline.counters.alternateCompiledRangeElapsedNsMax);
  const candidatePcreMedianMs = nsSummaryToMs(candidatePcreTotalSummary);
  const baselinePcreMedianMs = nsSummaryToMs(baselinePcreTotalSummary);
  const candidateTeddyMedianMs = nsSummaryToMs(candidateTeddyTotalSummary);
  const baselineTeddyMedianMs = nsSummaryToMs(baselineTeddyTotalSummary);
  const candidateCompiledMedianMs = nsSummaryToMs(candidateCompiledTotalSummary);
  const baselineCompiledMedianMs = nsSummaryToMs(baselineCompiledTotalSummary);
  const fullScanCallsParity = JSON.stringify(lane.counters.alternateFullScanCalls) === JSON.stringify(baseline.counters.alternateFullScanCalls);
  const fullScanBytesParity = JSON.stringify(lane.counters.alternateFullScanBytes) === JSON.stringify(baseline.counters.alternateFullScanBytes);
  const fullScanMatchesParity = JSON.stringify(lane.counters.alternateFullScanMatches) === JSON.stringify(baseline.counters.alternateFullScanMatches);
  return {
    branchCount: lane.branchCount,
    expression: lane.expression,
    selectorFeatures: lane.selectorFeatures,
    candidateEngineMedianMs: candidateMedian,
    baselineEngineMedianMs: baselineMedian,
    candidateVsBaselineRatio: baselineMedian > 0 ? candidateMedian / baselineMedian : null,
    candidateEngineDeltaMs: deltaMs,
    candidateEngineDeltaPct: deltaPct,
    maxRegressionPct,
    binaryRelation,
    evidenceAuthority: binaryRelation === "same_binary" ? "identity_noise_only" : "candidate_vs_baseline",
    pairedEngine: pairedEngineStats(baseline.samples, lane.samples, {
      baselineLabel: "baseline",
      candidateLabel: "candidate",
    }),
    pairOrder: lane.pairOrder ?? [],
    pairOrderSummary: lane.pairOrderSummary ?? null,
    regression,
    classification: regression ? "regression" : deltaMs < 0 ? "improvement" : "parity",
    regressionConfirmation: null,
    matchParity: JSON.stringify(lane.counters.matchCounts) === JSON.stringify(baseline.counters.matchCounts),
    fullScanCallsParity,
    fullScanBytesParity,
    fullScanMatchesParity,
    candidateAlternateFullScanCalls: lane.counters.alternateFullScanCalls,
    baselineAlternateFullScanCalls: baseline.counters.alternateFullScanCalls,
    candidateAlternateFullScanCallsSummary: lane.counters.alternateFullScanCallsSummary,
    baselineAlternateFullScanCallsSummary: baseline.counters.alternateFullScanCallsSummary,
    candidateAlternateFullScanBytes: lane.counters.alternateFullScanBytes,
    baselineAlternateFullScanBytes: baseline.counters.alternateFullScanBytes,
    candidateAlternateFullScanBytesSummary: lane.counters.alternateFullScanBytesSummary,
    baselineAlternateFullScanBytesSummary: baseline.counters.alternateFullScanBytesSummary,
    candidateAlternateFullScanMatches: lane.counters.alternateFullScanMatches,
    baselineAlternateFullScanMatches: baseline.counters.alternateFullScanMatches,
    candidateAlternateFullScanMatchesSummary: lane.counters.alternateFullScanMatchesSummary,
    baselineAlternateFullScanMatchesSummary: baseline.counters.alternateFullScanMatchesSummary,
    candidateAlternateFullScanElapsedNsTotal: lane.counters.alternateFullScanElapsedNsTotal,
    baselineAlternateFullScanElapsedNsTotal: baseline.counters.alternateFullScanElapsedNsTotal,
    candidateAlternateFullScanElapsedNsTotalSummary: lane.counters.alternateFullScanElapsedNsTotalSummary,
    baselineAlternateFullScanElapsedNsTotalSummary: baseline.counters.alternateFullScanElapsedNsTotalSummary,
    candidatePcreRanges: lane.counters.alternatePcreRangeCalls,
    baselinePcreRanges: baseline.counters.alternatePcreRangeCalls,
    candidatePcreElapsedNsTotal: lane.counters.alternatePcreRangeElapsedNsTotal,
    baselinePcreElapsedNsTotal: baseline.counters.alternatePcreRangeElapsedNsTotal,
    candidatePcreElapsedNsTotalSummary: candidatePcreTotalSummary,
    baselinePcreElapsedNsTotalSummary: baselinePcreTotalSummary,
    candidatePcreElapsedMedianMs: candidatePcreMedianMs,
    baselinePcreElapsedMedianMs: baselinePcreMedianMs,
    candidatePcreEngineSharePct: medianSharePct(candidatePcreMedianMs, candidateMedian),
    baselinePcreEngineSharePct: medianSharePct(baselinePcreMedianMs, baselineMedian),
    candidatePcreElapsedNsMax: lane.counters.alternatePcreRangeElapsedNsMax,
    baselinePcreElapsedNsMax: baseline.counters.alternatePcreRangeElapsedNsMax,
    candidatePcreElapsedNsMaxSummary: candidatePcreMaxSummary,
    baselinePcreElapsedNsMaxSummary: baselinePcreMaxSummary,
    candidateTeddyRanges: lane.counters.alternateTeddyRangeCalls,
    baselineTeddyRanges: baseline.counters.alternateTeddyRangeCalls,
    candidateTeddyElapsedNsTotal: lane.counters.alternateTeddyRangeElapsedNsTotal,
    baselineTeddyElapsedNsTotal: baseline.counters.alternateTeddyRangeElapsedNsTotal,
    candidateTeddyElapsedNsTotalSummary: candidateTeddyTotalSummary,
    baselineTeddyElapsedNsTotalSummary: baselineTeddyTotalSummary,
    candidateTeddyElapsedMedianMs: candidateTeddyMedianMs,
    baselineTeddyElapsedMedianMs: baselineTeddyMedianMs,
    candidateTeddyEngineSharePct: medianSharePct(candidateTeddyMedianMs, candidateMedian),
    baselineTeddyEngineSharePct: medianSharePct(baselineTeddyMedianMs, baselineMedian),
    candidateTeddyElapsedNsMax: lane.counters.alternateTeddyRangeElapsedNsMax,
    baselineTeddyElapsedNsMax: baseline.counters.alternateTeddyRangeElapsedNsMax,
    candidateTeddyElapsedNsMaxSummary: candidateTeddyMaxSummary,
    baselineTeddyElapsedNsMaxSummary: baselineTeddyMaxSummary,
    candidateCompiledRanges: lane.counters.alternateCompiledRangeCalls,
    baselineCompiledRanges: baseline.counters.alternateCompiledRangeCalls,
    candidateCompiledElapsedNsTotal: lane.counters.alternateCompiledRangeElapsedNsTotal,
    baselineCompiledElapsedNsTotal: baseline.counters.alternateCompiledRangeElapsedNsTotal,
    candidateCompiledElapsedNsTotalSummary: candidateCompiledTotalSummary,
    baselineCompiledElapsedNsTotalSummary: baselineCompiledTotalSummary,
    candidateCompiledElapsedMedianMs: candidateCompiledMedianMs,
    baselineCompiledElapsedMedianMs: baselineCompiledMedianMs,
    candidateCompiledEngineSharePct: medianSharePct(candidateCompiledMedianMs, candidateMedian),
    baselineCompiledEngineSharePct: medianSharePct(baselineCompiledMedianMs, baselineMedian),
    candidateCompiledElapsedNsMax: lane.counters.alternateCompiledRangeElapsedNsMax,
    baselineCompiledElapsedNsMax: baseline.counters.alternateCompiledRangeElapsedNsMax,
    candidateCompiledElapsedNsMaxSummary: candidateCompiledMaxSummary,
    baselineCompiledElapsedNsMaxSummary: baselineCompiledMaxSummary,
  };
}).filter(Boolean);
for (const comparison of comparisons) {
  comparison.candidatePath = ixBinary;
  comparison.baselinePath = baselineIxBinary.length > 0 ? baselineIxBinary : null;
  comparison.candidateSha256 = ixBinarySha256;
  comparison.baselineSha256 = baselineIxBinarySha256;
  comparison.regressionConfirmation = confirmationForComparison(comparison);
}
comparisons.forEach((comparison, index) => {
  comparison.score = buildAlternatesComparisonScore({
    comparison,
    roundIndex: index + 1,
    minImprovementPct: 0,
  });
});
const comparisonSummary = summarizeComparisons(comparisons);
const scorecard = buildAlternatesScorecard(comparisons);
const roundLedger = buildAlternatesRoundLedger(comparisons);
const contracts = routeContracts(comparisons);
const targets = optimizationTargets(comparisons);
const nextMoves = nextMovesForTargets(targets);
const requiredFailureList = requiredDecisionFailures({
  host: { before: hostBefore, after: hostAfter },
  baselinePath: baselineIxBinary.length > 0 ? baselineIxBinary : null,
  relation: binaryRelation,
  comparisons,
  contracts,
  identityControls,
});
const requiredGateFailures = requiredFailureList.length > 0
  ? [
      {
        gate: "alternates_decision",
        reason: "alternates decision evidence required",
        failures: requiredFailureList,
      },
    ]
  : [];
const fingerprintAnalyses = fingerprintCorpus
  ? Object.fromEntries(branchCounts.map((branchCount) => [String(branchCount), analyzeFingerprintWindows(branchCount)]))
  : {};

const report = {
  runId: `alternates-decision-${timestampSlug()}`,
  timestamp: new Date().toISOString(),
  corpus,
  ixBinary,
  baselineIxBinary: baselineIxBinary.length > 0 ? baselineIxBinary : null,
  binaryHashes: {
    candidateSha256: ixBinarySha256,
    baselineSha256: baselineIxBinarySha256,
    relation: binaryRelation,
  },
  samples,
  identityControlSamples: identityControlEnabled ? identityControlSamples : 0,
  identityControlAttempts: identityControlEnabled ? identityControlAttempts : 0,
  threads,
  branchCounts,
  branchCountsArg: branchCountsArg.length > 0 ? branchCountsArg : null,
  maxRegressionPct,
  caseInsensitive,
  host: { before: hostBefore, after: hostAfter },
  lanes,
  baselineLanes,
  identityControls,
  comparisons,
  comparisonSummary,
  scorecard,
  roundLedger,
  routeContracts: contracts,
  requiredGateFailures,
  fingerprintAnalyses,
  teddyFingerprintOffsetEnv,
  optimizationTargets: targets,
  nextMoves,
};

mkdirSync(REPORT_DIR, { recursive: true });
const outPath = path.join(REPORT_DIR, `${report.runId}.json`);
writeFileSync(outPath, `${JSON.stringify(report, null, 2)}\n`, "utf8");
writeFileSync(path.join(REPORT_DIR, "latest-alternates-decision.json"), `${JSON.stringify(report, null, 2)}\n`, "utf8");

if (!quiet) {
  console.log(JSON.stringify({
    outPath,
    caseInsensitive,
    branchCounts,
    baseline: baselineIxBinary.length > 0,
    optimizationTargets: targets.map((target) => ({
      branchCount: target.branchCount,
      route: target.candidateRoute,
      deltaPct: target.candidateEngineDeltaPct,
      routeSharePct: target.candidateRouteEngineSharePct,
      routeElapsedAuthority: target.candidateRouteElapsedAuthority,
    })),
    routeContracts: contracts,
    requiredGateFailures,
    fingerprintAnalyses,
    nextMoves,
    rows: lanes.map((lane) => ({
      branchCount: lane.branchCount,
      engineMedianMs: lane.engineSummary.median,
      matches: lane.counters.matchCounts,
      pcreRanges: lane.counters.alternatePcreRangeCalls,
      teddyRanges: lane.counters.alternateTeddyRangeCalls,
      compiledRanges: lane.counters.alternateCompiledRangeCalls,
      fullScanCalls: lane.counters.alternateFullScanCalls,
      fullScanBytes: lane.counters.alternateFullScanBytes,
      fullScanMatches: lane.counters.alternateFullScanMatches,
      byteShardStrategy: lane.counters.byteShardStrategy,
      firstByteFanout: lane.selectorFeatures.firstByteFanout,
      foldedFirstByteFanout: lane.selectorFeatures.foldedFirstByteFanout,
      prefixCollisionDensity: lane.selectorFeatures.prefixCollisionDensity,
      branchLengthMean: lane.selectorFeatures.branchLengths.mean,
    })),
    comparisons: comparisons.map((comparison) => ({
      branchCount: comparison.branchCount,
      candidateEngineMedianMs: comparison.candidateEngineMedianMs,
      baselineEngineMedianMs: comparison.baselineEngineMedianMs,
      candidateVsBaselineRatio: comparison.candidateVsBaselineRatio,
      candidateEngineDeltaPct: comparison.candidateEngineDeltaPct,
      classification: comparison.classification,
      matchParity: comparison.matchParity,
      fullScanCallsParity: comparison.fullScanCallsParity,
      fullScanBytesParity: comparison.fullScanBytesParity,
      fullScanMatchesParity: comparison.fullScanMatchesParity,
      candidateAlternateFullScanCallsMedian: comparison.candidateAlternateFullScanCallsSummary?.median ?? null,
      baselineAlternateFullScanCallsMedian: comparison.baselineAlternateFullScanCallsSummary?.median ?? null,
      candidateAlternateFullScanBytesMedian: comparison.candidateAlternateFullScanBytesSummary?.median ?? null,
      baselineAlternateFullScanBytesMedian: comparison.baselineAlternateFullScanBytesSummary?.median ?? null,
      candidateAlternateFullScanMatchesMedian: comparison.candidateAlternateFullScanMatchesSummary?.median ?? null,
      baselineAlternateFullScanMatchesMedian: comparison.baselineAlternateFullScanMatchesSummary?.median ?? null,
      candidateAlternateFullScanElapsedNsMedian: comparison.candidateAlternateFullScanElapsedNsTotalSummary?.median ?? null,
      baselineAlternateFullScanElapsedNsMedian: comparison.baselineAlternateFullScanElapsedNsTotalSummary?.median ?? null,
      pairedEngine: comparison.pairedEngine
        ? {
            count: comparison.pairedEngine.count,
            candidateWins: comparison.pairedEngine.candidateWins,
            baselineWins: comparison.pairedEngine.baselineWins,
            candidateWinRate: comparison.pairedEngine.candidateWinRate,
            deltaMedianMs: comparison.pairedEngine.deltaSummary?.median ?? null,
            candidateImprovementMedianPct: comparison.pairedEngine.candidateImprovementPctSummary?.median ?? null,
          }
        : null,
    })),
    comparisonSummary,
  }, null, 2));
}
