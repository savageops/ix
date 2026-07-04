---
id: 002e-frontier-absorption
parent: 002-frontier-absorption
type: execution-unit
protocol_version: "2.1"
category: feature
phase: e
status: pending
patch_scope: "Add a pure-Zig Shufti byte-class primitive (two 16-byte PSHUFB tables + AND, per Langdale's SMH post and Vectorscan nfa/shufti.*) to src/core/simd.zig as a new shufti namespace, providing shuftiCompile(byte_set) -> ShuftiMask and shuftiFirstMatch(haystack, mask) ?usize that classify 32 bytes in three SIMD ops, inlinable into tight character-class scan loops."
blast_radius: low
blast_radius_justification: "Additive change to simd.zig (a new namespace, no modification to existing indexOfByte/indexOf). Failure propagation bounded to callers of the new primitive (currently none — this slice adds the primitive plus tests, no caller wiring). The existing indexOfByteSet FFI (sz.zig:139) is untouched and remains the byteset-over-haystack path."
idempotency_contract: idempotent
idempotency_notes: "Pure additive source edit. Re-executing produces the same state. Direct re-execute on partial failure."
acceptance: "simd.zig exports a shufti namespace with ShuftiMask, shuftiCompile, and shuftiFirstMatch; the mask construction produces correct lo/hi tables for arbitrary byte sets; shuftiFirstMatch classifies 32 bytes correctly across the byte alphabet; @Vector(32, u8) only (no runtime dispatch, no AVX-512); existing simd.zig tests pass unchanged; new tests cover alphabet partitions, single-byte sets, empty/full sets, and first-match at every offset; benchmark receipt on a synthetic character-class workload shows the primitive is at least as fast as the FFI path for repeated queries."
exit_criterion: "`grep -c 'shufti\\|Shufti\\|SHUFTI' src/core/simd.zig` ≥ 1 AND `zig build test` exit 0 AND new Shufti tests pass AND `grep -c 'cpuid\\|runtime.*dispatch' src/core/simd.zig` == 0 AND benchmark receipt captured."
validation: "cd \"E:/Workspaces/01_Projects/01_Github/ix-zig\" && zig build test 2>&1 | tail -5 && grep -n 'shufti\\|Shufti' src/core/simd.zig"
expected_exit_code: 0
expected_output_pattern: "(test|PASS|0 failed|.*passed)"
evidence: "PLACEHOLDER — replace with exact captured stdout at completion."
conflict_surface: "001d-hot-path-perf (shares src/core/simd.zig — 001d marks indexOfByte's error path cold, this slice adds a new namespace; coordinate per 002a handoff)"
invariants:
  - "I3: Compile-time SIMD only — Shufti uses @Vector(32, u8) and @shuffle / @select lowering of PSHUFB; no runtime dispatch, no cpuid, no AVX-512-specific intrinsics."
  - "I5: StringZilla symbol surface unchanged — the new primitive is pure Zig, no new C ABI."
  - "I6: Existing tests pass."
source_message_anchor: "U4, U5, U9"
source_message_excerpt: "Default to copying or tightly adapting proven algorithms; SZ_DYNAMIC_DISPATCH=0; (survey Tier S1: Shufti, citing Langdale SMH post + Vectorscan nfa/shufti.*)"
source_message_proof_obligation: "Close Decision Record G-4 by adding a pure-Zig Shufti primitive that classifies 32 bytes via two PSHUFB lookups + AND, inlinable into callers, with no runtime dispatch."
entry_state: "002d is archived. zig build test is green. simd.zig has indexOfByte and indexOf (now 3-byte from 002b) but no Shufti primitive. byte-class queries route through sz.indexOfByteSet (FFI). The SMH post (branchfree.org/2018/05/30/smh-...) and Vectorscan nfa/shufti.* are the references."
rollback_surface: "1. `git checkout src/core/simd.zig`. 2. `zig build test`."
dependencies: "002d-frontier-absorption, 002b-frontier-absorption (shares simd.zig — must be archived first)"
next_todo: /todo/pending/002f-frontier-absorption.md
continuation: "On completion: record evidence, set status done, move to /todo/changelog/002e-frontier-absorption.md, continue immediately to /todo/pending/002f-frontier-absorption.md. Stay focused on this slice."
blocked_reason: ""
unblock_action: ""
resumption_point: ""
---
# 002e Pure-Zig Shufti Byte-Class Primitive

## Execute Now

Harvest the Shufti mask-construction algorithm from Langdale's SMH post and Vectorscan `nfa/shufti.*`, then implement a pure-Zig `shufti` namespace in `src/core/simd.zig` with `ShuftiMask`, `shuftiCompile(byte_set)`, and `shuftiFirstMatch(haystack, mask) ?usize` that classifies 32 bytes via two `@Vector(16, u8)` PSHUFB-eligible lookups + AND, with no runtime dispatch.

## Slice Focus Rule

This unit owns the agent's attention until the primitive is implemented, tested across the byte alphabet, the ASM confirms two PSHUFBs, and the benchmark confirms parity-or-better vs the FFI path. The agent must not modify `indexOfByte` or `indexOf` (002b's territory), must not touch `sz.indexOfByteSet` (the FFI stays), must not use CLMUL (DP-2), must not use runtime dispatch (I3), and must not wire callers in this slice — the primitive lands first; caller migration is a follow-up.

## Why This Execution Unit Exists

This slice is separate because Shufti is an additive primitive (a new namespace), the lowest-risk shape in the chain. It is sequenced last among the absorptions so that 002b's `indexOf` change and this slice's new namespace don't collide mid-edit, and so the chain ends on a positive additive note before the review.

## Better-Than-Before Delta

The pre-slice weakness is that tight character-class scan loops (the kind that will be needed by Rose-lite dispatch, bit-parallel regex verifiers, and any future "skip to next interesting byte" prefilter) have no inlinable Zig primitive — they must either loop per-byte or pay FFI to `sz.indexOfByteSet`. The post-slice improvement is a pure-Zig primitive that classifies 32 bytes in three ops (two PSHUFB + one VPAND) + a VPMOVMSKB extract, inlines into any caller, and serves as the foundation for the survey's Tier-A follow-on work (Rose-lite, Glushkov NFA, Sheng DFA). The ASM regression test pins the SIMD lowering.

## Slice Domain Standard

| Domain Standard | Local Evidence | Implementation Consequence | Anti-Assumption Guard |
|-----------------|----------------|----------------------------|-----------------------|
| Shufti is two 16-byte PSHUFB lookups (lo nibble, hi nibble) + AND. | Langdale "SMH: Swiss Army Chainsaw" post (branchfree.org/2018/05/30/...); Vectorscan `nfa/shufti.{cpp,h}` + `shufticompile.*`. | Implement `shuftiCompile` that builds two `[16]u8` tables; `shuftiFirstMatch` that broadcasts each input byte's lo/hi nibble, shuffles both tables, ANDs, extracts. | A "shufti" that uses a 256-byte lookup table is not Shufti — it's a plain LUT and loses the SIMD width. |
| Zig lowers `@shuffle` on `@Vector(16, u8)` to `vpshufb` on AVX2. | `simd.zig:1-15` documents that `@Vector` lowers to the expected AVX2 instructions. | Use `@shuffle` / `a[a_index]` indexing on `@Vector(16, u8)`; verify via `zig build -femit-asm`. | Using `@Vector(32, u8)` and a 32-byte table would still lower correctly but diverges from the canonical 16-byte Shufti form; prefer the canonical form for portability. |

## Domain-Knowledge Research Check

| Knowledge Gap | Research / Probe To Run | Source Priority | Decision It Controls | Closure Evidence |
|---------------|--------------------------|-----------------|----------------------|------------------|
| Exact mask-construction algorithm. | `engine --url https://branchfree.org/2018/05/30/smh-the-swiss-army-chainsaw-of-shuffle-based-matching-sequences/`; local grep of `.docs/research/hyperscan-teddy.c.snapshot` lines 199-210 for the `TEDDY_VBMI_PSHUFB_OR_*` macros (a related but AVX-512 form). | Primary: SMH post + Vectorscan `nfa/shufti*`. | The exact `shuftiCompile` algorithm. | Quoted mask algorithm + Zig port. |
| How to express PSHUFB in Zig. | `engine --query "zig @shuffle @Vector 16 u8 vpshufb AVX2 lower codegen"`; local `zig build -femit-asm`. | Primary: Zig docs + local codegen. | Whether to use `@shuffle` or indexed-load on a vector splat. | ASM excerpt showing `vpshufb`. |
| How to handle the >16-byte haystack (Shufti is 16-byte; AVX2 is 32-byte). | `engine --query "shufti 32 byte AVX2 two 16-byte halves implementation"`. | Primary: Vectorscan `shufti_simd.hpp`. | Whether to process 16 bytes at a time or double-up for 32. | Documented choice. |

## Technical Execution Blueprint

| Area | Required Detail |
|------|-----------------|
| Repository anchors | `src/core/simd.zig:1-15` (header comment), `:17-50` (the indexOfByte pattern to mirror in spirit), `src/core/sz.zig:47-53` (the existing `ByteSet` 256-bit bitmap — reference for the input shape), `src/core/sz.zig:139` (the `indexOfByteSet` FFI — stays). `.refs/stringzilla/include/stringzia/find.h` (no Shufti; reference is external). `.docs/research/hyperscan-teddy.c.snapshot:199-210` (related PSHUFB macros for AVX-512 form — informational). |
| Existing-owner decision | Add a new `shufti` namespace to `simd.zig`. No new module. |
| Domain owner / canonical standard | Langdale SMH post + Vectorscan `nfa/shufti*`. |
| Intended design | (1) `pub const ShuftiMask = struct { lo: [16]u8, hi: [16]u8 }`. (2) `pub fn shuftiCompile(set: []const u8) ShuftiMask` — for each byte `b` in the set, set the bit `1 << (b & 0x0f)` in `lo[b >> 4]` and the bit `1 << (b >> 4)` in `hi[b & 0x0f]`. Wait — correct algorithm: for each byte `b` in the set, the result of `vpshufb(lo, broadcast(b & 0x0f))` AND `vpshufb(hi, broadcast(b >> 4))` must be nonzero for `b` and zero for non-`b`. So: for each `b` in set, set bit `(b & 0x0f)` in `lo[b >> 4]`... no. The canonical construction: classify each byte `b` by its lo nibble and hi nibble independently; the AND requires both to vote yes. Standard construction: for each `b` in the set, OR `1 << (b & 0x0f)` into `lo_for_hi_nibble[b >> 4]`... The exact construction is non-trivial; harvest it from Vectorscan `shufticompile.cpp` before implementing. (3) `pub fn shuftiFirstMatch(haystack: []const u8, mask: ShuftiMask) ?usize` — load 16/32 bytes, compute `lo_lookup = vpshufb(mask.lo, lo_nibbles_of_haystack)`, `hi_lookup = vpshufb(mask.hi, hi_nibbles_of_haystack)`, `result = lo_lookup & hi_lookup`, `movemask + ctz` to find the first nonzero byte. |
| Integration path | No callers wired in this slice. The primitive's proof is its own tests + ASM + benchmark vs `sz.indexOfByteSet` on a synthetic character-class workload. |
| Failure modes to prevent | (1) Wrong mask construction (silent misclassification). (2) Using a 256-byte LUT instead of two 16-byte tables (loses SIMD width). (3) Runtime dispatch (I3 violation). (4) Out-of-bounds on the >16-byte tail. |
| Alternatives rejected | CLMUL (DP-2). A 256-byte bitmap + popcount (loses width). Wiring callers in this slice (premature; primitive first). |
| Proof hooks | Tests: empty set (no matches), full set (every byte matches), single-byte set at each of 256 positions, common classes ([a-z], [A-Z], [0-9], whitespace, identifier-chars), first-match at offsets 0/1/15/16/31/end. ASM diff confirming `vpshufb` ×2 + `vpand` + `vpmovmskb`. Benchmark vs `sz.indexOfByteSet` on a synthetic class-scan workload. |

## Codebase Research And Execution Addendum

**Implementation map:** Read `src/core/simd.zig` in full. Read `.docs/research/hyperscan-teddy.c.snapshot:199-210` for a related (AVX-512) PSHUFB form. Harvest the exact mask construction from the SMH post and Vectorscan `shufticompile.cpp` (the latter may not be vendored — confirm via `find .refs -name 'shufti*'`).

**Existing-owner directive:** `simd.zig` is the canonical SIMD owner. Add the namespace there.

**Directive:** Harvest the canonical mask-construction from Vectorscan/SMH. Implement `ShuftiMask`, `shuftiCompile`, `shuftiFirstMatch` with `@Vector(16, u8)` + `@shuffle`. Add tests. Verify ASM. Benchmark vs `sz.indexOfByteSet`. Do NOT wire callers.

**Gold-standard guardrail:** Do NOT use CLMUL (DP-2). Do NOT use runtime dispatch (I3). Do NOT use a 256-byte LUT. Do NOT modify `indexOf`/`indexOfByte`.

**Knowledge gathering route:** `engine --url` for SMH and (if not vendored) Vectorscan source. Local `find .refs -name 'shufti*'`. Local `zig build -femit-asm`.

**Runtime visualization:** `shuftiCompile({a, b, c}) ──► ShuftiMask{lo, hi}`; `shuftiFirstMatch(haystack, mask) ──@Vector(16,u8) load──► lo_nibbles, hi_nibbles ──vpshufb(lo, lo_nibbles) & vpshufb(hi, hi_nibbles)──► per-byte nonzero? ──vpmovmskb + ctz──► first match offset`.

**Proof expansion:** Tests: empty set (returns null), full set (returns 0), single-byte set for each of 256 bytes (returns first occurrence), common classes ([a-z] etc.), first-match at offsets 0, 1, 15, 16, 31, end. Add a fuzz-style test that picks random subsets and verifies against a scalar reference. ASM test: assert the compiled output contains `vpshufb` (via `zig build -femit-asm` + grep). Benchmark: a loop scanning a 1 MiB buffer for class [a-z] members, comparing Shufti vs `sz.indexOfByteSet` wall-clock.

**Action-mode arbitration:** Execute now. Synchronous harvest + implement + test + benchmark.

## Embedded Framing

Add the Shufti primitive that the survey identified as the highest ratio of value to effort: two PSHUFB lookups + AND classifies 32 bytes in three ops, pure-Zig, inlinable, no CLMUL, no runtime dispatch. ASM and a class-scan benchmark prove it earns its place as the foundation for Tier-A follow-on chains.

## Slice Research Directive

| Research Topic | Why It Matters To This Slice | Insect Mode | Source Priority | Closure Evidence |
|----------------|------------------------------|-------------|-----------------|------------------|
| Canonical Shufti mask construction. | Controls correctness — wrong construction silently misclassifies. | `engine --url https://branchfree.org/2018/05/30/smh-...`; `engine --query "vectorscan shufticompile.cpp mask construction source"`. | Primary: SMH post + Vectorscan. | Quoted algorithm + Zig port. |
| Zig `@shuffle`/indexing lowering to `vpshufb`. | Confirms I3 (compile-time SIMD) and the 16-byte form. | Local `zig build -femit-asm`; `engine --query "zig @shuffle @Vector 16 u8 vpshufb AVX2"`. | Primary: local codegen. | ASM excerpt. |
| 16-byte vs 32-byte Shufti form on AVX2. | Controls the loop width (16-byte single, or 32-byte doubled). | `engine --query "shufti 32 byte AVX2 two 16-byte halves vectorscan simd"`. | Primary: Vectorscan `shufti_simd.hpp`. | Documented choice. |

## Original User Message Proof

| Source Anchor | Verbatim Original Snippet | Slice Proof Obligation | Evidence Capture |
|---------------|---------------------------|------------------------|------------------|
| U4 | "Default to copying or tightly adapting proven algorithms" (AGENTS.md) | Harvest the SMH/Vectorscan mask construction before implementing. | Quoted algorithm in design notes. |
| U5 | "`SZ_DYNAMIC_DISPATCH=0`. No runtime feature detection." (AGENTS.md) | Lock the no-runtime-dispatch invariant for the new primitive. | `grep -c "cpuid\|runtime.*dispatch" src/core/simd.zig` == 0; ASM excerpt. |
| U9 | (survey Tier S1: Shufti) | Close gap G-4 by adding the pure-Zig Shufti primitive. | `grep` hits + tests + ASM + benchmark. |

## Pre-flight Checklist

- [ ] All `dependencies` archived. (002b and 002d archived — 002b because it shares simd.zig.)
- [ ] All `entry_state` claims verifiable.
- [ ] `source_message_*` populated.
- [ ] `conflict_surface` documents the 001d handoff.
- [ ] Rollback procedure populated.
- [ ] Idempotency: idempotent; direct re-execute.
- [ ] No other slice being advanced. Check 001d's state before editing `simd.zig`.
- [ ] Slice Research Directive declares bounded research.

## Entry State

- 002b and 002d archived. `zig build test` green.
- `simd.zig` has `indexOfByte` and `indexOf` (3-byte from 002b); no Shufti.
- `sz.indexOfByteSet` (FFI) is the current byte-class path.

## Patch Surface

**Modifies:**
- `src/core/simd.zig` — add `shufti` namespace (`ShuftiMask`, `shuftiCompile`, `shuftiFirstMatch`); add tests.

**Adds:** (tests in-file)
**Deletes:** (none)
**Must not touch:** `src/core/simd.zig::indexOf` (002b's territory), `::indexOfByte` (001d's territory), `src/core/sz.zig`, `src/sz_shim.c`, `build.zig`.

## Detailed Requirements

- R1: Harvest the canonical mask construction from the SMH post and Vectorscan (via Slice Research Directive) before implementing.
- R2: Add `pub const ShuftiMask = struct { lo: [16]u8, hi: [16]u8 }`.
- R3: Add `pub fn shuftiCompile(set: []const u8) ShuftiMask` implementing the canonical construction.
- R4: Add `pub fn shuftiFirstMatch(haystack: []const u8, mask: ShuftiMask) ?usize` using `@Vector(16, u8)` and `@shuffle` (or equivalent) for the two PSHUFB lookups, AND-combine, VPMOVMSKB, TZCNT.
- R5: Handle the >16-byte haystack by looping 16 bytes at a time, with a scalar tail.
- R6: Add tests: empty set, full set, single-byte set for each of 256 bytes, common classes, first-match at offsets 0/1/15/16/31/end, fuzz vs scalar reference.
- R7: Run `zig build test`. Verify via `zig build -femit-asm` that the kernel emits `vpshufb` ×2 + `vpand` + `vpmovmskb`. Benchmark vs `sz.indexOfByteSet` on a 1 MiB class-scan workload.
- R8: Apply I3 — `@Vector` only, no runtime dispatch, no CLMUL.

## Invariants This Unit Must Preserve

- I3: Compile-time SIMD only (`@Vector`, no cpuid, no AVX-512-specific intrinsics).
- I5: StringZilla symbol surface unchanged (no new C ABI).
- I6: Existing tests pass.

## Validation Plan

| Step | Command | Expected Exit Code | Expected Output Pattern | Idempotent |
|------|---------|-------------------|------------------------|-----------|
| 1 | `cd "E:/Workspaces/01_Projects/01_Github/ix-zig" && grep -c "shufti\|Shufti\|SHUFTI" src/core/simd.zig` | `0` | ≥1 | yes |
| 2 | `cd "E:/Workspaces/01_Projects/01_Github/ix-zig" && grep -c "cpuid\|runtime.*dispatch" src/core/simd.zig` | `0` | `0` | yes |
| 3 | `cd "E:/Workspaces/01_Projects/01_Github/ix-zig" && zig build test 2>&1 \| tail -5` | `0` | test pass / 0 failed | yes |
| 4 | `cd "E:/Workspaces/01_Projects/01_Github/ix-zig" && zig build -femit-asm ... && grep -c "vpshufb" <asm>` | `0` | ≥2 (two PSHUFBs) | yes |
| 5 | Benchmark: Shufti vs sz.indexOfByteSet on 1 MiB class-scan | `0` | parity or better | no |

**Evidence to capture:** Greps, test tail, ASM excerpt, benchmark JSON.

## Exit State (Handoff Contract)

- `simd.zig` exports the `shufti` namespace with `ShuftiMask`, `shuftiCompile`, `shuftiFirstMatch`.
- Existing `indexOfByte`/`indexOf` tests pass unchanged.
- New Shufti tests pass across the byte alphabet + fuzz.
- ASM confirms `vpshufb` ×2.
- Benchmark confirms parity-or-better vs `sz.indexOfByteSet`.
- 002f inherits: all four absorptions (b–e) archived; the chain is ready for review.

## Rollback Procedure

1. `git checkout src/core/simd.zig`.
2. `zig build test`.

## Next todo

`/todo/pending/002f-frontier-absorption.md`

## Completion

- [ ] Pre-flight passed.
- [ ] Implementation-unit test floor: ≥30 tests OR focused-test exemption. (Amendment: this slice adds ≥30 alphabet-coverage + fuzz tests for the new primitive — the test floor is met directly.)
- [ ] Tests prove capability through entrypoint (the primitive's own API is the entrypoint).
- [ ] All validation commands executed. Exit codes match.
- [ ] Post-flight: Exit State claims verifiable.
- [ ] Evidence captured. PLACEHOLDER gone.
- [ ] Status set to `done`.
- [ ] `mv /todo/pending/002e-frontier-absorption.md /todo/changelog/002e-frontier-absorption.md` verified.
- [ ] Continue immediately to `next_todo`.
