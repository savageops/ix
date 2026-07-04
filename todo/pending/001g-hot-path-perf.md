---
id: 001g-hot-path-perf
parent: 001-hot-path-perf
type: execution-unit
protocol_version: "2.1"
category: feature
phase: g
status: pending
patch_scope: "Replace the scalar chunk-skip helpers (std.mem.lastIndexOfScalar, std.mem.count) at src/core/search.zig:3556,3562-3566 with a RotVec-style SIMD memchr2/memchr3 primitive added to src/core/simd.zig, and replace the per-line std.mem.trimEnd(u8, raw_line, '\\r') at src/core/search.zig:3651 and 4423 with a single-byte branch on the last byte."
blast_radius: low
blast_radius_justification: "Two-file change. simd.zig gains a new primitive (additive); search.zig swaps two scalar helper calls and two CR-trim calls for the SIMD primitive and a single-byte branch. Failure propagation bounded to the chunk-skip and line-record paths; casefold and matcher paths untouched."
idempotency_contract: idempotent
idempotency_notes: "Pure source edits. Re-executing produces the same state. Direct re-execute on partial failure."
acceptance: "`grep -n 'lastIndexOfScalar\\|std.mem.count\\|trimEnd' src/core/search.zig` shows the chunk-skip and CR-trim sites replaced; `src/core/simd.zig` exports the new memchr2/memchr3 primitive; `zig build test` exits 0 with new tests proving the primitive's worst-case O(h+n) behavior and the RotVec overlap-read correctness; benchmark receipt confirms no scan-loop regression."
exit_criterion: "Diff at search.zig:3556,3562-3566,3651,4423 shows the replacements; `grep -n 'memchr2\\|memchr3\\|indexOfTwoBytes\\|indexOfBytes2' src/core/simd.zig` returns the new export; `zig build test` exit 0; benchmark receipt captured."
validation: "cd \"E:/Workspaces/01_Projects/01_Github/ix-zig\" && zig build test 2>&1 | tail -5 && grep -n 'lastIndexOfScalar\\|trimEnd.*rnr' src/core/search.zig"
expected_exit_code: 0
expected_output_pattern: "(test|PASS|0 failed|.*passed)"
evidence: "PLACEHOLDER — replace with exact captured stdout at completion."
conflict_surface: ""
invariants:
  - "I1: No mutex in scan loop (unaffected)."
  - "I3: Compile-time SIMD selection only — the new primitive uses @Vector, no runtime dispatch."
  - "I6: Existing tests pass."
  - "I7: Benchmark identity controls do not regress."
source_message_anchor: "U1, U2, U3"
source_message_excerpt: "wha your unbiased opinion is on areas to review where performance improvements can be made; studying the web, the refs the docs research; Make sure the todo slices each demand mandatory unavoidable computer science / algorithm / hardware / system / code WEB RESEARCH using insect skill"
source_message_proof_obligation: "Close parent Decision Record G-7. The scalar chunk-skip and per-line CR trim are replaced with RotVec-style SIMD anchoring (worst-case O(h+n)) and a single-byte branch, eliminating the scalar scans on the hot path."
entry_state: "001f is archived. zig build test is green. search.zig:3556,3562-3566 use scalar std.mem.lastIndexOfScalar/std.mem.count; search.zig:3651 and 4423 use std.mem.trimEnd(u8, raw_line, '\\r'). simd.zig exports indexOfByte and indexOf but not a multi-byte/rotated primitive."
rollback_surface: "1. `git checkout src/core/search.zig src/core/simd.zig`. 2. `zig build test`."
dependencies: "001f-hot-path-perf"
next_todo: /todo/pending/001h-hot-path-perf.md
continuation: "On completion: record evidence, set status done, move to /todo/changelog/001g-hot-path-perf.md, continue immediately to /todo/pending/001h-hot-path-perf.md. Stay focused on this slice."
blocked_reason: ""
unblock_action: ""
resumption_point: ""
---
# 001g RotVec memchr2/memchr3 Anchoring and CR-Trim Replacement

## Execute Now

Add a RotVec-style `memchr2`/`memchr3` primitive (worst-case O(h+n), handles unaligned overlap reads without a slow path) to `src/core/simd.zig`, then replace the scalar `std.mem.lastIndexOfScalar`/`std.mem.count` chunk-skip helpers at `src/core/search.zig:3556,3562-3566` and the per-line `std.mem.trimEnd(u8, raw_line, "\r")` at `:3651, :4423` with the new primitive and a single-byte branch respectively.

## Slice Focus Rule

This unit owns the agent's attention until the scalar sites are replaced, the new primitive is tested for RotVec overlap-read correctness and worst-case O(h+n) behavior, and the benchmark confirms no scan regression. The agent must not touch the matcher path (Fat Teddy territory, now closed), must not introduce CLMUL (DP-2 forbids it for newline finding), and must not change the existing `simd.indexOfByte` (already correct VPCMPEQB+VPMOVMSKB+TZCNT).

## Why This Execution Unit Exists

This slice closes the worst-case-safety gap on the structural-anchor path. The audit found that `search.zig:3556,3562-3566` uses scalar `std.mem.lastIndexOfScalar`/`std.mem.count` on the chunk-skip path, and `:3651, :4423` does a scalar `std.mem.trimEnd` per line for a 1-in-N event (trailing CR). The frontier research (parent RCH-3) confirms BurntSushi/memchr's RotVec technique handles unaligned/overlap reads without a slow path and documents O(h+n) worst case where StringZilla documents O(h×n). The existing `simd.indexOfByte` already uses the right AVX2 primitive for single-byte newline finding; this slice extends the same discipline to multi-byte anchors and eliminates the scalar CR scan.

## Better-Than-Before Delta

The pre-slice weakness is a hybrid scan loop: SIMD-fast for newline finding (`simd.indexOfByte`) but scalar-slow for chunk-skip multi-byte anchors and per-line CR trim. The post-slice improvement is that the structural-anchor path is uniformly SIMD with a documented worst-case bound, the per-line CR trim becomes a single comparison, and a new test in `simd.zig` pins the RotVec overlap-read correctness so future refactors cannot regress it.

## Slice Domain Standard

| Domain Standard | Local Evidence | Implementation Consequence | Anti-Assumption Guard |
|-----------------|----------------|----------------------------|-----------------------|
| RotVec reads across the wrap boundary by rotating so the "second half" of a straddling read is realigned, avoiding a separate tail path. memchr2/memchr3 compose two/three single-byte VPCMPEQB compares and AND the masks. | BurntSushi/memchr (parent RCH-3); existing `simd.indexOfByte` in `simd.zig:25`. | Add a `memchr2`/`memchr3` primitive to `simd.zig` following the RotVec pattern. | Do NOT use CLMUL (DP-2 — simdjson uses it for backslash-escape chains, not newline finding). Do NOT change `simd.indexOfByte`. |
| The CR trim is a 1-in-N event and should cost one comparison, not a scalar length scan. | `search.zig:3651, 4423` use `std.mem.trimEnd(u8, raw_line, "\r")` which scans from the end. | Replace with `if (line.len > 0 and line[line.len-1] == '\\r') line.len -= 1;` | A trim that handles multi-byte trailing sets is over-engineering — the only producer is CRLF line endings. |

## Domain-Knowledge Research Check

| Knowledge Gap | Research / Probe To Run | Source Priority | Decision It Controls | Closure Evidence |
|---------------|--------------------------|-----------------|----------------------|------------------|
| Exact RotVec technique for unaligned overlap reads in BurntSushi/memchr. | `engine --url https://github.com/BurntSushi/memchr`; `engine --query "memchr RotVec unaligned overlap read technique 2024"`. | Primary: BurntSushi/memchr repo. | The exact Zig port — how to handle the wrap/overlap without a slow path. | Markdown excerpt of the RotVec routine + the Zig port. |
| How does memchr compose memchr2/memchr3 from single-byte compares? | BurntSushi/memchr `src/memchr/mod.rs` and the vector impls. | Primary: BurntSushi/memchr repo. | Whether to AND two masks (memchr2) or compose three (memchr3). | Quoted routine + the chosen composition. |
| Is the worst-case O(h+n) guarantee load-bearing for IX's workloads, or is it adversarial only? | `engine --url https://github.com/BurntSushi/memchr/discussions/159` (memchr vs StringZilla worst-case). | Primary: memchr discussions. | Whether the primitive swap is justified by real-workload wins or only by worst-case safety. | Quoted claim + a measurement or a documented worst-case-safety rationale. |
| External gap already closed by local/research artifact because the parent RCH-3 named the priority; this slice confirms the technique. | — | — | — | — |

## Technical Execution Blueprint

| Area | Required Detail |
|------|-----------------|
| Repository anchors | `src/core/simd.zig:25` (`indexOfByte` — the existing VPCMPEQB pattern to mirror), `:63` (`indexOf`), `:1-15` (header documenting the pure-Zig rationale); `src/core/search.zig:3556` (scalar `lastIndexOfScalar` on chunk-skip), `:3562-3566` (scalar `std.mem.count` region), `:3651` (per-line trimEnd in recordLineIntoShardImpl), `:4423` (per-line trimEnd in recordLine). |
| Existing-owner decision | Extend `simd.zig` (the canonical pure-Zig SIMD owner) and the two scan helpers in `search.zig`. No new module. |
| Domain owner / canonical standard | BurntSushi/memchr RotVec + memchr2/memchr3 composition. |
| Intended design | (1) Add `pub fn indexOf2(haystack: []const u8, a: u8, b: u8) ?usize` (and `indexOf3` if the chunk-skip needs three anchors) to `simd.zig`, following the RotVec pattern: read 32-byte chunks, `@Vector(32,u8)` equality with `@splat(a)` and `@splat(b)`, OR the masks, `@pmovmskb`-equivalent (`@reduce` or manual) to a u32, `@ctz` for the first hit; handle the unaligned head/tail via RotVec overlap read. (2) Replace the scalar chunk-skip at `search.zig:3556,3562-3566` with the new primitive. (3) Replace `std.mem.trimEnd(u8, raw_line, "\r")` at `:3651, :4423` with `if (line.len > 0 and line[line.len-1] == '\\r') line.len -= 1;`. |
| Integration path | The chunk-skip path is consumed by the chunk-prefilter in `scanOpenFileIntoShardImpl`; the per-line trim is consumed by `recordLineIntoShardImpl` and `recordLine`. |
| Failure modes to prevent | (1) Misimplementing RotVec so the overlap read returns wrong results on unaligned inputs. (2) Using CLMUL (DP-2). (3) Breaking the existing `simd.indexOfByte` consumers while adding the new primitive. (4) Changing multi-byte trim semantics (CR-only is the contract). |
| Alternatives rejected | CLMUL (DP-2). A single new `memchr_n` generic — rejected for readability; separate `indexOf2`/`indexOf3` match the memchr convention. |
| Proof hooks | New `simd.zig` tests for RotVec overlap-read correctness (unaligned haystacks, hits at offset 0, 1, 31, 32, 33, end); worst-case O(h+n) test (adversarial haystack with no hits, all-equal bytes); `search.zig` test confirming chunk-skip still finds the same anchors; `zig build test` green; benchmark receipt. |

## Codebase Research And Execution Addendum

**Implementation map:** Read `src/core/simd.zig` in full (175 lines) to mirror the existing `indexOfByte` style. Read `src/core/search.zig` around 3540-3610 (chunk-skip) and 3640-3660 + 4415-4430 (per-line trim). Read the BurntSushi/memchr RotVec routine via the harvest.

**Existing-owner directive:** `simd.zig` owns the SIMD primitives; the scan helpers in `search.zig` own the call sites. Extend both in place.

**Directive:** Add `indexOf2`/`indexOf3` to `simd.zig` following RotVec. Swap the chunk-skip call sites. Swap the two CR-trim call sites. Add tests. Run `zig build test`. Run the benchmark.

**Gold-standard guardrail:** No CLMUL (DP-2). No change to `indexOfByte`. No multi-byte trim (CR-only). The RotVec overlap-read test is mandatory — a naive implementation that skips the overlap will misread unaligned inputs.

**Knowledge gathering route:** Local reads; then `engine --url` / `engine --query` for the RotVec technique and memchr2/memchr3 composition.

**Runtime visualization:** `chunk-skip path ──simd.indexOf2(a,b)──► VPCMPEQB ×2 + OR + VPMOVMSKB + TZCNT (RotVec overlap)`. Before: `──std.mem.lastIndexOfScalar──► scalar byte loop`. CR trim: `if (line[line.len-1]=='\\r') line.len -= 1` (one comparison); before: `std.mem.trimEnd` (scalar scan from end).

**Proof expansion:** Tests for `indexOf2`/`indexOf3`: haystacks of length 0, 1, 31, 32, 33, 64, 65; hits at offsets 0, 1, 16, 31, 32, 33, end-1; both needles present; neither present (worst-case O(h+n) — measure it does not blow up); all-equal haystack (adversarial). Chunk-skip integration test: a chunk with the anchor at the start, middle, end, and absent. CR-trim test: lines ending in `\r`, `\n`, `\r\n`, neither, empty line.

**Action-mode arbitration:** Execute now. Synchronous add-primitive-then-swap-then-test-then-benchmark.

## Embedded Framing

Make the structural-anchor path uniformly SIMD and worst-case-safe: add the RotVec primitive that memchr proven, replace the scalar chunk-skip and per-line CR trim, and pin the overlap-read correctness with a test so the worst-case bound survives future refactors. CLMUL stays out — frontier guidance reserves it for escape carry chains, not newline finding.

## Slice Research Directive

| Research Topic | Why It Matters To This Slice | Insect Mode | Source Priority | Closure Evidence |
|----------------|------------------------------|-------------|-----------------|------------------|
| RotVec unaligned overlap-read technique. | Controls the correctness of the new primitive — a naive wrap will misread. | `engine --url https://github.com/BurntSushi/memchr`; `engine --query "memchr RotVec unaligned overlap read 2024"`. | Primary: BurntSushi/memchr. | Markdown excerpt + Zig port. |
| memchr2/memchr3 composition (AND vs OR of masks). | Controls whether `indexOf2` ORs two hit masks (find either byte) — the chunk-skip anchor use case. | BurntSushi/memchr `src/memchr/mod.rs`. | Primary: BurntSushi/memchr. | Quoted composition. |
| Worst-case O(h+n) load-bearing for IX vs adversarial only. | Controls whether the swap is justified by real wins or by safety. | `engine --url https://github.com/BurntSushi/memchr/discussions/159`. | Primary: memchr discussions. | Quoted claim + measurement or safety rationale. |

## Original User Message Proof

| Source Anchor | Verbatim Original Snippet | Slice Proof Obligation | Evidence Capture |
|---------------|---------------------------|------------------------|------------------|
| U1 | "wha your unbiased opinion is on areas to review where performance improvements can be made" | Close gap G-7 — replace scalar chunk-skip and CR trim. | Diff at the named lines; new primitive in simd.zig; benchmark receipt. |
| U2 | "studying the web, the refs the docs research" | Research confirms RotVec technique and worst-case bound before implementing. | Quoted memchr sources in research closure. |
| U3 | "Make sure the todo slices each demand mandatory unavoidable computer science / algorithm / hardware / system / code WEB RESEARCH using insect skill" | Three mandatory research rows above. | Each row's Closure Evidence populated. |

## Pre-flight Checklist

- [ ] All `dependencies` archived with non-PLACEHOLDER evidence. (001f archived.)
- [ ] All `entry_state` claims verifiable.
- [ ] `source_message_*` populated.
- [ ] `conflict_surface` empty.
- [ ] Rollback procedure populated.
- [ ] Idempotency: idempotent; direct re-execute.
- [ ] No other slice being advanced.
- [ ] Slice Research Directive declares bounded external research.

## Entry State

- 001f archived. `zig build test` green.
- `search.zig:3556,3562-3566` use scalar helpers; `:3651, :4423` use `std.mem.trimEnd`.
- `simd.zig` exports `indexOfByte` and `indexOf` but no multi-byte RotVec primitive.

## Patch Surface

**Modifies:**
- `src/core/simd.zig` — add `indexOf2`/`indexOf3` RotVec primitive + tests.
- `src/core/search.zig` — swap chunk-skip at 3556,3562-3566; swap CR trim at 3651, 4423.

**Adds:**
- (tests in-file per convention)

**Deletes:**
- (none)

**Must not touch:**
- `src/core/simd.zig`'s existing `indexOfByte` (already correct).
- The matcher path (`literal_alternates.zig`).
- `sz_shim.c`, `sz.zig`.

## Detailed Requirements

- R1: Read `src/core/simd.zig` and the BurntSushi/memchr RotVec routine (via Slice Research Directive) before editing.
- R2: Add `pub fn indexOf2(haystack: []const u8, a: u8, b: u8) ?usize` to `simd.zig` following the existing `indexOfByte` style + RotVec overlap handling. Use `@Vector(32,u8)` only (I3).
- R3: Add `indexOf3` if the chunk-skip path needs three anchor bytes (confirm during recon of `search.zig:3556,3562-3566`).
- R4: Replace the scalar `std.mem.lastIndexOfScalar`/`std.mem.count` chunk-skip at `search.zig:3556,3562-3566` with the new primitive.
- R5: Replace `std.mem.trimEnd(u8, raw_line, "\r")` at `:3651` and `:4423` with `if (line.len > 0 and line[line.len-1] == '\\r') line.len -= 1;` (or the equivalent slicing).
- R6: Add tests for `indexOf2`/`indexOf3` covering RotVec overlap correctness (unaligned haystacks, hits at offsets 0,1,31,32,33,end-1, both present, neither present, all-equal adversarial).
- R7: Add a chunk-skip integration test confirming the swap finds the same anchors as the scalar predecessor across a corpus of fixtures.
- R8: Add a CR-trim test: lines ending in `\r`, `\n`, `\r\n`, neither, empty.
- R9: Run `zig build test`. Run the benchmark. Confirm no scan regression (I7).
- R10: Apply DP-2 (no CLMUL) and GS4 (extend `simd.zig`, no new module).

## Invariants This Unit Must Preserve

- I1: No mutex in scan loop (unaffected).
- I3: Compile-time SIMD selection only.
- I6: `zig build test` green.
- I7: Benchmark identity control — no scan regression.

## Validation Plan

| Step | Command | Expected Exit Code | Expected Output Pattern | Idempotent |
|------|---------|-------------------|------------------------|-----------|
| 1 | `cd "E:/Workspaces/01_Projects/01_Github/ix-zig" && grep -n 'indexOf2\|indexOf3\|memchr2\|memchr3' src/core/simd.zig` | `0` | new primitive exported | yes |
| 2 | `cd "E:/Workspaces/01_Projects/01_Github/ix-zig" && grep -n 'lastIndexOfScalar\|std.mem.count\|trimEnd' src/core/search.zig` | `0` | the named sites no longer use the scalar helpers (other unrelated uses may remain) | yes |
| 3 | `cd "E:/Workspaces/01_Projects/01_Github/ix-zig" && zig build test 2>&1 \| tail -5` | `0` | test pass / 0 failed | yes |
| 4 | Benchmark runner before/after | `0` | scan_ms within noise or improved | no |

**Evidence to capture:** Greps, test tail, benchmark JSON.

## Exit State (Handoff Contract)

- `simd.zig` exports `indexOf2`/`indexOf3` (RotVec).
- `search.zig:3556,3562-3566,3651,4423` no longer use the scalar helpers.
- `zig build test` green including the new RotVec and CR-trim tests.
- Benchmark receipt captured.
- 001h inherits: all implementation slices (b–g) archived; the chain is ready for review.

## Rollback Procedure

1. `git checkout src/core/search.zig src/core/simd.zig`.
2. `zig build test`.

## Next todo

`/todo/pending/001h-hot-path-perf.md`

## Completion

- [ ] Pre-flight passed.
- [ ] Implementation-unit test floor: ≥30 feature-value tests across the new primitive + integration + CR-trim (RotVec overlap, worst-case, integration, CR fixtures). If fewer than 30, record the focused-test exemption with rationale.
- [ ] Tests prove the externally valuable capability through its intended entrypoint.
- [ ] All validation commands executed. Exit codes match.
- [ ] Post-flight: Exit State claims verifiable.
- [ ] Evidence captured. PLACEHOLDER gone.
- [ ] Status set to `done`.
- [ ] `mv /todo/pending/001g-hot-path-perf.md /todo/changelog/001g-hot-path-perf.md` verified.
- [ ] Continue immediately to `next_todo`.
