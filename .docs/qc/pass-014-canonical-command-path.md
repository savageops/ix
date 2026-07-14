# QC Pass 014 — Canonical IX Command Path

Date: 2026-07-14

## Finding

The active PowerShell profile defined `ix` as a wrapper around the retired `C:\Users\Savage\AppData\Local\Programs\iEx\bin\ix.exe`. The live native owner is `C:\Users\Savage\AppData\ix\ix.exe`; the stale wrapper made the shell appear to detect or execute the old `iEx` installation.

The same retired path was also embedded in three benchmark-contract predicates: installed-speed comparison, Teddy contract validation, and Teddy decision validation. Those predicates could misclassify the canonical install as non-native.

## Repair

- Profile wrapper now invokes `C:\Users\Savage\AppData\ix\ix.exe` and is labelled `IX native install`.
- Benchmark predicates now compare against the shared `defaultInstalledIxPath()` owner.
- Legacy `AppData\Local\ix` and `AppData\Local\Programs\iEx\bin` paths remain only in `sync-native-install.mjs` as migration/archive inputs. They are not runtime owners or benchmark identities.

## Proof

- `Get-Command ix -All` resolves the executable at `C:\Users\Savage\AppData\ix\ix.exe` after profile reload.
- `ix help search` returns the IX command contract.
- `node --check` passes for all three changed benchmark scripts.
- Canonical native and repo binaries remain SHA-256 identical.
- Retired Local and Programs install directories remain absent.
- `rg` finds no hard-coded retired path outside the deliberate migration list.

## Disposition

Keep the legacy paths only as one-way migration inputs. Remove them if migration support is ever retired; never use them as execution, benchmark, or source-of-truth paths.
