---
id: 001f-hot-path-perf
parent: 001-hot-path-perf
type: execution-unit
protocol_version: "2.1"
category: feature
phase: f
status: pending
patch_scope: "Implement a Fat Teddy multi-literal matcher in src/core/literal_alternates.zig that raises the branch ceiling above the current TEDDY_MAX_BRANCHES = 8 by harvesting the 16-bucket nibble-shuffle design from .refs/aho-corasick/src/packed/teddy/ and .refs/teddy-jneem/, integrating it into the existing Counter/TeddyPlan/nextTeddyCandidate dispatch with a Slim-vs-Fat selection at plan-build time, and adding ≥30 feature-value tests covering the 9-16 branch territory, prefix collisions, casefold haystacks, fingerprint offsets, and adversarial bucket saturation."
blast_radius: medium
blast_radius_justification: "Touches the literal-alternates match path used by the benchmark workload (benchmark-config.mjs:5) and by every regex_literal_alternates strategy classification. Failure propagation: a regression in the matcher changes match counts for any case-insensitive alternates query. Contained because the change is confined to literal_alternates.zig and its tests; the scan loop's calling convention is unchanged."
idempotency_contract: conditionally-idempotent
idempotency_notes: "The implementation is reproducible. The condition: if a partial run leaves literal_alternates.zig in a state where Slim and Fat dispatch are both half-wired (e.g. teddyPlanWithOffset returns a Fat plan but nextTeddyCandidate still assumes Slim), revert via `git checkout src/core/literal_alternates.zig` before re-executing to avoid a broken dispatch."
acceptance: "The Fat Teddy kernel handles 9-16 literal branches without falling back to scalar countMatchesScalar or PCRE2; Slim Teddy remains the path for ≤8 branches; the existing 8-branch tests pass unchanged; ≥30 new feature-value tests cover the 9-16 branch territory and pass; the benchmark on the literal-alternates workload (re:(?i)(ERR_SYS|PME_TURN_OFF|LINK_REQ_RST|CFG_BME_EVT) plus new ≥9-branch fixtures) shows no regression and a measurable improvement on the new territory."
exit_criterion: "`grep -n 'TEDDY_MAX_BRANCHES\|fat_teddy\|FatTeddy\|TEDDY_FAT' src/core/literal_alternates.zig` shows the new constants/dispatch; `zig build test` exit 0 with ≥30 new tests passing; benchmark receipt on literal-alternates workload captured."
validation: "cd \"E:/Workspaces/01_Projects/01_Github/ix-zig\" && zig build test 2>&1 | tail -10 && grep -n 'fat\\|Fat\\|TEDDY_FAT\\|TEDDY_MAX_BRANCHES' src/core/literal_alternates.zig | head"
expected_exit_code: 0
expected_output_pattern: "(test|PASS|0 failed|.*passed).*(\\n.*(Fat|fat|TEDDY)){0,}"
evidence: "PLACEHOLDER — replace with exact captured stdout at completion."
conflict_surface: ""
invariants:
  - "I3: Compile-time SIMD selection only. Fat Teddy must use @Vector only — no runtime CPU dispatch, no cpuid."
  - "I4: Strategy classification before I/O. The Slim-vs-Fat selection happens at teddyPlanWithOffset (parse time), not in the scan loop."
  - "I6: Existing tests pass, including all existing Teddy fixtures."
source_message_anchor: "U7, U8, U2, U3"
source_message_excerpt: "Aho-Corasick automaton for literal alternates — single-pass instead of N independent scans; Default to copying or tightly adapting proven algorithms ... from the highest-quality reference repos; studying the web, the refs the docs research; Make sure the todo slices each demand mandatory unavoidable computer science / algorithm / hardware / system / code WEB RESEARCH using insect skill"
source_message_proof_obligation: "Close parent Decision Records G-4 and G-5. G-4: the AGENTS.md Tier 0 'Aho-Corasick for literal alternates' claim is delivered as Fat Teddy (the frontier-corrected production equivalent per DP-3). G-5: the implementation is harvested from .refs/aho-corasick/src/packed/teddy/, not reinvented."
entry_state: "001e is archived. zig build test is green. literal_alternates.zig:7 reads TEDDY_MAX_BRANCHES = 8; teddyPlanWithOffset at :267 returns null for >8 branches; nextTeddyCandidateInternal at :522 uses @Vector(32,u8) with 3-byte fingerprints against 8 buckets. .refs/aho-corasick/src/packed/teddy/ and .refs/teddy-jneem/ are present (confirmed in 001a). countLiteralAlternatesCasefoldedHaystack exists for the whole-buffer casefold path."
rollback_surface: "1. `git checkout src/core/literal_alternates.zig`. 2. `zig build test` to confirm baseline. 3. If the dispatch is half-wired (conditionally-idempotent failure), the checkout in step 1 is mandatory before re-executing."
dependencies: "001e-hot-path-perf"
next_todo: /todo/pending/001g-hot-path-perf.md
continuation: "On completion: record evidence, set status done, move to /todo/changelog/001f-hot-path-perf.md, continue immediately to /todo/pending/001g-hot-path-perf.md. Stay focused on this slice."
blocked_reason: ""
unblock_action: ""
resumption_point: ""
---
# 001f Fat Teddy: 16-Bucket Nibble-Shuffle Multi-Literal Matcher

## Execute Now

Harvest the Fat Teddy design from `.refs/aho-corasick/src/packed/teddy/README.md`, `.refs/aho-corasick/src/packed/vector.rs`, and `.refs/teddy-jneem/`, then implement a 16-bucket nibble-shuffle Fat Teddy in `src/core/literal_alternates.zig` that handles 9-16 branches and integrates into the existing `Counter`/`TeddyPlan`/`nextTeddyCandidate` dispatch with a Slim-vs-Fat selection at `teddyPlanWithOffset`.

## Slice Focus Rule

This unit owns the agent's attention until Fat Teddy handles 9-16 branches, ≥30 new tests pass, the existing 8-branch tests pass unchanged, and the benchmark shows improvement on the new territory without regressing the old. The agent must not touch the scan loop in `search.zig` (Fat Teddy plugs into the existing `Counter.countMatches` interface), must not introduce runtime CPU dispatch, must not invent a non-Teddy algorithm (DP-3 forbids SIMD-AC), and must not skip the `.refs/` harvest — reinvention violates U8 and the parent's Frontier Research And Source Reuse directive.

## Why This Execution Unit Exists

This slice is the algorithmic centerpiece of the chain. The current Slim Teddy caps at 8 branches (`TEDDY_MAX_BRANCHES = 8`) and bails to scalar `countMatchesScalar` or PCRE2 above that. The benchmark workload at `benchmark-config.mjs:5` uses 4 branches, but real-world literal-alternates queries frequently exceed 8 (the existing tooling layer's `teddy-kernel-decision.mjs:1221-1255` has pre-written an acceptance contract for a `packed_nibble_shuffle_teddy_kernel` that does not exist). The reference implementation is already vendored at `.refs/aho-corasick/src/packed/teddy/` (BurntSushi's production-grade Rust) and `.refs/teddy-jneem/` (standalone port). The frontier research (parent RCH-1, DP-3) confirms Fat Teddy — not SIMD-AC — is the correct mechanism for literal alternates. This slice is sequenced after 001e so Fat Teddy's verification step can rely on `simd.indexOf` being the canonical in-loop literal primitive.

## Better-Than-Before Delta

The pre-slice weakness is a branch-count cliff: queries with >8 alternates silently fall off the SIMD path onto scalar or PCRE2, and the vendored Fat Teddy reference sits unread. The post-slice improvement is a smooth Slim→Fat selection at plan-build time that extends the SIMD path to 16 branches, the vendored reference is consumed (not decorative), and the tooling layer's pre-written acceptance contract for a `packed_nibble_shuffle_teddy_kernel` is satisfied by real code rather than gate-keeping an absence. The Slim path is unchanged for ≤8 branches (no regression surface).

## Slice Domain Standard

| Domain Standard | Local Evidence | Implementation Consequence | Anti-Assumption Guard |
|-----------------|----------------|----------------------------|-----------------------|
| Fat Teddy uses 16 buckets with 16-byte AVX2 reads split into two 128-bit halves; nibble-shuffle (PSHUFB/TBL) produces per-bucket 8-bit masks from two 4-bit lookups; masks are AND-combined and TZCNT-extracted; candidates are then verified against real branches. | `.refs/aho-corasick/src/packed/teddy/README.md` (Slim vs Fat spec); `.refs/aho-corasick/src/packed/vector.rs` (Fat vector impl). | Implement the 16-bucket nibble-shuffle faithfully; do not invent a third variant. | A "fat teddy" that merely doubles Slim's branch count without the nibble-shuffle is not Fat Teddy — it's a misleading rename. |
| The Slim-vs-Fat selection is a plan-build-time decision (AGENTS.md invariant 6: classify before I/O). | Current `teddyPlanWithOffset` at `literal_alternates.zig:267` runs at parse time. | Add a Fat branch to `teddyPlanWithOffset` (or a sibling `teddyFatPlanWithOffset`) that returns a Fat plan for 9-16 branches. | A runtime Slim-vs-Fat branch inside `nextTeddyCandidate` violates I4. |
| Teddy degrades when patterns cluster in few buckets (hash collisions → verification dominates). | Faro & Kulekci cited in the aho-corasick README; parent AS2. | Add adversarial bucket-saturation tests. Document the degradation in a comment. | Shipping Fat Teddy without a bucket-saturation test hides the known weakness. |

## Domain-Knowledge Research Check

| Knowledge Gap | Research / Probe To Run | Source Priority | Decision It Controls | Closure Evidence |
|---------------|--------------------------|-----------------|----------------------|------------------|
| Exact Fat Teddy bucket-assignment hash and nibble-shuffle mask construction. | Read `.refs/aho-corasick/src/packed/teddy/README.md` and `.refs/aho-corasick/src/packed/vector.rs` locally; `engine --url https://github.com/BurntSushi/aho-corasick/blob/master/src/packed/teddy/README.md` for cross-reference. | Primary: vendored BurntSushi source. | The exact Zig port — bucket hash, mask layout, AND-combine order, TZCNT extraction. | Markdown extraction of the README + vector.rs excerpts in design notes; written element-by-element mapping to the Zig port. |
| How does the reference handle Slim-vs-Fat selection, and at what branch count? | `.refs/aho-corasick/src/packed/teddy/README.md` (selection rules); `.refs/teddy-jneem/` (standalone port's main.rs). | Primary: vendored source. | Whether IX should select Fat at 9+ branches, 17+ branches, or based on a denser heuristic. | Quoted selection rule + the chosen threshold with rationale. |
| What is the verification step after candidate extraction, and how does it avoid redundant work? | `.refs/aho-corasick/src/packed/teddy.rs` (verify routine); `.refs/teddy-jneem/`. | Primary: vendored source. | How the Zig port verifies candidates against real branches (likely reuse of existing `firstMatchingBranchLenInternal`). | Quoted verify routine + the Zig adapter. |
| How does case-insensitive Fat Teddy interact with the existing `haystack_casefolded` flag (working-tree addition)? | Local read of the working-tree `countMatchesCasefoldedHaystack` and `nextTeddyCandidateInternal`'s `haystack_casefolded` parameter. | Primary: local source. | Whether Fat Teddy must propagate the same flag. | Confirmed propagation in the diff. |
| External gap already closed by local/research artifact because the reference is vendored; this slice's research is primarily a `.refs/` harvest plus a cross-reference URL. | — | — | — | — |

## Technical Execution Blueprint

| Area | Required Detail |
|------|-----------------|
| Repository anchors | `src/core/literal_alternates.zig:6-10` (MAX_BRANCHES=32, TEDDY_MAX_BRANCHES=8, FINGERPRINT_BYTES=3, BUCKETS=8), `:132-249` (LiteralAlternates struct, branchMaskForByte, firstMatchingBranchLenInternal), `:251-303` (TeddyPlan, teddyPlanWithOffset), `:485-565` (countTeddyPrefix3, nextTeddyCandidateInternal, the @Vector(32,u8) load + 3-byte fingerprint AND-combine + @ctz), `:567-573` (asciiLowerVec32), `:44-90` (Counter struct, short_line_teddy_plan), `:415-446` (PCRE2 fallback — must remain as the >16 or non-Teddy-eligible path). Also the working-tree `countMatchesCasefoldedHaystack` and `haystack_casefolded` plumbing. |
| Existing-owner decision | Extend `literal_alternates.zig`. Do NOT create `teddy_fat.zig` or a new dispatcher module. |
| Domain owner / canonical standard | BurntSushi/aho-corasick Slim/Fat Teddy (vendored); Faro & Kulekci SIMD-packed-AC lineage. |
| Intended design | (1) Add `TEDDY_FAT_BUCKETS = 16` and raise the branch ceiling to 16 (keep MAX_BRANCHES=32 for the scalar fallback). (2) Add a `TeddyFatPlan` (or extend `TeddyPlan` with a fat flag + 16 bucket_masks) holding the 16 per-bucket masks and per-branch fingerprints. (3) Add `teddyFatPlanWithOffset` (or a Fat branch in `teddyPlanWithOffset`) that returns a Fat plan for 9-16 eligible branches, null otherwise. (4) Add `nextFatTeddyCandidateInternal` that loads 16 bytes, splits into two 128-bit halves, builds per-half 4-bit nibble masks via `@shuffle`/PSHUFB equivalent, AND-combines into 8-bit masks, ORs the two halves, and `@ctz`-extracts candidates. (5) Add `countFatTeddyPrefix3Internal` mirroring `countTeddyPrefix3Internal`'s verify loop. (6) Wire `Counter.countMatches` to prefer Fat when the Fat plan is non-null. (7) Propagate `haystack_casefolded` through the Fat path. (8) Keep the PCRE2 fallback for >16 branches or non-eligible patterns. |
| Integration path | `Counter.countMatches` → `Counter.countMatchesInternal` → Fat or Slim branch → `nextFatTeddyCandidateInternal`/`nextTeddyCandidateInternal` → `firstMatchingBranchLenInternal` (existing verify). The scan loop in `search.zig` calls `countLiteralAlternates`/`countLiteralAlternatesCasefoldedHaystack` unchanged. |
| Failure modes to prevent | (1) Misreading the Fat nibble-shuffle and producing a "fat teddy" that is just doubled Slim (not the real algorithm). (2) Selecting Fat at the wrong branch threshold and regressing Slim territory. (3) Breaking the `haystack_casefolded` propagation so case-insensitive >8-branch queries miscount. (4) Introducing runtime dispatch (I3 violation). (5) Bucket-saturation silent degradation. |
| Alternatives rejected | SIMD-AC (DP-3 forbids it). A single parameterized Teddy that morphs between Slim and Fat — rejected for readability (AGENTS.md: "hot path should be readable as a flat sequence"). Two separate functions (Slim and Fat) with plan-build-time selection is the cleaner split. |
| Proof hooks | ≥30 new tests (see Validation Plan); benchmark on the 4-branch workload (no Slim regression) plus new 12-branch and 16-branch fixtures (Fat territory improvement); `grep` for the new constants/dispatch. |

## Codebase Research And Execution Addendum

**Implementation map:** Before editing, read `src/core/literal_alternates.zig` in full (777 lines), `.refs/aho-corasick/src/packed/teddy/README.md`, `.refs/aho-corasick/src/packed/vector.rs` (Fat Teddy vector impl), `.refs/aho-corasick/src/packed/teddy.rs` (build + verify), and `.refs/teddy-jneem/` (standalone port). Read the working-tree `haystack_casefolded` additions to understand the casefold-buffer contract Fat Teddy must honor.

**Existing-owner directive:** `literal_alternates.zig` is the canonical owner. Extend it. The existing `nextTeddyCandidateInternal` and `firstMatchingBranchLenInternal` are reused; Fat Teddy adds a sibling candidate-finder and reuses the verify.

**Directive:** Implement the 16-bucket Fat Teddy faithfully to the BurntSushi reference. Select Fat for 9-16 eligible branches at `teddyPlanWithOffset`. Propagate `haystack_casefolded`. Keep PCRE2 fallback for >16 or non-eligible. Add ≥30 tests. Run `zig build test`. Run the benchmark on three workloads (4-branch Slim regression, 12-branch Fat, 16-branch Fat).

**Gold-standard guardrail:** Do NOT rename Slim's constants to claim "fat." Do NOT introduce runtime dispatch. Do NOT skip the `.refs/` harvest. Do NOT break `haystack_casefolded` propagation. Do NOT regress the existing 8-branch tests.

**Knowledge gathering route:** `.refs/` local harvest first (primary); `engine --url` cross-reference second; local `zig build -femit-asm` to confirm the Fat path emits the expected AVX2 shuffle/AND/TZCNT.

**Runtime visualization:** `Counter.countMatches ──plan-build-time──► (Fat for 9-16 / Slim for ≤8) ──scan loop──► nextFatTeddyCandidateInternal ──16-byte load + 2×128-bit split + nibble-shuffle masks + AND-combine + OR + @ctz──► candidate offset ──firstMatchingBranchLenInternal (existing verify)──► count`. Fat plan selection happens once at parse time (I4); the per-line loop is branch-free on Slim-vs-Fat because the plan is baked into the `Counter`.

**Proof expansion:** Tests must cover: 9, 10, 12, 16 branches (Fat territory happy path); 2, 4, 8 branches (Slim regression — must pass unchanged); single-branch fallthrough; prefix-collision inputs (where two branches share a 3-byte fingerprint); case-insensitive with `haystack_casefolded=true` and `=false`; fingerprint-offset 0 and nonzero (the existing `IX_TEDDY_FINGERPRINT_OFFSET` env); adversarial bucket-saturation (many branches hashing to one bucket — document the degradation); branch at line start, mid-line, end-of-line; empty line; line shorter than fingerprint bytes; non-ASCII bytes in branches (should route to scalar). Add a benchmark fixture with 12 and 16 branches and capture the receipt.

**Action-mode arbitration:** Execute now. Synchronous harvest-then-implement-then-test-then-benchmark. No deferral. The benchmark is terminal proof.

## Embedded Framing

Deliver the production-grade Fat Teddy the vendored reference already specifies: harvest the design from `.refs/aho-corasick/`, implement the 16-bucket nibble-shuffle faithfully, select Slim-vs-Fat at plan-build time so the per-line loop stays branch-free on the choice, propagate the casefold-buffer contract, and prove the >8-branch territory with a benchmark receipt. The existing Slim tests are the regression floor; the new ≥30 tests are the capability proof.

## Slice Research Directive

| Research Topic | Why It Matters To This Slice | Insect Mode | Source Priority | Closure Evidence |
|----------------|------------------------------|-------------|-----------------|------------------|
| Fat Teddy bucket-assignment hash, nibble-shuffle mask construction, AND-combine, TZCNT extraction. | This IS the algorithm — without it the implementation is a renamed Slim. | Local `.refs/aho-corasick/src/packed/teddy/README.md` + `vector.rs` read; `engine --url https://github.com/BurntSushi/aho-corasick/blob/master/src/packed/teddy/README.md` cross-reference. | Primary: vendored BurntSushi source. | Markdown excerpts + element-by-element mapping to the Zig port in design notes. |
| Slim-vs-Fat selection threshold and rules in the reference. | Controls whether IX selects Fat at 9+ branches and what makes a pattern "Fat-eligible." | `.refs/aho-corasick/src/packed/teddy/README.md` (selection rules); `.refs/teddy-jneem/`. | Primary: vendored source. | Quoted rule + chosen threshold. |
| Verify routine after candidate extraction. | Controls whether the Zig port can reuse `firstMatchingBranchLenInternal` or needs a Fat-specific verify. | `.refs/aho-corasick/src/packed/teddy.rs`; `.refs/teddy-jneem/`. | Primary: vendored source. | Quoted routine + adapter decision. |
| Bucket-saturation degradation characteristics. | Informs the adversarial test inputs and the documented degradation comment. | `engine --query "aho-corasick teddy bucket saturation hash collision performance degradation"`; Faro & Kulekci paper cited in the README. | Primary: paper, BurntSushi README. | Quoted claim + adversarial test fixture. |

## Original User Message Proof

| Source Anchor | Verbatim Original Snippet | Slice Proof Obligation | Evidence Capture |
|---------------|---------------------------|------------------------|------------------|
| U7 | "Aho-Corasick automaton for literal alternates — single-pass instead of N independent scans" (AGENTS.md Tier 0) | Close gap G-4 by delivering Fat Teddy (frontier-corrected equivalent per DP-3). | `grep` for new constants; ≥30 new tests; benchmark receipt on 12/16-branch fixtures. |
| U8 | "Default to copying or tightly adapting proven algorithms ... from the highest-quality reference repos" (AGENTS.md) | Close gap G-5 by harvesting `.refs/aho-corasick/src/packed/teddy/`. | Design notes mapping each Fat Teddy element to the vendored source. |
| U2 | "studying the web, the refs the docs research" | The Slice Research Directive's four rows are mandatory harvests before editing. | Each row's Closure Evidence populated. |
| U3 | "Make sure the todo slices each demand mandatory unavoidable computer science / algorithm / hardware / system / code WEB RESEARCH using insect skill" | The Fat Teddy design is not derivable from generic knowledge; the harvest is unavoidable. | `.refs/` harvest notes + `engine --url` cross-reference in research closure. |

## Pre-flight Checklist

- [ ] All `dependencies` archived with non-PLACEHOLDER evidence. (001e archived.)
- [ ] All `entry_state` claims verifiable.
- [ ] `source_message_*` populated.
- [ ] `conflict_surface` empty.
- [ ] Rollback procedure populated (medium blast).
- [ ] Idempotency: conditionally-idempotent — verify `literal_alternates.zig` Slim/Fat dispatch is not half-wired before re-executing; revert if unsure.
- [ ] No other slice being advanced.
- [ ] Slice Research Directive declares bounded external research with explicit harvest mode.

## Entry State

- 001e archived. `zig build test` green.
- `literal_alternates.zig:7` reads `TEDDY_MAX_BRANCHES = 8`; `teddyPlanWithOffset` at `:267` returns null for >8 branches.
- `.refs/aho-corasick/src/packed/teddy/` and `.refs/teddy-jneem/` present (001a confirmed).
- The working-tree `countMatchesCasefoldedHaystack` / `haystack_casefolded` plumbing exists.

## Patch Surface

**Modifies:**
- `src/core/literal_alternates.zig` — add Fat Teddy constants, plan struct, plan-builder, candidate-finder, count routine, and `Counter` dispatch wiring. Propagate `haystack_casefolded`. Add ≥30 tests.

**Adds:**
- (Tests live in the same file per existing convention — no new test file.)

**Deletes:**
- (none — Slim Teddy is preserved.)

**Must not touch:**
- `src/core/search.zig` scan loop (Fat Teddy plugs into `Counter.countMatches`).
- `src/core/simd.zig`, `src/core/sz.zig`, `src/sz_shim.c`.
- The PCRE2 fallback for >16 branches or non-eligible patterns (must remain).

## Detailed Requirements

- R1: Harvest the Fat Teddy design from `.refs/aho-corasick/src/packed/teddy/README.md` and `.refs/aho-corasick/src/packed/vector.rs` before editing. Record the element-by-element mapping in design notes (in this unit's evidence or a committed `.docs/research/` note).
- R2: Add `TEDDY_FAT_BUCKETS = 16` and a `TEDDY_FAT_MAX_BRANCHES` constant (16, or the value the reference supports on AVX2).
- R3: Extend `TeddyPlan` with a Fat variant (or add a `TeddyFatPlan` sibling). Carry 16 per-bucket masks and per-branch fingerprints.
- R4: Add a Fat branch to `teddyPlanWithOffset` (or `teddyFatPlanWithOffset`) that returns a Fat plan for 9-16 eligible branches. Selection happens at plan-build time (I4).
- R5: Implement `nextFatTeddyCandidateInternal` faithfully to the reference: 16-byte load, two 128-bit halves, 4-bit nibble-shuffle masks via the Zig `@shuffle`/vector-byte-shuffle equivalent of PSHUFB, AND-combine into 8-bit masks, OR the halves, `@ctz`-extract. Use `@Vector` only (I3).
- R6: Implement `countFatTeddyPrefix3Internal` mirroring `countTeddyPrefix3Internal`'s verify loop, reusing `firstMatchingBranchLenInternal`.
- R7: Wire `Counter.countMatchesInternal` to prefer Fat when the Fat plan is non-null, else Slim, else scalar. Keep the existing PCRE2 fallback path for >16 or non-eligible.
- R8: Propagate the `haystack_casefolded` flag through the Fat path so case-insensitive >8-branch queries on a pre-casefolded buffer skip the per-position `asciiLowerVec32`.
- R9: Add ≥30 feature-value tests (see Proof expansion). The tests must prove the capability through the real `Counter.countMatches`/`countLiteralAlternates` entrypoint.
- R10: Run `zig build test`. All existing Teddy tests must pass unchanged. All new tests must pass.
- R11: Run the benchmark on (a) the 4-branch literal-alternates workload (Slim regression check), (b) a new 12-branch fixture, (c) a new 16-branch fixture. Capture all three receipts. The 4-branch must not regress; the 12/16-branch must show the Fat path engaged (no scalar/PCRE2 fallback in the telemetry).
- R12: Apply GS1 (prefer the vendored reference) and DP-3 (Fat Teddy, not SIMD-AC). Apply GS4 (no new module — extend `literal_alternates.zig`).

## Invariants This Unit Must Preserve

- I3: Compile-time SIMD selection only (`@Vector`, no runtime dispatch).
- I4: Slim-vs-Fat selection at plan-build time, not in the per-line loop.
- I6: All existing Teddy tests pass unchanged.

## Validation Plan

| Step | Command | Expected Exit Code | Expected Output Pattern | Idempotent |
|------|---------|-------------------|------------------------|-----------|
| 1 | `cd "E:/Workspaces/01_Projects/01_Github/ix-zig" && grep -n 'TEDDY_FAT\|FatTeddy\|fat_teddy\|TEDDY_MAX_BRANCHES' src/core/literal_alternates.zig \| head` | `0` | new Fat constants/dispatch present; `TEDDY_MAX_BRANCHES` may be reinterpreted | yes |
| 2 | `cd "E:/Workspaces/01_Projects/01_Github/ix-zig" && zig build test 2>&1 \| tail -10` | `0` | test pass / 0 failed, with ≥30 new Teddy tests in the pass list | yes |
| 3 | `cd "E:/Workspaces/01_Projects/01_Github/ix-zig" && zig build test 2>&1 \| grep -ci 'fat.*teddy\|teddy.*fat\|alternates.*branch'` | `0` | ≥30 (the new test names appear) | yes |
| 4 | Benchmark runner on 4-branch (Slim), 12-branch (Fat), 16-branch (Fat) workloads | `0` | Slim no regression; Fat shows no scalar/PCRE2 fallback; receipt captured | no |

**Evidence to capture:** Grep output, test tail with the new test names, all three benchmark JSONs, and the design-notes mapping each Fat Teddy element to the vendored source.

## Exit State (Handoff Contract)

- `literal_alternates.zig` contains a 16-bucket Fat Teddy that handles 9-16 branches.
- Slim Teddy remains for ≤8 branches; existing Slim tests pass unchanged.
- ≥30 new Fat Teddy tests pass.
- `haystack_casefolded` propagated through the Fat path.
- PCRE2 fallback preserved for >16 branches.
- Three benchmark receipts captured (4-branch, 12-branch, 16-branch).
- 001g inherits: green baseline; the literal-alternates matcher now handles >8 branches; the scan loop's structural-anchor scalar tail at `search.zig:3556,3562-3566` is still unmodified (its scope).

## Rollback Procedure

1. `git checkout src/core/literal_alternates.zig` (reverts the Fat additions; Slim Teddy restored).
2. `zig build test` to confirm the Slim-only baseline is restored.
3. If the dispatch was left half-wired (Fat plan returned but candidate-finder missing), the checkout in step 1 is mandatory before re-executing — do not attempt to patch forward.
4. If new tests were added in a separate file (they should not be — convention is in-file), `git checkout` that file too.

## Next todo

`/todo/pending/001g-hot-path-perf.md`

## Completion

- [ ] Pre-flight passed.
- [ ] Implementation-unit test floor: ≥30 meaningful feature-value tests added, proving the Fat Teddy capability through the real `Counter.countMatches`/`countLiteralAlternates` entrypoint (no exemption invoked).
- [ ] Tests prove the externally valuable capability through its intended entrypoint.
- [ ] All validation commands executed. Exit codes match.
- [ ] Post-flight: Exit State claims verifiable.
- [ ] Evidence captured (incl. design notes mapping to `.refs/`). PLACEHOLDER gone.
- [ ] Status set to `done`.
- [ ] `mv /todo/pending/001f-hot-path-perf.md /todo/changelog/001f-hot-path-perf.md` verified.
- [ ] Continue immediately to `next_todo`.
