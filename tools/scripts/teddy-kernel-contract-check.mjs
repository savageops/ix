import { existsSync, mkdirSync, readFileSync, readdirSync, writeFileSync } from "node:fs";
import { createHash } from "node:crypto";
import path from "node:path";
import { DEFAULT_RIPGREP_LINUX_CORPUS, hasExperimentalBenchEnv } from "./lib/benchmark-config.mjs";
import { argValue, timestampSlug } from "./lib/script-helpers.mjs";

const ROOT = process.cwd();
const DEFAULT_CONTRACT = path.join(ROOT, ".docs", "research", "2026-06-13-packed-teddy-kernel-proof-contract.md");
const DEFAULT_DECISION = path.join(ROOT, "tools", "reports", "teddy-kernel-decision", "latest-teddy-kernel-decision.json");
const REPORT_DIR = path.join(ROOT, "tools", "reports", "teddy-kernel-contract");
const INSTALLED_REPORT_DIR = path.join(ROOT, "tools", "reports", "manual-speed-compare");
const REQUIRED_INSTALLED_THREADS = 32;
const REQUIRED_INSTALLED_SAMPLES = 12;
const REQUIRED_INSTALLED_RETAINABLE_SAMPLES = 12;

const args = process.argv.slice(2);
if (args.includes("--help") || args.includes("-h")) {
  console.log(`Usage: node tools/scripts/teddy-kernel-contract-check.mjs [options]

Validates the packed Teddy kernel proof contract against the latest Teddy
decision report. This is a guardrail only; it does not modify IX runtime code.

Options:
  --contract <path>    Contract markdown path.
  --decision <path>    Teddy decision JSON path.
  --out <path>         Output report path.
  --quiet              Write report without printing summary.
  --help, -h           Print this help and exit.
`);
  process.exit(0);
}

const contractPath = path.resolve(argValue(args, "--contract", DEFAULT_CONTRACT));
const decisionPath = path.resolve(argValue(args, "--decision", DEFAULT_DECISION));
const outPath = path.resolve(argValue(args, "--out", path.join(REPORT_DIR, `teddy-kernel-contract-${timestampSlug()}.json`)));
const quiet = args.includes("--quiet");

function readText(filePath) {
  return existsSync(filePath) ? readFileSync(filePath, "utf8") : "";
}

function readJson(filePath) {
  return JSON.parse(readFileSync(filePath, "utf8"));
}

function includesAll(haystack, needles) {
  return needles.filter((needle) => !haystack.includes(needle));
}

function normalized(text) {
  return text.replaceAll("\\", "/").toLowerCase();
}

function nativeInstalledBaselinePath(filePath) {
  return normalized(String(filePath ?? "")).endsWith("/appdata/local/programs/iex/bin/ix.exe");
}

function finiteNumber(value) {
  const number = Number(value);
  return Number.isFinite(number);
}

function executableSha256File(filePath) {
  if (!existsSync(filePath)) return null;
  return executableHash(readFileSync(filePath));
}

function executableHash(bytes) {
  const normalized = Buffer.from(bytes);
  const pe = peLayout(normalized);
  if (pe == null) return createHash("sha256").update(normalized).digest("hex").toUpperCase();
  normalized.fill(0, pe.coffTimestampOffset, pe.coffTimestampOffset + 4);
  const buildId = pe.sections.find((section) => section.name === ".buildid");
  if (buildId != null && buildId.rawPointer + buildId.rawSize <= normalized.length) {
    normalized.fill(0, buildId.rawPointer, buildId.rawPointer + buildId.rawSize);
  }
  return createHash("sha256").update(normalized).digest("hex").toUpperCase();
}

function peLayout(bytes) {
  if (bytes.length < 0x40 || bytes[0] !== 0x4d || bytes[1] !== 0x5a) return null;
  const peOffset = bytes.readUInt32LE(0x3c);
  if (peOffset + 24 > bytes.length) return null;
  if (bytes[peOffset] !== 0x50 || bytes[peOffset + 1] !== 0x45 || bytes[peOffset + 2] !== 0 || bytes[peOffset + 3] !== 0) return null;
  const sectionCount = bytes.readUInt16LE(peOffset + 6);
  const optionalHeaderSize = bytes.readUInt16LE(peOffset + 20);
  const optionalHeaderOffset = peOffset + 24;
  if (optionalHeaderOffset + optionalHeaderSize > bytes.length) return null;
  const sectionOffset = optionalHeaderOffset + optionalHeaderSize;
  const sections = [];
  for (let index = 0; index < sectionCount; index += 1) {
    const offset = sectionOffset + index * 40;
    if (offset + 40 > bytes.length) break;
    const nul = bytes.indexOf(0, offset);
    const nameEnd = nul >= offset && nul < offset + 8 ? nul : offset + 8;
    sections.push({
      name: bytes.subarray(offset, nameEnd).toString("ascii"),
      rawSize: bytes.readUInt32LE(offset + 16),
      rawPointer: bytes.readUInt32LE(offset + 20),
    });
  }
  return { coffTimestampOffset: peOffset + 8, sections };
}

function installedReportStatus(filePath, currentHash, currentExecutableHash = null) {
  if (!existsSync(filePath)) return null;
  const report = readJson(filePath);
  const repoSha256 = report.binaries?.repo?.sha256 ?? null;
  const installedExecutableSha256 = report.binaries?.installed?.executableSha256 ?? report.binaries?.installed?.sha256 ?? null;
  const repoExecutableSha256 = report.binaries?.repo?.executableSha256 ?? report.binaries?.repo?.sha256 ?? null;
  const installedPath = report.binaries?.installed?.path ?? null;
  const currentInstalledExecutableSha256 = installedPath != null ? executableSha256File(installedPath) : null;
  const threads = Number(report.threads);
  const samples = Number(report.samples);
  const minRetainableSamples = Number(report.minRetainableSamples);
  const promotionFailures = Array.isArray(report.promotionFailures) ? report.promotionFailures : [];
  const experimentalEnvMode = hasExperimentalBenchEnv(report);
  const diagnosticAttributionMode =
    report.diagnosticAttributionMode === true ||
    report.scanOpenTiming === true ||
    report.linuxDominantAttribution === true ||
    experimentalEnvMode ||
    promotionFailures.includes("diagnostic_attribution_run_not_promotion_evidence");
  const canonicalCorpus = normalized(String(report.corpus ?? "")) === normalized(DEFAULT_RIPGREP_LINUX_CORPUS);
  const nativeInstalledBaseline = nativeInstalledBaselinePath(installedPath);
  return {
    path: path.relative(ROOT, filePath),
    runId: report.runId ?? path.basename(filePath, ".json"),
    timestamp: report.timestamp ?? null,
    freshForCurrentBinary:
      currentExecutableHash != null && repoExecutableSha256 != null
        ? repoExecutableSha256 === currentExecutableHash
        : (currentHash != null && repoSha256 === currentHash),
    freshForInstalledBinary:
      installedExecutableSha256 != null &&
      currentInstalledExecutableSha256 != null &&
      installedExecutableSha256 === currentInstalledExecutableSha256,
    sameExecutableBinary:
      installedExecutableSha256 != null &&
      repoExecutableSha256 != null &&
      installedExecutableSha256 === repoExecutableSha256,
    retainableStrictEvidence: report.retainableStrictEvidence === true,
    diagnosticAttributionMode,
    experimentalEnvMode,
    nativeInstalledBaseline,
    canonicalThreadConfig: threads === REQUIRED_INSTALLED_THREADS,
    canonicalSampleConfig:
      samples >= REQUIRED_INSTALLED_SAMPLES &&
      minRetainableSamples >= REQUIRED_INSTALLED_RETAINABLE_SAMPLES,
    canonicalCorpus,
    installedPath,
    repoSha256,
    installedExecutableSha256,
    repoExecutableSha256,
    currentInstalledExecutableSha256,
    threads: Number.isFinite(threads) ? threads : null,
    samples: Number.isFinite(samples) ? samples : null,
    minRetainableSamples: Number.isFinite(minRetainableSamples) ? minRetainableSamples : null,
    corpus: report.corpus ?? null,
  };
}

function newestRetainableFreshNativeInstalledReport(currentHash, currentExecutableHash = null) {
  if (!existsSync(INSTALLED_REPORT_DIR) || (currentHash == null && currentExecutableHash == null)) return null;
  const candidates = readdirSync(INSTALLED_REPORT_DIR)
    .filter((name) => /^installed-speed-.*\.json$/.test(name))
    .map((name) => installedReportStatus(path.join(INSTALLED_REPORT_DIR, name), currentHash, currentExecutableHash))
    .filter((status) =>
      status?.freshForCurrentBinary === true &&
      status.freshForInstalledBinary === true &&
      status.sameExecutableBinary !== true &&
      status.retainableStrictEvidence === true &&
      status.diagnosticAttributionMode !== true &&
      status.nativeInstalledBaseline === true &&
      status.canonicalThreadConfig === true &&
      status.canonicalSampleConfig === true &&
      status.canonicalCorpus === true)
    .sort((left, right) => String(right.timestamp ?? right.runId).localeCompare(String(left.timestamp ?? left.runId)));
  return candidates[0] ?? null;
}

const failures = [];
if (!existsSync(contractPath)) failures.push(`contract missing: ${path.relative(ROOT, contractPath)}`);
if (!existsSync(decisionPath)) failures.push(`decision missing: ${path.relative(ROOT, decisionPath)}`);

const contract = readText(contractPath);
const contractLower = normalized(contract);
const decision = existsSync(decisionPath) ? readJson(decisionPath) : {};

const requiredSources = [
  ".docs/research/2026-06-12-teddy-literal-alternates-contract.md",
  ".docs/research/insect-packed-teddy-kernel-contract-20260613.json",
  ".docs/research/insect-simd-multipattern-prefilter-20260613.json",
  ".docs/research/insect-performance-attribution-next-20260613.json",
  ".refs/stringzilla/include/stringzilla/find.h",
  "tools/reports/teddy-kernel-decision/latest-teddy-kernel-decision.json",
];

const requiredTerms = [
  "packed_nibble_shuffle_teddy_kernel",
  "packed nibble/shuffle simd extractor",
  "pshufb",
  "vpshufb",
  "testedoneatatime === true",
  "previousbuildrounds > 0",
  "every previous-build round is net positive",
  "candidate binary hash matches the current repo binary",
  "no same-binary identity noise is counted as a retained improvement",
];

const rejectedShapes = [
  "scalar_start_byte_or_line_admission",
  "parallel_first_read_positional_transplant",
  "scalar_teddy_lite",
  "generic_sparse_aho_corasick",
  "range_level_whole_buffer_teddy",
  "range_level_c_ffi_packed_teddy_helper",
  "inline_zig_vpshufb_nibble_tables",
  "offset_only_fingerprint_selector",
  "branch4_vector_mask_scalar_tail",
];

const requiredProofCommands = [
  "zig build test --summary all",
  "zig build -Doptimize=ReleaseFast --summary all",
  "alternates-decision-table.mjs --branch-counts 4 --samples 12",
  "compare-historical-speed.mjs --samples 12",
  "teddy-kernel-decision.mjs --quiet",
  "teddy-kernel-contract-check.mjs",
  "ix-architecture-regression-gate.mjs --quick",
];

const requiredDecisionProofCommands = [
  "compare-installed-speed.mjs --samples 12",
  "compare-historical-speed.mjs --samples 12",
  "compare-older-snapshots.mjs --samples 12",
  "--identity-control-attempts 3",
  "--min-retainable-samples 12",
  "--max-snapshots 2",
  "--target-retainable-snapshots 2",
  "--min-engine-improvement-pct 5",
  "--min-paired-improvement-pct 5",
  "--require-strict",
  "--require-promotion",
];

for (const source of includesAll(contractLower, requiredSources.map((entry) => entry.toLowerCase()))) {
  failures.push(`contract missing source: ${source}`);
}
for (const term of includesAll(contractLower, requiredTerms.map((entry) => entry.toLowerCase()))) {
  failures.push(`contract missing invariant: ${term}`);
}
for (const rejected of includesAll(contractLower, rejectedShapes.map((entry) => entry.toLowerCase()))) {
  failures.push(`contract missing rejected shape: ${rejected}`);
}
for (const command of includesAll(contractLower, requiredProofCommands.map((entry) => entry.toLowerCase()))) {
  failures.push(`contract missing proof command: ${command}`);
}

const decisionRejectedIds = new Set((decision.candidateMoves ?? [])
  .filter((move) => move?.status === "rejected")
  .map((move) => move.id));
const topLevelRejectedIds = new Set(Array.isArray(decision.rejectedIds) ? decision.rejectedIds : []);
if (decision.evidenceFresh !== true) failures.push("decision evidence is not fresh for current repo binary");
if (decision.promotionAllowed === true) failures.push("decision unexpectedly allows runtime promotion");
const retainablePointer = decision.speedProofPointers?.latestRetainable ?? decision.finalizationGate?.requiredRetainablePointer ?? null;
const diagnosticPointer = decision.speedProofPointers?.latestDiagnostic ?? decision.finalizationGate?.latestDiagnosticPointer ?? null;
const installedPointer = decision.speedProofPointers?.latestInstalled ?? decision.finalizationGate?.requiredInstalledPointer ?? null;
const installedDiagnosticPointer = decision.speedProofPointers?.latestInstalledDiagnostic ?? decision.finalizationGate?.latestInstalledDiagnosticPointer ?? null;
const retainablePointerReady = retainablePointer?.status === "retainable_current";
const installedPointerReady = installedPointer?.status === "promotable_current";
if (diagnosticPointer == null || typeof diagnosticPointer !== "object") {
  failures.push("decision lacks latest diagnostic speed proof pointer");
}
if (retainablePointer == null || typeof retainablePointer !== "object") {
  failures.push("decision lacks latest retainable speed proof pointer");
}
if (installedPointer == null || typeof installedPointer !== "object") {
  failures.push("decision lacks latest retainable installed-vs-repo speed proof pointer");
}
if (installedDiagnosticPointer == null || typeof installedDiagnosticPointer !== "object") {
  failures.push("decision lacks latest diagnostic installed-vs-repo speed proof pointer");
}
if (installedDiagnosticPointer?.freshForCurrentBinary === true) {
  const installedDiagnosticPath = normalized(String(installedDiagnosticPointer.installedPath ?? ""));
  if (!installedDiagnosticPath.includes("/appdata/local/programs/iex/bin/ix.exe")) {
    failures.push("decision installed diagnostic pointer must use the native AppData install path");
  }
  if (installedDiagnosticPath.includes("/tmp-baselines/")) {
    failures.push("decision installed diagnostic pointer must not use tmp-baselines");
  }
  const newestInstalledDiagnostic = newestRetainableFreshNativeInstalledReport(decision.currentIxSha256 ?? null, decision.currentIxExecutableSha256 ?? null);
  if (newestInstalledDiagnostic != null &&
      installedDiagnosticPointer.runId !== newestInstalledDiagnostic.runId) {
    failures.push(`decision installed diagnostic pointer must select newest retainable fresh native report: ${newestInstalledDiagnostic.runId}`);
  }
  if (installedDiagnosticPointer.status === "promotion_failed") {
    const deficit = installedDiagnosticPointer.promotionDeficit ?? null;
    const promotionFailures = Array.isArray(installedDiagnosticPointer.promotionFailures)
      ? installedDiagnosticPointer.promotionFailures
      : [];
    if (promotionFailures.length === 0) {
      failures.push("decision installed diagnostic pointer must expose promotion failure strings");
    }
    if (deficit == null || typeof deficit !== "object" || Array.isArray(deficit)) {
      failures.push("decision installed diagnostic pointer must expose promotion deficit details");
    } else {
      for (const field of [
        "installedEngineMedianMs",
        "repoEngineMedianMs",
        "installedEngineVsRepoEnginePct",
        "installedPairedImprovementMedianPct",
        "repoPairedWinRate",
      ]) {
        if (!finiteNumber(deficit[field])) {
          failures.push(`decision installed diagnostic promotion deficit missing numeric field: ${field}`);
        }
      }
      if (!finiteNumber(deficit.ripgrepCliMedianMs) && !finiteNumber(deficit.ripgrepNoMmapCliMedianMs)) {
        failures.push("decision installed diagnostic promotion deficit must expose a ripgrep comparator median");
      }
    }
  }
}
if (diagnosticPointer?.freshForCurrentBinary === true && diagnosticPointer.diagnosticAttributionMode === true) {
  const diagnosticAttribution = decision.latestDiagnosticAttribution ?? null;
  if (diagnosticAttribution == null || typeof diagnosticAttribution !== "object" || Array.isArray(diagnosticAttribution)) {
    failures.push("decision lacks latest diagnostic attribution summary");
  } else {
    if (diagnosticAttribution.freshForCurrentBinary !== true) {
      failures.push("decision diagnostic attribution summary must be fresh for current binary");
    }
    if (diagnosticAttribution.diagnosticAttributionMode !== true) {
      failures.push("decision diagnostic attribution summary must come from a diagnostic attribution report");
    }
    if (diagnosticAttribution.usableForRuntimeMove !== false) {
      failures.push("decision diagnostic attribution summary must remain non-promotional");
    }
    if (diagnosticAttribution.nextRepairTarget == null) {
      failures.push("decision diagnostic attribution summary must expose next repair target");
    }
    if (diagnosticAttribution.nextRepairTarget === "scanFile") {
      const split = diagnosticAttribution.leakSummary?.leakAttribution?.currentOnlyScanSplit ?? null;
      if (split == null || typeof split !== "object" || Array.isArray(split)) {
        failures.push("decision scanFile diagnostic attribution must include current-only scan-file component split");
      } else {
        if (split.regressingCandidateSubphase !== "scanFile") {
          failures.push("decision scanFile diagnostic attribution must identify scanFile as the regressing subphase");
        }
        if (!["teddyRange", "alternateFullScan", "scanFileFastCount", "scanFileResidual"].includes(split.dominantCandidateScanFileComponent)) {
          failures.push("decision scanFile diagnostic attribution must name dominant scan-file component");
        }
      }
    }
  }
}
if (decision.finalizationGate?.requiredProofCommand == null ||
    !normalized(String(decision.finalizationGate.requiredProofCommand)).includes("compare-installed-speed.mjs") ||
    !normalized(String(decision.finalizationGate.requiredProofCommand)).includes("compare-historical-speed.mjs") ||
    !normalized(String(decision.finalizationGate.requiredProofCommand)).includes("--require-promotion") ||
    !normalized(String(decision.finalizationGate.requiredProofCommand)).includes("--require-strict")) {
  failures.push("decision finalization gate lacks strict installed and historical proof command");
}
if (decision.finalizationGate?.speedRegressionFinalizationAllowed !== decision.promotionAllowed) {
  failures.push("decision finalization gate must mirror promotionAllowed");
}
if (!installedPointerReady) {
  if (decision.promotionAllowed === true) failures.push("decision allows promotion without current installed-vs-repo promotion proof");
  if (decision.finalizationGate?.speedRegressionFinalizationAllowed === true) failures.push("decision allows finalization without current installed-vs-repo promotion proof");
  const blocker = String(decision.finalizationGate?.blocker ?? "");
  const noRuntimeReason = String(decision.noRuntimePromotionReason ?? "");
  const installedProofStateNamed =
    blocker.includes("no current installed-vs-repo promotion proof") ||
    blocker.includes("installed-vs-repo promotion proof is stale") ||
    blocker.includes("current installed-vs-repo promotion proof exists and failed") ||
    blocker.includes("identity-noise evidence");
  const installedReasonStateNamed =
    noRuntimeReason.includes("no current installed-vs-repo promotion proof") ||
    noRuntimeReason.includes("current installed-vs-repo promotion proof exists and failed") ||
    noRuntimeReason.includes("identity-noise evidence");
  if (!installedProofStateNamed) {
    failures.push("decision finalization gate must name missing/stale/failed installed-vs-repo promotion proof as blocker");
  }
  if (!installedReasonStateNamed) {
    failures.push("decision no-runtime reason must name missing or failed installed-vs-repo promotion proof");
  }
}
if (!retainablePointerReady) {
  if (decision.promotionAllowed === true) failures.push("decision allows promotion without current retainable strict speed proof");
  if (decision.finalizationGate?.speedRegressionFinalizationAllowed === true) failures.push("decision allows finalization without current retainable strict speed proof");
  if (installedPointerReady && !String(decision.finalizationGate?.blocker ?? "").includes("no current retainable strict speed proof")) {
    failures.push("decision finalization gate must name missing/stale retainable strict proof as blocker");
  }
  if (installedPointerReady && !String(decision.noRuntimePromotionReason ?? "").includes("no current retainable strict speed proof")) {
    failures.push("decision no-runtime reason must name missing retainable strict speed proof");
  }
}
const teddyGainNeedsLeakRepair =
  decision.leakSummary?.diagnosis === "preserve_positive_teddy_gain_and_repair_whole_engine_leak" &&
  decision.summary?.matchParity === true &&
  decision.summary?.routeParity === true;
const evidenceQuality = decision.evidenceQuality ?? {};
const benchmarkNoiseFailures = [
  ...(evidenceQuality.hostFailures ?? []),
  ...(evidenceQuality.identityFailures ?? []),
  ...(evidenceQuality.processFailures ?? []),
  ...(evidenceQuality.sampleFailures ?? []),
];
const evidenceBlockedByNoise = benchmarkNoiseFailures.length > 0;
function focusedSlowestTeddyNegative(decision) {
  const focused = decision?.focusedSlowestEvidence ?? null;
  return (
    focused != null &&
    typeof focused === "object" &&
    !Array.isArray(focused) &&
    focused.status === "focused_teddy_negative" &&
    focused.freshForCurrentBinary === true &&
    focused.retainableFocusedEvidence === true &&
    focused.experimentalFocusedEvidence !== true
  );
}
function expectedScanWorkRepairMove(split) {
  if (split?.regressingCandidateSubphase === "scanFile") return "scan_file_residual_hotspot_attribution";
  if (split?.regressingCandidateSubphase === "scanOpen") return "scan_open_path_pressure_attribution";
  return "whole_engine_leak_attribution";
}
function diagnosticAttributionOnly(quality) {
  return (quality?.comparisonFailures ?? []).includes("diagnostic_attribution_run_not_retainable_evidence");
}
function activeAttribution(decision) {
  if (
    decision?.nextEvidenceMove?.status === "allowed_next_evidence" &&
    decision?.latestDiagnosticAttribution != null &&
    typeof decision.latestDiagnosticAttribution === "object" &&
    !Array.isArray(decision.latestDiagnosticAttribution) &&
    decision.latestDiagnosticAttribution.freshForCurrentBinary === true &&
    decision.latestDiagnosticAttribution.diagnosticAttributionMode === true &&
    decision.latestDiagnosticAttribution.usableForRuntimeMove === false
  ) {
    return {
      split: decision.latestDiagnosticAttribution.leakSummary?.leakAttribution?.currentOnlyScanSplit,
      quality: decision.latestDiagnosticAttribution.evidenceQuality ?? {},
      target: decision.latestDiagnosticAttribution.nextRepairTarget ?? decision.latestDiagnosticAttribution.leakSummary?.nextRepairTarget ?? null,
    };
  }
  return {
    split: decision?.leakSummary?.leakAttribution?.currentOnlyScanSplit,
    quality: decision?.evidenceQuality ?? {},
    target: decision?.leakSummary?.nextRepairTarget ?? null,
  };
}
function expectedScanWorkNextMove(split, quality, target = null) {
  if (diagnosticAttributionOnly(quality) && target === "scanOpen") {
    return "retainable_scan_open_runtime_probe";
  }
  if (target === "scanOpen") return "scan_open_path_pressure_attribution";
  if (target === "scanFile") return "scan_file_residual_hotspot_attribution";
  if (diagnosticAttributionOnly(quality) && split?.regressingCandidateSubphase === "scanOpen") {
    return "retainable_scan_open_runtime_probe";
  }
  return expectedScanWorkRepairMove(split);
}
function expectedActiveRepairMove(attribution) {
  return expectedScanWorkNextMove(attribution.split, attribution.quality, attribution.target);
}
function expectedActiveRepairOwner(attribution) {
  if (attribution.target === "scanOpen") return "scan_open_path_pressure_attribution";
  if (attribution.target === "scanFile") return "scan_file_residual_hotspot_attribution";
  return expectedScanWorkRepairMove(attribution.split);
}
const activeExpectedAttribution = activeAttribution(decision);
const focusedTeddyNegative = focusedSlowestTeddyNegative(decision);
const expectedNextMove = evidenceBlockedByNoise
  ? "benchmark_host_noise_control"
  : (
      focusedTeddyNegative
        ? "focused_slowest_teddy_regression_attribution"
        :
      ["scanOpen", "scanFile"].includes(activeExpectedAttribution.target)
        ? expectedActiveRepairMove(activeExpectedAttribution)
        :
      teddyGainNeedsLeakRepair &&
      ["scan_file_residual_hotspot_attribution", "scan_open_path_pressure_attribution"].includes(expectedActiveRepairOwner(activeExpectedAttribution))
        ? expectedActiveRepairMove(activeExpectedAttribution)
        : (teddyGainNeedsLeakRepair ? "whole_engine_leak_attribution" : "packed_nibble_shuffle_teddy_kernel")
    );
const evidenceBlockedMove =
  typeof decision.nextAllowedMove?.status === "string" &&
  decision.nextAllowedMove.status.startsWith("blocked_by_") &&
  ["retainable_runtime_probe", "retainable_scan_open_runtime_probe", "retainable_scan_file_runtime_probe"].includes(decision.nextAllowedMove?.id);
if (!evidenceBlockedMove && decision.nextAllowedMove?.id !== expectedNextMove) {
  failures.push(`decision next move expected ${expectedNextMove}`);
}
if (evidenceBlockedMove && !String(decision.nextAllowedMove?.proofCommand ?? "").includes("compare-installed-speed.mjs")) {
  failures.push("blocked runtime evidence move must route to installed speed proof");
}
if (teddyGainNeedsLeakRepair &&
    !evidenceBlockedByNoise &&
    !decision.candidateMoves?.some((move) =>
      move?.id === "packed_nibble_shuffle_teddy_kernel" &&
      move?.status === "allowed_after_whole_engine_leak_attribution")) {
  failures.push("decision must preserve packed Teddy as follow-up after whole-engine leak attribution");
}
if (teddyGainNeedsLeakRepair) {
  if (decision.preservationPolicy?.preserveTeddyGain !== true) {
    failures.push("decision preservation policy must protect the positive Teddy gain");
  }
  const expectedRepairMove = focusedTeddyNegative
    ? "focused_slowest_teddy_regression_attribution"
    : expectedActiveRepairMove(activeExpectedAttribution);
  if (decision.preservationPolicy?.nextEngineeringMoveId !== expectedRepairMove) {
    failures.push("decision preservation policy must route engineering repair to the proved repair owner");
  }
  if (decision.nextEngineeringMove?.id !== "whole_engine_leak_attribution") {
    const expectedRuntimeMove = focusedTeddyNegative
      ? "focused_slowest_teddy_regression_attribution"
      : expectedActiveRepairMove(activeExpectedAttribution);
    const evidenceBlocked =
      typeof decision.nextEngineeringMove?.status === "string" &&
      decision.nextEngineeringMove.status.startsWith("blocked_by_") &&
      decision.nextEvidenceMove?.id === decision.nextEngineeringMove?.id &&
      decision.nextRuntimeMove?.id === expectedRuntimeMove;
    if (!evidenceBlocked && decision.nextEngineeringMove?.id !== expectedRuntimeMove) {
      failures.push("decision must expose the proved leak owner as next engineering move");
    }
  }
  if (
    decision.leakSummary?.nextRepairTarget === "scanWork" &&
    !focusedTeddyNegative &&
    !diagnosticAttributionOnly(activeExpectedAttribution.quality) &&
    !String(decision.nextAllowedMove?.proofCommand ?? "").includes("--scan-open-timing")
  ) {
    failures.push("decision scanWork leak attribution proof command must enable scan-open timing");
  }
  if (!String(decision.preservationPolicy?.rule ?? "").includes("do_not_revert_teddy_gain")) {
    failures.push("decision preservation policy must encode the no-revert Teddy rule");
  }
  if (decision.leakSummary?.nextRepairTarget === "scanWork") {
    const split = decision.leakSummary?.leakAttribution?.currentOnlyScanSplit;
    if (split == null || typeof split !== "object" || Array.isArray(split)) {
      failures.push("decision scanWork leak attribution must include current-only scanOpen/scanFile split summary");
    } else {
      if (Number(split.targetRoundCount ?? 0) < 1) {
        failures.push("decision scanWork leak attribution must include target rounds");
      }
      if (Number(split.candidateSplitRoundCount ?? 0) < Number(split.targetRoundCount ?? 0)) {
        failures.push("decision scanWork leak attribution must have candidate split telemetry for every target round");
      }
      if (!["scanOpen", "scanFile"].includes(split.dominantCandidateSubphase)) {
        failures.push("decision scanWork leak attribution must name dominant candidate subphase");
      }
      if (split.regressingCandidateSubphase != null && !["scanOpen", "scanFile"].includes(split.regressingCandidateSubphase)) {
        failures.push("decision scanWork leak attribution must name a valid regressing candidate subphase");
      }
      if (
        split.regressingCandidateSubphase === "scanFile" &&
        !decision.candidateMoves?.some((move) =>
          move?.id === "scan_file_residual_hotspot_attribution" &&
          move?.status === "allowed_next")
      ) {
        failures.push("decision scanFile-regressing attribution must route to scan-file residual hotspots");
      }
      if (
        split.regressingCandidateSubphase === "scanFile" &&
        !Array.isArray(split.candidateSlowestPathHotspots)
      ) {
        failures.push("decision scanFile-regressing attribution must include candidate slowest-path hotspots");
      }
      if (
        split.dominantCandidateSubphase === "scanOpen" &&
        split.regressingCandidateSubphase !== "scanFile" &&
        !decision.candidateMoves?.some((move) =>
          move?.id === (diagnosticAttributionOnly(evidenceQuality) ? "retainable_scan_open_runtime_probe" : "scan_open_path_pressure_attribution") &&
          move?.status === "allowed_next")
      ) {
        failures.push("decision scanOpen-dominant leak attribution must route to the correct retainable proof or scan-open pressure move");
      }
      if (
        split.dominantCandidateSubphase === "scanOpen" &&
        split.regressingCandidateSubphase !== "scanFile" &&
        Number(split.candidateScanOpenMsPerFileMedian?.median ?? 0) <= 0
      ) {
        failures.push("decision scanOpen-dominant leak attribution must include per-file open pressure");
      }
      if (
        split.dominantCandidateSubphase === "scanOpen" &&
        split.regressingCandidateSubphase !== "scanFile" &&
        split.filesScannedParity !== true
      ) {
        failures.push("decision scanOpen-dominant leak attribution must prove scanned-file-count parity");
      }
      if (
        split.dominantCandidateSubphase === "scanFile" &&
        !["teddyRange", "alternateFullScan", "scanFileFastCount", "scanFileResidual"].includes(split.dominantCandidateScanFileComponent)
      ) {
        failures.push("decision scanFile leak attribution must name dominant candidate scan-file component");
      }
      if (
        split.dominantCandidateScanFileComponent === "alternateFullScan" &&
        Number(split.candidateAlternateFullScanMedianMs?.median ?? 0) <= 0
      ) {
        failures.push("decision alternate full-scan attribution must include elapsed median timing");
      }
      if (
        split.dominantCandidateScanFileComponent === "scanFileResidual" &&
        !Array.isArray(split.candidateSlowestPathHotspots)
      ) {
        failures.push("decision scanFile residual attribution must include candidate slowest-path hotspots");
      }
    }
  }
}
if (
  !evidenceBlockedMove &&
  ["scanOpen", "scanFile"].includes(activeExpectedAttribution.target) &&
  !String(decision.nextAllowedMove?.proofCommand ?? "").includes("compare-historical-speed.mjs")
) {
  failures.push("decision runtime attribution move must include historical-speed proof command");
}
if (evidenceBlockedByNoise &&
    !decision.candidateMoves?.some((move) =>
      move?.id === "whole_engine_leak_attribution" &&
      move?.status === "blocked_by_benchmark_noise")) {
  failures.push("decision must block runtime leak attribution while host or identity-control noise is active");
}
if (decision.scorecard?.testedOneAtATime !== true) failures.push("decision scorecard is not one-at-a-time");
if (Number(decision.scorecard?.previousBuildRounds ?? 0) < 1) failures.push("decision scorecard has no previous-build rounds");
if (Number(decision.summary?.count ?? 0) < 1) failures.push("decision summary has no historical rounds");
if (decision.summary?.matchParity !== true) failures.push("decision summary lacks match parity");
if (decision.summary?.routeParity !== true) failures.push("decision summary lacks route parity");
if (decision.summary?.fullScanCallsParity !== true) failures.push("decision summary lacks alternates full-scan call parity");
if (decision.summary?.fullScanBytesParity !== true) failures.push("decision summary lacks alternates full-scan byte parity");
if (decision.summary?.fullScanMatchesParity !== true) failures.push("decision summary lacks alternates full-scan match parity");
if (!evidenceBlockedMove && !String(decision.nextAllowedMove?.proofCommand ?? "").includes("compare-historical-speed.mjs")) {
  failures.push("decision next move lacks historical-speed proof command");
}
if (evidenceBlockedMove && !String(decision.nextAllowedMove?.proofCommand ?? "").includes("compare-installed-speed.mjs")) {
  failures.push("blocked decision next move lacks installed-speed proof command");
}
const decisionProofText = normalized([
  decision.proofCommands?.installedStrictSpeed,
  decision.proofCommands?.historicalSpeed,
  decision.proofCommands?.olderSnapshots,
  decision.proofCommands?.speedGate,
  decision.nextAllowedMove?.proofCommand,
  decision.nextEngineeringMove?.proofCommand,
  ...(Array.isArray(decision.candidateMoves) ? decision.candidateMoves.map((move) => move?.proofCommand) : []),
].filter(Boolean).join("\n"));
for (const command of includesAll(decisionProofText, requiredDecisionProofCommands.map((entry) => entry.toLowerCase()))) {
  failures.push(`decision missing required proof command: ${command}`);
}
for (const rejected of [
  "scalar_start_byte_or_line_admission",
  "folded_trigram_admission_for_casefold_alternates",
  "parallel_first_read_positional_transplant",
]) {
  if (!decisionRejectedIds.has(rejected)) failures.push(`decision missing rejected move: ${rejected}`);
}
for (const rejected of decisionRejectedIds) {
  if (!topLevelRejectedIds.has(rejected)) failures.push(`decision top-level rejectedIds missing rejected move: ${rejected}`);
}
for (const rejected of topLevelRejectedIds) {
  if (!decisionRejectedIds.has(rejected)) failures.push(`decision top-level rejectedIds has non-rejected move: ${rejected}`);
}
if (decision.researchBasis?.contractSignals?.requiresPackedSimdExtractor !== true) {
  failures.push("decision research basis does not require packed SIMD extractor");
}
if (decision.researchBasis?.contractSignals?.rejectsScalarTeddyLite !== true) {
  failures.push("decision research basis does not reject scalar Teddy-lite");
}
if (!Array.isArray(decision.researchBasis?.references) || decision.researchBasis.references.length === 0) {
  failures.push("decision research basis has no references");
}
if (!decision.researchBasis?.files?.some((file) =>
  normalized(String(file?.path ?? "")) === ".docs/research/insect-literal-alternates-prefilter-refresh-20260613.json" &&
  file?.exists === true)) {
  failures.push("decision research basis lacks literal alternates Insect refresh");
}
if (!decision.researchBasis?.files?.some((file) =>
  normalized(String(file?.path ?? "")) === ".docs/research/insect-teddy-attribution-refresh-20260613.json" &&
  file?.exists === true)) {
  failures.push("decision research basis lacks Teddy attribution Insect refresh");
}
if (!decision.researchBasis?.files?.some((file) =>
  normalized(String(file?.path ?? "")) === ".docs/research/insect-packed-teddy-shufti-refresh-20260613.json" &&
  file?.exists === true)) {
  failures.push("decision research basis lacks packed Teddy/Shufti Insect refresh");
}
if (!Array.isArray(decision.candidateMoves) ||
    !decision.candidateMoves.some((move) => move?.id === "full_scan_route_selection_or_parser_hoist" && move?.status === "rejected_unless_volume_changes")) {
  failures.push("decision does not reject route/parser-hoist work when full-scan volume is stable");
}
if (!Array.isArray(decision.candidateMoves) ||
    !decision.candidateMoves.some((move) => move?.id === "casefold_or_alpha_fastpath" && move?.status === "rejected")) {
  failures.push("decision does not reject casefold OR alpha fastpath after widened branch regression");
}
if (!Array.isArray(decision.candidateMoves) ||
    !decision.candidateMoves.some((move) => move?.id === "teddy_plan_pointer_pass" && move?.status === "rejected")) {
  failures.push("decision does not reject Teddy plan pointer pass after focused whole-engine score failure");
}
if (!Array.isArray(decision.candidateMoves) ||
    !decision.candidateMoves.some((move) => move?.id === "per_shard_literal_alternates_counter_hoist" && move?.status === "rejected")) {
  failures.push("decision does not reject per-shard literal alternates counter hoist after repeat focused regression");
}
if (!Array.isArray(decision.candidateMoves) ||
    !decision.candidateMoves.some((move) => move?.id === "folded_trigram_admission_for_casefold_alternates" && move?.status === "rejected")) {
  failures.push("decision does not reject folded trigram admission after predecessor-speed regression");
}

const report = {
  runId: `teddy-kernel-contract-${timestampSlug()}`,
  timestamp: new Date().toISOString(),
  status: failures.length === 0 ? "ok" : "failed",
  contract: path.relative(ROOT, contractPath),
  decision: {
    path: path.relative(ROOT, decisionPath),
    runId: decision.runId ?? null,
    evaluatedHistoricalRunId: decision.evaluatedHistoricalRunId ?? null,
  currentIxSha256: decision.currentIxSha256 ?? null,
  currentIxExecutableSha256: decision.currentIxExecutableSha256 ?? null,
    evidenceFresh: decision.evidenceFresh === true,
    promotionAllowed: decision.promotionAllowed === true,
    speedProofPointers: decision.speedProofPointers ?? null,
    finalizationGate: decision.finalizationGate ?? null,
    scorecard: {
      testedOneAtATime: decision.scorecard?.testedOneAtATime === true,
      previousBuildRounds: decision.scorecard?.previousBuildRounds ?? null,
      netPositiveRounds: decision.scorecard?.netPositiveRounds ?? null,
      netPositive: decision.scorecard?.netPositive === true,
    },
    summary: decision.summary ?? null,
    leakSummary: decision.leakSummary ?? null,
    preservationPolicy: decision.preservationPolicy ?? null,
    evidenceQuality: decision.evidenceQuality ?? null,
    nextAllowedMove: decision.nextAllowedMove ?? null,
    nextEngineeringMove: decision.nextEngineeringMove ?? null,
    proofCommands: decision.proofCommands ?? null,
    rejectedIds: [...decisionRejectedIds],
  },
  requiredSources,
  rejectedShapes,
  requiredProofCommands,
  requiredDecisionProofCommands,
  failures,
};

mkdirSync(path.dirname(outPath), { recursive: true });
writeFileSync(outPath, `${JSON.stringify(report, null, 2)}\n`, "utf8");
mkdirSync(REPORT_DIR, { recursive: true });
writeFileSync(path.join(REPORT_DIR, "latest-teddy-kernel-contract.json"), `${JSON.stringify(report, null, 2)}\n`, "utf8");

if (!quiet) console.log(JSON.stringify(report, null, 2));
process.exit(report.status === "ok" ? 0 : 1);
