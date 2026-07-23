# IX Loop State Capsule

Updated: 2026-07-23

## Current objective

Run Goal 001 as a results-led architecture improvement loop. Establish only
enough repository and runtime truth to select one high-value measurable result,
then reconstruct the affected command, planning, discovery, indexing, scan,
resource, output, retrieval, protocol, platform, build, test, and installed
stages. Architecture and review depth scale only to the blast radius needed to
deliver and protect that result without correctness, resource, or performance
regression.

## Active loop

- Goal: `.docs/goals/001-benchmark-trust-and-route-portfolio.md`
- Doctrine: `.docs/qc/ix-perpetual-ascent.md`
- Latest documentation verdict: broad architecture goal revised and validated.
- Reviewer doctrine: full-path adversarial review is now mandatory; changed lines
  define mutation location, not blast radius.
- Result doctrine: research, review, tests, benchmarks, and refactoring are
  supporting evidence, never substitutes for a proven before/after outcome.
- Runtime verdict: unchanged by the documentation-only doctrine round.
- Warm-index containment verdict: ordinary search no longer launches indexd;
  physical generation GC and pre-publication per-root disk admission are wired.

## Verified state

- `min` is present as a native command and was promoted through the canonical
  installed path after focused compaction proof; the prior capsule statement
  that it was removed is superseded.
- The repository and installed executables most recently verified at SHA-256
  `373EF49DDB2A810BEA0240F65967D89DBA2A64F4EB3900603EAAF39199C2AF23`.
- The latest retained full-suite result remains partial rather than green;
  warm-cache and Thompson NFA failures require fresh owner-level verification.
- The current warm-index evidence in the 600-item report is not
  promotion-admissible because cold and warm-enabled result coverage diverged.
- Current MCP source advertises tools that are not all dispatched through
  `tools/call`; MCP completeness and runtime transport behavior remain unproven.
- Pending todo chains include performance, input-policy, discovery, refs, and
  compaction work whose live relevance must be reconciled before execution.
- Current source review exposed priority seams the capability matrix must keep
  visible: `search.run` owns multiple routing and execution phases, MCP lists
  tools not all dispatched by `tools/call`, index freshness behavior differs by
  platform, and index telemetry retains explicit `not_wired` defaults.
- A scoped semantic duplicate probe across `src/main.zig` and `src/core/mcp.zig`
  found no embedding-level duplicate candidates; the concern is behavioral
  request/projection divergence, which requires route-parity review rather than
  textual deduplication.
- The recurrence probe published three generations under a 1 MiB test envelope
  and retained exactly two. Warm-enabled ordinary search created no daemon and
  no index state. The 4 GiB default root cap is configurable through
  `index_disk_limit_mb` / `IX_INDEX_DISK_LIMIT_MB`.
- The broad test runner is still not green: 442/455 passed, with unrelated
  warm-cache and Thompson-NFA failures/crashes retained as explicit debt.

## Completed round: bounded index lifecycle (2026-07-23)

The four bounded-lifecycle gaps identified in the prior next-action are closed:

1. **Volume free-space floor** — `enforceDiskFreeFloor` checks actual volume
   headroom via `GetDiskFreeSpaceExW` (Windows) / `statfs` syscall (Linux/macOS)
   before any publish, complementing the existing self-quota budget. Configurable
   via `IX_INDEX_DISK_FREE_FLOOR_MB`, defaults to 512 MiB. Prevents ENOSPC
   mid-publish which corrupts generations.

2. **Startup/temp cleanup** — `reconcileIndexState` runs before the first
   publish in every mode. `sweepTempStaging` removes orphaned `tmp/<epoch>/`
   staging directories from prior crashes. `processDeferredDeleteLedger`
   retries epochs that failed GC deletion.

3. **Suspension/status accounting** — `IndexerStatus` enum (`active`,
   `degraded`, `suspended`) with `writeIndexerStatus` persisting to
   `indexd.status`. The serve/watch loops now degrade on transient compaction
   failure instead of killing the process. After 3 consecutive failures the
   loop suspends for 30s backoff, then retries. The prior generation stays
   valid during degraded state.

4. **Deletion retry semantics** — `collectGenerationGarbageWithRetry` wraps
   the GC in best-effort catch: if `deleteTree` fails (e.g. Windows reader
   holding a handle), the epoch is logged to `deferred-delete.ledger` and
   retried on next startup reconciliation instead of aborting the compaction
   loop.

Evidence: 8 new tests all pass. Full suite: 442/455 pass (was 434/447 baseline).
Zero regressions — the 13 pre-existing failures (warm-index + Thompson NFA) are
unchanged. ReleaseFast builds cleanly.

## Next action

Replace watcher-triggered full republication with coalesced content-identity
deltas. The write side currently re-indexes the entire corpus on every file
change; the read side already has delta overlay support
(`prepareDeltaWarmIndexFrontier`). The writer needs to emit true incremental
deltas keyed by content hash, not full snapshots. Do not re-enable automatic
daemon ownership.
