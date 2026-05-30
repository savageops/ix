---
id: 148-central-index-state-owner
type: parent
protocol_version: "2.1"
spec_status: approved
category: feature
status: done
epic_boundary: "Move IX warm-index process state, live markers, query cache, stats cache, and evidence cache out of scanned roots into one IX-owned state directory keyed by root fingerprint."
subtodo_start: /todo/pending/148a-central-index-state-owner.md
subtodo_final: /todo/pending/148d-central-index-state-owner.md
continuation: "After each completed execution unit: record evidence, set status done, move to /todo/changelog/, continue immediately to next_todo. Never batch-archive. Never pause between units."
source_message_policy: "Every lettered unit MUST include source_message_anchor, source_message_excerpt, source_message_proof_obligation, and an Original User Message Proof section with verbatim snippets from the original user message."
---
# 148 Central Index State Owner

## Objective

Make IX own its warm-index storage independently from the directory being searched. A scan root must remain input data only. Index generations, sidecar live ownership, warm query cache, stats cache, and dynamic evidence cache must resolve through a single IX state directory, with `IX_STATE_DIR` as the test/operator override and an AppData/XDG-style fallback for native installs.

## Rationale

Root-local `.ix` state conflates traversal input with runtime ownership. That makes generated or hidden roots look unmanaged, leaves stale process evidence near content, and blocks the RAM-resident delta-index work from having one durable owner. The durable shape is OPA: scanned roots identify content; the IX state owner materializes and guards process/index state; search and inspect consumers read through that owner.

## Scope

**In scope:**
- `src/core/state_dir.zig` as the canonical state-location owner.
- `src/core/indexd.zig` generation/live-marker paths.
- `src/core/generation.zig` path construction for central index roots.
- `src/core/search.zig` warm query cache, stats cache, and evidence cache paths.
- `src/main.zig` sidecar launch policy after root-local storage is removed.
- Existing test suite plus cold-path benchmark guard.

**Out of scope:**
- RAM-resident delta overlay from `147`.
- Persistent posting-list format changes.
- Runtime SIMD dispatch, daemon protocol changes, or external package additions.
- Committing generated benchmark reports.

## Source Language Anchors

- "use planning spec skill to lock it all in"
- "AFTER using insect to research the arch, understand, align. and implement"
- "why doesn't the index build in the same directory where the executable is instead"
- "So in IX's directory in app data"
- "Please check if there's any more stale processes"
- "Make sure you didn't slow the framework down"
- "run some tests, on the ripgrep dataset. at least 12 each"

## Original User Message Capture

| Anchor ID | Information Piece | Verbatim Original Snippet | Required Coverage |
|-----------|-------------------|---------------------------|-------------------|
| U1 | planning protocol | "use planning spec skill to lock it all in" | 148a, 148d |
| U2 | architecture research | "AFTER using insect to research the arch, understand, align. and implement" | 148a |
| U3 | central state direction | "why doesn't the index build in the same directory where the executable is instead" | 148b |
| U4 | native install target | "So in IX's directory in app data" | 148b |
| U5 | stale process concern | "Please check if there's any more stale processes" | 148b, 148d |
| U6 | performance guard | "Make sure you didn't slow the framework down" | 148c, 148d |
| U7 | benchmark shape | "run some tests, on the ripgrep dataset. at least 12 each" | 148a, 148d |

## Source Message Coverage

| Unit | Source Anchor(s) | Slice Proof Obligation |
|------|------------------|------------------------|
| 148a | U1, U2, U6, U7 | Capture baseline, research stale-owner/index-location architecture with Insect, and bind the plan to existing warm-index chains. |
| 148b | U3, U4, U5 | Implement one state owner for indexd generations, live markers, and sidecar eligibility. |
| 148c | U6 | Route foreground search caches through the same state owner without changing cold scan semantics. |
| 148d | U1, U5, U6, U7 | Run tests, release build, benchmark guard, stale-process scan, commit hygiene, and closeout. |

## Constraints

| Dimension | Constraint |
|-----------|------------|
| Canonical owner | `src/core/state_dir.zig` owns state-directory policy. |
| Consumer boundary | Search roots are content inputs, not writable runtime-state roots. |
| Compatibility | `IX_STATE_DIR` must make tests and native installs deterministic. |
| Performance | Cold/default scan route must not regress against the recorded ripgrep-corpus guard. |
| Relationship to 147 | This chain is a prerequisite ownership repair for the RAM-resident delta index, not a second index architecture. |

## Invariants

- I1: No warm-index generation or live marker is written under `<searched-root>/.ix/index`.
- I2: The same root fingerprint maps to the same central index directory.
- I3: Generated or hidden-looking roots can still use the sidecar because storage policy is no longer root-local.
- I4: Warm query, stats, and evidence caches use IX-owned state paths.
- I5: Existing cold/default search tests and the 12-sample ripgrep-corpus guard remain within measurement tolerance.

## Chain Manifest

| File | Phase | Role | Status |
|------|-------|------|--------|
| `/todo/pending/148-central-index-state-owner.md` | parent | Chain root | done |
| `/todo/pending/148a-central-index-state-owner.md` | a | Research / baseline lock | done |
| `/todo/pending/148b-central-index-state-owner.md` | b | Indexd/generation owner | done |
| `/todo/pending/148c-central-index-state-owner.md` | c | Search cache owner | done |
| `/todo/pending/148d-central-index-state-owner.md` | d | Validation / closeout | done |

## Phase Plan

| Letter | Role | Patch Surface | Depends On | Parallelizable |
|--------|------|---------------|------------|----------------|
| 148a | Research / baseline lock | planning docs only | none | no |
| 148b | Indexd/generation owner | `state_dir`, `indexd`, `generation`, `main` | 148a | no |
| 148c | Search cache owner | `search`, `state_dir` | 148b | no |
| 148d | Validation / closeout | tests, benchmark, process audit, git hygiene | 148c | no |

## Validation Gate

- `IX_INDEX=0 IX_NEXUS=0 IX_STATE_DIR=... zig build test --summary all`
- `IX_INDEX=0 IX_NEXUS=0 IX_STATE_DIR=... zig build -Doptimize=ReleaseFast --summary all`
- `IX_INDEX=0 IX_NEXUS=0 IX_STATE_DIR=... node tools/scripts/run-once-benchmark.mjs --profile suite-linux-word --expression 're:\bPM_RESUME\b' --corpus ... --threads 32 --warmup 2 --samples 12 --quiet`
- stale IX process scan through `Win32_Process`
- `git diff --check`

## Closeout Evidence

- Tests passed: `332/332` with indexing/nexus disabled and explicit `IX_STATE_DIR`.
- ReleaseFast build passed.
- Ripgrep-corpus 12-sample guard improved against prior IX baseline: engine `575.3829 ms` versus prior `585.3455 ms`, CLI `593.1372 ms` versus prior `604.2013 ms`; match count remained `9`.
- No stale IX/indexd/nexus executable was found after excluding the scan command.
