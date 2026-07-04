---
id: 002d-frontier-absorption
parent: 002-frontier-absorption
type: execution-unit
protocol_version: "2.1"
category: feature
phase: d
status: pending
patch_scope: "Add an adaptive size-ratio dispatch to src/core/postings.zig::intersectFileIds (currently a textbook O(|a|+|b|) two-pointer merge at lines 990-1008) so that when one input is much smaller than the other (ratio ≥ ~8:1), the smaller is galloped through the larger via exponential-then-binary search (Demaine SODA 2000), achieving the comparison-optimal adaptive bound; the existing two-pointer merge is preserved as the balanced-size fallback."
blast_radius: low
blast_radius_justification: "Single-function change to a private helper in postings.zig. The public intersection API (the allocator-returning intersectFileIds signature) is unchanged. Failure propagation bounded to posting-intersection results; the rarest-first ordering in evaluateLookupGroup (lines 738-842) is unchanged and now pays off more."
idempotency_contract: idempotent
idempotency_notes: "Pure source edit. Re-executing produces the same state. Direct re-execute on partial failure."
acceptance: "intersectFileIds dispatches by size ratio: galloping when ratio ≥ ~8:1, two-pointer merge otherwise; the existing merge code is preserved verbatim as the fallback branch; new tests cover ratios 1:1, 1:2, 1:8, 1:64, 1:1024 with intersection sizes 0, 1, |small|, |large|; the existing intersection tests pass unchanged; a benchmark receipt on a warm-index query shows no regression."
exit_criterion: "`grep -c 'gallop\\|GALLOP' src/core/postings.zig` ≥ 1 AND `zig build test` exit 0 AND ratio-stratified tests pass AND benchmark receipt captured."
validation: "cd \"E:/Workspaces/01_Projects/01_Github/ix-zig\" && zig build test 2>&1 | tail -5 && grep -n 'gallop\\|GALLOP' src/core/postings.zig"
expected_exit_code: 0
expected_output_pattern: "(test|PASS|0 failed|.*passed)"
evidence: "PLACEHOLDER — replace with exact captured stdout at completion."
conflict_surface: ""
invariants:
  - "I6: Existing tests pass, including all posting-intersection fixtures."
  - "I7: Benchmark identity controls do not regress on warm-index queries."
source_message_anchor: "U4, U8"
source_message_excerpt: "Default to copying or tightly adapting proven algorithms; (survey Tier S2: galloping intersection dispatch, citing Demaine SODA 2000)"
source_message_proof_obligation: "Close Decision Record G-3 by adding adaptive galloping to intersectFileIds so rare-vs-common trigram pairs pay O(|rare| · log(|common|/|rare|)) instead of O(|a|+|b|)."
entry_state: "002c is archived. zig build test is green. intersectFileIds (postings.zig:990-1008) is a two-pointer merge with no size-ratio check. evaluateLookupGroup (lines 738-842) already orders rarest-first; that ordering is unchanged."
rollback_surface: "1. `git checkout src/core/postings.zig`. 2. `zig build test`."
dependencies: "002c-frontier-absorption"
next_todo: /todo/pending/002e-frontier-absorption.md
continuation: "On completion: record evidence, set status done, move to /todo/changelog/002d-frontier-absorption.md, continue immediately to /todo/pending/002e-frontier-absorption.md. Stay focused on this slice."
blocked_reason: ""
unblock_action: ""
resumption_point: ""
---
# 002d Adaptive Galloping Intersection

## Execute Now

Add a size-ratio dispatch at the entry of `intersectFileIds` (postings.zig:990) that uses galloping search (Demaine SODA 2000, the algorithm inside TimSort's merge and Roaring's array-array kernel) when the input size ratio exceeds ~8:1, falling back to the existing two-pointer merge for balanced inputs.

## Slice Focus Rule

This unit owns the agent's attention until the dispatch is implemented, tested across ratio regimes, and the benchmark confirms no regression. The agent must not change the rarest-first ordering in `evaluateLookupGroup` (it stays and now pays off more), must not switch to a hash-based intersection, must not change the public `intersectFileIds` signature, and must not replace the two-pointer merge — only add a dispatch in front of it.

## Why This Execution Unit Exists

This slice is separate because galloping is a precise algorithmic addition to one private helper. Sequencing it after 002b/002c (which don't touch postings.zig) keeps the patch surfaces clean. It is sequenced before 002e (Shufti, back on simd.zig) so the chain alternates patch surfaces and reduces concurrent-edit risk with chain 001.

## Better-Than-Before Delta

The pre-slice weakness is that `intersectFileIds` always touches every element of both inputs, paying `O(|large|)` work even when the small input has 50 elements and the large has 50,000. The post-slice improvement is that rare-vs-common pairs pay `O(|small| · log(|large|/|small|))` — a ~1000× algorithmic win on exactly the workload `evaluateLookupGroup`'s rarest-first ordering produces. The two-pointer merge is retained for balanced inputs where it is already optimal. A ratio-stratified test corpus pins the dispatch behavior so future refactors cannot silently regress to merge-only.

## Slice Domain Standard

| Domain Standard | Local Evidence | Implementation Consequence | Anti-Assumption Guard |
|-----------------|----------------|----------------------------|-----------------------|
| The Demaine adaptive bound is the comparison-optimal target; galloping search achieves it for skewed inputs. | Demaine, López-Ortiz, Munro SODA 2000 ("Adaptive Set Intersections, Unions, and Differences"). TimSort's merge uses the same gallop at threshold 7 (Java/Python runtimes). Roaring's array-array kernel uses it. | Implement gallop search with threshold ~8 (the TimSort-tuned value); preserve merge as fallback. | A dispatch that switches to galloping at threshold 1 (always gallops) loses on balanced inputs. A threshold of 100 never gallops in practice. |
| The inputs are sorted u64 arrays (FileId), unique within each. | `validatePostingsSegmentShape` enforces sorted+unique. | Galloping works on sorted unique arrays. | A gallop that assumes duplicates or unsorted input is malformed. |

## Domain-Knowledge Research Check

| Knowledge Gap | Research / Probe To Run | Source Priority | Decision It Controls | Closure Evidence |
|---------------|--------------------------|-----------------|----------------------|------------------|
| Exact Demaine bound and the TimSort galloping threshold. | `engine --url https://erikdemaine.org/papers/SODA2000/`; `engine --query "TimSort galloping merge threshold 7 adaptive intersection implementation"`. | Primary: Demaine paper + TimSort references (Java Arrays.parallelSort, Python list.sort). | The chosen threshold (~8) and the gallop algorithm. | Quoted bound + threshold rationale. |
| Gallop-search algorithm (exponential + binary). | `engine --query "galloping search exponential binary sorted array implementation"`. | Primary: TimSort source. | The exact Zig helper. | Quoted routine. |
| Does the win materialize on IX's posting-list sizes? | Local benchmark on warm-index query with rarest-first ordering. | Primary: local measurement. | Whether the change is worth the code churn (AS3). | Benchmark receipt. |

## Technical Execution Blueprint

| Area | Required Detail |
|------|-----------------|
| Repository anchors | `src/core/postings.zig:990-1008` (the `intersectFileIds` two-pointer merge), `:738-842` (`evaluateLookupGroup` rarest-first ordering — unchanged), `:1481, 1594` (existing intersection tests). |
| Existing-owner decision | Extend `postings.zig::intersectFileIds`. Add a private `gallopSearch` / `intersectGalloping` helper above it. |
| Domain owner / canonical standard | Demaine SODA 2000; TimSort galloping merge. |
| Intended design | (1) Add `fn gallopSearchGeq(arr: []const FileId, target: FileId, start: usize) usize` returning the smallest index `≥ start` with `arr[index] ≥ target` (exponential + binary). (2) Add `fn intersectGalloping(allocator, small: []const FileId, large: []const FileId) ![]FileId` that walks `small` and gallops each element through `large`. (3) In `intersectFileIds`, at entry, compute size ratio; if `min.len * 8 ≤ max.len` (or similar threshold), dispatch to `intersectGalloping` with the smaller as the driver; else fall through to the existing two-pointer merge. (4) Preserve the existing merge verbatim. |
| Integration path | `evaluateLookupGroup` and `evaluateLookupPlan*` call `intersectFileIds`; the public signature is unchanged. |
| Failure modes to prevent | (1) Always-gallop (loses on balanced inputs). (2) Gallop that doesn't track the survivor cursor in `large` (re-searches from 0 each time → O(|small| · |large|)). (3) Gallop that mishandles duplicates (inputs are unique, so this is fine, but document it). (4) Changing the rarest-first ordering. |
| Alternatives rejected | Hash-based intersection (loses sorted-output invariant and the rarest-first benefit). Replacing the merge entirely (loses on balanced). SIMD galloping (Inoue VLDB 2015) — overkill for this slice; defer. |
| Proof hooks | Ratio-stratified tests: 1:1, 1:2, 1:8, 1:64, 1:1024; intersection sizes 0, 1, |small|, all-of-both; the existing intersection tests pass unchanged. Warm-index benchmark receipt. |

## Codebase Research And Execution Addendum

**Implementation map:** Read `src/core/postings.zig:980-1020` (the intersection + adjacent unionFileIds for style reference) and `:738-850` (the rarest-first ordering). Read the existing intersection tests at `:1481, 1594`.

**Existing-owner directive:** `postings.zig::intersectFileIds` owns this change. Add helpers above it.

**Directive:** Add `gallopSearchGeq` and `intersectGalloping`. Add the size-ratio dispatch at `intersectFileIds` entry. Add ratio-stratified tests. Run `zig build test`. Run a warm-index benchmark.

**Gold-standard guardrail:** Do NOT change the public signature. Do NOT replace the merge. Do NOT change the rarest-first ordering. Do NOT use a hash table.

**Knowledge gathering route:** Local reads; `engine --url`/`engine --query` for the Demaine bound and TimSort gallop algorithm.

**Runtime visualization:** `evaluateLookupGroup (rarest-first, unchanged) ──pairwise──► intersectFileIds(a, b) ──if min(a,b).len * 8 ≤ max(a,b).len──► intersectGalloping(small, large) ──else──► existing two-pointer merge`. The gallop version: for each `s` in `small`, `pos = gallopSearchGeq(large, s, last_pos)`; if `large[pos] == s`, append, advance `last_pos = pos + 1`; else `last_pos = pos`.

**Proof expansion:** Tests: ratio 1:1 (merge path, sanity), 1:2 (still merge), 1:8 (galloping kicks in), 1:64, 1:1024 (galloping dominates); intersection sizes 0 (no common), 1 (single common at start/middle/end), |small| (small is subset of large), all-of-both (identical). Add a test that asserts the dispatch threshold: construct inputs at ratio exactly 7:1 and 9:1 and verify the chosen path. Warm-index benchmark with rarest-first ordering.

**Action-mode arbitration:** Execute now. Synchronous add-helpers + dispatch + tests + benchmark.

## Embedded Framing

Make the posting intersection comparison-optimal under skew: dispatch to galloping when one list dwarfs the other, preserve the two-pointer merge for balanced inputs, and let the existing rarest-first ordering pay off as it was always meant to. A ratio-stratified test corpus pins the dispatch; a warm-index receipt proves the win.

## Slice Research Directive

| Research Topic | Why It Matters To This Slice | Insect Mode | Source Priority | Closure Evidence |
|----------------|------------------------------|-------------|-----------------|------------------|
| Demaine adaptive bound + TimSort gallop threshold. | Controls the dispatch threshold (~8) and the optimality argument. | `engine --url https://erikdemaine.org/papers/SODA2000/`; `engine --query "TimSort galloping merge threshold 7"`. | Primary: Demaine paper + TimSort. | Quoted bound + threshold. |
| Gallop-search algorithm. | Controls the Zig helper. | `engine --query "galloping search exponential binary sorted array implementation"`. | Primary: TimSort source. | Quoted routine. |
| Win on IX's posting-list sizes (AS3). | Confirms the change is worth it. | Local warm-index benchmark. | Primary: local measurement. | Benchmark JSON. |

## Original User Message Proof

| Source Anchor | Verbatim Original Snippet | Slice Proof Obligation | Evidence Capture |
|---------------|---------------------------|------------------------|------------------|
| U4 | "Default to copying or tightly adapting proven algorithms" (AGENTS.md) | Harvest the gallop-search algorithm from TimSort/Demaine before designing. | Quoted algorithm in design notes. |
| U8 | (survey Tier S2: galloping intersection) | Close gap G-3 by adding the adaptive dispatch. | `grep` hits + ratio-stratified tests + benchmark. |

## Pre-flight Checklist

- [ ] All `dependencies` archived. (002c archived.)
- [ ] All `entry_state` claims verifiable.
- [ ] `source_message_*` populated.
- [ ] `conflict_surface` empty.
- [ ] Rollback procedure populated.
- [ ] Idempotency: idempotent; direct re-execute.
- [ ] No other slice being advanced.
- [ ] Slice Research Directive declares bounded research.

## Entry State

- 002c archived. `zig build test` green.
- `intersectFileIds` (postings.zig:990-1008) is a two-pointer merge.
- `evaluateLookupGroup` already orders rarest-first.

## Patch Surface

**Modifies:**
- `src/core/postings.zig` — add `gallopSearchGeq`, `intersectGalloping`; add size-ratio dispatch at `intersectFileIds` entry; preserve existing merge as fallback; add ratio-stratified tests.

**Adds:** (tests in-file)
**Deletes:** (none)
**Must not touch:** `src/core/search.zig`, `src/core/trigram.zig`, `src/core/search_admission.zig`, `src/core/sz.zig`, `build.zig`.

## Detailed Requirements

- R1: Read `postings.zig:980-1020` and `:738-850`. Confirm the sorted-unique invariant and the rarest-first ordering.
- R2: Confirm the Demaine bound and the TimSort gallop algorithm via the Slice Research Directive.
- R3: Add `fn gallopSearchGeq(arr, target, start) usize` implementing exponential-then-binary search.
- R4: Add `fn intersectGalloping(allocator, small, large) ![]FileId` walking `small` and galloping through `large`, tracking the survivor cursor.
- R5: At `intersectFileIds` entry, compute size ratio. If `min.len * 8 ≤ max.len`, dispatch to `intersectGalloping(allocator, small, large)`; else fall through to the existing merge verbatim.
- R6: Add tests: ratios 1:1, 1:2, 1:8, 1:64, 1:1024; intersection sizes 0, 1, |small|, all-of-both. Add a dispatch-threshold test (ratio 7:1 → merge, 9:1 → gallop).
- R7: Run `zig build test`. Run warm-index benchmark. Confirm no regression.
- R8: Apply GS3 — extend `postings.zig` in place.

## Invariants This Unit Must Preserve

- I6: Existing intersection tests pass.
- I7: Warm-index benchmark identity control.

## Validation Plan

| Step | Command | Expected Exit Code | Expected Output Pattern | Idempotent |
|------|---------|-------------------|------------------------|-----------|
| 1 | `cd "E:/Workspaces/01_Projects/01_Github/ix-zig" && grep -c "gallop\|GALLOP" src/core/postings.zig` | `0` | ≥1 | yes |
| 2 | `cd "E:/Workspaces/01_Projects/01_Github/ix-zig" && zig build test 2>&1 \| tail -5` | `0` | test pass / 0 failed | yes |
| 3 | Warm-index benchmark | `0` | query_ms improved or within noise | no |

**Evidence to capture:** Grep, test tail, benchmark JSON.

## Exit State (Handoff Contract)

- `intersectFileIds` dispatches by size ratio (galloping for ≥~8:1, merge otherwise).
- Existing intersection tests pass unchanged.
- New ratio-stratified tests pass, including the dispatch-threshold test.
- Warm-index benchmark receipt captured.
- 002e inherits: green baseline; intersection now adaptive; `simd.zig` unchanged (its scope).

## Rollback Procedure

1. `git checkout src/core/postings.zig`.
2. `zig build test`.

## Next todo

`/todo/pending/002e-frontier-absorption.md`

## Completion

- [ ] Pre-flight passed.
- [ ] Implementation-unit test floor: ≥30 tests OR focused-test exemption. (Amendment: this slice adds ratio-stratified + dispatch-threshold tests; record the focused-test exemption — the capability is "adaptive galloping intersection," proven through the real `intersectFileIds` entrypoint across ratio regimes.)
- [ ] Tests prove capability through entrypoint.
- [ ] All validation commands executed. Exit codes match.
- [ ] Post-flight: Exit State claims verifiable.
- [ ] Evidence captured. PLACEHOLDER gone.
- [ ] Status set to `done`.
- [ ] `mv /todo/pending/002d-frontier-absorption.md /todo/changelog/002d-frontier-absorption.md` verified.
- [ ] Continue immediately to `next_todo`.
