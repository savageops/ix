const std = @import("std");
const cli = @import("../cli/args.zig");
const expr = @import("expr.zig");
const regex = @import("regex.zig");
const pcre_regex = @import("pcre_regex.zig");
const core_stats = @import("stats.zig");
const trigram = @import("trigram.zig");
// SIMD-accelerated byte/substring search via StringZilla (see sz.zig).
// Replaces std.mem.indexOf (~1 byte/cycle) with AVX2 search (~32 bytes/cycle)
// on the three hottest paths: newline scanning, binary sniffing, and literal matching.
const sz = @import("sz.zig");

/// Maximum hit records retained in the report. Beyond this count, matches
/// are still counted for stats but individual hit records are not stored.
/// This bounds memory usage for searches that hit millions of lines.
pub const MAX_RETAINED_HITS = 4096;

const TRIGRAM_MIN_PRUNE_BYTES: usize = 64 * 1024;

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

    // Phase 1: Discover all files via serial directory walk.
    const discover_started = std.Io.Timestamp.now(io, .awake);
    var file_list = try FileList.initWithCapacity(allocator, 512);
    for (roots.items[0..roots.count]) |root| {
        try discoverFiles(io, allocator, root.original, request, &file_list, &report);
    }
    report.discover_ms = elapsedMs(io, discover_started);

    // Phase 2: Scan files — thread count adapts to corpus size after discovery.
    const scan_started = std.Io.Timestamp.now(io, .awake);
    const discovered = file_list.items(allocator);
    const trigram_admission = trigram.admit(plan);
    initTrigramStats(&report.stats.trigram_acceleration, trigram_admission, request.case_insensitive);
    const thread_count = effectiveThreadCount(request, discovered.len);
    report.outer_scan_threads = thread_count;
    if (discovered.len == 0) {
        // No files discovered — nothing to scan.
    } else if (thread_count <= 1 or discovered.len < 4) {
        // Serial path: single thread or too few files to justify workers.
        for (discovered) |entry| {
            try scanDiscoveredFile(io, allocator, entry.path, request, plan, trigram_admission, &report);
            if (report.truncated) break;
        }
    } else {
        try parallelScanFiles(io, allocator, discovered, request, plan, trigram_admission, thread_count, &report);
    }
    report.scan_ms = elapsedMs(io, scan_started);

    const aggregate_started = std.Io.Timestamp.now(io, .awake);
    report.aggregate_ms = elapsedMs(io, aggregate_started);
    report.total_ms = elapsedMs(io, total_started);
    refreshStats(&report);
    return report;
}

/// Determine effective thread count for parallel scanning.
/// Uses the --threads flag if provided, otherwise scales adaptively with corpus size.
///
/// ADAPTIVE SCALING RATIONALE:
/// On Windows, spawning one OS thread (CreateThread) costs ~210μs. For small
/// corpora, over-threading means spawn_cost dwarfs actual scan work.
///
/// Optimal thread count N minimises: spawn_cost*N + total_work/N
/// Setting d/dN = 0: N* = sqrt(total_work / spawn_cost)
/// Empirically, the retained upstream candidate benefits from a more conservative
/// Windows split point: avoid extra worker fanout until discovery material is
/// large enough to amortize thread spawn and shard reduction.
fn effectiveThreadCount(request: cli.SearchRequest, file_count: usize) usize {
    if (request.threads) |threads| return @max(threads, 1);
    const cpus = availableThreads();
    const hard_cap: usize = @min(cpus, 16);
    // ceil(sqrt(file_count / 8)): loop finds smallest n where n² * 8 >= file_count.
    var adaptive: usize = 1;
    while (adaptive * adaptive * 8 < file_count) : (adaptive += 1) {}
    return @min(hard_cap, adaptive);
}

/// A discovered file entry — path is arena-allocated and lives for the
/// process lifetime.
const DiscoveredFile = struct {
    path: []const u8,
};

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
};

/// Phase 1: Recursively walk a root path and collect all scannable file paths.
/// This is fast — only readdir syscalls, no file content reads. Hidden files
/// are filtered here, and files_discovered/files_skipped are counted on the
/// main report (single-threaded, no contention).
fn discoverFiles(
    io: std.Io,
    allocator: std.mem.Allocator,
    path: []const u8,
    request: cli.SearchRequest,
    file_list: *FileList,
    report: *SearchReport,
) anyerror!void {
    // Try opening as a file first. If it's a directory, recurse.
    const file = std.Io.Dir.cwd().openFile(io, path, .{ .allow_directory = false }) catch |file_err| switch (file_err) {
        error.IsDir, error.AccessDenied => {
            try discoverDirectory(io, allocator, path, request, file_list, report);
            return;
        },
        else => return file_err,
    };
    file.close(io);
    report.files_discovered += 1;
    const display_path = try normalizeDisplayPath(allocator, path);
    try file_list.append(allocator, .{ .path = display_path });
}

fn discoverDirectory(
    io: std.Io,
    allocator: std.mem.Allocator,
    path: []const u8,
    request: cli.SearchRequest,
    file_list: *FileList,
    report: *SearchReport,
) anyerror!void {
    const dir = try std.Io.Dir.cwd().openDir(io, path, .{ .iterate = true });
    defer dir.close(io);
    var iterator = dir.iterate();
    while (try iterator.next(io)) |entry| {
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
            .directory => try discoverDirectory(io, allocator, child_path, request, file_list, report),
            else => {},
        }
    }
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
    trigram_stats: core_stats.TrigramAccelerationStats,
    slowest_path: []const u8,
    slowest_bytes: usize,
    slowest_ms: f64,
    hits: [MAX_RETAINED_HITS]SearchHit,
    hit_count: usize,
    truncated: bool,
    had_error: bool,

    const empty: ShardReport = .{
        .bytes_scanned = 0,
        .files_scanned = 0,
        .files_skipped = 0,
        .matches_found = 0,
        .scan_work_ms_total = 0,
        .trigram_stats = .{},
        .slowest_path = "",
        .slowest_bytes = 0,
        .slowest_ms = 0,
        .hits = undefined,
        .hit_count = 0,
        .truncated = false,
        .had_error = false,
    };
};

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
    report: *SearchReport,
) anyerror!void {
    // display_path is already normalized; open via the original-ish path.
    // We re-derive a filesystem path by using display_path directly since
    // we stored normalized forward-slash paths during discovery.
    const file = std.Io.Dir.cwd().openFile(io, display_path, .{ .allow_directory = false }) catch |err| switch (err) {
        error.IsDir, error.AccessDenied => return,
        else => return err,
    };
    defer file.close(io);
    try scanOpenFile(io, allocator, file, display_path, request, plan, trigram_admission, report);
}

/// Scan a single file into a ShardReport (thread-local, no sync needed).
fn scanFileIntoShard(
    io: std.Io,
    allocator: std.mem.Allocator,
    display_path: []const u8,
    request: cli.SearchRequest,
    plan: expr.ExpressionPlan,
    trigram_admission: trigram.Admission,
    shard: *ShardReport,
) void {
    const file = std.Io.Dir.cwd().openFile(io, display_path, .{ .allow_directory = false }) catch {
        shard.files_skipped += 1;
        return;
    };
    defer file.close(io);
    scanOpenFileIntoShard(io, allocator, file, display_path, request, plan, trigram_admission, shard) catch {
        shard.had_error = true;
    };
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
    shard: *ShardReport,
) anyerror!void {
    const file_started = std.Io.Timestamp.now(io, .awake);
    var read_buffer: [1024 * 1024]u8 = undefined;

    // Read first chunk before length lookup. Single-shot positional read avoids
    // the retry syscall that readPositionalAll pays on sub-1MiB files.
    const first_read = try file.readPositional(io, &.{&read_buffer}, 0);
    if (first_read == 0) {
        shard.files_scanned += 1;
        recordLineIntoShardImpl(mono, allocator, display_path, "", 1, request, plan, shard, false);
        const file_ms = elapsedMs(io, file_started);
        shard.scan_work_ms_total += file_ms;
        if (file_ms >= shard.slowest_ms) shard.slowest_ms = file_ms;
        return;
    }
    if (sz.indexOfByte(read_buffer[0..@min(1024, first_read)], 0) != null) {
        shard.files_skipped += 1;
        return;
    }
    const single_chunk = first_read < read_buffer.len;
    const file_bytes: usize = if (single_chunk) first_read else @intCast(try file.length(io));

    shard.files_scanned += 1;
    shard.bytes_scanned += file_bytes;
    if (file_bytes >= shard.slowest_bytes) {
        shard.slowest_path = display_path;
        shard.slowest_bytes = file_bytes;
    }
    if (shouldAttemptTrigramPrune(file_bytes, single_chunk, trigram_admission, request.case_insensitive) and
        tryTrigramPruneFile(read_buffer[0..first_read], trigram_admission, &shard.trigram_stats))
    {
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
            const file_ms = elapsedMs(io, file_started);
            shard.scan_work_ms_total += file_ms;
            if (file_ms >= shard.slowest_ms) shard.slowest_ms = file_ms;
            return;
        }
    }

    var carry: std.ArrayList(u8) = .empty;
    defer carry.deinit(allocator);
    var line_number: usize = 1;
    var ended_with_newline = false;

    // Process first chunk then any remaining chunks (most files fit in one chunk).
    var chunk: []const u8 = read_buffer[0..first_read];
    var offset: u64 = first_read;
    while (true) {
        ended_with_newline = chunk[chunk.len - 1] == '\n';
        var chunk_index: usize = 0;
        while (chunk_index < chunk.len) {
            if (sz.indexOfByte(chunk[chunk_index..], '\n')) |relative_newline| {
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
    shard: *ShardReport,
) anyerror!void {
    return scanOpenFileIntoShardImpl(null, io, allocator, file, display_path, request, plan, trigram_admission, shard);
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
fn shardWorker(io: std.Io, allocator: std.mem.Allocator, files: []const DiscoveredFile, request: cli.SearchRequest, plan: expr.ExpressionPlan, trigram_admission: trigram.Admission, shard: *ShardReport) void {
    if (plan.predicate_count == 1) {
        dispatchMonoShardLoop(io, allocator, files, request, plan, trigram_admission, shard);
    } else {
        for (files) |entry| {
            if (shard.truncated) break;
            scanFileIntoShard(io, allocator, entry.path, request, plan, trigram_admission, shard);
        }
    }
}

fn dynamicShardWorker(io: std.Io, allocator: std.mem.Allocator, next_file: *usize, files: []const DiscoveredFile, request: cli.SearchRequest, plan: expr.ExpressionPlan, trigram_admission: trigram.Admission, shard: *ShardReport) void {
    if (plan.predicate_count == 1) {
        dispatchMonoDynamicLoop(io, allocator, next_file, files, request, plan, trigram_admission, shard);
    } else {
        while (!shard.truncated) {
            const index = @atomicRmw(usize, next_file, .Add, 1, .monotonic);
            if (index >= files.len) break;
            scanFileIntoShard(io, allocator, files[index].path, request, plan, trigram_admission, shard);
        }
    }
}

/// Resolve single-predicate plan to comptime-known kind+strategy, then enter
/// monomorphized file loop. Dispatch happens once per worker thread.
fn dispatchMonoShardLoop(io: std.Io, allocator: std.mem.Allocator, files: []const DiscoveredFile, request: cli.SearchRequest, plan: expr.ExpressionPlan, trigram_admission: trigram.Admission, shard: *ShardReport) void {
    const pred = plan.predicates[0];
    switch (pred.kind) {
        .literal => monoShardLoop(.{ .kind = .literal, .strategy = .literal }, io, allocator, files, request, plan, trigram_admission, shard),
        .prefix => monoShardLoop(.{ .kind = .prefix, .strategy = .prefix }, io, allocator, files, request, plan, trigram_admission, shard),
        .suffix => monoShardLoop(.{ .kind = .suffix, .strategy = .suffix }, io, allocator, files, request, plan, trigram_admission, shard),
        .regex => switch (pred.strategy) {
            inline else => |strategy| monoShardLoop(.{ .kind = .regex, .strategy = strategy }, io, allocator, files, request, plan, trigram_admission, shard),
        },
    }
}

fn monoShardLoop(comptime mono: MonoSpec, io: std.Io, allocator: std.mem.Allocator, files: []const DiscoveredFile, request: cli.SearchRequest, plan: expr.ExpressionPlan, trigram_admission: trigram.Admission, shard: *ShardReport) void {
    for (files) |entry| {
        if (shard.truncated) break;
        scanFileIntoShardMono(mono, io, allocator, entry.path, request, plan, trigram_admission, shard);
    }
}

fn dispatchMonoDynamicLoop(io: std.Io, allocator: std.mem.Allocator, next_file: *usize, files: []const DiscoveredFile, request: cli.SearchRequest, plan: expr.ExpressionPlan, trigram_admission: trigram.Admission, shard: *ShardReport) void {
    const pred = plan.predicates[0];
    switch (pred.kind) {
        .literal => monoDynamicLoop(.{ .kind = .literal, .strategy = .literal }, io, allocator, next_file, files, request, plan, trigram_admission, shard),
        .prefix => monoDynamicLoop(.{ .kind = .prefix, .strategy = .prefix }, io, allocator, next_file, files, request, plan, trigram_admission, shard),
        .suffix => monoDynamicLoop(.{ .kind = .suffix, .strategy = .suffix }, io, allocator, next_file, files, request, plan, trigram_admission, shard),
        .regex => switch (pred.strategy) {
            inline else => |strategy| monoDynamicLoop(.{ .kind = .regex, .strategy = strategy }, io, allocator, next_file, files, request, plan, trigram_admission, shard),
        },
    }
}

fn monoDynamicLoop(comptime mono: MonoSpec, io: std.Io, allocator: std.mem.Allocator, next_file: *usize, files: []const DiscoveredFile, request: cli.SearchRequest, plan: expr.ExpressionPlan, trigram_admission: trigram.Admission, shard: *ShardReport) void {
    while (!shard.truncated) {
        const index = @atomicRmw(usize, next_file, .Add, 1, .monotonic);
        if (index >= files.len) break;
        scanFileIntoShardMono(mono, io, allocator, files[index].path, request, plan, trigram_admission, shard);
    }
}

/// Monomorphized file opener — calls scanOpenFileIntoShardImpl with comptime mono.
fn scanFileIntoShardMono(comptime mono: MonoSpec, io: std.Io, allocator: std.mem.Allocator, display_path: []const u8, request: cli.SearchRequest, plan: expr.ExpressionPlan, trigram_admission: trigram.Admission, shard: *ShardReport) void {
    const file = std.Io.Dir.cwd().openFile(io, display_path, .{ .allow_directory = false }) catch {
        shard.files_skipped += 1;
        return;
    };
    defer file.close(io);
    scanOpenFileIntoShardImpl(mono, io, allocator, file, display_path, request, plan, trigram_admission, shard) catch {
        shard.had_error = true;
    };
}

fn shouldUseDynamicWorkClaim(plan: expr.ExpressionPlan, file_count: usize) bool {
    if (file_count > 128) return false;
    return canUseDynamicWorkClaimForPlan(plan);
}

fn canUseDynamicWorkClaimForPlan(plan: expr.ExpressionPlan) bool {
    if (plan.predicate_count != 1) return false;
    const predicate = plan.predicates[0];
    if (predicate.kind == .literal) return true;
    return predicate.kind == .regex and predicate.strategy == .regex_literal_alternates;
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
    thread_count: usize,
    report: *SearchReport,
) !void {
    const actual_threads = @min(thread_count, files.len);
    // Worker threads = actual_threads - 1 (main thread takes a shard too).
    const worker_count = actual_threads - 1;

    // Allocate shard reports — one per thread (including main).
    const shards = try allocator.alloc(ShardReport, actual_threads);
    for (shards) |*s| s.* = ShardReport.empty;

    if (shouldUseDynamicWorkClaim(plan, files.len)) {
        var next_file: usize = 0;
        const threads = try allocator.alloc(std.Thread, worker_count);
        for (0..worker_count) |i| {
            const shard_index = i + 1;
            threads[i] = try std.Thread.spawn(.{}, dynamicShardWorker, .{ io, allocator, &next_file, files, request, plan, trigram_admission, &shards[shard_index] });
        }
        dynamicShardWorker(io, allocator, &next_file, files, request, plan, trigram_admission, &shards[0]);
        for (threads) |thread| thread.join();
        mergeShardsIntoReport(shards, report);
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
        threads[i] = try std.Thread.spawn(.{}, shardWorker, .{ io, allocator, shard_files, request, plan, trigram_admission, &shards[shard_index] });
    }

    // Main thread processes shard 0.
    const main_files = files[boundaries[0]..boundaries[1]];
    shardWorker(io, allocator, main_files, request, plan, trigram_admission, &shards[0]);

    // Join all worker threads.
    for (threads) |t| t.join();

    mergeShardsIntoReport(shards, report);
}

fn mergeShardsIntoReport(shards: []const ShardReport, report: *SearchReport) void {
    for (shards) |shard| {
        report.bytes_scanned += shard.bytes_scanned;
        report.files_scanned += shard.files_scanned;
        report.files_skipped += shard.files_skipped;
        report.matches_found += shard.matches_found;
        report.scan_work_ms_total += shard.scan_work_ms_total;
        mergeTrigramStats(&report.stats.trigram_acceleration, shard.trigram_stats);
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
    report.stats.concurrency = .{
        .available_threads = report.available_threads,
        .outer_scan_threads = report.outer_scan_threads,
        .execution_mode = "materialized",
        .sharding_enabled = false,
        .sharded_files = 0,
        .max_shard_threads = 0,
        .max_shard_ranges = 0,
        .max_shard_chunk_bytes = 0,
    };
    report.stats.recordSlowFile(report.slowest_path, report.slowest_ms, report.slowest_bytes, false);
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

fn tryTrigramPruneFile(
    bytes: []const u8,
    admission: trigram.Admission,
    stats: *core_stats.TrigramAccelerationStats,
) bool {
    stats.candidate_files_checked += 1;
    if (trigramAdmissionMayMatch(bytes, admission)) {
        stats.verified_files += 1;
        return false;
    }
    stats.pruned_files += 1;
    return true;
}

fn shouldAttemptTrigramPrune(file_bytes: usize, single_chunk: bool, admission: trigram.Admission, case_insensitive: bool) bool {
    return admission.eligible and !case_insensitive and single_chunk and file_bytes >= TRIGRAM_MIN_PRUNE_BYTES;
}

fn trigramAdmissionMayMatch(bytes: []const u8, admission: trigram.Admission) bool {
    if (admission.mode == .any) {
        for (admission.groups[0..admission.group_count]) |group| {
            if (trigramGroupMayMatch(bytes, group)) return true;
        }
        return false;
    }
    for (admission.groups[0..admission.group_count]) |group| {
        if (!trigramGroupMayMatch(bytes, group)) return false;
    }
    return true;
}

fn trigramGroupMayMatch(bytes: []const u8, group: trigram.PredicateEvidence) bool {
    for (group.trigrams[0..group.trigram_count]) |needle| {
        if (!bytesContainTrigram(bytes, needle)) return false;
    }
    return true;
}

fn bytesContainTrigram(bytes: []const u8, needle: trigram.Trigram) bool {
    if (bytes.len < 3) return false;
    const key_bytes = [_]u8{
        @intCast((needle >> 16) & 0xff),
        @intCast((needle >> 8) & 0xff),
        @intCast(needle & 0xff),
    };
    return sz.indexOf(bytes, key_bytes[0..]) != null;
}

fn availableThreads() usize {
    return std.Thread.getCpuCount() catch 1;
}

/// Core per-file scan loop. Reads the file in 1 MiB chunks, splits into
/// lines, and runs predicate matching on each line.
///
/// WHY CHUNKED READS INSTEAD OF MMAP:
/// Zig's std library doesn't expose mmap on Windows in a way that matches
/// Rust's `memmap2` ergonomics. Rust's search engine memory-maps large files
/// for zero-copy access, which avoids the read() syscall overhead and lets
/// the OS page in data on demand. This chunked approach copies data into a
/// stack buffer, adding syscall + memcpy overhead per chunk. This is one of
/// the remaining performance gaps vs Rust on large files.
///
/// WHY 1 MiB CHUNKS:
/// 1 MiB fits comfortably in L2/L3 cache on modern CPUs, so the StringZilla
/// SIMD newline scan operates on warm cache lines. Larger buffers risk
/// cache thrashing; smaller ones increase syscall frequency.
///
/// THE CARRY BUFFER:
/// Lines can span chunk boundaries (a line starts in chunk N and ends in
/// chunk N+1). The `carry` ArrayList accumulates partial line bytes across
/// chunks. When a newline is found, carry + current chunk segment form the
/// complete line. This is the standard streaming line-split pattern.
fn scanOpenFile(
    io: std.Io,
    allocator: std.mem.Allocator,
    file: std.Io.File,
    display_path: []const u8,
    request: cli.SearchRequest,
    plan: expr.ExpressionPlan,
    trigram_admission: trigram.Admission,
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
    if (sz.indexOfByte(read_buffer[0..@min(1024, first_read)], 0) != null) {
        report.files_skipped += 1;
        return;
    }
    const single_chunk = first_read < read_buffer.len;
    const file_bytes: usize = if (single_chunk) first_read else @intCast(try file.length(io));

    report.files_scanned += 1;
    report.bytes_scanned += file_bytes;
    if (file_bytes >= report.slowest_bytes) {
        report.slowest_path = display_path;
        report.slowest_bytes = file_bytes;
    }
    if (shouldAttemptTrigramPrune(file_bytes, single_chunk, trigram_admission, request.case_insensitive) and
        tryTrigramPruneFile(read_buffer[0..first_read], trigram_admission, &report.stats.trigram_acceleration))
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
    // HOT PATH: sz.indexOfByte uses AVX2 VPCMPEQB — 32 bytes/cycle vs 1 byte/cycle scalar.
    var chunk: []const u8 = read_buffer[0..first_read];
    var offset: u64 = first_read;
    while (true) {
        ended_with_newline = chunk[chunk.len - 1] == '\n';
        var chunk_index: usize = 0;
        while (chunk_index < chunk.len) {
            if (sz.indexOfByte(chunk[chunk_index..], '\n')) |relative_newline| {
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
        else => null,
    };
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
        .regex_literal_alternates => if (literalAlternatesColumn(line, predicate.value, case_insensitive) != null) 1 else 0,
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
    const effective_pattern = if (std.mem.startsWith(u8, pattern, "(?i)")) pattern[4..] else pattern;
    const prefix = extractLiteralPrefix(effective_pattern);
    if (prefix.len >= 2) {
        if (indexOfLiteral(line, prefix, case_insensitive) == null) return 0;
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
            return literalAlternatesColumn(line, predicate.value, case_insensitive);
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

/// For regex_full patterns, extract the literal prefix (if any) and use
/// StringZilla to reject lines that can't match before running the regex.
/// E.g. `process_\d+_\d+` has literal prefix `process_` — lines without
/// it are skipped entirely. This avoids the recursive backtracking cost
/// on the ~90% of lines that don't contain the prefix.
fn regexWithLiteralPrefilter(line: []const u8, pattern: []const u8, case_insensitive: bool) ?usize {
    const effective_pattern = if (std.mem.startsWith(u8, pattern, "(?i)")) pattern[4..] else pattern;
    const prefix = extractLiteralPrefix(effective_pattern);
    if (prefix.len >= 2) {
        if (indexOfLiteral(line, prefix, case_insensitive) == null) return null;
    }
    return pcre_regex.column(line, pattern, case_insensitive) catch
        regex.column(line, pattern, case_insensitive);
}

/// Extract the leading literal bytes from a regex pattern, stopping at
/// the first metacharacter or escape sequence. Returns an empty slice
/// if the pattern starts with a metacharacter.
fn extractLiteralPrefix(pattern: []const u8) []const u8 {
    var end: usize = 0;
    while (end < pattern.len) {
        const byte = pattern[end];
        const token_end = regexPrefixTokenEnd(pattern, end) orelse break;
        if (token_end < pattern.len and (pattern[token_end] == '?' or pattern[token_end] == '*')) break;
        if (byte == '\\') break; // escape sequence — not a plain literal
        if (isRegexMetaChar(byte)) break;
        end = token_end;
    }
    return pattern[0..end];
}

fn regexPrefixTokenEnd(pattern: []const u8, index: usize) ?usize {
    if (index >= pattern.len) return null;
    if (pattern[index] == '\\') {
        if (index + 1 >= pattern.len) return null;
        if (pattern[index + 1] == 'x') return if (index + 3 < pattern.len) index + 4 else null;
        return index + 2;
    }
    if (isRegexMetaChar(pattern[index])) return null;
    return index + 1;
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
// then run StringZilla's AVX2 memmem on the lowered copies.
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
/// Case-sensitive path uses sz.indexOf (StringZilla AVX2 memmem), which
/// fingerprints by first+last byte across 32 positions per SIMD pass.
///
/// Case-insensitive path dispatches to indexOfLiteralCasefold (separate
/// function) to keep this hot path's stack frame under 4 KiB. On Windows,
/// frames > 4 KiB trigger __chkstk page probes on every call — including
/// case-sensitive calls that take the early return. Isolating the 32 KiB
/// casefold buffer into its own function eliminates that overhead.
fn indexOfLiteral(line: []const u8, needle: []const u8, case_insensitive: bool) ?usize {
    if (!case_insensitive) return sz.indexOf(line, needle);
    if (needle.len == 0) return 0;
    if (needle.len > line.len) return null;
    return indexOfLiteralCasefold(line, needle);
}

/// SIMD casefold search — isolated from indexOfLiteral to quarantine the
/// 32 KiB stack buffer away from the case-sensitive hot path.
/// Lowercase both line and needle into stack buffers via AVX2 vector ops,
/// then search with sz.indexOf. O(n) casefold + O(n) SIMD search.
fn indexOfLiteralCasefold(line: []const u8, needle: []const u8) ?usize {
    if (line.len <= CASEFOLD_LINE_MAX and needle.len <= CASEFOLD_NEEDLE_MAX) {
        var lower_line: [CASEFOLD_LINE_MAX]u8 = undefined;
        var lower_needle: [CASEFOLD_NEEDLE_MAX]u8 = undefined;
        asciiLowerBuf(lower_line[0..line.len], line);
        asciiLowerBuf(lower_needle[0..needle.len], needle);
        return sz.indexOf(lower_line[0..line.len], lower_needle[0..needle.len]);
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
/// Case-sensitive path calls sz.indexOf directly in a tight loop.
/// Case-insensitive path dispatches to countLiteralCasefold (separate
/// function) to quarantine the 32 KiB casefold buffer.
fn countLiteral(line: []const u8, needle: []const u8, case_insensitive: bool) usize {
    if (needle.len == 0) return 0;
    if (case_insensitive) return countLiteralCasefold(line, needle);
    // Case-sensitive: sz.indexOf directly, no indirection.
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
/// 32 KiB stack buffer. Lowercase the line once, then loop sz.indexOf
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
            const index = sz.indexOf(ll[start..], ln) orelse break;
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

fn isWordChar(byte: u8) bool {
    return std.ascii.isAlphanumeric(byte) or byte == '_';
}

/// Search for a top-level literal alternation pattern such as `alpha|beta`.
/// Each branch is a plain literal — search them individually and return
/// the earliest match column.
fn literalAlternatesColumn(line: []const u8, pattern: []const u8, case_insensitive: bool) ?usize {
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

test "trigram gate rejects impossible complete file without verifier authority" {
    const plan = try expr.parse("lit:needle");
    const admission = trigram.admit(plan);
    var stats = core_stats.TrigramAccelerationStats{};
    initTrigramStats(&stats, admission, false);
    var bytes: [TRIGRAM_MIN_PRUNE_BYTES]u8 = undefined;
    @memset(bytes[0..], 'a');

    try std.testing.expect(shouldAttemptTrigramPrune(bytes.len, true, admission, false));
    try std.testing.expect(tryTrigramPruneFile(bytes[0..], admission, &stats));
    try std.testing.expect(stats.eligible);
    try std.testing.expectEqual(@as(usize, 1), stats.candidate_files_checked);
    try std.testing.expectEqual(@as(usize, 1), stats.pruned_files);
    try std.testing.expectEqual(@as(usize, 0), stats.verified_files);
}

test "trigram gate admits possible file for exact verifier" {
    const plan = try expr.parse("lit:needle");
    const admission = trigram.admit(plan);
    var stats = core_stats.TrigramAccelerationStats{};
    initTrigramStats(&stats, admission, false);
    var bytes: [TRIGRAM_MIN_PRUNE_BYTES]u8 = undefined;
    @memset(bytes[0..], 'a');
    @memcpy(bytes[128..134], "needle");

    try std.testing.expect(shouldAttemptTrigramPrune(bytes.len, true, admission, false));
    try std.testing.expect(!tryTrigramPruneFile(bytes[0..], admission, &stats));
    try std.testing.expectEqual(@as(usize, 1), stats.candidate_files_checked);
    try std.testing.expectEqual(@as(usize, 0), stats.pruned_files);
    try std.testing.expectEqual(@as(usize, 1), stats.verified_files);
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
