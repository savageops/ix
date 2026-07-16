# QC 3/4 — executable proof and ship boundary

Date: 2026-07-16

## Findings

- Blocking: size reduction cannot prove value. The acceptance matrix now requires labeled-fact recall, omission damage, coordinates, peak memory, runtime, and deterministic repeatability.
- Blocking: human and JSON paths could drift. One `MinReport` and one canonical sizing/serialization owner now feed both projections.
- Blocking: success-shaped partial stdout would violate CLI automation. Minimum-envelope and serializer failures now require empty stdout plus `ix.error.v1` on stderr.
- Major: adding MCP before the CLI contract is proven would multiply an unstable surface. MCP is explicitly deferred unless implemented and tested in the same round.
- Major: the previous full-suite baseline contains unrelated warm-cache/NFA failures. Regression proof must report targeted green separately from the known wider boundary.
- Major: installed-path proof and rollback preservation are required because the user consumes the promoted binary, not only `zig-out/bin`.

## Verdict

PASS. Spec 158 is implementation-ready; production mutation may begin with slice 1.
