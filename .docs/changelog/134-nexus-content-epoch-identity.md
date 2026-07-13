# Nexus Content-Epoch Identity

Date: 2026-05-11

## Summary

Added non-blocking content-epoch identity to the hidden Nexus evidence frontier without charging foreground searches for a full-tree metadata walk.

The attempted exact foreground validator was rejected by measurement: statting every discovered file before cache admission made the evidence-hot profile slower than the cold scan on Windows. The retained architecture keeps the foreground layer invisible: the sidecar records content identity, foreground reuse validates the expression/root/path-set contract, and successful evidence-pruned reuse does not spawn another writer immediately.

## Implementation

- `src/core/search.zig`
  - Upgraded cache magic to `IXEVIDENCE2`.
  - Added `content_signature=` to `.ix-evidence-{key}.cache`.
  - Computes the write-side content epoch from `path`, `size`, `inode` / Windows file index, and `mtime` after shard merge.
  - Keeps foreground cache admission free of full-tree stat validation.
- `src/main.zig`
  - Added `shouldLaunchNexusSidecar`.
  - Skips redundant sidecar launch when the foreground report already reused an evidence frontier and pruned files.

## Measurement

Profile:

```text
expression: re:\bPM_RESUME\b
corpus: E:\Workspaces\01_Projects\01_Github\iEx\.refs\ripgrep\benchsuite\linux
samples: 9
baseline commit: 51f8b3b
report: .docs/reports/content-epoch-postchange-2026-05-11.json
```

Before this slice, committed baseline:

```text
Cold foreground + sidecar:
  average wall: 672.0882 ms
  median wall: 666.4609 ms
  median total: 654.6509 ms

Evidence-hot:
  average wall: 203.0736 ms
  median wall: 203.6417 ms
  median total: 194.5817 ms
  median scan: 8.1764 ms
  evidence-pruned files: 79041
```

After this slice:

```text
Cold foreground + sidecar:
  average wall: 677.1841 ms
  median wall: 680.6401 ms
  median total: 671.4816 ms
  median scan: 506.6930 ms

Evidence-hot:
  average wall: 165.0266 ms
  median wall: 164.1002 ms
  median total: 157.1446 ms
  median scan: 7.0478 ms
  evidence-pruned files: 79041
```

Interpretation:

```text
hot median wall delta: -39.5415 ms
hot average wall delta: -38.0470 ms
hot median scan delta: -1.1286 ms
cold path: no intentional hot-path change; measured inside prior noise band
```

## Boundary

`content_signature` is artifact identity, not a foreground freshness proof. Exact mutable-tree freshness must be implemented as a sidecar-owned epoch source, preferably an NTFS USN journal cursor on Windows and platform-specific journal/checkpoint owners elsewhere. A foreground full-tree stat pass is disqualified for this architecture because it is visible latency.
