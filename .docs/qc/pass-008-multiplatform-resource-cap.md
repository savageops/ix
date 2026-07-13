---
id: pass-008-multiplatform-resource-cap
type: qc
category: review
status: complete
date: 2026-07-13
scope: "Multiplatform native, filesystem agnosticism, 5% device cap, benchmark promotion loop"
agents: 2
---

# QC Pass 008 — Multiplatform, Resource Cap, Benchmark Status

## 1. 5% Device Cap: ALREADY IMPLEMENTED

**Status: Done.** No code change needed.

`resource_profile.zig` already has:
- `FRAMEWORK_RESOURCE_PERCENT = 5` (line 4)
- `detectedPhysicalMemoryBytes()` (lines 50-54) — wraps `std.process.totalSystemMemory()`, which is Zig's cross-platform owner (Linux: /proc/meminfo, Windows: GlobalMemoryStatusEx, macOS: sysctl). Do NOT hand-roll these — the stdlib already handles all platforms.
- `memoryLimitBytes()` (lines 59-62) — returns 5% of detected RAM, falling back to 512 MiB on detection failure
- `CappedAllocator` (lines 67-142) — lock-free accounting allocator with atomic CAS on reserve, enforcing the ceiling at allocation time (not after RSS grows). Wired in main.zig:59.
- `threadLimit(available)` (lines 26-33) — 5% of CPU count with floor of 1
- `clampThreads` (lines 37-39) — bounds both defaults and explicit --threads beneath the ceiling

**Gap: No env override.** `FRAMEWORK_RESOURCE_PERCENT` is a source constant. There is no `IX_MEMORY_PERCENT` or `IX_THREAD_PERCENT` env var. If "allowing limits to be pushed" means a user-controlled percentage (still beneath a hard safety ceiling), that's a gap. If 5% is light enough, it's done.

**Gap: Profile enum is vestigial.** `effectiveThreadCount` in search.zig does `_ = profile` — the low/medium/high enum is ignored for sizing. The cap is always 5% device-relative. If the user wants low=2%, medium=5%, high=10%, that requires wiring the enum into the percent.

## 2. Filesystem Agnosticism: ALREADY DONE

**Status: Done.** No hardcoded path separators that break Linux.

- `nt_open.zig`: comptime guards (`builtin.os.tag != .windows` → fallback to std.Io.Dir.cwd().openFile). NT path optimization is purely additive on Windows.
- `iocp_batch.zig`: degrades to sequential off-Windows. Not wired into scan loop, cannot regress Linux.
- `scan_input_policy.zig`: clean policy enum, no platform coupling. mmap via `std.Io.File.MemoryMap` (cross-platform stdlib abstraction).
- `state_dir.zig`: three-way platform-aware (Windows: LOCALAPPDATA, macOS: HOME/Library, Linux: XDG_STATE_HOME or ~/.local/state). Single IX_STATE_DIR override.
- `main.launchDetachedProcess`: Windows vs POSIX branch with clean `std.process.spawn` fallback.
- Path comparison in search.zig treats both `\` and `/` as separators, lowercases only on Windows.

## 3. Multiplatform Build: ONE GAP

**Status: One gap.** `build.zig:60-65` hardcodes `-mavx2` unconditionally for the StringZilla C shim. This is x86-only. On AArch64 Linux (Graviton, Raspberry Pi, Apple Silicon), the C compile fails.

**Fix:** Gate on target CPU arch:
```zig
if (target.result.cpu.arch == .x86_64 or target.result.cpu.arch == .x86) {
    c_shim.addCFlag("-mavx2");
}
```
Or add a fallback `-DSZ_DYNAMIC_DISPATCH=1` path for non-x86 (contradicts AGENTS.md "no runtime dispatch" but necessary for ARM). This is a design decision: scope "multiplatform" to OSes on x86 only, or relax the no-runtime-dispatch invariant for non-x86.

**PCRE2:** 27 TUs compile on Linux. sljit JIT backend supports x86/x86_64/ARM/AArch64/MIPS/PPC/s390x. No change needed. Verify config.h is not Windows-shaped.

**No Linux-specific fast path exists yet.** io_uring (Tier 1 roadmap), MAP_HUGETLB, perf_event_open are future work. Linux today runs the generic std.Io path. Satisfies "multiplatform" but not "parity fast path."

## 4. Benchmark Infrastructure: ~80% READY

**Status: Existing infrastructure covers most needs.**

Already exists:
- ripgrep benchsuite corpus at `.refs/ripgrep/benchsuite/linux`
- Predecessor backup ladder (`ix.exe.backup-*` in install dir, deduplicated by PE-normalized hash)
- Paired interleaving (alternating previous/current order, median of engine-reported total_ms)
- Bootstrap 95% CI (xorshift32, 2000 resamples)
- Match parity, route parity, files discovered/scanned parity checks
- `sync-native-install.mjs` promotion script with hash verification
- `teddy-kernel-decision.mjs` promotion gate requiring netPositive on ALL rounds
- Evidence quality grading (benchmarkEvidenceFailures, benchmarkDecisionGrade)
- Host noise classification (Defender, scheduler pressure, power plan, etc.)
- Phase attribution (discover/scan/aggregate breakdown)

**Gap 1: 10% tolerance vs zero-regression gate.** The existing gate requires `netPositive === true` on ALL rounds — any regression fails. The user wants 10% tolerance for important features. BUT: `ix-architecture-regression-gate.mjs` already implements a tolerance pattern. The fix is plumbing, not design: route insight-lane (xo/inspect) regressions through a separate evidence lane that doesn't block search promotion.

**Gap 2: No bench-xo.mjs.** The existing runner hardcodes `["search", ...]` in buildIxSearchArgs. xo takes a different invocation (`xo <query> <paths> --max-bytes N --max-spans N --format json`). bench-xo.mjs needs:
- Own argument builder (not reusing buildIxSearchArgs)
- Own JSON summarizer (xo emits ix.xo.v1, not the search stats schema)
- Paired interleaving CAN be reused from measurePairedHistory
- measureIxOnce and summarizeIxRuns from speed-compare-utils.mjs can be adapted

**Gap 3: No monotonic build ledger.** The user wants "every test must be better than the last." There's no persistent ledger tracking the promotion history series. Historical reports exist but aren't structured as a monotonic-improvement series invariant.

**Key insight from agent 4:** "Only the search lane must maintain search speed" means xo/inspect regressions should NOT block promotion. The promotion gate should verify:
1. Search lane: no regression (existing strict gate)
2. Insight lanes (xo/inspect): quality measured independently, regressions noted but non-blocking

This separation already exists conceptually (xo doesn't touch search internals) but not in the promotion gate logic.

## Summary

| Requirement | Status | Action |
|-------------|--------|--------|
| 5% memory/thread cap | DONE | No change (consider IX_MEMORY_PERCENT env override if user wants runtime control) |
| Filesystem agnostic | DONE | No change |
| Multiplatform (x86 Linux/Windows) | DONE | No change |
| Multiplatform (ARM/AArch64) | GAP | Gate -mavx2 on x86 arch in build.zig |
| Benchmark vs predecessors | 80% READY | Create bench-xo.mjs with own harness |
| 10% regression tolerance | GAP | Route insight lanes through separate evidence lane |
| Every test better than last | GAP | Create monotonic build ledger |
| Search lane isolation | DONE | xo doesn't touch search path; just needs gate separation |
