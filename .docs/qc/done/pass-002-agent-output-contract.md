---
id: pass-002-agent-output-contract
type: qc
category: review
status: complete
date: 2026-07-13
scope: "Second-pass QC of pass-001 — independent source verification, bias check, missed-defect hunt"
prior: pass-001-agent-output-contract
---

# QC Pass 002 — Independent Verification of Pass-001

## Method

Every claim from pass-001 re-verified against source. No reliance on pass-001 conclusions — all file:line references checked independently. Runtime probes repeated. Five new defects found that pass-001 missed. Two pass-001 claims corrected.

## Pass-001 Claims: Verification Results

### Verified Correct (12/12 "done right" claims hold)

| # | Claim | Verdict | Evidence |
|---|-------|---------|----------|
| 1 | Preview extraction clean | ✅ | `preview.zig` fully self-contained, 4 tests covering T0 boundary, wide-match, multibyte, tier transition |
| 2 | SearchHit metadata fields | ✅ | `search.zig:131-143` — 5 new fields with defaults |
| 3 | Exact match span resolution | ✅ | `search.zig:4611-4625` — iterates predicates, picks smallest end |
| 4 | Cursor stale detection | ✅ | `search.zig:267,270,326,329` — both warm and cold paths check signatures |
| 5 | v3 truncation reason | ✅ | `agent_output.zig:148-153` — byte_budget/max_hits/retention_limit |
| 6 | Cursor only when remaining>0 | ✅ | `agent_output.zig:65` — `if (remaining > 0 and visible_count > 0)` |
| 7 | Byte budget binary search | ✅ | `main.zig:341-375` — correct low/high convergence, arena isolation |
| 8 | Context delegation works | ✅ | Runtime: `--context 1` produces role-tagged lines via inspect |
| 9 | Command spec single source | ✅ | `command_spec.zig:23-32` — table feeds parser and help |
| 10 | Similar frontier ordering | ✅ | `similar.zig:344-386` — lexical path + coverage + canonical tail |
| 11 | Format conflict detection | ✅ | `args.zig:474-484` — `ConflictingOutputFormat` on mismatch |
| 12 | Stats visibility tiers | ✅ | `output.zig:525-565` — 6/9/236 field split, `.agent` used by v3 |

### Verified Correct (10/12 defect claims hold, 2 corrected)

| Pass-001 # | Claim | Verdict | Notes |
|---|-------|---------|-------|
| D1 | Inspect no fisheye | ✅ Confirmed | `grep -c fisheye inspect.zig` = 0. Runtime: 8507 bytes for one line |
| D2 | unicode_casefold still hardcoded | ✅ Confirmed | `output.zig:537` still emits zeros in `.debug` |
| D3 | Similar path-name-only scoring | ✅ Confirmed | No import of search.zig; `lexicalPathScore` checks path only |
| D4 | Similar no chunking | ✅ Confirmed | No chunk function; `chunks_embedded` = document count |
| D5 | Help text missing new flags | ✅ Confirmed | `--help` output lacks `--format`, `--max-bytes`, `--cursor` |
| D7 | ByteBudgetTooSmall no guidance | ✅ Confirmed | Runtime: `{"code":"output_failed","message":"ByteBudgetTooSmall"}` |
| D8 | v3 stats redundancy | ✅ Confirmed | `scan` and `stats` both carry files_discovered/scanned |
| D9 | Binary search O(log N) renders | ✅ Confirmed | `versionedSearchResultLength` does full render per probe |
| D11 | No single-sentinel regression test | ✅ Confirmed | No test asserts one sentinel |
| D12 | No diversity | ✅ Confirmed | `agent_output.zig:100-121` emits in stored order |

**D6 correction:** Pass-001 marked this "Resolved." Correct — the README `--stats` lie is fixed (line 225 now says "Agent Format"). `--stats` is correctly rejected with `UnsupportedFlag`. No defect remains.

**D10 correction:** Pass-001 called this a "Low" defect. On re-inspection, it is not a defect at all. The `.stats` format intentionally uses the compact `ix.result.v1` sentinel, which is already well-designed (707 bytes for a 2-hit search). Routing it through `writeStats` with `.standard` visibility would change the output contract for no benefit. Pass-001 overstated this.

## New Defects Found (Pass-001 missed these)

### N1. Context lines in v3 output also lack fisheye — second geyser

**Evidence:** `agent_output.zig:124-141` — the v3 context block emits `line.text` directly from `inspect.ContextReport.lines[].text`. `inspect.zig:186` and `inspect.zig:253` store `source_lines[line_index]` as `line.text` — raw slices into the file bytes with no contraction. Runtime: `ix search 'lit:IMPLEMENT' .docs/log.txt --context 0 --max-hits 1` emits **9169 bytes**. The v3 context path is the same unfisheyed emission as inspect, just wrapped in the v3 envelope.

**Impact:** When an agent uses `search --context N`, every context line is full-length. For a file with a 3 KB minified line, a single hit with 3 lines of context dumps ~9 KB into the context window. This means `--context`, the feature designed to *save* round-trips, can itself be a context-window-scale dump.

**Fix:** Apply `preview.make` to each context line in `inspect.zig` before storing in `ContextReport.lines`. For `"match"` role lines, center on the match column. For `"context"` role lines, center on the line midpoint or first non-whitespace. This is the same fix as D1 — once inspect applies fisheye, the v3 context block inherits the fix automatically because it reads from `ContextReport`.

### N2. `inspect.zig` stack frames exceed 4 KiB invariant by 20×

**Evidence:** `inspect.zig:159-161` — `contextForPath` allocates three stack arrays:
- `source_lines: [4096][]const u8` = 65,536 bytes (4096 × 16-byte slice)
- `match_lines: [4096]bool` = 4,096 bytes
- `emitted_lines: [4096]bool` = 4,096 bytes
- `read_buffer: [8192]u8` = 8,192 bytes
- Total local stack: **~82 KB**

Plus `ContextReport.lines: [4096]ContextLine` at 40 bytes each = **160 KB**, returned by value (likely caller's stack via NRVO, but still a large frame).

`contextForSearchHitsPath` (`inspect.zig:196-260`) has the same `ContextReport` frame plus `read_buffer[8192]`.

The AGENTS.md invariant (`AGENTS.md:88`) states: "Stack frames < 4 KiB on hot path — Avoids Windows `__chkstk` page probes across 100k+ line iterations."

**Impact:** While inspect is not the scan hot path (it's called per-file, not per-line), the 82 KB stack frame triggers `__chkstk` on Windows, which probes each 4 KiB page. For a 100-file inspect batch, that's 100 × 20 page probes = 2000 unnecessary faults. More critically, if a caller uses a 64 KB custom stack (AGENTS.md Tier 7 roadmap: "64 KiB stacks for scan workers"), this function overflows the stack immediately.

**Fix:** Reduce `MAX_CONTEXT_LINES` from 4096 to 256 (the realistic max for match-context windows — `--context 10` with 20 hits = 420 lines at most, and 256 covers most cases). Or heap-allocate the arrays via the allocator parameter that is already passed to the function. The `ContextReport.lines` array should also be heap-allocated or reduced.

### N3. `inspect.zig` uses `allocRemaining` with 1 GB limit — unbounded memory

**Evidence:** `inspect.zig:77,157,220` — three call sites use `reader.interface.allocRemaining(allocator, .limited(1024 * 1024 * 1024))`. The 1 GB limit is effectively unbounded for source files. The allocator is the arena from `init.arena` (for `search --context` delegation) or `std.testing.allocator` (in tests).

**Impact:** `ix inspect <very_large_file> --all` reads the entire file into memory. For a 500 MB log file (not uncommon in the transcripts — `.docs/log.txt` contains multi-KB JSON blobs), this allocates 500 MB into the arena. The arena lives for the process lifetime. No per-file free. For `inspect --expr` with multiple files, each file's bytes accumulate.

**Fix:** For `inspect --range`, use streaming line iteration (the code already has `read_buffer[8192]` but then discards it in favor of `allocRemaining`). For `inspect --expr`, cap at 1 MiB (same as scan buffer). The `allocRemaining` path is a shortcut that avoids carry-buffer logic but trades memory safety for simplicity.

### N4. `makeSearchHit` catch fallback creates dangling pointer on stack-buffer path

**Evidence:** `search.zig:3933-3938`:
```zig
shard.hits[shard.hit_count] = makeSearchHit(allocator, ...) catch .{
    .path = display_path,
    .preview = allocator.dupe(u8, line) catch line,  // <-- inner catch
    ...
};
```

When `preview.make` fails (OOM), the outer catch tries `allocator.dupe(u8, line)`. If that also fails (same OOM), the inner `catch line` returns the raw `line` pointer. The `line` is a slice into either:
- mmap'd data (valid for the file's mapped lifetime — OK)
- `read_buffer[SCAN_READ_BUFFER_SIZE]` (stack-allocated, invalid after `scanOpenFileIntoShardImpl` returns — **dangling**)

The `data` parameter in the mmap path (`search.zig:3100-3148`) is mmap'd and valid. But the stack-buffer path (`scanOpenFileIntoShardImpl` at `search.zig:3844`) passes `line_part` which is a slice into `read_buffer`. If `preview.make` fails AND `allocator.dupe` fails, the hit's `preview` points into stack memory that will be overwritten by the next file's scan.

**Impact:** Extremely rare (requires double-OOM). But if triggered, the hit record contains garbage preview data that may survive into the output JSON. The probability is negligible in practice (arena allocator almost never fails), but the code pattern is technically unsound.

**Fix:** Remove the inner `catch line`. If both `preview.make` and `allocator.dupe` fail, skip the hit entirely (`return` instead of storing a dangling pointer). A missing hit is better than a corrupt hit.

### N5. v3 `eligible` and `remaining` are correct but `returned` can mislead

**Evidence:** `agent_output.zig:38-40`:
```zig
const visible_count = @min(options.visible_count, report.hit_count);
const eligible = report.matches_after_cursor;
const remaining = eligible -| visible_count;
```

When `max_hits` limits retention, `report.hit_count` is capped at `max_hits`, but `matches_after_cursor` counts all matches (verified: `search.zig:3926` increments unconditionally before the retention check). So `eligible = 100`, `returned = 5`, `remaining = 95`. This is correct — the agent can page via cursor.

But the field name `returned` is ambiguous. It says "5 returned" but does not say "5 of 100 retained." The `eligible` field says 100, but an agent might interpret `returned: 5` as "only 5 hits exist." The field name should be `retained` or `visible` to distinguish from total matches.

**Impact:** Low — the presence of `eligible: 100` and `remaining: 95` disambiguates. But field naming should be self-explanatory.

**Fix:** Rename `returned` to `visible` in the v3 projection object. `visible` clearly means "what you see now," while `eligible` means "what exists" and `remaining` means "what is left."

### N6. `search --max-bytes` errors instead of emitting empty result with continuation

**Evidence:** `main.zig:367`: `if (low == 0 and report.matches_after_cursor > 0) return error.ByteBudgetTooSmall`. When the budget can't fit even one hit, the binary returns `ix.error.v1` with exit code 1.

Runtime: `ix search 'lit:pub' src --max-bytes 500` produces:
```
-- ix.error.v1 {"code":"output_failed","message":"ByteBudgetTooSmall"} --
```

An agent receiving this error learns nothing about the minimum viable budget or how many matches exist.

**Impact:** The agent must guess a larger budget. It cannot determine whether 600, 2000, or 10000 is needed. The error is correct (the budget is genuinely too small) but unhelpful.

**Fix:** Instead of erroring, emit a v3 result with `projection.state: "truncated"`, `returned: 0`, `eligible: N`, `remaining: N`, and a `"byte_budget_min"` hint carrying the measured size of the first hit's envelope (~644 bytes measured). The agent increases its budget and retries. This is strictly more informative than an error.

## Pass-001 Defect Priority Corrections

Pass-001 listed D1 (inspect fisheye) as priority 1. On re-inspection, **N1 makes this more urgent**: the v3 context lines are the *same* unfisheyed emission. Fixing D1 (applying fisheye in inspect) automatically fixes N1 (v3 context). The two are one fix, not two. This raises the effective impact — every `--context` call and every `inspect` call leaks full-length lines.

Pass-001 listed N4 (dangling pointer) as not found. It is extremely low probability but technically real. It should be noted but not prioritized — arena OOM is not a realistic scenario.

## Corrected Priority Sequence

| Priority | ID | Finding | Fix Effort |
|----------|----|---------|-----------|
| 1 | D1+N1 | Fisheye for inspect + v3 context (one fix) | 2 hours |
| 2 | N2 | inspect.zig stack frame 20× over 4 KiB limit | 1 hour (reduce MAX_CONTEXT_LINES to 256 or heap-alloc) |
| 3 | N3 | inspect.zig allocRemaining 1 GB unbounded | 1 hour (cap at 1 MiB for --expr, stream for --range) |
| 4 | D5 | Help text missing new flags | 30 min |
| 5 | D7+N6 | ByteBudgetTooSmall: emit result with hint, not error | 1 hour |
| 6 | D3 | Similar content-based preselection | 3 hours |
| 7 | D4 | Similar chunking | 2 hours |
| 8 | D12 | Diversity enforcement | 2 hours |
| 9 | D11 | Single-sentinel regression test | 1 hour |
| 10 | D8 | v3 stats redundancy | 30 min |
| 11 | D2 | Delete unicode_casefold_prefilter | 15 min |
| 12 | D9 | Optimize byte-budget binary search | 1 hour |
| 13 | N4 | makeSearchHit dangling pointer on double-OOM | 15 min |
| 14 | N5 | Rename v3 `returned` to `visible` | 15 min |
| 15 | D10 | ~~Route .stats through writeStats~~ | **WONTFIX** — not a defect |

## Bias Check: What pass-001 got wrong

1. **D10 was a false positive.** The `.stats` format using `writeSearchReport` (the compact v1 sentinel) is intentional and correct. Pass-001 flagged it as an inconsistency; it is actually a different output contract that serves the "existence check" use case well.

2. **D1 understated scope.** Pass-001 identified inspect fisheye as one defect. It is actually two: inspect emission AND v3 context emission (N1). The fix is the same, but the impact is wider.

3. **Pass-001 missed the stack frame violation (N2).** The `MAX_CONTEXT_LINES = 4096` with three stack arrays totaling 82 KB is a direct violation of the AGENTS.md `< 4 KiB` invariant. This is the kind of invariant violation that the QC process exists to catch.

4. **Pass-001 missed the unbounded memory allocation (N3).** The 1 GB `allocRemaining` limit in three places is an unbounded memory path that contradicts the arena-allocation discipline.

5. **Pass-001 missed the dangling pointer pattern (N4).** The `catch line` fallback in `makeSearchHit` is technically unsound, even if practically unreachable.

6. **Pass-001 missed the ByteBudgetTooSmall UX gap framing (N6).** It found D7 (no guidance) but did not recognize that the error-vs-result choice is the deeper issue — an error prevents the agent from learning `eligible` and `remaining`.

## Summary

The implementation is architecturally sound. The v3 contract (verification/scan/projection separation), cursor system (fingerprint + stale detection), byte budget (binary search), and command spec (single-source table) are all well-designed and correctly implemented. The preview extraction is clean and properly tested.

The highest-impact remaining work is applying fisheye to inspect/v3-context (D1+N1), fixing the stack frame violation (N2), and bounding inspect memory (N3). These three are all in `inspect.zig` and can be fixed together in one focused pass. The similar improvements (D3 content preselection, D4 chunking) are the next priority after the inspect path is clean.
