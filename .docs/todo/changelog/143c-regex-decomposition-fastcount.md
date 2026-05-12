---
id: 143c-regex-decomposition-fastcount
parent: 143-regex-decomposition-fastcount
type: execution-unit
protocol_version: "2.1"
category: bug
phase: c
status: done
patch_scope: "Stats-only scan-path integration and telemetry merge."
blast_radius: medium
blast_radius_justification: "Touches mmap and single-buffer scan paths plus shard telemetry aggregation."
idempotency_contract: idempotent
idempotency_notes: "Source patch is deterministic; rollback is source revert."
acceptance: "Stats-only scan path attempts regex decomposition before whole-buffer/per-line fallback and reports telemetry."
exit_criterion: "Target workload JSON reports regex_decomposition.counted_files=1 and matches_found=30."
validation: "zig-out/bin/ix-zig.exe search 're:Sherlock\\s+Holmes' E:/Workspaces/01_Projects/01_Github/iEx/.refs/ripgrep/benchsuite/subtitles/en.sample.txt --stats-only --json --threads 8"
expected_exit_code: 0
expected_output_pattern: "\"matches_found\":30"
evidence: "Release target JSON reports matches_found=30, regex_decomposition.eligible_files=1, counted_files=1, candidate_lines_checked=78, candidate_lines_matched=30."
conflict_surface: ""
invariants:
  - "I1: Search result counts for the target workload remain 30."
  - "I3: Bailout falls back to the existing line scanner rather than reporting partial counts."
  - "I4: Non-stats hit collection remains on the existing line/hit-retention path."
source_message_anchor: "U1"
source_message_excerpt: "proceed"
source_message_proof_obligation: "Wire the primitive into the actual runtime entrypoint."
entry_state: "143b helpers exist and tests pass."
rollback_surface: "Revert scan-path changes in src/core/search.zig."
dependencies: "143b-regex-decomposition-fastcount"
next_todo: /todo/changelog/143d-regex-decomposition-fastcount.md
continuation: "On completion: record evidence, set status done, move this file to /todo/changelog/143c-regex-decomposition-fastcount.md, continue immediately to next_todo."
blocked_reason: ""
unblock_action: ""
resumption_point: ""
---
# 143c Runtime Wiring

## Execute Now
Wire regex decomposition fast count into the stats-only scan path and aggregate its telemetry.

## Original User Message Proof
| Source Anchor | Verbatim Original Snippet | Slice Proof Obligation | Evidence Capture |
|---------------|---------------------------|------------------------|------------------|
| U1 | "proceed" | This unit connects the implemented primitive to the running command. | Target command JSON excerpt. |

## Validation Plan
| Step | Command | Expected Exit Code | Expected Output Pattern | Idempotent |
|------|---------|-------------------|------------------------|-----------|
| 1 | `zig build -Doptimize=ReleaseFast --summary all` | `0` | `Build Summary:` | yes |
| 2 | `zig-out/bin/ix-zig.exe search 're:Sherlock\\s+Holmes' E:/Workspaces/01_Projects/01_Github/iEx/.refs/ripgrep/benchsuite/subtitles/en.sample.txt --stats-only --json --threads 8` | `0` | `"matches_found":30` | yes |

## Exit State
- Release binary executes the target workload through regex decomposition telemetry.

## Completion Evidence
- `scanFileMmap` and shard single-buffer stats-only paths attempt regex decomposition before whole-buffer/per-line fallback.
- JSON output now emits real `regex_decomposition` and `acceleration_bailouts` counters instead of hardcoded zeros.
- Target command returned `matches_found=30` and `candidate_lines_checked=78`.

## Next todo
`/todo/changelog/143d-regex-decomposition-fastcount.md`
