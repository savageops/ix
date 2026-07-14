# QC Pass 013 — Output, Cursor, Corpus, and Promotion Parity

Date: 2026-07-14
Scope: shipped CLI projections, bounded inspection, semantic/lexical insight lanes, heavy ripgrep corpus, benchmark helpers, and native promotion.

## Review provenance

Three independent subagents received the exact same review prompt at x2 effort. None edited files. Their consensus was merged with direct source probes and installed-binary probes. A fourth focused review was opened for the reproduced multi-file v3 cursor failure; its result must close before this pass is considered complete.

## Response structures

| Surface | Evidence | Good | Better | Default | Remove/clean |
|---|---|---|---|---|---|
| `records` / text | Exact query returned readable path:line:column records plus one terminal sentinel. | Pipe-safe, familiar, exact. | Keep terminal state compact and stable. | Keep for human/read-through compatibility. | Do not group paths; repetition is intentional statelessness. |
| `--agent` (`ix.result.v2`) | `lit:fn src --agent --max-hits 3` returned one path-grouped object with short `l/c/p` fields and explicit truncation. | Highest context density for ordinary agents. | Add only proven fields; preserve path-once grouping. | Agent-facing default when explicitly requested. | `--format agent-v2` is not a supported spelling; remove from docs/examples. |
| `--format agent-v3` | Returned canonical verification, scan completion, projection budget, cursor, compact stats, route, and grouped hits. | Strong machine contract and bounded envelope. | Fix the reproduced multi-file cursor false-stale path; consider renaming ambiguous `returned` only in a versioned contract. | Default for cursor/budget workflows. | Do not duplicate v2 as a second implementation. |
| `--json` | Full telemetry is valid and useful for diagnostics and benchmarks. | Complete provenance. | Keep opt-in; label count units. | Diagnostics/benchmark only. | Do not make it the agent default; repeated paths and zero-heavy telemetry waste context. |
| `--stats-only` | Full corpus scan is complete only without a hit cap. | Fast count path and no hit allocation. | Distinguish occurrence counts from matching-line counts. | Use for benchmark telemetry. | Reject `--stats-only` plus `--max-hits`/`--total-count`; a capped count is a lower bound and previously looked complete. |
| `inspect --range` | `1:32` returned literal lines. | Exact, deterministic evidence. | Add an explicit lens only if exact bytes remain recoverable. | Exact range. | Do not silently apply fisheye or accept undocumented `390:410...` syntax. |
| `xo` | Grouped ranked spans returned `ix.xo.v1`, bounded bytes, focus/score, and complete coverage on a small file. | Best current insight/context projection. | Make partial frontier coverage impossible to read as confident empty; keep lexical/structural provenance explicit. | Opt-in insight lane. | Never put it on the exact search hot path. |
| `similar` | Missing key returned typed `similar_requires_api_key`. | Honest remote capability boundary. | Add timeout/retry/privacy controls before broad use; expose whole-file/coordinate limitations. | Opt-in remote semantic lane. | Do not claim semantic truth or silently upload files. |

## Fisheye boundary

Fisheye is applied to search hit previews and XO spans. Plain inspect ranges remain literal. This is the correct boundary: context compression must not alter exact source evidence. Multi-range fisheye syntax is currently rejected with typed `inspect_failed InvalidRange`; keep that explicit until a real grammar and budget model exist.

## Heavy corpus evidence

Corpus: `E:\Workspaces\01_Projects\01_Github\iEx\.refs\ripgrep\benchsuite\linux` — 79,471 files on disk, 6.86 GB on disk; IX admitted/scanned 79,402 files and 1,340,828,181 bytes for the query below.

Query: `re:(?i)(ERR_SYS|PME_TURN_OFF|LINK_REQ_RST|CFG_BME_EVT)`.

- Promoted IX, 2-thread framework cap: 242 occurrences, 79,402 files, 1,340,828,181 bytes, engine `total_ms=3320.9`.
- Retained predecessor `AppData\ix\backups\ix.exe`, same query/corpus: 242 occurrences, same files/bytes, engine `total_ms=3445.1`.
- Current vs predecessor: current was about 3.6% faster in this single exploratory run; this is not a promotion claim by itself.
- `rg` uncapped: 242 matches / 241 matching lines, ~1.86 s wall time.
- `rg -j2`: 242 matches / 241 matching lines, ~6.45 s wall time. The equal-thread comparison favors IX; the uncapped comparison favors ripgrep. Reports must never collapse these envelopes.
- The 242-versus-241 difference is a unit difference: IX stats-only counts occurrences, while ripgrep’s matching-line statistic counts lines. Preserve the behavior, but label the unit or enforce a comparison mode before declaring parity.

## Contract repairs landed

1. Stats-only plus a hit cap now fails during parsing with `StatsOnlyOutputCapConflict` and a recovery hint. This removes the prior false-complete undercount path.
2. `--total-count` help now states that it is an output cap and aliases `--max-hits`; it is not a complete-scan count limit.
3. Benchmark helpers now fail when a process never starts instead of normalizing a null status to exit zero.
4. Ripgrep benchmarking resolves an executable path before Windows `ProcessStartInfo`; bare `rg` is no longer accepted as silent timing evidence.
5. Historical predecessor discovery now reads canonical `AppData\ix\backups` and retains the current install separately.
6. Native sync now builds ReleaseFast, rejects stale repo binaries, archives predecessors under `AppData\ix\backups`, and promotes only after cold/warm v3 parity probes.
7. `resource_policy` is now the truthful generic label `hardware_percent`; the effective default remains 5% memory and 5% threads, configurable through `~/.ix/config.json` and environment overrides.

## Native owner proof

- Live executable: `C:\Users\Savage\AppData\ix\ix.exe`.
- Mutable state: `C:\Users\Savage\.ix\` (`cache`, `index`, `config.json`).
- Predecessors: `C:\Users\Savage\AppData\ix\backups\` (76 files after migration and this promotion).
- Retired `AppData\Local\ix` and `AppData\Local\Programs\iEx\bin` paths are absent.
- Repo and native SHA-256: `0B4024B8411C5CF2135EA04664D038FD8A3C16698A0C36D7D6876256F9CED319`.

## Cursor finding and repair

The first installed probe exposed a real contract failure: stable v3 output entered parallel top-level discovery, whose workers shared the request arena while allocating discovered paths. The same static `src` tree alternated corpus signatures and continuation returned `stale_cursor`. Single-file roots were stable, and `--no-ignore` reproduced the issue, ruling out ignore semantics. Stable projections now force serial discovery; the search lane remains parallel. After promotion, repeated `src` pages emitted the same cursor and immediate continuation succeeded. Stale-corpus protection remains intact.

## Validation

- `zig build test -j1 -Doptimize=ReleaseFast`: passed.
- ReleaseFast build/install: passed.
- Stable v3 repeated-page and continuation probe: passed after the serial-discovery repair.
- `node --check` for changed scripts: passed.
- `zig fmt` for changed Zig files: passed.
- Installed exact search, v2, v3, inspect, XO, similar-key boundary, heavy corpus, predecessor, and ripgrep probes executed.

## Final disposition

Keep: exact records, compact v2 agent output, bounded v3, exact inspect, opt-in XO, opt-in remote similar, silent warm/cold parity.
Repair next: labeled count units, XO partial-coverage semantics, and semantic-lane timeout/privacy controls.
Do not add: implicit fisheye to inspect, public “warm mode,” a second agent-output implementation, or embeddings as exact-search authority.
