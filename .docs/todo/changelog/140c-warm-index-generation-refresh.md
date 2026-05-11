---
id: 140c-warm-index-generation-refresh
parent: 140-warm-index-generation-refresh
type: execution-unit
protocol_version: "2.1"
category: feature
phase: c
status: done
patch_scope: "Create `.ix/index/generations/<epoch>/` path helpers and tmp layout."
blast_radius: high
blast_radius_justification: "The warm-index substrate can influence search candidate selection and background writes; failure is contained by fail-closed fallback to the existing search path and unit-local rollback."
idempotency_contract: idempotent
idempotency_notes: "Re-running is safe after checking git diff because this unit only edits deterministic source/docs artifacts and validation commands are read-only."
acceptance: "Generation storage layout is complete when the declared patch surface exists, public search compatibility is preserved, and the validation command records passing output or a concrete blocker."
exit_criterion: "zig build test"
validation: "zig build test"
expected_exit_code: 0
expected_output_pattern: "Build Summary"
evidence: "Validation: `zig build test --summary all` exit 0 -> Build Summary: 3/3 steps succeeded; 114/114 tests passed. Added GenerationPaths with index_dir, generations_dir, generation_dir, tmp_dir, manifest_path, and tmp_manifest_path helpers; invalid epoch fails closed."
conflict_surface: ""
invariants:
  - "I1: Public command contracts remain backward compatible."
  - "I2: Verifier remains final owner of match correctness."
  - "I3: Bad index state fails closed."
  - "I4: Background workers stay silent during public search."
  - "I5: Search-visible generations publish atomically."
  - "I6: Windows freshness is USN-first with conservative fallback."
source_message_anchor: "U3, U5, U6"
source_message_excerpt: "Then let's attempt this experiment. Go all out. | To slice this entire research into at least 90 to-do slices using the planning spec skill. | Once that is established, proceed to implementation."
source_message_proof_obligation: "Generation storage layout preserves or implements the cited original request within the warm-layer execution program."
entry_state: "Dependency 140b-warm-index-generation-refresh is archived with non-PLACEHOLDER evidence before this unit starts."
rollback_surface: "Use non-interactive git diff to identify this unit's touched files, then revert only those unit-local edits before retrying. Do not revert unrelated user changes."
dependencies: "140b-warm-index-generation-refresh"
next_todo: /todo/pending/140d-warm-index-generation-refresh.md
continuation: "On completion: record evidence (replace PLACEHOLDER), set status done, move this file to /todo/changelog/<same filename>, continue immediately to next_todo. Do not pause. Do not batch."
blocked_reason: ""
unblock_action: ""
resumption_point: ""
---
# 140c Generation storage layout

## Execute Now
Generation storage layout: Create `.ix/index/generations/<epoch>/` path helpers and tmp layout.

## Why This Execution Unit Exists
This unit isolates implementation work for Warm Index Generation Refresh. The slice is intentionally narrow so candidate selection, index persistence, process lifecycle, and freshness semantics remain auditable across the warm-index program.

## Original User Message Proof

| Source Anchor | Verbatim Original Snippet | Slice Proof Obligation | Evidence Capture |
|---------------|---------------------------|------------------------|------------------|
| U3 | "Then let's attempt this experiment. Go all out." | Generation storage layout must preserve this request fragment. | Validation output plus changed-file review for this unit. |
| U5 | "To slice this entire research into at least 90 to-do slices using the planning spec skill." | Generation storage layout must preserve this request fragment. | Validation output plus changed-file review for this unit. |
| U6 | "Once that is established, proceed to implementation." | Generation storage layout must preserve this request fragment. | Validation output plus changed-file review for this unit. |

## Pre-flight Checklist
- [x] All `dependencies` are archived in `/todo/changelog/` with non-PLACEHOLDER evidence.
- [x] All `entry_state` claims are verifiable on the current filesystem.
- [x] `source_message_anchor`, `source_message_excerpt`, and `source_message_proof_obligation` are populated and match the parent source-message capture.
- [x] `conflict_surface` is empty or cross-chain dependency is resolved.
- [x] Rollback procedure is populated for blast_radius medium or high.
- [x] If re-executing after partial failure: idempotency_contract is read and the correct recovery path is determined.

## Entry State
- The file `.docs/todo/changelog/140b-warm-index-generation-refresh.md` exists and carries non-PLACEHOLDER evidence.
- The research artifact exists at `.docs/research/2026-05-11-warm-layer-sidecar-architecture.md`.

## Patch Surface

**Modifies:**
- `src/**` - exact file list must be narrowed by executing agent before patching.
- `.docs/**` - docs or test evidence only when required by this unit.

**Adds:**
- New warm-index files only when this unit's title requires a new owner module or test fixture.

**Deletes:**
- None unless the unit explicitly replaces an obsolete generated artifact and documents the reason in evidence.

**Must not touch (out of scope for this unit):**
- Public command names or output schemas outside explicitly documented telemetry fields.
- Unrelated benchmark harnesses, vendored dependencies, or generated cache artifacts.

## Detailed Requirements
- R1: Preserve public CLI compatibility and existing verifier-owned match correctness.
- R2: Implement only the patch surface named by this unit title and metadata.
- R3: Fail closed to existing search behavior when index state is absent, malformed, stale, or unsupported.
- R4: Record exact validation output before changing status to done.

## Invariants This Unit Must Preserve
- I1: Public `ix search`, `ix matches`, `ix inspect`, and `ix explain` command contracts remain backward compatible.
- I2: The verifier remains the final owner of match correctness.
- I3: Incomplete, stale, malformed, or wrong-root index state fails closed.
- I4: Background workers never write user-facing stdout/stderr during normal public search.
- I5: Search-visible index generations are published atomically.
- I6: Windows freshness uses USN when available and conservative fallback when uncertain.

## Validation Plan

| Step | Command | Expected Exit Code | Expected Output Pattern | Idempotent |
|------|---------|-------------------|------------------------|-----------|
| 1 | `zig build test` | `0` | `Build Summary` | yes |

**Evidence to capture:** exact command output, changed file list, and any blocker text if validation cannot run.

## Exit State (Handoff Contract)
- Generation storage layout is complete and the next unit can verify it from filesystem state plus archived evidence.
- Public search behavior remains compatible or the blocker is recorded before archival.

## Rollback Procedure
1. Run `git diff --name-only` and identify only files touched by this unit.
2. Revert only this unit's touched files with non-interactive git restore after confirming no unrelated user edits are present.
3. Re-run the validation command and record the resulting state.

## Next todo
`/todo/pending/140d-warm-index-generation-refresh.md`

## Completion
- [x] Pre-flight passed (all checklist items verified before execution began).
- [x] All validation commands executed. Exit codes match `expected_exit_code`. Output matches `expected_output_pattern`.
- [x] Post-flight: all Exit State claims are verifiable on the filesystem.
- [x] Evidence captured. `evidence` field updated. PLACEHOLDER is gone.
- [x] Status set to `done`.
- [x] Move this file to `/todo/changelog/140c-warm-index-generation-refresh.md` verified.
- [x] Continue immediately to `next_todo`. No pause. No batch.
