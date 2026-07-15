# Loop 019 - `min` Command Build Integrity

Date: 2026-07-15
Scope: current dirty worktree; no user-owned runtime edits reverted

## Frozen hypothesis

The compiler failure at `src/main.zig:107` is caused by a partially introduced
`min` command. The safe repair is not an exhaustive placeholder branch: the
command must either own its complete public path or leave the public command
union.

## Falsifier

This hypothesis is false if a `min` executor, output renderer, help renderer,
and behavior tests already exist and only the dispatch case was omitted.

## Evidence

| Check | Result |
|---|---|
| Independent compiler | `zig build -j1 -Doptimize=ReleaseSmall` fails: `src/main.zig:107:5 switch must handle all possibilities`; the unhandled tag is `cli.args.CommandTag.min` at `src/cli/args.zig:17`. |
| Parser owner | `src/cli/args.zig` defines `MinRequest`, parses `min`, and accepts level, byte-budget, JSON, and dry-run flags. |
| Dispatch owner | `src/main.zig` has no `.min` case. |
| Output owner | `src/cli/output.zig.writeHelp` has no `.min` case and no `writeMinHelp`. |
| Execution owner | Repository search found no module or call site that consumes `MinRequest`. |
| Test surface | The only `min` test verifies parser acceptance; no behavioral or output contract exists. |

## Candidate assessment

Adding `.min =>` to the main switch with a refusal, no-op, or invented output
would satisfy exhaustiveness while retaining an unimplemented public command.
It fails the falsifier-derived public-command completeness invariant and is
therefore rejected.

## Required completion boundary

The owning feature slice must choose and implement `min` semantics, then add:

1. an executor with bounded read/write and dry-run semantics;
2. a stable text and JSON output contract with typed errors;
3. parser-owned help and completion metadata;
4. exact behavior, failure, and idempotence tests;
5. a complete build and test proof.

Until that owner exists, the alternative is to remove the unshipped parser,
help topic, and command tag together in its owning change.

## Verdict

`BLOCKED`

The build cannot become a valid performance baseline while the incomplete
public command remains in the dirty worktree. No code was changed because the
only local repair candidate was a false capability; the next owner decision is
explicitly recorded in the state capsule.
