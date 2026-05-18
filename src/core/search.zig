const std = @import("std");
const builtin = @import("builtin");
const path_admission = @import("admission.zig");
const cli = @import("../cli/args.zig");
const catalog = @import("catalog.zig");
const expr = @import("expr.zig");
const generation = @import("generation.zig");
const regex = @import("regex.zig");
const pcre_regex = @import("pcre_regex.zig");
const postings = @import("postings.zig");
const core_stats = @import("stats.zig");
const trigram = @import("trigram.zig");
// Pure Zig SIMD search kernels — same VPCMPEQB/VPMOVMSKB/TZCNT instructions
// as StringZilla but inlineable (no FFI call overhead). Eliminates ~5 ns/call
// FFI overhead across ~600K calls per search (~3 ms total). Used on the hottest
// paths: newline scanning, binary sniffing, and literal matching.
const simd = @import("simd.zig");
const sz = @import("sz.zig");

const windows = std.os.windows;
const WARM_INDEX_LIVE_MARKER_NAME = "index.live";
const WARM_INDEX_LIVE_MARKER_MAGIC = "IXINDEX_LIVE1";
const WARM_INDEX_LIVE_READ_LIMIT = 4096;
const WARM_INDEX_SEGMENT_READ_LIMIT: usize = 128 * 1024 * 1024;
const WARM_QUERY_CACHE_MAGIC = "IXQUERY_FRONTIER1";
const WARM_QUERY_STATS_CACHE_MAGIC = "IXQUERY_STATS1";
const WARM_QUERY_HITS_CACHE_MAGIC = "IXQUERY_HITS1";
const WARM_QUERY_CACHE_READ_LIMIT: usize = 4 * 1024 * 1024;
const BINARY_SNIFF_BYTES: usize = 4 * 1024;
const REGEX_DECOMPOSITION_MIN_LITERAL_LEN: usize = 3;
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

// ---------------------------------------------------------------------------
// NT Object Path Bypass (Windows)
//
// Standard file open on Windows routes through RtlGetFullPathName_U which
// acquires the process-global PEB lock (RTL_CRITICAL_SECTION) to canonicalize
// paths. At 32 threads × 79K files, this single mutex serializes all file
// opens: per-file overhead inflates 13.6× from 66 μs (1 thread) to 897 μs
// (32 threads), collapsing parallelism from 32× theoretical to 1.6× measured.
//
// Fix: construct NT object paths (\??\E:\path\to\file) before calling openFile.
// The stdlib's wToPrefixedFileW checks hasCommonNtPrefix first — if the \??\
// prefix is present, it memcpys the path directly. No RtlGetFullPathName_U,
// no PEB lock, no contention. NtCreateFile receives the absolute NT path with
// RootDirectory=null and resolves it independently per thread.
// ---------------------------------------------------------------------------

/// NT CWD prefix: \??\E:\path\to\cwd\ (backslash-terminated UTF-8).
/// Resolved once on the main thread in run(), read-only during parallel scan.
var g_nt_cwd_prefix: [1024]u8 = undefined;
var g_nt_cwd_prefix_len: usize = 0;

/// Resolves CWD into NT object path prefix. Single-threaded, called once.
fn initNtCwdPrefix(io: std.Io) void {
    if (comptime builtin.os.tag != .windows) return;
    const nt_hdr = "\\??\\";
    @memcpy(g_nt_cwd_prefix[0..nt_hdr.len], nt_hdr);
    const cwd_len = std.process.currentPath(io, g_nt_cwd_prefix[nt_hdr.len .. g_nt_cwd_prefix.len - 1]) catch return;
    var total = nt_hdr.len + cwd_len;
    // CWD from RtlGetCurrentDirectory_U uses backslashes; normalize any stray forward slashes.
    for (g_nt_cwd_prefix[nt_hdr.len..total]) |*b| {
        if (b.* == '/') b.* = '\\';
    }
    if (total == 0 or g_nt_cwd_prefix[total - 1] != '\\') {
        g_nt_cwd_prefix[total] = '\\';
        total += 1;
    }
    g_nt_cwd_prefix_len = total;
}

/// Opens a file using NT object path to bypass RtlGetFullPathName_U PEB lock.
/// Constructs \??\{CWD}\{path} on the stack with / → \ conversion.
/// Falls back to standard openFile for non-Windows, unresolved CWD, or overflow.
fn openFileNt(io: std.Io, display_path: []const u8) !std.Io.File {
    if (comptime builtin.os.tag != .windows)
        return std.Io.Dir.cwd().openFile(io, display_path, .{ .allow_directory = false });
    if (g_nt_cwd_prefix_len == 0)
        return std.Io.Dir.cwd().openFile(io, display_path, .{ .allow_directory = false });

    // Absolute paths (drive letter) get \??\ prefix; relative paths get \??\{CWD}\.
    const nt_hdr: []const u8 = "\\??\\";
    const is_abs = display_path.len >= 2 and display_path[1] == ':' and
        ((display_path[0] >= 'A' and display_path[0] <= 'Z') or
            (display_path[0] >= 'a' and display_path[0] <= 'z'));
    const prefix = if (is_abs) nt_hdr else g_nt_cwd_prefix[0..g_nt_cwd_prefix_len];
    const total_len = prefix.len + display_path.len;

    var nt_buf: [1280]u8 = undefined;
    if (total_len > nt_buf.len)
        return std.Io.Dir.cwd().openFile(io, display_path, .{ .allow_directory = false });

    @memcpy(nt_buf[0..prefix.len], prefix);
    @memcpy(nt_buf[prefix.len..][0..display_path.len], display_path);
    // NT namespace requires backslash separators. Collapse consecutive separators
    // in one pass — NT Object Manager rejects adjacent backslashes (STATUS_OBJECT_NAME_INVALID).
    // This handles root paths with trailing slash producing "dir//file" via joinPathForward.
    var write_pos: usize = 0;
    for (nt_buf[0..total_len]) |b| {
        const c = if (b == '/') @as(u8, '\\') else b;
        if (write_pos > 0 and c == '\\' and nt_buf[write_pos - 1] == '\\') continue;
        nt_buf[write_pos] = c;
        write_pos += 1;
    }
    return std.Io.Dir.cwd().openFile(io, nt_buf[0..write_pos], .{ .allow_directory = false });
}

/// Maximum hit records retained in the report. Beyond this count, matches
/// are still counted for stats but individual hit records are not stored.
/// This bounds memory usage for searches that hit millions of lines.
pub const MAX_RETAINED_HITS = 4096;

const TRIGRAM_MIN_PRUNE_BYTES: usize = 64 * 1024;
const BYTE_SHARD_MIN_FILE_BYTES: usize = 8 * 1024 * 1024;
const BYTE_SHARD_MIN_RANGE_BYTES: usize = 4 * 1024 * 1024;
const BYTE_SHARD_WORD_BOUNDARY_MIN_FILE_BYTES: usize = 1 * 1024 * 1024;
const BYTE_SHARD_WORD_BOUNDARY_MIN_RANGE_BYTES: usize = 2 * 1024 * 1024;
const BYTE_SHARD_DEFAULT_MAX_RANGES: usize = 64;
const BYTE_SHARD_LINE_BOUNDARY_SEARCH_LIMIT: usize = 1024 * 1024;
const EVIDENCE_FRONTIER_CACHE_MAGIC = "IXEVIDENCE2";
const EVIDENCE_FRONTIER_LIVE_MAGIC = "IXEVIDENCELIVE1";
const EVIDENCE_FRONTIER_CACHE_READ_LIMIT = 64 * 1024 * 1024;
const EVIDENCE_FRONTIER_LIVE_READ_LIMIT = 4096;
const EVIDENCE_FRONTIER_CACHE_CANDIDATE_LIMIT = 262144;
const EVIDENCE_FRONTIER_LIVE_TTL_NS: i96 = 120 * std.time.ns_per_s;
const EVIDENCE_FRONTIER_BUILD_TTL_NS: i128 = 120 * std.time.ns_per_s;

/// Comptime predicate specialization for single-predicate plans. When passed to
/// scanOpenFileIntoShardImpl / recordLineIntoShardImpl, the per-line match
/// dispatch collapses to a direct call at compile time — zero runtime switches.
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
};

pub const SearchReport = struct {
    expression: []const u8,
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
    truncated: bool,
    slowest_path: []const u8,
    slowest_bytes: usize,
    slowest_ms: f64,
    discover_ms: f64,
    scan_ms: f64,
    aggregate_ms: f64,
    total_ms: f64,
    scan_work_ms_total: f64,
    matcher_strategy_supported: bool,
    outer_parallel_shard_safe: bool,
    uses_single_literal_counter: bool,
    fast_count_range_overlap: ?usize,
    available_threads: usize,
    outer_scan_threads: usize,
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
        .truncated = false,
        .slowest_path = "",
        .slowest_bytes = 0,
        .slowest_ms = 0,
        .discover_ms = 0,
        .scan_ms = 0,
        .aggregate_ms = 0,
        .total_ms = 0,
        .scan_work_ms_total = 0,
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
    const trigram_program = TrigramAdmissionProgram.compile(trigram_admission);
    initTrigramStats(&report.stats.trigram_acceleration, trigram_admission, request.case_insensitive);
    report.stats.admission.enabled = !request.no_ignore;

    if (prepareWarmIndexFrontier(io, allocator, request, plan, &report)) |warm_prepared| {
        try scanPreparedFiles(io, allocator, warm_prepared.active_files, request, plan, trigram_admission, &trigram_program, &report);
        if (request.stats_only and !report.truncated and !warm_prepared.stats_result_cache_hit) {
            writeWarmQueryStatsResult(io, allocator, warm_prepared, request, report);
        }
        if (!request.stats_only and request.max_hits == null and !report.truncated and !warm_prepared.hit_result_cache_hit) {
            writeWarmQueryHitResult(io, allocator, warm_prepared, request, report);
        }
        report.total_ms = elapsedMs(io, total_started);
        refreshStats(&report);
        return report;
    }

    if (prepareLiveEvidenceFrontier(io, allocator, request, plan, trigram_admission, &report)) |live_prepared| {
        try scanPreparedFiles(io, allocator, live_prepared.active_files.?, request, plan, trigram_admission, &trigram_program, &report);
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
    if (!try discoverRootsParallelTopLevel(io, allocator, roots, request, &file_list, &report)) {
        for (roots.items[0..roots.count]) |root| {
            try discoverFiles(io, allocator, root.original, request, &admission_engine, &file_list, &report);
        }
    }
    report.discover_ms = elapsedMs(io, discover_started);

    // Resolve CWD → NT object path prefix once, before spawning scan threads.
    // All workers read g_nt_cwd_prefix without contention (immutable after init).
    initNtCwdPrefix(io);

    // Phase 2: Scan files — thread count adapts to corpus size after discovery.
    const scan_started = std.Io.Timestamp.now(io, .awake);
    const discovered_mut = file_list.mutableItems();
    const evidence_prepared = prepareEvidenceFrontier(io, allocator, request, plan, trigram_admission, discovered_mut, &report);
    const active_files = evidence_prepared.active_files orelse discovered_mut;
    const thread_count = effectiveThreadCount(request, active_files.len);
    report.outer_scan_threads = thread_count;

    // Shuffle file list to distribute NTFS directory lock contention across threads.
    // Without shuffle, depth-first ordering causes all threads to contend on the same
    // directory's FCB lock in NtCreateFile — overhead inflates 13.6× at 32 threads.
    // Only for parallel mode: single-threaded benefits from sequential FS locality.
    if (thread_count > 1) shuffleFiles(active_files);
    const discovered: []const DiscoveredFile = active_files;
    if (discovered.len == 0) {
        // No files discovered — nothing to scan.
    } else if (thread_count <= 1 or discovered.len < 4) {
        // Serial path: single thread or too few files to justify workers.
        for (discovered) |entry| {
            try scanDiscoveredFile(io, allocator, entry.path, request, plan, trigram_admission, &trigram_program, &report);
            if (report.truncated) break;
        }
    } else {
        try parallelScanFiles(io, allocator, discovered, request, plan, trigram_admission, &trigram_program, thread_count, evidence_prepared.runtime, &report);
    }
    report.scan_ms = elapsedMs(io, scan_started);

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
    initNtCwdPrefix(io);
    const scan_started = std.Io.Timestamp.now(io, .awake);
    const thread_count = effectiveThreadCount(request, active_files.len);
    report.outer_scan_threads = thread_count;
    if (thread_count > 1) shuffleFiles(active_files);
    const discovered: []const DiscoveredFile = active_files;
    if (discovered.len == 0) {
        // Fully pruned frontier.
    } else if (thread_count <= 1 or discovered.len < 4) {
        for (discovered) |entry| {
            try scanDiscoveredFile(io, allocator, entry.path, request, plan, trigram_admission, trigram_program, report);
            if (report.truncated) break;
        }
    } else {
        try parallelScanFiles(io, allocator, discovered, request, plan, trigram_admission, trigram_program, thread_count, .{}, report);
    }
    report.scan_ms = elapsedMs(io, scan_started);
    const aggregate_started = std.Io.Timestamp.now(io, .awake);
    report.aggregate_ms = elapsedMs(io, aggregate_started);
}

/// Adaptive thread count scaling based on file count.
///
/// Each thread spawn costs ~100 μs on Windows (CreateThread + stack alloc).
/// Spawning 32 threads for 100 files adds ~3 ms to a 12 ms search — 25%
/// overhead with no throughput gain since one large file dominates.
///
/// sqrt(file_count) grows sub-linearly, clamped to [4, cpu_count]:
///   100 files → 10 threads
///   600 files → 24 threads
///  1000 files → 31 threads
///  5000 files → capped at cpu count
fn effectiveThreadCount(request: cli.SearchRequest, file_count: usize) usize {
    if (request.threads) |threads| return @max(threads, 1);
    const cpus = availableThreads();
    if (file_count <= 4) return @min(cpus, @max(file_count, 1));
    const sqrt_files = std.math.sqrt(@as(f64, @floatFromInt(file_count)));
    const scaled: usize = @intFromFloat(@min(sqrt_files, @as(f64, @floatFromInt(cpus))));
    return @max(scaled, 4);
}

/// A discovered file entry — path is arena-allocated and lives for the
/// process lifetime.
const DiscoveredFile = struct {
    path: []const u8,
};

const WarmIndexFrontier = struct {
    active_files: []DiscoveredFile,
    root: []const u8,
    root_fingerprint: catalog.RootFingerprint,
    epoch: generation.Epoch,
    discovered: usize,
    candidate_count: usize,
    stats_result_cache_hit: bool = false,
    hit_result_cache_hit: bool = false,
};

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

    if (request.case_insensitive) return warmIndexFallback(report, "case_insensitive");
    if (request.follow_symlinks) return warmIndexFallback(report, "follow_symlinks");
    if (request.hidden) return warmIndexFallback(report, "hidden_not_indexed");
    if (request.path_count != 1) return warmIndexFallback(report, "multi_root");

    const root = request.paths[0];
    const root_identity = catalog.identifyRoot(allocator, root) catch return warmIndexFallback(report, "root_identity_failed");
    defer root_identity.deinit(allocator);

    const marker_path = std.fs.path.join(allocator, &.{ root, ".ix", "index", WARM_INDEX_LIVE_MARKER_NAME }) catch return warmIndexFallback(report, "marker_path_failed");
    defer allocator.free(marker_path);
    const marker_bytes = std.Io.Dir.cwd().readFileAlloc(io, marker_path, allocator, .limited(WARM_INDEX_LIVE_READ_LIMIT)) catch return warmIndexFallback(report, "no_live_owner");
    defer allocator.free(marker_bytes);
    if (!validateWarmIndexLiveMarker(marker_bytes, root)) return warmIndexFallback(report, "invalid_live_owner");

    const current_paths = generation.buildGenerationPaths(allocator, root, 1) catch return warmIndexFallback(report, "paths_failed");
    defer current_paths.deinit(allocator);
    const pin = (generation.tryPinCurrentGeneration(io, allocator, current_paths.current_manifest_path, root_identity.fingerprint) catch return warmIndexFallback(report, "pin_failed")) orelse return warmIndexFallback(report, "no_current_generation");

    const lookup = postings.lowerExpressionToLookupPlan(plan);
    if (postings.lookupRequiresFullScan(lookup)) return warmIndexFallback(report, postings.lookupFallbackReasonText(lookup));

    if (request.stats_only) {
        if (loadWarmQueryStatsResult(io, allocator, root, root_identity.fingerprint, pin.epoch, request, report)) |cached| {
            return cached;
        }
    } else {
        if (loadWarmQueryHitResult(io, allocator, root, root_identity.fingerprint, pin.epoch, request, report)) |cached| {
            return cached;
        }
    }

    if (loadWarmQueryFrontier(io, allocator, root, root_identity.fingerprint, pin.epoch, request, report)) |cached| {
        return .{
            .active_files = cached,
            .root = root,
            .root_fingerprint = root_identity.fingerprint,
            .epoch = pin.epoch,
            .discovered = report.files_discovered,
            .candidate_count = cached.len,
        };
    }

    const paths = generation.buildGenerationPaths(allocator, root, pin.epoch) catch return warmIndexFallback(report, "generation_paths_failed");
    defer paths.deinit(allocator);
    const catalog_path = std.fs.path.join(allocator, &.{ paths.generation_dir, "catalog.ixcat" }) catch return warmIndexFallback(report, "catalog_path_failed");
    defer allocator.free(catalog_path);
    const postings_path = std.fs.path.join(allocator, &.{ paths.generation_dir, "postings.ixpost" }) catch return warmIndexFallback(report, "postings_path_failed");
    defer allocator.free(postings_path);

    const catalog_bytes = std.Io.Dir.cwd().readFileAlloc(io, catalog_path, allocator, .limited(WARM_INDEX_SEGMENT_READ_LIMIT)) catch return warmIndexFallback(report, "catalog_read_failed");
    defer allocator.free(catalog_bytes);
    const snapshot = catalog.parseCatalogForRoot(allocator, catalog_bytes, root_identity.fingerprint) catch |err| return warmIndexFallback(report, @errorName(err));
    defer snapshot.deinit(allocator);
    if (snapshot.header.generation != pin.epoch) return warmIndexFallback(report, "catalog_generation_mismatch");

    const lookup_result = postings.evaluateLookupPlanFromFile(io, allocator, postings_path, root_identity.fingerprint, pin.epoch, lookup) catch |err| return warmIndexFallback(report, @errorName(err));
    defer lookup_result.deinit(allocator);
    const candidate_ids = lookup_result.candidates;
    const selected = postings.selectCatalogEntriesForCandidates(allocator, snapshot, candidate_ids) catch return warmIndexFallback(report, "candidate_select_failed");
    defer allocator.free(selected);

    var active = std.ArrayList(DiscoveredFile).empty;
    errdefer active.deinit(allocator);
    for (selected) |entry| {
        const path = snapshot.path(entry);
        if (!request.hidden and isHiddenPath(warmIndexRelativePath(root, path))) continue;
        active.append(allocator, .{ .path = allocator.dupe(u8, path) catch return warmIndexFallback(report, "candidate_path_alloc_failed") }) catch return warmIndexFallback(report, "candidate_append_failed");
    }
    var verify_required_count: usize = 0;
    appendWarmVerificationFrontier(allocator, root, request, snapshot, candidate_ids, &active, &verify_required_count) catch return warmIndexFallback(report, "verify_required_append_failed");

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
    writeWarmQueryFrontier(io, allocator, root, root_identity.fingerprint, pin.epoch, request, snapshot.entries.len, owned);
    return .{
        .active_files = owned,
        .root = root,
        .root_fingerprint = root_identity.fingerprint,
        .epoch = pin.epoch,
        .discovered = snapshot.entries.len,
        .candidate_count = owned.len,
    };
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
        if (!request.hidden and isHiddenPath(warmIndexRelativePath(root, path))) continue;
        try active.append(allocator, .{ .path = try allocator.dupe(u8, path) });
    }
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
    return validateWarmIndexLiveMarkerWithOwnerCheck(bytes, expected_root, false);
}

fn validateWarmIndexLiveMarkerWithOwnerCheck(bytes: []const u8, expected_root: []const u8, check_owner: bool) bool {
    var lines = std.mem.splitScalar(u8, bytes, '\n');
    if (!std.mem.eql(u8, std.mem.trimEnd(u8, lines.next() orelse return false, "\r"), WARM_INDEX_LIVE_MARKER_MAGIC)) return false;
    const pid_line = std.mem.trimEnd(u8, lines.next() orelse return false, "\r");
    const root_line = std.mem.trimEnd(u8, lines.next() orelse return false, "\r");
    if (!std.mem.startsWith(u8, pid_line, "pid=")) return false;
    if (!std.mem.startsWith(u8, root_line, "root=")) return false;
    const owner_pid = std.fmt.parseInt(usize, pid_line["pid=".len..], 10) catch return false;
    if (owner_pid == 0) return false;
    const marker_root = root_line["root=".len..];
    if (!std.mem.eql(u8, marker_root, expected_root)) return false;
    if (check_owner and builtin.os.tag == .windows) {
        if (!processIsAlive(@intCast(owner_pid))) return false;
    }
    return true;
}

fn warmIndexRelativePath(root: []const u8, path: []const u8) []const u8 {
    if (!std.mem.startsWith(u8, path, root)) return path;
    var offset = root.len;
    while (offset < path.len and (path[offset] == '/' or path[offset] == '\\')) : (offset += 1) {}
    return path[offset..];
}

fn loadWarmQueryFrontier(
    io: std.Io,
    allocator: std.mem.Allocator,
    root: []const u8,
    root_fingerprint: catalog.RootFingerprint,
    epoch: generation.Epoch,
    request: cli.SearchRequest,
    report: *SearchReport,
) ?[]DiscoveredFile {
    const cache_path = warmQueryCachePath(allocator, root, root_fingerprint, epoch, request.expression) catch return null;
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

fn loadWarmQueryStatsResult(
    io: std.Io,
    allocator: std.mem.Allocator,
    root: []const u8,
    root_fingerprint: catalog.RootFingerprint,
    epoch: generation.Epoch,
    request: cli.SearchRequest,
    report: *SearchReport,
) ?WarmIndexFrontier {
    const cache_path = warmQueryStatsCachePath(allocator, root, root_fingerprint, epoch, request.expression) catch return null;
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
    const discovered = std.fmt.parseInt(usize, discovered_line["discovered=".len..], 10) catch return null;
    const candidates = std.fmt.parseInt(usize, candidates_line["candidates=".len..], 10) catch return null;
    const matches = std.fmt.parseInt(usize, matches_line["matches=".len..], 10) catch return null;

    report.discover_ms = 0;
    report.files_discovered = discovered;
    report.files_scanned = 0;
    report.matches_found = matches;
    report.stats.generation_refresh.available = true;
    report.stats.generation_refresh.epoch = epoch;
    report.stats.generation_refresh.refresh_status = "live_query_stats_cache";
    report.stats.generation_refresh.fallback_reason = "";
    report.stats.catalog_index.available = true;
    report.stats.catalog_index.generation = epoch;
    report.stats.catalog_index.path_count = discovered;
    report.stats.catalog_index.fallback_reason = "query_stats_cache";
    report.stats.postings_index.available = true;
    report.stats.postings_index.generation = epoch;
    report.stats.postings_index.file_count = discovered;
    report.stats.postings_index.candidate_files = candidates;
    report.stats.postings_index.pruned_files = discovered - candidates;
    report.stats.postings_index.verified_files = 0;
    report.stats.postings_index.fallback_reason = "query_stats_cache";

    const empty = allocator.alloc(DiscoveredFile, 0) catch return null;
    return .{
        .active_files = empty,
        .root = root,
        .root_fingerprint = root_fingerprint,
        .epoch = epoch,
        .discovered = discovered,
        .candidate_count = candidates,
        .stats_result_cache_hit = true,
    };
}

fn loadWarmQueryHitResult(
    io: std.Io,
    allocator: std.mem.Allocator,
    root: []const u8,
    root_fingerprint: catalog.RootFingerprint,
    epoch: generation.Epoch,
    request: cli.SearchRequest,
    report: *SearchReport,
) ?WarmIndexFrontier {
    const cache_path = warmQueryHitsCachePath(allocator, root, root_fingerprint, epoch, report.expression) catch return null;
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
        if (loaded < retained_hit_count) {
            report.hits[loaded] = .{
                .path = unescapeWarmQueryField(allocator, path_encoded) catch return null,
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

fn writeWarmQueryFrontier(
    io: std.Io,
    allocator: std.mem.Allocator,
    root: []const u8,
    root_fingerprint: catalog.RootFingerprint,
    epoch: generation.Epoch,
    request: cli.SearchRequest,
    discovered: usize,
    active: []const DiscoveredFile,
) void {
    const query_dir = std.fs.path.join(allocator, &.{ root, ".ix", "index", "query" }) catch return;
    defer allocator.free(query_dir);
    std.Io.Dir.cwd().createDirPath(io, query_dir) catch return;
    const cache_path = warmQueryCachePath(allocator, root, root_fingerprint, epoch, request.expression) catch return;
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
    if (request.stats_only or request.max_hits != null) return;
    const query_dir = std.fs.path.join(allocator, &.{ prepared.root, ".ix", "index", "query" }) catch return;
    defer allocator.free(query_dir);
    std.Io.Dir.cwd().createDirPath(io, query_dir) catch return;
    const cache_path = warmQueryHitsCachePath(allocator, prepared.root, prepared.root_fingerprint, prepared.epoch, request.expression) catch return;
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
    if (!request.stats_only) return;
    const query_dir = std.fs.path.join(allocator, &.{ prepared.root, ".ix", "index", "query" }) catch return;
    defer allocator.free(query_dir);
    std.Io.Dir.cwd().createDirPath(io, query_dir) catch return;
    const cache_path = warmQueryStatsCachePath(allocator, prepared.root, prepared.root_fingerprint, prepared.epoch, request.expression) catch return;
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
    root: []const u8,
    root_fingerprint: catalog.RootFingerprint,
    epoch: generation.Epoch,
    expression: []const u8,
) ![]const u8 {
    const hash = warmQueryHash(root_fingerprint, epoch, expression);
    const file_name = try std.fmt.allocPrint(allocator, "{x}.ixq", .{hash});
    defer allocator.free(file_name);
    return std.fs.path.join(allocator, &.{ root, ".ix", "index", "query", file_name });
}

fn warmQueryStatsCachePath(
    allocator: std.mem.Allocator,
    root: []const u8,
    root_fingerprint: catalog.RootFingerprint,
    epoch: generation.Epoch,
    expression: []const u8,
) ![]const u8 {
    const hash = warmQueryHash(root_fingerprint, epoch, expression) ^ 0x535441545331;
    const file_name = try std.fmt.allocPrint(allocator, "{x}.ixqs", .{hash});
    defer allocator.free(file_name);
    return std.fs.path.join(allocator, &.{ root, ".ix", "index", "query", file_name });
}

fn warmQueryHitsCachePath(
    allocator: std.mem.Allocator,
    root: []const u8,
    root_fingerprint: catalog.RootFingerprint,
    epoch: generation.Epoch,
    expression: []const u8,
) ![]const u8 {
    const hash = warmQueryHash(root_fingerprint, epoch, expression) ^ 0x4849545331;
    const file_name = try std.fmt.allocPrint(allocator, "{x}.ixqh", .{hash});
    defer allocator.free(file_name);
    return std.fs.path.join(allocator, &.{ root, ".ix", "index", "query", file_name });
}

fn warmQueryHash(root_fingerprint: catalog.RootFingerprint, epoch: generation.Epoch, expression: []const u8) u64 {
    var seed = std.hash.Wyhash.hash(0x4958515545525931, std.mem.asBytes(&root_fingerprint));
    seed = std.hash.Wyhash.hash(seed ^ epoch, expression);
    return seed;
}

/// Growable list of discovered files. Uses a flat array with doubling growth.
const FileList = struct {
    buffer: ?[*]DiscoveredFile,
    len: usize,
    capacity: usize,

    const empty: FileList = .{ .buffer = null, .len = 0, .capacity = 0 };

    fn initWithCapacity(allocator: std.mem.Allocator, cap: usize) !FileList {
        const buf = try allocator.alloc(DiscoveredFile, cap);
        return .{ .buffer = buf.ptr, .len = 0, .capacity = cap };
    }

    fn append(self: *FileList, allocator: std.mem.Allocator, entry: DiscoveredFile) !void {
        if (self.len == self.capacity) {
            const new_cap = if (self.capacity == 0) 64 else self.capacity * 2;
            const new_buf = try allocator.alloc(DiscoveredFile, new_cap);
            if (self.buffer) |old| {
                @memcpy(new_buf[0..self.len], old[0..self.len]);
            }
            self.buffer = new_buf.ptr;
            self.capacity = new_cap;
        }
        self.buffer.?[self.len] = entry;
        self.len += 1;
    }

    fn items(self: *const FileList, _: std.mem.Allocator) []const DiscoveredFile {
        if (self.buffer) |buf| return buf[0..self.len];
        return &[_]DiscoveredFile{};
    }

    fn mutableItems(self: *FileList) []DiscoveredFile {
        if (self.buffer) |buf| return buf[0..self.len];
        return &[_]DiscoveredFile{};
    }
};

/// Shuffle file list to distribute kernel-level NTFS directory lock contention.
///
/// Discovery walks depth-first, so adjacent files share the same parent directory.
/// With dynamic work claiming, all 32 threads contend on the same directory's FCB
/// lock in NtCreateFile. Shuffling interleaves files from different directories,
/// spreading concurrent opens across independent kernel locks.
///
/// Uses XorShift64 with fixed seed — deterministic, no allocation, O(n).
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

fn prepareLiveEvidenceFrontier(
    io: std.Io,
    allocator: std.mem.Allocator,
    request: cli.SearchRequest,
    plan: expr.ExpressionPlan,
    admission: trigram.Admission,
    report: *SearchReport,
) ?EvidenceFrontierPrepared {
    if (request.nexus_disabled) return null;
    if (!evidenceFrontierEligible(request, plan, admission)) return null;
    const key = evidenceFrontierKey(request, plan);
    const cache_path = std.fmt.allocPrint(allocator, ".ix-evidence-{x}.cache", .{key}) catch return null;
    const live_path = evidenceFrontierLivePath(allocator, cache_path) catch return null;
    if (!loadEvidenceFrontierLive(io, allocator, live_path, key)) return null;
    const cache = loadEvidenceFrontierCacheFast(io, allocator, cache_path, key) orelse return null;

    var evidence_files: std.ArrayList(DiscoveredFile) = .empty;
    for (cache.candidates) |candidate| evidence_files.append(allocator, .{ .path = candidate }) catch return null;
    report.files_discovered = cache.file_count;
    report.files_scanned += cache.pruned_files;
    report.bytes_scanned += cache.pruned_bytes;
    report.files_skipped += cache.skipped_files;
    report.stats.trigram_acceleration.pruned_files += cache.pruned_files;
    return .{ .active_files = evidence_files.toOwnedSlice(allocator) catch return null };
}

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
    const cache_path = std.fmt.allocPrint(allocator, ".ix-evidence-{x}.cache", .{key}) catch return false;
    defer allocator.free(cache_path);
    const live_path = evidenceFrontierLivePath(allocator, cache_path) catch return false;
    defer allocator.free(live_path);
    if (loadEvidenceFrontierLive(io, allocator, live_path, key)) return false;
    const build_path = evidenceFrontierBuildPath(allocator, cache_path) catch return false;
    defer allocator.free(build_path);
    if (evidenceFrontierBuildClaimFresh(io, build_path)) return false;
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
    if (!request.nexus_build) return .{};
    const signature = computeDiscoveredSignature(io, files) catch return .{};
    const key = evidenceFrontierKey(request, plan);
    const cache_path = std.fmt.allocPrint(allocator, ".ix-evidence-{x}.cache", .{key}) catch return .{};

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
    if (!admission.eligible and !(plan.predicate_count == 1 and fileAdmissionNeedleRuntime(plan.predicates[0]) != null)) return false;
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

fn computeDiscoveredSignature(io: std.Io, files: []const DiscoveredFile) !u64 {
    _ = io;
    var xor_acc: u64 = 0;
    var sum_acc: u64 = 0;
    for (files) |entry| {
        const item_hash = hashBytes64(0x4556_4944_5041_5448, entry.path);
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
        var file = try openFileNt(io, entry.path);
        defer file.close(io);
        const stat = try file.stat(io);
        var item = std.hash.Wyhash.init(0x4556_4944_4649_4c45);
        item.update(entry.path);
        hashU64(&item, stat.size);
        hashU64(&item, @bitCast(stat.inode));
        hashTimestamp(&item, stat.mtime);
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
        const line = std.mem.trimEnd(u8, raw_line, "\r");
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

fn loadEvidenceFrontierCacheFast(
    io: std.Io,
    allocator: std.mem.Allocator,
    path: []const u8,
    key: u64,
) ?EvidenceFrontierCache {
    const bytes = std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(EVIDENCE_FRONTIER_CACHE_READ_LIMIT)) catch return null;
    var lines = std.mem.splitScalar(u8, bytes, '\n');
    if (!std.mem.eql(u8, std.mem.trimEnd(u8, lines.next() orelse return null, "\r"), EVIDENCE_FRONTIER_CACHE_MAGIC)) return null;
    if (parseCacheU64(lines.next() orelse return null, "key=") != key) return null;
    _ = parseCacheU64(lines.next() orelse return null, "signature=");
    const content_signature = parseCacheU64(lines.next() orelse return null, "content_signature=");
    const file_count = parseCacheUsize(lines.next() orelse return null, "file_count=");
    const pruned_files = parseCacheUsize(lines.next() orelse return null, "pruned_files=");
    const pruned_bytes = parseCacheUsize(lines.next() orelse return null, "pruned_bytes=");
    const skipped_files = parseCacheUsize(lines.next() orelse return null, "skipped_files=");
    const candidate_count = parseCacheUsize(lines.next() orelse return null, "candidates=");
    if (candidate_count > EVIDENCE_FRONTIER_CACHE_CANDIDATE_LIMIT) return null;
    if (!std.mem.eql(u8, std.mem.trimEnd(u8, lines.next() orelse return null, "\r"), "--")) return null;

    var candidates: std.ArrayList([]const u8) = .empty;
    while (lines.next()) |raw_line| {
        const line = std.mem.trimEnd(u8, raw_line, "\r");
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

pub fn holdEvidenceFrontierLive(io: std.Io, allocator: std.mem.Allocator, request: cli.SearchRequest, plan: expr.ExpressionPlan) void {
    if (request.nexus_disabled) return;
    const admission = trigram.admit(plan);
    if (!evidenceFrontierEligible(request, plan, admission)) return;
    if (request.path_count == 0) return;
    const key = evidenceFrontierKey(request, plan);
    const cache_path = std.fmt.allocPrint(allocator, ".ix-evidence-{x}.cache", .{key}) catch return;
    const live_path = evidenceFrontierLivePath(allocator, cache_path) catch return;
    std.Io.Dir.cwd().access(io, live_path, .{}) catch return;
    defer std.Io.Dir.cwd().deleteFile(io, live_path) catch {};

    if (builtin.os.tag == .windows) {
        holdEvidenceFrontierLiveWindows(io, request.paths[0]);
    } else {
        std.Thread.sleep(@as(u64, 120) * std.time.ns_per_s);
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

fn hashBytes64(seed: u64, bytes: []const u8) u64 {
    var hasher = std.hash.Wyhash.init(seed);
    hasher.update(bytes);
    return hasher.final();
}

fn hashTimestamp(hasher: *std.hash.Wyhash, timestamp: std.Io.Timestamp) void {
    var nanos = timestamp.nanoseconds;
    hasher.update(std.mem.asBytes(&nanos));
}

/// Phase 1: Recursively walk a root path and collect all scannable file paths.
/// This is fast — only readdir syscalls, no file content reads. Hidden files
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
    const display_path = try normalizeDisplayPath(allocator, path);
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
        if (!request.hidden and isHiddenPath(entry.name)) {
            report.files_skipped += 1;
            recordDiscoveryAdmissionSkip(io, report, path, entry.name, entry.kind == .file, "hidden");
            continue;
        }
        const child_path = try joinPathForward(allocator, path, entry.name);
        if (admission_engine.decide(child_path, entry.kind == .directory) == .ignore) {
            report.files_skipped += 1;
            recordDiscoveryAdmissionSkipPath(io, report, child_path, entry.kind == .file, "ignored");
            continue;
        }
        switch (entry.kind) {
            .file => {
                report.files_discovered += 1;
                try file_list.append(allocator, .{ .path = child_path });
            },
            .directory => try discoverDirectory(io, allocator, child_path, request, admission_engine, file_list, report),
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

fn recordDiscoveryAdmissionSkip(
    io: std.Io,
    report: *SearchReport,
    parent: []const u8,
    name: []const u8,
    is_file: bool,
    reason: []const u8,
) void {
    var path_buf: [4096]u8 = undefined;
    const path = joinPathForwardBounded(parent, name, &path_buf) orelse return recordAdmissionSkip(report, reason, 0);
    recordDiscoveryAdmissionSkipPath(io, report, path, is_file, reason);
}

fn recordDiscoveryAdmissionSkipPath(
    io: std.Io,
    report: *SearchReport,
    path: []const u8,
    is_file: bool,
    reason: []const u8,
) void {
    const bytes = if (is_file) skippedFileBytes(io, path) else 0;
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

fn joinPathForwardBounded(left: []const u8, right: []const u8, out: []u8) ?[]const u8 {
    var n: usize = 0;
    for (left) |byte| {
        if (n >= out.len) return null;
        out[n] = if (byte == '\\') '/' else byte;
        n += 1;
    }
    if (n > 0 and out[n - 1] != '/') {
        if (n >= out.len) return null;
        out[n] = '/';
        n += 1;
    }
    for (right) |byte| {
        if (n >= out.len) return null;
        out[n] = if (byte == '\\') '/' else byte;
        n += 1;
    }
    return out[0..n];
}

const DiscoveryShardReport = struct {
    file_list: FileList,
    files_discovered: usize = 0,
    files_skipped: usize = 0,
    access_errors: core_stats.AccessErrorStats = .{},
    had_error: bool = false,
};

fn shouldUseParallelDiscovery(request: cli.SearchRequest, roots: PreparedRoots) bool {
    if (!request.no_ignore) return false;
    const requested_threads = request.threads orelse defaultParallelDiscoveryThreadBudget(request);
    if (requested_threads <= 1) return false;
    if (roots.count == 0) return false;
    for (roots.items[0..roots.count]) |root| {
        if (!root.is_directory) return false;
    }
    return true;
}

fn defaultParallelDiscoveryThreadBudget(request: cli.SearchRequest) usize {
    if (!request.stats_only) return 1;
    return @min(availableThreads(), 16);
}

fn discoverRootsParallelTopLevel(
    io: std.Io,
    allocator: std.mem.Allocator,
    roots: PreparedRoots,
    request: cli.SearchRequest,
    file_list: *FileList,
    report: *SearchReport,
) !bool {
    if (!shouldUseParallelDiscovery(request, roots)) return false;

    var top_dirs = try FileList.initWithCapacity(allocator, 64);
    for (roots.items[0..roots.count]) |root| {
        try discoverRootTopLevel(io, allocator, root.original, request, &top_dirs, file_list, report);
    }

    const top_dir_items = top_dirs.mutableItems();
    if (top_dir_items.len == 0) return true;

    const requested_threads = request.threads orelse defaultParallelDiscoveryThreadBudget(request);
    const actual_threads = @min(@max(requested_threads, 1), top_dir_items.len);
    if (actual_threads <= 1 or top_dir_items.len < 2) {
        var disabled_admission = path_admission.Engine.init(allocator, false);
        for (top_dir_items) |entry| {
            try discoverDirectory(io, allocator, entry.path, request, &disabled_admission, file_list, report);
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
        threads[i] = try std.Thread.spawn(.{}, discoveryShardWorker, .{ io, allocator, &next_dir, top_dir_items, request, &shards[shard_index] });
    }
    discoveryShardWorker(io, allocator, &next_dir, top_dir_items, request, &shards[0]);
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
        if (!request.hidden and isHiddenPath(entry.name)) {
            report.files_skipped += 1;
            continue;
        }
        const child_path = try joinPathForward(allocator, path, entry.name);
        switch (entry.kind) {
            .file => {
                report.files_discovered += 1;
                try file_list.append(allocator, .{ .path = child_path });
            },
            .directory => try top_dirs.append(allocator, .{ .path = child_path }),
            else => {},
        }
    }
}

fn discoveryShardWorker(
    io: std.Io,
    allocator: std.mem.Allocator,
    next_dir: *usize,
    dirs: []const DiscoveredFile,
    request: cli.SearchRequest,
    shard: *DiscoveryShardReport,
) void {
    while (true) {
        const index = @atomicRmw(usize, next_dir, .Add, 1, .monotonic);
        if (index >= dirs.len) break;
        discoverDirectoryShard(io, allocator, dirs[index].path, request, shard) catch {
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
        if (!request.hidden and isHiddenPath(entry.name)) {
            shard.files_skipped += 1;
            continue;
        }
        const child_path = try joinPathForward(allocator, path, entry.name);
        switch (entry.kind) {
            .file => {
                shard.files_discovered += 1;
                try shard.file_list.append(allocator, .{ .path = child_path });
            },
            .directory => try discoverDirectoryShard(io, allocator, child_path, request, shard),
            else => {},
        }
    }
}

fn recordReportAccessError(report: *SearchReport, phase: []const u8, operation: []const u8, path: []const u8, err: anyerror) void {
    report.stats.access_errors.record(phase, operation, path, err);
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
    if (comptime builtin.os.tag != .windows) return false;
    if (!request.stats_only) return false;
    if (!isProtectedWindowsPath(path)) return false;
    if (isProtectedVolatileSystemStore(path)) return true;
    const ext = pathExtension(path) orelse return false;
    return !hasProtectedTextExtension(ext);
}

fn isProtectedWindowsPath(path: []const u8) bool {
    if (path.len < "C:\\Windows".len) return false;
    if (path[1] != ':') return false;
    const slash = path[2];
    if (slash != '\\' and slash != '/') return false;
    if (!std.ascii.eqlIgnoreCase(path[3..10], "Windows")) return false;
    if (path.len == 10) return true;
    return path[10] == '\\' or path[10] == '/';
}

fn pathExtension(path: []const u8) ?[]const u8 {
    var base_start = path.len;
    while (base_start > 0) {
        base_start -= 1;
        if (path[base_start] == '\\' or path[base_start] == '/') {
            base_start += 1;
            break;
        }
    }
    const name = path[base_start..];
    const dot_index = std.mem.lastIndexOfScalar(u8, name, '.') orelse return null;
    return name[dot_index..];
}

fn hasProtectedTextExtension(ext: []const u8) bool {
    const text_extensions = [_][]const u8{
        ".inf", ".inf_loc", ".mof", ".man", ".cdxml", ".ps1xml", ".log",
        ".ini", ".psd1", ".xml", ".psm1", ".yaml", ".yml", ".xsd", ".msc",
        ".gpd", ".strings", ".forms", ".rtf", ".dis", ".txt", ".json",
        ".xsl", ".rs", ".gdl", ".vbs", ".table", ".hlp", ".cfg", ".dic",
        ".1", ".ppd",
    };
    for (text_extensions) |candidate| {
        if (std.ascii.eqlIgnoreCase(ext, candidate)) return true;
    }
    return false;
}

fn isProtectedVolatileSystemStore(path: []const u8) bool {
    return containsPathSegmentPairIgnoreCase(path, "System32", "catroot2");
}

fn containsPathSegmentPairIgnoreCase(path: []const u8, first: []const u8, second: []const u8) bool {
    var segments = std.mem.tokenizeAny(u8, path, "\\/");
    var saw_first = false;
    while (segments.next()) |segment| {
        if (!saw_first) {
            saw_first = std.ascii.eqlIgnoreCase(segment, first);
            continue;
        }
        if (std.ascii.eqlIgnoreCase(segment, second)) return true;
        saw_first = std.ascii.eqlIgnoreCase(segment, first);
    }
    return false;
}

/// Thread-local shard report. Each worker thread accumulates results here
/// without any synchronization. Merged into the main SearchReport after
/// all threads join.
const ShardReport = struct {
    bytes_scanned: usize,
    files_scanned: usize,
    files_skipped: usize,
    matches_found: usize,
    scan_work_ms_total: f64,
    acceleration_bailouts: usize,
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

    const empty: ShardReport = .{
        .bytes_scanned = 0,
        .files_scanned = 0,
        .files_skipped = 0,
        .matches_found = 0,
        .scan_work_ms_total = 0,
        .acceleration_bailouts = 0,
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
    const min_bytes = shard.linux_dominant_file_stats.min_bytes;
    if (file_bytes < min_bytes) return false;
    if (!isLinuxDominantFilePath(display_path)) return false;
    shard.linux_dominant_file_stats.targeted_files_scanned += 1;
    shard.linux_dominant_file_stats.targeted_bytes_scanned += file_bytes;
    shard.linux_dominant_file_stats.eligible_files += 1;
    return true;
}

fn recordLinuxDominantFileActivation(shard: *ShardReport) void {
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

/// Scan a single discovered file — used in the serial path and by
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
    if (shouldSkipProtectedBinaryContainer(request, display_path)) {
        report.files_skipped += 1;
        report.stats.admission.protected_entries_skipped += 1;
        return;
    }
    const open_started = std.Io.Timestamp.now(io, .awake);
    // Open via NT object path to bypass RtlGetFullPathName_U PEB lock contention.
    const file = openFileNt(io, display_path) catch |err| switch (err) {
        error.IsDir => {
            const open_ms = elapsedMs(io, open_started);
            report.scan_work_ms_total += open_ms;
            if (open_ms >= report.slowest_ms) {
                report.slowest_ms = open_ms;
                report.slowest_path = display_path;
                report.slowest_bytes = 0;
            }
            report.files_skipped += 1;
            recordReportAccessError(report, "scan", "open_file", display_path, err);
            return;
        },
        else => {
            if (isRecoverableScanAccessError(err)) {
                const open_ms = elapsedMs(io, open_started);
                report.scan_work_ms_total += open_ms;
                if (open_ms >= report.slowest_ms) {
                    report.slowest_ms = open_ms;
                    report.slowest_path = display_path;
                    report.slowest_bytes = 0;
                }
                report.files_skipped += 1;
                recordReportAccessError(report, "scan", "open_file", display_path, err);
                return;
            }
            return err;
        },
    };
    const open_ms = elapsedMs(io, open_started);
    report.scan_work_ms_total += open_ms;
    if (open_ms >= report.slowest_ms) {
        report.slowest_ms = open_ms;
        report.slowest_path = display_path;
        report.slowest_bytes = 0;
    }
    defer file.close(io);
    scanOpenFile(io, allocator, file, display_path, request, plan, trigram_admission, trigram_program, report) catch |err| switch (err) {
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
    const open_started = std.Io.Timestamp.now(io, .awake);
    const file = openFileNt(io, display_path) catch |err| {
        const open_ms = elapsedMs(io, open_started);
        shard.scan_work_ms_total += open_ms;
        if (open_ms >= shard.slowest_ms) {
            shard.slowest_ms = open_ms;
            shard.slowest_path = display_path;
            shard.slowest_bytes = 0;
        }
        shard.files_skipped += 1;
        recordShardAccessError(shard, "scan", "open_file", display_path, err);
        recordEvidenceSkipped(shard);
        return;
    };
    const open_ms = elapsedMs(io, open_started);
    shard.scan_work_ms_total += open_ms;
    if (open_ms >= shard.slowest_ms) {
        shard.slowest_ms = open_ms;
        shard.slowest_path = display_path;
        shard.slowest_bytes = 0;
    }
    defer file.close(io);
    scanOpenFileIntoShard(io, allocator, file, display_path, request, plan, trigram_admission, trigram_program, shard) catch |err| {
        if (isRecoverableScanAccessError(err)) {
            shard.files_skipped += 1;
            recordShardAccessError(shard, "scan", "read_file", display_path, err);
            recordEvidenceSkipped(shard);
        } else {
            shard.had_error = true;
        }
    };
}

/// Memory-mapped file scan — zero-copy, no stack buffer, no carry buffer.
/// Maps the entire file via NtCreateSection/NtMapViewOfSection (Windows) or
/// mmap (POSIX). The OS page cache provides the data directly; no read()
/// syscalls, no memcpy, no multi-chunk loop.
///
/// Returns error on mmap failure (resource limits, non-regular file), allowing
/// the caller to fall back to chunked reads.
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
        shard.scan_work_ms_total += file_ms;
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
    const linux_dominant_target = recordLinuxDominantFileScan(shard, display_path, file_bytes);
    if (file_bytes >= shard.slowest_bytes) {
        shard.slowest_path = display_path;
        shard.slowest_bytes = file_bytes;
    }

    if (request.stats_only and shouldRunByteShardBeforeAdmission(plan)) {
        if (tryByteShardFastCount(io, allocator, request, plan, data, &shard.byte_shard_stats, &shard.regex_decomposition_stats, &shard.acceleration_bailouts)) |count| {
            if (linux_dominant_target) recordLinuxDominantFileActivation(shard);
            shard.matches_found += count;
            recordEvidenceCandidate(shard, display_path);
            const file_ms = elapsedMs(io, file_started);
            shard.scan_work_ms_total += file_ms;
            if (file_ms >= shard.slowest_ms) shard.slowest_ms = file_ms;
            return;
        }
    }

    if (mono) |m| {
        if (fileAdmissionNeedle(m.kind, m.strategy, plan.predicates[0])) |needle| {
            if (!request.case_insensitive and sz.indexOfAdmission(data, needle) == null) {
                recordEvidencePruned(shard, file_bytes);
                const file_ms = elapsedMs(io, file_started);
                shard.scan_work_ms_total += file_ms;
                if (file_ms >= shard.slowest_ms) shard.slowest_ms = file_ms;
                return;
            }
        }
    }

    // Trigram prune — entire file available as one contiguous buffer.
    if (shouldAttemptTrigramPrune(file_bytes, true, trigram_admission, request.case_insensitive) and
        tryTrigramPruneFile(data, trigram_program, &shard.trigram_stats))
    {
        recordEvidencePruned(shard, file_bytes);
        const file_ms = elapsedMs(io, file_started);
        shard.scan_work_ms_total += file_ms;
        if (file_ms >= shard.slowest_ms) shard.slowest_ms = file_ms;
        return;
    }

    // Whole-buffer fast count — always applicable (entire file is one buffer).
    // For casefold-literal patterns in stats_only mode, this handles the
    // case-insensitive counting without buffer modification.
    if (request.stats_only) {
        if (tryByteShardFastCount(io, allocator, request, plan, data, &shard.byte_shard_stats, &shard.regex_decomposition_stats, &shard.acceleration_bailouts)) |count| {
            if (linux_dominant_target) recordLinuxDominantFileActivation(shard);
            shard.matches_found += count;
            recordEvidenceCandidate(shard, display_path);
            const file_ms = elapsedMs(io, file_started);
            shard.scan_work_ms_total += file_ms;
            if (file_ms >= shard.slowest_ms) shard.slowest_ms = file_ms;
            return;
        }
        if (regexDecompositionFastCount(data, plan, request.case_insensitive, &shard.regex_decomposition_stats, &shard.acceleration_bailouts)) |count| {
            shard.matches_found += count;
            recordEvidenceCandidate(shard, display_path);
            const file_ms = elapsedMs(io, file_started);
            shard.scan_work_ms_total += file_ms;
            if (file_ms >= shard.slowest_ms) shard.slowest_ms = file_ms;
            return;
        }
        if (wholeBufferFastCount(data, plan, request.case_insensitive, false)) |count| {
            shard.matches_found += count;
            recordEvidenceCandidate(shard, display_path);
            const file_ms = elapsedMs(io, file_started);
            shard.scan_work_ms_total += file_ms;
            if (file_ms >= shard.slowest_ms) shard.slowest_ms = file_ms;
            return;
        }
    }

    // Whole-file literal precheck: if a mandatory literal is absent from
    // the entire file, skip per-line processing.
    if (mono) |m| {
        if (chunkPrefilterNeedle(m.kind, m.strategy, plan.predicates[0])) |needle| {
            if (!request.case_insensitive and sz.indexOfAdmission(data, needle) == null) {
                recordEvidencePruned(shard, file_bytes);
                const file_ms = elapsedMs(io, file_started);
                shard.scan_work_ms_total += file_ms;
                if (file_ms >= shard.slowest_ms) shard.slowest_ms = file_ms;
                return;
            }
        }
    }

    // Per-line processing on mapped memory — no carry buffer, no chunk boundaries.
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
    shard.scan_work_ms_total += file_ms;
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
    scanFileMmap(null, io, allocator, file, display_path, request, plan, trigram_admission, trigram_program, &shard, file_started) catch return false;
    var shards = [_]ShardReport{shard};
    mergeShardsIntoReport(shards[0..], report);
    return true;
}

fn planUsesRegexDecompositionFastCount(plan: expr.ExpressionPlan, case_insensitive: bool) bool {
    if (case_insensitive or plan.predicate_count != 1) return false;
    const predicate = plan.predicates[0];
    return predicate.kind == .regex and regexDecompositionNeedle(predicate.value) != null;
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
    if (case_insensitive or plan.predicate_count != 1) return false;
    const predicate = plan.predicates[0];
    return predicate.kind == .regex and
        predicate.strategy == .regex_literal_alternates and
        parseLiteralAlternates(expr.literalAlternatesBody(predicate.value)) != null;
}

const ByteShardStrategy = enum {
    literal_occurrence,
    literal_alternates_line,
    word_boundary_line,
    regex_decomposition_line,

    fn text(self: ByteShardStrategy) []const u8 {
        return switch (self) {
            .literal_occurrence => "literal",
            .literal_alternates_line => "literal_alternates",
            .word_boundary_line => "word_boundary_literal",
            .regex_decomposition_line => "regex_decomposition",
        };
    }
};

const ByteShardPlan = struct {
    strategy: ByteShardStrategy,
    needle: []const u8,
    pattern: []const u8 = "",
    case_insensitive: bool = false,
};

const ByteShardRange = struct {
    logical_start: usize,
    logical_end: usize,
    widened_start: usize,
    widened_end: usize,
    line_aligned: bool = false,
};

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

const LiteralAlternatesRangeCount = struct {
    matches: usize = 0,
    bailed_out: bool = false,
};

const MAX_LITERAL_ALTERNATE_BRANCHES = 32;

const LiteralAlternates = struct {
    branches: [MAX_LITERAL_ALTERNATE_BRANCHES][]const u8 = undefined,
    count: usize = 0,

    fn slice(self: *const LiteralAlternates) []const []const u8 {
        return self.branches[0..self.count];
    }
};

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
    elapsed_ns: u64 = 0,
};

fn tryByteShardFastCount(
    io: std.Io,
    allocator: std.mem.Allocator,
    request: cli.SearchRequest,
    plan: expr.ExpressionPlan,
    data: []const u8,
    stats: *core_stats.ByteShardKernelStats,
    regex_stats: *core_stats.RegexDecompositionStats,
    acceleration_bailouts: *usize,
) ?usize {
    if (!request.stats_only or request.case_insensitive) return null;
    const shard_plan = byteShardPlan(plan) orelse return null;
    if (shard_plan.case_insensitive) return null;
    if (shard_plan.needle.len < 2 or shard_plan.needle.len > data.len) return null;
    const min_file_bytes: usize = switch (shard_plan.strategy) {
        .word_boundary_line => BYTE_SHARD_WORD_BOUNDARY_MIN_FILE_BYTES,
        else => BYTE_SHARD_MIN_FILE_BYTES,
    };
    if (data.len < min_file_bytes) return null;

    const requested_threads = request.threads orelse defaultByteShardThreadBudget(availableThreads());
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
        const range = byteShardRangeFor(data, shard_plan, logical_start, logical_end, index, range_count) orelse return null;
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
    return @min(available, BYTE_SHARD_DEFAULT_MAX_RANGES);
}

fn byteShardWorker(job: *ByteShardJob) void {
    const started = std.Io.Timestamp.now(job.io, .awake);
    switch (job.plan.strategy) {
        .literal_occurrence => {
            job.matches = countLiteralLogicalRange(job.data, job.plan.needle, job.logical_start, job.logical_end, job.widened_start, job.widened_end);
        },
        .literal_alternates_line => {
            const counted = countLiteralAlternatesLogicalLinesRange(job.data, job.plan.pattern, job.logical_start, job.logical_end);
            job.matches = counted.matches;
            job.regex_bailed_out = counted.bailed_out;
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
    var total: usize = 0;
    var cursor = @min(widened_start, end);
    while (cursor + needle.len <= end) {
        const index = sz.indexOf(data[cursor..end], needle) orelse break;
        const match_start = cursor + index;
        if (match_start >= logical_end) break;
        if (match_start >= logical_start) total += 1;
        cursor = match_start + needle.len;
    }
    return total;
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
        const line = std.mem.trimEnd(u8, raw_line, "\r");
        if (regexLineMatches(line, pattern)) {
            result.matches += 1;
            result.candidate_lines_matched += 1;
        }
        last_line_start = line_start;
    }

    return result;
}

fn shouldRunByteShardBeforeAdmission(plan: expr.ExpressionPlan) bool {
    const shard_plan = byteShardPlan(plan) orelse return false;
    return shard_plan.strategy == .literal_occurrence or
        shard_plan.strategy == .literal_alternates_line or
        shard_plan.strategy == .word_boundary_line or
        shard_plan.strategy == .regex_decomposition_line;
}

fn byteShardPlan(plan: expr.ExpressionPlan) ?ByteShardPlan {
    if (plan.predicate_count != 1) return null;
    const predicate = plan.predicates[0];
    return switch (predicate.kind) {
        .literal => if (predicate.value.len >= 2) .{
            .strategy = .literal_occurrence,
            .needle = predicate.value,
        } else null,
        .regex => switch (predicate.strategy) {
            .regex_plain_literal => if (std.mem.indexOfScalar(u8, predicate.value, '\\') == null and predicate.value.len >= 2) .{
                .strategy = .literal_occurrence,
                .needle = predicate.value,
            } else null,
            .regex_word_boundary_literal => blk: {
                const body = stripWordBoundaryAnchors(predicate.value);
                break :blk if (body.len >= 2) .{
                    .strategy = .word_boundary_line,
                    .needle = body,
                } else null;
            },
            .regex_literal_alternates => blk: {
                const pattern = expr.literalAlternatesBody(predicate.value);
                const branch = firstLiteralAlternateBranchAtLeast(pattern, 2) orelse break :blk null;
                break :blk .{
                    .strategy = .literal_alternates_line,
                    .needle = branch,
                    .pattern = pattern,
                };
            },
            .regex_decomposition_candidate_lines => blk: {
                const needle = regexDecompositionNeedle(predicate.value) orelse break :blk null;
                break :blk .{
                    .strategy = .regex_decomposition_line,
                    .needle = needle,
                    .pattern = predicate.value,
                };
            },
            else => null,
        },
        else => null,
    };
}

fn byteShardRangeFor(data: []const u8, plan: ByteShardPlan, logical_start: usize, logical_end: usize, index: usize, range_count: usize) ?ByteShardRange {
    return switch (plan.strategy) {
        .literal_occurrence => blk: {
            const overlap = plan.needle.len - 1;
            break :blk .{
                .logical_start = logical_start,
                .logical_end = logical_end,
                .widened_start = logical_start -| overlap,
                .widened_end = @min(logical_end + overlap, data.len),
            };
        },
        .literal_alternates_line => byteShardLineOwnedRange(data, logical_start, logical_end, index, range_count),
        .word_boundary_line => byteShardLineOwnedRange(data, logical_start, logical_end, index, range_count),
        .regex_decomposition_line => byteShardLineOwnedRange(data, logical_start, logical_end, index, range_count),
    };
}

fn byteShardLineOwnedRange(data: []const u8, nominal_start: usize, nominal_end: usize, index: usize, range_count: usize) ?ByteShardRange {
    const start = if (index == 0)
        @min(nominal_start, data.len)
    else
        findOwnedLineBoundaryAfter(data, nominal_start) orelse return null;
    const end = if (index + 1 >= range_count)
        data.len
    else
        findOwnedLineBoundaryAfter(data, nominal_end) orelse return null;
    if (start > end) return null;
    return .{
        .logical_start = start,
        .logical_end = end,
        .widened_start = start,
        .widened_end = end,
        .line_aligned = true,
    };
}

fn findOwnedLineBoundaryAfter(data: []const u8, position: usize) ?usize {
    if (position >= data.len) return data.len;
    const end = @min(data.len, position + BYTE_SHARD_LINE_BOUNDARY_SEARCH_LIMIT);
    const relative = simd.indexOfByte(data[position..end], '\n') orelse return null;
    return position + relative + 1;
}

/// Comptime-generic per-file scan. When mono is non-null, the per-line match
/// dispatch is fully monomorphized — zero runtime switches in the inner loop.
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
) anyerror!void {
    const file_started = std.Io.Timestamp.now(io, .awake);

    var read_buffer: [1024 * 1024]u8 = undefined;

    // Binary-heavy protected trees should not pay a 1 MiB read before skip.
    // Probe a small prefix first; escalate only for text candidates.
    var first_read = file.readStreaming(io, &.{read_buffer[0..BINARY_SNIFF_BYTES]}) catch |err| switch (err) {
        error.EndOfStream => 0,
        else => return err,
    };
    if (first_read == 0) {
        shard.files_scanned += 1;
        recordLineIntoShardImpl(mono, allocator, display_path, "", 1, request, plan, shard, false);
        recordEvidenceCandidate(shard, display_path);
        const file_ms = elapsedMs(io, file_started);
        shard.scan_work_ms_total += file_ms;
        if (file_ms >= shard.slowest_ms) shard.slowest_ms = file_ms;
        return;
    }
    if (simd.indexOfByte(read_buffer[0..@min(1024, first_read)], 0) != null) {
        shard.files_skipped += 1;
        shard.admission_stats.binary_entries_skipped += 1;
        shard.admission_stats.binary_file_bytes += @intCast(file.length(io) catch first_read);
        recordEvidenceSkipped(shard);
        return;
    }
    const file_bytes: usize = @intCast(try file.length(io));
    if (file_bytes > first_read and file_bytes <= read_buffer.len) {
        while (first_read < file_bytes) {
            const read_len = file.readStreaming(io, &.{read_buffer[first_read..file_bytes]}) catch |err| switch (err) {
                error.EndOfStream => break,
                else => return err,
            };
            if (read_len == 0) break;
            first_read += read_len;
        }
    }
    const single_chunk = file_bytes <= first_read;

    // Multi-chunk files (> 1 MiB): switch to mmap for zero-copy access.
    // Eliminates the carry buffer, multi-read loop, and per-chunk syscalls.
    // Single-chunk files stay on the readPositional path (one syscall, warm cache).
    if (!single_chunk) mmap: {
        scanFileMmap(mono, io, allocator, file, display_path, request, plan, trigram_admission, trigram_program, shard, file_started) catch break :mmap;
        return;
    }

    shard.files_scanned += 1;
    shard.bytes_scanned += file_bytes;
    const linux_dominant_target = recordLinuxDominantFileScan(shard, display_path, file_bytes);
    if (file_bytes >= shard.slowest_bytes) {
        shard.slowest_path = display_path;
        shard.slowest_bytes = file_bytes;
    }
    if (mono) |m| {
        if (fileAdmissionNeedle(m.kind, m.strategy, plan.predicates[0])) |needle| {
            if (!request.case_insensitive and sz.indexOfAdmission(read_buffer[0..first_read], needle) == null) {
                recordEvidencePruned(shard, file_bytes);
                const file_ms = elapsedMs(io, file_started);
                shard.scan_work_ms_total += file_ms;
                if (file_ms >= shard.slowest_ms) shard.slowest_ms = file_ms;
                return;
            }
        }
    }
    _ = linux_dominant_target;
    if (shouldAttemptTrigramPrune(file_bytes, single_chunk, trigram_admission, request.case_insensitive) and
        tryTrigramPruneFile(read_buffer[0..first_read], trigram_program, &shard.trigram_stats))
    {
        recordEvidencePruned(shard, file_bytes);
        const file_ms = elapsedMs(io, file_started);
        shard.scan_work_ms_total += file_ms;
        if (file_ms >= shard.slowest_ms) shard.slowest_ms = file_ms;
        return;
    }

    // CHUNK CASEFOLD: when stats-only and the plan is a single all-lowercase
    // casefold-literal predicate, lowercase the read buffer in-place once per
    // chunk instead of casefolding every line individually.  Reduces ~100k
    // per-line function calls to ~500 per-file AVX2 passes for large-dir.
    // Only safe in stats-only mode — hit-collecting needs the original bytes
    // for preview display.
    const chunk_casefold = request.stats_only and planIsFullyCasefoldLiteral(plan);

    // Casefold the first chunk in-place after binary sniff confirms it is text.
    if (chunk_casefold) asciiLowerBuf(read_buffer[0..first_read], read_buffer[0..first_read]);

    // WHOLE-BUFFER FAST COUNT: for single-chunk files in stats-only mode,
    // count eligible predicates across the entire buffer without line splitting.
    if (request.stats_only and single_chunk) {
        const ci = if (chunk_casefold) false else request.case_insensitive;
        if (wholeBufferFastCount(read_buffer[0..first_read], plan, ci, chunk_casefold)) |count| {
            shard.matches_found += count;
            recordEvidenceCandidate(shard, display_path);
            const file_ms = elapsedMs(io, file_started);
            shard.scan_work_ms_total += file_ms;
            if (file_ms >= shard.slowest_ms) shard.slowest_ms = file_ms;
            return;
        }
        if (regexDecompositionFastCount(read_buffer[0..first_read], plan, ci, &shard.regex_decomposition_stats, &shard.acceleration_bailouts)) |count| {
            shard.matches_found += count;
            recordEvidenceCandidate(shard, display_path);
            const file_ms = elapsedMs(io, file_started);
            shard.scan_work_ms_total += file_ms;
            if (file_ms >= shard.slowest_ms) shard.slowest_ms = file_ms;
            return;
        }
    }

    // CHUNK-LEVEL PREFILTER: extract the mandatory literal from the plan
    // (if any) to reject entire chunks that cannot contain a match.
    // One simd.indexOf over the 1 MiB chunk at 32 B/cycle (AVX2) replaces
    // ~10K per-line newline scans + ~10K per-line literal scans on
    // non-matching chunks. Only safe for case-sensitive single-predicate
    // literal/regex plans where the needle is a direct substring test.
    const chunk_prefilter_needle: ?[]const u8 = if (mono) |m| chunkPrefilterNeedle(m.kind, m.strategy, plan.predicates[0]) else null;

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
        if (chunk_prefilter_needle) |needle| {
            if (carry.items.len == 0 and !request.case_insensitive and
                sz.indexOfAdmission(chunk, needle) == null)
            {
                // Fast newline count: count newlines in bulk via SIMD.
                const newlines = std.mem.count(u8, chunk, "\n");
                line_number += newlines;
                // If chunk doesn't end with newline, the trailing bytes
                // become carry for the next chunk.
                if (!ended_with_newline) {
                    // Find last newline to extract the trailing partial line.
                    if (std.mem.lastIndexOfScalar(u8, chunk, '\n')) |last_nl| {
                        try carry.appendSlice(allocator, chunk[last_nl + 1 ..]);
                    } else {
                        // No newlines in chunk — entire chunk is carry.
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
        // Read next chunk — only for files > 1 MiB.
        const remaining = file_bytes - @as(usize, @intCast(offset));
        const target_len: usize = @intCast(@min(read_buffer.len, remaining));
        const read_len = try file.readPositionalAll(io, read_buffer[0..target_len], offset);
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
    shard.scan_work_ms_total += file_ms;
    if (file_ms >= shard.slowest_ms) shard.slowest_ms = file_ms;
}

/// Runtime wrapper — dispatches to Impl with null mono (generic path).
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
) anyerror!void {
    return scanOpenFileIntoShardImpl(null, io, allocator, file, display_path, request, plan, trigram_admission, trigram_program, shard);
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
    const line = std.mem.trimEnd(u8, raw_line, "\r");
    if (request.stats_only) {
        const ci = if (chunk_casefolded) false else request.case_insensitive;
        const count = if (mono) |m|
            predicateMatchCountMono(m.kind, m.strategy, line, plan.predicates[0], ci, chunk_casefolded)
        else
            statsOnlyMatchCount(line, plan, ci, chunk_casefolded);
        shard.matches_found += count;
        return;
    }
    const column = if (mono) |m|
        predicateColumnMono(m.kind, m.strategy, line, plan.predicates[0], request.case_insensitive)
    else
        matchingColumn(line, plan, request.case_insensitive);
    if (column) |col| {
        shard.matches_found += 1;
        const under_request_limit = if (request.max_hits) |max_hits| shard.hit_count < max_hits else true;
        if (under_request_limit and shard.hit_count < MAX_RETAINED_HITS) {
            shard.hits[shard.hit_count] = .{
                .path = display_path,
                .line = line_number,
                .column = col,
                .preview = allocator.dupe(u8, line) catch line,
            };
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
    if (plan.predicate_count == 1) {
        dispatchMonoShardLoop(io, allocator, files, request, plan, trigram_admission, trigram_program, shard);
    } else {
        for (files) |entry| {
            if (shard.truncated) break;
            scanFileIntoShard(io, allocator, entry.path, request, plan, trigram_admission, trigram_program, shard);
        }
    }
}

fn dynamicShardWorker(io: std.Io, allocator: std.mem.Allocator, next_file: *usize, files: []const DiscoveredFile, request: cli.SearchRequest, plan: expr.ExpressionPlan, trigram_admission: trigram.Admission, trigram_program: *const TrigramAdmissionProgram, shard: *ShardReport) void {
    if (plan.predicate_count == 1) {
        dispatchMonoDynamicLoop(io, allocator, next_file, files, request, plan, trigram_admission, trigram_program, shard);
    } else {
        while (!shard.truncated) {
            const index = @atomicRmw(usize, next_file, .Add, 1, .monotonic);
            if (index >= files.len) break;
            scanFileIntoShard(io, allocator, files[index].path, request, plan, trigram_admission, trigram_program, shard);
        }
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
    for (files) |entry| {
        if (shard.truncated) break;
        scanFileIntoShardMono(mono, io, allocator, entry.path, request, plan, trigram_admission, trigram_program, shard);
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
    while (!shard.truncated) {
        const index = @atomicRmw(usize, next_file, .Add, 1, .monotonic);
        if (index >= files.len) break;
        scanFileIntoShardMono(mono, io, allocator, files[index].path, request, plan, trigram_admission, trigram_program, shard);
    }
}

/// Monomorphized file opener — calls scanOpenFileIntoShardImpl with comptime mono.
fn scanFileIntoShardMono(comptime mono: MonoSpec, io: std.Io, allocator: std.mem.Allocator, display_path: []const u8, request: cli.SearchRequest, plan: expr.ExpressionPlan, trigram_admission: trigram.Admission, trigram_program: *const TrigramAdmissionProgram, shard: *ShardReport) void {
    if (shouldSkipProtectedBinaryContainer(request, display_path)) {
        shard.files_skipped += 1;
        recordEvidenceSkipped(shard);
        return;
    }
    const open_started = std.Io.Timestamp.now(io, .awake);
    const file = openFileNt(io, display_path) catch |err| {
        const open_ms = elapsedMs(io, open_started);
        shard.scan_work_ms_total += open_ms;
        if (open_ms >= shard.slowest_ms) {
            shard.slowest_ms = open_ms;
            shard.slowest_path = display_path;
            shard.slowest_bytes = 0;
        }
        shard.files_skipped += 1;
        recordShardAccessError(shard, "scan", "open_file", display_path, err);
        recordEvidenceSkipped(shard);
        return;
    };
    const open_ms = elapsedMs(io, open_started);
    shard.scan_work_ms_total += open_ms;
    if (open_ms >= shard.slowest_ms) {
        shard.slowest_ms = open_ms;
        shard.slowest_path = display_path;
        shard.slowest_bytes = 0;
    }
    defer file.close(io);
    scanOpenFileIntoShardImpl(mono, io, allocator, file, display_path, request, plan, trigram_admission, trigram_program, shard) catch |err| {
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
    _ = file_count; // Dynamic claiming benefits all file counts — atomic counter contention is negligible.
    return canUseDynamicWorkClaimForPlan(plan);
}

fn canUseDynamicWorkClaimForPlan(plan: expr.ExpressionPlan) bool {
    // All single-predicate plans benefit from dynamic load balancing.
    // The monomorphized dispatch in dispatchMonoDynamicLoop handles every
    // PredicateKind × MatcherStrategy variant.
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

    // Allocate shard reports — one per thread (including main).
    const shards = try allocator.alloc(ShardReport, actual_threads);
    for (shards) |*s| {
        s.* = ShardReport.empty;
        if (evidence_runtime.enabled) {
            s.evidence_capture = true;
            s.evidence_allocator = allocator;
        }
    }

    if (shouldUseDynamicWorkClaim(plan, files.len)) {
        var next_file: usize = 0;
        const threads = try allocator.alloc(std.Thread, worker_count);
        for (0..worker_count) |i| {
            const shard_index = i + 1;
            threads[i] = try std.Thread.spawn(.{}, dynamicShardWorker, .{ io, allocator, &next_file, files, request, plan, trigram_admission, trigram_program, &shards[shard_index] });
        }
        dynamicShardWorker(io, allocator, &next_file, files, request, plan, trigram_admission, trigram_program, &shards[0]);
        for (threads) |thread| thread.join();
        mergeShardsIntoReport(shards, report);
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
    }

    // Main thread processes shard 0.
    const main_files = files[boundaries[0]..boundaries[1]];
    shardWorker(io, allocator, main_files, request, plan, trigram_admission, trigram_program, &shards[0]);

    // Join all worker threads.
    for (threads) |t| t.join();

    mergeShardsIntoReport(shards, report);
    writeEvidenceFrontierCacheFromShards(io, allocator, evidence_runtime, shards);
}

fn mergeShardsIntoReport(shards: []const ShardReport, report: *SearchReport) void {
    for (shards) |shard| {
        report.bytes_scanned += shard.bytes_scanned;
        report.files_scanned += shard.files_scanned;
        report.files_skipped += shard.files_skipped;
        report.matches_found += shard.matches_found;
        report.scan_work_ms_total += shard.scan_work_ms_total;
        report.stats.acceleration_bailouts += shard.acceleration_bailouts;
        report.stats.access_errors.merge(shard.access_errors);
        report.stats.admission.merge(shard.admission_stats);
        mergeRegexDecompositionStats(&report.stats.regex_decomposition, shard.regex_decomposition_stats);
        mergeTrigramStats(&report.stats.trigram_acceleration, shard.trigram_stats);
        mergeByteShardStats(&report.stats.byte_shard_kernel, shard.byte_shard_stats);
        mergeLinuxDominantFileStats(&report.stats.linux_dominant_file, shard.linux_dominant_file_stats);
        if (shard.slowest_ms >= report.slowest_ms) {
            report.slowest_ms = shard.slowest_ms;
            report.slowest_path = shard.slowest_path;
            report.slowest_bytes = shard.slowest_bytes;
        }
        // Merge hits: copy from shard into report, respecting the global cap.
        const available = MAX_RETAINED_HITS - report.hit_count;
        const to_copy = @min(shard.hit_count, available);
        for (0..to_copy) |j| {
            report.hits[report.hit_count] = shard.hits[j];
            report.hit_count += 1;
        }
        if (shard.truncated) report.truncated = true;
    }
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
///   1. Exact duplicate: same normalized path → skip
///   2. Contained by accepted: candidate is inside an already-accepted dir → skip
///   3. Contains accepted: candidate is a parent dir of an accepted root →
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
        // element) to avoid shifting the array — O(1) per eviction.
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
/// Backslashes → forward slashes, lowercased, trailing slashes stripped.
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
        .aggregate_merge_ms = report.aggregate_ms,
        .aggregate_finalize_ms = 0,
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
        .outer_scan_threads = report.outer_scan_threads,
        .execution_mode = if (byte_sharded) "byte_sharded" else "materialized",
        .sharding_enabled = byte_sharded,
        .sharded_files = report.stats.byte_shard_kernel.files_profiled,
        .max_shard_threads = byte_shard_ranges,
        .max_shard_ranges = byte_shard_ranges,
        .max_shard_chunk_bytes = byte_shard_chunk,
    };
    report.stats.recordSlowFile(report.slowest_path, report.slowest_ms, report.slowest_bytes, isLinuxDominantFilePath(report.slowest_path) and report.slowest_bytes >= report.stats.linux_dominant_file.min_bytes);
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

const TRIGRAM_ADMISSION_CAPACITY = 4096;
const TRIGRAM_ADMISSION_HASH_MASK: usize = TRIGRAM_ADMISSION_CAPACITY - 1;

const TrigramAdmissionProgram = struct {
    eligible: bool = false,
    mode: trigram.AdmissionMode = .all,
    group_count: usize = 0,
    group_complete_mask: u64 = 0,
    required_counts: [trigram.MAX_GROUPS]u8 = @splat(0),
    keys: [TRIGRAM_ADMISSION_CAPACITY]trigram.Trigram = @splat(0),
    group_masks: [TRIGRAM_ADMISSION_CAPACITY]u64 = @splat(0),
    occupied: [TRIGRAM_ADMISSION_CAPACITY]bool = @splat(false),

    fn compile(admission: trigram.Admission) TrigramAdmissionProgram {
        var program = TrigramAdmissionProgram{
            .eligible = admission.eligible,
            .mode = admission.mode,
            .group_count = admission.group_count,
        };
        if (!admission.eligible) return program;

        for (admission.groups[0..admission.group_count], 0..) |group, group_index| {
            program.required_counts[group_index] = @intCast(group.trigram_count);
            program.group_complete_mask |= groupBit(group_index);
            for (group.trigrams[0..group.trigram_count]) |needle| {
                program.insert(needle, group_index);
            }
        }
        return program;
    }

    fn mayMatch(self: *const TrigramAdmissionProgram, bytes: []const u8) bool {
        if (!self.eligible) return true;
        if (bytes.len < 3) return false;

        var seen_slots: [TRIGRAM_ADMISSION_CAPACITY]bool = @splat(false);
        var group_seen_counts: [trigram.MAX_GROUPS]u8 = @splat(0);
        var satisfied_groups: u64 = 0;
        var rolling: trigram.Trigram = trigram.key(bytes[0..3]);
        if (self.recordTrigram(rolling, &seen_slots, &group_seen_counts, &satisfied_groups)) return true;

        var index: usize = 3;
        while (index < bytes.len) : (index += 1) {
            rolling = ((rolling & 0xffff) << 8) | bytes[index];
            if (self.recordTrigram(rolling, &seen_slots, &group_seen_counts, &satisfied_groups)) return true;
        }
        return false;
    }

    fn insert(self: *TrigramAdmissionProgram, needle: trigram.Trigram, group_index: usize) void {
        var slot = hashTrigram(needle);
        while (self.occupied[slot]) : (slot = (slot + 1) & TRIGRAM_ADMISSION_HASH_MASK) {
            if (self.keys[slot] == needle) {
                self.group_masks[slot] |= groupBit(group_index);
                return;
            }
        }
        self.occupied[slot] = true;
        self.keys[slot] = needle;
        self.group_masks[slot] = groupBit(group_index);
    }

    fn findSlot(self: *const TrigramAdmissionProgram, needle: trigram.Trigram) ?usize {
        var slot = hashTrigram(needle);
        while (self.occupied[slot]) : (slot = (slot + 1) & TRIGRAM_ADMISSION_HASH_MASK) {
            if (self.keys[slot] == needle) return slot;
        }
        return null;
    }

    fn recordTrigram(
        self: *const TrigramAdmissionProgram,
        needle: trigram.Trigram,
        seen_slots: *[TRIGRAM_ADMISSION_CAPACITY]bool,
        group_seen_counts: *[trigram.MAX_GROUPS]u8,
        satisfied_groups: *u64,
    ) bool {
        const slot = self.findSlot(needle) orelse return false;
        if (seen_slots[slot]) return false;
        seen_slots[slot] = true;

        var mask = self.group_masks[slot];
        while (mask != 0) {
            const group_index: usize = @intCast(@ctz(mask));
            group_seen_counts[group_index] += 1;
            if (group_seen_counts[group_index] == self.required_counts[group_index]) {
                satisfied_groups.* |= groupBit(group_index);
                if (self.mode == .any) return true;
                if ((satisfied_groups.* & self.group_complete_mask) == self.group_complete_mask) return true;
            }
            mask &= mask - 1;
        }
        return false;
    }
};

fn groupBit(group_index: usize) u64 {
    return @as(u64, 1) << @as(u6, @intCast(group_index));
}

fn hashTrigram(needle: trigram.Trigram) usize {
    var value = needle *% 0x9E3779B1;
    value ^= value >> 16;
    return @as(usize, value) & TRIGRAM_ADMISSION_HASH_MASK;
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

fn shouldAttemptTrigramPrune(file_bytes: usize, single_chunk: bool, admission: trigram.Admission, case_insensitive: bool) bool {
    return admission.eligible and !case_insensitive and single_chunk and file_bytes >= TRIGRAM_MIN_PRUNE_BYTES;
}

fn availableThreads() usize {
    return std.Thread.getCpuCount() catch 1;
}

/// Core per-file scan loop. Reads the file in 1 MiB chunks, splits into
/// lines, and runs predicate matching on each line.
///
/// Serial-path per-file scan (non-parallel reports, e.g. inspect mode).
///
/// Single-chunk files (≤1 MiB) use a stack-allocated read buffer — one
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
) anyerror!void {
    const file_started = std.Io.Timestamp.now(io, .awake);
    var read_buffer: [1024 * 1024]u8 = undefined;

    // Read first chunk before length lookup. Single-shot positional read avoids
    // the retry syscall that readPositionalAll pays on sub-1MiB files.
    const first_read = try file.readPositional(io, &.{&read_buffer}, 0);
    if (first_read == 0) {
        report.files_scanned += 1;
        try recordLine(allocator, display_path, "", 1, request, plan, report, false);
        const file_ms = elapsedMs(io, file_started);
        report.scan_work_ms_total += file_ms;
        if (file_ms >= report.slowest_ms) report.slowest_ms = file_ms;
        return;
    }
    if (simd.indexOfByte(read_buffer[0..@min(1024, first_read)], 0) != null) {
        report.files_skipped += 1;
        report.stats.admission.binary_entries_skipped += 1;
        report.stats.admission.binary_file_bytes += @intCast(file.length(io) catch first_read);
        return;
    }
    const single_chunk = first_read < read_buffer.len;
    const file_bytes: usize = if (single_chunk) first_read else @intCast(try file.length(io));

    if (!single_chunk and trySerialMmapFastPath(io, allocator, file, display_path, request, plan, trigram_admission, trigram_program, report, file_started)) {
        return;
    }

    report.files_scanned += 1;
    report.bytes_scanned += file_bytes;
    if (file_bytes >= report.slowest_bytes) {
        report.slowest_path = display_path;
        report.slowest_bytes = file_bytes;
    }
    if (shouldAttemptTrigramPrune(file_bytes, single_chunk, trigram_admission, request.case_insensitive) and
        tryTrigramPruneFile(read_buffer[0..first_read], trigram_program, &report.stats.trigram_acceleration))
    {
        const file_ms = elapsedMs(io, file_started);
        report.scan_work_ms_total += file_ms;
        if (file_ms >= report.slowest_ms) report.slowest_ms = file_ms;
        return;
    }

    // CHUNK CASEFOLD: when stats-only and the plan is a single all-lowercase
    // casefold-literal predicate, lowercase the read buffer in-place once per
    // chunk instead of casefolding every line individually.  Reduces ~100k
    // per-line function calls to ~500 per-file AVX2 passes for large-dir.
    // Only safe in stats-only mode — hit-collecting needs the original bytes
    // for preview display.
    const chunk_casefold = request.stats_only and planIsFullyCasefoldLiteral(plan);

    // Casefold the first chunk in-place after binary sniff confirms it is text.
    if (chunk_casefold) asciiLowerBuf(read_buffer[0..first_read], read_buffer[0..first_read]);

    // WHOLE-BUFFER FAST COUNT (serial path): same optimization as parallel path.
    if (request.stats_only and single_chunk) {
        const ci = if (chunk_casefold) false else request.case_insensitive;
        if (wholeBufferFastCount(read_buffer[0..first_read], plan, ci, chunk_casefold)) |count| {
            report.matches_found += count;
            const file_ms = elapsedMs(io, file_started);
            report.scan_work_ms_total += file_ms;
            if (file_ms >= report.slowest_ms) report.slowest_ms = file_ms;
            return;
        }
    }

    var carry: std.ArrayList(u8) = .empty;
    defer carry.deinit(allocator);
    var line_number: usize = 1;
    var ended_with_newline = false;

    // Process first chunk then any remaining chunks (most files fit in one chunk).
    // HOT PATH: simd.indexOfByte uses AVX2 VPCMPEQB — 32 bytes/cycle vs 1 byte/cycle scalar.
    var chunk: []const u8 = read_buffer[0..first_read];
    var offset: u64 = first_read;
    while (true) {
        ended_with_newline = chunk[chunk.len - 1] == '\n';
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
        // Read next chunk — only for files > 1 MiB.
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
    report.scan_work_ms_total += file_ms;
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
    const line = std.mem.trimEnd(u8, raw_line, "\r");
    if (request.stats_only) {
        const ci = if (chunk_casefolded) false else request.case_insensitive;
        const count = statsOnlyMatchCount(line, plan, ci, chunk_casefolded);
        report.matches_found += count;
        return;
    }
    if (matchingColumn(line, plan, request.case_insensitive)) |column| {
        report.matches_found += 1;
        const under_request_limit = if (request.max_hits) |max_hits| report.hit_count < max_hits else true;
        if (!request.stats_only and under_request_limit and report.hit_count < MAX_RETAINED_HITS) {
            report.hits[report.hit_count] = .{
                .path = display_path,
                .line = line_number,
                .column = column,
                .preview = try allocator.dupe(u8, line),
            };
            report.hit_count += 1;
        }
    }
}

/// Extracts only contract-safe whole-file admission needles.
/// These needles are mandatory substrings for the predicate shape, so absence
/// from the file proves absence of a match without invoking the line verifier.
fn fileAdmissionNeedle(comptime kind: expr.PredicateKind, comptime strategy: expr.MatcherStrategy, predicate: expr.Predicate) ?[]const u8 {
    switch (kind) {
        .literal, .prefix, .suffix => return if (predicate.value.len >= 2) predicate.value else null,
        .regex => switch (strategy) {
            .regex_plain_literal => {
                if (std.mem.indexOfScalar(u8, predicate.value, '\\') == null and predicate.value.len >= 2)
                    return predicate.value;
                return null;
            },
            .regex_word_boundary_literal => {
                const body = stripWordBoundaryAnchors(predicate.value);
                return if (body.len >= 2) body else null;
            },
            else => return null,
        },
    }
}

fn fileAdmissionNeedleRuntimeForPlan(plan: expr.ExpressionPlan) ?[]const u8 {
    if (plan.predicate_count != 1) return null;
    return fileAdmissionNeedleRuntime(plan.predicates[0]);
}

fn fileAdmissionNeedleRuntime(predicate: expr.Predicate) ?[]const u8 {
    switch (predicate.kind) {
        .literal, .prefix, .suffix => return if (predicate.value.len >= 2) predicate.value else null,
        .regex => switch (predicate.strategy) {
            .regex_plain_literal => {
                if (std.mem.indexOfScalar(u8, predicate.value, '\\') == null and predicate.value.len >= 2)
                    return predicate.value;
                return null;
            },
            .regex_word_boundary_literal => {
                const body = stripWordBoundaryAnchors(predicate.value);
                return if (body.len >= 2) body else null;
            },
            else => return null,
        },
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
fn chunkPrefilterNeedle(comptime kind: expr.PredicateKind, comptime strategy: expr.MatcherStrategy, predicate: expr.Predicate) ?[]const u8 {
    switch (kind) {
        .literal => return if (predicate.value.len >= 2) predicate.value else null,
        .regex => {
            switch (strategy) {
                .regex_plain_literal => {
                    if (std.mem.indexOfScalar(u8, predicate.value, '\\') == null and predicate.value.len >= 2)
                        return predicate.value;
                    return null;
                },
                .regex_word_boundary_literal => {
                    const body = stripWordBoundaryAnchors(predicate.value);
                    return if (body.len >= 2) body else null;
                },
                .regex_full, .regex_fixed_width_bytes, .regex_decomposition_candidate_lines => {
                    const effective = if (std.mem.startsWith(u8, predicate.value, "(?i)")) predicate.value[4..] else predicate.value;
                    const fragment = extractLongestLiteralFragment(effective);
                    return if (fragment.len >= 2) fragment else null;
                },
                else => return null,
            }
        },
        else => return null,
    }
}

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
            break :blk countWordBoundaryLiteralLines(buffer, stripWordBoundaryAnchors(predicate.value));
        },
        .regex_ascii_casefold_word_boundary_literal => blk: {
            if (!chunk_casefolded) break :blk null;
            const after_flag = if (std.mem.startsWith(u8, predicate.value, "(?i)")) predicate.value[4..] else predicate.value;
            break :blk countWordBoundaryLiteralLines(buffer, stripWordBoundaryAnchors(after_flag));
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
    const needle = regexDecompositionNeedle(predicate.value) orelse return null;

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
        const line = std.mem.trimEnd(u8, raw_line, "\r");
        if (regexLineMatches(line, predicate.value)) {
            count += 1;
            stats.candidate_lines_matched += 1;
        }
        last_line_start = line_start;
    }

    stats.counted_files += 1;
    return count;
}

fn regexDecompositionNeedle(pattern: []const u8) ?[]const u8 {
    if (std.mem.startsWith(u8, pattern, "(?i)")) return null;
    const fragment = expr.regexDecompositionLiteralCandidate(pattern) orelse return null;
    if (fragment.len < REGEX_DECOMPOSITION_MIN_LITERAL_LEN) return null;
    return fragment;
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
/// match — the line either matches all/any predicates or it doesn't.
/// This distinction matters for Rust parity: `ix search --stats-only "lit:ERROR"`
/// must report the same occurrence count as the Rust binary.
///
/// chunk_casefolded: the line bytes were already lowercased in the chunk
/// buffer — skip per-line casefold and use case-sensitive matching directly.
fn statsOnlyMatchCount(line: []const u8, plan: expr.ExpressionPlan, case_insensitive: bool, chunk_casefolded: bool) usize {
    if (plan.predicate_count == 1) {
        return predicateMatchCount(line, plan.predicates[0], case_insensitive, chunk_casefolded);
    }
    return if (matchingColumn(line, plan, case_insensitive) != null) 1 else 0;
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
/// chunk_casefolded: line bytes already lowercased in-place → skip per-line casefold.
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
        .regex_word_boundary_literal => if (wordBoundaryLiteralColumn(line, stripWordBoundaryAnchors(predicate.value), case_insensitive) != null) 1 else 0,
        .regex_ascii_casefold_word_boundary_literal => blk: {
            const after_flag = if (std.mem.startsWith(u8, predicate.value, "(?i)")) predicate.value[4..] else predicate.value;
            const effective_ci = if (chunk_casefolded) false else true;
            break :blk if (wordBoundaryLiteralColumn(line, stripWordBoundaryAnchors(after_flag), effective_ci) != null) 1 else 0;
        },
        .regex_literal_alternates => countLiteralAlternates(line, expr.literalAlternatesBody(predicate.value), case_insensitive),
        else => countRegexWithPrefilter(line, predicate.value, case_insensitive),
    };
}

/// Runtime dispatch wrapper — inline else forwards to comptime-specialized Mono.
fn predicateMatchCountByStrategy(line: []const u8, predicate: expr.Predicate, case_insensitive: bool, chunk_casefolded: bool) usize {
    return switch (predicate.strategy) {
        inline else => |strategy| predicateMatchCountByStrategyMono(strategy, line, predicate, case_insensitive, chunk_casefolded),
    };
}

fn countRegexWithPrefilter(line: []const u8, pattern: []const u8, case_insensitive: bool) usize {
    const cached = cachedLiteralFragment(pattern);
    if (cached.len >= 2) {
        if (indexOfLiteral(line, cached, case_insensitive) == null) return 0;
    }
    return countRegexStatsOnly(line, pattern, case_insensitive);
}

fn isSurroundingWordLiteralPattern(pattern: []const u8) bool {
    return std.mem.startsWith(u8, pattern, "\\w+\\s+") and std.mem.endsWith(u8, pattern, "\\s+\\w+");
}

fn elapsedMs(io: std.Io, start: std.Io.Timestamp) f64 {
    const elapsed = start.untilNow(io, .awake);
    return @as(f64, @floatFromInt(elapsed.nanoseconds)) / 1_000_000.0;
}

fn normalizeDisplayPath(allocator: std.mem.Allocator, path: []const u8) ![]const u8 {
    const normalized = try allocator.dupe(u8, path);
    for (normalized) |*byte| {
        if (byte.* == '\\') byte.* = '/';
    }
    return normalized;
}

fn joinPathForward(allocator: std.mem.Allocator, parent: []const u8, child: []const u8) ![]const u8 {
    const buf = try allocator.alloc(u8, parent.len + 1 + child.len);
    @memcpy(buf[0..parent.len], parent);
    buf[parent.len] = '/';
    @memcpy(buf[parent.len + 1 ..][0..child.len], child);
    return buf;
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
/// Both kind and strategy are comptime-known — all switches collapse.
fn predicateColumnMono(comptime kind: expr.PredicateKind, comptime strategy: expr.MatcherStrategy, line: []const u8, predicate: expr.Predicate, case_insensitive: bool) ?usize {
    return switch (kind) {
        .literal => if (indexOfLiteral(line, predicate.value, case_insensitive)) |index| index + 1 else null,
        .prefix => if (startsWithLiteral(line, predicate.value, case_insensitive)) 1 else null,
        .suffix => if (endsWithLiteral(line, predicate.value, case_insensitive)) line.len - predicate.value.len + 1 else null,
        .regex => regexColumnByStrategyMono(strategy, line, predicate, case_insensitive),
    };
}

/// Comptime-specialized regex column dispatch. When `strategy` is comptime-known,
/// the switch collapses to a single branch — zero runtime dispatch overhead.
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
            const body = stripWordBoundaryAnchors(predicate.value);
            return wordBoundaryLiteralColumn(line, body, case_insensitive);
        },
        .regex_ascii_casefold_word_boundary_literal => {
            const after_flag = if (std.mem.startsWith(u8, predicate.value, "(?i)")) predicate.value[4..] else predicate.value;
            const body = stripWordBoundaryAnchors(after_flag);
            return wordBoundaryLiteralColumn(line, body, true);
        },
        .regex_literal_alternates => {
            return literalAlternatesColumn(line, expr.literalAlternatesBody(predicate.value), case_insensitive);
        },
        // regex_full, regex_fixed_width_bytes, regex_decomposition_candidate_lines,
        // and non-regex strategies all fall through to prefilter + regex engine.
        else => regexWithLiteralPrefilter(line, predicate.value, case_insensitive),
    };
}

/// Runtime strategy dispatch — inline else converts each runtime branch to a
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
/// E.g. `\w+Column` → fragment `Column` (suffix, not prefix).
///      `process_\d+_\d+` → fragment `process_` (prefix).
///      `[A-Z]+error_log` → fragment `error_log` (suffix).
///
/// SIMD indexOf rejects non-matching lines at ~32 bytes/cycle (AVX2),
/// eliminating the per-line PCRE2 JIT dispatch on ~99% of lines for
/// patterns with a mandatory literal of ≥2 bytes.
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
///   `\w+Column`      → `Column`
///   `process_\d+_\d+`→ `process_`
///   `[A-Z]+error_log` → `error_log`
///   `\d{4}-\d{2}`    → `-`  (short — caller applies ≥2 byte threshold)
///   `.*`             → ``   (empty — no literals)
fn extractLongestLiteralFragment(pattern: []const u8) []const u8 {
    if (hasTopLevelRegexAlternation(pattern)) return "";

    var best_start: usize = 0;
    var best_len: usize = 0;
    var run_start: usize = 0;
    var run_len: usize = 0;
    var i: usize = 0;

    while (i < pattern.len) {
        const byte = pattern[i];

        // Skip escape sequences — they are metachar classes (\w, \d, etc.)
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
                // Groups contain alternation — cannot guarantee any single
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
        // optional (? or *). If so, it's not mandatory — break the run.
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

        // Plain mandatory literal byte — extend the current run.
        // If a `+` quantifier follows, the literal is still mandatory (≥1 match),
        // so include the byte but skip the `+`.
        run_len += 1;
        i += 1;
        if (i < pattern.len and pattern[i] == '+') {
            // `x+` means ≥1 x. The single `x` is mandatory. But the run
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

// ── SIMD Casefold Infrastructure ──────────────────────────────────────
//
// ASCII case differs by exactly bit 5 (0x20). To search case-insensitively
// at SIMD speed, we lowercase both the line and needle into scratch buffers,
// then run the pure Zig SIMD memmem on the lowered copies.
//
// The vector loop processes 32 bytes per iteration:
//   1. Load 32 bytes
//   2. Wrapping-subtract 'A' (maps A-Z → 0-25, everything else → ≥ 26)
//   3. Compare < 26 → bool mask identifying uppercase bytes
//   4. Select 0x20 where uppercase, 0 elsewhere
//   5. OR with originals → lowercase A-Z, all other bytes unchanged
//
// This converts O(n×m) scalar comparison into O(n) casefold + O(n) SIMD
// search — a ~10-30x speedup on typical source code lines.

/// Stack buffer ceiling for SIMD casefold. 2 KiB keeps the combined
/// casefold stack frame (line_buf + needle_buf + overhead) under 4 KiB,
/// which is the Windows __chkstk threshold. Frames ≥ 4 KiB require a
/// __chkstk page-probe call on every function entry — with 100k lines
/// this adds ~1ms on case-insensitive searches. Lines longer than 2 KiB
/// are virtually absent in real source code and fall back to the scalar path.
const CASEFOLD_LINE_MAX = 2 * 1024;

/// Maximum needle length for stack-buffered casefold. 256 B is sufficient
/// for any realistic search pattern; combined with CASEFOLD_LINE_MAX the
/// total stack frame stays under 4 KiB.
const CASEFOLD_NEEDLE_MAX = 256;

/// SIMD-accelerated ASCII lowercase. Processes 32 bytes per iteration
/// using AVX2 vector operations, with a scalar tail for the remainder.
/// Non-alpha bytes pass through unchanged — the wrapping range check
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

/// HOT PATH 3: Literal substring matching — the core search operation.
///
/// Case-sensitive path uses simd.indexOf (AVX2 first+last byte fingerprint), which
/// fingerprints by first+last byte across 32 positions per SIMD pass.
///
/// Case-insensitive path dispatches to indexOfLiteralCasefold (separate
/// function) to keep this hot path's stack frame under 4 KiB. On Windows,
/// frames > 4 KiB trigger __chkstk page probes on every call — including
/// case-sensitive calls that take the early return. Isolating the 2 KiB
/// casefold buffers into their own function eliminates that overhead.
fn indexOfLiteral(line: []const u8, needle: []const u8, case_insensitive: bool) ?usize {
    if (!case_insensitive) return simd.indexOf(line, needle);
    if (needle.len == 0) return 0;
    if (needle.len > line.len) return null;
    return indexOfLiteralCasefold(line, needle);
}

/// SIMD casefold search — isolated from indexOfLiteral to quarantine the
/// 2 KiB + 256 B stack buffers away from the case-sensitive hot path.
/// Lowercase both line and needle into stack buffers via AVX2 vector ops,
/// then search with simd.indexOf. O(n) casefold + O(n) SIMD search.
fn indexOfLiteralCasefold(line: []const u8, needle: []const u8) ?usize {
    if (line.len <= CASEFOLD_LINE_MAX and needle.len <= CASEFOLD_NEEDLE_MAX) {
        var lower_line: [CASEFOLD_LINE_MAX]u8 = undefined;
        var lower_needle: [CASEFOLD_NEEDLE_MAX]u8 = undefined;
        asciiLowerBuf(lower_line[0..line.len], line);
        asciiLowerBuf(lower_needle[0..needle.len], needle);
        return simd.indexOf(lower_line[0..line.len], lower_needle[0..needle.len]);
    }
    return indexOfLiteralScalar(line, needle);
}

/// Scalar case-insensitive literal search. O(n×m) byte-by-byte comparison,
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
/// Case-sensitive path calls simd.indexOf directly in a tight loop.
/// Case-insensitive path dispatches to countLiteralCasefold (separate
/// function) to quarantine the casefold stack buffers.
fn countLiteral(line: []const u8, needle: []const u8, case_insensitive: bool) usize {
    if (needle.len == 0) return 0;
    if (case_insensitive) return countLiteralCasefold(line, needle);
    // Case-sensitive: simd.indexOf directly, no indirection.
    var total: usize = 0;
    var start: usize = 0;
    while (start + needle.len <= line.len) {
        const index = sz.indexOf(line[start..], needle) orelse break;
        total += 1;
        start += index + needle.len;
    }
    return total;
}

/// Casefold-once counting — isolated from countLiteral to quarantine the
/// casefold stack buffers. Lowercase the line once, then loop simd.indexOf
/// on the lowered copy to avoid redundant casefold per match position.
fn countLiteralCasefold(line: []const u8, needle: []const u8) usize {
    if (line.len <= CASEFOLD_LINE_MAX and needle.len <= CASEFOLD_NEEDLE_MAX) {
        var lower_line: [CASEFOLD_LINE_MAX]u8 = undefined;
        var lower_needle: [CASEFOLD_NEEDLE_MAX]u8 = undefined;
        asciiLowerBuf(lower_line[0..line.len], line);
        asciiLowerBuf(lower_needle[0..needle.len], needle);
        const ll = lower_line[0..line.len];
        const ln = lower_needle[0..needle.len];
        var total: usize = 0;
        var start: usize = 0;
        while (start + needle.len <= ll.len) {
            const index = simd.indexOf(ll[start..], ln) orelse break;
            total += 1;
            start += index + needle.len;
        }
        return total;
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

/// Strip `\b` anchors from both ends of a word-boundary pattern.
/// E.g. `\bsession\b` → `session`. Caller has already verified
/// the pattern is classified as regex_word_boundary_literal.
fn stripWordBoundaryAnchors(pattern: []const u8) []const u8 {
    var body = pattern;
    if (body.len >= 2 and body[0] == '\\' and body[1] == 'b') body = body[2..];
    if (body.len >= 2 and body[body.len - 2] == '\\' and body[body.len - 1] == 'b') body = body[0 .. body.len - 2];
    return body;
}

/// Search for a literal at a word boundary. Finds the literal via
/// indexOfLiteral, then verifies that both edges sit at word boundaries
/// (transition between \w and \W or string edge). Returns 1-based column.
fn wordBoundaryLiteralColumn(line: []const u8, needle: []const u8, case_insensitive: bool) ?usize {
    if (needle.len == 0) return null;
    var start: usize = 0;
    while (start + needle.len <= line.len) {
        const index = indexOfLiteral(line[start..], needle, case_insensitive) orelse return null;
        const abs = start + index;
        const left_is_word = abs > 0 and isWordChar(line[abs - 1]);
        const right_is_word = (abs + needle.len) < line.len and isWordChar(line[abs + needle.len]);
        const first_is_word = isWordChar(needle[0]);
        const last_is_word = isWordChar(needle[needle.len - 1]);
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

fn countLiteralAlternatesLogicalLinesRange(buffer: []const u8, pattern: []const u8, logical_start: usize, logical_end: usize) LiteralAlternatesRangeCount {
    if (pattern.len == 0 or logical_start >= logical_end) return .{};
    const alternates = parseLiteralAlternates(pattern) orelse return .{ .bailed_out = true };
    const end = @min(logical_end, buffer.len);
    var counted = LiteralAlternatesRangeCount{};
    const start = @min(logical_start, end);

    if (literalAlternatesPcreRangeEligible(pattern, alternates.count)) {
        if (pcre_regex.count(buffer[start..end], pattern, false)) |matches| {
            counted.matches = matches;
            return counted;
        } else |_| {}
    }

    var cursor = start;

    while (cursor < end) {
        const newline = simd.indexOfByte(buffer[cursor..end], '\n');
        const line_end = if (newline) |offset| cursor + offset else end;
        const raw_line = buffer[cursor..line_end];
        const line = std.mem.trimEnd(u8, raw_line, "\r");
        counted.matches += countLiteralAlternatesParsed(line, alternates.slice(), false);
        if (newline) |offset| {
            cursor += offset + 1;
        } else {
            break;
        }
    }

    return counted;
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
/// Each branch is a plain literal — search them individually and return
/// the earliest match column.
fn literalAlternatesColumn(line: []const u8, pattern: []const u8, case_insensitive: bool) ?usize {
    if (parseLiteralAlternates(pattern)) |alternates| {
        return literalAlternatesColumnParsed(line, alternates.slice(), case_insensitive);
    }

    var best: ?usize = null;
    var start: usize = 0;
    while (start <= pattern.len) {
        const end = std.mem.indexOfScalarPos(u8, pattern, start, '|') orelse pattern.len;
        const branch = pattern[start..end];
        if (branch.len > 0) {
            if (indexOfLiteral(line, branch, case_insensitive)) |index| {
                const col = index + 1;
                if (best == null or col < best.?) best = col;
            }
        }
        if (end == pattern.len) break;
        start = end + 1;
    }
    return best;
}

fn countLiteralAlternates(line: []const u8, pattern: []const u8, case_insensitive: bool) usize {
    if (parseLiteralAlternates(pattern)) |alternates| {
        return countLiteralAlternatesParsed(line, alternates.slice(), case_insensitive);
    }

    var total: usize = 0;
    var cursor: usize = 0;
    while (cursor < line.len) {
        var best_index: ?usize = null;
        var best_len: usize = 0;
        var start: usize = 0;
        while (start <= pattern.len) {
            const end = std.mem.indexOfScalarPos(u8, pattern, start, '|') orelse pattern.len;
            const branch = pattern[start..end];
            if (branch.len > 0) {
                if (indexOfLiteral(line[cursor..], branch, case_insensitive)) |index| {
                    if (best_index == null or index < best_index.?) {
                        best_index = index;
                        best_len = branch.len;
                    }
                }
            }
            if (end == pattern.len) break;
            start = end + 1;
        }
        const index = best_index orelse break;
        total += 1;
        cursor += index + best_len;
    }
    return total;
}

fn literalAlternatesColumnParsed(line: []const u8, branches: []const []const u8, case_insensitive: bool) ?usize {
    var best: ?usize = null;
    for (branches) |branch| {
        if (indexOfLiteral(line, branch, case_insensitive)) |index| {
            const col = index + 1;
            if (best == null or col < best.?) best = col;
        }
    }
    return best;
}

fn countLiteralAlternatesParsed(line: []const u8, branches: []const []const u8, case_insensitive: bool) usize {
    var total: usize = 0;
    var cursor: usize = 0;
    while (cursor < line.len) {
        var best_index: ?usize = null;
        var best_len: usize = 0;
        for (branches) |branch| {
            if (indexOfLiteral(line[cursor..], branch, case_insensitive)) |index| {
                if (best_index == null or index < best_index.?) {
                    best_index = index;
                    best_len = branch.len;
                }
            }
        }
        const index = best_index orelse break;
        total += 1;
        cursor += index + best_len;
    }
    return total;
}

fn parseLiteralAlternates(pattern: []const u8) ?LiteralAlternates {
    var alternates: LiteralAlternates = .{};
    var start: usize = 0;
    while (start <= pattern.len) {
        const end = std.mem.indexOfScalarPos(u8, pattern, start, '|') orelse pattern.len;
        const branch = pattern[start..end];
        if (branch.len == 0) return null;
        if (alternates.count == MAX_LITERAL_ALTERNATE_BRANCHES) return null;
        alternates.branches[alternates.count] = branch;
        alternates.count += 1;
        if (end == pattern.len) break;
        start = end + 1;
    }
    return if (alternates.count > 1) alternates else null;
}

fn firstLiteralAlternateBranchAtLeast(pattern: []const u8, min_len: usize) ?[]const u8 {
    var start: usize = 0;
    while (start <= pattern.len) {
        const end = std.mem.indexOfScalarPos(u8, pattern, start, '|') orelse pattern.len;
        const branch = pattern[start..end];
        if (branch.len >= min_len) return branch;
        if (end == pattern.len) break;
        start = end + 1;
    }
    return null;
}

test "trigram gate rejects impossible complete file without verifier authority" {
    const plan = try expr.parse("lit:needle");
    const admission = trigram.admit(plan);
    const program = TrigramAdmissionProgram.compile(admission);
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
    const program = TrigramAdmissionProgram.compile(admission);
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
    const program = TrigramAdmissionProgram.compile(admission);
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
    const program = TrigramAdmissionProgram.compile(admission);
    var stats = core_stats.TrigramAccelerationStats{};
    initTrigramStats(&stats, admission, false);
    var bytes: [TRIGRAM_MIN_PRUNE_BYTES]u8 = undefined;
    @memset(bytes[0..], 'z');
    @memcpy(bytes[96..101], "omega");

    try std.testing.expect(!tryTrigramPruneFile(bytes[0..], &program, &stats));
}

test "file admission needle lowers only contract-safe predicate shapes" {
    const word_plan = try expr.parse("re:\\bPM_RESUME\\b");
    try std.testing.expectEqualStrings(
        "PM_RESUME",
        fileAdmissionNeedle(.regex, .regex_word_boundary_literal, word_plan.predicates[0]).?,
    );

    const full_plan = try expr.parse("re:PM_.*RESUME");
    try std.testing.expect(fileAdmissionNeedle(.regex, .regex_full, full_plan.predicates[0]) == null);
}

test "warm index live marker validates magic pid and root" {
    const marker = "IXINDEX_LIVE1\npid=1234\nroot=C:/repo\n";
    try std.testing.expect(validateWarmIndexLiveMarkerWithOwnerCheck(marker, "C:/repo", false));
    try std.testing.expect(!validateWarmIndexLiveMarkerWithOwnerCheck("BROKEN\npid=1234\nroot=C:/repo\n", "C:/repo", false));
    try std.testing.expect(!validateWarmIndexLiveMarkerWithOwnerCheck("IXINDEX_LIVE1\npid=0\nroot=C:/repo\n", "C:/repo", false));
    try std.testing.expect(!validateWarmIndexLiveMarkerWithOwnerCheck("IXINDEX_LIVE1\npid=abc\nroot=C:/repo\n", "C:/repo", false));
    try std.testing.expect(!validateWarmIndexLiveMarkerWithOwnerCheck(marker, "D:/repo", false));
}

test "warm index live marker rejects dead Windows owner" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    const marker = "IXINDEX_LIVE1\npid=999999\nroot=C:/repo\n";
    try std.testing.expect(!validateWarmIndexLiveMarkerWithOwnerCheck(marker, "C:/repo", true));
}

test "warm foreground marker validation is generation-pin gated" {
    const marker = "IXINDEX_LIVE1\npid=999999\nroot=C:/repo\n";
    try std.testing.expect(validateWarmIndexLiveMarker(marker, "C:/repo"));
    try std.testing.expect(!validateWarmIndexLiveMarker(marker, "D:/repo"));
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

test "byte shard plan admits word-boundary line kernels" {
    const literal_plan = try expr.parse("lit:Sherlock Holmes");
    const literal = byteShardPlan(literal_plan).?;
    try std.testing.expectEqual(ByteShardStrategy.literal_occurrence, literal.strategy);
    try std.testing.expectEqualStrings("Sherlock Holmes", literal.needle);

    const regex_literal = try expr.parse("re:Sherlock Holmes");
    const regex_plain = byteShardPlan(regex_literal).?;
    try std.testing.expectEqual(ByteShardStrategy.literal_occurrence, regex_plain.strategy);
    try std.testing.expectEqualStrings("Sherlock Holmes", regex_plain.needle);

    const regex_word = try expr.parse("re:\\bSherlock Holmes\\b");
    const word = byteShardPlan(regex_word).?;
    try std.testing.expectEqual(ByteShardStrategy.word_boundary_line, word.strategy);
    try std.testing.expectEqualStrings("Sherlock Holmes", word.needle);

    const regex_decomposed = try expr.parse("re:Sherlock\\s+Holmes");
    const decomposed = byteShardPlan(regex_decomposed).?;
    try std.testing.expectEqual(ByteShardStrategy.regex_decomposition_line, decomposed.strategy);
    try std.testing.expectEqualStrings("Sherlock", decomposed.needle);
    try std.testing.expectEqualStrings("Sherlock\\s+Holmes", decomposed.pattern);

    const regex_alternates = try expr.parse("re:Sherlock Holmes|John Watson|Irene Adler");
    const alternates = byteShardPlan(regex_alternates).?;
    try std.testing.expectEqual(ByteShardStrategy.literal_alternates_line, alternates.strategy);
    try std.testing.expectEqualStrings("Sherlock Holmes", alternates.needle);
    try std.testing.expectEqualStrings("Sherlock Holmes|John Watson|Irene Adler", alternates.pattern);

    const regex_wrapped_alternates = try expr.parse("re:(Sherlock Holmes|John Watson|Irene Adler)");
    const wrapped_alternates = byteShardPlan(regex_wrapped_alternates).?;
    try std.testing.expectEqual(ByteShardStrategy.literal_alternates_line, wrapped_alternates.strategy);
    try std.testing.expectEqualStrings("Sherlock Holmes", wrapped_alternates.needle);
    try std.testing.expectEqualStrings("Sherlock Holmes|John Watson|Irene Adler", wrapped_alternates.pattern);

    const regex_casefold_word = try expr.parse("re:(?i)\\bSherlock Holmes\\b");
    try std.testing.expect(byteShardPlan(regex_casefold_word) == null);
}

test "literal alternates line range counts regex occurrences" {
    const buffer =
        "Sherlock Holmes and John Watson\n" ++
        "Irene Adler\n" ++
        "Professor Moriarty\n" ++
        "plain line\n";
    const count = countLiteralAlternatesLogicalLinesRange(buffer, "Sherlock Holmes|John Watson|Irene Adler", 0, buffer.len);
    try std.testing.expect(!count.bailed_out);
    try std.testing.expectEqual(@as(usize, 3), count.matches);

    try std.testing.expectEqual(@as(?usize, 1), literalAlternatesColumn(buffer, expr.literalAlternatesBody("(Sherlock Holmes|John Watson|Irene Adler)"), false));
    try std.testing.expectEqual(@as(usize, 3), countLiteralAlternates(buffer, expr.literalAlternatesBody("(Sherlock Holmes|John Watson|Irene Adler)"), false));
}

test "large literal alternates range may use pcre count path" {
    const pattern = "Sherlock Holmes|John Watson|Irene Adler|Inspector Lestrade|Professor Moriarty";
    const buffer =
        "Sherlock Holmes and John Watson\n" ++
        "Irene Adler\n" ++
        "Inspector Lestrade\n" ++
        "Professor Moriarty Sherlock Holmes\n";

    const alternates = parseLiteralAlternates(pattern).?;
    try std.testing.expect(literalAlternatesPcreRangeEligible(pattern, alternates.count));

    const count = countLiteralAlternatesLogicalLinesRange(buffer, pattern, 0, buffer.len);
    try std.testing.expect(!count.bailed_out);
    try std.testing.expectEqual(@as(usize, 6), count.matches);

    const small = parseLiteralAlternates("Sherlock Holmes|John Watson|Irene Adler|Inspector Lestrade").?;
    try std.testing.expect(!literalAlternatesPcreRangeEligible("Sherlock Holmes|John Watson|Irene Adler|Inspector Lestrade", small.count));
    const escaped = parseLiteralAlternates("Sherlock\\.Holmes|John Watson|Irene Adler|Inspector Lestrade|Professor Moriarty").?;
    try std.testing.expect(!literalAlternatesPcreRangeEligible("Sherlock\\.Holmes|John Watson|Irene Adler|Inspector Lestrade|Professor Moriarty", escaped.count));
}

test "byte shard default fanout caps implicit hardware thread count" {
    try std.testing.expectEqual(@as(usize, BYTE_SHARD_DEFAULT_MAX_RANGES), defaultByteShardThreadBudget(BYTE_SHARD_DEFAULT_MAX_RANGES + 14));
    try std.testing.expectEqual(@as(usize, 8), defaultByteShardThreadBudget(8));
}

test "regex decomposition fast count verifies mandatory literal candidate lines" {
    const plan = try expr.parse("re:Sherlock\\s+Holmes");
    try std.testing.expect(planUsesRegexDecompositionFastCount(plan, false));
    try std.testing.expectEqualStrings("Sherlock", regexDecompositionNeedle(plan.predicates[0].value).?);

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
    const needle = regexDecompositionNeedle(pattern).?;
    const buffer =
        "Sherlock Holmes\n" ++
        "Sherlock\n" ++
        "Sherlock    Holmes\n" ++
        "Holmes Sherlock\n" ++
        "Sherlock Holmes again";
    const expected = countRegexDecompositionLogicalLinesRange(buffer, needle, pattern, 0, buffer.len);
    const seams = [_]usize{ 1, 9, 17, 31, 44, buffer.len - 1 };
    for (seams) |seam| {
        const left_end = findOwnedLineBoundaryAfter(buffer, seam) orelse buffer.len;
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
        const left_end = findOwnedLineBoundaryAfter(buffer, seam) orelse buffer.len;
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
    const first_end = findOwnedLineBoundaryAfter(buffer, 1).?;
    const second_end = findOwnedLineBoundaryAfter(buffer, first_end + 1).?;
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
    const forward = [_]DiscoveredFile{
        .{ .path = "src/main.zig" },
        .{ .path = "src/core/search.zig" },
        .{ .path = "src/core/stats.zig" },
    };
    const reversed = [_]DiscoveredFile{
        .{ .path = "src/core/stats.zig" },
        .{ .path = "src/core/search.zig" },
        .{ .path = "src/main.zig" },
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

test "evidence frontier prepare narrows active files and accounts cached prunes" {
    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var request = testSearchRequest("lit:needle", "fixture-root");
    request.nexus_build = true;
    const plan = try expr.parse(request.expression);
    const admission = trigram.admit(plan);
    const files = [_]DiscoveredFile{
        .{ .path = "src/main.zig" },
        .{ .path = "src/core/search.zig" },
    };
    var candidates = [_]DiscoveredFile{files[1]};
    const signature = try computeDiscoveredSignature(io, &files);
    const key = evidenceFrontierKey(request, plan);
    const cache_path = try std.fmt.allocPrint(allocator, ".ix-evidence-{x}.cache", .{key});
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
    try std.testing.expectEqualStrings("src/core/search.zig", active[0].path);
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

test "search run consumes evidence frontier and scans only retained candidates" {
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
    const cache_path = try std.fmt.allocPrint(allocator, ".ix-evidence-{x}.cache", .{key});
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

    const report = try run(io, allocator, request, plan);
    try std.testing.expectEqual(@as(f64, 0), report.discover_ms);
    try std.testing.expectEqual(@as(usize, 1), report.matches_found);
    try std.testing.expectEqual(@as(usize, 1), report.hit_count);
    try std.testing.expectEqualStrings(retained[0].path, report.hits[0].path);
    try std.testing.expectEqual(@as(usize, 1), report.stats.trigram_acceleration.pruned_files);
    try std.testing.expectEqual(@as(usize, 2), report.files_scanned);
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
    const index_dir = try std.fs.path.join(allocator, &.{ root_path, ".ix", "index" });
    try std.Io.Dir.cwd().createDirPath(io, index_dir);
    const live_path = try std.fs.path.join(allocator, &.{ index_dir, WARM_INDEX_LIVE_MARKER_NAME });
    const live_marker = try std.fmt.allocPrint(allocator, "IXINDEX_LIVE1\npid={}\nroot={s}\n", .{ currentProcessId(), root_path });
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
    const index_dir = try std.fs.path.join(allocator, &.{ root_path, ".ix", "index" });
    try std.Io.Dir.cwd().createDirPath(io, index_dir);
    const live_path = try std.fs.path.join(allocator, &.{ index_dir, WARM_INDEX_LIVE_MARKER_NAME });
    const live_marker = try std.fmt.allocPrint(allocator, "IXINDEX_LIVE1\npid={}\nroot={s}\n", .{ currentProcessId(), root_path });
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

    const cached = try run(io, allocator, request, plan);
    try std.testing.expectEqual(@as(usize, 2), cached.matches_found);
    try std.testing.expectEqual(@as(usize, 0), cached.files_scanned);
    try std.testing.expectEqual(@as(f64, 0), cached.discover_ms);
    try std.testing.expectEqualStrings("live_query_stats_cache", cached.stats.generation_refresh.refresh_status);
    try std.testing.expectEqualStrings("query_stats_cache", cached.stats.postings_index.fallback_reason);
}

test "protected Windows stats-only binary container skip stays scoped" {
    var request = testSearchRequest("lit:needle", "C:\\Windows\\System32");
    request.stats_only = true;

    if (builtin.os.tag == .windows) {
        try std.testing.expect(shouldSkipProtectedBinaryContainer(request, "C:\\Windows\\System32\\kernel32.dll"));
        try std.testing.expect(shouldSkipProtectedBinaryContainer(request, "C:/Windows/System32/catroot/example.cat"));
        try std.testing.expect(shouldSkipProtectedBinaryContainer(request, "C:\\Windows\\System32\\en-US\\shell32.dll.mui"));
        try std.testing.expect(shouldSkipProtectedBinaryContainer(request, "C:\\Windows\\System32\\catroot2\\edbtmp.log"));
        try std.testing.expect(!shouldSkipProtectedBinaryContainer(request, "C:\\Windows\\System32\\DriverStore\\sample.inf"));
        try std.testing.expect(!shouldSkipProtectedBinaryContainer(request, "C:\\Windows\\System32\\drivers\\etc\\hosts"));
        try std.testing.expect(!shouldSkipProtectedBinaryContainer(request, "E:\\repo\\fake.dll"));
        request.stats_only = false;
        try std.testing.expect(!shouldSkipProtectedBinaryContainer(request, "C:\\Windows\\System32\\kernel32.dll"));
    } else {
        try std.testing.expect(!shouldSkipProtectedBinaryContainer(request, "C:\\Windows\\System32\\kernel32.dll"));
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
