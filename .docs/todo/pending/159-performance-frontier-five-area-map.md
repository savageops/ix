---
id: 159-performance-frontier-five-area-map
type: parent
protocol_version: "3.0"
spec_status: approved
category: documentation
status: pending
epic_boundary: "Produce one evidence-backed implementation map for the five ranked IX performance areas without mutating runtime behavior or creating a competing performance owner."
subtodo_start: /todo/pending/159a-performance-frontier-five-area-map.md
subtodo_final: /todo/pending/159f-performance-frontier-five-area-map.md
continuation: "Execute one slice at a time: archive each evidence-bearing planning unit individually, then advance through next_todo; do not begin runtime mutation from this chain."
source_message_policy: "Every lettered unit carries verbatim source snippets from the user's five-area request and names the proof needed before any implementation chain is opened."
predecessor_state: "Checkpoint ea226896 is pushed to origin/develop-subzero. Existing 152 remains active; 153-155 have archived children but unarchived parents; 156-158 are complete records still under pending. This chain maps the next work and does not silently supersede those records."
---
# 159 Performance Frontier — Five-Area Implementation Map

## Objective

Create the canonical planning surface for the five performance opportunities named by the user: runtime admission wiring and threshold economics, ignore/discovery parity, byte-shard activation, and persistent warm-index promotion. The map begins at the actual IX owners — `src/core/search.zig`, `src/core/search_admission.zig`, `src/core/trigram.zig`, `src/core/admission.zig`, `src/core/byte_shard.zig`, `src/core/postings.zig`, `src/core/catalog.zig`, `src/core/generation.zig`, and `src/core/indexd.zig` — and ends at a falsifiable implementation order with no false-negative escape hatch.

This is a documentation planning chain, not a runtime patch chain. It records the exact probes, source harvests, route boundaries, resource-profile assumptions, and promotion gates required before code changes. The later implementation work must enter through the canonical owners and must wait for queue reconciliation where existing live chains overlap; this parent is the index that prevents the next agent from treating a telemetry symptom as an implementation fact.

## Rationale

The five opportunities are not independent knobs. Admission ordering affects byte-shard cost; ignore policy changes the candidate universe; warm frontiers can bypass discovery; and benchmark attribution must distinguish discovery, open, admission, scan, merge, and output. The order therefore starts with baseline and runtime truth, groups whole-file/trigram policy as one admission owner, proves discovery/ignore parity before indexed traversal, activates byte sharding only after admission economics are known, and leaves persistent warm-index promotion last because stale or over-broad candidates are a correctness and lifecycle failure, not merely a speed miss.

The current queue contains overlapping historical chains and contradictory completion records. No new implementation parent may use those records as current capability truth without reconciliation. This chain records the contradiction as an explicit dependency and requires current binary identity, route parity, match parity, process hygiene, and resource-profile provenance in every future promotion decision.

## Domain Expertise Baseline

| Domain Question | Current Evidence | Gold-Standard Requirement | What This Chain Must Not Assume |
|---|---|---|---|
| Can admission prune a file safely? | `src/core/search_admission.zig` owns `fileAdmissionMiss`/`mayMatch`; verifier remains in `src/core/search.zig`; prior unit probe proved a single literal miss. | Admission may reject only when the evidence program proves the query impossible; every retained candidate is verified by the existing matcher. | `candidate_files_checked: 0` alone proves a wiring defect; telemetry may be counted before the gate. |
| Which scan policy wins? | `search.zig` has mmap, buffered, and byte-shard routes; `scan_input_policy.zig` is diagnostic-only. `.docs/research/competitor-anatomy-map.md` records ripgrep's per-file mmap heuristic. | Select policy by paired, route-equivalent measurements on the declared resource profile and platform; do not generalize Linux results to Windows/macOS. | Forced mmap or a lower threshold is automatically faster. |
| What does ignore parity mean? | `src/core/admission.zig` parses `.gitignore`, `.ignore`, `.agignore`; discovery applies decisions in serial and parallel paths; default build-output exclusions were added in `6106b5e1`. | Last-match-wins, negation, directory-only, anchored, external-file, hidden/unrestricted, and warm-frontier behavior agree or fail closed. | `no_ignore` means default discovery should ignore build outputs; it controls ignore loading, not the separate default directory policy. |
| When is byte sharding valid? | `src/core/byte_shard.zig` and `tryByteShardFastCount` require eligible strategies, size thresholds, multiple ranges, and `stats_only`. | Byte ranges own complete lines, merge counts exactly, and never erase output or verifier semantics. | Enabling the kernel for match-output searches is a switch rather than a new proof obligation. |
| When is a warm index promotable? | `catalog.zig`, `generation.zig`, `postings.zig`, `delta_overlay.zig`, `usn.zig`, and `indexd.zig` contain substantial machinery; `.docs/research/2026-07-16-bounded-warm-index-architecture.md` says activation remains gated. | One writer, bounded immutable state, freshness continuity, quota/free-space enforcement, crash cleanup, exact candidate verification, ignore parity, and cold fallback are proven on the installed path. | Existing publication/compaction code means supported warm search is already complete. |

## Gold-Standard Decision Criteria

| Criterion ID | Decision Rule | Evidence Required Before Selection | Review Failure Signal |
|---|---|---|---|
| GS1 | Preserve exact match and route parity before accepting any speed delta. | Structured current/installed/predecessor reports with binary hashes, query identity, resource profile, files, bytes, matches, and route fields. | Any mismatch is used as a speed win or hidden by line-count parsing. |
| GS2 | Spend admission work only when measured rejection savings exceed its cost for that file/query lane. | Size/pattern/case/yield matrix separating admission-only and verifier timings. | A global threshold is lowered from intuition or one corpus. |
| GS3 | Treat discovery policy as part of the searched corpus. | Adversarial ignore fixtures plus serial/parallel/warm/unrestricted parity probes. | A warm frontier bypasses changed ignore rules or a default exclusion lacks an explicit override. |
| GS4 | Keep byte sharding confined to the proven stats-only contract until output semantics are independently proven. | Range ownership, count merge, boundary, UTF-8, binary, and match-count parity tests. | Match-output activation is justified only by a telemetry flag. |
| GS5 | Promote warm indexing only when lifecycle and freshness are bounded, not merely when a query is faster. | Restart, mutation, stale/malformed, disk-floor, GC, reader-pin, ignore-policy, and cold-fallback receipts on current installed binaries. | A warm hit or `postings_index` field is treated as capability proof without readback and failure proof. |

## Repository Ownership Reconnaissance

| Question | Evidence Found | Planning Consequence | Anti-Assumption Guard |
|---|---|---|---|
| Current canonical owners | Admission: `src/core/search_admission.zig`, `src/core/trigram.zig`; discovery: `src/core/admission.zig` + `src/core/search.zig`; sharding: `src/core/byte_shard.zig` + `search.zig`; warm state: `catalog.zig`, `generation.zig`, `postings.zig`, `indexd.zig`, `delta_overlay.zig`, `usn.zig`; benchmark: `tools/scripts/lib/*`, `tools/scripts/bench-three-way.mjs`. | Extend these owners; do not create a second admission, traversal, benchmark, or index registry. | The untracked benchmark harness is now committed as `ea226896`, but remains exploratory until identity/route parity is upgraded. |
| Adjacent or duplicate owners | `search.zig` is oversized; `scan_input_policy.zig` is diagnostic; `indexd.zig` has active lifecycle code while architecture docs state promotion is gated; `.docs/todo/157` and `.docs/todo/158` contradict on `min`. | Reconcile state records before claiming implementation; require structural decomposition for any new `search.zig` hot-path edit. | Do not infer current truth from a stale todo, ignored report, or a `not_wired` field alone. |
| Canonical callers and consumers | CLI search/matches enter `search.run`; JSON output is owned by `src/cli/output.zig`; warm search uses `prepareWarmIndexFrontier`; installed consumer is `C:\Users\Savage\AppData\ix\ix.exe`. | Every future slice must prove the real CLI and installed paths, not only internal unit calls. | Bench wrapper line counts are not match parity. |
| Existing tests and proof gaps | Admission unit tests exist; byte-shard tests exist; lifecycle tests were added; broad suite has 9 failures and 4 crashes in unrelated warm/Thompson paths; runtime admission counters remain zero in observed corpora. | Build challenge probes before mutation; classify pre-existing failures and never weaken them. | Diagnostic counters are not capability proof unless the canonical search result changes correctly. |
| Unsupported runtime boundaries | Resource caps are intentional; mmap and filesystem freshness differ by OS; Zig/toolchain/build refs must be present; warm activation remains lifecycle-gated. | Record profile and platform for every result; unsupported behavior fails closed to cold/verified paths. | Do not promise one policy or warm capability across Windows/Linux/macOS without native probes. |

## Scope

**In scope:**
- A complete five-area evidence map and ordered implementation DAG.
- Admission call-path instrumentation and threshold qualification requirements.
- Ignore/discovery parity contract, including warm-frontier implications.
- Byte-shard activation contract limited to proven route shapes.
- Warm-index promotion gates and explicit cold fallback.
- Benchmark provenance, competitor/source citations, queue dependencies, and review criteria.

**Out of scope:**
- Runtime source mutation in this planning chain.
- Lowering `TRIGRAM_MIN_PRUNE_BYTES` before runtime call-path proof.
- Enabling byte sharding for match-output searches.
- Making `.gitignore` parsing a new subsystem; the parser already exists.
- Declaring persistent warm indexing shipped from existing lifecycle code.
- Changing resource caps, platform defaults, or user-visible CLI semantics.

## Source Language Anchors

- "commit and push all current progress"
- "then proceed to map out these 5 areas using the planning spec skill."
- "Fix trigram/whole-file admission wiring gap"
- "Lower trigram prune threshold for mid-size files"
- ".gitignore support"
- "Byte-shard kernel activation"
- "Persistent warm index"
- "be very careful that we don't create false negatives"

## Original User Message Capture

| Anchor ID | Information Piece | Verbatim Original Snippet | Required Coverage |
|---|---|---|---|
| U0 | checkpoint | "commit and push all current progress" | Confirmed before this chain by `ea226896` pushed to `origin/develop-subzero`. |
| U1 | planning directive | "then proceed to map out these 5 areas using the planning spec skill." | All units and the terminal review produce the ordered map. |
| U2 | admission wiring | "1. 🔴 Fix trigram/whole-file admission wiring gap (3-4x potential)" | 159a/159b lock and map call-path proof. |
| U3 | admission threshold | "2. 🟡 Lower trigram prune threshold for mid-size files (1.5x on top of #1)" | 159b defines threshold economics and rejects blind lowering. |
| U4 | ignore policy | "3. 🟡 .gitignore support (2-10x on real projects)" | 159c proves existing parser/discovery and warm parity before extending anything. |
| U5 | byte sharding | "4. 🟢 Byte-shard kernel activation (2x on multi-thread)" | 159d maps current activation gates and stats-only boundary. |
| U6 | persistent index | "5. 🟢 Persistent warm index (Tier 6 — 10x+ on repeat queries)" | 159e maps lifecycle/freshness/postings promotion gates. |
| U7 | correctness | "be very careful that we don't create false negatives" | Every unit and review carries verifier authority, cold fallback, and parity gates. |

## Source Message Coverage

| Unit | Source Anchor(s) | Slice Proof Obligation |
|---|---|---|
| 159a | U0, U1, U7 | Freeze the five-area interpretation, queue boundary, and no-false-negative contract. |
| 159b | U2, U3, U7 | Map the admission call path and threshold decision matrix without speculative mutation. |
| 159c | U4, U7 | Map ignore/discovery behavior and warm-frontier policy parity with explicit overrides. |
| 159d | U5, U7 | Map byte-shard activation, range ownership, route scope, and proof gates. |
| 159e | U6, U7 | Map persistent-index lifecycle and promotion boundary with cold fallback. |
| 159f | U1, U2, U3, U4, U5, U6, U7 | Verify all requested areas are covered and no capability claim outruns evidence. |

## Constraints

| Dimension | Constraint |
|---|---|
| Category boundary | Documentation/planning only; runtime changes require a later approved implementation chain. |
| Blast radius ceiling | Low for this chain; no executable search behavior changes. |
| Structural boundary | Existing owners remain canonical; `search.zig` requires decomposition before hot-path edits. |
| Dependency boundary | Existing 152 remains active; 153-155 and 156-158 need state reconciliation before their records can be treated as current promotion evidence. |
| Rollback surface | Remove only the new planning files; do not revert `ea226896` or prior runtime commits. |
| Parallelism | Research lanes may be read-only and parallel; authored chain remains sequential and one-frontier. |

## Invariants

- I1: Admission is fail-closed and verifier-backed; no false negatives.
- I2: Match, route, file-count, byte, and output parity remain the promotion floor.
- I3: Resource profile, platform, binary identity, cache state, and process hygiene are recorded for every performance claim.
- I4: One canonical owner exists for admission, discovery policy, byte-shard execution, warm state, and benchmark interpretation.
- I5: Unsupported mmap, freshness, index, or resource behavior falls back explicitly rather than silently pretending support.
- I6: This chain does not mutate runtime behavior or weaken existing failing tests.

## Architectural Improvement Targets

| Target ID | Pre-Chain Weakness | Required Better-Than-Before Outcome | Verified By |
|---|---|---|---|
| A1 | Runtime telemetry and static admission evidence disagree. | One call-path map distinguishes program eligibility, gate reachability, return value, and counter semantics. | 159b map and terminal review. |
| A2 | Thresholds and route ordering are distributed across owners. | A single decision matrix names size, pattern, case, yield, admission cost, and verifier cost. | 159b acceptance table. |
| A3 | Ignore support is described as missing although parser/discovery owners exist. | The plan separates parser capability, discovery wiring, defaults, overrides, and warm parity. | 159c owner map. |
| A4 | Byte-shard and warm-index fields can be mistaken for active capability. | Activation contracts name exact entrypoint, route scope, lifecycle, and proof receipts. | 159d/159e review. |
| A5 | Historical todos and benchmark scripts can contradict current state. | Queue and evidence provenance become explicit prerequisites for implementation selection. | 159a and 159f audits. |

## Embedded Framing Contract

| Frame ID | Embedded Meaning | Where It Appears | Gold-Standard Pressure |
|---|---|---|---|
| F1 | Scan fewer bytes before scanning bytes faster. | Objective, rationale, 159b-159e | Prevents kernel-first optimization that leaves discovery/admission work unchanged. |
| F2 | Every speed claim is a parity-qualified measurement. | Criteria, validation, review | Blocks benchmark theater and route mismatch. |
| F3 | Warm indexing is a lifecycle capability, not a fast flag. | 159e and closeout | Blocks stale/malformed candidate use and unbounded disk growth. |

## Research Program

| Research ID | Why This Research Exists | Questions To Answer | Insect Surface | Priority Sources | Expected Artifact / Evidence |
|---|---|---|---|---|---|
| RCH-1 | Admission call-path and threshold selection | How do ripgrep, Zoekt, Hound/Livegrep, Hyperscan, and Aho-Corasick separate candidate admission from verification? | `.refs/` harvest; `engine --query` only if local refs leave a gap | `.refs/ripgrep`, `.refs/zoekt`, `.refs/hyperscan`, `.refs/aho-corasick`, competitor map | Cited admission decision matrix in 159b. |
| RCH-2 | SIMD admission economics | Which first-byte, Teddy/Shufti, Shift-Or, or rolling-trigram patterns reduce work without runtime dispatch or false negatives? | `.refs/` source inspection; bounded `engine --query` | `.refs/hyperscan`, `.refs/vectorscan`, `.refs/stringzilla`, `.refs/simdjson`, `.refs/simdutf` | Rejected/retained primitive table in 159b. |
| RCH-3 | Ignore semantics | Which git-compatible rules, negation, external files, and defaults are required for parity? | `.refs/` harvest; `engine --query` for current docs if needed | `.refs/ripgrep`, `.refs/gitoxide`, git documentation | Adversarial parity matrix in 159c. |
| RCH-4 | Range sharding | How do mature scanners prove line ownership, overlap, merge, and output boundaries? | `.refs/` harvest; `engine --query` | `.refs/ripgrep`, `.refs/simdjson`, `.refs/tigerbeetle` | Byte-shard activation contract in 159d. |
| RCH-5 | Persistent index lifecycle | What bounded segment, freshness, publication, and cleanup invariants transfer from indexed search systems? | `.refs/` harvest; `engine --query` for current operator evidence | `.refs/zoekt`, `.refs/tantivy`, `.refs/lucene`, `.refs/quickwit`, `.refs/sqlite`, competitor map | Warm promotion gate and rejection table in 159e. |
| RCH-6 | Benchmark trust | What does a fair current/predecessor/installed comparison require? | Local scripts and runtime probes; `engine --query` only for missing primary benchmark guidance | `tools/scripts/lib/*`, `.docs/qc/*`, ripgrep benchsuite | Provenance checklist and benchmark schema requirements. |

The twelve-plus source-bearing references already admitted to `.refs/index.md` satisfy the deep-research floor for planning: ripgrep, ugrep, Zoekt, Hyperscan, Vectorscan, RE2, Aho-Corasick, simdjson, simdutf, Tantivy, Lucene, Quickwit, SQLite, TigerBeetle, gitoxide, and the local competitor anatomy/lifecycle records. Any implementation chain that changes this source set must refresh the affected citation rather than silently relying on this snapshot.

## Assumption Ledger

| Assumption ID | Assumption | Evidence Class | Risk If Wrong | Slice That Proves Or Eliminates It |
|---|---|---|---|---|
| AS1 | The observed zero runtime admission counters indicate either unreachable wiring or incomplete telemetry. | Runtime probe + local source, unresolved | Threshold work could optimize a path never reached. | 159a/159b. |
| AS2 | Existing `.gitignore` parser is sufficient for ordinary discovery semantics. | Verified source inspection, runtime parity incomplete | Rebuilding it would create a duplicate and warm drift. | 159c. |
| AS3 | Byte-shard fast count remains stats-only by contract. | Verified source path | Match-output activation could lose lines/order. | 159d. |
| AS4 | Warm publication code is not promotion proof. | Architecture doc + source contradiction | Stale candidates, disk recurrence, or false hits. | 159e. |
| AS5 | Resource caps are intentional and must remain fixed while comparing per-thread throughput. | User decision + `resource_profile.zig` | Uncapped comparisons would misattribute gains. | 159a/159f. |
| AS6 | Existing pending todo records are not a single current-state authority. | Queue inspection; contradictory records 157/158 | New work could fork ownership or repeat completed work. | 159a/159f. |

## Chain Manifest

| File | Phase | Role | Status |
|---|---|---|---|
| `/todo/pending/159-performance-frontier-five-area-map.md` | parent | Chain root | pending |
| `/todo/pending/159a-performance-frontier-five-area-map.md` | a | Baseline / contract lock | pending |
| `/todo/pending/159b-performance-frontier-five-area-map.md` | b | Admission wiring and threshold map | pending |
| `/todo/pending/159c-performance-frontier-five-area-map.md` | c | Ignore/discovery parity map | pending |
| `/todo/pending/159d-performance-frontier-five-area-map.md` | d | Byte-shard activation map | pending |
| `/todo/pending/159e-performance-frontier-five-area-map.md` | e | Persistent warm-index promotion map | pending |
| `/todo/pending/159f-performance-frontier-five-area-map.md` | f | Terminal review / QC | pending |

## Execution Index

| Order | Unit | Role | Decision After Completion |
|---|---|---|---|
| 1 | 159a | Lock scope, queue state, benchmark contract, and invariants | Continue only with the five-area boundary frozen. |
| 2 | 159b | Map admission wiring and threshold economics | Continue to discovery only after admission evidence is explicit. |
| 3 | 159c | Map ignore/discovery and warm-frontier parity | Continue to byte sharding only after candidate-universe semantics are explicit. |
| 4 | 159d | Map byte-shard activation and route limits | Continue to warm index only after range and verifier boundaries are explicit. |
| 5 | 159e | Map warm-index lifecycle and promotion gates | Continue to terminal QC only after lifecycle blockers are named. |
| 6 | 159f | Review source coverage, ownership, evidence, and queue conflicts | `NONE` on pass; extend only for a proven planning defect. |

## Phase Plan

| Letter | Role | Patch Surface | Depends On | Parallelizable |
|---|---|---|---|---|
| a | Baseline / contract lock | No artifact change; scope and evidence interpretation | — | No |
| b | Admission map | Planning unit only; no runtime mutation | 159a | Read-only source research may parallelize. |
| c | Discovery/ignore map | Planning unit only; no parser rewrite | 159b | No, because warm parity consumes admission/candidate semantics. |
| d | Byte-shard map | Planning unit only; no activation flag change | 159c | No, because route ordering depends on candidate universe. |
| e | Warm-index map | Planning unit only; no promotion change | 159d | No, lifecycle is terminal architecture lane. |
| f | Review / closeout | Read-only plan and repository QC | 159a-159e | No |

## Validation Expectations

- Every unit records exact source paths, current evidence class, rejected alternatives, and a machine-verifiable next decision.
- Every implementation/documentation unit is exempt from the 30 feature-test floor only because this chain changes no executable capability; each still requires source, research, and schema/benchmark proof.
- No runtime benchmark is accepted without binary identity, query/route/match parity, resource profile, platform, cache state, and process status.
- No admission plan is accepted without an adversarial false-negative matrix.
- No warm-index plan is accepted without explicit stale/malformed/cold fallback and lifecycle cleanup gates.

## Current Frontier
`/todo/pending/159a-performance-frontier-five-area-map.md`

## Stop Condition
`NONE` only after 159f records a passing terminal review; runtime implementation remains a separate approved chain.

## Next todo
`/todo/pending/159a-performance-frontier-five-area-map.md`

## Parent Completion
- [ ] All six lettered units archive individually with concrete evidence.
- [ ] Terminal review passes or extends the chain with an evidence-backed planning repair.
- [ ] Parent archives last; runtime implementation remains outside this documentation chain.
