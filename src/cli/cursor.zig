const std = @import("std");
const cli = @import("args.zig");

pub const Cursor = struct {
    corpus_signature: u64,
    request_fingerprint: u64,
    path: []const u8,
    line: usize,
    column: usize,
};

pub const CursorError = error{
    InvalidCursor,
};

/// Encodes a restart key and the two identities required to reject stale traversal.
pub fn encode(allocator: std.mem.Allocator, value: Cursor) ![]const u8 {
    const path_hex = try allocator.alloc(u8, value.path.len * 2);
    defer allocator.free(path_hex);
    for (value.path, 0..) |byte, index| {
        path_hex[index * 2] = hexDigit(byte >> 4);
        path_hex[index * 2 + 1] = hexDigit(byte & 0x0f);
    }
    return std.fmt.allocPrint(allocator, "ixc1.{x}.{x}.{}.{}.{s}", .{
        value.corpus_signature,
        value.request_fingerprint,
        value.line,
        value.column,
        path_hex,
    });
}

/// Decodes the opaque cursor without accepting partial or trailing fields.
pub fn decode(allocator: std.mem.Allocator, raw: []const u8) CursorError!Cursor {
    var fields = std.mem.splitScalar(u8, raw, '.');
    if (!std.mem.eql(u8, fields.next() orelse return error.InvalidCursor, "ixc1")) return error.InvalidCursor;
    const corpus_signature = std.fmt.parseInt(u64, fields.next() orelse return error.InvalidCursor, 16) catch return error.InvalidCursor;
    const request_fingerprint = std.fmt.parseInt(u64, fields.next() orelse return error.InvalidCursor, 16) catch return error.InvalidCursor;
    const line = std.fmt.parseInt(usize, fields.next() orelse return error.InvalidCursor, 10) catch return error.InvalidCursor;
    const column = std.fmt.parseInt(usize, fields.next() orelse return error.InvalidCursor, 10) catch return error.InvalidCursor;
    const path_hex = fields.next() orelse return error.InvalidCursor;
    if (fields.next() != null or path_hex.len == 0 or path_hex.len % 2 != 0 or line == 0 or column == 0) return error.InvalidCursor;
    const path = allocator.alloc(u8, path_hex.len / 2) catch return error.InvalidCursor;
    errdefer allocator.free(path);
    for (path, 0..) |*byte, index| {
        const high = hexValue(path_hex[index * 2]) orelse return error.InvalidCursor;
        const low = hexValue(path_hex[index * 2 + 1]) orelse return error.InvalidCursor;
        byte.* = (high << 4) | low;
    }
    return .{
        .corpus_signature = corpus_signature,
        .request_fingerprint = request_fingerprint,
        .path = path,
        .line = line,
        .column = column,
    };
}

/// Fingerprints every request dimension that can change membership or canonical ordering.
pub fn requestFingerprint(request: cli.SearchRequest) u64 {
    var hasher = std.hash.Wyhash.init(0x4958_4355_5253_4f52);
    hasher.update(request.expression);
    for (request.paths[0..request.path_count]) |path| hasher.update(path);
    hashBool(&hasher, request.hidden);
    hashBool(&hasher, request.follow_symlinks);
    hashBool(&hasher, request.no_ignore);
    hashBool(&hasher, request.case_insensitive);
    hashBool(&hasher, request.fixed_strings);
    for (request.ignore_files[0..request.ignore_file_count]) |path| hasher.update(path);
    return hasher.final();
}

/// Fingerprints semantic membership and frontier ordering independently from presentation.
pub fn similarRequestFingerprint(request: cli.SimilarRequest) u64 {
    var hasher = std.hash.Wyhash.init(0x4958_5349_4d49_4c41);
    if (request.query) |query| hasher.update(query);
    for (request.paths[0..request.path_count]) |path| hasher.update(path);
    hasher.update(std.mem.asBytes(&request.candidate_budget));
    return hasher.final();
}

/// Orders restart keys by the public path, line, then column contract.
pub fn keyAfter(path: []const u8, line: usize, column: usize, after: Cursor) bool {
    const path_order = std.mem.order(u8, path, after.path);
    if (path_order == .gt) return true;
    if (path_order == .lt) return false;
    if (line != after.line) return line > after.line;
    return column > after.column;
}

/// Feeds one boolean into a stable request fingerprint.
fn hashBool(hasher: *std.hash.Wyhash, value: bool) void {
    hasher.update(if (value) &[_]u8{1} else &[_]u8{0});
}

/// Maps one nibble to the lowercase cursor alphabet.
fn hexDigit(value: u8) u8 {
    return if (value < 10) '0' + value else 'a' + value - 10;
}

/// Decodes one cursor-alphabet nibble.
fn hexValue(byte: u8) ?u8 {
    return switch (byte) {
        '0'...'9' => byte - '0',
        'a'...'f' => byte - 'a' + 10,
        'A'...'F' => byte - 'A' + 10,
        else => null,
    };
}

test "cursor round trips delimiter and unicode paths" {
    const raw = try encode(std.testing.allocator, .{
        .corpus_signature = 0xabc,
        .request_fingerprint = 0xdef,
        .path = "src/a.b/界.zig",
        .line = 42,
        .column = 7,
    });
    defer std.testing.allocator.free(raw);
    const parsed = try decode(std.testing.allocator, raw);
    defer std.testing.allocator.free(parsed.path);
    try std.testing.expectEqual(@as(u64, 0xabc), parsed.corpus_signature);
    try std.testing.expectEqualStrings("src/a.b/界.zig", parsed.path);
    try std.testing.expectEqual(@as(usize, 42), parsed.line);
}

test "cursor rejects malformed and zero-coordinate input" {
    try std.testing.expectError(error.InvalidCursor, decode(std.testing.allocator, "ixc1.1.2.0.1.aa"));
    try std.testing.expectError(error.InvalidCursor, decode(std.testing.allocator, "ixc1.1.2.1.1.zz"));
    try std.testing.expectError(error.InvalidCursor, decode(std.testing.allocator, "ixc2.1.2.1.1.aa"));
}
