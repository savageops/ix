# IX Perpetual Ascent Doctrine

## Purpose

IX improves through falsifiable loops, not momentum or accumulated claims:

`Inspect -> doubt -> measure -> research -> design -> implement -> attack -> prove -> compare -> commit -> compress state -> repeat.`

The target is exact, portable, reproducible search. A precise limited guarantee
is stronger than an impressive false theorem.

## Non-negotiable rules

- Source, compiler output, tests, retained reports, and independent tools rank
  above memory, summaries, and stale documentation.
- IX may inspect itself, but it may not be the sole oracle used to inspect
  itself.
- Every material run has exactly one terminal verdict: `PROMOTED`, `REJECTED`,
  `REVERTED`, or `BLOCKED`.
- A parser, help entry, flag, or command name is not a capability. A public
  command owns parse, execution, output, errors, help, tests, and measured
  behavior before it may ship.
- Correctness, deterministic output, bounded resource behavior, and declared
  failure semantics gate performance work. Benchmark noise is a measurement
  defect until disproved, not an engine verdict.
- `zig build` remains hermetic and network-free. Reference acquisition happens
  only through the tracked `.refs/index.md` bootstrap contract.

## Loop machinery

| Doctrine obligation | Canonical mechanism |
|---|---|
| Frozen hypothesis and falsifier | `.docs/qc/loop-*.md` immutable receipt |
| Current priority, known blockers, next action | `.docs/qc/ix-loop-state.md` overwriteable capsule |
| Code ownership and architectural boundaries | `AGENTS.md` and `.docs/architecture/ix-agent-operating-instruction.md` |
| Source intake and provenance | `.refs/index.md`, `.docs/research/competitor-anatomy-map.md` |
| Build/test/benchmark proof | compiler/test output and retained reports under `.docs/qc` or `.docs/reports` |
| Durable task state | `.docs/todo/pending/` and `.docs/log.md` |

## Required phases

1. Reconstruct the valid predecessor and current owner path.
2. Find contradictions across source, tests, documentation, behavior, and
   benchmark receipts.
3. Select the highest-value falsifiable gap; do not create a feature-shaped
   facade to make the compiler quiet.
4. Write the hypothesis, invariant, and disproof condition before mutation.
5. Research only when it changes the mechanism; preserve source and license
   provenance when it does.
6. Make the narrowest owner-aligned change, then attack it with edge, parity,
   failure, and resource probes.
7. Prove exactness and build/test integrity before comparing performance.
8. Decide the terminal verdict and write the receipt. Commit only a complete
   proof-bearing slice; otherwise record the explicit blocker and next action.

## Promotion standard

Promotion requires a complete owner path, deterministic contract, relevant
tests, an independent proof surface, and performance evidence that passes the
existing parity, identity, and host-validity gates. A route-local gain with a
whole-engine loss is a salvage investigation. An incomplete command is neither
a promotion candidate nor a harmless switch arm.
