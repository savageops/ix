---
id: pass-001-agent-output-contract
type: qc
category: review
status: complete
date: 2026-07-13
scope: "Agent-native output contract implementation — preview extraction, v3 format, cursor pagination, byte budget, context delegation, stats visibility, similar frontier, command spec"
---

# QC Pass 001 — Agent Output Contract

## Method

Direct source inspection of every modified file. No git diffs, no prior docs, no plan assumptions. Every finding references a file:line and a runtime probe where applicable.

## Done Right

### 1. Preview extraction is clean and correct

`src/core/preview.zig` is well-factored. The `MatchSpan` + `Preview` type split is the right abstraction — callers get both the compact text and the source byte window (`source_start`, `source_end`, `elided_left`, `elided_right`) needed to interpret the preview exactly. The old `fisheyePreview`/`fisheyeHalfWidth` functions were fully removed from `search.zig` (verified: `grep -n 'fn fisheye' src/core/search.zig` returns 0). The tier constants (T0≤300, T1≤600, T2≤1200, T3>1200 with 150/75/37 half-widths) are preserved correctly. No duplication of constants between modules.

### 2. UTF-8 boundary safety is implemented and tested

`preview.zig:48-53` validates UTF-8 before adjusting boundaries. `nextCodepointBoundary` (line 88) and `previousCodepointBoundary` (line 95) use continuation-byte detection (`isContinuation` at line 102: `byte & 0b1100_0000 == 0b1000_0000`). The fallback path for non-UTF-8 input (invalid bytes, binary) is correct — it skips boundary adjustment and remains byte-addressable. The test at line 123 ("preview never cuts a multibyte codepoint") uses `é` (2-byte) and `界` (3-byte) straddling the tier boundary. Verified correct.

### 3. SearchHit now carries preview metadata

`search.zig:131-143`: `SearchHit` gained `match_len`, `preview_start`, `preview_end`, `preview_elided_left`, `preview_elided_right`. This lets the v3 agent format emit the `w` (window) object per hit, so the model knows exactly which bytes of the source line are present and whether elision occurred on either side. The `makeSearchHit` function (`search.zig:4588-4608`) correctly populates all fields from `preview.make`.

### 4. Exact match span resolution is precise

`exactMatchSpan` (`search.zig:4611-4625`) iterates all predicates that match at the selected column and picks the one with the smallest end byte. This means for compound expressions (`lit:foo || lit:bar`), the preview is centered on the actual matched predicate, not just the first column. `predicateSpanAtColumn` (`search.zig:4628-4646`) handles regex via PCRE2 ovector (`pcre_regex.span`) with Zig-native regex fallback. The `regexLiteralEnd` function (`search.zig:4649-4665`) classifies regex strategies whose matched body is a single literal — correct for `regex_plain_literal`, `regex_ascii_casefold_literal`, `regex_word_boundary_literal`, and their casefold variant.

### 5. Cursor system is cryptographically sound

`cursor.zig` implements a versioned (`ixc1.`), dot-delimited encoding carrying `corpus_signature` (u64 hex), `request_fingerprint` (u64 hex), `line`, `column`, and hex-encoded `path`. The `decode` function (line 34) rejects: wrong version prefix, missing fields, zero coordinates (`line == 0 or column == 0`), odd-length hex, trailing fields. The `requestFingerprint` function (line 60) hashes expression + all paths + all membership flags (hidden, symlinks, no_ignore, case_insensitive, fixed_strings) + ignore files into a Wyhash. Stale-cursor detection is wired in `search.run` (`search.zig:266-270` for warm path, `search.zig:325-329` for cold path) — returns `error.StaleCursor` or `error.CursorRequestMismatch` with typed error messages in `main.zig:107-110`.

### 6. v3 output contract is well-structured

`agent_output.zig` emits `ix.result.v3` with three independent truth dimensions: `verification` (always `"canonical"` — proof-carrying), `scan.state` (`complete` or `partial_access`), and `projection.state` (`complete` or `truncated`). This separation is correct — canonical verification of every hit does not imply complete scanning (access errors) or complete projection (truncation). The `truncationReason` function (line 148) correctly distinguishes `byte_budget`, `max_hits`, and `retention_limit`. The cursor is emitted only when `remaining > 0 and visible_count > 0` — correct, no cursor on the last page.

### 7. Byte budget binary search is correct

`main.zig:341-375` (`writeVersionedSearchResult`) uses binary search to find the largest whole-record page fitting the byte budget. The search allocates separate arenas for each length probe (`versionedSearchResultLength` at line 378), so probes don't accumulate memory. The `ByteBudgetTooSmall` error (line 367) fires when `low == 0 and matches_after_cursor > 0` — meaning the budget can't fit even one hit. Correct edge-case handling.

### 8. Context delegation works at runtime

Verified: `ix search 'lit:pub' src/main.zig --context 1 --max-hits 1` produces `ix.result.v3` with a `"context"` array containing role-tagged lines (`"r":"context"`, `"r":"match"`). The context is delivered through `inspect.contextReportsFromSearchReport` (`main.zig:396-399`), which reuses the canonical search engine via `search.matchesLine()`. This is the correct delegation pattern — no context arrays added to `SearchHit`, no scan-loop bloat.

### 9. Command spec eliminates flag drift

`command_spec.zig` defines a single `formats` array (line 23) that feeds both `parseFormat` (line 35) and `writeFormatNames` (line 41). The test at line 48 verifies every format round-trips. This is the single-source-of-truth pattern that prevents the `--stats` / `--context` documentation-parser divergence.

### 10. Similar frontier ordering is deterministic

`buildFrontierOrder` (`similar.zig:344-386`) orders candidates by: (1) lexical path-name score for the first half of the budget, (2) evenly-distributed corpus coverage for the remaining slots, (3) canonical path order for the tail. This is deterministic, reproducible, and never drops candidates (zero-scored files remain eligible — line 365 comment: "zero-scored files remain eligible"). The `nearestUnselected` function (line 389) uses stable forward-first tie-breaking.

### 11. Format conflict detection is strict

`args.zig:474-484` (`selectOutputFormat`) rejects conflicting format flags (`--agent --json` → `ConflictingOutputFormat`). Context and bounded features upgrade format automatically but reject incompatible combinations (`--json --max-bytes` → error, because `--json` doesn't support `--max-bytes`). The `matches` subcommand correctly rejects terminal-envelope formats and context (line 217-224).

### 12. Stats visibility tiers are correctly separated

`output.zig:525-565` (`writeStats`): `.agent` emits 6 fields, `.standard` emits 9, `.debug` emits all 236. The agent path uses `.agent` visibility (verified: `agent_output.zig:85` calls `legacy_output.writeStats(writer, report.stats, .agent)`). The old inline `unicode_casefold_prefilter` hardcoded-zero block is now confined to `.debug` only — agents never see it.

## Done Wrong or Incomplete

### D1. Inspect still has NO fisheye — the largest token geyser remains unfixed

**Evidence:** `grep -n 'fisheye\|preview\.make' src/core/inspect.zig` returns 0. Runtime probe: `ix inspect .docs/log.txt --range 39:39 --json` emits **8507 bytes** for one pathological line. The `preview.zig` module exists, is tested, and works — but `inspect.zig` does not import or call it. Every inspect line emission (`inspect.zig:107`, `inspect.zig:186`, `inspect.zig:253`) stores `line.text` verbatim.

**Impact:** A single `inspect` call against a file with long lines dumps up to 256 KiB into the agent's context. This is the exact defect the plan identified as the highest-priority code change. It remains unfixed.

**Fix:** Import `preview` in `inspect.zig`. In `context()` (line 116) and `contextForPath()` (line 145), apply `preview.make(allocator, line_text, span)` before storing in `ContextReport.lines`. In `windowForPath`, apply fisheye to each line. For `inspect --range` without `--expr`, center on first non-whitespace.

### D2. `unicode_casefold_prefilter` is still hardcoded zeros in .debug output

**Evidence:** `output.zig:537` — the `.debug` path still emits `"unicode_casefold_prefilter":{"full_scan_calls":0,...all zeros...}`. There is no write path anywhere in the engine (verified: `grep -rn 'unicode_casefold_prefilter' src/core/stats.zig` shows only the struct definition at line 374 with default-zero initialization).

**Impact:** Low for agents (`.agent` visibility doesn't emit it), but the `.debug` path still carries 180 bytes of dead telemetry per search. The struct exists, is emitted, and has never been populated.

**Fix:** Delete the `unicode_casefold_prefilter` block from `writeStats` line 537 and the struct from `stats.zig:374`. If the feature is implemented later, re-add with a real write path.

### D3. Similar does NOT use the lexical search engine for content-based preselection

**Evidence:** `similar.zig` does not import `search.zig`, `expr.zig`, or `trigram.zig` (verified: `head -4 src/core/similar.zig` shows only std, cli, cursor, output_contract). The "lexical" scoring at `lexicalPathScore` (line 403) is **path-name-only** — it checks if query tokens appear in the file path (`containsIgnoreCase(path, query[start..end])`). It does not scan file contents. The comment at line 402 is honest: "Scores path-name evidence only as prioritization."

**Impact:** The candidate frontier is ordered by filename matching, not content matching. A file named `auth.zig` scores high for query "auth" regardless of whether it contains the concept. Files with semantically relevant content but irrelevant names (e.g., `session_manager.zig` for query "authentication") score zero and are ordered last. This is better than no ordering but falls short of the plan's intent: "use IX's lexical engine to build a candidate frontier."

**Fix:** Before the embedding API call, run `search.run` with the query tokens as a `lit:` alternation. Use `stats_only = true` to get per-file match counts without retaining hits. Rank by match density. This requires importing `search` and `expr` into `similar.zig`.

### D4. Similar does NOT chunk files

**Evidence:** `similar.zig:63` — `MAX_FILE_BYTES = 256 * 1024`. `readCandidateDocument` (line 443) reads entire file bodies up to 256 KiB. The `chunks_embedded` field in `Coverage` (line 54) is set to `candidate_document_count` (line 146) — it counts documents, not chunks. No chunk function exists.

**Impact:** A 200 KiB source file is embedded as one monolithic input. If the relevant section is 2 KiB in the middle, the embedding is diluted by 100× irrelevant content. Recall suffers. The API cost is also higher per-file because the entire body is sent.

**Fix:** Add a `chunk` function that splits text on 4 KiB boundaries (respecting line breaks). Embed each chunk. Aggregate per-file similarity as max (recall) or mean (precision).

### D5. Help text does not mention `--format`, `--max-bytes`, `--cursor`, or `--candidate-budget`

**Evidence:** `ix --help` output (verified at runtime) lists `--agent`, `--json`, `--stats-only`, `-l`, `-c`, `--context N` but does not mention `--format`, `--max-bytes`, `--cursor`, or `--candidate-budget`. The `command_spec.zig` table defines 8 formats (`text`, `agent`, `agent-v3`, `json`, `json-compact`, `files`, `count`, `stats`) but the help text only shows `--agent` and `--json`.

**Impact:** An agent reading the help text does not discover the v3 format, the byte budget, cursor pagination, or the candidate budget control. The most powerful agent-facing features are invisible.

**Fix:** Update `writeTopHelp` in `output.zig` to include the new flags. Generate the format list from `command_spec.formats` via `command_spec.writeFormatNames`.

### D6. `--stats` still returns `UnsupportedFlag` — README context unclear

**Evidence:** `ix search 'lit:fn' src/main.zig --stats` returns `ix.error.v1 UnsupportedFlag`. The README line 225 now says "### Agent Format (`--agent`)" — the old `--json --stats` text was replaced. But the help text at runtime still shows `--stats-only` (which maps to `.stats` format correctly). The issue is that `--stats` (without `-only`) was never a valid flag, and the parser correctly rejects it. This is not a defect — it is correct behavior that replaced the old documentation lie.

**Status:** Resolved. The README no longer claims `--stats` exists. The `--stats-only` flag works correctly via format selection.

### D7. `ByteBudgetTooSmall` error gives no guidance

**Evidence:** `ix search 'lit:pub' src/main.zig --max-bytes 100` returns `-- ix.error.v1 {"code":"output_failed","message":"ByteBudgetTooSmall"} --`. The error does not tell the agent what the minimum viable budget is.

**Impact:** An agent receiving this error cannot determine whether to increase the budget to 200, 2000, or 20000. It must guess.

**Fix:** Include the measured size of the first hit in the error: `"message":"ByteBudgetTooSmall","hint":"minimum viable budget is N bytes for the first hit"`. Or return a result with `projection.state: truncated` and zero hits plus the minimum budget hint, rather than erroring.

### D8. v3 format emits `stats` even for `.agent` visibility — redundant with top-level fields

**Evidence:** `agent_output.zig:84-85` emits `"stats":{"files_discovered":1,"files_scanned":1,"matches_found":1,...}`. But the `scan` object at line 49-56 already emits `"files_discovered"`, `"files_scanned"`, and `"access_errors"`. And the `projection` object at line 57-59 emits `"returned"` and `"eligible"`. The `matches_found` in stats overlaps conceptually with `eligible` in projection.

**Impact:** Redundant fields consume ~80 bytes per v3 result. Not severe, but violates the density principle.

**Fix:** Drop the `stats` block from v3 entirely. The `scan` and `projection` objects carry all the information the agent needs. If `bytes_scanned` or `total_ms` are needed, add them to `scan` or `projection`.

### D9. Binary search for byte budget does `O(log N)` full render passes

**Evidence:** `main.zig:360-366` — the binary search calls `versionedSearchResultLength` (which calls `renderVersionedSearchResult` into a temporary arena) for each probe. For `matches_after_cursor = 1000`, this is ~10 full render passes, each allocating an arena, building the entire JSON, measuring it, and discarding.

**Impact:** For large result sets with tight byte budgets, the output phase does 10× the work of the actual rendering. Not a scan-path cost (the scan already completed), but measurable latency on the output path.

**Fix:** Estimate per-hit byte cost from the first hit (`path.len + preview.len + 50`), compute `estimated_count = budget / avg_hit_cost`, render once, adjust by ±1 if over/under budget. One render pass instead of 10.

### D10. `search --stats` path still uses old `writeSearchReport` (full sentinel)

**Evidence:** `main.zig:328` — `.stats => try output.writeSearchReport(writer, report)`. This calls the old `writeSearchReport` function which emits the `ix.result.v1` sentinel with `dedupe`, `files`, `matches`, `ms`, `slowest`, `access_errors`, `status`. This path does not use `writeStats` with visibility tiers.

**Impact:** `--stats-only` (which maps to `.stats` format) still emits the old sentinel format. It does not benefit from the visibility-tier refactoring. Minor inconsistency, but means the stats-only path has a different output contract than the v2/v3 paths.

**Fix:** Either keep `writeSearchReport` as-is (it's already compact) or route `.stats` through a `.standard` visibility `writeStats` call for consistency.

### D11. No regression test for single-sentinel emission

**Evidence:** No test in `output.zig`, `agent_output.zig`, or `main.zig` asserts exactly one sentinel per invocation. The transcripts showed duplicated output (three independent sessions). While the current binary doesn't reproduce it, there is no test that would catch it if it returned.

**Impact:** If the duplication bug returns (Windows pipe semantics, buffer flush interaction), no test catches it.

**Fix:** Add a test that calls each output writer and asserts the sentinel prefix (`ix.result.v2`, `ix.result.v3`, `ix.result.v1`, `ix.inspect.file`) appears exactly once in the output buffer.

### D12. No diversity enforcement in v2 or v3 output

**Evidence:** `agent_output.zig:100-121` — the v3 hit emission iterates `report.hits[0..visible_count]` in stored order (sorted by path during merge). There is no per-file quota, no expression-branch coverage, no diversity selection. `writeSearchReportAgent` in `output.zig` has the same pattern (sorted by path, emitted in order).

**Impact:** A query matching 50 times in one test file consumes the entire visible budget. The declaration file may not appear at all.

**Fix:** After the existing sort, compute `per_file_quota = max(3, visible_count / distinct_files)`. Walk the sorted hits, emitting up to `per_file_quota` per file before moving to the next.

## Summary Scorecard

| Area | Status | Notes |
|------|--------|-------|
| Preview extraction (preview.zig) | ✅ Done right | Clean, tested, UTF-8 safe |
| SearchHit metadata fields | ✅ Done right | match_len, preview_start/end, elided flags |
| Exact match span resolution | ✅ Done right | Multi-predicate, regex ovector |
| Cursor system | ✅ Done right | Versioned, fingerprinted, stale detection |
| v3 output contract | ✅ Done right | Three-dimension truth, truncation reason |
| Byte budget | ✅ Done right | Binary search, arena isolation |
| Context delegation | ✅ Done right | Routes through inspect, runtime verified |
| Command spec | ✅ Done right | Single source, round-trip tested |
| Similar frontier ordering | ✅ Done right | Lexical path + coverage, deterministic |
| Format conflict detection | ✅ Done right | Strict, typed errors |
| Stats visibility tiers | ✅ Done right | 6/9/236 field split |
| Inspect fisheye | ❌ Not done | 8.5 KB per pathological line, preview.zig unused |
| unicode_casefold_prefilter | ⚠️ Half done | Confined to .debug but still hardcoded zeros |
| Similar content preselection | ⚠️ Partial | Path-name only, not lexical content search |
| Similar chunking | ❌ Not done | Whole-file embed, no chunk function |
| Help text coverage | ❌ Incomplete | --format, --max-bytes, --cursor, --candidate-budget missing |
| ByteBudgetTooSmall error | ⚠️ Unguided | No minimum-budget hint |
| v3 stats redundancy | ⚠️ Minor | Overlaps scan/projection objects |
| Binary search cost | ⚠️ Minor | O(log N) full render passes |
| Single-sentinel regression test | ❌ Missing | No assertion for one sentinel per call |
| Diversity enforcement | ❌ Not done | No per-file quota or branch coverage |

## Priority Repair Sequence

1. **D1** — Apply fisheye to inspect (largest remaining token geyser)
2. **D5** — Update help text to expose new flags
3. **D7** — Add minimum-budget hint to ByteBudgetTooSmall
4. **D3** — Wire lexical content search into similar frontier
5. **D4** — Add chunking to similar
6. **D12** — Add diversity to v2/v3 output
7. **D11** — Add single-sentinel regression test
8. **D8** — Remove redundant stats from v3
9. **D2** — Delete dead unicode_casefold_prefilter struct
10. **D9** — Optimize byte-budget binary search to single-pass estimate
