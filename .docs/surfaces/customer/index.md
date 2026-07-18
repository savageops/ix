# Customer-path proof

## 2026-07-18 — agent error escalation receipt

- Built the packaged ReleaseSmall executable with `zig build -j1 -Doptimize=ReleaseSmall`.
- Ran `zig-out/bin/ix-zig.exe inspect ./definitely-missing-ix-agent-receipt.txt` from the consumer command surface. It exited `1` and emitted `ix.error.v1` with `agent_action`: errors that conflict with observed state must be reported as an IX issue or regression with the command, target, and raw error.
- Ran `zig-out/bin/ix-zig.exe search 'lit:writeErrorDetail' src/cli/output.zig --format json-compact`. It exited `0`, emitted `ix.result.v3`, and did not emit `agent_action`; ordinary successful results remain clean.
- Residual suite boundary: `zig build test -j1` is independently red at 564/577 passing, with 9 failures and 4 crashes in warm-index and Thompson-NFA tests. This error-envelope change is covered by its passing output test and the packaged CLI probes above.
