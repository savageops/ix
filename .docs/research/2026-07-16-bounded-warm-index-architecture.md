---
type: research-design
id: bounded-warm-index-architecture
date: 2026-07-16
status: proposed
incident: "Unbounded index generations consumed approximately 250 GB on C:"
result_owner: src/core/indexd.zig
---

# IX Bounded Warm Index Architecture

## Verdict

IX should keep indexed search, but replace the current rebuild-on-mutation generation loop with a bounded base-plus-delta lifecycle. The intended result is not “a sophisticated indexer.” It is an exact search path that remains warm across edits, updates only affected content, never publishes partial state, never surprises the user with an unbounded detached process, and cannot exceed its declared disk envelope.

This artifact is a researched architecture proposal, not a runtime repair. Warm indexing remains disabled; the current index lifecycle remains unsafe until Result 1 is implemented and passes the recurrence, quota, crash, parity, and installed-path gates below.

The design is deliberately smaller than Lucene/Tantivy/Quickwit and more capable than a monolithic Livegrep-style snapshot. It takes immutable searchable units, atomic commit points, managed-file GC, change clocks, content identity, and exact post-verification from the reference systems, but implements them through one IX binary, one root-scoped writer, one manifest format, one base segment, a bounded delta set, and one cold fallback.

## Result contract

- **Consumer:** local IX CLI, agent, MCP, maintainer, and workstation operator.
- **Current limitation:** a detached index daemon can rebuild a complete generation after each mutation while old generation payloads remain on disk; a broad root can therefore consume the volume continuously.
- **Result target:** indexed searches stay exact and fresh while index storage remains predictably bounded and mutation cost is proportional to changed content.
- **Baseline:** the observed failure produced roughly 250 GB of generated data from repeated approximately 345 MB publications.
- **Protected invariants:** no false negatives, exact final verification, deterministic output, one writer per root, atomic visibility, cold fallback, bounded RAM/CPU/handles/disk, native Windows/Linux/macOS behavior.
- **Proof:** mutation-storm and crash tests show warm/cold parity while disk usage remains below the configured cap; repository and installed binaries pass the same lifecycle probe.

## Confirmed failure mechanism

The current daemon publishes an initial complete generation and then loops forever: wait for a root mutation, settle briefly, and call `compactCurrentRootGenerationWithBudget()`. That function reads the current generation and publishes another complete catalog, postings segment, and signature with the previous epoch as parent. The generation GC planner exists and is tested, but production publication does not call it or physically delete unreachable generation directories. The memory ceiling does not govern disk.

This creates a multiplicative failure on a broad or busy root:

`ordinary write → watcher wakes → full corpus rebuild → full new generation → no physical GC → repeat`

The design defect is therefore larger than a missing `deleteTree()`. The system confuses a filesystem event with permission to rebuild, a generation with a physical copy of the entire index, and a memory budget with a complete resource envelope.

## Six-system anatomy and transferred decisions

### 1. Sourcegraph Zoekt — repository shards, serialized work, reversible cleanup

- **Primary source:** [sourcegraph/zoekt](https://github.com/sourcegraph/zoekt), pinned locally at `33f1f18af292ba83211b23e784b42dc786fb23b8`, Apache-2.0.
- **Local evidence:** `.refs/codebases/zoekt/cmd/zoekt-sourcegraph-indexserver/{index.go,queue.go,cleanup.go,merge.go}`.
- **Mechanism:** repository work is deduplicated in a keyed queue; failures back off; shard merges are globally serialized; removed shards enter a trash area before deletion; stale temporary and incomplete shards are cleaned separately.
- **Decision changed:** IX mutation intake must coalesce by root/file identity, permit only one root writer, separate retirement from deletion, and clean crash residue on startup.
- **Alternative defeated:** launching a full rebuild directly from every watcher wake-up.
- **Falsifier:** if a bounded coalescing queue increases freshness lag without reducing rebuild count and write amplification, it is not valuable.

### 2. Tantivy — atomic metadata, managed-file registry, exact live-set GC

- **Primary source:** [quickwit-oss/tantivy](https://github.com/quickwit-oss/tantivy), pinned locally at `057458bf14d6973c9c97594c1d99580b6af4c49d`, MIT.
- **Local evidence:** `.refs/codebases/tantivy/src/directory/managed_directory.rs` and `src/indexer/segment_updater.rs`.
- **Mechanism:** files are registered as managed before creation, index metadata is atomically written and synced, one segment updater serializes state transitions, and GC deletes managed files not returned by the authoritative live-file set.
- **Decision changed:** IX needs a durable managed-object inventory and mark-and-sweep from current manifests; directory age or filename patterns cannot be the authority for deleting index data.
- **Alternative defeated:** a planner that returns epochs but has no physical ownership record or post-publication executor.
- **Falsifier:** inject crashes before file creation, during payload write, and after manifest swap; no untracked file may survive recovery and no live file may be deleted.

### 3. Quickwit — explicit staged, published, and deletion lifecycle

- **Primary source:** [quickwit-oss/quickwit](https://github.com/quickwit-oss/quickwit), pinned locally at `55840e41e16a0a4ecc896df53b936aa3b4dda7e3`, Apache-2.0.
- **Local evidence:** `.refs/codebases/quickwit/quickwit/quickwit-index-management/src/garbage_collection.rs`, `quickwit-metastore/src/split_metadata.rs`, and janitor deletion/retention actors.
- **Mechanism:** searchable splits have explicit lifecycle states; publication and deletion are separate state transitions; stale staged objects and deletion-marked objects are reclaimed by dedicated ownership rather than inferred from query state.
- **Decision changed:** IX segment state must be typed as `building`, `sealed`, `referenced`, `retired`, or `delete_pending`, with recovery defined for every state.
- **Alternative defeated:** treating the presence of a newer manifest as proof that every older payload is immediately deletable.
- **Falsifier:** kill the writer at every transition and prove startup converges to one searchable manifest plus a bounded, explainable cleanup set.

### 4. Watchman — clocks, settle windows, conservative uncertainty

- **Primary sources:** [Watchman concepts](https://facebook.github.io/watchman/), [configuration and GC](https://facebook.github.io/watchman/docs/config), and [recrawl recovery](https://facebook.github.io/watchman/docs/troubleshooting), Apache-2.0.
- **Mechanism:** roots settle before triggers fire; clients consume changes from an abstract clock; pruned history makes old clocks a detectable fresh instance; overflow or uncertainty promotes to conservative recrawl instead of pretending continuity.
- **Decision changed:** filesystem notification is a wake-up hint, while a journal cursor/clock proves continuity. IX must coalesce events, persist the cursor with the published manifest, and reconcile only when continuity is lost.
- **Alternative defeated:** equating `ReadDirectoryChangesW` delivery with a complete durable change log.
- **Falsifier:** overflow, rename-storm, and deleted-history tests must either apply exact deltas or expose `reconcile_required`; silent freshness is forbidden.

### 5. Livegrep — useful simplicity and a clear scaling limit

- **Primary source:** [livegrep/livegrep](https://github.com/livegrep/livegrep), BSD-style license in `COPYING`.
- **Mechanism:** one standalone index file can be built once, memory-mapped, and reused without source access. This keeps the serving path simple, but its documented index commonly occupies three to five times the indexed text and refresh is rebuild-oriented.
- **Decision changed:** IX should preserve standalone mmap-friendly immutable segments and a trivial reader, but reject whole-index replacement for routine edits.
- **Alternative defeated:** a permanently mutable index or one giant regenerated snapshot.
- **Falsifier:** if base-plus-delta query overhead exceeds the cold verifier or produces unbounded segment fan-out, compaction thresholds or the layout must change.

### 6. GitHub Blackbird — content identity, delta ingest, commit-consistent visibility

- **Primary sources:** [The technology behind GitHub’s new code search](https://github.blog/engineering/architecture-optimization/the-technology-behind-githubs-new-code-search/) and [A brief history of code search at GitHub](https://github.blog/engineering/architecture-optimization/a-brief-history-of-code-search-at-github/). Implementation is proprietary; concepts only, no copied code.
- **Mechanism:** content is identified by Git blob object ID, duplicate blobs are indexed once, ingestion is event-driven, visibility is commit-consistent, ngram/path/symbol indices are flushed in batches, and compaction folds small indices and deletions.
- **Decision changed:** IX should separate path instances from content identity, deduplicate unchanged/duplicate content within a root, publish an entire delta batch atomically, and retain exact verification after indexed candidate selection.
- **Alternative defeated:** indexing each path’s bytes independently on every rebuild and exposing mixed pre/post-mutation state.
- **Falsifier:** on worktrees with duplicate vendor/generated content, content identity must materially reduce indexed bytes without changing path-level results or coordinates.

## Proposed architecture: one bounded root state machine

Do not introduce a service mesh, Kafka, a database, or a generic actor framework. The canonical owner remains `indexd.zig`, decomposed only at stable data/lifecycle boundaries. One root has one writer and one explicit state machine:

```text
disabled
  → bootstrap_required
  → building_base
  → publishing
  → healthy
  → dirty
  → applying_delta
  → publishing
  → collecting
  → healthy

Any state
  → reconcile_required   (journal discontinuity, schema change, corruption)
  → suspended            (disk/RAM/resource boundary, repeated failure)
  → disabled             (operator stop/removal)
```

Each transition emits one durable receipt. A watcher may move `healthy → dirty`; it may not build or publish directly. Repeated events update the same pending file task rather than enqueueing another rebuild. A full rebuild is legal only for first bootstrap, index format change, proven continuity loss, corruption, or explicit repair.

## Storage model: one base, bounded deltas, tiny manifests

```text
~/.ix/index/roots/<root-id>/
  root.ixstate                 # root identity, schema, budgets, health
  current.ixgen               # atomic pointer/manifest copy
  manifests/
    <epoch>.ixgen              # references immutable segment IDs
  segments/
    <segment-id>.ixseg         # base or delta; never copied for a refresh
  journal/
    cursor.ixcursor            # continuity identity committed with epoch
  tmp/
    <operation-id>/             # registered before payload creation
  writer.lock
```

A generation is a tiny immutable manifest, not a directory containing another complete physical copy of the corpus. A normal delta publication writes one delta segment and one manifest referencing the existing base plus the bounded live delta set. Compaction writes a replacement base, swaps the manifest, retires the prior segment set, then invokes GC.

Keep the query shape bounded: one base plus at most a small canonical number of delta segments. The exact threshold has one policy owner and must be selected by benchmark; it is not scattered through the writer. When the threshold is reached, the writer compacts before accepting another delta publication. This avoids both the current full-copy explosion and Lucene-scale merge-policy complexity.

## Identity model: paths are instances, content is reusable evidence

The catalog separates:

- `RootId`: canonical filesystem root identity.
- `FileId`: stable path instance inside a root.
- `ContentId`: hash of indexable bytes plus index schema/version.
- `FileState`: path, filesystem ID/inode, size, mtime, text/binary policy, content ID, last observed cursor.

Metadata is the cheap change filter, not final identity. A changed event stats the path; unchanged identity can be dismissed. Ambiguous or changed metadata computes `ContentId`. A rename preserves content evidence and updates path metadata. Duplicate content within the enrolled root references one postings payload while retaining every path instance. Git blob IDs may be used when trustworthy; uncommitted and non-Git files use the same local content-hash contract.

## Freshness pipeline

```text
OS notification
  → wake root owner
  → read durable change source from committed cursor
  → coalesce latest task per file identity
  → settle bounded mutation burst
  → stat/hash only affected paths
  → build one delta segment
  → fsync payload + manifest
  → atomic current swap
  → commit new cursor
  → GC unreachable objects
```

Windows uses USN journal continuity where available and `ReadDirectoryChangesW` as a low-latency wake-up/fallback invalidator. Linux uses inotify plus a persisted reconciliation watermark; macOS uses FSEvents plus its event identity. Unsupported or remote filesystems use periodic bounded reconcile or remain explicitly cold. Event overflow, cursor wrap, journal replacement, or an unknown rename never becomes “probably fresh”; it becomes `reconcile_required`, and foreground search uses the last proven generation only when its coverage contract remains valid, otherwise cold fallback.

## Disk governor: safety before throughput

Disk is a first-class resource policy beside memory and threads. Every root and the global index store have hard caps and a free-volume floor. Before creating temporary payloads, the writer computes:

```text
projected_usage = managed_live + managed_retired + temp_reserved + proposed_write
free_after_write = volume_free - proposed_write
```

The write is admitted only when `projected_usage <= root_cap`, `global_usage <= global_cap`, and `free_after_write >= free_floor`. Proposed bytes are reserved before the build begins. Retired-but-undeletable Windows mappings still count against the cap. Crossing the pressure watermark triggers GC/compaction; crossing the hard cap suspends indexing and preserves cold search. No retry loop may continue writing after a disk-budget failure.

Safe defaults must make the 250 GB incident structurally impossible. The default profile should use a modest absolute per-root cap, a global cap, a source-size ratio cap, and a volume free-space floor; operators may raise them explicitly. Exact default values are qualification outputs, not guesses in this design. `ix index status` must report live, retired, temporary, reclaimable, reserved, cap, free floor, write rate, last GC, and suspension reason.

## Publication and GC invariants

1. Register every managed path before creating it.
2. Write only under `tmp/<operation-id>` until the segment is complete and validated.
3. Seal immutable segments before writing the manifest that references them.
4. Atomically replace `current.ixgen` only after payload and cursor durability.
5. Search pins one manifest for the request lifetime.
6. GC derives the live set from current and retained manifests, never directory age alone.
7. Retain current plus one rollback generation by default; additional retention consumes declared quota.
8. Delete unreferenced temp/segment/manifest files on startup and after publication.
9. On Windows sharing violations, mark `delete_pending`, retry with bounded backoff, and count bytes against quota.
10. If cleanup cannot recover the required reserve, suspend the writer instead of publishing.

## Search contract

The warm layer never owns final truth. It owns reusable negative evidence and candidate ordering:

```text
query plan
  → pin healthy manifest
  → path/language/symbol/content postings
  → intersect/union lazy iterators
  → candidate files or blocks
  → canonical exact scanner/verifier
  → deterministic merge/output
```

Unsupported expressions, missing evidence, stale coverage, malformed state, quota suspension, or platform uncertainty fall back to the existing cold path. The index may remove a candidate only under a proven evidence domain. It may never manufacture a match. CLI, agent output, and MCP consume the same search report; protocol surfaces do not build separate index behavior.

## Capability advantage

The bounded lifecycle enables capabilities that the current full-generation loop cannot safely support:

- live uncommitted-file indexing rather than Git-commit-only visibility;
- content deduplication across duplicate files and worktrees inside an enrolled root;
- exact path, basename, extension, language, generated/vendor, symbol, and content evidence under one planner;
- optional block-level postings for giant files while retaining exact coordinates;
- instant root-scoped deletion and rename handling through catalog deltas;
- commit/batch-consistent results under concurrent edits;
- deterministic offline operation with no API, model, or network dependency;
- shared semantics across CLI and MCP;
- explicit status, repair, suspend, resume, and clean operations;
- cold-search continuity even when indexing is disabled or unhealthy.

Power comes from doing less work safely, not from adding more background machinery.

## Activation boundary

Ordinary `ix search` must not silently create a long-lived writer. Search may consume a healthy existing index and may report that no owner exists. Root enrollment and background ownership are explicit operator actions through the existing index command owner. A one-shot foreground bootstrap is allowed only when explicitly requested and after disk preflight. Broad ambiguous roots such as `.` are resolved to a canonical path, displayed, estimated, and refused when they cross safety policy unless the operator explicitly raises the boundary.

Warm indexing remains disabled by default until the lifecycle tests, quota tests, parity suite, clean build, benchmark qualification, and installed-path soak pass. Unsupported platforms remain cold with an explicit reason.

## Implementation sequence

### Result 1 — stop recurrence

Wire physical GC after every successful publication and on startup; add managed-object accounting, disk caps, free-space floor, temporary reservations, and writer suspension. Remove automatic detached writer launch from ordinary search. Prove the 250 GB reproducer cannot exceed its tiny test quota.

### Result 2 — eliminate rebuild amplification

Replace mutation-triggered full compaction with a coalescing delta queue. Persist file/content identity and publish only affected upserts/deletes. Prove mutation cost tracks changed bytes rather than corpus bytes.

### Result 3 — make generations cheap

Change manifests to reference immutable shared segments. Retain one base plus bounded deltas and one rollback manifest. Prove repeated publications do not duplicate unchanged base bytes.

### Result 4 — native freshness

Wire USN continuity on Windows, inotify on Linux, and FSEvents on macOS behind one cursor contract. Prove overflow and discontinuity become reconcile/cold fallback rather than silent stale results.

### Result 5 — expand indexed evidence

Add path/language/symbol and optional block-level evidence only after the bounded lifecycle wins. Each evidence class needs an exact-domain proof, storage-cost measurement, and consumer query that benefits.

Each result is independently promotable only after repository-versus-installed proof. Do not attempt all five in one mutation round.

## Acceptance scorecard

| Axis | Required result |
|---|---|
| Exactness | Warm and cold match/file/coordinate parity across supported expressions; uncertainty falls cold. |
| Disk | Mutation-storm usage remains below hard cap; no monotonic generation leak; startup GC converges. |
| Write amplification | Single-file edit writes a bounded delta, not a corpus-sized generation. |
| Freshness | Normal edit becomes searchable within the declared settle target; overflow becomes visible reconcile. |
| Crash recovery | Kill at each build/publish/GC transition leaves either prior or next valid generation, never partial visibility. |
| Concurrency | One writer per root; multiple readers pin deterministic immutable state. |
| Platform | Windows/Linux/macOS share semantics; unsupported backends report cold boundary. |
| Performance | Warm query materially beats cold on declared corpora without protected-axis regression. |
| Operations | Status explains bytes and state; stop/clean/repair are bounded and idempotent. |
| Installation | Installed artifact passes quota, parity, freshness, crash, and rollback probes. |

## Rejected complexity

- No Kafka, Redis, database server, network service, or external package.
- No per-query cache as the canonical warm substrate.
- No full generation copy for routine edits.
- No watcher event treated as complete freshness proof.
- No automatic daemon spawned merely because a search missed an index.
- No unbounded segment graph or merge-policy framework.
- No deletion based only on age, filename, or “newer generation exists.”
- No background write without prior disk reservation.
- No warm result without canonical exact verification.

## Final recommendation

Adopt the architecture, beginning only with Result 1. The current index format already has useful catalog, postings, manifest, pinning, and GC-planning substrate; the right move is to complete its lifecycle ownership before adding more search intelligence. Once storage is bounded and publication is governable, delta indexing and richer evidence become safe leverage instead of another path to an invisible 250 GB failure.
