# Performance Lead Objective

## Goal

Build IX-Zig into the search engine that is difficult to beat without copying its architecture: cold path wins, warm path wins, protected-tree correctness wins, and repeated-search ergonomics wins.

## Retention Rule

A speed slice is retained only when measured evidence proves one of these states:

- It creates a new lead and does not break existing parity or correctness gates.
- It creates a new lead while regressing another lane, and a follow-up refinement recovers that lane before commit.
- It preserves an existing lead while eliminating a correctness, freshness, or protected-tree failure.

Discarding a slice is allowed only after bounded refinement attempts fail to recover the regressed lane or the slice violates a core invariant.

## Commit Rule

Commit after every captured lead with:

- Test proof: `zig build test --summary all`.
- Release proof: `zig build -Doptimize=ReleaseFast --summary all`.
- Hygiene proof: `git diff --check`.
- Benchmark proof against old IX and Rust IX for the affected lane.
- Dupe-audit proof for large or architecture-shifting code changes.

## Priority Order

1. Cold path: no warm state, no sidecar dependency, no cache assumption.
2. Warm path: live sidecar, generation-pinned postings, query-frontier reuse.
3. Protected trees: partial success with structured diagnostics instead of fatal aborts.
4. Broad parity: search, matches, JSON reports, stdout/stderr silence, hidden toggles.
5. Opportunistic micro-leads only after no obvious large weak lane remains.

## Regression Policy

If a retained candidate wins one lane and loses another:

- Do not immediately delete it.
- Identify the lost lane and isolate the mechanism.
- Try small refinements that preserve the winning lane.
- Re-run the gate after each refinement.
- Commit only after the combined frontier is stronger than the starting point.

## Current Frontier

Warm engine leadership is established for live query-cache reuse. Cold protected-tree leadership is established for `C:\Windows\System32` stats-only searches by rejecting volatile system stores before open and by constraining protected-root scans to text-like extensions. The next frontier is broadening that cold lead without weakening source-tree and large-corpus lanes.
