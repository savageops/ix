# Loop 020 - Native promotion closure

Date: 2026-07-15

## Frozen hypothesis

The checkpointed source can produce a valid native candidate once two
integration defects are repaired: the unshipped `min` public surface is removed
coherently, and the pinned tree-sitter runtime compiles its real native point
and non-WASM store sources instead of an empty compatibility stub.

## Falsifier

Reject promotion if ReleaseFast does not link, any build ref fails manifest
verification, the candidate is source-stale, cold/warm output differs, the
installed hash differs from the candidate, or the rollback binary is not
preserved.

## Evidence

- `bootstrap-refs.ps1 -Group build -VerifyOnly`: 4/4 verified.
- `zig build -j1 -Doptimize=ReleaseFast --summary all`: 3/3 succeeded.
- `zig build test -j1 -Doptimize=ReleaseFast --summary all`: 539/549 passed;
  ten pre-existing warm-query-cache and Thompson NFA failures remain explicit.
- `sync-native-install.mjs --dry-run`: source freshness and cold/warm output
  parity passed before mutation.
- Atomic install promoted SHA-256
  `5F66F4245CC2F80A1F9A04967AD8FE46B0BD8C0A2265647D30C19E1A899C8B5C`.
- Previous SHA-256
  `D135996FCAAE7F0621E8BE6790E977DE077EDB757C872772714233AB95C895C4`
  is preserved at `C:\Users\Savage\AppData\ix\backups\ix.old.150726.exe`.
- Direct installed probes passed for `--version`, search help, canonical v3
  JSON search, executable hash, and `where ix` ownership.

## Verdict

`PROMOTED`

The native owner now matches the fresh ReleaseFast candidate. The broader test
suite is not green; its ten remaining failures stay as named debt rather than
being folded into the promotion claim.
