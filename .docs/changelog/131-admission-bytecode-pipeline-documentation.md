# Version 131 - Admission Bytecode Pipeline Documentation

**Date:** 2026-05-11

## Changes

### Added
- README architecture lane for `PathAdmission -> FileAdmissionBytecode -> ByteKernel -> LineVerifier`
- README "Admission Bytecode Lane" section with measured Rust IX comparison context
- README opcode surface for the planned `FileAdmissionProgram`
- README PCRE2 metadata-lowering details for first-byte, last-byte, minimum-length, and JIT-size facts
- README C-kernel boundary for `ix_count_byte_avx2`, `ix_ascii_ci_memmem_avx2`, and `ix_trigram_admit_scalar_or_avx2`
- Changelog entry documenting the technical pipeline and its proof constraints

### Changed
- README headline now includes the admission-bytecode lane.
- README vendoring line now reflects the actual StringZilla/PCRE2 C-source build model.
- README "How It Works" flow now routes through proof-program/admission-program stages.
- README "Execution Model" distinguishes current trigram admission from planned executable admission bytecode.
- README "What Is Inside" now tracks admission bytecode and byte-kernel ownership.
- README "Exact Trigram Acceleration" now documents the selected one-pass rolling trigram replacement for repeated per-trigram SIMD probes.
- README Roadmap now prioritizes executable admission bytecode, one-pass trigram admission, PCRE2 metadata lowering, and narrow C byte kernels ahead of broader algorithmic work.

## Patch Surface

Modifies:
- `README.md`
- `.docs/todo/changelog/_log.md`

Adds:
- `.docs/changelog/131-admission-bytecode-pipeline-documentation.md`

Deletes:
- none

## Architecture

### Selected pipeline

```text
SearchRequest + ExpressionPlan
  └─ FileAdmissionProgram
      ├─ PathAdmission
      ├─ MetadataAdmission
      ├─ RegexMetadataAdmission
      ├─ TrigramAdmission
      └─ LineVerifier
```

### Opcode surface

```text
RejectByPathClass
RejectByExtSet
RejectBinaryPrefix
RequireAnyFirstByteSet
RequireLastCodeUnit
RequireMinLength
RequireTrigramGroups
```

### Byte-kernel boundary

```text
Zig-owned planner/verifier
  └─ stable opcode contract
      └─ optional C kernels
          ├─ ix_count_byte_avx2
          ├─ ix_ascii_ci_memmem_avx2
          └─ ix_trigram_admit_scalar_or_avx2
```

## Invariants

- Admission bytecode is a negative gate only.
- Exact verifier remains the only match authority.
- PCRE2 metadata is used only when PCRE2 proves the fact.
- Heuristic mandatory-literal rejection is not allowed.
- C is a byte-kernel layer, not a second control plane.
- No heap allocation is permitted during admission-program execution.

## Evidence

Fresh Rust IX comparison:

```text
command: node tools/scripts/run-once-benchmark.mjs --expression "re:\bPM_RESUME\b" --corpus "E:\Workspaces\01_Projects\01_Github\iEx\.refs\ripgrep\benchsuite\linux" --rust-ix-binary "E:\Workspaces\01_Projects\01_Github\iEx\target\release\ix.exe" --samples 3 --warmup 1 --quiet
artifact: tools/reports/latest.json
zig total: 681.5082 ms
rust total: 620.3549 ms
gap: 9.86%
discovery: 174.7226 ms
scan: 506.5152 ms
files discovered: 79088
```

Research artifact:

```text
.docs/research/2026-05-11-zig-search-edge-next-step.md
```

Insect harvest artifacts:

```text
.docs/research/insect/zig-simd-vector-search.json
.docs/research/insect/zig-c-interop-avx2.json
.docs/research/insect/ripgrep-prefilter-architecture.json
.docs/research/insect/pcre2-jit-startchar.json
.docs/research/insect/reddit-zig-simd-c.json
.docs/research/insect/youtube-zig-simd.json
.docs/research/insect/youtube-zig-in-depth-vectors-transcript.json
```

## Impact

This does not implement the admission bytecode yet. It makes the pipeline visible in the public technical surface so future implementation work can be evaluated against one canonical contract instead of scattered optimization notes.
