---
id: pass-011-ripgrep-dataset-experience
type: qc
category: runtime-benchmark-and-output-review
status: complete
date: 2026-07-13
scope: "IX search, inspect, xo, output contracts, and predecessor comparison on the ripgrep Linux benchsuite"
corpus: "E:/Workspaces/01_Projects/01_Github/iEx/.refs/ripgrep/benchsuite/linux"
---

# QC Pass 011 — Ripgrep Dataset Experience

## Decision

The pipeline is useful and operational, but this pass does **not** qualify a runtime promotion. IX produced correct, compact agent output and useful ranked context on the 6.6 GB / 79,440-file Linux corpus. The search lane is, however, materially slower than ripgrep for this workload, and the benchmark evidence is exploratory because the host is under heavy memory-compression load and the runs are intentionally underpowered. Preserve the output-contract wins; repair the benchmark owner and search/index route before treating a speed result as release evidence.

## Commands exercised

All commands used the installed `C:/Users/Savage/AppData/ix/ix.exe` with an isolated `IX_STATE_DIR` under `.zig-cache/qc-ripgrep-experience-001`.

```text
ix search 'lit:EXPORT_SYMBOL' <ripgrep-corpus> --format records --total-count 10
ix search 'lit:EXPORT_SYMBOL' <ripgrep-corpus> --agent --total-count 10
ix search 'lit:EXPORT_SYMBOL' <ripgrep-corpus> --json --total-count 3
ix inspect <largest-header> --range 1:20 --format records
ix xo 'EXPORT_SYMBOL AMD register mask' <ripgrep-corpus> --max-bytes 3000 --max-spans 6
```

The largest non-index file was `drivers/gpu/drm/amd/include/asic_reg/dcn/dcn_3_2_0_sh_mask.h` at 24,167,513 bytes.

## Runtime observations

1. `search --format records` completed successfully in roughly 4–5 seconds for `EXPORT_SYMBOL`, emitted the requested ten records, and reported 35,582 total matches. `--total-count` limits emitted hits; it does not stop the scan or reduce the work reported in telemetry.
2. Record output is pipe-safe and preserves independent attribution, but repeats the full path on every hit. That repetition is correct for a stateless record stream; it is not the compact agent contract.
3. `search --agent` is the best context-density result observed. It emits `ix.result.v2`, groups hits by path, uses short fields, elides duplicate paths, and marks `truncated:true`. Ten hits occupied a single compact envelope while retaining line, column, preview, expression, counts, and status.
4. `search --json` is exact and richly diagnostic, but it is not an agent default. It repeats `path` and `absolute_path` for every hit and includes a large mostly-zero telemetry tree. Keep it for programmatic/debug consumers, not context-constrained model input.
5. JSON telemetry exposed useful truth: `files_discovered=79,405`, `files_scanned=79,402`, `matches_found=35,582`, `bytes_scanned=1,340,828,181`, `thread_limit=2`, `resource_policy=hardware_5_percent`, and `postings_index.fallback_reason=not_wired`. The last field explains why this corpus search is a full scan rather than an indexed admission path.
6. `inspect --range 1:20` is clear, exact, and path-once grouped. It does not apply fisheye contraction, which is correct for exact inspection. Fisheye belongs to search hit previews; applying it to `inspect` would silently destroy source evidence.
7. `xo` returned six ranked, fragmented spans under a 3,000-byte cap and declared `retrieval=bm25_line`, `assembly=degree_of_interest`, `files_read=1024`, `bytes_read=6,938,876`, `candidates=1,486`, `coverage=partial`. This is high value per output byte, but the partial coverage is important: the result is a bounded lexical retrieval, not a corpus-wide semantic truth.
8. The XO query intentionally included `EXPORT_SYMBOL AMD register mask`, yet the top spans were mostly documentation matches around register/mask terms rather than exact export-symbol code. This is a useful ranking signal, not a failure: the output makes related context discoverable, but semantic reranking or code-aware passage scoring is needed before calling it “similar.”

## Performance evidence

### Installed versus repository binary

The corrected same-profile run used matching SHA-256 binaries (`35E34800C65F1445F60131F2693D71B3FD443949047D63B622E8860FFE0F901C`, 2,909,696 bytes). Its three-sample medians were:

| Lane | Median |
|---|---:|
| ripgrep CLI | 59.4 ms |
| installed IX engine | 3,026.1 ms |
| repository IX engine | 2,985.9 ms |

The observed 1.33% difference is identity noise, not promotion evidence. The report correctly rejected it because the route was `both_unsupported`, samples were below the strict 12-sample floor, identity controls were underpowered, and the host had a 20–21 GB Memory Compression working set.

The earlier six-sample run also caught a real measurement hazard: the repository binary was 11.8 MB ReleaseFast while the installed binary was 2.9 MB ReleaseSmall. That report is invalid for a runtime claim. Binary size, SHA, build profile, route, and match parity must be hard preconditions before comparing timings.

### Current binary versus predecessor

The historical harness was first run against `C:/Users/Savage/AppData/ix`; it selected no predecessor because it only scans that directory for `ix.exe.backup-*`. The enforced layout stores predecessors in `C:/Users/Savage/AppData/ix/backups`. Rerunning against the canonical backups directory selected `backup-2026-06-30T19-36-32-721Z`.

That exploratory three-sample comparison observed:

- current IX median engine: 3,177.4 ms;
- predecessor median engine: 3,438.8 ms;
- observed current improvement: 7.60% (paired median 9.38%, all three paired current wins);
- match parity: true;
- route: `both_unsupported`;
- strict evidence: false because of host load, underpowered samples, and underpowered identity control.

This is a promising scan-phase signal, not a release claim. The report also showed discovery was not consistently better and order-stratified starts were not all net-positive. Repeat with the full 12-sample gate on a clean host before promotion.

The ripgrep comparison is stark: approximately 59–61 ms versus 2,986–3,177 ms for this expression, or about 49–53× faster for ripgrep. This is not yet an apples-to-apples route comparison (`both_unsupported`), but it is too large to dismiss as noise. The search lane currently scans about 1.34 GB with the postings/catalog indexes explicitly `not_wired`; indexed admission, mmap/scan policy, and benchmark route parity are the highest-value investigations.

## Response-structure disposition

| Structure | Keep | Better | Default | Remove / clean |
|---|---|---|---|---|
| `records` | Stateless, pipe-safe, independently attributable | Keep path repetition documented as a contract | Explicit pipelines and shell composition | Do not add grouping state to records |
| `json` | Exact coordinates and complete diagnostics | Version the envelope; split diagnostics behind an opt-in flag | Tests, integrations, debugging | Remove derived duplicate paths from any future compact mode |
| `agent` / `ix.result.v2` | Best density; path-once grouping; fisheye previews; truncation truth | Preserve `cwd`, status, counts, and explicit truncation; add only measured fields | Agent-facing search default | Do not leak the full stats tree into this mode |
| `inspect` grouped | Exact source, path once, readable | Keep it literal and deterministic | Human source reading | No fisheye or relevance filtering |
| `xo` | Ranked, budgeted, fragmented context with coverage metadata | Add semantic/code-aware reranking only behind measured recall and cost gates | Opt-in insight lane until retrieval quality is labeled | Do not call BM25 “embedding” or “truth”; do not hide partial coverage |

## Highest-value actions

1. Repair the historical benchmark owner to resolve predecessors from the canonical `AppData/ix/backups` path (or accept an explicit backup root). Add a fixture test proving non-empty selection under that layout.
2. Make binary identity a hard preflight: same optimization profile, size/build ID/SHA, target architecture, and route/match parity. Abort comparison before timing if any identity check fails.
3. Add a clean-host admission requirement or record a reproducible override for Memory Compression and other resident-workload failures. Never promote from exploratory reports.
4. Run the full 12-sample predecessor and installed/repository gates with balanced order, at least three identity-control samples, and the exact same corpus/expression. Preserve the report JSON as evidence.
5. Investigate why `postings_index` and `catalog_index` are `not_wired` on this corpus. A search engine that is tens of times slower than ripgrep must first prove whether it is taking the intended indexed route or an accidental full-scan fallback.
6. Keep the search lane speed-focused. Spend context and CPU in `xo`/similar only when the output increases decision value; do not move semantic retrieval into the hot search path without a measured contract.
7. Add a bounded “emitted versus scanned” note to help output consumers understand that `--total-count` is an output cap, not a work cap.
8. Preserve comments explaining why `records`, `agent`, `inspect`, and `xo` differ. These are intentional boundaries, not redundant formats.

## Residual risks

- The corpus is 6.6 GB and contains a nested `.ix` directory; every benchmark must isolate state and exclude accidental index reuse or contamination.
- The current 5% framework memory budget is approximately 10.2 GB on this host because the host reports roughly 203 GB RAM. IX itself stayed around 24–49 MB resident in these runs, but the budget is framework-wide and should remain visible in evidence.
- The observed historical win is below the requested strict confidence envelope. It is a candidate for further investigation, not permission to promote.

## Evidence files

- `.docs/qc/bench-installed-001-small.json` — same-binary installed/repository exploratory report.
- `.docs/qc/bench-installed-001.json` — invalid earlier report with ReleaseFast/ReleaseSmall identity drift; retained as a harness lesson.
- `tools/reports/historical-speed/latest-historical-speed.json` — predecessor exploratory report selected from `AppData/ix/backups`.

**Pass result: output contracts are valuable and compact; search performance and predecessor evidence are not yet release-grade.**
