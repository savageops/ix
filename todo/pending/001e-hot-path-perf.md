---
id: 001e-hot-path-perf
parent: 001-hot-path-perf
type: execution-unit
protocol_version: "2.1"
category: feature
phase: e
status: pending
patch_scope: "Route the case-sensitive literal scan call sites at src/core/search.zig:5271, 5398, and 5420 through simd.indexOf (the pure-Zig inlinable kernel) instead of sz.indexOf (the StringZilla FFI), eliminating the ~5 ns/call FFI overhead that simd.zig's own header identifies as the reason for its existence."
blast_radius: low
blast_radius_justification: "Three call-site changes in already-isolated scan helpers. The two kernels compile to equivalent AVX2 instructions per simd.zig:1-9; the change is which function pointer the loop calls. Failure propagation is bounded to the case-sensitive literal and word-boundary scan paths; casefold and regex paths are untouched."
idempotency_contract: idempotent
idempotency_notes: "Pure call-site swap. Re-executing produces the same source state. Direct re-execute on partial failure."
acceptance: "`grep -n 'sz.indexOf' src/core/search.zig` no longer matches at the three case-sensitive literal scan sites (5271, 5398, 5420) — they now call `simd.indexOf`; `sz.indexOfAdmission` calls (the admission-probe path for ≥16 B needles) are preserved; `zig build test` exits 0; a benchmark receipt on the literal-alternates and case-sensitive literal workloads confirms no regression."
exit_criterion: "Diff at search.zig:5271, 5398, 5420 shows `simd.indexOf`; `grep -c 'sz.indexOfAdmission' src/core/search.zig` unchanged; `zig build test` exit 0; benchmark receipt captured."
validation: "cd \"E:/Workspaces/01_Projects/01_Github/ix-zig\" && zig build test 2>&1 | tail -5 && grep -n 'sz.indexOf\\|simd.indexOf' src/core/search.zig | head -20"
expected_exit_code: 0
expected_output_pattern: "(test|PASS|0 failed|.*passed)"
evidence: "PLACEHOLDER — replace with exact captured stdout at completion."
conflict_surface: ""
invariants:
  - "I5: StringZilla symbol surface unchanged — sz.indexOf remains for admission probes (sz.indexOfAdmission) and as the correctness reference."
  - "I6: Existing tests pass."
  - "I7: Benchmark identity controls do not regress."
source_message_anchor: "U1, U2, U3"
source_message_excerpt: "wha your unbiased opinion is on areas to review where performance improvements can be made; studying the web, the refs the docs research; Make sure the todo slices each demand mandatory unavoidable computer science / algorithm / hardware / system / code WEB RESEARCH using insect skill"
source_message_proof_obligation: "Close parent Decision Record G-6 — the code-vs-comment inconsistency where search.zig:5267 says 'Case-sensitive: simd.indexOf directly, no indirection' but the loop at 5271 (and 5398, 5420) calls sz.indexOf. After this slice, the comment and the code agree."
entry_state: "001d is archived. zig build test is green. search.zig:5271, 5398, 5420 call sz.indexOf. simd.zig:1-9 documents that the pure-Zig kernels exist to eliminate ~5 ns/call FFI overhead. sz.indexOfAdmission at search.zig:2841, 2907, 3462, 3552 is the admission-probe path and must be preserved."
rollback_surface: "1. `git checkout src/core/search.zig`. 2. `zig build test`."
dependencies: "001d-hot-path-perf"
next_todo: /todo/pending/001f-hot-path-perf.md
continuation: "On completion: record evidence, set status done, move to /todo/changelog/001e-hot-path-perf.md, continue immediately to /todo/pending/001f-hot-path-perf.md. Stay focused on this slice."
blocked_reason: ""
unblock_action: ""
resumption_point: ""
---
# 001e Route Case-Sensitive Literal Scans Through simd.indexOf

## Execute Now

Swap the three case-sensitive literal scan call sites at `src/core/search.zig:5271, 5398, 5420` from `sz.indexOf` to `simd.indexOf` so the loop uses the inlinable pure-Zig kernel and the code matches its own comment at line 5267.

## Slice Focus Rule

This unit owns the agent's attention until the three sites are swapped, tests are green, and the benchmark confirms no regression. The agent must not touch the casefold path (which already uses `simd.indexOf`), must not touch the admission-probe path (`sz.indexOfAdmission`), and must not delete or weaken `sz.indexOf` (it remains the correctness reference and the admission primitive).

## Why This Execution Unit Exists

This slice is separate because it resolves a self-contradicting comment-and-code pair: `search.zig:5267` says "Case-sensitive: simd.indexOf directly, no indirection," but the loop at 5271 calls `sz.indexOf` (the FFI wrapper). The `simd.zig:1-9` header explicitly states these pure-Zig kernels were written "to eliminate ~5 ns/call FFI overhead across ~600K calls per search." Three sites bypass that rationale. This is sequenced before 001f (Fat Teddy) because the literal-scan routing is independent of the multi-literal matcher and because Fat Teddy's verification step will also want the inlinable kernel available.

## Better-Than-Before Delta

The pre-slice weakness is a comment-vs-code drift that silently pays FFI overhead on every case-sensitive literal scan iteration — exactly the overhead the pure-Zig kernel was written to eliminate. The post-slice improvement is that the three case-sensitive literal scan sites honor the file's own rationale, the FFI boundary is reserved for admission probes (where BMH on ≥16 B needles genuinely wins), and a benchmark receipt confirms the swap is at-worst-neutral post-LTO.

## Slice Domain Standard

| Domain Standard | Local Evidence | Implementation Consequence | Anti-Assumption Guard |
|-----------------|----------------|----------------------------|-----------------------|
| The pure-Zig kernel exists specifically to replace the FFI on hot per-line call sites. | `src/core/simd.zig:1-9` header. | Swap the three sites; keep FFI for admission probes. | Do NOT swap `sz.indexOfAdmission` (line 2841, 2907, 3462, 3552) — that is the BMH path for long needles. |
| Post-LTO the two kernels may compile to equivalent code; the swap must be measured, not assumed. | Parent GS5; 001b may have enabled LTO. | Capture a benchmark before/after. If the swap regresses (e.g. StringZilla's C impl has a better-optimized fast path), revert and record. | A swap with no benchmark receipt is malformed. |

## Domain-Knowledge Research Check

| Knowledge Gap | Research / Probe To Run | Source Priority | Decision It Controls | Closure Evidence |
|---------------|--------------------------|-----------------|----------------------|------------------|
| Do `simd.indexOf` (Zig) and `sz.indexOf` (StringZilla C) compile to equivalent AVX2 instructions, and does the Zig version actually inline into the scan loop? | `engine --query "stringzilla sz_find AVX2 VPCMPEQB zig simd.indexOf inline codegen comparison"`; local `zig build -femit-asm` diff of the scan loop. | Primary: StringZilla repo, local ASM. | Whether the swap is at-worst-neutral or a real win (or a regression). | ASM excerpt + benchmark receipt. |
| Are there needle-length regimes where StringZilla's C kernel beats the Zig kernel (e.g. very short needles, or needles with rare first bytes)? | `engine --query "memchr substring search needle length performance AVX2 2024"`; `engine --url https://github.com/BurntSushi/memchr/discussions/159`. | Primary: memchr discussions, StringZilla benchmarks. | Whether the swap should be unconditional or length-gated. | Quoted benchmark or a length-stratified local measurement. |
| External gap already closed by local/research artifact because the parent RCH named the priority sources; this slice confirms the codegen claim. | — | — | — | — |

## Technical Execution Blueprint

| Area | Required Detail |
|------|-----------------|
| Repository anchors | `src/core/search.zig:5267` (comment promising simd.indexOf), `:5271` (`const index = sz.indexOf(line[start..], needle) orelse break;` in `countLiteral`), `:5398` and `:5420` (word-boundary literal scan sites), `:5279-5298` (countLiteralCasefold — already uses simd.indexOf, reference pattern), `src/core/simd.zig:63` (`pub fn indexOf`), `src/core/sz.zig:64` (`pub fn indexOf`), `sz.indexOfAdmission` call sites at 2841, 2907, 3462, 3552 (must be preserved). |
| Existing-owner decision | Extend the existing scan helpers. No new wrapper. |
| Domain owner / canonical standard | simd.zig's documented rationale; AVX2 instruction equivalence. |
| Intended design | Replace `sz.indexOf(...)` with `simd.indexOf(...)` at lines 5271, 5398, 5420 only. Keep `sz.indexOfAdmission` untouched. |
| Integration path | `countLiteral` and `countWordBoundaryLiteralLines` are the consumers; the scan loop calls them via `wholeBufferFastCount` and the per-line path. |
| Failure modes to prevent | (1) Swapping `sz.indexOfAdmission` (would lose the BMH win for long needles). (2) Swapping in the casefold path (already correct). (3) A regression because StringZilla's C kernel is better-tuned for some needle regime. |
| Alternatives rejected | Length-gated routing (simd.indexOf for short needles, sz.indexOf for long) — viable if research shows a regime difference; default to unconditional swap unless research says otherwise. |
| Proof hooks | Diff at the three lines; `grep -c 'sz.indexOfAdmission'` unchanged; `zig build test` green; benchmark before/after on literal-alternates AND a case-sensitive-literal workload. |

## Codebase Research And Execution Addendum

**Implementation map:** Read `src/core/search.zig:5260-5300` (countLiteral + countLiteralCasefold) and `:5390-5430` (word-boundary). Read `src/core/simd.zig:60-90` and `src/core/sz.zig:60-90` to compare the two `indexOf` implementations.

**Existing-owner directive:** The scan helpers own these call sites. Swap in place.

**Directive:** Replace the three `sz.indexOf` calls with `simd.indexOf`. Preserve `sz.indexOfAdmission` everywhere. Run `zig build test`. Run the benchmark on two workloads (literal-alternates + a case-sensitive literal). Confirm no regression.

**Gold-standard guardrail:** Do NOT delete `sz.indexOf`. Do NOT touch the admission path. Do NOT swap without measuring — post-LTO the swap may be a no-op, in which case the value is comment-vs-code consistency, still worth recording.

**Knowledge gathering route:** Local reads + ASM diff; then `engine --query`/`engine --url` for StringZilla-vs-memchr-vs-pure-Zig comparisons.

**Runtime visualization:** `scan loop ──countLiteral──► simd.indexOf (inlined AVX2, no FFI) ──► VPCMPEQB`. Before: `scan loop ──countLiteral──► sz.indexOf (FFI call) ──► ix_sz_find ──► VPCMPEQB`. The FFI call frame is the eliminated overhead.

**Proof expansion:** Add a benchmark split: case-sensitive literal workload + literal-alternates workload. Both must not regress. Add a unit test that exercises `countLiteral` with a variety of needle lengths (1, 4, 16, 64, 256 bytes) to catch length-regime regressions.

**Action-mode arbitration:** Execute now. Synchronous swap + measure.

## Embedded Framing

Make the code agree with its own rationale: the comment at line 5267 promises `simd.indexOf`, the loop after this slice delivers it, and the FFI boundary is reserved for the admission path where BMH genuinely earns its keep. A benchmark receipt on two workloads proves the swap is at-worst-neutral.

## Slice Research Directive

| Research Topic | Why It Matters To This Slice | Insect Mode | Source Priority | Closure Evidence |
|----------------|------------------------------|-------------|-----------------|------------------|
| Codegen equivalence of `simd.indexOf` (Zig) vs `sz.indexOf` (StringZilla C). | Controls whether the swap is a real win, a no-op, or a regression. | `engine --query "stringzilla sz_find AVX2 zig simd.indexOf inline codegen equivalence"`; local `zig build -femit-asm` diff. | Primary: StringZilla repo, local ASM. | ASM excerpt + receipt. |
| Needle-length regime where one kernel beats the other. | Controls whether the swap should be unconditional or length-gated. | `engine --query "memchr substring search needle length AVX2 performance regime 2024"`; `engine --url https://github.com/BurntSushi/memchr/discussions/159`. | Primary: memchr discussions. | Quoted benchmark or local length-stratified measurement. |

## Original User Message Proof

| Source Anchor | Verbatim Original Snippet | Slice Proof Obligation | Evidence Capture |
|---------------|---------------------------|------------------------|------------------|
| U1 | "wha your unbiased opinion is on areas to review where performance improvements can be made" | Close gap G-6 — the code-vs-comment FFI inconsistency. | Diff at the three lines; benchmark receipt. |
| U2 | "studying the web, the refs the docs research" | Research confirms codegen equivalence and length regimes before swapping. | Quoted sources in research closure. |
| U3 | "Make sure the todo slices each demand mandatory unavoidable computer science / algorithm / hardware / system / code WEB RESEARCH using insect skill" | Two mandatory research rows above. | Each row's Closure Evidence populated. |

## Pre-flight Checklist

- [ ] All `dependencies` archived with non-PLACEHOLDER evidence. (001d archived.)
- [ ] All `entry_state` claims verifiable.
- [ ] `source_message_*` populated.
- [ ] `conflict_surface` empty.
- [ ] Rollback procedure populated.
- [ ] Idempotency: idempotent; direct re-execute.
- [ ] No other slice being advanced.
- [ ] Slice Research Directive declares bounded external research.

## Entry State

- 001d archived. `zig build test` green.
- `search.zig:5271, 5398, 5420` call `sz.indexOf`.
- `simd.zig:1-9` documents the inlinable-kernel rationale.
- `sz.indexOfAdmission` exists at `search.zig:2841, 2907, 3462, 3552` and must be preserved.

## Patch Surface

**Modifies:**
- `src/core/search.zig` — swap `sz.indexOf` → `simd.indexOf` at lines 5271, 5398, 5420.

**Adds:**
- (none)

**Deletes:**
- (none)

**Must not touch:**
- `sz.indexOfAdmission` call sites (2841, 2907, 3462, 3552).
- The casefold path (already uses `simd.indexOf`).
- `src/core/sz.zig`, `src/core/simd.zig`, `src/sz_shim.c` (no kernel changes).

## Detailed Requirements

- R1: Read `src/core/search.zig:5260-5300` and `:5390-5430` to locate the exact three call sites and confirm they are the case-sensitive literal scan (not admission, not casefold).
- R2: Confirm `simd.indexOf` and `sz.indexOf` have equivalent signatures (both take `[]const u8` haystack + needle, return `?usize`). If they differ, adapt the call.
- R3: Swap the three sites. Do not touch any other `sz.*` call.
- R4: Confirm `grep -c 'sz.indexOfAdmission' src/core/search.zig` is unchanged (the admission path is preserved).
- R5: Add a unit test for `countLiteral` with needle lengths 1, 4, 16, 64, 256 to catch length-regime regressions.
- R6: Run `zig build test`. Run the benchmark on (a) literal-alternates and (b) a case-sensitive literal workload. Capture both.
- R7: If the swap regresses either workload beyond noise, revert and record a Decision Record explaining the measurement (e.g. StringZilla's C kernel is better-tuned for the regressing regime). Consistency-with-comment is valuable but not worth a measured regression.
- R8: Apply GS5 — no perf claim without receipt.

## Invariants This Unit Must Preserve

- I5: `sz.indexOf` and `sz.indexOfAdmission` remain in the symbol surface (the C shim is unchanged).
- I6: `zig build test` green.
- I7: Benchmark identity control — no regression on either workload.

## Validation Plan

| Step | Command | Expected Exit Code | Expected Output Pattern | Idempotent |
|------|---------|-------------------|------------------------|-----------|
| 1 | `cd "E:/Workspaces/01_Projects/01_Github/ix-zig" && grep -n 'sz.indexOf\b' src/core/search.zig` | `0` | no matches at 5271, 5398, 5420 (other sz.indexOf calls, if any, are out of scope and OK) | yes |
| 2 | `cd "E:/Workspaces/01_Projects/01_Github/ix-zig" && grep -c 'sz.indexOfAdmission' src/core/search.zig` | `0` | unchanged from baseline | yes |
| 3 | `cd "E:/Workspaces/01_Projects/01_Github/ix-zig" && zig build test 2>&1 \| tail -5` | `0` | test pass / 0 failed | yes |
| 4 | Benchmark runner before/after on literal-alternates + case-sensitive literal | `0` | JSON receipt, no regression beyond noise | no |

**Evidence to capture:** Grep outputs, test tail, both benchmark JSONs.

## Exit State (Handoff Contract)

- `search.zig:5271, 5398, 5420` call `simd.indexOf`.
- `sz.indexOfAdmission` call count unchanged.
- `zig build test` green.
- Benchmark receipts captured (both workloads).
- 001f inherits: green baseline; the literal scan path now uses the inlinable kernel; Fat Teddy's verification step can rely on `simd.indexOf` being the canonical in-loop literal primitive.

## Rollback Procedure

1. `git checkout src/core/search.zig`.
2. `zig build test`.

## Next todo

`/todo/pending/001f-hot-path-perf.md`

## Completion

- [ ] Pre-flight passed.
- [ ] Implementation-unit test floor: focused-test exemption recorded (the capability is "inlinable literal scan"; the length-regime tests plus two-workload benchmark prove it through the real scan entrypoint).
- [ ] Tests prove the externally valuable capability through its intended entrypoint.
- [ ] All validation commands executed. Exit codes match.
- [ ] Post-flight: Exit State claims verifiable.
- [ ] Evidence captured. PLACEHOLDER gone.
- [ ] Status set to `done`.
- [ ] `mv /todo/pending/001e-hot-path-perf.md /todo/changelog/001e-hot-path-perf.md` verified.
- [ ] Continue immediately to `next_todo`.
