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
