---
id: 159d-performance-frontier-five-area-map
parent: 159-performance-frontier-five-area-map
type: execution-unit
protocol_version: "3.0"
category: documentation
phase: d
status: pending
patch_scope: "Map byte-shard activation, line-range ownership, route ordering, merge semantics, and the stats-only boundary without enabling new shard routes."
blast_radius: low
blast_radius_justification: "This unit creates no executable change and cannot alter byte ownership or output."
idempotency_contract: idempotent
idempotency_notes: "The map has no side effects and can be regenerated deterministically."
acceptance: "The record names all current byte-shard selectors, thresholds, bailout conditions, pre/post-admission ordering, worker/resource constraints, merge proof, and the exact additional evidence required before any activation expansion."
exit_criterion: "A later implementation chain can change one shard owner or selector with a bounded parity test and cannot mistake `enabled=false` telemetry for permission to broaden scope."
validation: "git diff --check"
expected_exit_code: 0
expected_output_pattern: ""
evidence: "PLACEHOLDER — replace with exact captured stdout at completion."
conflict_surface: "152-scan-open-residual-regain; 153-search-frontier-zoom-out; 155-discovery-traversal-attribution"
invariants:
  - "I1: Admission and verifier semantics remain exact."
  - "I2: Match, route, file-count, byte, and output parity remain the promotion floor."
  - "I3: Resource profile and process hygiene are recorded."
  - "I4: Byte-shard execution has one canonical owner."
  - "I6: This chain does not mutate runtime behavior."
source_message_anchor: "U5, U7"
source_message_excerpt: >-
  "4. 🟢 Byte-shard kernel activation (2x on multi-thread)";
  "be very careful that we don't create false negatives"
source_message_proof_obligation: "Map the existing constrained kernel and its proof obligations before any selector or route expansion."
entry_state: "159c is archived with candidate-universe and ignore parity boundaries defined."
rollback_surface: "Delete only this planning unit; do not modify `byte_shard.zig` or `search.zig`."
dependencies: "159c-performance-frontier-five-area-map"
next_todo: /todo/pending/159e-performance-frontier-five-area-map.md
continuation: "On completion: capture evidence, set status done, move this file to /todo/changelog/, and continue immediately to 159e."
blocked_reason: ""
unblock_action: ""
resumption_point: ""
---
# 159d Byte-Shard Activation Map

## Execute Now
Map the existing byte-shard selector, range ownership, admission ordering, resource gates, and stats-only contract without broadening activation.

## Slice Focus Rule
Own only byte-range counting and merge semantics; do not change admission thresholds, discovery policy, output routes, or warm-index state while this unit is live.

## Why This Execution Unit Exists
The byte-shard kernel is already implemented, but the observed telemetry says it is not active for the measured query. `tryByteShardFastCount` is deliberately stats-only and strategy-gated. A planning map must therefore distinguish an ineligible route from a broken route and prove that line ownership, overlap, and merge behavior remain exact before any activation claim.

## Better-Than-Before Delta
Before this slice, “activate byte-shard” is a broad 2x promise. After it, activation is a finite decision table over strategy, size, ranges, case mode, admission order, stats/output mode, and resource cap, with a separate proof gate for any match-output expansion.

## Slice Domain Standard

| Domain Standard | Local Evidence | Implementation Consequence | Anti-Assumption Guard |
|---|---|---|---|
| Every byte belongs to one complete line owner or a documented overlap. | `src/core/byte_shard.zig`; `search.zig` range builder/merge. | Test boundary lines, CRLF, long lines, UTF-8, and overlap. | Do not split arbitrary byte ranges and assume line semantics survive. |
| Fast count is not hit-output proof. | `tryByteShardFastCount` gates on `request.stats_only`. | Keep output route separate until coordinates/order/truncation prove parity. | Do not remove the stats-only guard to raise telemetry. |
| Thread caps are a deliberate constraint. | `resource_profile.zig`; project memory. | Measure per-thread throughput and cap-sensitive activation. | Do not enable a route only because uncapped wall time improves. |

## Domain-Knowledge Research Check

| Knowledge Gap | Research / Probe To Run | Source Priority | Decision It Controls | Closure Evidence |
|---|---|---|---|---|
| Range/merge patterns | Read pinned ripgrep walker/search and TigerBeetle merge/range code; inspect local tests. | Source-bearing refs. | Range construction and merge shape. | Range/merge proof table. |
| Strategy and ordering | Trace `tryByteShardFastCount`, `streamingLiteralNeedles`, literal admission, and stats route. | Local source/runtime. | Selector matrix. | Exact route map. |

## Technical Execution Blueprint

| Area | Required Detail |
|---|---|
| Repository anchors | `src/core/byte_shard.zig:6-184`; `src/core/search.zig:3642-3731,3875-4027,4085-4205`; stats fields in `src/cli/output.zig`. |
| Existing-owner decision | Keep range planning in `byte_shard.zig` and orchestration/merge in `search.zig`; no new worker pool. |
| Domain owner / canonical standard | `ByteShardPlan` owns eligibility/ranges; scan owner owns verifier and report merge. |
| Intended design | `file bytes → strategy selector → plan ranges → workers count owned lines → join/merge → telemetry`; admission order is explicit per strategy. |
| Integration path | `search --stats-only` through CLI JSON; match-output remains normal verifier path. |
| Failure modes to prevent | Duplicate boundary count, missed line, counter race, resource oversubscription, post-admission double work, and output semantics loss. |
| Alternatives rejected | General work-stealing pool, match-output activation without proof, byte-shard before stable candidate universe, runtime SIMD dispatch. |
| Proof hooks | Range plan tests, adversarial files, one/two/many thread parity, stats-only corpus, resource telemetry, and predecessor gates. |

## Codebase Research And Execution Addendum

**Implementation map:** Inspect `ByteShardPlan`, strategy enum, range builder, `tryByteShardFastCount`, worker join/merge, `request.stats_only` gate, and telemetry projection.

**Existing-owner directive:** Keep all selector and range logic within current byte-shard/search owners; do not create a second shard scheduler.

**Directive:** Define activation as a route contract with preconditions and proof, not a boolean flag change.

**Gold-standard guardrail:** Never use stats-only parity to claim match-output correctness; never let a shard bypass the canonical verifier when output is requested.

**Knowledge gathering route:** Read pinned ripgrep/TigerBeetle/simdjson patterns and local `145b` evidence; use current benchmark probes only after admission/discovery route identity is frozen.

**Runtime visualization:** `candidate file → strategy selector → aligned ranges → thread-local counts → join/merge → stats JSON`; output mode bypasses this route unless separately proven.

**Proof expansion:** Future implementation must run range adversaries, route/match/file/byte parity, cap-sensitive benchmarks, and process cleanup checks.

## Embedded Framing
A shard is useful only when it owns a complete semantic unit, merges without duplication, and costs less than the unsharded verifier under the declared resource profile.

## Slice Research Directive

| Research Topic | Why It Matters To This Slice | Insect Mode | Source Priority | Closure Evidence |
|---|---|---|---|---|
| SIMD range and line ownership | Prevent boundary false negatives/double counts. | `.refs/` harvest; bounded `engine --query` if needed. | ripgrep, simdjson, TigerBeetle. | Range/merge contract. |
| Local byte-shard results | Avoid retrying rejected shapes. | Local reports and changelog 145b. | Current source and reports. | Selector/rejection table. |

## Original User Message Proof

| Source Anchor | Verbatim Original Snippet | Slice Proof Obligation | Evidence Capture |
|---|---|---|---|
| U5 | "4. 🟢 Byte-shard kernel activation (2x on multi-thread)" | Identify exact currently eligible route and activation gap. | Selector matrix and route proof. |
| U7 | "be very careful that we don't create false negatives" | Preserve line ownership and verifier boundaries. | I1/I2 and adversarial test requirements. |

## Entry State

- `159c` is archived with a stable candidate-universe contract.
- Existing byte-shard owner and stats-only guard are identified in parent 159.

## Patch Surface

**Modifies:** None.

**Adds:** This planning unit only.

**Deletes:** None.

**Must not touch:** `src/core/byte_shard.zig`, `src/core/search.zig`, `src/cli/output.zig`, `.docs/log.txt`, and `.docs/changelog.txt`.

## Detailed Requirements

- R1: List every strategy, file/range-size threshold, case-mode condition, and stats/output precondition.
- R2: Trace range boundary construction and merge ownership, including overlap/bailout behavior.
- R3: Record admission-before/after ordering for each eligible route.
- R4: Define the proof required before match-output activation or threshold changes.
- R5: Include capped and uncapped diagnostic interpretation without changing the configured cap.

## Invariants This Unit Must Preserve

- I1, I2, I3, I4, I6 above.

## Validation Plan

| Step | Command | Expected Exit Code | Expected Output Pattern | Idempotent |
|---|---|---:|---|---|
| 1 | `git diff --check` | 0 | empty stdout | yes |

**Evidence to capture:** Plan diff check and cited selector/range owner map.

## Exit State (Handoff Contract)

- The next unit can map warm postings against a stable candidate and route contract.
- Any future shard work remains stats-only unless a new proof chain establishes output parity.

## Rollback Procedure

1. Delete only this planning unit.
2. Preserve current shard implementation and prior receipts.

## Next todo
`/todo/pending/159e-performance-frontier-five-area-map.md`

## Completion
- [ ] Pre-flight passed.
- [ ] Documentation-only exemption recorded.
- [ ] Validation executed and evidence captured.
- [ ] Move verified.
- [ ] Continue to 159e.
