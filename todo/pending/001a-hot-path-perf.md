---
id: 001a-hot-path-perf
parent: 001-hot-path-perf
type: execution-unit
protocol_version: "2.1"
category: feature
phase: a
status: pending
patch_scope: "Interpretation freeze and invariant declaration. No artifact change. Locks the audit findings, the AGENTS.md invariants in play, the frontier-corrected de-prioritizations, and the per-slice research mandate."
blast_radius: low
blast_radius_justification: "Read-only unit. No source files, build files, or tests are modified. Failure propagation path is nonexistent; the only output is the locked interpretation inherited by downstream units."
idempotency_contract: idempotent
idempotency_notes: "No artifact change. Re-executing this unit from any point produces the same locked interpretation. Recovery is a no-op."
acceptance: "The audit findings, AGENTS.md invariant-to-binary gaps, frontier de-prioritizations, and per-slice research mandate are recorded as decision records in this file's body. The body must cite concrete file:line evidence for every gap and every de-prioritization must name a primary source."
exit_criterion: "This file's body contains: (1) a Decision Record section with one row per gap named in the parent's Architectural Improvement Targets, (2) a De-Prioritization Record citing at least 4 primary sources (Algorithmica, Travis Downs, simdjson arXiv:1902.08318, TU Dortmund 2024 prefetch survey), and (3) confirmation of the parent's per-slice research mandate. `zig build test` continues to pass (baseline not perturbed)."
validation: "cd \"E:/Workspaces/01_Projects/01_Github/ix-zig\" && zig build test 2>&1 | tail -5"
expected_exit_code: 0
expected_output_pattern: "(test|PASS|0 skipped|0 failed|.*passed)"
evidence: "PLACEHOLDER — replace with exact captured stdout at completion. Archival is gated on this field being populated."
conflict_surface: ""
invariants:
  - "I6: Existing tests pass — `zig build test` green at every unit boundary."
  - "I8: Every implementation unit's `evidence` field carries a captured before/after or test result, not PLACEHOLDER. (This baseline unit captures the test-suite baseline.)"
source_message_anchor: "U1, U2, U3, U4, U5, U6, U7, U8"
source_message_excerpt: "wha your unbiased opinion is on areas to review where performance improvements can be made; studying the web, the refs the docs research; Make sure the todo slices each demand mandatory unavoidable computer science / algorithm / hardware / system / code WEB RESEARCH using insect skill; LTO across Zig/C boundary — want_lto = true on C source steps; @alignCast(32, ...) on casefold buffers; @setCold() on error/fallback paths; Aho-Corasick automaton for literal alternates; Default to copying or tightly adapting proven algorithms ... from the highest-quality reference repos"
source_message_proof_obligation: "Freeze the audit findings as the chain scope; freeze the AGENTS.md invariants as acceptance criteria; lock the frontier-corrected de-prioritizations with primary-source citations; and bind every downstream unit to the per-slice research mandate. Every downstream unit's Slice Research Directive traces to a row locked here."
entry_state: "Parent `001-hot-path-perf.md` is approved and in `/todo/pending/`. The codebase is in the audited working-tree state: `src/core/literal_alternates.zig` carries `TEDDY_MAX_BRANCHES = 8` (line 7); `build.zig:58,72` set no `want_lto`; `src/core/search.zig:5239-5240, 5283-5284` declare plain `[N]u8` casefold buffers; `src/core/search.zig:5271,5398,5420` call `sz.indexOf` despite the comment at 5267 promising `simd.indexOf`; `.refs/aho-corasick/src/packed/teddy/` and `.refs/teddy-jneem/` are vendored and unread by the current implementation."
rollback_surface: "None. No artifact change. If the unit is aborted, no revert is required."
dependencies: ""
next_todo: /todo/pending/001b-hot-path-perf.md
continuation: "On completion: record evidence (replace PLACEHOLDER with `zig build test` stdout), set status done, move this file to /todo/changelog/001a-hot-path-perf.md, continue immediately to /todo/pending/001b-hot-path-perf.md. Stay fully focused on this slice until it resolves. Do not switch to any other slice. Do not pause. Do not batch."
blocked_reason: ""
unblock_action: ""
resumption_point: ""
---
# 001a Baseline / Contract Lock

## Execute Now

Freeze the audit's findings as binding decision records, lock the AGENTS.md invariants as acceptance criteria for downstream slices, record the frontier-corrected de-prioritizations with primary-source citations, and confirm the per-slice research mandate binds every downstream unit.

## Slice Focus Rule

This unit owns the agent's attention until the decision records below are fully populated and the baseline test output is captured. The agent must not skip ahead to implementation, must not begin reading `.refs/aho-corasick/` harvest work (that belongs to 001f), and must not reinterpret the parent's scope. Any ambiguity in the parent's wording is resolved here, in writing, before any later unit begins.

## Why This Execution Unit Exists

This slice exists because the parent names seven AGENTS.md invariants, four de-prioritization decisions, and one research mandate, but downstream units need a single frozen interpretation to prevent drift. Without this lock, 001f could reinvent Fat Teddy from generic AC knowledge rather than harvesting `.refs/aho-corasick/`, and 001b could enable LTO by rote without recording the measurement-backed de-prioritization alternative. Merging this lock into the first implementation unit would contaminate the baseline test capture with interpretation work.

## Better-Than-Before Delta

This slice leaves the chain with a written contract that makes every downstream acceptance criterion falsifiable: each AGENTS.md gap is tied to a file:line, each de-prioritization is tied to a primary source, and each implementation unit's research obligation is traceable to a row here. The pre-slice weakness is that the audit's conclusions exist only in conversation history; the post-slice improvement is that they exist as a reviewable artifact in the repository.

## Slice Domain Standard

| Domain Standard | Local Evidence | Implementation Consequence | Anti-Assumption Guard |
|-----------------|----------------|----------------------------|-----------------------|
| A baseline lock must be derivable from repository evidence, not memory. | `grep -n "TEDDY_MAX_BRANCHES\|want_lto\|@alignCast\|@setCold" src/core/literal_alternates.zig build.zig src/core/search.zig src/core/simd.zig` (run during parent reconnaissance). | Every Decision Record row cites a concrete file:line. | A decision record that names a gap without a file:line citation is malformed. |
| A de-prioritization must cite a primary source, not "the literature." | Parent Research Program RCH-4 names Algorithmica, Travis Downs, simdjson arXiv:1902.08318, TU Dortmund 2024 prefetch survey. | Each De-Prioritization Record row names one of these sources and the specific claim borrowed. | "Research shows prefetch doesn't help" without a citation is malformed. |

## Domain-Knowledge Research Check

| Knowledge Gap | Research / Probe To Run | Source Priority | Decision It Controls | Closure Evidence |
|---------------|--------------------------|-----------------|----------------------|------------------|
| Confirm the four primary de-prioritization sources are accessible and say what the parent claims. | `engine --query "algorithmica software prefetch sequential scan don't bother"`; `engine --url https://travisdowns.github.io/blog/2019/06/11/speed-limits.html`; `engine --url https://arxiv.org/abs/1902.08318`; `engine --query "TU Dortmund software prefetching survey 2024"`. | Primary: Algorithmica site, Travis Downs blog, arXiv paper, TU Dortmund survey PDF. | Whether 001a's De-Prioritization Record can cite primary sources verbatim, locking out SIMD-AC/CLMUL/inner-loop prefetch from downstream slices. | Extracted markdown/quote from each source stored as cited evidence in this unit's body. |
| Confirm the Fat Teddy reference paths exist in the repo. | `ix search` or `ls .refs/aho-corasick/src/packed/teddy/`; `ls .refs/teddy-jneem/`. | Local `.refs/` (primary). | Whether 001f's harvest directive is sound. | Directory listing reproduced in this unit's body. |
| External gap already closed by local/research artifact because the parent's Research Program already names the primary sources; this slice confirms accessibility and quotes the load-bearing claims. | — | — | — | — |

## Technical Execution Blueprint

| Area | Required Detail |
|------|-----------------|
| Repository anchors | `src/core/literal_alternates.zig:7` (`TEDDY_MAX_BRANCHES = 8`), `build.zig:58,72` (C source steps, no `want_lto`), `src/core/search.zig:5239-5240,5283-5284` (casefold buffers), `src/core/search.zig:2660-2683,2755-2763` (recoverable-error paths), `src/core/search.zig:5271,5398,5420` (`sz.indexOf` call sites), `src/core/search.zig:3556,3562-3566` (scalar chunk-skip), `src/core/search.zig:3651,4423` (per-line CR trim), `.refs/aho-corasick/src/packed/teddy/`, `.refs/teddy-jneem/`. |
| Existing-owner decision | No owner change. This is a contract lock. |
| Domain owner / canonical standard | AGENTS.md invariants + frontier primary sources govern correctness. |
| Intended design | A Decision Record table, a De-Prioritization Record table, and a Research Mandate Confirmation table populated in this file's body. |
| Integration path | Downstream units reference rows in these tables by ID in their `Slice Research Directive` and `Original User Message Proof` sections. |
| Failure modes to prevent | Vague de-prioritization ("prefetch doesn't help") with no citation; gap rows without file:line; harvest paths listed but not verified to exist. |
| Alternatives rejected | Writing a separate `decision-record.md` artifact — rejected because the parent is the ownership surface and this lock belongs in the chain. |
| Proof hooks | `zig build test` baseline captured in evidence; grep output in this unit's body confirming each cited path exists. |

## Codebase Research And Execution Addendum

**Implementation map:** Before populating the decision records, run `ls .refs/aho-corasick/src/packed/teddy/ .refs/teddy-jneem/` to confirm the vendored Fat Teddy reference is present, and `grep -n "want_lto\|@alignCast\|@setCold\|@branchHint" build.zig src/core/search.zig src/core/simd.zig` to confirm the absence that motivates slices b–d.

**Existing-owner directive:** No owner is modified. This slice extends the chain's contract surface only.

**Directive:** Populate the three tables in the body verbatim from the parent's Domain Expertise Baseline, Gold-Standard Decision Criteria, and Research Program. Cite file:line for every gap. Cite a primary source URL or quoted claim for every de-prioritization.

**Gold-standard guardrail:** Do not convert this baseline into a free-form essay. The output is three structured tables plus the captured test baseline. Paragraphs are forbidden outside the table rows and the Execute Now / Focus Rule sections.

**Knowledge gathering route:** Local `grep`/`ls` first; then `engine --url` and `engine --query` via the Insect wrapper (`scripts/run-insect-rs.ps1 engine --url ...` / `--query ...`) to confirm the four primary sources are reachable and say what the parent claims. Store extracted quotes inline in the De-Prioritization Record.

**Runtime visualization:** Not applicable — no runtime change.

**Proof expansion:** Run `zig build test` and capture the tail. Add no new tests; this is a baseline-only unit with the documented exemption.

**Action-mode arbitration:** Execute now. This is a direct synchronous authoring task. No deferral, delegation, batching, or background work is permitted.

## Embedded Framing

Lock the contract so each downstream slice is pulled toward evidence rather than assertion: every gap cites a file:line, every de-prioritization cites a primary source, every research obligation traces to a row here.

## Slice Research Directive

| Research Topic | Why It Matters To This Slice | Insect Mode | Source Priority | Closure Evidence |
|----------------|------------------------------|-------------|-----------------|------------------|
| Confirm Algorithmica's "don't bother" prefetch guidance is current and quotable. | Locks AS5 and prevents any downstream slice from adding inner-loop `@prefetch`. | `engine --query "algorithmica software prefetch sequential scan don't bother"` or `engine --url https://en.algorithmica.org/hpc/` | Primary: Algorithmica site. | Quoted sentence in De-Prioritization Record row DP-1. |
| Confirm Travis Downs "Speed Limits" says prefetch wins only on predictable far-ahead misses. | Load-bearing for the prefetch de-prioritization and for the "prefetch only at cross-buffer transitions" carve-out. | `engine --url https://travisdowns.github.io/blog/2019/06/11/speed-limits.html` | Primary: Travis Downs blog. | Quoted sentence in DP-1. |
| Confirm simdjson paper (arXiv:1902.08318) ties CLMUL to backslash-escape carry chains, not plain newline finding. | Prevents 001g from over-reaching into CLMUL newline detection. | `engine --url https://arxiv.org/abs/1902.08318` | Primary: VLDB Journal paper. | Quoted sentence in DP-2. |
| Confirm TU Dortmund 2024 survey says locality hints are increasingly ignored on Zen-class parts. | Prevents effort spent tuning `_MM_HINT_T0` vs `_T2` in any future prefetch work. | `engine --query "TU Dortmund software prefetching survey 2024 locality hints ignored"` | Primary: TU Dortmund PDF. | Quoted sentence in DP-1. |
| Confirm Ourlis & Bellala SCPE 2019 SIMD-AC is superseded by Teddy for literal search. | Prevents any downstream slice from introducing a 256-wide flattened AC transition table. | `engine --url https://www.scpe.org/index.php/scpe/article/view/1572/598` | Primary: SCPE journal paper. | Quoted sentence in DP-3. |
| Confirm `.refs/aho-corasick/src/packed/teddy/` and `.refs/teddy-jneem/` exist and contain the reference Slim/Fat implementation. | Bind 001f to the harvest directive (U8). | Local `ls`/`ix search` (no Insect mode needed; `.refs/` is local). | Primary: vendored Rust source. | Directory listing in Decision Record row G-5. |

## Original User Message Proof

| Source Anchor | Verbatim Original Snippet | Slice Proof Obligation | Evidence Capture |
|---------------|---------------------------|------------------------|------------------|
| U1 | "wha your unbiased opinion is on areas to review where performance improvements can be made" | Freeze the audit's gap list as binding decision records; prevent drift. | The Decision Record table in this unit's body. |
| U2 | "studying the web, the refs the docs research" | Lock the research-source expectation; every downstream Slice Research Directive traces here. | The Research Mandate Confirmation table. |
| U3 | "Make sure the todo slices each demand mandatory unavoidable computer science / algorithm / hardware / system / code WEB RESEARCH using insect skill" | Bind every implementation unit to a per-slice Insect/harvest directive; this unit confirms the mandate is in the parent and traces to each unit. | The Research Mandate Confirmation table maps parent anchors U2/U3 to each downstream unit'sSlice Research Directive obligation. |
| U4 | "LTO across Zig/C boundary — `want_lto = true` on C source steps" (AGENTS.md) | Record the LTO gap with file:line so 001b inherits a falsifiable target. | Decision Record row G-1. |
| U5 | "`@alignCast(32, ...) on casefold buffers`" (AGENTS.md) | Record the alignment gap with file:line. | Decision Record row G-2. |
| U6 | "`@setCold() on error/fallback paths`" (AGENTS.md) | Record the cold-path gap with file:line. | Decision Record row G-3. |
| U7 | "Aho-Corasick automaton for literal alternates" (AGENTS.md) | Record the literal-alternates gap, frontier-corrected to Fat Teddy. | Decision Record row G-4, G-5. |
| U8 | "Default to copying or tightly adapting proven algorithms ... from the highest-quality reference repos" (AGENTS.md) | Bind 001f to harvesting `.refs/aho-corasick/`. | Decision Record row G-5; Research Mandate row for 001f. |

## Decision Record

| Gap ID | AGENTS.md Claim | File:Line Evidence (Current State) | Owning Slice | Closure Signal |
|--------|-----------------|------------------------------------|--------------|----------------|
| G-1 | Tier 3: "LTO across Zig/C boundary — `want_lto = true` on C source steps" | `build.zig:58` (`root_module.addCSourceFile(.{ ... })` no `want_lto`); `build.zig:72` (`root_module.addCSourceFiles(.{ ... })` no `want_lto`). | 001b | `grep -n "want_lto" build.zig` returns a hit, OR 001b records a measurement-backed de-prioritization. |
| G-2 | Tier 5: "Store-to-load forwarding alignment — `@alignCast(32, ...) on casefold buffers`" | `src/core/search.zig:5239` (`var lower_line: [CASEFOLD_LINE_MAX]u8 = undefined;`); `:5240` (`var lower_needle: [CASEFOLD_NEEDLE_MAX]u8 = undefined;`); `:5283-5284` (second pair in `countLiteralCasefold`). Comment at `:5185-5193` isolates them for 4 KiB stack hygiene but does not align them. | 001c | `grep -n "@alignCast" src/core/search.zig` returns ≥4 hits at the casefold sites. |
| G-3 | Tier 5: "`@setCold() on error/fallback paths — keep hot scan code in L1i`" | `src/core/search.zig:2660-2683, 2755-2763` (recoverable-error paths); scalar tails in `src/core/simd.zig`. No `@setCold` or `@branchHint(.cold)` anywhere in `search.zig` or `simd.zig`. | 001d | `grep -n "@setCold\|@branchHint" src/core/search.zig src/core/simd.zig` returns hits on recoverable-error and scalar-tail paths. |
| G-4 | Tier 0: "Aho-Corasick automaton for literal alternates — single-pass instead of N independent scans" — frontier-corrected to Fat Teddy | `src/core/literal_alternates.zig:7` (`TEDDY_MAX_BRANCHES = 8`); `:267` (`teddyPlanWithOffset` returns null for >8 branches); `:415-421` (PCRE2 fallback for ≥5 branches). | 001f | 16-bucket Fat Teddy kernel handles >8 branches; ≥30 new feature-value tests; benchmark receipt on the literal-alternates workload. |
| G-5 | Frontier Research And Source Reuse: "Default to copying or tightly adapting proven algorithms ... from the highest-quality reference repos" | `.refs/aho-corasick/src/packed/teddy/README.md` (Slim vs Fat spec); `.refs/aho-corasick/src/packed/vector.rs` (Fat Teddy vector impl); `.refs/teddy-jneem/` (standalone port). All present, none consumed by current Zig impl. | 001f | 001f's Slice Research Directive records the harvest; design notes map each Fat Teddy element to the Zig port. |
| G-6 | Tier 5: implicit "no FFI where inlinable Zig is equivalent" (rationale at `simd.zig:1-9`) | `src/core/search.zig:5271` (`const index = sz.indexOf(line[start..], needle) orelse break;`); `:5398, :5420` (word-boundary paths also `sz.indexOf`). Comment at `:5267` says "Case-sensitive: simd.indexOf directly, no indirection." | 001e | Diff at `search.zig:5271,5398,5420` shows `simd.indexOf`; benchmark receipt shows no regression. |
| G-7 | Implicit worst-case safety for structural anchors (memchr O(h+n) vs StringZilla O(h×n)) | `src/core/search.zig:3556,3562-3566` (scalar `std.mem.lastIndexOfScalar`/`std.mem.count` on chunk-skip); `:3651, :4423` (per-line `std.mem.trimEnd(u8, raw_line, "\r")`). | 001g | RotVec primitive in `simd.zig`; scalar chunk-skip and CR trim replaced; benchmark receipt. |

## De-Prioritization Record

Frontier consensus rejects these for IX's workload. Each row binds downstream units to NOT implement the item unless a slice-local probe proves a win.

| DP ID | Rejected Item | Primary-Source Citation | Load-Bearing Claim | Bound Slice Effect |
|-------|---------------|-------------------------|--------------------|--------------------|
| DP-1 | Inner-loop `@prefetch` on the sequential scan path (Tier 2). | Algorithmica "Algorithms for Modern Hardware" (`engine --url https://en.algorithmica/hpc/`, "So, don't bother" guidance for sequential-access prefetch, crediting Travis Downs); Travis Downs "Speed Limits" (`engine --url https://travisdowns.github.io/blog/2019/06/11/speed-limits.html` — prefetch wins only on predictable far-ahead addresses the HW prefetcher can't infer); TU Dortmund 2024 "Software Prefetching" survey (`engine --query "TU Dortmund software prefetching survey 2024"` — locality hints `_MM_HINT_T0` vs `_T2` increasingly ignored on Zen-class parts). | Modern HW prefetchers (Zen 4 SFC, Golden Cove, Granite Rapids) track strided + streaming access near-perfectly; explicit prefetch on the sequential scan path usually slows you down by stealing load ports and MSHR entries. | No slice in this chain adds `@prefetch` to the per-line or per-chunk scan loop. Reserved for cross-buffer transitions only if a future profile proves a stall. |
| DP-2 | CLMUL (`VPCLMULQDQ`) for newline/structural-boundary detection (Tier 0). | Langdale & Lemire "Parsing Gigabytes of JSON per Second" (VLDB Journal 28(6), 2019; `engine --url https://arxiv.org/abs/1902.08318`). | simdjson uses CLMUL for the backslash-escape carry chain and structural-character classification in JSON, not for plain newline finding. For newline detection, plain `VPCMPEQB+VPMOVMSKB+TZCNT` (already in `simd.zig`) is cheaper and sufficient. CLMUL earns its keep only when a carry chain (escape/quote state) must propagate across 64 bytes. | 001g uses VPCMPEQB-style memchr2/memchr3, NOT CLMUL, for structural anchoring. CLMUL is reserved for a hypothetical quoted-field mode. |
| DP-3 | SIMD Aho-Corasick with 256-wide flattened transition table (Tier 4). | Ourlis & Bellala "A SIMD Implementation of Aho-Corasick Algorithm" (SCPE Vol. 20 No. 3, 2019; `engine --url https://www.scpe.org/index.php/scpe/article/view/1572/598`); BurntSushi/aho-corasick Teddy README (`engine --url https://github.com/BurntSushi/aho-corasick/blob/master/src/packed/teddy/README.md`). | Full SIMD AC pays off only when real failure links are required; for pure literal alternates, Teddy's bucket-reject-then-verify is simpler, usually faster, and avoids the cache-hungry 256-wide flattened table that state explosion kills. | 001f implements Fat Teddy (Slim/Fat bucket-and-nibble from `.refs/aho-corasick/`), NOT SIMD-AC. |
| DP-4 | Zero-copy I/O architecture (Tier 1): io_uring SQPOLL + READ_FIXED, IOCP + FILE_FLAG_NO_BUFFERING, VM double-mapped ring. | ripgrep heuristic ("mmap for few files, streamed for many"); TigerBeetle `src/io/linux.zig` (registered buffers); Ryg "The Magic Ring Buffer" (`engine --url https://fgiesen.wordpress.com/2012/07/21/the-magic-ring-buffer/`). | These are clear wins only in the I/O-bound regime (huge/cold files); IX already has mmap zero-copy for >1 MiB files (`scanFileMmap`), and the dominant cost for IX's workload is search, not syscalls. The double-mapped ring is awkward on Windows-first targets. | No slice in this chain touches the I/O architecture. Reserved for a separate chain if profiling shows I/O as the bottleneck. |

## Research Mandate Confirmation

| Downstream Unit | Parent Anchor(s) | Slice Research Directive Obligation (locked) | Insect/Harvest Mode |
|-----------------|-------------------|----------------------------------------------|---------------------|
| 001b | U4 | Confirm Zig `want_lto` semantics and any StringZilla/PCRE2 LTO pitfalls before enabling. | `engine --query "zig want_lto addCSourceFile stringzilla pcre2 LTO"`; `engine --url https://ziglang.org/learn/build-system/`. |
| 001c | U5 | Confirm `@alignCast(32, ...)` is the correct Zig 0.16.0+ spelling and that store-to-load forwarding stalls on unaligned stack buffers are still ~12 cycles on the target microarchitectures. | `engine --query "zig 0.16 alignCast 32 store-to-load forwarding stack buffer alignment"`; `engine --query "intel zen store-to-load forwarding 12 cycle stall unaligned"`. |
| 001d | U6 | Confirm `@setCold` / `@branchHint(.cold)` spelling in Zig 0.16.0+ and that they emit the expected `llvm.setjmp`/section-placement or branch-weight metadata. | `engine --query "zig 0.16 setCold branchHint cold llvm branch weights metadata"`. |
| 001e | U1, U3 | Confirm `simd.indexOf` and `sz.indexOf` compile to equivalent AVX2 instructions and that the inlining win is real (or measure-equivalent) for the literal-scan call sites. | `engine --query "stringzilla sz_find AVX2 VPCMPEQB comptime zig inline FFI overhead"`; local `zig build -femit-asm` inspection. |
| 001f | U7, U8, U2, U3 | Harvest `.refs/aho-corasick/src/packed/teddy/README.md`, `.refs/aho-corasick/src/packed/vector.rs`, `.refs/teddy-jneem/`; confirm Slim-vs-Fat bucket/nibble structure and the bucket-assignment hash. | Local `.refs/` read (primary); `engine --url https://github.com/BurntSushi/aho-corasick/blob/master/src/packed/teddy/README.md` for cross-reference. |
| 001g | U1, U2, U3 | Harvest BurntSushi/memchr RotVec and memchr2/memchr3 composition; confirm O(h+n) worst case. | `engine --url https://github.com/BurntSushi/memchr`; `engine --query "memchr RotVec unaligned overlap read technique 2024"`. |
| 001h | U1, U2, U3, U4, U5, U6, U7, U8 | Audit that every row above has closure evidence in the corresponding archived unit. | Read-only review of `/todo/changelog/`. |

## Pre-flight Checklist

- [ ] All `dependencies` are archived in `/todo/changelog/` with non-PLACEHOLDER evidence. (None — this is the first unit.)
- [ ] All `entry_state` claims are verifiable on the current filesystem. (Parent exists; cited file:line lines are present.)
- [ ] `source_message_anchor`, `source_message_excerpt`, and `source_message_proof_obligation` are populated and match the parent source-message capture.
- [ ] `conflict_surface` is empty.
- [ ] Rollback procedure is populated for blast_radius medium or high. (N/A — low blast, no artifact change.)
- [ ] If re-executing after partial failure: idempotency_contract is read and the correct recovery path (rollback or direct re-execute) is determined. (Idempotent; direct re-execute.)
- [ ] No other slice in this chain is being advanced, edited, or interpreted while this slice is unresolved.
- [ ] Slice Research Directive records the local research baseline and either declares bounded external research with explicit Insect/harvest mode or cites the artifact that already closes the external gap.

## Entry State

- Parent `/todo/pending/001-hot-path-perf.md` exists and carries `spec_status: approved`.
- The codebase matches the audited working-tree state: `src/core/literal_alternates.zig:7` reads `TEDDY_MAX_BRANCHES = 8`; `build.zig:58,72` set no `want_lto`; `src/core/search.zig:5239-5240, 5283-5284` declare plain `[N]u8` casefold buffers; `src/core/search.zig:5271,5398,5420` call `sz.indexOf`.
- `.refs/aho-corasick/src/packed/teddy/` and `.refs/teddy-jneem/` are present in the working tree.

## Patch Surface

**Modifies:**
- (none)

**Adds:**
- (none)

**Deletes:**
- (none)

**Must not touch (out of scope for this unit):**
- All source files, build files, tests. This is a contract lock with no artifact change.

## Detailed Requirements

These are interpretation locks, not code directives. Each requirement binds a downstream unit.

- R1: The Decision Record table must contain exactly seven rows (G-1 through G-7), each citing a concrete `file:line` from the current working tree. A row without a file:line citation is malformed and fails the exit criterion.
- R2: The De-Prioritization Record table must contain exactly four rows (DP-1 through DP-4), each citing at least one primary source URL and a quoted load-bearing claim. Paraphrase without quotation is malformed.
- R3: The Research Mandate Confirmation table must contain one row per downstream implementation unit (001b through 001g) plus the review unit (001h), each naming the parent anchor(s) it serves and the Insect/harvest mode (`engine --query`, `engine --url`, or local `.refs/` read).
- R4: Run `zig build test` and capture the tail of the output. The baseline must be green (0 failures). This is the regression floor every later unit is measured against.
- R5: Run `ls .refs/aho-corasick/src/packed/teddy/ .refs/teddy-jneem/` and reproduce the directory listing in the Decision Record row G-5 evidence column. If either path is missing, halt and block — the parent's harvest directive is unsatisfiable.
- R6: Apply the slice domain standard: every de-prioritization claim is tied to a primary source, not to "the literature" or "best practice."

## Invariants This Unit Must Preserve

- I6: Existing tests pass — `zig build test` green at the baseline. (Captured in evidence.)
- I8: This baseline unit's `evidence` field carries the captured test result, not PLACEHOLDER. (This unit is baseline-only and records the exemption from the 30-test floor in R4.)

## Validation Plan

| Step | Command | Expected Exit Code | Expected Output Pattern | Idempotent |
|------|---------|-------------------|------------------------|-----------|
| 1 | `cd "E:/Workspaces/01_Projects/01_Github/ix-zig" && ls .refs/aho-corasick/src/packed/teddy/ .refs/teddy-jneem/` | `0` | `README.md\|vector.rs\|tests\|...` (non-empty listing) | yes |
| 2 | `cd "E:/Workspaces/01_Projects/01_Github/ix-zig" && grep -nc "want_lto\|@alignCast\|@setCold\|@branchHint" build.zig src/core/search.zig src/core/simd.zig` | `0` | `0` for each file (confirming the gaps exist) | yes |
| 3 | `cd "E:/Workspaces/01_Projects/01_Github/ix-zig" && zig build test 2>&1 \| tail -5` | `0` | baseline green (test pass / 0 failed) | yes |

**Evidence to capture:** The tail of `zig build test` output showing the pass/fail summary; the directory listing from step 1; the grep output from step 2 confirming the gap state. Store all three in the `evidence` field.

## Exit State (Handoff Contract)

- The Decision Record (G-1 through G-7), De-Prioritization Record (DP-1 through DP-4), and Research Mandate Confirmation tables are populated in this archived file.
- `zig build test` baseline is green; the tail is captured in the `evidence` field.
- `.refs/aho-corasick/src/packed/teddy/` and `.refs/teddy-jneem/` are confirmed present (listing in evidence).
- The gap state is confirmed: zero hits for `want_lto`/`@alignCast`/`@setCold`/`@branchHint` in the target files.
- 001b inherits G-1 as its closure signal; 001c inherits G-2; 001d inherits G-3; 001e inherits G-6; 001f inherits G-4 and G-5; 001g inherits G-7; 001h inherits the mandate to audit every row.

## Rollback Procedure

1. No artifact change. If the unit is aborted after partial population, the file simply remains in `/todo/pending/` with `status: pending`. Re-execute from pre-flight.

## Next todo

`/todo/pending/001b-hot-path-perf.md`

## Completion

- [ ] Pre-flight passed (all checklist items verified before execution began).
- [ ] Implementation-unit test floor satisfied: this unit records a baseline-only exemption (no artifact change; `zig build test` baseline captured instead).
- [ ] Tests prove the externally valuable capability through its intended entrypoint; diagnostics/logging/internal-only checks were not counted unless they are the delivered capability. (N/A — baseline.)
- [ ] All validation commands executed. Exit codes match `expected_exit_code`. Output matches `expected_output_pattern`.
- [ ] Post-flight: all Exit State claims are verifiable on the filesystem.
- [ ] Evidence captured. `evidence` field updated. PLACEHOLDER is gone.
- [ ] Status set to `done`.
- [ ] `mv /todo/pending/001a-hot-path-perf.md /todo/changelog/001a-hot-path-perf.md` — verified.
- [ ] Continue immediately to `next_todo`. No pause. No batch. No sibling-slice detour.
