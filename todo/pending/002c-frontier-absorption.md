---
id: 002c-frontier-absorption
parent: 002-frontier-absorption
type: execution-unit
protocol_version: "2.1"
category: feature
phase: c
status: pending
patch_scope: "Switch src/core/pcre_regex.zig::column and ::count to call pcre2_jit_match_8 (the JIT-bypass entry declared at .refs/pcre2/src/pcre2.h.in:783) instead of pcre2_match_8, retaining pcre2_match_8 as the fallback for patterns where JIT is unsupported (PCRE2_ERROR_JIT_BADOPTION) or where the JIT stack limit is exceeded."
blast_radius: medium
blast_radius_justification: "Touches the regex verifier used by every regex_full strategy query. Failure propagation: a regression changes match results for any regex query that PCRE2 handles. Contained because the change is confined to pcre_regex.zig; the calling convention (line, pattern, case_insensitive) → (?usize | error.CompileFailed) is unchanged, and the fallback preserves current behavior on JIT-unsupported patterns."
idempotency_contract: conditionally-idempotent
idempotency_notes: "The change is reproducible. The condition: if a partial run leaves the file with pcre2_jit_match_8 wired into column but not count (or vice versa), revert via `git checkout src/core/pcre_regex.zig` before re-executing to avoid inconsistent dispatch."
acceptance: "pcre_regex.zig::column and ::count both call pcre2_jit_match_8 as the primary path; both fall back to pcre2_match_8 on PCRE2_ERROR_JIT_BADOPTION (or any negative return indicating JIT unavailability); the existing test corpus passes; new tests exercise the fallback path; a benchmark receipt on a regex-heavy workload shows no regression."
exit_criterion: "`grep -c 'pcre2_jit_match_8' src/core/pcre_regex.zig` ≥ 1 AND `grep -c 'pcre2_match_8' src/core/pcre_regex.zig` ≥ 1 (fallback retained) AND `zig build test` exit 0 AND benchmark receipt captured."
validation: "cd \"E:/Workspaces/01_Projects/01_Github/ix-zig\" && zig build test 2>&1 | tail -5 && grep -n 'pcre2_jit_match_8\\|pcre2_match_8' src/core/pcre_regex.zig"
expected_exit_code: 0
expected_output_pattern: "(test|PASS|0 failed|.*passed)"
evidence: "PLACEHOLDER — replace with exact captured stdout at completion."
conflict_surface: ""
invariants:
  - "I6: Existing tests pass, including every regex test in the corpus."
  - "I7: Benchmark identity controls do not regress on regex queries."
source_message_anchor: "U4, U7"
source_message_excerpt: "Default to copying or tightly adapting proven algorithms; (survey Tier S5: pcre2_jit_match_8 bypass, citing PCRE2 pcre2.h.in:783, pcre2_jit_match.c:91)"
source_message_proof_obligation: "Close Decision Record G-2 by routing the regex verifier through pcre2_jit_match_8 with a documented fallback to pcre2_match_8 for JIT-unsupported patterns."
entry_state: "002b is archived. zig build test is green. pcre_regex.zig::column (line 139) and ::count (line 165) both call pcre2_match_8. The PCRE2 declarations at .refs/pcre2/src/pcre2.h.in:783 and the implementation at pcre2_jit_match.c:91-200 are present."
rollback_surface: "1. `git checkout src/core/pcre_regex.zig`. 2. `zig build test`."
dependencies: "002b-frontier-absorption"
next_todo: /todo/pending/002d-frontier-absorption.md
continuation: "On completion: record evidence, set status done, move to /todo/changelog/002c-frontier-absorption.md, continue immediately to /todo/pending/002d-frontier-absorption.md. Stay focused on this slice."
blocked_reason: ""
unblock_action: ""
resumption_point: ""
---
# 002c PCRE2 JIT-Bypass (`pcre2_jit_match_8`)

## Execute Now

Add an `extern fn pcre2_jit_match_8` declaration matching the signature at `.refs/pcre2/src/pcre2.h.in:783-784`, then route `pcre_regex.zig::column` and `::count` through it as the primary path, falling back to `pcre2_match_8` when the JIT-bypass returns `PCRE2_ERROR_JIT_BADOPTION` or any other JIT-unavailability indicator.

## Slice Focus Rule

This unit owns the agent's attention until both call sites are wired, the fallback is exercised by tests, and the benchmark confirms no regression. The agent must not remove the `pcre2_match_8` declaration (the fallback is mandatory), must not change the public `column`/`count` signatures, must not touch the compile/cache path (`ensureCompiled` is unchanged), and must not introduce a match context or JIT stack in this slice (deferred to a future hardening chain — survey item B4).

## Why This Execution Unit Exists

This slice is separate because the JIT-bypass change has medium blast radius (every `regex_full` query) and a documented failure mode (`PCRE2_ERROR_JIT_BADOPTION`). Isolating it means the fallback path is tested in isolation, and a regression is `git checkout src/core/pcre_regex.zig`. It is sequenced after 002b so that the chain accumulates evidence on lower-risk slices first; it is sequenced before 002d/002e because those touch different files entirely.

## Better-Than-Before Delta

The pre-slice weakness is that IX pays PCRE2's per-line sanity-check overhead (UTF validity re-check, callout machinery, recursion-limit re-check) on every line of every regex query, even though IX has already JIT-compiled the pattern and trusts the subject bytes. The post-slice improvement is that the JIT path is entered directly, the per-line overhead is gone, and a documented fallback preserves current behavior exactly for JIT-unsupported patterns. The change is also self-documenting: the code now expresses "we trust the JIT" rather than "we re-validate every line."

## Slice Domain Standard

| Domain Standard | Local Evidence | Implementation Consequence | Anti-Assumption Guard |
|-----------------|----------------|----------------------------|-----------------------|
| `pcre2_jit_match_8` is documented to "bypass all sanity checks" — it is not a synonym for `pcre2_match_8`. | `.refs/pcre2/src/pcre2.h.in:170-174` (comment), `:783-784` (prototype), `pcre2_jit_match.c:91-200` (jumps straight into JIT code). | Use it as the primary path; fall back to `pcre2_match_8` on `PCRE2_ERROR_JIT_BADOPTION` (the documented return for JIT-unsupported patterns at `pcre2_jit_match.c:104, 127`). | Treating `pcre2_jit_match_8` as identical to `pcre2_match_8` and dropping the fallback is malformed. |
| The ovector semantics are identical between the two entries. | Both write to the match_data's ovector; `pcre2_get_ovector_pointer_8` reads it the same way. | The existing ovector-reading code at `pcre_regex.zig:151-152, 178-183` is unchanged. | Re-reading the ovector differently would be a silent semantic drift. |

## Domain-Knowledge Research Check

| Knowledge Gap | Research / Probe To Run | Source Priority | Decision It Controls | Closure Evidence |
|---------------|--------------------------|-----------------|----------------------|------------------|
| Exact `pcre2_jit_match_8` signature and return codes. | Local read `.refs/pcre2/src/pcre2.h.in:783-784` and `pcre2_jit_match.c:91-130`; `engine --query "pcre2_jit_match_8 signature return codes PCRE2_ERROR_JIT_BADOPOINT PCRE2_ERROR_JIT_STACKLIMIT"`. | Primary: vendored PCRE2 source + manpages. | The exact extern declaration and the fallback condition. | Quoted prototype + return-code matrix in design notes. |
| Are there PCRE2 patterns where the JIT-bypass produces different match results from the interpreter? | `engine --query "pcre2_jit_match vs pcre2_match result differences semantics"`. | Primary: PCRE2 manpages + issue tracker. | Whether the fallback needs to be semantic (different result) or just availability-based. | Documented finding (expected: no semantic difference; bypass only skips pre-checks). |
| Does the JIT-bypass need a JIT stack (the `pcre2_jit_stack_assign` API)? | `engine --query "pcre2_jit_match default jit stack need explicit assign"`. | Primary: PCRE2 manpages. | Whether this slice must also wire up a JIT stack (survey B4) or can defer. | Documented decision (expected: defer; default stack works for IX's pattern shapes). |

## Technical Execution Blueprint

| Area | Required Detail |
|------|-----------------|
| Repository anchors | `src/core/pcre_regex.zig:32-40` (the existing `pcre2_match_8` extern declaration — model the new one on it), `:139` (the column call site), `:165` (the count call site), `:151-152, 178-183` (ovector reading — unchanged). `.refs/pcre2/src/pcre2.h.in:783-784` (prototype), `.refs/pcre2/src/pcre2_jit_match.c:91-130` (return codes). |
| Existing-owner decision | Extend `pcre_regex.zig`. No new module. |
| Domain owner / canonical standard | PCRE2 ABI. |
| Intended design | (1) Add `extern fn pcre2_jit_match_8(code, subject, length, startoffset, options, match_data, match_context) c_int` matching `pcre2.h.in:783`. (2) In `column`, replace the `pcre2_match_8` call with `pcre2_jit_match_8`; on return `< 0` AND `!= PCRE2_ERROR_JIT_BADOPTION` (and not `PCRE2_ERROR_NOMATCH`), treat as no-match as today; on `PCRE2_ERROR_JIT_BADOPTION`, retry with `pcre2_match_8`. (3) Same for `count`. (4) Define a `PCRE2_ERROR_JIT_BADOPTION` constant matching PCRE2's `pcre2.h.in` value. (5) Document why the fallback exists. |
| Integration path | `expr.zig`'s `regex_full` strategy and every `pcre_regex.column`/`count` caller is the consumer. The signature is unchanged. |
| Failure modes to prevent | (1) Dropping the fallback (silently breaks JIT-unsupported patterns). (2) Mis-handling `PCRE2_ERROR_NOMATCH` (rc < 0 includes this; must still mean "no match," not "fall back"). (3) Reading the ovector differently. (4) Forgetting that the JIT-bypass can also return `PCRE2_ERROR_JIT_STACKLIMIT` (deep patterns) — handle by falling back, not erroring. |
| Alternatives rejected | Wiring a custom JIT stack now (deferred to B4 — orthogonal hardening). Using `pcre2_jit_match_8` without fallback — rejected; the JIT may legitimately not support some pattern shapes. |
| Proof hooks | New tests: a regex that PCRE2 JIT supports (assert `pcre2_jit_match_8` path); a synthetic test for the fallback (mock or construct a JIT-unsupported pattern, e.g. certain lookbehinds on older PCRE2 builds); existing regex tests pass unchanged. Benchmark receipt on a regex-heavy workload. |

## Codebase Research And Execution Addendum

**Implementation map:** Read `src/core/pcre_regex.zig` in full (188 lines). Read `.refs/pcre2/src/pcre2.h.in:165-180, 500-510, 783-792` (the JIT-bypass prototype, the JIT-stack API, the sanity-check comment). Read `.refs/pcre2/src/pcre2_jit_match.c:91-130` (return codes).

**Existing-owner directive:** `pcre_regex.zig` is the canonical owner. Extend it in place.

**Directive:** Add the `pcre2_jit_match_8` extern. Route both call sites through it with a `PCRE2_ERROR_JIT_BADOPTION`/`PCRE2_ERROR_JIT_STACKLIMIT` fallback to `pcre2_match_8`. Add tests. Run `zig build test`. Run a benchmark on a regex-heavy workload.

**Gold-standard guardrail:** Do NOT remove `pcre2_match_8`. Do NOT change the public signatures. Do NOT wire a JIT stack in this slice. Do NOT change the ovector reading.

**Knowledge gathering route:** Local reads; `engine --query` for return-code semantics and JIT-stack necessity.

**Runtime visualization:** `column(line, pattern) ──ensureCompiled──► cached code ──pcre2_jit_match_8──► rc ──if rc == JIT_BADOPTION or JIT_STACKLIMIT──► pcre2_match_8 fallback ──► ovector read (unchanged)`.

**Proof expansion:** Tests: a normal regex (positive match, no-match, case-insensitive); a regex that exercises count's loop (multiple matches); a fallback test that synthesizes `PCRE2_ERROR_JIT_BADOPTION` (may require a pattern known to defeat JIT, or a unit-test seam that mocks the return). The fallback test is the proof hook that catches a "dropped fallback" regression.

**Action-mode arbitration:** Execute now. Synchronous add-extern + rewire + test + benchmark.

## Embedded Framing

Make the regex verifier trust the JIT it already compiled: route through `pcre2_jit_match_8` to skip the per-line sanity checks, keep `pcre2_match_8` as the documented fallback for JIT-unsupported patterns, and prove the path with a benchmark receipt and a fallback regression test.

## Slice Research Directive

| Research Topic | Why It Matters To This Slice | Insect Mode | Source Priority | Closure Evidence |
|----------------|------------------------------|-------------|-----------------|------------------|
| `pcre2_jit_match_8` signature, return codes, and bypass semantics. | Controls the extern declaration and the fallback condition. | Local read `.refs/pcre2/src/pcre2.h.in:783` + `.refs/pcre2/src/pcre2_jit_match.c:91`; `engine --query "pcre2_jit_match_8 return codes JIT_BADOPTION JIT_STACKLIMIT"`. | Primary: vendored PCRE2. | Quoted prototype + return-code matrix. |
| Whether the bypass needs a JIT stack. | Controls whether this slice must also wire B4 (deferred). | `engine --query "pcre2_jit_match default jit stack explicit assign necessity"`. | Primary: PCRE2 manpages. | Documented decision (expected: defer). |
| Whether the bypass can produce different match results. | Controls whether the fallback is semantic or availability-only. | `engine --query "pcre2_jit_match vs pcre2_match result differences semantics edge cases"`. | Primary: PCRE2 manpages/issues. | Documented finding. |

## Original User Message Proof

| Source Anchor | Verbatim Original Snippet | Slice Proof Obligation | Evidence Capture |
|---------------|---------------------------|------------------------|------------------|
| U4 | "Default to copying or tightly adapting proven algorithms" (AGENTS.md) | Harvest PCRE2's documented JIT-bypass API before swapping. | Quoted header comment in design notes. |
| U7 | (survey Tier S5: JIT bypass) | Close gap G-2 by switching to `pcre2_jit_match_8` with fallback. | `grep` hits + benchmark receipt + fallback test. |

## Pre-flight Checklist

- [ ] All `dependencies` archived. (002b archived.)
- [ ] All `entry_state` claims verifiable.
- [ ] `source_message_*` populated.
- [ ] `conflict_surface` empty.
- [ ] Rollback procedure populated.
- [ ] Idempotency: conditionally-idempotent — verify both call sites are wired consistently before re-executing.
- [ ] No other slice being advanced.
- [ ] Slice Research Directive declares bounded research.

## Entry State

- 002b archived. `zig build test` green.
- `pcre_regex.zig::column` (line 139) and `::count` (line 165) call `pcre2_match_8`.
- `.refs/pcre2/src/pcre2.h.in:783` and `pcre2_jit_match.c:91` present.

## Patch Surface

**Modifies:**
- `src/core/pcre_regex.zig` — add `pcre2_jit_match_8` extern; add `PCRE2_ERROR_JIT_BADOPTION` / `PCRE2_ERROR_JIT_STACKLIMIT` constants; rewire `column` and `::count` with fallback; add tests.

**Adds:** (tests in-file)
**Deletes:** (none — `pcre2_match_8` declaration retained)
**Must not touch:** `src/core/search.zig`, `src/core/expr.zig`, `src/core/regex.zig` (the non-PCRE fallback), `build.zig`.

## Detailed Requirements

- R1: Read `.refs/pcre2/src/pcre2.h.in:165-180, 783-784` and `.refs/pcre2/src/pcre2_jit_match.c:91-130`. Record the exact signature and return-code semantics in design notes.
- R2: Add `extern fn pcre2_jit_match_8` to `pcre_regex.zig` with the same signature as `pcre2_match_8`.
- R3: Add constants `PCRE2_ERROR_JIT_BADOPT` and `PCRE2_ERROR_JIT_STACKLIMIT` matching PCRE2's `pcre2.h.in` values (look up the exact integer values).
- R4: In `column`, call `pcre2_jit_match_8` first. If rc is `PCRE2_ERROR_JIT_BADOPT` or `PCRE2_ERROR_JIT_STACKLIMIT`, retry with `pcre2_match_8`. If rc is `PCRE2_ERROR_NOMATCH` (or any other negative), treat as no-match as today.
- R5: Same rewire in `count`'s loop. The fallback must preserve the existing offset-advance semantics.
- R6: Add tests: positive match, no-match, case-insensitive, multiple-match count, and a fallback test (either a known JIT-unsupported pattern or a unit-test seam that returns `PCRE2_ERROR_JIT_BADOPT`).
- R7: Run `zig build test`. Run benchmark on a regex-heavy workload (e.g. a `re:` query against the corpus). Confirm no regression.
- R8: Apply GS3 — extend `pcre_regex.zig` in place; no new module.

## Invariants This Unit Must Preserve

- I6: Existing tests pass, including every regex test.
- I7: Benchmark identity control — no regex regression.

## Validation Plan

| Step | Command | Expected Exit Code | Expected Output Pattern | Idempotent |
|------|---------|-------------------|------------------------|-----------|
| 1 | `cd "E:/Workspaces/01_Projects/01_Github/ix-zig" && grep -c "pcre2_jit_match_8" src/core/pcre_regex.zig && grep -c "pcre2_match_8" src/core/pcre_regex.zig` | `0` | both ≥1 | yes |
| 2 | `cd "E:/Workspaces/01_Projects/01_Github/ix-zig" && zig build test 2>&1 \| tail -5` | `0` | test pass / 0 failed | yes |
| 3 | Benchmark on regex-heavy workload | `0` | scan_ms improved or within noise | no |

**Evidence to capture:** Greps, test tail, benchmark JSON, return-code matrix.

## Exit State (Handoff Contract)

- `pcre_regex.zig::column` and `::count` route through `pcre2_jit_match_8` with a `pcre2_match_8` fallback.
- Existing regex tests pass unchanged.
- New tests cover the fallback path.
- Benchmark receipt captured.
- 002d inherits: green baseline; regex verifier now uses JIT bypass; `postings.zig` unchanged (its scope).

## Rollback Procedure

1. `git checkout src/core/pcre_regex.zig`.
2. `zig build test`.

## Next todo

`/todo/pending/002d-frontier-absorption.md`

## Completion

- [ ] Pre-flight passed.
- [ ] Implementation-unit test floor: focused-test exemption recorded (capability = "JIT-bypass with documented fallback"; fallback test + behavior tests prove it through the real `column`/`count` entrypoint).
- [ ] Tests prove capability through entrypoint.
- [ ] All validation commands executed. Exit codes match.
- [ ] Post-flight: Exit State claims verifiable.
- [ ] Evidence captured. PLACEHOLDER gone.
- [ ] Status set to `done`.
- [ ] `mv /todo/pending/002c-frontier-absorption.md /todo/changelog/002c-frontier-absorption.md` verified.
- [ ] Continue immediately to `next_todo`.
