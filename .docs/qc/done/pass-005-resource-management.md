---
id: pass-005-resource-management
type: qc
category: performance
status: complete
date: 2026-07-13
severity: high
discovered_by: "x3 deep, x4 adversarial, x5 architectural, x20 forensic (convergent finding)"
prior: pass-002-agent-output-contract
---

# QC Pass 005 — Resource Management Defects

Four independently-discovered resource management issues, all in the output/inspect path. Found convergently by 4 of 5 agents.

## R1. Byte-budget binary search re-reads source files O(log N) times

**Found by:** x5 (A1), x3 (3a), x4 (H1), x20 (M2) — independent convergence

**File:** `main.zig:341-375` (`writeVersionedSearchResult`), `main.zig:378-382` (`versionedSearchResultLength`), `main.zig:394-405` (`renderVersionedSearchResult`)

**Defect:** The binary search for the byte-budget-fitting page calls `versionedSearchResultLength` up to ~12 times (log₂4096). Each call:
1. Allocates a fresh `ArenaAllocator`
2. Calls `renderVersionedSearchResult` which fully renders the JSON envelope
3. When `--context N` is set, calls `inspect.contextReportsFromSearchReport` (line 396-397), which **re-opens and re-reads source files** from disk

For `--context 3 --max-bytes 4096` with hits in 5 files: 12 probes × 5 files = 60 file opens and reads of identical content. At Windows ~10 µs per file open, this is ~0.6 ms of pure re-read overhead on top of the actual scan.

**Fix:** Pre-compute context reports once for the full hit set (before the binary search). In each binary search iteration, only re-serialize the already-computed context for the visible subset. Or: measure the byte length in two phases — first binary-search the hit payload without context (cheap arena render), then append context for the final visible count only.

## R2. `inspect.zig` `allocRemaining` with 1 GiB limit — unbounded memory amplifier

**Found by:** x3 (3b), x4 (S2), pass-002 (N3)

**File:** `inspect.zig:77,157,220` — three call sites

**Defect:** All three inspect paths use `reader.interface.allocRemaining(allocator, .limited(1024 * 1024 * 1024))`. The 1 GiB limit is per-file. `inspect` accepts up to `MAX_SEARCH_PATHS = 128` paths. `contextReportsFromSearchReport` re-opens files once per distinct hit-path.

Combined with R1 (binary search re-reads), the worst case for `search --context N --max-bytes M` with hits in many files is: 12 binary search probes × N files × up to 1 GiB each. Arena allocation means no per-probe free — peak memory can reach gigabytes.

**Fix:** Cap `allocRemaining` at 16 MiB for context extraction. For `inspect --range`, use streaming line iteration (the `read_buffer[8192]` already exists but is discarded in favor of `allocRemaining`). For `contextForSearchHitsPath`, it already knows `last_needed = hits[hits.len-1].line + after` — it should stop reading at that byte offset, not slurp the whole file.

## R3. `SearchReport` (~321 KB) passed by value through 20+ function signatures

**Found by:** x20 (H2), x5 (A2 context)

**File:** All functions in `main.zig`, `output.zig`, `agent_output.zig` that take `report: search.SearchReport`

**Defect:** `SearchReport` contains `hits: [4096]SearchHit`. Each `SearchHit` is ~80 bytes. Total struct size: ~321 KB. It is passed by value in 20+ signatures. In the `--max-bytes` binary search path, this means ~12 copies of 321 KB = ~3.9 MB of memcpy per search, plus copies inside `renderVersionedSearchResult` (`visible_report = report`) and `agent_output.render`.

**Fix:** Change all `report: search.SearchReport` parameters to `report: *const search.SearchReport`. This is a mechanical refactor — the functions only read the report, never mutate it.

## R4. `MAX_RETAINED_HITS = 4096` inline array — 393 KB per ShardReport, no per-request tuning

**Found by:** x5 (A2)

**File:** `search.zig:82`, `search.zig:187` (SearchReport), `search.zig:2742` (ShardReport)

**Defect:** The inline `hits: [4096]SearchHit` array costs ~321 KB per instance. The engine allocates `actual_threads` shards (`search.zig:4143`: `allocator.alloc(ShardReport, actual_threads)`). At 16 threads: ~5.1 MB pre-allocated hit storage, regardless of whether the query matches 5 lines or 5000. An agent passing `--max-hits 20` still pays for 4096 slots in every shard.

**Fix:** Shard hit storage should be heap-allocated and sized to `@min(request.max_hits orelse MAX_RETAINED_HITS, MAX_RETAINED_HITS)`. Use a small-buffer-optimization pattern (64 hits inline, heap for larger) to avoid allocation overhead for small queries.

## Severity Justification

- **R1** is HIGH for agent workflows combining `--context` + `--max-bytes` (the documented v3 pattern)
- **R2** is HIGH for any inspect/search-context call against large files
- **R3** is MEDIUM — 3.9 MB of memcpy adds ~1-3 ms per search, not critical but wasteful
- **R4** is MEDIUM — 5.1 MB pre-allocation is not a leak but wastes cache and memory on small queries

R1 and R2 interact multiplicatively: the binary search amplification (R1) multiplies the per-file memory cost (R2). Together they can produce gigabyte-scale memory amplification for `--context --max-bytes` searches against large-file corpora.
