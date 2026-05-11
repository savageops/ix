# Warm Index Windows Freshness Policy

## Contract

The warm index uses Windows freshness evidence as a background maintenance input only. Public `ix search`, `ix matches`, `ix inspect`, and `ix explain` remain verifier-owned and must fail closed to the existing foreground search path when the warm state is missing, stale, malformed, wrong-root, or discontinuous.

## Backend Matrix

| State | Backend | Action | Search-visible effect |
|---|---|---|---|
| USN available and cursor continuous | `usn_delta` | Read bounded USN record batches, map records to delta tasks, coalesce duplicates, and publish a refreshed generation. | Silent acceleration only after an atomic generation is valid. |
| USN unavailable or inaccessible | `directory_watch_invalidate` | Use `ReadDirectoryChangesW` only as a wakeup/invalidation source and schedule root reconciliation. | No surgical delta claim; stale risk collapses to rebuild. |
| Cursor missing | root reconcile | Treat as lost continuity and rebuild root-local catalog/postings. | No partial warm reuse. |
| Journal wrapped or changed identity | root reconcile | Reject delta application and rebuild from root. | No stale journal replay. |
| Bounded read overflow | root reconcile | Reject truncated delta batch and rebuild from root. | No missing mutation window. |
| Pending path lookup remains unresolved | root reconcile | Defer surgical mutation until file identity maps to catalog ownership. | No path-guessing fallback. |

## State Machine

`JournalAvailability` chooses the backend. `evaluateDeltaContinuity` gates whether a USN batch may apply. `mapRecordToDeltaTask` emits `upsert_file`, `delete_file`, or `reconcile_root`. `coalesceDeltaTasks` folds duplicate identities before mutation. `planDeltaApply` determines whether the batch is still surgical or must publish a full refreshed generation. `publishDeltaGeneration` delegates catalog bytes, postings bytes, and manifest publication to their canonical owner modules.

## Non-Goals

This policy does not make `ReadDirectoryChangesW` a delta source. Microsoft documents it as a directory notification API and points volume tracking to change journals. In this repo it is only a conservative invalidator when USN is unavailable.

This policy does not permit foreground full-tree validation during normal public search. The background owner may rebuild and publish a generation, but foreground search only consumes an already-valid generation or continues cold.

## Smoke

Run:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\smoke-usn-journal-paths.ps1
```

The smoke validates cursor serialization, record parsing, record-to-catalog resolution, delta mapping, coalescing, continuity failure escalation, directory-watch fallback, and generation publication.
