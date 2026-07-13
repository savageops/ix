---
id: pass-008-projection-insight-lanes
type: qc
category: architecture
status: active
date: 2026-07-13
owner: xo-insight-lane
baseline_commit: 3c485c7c
---

# QC Pass 008 — Projection And Insight Lanes

## Decision

`inspect` remains the exact sequential reader. Its grouped default already emits a path once and numbered lines beneath it. `--format records` remains `path:line:text` because independent records must survive filtering, sorting, and concatenation. Path repetition is therefore not removed from the pipe contract.

`xo` is the separate query-driven context assembler. It may return fragmented exact source spans under a byte budget, but every span retains path and line coordinates, every omitted region is explicit, ordering is deterministic, and the envelope says which retrieval signals were actually used. It cannot describe an embedding, reranker, lexical heuristic, or incomplete corpus traversal as truth.

## Response Structure Disposition

| Structure | Good | Better | Default | Remove / clean |
|---|---|---|---|---|
| `inspect` grouped | Exact, path once, readable continuation. | Keep headings compact; preserve exact lines. | Default inspect output. | No new decoration or fisheye. |
| `inspect --format records` | Pipe-safe, grep-shaped, independently attributable. | Document why the path repeats. | Explicit pipe format. | Do not group or make stateful. |
| `inspect --format json` | Exact structured evidence. | Add only versioning if a breaking contract is required. | Programmatic exact reading. | Avoid derived duplicate paths. |
| Search previews | Fisheye saves tokens on long lines without changing matches. | Keep preview window metadata in v3. | Search navigation only. | Never apply silently to exact inspect. |
| `similar` v2 | Real embedding plus rerank lane with explicit coverage and coordinates. | Expose provider/model/strategy; replace whole-file batches with measured code-aware passages; add lexical candidate evidence. | Advisory file/passages frontier after quality proof. | Remove any whole-file or uniform-frontier behavior that fails labeled recall/cost gates. |
| `xo` grouped | Query-ranked exact spans, path once, omitted gaps visible. | Hybrid lexical/structural/semantic retrieval with deterministic final assembly. | Candidate agent insight default only after next-read evaluation. | No fixed-range theater, hidden incompleteness, or prose-only explanation. |
| `xo` JSON | Machine-readable spans, budgets, signals, coverage, continuation. | Stable versioned envelope. | Programmatic insight output. | No field without a real measured owner. |

## Competitor And Research Deltas

- Sourcegraph separates display limits from exhaustive statistics and streams progress/skips independently; IX keeps scan truth separate from projections and must do the same for insight coverage.
- Cursor automatically assembles semantically related code and session context; IX must add exact coordinates, deterministic budgets, and visible retrieval provenance rather than an opaque context bundle.
- Continue applies reranking after vector retrieval; IX must preserve candidate-stage and rerank-stage identity instead of presenting the final score as fact.
- OpenAI File Search exposes chunking, result caps, ranker, and score threshold; IX must make passage formation and omission measurable rather than hardcoded and invisible.
- ColBERT/PLAID use late interaction and staged candidate pruning; IX should treat semantic retrieval as a measured second-stage signal, not upload every whole file to every stage.
- Tree-sitter proves incremental structural parsing can be fast and error-tolerant; IX may add syntax-aware boundaries only through vendored parsers or a dependency-free local owner after labeled value exceeds the added grammar surface.
- Zoekt and ripgrep reinforce the exact lexical lane: trigrams/literal extraction remain the fast candidate owner. `xo` composes that evidence off the search hot path rather than inserting semantic work into scanning.
- Furnas fisheye is a focus-plus-context model, not permission to corrupt exact evidence. `xo` applies degree-of-interest to span selection while emitted source remains byte-exact.

## Acceptance Gates

- Search hot path has no dependency on `xo`, embeddings, reranking, passage scoring, or insight serialization.
- Exact inspect output remains byte-for-byte compatible for grouped, records, and JSON fixtures.
- Warm and cold search lanes retain identical evidence and predecessor performance gates.
- `xo` supports a file or directory, a natural-language query, and an explicit byte cap.
- Central spans maximize measured query/structural evidence; expansion decreases by distance and stops at the budget or zero marginal evidence.
- Fragmentation is explicit: non-adjacent spans carry omitted-line counts and exact coordinates.
- Output groups a path once; record mode, if added, remains independently attributable.
- Retrieval metadata names lexical, structural, embedding, and rerank stages only when each actually ran.
- Provider and model identities are present for remote stages; provider failure is typed and never replaced with a success-shaped empty result.
- Corpus coverage, candidate count, files read, bytes read/submitted, and skipped/error counts are visible.
- One framework owner caps every search, inspect, similar, `xo`, nexus, indexd, discovery, byte-shard, and batch-I/O allocation/worker path at 5% of detected hardware. Explicit CLI or environment values may lower the ceiling and can never raise it.
- The hardware percentage is computed from detected capacity, not a hardcoded 4/6/8 GiB fiction. Existing lower caps may remain lower.
- Labeled tasks compare `similar -> inspect -> retry` against one `xo` call on next-read success, relevant-line recall, irrelevant bytes, round trips, latency, provider bytes, and peak resident memory.
- No promotion occurs unless exactness, warm/cold parity, and predecessor gates pass; an important gain may accept a measured loss below 10% only with explicit disposition and attempted recovery.

## Initial Findings

1. The reported path repetition is isolated to `--format records`; grouped inspect already solves it.
2. Current `similar` is real, not a stub, but its retrieval unit is the whole file up to 256 KiB and its first frontier is path-token plus uniform corpus sampling. That is expensive and weak for code-local relevance.
3. Current `similar` does not emit provider/model identity in v2, so score provenance is incomplete.
4. The former policy was split: discovery could use 16 workers, explicit `-t` bypassed scan defaults, indexd used 4/6/8 GiB profile constants, and only `xo` had a bounded allocator. That was not a framework contract.
5. On this host the common owner resolves to two workers and about 10.17 GB. Search performance must now recover within that ceiling; preserving an uncapped predecessor number is not permission to bypass policy.

## Open Work

- Build a labeled next-read evaluation corpus before promoting `xo` or refactoring semantic retrieval into reusable passages.
- Recover the remaining equal-envelope regex regression below the target without restoring route-local resource exemptions.
- Complete the ripgrep persistent warm-lane predecessor report; the full harness currently exceeds its 60-second readiness window under the two-worker index-build ceiling.
- Add adversarial `xo` long-line/large-file/binary/budget fixtures and promotion-grade response snapshots.

## Framework-Ceiling Evidence

- Canonical policy: `hardware_5_percent`; the inert `low|medium|high` resource-profile surface was removed because it no longer controlled runtime behavior.
- Host resolution: 32 logical processors -> 2 workers; 203,377,963,008 physical bytes -> 10,168,898,150 allocation bytes.
- Oversized request proof: `search ... -t 128 --json` reports `outer_scan_threads=2`, `thread_limit=2`, and `allocation_limit_bytes=10168898150`.
- Enforcement owners: capped allocation-time allocator at composition root; arena layered over that owner for short-lived command locality; direct capped allocator for indexd refresh reclamation; one thread clamp for discovery, scan, byte shards, and batch I/O; indexd environment override is lower-only.
- Stack-frame repair: the two 1 MiB per-file scan buffers moved from hot stack frames to one allocator-owned buffer per serial report or worker.
- Removed `iocp_batch.zig`: it was a test-only thread-per-file prototype that explicitly claimed to be an IOCP stepping stone but had no runtime consumer. The real scan I/O owner remains the only implementation surface.
- Two-worker recovery: static two-way file ownership replaces per-file atomic claiming at the framework ceiling; high-fanout dynamic claiming remains available above two workers on larger hardware.
- Linux ripgrep corpus, equal two-worker envelope, 39/39 literal matches: current median wall 3,125 ms versus retained 2,931 ms in the recovery sample (+6.6%). Absent literal was +3.6%. Exact run-to-run values remain host-noise sensitive.
- Regex word-boundary lane, equal two-worker envelope, 9/9 matches: current median wall 3,146 ms versus retained 2,832 ms (+11.1%). This exceeds the target by roughly one point and blocks native promotion; it remains the active performance owner.
- An uncapped predecessor comparison is diagnostic only: it violates the new compute envelope and cannot select a promotion winner.
- Output contract passed. Warm/cold mutation parity passed at 1,000 -> 101 files with identical match/evidence projections. Debug and ReleaseSmall tests passed 517/517 after the prototype deletion.

## Disposition

Pass 008 remains active. The framework cap, `xo`, exact inspect separation, grouped response structures, and similar provenance are implemented, but the regex equal-envelope regression and a completed ripgrep warm-lane report still prevent closure or native promotion. No separate QC file is justified yet: both debts are direct acceptance gates of this owner, and splitting them would create a parallel ledger.
