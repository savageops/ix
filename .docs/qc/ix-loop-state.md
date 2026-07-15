# IX Loop State Capsule

Updated: 2026-07-15

## Current objective

Preserve the promoted native owner while isolating the remaining warm-cache
and Thompson NFA test debt.

## Active loop

- Receipt: `.docs/qc/loop-020-native-promotion.md`
- Hypothesis: removing the unshipped `min` surface and compiling the complete
  pinned tree-sitter native source set restores a source-fresh promotable binary.
- Current verdict: `PROMOTED`

## Verified state

- The unshipped `min` parser, tag, request, and parser-only tests were removed
  as one coherent public-surface rollback.
- Tree-sitter now compiles upstream `point.c` and the non-WASM branch of
  `wasm_store.c`; all four build refs verify and ReleaseFast links successfully.
- The installed owner `C:\Users\Savage\AppData\ix\ix.exe` matches candidate
  SHA-256 `5F66F4245CC2F80A1F9A04967AD8FE46B0BD8C0A2265647D30C19E1A899C8B5C`.
- Native help, version, source-freshness, cold/warm parity, JSON v3 search, hash,
  backup, and PATH-owner probes pass.
- Full ReleaseFast tests report 539/549 passing; ten known failures remain in
  warm-query-cache and Thompson NFA lanes and are not represented as green.

## Next action

Repair the ten remaining tests at their warm-cache and Thompson NFA owners,
then rerun the strict `sync-native-install.mjs --build` lane.
