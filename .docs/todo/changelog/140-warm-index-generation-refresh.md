---
id: 140-warm-index-generation-refresh
type: parent
protocol_version: "2.1"
spec_status: approved
category: feature
status: done
epic_boundary: "Introduce manifest-published searchable generations so searches pin complete index epochs. This chain upgrades `.live` marker semantics into atomic manifest refresh."
subtodo_start: /todo/pending/140a-warm-index-generation-refresh.md
subtodo_final: /todo/pending/140o-warm-index-generation-refresh.md
continuation: "After each completed execution unit: record evidence, set status done, move to /todo/changelog/, continue immediately to next_todo. Never batch-archive. Never pause between units."
source_message_policy: "Every lettered unit MUST include source_message_anchor, source_message_excerpt, source_message_proof_obligation, and an Original User Message Proof section with verbatim snippets from the original user message."
---
# 140 Warm Index Generation Refresh

## Objective
Introduce manifest-published searchable generations so searches pin complete index epochs. This chain upgrades `.live` marker semantics into atomic manifest refresh.

## Rationale
Lucene NRT and Blackbird commit consistency both show that search-visible state must be published atomically. Foreground search should open a declared generation, not validate a query cache by walking the tree.

## Scope

**In scope:**
- Manifest format.
- Generation directories.
- Atomic manifest swap.
- Reader epoch pinning.
- Partial publish rejection.

**Out of scope:**
- Long-term compaction.
- USN-specific deltas.
- Remote index serving.

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
| 140a | U1, U2, U4, U5 | Baseline contract lock preserves or implements the warm-layer research program without leaving the planning-spec contract. |
| 140b | U3, U5, U6 | Manifest type skeleton preserves or implements the warm-layer research program without leaving the planning-spec contract. |
| 140c | U3, U5, U6 | Generation storage layout preserves or implements the warm-layer research program without leaving the planning-spec contract. |
| 140d | U3, U5, U6 | Atomic publish preserves or implements the warm-layer research program without leaving the planning-spec contract. |
| 140e | U3, U5, U6 | Manifest load validation preserves or implements the warm-layer research program without leaving the planning-spec contract. |
| 140f | U3, U5, U6 | Reader pin model preserves or implements the warm-layer research program without leaving the planning-spec contract. |
| 140g | U3, U5, U6 | Index writer integration preserves or implements the warm-layer research program without leaving the planning-spec contract. |
| 140h | U3, U5, U6 | Old generation retention preserves or implements the warm-layer research program without leaving the planning-spec contract. |
| 140i | U3, U5, U6 | Partial publish tests preserves or implements the warm-layer research program without leaving the planning-spec contract. |
| 140j | U3, U5, U6 | Search adoption guard preserves or implements the warm-layer research program without leaving the planning-spec contract. |
| 140k | U3, U5, U6 | Telemetry preserves or implements the warm-layer research program without leaving the planning-spec contract. |
| 140l | U3, U5, U6 | Concurrent read smoke preserves or implements the warm-layer research program without leaving the planning-spec contract. |
| 140m | U3, U5, U6 | Docs update preserves or implements the warm-layer research program without leaving the planning-spec contract. |
| 140n | U3, U5, U6 | Benchmark gate preserves or implements the warm-layer research program without leaving the planning-spec contract. |
| 140o | U3, U4, U5, U6 | Refresh closeout preserves or implements the warm-layer research program without leaving the planning-spec contract. |

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
| `/todo/changelog/140-warm-index-generation-refresh.md` | parent | Chain root | archived |
| `/todo/changelog/140a-warm-index-generation-refresh.md` | a | Baseline / contract lock | archived |
| `/todo/changelog/140b-warm-index-generation-refresh.md` | b | Manifest type skeleton | archived |
| `/todo/changelog/140c-warm-index-generation-refresh.md` | c | Generation storage layout | archived |
| `/todo/changelog/140d-warm-index-generation-refresh.md` | d | Atomic publish | archived |
| `/todo/changelog/140e-warm-index-generation-refresh.md` | e | Manifest load validation | archived |
| `/todo/changelog/140f-warm-index-generation-refresh.md` | f | Reader pin model | archived |
| `/todo/changelog/140g-warm-index-generation-refresh.md` | g | Index writer integration | archived |
| `/todo/changelog/140h-warm-index-generation-refresh.md` | h | Old generation retention | archived |
| `/todo/changelog/140i-warm-index-generation-refresh.md` | i | Partial publish tests | archived |
| `/todo/changelog/140j-warm-index-generation-refresh.md` | j | Search adoption guard | archived |
| `/todo/changelog/140k-warm-index-generation-refresh.md` | k | Telemetry | archived |
| `/todo/changelog/140l-warm-index-generation-refresh.md` | l | Concurrent read smoke | archived |
| `/todo/changelog/140m-warm-index-generation-refresh.md` | m | Docs update | archived |
| `/todo/changelog/140n-warm-index-generation-refresh.md` | n | Benchmark gate | archived |
| `/todo/changelog/140o-warm-index-generation-refresh.md` | o | Verification / closeout | archived |

Chain is complete when all rows read `archived` and all files are in `/todo/changelog/`.

## Phase Plan

| Letter | Role | Patch Surface | Depends On | Parallelizable |
|--------|------|--------------|-----------|---------------|
| `a` | Baseline contract lock | Freeze generation visibility and fail-closed publish invariants. | - | No |
| `b` | Manifest type skeleton | Add GenerationManifest structs with segment list, parent, root, and epoch fields. | 140a-warm-index-generation-refresh | No |
| `c` | Generation storage layout | Create `.ix/index/generations/<epoch>/` path helpers and tmp layout. | 140b-warm-index-generation-refresh | No |
| `d` | Atomic publish | Write manifest tmp file and atomic rename/swap into search-visible state. | 140c-warm-index-generation-refresh | No |
| `e` | Manifest load validation | Reject partial, wrong-root, unknown-segment, and future-version manifests. | 140d-warm-index-generation-refresh | No |
| `f` | Reader pin model | Add lightweight reader pin/epoch selection for foreground search. | 140e-warm-index-generation-refresh | No |
| `g` | Index writer integration | Make catalog/postings writers publish through generation directories. | 140f-warm-index-generation-refresh | No |
| `h` | Old generation retention | Keep prior generation live until no reader can observe a broken state. | 140g-warm-index-generation-refresh | No |
| `i` | Partial publish tests | Add tests proving failed writes leave old generation active. | 140h-warm-index-generation-refresh | No |
| `j` | Search adoption guard | Allow search to use current generation when complete, else fall back safely. | 140i-warm-index-generation-refresh | No |
| `k` | Telemetry | Expose generation epoch, refresh status, and fallback reason in JSON stats. | 140j-warm-index-generation-refresh | No |
| `l` | Concurrent read smoke | Probe search while publishing a new generation in controlled test flow. | 140k-warm-index-generation-refresh | No |
| `m` | Docs update | Document refresh_epoch versus compact_epoch semantics. | 140l-warm-index-generation-refresh | No |
| `n` | Benchmark gate | Measure generation-open overhead and compare to current cold/hot paths. | 140m-warm-index-generation-refresh | No |
| `o` | Refresh closeout | Verify epoch consistency and source-anchor coverage. | 140n-warm-index-generation-refresh | No |

## Validation Expectations
- Signal 1: The chain's terminal unit verifies all listed source anchors and invariants.
- Signal 2: Relevant build/test/search parity gates pass or record concrete blockers.
- Evidence format expected: exact command output snippets, changed file list, and failing blocker text where applicable.

## Next todo
`/todo/pending/140a-warm-index-generation-refresh.md`
