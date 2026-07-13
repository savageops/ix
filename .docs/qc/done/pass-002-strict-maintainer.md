# QC Pass 002 — Strict Maintainer

Date: 2026-07-13
Verdict: FAIL — CONTRACT REPAIR REQUIRED
Owner: IX output, pagination, discovery, and benchmark contracts

## Maintainer verdict

IX has a strong output architecture and preserved warm/cold search evidence, but it is not contract-complete. Adversarial runtime proof found one P1 pagination defect and three P2 truth defects that the 506-test suite does not cover. `ix.result.v3` and `ix.similar.v2` are the right destination structures; neither should become the default until their budget, cursor, discovery, and coverage invariants are repaired.

## Evidence status

| Gate | Status | Maintainer reading |
|---|---|---|
| Zig tests | PASS | 506/506; insufficient coverage for the confirmed defects |
| ReleaseFast | PASS | Build succeeds |
| ReleaseSmall | PASS | Build succeeds |
| Warm/cold evidence | PASS | Sampled evidence parity held; the gate remains mandatory |
| Output contract | FAIL | Byte-budget pagination can omit a fitting page |
| Semantic coverage | FAIL | Discovery failures can be reported as complete coverage |
| Cursor identity | FAIL | Ambiguous framing; semantic ranking input omitted |
| Benchmark parity | INCOMPLETE | Aggregate counts do not prove identical evidence or binary identity |
| Error boundary | PARTIAL | Typed framing is not consistently owned across commands |

Green builds prove compilation and covered behavior. They do not override a reproducible contract counterexample.

## Confirmed defects

| Priority | Defect | Proof | Required repair |
|---|---|---|---|
| P1 | Non-monotonic byte-budget pagination | Serialized page sizes measured `920 → 1658 → 1446 → 1551` bytes. At `--max-bytes 1500`, one hit was returned although three fit. | Replace monotonic binary search with an exact bounded selector. Prove maximal fitting prefixes across adversarial escaping, grouping, and telemetry shapes. |
| P2 | False-complete semantic coverage | Candidate discovery silently returns on `statFile` and `openDir` errors; coverage only considers omitted candidates and later read errors. | Use the canonical discovery owner or return typed discovery outcomes. Any inaccessible or unvisited scope must make coverage partial. |
| P2 | Weak cursor identity | Variable-length fields are raw-concatenated without domain or length framing; similar cursors omit `anti`. | Hash a versioned, domain-separated, length-prefixed canonical request. Include every ordering, filtering, ranking, and projection input. |
| P2 | Weak benchmark parity | The harness compares aggregate match/discovery/scan/error counts only. Equal totals can hide different files and hits. | Gate on binary SHA-256, exact evidence digest, exact file-set digest, route identity, and telemetry availability before timing is accepted. |
| P3 | Split output-failure handling | `search` owns typed output failure framing; `matches`, `inspect`, and other writers can still escape through direct `try`. | Centralize command output failure translation and test broken-pipe, impossible-budget, encoding, and writer failures for every output owner. |
| P3 | Windows relative-path inconsistency | `r` works while reproduced `./r` and `.\r` forms fail with `search_failed/FileNotFound`. | Normalize accepted path forms once at argument lowering and test equivalent Windows spellings. |

## Search response structures

| Surface | What is good | Better/default posture | Remove or clean |
|---|---|---|---|
| `text` + `ix.result.v1` | Readable hits; stable terminal summary; appropriate for a person at a terminal. | Keep as the human/TTY default. | Do not use as the agent or pipe default. Avoid extending the legacy sentinel with new semantics. |
| `--agent` / `ix.result.v2` | Compact file grouping, short fields, low repetition, fisheye previews. | Keep as a compatibility bridge. Move the `--agent` alias to v3 only through an explicit versioned migration. | Remove as an independent canonical contract after v3 adoption; do not maintain two permanent agent schemas. |
| `agent-v3` / `ix.result.v3` | Best structure: separated verification, scan, and projection state; exact spans and source windows; route, cursor, and budgets. | Make this the canonical agent default after P1 pagination and cursor repairs. Keep bounded output as the default. | Remove the non-monotonic sizing assumption and any duplicated v2-only projection logic. |
| `--json` full report | High-fidelity telemetry is valuable for debugging, profiling, and compatibility. | Keep explicit as a full/debug surface. A future `json-debug` name may be clearer, but only through migration. | Never make it routine agent output; trim duplicated derived fields where compatibility permits. |
| `json-compact` | Pure raw v3 JSON; no sentinel; strongest script/MCP structure. | Make this the canonical machine-JSON surface after v3 repairs. Stdout must remain one JSON value. | Remove any path that adds prose, sentinels, or stderr-like diagnostics to JSON stdout. |
| `files` | Useful low-cost projection for composition. | Keep as newline-delimited paths only. | Remove the appended v1 terminal sentinel after a declared compatibility window; summary belongs on stderr or behind an explicit flag. |
| `count` | Useful per-file aggregation. | Keep as a pure count projection with one documented record grammar. | Remove the appended v1 terminal sentinel after migration; align `search` and `matches`. |
| `stats` | Useful diagnostic and benchmark projection. | Keep as an explicit diagnostic surface with one framed or raw-JSON contract. | Stop treating it like a list projection; eliminate overlapping telemetry encodings where no compatibility consumer requires them. |

## Command response structures

| Command | Current value | Default | Improve | Clean or remove |
|---|---|---|---|---|
| `search` | Canonical discovery-to-output path; richest bounded contracts. | Human: `text`. Agent: v3 after repair. Machine: `json-compact` after repair. | One output dispatcher, one error boundary, exact maximal byte pages, stable cursor identity. | Retire v2 as a canonical peer and remove mixed sentinels from pipe projections. |
| `matches` | Valuable record-only composition primitive using the search engine. | Keep record-only text for pipes; JSON must be pure JSON. | Define a deliberately narrow format matrix and share writer/error ownership with `search`. | Do not add agent envelopes or pagination here. Remove redundant format aliases that serialize identically without a distinct contract. |
| `inspect` grouped | Exact bounded context plus explicit continuation; correctly bypasses fisheye. | Keep grouped for interactive/agent reading. | Make continuation a stable structured object or opaque cursor while preserving readable next-action guidance. | Do not force search previews or search envelopes onto exact inspection. |
| `inspect --format records` | Clean `path:line:text` composition form. | Keep for pipes. | Guarantee record-only stdout and consistent encoding/error behavior. | Remove any future summary/sentinel mixing. |
| `inspect --json` | Proper programmatic exact-window report. | Keep for programs. | Align status, continuation, and error vocabulary with the common contract primitives. | Avoid duplicating search-only telemetry. |
| `similar` text | Useful human ranking view. | Keep as the human default. | Surface coverage limitations plainly. | No change until discovery truth is repaired. |
| `ix.similar.v1` | Compact compatibility response. | Compatibility only. | Provide migration guidance to v2. | Deprecate and remove after v2 proves coverage and cursor correctness. |
| `ix.similar.v2` / raw compact v2 | Correct destination shape: coverage, cursor, exact whole-file coordinates. | Canonical agent/machine structure after repair. | Canonical discovery, truthful partial coverage, request-complete cursor identity. | Remove the parallel silent discovery implementation and legacy JSON duplication. |
| `ix.error.v1` | Typed machine-recognizable boundary on stderr. | Keep one universal error envelope. | Require stable status, reason/code, message, and actionable recovery for all commands. | Remove per-command ad hoc writer failure paths and unframed machine errors. |

## Fisheye decision

Fisheye is correctly an output projection, not a scan behavior. It should remain default for compact search and similarity previews, where long-line token reduction has clear value. It must not apply to exact inspection, exact context windows, JSON source spans, file lists, counts, or stats. The structure must expose exact match coordinates independently of the contracted preview so an agent never mistakes a lens for source truth.

## Canonical defaults after repair

1. Human terminal: `search` text and `similar` text.
2. Agent search: framed `ix.result.v3`, bounded by default.
3. Machine search: raw `json-compact` v3, one JSON value on stdout.
4. Full diagnostics: explicit full JSON/stats, never the routine default.
5. Pipes: record-only `matches`, `files`, `count`, and inspect records.
6. Exact reading: inspect grouped or inspect JSON, never fisheye.
7. Failures: one typed stderr envelope with non-zero exit status.

## Keep, migrate, remove

### Keep

- `ix.result.v3` and `ix.similar.v2` as the destination contracts.
- Text defaults for humans.
- Raw compact JSON for programs.
- Record-only projections for shell composition.
- Exact inspect as a distinct capability.
- Fisheye for compact previews only.
- Mandatory warm/cold evidence parity and installed-binary verification.

### Migrate

- `--agent`: v2 compatibility to v3 canonical behavior.
- Similar v1 and legacy JSON: toward similar v2.
- Full `--json`: toward an explicitly diagnostic identity if ambiguity causes misuse.
- Files/count: mixed legacy terminal report to pure projections.

### Remove or consolidate

- Parallel semantic discovery with silent error swallowing.
- The binary-search assumption over serialized page size.
- Raw-concatenated cursor fingerprints and incomplete request identity.
- Indefinite dual canonical agent schemas.
- Appended sentinels in pipe-oriented list output.
- Per-command output error translation.
- Benchmark acceptance based only on aggregate counts.
- Redundant structures that differ in name but not in semantic contract.

## Performance and lane protection

The prior cold comparison remains exploratory: route counts differed, predecessor telemetry was incomplete, and aggregate parity was insufficient. No performance decision may use those rows. Every repair must preserve both lanes:

- Cold and warm runs must return identical ordered evidence for the same request.
- Warm reuse must never bypass mutation, request-identity, error, or coverage checks.
- Cold remains the source-of-truth fallback; warm is an optimization of the same contract.
- Performance claims require same-corpus, same-request, exact evidence, route, binary, and host-quality proof.
- A correctness repair is not licensed to add per-hit allocation, hot-loop synchronization, or duplicate discovery work.

## Closure order

1. Replace byte-budget page selection and add adversarial maximal-prefix tests.
2. Collapse semantic discovery into the canonical owner or introduce typed discovery outcomes.
3. Version and fully frame search and similarity request fingerprints.
4. Centralize output writing and typed failure translation.
5. Normalize Windows relative paths at the argument boundary.
6. Strengthen benchmark parity with evidence, file-set, route, and binary digests.
7. Run Debug, ReleaseFast, ReleaseSmall, warm/cold parity, cursor mutation, installed-binary, broken-pipe, and maximum-boundary suites.
8. Repeat the strict review against the installed SHA before promotion.

## Exit criteria

- For every tested byte budget, v3 returns the largest fitting prefix or a typed impossible-budget error.
- Discovery denial or failure produces partial coverage with an attributable reason.
- A cursor is rejected when `anti`, expression boundaries, paths, filters, ordering, budgets, or projection semantics differ.
- Warm and cold lanes produce identical evidence and failure semantics across present, absent, regex, compound, mutation, and error cases.
- Files/count/records stdout contains only their documented records.
- JSON stdout parses as exactly one JSON value.
- Every command emits the same typed machine error contract on output failure.
- Benchmark rows are invalid unless binary identity, exact evidence, file set, route, and required telemetry match.
- All tests and both optimized builds pass against the exact binary promoted to the installed path.

## State

- Branch at review: `develop-subzero`.
- Reviewed repository commit: `5879c2ed` (`fix: gate benchmarks on parity evidence`).
- Reviewed installed SHA-256: `B882907DE285A648A7F0A2B73D3AB7C44B7D3C19B0F4B6F3035839DAD0C2A9F3`.
- User-owned `.zcode/` remained untouched.
- `.docs` is ignored by repository policy; this audit is intentionally local and durable.
