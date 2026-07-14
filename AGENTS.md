# IX-Zig Engineering Directives

## Identity

IX is a search engine that operates at the register-instruction-cache boundary. Not the API boundary. Not the library boundary. The point where a `VPCMPEQB` fuses with the subsequent `TEST`/`JNZ` in the decoder, where a store-to-load forwarding path either stalls or succeeds based on 32-byte alignment, where a single TLB miss on an arena page walk costs more than an entire 64-byte cache line scan.

This is not a wrapper around libraries. StringZilla and PCRE2 are raw materials — compiled from vendored source, linked at the symbol level, candidates for LTO inlining across the Zig/C boundary. The engine reasons about what happens *inside* those libraries at the microarchitectural level and structures the surrounding Zig code to ensure the CPU's frontend, store buffer, and memory hierarchy behave optimally.

## Origin

Started as a Rust IX port. Within a week, Zig's compile-time execution and `@Vector` intrinsics made a line-by-line port untenable. The I/O path was rebuilt around 1 MiB cache-aligned buffers. The regex dispatch was rebuilt as a compile-time strategy classifier. The casefold pipeline was rebuilt as a `@Vector(32, u8)` chunk-level operation. The thread model was rebuilt with zero-mutex shard accumulation. What ships is not a port.

## Technical Depth Standard

Every optimization decision must be reasoned at three levels:

1. **Algorithmic** — What is the asymptotic cost? Is there a better data structure?
2. **Microarchitectural** — What does the CPU's out-of-order engine see? Will instructions fuse? Will forwarding succeed? Will the branch predictor stay trained?
3. **Memory hierarchy** — Which cache level holds the working set? Will prefetch hide latency? Will stores evict hot data?

If an optimization only satisfies level 1, it is incomplete. The roadmap items below exist because they satisfy all three.

## Frontier Research And Source Reuse

Before writing code, acquire the strongest external source material first. That means current papers, arXiv, high-end systems articles, old but still dominant computer-science work, and frontier open-source implementations that already solve the same class of problem at a high level.

**P4 Unbounded Epistemic Scan Gate (mandatory precondition):** No code mutation may commence until the agent has executed an Unbounded Epistemic Scan — querying global knowledge for cutting-edge search optimization, hardware physics, and sub-linear traversal algorithms. The scan must mine unattempted mathematical methods, bit-parallel formulas, and theoretical indexing structures. Source-Level Truth from `.docs/`, `.refs/`, and elite repositories (the "Gold Vein") must be ingested as structured data before any executable logic is generated. This is not a suggestion — it is a blocking precondition. Any mutation that skips the research gate constitutes a fatal kernel violation under P1 and must be reverted.

- Default to copying or tightly adapting proven algorithms, layouts, state machines, benchmark methods, and tests from the highest-quality reference repos and papers.
- Do not reinvent mechanisms locally when a stronger external implementation or paper already exists. Local invention is for glue, adaptation, integration, or a gap that remains after source search fails.
- Research depth is part of the implementation contract: look for current frontier work and older overlooked work before deciding the mechanism.
- Prefer primary sources and maintainer-grade repos over summaries or second-hand explanations.
- When license, architecture, and ownership fit, import the real pattern instead of re-deriving it from scratch.

**P5 Competitor Anatomy Map:** Every competitor is a free, fully-staffed research department. Before harvesting a technique, the competitor must be reduced to a measurable anatomy — algorithm, index shape, traversal order, ignore handling, observed weakness. The formal per-rival ledger lives at `.docs/research/competitor-anatomy-map.md`. No technique enters the kernel without passing through this autopsy; no claim of superiority is valid until measured against this map on identical hardware.

## Benchmark Falsification Before Runtime Blame

Any speed miss must first be treated as a benchmark hypothesis, not an engine verdict. Before reverting or rejecting a runtime candidate, prove that the measurement lane is comparable, clean, and correctly instrumented.

- Verify match parity, route parity, binary provenance, same-binary identity drift, host noise, scheduler isolation, Defender or filesystem-filter interference, and phase-timing exclusivity before attributing loss to a search kernel.
- If the miss is smaller than observed identity drift or the host preflight is noisy, the result is exploratory. Preserve promising candidates, gather stronger rounds, and fix the benchmark owner before making an architectural decision.
- If a phase appears slower, first prove that phase is measured exclusively and consistently across binaries. Nested or double-counted timing cannot drive repair targets.
- Compare only against the single hardest valid predecessor lane for retained historical proof. Invalid rows with match or route mismatch cannot select the predecessor and cannot drive phase attribution.
- A route-local win plus a small whole-engine loss is a salvage problem, not a revert command. Preserve the gain, isolate the losing owner, and widen sample depth under a cleaner envelope.

## Architecture

```
argv → parse → classify → discover → shard → scan → merge → output
```

- **Strategy classification at parse time** — query shape determines execution path before any file is opened
- **1 MiB chunk I/O** — sized for L2/L3 residency; StringZilla SIMD operates on warm cache lines
- **Thread-local ShardReport** — zero mutex, zero atomic, zero contention on the hot path
- **Arena allocation** — one region, process lifetime, zero individual frees
- **Compile-time SIMD backend** — `-mavx2` at build, no runtime dispatch, no `cpuid`, no DllMain

## Key Files

| File | Role |
|------|------|
| `src/core/search.zig` | Scan pipeline — discover, shard, scan, merge. Hot loop lives here. |
| `src/core/expr.zig` | Expression parser + 11-variant `MatcherStrategy` classifier |
| `src/core/pcre_regex.zig` | PCRE2 JIT wrapper, threadlocal compile cache |
| `src/core/regex.zig` | Zig-native recursive backtracking fallback |
| `src/core/trigram.zig` | 3-byte evidence extraction and admission gates |
| `src/core/sz.zig` | StringZilla Zig bindings (thin FFI) |
| `src/sz_shim.c` | C shim forcing symbol emission from header-only StringZilla |
| `src/core/stats.zig` | Telemetry model |
| `src/core/inspect.zig` | Bounded file windows, agent pagination |
| `src/core/corpus.zig` | Proof-program compilation for `explain` |
| `src/cli/args.zig` | Argument parsing, ripgrep compat lowering |
| `src/cli/output.zig` | JSON, text, sentinels |
| `build.zig` | Build config — PCRE2 from source (27 TUs), StringZilla with `-mavx2` |

## Vendored Dependencies

| Dependency | Location | Build |
|------------|----------|-------|
| StringZilla v4.6.0 | `.refs/stringzilla/include/` | Header-only → C shim → `-mavx2 -O3` |
| PCRE2 10.44 | `.refs/pcre2/src/` | 27 translation units, `SUPPORT_JIT=1`, sljit backend |

Zero external packages. Zero network fetches. Everything compiles from source via `zig build`.

## Optimization Invariants

These are non-negotiable constraints on the hot path:

1. **No mutex in the scan loop** — ShardReport is thread-local. Merge happens after join.
2. **No allocation in the scan loop** — Arena from init. Carry buffer is the only dynamic allocation, and it is amortized.
3. **Stack frames < 4 KiB on hot path** — Avoids Windows `__chkstk` page probes across 100k+ line iterations. Casefold buffers (2 KiB + 256 B) isolated into separate functions.
4. **Single syscall per small file** — `readPositional` for first chunk, not `readPositionalAll`. File length deferred until chunk overflows.
5. **Compile-time SIMD selection** — `SZ_DYNAMIC_DISPATCH=0`. No runtime feature detection. No function pointer table.
6. **Strategy classification before I/O** — The query shape determines the execution path at parse time, not inside the scan loop.

## Roadmap Execution Tiers

### Tier 0: Execution Core (Now)

- Aho-Corasick automaton for literal alternates — single-pass instead of N independent scans
- Multi-chunk whole-buffer fast count — boundary-aware match accumulation without line splitting
- Boyer-Moore-Horspool shift table for case-insensitive — memchr2 anchor, skip full-line casefold copy
- Loser tree (tournament) merge for shard results — 64-byte aligned struct-of-arrays, branchless CMOV selection, sentinel keys for empty shards, O(log K) per pop (ref: TigerBeetle `k_way_merge.zig`)
- CLMUL structural boundary detection — `VPCLMULQDQ` propagates delimiter parity across 64 bytes in one instruction, enables structure-aware search without per-byte state machine (ref: zimdjson `indexer.zig`)

### Tier 1: Zero-Copy I/O Architecture

- VM double-mapped ring buffer via `VirtualAlloc2` / `mmap` — same physical pages mapped twice contiguously, boundary-free SIMD scan, carry buffer eliminated
- `io_uring` SQ polling with `IORING_OP_READ_FIXED` + pre-registered page-aligned buffers — thread-local instances (lazy init), zero cross-thread contention on SQ/CQ, async pipeline overlapping read N+1 with scan N (ref: sig-main `buffer_pool.zig`)
- IOCP with `FILE_FLAG_NO_BUFFERING` — Windows equivalent, sector-aligned direct reads bypassing filesystem cache
- Deferred batch I/O completion — queue all CQE/IOCP completions into stack-allocated flat array before invoking scan callbacks, bounded O(1) stack depth, prevents callback recursion (ref: TigerBeetle `io/linux.zig`)
- SPSC lock-free ring buffer for I/O→scan handoff — cache-line padded producer/consumer cursors, power-of-two masking, local cursor caches batch-amortize atomic loads, enables true async I/O pipelining (ref: buzz `spsc_queue.zig`)
- Futex-based scan worker parking — `FUTEX_WAIT`/`WaitOnAddress`/`__ulock_wait` parks scan worker at zero CPU when SPSC ring drains, ~200 ns wake, single u32 futex word, `@branchHint(.cold)` on wait path (ref: Cubyz `Futex.zig`)

### Tier 2: Memory Hierarchy Control

- Software prefetch (`@prefetch`) scheduling — prefetch chunk N+1 during scan of chunk N, hide L2→L1 latency behind compute
- Non-temporal stores (`_mm256_stream_si256`) for result buffers — prevent SearchHit writes from evicting hot scan data from L1/L2
- Huge page arena — `MAP_HUGETLB` / `MEM_LARGE_PAGES` for 2 MiB TLB entries, eliminate page-walk overhead on arena regions
- NUMA-aware thread pinning — `sched_setaffinity` / `SetThreadAffinityMask` + NUMA-local buffer allocation via `mbind` / `VirtualAllocExNuma`
- Slab node pool with hardware CTZ freelist — contiguous aligned buffer, `DynamicBitSetUnmanaged` tracking, `TZCNT`-based O(1) acquire, bulk deallocation via `memset` (ref: TigerBeetle `lsm/node_pool.zig`)
- Lazy proof-positive SIMD scan — two-pass: `@reduce(.Max, chunk == target)` dismisses match-free chunks in ~1 cycle/32 bytes, second pass runs only on positive chunks (ref: bun `escapeHTML.zig`)
- Set-associative cache with packed SoA tag arrays — separate cache-line-aligned tag/value arrays, 16-way × 8-bit tags in one cache line, CLOCK Nth-chance eviction, zero value-array touches on miss, for file metadata and posting-list fragment caching (ref: TigerBeetle `lsm/set_associative_cache.zig`)

### Tier 3: Compile-Time Codegen

- `comptime` strategy specialization — monomorphized scan function per `MatcherStrategy` variant, function pointer selected once at parse time, zero branch overhead in inner loop
- LTO across Zig/C boundary — `want_lto = true` on C source steps, inline StringZilla AVX2 intrinsics into Zig scan loop, eliminate call overhead at the Zig/C seam
- Compile-time DFA table generation — bake transition tables for fixed-vocabulary regex patterns into read-only binary sections, tight `state = table[state][byte]` execution, no interpretation
- `callconv(.@"inline")` on hot-path callback parameters — force-inline key extraction / comparison functions passed to generic algorithms, eliminates indirect call overhead entirely, callee spliced into caller's decode window (ref: TigerBeetle `lsm/binary_search.zig`)
- Comptime ASCII classification bitset — 256-byte table, 8 bit-packed categories per byte, single indexed load + AND-mask at runtime, replaces branch chains in binary sniff / word-boundary / regex fallback (ref: gotta-go-fast `ascii.zig`)

### Tier 4: Algorithmic Frontier

- SIMD-accelerated Aho-Corasick — flatten state transition table to 256-wide array per state, broadcast input byte across 32 YMM lanes, gather from transition table, 32 automaton steps per cycle
- Elias-Fano encoded posting lists — quasi-succinct representation (~2 bits/element beyond information-theoretic minimum), `select` + `advance` intersection without full decoding
- Rabin-Karp rolling hash for chunk boundary matching — detect cross-boundary candidates without reassembling lines, hash collision → verify, eliminates carry buffer for stats-only counting
- Bitap (Baeza-Yates–Gonnet) for fuzzy search — pattern as bitmask, one OR+SHIFT per byte, `@Vector(4, u64)` processes 4 positions simultaneously, edit distance 1 at near-literal speed
- EWAH bitmap compression for dense posting lists — word-aligned hybrid encoding (literal + marker words), 64x compression on sparse bitmaps, intersection operates on compressed words directly, adaptive selection per trigram density (ref: TigerBeetle `ewah.zig`)
- Prefetch-scheduled binary search for posting lists — two-position `@prefetch` at quarter/three-quarter range before comparison, hides L2→L1 latency behind branch resolution, `locality=0` for single-visit data (ref: TigerBeetle `lsm/binary_search.zig`)

### Tier 5: Microarchitectural Exploitation

- AVX-512 VBMI2 `VPCOMPRESSB` match extraction — hardware-gather matching byte positions into dense output, eliminate scalar `TZCNT` extraction loop
- μop fusion-aware loop structuring — guarantee `TEST`/`JNZ` fusion in decoder by preventing flag-clobbering instructions between comparison and branch, Zig-native `@Vector` + `@reduce` path
- Store-to-load forwarding alignment — `@alignCast(32, ...)` on casefold buffers to guarantee 32-byte forwarding success, avoid 12-cycle stall on alignment miss
- `@setCold()` on error/fallback paths — keep hot scan code in L1i, push cold code to distant addresses
- Hardware PMU profiling via `perf_event_open` — instrument hot loop with `CACHE_MISSES`, `BRANCH_MISSES`, `INSTRUCTIONS` counters, `rdpmc` for cycle-accurate reads without kernel transition (ref: gotta-go-fast benchmark infrastructure)
- Visited-bitset regex deduplication — 16 KiB bitset indexed by `(ip × input_len + pos)`, single `BT` instruction check, bounds backtracking to O(pattern_len × input_len) polynomial (ref: zig-regex `vm_backtrack.zig`)

### Tier 6: Persistent Index Architecture

- Succinct rank/select bitvectors — O(1) `rank(i)` and `select(k)` via precomputed superblock tables, posting-list intersection without binary search
- Cache-oblivious Van Emde Boas B-tree layout — recursive subtree placement optimal for any cache line size, `O(log_B N)` cache misses regardless of hardware geometry
- Persistent trigram corpus epoch — durable file index, mmap-backed checkpoints, adaptive posting-list representations (dense bitset / Roaring / Elias-Fano / inline singleton by evidence density)
- Cuckoo filter for O(1) trigram admission — 16-bit fingerprint, 2 bucket lookups with comptime-unrolled scan, supports deletion for incremental re-indexing, ~0.012% FP rate at 4 bytes/element (ref: redis-cuckoofilter `zig-cuckoofilter.zig`)
- Segmented array (unrolled linked list) for mutable posting lists — fixed-capacity nodes backed by slab pool, O(node_capacity) insert/delete vs O(n) for flat arrays, split/join on overflow/underflow, serialized to compressed form at checkpoint (ref: TigerBeetle `lsm/segmented_array.zig`)

### Tier 7: OS Kernel Bypass

- Direct NVMe submission via `ioctl` / `io_uring` passthrough — bypass VFS + page cache, query `FIEMAP` / `FSCTL_GET_RETRIEVAL_POINTERS` for physical block addresses, submit direct read commands to block device
- Custom thread stacks — 64 KiB stacks for scan workers (default 1-8 MiB is wasteful), reduce virtual address space and page table pressure
- Process CPU affinity boost — elevate scan-phase priority, pin workers to physical cores (not hyperthreads), eliminate cross-core migration overhead

## Code Standards

- **Zig 0.16.0+** — uses `@Vector`, `@prefetch`, `@atomicRmw`, `@cImport`
- **C11** — StringZilla shim, potential future intrinsic kernels
- **No external packages** — everything vendored and compiled from source
- **Arena allocation** — no individual frees, no deallocation in hot path
- **Thread-local accumulation** — ShardReport per thread, merge after join
- **Explicit I/O** — `std.Io` threaded through all functions, no global state
- **Strategy-first dispatch** — classify at parse time, not at match time

## What Not To Do

- Do not add runtime SIMD dispatch. Compile-time only.
- Do not add mutex or atomic operations to the scan hot path.
- Do not allocate per-line in the scan loop.
- Do not import external Zig packages. Vendor and compile from source.
- Do not wrap functionality in layers of abstraction. The hot path should be readable as a flat sequence of operations.
- Do not compare IX to other tools in documentation or code comments. IX presents itself.
- Do not use language that sounds like prompt output. Technical voice only. Dense. Precise. No filler.

## Documentation

- **README.md** — product presentation, architecture overview, roadmap
- **Source comments** — WHY decisions, not WHAT the code does (the code says what)
- **`explain` command** — surfaces the proof program for any query at runtime
- **Roadmap** — tiered by depth: execution core → I/O architecture → memory hierarchy → codegen → algorithms → microarchitecture → persistent index → kernel bypass

## Fisheye Preview

Match previews use a fisheye lens (Furnas 1986, *Generalized Fisheye Views*). The match is the focus point; context window contracts geometrically as line length grows. Line length acts as the *a priori* importance prior — longer lines skew toward minified/generated content with lower marginal information density.

- T0 (≤ 300 bytes): full line — normal source code, zero overhead
- T1 (301–600): 150-byte half-width around match
- T2 (601–1200): 75-byte half-width
- T3 (> 1200): 37-byte half-width — up to 143× output reduction on minified content

The match substring is always fully visible. Elision boundaries marked with `…` (U+2026). If the match is wider than `2 × half_width`, the window expands to contain it.

This is an output-stage optimization, not a scan-stage optimization. It does not affect match parity, scan time, or admission. It reduces memory allocation and output size for hit records on long-line corpora.

## Agent Format (ix.result.v2)

`--agent` emits a compact, file-grouped output format designed for LLM agent consumption. The standard `ix.result.v1` sentinel and `--json` format waste tokens on three fronts: path repetition (same file path per hit), derived fields (`absolute_path` per hit), and telemetry bloat (2KB of mostly-zero stats).

### Design

- **File-grouped hits** — hits are keyed by file path in a JSON object. Path appears once per file, not once per hit.
- **Short field names** — `l` (line), `c` (column), `p` (preview). Minimizes per-hit token overhead.
- **No `absolute_path`** — `cwd` emitted once at top level. Agent reconstructs if needed.
- **Minimal telemetry** — only `matches`, `files`, `ms`, `status`, `expr`. Full telemetry available via `--json --stats`.
- **Zero-elision** — `access_errors`, `skipped`, `truncated` omitted when zero/false.
- **Fisheye integrated** — previews use the existing fisheye contraction.

### Token economy

For 72 hits across 29 files: `--json` = 26,671 bytes, `--agent` = 6,370 bytes. **4.2× reduction.**

This is an output-stage optimization. It does not affect match parity, scan time, or admission.
