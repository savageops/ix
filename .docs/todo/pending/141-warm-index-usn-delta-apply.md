---
id: 141-warm-index-usn-delta-apply
type: parent
protocol_version: "2.1"
spec_status: approved
category: feature
status: pending
epic_boundary: "Make NTFS USN the primary Windows freshness source for the warm index. This chain moves from invalidation-only mutation handling to actual delta application."
subtodo_start: /todo/pending/141a-warm-index-usn-delta-apply.md
subtodo_final: /todo/pending/141o-warm-index-usn-delta-apply.md
continuation: "After each completed execution unit: record evidence, set status done, move to /todo/changelog/, continue immediately to next_todo. Never batch-archive. Never pause between units."
source_message_policy: "Every lettered unit MUST include source_message_anchor, source_message_excerpt, source_message_proof_obligation, and an Original User Message Proof section with verbatim snippets from the original user message."
---
# 141 Warm Index USN Delta Apply

## Objective
Make NTFS USN the primary Windows freshness source for the warm index. This chain moves from invalidation-only mutation handling to actual delta application.

## Rationale
The research identifies USN as the serious Windows-native delta feed. Directory watching remains useful for wakeups, but the journal gives continuity and affected-file evidence that avoids full metadata walks.

## Scope

**In scope:**
- USN cursor storage.
- Journal availability probing.
- Record-to-delta mapping.
- Fallback reconcile when continuity is lost.
- Windows-first tests/smokes.

**Out of scope:**
- Non-Windows native journal implementations.
- GUI/service installer.
- Networked indexing.

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
| 141a | U1, U2, U4, U5 | Baseline contract lock preserves or implements the warm-layer research program without leaving the planning-spec contract. |
| 141b | U3, U5, U6 | USN FFI skeleton preserves or implements the warm-layer research program without leaving the planning-spec contract. |
| 141c | U3, U5, U6 | Volume identity preserves or implements the warm-layer research program without leaving the planning-spec contract. |
| 141d | U3, U5, U6 | Cursor persistence preserves or implements the warm-layer research program without leaving the planning-spec contract. |
| 141e | U3, U5, U6 | Journal availability probe preserves or implements the warm-layer research program without leaving the planning-spec contract. |
| 141f | U3, U5, U6 | Read batch loop preserves or implements the warm-layer research program without leaving the planning-spec contract. |
| 141g | U3, U5, U6 | Record path resolution preserves or implements the warm-layer research program without leaving the planning-spec contract. |
| 141h | U3, U5, U6 | Delta task mapping preserves or implements the warm-layer research program without leaving the planning-spec contract. |
| 141i | U3, U5, U6 | Batch coalescing preserves or implements the warm-layer research program without leaving the planning-spec contract. |
| 141j | U3, U5, U6 | Continuity failure preserves or implements the warm-layer research program without leaving the planning-spec contract. |
| 141k | U3, U5, U6 | Directory watch fallback preserves or implements the warm-layer research program without leaving the planning-spec contract. |
| 141l | U3, U5, U6 | Delta apply integration preserves or implements the warm-layer research program without leaving the planning-spec contract. |
| 141m | U3, U5, U6 | USN tests/smokes preserves or implements the warm-layer research program without leaving the planning-spec contract. |
| 141n | U3, U5, U6 | Docs update preserves or implements the warm-layer research program without leaving the planning-spec contract. |
| 141o | U3, U4, U5, U6 | USN closeout preserves or implements the warm-layer research program without leaving the planning-spec contract. |

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
| `/todo/pending/141-warm-index-usn-delta-apply.md` | parent | Chain root | pending |
| `/todo/changelog/141a-warm-index-usn-delta-apply.md` | a | Baseline / contract lock | archived |
| `/todo/changelog/141b-warm-index-usn-delta-apply.md` | b | USN FFI skeleton | archived |
| `/todo/changelog/141c-warm-index-usn-delta-apply.md` | c | Volume identity | archived |
| `/todo/changelog/141d-warm-index-usn-delta-apply.md` | d | Cursor persistence | archived |
| `/todo/changelog/141e-warm-index-usn-delta-apply.md` | e | Journal availability probe | archived |
| `/todo/changelog/141f-warm-index-usn-delta-apply.md` | f | Read batch loop | archived |
| `/todo/pending/141g-warm-index-usn-delta-apply.md` | g | Record path resolution | pending |
| `/todo/pending/141h-warm-index-usn-delta-apply.md` | h | Delta task mapping | pending |
| `/todo/pending/141i-warm-index-usn-delta-apply.md` | i | Batch coalescing | pending |
| `/todo/pending/141j-warm-index-usn-delta-apply.md` | j | Continuity failure | pending |
| `/todo/pending/141k-warm-index-usn-delta-apply.md` | k | Directory watch fallback | pending |
| `/todo/pending/141l-warm-index-usn-delta-apply.md` | l | Delta apply integration | pending |
| `/todo/pending/141m-warm-index-usn-delta-apply.md` | m | USN tests/smokes | pending |
| `/todo/pending/141n-warm-index-usn-delta-apply.md` | n | Docs update | pending |
| `/todo/pending/141o-warm-index-usn-delta-apply.md` | o | Verification / closeout | pending |

Chain is complete when all rows read `archived` and all files are in `/todo/changelog/`.

## Phase Plan

| Letter | Role | Patch Surface | Depends On | Parallelizable |
|--------|------|--------------|-----------|---------------|
| `a` | Baseline contract lock | Freeze fail-closed journal semantics and fallback behavior. | - | No |
| `b` | USN FFI skeleton | Add minimal Windows API bindings/types for journal query and read. | 141a-warm-index-usn-delta-apply | No |
| `c` | Volume identity | Capture NTFS volume identity and journal ID in JournalCursor. | 141b-warm-index-usn-delta-apply | No |
| `d` | Cursor persistence | Persist and validate journal cursor under `.ix/index/journals/`. | 141c-warm-index-usn-delta-apply | No |
| `e` | Journal availability probe | Detect usable journal, inaccessible journal, and unsupported filesystem states. | 141d-warm-index-usn-delta-apply | No |
| `f` | Read batch loop | Read bounded USN record batches with timeout/cancellation points. | 141e-warm-index-usn-delta-apply | No |
| `g` | Record path resolution | Map journal records to catalog file IDs or pending path lookups. | 141f-warm-index-usn-delta-apply | No |
| `h` | Delta task mapping | Translate records into `upsert_file`, `delete_file`, and `reconcile_root` tasks. | 141g-warm-index-usn-delta-apply | No |
| `i` | Batch coalescing | Coalesce rename storms and duplicate writes before segment update. | 141h-warm-index-usn-delta-apply | No |
| `j` | Continuity failure | Escalate lost cursor/wrap/overflow into root-local reconcile. | 141i-warm-index-usn-delta-apply | No |
| `k` | Directory watch fallback | Retain `ReadDirectoryChangesW` as wakeup/invalidation when USN is unavailable. | 141j-warm-index-usn-delta-apply | No |
| `l` | Delta apply integration | Apply deltas into catalog/postings and publish refreshed generation. | 141k-warm-index-usn-delta-apply | No |
| `m` | USN tests/smokes | Add guarded Windows tests and local smoke scripts for journal paths. | 141l-warm-index-usn-delta-apply | No |
| `n` | Docs update | Document Windows-first freshness policy and fallback matrix. | 141m-warm-index-usn-delta-apply | No |
| `o` | USN closeout | Verify mutation freshness without full foreground tree validation. | 141n-warm-index-usn-delta-apply | No |

## Validation Expectations
- Signal 1: The chain's terminal unit verifies all listed source anchors and invariants.
- Signal 2: Relevant build/test/search parity gates pass or record concrete blockers.
- Evidence format expected: exact command output snippets, changed file list, and failing blocker text where applicable.

## Next todo
`/todo/pending/141a-warm-index-usn-delta-apply.md`
