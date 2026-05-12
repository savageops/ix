---
id: 143a-regex-decomposition-fastcount
parent: 143-regex-decomposition-fastcount
type: execution-unit
protocol_version: "2.1"
category: bug
phase: a
status: done
patch_scope: "Baseline and contract lock without source-code changes."
blast_radius: low
blast_radius_justification: "Documentation and benchmark artifact only; no runtime code changes."
idempotency_contract: idempotent
idempotency_notes: "Re-running the baseline regenerates report files for the same workload."
acceptance: "Baseline evidence records Zig before-change and Rust IX comparator values for the target regex workload."
exit_criterion: ".docs/reports/regex-decomposition-fastcount-2026-05-12-baseline/samples.json exists and contains zig_before and rust_ix rows."
validation: "Test-Path .docs/reports/regex-decomposition-fastcount-2026-05-12-baseline/samples.json"
expected_exit_code: 0
expected_output_pattern: "True"
evidence: "Baseline artifact exists. Zig before median total 119.2934ms with matches_found=30 and regex_counted=0. Rust IX baseline median total 47ms-class with matches_found=30 and regex_counted=1."
conflict_surface: ""
invariants:
  - "I1: Search result counts for the target workload remain 30."
  - "I5: Before/after evidence must include pre-change Zig, post-change Zig, and Rust IX comparator numbers."
source_message_anchor: "U2, U4"
source_message_excerpt: "Use the planning spec skill after gathering research to lock it in | Make sure we have before and after comparison to ensure that we are improving."
source_message_proof_obligation: "Freeze the researched baseline before runtime edits."
entry_state: "Fresh baseline command has been executed for zig_before and rust_ix on the subtitle regex workload."
rollback_surface: "Delete .docs/reports/regex-decomposition-fastcount-2026-05-12-baseline if the baseline is invalid."
dependencies: ""
next_todo: /todo/changelog/143b-regex-decomposition-fastcount.md
continuation: "On completion: record evidence, set status done, move this file to /todo/changelog/143a-regex-decomposition-fastcount.md, continue immediately to next_todo."
blocked_reason: ""
unblock_action: ""
resumption_point: ""
---
# 143a Baseline Contract Lock

## Execute Now
Validate the fresh baseline artifact and lock the exact acceptance boundary before code edits.

## Original User Message Proof
| Source Anchor | Verbatim Original Snippet | Slice Proof Obligation | Evidence Capture |
|---------------|---------------------------|------------------------|------------------|
| U2 | "Use the planning spec skill after gathering research to lock it in" | This unit locks the researched plan and source evidence. | Baseline artifact path and comparator values. |
| U4 | "Make sure we have before and after comparison to ensure that we are improving." | This unit records the before side of before/after. | Zig before and Rust IX median metrics. |

## Validation Plan
| Step | Command | Expected Exit Code | Expected Output Pattern | Idempotent |
|------|---------|-------------------|------------------------|-----------|
| 1 | `Test-Path .docs/reports/regex-decomposition-fastcount-2026-05-12-baseline/samples.json` | `0` | `True` | yes |

## Exit State
- Baseline report exists at `.docs/reports/regex-decomposition-fastcount-2026-05-12-baseline/samples.json`.
- Zig before-change target workload has match count 30 and no regex decomposition count.
- Rust IX target workload has match count 30 and regex decomposition count active.

## Completion Evidence
- `.docs/reports/regex-decomposition-fastcount-2026-05-12-baseline/samples.json` exists.
- Baseline samples captured `zig_before` and `rust_ix` rows for the target workload.

## Next todo
`/todo/changelog/143b-regex-decomposition-fastcount.md`
