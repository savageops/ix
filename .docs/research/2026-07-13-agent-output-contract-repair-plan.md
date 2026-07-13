---
type: research
status: implemented-and-promoted
date: 2026-07-13
scope: IX agent-facing search, inspect, similar, and output contracts
---

# IX Agent-Native Output Contract Repair Plan

## Decision

This revision keeps the high-value parts of the transcript-derived plan and removes prescriptions that current source or runtime evidence does not support. The critical path is not a new scan engine. It is a truthful, bounded, reconstructable projection over the existing engine: exact inspection remains exact; compact previews become explicit; truncation becomes typed; continuation becomes stable; telemetry becomes intentional; and installed-binary promotion becomes an evidence gate rather than a copy step.

The plan is deliberately stricter than the earlier draft. A transcript observation is evidence that a consumer experienced something, not proof that IX caused it. A source default is not runtime truth when an environment merge can override it. A compact projection may omit visible hits, but it must say so and preserve a deterministic path to exact evidence. Positive hits may be canonically verified; an empty result is not automatically proof that no result exists under every ignore, access, index, expression, and binary condition.

## Current proof baseline

| Surface | Verified current state | Consequence |
|---|---|---|
| Installed command | PowerShell `ix` resolves to `C:\Users\Savage\AppData\Local\Programs\iEx\bin\ix.exe` and rejects `--agent` | Promotion is blocked until parity and release gates pass |
| Repository binary | `zig-out\bin\ix-zig.exe` emits one `ix.result.v2` envelope for `--agent` | Agent format exists in repo and is not installed |
| Duplicate output | 20 raw `System.Diagnostics.Process` child runs produced exactly one envelope each | Do not change IX buffering or add dedup logic without a raw-stdout reproduction |
| JSON | `--json` emits one raw JSON object, no sentinel; it includes `absolute_path` and full telemetry | `--no-sentinel` is redundant; changing existing JSON needs versioning |
| Search context | `search --context 3 --agent` has no context records and no continuation | The flag is a capability-truth defect |
| Inspect | Bounded UTF-8 file windows are exact and continuable | Exact inspect is the recovery authority, not another preview surface |
| Fisheye | Search hit construction calls `fisheyePreview`; inspect does not | Fisheye is a compact-search projection today, not a universal line transform |
| UTF-8 | Fisheye slices computed byte windows directly | Boundary-safe slicing needs an adversarial regression test and repair |
| Match span | Preview length is best-effort; regex can pass zero and compound expressions can use the first predicate length | “The full match is always visible” is not yet proven for every strategy |
| Status | `status` is derived from access errors | `ok` does not prove a negative result or untruncated projection |
| Index | Parser default is false, then `main.zig` applies `indexdEnabled(init)` | “Index is always disabled” is false and removed |
| Similar | Whole-file collection is bounded by file and byte constants before embedding | Latency is real evidence; a hard lexical gate would introduce recall risk |
| Tests/build | Fresh gate: `zig build test -j1` and `zig build -j1 -Doptimize=ReleaseSmall` passed under Zig 0.16.0 | This is the pre-plan baseline, not proof of unimplemented actions |

## What great looks like, why it matters, and the actions

### Action 1: Preserve two explicit reading contracts

Great means the agent can distinguish retrieval from evidence. `search --agent` returns compact, lossy previews optimized for choosing the next file. `inspect` returns exact bounded lines optimized for proving what the file says. Do not fisheye plain inspect windows, center a no-match range on arbitrary whitespace, or silently turn an exact reader into a summarizer. Add an explicit compact inspect projection only if measurements show that it reduces total task cost while retaining exact continuation.

### Action 2: Make compact inspection opt-in

If compact inspect is implemented, expose it as `ix inspect --compact` or a versioned `--format agent`, not as a change to default grouped, records, or JSON output. The compact record must include path, exact line number, byte or column focus, preview, elision state, and an exact continuation command. Range mode without an expression has no defensible focus point; it should remain exact unless the caller supplies one.

### Action 3: Extract preview policy from the scan owner

Move fisheye tier selection, UTF-8-safe windowing, elision markers, and preview metadata from the oversized `search.zig` into one `src/core/preview.zig` owner. Search may call it while recording retained hits; a future compact inspect projection may call it at output time. Exact inspect must bypass it. The architectural win is one preview policy without turning preview policy into universal content mutation.

### Action 4: Prove the match span before promising visibility

Replace the best-effort `fisheyeMatchLen` assumption with a typed `MatchSpan { start, len }` produced by, or recoverable from, the selected matcher strategy. First write adversarial tests for regex, alternation, case-insensitive, word-boundary, and matches wider than the normal lens. Only after those tests fail on the old behavior should span propagation touch the hot path. Acceptance: the exact matched byte range is either visible or explicitly represented as elided with recoverable coordinates.

### Action 5: Repair UTF-8 boundaries as a correctness defect

The current preview copies arbitrary byte slices. Adjust starts forward over continuation bytes and ends backward to a code-point boundary; validate the final buffer before JSON escaping. Test 2-, 3-, and 4-byte code points at both boundaries, including the 300/301, 600/601, and 1200/1201 tier transitions. This action is independent of any decision about inspect compaction and should land with the preview extraction.

### Action 6: Never slice a complete hit record to meet a budget

A byte budget may stop before the next record; it must not cut JSON, UTF-8, an elision marker, or an unmarked match. For pathological matches, emit bounded preview context plus exact span metadata and a continuation to exact inspect. The earlier fixed 512-byte match truncation is rejected because it contradicted the stated visibility invariant and had no measured threshold justification.

### Action 7: Keep exact reconstruction first-class

Every lossy result must carry enough identity to recover the source: normalized relative path, line, column or byte offset, match byte length when known, expression identity, and the exact inspect command. Reconstruction tests must fetch the indicated file/range and prove that the represented match can be recovered. This is the hard gate for fisheye, diversity, byte budgets, and semantic chunking.

### Action 8: Replace ambiguous completion state with typed dimensions

Design the next agent schema around separate facts: positive-hit verification, scan coverage, and projection completeness. A viable shape is `verification: canonical`, `scan: complete|partial_access`, and `projection: complete|truncated`, with structured reasons. Do not overload `status:"ok"`; current source proves it only reflects access errors. Because this changes semantics, publish it as `ix.result.v3` or another explicitly versioned contract.

### Action 9: Add a canonical `TruncationReason`

Use one enum owned outside output formatting: `max_hits`, `retention_limit`, `byte_budget`, `access_error`, `similar_candidate_budget`, and `similar_token_budget`, narrowed if implementation shows fewer real states. Scan-owned truncation and projection-owned truncation remain distinguishable. Writers serialize the enum; they do not invent strings. Tests cover every producer and reject `truncated:true` without a reason.

### Action 10: Treat negative results honestly

An empty hit set means only that the executed request produced no retained verified hits under the active binary, roots, ignore policy, access state, expression semantics, and index configuration. Output may say `matches:0`; it must not say or imply “zero matches verified” unless all coverage dimensions are complete. Documentation and tests should teach this distinction so agents do not convert a projection fact into corpus truth.

### Action 11: Make search continuation cursor-based

Do not add plain `--offset N` as the durable contract. Offset pagination can skip or repeat hits when files, ignore state, index generation, sort order, or the result schema changes. Use an opaque cursor bound to expression, roots, relevant flags, ordering policy, output schema, and corpus/index identity. Reject stale or mismatched cursors with a typed recovery error that tells the caller to restart the search.

### Action 12: Define corpus identity narrowly and cheaply

Cursor validation does not require a database. Prefer the existing index generation when the indexed path owns the search; otherwise derive a bounded request/corpus identity from normalized roots, ignore configuration, ordering version, and file-discovery snapshot data already available to the report. Benchmark the cost. If a stable identity cannot be produced cheaply, state that continuation is snapshot-local and reject reuse across invocations rather than pretending determinism.

### Action 13: Make diversity an explicit projection

Deterministic diversity can improve evidence coverage, but a per-file quota does hide otherwise retained hits. Name that behavior accurately: it is a lossy visible projection over a larger ordered result. Select stable first-pass coverage across files, then fill remaining slots in canonical order. Emit projection truncation and a cursor whenever retained hits were omitted. Never claim the formatter “reorganizes but never drops.”

### Action 14: Prove diversity against real next-read decisions

Use transcript commands where one file dominates the first page. Label the file/range the agent actually needed next, replay canonical and diversified projections, and measure top-k coverage, follow-up reads, total bytes, and reconstruction success. Do not hardcode a quota formula from intuition. Select quota and over-fetch policy only when the workload shows a repeatable task-completion gain without unacceptable hidden evidence.

### Action 15: Add an aggregate output budget through typed configuration

Implement `--max-bytes` as a projection limit, but do not declare 8192 the default before measurement. Benchmark candidate budgets against local-model contexts and transcript tasks. The writer must account for escaping and envelope overhead, stop before a complete record that would exceed the budget, set `projection:truncated`, serialize `byte_budget`, and emit the cursor. Explicit user limits override any format default.

### Action 16: Complete `search --context` as one command

The current flag is parsed and advertised but has no observable effect. A continuation alone would not satisfy a flag named `--context`. Build context after visible-hit selection: coalesce overlapping line windows per file, read those bounded windows through the inspect owner, and emit them in the same versioned result. This avoids enlarging the fixed `SearchHit` array and avoids a second full scan. Context records must retain exact line identities; compacting them is a separate explicit projection choice.

### Action 17: Keep help truthful during the context repair

Until Action 16 ships, help and README must not claim that search context is delivered. The implementation slice should update parser behavior, help, docs, and tests together so the advertised surface never drifts again. Acceptance is black-box: the same query with and without `--context N` differs in a defined context section, and the section reconstructs the exact requested windows.

### Action 18: Fix the `--stats` capability-truth defect

The repo README advertises `--json --stats`; the repository binary rejects `--stats`. Choose one current contract and prove it. The smallest compatible repair is to document existing `--json` as the diagnostic surface. If a stats selector is wanted, define it in the canonical command specification first, then implement parser, help, writer, tests, and README in one slice. No documentation-only flag promise may remain.

### Action 19: Introduce `StatsVisibility` without polluting agent output

Define `StatsVisibility = agent|standard|debug` or equivalent in the output-contract owner. Agent visibility should remain the actionable fields already proven useful: expression, matches, files, elapsed time, access/coverage state, and truncation. Do not add `slowest_file` by default; it is diagnostic, not usually a next-retrieval decision. New telemetry fields default to debug until a consumer-value test promotes them.

### Action 20: Extract one telemetry writer

Move full telemetry serialization out of the monolithic JSON report writer into `writeStats(writer, stats, visibility)`. Activation-dependent blocks are emitted only when their owners were active; hardcoded zero-only blocks are removed from the new schema. Existing `--json` remains compatible until its migration boundary is explicit. This refactor is valuable because it creates one policy owner, not because zero values are inherently invalid diagnostics.

### Action 21: Version compact JSON instead of breaking full JSON

Do not silently remove `absolute_path`, reorder fields under attention claims, or zero-elide fields from the existing JSON schema. Tests currently recognize that schema, and consumers may depend on it. Add a versioned compact JSON or `--format json-compact` projection that omits reconstructable fields and uses the new completion model. Deprecate the old form only after consumer inventory and migration evidence exist.

### Action 22: Do not add `--no-sentinel`

Runtime proof shows `--json` already emits one raw JSON object with no sentinel. Agent and grouped formats use sentinels as protocol framing and continuation metadata. A flag that removes their contract while retaining ambiguous line output would add another mode without a proven consumer. Keep raw machine consumption on explicit JSON formats and framed agent consumption on versioned sentinel formats.

### Action 23: Consolidate format selection through one enum

The parser already has a partial `--format` path while separate flags select other projections. Evolve one typed format enum covering text, agent, JSON-compatible, JSON-compact, files, count, and stats-only as supported. Preserve old flags as tested aliases during a named migration window. Reject conflicting selectors deterministically. The enum should own writer selection; `main.zig` should not duplicate projection policy across branches.

### Action 24: Do not infer agent format from pipes

Non-TTY stdout does not prove that the consumer is an LLM; it may be a script expecting current text or JSON. Making `--agent` implicit would be a compatibility break disguised as convenience. Keep format choice explicit. Reduce friction through concise help, examples, skills, and the canonical command specification. Reconsider auto-selection only after usage telemetry or controlled consumer evidence proves it safe.

### Action 25: Generate help and docs from one command specification

Create one compile-time command table containing command, flag, aliases, value type, compatibility status, format applicability, and help text. The parser may still be handwritten if performance or Zig ergonomics demand it, but tests must compare accepted flags to the table. Generate or verify help and README snippets from that owner. This directly prevents the current `--stats` and `--context` drift.

### Action 26: Keep session deduplication at the consumer boundary

IX owns duplicate records within one invocation and stable hit identity. It cannot know which older tool results remain in an agent’s context. Document a stable downstream key—at minimum path, line, column/span, expression/schema identity—and let the consumer harness deduplicate overlapping invocations. Do not add hidden process-global or session state to IX; that would make a deterministic CLI stateful without solving ingestion ownership.

### Action 27: Localize duplicate envelopes before mutation

The transcripts show duplicated output, but 20 current raw-child runs produced exactly one agent envelope and the repo binary has not reproduced the defect. Capture three layers separately: raw child stdout bytes, shell-captured output, and harness-ingested tool results. Change IX only if duplication exists in raw child stdout. A duplicated shell or harness projection belongs to that owner. The prior theory about 4096-byte buffering remains an unproven hypothesis, not a repair target.

### Action 28: Add black-box one-envelope regression coverage

Even without a reproduced defect, contract coverage is cheap and useful. Invoke the real binary below, at, and above the writer buffer boundary and assert one complete envelope, valid framing, valid JSON payload where applicable, and clean exit. Test search agent, search JSON, default search, inspect JSON, and grouped inspect. Unit tests that increment a local “sentinel count” inside a writer are rejected because they prove the counter, not stdout behavior.

### Action 29: Make downstream ingestion tests a separate gate

Where the real transcripts came through PowerShell or an agent harness, replay representative commands through those consumers and count ingested envelopes. If raw stdout is single and ingestion is double, save that evidence beside this plan and repair the consumer. The IX release gate should record the distinction so an external duplication bug is not later “fixed” by suppressing legitimate IX output.

### Action 30: Repair `similar` with a bounded union frontier

Do not hard-filter semantic search to files containing query tokens. Lexically dissimilar files can be semantically relevant. Build the first candidate batch as a bounded union of lexical high-signal files and a deterministic corpus-order or coverage sample, then expose continuation over remaining candidates. Report candidates evaluated versus eligible. Lexical evidence may prioritize work; it must not silently define semantic eligibility.

### Action 31: Make semantic coverage visible

The `similar` contract needs its own completeness fields: files eligible, files read, chunks embedded, bytes/tokens submitted, candidates omitted, and truncation reason. A remote timeout or budget stop is partial semantic coverage, not an empty semantic result. Errors preserve provider ownership and recovery action without leaking secrets. This turns a minutes-long opaque call into an inspectable bounded operation.

### Action 32: Benchmark semantic chunking before fixing constants

Whole-file embeddings dilute local relevance and can be expensive, but 4 KiB chunks and a 100K-token budget were not proven. Build a corpus with known related spans; compare line-aware chunk sizes, overlap, max-versus-aggregate file scoring, request count, recall, latency, and cost. Select typed defaults from the Pareto frontier. Preserve exact file/range coordinates so every semantic hit can be inspected without re-embedding.

### Action 33: Keep semantic work out of the literal hot path

Lexical candidate collection, chunking, remote calls, and semantic scoring belong to `similar` and its adapters. They must not add allocation, locks, language parsing, or provider state to the canonical scan loop. Reuse discovery and expression owners through bounded interfaces. This preserves IX’s hot-path invariants while allowing the semantic lane to mature independently.

### Action 34: Reject hot-loop scope annotation

The proposed brace-depth tracker would add language heuristics, state, and a larger `SearchHit` to every scan for an unmeasured benefit. Do not implement it in the hot path. If transcript benchmarking later proves scope labels reduce exact reads, derive them after visible-hit selection through a language-aware optional projection and measure false labels. Until then, file, line, preview, and exact inspect are the simpler truthful contract.

### Action 35: Preserve architecture boundaries that already prove value

Do not add a mandatory metadata database, runtime SIMD dispatch, GPU regex, bloom filters beside trigram admission, or prediction models in literal scan admission. Current transcript evidence points to output and semantic-lane defects, while repository directives protect compile-time SIMD, thread-local accumulation, pre-I/O classification, and no scan-loop allocation. Any future engine change must enter through a separate benchmark-falsification plan.

### Action 36: Keep streaming as a measured future candidate

Do not add incremental hit streaming in this repair. It changes ordering, truncation, framing, cancellation, and duplicate semantics and has no transcript proof that first-hit latency is the limiting factor. Cursor-based bounded results solve the demonstrated context problem with less mechanism. Reopen streaming only with a workload where time-to-first-useful-hit dominates and a deterministic merge contract is specified.

### Action 37: Build the transcript replay benchmark

Extract unique IX commands, expected next file/range, and observed failure mode from the supplied transcripts. For each candidate projection measure bytes, parse success, top-k next-read accuracy, exact reconstruction, follow-up tool calls, wall time, and completeness truth. Keep engine timing separate from model/context evaluation. A local-model run is useful secondary evidence; deterministic labels and reconstruction are the primary gate.

### Action 38: Add falsification cases, not only happy paths

The suite must include multibyte boundaries, whole-line regex, compound expressions, one-file dominance, access denial, ignored files, retention overflow, byte-budget overflow, corpus mutation between cursor pages, stale cursor, index enabled and disabled, raw stdout around buffer boundaries, and remote semantic failure. Each test states what shallow implementation it rejects. Snapshot-only output tests are insufficient.

### Action 39: Execute in category-pure waves

Wave A locks baselines and localizes duplicate ownership. Wave B repairs correctness and truth: UTF-8, match span, `--stats`, and `--context`. Wave C performs ownership refactors: preview module, command specification, format enum, telemetry writer. Wave D adds the versioned agent contract: typed completeness, budgets, diversity, and cursors. Wave E repairs `similar`. Wave F runs replay, compatibility, performance, and promotion gates. Do not mix an unrelated hot-path optimization into these waves.

### Action 40: Gate every wave on no-false-negative and reconstruction evidence

For scan-affecting work, match parity against the current valid predecessor is mandatory. For projection work, canonical retained-hit parity, explicit omission accounting, cursor traversal, and exact reconstruction are mandatory. For semantic work, compare recall on labeled spans and expose incomplete coverage. `status:"ok"`, one green example, or reduced byte count alone cannot satisfy the gate.

### Action 41: Promote the repository binary only after parity

Promotion requires: clean ReleaseSmall build under the declared Zig/StringZilla/PCRE2 contract; full tests; help/parser/README parity; agent and JSON schema probes; current benchmark match and route parity; no unexplained engine regression beyond the clean envelope; installed-path replacement through a reversible process; and post-install hash, version/help, agent-format, inspect, and error-contract smoke probes. Promotion happens once the release candidate passes, not automatically after each documentation phase.

### Action 42: Close the plan with one auditable checklist

- [x] Baseline artifacts record installed/repo identity, commands, outputs, and current test/build proof.
- [x] Exact inspect remains exact; compact inspect was not added without a proven focus contract.
- [x] Preview ownership is extracted; UTF-8 and exact-span adversarial tests pass.
- [x] `search --context` has observable same-command context, not a hint pretending to be context.
- [x] `--stats-only`, help, parser, README, and the typed format specification agree.
- [x] `ix.result.v3` separates verification, scan coverage, and projection completeness.
- [x] `TruncationReason`, whole-envelope byte accounting, and cursor traversal are typed and tested. Diversity was evaluated and deferred because no labeled next-read evidence proved a quota, and a naive reorder would break the cursor's total order.
- [x] Existing JSON compatibility is preserved behind the current `--json`; compact JSON is an explicit versioned projection.
- [x] No `--no-sentinel`, pipe-auto-agent, hot-loop scope parser, or unproven IX dedup patch landed.
- [x] Twenty raw-child repetitions prove one IX envelope per invocation; harness-level duplication remains outside IX until independently reproduced there.
- [x] `similar` uses a deterministic bounded union frontier, visible coverage, and exact whole-file coordinates. Artificial 4 KiB chunking was removed; chunking remains deferred until a labeled benchmark proves its value and boundaries.
- [ ] Transcript replay has not yet established a diversity or semantic-chunking default; deterministic transcript-derived cases do prove framing, reconstruction, byte boundaries, and mutation recovery.
- [x] Repository tests, release build, match parity, route parity, performance envelopes, reversible installed promotion, and installed-path smoke probes pass.
- [x] Ledgers, README, root `SKILL.md`, black-box gates, and this plan reflect the release-candidate contract.

## Execution ledger

| Wave | Actions | Exit proof |
|---|---|---|
| A — baseline and ownership | 27–29, 37–38 | Raw/stdout/harness duplication classified; replay corpus and adversarial cases saved |
| B — correctness and capability truth | 4–5, 8–10, 16–18 | UTF-8/span tests pass; completion semantics are truthful; context and stats surfaces work as advertised |
| C — canonical owners | 3, 19–25 | One preview policy, command specification, format owner, and telemetry writer; compatibility tests green |
| D — bounded agent contract | 6–15 | Complete records, typed truncation, cursor traversal, diversity evaluation, exact reconstruction |
| E — semantic lane | 30–33 | Bounded union coverage, measured chunking, visible partial state, provider recovery tests |
| F — release closure | 35–42 | Replay gain, scan parity, release build/tests, reversible promotion, installed smoke proof |

### 2026-07-13 implementation evidence

- Repository checkpoint `6cc365a8` was committed and pushed before implementation.
- Debug suite: `506/506` tests pass under the declared Zig 0.16.0 toolchain.
- ReleaseSmall build passes against restored tag-exact StringZilla `v4.6.0` and PCRE2 `pcre2-10.44` sources.
- Output contract gate passes one-envelope framing, legacy v2/JSON compatibility, exact regex spans, UTF-8 fisheye boundaries, same-command context, cursor traversal, whole-envelope byte budgets at 1400/4095/4096/4097 bytes, and typed stale-cursor recovery after mutation.
- Warm/cold gate passes on an actual 1,000-file index: identical matches and retained evidence, 1,000 cold files versus 100 warm candidates, with this run's median `87.184 ms` cold versus `11.016 ms` warm.
- Valid predecessor cold proof retained exact match parity: literal median ratio `0.9877`; variable-regex median ratio `1.0152`. Legacy warm-cache proof retained exact match parity with median ratio `0.9203`.
- Repeated cold cursor identities are stable on Windows after excluding the filesystem's unstable synthetic FileIndex; size and mtime still reject mutation, while POSIX retains inode evidence.
- Expression parsing now rejects empty operands, mixed `&&`/`||` plans, empty regexes, and PCRE2 compile failures before discovery; malformed syntax can no longer masquerade as a successful zero-result scan.
- Fisheye remains deliberately scoped to compact search previews. Exact inspect windows and exact search-context windows bypass it.
- Commit `b9cbfdc1` is pushed on `develop-subzero`. The committed ReleaseSmall binary is installed at both `ix.exe` and `iex.exe` with SHA-256 `07D50B767C065214A68F9A41C2AE413DE2421A22B9587CB66B231FCAE1ECC211`; reversible backups use timestamp `2026-07-13T13-32-39-608Z`.
- Installed-path gates pass output framing/compatibility, real warm/cold parity, strict malformed-expression rejection, current help, and exact inspect windows.

## Rejected or deferred prescriptions

| Prescription | Disposition | Reason |
|---|---|---|
| Apply fisheye to every inspect path | Rejected | Breaks the exact bounded-reader contract and invents focus for range reads |
| Truncate every emission at 512 bytes | Rejected | Threshold unmeasured; can cut the match and violate reconstruction |
| Default `--agent` when stdout is piped | Rejected | Pipe is not proof of an agent consumer; compatibility risk |
| Remove `absolute_path` from current JSON | Deferred to versioned compact JSON | Existing public shape and tests may have consumers |
| Add `--no-sentinel` | Rejected | Raw `--json` is already sentinel-free |
| Fix duplicate output in IX now | Blocked on reproduction | Current raw child stdout is single-envelope across 20 runs |
| Use lexical matches as a hard semantic gate | Rejected | Can create semantic false negatives |
| Add scope tracking in the scan loop | Rejected | Unmeasured value and direct hot-path cost |
| Use plain result offsets | Rejected | Mutation and ordering create skip/repeat anomalies |
| Claim `status:"ok"` proves no false negatives | Rejected | Source proves status only reflects access errors |
| Promote after each phase | Rejected | Installed state should change only after one complete release gate |

## Source owners to touch when execution begins

| Owner | Planned responsibility |
|---|---|
| `src/core/preview.zig` | New compact preview policy, UTF-8-safe windows, span/elision metadata |
| `src/core/search.zig` | Import preview owner; expose exact span/completeness facts without weakening hot-path invariants |
| `src/core/inspect.zig` | Exact bounded windows; optional compact projection input and context-window coalescing |
| `src/core/similar.zig` | Bounded union frontier, chunk coordinates, budget and coverage reporting |
| `src/cli/args.zig` | Typed formats, context, byte budget, cursor, deterministic conflicts |
| `src/cli/output.zig` | Versioned projections, typed completeness, cursor, one telemetry writer |
| `src/cli/command_table.zig` | Canonical command/flag/help specification if Zig implementation proves clean |
| `src/main.zig` | Thin command dispatch and runtime config merge; no output-policy duplication |
| `README.md` and agent skill/docs | Generated or checked usage contract after behavior exists |
| Existing Zig test owners plus black-box CLI suite | Adversarial invariants, compatibility, framing, reconstruction, parity |

## Definition of done

This plan is complete only when an agent can issue a documented command against the installed binary, receive one parseable and truthful result, distinguish verified positives from scan and projection completeness, continue without guessing, reconstruct exact source evidence, and avoid paying for telemetry it did not request. The engine must retain match and route parity, exact inspect must remain trustworthy, semantic partial coverage must be visible, and every public format change must cross an explicit compatibility boundary.
