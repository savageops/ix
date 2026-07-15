---
id: 156-refs-index-bootstrap
type: implementation
status: complete
priority: P1
owner: refs-substrate
source: user-request-2026-07-15
canonical_owner: .refs/index.md + scripts/bootstrap-refs.ps1
---

# Tracked-index-only `.refs` collection

## Objective

Make `.refs/index.md` the sole tracked reference artifact while keeping
build-critical payloads reproducible and `zig build` network-free.

## Slices

- **A — Manifest:** record every build and research source with URL, ref,
  commit SHA, archive SHA-256, license, local path, role, status, and rationale.
- **B — Bootstrap:** restore selected groups through verified GitHub archives;
  reject unsafe paths, mismatched hashes, duplicate metadata, and silent
  overwrite.
- **C — Policy:** align project and global `AGENTS.d` owners with the tracked
  index and explicit bootstrap boundary.
- **D — Research ledger:** record the admitted source anatomy and transfer
  boundary in the canonical competitor map.
- **E — Proof:** verify ignore parity, manifest validity, bootstrap idempotence,
  missing/corrupt ref failures, and the offline build boundary.

## Invariant and rollback

Only `.refs/index.md` is tracked. Research payloads never enter `build.zig`.
If bootstrap or build validation fails, preserve the manifest and diagnose the
specific source/path mismatch; do not restore the pre-migration vendored tree
or reset unrelated dirty work.

## Acceptance

- Four build-critical refs and eighteen research refs have complete provenance.
- `scripts/bootstrap-refs.ps1 -Group build` restores all required build paths.
- `scripts/bootstrap-refs.ps1 -VerifyOnly` passes after restoration and fails
  on a missing marker, wrong hash, or missing required path.
- `.refs/index.md` is the only tracked `.refs` path.
- Build and test results distinguish ref restoration failures from existing
  non-ref source failures.

## Closure evidence

- `bootstrap-refs.ps1 -Group all -VerifyOnly`: 22/22 verified.
- Clean temporary refs root: verify-only failed as expected, then build refs
  restored and verified from the manifest alone.
- `git ls-files .refs`: `.refs/index.md` only; all payload probes resolve to the
  `.gitignore` rule.
- ReleaseSmall build and test compilation reached IX sources; the remaining
  failure is the pre-existing `CommandTag.min` exhaustiveness defect at
  `src/main.zig:107`. The test runner reports 130/130 passing.
