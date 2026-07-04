---
id: 002b-frontier-absorption
parent: 002-frontier-absorption
type: execution-unit
protocol_version: "2.1"
category: feature
phase: b
status: pending
patch_scope: "Port StringZilla's rarity-pivoted 3-byte SIMD literal fingerprint into simd.zig::indexOf by harvesting sz_locate_needle_anomalies_ from .refs/stringzilla/include/stringzilla/find.h:280-330 and adding a third (mid) byte broadcast + AND-combine to the existing first+last fingerprint loop, with a scalar verify step that skips the three already-matched positions."
blast_radius: low
blast_radius_justification: "Single-function change to simd.zig::indexOf (the pure-Zig literal scan primitive). Failure propagation bounded to literal scan consumers (countLiteral via search.zig:5271 after 001e lands, and the existing in-file tests). The StringZilla FFI path (sz.indexOf) is untouched and remains the correctness reference."
idempotency_contract: idempotent
idempotency_notes: "Pure source edit. Re-executing produces the same state. Direct re-execute on partial failure."
acceptance: "simd.zig::indexOf computes three fingerprint positions via a ported anomaly locator, broadcasts three byte splats, AND-combines three masks, and verifies survivors skipping the three matched positions; existing indexOf tests pass unchanged; new tests cover collision-pivot inputs, mid-byte selection, and needle lengths 0/1/2/3/>8; benchmark receipt on a case-sensitive literal workload shows no regression."
exit_criterion: "`grep -c 'mid_byte\|offset_mid\|anomalies\|locateNeedleAnomalies' src/core/simd.zig` ≥ 1 AND `zig build test` exit 0 AND new fingerprint tests pass AND benchmark receipt captured."
validation: "cd \"E:/Workspaces/01_Projects/01_Github/ix-zig\" && zig build test 2>&1 | tail -5 && grep -n 'mid_byte\|offset_mid\|anomalies' src/core/simd.zig"
expected_exit_code: 0
expected_output_pattern: "(test|PASS|0 failed|.*passed)"
evidence: "PLACEHOLDER — replace with exact captured stdout at completion."
conflict_surface: "001d-hot-path-perf (shares src/core/simd.zig — 001d touches indexOfByte cold-marking, this slice touches indexOf body; coordinate per 002a handoff)"
invariants:
  - "I3: Compile-time SIMD only — the new fingerprint uses @Vector(32, u8) only."
  - "I6: Existing tests pass, including all current indexOf tests."
source_message_anchor: "U4, U6"
source_message_excerpt: "Default to copying or tightly adapting proven algorithms ... from the highest-quality reference repos; (survey Tier S4: 3-byte rarity-pivoted fingerprint, citing StringZilla find.h:293-322)"
source_message_proof_obligation: "Close Decision Record G-1 by porting StringZilla's sz_locate_needle_anomalies_ and the 3-byte AND-combine faithfully into simd.zig::indexOf, replacing the current 2-byte first+last fingerprint."
entry_state: "002a is archived. zig build test is green. simd.zig::indexOf (lines 63-109) uses only first_byte and last_byte splats AND-combined at line 84. The StringZilla reference at .refs/stringzilla/include/stringzilla/find.h:280-330 (anomaly locator) and :1064-1085 (haswell kernel) is present and unread by the IX implementation."
rollback_surface: "1. `git checkout src/core/simd.zig`. 2. `zig build test`."
dependencies: "002a-frontier-absorption"
next_todo: /todo/pending/002c-frontier-absorption.md
continuation: "On completion: record evidence, set status done, move to /todo/changelog/002b-frontier-absorption.md, continue immediately to /todo/pending/002c-frontier-absorption.md. Stay focused on this slice."
blocked_reason: ""
unblock_action: ""
resumption_point: ""
---
# 002b 3-Byte Rarity-Pivoted SIMD Literal Fingerprint

## Execute Now

Harvest `sz_locate_needle_anomalies_` from `.refs/stringzilla/include/stringzilla/find.h:280-330`, port it to Zig as a `locateNeedleAnomalies` helper, then extend `simd.zig::indexOf` to broadcast three needle positions (first/mid/last) and AND-combine three masks, with the verify step skipping the three matched positions.

## Slice Focus Rule

This unit owns the agent's attention until the 3-byte fingerprint is implemented, tested across needle lengths and collision cases, and the benchmark confirms no regression. The agent must not touch `sz.indexOf` (the FFI stays as-is), must not change `indexOfByte` (001d's territory), must not introduce runtime needle-position selection, and must not skip the rarity-pivot collision-avoidance pass — it is the whole point of the algorithm.

## Why This Execution Unit Exists

This slice is separate because the 3-byte fingerprint is a precise, self-contained algorithmic change to one function. Sequencing it first among the four absorptions builds evidence momentum with the lowest risk: the change is mechanical (port a documented algorithm), the fallback is trivial (`git checkout`), and the payoff compounds with every later chain (Fat Teddy's verify, Rose-lite dispatch, every literal scan). It must land before 002e (Shufti) because both touch `simd.zig` and ordered execution prevents patch-surface conflict.

## Better-Than-Before Delta

The pre-slice weakness is a 2-byte fingerprint that wastes SIMD lanes on repetitive needles: for a needle like `function`, first=`f` and last=`n` collide often in source code, so most 32-byte windows produce many false-positive verifications. The post-slice improvement is that the third (rarity-pivoted) byte multiplicatively cuts false positives (false-positive rate drops from `P(first)·P(last)` to `P(first)·P(mid)·P(last)`), the verify step skips three positions instead of two (slightly less memcmp work per survivor), and a regression test pins the anomaly-locator behavior so future refactors cannot silently regress to the 2-byte fingerprint.

## Slice Domain Standard

| Domain Standard | Local Evidence | Implementation Consequence | Anti-Assumption Guard |
|-----------------|----------------|----------------------------|-----------------------|
| The anomaly locator is the production reference for fingerprint-position selection; its collision-pivot logic is the algorithmic content. | `.refs/stringzilla/include/stringzilla/find.h:283-322` documents the rationale ("comparing against 'a' in every register is a waste") and the pivot algorithm. | Port `sz_locate_needle_anomalies_` faithfully, including the >8-byte UTF-8-prefix-aware extension at `find.h:314-322`. | Skipping the collision-pivot produces a "3-byte fingerprint" that's just first+mid+last without anomaly avoidance — not the real algorithm. |
| The fingerprint positions must be selected at parse time (or per-call), not per-iteration. | The current `indexOf` broadcasts `first_byte` and `last_byte` once outside the loop. | Compute `offset_first`, `offset_mid`, `offset_last` once before the SIMD loop. | Recomputing the anomaly positions inside the loop defeats the purpose. |

## Domain-Knowledge Research Check

| Knowledge Gap | Research / Probe To Run | Source Priority | Decision It Controls | Closure Evidence |
|---------------|--------------------------|-----------------|----------------------|------------------|
| Exact anomaly-locator algorithm including the >8-byte UTF-8 extension. | Local read `.refs/stringzilla/include/stringzilla/find.h:280-330`. | Primary: vendored StringZilla source. | The Zig port's faithfulness. | Quoted source comment reproduced in design notes; line-by-line mapping. |
| Does the rarity-pivot actually help on source-code needles (vs natural-language)? | `engine --query "stringzilla needle anomaly fingerprint source code repetitive benchmark"`; local benchmark. | Primary: StringZilla repo + local measurement. | Whether the change is worth the code churn. | Benchmark receipt on the case-sensitive literal workload. |
| Does Zig's `@Vector(32, u8)` AND-three-masks lower to three VPCMPEQB + two VPAND + VPMOVMSKB? | Local `zig build -femit-asm` diff. | Primary: local codegen. | Whether the compile-time SIMD invariant (I3) is preserved. | ASM excerpt. |

## Technical Execution Blueprint

| Area | Required Detail |
|------|-----------------|
| Repository anchors | `src/core/simd.zig:1-15` (header comment to update), `:63-109` (the `indexOf` body to extend), `:67-69` (the `first_byte`/`last_byte` splat sites), `:84` (the AND-combine), `:86-95` (the verify loop). `.refs/stringzilla/include/stringzilla/find.h:280-330` (anomaly locator), `:1064-1085` (haswell 3-byte kernel). |
| Existing-owner decision | Extend `simd.zig::indexOf`. No new module. Add a private `locateNeedleAnomalies` helper above `indexOf`. |
| Domain owner / canonical standard | StringZilla `sz_locate_needle_anomalies_` + the haswell 3-byte kernel. |
| Intended design | (1) Add `fn locateNeedleAnomalies(needle: []const u8) struct { first: usize, mid: usize, last: usize }` that ports the collision-pivot + UTF-8-aware extension. (2) In `indexOf`, after the `needle.len == 1` special case, compute the three positions. (3) Broadcast three splats: `n_first`, `n_mid`, `n_last`. (4) In the SIMD loop, load three chunks at offsets `pos_first`, `pos_mid`, `pos_last`; produce three masks; AND-combine all three. (5) Verify survivors with a memcmp that skips the three matched positions (or just memcmp the whole needle — the three positions are byte-equal by construction; skipping is a micro-optimization). (6) Preserve the existing scalar tail for the remaining <VEC_SIZE positions. |
| Integration path | `countLiteral` and `countWordBoundaryLiteralLines` (in `search.zig`) call `simd.indexOf` (post-001e); the in-file tests exercise `indexOf` directly. |
| Failure modes to prevent | (1) Skipping the collision-pivot (degenerate 3-byte). (2) Out-of-bounds when `needle.len < 3` (must fall back to existing first+last or single-byte path). (3) Recomputing positions inside the loop. (4) Violating the `needle.len > haystack.len` early return. |
| Alternatives rejected | A 4-byte fingerprint — diminishing returns; the fourth mask adds VPCMPEQB cost without proportional false-positive reduction. A frequency-ranked single-byte choice — would require a static frequency table (deferred to a separate chain, survey Tier A5). |
| Proof hooks | New tests: needle lengths 0/1/2/3/4/8/9/>8 (UTF-8 pivot boundary); collision cases (`aaa`, `aXaYa`); mid-byte at every position; the existing `indexOf` tests pass unchanged. Benchmark receipt on case-sensitive literal workload. ASM diff confirming three VPCMPEQB + VPAND. |

## Codebase Research And Execution Addendum

**Implementation map:** Read `src/core/simd.zig` in full (175 lines). Read `.refs/stringzilla/include/stringzilla/find.h:280-330` (anomaly locator) and `:1064-1085` (haswell kernel).

**Existing-owner directive:** `simd.zig::indexOf` owns this change. Add the helper above it.

**Directive:** Port the anomaly locator faithfully (including the >8-byte UTF-8-aware extension). Extend `indexOf` to three positions. Add tests. Run `zig build test`. Run the benchmark on case-sensitive literal.

**Gold-standard guardrail:** Do NOT skip the collision-pivot. Do NOT change `indexOfByte`. Do NOT add runtime dispatch. Do NOT touch `sz.indexOf`.

**Knowledge gathering route:** Local reads; `engine --query` only if the algorithm is unclear; local `zig build -femit-asm` to confirm codegen.

**Runtime visualization:** `indexOf(haystack, needle) ──locateNeedleAnomalies(needle)──► (first, mid, last) positions ──3× splat + 3× VPCMPEQB + 2× VPAND + VPMOVMSKB + TZCNT──► candidate offset ──memcmp verify──► hit`. Before: 2× VPCMPEQB + 1× VPAND.

**Proof expansion:** Tests must cover: needle length 0 (returns 0), 1 (delegates to `indexOfByte`), 2 (first==0, last==1, no mid), 3 (first/mid/last distinct), 4-8 (collision-pivot may or may not trigger), >8 (UTF-8-aware pivot engages). Collision inputs: `aaa` (all same), `aXaYa` (the StringZilla comment's example). Mid-byte correctness: construct needles where the mid byte uniquely identifies the position. Add a test that asserts the anomaly locator returns distinct positions when possible.

**Action-mode arbitration:** Execute now. Synchronous port + test + benchmark.

## Embedded Framing

Make the literal scan reject false candidates at one-third the current rate: port StringZilla's anomaly locator faithfully, broadcast three positions, AND-combine three masks, and let the rarity-pivot collision-avoidance do the work the algorithm is named for. A benchmark receipt on the case-sensitive workload proves the win; an ASM diff proves the SIMD lowering.

## Slice Research Directive

| Research Topic | Why It Matters To This Slice | Insect Mode | Source Priority | Closure Evidence |
|----------------|------------------------------|-------------|-----------------|------------------|
| Exact anomaly-locator algorithm + UTF-8 extension. | Controls faithfulness of the port. | Local read `.refs/stringzilla/include/stringzilla/find.h:280-330`. | Primary: vendored StringZilla. | Line-by-line mapping in design notes. |
| Source-code-repetitive-needle benchmark. | Confirms the win on IX's workload (AS1). | Local benchmark on case-sensitive literal workload. | Primary: local measurement. | Benchmark JSON in evidence. |
| `@Vector(32, u8)` AND-three-masks codegen. | Confirms I3 (compile-time SIMD) is preserved. | Local `zig build -femit-asm`. | Primary: local codegen. | ASM excerpt. |

## Original User Message Proof

| Source Anchor | Verbatim Original Snippet | Slice Proof Obligation | Evidence Capture |
|---------------|---------------------------|------------------------|------------------|
| U4 | "Default to copying or tightly adapting proven algorithms ... from the highest-quality reference repos" (AGENTS.md) | Harvest StringZilla's anomaly locator before designing. | Design notes mapping each element to `find.h:280-330`. |
| U6 | (survey Tier S4: 3-byte fingerprint) | Close gap G-1 by implementing the 3-byte rarity-pivoted fingerprint. | `grep` hits + benchmark receipt + tests. |

## Pre-flight Checklist

- [ ] All `dependencies` archived. (002a archived.)
- [ ] All `entry_state` claims verifiable.
- [ ] `source_message_*` populated.
- [ ] `conflict_surface` documents the 001d handoff.
- [ ] Rollback procedure populated.
- [ ] Idempotency: idempotent; direct re-execute.
- [ ] No other slice being advanced. Check 001d's archive state before executing on `simd.zig`.
- [ ] Slice Research Directive declares bounded research.

## Entry State

- 002a archived. `zig build test` green.
- `simd.zig::indexOf` uses 2-byte first+last fingerprint (lines 67-69 splat, line 84 AND).
- `.refs/stringzilla/include/stringzilla/find.h:280-330` and `:1064-1085` present.

## Patch Surface

**Modifies:**
- `src/core/simd.zig` — add `locateNeedleAnomalies` helper; extend `indexOf` to 3-byte fingerprint; update header comment; add tests.

**Adds:**
- (tests in-file)

**Deletes:**
- (none)

**Must not touch:**
- `src/core/simd.zig::indexOfByte` (001d's territory).
- `src/core/sz.zig` (the FFI path stays).
- `src/core/search.zig`, `src/core/literal_alternates.zig`, `build.zig`.

## Detailed Requirements

- R1: Read `.refs/stringzilla/include/stringzilla/find.h:280-330` and reproduce the anomaly-locator algorithm as `fn locateNeedleAnomalies(needle: []const u8) struct { first: usize, mid: usize, last: usize }`.
- R2: Include the collision-pivot pass: if first/mid/last collide and `needle.len > 3`, pivot mid rightward and last leftward until distinct (or the bounds are hit).
- R3: Include the >8-byte UTF-8-aware extension from `find.h:314-322`: prefer bytes whose value is ≤191 (avoids UTF-8 continuation-byte prefixes with low information content).
- R4: In `indexOf`, after the `needle.len == 1` delegation, compute the three positions once outside the loop. For `needle.len == 2`, fall back to the existing first+last path (no meaningful mid).
- R5: Broadcast three splats (`n_first`, `n_mid`, `n_last`). In the SIMD loop, load three chunks at the computed offsets, produce three masks, AND-combine.
- R6: Verify survivors with `std.mem.eql` over the interior (or the whole needle — micro-optimization deferred). Preserve the existing scalar tail.
- R7: Add tests: needle lengths 0/1/2/3/4/8/9/>8; collision cases (`aaa`, `aXaYa`); anomaly-locator distinctness assertion.
- R8: Run `zig build test`. Run benchmark on case-sensitive literal workload. Confirm no regression.
- R9: Apply I3 — `@Vector(32, u8)` only; confirm via `zig build -femit-asm` that the three-mask AND lowers to VPCMPEQB×3 + VPAND×2.

## Invariants This Unit Must Preserve

- I3: Compile-time SIMD only.
- I6: Existing tests pass.

## Validation Plan

| Step | Command | Expected Exit Code | Expected Output Pattern | Idempotent |
|------|---------|-------------------|------------------------|-----------|
| 1 | `cd "E:/Workspaces/01_Projects/01_Github/ix-zig" && grep -c "mid_byte\|offset_mid\|anomalies\|locateNeedleAnomalies" src/core/simd.zig` | `0` | ≥1 | yes |
| 2 | `cd "E:/Workspaces/01_Projects/01_Github/ix-zig" && zig build test 2>&1 \| tail -5` | `0` | test pass / 0 failed | yes |
| 3 | Benchmark on case-sensitive literal workload | `0` | scan_ms improved or within noise | no |

**Evidence to capture:** Grep, test tail, benchmark JSON, ASM excerpt.

## Exit State (Handoff Contract)

- `simd.zig::indexOf` uses a 3-byte rarity-pivoted fingerprint via a ported `locateNeedleAnomalies`.
- Existing `indexOf` tests pass unchanged.
- New tests cover needle lengths 0..>8 and collision cases.
- Benchmark receipt captured.
- 002c inherits: green baseline; literal scan now 3-byte; `pcre_regex.zig` unchanged (its scope).

## Rollback Procedure

1. `git checkout src/core/simd.zig`.
2. `zig build test`.

## Next todo

`/todo/pending/002c-frontier-absorption.md`

## Completion

- [ ] Pre-flight passed.
- [ ] Implementation-unit test floor: ≥30 tests OR focused-test exemption. (Amendment: this slice adds targeted fingerprint regression tests; record the focused-test exemption with rationale — the capability is "3-byte fingerprint correctness," proven by length-stratified + collision tests through the real `indexOf` entrypoint.)
- [ ] Tests prove capability through entrypoint.
- [ ] All validation commands executed. Exit codes match.
- [ ] Post-flight: Exit State claims verifiable.
- [ ] Evidence captured. PLACEHOLDER gone.
- [ ] Status set to `done`.
- [ ] `mv /todo/pending/002b-frontier-absorption.md /todo/changelog/002b-frontier-absorption.md` verified.
- [ ] Continue immediately to `next_todo`.
