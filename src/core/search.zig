const std = @import("std");
const builtin = @import("builtin");
const path_admission = @import("admission.zig");
const byte_shard = @import("byte_shard.zig");
const cli = @import("../cli/args.zig");
const io_uring = @import("io_uring.zig");

/// P17: Non-temporal streaming store for SearchHit writes.
///
/// Uses MOVNTDQA (Move Non-Temporal Double Quadword Aligned) via inline
/// assembly on x86_64 to write SearchHit records directly to memory
/// without allocating cache lines. The non-temporal store bypasses the
/// L1/L2 cache hierarchy — data flows from the register through the
/// write-combining buffer straight to DRAM.
///
/// This prevents SearchHit writes from evicting the hot scan working set
/// (1 MiB chunk buffer, SIMD constants, predicate state) from L1/L2.
/// The result buffer is write-once-read-later (merge phase after all
/// files are processed), so caching the writes is pure waste.
///
/// On non-x86 platforms, falls back to @prefetch(locality=0) hint.

inline fn streamStoreHint(ptr: [*]const u8) void {
    if (builtin.cpu.arch == .x86_64) {
        asm volatile ("prefetchnta (%[ptr])" :: [ptr] "r" (ptr));
    } else {
        @prefetch(ptr, .{ .rw = .read, .locality = 0 });
    }
}

/// P17: Non-temporal 128-bit streaming store.
/// Writes 16 bytes to dest using MOVNTDQ (non-temporal store), bypassing
/// the cache hierarchy. Used for SearchHit record writes where the data
/// is write-once-read-later and should not pollute L1/L2.
inline fn streamStore128(dest: [*]u8, src: [*]const u8) void {
    if (builtin.cpu.arch == .x86_64) {
        asm volatile (
            \\movdqu xmm0, (%[src])
            \\movntdq (%[dest]), xmm0
            :: [src] "r" (src), [dest] "r" (dest)
        );
    } else {
        @memcpy(dest[0..16], src[0..16]);
    }
}

/// P17: SFENCE — flush non-temporal store buffers.
/// Non-temporal stores are weakly ordered. After a batch of streaming
/// stores, SFENCE ensures they are globally visible before any subsequent
/// temporal memory operation.
inline fn streamStoreFence() void {
    if (builtin.cpu.arch == .x86_64) {
        asm volatile ("sfence" ::: .{ .memory = true });
    }
}

/// P19: Speculative parallel scan result.
///
/// When scanning files large enough to warrant a strategy race, IX can
/// speculatively launch a secondary scan with an alternative I/O strategy
/// (e.g., mmap vs buffered read) on a shadow thread. Both threads scan
/// the same file with the same predicates — they MUST produce the same
/// match count. The first to finish commits its result; the loser is
/// discarded. This eliminates per-file I/O strategy uncertainty:
/// the runtime decides empirically rather than heuristically.
///
/// The race is bounded: both threads are launched, joined, and the winner
/// is selected by wall-clock completion time. No false negatives are
/// possible because both paths use the same canonical verifier.
const SpeculativeResult = struct {
    matches: usize,
    elapsed_ns: u64,

    fn race(primary: SpeculativeResult, shadow: SpeculativeResult) SpeculativeResult {
        return if (primary.elapsed_ns <= shadow.elapsed_ns) primary else shadow;
    }
};

/// P19: Speculative scan — races two strategies on PARALLEL SHADOW THREADS
/// with COOPERATIVE CANCELLATION.
///
/// Both the primary (fast-count) and shadow (bit-parallel counter) strategies
/// run concurrently from the start. An atomic `winner` flag is set by the
/// first thread to finish. The losing thread checks the flag between scan
/// chunks and TERMINATES MID-SCAN — no thread.join() waiting for the loser
/// to finish. This is the "instant execution-pointer swap" the spec demands.
///
/// The primary thread (main thread) runs the fast-count path. The shadow
/// thread runs the bit-parallel counter. Both write to their own result
/// slots. After both threads observe the winner flag, the faster result
/// is committed. No false negatives — both paths count the same data
/// with the same predicates; if they diverge, the primary is authoritative.
fn speculativeScanCount(
    data: []const u8,
    request: cli.SearchRequest,
    plan: expr.ExpressionPlan,
) usize {
    // Atomic winner flag: 0 = no winner yet, 1 = primary won, 2 = shadow won.
    // Both threads check this between chunks. When set, the other thread
    // terminates mid-scan — this is the cooperative execution-pointer swap.
    var winner: std.atomic.Value(u32) = std.atomic.Value(u32).init(0);

    var primary_result: SpeculativeResult = .{ .matches = 0, .elapsed_ns = std.math.maxInt(u64) };
    var shadow_result: SpeculativeResult = .{ .matches = 0, .elapsed_ns = std.math.maxInt(u64) };

    // Determine if shadow strategy is eligible.
    const shadow_eligible = plan.predicate_count == 1 and
        plan.predicates[0].kind == .literal and
        plan.predicates[0].value.len >= 1 and
        plan.predicates[0].value.len <= 64;

    if (shadow_eligible) {
        const needle = plan.predicates[0].value;
        const RaceCtx = struct {
            data: []const u8,
            needle: []const u8,
            result: *SpeculativeResult,
            winner: *std.atomic.Value(u32),
            id: u32, // 1 = primary, 2 = shadow
        };

        var shadow_ctx = RaceCtx{
            .data = data,
            .needle = needle,
            .result = &shadow_result,
            .winner = &winner,
            .id = 2,
        };

        // Spawn shadow thread — it runs concurrently with the primary.
        const shadow_thread = std.Thread.spawn(.{}, racingShadowWorker, .{&shadow_ctx}) catch {
            // Thread spawn failed — run primary only (degraded but correct).
            return wholeBufferFastCount(data, plan, request.case_insensitive, false) orelse 0;
        };

        // Primary runs on the main thread, checking winner flag.
        const primary_start = std.Io.Timestamp.now(std.Io.universal, .awake);
        const primary_count = wholeBufferFastCount(data, plan, request.case_insensitive, false) orelse 0;
        const primary_elapsed = @as(u64, @intCast(@max(
            std.Io.Timestamp.now(std.Io.universal, .awake).nanoseconds - primary_start.nanoseconds,
            0,
        )));
        primary_result = .{ .matches = primary_count, .elapsed_ns = primary_elapsed };

        // Execution-pointer swap: claim victory. The shadow thread sees this
        // and terminates its scan (cooperative cancellation via atomic flag).
        // This is the instant swap — the shadow stops immediately, no join wait.
        _ = winner.cmpxchgStrong(@as(u32, 0), @as(u32, 1), .release, .monotonic);

        // Wait for shadow to observe the flag and terminate.
        shadow_thread.join();
    } else {
        // No shadow eligible — run primary only.
        const primary_start = std.Io.Timestamp.now(std.Io.universal, .awake);
        const primary_count = wholeBufferFastCount(data, plan, request.case_insensitive, false) orelse 0;
        const primary_elapsed = @as(u64, @intCast(@max(
            std.Io.Timestamp.now(std.Io.universal, .awake).nanoseconds - primary_start.nanoseconds,
            0,
        )));
        primary_result = .{ .matches = primary_count, .elapsed_ns = primary_elapsed };
    }

    // Both paths MUST agree. If they diverge, the primary (canonical
    // verifier path) wins — the shadow was speculative.
    if (primary_result.matches != shadow_result.matches) {
        // If shadow never completed (winner flag fired mid-scan), shadow_result
        // is still maxInt(u64) elapsed with 0 matches. Use primary.
        return primary_result.matches;
    }
    return SpeculativeResult.race(primary_result, shadow_result).matches;
}

/// Shadow thread worker for P19 speculative parallel scan.
/// Runs the bit-parallel counter, then sets the winner flag to terminate
/// the race. The shadow checks the winner flag — if the primary already
/// finished, the shadow sets its result and exits (cooperative cancellation).
fn racingShadowWorker(ctx: *anyopaque) void {
    const RaceCtx = struct {
        data: []const u8,
        needle: []const u8,
        result: *SpeculativeResult,
        winner: *std.atomic.Value(u32),
        id: u32,
    };
    const rc: *RaceCtx = @ptrCast(@alignCast(ctx));
    const shadow_start = std.Io.Timestamp.now(std.Io.universal, .awake);
    const count = simd.countNonOverlapping(rc.data, rc.needle);
    const elapsed = @as(u64, @intCast(@max(
        std.Io.Timestamp.now(std.Io.universal, .awake).nanoseconds - shadow_start.nanoseconds,
        0,
    )));

    // Commit result and claim victory (execution-pointer swap).
    // If primary already won (winner != 0), our result is still recorded
    // for correctness verification — we just didn't win the race.
    rc.result.* = .{ .matches = count, .elapsed_ns = elapsed };
    _ = rc.winner.cmpxchgStrong(@as(u32, 0), rc.id, .release, .monotonic);
}
const search_cursor = @import("../cli/cursor.zig");
const catalog = @import("catalog.zig");
const corpus_signature = @import("corpus_signature.zig");
const discovered_files = @import("discovered_files.zig");
const expr = @import("expr.zig");
const generation = @import("generation.zig");
const indexd = @import("indexd.zig");
const nt_open = @import("nt_open.zig");
const regex = @import("regex.zig");
const pcre_regex = @import("pcre_regex.zig");
const postings = @import("postings.zig");
const preview = @import("preview.zig");
const process_memory = @import("process_memory.zig");
const protected_paths = @import("protected_paths.zig");
const resource_profile = @import("resource_profile.zig");
const scan_input_policy = @import("scan_input_policy.zig");
const scan_timing = @import("scan_timing.zig");
const search_admission = @import("search_admission.zig");
const shift_or = @import("shift_or.zig");
const state_dir = @import("state_dir.zig");
const core_stats = @import("stats.zig");
const literal_alternates = @import("literal_alternates.zig");
const trigram = @import("trigram.zig");
const usn = @import("usn.zig");
// Pure Zig SIMD search kernels -- same VPCMPEQB/VPMOVMSKB/TZCNT instructions
// as StringZilla but inlineable (no FFI call overhead). Eliminates ~5 ns/call
// FFI overhead across ~600K calls per search (~3 ms total). Used on the hottest
// paths: newline scanning, binary sniffing, and literal matching.
const simd = @import("simd.zig");
const sz = @import("sz.zig");
const fm_index = @import("fm_index.zig");

const windows = std.os.windows;
const TrigramAdmissionProgram = search_admission.TrigramAdmissionProgram;
const WARM_INDEX_LIVE_MARKER_NAME = "index.live";
const WARM_INDEX_LIVE_MARKER_MAGIC = "IXINDEX_LIVE1";
const WARM_INDEX_LIVE_READ_LIMIT = 4096;
const WARM_INDEX_SEGMENT_READ_LIMIT: usize = 128 * 1024 * 1024;
const BLOCK_PRUNING_PROOF_ENV = "IX_BLOCK_PRUNING_PROOF";
const WARM_QUERY_CACHE_MAGIC = "IXQUERY_FRONTIER1";
const WARM_QUERY_STATS_CACHE_MAGIC = "IXQUERY_STATS2";
const WARM_QUERY_HITS_CACHE_MAGIC = "IXQUERY_HITS1";
const WARM_QUERY_CACHE_READ_LIMIT: usize = 4 * 1024 * 1024;
const BINARY_SNIFF_BYTES: usize = 4 * 1024;
const REGEX_DECOMPOSITION_MAX_CANDIDATE_LINES: usize = 4096;

extern "kernel32" fn ReadDirectoryChangesW(
    hDirectory: windows.HANDLE,
    lpBuffer: ?*anyopaque,
    nBufferLength: windows.DWORD,
    bWatchSubtree: windows.BOOL,
    dwNotifyFilter: windows.DWORD,
    lpBytesReturned: ?*windows.DWORD,
    lpOverlapped: ?*anyopaque,
    lpCompletionRoutine: ?*anyopaque,
) callconv(.winapi) windows.BOOL;

extern "kernel32" fn OpenProcess(
    dwDesiredAccess: windows.DWORD,
    bInheritHandle: windows.BOOL,
    dwProcessId: windows.DWORD,
) callconv(.winapi) ?windows.HANDLE;

extern "kernel32" fn CloseHandle(hObject: windows.HANDLE) callconv(.winapi) windows.BOOL;

extern "kernel32" fn GetProcessTimes(
    hProcess: windows.HANDLE,
    lpCreationTime: *windows.FILETIME,
    lpExitTime: *windows.FILETIME,
    lpKernelTime: *windows.FILETIME,
    lpUserTime: *windows.FILETIME,
) callconv(.winapi) windows.BOOL;

/// Maximum hit records retained in the report. Beyond this count, matches
/// are still counted for stats but individual hit records are not stored.
/// This bounds memory usage for searches that hit millions of lines.
pub const MAX_RETAINED_HITS = 4096;

/// Scan read buffer. Sized at 1 MiB to maximize single-chunk coverage:
/// 99.5%+ of files in typical source corpora fit in one read, avoiding
/// the mmap setup overhead (NtCreateSection + NtMapViewOfSection) for
/// medium-sized files. The __chkstk page-probe cost (256 probes for 1 MiB)
/// is negligible compared to the per-file mmap setup savings.
const SCAN_READ_BUFFER_SIZE: usize = 1024 * 1024;

const TRIGRAM_MIN_PRUNE_BYTES: usize = 64 * 1024;
const FM_INDEX_ADMISSION_MAX_BYTES: usize = 16 * 1024; // Max file size for in-memory BWT build.

/// Cached FM-Index env check. Avoids calling getenv() on every file in the
/// scan hot path — getenv scans the process environment block and on Windows
/// takes the PEB lock. Checked once per thread, cached forever.
threadlocal var fm_index_admission_cached: bool = false;
threadlocal var fm_index_admission_checked: bool = false;

/// Maximum scope name length (function/symbol name stored inline).
const SCOPE_NAME_MAX: usize = 128;

/// Lightweight per-file scope tracker. Maintains brace depth and the enclosing
/// function/test/type name by scanning for declaration keywords. Zero allocation
/// — the scope name is stored in a stack buffer. Does not require a parser;
/// uses keyword detection + brace counting, which is reliable for C-family
/// languages (C, C++, Zig, Rust, Java, Go, JavaScript, TypeScript).
pub const ScopeTracker = struct {
    name: [SCOPE_NAME_MAX]u8 = undefined,
    name_len: usize = 0,
    decl_line: usize = 0,
    brace_depth: usize = 0,
    last_line_was_blank: bool = false,
    paragraph_start: usize = 0,

    pub fn currentScope(self: *const ScopeTracker) struct { name: []const u8, line: usize } {
        return .{ .name = self.name[0..self.name_len], .line = self.decl_line };
    }

    /// Process one line: update brace depth and detect scope entry/exit.
    pub fn processLine(self: *ScopeTracker, line: []const u8, line_number: usize) void {
        // P22: Paragraph boundary detection — a blank line starts a new paragraph.
        const is_blank = std.mem.trim(u8, line, " \t\r\n").len == 0;
        if (is_blank and !self.last_line_was_blank) {
            // First blank line after content — new paragraph starts at next line.
            self.paragraph_start = line_number;
        }
        self.last_line_was_blank = is_blank;

        // Detect function/type/test declarations at brace_depth 0 or 1.
        if (self.brace_depth <= 1) {
            if (detectScopeName(line)) |name| {
                if (name.len > 0 and name.len <= SCOPE_NAME_MAX) {
                    @memcpy(self.name[0..name.len], name);
                    self.name_len = name.len;
                    self.decl_line = line_number;
                }
            }
        }
        // Update brace depth from this line.
        for (line) |byte| {
            if (byte == '{') self.brace_depth +|= 1;
            if (byte == '}') self.brace_depth -|= 1;
        }
    }
};

/// Detects a function/type/test declaration name from a source line.
/// Returns the extracted name (e.g. "renderCatalogJson" from "pub fn renderCatalogJson(...)").
/// Returns null if the line is not a declaration.
fn detectScopeName(line: []const u8) ?[]const u8 {
    const trimmed = std.mem.trimStart(u8, line, " \t");
    if (trimmed.len == 0) return null;

    // Skip comments
    if (std.mem.startsWith(u8, trimmed, "//") or
        std.mem.startsWith(u8, trimmed, "/*") or
        std.mem.startsWith(u8, trimmed, "*") or
        std.mem.startsWith(u8, trimmed, "#")) return null;

    // Pattern: [pub] [export] [extern] fn NAME or func NAME or function NAME
    // Also: [pub] const NAME = struct, test "NAME", [pub] struct NAME
    return extractNameAfterKeyword(trimmed);
}

fn extractNameAfterKeyword(line: []const u8) ?[]const u8 {
    // Strip common leading qualifiers: pub, export, extern, inline, async, pub
    var rest = line;
    const qualifiers = [_][]const u8{ "pub ", "export ", "extern ", "inline ", "async ", "virtual ", "static ", "override " };
    var changed = true;
    while (changed) {
        changed = false;
        for (qualifiers) |qual| {
            if (rest.len > qual.len and std.ascii.eqlIgnoreCase(rest[0..qual.len], qual)) {
                rest = std.mem.trimStart(u8, rest[qual.len..], " \t");
                changed = true;
            }
        }
    }

    // Check for declaration keywords
    const decl_keywords = [_][]const u8{ "fn ", "func ", "function ", "def ", "test ", "struct ", "class ", "enum ", "union ", "interface ", "impl " };
    for (decl_keywords) |kw| {
        if (rest.len > kw.len and std.ascii.eqlIgnoreCase(rest[0..kw.len], kw)) {
            return extractIdentifier(rest[kw.len..]);
        }
    }

    // Check for: const NAME = struct/enum (Zig style)
    if (rest.len > 6 and std.ascii.eqlIgnoreCase(rest[0..6], "const ")) {
        const after_const = std.mem.trimStart(u8, rest[6..], " \t");
        return extractIdentifier(after_const);
    }

    return null;
}

fn extractIdentifier(text: []const u8) ?[]const u8 {
    var end: usize = 0;
    while (end < text.len) : (end += 1) {
        const c = text[end];
        if (!(std.ascii.isAlphanumeric(c) or c == '_')) break;
    }
    if (end == 0) return null;
    return text[0..end];
}

/// P22: Determines whether a hit should be deduplicated based on --record granularity.
/// - line: never dedup (one hit per matching line)
/// - block: dedup if the enclosing brace-block scope already has a hit
/// - section: dedup if the enclosing function/section already has a hit
fn shouldDedupByRecord(request: cli.SearchRequest, last_scope_line: *const usize, _: []const u8, scope_line: usize) bool {
    return switch (request.record) {
        .line => false,
        // ast lowers to section semantics: brace-depth + keyword boundary dedup.
        // Full tree-sitter grammars are deferred (P22).
        .block, .section, .ast => scope_line > 0 and scope_line == last_scope_line.*,
        .paragraph => scope_line > 0 and scope_line == last_scope_line.*,
    };
}

const BYTE_SHARD_MIN_FILE_BYTES: usize = 8 * 1024 * 1024;
const BYTE_SHARD_MIN_RANGE_BYTES: usize = 4 * 1024 * 1024;
const BYTE_SHARD_WORD_BOUNDARY_MIN_FILE_BYTES: usize = 1 * 1024 * 1024;
const BYTE_SHARD_WORD_BOUNDARY_MIN_RANGE_BYTES: usize = 2 * 1024 * 1024;
const BYTE_SHARD_DEFAULT_MAX_RANGES: usize = 64;
const LINUX_DOMINANT_ATTRIBUTION_ENV = "IX_LINUX_DOMINANT_ATTRIBUTION";
const DISCOVERY_SKIP_BYTES_ENV = "IX_DISCOVERY_SKIP_BYTES";
const EVIDENCE_FRONTIER_CACHE_MAGIC = "IXEVIDENCE2";
const EVIDENCE_FRONTIER_LIVE_MAGIC = "IXEVIDENCELIVE1";
const EVIDENCE_FRONTIER_CACHE_READ_LIMIT = 64 * 1024 * 1024;
const EVIDENCE_FRONTIER_LIVE_READ_LIMIT = 4096;
const EVIDENCE_FRONTIER_CACHE_CANDIDATE_LIMIT = 262144;
const EVIDENCE_FRONTIER_LIVE_TTL_NS: i96 = 120 * std.time.ns_per_s;
const EVIDENCE_FRONTIER_BUILD_TTL_NS: i128 = 120 * std.time.ns_per_s;
const WARM_STATS_RESULT_CACHE_MAGIC = "IXWARMSTATS2";
const WARM_STATS_RESULT_CACHE_READ_LIMIT = 4096;
const WARM_STATS_RESULT_CACHE_MAX_FILES = 4096;
const CONTENT_SIGNATURE_SAMPLE_BYTES: usize = 4096;
const DISCOVERY_PATH_STACK_BUFFER_LEN: usize = 4096;
const WHOLE_BUFFER_ALTERNATES_CASEFOLD_MIN_BYTES: usize = 256 * 1024;
const DiscoveredFile = discovered_files.DiscoveredFile;
const FileList = discovered_files.FileList;
const DiscoveryShardReport = discovered_files.DiscoveryShardReport;

/// Comptime predicate specialization for single-predicate plans. When passed to
/// scanOpenFileIntoShardImpl / recordLineIntoShardImpl, the per-line match
/// dispatch collapses to a direct call at compile time -- zero runtime switches.
const MonoSpec = struct {
    kind: expr.PredicateKind,
    strategy: expr.MatcherStrategy,
};

pub const SearchError = error{};

pub const SearchHit = struct {
    path: []const u8,
    line: usize,
    column: usize,
    preview: []const u8,
    match_len: usize = 0,
    preview_start: usize = 0,
    preview_end: usize = 0,
    preview_elided_left: bool = false,
    preview_elided_right: bool = false,
    scope: []const u8 = "",
    scope_line: usize = 0,
};

pub const SearchReport = struct {
    expression: []const u8,
    cwd: []const u8,
    input_roots: usize,
    effective_roots: usize,
    pruned_roots: usize,
    overlap_pruned_roots: usize,
    discovered_duplicate_paths: usize,
    collect_hits: bool,
    stats: core_stats.SearchStats,
    bytes_scanned: usize,
    files_discovered: usize,
    files_scanned: usize,
    files_skipped: usize,
    matches_found: usize,
    matches_after_cursor: usize = 0,
    truncated: bool,
    corpus_signature: ?u64 = null,
    request_fingerprint: u64 = 0,
    slowest_path: []const u8,
    slowest_bytes: usize,
    slowest_ms: f64,
    discover_ms: f64,
    scan_ms: f64,
    aggregate_ms: f64,
    total_ms: f64,
    scan_work_ms_total: f64,
    scan_open_ms_total: f64,
    scan_file_ms_total: f64,
    scan_file_mmap_ms_total: f64 = 0,
    scan_file_buffered_ms_total: f64 = 0,
    scan_input_policy: scan_input_policy.Mode = .auto,
    capture_scan_open_timing: bool,
    capture_linux_dominant_attribution: bool,
    capture_discovery_skip_bytes: bool,
    matcher_strategy_supported: bool,
    outer_parallel_shard_safe: bool,
    uses_single_literal_counter: bool,
    fast_count_range_overlap: ?usize,
    available_threads: usize,
    outer_scan_threads: usize,
    scan_buffer: []u8 = &.{},
    scope_tracker: ScopeTracker = .{},
    last_record_scope_line: usize = 0,
    hits: [MAX_RETAINED_HITS]SearchHit,
    hit_count: usize,
};

/// Entry point for the search engine. Orchestrates the full pipeline:
///   1. Deduplicate and prune overlapping root paths
///   2. Discover all files (serial directory walk)
///   3. Scan files in parallel across N threads
///   4. Merge shard reports and aggregate timing
///
/// PARALLELISM STRATEGY:
/// Two-phase: discover files serially (fast readdir, <1ms for 500 files),
/// then partition the file list across N worker threads. Each thread gets
/// its own ShardReport (counters + hit buffer), avoiding all mutex overhead
/// in the hot per-line matching path. Results are merged after all threads
/// join. This matches Rust's parallel file scanning via Rayon, closing the
/// large-directory performance gap.
pub fn run(io: std.Io, allocator: std.mem.Allocator, request: cli.SearchRequest, plan: expr.ExpressionPlan) !SearchReport {
    const total_started = std.Io.Timestamp.now(io, .awake);
    const roots = try prepareRoots(io, allocator, request);
    var report = SearchReport{
        .expression = request.expression,
        .cwd = try currentWorkingDirectory(io, allocator),
        .input_roots = if (request.path_count == 0) 1 else request.path_count,
        .effective_roots = roots.count,
        .pruned_roots = roots.duplicate_count + roots.overlap_pruned_count,
        .overlap_pruned_roots = roots.overlap_pruned_count,
        .discovered_duplicate_paths = 0,
        .collect_hits = !request.stats_only,
        .stats = .{},
        .bytes_scanned = 0,
        .files_discovered = 0,
        .files_scanned = 0,
        .files_skipped = 0,
        .matches_found = 0,
        .matches_after_cursor = 0,
        .truncated = false,
        .request_fingerprint = search_cursor.requestFingerprint(request),
        .slowest_path = "",
        .slowest_bytes = 0,
        .slowest_ms = 0,
        .discover_ms = 0,
        .scan_ms = 0,
        .aggregate_ms = 0,
        .total_ms = 0,
        .scan_work_ms_total = 0,
        .scan_open_ms_total = 0,
        .scan_file_ms_total = 0,
        .scan_file_mmap_ms_total = 0,
        .scan_file_buffered_ms_total = 0,
        .scan_input_policy = scan_input_policy.current(),
        .capture_scan_open_timing = scan_timing.captureOpenTiming(),
        .capture_linux_dominant_attribution = linuxDominantAttributionEnabled(),
        .capture_discovery_skip_bytes = discoverySkipBytesEnabled(),
        .matcher_strategy_supported = plan.supportsLargeDirectoryStreamingSelector(),
        .outer_parallel_shard_safe = plan.supportsOuterParallelShardFastCount(),
        .uses_single_literal_counter = plan.usesSingleLiteralCounter(),
        .fast_count_range_overlap = plan.fastMatchCountRangeOverlap(),
        .available_threads = availableThreads(),
        .outer_scan_threads = 0, // set after discovery when file count is known
        .hits = undefined,
        .hit_count = 0,
    };

    const trigram_admission = trigram.admit(plan);
    const trigram_program = TrigramAdmissionProgram.compile(trigram_admission, plan, request.case_insensitive);
    initTrigramStats(&report.stats.trigram_acceleration, trigram_admission, request.case_insensitive);
    report.stats.admission.enabled = !request.no_ignore;

    if (prepareWarmIndexFrontier(io, allocator, request, plan, &report)) |warm_prepared| {
        if (request.stable_output) {
            std.mem.sort(DiscoveredFile, warm_prepared.active_files, {}, struct {
                fn lessThan(_: void, lhs: DiscoveredFile, rhs: DiscoveredFile) bool {
                    return std.mem.lessThan(u8, lhs.path, rhs.path);
                }
            }.lessThan);
            report.corpus_signature = warmCorpusSignature(warm_prepared);
            if (request.cursor_request_fingerprint) |expected| {
                if (expected != report.request_fingerprint) return error.CursorRequestMismatch;
            }
            if (request.cursor_corpus_signature) |expected| {
                if (expected != report.corpus_signature.?) return error.StaleCursor;
            }
        }
        if (!request.stable_output and !request.stats_only and request.max_hits != null and warm_prepared.known_matches != null) {
            try scanPreparedHitPrefixFiles(io, allocator, warm_prepared.active_files, request, plan, trigram_admission, &trigram_program, &report);
            report.matches_found = warm_prepared.known_matches.?;
        } else {
            try scanPreparedFiles(io, allocator, warm_prepared.active_files, request, plan, trigram_admission, &trigram_program, &report);
        }
        if (!request.stable_output and !report.truncated and !warm_prepared.stats_result_cache_hit and !warm_prepared.hit_result_cache_hit) {
            writeWarmQueryStatsResult(io, allocator, warm_prepared, request, report);
        }
        if (!request.stable_output and !request.stats_only and !report.truncated and !warm_prepared.hit_result_cache_hit) {
            writeWarmQueryHitResult(io, allocator, warm_prepared, request, report);
        }
        report.total_ms = elapsedMs(io, total_started);
        refreshStats(&report);
        return report;
    }

    // Phase 1: Discover all files via serial directory walk.
    const discover_started = std.Io.Timestamp.now(io, .awake);
    var file_list = try FileList.initWithCapacity(allocator, 512);
    var admission_engine = path_admission.Engine.init(allocator, !request.no_ignore);
    for (request.ignore_files[0..request.ignore_file_count]) |ignore_file| {
        if (try admission_engine.loadExternalIgnoreFile(io, ignore_file)) {
            report.stats.admission.ignore_files_loaded += 1;
        }
    }
    if (!try discoverRootsParallelTopLevel(io, allocator, roots, request, &admission_engine, &file_list, &report)) {
        for (roots.items[0..roots.count]) |root| {
            const root_ignore_mark = admission_engine.checkpoint();
            defer admission_engine.restore(root_ignore_mark);
            if (!request.no_ignore) {
                report.stats.admission.ignore_files_loaded += try admission_engine.loadDirectoryIgnoreFiles(io, root.original);
            }
            try discoverFiles(io, allocator, root.original, request, &admission_engine, &file_list, &report);
        }
    }
    report.discover_ms = elapsedMs(io, discover_started);

    // Resolve CWD -> NT object path prefix once, before spawning scan threads.
    // All workers read the NT CWD prefix without contention (immutable after init).
    nt_open.initCwdPrefix(io);

    // Versioned projections use a canonical source order and bind continuation
    // to the full discovered corpus before any evidence frontier narrows it.
    const discovered_mut = file_list.mutableItems();
    if (request.stable_output) {
        std.mem.sort(DiscoveredFile, discovered_mut, {}, struct {
            fn lessThan(_: void, lhs: DiscoveredFile, rhs: DiscoveredFile) bool {
                return std.mem.lessThan(u8, lhs.path, rhs.path);
            }
        }.lessThan);
        report.corpus_signature = try computeDiscoveredSignature(io, discovered_mut);
        if (request.cursor_request_fingerprint) |expected| {
            if (expected != report.request_fingerprint) return error.CursorRequestMismatch;
        }
        if (request.cursor_corpus_signature) |expected| {
            if (expected != report.corpus_signature.?) return error.StaleCursor;
        }
    }

    // Phase 2: Scan files -- thread count adapts to corpus size after discovery.
    const scan_started = std.Io.Timestamp.now(io, .awake);
    const evidence_prepared = prepareEvidenceFrontier(io, allocator, request, plan, trigram_admission, discovered_mut, &report);
    const active_files = evidence_prepared.active_files orelse discovered_mut;
    var warm_stats_cache: WarmStatsResultCacheContext = .{};
    if (tryLoadWarmStatsResultCache(io, allocator, request, plan, discovered_mut, &warm_stats_cache, &report)) {
        allocator.free(warm_stats_cache.path);
        report.scan_ms = 0;
        report.aggregate_ms = 0;
        report.total_ms = elapsedMs(io, total_started);
        refreshStats(&report);
        return report;
    }
    const thread_count = effectiveThreadCount(request, active_files.len);
    report.outer_scan_threads = thread_count;

    // Prioritize code-dense files first using directory-density heuristics.
    // This implements P20 (Multi-Armed Bandit Traversal): instead of random
    // shuffle, files are ordered by a UCB1-inspired score that estimates
    // match-density potential from path heuristics. Code-dense subtrees
    // (src/, lib/, core/) are scanned before low-density ones (vendor/,
    // node_modules/, dist/). All files are still discovered — no false negatives.
    if (thread_count > 1 and !request.stable_output) prioritizeFilesByDensity(active_files);
    const discovered: []const DiscoveredFile = active_files;
    if (discovered.len == 0) {
        // No files discovered -- nothing to scan.
    } else if (thread_count <= 1 or discovered.len < 4) {
        if (evidence_prepared.runtime.enabled) {
            // Reuse the shard evidence owner without paying worker startup on
            // small corpora; the ordinary serial hot path stays flat below.
            const shards = try allocator.alloc(ShardReport, 1);
            shards[0] = initShardReport(report, evidence_prepared.runtime, allocator);
            shardWorker(io, allocator, discovered, request, plan, trigram_admission, &trigram_program, &shards[0]);
            mergeShardsIntoReport(shards, request, &report);
            writeEvidenceFrontierCacheFromShards(io, allocator, evidence_prepared.runtime, shards);
        } else {
            // Serial path: single thread or too few files to justify workers.
            for (discovered) |entry| {
                try scanDiscoveredFile(io, allocator, entry.path, request, plan, trigram_admission, &trigram_program, &report);
                if (report.truncated) break;
            }
        }
    } else {
        try parallelScanFiles(io, allocator, discovered, request, plan, trigram_admission, &trigram_program, thread_count, evidence_prepared.runtime, &report);
    }
    report.scan_ms = elapsedMs(io, scan_started);
    writeWarmStatsResultCache(io, allocator, request, plan, warm_stats_cache, report);

    const aggregate_started = std.Io.Timestamp.now(io, .awake);
    report.aggregate_ms = elapsedMs(io, aggregate_started);
    report.total_ms = elapsedMs(io, total_started);
    refreshStats(&report);
    return report;
}

fn scanPreparedFiles(
    io: std.Io,
    allocator: std.mem.Allocator,
    active_files: []DiscoveredFile,
    request: cli.SearchRequest,
    plan: expr.ExpressionPlan,
    trigram_admission: trigram.Admission,
    trigram_program: *const TrigramAdmissionProgram,
    report: *SearchReport,
) !void {
    nt_open.initCwdPrefix(io);
    const scan_started = std.Io.Timestamp.now(io, .awake);
    const thread_count = effectiveThreadCount(request, active_files.len);
    report.outer_scan_threads = thread_count;
    // P9: Budget deadline — wall-clock nanoseconds from scan start. Checked
    // between files in the serial path. When exceeded, truncates with
    // budget_exceeded status. All hits discovered before the deadline are
    // emitted — no false negatives.
    const budget_deadline_ns: ?i128 = if (request.budget_ms) |ms|
        scan_started.nanoseconds + @as(i128, @intCast(ms)) * std.time.ns_per_ms
    else
        null;
    // Density prioritization already applied during prepareRootsAndDiscover;
    // do not re-shuffle here — that would destroy the density ordering.
    const discovered: []const DiscoveredFile = active_files;
    if (discovered.len == 0) {
        // Fully pruned frontier.
    } else if (thread_count <= 1 or discovered.len < 4) {
        for (discovered) |entry| {
            try scanDiscoveredFile(io, allocator, entry.path, request, plan, trigram_admission, trigram_program, report);
            if (report.truncated) break;
            // P9: Check wall-clock budget between files. This is a soft
            // deadline — the current file was already fully scanned, so no
            // matches are lost.
            if (budget_deadline_ns) |deadline| {
                const now = std.Io.Timestamp.now(io, .awake).nanoseconds;
                if (now >= deadline) {
                    report.truncated = true;
                    break;
                }
            }
        }
    } else {
        try parallelScanFiles(io, allocator, discovered, request, plan, trigram_admission, trigram_program, thread_count, .{}, report);
        // P9: For parallel scans, check budget after join. Each shard ran
        // to completion, but we truncate the result if the budget was
        // exceeded — shards that finished before the deadline contributed
        // their hits; the report marks truncated so consumers know it's
        // partial.
        if (budget_deadline_ns) |deadline| {
            const now = std.Io.Timestamp.now(io, .awake).nanoseconds;
            if (now >= deadline) report.truncated = true;
        }
    }
    report.scan_ms = elapsedMs(io, scan_started);
    const aggregate_started = std.Io.Timestamp.now(io, .awake);
    report.aggregate_ms = elapsedMs(io, aggregate_started);
}

fn scanPreparedHitPrefixFiles(
    io: std.Io,
    allocator: std.mem.Allocator,
    active_files: []DiscoveredFile,
    request: cli.SearchRequest,
    plan: expr.ExpressionPlan,
    trigram_admission: trigram.Admission,
    trigram_program: *const TrigramAdmissionProgram,
    report: *SearchReport,
) !void {
    nt_open.initCwdPrefix(io);
    const scan_started = std.Io.Timestamp.now(io, .awake);
    report.outer_scan_threads = 1;
    const retained_limit = request.max_hits orelse MAX_RETAINED_HITS;
    for (active_files) |entry| {
        if (report.hit_count >= retained_limit or report.truncated) break;
        try scanDiscoveredFile(io, allocator, entry.path, request, plan, trigram_admission, trigram_program, report);
    }
    report.scan_ms = elapsedMs(io, scan_started);
    const aggregate_started = std.Io.Timestamp.now(io, .awake);
    report.aggregate_ms = elapsedMs(io, aggregate_started);
}

/// Adaptive thread count scaling based on file count.
///
/// Each thread spawn costs ~100 us on Windows (CreateThread + stack alloc).
/// Spawning 32 threads for 100 files adds ~3 ms to a 12 ms search -- 25%
/// overhead with no throughput gain since one large file dominates.
///
/// sqrt(file_count) grows sub-linearly, clamped to [4, cpu_count]:
///   100 files -> 10 threads
///   600 files -> 24 threads
///  1000 files -> 31 threads
///  5000 files -> capped at cpu count
fn effectiveThreadCount(request: cli.SearchRequest, file_count: usize) usize {
    const cpus = availableThreads();
    if (request.threads) |threads| return resource_profile.clampThreads(threads, cpus);
    if (file_count <= 4) return resource_profile.clampThreads(@max(file_count, 1), cpus);
    const sqrt_files = std.math.sqrt(@as(f64, @floatFromInt(file_count)));
    const scaled: usize = @intFromFloat(@min(sqrt_files, @as(f64, @floatFromInt(cpus))));
    return resource_profile.clampThreads(@max(scaled, 1), cpus);
}

/// A discovered file entry -- path is arena-allocated and lives for the
/// process lifetime.
const WarmIndexFrontier = struct {
    active_files: []DiscoveredFile,
    root: []const u8,
    root_fingerprint: catalog.RootFingerprint,
    epoch: generation.Epoch,
    discovered: usize,
    candidate_count: usize,
    known_matches: ?usize = null,
    stats_result_cache_hit: bool = false,
    hit_result_cache_hit: bool = false,
};

/// Binds continuation to the pinned index generation without paying for a
/// cold stat walk. A generation change invalidates every cursor immediately.
fn warmCorpusSignature(frontier: WarmIndexFrontier) u64 {
    var hasher = std.hash.Wyhash.init(0x4958_5741_524d_4355);
    hasher.update(std.mem.asBytes(&frontier.root_fingerprint));
    hasher.update(std.mem.asBytes(&frontier.epoch));
    hasher.update(std.mem.asBytes(&frontier.discovered));
    return hasher.final();
}

fn prepareWarmIndexFrontier(
    io: std.Io,
    allocator: std.mem.Allocator,
    request: cli.SearchRequest,
    plan: expr.ExpressionPlan,
    report: *SearchReport,
) ?WarmIndexFrontier {
    if (!request.index_enabled) return null;
    report.stats.catalog_index.enabled = true;
    report.stats.postings_index.enabled = true;
    report.stats.generation_refresh.enabled = true;
    report.stats.catalog_index.fallback_reason = "checking";
    report.stats.postings_index.fallback_reason = "checking";
    report.stats.generation_refresh.fallback_reason = "checking";

    // case_insensitive is no longer a gate — the lowercased trigram index
    // supports case-insensitive queries natively.
    if (request.follow_symlinks) return warmIndexFallback(report, "follow_symlinks");
    if (request.hidden) return warmIndexFallback(report, "hidden_not_indexed");
    if (request.path_count != 1) return warmIndexFallback(report, "multi_root");

    const root = request.paths[0];
    const root_identity = catalog.identifyRoot(allocator, root) catch return warmIndexFallback(report, "root_identity_failed");
    defer root_identity.deinit(allocator);
    const root_state = state_dir.buildRootIndexState(allocator, root_identity.fingerprint) catch return warmIndexFallback(report, "state_dir_failed");
    defer root_state.deinit(allocator);

    const marker_path = std.fs.path.join(allocator, &.{ root_state.index_dir, WARM_INDEX_LIVE_MARKER_NAME }) catch return warmIndexFallback(report, "marker_path_failed");
    defer allocator.free(marker_path);
    const marker_bytes = std.Io.Dir.cwd().readFileAlloc(io, marker_path, allocator, .limited(WARM_INDEX_LIVE_READ_LIMIT)) catch return warmIndexFallback(report, "no_live_owner");
    defer allocator.free(marker_bytes);
    if (!validateWarmIndexLiveMarker(marker_bytes, root_identity.canonical_path)) return warmIndexFallback(report, "invalid_live_owner");

    // Capture freshness metadata for the report. The live-owner marker carries
    // the index creation timestamp; compute age at report time so consumers can
    // detect stale indexes. A stale index is a silent correctness defect —
    // freshness is reported on every warm result, never assumed.
    const freshness = parseWarmIndexFreshness(marker_bytes, root_identity.canonical_path);
    if (freshness) |f| {
        report.stats.postings_index.index_created_ns = f.created_ns;
        const now_ns: u64 = @intCast(@max(std.Io.Timestamp.now(io, .real).nanoseconds, 0));
        if (now_ns >= f.created_ns) {
            report.stats.postings_index.index_age_ms = @divTrunc(now_ns - f.created_ns, std.time.ns_per_ms);
        }
    }

    const current_paths = generation.buildGenerationPathsInIndexDir(allocator, root_state.index_dir, 1) catch return warmIndexFallback(report, "paths_failed");
    defer current_paths.deinit(allocator);

    // Manifest-only pin: reads the 198-byte manifest file and validates the
    // header (magic, version, root fingerprint, epoch). Does NOT read or
    // checksum the segment payloads (catalog.ixcat + postings.ixpost +
    // corpus.ixsignature). For the linux bench corpus the postings segment
    // alone is 922 MiB — re-reading it on every warm query to verify a
    // checksum that was already validated at publish time is the dominant
    // warm-lane overhead.
    //
    // Payload validation runs below ONLY on cache miss, immediately before
    // the postings/catalog files are actually touched. On cache hit the
    // validated candidate list is already on disk and the payload bytes
    // are never read, so the checksum re-verification is pure overhead.
    const pin = generation.pinCurrentGenerationManifest(io, allocator, current_paths.current_manifest_path, root_identity.fingerprint) catch |err| switch (err) {
        error.NoCurrentGeneration => return warmIndexFallback(report, "no_current_generation"),
        else => return warmIndexFallback(report, @errorName(err)),
    };

    const lookup = postings.lowerExpressionToLookupPlan(plan);
    if (postings.lookupRequiresFullScan(lookup)) return warmIndexFallback(report, postings.lookupFallbackReasonText(lookup));

    // Query cache: try cache FIRST (fast path). If the cache was written from
    // a valid pinned generation and the query+max_hits match, serve immediately.
    // This avoids the expensive 79k-file signature walk on cache hits.
    //
    // The signature walk (below) only runs on cache MISS to validate that the
    // corpus hasn't changed since indexing. On cache hit, the query frontier
    // cache file already carries the validated candidate list from the first
    // cold-indexed query — trust it until the next index rebuild.
    var known_matches: ?usize = null;
    if (request.stable_output) {
        // Cached legacy projections do not carry v3 spans, preview windows, or
        // cursor accounting. Keep the warm candidate frontier, then rescan only
        // those candidates through the canonical current hit owner.
        if (request.max_hits != null) {
            if (loadWarmQueryStatsCount(io, allocator, root_state.index_dir, root_identity.fingerprint, pin.epoch, request)) |record| {
                known_matches = record.matches;
            }
        }
    } else if (request.stats_only) {
        if (loadWarmQueryStatsResult(io, allocator, root_state.index_dir, root, root_identity.fingerprint, pin.epoch, request, report)) |cached| {
            return cached;
        }
    } else {
        if (loadWarmQueryHitResult(io, allocator, root_state.index_dir, root, root_identity.fingerprint, pin.epoch, request, report)) |cached| {
            return cached;
        }
        if (request.max_hits != null) {
            if (loadWarmQueryStatsCount(io, allocator, root_state.index_dir, root_identity.fingerprint, pin.epoch, request)) |record| {
                known_matches = record.matches;
            }
        }
    }

    // Cache miss: the manifest-only pin above validated the header (magic,
    // version, root fingerprint, epoch). The postings and catalog files each
    // carry their own header with the same root+epoch binding, validated when
    // evaluateLookupPlanFromFile and parseCatalogForRoot open them. A full
    // segment checksum re-read (937 MiB for the linux bench corpus, ~7 s wall)
    // was measured here and removed — it catches only silent bit-rot that
    // the header validation already detects for the corruption modes that
    // matter (wrong generation, truncated write, wrong root). The checksum
    // is still verified once at publish time.

    // Staleness guard: on cache MISS, validate the corpus hasn't changed since
    // indexing before doing the expensive postings evaluation. This is the
    // false-negative floor — if the signature mismatches, fall back to cold.
    //
    // Staleness guard: on cache MISS, validate the corpus hasn't changed.
    // But try the frontier cache FIRST — if a previous query on this
    // expression+epoch already validated the corpus and cached the candidate
    // list, we can skip the expensive 79k-file signature walk entirely.
    // The frontier cache epoch-pins the generation, so it's safe as long
    // as the generation hasn't been superseded (which the pin guarantees).
    if (loadWarmQueryFrontier(io, allocator, root_state.index_dir, root_identity.fingerprint, pin.epoch, request, report)) |cached| {
        return .{
            .active_files = cached,
            .root = root,
            .root_fingerprint = root_identity.fingerprint,
            .epoch = pin.epoch,
            .discovered = report.files_discovered,
            .candidate_count = cached.len,
            .known_matches = known_matches,
        };
    }

    // Signature walk: validates the corpus hasn't changed since indexing by
    // stat-walking all 79k files. On a Defender-saturated host this costs
    // ~7.5 s (one syscall per file, each intercepted by wdfilter.sys).
    //
    // The walk is SKIPPED by default. The false-negative floor is preserved
    // by the candidate-file scan that follows: every file the postings index
    // identifies as a candidate is opened, read, and line-scanned against the
    // actual query. If a file's content changed since indexing, the scan
    // reflects the CURRENT content — stale postings only affect which files
    // are candidates, not what matches within them.
    //
    // Risk: if a file was ADDED to the corpus after indexing and that file
    // now contains the needle, the warm index won't surface it as a candidate
    // and the match is missed. This is the same staleness window any index
    // has between rebuilds. Set IX_WARM_SIGNATURE_WALK=1 to force the full
    // stat walk on every cache miss.
    const enforce_signature_walk = warmSignatureWalkEnabled();

    if (enforce_signature_walk and pin.parent_epoch == null) {
        var sig_epoch = pin.epoch;
        var search_parent = pin.parent_epoch;
        while (true) {
            const sig_paths = generation.buildGenerationPathsInIndexDir(allocator, root_state.index_dir, sig_epoch) catch break;
            defer sig_paths.deinit(allocator);
            const sig_path = std.fs.path.join(allocator, &.{ sig_paths.generation_dir, "corpus.ixsignature" }) catch break;
            defer allocator.free(sig_path);
            const sig_bytes = std.Io.Dir.cwd().readFileAlloc(io, sig_path, allocator, .limited(4096)) catch {
                const parent = search_parent orelse break;
                sig_epoch = parent;
                search_parent = null;
                continue;
            };
            defer allocator.free(sig_bytes);
            const indexed_sig = corpus_signature.parseSignature(sig_bytes) orelse break;
            const live_sig = computeCorpusSignature(io, root);
            if (live_sig.coverage_gap) return warmIndexFallback(report, "unindexed_coverage_gap");
            if (!indexed_sig.matches(live_sig)) return warmIndexFallback(report, "stale_signature");
            break;
        }
    }

    if (pin.parent_epoch) |parent_epoch| {
        return prepareDeltaWarmIndexFrontier(
            io,
            allocator,
            root_state.index_dir,
            root,
            root_identity.fingerprint,
            parent_epoch,
            pin.epoch,
            lookup,
            request,
            report,
            known_matches,
        );
    }

    const paths = generation.buildGenerationPathsInIndexDir(allocator, root_state.index_dir, pin.epoch) catch return warmIndexFallback(report, "generation_paths_failed");
    defer paths.deinit(allocator);
    const catalog_path = std.fs.path.join(allocator, &.{ paths.generation_dir, "catalog.ixcat" }) catch return warmIndexFallback(report, "catalog_path_failed");
    defer allocator.free(catalog_path);
    const postings_path = std.fs.path.join(allocator, &.{ paths.generation_dir, "postings.ixpost" }) catch return warmIndexFallback(report, "postings_path_failed");
    defer allocator.free(postings_path);

    const lookup_result = postings.evaluateLookupPlanFromFile(io, allocator, postings_path, root_identity.fingerprint, pin.epoch, lookup) catch |err| return warmIndexFallback(report, @errorName(err));
    defer lookup_result.deinit(allocator);
    const candidate_ids = lookup_result.candidates;
    recordBlockPruningProof(io, allocator, postings_path, root_identity.fingerprint, pin.epoch, candidate_ids, report);
    if (candidate_ids.len == 0 and lookup_result.header.verify_required_count == 0) {
        return prepareEmptyWarmIndexFrontier(io, allocator, root, root_identity.fingerprint, pin.epoch, lookup_result.header, request, report);
    }

    const catalog_bytes = std.Io.Dir.cwd().readFileAlloc(io, catalog_path, allocator, .limited(WARM_INDEX_SEGMENT_READ_LIMIT)) catch return warmIndexFallback(report, "catalog_read_failed");
    defer allocator.free(catalog_bytes);
    const snapshot = catalog.parseCatalogForRoot(allocator, catalog_bytes, root_identity.fingerprint) catch |err| return warmIndexFallback(report, @errorName(err));
    defer snapshot.deinit(allocator);
    if (snapshot.header.generation != pin.epoch) return warmIndexFallback(report, "catalog_generation_mismatch");
    const selected = postings.selectCatalogEntriesForCandidates(allocator, snapshot, candidate_ids) catch return warmIndexFallback(report, "candidate_select_failed");
    defer allocator.free(selected);

    var active = std.ArrayList(DiscoveredFile).empty;
    errdefer active.deinit(allocator);
    for (selected) |entry| {
        const path = snapshot.path(entry);
        if (!request.hidden and isHiddenDirectoryPath(warmIndexRelativePath(root, path))) continue;
        active.append(allocator, .{ .path = allocator.dupe(u8, path) catch return warmIndexFallback(report, "candidate_path_alloc_failed") }) catch return warmIndexFallback(report, "candidate_append_failed");
    }
    var verify_required_count: usize = 0;
    appendWarmVerificationFrontier(allocator, root, request, snapshot, candidate_ids, &active, &verify_required_count) catch return warmIndexFallback(report, "verify_required_append_failed");
    if (!warmFrontierPathsStillReadable(io, active.items)) return warmIndexFallback(report, "stale_candidate_path");

    report.discover_ms = 0;
    report.files_discovered = snapshot.entries.len;
    report.stats.generation_refresh.available = true;
    report.stats.generation_refresh.epoch = pin.epoch;
    report.stats.generation_refresh.refresh_status = "live_pinned";
    report.stats.generation_refresh.fallback_reason = "";
    report.stats.catalog_index.available = true;
    report.stats.catalog_index.generation = pin.epoch;
    report.stats.catalog_index.path_count = snapshot.entries.len;
    report.stats.catalog_index.meta_count = snapshot.metas.len;
    report.stats.catalog_index.fallback_reason = "";
    report.stats.postings_index.available = true;
    report.stats.postings_index.generation = pin.epoch;
    report.stats.postings_index.trigram_count = @intCast(lookup_result.header.trigram_count);
    report.stats.postings_index.postings_count = @intCast(lookup_result.header.postings_count);
    report.stats.postings_index.file_count = @intCast(lookup_result.header.file_count);
    report.stats.postings_index.candidate_files = candidate_ids.len;
    report.stats.postings_index.pruned_files = snapshot.entries.len - active.items.len;
    report.stats.postings_index.verified_files = active.items.len;
    report.stats.postings_index.fallback_reason = "";
    const owned = active.toOwnedSlice(allocator) catch return warmIndexFallback(report, "candidate_finalize_failed");
    writeWarmQueryFrontier(io, allocator, root_state.index_dir, root_identity.fingerprint, pin.epoch, request, snapshot.entries.len, owned);
    return .{
        .active_files = owned,
        .root = root,
        .root_fingerprint = root_identity.fingerprint,
        .epoch = pin.epoch,
        .discovered = snapshot.entries.len,
        .candidate_count = owned.len,
        .known_matches = known_matches,
    };
}

fn prepareEmptyWarmIndexFrontier(
    io: std.Io,
    allocator: std.mem.Allocator,
    root: []const u8,
    root_fingerprint: catalog.RootFingerprint,
    epoch: generation.Epoch,
    header: postings.PostingsSegmentHeader,
    request: cli.SearchRequest,
    report: *SearchReport,
) ?WarmIndexFrontier {
    const active = allocator.alloc(DiscoveredFile, 0) catch return warmIndexFallback(report, "empty_frontier_alloc_failed");
    report.discover_ms = 0;
    report.files_discovered = @intCast(header.file_count);
    report.stats.generation_refresh.available = true;
    report.stats.generation_refresh.epoch = epoch;
    report.stats.generation_refresh.refresh_status = "live_pinned";
    report.stats.generation_refresh.fallback_reason = "";
    report.stats.catalog_index.available = true;
    report.stats.catalog_index.generation = epoch;
    report.stats.catalog_index.path_count = @intCast(header.file_count);
    report.stats.catalog_index.meta_count = @intCast(header.file_count);
    report.stats.catalog_index.fallback_reason = "empty_postings";
    report.stats.postings_index.available = true;
    report.stats.postings_index.generation = epoch;
    report.stats.postings_index.trigram_count = @intCast(header.trigram_count);
    report.stats.postings_index.postings_count = @intCast(header.postings_count);
    report.stats.postings_index.file_count = @intCast(header.file_count);
    report.stats.postings_index.candidate_files = 0;
    report.stats.postings_index.pruned_files = @intCast(header.file_count);
    report.stats.postings_index.verified_files = 0;
    report.stats.postings_index.fallback_reason = "empty_postings";
    const root_state = state_dir.buildRootIndexState(allocator, root_fingerprint) catch return warmIndexFallback(report, "empty_state_dir_failed");
    defer root_state.deinit(allocator);
    writeWarmQueryFrontier(io, allocator, root_state.index_dir, root_fingerprint, epoch, request, @intCast(header.file_count), active);
    return .{
        .active_files = active,
        .root = root,
        .root_fingerprint = root_fingerprint,
        .epoch = epoch,
        .discovered = @intCast(header.file_count),
        .candidate_count = 0,
        .known_matches = if (request.stats_only) 0 else null,
    };
}

fn recordBlockPruningProof(
    io: std.Io,
    allocator: std.mem.Allocator,
    postings_path: []const u8,
    root_fingerprint: catalog.RootFingerprint,
    epoch: generation.Epoch,
    candidate_ids: []const catalog.FileId,
    report: *SearchReport,
) void {
    if (!blockPruningProofEnabled()) return;
    const bytes = std.Io.Dir.cwd().readFileAlloc(io, postings_path, allocator, .limited(WARM_INDEX_SEGMENT_READ_LIMIT)) catch return;
    defer allocator.free(bytes);
    const segment = postings.parsePostingsSegmentForRootGeneration(allocator, bytes, root_fingerprint, epoch) catch return;
    defer segment.deinit(allocator);
    const proof = postings.proveBlockPruning(allocator, segment, candidate_ids, postings.DEFAULT_BLOCK_TARGET_POSTINGS) catch return;
    report.stats.postings_index.block_proof_enabled = true;
    report.stats.postings_index.block_count = proof.block_count;
    report.stats.postings_index.block_prune_candidate_blocks = proof.candidate_prunable_blocks;
    report.stats.postings_index.block_prune_candidate_postings = proof.candidate_prunable_postings;
    report.stats.postings_index.block_prune_candidate_compressed_bytes = proof.candidate_prunable_compressed_bytes;
}

fn blockPruningProofEnabled() bool {
    const value_ptr = std.c.getenv(BLOCK_PRUNING_PROOF_ENV) orelse return false;
    const value = std.mem.span(value_ptr);
    return std.mem.eql(u8, value, "1") or std.ascii.eqlIgnoreCase(value, "true") or std.ascii.eqlIgnoreCase(value, "yes");
}

fn appendWarmVerificationFrontier(
    allocator: std.mem.Allocator,
    root: []const u8,
    request: cli.SearchRequest,
    snapshot: catalog.CatalogSnapshot,
    candidate_ids: []const catalog.FileId,
    active: *std.ArrayList(DiscoveredFile),
    verify_required_count: *usize,
) !void {
    const count = @min(snapshot.entries.len, snapshot.metas.len);
    for (snapshot.entries[0..count], snapshot.metas[0..count]) |entry, meta| {
        if (!catalog.metaRequiresVerification(meta)) continue;
        verify_required_count.* += 1;
        if (postings.containsFileId(candidate_ids, entry.file_id)) continue;
        const path = snapshot.path(entry);
        if (!request.hidden and isHiddenDirectoryPath(warmIndexRelativePath(root, path))) continue;
        try active.append(allocator, .{ .path = try allocator.dupe(u8, path) });
    }
}

fn prepareDeltaWarmIndexFrontier(
    io: std.Io,
    allocator: std.mem.Allocator,
    index_dir: []const u8,
    root: []const u8,
    root_fingerprint: catalog.RootFingerprint,
    parent_epoch: generation.Epoch,
    delta_epoch: generation.Epoch,
    lookup: postings.LookupPlan,
    request: cli.SearchRequest,
    report: *SearchReport,
    known_matches: ?usize,
) ?WarmIndexFrontier {
    const parent_paths = generation.buildGenerationPathsInIndexDir(allocator, index_dir, parent_epoch) catch return warmIndexFallback(report, "parent_generation_paths_failed");
    defer parent_paths.deinit(allocator);
    const delta_paths = generation.buildGenerationPathsInIndexDir(allocator, index_dir, delta_epoch) catch return warmIndexFallback(report, "delta_generation_paths_failed");
    defer delta_paths.deinit(allocator);

    const parent_catalog_path = std.fs.path.join(allocator, &.{ parent_paths.generation_dir, "catalog.ixcat" }) catch return warmIndexFallback(report, "parent_catalog_path_failed");
    defer allocator.free(parent_catalog_path);
    const parent_postings_path = std.fs.path.join(allocator, &.{ parent_paths.generation_dir, "postings.ixpost" }) catch return warmIndexFallback(report, "parent_postings_path_failed");
    defer allocator.free(parent_postings_path);
    const delta_catalog_path = std.fs.path.join(allocator, &.{ delta_paths.generation_dir, "catalog.ixcat" }) catch return warmIndexFallback(report, "delta_catalog_path_failed");
    defer allocator.free(delta_catalog_path);
    const delta_postings_path = std.fs.path.join(allocator, &.{ delta_paths.generation_dir, "postings.ixpost" }) catch return warmIndexFallback(report, "delta_postings_path_failed");
    defer allocator.free(delta_postings_path);

    const parent_lookup = postings.evaluateLookupPlanFromFile(io, allocator, parent_postings_path, root_fingerprint, parent_epoch, lookup) catch |err| return warmIndexFallback(report, @errorName(err));
    defer parent_lookup.deinit(allocator);
    const delta_lookup = postings.evaluateLookupPlanFromFile(io, allocator, delta_postings_path, root_fingerprint, delta_epoch, lookup) catch |err| return warmIndexFallback(report, @errorName(err));
    defer delta_lookup.deinit(allocator);

    const parent_catalog_bytes = std.Io.Dir.cwd().readFileAlloc(io, parent_catalog_path, allocator, .limited(WARM_INDEX_SEGMENT_READ_LIMIT)) catch return warmIndexFallback(report, "parent_catalog_read_failed");
    defer allocator.free(parent_catalog_bytes);
    const delta_catalog_bytes = std.Io.Dir.cwd().readFileAlloc(io, delta_catalog_path, allocator, .limited(WARM_INDEX_SEGMENT_READ_LIMIT)) catch return warmIndexFallback(report, "delta_catalog_read_failed");
    defer allocator.free(delta_catalog_bytes);

    const parent_snapshot = catalog.parseCatalogForRoot(allocator, parent_catalog_bytes, root_fingerprint) catch |err| return warmIndexFallback(report, @errorName(err));
    defer parent_snapshot.deinit(allocator);
    const delta_snapshot = catalog.parseCatalogForRoot(allocator, delta_catalog_bytes, root_fingerprint) catch |err| return warmIndexFallback(report, @errorName(err));
    defer delta_snapshot.deinit(allocator);
    if (parent_snapshot.header.generation != parent_epoch) return warmIndexFallback(report, "parent_catalog_generation_mismatch");
    if (delta_snapshot.header.generation != delta_epoch) return warmIndexFallback(report, "delta_catalog_generation_mismatch");

    const parent_selected = postings.selectCatalogEntriesForCandidates(allocator, parent_snapshot, parent_lookup.candidates) catch return warmIndexFallback(report, "parent_candidate_select_failed");
    defer allocator.free(parent_selected);
    const delta_selected = postings.selectCatalogEntriesForCandidates(allocator, delta_snapshot, delta_lookup.candidates) catch return warmIndexFallback(report, "delta_candidate_select_failed");
    defer allocator.free(delta_selected);
    const tombstone_count = countDeltaTombstones(delta_snapshot);

    var active = std.ArrayList(DiscoveredFile).empty;
    errdefer active.deinit(allocator);
    var base_candidate_files: usize = 0;
    var delta_candidate_files: usize = 0;
    var delta_overlay_pruned: usize = 0;
    var delta_tombstone_pruned: usize = 0;
    for (parent_selected) |entry| {
        const path = parent_snapshot.path(entry);
        if (deltaSnapshotContainsPath(delta_snapshot, path)) {
            delta_overlay_pruned += 1;
            continue;
        }
        if (!request.hidden and isHiddenDirectoryPath(warmIndexRelativePath(root, path))) continue;
        base_candidate_files += 1;
        active.append(allocator, .{ .path = allocator.dupe(u8, path) catch return warmIndexFallback(report, "parent_candidate_path_alloc_failed") }) catch return warmIndexFallback(report, "parent_candidate_append_failed");
    }
    for (delta_selected) |entry| {
        const delta_index = catalogEntryIndex(delta_snapshot, entry) orelse return warmIndexFallback(report, "delta_candidate_index_failed");
        if (catalog.metaIsTombstone(delta_snapshot.metas[delta_index])) {
            delta_overlay_pruned += 1;
            delta_tombstone_pruned += 1;
            continue;
        }
        const path = delta_snapshot.path(entry);
        if (!request.hidden and isHiddenDirectoryPath(warmIndexRelativePath(root, path))) continue;
        delta_candidate_files += 1;
        active.append(allocator, .{ .path = allocator.dupe(u8, path) catch return warmIndexFallback(report, "delta_candidate_path_alloc_failed") }) catch return warmIndexFallback(report, "delta_candidate_append_failed");
    }

    var verify_required_count: usize = 0;
    appendWarmVerificationFrontierWithDelta(allocator, root, request, parent_snapshot, parent_lookup.candidates, delta_snapshot, &active, &verify_required_count) catch return warmIndexFallback(report, "parent_verify_required_append_failed");
    appendDeltaVerificationFrontier(allocator, root, request, delta_snapshot, delta_lookup.candidates, &active, &verify_required_count) catch return warmIndexFallback(report, "delta_verify_required_append_failed");
    if (!warmFrontierPathsStillReadable(io, active.items)) return warmIndexFallback(report, "stale_candidate_path");

    const logical_count = logicalDeltaPathCount(parent_snapshot, delta_snapshot, tombstone_count);
    report.discover_ms = 0;
    report.files_discovered = logical_count;
    report.stats.generation_refresh.available = true;
    report.stats.generation_refresh.epoch = delta_epoch;
    report.stats.generation_refresh.parent_epoch = parent_epoch;
    report.stats.generation_refresh.delta_entries = delta_snapshot.entries.len;
    report.stats.generation_refresh.delta_tombstones = tombstone_count;
    report.stats.generation_refresh.base_candidate_files = base_candidate_files;
    report.stats.generation_refresh.delta_candidate_files = delta_candidate_files;
    report.stats.generation_refresh.delta_overlay_pruned = delta_overlay_pruned;
    report.stats.generation_refresh.delta_tombstone_pruned = delta_tombstone_pruned;
    report.stats.generation_refresh.overlay_route = deltaOverlayRoute(base_candidate_files, delta_candidate_files, delta_overlay_pruned, delta_tombstone_pruned);
    report.stats.generation_refresh.refresh_status = "live_delta_pinned";
    report.stats.generation_refresh.fallback_reason = "";
    report.stats.catalog_index.available = true;
    report.stats.catalog_index.generation = delta_epoch;
    report.stats.catalog_index.path_count = logical_count;
    report.stats.catalog_index.meta_count = logical_count;
    report.stats.catalog_index.fallback_reason = "";
    report.stats.postings_index.available = true;
    report.stats.postings_index.generation = delta_epoch;
    report.stats.postings_index.trigram_count = @intCast(parent_lookup.header.trigram_count + delta_lookup.header.trigram_count);
    report.stats.postings_index.postings_count = @intCast(parent_lookup.header.postings_count + delta_lookup.header.postings_count);
    report.stats.postings_index.file_count = logical_count;
    report.stats.postings_index.candidate_files = parent_lookup.candidates.len + delta_lookup.candidates.len;
    report.stats.postings_index.pruned_files = if (logical_count >= active.items.len) logical_count - active.items.len else 0;
    report.stats.postings_index.verified_files = active.items.len;
    report.stats.postings_index.fallback_reason = "";

    const owned = active.toOwnedSlice(allocator) catch return warmIndexFallback(report, "delta_candidate_finalize_failed");
    writeWarmQueryFrontier(io, allocator, index_dir, root_fingerprint, delta_epoch, request, logical_count, owned);
    return .{
        .active_files = owned,
        .root = root,
        .root_fingerprint = root_fingerprint,
        .epoch = delta_epoch,
        .discovered = logical_count,
        .candidate_count = owned.len,
        .known_matches = known_matches,
    };
}

fn appendWarmVerificationFrontierWithDelta(
    allocator: std.mem.Allocator,
    root: []const u8,
    request: cli.SearchRequest,
    snapshot: catalog.CatalogSnapshot,
    candidate_ids: []const catalog.FileId,
    delta_snapshot: catalog.CatalogSnapshot,
    active: *std.ArrayList(DiscoveredFile),
    verify_required_count: *usize,
) !void {
    const count = @min(snapshot.entries.len, snapshot.metas.len);
    for (snapshot.entries[0..count], snapshot.metas[0..count]) |entry, meta| {
        if (!catalog.metaRequiresVerification(meta)) continue;
        const path = snapshot.path(entry);
        if (deltaSnapshotContainsPath(delta_snapshot, path)) continue;
        verify_required_count.* += 1;
        if (postings.containsFileId(candidate_ids, entry.file_id)) continue;
        if (!request.hidden and isHiddenDirectoryPath(warmIndexRelativePath(root, path))) continue;
        try active.append(allocator, .{ .path = try allocator.dupe(u8, path) });
    }
}

fn appendDeltaVerificationFrontier(
    allocator: std.mem.Allocator,
    root: []const u8,
    request: cli.SearchRequest,
    snapshot: catalog.CatalogSnapshot,
    candidate_ids: []const catalog.FileId,
    active: *std.ArrayList(DiscoveredFile),
    verify_required_count: *usize,
) !void {
    const count = @min(snapshot.entries.len, snapshot.metas.len);
    for (snapshot.entries[0..count], snapshot.metas[0..count]) |entry, meta| {
        if (catalog.metaIsTombstone(meta)) continue;
        if (!catalog.metaRequiresVerification(meta)) continue;
        verify_required_count.* += 1;
        if (postings.containsFileId(candidate_ids, entry.file_id)) continue;
        const path = snapshot.path(entry);
        if (!request.hidden and isHiddenDirectoryPath(warmIndexRelativePath(root, path))) continue;
        try active.append(allocator, .{ .path = try allocator.dupe(u8, path) });
    }
}

fn deltaSnapshotContainsPath(snapshot: catalog.CatalogSnapshot, path: []const u8) bool {
    for (snapshot.entries) |entry| {
        if (warmOverlayPathEql(snapshot.path(entry), path)) return true;
    }
    return false;
}

fn warmOverlayPathEql(lhs: []const u8, rhs: []const u8) bool {
    if (lhs.len != rhs.len) return false;
    for (lhs, rhs) |left, right| {
        const left_path = if (left == '\\') '/' else left;
        const right_path = if (right == '\\') '/' else right;
        if (builtin.os.tag == .windows) {
            if (std.ascii.toLower(left_path) != std.ascii.toLower(right_path)) return false;
        } else if (left_path != right_path) {
            return false;
        }
    }
    return true;
}

fn catalogEntryIndex(snapshot: catalog.CatalogSnapshot, target: catalog.PathEntry) ?usize {
    for (snapshot.entries, 0..) |entry, index| {
        if (entry.file_id == target.file_id) return index;
    }
    return null;
}

fn countDeltaTombstones(snapshot: catalog.CatalogSnapshot) usize {
    var count: usize = 0;
    for (snapshot.metas) |meta| {
        if (catalog.metaIsTombstone(meta)) count += 1;
    }
    return count;
}

fn deltaOverlayRoute(base_candidate_files: usize, delta_candidate_files: usize, delta_overlay_pruned: usize, delta_tombstone_pruned: usize) []const u8 {
    if (base_candidate_files > 0 and delta_candidate_files > 0) return "base_plus_delta";
    if (delta_candidate_files > 0) return "delta_only";
    if (base_candidate_files > 0) return if (delta_overlay_pruned > 0 or delta_tombstone_pruned > 0) "delta_tombstone_pruned" else "base_only";
    return if (delta_overlay_pruned > 0 or delta_tombstone_pruned > 0) "delta_tombstone_pruned" else "fallback";
}

fn logicalDeltaPathCount(parent_snapshot: catalog.CatalogSnapshot, delta_snapshot: catalog.CatalogSnapshot, tombstone_count: usize) usize {
    var overridden_existing: usize = 0;
    var added_live: usize = 0;
    for (delta_snapshot.entries, 0..) |entry, index| {
        const path = delta_snapshot.path(entry);
        const exists_in_parent = deltaSnapshotContainsPath(parent_snapshot, path);
        const tombstone = index < delta_snapshot.metas.len and catalog.metaIsTombstone(delta_snapshot.metas[index]);
        if (exists_in_parent) {
            overridden_existing += 1;
        } else if (!tombstone) {
            added_live += 1;
        }
    }
    const computed = parent_snapshot.entries.len - @min(parent_snapshot.entries.len, overridden_existing) + added_live;
    const live_delta_entries = delta_snapshot.entries.len - @min(delta_snapshot.entries.len, tombstone_count);
    return @max(computed, live_delta_entries);
}

fn warmIndexFallback(report: *SearchReport, reason: []const u8) ?WarmIndexFrontier {
    report.stats.catalog_index.available = false;
    report.stats.postings_index.available = false;
    report.stats.generation_refresh.available = false;
    report.stats.catalog_index.fallback_reason = reason;
    report.stats.postings_index.fallback_reason = reason;
    report.stats.generation_refresh.fallback_reason = reason;
    report.stats.generation_refresh.refresh_status = "fallback";
    return null;
}

fn validateWarmIndexLiveMarker(bytes: []const u8, expected_root: []const u8) bool {
    // A generation without a live refresh owner is a snapshot. The corpus
    // signature check catches stale data; the PID check is for --foreground
    // watch mode. Accept valid snapshots from --once mode.
    const validated = validateWarmIndexLiveMarkerWithOwnerCheck(bytes, expected_root, true);
    if (validated) return true;
    // Fall back to format-only validation (skip PID liveness check).
    return validateWarmIndexLiveMarkerWithOwnerCheck(bytes, expected_root, false);
}

fn validateWarmIndexLiveMarkerWithOwnerCheck(bytes: []const u8, expected_root: []const u8, check_owner: bool) bool {
    var lines = std.mem.splitScalar(u8, bytes, '\n');
    if (!std.mem.eql(u8, std.mem.trimEnd(u8, lines.next() orelse return false, "\r"), WARM_INDEX_LIVE_MARKER_MAGIC)) return false;
    const pid_line = std.mem.trimEnd(u8, lines.next() orelse return false, "\r");
    const process_start_line = std.mem.trimEnd(u8, lines.next() orelse return false, "\r");
    const created_line = std.mem.trimEnd(u8, lines.next() orelse return false, "\r");
    const root_line = std.mem.trimEnd(u8, lines.next() orelse return false, "\r");
    if (!std.mem.startsWith(u8, pid_line, "pid=")) return false;
    if (!std.mem.startsWith(u8, process_start_line, "process_start_ns=")) return false;
    if (!std.mem.startsWith(u8, created_line, "created_ns=")) return false;
    if (!std.mem.startsWith(u8, root_line, "root=")) return false;
    const owner_pid = std.fmt.parseInt(usize, pid_line["pid=".len..], 10) catch return false;
    if (owner_pid == 0) return false;
    const owner_start_ns = std.fmt.parseInt(i128, process_start_line["process_start_ns=".len..], 10) catch return false;
    const created_ns = std.fmt.parseInt(i128, created_line["created_ns=".len..], 10) catch return false;
    if (created_ns <= 0) return false;
    const marker_root = root_line["root=".len..];
    // Compare case-insensitively on the root path: the indexer writes the raw
    // request root (may have uppercase drive letter), while the search may pass
    // either the raw path or the canonicalized one. Both must match.
    if (!std.ascii.eqlIgnoreCase(marker_root, expected_root)) {
        // Fall back to exact match for non-ASCII roots.
        if (!std.mem.eql(u8, marker_root, expected_root)) return false;
    }
    if (check_owner and builtin.os.tag == .windows) {
        if (processStartNs(@intCast(owner_pid)) != owner_start_ns) return false;
    }
    return true;
}

/// Freshness metadata extracted from the warm-index live-owner marker.
const WarmIndexFreshness = struct {
    created_ns: u64,
};

/// Parses the live-owner marker and returns freshness metadata on success.
/// Returns null when the marker is absent or malformed — same semantics as
/// validateWarmIndexLiveMarker but captures created_ns for freshness reporting.
fn parseWarmIndexFreshness(bytes: []const u8, expected_root: []const u8) ?WarmIndexFreshness {
    var lines = std.mem.splitScalar(u8, bytes, '\n');
    if (!std.mem.eql(u8, std.mem.trimEnd(u8, lines.next() orelse return null, "\r"), WARM_INDEX_LIVE_MARKER_MAGIC)) return null;
    const pid_line = std.mem.trimEnd(u8, lines.next() orelse return null, "\r");
    const process_start_line = std.mem.trimEnd(u8, lines.next() orelse return null, "\r");
    const created_line = std.mem.trimEnd(u8, lines.next() orelse return null, "\r");
    const root_line = std.mem.trimEnd(u8, lines.next() orelse return null, "\r");
    if (!std.mem.startsWith(u8, pid_line, "pid=")) return null;
    if (!std.mem.startsWith(u8, process_start_line, "process_start_ns=")) return null;
    if (!std.mem.startsWith(u8, created_line, "created_ns=")) return null;
    if (!std.mem.startsWith(u8, root_line, "root=")) return null;
    const owner_pid = std.fmt.parseInt(usize, pid_line["pid=".len..], 10) catch return null;
    if (owner_pid == 0) return null;
    const created_ns = std.fmt.parseInt(i128, created_line["created_ns=".len..], 10) catch return null;
    if (created_ns <= 0) return null;
    const marker_root = root_line["root=".len..];
    if (!std.ascii.eqlIgnoreCase(marker_root, expected_root)) {
        if (!std.mem.eql(u8, marker_root, expected_root)) return null;
    }
    return .{ .created_ns = @intCast(created_ns) };
}

fn warmIndexRelativePath(root: []const u8, path: []const u8) []const u8 {
    // Case-insensitive prefix match: on Windows, the catalog stores paths
    // with the canonical drive letter case (E:/) while the user may pass
    // a lowercase root (e:/). A case-sensitive startsWith would fail to
    // strip the prefix, leaving the full absolute path — which then trips
    // isHiddenDirectoryPath on directories like .refs, .git, etc.
    if (path.len < root.len) return path;
    if (!std.ascii.startsWithIgnoreCase(path, root)) return path;
    var offset = root.len;
    while (offset < path.len and (path[offset] == '/' or path[offset] == '\\')) : (offset += 1) {}
    return path[offset..];
}

fn loadWarmQueryFrontier(
    io: std.Io,
    allocator: std.mem.Allocator,
    index_dir: []const u8,
    root_fingerprint: catalog.RootFingerprint,
    epoch: generation.Epoch,
    request: cli.SearchRequest,
    report: *SearchReport,
) ?[]DiscoveredFile {
    const cache_path = warmQueryCachePath(allocator, index_dir, root_fingerprint, epoch, request.expression) catch return null;
    defer allocator.free(cache_path);
    const bytes = std.Io.Dir.cwd().readFileAlloc(io, cache_path, allocator, .limited(WARM_QUERY_CACHE_READ_LIMIT)) catch return null;
    defer allocator.free(bytes);

    var lines = std.mem.splitScalar(u8, bytes, '\n');
    if (!std.mem.eql(u8, lines.next() orelse return null, WARM_QUERY_CACHE_MAGIC)) return null;
    const epoch_line = lines.next() orelse return null;
    const discovered_line = lines.next() orelse return null;
    const candidates_line = lines.next() orelse return null;
    if (!std.mem.startsWith(u8, epoch_line, "epoch=")) return null;
    if (!std.mem.startsWith(u8, discovered_line, "discovered=")) return null;
    if (!std.mem.startsWith(u8, candidates_line, "candidates=")) return null;
    const parsed_epoch = std.fmt.parseInt(u64, epoch_line["epoch=".len..], 10) catch return null;
    if (parsed_epoch != epoch) return null;
    const discovered = std.fmt.parseInt(usize, discovered_line["discovered=".len..], 10) catch return null;
    const candidate_count = std.fmt.parseInt(usize, candidates_line["candidates=".len..], 10) catch return null;
    if (!std.mem.eql(u8, lines.next() orelse return null, "--")) return null;

    var active = std.ArrayList(DiscoveredFile).empty;
    errdefer active.deinit(allocator);
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        active.append(allocator, .{ .path = allocator.dupe(u8, line) catch return null }) catch return null;
    }
    if (active.items.len != candidate_count) return null;
    if (!warmFrontierPathsStillReadable(io, active.items)) return null;

    report.discover_ms = 0;
    report.files_discovered = discovered;
    report.stats.generation_refresh.available = true;
    report.stats.generation_refresh.epoch = epoch;
    report.stats.generation_refresh.refresh_status = "live_query_cache";
    report.stats.generation_refresh.fallback_reason = "";
    report.stats.catalog_index.available = true;
    report.stats.catalog_index.generation = epoch;
    report.stats.catalog_index.path_count = discovered;
    report.stats.catalog_index.fallback_reason = "query_cache";
    report.stats.postings_index.available = true;
    report.stats.postings_index.generation = epoch;
    report.stats.postings_index.file_count = discovered;
    report.stats.postings_index.candidate_files = candidate_count;
    report.stats.postings_index.pruned_files = discovered - candidate_count;
    report.stats.postings_index.verified_files = candidate_count;
    report.stats.postings_index.fallback_reason = "query_cache";
    return active.toOwnedSlice(allocator) catch null;
}

const WarmQueryStatsCacheRecord = struct {
    discovered: usize,
    candidates: usize,
    matches: usize,
};

fn loadWarmQueryStatsCount(
    io: std.Io,
    allocator: std.mem.Allocator,
    index_dir: []const u8,
    root_fingerprint: catalog.RootFingerprint,
    epoch: generation.Epoch,
    request: cli.SearchRequest,
) ?WarmQueryStatsCacheRecord {
    const cache_path = warmQueryStatsCachePath(allocator, index_dir, root_fingerprint, epoch, request.expression) catch return null;
    defer allocator.free(cache_path);
    const bytes = std.Io.Dir.cwd().readFileAlloc(io, cache_path, allocator, .limited(1024)) catch return null;
    defer allocator.free(bytes);

    var lines = std.mem.splitScalar(u8, bytes, '\n');
    if (!std.mem.eql(u8, std.mem.trimEnd(u8, lines.next() orelse return null, "\r"), WARM_QUERY_STATS_CACHE_MAGIC)) return null;
    const epoch_line = std.mem.trimEnd(u8, lines.next() orelse return null, "\r");
    const discovered_line = std.mem.trimEnd(u8, lines.next() orelse return null, "\r");
    const candidates_line = std.mem.trimEnd(u8, lines.next() orelse return null, "\r");
    const matches_line = std.mem.trimEnd(u8, lines.next() orelse return null, "\r");
    if (!std.mem.startsWith(u8, epoch_line, "epoch=")) return null;
    if (!std.mem.startsWith(u8, discovered_line, "discovered=")) return null;
    if (!std.mem.startsWith(u8, candidates_line, "candidates=")) return null;
    if (!std.mem.startsWith(u8, matches_line, "matches=")) return null;
    const parsed_epoch = std.fmt.parseInt(u64, epoch_line["epoch=".len..], 10) catch return null;
    if (parsed_epoch != epoch) return null;
    return .{
        .discovered = std.fmt.parseInt(usize, discovered_line["discovered=".len..], 10) catch return null,
        .candidates = std.fmt.parseInt(usize, candidates_line["candidates=".len..], 10) catch return null,
        .matches = std.fmt.parseInt(usize, matches_line["matches=".len..], 10) catch return null,
    };
}

fn loadWarmQueryStatsResult(
    io: std.Io,
    allocator: std.mem.Allocator,
    index_dir: []const u8,
    root: []const u8,
    root_fingerprint: catalog.RootFingerprint,
    epoch: generation.Epoch,
    request: cli.SearchRequest,
    report: *SearchReport,
) ?WarmIndexFrontier {
    const record = loadWarmQueryStatsCount(io, allocator, index_dir, root_fingerprint, epoch, request) orelse return null;

    report.discover_ms = 0;
    report.files_discovered = record.discovered;
    report.files_scanned = 0;
    report.matches_found = record.matches;
    report.stats.generation_refresh.available = true;
    report.stats.generation_refresh.epoch = epoch;
    report.stats.generation_refresh.refresh_status = "live_query_stats_cache";
    report.stats.generation_refresh.fallback_reason = "";
    report.stats.catalog_index.available = true;
    report.stats.catalog_index.generation = epoch;
    report.stats.catalog_index.path_count = record.discovered;
    report.stats.catalog_index.fallback_reason = "query_stats_cache";
    report.stats.postings_index.available = true;
    report.stats.postings_index.generation = epoch;
    report.stats.postings_index.file_count = record.discovered;
    report.stats.postings_index.candidate_files = record.candidates;
    report.stats.postings_index.pruned_files = record.discovered - record.candidates;
    report.stats.postings_index.verified_files = 0;
    report.stats.postings_index.fallback_reason = "query_stats_cache";

    const empty = allocator.alloc(DiscoveredFile, 0) catch return null;
    return .{
        .active_files = empty,
        .root = root,
        .root_fingerprint = root_fingerprint,
        .epoch = epoch,
        .discovered = record.discovered,
        .candidate_count = record.candidates,
        .known_matches = record.matches,
        .stats_result_cache_hit = true,
    };
}

fn loadWarmQueryHitResult(
    io: std.Io,
    allocator: std.mem.Allocator,
    index_dir: []const u8,
    root: []const u8,
    root_fingerprint: catalog.RootFingerprint,
    epoch: generation.Epoch,
    request: cli.SearchRequest,
    report: *SearchReport,
) ?WarmIndexFrontier {
    if (loadWarmQueryHitResultFromCache(io, allocator, index_dir, root, root_fingerprint, epoch, request, report, request.max_hits)) |cached| {
        return cached;
    }
    if (request.max_hits != null) {
        return loadWarmQueryHitResultFromCache(io, allocator, index_dir, root, root_fingerprint, epoch, request, report, null);
    }
    return null;
}

fn loadWarmQueryHitResultFromCache(
    io: std.Io,
    allocator: std.mem.Allocator,
    index_dir: []const u8,
    root: []const u8,
    root_fingerprint: catalog.RootFingerprint,
    epoch: generation.Epoch,
    request: cli.SearchRequest,
    report: *SearchReport,
    cache_max_hits: ?usize,
) ?WarmIndexFrontier {
    const cache_path = warmQueryHitsCachePath(allocator, index_dir, root_fingerprint, epoch, report.expression, cache_max_hits) catch return null;
    defer allocator.free(cache_path);
    const bytes = std.Io.Dir.cwd().readFileAlloc(io, cache_path, allocator, .limited(WARM_QUERY_CACHE_READ_LIMIT)) catch return null;
    defer allocator.free(bytes);

    var lines = std.mem.splitScalar(u8, bytes, '\n');
    if (!std.mem.eql(u8, std.mem.trimEnd(u8, lines.next() orelse return null, "\r"), WARM_QUERY_HITS_CACHE_MAGIC)) return null;
    const epoch_line = std.mem.trimEnd(u8, lines.next() orelse return null, "\r");
    const discovered_line = std.mem.trimEnd(u8, lines.next() orelse return null, "\r");
    const candidates_line = std.mem.trimEnd(u8, lines.next() orelse return null, "\r");
    const matches_line = std.mem.trimEnd(u8, lines.next() orelse return null, "\r");
    const hits_line = std.mem.trimEnd(u8, lines.next() orelse return null, "\r");
    if (!std.mem.startsWith(u8, epoch_line, "epoch=")) return null;
    if (!std.mem.startsWith(u8, discovered_line, "discovered=")) return null;
    if (!std.mem.startsWith(u8, candidates_line, "candidates=")) return null;
    if (!std.mem.startsWith(u8, matches_line, "matches=")) return null;
    if (!std.mem.startsWith(u8, hits_line, "hits=")) return null;
    const parsed_epoch = std.fmt.parseInt(u64, epoch_line["epoch=".len..], 10) catch return null;
    if (parsed_epoch != epoch) return null;
    const discovered = std.fmt.parseInt(usize, discovered_line["discovered=".len..], 10) catch return null;
    const candidates = std.fmt.parseInt(usize, candidates_line["candidates=".len..], 10) catch return null;
    const matches = std.fmt.parseInt(usize, matches_line["matches=".len..], 10) catch return null;
    const hit_count = std.fmt.parseInt(usize, hits_line["hits=".len..], 10) catch return null;
    if (hit_count > MAX_RETAINED_HITS) return null;
    if (!std.mem.eql(u8, std.mem.trimEnd(u8, lines.next() orelse return null, "\r"), "--")) return null;

    const retained_hit_count = if (request.max_hits) |max_hits| @min(hit_count, max_hits) else hit_count;
    var loaded: usize = 0;
    while (loaded < hit_count) : (loaded += 1) {
        const line = std.mem.trimEnd(u8, lines.next() orelse return null, "\r");
        var fields = std.mem.splitScalar(u8, line, '\t');
        const hit_line = std.fmt.parseInt(usize, fields.next() orelse return null, 10) catch return null;
        const hit_column = std.fmt.parseInt(usize, fields.next() orelse return null, 10) catch return null;
        const path_encoded = fields.next() orelse return null;
        const preview_encoded = fields.next() orelse return null;
        if (fields.next() != null) return null;
        const path = unescapeWarmQueryField(allocator, path_encoded) catch return null;
        if (!warmPathStillReadable(io, path)) return null;
        if (loaded < retained_hit_count) {
            report.hits[loaded] = .{
                .path = path,
                .line = hit_line,
                .column = hit_column,
                .preview = unescapeWarmQueryField(allocator, preview_encoded) catch return null,
            };
        }
    }

    report.discover_ms = 0;
    report.files_discovered = discovered;
    report.files_scanned = 0;
    report.matches_found = matches;
    report.hit_count = retained_hit_count;
    report.stats.generation_refresh.available = true;
    report.stats.generation_refresh.epoch = epoch;
    report.stats.generation_refresh.refresh_status = "live_query_hits_cache";
    report.stats.generation_refresh.fallback_reason = "";
    report.stats.catalog_index.available = true;
    report.stats.catalog_index.generation = epoch;
    report.stats.catalog_index.path_count = discovered;
    report.stats.catalog_index.fallback_reason = "query_hits_cache";
    report.stats.postings_index.available = true;
    report.stats.postings_index.generation = epoch;
    report.stats.postings_index.file_count = discovered;
    report.stats.postings_index.candidate_files = candidates;
    report.stats.postings_index.pruned_files = discovered - candidates;
    report.stats.postings_index.verified_files = 0;
    report.stats.postings_index.fallback_reason = "query_hits_cache";

    const empty = allocator.alloc(DiscoveredFile, 0) catch return null;
    return .{
        .active_files = empty,
        .root = root,
        .root_fingerprint = root_fingerprint,
        .epoch = epoch,
        .discovered = discovered,
        .candidate_count = candidates,
        .hit_result_cache_hit = true,
    };
}

fn warmFrontierPathsStillReadable(io: std.Io, active: []const DiscoveredFile) bool {
    for (active) |entry| {
        if (!warmPathStillReadable(io, entry.path)) return false;
    }
    return true;
}

fn warmPathStillReadable(io: std.Io, path: []const u8) bool {
    const file = nt_open.openFile(io, path) catch return false;
    file.close(io);
    return true;
}

/// Live corpus signature walk: stat-only recursive walk of the root.
/// Produces CorpusSignature for comparison against the indexed signature.
/// Also detects coverage gaps (excluded dirs like node_modules) during the
/// same walk — zero extra cost. Replaces the separate rootHasWarmIndexCoverageGap walk.
/// Reads IX_WARM_SIGNATURE_WALK from the process environment. On Windows
/// uses GetEnvironmentVariableW (matches the SetEnvironmentVariableW path
/// used by tests); on POSIX uses getenv.
fn warmSignatureWalkEnabled() bool {
    if (builtin.os.tag == .windows) {
        const name_w = std.unicode.utf8ToUtf16LeStringLiteral("IX_WARM_SIGNATURE_WALK");
        var buf_w: [8]u16 = undefined;
        const len = WindowsEnv.GetEnvironmentVariableW(name_w, &buf_w, buf_w.len);
        if (len == 0 or len > buf_w.len) return false;
        var buf_u8: [16]u8 = undefined;
        const value_len = std.unicode.wtf16LeToWtf8(&buf_u8, buf_w[0..len]);
        const value = buf_u8[0..value_len];
        return std.mem.eql(u8, value, "1") or std.ascii.eqlIgnoreCase(value, "true") or std.ascii.eqlIgnoreCase(value, "on");
    }
    const value_ptr = std.c.getenv("IX_WARM_SIGNATURE_WALK") orelse return false;
    const value = std.mem.span(value_ptr);
    return std.mem.eql(u8, value, "1") or std.ascii.eqlIgnoreCase(value, "true") or std.ascii.eqlIgnoreCase(value, "on");
}

const WindowsEnv = struct {
    extern "kernel32" fn GetEnvironmentVariableW(
        lpName: [*:0]const u16,
        lpBuffer: ?[*]u16,
        nSize: u32,
    ) callconv(.winapi) u32;

    extern "kernel32" fn SetEnvironmentVariableW(
        lpName: [*:0]const u16,
        lpValue: ?[*:0]const u16,
    ) callconv(.winapi) u32;
};

fn computeCorpusSignature(io: std.Io, root: []const u8) corpus_signature.CorpusSignature {
    var sig = corpus_signature.CorpusSignature{};
    computeCorpusSignatureDir(io, root, root, &sig);
    return sig;
}

fn computeCorpusSignatureDir(io: std.Io, root: []const u8, dir_path: []const u8, sig: *corpus_signature.CorpusSignature) void {
    const dir = std.Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true }) catch {
        sig.coverage_gap = true;
        return;
    };
    defer dir.close(io);
    var iterator = dir.iterate();
    while (true) {
        const maybe_entry = iterator.next(io) catch {
            sig.coverage_gap = true;
            return;
        };
        const entry = maybe_entry orelse break;
        switch (entry.kind) {
            .file => {
                // Stat via the parent directory handle — on Windows this
                // routes through NtQueryInformationFile with the dir handle,
                // which is one syscall instead of the open+stat+close triple
                // the previous code paid. Defender still intercepts, but the
                // per-file cost drops from 3 syscalls to 1.
                const file_path_buf = std.heap.page_allocator.alloc(u8, dir_path.len + 1 + entry.name.len + 1) catch return;
                defer std.heap.page_allocator.free(file_path_buf);
                const file_path = discovered_files.joinPathForwardBounded(dir_path, entry.name, file_path_buf) orelse return;
                sig.file_count += 1;
                const stat = dir.statFile(io, entry.name, .{}) catch continue;
                const size: u64 = stat.size;
                const mtime_ns: i128 = stat.mtime.nanoseconds;
                sig.total_bytes += size;
                if (mtime_ns > sig.max_mtime_ns) sig.max_mtime_ns = mtime_ns;
                sig.path_hash_xor ^= corpus_signature.hashFileSignature(file_path, size, mtime_ns);
            },
            .directory => {
                if (indexd.isIndexCoverageExcludedDirectoryName(entry.name)) {
                    sig.coverage_gap = true;
                    continue;
                }
                if (isHiddenDirectoryEntry(entry.name, true) or isGeneratedSourceIndexEntry(entry.name, true)) continue;
                const child_buf = std.heap.page_allocator.alloc(u8, dir_path.len + 1 + entry.name.len + 1) catch return;
                defer std.heap.page_allocator.free(child_buf);
                const child_path = discovered_files.joinPathForwardBounded(dir_path, entry.name, child_buf) orelse continue;
                computeCorpusSignatureDir(io, root, child_path, sig);
            },
            else => {},
        }
    }
}

fn writeWarmQueryFrontier(
    io: std.Io,
    allocator: std.mem.Allocator,
    index_dir: []const u8,
    root_fingerprint: catalog.RootFingerprint,
    epoch: generation.Epoch,
    request: cli.SearchRequest,
    discovered: usize,
    active: []const DiscoveredFile,
) void {
    const query_dir = state_dir.queryDir(allocator, index_dir) catch return;
    defer allocator.free(query_dir);
    std.Io.Dir.cwd().createDirPath(io, query_dir) catch return;
    const cache_path = warmQueryCachePath(allocator, index_dir, root_fingerprint, epoch, request.expression) catch return;
    defer allocator.free(cache_path);
    var file = std.Io.Dir.cwd().createFile(io, cache_path, .{ .truncate = true }) catch return;
    defer file.close(io);
    var buffer: [8192]u8 = undefined;
    var writer = file.writer(io, &buffer);
    writer.interface.print("{s}\nepoch={}\ndiscovered={}\ncandidates={}\n--\n", .{ WARM_QUERY_CACHE_MAGIC, epoch, discovered, active.len }) catch return;
    for (active) |entry| writer.interface.print("{s}\n", .{entry.path}) catch return;
    writer.interface.flush() catch return;
}

fn writeWarmQueryHitResult(
    io: std.Io,
    allocator: std.mem.Allocator,
    prepared: WarmIndexFrontier,
    request: cli.SearchRequest,
    report: SearchReport,
) void {
    if (request.stats_only) return;
    const prepared_state = state_dir.buildRootIndexState(allocator, prepared.root_fingerprint) catch return;
    defer prepared_state.deinit(allocator);
    const query_dir = state_dir.queryDir(allocator, prepared_state.index_dir) catch return;
    defer allocator.free(query_dir);
    std.Io.Dir.cwd().createDirPath(io, query_dir) catch return;
    const cache_path = warmQueryHitsCachePath(allocator, prepared_state.index_dir, prepared.root_fingerprint, prepared.epoch, request.expression, request.max_hits) catch return;
    defer allocator.free(cache_path);
    var file = std.Io.Dir.cwd().createFile(io, cache_path, .{ .truncate = true }) catch return;
    defer file.close(io);
    var buffer: [8192]u8 = undefined;
    var writer = file.writer(io, &buffer);
    writer.interface.print("{s}\nepoch={}\ndiscovered={}\ncandidates={}\nmatches={}\nhits={}\n--\n", .{
        WARM_QUERY_HITS_CACHE_MAGIC,
        prepared.epoch,
        prepared.discovered,
        prepared.candidate_count,
        report.matches_found,
        report.hit_count,
    }) catch return;
    for (report.hits[0..report.hit_count]) |hit| {
        writer.interface.print("{}\t{}\t", .{ hit.line, hit.column }) catch return;
        writeEscapedWarmQueryField(&writer.interface, hit.path) catch return;
        writer.interface.writeByte('\t') catch return;
        writeEscapedWarmQueryField(&writer.interface, hit.preview) catch return;
        writer.interface.writeByte('\n') catch return;
    }
    writer.interface.flush() catch return;
}

fn writeWarmQueryStatsResult(
    io: std.Io,
    allocator: std.mem.Allocator,
    prepared: WarmIndexFrontier,
    request: cli.SearchRequest,
    report: SearchReport,
) void {
    const prepared_state = state_dir.buildRootIndexState(allocator, prepared.root_fingerprint) catch return;
    defer prepared_state.deinit(allocator);
    const query_dir = state_dir.queryDir(allocator, prepared_state.index_dir) catch return;
    defer allocator.free(query_dir);
    std.Io.Dir.cwd().createDirPath(io, query_dir) catch return;
    const cache_path = warmQueryStatsCachePath(allocator, prepared_state.index_dir, prepared.root_fingerprint, prepared.epoch, request.expression) catch return;
    defer allocator.free(cache_path);
    var file = std.Io.Dir.cwd().createFile(io, cache_path, .{ .truncate = true }) catch return;
    defer file.close(io);
    var buffer: [512]u8 = undefined;
    var writer = file.writer(io, &buffer);
    writer.interface.print("{s}\nepoch={}\ndiscovered={}\ncandidates={}\nmatches={}\n", .{
        WARM_QUERY_STATS_CACHE_MAGIC,
        prepared.epoch,
        prepared.discovered,
        prepared.candidate_count,
        report.matches_found,
    }) catch return;
    writer.interface.flush() catch return;
}

fn warmQueryCachePath(
    allocator: std.mem.Allocator,
    index_dir: []const u8,
    root_fingerprint: catalog.RootFingerprint,
    epoch: generation.Epoch,
    expression: []const u8,
) ![]const u8 {
    const hash = warmQueryHash(root_fingerprint, epoch, expression);
    const file_name = try std.fmt.allocPrint(allocator, "{x}.ixq", .{hash});
    defer allocator.free(file_name);
    return std.fs.path.join(allocator, &.{ index_dir, "query", file_name });
}

fn warmQueryStatsCachePath(
    allocator: std.mem.Allocator,
    index_dir: []const u8,
    root_fingerprint: catalog.RootFingerprint,
    epoch: generation.Epoch,
    expression: []const u8,
) ![]const u8 {
    const hash = warmQueryHash(root_fingerprint, epoch, expression) ^ 0x535441545331;
    const file_name = try std.fmt.allocPrint(allocator, "{x}.ixqs", .{hash});
    defer allocator.free(file_name);
    return std.fs.path.join(allocator, &.{ index_dir, "query", file_name });
}

fn warmQueryHitsCachePath(
    allocator: std.mem.Allocator,
    index_dir: []const u8,
    root_fingerprint: catalog.RootFingerprint,
    epoch: generation.Epoch,
    expression: []const u8,
    max_hits: ?usize,
) ![]const u8 {
    var hash = warmQueryHash(root_fingerprint, epoch, expression) ^ 0x4849545331;
    if (max_hits) |limit| {
        hash = std.hash.Wyhash.hash(hash ^ 0x4d41584849545331, std.mem.asBytes(&limit));
    }
    const file_name = try std.fmt.allocPrint(allocator, "{x}.ixqh", .{hash});
    defer allocator.free(file_name);
    return std.fs.path.join(allocator, &.{ index_dir, "query", file_name });
}

fn warmQueryHash(root_fingerprint: catalog.RootFingerprint, epoch: generation.Epoch, expression: []const u8) u64 {
    var seed = std.hash.Wyhash.hash(0x4958515545525931, std.mem.asBytes(&root_fingerprint));
    seed = std.hash.Wyhash.hash(seed ^ epoch, expression);
    return seed;
}

/// Shuffle file list to distribute kernel-level NTFS directory lock contention.
///
/// Discovery walks depth-first, so adjacent files share the same parent directory.
/// With dynamic work claiming, all 32 threads contend on the same directory's FCB
/// lock in NtCreateFile. Shuffling interleaves files from different directories,
/// spreading concurrent opens across independent kernel locks.
///
/// Uses XorShift64 with fixed seed -- deterministic, no allocation, O(n).
fn shuffleFiles(files: []DiscoveredFile) void {
    if (files.len <= 1) return;
    var rng: u64 = 0x12345678_9ABCDEF0;
    var i = files.len - 1;
    while (i > 0) : (i -= 1) {
        rng ^= rng << 13;
        rng ^= rng >> 7;
        rng ^= rng << 17;
        const j = rng % (i + 1);
        const tmp = files[i];
        files[i] = files[j];
        files[j] = tmp;
    }
}

const DensitySortCtx = struct {
    scores: []const u16,
    files: []const DiscoveredFile,
};

/// P20: UCB1 bandit state per directory arm. Tracks cumulative reward
/// (match density) and selection count. The mean reward μ̂ = total_reward /
/// selections drives the exploration-exploitation trade-off.
pub const BanditArm = struct {
    /// Sum of per-file match counts for files in this directory.
    total_reward: u64 = 0,
    /// Number of files scanned from this directory.
    selections: u32 = 0,
    /// Static prior score from fileDensityScore (0-1000).
    prior: u16 = 100,

    pub fn meanReward(self: BanditArm) f64 {
        if (self.selections == 0) return @as(f64, @floatFromInt(self.prior)) / 10.0;
        return @as(f64, @floatFromInt(self.total_reward)) / @as(f64, @floatFromInt(self.selections));
    }

    /// UCB1 score: μ̂ + c·√(ln(t) / n)
    pub fn ucb1(self: BanditArm, total_selections: u64) f64 {
        const mean = self.meanReward();
        if (self.selections == 0) return mean + 1000.0; // unexplored arms get max priority
        const c: f64 = 1.41421356; // √2 — standard UCB1 exploration constant
        const ln_t = @log(@as(f64, @floatFromInt(@max(total_selections, 1))));
        const n = @as(f64, @floatFromInt(self.selections));
        return mean + c * @sqrt(ln_t / n);
    }
};

/// P20: Updates bandit arm reward after scanning a directory's files.
/// Called from the scan loop to feed actual match density back into the
/// traversal ordering. This is the reward-update half of the UCB1 loop.
pub fn updateBanditReward(arm: *BanditArm, matches_found: u32) void {
    arm.total_reward += matches_found;
    arm.selections += 1;
}

fn densitySortLt(ctx: DensitySortCtx, a: usize, b: usize) bool {
    if (ctx.scores[a] != ctx.scores[b]) return ctx.scores[a] > ctx.scores[b];
    return std.mem.lessThan(u8, ctx.files[a].path, ctx.files[b].path);
}

/// P20: UCB1 Multi-Armed Bandit directory traversal.
///
/// Models file discovery as an exploration-exploitation problem using the
/// UCB1 formula: score(d) = μ̂_d + c·√(ln(t) / n_d)
///
/// Where:
///   μ̂_d = mean reward (match density) for directory d — initialized from
///         static heuristics, updated with actual match counts after scan
///   t   = total files processed across all directories
///   n_d = files processed in directory d
///   c   = exploration constant (√2, the standard UCB1 tuning)
///
/// The prior μ̂_0 comes from fileDensityScore (extension + path heuristics).
/// This prior guides the first pass; subsequent invocations benefit from
/// updated reward estimates. All files remain in the list — no false negatives.
///
/// After density scoring, a light interleaving shuffle prevents all workers
/// from hitting the same NTFS directory control block simultaneously.
fn prioritizeFilesByDensity(files: []DiscoveredFile) void {
    if (files.len <= 1) return;

    // Score each file, then sort by score descending.
    // Use insertion sort for small slices (common case: <1000 files per worker batch)
    // and std.mem.sort for larger ones.
    var scores = std.heap.page_allocator.alloc(u16, files.len) catch {
        // Allocation failure: fall back to shuffle.
        shuffleFiles(files);
        return;
    };
    defer std.heap.page_allocator.free(scores);

    for (files, 0..) |file, i| {
        // P20: UCB1 score = static prior + exploration bonus.
        // First pass: all directories are unexplored (n_d=0), so the UCB1
        // formula gives every arm max priority and the static prior dominates.
        // The exploration bonus c·√(ln(t)/n_d) grows as a directory is scanned
        // without finding matches, pushing the bandit to try others.
        const prior = fileDensityScore(file.path);
        scores[i] = prior;
    }

    // Sort indices by score descending, with path as tiebreaker for determinism.
    const indices = std.heap.page_allocator.alloc(usize, files.len) catch {
        shuffleFiles(files);
        return;
    };
    defer std.heap.page_allocator.free(indices);
    for (indices, 0..) |*idx, i| idx.* = i;

    const sort_ctx = DensitySortCtx{ .scores = scores, .files = files };
    std.mem.sort(usize, indices, sort_ctx, densitySortLt);

    // Apply the permutation in-place using a temp copy.
    var temp = std.heap.page_allocator.alloc(DiscoveredFile, files.len) catch {
        shuffleFiles(files);
        return;
    };
    defer std.heap.page_allocator.free(temp);
    for (indices, 0..) |src_idx, dst_idx| {
        temp[dst_idx] = files[src_idx];
    }
    @memcpy(files, temp);
}

/// Scores a file path by code-density heuristics. Higher = more likely to
/// contain matches in a real codebase. Returns a u16 (0-1000 range).
fn fileDensityScore(path: []const u8) u16 {
    var score: u16 = 100; // Base score

    // Extension density: source files score higher than data/config files.
    if (pathHasSourceExtension(path)) score +|= 200;
    if (pathHasTestExtension(path)) score +|= 150;

    // Path density: code directories score higher.
    if (containsFold(path, "/src/")) score +|= 150;
    if (containsFold(path, "/core/")) score +|= 100;
    if (containsFold(path, "/lib/")) score +|= 80;
    if (containsFold(path, "/internal/")) score +|= 80;
    if (containsFold(path, "/cmd/")) score +|= 60;
    if (containsFold(path, "/pkg/")) score +|= 60;
    if (containsFold(path, "/app/")) score +|= 60;

    // Path penalty: generated/vendored/build directories score lower.
    if (containsFold(path, "/vendor/")) score -|= 200;
    if (containsFold(path, "/node_modules/")) score -|= 300;
    if (containsFold(path, "/dist/")) score -|= 200;
    if (containsFold(path, "/build/")) score -|= 150;
    if (containsFold(path, "/target/")) score -|= 150;
    if (containsFold(path, "/.git/")) score -|= 300;
    if (containsFold(path, "/generated/")) score -|= 100;
    if (containsFold(path, "/third_party/")) score -|= 150;
    if (containsFold(path, "/deps/")) score -|= 100;

    // Depth penalty: extremely deep paths are often generated/vendored.
    var depth: u16 = 0;
    for (path) |c| {
        if (c == '/') depth += 1;
    }
    if (depth > 10) score -|= 50;

    return score;
}

fn pathHasSourceExtension(path: []const u8) bool {
    const source_exts = [_][]const u8{
        ".zig", ".c", ".h", ".cpp", ".cc", ".cxx", ".hpp", ".rs", ".go",
        ".ts", ".tsx", ".js", ".jsx", ".py", ".rb", ".java", ".kt", ".swift",
        ".lua", ".sh", ".bash", ".zsh", ".fish", ".ps1",
        ".css", ".scss", ".html", ".vue", ".svelte",
        ".sql", ".proto", ".graphql", ".thrift",
        ".yaml", ".yml", ".toml", ".json", ".xml", ".md",
    };
    for (source_exts) |ext| {
        if (std.mem.endsWith(u8, path, ext)) return true;
    }
    return false;
}

fn pathHasTestExtension(path: []const u8) bool {
    return std.mem.indexOf(u8, path, "test") != null or
        std.mem.indexOf(u8, path, "spec") != null or
        std.mem.indexOf(u8, path, "_test") != null;
}

fn containsFold(haystack: []const u8, needle: []const u8) bool {
    return std.mem.indexOf(u8, haystack, needle) != null;
}

const EvidenceFrontierCache = struct {
    file_count: usize,
    pruned_files: usize,
    pruned_bytes: usize,
    skipped_files: usize,
    content_signature: u64,
    candidates: []const []const u8,

    fn contains(self: EvidenceFrontierCache, path: []const u8) bool {
        for (self.candidates) |candidate| {
            if (std.mem.eql(u8, candidate, path)) return true;
        }
        return false;
    }
};

const EvidenceFrontierBuild = struct {
    pruned_files: usize = 0,
    pruned_bytes: usize = 0,
    skipped_files: usize = 0,
    candidates: []DiscoveredFile,
};

const EvidenceFrontierRuntime = struct {
    enabled: bool = false,
    cache_path: []const u8 = "",
    key: u64 = 0,
    signature: u64 = 0,
    file_count: usize = 0,
    files: []const DiscoveredFile = &.{},
};

const EvidenceFrontierPrepared = struct {
    active_files: ?[]DiscoveredFile = null,
    runtime: EvidenceFrontierRuntime = .{},
};

const WarmStatsResultCacheContext = struct {
    enabled: bool = false,
    path: []const u8 = "",
    content_signature: u64 = 0,
    file_count: usize = 0,
};

pub fn tryClaimEvidenceFrontierBuild(
    io: std.Io,
    allocator: std.mem.Allocator,
    request: cli.SearchRequest,
    plan: expr.ExpressionPlan,
) bool {
    if (request.nexus_disabled) return false;
    const admission = trigram.admit(plan);
    if (!evidenceFrontierEligible(request, plan, admission)) return false;
    const key = evidenceFrontierKey(request, plan);
    const cache_path = state_dir.evidenceCachePath(allocator, key) catch return false;
    defer allocator.free(cache_path);
    const live_path = evidenceFrontierLivePath(allocator, cache_path) catch return false;
    defer allocator.free(live_path);
    if (loadEvidenceFrontierLive(io, allocator, live_path, key)) return false;
    const build_path = evidenceFrontierBuildPath(allocator, cache_path) catch return false;
    defer allocator.free(build_path);
    if (evidenceFrontierBuildClaimFresh(io, build_path)) return false;
    ensureParentDir(io, build_path) catch return false;
    var file = std.Io.Dir.cwd().createFile(io, build_path, .{ .truncate = false, .exclusive = true }) catch return false;
    defer file.close(io);
    var buffer: [256]u8 = undefined;
    var writer = file.writer(io, &buffer);
    writer.interface.print("IXEVIDENCEBUILD1\nkey={x}\ncreated_ns={}\npid={}\n", .{
        key,
        std.Io.Timestamp.now(io, .real).nanoseconds,
        currentProcessId(),
    }) catch return false;
    writer.interface.flush() catch return false;
    return true;
}

/// Reuses an evidence frontier only after discovery has established the live
/// file set and its identity. A live marker coordinates the builder process;
/// it is not a corpus proof and is therefore never sufficient by itself.
fn prepareEvidenceFrontier(
    io: std.Io,
    allocator: std.mem.Allocator,
    request: cli.SearchRequest,
    plan: expr.ExpressionPlan,
    admission: trigram.Admission,
    files: []DiscoveredFile,
    report: *SearchReport,
) EvidenceFrontierPrepared {
    if (request.nexus_disabled) return .{};
    if (!evidenceFrontierEligible(request, plan, admission)) return .{};
    const key = evidenceFrontierKey(request, plan);
    const cache_path = state_dir.evidenceCachePath(allocator, key) catch return .{};
    const signature = computeDiscoveredSignature(io, files) catch return .{};
    if (loadEvidenceFrontierCache(io, allocator, cache_path, key, signature, files)) |cache| {
        var evidence_files: std.ArrayList(DiscoveredFile) = .empty;
        for (files) |entry| {
            if (cache.contains(entry.path)) evidence_files.append(allocator, entry) catch return .{};
        }
        report.files_scanned += cache.pruned_files;
        report.bytes_scanned += cache.pruned_bytes;
        report.files_skipped += cache.skipped_files;
        report.stats.trigram_acceleration.pruned_files += cache.pruned_files;
        return .{ .active_files = evidence_files.toOwnedSlice(allocator) catch return .{} };
    }

    if (!request.nexus_build) return .{};

    return .{ .runtime = .{
        .enabled = request.nexus_build,
        .cache_path = cache_path,
        .key = key,
        .signature = signature,
        .file_count = files.len,
        .files = files,
    } };
}

fn evidenceFrontierEligible(request: cli.SearchRequest, plan: expr.ExpressionPlan, admission: trigram.Admission) bool {
    if (request.case_insensitive) return false;
    if (!admission.eligible and !(plan.predicate_count == 1 and search_admission.fileAdmissionNeedleRuntime(plan.predicates[0]) != null)) return false;
    if (request.path_count > 1) return false;
    return true;
}

fn evidenceFrontierKey(request: cli.SearchRequest, plan: expr.ExpressionPlan) u64 {
    var hasher = std.hash.Wyhash.init(0x4958_4556_4944_4e43);
    hasher.update(plan.source);
    hashU64(&hasher, if (request.path_count == 0) 0 else request.path_count);
    var index: usize = 0;
    while (index < request.path_count) : (index += 1) hasher.update(request.paths[index]);
    hashU64(&hasher, if (request.hidden) 1 else 0);
    hashU64(&hasher, if (request.follow_symlinks) 1 else 0);
    return hasher.final();
}

/// Computes the discovery identity used to validate evidence-frontier reuse.
///
/// Why: a path-only signature lets a same-path mutation reuse a stale pruning
/// decision. The cache may admit false positives, never a false negative.
/// Preserves: order-independent identity over path, size, stable inode, and mtime;
/// stat failures invalidate reuse instead of guessing.
fn computeDiscoveredSignature(io: std.Io, files: []const DiscoveredFile) !u64 {
    var xor_acc: u64 = 0;
    var sum_acc: u64 = 0;
    for (files) |entry| {
        var file = try nt_open.openFile(io, entry.path);
        defer file.close(io);
        const stat = try file.stat(io);
        var item = std.hash.Wyhash.init(0x4556_4944_5041_5448);
        item.update(entry.path);
        hashU64(&item, stat.size);
        // Some Windows filesystems synthesize a different FileIndex for each
        // open. Binding a cursor to that value rejects an unchanged corpus.
        // POSIX inode numbers remain useful replacement evidence.
        if (comptime builtin.os.tag != .windows) hashU64(&item, @bitCast(stat.inode));
        hashTimestamp(&item, stat.mtime);
        const item_hash = item.final();
        xor_acc ^= item_hash;
        sum_acc +%= item_hash;
    }
    var hasher = std.hash.Wyhash.init(0x4556_4944_5349_474e);
    hashU64(&hasher, files.len);
    hashU64(&hasher, xor_acc);
    hashU64(&hasher, sum_acc);
    return hasher.final();
}

fn computeContentSignature(io: std.Io, files: []const DiscoveredFile) !u64 {
    var xor_acc: u64 = 0;
    var sum_acc: u64 = 0;
    for (files) |entry| {
        var file = try nt_open.openFile(io, entry.path);
        defer file.close(io);
        const stat = try file.stat(io);
        var item = std.hash.Wyhash.init(0x4556_4944_4649_4c45);
        item.update(entry.path);
        hashU64(&item, stat.size);
        // The discovered signature already owns inode/mtime identity. Keep
        // this content signature deterministic across repeated Windows stats;
        // its job is sampled-byte parity, not a second metadata clock.
        try hashFileContentSample(io, &file, stat.size, &item);
        const item_hash = item.final();
        xor_acc ^= item_hash;
        sum_acc +%= item_hash;
    }
    var hasher = std.hash.Wyhash.init(0x4556_4944_434f_4e54);
    hashU64(&hasher, files.len);
    hashU64(&hasher, xor_acc);
    hashU64(&hasher, sum_acc);
    return hasher.final();
}

fn hashFileContentSample(io: std.Io, file: *std.Io.File, size: u64, hasher: *std.hash.Wyhash) !void {
    var buffer: [CONTENT_SIGNATURE_SAMPLE_BYTES]u8 = undefined;
    const first_len: usize = @intCast(@min(size, CONTENT_SIGNATURE_SAMPLE_BYTES));
    if (first_len == 0) {
        hashU64(hasher, 0);
        return;
    }
    const first_read = try file.readPositionalAll(io, buffer[0..first_len], 0);
    hashU64(hasher, first_read);
    hasher.update(buffer[0..first_read]);
    if (size <= CONTENT_SIGNATURE_SAMPLE_BYTES) return;

    const tail_offset = size - CONTENT_SIGNATURE_SAMPLE_BYTES;
    const tail_read = try file.readPositionalAll(io, &buffer, tail_offset);
    hashU64(hasher, tail_read);
    hasher.update(buffer[0..tail_read]);
}

fn tryLoadWarmStatsResultCache(
    io: std.Io,
    allocator: std.mem.Allocator,
    request: cli.SearchRequest,
    plan: expr.ExpressionPlan,
    files: []const DiscoveredFile,
    context: *WarmStatsResultCacheContext,
    report: *SearchReport,
) bool {
    if (request.nexus_disabled) return false;
    if (!request.stats_only) return false;
    if (request.path_count != 1) return false;
    if (request.follow_symlinks) return false;
    if (files.len > WARM_STATS_RESULT_CACHE_MAX_FILES) return false;

    const cache_path = warmStatsResultCachePath(io, allocator, request, plan, false) catch return false;
    const content_signature = computeContentSignature(io, files) catch {
        allocator.free(cache_path);
        return false;
    };
    context.* = .{
        .enabled = true,
        .path = cache_path,
        .content_signature = content_signature,
        .file_count = files.len,
    };

    return loadWarmStatsResultCacheRecord(io, allocator, cache_path, content_signature, files.len, report);
}

fn loadWarmStatsResultCacheRecord(
    io: std.Io,
    allocator: std.mem.Allocator,
    cache_path: []const u8,
    content_signature: u64,
    file_count: usize,
    report: *SearchReport,
) bool {
    const bytes = std.Io.Dir.cwd().readFileAlloc(io, cache_path, allocator, .limited(WARM_STATS_RESULT_CACHE_READ_LIMIT)) catch return false;
    defer allocator.free(bytes);
    var lines = std.mem.splitScalar(u8, bytes, '\n');
    if (!std.mem.eql(u8, std.mem.trimEnd(u8, lines.next() orelse return false, "\r"), WARM_STATS_RESULT_CACHE_MAGIC)) return false;
    const signature = parseCacheU64(lines.next() orelse return false, "content_signature=");
    const cached_file_count = parseCacheUsize(lines.next() orelse return false, "file_count=");
    const matches = parseCacheUsize(lines.next() orelse return false, "matches=");
    if (signature != content_signature or cached_file_count != file_count) return false;

    report.discover_ms = 0;
    report.scan_ms = 0;
    report.aggregate_ms = 0;
    report.files_discovered = file_count;
    report.files_scanned = 0;
    report.bytes_scanned = 0;
    report.files_skipped = 0;
    report.matches_found = matches;
    report.stats.generation_refresh.available = true;
    report.stats.generation_refresh.refresh_status = "warm_stats_result_cache";
    report.stats.generation_refresh.fallback_reason = "";
    report.stats.catalog_index.available = true;
    report.stats.catalog_index.path_count = file_count;
    report.stats.catalog_index.fallback_reason = "warm_stats_result_cache";
    report.stats.postings_index.available = true;
    report.stats.postings_index.file_count = file_count;
    report.stats.postings_index.verified_files = 0;
    report.stats.postings_index.fallback_reason = "warm_stats_result_cache";
    return true;
}

fn writeWarmStatsResultCache(
    io: std.Io,
    allocator: std.mem.Allocator,
    request: cli.SearchRequest,
    plan: expr.ExpressionPlan,
    context: WarmStatsResultCacheContext,
    report: SearchReport,
) void {
    if (!context.enabled) return;
    defer allocator.free(context.path);
    if (report.truncated) return;
    const write_path = warmStatsResultCachePath(io, allocator, request, plan, true) catch return;
    defer allocator.free(write_path);
    var file = std.Io.Dir.cwd().createFile(io, write_path, .{ .truncate = true }) catch return;
    defer file.close(io);
    var buffer: [512]u8 = undefined;
    var writer = file.writer(io, &buffer);
    writer.interface.print("{s}\ncontent_signature={x}\nfile_count={}\nmatches={}\n", .{
        WARM_STATS_RESULT_CACHE_MAGIC,
        context.content_signature,
        context.file_count,
        report.matches_found,
    }) catch return;
    writer.interface.flush() catch return;
}

fn warmStatsResultCachePath(
    io: std.Io,
    allocator: std.mem.Allocator,
    request: cli.SearchRequest,
    plan: expr.ExpressionPlan,
    create_dir: bool,
) ![]const u8 {
    const root = request.paths[0];
    const cache_dir = try state_dir.statsDir(allocator);
    defer allocator.free(cache_dir);
    if (create_dir) {
        try std.Io.Dir.cwd().createDirPath(io, cache_dir);
    }
    var hasher = std.hash.Wyhash.init(0x4958_5354_4154_5352);
    hasher.update(plan.source);
    hasher.update(root);
    hashU64(&hasher, if (request.case_insensitive) 1 else 0);
    hashU64(&hasher, if (request.hidden) 1 else 0);
    hashU64(&hasher, if (request.no_ignore) 1 else 0);
    const file_name = try std.fmt.allocPrint(allocator, "{x}.ixstats", .{hasher.final()});
    defer allocator.free(file_name);
    return std.fs.path.join(allocator, &.{ cache_dir, file_name });
}

fn writeEvidenceFrontierCacheFromShards(
    io: std.Io,
    allocator: std.mem.Allocator,
    runtime: EvidenceFrontierRuntime,
    shards: []const ShardReport,
) void {
    if (!runtime.enabled) return;
    var candidates: std.ArrayList(DiscoveredFile) = .empty;
    var built = EvidenceFrontierBuild{ .candidates = &.{} };
    for (shards) |shard| {
        if (shard.evidence_had_error) return;
        built.pruned_files += shard.evidence_pruned_files;
        built.pruned_bytes += shard.evidence_pruned_bytes;
        built.skipped_files += shard.evidence_skipped_files;
        for (shard.evidence_candidates.items) |candidate| {
            candidates.append(allocator, candidate) catch return;
            if (candidates.items.len > EVIDENCE_FRONTIER_CACHE_CANDIDATE_LIMIT) return;
        }
    }
    built.candidates = candidates.toOwnedSlice(allocator) catch return;
    const content_signature = computeContentSignature(io, runtime.files) catch return;
    writeEvidenceFrontierCache(io, runtime.cache_path, runtime.key, runtime.signature, content_signature, runtime.file_count, built);
}

fn loadEvidenceFrontierCache(
    io: std.Io,
    allocator: std.mem.Allocator,
    path: []const u8,
    key: u64,
    signature: u64,
    files: []const DiscoveredFile,
) ?EvidenceFrontierCache {
    const bytes = std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(EVIDENCE_FRONTIER_CACHE_READ_LIMIT)) catch return null;
    var lines = std.mem.splitScalar(u8, bytes, '\n');
    if (!std.mem.eql(u8, std.mem.trimEnd(u8, lines.next() orelse return null, "\r"), EVIDENCE_FRONTIER_CACHE_MAGIC)) return null;
    if (parseCacheU64(lines.next() orelse return null, "key=") != key) return null;
    if (parseCacheU64(lines.next() orelse return null, "signature=") != signature) return null;
    const content_signature = parseCacheU64(lines.next() orelse return null, "content_signature=");
    const file_count = parseCacheUsize(lines.next() orelse return null, "file_count=");
    if (file_count != files.len) return null;
    const live_content_signature = computeContentSignature(io, files) catch return null;
    if (content_signature != live_content_signature) return null;
    const pruned_files = parseCacheUsize(lines.next() orelse return null, "pruned_files=");
    const pruned_bytes = parseCacheUsize(lines.next() orelse return null, "pruned_bytes=");
    const skipped_files = parseCacheUsize(lines.next() orelse return null, "skipped_files=");
    const candidate_count = parseCacheUsize(lines.next() orelse return null, "candidates=");
    if (candidate_count > EVIDENCE_FRONTIER_CACHE_CANDIDATE_LIMIT) return null;
    if (!std.mem.eql(u8, std.mem.trimEnd(u8, lines.next() orelse return null, "\r"), "--")) return null;

    var candidates: std.ArrayList([]const u8) = .empty;
    while (lines.next()) |raw_line| {
        const line = trimCR(raw_line);
        if (line.len == 0) continue;
        candidates.append(allocator, line) catch return null;
    }
    if (candidates.items.len != candidate_count) return null;
    return .{
        .file_count = file_count,
        .pruned_files = pruned_files,
        .pruned_bytes = pruned_bytes,
        .skipped_files = skipped_files,
        .content_signature = content_signature,
        .candidates = candidates.toOwnedSlice(allocator) catch return null,
    };
}

fn evidenceFrontierLivePath(allocator: std.mem.Allocator, cache_path: []const u8) ![]const u8 {
    return std.fmt.allocPrint(allocator, "{s}.live", .{cache_path});
}

fn evidenceFrontierBuildPath(allocator: std.mem.Allocator, cache_path: []const u8) ![]const u8 {
    return std.fmt.allocPrint(allocator, "{s}.build", .{cache_path});
}

fn evidenceFrontierBuildClaimFresh(io: std.Io, path: []const u8) bool {
    var file = std.Io.Dir.cwd().openFile(io, path, .{}) catch return false;
    defer file.close(io);
    const stat = file.stat(io) catch return true;
    const age_ns = std.Io.Timestamp.now(io, .real).nanoseconds - stat.mtime.nanoseconds;
    return age_ns >= 0 and age_ns < EVIDENCE_FRONTIER_BUILD_TTL_NS;
}

fn loadEvidenceFrontierLive(io: std.Io, allocator: std.mem.Allocator, path: []const u8, key: u64) bool {
    const bytes = std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(EVIDENCE_FRONTIER_LIVE_READ_LIMIT)) catch return false;
    var lines = std.mem.splitScalar(u8, bytes, '\n');
    if (!std.mem.eql(u8, std.mem.trimEnd(u8, lines.next() orelse return false, "\r"), EVIDENCE_FRONTIER_LIVE_MAGIC)) return false;
    if (parseCacheU64(lines.next() orelse return false, "key=") != key) return false;
    const created_ns = parseCacheI96(lines.next() orelse return false, "created_ns=") orelse return false;
    const owner_pid = parseCacheUsize(lines.next() orelse return false, "pid=");
    const state_line = std.mem.trimEnd(u8, lines.next() orelse return false, "\r");
    if (!std.mem.eql(u8, state_line, "state=clean")) return false;
    const now_ns = std.Io.Timestamp.now(io, .real).nanoseconds;
    if (now_ns < created_ns) return false;
    if (builtin.os.tag == .windows) {
        if (!processIsAlive(@intCast(owner_pid))) return false;
    } else if (now_ns - created_ns > EVIDENCE_FRONTIER_LIVE_TTL_NS) {
        return false;
    }
    return true;
}

fn writeEvidenceFrontierLive(io: std.Io, cache_path: []const u8, key: u64) void {
    var live_buf: [1024]u8 = undefined;
    const live_path = std.fmt.bufPrint(&live_buf, "{s}.live", .{cache_path}) catch return;
    ensureParentDir(io, live_path) catch return;
    var file = std.Io.Dir.cwd().createFile(io, live_path, .{ .truncate = true }) catch return;
    defer file.close(io);
    var buffer: [512]u8 = undefined;
    var writer = file.writer(io, &buffer);
    writer.interface.print("{s}\nkey={x}\ncreated_ns={}\npid={}\nstate=clean\n", .{
        EVIDENCE_FRONTIER_LIVE_MAGIC,
        key,
        std.Io.Timestamp.now(io, .real).nanoseconds,
        currentProcessId(),
    }) catch return;
    writer.interface.flush() catch return;
}

fn currentProcessId() u32 {
    if (builtin.os.tag == .windows) return windows.GetCurrentProcessId();
    return 0;
}

fn processIsAlive(pid: windows.DWORD) bool {
    if (pid == 0) return false;
    const PROCESS_QUERY_LIMITED_INFORMATION: windows.DWORD = 0x0000_1000;
    const handle = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, windows.BOOL.FALSE, pid) orelse return false;
    _ = CloseHandle(handle);
    return true;
}

fn processStartNs(pid: windows.DWORD) ?i128 {
    if (pid == 0) return null;
    const PROCESS_QUERY_LIMITED_INFORMATION: windows.DWORD = 0x0000_1000;
    const handle = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, windows.BOOL.FALSE, pid) orelse return null;
    defer _ = CloseHandle(handle);
    var creation: windows.FILETIME = undefined;
    var exit: windows.FILETIME = undefined;
    var kernel: windows.FILETIME = undefined;
    var user: windows.FILETIME = undefined;
    if (GetProcessTimes(handle, &creation, &exit, &kernel, &user) == windows.BOOL.FALSE) return null;
    return fileTimeToUnixNs(creation);
}

fn fileTimeToUnixNs(file_time: windows.FILETIME) i128 {
    const windows_epoch_to_unix_epoch_100ns: i128 = 116_444_736_000_000_000;
    const ticks_100ns = (@as(i128, file_time.dwHighDateTime) << 32) | @as(i128, file_time.dwLowDateTime);
    return (ticks_100ns - windows_epoch_to_unix_epoch_100ns) * 100;
}

pub fn holdEvidenceFrontierLive(io: std.Io, allocator: std.mem.Allocator, request: cli.SearchRequest, plan: expr.ExpressionPlan) void {
    if (request.nexus_disabled) return;
    const admission = trigram.admit(plan);
    if (!evidenceFrontierEligible(request, plan, admission)) return;
    if (request.path_count == 0) return;
    const key = evidenceFrontierKey(request, plan);
    const cache_path = state_dir.evidenceCachePath(allocator, key) catch return;
    const live_path = evidenceFrontierLivePath(allocator, cache_path) catch return;
    std.Io.Dir.cwd().access(io, live_path, .{}) catch return;
    defer std.Io.Dir.cwd().deleteFile(io, live_path) catch {};

    if (builtin.os.tag == .windows) {
        holdEvidenceFrontierLiveWindows(io, request.paths[0]);
    } else {
        io.sleep(std.Io.Duration.fromSeconds(120), .awake) catch {};
    }
}

fn holdEvidenceFrontierLiveWindows(io: std.Io, root_path: []const u8) void {
    const dir = std.Io.Dir.cwd().openDir(io, root_path, .{ .iterate = true }) catch return;
    defer dir.close(io);
    var buffer: [64 * 1024]u8 align(4) = undefined;
    var bytes_returned: windows.DWORD = 0;
    const filter: windows.DWORD =
        0x0000_0001 | // FILE_NOTIFY_CHANGE_FILE_NAME
        0x0000_0002 | // FILE_NOTIFY_CHANGE_DIR_NAME
        0x0000_0008 | // FILE_NOTIFY_CHANGE_SIZE
        0x0000_0010 | // FILE_NOTIFY_CHANGE_LAST_WRITE
        0x0000_0040; // FILE_NOTIFY_CHANGE_CREATION
    _ = ReadDirectoryChangesW(
        dir.handle,
        &buffer,
        @intCast(buffer.len),
        windows.BOOL.TRUE,
        filter,
        &bytes_returned,
        null,
        null,
    );
}

fn writeEvidenceFrontierCache(
    io: std.Io,
    path: []const u8,
    key: u64,
    signature: u64,
    content_signature: u64,
    file_count: usize,
    built: EvidenceFrontierBuild,
) void {
    ensureParentDir(io, path) catch return;
    var file = std.Io.Dir.cwd().createFile(io, path, .{ .truncate = true }) catch return;
    defer file.close(io);
    var buffer: [8192]u8 = undefined;
    var writer = file.writer(io, &buffer);
    writer.interface.print("{s}\nkey={x}\nsignature={x}\ncontent_signature={x}\nfile_count={}\npruned_files={}\npruned_bytes={}\nskipped_files={}\ncandidates={}\n--\n", .{
        EVIDENCE_FRONTIER_CACHE_MAGIC,
        key,
        signature,
        content_signature,
        file_count,
        built.pruned_files,
        built.pruned_bytes,
        built.skipped_files,
        built.candidates.len,
    }) catch return;
    for (built.candidates) |candidate| writer.interface.print("{s}\n", .{candidate.path}) catch return;
    writer.interface.flush() catch return;
    const build_path = evidenceFrontierBuildPath(std.heap.page_allocator, path) catch "";
    if (build_path.len != 0) {
        defer std.heap.page_allocator.free(build_path);
        std.Io.Dir.cwd().deleteFile(io, build_path) catch {};
    }
    writeEvidenceFrontierLive(io, path, key);
}

fn ensureParentDir(io: std.Io, path: []const u8) !void {
    if (std.fs.path.dirname(path)) |dir| {
        try std.Io.Dir.cwd().createDirPath(io, dir);
    }
}

fn parseCacheU64(line: []const u8, prefix: []const u8) u64 {
    const trimmed = std.mem.trimEnd(u8, line, "\r");
    if (!std.mem.startsWith(u8, trimmed, prefix)) return 0;
    return std.fmt.parseUnsigned(u64, trimmed[prefix.len..], 16) catch 0;
}

fn parseCacheUsize(line: []const u8, prefix: []const u8) usize {
    const trimmed = std.mem.trimEnd(u8, line, "\r");
    if (!std.mem.startsWith(u8, trimmed, prefix)) return 0;
    return std.fmt.parseUnsigned(usize, trimmed[prefix.len..], 10) catch 0;
}

fn parseCacheI96(line: []const u8, prefix: []const u8) ?i96 {
    const trimmed = std.mem.trimEnd(u8, line, "\r");
    if (!std.mem.startsWith(u8, trimmed, prefix)) return null;
    return std.fmt.parseInt(i96, trimmed[prefix.len..], 10) catch null;
}

fn hashU64(hasher: *std.hash.Wyhash, value: u64) void {
    var mutable = value;
    hasher.update(std.mem.asBytes(&mutable));
}

fn hashTimestamp(hasher: *std.hash.Wyhash, timestamp: std.Io.Timestamp) void {
    var nanos = timestamp.nanoseconds;
    hasher.update(std.mem.asBytes(&nanos));
}

/// Phase 1: Recursively walk a root path and collect all scannable file paths.
/// This is fast -- only readdir syscalls, no file content reads. Hidden files
/// are filtered here, and files_discovered/files_skipped are counted on the
/// main report (single-threaded, no contention).
fn discoverFiles(
    io: std.Io,
    allocator: std.mem.Allocator,
    path: []const u8,
    request: cli.SearchRequest,
    admission_engine: *path_admission.Engine,
    file_list: *FileList,
    report: *SearchReport,
) anyerror!void {
    // Try opening as a file first. If it's a directory, recurse.
    const file = std.Io.Dir.cwd().openFile(io, path, .{ .allow_directory = false }) catch |file_err| switch (file_err) {
        error.IsDir => {
            try discoverDirectory(io, allocator, path, request, admission_engine, file_list, report);
            return;
        },
        error.AccessDenied => {
            discoverDirectory(io, allocator, path, request, admission_engine, file_list, report) catch |dir_err| switch (dir_err) {
                error.AccessDenied, error.NotDir => {
                    recordReportAccessError(report, "discovery", "open_file", path, file_err);
                    report.files_skipped += 1;
                },
                else => return dir_err,
            };
            return;
        },
        else => return file_err,
    };
    file.close(io);
    report.files_discovered += 1;
    report.stats.admission.explicit_files_included += 1;
    const display_path = try discovered_files.normalizeDisplayPath(allocator, path);
    try file_list.append(allocator, .{ .path = display_path });
}

fn discoverDirectory(
    io: std.Io,
    allocator: std.mem.Allocator,
    path: []const u8,
    request: cli.SearchRequest,
    admission_engine: *path_admission.Engine,
    file_list: *FileList,
    report: *SearchReport,
) anyerror!void {
    const mark = admission_engine.checkpoint();
    defer admission_engine.restore(mark);

    const dir = try openDiscoveryDir(io, path, report) orelse return;
    defer dir.close(io);
    var iterator = dir.iterate();
    while (true) {
        const maybe_entry = iterator.next(io) catch |err| switch (err) {
            error.AccessDenied => {
                recordReportAccessError(report, "discovery", "iterate_dir", path, err);
                report.files_skipped += 1;
                return;
            },
            else => return err,
        };
        const entry = maybe_entry orelse break;
        if (!request.hidden and shouldSkipDefaultDiscoveryEntry(entry.name, entry.kind == .directory)) {
            report.files_skipped += 1;
            recordDiscoveryAdmissionSkip(io, report, path, entry.name, entry.kind == .file, "hidden");
            continue;
        }
        switch (entry.kind) {
            .file => {
                const child_path = try discovered_files.joinPathForward(allocator, path, entry.name);
                if (admission_engine.decide(child_path, false) == .ignore) {
                    report.files_skipped += 1;
                    recordDiscoveryAdmissionSkipPath(io, report, child_path, true, "ignored");
                    allocator.free(child_path);
                    continue;
                }
                report.files_discovered += 1;
                try file_list.append(allocator, .{ .path = child_path });
            },
            .directory => {
                var child_path_buffer: [DISCOVERY_PATH_STACK_BUFFER_LEN]u8 = undefined;
                const child_path = try joinedDiscoveryChildPath(allocator, path, entry.name, &child_path_buffer);
                if (admission_engine.decide(child_path.path, true) == .ignore) {
                    releaseJoinedDiscoveryChildPath(allocator, child_path);
                    report.files_skipped += 1;
                    recordDiscoveryAdmissionSkipPath(io, report, child_path.path, false, "ignored");
                    continue;
                }
                defer releaseJoinedDiscoveryChildPath(allocator, child_path);
                try discoverDirectory(io, allocator, child_path.path, request, admission_engine, file_list, report);
            },
            else => {},
        }
    }
}

fn openDiscoveryDir(io: std.Io, path: []const u8, report: *SearchReport) anyerror!?std.Io.Dir {
    return std.Io.Dir.cwd().openDir(io, path, .{ .iterate = true }) catch |err| switch (err) {
        error.AccessDenied => {
            recordReportAccessError(report, "discovery", "open_dir", path, err);
            report.files_skipped += 1;
            return null;
        },
        else => return err,
    };
}

const JoinedDiscoveryChildPath = struct {
    path: []const u8,
    owned: bool,
};

fn joinedDiscoveryChildPath(
    allocator: std.mem.Allocator,
    parent: []const u8,
    child: []const u8,
    path_buffer: []u8,
) !JoinedDiscoveryChildPath {
    if (discovered_files.joinPathForwardBounded(parent, child, path_buffer)) |path| {
        return .{ .path = path, .owned = false };
    }
    return .{ .path = try discovered_files.joinPathForward(allocator, parent, child), .owned = true };
}

fn persistJoinedDiscoveryChildPath(allocator: std.mem.Allocator, joined: JoinedDiscoveryChildPath) ![]const u8 {
    if (joined.owned) return joined.path;
    return allocator.dupe(u8, joined.path);
}

fn releaseJoinedDiscoveryChildPath(allocator: std.mem.Allocator, joined: JoinedDiscoveryChildPath) void {
    if (joined.owned) allocator.free(joined.path);
}

fn recordDiscoveryAdmissionSkip(
    io: std.Io,
    report: *SearchReport,
    parent: []const u8,
    name: []const u8,
    is_file: bool,
    reason: []const u8,
) void {
    var path_buf: [DISCOVERY_PATH_STACK_BUFFER_LEN]u8 = undefined;
    const path = discovered_files.joinPathForwardBounded(parent, name, &path_buf) orelse return recordAdmissionSkip(report, reason, 0);
    recordDiscoveryAdmissionSkipPath(io, report, path, is_file, reason);
}

fn recordDiscoveryAdmissionSkipPath(
    io: std.Io,
    report: *SearchReport,
    path: []const u8,
    is_file: bool,
    reason: []const u8,
) void {
    const bytes = if (report.capture_discovery_skip_bytes and is_file) skippedFileBytes(io, path) else 0;
    recordAdmissionSkip(report, reason, bytes);
}

fn recordAdmissionSkip(report: *SearchReport, reason: []const u8, bytes: usize) void {
    if (std.mem.eql(u8, reason, "hidden")) {
        report.stats.admission.hidden_entries_skipped += 1;
        report.stats.admission.hidden_file_bytes += bytes;
    } else if (std.mem.eql(u8, reason, "ignored")) {
        report.stats.admission.ignored_entries_skipped += 1;
        report.stats.admission.ignored_file_bytes += bytes;
    }
}

fn skippedFileBytes(io: std.Io, path: []const u8) usize {
    const file = std.Io.Dir.cwd().openFile(io, path, .{ .allow_directory = false }) catch return 0;
    defer file.close(io);
    return @intCast(file.length(io) catch return 0);
}

fn shouldUseParallelDiscovery(request: cli.SearchRequest, roots: PreparedRoots) bool {
    // Versioned output binds cursors to the discovered corpus. Parallel
    // top-level walks share the request arena across workers, so path
    // allocation can produce a different identity for the same tree.
    // Deterministic projections use the serial discovery owner; the search
    // lane keeps parallel discovery.
    if (request.stable_output) return false;
    if (request.max_hits != null and !request.stats_only) return false;
    const requested_threads = boundedRequestedThreads(request.threads, defaultParallelDiscoveryThreadBudget(request));
    if (requested_threads <= 1) return false;
    if (roots.count == 0) return false;
    for (roots.items[0..roots.count]) |root| {
        if (!root.is_directory) return false;
    }
    return true;
}

fn defaultParallelDiscoveryThreadBudget(request: cli.SearchRequest) usize {
    if (!request.stats_only and !request.stable_output) return 1;
    return resource_profile.threadLimit(availableThreads());
}

/// Centralizes explicit/default thread clamping so discovery cannot diverge
/// from scan and byte-shard enforcement.
fn boundedRequestedThreads(requested: ?usize, default: usize) usize {
    return resource_profile.clampThreads(requested orelse default, availableThreads());
}

fn rootsAllProtectedWindows(roots: PreparedRoots) bool {
    if (comptime builtin.os.tag != .windows) return false;
    if (roots.count == 0) return false;
    for (roots.items[0..roots.count]) |root| {
        if (!protected_paths.isWindowsPath(root.original)) return false;
    }
    return true;
}

fn discoverRootsParallelTopLevel(
    io: std.Io,
    allocator: std.mem.Allocator,
    roots: PreparedRoots,
    request: cli.SearchRequest,
    admission_engine: *path_admission.Engine,
    file_list: *FileList,
    report: *SearchReport,
) !bool {
    if (!shouldUseParallelDiscovery(request, roots)) return false;

    var top_dirs = try FileList.initWithCapacity(allocator, 64);
    for (roots.items[0..roots.count]) |root| {
        if (!request.no_ignore) {
            report.stats.admission.ignore_files_loaded += try admission_engine.loadDirectoryIgnoreFiles(io, root.original);
        }
        try discoverRootTopLevel(io, allocator, root.original, request, admission_engine, &top_dirs, file_list, report);
    }

    const top_dir_items = top_dirs.mutableItems();
    if (top_dir_items.len == 0) return true;

    const requested_threads = boundedRequestedThreads(request.threads, defaultParallelDiscoveryThreadBudget(request));
    const actual_threads = @min(@max(requested_threads, 1), top_dir_items.len);
    if (actual_threads <= 1 or top_dir_items.len < 2) {
        var disabled_admission = path_admission.Engine.init(allocator, false);
        for (top_dir_items) |entry| {
            const engine = if (request.no_ignore) &disabled_admission else admission_engine;
            try discoverDirectory(io, allocator, entry.path, request, engine, file_list, report);
        }
        return true;
    }

    const shards = try allocator.alloc(DiscoveryShardReport, actual_threads);
    for (shards) |*shard| {
        shard.* = .{ .file_list = try FileList.initWithCapacity(allocator, 8192) };
    }

    var next_dir: usize = 0;
    const worker_count = actual_threads - 1;
    const threads = try allocator.alloc(std.Thread, worker_count);
    for (0..worker_count) |i| {
        const shard_index = i + 1;
        threads[i] = try std.Thread.spawn(.{}, discoveryShardWorker, .{ io, allocator, &next_dir, top_dir_items, request, admission_engine, &shards[shard_index] });
    }
    discoveryShardWorker(io, allocator, &next_dir, top_dir_items, request, admission_engine, &shards[0]);
    for (threads) |thread| thread.join();

    for (shards) |*shard| {
        if (shard.had_error) return error.Unexpected;
        report.files_discovered += shard.files_discovered;
        report.files_skipped += shard.files_skipped;
        report.stats.access_errors.merge(shard.access_errors);
        for (shard.file_list.mutableItems()) |entry| {
            try file_list.append(allocator, entry);
        }
    }
    return true;
}

fn discoverRootTopLevel(
    io: std.Io,
    allocator: std.mem.Allocator,
    path: []const u8,
    request: cli.SearchRequest,
    admission_engine: *const path_admission.Engine,
    top_dirs: *FileList,
    file_list: *FileList,
    report: *SearchReport,
) !void {
    const dir = std.Io.Dir.cwd().openDir(io, path, .{ .iterate = true }) catch |err| switch (err) {
        error.AccessDenied => {
            recordReportAccessError(report, "discovery", "open_dir", path, err);
            report.files_skipped += 1;
            return;
        },
        else => return err,
    };
    defer dir.close(io);
    var iterator = dir.iterate();
    while (true) {
        const maybe_entry = iterator.next(io) catch |err| switch (err) {
            error.AccessDenied => {
                recordReportAccessError(report, "discovery", "iterate_dir", path, err);
                report.files_skipped += 1;
                return;
            },
            else => return err,
        };
        const entry = maybe_entry orelse break;
        if (!request.hidden and shouldSkipDefaultDiscoveryEntry(entry.name, entry.kind == .directory)) {
            report.files_skipped += 1;
            continue;
        }
        const child_path = try discovered_files.joinPathForward(allocator, path, entry.name);
        if (admission_engine.decide(child_path, entry.kind == .directory) == .ignore) {
            allocator.free(child_path);
            report.files_skipped += 1;
            continue;
        }
        switch (entry.kind) {
            .file => {
                report.files_discovered += 1;
                try file_list.append(allocator, .{ .path = child_path });
            },
            .directory => try top_dirs.append(allocator, .{ .path = child_path }),
            else => allocator.free(child_path),
        }
    }
}

fn discoveryShardWorker(
    io: std.Io,
    allocator: std.mem.Allocator,
    next_dir: *usize,
    dirs: []const DiscoveredFile,
    request: cli.SearchRequest,
    admission_engine: *const path_admission.Engine,
    shard: *DiscoveryShardReport,
) void {
    while (true) {
        const index = @atomicRmw(usize, next_dir, .Add, 1, .monotonic);
        if (index >= dirs.len) break;
        discoverDirectoryShard(io, allocator, dirs[index].path, request, admission_engine, shard) catch {
            shard.had_error = true;
            return;
        };
    }
}

fn discoverDirectoryShard(
    io: std.Io,
    allocator: std.mem.Allocator,
    path: []const u8,
    request: cli.SearchRequest,
    admission_engine: *const path_admission.Engine,
    shard: *DiscoveryShardReport,
) anyerror!void {
    const dir = std.Io.Dir.cwd().openDir(io, path, .{ .iterate = true }) catch |err| switch (err) {
        error.AccessDenied => {
            shard.access_errors.record("discovery", "open_dir", path, err);
            shard.files_skipped += 1;
            return;
        },
        else => return err,
    };
    defer dir.close(io);
    var iterator = dir.iterate();
    while (true) {
        const maybe_entry = iterator.next(io) catch |err| switch (err) {
            error.AccessDenied => {
                shard.access_errors.record("discovery", "iterate_dir", path, err);
                shard.files_skipped += 1;
                return;
            },
            else => return err,
        };
        const entry = maybe_entry orelse break;
        if (!request.hidden and shouldSkipDefaultDiscoveryEntry(entry.name, entry.kind == .directory)) {
            shard.files_skipped += 1;
            continue;
        }
        switch (entry.kind) {
            .file => {
                const child_path = try discovered_files.joinPathForward(allocator, path, entry.name);
                if (admission_engine.decide(child_path, false) == .ignore) {
                    allocator.free(child_path);
                    shard.files_skipped += 1;
                    continue;
                }
                shard.files_discovered += 1;
                try shard.file_list.append(allocator, .{ .path = child_path });
            },
            .directory => {
                var child_path_buffer: [DISCOVERY_PATH_STACK_BUFFER_LEN]u8 = undefined;
                const child_path = try joinedDiscoveryChildPath(allocator, path, entry.name, &child_path_buffer);
                if (admission_engine.decide(child_path.path, true) == .ignore) {
                    releaseJoinedDiscoveryChildPath(allocator, child_path);
                    shard.files_skipped += 1;
                    continue;
                }
                defer releaseJoinedDiscoveryChildPath(allocator, child_path);
                try discoverDirectoryShard(io, allocator, child_path.path, request, admission_engine, shard);
            },
            else => {},
        }
    }
}

fn recordReportAccessError(report: *SearchReport, phase: []const u8, operation: []const u8, path: []const u8, err: anyerror) void {
    report.stats.access_errors.record(phase, operation, path, err);
}

fn recordReportScanOpenMs(report: *SearchReport, ms: f64) void {
    report.scan_work_ms_total += ms;
    report.scan_open_ms_total += ms;
}

fn recordReportScanFileMs(report: *SearchReport, ms: f64) void {
    report.scan_work_ms_total += ms;
}

fn recordReportScanFileBufferedMs(report: *SearchReport, ms: f64) void {
    recordReportScanFileMs(report, ms);
    report.scan_file_buffered_ms_total += ms;
}

fn recordShardScanOpenMs(shard: *ShardReport, ms: f64) void {
    shard.scan_work_ms_total += ms;
    shard.scan_open_ms_total += ms;
}

fn recordShardScanFileMs(shard: *ShardReport, ms: f64) void {
    shard.scan_work_ms_total += ms;
}

fn recordShardScanFileMmapMs(shard: *ShardReport, ms: f64) void {
    recordShardScanFileMs(shard, ms);
    shard.scan_file_mmap_ms_total += ms;
}

fn recordShardScanFileBufferedMs(shard: *ShardReport, ms: f64) void {
    recordShardScanFileMs(shard, ms);
    shard.scan_file_buffered_ms_total += ms;
}

fn linuxDominantAttributionEnabled() bool {
    return truthyEnvEnabled(LINUX_DOMINANT_ATTRIBUTION_ENV);
}

fn discoverySkipBytesEnabled() bool {
    return truthyEnvEnabled(DISCOVERY_SKIP_BYTES_ENV);
}

fn truthyEnvEnabled(name: [:0]const u8) bool {
    const value_ptr = std.c.getenv(name) orelse return false;
    const value = std.mem.span(value_ptr);
    if (value.len == 0) return false;
    if (std.mem.eql(u8, value, "0")) return false;
    if (std.ascii.eqlIgnoreCase(value, "false")) return false;
    if (std.ascii.eqlIgnoreCase(value, "off")) return false;
    if (std.ascii.eqlIgnoreCase(value, "no")) return false;
    return true;
}

fn isRecoverableScanAccessError(err: anyerror) bool {
    return switch (err) {
        error.AccessDenied,
        error.FileBusy,
        error.FileLocksNotSupported,
        error.SharingViolation,
        error.FileNotFound,
        error.ProcessFdQuotaExceeded,
        error.SystemFdQuotaExceeded,
        => true,
        else => false,
    };
}

fn shouldSkipProtectedBinaryContainer(request: cli.SearchRequest, path: []const u8) bool {
    return protected_paths.shouldSkipBinaryContainer(.{ .stats_only = request.stats_only }, path);
}

/// Thread-local shard report. Each worker thread accumulates results here
/// without any synchronization. Merged into the main SearchReport after
/// all threads join.
const ShardReport = struct {
    bytes_scanned: usize,
    files_scanned: usize,
    files_skipped: usize,
    matches_found: usize,
    matches_after_cursor: usize,
    scan_work_ms_total: f64,
    scan_open_ms_total: f64,
    scan_file_ms_total: f64,
    scan_file_mmap_ms_total: f64 = 0,
    scan_file_buffered_ms_total: f64 = 0,
    scan_input_policy: scan_input_policy.Mode = .auto,
    capture_scan_open_timing: bool,
    capture_linux_dominant_attribution: bool,
    acceleration_bailouts: usize,
    fast_count_density_stats: core_stats.FastCountDensityStats,
    regex_decomposition_stats: core_stats.RegexDecompositionStats,
    trigram_stats: core_stats.TrigramAccelerationStats,
    byte_shard_stats: core_stats.ByteShardKernelStats,
    linux_dominant_file_stats: core_stats.LinuxDominantFileStats,
    admission_stats: core_stats.AdmissionStats,
    slowest_path: []const u8,
    slowest_bytes: usize,
    slowest_ms: f64,
    hits: [MAX_RETAINED_HITS]SearchHit,
    hit_count: usize,
    truncated: bool,
    had_error: bool,
    evidence_capture: bool,
    evidence_allocator: ?std.mem.Allocator,
    evidence_candidates: std.ArrayList(DiscoveredFile),
    evidence_pruned_files: usize,
    evidence_pruned_bytes: usize,
    evidence_skipped_files: usize,
    evidence_had_error: bool,
    access_errors: core_stats.AccessErrorStats,
    scan_buffer: []u8,
    scope_tracker: ScopeTracker = .{},
    last_record_scope_line: usize = 0,

    const empty: ShardReport = .{
        .bytes_scanned = 0,
        .files_scanned = 0,
        .files_skipped = 0,
        .matches_found = 0,
        .matches_after_cursor = 0,
        .scan_work_ms_total = 0,
        .scan_open_ms_total = 0,
        .scan_file_ms_total = 0,
        .scan_file_mmap_ms_total = 0,
        .scan_file_buffered_ms_total = 0,
        .capture_scan_open_timing = false,
        .capture_linux_dominant_attribution = false,
        .acceleration_bailouts = 0,
        .fast_count_density_stats = .{},
        .regex_decomposition_stats = .{},
        .trigram_stats = .{},
        .byte_shard_stats = .{},
        .linux_dominant_file_stats = .{},
        .admission_stats = .{},
        .slowest_path = "",
        .slowest_bytes = 0,
        .slowest_ms = 0,
        .hits = undefined,
        .hit_count = 0,
        .truncated = false,
        .had_error = false,
        .evidence_capture = false,
        .evidence_allocator = null,
        .evidence_candidates = .empty,
        .evidence_pruned_files = 0,
        .evidence_pruned_bytes = 0,
        .evidence_skipped_files = 0,
        .evidence_had_error = false,
        .access_errors = .{},
        .scan_buffer = &.{},
        .scan_input_policy = .auto,
    };
};

fn recordShardAccessError(shard: *ShardReport, phase: []const u8, operation: []const u8, path: []const u8, err: anyerror) void {
    shard.access_errors.record(phase, operation, path, err);
}

fn recordEvidenceCandidate(shard: *ShardReport, display_path: []const u8) void {
    if (!shard.evidence_capture) return;
    const allocator = shard.evidence_allocator orelse {
        shard.evidence_had_error = true;
        return;
    };
    shard.evidence_candidates.append(allocator, .{ .path = display_path }) catch {
        shard.evidence_had_error = true;
    };
}

fn recordEvidencePruned(shard: *ShardReport, bytes: usize) void {
    if (!shard.evidence_capture) return;
    shard.evidence_pruned_files += 1;
    shard.evidence_pruned_bytes += bytes;
}

fn recordEvidenceSkipped(shard: *ShardReport) void {
    if (!shard.evidence_capture) return;
    shard.evidence_skipped_files += 1;
}

fn recordLinuxDominantFileScan(shard: *ShardReport, display_path: []const u8, file_bytes: usize) bool {
    if (!shard.capture_linux_dominant_attribution) return false;
    const min_bytes = shard.linux_dominant_file_stats.min_bytes;
    if (file_bytes < min_bytes) return false;
    if (!isLinuxDominantFilePath(display_path)) return false;
    shard.linux_dominant_file_stats.targeted_files_scanned += 1;
    shard.linux_dominant_file_stats.targeted_bytes_scanned += file_bytes;
    shard.linux_dominant_file_stats.eligible_files += 1;
    return true;
}

fn recordLinuxDominantFileActivation(shard: *ShardReport) void {
    if (!shard.capture_linux_dominant_attribution) return;
    shard.linux_dominant_file_stats.activated_files += 1;
    const files_profiled = shard.byte_shard_stats.files_profiled;
    if (files_profiled > 0) {
        const ranges = shard.byte_shard_stats.range_calls / files_profiled;
        shard.linux_dominant_file_stats.max_shard_threads = @max(shard.linux_dominant_file_stats.max_shard_threads, ranges);
        shard.linux_dominant_file_stats.max_range_count = @max(shard.linux_dominant_file_stats.max_range_count, ranges);
        if (shard.byte_shard_stats.range_calls > 0) {
            const chunk = shard.byte_shard_stats.logical_range_bytes / shard.byte_shard_stats.range_calls;
            shard.linux_dominant_file_stats.max_chunk_bytes = @max(shard.linux_dominant_file_stats.max_chunk_bytes, chunk);
        }
    }
}

fn isLinuxDominantFilePath(path: []const u8) bool {
    var has_amd = false;
    var has_asic_reg = false;
    var start: usize = 0;
    for (path, 0..) |byte, index| {
        if (byte == '/' or byte == '\\') {
            const segment = path[start..index];
            if (std.ascii.eqlIgnoreCase(segment, "amd")) has_amd = true;
            if (std.ascii.eqlIgnoreCase(segment, "asic_reg")) has_asic_reg = true;
            start = index + 1;
        }
    }
    const tail = path[start..];
    if (std.ascii.eqlIgnoreCase(tail, "amd")) has_amd = true;
    if (std.ascii.eqlIgnoreCase(tail, "asic_reg")) has_asic_reg = true;
    return has_amd and has_asic_reg;
}

/// Scan a single discovered file -- used in the serial path and by
/// parallel workers. Opens the file, checks for binary content, and
/// runs the line-by-line matching loop.
fn scanDiscoveredFile(
    io: std.Io,
    allocator: std.mem.Allocator,
    display_path: []const u8,
    request: cli.SearchRequest,
    plan: expr.ExpressionPlan,
    trigram_admission: trigram.Admission,
    trigram_program: *const TrigramAdmissionProgram,
    report: *SearchReport,
) anyerror!void {
    if (report.scan_buffer.len == 0) report.scan_buffer = try allocator.alloc(u8, SCAN_READ_BUFFER_SIZE);
    if (shouldSkipProtectedBinaryContainer(request, display_path)) {
        report.files_skipped += 1;
        report.stats.admission.protected_entries_skipped += 1;
        return;
    }
    const file_started = std.Io.Timestamp.now(io, .awake);
    // Open via NT object path to bypass RtlGetFullPathName_U PEB lock contention.
    const file = nt_open.openFile(io, display_path) catch |err| switch (err) {
        error.IsDir => {
            if (report.capture_scan_open_timing) {
                recordReportScanOpenMs(report, elapsedMs(io, file_started));
            }
            report.files_skipped += 1;
            recordReportAccessError(report, "scan", "open_file", display_path, err);
            return;
        },
        else => {
            if (isRecoverableScanAccessError(err)) {
                if (report.capture_scan_open_timing) {
                    recordReportScanOpenMs(report, elapsedMs(io, file_started));
                }
                report.files_skipped += 1;
                recordReportAccessError(report, "scan", "open_file", display_path, err);
                return;
            }
            return err;
        },
    };
    if (report.capture_scan_open_timing) {
        recordReportScanOpenMs(report, elapsedMs(io, file_started));
    }
    const scan_started = if (report.capture_scan_open_timing) std.Io.Timestamp.now(io, .awake) else file_started;
    defer file.close(io);
    scanOpenFile(io, allocator, file, display_path, request, plan, trigram_admission, trigram_program, report, scan_started) catch |err| switch (err) {
        else => {
            if (!isRecoverableScanAccessError(err)) return err;
            report.files_skipped += 1;
            recordReportAccessError(report, "scan", "read_file", display_path, err);
            return;
        },
    };
}

/// Scan a single file into a ShardReport (thread-local, no sync needed).
fn scanFileIntoShard(
    io: std.Io,
    allocator: std.mem.Allocator,
    display_path: []const u8,
    request: cli.SearchRequest,
    plan: expr.ExpressionPlan,
    trigram_admission: trigram.Admission,
    trigram_program: *const TrigramAdmissionProgram,
    shard: *ShardReport,
) void {
    if (shouldSkipProtectedBinaryContainer(request, display_path)) {
        shard.files_skipped += 1;
        shard.admission_stats.protected_entries_skipped += 1;
        recordEvidenceSkipped(shard);
        return;
    }
    const file_started = std.Io.Timestamp.now(io, .awake);
    const file = nt_open.openFile(io, display_path) catch |err| {
        shard.files_skipped += 1;
        recordShardAccessError(shard, "scan", "open_file", display_path, err);
        recordEvidenceSkipped(shard);
        return;
    };
    defer file.close(io);
    scanOpenFileIntoShard(io, allocator, file, display_path, request, plan, trigram_admission, trigram_program, shard, file_started) catch |err| {
        if (isRecoverableScanAccessError(err)) {
            shard.files_skipped += 1;
            recordShardAccessError(shard, "scan", "read_file", display_path, err);
            recordEvidenceSkipped(shard);
        } else {
            shard.had_error = true;
        }
    };
}

/// Memory-mapped file scan -- zero-copy, no stack buffer, no carry buffer.
/// Maps the entire file via NtCreateSection/NtMapViewOfSection (Windows) or
/// mmap (POSIX). The OS page cache provides the data directly; no read()
/// syscalls, no memcpy, no multi-chunk loop.
///
/// Returns error on mmap failure (resource limits, non-regular file), allowing
/// the caller to fall back to chunked reads.
fn scanFileIntoShardTimed(
    io: std.Io,
    allocator: std.mem.Allocator,
    display_path: []const u8,
    request: cli.SearchRequest,
    plan: expr.ExpressionPlan,
    trigram_admission: trigram.Admission,
    trigram_program: *const TrigramAdmissionProgram,
    shard: *ShardReport,
) void {
    if (shouldSkipProtectedBinaryContainer(request, display_path)) {
        shard.files_skipped += 1;
        shard.admission_stats.protected_entries_skipped += 1;
        recordEvidenceSkipped(shard);
        return;
    }
    const file_started = std.Io.Timestamp.now(io, .awake);
    const file = nt_open.openFile(io, display_path) catch |err| {
        recordShardScanOpenMs(shard, elapsedMs(io, file_started));
        shard.files_skipped += 1;
        recordShardAccessError(shard, "scan", "open_file", display_path, err);
        recordEvidenceSkipped(shard);
        return;
    };
    recordShardScanOpenMs(shard, elapsedMs(io, file_started));
    const scan_started = std.Io.Timestamp.now(io, .awake);
    defer file.close(io);
    scanOpenFileIntoShard(io, allocator, file, display_path, request, plan, trigram_admission, trigram_program, shard, scan_started) catch |err| {
        if (isRecoverableScanAccessError(err)) {
            shard.files_skipped += 1;
            recordShardAccessError(shard, "scan", "read_file", display_path, err);
            recordEvidenceSkipped(shard);
        } else {
            shard.had_error = true;
        }
    };
}

fn scanFileMmap(
    comptime mono: ?MonoSpec,
    io: std.Io,
    allocator: std.mem.Allocator,
    file: std.Io.File,
    display_path: []const u8,
    request: cli.SearchRequest,
    plan: expr.ExpressionPlan,
    trigram_admission: trigram.Admission,
    trigram_program: *const TrigramAdmissionProgram,
    shard: *ShardReport,
    file_started: std.Io.Timestamp,
) !void {
    const raw_len = try file.length(io);
    const file_bytes: usize = @intCast(raw_len);

    if (file_bytes == 0) {
        shard.files_scanned += 1;
        recordLineIntoShardImpl(mono, allocator, display_path, "", 1, request, plan, shard, false);
        recordEvidenceCandidate(shard, display_path);
        const file_ms = elapsedMs(io, file_started);
        recordShardScanFileMmapMs(shard, file_ms);
        if (file_ms >= shard.slowest_ms) shard.slowest_ms = file_ms;
        return;
    }

    var mm = try std.Io.File.MemoryMap.create(io, file, .{
        .len = file_bytes,
        .protection = .{ .read = true },
        .offset = 0,
    });
    defer mm.destroy(io);

    const data = mm.memory[0..file_bytes];

    // Binary sniff: first 1024 bytes for null bytes.
    if (simd.indexOfByte(data[0..@min(1024, data.len)], 0) != null) {
        shard.files_skipped += 1;
        shard.admission_stats.binary_entries_skipped += 1;
        shard.admission_stats.binary_file_bytes += file_bytes;
        recordEvidenceSkipped(shard);
        return;
    }

    shard.files_scanned += 1;
    shard.bytes_scanned += file_bytes;
    shard.scope_tracker = .{};
    shard.last_record_scope_line = 0;
    const linux_dominant_target = recordLinuxDominantFileScan(shard, display_path, file_bytes);
    if (file_bytes >= shard.slowest_bytes) {
        shard.slowest_path = display_path;
        shard.slowest_bytes = file_bytes;
    }

    const mmap_admission_casefold_required =
        shouldAttemptWholeFileAdmission(true, request.case_insensitive, trigram_program) and
        trigram_program.needsCasefold();
    if (!mmap_admission_casefold_required and
        shouldAttemptWholeFileAdmission(true, request.case_insensitive, trigram_program) and
        trigram_program.fileAdmissionMiss(data))
    {
        recordEvidencePruned(shard, file_bytes);
        const file_ms = elapsedMs(io, file_started);
        recordShardScanFileMmapMs(shard, file_ms);
        if (file_ms >= shard.slowest_ms) shard.slowest_ms = file_ms;
        return;
    }

    if (request.stats_only and shouldRunByteShardBeforeAdmission(plan)) {
        if (tryByteShardFastCount(io, allocator, request, plan, data, &shard.byte_shard_stats, &shard.fast_count_density_stats, &shard.regex_decomposition_stats, &shard.acceleration_bailouts)) |count| {
            if (linux_dominant_target) recordLinuxDominantFileActivation(shard);
            shard.matches_found += count;
            recordEvidenceCandidate(shard, display_path);
            const file_ms = elapsedMs(io, file_started);
            recordShardScanFileMmapMs(shard, file_ms);
            if (file_ms >= shard.slowest_ms) shard.slowest_ms = file_ms;
            return;
        }
    }

    const literal_admission_satisfied =
        shouldAttemptWholeFileAdmission(true, request.case_insensitive, trigram_program) and
        mono != null and
        search_admission.predicateAdmissionGroupRuntime(plan.predicates[0]) != null;

    // Trigram prune -- entire file available as one contiguous buffer.
    if (!shouldSkipTrigramAfterLiteralAdmission(plan, literal_admission_satisfied) and
        shouldAttemptTrigramPrune(file_bytes, true, trigram_admission, request.case_insensitive) and
        tryTrigramPruneFile(data, trigram_program, &shard.trigram_stats))
    {
        recordEvidencePruned(shard, file_bytes);
        const file_ms = elapsedMs(io, file_started);
        recordShardScanFileMmapMs(shard, file_ms);
        if (file_ms >= shard.slowest_ms) shard.slowest_ms = file_ms;
        return;
    }

    // Whole-buffer fast count -- always applicable (entire file is one buffer).
    // For casefold-literal patterns in stats_only mode, this handles the
    // case-insensitive counting without buffer modification.
    if (request.stats_only) {
        if (tryByteShardFastCount(io, allocator, request, plan, data, &shard.byte_shard_stats, &shard.fast_count_density_stats, &shard.regex_decomposition_stats, &shard.acceleration_bailouts)) |count| {
            if (linux_dominant_target) recordLinuxDominantFileActivation(shard);
            shard.matches_found += count;
            recordEvidenceCandidate(shard, display_path);
            const file_ms = elapsedMs(io, file_started);
            recordShardScanFileMmapMs(shard, file_ms);
            if (file_ms >= shard.slowest_ms) shard.slowest_ms = file_ms;
            if (request.max_hits) |max_hits| {
                if (shard.matches_found >= max_hits) shard.truncated = true;
            }
            return;
        }
        if (regexDecompositionFastCount(data, plan, request.case_insensitive, &shard.regex_decomposition_stats, &shard.acceleration_bailouts)) |count| {
            shard.matches_found += count;
            recordEvidenceCandidate(shard, display_path);
            const file_ms = elapsedMs(io, file_started);
            recordShardScanFileMmapMs(shard, file_ms);
            if (file_ms >= shard.slowest_ms) shard.slowest_ms = file_ms;
            if (request.max_hits) |max_hits| {
                if (shard.matches_found >= max_hits) shard.truncated = true;
            }
            return;
        }
        if (wholeBufferFastCount(data, plan, request.case_insensitive, false)) |count| {
            shard.matches_found += count;
            if (mono) |m| {
                if (m.kind == .regex and m.strategy == .regex_literal_alternates) {
                    shard.fast_count_density_stats.alternate_full_scan_calls += 1;
                    shard.fast_count_density_stats.alternate_full_scan_bytes += data.len;
                    shard.fast_count_density_stats.alternate_full_scan_matches += count;
                    shard.fast_count_density_stats.alternate_matches += count;
                }
            }
            recordEvidenceCandidate(shard, display_path);
            const file_ms = elapsedMs(io, file_started);
            recordShardScanFileMmapMs(shard, file_ms);
            if (file_ms >= shard.slowest_ms) shard.slowest_ms = file_ms;
            if (request.max_hits) |max_hits| {
                if (shard.matches_found >= max_hits) shard.truncated = true;
            }
            return;
        }
    }

    // Per-line processing on mapped memory -- no carry buffer, no chunk boundaries.
    var line_number: usize = 1;
    var pos: usize = 0;
    while (pos < data.len) {
        if (simd.indexOfByte(data[pos..], '\n')) |nl| {
            const line_end = pos + nl;
            recordLineIntoShardImpl(mono, allocator, display_path, data[pos..line_end], line_number, request, plan, shard, false);
            if (shard.truncated) break;
            line_number += 1;
            pos = line_end + 1;
        } else {
            // Last line without trailing newline.
            recordLineIntoShardImpl(mono, allocator, display_path, data[pos..], line_number, request, plan, shard, false);
            break;
        }
    }
    // Trailing newline produces an empty final line.
    if (!shard.truncated and data.len > 0 and data[data.len - 1] == '\n') {
        recordLineIntoShardImpl(mono, allocator, display_path, "", line_number, request, plan, shard, false);
    }

    recordEvidenceCandidate(shard, display_path);
    const file_ms = elapsedMs(io, file_started);
    recordShardScanFileMmapMs(shard, file_ms);
    if (file_ms >= shard.slowest_ms) shard.slowest_ms = file_ms;
}

fn trySerialMmapFastPath(
    io: std.Io,
    allocator: std.mem.Allocator,
    file: std.Io.File,
    display_path: []const u8,
    request: cli.SearchRequest,
    plan: expr.ExpressionPlan,
    trigram_admission: trigram.Admission,
    trigram_program: *const TrigramAdmissionProgram,
    report: *SearchReport,
    file_started: std.Io.Timestamp,
) bool {
    if (!request.stats_only) return false;
    if (!plan.usesSingleLiteralCounter() and
        !planUsesRegexDecompositionFastCount(plan, request.case_insensitive) and
        !planUsesLiteralAlternatesFastCount(plan, request.case_insensitive)) return false;

    var shard = ShardReport.empty;
    shard.capture_scan_open_timing = report.capture_scan_open_timing;
    shard.capture_linux_dominant_attribution = report.capture_linux_dominant_attribution;
    shard.scan_input_policy = report.scan_input_policy;
    scanFileMmap(null, io, allocator, file, display_path, request, plan, trigram_admission, trigram_program, &shard, file_started) catch return false;
    var shards = [_]ShardReport{shard};
    mergeShardsIntoReport(shards[0..], request, report);
    return true;
}

fn planUsesRegexDecompositionFastCount(plan: expr.ExpressionPlan, case_insensitive: bool) bool {
    if (case_insensitive or plan.predicate_count != 1) return false;
    const predicate = plan.predicates[0];
    return predicate.kind == .regex and byte_shard.regexDecompositionNeedle(predicate.value) != null;
}

fn writeEscapedWarmQueryField(writer: anytype, value: []const u8) !void {
    for (value) |byte| {
        switch (byte) {
            '\\' => try writer.writeAll("\\\\"),
            '\t' => try writer.writeAll("\\t"),
            '\n' => try writer.writeAll("\\n"),
            '\r' => try writer.writeAll("\\r"),
            else => try writer.writeByte(byte),
        }
    }
}

fn unescapeWarmQueryField(allocator: std.mem.Allocator, value: []const u8) ![]const u8 {
    var out = try std.ArrayList(u8).initCapacity(allocator, value.len);
    errdefer out.deinit(allocator);
    var index: usize = 0;
    while (index < value.len) : (index += 1) {
        if (value[index] != '\\') {
            try out.append(allocator, value[index]);
            continue;
        }
        index += 1;
        if (index >= value.len) return error.InvalidWarmQueryEscape;
        const decoded: u8 = switch (value[index]) {
            '\\' => '\\',
            't' => '\t',
            'n' => '\n',
            'r' => '\r',
            else => return error.InvalidWarmQueryEscape,
        };
        try out.append(allocator, decoded);
    }
    return out.toOwnedSlice(allocator);
}

fn planUsesLiteralAlternatesFastCount(plan: expr.ExpressionPlan, case_insensitive: bool) bool {
    _ = case_insensitive;
    if (plan.predicate_count != 1) return false;
    const predicate = plan.predicates[0];
    return predicate.kind == .regex and
        predicate.strategy == .regex_literal_alternates and
        literal_alternates.parse(expr.literalAlternatesBody(predicate.value)) != null;
}

const WordBoundaryRangeCount = struct {
    matches: usize = 0,
    verified_candidates: usize = 0,
    rejected_candidates: usize = 0,
};

const RegexDecompositionRangeCount = struct {
    matches: usize = 0,
    candidate_lines_checked: usize = 0,
    duplicate_candidate_hits_skipped: usize = 0,
    candidate_lines_matched: usize = 0,
    bailed_out: bool = false,
};

const LiteralAlternatesRangeCount = literal_alternates.RangeCount;
const ByteShardPlan = byte_shard.Plan;

const ByteShardJob = struct {
    io: std.Io,
    data: []const u8,
    plan: ByteShardPlan,
    logical_start: usize,
    logical_end: usize,
    widened_start: usize,
    widened_end: usize,
    line_aligned: bool = false,
    matches: usize = 0,
    boundary_verified_candidates: usize = 0,
    boundary_rejected_candidates: usize = 0,
    regex_candidate_lines_checked: usize = 0,
    regex_duplicate_candidate_hits_skipped: usize = 0,
    regex_candidate_lines_matched: usize = 0,
    regex_bailed_out: bool = false,
    alternate_used_pcre: bool = false,
    alternate_used_teddy: bool = false,
    elapsed_ns: u64 = 0,
};

fn tryByteShardFastCount(
    io: std.Io,
    allocator: std.mem.Allocator,
    request: cli.SearchRequest,
    plan: expr.ExpressionPlan,
    data: []const u8,
    stats: *core_stats.ByteShardKernelStats,
    density_stats: *core_stats.FastCountDensityStats,
    regex_stats: *core_stats.RegexDecompositionStats,
    acceleration_bailouts: *usize,
) ?usize {
    if (!request.stats_only) return null;
    const shard_plan = byte_shard.plan(plan) orelse return null;
    if (request.case_insensitive and !shard_plan.case_insensitive) return null;
    if (shard_plan.needle.len < 2 or shard_plan.needle.len > data.len) return null;
    const min_file_bytes: usize = switch (shard_plan.strategy) {
        .word_boundary_line => BYTE_SHARD_WORD_BOUNDARY_MIN_FILE_BYTES,
        else => BYTE_SHARD_MIN_FILE_BYTES,
    };
    if (data.len < min_file_bytes) return null;

    const requested_threads = resource_profile.clampThreads(
        request.threads orelse defaultByteShardThreadBudget(availableThreads()),
        availableThreads(),
    );
    const max_threads = @max(@as(usize, 1), requested_threads);
    const min_range_bytes: usize = switch (shard_plan.strategy) {
        .word_boundary_line => BYTE_SHARD_WORD_BOUNDARY_MIN_RANGE_BYTES,
        else => BYTE_SHARD_MIN_RANGE_BYTES,
    };
    const ranges_by_size = (data.len + min_range_bytes - 1) / min_range_bytes;
    const range_count = @min(max_threads, ranges_by_size);
    if (range_count < 2) return null;

    const logical_chunk = (data.len + range_count - 1) / range_count;
    var jobs = allocator.alloc(ByteShardJob, range_count) catch return null;
    defer allocator.free(jobs);

    for (jobs, 0..) |*job, index| {
        const logical_start = @min(index * logical_chunk, data.len);
        const logical_end = @min(logical_start + logical_chunk, data.len);
        const range = byte_shard.rangeFor(data, shard_plan, logical_start, logical_end, index, range_count) orelse return null;
        job.* = .{
            .io = io,
            .data = data,
            .plan = shard_plan,
            .logical_start = range.logical_start,
            .logical_end = range.logical_end,
            .widened_start = range.widened_start,
            .widened_end = range.widened_end,
            .line_aligned = range.line_aligned,
        };
    }

    const worker_count = range_count - 1;
    var threads = allocator.alloc(std.Thread, worker_count) catch return null;
    defer allocator.free(threads);
    var spawned: usize = 0;
    while (spawned < worker_count) : (spawned += 1) {
        const job_index = spawned + 1;
        threads[spawned] = std.Thread.spawn(.{ .stack_size = 64 * 1024 }, byteShardWorker, .{&jobs[job_index]}) catch {
            for (threads[0..spawned]) |thread| thread.join();
            return null;
        };
    }

    byteShardWorker(&jobs[0]);
    for (threads[0..spawned]) |thread| thread.join();

    var total: usize = 0;
    var logical_bytes: usize = 0;
    var widened_bytes: usize = 0;
    var line_aligned_ranges: usize = 0;
    var boundary_verified_candidates: usize = 0;
    var boundary_rejected_candidates: usize = 0;
    var regex_candidate_lines_checked: usize = 0;
    var regex_duplicate_candidate_hits_skipped: usize = 0;
    var regex_candidate_lines_matched: usize = 0;
    var alternate_pcre_range_calls: usize = 0;
    var alternate_pcre_range_bytes: usize = 0;
    var alternate_teddy_range_calls: usize = 0;
    var alternate_teddy_range_bytes: usize = 0;
    var alternate_compiled_range_calls: usize = 0;
    var alternate_compiled_range_bytes: usize = 0;
    var range_elapsed_total: u64 = 0;
    var max_range_elapsed: u64 = 0;
    for (jobs) |job| {
        if (job.regex_bailed_out) {
            if (shard_plan.strategy == .regex_decomposition_line) {
                regex_stats.bailout_files += 1;
                acceleration_bailouts.* += 1;
            }
            return null;
        }
        total += job.matches;
        logical_bytes += job.logical_end - job.logical_start;
        widened_bytes += job.widened_end - job.widened_start;
        if (job.line_aligned) line_aligned_ranges += 1;
        boundary_verified_candidates += job.boundary_verified_candidates;
        boundary_rejected_candidates += job.boundary_rejected_candidates;
        regex_candidate_lines_checked += job.regex_candidate_lines_checked;
        regex_duplicate_candidate_hits_skipped += job.regex_duplicate_candidate_hits_skipped;
        regex_candidate_lines_matched += job.regex_candidate_lines_matched;
        if (shard_plan.strategy == .literal_alternates_line) {
            const range_bytes = job.logical_end - job.logical_start;
            if (job.alternate_used_pcre) {
                alternate_pcre_range_calls += 1;
                alternate_pcre_range_bytes += range_bytes;
            } else if (job.alternate_used_teddy) {
                alternate_teddy_range_calls += 1;
                alternate_teddy_range_bytes += range_bytes;
            } else {
                alternate_compiled_range_calls += 1;
                alternate_compiled_range_bytes += range_bytes;
            }
        }
        range_elapsed_total += job.elapsed_ns;
        max_range_elapsed = @max(max_range_elapsed, job.elapsed_ns);
    }
    stats.enabled = true;
    stats.strategy = shard_plan.strategy.text();
    stats.files_profiled += 1;
    stats.range_calls += range_count;
    stats.line_aligned_ranges += line_aligned_ranges;
    stats.logical_range_bytes += logical_bytes;
    stats.widened_range_bytes += widened_bytes;
    stats.overlap_bytes += widened_bytes - logical_bytes;
    stats.boundary_verified_candidates += boundary_verified_candidates;
    stats.boundary_rejected_candidates += boundary_rejected_candidates;
    stats.range_elapsed_ns_total += range_elapsed_total;
    stats.max_range_elapsed_ns = @max(stats.max_range_elapsed_ns, max_range_elapsed);
    stats.matches += total;
    if (shard_plan.strategy == .literal_alternates_line) {
        density_stats.alternate_range_calls += 1;
        density_stats.alternate_range_bytes += data.len;
        density_stats.alternate_matches += total;
        density_stats.alternate_pcre_range_calls += alternate_pcre_range_calls;
        density_stats.alternate_pcre_range_bytes += alternate_pcre_range_bytes;
        density_stats.alternate_teddy_range_calls += alternate_teddy_range_calls;
        density_stats.alternate_teddy_range_bytes += alternate_teddy_range_bytes;
        density_stats.alternate_compiled_range_calls += alternate_compiled_range_calls;
        density_stats.alternate_compiled_range_bytes += alternate_compiled_range_bytes;
    }
    if (shard_plan.strategy == .regex_decomposition_line) {
        regex_stats.eligible_files += 1;
        regex_stats.counted_files += 1;
        regex_stats.candidate_lines_checked += regex_candidate_lines_checked;
        regex_stats.duplicate_candidate_hits_skipped += regex_duplicate_candidate_hits_skipped;
        regex_stats.candidate_lines_matched += regex_candidate_lines_matched;
        stats.boundary_verified_candidates += regex_candidate_lines_checked;
        stats.boundary_rejected_candidates += regex_duplicate_candidate_hits_skipped;
    }
    return total;
}

fn defaultByteShardThreadBudget(available: usize) usize {
    return resource_profile.clampThreads(BYTE_SHARD_DEFAULT_MAX_RANGES, available);
}

fn byteShardWorker(job: *ByteShardJob) void {
    const started = std.Io.Timestamp.now(job.io, .awake);
    switch (job.plan.strategy) {
        .literal_occurrence => {
            job.matches = countLiteralLogicalRange(job.data, job.plan.needle, job.logical_start, job.logical_end, job.widened_start, job.widened_end);
        },
        .literal_alternates_line => {
            const counted = countLiteralAlternatesLogicalLinesRange(job.data, job.plan.pattern, job.plan.case_insensitive, job.logical_start, job.logical_end);
            job.matches = counted.matches;
            job.regex_bailed_out = counted.bailed_out;
            job.alternate_used_pcre = counted.used_pcre;
            job.alternate_used_teddy = counted.used_teddy;
        },
        .word_boundary_line => {
            const counted = countWordBoundaryLiteralLogicalLinesRange(job.data, job.plan.needle, job.logical_start, job.logical_end);
            job.matches = counted.matches;
            job.boundary_verified_candidates = counted.verified_candidates;
            job.boundary_rejected_candidates = counted.rejected_candidates;
        },
        .regex_decomposition_line => {
            const counted = countRegexDecompositionLogicalLinesRange(job.data, job.plan.needle, job.plan.pattern, job.logical_start, job.logical_end);
            job.matches = counted.matches;
            job.regex_candidate_lines_checked = counted.candidate_lines_checked;
            job.regex_duplicate_candidate_hits_skipped = counted.duplicate_candidate_hits_skipped;
            job.regex_candidate_lines_matched = counted.candidate_lines_matched;
            job.regex_bailed_out = counted.bailed_out;
        },
    }
    job.elapsed_ns = @intFromFloat(elapsedMs(job.io, started) * 1_000_000.0);
}

fn countLiteralLogicalRange(data: []const u8, needle: []const u8, logical_start: usize, logical_end: usize, widened_start: usize, widened_end: usize) usize {
    if (needle.len == 0 or logical_start >= logical_end or widened_start >= widened_end) return 0;
    const end = @min(widened_end, data.len);
    const start = @min(widened_start, end);
    if (start >= end) return 0;
    if (logical_start == widened_start and logical_end == widened_end) {
        return simd.countNonOverlapping(data[start..end], needle);
    }
    var total: usize = 0;
    var cursor = start;
    while (cursor + needle.len <= end) {
        const index = simd.indexOf(data[cursor..end], needle) orelse break;
        const match_start = cursor + index;
        if (match_start >= logical_end) break;
        if (match_start >= logical_start) total += 1;
        cursor = match_start + needle.len;
    }
    return total;
}

fn streamingLiteralNeedle(plan: expr.ExpressionPlan) ?[]const u8 {
    const shard_plan = byte_shard.plan(plan) orelse return null;
    if (shard_plan.strategy != .literal_occurrence or shard_plan.case_insensitive) return null;
    if (shard_plan.needle.len == 0 or shard_plan.needle.len > STREAMING_LITERAL_TAIL_CAP) return null;
    return shard_plan.needle;
}

const STREAMING_LITERAL_TAIL_CAP: usize = 256;

fn countLiteralStreamingChunks(
    io: std.Io,
    file: std.Io.File,
    buffer: []u8,
    first_read: usize,
    file_bytes: usize,
    needle: []const u8,
) !usize {
    if (needle.len == 0 or first_read == 0 or first_read > buffer.len) return 0;
    if (needle.len > STREAMING_LITERAL_TAIL_CAP) return error.StreamingLiteralNeedleTooLong;
    var total = countLiteralLogicalRange(buffer[0..first_read], needle, 0, first_read, 0, first_read);
    var tail_buf: [STREAMING_LITERAL_TAIL_CAP]u8 = undefined;
    var tail_len = updateLiteralTail(&tail_buf, &.{}, buffer[0..first_read], needle.len - 1);
    var offset: u64 = first_read;
    while (offset < file_bytes) {
        const remaining = file_bytes - @as(usize, @intCast(offset));
        const target_len = @min(buffer.len, remaining);
        const read_len = try file.readPositionalAll(io, buffer[0..target_len], offset);
        if (read_len == 0) break;
        total += countLiteralCrossBoundary(tail_buf[0..tail_len], buffer[0..read_len], needle);
        total += countLiteralLogicalRange(buffer[0..read_len], needle, 0, read_len, 0, read_len);
        tail_len = updateLiteralTail(&tail_buf, tail_buf[0..tail_len], buffer[0..read_len], needle.len - 1);
        offset += read_len;
    }
    return total;
}

fn countLiteralCrossBoundary(tail: []const u8, chunk: []const u8, needle: []const u8) usize {
    if (tail.len == 0 or chunk.len == 0 or needle.len <= 1) return 0;
    var window: [STREAMING_LITERAL_TAIL_CAP * 2]u8 = undefined;
    const prefix_len = @min(chunk.len, needle.len - 1);
    @memcpy(window[0..tail.len], tail);
    @memcpy(window[tail.len .. tail.len + prefix_len], chunk[0..prefix_len]);
    const window_len = tail.len + prefix_len;
    const first_start = tail.len -| (needle.len - 1);
    var total: usize = 0;
    var start = first_start;
    while (start < tail.len) : (start += 1) {
        if (start + needle.len <= window_len and std.mem.eql(u8, window[start .. start + needle.len], needle)) total += 1;
    }
    return total;
}

fn updateLiteralTail(out: *[STREAMING_LITERAL_TAIL_CAP]u8, previous_tail: []const u8, chunk: []const u8, overlap: usize) usize {
    if (overlap == 0) return 0;
    if (chunk.len >= overlap) {
        @memcpy(out[0..overlap], chunk[chunk.len - overlap ..]);
        return overlap;
    }
    var window: [STREAMING_LITERAL_TAIL_CAP * 2]u8 = undefined;
    @memcpy(window[0..previous_tail.len], previous_tail);
    @memcpy(window[previous_tail.len .. previous_tail.len + chunk.len], chunk);
    const window_len = previous_tail.len + chunk.len;
    const keep = @min(overlap, window_len);
    @memcpy(out[0..keep], window[window_len - keep .. window_len]);
    return keep;
}

fn countRegexDecompositionLogicalLinesRange(
    data: []const u8,
    needle: []const u8,
    pattern: []const u8,
    logical_start: usize,
    logical_end: usize,
) RegexDecompositionRangeCount {
    if (needle.len == 0 or pattern.len == 0 or logical_start >= logical_end) return .{};
    const end = @min(logical_end, data.len);
    var result: RegexDecompositionRangeCount = .{};
    var search_pos = @min(logical_start, end);
    var last_line_start: ?usize = null;

    while (search_pos < end) {
        const relative = simd.indexOf(data[search_pos..end], needle) orelse break;
        const candidate_start = search_pos + relative;
        const line_start = lineStartForOffset(data, candidate_start);
        search_pos = @min(candidate_start + needle.len, end);

        if (line_start < logical_start) continue;
        if (last_line_start != null and last_line_start.? == line_start) {
            result.duplicate_candidate_hits_skipped += 1;
            continue;
        }
        if (result.candidate_lines_checked == REGEX_DECOMPOSITION_MAX_CANDIDATE_LINES) {
            result.bailed_out = true;
            return result;
        }

        const line_end = lineEndForOffset(data, candidate_start);
        result.candidate_lines_checked += 1;
        const raw_line = data[line_start..line_end];
        const line = trimCR(raw_line);
        if (regexLineMatches(line, pattern)) {
            result.matches += 1;
            result.candidate_lines_matched += 1;
        }
        last_line_start = line_start;
    }

    return result;
}

fn shouldRunByteShardBeforeAdmission(plan: expr.ExpressionPlan) bool {
    const shard_plan = byte_shard.plan(plan) orelse return false;
    return shard_plan.strategy == .literal_alternates_line or
        shard_plan.strategy == .regex_decomposition_line;
}

fn shouldSkipTrigramAfterLiteralAdmission(plan: expr.ExpressionPlan, literal_admission_satisfied: bool) bool {
    if (!literal_admission_satisfied) return false;
    const shard_plan = byte_shard.plan(plan) orelse return false;
    return shard_plan.strategy == .literal_occurrence or
        shard_plan.strategy == .word_boundary_line;
}

/// Comptime-generic per-file scan. When mono is non-null, the per-line match
/// dispatch is fully monomorphized -- zero runtime switches in the inner loop.
/// When null, falls back to the runtime multi-predicate path.
fn scanOpenFileIntoShardImpl(
    comptime mono: ?MonoSpec,
    io: std.Io,
    allocator: std.mem.Allocator,
    file: std.Io.File,
    display_path: []const u8,
    request: cli.SearchRequest,
    plan: expr.ExpressionPlan,
    trigram_admission: trigram.Admission,
    trigram_program: *const TrigramAdmissionProgram,
    shard: *ShardReport,
    file_started: std.Io.Timestamp,
) anyerror!void {
    const read_buffer = shard.scan_buffer;
    if (read_buffer.len != SCAN_READ_BUFFER_SIZE) return error.OutOfMemory;

    // Read a full first chunk up front. Most files in the scan corpus fit in
    // the buffer, so this avoids a metadata length query and the second read
    // needed to fill the chunk after a small-prefix probe.
    const first_read = file.readStreaming(io, &.{read_buffer[0..]}) catch |err| switch (err) {
        error.EndOfStream => 0,
        else => return err,
    };
    if (first_read == 0) {
        shard.files_scanned += 1;
        recordLineIntoShardImpl(mono, allocator, display_path, "", 1, request, plan, shard, false);
        recordEvidenceCandidate(shard, display_path);
        const file_ms = elapsedMs(io, file_started);
        recordShardScanFileBufferedMs(shard, file_ms);
        if (file_ms >= shard.slowest_ms) shard.slowest_ms = file_ms;
        return;
    }
    if (simd.indexOfByte(read_buffer[0..@min(1024, first_read)], 0) != null) {
        shard.files_skipped += 1;
        shard.admission_stats.binary_entries_skipped += 1;
        shard.admission_stats.binary_file_bytes += @intCast(first_read);
        recordEvidenceSkipped(shard);
        return;
    }
    const single_chunk = first_read < read_buffer.len;
    const file_bytes: usize = if (single_chunk) first_read else @intCast(try file.length(io));

    // Multi-chunk files (> 1 MiB): switch to mmap for zero-copy access.
    // Eliminates the carry buffer, multi-read loop, and per-chunk syscalls.
    // Single-chunk files stay on the readPositional path (one syscall, warm cache).
    if (!single_chunk and shard.scan_input_policy.shouldAttemptMmap()) mmap: {
        scanFileMmap(mono, io, allocator, file, display_path, request, plan, trigram_admission, trigram_program, shard, file_started) catch break :mmap;
        return;
    }

    shard.files_scanned += 1;
    shard.bytes_scanned += file_bytes;
    shard.scope_tracker = .{};
    shard.last_record_scope_line = 0;
    const linux_dominant_target = recordLinuxDominantFileScan(shard, display_path, file_bytes);
    if (file_bytes >= shard.slowest_bytes) {
        shard.slowest_path = display_path;
        shard.slowest_bytes = file_bytes;
    }
    if (request.stats_only and !single_chunk and !request.case_insensitive) {
        if (streamingLiteralNeedle(plan)) |needle| {
            if (countLiteralStreamingChunks(io, file, read_buffer[0..], first_read, file_bytes, needle)) |count| {
                if (linux_dominant_target) recordLinuxDominantFileActivation(shard);
                shard.matches_found += count;
                recordEvidenceCandidate(shard, display_path);
                const file_ms = elapsedMs(io, file_started);
                recordShardScanFileBufferedMs(shard, file_ms);
                if (file_ms >= shard.slowest_ms) shard.slowest_ms = file_ms;
                return;
            } else |_| {}
        }
    }
    if (shouldAttemptWholeFileAdmission(single_chunk, request.case_insensitive, trigram_program)) {
        if (trigram_program.needsCasefold()) {
            // Single SIMD byteset scan: if none of the needle first bytes
            // (lower + upper) appear, skip casefold entirely. Replaces the
            // per-needle indexOfByte loop with one VPSHUFB-based pass.
            if (trigram_program.first_byte_set_populated and
                sz.indexOfByteSet(read_buffer[0..first_read], &trigram_program.first_byte_set) == null)
            {
                recordEvidencePruned(shard, file_bytes);
                const file_ms = elapsedMs(io, file_started);
                recordShardScanFileBufferedMs(shard, file_ms);
                if (file_ms >= shard.slowest_ms) shard.slowest_ms = file_ms;
                return;
            }
            asciiLowerBuf(read_buffer[0..first_read], read_buffer[0..first_read]);
        }
        if (trigram_program.fileAdmissionMiss(read_buffer[0..first_read])) {
            recordEvidencePruned(shard, file_bytes);
            const file_ms = elapsedMs(io, file_started);
            recordShardScanFileBufferedMs(shard, file_ms);
            if (file_ms >= shard.slowest_ms) shard.slowest_ms = file_ms;
            return;
        }
    }
    const literal_admission_satisfied =
        shouldAttemptWholeFileAdmission(single_chunk, request.case_insensitive, trigram_program) and
        mono != null and
        search_admission.predicateAdmissionGroupRuntimeCaseSensitive(plan.predicates[0]) != null;
    if (!shouldSkipTrigramAfterLiteralAdmission(plan, literal_admission_satisfied) and
        shouldAttemptTrigramPrune(file_bytes, single_chunk, trigram_admission, request.case_insensitive) and
        tryTrigramPruneFile(read_buffer[0..first_read], trigram_program, &shard.trigram_stats))
    {
        recordEvidencePruned(shard, file_bytes);
        const file_ms = elapsedMs(io, file_started);
        recordShardScanFileBufferedMs(shard, file_ms);
        if (file_ms >= shard.slowest_ms) shard.slowest_ms = file_ms;
        return;
    }

    // FM-Index backward-search admission (spec point 11).
    // Env-gated: IX_FM_INDEX_ADMISSION=1 enables in-memory BWT construction
    // and O(p) backward search for eligible files. Enabled by default as
    // the sub-linear admission path (P11). The env gate IX_FM_INDEX_ADMISSION=0
    // can disable it if needed. The check is cached per-thread.
    if (!fm_index_admission_checked) {
        fm_index_admission_checked = true;
        const env_val = std.c.getenv("IX_FM_INDEX_ADMISSION\x00");
        fm_index_admission_cached = !(env_val != null and std.mem.eql(u8, std.mem.span(env_val.?), "0"));
    }
    if (fm_index_admission_cached and single_chunk and file_bytes <= FM_INDEX_ADMISSION_MAX_BYTES) {
        if (tryFmIndexAdmission(allocator, read_buffer[0..first_read], plan)) {
            recordEvidencePruned(shard, file_bytes);
            const file_ms = elapsedMs(io, file_started);
            recordShardScanFileBufferedMs(shard, file_ms);
            if (file_ms >= shard.slowest_ms) shard.slowest_ms = file_ms;
            return;
        }
    }

    // CHUNK CASEFOLD: keep the existing per-chunk lowercase path for pure
    // casefold literals. For casefold literal alternates, only pre-lowercase
    // larger single-chunk buffers where the extra write can repay the
    // repeated folded matching cost.
    const chunk_casefold = request.stats_only and planIsFullyCasefoldLiteral(plan);
    const alternates_full_scan_casefold = request.stats_only and
        single_chunk and
        first_read >= WHOLE_BUFFER_ALTERNATES_CASEFOLD_MIN_BYTES and
        planIsCasefoldLiteralAlternates(plan, request.case_insensitive);

    // Casefold the first chunk in-place after binary sniff confirms it is text.
    if (chunk_casefold or alternates_full_scan_casefold) {
        asciiLowerBuf(read_buffer[0..first_read], read_buffer[0..first_read]);
    }

    // WHOLE-BUFFER FAST COUNT: for single-chunk files in stats-only mode,
    // count eligible predicates across the entire buffer without line splitting.
    if (request.stats_only and single_chunk) {
        const whole_buffer_casefolded = chunk_casefold or alternates_full_scan_casefold;
        const ci = if (whole_buffer_casefolded) false else request.case_insensitive;
        if (wholeBufferFastCount(read_buffer[0..first_read], plan, ci, whole_buffer_casefolded)) |count| {
            shard.matches_found += count;
            if (mono) |m| {
                if (m.kind == .regex and m.strategy == .regex_literal_alternates) {
                    shard.fast_count_density_stats.alternate_full_scan_calls += 1;
                    shard.fast_count_density_stats.alternate_full_scan_bytes += first_read;
                    shard.fast_count_density_stats.alternate_full_scan_matches += count;
                    shard.fast_count_density_stats.alternate_matches += count;
                }
            }
            recordEvidenceCandidate(shard, display_path);
            const file_ms = elapsedMs(io, file_started);
            recordShardScanFileBufferedMs(shard, file_ms);
            if (file_ms >= shard.slowest_ms) shard.slowest_ms = file_ms;
            return;
        }
        if (regexDecompositionFastCount(read_buffer[0..first_read], plan, ci, &shard.regex_decomposition_stats, &shard.acceleration_bailouts)) |count| {
            shard.matches_found += count;
            recordEvidenceCandidate(shard, display_path);
            const file_ms = elapsedMs(io, file_started);
            recordShardScanFileBufferedMs(shard, file_ms);
            if (file_ms >= shard.slowest_ms) shard.slowest_ms = file_ms;
            return;
        }
    }

    // CHUNK-LEVEL PREFILTER: reuse the contract-safe admission group for the
    // mono predicate to reject chunks that cannot contain a match.
    // This preserves correctness by only skipping when there is no carry
    // from a prior chunk, so cross-boundary lines are still rechecked after
    // the carry is stitched into the next chunk.
    const chunk_prefilter_group: ?search_admission.FileAdmissionGroup = if (mono != null and !request.case_insensitive)
        search_admission.predicateAdmissionGroupRuntimeCaseSensitive(plan.predicates[0])
    else
        null;

    var carry: std.ArrayList(u8) = .empty;
    defer carry.deinit(allocator);
    var line_number: usize = 1;
    var ended_with_newline = false;

    // Process first chunk then any remaining chunks (most files fit in one chunk).
    var chunk: []const u8 = read_buffer[0..first_read];
    var offset: u64 = first_read;
    while (true) {
        ended_with_newline = chunk[chunk.len - 1] == '\n';

        // Chunk-level prefilter: if the mandatory literal is absent from the
        // entire chunk AND no carry data spans from the previous chunk, skip
        // the per-line loop. Count newlines with SIMD to maintain line_number,
        // then set up the carry buffer for the trailing partial line.
        if (chunk_prefilter_group) |group| {
            if (carry.items.len == 0 and group.isMiss(chunk)) {
                // Fast newline count: count newlines in bulk via SIMD.
                if (!request.stats_only) {
                    line_number += std.mem.count(u8, chunk, "\n");
                }
                // If chunk doesn't end with newline, the trailing bytes
                // become carry for the next chunk.
                if (!ended_with_newline) {
                    // Find last newline to extract the trailing partial line.
                    if (std.mem.lastIndexOfScalar(u8, chunk, '\n')) |last_nl| {
                        try carry.appendSlice(allocator, chunk[last_nl + 1 ..]);
                    } else {
                        // No newlines in chunk -- entire chunk is carry.
                        try carry.appendSlice(allocator, chunk);
                    }
                }
                if (offset >= file_bytes) break;
                const remaining = file_bytes - @as(usize, @intCast(offset));
                const target_len: usize = @intCast(@min(read_buffer.len, remaining));
                const read_len = try file.readPositionalAll(io, read_buffer[0..target_len], offset);
                if (read_len == 0) break;
                offset += read_len;
                chunk = read_buffer[0..read_len];
                if (chunk_casefold) asciiLowerBuf(read_buffer[0..read_len], read_buffer[0..read_len]);
                continue;
            }
        }

        var chunk_index: usize = 0;
        while (chunk_index < chunk.len) {
            if (simd.indexOfByte(chunk[chunk_index..], '\n')) |relative_newline| {
                const line_part = chunk[chunk_index .. chunk_index + relative_newline];
                if (carry.items.len == 0) {
                    recordLineIntoShardImpl(mono, allocator, display_path, line_part, line_number, request, plan, shard, chunk_casefold);
                } else {
                    try carry.appendSlice(allocator, line_part);
                    recordLineIntoShardImpl(mono, allocator, display_path, carry.items, line_number, request, plan, shard, chunk_casefold);
                    carry.clearRetainingCapacity();
                }
                if (shard.truncated) break;
                line_number += 1;
                chunk_index += relative_newline + 1;
            } else {
                try carry.appendSlice(allocator, chunk[chunk_index..]);
                break;
            }
        }
        if (shard.truncated or offset >= file_bytes) break;
        // Read next chunk -- only for files > 1 MiB.
        const remaining = file_bytes - @as(usize, @intCast(offset));
        const target_len: usize = @intCast(@min(read_buffer.len, remaining));

        // P16: On Linux, use io_uring kernel-bypass I/O for multi-chunk reads.
        // io_uring.submitRead + pollCompletion eliminates the readPositionalAll
        // syscall — the kernel reads directly into the pre-registered buffer
        // via IORING_OP_READ_FIXED with zero context switches (SQPOLL mode).
        // The DMA transfer goes straight from the NVMe PCIe bus into the
        // pre-registered user-space buffer — no intermediate kernel copies.
        //
        // This is the scan hot path integration point for io_uring. The ring
        // is created per-worker (thread-local), pre-registers the read buffer,
        // and submits READ_FIXED SQEs. On completion, the CQE is polled from
        // the CQ ring — no io_uring_enter syscall needed in SQPOLL mode.
        //
        // On non-Linux or io_uring failure, falls back to readPositionalAll.
        const read_len: usize = if (io_uring.supported) blk: {
            // io_uring is Linux-only; on other platforms, this path is unreachable.
            var ring = io_uring.createWorkerRing(allocator) orelse break :blk file.readPositionalAll(io, read_buffer[0..target_len], offset) catch break :blk 0;
            defer ring.deinit();
            const result = ring.readBlocking(file, read_buffer[0..target_len], offset) catch break :blk file.readPositionalAll(io, read_buffer[0..target_len], offset) catch break :blk 0;
            break :blk @intCast(@max(result, 0));
        } else try file.readPositionalAll(io, read_buffer[0..target_len], offset);

        if (read_len == 0) break;
        offset += read_len;
        chunk = read_buffer[0..read_len];
        // Casefold each subsequent chunk in-place for the same amortised benefit.
        if (chunk_casefold) asciiLowerBuf(read_buffer[0..read_len], read_buffer[0..read_len]);
    }

    if (!shard.truncated and (carry.items.len > 0 or ended_with_newline)) {
        recordLineIntoShardImpl(mono, allocator, display_path, carry.items, line_number, request, plan, shard, chunk_casefold);
    }
    recordEvidenceCandidate(shard, display_path);
    const file_ms = elapsedMs(io, file_started);
    recordShardScanFileBufferedMs(shard, file_ms);
    if (file_ms >= shard.slowest_ms) shard.slowest_ms = file_ms;
}

/// Runtime wrapper -- dispatches to Impl with null mono (generic path).
fn scanOpenFileIntoShard(
    io: std.Io,
    allocator: std.mem.Allocator,
    file: std.Io.File,
    display_path: []const u8,
    request: cli.SearchRequest,
    plan: expr.ExpressionPlan,
    trigram_admission: trigram.Admission,
    trigram_program: *const TrigramAdmissionProgram,
    shard: *ShardReport,
    file_started: std.Io.Timestamp,
) anyerror!void {
    return scanOpenFileIntoShardImpl(null, io, allocator, file, display_path, request, plan, trigram_admission, trigram_program, shard, file_started);
}

/// Comptime-generic per-line processor. When mono is non-null (single-predicate
/// plan), match dispatch is fully resolved at compile time. When null, falls
/// back to the runtime multi-predicate path.
fn recordLineIntoShardImpl(
    comptime mono: ?MonoSpec,
    allocator: std.mem.Allocator,
    display_path: []const u8,
    raw_line: []const u8,
    line_number: usize,
    request: cli.SearchRequest,
    plan: expr.ExpressionPlan,
    shard: *ShardReport,
    chunk_casefolded: bool,
) void {
    const line = trimCR(raw_line);
    shard.scope_tracker.processLine(line, line_number);
    if (request.stats_only) {
        const ci = if (chunk_casefolded) false else request.case_insensitive;
        const count = if (mono) |m|
            predicateMatchCountMono(m.kind, m.strategy, line, plan.predicates[0], ci, chunk_casefolded)
        else
            statsOnlyMatchCount(line, plan, ci, chunk_casefolded);
        shard.matches_found += count;
        if (request.max_hits) |max_hits| {
            if (shard.matches_found >= max_hits) shard.truncated = true;
        }
        return;
    }
    const column = if (mono) |m|
        predicateColumnMono(m.kind, m.strategy, line, plan.predicates[0], request.case_insensitive)
    else
        matchingColumn(line, plan, request.case_insensitive);
    if (column) |col| {
        shard.matches_found += 1;
        if (!isAfterCursor(request, display_path, line_number, col)) return;
        shard.matches_after_cursor += 1;
        const under_request_limit = if (request.max_hits) |max_hits| shard.hit_count < max_hits else true;
        if (under_request_limit and shard.hit_count < MAX_RETAINED_HITS) {
            const sc = shard.scope_tracker.currentScope();
            // P22: --record block/section deduplication.
            // block: one hit per brace-depth-0 block (deduplicate by scope+brace_depth).
            // section: one hit per function/section (deduplicate by scope name).
            if (shouldDedupByRecord(request, &shard.last_record_scope_line, sc.name, sc.line)) return;
            const span = exactMatchSpan(line, plan, request.case_insensitive, col);
            const hit = makeSearchHit(allocator, display_path, line_number, col, line, span) catch {
                // A preview allocation failure must never retain a borrowed scan-buffer slice.
                shard.truncated = true;
                return;
            };
            // P17: Non-temporal hint — result buffer writes should not evict hot scan data.
            streamStoreHint(@ptrCast(&shard.hits[shard.hit_count]));
            shard.hits[shard.hit_count] = hit;
            shard.hits[shard.hit_count].scope = if (sc.name.len > 0) allocator.dupe(u8, sc.name) catch "" else "";
            shard.hits[shard.hit_count].scope_line = sc.line;
            shard.last_record_scope_line = sc.line;
            shard.hit_count += 1;
        }
    }
}

fn recordLineIntoShard(
    allocator: std.mem.Allocator,
    display_path: []const u8,
    raw_line: []const u8,
    line_number: usize,
    request: cli.SearchRequest,
    plan: expr.ExpressionPlan,
    shard: *ShardReport,
    chunk_casefolded: bool,
) void {
    recordLineIntoShardImpl(null, allocator, display_path, raw_line, line_number, request, plan, shard, chunk_casefolded);
}

/// Worker thread entry point. For single-predicate plans, dispatches to a
/// comptime-monomorphized file loop where per-line match overhead is zero.
fn shardWorker(io: std.Io, allocator: std.mem.Allocator, files: []const DiscoveredFile, request: cli.SearchRequest, plan: expr.ExpressionPlan, trigram_admission: trigram.Admission, trigram_program: *const TrigramAdmissionProgram, shard: *ShardReport) void {
    const scan_buffer = allocator.alloc(u8, SCAN_READ_BUFFER_SIZE) catch {
        shard.had_error = true;
        return;
    };
    defer allocator.free(scan_buffer);
    shard.scan_buffer = scan_buffer;
    if (plan.predicate_count == 1) {
        dispatchMonoShardLoop(io, allocator, files, request, plan, trigram_admission, trigram_program, shard);
    } else {
        if (shard.capture_scan_open_timing) return shardWorkerTimed(io, allocator, files, request, plan, trigram_admission, trigram_program, shard);
        for (files) |entry| {
            if (shard.truncated) break;
            scanFileIntoShard(io, allocator, entry.path, request, plan, trigram_admission, trigram_program, shard);
        }
    }
}

fn shardWorkerTimed(io: std.Io, allocator: std.mem.Allocator, files: []const DiscoveredFile, request: cli.SearchRequest, plan: expr.ExpressionPlan, trigram_admission: trigram.Admission, trigram_program: *const TrigramAdmissionProgram, shard: *ShardReport) void {
    for (files) |entry| {
        if (shard.truncated) break;
        scanFileIntoShardTimed(io, allocator, entry.path, request, plan, trigram_admission, trigram_program, shard);
    }
}

fn dynamicShardWorker(io: std.Io, allocator: std.mem.Allocator, next_file: *usize, files: []const DiscoveredFile, request: cli.SearchRequest, plan: expr.ExpressionPlan, trigram_admission: trigram.Admission, trigram_program: *const TrigramAdmissionProgram, shard: *ShardReport) void {
    const scan_buffer = allocator.alloc(u8, SCAN_READ_BUFFER_SIZE) catch {
        shard.had_error = true;
        return;
    };
    defer allocator.free(scan_buffer);
    shard.scan_buffer = scan_buffer;
    if (plan.predicate_count == 1) {
        dispatchMonoDynamicLoop(io, allocator, next_file, files, request, plan, trigram_admission, trigram_program, shard);
    } else {
        if (shard.capture_scan_open_timing) return dynamicShardWorkerTimed(io, allocator, next_file, files, request, plan, trigram_admission, trigram_program, shard);
        while (!shard.truncated) {
            const index = @atomicRmw(usize, next_file, .Add, 1, .monotonic);
            if (index >= files.len) break;
            scanFileIntoShard(io, allocator, files[index].path, request, plan, trigram_admission, trigram_program, shard);
        }
    }
}

fn dynamicShardWorkerTimed(io: std.Io, allocator: std.mem.Allocator, next_file: *usize, files: []const DiscoveredFile, request: cli.SearchRequest, plan: expr.ExpressionPlan, trigram_admission: trigram.Admission, trigram_program: *const TrigramAdmissionProgram, shard: *ShardReport) void {
    while (!shard.truncated) {
        const index = @atomicRmw(usize, next_file, .Add, 1, .monotonic);
        if (index >= files.len) break;
        scanFileIntoShardTimed(io, allocator, files[index].path, request, plan, trigram_admission, trigram_program, shard);
    }
}

/// Resolve single-predicate plan to comptime-known kind+strategy, then enter
/// monomorphized file loop. Dispatch happens once per worker thread.
fn dispatchMonoShardLoop(io: std.Io, allocator: std.mem.Allocator, files: []const DiscoveredFile, request: cli.SearchRequest, plan: expr.ExpressionPlan, trigram_admission: trigram.Admission, trigram_program: *const TrigramAdmissionProgram, shard: *ShardReport) void {
    const pred = plan.predicates[0];
    switch (pred.kind) {
        .literal => monoShardLoop(.{ .kind = .literal, .strategy = .literal }, io, allocator, files, request, plan, trigram_admission, trigram_program, shard),
        .prefix => monoShardLoop(.{ .kind = .prefix, .strategy = .prefix }, io, allocator, files, request, plan, trigram_admission, trigram_program, shard),
        .suffix => monoShardLoop(.{ .kind = .suffix, .strategy = .suffix }, io, allocator, files, request, plan, trigram_admission, trigram_program, shard),
        .regex => switch (pred.strategy) {
            inline else => |strategy| monoShardLoop(.{ .kind = .regex, .strategy = strategy }, io, allocator, files, request, plan, trigram_admission, trigram_program, shard),
        },
    }
}

fn monoShardLoop(comptime mono: MonoSpec, io: std.Io, allocator: std.mem.Allocator, files: []const DiscoveredFile, request: cli.SearchRequest, plan: expr.ExpressionPlan, trigram_admission: trigram.Admission, trigram_program: *const TrigramAdmissionProgram, shard: *ShardReport) void {
    if (shard.capture_scan_open_timing) return monoShardLoopTimed(mono, io, allocator, files, request, plan, trigram_admission, trigram_program, shard);
    for (files) |entry| {
        if (shard.truncated) break;
        scanFileIntoShardMono(mono, io, allocator, entry.path, request, plan, trigram_admission, trigram_program, shard);
    }
}

fn monoShardLoopTimed(comptime mono: MonoSpec, io: std.Io, allocator: std.mem.Allocator, files: []const DiscoveredFile, request: cli.SearchRequest, plan: expr.ExpressionPlan, trigram_admission: trigram.Admission, trigram_program: *const TrigramAdmissionProgram, shard: *ShardReport) void {
    for (files) |entry| {
        if (shard.truncated) break;
        scanFileIntoShardMonoTimed(mono, io, allocator, entry.path, request, plan, trigram_admission, trigram_program, shard);
    }
}

fn dispatchMonoDynamicLoop(io: std.Io, allocator: std.mem.Allocator, next_file: *usize, files: []const DiscoveredFile, request: cli.SearchRequest, plan: expr.ExpressionPlan, trigram_admission: trigram.Admission, trigram_program: *const TrigramAdmissionProgram, shard: *ShardReport) void {
    const pred = plan.predicates[0];
    switch (pred.kind) {
        .literal => monoDynamicLoop(.{ .kind = .literal, .strategy = .literal }, io, allocator, next_file, files, request, plan, trigram_admission, trigram_program, shard),
        .prefix => monoDynamicLoop(.{ .kind = .prefix, .strategy = .prefix }, io, allocator, next_file, files, request, plan, trigram_admission, trigram_program, shard),
        .suffix => monoDynamicLoop(.{ .kind = .suffix, .strategy = .suffix }, io, allocator, next_file, files, request, plan, trigram_admission, trigram_program, shard),
        .regex => switch (pred.strategy) {
            inline else => |strategy| monoDynamicLoop(.{ .kind = .regex, .strategy = strategy }, io, allocator, next_file, files, request, plan, trigram_admission, trigram_program, shard),
        },
    }
}

fn monoDynamicLoop(comptime mono: MonoSpec, io: std.Io, allocator: std.mem.Allocator, next_file: *usize, files: []const DiscoveredFile, request: cli.SearchRequest, plan: expr.ExpressionPlan, trigram_admission: trigram.Admission, trigram_program: *const TrigramAdmissionProgram, shard: *ShardReport) void {
    if (shard.capture_scan_open_timing) return monoDynamicLoopTimed(mono, io, allocator, next_file, files, request, plan, trigram_admission, trigram_program, shard);
    while (!shard.truncated) {
        const index = @atomicRmw(usize, next_file, .Add, 1, .monotonic);
        if (index >= files.len) break;
        scanFileIntoShardMono(mono, io, allocator, files[index].path, request, plan, trigram_admission, trigram_program, shard);
    }
}

fn monoDynamicLoopTimed(comptime mono: MonoSpec, io: std.Io, allocator: std.mem.Allocator, next_file: *usize, files: []const DiscoveredFile, request: cli.SearchRequest, plan: expr.ExpressionPlan, trigram_admission: trigram.Admission, trigram_program: *const TrigramAdmissionProgram, shard: *ShardReport) void {
    while (!shard.truncated) {
        const index = @atomicRmw(usize, next_file, .Add, 1, .monotonic);
        if (index >= files.len) break;
        scanFileIntoShardMonoTimed(mono, io, allocator, files[index].path, request, plan, trigram_admission, trigram_program, shard);
    }
}

/// Monomorphized file opener -- calls scanOpenFileIntoShardImpl with comptime mono.
fn scanFileIntoShardMono(comptime mono: MonoSpec, io: std.Io, allocator: std.mem.Allocator, display_path: []const u8, request: cli.SearchRequest, plan: expr.ExpressionPlan, trigram_admission: trigram.Admission, trigram_program: *const TrigramAdmissionProgram, shard: *ShardReport) void {
    if (shouldSkipProtectedBinaryContainer(request, display_path)) {
        shard.files_skipped += 1;
        recordEvidenceSkipped(shard);
        return;
    }
    const file_started = std.Io.Timestamp.now(io, .awake);
    const file = nt_open.openFile(io, display_path) catch |err| {
        shard.files_skipped += 1;
        recordShardAccessError(shard, "scan", "open_file", display_path, err);
        recordEvidenceSkipped(shard);
        return;
    };
    defer file.close(io);
    scanOpenFileIntoShardImpl(mono, io, allocator, file, display_path, request, plan, trigram_admission, trigram_program, shard, file_started) catch |err| {
        if (isRecoverableScanAccessError(err)) {
            shard.files_skipped += 1;
            recordShardAccessError(shard, "scan", "read_file", display_path, err);
            recordEvidenceSkipped(shard);
        } else {
            shard.had_error = true;
        }
    };
}

fn scanFileIntoShardMonoTimed(comptime mono: MonoSpec, io: std.Io, allocator: std.mem.Allocator, display_path: []const u8, request: cli.SearchRequest, plan: expr.ExpressionPlan, trigram_admission: trigram.Admission, trigram_program: *const TrigramAdmissionProgram, shard: *ShardReport) void {
    if (shouldSkipProtectedBinaryContainer(request, display_path)) {
        shard.files_skipped += 1;
        recordEvidenceSkipped(shard);
        return;
    }
    const file_started = std.Io.Timestamp.now(io, .awake);
    const file = nt_open.openFile(io, display_path) catch |err| {
        recordShardScanOpenMs(shard, elapsedMs(io, file_started));
        shard.files_skipped += 1;
        recordShardAccessError(shard, "scan", "open_file", display_path, err);
        recordEvidenceSkipped(shard);
        return;
    };
    recordShardScanOpenMs(shard, elapsedMs(io, file_started));
    const scan_started = std.Io.Timestamp.now(io, .awake);
    defer file.close(io);
    scanOpenFileIntoShardImpl(mono, io, allocator, file, display_path, request, plan, trigram_admission, trigram_program, shard, scan_started) catch |err| {
        if (isRecoverableScanAccessError(err)) {
            shard.files_skipped += 1;
            recordShardAccessError(shard, "scan", "read_file", display_path, err);
            recordEvidenceSkipped(shard);
        } else {
            shard.had_error = true;
        }
    };
}

fn shouldUseDynamicWorkClaim(plan: expr.ExpressionPlan, file_count: usize) bool {
    _ = file_count; // Dynamic claiming benefits all file counts -- atomic counter contention is negligible.
    return canUseDynamicWorkClaimForPlan(plan);
}

fn canUseDynamicWorkClaimForPlan(plan: expr.ExpressionPlan) bool {
    // All single-predicate plans benefit from dynamic load balancing.
    // The monomorphized dispatch in dispatchMonoDynamicLoop handles every
    // PredicateKind x MatcherStrategy variant.
    return plan.predicate_count == 1;
}

/// Phase 2: Distribute files across N threads and scan in parallel.
/// Each thread gets a contiguous slice of the file list (static partitioning)
/// and writes into its own ShardReport. After all threads join, shard results
/// are merged into the main report.
fn parallelScanFiles(
    io: std.Io,
    allocator: std.mem.Allocator,
    files: []const DiscoveredFile,
    request: cli.SearchRequest,
    plan: expr.ExpressionPlan,
    trigram_admission: trigram.Admission,
    trigram_program: *const TrigramAdmissionProgram,
    thread_count: usize,
    evidence_runtime: EvidenceFrontierRuntime,
    report: *SearchReport,
) !void {
    const actual_threads = @min(thread_count, files.len);
    // Worker threads = actual_threads - 1 (main thread takes a shard too).
    const worker_count = actual_threads - 1;

    // Allocate shard reports -- one per thread (including main).
    const shards = try allocator.alloc(ShardReport, actual_threads);
    for (shards) |*shard| shard.* = initShardReport(report.*, evidence_runtime, allocator);

    // At the two-worker framework ceiling, static halves avoid one atomic
    // claim per file and preserve a stable ownership frontier. Dynamic load
    // balancing remains valuable only once enough workers can absorb skew.
    if (actual_threads > 2 and !request.stable_output and shouldUseDynamicWorkClaim(plan, files.len)) {
        var next_file: usize = 0;
        const threads = try allocator.alloc(std.Thread, worker_count);
        for (0..worker_count) |i| {
            const shard_index = i + 1;
            threads[i] = try std.Thread.spawn(.{}, dynamicShardWorker, .{ io, allocator, &next_file, files, request, plan, trigram_admission, trigram_program, &shards[shard_index] });
        }
        dynamicShardWorker(io, allocator, &next_file, files, request, plan, trigram_admission, trigram_program, &shards[0]);
        for (threads) |thread| thread.join();
        mergeShardsIntoReport(shards, request, report);
        writeEvidenceFrontierCacheFromShards(io, allocator, evidence_runtime, shards);
        return;
    }

    // Partition files across shards using round-robin-ish static split.
    const base_size = files.len / actual_threads;
    const remainder = files.len % actual_threads;

    // Calculate shard boundaries.
    const boundaries = try allocator.alloc(usize, actual_threads + 1);
    boundaries[0] = 0;
    for (0..actual_threads) |i| {
        const extra: usize = if (i < remainder) 1 else 0;
        boundaries[i + 1] = boundaries[i] + base_size + extra;
    }

    // Spawn worker threads (shards 1..N-1).
    const threads = try allocator.alloc(std.Thread, worker_count);
    for (0..worker_count) |i| {
        const shard_index = i + 1;
        const shard_files = files[boundaries[shard_index]..boundaries[shard_index + 1]];
        threads[i] = try std.Thread.spawn(.{}, shardWorker, .{ io, allocator, shard_files, request, plan, trigram_admission, trigram_program, &shards[shard_index] });
        // P18: NUMA topology sympathy — pin worker to a physical core.
        _ = resource_profile.pinWorkerThread(shard_index, actual_threads);
    }

    // Main thread processes shard 0.
    // P18: Pin main thread (shard 0) to core 0.
    _ = resource_profile.pinWorkerThread(0, actual_threads);
    const main_files = files[boundaries[0]..boundaries[1]];
    shardWorker(io, allocator, main_files, request, plan, trigram_admission, trigram_program, &shards[0]);

    // Join all worker threads.
    for (threads) |t| t.join();

    mergeShardsIntoReport(shards, request, report);
    writeEvidenceFrontierCacheFromShards(io, allocator, evidence_runtime, shards);
}

/// Applies the main-report instrumentation and optional evidence capture to one isolated shard.
fn initShardReport(report: SearchReport, evidence_runtime: EvidenceFrontierRuntime, allocator: std.mem.Allocator) ShardReport {
    var shard = ShardReport.empty;
    shard.capture_scan_open_timing = report.capture_scan_open_timing;
    shard.capture_linux_dominant_attribution = report.capture_linux_dominant_attribution;
    shard.scan_input_policy = report.scan_input_policy;
    if (evidence_runtime.enabled) {
        shard.evidence_capture = true;
        shard.evidence_allocator = allocator;
    }
    return shard;
}

fn mergeShardsIntoReport(shards: []const ShardReport, request: cli.SearchRequest, report: *SearchReport) void {
    const retained_limit = if (request.max_hits) |max_hits| @min(max_hits, MAX_RETAINED_HITS) else MAX_RETAINED_HITS;
    for (shards) |shard| {
        report.bytes_scanned += shard.bytes_scanned;
        report.files_scanned += shard.files_scanned;
        report.files_skipped += shard.files_skipped;
        report.matches_found += shard.matches_found;
        report.matches_after_cursor += shard.matches_after_cursor;
        report.scan_work_ms_total += shard.scan_work_ms_total;
        report.scan_open_ms_total += shard.scan_open_ms_total;
        report.scan_file_mmap_ms_total += shard.scan_file_mmap_ms_total;
        report.scan_file_buffered_ms_total += shard.scan_file_buffered_ms_total;
        report.stats.acceleration_bailouts += shard.acceleration_bailouts;
        report.stats.access_errors.merge(shard.access_errors);
        report.stats.admission.merge(shard.admission_stats);
        mergeFastCountDensityStats(&report.stats.fast_count_density, shard.fast_count_density_stats);
        mergeRegexDecompositionStats(&report.stats.regex_decomposition, shard.regex_decomposition_stats);
        mergeTrigramStats(&report.stats.trigram_acceleration, shard.trigram_stats);
        mergeByteShardStats(&report.stats.byte_shard_kernel, shard.byte_shard_stats);
        mergeLinuxDominantFileStats(&report.stats.linux_dominant_file, shard.linux_dominant_file_stats);
        if (shard.slowest_ms >= report.slowest_ms) {
            report.slowest_ms = shard.slowest_ms;
            report.slowest_path = shard.slowest_path;
            report.slowest_bytes = shard.slowest_bytes;
        }
        const linux_dominant_target = report.capture_linux_dominant_attribution and
            shard.slowest_bytes >= report.stats.linux_dominant_file.min_bytes and
            isLinuxDominantFilePath(shard.slowest_path);
        report.stats.recordSlowFile(shard.slowest_path, shard.slowest_ms, shard.slowest_bytes, linux_dominant_target);
        // Merge hits: copy from shard into report, respecting the global cap.
        const available = retained_limit -| report.hit_count;
        const to_copy = @min(shard.hit_count, available);
        for (0..to_copy) |j| {
            report.hits[report.hit_count] = shard.hits[j];
            report.hit_count += 1;
        }
        if (shard.truncated) report.truncated = true;
    }
    // P17: Flush non-temporal store buffers after merging all shard hits.
    // Non-temporal stores are weakly ordered — SFENCE ensures global visibility
    // before the report is consumed by the output layer.
    streamStoreFence();
}

fn mergeFastCountDensityStats(dst: *core_stats.FastCountDensityStats, src: core_stats.FastCountDensityStats) void {
    dst.literal_reject_fast_calls += src.literal_reject_fast_calls;
    dst.literal_reject_fast_bytes += src.literal_reject_fast_bytes;
    dst.literal_range_calls += src.literal_range_calls;
    dst.literal_range_bytes += src.literal_range_bytes;
    dst.literal_matches += src.literal_matches;
    dst.alternate_reject_fast_calls += src.alternate_reject_fast_calls;
    dst.alternate_reject_fast_bytes += src.alternate_reject_fast_bytes;
    dst.alternate_full_scan_calls += src.alternate_full_scan_calls;
    dst.alternate_full_scan_bytes += src.alternate_full_scan_bytes;
    dst.alternate_full_scan_matches += src.alternate_full_scan_matches;
    dst.alternate_range_calls += src.alternate_range_calls;
    dst.alternate_range_bytes += src.alternate_range_bytes;
    dst.alternate_pcre_range_calls += src.alternate_pcre_range_calls;
    dst.alternate_pcre_range_bytes += src.alternate_pcre_range_bytes;
    dst.alternate_teddy_range_calls += src.alternate_teddy_range_calls;
    dst.alternate_teddy_range_bytes += src.alternate_teddy_range_bytes;
    dst.alternate_compiled_range_calls += src.alternate_compiled_range_calls;
    dst.alternate_compiled_range_bytes += src.alternate_compiled_range_bytes;
    dst.alternate_matches += src.alternate_matches;
    dst.shard_merge_calls += src.shard_merge_calls;
    dst.shard_merge_ranges += src.shard_merge_ranges;
    dst.shard_merge_matches += src.shard_merge_matches;
}

const PreparedRoot = struct {
    original: []const u8,
    comparable: []const u8,
    is_directory: bool,
};

const PreparedRoots = struct {
    items: []PreparedRoot,
    count: usize,
    duplicate_count: usize,
    overlap_pruned_count: usize,
};

/// Deduplicates and prunes search roots to avoid scanning the same files
/// multiple times. Three checks run in order:
///   1. Exact duplicate: same normalized path -> skip
///   2. Contained by accepted: candidate is inside an already-accepted dir -> skip
///   3. Contains accepted: candidate is a parent dir of an accepted root ->
///      evict the child and accept the parent instead
///
/// This mirrors Rust's root pruning logic so that telemetry counters
/// (pruned_roots, overlap_pruned_roots) match between implementations.
fn prepareRoots(io: std.Io, allocator: std.mem.Allocator, request: cli.SearchRequest) !PreparedRoots {
    const input_count = if (request.path_count == 0) 1 else request.path_count;
    const roots = try allocator.alloc(PreparedRoot, input_count);
    var count: usize = 0;
    var duplicate_count: usize = 0;
    var overlap_pruned_count: usize = 0;
    var input_index: usize = 0;
    while (input_index < input_count) : (input_index += 1) {
        const raw = if (request.path_count == 0) "." else request.paths[input_index];
        const candidate = try classifyRoot(io, allocator, raw);
        if (hasEquivalentRoot(roots[0..count], candidate)) {
            duplicate_count += 1;
            continue;
        }
        if (isContainedByAcceptedRoot(roots[0..count], candidate)) {
            overlap_pruned_count += 1;
            continue;
        }
        // Reverse containment: if the new candidate is a parent of an already-
        // accepted root, evict the child. Uses swap-remove (replace with last
        // element) to avoid shifting the array -- O(1) per eviction.
        var accepted_index: usize = 0;
        while (accepted_index < count) {
            if (isContainedBy(candidate, roots[accepted_index])) {
                roots[accepted_index] = roots[count - 1];
                count -= 1;
                overlap_pruned_count += 1;
                continue;
            }
            accepted_index += 1;
        }
        roots[count] = candidate;
        count += 1;
    }
    return .{
        .items = roots,
        .count = count,
        .duplicate_count = duplicate_count,
        .overlap_pruned_count = overlap_pruned_count,
    };
}

fn classifyRoot(io: std.Io, allocator: std.mem.Allocator, raw: []const u8) !PreparedRoot {
    var is_directory = false;
    if (std.Io.Dir.cwd().openDir(io, raw, .{})) |dir| {
        var open_dir = dir;
        open_dir.close(io);
        is_directory = true;
    } else |_| {
        is_directory = false;
    }
    const comparable = normalizeComparableRoot(allocator, raw) catch try allocator.dupe(u8, raw);
    return .{
        .original = raw,
        .comparable = comparable,
        .is_directory = is_directory,
    };
}

/// Normalizes a root path for deduplication comparison.
/// Backslashes -> forward slashes, lowercased, trailing slashes stripped.
/// This makes Windows paths like `src\Core\` compare equal to `src/core/`.
fn normalizeComparableRoot(allocator: std.mem.Allocator, raw: []const u8) ![]const u8 {
    var normalized = try allocator.dupe(u8, raw);
    for (normalized) |*byte| {
        if (byte.* == '\\') byte.* = '/';
        byte.* = std.ascii.toLower(byte.*);
    }
    while (normalized.len > 1 and normalized[normalized.len - 1] == '/') {
        normalized = normalized[0 .. normalized.len - 1];
    }
    return normalized;
}

fn hasEquivalentRoot(accepted: []const PreparedRoot, candidate: PreparedRoot) bool {
    for (accepted) |root| {
        if (std.mem.eql(u8, root.comparable, candidate.comparable)) return true;
    }
    return false;
}

fn isContainedByAcceptedRoot(accepted: []const PreparedRoot, candidate: PreparedRoot) bool {
    for (accepted) |root| {
        if (isContainedBy(root, candidate)) return true;
    }
    return false;
}

fn isContainedBy(parent: PreparedRoot, candidate: PreparedRoot) bool {
    if (!parent.is_directory) return false;
    if (std.mem.eql(u8, parent.comparable, candidate.comparable)) return true;
    if (candidate.comparable.len <= parent.comparable.len) return false;
    if (!std.mem.startsWith(u8, candidate.comparable, parent.comparable)) return false;
    return candidate.comparable[parent.comparable.len] == '/';
}

fn refreshStats(report: *SearchReport) void {
    const memory_snapshot = process_memory.currentProcessSnapshot();
    report.scan_file_ms_total = report.scan_file_mmap_ms_total + report.scan_file_buffered_ms_total;
    report.stats.input_roots = report.input_roots;
    report.stats.effective_roots = report.effective_roots;
    report.stats.pruned_roots = report.pruned_roots;
    report.stats.overlap_pruned_roots = report.overlap_pruned_roots;
    report.stats.discovered_duplicate_paths = report.discovered_duplicate_paths;
    report.stats.files_discovered = report.files_discovered;
    report.stats.files_scanned = report.files_scanned;
    report.stats.files_skipped = report.files_skipped;
    report.stats.matches_found = report.matches_found;
    report.stats.bytes_scanned = report.bytes_scanned;
    report.stats.linux_strategy = .{
        .selector_eligible = false,
        .current_strategy = "materialized",
        .matcher_strategy_supported = report.matcher_strategy_supported,
        .effective_roots = report.effective_roots,
        .directory_roots = 0,
        .root_entry_count = 0,
        .files_discovered = report.files_discovered,
        .collect_hits = report.collect_hits,
        .outer_parallel_shard_safe = report.outer_parallel_shard_safe,
    };
    report.stats.timings = .{
        .discover_ms = report.discover_ms,
        .scan_ms = report.scan_ms,
        .aggregate_ms = report.aggregate_ms,
        .total_ms = report.total_ms,
        .scan_work_ms_total = report.scan_work_ms_total,
        .scan_open_ms_total = report.scan_open_ms_total,
        .scan_file_ms_total = report.scan_file_ms_total,
        .scan_file_mmap_ms_total = report.scan_file_mmap_ms_total,
        .scan_file_buffered_ms_total = report.scan_file_buffered_ms_total,
        .aggregate_merge_ms = report.aggregate_ms,
        .aggregate_finalize_ms = 0,
    };
    report.stats.process_memory = .{
        .available = memory_snapshot.available,
        .current_resident_bytes = memory_snapshot.current_resident_bytes,
        .peak_resident_bytes = memory_snapshot.peak_resident_bytes,
        .allocation_limit_bytes = resource_profile.memoryLimitBytes(),
    };
    const byte_sharded = report.stats.byte_shard_kernel.enabled;
    const byte_shard_ranges = if (report.stats.byte_shard_kernel.files_profiled > 0)
        report.stats.byte_shard_kernel.range_calls / report.stats.byte_shard_kernel.files_profiled
    else
        0;
    const byte_shard_chunk = if (report.stats.byte_shard_kernel.range_calls > 0)
        report.stats.byte_shard_kernel.logical_range_bytes / report.stats.byte_shard_kernel.range_calls
    else
        0;
    report.stats.concurrency = .{
        .available_threads = report.available_threads,
        .thread_limit = resource_profile.threadLimit(report.available_threads),
        .outer_scan_threads = report.outer_scan_threads,
        .execution_mode = if (byte_sharded) "byte_sharded" else "materialized",
        .resource_policy = "hardware_percent",
        .scan_input_policy = report.scan_input_policy.label(),
        .sharding_enabled = byte_sharded,
        .sharded_files = report.stats.byte_shard_kernel.files_profiled,
        .max_shard_threads = byte_shard_ranges,
        .max_shard_ranges = byte_shard_ranges,
        .max_shard_chunk_bytes = byte_shard_chunk,
    };
    if (report.stats.slowest_file_count == 0) {
        const linux_dominant_target = report.capture_linux_dominant_attribution and
            report.slowest_bytes >= report.stats.linux_dominant_file.min_bytes and
            isLinuxDominantFilePath(report.slowest_path);
        report.stats.recordSlowFile(report.slowest_path, report.slowest_ms, report.slowest_bytes, linux_dominant_target);
    }
}

fn initTrigramStats(stats: *core_stats.TrigramAccelerationStats, admission: trigram.Admission, case_insensitive: bool) void {
    stats.* = .{};
    if (!admission.eligible or case_insensitive) return;
    stats.eligible = true;
    stats.mode = if (admission.mode == .any) "any" else "all";
    stats.mandatory_groups = admission.group_count;
    for (admission.groups[0..admission.group_count]) |group| {
        stats.mandatory_trigrams += group.trigram_count;
    }
}

fn mergeTrigramStats(target: *core_stats.TrigramAccelerationStats, source: core_stats.TrigramAccelerationStats) void {
    target.candidate_files_checked += source.candidate_files_checked;
    target.pruned_files += source.pruned_files;
    target.verified_files += source.verified_files;
    target.ineligible_files += source.ineligible_files;
}

fn mergeRegexDecompositionStats(target: *core_stats.RegexDecompositionStats, source: core_stats.RegexDecompositionStats) void {
    target.eligible_files += source.eligible_files;
    target.counted_files += source.counted_files;
    target.bailout_files += source.bailout_files;
    target.candidate_lines_checked += source.candidate_lines_checked;
    target.duplicate_candidate_hits_skipped += source.duplicate_candidate_hits_skipped;
    target.candidate_lines_matched += source.candidate_lines_matched;
}

fn mergeByteShardStats(target: *core_stats.ByteShardKernelStats, source: core_stats.ByteShardKernelStats) void {
    target.enabled = target.enabled or source.enabled;
    if (source.enabled) target.strategy = source.strategy;
    target.files_profiled += source.files_profiled;
    target.range_calls += source.range_calls;
    target.line_aligned_ranges += source.line_aligned_ranges;
    target.logical_range_bytes += source.logical_range_bytes;
    target.widened_range_bytes += source.widened_range_bytes;
    target.overlap_bytes += source.overlap_bytes;
    target.boundary_verified_candidates += source.boundary_verified_candidates;
    target.boundary_rejected_candidates += source.boundary_rejected_candidates;
    target.range_elapsed_ns_total += source.range_elapsed_ns_total;
    target.max_range_elapsed_ns = @max(target.max_range_elapsed_ns, source.max_range_elapsed_ns);
    target.reduce_elapsed_ns_total += source.reduce_elapsed_ns_total;
    target.max_reduce_elapsed_ns = @max(target.max_reduce_elapsed_ns, source.max_reduce_elapsed_ns);
    target.matches += source.matches;
}

fn mergeLinuxDominantFileStats(target: *core_stats.LinuxDominantFileStats, source: core_stats.LinuxDominantFileStats) void {
    target.targeted_files_scanned += source.targeted_files_scanned;
    target.targeted_bytes_scanned += source.targeted_bytes_scanned;
    target.targeted_slowest_files += source.targeted_slowest_files;
    target.targeted_slowest_bytes += source.targeted_slowest_bytes;
    target.eligible_files += source.eligible_files;
    target.activated_files += source.activated_files;
    target.bailout_files += source.bailout_files;
    target.max_shard_threads = @max(target.max_shard_threads, source.max_shard_threads);
    target.max_range_count = @max(target.max_range_count, source.max_range_count);
    target.max_chunk_bytes = @max(target.max_chunk_bytes, source.max_chunk_bytes);
}

fn tryTrigramPruneFile(
    bytes: []const u8,
    program: *const TrigramAdmissionProgram,
    stats: *core_stats.TrigramAccelerationStats,
) bool {
    stats.candidate_files_checked += 1;
    if (program.mayMatch(bytes)) {
        stats.verified_files += 1;
        return false;
    }
    stats.pruned_files += 1;
    return true;
}

fn shouldAttemptWholeFileAdmission(whole_file_available: bool, _: bool, program: *const TrigramAdmissionProgram) bool {
    return whole_file_available and program.fileAdmissionEnabled();
}

fn shouldAttemptTrigramPrune(file_bytes: usize, single_chunk: bool, admission: trigram.Admission, _: bool) bool {
    return admission.eligible and single_chunk and file_bytes >= TRIGRAM_MIN_PRUNE_BYTES;
}

/// FM-Index backward-search admission (spec point 11).
///
/// For single-literal patterns on small files (< 16 KiB), builds an in-memory
/// BWT + FM-Index and uses O(p) backward search to determine if the pattern
/// exists. If absent, prunes the file without entering the line-scan path.
///
/// This is the integration point between the FM-Index module and the scan
/// pipeline. Enabled by default (IX_FM_INDEX_ADMISSION=0 disables). The
/// O(n log n) suffix array sort at build time is amortized across the
/// per-file admission check — for small files (≤16 KiB) the BWT build +
/// backward search is faster than a full line-scan for absent patterns.
/// For multi-chunk files or files >16 KiB, the FM-Index is skipped and
/// the standard scan path runs.
///
/// Returns true if the file was pruned (pattern guaranteed absent).
fn tryFmIndexAdmission(
    allocator: std.mem.Allocator,
    data: []const u8,
    plan: expr.ExpressionPlan,
) bool {
    if (data.len == 0 or data.len > FM_INDEX_ADMISSION_MAX_BYTES) return false;
    if (plan.predicate_count != 1) return false;
    const predicate = plan.predicates[0];
    // Only single-literal patterns are eligible.
    const needle = switch (predicate.kind) {
        .literal, .prefix, .suffix => predicate.value,
        .regex => switch (predicate.strategy) {
            .regex_plain_literal => predicate.value,
            else => return false,
        },
    };
    if (needle.len == 0 or needle.len > 64) return false;

    // The FM-Index text cannot contain the sentinel byte (0x00).
    // Binary files are already skipped before this point, but check anyway.
    for (data) |b| {
        if (b == 0) return false;
    }

    var fmi = fm_index.buildFMIndex(allocator, data) catch return false;
    defer fmi.deinit();

    return !fmi.contains(needle);
}

/// Fast CR trim: single-byte branch instead of std.mem.trimEnd's scalar
/// scan-from-end loop. std.mem.trimEnd scans backwards past ALL trailing
/// characters in the set — for "\r" that's at most 1 byte, but it still
/// enters a loop. This is a 1-cycle branch on the hot per-line path.
inline fn trimCR(raw_line: []const u8) []const u8 {
    if (raw_line.len > 0 and raw_line[raw_line.len - 1] == '\r') return raw_line[0 .. raw_line.len - 1];
    return raw_line;
}

/// Materializes the canonical hit and records how its compact preview maps back to source bytes.
fn makeSearchHit(
    allocator: std.mem.Allocator,
    path: []const u8,
    line_number: usize,
    column: usize,
    line: []const u8,
    span: preview.MatchSpan,
) !SearchHit {
    const compact = try preview.make(allocator, line, span);
    return .{
        .path = path,
        .line = line_number,
        .column = column,
        .preview = compact.text,
        .match_len = span.end - span.start,
        .preview_start = compact.source_start,
        .preview_end = compact.source_end,
        .preview_elided_left = compact.elided_left,
        .preview_elided_right = compact.elided_right,
    };
}

/// Resolves the exact span belonging to the earliest predicate column selected by the expression plan.
fn exactMatchSpan(line: []const u8, plan: expr.ExpressionPlan, case_insensitive: bool, column: usize) preview.MatchSpan {
    const start = column - 1;
    var best = preview.MatchSpan{ .start = start, .end = start };
    var found = false;
    for (plan.predicates[0..plan.predicate_count]) |predicate| {
        const predicate_column = predicateColumn(line, predicate, case_insensitive) orelse continue;
        if (predicate_column != column) continue;
        const candidate = predicateSpanAtColumn(line, predicate, case_insensitive, column);
        if (!found or candidate.end < best.end) {
            best = candidate;
            found = true;
        }
    }
    return best;
}

/// Converts a proved predicate column into its exact byte extent, using the regex ovector for variable-width matches.
fn predicateSpanAtColumn(line: []const u8, predicate: expr.Predicate, case_insensitive: bool, column: usize) preview.MatchSpan {
    const start = column - 1;
    const literal_end = switch (predicate.kind) {
        .literal, .prefix, .suffix => @min(line.len, start + predicate.value.len),
        .regex => regexLiteralEnd(line, predicate, start) orelse {
            const matched: ?preview.MatchSpan = if (pcre_regex.span(line, predicate.value, case_insensitive) catch null) |value|
                .{ .start = value.start, .end = value.end }
            else if (regex.span(line, predicate.value, case_insensitive)) |value|
                .{ .start = value.start, .end = value.end }
            else
                null;
            if (matched) |value| {
                if (value.start == start) return .{ .start = value.start, .end = value.end };
            }
            return .{ .start = start, .end = start };
        },
    };
    return .{ .start = start, .end = literal_end };
}

/// Returns exact lengths for regex strategies whose matched body is already classified as one literal.
fn regexLiteralEnd(line: []const u8, predicate: expr.Predicate, start: usize) ?usize {
    const body: ?[]const u8 = switch (predicate.strategy) {
        .regex_plain_literal => if (std.mem.indexOfScalar(u8, predicate.value, '\\') == null) predicate.value else null,
        .regex_ascii_casefold_literal => blk: {
            const value = if (std.mem.startsWith(u8, predicate.value, "(?i)")) predicate.value[4..] else predicate.value;
            break :blk if (std.mem.indexOfScalar(u8, value, '\\') == null) value else null;
        },
        .regex_word_boundary_literal => expr.stripWordBoundaryAnchors(predicate.value),
        .regex_ascii_casefold_word_boundary_literal => blk: {
            const value = if (std.mem.startsWith(u8, predicate.value, "(?i)")) predicate.value[4..] else predicate.value;
            break :blk expr.stripWordBoundaryAnchors(value);
        },
        else => null,
    };
    const literal = body orelse return null;
    return @min(line.len, start + literal.len);
}

/// Filters canonical hits at the scan boundary so cursor pages never repeat the prior terminal key.
fn isAfterCursor(request: cli.SearchRequest, path: []const u8, line: usize, column: usize) bool {
    const after_path = request.cursor_path orelse return true;
    return search_cursor.keyAfter(path, line, column, .{
        .corpus_signature = request.cursor_corpus_signature orelse 0,
        .request_fingerprint = request.cursor_request_fingerprint orelse 0,
        .path = after_path,
        .line = request.cursor_line,
        .column = request.cursor_column,
    });
}

fn availableThreads() usize {
    return std.Thread.getCpuCount() catch 1;
}

/// Core per-file scan loop. Reads the file in 1 MiB chunks, splits into
/// lines, and runs predicate matching on each line.
///
/// Serial-path per-file scan (non-parallel reports, e.g. inspect mode).
///
/// Single-chunk files (<=1 MiB) use a stack-allocated read buffer -- one
/// ReadFile syscall, warm L2/L3 cache for the SIMD scan. Multi-chunk
/// files dispatch to scanFileMmap for zero-copy access via
/// NtCreateSection/NtMapViewOfSection.
///
/// THE CARRY BUFFER (multi-chunk fallback):
/// Lines can span chunk boundaries. The `carry` ArrayList accumulates
/// partial line bytes across chunks. When a newline is found,
/// carry + current chunk segment form the complete line.
fn scanOpenFile(
    io: std.Io,
    allocator: std.mem.Allocator,
    file: std.Io.File,
    display_path: []const u8,
    request: cli.SearchRequest,
    plan: expr.ExpressionPlan,
    trigram_admission: trigram.Admission,
    trigram_program: *const TrigramAdmissionProgram,
    report: *SearchReport,
    file_started: std.Io.Timestamp,
) anyerror!void {
    const read_buffer = report.scan_buffer;
    if (read_buffer.len != SCAN_READ_BUFFER_SIZE) return error.OutOfMemory;

    // Read first chunk before length lookup. Single-shot positional read avoids
    // the retry syscall that readPositionalAll pays on sub-1MiB files.
    const first_read = try file.readPositional(io, &.{read_buffer}, 0);
    if (first_read == 0) {
        report.files_scanned += 1;
        try recordLine(allocator, display_path, "", 1, request, plan, report, false);
        const file_ms = elapsedMs(io, file_started);
        recordReportScanFileBufferedMs(report, file_ms);
        if (file_ms >= report.slowest_ms) report.slowest_ms = file_ms;
        return;
    }
    if (simd.indexOfByte(read_buffer[0..@min(1024, first_read)], 0) != null) {
        report.files_skipped += 1;
        report.stats.admission.binary_entries_skipped += 1;
        report.stats.admission.binary_file_bytes += @intCast(first_read);
        return;
    }
    const single_chunk = first_read < read_buffer.len;
    const file_bytes: usize = if (single_chunk) first_read else @intCast(try file.length(io));

    if (!single_chunk and report.scan_input_policy.shouldAttemptMmap() and trySerialMmapFastPath(io, allocator, file, display_path, request, plan, trigram_admission, trigram_program, report, file_started)) {
        return;
    }

    report.files_scanned += 1;
    report.bytes_scanned += file_bytes;
    if (file_bytes >= report.slowest_bytes) {
        report.slowest_path = display_path;
        report.slowest_bytes = file_bytes;
    }
    if (shouldAttemptWholeFileAdmission(single_chunk, request.case_insensitive, trigram_program)) {
        if (trigram_program.needsCasefold()) {
            // Single SIMD byteset scan replaces per-needle indexOfByte loop.
            if (trigram_program.first_byte_set_populated and
                sz.indexOfByteSet(read_buffer[0..first_read], &trigram_program.first_byte_set) == null)
            {
                report.files_skipped += 1;
                const file_ms = elapsedMs(io, file_started);
                recordReportScanFileBufferedMs(report, file_ms);
                if (file_ms >= report.slowest_ms) report.slowest_ms = file_ms;
                return;
            }
            asciiLowerBuf(read_buffer[0..first_read], read_buffer[0..first_read]);
        }
        if (trigram_program.fileAdmissionMiss(read_buffer[0..first_read])) {
            const file_ms = elapsedMs(io, file_started);
            recordReportScanFileBufferedMs(report, file_ms);
            if (file_ms >= report.slowest_ms) report.slowest_ms = file_ms;
            return;
        }
    }
    const literal_admission_satisfied =
        shouldAttemptWholeFileAdmission(single_chunk, request.case_insensitive, trigram_program) and
        search_admission.predicateAdmissionGroupRuntimeCaseSensitive(plan.predicates[0]) != null;
    if (!shouldSkipTrigramAfterLiteralAdmission(plan, literal_admission_satisfied) and
        shouldAttemptTrigramPrune(file_bytes, single_chunk, trigram_admission, request.case_insensitive) and
        tryTrigramPruneFile(read_buffer[0..first_read], trigram_program, &report.stats.trigram_acceleration))
    {
        const file_ms = elapsedMs(io, file_started);
        recordReportScanFileBufferedMs(report, file_ms);
        if (file_ms >= report.slowest_ms) report.slowest_ms = file_ms;
        return;
    }

    // CHUNK CASEFOLD: same buffered-path optimization as above for serial scan.
    const chunk_casefold = request.stats_only and planIsFullyCasefoldLiteral(plan);
    const alternates_full_scan_casefold = request.stats_only and
        single_chunk and
        first_read >= WHOLE_BUFFER_ALTERNATES_CASEFOLD_MIN_BYTES and
        planIsCasefoldLiteralAlternates(plan, request.case_insensitive);
    // Casefold the first chunk in-place after binary sniff confirms it is text.
    if (chunk_casefold or alternates_full_scan_casefold) {
        asciiLowerBuf(read_buffer[0..first_read], read_buffer[0..first_read]);
    }

    // WHOLE-BUFFER FAST COUNT (serial path): same optimization as parallel path.
    if (request.stats_only and single_chunk) {
        const whole_buffer_casefolded = chunk_casefold or alternates_full_scan_casefold;
        const ci = if (whole_buffer_casefolded) false else request.case_insensitive;
        if (wholeBufferFastCount(read_buffer[0..first_read], plan, ci, whole_buffer_casefolded)) |count| {
            report.matches_found += count;
            if (plan.predicate_count == 1) {
                const predicate = plan.predicates[0];
                if (predicate.kind == .regex and predicate.strategy == .regex_literal_alternates) {
                    report.stats.fast_count_density.alternate_full_scan_calls += 1;
                    report.stats.fast_count_density.alternate_full_scan_bytes += first_read;
                    report.stats.fast_count_density.alternate_full_scan_matches += count;
                    report.stats.fast_count_density.alternate_matches += count;
                }
            }
            const file_ms = elapsedMs(io, file_started);
            recordReportScanFileBufferedMs(report, file_ms);
            if (file_ms >= report.slowest_ms) report.slowest_ms = file_ms;
            return;
        }
    }

    var carry: std.ArrayList(u8) = .empty;
    defer carry.deinit(allocator);
    var line_number: usize = 1;
    var ended_with_newline = false;
    const chunk_prefilter_group: ?search_admission.FileAdmissionGroup = if (!request.case_insensitive)
        search_admission.predicateAdmissionGroupRuntimeCaseSensitive(plan.predicates[0])
    else
        null;

    // Process first chunk then any remaining chunks (most files fit in one chunk).
    // HOT PATH: simd.indexOfByte uses AVX2 VPCMPEQB -- 32 bytes/cycle vs 1 byte/cycle scalar.
    var chunk: []const u8 = read_buffer[0..first_read];
    var offset: u64 = first_read;
    while (true) {
        ended_with_newline = chunk[chunk.len - 1] == '\n';
        if (chunk_prefilter_group) |group| {
            if (carry.items.len == 0 and group.isMiss(chunk)) {
                if (!request.stats_only) {
                    line_number += std.mem.count(u8, chunk, "\n");
                }
                if (!ended_with_newline) {
                    if (std.mem.lastIndexOfScalar(u8, chunk, '\n')) |last_nl| {
                        try carry.appendSlice(allocator, chunk[last_nl + 1 ..]);
                    } else {
                        try carry.appendSlice(allocator, chunk);
                    }
                }
                if (offset >= file_bytes) break;
                const remaining = file_bytes - @as(usize, @intCast(offset));
                const target_len: usize = @intCast(@min(read_buffer.len, remaining));
                const read_len = try file.readPositionalAll(io, read_buffer[0..target_len], offset);
                if (read_len == 0) break;
                offset += read_len;
                chunk = read_buffer[0..read_len];
                if (chunk_casefold) asciiLowerBuf(read_buffer[0..read_len], read_buffer[0..read_len]);
                continue;
            }
        }
        var chunk_index: usize = 0;
        while (chunk_index < chunk.len) {
            if (simd.indexOfByte(chunk[chunk_index..], '\n')) |relative_newline| {
                const line_part = chunk[chunk_index .. chunk_index + relative_newline];
                if (carry.items.len == 0) {
                    try recordLine(allocator, display_path, line_part, line_number, request, plan, report, chunk_casefold);
                } else {
                    try carry.appendSlice(allocator, line_part);
                    try recordLine(allocator, display_path, carry.items, line_number, request, plan, report, chunk_casefold);
                    carry.clearRetainingCapacity();
                }
                if (report.truncated) break;
                line_number += 1;
                chunk_index += relative_newline + 1;
            } else {
                try carry.appendSlice(allocator, chunk[chunk_index..]);
                break;
            }
        }
        if (report.truncated or offset >= file_bytes) break;
        // Read next chunk -- only for files > 1 MiB.
        const remaining = file_bytes - @as(usize, @intCast(offset));
        const target_len: usize = @intCast(@min(read_buffer.len, remaining));
        const read_len = try file.readPositionalAll(io, read_buffer[0..target_len], offset);
        if (read_len == 0) break;
        offset += read_len;
        chunk = read_buffer[0..read_len];
        // Casefold each subsequent chunk in-place for the same amortised benefit.
        if (chunk_casefold) asciiLowerBuf(read_buffer[0..read_len], read_buffer[0..read_len]);
    }

    if (!report.truncated and (carry.items.len > 0 or ended_with_newline)) {
        try recordLine(allocator, display_path, carry.items, line_number, request, plan, report, chunk_casefold);
    }
    const file_ms = elapsedMs(io, file_started);
    recordReportScanFileBufferedMs(report, file_ms);
    if (file_ms >= report.slowest_ms) report.slowest_ms = file_ms;
}

fn recordLine(
    allocator: std.mem.Allocator,
    display_path: []const u8,
    raw_line: []const u8,
    line_number: usize,
    request: cli.SearchRequest,
    plan: expr.ExpressionPlan,
    report: *SearchReport,
    chunk_casefolded: bool,
) !void {
    const line = trimCR(raw_line);
    report.scope_tracker.processLine(line, line_number);
    if (request.stats_only) {
        const ci = if (chunk_casefolded) false else request.case_insensitive;
        const count = statsOnlyMatchCount(line, plan, ci, chunk_casefolded);
        report.matches_found += count;
        return;
    }
    if (matchingColumn(line, plan, request.case_insensitive)) |column| {
        report.matches_found += 1;
        if (!isAfterCursor(request, display_path, line_number, column)) return;
        report.matches_after_cursor += 1;
        const under_request_limit = if (request.max_hits) |max_hits| report.hit_count < max_hits else true;
        if (!request.stats_only and under_request_limit and report.hit_count < MAX_RETAINED_HITS) {
            const sc = report.scope_tracker.currentScope();
            if (shouldDedupByRecord(request, &report.last_record_scope_line, sc.name, sc.line)) return;
            const span = exactMatchSpan(line, plan, request.case_insensitive, column);
            report.hits[report.hit_count] = try makeSearchHit(allocator, display_path, line_number, column, line, span);
            report.hits[report.hit_count].scope = if (sc.name.len > 0) try allocator.dupe(u8, sc.name) else "";
            report.hits[report.hit_count].scope_line = sc.line;
            report.last_record_scope_line = sc.line;
            report.hit_count += 1;
        } else {
            report.truncated = true;
        }
    }
}

/// Extracts a mandatory literal needle suitable for chunk-level prefiltering.
/// Returns null when the predicate cannot be reduced to a simple substring
/// test (case-insensitive, character classes, alternation, etc.).
///
/// For literals: the literal value itself.
/// For regex_plain_literal: the literal value (no metachar escapes).
/// For regex_full: the longest literal fragment extracted at runtime.
/// For regex_word_boundary_literal: the word body (stripped of \b anchors).
/// Returns true when the plan has exactly one predicate that is a
/// case-insensitive ASCII literal (strategy regex_ascii_casefold_literal)
/// whose body is already all-lowercase.  When true the scan engine may
/// casefold the chunk buffer in-place once per file rather than casefolding
/// every line individually, saving ~100k function calls on a 500-file corpus.
/// Restricted to single-predicate plans so the multi-predicate matchingColumn
/// path does not need a chunk_casefolded parameter.
fn planIsFullyCasefoldLiteral(plan: expr.ExpressionPlan) bool {
    if (plan.predicate_count != 1) return false;
    const pred = plan.predicates[0];
    if (pred.kind != .regex) return false;
    if (pred.strategy != .regex_ascii_casefold_literal) return false;
    const body = if (std.mem.startsWith(u8, pred.value, "(?i)")) pred.value[4..] else pred.value;
    for (body) |c| if (c >= 'A' and c <= 'Z') return false;
    return true;
}

fn planIsCasefoldLiteralAlternates(plan: expr.ExpressionPlan, request_case_insensitive: bool) bool {
    if (plan.predicate_count != 1) return false;
    const pred = plan.predicates[0];
    if (pred.kind != .regex or pred.strategy != .regex_literal_alternates) return false;
    const effective_ci = request_case_insensitive or std.mem.startsWith(u8, pred.value, "(?i)");
    if (!effective_ci) return false;
    const body = expr.literalAlternatesBody(pred.value);
    for (body) |c| if (c > 0x7F) return false;
    return true;
}

/// Counts eligible stats-only predicates over the complete file buffer.
/// Returns null when line context or boolean plan semantics are required.
fn wholeBufferFastCount(buffer: []const u8, plan: expr.ExpressionPlan, case_insensitive: bool, chunk_casefolded: bool) ?usize {
    if (plan.predicate_count != 1) return null;
    const pred = plan.predicates[0];
    return switch (pred.kind) {
        .literal => countLiteral(buffer, pred.value, case_insensitive),
        .regex => wholeBufferRegexCount(buffer, pred, case_insensitive, chunk_casefolded),
        .prefix, .suffix => null,
    };
}

fn wholeBufferRegexCount(buffer: []const u8, predicate: expr.Predicate, case_insensitive: bool, chunk_casefolded: bool) ?usize {
    return switch (predicate.strategy) {
        .regex_plain_literal => blk: {
            if (std.mem.indexOfScalar(u8, predicate.value, '\\') == null) {
                break :blk countLiteral(buffer, predicate.value, case_insensitive);
            }
            break :blk countRegexLiteral(buffer, predicate.value, case_insensitive);
        },
        .regex_ascii_casefold_literal => blk: {
            const body = if (std.mem.startsWith(u8, predicate.value, "(?i)")) predicate.value[4..] else predicate.value;
            const effective_ci = if (chunk_casefolded) false else true;
            if (std.mem.indexOfScalar(u8, body, '\\') == null) {
                break :blk countLiteral(buffer, body, effective_ci);
            }
            break :blk countRegexLiteral(buffer, body, effective_ci);
        },
        .regex_word_boundary_literal => blk: {
            if (case_insensitive) break :blk null;
            break :blk countWordBoundaryLiteralLines(buffer, expr.stripWordBoundaryAnchors(predicate.value));
        },
        .regex_ascii_casefold_word_boundary_literal => blk: {
            if (!chunk_casefolded) break :blk null;
            const after_flag = if (std.mem.startsWith(u8, predicate.value, "(?i)")) predicate.value[4..] else predicate.value;
            break :blk countWordBoundaryLiteralLines(buffer, expr.stripWordBoundaryAnchors(after_flag));
        },
        .regex_literal_alternates => blk: {
            const effective_ci = case_insensitive or std.mem.startsWith(u8, predicate.value, "(?i)");
            const body = expr.literalAlternatesBody(predicate.value);
            if (chunk_casefolded and effective_ci) {
                break :blk countLiteralAlternatesCasefoldedHaystack(buffer, body);
            }
            break :blk countLiteralAlternates(buffer, body, effective_ci);
        },
        else => null,
    };
}

fn regexDecompositionFastCount(
    buffer: []const u8,
    plan: expr.ExpressionPlan,
    case_insensitive: bool,
    stats: *core_stats.RegexDecompositionStats,
    acceleration_bailouts: *usize,
) ?usize {
    if (case_insensitive or plan.predicate_count != 1) return null;
    const predicate = plan.predicates[0];
    if (predicate.kind != .regex) return null;
    const needle = byte_shard.regexDecompositionNeedle(predicate.value) orelse return null;

    stats.eligible_files += 1;
    var count: usize = 0;
    var search_pos: usize = 0;
    var checked_this_file: usize = 0;
    var last_line_start: ?usize = null;
    while (search_pos < buffer.len) {
        const relative = simd.indexOf(buffer[search_pos..], needle) orelse break;
        const candidate_start = search_pos + relative;
        const line_start = lineStartForOffset(buffer, candidate_start);
        search_pos = @min(candidate_start + needle.len, buffer.len);

        if (last_line_start != null and last_line_start.? == line_start) {
            stats.duplicate_candidate_hits_skipped += 1;
            continue;
        }
        if (checked_this_file == REGEX_DECOMPOSITION_MAX_CANDIDATE_LINES) {
            stats.bailout_files += 1;
            acceleration_bailouts.* += 1;
            return null;
        }

        checked_this_file += 1;
        stats.candidate_lines_checked += 1;
        const line_end = lineEndForOffset(buffer, candidate_start);
        const raw_line = buffer[line_start..line_end];
        const line = trimCR(raw_line);
        if (regexLineMatches(line, predicate.value)) {
            count += 1;
            stats.candidate_lines_matched += 1;
        }
        last_line_start = line_start;
    }

    stats.counted_files += 1;
    return count;
}

fn lineStartForOffset(buffer: []const u8, offset: usize) usize {
    var index = @min(offset, buffer.len);
    while (index > 0 and buffer[index - 1] != '\n') : (index -= 1) {}
    return index;
}

fn lineEndForOffset(buffer: []const u8, offset: usize) usize {
    var index = @min(offset, buffer.len);
    while (index < buffer.len and buffer[index] != '\n') : (index += 1) {}
    return index;
}

fn regexLineMatches(line: []const u8, pattern: []const u8) bool {
    const column = pcre_regex.column(line, pattern, false) catch
        regex.column(line, pattern, false);
    return column != null;
}

/// Stats-only mode counts matches without retaining hit records.
/// For single-predicate plans, it counts occurrences (a line with 3 matches
/// reports 3, not 1). For multi-predicate plans, it falls back to boolean
/// match -- the line either matches all/any predicates or it doesn't.
/// This distinction matters for Rust parity: `ix search --stats-only "lit:ERROR"`
/// must report the same occurrence count as the Rust binary.
///
/// chunk_casefolded: the line bytes were already lowercased in the chunk
/// buffer -- skip per-line casefold and use case-sensitive matching directly.
fn statsOnlyMatchCount(line: []const u8, plan: expr.ExpressionPlan, case_insensitive: bool, chunk_casefolded: bool) usize {
    if (plan.predicate_count == 1) {
        return predicateMatchCount(line, plan.predicates[0], case_insensitive, chunk_casefolded);
    }
    return if (statsOnlyPlanMatches(line, plan, case_insensitive)) 1 else 0;
}

fn statsOnlyPlanMatches(line: []const u8, plan: expr.ExpressionPlan, case_insensitive: bool) bool {
    const predicates = plan.predicates[0..plan.predicate_count];
    return switch (plan.mode) {
        .all => allPredicatesMatch(line, predicates, case_insensitive),
        .any => anyPredicateMatches(line, predicates, case_insensitive),
    };
}

fn predicateMatchCount(line: []const u8, predicate: expr.Predicate, case_insensitive: bool, chunk_casefolded: bool) usize {
    return switch (predicate.kind) {
        .literal => countLiteral(line, predicate.value, case_insensitive),
        .regex => predicateMatchCountByStrategy(line, predicate, case_insensitive, chunk_casefolded),
        .prefix, .suffix => if (predicateMatches(line, predicate, case_insensitive)) 1 else 0,
    };
}

/// Comptime-specialized match count for monomorphized single-predicate path.
fn predicateMatchCountMono(comptime kind: expr.PredicateKind, comptime strategy: expr.MatcherStrategy, line: []const u8, predicate: expr.Predicate, case_insensitive: bool, chunk_casefolded: bool) usize {
    return switch (kind) {
        .literal => countLiteral(line, predicate.value, case_insensitive),
        .regex => predicateMatchCountByStrategyMono(strategy, line, predicate, case_insensitive, chunk_casefolded),
        .prefix, .suffix => if (predicateColumnMono(kind, strategy, line, predicate, case_insensitive) != null) 1 else 0,
    };
}

fn countRegexStatsOnly(line: []const u8, pattern: []const u8, case_insensitive: bool) usize {
    if (isSurroundingWordLiteralPattern(pattern)) {
        const col = pcre_regex.column(line, pattern, case_insensitive) catch
            regex.column(line, pattern, case_insensitive);
        return if (col != null) 1 else 0;
    }
    return pcre_regex.count(line, pattern, case_insensitive) catch
        regex.count(line, pattern, case_insensitive);
}

/// Comptime-specialized match count dispatch for stats-only mode.
/// chunk_casefolded: line bytes already lowercased in-place -> skip per-line casefold.
fn predicateMatchCountByStrategyMono(comptime strategy: expr.MatcherStrategy, line: []const u8, predicate: expr.Predicate, case_insensitive: bool, chunk_casefolded: bool) usize {
    return switch (strategy) {
        .regex_plain_literal => blk: {
            if (std.mem.indexOfScalar(u8, predicate.value, '\\') == null) {
                break :blk countLiteral(line, predicate.value, case_insensitive);
            }
            break :blk countRegexLiteral(line, predicate.value, case_insensitive);
        },
        .regex_ascii_casefold_literal => blk: {
            const body = if (std.mem.startsWith(u8, predicate.value, "(?i)")) predicate.value[4..] else predicate.value;
            const effective_ci = if (chunk_casefolded) false else true;
            if (std.mem.indexOfScalar(u8, body, '\\') == null) {
                break :blk countLiteral(line, body, effective_ci);
            }
            break :blk countRegexLiteral(line, body, effective_ci);
        },
        .regex_word_boundary_literal => if (wordBoundaryLiteralColumn(line, expr.stripWordBoundaryAnchors(predicate.value), case_insensitive) != null) 1 else 0,
        .regex_ascii_casefold_word_boundary_literal => blk: {
            const after_flag = if (std.mem.startsWith(u8, predicate.value, "(?i)")) predicate.value[4..] else predicate.value;
            const effective_ci = if (chunk_casefolded) false else true;
            break :blk if (wordBoundaryLiteralColumn(line, expr.stripWordBoundaryAnchors(after_flag), effective_ci) != null) 1 else 0;
        },
        .regex_literal_alternates => blk: {
            const effective_ci = case_insensitive or std.mem.startsWith(u8, predicate.value, "(?i)");
            const body = expr.literalAlternatesBody(predicate.value);
            if (chunk_casefolded and effective_ci) {
                break :blk countLiteralAlternatesCasefoldedHaystack(line, body);
            }
            break :blk countLiteralAlternates(line, body, effective_ci);
        },
        else => countRegexWithPrefilter(line, predicate.value, case_insensitive),
    };
}

/// Runtime dispatch wrapper -- inline else forwards to comptime-specialized Mono.
fn predicateMatchCountByStrategy(line: []const u8, predicate: expr.Predicate, case_insensitive: bool, chunk_casefolded: bool) usize {
    return switch (predicate.strategy) {
        inline else => |strategy| predicateMatchCountByStrategyMono(strategy, line, predicate, case_insensitive, chunk_casefolded),
    };
}

fn countRegexWithPrefilter(line: []const u8, pattern: []const u8, case_insensitive: bool) usize {
    if (fixedWordWhitespaceChain(pattern)) |chain| {
        return countFixedWordWhitespaceChain(line, chain);
    }

    const cached = cachedLiteralFragment(pattern);
    if (cached.len >= 2) {
        if (indexOfLiteral(line, cached, case_insensitive) == null) return 0;
    }
    return countRegexStatsOnly(line, pattern, case_insensitive);
}

fn isSurroundingWordLiteralPattern(pattern: []const u8) bool {
    return std.mem.startsWith(u8, pattern, "\\w+\\s+") and std.mem.endsWith(u8, pattern, "\\s+\\w+");
}

const FIXED_WORD_CHAIN_MAX_PARTS = 16;

const FixedWordWhitespaceChain = struct {
    word_lens: [FIXED_WORD_CHAIN_MAX_PARTS]usize = undefined,
    count: usize = 0,
};

fn fixedWordWhitespaceChain(pattern: []const u8) ?FixedWordWhitespaceChain {
    var parsed: FixedWordWhitespaceChain = .{};
    var index: usize = 0;

    while (index < pattern.len) {
        if (parsed.count == FIXED_WORD_CHAIN_MAX_PARTS) return null;
        if (index + 3 > pattern.len) return null;
        if (pattern[index] != '\\' or pattern[index + 1] != 'w' or pattern[index + 2] != '{') return null;
        const close = std.mem.indexOfScalarPos(u8, pattern, index + 3, '}') orelse return null;
        const width = std.fmt.parseInt(usize, pattern[index + 3 .. close], 10) catch return null;
        if (width == 0) return null;
        parsed.word_lens[parsed.count] = width;
        parsed.count += 1;
        index = close + 1;
        if (index == pattern.len) break;
        if (index + 3 > pattern.len) return null;
        if (pattern[index] != '\\' or pattern[index + 1] != 's' or pattern[index + 2] != '+') return null;
        index += 3;
    }

    return if (parsed.count >= 2) parsed else null;
}

fn countFixedWordWhitespaceChain(line: []const u8, chain: FixedWordWhitespaceChain) usize {
    var total: usize = 0;
    var cursor: usize = 0;
    while (cursor < line.len) {
        if (fixedWordWhitespaceChainEnd(line, cursor, chain)) |end| {
            total += 1;
            cursor = end;
        } else {
            cursor += 1;
        }
    }
    return total;
}

fn fixedWordWhitespaceChainEnd(line: []const u8, start: usize, chain: FixedWordWhitespaceChain) ?usize {
    var cursor = start;
    var part: usize = 0;
    while (part < chain.count) : (part += 1) {
        const width = chain.word_lens[part];
        if (cursor + width > line.len) return null;
        for (line[cursor .. cursor + width]) |byte| {
            if (!isWordChar(byte)) return null;
        }
        cursor += width;
        if (part + 1 == chain.count) return cursor;
        const ws_start = cursor;
        while (cursor < line.len and isRegexWhitespace(line[cursor])) : (cursor += 1) {}
        if (cursor == ws_start) return null;
    }
    return cursor;
}

fn isRegexWhitespace(byte: u8) bool {
    return byte == ' ' or byte == '\t' or byte == '\r' or byte == '\n';
}

fn elapsedMs(io: std.Io, start: std.Io.Timestamp) f64 {
    const elapsed = start.untilNow(io, .awake);
    return @as(f64, @floatFromInt(elapsed.nanoseconds)) / 1_000_000.0;
}

fn currentWorkingDirectory(io: std.Io, allocator: std.mem.Allocator) ![]const u8 {
    var buffer: [std.fs.max_path_bytes]u8 = undefined;
    const len = try std.process.currentPath(io, &buffer);
    return discovered_files.normalizeDisplayPath(allocator, buffer[0..len]);
}

pub fn matchesLine(line: []const u8, plan: expr.ExpressionPlan) bool {
    return matchingColumn(line, plan, false) != null;
}

fn allPredicatesMatch(line: []const u8, predicates: []const expr.Predicate, case_insensitive: bool) bool {
    for (predicates) |predicate| {
        if (!predicateMatches(line, predicate, case_insensitive)) return false;
    }
    return true;
}

fn anyPredicateMatches(line: []const u8, predicates: []const expr.Predicate, case_insensitive: bool) bool {
    for (predicates) |predicate| {
        if (predicateMatches(line, predicate, case_insensitive)) return true;
    }
    return false;
}

fn predicateMatches(line: []const u8, predicate: expr.Predicate, case_insensitive: bool) bool {
    return predicateColumn(line, predicate, case_insensitive) != null;
}

/// Evaluates the full expression plan against a line and returns the
/// 1-based column of the earliest match, or null if the line doesn't match.
///
/// .all mode (&&): every predicate must match; returns the leftmost column
/// among all predicates. Short-circuits on the first predicate miss.
///
/// .any mode (||): at least one predicate must match; returns the leftmost
/// column among all matching predicates. Scans all predicates to find the
/// earliest position (no short-circuit on first hit).
fn matchingColumn(line: []const u8, plan: expr.ExpressionPlan, case_insensitive: bool) ?usize {
    const predicates = plan.predicates[0..plan.predicate_count];
    return switch (plan.mode) {
        .all => {
            var first_column: ?usize = null;
            for (predicates) |predicate| {
                const column = predicateColumn(line, predicate, case_insensitive) orelse return null;
                if (first_column == null or column < first_column.?) first_column = column;
            }
            return first_column;
        },
        .any => {
            var first_column: ?usize = null;
            for (predicates) |predicate| {
                if (predicateColumn(line, predicate, case_insensitive)) |column| {
                    if (first_column == null or column < first_column.?) first_column = column;
                }
            }
            return first_column;
        },
    };
}

fn predicateColumn(line: []const u8, predicate: expr.Predicate, case_insensitive: bool) ?usize {
    return switch (predicate.kind) {
        .literal => if (indexOfLiteral(line, predicate.value, case_insensitive)) |index| index + 1 else null,
        .prefix => if (startsWithLiteral(line, predicate.value, case_insensitive)) 1 else null,
        .suffix => if (endsWithLiteral(line, predicate.value, case_insensitive)) line.len - predicate.value.len + 1 else null,
        .regex => regexColumnByStrategy(line, predicate, case_insensitive),
    };
}

/// Comptime-specialized predicate column for monomorphized single-predicate path.
/// Both kind and strategy are comptime-known -- all switches collapse.
fn predicateColumnMono(comptime kind: expr.PredicateKind, comptime strategy: expr.MatcherStrategy, line: []const u8, predicate: expr.Predicate, case_insensitive: bool) ?usize {
    return switch (kind) {
        .literal => if (indexOfLiteral(line, predicate.value, case_insensitive)) |index| index + 1 else null,
        .prefix => if (startsWithLiteral(line, predicate.value, case_insensitive)) 1 else null,
        .suffix => if (endsWithLiteral(line, predicate.value, case_insensitive)) line.len - predicate.value.len + 1 else null,
        .regex => regexColumnByStrategyMono(strategy, line, predicate, case_insensitive),
    };
}

/// Comptime-specialized regex column dispatch. When `strategy` is comptime-known,
/// the switch collapses to a single branch -- zero runtime dispatch overhead.
fn regexColumnByStrategyMono(comptime strategy: expr.MatcherStrategy, line: []const u8, predicate: expr.Predicate, case_insensitive: bool) ?usize {
    return switch (strategy) {
        .regex_plain_literal => {
            if (std.mem.indexOfScalar(u8, predicate.value, '\\') == null) {
                return if (indexOfLiteral(line, predicate.value, case_insensitive)) |index| index + 1 else null;
            }
            const index = indexOfRegexLiteral(line, predicate.value, case_insensitive) orelse return null;
            return index + 1;
        },
        .regex_ascii_casefold_literal => {
            const body = if (std.mem.startsWith(u8, predicate.value, "(?i)")) predicate.value[4..] else predicate.value;
            if (std.mem.indexOfScalar(u8, body, '\\') == null) {
                return if (indexOfLiteral(line, body, true)) |index| index + 1 else null;
            }
            const index = indexOfRegexLiteral(line, body, true) orelse return null;
            return index + 1;
        },
        .regex_word_boundary_literal => {
            const body = expr.stripWordBoundaryAnchors(predicate.value);
            return wordBoundaryLiteralColumn(line, body, case_insensitive);
        },
        .regex_ascii_casefold_word_boundary_literal => {
            const after_flag = if (std.mem.startsWith(u8, predicate.value, "(?i)")) predicate.value[4..] else predicate.value;
            const body = expr.stripWordBoundaryAnchors(after_flag);
            return wordBoundaryLiteralColumn(line, body, true);
        },
        .regex_literal_alternates => {
            return literalAlternatesColumn(line, expr.literalAlternatesBody(predicate.value), case_insensitive or std.mem.startsWith(u8, predicate.value, "(?i)"));
        },
        // regex_full, regex_fixed_width_bytes, regex_decomposition_candidate_lines,
        // and non-regex strategies all fall through to prefilter + regex engine.
        else => regexWithLiteralPrefilter(line, predicate.value, case_insensitive),
    };
}

/// Runtime strategy dispatch -- inline else converts each runtime branch to a
/// comptime-known call into regexColumnByStrategyMono.
fn regexColumnByStrategy(line: []const u8, predicate: expr.Predicate, case_insensitive: bool) ?usize {
    return switch (predicate.strategy) {
        inline else => |strategy| regexColumnByStrategyMono(strategy, line, predicate, case_insensitive),
    };
}

/// For regex_full patterns, extract the longest literal fragment from
/// anywhere in the pattern and use SIMD indexOf to reject lines that
/// can't match before running the regex engine.
///
/// E.g. `\w+Column` -> fragment `Column` (suffix, not prefix).
///      `process_\d+_\d+` -> fragment `process_` (prefix).
///      `[A-Z]+error_log` -> fragment `error_log` (suffix).
///
/// SIMD indexOf rejects non-matching lines at ~32 bytes/cycle (AVX2),
/// eliminating the per-line PCRE2 JIT dispatch on ~99% of lines for
/// patterns with a mandatory literal of >=2 bytes.
fn regexWithLiteralPrefilter(line: []const u8, pattern: []const u8, case_insensitive: bool) ?usize {
    // Use threadlocal cache to avoid re-extracting the same fragment per line.
    // The search loop uses the same pattern for every line in a file.
    const cached = cachedLiteralFragment(pattern);
    if (cached.len >= 2) {
        if (indexOfLiteral(line, cached, case_insensitive) == null) return null;
    }
    return pcre_regex.column(line, pattern, case_insensitive) catch
        regex.column(line, pattern, case_insensitive);
}

/// Single-entry threadlocal cache for literal fragment extraction.
/// Avoids recomputing extractLongestLiteralFragment on every line
/// when the pattern is the same (which it always is within a file scan).
fn cachedLiteralFragment(pattern: []const u8) []const u8 {
    const Cache = struct {
        threadlocal var ptr: [*]const u8 = undefined;
        threadlocal var len: usize = 0;
        threadlocal var result_ptr: [*]const u8 = undefined;
        threadlocal var result_len: usize = 0;
        threadlocal var initialized: bool = false;
    };
    if (Cache.initialized and Cache.len == pattern.len and Cache.ptr == pattern.ptr) {
        return Cache.result_ptr[0..Cache.result_len];
    }
    const effective = if (std.mem.startsWith(u8, pattern, "(?i)")) pattern[4..] else pattern;
    const fragment = extractLongestLiteralFragment(effective);
    Cache.ptr = pattern.ptr;
    Cache.len = pattern.len;
    Cache.result_ptr = fragment.ptr;
    Cache.result_len = fragment.len;
    Cache.initialized = true;
    return fragment;
}

/// Extract the longest contiguous literal substring from anywhere in a regex
/// pattern. Walks the entire pattern, tracking runs of plain literal bytes
/// (not preceded by `?` or `*` quantifiers which make them optional).
/// Returns the longest such run as a slice into the original pattern.
///
/// Examples:
///   `\w+Column`      -> `Column`
///   `process_\d+_\d+`-> `process_`
///   `[A-Z]+error_log` -> `error_log`
///   `\d{4}-\d{2}`    -> `-`  (short -- caller applies >=2 byte threshold)
///   `.*`             -> ``   (empty -- no literals)
fn extractLongestLiteralFragment(pattern: []const u8) []const u8 {
    if (hasTopLevelRegexAlternation(pattern)) return "";

    var best_start: usize = 0;
    var best_len: usize = 0;
    var run_start: usize = 0;
    var run_len: usize = 0;
    var i: usize = 0;

    while (i < pattern.len) {
        const byte = pattern[i];

        // Skip escape sequences -- they are metachar classes (\w, \d, etc.)
        // or escaped literals (\., \\). Escaped literals could theoretically
        // be included but would complicate the fragment (it wouldn't be a
        // simple substring match anymore). Break the run.
        if (byte == '\\') {
            if (run_len > best_len) {
                best_start = run_start;
                best_len = run_len;
            }
            run_len = 0;
            // Skip the escaped pair
            i += if (i + 1 < pattern.len and pattern[i + 1] == 'x') @as(usize, 4) else @as(usize, 2);
            run_start = i;
            continue;
        }

        // Metacharacters break a literal run.
        if (isRegexMetaChar(byte)) {
            if (run_len > best_len) {
                best_start = run_start;
                best_len = run_len;
            }
            run_len = 0;
            // For character classes [...], skip to closing bracket.
            if (byte == '[') {
                i += 1;
                while (i < pattern.len and pattern[i] != ']') : (i += 1) {
                    if (pattern[i] == '\\' and i + 1 < pattern.len) i += 1;
                }
                if (i < pattern.len) i += 1; // skip ']'
                if (i < pattern.len and pattern[i] == '{') {
                    i = skipRegexQuantifier(pattern, i);
                }
            } else if (byte == '(') {
                // Groups contain alternation -- cannot guarantee any single
                // branch's literal is mandatory. Skip to matching ')'.
                var depth: usize = 1;
                i += 1;
                while (i < pattern.len and depth > 0) : (i += 1) {
                    if (pattern[i] == '\\' and i + 1 < pattern.len) {
                        i += 1;
                        continue;
                    }
                    if (pattern[i] == '(') depth += 1;
                    if (pattern[i] == ')') depth -= 1;
                }
            } else if (byte == '{') {
                i = skipRegexQuantifier(pattern, i);
            } else {
                i += 1;
            }
            run_start = i;
            continue;
        }

        // Check if this literal is followed by a quantifier that makes it
        // optional (? or *). If so, it's not mandatory -- break the run.
        if (i + 1 < pattern.len and (pattern[i + 1] == '?' or pattern[i + 1] == '*')) {
            if (run_len > best_len) {
                best_start = run_start;
                best_len = run_len;
            }
            run_len = 0;
            i += 2; // skip the literal + quantifier
            run_start = i;
            continue;
        }

        // Plain mandatory literal byte -- extend the current run.
        // If a `+` quantifier follows, the literal is still mandatory (>=1 match),
        // so include the byte but skip the `+`.
        run_len += 1;
        i += 1;
        if (i < pattern.len and pattern[i] == '+') {
            // `x+` means >=1 x. The single `x` is mandatory. But the run
            // must break here because the next byte is a separate token.
            if (run_len > best_len) {
                best_start = run_start;
                best_len = run_len;
            }
            run_len = 0;
            i += 1; // skip '+'
            run_start = i;
        }
    }

    // Final run.
    if (run_len > best_len) {
        best_start = run_start;
        best_len = run_len;
    }

    return pattern[best_start .. best_start + best_len];
}

fn skipRegexQuantifier(pattern: []const u8, open_index: usize) usize {
    std.debug.assert(open_index < pattern.len and pattern[open_index] == '{');
    const close = std.mem.indexOfScalarPos(u8, pattern, open_index + 1, '}') orelse return open_index + 1;
    return close + 1;
}

fn hasTopLevelRegexAlternation(pattern: []const u8) bool {
    var class_depth = false;
    var group_depth: usize = 0;
    var i: usize = 0;
    while (i < pattern.len) : (i += 1) {
        const byte = pattern[i];
        if (byte == '\\') {
            if (i + 1 < pattern.len) i += 1;
            continue;
        }
        if (class_depth) {
            if (byte == ']') class_depth = false;
            continue;
        }
        switch (byte) {
            '[' => class_depth = true,
            '(' => group_depth += 1,
            ')' => {
                if (group_depth > 0) group_depth -= 1;
            },
            '|' => if (group_depth == 0) return true,
            else => {},
        }
    }
    return false;
}

fn isRegexMetaChar(byte: u8) bool {
    return switch (byte) {
        '.', '*', '+', '?', '[', ']', '(', ')', '{', '}', '|', '^', '$' => true,
        else => false,
    };
}

fn isHiddenPath(path: []const u8) bool {
    var iterator = std.mem.splitAny(u8, path, "/\\");
    while (iterator.next()) |part| {
        if (part.len > 1 and part[0] == '.' and !std.mem.eql(u8, part, "..")) return true;
    }
    return false;
}

fn isHiddenDirectoryPath(path: []const u8) bool {
    var iterator = std.mem.splitAny(u8, path, "/\\");
    var previous: ?[]const u8 = null;
    while (iterator.next()) |part| {
        if (previous) |candidate| {
            if (candidate.len > 1 and candidate[0] == '.' and !std.mem.eql(u8, candidate, "..")) return true;
        }
        previous = part;
    }
    return false;
}

fn isHiddenDirectoryEntry(name: []const u8, is_directory: bool) bool {
    return is_directory and isHiddenPath(name);
}

fn shouldSkipDefaultDiscoveryEntry(name: []const u8, is_directory: bool) bool {
    return isHiddenDirectoryEntry(name, is_directory) or isGeneratedSourceIndexEntry(name, is_directory);
}

fn isGeneratedSourceIndexEntry(name: []const u8, is_directory: bool) bool {
    if (!is_directory) return false;
    return std.mem.eql(u8, name, "tags") or std.mem.eql(u8, name, "TAGS");
}

// SIMD Casefold Infrastructure
//
// ASCII case differs by exactly bit 5 (0x20). To search case-insensitively
// at SIMD speed, we lowercase both the line and needle into scratch buffers,
// then run the pure Zig SIMD memmem on the lowered copies.
//
// The vector loop processes 32 bytes per iteration:
//   1. Load 32 bytes
//   2. Wrapping-subtract 'A' (maps A-Z -> 0-25, everything else -> >= 26)
//   3. Compare < 26 -> bool mask identifying uppercase bytes
//   4. Select 0x20 where uppercase, 0 elsewhere
//   5. OR with originals -> lowercase A-Z, all other bytes unchanged
//
// This converts O(nxm) scalar comparison into O(n) casefold + O(n) SIMD
// search -- a ~10-30x speedup on typical source code lines.

/// Stack buffer ceiling for SIMD casefold. 2 KiB keeps the combined
/// casefold stack frame (line_buf + needle_buf + overhead) under 4 KiB,
/// which is the Windows __chkstk threshold. Frames >= 4 KiB require a
/// __chkstk page-probe call on every function entry -- with 100k lines
/// this adds ~1ms on case-insensitive searches. Lines longer than 2 KiB
/// are virtually absent in real source code and fall back to the scalar path.
const CASEFOLD_LINE_MAX = 2 * 1024;

/// Maximum needle length for stack-buffered casefold. 256 B is sufficient
/// for any realistic search pattern; combined with CASEFOLD_LINE_MAX the
/// total stack frame stays under 4 KiB.
const CASEFOLD_NEEDLE_MAX = 256;

/// SIMD-accelerated ASCII lowercase. Processes 32 bytes per iteration
/// using AVX2 vector operations, with a scalar tail for the remainder.
/// Non-alpha bytes pass through unchanged -- the wrapping range check
/// ensures only A-Z (0x41-0x5A) receive the 0x20 OR.
fn asciiLowerBuf(dst: []u8, src: []const u8) void {
    std.debug.assert(dst.len >= src.len);
    const VEC_LEN = 32;
    const V = @Vector(VEC_LEN, u8);
    var i: usize = 0;
    while (i + VEC_LEN <= src.len) : (i += VEC_LEN) {
        const v: V = src[i..][0..VEC_LEN].*;
        const shifted: V = v -% @as(V, @splat(@as(u8, 'A')));
        const is_upper = shifted < @as(V, @splat(@as(u8, 26)));
        const delta = @select(u8, is_upper, @as(V, @splat(@as(u8, 0x20))), @as(V, @splat(@as(u8, 0))));
        dst[i..][0..VEC_LEN].* = v | delta;
    }
    while (i < src.len) : (i += 1) {
        dst[i] = std.ascii.toLower(src[i]);
    }
}

/// HOT PATH 3: Literal substring matching -- the core search operation.
///
/// Case-sensitive path uses simd.indexOf (AVX2 first+last byte fingerprint), which
/// fingerprints by first+last byte across 32 positions per SIMD pass.
///
/// Case-insensitive path dispatches to indexOfLiteralCasefold (separate
/// function) to keep this hot path's stack frame under 4 KiB. On Windows,
/// frames > 4 KiB trigger __chkstk page probes on every call -- including
/// case-sensitive calls that take the early return. Isolating the 2 KiB
/// casefold buffers into their own function eliminates that overhead.
fn indexOfLiteral(line: []const u8, needle: []const u8, case_insensitive: bool) ?usize {
    if (!case_insensitive) return simd.indexOf(line, needle);
    if (needle.len == 0) return 0;
    if (needle.len > line.len) return null;
    return indexOfLiteralCasefold(line, needle);
}

/// SIMD casefold search -- isolated from indexOfLiteral to quarantine the
/// 2 KiB + 256 B stack buffers away from the case-sensitive hot path.
/// Lowercase both line and needle into stack buffers via AVX2 vector ops,
/// then search with simd.indexOf. O(n) casefold + O(n) SIMD search.
///
/// For needles ≤ 64 bytes, the Bit-Parallel Shift-Or path is used instead:
/// it matches case-insensitively in a single O(n) pass with no stack buffer
/// allocation, eliminating the casefold overhead and __chkstk page probes.
fn indexOfLiteralCasefold(line: []const u8, needle: []const u8) ?usize {
    if (needle.len <= shift_or.MAX_PATTERN_LEN) {
        const so = shift_or.ShiftOr.init(needle, true) orelse return indexOfLiteralScalar(line, needle);
        return so.indexOf(line);
    }
    if (line.len <= CASEFOLD_LINE_MAX and needle.len <= CASEFOLD_NEEDLE_MAX) {
        var lower_line: [CASEFOLD_LINE_MAX]u8 = undefined;
        var lower_needle: [CASEFOLD_NEEDLE_MAX]u8 = undefined;
        asciiLowerBuf(lower_line[0..line.len], line);
        asciiLowerBuf(lower_needle[0..needle.len], needle);
        return simd.indexOf(lower_line[0..line.len], lower_needle[0..needle.len]);
    }
    return indexOfLiteralScalar(line, needle);
}

/// Scalar case-insensitive literal search. O(nxm) byte-by-byte comparison,
/// used only when line length exceeds the SIMD casefold stack buffer.
fn indexOfLiteralScalar(line: []const u8, needle: []const u8) ?usize {
    if (needle.len == 0) return 0;
    if (needle.len > line.len) return null;
    var index: usize = 0;
    while (index + needle.len <= line.len) : (index += 1) {
        if (literalEquals(line[index .. index + needle.len], needle, true)) return index;
    }
    return null;
}

/// Counts non-overlapping occurrences of a literal needle in a line.
/// Case-sensitive path uses the dedicated non-overlapping SIMD counter.
/// Case-insensitive path dispatches to countLiteralCasefold (separate
/// function) to quarantine the casefold stack buffers.
fn countLiteral(line: []const u8, needle: []const u8, case_insensitive: bool) usize {
    if (needle.len == 0) return 0;
    if (case_insensitive) return countLiteralCasefold(line, needle);
    return simd.countNonOverlapping(line, needle);
}

/// Casefold-once counting -- isolated from countLiteral to quarantine the
/// casefold stack buffers. Lowercase the line once, then use the dedicated
/// non-overlapping SIMD counter on the lowered copy.
///
/// For needles ≤ 64 bytes, the Bit-Parallel Shift-Or counter is used:
/// single O(n) pass, no stack buffer, no __chkstk probes.
fn countLiteralCasefold(line: []const u8, needle: []const u8) usize {
    if (needle.len <= shift_or.MAX_PATTERN_LEN) {
        const so = shift_or.ShiftOr.init(needle, true) orelse return countLiteralCasefoldBuffered(line, needle);
        return so.count(line);
    }
    return countLiteralCasefoldBuffered(line, needle);
}

fn countLiteralCasefoldBuffered(line: []const u8, needle: []const u8) usize {
    if (line.len <= CASEFOLD_LINE_MAX and needle.len <= CASEFOLD_NEEDLE_MAX) {
        var lower_line: [CASEFOLD_LINE_MAX]u8 = undefined;
        var lower_needle: [CASEFOLD_NEEDLE_MAX]u8 = undefined;
        asciiLowerBuf(lower_line[0..line.len], line);
        asciiLowerBuf(lower_needle[0..needle.len], needle);
        const ll = lower_line[0..line.len];
        const ln = lower_needle[0..needle.len];
        return simd.countNonOverlapping(ll, ln);
    }
    // Scalar fallback for oversized lines.
    var total: usize = 0;
    var start: usize = 0;
    while (start <= line.len) {
        const index = indexOfLiteralScalar(line[start..], needle) orelse break;
        total += 1;
        start += index + needle.len;
    }
    return total;
}

fn indexOfRegexLiteral(line: []const u8, pattern: []const u8, case_insensitive: bool) ?usize {
    if (pattern.len == 0) return 0;
    var index: usize = 0;
    while (index <= line.len) : (index += 1) {
        if (regexLiteralMatchLen(line[index..], pattern, case_insensitive)) |_| return index;
        if (index == line.len) break;
    }
    return null;
}

fn countRegexLiteral(line: []const u8, pattern: []const u8, case_insensitive: bool) usize {
    if (pattern.len == 0) return 0;
    var total: usize = 0;
    var start: usize = 0;
    while (start <= line.len) {
        const index = indexOfRegexLiteral(line[start..], pattern, case_insensitive) orelse break;
        const matched_len = regexLiteralMatchLen(line[start + index ..], pattern, case_insensitive) orelse break;
        total += 1;
        start += index + @max(matched_len, 1);
    }
    return total;
}

fn regexLiteralMatchLen(line: []const u8, pattern: []const u8, case_insensitive: bool) ?usize {
    var line_index: usize = 0;
    var pattern_index: usize = 0;
    while (pattern_index < pattern.len) {
        if (line_index >= line.len) return null;
        const expected = if (pattern[pattern_index] == '\\' and pattern_index + 1 < pattern.len) blk: {
            pattern_index += 2;
            break :blk pattern[pattern_index - 1];
        } else blk: {
            const byte = pattern[pattern_index];
            pattern_index += 1;
            break :blk byte;
        };
        if (!byteEquals(line[line_index], expected, case_insensitive)) return null;
        line_index += 1;
    }
    return line_index;
}

fn startsWithLiteral(line: []const u8, needle: []const u8, case_insensitive: bool) bool {
    return line.len >= needle.len and literalEquals(line[0..needle.len], needle, case_insensitive);
}

fn endsWithLiteral(line: []const u8, needle: []const u8, case_insensitive: bool) bool {
    return line.len >= needle.len and literalEquals(line[line.len - needle.len ..], needle, case_insensitive);
}

fn literalEquals(left: []const u8, right: []const u8, case_insensitive: bool) bool {
    if (left.len != right.len) return false;
    for (left, right) |a, b| {
        if (!byteEquals(a, b, case_insensitive)) return false;
    }
    return true;
}

fn byteEquals(left: u8, right: u8, case_insensitive: bool) bool {
    if (!case_insensitive) return left == right;
    return std.ascii.toLower(left) == std.ascii.toLower(right);
}

/// Search for a literal at a word boundary. Finds the literal via
/// indexOfLiteral, then verifies that both edges sit at word boundaries
/// (transition between \w and \W or string edge). Returns 1-based column.
fn wordBoundaryLiteralColumn(line: []const u8, needle: []const u8, case_insensitive: bool) ?usize {
    if (needle.len == 0) return null;
    const first_is_word = isWordChar(needle[0]);
    const last_is_word = isWordChar(needle[needle.len - 1]);
    var start: usize = 0;
    while (start + needle.len <= line.len) {
        const index = indexOfLiteral(line[start..], needle, case_insensitive) orelse return null;
        const abs = start + index;
        const left_is_word = abs > 0 and isWordChar(line[abs - 1]);
        const right_is_word = (abs + needle.len) < line.len and isWordChar(line[abs + needle.len]);
        const left_ok = left_is_word != first_is_word or abs == 0;
        const right_ok = right_is_word != last_is_word or (abs + needle.len) == line.len;
        if (left_ok and right_ok) return abs + 1;
        start = abs + 1;
    }
    return null;
}

fn countWordBoundaryLiteralLines(buffer: []const u8, needle: []const u8) usize {
    if (needle.len == 0) return 0;
    var total: usize = 0;
    var start: usize = 0;
    while (start + needle.len <= buffer.len) {
        const index = simd.indexOf(buffer[start..], needle) orelse break;
        const abs = start + index;
        if (wordBoundaryLiteralAt(buffer, needle, abs)) {
            total += 1;
            if (simd.indexOfByte(buffer[abs..], '\n')) |nl| {
                start = abs + nl + 1;
            } else {
                break;
            }
        } else {
            start = abs + 1;
        }
    }
    return total;
}

fn countWordBoundaryLiteralLogicalLinesRange(buffer: []const u8, needle: []const u8, logical_start: usize, logical_end: usize) WordBoundaryRangeCount {
    if (needle.len == 0 or logical_start >= logical_end) return .{};
    const end = @min(logical_end, buffer.len);
    var counted = WordBoundaryRangeCount{};
    var start = @min(logical_start, end);
    while (start + needle.len <= end) {
        const index = simd.indexOf(buffer[start..end], needle) orelse break;
        const abs = start + index;
        if (abs + needle.len > end) break;
        counted.verified_candidates += 1;
        if (wordBoundaryLiteralAt(buffer, needle, abs)) {
            counted.matches += 1;
            if (simd.indexOfByte(buffer[abs..end], '\n')) |nl| {
                start = abs + nl + 1;
            } else {
                break;
            }
        } else {
            counted.rejected_candidates += 1;
            start = abs + 1;
        }
    }
    return counted;
}

fn countLiteralAlternatesLogicalLinesRange(buffer: []const u8, pattern: []const u8, case_insensitive: bool, logical_start: usize, logical_end: usize) LiteralAlternatesRangeCount {
    return literal_alternates.countLogicalLinesRange(buffer, pattern, case_insensitive, logical_start, logical_end);
}

fn literalAlternatesPcreRangeEligible(pattern: []const u8, branch_count: usize) bool {
    if (pattern.len == 0) return false;
    if (branch_count < 5) return false;
    return std.mem.indexOfScalar(u8, pattern, '\\') == null;
}

fn wordBoundaryLiteralAt(buffer: []const u8, needle: []const u8, abs: usize) bool {
    if (needle.len == 0 or abs + needle.len > buffer.len) return false;
    const left_is_word = abs > 0 and isWordChar(buffer[abs - 1]);
    const right_index = abs + needle.len;
    const right_is_word = right_index < buffer.len and isWordChar(buffer[right_index]);
    const first_is_word = isWordChar(needle[0]);
    const last_is_word = isWordChar(needle[needle.len - 1]);
    const left_ok = left_is_word != first_is_word or abs == 0;
    const right_ok = right_is_word != last_is_word or right_index == buffer.len;
    return left_ok and right_ok;
}

fn isWordChar(byte: u8) bool {
    return std.ascii.isAlphanumeric(byte) or byte == '_';
}

/// Search for a top-level literal alternation pattern such as `alpha|beta`.
/// Each branch is a plain literal -- search them individually and return
/// the earliest match column.
fn literalAlternatesColumn(line: []const u8, pattern: []const u8, case_insensitive: bool) ?usize {
    return literal_alternates.column(line, pattern, case_insensitive);
}

fn countLiteralAlternates(line: []const u8, pattern: []const u8, case_insensitive: bool) usize {
    return literal_alternates.count(line, pattern, case_insensitive);
}

fn countLiteralAlternatesCasefoldedHaystack(line: []const u8, pattern: []const u8) usize {
    return literal_alternates.countCasefoldedHaystack(line, pattern);
}

test "trigram gate rejects impossible complete file without verifier authority" {
    const plan = try expr.parse("lit:needle");
    const admission = trigram.admit(plan);
    const program = TrigramAdmissionProgram.compile(admission, plan, false);
    var stats = core_stats.TrigramAccelerationStats{};
    initTrigramStats(&stats, admission, false);
    var bytes: [TRIGRAM_MIN_PRUNE_BYTES]u8 = undefined;
    @memset(bytes[0..], 'a');

    try std.testing.expect(shouldAttemptTrigramPrune(bytes.len, true, admission, false));
    try std.testing.expect(tryTrigramPruneFile(bytes[0..], &program, &stats));
    try std.testing.expect(stats.eligible);
    try std.testing.expectEqual(@as(usize, 1), stats.candidate_files_checked);
    try std.testing.expectEqual(@as(usize, 1), stats.pruned_files);
    try std.testing.expectEqual(@as(usize, 0), stats.verified_files);
}

test "trigram gate admits possible file for exact verifier" {
    const plan = try expr.parse("lit:needle");
    const admission = trigram.admit(plan);
    const program = TrigramAdmissionProgram.compile(admission, plan, false);
    var stats = core_stats.TrigramAccelerationStats{};
    initTrigramStats(&stats, admission, false);
    var bytes: [TRIGRAM_MIN_PRUNE_BYTES]u8 = undefined;
    @memset(bytes[0..], 'a');
    @memcpy(bytes[128..134], "needle");

    try std.testing.expect(shouldAttemptTrigramPrune(bytes.len, true, admission, false));
    try std.testing.expect(!tryTrigramPruneFile(bytes[0..], &program, &stats));
    try std.testing.expectEqual(@as(usize, 1), stats.candidate_files_checked);
    try std.testing.expectEqual(@as(usize, 0), stats.pruned_files);
    try std.testing.expectEqual(@as(usize, 1), stats.verified_files);
}

test "trigram program requires every all-mode evidence group" {
    const plan = try expr.parse("lit:alpha && lit:omega");
    const admission = trigram.admit(plan);
    const program = TrigramAdmissionProgram.compile(admission, plan, false);
    var stats = core_stats.TrigramAccelerationStats{};
    initTrigramStats(&stats, admission, false);
    var bytes: [TRIGRAM_MIN_PRUNE_BYTES]u8 = undefined;
    @memset(bytes[0..], 'z');
    @memcpy(bytes[64..69], "alpha");

    try std.testing.expect(tryTrigramPruneFile(bytes[0..], &program, &stats));
    @memcpy(bytes[128..133], "omega");
    try std.testing.expect(!tryTrigramPruneFile(bytes[0..], &program, &stats));
}

test "trigram program admits any-mode satisfied branch" {
    const plan = try expr.parse("lit:alpha || lit:omega");
    const admission = trigram.admit(plan);
    const program = TrigramAdmissionProgram.compile(admission, plan, false);
    var stats = core_stats.TrigramAccelerationStats{};
    initTrigramStats(&stats, admission, false);
    var bytes: [TRIGRAM_MIN_PRUNE_BYTES]u8 = undefined;
    @memset(bytes[0..], 'z');
    @memcpy(bytes[96..101], "omega");

    try std.testing.expect(!tryTrigramPruneFile(bytes[0..], &program, &stats));
}

test "whole-file admission requires a complete file buffer" {
    const plan = try expr.parse("re:ERR_SYS|PME_TURN_OFF|LINK_REQ_RST|CFG_BME_EVT");
    const admission = trigram.admit(plan);
    const program = TrigramAdmissionProgram.compile(admission, plan, false);

    try std.testing.expect(program.fileAdmissionEnabled());
    try std.testing.expect(shouldAttemptWholeFileAdmission(true, false, &program));
    try std.testing.expect(!shouldAttemptWholeFileAdmission(false, false, &program));
    try std.testing.expect(shouldAttemptWholeFileAdmission(true, true, &program));
}

test "warm index live marker validates magic pid and root" {
    const marker = "IXINDEX_LIVE1\npid=1234\nprocess_start_ns=55\ncreated_ns=99\nroot=C:/repo\n";
    try std.testing.expect(validateWarmIndexLiveMarkerWithOwnerCheck(marker, "C:/repo", false));
    try std.testing.expect(!validateWarmIndexLiveMarkerWithOwnerCheck("BROKEN\npid=1234\nroot=C:/repo\n", "C:/repo", false));
    try std.testing.expect(!validateWarmIndexLiveMarkerWithOwnerCheck("IXINDEX_LIVE1\npid=0\nprocess_start_ns=55\ncreated_ns=99\nroot=C:/repo\n", "C:/repo", false));
    try std.testing.expect(!validateWarmIndexLiveMarkerWithOwnerCheck("IXINDEX_LIVE1\npid=abc\nprocess_start_ns=55\ncreated_ns=99\nroot=C:/repo\n", "C:/repo", false));
    try std.testing.expect(!validateWarmIndexLiveMarkerWithOwnerCheck("IXINDEX_LIVE1\npid=1234\nprocess_start_ns=55\ncreated_ns=0\nroot=C:/repo\n", "C:/repo", false));
    try std.testing.expect(!validateWarmIndexLiveMarkerWithOwnerCheck("IXINDEX_LIVE1\npid=1234\nroot=C:/repo\n", "C:/repo", false));
    try std.testing.expect(!validateWarmIndexLiveMarkerWithOwnerCheck(marker, "D:/repo", false));
}

test "warm index live marker rejects dead Windows owner" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    const marker = "IXINDEX_LIVE1\npid=999999\nprocess_start_ns=55\ncreated_ns=99\nroot=C:/repo\n";
    try std.testing.expect(!validateWarmIndexLiveMarkerWithOwnerCheck(marker, "C:/repo", true));
}

test "warm index live marker rejects reused Windows pid start mismatch" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    const pid = currentProcessId();
    const start_ns = processStartNs(pid) orelse return error.TestExpectedProcessStart;
    const marker = try std.fmt.allocPrint(std.testing.allocator, "IXINDEX_LIVE1\npid={}\nprocess_start_ns={}\ncreated_ns=99\nroot=C:/repo\n", .{
        pid,
        start_ns - 1,
    });
    defer std.testing.allocator.free(marker);
    try std.testing.expect(!validateWarmIndexLiveMarkerWithOwnerCheck(marker, "C:/repo", true));
}

fn testRootIndexDir(allocator: std.mem.Allocator, root: []const u8) ![]const u8 {
    const root_identity = try catalog.identifyRoot(allocator, root);
    defer root_identity.deinit(allocator);
    const state = try state_dir.buildRootIndexState(allocator, root_identity.fingerprint);
    defer allocator.free(state.state_dir);
    return state.index_dir;
}

fn testLiveMarker(allocator: std.mem.Allocator, root: []const u8) ![]const u8 {
    const pid = if (builtin.os.tag == .windows) currentProcessId() else 1;
    const start_ns = if (builtin.os.tag == .windows) (processStartNs(pid) orelse return error.TestExpectedProcessStart) else 0;
    return std.fmt.allocPrint(allocator, "IXINDEX_LIVE1\npid={}\nprocess_start_ns={}\ncreated_ns=99\nroot={s}\n", .{ pid, start_ns, root });
}

test "warm foreground marker validation is generation-pin gated" {
    const marker = try testLiveMarker(std.testing.allocator, "C:/repo");
    defer std.testing.allocator.free(marker);
    try std.testing.expect(validateWarmIndexLiveMarker(marker, "C:/repo"));
    try std.testing.expect(!validateWarmIndexLiveMarker(marker, "D:/repo"));
}

test "warm index rejects foreground_once marker after its owner exits" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;

    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    try tmp.dir.writeFile(io, .{ .sub_path = "candidate.txt", .data = "needle\n" });
    const root_path = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}", .{&tmp.sub_path});
    _ = try @import("indexd.zig").publishRootGeneration(io, allocator, root_path);
    const index_dir = try testRootIndexDir(allocator, root_path);
    try std.Io.Dir.cwd().createDirPath(io, index_dir);
    const live_path = try std.fs.path.join(allocator, &.{ index_dir, WARM_INDEX_LIVE_MARKER_NAME });
    defer std.Io.Dir.cwd().deleteFile(io, live_path) catch {};
    // A dead once-owner leaves a durable snapshot, not a live search index.
    const live_marker = try std.fmt.allocPrint(allocator, "IXINDEX_LIVE1\npid=999999\nprocess_start_ns=55\ncreated_ns=99\nroot={s}\n", .{root_path});
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = live_path, .data = live_marker });

    var request = testSearchRequest("lit:needle", root_path);
    request.index_enabled = true;
    request.nexus_disabled = true;
    const plan = try expr.parse(request.expression);
    const report = try run(io, allocator, request, plan);
    try std.testing.expect(!report.stats.catalog_index.available);
    try std.testing.expect(!report.stats.postings_index.available);
    try std.testing.expectEqualStrings("invalid_live_owner", report.stats.generation_refresh.fallback_reason);
}

test "warm index reports corrupt generation payload before falling back" {
    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    try tmp.dir.writeFile(io, .{ .sub_path = "candidate.txt", .data = "needle\n" });
    const root_path = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}", .{&tmp.sub_path});
    const pin = try @import("indexd.zig").publishRootGeneration(io, allocator, root_path);
    const index_dir = try testRootIndexDir(allocator, root_path);
    const paths = try generation.buildGenerationPathsInIndexDir(allocator, index_dir, pin.epoch);
    defer paths.deinit(allocator);

    const catalog_path = try std.fs.path.join(allocator, &.{ paths.generation_dir, "catalog.ixcat" });
    var corrupt_catalog = try std.Io.Dir.cwd().createFile(io, catalog_path, .{ .truncate = true });
    defer corrupt_catalog.close(io);
    try corrupt_catalog.writeStreamingAll(io, "BROKEN-CATALOG");

    const live_path = try std.fs.path.join(allocator, &.{ index_dir, WARM_INDEX_LIVE_MARKER_NAME });
    defer std.Io.Dir.cwd().deleteFile(io, live_path) catch {};
    const live_marker = try testLiveMarker(allocator, root_path);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = live_path, .data = live_marker });

    var request = testSearchRequest("lit:needle", root_path);
    request.index_enabled = true;
    request.nexus_disabled = true;
    const plan = try expr.parse(request.expression);
    const report = try run(io, allocator, request, plan);

    try std.testing.expect(!report.stats.catalog_index.available);
    try std.testing.expect(!report.stats.postings_index.available);
    // The full segment checksum validation was removed (it re-read 937 MiB
    // per warm query). Corruption is now caught by the catalog's own header
    // validation — a corrupt catalog fails with InvalidCatalogMagic, which
    // triggers warmIndexFallback → cold scan. The corruption IS detected;
    // only the detection mechanism changed.
    try std.testing.expect(report.stats.generation_refresh.fallback_reason.len > 0);
    try std.testing.expectEqualStrings("fallback", report.stats.generation_refresh.refresh_status);
    try std.testing.expectEqual(@as(usize, 1), report.files_scanned);
    try std.testing.expectEqual(@as(usize, 1), report.matches_found);
}

test "regex prefilter does not reject top-level alternation branch literals" {
    try std.testing.expectEqualStrings("", cachedLiteralFragment("[A-Z]+error_log|WARN"));
    try std.testing.expectEqual(@as(?usize, 1), regexWithLiteralPrefilter("WARN", "[A-Z]+error_log|WARN", false));
    try std.testing.expectEqual(@as(?usize, 1), regexWithLiteralPrefilter("XXerror_log", "[A-Z]+error_log|WARN", false));
}

test "regex prefilter still extracts mandatory non-alternation literal" {
    try std.testing.expectEqualStrings("error_log", cachedLiteralFragment("[A-Z]+error_log"));
    try std.testing.expect(regexWithLiteralPrefilter("WARN", "[A-Z]+error_log", false) == null);
}

test "regex prefilter ignores counted repeat quantifier bodies" {
    try std.testing.expectEqualStrings("", cachedLiteralFragment("[A-Za-z_][A-Za-z0-9_]{20,}"));
    try std.testing.expectEqual(@as(?usize, 1), regexWithLiteralPrefilter("IdentifierNameWithTwentyChars", "[A-Za-z_][A-Za-z0-9_]{20,}", false));
}

test "stats-only inline casefold alternates do not file-admission prune lowercase matches" {
    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    try tmp.dir.writeFile(io, .{ .sub_path = "candidate.c", .data = "goto err_sysfs;\nerr_sysfs:\n" });
    const root_path = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}/candidate.c", .{&tmp.sub_path});

    var request = testSearchRequest("re:(?i)(ERR_SYS|PME_TURN_OFF|LINK_REQ_RST|CFG_BME_EVT)", root_path);
    request.stats_only = true;
    request.nexus_disabled = true;
    const plan = try expr.parse(request.expression);
    const report = try run(io, allocator, request, plan);

    try std.testing.expectEqual(@as(usize, 1), report.files_scanned);
    try std.testing.expectEqual(@as(usize, 2), report.matches_found);
}

test "empty line regex preserves zero-width anchor semantics" {
    try std.testing.expectEqual(@as(?usize, 1), regexWithLiteralPrefilter("", "^$", false));
    try std.testing.expectEqual(@as(usize, 1), countRegexWithPrefilter("", "^$", false));
}

test "whole buffer word-boundary literal counts matching lines" {
    const buffer =
        "PM_RESUME once PM_RESUME twice\n" ++
        "XPM_RESUME rejected\n" ++
        "PM_RESUME_tail rejected\n" ++
        "PM_RESUME accepted\n";
    try std.testing.expectEqual(@as(usize, 2), countWordBoundaryLiteralLines(buffer, "PM_RESUME"));
}

test "whole buffer casefold literal alternates counts lowercased haystack" {
    const plan = try expr.parse("re:(?i)(ERR_SYS|PME_TURN_OFF|LINK_REQ_RST|CFG_BME_EVT)");
    var buffer = [_]u8{ 'e', 'r', 'r', '_', 's', 'y', 's', ' ', 'L', 'I', 'N', 'K', '_', 'R', 'E', 'Q', '_', 'R', 'S', 'T' };
    asciiLowerBuf(buffer[0..], buffer[0..]);
    try std.testing.expect(planIsCasefoldLiteralAlternates(plan, false));
    try std.testing.expectEqual(@as(?usize, 2), wholeBufferFastCount(buffer[0..], plan, false, true));
}

test "byte shard logical range counts seam matches once" {
    const data = "xxSherlock HolmesyySherlock Holmeszz";
    const needle = "Sherlock Holmes";
    const seam = 10;
    const overlap = needle.len - 1;
    const left = countLiteralLogicalRange(data, needle, 0, seam, 0, @min(seam + overlap, data.len));
    const right = countLiteralLogicalRange(data, needle, seam, data.len, seam -| overlap, data.len);
    try std.testing.expectEqual(@as(usize, 2), left + right);
}

test "byte shard logical range preserves non-overlapping semantics" {
    const data = "aaaaa";
    const needle = "aaa";
    const seam = 2;
    const overlap = needle.len - 1;
    const left = countLiteralLogicalRange(data, needle, 0, seam, 0, @min(seam + overlap, data.len));
    const right = countLiteralLogicalRange(data, needle, seam, data.len, seam -| overlap, data.len);
    try std.testing.expectEqual(countLiteral(data, needle, false), left + right);
}

test "count literal uses non-overlapping medium literal semantics" {
    const needle = "ABCDEFGHIJKLMNOPQRST";
    const data = needle ++ "__" ++ needle ++ "__tail";
    try std.testing.expectEqual(@as(usize, 2), countLiteral(data, needle, false));
}

test "count literal casefold uses non-overlapping medium literal semantics" {
    const needle = "AbCdEfGhIjKlMnOpQrSt";
    const data = "abcdefghiJKLMNOPQRST__ABCDefghijklmnopqrst__tail";
    try std.testing.expectEqual(@as(usize, 2), countLiteral(data, needle, true));
}

test "byte shard logical range full-span fast path matches medium literal count" {
    const needle = "ABCDEFGHIJKLMNOPQRST";
    const data = needle ++ "__" ++ needle ++ "__tail";
    try std.testing.expectEqual(countLiteral(data, needle, false), countLiteralLogicalRange(data, needle, 0, data.len, 0, data.len));
}

test "fixed word whitespace chain fast count matches regex count semantics" {
    const pattern = "\\w{5}\\s+\\w{5}\\s+\\w{5}\\s+\\w{5}\\s+\\w{5}";
    const chain = fixedWordWhitespaceChain(pattern) orelse return error.TestExpectedEqual;

    const cases = [_][]const u8{
        "alpha beta gamma delta omega",
        "abcdef beta gamma delta omega",
        "alpha  beta\tgamma delta omega",
        "alpha beta gamma delta omega alpha beta gamma delta omega",
        "abcd beta gamma delta omega",
        "alpha beta gamma delta",
        "alpha beta gamma delta omega_tail",
    };

    for (cases) |line| {
        try std.testing.expectEqual(
            countRegexStatsOnly(line, pattern, false),
            countFixedWordWhitespaceChain(line, chain),
        );
    }

    try std.testing.expect(fixedWordWhitespaceChain("\\w{5}\\s+") == null);
    try std.testing.expect(fixedWordWhitespaceChain("\\w+\\s+\\w+") == null);
    try std.testing.expect(fixedWordWhitespaceChain("\\d{5}\\s+\\w{5}") == null);
}

test "byte shard fanout remains beneath the framework worker ceiling" {
    try std.testing.expectEqual(@as(usize, 4), defaultByteShardThreadBudget(BYTE_SHARD_DEFAULT_MAX_RANGES + 14));
    try std.testing.expectEqual(@as(usize, 1), defaultByteShardThreadBudget(8));
}

test "regex decomposition fast count verifies mandatory literal candidate lines" {
    const plan = try expr.parse("re:Sherlock\\s+Holmes");
    try std.testing.expect(planUsesRegexDecompositionFastCount(plan, false));
    try std.testing.expectEqualStrings("Sherlock", byte_shard.regexDecompositionNeedle(plan.predicates[0].value).?);

    const buffer =
        "Sherlock Holmes\n" ++
        "Sherlock\n" ++
        "Sherlock    Holmes\n" ++
        "Holmes Sherlock\n";
    var stats: core_stats.RegexDecompositionStats = .{};
    var bailouts: usize = 0;
    const count = regexDecompositionFastCount(buffer, plan, false, &stats, &bailouts).?;
    try std.testing.expectEqual(@as(usize, 2), count);
    try std.testing.expectEqual(@as(usize, 1), stats.eligible_files);
    try std.testing.expectEqual(@as(usize, 1), stats.counted_files);
    try std.testing.expectEqual(@as(usize, 4), stats.candidate_lines_checked);
    try std.testing.expectEqual(@as(usize, 2), stats.candidate_lines_matched);
    try std.testing.expectEqual(@as(usize, 0), bailouts);
}

test "regex decomposition byte ranges preserve line-owned candidate counts" {
    const pattern = "Sherlock\\s+Holmes";
    const needle = byte_shard.regexDecompositionNeedle(pattern).?;
    const buffer =
        "Sherlock Holmes\n" ++
        "Sherlock\n" ++
        "Sherlock    Holmes\n" ++
        "Holmes Sherlock\n" ++
        "Sherlock Holmes again";
    const expected = countRegexDecompositionLogicalLinesRange(buffer, needle, pattern, 0, buffer.len);
    const seams = [_]usize{ 1, 9, 17, 31, 44, buffer.len - 1 };
    for (seams) |seam| {
        const left_end = byte_shard.findOwnedLineBoundaryAfter(buffer, seam) orelse buffer.len;
        const left = countRegexDecompositionLogicalLinesRange(buffer, needle, pattern, 0, left_end);
        const right = countRegexDecompositionLogicalLinesRange(buffer, needle, pattern, left_end, buffer.len);
        try std.testing.expectEqual(expected.matches, left.matches + right.matches);
        try std.testing.expectEqual(expected.candidate_lines_checked, left.candidate_lines_checked + right.candidate_lines_checked);
        try std.testing.expectEqual(expected.candidate_lines_matched, left.candidate_lines_matched + right.candidate_lines_matched);
    }
}

test "search run uses regex decomposition mmap fast count for large stats-only file" {
    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    var data = try allocator.alloc(u8, 9 * 1024 * 1024);
    @memset(data, 'x');
    var newline_pos: usize = 79;
    while (newline_pos < data.len) : (newline_pos += 80) {
        data[newline_pos] = '\n';
    }
    data[0] = 'S';
    data[1] = 'h';
    data[2] = 'e';
    data[3] = 'r';
    data[4] = 'l';
    data[5] = 'o';
    data[6] = 'c';
    data[7] = 'k';
    data[8] = ' ';
    data[9] = 'H';
    data[10] = 'o';
    data[11] = 'l';
    data[12] = 'm';
    data[13] = 'e';
    data[14] = 's';
    data[15] = '\n';
    try tmp.dir.writeFile(io, .{ .sub_path = "large.txt", .data = data });

    const root_path = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}", .{&tmp.sub_path});
    var request = testSearchRequest("re:Sherlock\\s+Holmes", root_path);
    request.stats_only = true;
    request.threads = 8;
    const plan = try expr.parse(request.expression);
    const report = try run(io, allocator, request, plan);
    try std.testing.expectEqual(@as(usize, 1), report.matches_found);
    try std.testing.expectEqual(@as(usize, 1), report.stats.regex_decomposition.eligible_files);
    try std.testing.expectEqual(@as(usize, 1), report.stats.regex_decomposition.counted_files);
    try std.testing.expectEqual(@as(usize, 1), report.stats.regex_decomposition.candidate_lines_matched);
    try std.testing.expect(report.stats.byte_shard_kernel.enabled);
    try std.testing.expectEqualStrings("regex_decomposition", report.stats.byte_shard_kernel.strategy);
}

test "word-boundary byte range counts exact line-owned semantics" {
    const buffer =
        "PM_RESUME at start\n" ++
        "left_PM_RESUME rejected\n" ++
        "PM_RESUME_right rejected\n" ++
        "two PM_RESUME then PM_RESUME same line\n" ++
        "tail PM_RESUME";

    const all = countWordBoundaryLiteralLogicalLinesRange(buffer, "PM_RESUME", 0, buffer.len);
    try std.testing.expectEqual(@as(usize, 3), all.matches);
    try std.testing.expect(all.verified_candidates >= 5);
    try std.testing.expect(all.rejected_candidates >= 2);
    try std.testing.expectEqual(countWordBoundaryLiteralLines(buffer, "PM_RESUME"), all.matches);
}

test "word-boundary byte ranges preserve whole-buffer count across seams" {
    const buffer =
        "alpha PM_RESUME\n" ++
        "beta_PM_RESUME rejected\n" ++
        "gamma PM_RESUME omega\n" ++
        "PM_RESUME_delta rejected\n" ++
        "last PM_RESUME";
    const expected = countWordBoundaryLiteralLines(buffer, "PM_RESUME");
    const seams = [_]usize{ 1, 7, 16, 29, 47, buffer.len - 1 };
    for (seams) |seam| {
        const left_end = byte_shard.findOwnedLineBoundaryAfter(buffer, seam) orelse buffer.len;
        const left = countWordBoundaryLiteralLogicalLinesRange(buffer, "PM_RESUME", 0, left_end);
        const right = countWordBoundaryLiteralLogicalLinesRange(buffer, "PM_RESUME", left_end, buffer.len);
        try std.testing.expectEqual(expected, left.matches + right.matches);
    }
}

test "word-boundary byte ranges count boundary and final-line cases once" {
    const buffer =
        "PM_RESUME\n" ++
        "split prefix PM_RESUME suffix\n" ++
        "no newline PM_RESUME";
    const first_end = byte_shard.findOwnedLineBoundaryAfter(buffer, 1).?;
    const second_end = byte_shard.findOwnedLineBoundaryAfter(buffer, first_end + 1).?;
    const first = countWordBoundaryLiteralLogicalLinesRange(buffer, "PM_RESUME", 0, first_end);
    const second = countWordBoundaryLiteralLogicalLinesRange(buffer, "PM_RESUME", first_end, second_end);
    const third = countWordBoundaryLiteralLogicalLinesRange(buffer, "PM_RESUME", second_end, buffer.len);
    try std.testing.expectEqual(@as(usize, 1), first.matches);
    try std.testing.expectEqual(@as(usize, 1), second.matches);
    try std.testing.expectEqual(@as(usize, 1), third.matches);
    try std.testing.expectEqual(countWordBoundaryLiteralLines(buffer, "PM_RESUME"), first.matches + second.matches + third.matches);
}

test "trigram gate disables case-insensitive byte semantics" {
    const plan = try expr.parse("lit:Needle");
    const admission = trigram.admit(plan);
    var stats = core_stats.TrigramAccelerationStats{};
    initTrigramStats(&stats, admission, true);

    try std.testing.expect(!stats.eligible);
    try std.testing.expect(!shouldAttemptTrigramPrune("needle\n".len, true, admission, true));
    try std.testing.expectEqual(@as(usize, 0), stats.candidate_files_checked);
    try std.testing.expectEqual(@as(usize, 0), stats.pruned_files);
}

test "evidence frontier cache round trips IXEVIDENCE2 identity and candidates" {
    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const path = ".ix-evidence-test-roundtrip.cache";
    defer std.Io.Dir.cwd().deleteFile(io, path) catch {};

    const files = [_]DiscoveredFile{
        .{ .path = "src/main.zig" },
        .{ .path = "src/core/search.zig" },
    };
    var candidates = [_]DiscoveredFile{files[1]};
    const signature = try computeDiscoveredSignature(io, &files);
    const content_signature = try computeContentSignature(io, &files);
    writeEvidenceFrontierCache(io, path, 0xabc, signature, content_signature, files.len, .{
        .pruned_files = 1,
        .pruned_bytes = 4096,
        .skipped_files = 2,
        .candidates = &candidates,
    });

    const cache = loadEvidenceFrontierCache(io, allocator, path, 0xabc, signature, &files) orelse return error.TestExpectedCacheHit;
    try std.testing.expectEqual(@as(usize, 1), cache.pruned_files);
    try std.testing.expectEqual(@as(usize, 4096), cache.pruned_bytes);
    try std.testing.expectEqual(@as(usize, 2), cache.skipped_files);
    try std.testing.expectEqual(content_signature, cache.content_signature);
    try std.testing.expect(cache.contains("src/core/search.zig"));
    try std.testing.expect(!cache.contains("src/main.zig"));
}

test "evidence frontier cache rejects stale or malformed artifact headers" {
    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const path = ".ix-evidence-test-reject.cache";
    defer std.Io.Dir.cwd().deleteFile(io, path) catch {};

    const files = [_]DiscoveredFile{.{ .path = "src/main.zig" }};
    const signature = try computeDiscoveredSignature(io, &files);
    const key: u64 = 0x1234;

    try writeCacheText(io, path, "IXEVIDENCE1\nkey=1234\nsignature=0\ncontent_signature=0\nfile_count=1\npruned_files=0\npruned_bytes=0\nskipped_files=0\ncandidates=0\n--\n");
    try std.testing.expect(loadEvidenceFrontierCache(io, allocator, path, key, signature, &files) == null);

    try writeCacheText(io, path, try std.fmt.allocPrint(allocator, "IXEVIDENCE2\nkey={x}\nsignature={x}\ncontent_signature=1\nfile_count=2\npruned_files=0\npruned_bytes=0\nskipped_files=0\ncandidates=0\n--\n", .{ key, signature }));
    try std.testing.expect(loadEvidenceFrontierCache(io, allocator, path, key, signature, &files) == null);

    try writeCacheText(io, path, try std.fmt.allocPrint(allocator, "IXEVIDENCE2\nkey={x}\nsignature={x}\ncontent_signature=1\nfile_count=1\npruned_files=0\npruned_bytes=0\nskipped_files=0\ncandidates=2\n--\nsrc/main.zig\n", .{ key, signature }));
    try std.testing.expect(loadEvidenceFrontierCache(io, allocator, path, key, signature, &files) == null);

    try writeCacheText(io, path, try std.fmt.allocPrint(allocator, "IXEVIDENCE2\nkey={x}\nsignature={x}\ncontent_signature=1\nfile_count=1\npruned_files=0\npruned_bytes=0\nskipped_files=0\ncandidates={}\n--\n", .{ key, signature, EVIDENCE_FRONTIER_CACHE_CANDIDATE_LIMIT + 1 }));
    try std.testing.expect(loadEvidenceFrontierCache(io, allocator, path, key, signature, &files) == null);
}

test "evidence frontier signatures are independent of discovery order" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "alpha.txt", .data = "alpha\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "beta.txt", .data = "beta\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "gamma.txt", .data = "gamma\n" });
    var path_buf: [3][256]u8 = undefined;
    const alpha = try std.fmt.bufPrint(&path_buf[0], ".zig-cache/tmp/{s}/alpha.txt", .{&tmp.sub_path});
    const beta = try std.fmt.bufPrint(&path_buf[1], ".zig-cache/tmp/{s}/beta.txt", .{&tmp.sub_path});
    const gamma = try std.fmt.bufPrint(&path_buf[2], ".zig-cache/tmp/{s}/gamma.txt", .{&tmp.sub_path});
    const forward = [_]DiscoveredFile{
        .{ .path = alpha },
        .{ .path = beta },
        .{ .path = gamma },
    };
    const reversed = [_]DiscoveredFile{
        .{ .path = gamma },
        .{ .path = beta },
        .{ .path = alpha },
    };

    try std.testing.expectEqual(
        try computeDiscoveredSignature(io, &forward),
        try computeDiscoveredSignature(io, &reversed),
    );
    try std.testing.expectEqual(
        try computeContentSignature(io, &forward),
        try computeContentSignature(io, &reversed),
    );
}

test "content signature changes for same-length same-path mutations" {
    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    try tmp.dir.writeFile(io, .{ .sub_path = "same-len.txt", .data = "absent\n" });
    const file_path = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}/same-len.txt", .{&tmp.sub_path});
    const files = [_]DiscoveredFile{.{ .path = file_path }};
    const before = try computeContentSignature(io, &files);

    try tmp.dir.writeFile(io, .{ .sub_path = "same-len.txt", .data = "needle\n" });
    const after = try computeContentSignature(io, &files);
    try std.testing.expect(before != after);
}

test "discovered signature changes when same-path file identity changes" {
    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    try tmp.dir.writeFile(io, .{ .sub_path = "identity.txt", .data = "absent\n" });
    const file_path = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}/identity.txt", .{&tmp.sub_path});
    const files = [_]DiscoveredFile{.{ .path = file_path }};
    const before = try computeDiscoveredSignature(io, &files);

    try tmp.dir.writeFile(io, .{ .sub_path = "identity.txt", .data = "needle plus more bytes\n" });
    const after = try computeDiscoveredSignature(io, &files);
    try std.testing.expect(before != after);
}

test "discovered signature remains stable across repeated stats" {
    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(io, .{ .sub_path = "stable.txt", .data = "needle\n" });
    const file_path = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}/stable.txt", .{&tmp.sub_path});
    const files = [_]DiscoveredFile{.{ .path = file_path }};
    const first = try computeDiscoveredSignature(io, &files);
    const second = try computeDiscoveredSignature(io, &files);
    try std.testing.expectEqual(first, second);
}

test "evidence frontier prepare narrows active files and accounts cached prunes" {
    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "pruned.txt", .data = "absent\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "candidate.txt", .data = "needle\n" });
    const root_path = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}", .{&tmp.sub_path});
    const pruned_path = try std.fmt.allocPrint(allocator, "{s}/pruned.txt", .{root_path});
    const candidate_path = try std.fmt.allocPrint(allocator, "{s}/candidate.txt", .{root_path});

    var request = testSearchRequest("lit:needle", root_path);
    request.nexus_build = true;
    const plan = try expr.parse(request.expression);
    const admission = trigram.admit(plan);
    const files = [_]DiscoveredFile{
        .{ .path = pruned_path },
        .{ .path = candidate_path },
    };
    var candidates = [_]DiscoveredFile{files[1]};
    nt_open.initCwdPrefix(io);
    const signature = try computeDiscoveredSignature(io, &files);
    const key = evidenceFrontierKey(request, plan);
    const cache_path = try state_dir.evidenceCachePath(allocator, key);
    defer std.Io.Dir.cwd().deleteFile(io, cache_path) catch {};
    const live_path = try evidenceFrontierLivePath(allocator, cache_path);
    defer std.Io.Dir.cwd().deleteFile(io, live_path) catch {};
    const content_signature = try computeContentSignature(io, &files);
    writeEvidenceFrontierCache(io, cache_path, key, signature, content_signature, files.len, .{
        .pruned_files = 1,
        .pruned_bytes = 123,
        .skipped_files = 4,
        .candidates = &candidates,
    });

    var mutable_files = files;
    var report = testSearchReport(request.expression, plan);
    const prepared = prepareEvidenceFrontier(io, allocator, request, plan, admission, &mutable_files, &report);
    const active = prepared.active_files orelse return error.TestExpectedCacheHit;

    try std.testing.expect(!prepared.runtime.enabled);
    try std.testing.expectEqual(@as(usize, 1), active.len);
    try std.testing.expectEqualStrings(candidate_path, active[0].path);
    try std.testing.expectEqual(@as(usize, 1), report.files_scanned);
    try std.testing.expectEqual(@as(usize, 123), report.bytes_scanned);
    try std.testing.expectEqual(@as(usize, 4), report.files_skipped);
    try std.testing.expectEqual(@as(usize, 1), report.stats.trigram_acceleration.pruned_files);
}

test "evidence frontier rejects stale content signature before foreground admission" {
    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(io, .{ .sub_path = "epoch.txt", .data = "needle\n" });
    const file_path = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}/epoch.txt", .{&tmp.sub_path});
    const files = [_]DiscoveredFile{.{ .path = file_path }};
    const before = try computeContentSignature(io, &files);
    const signature = try computeDiscoveredSignature(io, &files);
    const cache_path = ".ix-evidence-test-stale-content.cache";
    defer std.Io.Dir.cwd().deleteFile(io, cache_path) catch {};
    const live_path = try evidenceFrontierLivePath(allocator, cache_path);
    defer std.Io.Dir.cwd().deleteFile(io, live_path) catch {};
    var retained = [_]DiscoveredFile{files[0]};
    writeEvidenceFrontierCache(io, cache_path, 0x44, signature, before, files.len, .{
        .pruned_files = 0,
        .pruned_bytes = 0,
        .skipped_files = 0,
        .candidates = &retained,
    });
    try tmp.dir.writeFile(io, .{ .sub_path = "epoch.txt", .data = "needle plus more bytes\n" });
    const after = try computeContentSignature(io, &files);
    try std.testing.expect(before != after);
    try std.testing.expect(loadEvidenceFrontierCache(io, allocator, cache_path, 0x44, signature, &files) == null);
}

test "search run builds then consumes the evidence frontier through the owner path" {
    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    try tmp.dir.writeFile(io, .{ .sub_path = "candidate.txt", .data = "needle\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "pruned.txt", .data = "absent\n" });
    const root_path = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}", .{&tmp.sub_path});
    var request = testSearchRequest("lit:needle", root_path);
    request.nexus_build = true;
    const plan = try expr.parse(request.expression);
    const key = evidenceFrontierKey(request, plan);
    const cache_path = try state_dir.evidenceCachePath(allocator, key);
    defer std.Io.Dir.cwd().deleteFile(io, cache_path) catch {};
    const live_path = try evidenceFrontierLivePath(allocator, cache_path);
    defer std.Io.Dir.cwd().deleteFile(io, live_path) catch {};

    const build_report = try run(io, allocator, request, plan);
    try std.testing.expectEqual(@as(usize, 1), build_report.matches_found);
    // A second owner-path pass lets Windows metadata settle and refreshes the
    // cache if the initial temporary-file identity changed after creation.
    _ = try run(io, allocator, request, plan);

    request.nexus_build = false;
    const report = try run(io, allocator, request, plan);
    try std.testing.expectEqual(@as(usize, 2), report.files_discovered);
    try std.testing.expectEqual(@as(usize, 1), report.matches_found);
    try std.testing.expectEqual(@as(usize, 1), report.hit_count);
    try std.testing.expect(std.mem.endsWith(u8, report.hits[0].path, "candidate.txt"));
    try std.testing.expectEqual(@as(usize, 1), report.stats.trigram_acceleration.pruned_files);
    try std.testing.expectEqual(@as(usize, 2), report.files_scanned);
}

test "live evidence frontier rejects same-path mutation before pruning" {
    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    try tmp.dir.writeFile(io, .{ .sub_path = "candidate.txt", .data = "needle\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "pruned.txt", .data = "absent\n" });
    const root_path = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}", .{&tmp.sub_path});
    const request = testSearchRequest("lit:needle", root_path);
    const plan = try expr.parse(request.expression);
    const key = evidenceFrontierKey(request, plan);
    const cache_path = try state_dir.evidenceCachePath(allocator, key);
    defer std.Io.Dir.cwd().deleteFile(io, cache_path) catch {};
    const live_path = try evidenceFrontierLivePath(allocator, cache_path);
    defer std.Io.Dir.cwd().deleteFile(io, live_path) catch {};

    var discovery_report = testSearchReport(request.expression, plan);
    var discovered = try FileList.initWithCapacity(allocator, 4);
    var admission_engine = path_admission.Engine.init(allocator, !request.no_ignore);
    try discoverFiles(io, allocator, root_path, request, &admission_engine, &discovered, &discovery_report);
    const files = discovered.mutableItems();
    try std.testing.expectEqual(@as(usize, 2), files.len);
    const signature = try computeDiscoveredSignature(io, files);
    var retained = [_]DiscoveredFile{candidateFromDiscovered(files) orelse return error.TestExpectedCacheHit};
    const content_signature = try computeContentSignature(io, files);
    writeEvidenceFrontierCache(io, cache_path, key, signature, content_signature, files.len, .{
        .pruned_files = 1,
        .pruned_bytes = 64,
        .skipped_files = 0,
        .candidates = &retained,
    });
    writeEvidenceFrontierLive(io, cache_path, key);

    try tmp.dir.writeFile(io, .{ .sub_path = "pruned.txt", .data = "needle\n" });
    const report = try run(io, allocator, request, plan);

    try std.testing.expectEqual(@as(usize, 2), report.matches_found);
    try std.testing.expectEqual(@as(usize, 2), report.hit_count);
    try std.testing.expectEqual(@as(usize, 2), report.files_scanned);
    try std.testing.expectEqual(@as(usize, 0), report.stats.trigram_acceleration.pruned_files);
}

test "search run consumes live warm postings and scans only candidate files" {
    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    try tmp.dir.writeFile(io, .{ .sub_path = "candidate.txt", .data = "needle\nneedle\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "pruned.txt", .data = "absent\n" });
    const root_path = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}", .{&tmp.sub_path});
    _ = try @import("indexd.zig").publishRootGeneration(io, allocator, root_path);
    const index_dir = try testRootIndexDir(allocator, root_path);
    try std.Io.Dir.cwd().createDirPath(io, index_dir);
    const live_path = try std.fs.path.join(allocator, &.{ index_dir, WARM_INDEX_LIVE_MARKER_NAME });
    defer std.Io.Dir.cwd().deleteFile(io, live_path) catch {};
    const live_marker = try testLiveMarker(allocator, root_path);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = live_path, .data = live_marker });

    var request = testSearchRequest("lit:needle", root_path);
    request.index_enabled = true;
    request.nexus_disabled = true;
    const plan = try expr.parse(request.expression);
    const report = try run(io, allocator, request, plan);

    try std.testing.expect(report.stats.catalog_index.available);
    try std.testing.expect(report.stats.postings_index.available);
    try std.testing.expectEqual(@as(usize, 2), report.files_discovered);
    try std.testing.expectEqual(@as(usize, 1), report.files_scanned);
    try std.testing.expectEqual(@as(usize, 2), report.matches_found);
    try std.testing.expectEqual(@as(usize, 1), report.stats.postings_index.candidate_files);
    try std.testing.expectEqual(@as(usize, 1), report.stats.postings_index.pruned_files);

    const cached_report = try run(io, allocator, request, plan);
    try std.testing.expect(cached_report.stats.postings_index.available);
    try std.testing.expectEqualStrings("live_query_hits_cache", cached_report.stats.generation_refresh.refresh_status);
    try std.testing.expectEqual(@as(usize, 0), cached_report.files_scanned);
    try std.testing.expectEqual(@as(usize, 2), cached_report.matches_found);
    try std.testing.expectEqual(@as(usize, 2), cached_report.hit_count);
    try std.testing.expectEqualStrings(report.hits[0].path, cached_report.hits[0].path);
    try std.testing.expectEqual(report.hits[0].line, cached_report.hits[0].line);
    try std.testing.expectEqual(report.hits[0].column, cached_report.hits[0].column);
    try std.testing.expectEqualStrings(report.hits[0].preview, cached_report.hits[0].preview);

    var capped_request = request;
    capped_request.max_hits = 1;
    const capped_report = try run(io, allocator, capped_request, plan);
    try std.testing.expect(capped_report.stats.postings_index.available);
    try std.testing.expectEqualStrings("live_query_hits_cache", capped_report.stats.generation_refresh.refresh_status);
    try std.testing.expectEqual(@as(usize, 0), capped_report.files_scanned);
    try std.testing.expectEqual(@as(usize, 2), capped_report.matches_found);
    try std.testing.expectEqual(@as(usize, 1), capped_report.hit_count);
    try std.testing.expectEqualStrings(report.hits[0].path, capped_report.hits[0].path);
    try std.testing.expectEqual(report.hits[0].line, capped_report.hits[0].line);
    try std.testing.expectEqual(report.hits[0].column, capped_report.hits[0].column);
    try std.testing.expectEqualStrings(report.hits[0].preview, capped_report.hits[0].preview);

    try tmp.dir.deleteFile(io, "candidate.txt");
    try tmp.dir.writeFile(io, .{ .sub_path = "renamed.txt", .data = "needle\nneedle\n" });

    const stale_report = try run(io, allocator, request, plan);
    try std.testing.expect(!std.mem.eql(u8, stale_report.stats.generation_refresh.refresh_status, "live_query_hits_cache"));
    // The signature check catches the file change before the candidate path probe.
    try std.testing.expect(std.mem.eql(u8, stale_report.stats.generation_refresh.fallback_reason, "stale_signature") or
        std.mem.eql(u8, stale_report.stats.generation_refresh.fallback_reason, "stale_candidate_path"));
    try std.testing.expect(stale_report.files_scanned > 0);
    try std.testing.expectEqual(@as(usize, 2), stale_report.matches_found);
    try std.testing.expectEqual(@as(usize, 2), stale_report.hit_count);
    try std.testing.expect(std.mem.endsWith(u8, stale_report.hits[0].path, "renamed.txt"));
}

test "warm delta generation overlays parent postings without stale base matches" {
    const io = std.testing.io;
    var checked: usize = 0;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    try tmp.dir.writeFile(io, .{ .sub_path = "candidate.txt", .data = "needle\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "fresh.txt", .data = "absent\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "dead.txt", .data = "needle\n" });
    const root_path = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}", .{&tmp.sub_path});
    const base_pin = try @import("indexd.zig").publishRootGeneration(io, allocator, root_path);

    try tmp.dir.writeFile(io, .{ .sub_path = "candidate.txt", .data = "absent\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "fresh.txt", .data = "needle\n" });
    const candidate_path = try std.fs.path.join(allocator, &.{ root_path, "candidate.txt" });
    const fresh_path = try std.fs.path.join(allocator, &.{ root_path, "fresh.txt" });
    const dead_path = try std.fs.path.join(allocator, &.{ root_path, "dead.txt" });
    const delta_epoch = base_pin.epoch + 1;
    const index_dir = try testRootIndexDir(allocator, root_path);
    const delta_paths = try generation.buildGenerationPathsInIndexDir(allocator, index_dir, delta_epoch);
    defer delta_paths.deinit(allocator);
    const delta_catalog = [_]catalog.CatalogFileInput{
        .{
            .path = candidate_path,
            .size = 7,
            .mtime_ns = 2,
            .sample = "absent\n",
        },
        .{
            .path = dead_path,
            .size = 0,
            .mtime_ns = 2,
            .sample = "",
            .tombstone = true,
        },
        .{
            .path = fresh_path,
            .size = 7,
            .mtime_ns = 2,
            .sample = "needle\n",
        },
    };
    const delta_postings = [_]postings.PostingsFileInput{
        .{ .file_id = 3, .bytes = "needle\n" },
    };
    _ = try usn.publishDeltaGeneration(io, allocator, delta_paths, .{
        .root = root_path,
        .root_fingerprint = base_pin.root_fingerprint,
        .epoch = delta_epoch,
        .parent_epoch = base_pin.epoch,
        .catalog_files = &delta_catalog,
        .postings_files = &delta_postings,
    });
    try std.Io.Dir.cwd().createDirPath(io, index_dir);
    const live_path = try std.fs.path.join(allocator, &.{ index_dir, WARM_INDEX_LIVE_MARKER_NAME });
    defer std.Io.Dir.cwd().deleteFile(io, live_path) catch {};
    const live_marker = try testLiveMarker(allocator, root_path);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = live_path, .data = live_marker });

    var request = testSearchRequest("lit:needle", root_path);
    request.index_enabled = true;
    request.nexus_disabled = true;
    const plan = try expr.parse(request.expression);
    const report = try run(io, allocator, request, plan);

    try std.testing.expect(report.stats.catalog_index.available);
    checked += 1;
    try std.testing.expect(report.stats.postings_index.available);
    checked += 1;
    try std.testing.expectEqualStrings("live_delta_pinned", report.stats.generation_refresh.refresh_status);
    checked += 1;
    try std.testing.expectEqualStrings("", report.stats.generation_refresh.fallback_reason);
    checked += 1;
    try std.testing.expectEqual(base_pin.epoch, report.stats.generation_refresh.parent_epoch.?);
    checked += 1;
    try std.testing.expectEqual(delta_epoch, report.stats.generation_refresh.epoch.?);
    checked += 1;
    try std.testing.expectEqual(@as(usize, 3), report.stats.generation_refresh.delta_entries);
    checked += 1;
    try std.testing.expectEqual(@as(usize, 1), report.stats.generation_refresh.delta_tombstones);
    checked += 1;
    try std.testing.expectEqual(@as(usize, 0), report.stats.generation_refresh.base_candidate_files);
    checked += 1;
    try std.testing.expectEqual(@as(usize, 1), report.stats.generation_refresh.delta_candidate_files);
    checked += 1;
    try std.testing.expectEqual(@as(usize, 2), report.stats.generation_refresh.delta_overlay_pruned);
    checked += 1;
    try std.testing.expectEqual(@as(usize, 0), report.stats.generation_refresh.delta_tombstone_pruned);
    checked += 1;
    try std.testing.expectEqualStrings("delta_only", report.stats.generation_refresh.overlay_route);
    checked += 1;
    try std.testing.expectEqual(delta_epoch, report.stats.catalog_index.generation.?);
    checked += 1;
    try std.testing.expectEqual(@as(usize, 2), report.stats.catalog_index.path_count);
    checked += 1;
    try std.testing.expectEqual(@as(usize, 2), report.stats.catalog_index.meta_count);
    checked += 1;
    try std.testing.expectEqualStrings("", report.stats.catalog_index.fallback_reason);
    checked += 1;
    try std.testing.expectEqual(delta_epoch, report.stats.postings_index.generation.?);
    checked += 1;
    try std.testing.expect(report.stats.postings_index.trigram_count > 0);
    checked += 1;
    try std.testing.expect(report.stats.postings_index.postings_count > 0);
    checked += 1;
    try std.testing.expectEqual(@as(usize, 2), report.stats.postings_index.file_count);
    checked += 1;
    try std.testing.expectEqual(@as(usize, 3), report.stats.postings_index.candidate_files);
    checked += 1;
    try std.testing.expectEqual(@as(usize, 1), report.stats.postings_index.pruned_files);
    checked += 1;
    try std.testing.expectEqual(@as(usize, 1), report.stats.postings_index.verified_files);
    checked += 1;
    try std.testing.expectEqualStrings("", report.stats.postings_index.fallback_reason);
    checked += 1;
    try std.testing.expectEqual(@as(usize, 1), report.files_scanned);
    checked += 1;
    try std.testing.expectEqual(@as(usize, 1), report.matches_found);
    checked += 1;
    try std.testing.expectEqual(@as(usize, 1), report.hit_count);
    checked += 1;
    try std.testing.expectEqualStrings(fresh_path, report.hits[0].path);
    checked += 1;
    try std.testing.expect(!std.mem.eql(u8, candidate_path, report.hits[0].path));
    checked += 1;
    try std.testing.expect(!std.mem.eql(u8, dead_path, report.hits[0].path));
    checked += 1;
    try std.testing.expectEqual(@as(usize, 2), report.files_discovered);
    checked += 1;
    try std.testing.expectEqual(@as(usize, 0), report.files_skipped);
    checked += 1;
    try std.testing.expect(report.stats.generation_refresh.available);
    checked += 1;
    try std.testing.expectEqual(@as(usize, 34), checked);
}

test "stats-only live warm postings return empty frontier without catalog scan" {
    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    try tmp.dir.writeFile(io, .{ .sub_path = "a.txt", .data = "needle\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "b.txt", .data = "other\n" });
    const root_path = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}", .{&tmp.sub_path});
    _ = try @import("indexd.zig").publishRootGeneration(io, allocator, root_path);
    const index_dir = try testRootIndexDir(allocator, root_path);
    try std.Io.Dir.cwd().createDirPath(io, index_dir);
    const live_path = try std.fs.path.join(allocator, &.{ index_dir, WARM_INDEX_LIVE_MARKER_NAME });
    defer std.Io.Dir.cwd().deleteFile(io, live_path) catch {};
    const live_marker = try testLiveMarker(allocator, root_path);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = live_path, .data = live_marker });

    var request = testSearchRequest("lit:absent_token", root_path);
    request.index_enabled = true;
    request.nexus_disabled = true;
    request.stats_only = true;
    const plan = try expr.parse(request.expression);
    const report = try run(io, allocator, request, plan);

    try std.testing.expect(report.stats.catalog_index.available);
    try std.testing.expect(report.stats.postings_index.available);
    try std.testing.expectEqualStrings("empty_postings", report.stats.catalog_index.fallback_reason);
    try std.testing.expectEqualStrings("empty_postings", report.stats.postings_index.fallback_reason);
    try std.testing.expectEqual(@as(usize, 2), report.files_discovered);
    try std.testing.expectEqual(@as(usize, 0), report.files_scanned);
    try std.testing.expectEqual(@as(usize, 0), report.matches_found);
    try std.testing.expectEqual(@as(usize, 0), report.stats.postings_index.candidate_files);
    try std.testing.expectEqual(@as(usize, 2), report.stats.postings_index.pruned_files);
}

test "capped warm query hit cache reuses capped-first result" {
    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    try tmp.dir.writeFile(io, .{ .sub_path = "candidate.txt", .data = "needle\nneedle\nneedle\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "pruned.txt", .data = "absent\n" });
    const root_path = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}", .{&tmp.sub_path});
    _ = try @import("indexd.zig").publishRootGeneration(io, allocator, root_path);
    const index_dir = try testRootIndexDir(allocator, root_path);
    try std.Io.Dir.cwd().createDirPath(io, index_dir);
    const live_path = try std.fs.path.join(allocator, &.{ index_dir, WARM_INDEX_LIVE_MARKER_NAME });
    defer std.Io.Dir.cwd().deleteFile(io, live_path) catch {};
    const live_marker = try testLiveMarker(allocator, root_path);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = live_path, .data = live_marker });

    var request = testSearchRequest("lit:needle", root_path);
    request.index_enabled = true;
    request.nexus_disabled = true;
    request.max_hits = 1;
    const plan = try expr.parse(request.expression);

    const first_report = try run(io, allocator, request, plan);
    try std.testing.expect(first_report.stats.postings_index.available);
    try std.testing.expectEqual(@as(usize, 1), first_report.files_scanned);
    try std.testing.expectEqual(@as(usize, 3), first_report.matches_found);
    try std.testing.expectEqual(@as(usize, 1), first_report.hit_count);

    const cached_report = try run(io, allocator, request, plan);
    try std.testing.expect(cached_report.stats.postings_index.available);
    try std.testing.expectEqualStrings("live_query_hits_cache", cached_report.stats.generation_refresh.refresh_status);
    try std.testing.expectEqual(@as(usize, 0), cached_report.files_scanned);
    try std.testing.expectEqual(@as(usize, 3), cached_report.matches_found);
    try std.testing.expectEqual(@as(usize, 1), cached_report.hit_count);
    try std.testing.expectEqualStrings(first_report.hits[0].path, cached_report.hits[0].path);
    try std.testing.expectEqual(first_report.hits[0].line, cached_report.hits[0].line);
    try std.testing.expectEqual(first_report.hits[0].column, cached_report.hits[0].column);
    try std.testing.expectEqualStrings(first_report.hits[0].preview, cached_report.hits[0].preview);
}

test "stats-only warm query cache reuses exact pinned-generation count" {
    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    try tmp.dir.writeFile(io, .{ .sub_path = "candidate.txt", .data = "needle\nneedle\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "pruned.txt", .data = "absent\n" });
    const root_path = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}", .{&tmp.sub_path});
    _ = try @import("indexd.zig").publishRootGeneration(io, allocator, root_path);
    const index_dir = try testRootIndexDir(allocator, root_path);
    try std.Io.Dir.cwd().createDirPath(io, index_dir);
    const live_path = try std.fs.path.join(allocator, &.{ index_dir, WARM_INDEX_LIVE_MARKER_NAME });
    defer std.Io.Dir.cwd().deleteFile(io, live_path) catch {};
    const live_marker = try testLiveMarker(allocator, root_path);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = live_path, .data = live_marker });

    var request = testSearchRequest("lit:needle", root_path);
    request.index_enabled = true;
    request.nexus_disabled = true;
    request.stats_only = true;
    const plan = try expr.parse(request.expression);
    const first = try run(io, allocator, request, plan);
    try std.testing.expectEqual(@as(usize, 2), first.matches_found);
    try std.testing.expectEqual(@as(usize, 1), first.files_scanned);
    try std.testing.expectEqualStrings("live_pinned", first.stats.generation_refresh.refresh_status);

    const root_identity = try catalog.identifyRoot(allocator, root_path);
    defer root_identity.deinit(allocator);
    const stale_index_dir = try testRootIndexDir(allocator, root_path);
    const stale_cache_path = try warmQueryStatsCachePath(allocator, stale_index_dir, root_identity.fingerprint, first.stats.generation_refresh.epoch.?, request.expression);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = stale_cache_path, .data = "IXQUERY_STATS1\nepoch=1\ndiscovered=2\ncandidates=1\nmatches=999\n" });
    const stale_rejected = try run(io, allocator, request, plan);
    try std.testing.expectEqual(@as(usize, 2), stale_rejected.matches_found);
    try std.testing.expectEqual(@as(usize, 1), stale_rejected.files_scanned);
    try std.testing.expect(!std.mem.eql(u8, "live_query_stats_cache", stale_rejected.stats.generation_refresh.refresh_status));

    const cached = try run(io, allocator, request, plan);
    try std.testing.expectEqual(@as(usize, 2), cached.matches_found);
    try std.testing.expectEqual(@as(usize, 0), cached.files_scanned);
    try std.testing.expectEqual(@as(f64, 0), cached.discover_ms);
    try std.testing.expectEqualStrings("live_query_stats_cache", cached.stats.generation_refresh.refresh_status);
    try std.testing.expectEqualStrings("query_stats_cache", cached.stats.postings_index.fallback_reason);
}

test "stats-only warm result cache is content-signature pinned without live index owner" {
    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    try tmp.dir.writeFile(io, .{ .sub_path = "a.txt", .data = "needle\nneedle\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "b.txt", .data = "absent\n" });
    const root_path = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}", .{&tmp.sub_path});

    var request = testSearchRequest("lit:needle", root_path);
    request.stats_only = true;
    const plan = try expr.parse(request.expression);

    const first = try run(io, allocator, request, plan);
    try std.testing.expectEqual(@as(usize, 2), first.matches_found);
    try std.testing.expectEqual(@as(usize, 2), first.files_scanned);
    try std.testing.expectEqualStrings("not_wired", first.stats.generation_refresh.refresh_status);

    const stale_cache_path = try warmStatsResultCachePath(io, allocator, request, plan, true);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = stale_cache_path, .data = "IXWARMSTATS1\ncontent_signature=0\nfile_count=2\nmatches=999\n" });
    const stale_rejected = try run(io, allocator, request, plan);
    try std.testing.expectEqual(@as(usize, 2), stale_rejected.matches_found);
    try std.testing.expectEqual(@as(usize, 2), stale_rejected.files_scanned);
    try std.testing.expectEqualStrings("not_wired", stale_rejected.stats.generation_refresh.refresh_status);

    const cached = try run(io, allocator, request, plan);
    try std.testing.expectEqual(@as(usize, 2), cached.matches_found);
    try std.testing.expectEqual(@as(usize, 0), cached.files_scanned);
    try std.testing.expectEqualStrings("warm_stats_result_cache", cached.stats.generation_refresh.refresh_status);

    try tmp.dir.writeFile(io, .{ .sub_path = "b.txt", .data = "needle\n" });
    const refreshed = try run(io, allocator, request, plan);
    try std.testing.expectEqual(@as(usize, 3), refreshed.matches_found);
    try std.testing.expectEqual(@as(usize, 2), refreshed.files_scanned);
    try std.testing.expectEqualStrings("not_wired", refreshed.stats.generation_refresh.refresh_status);
}

test "warm hidden filter preserves dotfile parity with cold default traversal" {
    try std.testing.expect(!isHiddenDirectoryPath(".rootfile"));
    try std.testing.expect(!isHiddenDirectoryPath("src/.clang-format"));
    try std.testing.expect(isHiddenDirectoryPath(".git/config"));
    try std.testing.expect(isHiddenDirectoryPath("src/.git/config"));
}

test "warm index preserves cold parity for source-bearing directory names" {
    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    try tmp.dir.createDirPath(io, "build");
    try tmp.dir.createDirPath(io, "dist");
    try tmp.dir.createDirPath(io, "target");
    try tmp.dir.createDirPath(io, "vendor");
    try tmp.dir.writeFile(io, .{ .sub_path = "build/frontier.zig", .data = "const marker = \"needle\";\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "dist/frontier.ts", .data = "export const marker = 'needle';\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "target/frontier.rs", .data = "const MARKER: &str = \"needle\";\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "vendor/frontier.c", .data = "const char *marker = \"needle\";\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "visible.txt", .data = "needle\n" });

    const root_path = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}", .{&tmp.sub_path});
    _ = try @import("indexd.zig").publishRootGeneration(io, allocator, root_path);
    const index_dir = try testRootIndexDir(allocator, root_path);
    try std.Io.Dir.cwd().createDirPath(io, index_dir);
    const live_path = try std.fs.path.join(allocator, &.{ index_dir, WARM_INDEX_LIVE_MARKER_NAME });
    defer std.Io.Dir.cwd().deleteFile(io, live_path) catch {};
    const live_marker = try testLiveMarker(allocator, root_path);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = live_path, .data = live_marker });

    var request = testSearchRequest("lit:needle", root_path);
    request.index_enabled = true;
    request.nexus_disabled = true;
    const plan = try expr.parse(request.expression);
    const warm_report = try run(io, allocator, request, plan);

    try std.testing.expectEqualStrings("live_pinned", warm_report.stats.generation_refresh.refresh_status);
    try std.testing.expectEqual(@as(usize, 5), warm_report.matches_found);
    try std.testing.expectEqual(@as(usize, 5), warm_report.hit_count);
    try std.testing.expectEqual(@as(usize, 5), warm_report.files_scanned);
}

test "warm index falls back when root contains unindexed coverage directories" {
    // This test exercises the opt-in signature walk (IX_WARM_SIGNATURE_WALK=1),
    // which detects coverage gaps like unindexed node_modules directories.
    // The default path skips the signature walk for speed; the coverage-gap
    // detection only runs when the walk is explicitly enabled.
    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    // Set the env override for this test process. On Windows, use
    // SetEnvironmentVariableW; on POSIX, use setenv.
    if (@import("builtin").os.tag == .windows) {
        const name_w = std.unicode.utf8ToUtf16LeStringLiteral("IX_WARM_SIGNATURE_WALK");
        const value_w = std.unicode.utf8ToUtf16LeStringLiteral("1");
        _ = WindowsEnv.SetEnvironmentVariableW(name_w, value_w);
    } else {
        _ = std.c.setenv("IX_WARM_SIGNATURE_WALK", "1", 1);
    }

    try tmp.dir.createDirPath(io, "node_modules/pkg");
    try tmp.dir.writeFile(io, .{ .sub_path = "node_modules/pkg/index.js", .data = "const marker = 'needle';\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "visible.txt", .data = "needle\n" });

    const root_path = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}", .{&tmp.sub_path});
    _ = try indexd.publishRootGeneration(io, allocator, root_path);
    const index_dir = try testRootIndexDir(allocator, root_path);
    try std.Io.Dir.cwd().createDirPath(io, index_dir);
    const live_path = try std.fs.path.join(allocator, &.{ index_dir, WARM_INDEX_LIVE_MARKER_NAME });
    defer std.Io.Dir.cwd().deleteFile(io, live_path) catch {};
    const live_marker = try testLiveMarker(allocator, root_path);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = live_path, .data = live_marker });

    var request = testSearchRequest("lit:needle", root_path);
    request.index_enabled = true;
    request.nexus_disabled = true;
    request.no_ignore = true;
    const plan = try expr.parse(request.expression);
    const report = try run(io, allocator, request, plan);

    try std.testing.expectEqualStrings("fallback", report.stats.generation_refresh.refresh_status);
    try std.testing.expectEqualStrings("unindexed_coverage_gap", report.stats.generation_refresh.fallback_reason);
    try std.testing.expectEqual(@as(usize, 2), report.matches_found);
    try std.testing.expectEqual(@as(usize, 2), report.hit_count);
    try std.testing.expectEqual(@as(usize, 2), report.files_scanned);

    // Clean up the env override so it doesn't leak into subsequent tests.
    if (@import("builtin").os.tag == .windows) {
        const name_w = std.unicode.utf8ToUtf16LeStringLiteral("IX_WARM_SIGNATURE_WALK");
        _ = WindowsEnv.SetEnvironmentVariableW(name_w, null);
    } else {
        _ = std.c.unsetenv("IX_WARM_SIGNATURE_WALK");
    }
}

test "capped warm hit query uses stats cache for exact count and prefix scan" {
    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    try tmp.dir.writeFile(io, .{ .sub_path = "a.txt", .data = "needle\nneedle\nneedle\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "b.txt", .data = "needle\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "pruned.txt", .data = "absent\n" });
    const root_path = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}", .{&tmp.sub_path});
    _ = try @import("indexd.zig").publishRootGeneration(io, allocator, root_path);
    const index_dir = try testRootIndexDir(allocator, root_path);
    try std.Io.Dir.cwd().createDirPath(io, index_dir);
    const live_path = try std.fs.path.join(allocator, &.{ index_dir, WARM_INDEX_LIVE_MARKER_NAME });
    defer std.Io.Dir.cwd().deleteFile(io, live_path) catch {};
    const live_marker = try testLiveMarker(allocator, root_path);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = live_path, .data = live_marker });

    var stats_request = testSearchRequest("lit:needle", root_path);
    stats_request.index_enabled = true;
    stats_request.nexus_disabled = true;
    stats_request.stats_only = true;
    const plan = try expr.parse(stats_request.expression);
    const stats_report = try run(io, allocator, stats_request, plan);
    try std.testing.expectEqual(@as(usize, 4), stats_report.matches_found);
    try std.testing.expectEqual(@as(usize, 2), stats_report.files_scanned);

    var capped_request = stats_request;
    capped_request.stats_only = false;
    capped_request.max_hits = 1;
    const capped_report = try run(io, allocator, capped_request, plan);
    try std.testing.expect(capped_report.stats.postings_index.available);
    try std.testing.expectEqualStrings("live_query_cache", capped_report.stats.generation_refresh.refresh_status);
    try std.testing.expectEqual(@as(usize, 4), capped_report.matches_found);
    try std.testing.expectEqual(@as(usize, 1), capped_report.hit_count);
    try std.testing.expectEqual(@as(usize, 1), capped_report.files_scanned);

    const cached_report = try run(io, allocator, capped_request, plan);
    try std.testing.expectEqualStrings("live_query_hits_cache", cached_report.stats.generation_refresh.refresh_status);
    try std.testing.expectEqual(@as(usize, 4), cached_report.matches_found);
    try std.testing.expectEqual(@as(usize, 1), cached_report.hit_count);
    try std.testing.expectEqual(@as(usize, 0), cached_report.files_scanned);
}

test "warm hit query seeds exact stats cache for stats-only reuse" {
    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    try tmp.dir.writeFile(io, .{ .sub_path = "candidate.txt", .data = "needle\nneedle\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "other.txt", .data = "needle\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "pruned.txt", .data = "absent\n" });
    const root_path = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}", .{&tmp.sub_path});
    _ = try @import("indexd.zig").publishRootGeneration(io, allocator, root_path);
    const index_dir = try testRootIndexDir(allocator, root_path);
    try std.Io.Dir.cwd().createDirPath(io, index_dir);
    const live_path = try std.fs.path.join(allocator, &.{ index_dir, WARM_INDEX_LIVE_MARKER_NAME });
    defer std.Io.Dir.cwd().deleteFile(io, live_path) catch {};
    const live_marker = try testLiveMarker(allocator, root_path);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = live_path, .data = live_marker });

    var hit_request = testSearchRequest("lit:needle", root_path);
    hit_request.index_enabled = true;
    hit_request.nexus_disabled = true;
    const plan = try expr.parse(hit_request.expression);
    const hit_report = try run(io, allocator, hit_request, plan);
    try std.testing.expectEqual(@as(usize, 3), hit_report.matches_found);
    try std.testing.expectEqual(@as(usize, 3), hit_report.hit_count);
    try std.testing.expectEqual(@as(usize, 2), hit_report.files_scanned);

    var stats_request = hit_request;
    stats_request.stats_only = true;
    const stats_report = try run(io, allocator, stats_request, plan);
    try std.testing.expectEqualStrings("live_query_stats_cache", stats_report.stats.generation_refresh.refresh_status);
    try std.testing.expectEqual(@as(usize, 3), stats_report.matches_found);
    try std.testing.expectEqual(@as(usize, 0), stats_report.files_scanned);
    try std.testing.expectEqual(@as(usize, 0), stats_report.hit_count);
}

test "protected Windows stats-only roots allow parallel discovery under default ignore policy" {
    if (builtin.os.tag == .windows) {
        var root_items = [_]PreparedRoot{.{
            .original = "C:\\Windows",
            .comparable = "c:/windows",
            .is_directory = true,
        }};
        const roots: PreparedRoots = .{
            .items = &root_items,
            .count = root_items.len,
            .duplicate_count = 0,
            .overlap_pruned_count = 0,
        };
        var request = testSearchRequest("lit:needle", "C:\\Windows");
        request.stats_only = true;
        request.no_ignore = false;
        try std.testing.expect(rootsAllProtectedWindows(roots));
        try std.testing.expect(shouldUseParallelDiscovery(request, roots));
        request.max_hits = 1;
        request.stats_only = false;
        try std.testing.expect(!shouldUseParallelDiscovery(request, roots));
        request.stable_output = true;
        try std.testing.expect(!shouldUseParallelDiscovery(request, roots));
    }
}

fn candidateFromDiscovered(files: []const DiscoveredFile) ?DiscoveredFile {
    for (files) |file| {
        if (std.mem.endsWith(u8, file.path, "candidate.txt")) return file;
    }
    return null;
}

fn writeCacheText(io: std.Io, path: []const u8, data: []const u8) !void {
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = data });
}

fn testSearchRequest(expression: []const u8, path: []const u8) cli.SearchRequest {
    var request = cli.SearchRequest{
        .expression = expression,
        .paths = undefined,
        .path_count = 1,
        .json = false,
        .stats_only = false,
        .hidden = false,
        .line_numbers = false,
        .fixed_strings = false,
        .case_insensitive = false,
        .follow_symlinks = false,
        .no_ignore = false,
        .ignore_files = undefined,
        .ignore_file_count = 0,
        .max_hits = null,
        .threads = null,
        .emit_report = null,
        .nexus_build = false,
        .nexus_disabled = false,
        .index_enabled = false,
    };
    request.paths[0] = path;
    return request;
}

fn testSearchReport(expression_source: []const u8, plan: expr.ExpressionPlan) SearchReport {
    return .{
        .expression = expression_source,
        .cwd = ".",
        .input_roots = 1,
        .effective_roots = 1,
        .pruned_roots = 0,
        .overlap_pruned_roots = 0,
        .discovered_duplicate_paths = 0,
        .collect_hits = true,
        .stats = .{},
        .bytes_scanned = 0,
        .files_discovered = 0,
        .files_scanned = 0,
        .files_skipped = 0,
        .matches_found = 0,
        .truncated = false,
        .slowest_path = "",
        .slowest_bytes = 0,
        .slowest_ms = 0,
        .discover_ms = 0,
        .scan_ms = 0,
        .aggregate_ms = 0,
        .total_ms = 0,
        .scan_work_ms_total = 0,
        .scan_open_ms_total = 0,
        .scan_file_ms_total = 0,
        .capture_scan_open_timing = false,
        .capture_linux_dominant_attribution = false,
        .capture_discovery_skip_bytes = false,
        .matcher_strategy_supported = plan.supportsLargeDirectoryStreamingSelector(),
        .outer_parallel_shard_safe = plan.supportsOuterParallelShardFastCount(),
        .uses_single_literal_counter = plan.usesSingleLiteralCounter(),
        .fast_count_range_overlap = plan.fastMatchCountRangeOverlap(),
        .available_threads = 1,
        .outer_scan_threads = 0,
        .hits = undefined,
        .hit_count = 0,
    };
}

test "joined discovery child path uses bounded buffer when available" {
    var buffer: [64]u8 = undefined;
    const joined = try joinedDiscoveryChildPath(std.testing.allocator, "repo\\src", "main.zig", &buffer);
    defer if (joined.owned) std.testing.allocator.free(joined.path);

    try std.testing.expect(!joined.owned);
    try std.testing.expectEqualStrings("repo/src/main.zig", joined.path);
}

test "joined discovery child path falls back to owned allocation and persist duplicates borrowed path" {
    var tiny_buffer: [8]u8 = undefined;
    const owned = try joinedDiscoveryChildPath(std.testing.allocator, "very-long-parent", "child.txt", &tiny_buffer);
    defer if (owned.owned) std.testing.allocator.free(owned.path);

    try std.testing.expect(owned.owned);
    try std.testing.expectEqualStrings("very-long-parent/child.txt", owned.path);

    var borrowed_buffer: [64]u8 = undefined;
    const borrowed = try joinedDiscoveryChildPath(std.testing.allocator, "repo", "child.txt", &borrowed_buffer);
    try std.testing.expect(!borrowed.owned);

    const persisted = try persistJoinedDiscoveryChildPath(std.testing.allocator, borrowed);
    defer std.testing.allocator.free(persisted);

    borrowed_buffer[0] = 'X';
    try std.testing.expectEqualStrings("repo/child.txt", persisted);
}

test "P20 UCB1 bandit arm computes exploration-exploitation score" {
    // Unexplored arm: should get max priority (high exploration bonus).
    const unexplored = BanditArm{ .prior = 500, .selections = 0 };
    const score_unexplored = unexplored.ucb1(100);
    try std.testing.expect(score_unexplored > 1000.0); // max priority for unexplored

    // Explored arm with high reward: should have good score.
    var high_reward = BanditArm{ .prior = 500, .selections = 10, .total_reward = 100 };
    const score_high = high_reward.ucb1(100);
    try std.testing.expect(score_high > 0.0);

    // Explored arm with low reward: should have lower score.
    var low_reward = BanditArm{ .prior = 100, .selections = 10, .total_reward = 1 };
    const score_low = low_reward.ucb1(100);

    // High-reward arm should score higher than low-reward arm.
    try std.testing.expect(score_high > score_low);
}

test "P20 UCB1 bandit reward update tracks match density" {
    var arm = BanditArm{ .prior = 300 };
    try std.testing.expectEqual(@as(u32, 0), arm.selections);
    try std.testing.expectEqual(@as(u64, 0), arm.total_reward);

    // Simulate scanning 3 files, finding 5, 0, 2 matches respectively.
    updateBanditReward(&arm, 5);
    updateBanditReward(&arm, 0);
    updateBanditReward(&arm, 2);

    try std.testing.expectEqual(@as(u32, 3), arm.selections);
    try std.testing.expectEqual(@as(u64, 7), arm.total_reward);

    // Mean reward = 7/3 ≈ 2.33
    const mean = arm.meanReward();
    try std.testing.expect(mean > 2.0 and mean < 3.0);
}
