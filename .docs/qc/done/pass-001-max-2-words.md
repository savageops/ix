# QC Pass 001 — Max-2-Words

Date: 2026-07-13
Verdict: SUPERSEDED
Owner: IX repository + installed `ix.exe`

> This pass records the evidence available at its execution boundary. A subsequent adversarial maintainer review disproved its output-contract conclusion. See [`pass-002-strict-maintainer.md`](pass-002-strict-maintainer.md). Passing builds and the warm/cold parity sample remain valid evidence; they do not clear the confirmed pagination, coverage, cursor-identity, and parity-proof defects.

## Gate proof

| Gate | Result |
|---|---|
| Zig Debug | 506/506 tests passed |
| ReleaseSmall | Passed; 0 build errors |
| Output contract | Passed: framing, v2/JSON compatibility, UTF-8, spans, context, cursors, mutation, budgets |
| Warm/cold parity | Passed: identical evidence; 1000 → 100 scanned files; latest median 78.563 → 9.819 ms |
| Installed path | Output, warm/cold, grammar, help, exact inspect, and typed impossible-budget error passed after promotion |

## Boundary stress

- 4 MiB single-line file: exact hit retained; 1001 matches remained parity-identical at 1 and 32 threads.
- 1000-file corpus: 1001 matches; 1001 files scanned; no duplicate or missing evidence.
- 1400-byte v3 budget: 1275-byte complete envelope; one sentinel.
- 512-byte impossible budget: typed `ix.error.v1`/`output_failed` with `ByteBudgetTooSmall`.
- Binary corpus member: 0 false-positive matches.
- Strict grammar: empty operands, mixed `&&`/`||`, empty regex, malformed PCRE2 rejected before discovery.

## Performance envelope

Reduced 3-cold / 3-transition / 5-steady benchmark against the available Rust predecessor, with exact match parity but route-count mismatch:

- Literal `PM_RESUME`: Zig cold 1059.223 ms vs Rust 1043.945 ms, +1.46%.
- Word regex `PM_RESUME`: Zig cold 955.755 ms vs Rust 956.342 ms, −0.06%.
- Absent literal: Zig cold 1057.950 ms vs Rust 987.133 ms, +7.17%.
- Report: `.docs/reports/subzero-cold-decomposition-20260713-155900/summary.json`.

Interpretation: these timings are exploratory only. Zig reports 79,405 discovered / 79,402 scanned / 6 skipped versus Rust 79,395 / 79,392 / 3; the predecessor also omits access-error telemetry. No row is decision-grade until route parity is explained or the corpus is normalized.

## Findings and actions

1. Fixed stale benchmark command using rejected `--json --stats-only`; diagnostic benchmark now uses `--json`.
2. Fixed untyped impossible-budget failure; output failures are framed and typed.
3. Preserved warm/cold parity and exact evidence; no lane regression observed.
4. Fisheye applies to compact search previews only; exact inspect/context bypass it intentionally.
5. Diversity quotas and semantic chunking remain deferred; no labeled evidence justifies a default.
6. Tightened the benchmark harness: unknown telemetry, match mismatch, or route mismatch now marks rows invalid and excludes them from performance summaries.

## Residual watch

- Explain or normalize the predecessor route-count mismatch before using any timing delta; rerun absent-literal on a clean host with larger samples afterward.
- Keep warm and cold parity gates mandatory for every scan or index change.
- Do not promote diversity/chunking without next-read accuracy and reconstruction evidence.

## State

- Repository branch: `develop-subzero`.
- Repository commit: `5879c2ed` (`fix: gate benchmarks on parity evidence`).
- Installed SHA-256 (`ix.exe`, `iex.exe`): `B882907DE285A648A7F0A2B73D3AB7C44B7D3C19B0F4B6F3035839DAD0C2A9F3`.
- Promotion backup stamp: `20260713T140408171Z`.
- User-owned `.zcode/` remains untracked and untouched.
- `.docs` is ignored by repository policy; this QC artifact is intentionally local and durable.
