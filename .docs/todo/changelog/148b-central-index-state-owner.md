---
id: 148b-central-index-state-owner
parent: 148-central-index-state-owner
type: subtodo
phase: b
category: feature
status: done
source_message_anchor: U3,U4,U5
source_message_excerpt: "why doesn't the index build in the same directory where the executable is instead"; "So in IX's directory in app data"; "Please check if there's any more stale processes"
source_message_proof_obligation: "Implement one central state owner for indexd/generation/live marker state and remove root-local managed-root gating."
next_todo: /todo/pending/148c-central-index-state-owner.md
---
# 148b Indexd / Generation Owner

## Objective

Move generation path construction and indexd live ownership out of scanned roots and into an IX-owned state directory keyed by root fingerprint. Sidecar launch policy must no longer reject generated-looking roots merely because writable state used to live under the root.

## Original User Message Proof

- U3: "why doesn't the index build in the same directory where the executable is instead"
- U4: "So in IX's directory in app data"
- U5: "Please check if there's any more stale processes"

## Required Patch

- Add `src/core/state_dir.zig`.
- Teach `generation` to build paths from a storage index directory.
- Teach `indexd` to resolve `config.index_dir` from root fingerprint and central state.
- Remove root-local sidecar eligibility coupling from `main`.
- Add regression tests for generated-looking roots and central state ownership.

## Exit Criteria

- Existing root-local `.ix/index` live marker paths are no longer the active owner.
- Tests prove `indexd` config and generation payloads resolve through central state.

## Evidence

- Added `src/core/state_dir.zig` with `IX_STATE_DIR` override and platform fallback to an IX-owned state directory.
- `src/core/generation.zig` now supports path construction from a storage index directory.
- `src/core/indexd.zig` resolves `config.index_dir` from `catalog.identifyRoot` plus `state_dir.buildRootIndexState`.
- `src/main.zig` no longer blocks sidecar launch for generated-looking roots based on root-local storage policy.
- Regression tests cover central index config and generated-looking roots.
