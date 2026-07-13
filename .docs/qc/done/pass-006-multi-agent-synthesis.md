---
id: pass-006-multi-agent-synthesis
type: qc
category: synthesis
status: complete
date: 2026-07-13
scope: "Consolidated findings from 6 independent review agents (x1, x2, x3, x4, x5, x20) plus pass-001 and pass-002"
agents_completed: 6
agents_pending: 0
---

# QC Pass 006 — Multi-Agent Synthesis

## Agent Inventory

| Agent | Effort | Focus | Runtime | Findings |
|-------|--------|-------|---------|----------|
| x1 | Lightning | Surface scan, compilation | 5 min | 0 critical, 0 high, 2 low, 5 done-right |
| x2 | Standard | Correctness, logic paths | 69 min | 0 critical, 0 high, 1 medium, 0 low, 12 done-right |
| x3 | Deep | Edge cases, invariants | 21 min | 0 critical, 2 high, 2 medium, 3 low, 0 violations |
| x4 | Adversarial | Security, attack vectors | 21 min | 2 security, 0 critical, 2 high, 1 medium, 3 low |
| x5 | Architectural | Design coherence | 7 min | 3 architectural, 3 contract, 2 high, 3 medium, 3 low |
| x20 | Exhaustive | Forensics, every line | 16 min | 1 critical, 2 high, 4 medium, 2 low, 4 dead code, 3 token economy |

## Deduplicated Finding Catalog

Findings consolidated across all agents. Duplicate discoveries marked with the agents that found them independently.

### CRITICAL

| ID | Finding | File:Line | Found By | QC Pass |
|----|---------|-----------|----------|---------|
| C1 | `shard.truncated` never set to `true` — `--max-hits` early-exit is dead code, 14+ break statements never fire | `search.zig:2744,2780,4237` | x20, x2 (MEDIUM-1) | pass-003 |

### HIGH / SECURITY

| ID | Finding | File:Line | Found By | QC Pass |
|----|---------|-----------|----------|---------|
| H1 | Legacy JSON escaper doesn't escape control chars 0x00-0x1F — produces invalid JSON | `output.zig:991-1002` | x4 (S1), x20 (H1) | pass-004 |
| H2 | Byte-budget binary search re-reads source files O(log N) times with `--context` | `main.zig:341-375` | x5 (A1), x3 (3a), x4 (H1), x20 (M2) | pass-005 R1 |
| H3 | `inspect.zig` `allocRemaining` with 1 GiB limit × 128 paths = DoS amplifier | `inspect.zig:77,157,220` | x3 (3b), x4 (S2), pass-002 (N3) | pass-005 R2 |
| H4 | Triple PCRE2 evaluation per matching line for regex span extraction | `search.zig:4611-4646` | x3 (2b) | — |
| H5 | `SearchReport` (~321 KB) passed by value through 20+ functions | all output functions | x20 (H2), x5 (A2) | pass-005 R3 |
| H6 | Cursor `corpus_signature` doesn't cover content changes that preserve (size, mtime) | `search.zig:1482`, `cursor.zig` | x5 (H1) | — |

### MEDIUM

| ID | Finding | File:Line | Found By | QC Pass |
|----|---------|-----------|----------|---------|
| M1 | Inspect still has no fisheye — 8.5 KB per pathological line | `inspect.zig` | pass-001 (D1), pass-002 (N1) | pass-001 |
| M2 | v3 context lines also lack fisheye — 9.1 KB for one match with context | `inspect.zig:186,253` | pass-002 (N1) | pass-002 |
| M3 | `inspect.zig` stack frames ~82 KB — 20× AGENTS.md 4 KiB invariant | `inspect.zig:159-161` | pass-002 (N2) | pass-002 |
| M4 | v3 emits `files_discovered`, `files_scanned`, `access_errors` twice (scan + stats) | `agent_output.zig:49-56,85` | x5 (C1), x20 (M1), pass-001 (D8) | — |
| M5 | `truncationReason` misattributes `retention_limit` as `max_hits` when max_hits > 4096 | `agent_output.zig:148-153` | x5 (C2), x20 (M3) | — |
| M6 | `similar` path-name-only scoring, no content-based lexical preselection | `similar.zig:403` | pass-001 (D3), x5 (M1) | — |
| M7 | `similar` no chunking — whole files up to 256 KiB embedded monolithically | `similar.zig:63,443` | pass-001 (D4) | — |
| M8 | No diversity enforcement — one file can consume entire visible budget | `agent_output.zig:100-121` | pass-001 (D12) | — |
| M9 | v3 can emit invalid UTF-8 in JSON strings for non-UTF-8 source lines | `preview.zig:48-53` | x4 (M1) | — |
| M10 | `ByteBudgetTooSmall` errors instead of emitting result with hints | `main.zig:367` | pass-001 (D7), x5 (L3), x20 context | — |
| M11 | `similar.run` leaks `document_list` items on early return (no defer) | `similar.zig:147-153` | x3 (4c) | — |
| M12 | Cursor `line` field overloaded as frontier ordinal in similar (semantic confusion) | `main.zig:306-312`, `similar.zig:491` | x4 (H2) | — |

### LOW

| ID | Finding | File:Line | Found By |
|----|---------|-----------|----------|
| L1 | `makeSearchHit` OOM catch fallback stores dangling pointer to stack buffer | `search.zig:3934` | x20 (M4), x3 (4b), pass-002 (N4) |
| L2 | `-n 0` silently sets max_hits=0 without rejection | `args.zig:498-504` | x3 (4a) |
| L3 | v2 distinct-file count uses `prev_path.len == 0` sentinel (empty-path edge case) | `output.zig:441` | x20 (L1) |
| L4 | `contextForSearchHitsPath` `last_emitted` dedup is dead code | `inspect.zig:225,248` | x20 (L2) |
| L5 | Cursor `decode` masks OOM as `InvalidCursor` | `cursor.zig:43` | x4 (L1) |
| L6 | Cursor hex encoding doubles path size (base64 would be 33% smaller) | `cursor.zig:18-31` | x5 (M3) |
| L7 | Help text missing `--format`, `--max-bytes`, `--cursor`, `--candidate-budget` | `output.zig` | pass-001 (D5) |
| L8 | v3 `route` block always emitted even when index disabled (~40 bytes wasted) | `agent_output.zig:86-98` | x20 (T2) |
| L9 | `files_skipped` has three different JSON names across v1/v2/v3 | various | x5 (C3) |

### DEAD CODE

| ID | Finding | File:Line | Found By |
|----|---------|-----------|----------|
| DC1 | `UnicodeCaseFoldPrefilterStats` — 11 fields, never populated, JSON hardcodes zeros | `stats.zig:79-91,374`, `output.zig:537` | pass-001 (D2), x3 (2a), x20 (D1) |
| DC2 | `FallbackLineScanStats` — 13 fields, optional in SearchStats, never set non-null, never read, never emitted | `stats.zig:338-357,383` | x5 (A3), x20 (D2) |
| DC3 | `WarmBenchmark*` structs and `evaluateWarmPerformanceGates` — only used in tests | `stats.zig:196-246` | x5 (A3), x20 (D3) |
| DC4 | 14+ `if (shard.truncated) break;` statements never fire | `search.zig` 14 locations | x20 (D4) |

### INVARIANT VIOLATIONS (AGENTS.md)

| ID | Invariant | Status | Found By |
|----|-----------|--------|----------|
| IV1 | No mutex in scan loop | ✅ PASS | x3, x20 |
| IV2 | No allocation per-line in scan loop | ✅ PASS | x3, x20 |
| IV3 | Stack frames < 4 KiB on hot path | ⚠️ PASS (hot path); FAIL (inspect path: ~82 KB) | x3, x20, pass-002 |
| IV4 | Single syscall per small file | ✅ PASS | x20 |
| IV5 | Compile-time SIMD selection | ✅ PASS | x20 |
| IV6 | Strategy classification before I/O | ✅ PASS | x20 |

### DONE RIGHT (consensus across agents)

| Finding | Confirmed By |
|---------|-------------|
| Fisheye preview with UTF-8 boundary safety | x1, x3, x4, x5, x20 |
| Cursor encode/decode round-trip with strict validation | x1, x3, x4, x5, x20 |
| v3 verification/scan/projection separation | x1, x5, x20 |
| Command spec single-source table | x5 |
| Byte-budget binary search termination correctness | x1, x4, x20 |
| Thread-local shard accumulation (zero mutex) | x3, x20 |
| Comptime strategy monomorphization | x20 |
| Stats visibility tier system | x1, x5 |
| Format conflict detection | x4 |
| Similar coverage accounting (every disposition tracked) | x5 |

## Convergence Analysis

**Strongest signal (4/5 agents independently):**
- H2: Byte-budget binary search re-reads files — found by x3, x4, x5, x20 independently. This is the most robustly-confirmed performance defect.

**Strong signal (3/5 agents):**
- H1: Invalid JSON from control chars — found by x4, x20, and implied by x1's review of the escaper
- H5: SearchReport by-value cost — found by x5, x20, pass-002
- DC1: Dead unicode_casefold_prefilter — found by pass-001, x3, x20

**Unique high-value findings (single agent):**
- C1: Dead truncation signal — **x20 discovered it (CRITICAL); x2 independently confirmed (MEDIUM-1)**. The most severe defect in the codebase. x2 classified it lower (medium) because the v3 cursor contract's `matches_after_cursor` counting is accurate independent of the `truncated` flag, so pagination correctness is preserved. x20 classified it critical because the performance impact (scanning all files despite `--max-hits`) is severe. Both are correct — the defect is critical for performance but medium for correctness.
- H4: Triple regex evaluation — **x3 only**. A scan-loop performance issue that no other agent traced.
- H6: Cursor content gap (size+mtime identity) — **x5 only**. An architectural robustness issue.

**x2's unique contribution:** DONE-12 — argued that inspect NOT applying fisheye to context lines is **intentional and correct**: "context lines exist to give the agent surrounding source, and truncating them would defeat the purpose." This is the only agent that defended the absence of fisheye in inspect. The counter-argument (from pass-001/pass-002): a 3 KB minified line in context defeats the agent's purpose more than truncating it would. This is a design-tension note, not a definitive resolution.

## Priority Repair Queue (Updated)

| Priority | ID | Finding | Effort | Impact |
|----------|----|---------|--------|--------|
| 1 | C1 | Wire `shard.truncated = true` | 30 min | Enables early-exit, massive perf win |
| 2 | H1 | Fix legacy JSON escaper | 15 min | Prevents invalid JSON output |
| 3 | M1+M2 | Fisheye for inspect + v3 context | 2 hr | Largest token reduction |
| 4 | H2+R2 | Fix binary search re-reads + inspect memory | 3 hr | Prevents gigabyte-scale amplification |
| 5 | H4 | Eliminate triple regex evaluation | 2 hr | Scan-loop throughput |
| 6 | M3 | Reduce inspect stack frame | 1 hr | AGENTS.md invariant compliance |
| 7 | DC1-DC4 | Delete dead stats structs | 30 min | Binary size, memory |
| 8 | H5+R3+R4 | Pass SearchReport by pointer, heap-allocate shards | 4 hr | Memory, memcpy cost |
| 9 | M4-M5 | Fix v3 field redundancy and truncation attribution | 1 hr | Token economy, correctness |
| 10 | M6-M7 | Similar content preselection + chunking | 5 hr | Semantic lane usability |
| 11 | M8 | Diversity enforcement | 2 hr | Evidence quality |
| 12 | H6 | Cursor content hash | 3 hr | Pagination robustness |
| 13 | M9 | UTF-8 validation in preview output | 1 hr | JSON validity |
| 14 | L1-L9 | Low-priority fixes | 3 hr | Polish |
| 15 | M10-M12 | ByteBudgetTooSmall UX, similar leak, cursor overload | 2 hr | Edge cases |

## QC Files Created

| File | Scope | Severity |
|------|-------|----------|
| `pass-001-agent-output-contract.md` | Initial review (12 done right, 12 defects) | Mixed |
| `pass-002-agent-output-contract.md` | Independent verification + 6 new findings | Mixed |
| `pass-003-truncation-dead-signal.md` | Dead truncation signal | CRITICAL |
| `pass-004-json-validity.md` | Invalid JSON from control chars | HIGH/SECURITY |
| `pass-005-resource-management.md` | Binary search re-reads, inspect memory, by-value cost | HIGH |
| `pass-006-multi-agent-synthesis.md` | This file — consolidated catalog | Synthesis |

## Note on x2

The x2 (standard correctness) agent completed after 69 minutes — significantly longer than x3 (21 min) or x20 (16 min). Its findings confirmed the existing catalog without surfacing new critical issues, as expected. Its key contribution:

1. **Independently confirmed C1** (dead truncation signal) as MEDIUM-1, with a nuanced severity assessment: correct that v3 pagination still works (cursor counting is independent), but acknowledged the `truncated` field is dead.
2. **Defended inspect's lack of fisheye** (DONE-12) as intentional — the only agent to do so. This is a valid design-tension observation worth noting: context lines are meant to show surrounding source, and truncating them could hide relevant code. The counter-position (from pass-001/pass-002 and the transcript evidence) is that pathological lines (3 KB minified blobs) harm agent context more than truncation would.
3. **12 "done right" confirmations** — the highest agreement count of any agent, validating the architectural soundness of cursor, fisheye, byte-budget, format conflict detection, and the v3 contract.
