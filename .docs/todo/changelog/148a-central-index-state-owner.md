---
id: 148a-central-index-state-owner
parent: 148-central-index-state-owner
type: subtodo
phase: a
category: feature
status: done
source_message_anchor: U1,U2,U6,U7
source_message_excerpt: "use planning spec skill to lock it all in"; "AFTER using insect to research the arch, understand, align. and implement"; "Make sure you didn't slow the framework down"; "run some tests, on the ripgrep dataset. at least 12 each"
source_message_proof_obligation: "Use Insect before code, record baseline and benchmark gate, and align the change with existing warm-index ownership work."
next_todo: /todo/pending/148b-central-index-state-owner.md
---
# 148a Research / Baseline Lock

## Objective

Establish the state-owner repair before implementation: stale process files need owner validation and central storage; root traversal policy must stay separate from writable IX state; performance evidence must use the existing 12-sample ripgrep-corpus guard.

## Original User Message Proof

- U1: "use planning spec skill to lock it all in"
- U2: "AFTER using insect to research the arch, understand, align. and implement"
- U6: "Make sure you didn't slow the framework down"
- U7: "run some tests, on the ripgrep dataset. at least 12 each"

## Evidence To Record

- Insect search for stale PID/live-owner patterns.
- Insect search for ripgrep traversal/cache behavior.
- Baseline test result before implementation.
- Baseline benchmark result before implementation.

## Exit Criteria

- State owner direction is recorded as a prerequisite to `147`.
- No code change is required before the baseline/research evidence is captured.

## Evidence

- Insect stale-owner research: queried `engine --query "search index application data directory stale pid lock file design" --search-engines duckduckgo,bing,brave,google --format json --metadata`; results reinforced that stale PID/lock files need live-owner validation and cleanup semantics.
- Insect traversal/cache research: queried `engine --query "ripgrep ignore hidden directories cache index design appdata search tool" --search-engines duckduckgo,bing,brave,google --format json --metadata`; results aligned the design boundary: traversal policy belongs to scanned content, writable cache/index state belongs outside the scanned root.
- Baseline before code: `IX_INDEX=0 IX_NEXUS=0 zig build test --summary all` passed `330/330`.
- Prior ripgrep-corpus guard: `node tools/scripts/run-once-benchmark.mjs --profile suite-linux-word --expression 're:\bPM_RESUME\b' --corpus ... --threads 32 --warmup 2 --samples 12 --quiet` recorded IX engine `585.3455 ms`, CLI `604.2013 ms`, ripgrep `1066.1788 ms`, match count `9`.
