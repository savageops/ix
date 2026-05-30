const std = @import("std");
const builtin = @import("builtin");
const catalog = @import("catalog.zig");

pub const STATE_ENV = "IX_STATE_DIR";

pub const RootIndexState = struct {
    state_dir: []const u8,
    index_dir: []const u8,

    pub fn deinit(self: RootIndexState, allocator: std.mem.Allocator) void {
        allocator.free(self.index_dir);
        allocator.free(self.state_dir);
    }
};

pub fn resolveStateDir(allocator: std.mem.Allocator) ![]const u8 {
    if (getenvOwned(allocator, STATE_ENV)) |override| return override;

    if (builtinStateBase(allocator)) |base| {
        defer allocator.free(base);
        return std.fs.path.join(allocator, &.{ base, "iEx", "ix" });
    } else |_| {}

    return std.fs.path.join(allocator, &.{ ".ix-state" });
}

pub fn buildRootIndexState(allocator: std.mem.Allocator, root_fingerprint: catalog.RootFingerprint) !RootIndexState {
    const state_dir = try resolveStateDir(allocator);
    errdefer allocator.free(state_dir);
    const root_dir = try rootFingerprintDirName(allocator, root_fingerprint);
    defer allocator.free(root_dir);
    const index_dir = try std.fs.path.join(allocator, &.{ state_dir, "index", "roots", root_dir });
    return .{
        .state_dir = state_dir,
        .index_dir = index_dir,
    };
}

pub fn queryDir(allocator: std.mem.Allocator, index_dir: []const u8) ![]const u8 {
    return std.fs.path.join(allocator, &.{ index_dir, "query" });
}

pub fn statsDir(allocator: std.mem.Allocator) ![]const u8 {
    const state_dir = try resolveStateDir(allocator);
    defer allocator.free(state_dir);
    return std.fs.path.join(allocator, &.{ state_dir, "cache", "stats" });
}

pub fn evidenceCachePath(allocator: std.mem.Allocator, key: u64) ![]const u8 {
    const state_dir = try resolveStateDir(allocator);
    defer allocator.free(state_dir);
    const file_name = try std.fmt.allocPrint(allocator, "{x}.cache", .{key});
    defer allocator.free(file_name);
    return std.fs.path.join(allocator, &.{ state_dir, "cache", "evidence", file_name });
}

pub fn rootFingerprintDirName(allocator: std.mem.Allocator, root_fingerprint: catalog.RootFingerprint) ![]const u8 {
    return std.fmt.allocPrint(allocator, "{x:0>32}", .{root_fingerprint});
}

fn builtinStateBase(allocator: std.mem.Allocator) ![]const u8 {
    if (builtin.os.tag == .windows) {
        if (getenvOwned(allocator, "LOCALAPPDATA")) |value| return value;
        if (getenvOwned(allocator, "APPDATA")) |value| return value;
    }
    if (getenvOwned(allocator, "XDG_STATE_HOME")) |value| return value;
    if (getenvOwned(allocator, "HOME")) |home| {
        defer allocator.free(home);
        return std.fs.path.join(allocator, &.{ home, ".local", "state" });
    }
    return error.NoStateBase;
}

fn getenvOwned(allocator: std.mem.Allocator, comptime name: []const u8) ?[]const u8 {
    const value_ptr = std.c.getenv(name ++ "\x00") orelse return null;
    const value = std.mem.span(value_ptr);
    if (value.len == 0) return null;
    return allocator.dupe(u8, value) catch null;
}

test "root index state partitions by fingerprint outside scanned-root .ix" {
    const allocator = std.testing.allocator;

    const state = try buildRootIndexState(allocator, 0x1234);
    defer state.deinit(allocator);

    try std.testing.expect(std.mem.indexOf(u8, state.index_dir, ".ix/index") == null);
    try std.testing.expect(std.mem.endsWith(u8, state.index_dir, "00000000000000000000000000001234"));
}

test "cache paths live under IX-owned state directory" {
    const allocator = std.testing.allocator;

    const stats = try statsDir(allocator);
    defer allocator.free(stats);
    const evidence = try evidenceCachePath(allocator, 0xfeed);
    defer allocator.free(evidence);

    try std.testing.expect(std.mem.indexOf(u8, stats, "cache") != null);
    try std.testing.expect(std.mem.indexOf(u8, evidence, "cache") != null);
    try std.testing.expect(std.mem.endsWith(u8, evidence, "feed.cache"));
}
