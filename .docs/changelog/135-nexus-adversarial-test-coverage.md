# Nexus Adversarial Test Coverage

Date: 2026-05-11

## Summary

Added adversarial coverage around the hidden Nexus evidence frontier and its command/sidecar contracts.

The tests target failure modes exposed by the content-epoch work: stale artifact formats, malformed cache headers, candidate-count drift, foreground admission accidentally turning into a metadata walk, redundant sidecar launch after hot reuse, and Windows argument quoting corruption.

## Coverage

- `src/cli/args.zig`
  - Hidden `__ix_nexus` parsing forces `stats_only`, `json`, and `nexus_build`.
  - Sidecar parsing preserves expression, root, hidden/follow flags, and thread count.
- `src/core/search.zig`
  - `IXEVIDENCE2` cache round-trip preserves key/signature/content identity and candidate membership.
  - Legacy `IXEVIDENCE1`, wrong file count, candidate count mismatch, and candidate-limit overflow are rejected.
  - `prepareEvidenceFrontier` narrows active files to cached candidates and accounts cached pruned/skipped counters.
  - `computeContentSignature` changes when file size mutates, proving the sidecar write-side epoch detects content-shape changes without foreground validation.
  - `search.run` consumes a prebuilt evidence frontier and scans only the retained candidate while preserving exact match output.
- `src/main.zig`
  - `shouldLaunchNexusSidecar` launches only when the foreground report did not already prune from evidence.
  - `appendWindowsCommandArg` preserves spaces, quotes, and trailing backslashes.

## Validation

```text
zig build test
zig build -Doptimize=ReleaseFast
dupe-audit summary:
  target_file_count=3
  segment_count=66
  candidate_pair_count=0
  exact_duplicate_candidate_count=0
```

## Boundary

This is test hardening only. It does not change the measured Nexus runtime path beyond executable test-only code. Runtime behavior remains the `a9c3956` nonblocking content-epoch slice.
