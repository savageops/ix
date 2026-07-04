---
id: 001h-hot-path-perf
parent: 001-hot-path-perf
type: review-closeout
protocol_version: "2.1"
category: feature
phase: h
status: pending
patch_scope: "No artifact change. This unit reviews, validates, verifies invariants, judges code quality and domain-standard adherence, audits research coverage and source-message proof, and decides whether the chain terminates or extends."
blast_radius: low
blast_radius_justification: "Read-only execution. Validation commands do not modify system state."
idempotency_contract: idempotent
idempotency_notes: "Validation commands are read-only. Re-execution from any point is safe."
acceptance: "All chain invariants (I1-I8) pass, all prior unit acceptance criteria are satisfied, all six Architectural Improvement Targets (A1-A6) are evidenced, all eight source-message anchors (U1-U8) are closed, the per-slice research mandate (U3) is honored by every implementation unit, code structure remains canonical (no new wrapper modules introduced), and no scan-loop regression is detected on the benchmark."
exit_criterion: "Either the review passes (all audits PASS, full regression green, no actionable findings) and the chain closes, or the review produces evidence-backed findings requiring a focused fix slice + new re-review slice."
validation: "cd \"E:/Workspaces/01_Projects/01_Github/ix-zig\" && zig build test 2>&1 | tail -10 && grep -n 'want_lto' build.zig && grep -c '@alignCast(32' src/core/search.zig && grep -c '@setCold\\|@branchHint' src/core/search.zig src/core/simd.zig && grep -n 'TEDDY_FAT\\|FatTeddy\\|fat_teddy' src/core/literal_alternates.zig | head -3 && grep -n 'indexOf2\\|indexOf3' src/core/simd.zig"
expected_exit_code: 0
expected_output_pattern: "(test|PASS|0 failed|.*passed)"
evidence: "PLACEHOLDER — replace with captured final validation output. Chain cannot terminate until this is populated."
conflict_surface: ""
invariants: []
source_message_anchor: "U1, U2, U3, U4, U5, U6, U7, U8"
source_message_excerpt: "wha your unbiased opinion is on areas to review where performance improvements can be made; studying the web, the refs the docs research; Make sure the todo slices each demand mandatory unavoidable computer science / algorithm / hardware / system / code WEB RESEARCH using insect skill; LTO across Zig/C boundary; @alignCast(32, ...) on casefold buffers; @setCold() on error/fallback paths; Aho-Corasick automaton for literal alternates; Default to copying or tightly adapting proven algorithms ... from the highest-quality reference repos"
source_message_proof_obligation: "Verify every source-message anchor is mapped to a completed unit, every proof obligation has evidence, every AGENTS.md invariant gap is closed or reconciled, the per-slice research mandate (U3) is honored by every implementation unit, and no original-user-message requirement was lost between parent and closeout."
entry_state: "All implementation units 001a through 001g are archived in /todo/changelog/. All exit states from 001b through 001g are provably true. zig build test is green at every unit boundary. The chain is in a state where full regression and architectural review can run cleanly."
rollback_surface: "None. This unit introduces no artifact changes. If review fails, the next action is chain extension (focused fix slice + re-review), not rollback of this unit."
dependencies: "001a-hot-path-perf, 001b-hot-path-perf, 001c-hot-path-perf, 001d-hot-path-perf, 001e-hot-path-perf, 001f-hot-path-perf, 001g-hot-path-perf"
next_todo: NONE
continuation: "Stay fully focused on this review until it reaches a decision. If review passes: record evidence, set status done, archive this unit, then execute Parent Archival Protocol. If review fails: do not close the chain; create the smallest fix slice required by the findings, create a new terminal re-review slice, update the parent manifest and phase plan, and continue from the new fix slice."
blocked_reason: ""
unblock_action: ""
resumption_point: ""
---
# 001h Review, Regression, and Closeout Decision

## Execute Now

Run the full regression suite, assert all chain invariants (I1-I8), judge the implementation quality and domain-standard adherence, audit research coverage and source-message proof, then either close the chain or extend it with the smallest fix slice the review proves is necessary.

## Review Focus Rule

This review owns the chain decision point. Do not speculate about follow-on fixes before the review findings exist. If the review passes, stop. If the review fails, extend the chain only with findings that are evidenced here. Do not pre-author a fix slice.

## Domain Standard Audit

| Standard / Criterion | Declared In | Evidence Used During Implementation | Review Evidence | Status |
|----------------------|-------------|-------------------------------------|-----------------|--------|
| GS1 — Prefer vendored reference over reinvention for Fat Teddy. | Parent Gold-Standard Decision Criteria. | 001f's Slice Research Directive harvest of `.refs/aho-corasick/src/packed/teddy/` + `.refs/teddy-jneem/`. | Reviewer confirms 001f's design notes map each Fat Teddy element to the vendored source; `grep` for the nibble-shuffle constants in `literal_alternates.zig`. | [ ] PASS / [ ] FAIL |
| GS2 — Reject frontier-deprioritized items (SIMD-AC, CLMUL newline, inner-loop prefetch) unless a slice-local probe proves a win. | Parent Gold-Standard Decision Criteria; 001a De-Prioritization Record. | No slice introduced SIMD-AC, CLMUL newline, or inner-loop `@prefetch`. | `grep -n 'VPCLMULQDQ\|pclmul\|prefetch' src/core/` returns no hot-loop hits; review confirms no slice violated DP-1/DP-2/DP-3. | [ ] PASS / [ ] FAIL |
| GS3 — Every AGENTS.md invariant-vs-binary gap is fixed or explicitly de-prioritized with a measurement reason. | Parent Gold-Standard Decision Criteria; 001a Decision Record G-1..G-7. | 001b (LTO or reconciliation), 001c (alignment), 001d (cold paths), 001e (simd routing), 001f (Fat Teddy), 001g (RotVec). | Reviewer confirms each G-row has closure evidence in the corresponding archived unit. | [ ] PASS / [ ] FAIL |
| GS4 — No new owner/registry/gate/wrapper created. | Parent Gold-Standard Decision Criteria. | Every slice extended an existing owner (`build.zig`, `search.zig`, `simd.zig`, `literal_alternates.zig`). | `ls src/core/` shows no new wrapper modules (`teddy_fat.zig`, `simd_backend.zig`, etc.) introduced by this chain. | [ ] PASS / [ ] FAIL |
| GS5 — Measurement gates every performance claim. | Parent Gold-Standard Decision Criteria. | 001b, 001e, 001f, 001g each captured benchmark receipts. | Reviewer confirms each perf-claim unit's evidence field contains a before/after JSON, not just a test pass. | [ ] PASS / [ ] FAIL |

## Assumption Ledger Audit

| Assumption ID | Resolution Evidence | Still Risky? | Status |
|---------------|---------------------|--------------|--------|
| AS1 (casefold buffers unaligned) | 001c added `@alignCast(32)` to all four sites; regression test asserts runtime alignment. | [ ] YES / [ ] NO | [ ] PASS / [ ] FAIL |
| AS2 (Fat Teddy outperforms scalar/PCRE2 for >8 branches) | 001f's 12-branch and 16-branch benchmark receipts show the Fat path engaged with no scalar/PCRE2 fallback. | [ ] YES / [ ] NO | [ ] PASS / [ ] FAIL |
| AS3 (LTO does not break StringZilla/PCRE2 build) | 001b either delivered LTO with `zig build test` green and the four C ABI symbols surviving, or recorded a Decision Record with the failing output. | [ ] YES / [ ] NO | [ ] PASS / [ ] FAIL |
| AS4 (simd.indexOf outperforms or matches sz.indexOf post-LTO at literal call sites) | 001e's two-workload benchmark receipt confirms no regression. | [ ] YES / [ ] NO | [ ] PASS / [ ] FAIL |
| AS5 (no inner-loop prefetch is correct) | 001a De-Prioritization Record DP-1 cites Algorithmica + Travis Downs + TU Dortmund 2024; no slice added prefetch. | [ ] YES / [ ] NO | [ ] PASS / [ ] FAIL |

## Better-Than-Before Audit

| Target ID | Claimed Better-Than-Before Outcome | Evidence | Status |
|-----------|------------------------------------|----------|--------|
| A1 | LTO claim reconciled: either enabled with measured delta or AGENTS.md Tier 3 entry reconciled with measurement note. | `grep want_lto build.zig` + 001b evidence (receipt or Decision Record). | [ ] PASS / [ ] FAIL |
| A2 | All four casefold stack buffers carry `@alignCast(32, ...)`. | `grep -c '@alignCast(32' src/core/search.zig` ≥ 4. | [ ] PASS / [ ] FAIL |
| A3 | Cold paths marked `@setCold`/`@branchHint(.cold)`. | `grep -c '@setCold\|@branchHint' src/core/search.zig src/core/simd.zig` ≥1 per file. | [ ] PASS / [ ] FAIL |
| A4 | Case-sensitive literal scans route through `simd.indexOf`; comment at search.zig:5267 now matches code. | Diff at search.zig:5271,5398,5420; `sz.indexOfAdmission` count unchanged. | [ ] PASS / [ ] FAIL |
| A5 | Fat Teddy handles >8 branches via 16-bucket nibble-shuffle, harvested from `.refs/aho-corasick/`. | `grep 'TEDDY_FAT\|FatTeddy' src/core/literal_alternates.zig`; ≥30 new tests; 12/16-branch benchmark receipts. | [ ] PASS / [ ] FAIL |
| A6 | RotVec SIMD primitives replace scalar chunk-skip; CR trim is a single-byte branch. | `grep 'indexOf2\|indexOf3' src/core/simd.zig`; diff at search.zig:3556,3562-3566,3651,4423. | [ ] PASS / [ ] FAIL |

## Embedded Framing Audit

| Frame ID | Expected Embedded Meaning | Evidence In Parent / Units | Status |
|----------|---------------------------|-----------------------------|--------|
| F1 | Invariant-to-binary truth — every AGENTS.md claim observable in the binary or reconciled. | Parent Objective/Rationale/A1-A4; 001b-001d acceptance wording. | [ ] PASS / [ ] FAIL |
| F2 | Frontier-corrected reuse — Fat Teddy not SIMD-AC, memchr not CLMUL, no inner-loop prefetch. | Parent Domain Expertise Baseline, GS1/GS2, 001f/001g directives; 001a DP records. | [ ] PASS / [ ] FAIL |
| F3 | Measurement discipline — no perf claim without paired before/after. | Parent GS5/I7; each implementation unit's Validation Plan. | [ ] PASS / [ ] FAIL |
| F4 | Single canonical owner — extend existing files, no new wrapper modules. | Parent GS4/Repository Ownership Reconnaissance; each unit's Existing-owner decision. | [ ] PASS / [ ] FAIL |

## Research Coverage Audit

| Research ID / Topic | Declared In | Evidence Present | Implementation Impact Recorded | Status |
|---------------------|-------------|------------------|-------------------------------|--------|
| RCH-1 (Fat Teddy harvest) | Parent Research Program; 001f Slice Research Directive. | [ ] YES / [ ] NO | [ ] YES / [ ] NO | [ ] PASS / [ ] FAIL |
| RCH-2 (LTO measurement) | Parent Research Program; 001b Slice Research Directive. | [ ] YES / [ ] NO | [ ] YES / [ ] NO | [ ] PASS / [ ] FAIL |
| RCH-3 (RotVec memchr) | Parent Research Program; 001g Slice Research Directive. | [ ] YES / [ ] NO | [ ] YES / [ ] NO | [ ] PASS / [ ] FAIL |
| RCH-4 (de-prioritization sources) | Parent Research Program; 001a De-Prioritization Record (DP-1 through DP-4). | [ ] YES / [ ] NO | [ ] YES / [ ] NO | [ ] PASS / [ ] FAIL |
| Per-slice research mandate (U3) | Parent Source Message Capture; 001a Research Mandate Confirmation table. | [ ] YES / [ ] NO — every implementation unit's Slice Research Directive populated | [ ] YES / [ ] NO | [ ] PASS / [ ] FAIL |

## Repository Ownership Audit

| Ownership Question | Declared Owner / Evidence | Review Finding | Status |
|--------------------|---------------------------|----------------|--------|
| Did each slice modify or extend the real canonical owner? | build.zig (001b), search.zig (001c, 001d, 001e, 001g), simd.zig (001d, 001g), literal_alternates.zig (001f). | Reviewer confirms via `git log`/diff that no slice touched an out-of-scope file. | [ ] PASS / [ ] FAIL |
| Were duplicate or adjacent owners collapsed or explicitly bounded? | simd.zig vs sz.zig — 001e preserved sz.indexOfAdmission; 001g added to simd.zig without duplicating sz. | `grep` confirms no parallel primitive added to sz.zig. | [ ] PASS / [ ] FAIL |
| Did any slice rely on prompt-only fixes, hardcoded triggers, or active-tool absence? | Expected no. | Reviewer greps for any new wrapper/gate/dispatcher introduced by the chain. | [ ] PASS / [ ] FAIL |
| Are unsupported runtime boundaries proven by probes rather than broad unavailability claims? | Expected no — the chain does not claim any runtime boundary. | Reviewer confirms. | [ ] PASS / [ ] FAIL |

## Original User Message Proof

| Source Anchor | Verbatim Original Snippet | Covered By Unit(s) | Evidence / Closeout Signal |
|---------------|---------------------------|--------------------|----------------------------|
| U1 | "wha your unbiased opinion is on areas to review where performance improvements can be made" | 001a (lock), 001b-001g (implement), 001h (this audit) | Decision Record G-1..G-7 closed across the chain. |
| U2 | "studying the web, the refs the docs research" | 001a-001g Slice Research Directives | Research Coverage Audit above. |
| U3 | "Make sure the todo slices each demand mandatory unavoidable computer science / algorithm / hardware / system / code WEB RESEARCH using insect skill" | 001a Research Mandate Confirmation; 001b-001g Slice Research Directives | Per-unit Research Coverage row above. |
| U4 | "LTO across Zig/C boundary — `want_lto = true` on C source steps" | 001b | `grep want_lto build.zig` or 001b Decision Record. |
| U5 | "`@alignCast(32, ...) on casefold buffers`" | 001c | `grep '@alignCast(32' src/core/search.zig` ≥ 4. |
| U6 | "`@setCold() on error/fallback paths`" | 001d | `grep '@setCold\|@branchHint'` per file. |
| U7 | "Aho-Corasick automaton for literal alternates" | 001f | Fat Teddy in `literal_alternates.zig`; ≥30 tests; receipts. |
| U8 | "Default to copying or tightly adapting proven algorithms ... from the highest-quality reference repos" | 001f (harvest) | Design notes mapping to `.refs/aho-corasick/`. |

## Pre-flight Checklist

- [ ] Every execution unit from `001a` through `001g` is in `/todo/changelog/`.
- [ ] No unit in `/todo/changelog/` for this chain has `evidence: PLACEHOLDER`.
- [ ] No unit in `/todo/pending/` for this chain remains with `status: in-progress` or `status: blocked`.
- [ ] All exit state claims from all prior units are verifiable on the current filesystem.
- [ ] Every parent source-message anchor appears in at least one archived unit's `Original User Message Proof` section.
- [ ] Every declared parent or slice research obligation has closure evidence or an explicit no-research justification.
- [ ] Every parent and slice domain standard has review evidence or a documented failure finding.
- [ ] Every assumption in the parent or slices is resolved, downgraded with evidence, or converted into a review finding.

## Invariant Assertion Surface

| Invariant ID | Statement | Verification Command | Expected Result |
|-------------|-----------|---------------------|----------------|
| I1 | No mutex/atomic in scan loop (atomics only at file-claim granularity). | `grep -n "Mutex" src/core/search.zig` returns no scan-loop hits; `grep -n "atomicRmw" src/core/search.zig` returns only file-claim sites. | No new mutex/atomic introduced by the chain. |
| I2 | No per-line allocation in scan loop. | Reviewer confirms no slice added per-line allocation. | No new per-line allocation. |
| I3 | Compile-time SIMD selection only — no runtime dispatch. | `grep -n "cpuid\|CPU feature\|runtime.*dispatch" src/core/` | No new runtime dispatch introduced by 001f/001g. |
| I4 | Strategy classification before I/O. | `grep -n "teddyFatPlan\|Fat Teddy" src/core/literal_alternates.zig` confirms Fat selection is in `teddyPlanWithOffset` (parse time). | Fat-vs-Slim selection is plan-build-time. |
| I5 | StringZilla symbol surface unchanged. | `nm zig-out/bin/ix.exe \| grep -c "ix_sz_"` | 4 (the four C ABI symbols survive). |
| I6 | `zig build test` green. | `zig build test 2>&1 \| tail -5` | 0 failed. |
| I7 | Benchmark identity control — no scan regression. | Benchmark runner on literal-alternates workload | Within noise thresholds or improved. |
| I8 | Every implementation unit's evidence field populated (no PLACEHOLDER). | `grep -l PLACEHOLDER /todo/changelog/001[a-g]-*.md` | No matches. |

## Acceptance Criteria Matrix

| Unit | Acceptance Criterion | Status |
|------|---------------------|--------|
| 001a | Decision Record (G-1..G-7), De-Prioritization Record (DP-1..DP-4), Research Mandate Confirmation populated; baseline test green. | [ ] PASS / [ ] FAIL |
| 001b | LTO enabled with receipt OR measurement-backed Decision Record; `zig build test` green; C ABI symbols survive. | [ ] PASS / [ ] FAIL |
| 001c | `@alignCast(32)` on four casefold buffers; alignment regression test passing; `zig build test` green. | [ ] PASS / [ ] FAIL |
| 001d | Cold paths marked; behavior-preservation tests passing; benchmark no hot-path regression. | [ ] PASS / [ ] FAIL |
| 001e | Three case-sensitive literal sites routed to `simd.indexOf`; `sz.indexOfAdmission` preserved; two-workload receipt. | [ ] PASS / [ ] FAIL |
| 001f | Fat Teddy handles 9-16 branches; ≥30 new tests; Slim tests unchanged; three-workload receipt; `.refs/` harvest notes. | [ ] PASS / [ ] FAIL |
| 001g | RotVec `indexOf2`/`indexOf3` in simd.zig; scalar chunk-skip and CR trim replaced; RotVec overlap tests passing; receipt. | [ ] PASS / [ ] FAIL |

## Source Message Coverage Audit

| Source Anchor | Original Snippet Present In Parent | Covered By Unit | Evidence Present | Status |
|---------------|------------------------------------|-----------------|------------------|--------|
| U1 | [ ] YES / [ ] NO | 001a, 001b-001g, 001h | [ ] YES / [ ] NO | [ ] PASS / [ ] FAIL |
| U2 | [ ] YES / [ ] NO | 001a-001g | [ ] YES / [ ] NO | [ ] PASS / [ ] FAIL |
| U3 | [ ] YES / [ ] NO | 001a-001g | [ ] YES / [ ] NO | [ ] PASS / [ ] FAIL |
| U4 | [ ] YES / [ ] NO | 001b | [ ] YES / [ ] NO | [ ] PASS / [ ] FAIL |
| U5 | [ ] YES / [ ] NO | 001c | [ ] YES / [ ] NO | [ ] PASS / [ ] FAIL |
| U6 | [ ] YES / [ ] NO | 001d | [ ] YES / [ ] NO | [ ] PASS / [ ] FAIL |
| U7 | [ ] YES / [ ] NO | 001f | [ ] YES / [ ] NO | [ ] PASS / [ ] FAIL |
| U8 | [ ] YES / [ ] NO | 001f | [ ] YES / [ ] NO | [ ] PASS / [ ] FAIL |

## Regression Surface

**Files in combined patch surface:**
- `build.zig` — touched by `001b`
- `src/core/search.zig` — touched by `001c`, `001d`, `001e`, `001g`
- `src/core/simd.zig` — touched by `001d`, `001g`
- `src/core/literal_alternates.zig` — touched by `001f`

## Full Regression Validation Plan

| Step | Command | Expected Exit Code | Expected Output Pattern |
|------|---------|-------------------|------------------------|
| 1 | `cd "E:/Workspaces/01_Projects/01_Github/ix-zig" && zig build test 2>&1 \| tail -10` | `0` | all tests pass, 0 failed, including all new Teddy/alignment/cold/RotVec tests |
| 2 | `cd "E:/Workspaces/01_Projects/01_Github/ix-zig" && zig build 2>&1 \| tail -3` | `0` | successful link |
| 3 | `cd "E:/Workspaces/01_Projects/01_Github/ix-zig" && grep -n 'want_lto' build.zig` | `0` | hit(s) OR documented absence with 001b Decision Record |
| 4 | `cd "E:/Workspaces/01_Projects/01_Github/ix-zig" && grep -c '@alignCast(32' src/core/search.zig` | `0` | ≥4 |
| 5 | `cd "E:/Workspaces/01_Projects/01_Github/ix-zig" && grep -c '@setCold\|@branchHint' src/core/search.zig src/core/simd.zig` | `0` | ≥1 per file |
| 6 | `cd "E:/Workspaces/01_Projects/01_Github/ix-zig" && grep -n 'TEDDY_FAT\|FatTeddy\|fat_teddy' src/core/literal_alternates.zig \| head -3` | `0` | new Fat constants/dispatch present |
| 7 | `cd "E:/Workspaces/01_Projects/01_Github/ix-zig" && grep -n 'indexOf2\|indexOf3' src/core/simd.zig` | `0` | new RotVec primitive exported |
| 8 | `cd "E:/Workspaces/01_Projects/01_Github/ix-zig" && nm zig-out/bin/ix.exe 2>/dev/null \| grep -c "ix_sz_"` | `0` | 4 |
| 9 | Benchmark runner on literal-alternates + case-sensitive literal + 12/16-branch fixtures | `0` | no regression beyond noise; Fat territory improved |
| 10 | `grep -l PLACEHOLDER /todo/changelog/001[a-g]-*.md 2>/dev/null; echo "exit:$?"` | `0` | no PLACEHOLDER in archived evidence fields |

**Evidence to capture:** Full stdout from all validation commands. This is the aggregate chain evidence.

## Review Findings And Extension Decision

| Finding ID | Severity | Surface | Evidence | Requires Extension? |
|------------|----------|---------|----------|---------------------|
| (populated during review execution) | | | | |

## Regression Triage (if failures occur)

1. Identify which test(s) or lint rule(s) failed.
2. Trace the failure to its origin: which execution unit's patch surface introduced it?
3. Determine: regression (invariant broken by a prior unit), incomplete implementation (acceptance not met), or structural defect requiring a focused fix slice?
4. If real and in-scope: extend the chain by creating one focused fix slice (`001i-hot-path-perf.md`) and one new terminal re-review slice (`001j-hot-path-perf.md`). Update parent manifest, Phase Plan, `subtodo_final`, and Better-Than-Before Audit rows. Do not close the chain yet.
5. If external blockers: block this review unit with `blocked_reason` naming the exact blocker and preserve the implementation obligation.

## Chain Audit

- [ ] Chain manifest in parent is complete: every planned letter (a–h) has a file in `/todo/changelog/`.
- [ ] Parent's Phase Plan table: all letters marked `archived`.
- [ ] No files for this chain remain in `/todo/pending/` except the parent and this unit.
- [ ] Source Message Coverage Audit shows PASS for every original user-message anchor (U1-U8).
- [ ] Research Coverage Audit shows PASS for every declared research obligation (RCH-1 through RCH-4 + per-slice mandate).
- [ ] Better-Than-Before Audit shows PASS for every architectural improvement target (A1-A6).
- [ ] Embedded Framing Audit shows PASS for every declared gold-standard framing contract (F1-F4).
- [ ] Domain Standard Audit shows PASS for every declared gold-standard decision criterion (GS1-GS5).
- [ ] Assumption Ledger Audit has no unresolved blocking assumptions (AS1-AS5 resolved).
- [ ] All invariants in Invariant Assertion Surface table show PASS (I1-I8).
- [ ] All acceptance criteria in Acceptance Criteria Matrix show PASS.

## Next todo

`NONE`

## Completion

- [ ] All pre-flight checks passed.
- [ ] Full regression suite executed. All commands exit 0. All output patterns matched.
- [ ] All invariants asserted: PASS.
- [ ] All acceptance criteria resolved: PASS.
- [ ] Review findings table resolved: either no extension required, or extension created and parent updated.
- [ ] Chain audit complete: all rows verified.
- [ ] Evidence captured. `evidence` field populated with full regression stdout. PLACEHOLDER is gone.
- [ ] If review passes: status set to `done`, `mv /todo/pending/001h-hot-path-perf.md /todo/changelog/001h-hot-path-perf.md` verified, Parent Archival Protocol executed, chain complete.
- [ ] If review fails: parent extended with fix slice + re-review slice, current review unit records the findings that caused the extension, and execution continues to the new fix slice.
