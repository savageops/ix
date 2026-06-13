const std = @import("std");
const core_stats = @import("stats.zig");

pub const DiscoveredFile = struct {
    path: []const u8,
};

pub const DiscoveryShardReport = struct {
    file_list: FileList,
    files_discovered: usize = 0,
    files_skipped: usize = 0,
    access_errors: core_stats.AccessErrorStats = .{},
    had_error: bool = false,
};

/// Growable list of discovered files. Uses a flat array with doubling growth.
pub const FileList = struct {
    buffer: ?[*]DiscoveredFile,
    len: usize,
    capacity: usize,

    pub const empty: FileList = .{ .buffer = null, .len = 0, .capacity = 0 };

    pub fn initWithCapacity(allocator: std.mem.Allocator, cap: usize) !FileList {
        const buf = try allocator.alloc(DiscoveredFile, cap);
        return .{ .buffer = buf.ptr, .len = 0, .capacity = cap };
    }

    pub fn append(self: *FileList, allocator: std.mem.Allocator, entry: DiscoveredFile) !void {
        if (self.len == self.capacity) {
            const new_cap = if (self.capacity == 0) 64 else self.capacity * 2;
            const new_buf = try allocator.alloc(DiscoveredFile, new_cap);
            if (self.buffer) |old| {
                @memcpy(new_buf[0..self.len], old[0..self.len]);
                allocator.free(old[0..self.capacity]);
            }
            self.buffer = new_buf.ptr;
            self.capacity = new_cap;
        }
        self.buffer.?[self.len] = entry;
        self.len += 1;
    }

    pub fn deinit(self: *FileList, allocator: std.mem.Allocator) void {
        if (self.buffer) |buf| allocator.free(buf[0..self.capacity]);
        self.* = empty;
    }

    pub fn items(self: *const FileList) []const DiscoveredFile {
        if (self.buffer) |buf| return buf[0..self.len];
        return &[_]DiscoveredFile{};
    }

    pub fn mutableItems(self: *FileList) []DiscoveredFile {
        if (self.buffer) |buf| return buf[0..self.len];
        return &[_]DiscoveredFile{};
    }
};

pub fn normalizeDisplayPath(allocator: std.mem.Allocator, path: []const u8) ![]const u8 {
    const normalized = try allocator.dupe(u8, path);
    for (normalized) |*byte| {
        if (byte.* == '\\') byte.* = '/';
    }
    return normalized;
}

pub fn joinPathForward(allocator: std.mem.Allocator, parent: []const u8, child: []const u8) ![]const u8 {
    if (parent.len == 0 or std.mem.eql(u8, parent, ".")) return normalizeDisplayPath(allocator, child);
    const buf = try allocator.alloc(u8, parent.len + 1 + child.len);
    @memcpy(buf[0..parent.len], parent);
    buf[parent.len] = '/';
    @memcpy(buf[parent.len + 1 ..][0..child.len], child);
    return buf;
}

pub fn joinPathForwardBounded(left: []const u8, right: []const u8, out: []u8) ?[]const u8 {
    if (left.len == 0 or std.mem.eql(u8, left, ".")) {
        if (right.len > out.len) return null;
        for (right, 0..) |byte, index| out[index] = if (byte == '\\') '/' else byte;
        return out[0..right.len];
    }

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

test "file list grows and preserves discovered order" {
    var list = try FileList.initWithCapacity(std.testing.allocator, 1);
    defer list.deinit(std.testing.allocator);

    try list.append(std.testing.allocator, .{ .path = "a" });
    try list.append(std.testing.allocator, .{ .path = "b" });

    const items = list.items();
    try std.testing.expectEqual(@as(usize, 2), items.len);
    try std.testing.expectEqualStrings("a", items[0].path);
    try std.testing.expectEqualStrings("b", items[1].path);
}

test "bounded forward join normalizes dot root and backslashes" {
    const joined_alloc = try joinPathForward(std.testing.allocator, ".", "packages\\shared\\src\\index.ts");
    defer std.testing.allocator.free(joined_alloc);
    try std.testing.expectEqualStrings("packages/shared/src/index.ts", joined_alloc);

    var buffer: [64]u8 = undefined;
    const joined = joinPathForwardBounded(".", "apps\\backend", &buffer) orelse return error.TestExpectedJoin;
    try std.testing.expectEqualStrings("apps/backend", joined);
}
