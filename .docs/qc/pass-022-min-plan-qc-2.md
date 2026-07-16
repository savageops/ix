# QC 2/4 — architecture and adversarial contract

Date: 2026-07-16

## Findings

- Blocking: a naive unit vector grows with line count even when file bytes are streamed. The plan now fixes `MAX_UNITS` and derives adaptive line grouping from source size.
- Blocking: digest equality is not duplicate equality. The plan now requires chunked positional byte comparison before omission.
- Blocking: hard-preserve material can exceed the budget. The plan now returns `min_budget_too_small` instead of cutting or silently dropping protected units.
- Major: the current Tree-sitter owner is Zig-only and whole-string based, so it cannot be the generic oversized-file path. It is deferred to an optional adapter.
- Major: “preserve critical knowledge” was too broad to prove. The plan narrows it to explicit syntactic evidence classes and requires labeled-fact testing.
- Major: invalid UTF-8 replacement would sever byte provenance. Invalid encoding is now a typed boundary.

## Verdict

PASS after repair in spec 158. The core algorithm has deterministic bounds, collision safety, and honest failure behavior.
