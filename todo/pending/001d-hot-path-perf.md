---
id: 001d-hot-path-perf
parent: 001-hot-path-perf
type: execution-unit
protocol_version: "2.1"
category: feature
phase: d
status: pending
patch_scope: "Add @setCold() / @branchHint(.cold) (Zig 0.16.0+ confirmed spelling) to the recoverable-error paths in src/core/search.zig (isRecoverableScanAccessError branches around lines 2660-2683 and 2755-2763) and to the scalar tail of src/core/simd.zig so the hot scan loop stays in L1i and cold code is pushed to distant addresses."
blast_radius: low
blast_radius_justification: "Two-file annotation change. The functions' behavior is unchanged; only their section placement / branch-weight metadata changes. Failure propagation is bounded to the affected functions' instruction cache layout. Worst case: a misplaced @setCold on a hot path would slow that path — caught by the benchmark receipt."
idempotency_contract: idempotent
idempotency_notes: "Pure source annotation. Re-executing produces the same state. Direct re-execute on partial failure."
acceptance: "`grep -n '@setCold\\|@branchHint' src/core/search.zig src/core/simd.zig` returns hits on the recoverable-error paths and the simd scalar tail, `zig build test` exits 0, and a benchmark receipt on the literal-alternates workload confirms no scan-loop regression (the hot path did not accidentally get cold-marked)."
exit_criterion: "`grep -c '@setCold\\|@branchHint' src/core/search.zig src/core/simd.zig` returns ≥1 per file (or a documented subset) AND `zig build test` exit 0 AND benchmark receipt captured."
validation: "cd \"E:/Workspaces/01_Projects/01_Github/ix-zig\" && zig build test 2>&1 | tail -5 && grep -n '@setCold\\|@branchHint' src/core/search.zig src/core/simd.zig"
expected_exit_code: 0
expected_output_pattern: "(test|PASS|0 failed|.*passed)"
evidence: "PLACEHOLDER — replace with exact captured stdout at completion."
conflict_surface: ""
invariants:
  - "I1: No mutex in the scan loop. (Unaffected — annotation only.)"
  - "I6: Existing tests pass."
  - "I7: Benchmark identity controls do not regress — a misplaced @setCold on a hot path would show up here."
source_message_anchor: "U6, U2, U3"
source_message_excerpt: "@setCold() on error/fallback paths — keep hot scan code in L1i, push cold code to distant addresses; studying the web, the refs the docs research; Make sure the todo slices each demand mandatory unavoidable computer science / algorithm / hardware / system / code WEB RESEARCH using insect skill"
source_message_proof_obligation: "Close the AGENTS.md Tier 5 cold-path isolation gap (parent Decision Record G-3). The recoverable-error branches and the simd scalar tail become @setCold/@branchHint(.cold) so they do not pollute L1i during hot scan."
entry_state: "001c is archived. zig build test is green. The recoverable-error paths at search.zig:2660-2683 and 2755-2763 are unmarked. The simd.zig scalar tail is unmarked."
rollback_surface: "1. `git checkout src/core/search.zig src/core/simd.zig`. 2. `zig build test`."
dependencies: "001c-hot-path-perf"
next_todo: /todo/pending/001e-hot-path-perf.md
continuation: "On completion: record evidence, set status done, move to /todo/changelog/001d-hot-path-perf.md, continue immediately to /todo/pending/001e-hot-path-perf.md. Stay focused on this slice."
blocked_reason: ""
unblock_action: ""
resumption_point: ""
---
# 001d Cold-Path Isolation for Error and Scalar Tail

## Execute Now

Annotate the recoverable-error branches in `src/core/search.zig:2660-2683, 2755-2763` and the scalar tail of `src/core/simd.zig` with `@setCold()` / `@branchHint(.cold)` (Zig 0.16.0+ confirmed spelling) so cold code is pushed out of the hot scan loop's L1i footprint.

## Slice Focus Rule

This unit owns the agent's attention until the cold paths are marked, tests are green, and the benchmark confirms the hot path was not accidentally slowed. The agent must not cold-mark anything outside the named error branches and the scalar tail (over-marking would slow hot paths), must not touch the hot scan loop itself, and must not bundle 001e's literal-routing work.

## Why This Execution Unit Exists

This slice is separate because cold-path isolation is an L1i-footprint optimization distinct from alignment (001c) and routing (001e). The recoverable-error paths fire rarely (file access errors, sharing violations) but currently sit inline with the hot decode path; if the branch predictor mispredicts into them, or if the instruction-fetch window pulls them in, they waste L1i capacity that the hot loop needs. `@setCold`/`@branchHint(.cold)` is the LLVM-level mechanism (via Zig builtins) to relocate them to a distant section and tag the branch as cold for the predictor.

## Better-Than-Before Delta

The pre-slice weakness is that the AGENTS.md Tier 5 cold-path item is unimplemented — recoverable-error branches and scalar tails compete with the hot scan loop for L1i. The post-slice improvement is that the cold code is section-relocated, the hot loop's L1i working set shrinks, and a benchmark receipt proves the hot path did not regress. The annotation is also self-documenting: future readers see exactly which branches are rare.

## Slice Domain Standard

| Domain Standard | Local Evidence | Implementation Consequence | Anti-Assumption Guard |
|-----------------|----------------|----------------------------|-----------------------|
| `@setCold`/`@branchHint(.cold)` is the Zig builtin that lowers to LLVM `coldcc`/`!prof` branch weights; it relocates the function/block to a cold section and trains the predictor. | No usage anywhere in `search.zig`/`simd.zig` per 001a G-3. | Apply to the named error branches and the scalar tail. Do NOT apply to the hot scan loop or the casefold path. | Over-marking hot paths as cold would slow them; the benchmark receipt is the guard. |
| Cold-marking is only valuable where the branch is genuinely rare. | `isRecoverableScanAccessError` branches fire on access errors only. | Mark only the error-handling continuation, not the success path. | Marking the access-attempt itself as cold (it is the hot path). |

## Domain-Knowledge Research Check

| Knowledge Gap | Research / Probe To Run | Source Priority | Decision It Controls | Closure Evidence |
|---------------|--------------------------|-----------------|----------------------|------------------|
| Is `@setCold()` still the spelling in Zig 0.16.0+, or has it become `@branchHint(.cold)` (or both)? | `engine --query "zig 0.16 setCold branchHint cold deprecated spelling"`; `engine --url https://ziglang.org/documentation/master/`. | Primary: Zig docs. | Which builtin to use in the diff. | Quoted doc + diff. |
| Does LLVM actually relocate the cold block to a distant section, and does it train the branch predictor? | `engine --query "llvm coldcc branch weights __cold section predictor training"`; `engine --query "zig setCold llvm codegen section layout benchmark"`. | Primary: LLVM docs, Agner Fog. | Whether the annotation is worth the code churn or cosmetic. | Quoted LLVM/Zig source or benchmark. |
| External gap already closed by local/research artifact because the parent RCH named the priority; this slice confirms the spelling. | — | — | — | — |

## Technical Execution Blueprint

| Area | Required Detail |
|------|-----------------|
| Repository anchors | `src/core/search.zig:2660-2683` (first recoverable-error block), `:2755-2763` (second), `src/core/simd.zig` (scalar tail after the AVX2 fast path — confirm exact line during recon). Also `isRecoverableScanAccessError` definition (find via grep). |
| Existing-owner decision | Extend the existing functions. No new helper. |
| Domain owner / canonical standard | Zig builtin semantics; LLVM coldcc / branch-weight metadata. |
| Intended design | Add `@setCold()` (or `@branchHint(.cold)` per research) at the start of the recoverable-error continuation, and on the scalar-tail fallback in `simd.zig`. |
| Integration path | The hot scan loop in `scanOpenFileIntoShardImpl`/`scanOpenFile` is the consumer of the improved L1i footprint. |
| Failure modes to prevent | (1) Cold-marking a hot path (regression). (2) Using the wrong builtin name (compile error). (3) Marking the access attempt instead of the error continuation. |
| Alternatives rejected | Manual `noinline` + section attributes — rejected as non-idiomatic in Zig. Splitting error paths into separate cold functions — viable but larger churn; revisit if `@setCold` proves insufficient. |
| Proof hooks | `grep -c '@setCold\|@branchHint'` ≥1 in each file; `zig build test` green; benchmark receipt showing no scan regression. |

## Codebase Research And Execution Addendum

**Implementation map:** Read `src/core/search.zig` around 2660-2683 and 2755-2763 to see the exact error-continuation structure. Read `src/core/simd.zig` to find the scalar tail after the `@Vector` fast path. `grep -n "isRecoverableScanAccessError" src/core/search.zig` to find the predicate.

**Existing-owner directive:** The functions owning the error branches own this change. Extend them.

**Directive:** Apply the confirmed builtin to the error continuations and the scalar tail. Run `zig build test`. Run the benchmark. Confirm no hot-path regression.

**Gold-standard guardrail:** Do not cold-mark the hot scan loop, the casefold path, or the access attempt itself. Do not use the wrong builtin spelling. The benchmark receipt is the guard against over-marking.

**Knowledge gathering route:** Local reads; then `engine --query` / `engine --url` for builtin spelling and LLVM lowering behavior.

**Runtime visualization:** `hot scan loop (L1i resident) ──rare error──► @setCold continuation (relocated to __cold section, distant address)`. Without the annotation, the continuation sits inline and competes for L1i.

**Proof expansion:** Add a unit test that triggers the recoverable-error path with a mocked/simulated error and asserts the function still behaves correctly (cold-marking must not change behavior). Run the benchmark and capture the hot-path scan_ms before/after.

**Action-mode arbitration:** Execute now. Synchronous edit + measure.

## Embedded Framing

Mark the rare paths cold so the hot scan loop owns its L1i working set: the annotation trains the predictor and relocates the continuation, and the benchmark receipt proves the hot path did not regress. Behavior is unchanged; only section placement and branch weights move.

## Slice Research Directive

| Research Topic | Why It Matters To This Slice | Insect Mode | Source Priority | Closure Evidence |
|----------------|------------------------------|-------------|-----------------|------------------|
| Zig 0.16.0+ builtin spelling (`@setCold` vs `@branchHint(.cold)`). | Controls the exact diff and whether it compiles. | `engine --query "zig 0.16 setCold branchHint cold spelling documentation"`; `engine --url https://ziglang.org/documentation/master/`. | Primary: Zig docs. | Quoted doc + diff. |
| LLVM cold-section relocation and predictor training. | Confirms the annotation is functional, not cosmetic. | `engine --query "llvm coldcc __cold section branch weights predictor training codegen"`. | Primary: LLVM docs, Agner Fog. | Quoted source. |

## Original User Message Proof

| Source Anchor | Verbatim Original Snippet | Slice Proof Obligation | Evidence Capture |
|---------------|---------------------------|------------------------|------------------|
| U6 | "`@setCold() on error/fallback paths — keep hot scan code in L1i, push cold code to distant addresses`" (AGENTS.md Tier 5) | Close gap G-3 by cold-marking the recoverable-error branches and scalar tail. | `grep -c '@setCold\|@branchHint'` per file; benchmark receipt. |
| U2 | "studying the web, the refs the docs research" | Research confirms builtin spelling and LLVM lowering. | Quoted Zig docs + LLVM docs in research closure. |
| U3 | "Make sure the todo slices each demand mandatory unavoidable computer science / algorithm / hardware / system / code WEB RESEARCH using insect skill" | Two mandatory research rows above. | Each row's Closure Evidence populated. |

## Pre-flight Checklist

- [ ] All `dependencies` archived with non-PLACEHOLDER evidence. (001c archived.)
- [ ] All `entry_state` claims verifiable.
- [ ] `source_message_*` populated.
- [ ] `conflict_surface` empty.
- [ ] Rollback procedure populated.
- [ ] Idempotency: idempotent; direct re-execute.
- [ ] No other slice being advanced.
- [ ] Slice Research Directive declares bounded external research.

## Entry State

- 001c archived. `zig build test` green.
- `grep '@setCold\|@branchHint' src/core/search.zig src/core/simd.zig` returns 0 (per 001a G-3).
- The recoverable-error paths exist at the named line ranges.

## Patch Surface

**Modifies:**
- `src/core/search.zig` — add cold annotation to the recoverable-error continuations around 2660-2683 and 2755-2763.
- `src/core/simd.zig` — add cold annotation to the scalar tail after the AVX2 fast path.

**Adds:**
- (none)

**Deletes:**
- (none)

**Must not touch:**
- The hot scan loop (`scanOpenFileIntoShardImpl` inner loop, `scanOpenFile` inner loop).
- The casefold path (001c territory).
- The access attempt itself (only the error continuation is cold).

## Detailed Requirements

- R1: Read `src/core/search.zig` around 2660-2683 and 2755-2763; identify the exact error-continuation blocks (the code that runs when `isRecoverableScanAccessError` returns true).
- R2: Read `src/core/simd.zig`; identify the scalar tail after the `@Vector(32,u8)` fast path.
- R3: Confirm `@setCold()` vs `@branchHint(.cold)` spelling via the Slice Research Directive.
- R4: Apply the confirmed builtin to the two error continuations in `search.zig` and the scalar tail in `simd.zig`.
- R5: Add a unit test that triggers each recoverable-error path (or calls the scalar tail directly with a short input) and asserts behavior is unchanged.
- R6: Run `zig build test`. Run the benchmark on the literal-alternates workload. Confirm no hot-path scan regression (I7).
- R7: Apply the slice domain standard — only rare paths are cold-marked; the hot scan loop is untouched.

## Invariants This Unit Must Preserve

- I1: No mutex in scan loop (unaffected).
- I6: `zig build test` green.
- I7: Benchmark identity control — hot-path scan_ms not regressed.

## Validation Plan

| Step | Command | Expected Exit Code | Expected Output Pattern | Idempotent |
|------|---------|-------------------|------------------------|-----------|
| 1 | `cd "E:/Workspaces/01_Projects/01_Github/ix-zig" && grep -c '@setCold\|@branchHint' src/core/search.zig src/core/simd.zig` | `0` | ≥1 per file | yes |
| 2 | `cd "E:/Workspaces/01_Projects/01_Github/ix-zig" && zig build test 2>&1 \| tail -5` | `0` | test pass / 0 failed | yes |
| 3 | Benchmark runner before/after on literal-alternates workload | `0` | scan_ms within noise or improved | no |

**Evidence to capture:** Grep counts, test tail, benchmark JSON before/after.

## Exit State (Handoff Contract)

- `grep -c '@setCold\|@branchHint'` ≥1 in each of `search.zig` and `simd.zig`.
- `zig build test` green.
- Benchmark receipt shows no hot-path scan regression.
- 001e inherits: green baseline; cold paths marked; `search.zig:5271,5398,5420` still call `sz.indexOf` (its scope).

## Rollback Procedure

1. `git checkout src/core/search.zig src/core/simd.zig`.
2. `zig build test`.

## Next todo

`/todo/pending/001e-hot-path-perf.md`

## Completion

- [ ] Pre-flight passed.
- [ ] Implementation-unit test floor: focused-test exemption recorded (the capability is "cold-path isolation"; the new behavior-preservation tests plus the benchmark receipt prove it through the real scan entrypoint).
- [ ] Tests prove the externally valuable capability through its intended entrypoint.
- [ ] All validation commands executed. Exit codes match.
- [ ] Post-flight: Exit State claims verifiable.
- [ ] Evidence captured. PLACEHOLDER gone.
- [ ] Status set to `done`.
- [ ] `mv /todo/pending/001d-hot-path-perf.md /todo/changelog/001d-hot-path-perf.md` verified.
- [ ] Continue immediately to `next_todo`.
