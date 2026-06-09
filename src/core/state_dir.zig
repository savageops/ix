const std = @import("std");
const builtin = @import("builtin");
const catalog = @import("catalog.zig");
const windows = std.os.windows;

const WindowsApi = if (builtin.os.tag == .windows) struct {
    extern "kernel32" fn GetModuleFileNameW(
        hModule: ?windows.HMODULE,
        lpFilename: [*]u16,
        nSize: windows.DWORD,
    ) callconv(.winapi) windows.DWORD;

    extern "kernel32" fn GetEnvironmentVariableW(
        lpName: windows.LPCWSTR,
        lpBuffer: ?[*]u16,
        nSize: windows.DWORD,
    ) callconv(.winapi) windows.DWORD;
} else struct {};

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

    const local_appdata = if (builtin.os.tag == .windows) getenvOwned(allocator, "LOCALAPPDATA") else null;
    defer if (local_appdata) |value| allocator.free(value);
    const appdata = if (builtin.os.tag == .windows) getenvOwned(allocator, "APPDATA") else null;
    defer if (appdata) |value| allocator.free(value);
    const xdg_state_home = if (builtin.os.tag != .windows) getenvOwned(allocator, "XDG_STATE_HOME") else null;
    defer if (xdg_state_home) |value| allocator.free(value);
    const home = if (builtin.os.tag != .windows) getenvOwned(allocator, "HOME") else null;
    defer if (home) |value| allocator.free(value);

    if (builtin.os.tag == .windows) {
        const exe_path = windowsExecutablePath(allocator) catch null;
        defer if (exe_path) |value| allocator.free(value);
        return resolveDefaultStateDir(allocator, .{
            .exe_path = exe_path,
            .local_appdata = local_appdata,
            .appdata = appdata,
        });
    }

    return resolveDefaultStateDir(allocator, .{
        .xdg_state_home = xdg_state_home,
        .home = home,
    });
}

pub const DefaultStateDirInput = struct {
    exe_path: ?[]const u8 = null,
    local_appdata: ?[]const u8 = null,
    appdata: ?[]const u8 = null,
    xdg_state_home: ?[]const u8 = null,
    home: ?[]const u8 = null,
};

pub fn resolveDefaultStateDir(allocator: std.mem.Allocator, input: DefaultStateDirInput) ![]const u8 {
    if (builtin.os.tag == .windows) {
        if (input.exe_path) |exe_path| {
            if (try windowsStateDirFromExecutablePath(allocator, exe_path, input.local_appdata, input.appdata)) |dir| return dir;
        }
        if (input.local_appdata) |base| return std.fs.path.join(allocator, &.{ base, "iEx", "ix" });
        if (input.appdata) |base| return std.fs.path.join(allocator, &.{ base, "iEx", "ix" });
    } else {
        if (input.xdg_state_home) |base| return std.fs.path.join(allocator, &.{ base, "iEx", "ix" });
        if (input.home) |home| return std.fs.path.join(allocator, &.{ home, ".local", "state", "iEx", "ix" });
    }

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

fn windowsExecutablePath(allocator: std.mem.Allocator) ![]const u8 {
    var buffer: [32768]u16 = undefined;
    const len = WindowsApi.GetModuleFileNameW(null, &buffer, buffer.len);
    if (len == 0 or len == buffer.len) return error.ExecutablePathUnavailable;
    return std.unicode.wtf16LeToWtf8Alloc(allocator, buffer[0..len]);
}

fn windowsStateDirFromExecutablePath(
    allocator: std.mem.Allocator,
    exe_path: []const u8,
    local_appdata: ?[]const u8,
    appdata: ?[]const u8,
) !?[]const u8 {
    const exe_dir = std.fs.path.dirname(exe_path) orelse return null;
    if (pathStartsWithDirectory(exe_dir, local_appdata) or pathStartsWithDirectory(exe_dir, appdata)) {
        const state_dir = try std.fs.path.join(allocator, &.{ exe_dir, ".ix" });
        return state_dir;
    }
    return null;
}

fn pathStartsWithDirectory(path: []const u8, maybe_prefix: ?[]const u8) bool {
    const prefix = maybe_prefix orelse return false;
    if (prefix.len == 0 or path.len < prefix.len) return false;
    if (!std.ascii.eqlIgnoreCase(path[0..prefix.len], prefix)) return false;
    if (path.len == prefix.len) return true;
    return path[prefix.len] == '/' or path[prefix.len] == '\\';
}

fn getenvOwned(allocator: std.mem.Allocator, comptime name: []const u8) ?[]const u8 {
    const value = if (builtin.os.tag == .windows) getenvOwnedWindows(allocator, name) catch return null else getenvOwnedLibc(allocator, name) catch return null;
    if (value.len == 0) {
        allocator.free(value);
        return null;
    }
    return value;
}

fn getenvOwnedWindows(allocator: std.mem.Allocator, comptime name: []const u8) ![]u8 {
    const wide_name = std.unicode.utf8ToUtf16LeStringLiteral(name);
    const required = WindowsApi.GetEnvironmentVariableW(wide_name, null, 0);
    if (required == 0) return error.EnvironmentVariableNotFound;

    const buffer = try allocator.alloc(u16, required);
    defer allocator.free(buffer);
    const written = WindowsApi.GetEnvironmentVariableW(wide_name, buffer.ptr, required);
    if (written == 0 or written >= required) return error.EnvironmentVariableNotFound;
    return std.unicode.utf16LeToUtf8Alloc(allocator, buffer[0..written]);
}

fn getenvOwnedLibc(allocator: std.mem.Allocator, comptime name: []const u8) ![]u8 {
    const value_ptr = std.c.getenv(name ++ "\x00") orelse return error.EnvironmentVariableNotFound;
    const value = std.mem.span(value_ptr);
    return allocator.dupe(u8, value);
}

test "root index state partitions by fingerprint outside scanned-root .ix" {
    const allocator = std.testing.allocator;

    const state = try buildRootIndexState(allocator, 0x1234);
    defer state.deinit(allocator);

    try std.testing.expect(std.mem.indexOf(u8, state.index_dir, ".ix/index") == null);
    try std.testing.expect(std.mem.endsWith(u8, state.index_dir, "00000000000000000000000000001234"));
}

test "IX_STATE_DIR override remains authoritative" {
    const allocator = std.testing.allocator;

    const expected = getenvOwned(allocator, STATE_ENV) orelse return error.SkipZigTest;
    defer allocator.free(expected);
    const state = try buildRootIndexState(allocator, 0xbeef);
    defer state.deinit(allocator);

    try std.testing.expectEqualStrings(expected, state.state_dir);
    try std.testing.expect(std.mem.indexOf(u8, state.index_dir, "roots") != null);
    try std.testing.expect(std.mem.endsWith(u8, state.index_dir, "0000000000000000000000000000beef"));
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

test "Windows state dir anchors to executable directory under AppData" {
    const allocator = std.testing.allocator;

    const state = try resolveDefaultStateDir(allocator, .{
        .exe_path = "C:\\Users\\Savage\\AppData\\Local\\Programs\\iEx\\bin\\ix.exe",
        .local_appdata = "C:\\Users\\Savage\\AppData\\Local",
    });
    defer allocator.free(state);

    try std.testing.expectEqualStrings("C:\\Users\\Savage\\AppData\\Local\\Programs\\iEx\\bin\\.ix", state);
}

test "Windows state dir falls back to AppData owner for repository executable" {
    const allocator = std.testing.allocator;

    const state = try resolveDefaultStateDir(allocator, .{
        .exe_path = "E:\\Workspaces\\01_Projects\\01_Github\\ix-zig\\zig-out\\bin\\ix-zig.exe",
        .local_appdata = "C:\\Users\\Savage\\AppData\\Local",
    });
    defer allocator.free(state);

    try std.testing.expectEqualStrings("C:\\Users\\Savage\\AppData\\Local\\iEx\\ix", state);
    try std.testing.expect(std.mem.indexOf(u8, state, "ix-zig") == null);
    try std.testing.expect(std.mem.indexOf(u8, state, ".ix-state") == null);
}

test "Windows state dir rejects repository executable outside AppData" {
    const state = try windowsStateDirFromExecutablePath(
        std.testing.allocator,
        "E:\\Workspaces\\01_Projects\\01_Github\\ix-zig\\zig-out\\bin\\ix-zig.exe",
        "C:\\Users\\Savage\\AppData\\Local",
        null,
    );
    try std.testing.expect(state == null);
}

test "default state dir does not depend on current working directory" {
    const allocator = std.testing.allocator;

    const first = try resolveDefaultStateDir(allocator, .{
        .exe_path = "E:\\a\\ix-zig.exe",
        .local_appdata = "C:\\Users\\Savage\\AppData\\Local",
    });
    defer allocator.free(first);
    const second = try resolveDefaultStateDir(allocator, .{
        .exe_path = "E:\\b\\ix-zig.exe",
        .local_appdata = "C:\\Users\\Savage\\AppData\\Local",
    });
    defer allocator.free(second);

    try std.testing.expectEqualStrings(first, second);
    try std.testing.expect(std.mem.indexOf(u8, first, ".ix-state") == null);
}
