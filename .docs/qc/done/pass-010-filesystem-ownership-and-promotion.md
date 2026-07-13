# Pass 010 — Filesystem Ownership And Promotion

Status: complete
Date: 2026-07-13

## Contract

- Mutable IX state has one owner: `~/.ix/` on Windows, Linux, and Unix.
- Persistent indexes live under `~/.ix/index/`; caches live under `~/.ix/cache/`.
- Windows has one live executable: `~/AppData/ix/ix.exe`.
- Historical executables live only under `~/AppData/ix/backups/`.
- Candidate verification and unit tests must never touch operator state.

## Findings And Repairs

- The apparent `E:\Workspaces\ix-zig` index root was a stale test fixture, not a runtime default. It was replaced with a disposable `.zig-cache` fixture and a repository-wide search now returns zero occurrences.
- Runtime state previously defaulted to `%LOCALAPPDATA%\ix`; it now resolves `IX_STATE_DIR`, then `USERPROFILE/.ix` or `HOME/.ix`.
- Installer verification created `~/.ix` before migration. Verification now receives an isolated temporary `IX_STATE_DIR` and deletes it in `finally`.
- The preserved 2.83 GB historical state was restored whole to `C:\Users\Savage\.ix`; no generation trees were merged. The 50 KB verification-created state remains archived as recovery evidence.
- Test processes previously inherited operator state. `zig build test` now forces `.zig-cache/ix-test-state`.
- Seven stale test/runtime markers in the restored index were removed through the IX-owned `process cleanup` contract.
- The obsolete `Programs/iEx/bin` install was retired, its PATH entry removed, and its binaries archived without deletion.

## Proof

- ReleaseSmall: `522/522` tests passed.
- Test isolation: operator-state signature stayed exactly `18044:2827280283:639195687442761106` before and after the suite.
- Promotion isolation: operator-state signature stayed unchanged across candidate verification and install.
- Installed/repository SHA-256: `35E34800C65F1445F60131F2693D71B3FD443949047D63B622E8860FFE0F901C`.
- Install root contains exactly one file: `ix.exe`.
- Backup directory contains 11 predecessor executables.
- Persistent user PATH contains `C:\Users\Savage\AppData\ix` and no legacy IX install entry.
- `ix process status --json` reports `state_dir: C:\Users\Savage\.ix`.
- Repository search for literal `E:\Workspaces\ix-zig`: zero matches.

## Residual Boundary

- `config.json` and `auth.json` are reserved future owners under `~/.ix`; the installer does not manufacture placeholder capability.
- The current parent shell may retain an old function or PATH snapshot until restarted. Persistent PATH is correct; no compatibility shim was added.
- The broader `--quick` architecture gate is not globally green. Filesystem ownership, native identity, process scan, state-location, and the 522-test lane pass; independent failures remain in stale Teddy decision evidence, legacy path-sentinel expectations, cold smoke, warm/cold case-policy parity, live-index refresh, and generation-recovery expectations. The machine-readable report is `.docs/qc/ix-architecture-filesystem-pass-010.json`; these failures are not concealed by this completed ownership pass.
