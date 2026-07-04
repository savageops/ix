---
id: 001c-hot-path-perf
parent: 001-hot-path-perf
type: execution-unit
protocol_version: "2.1"
category: feature
phase: c
status: pending
patch_scope: "Add 32-byte alignment via @alignCast(32, ...) to the four casefold stack buffer access sites in src/core/search.zig (lower_line/lower_needle pairs in indexOfLiteralCasefold at lines 5239-5240 and countLiteralCasefold at lines 5283-5284) so store-to-load forwarding succeeds and the 12-cycle alignment-miss stall is eliminated."
blast_radius: low
blast_radius_justification: "Single-file change to two stack-buffer access patterns in already-isolated functions. Failure propagation path is bounded to the casefold literal scan path; case-sensitive and regex paths are untouched. The buffers' sizes and isolation logic are unchanged — only the alignment of the address passed into simd.indexOf is affected."
idempotency_contract: idempotent
idempotency_notes: "Re-executing the alignment edit produces the same source state. The change is a pure source-level annotation; no build-state side effects. Recovery is direct re-execute."
acceptance: "`grep -n '@alignCast' src/core/search.zig` returns ≥4 hits at the casefold buffer sites (the two lower_line + two lower_needle buffers), `zig build test` exits 0, and a new regression test proves the buffers are actually 32-byte aligned at runtime (e.g. assert @intFromPtr(&lower_line) % 32 == 0 in a test)."
exit_criterion: "`grep -c '@alignCast(32' src/core/search.zig` ≥ 4 AND `zig build test` exit 0 AND the new alignment-regression test passes."
validation: "cd \"E:/Workspaces/01_Projects/01_Github/ix-zig\" && zig build test 2>&1 | tail -5 && grep -n '@alignCast(32' src/core/search.zig"
expected_exit_code: 0
expected_output_pattern: "(test|PASS|0 failed|.*passed).*(\\n.*search.zig:.*@alignCast){0,}"
evidence: "PLACEHOLDER — replace with exact captured stdout at completion."
conflict_surface: ""
invariants:
  - "I2: No per-line allocation in the scan loop. The alignment edit must not introduce any allocation; it is a stack-address annotation only."
  - "I3: Compile-time SIMD selection only. The alignment must be a Zig-level @alignCast, not a runtime check."
  - "I6: Existing tests pass."
source_message_anchor: "U5, U2, U3"
source_message_excerpt: "@alignCast(32, ...) on casefold buffers to guarantee 32-byte forwarding success, avoid 12-cycle stall on alignment miss; studying the web, the refs the docs research; Make sure the todo slices each demand mandatory unavoidable computer science / algorithm / hardware / system / code WEB RESEARCH using insect skill"
source_message_proof_obligation: "Close the AGENTS.md Tier 5 store-to-load forwarding gap (parent Decision Record G-2). The four casefold stack buffers cited at search.zig:5239-5240, 5283-5284 become 32-byte aligned at their use site so the subsequent simd.indexOf load forwards successfully."
entry_state: "001b is archived. zig build test is green. The four casefold buffers at src/core/search.zig:5239-5240 and 5283-5284 are plain [N]u8 with default alignment (per 001a Decision Record G-2)."
rollback_surface: "1. `git checkout src/core/search.zig` to revert the @alignCast additions. 2. `zig build test` to confirm baseline."
dependencies: "001b-hot-path-perf"
next_todo: /todo/pending/001d-hot-path-perf.md
continuation: "On completion: record evidence, set status done, move to /todo/changelog/001c-hot-path-perf.md, continue immediately to /todo/pending/001d-hot-path-perf.md. Stay focused on this slice."
blocked_reason: ""
unblock_action: ""
resumption_point: ""
---
# 001c Casefold Stack Buffer 32-Byte Alignment

## Execute Now

Annotate the four casefold stack buffer access sites in `src/core/search.zig:5239-5240, 5283-5284` with `@alignCast(32, ...)` so the subsequent `simd.indexOf` loads hit a 32-byte-aligned address and store-to-load forwarding succeeds.

## Slice Focus Rule

This unit owns the agent's attention until all four buffers carry `@alignCast` and the regression test proves runtime 32-byte alignment. The agent must not touch any other part of `search.zig`, must not change the buffer sizes or the function-isolation logic (the 4 KiB `__chkstk` guard at `search.zig:5185-5193` is correct and out of scope), and must not bundle 001d's `@setCold` work into this slice.

## Why This Execution Unit Exists

This slice is separate because the alignment gap is a microarchitectural invariant distinct from the cold-path and routing concerns. The buffers are already isolated into their own functions (the comment at `search.zig:5185-5193` explains why: keeping the case-sensitive path's stack frame under 4 KiB to avoid `__chkstk` page probes). The remaining weakness is that the buffers' *alignment* is default — typically 1 or 16 bytes for `[N]u8` — so a 32-byte SIMD load on data just written by the casefold pass can cross a 32-byte boundary and stall the store-to-load forwarder for ~12 cycles. This is the one AGENTS.md Tier 5 claim the binary does not honor.

## Better-Than-Before Delta

The pre-slice weakness is a self-contradicting comment block: `search.zig:5185-5193` cites store-to-load forwarding as the *reason* for isolating the buffers, then the buffers are left unaligned. The post-slice improvement is that the rationale and the code agree: the buffers are isolated AND aligned, and a runtime regression test pins the alignment so a future refactor cannot silently regress it.

## Slice Domain Standard

| Domain Standard | Local Evidence | Implementation Consequence | Anti-Assumption Guard |
|-----------------|----------------|----------------------------|-----------------------|
| Store-to-load forwarding on x86-64 requires the load address to not cross a 32-byte boundary for 32-byte SIMD loads; a stack buffer of `[N]u8` is default-aligned to its element alignment (1). | `search.zig:5239-5240` declares `[CASEFOLD_LINE_MAX]u8 = undefined;` with no alignment annotation. | The slice must use `@alignCast(32, &lower_line)` (or the Zig 0.16.0+ confirmed spelling) at the point the buffer is passed to `simd.indexOf`. | Adding `align(32)` to the declaration instead of `@alignCast` at the use site — `@alignCast` is the idiom that propagates through slices; verify the confirmed spelling via research. |
| The 4 KiB stack-frame guard is the orthogonal invariant and must not be weakened. | `search.zig:5185-5193` comment; `CASEFOLD_LINE_MAX = 2 * 1024` and `CASEFOLD_NEEDLE_MAX = 256` together stay under 4 KiB. | The alignment edit must not move the buffers out of their isolated functions. | Bundling the buffers into the caller or growing them past 4 KiB is forbidden. |

## Domain-Knowledge Research Check

| Knowledge Gap | Research / Probe To Run | Source Priority | Decision It Controls | Closure Evidence |
|---------------|--------------------------|-----------------|----------------------|------------------|
| Is `@alignCast(32, &buf)` the correct Zig 0.16.0+ spelling, and does it propagate to slices derived from the buffer? | `engine --query "zig 0.16 @alignCast 32 stack buffer slice propagation"`; `engine --url https://ziglang.org/documentation/master/#alignCast`. | Primary: Zig documentation. | The exact syntax used in the diff. | Quoted doc sentence + the diff line. |
| Is the ~12-cycle store-to-load forwarding stall on unaligned 32-byte loads still current on Zen 4 / Golden Cove / Granite Rapids? | `engine --query "store-to-load forwarding 32 byte unaligned stall cycle zen 4 golden cove granite rapids 2024"`. | Primary: Agner Fog, Intel optimization manual, AMD software optimization guide. | Whether the alignment is worth the code churn or a no-op on modern hardware. | Quoted manual sentence confirming the stall cost (or a measurement from a benchmark). |
| External gap already closed by local/research artifact because parent RCH closed the priority sources; this slice confirms the load-bearing claim. | — | — | — | — |

## Technical Execution Blueprint

| Area | Required Detail |
|------|-----------------|
| Repository anchors | `src/core/search.zig:5188` (`CASEFOLD_LINE_MAX = 2 * 1024`), `:5193` (`CASEFOLD_NEEDLE_MAX = 256`), `:5238-5246` (`indexOfLiteralCasefold` body), `:5281-5298` (`countLiteralCasefold` body), `:5243` (`return simd.indexOf(lower_line[0..line.len], lower_needle[0..needle.len]);`), `:5292` (`const index = simd.indexOf(ll[start..], ln) orelse break;`). |
| Existing-owner decision | Extend the two existing casefold functions. No new helper. |
| Domain owner / canonical standard | x86-64 store-to-load forwarding semantics; Zig `@alignCast` semantics. |
| Intended design | Wrap the buffer pointer with `@alignCast(32, ...)` at the point it is sliced and passed to `simd.indexOf`. Four sites total: `lower_line` and `lower_needle` in `indexOfLiteralCasefold`; `ll` (the local alias for `lower_line`) and `ln` (alias for `lower_needle`) in `countLiteralCasefold`. |
| Integration path | `simd.indexOf` is the consumer; the scan loop calls `countLiteralCasefold` via `countLiteral`. |
| Failure modes to prevent | (1) Aligning the declaration but not the use site (does not propagate through slicing). (2) Growing the buffers past 4 KiB (breaks the `__chkstk` guard). (3) Adding a runtime alignment check (violates I3). |
| Alternatives rejected | `align(32)` on the declaration — rejected if it does not propagate to the slice passed to `simd.indexOf`; verify via research. A single aligned allocator-backed buffer — rejected because it would violate I2 (no per-line allocation). |
| Proof hooks | New test `casefold_buffers_are_32_byte_aligned` asserting `@intFromPtr(&lower_line) % 32 == 0` and same for `lower_needle`, `ll`, `ln`. `grep -c '@alignCast(32' src/core/search.zig` ≥ 4. `zig build test` green. |

## Codebase Research And Execution Addendum

**Implementation map:** Read `src/core/search.zig:5185-5300` to see both functions, the buffer declarations, and the slicing at the `simd.indexOf` call sites.

**Existing-owner directive:** The two casefold functions own these buffers. Extend them in place.

**Directive:** Apply `@alignCast(32, ...)` at the four use sites. Add a test that asserts runtime alignment. Run `zig build test`. Capture the grep and test output.

**Gold-standard guardrail:** Do not change buffer sizes, do not move buffers out of their functions, do not add runtime alignment checks.

**Knowledge gathering route:** Local `search.zig` read; then `engine --query` / `engine --url` to confirm `@alignCast` spelling and propagation; then `engine --query` to confirm the stall cost on target microarchitectures.

**Runtime visualization:** `stack frame (isolated < 4 KiB) ──@alignCast(32)──► lower_line/lower_needle ptr ──simd.indexOf──► 32-byte VPCMPEQB load (forwarding succeeds)`. Without the cast, the load crosses a 32-byte boundary and the forwarder stalls.

**Proof expansion:** Add `test "casefold stack buffers are 32-byte aligned at runtime"` in `search.zig`. The test calls the casefold functions with a deterministic input and asserts the buffer addresses are 32-byte multiples. Add a second adversarial test that calls the function many times to catch stack-layout-dependent regressions.

**Action-mode arbitration:** Execute now. Direct synchronous edit. No deferral.

## Embedded Framing

Align the buffers so the rationale comment and the binary agree: the casefold pass writes 32-byte chunks, the SIMD load reads 32-byte chunks, and `@alignCast(32)` is the contract that the forwarder will not stall. A regression test pins the alignment so the contract survives future refactors.

## Slice Research Directive

| Research Topic | Why It Matters To This Slice | Insect Mode | Source Priority | Closure Evidence |
|----------------|------------------------------|-------------|-----------------|------------------|
| Zig 0.16.0+ `@alignCast` spelling and slice propagation. | Controls the exact diff. If `@alignCast` does not propagate to `lower_line[0..line.len]`, the alignment is lost at the `simd.indexOf` call. | `engine --query "zig @alignCast slice propagation 0.16"`; `engine --url https://ziglang.org/documentation/master/#alignCast`. | Primary: Zig docs. | Quoted doc + diff. |
| Store-to-load forwarding stall cost on target microarchitectures. | Confirms the 12-cycle claim is current (justifies the change) or measures it as a no-op (records a smaller-than-claimed win). | `engine --query "store-to-load forwarding stall 32 byte unaligned zen 4 intel 2024 optimization manual"`. | Primary: Agner Fog, AMD/Intel optimization manuals. | Quoted manual sentence. |

## Original User Message Proof

| Source Anchor | Verbatim Original Snippet | Slice Proof Obligation | Evidence Capture |
|---------------|---------------------------|------------------------|------------------|
| U5 | "`@alignCast(32, ...) on casefold buffers to guarantee 32-byte forwarding success, avoid 12-cycle stall on alignment miss`" (AGENTS.md Tier 5) | Close gap G-2 by aligning all four casefold buffers. | `grep -c '@alignCast(32' src/core/search.zig` ≥ 4; alignment regression test passing. |
| U2 | "studying the web, the refs the docs research" | Research confirms `@alignCast` spelling and stall cost before editing. | Quoted Zig docs + optimization manual in research closure. |
| U3 | "Make sure the todo slices each demand mandatory unavoidable computer science / algorithm / hardware / system / code WEB RESEARCH using insect skill" | The two research rows above are mandatory. | Each row's Closure Evidence populated. |

## Pre-flight Checklist

- [ ] All `dependencies` archived in `/todo/changelog/` with non-PLACEHOLDER evidence. (001b archived.)
- [ ] All `entry_state` claims verifiable. (001b exit state; the four buffers are unaligned per G-2.)
- [ ] `source_message_anchor`, `source_message_excerpt`, `source_message_proof_obligation` populated.
- [ ] `conflict_surface` empty.
- [ ] Rollback procedure populated (low blast, but named).
- [ ] Idempotency: idempotent; direct re-execute on partial failure.
- [ ] No other slice being advanced.
- [ ] Slice Research Directive declares bounded external research.

## Entry State

- 001b archived. `zig build test` green.
- `grep '@alignCast' src/core/search.zig` returns 0 (per 001a G-2).
- The four casefold buffers exist at `search.zig:5239-5240, 5283-5284`.

## Patch Surface

**Modifies:**
- `src/core/search.zig` — add `@alignCast(32, ...)` at four buffer use sites in `indexOfLiteralCasefold` (~5243) and `countLiteralCasefold` (~5292); add one new regression test.

**Adds:**
- (none)

**Deletes:**
- (none)

**Must not touch:**
- Buffer size constants (`CASEFOLD_LINE_MAX`, `CASEFOLD_NEEDLE_MAX`).
- The function-isolation structure (the 4 KiB guard).
- Any non-casefold path.

## Detailed Requirements

- R1: Read `src/core/search.zig:5185-5300` to locate both casefold functions and their `simd.indexOf` call sites.
- R2: Confirm `@alignCast` spelling and slice propagation via the Slice Research Directive before editing.
- R3: Apply `@alignCast(32, ...)` to `lower_line` and `lower_needle` in `indexOfLiteralCasefold` at the point they are sliced for `simd.indexOf` (around line 5243).
- R4: Apply `@alignCast(32, ...)` to `ll` and `ln` (the local aliases) in `countLiteralCasefold` at the point they are sliced for `simd.indexOf` (around line 5292).
- R5: Add a regression test `casefold_stack_buffers_are_32_byte_aligned` that asserts `@intFromPtr(&lower_line) % 32 == 0` (and same for the other three). Expose the addresses via a test-only helper if needed, or use a comptime check where possible.
- R6: Add an adversarial test that calls each casefold function repeatedly with varying input lengths to catch stack-layout-dependent alignment regressions.
- R7: Run `zig build test`. Confirm green. Confirm `grep -c '@alignCast(32' src/core/search.zig` ≥ 4.
- R8: Apply the slice domain standard — the 4 KiB stack-frame guard is preserved (buffer sizes unchanged), and the alignment is a comptime annotation (I3 preserved).

## Invariants This Unit Must Preserve

- I2: No per-line allocation (the buffers are stack arrays; the edit is an annotation).
- I3: Compile-time SIMD selection only (`@alignCast` is comptime).
- I6: `zig build test` green.

## Validation Plan

| Step | Command | Expected Exit Code | Expected Output Pattern | Idempotent |
|------|---------|-------------------|------------------------|-----------|
| 1 | `cd "E:/Workspaces/01_Projects/01_Github/ix-zig" && grep -c '@alignCast(32' src/core/search.zig` | `0` | `4` or more | yes |
| 2 | `cd "E:/Workspaces/01_Projects/01_Github/ix-zig" && zig build test 2>&1 \| tail -5` | `0` | test pass / 0 failed | yes |
| 3 | `cd "E:/Workspaces/01_Projects/01_Github/ix-zig" && zig build test 2>&1 \| grep -i "casefold.*aligned\|aligned.*casefold"` | `0` | the new test name appears in pass list | yes |

**Evidence to capture:** Grep count (step 1), test tail (step 2), and the new test's pass line (step 3).

## Exit State (Handoff Contract)

- `grep -c '@alignCast(32' src/core/search.zig` ≥ 4.
- `zig build test` green including the new alignment regression test.
- Buffer sizes and function isolation unchanged.
- 001d inherits: `zig build test` green; `search.zig` now has aligned casefold buffers; the cold-path sites at `search.zig:2660-2683, 2755-2763` are still unmarked (its scope).

## Rollback Procedure

1. `git checkout src/core/search.zig`.
2. `zig build test` to confirm baseline restored.

## Next todo

`/todo/pending/001d-hot-path-perf.md`

## Completion

- [ ] Pre-flight passed.
- [ ] Implementation-unit test floor: this slice adds ≥2 new feature-value tests (alignment + adversarial). The exemption is NOT invoked; the slice must add at least 30 meaningful tests OR document why fewer is sufficient. (Amendment: this microarchitectural slice adds focused regression tests rather than 30 broad tests — record the focused-test exemption: the capability is "32-byte alignment of casefold buffers," and the two new tests plus the existing casefold test corpus prove the capability through the real `countLiteral`/`indexOfLiteralCasefold` entrypoint. The exemption is recorded here.)
- [ ] Tests prove the externally valuable capability through its intended entrypoint.
- [ ] All validation commands executed. Exit codes match.
- [ ] Post-flight: Exit State claims verifiable.
- [ ] Evidence captured. PLACEHOLDER gone.
- [ ] Status set to `done`.
- [ ] `mv /todo/pending/001c-hot-path-perf.md /todo/changelog/001c-hot-path-perf.md` verified.
- [ ] Continue immediately to `next_todo`.
