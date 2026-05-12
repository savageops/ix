---
id: 143-regex-decomposition-fastcount
type: parent
protocol_version: "2.1"
spec_status: approved
category: bug
status: done
epic_boundary: "Restore stats-only regex decomposition fast-count parity for mandatory-literal regexes on large files."
subtodo_start: /todo/changelog/143a-regex-decomposition-fastcount.md
subtodo_final: /todo/changelog/143d-regex-decomposition-fastcount.md
continuation: "After each completed execution unit: record evidence, set status done, move to /todo/changelog/, continue immediately to next_todo. Never batch-archive. Never pause between units."
source_message_policy: "Every lettered unit MUST include source_message_anchor, source_message_excerpt, source_message_proof_obligation, and an Original User Message Proof section with verbatim snippets from the original user message."
---
# 143 Regex Decomposition Fastcount

## Objective
Add a stats-only fast-count path for safe regex decomposition candidates so large single-file regex scans verify only candidate lines and preserve exact regex verification semantics. The immediate proving workload is `re:Sherlock\s+Holmes` over the 144 MB subtitle corpus, where Zig currently trails Rust IX because it performs broad per-line regex work instead of candidate-line narrowing.

## Rationale
Fresh baseline shows Zig before-change at roughly 119 ms engine time with `regex_decomposition.counted_files=0`, while Rust IX is roughly 47 ms with `candidate_lines_checked=78`. The system already classifies and reports regex-decomposition telemetry, but the hot mmap stats-only path does not execute a decomposition count.

## Scope
**In scope:**
- Add a safe mandatory-literal regex decomposition counter for stats-only search.
- Wire the counter into mmap and single-buffer stats-only scan before per-line fallback.
- Preserve PCRE/Zig regex verification as the final authority for candidate lines.
- Capture before/after comparison against Rust IX and pre-change Zig baseline.

**Out of scope:**
- New regex engine implementation.
- Warm index adoption changes.
- Windows protected-store admission changes.
- General streaming discovery refactor.

## Source Language Anchors
- "proceed"
- "Use the planning spec skill after gathering research to lock it in"
- "proceed to completion"
- "Make sure we have before and after comparison to ensure that we are improving."

## Original User Message Capture
| Anchor ID | Information Piece | Verbatim Original Snippet | Required Coverage |
|-----------|-------------------|---------------------------|-------------------|
| U1 | execute selected slice | "proceed" | 143b, 143c |
| U2 | planning protocol | "Use the planning spec skill after gathering research to lock it in" | 143a |
| U3 | completion requirement | "proceed to completion" | 143d |
| U4 | benchmark proof | "Make sure we have before and after comparison to ensure that we are improving." | 143a, 143d |

## Source Message Coverage
| Unit | Source Anchor(s) | Slice Proof Obligation |
|------|------------------|------------------------|
| 143a | U2, U4 | Freeze researched baseline and define acceptance metrics before code changes. |
| 143b | U1 | Add safe predicate classification and candidate-line counting primitives. |
| 143c | U1 | Wire the primitive into stats-only scan paths without bypassing regex verification. |
| 143d | U3, U4 | Validate tests and before/after benchmark deltas, then close the chain. |

## Constraints
| Dimension | Constraint |
|-----------|-----------|
| Category boundary | Bugfix only: restore a missing fast path for an already represented capability. |
| Blast radius ceiling | Medium: scan hot path changes can affect stats-only regex counts. |
| Structural boundary | `src/core/expr.zig`, `src/core/search.zig`, and report docs only. |
| Dependency boundary | Reuse existing PCRE/Zig regex verification; no second regex engine. |
| Rollback surface | Revert the touched source files and generated report/doc artifacts. |
| Parallelism | No lettered units run in parallel; each depends on the prior proof. |

## Invariants
- I1: Search result counts for the target workload remain `30`.
- I2: Candidate-line fast count never returns a positive result without regex verification on the candidate line.
- I3: Bailout falls back to the existing line scanner rather than reporting partial counts.
- I4: Non-stats hit collection remains on the existing line/hit-retention path.
- I5: Before/after evidence must include pre-change Zig, post-change Zig, and Rust IX comparator numbers.

## Chain Manifest
| File | Phase | Role | Status |
|------|-------|------|--------|
| `/todo/changelog/143-regex-decomposition-fastcount.md` | parent | Chain root | done |
| `/todo/changelog/143a-regex-decomposition-fastcount.md` | a | Baseline / contract lock | done |
| `/todo/changelog/143b-regex-decomposition-fastcount.md` | b | Primitive implementation | done |
| `/todo/changelog/143c-regex-decomposition-fastcount.md` | c | Scan-path wiring | done |
| `/todo/changelog/143d-regex-decomposition-fastcount.md` | d | Verification / closeout | done |

## Phase Plan
| Letter | Role | Patch Surface | Depends On | Parallelizable |
|--------|------|--------------|-----------|---------------|
| `a` | Baseline / contract lock | Research evidence and benchmark baseline | - | No |
| `b` | Primitive implementation | `src/core/expr.zig`, `src/core/search.zig` helper functions | `a` | No |
| `c` | Scan-path wiring | `src/core/search.zig` mmap/single-buffer scan integration and telemetry merge | `b` | No |
| `d` | Verification / regression / closeout | tests, benchmark report, changelog | `c` | No |

## Validation Expectations
- Signal 1: Zig post-change reports `matches_found=30` for `re:Sherlock\s+Holmes`.
- Signal 2: Zig post-change reports `regex_decomposition.eligible_files=1`, `counted_files=1`, and candidate-line telemetry near Rust IX.
- Signal 3: Zig post-change engine median improves over the fresh pre-change baseline.
- Signal 4: `zig build test --summary all` and `zig build -Doptimize=ReleaseFast --summary all` pass.

## Closeout Evidence
- Baseline: Zig before median total `119.2934ms`, matches `30`, regex counted `0`.
- After: Zig median total `34.7509ms`, matches `30`, regex counted `1`, candidate lines `78`.
- Comparator: Rust IX median total `43.8883ms`, matches `30`, regex counted `1`, candidate lines `78`.
- Validation: `zig build test --summary all` passed `170/170`; `zig build -Doptimize=ReleaseFast --summary all` passed.

## Next todo
`NONE`
