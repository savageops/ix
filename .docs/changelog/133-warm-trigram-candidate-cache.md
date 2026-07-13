# Nexus Evidence-Frontier Sidecar

Date: 2026-05-11

## Summary

Corrected the foreground cache drift into the first Zig-side invisible evidence-frontier sidecar. Public `search` / `matches` never synchronously build the artifact; they only spawn a hidden `__ix_nexus` worker after their foreground report is computed. The sidecar is stats-only, silent, native-detached on Windows, and writes the candidate frontier in the background.

## Pipeline

```text
Public cold query
  └─ discover files
  └─ scan normally through the parallel shard engine
  └─ emit normal result
  └─ spawn __ix_nexus sidecar and return

Hidden sidecar
  └─ discover files
  └─ scan normally through the parallel shard engine
      ├─ record candidate files that survive mandatory-needle/trigram gates
      ├─ record pruned/skipped counters thread-locally
      └─ write .ix-evidence-{key}.cache after shard merge

Public later query
  └─ discover files
  └─ validate expression/root/path-set key
  └─ replace scan input with cached candidate frontier
  └─ scan candidates through the existing verifier
```

## Implementation

- `src/core/search.zig`
  - Added `EvidenceFrontierCache`, `EvidenceFrontierRuntime`, and `EvidenceFrontierPrepared`.
  - Added path-set keyed `.ix-evidence-{key}.cache` load/write.
  - Upgraded the artifact format to `IXEVIDENCE2` with a write-side content epoch over `path + size + inode/file-index + mtime`.
  - Added shard-local evidence capture fields to `ShardReport`.
  - Added `recordEvidenceCandidate`, `recordEvidencePruned`, and `recordEvidenceSkipped`.
  - Wired evidence reuse before worker scheduling.
  - Writes the frontier only when `SearchRequest.nexus_build` is true.
- `src/cli/args.zig`
  - Added hidden `__ix_nexus` parsing and `SearchRequest.nexus_build`.
  - Forced sidecar requests to `--stats-only --json` semantics without exposing a public mode.
- `src/main.zig`
  - Added `launchNexusSidecar`.
  - Public `search` / `matches` launch the sidecar after the foreground engine report is available.
  - Successful evidence-pruned foreground reuse skips redundant sidecar rebuilds so hot queries do not race their own background writer.
  - Sidecar standard streams are ignored.
  - Windows sidecar launch uses native `CreateProcessW` with `DETACHED_PROCESS`, `CREATE_NEW_PROCESS_GROUP`, `CREATE_NO_WINDOW`, and immediate process/thread handle close.

## Measurement

Profile:

```text
expression: re:\bPM_RESUME\b
corpus: E:\Workspaces\01_Projects\01_Github\iEx\.refs\ripgrep\benchsuite\linux
mode: --json --stats-only
```

Results:

```text
Current foreground cold + sidecar spawn:
  median wall: 626.9509 ms
  median total: 616.5599 ms
  median scan: 459.9087 ms
  evidence-pruned files: 0

Current evidence-hot:
  median wall: 189.9459 ms
  median total: 181.4790 ms
  median scan: 7.6543 ms
  evidence-pruned files: 79041

Prior promoted Zig:
  median wall: 734.5797 ms
  median total: 727.5432 ms
  median scan: 577.2752 ms

Rust IX direct:
  median wall: 643.2430 ms
  median total: 625.0220 ms
```

## Boundary

This frontier validates the discovered path set and records a write-side content epoch. It is intended for stable benchmark/reference corpora. Foreground full-tree metadata validation was tested and rejected because it turns the hidden layer into a blocking stat walk. Mutable trees require deleting `.ix-evidence-*.cache` after content edits until the next slice adds content freshness through NTFS USN journal state or a checkpoint owner that can validate without foreground cost.
