# QC Pass 003 — Output Contract Matrix

Date: 2026-07-13
Status: COMPLETE — CLOSED BY PASS 007
Inputs: six independent maintainer reviews at effort `x1`, `x2`, `x3`, `x4`, `x5`, and `x20`

## Consolidated verdict

Pass 002 was directionally correct. This pass added two confirmed format defects, one shared coverage-truth defect, and several precision corrections. The executable repairs and proof gates are recorded in Pass 007; this file remains the historical contract matrix.

## Confirmed additions

| Priority | Finding | Current behavior | Required action |
|---|---|---|---|
| P2 | `search --format files/count` is not pure | `search` appends a v1 terminal report after records when hits exist and emits a full report on zero hits; `matches` remains record-only. | Add zero/nonzero/truncated tests. Migrate to pure records only after a separate summary channel preserves total/truncation truth. |
| P2 | `matches --format stats` is a silent accepted format | Argument parsing accepts it; the command switch emits nothing. | Either reject it before execution or emit a defined stats structure. Do not retain a silent no-op. |
| P2 | Coverage truth is shared, not only similar-specific | v3 scan state and full JSON status derive primarily from access-error totals; discovery omissions, policy skips, and unvisited scopes can be absent or falsely complete. v3 access-error detail is serialized as `{}`. | Introduce a typed coverage taxonomy: complete, partial, inaccessible, policy-skipped, omitted, and unvisited. Propagate attributable counts/reasons through SearchReport, v3, full JSON, and similar. |
| P2 | Schema proof is too shallow | Existing checks emphasize framing/substrings more than parse-level success and failure contracts. | Add parser/schema tests for v3 and similar v2, including partial coverage, provider/discovery failures, truncation, cursor mismatch, and zero-hit cases. |

## Corrected descriptions

| Topic | Correct statement |
|---|---|
| Fisheye | Applies to search hit previews, including text, v2, v3, and legacy JSON projections. It does not apply to similarity path/score output or exact inspect/context windows. |
| `--json` | Search full JSON is raw one-value JSON with debug telemetry. It is machine-readable but intentionally verbose; `json-compact` is the smaller v3 machine contract. |
| v3 evidence | v3 provides exact coordinates and preview-window metadata; do not describe it as carrying source-byte spans unless bytes are actually emitted. |
| Similarity continuity | Inspect’s `ix.next.v1` argv hints are a separate exact-reading continuation structure; align vocabulary where useful, but do not force inspect into the search cursor schema. |
| Errors | Standardize the envelope (`status`, stable reason/code, message, recovery) while preserving command-specific semantics and recovery actions. |
| Benchmark parity | Evidence/file-set/route/binary digests are a proof requirement and parity gap, not by themselves a newly demonstrated engine regression. Define canonical ordering and digest version before enforcing it. |

## Current-to-target matrix

| Command / format | Current stdout grammar | Framing | Fisheye | Best target/default | Cleanup |
|---|---|---|---|---|---|
| `search text` | Human hit records + report | v1 report | Yes for previews | Human default | Keep legacy semantics; do not expand it into agent protocol. |
| `search --agent` | Usually v2; context/bytes/cursor can force v3 | v2/v3 sentinel | Yes for previews | Versioned migration to v3 | Do not silently flip consumers; publish alias/deprecation window. |
| `search agent-v3` | Framed v3 JSON | Sentinel | Yes for previews | Canonical bounded agent output after repairs | Fix page sizing, coverage, cursor, and truthful scan detail. |
| `search json` | Full raw JSON report | None | Yes for hit previews | Explicit debug/full machine output | Keep verbose; add parse/schema tests. |
| `search json-compact` | Raw compact v3 JSON | None | Yes for previews | Canonical machine JSON after repairs | Must remain exactly one JSON value plus newline. |
| `search files/count` | Records plus report, including zero-hit report | Mixed | No | Pure records with explicit summary channel | Remove contamination only after preserving truncation totals. |
| `search stats` | Diagnostic report | v1 framing | No | Explicit diagnostic projection | Keep distinct from list projections. |
| `matches text/files/count` | Records only | None | Text previews as applicable | Pipe composition default | Keep narrow and record-pure. |
| `matches stats` | No output | None | No | Reject or implement | Silent accepted format is forbidden. |
| `inspect grouped` | Exact windows, headers, next hints | inspect/next sentinels | No | Human/agent exact reading | Preserve separate continuation; test stdout purity. |
| `inspect records` | `path:line:text` records | None | No | Pipe default | Keep record-only. |
| `inspect json` | Structured exact report | None | No | Programmatic exact reading | Align envelope and continuation fields. |
| `similar text` | Human paths/scores | Human | No | Human default | Surface partial coverage. |
| `similar agent-v1` | Compact legacy result | Legacy | No | Compatibility only | Deprecate after v2 migration. |
| `similar agent-v3` / compact v2 | Framed or raw v2 | Sentinel/raw variant | No | Canonical similarity machine output after repair | Repair discovery coverage and complete cursor identity. |
| Errors | Command-dependent stderr paths | Inconsistent | No | One envelope, command-specific code | Centralize writer failure translation without flattening semantics. |

## Required executable test matrix

For every output owner, assert stdout purity, stderr error framing, exit status, and JSON parseability for zero hits, one hit, multiple hits, truncation, impossible budget, writer failure, discovery denial, stat/open/iterate failure, policy skip, binary skip, mutation, and warm/cold equivalence. Test cursor changes to expression, paths, filters, ordering, anti-expression, projection, budget, and schema version. Include `files/count` search versus matches, `matches stats` rejection or implementation, v3 access-error detail and scan state under partial coverage, and framed/raw schema parsing for search and similarity.

## Default decisions after repair

Human: text. Agent: v3 after explicit migration. Machine JSON: raw `json-compact`. Full diagnostics: explicit `json`/stats. Pipes: record-only formats. Exact source reading: inspect. Fisheye: previews only. Errors: typed stderr envelope with non-zero status.

## New QC artifact decision

This file was the only new QC artifact warranted by the six reviews. Passes 004 through 007 supplied the implementation and fresh proof, so this matrix is closed and retained as historical design evidence.
