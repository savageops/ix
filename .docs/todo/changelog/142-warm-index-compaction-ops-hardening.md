---
id: 142-warm-index-compaction-ops-hardening
type: parent
protocol_version: "2.1"
spec_status: approved
category: feature
status: done
epic_boundary: "Add compaction, diagnostics, adversarial tests, and operator-ready closeout for the warm-index system. This chain turns a functional index into a maintainable long-lived substrate."
subtodo_start: /todo/pending/142a-warm-index-compaction-ops-hardening.md
subtodo_final: /todo/pending/142o-warm-index-compaction-ops-hardening.md
continuation: "After each completed execution unit: record evidence, set status done, move to /todo/changelog/, continue immediately to next_todo. Never batch-archive. Never pause between units."
source_message_policy: "Every lettered unit MUST include source_message_anchor, source_message_excerpt, source_message_proof_obligation, and an Original User Message Proof section with verbatim snippets from the original user message."
---
# 142 Warm Index Compaction Ops Hardening

## Objective
Add compaction, diagnostics, adversarial tests, and operator-ready closeout for the warm-index system. This chain turns a functional index into a maintainable long-lived substrate.

## Rationale
Segmented systems need bounded growth, tombstone cleanup, reader-safe deletion, and clear diagnostics. Without compaction and adversarial gates, a warm index becomes correct only in small synthetic states.

## Scope

**In scope:**
- Segment compaction.
- Generation garbage collection.
- Diagnostics.
- Adversarial tests.
- README and changelog closeout.

**Out of scope:**
- Remote service mode.
- Cross-repository global index.
- UI or installer work.

## Source Language Anchors
- "persistent corpus-global background indexer"
- "FileCatalog -> DeltaLog -> SegmentWriter -> SearcherRefresh -> Compaction"
- "Nexus frontier -> persistent FileCatalog -> corpus-global trigram postings -> hidden __ix_indexd -> generation refresh -> USN delta apply"
- "one binary, one index format, and fail-closed epoch publication"

## Original User Message Capture

| Anchor ID | Information Piece | Verbatim Original Snippet | Required Coverage |
|-----------|-------------------|---------------------------|-------------------|
| U1 | commit checkpoint | "Make a commit." | All baseline units preserve the checkpoint boundary; implementation begins only after branch creation. |
| U2 | branch requirement | "Then fork to develop branch." | All parent chains assert execution on develop. |
| U3 | experiment authorization | "Then let's attempt this experiment. Go all out." | Implementation units authorize deep warm-index architecture work. |
| U4 | planning protocol | "Use the planning spec skill after we've forked." | All parent and lettered units follow planning-spec v2.1. |
| U5 | slice count | "To slice this entire research into at least 90 to-do slices using the planning spec skill." | Six parent chains contain 90 lettered execution slices. |
| U6 | implementation order | "Once that is established, proceed to implementation." | Unit 137a begins execution after decomposition is established. |

## Source Message Coverage

| Unit | Source Anchor(s) | Slice Proof Obligation |
|------|------------------|------------------------|
| 142a | U1, U2, U4, U5 | Baseline contract lock preserves or implements the warm-layer research program without leaving the planning-spec contract. |
| 142b | U3, U5, U6 | Compaction planner preserves or implements the warm-layer research program without leaving the planning-spec contract. |
| 142c | U3, U5, U6 | Merge writer preserves or implements the warm-layer research program without leaving the planning-spec contract. |
| 142d | U3, U5, U6 | Tombstone folding preserves or implements the warm-layer research program without leaving the planning-spec contract. |
| 142e | U3, U5, U6 | Reader-safe GC preserves or implements the warm-layer research program without leaving the planning-spec contract. |
| 142f | U3, U5, U6 | Index diagnostics preserves or implements the warm-layer research program without leaving the planning-spec contract. |
| 142g | U3, U5, U6 | Repair command preserves or implements the warm-layer research program without leaving the planning-spec contract. |
| 142h | U3, U5, U6 | Adversarial mutation tests preserves or implements the warm-layer research program without leaving the planning-spec contract. |
| 142i | U3, U5, U6 | Performance gates preserves or implements the warm-layer research program without leaving the planning-spec contract. |
| 142j | U3, U5, U6 | Dupe audit gate preserves or implements the warm-layer research program without leaving the planning-spec contract. |
| 142k | U3, U5, U6 | Public README update preserves or implements the warm-layer research program without leaving the planning-spec contract. |
| 142l | U3, U5, U6 | Research artifact update preserves or implements the warm-layer research program without leaving the planning-spec contract. |
| 142m | U3, U5, U6 | Changelog update preserves or implements the warm-layer research program without leaving the planning-spec contract. |
| 142n | U3, U5, U6 | Release readiness gate preserves or implements the warm-layer research program without leaving the planning-spec contract. |
| 142o | U3, U4, U5, U6 | Program closeout preserves or implements the warm-layer research program without leaving the planning-spec contract. |

## Constraints

| Dimension | Constraint |
|-----------|-----------|
| Category boundary | Only feature operations for the warm-index substrate. Refactors are permitted only as direct enabling moves inside the declared patch surface. |
| Blast radius ceiling | high - index state, search hot paths, and hidden process lifecycle can affect every search. |
| Structural boundary | Preserve one binary, one index format, and public CLI compatibility. |
| Dependency boundary | This chain may depend on prior warm-index chains by ID but must remain cold-startable from todo files and repository state. |
| Rollback surface | Revert this chain's files and disable the internal index path; public search must keep current Nexus/cold behavior. |
| Parallelism | No by default. Warm-index chains intentionally serialize to preserve format and search-contract correctness. |

## Invariants
- I1: Public `ix search`, `ix matches`, `ix inspect`, and `ix explain` command contracts remain backward compatible.
- I2: The verifier remains the final owner of match correctness; index structures may only narrow candidates when proof is available.
- I3: Incomplete, stale, malformed, or wrong-root index state fails closed to the existing search path.
- I4: Background workers never write user-facing stdout/stderr during normal public search.
- I5: Search-visible index generations are published atomically; partial writes are not observable as current state.
- I6: Windows freshness uses USN when available and conservative reconcile/fallback when continuity is uncertain.

## Chain Manifest

| File | Phase | Role | Status |
|------|-------|------|--------|
| `/todo/changelog/142-warm-index-compaction-ops-hardening.md` | parent | Chain root | archived |
| `/todo/changelog/142a-warm-index-compaction-ops-hardening.md` | a | Baseline / contract lock | archived |
| `/todo/changelog/142b-warm-index-compaction-ops-hardening.md` | b | Compaction planner | archived |
| `/todo/changelog/142c-warm-index-compaction-ops-hardening.md` | c | Merge writer | archived |
| `/todo/changelog/142d-warm-index-compaction-ops-hardening.md` | d | Tombstone folding | archived |
| `/todo/changelog/142e-warm-index-compaction-ops-hardening.md` | e | Reader-safe GC | archived |
| `/todo/changelog/142f-warm-index-compaction-ops-hardening.md` | f | Index diagnostics | archived |
| `/todo/changelog/142g-warm-index-compaction-ops-hardening.md` | g | Repair command | archived |
| `/todo/changelog/142h-warm-index-compaction-ops-hardening.md` | h | Adversarial mutation tests | archived |
| `/todo/changelog/142i-warm-index-compaction-ops-hardening.md` | i | Performance gates | archived |
| `/todo/changelog/142j-warm-index-compaction-ops-hardening.md` | j | Dupe audit gate | archived |
| `/todo/changelog/142k-warm-index-compaction-ops-hardening.md` | k | Public README update | archived |
| `/todo/changelog/142l-warm-index-compaction-ops-hardening.md` | l | Research artifact update | archived |
| `/todo/changelog/142m-warm-index-compaction-ops-hardening.md` | m | Changelog update | archived |
| `/todo/changelog/142n-warm-index-compaction-ops-hardening.md` | n | Release readiness gate | archived |
| `/todo/changelog/142o-warm-index-compaction-ops-hardening.md` | o | Verification / closeout | archived |

Chain is complete when all rows read `archived` and all files are in `/todo/changelog/`.

## Phase Plan

| Letter | Role | Patch Surface | Depends On | Parallelizable |
|--------|------|--------------|-----------|---------------|
| `a` | Baseline contract lock | Freeze operational invariants and growth bounds. | - | No |
| `b` | Compaction planner | Select small/dense/deleted segments for merge without blocking readers. | 142a-warm-index-compaction-ops-hardening | No |
| `c` | Merge writer | Merge postings/catalog deltas into a compacted generation. | 142b-warm-index-compaction-ops-hardening | No |
| `d` | Tombstone folding | Fold deletes and stale path entries during compaction. | 142c-warm-index-compaction-ops-hardening | No |
| `e` | Reader-safe GC | Delete obsolete generations only after reader pins cannot reference them. | 142d-warm-index-compaction-ops-hardening | No |
| `f` | Index diagnostics | Add inspect/debug output for manifest, generations, journal cursor, and lock state. | 142e-warm-index-compaction-ops-hardening | No |
| `g` | Repair command | Add internal rebuild/reconcile command for corrupted or stale index state. | 142f-warm-index-compaction-ops-hardening | No |
| `h` | Adversarial mutation tests | Test branch-switch, rename storm, delete/recreate, and partial write failures. | 142g-warm-index-compaction-ops-hardening | No |
| `i` | Performance gates | Benchmark cold, index-hot, mutation-hot, and fallback modes. | 142h-warm-index-compaction-ops-hardening | No |
| `j` | Dupe audit gate | Run dupe-audit over new index modules and search integration surfaces. | 142i-warm-index-compaction-ops-hardening | No |
| `k` | Public README update | Document capabilities honestly with internal-control boundaries. | 142j-warm-index-compaction-ops-hardening | No |
| `l` | Research artifact update | Update architecture note with implemented state and remaining limits. | 142k-warm-index-compaction-ops-hardening | No |
| `m` | Changelog update | Append execution log and per-chain evidence pointers. | 142l-warm-index-compaction-ops-hardening | No |
| `n` | Release readiness gate | Run full build/test/diff hygiene and capture exact outputs. | 142m-warm-index-compaction-ops-hardening | No |
| `o` | Program closeout | Verify all six chains, 90 slices, source anchors, docs, tests, and known limits. | 142n-warm-index-compaction-ops-hardening | No |

## Validation Expectations
- Signal 1: The chain's terminal unit verifies all listed source anchors and invariants.
- Signal 2: Relevant build/test/search parity gates pass or record concrete blockers.
- Evidence format expected: exact command output snippets, changed file list, and failing blocker text where applicable.

## Next todo
`/todo/pending/142a-warm-index-compaction-ops-hardening.md`
