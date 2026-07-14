# QC pass 016 — README capability injection

## Finding

The README already described SIMD search, fisheye previews, warm generations, and versioned agent output, but it underrepresented shipped agent-context ranking and resource ownership. It also described semantic lexical ordering without stating the important non-exclusion invariant.

## Changes

- Added BM25-ranked agent context to the product promise and command table.
- Added an Agent Context Lane section for `xo`: stop-word removal, code-vocabulary aliases, BM25 scoring, structural/path tie-breaking, degree-of-interest span expansion, bounded projections, and visible omissions.
- Added the framework-wide 5% memory/thread ceiling and its config/env owners.
- Clarified semantic similarity’s lexical frontier: lexical overlap prioritizes candidates but never excludes zero-overlap files; embeddings recall and reranking orders.
- Added the validated warm-postings block-pruning mechanism and its generation/reader safety boundary.

## Evidence

- `src/core/xo.zig`: BM25 scoring, concept aliases, structural prior, bounded span selection, coverage envelope.
- `src/core/similar.zig`: lexical frontier union, embedding recall, reranker ordering, anti-ranking, cursor-bound coverage.
- `src/core/resource_profile.zig`: one capped allocator and 5% default memory/thread ceilings with config/env overrides.
- `src/core/postings.zig`: validated block metadata and candidate-prunable block proof.

## Proof

- `git diff --check` passed.
- `zig build test -Doptimize=Debug` passed.

## Disposition

Keep README additions capability-led and evidence-backed. Roadmap-only mechanisms remain in Roadmap and are not promoted into the shipped product promise.
