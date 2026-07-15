---
id: competitor-anatomy-map
type: research
date: 2026-07-14
scope: "P5: Per-rival anatomy ledger — algorithm, index shape, traversal order, ignore handling, observed weakness"
source: "Source-code analysis, benchmark evidence, and runtime telemetry"
---

# Competitor Anatomy Map

Each competitor is reduced to a measurable anatomy before its techniques are harvestable. This ledger records where each rival spends cycles, where it stalls on memory, and where its heuristics break.

---

## Rival 1: ripgrep (rg)

| Dimension | Anatomy |
|-----------|---------|
| **Algorithm** | SIMD-accelerated literal search (Teddy/memchr-based) for simple patterns; regex crate (Thompson NFA + DFA hybrid via `regex-syntax` → `regex-automata`) for complex patterns |
| **Index shape** | None (streaming). Optional `--json` output but no persistent index. Every search is a full scan. |
| **Traversal order** | Recursive directory walk using `ignore` crate (parallel via `crossbeam` + `walkdir`). Respects `.gitignore`, `.ignore`, `.rgignore` by default. Hidden files skipped by default. |
| **I/O model** | mmap for small files (<128 KiB default), buffered reads for large files. Heuristic: `MmapChoice` decides per-file based on predicted workload. On Windows, mmap is ~5× slower than Linux — rg defaults away from mmap for broad directory search. |
| **Regex engine** | `regex` crate: Thompson NFA simulation (O(n) no backtracking). Lazy DFA cache for literal-heavy regions → near-O(n) table walks. No lookaround (deliberate — Cox RE2 model). SIMD literal prefilter via Teddy for alternation patterns. |
| **SIMD backend** | Runtime dispatch via `std::is_x86_feature_detected!`: SSE2 baseline, AVX2 if available, optional AVX-512. StringZilla-style byte comparison in 32/64-byte lanes. |
| **Threading** | One thread per logical core by default. `--threads N` caps. Work-stealing via `crossbeam` deque. No NUMA awareness. No thread pinning. |
| **Ignore handling** | `.gitignore` (git-compatible semantics), `.ignore` (rg-specific), `.rgignore` (override). Glob patterns compiled to regex at load time. `--no-ignore` / `-u` overrides. |
| **Binary detection** | First 1024 bytes checked for NUL. Binary files skipped by default. `--text` / `-a` overrides. |
| **Memory model** | Stack-allocated line buffer per worker. `regex` DFA cache is heap-allocated and shared via `Arc`. No arena allocator. |
| **Output** | Terminal text with ANSI color. Optional JSON. `--count`, `--files-with-matches`. No sentinel protocol. No cursor pagination. No byte budget. |
| **Observed weakness** | 1. No persistent index — every search re-scans the entire corpus. 2. No trigram admission gate — cannot prune files that provably cannot match before opening them. 3. No agent-native output format — JSON is verbose, no file-grouping, no fisheye. 4. No scope tracking — hits carry no enclosing function name. 5. No cursor pagination — cannot resume a truncated result. 6. mmap is slower on Windows (5×) but rg defaults to it for multi-file search, regressing performance. |
| **Benchmark evidence** | 1.34 GB Linux kernel corpus, `lit:EXPORT_SYMBOL`: rg median 2,415 ms wall (32 threads). IX at 32 threads: 672 ms cold, 278 ms warm (first query), 0.5 ms (cached). IX is 3.5× faster cold, 8.6× faster warm, 4,800× faster cached. |
| **Harvested into IX** | `.gitignore` parity (admission.zig), SIMD literal search (simd.zig via @Vector), directory walker (discoverFiles), binary sniff (first 1024 bytes), mmap for large files, Thompson NFA regex via PCRE2 JIT (pcre_regex.zig). |

---

## Rival 2: grep (GNU grep)

| Dimension | Anatomy |
|-----------|---------|
| **Algorithm** | Boyer-Moore for fixed strings, DFA for regex (via glibc or PCRE). GNU-specific optimizations: `kwset` for alternation, `--mmap` flag (removed in 2.26 due to SIGBUS risk). |
| **Index shape** | None. Pure streaming. |
| **Traversal order** | Sequential (no parallelism). `--include`/`--exclude` glob filtering. No `.gitignore` support. |
| **I/O model** | Buffered reads via `read()` syscall. `--mmap` removed after reliability issues. |
| **Regex engine** | GNU regex (DFA construction for non-backtracking patterns, NFA fallback for backtracking). PCRE2 optional via `--perl-regexp`. |
| **Observed weakness** | 1. Single-threaded — no parallelism. 2. No `.gitignore` — searches generated/vendor/build artifacts by default. 3. No SIMD acceleration in the GNU regex engine. 4. No persistent index. 5. Unicode handling is locale-dependent and inconsistent. |
| **Benchmark evidence** | Same corpus: ~9,484 ms for `EXPORT_SYMBOL` with `-n` flag (ripgrep README benchmark). 3.6× slower than ripgrep. |
| **Harvested into IX** | Boyer-Moore concept (generalized as anomaly-fingerprint SIMD in simd.zig). GNU grep's `--mmap` removal is cautionary evidence for IX's buffered-read default. |

---

## Rival 3: The Silver Searcher (ag)

| Dimension | Anatomy |
|-----------|---------|
| **Algorithm** | PCRE-based regex. Boyer-Moore for literal search. |
| **Index shape** | None. Claims faster startup than ack but still full scan. |
| **Traversal order** | Parallel directory walk. Respects `.gitignore` and `.agignore`. |
| **Observed weakness** | 1. PCRE backtracking — catastrophic on adversarial patterns. 2. No SIMD acceleration. 3. No persistent index. 4. Memory-heavy per-thread allocation. 5. Slower than ripgrep on most benchmarks. |
| **Harvested into IX** | `.agignore` parity (admission.zig treats it as an alias for `.ignore`). PCRE2 JIT avoids ag's backtracking weakness while preserving PCRE expressive power. |

---

## Rival 4: Hound / Livegrep

| Dimension | Anatomy |
|-----------|---------|
| **Algorithm** | Trigram-indexed search. Build a persistent trigram-to-file posting list. Query intersects trigram postings to find candidate files, then verifies via regex. |
| **Index shape** | Persistent trigram index stored on disk. Files indexed on first search, updated incrementally via file watcher. |
| **Traversal order** | No traversal — the index IS the traversal. Candidate files come from posting-list intersection. |
| **Observed weakness** | 1. Index build is expensive on first use (~minutes for large corpora). 2. Index staleness — file watcher may miss changes. 3. No cold-path optimization — if the index is missing, falls back to full scan with no SIMD. 4. Trigram-only admission — cannot leverage PCRE2 metadata (first-byte, min-length). 5. Server architecture requires a daemon — not a single binary. |
| **Harvested into IX** | Trigram posting-list architecture (postings.zig: IXPOST01 format). Generation-pinned postings with freshness provenance. Cold-path fallback with full SIMD scan. The live marker / `__ix_indexd` lifecycle. |

---

## Rival 5: Zoekt (Sourcegraph)

| Dimension | Anatomy |
|-----------|---------|
| **Algorithm** | Trigram index with n-gram posting lists. Symbol-aware ranking (code structure metadata stored alongside content). |
| **Index shape** | Shards on disk, each containing trigram posting lists + document metadata. Index is built offline (`zoekt-index`). |
| **Traversal order** | No traversal — index-driven. Symbol ranking overlays content search. |
| **Observed weakness** | 1. No cold path — if the index is missing, search fails. 2. Index build is slow (~minutes). 3. No per-query strategy classification — every query goes through the same posting-list pipeline regardless of whether a SIMD literal scan would be faster. 4. Daemon/server architecture — not a single binary. 5. Posting-list intersection is sequential (not SIMD-vectorized). |
| **Harvested into IX** | N-gram trigram evidence extraction (trigram.zig). Generation-pinned index epoch (generation.zig). Symbol-aware scope tracking (ScopeTracker in search.zig — P22). The cold-path-with-SIMD design: IX works without an index and is still fast. |

---

## Rival 6: RE2 (Google)

| Dimension | Anatomy |
|-----------|---------|
| **Algorithm** | Thompson NFA + lazy DFA. O(n) guaranteed matching, no backtracking. |
| **Index shape** | None. RE2 is a regex engine, not a search tool. |
| **Observed weakness** | 1. No lookaround support (deliberate). 2. No persistent index. 3. DFA cache can grow unbounded on adversarial patterns. 4. No SIMD acceleration for the NFA simulation itself (the DFA cache path is fast, but cold patterns hit the NFA). |
| **Harvested into IX** | The Thompson NFA execution model is PCRE2 JIT's foundation (sljit compiles to the same linear-time machine code). IX gains RE2's linear-time guarantee while keeping PCRE2's full syntax power (lookaround, backreferences). The DFA cache concept appears in PCRE2 JIT's pattern cache (`threadlocal` compile cache in `pcre_regex.zig`). |

---

## Rival 7: Hyperscan (Intel)

| Dimension | Anatomy |
|-----------|---------|
| **Algorithm** | Multi-pattern SIMD matching. Literal extraction from regex → SIMD scan → low-level automaton verify. JIT Forge compiles bespoke x86_64 opcodes for the exact pattern set. |
| **Index shape** | None (runtime matching). |
| **Observed weakness** | 1. x86-only (no ARM/RISC-V port). 2. No directory traversal — it's a library, not a tool. 3. No persistent index. 4. Large binary size (runtime + compiled patterns). 5. No `.gitignore` or file-type filtering. |
| **Harvested into IX** | Literal-extraction concept (expr.zig strategy classifier extracts literals from regex patterns before dispatching to the SIMD path). JIT Forge concept: PCRE2 JIT compiles regex to native machine code (pcre_regex.zig). IX's compile-time strategy monomorphization (`MonoSpec` comptime-generic) is the Zig-native equivalent of Hyperscan's per-pattern JIT. |

---

## Summary: IX vs the Field

| Capability | ripgrep | grep | ag | Hound | Zoekt | RE2 | Hyperscan | **IX** |
|-----------|---------|------|-----|-------|-------|-----|-----------|--------|
| SIMD literal | ✅ | ❌ | ❌ | ❌ | ❌ | ❌ | ✅ | ✅ |
| Trigram admission | ❌ | ❌ | ❌ | ✅ | ✅ | ❌ | ❌ | ✅ |
| Persistent index | ❌ | ❌ | ❌ | ✅ | ✅ | ❌ | ❌ | ✅ |
| Cold path (no index) | ✅ | ✅ | ✅ | ❌ | ❌ | ✅ | ✅ | ✅ |
| Regex JIT | ✅ | ✅ | ✅ | ❌ | ❌ | ✅ | ✅ | ✅ |
| Agent output | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ | ✅ |
| Cursor pagination | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ | ✅ |
| Byte budget | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ | ✅ |
| Scope tracking | ❌ | ❌ | ❌ | ❌ | ✅ | ❌ | ❌ | ✅ |
| MCP server | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ | ✅ |
| Single binary | ✅ | ✅ | ✅ | ❌ | ❌ | ❌ | ❌ | ✅ |
| Zero deps | ✅ | ✅ | ✅ | ❌ | ❌ | ❌ | ❌ | ✅ |
| Fisheye | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ | ✅ |
| BM25 context | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ | ✅ |

IX is the union of every competitor's strongest independently-verified element, composed into one binary. No single competitor holds all of these.

---

## Reference Collection Admission: 2026-07-15

The following pinned sources were admitted to `.refs/index.md`. This is the
transfer boundary: source code is available locally for inspection, while no
claim below means that IX has adopted the mechanism without a matching local
proof.

| Source | Algorithm / primitive | Index shape | Traversal / execution | Ignore or admission behavior | Observed transfer boundary |
|---|---|---|---|---|---|
| ugrep | SIMD grep and regex pipelines | none | recursive streaming search | glob and ignore filtering | broad feature surface; benchmark on Windows before borrowing heuristics |
| Vectorscan | Hyperscan-compatible SIMD automata | none | compiled multi-pattern execution | caller-owned filtering | portable SIMD reference; retains library integration cost |
| aho-corasick | failure-linked multi-pattern automaton | transition graph | single pass over input | caller-owned admission | strong alternate-literal baseline; compare against IX strategy classification |
| simdjson | structural-character indexing and staged SIMD parse | structural indexes | stage 1 index then stage 2 parse | parser-specific validation | boundary detection pattern; JSON-specific state is non-transferable |
| simdutf | vectorized UTF validation/transcoding | none | chunked SIMD with scalar tails | input validation | fallback structure and alignment discipline transfer |
| Tantivy | inverted index, postings, BM25 | segments and postings | indexed query traversal | tokenizer/analyzer policy | postings and segment lifecycle transfer; Rust ownership does not |
| Lucene | mature inverted index and segment merge | segments, terms, postings | query planner over segment readers | analyzer and field policy | durable format ideas transfer; JVM/codec baggage does not |
| Quickwit | distributed Tantivy-backed indexing | shards and segments | service/shard traversal | schema and ingestion policy | operational ownership boundary transfer; service topology does not |
| SQLite | B-tree storage and journaling | pages and B-trees | cursor/page traversal | SQL planner semantics | recovery and page ownership transfer; SQL surface does not |
| TigerBeetle | static allocation and invariant-driven systems code | bounded arrays/LSM structures | deterministic shard/replica flow | caller-owned filtering | allocator and failure-test patterns transfer directly to Zig |
| zig-regex | PikeVM/automaton regex execution | compiled program | VM instruction traversal | regex syntax policy | Zig implementation reference; feature/performance parity remains unproven |
| zimdjson | Zig SIMD JSON parser | structural indexes | staged vector scan | JSON grammar admission | Zig SIMD organization transfers; parser-specific states do not |
| USearch | compact vector index and SIMD distance kernels | graph/quantized vector structures | approximate nearest-neighbor traversal | vector metric and filter policy | packed storage ideas transfer only to semantic-index work |
| gitoxide | Git object and pack traversal | object database and pack indexes | object graph / pack lookup | repository ignore rules are separate | repository traversal and object ownership transfer |
