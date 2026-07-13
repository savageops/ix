---
id: pass-007-xo-implementation
type: qc
category: review
status: complete
date: 2026-07-13
scope: "Existing ix xo implementation review — 4 agents at x2 effort"
agents: 4
---

# QC Pass 007 — ix xo Implementation Review

## State: Already implemented, ~60% to vision

570 lines in src/core/xo.zig. BM25 line scoring + structural prior + DOI geometric expansion + byte-budget rollback. Wired through args.zig, main.zig, with tests.

## Done Right (9 items)

1. BM25 formula correct (k1=1.2, b=0.75, Lucene IDF variant, line-as-document)
2. Budget-aware expansion with rollback (save/attempt/restore per step, zero-alloc Discarding writer for measurement)
3. Anti-clustering span selection (rejects within MAX_RADIUS*2+1=17 lines of existing spans)
4. Pipeline isolation from search (never calls search.run, owns own discovery/tokenization/scoring)
5. Coverage transparency (every skip reason counted and emitted, coverageState refuses partial=complete)
6. Path-once grouped output (path header once, then line|text per line — already solves path redundancy)
7. Deterministic ordering (path then line tie-break, byte-stable)
8. Stop-word tokenization (strips glue like "code"/"how"/"with", dedup case-insensitive)
9. Arena allocation through CappedAllocator (5% device RAM ceiling, no leaks)

## Critical

### C1. No fisheye contraction — full lines emitted
**File:** xo.zig:465 (grouped), xo.zig:544 (JSON)
preview.make exists in preview.zig with UTF-8-safe tiered contraction. search.zig uses it. xo never imports it. Both output paths emit line.text verbatim. A 2000-byte minified line consumes the entire byte budget on one line.
**Fix:** Import preview, track focus column per candidate (extend Candidate with focus_column), pass each line through preview.make(allocator, line.text, .{ .start = focus_col, .end = focus_col + term.len }).

### C2. No within-span fragmentation — spans are contiguous
**File:** xo.zig:57 (Span type), xo.zig:397-416 (expandWithinBudget)
Span has start_line_index/end_line_index only. Expansion is symmetric and contiguous. User wants "smaller spreads over longer distance" — fragmented spans with interior gaps where density decays from focus.
**Fix:** Replace contiguous [start,end] with SubRange list (stack array, 4 sub-ranges per span). Expand at geometric distances (1,3,7,15), each shorter. Mark gaps with "... N lines omitted ...".

## High

### H1. No omitted_after — agent can't see trailing context gap
**File:** xo.zig:539 — JSON emits omitted_before per span but no omitted_after after last span.
**Fix:** Emit omitted_after: line_count - last_end_line after last span per file.

### H2. No pagination/cursor — agent must re-scan for more
xo emits no continuation token. Agent must re-run with different params, re-discovering and re-scoring everything.
**Fix:** Emit a next hint with query, paths, and candidate offset.

### H3. Latent array overflow — MAX_OUTPUT_SPANS decoupled from MAX_XO_SPANS
**File:** xo.zig:11 vs args.zig:6 — both 128 but defined independently. Raising one without the other causes stack overflow.
**Fix:** comptime assert or import cli.MAX_XO_SPANS directly.

### H4. structuralPrior matches keywords in strings/comments
**File:** xo.zig:351-357 — containsFold(line, "fn ") matches inside comments and string literals. Comment check runs AFTER marker check, so comments get declaration bonus (0.18) instead of comment bonus (0.08).
**Fix:** Check comment prefix FIRST, then anchor marker detection to line start (startsWith not containsFold).

## Medium

- M1. document_frequency undercounted at candidate limit — df not incremented for skipped tail lines, inflating IDF
- M2. No symlink-loop or depth guard in discoverPath — recursive walk with no visited-set, no no_follow
- M3. expandWithinBudget re-renders full projection per attempt — O(spans x radius x total_lines)
- M4. inspect records format repeats path per line (output.zig:991) — user wants path-once header like xo grouped
- M5. inspect --range has no fisheye — strictly contiguous, user wants fragmented spreads

## Low

- L1. EmptyInsightQuery error surfaces as unfriendly xo_failed
- L2. boolText duplicated between xo.zig and output.zig
- L3. normalizePath (xo) and normalizeDisplayPath (inspect) near-duplicates
- L4. Magic threshold 0.20 in expansion is undocumented — needs named constant

## Defaults Assessment

| Parameter | Current | Assessment |
|-----------|---------|------------|
| max_bytes | 8000 | Reasonable (~2K tokens). With fisheye, more evidence fits. Keep. |
| max_spans | 12 | Reasonable upper bound. Keep. |
| MAX_RADIUS | 8 | Controls spread distance. Raise to 16-32 if within-span fragmentation added. |
| MAX_CANDIDATE_LINES | 65536 | Input-side cap, correctly independent of output budget. Fine. |
| MAX_FILES | 1024 | Fine. |
| MAX_INPUT_BYTES | 16 MiB | Fine. |

## Cleanup

- Redundant safety check at xo.zig:103-104 (expandWithinBudget already guarantees fit)
- MAX_OUTPUT_SPANS constant — replace with cli.MAX_XO_SPANS import
- Local boolText — minor duplication
