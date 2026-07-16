# QC 1/4 — bounded compaction problem and ownership

Date: 2026-07-16

## Findings

- Blocking: the inherited intelligent-compactor reads whole files and its aggressive levels lost exact symbols and coordinates; direct inheritance would violate the oversized-file objective.
- Blocking: an earlier parser-only `min` tag had already broken exhaustive dispatch and was correctly removed. The new plan must land parse, dispatch, executor, output, help, tests, and docs coherently.
- Blocking: “low/med/high” had no objective loss contract. The plan now defines low as unique-preserving exact dedup only and makes med/high visibly lossy.
- Blocking: an output content budget alone permits unbounded JSON metadata. The plan now binds complete stdout bytes and requires serializer preflight.
- Major: `inspect`, `xo`, and `similar` already own exact, query-guided, and semantic lanes. The new owner is restricted to query-free whole-document projection.

## Verdict

PASS after repair in spec 158. The problem is real, ownership is non-overlapping, and prior failure mode is explicitly barred.
