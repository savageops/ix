---
id: 001b-hot-path-perf
parent: 001-hot-path-perf
type: execution-unit
protocol_version: "2.1"
category: feature
phase: b
status: pending
patch_scope: "Enable LTO across the Zig/C boundary in build.zig by setting want_lto on the executable and the C source steps that compile StringZilla and PCRE2, OR record a measurement-backed de-prioritization if LTO regresses link time, binary correctness, or measured scan throughput."
blast_radius: medium
blast_radius_justification: "Touches link behavior for the whole binary. Failure propagation path: a malformed LTO flag can produce a non-linking or non-running ix.exe, which the benchmark runner, test suite, and every downstream slice depend on. Contained because the change is confined to build.zig and is fully reverted by `git checkout build.zig`."
idempotency_contract: conditionally-idempotent
idempotency_notes: "Re-executing the build flag change is safe (build.zig is deterministic). The condition is: if a partial run left build.zig in a state with want_lto on one step but not others, revert via `git checkout build.zig` before re-executing to avoid an inconsistent LTO boundary (the non-LTO-static-lib trap)."
acceptance: "Either (a) `grep -n 'want_lto' build.zig` returns hits on the executable and the C source steps, `zig build test` exits 0, `zig build` produces a working ix.exe that passes the benchmark identity control vs the installed binary within noise thresholds, and a before/after benchmark receipt is captured; OR (b) a decision record in this unit's body documents the measured regression or correctness failure with the exact command and output that caused the de-prioritization, and the AGENTS.md Tier 3 LTO entry is reconciled."
exit_criterion: "Path (a): `grep -c 'want_lto' build.zig` ≥ 1 AND `zig build test` exit 0 AND captured benchmark JSON in evidence. Path (b): `grep -c 'want_lto' build.zig` may be 0 BUT the body contains a Decision Record with a captured failing command/output AND a written AGENTS.md reconciliation note."
validation: "cd \"E:/Workspaces/01_Projects/01_Github/ix-zig\" && zig build test 2>&1 | tail -5 && grep -n 'want_lto' build.zig"
expected_exit_code: 0
expected_output_pattern: "(test|PASS|0 failed|.*passed).*(want_lto|\\z)"
evidence: "PLACEHOLDER — replace with exact captured stdout at completion. Archival is gated on this field being populated."
conflict_surface: ""
invariants:
  - "I5: StringZilla symbol surface unchanged — ix_sz_find, ix_sz_find_byte, ix_sz_find_byteset, ix_sz_equal remain the C ABI. LTO must not rename or drop these symbols."
  - "I6: Existing tests pass — `zig build test` green."
  - "I7: Benchmark identity controls do not regress — repo binary vs installed binary within noise."
  - "I8: Evidence field carries a captured benchmark receipt or decision record."
source_message_anchor: "U4, U2, U3"
source_message_excerpt: "LTO across Zig/C boundary — want_lto = true on C source steps; studying the web, the refs the docs research; Make sure the todo slices each demand mandatory unavoidable computer science / algorithm / hardware / system / code WEB RESEARCH using insect skill"
source_message_proof_obligation: "Close the AGENTS.md Tier 3 LTO claim-vs-binary gap (parent Decision Record G-1). Either deliver LTO in the binary with a measured delta, or convert the claim into a measurement-backed reconciliation note. Either outcome must be falsifiable from the evidence field."
entry_state: "001a is archived in /todo/changelog/. The Decision Record G-1 row locks build.zig:58,72 as the gap site. `grep want_lto build.zig` returns 0. `zig build test` is green at baseline. `.refs/stringzilla/` and `.refs/pcre2/src/` compile under the current flags."
rollback_surface: "1. `git checkout build.zig` to revert any want_lto additions. 2. Re-run `zig build` to confirm the original binary is restored. 3. If the build cache is contaminated, remove `zig-cache/` and `zig-out/` and rebuild."
dependencies: "001a-hot-path-perf"
next_todo: /todo/pending/001c-hot-path-perf.md
continuation: "On completion: record evidence (replace PLACEHOLDER), set status done, move this file to /todo/changelog/001b-hot-path-perf.md, continue immediately to /todo/pending/001c-hot-path-perf.md. Stay fully focused on this slice until it resolves. Do not switch to any other slice."
blocked_reason: ""
unblock_action: ""
resumption_point: ""
---
# 001b LTO Across the Zig/C Boundary

## Execute Now

Set `want_lto = .full` (or the Zig 0.16.0+ equivalent confirmed via Slice Research Directive) on the `createIxModule` executable module and on the `addCSourceFile`/`addCSourceFiles` steps at `build.zig:58,72`, then measure scan throughput on the literal-alternates workload; if LTO regresses link time, correctness, or measured throughput, revert and record the decision.

## Slice Focus Rule

This unit owns the agent's attention until either LTO is delivered with a benchmark receipt or a measurement-backed de-prioritization is recorded. The agent must not skip ahead to 001c, must not bundle unrelated build-flag changes (e.g. optimization level, SIMD flags) into this slice, and must not enable LTO without measuring — faith-based LTO violates GS5.

## Why This Execution Unit Exists

This slice is separate from 001c–001g because its blast radius is the entire binary link, not a single hot-path file. A bad LTO flag breaks every downstream slice's baseline (`zig build test`, `zig build`, the benchmark). Isolating it means a revert is `git checkout build.zig`, not a multi-file unwind. It is sequenced first among implementation units because if LTO does inline StringZilla across the C ABI, it changes the picture for 001e (the `simd.indexOf`-vs-`sz.indexOf` routing decision may flip post-LTO).

## Better-Than-Before Delta

The pre-slice weakness is that AGENTS.md Tier 3 names LTO as a roadmap item already in force ("`want_lto = true` on C source steps") while `build.zig` silently does not deliver it — a contract-vs-binary drift. The post-slice improvement is that the drift is closed in one direction or the other: either LTO is in the binary and the claim is true, or the claim is reconciled with a measurement-backed note and the AGENTS.md entry no longer misrepresents the binary. Either outcome is reviewable from `grep want_lto build.zig` plus this unit's evidence.

## Slice Domain Standard

| Domain Standard | Local Evidence | Implementation Consequence | Anti-Assumption Guard |
|-----------------|----------------|----------------------------|-----------------------|
| LTO claims must be measurement-gated, not faith-based (parent GS5). | Frontier guidance (Algorithmica, Travis Downs) consistently reports ~1-3% deltas on already-SIMD-heavy code with non-trivial link-time cost. | The slice must capture before/after on the literal-alternates workload, not just assert "LTO is faster." | Enabling LTO with no benchmark receipt is malformed and fails GS5. |
| The non-LTO-static-lib trap: any TU not compiled with LTO becomes a hard LTO boundary (parent RCH-2). | PCRE2 has 27 TUs (`build.zig:72-110`); if even one is not LTO-compiled, cross-boundary calls into it cannot be inlined. | The slice must verify the LTO flag reaches both `addCSourceFile` (StringZilla, line 58) and `addCSourceFiles` (PCRE2, line 72). | Enabling LTO only on the StringZilla TU while leaving PCRE2 TUs non-LTO creates the exact trap. |

## Domain-Knowledge Research Check

| Knowledge Gap | Research / Probe To Run | Source Priority | Decision It Controls | Closure Evidence |
|---------------|--------------------------|-----------------|----------------------|------------------|
| Is `want_lto` still the correct Zig 0.16.0+ field name on `addCSourceFile`/`addCSourceFiles`/the executable, and is the value `.full` or a boolean? | `engine --query "zig 0.16 addCSourceFile want_lto field full boolean"`; `engine --url https://ziglang.org/learn/build-system/`; local `zig build --help`. | Primary: Zig build-system docs, Zig source. | Whether to write `want_lto: .full` or `want_lto: true` or use the module-level flag. | Quoted doc sentence + the exact field spelling used in the diff. |
| Does LTO across the StringZilla header-only boundary actually inline the hot `sz_find` compare loop, or does the C ABI defeat it? | `engine --query "stringzilla sz_find LTO inline zig c boundary benchmark"`; local `zig build -femit-asm` diff of the scan loop before/after. | Primary: StringZilla repo, Zig issues. | Whether LTO is worth the link-time cost at all (path a vs path b). | ASM diff showing the StringZilla compare inlined (or not) into the Zig scan loop. |
| Are there known PCRE2-or-sljit LTO pitfalls (sljit's JIT buffer, function pointers)? | `engine --query "pcre2 sljit LTO link-time optimization problem"`. | Primary: PCRE2 issue tracker, sljit source. | Whether PCRE2 TUs must be excluded from LTO (conditional-idempotency condition). | Quoted issue or source comment; the exact `want_lto` per-step configuration chosen. |
| External gap already closed by local/research artifact because parent RCH-2 named the priority sources; this slice confirms the load-bearing claim before committing. | — | — | — | — |

## Technical Execution Blueprint

| Area | Required Detail |
|------|-----------------|
| Repository anchors | `build.zig:45-66` (`createIxModule`, `root_module.addCSourceFile` for StringZilla), `build.zig:72-110` (`root_module.addCSourceFiles` for PCRE2), `build.zig:5-7` (`exe_module`, `optimize`). |
| Existing-owner decision | Extend `build.zig`. No new build script or wrapper. |
| Domain owner / canonical standard | Zig build-system `Compile` step semantics; LLVM LTO phase ordering. |
| Intended design | Add `want_lto: .full` (or confirmed spelling) to the `addCSourceFile` struct at line 58, to the `addCSourceFiles` struct at line 72, and to the executable created from `exe_module`. Confirm with `grep want_lto build.zig`. |
| Integration path | `zig build` re-links; `ix.exe` is the consumer; `benchmark-runner.mjs` is the measurement path. |
| Failure modes to prevent | (1) LTO on StringZilla but not PCRE2 (non-LTO-static-lib trap). (2) Link failure due to sljit JIT buffer handling. (3) Silent binary slowdown from LTO overhead exceeding inline win. (4) WASM target breakage (not in current targets but documented in r/Zig). |
| Alternatives rejected | Per-TU `want_lto` only on StringZilla — rejected because PCRE2's 27 TUs would form the trap. Module-level only — rejected if it does not propagate to C source steps. |
| Proof hooks | `grep -c want_lto build.zig` ≥ 1; `zig build test` exit 0; `zig build` produces `zig-out/bin/ix.exe`; benchmark before/after JSON in evidence. |

## Codebase Research And Execution Addendum

**Implementation map:** Before editing, read `build.zig:1-120` to see the exact struct literals at lines 58 and 72, the module/exe creation, and the optimize mode. Run `zig build --help | grep -i lto` to confirm the spelling.

**Existing-owner directive:** `build.zig` is the canonical build owner. Extend it; do not add a `build_lto.zig` or a wrapper script.

**Directive:** Add `want_lto` to the two C source steps and to the executable in `createIxModule`'s caller. Rebuild. Run `zig build test`. Run the benchmark runner against the installed binary and the freshly built binary. Capture all three outputs. If any fails, revert via `git checkout build.zig` and write the Decision Record.

**Gold-standard guardrail:** Do not enable LTO as a checkbox — the parent explicitly flags this as marginal (~1-3%) and the non-LTO-static-lib trap. A change with no benchmark receipt is malformed.

**Knowledge gathering route:** Local `zig build --help` + `build.zig` read first; then `engine --query` and `engine --url` via the Insect wrapper to confirm spelling, PCRE2/sljit pitfalls, and StringZilla inline behavior.

**Runtime visualization:** `build.zig:58 (StringZilla TU) ──LTO──► exe_module ──► ix.exe ──benchmark──► receipt`; `build.zig:72 (PCRE2 27 TUs) ──LTO──► same exe_module`. Both must carry the flag or the boundary traps.

**Proof expansion:** Beyond `zig build test`, run `tools/scripts/lib/benchmark-runner.mjs` (or the repo's `bench:once` package.json script) on the literal-alternates workload before and after. Capture both JSON outputs. Identity controls must be respected (paired same-binary runs).

**Action-mode arbitration:** Execute now. Synchronous build-and-measure. No deferral, delegation, or background work. The benchmark is the terminal proof; a successful `zig build` alone is not completion.

## Embedded Framing

Close the LTO contract with measurement discipline: either the binary carries `want_lto` and a receipt proves the win, or a captured failing output reconciles the AGENTS.md claim with the measured reality. Faith-based LTO violates the parent's GS5 and fails this slice.

## Slice Research Directive

| Research Topic | Why It Matters To This Slice | Insect Mode | Source Priority | Closure Evidence |
|----------------|------------------------------|-------------|-----------------|------------------|
| Zig 0.16.0+ `want_lto` spelling and propagation rules. | Controls whether to write `.full`, `true`, or use a module-level flag, and whether it reaches C source steps. | `engine --query "zig 0.16 addCSourceFile want_lto field full boolean propagation"`; `engine --url https://ziglang.org/learn/build-system/`. | Primary: Zig docs, Zig source. | Quoted doc + the exact field spelling used. |
| PCRE2 / sljit LTO pitfalls. | Controls whether PCRE2 TUs must be excluded (the conditional-idempotency condition). | `engine --query "pcre2 sljit LTO link-time optimization problem JIT buffer"`. | Primary: PCRE2 issues, sljit source. | Quoted issue/comment or "no pitfall found" with the search-result evidence. |
| StringZilla inline-across-ABI behavior under LTO. | Controls whether LTO is worth enabling at all (path a vs path b). | `engine --query "stringzilla sz_find AVX2 inline LTO zig c boundary"`; local `zig build -femit-asm` diff. | Primary: StringZilla repo; local ASM. | ASM excerpt or quoted source comment. |
| Benchmark receipt on the literal-alternates workload. | Closes GS5 — no perf claim without before/after. | Local `tools/scripts/lib/benchmark-runner.mjs` run (not Insect; this is a local measurement). | Primary: the repo's own benchmark harness. | Captured JSON before/after in evidence. |

## Original User Message Proof

| Source Anchor | Verbatim Original Snippet | Slice Proof Obligation | Evidence Capture |
|---------------|---------------------------|------------------------|------------------|
| U4 | "LTO across Zig/C boundary — `want_lto = true` on C source steps" (AGENTS.md Tier 3) | Close gap G-1: deliver LTO in the binary, or record a measurement-backed reconciliation. | `grep want_lto build.zig` hit count; benchmark JSON; or Decision Record with failing output. |
| U2 | "studying the web, the refs the docs research" | The Slice Research Directive above mines primary sources before the flag is flipped. | Quoted Zig docs / PCRE2 issues / StringZilla source in the Domain-Knowledge Research Check closure column. |
| U3 | "Make sure the todo slices each demand mandatory unavoidable computer science / algorithm / hardware / system / code WEB RESEARCH using insect skill" | The four research rows above are mandatory and each closes a decision. | Each row's Closure Evidence column populated before archival. |

## Pre-flight Checklist

- [ ] All `dependencies` are archived in `/todo/changelog/` with non-PLACEHOLDER evidence. (001a archived.)
- [ ] All `entry_state` claims are verifiable on the current filesystem. (001a's exit state; `grep want_lto build.zig` returns 0.)
- [ ] `source_message_anchor`, `source_message_excerpt`, and `source_message_proof_obligation` are populated and match the parent.
- [ ] `conflict_surface` is empty.
- [ ] Rollback procedure is populated for blast_radius medium. (`git checkout build.zig` + rebuild.)
- [ ] If re-executing after partial failure: idempotency_contract is conditionally-idempotent — verify build.zig is in a consistent state (all-or-nothing want_lto) before re-executing; revert if inconsistent.
- [ ] No other slice in this chain is being advanced, edited, or interpreted while this slice is unresolved.
- [ ] Slice Research Directive records the local research baseline and declares bounded external research with explicit Insect mode.

## Entry State

- 001a is archived. Decision Record G-1 names `build.zig:58,72` as the gap.
- `grep want_lto build.zig` returns 0.
- `zig build test` is green (001a baseline).
- `tools/scripts/lib/benchmark-runner.mjs` is runnable; the literal-alternates workload is configured at `benchmark-config.mjs:5`.

## Patch Surface

**Modifies:**
- `build.zig` — add `want_lto` to the StringZilla `addCSourceFile` (around line 58), to the PCRE2 `addCSourceFiles` (around line 72), and to the executable created from `exe_module`. Exact field spelling confirmed via Slice Research Directive.

**Adds:**
- (none)

**Deletes:**
- (none)

**Must not touch (out of scope for this unit):**
- `src/**` — no source changes; LTO is a build-flag change only.
- `tools/scripts/**` — benchmark harness is a consumer, not a modification target.
- Optimization level, SIMD flags, linker settings unrelated to LTO.

## Detailed Requirements

- R1: Read `build.zig:1-120` and run `zig build --help | grep -i lto` to confirm the `want_lto` field spelling in the installed Zig version. Do not guess the spelling.
- R2: Add `want_lto` to the StringZilla `addCSourceFile` step at `build.zig:58` with the confirmed value.
- R3: Add `want_lto` to the PCRE2 `addCSourceFiles` step at `build.zig:72` with the same value. This prevents the non-LTO-static-lib trap across PCRE2's 27 TUs.
- R4: Add `want_lto` to the executable created from `exe_module` so the LLVM link phase sees the whole-graph LTO.
- R5: Run `zig build test`. If it fails, revert (`git checkout build.zig`) and proceed to the Decision Record path (path b).
- R6: Run `zig build`. Confirm `zig-out/bin/ix.exe` (or equivalent) is produced. Record binary size before/after — LTO commonly shrinks the binary; a size increase is suspicious.
- R7: Run the benchmark on the literal-alternates workload before (baseline) and after (LTO) using `tools/scripts/lib/benchmark-runner.mjs` or `pnpm bench:once`. Respect identity controls (paired same-binary runs).
- R8: If the LTO binary regresses scan throughput beyond the noise thresholds defined in `benchmark-config.mjs`, revert and record the Decision Record.
- R9: If the sljit/PCRE2 search reveals a known LTO pitfall, exclude the affected TUs by setting `want_lto: false` (or `.none`) on the PCRE2 step only and document the per-step asymmetry in the body.
- R10: Apply GS5 — the evidence field must contain the benchmark JSON or the Decision Record's failing output. A `zig build test` pass alone is not completion.

## Invariants This Unit Must Preserve

- I5: StringZilla symbol surface unchanged. After LTO, confirm `nm zig-out/bin/ix.exe | grep ix_sz_find` returns the four symbols.
- I6: `zig build test` green.
- I7: Benchmark identity control — repo binary vs installed binary within noise.
- I8: Evidence field populated with benchmark receipt or Decision Record.

## Validation Plan

| Step | Command | Expected Exit Code | Expected Output Pattern | Idempotent |
|------|---------|-------------------|------------------------|-----------|
| 1 | `cd "E:/Workspaces/01_Projects/01_Github/ix-zig" && grep -n "want_lto" build.zig` | `0` | ≥1 hit (path a) OR 0 hits with body Decision Record (path b) | yes |
| 2 | `cd "E:/Workspaces/01_Projects/01_Github/ix-zig" && zig build test 2>&1 \| tail -5` | `0` | test pass / 0 failed | yes |
| 3 | `cd "E:/Workspaces/01_Projects/01_Github/ix-zig" && zig build 2>&1 \| tail -3` | `0` | successful link, no error | yes |
| 4 | `cd "E:/Workspaces/01_Projects/01_Github/ix-zig" && nm zig-out/bin/ix.exe 2>/dev/null \| grep -c "ix_sz_find"` | `0` | `4` (the four C ABI symbols survive LTO) | yes |
| 5 | Benchmark runner before/after on literal-alternates workload | `0` | JSON receipt with delta within noise OR regression captured for path b | no (paired measurement) |

**Evidence to capture:** Grep output (step 1), test tail (step 2), link output (step 3), nm count (step 4), and both benchmark JSONs (step 5). For path b, capture the failing command and output that triggered the Decision Record.

## Exit State (Handoff Contract)

- Either `build.zig` carries `want_lto` on the StringZilla step, PCRE2 step, and executable (path a), OR a Decision Record in this archived unit documents the measured regression with captured output (path b).
- `zig build test` is green.
- `ix_sz_find`, `ix_sz_find_byte`, `ix_sz_find_byteset`, `ix_sz_equal` symbols survive (I5).
- The benchmark receipt (or Decision Record failing output) is in the evidence field.
- 001c inherits: `zig build test` green baseline; build.zig state known (LTO on or off, documented); benchmark runner operational.

## Rollback Procedure

1. `git checkout build.zig` to revert all `want_lto` additions.
2. `rm -rf zig-cache/ zig-out/` to clear any contaminated build cache.
3. `zig build` to confirm the original binary is restored.
4. `zig build test` to confirm the test baseline is restored.
5. If rollback itself fails (e.g. build.zig was not the only file touched — it should be), halt and report; do not proceed to 001c.

## Next todo

`/todo/pending/001c-hot-path-perf.md`

## Completion

- [ ] Pre-flight passed.
- [ ] Implementation-unit test floor satisfied: 30 meaningful feature-value tests OR a written exemption. (This slice's exemption: build-flag change with no new runtime capability; the benchmark receipt IS the feature-value proof through the real operator entrypoint — the scan workload. If path b, the Decision Record is the proof.)
- [ ] Tests prove the externally valuable capability through its intended entrypoint (benchmark runner on the literal-alternates workload).
- [ ] All validation commands executed. Exit codes match. Output patterns matched.
- [ ] Post-flight: all Exit State claims verifiable.
- [ ] Evidence captured. PLACEHOLDER gone.
- [ ] Status set to `done`.
- [ ] `mv /todo/pending/001b-hot-path-perf.md /todo/changelog/001b-hot-path-perf.md` verified.
- [ ] Continue immediately to `next_todo`.
