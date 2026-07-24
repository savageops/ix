---
id: 159b-performance-frontier-five-area-map
parent: 159-performance-frontier-five-area-map
type: execution-unit
protocol_version: "3.0"
category: documentation
phase: b
status: pending
patch_scope: "Map the runtime admission call path and threshold economics for whole-file and rolling-trigram admission without changing the threshold or scan behavior."
blast_radius: low
blast_radius_justification: "This unit adds only an evidence-bearing planning record; no runtime code or benchmark owner is mutated."
idempotency_contract: idempotent
idempotency_notes: "The map is deterministic and has no external or persistent side effect."
acceptance: "The record identifies every admission call site, gate predicate, counter increment, verifier handoff, threshold, and false-negative test required to decide whether admission is wired and whether the 64 KiB policy should change."
exit_criterion: "A future implementer can add the smallest diagnostic or policy change without guessing whether the admission program is compiled, reached, counted, or verified."
validation: "git diff --check"
expected_exit_code: 0
expected_output_pattern: ""
evidence: "PLACEHOLDER — replace with exact captured stdout at completion."
conflict_surface: "152-scan-open-residual-regain; 152r-retainable-scanwork-teddy-repair; 153-search-frontier-zoom-out"
invariants:
  - "I1: Admission is fail-closed and verifier-backed; no false negatives."
  - "I2: Match, route, file-count, byte, and output parity remain the promotion floor."
  - "I3: Resource profile, platform, binary identity, cache state, and process hygiene are recorded."
  - "I4: One canonical owner exists for admission and benchmark interpretation."
source_message_anchor: "U2, U3, U7"
source_message_excerpt: >-
  "1. 🔴 Fix trigram/whole-file admission wiring gap (3-4x potential)";
  "2. 🟡 Lower trigram prune threshold for mid-size files (1.5x on top of #1)";
  "be very careful that we don't create false negatives"
source_message_proof_obligation: "Convert the two admission opportunities into one call-path and policy decision surface, proving what must be instrumented before any threshold or wiring mutation."
entry_state: "159a is archived with the interpretation lock, and parent 159 identifies `search_admission.zig`/`trigram.zig`/`search.zig` as canonical admission owners."
rollback_surface: "Delete only this planning unit; do not modify admission code or benchmark scripts."
dependencies: "159a-performance-frontier-five-area-map"
next_todo: /todo/pending/159c-performance-frontier-five-area-map.md
continuation: "On completion: capture evidence, set status done, move this file to /todo/changelog/, and continue immediately to 159c."
blocked_reason: ""
unblock_action: ""
resumption_point: ""
---
# 159b Admission Wiring and Threshold Economics Map

## Execute Now
Map the compiled admission program, runtime gate predicates, telemetry semantics, and threshold decision matrix from source and existing proof artifacts.

## Slice Focus Rule
Own only admission policy and call-path truth; do not edit `TRIGRAM_MIN_PRUNE_BYTES`, add SIMD code, repair discovery, activate byte sharding, or promote postings while this unit is live.

## Why This Execution Unit Exists
The observed `eligible: true` plus zero candidate counters is a compound signal, not a root cause. `TrigramAdmissionProgram.compile` can be valid while the runtime route uses a different `single_chunk`, request mode, or counter interpretation. This unit separates program construction, gate reachability, miss result, early return, and verifier work before anyone claims a 3–4x opportunity.

## Better-Than-Before Delta
Before this slice, admission wiring and threshold economics are mixed into a ranked recommendation. After it, the map has one explicit runtime sequence and one falsifiable cost/yield matrix, making a blind threshold edit or telemetry-only “fix” structurally impossible.

## Slice Domain Standard

| Domain Standard | Local Evidence | Implementation Consequence | Anti-Assumption Guard |
|---|---|---|---|
| Evidence admission must be a proof of impossibility. | `src/core/search_admission.zig`; `src/core/trigram.zig`; `search.zig` verifier routes. | Instrument booleans and returns, never bypass verification. | Do not use probabilistic sketches or hash collisions as rejection proof. |
| SIMD policy is compile-time selected. | `AGENTS.md`; `src/core/sz.zig`; `.refs/stringzilla`. | Any future fast path must preserve compile-time backend selection and scalar fallback. | No `cpuid` or runtime dispatch. |
| Cost policy is workload-specific. | `search_admission.zig` prior tests; `.docs/todo/changelog/129-*`; competitor map. | Measure by size, query shape, case mode, and rejection yield. | Do not lower 64 KiB globally from Linux telemetry alone. |

## Domain-Knowledge Research Check

| Knowledge Gap | Research / Probe To Run | Source Priority | Decision It Controls | Closure Evidence |
|---|---|---|---|---|
| Whole-file call-path reachability | Inspect `search.zig` mmap, parallel buffered, serial buffered, and mono dispatch around `scanOpenFileIntoShardImpl`. | Local source/tests/runtime probe. | Diagnostic counters and ownership. | Call-path table in this unit. |
| Admission algorithm alternatives | Read `.refs/ripgrep`, `.refs/hyperscan`, `.refs/vectorscan`, `.refs/aho-corasick`, `.refs/stringzilla`; compare first-byte, Teddy/Shufti, Shift-Or, trigram behavior. | Primary source-bearing refs. | Retained/rejected primitive for any later implementation chain. | Research matrix in 159b artifact. |

## Technical Execution Blueprint

| Area | Required Detail |
|---|---|
| Repository anchors | `src/core/search.zig` admission blocks around mmap and buffered scan paths; `src/core/search_admission.zig` compile/fileAdmissionMiss/mayMatch; `src/core/trigram.zig` eligibility; `src/cli/output.zig` telemetry projection. |
| Existing-owner decision | Keep admission construction in `search_admission.zig` and runtime application in `search.zig`; do not add a new admission service. |
| Domain owner / canonical standard | `TrigramAdmissionProgram` is evidence authority; existing verifier remains match authority. |
| Intended design | `ExpressionPlan → trigram.admit → compile → fileAdmissionEnabled → shouldAttemptWholeFileAdmission → fileAdmissionMiss → recordEvidencePruned/verified → verifier`; rolling trigram follows only where size/single-chunk policy qualifies. |
| Integration path | CLI `search ... --json --stats` must expose candidate/pruned/verified semantics consistent with actual early returns. |
| Failure modes to prevent | Missed call, pre-admission counter inflation, double-counted admission, false prune, casefold mismatch, and scalar admission cost exceeding verifier savings. |
| Alternatives rejected | Blind threshold lowering; replacing exact evidence with a sketch; moving admission into byte-shard code; measuring only `files_scanned`. |
| Proof hooks | Tiny three-file corpus, adversarial literals/UTF-8/case modes, Linux corpus, per-stage counters, structured match parity. |

## Codebase Research And Execution Addendum

**Implementation map:** Before any later edit, inspect `TrigramAdmissionProgram.compile`, `fileAdmissionEnabled`, `fileAdmissionMiss`, `mayMatch`, `shouldAttemptWholeFileAdmission`, `shouldAttemptTrigramPrune`, and all three scan leaves.

**Existing-owner directive:** Add diagnostics beside the existing admission owner or correct the telemetry owner; never create a parallel prefilter.

**Directive:** Prove `program enabled → gate reached → miss true/false → early-return → verifier` for both matching and nonmatching files, then construct the threshold matrix.

**Gold-standard guardrail:** Do not count a file as a candidate merely because it was opened, and do not count a pruned file after verifier work has already begun.

**Knowledge gathering route:** Read pinned ripgrep/Hyperscan/Vectorscan/Aho-Corasick/StringZilla sources and local changelog 129/131/132; use `engine --query` only for an unanswered current-source question.

**Runtime visualization:** `ExpressionPlan → admission compile → scan leaf → whole-file gate → miss? prune : verifier → exact hit/output`.

**Proof expansion:** Future runtime slice must run the focused admission suite, adversarial parity corpus, ReleaseFast build, and structured current/installed/predecessor benchmark with counters.

## Embedded Framing
First establish whether IX reaches the cheap proof of impossibility; only then decide whether a smaller-file policy or SIMD kernel earns its cost.

## Slice Research Directive

| Research Topic | Why It Matters To This Slice | Insect Mode | Source Priority | Closure Evidence |
|---|---|---|---|---|
| Trigram and literal admission implementation patterns | Distinguish exact proof filters from heuristic candidate ranking. | `.refs/` harvest; bounded `engine --query` if needed. | Hyperscan, Vectorscan, ripgrep, Aho-Corasick, StringZilla. | Retained/rejected mechanism table and call-path map. |
| Prior local threshold decisions | Prevent repeating a removed 2048-bit sketch regression. | Local `.docs/todo/changelog/129-*` and reports. | Local history and benchmark receipts. | Threshold policy matrix. |

## Original User Message Proof

| Source Anchor | Verbatim Original Snippet | Slice Proof Obligation | Evidence Capture |
|---|---|---|---|
| U2 | "1. 🔴 Fix trigram/whole-file admission wiring gap (3-4x potential)" | Map the exact reachability and return path before proposing repair. | Call-path and counter table. |
| U3 | "2. 🟡 Lower trigram prune threshold for mid-size files (1.5x on top of #1)" | Require measured cost/yield evidence before a threshold change. | Size/pattern/case/yield matrix. |
| U7 | "be very careful that we don't create false negatives" | Keep exact verifier authority and adversarial parity as gates. | I1 plus future proof hooks. |

## Entry State

- `159a` is archived with the five-area boundary and no-false-negative invariant.
- The parent names `search_admission.zig` and `search.zig` as canonical owners.

## Patch Surface

**Modifies:** None.

**Adds:** This planning unit only.

**Deletes:** None.

**Must not touch:** `src/core/search.zig`, `src/core/search_admission.zig`, `src/core/trigram.zig`, benchmark scripts, `.docs/log.txt`, and `.docs/changelog.txt`.

## Detailed Requirements

- R1: Enumerate both whole-file and rolling-trigram gates for mmap, parallel buffered, and serial buffered paths.
- R2: Separate compile eligibility, group count/mode, gate reachability, miss result, early return, candidate verification, and telemetry increment.
- R3: Require threshold experiments across file-size buckets, literal lengths, mandatory trigram counts, case mode, and rejection yield.
- R4: Require a scalar-baseline comparison and a compile-time SIMD alternative comparison before selecting a new primitive.
- R5: Require exact match, route, files, bytes, binary, and UTF-8 parity for every candidate.

## Invariants This Unit Must Preserve

- I1–I4 above.

## Validation Plan

| Step | Command | Expected Exit Code | Expected Output Pattern | Idempotent |
|---|---|---:|---|---|
| 1 | `git diff --check` | 0 | empty stdout | yes |

**Evidence to capture:** The plan diff check and the cited owner/source map; no runtime claim is made by this documentation unit.

## Exit State (Handoff Contract)

- The next unit can reason about ignore policy without confusing candidate admission with directory admission.
- Any future admission implementation must begin with runtime call-path proof, not `TRIGRAM_MIN_PRUNE_BYTES` editing.

## Rollback Procedure

1. Remove only this planning unit.
2. Preserve 159a and all runtime source unchanged.

## Next todo
`/todo/pending/159c-performance-frontier-five-area-map.md`

## Completion
- [ ] Pre-flight passed.
- [ ] Documentation-only exemption recorded.
- [ ] Validation executed and evidence captured.
- [ ] Status set to `done`.
- [ ] Move verified.
- [ ] Continue to 159c.
