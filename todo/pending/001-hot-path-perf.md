---
id: 001-hot-path-perf
type: parent
protocol_version: "2.1"
spec_status: approved
category: feature
status: pending
epic_boundary: "Close the highest-leverage hot-path performance gaps in the IX scan pipeline by aligning code with AGENTS.md invariants (LTO, store-to-load forwarding alignment, cold-path isolation, inlinable literal scan), completing the Teddy kernel roadmap item with a Fat/16-bucket nibble-shuffle implementation harvested from vendored `.refs/aho-corasick/`, and replacing the scalar structural-anchor tail with RotVec-style memchr2."
subtodo_start: /todo/pending/001a-hot-path-perf.md
subtodo_final: /todo/pending/001h-hot-path-perf.md
continuation: "After each completed execution unit: record evidence, set status done, move to /todo/changelog/, continue immediately to next_todo. Stay focused on one slice at a time. Never batch-archive. Never pause between units."
source_message_policy: "Every lettered unit MUST include source_message_anchor, source_message_excerpt, source_message_proof_obligation, and an Original User Message Proof section with verbatim snippets from the original user message."
---
# 001 Hot-Path Performance: Invariant Alignment, Fat Teddy, RotVec Anchoring

## Objective

This chain closes the concrete performance gaps surfaced by a full codebase + frontier research audit of the IX scan pipeline. The system boundary is the scan hot path: `src/core/search.zig` (line scan, chunk I/O, ShardReport accumulation), `src/core/literal_alternates.zig` (Teddy multi-literal matcher), `src/core/simd.zig` (pure-Zig SIMD kernels), `src/sz_shim.c` + `src/core/sz.zig` (StringZilla FFI), and `build.zig` (C/Zig compile flags). The intended long-run shape is a scan loop where every AGENTS.md Tier 0–5 invariant the code already claims to honor is actually honored in the binary, where literal alternates beyond 8 branches stop falling back to scalar/PCRE2, and where structural boundary detection uses the documented memchr-style SIMD primitive with O(h+n) worst case instead of scalar `std.mem.lastIndexOfScalar`. The canonical deliverable is measurable scan-loop improvement on the literal-alternates workload the existing benchmark suite already exercises (`re:(?i)(ERR_SYS|PME_TURN_OFF|LINK_REQ_RST|CFG_BME_EVT)` per `tools/scripts/lib/benchmark-config.mjs:5`) without regressing the case-sensitive literal, word-boundary, or regex paths.

## Rationale

The audit established three failure classes. First, three AGENTS.md invariants are claimed but not delivered in the actual binary: `build.zig` never sets `want_lto` despite Tier 3 listing "LTO across Zig/C boundary"; the casefold stack buffers at `search.zig:5239-5240, 5283-5284` are plain `[N]u8` despite the file's own comments citing store-to-load forwarding as the rationale for isolating them; and no `@setCold`/`@branchHint(.cold)` protects the recoverable-error paths at `search.zig:2660-2683, 2755-2763` from polluting L1i. Second, the single highest-value algorithmic lever — a Fat Teddy with nibble-shuffle buckets capable of handling >8 branches — has its reference implementation already vendored at `.refs/aho-corasick/src/packed/teddy/` and `.refs/teddy-jneem/`, while the current `literal_alternates.zig:7` caps at `TEDDY_MAX_BRANCHES = 8` and bails to scalar `countMatchesScalar` or PCRE2 above that. The tooling layer (`tools/scripts/teddy-kernel-decision.mjs:1221-1255`) has pre-written an acceptance contract for a `packed_nibble_shuffle_teddy_kernel` that does not exist in `src/`. Third, the structural-anchor tail uses scalar `std.mem.lastIndexOfScalar` and `std.mem.count` on the chunk-skip path (`search.zig:3556, 3562-3566`), and the per-line `std.mem.trimEnd(u8, raw_line, "\r")` at `search.zig:3651, 4423` does a scalar length scan for a 1-in-N event.

The slices are sequenced so each leaves a self-contained, reviewable improvement: LTO/alignCold/simd-routing are independent single-file changes ordered cheapest-first to build evidence momentum; Fat Teddy is the algorithmic centerpiece that consumes the prior alignment work; RotVec anchoring is a correctness-and-worst-case win layered on top of the now-faster literal path. Downstream surfaces that depend on completion are the existing benchmark harness (`tools/scripts/lib/benchmark-runner.mjs`), the speed-compare and teddy-kernel-decision gates, and the AGENTS.md roadmap entries that currently misrepresent the binary.

## Domain Expertise Baseline

| Domain Question | Current Evidence | Gold-Standard Requirement | What This Chain Must Not Assume |
|-----------------|------------------|---------------------------|---------------------------------|
| What is the correct Fat Teddy algorithm and how does it differ from the current Slim Teddy? | Current impl `literal_alternates.zig:522-548` uses 8-bucket, 3-byte fingerprint, single `@Vector(32,u8)` load. `.refs/aho-corasick/src/packed/teddy/README.md` documents Slim (8 buckets, 32-byte read) vs Fat (16 buckets, 16-byte read on AVX2, two 128-bit halves). | BurntSushi/aho-corasick `src/packed/teddy/` + `src/packed/vector.rs` is the production reference; Faro & Kulekci SIMD-packed-AC lineage cited there. PSHUFB/TBL nibble tables produce per-bucket 8-bit masks from two 4-bit lookups, then AND-combine and TZCNT-extract candidates, then verify against real branches. | Do not invent a "SIMD Aho-Corasick with 256-wide flattened transition table" — Ourlis & Bellala SCPE 2019 is superseded by Teddy for literal search and is cache-hungry on state explosion. Do not skip verification. |
| Does LTO across the Zig/C boundary actually help StringZilla call sites? | `build.zig:58, 72` never set `want_lto`. `countLiteral:5271` calls `sz.indexOf` per line. | Zig `Compile.want_lto` is documented in the Zig build-system docs. Frontier guidance (Algorithmica, Travis Downs) is that LTO is marginal (~1-3%) on already-SIMD-heavy inline C, with link-time cost and the non-LTO-static-lib trap. Measure before committing. | Do not assume LTO is a windfall. Do not break WASM targets if they exist. The slice must be measurement-gated, not faith-based. |
| Is software prefetch worth adding to the scan loop? | No `@prefetch` anywhere in `search.zig`. | Algorithmica "don't bother" for sequential streams; Travis Downs "Speed Limits" — prefetch wins only on predictable far-ahead addresses the HW prefetcher can't infer; TU Dortmund 2024 survey notes locality hints ignored on Zen-class parts. | Do NOT add `@prefetch` to the inner scan loop. Reserve it for cross-buffer transitions only if a profile shows a stall. This is a de-prioritization decision, not work. |
| What is the worst-case-safe structural anchor primitive? | `simd.indexOfByte` uses `VPCMPEQB+VPMOVMSKB+TZCNT`; `sz_shim.c:58 ix_sz_find_byteset` exposes `sz_byteset_t`. `search.zig:3556,3562-3566` still uses scalar `std.mem.lastIndexOfScalar`/`std.mem.count`. | BurntSushi/memchr documents O(h+n) worst case; StringZilla documents O(h×n) worst case. RotVec handles unaligned/overlap reads without a slow path. memchr2/memchr3 is the standard prefilter. | Do not replace `simd.indexOfByte` (already correct). Do replace the scalar chunk-skip helpers. Do not assume CLMUL belongs here — simdjson/zimdjson use `VPCLMULQDQ` for backslash-escape carry chains, not plain newline finding; plain VPCMPEQB is cheaper and sufficient. |
| Are casefold buffers at risk of store-to-load forwarding stalls? | `search.zig:5239-5240, 5283-5284` declare plain `[CASEFOLD_LINE_MAX]u8` / `[CASEFOLD_NEEDLE_MAX]u8` stack arrays. Comment at `search.zig:5185-5193` isolates them to keep the hot path under 4 KiB but does not align them. | Store-to-load forwarding on a 32-byte unaligned store crossing a 32-byte boundary costs ~12 cycles. `@alignCast(32, ...)` on the buffer address guarantees forwarding success. | Do not change the isolation into separate functions (that's the 4 KiB `__chkstk` guard, already correct). Only add alignment to the buffers themselves. |

## Gold-Standard Decision Criteria

| Criterion ID | Decision Rule | Evidence Required Before Selection | Review Failure Signal |
|--------------|---------------|------------------------------------|-----------------------|
| GS1 | Prefer the vendored reference implementation over local reinvention for Fat Teddy (AGENTS.md "Frontier Research And Source Reuse"). | Read `.refs/aho-corasick/src/packed/teddy/README.md`, `.refs/aho-corasick/src/packed/vector.rs`, `.refs/teddy-jneem/` before designing the Zig port. | A Teddy reimplementation that does not map clearly to the Slim/Fat bucket-and-nibble structure of the reference. |
| GS2 | Reject algorithmic items the frontier literature flags as superseded or situational unless a slice-local probe proves a win (SIMD-AC, CLMUL newline, hot-loop `@prefetch`). | Cite Algorithmica, Travis Downs, simdjson paper, Ourlis & Bellala SCPE 2019. | Inclusion of SIMD-AC, CLMUL newline detection, or inner-loop prefetch in any slice without an explicit probe proving the win. |
| GS3 | Every claimed invariant in AGENTS.md that the binary does not honor is either fixed or explicitly de-prioritized with a measurement reason before chain close. | `grep -n` evidence in `build.zig`, `search.zig`; benchmark receipts before/after. | An AGENTS.md invariant left unaddressed without a recorded measurement. |
| GS4 | No new owner, registry, gate, or abstraction layer is created when an existing owner can absorb the change (AGENTS.md "hot path should be readable as a flat sequence"). | Repository reconnaissance showing `literal_alternates.zig`, `simd.zig`, `search.zig`, `sz.zig` are the canonical owners. | A new wrapper module, strategy dispatcher, or SIMD backend selector introduced by this chain. |
| GS5 | Measurement gates any performance claim: at minimum a before/after on the existing benchmark workload with paired identity controls (the discipline already in `benchmark-runner.mjs`). | `tools/scripts/lib/benchmark-runner.mjs` outputs; speed-compare utils. | A claim of speedup with no captured before/after evidence in the unit's `evidence` field. |

## Repository Ownership Reconnaissance

| Question | Evidence Found | Planning Consequence | Anti-Assumption Guard |
|----------|----------------|----------------------|-----------------------|
| Current canonical owners | `src/core/literal_alternates.zig` (Teddy + Counter, 777 LOC), `src/core/simd.zig` (pure-Zig kernels), `src/core/search.zig:5218-5298` (casefold literal scan + comment header), `src/sz_shim.c:58` (byteset), `build.zig:58,72` (C source steps), `src/core/literal_alternates.zig:251-303` (TeddyPlan, teddyPlanWithOffset). | Every slice extends these owners. No new module. | Do not create `teddy_fat.zig`, `simd_backend.zig`, or `prefetch.zig`. |
| Adjacent or duplicate owners | `src/core/sz.zig` (FFI wrappers incl. `indexOfByteSet` + cached BMH), `src/core/simd.zig` (pure-Zig equivalents). The split exists deliberately — see `simd.zig:1-9` header. | Fat Teddy extends `literal_alternates.zig`. SIMD literal routing moves `sz.indexOf` call sites in `search.zig:5271, 5398, 5420` to `simd.indexOf` where inlinability wins. | Do not delete `sz.indexOf` — it remains the correctness reference and admission-probe path (`sz.indexOfAdmission` for ≥16 B needles). |
| Canonical callers and consumers | `countLiteral:5271`, `countWordBoundaryLiteralLines:5398,5420`, `wholeBufferFastCount` paths, `nextTeddyCandidateInternal:522`. The benchmark workload at `benchmark-config.mjs:5` exercises literal alternates. | Each slice must prove the change through these callers and the benchmark. | A change validated only by a unit test of the new helper without proving the scan-loop call site. |
| Existing tests and proof gaps | `literal_alternates.zig:661+` has Teddy tests; `search.zig` has `whole buffer casefold literal alternates counts lowercased haystack` (line ~5691 in working tree). No test covers >8 branches (Fat territory). No test covers unaligned casefold buffer forwarding. | Fat Teddy slice must add >8-branch tests. Alignment slice must add a buffer-overlap regression test. | A Teddy change that only re-tests the existing 8-branch fixtures. |
| Unsupported runtime boundaries | Windows-first (`nt_open`, `GetProcessTimes`). StringZilla `SZ_DYNAMIC_DISPATCH=0`, `-mavx2` compile-time only. No runtime CPU dispatch (AGENTS.md invariant 5). | Fat Teddy must use `@Vector` compile-time AVX2 only — no runtime dispatch, no cpuid. | Introduction of a runtime feature check or `cpuid` gate. |

## Scope

**In scope:**
- LTO enablement in `build.zig` with a measurement gate.
- `@alignCast(32, ...)` on casefold stack buffers in `search.zig`.
- `@setCold()`/`@branchHint(.cold)` on recoverable-error and slow-scalar-tail paths in `search.zig` and `simd.zig`.
- Routing case-sensitive `countLiteral`/`countWordBoundaryLiteralLines` through `simd.indexOf` instead of `sz.indexOf` where inlinability is the documented rationale.
- Fat Teddy (16-bucket nibble-shuffle) in `literal_alternates.zig`, raising the branch ceiling above 8 with reference harvesting from `.refs/aho-corasick/src/packed/teddy/`.
- RotVec-style memchr2/memchr3 anchoring replacing the scalar chunk-skip helpers in `search.zig:3556,3562-3566`, plus the per-line CR trim replacement at `search.zig:3651,4423`.

**Out of scope:**
- io_uring / IOCP / VM double-mapped ring buffer (Tier 1) — large separate effort; mmap zero-copy already handles >1 MiB files.
- `@prefetch` scheduling (Tier 2) — frontier guidance says no for sequential scan; deferred unless a profile proves a stall.
- CLMUL structural boundary detection (Tier 0) — simdjson technique is for escape carry chains, not newline finding.
- SIMD Aho-Corasick with flattened transition table (Tier 4) — superseded by Teddy for literal search.
- Persistent index formats (Elias-Fano, Roaring, EWAH, cuckoo filter) — Tier 4/6, separate chain.
- Loser-tree k-way merge for `mergeShardsIntoReport` — marginal at current shard/hit counts; separate chain if profiling justifies.
- The `tools/scripts/` decision-harness layer — explicitly not modified by this chain except as a *consumer* of benchmark evidence.

## Source Language Anchors

- "study this codebase, last actions, w, whats going on, and ultimately wha your unbiased opinion is on areas to review where performance improvements can be made. studying the web, the refs the docs research." — original audit request.
- "Make sure the todo slices each demand mandatory unavoidable computer science / algorithm / hardware / system / code WEB RESEARCH using insect skill." — planning directive mandating per-slice research obligations.
- AGENTS.md: "LTO across Zig/C boundary — `want_lto = true` on C source steps, inline StringZilla AVX2 intrinsics into Zig scan loop, eliminate call overhead at the Zig/C seam" (Tier 3).
- AGENTS.md: "Store-to-load forwarding alignment — `@alignCast(32, ...)` on casefold buffers to guarantee 32-byte forwarding success, avoid 12-cycle stall on alignment miss" (Tier 5).
- AGENTS.md: "`@setCold()` on error/fallback paths — keep hot scan code in L1i, push cold code to distant addresses" (Tier 5).
- AGENTS.md: "Aho-Corasick automaton for literal alternates — single-pass instead of N independent scans" (Tier 0) — *narrowed by frontier research to Fat Teddy, the production-grade equivalent for literal search*.
- AGENTS.md: "Default to copying or tightly adapting proven algorithms, layouts, state machines, benchmark methods, and tests from the highest-quality reference repos and papers." (Frontier Research And Source Reuse).

## Original User Message Capture

| Anchor ID | Information Piece | Verbatim Original Snippet | Required Coverage |
|-----------|-------------------|---------------------------|-------------------|
| U1 | objective — unbiased performance review | "wha your unbiased opinion is on areas to review where performance improvements can be made" | 001a locks the review's findings as the chain scope; 001b–001g implement; 001h verifies the review's priority ordering was honored. |
| U2 | research depth — web + refs + docs | "studying the web, the refs the docs research" | Every implementation unit carries a Slice Research Directive citing `.refs/`, AGENTS.md, or Insect-harvested primary sources. 001h audits research coverage. |
| U3 | planning directive — mandatory per-slice research | "Make sure the todo slices each demand mandatory unavoidable computer science / algorithm / hardware / system / code WEB RESEARCH using insect skill" | Every implementation unit's Slice Research Directive names the exact Insect mode (`engine --query`, `engine --url`) or `.refs/` harvest and the closure artifact. 001h fails the chain if any unit omits this. |
| U4 | invariant — LTO claim | "LTO across Zig/C boundary — `want_lto = true` on C source steps" (AGENTS.md Tier 3) | 001c enables LTO with measurement or records a measurement-backed de-prioritization. |
| U5 | invariant — store-to-load forwarding | "@alignCast(32, ...) on casefold buffers to guarantee 32-byte forwarding success, avoid 12-cycle stall on alignment miss" (AGENTS.md Tier 5) | 001d adds the alignment to `search.zig:5239-5240, 5283-5284`. |
| U6 | invariant — cold-path isolation | "@setCold() on error/fallback paths — keep hot scan code in L1i, push cold code to distant addresses" (AGENTS.md Tier 5) | 001e adds `@setCold`/`@branchHint(.cold)`. |
| U7 | algorithmic — literal alternates | "Aho-Corasick automaton for literal alternates — single-pass instead of N independent scans" (AGENTS.md Tier 0) | 001f/001g deliver Fat Teddy (frontier-corrected equivalent). |
| U8 | reuse — vendored references | "Default to copying or tightly adapting proven algorithms ... from the highest-quality reference repos" (AGENTS.md) | 001f harvests `.refs/aho-corasick/src/packed/teddy/` and `.refs/teddy-jneem/` before designing. |

## Source Message Coverage

| Unit | Source Anchor(s) | Slice Proof Obligation |
|------|------------------|------------------------|
| 001a | U1, U2, U3, U4, U5, U6, U7, U8 | Freeze interpretation of the audit findings, the AGENTS.md invariants, and the per-slice research mandate. Reject any drift toward unrelated roadmap items. |
| 001b | U4 | Enable LTO in `build.zig` OR record a measurement-backed de-prioritization; either way close the AGENTS.md-vs-binary gap. |
| 001c | U5 | Add `@alignCast(32, ...)` to the four casefold stack buffers in `search.zig`. |
| 001d | U6 | Add `@setCold`/`@branchHint(.cold)` to recoverable-error and scalar-tail paths. |
| 001e | U1, U2, U3 | Route `sz.indexOf` call sites in the case-sensitive literal scans through `simd.indexOf`. Prove the inlinability win through the scan-loop caller. |
| 001f | U7, U8, U2, U3 | Harvest `.refs/aho-corasick/src/packed/teddy/` via Insect/local read; design and implement Fat Teddy raising the branch ceiling above 8. |
| 001g | U1, U2, U3 | Replace scalar chunk-skip and per-line CR trim with RotVec-style SIMD primitives. |
| 001h | U1, U2, U3, U4, U5, U6, U7, U8 | Verify every source anchor is implemented, evidenced, or explicitly closed; audit research coverage; audit better-than-before deltas. |

## Constraints

| Dimension | Constraint |
|-----------|-----------|
| Category boundary | `feature`. No refactoring-for-its-own-sake; every change must close a documented perf gap. |
| Blast radius ceiling | medium. Fat Teddy touches the literal-alternates match path used by the benchmark; LTO touches link behavior across the binary. No high-blast-radius slice. |
| Structural boundary | Scan hot path only: `search.zig`, `literal_alternates.zig`, `simd.zig`, `sz.zig`, `sz_shim.c`, `build.zig`. No `tools/scripts/` modifications. |
| Dependency boundary | StringZilla symbol surface (`sz_find`, `sz_find_byte`, `sz_find_byteset`, `sz_byteset_t`) is frozen. PCRE2 unaffected. |
| Rollback surface | Per-unit `git checkout` on the named files. LTO unit additionally records the link command and binary size before/after. |
| Parallelism | Sequential. Each unit's exit state feeds the next. No parallel slice execution. |

## Invariants

- I1: No mutex or atomic in the per-line scan loop (AGENTS.md invariant 1). Verified by `grep -n "Mutex\|atomicRmw" src/core/search.zig` showing atomics only at file-claim granularity.
- I2: No per-line allocation in the scan loop (AGENTS.md invariant 2). Carry buffer remains amortized.
- I3: Compile-time SIMD selection only — no runtime dispatch, no cpuid (AGENTS.md invariant 5). Fat Teddy must use `@Vector` only.
- I4: Strategy classification before I/O (AGENTS.md invariant 6). No new runtime classification in the scan loop.
- I5: StringZilla symbol surface unchanged — `ix_sz_find`, `ix_sz_find_byte`, `ix_sz_find_byteset`, `ix_sz_equal` remain the C ABI.
- I6: Existing tests pass — `zig build test` green at every unit boundary.
- I7: Benchmark identity controls do not regress — the repo binary must not slow down vs the installed binary on the workload at `benchmark-config.mjs:5` beyond noise thresholds.
- I8: Every implementation unit's `evidence` field carries a captured before/after or test result, not PLACEHOLDER.

## Architectural Improvement Targets

| Target ID | Pre-Chain Weakness | Required Better-Than-Before Outcome | Verified By |
|-----------|--------------------|-------------------------------------|-------------|
| A1 | AGENTS.md claims LTO; `build.zig` does not deliver it. | Either LTO is enabled with a measured delta, or AGENTS.md Tier 3 LTO entry is reconciled with a measurement-backed note. | 001b evidence + `grep want_lto build.zig`. |
| A2 | Casefold buffers cited as store-to-load rationale but left unaligned. | All four casefold stack buffers carry `@alignCast(32, ...)`. | 001c evidence + `grep -n "@alignCast" src/core/search.zig`. |
| A3 | Recoverable-error paths interleave with hot decode paths in L1i. | Cold paths marked `@setCold`/`@branchHint(.cold)`. | 001d evidence + `grep -n "@setCold\|@branchHint" src/core/search.zig src/core/simd.zig`. |
| A4 | `countLiteral` comment at `search.zig:5267` says "simd.indexOf directly" but the loop at 5271 calls `sz.indexOf` (FFI). | Case-sensitive literal scan routes through `simd.indexOf` where inlinability is the documented rationale. | 001e evidence + diff of `search.zig:5271,5398,5420`. |
| A5 | Literal alternates >8 branches fall back to scalar/PCRE2; vendored Fat Teddy reference unused. | Fat Teddy handles >8 branches via 16-bucket nibble-shuffle, harvested from `.refs/aho-corasick/`. | 001f evidence + new >8-branch tests + benchmark receipt. |
| A6 | Structural anchor uses scalar `std.mem.lastIndexOfScalar`/`std.mem.count` on the chunk-skip path; per-line CR trim is a scalar scan. | RotVec-style SIMD primitives replace scalar chunk-skip; CR trim becomes a single-byte branch. | 001g evidence + diff of `search.zig:3556,3562-3566,3651,4423`. |

## Embedded Framing Contract

| Frame ID | Embedded Meaning | Where It Appears | Gold-Standard Pressure |
|----------|------------------|------------------|------------------------|
| F1 | Invariant-to-binary truth — every AGENTS.md claim must be observable in the binary or explicitly reconciled. | Objective, Rationale, A1–A4, 001b–001d acceptance. | Pulls each invariant slice toward closure evidence, not assertion. |
| F2 | Frontier-corrected reuse — Fat Teddy not SIMD-AC, memchr not CLMUL, no inner-loop prefetch. | Domain Expertise Baseline, GS1/GS2, 001f/001g directives. | Pulls design toward vendored reference + cited research, away from reinvention. |
| F3 | Measurement discipline — no perf claim without a paired before/after. | GS5, I7, every implementation unit's Validation Plan. | Pulls validation toward benchmark receipts, not unit tests alone. |
| F4 | Single canonical owner — extend `literal_alternates.zig`/`simd.zig`/`search.zig`; no new wrapper modules. | GS4, Repository Ownership Reconnaissance. | Pulls each patch toward the existing owner, away from sprawl. |

## Research Program

| Research ID | Why This Research Exists | Questions To Answer | Insect Surface | Priority Sources | Expected Artifact / Evidence |
|-------------|--------------------------|---------------------|----------------|------------------|------------------------------|
| RCH-1 | Fat Teddy design must be harvested from the production reference, not reinvented. | How does BurntSushi/aho-corasick implement Fat Teddy's 16-bucket nibble-shuffle on AVX2? What is the bucket-assignment hash? How are candidate masks AND-combined and TZCNT-extracted? How is the Slim→Fat fallback chosen? | `engine --url https://github.com/BurntSushi/aho-corasick/blob/master/src/packed/teddy/README.md`; `engine --url .../src/packed/vector.rs`; local `.refs/aho-corasick/src/packed/teddy/` read; `.refs/teddy-jneem/` read. | BurntSushi/aho-corasick repo (primary), Faro & Kulekci paper (cited in README), jneem/teddy standalone port. | Markdown extraction of the Teddy README + vector.rs; written design notes mapping each element to the Zig port. |
| RCH-2 | LTO across Zig/C boundary — quantify the actual win on StringZilla call sites before committing. | Does `want_lto = .full` in Zig 0.16.0+ actually inline StringZilla's hot compare loop across the C ABI? What is the measured before/after on the literal-alternates workload? Any link-time or WASM-target regressions? | `engine --query "zig want_lto addCSourceFile stringzilla benchmark"`; `engine --url https://ziglang.org/learn/build-system/`. | Zig build-system docs (primary), StringZilla repo, r/Zig LTO bug reports. | Benchmark receipt before/after; build-time log; written decision record. |
| RCH-3 | RotVec / memchr2 worst-case correctness vs StringZilla O(h×n). | What is the RotVec technique for unaligned overlap reads? How does BurntSushi/memchr compose memchr2/memchr3? What's the concrete worst-case-safe primitive to add to `simd.zig`? | `engine --url https://github.com/BurntSushi/memchr/blob/master/src/...`; `engine --query "memchr RotVec unaligned overlap read technique"`. | BurntSushi/memchr repo (primary), memchr vs StringZilla discussions/159. | Markdown extraction of memchr RotVec implementation; written primitive spec for `simd.zig`. |
| RCH-4 | De-prioritization justification for SIMD-AC, CLMUL newline, inner-loop prefetch. | Confirm the frontier consensus rejects these for IX's workload. | `engine --query "simd aho-corasick vs teddy literal search 2024 2025"`; `engine --query "software prefetch sequential scan zen 4 golden cove 2024"`; `engine --url https://arxiv.org/abs/1902.08318`. | Algorithmica, Travis Downs "Speed Limits", simdjson paper (arXiv:1902.08318), TU Dortmund 2024 prefetch survey. | Written decision record in 001a locking the de-prioritization with citations. |

## Assumption Ledger

| Assumption ID | Assumption | Evidence Class | Risk If Wrong | Slice That Proves Or Eliminates It |
|---------------|------------|----------------|---------------|------------------------------------|
| AS1 | The audit's identification of the casefold buffers as unaligned is correct. | Verified repo fact (`search.zig:5239-5240, 5283-5284` have no `@alignCast`). | Low — if already aligned by luck of stack layout, the change is a no-op but not harmful. | 001c |
| AS2 | Fat Teddy will outperform the current scalar/PCRE2 fallback for >8 branches. | Unresolved hypothesis — frontier research says it should, but workload-specific bucket balance is unknown. | Medium — if benchmark patterns cluster in few buckets, verification cost dominates and the win is small. | 001f |
| AS3 | LTO will not break the StringZilla/PCRE2 build. | Primary source (Zig docs) + general LTO behavior. | Medium — non-LTO static lib trap; PCRE2's 27 TUs may not all be LTO-compatible. | 001b |
| AS4 | `simd.indexOf` outperforms `sz.indexOf` post-LTO at the literal call sites. | Local rationale comment at `simd.zig:1-9`. | Low — if equivalent, the change still removes FFI overhead in principle. | 001e |
| AS5 | The audit's recommendation to *not* add inner-loop prefetch is correct for IX's workload. | Primary sources (Algorithmica, Travis Downs, TU Dortmund 2024). | Low — worst case we leave a small win on the table; the frontier consensus is strong. | 001a (locks the decision) |

## Chain Manifest

| File | Phase | Role | Status |
|------|-------|------|--------|
| `/todo/pending/001-hot-path-perf.md` | parent | Chain root | pending |
| `/todo/pending/001a-hot-path-perf.md` | a | Baseline / contract lock | pending |
| `/todo/pending/001b-hot-path-perf.md` | b | LTO across Zig/C boundary (`build.zig`) | pending |
| `/todo/pending/001c-hot-path-perf.md` | c | `@alignCast(32)` on casefold stack buffers | pending |
| `/todo/pending/001d-hot-path-perf.md` | d | `@setCold`/`@branchHint(.cold)` on error and scalar-tail paths | pending |
| `/todo/pending/001e-hot-path-perf.md` | e | Route case-sensitive literal scans through `simd.indexOf` | pending |
| `/todo/pending/001f-hot-path-perf.md` | f | Fat Teddy (16-bucket nibble-shuffle) kernel | pending |
| `/todo/pending/001g-hot-path-perf.md` | g | RotVec memchr2/memchr3 anchoring + CR-trim replacement | pending |
| `/todo/pending/001h-hot-path-perf.md` | h | Review / regression / closeout decision | pending |

Chain is complete when all rows read `archived` and all files are in `/todo/changelog/`.

## Execution Index

| Order | Unit | Role | Decision After Completion |
|------|------|------|---------------------------|
| 1 | `001a` | Baseline / contract lock — freeze audit findings, AGENTS.md invariants, de-prioritization decisions, per-slice research mandates | Continue to `001b` |
| 2 | `001b` | Enable (or measurement-gate) LTO in `build.zig` | Continue to `001c` |
| 3 | `001c` | Align casefold buffers | Continue to `001d` |
| 4 | `001d` | Cold-mark error and scalar-tail paths | Continue to `001e` |
| 5 | `001e` | Route literal scans through `simd.indexOf` | Continue to `001f` |
| 6 | `001f` | Implement Fat Teddy raising branch ceiling above 8 | Continue to `001g` |
| 7 | `001g` | RotVec anchoring + CR-trim replacement | Continue to `001h` |
| 8 | `001h` | Review / regression / closeout | `NONE` if pass; extend chain only if review proves fix work is required |

Every row above should compound the parent ratchet. The invariant-alignment slices (b–e) clear the AGENTS.md-vs-binary gap; the algorithmic slices (f–g) deliver the performance leverage; the review (h) audits both.

## Phase Plan

| Letter | Role | Patch Surface | Depends On | Parallelizable |
|--------|------|--------------|-----------|---------------|
| `a` | Baseline / contract lock | Interpretation freeze, invariant declaration, de-prioritization record — no artifact change | — | No |
| `b` | LTO enablement | `build.zig` | `a` | No |
| `c` | Casefold buffer alignment | `src/core/search.zig` (4 buffer decls + slice references) | `a` | No |
| `d` | Cold-path marking | `src/core/search.zig`, `src/core/simd.zig` | `a` | No |
| `e` | simd.indexOf literal routing | `src/core/search.zig:5271,5398,5420` call sites | `a` | No |
| `f` | Fat Teddy kernel | `src/core/literal_alternates.zig` (TeddyPlan, teddyPlanWithOffset, nextTeddyCandidate, counter dispatch); tests | `a`, `e` | No |
| `g` | RotVec anchoring + CR trim | `src/core/simd.zig` (new primitive), `src/core/search.zig:3556,3562-3566,3651,4423` | `a`, `e` | No |
| `h` | Review / regression / closeout decision | Full deliverable validation plus architectural judgment | all prior | No |

## Validation Expectations

- Signal 1: `zig build test` exits 0 with no test regressions at every unit boundary.
- Signal 2: For slices claiming a perf delta (b, e, f, g), a before/after benchmark receipt on the workload at `tools/scripts/lib/benchmark-config.mjs:5` is captured in the unit's `evidence` field, run through `tools/scripts/lib/benchmark-runner.mjs` or equivalent. Identity controls respected.
- Signal 3: Fat Teddy slice adds at least 30 meaningful feature-value tests covering: 9–16 branches (new territory), 2–8 branches (regression), single-branch fallthrough, branch-prefix collisions, case-insensitive folded/unfolded haystacks, fingerprint-offset variations, and adversarial bucket-saturation inputs.
- Signal 4: `grep -n "want_lto" build.zig` returns a hit (or 001b records a measurement-backed de-prioritization).
- Signal 5: `grep -n "@alignCast" src/core/search.zig` returns ≥4 hits at the casefold buffer sites.
- Signal 6: `grep -n "@setCold\|@branchHint" src/core/search.zig src/core/simd.zig` returns hits on the recoverable-error and scalar-tail paths.
- Per-unit test floor: every implementation execution unit must provide at least 30 meaningful feature-value tests before archival, unless it is explicitly documentation-only/baseline-only and records that exemption.
- Test-value rule: tests must prove the changed capability through the intended user/operator/runtime entrypoint (the scan loop / benchmark workload) and its valuable output path; diagnostics-only, logging-only, snapshot-only, or internal-counter checks do not satisfy the floor.
- Evidence format expected: captured `zig build test` stdout, benchmark-runner JSON or text receipt, and `grep` output for the invariant signals.

## Current Frontier

`/todo/pending/001a-hot-path-perf.md`

## Stop Condition

`NONE` only after the terminal review or re-review passes. If the review fails, extend the chain with the smallest fix slice and a new terminal re-review slice.

## Next todo

`/todo/pending/001a-hot-path-perf.md`
