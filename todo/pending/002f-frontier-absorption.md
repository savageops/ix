---
id: 002f-frontier-absorption
parent: 002-frontier-absorption
type: review-closeout
protocol_version: "2.1"
category: feature
phase: f
status: pending
patch_scope: "No artifact change. This unit reviews, validates, verifies invariants, judges code quality and domain-standard adherence, audits research coverage and source-message proof, and decides whether the chain terminates or extends."
blast_radius: low
blast_radius_justification: "Read-only execution. Validation commands do not modify system state."
idempotency_contract: idempotent
idempotency_notes: "Validation commands are read-only. Re-execution from any point is safe."
acceptance: "All chain invariants (I1-I8) pass, all four unit acceptance criteria are satisfied, all four Architectural Improvement Targets (A1-A4) are evidenced, all nine source-message anchors (U1-U9) are closed, the per-slice research mandate is honored by every implementation unit, no frontier-rejected item was smuggled in, and no scan-loop or regex regression is detected."
exit_criterion: "Either the review passes (all audits PASS, full regression green, no actionable findings) and the chain closes, or the review produces evidence-backed findings requiring a focused fix slice + new re-review slice."
validation: "cd \"E:/Workspaces/01_Projects/01_Github/ix-zig\" && zig build test 2>&1 | tail -10 && grep -n 'mid_byte\|offset_mid\|anomalies' src/core/simd.zig && grep -n 'pcre2_jit_match_8\|pcre2_match_8' src/core/pcre_regex.zig && grep -n 'gallop\|GALLOP' src/core/postings.zig && grep -n 'shufti\|Shufti' src/core/simd.zig && grep -c 'cpuid\|runtime.*dispatch' src/core/simd.zig"
expected_exit_code: 0
expected_output_pattern: "(test|PASS|0 failed|.*passed)"
evidence: "PLACEHOLDER — replace with captured final validation output."
conflict_surface: ""
invariants: []
source_message_anchor: "U1, U2, U3, U4, U5, U6, U7, U8, U9"
source_message_excerpt: "continue studying and researching the most complex genius formulas, methods, recipes, and code strategies for blazing fast search; we shouldnt get biased and stuck on existing lanes, we should zoom out and find things not yet explored or attempted; please do; Default to copying or tightly adapting proven algorithms; SZ_DYNAMIC_DISPATCH=0; 3-byte fingerprint; pcre2_jit_match_8; galloping intersection; Shufti"
source_message_proof_obligation: "Verify every source-message anchor is mapped to a completed unit, every proof obligation has evidence, the survey's Tier-S scope was honored without smuggling in Tier-C rejections, and the no-runtime-dispatch invariant held."
entry_state: "All implementation units 002a through 002e are archived in /todo/changelog/. zig build test is green at every unit boundary. The chain is in a state where full regression and architectural review can run cleanly."
rollback_surface: "None. This unit introduces no artifact changes. If review fails, the next action is chain extension."
dependencies: "002a-frontier-absorption, 002b-frontier-absorption, 002c-frontier-absorption, 002d-frontier-absorption, 002e-frontier-absorption"
next_todo: NONE
continuation: "Stay fully focused on this review until it reaches a decision. If review passes: record evidence, set status done, archive this unit, then execute Parent Archival Protocol. If review fails: do not close the chain; create the smallest fix slice required by the findings, create a new terminal re-review slice, update the parent manifest and phase plan, and continue from the new fix slice."
blocked_reason: ""
unblock_action: ""
resumption_point: ""
---
# 002f Review, Regression, and Closeout Decision

## Execute Now

Run the full regression suite, assert all chain invariants, judge the implementation quality and domain-standard adherence, audit research coverage and source-message proof, then either close the chain or extend it with the smallest fix slice the review proves is necessary.

## Review Focus Rule

This review owns the chain decision point. Do not speculate about follow-on fixes before the review findings exist. If the review passes, stop. If the review fails, extend the chain only with findings that are evidenced here.

## Domain Standard Audit

| Standard / Criterion | Declared In | Evidence Used During Implementation | Review Evidence | Status |
|----------------------|-------------|-------------------------------------|-----------------|--------|
| GS1 — Prefer vendored reference over reinvention. | Parent Gold-Standard Decision Criteria. | 002b harvest of StringZilla `find.h:280-330`; 002c harvest of PCRE2 `pcre2.h.in:783` + `pcre2_jit_match.c:91`; 002d cite of Demaine SODA 2000; 002e harvest of SMH + Vectorscan. | Reviewer confirms each unit's design notes map to the reference; `grep` confirms the new symbols. | [ ] PASS / [ ] FAIL |
| GS2 — Measurement gates every perf claim. | Parent Gold-Standard Decision Criteria. | 002b/002c/002d/002e each captured before/after benchmark receipts. | Reviewer confirms each unit's evidence field contains a benchmark JSON, not just a test pass. | [ ] PASS / [ ] FAIL |
| GS3 — No new wrapper module. | Parent Gold-Standard Decision Criteria. | Every slice extended an existing owner in place (`simd.zig`, `pcre_regex.zig`, `postings.zig`). | `ls src/core/` shows no new wrapper modules introduced by this chain. | [ ] PASS / [ ] FAIL |
| GS4 — Pure Zig + AVX2 only. | Parent Gold-Standard Decision Criteria; AGENTS.md invariant 5. | 002b/002e use `@Vector(32, u8)` only; 002c adds a PCRE2 extern but no runtime dispatch; 002d is scalar Zig. | `grep -c "cpuid\|runtime.*dispatch" src/core/simd.zig src/core/pcre_regex.zig src/core/postings.zig` returns 0. | [ ] PASS / [ ] FAIL |
| GS5 — Frontier-rejected items stay rejected. | Parent Gold-Standard Decision Criteria; 002a De-Prioritization Record. | No slice introduced CLMUL, prefetch, SIMD-AC, AVX-512, Roaring, Glushkov NFA, or Rose-lite. | Reviewer confirms via grep that no forbidden symbol/flag was introduced. | [ ] PASS / [ ] FAIL |

## Assumption Ledger Audit

| Assumption ID | Resolution Evidence | Still Risky? | Status |
|---------------|---------------------|--------------|--------|
| AS1 (3-byte fingerprint helps on source-code needles) | 002b's benchmark receipt on the case-sensitive literal workload. | [ ] YES / [ ] NO | [ ] PASS / [ ] FAIL |
| AS2 (`pcre2_jit_match_8` produces identical match offsets) | 002c's behavior tests + the fallback test. | [ ] YES / [ ] NO | [ ] PASS / [ ] FAIL |
| AS3 (galloping wins on IX's posting-list sizes) | 002d's warm-index benchmark + ratio-stratified tests. | [ ] YES / [ ] NO | [ ] PASS / [ ] FAIL |
| AS4 (Zig lowers Shufti to two PSHUFBs) | 002e's `zig build -femit-asm` excerpt. | [ ] YES / [ ] NO | [ ] PASS / [ ] FAIL |

## Better-Than-Before Audit

| Target ID | Claimed Better-Than-Before Outcome | Evidence | Status |
|-----------|------------------------------------|----------|--------|
| A1 | 3-byte rarity-pivoted fingerprint reduces false positives multiplicatively. | 002b evidence: benchmark + length-stratified tests + ASM diff. | [ ] PASS / [ ] FAIL |
| A2 | `pcre2_jit_match_8` bypasses per-line sanity checks; fallback retained. | 002c evidence: greps + behavior tests + fallback test + benchmark. | [ ] PASS / [ ] FAIL |
| A3 | Galloping dispatch achieves the Demaine adaptive bound for skewed inputs. | 002d evidence: ratio-stratified tests + dispatch-threshold test + warm-index benchmark. | [ ] PASS / [ ] FAIL |
| A4 | Pure-Zig Shufti primitive classifies 32 bytes in 3 ops, inlinable. | 002e evidence: alphabet-coverage tests + fuzz + ASM + benchmark vs `sz.indexOfByteSet`. | [ ] PASS / [ ] FAIL |

## Embedded Framing Audit

| Frame ID | Expected Embedded Meaning | Evidence In Parent / Units | Status |
|----------|---------------------------|-----------------------------|--------|
| F1 | Survey-grounded absorption — every slice traces to a primary source. | Parent Objective/Rationale; each unit's Slice Research Directive. | [ ] PASS / [ ] FAIL |
| F2 | Measurement discipline — no perf claim without paired before/after. | Parent GS2; each unit's Validation Plan. | [ ] PASS / [ ] FAIL |
| F3 | Frontier discipline — rejected items stay rejected. | Parent GS5; 002a De-Prioritization Record. | [ ] PASS / [ ] FAIL |
| F4 | Owner clarity — extend existing owners, no new modules. | Parent GS3; each unit's Existing-owner decision. | [ ] PASS / [ ] FAIL |

## Research Coverage Audit

| Research ID / Topic | Declared In | Evidence Present | Implementation Impact Recorded | Status |
|---------------------|-------------|------------------|-------------------------------|--------|
| RCH-1 (StringZilla 3-byte fingerprint harvest) | Parent Research Program; 002b Slice Research Directive. | [ ] YES / [ ] NO | [ ] YES / [ ] NO | [ ] PASS / [ ] FAIL |
| RCH-2 (PCRE2 JIT-bypass semantics) | Parent Research Program; 002c Slice Research Directive. | [ ] YES / [ ] NO | [ ] YES / [ ] NO | [ ] PASS / [ ] FAIL |
| RCH-3 (Demaine adaptive bound + TimSort threshold) | Parent Research Program; 002d Slice Research Directive. | [ ] YES / [ ] NO | [ ] YES / [ ] NO | [ ] PASS / [ ] FAIL |
| RCH-4 (Shufti mask construction from SMH/Vectorscan) | Parent Research Program; 002e Slice Research Directive. | [ ] YES / [ ] NO | [ ] YES / [ ] NO | [ ] PASS / [ ] FAIL |
| Per-slice research mandate (U4) | Parent Source Message Capture; 002a Research Mandate Confirmation. | [ ] YES / [ ] NO | [ ] YES / [ ] NO | [ ] PASS / [ ] FAIL |

## Repository Ownership Audit

| Ownership Question | Declared Owner / Evidence | Review Finding | Status |
|--------------------|---------------------------|----------------|--------|
| Did each slice modify or extend the real canonical owner? | `simd.zig` (002b, 002e), `pcre_regex.zig` (002c), `postings.zig` (002d). | Reviewer confirms via `git log`/diff that no slice touched an out-of-scope file. | [ ] PASS / [ ] FAIL |
| Were duplicate or adjacent owners collapsed or explicitly bounded? | `simd.zig` (inlinable Zig path) vs `sz.zig` (FFI path) — both slices preserved the FFI. | `grep` confirms `sz.indexOf` and `sz.indexOfByteSet` declarations unchanged. | [ ] PASS / [ ] FAIL |
| Did any slice rely on prompt-only fixes or generic gates? | Expected no. | Reviewer greps for any new wrapper introduced by the chain. | [ ] PASS / [ ] FAIL |
| Are unsupported runtime boundaries proven by probes? | PCRE2 JIT-unsupported fallback is the only runtime boundary; 002c documents it. | Reviewer confirms the fallback test exists. | [ ] PASS / [ ] FAIL |

## Original User Message Proof

| Source Anchor | Verbatim Original Snippet | Covered By Unit(s) | Evidence / Closeout Signal |
|---------------|---------------------------|--------------------|----------------------------|
| U1 | "continue studying and researching the most complex genius formulas" | 002a (lock), 002b-002e (implement), 002f (this audit) | Decision Records G-1..G-4 closed. |
| U2 | "we shouldnt get biased and stuck on existing lanes" | 002a (scope + de-prioritizations) | De-Prioritization Record DP-1..DP-8. |
| U3 | "please do" | The chain exists. | This file + parent approval. |
| U4 | "Default to copying or tightly adapting proven algorithms" | 002a-002e Slice Research Directives | Research Coverage Audit above. |
| U5 | "`SZ_DYNAMIC_DISPATCH=0`" | 002e (Shufti), all units (invariant) | `grep -c "cpuid\|runtime.*dispatch"` == 0. |
| U6 | (3-byte fingerprint) | 002b | `grep -c "mid_byte\|anomalies"` ≥ 1. |
| U7 | (PCRE2 JIT bypass) | 002c | `grep -c "pcre2_jit_match_8"` ≥ 1 AND `grep -c "pcre2_match_8"` ≥ 1. |
| U8 | (Galloping intersection) | 002d | `grep -c "gallop\|GALLOP"` ≥ 1. |
| U9 | (Shufti) | 002e | `grep -c "shufti\|Shufti"` ≥ 1. |

## Pre-flight Checklist

- [ ] Every execution unit from `002a` through `002e` is in `/todo/changelog/`.
- [ ] No unit in `/todo/changelog/` for this chain has `evidence: PLACEHOLDER`.
- [ ] No unit in `/todo/pending/` for this chain remains with `status: in-progress` or `status: blocked`.
- [ ] All exit state claims from all prior units are verifiable on the current filesystem.
- [ ] Every parent source-message anchor appears in at least one archived unit's `Original User Message Proof` section.
- [ ] Every declared parent or slice research obligation has closure evidence.
- [ ] Every parent and slice domain standard has review evidence.
- [ ] Every assumption is resolved, downgraded, or converted into a review finding.

## Invariant Assertion Surface

| Invariant ID | Statement | Verification Command | Expected Result |
|-------------|-----------|---------------------|----------------|
| I1 | No mutex/atomic in scan loop. | `grep -n "Mutex" src/core/simd.zig src/core/postings.zig src/core/pcre_regex.zig` | No scan-loop mutex introduced. |
| I2 | No per-line allocation. | Reviewer confirms. | No new allocation. |
| I3 | Compile-time SIMD only. | `grep -c "cpuid\|runtime.*dispatch" src/core/simd.zig` | `0`. |
| I4 | Strategy classification before I/O. | Reviewer confirms 002d/002e don't add runtime classification. | Preserved. |
| I5 | StringZilla C ABI surface unchanged. | `grep -c "ix_sz_" src/sz_shim.c` | Unchanged from baseline. |
| I6 | `zig build test` green. | `zig build test 2>&1 \| tail -5` | 0 failed. |
| I7 | Benchmark identity controls — no regression. | Benchmark runner on literal-alternates, case-sensitive literal, regex, warm-index | Within noise or improved. |
| I8 | Evidence fields populated. | `grep -l PLACEHOLDER /todo/changelog/002[a-e]-*.md` | No matches. |

## Acceptance Criteria Matrix

| Unit | Acceptance Criterion | Status |
|------|---------------------|--------|
| 002a | Decision/De-Prioritization/Research-Mandate/001-Handoff tables populated; baseline green. | [ ] PASS / [ ] FAIL |
| 002b | 3-byte rarity-pivoted fingerprint; length-stratified tests; benchmark receipt. | [ ] PASS / [ ] FAIL |
| 002c | `pcre2_jit_match_8` primary + `pcre2_match_8` fallback; behavior + fallback tests; benchmark. | [ ] PASS / [ ] FAIL |
| 002d | Galloping dispatch at ratio ~8:1; merge preserved; ratio-stratified tests; warm-index benchmark. | [ ] PASS / [ ] FAIL |
| 002e | Pure-Zig Shufti primitive; alphabet tests + fuzz; ASM confirms two PSHUFBs; benchmark vs FFI. | [ ] PASS / [ ] FAIL |

## Source Message Coverage Audit

| Source Anchor | Original Snippet Present In Parent | Covered By Unit | Evidence Present | Status |
|---------------|------------------------------------|-----------------|------------------|--------|
| U1 | [ ] YES / [ ] NO | 002a, 002b-002e, 002f | [ ] YES / [ ] NO | [ ] PASS / [ ] FAIL |
| U2 | [ ] YES / [ ] NO | 002a | [ ] YES / [ ] NO | [ ] PASS / [ ] FAIL |
| U3 | [ ] YES / [ ] NO | (the chain's existence) | [ ] YES / [ ] NO | [ ] PASS / [ ] FAIL |
| U4 | [ ] YES / [ ] NO | 002a-002e | [ ] YES / [ ] NO | [ ] PASS / [ ] FAIL |
| U5 | [ ] YES / [ ] NO | 002e, all units | [ ] YES / [ ] NO | [ ] PASS / [ ] FAIL |
| U6 | [ ] YES / [ ] NO | 002b | [ ] YES / [ ] NO | [ ] PASS / [ ] FAIL |
| U7 | [ ] YES / [ ] NO | 002c | [ ] YES / [ ] NO | [ ] PASS / [ ] FAIL |
| U8 | [ ] YES / [ ] NO | 002d | [ ] YES / [ ] NO | [ ] PASS / [ ] FAIL |
| U9 | [ ] YES / [ ] NO | 002e | [ ] YES / [ ] NO | [ ] PASS / [ ] FAIL |

## Regression Surface

**Files in combined patch surface:**
- `src/core/simd.zig` — touched by `002b` (3-byte fingerprint) and `002e` (Shufti namespace).
- `src/core/pcre_regex.zig` — touched by `002c` (JIT bypass).
- `src/core/postings.zig` — touched by `002d` (galloping dispatch).

## Full Regression Validation Plan

| Step | Command | Expected Exit Code | Expected Output Pattern |
|------|---------|-------------------|------------------------|
| 1 | `cd "E:/Workspaces/01_Projects/01_Github/ix-zig" && zig build test 2>&1 \| tail -10` | `0` | all tests pass, 0 failed |
| 2 | `cd "E:/Workspaces/01_Projects/01_Github/ix-zig" && zig build 2>&1 \| tail -3` | `0` | successful build |
| 3 | `cd "E:/Workspaces/01_Projects/01_Github/ix-zig" && grep -c "mid_byte\|offset_mid\|anomalies\|locateNeedleAnomalies" src/core/simd.zig` | `0` | ≥1 |
| 4 | `cd "E:/Workspaces/01_Projects/01_Github/ix-zig" && grep -c "pcre2_jit_match_8" src/core/pcre_regex.zig && grep -c "pcre2_match_8" src/core/pcre_regex.zig` | `0` | both ≥1 |
| 5 | `cd "E:/Workspaces/01_Projects/01_Github/ix-zig" && grep -c "gallop\|GALLOP" src/core/postings.zig` | `0` | ≥1 |
| 6 | `cd "E:/Workspaces/01_Projects/01_Github/ix-zig" && grep -c "shufti\|Shufti\|SHUFTI" src/core/simd.zig` | `0` | ≥1 |
| 7 | `cd "E:/Workspaces/01_Projects/01_Github/ix-zig" && grep -c "cpuid\|runtime.*dispatch" src/core/simd.zig src/core/pcre_regex.zig src/core/postings.zig` | `0` | `0` for each file |
| 8 | Benchmark runner on literal-alternates, case-sensitive literal, regex, warm-index | `0` | no regression beyond noise |
| 9 | `grep -l PLACEHOLDER /todo/changelog/002[a-e]-*.md 2>/dev/null; echo "exit:$?"` | `0` | no PLACEHOLDER |

**Evidence to capture:** Full stdout from all validation commands. This is the aggregate chain evidence.

## Review Findings And Extension Decision

| Finding ID | Severity | Surface | Evidence | Requires Extension? |
|------------|----------|---------|----------|---------------------|
| (populated during review execution) | | | | |

## Regression Triage (if failures occur)

1. Identify which test(s) failed.
2. Trace the failure to its origin: which slice's patch surface introduced it?
3. Determine: regression, incomplete implementation, or structural defect?
4. If real and in-scope: extend the chain by creating one focused fix slice (`002g-frontier-absorption.md`) and one new terminal re-review slice (`002h-frontier-absorption.md`). Update parent manifest, Phase Plan, `subtodo_final`, and Better-Than-Before Audit rows. Do not close the chain yet.
5. If external blockers: block this review unit with `blocked_reason` naming the exact blocker.

## Chain Audit

- [ ] Chain manifest in parent is complete: every planned letter (a–f) has a file in `/todo/changelog/`.
- [ ] Parent's Phase Plan table: all letters marked `archived`.
- [ ] No files for this chain remain in `/todo/pending/` except the parent and this unit.
- [ ] Source Message Coverage Audit shows PASS for every original user-message anchor (U1-U9).
- [ ] Research Coverage Audit shows PASS for every declared research obligation (RCH-1 through RCH-4 + per-slice mandate).
- [ ] Better-Than-Before Audit shows PASS for every architectural improvement target (A1-A4).
- [ ] Embedded Framing Audit shows PASS for every declared gold-standard framing contract (F1-F4).
- [ ] Domain Standard Audit shows PASS for every declared gold-standard decision criterion (GS1-GS5).
- [ ] Assumption Ledger Audit has no unresolved blocking assumptions (AS1-AS4 resolved).
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
- [ ] If review passes: status set to `done`, `mv /todo/pending/002f-frontier-absorption.md /todo/changelog/002f-frontier-absorption.md` verified, Parent Archival Protocol executed, chain complete.
- [ ] If review fails: parent extended with fix slice + re-review slice, current review unit records the findings, execution continues to the new fix slice.
