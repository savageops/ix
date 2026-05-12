---
id: 143d-regex-decomposition-fastcount
parent: 143-regex-decomposition-fastcount
type: verification-unit
protocol_version: "2.1"
category: bug
phase: d
status: done
patch_scope: "Full validation, before/after benchmark report, changelog closeout."
blast_radius: low
blast_radius_justification: "Verification and documentation artifacts after runtime code is complete."
idempotency_contract: idempotent
idempotency_notes: "Validation commands and report generation can be rerun."
acceptance: "Post-change benchmark improves over Zig before-change while preserving correctness and comparator evidence."
exit_criterion: "Tests pass and .docs/reports/regex-decomposition-fastcount-2026-05-12-after/comparison.json plus summary.md exist."
validation: "zig build test --summary all && zig build -Doptimize=ReleaseFast --summary all"
expected_exit_code: 0
expected_output_pattern: "Build Summary:"
evidence: "zig build test --summary all passed 170/170; ReleaseFast build passed; after comparison median total Zig 34.7509ms vs Zig before 119.2934ms and Rust IX 43.8883ms."
conflict_surface: ""
invariants:
  - "I1: Search result counts for the target workload remain 30."
  - "I2: Candidate-line fast count never returns a positive result without regex verification on the candidate line."
  - "I3: Bailout falls back to the existing line scanner rather than reporting partial counts."
  - "I4: Non-stats hit collection remains on the existing line/hit-retention path."
  - "I5: Before/after evidence must include pre-change Zig, post-change Zig, and Rust IX comparator numbers."
source_message_anchor: "U3, U4"
source_message_excerpt: "proceed to completion | Make sure we have before and after comparison to ensure that we are improving."
source_message_proof_obligation: "Close the chain with tests and before/after performance proof."
entry_state: "143c release binary routes the target workload through regex decomposition fast count."
rollback_surface: "If validation fails, revert source changes and remove after-report artifacts."
dependencies: "143c-regex-decomposition-fastcount"
next_todo: NONE
continuation: "On completion: record evidence, set status done, move this file to /todo/changelog/143d-regex-decomposition-fastcount.md, then archive the parent."
blocked_reason: ""
unblock_action: ""
resumption_point: ""
---
# 143d Verification Closeout

## Execute Now
Run full tests and before/after comparator benchmarks, then record the final evidence.

## Original User Message Proof
| Source Anchor | Verbatim Original Snippet | Slice Proof Obligation | Evidence Capture |
|---------------|---------------------------|------------------------|------------------|
| U3 | "proceed to completion" | This unit closes the chain rather than stopping at implementation. | Tests, release build, and changelog. |
| U4 | "Make sure we have before and after comparison to ensure that we are improving." | This unit captures the after side and compares it with baseline. | Summary JSON and metrics. |

## Validation Plan
| Step | Command | Expected Exit Code | Expected Output Pattern | Idempotent |
|------|---------|-------------------|------------------------|-----------|
| 1 | `zig build test --summary all` | `0` | `Build Summary:` | yes |
| 2 | `zig build -Doptimize=ReleaseFast --summary all` | `0` | `Build Summary:` | yes |
| 3 | `git diff --check` | `0` | no output | yes |

## Exit State
- Post-change report exists.
- Changelog records the implementation and benchmark delta.
- Parent chain can be archived.
- `.docs/reports/regex-decomposition-fastcount-2026-05-12-after/comparison.json` and `summary.md` contain the before/after/Rust proof.
- Post-change target telemetry: `matches_found=30`, `eligible_files=1`, `counted_files=1`, `candidate_lines_checked=78`, `candidate_lines_matched=30`.

## Next todo
`NONE`
