---
id: 159a-performance-frontier-five-area-map
parent: 159-performance-frontier-five-area-map
type: execution-unit
protocol_version: "3.0"
category: documentation
phase: a
status: pending
patch_scope: "Lock the five-area interpretation, queue boundary, benchmark contract, and no-false-negative invariants without changing executable artifacts."
blast_radius: low
blast_radius_justification: "This unit adds only a planning record; it cannot alter runtime behavior or persisted index state."
idempotency_contract: idempotent
idempotency_notes: "Rewriting the same baseline record produces the same scope lock and no executable side effects."
acceptance: "The baseline record names all five areas, their canonical owners, existing queue overlaps, measurement identity fields, and explicit false-negative and unsupported-runtime boundaries."
exit_criterion: "The unit contains a complete interpretation lock and its next unit can be executed without consulting conversation history."
validation: "git diff --check"
expected_exit_code: 0
expected_output_pattern: ""
evidence: "PLACEHOLDER — replace with exact captured stdout at completion."
conflict_surface: "152-scan-open-residual-regain; 153-search-frontier-zoom-out; 154-scan-input-policy-diagnostic; 155-discovery-traversal-attribution"
invariants:
  - "I1: Admission is fail-closed and verifier-backed; no false negatives."
  - "I2: Match, route, file-count, byte, and output parity remain the promotion floor."
  - "I3: Resource profile, platform, binary identity, cache state, and process hygiene are recorded for every performance claim."
  - "I4: One canonical owner exists for each performance concern."
  - "I6: This chain does not mutate runtime behavior or weaken existing failing tests."
source_message_anchor: "U0, U1, U7"
source_message_excerpt: >-
  "commit and push all current progress"; "then proceed to map out these 5 areas using the planning spec skill.";
  "be very careful that we don't create false negatives"
source_message_proof_obligation: "Record that the pushed checkpoint precedes planning and freeze a five-area map whose later implementation cannot trade correctness for speed."
entry_state: "Commit ea226896 exists on origin/develop-subzero; the parent 159 file exists; current pending and changelog inventories have been inspected."
rollback_surface: "Delete only this planning file if the parent is rejected; do not revert ea226896 or any prior runtime commit."
dependencies: ""
next_todo: /todo/pending/159b-performance-frontier-five-area-map.md
continuation: "On completion: capture evidence, set status done, move this file to /todo/changelog/, and continue immediately to 159b."
blocked_reason: ""
unblock_action: ""
resumption_point: ""
---
# 159a Baseline and Contract Lock

## Execute Now
Freeze the five-area scope, queue conflicts, benchmark identity contract, and correctness boundaries in this planning record.

## Slice Focus Rule
Own only the interpretation lock; do not inspect a new mechanism deeply, mutate runtime code, reconcile historical todo contradictions in place, or begin a sibling area while this unit is live.

## Why This Execution Unit Exists
The user requested a map, but the repository already has live overlapping chains and stale completion records. This baseline prevents a planning document from becoming a second owner or silently treating exploratory telemetry as capability truth. It also converts the user's false-negative warning into an inherited acceptance condition.

## Better-Than-Before Delta
Before this slice, the five opportunities exist as a ranked prose list with mixed certainty. After it, each area has a named owner class, a proof boundary, a queue overlap disposition, and a promotion identity contract that later units must preserve.

## Slice Domain Standard

| Domain Standard | Local Evidence | Implementation Consequence | Anti-Assumption Guard |
|---|---|---|---|
| Performance claims require parity and provenance. | `AGENTS.md`; `.docs/log.md`; `tools/scripts/lib/speed-compare-utils.mjs`; `ea226896`. | Future reports must capture hashes, route, matches, files, bytes, profile, platform, and process state. | Do not use wall time alone. |
| Admission never manufactures a hit or drops a possible hit. | `src/core/search_admission.zig`; verifier paths in `src/core/search.zig`. | Candidate pruning is always fail-closed and followed by verification. | Zero counters are a hypothesis, not proof of a missing call. |
| Resource caps are deliberate. | `src/core/resource_profile.zig`; project memory topic. | Compare capped per-thread throughput and separately label uncapped diagnostics. | Do not raise caps to make a candidate look better. |

## Domain-Knowledge Research Check

| Knowledge Gap | Research / Probe To Run | Source Priority | Decision It Controls | Closure Evidence |
|---|---|---|---|---|
| Existing queue ownership | Inventory `.docs/todo/pending/` and `.docs/todo/changelog/`, inspect 152–158. | Local filesystem and logs. | Whether 159 is a new map or extension/supersession. | This unit's queue-conflict table. |
| Benchmark identity | Inspect `bench-three-way.mjs` and comparison utilities. | Local scripts and reports. | Minimum fields for later gates. | Explicit identity contract in this unit. |

## Technical Execution Blueprint

| Area | Required Detail |
|---|---|
| Repository anchors | `.docs/todo/pending/152*` through `158*`; `.docs/log.md`; `tools/scripts/bench-three-way.mjs`; `src/core/resource_profile.zig`. |
| Existing-owner decision | Keep 159 as a documentation-only map; do not create a runtime owner or supersede 152–155 by deletion. |
| Domain owner / canonical standard | `.docs/log.md` and benchmark policy own current evidence interpretation; `search.zig` and specialist modules own runtime behavior. |
| Intended design | Ordered DAG: baseline → admission → discovery → byte shard → warm index → review. |
| Integration path | Each later implementation chain must point from CLI `search.run` to owner, telemetry, and installed smoke proof. |
| Failure modes to prevent | Duplicate parent, benchmark identity drift, threshold-first tuning, warm-index false claims, and false-negative shortcuts. |
| Alternatives rejected | A single broad runtime refactor; parallel sibling parents; immediate threshold lowering; “enable everything” flags. |
| Proof hooks | Parent source coverage, queue inventory, explicit invariants, and terminal review. |

## Codebase Research And Execution Addendum

**Implementation map:** Read `src/core/search.zig`, `search_admission.zig`, `trigram.zig`, `admission.zig`, `byte_shard.zig`, `postings.zig`, `catalog.zig`, `generation.zig`, `indexd.zig`, `src/cli/output.zig`, and the comparison scripts before any later mutation.

**Existing-owner directive:** Extend the smallest existing owner; do not add a performance coordinator or benchmark registry.

**Directive:** Treat this chain as a planning index only, and make every future runtime claim enter through the canonical CLI and installed binary.

**Gold-standard guardrail:** Do not interpret a committed plan, telemetry field, or ignored report as proof that a capability is active.

**Knowledge gathering route:** Use repository-native search/inspection first, then `.refs/index.md`, `.docs/research/competitor-anatomy-map.md`, and the bounded warm-index architecture note.

**Runtime visualization:** `CLI query → ExpressionPlan → discovery/admission → scan route → verifier → stats/output → benchmark receipt`.

**Proof expansion:** Run `git diff --check`; no feature-test floor applies because this is documentation-only and explicitly records that exemption.

## Embedded Framing
The next performance move is selected by proven work avoided, not by the most visible kernel; correctness and identity are admission gates, not post-hoc commentary.

## Slice Research Directive

| Research Topic | Why It Matters To This Slice | Insect Mode | Source Priority | Closure Evidence |
|---|---|---|---|---|
| Existing IX performance queue and predecessor policy | Prevent duplicate ownership and stale evidence. | Local `.docs/`/`.refs/` inspection; `engine --query` only if local evidence is incomplete. | Local logs, reports, source. | Queue and identity locks above. |

## Original User Message Proof

| Source Anchor | Verbatim Original Snippet | Slice Proof Obligation | Evidence Capture |
|---|---|---|---|
| U0 | "commit and push all current progress" | Confirm the checkpoint is pushed before planning. | `git log` and remote status captured in session. |
| U1 | "then proceed to map out these 5 areas using the planning spec skill." | Use planning-spec structure rather than a prose suggestion. | Parent and six-unit manifest. |
| U7 | "be very careful that we don't create false negatives" | Carry fail-closed verification into every area. | I1 and later unit acceptance. |

## Entry State

- `ea226896` is pushed and the worktree was clean before this planning artifact.
- Parent 159 names the five areas and the chain DAG.

## Patch Surface

**Modifies:** None.

**Adds:** This planning unit only.

**Deletes:** None.

**Must not touch:** Runtime source, benchmark logic, existing todo history, `.docs/log.txt`, or `.changelog.txt`.

## Interpretation Locks

- “Wiring gap” means a discrepancy between compiled eligibility, gate reachability, return value, and telemetry semantics; it does not authorize a speculative runtime patch.
- “Lower threshold” means a measured policy decision after admission cost/yield data, not a constant edit.
- “.gitignore support” means parity and policy proof first because parser/discovery owners already exist.
- “Byte-shard activation” remains bounded by current stats-only route until output semantics are proven.
- “Persistent warm index” remains a promotion target gated by lifecycle, freshness, and cold fallback.

## Invariants This Unit Must Preserve

- I1, I2, I3, I4, I6 above.

## Validation Plan

| Step | Command | Expected Exit Code | Expected Output Pattern | Idempotent |
|---|---|---:|---|---|
| 1 | `git diff --check` | 0 | empty stdout | yes |

**Evidence to capture:** Exact command exit code and stdout plus the pushed checkpoint identity.

## Exit State (Handoff Contract)

- The five-area scope and all inherited invariants are frozen.
- 159b may map admission without reopening the category boundary.
- Queue overlap is recorded as a dependency/reconciliation concern, not silently resolved.

## Rollback Procedure

1. Remove only `159a-performance-frontier-five-area-map.md`.
2. Leave the pushed checkpoint and existing queue records unchanged.

## Next todo
`/todo/pending/159b-performance-frontier-five-area-map.md`

## Completion
- [ ] Pre-flight passed.
- [ ] Documentation-only 30-test exemption recorded.
- [ ] Validation executed and evidence captured.
- [ ] Status set to `done`.
- [ ] Move to `/todo/changelog/` verified.
- [ ] Continue immediately to `159b`.
