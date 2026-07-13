const std = @import("std");

/// Exact byte span of the canonical match inside the source line.
pub const MatchSpan = struct {
    start: usize,
    end: usize,
};

/// A compact preview plus the source window required to interpret it exactly.
pub const Preview = struct {
    text: []const u8,
    source_start: usize,
    source_end: usize,
    elided_left: bool,
    elided_right: bool,
};

const T0_MAX: usize = 300;
const T1_MAX: usize = 600;
const T2_MAX: usize = 1200;
const HALF_WIDTH_T1: usize = 150;
const HALF_WIDTH_T2: usize = 75;
const HALF_WIDTH_T3: usize = 37;
const ELLIPSIS = "…";

/// Produces a UTF-8-safe Furnas fisheye preview without cutting the exact match.
/// Invalid UTF-8 input remains byte-addressable and uses byte-safe boundaries.
pub fn make(allocator: std.mem.Allocator, line: []const u8, raw_span: MatchSpan) !Preview {
    const span = MatchSpan{
        .start = @min(raw_span.start, line.len),
        .end = @min(@max(raw_span.start, raw_span.end), line.len),
    };
    if (line.len <= T0_MAX) {
        return .{
            .text = try allocator.dupe(u8, line),
            .source_start = 0,
            .source_end = line.len,
            .elided_left = false,
            .elided_right = false,
        };
    }

    const half_width = halfWidth(line.len);
    var source_start = span.start -| half_width;
    var source_end = @min(line.len, span.end +| half_width);
    if (source_end <= source_start) source_end = @min(line.len, source_start + 1);

    if (std.unicode.utf8ValidateSlice(line)) {
        source_start = nextCodepointBoundary(line, source_start);
        source_end = previousCodepointBoundary(line, source_end);
        if (source_start > span.start) source_start = previousCodepointBoundary(line, span.start);
        if (source_end < span.end) source_end = nextCodepointBoundary(line, span.end);
    }

    const elided_left = source_start > 0;
    const elided_right = source_end < line.len;
    const result_len = (source_end - source_start) +
        (if (elided_left) ELLIPSIS.len else 0) +
        (if (elided_right) ELLIPSIS.len else 0);
    const result = try allocator.alloc(u8, result_len);
    var cursor: usize = 0;
    if (elided_left) {
        @memcpy(result[cursor..][0..ELLIPSIS.len], ELLIPSIS);
        cursor += ELLIPSIS.len;
    }
    @memcpy(result[cursor..][0 .. source_end - source_start], line[source_start..source_end]);
    cursor += source_end - source_start;
    if (elided_right) @memcpy(result[cursor..][0..ELLIPSIS.len], ELLIPSIS);

    return .{
        .text = result,
        .source_start = source_start,
        .source_end = source_end,
        .elided_left = elided_left,
        .elided_right = elided_right,
    };
}

/// Selects the geometric context radius for the source-line length tier.
fn halfWidth(line_len: usize) usize {
    if (line_len <= T0_MAX) return line_len;
    if (line_len <= T1_MAX) return HALF_WIDTH_T1;
    if (line_len <= T2_MAX) return HALF_WIDTH_T2;
    return HALF_WIDTH_T3;
}

/// Moves a candidate cut forward until it begins at a UTF-8 codepoint boundary.
fn nextCodepointBoundary(bytes: []const u8, candidate: usize) usize {
    var index = @min(candidate, bytes.len);
    while (index < bytes.len and isContinuation(bytes[index])) : (index += 1) {}
    return index;
}

/// Moves a candidate cut backward until it ends at a UTF-8 codepoint boundary.
fn previousCodepointBoundary(bytes: []const u8, candidate: usize) usize {
    var index = @min(candidate, bytes.len);
    while (index > 0 and index < bytes.len and isContinuation(bytes[index])) : (index -= 1) {}
    return index;
}

/// Identifies UTF-8 continuation bytes without decoding the source line.
fn isContinuation(byte: u8) bool {
    return byte & 0b1100_0000 == 0b1000_0000;
}

test "preview keeps short lines exact" {
    const result = try make(std.testing.allocator, "prefix needle suffix", .{ .start = 7, .end = 13 });
    defer std.testing.allocator.free(result.text);
    try std.testing.expectEqualStrings("prefix needle suffix", result.text);
    try std.testing.expect(!result.elided_left and !result.elided_right);
}

test "preview preserves a match wider than its context radius" {
    const line = "a" ** 400 ++ "MATCH-WIDER-THAN-THE-RADIUS" ++ "z" ** 400;
    const start = 400;
    const result = try make(std.testing.allocator, line, .{ .start = start, .end = start + "MATCH-WIDER-THAN-THE-RADIUS".len });
    defer std.testing.allocator.free(result.text);
    try std.testing.expect(std.mem.indexOf(u8, result.text, "MATCH-WIDER-THAN-THE-RADIUS") != null);
    try std.testing.expect(result.source_start <= start);
    try std.testing.expect(result.source_end >= start + "MATCH-WIDER-THAN-THE-RADIUS".len);
}

test "preview never cuts a multibyte codepoint" {
    const line = "é" ** 200 ++ "needle" ++ "界" ** 200;
    const start = ("é" ** 200).len;
    const result = try make(std.testing.allocator, line, .{ .start = start, .end = start + 6 });
    defer std.testing.allocator.free(result.text);
    try std.testing.expect(std.unicode.utf8ValidateSlice(result.text));
    try std.testing.expect(std.mem.indexOf(u8, result.text, "needle") != null);
}

test "preview tier boundary keeps 300 bytes and contracts 301" {
    const exact = "x" ** 300;
    const full = try make(std.testing.allocator, exact, .{ .start = 150, .end = 151 });
    defer std.testing.allocator.free(full.text);
    try std.testing.expectEqual(@as(usize, 300), full.text.len);

    const contracted = "x" ** 301;
    const compact = try make(std.testing.allocator, contracted, .{ .start = 20, .end = 21 });
    defer std.testing.allocator.free(compact.text);
    try std.testing.expect(compact.elided_right or compact.elided_left);
}
