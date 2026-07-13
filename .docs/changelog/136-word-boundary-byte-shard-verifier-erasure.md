# Word-Boundary Byte-Shard Verifier Erasure

Date: 2026-05-11

## Summary

Added a cold-lane byte-sharded stats-only path for `re:\bLITERAL\b` queries.

The retained slice lowers `regex_word_boundary_literal` plans into a Zig-owned `ByteShardPlan.word_boundary_literal` descriptor for large mmap-backed files. This erases the materialized line verifier for the supported class while preserving exact word-boundary and logical-line count semantics.

## Implementation

- `src/core/expr.zig`
  - Enables outer parallel shard fast-count eligibility for `regex_word_boundary_literal`.
  - Keeps ASCII casefold word-boundary regexes disabled until a casefold-safe byte kernel exists.
- `src/core/search.zig`
  - Replaces the raw byte-shard needle helper with a richer byte-shard descriptor.
  - Adds `literal_occurrence` and `word_boundary_literal` strategies.
  - Uses overlap ownership for literal occurrence counts.
  - Uses newline-owned logical ranges for word-boundary line counts.
  - Adds `countWordBoundaryLiteralLogicalLinesRange`.
  - Runs the word-boundary byte-shard path before file-admission for stats-only mmap-backed large files.
  - Measures actual byte-shard worker elapsed time instead of reporting zero.
- `src/core/stats.zig`
  - Adds byte-shard telemetry for strategy, line-aligned ranges, and boundary candidate verification/rejection.
- `src/cli/output.zig`
  - Emits the expanded `stats.byte_shard_kernel` fields in JSON output.

## Semantics

```text
re:\bLITERAL\b
  -> regex_word_boundary_literal
  -> ByteShardPlan.word_boundary_literal
  -> newline-owned byte ranges
  -> simd.indexOf candidate scan
  -> wordBoundaryLiteralAt boundary verifier
  -> count at most one match per owned logical line
```

Fallback is mandatory when a shard cannot prove newline ownership inside the bounded boundary-search window. The fallback preserves the existing materialized verifier path rather than risking double-counted long logical lines.

## Measurement

Profile:

```text
expression: re:\bPM_RESUME\b
corpus: E:\Workspaces\01_Projects\01_Github\iEx\.refs\ripgrep\benchsuite\linux
mode: IX_NEXUS=0, --json --stats-only --threads 32
rounds: 7
```

Result:

```text
previous reference median wall: 637.615 ms
current median wall: 609.966 ms
delta: -27.649 ms (-4.34%)
matches: 9
files scanned: 79085
bytes scanned: 1340745076
execution_mode: byte_sharded
byte_shard_kernel.strategy: word_boundary_literal
byte_shard_kernel.files_profiled: 10
byte_shard_kernel.range_calls: 40
byte_shard_kernel.line_aligned_ranges: 40
```

Guard lanes:

```text
lit:Sherlock Holmes, en.sample.txt, --threads 8:
  previous reference median wall: 38.043 ms
  current median wall: 34.788 ms
  delta: -8.56%

lit:the, Linux corpus, --threads 32:
  current median wall: 613.823 ms
  matches: 1469971
```

## Validation

```text
zig build test
zig build -Doptimize=ReleaseFast
git diff --check
dupe-audit summary:
  target_file_count=4
  segment_count=89
  candidate_pair_count=2
  exact_duplicate_candidate_count=0
```

## Boundary

This is a retained cold-lane improvement, not a 10x class jump. It proves the algorithmic lane and descriptor contract. The remaining PM_RESUME wall time is dominated by discovery/open/admission and nested shard scheduling because the large sharded files are mostly negatives while the matching files are small. A C/AVX2 kernel is now admissible only beneath the same Zig-owned descriptor if timing proves candidate scan and ASCII boundary classification are the ceiling.
