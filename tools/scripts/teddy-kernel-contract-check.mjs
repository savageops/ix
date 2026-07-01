import { existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import path from "node:path";
import { argValue, timestampSlug } from "./lib/script-helpers.mjs";

const ROOT = process.cwd();
const DEFAULT_CONTRACT = path.join(ROOT, ".docs", "research", "2026-06-13-packed-teddy-kernel-proof-contract.md");
const DEFAULT_DECISION = path.join(ROOT, "tools", "reports", "teddy-kernel-decision", "latest-teddy-kernel-decision.json");
const REPORT_DIR = path.join(ROOT, "tools", "reports", "teddy-kernel-contract");

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
if (diagnosticPointer?.freshForCurrentBinary === true) {
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
  if (!String(decision.finalizationGate?.blocker ?? "").includes("no current installed-vs-repo promotion proof")) {
    failures.push("decision finalization gate must name missing/stale installed-vs-repo promotion proof as blocker");
  }
  if (!String(decision.noRuntimePromotionReason ?? "").includes("no current installed-vs-repo promotion proof")) {
    failures.push("decision no-runtime reason must name missing installed-vs-repo promotion proof");
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
function expectedScanWorkRepairMove(split) {
  if (split?.regressingCandidateSubphase === "scanFile") return "scan_file_residual_hotspot_attribution";
  if (split?.dominantCandidateSubphase === "scanOpen") return "scan_open_path_pressure_attribution";
  return "whole_engine_leak_attribution";
}
function diagnosticAttributionOnly(quality) {
  return (quality?.comparisonFailures ?? []).includes("diagnostic_attribution_run_not_retainable_evidence");
}
function expectedScanWorkNextMove(split, quality) {
  if (diagnosticAttributionOnly(quality) && split?.dominantCandidateSubphase === "scanOpen" && split?.regressingCandidateSubphase !== "scanFile") {
    return "retainable_scan_open_runtime_probe";
  }
  return expectedScanWorkRepairMove(split);
}
const expectedNextMove = evidenceBlockedByNoise
  ? "benchmark_host_noise_control"
  : (
      teddyGainNeedsLeakRepair &&
      decision.leakSummary?.nextRepairTarget === "scanWork" &&
      ["scan_file_residual_hotspot_attribution", "scan_open_path_pressure_attribution"].includes(expectedScanWorkRepairMove(decision.leakSummary?.leakAttribution?.currentOnlyScanSplit))
        ? expectedScanWorkNextMove(decision.leakSummary?.leakAttribution?.currentOnlyScanSplit, evidenceQuality)
        : (teddyGainNeedsLeakRepair ? "whole_engine_leak_attribution" : "packed_nibble_shuffle_teddy_kernel")
    );
if (decision.nextAllowedMove?.id !== expectedNextMove) {
  failures.push(`decision next move expected ${expectedNextMove}`);
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
  const expectedRepairMove = expectedScanWorkNextMove(decision.leakSummary?.leakAttribution?.currentOnlyScanSplit, evidenceQuality);
  if (decision.preservationPolicy?.nextEngineeringMoveId !== expectedRepairMove) {
    failures.push("decision preservation policy must route engineering repair to the proved repair owner");
  }
  if (decision.nextEngineeringMove?.id !== "whole_engine_leak_attribution") {
    const split = decision.leakSummary?.leakAttribution?.currentOnlyScanSplit;
    if (decision.nextEngineeringMove?.id !== expectedScanWorkNextMove(split, evidenceQuality)) {
      failures.push("decision must expose the proved leak owner as next engineering move");
    }
  }
  if (
    decision.leakSummary?.nextRepairTarget === "scanWork" &&
    !diagnosticAttributionOnly(evidenceQuality) &&
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
        !["teddyRange", "alternateFullScan", "scanFileResidual"].includes(split.dominantCandidateScanFileComponent)
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
if (!String(decision.nextAllowedMove?.proofCommand ?? "").includes("compare-historical-speed.mjs")) {
  failures.push("decision next move lacks historical-speed proof command");
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
