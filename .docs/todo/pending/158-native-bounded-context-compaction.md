---
id: 158-native-bounded-context-compaction
type: implementation-spec
status: active
priority: P0
owner: cli-command-spine
date: 2026-07-16
canonical_owner: src/core/min.zig
adjacent_owners:
  - src/cli/args.zig
  - src/cli/output.zig
  - src/main.zig
  - src/core/resource_profile.zig
  - src/core/inspect.zig
research: .docs/research/2026-07-16-bounded-context-compaction.md
goal: .docs/goals/002-ix-min-context-compaction.md
source_request:
  - "ix inherited a feature from the dupe audit skill called ix similar."
  - "im thinking of a ix minify (min) command for use when files are too big, and instead of trying to read large text files, minify can be used on low, med or high"
  - "ix min med c://abc..."
  - "this inherited form intelligent compactor skill but you need to studfy it firt to tell me if thsi is worth it or not"
  - "start a goal with at least 12 paragraphs of doctrine. and mention for research, source proof (citation), proving knowledge is valuable, and aligned with what the arch expects"
  - "use a file instead"
---

# Native bounded context compaction

## Verdict

The command is worth implementing as a narrow, query-free reading projection. It fills the gap between exact paginated `inspect` and query-guided `xo`, provided it remains extractive, byte-attributable, deterministic, bounded by the shared allocator and output budget, and visibly lossy whenever unique units can be omitted. The inherited intelligent-compactor profiles are evidence, not an implementation dependency: its conservative exact/template deduplication is useful, while its aggressive whole-file scoring demonstrated unacceptable symbol and coordinate loss.

## Contract

`ix min [LEVEL] FILE` compacts one regular text file. `LEVEL` is `low`, `med`, or `high`; `--level LEVEL` is the canonical flag form and the optional positional level is retained as the short command requested by the user. `--max-bytes N` bounds the complete stdout payload, not only retained content. `--format text|json` selects a human projection or the stable `ix.min.v1` machine envelope. Defaults are owned by `src/core/min.zig`: low 32768 bytes, med 16384 bytes, high 8192 bytes. An explicit budget below the minimum truthful envelope fails before stdout is written.

The command is read-only and accepts exactly one file. Directories, stdin, recursive packing, output-file mutation, network calls, model providers, and hidden subprocesses are outside this surface. `inspect` remains the exact follow-up owner. `xo` remains query-guided. `similar` remains semantic ranking. Persistent index compaction is unrelated and must not share the public noun without qualification.

Retained content is copied byte-for-byte from the source. Each retained unit includes one-based start/end lines and zero-based start/end byte offsets. Every omitted source range is represented by an omission record containing its coordinates, input bytes, unit count, and reason. The result carries a SHA-256 of the exact input bytes. Original source order is restored after selection.

`low` is conservative: it may remove verified byte-identical units and normalize only output framing whitespace; it may not omit unique units. If the unique complete units and truthful metadata do not fit, the command returns `min_budget_too_small` with a suggested minimum or a lower-fidelity level. `med` and `high` may omit unique units after hard-preserve admission and therefore always report `lossy:true` when any unique unit is absent. No level substring-cuts a retained unit.

## Native pipeline

1. Preflight the path, regular-file status, size, and output budget. Reject NUL-bearing/binary input, invalid UTF-8, and arithmetic overflow with typed errors. Compute an adaptive target unit size from file size and `MAX_UNITS = 65536`, with a 4 KiB floor. This keeps metadata input-independent while retaining line boundaries.
2. Pass one streams through a fixed read buffer under the framework allocator. It computes SHA-256, exact line coordinates, structural-unit metadata, a bounded lexical-frequency sketch, a 256-bit feature signature, and a 128-bit duplicate-candidate digest. Units prefer blank-line, heading, declaration, and record boundaries; the adaptive target groups adjacent complete lines. A pathological line remains one complete unit.
3. Duplicate admission groups matching digest and length. Equality is proven by chunked positional byte comparison before a unit is marked duplicate. Digest equality alone can never remove content.
4. Hard-preserve classification is syntactic and explainable: headings/declarations, obligation or negation terms, paths/URLs, command/flag forms, hashes, numeric metrics/formulas, error/status markers, and first/last document units. It is a floor, not a claim of semantic understanding.
5. Soft score is a saturating integer tuple: structural role, bounded lexical rarity, obligation density, identifier density, numeric/path/error evidence, source-boundary prior, and duplicate penalty. Med/high greedily add the greatest marginal score per exact rendered byte, subtracting overlap against selected 256-bit signatures. Stable ties resolve by source offset. Selection is returned to source order.
6. The canonical serializer preflights exact escaped/rendered byte length, including metadata, omission sentinels, delimiters, and final newline. It drops only soft-selected units until the payload fits. If protected units plus the minimum truthful envelope exceed the budget, it returns `min_budget_too_small`; it never truncates stdout.

## Typed model

- `MinLevel = enum { low, med, high }`
- `MinFormat = enum { text, json }`
- `MinRequest { path, level, max_bytes, format }`
- `SourceRange { start_byte, end_byte, start_line, end_line }`
- `UnitClass { heading, declaration, paragraph, record, block, long_line }`
- `OmissionReason { exact_duplicate, budget, low_marginal_value }`
- `MinUnit { range, class, digest, feature_bits, score, hard_preserve, duplicate_of }`
- `MinOmission { range, input_bytes, units, reason }`
- `MinReport { schema, path, source_sha256, level, lossy, complete, input_bytes, input_lines, max_bytes, output_bytes, retained_bytes, retained_units, omitted_bytes, omitted_units, units, omissions }`

`complete` means the source traversal and accounting completed, not that lossy output contains every source fact. JSON enum values are stable lowercase strings. Human output starts with a compact provenance header, emits `@@ lines START:END bytes START:END CLASS` before each exact block, and uses `… omitted lines START:END bytes=N units=N reason=REASON …` between retained blocks. JSON is the sole stdout content in JSON mode; diagnostics go to stderr as `ix.error.v1`.

## Errors

- `min_missing_file`: provide one file path.
- `min_multiple_files`: run one file per invocation.
- `min_invalid_level`: use `low`, `med`, or `high`.
- `min_invalid_budget`: provide a positive decimal byte count.
- `min_not_file`: point to a regular file.
- `min_binary_input`: use an exact binary-aware tool; compaction accepts text.
- `min_invalid_utf8`: transcode explicitly before compaction so byte provenance remains honest.
- `min_unit_limit`: the adaptive unit planner could not represent the source within the fixed metadata ceiling.
- `min_resource_limit`: the framework-wide allocator ceiling was reached.
- `min_budget_too_small`: raise `--max-bytes` or choose a lossier level; include the minimum truthful size when calculable.
- `min_read_failed`: include the path and underlying operation class without leaking internals.

## Architecture challenge contracts

- Why a command rather than an `inspect` flag: `inspect` answers exact coordinate requests; query-free whole-document evidence selection has different loss semantics, profiles, schemas, and failure modes. Folding it into `inspect` would blur exact and lossy truth.
- Why not reuse `xo`: `xo` requires a query and ranks spans against it. A fabricated empty query would create an undocumented mode and weaken its relevance contract.
- Why two passes: stable whole-document rarity, duplicate proof, and budget selection require corpus evidence before emission. Two sequential passes preserve bounded memory and avoid whole-file materialization.
- Why no Tree-sitter baseline: the current adapter is Zig-only, parses whole strings, and deliberately refuses files above 1 MiB in adjacent use. It can become an optional bounded adapter later; generic complete-line units are the only honest cross-format baseline.
- Why fixed metadata: allocator caps alone make failure host-dependent. `MAX_UNITS` plus adaptive grouping supplies a deterministic structural bound before shared-allocation enforcement.
- Why no model: learned deletion introduces weights, tokenizer drift, nondeterminism, dependencies, and non-attributable fragments. The command’s value is reliable evidence reduction, not fluent rewriting.
- Live-data reflex: no push delivery is useful for a one-shot immutable projection. File watching would broaden the owner and is rejected.
- Deployment reflex: no new runtime dependency, provider, state directory, or network path is introduced. The existing single-binary build and promotion graph remains canonical.

## Execution slices

1. Command and schema spine: typed request/profile/result, parser/help/completion, dispatch, error mapping, empty/minimum serializer tests.
2. Streaming source model: preflight, UTF-8/binary validation, SHA-256, adaptive complete-line segmentation, coordinates, fixed metadata ceiling.
3. Evidence and deduplication: hard-preserve features, bounded rarity/signatures, digest candidate grouping, exact positional equality proof.
4. Selection and rendering: low exact-only behavior, med/high marginal selection, omission coalescing, exact whole-payload byte budgeting, human and JSON projections.
5. Product surface and proof: README/SKILL, representative corpus harness, intelligent-compactor comparison, installed-path promotion, ledger reconciliation.

## Test ledger

1. Parses `ix min med path`.
2. Parses `ix min path --level med` to the same request.
3. Defaults omitted level to `med`.
4. Rejects unknown level with accepted values.
5. Rejects missing path.
6. Rejects a second path.
7. Rejects zero, negative, malformed, and overflowing byte budgets.
8. Help lists all levels, defaults, formats, and examples.
9. Bash, Zsh, Fish, and PowerShell completions include `min` and its flags.
10. Empty file returns a truthful bounded envelope.
11. One newline-terminated unit preserves exact bytes and coordinates.
12. A final non-newline unit preserves exact bytes and line count.
13. CRLF input preserves source bytes and one-based line ranges.
14. Invalid UTF-8 returns `min_invalid_utf8` with empty stdout.
15. NUL-bearing input returns `min_binary_input` with empty stdout.
16. Directory input returns `min_not_file`.
17. A multi-megabyte single line is never substring-cut.
18. Adaptive grouping never exceeds `MAX_UNITS` on a many-line fixture.
19. Unit-limit/resource failure reports incomplete work as an error, not a summary.
20. Input SHA-256 matches an independent hash probe.
21. Retained byte offsets reproduce each emitted block exactly.
22. Low removes byte-identical repeated units.
23. Equal digest plus unequal bytes does not deduplicate.
24. Low retains every unique unit or fails budget-too-small.
25. Med/high mark unique omission as lossy.
26. Negation-bearing requirement is hard-preserved.
27. Path, URL, command, and flag forms are hard-preserved.
28. Hash, metric, formula, error, and status evidence are hard-preserved.
29. First and last document units are hard-preserved.
30. Protected material exceeding budget fails instead of truncating it.
31. Marginal selection chooses distinct evidence over repeated high-score boilerplate.
32. Stable ties resolve by source offset.
33. Final retained units remain in source order.
34. Adjacent omissions with the same reason coalesce without hiding coordinates.
35. Human output includes provenance, range headers, and visible omission sentinels.
36. JSON conforms to `ix.min.v1` and contains no ANSI or prose prefix.
37. `output_bytes` equals actual stdout bytes including final newline.
38. Both formats stay at or below explicit `--max-bytes`.
39. Too-small minimum envelope writes no partial stdout.
40. Repeated runs produce byte-identical human and JSON output.
41. Low/med/high ordering yields non-increasing output targets and non-decreasing admissible loss.
42. Exact `inspect` follow-up for every retained range matches emitted bytes.
43. Read permission and mid-read failures map to `min_read_failed` without success output.
44. Allocation fault injection reaches `min_resource_limit` without leaks.
45. Representative Zig, Markdown, JSONL, log, generated, and low-redundancy fixtures meet labeled-fact floors.
46. Comparison harness reports preservation, damage, bytes, runtime, and peak memory for native profiles and intelligent-compactor profiles.
47. ReleaseSmall and ReleaseFast builds remain network-free.
48. Existing inspect/xo/similar parser and behavior tests remain unchanged and green within their known baseline.

## Acceptance gates

- Research gate: 13 decision-changing sources, three source classes, six pinned competitor repos, and anatomy ledger are present and provenance-verified.
- QC gate: planning passes 1/4, 2/4, and 3/4 have distinct recorded findings and all blocking findings are resolved before production mutation.
- Correctness gate: all 48 feature tests pass; retained bytes and coordinates reproduce source exactly; no hash-only deduplication.
- Resource gate: memory is bounded by fixed metadata plus the shared allocator; stdout never exceeds `--max-bytes`; failure output is typed and non-partial.
- Value gate: med improves required-fact density over bounded sequential inspection on at least four representative classes, and no profile is selected by compression ratio alone.
- Regression gate: targeted tests, full suite with existing unrelated failures separated, ReleaseSmall/ReleaseFast builds, help/completion probes, and installed binary smoke pass.
- Surface gate: README and `SKILL.md` agree with executable help. MCP remains unchanged unless a real bounded tool is implemented and tested in the same round.

## Rollback

If preservation or budget truth fails, remove the complete public command spine together: tag, request, parser, dispatch, output/help/completion, docs, and tests. Do not leave a parser-only command or refusal stub. Reference research and falsification fixtures may remain because they document why the surface was rejected.
