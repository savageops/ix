# IX Zig Warm Layer Sidecar Architecture

Generated: 2026-05-11

## Verdict

The current Nexus evidence frontier is a **query-keyed retained candidate cache with invalidation**, not a true warm index.

To reach the level the user is asking for, `ix-zig` needs a **persistent corpus-global background indexer** with:

`FileCatalog -> DeltaLog -> SegmentWriter -> SearcherRefresh -> Compaction`

The sidecar must stop thinking in terms of “cache this query result set” and start thinking in terms of “maintain a searchable repository state that many queries can reuse.”

Watcher-only designs do not achieve this. A watcher can tell you *that* something changed. It does not give you a reusable searchable structure. The speedup comes from a maintained index plus a cheap delta-application path.

## Current Boundary

Current local shape:

`search/matches`
  `-> foreground discovery`
  `-> foreground scan`
  `-> hidden __ix_nexus sidecar`
  `-> writes .ix-evidence-{key}.cache`
  `-> holds .live marker while tree is unchanged`

What it does well:

- Silent detached background build.
- Fast replay for the exact same eligible expression/root surface.
- Fail-closed freshness boundary via metadata/content signatures.
- Windows tree mutation invalidates the live marker without polluting correctness.

What it cannot do:

- Reuse work across *different* queries.
- Apply deltas on file mutation.
- Keep a persistent searchable corpus hot after invalidation.
- Avoid cold rediscovery after the watched tree changes.
- Provide commit/epoch-pinned search visibility across concurrent updates.

The current design is therefore a **frontier replay lane**, not a **maintained retrieval substrate**.

## Implementation Status: Warm Postings + Hidden Indexd Lifecycle + Generation Refresh

As of 2026-05-11, the first corpus-global warm-index primitives, hidden maintenance-process lifecycle, and generation publication substrate are implemented as verified internal substrate. Foreground search adoption is still intentionally disabled until candidate pruning can open the current manifest and prove verifier-equivalent results.

Implemented:

- `FileCatalog`: deterministic root fingerprint, stable file IDs, sorted path metadata, versioned little-endian serialization, atomic publish helper, wrong-root/truncated/unsorted rejection.
- `PostingsSegment`: trigram-to-FileId postings, root/generation pinning, versioned little-endian serialization, sorted unique postings validation, malformed density rejection, and bounded count guards.
- `LookupPlan`: expression evidence lowering through the existing trigram admission owner, AND intersection, OR union, and explicit `RequiresFullScan` fallback for no-evidence or unsafe disjunctive queries.
- Verifier handoff: postings candidates select catalog entries only; the existing verifier remains the sole owner of match correctness.
- Telemetry: public JSON stats expose inactive/fail-closed `catalog_index` and `postings_index` nodes so adoption can be measured without pretending the sidecar is already live.
- Hidden `__ix_indexd`: one-binary maintenance role with root-local `.ix/index`, nonblocking exclusive root lock, heartbeat marker, foreground bootstrap marker, and cleanup on normal return.
- Toggle boundary: public `search` / `matches` detach the index daemon only when `IX_INDEX=1`, `IX_INDEX=true`, or `IX_INDEX=on`; default behavior is unchanged and the sidecar stdout/stderr contract is silent.
- `GenerationManifest`: versioned `IXGEN001` manifest bytes, epoch/root validation, parent epoch, segment list, atomic per-epoch manifest publication, stable `.ix/index/current.ixgen` refresh, and `ReaderPin` semantics for foreground adoption.
- Refresh telemetry: public JSON stats expose inactive/fail-closed `generation_refresh` with `epoch`, `refresh_status`, and `fallback_reason`, preserving the no-pretend contract while adoption remains disabled.
- Parity proof: disabled/enabled public `matches` output was hash-identical on a throwaway corpus while the enabled run created the internal sidecar index directory.

Not yet implemented:

- USN-backed delta ingestion and root-settle batching.
- Foreground search adoption of existing postings segments.
- Compaction, tombstones, and generation garbage collection.

Operationally, this means IX now has the internal data model, opt-in silent process boundary, and atomic current-generation pointer needed for cross-query reuse, but it still does not claim foreground acceleration from resident index state. The next milestone is adoption: foreground search must verify root/generation compatibility from `.ix/index/current.ixgen`, open catalog/postings segments, and only then prune candidates before the verifier.

## Why Query-Keyed Frontiers Plateau

1. Query-keyed caches scale with query diversity, not corpus size.
2. The moment files change, the current lane drops to invalidation instead of delta repair.
3. New queries still pay discovery/admission because there is no corpus-global postings structure.
4. Search-time work is still coupled to repository traversal instead of a precomputed retrieval state.

This is the exact point where serious systems stop optimizing grep-shaped scans and introduce a background indexer.

## External Research

### 1. GitHub Blackbird: event-driven indexing, delta ingest, shard-local indices

```text
Evidence: .docs/research/insect/warm-layer-2026-05-11/page-github-code-search.md:199
Observation: Blackbird shards by blob object ID and models the index as a tree with delta encoding.
Impact: work is reduced by deduplicating content and by indexing repository deltas instead of whole trees.
Action: move ix-zig from query-keyed frontier caches toward corpus-global file/blob identity plus delta application.
```

```text
Evidence: .docs/research/insect/warm-layer-2026-05-11/page-github-code-search.md:203
Observation: query results are commit-consistent; new commits are hidden until fully processed.
Impact: background indexing must publish searchable generations atomically, not leak half-applied updates.
Action: add epoch/generation pinning to ix-zig searcher refresh.
```

```text
Evidence: .docs/research/insect/warm-layer-2026-05-11/page-github-code-search.md:209
Observation: indexing is driven by events, partitioned by shard, and decoupled from crawling.
Impact: sidecar ownership must be ingest/apply/flush; foreground search must not perform indexing work.
Action: introduce a dedicated hidden indexer mode rather than expanding the foreground Nexus scan lane.
```

```text
Evidence: .docs/research/insect/warm-layer-2026-05-11/page-github-code-search.md:217
Observation: shards build ngram and metadata indices, flush accumulated work, then compact smaller indices into larger ones.
Impact: the right substrate is segment-based with periodic compaction, not one mutable monolith file.
Action: implement immutable delta segments plus background compaction.
```

### 2. Zoekt / GitLab: single binary, persistent on-disk index, async indexing ownership

```text
Evidence: .docs/research/insect/warm-layer-2026-05-11/page-zoekt-readme.md:339
Observation: Zoekt runs an index server that periodically fetches and reindexes repositories while a web server serves queries.
Impact: mature code search separates search serving from index maintenance while keeping one canonical index format on disk.
Action: keep one ix-zig binary with hidden indexer/searcher modes instead of a second codebase or second index format.
```

```text
Evidence: .docs/research/insect/warm-layer-2026-05-11/page-gitlab-zoekt-design.md:398
Observation: GitLab distinguishes incremental indexing, full reindex, and delete tasks, with a lock to prevent overlapping index operations per repo.
Impact: ix-zig needs explicit task kinds and single-owner mutation per root/index shard.
Action: define `apply_delta`, `rebuild_root`, and `delete_path` tasks with root-scoped exclusion.
```

```text
Evidence: .docs/research/insect/warm-layer-2026-05-11/page-gitlab-zoekt-design.md:491
Observation: asynchronous callback architecture reduced blocking job pressure and let indexing scale by node capacity.
Impact: background indexing must report completed generations back to the searchable manifest, not block user queries.
Action: make the sidecar publish refreshed manifests only after segment write success.
```

```text
Evidence: .docs/research/insect/warm-layer-2026-05-11/page-gitlab-zoekt-design.md:523
Observation: one binary can run indexer and search modes simultaneously while serving persistent on-disk index files.
Impact: the sidecar can stay canonical without creating a product-level “second system.”
Action: model future ix-zig as one binary, dual mode: `search` and hidden `__ix_indexd`.
```

### 3. Lucene / Elastic NRT: refresh is lighter than commit

```text
Evidence: .docs/research/insect/warm-layer-2026-05-11/page-elastic-nrt.md:131
Observation: Lucene treats an index as segments plus a commit point.
Impact: immutable segment publication is the right mental model for searchable generations.
Action: store ix-zig index state as manifest + immutable segment set.
```

```text
Evidence: .docs/research/insect/warm-layer-2026-05-11/page-elastic-nrt.md:133
Observation: new segments become searchable first through filesystem cache, then later flush to disk.
Impact: there is a meaningful distinction between “search-visible” and “durably committed.”
Action: add a cheap local refresh path before expensive compaction/commit work.
```

```text
Evidence: .docs/research/insect/warm-layer-2026-05-11/page-elastic-nrt.md:138
Observation: new searchable state can be opened without a full commit.
Impact: ix-zig can publish micro-delta segments quickly and compact later.
Action: separate `refresh_epoch` from `compact_epoch`.
```

### 4. Watchman + USN Journal: watchers are invalidators/delta feeds, not search engines

```text
Evidence: .docs/research/insect/warm-layer-2026-05-11/page-watchman.md:7
Observation: Watchman watches roots recursively and waits for roots to settle before notifications.
Impact: raw mutation streams need debounce/coalescing before index application.
Action: add root-settle batching to background delta ingestion.
```

```text
Evidence: .docs/research/insect/warm-layer-2026-05-11/page-watchman.md:10
Observation: Watchman is conservative and marks files fresh when unsure.
Impact: correctness-safe uncertainty must promote to re-verify/rebuild, not silent trust.
Action: use fail-closed invalidation when journal continuity is lost.
```

```text
Evidence: .docs/research/insect/warm-layer-2026-05-11/page-fsutil-usn.md:333
Observation: the USN journal is a persistent append-only change log for NTFS volumes.
Impact: this is the correct Windows-native delta source for a real warm layer.
Action: prefer USN-backed delta ingestion over repeated full metadata walks on NTFS.
```

```text
Evidence: .docs/research/insect/warm-layer-2026-05-11/page-fsutil-usn.md:437
Observation: programs can consult the USN journal to determine all modifications more efficiently than timestamps or file notifications.
Impact: `ReadDirectoryChangesW` should be the fallback invalidator; USN should be the primary fast delta feed.
Action: build a two-tier Windows freshness owner: USN primary, directory watch fallback.
```

```text
Evidence: .docs/research/insect/warm-layer-2026-05-11/page-fastfilewatch-readme.md:265
Observation: a practical Windows stack separates full scan/index build, search structures, and a USN watcher that keeps them live-updated with zero rescans.
Impact: the architectural split the user wants is already a known successful pattern.
Action: split ix-zig into catalog/index/searcher state plus a journal-fed updater.
```

```text
Evidence: .docs/research/insect/warm-layer-2026-05-11/page-everything-recent-changes.md:135
Observation: Everything exposes recent changes by loading from the USN journal and reports real-time index changes.
Impact: high-quality Windows local search relies on journal-fed index maintenance, not foreground rescans.
Action: treat NTFS journal integration as the pivotal Windows-native upgrade path.
```

## Target IX Zig Architecture

### Canonical subsystem

One binary. Two hidden roles. One index format.

`ix search`
  `-> open current manifest`
  `-> mmap searchable segments`
  `-> evaluate query against corpus-global postings`
  `-> verify candidate files/lines`

`ix __ix_indexd`
  `-> build or attach FileCatalog`
  `-> consume change feed`
  `-> apply delta tasks`
  `-> write immutable delta segment`
  `-> atomically publish refreshed manifest`
  `-> compact later`

### Storage layout

Implemented/current repo-local shape:

```text
.ix/
  index/
    current.ixgen
    generations/
      <refresh_epoch>/
        manifest.ixgen
        catalog.ixcat
        postings.ixpost
    journals/
      ntfs-usn.json
      fallback-events.log
    tmp/
```

### Core data structures

- `FileCatalog`
  Stable file IDs, canonical path table, root ownership, binary/text bit, size, mtime, file index/inode, optional content hash.
- `PathMetaIndex`
  Extension, basename, directory prefixes, hidden/generated/vendor flags.
- `TrigramPostings`
  Corpus-global exact trigram postings keyed by file ID, not query-keyed candidate sets.
- `GenerationManifest`
  Search-visible refresh epoch with segment list, root fingerprint, parent generation, and fail-closed validation.
- `DeltaTask`
  `upsert_file`, `delete_file`, `rebuild_root`, `reconcile_root`.
- `JournalCursor`
  NTFS USN cursor on Windows; fallback watcher cursor otherwise.

### Search refresh protocol

`IndexBuilding`
  `-> write delta segment`
  `-> fsync/close`
  `-> publish manifest under generations/N+1/`
  `-> atomically replace current.ixgen`
  `-> new searches pin generation N+1`
  `-> existing searches finish on generation N`

This is the missing level above the current `.live` file. A query should never have to ask “is the cache still okay?” by re-walking the entire tree. It should open a generation that the sidecar has already declared searchable.

### `refresh_epoch` vs `compact_epoch`

`refresh_epoch` is the reader-visible searcher generation. It advances when the sidecar has written complete segment payloads, serialized a valid `IXGEN001` manifest, and atomically replaced `.ix/index/current.ixgen`. A foreground search may pin that epoch for its lifetime; if the manifest is missing, malformed, wrong-root, incomplete, or future-versioned, foreground search must fall back to the cold verifier-owned path.

`compact_epoch` is a future maintenance watermark, not a foreground adoption contract. Compaction may merge small segment graphs, fold tombstones, and schedule old generations for deletion, but it cannot mutate the segment set behind a live `ReaderPin`. Garbage collection therefore depends on reader-pin retention or a conservative age/epoch policy, not on the mere existence of a newer refresh.

## Windows-First Freshness Strategy

### Required ownership split

1. `ReadDirectoryChangesW` is not enough.
   It is a good low-latency invalidator and wake-up signal.

2. NTFS USN journal is the serious path.
   It gives append-only volume changes and continuity semantics.

3. Fallback semantics must remain conservative.
   If the USN cursor is lost, wrapped, or inaccessible:
   full root reconcile, publish a new generation, and continue.

### Recommended policy

- `USN available + cursor valid`
  Apply exact deltas in background.
- `USN unavailable but directory watch available`
  Mark roots dirty, coalesce, then perform bounded reconcile scans.
- `watch overflow / uncertainty / cursor discontinuity`
  Escalate to root rebuild for affected roots only.

This preserves the current repo’s fail-honest doctrine.

## What The Sidecar Must Actually Do

Not acceptable:

- keep only `.ix-evidence-{query}.cache`
- delete `.live` on mutation
- hope the next foreground run rebuilds useful heat

Required:

- maintain a long-lived searchable corpus state
- consume mutation deltas continuously
- publish refreshed generations atomically
- make new queries reuse the same corpus structures
- compact and garbage-collect obsolete generations

If this is not true, it is still just an invalidation cache.

## Staged Implementation Path For IX Zig

### Stage 0. Keep Nexus as the bootstrap lane

Do not delete the current evidence frontier yet. It is a useful narrow benchmark lane and a correctness-safe stepping stone.

### Stage 1. Introduce persistent `FileCatalog`

Replace discovery-as-query-work with a background-built catalog:

- stable file IDs
- path table
- metadata table
- root/version manifest

Search still scans files directly at this stage, but discovery is no longer in the hot path.

### Stage 1 implementation status: `137` FileCatalog foundation

Implemented substrate:

```text
src/core/catalog.zig
  -> RootIdentity / RootFingerprint
  -> PathTable / PathEntry / FileId
  -> FileMeta / TextKind
  -> CatalogHeader / CatalogSnapshot
  -> buildCatalogBytes()
  -> serializeCatalog() / parseCatalog() / parseCatalogForRoot()
  -> publishCatalogBytes()
```

Search-facing telemetry:

```text
src/core/stats.zig
  -> SearchStats.catalog_index: CatalogIndexStats

src/cli/output.zig
  -> stats.catalog_index JSON object
```

Intended on-disk object:

```text
.ix/
  index/
    generations/
      <generation>/
        catalog.bin
```

Current publication contract:

- `catalog.bin` is a versioned little-endian binary object with `IXCAT001` magic and `FORMAT_VERSION = 1`.
- Root identity is embedded in the header; `parseCatalogForRoot()` rejects wrong-root state.
- Path and metadata tables must have matching file IDs and strictly sorted paths.
- Truncated, malformed, unsorted, wrong-root, and out-of-bounds catalog state fails closed before search can observe it.
- Atomic publication is provided by `publishCatalogBytes()` using temp-file creation plus replacement.
- Public search does not yet consume the catalog. The only public surface is inactive telemetry: `stats.catalog_index.enabled=false`, `available=false`, `fallback_reason="not_wired"`.

Adoption boundary:

```text
FileCatalog exists
  -> corpus-global postings do not exist yet
  -> hidden __ix_indexd does not own catalog refresh yet
  -> foreground search still uses the current cold/materialized path unless Nexus evidence-frontier reuse is independently available
```

This keeps the user-visible invariant honest: no toggle claims a silent warm index exists until candidate selection can open a published generation and prove verifier-equivalent results.

### Stage 2. Add corpus-global trigram postings

Build exact trigram postings by file ID:

- query path becomes postings intersection -> candidate file set
- verifier remains canonical owner of exactness
- current `TrigramAdmissionProgram` survives as verifier-side admission, not the primary searchable substrate

This is the exact point where new queries start benefiting, not only repeated identical queries.

### Stage 3. Add hidden `__ix_indexd`

The same binary gains a persistent sidecar mode:

- owns catalog build
- owns watcher/journal cursor
- owns delta task application
- writes new searchable generations

Public CLI remains unchanged.

### Stage 4. Add `refresh_epoch`

Implemented substrate:

- write new delta segments
- publish per-epoch manifest under `.ix/index/generations/<epoch>/manifest.ixgen`
- atomically swap `.ix/index/current.ixgen`
- new queries observe the new epoch
- old queries continue on the prior epoch

This is the Lucene NRT lesson applied locally. Foreground adoption still remains disabled until catalog/postings segment opening is wired into search candidate selection.

### Stage 5. Add compaction

Periodic background merge:

- collapse tiny delta segments
- fold deletes/tombstones
- rebuild postings density classes
- free dead generations after no reader pins them

### Stage 6. Add NTFS USN primary path

Once the segment protocol exists, upgrade invalidation to true delta application:

- map journal records -> affected file IDs
- schedule `upsert_file` / `delete_file`
- rebuild only touched postings/path-meta entries

That is the “level it is not yet on.”

## Recommended Internal Toggle Surface

Avoid productizing this as a user-visible “warm query mode.” Keep the user contract simple and exact.

Internal controls should look like:

```text
IX_INDEX=off
IX_INDEX=foreground-bootstrap
IX_INDEX=background
IX_INDEX=background-usn-preferred
```

But the public mental model should remain:

`ix search` is fast because a local searchable state exists.

Not:

`ix search` sometimes uses a mystery query cache.

## Failure Modes To Design Explicitly

- USN cursor discontinuity
  -> root reconcile
- rename storms
  -> coalesced batch apply
- giant branch switch
  -> root-local rebuild task
- stale reader on compacted generation
  -> refcount or epoch pin before unlink
- partial delta publish
  -> manifest not swapped; old generation remains live
- sidecar death
  -> foreground continues searching the latest committed generation

## Direct Recommendation

The next real move is **not** another enhancement to `.ix-evidence-{key}.cache`.

The next real move is:

`Nexus frontier -> persistent FileCatalog -> corpus-global trigram postings -> hidden __ix_indexd -> generation refresh -> USN delta apply`

That is the smallest architecture shift that converts the current silent background helper into a genuinely self-maintaining warm layer.

## Harvest Artifacts

Primary research harvest:

- `.docs/research/insect/warm-layer-2026-05-11/page-github-code-search.md`
- `.docs/research/insect/warm-layer-2026-05-11/page-zoekt-readme.md`
- `.docs/research/insect/warm-layer-2026-05-11/page-gitlab-zoekt-design.md`
- `.docs/research/insect/warm-layer-2026-05-11/page-elastic-nrt.md`
- `.docs/research/insect/warm-layer-2026-05-11/page-watchman.md`
- `.docs/research/insect/warm-layer-2026-05-11/page-fsutil-usn.md`
- `.docs/research/insect/warm-layer-2026-05-11/page-everything-recent-changes.md`
- `.docs/research/insect/warm-layer-2026-05-11/page-fastfilewatch-readme.md`
- `.docs/research/insect/warm-layer-2026-05-11/reddit-code-search-tools.md`
- `.docs/research/insect/warm-layer-2026-05-11/reddit-github-code-search-indexing.md`
- `.docs/research/insect/warm-layer-2026-05-11/youtube-github-universe-code-search-transcript.json`
- `.docs/research/insect/warm-layer-2026-05-11/youtube-trigram-trick-transcript.json`
- `.docs/research/insect/warm-layer-2026-05-11/youtube-lucene-indexing-searching-transcript.json`
