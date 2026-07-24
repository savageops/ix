---
id: 159c-performance-frontier-five-area-map
parent: 159-performance-frontier-five-area-map
type: execution-unit
protocol_version: "3.0"
category: documentation
phase: c
status: pending
patch_scope: "Map `.gitignore`/`.ignore`/`.agignore` and default discovery semantics across cold serial, cold parallel, hidden/unrestricted, and warm-frontier paths without rewriting the existing parser."
blast_radius: low
blast_radius_justification: "This unit records a parity plan only; it does not alter discovery, ignore rules, or warm state."
idempotency_contract: idempotent
idempotency_notes: "The mapping is deterministic and has no runtime side effects."
acceptance: "The record distinguishes existing parser capability from discovery wiring, default build-output policy, explicit overrides, external ignore files, and warm-frontier freshness/ignore parity, with adversarial fixtures and fail-closed outcomes named."
exit_criterion: "A later implementation unit can prove or repair discovery parity by changing only the existing `admission.zig`/`search.zig` owners and their tests."
validation: "git diff --check"
expected_exit_code: 0
expected_output_pattern: ""
evidence: "PLACEHOLDER — replace with exact captured stdout at completion."
conflict_surface: "155-discovery-traversal-attribution; 153-search-frontier-zoom-out"
invariants:
  - "I1: Admission and discovery are fail-closed; no false negatives or accidental inclusion claims."
  - "I2: Match, route, file-count, byte, and output parity remain the promotion floor."
  - "I4: One canonical owner exists for discovery policy and warm candidate universe."
  - "I5: Unsupported freshness or ignore behavior falls back explicitly."
source_message_anchor: "U4, U7"
source_message_excerpt: >-
  "3. 🟡 .gitignore support (2-10x on real projects)";
  "be very careful that we don't create false negatives"
source_message_proof_obligation: "Map the already-present ignore parser and prove the exact missing parity boundary instead of building a duplicate or broad exclusion that drops valid files."
entry_state: "159b is archived with admission versus directory-admission semantics separated and the false-negative proof floor recorded."
rollback_surface: "Delete only this planning unit; do not modify `admission.zig`, `search.zig`, or warm-index consumers."
dependencies: "159b-performance-frontier-five-area-map"
next_todo: /todo/pending/159d-performance-frontier-five-area-map.md
continuation: "On completion: capture evidence, set status done, move this file to /todo/changelog/, and continue immediately to 159d."
blocked_reason: ""
unblock_action: ""
resumption_point: ""
---
# 159c Ignore and Discovery Parity Map

## Execute Now
Map existing ignore parsing, discovery admission, explicit overrides, and warm-frontier candidate-universe parity without changing traversal behavior.

## Slice Focus Rule
Own only directory and path admission semantics; do not lower trigram thresholds, activate byte sharding, modify the parser, or promote warm indexing while this unit is live.

## Why This Execution Unit Exists
The ranked opportunity calls `.gitignore` support “missing,” but `src/core/admission.zig` already loads and evaluates `.gitignore`, `.ignore`, and `.agignore`. The real planning question is whether all cold discovery routes and warm frontiers apply the same effective policy, including build-output defaults and `--hidden`/`-u` overrides. Treating parser existence as shipped parity or adding a second ignore engine would both be architecture failures.

## Better-Than-Before Delta
Before this slice, ignore support is a broad speed claim. After it, the plan separates rule parsing, root loading, recursive application, default directory exclusions, override semantics, telemetry, and warm-frontier invalidation, so only the missing owner boundary is repaired.

## Slice Domain Standard

| Domain Standard | Local Evidence | Implementation Consequence | Anti-Assumption Guard |
|---|---|---|---|
| Git-compatible patterns are last-match-wins with negation and directory semantics. | `src/core/admission.zig`; `.refs/ripgrep`; competitor map. | Test anchored, directory-only, negated, external, and nested rules. | Do not reduce patterns to basename filters. |
| Explicit overrides must be real. | `search.zig` `request.hidden`, `-u`, `no_ignore`; commit `6106b5e1`. | Prove default skips and explicit inclusion separately. | Do not conflate `no_ignore` with build-output policy. |
| Warm candidates must reflect current discovery policy. | `search.zig:prepareWarmIndexFrontier`; warm architecture note. | Rule/config changes invalidate or bypass stale frontiers. | Do not scan an ignored warm file because it was previously indexed. |

## Domain-Knowledge Research Check

| Knowledge Gap | Research / Probe To Run | Source Priority | Decision It Controls | Closure Evidence |
|---|---|---|---|---|
| Existing parser parity | Inspect `admission.zig` pattern parser and tests; compare `.refs/ripgrep` ignore crate behavior. | Local source and pinned reference. | Whether parser changes are needed. | Rule matrix. |
| Warm bypass behavior | Trace `prepareWarmIndexFrontier`, active-file selection, freshness metadata, and cold fallback. | Local source/docs/runtime. | Warm policy contract. | Candidate-universe flow map. |

## Technical Execution Blueprint

| Area | Required Detail |
|---|---|
| Repository anchors | `src/core/admission.zig:47-200`; `src/core/search.zig` root loading, recursive discovery, parallel/serial admission, `prepareWarmIndexFrontier`; `src/cli/args.zig` flags; tests around discovery/warm coverage. |
| Existing-owner decision | Extend `PathAdmission` and discovery callers only if proof finds a gap; do not add a new gitignore parser. |
| Domain owner / canonical standard | `admission.zig` owns rule semantics; `search.zig` owns traversal and fallback; warm catalog owns candidate identity. |
| Intended design | `request → root ignore load → recursive entry decision → default exclusion/override → materialized files → scan`; warm path must validate equivalent policy or fall back cold. |
| Integration path | CLI cold search, `--hidden`, `-u`, explicit no-ignore, parallel discovery, warm search, and JSON skipped telemetry. |
| Failure modes to prevent | Negation loss, nested-rule drift, warm stale inclusion, parallel/serial disagreement, hidden override regression, and generated-tree false negatives. |
| Alternatives rejected | New glob engine; blanket vendor/build exclusion; treating ignored-file count as performance proof; warm bypass without policy identity. |
| Proof hooks | Adversarial fixture tree, cold/warm exact file/match parity, serial/parallel comparison, explicit overrides, and malformed-rule behavior. |

## Codebase Research And Execution Addendum

**Implementation map:** Inspect `PathAdmission`, root loader, local rule loader, recursive directory functions, parallel discovery dispatch, warm frontier preparation, and build-output exclusion tests.

**Existing-owner directive:** Keep rule semantics in `admission.zig`; keep path traversal in `search.zig`; keep warm eligibility in the index/catalog owner.

**Directive:** First prove whether the missing value is parser support, caller wiring, default policy, or warm invalidation; repair only that owner in a later chain.

**Gold-standard guardrail:** Never “fix” performance by excluding a directory that the user did not authorize excluding; every default exclusion needs an explicit override and parity fixture.

**Knowledge gathering route:** Compare pinned ripgrep/gitoxide source and local competitor anatomy; use current git documentation only if a pattern semantic is not settled by source.

**Runtime visualization:** `CLI flags/root → ignore-rule load → path decision → file set → cold scan OR warm frontier validation → verified output`.

**Proof expansion:** Future implementation must exercise serial/parallel, nested/negated/anchored/directory-only, external rules, hidden/unrestricted, warm stale, and cold fallback cases.

## Embedded Framing
The fastest safe traversal is the smallest correct candidate universe; policy parity is part of the corpus definition, not a cosmetic filter.

## Slice Research Directive

| Research Topic | Why It Matters To This Slice | Insect Mode | Source Priority | Closure Evidence |
|---|---|---|---|---|
| Git-compatible ignore behavior | Prevent false negatives and parser duplication. | `.refs/` harvest; bounded `engine --query` if needed. | ripgrep source, git docs, gitoxide. | Adversarial rule table. |
| Warm candidate invalidation | Prevent stale ignored files from bypassing discovery. | Local source/docs/runtime probe. | Warm architecture note, catalog/generation code. | Warm-vs-cold policy contract. |

## Original User Message Proof

| Source Anchor | Verbatim Original Snippet | Slice Proof Obligation | Evidence Capture |
|---|---|---|---|
| U4 | "3. 🟡 .gitignore support (2-10x on real projects)" | Identify existing support and exact gap before proposing changes. | Owner map and parity matrix. |
| U7 | "be very careful that we don't create false negatives" | Prove negation, override, and warm fallback behavior. | I1/I5 and adversarial fixtures. |

## Entry State

- `159b` is archived with admission and discovery semantics distinguished.
- Parent 159 records `admission.zig` and `search.zig` as the existing path owners.

## Patch Surface

**Modifies:** None.

**Adds:** This planning unit only.

**Deletes:** None.

**Must not touch:** `src/core/admission.zig`, `src/core/search.zig`, `src/cli/args.zig`, `.docs/log.txt`, and `.docs/changelog.txt`.

## Detailed Requirements

- R1: Enumerate `.gitignore`, `.ignore`, `.agignore`, external ignore-file, nested, anchored, negated, directory-only, hidden, and unrestricted behavior.
- R2: Distinguish default build-output exclusions from ignore-file semantics and name their override path.
- R3: Compare serial and parallel discovery file sets and telemetry.
- R4: Define warm-frontier policy identity/freshness requirements and explicit cold fallback for mismatch.
- R5: Preserve valid files re-included by negation and all exact match/output coordinates.

## Invariants This Unit Must Preserve

- I1, I2, I4, I5 above.

## Validation Plan

| Step | Command | Expected Exit Code | Expected Output Pattern | Idempotent |
|---|---|---:|---|---|
| 1 | `git diff --check` | 0 | empty stdout | yes |

**Evidence to capture:** Plan diff check and exact owner references; no executable behavior is claimed here.

## Exit State (Handoff Contract)

- The next unit can reason about byte ranges over a stable candidate universe.
- Any future `.gitignore` work begins at the existing parser/discovery owners and includes warm parity or a fail-closed bypass.

## Rollback Procedure

1. Delete only this planning unit.
2. Leave parser, discovery, and warm state untouched.

## Next todo
`/todo/pending/159d-performance-frontier-five-area-map.md`

## Completion
- [ ] Pre-flight passed.
- [ ] Documentation-only exemption recorded.
- [ ] Validation executed and evidence captured.
- [ ] Status set to `done`.
- [ ] Move verified.
- [ ] Continue to 159d.
