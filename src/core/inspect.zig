const std = @import("std");
const cli = @import("../cli/args.zig");
const expr = @import("expr.zig");
const search = @import("search.zig");

pub const MAX_WINDOW_LINES = 512;

pub const InspectError = error{
    MissingTarget,
    InvalidRange,
    IncompatibleBounds,
};

pub const InspectLine = struct {
    number: usize,
    text: []const u8,
};

pub const InspectWindow = struct {
    path: []const u8,
    request_label: []const u8,
    start_line: usize,
    limit: ?usize,
    skip: usize,
    allow_full: bool,
    requested_end_line: ?usize,
    end_line: usize,
    has_more: bool,
    eof: bool,
    total_lines: ?usize,
    lines: []InspectLine,
    line_count: usize,
};

pub const MAX_CONTEXT_LINES = 4096;

pub const ContextLine = struct {
    number: usize,
    role: []const u8,
    text: []const u8,
};

pub const ContextReport = struct {
    path: []const u8,
    expression: []const u8,
    lines: []ContextLine,
    line_count: usize,
};

pub const CachedContextLine = struct {
    number: usize,
    text: []const u8,
    first_cover_hit: usize,
    first_match_hit: ?usize,
};

pub const CachedContextFile = struct {
    path: []const u8,
    lines: []const CachedContextLine,
};

pub const ContextCache = struct {
    expression: []const u8,
    files: []const CachedContextFile,
};

pub fn window(io: std.Io, allocator: std.mem.Allocator, request: cli.InspectRequest) !InspectWindow {
    if (request.path_count == 0) return InspectError.MissingTarget;
    return windowForPath(io, allocator, request, request.paths[0]);
}

pub fn windowForPath(io: std.Io, allocator: std.mem.Allocator, request: cli.InspectRequest, path: []const u8) !InspectWindow {
    const bounds = try resolveBounds(request);
    const output_lines = try allocator.alloc(InspectLine, MAX_WINDOW_LINES);
    var output = InspectWindow{
        .path = try normalizeDisplayPath(allocator, path),
        .request_label = try requestLabel(allocator, bounds),
        .start_line = bounds.start_line,
        .limit = bounds.limit,
        .skip = bounds.skip,
        .allow_full = bounds.allow_full,
        .requested_end_line = bounds.end_line,
        .end_line = bounds.start_line - 1,
        .has_more = false,
        .eof = true,
        .total_lines = null,
        .lines = output_lines,
        .line_count = 0,
    };

    const file = try std.Io.Dir.cwd().openFile(io, path, .{ .allow_directory = false });
    defer file.close(io);
    var read_buffer: [8192]u8 = undefined;
    var reader = file.reader(io, &read_buffer);
    var line_buffer: std.Io.Writer.Allocating = .init(std.heap.page_allocator);
    defer line_buffer.deinit();

    var line_number: usize = 1;
    while (try nextLine(&reader.interface, &line_buffer)) |raw_line| : (line_number += 1) {
        const line = std.mem.trimEnd(u8, raw_line, "\r");
        if (line_number < bounds.start_line) continue;
        if (bounds.end_line) |end_line| {
            if (line_number > end_line) {
                output.has_more = true;
                output.eof = false;
                break;
            }
        }
        if (bounds.limit) |limit| {
            if (output.line_count >= limit) {
                output.has_more = true;
                output.eof = false;
                break;
            }
        }
        if (output.line_count >= MAX_WINDOW_LINES) {
            output.has_more = true;
            output.eof = false;
            break;
        }
        output.lines[output.line_count] = .{ .number = line_number, .text = try allocator.dupe(u8, line) };
        output.line_count += 1;
        output.end_line = line_number;
    }
    if (output.eof) output.total_lines = line_number - 1;
    if (output.line_count == 0) output.end_line = bounds.end_line orelse bounds.start_line;
    return output;
}

pub fn context(io: std.Io, allocator: std.mem.Allocator, request: cli.InspectRequest, plan: expr.ExpressionPlan) !ContextReport {
    if (request.path_count == 0) return InspectError.MissingTarget;
    return contextForPath(io, allocator, request, request.paths[0], plan);
}

pub fn contextReportsFromSearchReport(io: std.Io, allocator: std.mem.Allocator, request: cli.InspectRequest, search_report: search.SearchReport) ![]ContextReport {
    var reports = std.ArrayList(ContextReport).empty;
    errdefer reports.deinit(allocator);
    var remaining_lines = request.total_count orelse MAX_CONTEXT_LINES;

    var hit_index: usize = 0;
    while (hit_index < search_report.hit_count and remaining_lines > 0) {
        const path = search_report.hits[hit_index].path;
        const start = hit_index;
        hit_index += 1;
        while (hit_index < search_report.hit_count and std.mem.eql(u8, search_report.hits[hit_index].path, path)) : (hit_index += 1) {}

        const report = try contextForSearchHitsPath(
            io,
            allocator,
            request,
            search_report.expression,
            path,
            search_report.hits[start..hit_index],
            remaining_lines,
        );
        remaining_lines -= report.line_count;
        if (report.line_count != 0) try reports.append(allocator, report);
    }

    return reports.toOwnedSlice(allocator);
}

/// Reads each represented source file once so byte-budget probes only reshape cached context.
pub fn cacheContextForSearchReport(io: std.Io, allocator: std.mem.Allocator, request: cli.InspectRequest, search_report: search.SearchReport) !ContextCache {
    if (!hasCanonicalHitOrder(search_report.hits[0..search_report.hit_count])) return error.NonCanonicalHitOrder;
    var files = std.ArrayList(CachedContextFile).empty;
    errdefer files.deinit(allocator);
    const before = request.before_context orelse request.context orelse 0;
    const after = request.after_context orelse request.context orelse 0;

    var hit_index: usize = 0;
    while (hit_index < search_report.hit_count) {
        const path = search_report.hits[hit_index].path;
        const start = hit_index;
        hit_index += 1;
        while (hit_index < search_report.hit_count and std.mem.eql(u8, search_report.hits[hit_index].path, path)) : (hit_index += 1) {}
        try files.append(allocator, try cacheContextFile(
            io,
            allocator,
            path,
            search_report.hits[start..hit_index],
            start,
            before,
            after,
        ));
    }
    return .{ .expression = search_report.expression, .files = try files.toOwnedSlice(allocator) };
}

/// Protects prefix-to-context ownership from interleaved files or descending source coordinates.
fn hasCanonicalHitOrder(hits: []const search.SearchHit) bool {
    if (hits.len < 2) return true;
    for (hits[1..], 1..) |hit, index| {
        const previous = hits[index - 1];
        switch (std.mem.order(u8, previous.path, hit.path)) {
            .gt => return false,
            .lt => continue,
            .eq => {},
        }
        if (hit.line < previous.line) return false;
        if (hit.line == previous.line and hit.column < previous.column) return false;
    }
    return true;
}

/// Materializes the exact coalesced windows for a hit prefix without touching the filesystem.
pub fn contextReportsFromCache(allocator: std.mem.Allocator, cache: ContextCache, visible_count: usize) ![]ContextReport {
    var reports = std.ArrayList(ContextReport).empty;
    errdefer reports.deinit(allocator);
    for (cache.files) |file| {
        var eligible_count: usize = 0;
        for (file.lines) |line| {
            if (line.first_cover_hit < visible_count) eligible_count += 1;
            if (eligible_count >= MAX_CONTEXT_LINES) break;
        }
        if (eligible_count == 0) continue;
        const lines = try allocator.alloc(ContextLine, eligible_count);
        var line_count: usize = 0;
        for (file.lines) |line| {
            if (line.first_cover_hit >= visible_count) continue;
            if (line_count >= eligible_count) break;
            lines[line_count] = .{
                .number = line.number,
                .role = if (line.first_match_hit != null and line.first_match_hit.? < visible_count) "match" else "context",
                .text = line.text,
            };
            line_count += 1;
        }
        try reports.append(allocator, .{
            .path = file.path,
            .expression = cache.expression,
            .lines = lines,
            .line_count = line_count,
        });
    }
    return reports.toOwnedSlice(allocator);
}

/// Captures only lines covered by a search-hit window and tags the earliest hit that owns each line.
fn cacheContextFile(
    io: std.Io,
    allocator: std.mem.Allocator,
    path: []const u8,
    hits: []const search.SearchHit,
    global_hit_start: usize,
    before: usize,
    after: usize,
) !CachedContextFile {
    var lines = std.ArrayList(CachedContextLine).empty;
    errdefer lines.deinit(allocator);
    if (hits.len == 0) return .{ .path = path, .lines = &.{} };

    const file = try std.Io.Dir.cwd().openFile(io, path, .{ .allow_directory = false });
    defer file.close(io);
    var read_buffer: [8192]u8 = undefined;
    var reader = file.reader(io, &read_buffer);
    var line_buffer: std.Io.Writer.Allocating = .init(std.heap.page_allocator);
    defer line_buffer.deinit();

    const last_needed = hits[hits.len - 1].line +| after;
    var line_number: usize = 1;
    var active_start: usize = 0;
    while (line_number <= last_needed) : (line_number += 1) {
        const raw_line = (try nextLine(&reader.interface, &line_buffer)) orelse break;
        while (active_start < hits.len and hits[active_start].line +| after < line_number) : (active_start += 1) {}
        if (active_start >= hits.len) break;

        var probe = active_start;
        var first_match_hit: ?usize = null;
        while (probe < hits.len and hits[probe].line -| before <= line_number) : (probe += 1) {
            if (hits[probe].line == line_number and first_match_hit == null) first_match_hit = global_hit_start + probe;
        }
        if (probe == active_start) continue;
        try lines.append(allocator, .{
            .number = line_number,
            .text = try allocator.dupe(u8, std.mem.trimEnd(u8, raw_line, "\r")),
            .first_cover_hit = global_hit_start + active_start,
            .first_match_hit = first_match_hit,
        });
    }
    return .{ .path = try normalizeDisplayPath(allocator, path), .lines = try lines.toOwnedSlice(allocator) };
}

pub fn contextForPath(io: std.Io, allocator: std.mem.Allocator, request: cli.InspectRequest, path: []const u8, plan: expr.ExpressionPlan) !ContextReport {
    const report_lines = try allocator.alloc(ContextLine, MAX_CONTEXT_LINES);
    var report = ContextReport{
        .path = try normalizeDisplayPath(allocator, path),
        .expression = request.expression orelse plan.source,
        .lines = report_lines,
        .line_count = 0,
    };

    const file = try std.Io.Dir.cwd().openFile(io, path, .{ .allow_directory = false });
    defer file.close(io);
    var read_buffer: [8192]u8 = undefined;
    var reader = file.reader(io, &read_buffer);
    var line_buffer: std.Io.Writer.Allocating = .init(std.heap.page_allocator);
    defer line_buffer.deinit();

    const source_lines = try allocator.alloc([]const u8, MAX_CONTEXT_LINES);
    const match_lines = try allocator.alloc(bool, MAX_CONTEXT_LINES);
    const emitted_lines = try allocator.alloc(bool, MAX_CONTEXT_LINES);
    var source_count: usize = 0;
    while (try nextLine(&reader.interface, &line_buffer)) |raw_line| {
        if (source_count >= MAX_CONTEXT_LINES) break;
        const line = std.mem.trimEnd(u8, raw_line, "\r");
        source_lines[source_count] = try allocator.dupe(u8, line);
        match_lines[source_count] = search.matchesLine(line, plan);
        emitted_lines[source_count] = false;
        source_count += 1;
    }

    const before = request.before_context orelse request.context orelse 0;
    const after = request.after_context orelse request.context orelse 0;
    const output_limit = @min(request.total_count orelse MAX_CONTEXT_LINES, MAX_CONTEXT_LINES);
    var index: usize = 0;
    while (index < source_count) : (index += 1) {
        if (!match_lines[index]) continue;
        const start = if (index >= before) index - before else 0;
        const end = @min(source_count - 1, index + after);
        var line_index = start;
        while (line_index <= end) : (line_index += 1) {
            if (emitted_lines[line_index]) continue;
            report.lines[report.line_count] = .{
                .number = line_index + 1,
                .role = if (match_lines[line_index]) "match" else "context",
                .text = source_lines[line_index],
            };
            emitted_lines[line_index] = true;
            report.line_count += 1;
            if (report.line_count >= output_limit) return report;
        }
    }
    return report;
}

fn contextForSearchHitsPath(
    io: std.Io,
    allocator: std.mem.Allocator,
    request: cli.InspectRequest,
    expression: []const u8,
    path: []const u8,
    hits: []const search.SearchHit,
    output_limit: usize,
) !ContextReport {
    const report_lines = try allocator.alloc(ContextLine, MAX_CONTEXT_LINES);
    var report = ContextReport{
        .path = try normalizeDisplayPath(allocator, path),
        .expression = request.expression orelse expression,
        .lines = report_lines,
        .line_count = 0,
    };
    if (hits.len == 0) return report;

    const before = request.before_context orelse request.context orelse 0;
    const after = request.after_context orelse request.context orelse 0;
    const last_needed = hits[hits.len - 1].line + after;

    const file = try std.Io.Dir.cwd().openFile(io, path, .{ .allow_directory = false });
    defer file.close(io);
    var read_buffer: [8192]u8 = undefined;
    var reader = file.reader(io, &read_buffer);
    var line_buffer: std.Io.Writer.Allocating = .init(std.heap.page_allocator);
    defer line_buffer.deinit();

    var line_number: usize = 1;
    var next_hit_index: usize = 0;
    var last_emitted: usize = 0;
    while (line_number <= last_needed) : (line_number += 1) {
        const raw_line = (try nextLine(&reader.interface, &line_buffer)) orelse break;

        while (next_hit_index < hits.len and hits[next_hit_index].line + after < line_number) : (next_hit_index += 1) {}
        if (next_hit_index >= hits.len) break;

        const hit_line = hits[next_hit_index].line;
        const window_start = if (hit_line > before) hit_line - before else 1;
        if (line_number < window_start) continue;

        var is_match = false;
        var probe = next_hit_index;
        while (probe < hits.len and hits[probe].line <= line_number) : (probe += 1) {
            if (hits[probe].line == line_number) {
                is_match = true;
                break;
            }
        }
        const in_window = line_number <= hit_line + after or is_match;
        if (!in_window or line_number == last_emitted) continue;

        report.lines[report.line_count] = .{
            .number = line_number,
            .role = if (is_match) "match" else "context",
            .text = try allocator.dupe(u8, std.mem.trimEnd(u8, raw_line, "\r")),
        };
        report.line_count += 1;
        last_emitted = line_number;
        if (report.line_count >= @min(output_limit, MAX_CONTEXT_LINES)) return report;
    }
    return report;
}

/// Streams one arbitrary-length line through a reusable buffer and consumes its delimiter.
fn nextLine(reader: *std.Io.Reader, line_buffer: *std.Io.Writer.Allocating) !?[]const u8 {
    line_buffer.clearRetainingCapacity();
    _ = try reader.streamDelimiterEnding(&line_buffer.writer, '\n');
    const has_delimiter = reader.seek < reader.end and reader.buffer[reader.seek] == '\n';
    if (has_delimiter) reader.toss(1);
    if (line_buffer.written().len == 0 and !has_delimiter) return null;
    return line_buffer.written();
}

fn normalizeDisplayPath(allocator: std.mem.Allocator, path: []const u8) ![]const u8 {
    const normalized = try allocator.dupe(u8, path);
    for (normalized) |*byte| {
        if (byte.* == '\\') byte.* = '/';
    }
    return normalized;
}

const Bounds = struct {
    start_line: usize,
    end_line: ?usize,
    skip: usize,
    limit: ?usize,
    allow_full: bool,
};

fn resolveBounds(request: cli.InspectRequest) InspectError!Bounds {
    if (request.range != null and (request.total_count != null or request.skip != null or request.limit != null or request.start_line != null or request.end_line != null or request.all)) return InspectError.IncompatibleBounds;
    if (request.total_count != null and (request.skip != null or request.limit != null or request.start_line != null or request.end_line != null or request.all)) return InspectError.IncompatibleBounds;
    if (request.skip != null and request.start_line != null) return InspectError.IncompatibleBounds;
    if (request.range) |range| {
        const separator = std.mem.indexOfScalar(u8, range, ':') orelse return InspectError.InvalidRange;
        const start = std.fmt.parseInt(usize, range[0..separator], 10) catch return InspectError.InvalidRange;
        const end = std.fmt.parseInt(usize, range[separator + 1 ..], 10) catch return InspectError.InvalidRange;
        if (start == 0 or end < start) return InspectError.InvalidRange;
        return .{ .start_line = start, .end_line = end, .skip = 0, .limit = null, .allow_full = false };
    }
    if (request.total_count) |total| {
        if (total == 0) return InspectError.InvalidRange;
        return .{ .start_line = 1, .end_line = null, .skip = 0, .limit = total, .allow_full = false };
    }
    const skip = request.skip orelse 0;
    const start = request.start_line orelse skip + 1;
    if (start == 0) return InspectError.InvalidRange;
    if (request.end_line) |end_line| {
        if (end_line == 0 or start > end_line) return InspectError.InvalidRange;
    }
    if (request.limit) |limit| {
        if (limit == 0) return InspectError.InvalidRange;
    }
    return .{
        .start_line = start,
        .end_line = request.end_line,
        .skip = skip,
        .limit = if (request.limit != null or request.end_line != null or request.all) request.limit else 240,
        .allow_full = request.all,
    };
}

fn requestLabel(allocator: std.mem.Allocator, bounds: Bounds) ![]const u8 {
    if (bounds.end_line) |end_line| {
        return try std.fmt.allocPrint(allocator, "{}:{}", .{ bounds.start_line, end_line });
    }
    if (bounds.limit) |limit| {
        return try std.fmt.allocPrint(allocator, "{}:+{}", .{ bounds.start_line, limit });
    }
    return try std.fmt.allocPrint(allocator, "{}:*", .{bounds.start_line});
}

test "inspect context materializes from search hits across roots" {
    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    try tmp.dir.writeFile(io, .{ .sub_path = "a.txt", .data = "before\nneedle\ninside\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "b.txt", .data = "alpha\nneedle\nomega\n" });
    const root_path = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}", .{&tmp.sub_path});
    const path_a = try std.fs.path.join(allocator, &.{ root_path, "a.txt" });
    const path_b = try std.fs.path.join(allocator, &.{ root_path, "b.txt" });

    var report = search.SearchReport{
        .expression = "lit:needle",
        .cwd = ".",
        .input_roots = 1,
        .effective_roots = 1,
        .pruned_roots = 0,
        .overlap_pruned_roots = 0,
        .discovered_duplicate_paths = 0,
        .collect_hits = true,
        .stats = .{},
        .bytes_scanned = 0,
        .files_discovered = 2,
        .files_scanned = 2,
        .files_skipped = 0,
        .matches_found = 2,
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
        .matcher_strategy_supported = true,
        .outer_parallel_shard_safe = true,
        .uses_single_literal_counter = true,
        .fast_count_range_overlap = null,
        .available_threads = 1,
        .outer_scan_threads = 1,
        .hits = undefined,
        .hit_count = 2,
    };
    report.hits[0] = .{ .path = path_a, .line = 2, .column = 1, .preview = "needle" };
    report.hits[1] = .{ .path = path_b, .line = 2, .column = 1, .preview = "needle" };

    var request = cli.InspectRequest{
        .paths = undefined,
        .path_count = 1,
        .expression = "lit:needle",
        .range = null,
        .start_line = null,
        .end_line = null,
        .limit = null,
        .total_count = null,
        .skip = null,
        .all = false,
        .context = 1,
        .before_context = null,
        .after_context = null,
        .hidden = false,
        .follow_symlinks = false,
        .threads = null,
        .max_hits = null,
        .json = true,
        .format = .json,
    };
    request.paths[0] = root_path;

    const reports = try contextReportsFromSearchReport(io, allocator, request, report);
    try std.testing.expectEqual(@as(usize, 2), reports.len);
    try std.testing.expectEqual(@as(usize, 3), reports[0].line_count);
    try std.testing.expectEqual(@as(usize, 3), reports[1].line_count);
    try std.testing.expectEqualStrings("match", reports[0].lines[1].role);
    try std.testing.expectEqualStrings("match", reports[1].lines[1].role);

    request.total_count = 4;
    const bounded = try contextReportsFromSearchReport(io, allocator, request, report);
    var bounded_lines: usize = 0;
    for (bounded) |context_report| bounded_lines += context_report.line_count;
    try std.testing.expectEqual(@as(usize, 4), bounded_lines);

    const cache = try cacheContextForSearchReport(io, allocator, request, report);
    const first_page = try contextReportsFromCache(allocator, cache, 1);
    try std.testing.expectEqual(@as(usize, 1), first_page.len);
    try std.testing.expectEqual(@as(usize, 3), first_page[0].line_count);
    const full_page = try contextReportsFromCache(allocator, cache, 2);
    try std.testing.expectEqual(@as(usize, 2), full_page.len);
}

test "context cache rejects non-canonical hit order" {
    const hits = [_]search.SearchHit{
        .{ .path = "b.zig", .line = 1, .column = 1, .preview = "b" },
        .{ .path = "a.zig", .line = 1, .column = 1, .preview = "a" },
    };
    try std.testing.expect(!hasCanonicalHitOrder(&hits));
}
