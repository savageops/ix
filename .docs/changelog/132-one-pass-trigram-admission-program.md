# 132 - One-Pass Trigram Admission Program

Date: 2026-05-11

## Summary

Implemented the first executable admission-bytecode slice in the hot search path: mandatory trigram evidence now compiles once per query into `TrigramAdmissionProgram` and executes as a single rolling pass over each candidate file buffer.

## Technical Contract

`src/core/search.zig` now lowers `trigram.Admission` into an immutable program before scanning:

```text
TrigramAdmissionProgram
  ├─ keys[4096]                 // open-addressed 24-bit trigram table
  ├─ group_masks[4096]          // evidence groups containing each trigram
  ├─ required_counts[MAX_GROUPS]
  ├─ group_complete_mask
  └─ mode: all | any
```

Execution details:

- The program is compiled once from the existing `ExpressionPlan -> trigram.Admission` evidence contract.
- Single-predicate literal / prefix / suffix / regex-word-boundary plans run a contract-safe whole-file mandatory-needle admission before trigram execution.
- The file scanner rolls a 24-bit trigram key: `(b[i-2] << 16) | (b[i-1] << 8) | b[i]`.
- Each matching table slot is counted once per file via `seen_slots`, preventing repeated byte occurrences from double-counting group evidence.
- `AND` admission succeeds only when every evidence group is satisfied.
- `OR` admission succeeds as soon as any indexed branch group is satisfied.
- The gate remains negative-only: it can prune impossible files or admit candidates to the exact verifier, but it never emits matches.
- No heap allocation occurs during per-file admission execution.

## Pipeline Position

```text
SearchRequest + ExpressionPlan
  └─ trigram.Admission
      └─ TrigramAdmissionProgram
          ├─ one-pass rolling byte kernel
          ├─ group satisfaction state
          └─ exact LineVerifier handoff
```

This is the retained first slice of the larger `PathAdmission -> FileAdmissionBytecode -> ByteKernel -> LineVerifier` architecture. The remaining bytecode work is path admission, file metadata admission, and PCRE2-proven metadata lowering.

## Verification

- `zig build test`
- Linux bench corpus profile, `re:\bPM_RESUME\b`, 9 measured samples / 2 warmups:
  - Zig: `652.9729ms`
  - Rust IX: `631.6790ms`
  - Gap: `3.37%`
  - Trigram candidate buffers on the same direct JSON profile after whole-file mandatory-needle admission: `1`
  - Prior same-turn baseline: Zig `681.5082ms`, Rust IX `620.3549ms`, gap `9.86%`
- Dupe audit on `src/core/search.zig`: `segment_count=42`, `candidate_pair_count=0`, `exact_duplicate_candidate_count=0`
