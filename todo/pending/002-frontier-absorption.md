---
id: 002-frontier-absorption
type: parent
protocol_version: "2.1"
spec_status: approved
category: feature
status: pending
epic_boundary: "Absorb four high-leverage frontier techniques the prior research survey identified as currently-absent from IX but tightly-fit to its workload: a rarity-pivoted 3-byte SIMD literal fingerprint (StringZilla's `sz_locate_needle_anomalies_`), the PCRE2 `pcre2_jit_match_8` fast-path that bypasses per-line sanity checks, an adaptive galloping dispatch in `intersectFileIds` (Demaine SODA 2000), and a pure-Zig Shufti (2× PSHUFB) byte-class primitive for character-class scanning."
subtodo_start: /todo/pending/002a-frontier-absorption.md
subtodo_final: /todo/pending/002f-frontier-absorption.md
continuation: "After each completed execution unit: record evidence, set status done, move to /todo/changelog/, continue immediately to next_todo. Stay focused on one slice at a time. Never batch-archive. Never pause between units."
source_message_policy: "Every lettered unit MUST include source_message_anchor, source_message_excerpt, source_message_proof_obligation, and an Original User Message Proof section with verbatim snippets from the original user message."
---
# 002 Frontier Absorption: 3-Byte Fingerprint, JIT Bypass, Galloping Intersection, Shufti

## Objective

This chain closes four high-leverage gaps surfaced by the 2026-07-04 frontier research survey (`.docs/research/2026-07-04-zoom-out-non-teddy-frontier.md` and the six parallel deep-dives that followed). The system boundary is the per-byte literal scan path (`src/core/simd.zig`), the regex verifier (`src/core/pcre_regex.zig`), the posting-list intersection (`src/core/postings.zig::intersectFileIds`), and the byte-class prefilter surface (`src/core/sz.zig::indexOfByteSet` plus future character-class consumers). The intended long-run shape is a scan-and-admit pipeline where the literal fingerprint rejects false candidates at one-third the current rate, the regex verifier skips PCRE2's per-line sanity-check overhead, the posting intersection is comparison-optimal under skewed set sizes, and the byte-class prefilter runs at 1 cycle/byte instead of the per-byte loop the current StringZilla FFI incurs for small sets.

The canonical deliverable is four independently-shippable absorption slices, each grounded in a primary source already vendored or cited in the survey, each validated by a measurement (benchmark receipt on the literal-alternates and case-sensitive literal workloads, plus the existing `zig build test` regression), and each leaving a structural improvement that makes the next frontier chain (Fat Teddy in `001f`, Rose-lite dispatch, Sheng DFA) plug into a faster substrate.

## Rationale

The survey established that IX's current literal scan uses a 2-byte (first+last) fingerprint in the hot inlinable path (`simd.zig:63-109`) even though StringZilla's vendored reference uses a rarity-pivoted 3-byte fingerprint (`find.h:293-322`, `1064-1085`) that multiplicatively cuts false-positive verifications. The same survey established that IX's PCRE2 caller invokes `pcre2_match_8` (`pcre_regex.zig:139, 165`) — the interpreter entry that re-validates UTF and callouts on every line — even though PCRE2 exposes `pcre2_jit_match_8` (`pcre2.h.in:783-784`) which "bypasses all sanity checks" per the header comment, and IX has already JIT-compiled the pattern. The posting intersection at `postings.zig:990-1008` is a textbook two-pointer merge that always touches every element of both inputs; the Demaine SODA 2000 adaptive bound shows the comparison-optimal answer is galloping-search when set-size ratios exceed ~8:1, which is exactly the rare-vs-common trigram shape. And the byte-class prefilter (`sz.zig:139 indexOfByteSet`) routes through the StringZilla FFI for a primitive that the Hyperscan/Vectorscan lineage (Langdale's "SMH: Swiss Army Chainsaw" post) shows can be done in pure Zig at 1 cycle/byte via two PSHUFB lookups + an AND.

These four are sequenced cheapest-first to compound evidence momentum: 3-byte fingerprint and `pcre2_jit_match_8` are near-mechanical ports from already-vendored references; galloping intersection is ~20 lines with no new data structures; Shufti is the only new primitive. None overlap with the `001-hot-path-perf` patch surface except the shared `simd.zig` file (this chain's 3-byte fingerprint at the `indexOf` body, vs `001`'s cold-path marking and alignment — different functions, ordered to avoid concurrent conflict). Downstream surfaces that depend on completion are the `001` chain's Fat Teddy slice (`001f` will benefit from a faster literal primitive), the warm-index fast path (`postings.zig` query time), and the AGENTS.md Tier 4/5 entries that currently assume these primitives exist.

## Domain Expertise Baseline

| Domain Question | Current Evidence | Gold-Standard Requirement | What This Chain Must Not Assume |
|-----------------|------------------|---------------------------|---------------------------------|
| What is the optimal literal fingerprint width for AVX2? | IX `simd.zig:63-109` uses first+last (2-byte). StringZilla `find.h:1064-1085` uses first+mid+last (3-byte) with rarity pivoting. | The StringZilla reference is the production-grade implementation; Langdale's "anomaly locator" comment (`find.h:283-291`) gives the exact rationale (avoid wasting SIMD lanes on repeated bytes). | Do not invent a 4-byte fingerprint; do not skip the rarity-pivot collision-avoidance pass. |
| Is `pcre2_jit_match_8` a real bypass, or does it just dispatch to JIT like `pcre2_match_8`? | PCRE2 header comment at `pcre2.h.in:170-174`: "pcre2_jit_match() bypasses all sanity checks." `pcre2_jit_match.c:91-200` jumps straight into JIT code. | The bypass is real: it skips UTF validity, callouts, and recursion-limit re-checks on every call. IX has already validated at compile time. | Do not call `pcre2_jit_match_8` without first checking JIT is supported (returns `PCRE2_ERROR_JIT_BADOPTION`); keep `pcre2_match_8` as the fallback. |
| What is the adaptive set-intersection optimum? | IX `intersectFileIds` (`postings.zig:990-1008`) is `O(|a|+|b|)` two-pointer merge. | Demaine, López-Ortiz, Munro SODA 2000 "Adaptive Set Intersections, Unions, and Differences" — within 8k of optimal; galloping search achieves it when size ratios exceed ~8:1. This is what Roaring's array-array kernel and TimSort's merge use. | Do not switch to hash-based intersection; do not change the rarest-first ordering in `evaluateLookupGroup` (`postings.zig:738-842`) — that stays and now pays off more. |
| What is Shufti and when does it beat `sz_find_byteset`? | IX routes byte-class queries through `sz.indexOfByteSet` (`sz.zig:139`) → `ix_sz_find_byteset` FFI (`sz_shim.c:58`). | Langdale "SMH" post + Vectorscan `nfa/shufti.*`: two 16-byte PSHUFB tables (lo nibble, hi nibble) + AND classifies 16/32 bytes in 3 ops. Beats the FFI by inlining into the caller. | Do not replace `indexOfByteSet` (the FFI remains the byteset-over-haystack primitive); add Shufti as an inlinable Zig primitive for tight loops where the same byte-set is queried repeatedly. Do not use CLMUL (DP-2). |

## Gold-Standard Decision Criteria

| Criterion ID | Decision Rule | Evidence Required Before Selection | Review Failure Signal |
|--------------|---------------|------------------------------------|-----------------------|
| GS1 | Prefer vendored reference implementations over local reinvention (AGENTS.md "Frontier Research And Source Reuse"). | 002b reads StringZilla `find.h:293-322` before designing; 002c reads PCRE2 `pcre2.h.in:783` and `pcre2_jit_match.c:91`; 002e reads the SMH post and Vectorscan `nfa/shufti.*`. | A fingerprint/JIT-bypass/Shufti design that does not map to the reference. |
| GS2 | Measurement gates every performance claim (parent `001` GS5, inherited). | 002b, 002c, 002d, 002e each capture a benchmark before/after receipt on the literal-alternates and case-sensitive literal workloads. | A change with no benchmark receipt in the evidence field. |
| GS3 | No new wrapper module — extend existing owners (parent `001` GS4, inherited). | 002b extends `simd.zig::indexOf`; 002c extends `pcre_regex.zig::column/count`; 002d extends `postings.zig::intersectFileIds`; 002e extends `simd.zig` with a new `shufti` namespace. | A new `fingerprint.zig`, `jit_bypass.zig`, `intersection.zig`, or `byte_class.zig` module. |
| GS4 | Pure Zig + AVX2 only (AGENTS.md invariant 5, "compile-time SIMD only"). | All new kernels use `@Vector(32, u8)`; no runtime dispatch; no cpuid; no AVX-512-specific intrinsics in this chain. | Runtime CPU detection or AVX-512-locked code. |
| GS5 | Frontier-rejected items stay rejected (parent `001` DP-1 through DP-4, inherited). | No slice introduces CLMUL, inner-loop `@prefetch`, SIMD-AC, or io_uring. | A slice smuggling in a frontier-rejected technique. |

## Repository Ownership Reconnaissance

| Question | Evidence Found | Planning Consequence | Anti-Assumption Guard |
|----------|----------------|----------------------|-----------------------|
| Current canonical owners | `src/core/simd.zig:63-109` (`indexOf`, 2-byte fingerprint); `src/core/pcre_regex.zig:139, 165` (the two `pcre2_match_8` call sites); `src/core/postings.zig:990-1008` (`intersectFileIds`); `src/core/sz.zig:139` (`indexOfByteSet` FFI). | Each slice extends exactly one owner in place. | Do not create `simd_fingerprint.zig`, `intersection_v2.zig`, etc. |
| Adjacent or duplicate owners | `src/core/sz.zig::indexOf` (the FFI path, also a literal finder but not inlined); `src/core/literal_alternates.zig` (Teddy, separate concern); `src/core/sz.zig::ByteSet` (the 256-bit bitmap Shufti could share state with). | 002b leaves `sz.indexOf` alone (it remains the correctness reference and admission path); 002e does not duplicate `ByteSet` but may reference it. | Replacing `sz.indexOf` everywhere — it stays for non-hot paths. |
| Canonical callers and consumers | `countLiteral` (`search.zig:5271`), `countWordBoundaryLiteralLines` (`search.zig:5398, 5420`) consume `simd.indexOf`; `regex_full` strategy in `expr.zig` and every `pcre_regex.column`/`count` call site consumes the JIT path; `evaluateLookupGroup` (`postings.zig:738`) and `evaluateLookupPlan*` (lines 503, 780) consume `intersectFileIds`; `search.zig:3462, 3552, 2841, 2907` consume `sz.indexOfAdmission` and `indexOfByteSet`. | Each slice's proof path runs through the real consumer: benchmark on literal-alternates workload for 002b/002c/002e; benchmark on a warm-index query for 002d. | A unit validated only by a unit test of the helper without proving the consumer path. |
| Existing tests and proof gaps | `simd.zig` has `indexOfByte — basic` test; `pcre_regex.zig` has no in-file tests (PCRE2 is integration-tested via search.zig); `postings.zig` has tests at lines 1481, 1594 but none for skewed-size intersection. | 002b adds 3-byte fingerprint regression tests + a benchmark; 002c adds JIT-bypass behavior tests + benchmark; 002d adds galloping-vs-merge tests at multiple size ratios + benchmark; 002e adds Shufti correctness tests across the byte-alphabet. | A change that only re-tests the existing fixtures. |
| Unsupported runtime boundaries | PCRE2 JIT may return `PCRE2_ERROR_JIT_BADOPTION` for some patterns; the JIT-bypass slice must fall back to `pcre2_match_8`. The StringZilla fingerprint pivot is undefined for needles of length 0/1 (already special-cased). Shufti is undefined for an empty class (degenerate). | 002c carries the JIT-unsupported fallback; 002b preserves the existing length-1 special case; 002e documents the empty-class behavior. | A slice that crashes on the documented runtime boundary. |

## Scope

**In scope:**
- Port StringZilla's rarity-pivoted 3-byte fingerprint into `simd.zig::indexOf` (replacing 2-byte).
- Switch `pcre_regex.zig::column/count` to `pcre2_jit_match_8` with a fallback to `pcre2_match_8`.
- Add galloping dispatch to `intersectFileIds` for skewed-size inputs.
- Add a pure-Zig Shufti primitive (2× PSHUFB) to `simd.zig` for inlinable byte-class scanning.

**Out of scope:**
- Fat Teddy, Rose-lite dispatch, Sheng DFA, bit-parallel Glushkov NFA — separate chains.
- AVX-512 build target and `VPCOMPRESSB` — separate chain (would conflict with parent `001`'s build.zig work).
- Roaring bitmap posting lists — separate chain (large; depends on `intersectFileIds` galloping landing first).
- Huge pages, NUMA pinning — OS-level, separate chain.
- The `001-hot-path-perf` patch surface (Fat Teddy in `literal_alternates.zig`, LTO/cold-path/alignment in build.zig and search.zig) — concurrent but non-overlapping at the function level; explicit ordering in Phase Plan.

## Source Language Anchors

- "continue studying and researching the most complex genius formulas, methods, recipes, and code strategies for blazing fast search. we shouldnt get biased and stuck on existing lanes, we should zoom out and find things not yet explored or attempted." — original research request.
- "please do" — approval to lock the survey's Tier-S findings into a planning chain.
- AGENTS.md "Frontier Research And Source Reuse": "Default to copying or tightly adapting proven algorithms, layouts, state machines, benchmark methods, and tests from the highest-quality reference repos and papers."
- AGENTS.md Tier 5: "Compile-time SIMD selection — `SZ_DYNAMIC_DISPATCH=0`. No runtime feature detection. No function pointer table."
- Demaine, López-Ortiz, Munro SODA 2000 (cited in survey): the adaptive set-intersection optimum.
- Langdale "SMH: Swiss Army Chainsaw of shuffle-based matching sequences" (cited in survey): the Shufti 2×PSHUFB idiom.
- Wang et al., "Hyperscan: A Fast Multi-pattern Regex Matcher for Modern CPUs", USENIX NSDI 2019 (cited in survey): the production reference for the broader matching pipeline.

## Original User Message Capture

| Anchor ID | Information Piece | Verbatim Original Snippet | Required Coverage |
|-----------|-------------------|---------------------------|-------------------|
| U1 | objective — frontier research | "continue studying and researching the most complex genius formulas, methods, recipes, and code strategies for blazing fast search" | 002a freezes the survey's findings as decision records; 002b–002e absorb the four Tier-S items; 002f audits coverage. |
| U2 | directive — escape existing lanes | "we shouldnt get biased and stuck on existing lanes, we should zoom out and find things not yet explored or attempted" | The chain's scope is restricted to techniques the survey identified as currently-absent from IX; 002a locks this with a de-prioritization record for already-absorbed items. |
| U3 | approval — lock it in | "please do" | The chain exists. 002f verifies every slice traces back to U1/U2/U3. |
| U4 | invariant — reuse vendored references | "Default to copying or tightly adapting proven algorithms ... from the highest-quality reference repos" (AGENTS.md) | 002b harvests StringZilla `find.h:293-322`; 002c reads PCRE2 `pcre2.h.in:783` and `pcre2_jit_match.c:91`; 002e harvests the SMH post and Vectorscan `nfa/shufti.*`. |
| U5 | invariant — compile-time SIMD only | "`SZ_DYNAMIC_DISPATCH=0`. No runtime feature detection." (AGENTS.md Tier 5) | Every new kernel uses `@Vector(32, u8)` only; 002f asserts via grep that no runtime dispatch was introduced. |
| U6 | technique — 3-byte fingerprint | (survey Tier S4, citing StringZilla `find.h:293-322`) | 002b implements the rarity-pivoted 3-byte fingerprint. |
| U7 | technique — JIT bypass | (survey Tier S5, citing PCRE2 `pcre2.h.in:783`) | 002c switches to `pcre2_jit_match_8` with fallback. |
| U8 | technique — galloping intersection | (survey Tier S2, citing Demaine SODA 2000) | 002d adds the size-ratio dispatch. |
| U9 | technique — Shufti | (survey Tier S1, citing Langdale SMH post + Vectorscan) | 002e adds the pure-Zig Shufti primitive. |

## Source Message Coverage

| Unit | Source Anchor(s) | Slice Proof Obligation |
|------|------------------|------------------------|
| 002a | U1, U2, U3, U4, U5, U6, U7, U8, U9 | Freeze the survey's Tier-S findings as decision records; bind each implementation unit to its primary source; lock the no-runtime-dispatch and no-overlapping-with-001 constraints. |
| 002b | U4, U6 | Harvest StringZilla `find.h:293-322`; implement the 3-byte rarity-pivoted fingerprint in `simd.zig::indexOf`. |
| 002c | U4, U7 | Read PCRE2 `pcre2.h.in:783` and `pcre2_jit_match.c:91`; switch `pcre_regex.zig::column/count` to `pcre2_jit_match_8` with fallback. |
| 002d | U4, U8 | Cite Demaine SODA 2000; add galloping dispatch to `intersectFileIds`. |
| 002e | U4, U5, U9 | Harvest the SMH post + Vectorscan `nfa/shufti.*`; implement pure-Zig Shufti in `simd.zig`. |
| 002f | U1, U2, U3, U4, U5, U6, U7, U8, U9 | Verify every source anchor is closed; audit that no frontier-rejected item was smuggled in. |

## Constraints

| Dimension | Constraint |
|-----------|-----------|
| Category boundary | `feature`. Every change closes a surveyed perf gap. No pure refactoring. |
| Blast radius ceiling | medium. 002c touches the regex verifier used by every `regex_full` query; 002b touches every literal scan. No high-blast slice. |
| Structural boundary | Per-byte literal path (`simd.zig`), regex verifier (`pcre_regex.zig`), posting intersection (`postings.zig`), byte-class prefilter (`simd.zig` + `sz.zig` read-only). No `tools/scripts/` modifications. No `search.zig` scan-loop changes. |
| Dependency boundary | PCRE2 ABI surface grows by one symbol (`pcre2_jit_match_8`); StringZilla symbol surface unchanged. |
| Rollback surface | Per-unit `git checkout` on the named files. |
| Parallelism | Sequential. Each unit's exit state informs the next. The `001-hot-path-perf` chain is concurrent at the repo level but non-overlapping at the function level — explicit handoff in 002a. |

## Invariants

- I1: No mutex/atomic in the per-byte scan loop (AGENTS.md invariant 1, inherited).
- I2: No per-line allocation (AGENTS.md invariant 2, inherited).
- I3: Compile-time SIMD only — no runtime dispatch (AGENTS.md invariant 5). Every new kernel uses `@Vector(32, u8)`.
- I4: Strategy classification before I/O (AGENTS.md invariant 6, inherited).
- I5: StringZilla C ABI surface unchanged — `ix_sz_find`, `ix_sz_find_byte`, `ix_sz_find_byteset`, `ix_sz_equal` remain.
- I6: PCRE2 fallback path preserved — `pcre2_match_8` remains as the JIT-unsupported fallback.
- I7: Existing tests pass at every unit boundary; benchmark identity controls do not regress.
- I8: Every implementation unit's `evidence` field carries a captured benchmark receipt, not PLACEHOLDER.

## Architectural Improvement Targets

| Target ID | Pre-Chain Weakness | Required Better-Than-Before Outcome | Verified By |
|-----------|--------------------|-------------------------------------|-------------|
| A1 | Literal fingerprint uses 2 bytes (first+last); false-positive verifications dominate on repetitive needles. | 3-byte rarity-pivoted fingerprint reduces false positives multiplicatively. | 002b evidence: benchmark receipt + fingerprint regression tests. |
| A2 | PCRE2 caller invokes the interpreter entry on every line even after JIT compile; per-line sanity-check overhead is paid needlessly. | `pcre2_jit_match_8` bypasses sanity checks; `pcre2_match_8` retained as fallback. | 002c evidence: benchmark receipt + behavior tests including JIT-unsupported fallback. |
| A3 | Posting intersection is `O(|a|+|b|)` regardless of skew; rare-vs-common trigram pairs pay full cost. | Galloping dispatch achieves the Demaine adaptive bound for skewed inputs. | 002d evidence: galloping-vs-merge tests at multiple ratios + warm-index benchmark receipt. |
| A4 | Byte-class prefilter routes through FFI per query; no inlinable primitive exists for tight character-class loops. | Pure-Zig Shufti primitive classifies 32 bytes in 3 ops, inlines into callers. | 002e evidence: Shufti correctness tests + benchmark receipt on a character-class workload. |

## Embedded Framing Contract

| Frame ID | Embedded Meaning | Where It Appears | Gold-Standard Pressure |
|----------|------------------|------------------|------------------------|
| F1 | Survey-grounded absorption — every slice traces to a primary source the survey cited. | Objective, Rationale, Domain Expertise Baseline, each unit's Slice Research Directive. | Pulls each unit toward the vendored reference, away from reinvention. |
| F2 | Measurement discipline — no perf claim without paired before/after. | GS2, I7, every unit's Validation Plan. | Pulls validation toward benchmark receipts, not unit tests alone. |
| F3 | Frontier discipline — rejected items stay rejected; no scope creep. | GS5, 002a De-Prioritization Record. | Pulls scope away from CLMUL/prefetch/SIMD-AC/io_uring. |
| F4 | Owner clarity — extend existing owners, no new modules. | GS3, Repository Ownership Reconnaissance. | Pulls each patch toward `simd.zig`/`pcre_regex.zig`/`postings.zig`. |

## Research Program

| Research ID | Why This Research Exists | Questions To Answer | Insect Surface | Priority Sources | Expected Artifact / Evidence |
|-------------|--------------------------|---------------------|----------------|------------------|------------------------------|
| RCH-1 | 3-byte fingerprint design must be harvested from StringZilla, not reinvented. | How does `sz_locate_needle_anomalies_` pivot around collisions? What is the exact UTF-8-aware extension for long needles (>8 bytes)? | Local `.refs/stringzilla/include/stringzilla/find.h:280-330` read; `engine --url https://github.com/ashvardanian/StringZilla/blob/main/include/stringzilla/find.h` cross-reference. | Primary: vendored StringZilla source. | Quoted source excerpt + element-by-element mapping to Zig port in 002b design notes. |
| RCH-2 | PCRE2 JIT-bypass contract must be confirmed before swapping call sites. | Does `pcre2_jit_match_8` accept the same arg signature? What does it return on JIT-unsupported patterns? Does it set the ovector the same way? | `engine --url https://github.com/PCRE2Project/pcre2/blob/master/src/pcre2_jit_match.c`; `engine --query "pcre2_jit_match_8 vs pcre2_match_8 sanity check bypass semantics"`. | Primary: PCRE2 source + manpages. | Quoted header comment + return-code matrix in 002c design notes. |
| RCH-3 | Galloping intersection threshold and correctness proof. | At what size ratio does galloping beat two-pointer merge (Demaine says ~log; TimSort uses 7)? What is the exact gallop-search algorithm? | `engine --url https://erikdemaine.org/papers/SODA2000/`; `engine --query "TimSort galloping merge threshold adaptive intersection implementation"`. | Primary: Demaine SODA 2000 paper + TimSort implementation references. | Quoted bound + chosen threshold with rationale. |
| RCH-4 | Shufti mask-construction algorithm and the exact PSHUFB idiom. | How are the lo/hi 16-byte tables constructed from a byte set? How does the AND combine classifications? What's the verification step? | `engine --url https://branchfree.org/2018/05/30/smh-the-swiss-army-chainsaw-of-shuffle-based-matching-sequences/`; local read of any shufti-style macros in `.docs/research/hyperscan-teddy.c.snapshot` lines 199-210. | Primary: Langdale SMH post + Vectorscan `nfa/shufti*`. | Quoted mask-construction algorithm + Zig port. |

## Assumption Ledger

| Assumption ID | Assumption | Evidence Class | Risk If Wrong | Slice That Proves Or Eliminates It |
|---------------|------------|----------------|---------------|------------------------------------|
| AS1 | The 3-byte fingerprint reduces verifications on IX's workload (source-code corpus). | Unresolved hypothesis — StringZilla uses it but IX's needle distribution may differ. | Medium — if rare bytes are already at first/last, the third byte adds overhead with no win. | 002b (benchmark receipt) |
| AS2 | `pcre2_jit_match_8` returns identical match offsets to `pcre2_match_8` for IX's query shapes. | Primary source (PCRE2 header) + general JIT semantics. | Low — both go through the same JIT code; bypass only skips pre-checks. | 002c (behavior tests) |
| AS3 | Galloping wins on IX's posting lists at the size ratios actually encountered. | Primary source (Demaine) + Roaring production evidence. | Low — if all lists are similar size, the dispatch is a no-op fallback to merge. | 002d (ratio-stratified benchmark) |
| AS4 | Shufti's two-PSHUFB idiom compiles cleanly to AVX2 `vpsubusb`+`vpshufb`+`vpand` in Zig. | Primary source (Langdale SMH). | Low — the idiom is documented; Zig `@Vector` lowering is reliable. | 002e (asm diff) |

## Chain Manifest

| File | Phase | Role | Status |
|------|-------|------|--------|
| `/todo/pending/002-frontier-absorption.md` | parent | Chain root | pending |
| `/todo/pending/002a-frontier-absorption.md` | a | Baseline / contract lock | pending |
| `/todo/pending/002b-frontier-absorption.md` | b | 3-byte SIMD literal fingerprint (`simd.zig::indexOf`) | pending |
| `/todo/pending/002c-frontier-absorption.md` | c | PCRE2 `pcre2_jit_match_8` bypass (`pcre_regex.zig`) | pending |
| `/todo/pending/002d-frontier-absorption.md` | d | Galloping intersection dispatch (`postings.zig::intersectFileIds`) | pending |
| `/todo/pending/002e-frontier-absorption.md` | e | Pure-Zig Shufti byte-class primitive (`simd.zig`) | pending |
| `/todo/pending/002f-frontier-absorption.md` | f | Review / regression / closeout decision | pending |

Chain is complete when all rows read `archived` and all files are in `/todo/changelog/`.

## Execution Index

| Order | Unit | Role | Decision After Completion |
|------|------|------|---------------------------|
| 1 | `002a` | Baseline / contract lock — freeze survey findings, de-prioritizations, per-slice research mandates | Continue to `002b` |
| 2 | `002b` | 3-byte SIMD literal fingerprint | Continue to `002c` |
| 3 | `002c` | PCRE2 JIT bypass | Continue to `002d` |
| 4 | `002d` | Galloping intersection dispatch | Continue to `002e` |
| 5 | `002e` | Pure-Zig Shufti primitive | Continue to `002f` |
| 6 | `002f` | Review / regression / closeout | `NONE` if pass; extend only if review proves fix work required |

## Phase Plan

| Letter | Role | Patch Surface | Depends On | Parallelizable |
|--------|------|--------------|-----------|---------------|
| `a` | Baseline / contract lock | Interpretation freeze — no artifact change | — | No |
| `b` | 3-byte fingerprint | `src/core/simd.zig::indexOf` body + tests | `a` | No (shares simd.zig with 002e, ordered first) |
| `c` | JIT bypass | `src/core/pcre_regex.zig::column/count` + tests | `a` | No |
| `d` | Galloping intersection | `src/core/postings.zig::intersectFileIds` + tests | `a` | No |
| `e` | Shufti primitive | `src/core/simd.zig` (new namespace, separate from `indexOf`) + tests | `a`, `b` | No |
| `f` | Review / regression / closeout | Full deliverable validation plus architectural judgment | all prior | No |

## Validation Expectations

- Signal 1: `zig build test` exits 0 with no regressions at every unit boundary.
- Signal 2: For each implementation unit (b–e), a before/after benchmark receipt on the relevant workload (literal-alternates for b/c/e; warm-index query for d) is captured in the unit's `evidence` field.
- Signal 3: `grep -n "pcre2_match_8\|pcre2_jit_match_8" src/core/pcre_regex.zig` shows both symbols (the JIT-bypass primary path plus the fallback retained).
- Signal 4: `grep -n "gallop\|GALLOP" src/core/postings.zig` returns hits; the existing two-pointer merge is preserved as the balanced-size fallback.
- Signal 5: `grep -n "@Vector(32" src/core/simd.zig` returns multiple hits (the 3-byte fingerprint plus Shufti); `grep -n "cpuid\|runtime.*dispatch" src/core/simd.zig` returns no hits.
- Per-unit test floor: every implementation unit provides at least 30 meaningful feature-value tests before archival, unless explicitly documentation-only/baseline-only with a written exemption.
- Evidence format expected: captured `zig build test` stdout, benchmark-runner JSON, and grep outputs for the invariant signals.

## Current Frontier

`/todo/pending/002a-frontier-absorption.md`

## Stop Condition

`NONE` only after the terminal review or re-review passes. If the review fails, extend the chain with the smallest fix slice and a new terminal re-review slice.

## Next todo

`/todo/pending/002a-frontier-absorption.md`
