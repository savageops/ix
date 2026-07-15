---
id: 157-min-command-completion-boundary
type: decision-required
status: complete
priority: P0
owner: cli-command-spine
source: ix-perpetual-ascent-loop-019
canonical_owner: src/cli/args.zig + src/main.zig + src/cli/output.zig
---

# Resolve the unshipped `min` public-command boundary

## Objective

Restore a complete command union and hermetic build without retaining an
unimplemented public capability.

## Evidence

`CommandTag.min` and `MinRequest` were added in the dirty worktree, but the
command has no executor, output/help owner, or behavioral tests. The compiler
correctly rejects the non-exhaustive `src/main.zig` dispatch switch.

## Required decision

Either complete `min` end-to-end with explicit product semantics and proof, or
remove its parser/public-surface additions as one coherent owning change. Do
not add a stub dispatch arm.

## Acceptance

- Every public `CommandTag` has parse, dispatch, help, output/error, and
  behavior-test ownership.
- `zig build -j1 -Doptimize=ReleaseSmall` passes without network access.
- `zig build test --summary all` reports any non-command failures separately.

## Closure evidence

- Removed the unshipped tag, help topic, request type, parser branch, helper,
  and parser-only tests together; no placeholder dispatch arm remains.
- ReleaseFast executable build succeeds.
- The full suite now reaches runtime tests and reports 539/549 passing; the ten
  remaining failures are independently owned by warm-query-cache and Thompson
  NFA paths.
