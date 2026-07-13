# Warm Index README Sync

Date: 2026-05-12

## Summary

Updated the public README to reflect the current post-`8f32a12` architecture: live warm-index query reuse, generation-pinned catalog/postings, USN delta substrate, compaction hardening, and protected cold-path repair.

## README Updates

- Promoted warm query-frontier reuse into the headline capability list.
- Added a warm-index architecture paragraph under "What It Is".
- Replaced stale "substrate only" descriptions for `FileCatalog`, trigram postings, generation refresh, and compaction with current foreground-adoption semantics.
- Added explicit rows for:
  - `Warm query frontier`
  - `USN delta substrate`
  - `Protected cold path`
- Added scan-path bullets for:
  - `4 KiB` prefix probe
  - protected-root admission
- Added the current warm-index benchmark narrative:
  - Rust Linux median wall: `736.305 ms`
  - Zig warm final-hot wall: `31.7333 ms`
  - Zig warm final-hot engine total: `19.5706 ms`
  - `discover_ms=0`
  - `matches=9`
  - `pruned=79031`
  - `verified=1`
  - warm speedup: `37.6x` by engine time, `23.8x` by wall time
- Added the `8f32a12` protected cold-path retention grid for source, Linux, subtitle, and `C:\Windows\System32` lanes.
- Updated source layout to include `catalog.zig`, `generation.zig`, `indexd.zig`, `postings.zig`, and `usn.zig`.

## Boundary

The README now emphasizes the strongest current truth: raw stateless foreground is still a comparator lane, but the warm indexed/reused path has become a distinct retained-corpus architecture that can make full-corpus search disappear behind a generation-pinned candidate frontier.
