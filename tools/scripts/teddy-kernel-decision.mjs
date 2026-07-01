import { existsSync, mkdirSync, readFileSync, readdirSync, writeFileSync } from "node:fs";
import { createHash } from "node:crypto";
import path from "node:path";
import { evidenceQualityFromFailures } from "./lib/benchmark-evidence-quality.mjs";
import { argValue, timestampSlug } from "./lib/script-helpers.mjs";
import { phaseLeakSummaryFromRounds } from "./lib/speed-compare-utils.mjs";

const ROOT = process.cwd();
const HISTORICAL_REPORT_DIR = path.join(ROOT, "tools", "reports", "historical-speed");
const LATEST_HISTORICAL_PATH = path.join(HISTORICAL_REPORT_DIR, "latest-historical-speed.json");
const LATEST_RETAINABLE_HISTORICAL_PATH = path.join(HISTORICAL_REPORT_DIR, "latest-retainable-historical-speed.json");
const INSTALLED_REPORT_DIR = path.join(ROOT, "tools", "reports", "manual-speed-compare");
const LATEST_INSTALLED_PATH = path.join(INSTALLED_REPORT_DIR, "latest-installed-speed.json");
const LATEST_RETAINABLE_INSTALLED_PATH = path.join(INSTALLED_REPORT_DIR, "latest-retainable-installed-speed.json");
const OLDER_SNAPSHOT_REPORT_DIR = path.join(ROOT, "tools", "reports", "older-snapshot-ladder");
const LATEST_OLDER_SNAPSHOT_PATH = path.join(OLDER_SNAPSHOT_REPORT_DIR, "latest-older-snapshot-ladder.json");
const REPORT_DIR = path.join(ROOT, "tools", "reports", "teddy-kernel-decision");
const DEFAULT_CURRENT_IX = path.join(ROOT, "zig-out", "bin", process.platform === "win32" ? "ix-zig.exe" : "ix-zig");
const REQUIRED_INSTALLED_THREADS = 32;
const TEDDY_CONTRACT = path.join(ROOT, ".docs", "research", "2026-06-12-teddy-literal-alternates-contract.md");
const INSECT_SIMD_RESEARCH = path.join(ROOT, ".docs", "research", "insect-simd-multipattern-prefilter-20260613.json");
const INSECT_ATTRIBUTION_RESEARCH = path.join(ROOT, ".docs", "research", "insect-performance-attribution-next-20260613.json");
const INSECT_LITERAL_ALTERNATES_REFRESH = path.join(ROOT, ".docs", "research", "insect-literal-alternates-prefilter-refresh-20260613.json");
const INSECT_TEDDY_ATTRIBUTION_REFRESH = path.join(ROOT, ".docs", "research", "insect-teddy-attribution-refresh-20260613.json");
const INSECT_PACKED_TEDDY_SHUFTI_REFRESH = path.join(ROOT, ".docs", "research", "insect-packed-teddy-shufti-refresh-20260613.json");
const HISTORICAL_SPEED_DIAGNOSTIC_COMMAND =
  "node tools/scripts/compare-historical-speed.mjs --samples 12 --identity-control-samples 12 --identity-control-attempts 3 --max-backups 4 --quiet --no-require-strict";
const HISTORICAL_SPEED_SCAN_OPEN_DIAGNOSTIC_COMMAND =
  "node tools/scripts/compare-historical-speed.mjs --samples 12 --identity-control-samples 12 --identity-control-attempts 3 --max-backups 4 --quiet --no-require-strict --scan-open-timing";
const HISTORICAL_SPEED_STRICT_COMMAND =
  "node tools/scripts/compare-historical-speed.mjs --samples 12 --identity-control-samples 12 --identity-control-attempts 3 --max-backups 4 --quiet --require-strict";
const HISTORICAL_SPEED_SCAN_OPEN_STRICT_COMMAND =
  "node tools/scripts/compare-historical-speed.mjs --samples 12 --identity-control-samples 12 --identity-control-attempts 3 --max-backups 4 --quiet --require-strict --scan-open-timing";
const OLDER_SNAPSHOT_PROOF_COMMAND =
  "node tools/scripts/compare-older-snapshots.mjs --samples 12 --identity-control-samples 12 --identity-control-attempts 3 --min-retainable-samples 12 --max-snapshots 2 --target-retainable-snapshots 2 --min-engine-improvement-pct 5 --min-paired-improvement-pct 5 --require-strict --quiet";
const INSTALLED_SPEED_STRICT_COMMAND =
  "node tools/scripts/compare-installed-speed.mjs --samples 12 --identity-control-samples 12 --identity-control-attempts 3 --min-retainable-samples 12 --require-strict --require-promotion --quiet";
const SPEED_DIAGNOSTIC_COMMAND = `${HISTORICAL_SPEED_DIAGNOSTIC_COMMAND} && ${OLDER_SNAPSHOT_PROOF_COMMAND}`;
const SPEED_LEAK_ATTRIBUTION_COMMAND = `${HISTORICAL_SPEED_SCAN_OPEN_DIAGNOSTIC_COMMAND} && ${OLDER_SNAPSHOT_PROOF_COMMAND}`;
const SPEED_SCAN_OPEN_PROMOTION_COMMAND = `${HISTORICAL_SPEED_SCAN_OPEN_STRICT_COMMAND} && ${OLDER_SNAPSHOT_PROOF_COMMAND}`;
const SPEED_PROMOTION_COMMAND = `${INSTALLED_SPEED_STRICT_COMMAND} && ${HISTORICAL_SPEED_STRICT_COMMAND} && ${OLDER_SNAPSHOT_PROOF_COMMAND}`;

const args = process.argv.slice(2);
if (args.includes("--help") || args.includes("-h")) {
  console.log(`Usage: node tools/scripts/teddy-kernel-decision.mjs [options]

Reads one-at-a-time historical speed reports plus Teddy/Insect research and
emits the next kernel decision. This is a decision harness only; it does not
modify IX runtime code.

Options:
  --report <path>       Historical speed report to evaluate. Default: newest fresh current-binary report.
  --current-ix <path>   Current repo IX binary used to verify report freshness.
  --out <path>          Output report path.
  --quiet               Write report without printing summary.
  --help, -h            Print this help and exit.
`);
  process.exit(0);
}

const currentIx = argValue(args, "--current-ix", DEFAULT_CURRENT_IX);
const currentIxSha256 = sha256File(currentIx);
const explicitReportPath = argValue(args, "--report", "");
const reportSelection = explicitReportPath.length > 0 ? "explicit" : "newest_fresh_current_binary";
const reportPath = explicitReportPath.length > 0
  ? explicitReportPath
  : (selectFreshHistoricalReport(currentIxSha256) ?? path.join(HISTORICAL_REPORT_DIR, "latest-historical-speed.json"));
const outPath = argValue(args, "--out", path.join(REPORT_DIR, `teddy-kernel-decision-${timestampSlug()}.json`));
const quiet = args.includes("--quiet");

function readJson(filePath, fallback = null) {
  if (!existsSync(filePath)) return fallback;
  return JSON.parse(readFileSync(filePath, "utf8"));
}

function readText(filePath) {
  return existsSync(filePath) ? readFileSync(filePath, "utf8") : "";
}

function sha256File(filePath) {
  if (!existsSync(filePath)) return null;
  return createHash("sha256").update(readFileSync(filePath)).digest("hex").toUpperCase();
}

function historicalComparisonHashes(report) {
  return Array.isArray(report?.comparisons)
    ? [...new Set(report.comparisons.map((comparison) => comparison?.current?.sha256).filter(Boolean))]
    : [];
}

function reportMatchesCurrentBinary(report, currentHash) {
  const hashes = historicalComparisonHashes(report);
  return currentHash != null && hashes.length > 0 && hashes.every((hash) => hash === currentHash);
}

function selectFreshHistoricalReport(currentHash) {
  if (!existsSync(HISTORICAL_REPORT_DIR) || currentHash == null) return null;
  const candidates = readdirSync(HISTORICAL_REPORT_DIR)
    .filter((name) => /^historical-speed-.*\.json$/.test(name))
    .map((name) => {
      const fullPath = path.join(HISTORICAL_REPORT_DIR, name);
      const report = readJson(fullPath, {});
      return {
        path: fullPath,
        timestamp: report.timestamp ?? null,
        runId: report.runId ?? name.replace(/\.json$/, ""),
        fresh: reportMatchesCurrentBinary(report, currentHash),
        diagnostic: report.diagnosticAttributionMode === true,
      };
    })
    .filter((entry) => entry.fresh && !entry.diagnostic)
    .sort((left, right) => String(right.timestamp ?? right.runId).localeCompare(String(left.timestamp ?? left.runId)));
  return candidates[0]?.path ?? null;
}

function selectFreshDiagnosticHistoricalReport(currentHash) {
  if (!existsSync(HISTORICAL_REPORT_DIR) || currentHash == null) return null;
  const candidates = readdirSync(HISTORICAL_REPORT_DIR)
    .filter((name) => /^historical-speed-.*\.json$/.test(name))
    .map((name) => {
      const fullPath = path.join(HISTORICAL_REPORT_DIR, name);
      const report = readJson(fullPath, {});
      return {
        path: fullPath,
        timestamp: report.timestamp ?? null,
        runId: report.runId ?? name.replace(/\.json$/, ""),
        fresh: reportMatchesCurrentBinary(report, currentHash),
        diagnostic: report.diagnosticAttributionMode === true,
      };
    })
    .filter((entry) => entry.fresh && entry.diagnostic)
    .sort((left, right) => String(right.timestamp ?? right.runId).localeCompare(String(left.timestamp ?? left.runId)));
  return candidates[0]?.path ?? null;
}

function latestHistoricalReports(limit = 8) {
  if (!existsSync(HISTORICAL_REPORT_DIR)) return [];
  return readdirSync(HISTORICAL_REPORT_DIR)
    .filter((name) => /^historical-speed-.*\.json$/.test(name))
    .map((name) => {
      const fullPath = path.join(HISTORICAL_REPORT_DIR, name);
      const report = readJson(fullPath, {});
      return {
        path: fullPath,
        runId: report.runId ?? name.replace(/\.json$/, ""),
        timestamp: report.timestamp ?? null,
        scorecard: report.scorecard ?? null,
        diagnosticAttributionMode: report.diagnosticAttributionMode === true,
        roundCount: Array.isArray(report.roundLedger) ? report.roundLedger.length : 0,
        candidateHashes: historicalComparisonHashes(report),
        freshForCurrentBinary: reportMatchesCurrentBinary(report, currentIxSha256),
        netPositiveRounds: Number(report.scorecard?.netPositiveRounds ?? 0),
        netPositive: report.scorecard?.netPositive === true,
      };
    })
    .sort((left, right) => String(right.timestamp ?? right.runId).localeCompare(String(left.timestamp ?? left.runId)))
    .slice(0, limit);
}

function historicalPointerStatus(filePath, currentHash) {
  if (!existsSync(filePath)) {
    return {
      path: path.relative(ROOT, filePath),
      exists: false,
      status: "missing",
      runId: null,
      timestamp: null,
      freshForCurrentBinary: false,
      retainableStrictEvidence: false,
      strictEvidenceFailureCount: null,
    };
  }

  const pointer = readJson(filePath, {});
  const freshForCurrentBinary = reportMatchesCurrentBinary(pointer, currentHash);
  const retainableStrictEvidence = pointer.retainableStrictEvidence === true;
  const strictEvidenceFailures = Array.isArray(pointer.strictEvidenceFailures)
    ? pointer.strictEvidenceFailures
    : [];
  let status = "retainable_current";
  if (!freshForCurrentBinary) status = "stale_current_binary";
  else if (!retainableStrictEvidence) status = "strict_failed";

  return {
    path: path.relative(ROOT, filePath),
    exists: true,
    status,
    runId: pointer.runId ?? null,
    timestamp: pointer.timestamp ?? null,
    freshForCurrentBinary,
    retainableStrictEvidence,
    strictEvidenceFailureCount: strictEvidenceFailures.length,
  };
}

function installedPointerStatus(filePath, currentHash) {
  if (!existsSync(filePath)) {
    return {
      path: path.relative(ROOT, filePath),
      exists: false,
      status: "missing",
      runId: null,
      timestamp: null,
      freshForCurrentBinary: false,
      retainableStrictEvidence: false,
      promotionQualified: false,
      promotionFailureCount: null,
      repoSha256: null,
      installedPath: null,
      threads: null,
    };
  }

  const pointer = readJson(filePath, {});
  const repoSha256 = pointer.binaries?.repo?.sha256 ?? null;
  const installedPath = pointer.binaries?.installed?.path ?? null;
  const threads = Number(pointer.threads);
  const normalizedInstalledPath = String(installedPath ?? "").replaceAll("\\", "/").toLowerCase();
  const freshForCurrentBinary = currentHash != null && repoSha256 === currentHash;
  const canonicalThreadConfig = threads === REQUIRED_INSTALLED_THREADS;
  const nativeInstalledBaseline =
    normalizedInstalledPath.includes("/appdata/local/programs/iex/bin/ix.exe") &&
    !normalizedInstalledPath.includes("/tmp-baselines/");
  const retainableStrictEvidence = pointer.retainableStrictEvidence === true;
  const promotionQualified = pointer.promotionQualified === true;
  const promotionFailures = Array.isArray(pointer.promotionFailures)
    ? pointer.promotionFailures
    : [];
  const diagnosticAttributionMode =
    pointer.diagnosticAttributionMode === true ||
    promotionFailures.includes("diagnostic_attribution_run_not_promotion_evidence");
  const installedEngineMedianMs = Number(pointer.installedRepoComparison?.installedEngineMedianMs);
  const repoEngineMedianMs = Number(pointer.installedRepoComparison?.repoEngineMedianMs);
  const installedEngineVsRepoEnginePct = Number(pointer.deltasPct?.installedEngineVsRepoEngine);
  const installedRound = Array.isArray(pointer.roundLedger) ? pointer.roundLedger[0] : null;
  const installedPairedImprovementMedianPct = Number(installedRound?.pairedCandidateImprovementMedianPct);
  const repoPairedWinRate = Number(installedRound?.pairedCandidateWinRate);
  const ripgrepCliMedianMs = Number(pointer.lanes?.ripgrep?.summary?.median);
  const ripgrepNoMmapCliMedianMs = Number(pointer.lanes?.ripgrepMmapComparison?.never?.summary?.median);
  const ripgrepFastestMmapMode = pointer.lanes?.ripgrepMmapComparison?.fastest ?? null;
  let status = "promotable_current";
  if (!freshForCurrentBinary) status = "stale_current_binary";
  else if (!canonicalThreadConfig) status = "wrong_thread_config";
  else if (!nativeInstalledBaseline) status = "wrong_baseline";
  else if (diagnosticAttributionMode) status = "diagnostic_only";
  else if (!retainableStrictEvidence) status = "strict_failed";
  else if (!promotionQualified) status = "promotion_failed";

  return {
    path: path.relative(ROOT, filePath),
    exists: true,
    status,
    runId: pointer.runId ?? null,
    timestamp: pointer.timestamp ?? null,
    freshForCurrentBinary,
    diagnosticAttributionMode,
    retainableStrictEvidence,
    promotionQualified,
    promotionFailureCount: promotionFailures.length,
    promotionFailures,
    promotionDeficit: {
      installedEngineMedianMs: Number.isFinite(installedEngineMedianMs) ? installedEngineMedianMs : null,
      repoEngineMedianMs: Number.isFinite(repoEngineMedianMs) ? repoEngineMedianMs : null,
      installedEngineVsRepoEnginePct: Number.isFinite(installedEngineVsRepoEnginePct) ? installedEngineVsRepoEnginePct : null,
      installedPairedImprovementMedianPct: Number.isFinite(installedPairedImprovementMedianPct) ? installedPairedImprovementMedianPct : null,
      repoPairedWinRate: Number.isFinite(repoPairedWinRate) ? repoPairedWinRate : null,
      ripgrepCliMedianMs: Number.isFinite(ripgrepCliMedianMs) ? ripgrepCliMedianMs : null,
      ripgrepNoMmapCliMedianMs: Number.isFinite(ripgrepNoMmapCliMedianMs) ? ripgrepNoMmapCliMedianMs : null,
      ripgrepFastestMmapMode,
    },
    repoSha256,
    installedPath,
    threads: Number.isFinite(threads) ? threads : null,
  };
}

function selectRetainableFreshNativeInstalledReport(currentHash) {
  if (!existsSync(INSTALLED_REPORT_DIR) || currentHash == null) return null;
  const candidates = readdirSync(INSTALLED_REPORT_DIR)
    .filter((name) => /^installed-speed-.*\.json$/.test(name))
    .map((name) => {
      const fullPath = path.join(INSTALLED_REPORT_DIR, name);
      const status = installedPointerStatus(fullPath, currentHash);
      return {
        path: fullPath,
        timestamp: status.timestamp ?? null,
        runId: status.runId ?? name.replace(/\.json$/, ""),
        status,
      };
    })
    .filter((entry) =>
      entry.status.freshForCurrentBinary === true &&
      entry.status.threads === REQUIRED_INSTALLED_THREADS &&
      entry.status.retainableStrictEvidence === true &&
      entry.status.status !== "wrong_baseline" &&
      entry.status.status !== "wrong_thread_config" &&
      entry.status.status !== "diagnostic_only")
    .sort((left, right) => String(right.timestamp ?? right.runId).localeCompare(String(left.timestamp ?? left.runId)));
  return candidates[0]?.path ?? null;
}

function selectedInstalledPointerStatus(speedProofPointers) {
  const retainable = speedProofPointers?.latestInstalled ?? null;
  const diagnostic = speedProofPointers?.latestInstalledDiagnostic ?? null;
  if (retainable?.status === "promotable_current") return retainable;
  if (diagnostic?.freshForCurrentBinary === true && !["missing", "diagnostic_only"].includes(diagnostic?.status)) return diagnostic;
  return retainable ?? diagnostic ?? null;
}

function olderSnapshotPointerStatus(filePath) {
  if (!existsSync(filePath)) {
    return {
      path: path.relative(ROOT, filePath),
      exists: false,
      status: "missing",
      runId: null,
      timestamp: null,
      retainableEvidence: false,
      retainableSnapshots: 0,
      runnableSnapshots: 0,
      skippedSnapshots: 0,
      failureCount: null,
    };
  }

  const pointer = readJson(filePath, {});
  const rounds = Array.isArray(pointer.rounds) ? pointer.rounds : [];
  const failures = Array.isArray(pointer.failures) ? pointer.failures : [];
  const retainableEvidence = pointer.retainableEvidence === true;
  const retainableSnapshots = Number(pointer.retainableSnapshots ?? rounds.filter((round) => round.status === "net_positive").length);
  const runnableSnapshots = Number(pointer.runnableSnapshots ?? rounds.filter((round) => round.runnable === true).length);
  const skippedSnapshots = Number(pointer.skippedSnapshots ?? rounds.filter((round) => round.runnable === false || round.status === "skipped").length);
  let status = "retainable_current";
  if (!retainableEvidence) status = "strict_failed";
  else if (retainableSnapshots < Number(pointer.targetRetainableSnapshots ?? 1)) status = "insufficient_retainable_snapshots";

  return {
    path: path.relative(ROOT, filePath),
    exists: true,
    status,
    runId: pointer.runId ?? null,
    timestamp: pointer.timestamp ?? pointer.generatedAt ?? null,
    retainableEvidence,
    retainableSnapshots: Number.isFinite(retainableSnapshots) ? retainableSnapshots : 0,
    runnableSnapshots: Number.isFinite(runnableSnapshots) ? runnableSnapshots : 0,
    skippedSnapshots: Number.isFinite(skippedSnapshots) ? skippedSnapshots : 0,
    failureCount: failures.length,
  };
}

function finiteNumbers(values) {
  return values.map(Number).filter(Number.isFinite);
}

function average(values) {
  const finite = finiteNumbers(values);
  if (finite.length === 0) return null;
  return finite.reduce((sum, value) => sum + value, 0) / finite.length;
}

function min(values) {
  const finite = finiteNumbers(values);
  if (finite.length === 0) return null;
  return Math.min(...finite);
}

function max(values) {
  const finite = finiteNumbers(values);
  if (finite.length === 0) return null;
  return Math.max(...finite);
}

function roundSummary(rounds) {
  const fullScanCallsParity = rounds.every((round) =>
    Number(round.baselineAlternateFullScanCallsMedian) === Number(round.candidateAlternateFullScanCallsMedian));
  const fullScanBytesParity = rounds.every((round) =>
    Number(round.baselineAlternateFullScanBytesMedian) === Number(round.candidateAlternateFullScanBytesMedian));
  const fullScanMatchesParity = rounds.every((round) =>
    Number(round.baselineAlternateFullScanMatchesMedian) === Number(round.candidateAlternateFullScanMatchesMedian));
  return {
    count: rounds.length,
    netPositiveRounds: rounds.filter((round) => round.netPositive === true).length,
    worstEngineImprovementPct: min(rounds.map((round) => round.engineImprovementPct)),
    bestEngineImprovementPct: max(rounds.map((round) => round.engineImprovementPct)),
    averageEngineImprovementPct: average(rounds.map((round) => round.engineImprovementPct)),
    averagePairedEngineMedianPct: average(rounds.map((round) => round.pairedCandidateImprovementMedianPct)),
    averagePairedDiscoverMedianPct: average(rounds.map((round) => round.pairedCandidateDiscoverImprovementMedianPct)),
    averagePairedScanMedianPct: average(rounds.map((round) => round.pairedCandidateScanImprovementMedianPct)),
    averagePairedScanWorkMedianPct: average(rounds.map((round) => round.pairedCandidateScanWorkImprovementMedianPct)),
    averagePairedTeddyMedianPct: average(rounds.map((round) => round.pairedCandidateTeddyRangeImprovementMedianPct)),
    routeParity: rounds.every((round) => round.routeParity === true),
    matchParity: rounds.every((round) => round.matchParity === true),
    fullScanCallsParity,
    fullScanBytesParity,
    fullScanMatchesParity,
    averageBaselineFullScanCalls: average(rounds.map((round) => round.baselineAlternateFullScanCallsMedian)),
    averageCandidateFullScanCalls: average(rounds.map((round) => round.candidateAlternateFullScanCallsMedian)),
    averageBaselineFullScanBytes: average(rounds.map((round) => round.baselineAlternateFullScanBytesMedian)),
    averageCandidateFullScanBytes: average(rounds.map((round) => round.candidateAlternateFullScanBytesMedian)),
    averageBaselineFullScanMatches: average(rounds.map((round) => round.baselineAlternateFullScanMatchesMedian)),
    averageCandidateFullScanMatches: average(rounds.map((round) => round.candidateAlternateFullScanMatchesMedian)),
  };
}

function researchBasis() {
  const simd = readJson(INSECT_SIMD_RESEARCH, []);
  const attribution = readJson(INSECT_ATTRIBUTION_RESEARCH, []);
  const literalAlternatesRefresh = readJson(INSECT_LITERAL_ALTERNATES_REFRESH, []);
  const teddyAttributionRefresh = readJson(INSECT_TEDDY_ATTRIBUTION_REFRESH, []);
  const packedTeddyShuftiRefresh = readJson(INSECT_PACKED_TEDDY_SHUFTI_REFRESH, []);
  const contract = readText(TEDDY_CONTRACT);
  return {
    files: [
      { path: path.relative(ROOT, TEDDY_CONTRACT), exists: existsSync(TEDDY_CONTRACT) },
      { path: path.relative(ROOT, INSECT_SIMD_RESEARCH), exists: existsSync(INSECT_SIMD_RESEARCH), results: Array.isArray(simd) ? simd.length : null },
      { path: path.relative(ROOT, INSECT_ATTRIBUTION_RESEARCH), exists: existsSync(INSECT_ATTRIBUTION_RESEARCH), results: Array.isArray(attribution) ? attribution.length : null },
      { path: path.relative(ROOT, INSECT_LITERAL_ALTERNATES_REFRESH), exists: existsSync(INSECT_LITERAL_ALTERNATES_REFRESH), results: Array.isArray(literalAlternatesRefresh) ? literalAlternatesRefresh.length : null },
      { path: path.relative(ROOT, INSECT_TEDDY_ATTRIBUTION_REFRESH), exists: existsSync(INSECT_TEDDY_ATTRIBUTION_REFRESH), results: Array.isArray(teddyAttributionRefresh) ? teddyAttributionRefresh.length : null },
      { path: path.relative(ROOT, INSECT_PACKED_TEDDY_SHUFTI_REFRESH), exists: existsSync(INSECT_PACKED_TEDDY_SHUFTI_REFRESH), results: Array.isArray(packedTeddyShuftiRefresh) ? packedTeddyShuftiRefresh.length : null },
    ],
    references: [
      ...((Array.isArray(simd) ? simd : []).slice(0, 5).map((entry) => ({
        title: entry.title ?? null,
        url: entry.url ?? null,
        source: "insect-simd-multipattern-prefilter",
      }))),
      ...((Array.isArray(attribution) ? attribution : []).slice(0, 5).map((entry) => ({
        title: entry.title ?? null,
        url: entry.url ?? null,
        source: "insect-performance-attribution",
      }))),
      ...((Array.isArray(literalAlternatesRefresh) ? literalAlternatesRefresh : []).slice(0, 5).map((entry) => ({
        title: entry.title ?? null,
        url: entry.url ?? null,
        source: "insect-literal-alternates-prefilter-refresh",
      }))),
      ...((Array.isArray(teddyAttributionRefresh) ? teddyAttributionRefresh : []).slice(0, 5).map((entry) => ({
        title: entry.title ?? null,
        url: entry.url ?? null,
        source: "insect-teddy-attribution-refresh",
      }))),
      ...((Array.isArray(packedTeddyShuftiRefresh) ? packedTeddyShuftiRefresh : []).slice(0, 5).map((entry) => ({
        title: entry.title ?? null,
        url: entry.url ?? null,
        source: "insect-packed-teddy-shufti-refresh",
      }))),
    ],
    contractSignals: {
      rejectsScalarTeddyLite: /rejected scalar Teddy-lite/i.test(contract),
      requiresPackedSimdExtractor: /packed SIMD candidate extractor/i.test(contract),
      requiresCorpusMeasuredSelector: /corpus-measured fingerprint/i.test(contract),
      requiresPromotionGate: /Promotion Gate/i.test(contract),
    },
  };
}

function evidenceQuality(historical) {
  const failures = Array.isArray(historical?.strictEvidenceFailures)
    ? historical.strictEvidenceFailures
    : historical?.evidenceQuality?.failures ?? [];
  return evidenceQualityFromFailures(failures);
}

function benchmarkNoiseFailures(quality) {
  return [
    ...(quality.hostFailures ?? []),
    ...(quality.identityFailures ?? []),
    ...(quality.processFailures ?? []),
    ...(quality.sampleFailures ?? []),
  ];
}

function blockedByBenchmarkNoise(quality) {
  return benchmarkNoiseFailures(quality).length > 0;
}

function benchmarkNoiseControlReason(quality) {
  const hostFailures = quality.hostFailures ?? [];
  const identityFailures = quality.identityFailures ?? [];
  const processFailures = quality.processFailures ?? [];
  const sampleFailures = quality.sampleFailures ?? [];
  const counts =
    `hostFailures=${hostFailures.length}, identityFailures=${identityFailures.length}, ` +
    `processFailures=${processFailures.length}, sampleFailures=${sampleFailures.length}`;
  if (identityFailures.length > 0 && hostFailures.length === 0 && processFailures.length === 0 && sampleFailures.length === 0) {
    return `Latest report is not suitable for a runtime code decision: ${counts}. Preserve the current runtime slice, rerun same-binary identity controls under a quieter benchmark envelope, and only act on sub-percent scanWork deltas after identity drift and paired-lane skew clear.`;
  }
  if (hostFailures.length > 0) {
    return `Latest report is not suitable for a runtime code decision: ${counts}. Preserve the current runtime slice, clear the benchmark host preflight issues, and only then act on sub-percent scanWork deltas.`;
  }
  if (processFailures.length > 0) {
    return `Latest report is not suitable for a runtime code decision: ${counts}. Preserve the current runtime slice, clean IX process state, and rerun before using speed attribution.`;
  }
  if (sampleFailures.length > 0) {
    return `Latest report is not suitable for a runtime code decision: ${counts}. Preserve the current runtime slice and rerun with enough retained samples before using speed attribution.`;
  }
  return `Latest report is not suitable for a runtime code decision: ${counts}. Preserve the current runtime slice, rerun the benchmark control gate, and only then act on sub-percent scanWork deltas.`;
}

function diagnosticAttributionOnly(quality) {
  return (quality?.comparisonFailures ?? []).includes("diagnostic_attribution_run_not_retainable_evidence");
}

function candidateMoves(summary, leakSummary, quality) {
  const benchmarkNoiseBlocked = blockedByBenchmarkNoise(quality);
  const diagnosticOnly = diagnosticAttributionOnly(quality);
  const teddyPressure = Number(summary.averagePairedTeddyMedianPct ?? 0);
  const enginePressure = Number(summary.averagePairedEngineMedianPct ?? 0);
  const scanPressure = Number(summary.averagePairedScanMedianPct ?? 0);
  const scanWorkPressure = Number(summary.averagePairedScanWorkMedianPct ?? 0);
  const negativePressure = Math.max(0, -Math.min(teddyPressure, scanPressure, scanWorkPressure));
  const teddyGainNeedsLeakRepair =
    leakSummary?.diagnosis === "preserve_positive_teddy_gain_and_repair_whole_engine_leak" &&
    summary.matchParity === true &&
    summary.routeParity === true;
  const scanOpenDominatesLeak =
    teddyGainNeedsLeakRepair &&
    leakSummary?.nextRepairTarget === "scanWork" &&
    leakSummary?.leakAttribution?.currentOnlyScanSplit?.dominantCandidateSubphase === "scanOpen" &&
    leakSummary?.leakAttribution?.currentOnlyScanSplit?.regressingCandidateSubphase !== "scanFile";
  const scanFileResidualRegresses =
    teddyGainNeedsLeakRepair &&
    leakSummary?.nextRepairTarget === "scanWork" &&
    leakSummary?.leakAttribution?.currentOnlyScanSplit?.regressingCandidateSubphase === "scanFile";
  const filesScannedParityStatus = (() => {
    const value = leakSummary?.leakAttribution?.currentOnlyScanSplit?.filesScannedParity;
    if (value === true) return "proved";
    if (value === false) return "mismatch";
    return "missing";
  })();
  const fullScanVolumeStable =
    summary.fullScanCallsParity === true &&
    summary.fullScanBytesParity === true &&
    summary.fullScanMatchesParity === true;
  const teddyReason = fullScanVolumeStable
    ? "Current route, match, and alternates full-scan volumes are stable across older-build rounds; the next retainable move must reduce alternate_teddy_range_elapsed_ns or scan work, not merely reroute or hoist parser work."
    : "Alternates full-scan volume changed across historical rounds; attribution must explain route volume before a runtime search change is promotable.";
  const moves = [
    {
      id: "benchmark_host_noise_control",
      status: benchmarkNoiseBlocked ? "allowed_next" : "satisfied",
      owner: "tools/scripts/compare-historical-speed.mjs host preflight plus same-binary identity control",
      reason: benchmarkNoiseBlocked
        ? benchmarkNoiseControlReason(quality)
        : "Latest historical evidence has no host, identity-control, process, or sample-size noise blocker.",
      expectedGainScore: benchmarkNoiseBlocked ? 10 + benchmarkNoiseFailures(quality).length : 0,
      proofCommand: SPEED_DIAGNOSTIC_COMMAND,
    },
    {
      id: "whole_engine_leak_attribution",
      status: benchmarkNoiseBlocked
        ? "blocked_by_benchmark_noise"
        : (scanOpenDominatesLeak ? "satisfied_by_scan_open_split" : (teddyGainNeedsLeakRepair ? "allowed_next" : "waiting_for_teddy_route_win")),
      owner: "tools/scripts/compare-historical-speed.mjs plus src/core/search.zig phase telemetry",
      reason: teddyGainNeedsLeakRepair
        ? `Latest historical evidence shows Teddy attribution is positive while whole-engine evidence still has a losing round; preserve the Teddy gain and isolate ${leakSummary?.nextRepairTarget ?? "discovery, scheduling, scan bookkeeping, or reporting"} overhead before changing the Teddy kernel again. Current averaged phase medians: discover=${summary.averagePairedDiscoverMedianPct}%, scan=${summary.averagePairedScanMedianPct}%, scanWork=${summary.averagePairedScanWorkMedianPct}%, teddy=${summary.averagePairedTeddyMedianPct}%. Worst round=${leakSummary?.worstRound?.baselineLabel ?? "unknown"}.`
        : "Use this only after Teddy route attribution is already net-positive and whole-engine evidence still regresses.",
      expectedGainScore: teddyGainNeedsLeakRepair ? 3 + Math.max(0, -enginePressure) + Math.max(0, teddyPressure / 4) : 0,
      proofCommand: SPEED_LEAK_ATTRIBUTION_COMMAND,
    },
    {
      id: "scan_open_path_pressure_attribution",
      status: benchmarkNoiseBlocked
        ? "blocked_by_benchmark_noise"
        : (diagnosticOnly && scanOpenDominatesLeak
            ? "diagnostic_only"
            : (scanOpenDominatesLeak ? "allowed_next" : (scanFileResidualRegresses ? "blocked_by_scan_file_regression" : "waiting_for_scan_open_split"))),
      owner: "src/core/search.zig::scanFileIntoShardTimed and scanFileIntoShardMonoTimed",
      reason: scanOpenDominatesLeak
        ? `Scan-open timing split is now present and identifies the file-open wrapper as the dominant candidate subphase under file-count parity=${filesScannedParityStatus}: scanOpen median=${leakSummary.leakAttribution.currentOnlyScanSplit.candidateScanOpenMedianMs?.median}ms, scanOpen per file=${leakSummary.leakAttribution.currentOnlyScanSplit.candidateScanOpenMsPerFileMedian?.median}ms, scanFile median=${leakSummary.leakAttribution.currentOnlyScanSplit.candidateScanFileMedianMs?.median}ms. ${diagnosticOnly ? "This report is diagnostic-only, so it may guide the next proof run but must not directly authorize a runtime patch." : "The next runtime candidate must reduce open-path pressure per file, not chase scanned-file count, before touching the Teddy kernel."}`
        : (scanFileResidualRegresses
            ? `Scan-open owns the largest current scan-work share, but scanFile is the measured regressing subphase: scanFile paired=${leakSummary.leakAttribution.currentOnlyScanSplit.regressingCandidateSubphaseMedianPct}%, scanFile delta=${leakSummary.leakAttribution.currentOnlyScanSplit.regressingCandidateSubphaseDeltaMs}ms. Do not chase open-path pressure until scan-file residual/hotspots are repaired or disproven.`
            : "Run historical proof with --scan-open-timing before choosing an open-path, scan-file, or Teddy-kernel repair."),
      expectedGainScore: scanOpenDominatesLeak ? 4 + Math.max(0, -enginePressure) : 0,
      proofCommand: SPEED_SCAN_OPEN_PROMOTION_COMMAND,
    },
    {
      id: "retainable_scan_open_runtime_probe",
      status: benchmarkNoiseBlocked
        ? "blocked_by_benchmark_noise"
        : (diagnosticOnly && scanOpenDominatesLeak ? "allowed_next" : "waiting_for_diagnostic_scan_open_split"),
      owner: "tools/scripts/compare-historical-speed.mjs retainable predecessor gate",
      reason: diagnosticOnly && scanOpenDominatesLeak
        ? "A scan-open-timing run found open-path pressure, but diagnostic attribution is deliberately non-retainable evidence. Before touching scanFileIntoShardTimed, prove the current binary under the normal strict predecessor gate so runtime work is selected from production-shaped timing, not instrumentation-shaped timing."
        : "Use only after a diagnostic scan-open split identifies open-path pressure from a report that cannot itself authorize runtime changes.",
      expectedGainScore: diagnosticOnly && scanOpenDominatesLeak ? 5 + Math.max(0, -enginePressure) : 0,
      proofCommand: SPEED_PROMOTION_COMMAND,
    },
    {
      id: "scan_file_residual_hotspot_attribution",
      status: benchmarkNoiseBlocked ? "blocked_by_benchmark_noise" : (scanFileResidualRegresses ? "allowed_next" : "waiting_for_scan_file_regression"),
      owner: "src/core/search.zig::scanOpenFileIntoShardImpl and large-file range counters",
      reason: scanFileResidualRegresses
        ? `Fresh historical proof shows scanFile is the negative scan subphase while file-count parity holds. Candidate scan-file residual median=${leakSummary.leakAttribution.currentOnlyScanSplit.candidateScanFileResidualMedianMs?.median}ms, residual share=${leakSummary.leakAttribution.currentOnlyScanSplit.candidateScanFileResidualSharePct?.median}%, slow class=${leakSummary.leakAttribution.currentOnlyScanSplit.candidateSlowestPathClasses?.[0]?.value ?? "unknown"}. The next runtime candidate must reduce large-file scan residual work without changing route or match volume.`
        : "Use only when scanWork leaks and scanFile, not scanOpen, is the measured regressing subphase.",
      expectedGainScore: scanFileResidualRegresses ? 4 + Math.max(0, -enginePressure) + Math.max(0, -Number(leakSummary.leakAttribution.currentOnlyScanSplit.regressingCandidateSubphaseMedianPct ?? 0)) / 2 : 0,
      proofCommand: SPEED_SCAN_OPEN_PROMOTION_COMMAND,
    },
    {
      id: "packed_nibble_shuffle_teddy_kernel",
      status: benchmarkNoiseBlocked ? "blocked_by_benchmark_noise" : (teddyGainNeedsLeakRepair ? "allowed_after_whole_engine_leak_attribution" : "allowed_next"),
      owner: "src/core/literal_alternates.zig::nextTeddyCandidate with an optional narrow src/core/simd.zig primitive",
      reason: `${teddyReason} Current Teddy path still compares each branch vector independently; research and contract require a packed SIMD/Shufti-style candidate extractor. Do not repeat prior rejected shapes: cached vectors in TeddyPlan, per-call hoisted splats, range-level C FFI packed helper, inline Zig VPSHUFB nibble tables, branch-count unrolling, single-load shifted equality masks, fingerprint-byte confirmation skips, or scan-open pairing without reducing confirmation/line-loop work.`,
      expectedGainScore: teddyGainNeedsLeakRepair ? 1 : 2.5 + negativePressure,
      blockedImplementationShapes: [
        "cached_fingerprint_vectors_in_teddy_plan",
        "per_call_hoisted_splat_vectors",
        "range_level_c_ffi_packed_teddy_helper",
        "inline_zig_vpshufb_nibble_tables",
        "branch4_unrolled_equality_kernel",
        "branch_mask_candidate_verification",
        "fingerprint_verified_byte_confirmation_skip",
        "single_load_shifted_equality_mask",
        "single_load_shifted_mask_plus_large_first_read",
      ],
      proofCommand: SPEED_PROMOTION_COMMAND,
    },
    {
      id: "corpus_measured_fingerprint_selector_inside_packed_kernel",
      status: "allowed_after_packed_kernel_shape",
      owner: "src/core/search.zig::teddyLiteralAlternatesPlan",
      reason: "Existing corpus evidence shows prefix fingerprints are high-candidate for branch-4, but offset-only heuristics regressed without a real packed kernel.",
      expectedGainScore: 1.5 + Math.max(0, -teddyPressure),
      proofCommand: "node tools/scripts/alternates-decision-table.mjs --branch-counts 4 --samples 12 --identity-control-attempts 3 --threads 32 --fingerprint-corpus --quiet",
    },
    {
      id: "scalar_start_byte_or_line_admission",
      status: "rejected",
      owner: "src/core/search.zig::LiteralAlternatesCounter.countMatches",
      reason: "A StringZilla byte-set line admission before Teddy preserved tests but failed the four-backup historical gate with 0/4 net-positive rounds.",
      expectedGainScore: 0,
      proofCommand: "historical-speed-2026-06-13T08-12-14-696Z.json",
    },
    {
      id: "folded_trigram_admission_for_casefold_alternates",
      status: "rejected",
      owner: "src/core/trigram.zig + src/core/search_admission.zig + src/core/search.zig::shouldAttemptTrigramPrune",
      reason: "Case-insensitive folded trigram admission preserved correctness and pruned mid-size files, but failed historical predecessor proof with 0/4 net-positive rounds, route mismatches, and added scalar file scans without reducing the byte-sharded hot path enough.",
      expectedGainScore: 0,
      proofCommand: "historical-speed-2026-06-29T21-56-18-971Z.json",
    },
    {
      id: "parallel_first_read_positional_transplant",
      status: "rejected",
      owner: "src/core/search.zig::scanOpenFileIntoShardImpl",
      reason: "The serial first-read pattern regressed scan-work medians when transplanted into the parallel shard path.",
      expectedGainScore: 0,
      proofCommand: "historical-speed-2026-06-13T08-04-03-346Z.json",
    },
    {
      id: "full_scan_route_selection_or_parser_hoist",
      status: "rejected_unless_volume_changes",
      owner: "src/core/search.zig::countLiteralAlternatesLogicalLinesRange and LiteralAlternates.parse",
      reason: "Latest installed and historical reports show identical alternates full-scan calls, bytes, and matches while the previous parser-hoist shape failed older-build proof; route-selection work is not the current speed lever without new attribution.",
      expectedGainScore: fullScanVolumeStable ? 0 : 0.75,
      proofCommand: "compare-historical-speed reports with alternate_full_scan_* medians",
    },
    {
      id: "per_shard_literal_alternates_counter_hoist",
      status: "rejected",
      owner: "src/core/search.zig::ShardReport and wholeBufferFastCount",
      reason: "Reusing one LiteralAlternatesCounter per worker removed per-file parser churn in the single-chunk full-buffer path, but repeat focused branch-4 proof regressed paired whole-engine median by -2.407% and left Teddy-route attribution negative.",
      expectedGainScore: 0,
      proofCommand: "alternates-decision-2026-06-13T11-04-17-726Z.json",
    },
    {
      id: "casefold_or_alpha_fastpath",
      status: "rejected",
      owner: "src/core/search.zig::nextTeddyLiteralAlternatesCandidate",
      reason: "Replacing ASCII range-select lowercasing with unconditional OR 0x20 for all-letter fingerprints passed tests and focused branch-4 installed proof, but widened 2-8 installed proof regressed branches 2, 3, 7, and 8.",
      expectedGainScore: 0,
      proofCommand: "alternates-decision-2026-06-13T09-41-00-665Z.json",
    },
    {
      id: "teddy_plan_pointer_pass",
      status: "rejected",
      owner: "src/core/search.zig::countTeddyLiteralAlternatesPrefix3 and nextTeddyLiteralAlternatesCandidate",
      reason: "Passing the Teddy plan by pointer improved route-local Teddy attribution but did not clear the focused whole-engine scorecard; engine paired median was only +0.228% and identity noise exceeded the strict gate.",
      expectedGainScore: 0,
      proofCommand: "alternates-decision-2026-06-13T09-56-05-637Z.json",
    },
    {
      id: "branch_mask_candidate_verification",
      status: "rejected",
      owner: "src/core/literal_alternates.zig::nextTeddyCandidate and countTeddyPrefix3",
      reason: "Returning the matched branch mask from Teddy candidate extraction reduced installed Teddy-range time, but the added candidate bookkeeping failed the recent predecessor ladder with 0/4 net-positive rounds and Teddy regressions against the newest two backups.",
      expectedGainScore: 0,
      proofCommand: "historical-speed-2026-07-01T01-52-11-644Z.json",
    },
    {
      id: "offset3_fingerprint_selector_without_packed_kernel",
      status: "rejected",
      owner: "src/core/literal_alternates.zig::teddyRangeFingerprintOffsetOverride",
      reason: "A no-code installed-vs-current probe with IX_TEDDY_RANGE_FINGERPRINT_OFFSET=3 preserved route and match parity but failed promotion: repo median 603.5326 ms was slower than installed 599.1414 ms, paired median was -6.8536%, and win rate was 0.4167. Moving the fingerprint window without a lower-cost packed verifier is not a promotable speed move.",
      expectedGainScore: 0,
      proofCommand: "installed-speed-2026-07-01T07-11-15-156Z.json",
    },
    {
      id: "fingerprint_verified_byte_confirmation_skip",
      status: "rejected",
      owner: "src/core/literal_alternates.zig::countTeddyPrefix3 and firstMatchingBranchLen",
      reason: "Skipping the already-proven three fingerprint bytes during post-candidate confirmation preserved Zig tests and ReleaseFast build, but failed installed-vs-current promotion: repo median 630.4795 ms was slower than installed 594.4936 ms, paired median was -6.0879%, and win rate was 0.3333. A promotable confirmation change must reduce the candidate loop itself or carry bucket identity, not add a new confirmation helper around the current candidate stream.",
      expectedGainScore: 0,
      proofCommand: "installed-speed-2026-07-01T07-14-48-344Z.json",
    },
    {
      id: "branch4_unrolled_equality_kernel",
      status: "rejected",
      owner: "src/core/literal_alternates.zig::nextTeddyCandidate",
      reason: "Special-casing branch_count == 4 by unrolling the existing equality-vector branch loop preserved correctness and ReleaseFast build, but failed installed-vs-repo promotion: repo median 591.4168 ms was slower than installed 586.3894 ms, paired median was -0.0240%, and win rate stayed 0.5. The retained path must remove candidate or confirmation work, not only unroll the current comparisons.",
      expectedGainScore: 0,
      proofCommand: "installed-speed-2026-07-01T02-39-20-182Z.json",
    },
    {
      id: "single_load_shifted_equality_mask",
      status: "rejected",
      owner: "src/core/literal_alternates.zig::nextTeddyCandidate",
      reason: "Loading one 32-byte vector and shifting equality masks for the three fingerprint bytes improved Teddy route time by +4.3781%, but failed installed promotion: engine -0.5138%, paired median -2.5321%, scanWork -2.2167%, and win rate 0.5. The next packed extractor must reduce confirmation or line-loop cost, not only replace adjacent loads with shifted equality masks.",
      expectedGainScore: 0,
      proofCommand: "installed-speed-2026-07-01T06-37-23-640Z.json",
    },
    {
      id: "single_load_shifted_mask_plus_large_first_read",
      status: "rejected",
      owner: "src/core/literal_alternates.zig::nextTeddyCandidate plus src/core/search.zig::scanOpenFileIntoShardImpl",
      reason: "Pairing the shifted-mask Teddy extractor with a one-shot 1 MiB first read made raw engine median barely positive (+0.0270%) and Teddy positive (+1.6132%), but still failed installed promotion on paired median -2.5053% and win rate 0.5. The scan-open read shape cannot rescue this Teddy extractor under the no-regression gate.",
      expectedGainScore: 0,
      proofCommand: "installed-speed-2026-07-01T06-40-13-841Z.json",
    },
    {
      id: "cached_fingerprint_vectors_in_teddy_plan",
      status: "rejected",
      owner: "src/core/literal_alternates.zig::TeddyPlan and nextTeddyCandidate",
      reason: "Storing splatted fingerprint vectors in TeddyPlan improved route-local attribution in some installed runs, but failed promotion or predecessor proof. It adds plan footprint and moves setup cost without replacing the independent branch-comparison kernel.",
      expectedGainScore: 0,
      proofCommand: ".docs/todo/changelog/152m-packed-teddy-bucket-mask-repair.md",
    },
    {
      id: "per_call_hoisted_splat_vectors",
      status: "rejected",
      owner: "src/core/literal_alternates.zig::nextTeddyCandidate",
      reason: "Hoisting branch splats inside nextTeddyCandidate passed installed promotion once, but historical strict proof rejected it: newest backup engine -3.9367%, paired -7.7632%, Teddy -18.1697%; second backup engine -0.5427%, paired -1.1666%, Teddy -13.9036%.",
      expectedGainScore: 0,
      proofCommand: ".docs/todo/changelog/152m-packed-teddy-bucket-mask-repair.md",
    },
    {
      id: "range_level_c_ffi_packed_teddy_helper",
      status: "rejected",
      owner: "src/core/literal_alternates.zig::countLogicalLinesRange and C SIMD helper boundary",
      reason: "The packed Teddy contract records the range-level C FFI helper as rejected: crossing the Zig/C boundary at range granularity did not clear the older-build proof gate. A retainable packed kernel must either be a lower-overhead primitive or reduce surrounding line-loop/confirmation work enough to pay for the SIMD extractor.",
      expectedGainScore: 0,
      proofCommand: ".docs/research/2026-06-13-packed-teddy-kernel-proof-contract.md",
    },
    {
      id: "inline_zig_vpshufb_nibble_tables",
      status: "rejected",
      owner: "src/core/literal_alternates.zig::nextTeddyCandidate",
      reason: "The packed Teddy contract records inline Zig VPSHUFB nibble tables as rejected: direct shuffle-table substitution was too instruction-heavy for the current 2-8 branch envelope. The next candidate must reduce adjacent loads, confirmation, or range work instead of replaying the same shuffle shape.",
      expectedGainScore: 0,
      proofCommand: ".docs/research/2026-06-13-packed-teddy-kernel-proof-contract.md",
    },
  ];
  return moves.sort((left, right) => Number(right.expectedGainScore) - Number(left.expectedGainScore));
}

function mixedTeddyGainNeedsLeakRepair(summary, leakSummary) {
  return (
    leakSummary?.diagnosis === "preserve_positive_teddy_gain_and_repair_whole_engine_leak" &&
    summary?.matchParity === true &&
    summary?.routeParity === true
  );
}

function nextEngineeringMove(moves, summary, leakSummary) {
  const scanFileResidual = moves.find((move) => move.id === "scan_file_residual_hotspot_attribution") ?? null;
  const scanOpenPressure = moves.find((move) => move.id === "scan_open_path_pressure_attribution") ?? null;
  const retainableScanOpenProbe = moves.find((move) => move.id === "retainable_scan_open_runtime_probe") ?? null;
  const wholeEngineLeak = moves.find((move) => move.id === "whole_engine_leak_attribution") ?? null;
  if (retainableScanOpenProbe?.status === "allowed_next") return retainableScanOpenProbe;
  if (scanFileResidual?.status === "allowed_next") return scanFileResidual;
  if (scanOpenPressure?.status === "allowed_next") return scanOpenPressure;
  if (mixedTeddyGainNeedsLeakRepair(summary, leakSummary)) return wholeEngineLeak;
  return moves.find((move) => move.id === "packed_nibble_shuffle_teddy_kernel") ?? wholeEngineLeak ?? null;
}

function preservationPolicy(summary, leakSummary, quality, engineeringMove) {
  const preserveTeddyGain = mixedTeddyGainNeedsLeakRepair(summary, leakSummary);
  const benchmarkNoiseBlocked = blockedByBenchmarkNoise(quality);
  return {
    preserveTeddyGain,
    protectedPhase: preserveTeddyGain ? "teddyRange" : null,
    repairPhase: preserveTeddyGain ? leakSummary?.nextRepairTarget ?? "wholeEngine" : null,
    promotionBlocked: true,
    promotionBlocker: benchmarkNoiseBlocked
      ? "benchmark_host_or_identity_noise"
      : "whole_engine_not_net_positive",
    rule: preserveTeddyGain
      ? "do_not_revert_teddy_gain; isolate and repair the smaller whole-engine loss"
      : "advance only changes that improve the whole engine without route-local regression",
    nextEngineeringMoveId: engineeringMove?.id ?? null,
  };
}

function diagnosticAttributionReport(filePath, currentHash) {
  if (filePath == null || !existsSync(filePath)) return null;
  const diagnostic = readJson(filePath, {});
  const diagnosticRounds = Array.isArray(diagnostic.roundLedger) ? diagnostic.roundLedger : [];
  const diagnosticLeakSummary = phaseLeakSummaryFromRounds(diagnosticRounds);
  return {
    inputReport: path.relative(ROOT, filePath),
    evaluatedHistoricalRunId: diagnostic.runId ?? null,
    timestamp: diagnostic.timestamp ?? null,
    freshForCurrentBinary: reportMatchesCurrentBinary(diagnostic, currentHash),
    diagnosticAttributionMode: diagnostic.diagnosticAttributionMode === true,
    retainableStrictEvidence: diagnostic.retainableStrictEvidence === true,
    usableForRuntimeMove: false,
    reason: "diagnostic attribution is owner-selection evidence only; it cannot authorize runtime promotion or finalization",
    scorecard: diagnostic.scorecard ?? null,
    evidenceQuality: evidenceQuality(diagnostic),
    leakSummary: diagnosticLeakSummary,
    nextRepairTarget: diagnosticLeakSummary?.nextRepairTarget ?? null,
    nextProbe: diagnosticLeakSummary?.leakAttribution?.nextProbe ?? null,
  };
}

function roundSpeedEvidence(round, candidateSha256 = null) {
  return {
    roundIndex: round.roundIndex ?? null,
    baselineLabel: round.baselineLabel ?? null,
    candidateLabel: round.candidateLabel ?? null,
    status: round.status ?? null,
    testedOneAtATime: round.testedOneAtATime === true,
    netPositive: round.netPositive === true,
    requiredImprovementPct: Number.isFinite(Number(round.requiredImprovementPct)) ? Number(round.requiredImprovementPct) : null,
    baselineEngineMedianMs: Number.isFinite(Number(round.baselineEngineMedianMs)) ? Number(round.baselineEngineMedianMs) : null,
    candidateEngineMedianMs: Number.isFinite(Number(round.candidateEngineMedianMs)) ? Number(round.candidateEngineMedianMs) : null,
    engineImprovementPct: Number.isFinite(Number(round.engineImprovementPct)) ? Number(round.engineImprovementPct) : null,
    pairedCandidateImprovementMedianPct: Number.isFinite(Number(round.pairedCandidateImprovementMedianPct)) ? Number(round.pairedCandidateImprovementMedianPct) : null,
    pairedCandidateScanWorkImprovementMedianPct: Number.isFinite(Number(round.pairedCandidateScanWorkImprovementMedianPct)) ? Number(round.pairedCandidateScanWorkImprovementMedianPct) : null,
    pairedCandidateTeddyRangeImprovementMedianPct: Number.isFinite(Number(round.pairedCandidateTeddyRangeImprovementMedianPct)) ? Number(round.pairedCandidateTeddyRangeImprovementMedianPct) : null,
    pairedCandidateWinRate: Number.isFinite(Number(round.pairedCandidateWinRate)) ? Number(round.pairedCandidateWinRate) : null,
    routeParity: round.routeParity === true,
    matchParity: round.matchParity === true,
    baselineSha256: round.baselineSha256 ?? null,
    candidateSha256: round.candidateSha256 ?? candidateSha256,
  };
}

function installedRoundEvidence(filePath) {
  const report = readJson(filePath, null);
  if (report == null) return null;
  const rounds = Array.isArray(report.roundLedger) ? report.roundLedger : [];
  return {
    source: path.relative(ROOT, filePath),
    runId: report.runId ?? null,
    promotionQualified: report.promotionQualified === true,
    retainableStrictEvidence: report.retainableStrictEvidence === true,
    failures: Array.isArray(report.promotionFailures) ? report.promotionFailures : [],
    rounds: rounds.map(roundSpeedEvidence),
  };
}

function historicalRoundEvidence(report) {
  const rounds = Array.isArray(report?.roundLedger) ? report.roundLedger : [];
  const currentHashes = historicalComparisonHashes(report);
  const currentHash = currentHashes.length === 1 ? currentHashes[0] : null;
  return {
    runId: report?.runId ?? null,
    retainableStrictEvidence: report?.retainableStrictEvidence === true,
    testedOneAtATime: report?.scorecard?.testedOneAtATime === true,
    totalRounds: Number(report?.scorecard?.totalRounds ?? rounds.length),
    netPositiveRounds: Number(report?.scorecard?.netPositiveRounds ?? rounds.filter((round) => round.netPositive === true).length),
    regressionRoundCount: Number(report?.scorecard?.regressionRoundCount ?? rounds.filter((round) => round.netPositive !== true).length),
    rounds: rounds.map((round) => roundSpeedEvidence(round, currentHash)),
  };
}

function olderSnapshotRoundEvidence(filePath) {
  const report = readJson(filePath, null);
  if (report == null) return null;
  const rounds = Array.isArray(report.rounds) ? report.rounds : [];
  return {
    source: path.relative(ROOT, filePath),
    runId: report.runId ?? null,
    retainableEvidence: report.retainableEvidence === true,
    runnableSnapshots: Number(report.runnableSnapshots ?? rounds.filter((round) => round.runnable === true).length),
    retainableSnapshots: Number(report.retainableSnapshots ?? rounds.filter((round) => round.status === "net_positive").length),
    skippedSnapshots: Number(report.skippedSnapshots ?? rounds.filter((round) => round.status === "skipped" || round.runnable === false).length),
    failures: Array.isArray(report.failures) ? report.failures : [],
    rounds: rounds.map((round, index) => ({
      roundIndex: index + 1,
      snapshotLabel: round.label ?? round.snapshotLabel ?? round.baselineLabel ?? null,
      status: round.status ?? null,
      runnable: round.runnable === true,
      retainable: round.status === "net_positive",
      baselineEngineMedianMs: Number.isFinite(Number(round.baselineMedianMs)) ? Number(round.baselineMedianMs) : null,
      candidateEngineMedianMs: Number.isFinite(Number(round.repoMedianMs)) ? Number(round.repoMedianMs) : null,
      engineImprovementPct: Number.isFinite(Number(round.enginePct)) ? Number(round.enginePct) : null,
      pairedCandidateImprovementMedianPct: Number.isFinite(Number(round.pairedPct)) ? Number(round.pairedPct) : null,
      pairedCandidateWinRate: Number.isFinite(Number(round.winRate)) ? Number(round.winRate) : null,
      routeParityStatus: round.routeParityStatus ?? null,
      matchParity: round.matchParity === true,
      baselineSha256: round.baseline?.sha256 ?? round.baselineSha256 ?? null,
      candidateSha256: round.current?.sha256 ?? round.candidateSha256 ?? null,
    })),
  };
}

function currentSpeedStatus({ summary, historical, installedStatus, installedEvidencePath, historicalDiagnosticStatus, historicalRetainableStatus, olderStatus }) {
  const losingRounds = Array.isArray(historical?.scorecard?.losingRounds)
    ? historical.scorecard.losingRounds
    : [];
  const underTargetRounds = Array.isArray(historical?.scorecard?.underTargetRounds)
    ? historical.scorecard.underTargetRounds
    : [];
  return {
    installed: {
      status: installedStatus.status,
      runId: installedStatus.runId,
      promotionQualified: installedStatus.promotionQualified,
      retainableStrictEvidence: installedStatus.retainableStrictEvidence,
    },
    recentPredecessors: {
      status: historicalDiagnosticStatus.status,
      runId: historicalDiagnosticStatus.runId,
      retainableStrictEvidence: historicalDiagnosticStatus.retainableStrictEvidence,
      requiredRetainableStatus: historicalRetainableStatus.status,
      requiredRetainableRunId: historicalRetainableStatus.runId,
      netPositiveRounds: Number(historical?.scorecard?.netPositiveRounds ?? summary.netPositiveRounds ?? 0),
      totalRounds: Number(historical?.scorecard?.totalRounds ?? summary.count ?? 0),
      regressionRoundCount: Number(historical?.scorecard?.regressionRoundCount ?? losingRounds.length),
      underTargetRoundCount: Number(historical?.scorecard?.underTargetRoundCount ?? underTargetRounds.length),
      worstEngineImprovementPct: summary.worstEngineImprovementPct,
      averagePairedEngineMedianPct: summary.averagePairedEngineMedianPct,
      averagePairedScanWorkMedianPct: summary.averagePairedScanWorkMedianPct,
      averagePairedTeddyMedianPct: summary.averagePairedTeddyMedianPct,
    },
    olderSnapshots: {
      status: olderStatus.status,
      runId: olderStatus.runId,
      retainableEvidence: olderStatus.retainableEvidence,
      retainableSnapshots: olderStatus.retainableSnapshots,
      runnableSnapshots: olderStatus.runnableSnapshots,
      skippedSnapshots: olderStatus.skippedSnapshots,
    },
    actualSearchSpeedEvidence: {
      installedVsCurrent: installedRoundEvidence(installedEvidencePath) ?? installedRoundEvidence(LATEST_RETAINABLE_INSTALLED_PATH) ?? installedRoundEvidence(LATEST_INSTALLED_PATH),
      recentPredecessorsVsCurrent: historicalRoundEvidence(historical),
      olderSnapshotsVsCurrent: olderSnapshotRoundEvidence(LATEST_OLDER_SNAPSHOT_PATH),
    },
    finalizationAllowed:
      installedStatus.status === "promotable_current" &&
      historicalRetainableStatus.status === "retainable_current" &&
      olderStatus.status === "retainable_current",
  };
}

function requiredKernelProof(engineeringMove) {
  if (engineeringMove?.id !== "packed_nibble_shuffle_teddy_kernel") return null;
  return {
    owner: "src/core/literal_alternates.zig::TeddyPlan and nextTeddyCandidate",
    requiredMechanism: "packed_bucket_carrying_candidate_masks",
    reason: "The last retained-lane experiments showed route-local Teddy gains are not enough. A promotable kernel must carry bucket identity through candidate extraction so confirmation narrows before firstMatchingBranchLen-style broad verification, or must otherwise prove reduced confirmation/line-loop work.",
    mustProve: [
      "candidate extraction produces bucket-bearing masks or an equivalent narrowed verification token",
      "confirmation checks only branches in the surviving bucket or proves an equivalent lower-cost verifier",
      "route, match, full-scan calls, full-scan bytes, and full-scan matches remain unchanged",
      "installed-vs-current promotion passes with paired median and win-rate non-negative",
      "recent predecessor ladder passes one build at a time",
      "older snapshot ladder remains retainable",
    ],
    rejectedShortcuts: [
      "single_load_shifted_equality_mask",
      "single_load_shifted_mask_plus_large_first_read",
      "branch4_unrolled_equality_kernel",
      "branch_mask_candidate_verification",
      "fingerprint_verified_byte_confirmation_skip",
      "inline_zig_vpshufb_nibble_tables",
      "range_level_c_ffi_packed_teddy_helper",
      "offset_only_fingerprint_selector",
      "offset3_fingerprint_selector_without_packed_kernel",
      "scalar_post_candidate_secondary_filter",
    ],
    sourceReferences: [
      ".refs/aho-corasick/src/packed/teddy/generic.rs::Mask::members3",
      ".refs/aho-corasick/src/packed/teddy/generic.rs::Teddy::verify64",
      ".refs/aho-corasick/src/packed/teddy/generic.rs::SlimMaskBuilder::from_teddy",
      ".refs/aho-corasick/src/packed/teddy/README.md",
      ".docs/research/insect-teddy-single-load-shifted-masks-20260701.json",
    ],
  };
}

function nextEvidenceMove(latestDiagnosticAttribution, speedProofPointers) {
  if (
    latestDiagnosticAttribution?.freshForCurrentBinary !== true ||
    latestDiagnosticAttribution?.diagnosticAttributionMode !== true ||
    latestDiagnosticAttribution?.usableForRuntimeMove !== false
  ) {
    return null;
  }

  const retainableInstalled = speedProofPointers?.latestInstalled ?? null;
  const diagnosticInstalled = speedProofPointers?.latestInstalledDiagnostic ?? null;
  const installed = retainableInstalled?.freshForCurrentBinary === true ? retainableInstalled : diagnosticInstalled;
  if (installed?.status === "stale_current_binary") {
    return {
      id: "retainable_runtime_probe",
      status: "blocked_by_stale_installed_promotion_evidence",
      owner: "tools/scripts/compare-installed-speed.mjs",
      reason: "Fresh diagnostic attribution exists, but the installed-vs-current promotion evidence points at a stale repo binary. Rerun the strict installed promotion gate for the current binary before selecting any runtime repair.",
      sourceDiagnosticRunId: latestDiagnosticAttribution.evaluatedHistoricalRunId ?? null,
      installedRunId: installed.runId ?? null,
      installedStatus: installed.status,
      proofCommand: INSTALLED_SPEED_STRICT_COMMAND,
    };
  }
  if (installed?.status === "promotion_failed") {
    return {
      id: "retainable_runtime_probe",
      status: "blocked_by_installed_promotion_failure",
      owner: "tools/scripts/compare-installed-speed.mjs",
      reason: `Fresh diagnostic attribution found ${latestDiagnosticAttribution.nextRepairTarget ?? "runtime"} pressure, but the strict installed-vs-current promotion gate already failed for the current binary. Do not rerun the same evidence step or choose a runtime repair from diagnostic-only data; change the runtime candidate or benchmark owner first, then rerun installed promotion.`,
      sourceDiagnosticRunId: latestDiagnosticAttribution.evaluatedHistoricalRunId ?? null,
      installedRunId: installed.runId ?? null,
      installedStatus: installed.status,
      proofCommand: INSTALLED_SPEED_STRICT_COMMAND,
    };
  }

  const target = latestDiagnosticAttribution.nextRepairTarget ?? null;
  if (target === "scanOpen") {
    return {
      id: "retainable_scan_open_runtime_probe",
      status: "allowed_next_evidence",
      owner: "tools/scripts/compare-historical-speed.mjs retainable predecessor gate",
      reason: "Fresh diagnostic attribution found scanOpen pressure, but diagnostic attribution is non-promotional. Run the normal strict installed, predecessor, and older-snapshot gates before selecting any scanOpen runtime repair.",
      sourceDiagnosticRunId: latestDiagnosticAttribution.evaluatedHistoricalRunId ?? null,
      proofCommand: SPEED_PROMOTION_COMMAND,
    };
  }
  if (target === "scanFile") {
    return {
      id: "retainable_scan_file_runtime_probe",
      status: "allowed_next_evidence",
      owner: "tools/scripts/compare-historical-speed.mjs retainable predecessor gate",
      reason: "Fresh diagnostic attribution found scanFile pressure, but diagnostic attribution is non-promotional. Run the normal strict installed, predecessor, and older-snapshot gates before selecting any scanFile runtime repair.",
      sourceDiagnosticRunId: latestDiagnosticAttribution.evaluatedHistoricalRunId ?? null,
      proofCommand: SPEED_PROMOTION_COMMAND,
    };
  }
  return {
    id: "retainable_runtime_probe",
    status: "allowed_next_evidence",
    owner: "tools/scripts/compare-historical-speed.mjs retainable predecessor gate",
    reason: "Fresh diagnostic attribution exists, but it cannot authorize runtime promotion. Run the normal strict installed, predecessor, and older-snapshot gates before selecting a runtime repair.",
    sourceDiagnosticRunId: latestDiagnosticAttribution.evaluatedHistoricalRunId ?? null,
    proofCommand: SPEED_PROMOTION_COMMAND,
  };
}

if (!existsSync(reportPath)) {
  throw new Error(`historical report not found: ${reportPath}`);
}

const historical = readJson(reportPath, {});
const rounds = Array.isArray(historical.roundLedger) ? historical.roundLedger : [];
const comparisonCurrentHashes = historicalComparisonHashes(historical);
const evidenceFresh =
  currentIxSha256 != null &&
  comparisonCurrentHashes.length > 0 &&
  comparisonCurrentHashes.every((hash) => hash === currentIxSha256);
const summary = roundSummary(rounds);
const leakSummary = phaseLeakSummaryFromRounds(rounds);
const quality = evidenceQuality(historical);
const basis = researchBasis();
const moves = candidateMoves(summary, leakSummary, quality);
const rejectedIds = moves.filter((move) => move.status === "rejected").map((move) => move.id);
const engineeringMove = nextEngineeringMove(moves, summary, leakSummary);
const policy = preservationPolicy(summary, leakSummary, quality, engineeringMove);
const diagnosticReportPath = selectFreshDiagnosticHistoricalReport(currentIxSha256);
const latestDiagnosticAttribution = diagnosticAttributionReport(diagnosticReportPath, currentIxSha256);
const latestNativeInstalledReportPath = selectRetainableFreshNativeInstalledReport(currentIxSha256) ?? LATEST_INSTALLED_PATH;
const speedProofPointers = {
  latestDiagnostic: historicalPointerStatus(LATEST_HISTORICAL_PATH, currentIxSha256),
  latestRetainable: historicalPointerStatus(LATEST_RETAINABLE_HISTORICAL_PATH, currentIxSha256),
  latestInstalledDiagnostic: installedPointerStatus(latestNativeInstalledReportPath, currentIxSha256),
  latestInstalled: installedPointerStatus(LATEST_RETAINABLE_INSTALLED_PATH, currentIxSha256),
  latestOlderSnapshots: olderSnapshotPointerStatus(LATEST_OLDER_SNAPSHOT_PATH),
};
const selectedInstalledPointer = selectedInstalledPointerStatus(speedProofPointers);
const selectedInstalledPath = selectedInstalledPointer?.path ? path.resolve(ROOT, selectedInstalledPointer.path) : LATEST_INSTALLED_PATH;
const evidenceMove = nextEvidenceMove(latestDiagnosticAttribution, speedProofPointers);
const effectiveEngineeringMove =
  evidenceMove?.status?.startsWith("blocked_by_") === true
    ? evidenceMove
    : engineeringMove;
const benchmarkStatus = currentSpeedStatus({
  summary,
  historical,
  installedStatus: selectedInstalledPointer,
  installedEvidencePath: selectedInstalledPath,
  historicalDiagnosticStatus: speedProofPointers.latestDiagnostic,
  historicalRetainableStatus: speedProofPointers.latestRetainable,
  olderStatus: speedProofPointers.latestOlderSnapshots,
});
const promotionAllowed =
  historical.scorecard?.netPositive === true &&
  summary.matchParity === true &&
  summary.routeParity === true &&
  summary.fullScanCallsParity === true &&
  summary.fullScanBytesParity === true &&
  summary.fullScanMatchesParity === true &&
  summary.netPositiveRounds === summary.count &&
  quality.usableForRuntimeMove === true &&
  speedProofPointers.latestRetainable.status === "retainable_current" &&
  selectedInstalledPointer?.status === "promotable_current" &&
  speedProofPointers.latestOlderSnapshots.status === "retainable_current";

function installedPromotionBlocker(pointer) {
  const status = pointer?.status ?? "missing";
  if (status === "promotion_failed") {
    const failures = Array.isArray(pointer?.promotionFailures) && pointer.promotionFailures.length > 0
      ? `: ${pointer.promotionFailures.join("; ")}`
      : "";
    return `current installed-vs-repo promotion proof exists and failed (${pointer?.runId ?? "unknown run"})${failures}; change the runtime candidate or benchmark owner before rerunning promotion`;
  }
  if (status === "stale_current_binary") {
    return `installed-vs-repo promotion proof is stale for the current repo binary (${pointer?.runId ?? "unknown run"}); rerun the installed speed gate before finalizing code changes`;
  }
  return `no current installed-vs-repo promotion proof (${status}); run the installed speed gate before finalizing code changes`;
}

const finalizationGate = {
  speedRegressionFinalizationAllowed: promotionAllowed,
  requiredRetainablePointer: speedProofPointers.latestRetainable,
  requiredInstalledPointer: speedProofPointers.latestInstalled,
  latestInstalledDiagnosticPointer: speedProofPointers.latestInstalledDiagnostic,
  selectedInstalledPointer,
  latestDiagnosticPointer: speedProofPointers.latestDiagnostic,
  requiredProofCommand: SPEED_PROMOTION_COMMAND,
  blocker: promotionAllowed
    ? null
    : (
        selectedInstalledPointer?.status !== "promotable_current"
          ? installedPromotionBlocker(selectedInstalledPointer)
          : speedProofPointers.latestOlderSnapshots.status !== "retainable_current"
          ? `no current older-snapshot proof (${speedProofPointers.latestOlderSnapshots.status}); run the older-snapshot speed gate before finalizing code changes`
          : speedProofPointers.latestRetainable.status === "retainable_current"
          ? "current retainable strict proof exists, but the selected report is not net-positive enough for runtime promotion"
          : `no current retainable strict speed proof (${speedProofPointers.latestRetainable.status}); run the strict speed gate before finalizing code changes`
      ),
};
const noRuntimePromotionReason = (() => {
  if (!evidenceFresh) return "historical report candidate hash does not match the current repo binary";
  if (promotionAllowed) return null;
  if (selectedInstalledPointer?.status !== "promotable_current") {
    return selectedInstalledPointer?.status === "promotion_failed"
      ? "current installed-vs-repo promotion proof exists and failed; finalization requires a changed runtime candidate or benchmark owner followed by a passing installed speed gate"
      : "no current installed-vs-repo promotion proof exists for the repo binary; finalization must run and pass the installed speed gate";
  }
  if (speedProofPointers.latestRetainable.status !== "retainable_current") {
    return "no current retainable strict speed proof exists for the repo binary; finalization must run and pass the strict predecessor speed gate";
  }
  if (policy.preserveTeddyGain) {
    return "Teddy gain is protected, but whole-engine evidence is not net-positive; repair the leak instead of reverting";
  }
  if (blockedByBenchmarkNoise(quality)) {
    return "historical report is blocked by host, identity-control, process, or sample-size benchmark noise";
  }
  return "historical report is not net-positive across all previous-build rounds";
})();

const report = {
  runId: `teddy-kernel-decision-${timestampSlug()}`,
  timestamp: new Date().toISOString(),
  inputReport: path.relative(ROOT, reportPath),
  reportSelection,
  evaluatedHistoricalRunId: historical.runId ?? null,
  currentIx: path.relative(ROOT, currentIx),
  currentIxSha256,
  comparisonCurrentHashes,
  evidenceFresh,
  promotionAllowed,
  speedProofPointers,
  finalizationGate,
  proofCommands: {
    installedStrictSpeed: INSTALLED_SPEED_STRICT_COMMAND,
    historicalSpeed: HISTORICAL_SPEED_DIAGNOSTIC_COMMAND,
    historicalStrictSpeed: HISTORICAL_SPEED_STRICT_COMMAND,
    olderSnapshots: OLDER_SNAPSHOT_PROOF_COMMAND,
    speedGate: SPEED_PROMOTION_COMMAND,
  },
  noRuntimePromotionReason,
  benchmarkStatus,
  scorecard: historical.scorecard ?? null,
  summary,
  leakSummary,
  latestDiagnosticAttribution,
  preservationPolicy: policy,
  evidenceQuality: quality,
  researchBasis: basis,
  recentHistoricalReports: latestHistoricalReports(),
  candidateMoves: moves,
  rejectedIds,
  requiredKernelProof: requiredKernelProof(engineeringMove),
  nextEvidenceMove: evidenceMove,
  nextAllowedMove: moves.find((move) => move.status === "allowed_next") ?? null,
  nextRuntimeMove: engineeringMove,
  nextEngineeringMove: effectiveEngineeringMove,
};

mkdirSync(path.dirname(outPath), { recursive: true });
writeFileSync(outPath, `${JSON.stringify(report, null, 2)}\n`, "utf8");
mkdirSync(REPORT_DIR, { recursive: true });
writeFileSync(path.join(REPORT_DIR, "latest-teddy-kernel-decision.json"), `${JSON.stringify(report, null, 2)}\n`, "utf8");

if (!quiet) {
  console.log(JSON.stringify({
    outPath,
    evaluatedHistoricalRunId: report.evaluatedHistoricalRunId,
    promotionAllowed,
    summary,
    nextAllowedMove: report.nextAllowedMove,
    rejected: rejectedIds,
  }, null, 2));
}
