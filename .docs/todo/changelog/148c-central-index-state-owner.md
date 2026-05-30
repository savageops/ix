---
id: 148c-central-index-state-owner
parent: 148-central-index-state-owner
type: subtodo
phase: c
category: feature
status: done
source_message_anchor: U6
source_message_excerpt: "Make sure you didn't slow the framework down"
source_message_proof_obligation: "Route foreground search caches through the central owner without changing cold scan semantics or match-count behavior."
next_todo: /todo/pending/148d-central-index-state-owner.md
---
# 148c Search Cache Owner

## Objective

Make foreground search consume the central index state owner consistently: warm query cache, stats cache, and evidence cache must not create writable state in the working directory or searched root.

## Original User Message Proof

- U6: "Make sure you didn't slow the framework down"

## Required Patch

- `prepareWarmIndexFrontier` reads `index.live`, manifest, generation payload, and query caches from the central index directory.
- Warm query cache writes under `<state>/index/roots/<fingerprint>/query`.
- Stats cache writes under `<state>/cache/stats`.
- Dynamic evidence cache writes under `<state>/cache/evidence`.
- Parent directories are created before cache writes.

## Exit Criteria

- Existing warm tests pass with `IX_STATE_DIR` override.
- Cold/default test suite remains green with indexing disabled.

## Evidence

- `src/core/search.zig` reads `index.live`, manifest, generation payload, and warm query caches from the central root index directory.
- Warm query cache writes under `<state>/index/roots/<fingerprint>/query`.
- Stats cache writes under `<state>/cache/stats`.
- Evidence cache writes under `<state>/cache/evidence`.
- Cache writes create their parent directories before writing.
- Full suite with `IX_STATE_DIR` override passed after the patch.
