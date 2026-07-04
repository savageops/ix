---
id: 002a-frontier-absorption
parent: 002-frontier-absorption
type: execution-unit
protocol_version: "2.1"
category: feature
phase: a
status: pending
patch_scope: "Interpretation freeze and invariant declaration. No artifact change. Locks the survey's Tier-S findings, the per-slice research mandates, the no-runtime-dispatch constraint, and the non-overlap handoff with chain 001."
blast_radius: low
blast_radius_justification: "Read-only unit. No source, build, or test files modified. The only output is the locked interpretation inherited by downstream units."
idempotency_contract: idempotent
idempotency_notes: "No artifact change. Re-executing produces the same locked interpretation. Recovery is a no-op."
acceptance: "The Decision Record (G-1 through G-4), De-Prioritization Record (DP-1 through DP-4, inherited from 001a plus the survey's full set), Research Mandate Confirmation table, and 001-handoff note are populated in this file's body. Every gap cites a concrete file:line. Every de-prioritization names a primary source."
exit_criterion: "This file's body contains the four populated tables plus the 001-handoff section, `zig build test` continues to pass (baseline not perturbed), and the survey's Tier-S/C items are enumerated with their dispositions."
validation: "cd \"E:/Workspaces/01_Projects/01_Github/ix-zig\" && zig build test 2>&1 | tail -5"
expected_exit_code: 0
expected_output_pattern: "(test|PASS|0 failed|.*passed)"
evidence: "PLACEHOLDER — replace with exact captured stdout at completion."
conflict_surface: "001-hot-path-perf (concurrent chain — explicit non-overlap handoff below)"
invariants:
  - "I3: Compile-time SIMD only — no runtime dispatch."
  - "I6: Existing tests pass — `zig build test` baseline."
  - "I8: This baseline unit's `evidence` field carries the captured test result, not PLACEHOLDER."
source_message_anchor: "U1, U2, U3, U4, U5, U6, U7, U8, U9"
source_message_excerpt: "continue studying and researching the most complex genius formulas, methods, recipes, and code strategies for blazing fast search; we shouldnt get biased and stuck on existing lanes, we should zoom out and find things not yet explored or attempted; please do; Default to copying or tightly adapting proven algorithms; SZ_DYNAMIC_DISPATCH=0; 3-byte fingerprint; pcre2_jit_match_8; galloping intersection; Shufti"
source_message_proof_obligation: "Freeze the survey's Tier-S findings as the chain scope; lock the no-runtime-dispatch and no-overlap-with-001 constraints; bind every downstream unit to its primary-source research mandate."
entry_state: "Parent `002-frontier-absorption.md` is approved and in `/todo/pending/`. Codebase matches the audited working-tree state: `simd.zig::indexOf` uses 2-byte first+last fingerprint (lines 63-109); `pcre_regex.zig::column/count` call `pcre2_match_8` (lines 139, 165); `postings.zig::intersectFileIds` is a two-pointer merge (lines 990-1008); `simd.zig` has no Shufti primitive."
rollback_surface: "None. No artifact change."
dependencies: ""
next_todo: /todo/pending/002b-frontier-absorption.md
continuation: "On completion: record evidence, set status done, move to /todo/changelog/002a-frontier-absorption.md, continue immediately to /todo/pending/002b-frontier-absorption.md. Stay focused on this slice."
blocked_reason: ""
unblock_action: ""
resumption_point: ""
---
# 002a Baseline / Contract Lock

## Execute Now

Freeze the survey's Tier-S findings as binding decision records, lock the no-runtime-dispatch invariant, record the 001-handoff for the shared `simd.zig` file, and bind every downstream unit to its per-slice research mandate.

## Slice Focus Rule

This unit owns the agent's attention until the four tables below are populated and the baseline test output is captured. The agent must not skip to implementation, must not begin the StringZilla/PCRE2/Demaine/Shufti harvests (those belong to 002b–002e), and must not reinterpret the parent's scope. Any ambiguity in the survey's wording is resolved here, in writing, before any later unit begins.

## Why This Execution Unit Exists

This slice exists because the survey identified ten frontiers (S1–S5, A1–A5, B1–B5, C1–C11) and the parent chose four. Downstream units need a single frozen interpretation of which four, why those four, and why the others were rejected. Without this lock, 002b could drift into AVX-512 territory (Tier A2), 002d could over-reach into Roaring (Tier A1), or 002e could smuggle in CLMUL (DP-2). Merging this lock into the first implementation unit would contaminate the baseline test capture with interpretation work.

## Better-Than-Before Delta

This slice leaves the chain with a written contract that makes every downstream acceptance criterion falsifiable: each gap cites a file:line, each de-prioritization cites a primary source, and each research obligation traces to a row here. The pre-slice weakness is that the survey's conclusions exist only in conversation history; the post-slice improvement is that they exist as a reviewable artifact in the repository.

## Slice Domain Standard

| Domain Standard | Local Evidence | Implementation Consequence | Anti-Assumption Guard |
|-----------------|----------------|----------------------------|-----------------------|
| A baseline lock must be derivable from repository evidence and primary sources, not memory. | `grep -n "first_byte\|last_byte" src/core/simd.zig`; `grep -n "pcre2_match_8" src/core/pcre_regex.zig`; the survey citations. | Every Decision Record row cites a concrete file:line and every De-Prioritization row cites a primary source. | A decision record naming a gap without a file:line, or a de-prioritization without a citation, is malformed. |
| The 001-handoff is a hard constraint, not a preference. | Both chains touch `src/core/simd.zig` at different functions. | Record the exact functions each chain owns and the ordering that prevents conflict. | A downstream unit that edits a 001-owned function without checking 001's archive state is malformed. |

## Domain-Knowledge Research Check

| Knowledge Gap | Research / Probe To Run | Source Priority | Decision It Controls | Closure Evidence |
|---------------|--------------------------|-----------------|----------------------|------------------|
| Confirm StringZilla's anomaly locator is the production reference for 3-byte fingerprinting. | `engine --query "stringzilla sz_locate_needle_anomalies 3-byte fingerprint SIMD"`; local `.refs/stringzilla/include/stringzilla/find.h:280-330` read. | Primary: vendored StringZilla source. | Whether 002b ports the algorithm faithfully. | Quoted source comment reproduced in the Decision Record. |
| Confirm Demaine SODA 2000 is the adaptive-intersection primary source and the ~8:1 galloping threshold. | `engine --url https://erikdemaine.org/papers/SODA2000/`; `engine --query "TimSort galloping merge 7 threshold adaptive intersection"`. | Primary: Demaine paper + TimSort references. | Whether 002d's threshold is grounded. | Quoted bound + chosen threshold. |
| Confirm the PCRE2 JIT-bypass contract. | `engine --url https://github.com/PCRE2Project/pcre2/blob/master/src/pcre2_jit_match.c`; `engine --query "pcre2_jit_match_8 bypass sanity check semantics"`. | Primary: PCRE2 source + manpages. | Whether 002c can rely on identical ovector semantics. | Quoted header comment in the Decision Record. |
| Confirm Langdale's SMH post is the Shufti primary source. | `engine --url https://branchfree.org/2018/05/30/smh-the-swiss-army-chainsaw-of-shuffle-based-matching-sequences/`. | Primary: branchfree.org. | Whether 002e's mask-construction is faithful. | Quoted mask algorithm. |
| External gap already closed by local/research artifact because the parent RCH named the priority; this slice confirms accessibility. | — | — | — | — |

## Technical Execution Blueprint

| Area | Required Detail |
|------|-----------------|
| Repository anchors | `src/core/simd.zig:67-69` (the `first_byte`/`last_byte` splat sites), `src/core/simd.zig:84` (the AND-combine), `src/core/pcre_regex.zig:139, 165` (the two `pcre2_match_8` calls), `src/core/postings.zig:990-1008` (the two-pointer merge), `src/core/sz.zig:139` (`indexOfByteSet` FFI), `.refs/stringzilla/include/stringzilla/find.h:280-330` (anomaly locator), `.refs/pcre2/src/pcre2.h.in:783` (jit_match prototype), `.refs/pcre2/src/pcre2_jit_match.c:91` (implementation). |
| Existing-owner decision | No owner change. Contract lock only. |
| Domain owner / canonical standard | StringZilla, PCRE2, Demaine SODA 2000, Langdale SMH post. |
| Intended design | Four tables (Decision Record, De-Prioritization Record, Research Mandate Confirmation, 001-Handoff) populated in this file's body. |
| Integration path | Downstream units reference rows by ID in their Slice Research Directive and Original User Message Proof sections. |
| Failure modes to prevent | Vague de-prioritization; gap rows without file:line; missing 001-handoff. |
| Alternatives rejected | A separate `survey-findings.md` artifact — rejected because the parent is the ownership surface. |
| Proof hooks | `zig build test` baseline captured in evidence; grep output confirming the gap state. |

## Codebase Research And Execution Addendum

**Implementation map:** Run `grep -n "first_byte\|last_byte\|pcre2_match_8\|intersectFileIds" src/core/simd.zig src/core/pcre_regex.zig src/core/postings.zig` to confirm the gap sites. Run `ls .refs/stringzilla/include/stringzilla/find.h .refs/pcre2/src/pcre2_jit_match.c` to confirm the harvest sources exist.

**Existing-owner directive:** No owner modified. This slice extends the chain's contract surface only.

**Directive:** Populate the four tables verbatim from the parent's Domain Expertise Baseline, Gold-Standard Criteria, and Research Program. Cite file:line for every gap. Cite a primary source URL or quoted claim for every de-prioritization. Record the 001-handoff with the exact functions each chain owns.

**Gold-standard guardrail:** Do not convert this baseline into a free-form essay. The output is four structured tables plus the captured test baseline. Paragraphs are forbidden outside the template sections.

**Knowledge gathering route:** Local `grep`/`ls` first; then `engine --query`/`engine --url` via the Insect wrapper to confirm the four primary sources are reachable and say what the parent claims.

**Runtime visualization:** Not applicable — no runtime change.

**Proof expansion:** Run `zig build test` and capture the tail. No new tests; baseline-only exemption.

**Action-mode arbitration:** Execute now. Direct synchronous authoring.

## Embedded Framing

Lock the contract so each downstream slice is pulled toward its primary source rather than reinvention: every gap cites a file:line, every de-prioritization cites a survey primary source, and the 001-handoff prevents silent patch-surface collision.

## Slice Research Directive

| Research Topic | Why It Matters To This Slice | Insect Mode | Source Priority | Closure Evidence |
|----------------|------------------------------|-------------|-----------------|------------------|
| Confirm StringZilla anomaly locator. | Locks 002b's harvest source. | Local read + `engine --url` cross-reference. | `.refs/stringzilla/include/stringzilla/find.h:280-330` | Quoted comment in Decision Record G-1. |
| Confirm Demaine galloping bound. | Locks 002d's threshold rationale. | `engine --url https://erikdemaine.org/papers/SODA2000/`. | Demaine SODA 2000. | Quoted bound in Decision Record G-3. |
| Confirm PCRE2 JIT-bypass semantics. | Locks 002c's safety argument. | `engine --url https://github.com/PCRE2Project/pcre2/blob/master/src/pcre2_jit_match.c`. | PCRE2 source. | Quoted header in Decision Record G-2. |
| Confirm Langdale SMH Shufti reference. | Locks 002e's mask-construction. | `engine --url https://branchfree.org/2018/05/30/smh-...`. | branchfree.org. | Quoted algorithm in Decision Record G-4. |

## Original User Message Proof

| Source Anchor | Verbatim Original Snippet | Slice Proof Obligation | Evidence Capture |
|---------------|---------------------------|------------------------|------------------|
| U1 | "continue studying and researching the most complex genius formulas, methods, recipes, and code strategies for blazing fast search" | Freeze the survey's findings as binding scope. | Decision Record table. |
| U2 | "we shouldnt get biased and stuck on existing lanes, we should zoom out and find things not yet explored or attempted" | Lock the scope to currently-absent techniques; record dispositions for already-explored items. | De-Prioritization Record + the "already absorbed in 001" notes. |
| U3 | "please do" | The chain exists; this slice locks it. | This file's existence + the parent's approval. |
| U4 | "Default to copying or tightly adapting proven algorithms" (AGENTS.md) | Bind each unit to its vendored reference. | Research Mandate Confirmation table. |
| U5 | "`SZ_DYNAMIC_DISPATCH=0`. No runtime feature detection." (AGENTS.md) | Lock the compile-time-SIMD-only constraint. | Invariant I3 + 002f's audit hook. |
| U6 | (3-byte fingerprint) | Record the gap with file:line. | Decision Record G-1. |
| U7 | (PCRE2 JIT bypass) | Record the gap with file:line. | Decision Record G-2. |
| U8 | (Galloping intersection) | Record the gap with file:line. | Decision Record G-3. |
| U9 | (Shufti) | Record the gap with file:line. | Decision Record G-4. |

## Decision Record

| Gap ID | Survey Finding | File:Line Evidence (Current State) | Owning Slice | Closure Signal |
|--------|----------------|------------------------------------|--------------|----------------|
| G-1 | S4: 3-byte rarity-pivoted fingerprint (S4) | `src/core/simd.zig:67-69` (only `first_byte`/`last_byte` splats); `:84` (only `first_mask & last_mask`). StringZilla reference: `.refs/stringzilla/include/stringzilla/find.h:1064-1085` uses three positions via `sz_locate_needle_anomalies_`. | 002b | `grep -c "mid_byte\|offset_mid\|anomalies" src/core/simd.zig` ≥ 1; benchmark receipt. |
| G-2 | S5: `pcre2_jit_match_8` bypass (S5) | `src/core/pcre_regex.zig:139, 165` (`pcre2_match_8` calls). PCRE2 reference: `.refs/pcre2/src/pcre2.h.in:783` declares `pcre2_jit_match_8`; comment at `:170-174` says it "bypasses all sanity checks." | 002c | `grep -c "pcre2_jit_match_8" src/core/pcre_regex.zig` ≥ 1 AND `grep -c "pcre2_match_8" src/core/pcre_regex.zig` ≥ 1 (fallback retained); benchmark receipt. |
| G-3 | S2: Galloping intersection dispatch (S2) | `src/core/postings.zig:990-1008` (two-pointer merge, no size-ratio check). Demaine SODA 2000 is the adaptive bound; galloping wins at size ratio ~8:1. | 002d | `grep -c "gallop\|GALLOP" src/core/postings.zig` ≥ 1; existing merge preserved as fallback; ratio-stratified tests. |
| G-4 | S1: Shufti (2× PSHUFB) byte-class primitive (S1) | `src/core/simd.zig` has no Shufti-equivalent; byte-class queries route through FFI at `src/core/sz.zig:139`. Langdale SMH post + Vectorscan `nfa/shufti.*` are the reference. | 002e | `grep -c "shufti\|Shufti\|SHUFTI" src/core/simd.zig` ≥ 1; correctness tests across the byte alphabet; benchmark receipt. |

## De-Prioritization Record

Frontier-rejected items from the survey, inherited from 001a where overlapping. No slice in this chain may introduce them.

| DP ID | Rejected Item | Primary-Source Citation | Load-Bearing Claim | Bound Slice Effect |
|-------|---------------|-------------------------|--------------------|--------------------|
| DP-1 | Inner-loop `@prefetch` (Tier 2). | Algorithmica; Travis Downs "Speed Limits"; TU Dortmund 2024 prefetch survey. | HW prefetcher wins on sequential scan; explicit prefetch steals load ports. | No slice in this chain adds `@prefetch` to the scan loop. |
| DP-2 | CLMUL newline/structural detection (Tier 0). | Langdale & Lemire, "Parsing Gigabytes of JSON per Second", VLDB 2019 / arXiv:1902.08318. | CLMUL is for backslash-escape carry chains, not plain byte-class scanning. | 002e uses two-PSHUFB Shufti, NOT CLMUL. |
| DP-3 | SIMD Aho-Corasick (256-wide flattened). | Ourlis & Bellala SCPE 2019; BurntSushi/aho-corasick Teddy README. | Superseded by Teddy for literal search; cache-hungry on state explosion. | Not in this chain. (Fat Teddy is `001f`'s scope.) |
| DP-4 | io_uring / IOCP / VM ring (Tier 1). | TigerBeetle io/linux.zig; ripgrep mmap heuristic. | Out of scope for the per-byte / per-line optimization layer. | Not in this chain. |
| DP-5 | AVX-512 build target (Tier A2). | StringZilla headers; Lemire AVX-512 posts. | Real win, but separate chain (would touch build.zig and conflict with `001b`'s LTO work). | No slice in this chain adds `-mavx512*` flags. |
| DP-6 | Roaring bitmaps for posting lists (Tier A1). | Chambi/Lemire SPE 2016, arXiv:1402.6407. | Real win, but depends on galloping landing first (002d) and is large enough to deserve its own chain. | 002d only adds galloping; Roaring representation is deferred to a successor chain. |
| DP-7 | Bit-parallel Glushkov NFA (Tier A3). | Navarro-Raffinot 2002; Cantone-Faro-Giaquinta FUN 2010. | Real win, but ~2-3k LOC; separate chain. | Not in this chain. |
| DP-8 | Rose-lite multi-literal chaining (Tier A4). | Hyperscan NSDI 2019 §4. | Real win, but ~500 LOC; separate chain. | Not in this chain. |

## Research Mandate Confirmation

| Downstream Unit | Parent Anchor(s) | Slice Research Directive Obligation (locked) | Insect/Harvest Mode |
|-----------------|-------------------|----------------------------------------------|---------------------|
| 002b | U4, U6 | Harvest `.refs/stringzilla/include/stringzilla/find.h:280-330` (anomaly locator) + `:1064-1085` (haswell kernel) before designing. | Local read (primary) + `engine --url` cross-reference. |
| 002c | U4, U7 | Read `.refs/pcre2/src/pcre2.h.in:783` and `.refs/pcre2/src/pcre2_jit_match.c:91-200` before swapping call sites. | Local read (primary) + `engine --query` for return-code matrix. |
| 002d | U4, U8 | Cite Demaine SODA 2000 (already locked in DP-style above); confirm the ~8:1 threshold against TimSort's galloping implementation. | `engine --url https://erikdemaine.org/papers/SODA2000/`; `engine --query "TimSort galloping merge threshold"`. |
| 002e | U4, U5, U9 | Harvest Langdale SMH post + Vectorscan `nfa/shufti*` mask-construction; verify Zig `@Vector(32, u8)` lowers two PSHUFBs correctly. | `engine --url https://branchfree.org/2018/05/30/smh-...`; local `zig build -femit-asm` diff. |
| 002f | U1, U2, U3, U4, U5, U6, U7, U8, U9 | Audit that every row above has closure evidence in the corresponding archived unit. | Read-only review of `/todo/changelog/`. |

## 001-Handoff (Patch-Surface Coordination)

Chain `001-hot-path-perf` is concurrent (in `/todo/pending/`) and shares `src/core/simd.zig` and `src/core/search.zig` with this chain. To prevent silent patch-surface collision:

| File | 001 owns (function-level) | 002 owns (function-level) | Coordination rule |
|------|---------------------------|---------------------------|-------------------|
| `src/core/simd.zig` | `indexOfByte` (cold-path marking in 001d), no other changes in 001. | `indexOf` body (002b), new `shufti` namespace (002e). | 002b and 002e touch different functions than 001d. Execute 002b/002e only after checking 001d's archive state; if 001d is in-progress, wait. |
| `src/core/search.zig` | Multiple functions across 001c/001d/001e/001g. | None in this chain. | No conflict — 002 does not touch `search.zig`. |
| `src/core/literal_alternates.zig` | Fat Teddy in 001f. | None in this chain. | No conflict. |
| `src/core/postings.zig` | None in 001. | `intersectFileIds` in 002d. | No conflict. |
| `src/core/pcre_regex.zig` | None in 001. | `column`/`count` in 002c. | No conflict. |
| `build.zig` | LTO in 001b. | None in this chain (DP-5). | No conflict. |

If any 001 unit is in-progress on `simd.zig` when a 002 unit reaches pre-flight, the 002 unit MUST wait for 001's archive and re-read the file before executing.

## Pre-flight Checklist

- [ ] All `dependencies` archived. (None — first unit.)
- [ ] All `entry_state` claims verifiable.
- [ ] `source_message_*` populated.
- [ ] `conflict_surface` documents the 001 handoff.
- [ ] Rollback procedure populated (N/A — no artifact change).
- [ ] Idempotency: idempotent; direct re-execute.
- [ ] No other slice being advanced.
- [ ] Slice Research Directive declares bounded external research.

## Entry State

- Parent `/todo/pending/002-frontier-absorption.md` exists with `spec_status: approved`.
- The codebase matches the audited state: `simd.zig::indexOf` uses 2-byte fingerprint; `pcre_regex.zig` calls `pcre2_match_8`; `postings.zig::intersectFileIds` is a two-pointer merge; no Shufti in `simd.zig`.
- Chain `001-hot-path-perf` is concurrent in `/todo/pending/`.

## Patch Surface

**Modifies:** (none)
**Adds:** (none)
**Deletes:** (none)
**Must not touch:** All source, build, test files. Contract lock only.

## Detailed Requirements

- R1: Decision Record table contains exactly four rows (G-1 through G-4), each citing a concrete `file:line` from the current working tree.
- R2: De-Prioritization Record table contains at least eight rows (DP-1 through DP-8), each citing at least one primary source.
- R3: Research Mandate Confirmation table contains one row per downstream implementation unit (002b through 002e) plus the review unit (002f), each naming the parent anchor(s) and the harvest mode.
- R4: 001-Handoff table enumerates the function-level ownership of `simd.zig` and confirms no other file conflicts.
- R5: Run `zig build test` and capture the tail. The baseline must be green. This is the regression floor every later unit is measured against.
- R6: Run `ls .refs/stringzilla/include/stringzilla/find.h .refs/pcre2/src/pcre2_jit_match.c` and confirm both exist. If either is missing, halt and block — the harvest directive is unsatisfiable.

## Invariants This Unit Must Preserve

- I3: Compile-time SIMD only (no code change; just declaration).
- I6: `zig build test` green at baseline.
- I8: Evidence field carries the captured test result.

## Validation Plan

| Step | Command | Expected Exit Code | Expected Output Pattern | Idempotent |
|------|---------|-------------------|------------------------|-----------|
| 1 | `cd "E:/Workspaces/01_Projects/01_Github/ix-zig" && ls .refs/stringzilla/include/stringzilla/find.h .refs/pcre2/src/pcre2_jit_match.c` | `0` | both files listed | yes |
| 2 | `cd "E:/Workspaces/01_Projects/01_Github/ix-zig" && grep -c "pcre2_jit_match_8" src/core/pcre_regex.zig && grep -c "mid_byte\|offset_mid\|anomalies" src/core/simd.zig && grep -c "gallop" src/core/postings.zig && grep -c "shufti\|Shufti" src/core/simd.zig` | `0` | `0` for each (confirming the gaps) | yes |
| 3 | `cd "E:/Workspaces/01_Projects/01_Github/ix-zig" && zig build test 2>&1 \| tail -5` | `0` | test pass / 0 failed | yes |

**Evidence to capture:** Test tail, grep outputs confirming the gap state, ls output confirming harvest sources exist.

## Exit State (Handoff Contract)

- Decision Record (G-1..G-4), De-Prioritization Record (DP-1..DP-8), Research Mandate Confirmation, and 001-Handoff tables populated in this archived file.
- `zig build test` baseline green; tail captured in evidence.
- Harvest sources confirmed present.
- Gap state confirmed: zero hits for `pcre2_jit_match_8`/`mid_byte`/`gallop`/`shufti` in the target files.
- 002b inherits G-1; 002c inherits G-2; 002d inherits G-3; 002e inherits G-4; 002f inherits the mandate to audit every row.

## Rollback Procedure

1. No artifact change. If aborted, the file remains in `/todo/pending/` with `status: pending`. Re-execute from pre-flight.

## Next todo

`/todo/pending/002b-frontier-absorption.md`

## Completion

- [ ] Pre-flight passed.
- [ ] Implementation-unit test floor: baseline-only exemption (no artifact change; `zig build test` baseline captured).
- [ ] Tests prove capability through entrypoint. (N/A — baseline.)
- [ ] All validation commands executed. Exit codes match.
- [ ] Post-flight: Exit State claims verifiable.
- [ ] Evidence captured. PLACEHOLDER gone.
- [ ] Status set to `done`.
- [ ] `mv /todo/pending/002a-frontier-absorption.md /todo/changelog/002a-frontier-absorption.md` verified.
- [ ] Continue immediately to `next_todo`.
