---
id: pass-007-maintainer-closure
type: qc
category: closure
status: complete
date: 2026-07-13
scope: "QC passes 001-006 plus multi-agent synthesis"
---

# QC Pass 007 — Maintainer Closure

## Decision

IX now uses one explicit model: scanning establishes canonical retrieval truth; output formats project that truth for a consumer. A display limit never masquerades as a scan limit. Exact inspection never masquerades as a compact preview. Warm and cold routes must emit the same evidence identity before their performance is comparable.

This matches the strongest predecessor and competitor logic. The Rust IX predecessor scans, sorts, then truncates retained hits without changing `matches_found` (`iEx/crates/iex-core/src/engine.rs:478-515`) and tests that invariant directly (`:3062-3080`). Sourcegraph's stream contract likewise separates match events, progress/skipped reasons, alerts, and terminal completion. The useful pattern is separation of facts, not imitation of a competitor's field names.

## Remediated

| Area | Closure |
|---|---|
| Byte budgets | Maximal fitting whole-record prefix is proven despite non-monotonic cursor size; impossible budgets return `byte_budget_too_small` with recovery. |
| Context sizing | Source files are streamed once into a context cache; sizing probes reshape cached exact windows and perform no repeated file I/O. |
| Inspect memory | Removed three 1 GiB `allocRemaining` paths. Arbitrary-length lines stream through one reusable buffer; returned lines alone are retained. Large inline report and scratch arrays moved off stack. |
| JSON integrity | One JSON-string owner escapes every C0 control byte and invalid UTF-8 byte; v3 routes through it. Black-box control-byte JSON parsing is covered. |
| Cursor identity | Request fields and paths are length-framed; `similar --anti` participates; corpus records use stable integer encoding. Cursor OOM is no longer mislabeled as invalid input. |
| Similar coverage | Discovery/stat/open/iteration failures are counted and force partial coverage. Candidate corpus identity is length-framed. Early-return list storage is released. |
| Record projections | `files` and `count` are pure stdout record streams. They reject incomplete retained evidence instead of appending a contradictory envelope. `matches --stats-only` is rejected. |
| Output errors | Search, matches, inspect, and explain failures cross typed `ix.error.v1` boundaries; JSON error fields are escaped. |
| Path parity | Repeated `./` and `.\\` prefixes normalize through one CLI owner across search, similar, and inspect. |
| Projection truth | Agent telemetry no longer repeats scan coverage; `max_hits > MAX_RETAINED_HITS` is attributed to `retention_limit`, not `max_hits`. |
| OOM safety | Hit preview allocation failure cannot retain a borrowed scan-buffer slice. |
| Small-corpus warm evidence | Serial evidence builds now use the same cache writer as parallel builds, so small repositories populate the warm index instead of silently remaining cold. |
| Warm freshness | Windows warm reads require a live index owner. A dead `foreground_once` snapshot can no longer impersonate current evidence; persistent `indexd` mutation converges to exact cold-route evidence. |
| Dead surface | Removed `UnicodeCaseFoldPrefilterStats`, its hardcoded zero output, and unused `FallbackLineScanStats`. |
| Small correctness | `-n 0` compatibility lowering rejects zero; v2 distinct-file counting handles an empty path; similar cursor fingerprint covers `anti`. |
| Benchmark truth | Cold comparison now records binary SHA-256, canonical path/line/column/match-length evidence digest, ordered evidence digest, file-set digest, route parity, and binary-identity drift; mismatched rows are invalid. Preview presentation is intentionally excluded. |

## Rejected Findings

| Proposal | Disposition | Why |
|---|---|---|
| Stop scanning at `--max-hits` | Rejected | It destroys exhaustive count, stable cursor remaining-count truth, and parity with the predecessor's proven retention model. `max_hits` bounds projection, not verification. |
| Apply fisheye to inspect/context | Rejected | Search previews are lossy navigation. Inspect and requested context are exact evidence. Compaction requires a separate explicit future format. |
| Add semantic chunking now | Rejected | No labeled recall/cost benchmark proves a chunk boundary or overlap policy. Whole-file coordinates remain truthful. |
| Add result diversity now | Rejected | No task-labeled evidence proves a cap or reranking rule. Deterministic relevance order remains canonical. |
| Treat large by-value structs as proven memcpy | Rejected as unproven | Zig/LLVM may lower large aggregates indirectly. Context structs were made slice-backed where source showed real stack cost; SearchReport needs PMU/IR evidence before structural churn. |
| Content-hash every cursor page | Rejected | Size/mtime/file identity is the current low-cost filesystem snapshot. Full content hashing before every page would rescan the corpus and erase the value of pagination. |
| Triple-regex scan-loop emergency | Reclassified | Extra span work occurs only while materializing retained hits, bounded by retention, not for every counted match. Fuse only with measured retained-hit profiles. |
| Base64 cursor rewrite | Rejected | Opaque hex is deterministic and simple; a smaller token is not worth another decoder and migration boundary without budget evidence. |

## Output Structure Disposition

| Structure | Quality | Default / future |
|---|---|---|
| Human text | Good for terminals; intentionally mixed records plus terminal summary. | Default interactive search output. Do not infer an agent from a pipe. |
| `ix.result.v1` / full `--json` | Strong diagnostics and compatibility, expensive for agents. | Keep explicit for diagnostic consumers; no new features unless required for compatibility. |
| `ix.result.v2` (`--agent`) | Good token-minimal grouped navigation; lacks typed scan/projection separation and cursor budgeting. | Keep as explicit compact compatibility surface. Freeze it. |
| `ix.result.v3` (`--format agent-v3`) | Best bounded agent contract: exact match spans, scan/projection truth, byte budgets, recovery cursor, route facts. | Recommended agent default when the caller explicitly chooses an agent format. |
| `json-compact` | Same v3 semantics without sentinel framing. | Default for programs that require one raw JSON object. |
| `files` / `count` | Good composable record projections only when complete. | Keep pure; fail on incomplete retention. |
| `matches` | Good record-only command. | Text or raw JSON records only; envelope/stat formats remain removed. |
| Exact inspect | Good proof surface with bounded continuation and streaming memory. | Keep exact. Never silently fisheye. |
| Similar v2 | Truthful bounded candidate frontier with coverage and cursor. | Keep whole-file until chunking wins a labeled benchmark. |

## Proof Gates

- Debug: 513/513 tests.
- ReleaseFast: 513/513 tests; executable build passed.
- ReleaseSmall: 513/513 tests.
- Black-box output contract: pass, including control-byte JSON, framing, legacy compatibility, exact spans, UTF-8, context, cursor mutation, byte budgets, and impossible-budget recovery.
- Warm/cold parity: persistent daemon pass with exact v3 hit spans, previews, windows, scan state, errors, and projection eligibility; mutation converged from 1,000 scanned files to 101 with evidence identity equal.
- Warm/cold timing signal: median cold 78.142 ms, warm 10.232 ms. This is a lane-health probe, not a predecessor promotion result.
- PowerShell parsers: benchmark, output-contract, and warm/cold scripts parse cleanly.
- Formatting and diff hygiene: `zig fmt --check` and `git diff --check` pass apart from configured line-ending warnings.

## Residual Rule

Pass 008 opens after this repaired baseline is committed and pushed. It owns the explicit grouped/lens projection and deterministic `xo` insight-lane investigation; neither may weaken exact inspect, pipe-safe records, search parity, or the warm/cold performance gates.
