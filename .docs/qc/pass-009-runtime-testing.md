---
id: pass-009-runtime-testing
type: qc
category: runtime-test
status: complete
date: 2026-07-13
scope: "Extensive runtime testing of search, inspect, xo, explain, process commands"
binary: "zig-out/bin/ix-zig.exe (Jul 13 21:16 — pre-truncation-fix build)"
---

# QC Pass 009 — Runtime Testing and Observations

## Test Environment

- Binary: `zig-out/bin/ix-zig.exe` built Jul 13 21:16
- This binary includes xo with fisheye but predates the truncation fix and structuralPrior fix
- Source changes (truncation, fisheye, structuralPrior, omitted_after, build.zig) are committed but NOT in this binary

## Command Testing Results

### search --format records

**Works correctly.** Emits `path:line:column:text` per hit, followed by `ix.result.v1` sentinel.
- `--total-count N` works as alias for `--max-hits N` on search (passes through to records output)
- `--format json` emits full JSON with stats
- `--format agent` emits compact ix.result.v2

### search --context N --format agent-v3

**Works correctly.** Emits ix.result.v3 with:
- `verification: canonical`
- `scan.state: complete/partial_access`
- `projection.state: complete/truncated` with `reason` and `next_cursor`
- `hits` grouped by file with `w` (window) metadata
- `context` array with role-tagged lines (`match`/`context`)

**Observation:** Context lines are full-length — no fisheye applied. A 200-byte line in context costs 200 bytes of the agent's budget. This is the pass-001 D1 / pass-002 N1 defect confirmed at runtime.

### search --max-bytes

**Error UX gap confirmed.** `--max-bytes 500` on a file with hits produces:
```
-- ix.error.v1 {"schema":"ix.error.v1","status":"error","code":"byte_budget_too_small","message":"increase --max-bytes; the budget cannot fit one complete result"} --
```
The error message is helpful ("increase --max-bytes") but doesn't state the minimum viable budget. Agent must guess.

### search --max-hits (truncation)

**Truncation fix NOT active in this binary.** `--max-hits 1 --stats-only` still shows `files_scanned: 44` — all files scanned despite requesting 1 hit. The source fix is committed but not built into this binary.

### xo grouped format

**Works well.** Produces:
- Header with query, retrieval method, coverage stats
- File-grouped output with path once as header
- Span metadata: `lines START:END focus=LINE score=SCORE`
- Line content: `  LINE_NUM | text`
- Gap markers: `  ... N lines omitted ...`
- Trailing gap: `  ... N lines omitted ...` after last span (confirmed working)

**Strong points:**
- Path shown once per file (no repetition)
- Fragmented spans across different parts of the file
- Score visible per span (agent can gauge relevance)
- Coverage state (`complete`/`partial`) visible in header

**Pain points:**
- Each span is contiguous (no within-span fragmentation) — confirmed pass-007 C2
- Lines > 300 bytes DO get fisheye contraction (confirmed working) — `…` markers present
- Lines ≤ 300 bytes are full text (correct — T0 tier)

### xo JSON format

**Works well.** Emits `ix.xo.v1` schema with:
- `retrieval` metadata (bm25_line, structural_prior, degree_of_interest)
- `coverage` with all skip reasons counted
- `projection` with max_bytes, max_spans, returned_spans
- `files` array with `spans` containing `start_line`, `end_line`, `focus_line`, `score`, `omitted_before`, `omitted_after`, `lines[]`
- `omitted_after` confirmed working — agent can see trailing gap

### xo edge cases

| Case | Result | Assessment |
|------|--------|------------|
| Empty query | `MissingValue` error | Correct — needs at least one term |
| Stop-words only (`the with for and`) | `EmptyInsightQuery` error via `xo_failed` | **Pain point** — unfriendly error message (pass-007 L1) |
| Nonexistent path | `coverage=partial, files_read=0, candidates=0, returned=0` | Correct — graceful empty result, not an error |
| Tiny budget (50 bytes) | `byte_budget_too_small` error | Correct — helpful message |
| Many spans (20) | Returns 20 spans across multiple files | Correct — anti-clustering works |
| Long line (1006 bytes) | Fisheye contracted to ~160 bytes with `…needle…` | **Strong point** — fisheye working, match visible |
| Single file | Works, returns spans from that file | Correct |
| Multi-file | Works, groups by file, orders by score | Correct |

### inspect --format records

**Path repetition confirmed.** Every line emits `path:line:text` — path repeated on every line. For a 50-line inspect of `src/main.zig`, the path `src/main.zig` is emitted 50 times = ~700 bytes wasted.

**Fix needed:** Converge on xo's grouped format (path once as header, then `line | text`).

### inspect --format grouped

**Works well.** Emits:
- Header: `== ix.inspect.file path="..." request="..." range=S:E emitted=N eof=... ==`
- Lines: `  N | text`
- Continuation: `-- ix.next.v1 {"argv":["ix","inspect",...],"cmd":"inspect"} --`

**Strong points:** Path-once, clean line format, continuation hints for pagination.
**Pain point:** No fisheye on lines (pass-001 D1). A 3 KB line emits in full.

### inspect --expr --context N

**Works well.** Match-context mode with role tags (`match`/`context`). Records format adds `:role:` to the path-repeated output.

### explain

**Works correctly.** Emits JSON with proof program, query class, mandatory evidence, kernel candidates.

### process status

**Works correctly.** Shows stale index markers, cleanup actions, memory limits.

## Context Usefulness Assessment

### What's desirable
1. **xo's BM25 scoring** — finds the right lines. "cursor encode decode fingerprint" correctly surfaces `cursor.zig:hexDigit/hexValue` and `search.zig:corpus_signature` as top hits
2. **xo's fragmented spans** — multiple focus points across a file, not just one window
3. **xo's grouped format** — path once, clean line numbers, gap markers
4. **v3's verification/scan/projection separation** — agent can trust results and know what's missing
5. **v3's cursor pagination** — deterministic continuation, no guessing
6. **Fisheye on long lines** — 1000-byte line contracted to 160 bytes with match visible

### What's not desirable
1. **inspect records path repetition** — wastes ~14 bytes per line on path data
2. **No fisheye on inspect lines** — long lines in inspect/context emit in full
3. **No within-span fragmentation in xo** — each span is contiguous, no interior gaps
4. **ByteBudgetTooSmall gives no minimum** — agent must guess the viable budget
5. **EmptyInsightQuery error is unfriendly** — says `xo_failed: EmptyInsightQuery` instead of explaining
6. **Search stats blob still huge in --json** — 3+ KB of zero-valued telemetry per search
7. **Truncation fix not in binary** — `--max-hits` doesn't early-exit (source fixed, binary stale)

### Strong points
1. **xo is genuinely useful** — it finds relevant code that a fixed-range inspect would miss. "cursor encode decode fingerprint" surfaced the hex encoding functions AND the corpus signature computation in one call.
2. **xo's byte budget works** — 2000 bytes of the most relevant code, not 2000 bytes of whatever happens to be at line 400.
3. **v3 contract is well-designed** — the three-dimension truth (verification/scan/projection) gives the agent exactly what it needs to decide "do I have enough?"
4. **Cursor pagination is deterministic** — the agent can page through results without re-scanning
5. **Coverage transparency** — every skip reason is visible, the agent knows what it doesn't know

## Pain points summary

| Pain Point | Severity | Fix Status |
|-----------|----------|------------|
| inspect records path repetition | Medium | Not started — converge on xo grouped format |
| No fisheye on inspect lines | High | Source fix in pass-001, not yet implemented |
| No within-span xo fragmentation | Medium | Design needed — SubRange list |
| ByteBudgetTooSmall no minimum | Low | Not started — add minimum hint |
| EmptyInsightQuery unfriendly | Low | Not started — add dedicated error message |
| JSON stats blob still huge | Medium | Source fix in pass-006, not yet implemented |
| Truncation fix not in binary | Critical | Source fixed (commit e1fed22a), binary not rebuilt |

## Binary promotion status

The repo binary (Jul 13 21:16) predates the truncation fix, structuralPrior fix, omitted_after addition, and build.zig arch gate. These changes are in source (commit e1fed22a) but need a rebuild with Zig 0.16.0+ to produce a new binary. The available toolchain (0.15.1) has a pre-existing `std.process.Init` incompatibility.

**Promotion path:** Obtain Zig 0.16.0+ → rebuild → run `compare-historical-speed.mjs` against predecessor → verify match parity and no regression → `sync-native-install.mjs` to promote.
