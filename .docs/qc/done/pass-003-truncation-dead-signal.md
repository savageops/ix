---
id: pass-003-truncation-dead-signal
type: qc
category: critical-defect
status: complete
date: 2026-07-13
severity: critical
discovered_by: "x20 forensic agent, confirmed independently"
prior: pass-002-agent-output-contract
---

# QC Pass 003 — Dead Truncation Signal (CRITICAL)

## Defect

`shard.truncated` and `report.truncated` are **never set to `true`** anywhere in the codebase. The `--max-hits` early-exit mechanism is completely non-functional.

## Evidence

**Confirmed by direct source inspection:**

```
grep -rn '\.truncated' src/core/search.zig
```

Results:
- Line 224: `.truncated = false` (SearchReport init)
- Line 2780: `.truncated = false` (ShardReport init)
- Line 4237: `if (shard.truncated) report.truncated = true;` — reads from always-false shard value
- Lines 3143, 3850, 3858, 3870, 3964, 3972, 3982, 3991, 4015, 4022, 4041, 4049, 4857, 4865: `if (shard.truncated) break;` — 14+ dead break statements
- Lines 361, 397, 422, 1952, 4877: `if (report.truncated) break/return;` — dead checks on report-level

No assignment to `.truncated = true` exists anywhere in `src/`.

## Impact

1. **Performance:** When `--max-hits N` is specified, the scan continues reading and processing EVERY file in the corpus even after N hits are found. For a 100k-file corpus with `--max-hits 10`, the engine scans ~99,990 unnecessary files. The `under_request_limit` check at `search.zig:3927` prevents storing more hits, but the scan loop (file open, read, line-split, predicate-match) continues at full cost. This defeats the purpose of `--max-hits` as a latency control.

2. **Incorrect telemetry:** `report.truncated` is always `false`. The v2 output at `output.zig:461` (`if (report.truncated or report.matches_found > report.hit_count)`) only signals truncation via the `matches_found > hit_count` heuristic, missing the case when `matches_found == hit_count == max_hits` (where the limit was hit exactly).

3. **Dead code:** 14+ `if (shard.truncated) break;` statements are dead code that never trigger, adding branch overhead to every scan iteration.

4. **v3 cursor pagination correctness:** The `truncationReason` function (`agent_output.zig:148-153`) infers truncation cause from request shape, but the underlying `report.truncated` never fires. The `projection.state` field relies on `remaining > 0` which is computed from `matches_after_cursor - visible_count`, so cursor pagination itself works correctly (the re-scan skips cursor'd matches). But the early-exit optimization that should prevent scanning unnecessary files after the limit is hit does not work.

## Root Cause

The truncation signal was designed to allow early-exit from file scan loops when `max_hits` or `MAX_RETAINED_HITS` is reached. The break checks were placed throughout the scan loop, but the assignment `shard.truncated = true` was never implemented in `recordLineIntoShardImpl` or `recordLine`.

## Fix

In `recordLineIntoShardImpl` (`search.zig:3898`), after the hit storage block at line 3938, add:

```zig
if (!under_request_limit or shard.hit_count >= MAX_RETAINED_HITS) {
    shard.truncated = true;
}
```

This sets the flag when either the user's `max_hits` limit or the engine's `MAX_RETAINED_HITS` cap is reached. The existing 14+ `if (shard.truncated) break;` statements then activate, short-circuiting the scan loop.

**Caution:** This changes scan behavior — files after the hit limit are no longer scanned. This is the intended behavior (the break checks were designed for it), but it means `files_scanned` will decrease when `--max-hits` is set. This is correct — the agent should know that not all files were scanned when a limit is hit. The v3 `scan.state` should then report `partial_access` or a new `truncated_scan` state to distinguish "access errors prevented scanning" from "hit limit prevented scanning."

## Verification

```bash
# Before fix (current behavior):
ix search 'lit:fn' . --max-hits 1 --stats-only
# files_scanned will be > 1 (all files scanned despite limit)

# After fix:
ix search 'lit:fn' . --max-hits 1 --stats-only
# files_scanned should be small (scan stops after finding 1 hit)
```
