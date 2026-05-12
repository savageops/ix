# Regex Decomposition Fast Count After Gate

Date: 2026-05-12

Workload:

```text
search "re:Sherlock\s+Holmes" E:/Workspaces/01_Projects/01_Github/iEx/.refs/ripgrep/benchsuite/subtitles/en.sample.txt --stats-only --json --threads 8
```

Comparator medians:

| Lane | Runs | Median total ms | Median scan ms | Median work ms | Matches | Regex counted | Candidate lines |
|------|------|-----------------|----------------|----------------|---------|---------------|-----------------|
| Zig before | 5 | 119.2934 | 118.8648 | 118.4818 | 30 | 0 | 0 |
| Zig after | 5 | 34.7509 | 34.4350 | 31.6458 | 30 | 1 | 78 |
| Rust IX after | 5 | 43.8883 | 43.8702 | 43.6502 | 30 | 1 | 78 |

Result:

- Zig after versus Zig before: `70.87%` median total reduction.
- Zig after versus Rust IX after: `20.82%` lower median total time.
- Correctness parity held: all lanes returned `matches_found=30`.
- The patched Zig binary now reports active decomposition telemetry: `eligible_files=1`, `counted_files=1`, `candidate_lines_checked=78`, `candidate_lines_matched=30`.

Artifacts:

- Raw comparison JSON: `.docs/reports/regex-decomposition-fastcount-2026-05-12-after/comparison.json`
- Fresh Zig after samples: `.docs/reports/regex-decomposition-fastcount-2026-05-12-after/zig_after-*.json`
- Fresh Rust IX samples: `.docs/reports/regex-decomposition-fastcount-2026-05-12-after/rust_ix-*.json`
- Pre-change baseline samples: `.docs/reports/regex-decomposition-fastcount-2026-05-12-baseline/zig_before-*.json`
