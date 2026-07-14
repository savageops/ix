# QC pass 015 — help contract

## Finding

The top-level help mixed search-only flags into a global-looking “Output” section and did not show the shortest agent workflow. Inspect’s generic flags had blank descriptions, and continuation behavior was documented later than the action it explains.

## Change

- Reframed top-level help around the six lanes and copyable agent quickstarts.
- Marked `--json`, `--agent`, and `--context` as scoped controls instead of universal flags.
- Added explicit inspect descriptions for hidden paths, symlinks, threads, and match caps.
- Clarified that `records` is the pipe-friendly inspect projection and `grouped` is the default agent-readable projection.
- Added WHY comments at the help owners so future edits preserve the task-shaped front door.

## Proof

- `zig build test -Doptimize=Debug` passed.
- Release build completed with `zig build -Doptimize=ReleaseSmall`.
- Built binary emitted non-empty help for top-level, search, matches, inspect, similar, xo, explain, and process.
- Top-level help now leads with search, inspect, context, explain, and lane-specific help commands.

## Disposition

Keep detailed option matrices in subcommand help. Keep top-level help as a routing surface, not a duplicate reference manual.
