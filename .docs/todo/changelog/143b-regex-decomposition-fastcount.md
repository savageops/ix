---
id: 143b-regex-decomposition-fastcount
parent: 143-regex-decomposition-fastcount
type: execution-unit
protocol_version: "2.1"
category: bug
phase: b
status: done
patch_scope: "Regex decomposition classification and candidate-line primitive."
blast_radius: medium
blast_radius_justification: "Touches regex strategy classification and stats-only count helper used by scan hot paths."
idempotency_contract: idempotent
idempotency_notes: "Applying the same source patch twice should be rejected by context; rollback is source revert."
acceptance: "Safe mandatory-literal regexes can be identified and candidate lines counted only after regex verification."
exit_criterion: "zig build test --summary all exits 0 after primitive tests are added."
validation: "zig build test --summary all"
expected_exit_code: 0
expected_output_pattern: "Build Summary:.*success"
evidence: "Added canonical expr.regexDecompositionLiteralCandidate, search-layer regexDecompositionFastCount, and adversarial unit coverage. zig build test --summary all passed 170/170."
conflict_surface: ""
invariants:
  - "I1: Search result counts for the target workload remain 30."
  - "I2: Candidate-line fast count never returns a positive result without regex verification on the candidate line."
  - "I3: Bailout falls back to the existing line scanner rather than reporting partial counts."
source_message_anchor: "U1"
source_message_excerpt: "proceed"
source_message_proof_obligation: "Implement the selected weak-link primitive."
entry_state: "143a baseline artifact exists and target loss mechanism is candidate-line decomposition absence."
rollback_surface: "Revert changes in src/core/expr.zig and src/core/search.zig."
dependencies: "143a-regex-decomposition-fastcount"
next_todo: /todo/changelog/143c-regex-decomposition-fastcount.md
continuation: "On completion: record evidence, set status done, move this file to /todo/changelog/143b-regex-decomposition-fastcount.md, continue immediately to next_todo."
blocked_reason: ""
unblock_action: ""
resumption_point: ""
---
# 143b Primitive Implementation

## Execute Now
Add bounded candidate-line decomposition primitives for safe mandatory-literal regex patterns.

## Original User Message Proof
| Source Anchor | Verbatim Original Snippet | Slice Proof Obligation | Evidence Capture |
|---------------|---------------------------|------------------------|------------------|
| U1 | "proceed" | This unit performs the implementation step authorized by the user. | Source diff and passing tests. |

## Validation Plan
| Step | Command | Expected Exit Code | Expected Output Pattern | Idempotent |
|------|---------|-------------------|------------------------|-----------|
| 1 | `zig build test --summary all` | `0` | `Build Summary:` | yes |

## Exit State
- `src/core/search.zig` contains candidate-line decomposition helpers.
- Regex candidate lines are verified through existing regex verification.

## Completion Evidence
- `src/core/expr.zig` owns the safe decomposition literal proof.
- `src/core/search.zig` verifies candidate lines through PCRE/Zig regex before counting.
- `zig build test --summary all` passed `170/170`.

## Next todo
`/todo/changelog/143c-regex-decomposition-fastcount.md`
