# QC Pass 009 — Native Response And Context Field Test

## Scope

Promote commit `9e62dbe1`, preserve the displaced native binary, then test the installed command as an agent-facing product across exact search, bounded records, grouped output, structured output, inspect, `xo`, warm/cold search, errors, path spellings, long lines, and strict byte/count envelopes.

## Promotion Receipt

- Previous native: `C:\Users\Savage\AppData\Local\Programs\iEx\bin\ix.old.130726.exe`
- Historical promoted native at time of pass: `C:\Users\Savage\AppData\Local\Programs\iEx\bin\ix.exe`; superseded by the canonical `C:\Users\Savage\AppData\ix\ix.exe` layout.
- Source build: `E:\Workspaces\01_Projects\01_Github\ix-zig\zig-out\bin\ix-zig.exe`
- Rollback naming contract: `.old.ddmmyy.exe`, resolved to `.old.130726.exe`.
- Previous hash: `B882907DE285A648A7F0A2B73D3AB7C44B7D3C19B0F4B6F3035839DAD0C2A9F3` (2,833,408 bytes).
- Final promoted/source hash after source-fresh rebuild: `C9864C7FC6241B272DFAA7E3E507EDEC866EC04A0B5E96CDC335F35465CBC818` (2,901,504 bytes). Installed and source hashes are identical.

## Live Findings

1. Promotion preserved a distinct rollback executable before replacing the native path.
2. The formerly failing `search ... --format records --total-count 300` command exits zero and returns 10 records plus one terminal result.
3. `records` and `text` are byte-identical aliases: 1,017 bytes for six hits. This is useful compatibility, but advertising both as peer formats makes the surface look larger than the capability set.
4. `agent` v2 is the smallest attributable search envelope in the sample (825 bytes), but truncation is terminal: it says `truncated:true` without a continuation cursor.
5. `agent-v3` costs 1,470 bytes versus v2's 825, but earns the difference with scan/projection separation, eligible/returned/remaining counts, typed truncation reason, cursor, exact match length, and fisheye window coordinates.
6. `json-compact` is the clean programmatic default: the same v3 contract without sentinel framing (1,450 bytes). Full `json` is 5,809 bytes and should remain opt-in diagnostics.
7. `files` and `count` reject `--max-hits`; the failure is safe, but the generic error does not explain that these exhaustive projections are incompatible with a hit-retention limit.
8. `matches --format records` is the leanest pipe surface in the sample (602 bytes): six independent records, no result envelope. It is excellent for downstream text tools but carries no completeness state.
9. Search fisheye works: the 358-byte parser line contracts around `--fixed-strings`, retains the match, and marks right elision plus the exact represented byte window.
10. Search `--context 2` is highly useful: v3 keeps compact hit previews while adding exact coalesced source windows with explicit `match|context` roles. This is a stronger default for one-round agent navigation than plain records when the caller can afford the envelope.
11. Inspect grouped output is the strongest human exact-reader default: path once, numbered lines, exact range, emitted count, EOF state, and a copyable continuation command.
12. Inspect records repeat the full path on every line. That is undesirable for direct reading but correct for stateless pipes; it must not replace grouped output.
13. Inspect JSON is exact and easy to consume, but its uncompressed `{line,text}` repetition is expensive. It is an evidence format, not a token-minimal agent default.
14. `inspect --range ... --total-count ...` returns typed `IncompatibleBounds`. The safety is good; the recovery is poor because the error does not identify the conflicting flags or suggest `--limit`/a narrower range.
15. `inspect --expr ceiling --context 2 --total-count 30` reported `emitted=31`. Context-block integrity may explain the overshoot, but `total-count` reads as a hard cap. The contract or implementation must change; silent +1 violates caller expectations.
16. `xo` retrieved the native-install synopsis, hash/backup function, Windows-only guard, and final receipt in one 4 KB call. This is a real round-trip reduction over `similar -> inspect -> retry`.
17. `xo` correctly exposes `candidate=bm25_line`, `structural_prior=true`, `semantic=false`, coverage, files/bytes/lines read, candidate count, budgets, exact spans, focus lines, scores, and omission counts. It does not pretend lexical retrieval is semantic truth.
18. `xo` on the framework-cap query found the canonical owner plus enforcement consumers in `indexd`, search discovery, telemetry, and the typed resource-limit error. Fragmented long-distance spans were substantially more useful than a fixed range.
19. Natural-language weakness is material: “waits for file changes differently on Windows versus Unix” ranked three unrelated `fileTimeToUnixNs` spans and Windows watchers, missing the decisive non-Windows `io.sleep`. Adding exact identifiers recovered the correct span, but three of four results still went to declarations/helpers. Current BM25-line retrieval is identifier-sensitive, not semantic.
20. `similar` could not participate because no API key is configured. Its typed `similar_requires_api_key` error is honest and actionable; no semantic-quality claim is possible from this run.
21. `xo` byte budgets are tight in practice: JSON samples requested at 2,000/4,000/8,000 bytes measured approximately 2,000/3,989/7,991 raw bytes before the capture shell's trailing newline. More budget expands context rather than changing the command grammar.
22. Invalid format and invalid flag failures are structured and stderr-only, but both collapse to `UnsupportedFlag`. This loses the offending token, accepted values, and recovery action—the largest remaining pipeline ergonomics defect.
23. Search help lists canonical formats from the owner table, but the option list omits `--format`, `--context`, `--max-bytes`, `--cursor`, and the new `--total-count`. The detailed prose knows the features while the scannable options section hides them.
24. Installed resource telemetry reports the shared 10,168,898,150-byte allocation ceiling. An explicit `-t 128` remains clamped by the framework owner rather than bypassing it.
25. The first promoted artifact was hash-identical to `zig-out` but source-stale: `output.zig` had been formatted three minutes after the build. The benchmark freshness gate rejected it. Promotion must compare the binary mtime/hash against every tracked source after all formatting and before copying; source/build identity alone is insufficient.
26. The repository benchmark lane was broken by `--json --stats-only` becoming a conflicting format pair. The apparent duplication is intentional orthogonality: JSON selects serialization while stats-only disables hit collection. The parser now lowers either order to raw JSON telemetry with `hits:[]`, retaining benchmark semantics and avoiding a second writer.
27. An exit-zero compatibility attempt that lowered the pair to framed stats was still wrong: the benchmark expected raw JSON and failed parsing. Owner-path validation corrected the contract; smoke success was not accepted as completion.
28. The preserved old binary also rejects `--json --stats-only`, so the current comparison harness cannot measure it without changing the historical artifact or its invocation. A manual paired lane used the shared `--stats-only` contract and parsed the v1 sentinel for both binaries.
29. Exploratory three-pair ripgrep Linux-corpus regex comparison retained exact parity (242 matches, 79,402 scanned files every run). Median engine time improved from 3,112.6961 ms old to 2,873.0919 ms promoted, a 7.7% improvement. Sample depth and host controls are insufficient for strict retention evidence, but the result disproves an immediate catastrophic regression.

## Response Structure Matrix

| Surface | Strong | Pain point | Default disposition |
|---|---|---|---|
| Search records | Familiar, independent, pipe-safe. | Repeats paths; v1 sentinel dominates small results. | Human/Unix compatibility only; `text` should be documented as alias. |
| Search v1 terminal | Compact scan receipt and zero-match truth. | Mixed records + sentinel needs two parsers. | Preserve for compatibility, not new agents. |
| Search agent v2 | Smallest grouped attributable envelope. | Truncation has no continuation; weaker verification. | Default only for tiny one-shot retrieval. |
| Search agent v3 | Complete scan/projection truth, cursors, fisheye coordinates, context. | More envelope bytes; sentinel framing. | Canonical agent default. |
| Search JSON | Full diagnostics and provenance. | 4x v3 sample size; telemetry overwhelms hits. | Explicit debug/stats only. |
| JSON compact | Canonical v3 without framing. | Less terminal-friendly. | Programmatic default. |
| Inspect grouped | Exact, readable, path once, continuation. | Heading is slightly ceremonious for tiny reads. | Human/agent exact-read default. |
| Inspect records | Stateless and composable. | Path repeats every line. | Pipe-only explicit format. |
| Inspect JSON | Exact structured evidence. | Verbose line objects; no compact schema. | Programmatic exact reader. |
| `xo` grouped | Best one-round narrative; gaps and focus visible. | Scores add noise; lexical misses can look persuasive. | Human/agent insight default with retrieval disclosure. |
| `xo` JSON | Excellent provenance, coverage, budgets, exact spans. | No continuation or marginal-gain explanation. | Programmatic insight default. |
| Error v1 | Typed, versioned, stderr-only. | Generic `UnsupportedFlag` and opaque bound conflicts. | Keep schema; repair diagnostic payload. |

## Gates

- [x] Installed hash equals repository build hash.
- [x] Exact formerly failing command exits zero.
- [x] Full Debug suite passes after the compatibility repair; the new JSON/stats regression passes under ReleaseSmall.
- [x] Output-contract suite passes against installed `ix`.
- [x] Warm/cold mutation parity passes against installed `ix` (1,000 -> 101 files, identical evidence).
- [x] Cross-platform compile matrix was green before promotion (Linux/Darwin, x86_64/AArch64).
- [x] Context usefulness was judged from native-install, resource-policy, CLI-owner, and platform-watcher retrieval tasks.
- [x] Limits remain exact: inspect now shares one remaining-line budget across every context report; the original expression/context probe emits exactly 30 lines.
- [x] Strong points, weak points, defaults, and removal candidates have transcript evidence.

## Priority Actions

1. **P0 — exact inspect cap:** decide and encode whether context blocks may exceed `--total-count`; preferred behavior is never exceed the named hard cap, with omitted partial blocks surfaced explicitly.
2. **P0 — diagnostic ownership:** error v1 must include the offending argument/value and a safe suggestion. `UnsupportedFlag` without provenance is structured opacity.
3. **P1 — help parity:** generate the search option list from the same command specification as parsing, including `--format`, `--total-count`, `--context`, `--max-bytes`, and `--cursor`.
4. **P1 — `xo` ranking:** add phrase/identifier normalization, proximity, call-neighborhood, and cross-branch structural evidence before adding remote semantics. Penalize duplicate helper shapes and declaration-only spans when a concrete branch/body exists.
5. **P1 — `xo` continuation:** JSON needs a request-bound continuation or explicit terminal reason when relevant candidates remain beyond `max_spans`/`max_bytes`.
6. **P1 — native promotion gate:** enforce source freshness, tests, output contract, warm/cold parity, rollback creation, copy, installed/source hash equality, and installed smoke in one transaction-like script.
7. **P2 — format surface:** document `text` as an alias of `records`, not a separate capability. Keep v1/v2 for compatibility; recommend v3 for agents and JSON-compact for programs.
8. **P2 — benchmark compatibility:** benchmark builders should own an explicit stats serialization contract instead of relying on two legacy flags whose relationship was undocumented.

## Final Validation State

- Installed output contract: pass.
- Installed warm/cold mutation parity: pass; identical match/evidence projection across 1,000 -> 101 files.
- Formerly failing records/total-count command: pass after final promotion.
- Full Debug suite: pass after parser repair.
- Targeted ReleaseSmall JSON/stats regression: pass.
- Full ReleaseSmall suite: pass; 522/522 tests completed in 214.9 seconds. The former 120/180-second timeouts were compile-duration assumptions, not test-runner failure.
- Native/source SHA-256 identity: pass.
- Old rollback executable remains untouched and independently hash-addressable.

## Disposition

Pass 009 is complete. Exact inspect limits, argument provenance, parser-owned help, `xo` intent normalization/proximity/deduplication, explicit projection termination, format guidance, benchmark serialization ownership, and transaction-like native promotion now have direct tests or live proof.

## Remediation Receipt

- Inspect applies one hard `total-count` budget across files and fragmented context windows; unit and native probes both prove the ceiling.
- Error v1 retains its stable envelope while adding `argument` and `hint`; incompatible inspect bounds use a specific code and recovery syntax.
- Search help is generated from the parser-owned option table. `text` is explicitly an alias of `records`; v3 and JSON-compact remain the recommended agent/program surfaces.
- `xo` adds weighted intent aliases, neighborhood convergence, branch/body preference, duplicate-helper rejection, and `eligible/remaining/reason/selection_limit_reached` projection truth.
- Benchmark scripts import one `IX_STATS_JSON_FLAGS` owner rather than independently reconstructing the raw-JSON/no-hit-retention wire contract.
- Native sync verifies source freshness, the full ReleaseSmall gate when building, v3 serialization, warm/cold evidence parity, staged hash identity, `.old.ddmmyy[.N].exe` rollback rotation, installed smoke, and rollback-on-failure.
- Debug suite passes. Full ReleaseSmall passes 522/522. A real isolated install transaction preserved exact hashes on both aliases.
- A final tight-budget native probe caught and repaired a missing `spans` array closure in `xo` JSON. The serializer now has a real JSON parser regression, and the 2,000-byte installed response parses with 1 byte to spare.
- Final response-contract artifact SHA-256 was `8A65178047A679F6A051BC9FE342BC9D04F42EE710AE5DD168EEE3180C18FD48`. The sole live Windows executable now resides at `~/AppData/ix/ix.exe`; the obsolete alias and every predecessor reside under `~/AppData/ix/backups/`, while mutable state resides under `~/.ix/`.
