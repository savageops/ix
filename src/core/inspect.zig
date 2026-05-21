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
    lines: [MAX_WINDOW_LINES]InspectLine,
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
    lines: [MAX_CONTEXT_LINES]ContextLine,
    line_count: usize,
};

pub fn window(io: std.Io, allocator: std.mem.Allocator, request: cli.InspectRequest) !InspectWindow {
    if (request.path_count == 0) return InspectError.MissingTarget;
    return windowForPath(io, allocator, request, request.paths[0]);
}

pub fn windowForPath(io: std.Io, allocator: std.mem.Allocator, request: cli.InspectRequest, path: []const u8) !InspectWindow {
    const bounds = try resolveBounds(request);
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
        .lines = undefined,
        .line_count = 0,
    };

    const file = try std.Io.Dir.cwd().openFile(io, path, .{ .allow_directory = false });
    defer file.close(io);
    var read_buffer: [8192]u8 = undefined;
    var reader = file.reader(io, &read_buffer);
    const bytes = try reader.interface.allocRemaining(allocator, .limited(1024 * 1024 * 1024));

    var line_number: usize = 1;
    var cursor: usize = 0;
    while (cursor < bytes.len) : (line_number += 1) {
        const newline_offset = std.mem.indexOfScalar(u8, bytes[cursor..], '\n');
        const end = if (newline_offset) |offset| cursor + offset else bytes.len;
        const raw_line = bytes[cursor..end];
        cursor = if (newline_offset != null) end + 1 else bytes.len;
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
        output.lines[output.line_count] = .{ .number = line_number, .text = line };
        output.line_count += 1;
        output.end_line = line_number;
    }
    if (output.eof) output.total_lines = if (bytes.len == 0) 0 else line_number - 1;
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

    var hit_index: usize = 0;
    while (hit_index < search_report.hit_count) {
        const path = search_report.hits[hit_index].path;
        const start = hit_index;
        hit_index += 1;
        while (hit_index < search_report.hit_count and std.mem.eql(u8, search_report.hits[hit_index].path, path)) : (hit_index += 1) {}

        try reports.append(allocator, try contextForSearchHitsPath(
            io,
            allocator,
            request,
            search_report.expression,
            path,
            search_report.hits[start..hit_index],
        ));
    }

    return reports.toOwnedSlice(allocator);
}

pub fn contextForPath(io: std.Io, allocator: std.mem.Allocator, request: cli.InspectRequest, path: []const u8, plan: expr.ExpressionPlan) !ContextReport {
    var report = ContextReport{
        .path = try normalizeDisplayPath(allocator, path),
        .expression = request.expression orelse plan.source,
        .lines = undefined,
        .line_count = 0,
    };

    const file = try std.Io.Dir.cwd().openFile(io, path, .{ .allow_directory = false });
    defer file.close(io);
    var read_buffer: [8192]u8 = undefined;
    var reader = file.reader(io, &read_buffer);
    const bytes = try reader.interface.allocRemaining(allocator, .limited(1024 * 1024 * 1024));

    var source_lines: [MAX_CONTEXT_LINES][]const u8 = undefined;
    var match_lines: [MAX_CONTEXT_LINES]bool = undefined;
    var emitted_lines: [MAX_CONTEXT_LINES]bool = undefined;
    var source_count: usize = 0;
    var split = std.mem.splitScalar(u8, bytes, '\n');
    while (split.next()) |raw_line| {
        if (source_count >= MAX_CONTEXT_LINES) break;
        const line = std.mem.trimEnd(u8, raw_line, "\r");
        source_lines[source_count] = line;
        match_lines[source_count] = search.matchesLine(line, plan);
        emitted_lines[source_count] = false;
        source_count += 1;
    }

    const before = request.before_context orelse request.context orelse 0;
    const after = request.after_context orelse request.context orelse 0;
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
            if (report.line_count >= MAX_CONTEXT_LINES) return report;
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
) !ContextReport {
    var report = ContextReport{
        .path = try normalizeDisplayPath(allocator, path),
        .expression = request.expression orelse expression,
        .lines = undefined,
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
    const bytes = try reader.interface.allocRemaining(allocator, .limited(1024 * 1024 * 1024));

    var cursor: usize = 0;
    var line_number: usize = 1;
    var next_hit_index: usize = 0;
    var last_emitted: usize = 0;
    while (cursor < bytes.len and line_number <= last_needed) : (line_number += 1) {
        const newline_offset = std.mem.indexOfScalar(u8, bytes[cursor..], '\n');
        const end = if (newline_offset) |offset| cursor + offset else bytes.len;
        const raw_line = bytes[cursor..end];
        cursor = if (newline_offset != null) end + 1 else bytes.len;

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
            .text = std.mem.trimEnd(u8, raw_line, "\r"),
        };
        report.line_count += 1;
        last_emitted = line_number;
        if (report.line_count >= MAX_CONTEXT_LINES) return report;
    }
    return report;
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
}
