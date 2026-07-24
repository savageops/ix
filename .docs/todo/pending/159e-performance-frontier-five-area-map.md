---
id: 159e-performance-frontier-five-area-map
parent: 159-performance-frontier-five-area-map
type: execution-unit
protocol_version: "3.0"
category: documentation
phase: e
status: pending
patch_scope: "Map persistent warm-index admission and lifecycle promotion gates across catalog, generations, postings, freshness, quotas, cleanup, and cold fallback without enabling warm indexing."
blast_radius: low
blast_radius_justification: "This unit adds only a planning record and cannot publish, delete, or consume index generations."
idempotency_contract: idempotent
idempotency_notes: "The lifecycle map is deterministic and has no runtime side effects."
acceptance: "The record traces warm query input through candidate planning and exact verification, names every freshness/quota/publication/GC/recovery gate, and defines the smallest evidence set required before `postings_index` can be promoted from `not_wired` or equivalent."
exit_criterion: "A later warm-index implementation chain has explicit legal activation and fallback states and cannot promote on latency alone."
validation: "git diff --check"
expected_exit_code: 0
expected_output_pattern: ""
evidence: "PLACEHOLDER — replace with exact captured stdout at completion."
conflict_surface: "152-scan-open-residual-regain; 153-search-frontier-zoom-out; 155-discovery-traversal-attribution"
invariants:
  - "I1: Warm candidates are exact-admission hints only; verifier remains authoritative."
  - "I2: Match, route, file-count, byte, and output parity remain the promotion floor."
  - "I3: Resource profile, platform, binary identity, cache state, and process hygiene are recorded."
  - "I4: One canonical owner exists for catalog, generation, postings, freshness, and cleanup."
  - "I5: Stale, malformed, wrong-root, discontinuous, over-quota, or unsupported state falls back cold."
source_message_anchor: "U6, U7"
source_message_excerpt: >-
  "5. 🟢 Persistent warm index (Tier 6 — 10x+ on repeat queries)";
  "be very careful that we don't create false negatives"
source_message_proof_obligation: "Map warm indexing as a lifecycle capability with exact verification and cold fallback, not as an unproven speed switch."
entry_state: "159d is archived with candidate-universe, admission, and byte-shard route boundaries explicit."
rollback_surface: "Delete only this planning unit; do not alter index state, generation files, or warm query behavior."
dependencies: "159d-performance-frontier-five-area-map"
next_todo: /todo/pending/159f-performance-frontier-five-area-map.md
continuation: "On completion: capture evidence, set status done, move this file to /todo/changelog/, and continue immediately to 159f."
blocked_reason: ""
unblock_action: ""
resumption_point: ""
---
# 159e Persistent Warm-Index Promotion Map

## Execute Now
Map persistent warm-index query, lifecycle, freshness, resource, and cold-fallback gates from the existing owners and architecture evidence.

## Slice Focus Rule
Own only persistent index capability truth; do not publish generations, change compaction, wire new postings, or broaden indexed evidence while this unit is live.

## Why This Execution Unit Exists
Persistent warm indexing is the largest theoretical speed opportunity and the largest correctness/lifecycle surface. IX already contains catalog, generation, postings, delta, USN, state-directory, and indexd code, but the architecture record explicitly keeps activation gated while bounded lifecycle and freshness proof is incomplete. This unit maps the legal promotion boundary so an implementation chain cannot turn existing machinery or a fast warm report into a supported capability.

## Better-Than-Before Delta
Before this slice, “postings index: not_wired” and active publication code can be read as contradictory capability claims. After it, the plan has one state model linking generation identity, candidate selection, exact verification, policy parity, cleanup, and cold fallback, with promotion blocked until each state is proven.

## Slice Domain Standard

| Domain Standard | Local Evidence | Implementation Consequence | Anti-Assumption Guard |
|---|---|---|---|
| Warm state must be bounded and recoverable. | `.docs/research/2026-07-16-bounded-warm-index-architecture.md`; `indexd.zig`; `generation.zig`. | Require disk cap, free-space floor, GC, startup cleanup, reader pins, and crash recovery. | Publication code alone is not lifecycle proof. |
| Indexed candidates are hints, not truth. | `postings.zig`; warm query path; competitor map for Zoekt/Livegrep. | Every candidate is verified against current bytes; stale/malformed state falls cold. | Never manufacture hits from postings. |
| Freshness is platform-native and explicit. | `usn.zig`, `delta_overlay.zig`, `warm-index-windows-freshness.md`. | Require root/epoch/cursor continuity and native unsupported boundaries. | A directory watcher alone is not durable freshness. |

## Domain-Knowledge Research Check

| Knowledge Gap | Research / Probe To Run | Source Priority | Decision It Controls | Closure Evidence |
|---|---|---|---|---|
| Segment/generation lifecycle | Read catalog/generation/indexd plus pinned Zoekt/Tantivy/Lucene/Quickwit/SQLite sources. | Primary source-bearing refs and local architecture note. | Bounded state machine and cleanup owner. | Lifecycle state table. |
| Freshness and policy parity | Read `usn.zig`, `delta_overlay.zig`, warm freshness doc, discovery/ignore map from 159c. | Local source and platform docs. | Legal warm/cold transitions. | Freshness/fallback matrix. |
| Repeat-query value | Use current reports only after identity and parity controls are available. | Local benchmark artifacts. | Promotion threshold and resource-profile value. | Promotion receipt requirements. |

## Technical Execution Blueprint

| Area | Required Detail |
|---|---|
| Repository anchors | `src/core/catalog.zig`; `generation.zig`; `postings.zig`; `delta_overlay.zig`; `usn.zig`; `state_dir.zig`; `indexd.zig`; `search.zig:prepareWarmIndexFrontier`; `.docs/architecture/warm-index-windows-freshness.md`; bounded warm-index research. |
| Existing-owner decision | Extend catalog/generation/postings/indexd/freshness owners; do not add a separate warm daemon, cache, or query planner. |
| Domain owner / canonical standard | Generation/catalog own identity and publication; postings owns candidate planning; search owns verification/fallback; indexd owns lifecycle side effects. |
| Intended design | `query/root → generation read/validate → postings candidate intersection → freshness/policy check → exact file verification → result`; any invalid state → cold discovery/scan. |
| Integration path | Explicit operator/index enrollment, installed CLI warm search, mutation/restart probes, JSON status/telemetry, and cleanup evidence. |
| Failure modes to prevent | Stale hit, ignored-file inclusion, wrong root, epoch discontinuity, partial generation, unbounded disk, reader-pinned deletion, silent cold/warm mismatch, and resource-cap violation. |
| Alternatives rejected | Warm activation on latency alone; full rebuild per mutation; watcher-only freshness; broad new index schema before lifecycle closure; daemon auto-spawn from search. |
| Proof hooks | Generation manifest validation, crash residue sweep, quota/free-space refusal, mutation convergence, stale/malformed/wrong-root fallback, ignore parity, exact cold/warm result parity, installed path, and soak. |

## Codebase Research And Execution Addendum

**Implementation map:** Inspect `prepareWarmIndexFrontier`, catalog fingerprints, generation manifest/publication/retention/GC, postings query planning, delta overlay continuity, USN provider, indexd status/cleanup, and state-dir layout.

**Existing-owner directive:** Repair the current lifecycle and freshness owners before adding evidence or query features; one writer and one cleanup owner remain mandatory.

**Directive:** Define warm activation as explicit state transitions: absent → building → published → fresh/usable → stale/uncertain → cold fallback → retired/GC, with reader pins and quota gates visible.

**Gold-standard guardrail:** Never expose a fast warm result if the generation is stale, malformed, wrong-root, policy-incompatible, or unverifiable; cold fallback is the supported safety path.

**Knowledge gathering route:** Use local architecture/research and pinned Zoekt/Tantivy/Lucene/Quickwit/SQLite sources; use current platform docs only for unresolved Windows/Linux/macOS freshness behavior.

**Runtime visualization:** `operator enrollment/mutation → indexd lifecycle owner → manifest/segments → freshness/ignore validation → postings candidates → exact verifier → result/status; invalid state → cold discovery`.

**Proof expansion:** Future implementation must run lifecycle, crash, quota, mutation, restart, stale, malformed, wrong-root, ignore-policy, parity, resource-cap, installed, and soak gates.

## Embedded Framing
A warm index earns promotion by surviving mutation, restart, quota, freshness, and cold-fallback tests; repeat-query latency is the final value proof, not the activation proof.

## Slice Research Directive

| Research Topic | Why It Matters To This Slice | Insect Mode | Source Priority | Closure Evidence |
|---|---|---|---|---|
| Bounded index lifecycle | Prevent recurrence of the documented generation/disk leak. | `.refs/` harvest; bounded `engine --query` if current operator evidence is missing. | Zoekt, Tantivy, Quickwit, Lucene, SQLite, local warm architecture. | Lifecycle/recovery state table. |
| Native freshness | Preserve Windows/Linux/macOS boundaries. | Local source plus primary platform docs. | `usn.zig`, freshness architecture, Microsoft/Linux/macOS docs. | Platform support matrix. |

## Original User Message Proof

| Source Anchor | Verbatim Original Snippet | Slice Proof Obligation | Evidence Capture |
|---|---|---|---|
| U6 | "5. 🟢 Persistent warm index (Tier 6 — 10x+ on repeat queries)" | Map the value lane and all activation blockers. | Promotion gate and receipt checklist. |
| U7 | "be very careful that we don't create false negatives" | Require exact verification and cold fallback for every candidate set. | I1/I5 and adversarial lifecycle matrix. |

## Entry State

- `159d` is archived with byte-shard route and candidate-universe boundaries.
- Parent 159 records current warm owners and documented activation boundary.

## Patch Surface

**Modifies:** None.

**Adds:** This planning unit only.

**Deletes:** None.

**Must not touch:** `src/core/catalog.zig`, `generation.zig`, `postings.zig`, `indexd.zig`, `usn.zig`, `delta_overlay.zig`, `search.zig`, generation files, state directories, `.docs/log.txt`, and `.docs/changelog.txt`.

## Detailed Requirements

- R1: Enumerate generation identity, root/epoch, freshness cursor, policy identity, and reader-pin fields.
- R2: Define legal lifecycle states and fail-closed transitions for absent, stale, malformed, discontinuous, quota-blocked, and unsupported state.
- R3: Separate candidate planning from exact verifier truth and result projection.
- R4: Require mutation, restart, crash residue, GC, free-space, and installed-path proof before promotion.
- R5: Preserve intentional resource caps and report per-thread/whole-engine value separately.

## Invariants This Unit Must Preserve

- I1, I2, I3, I4, I5 above.

## Validation Plan

| Step | Command | Expected Exit Code | Expected Output Pattern | Idempotent |
|---|---|---:|---|---|
| 1 | `git diff --check` | 0 | empty stdout | yes |

**Evidence to capture:** Plan diff check plus lifecycle owner/source map; no warm capability is claimed here.

## Exit State (Handoff Contract)

- The terminal review can judge whether the five-area map preserves capability truth and lifecycle safety.
- Any later warm implementation starts with lifecycle/freshness gates, not postings-only wiring.

## Rollback Procedure

1. Delete only this planning unit.
2. Leave all index files, generations, and runtime state untouched.

## Next todo
`/todo/pending/159f-performance-frontier-five-area-map.md`

## Completion
- [ ] Pre-flight passed.
- [ ] Documentation-only exemption recorded.
- [ ] Validation executed and evidence captured.
- [ ] Move verified.
- [ ] Continue to 159f.
