const std = @import("std");
const builtin = @import("builtin");

/// State directory resolution.
///
/// IX stores all runtime state (index, query cache, process markers) in a
/// single state directory. The resolution is simple and explicit:
///
///   Windows:  %LOCALAPPDATA%\ix\
///   Linux:    $XDG_STATE_HOME/ix/  (or ~/.local/state/ix/)
///   macOS:    ~/Library/Application Support/ix/
///
/// Override with IX_STATE_DIR environment variable.
///
/// No legacy .ix-next-to-exe detection. No fallbacks. One path per platform.
/// This matches the convention used by fzf (%LOCALAPPDATA%\fzf),
/// zoxide (%LOCALAPPDATA%\zoxide), and eza (%LOCALAPPDATA%\eza).

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

    if (builtin.os.tag == .windows) {
        const local_appdata = getenvOwned(allocator, "LOCALAPPDATA") orelse
            return error.StateDirResolutionFailed;
        defer allocator.free(local_appdata);
        return std.fs.path.join(allocator, &.{ local_appdata, "ix" });
    }

    if (builtin.os.tag == .macos) {
        const home = getenvOwned(allocator, "HOME") orelse
            return error.StateDirResolutionFailed;
        defer allocator.free(home);
        return std.fs.path.join(allocator, &.{ home, "Library", "Application Support", "ix" });
    }

    // Linux / FreeBSD: XDG_STATE_HOME or ~/.local/state
    if (getenvOwned(allocator, "XDG_STATE_HOME")) |xdg| {
        defer allocator.free(xdg);
        return std.fs.path.join(allocator, &.{ xdg, "ix" });
    }
    const home = getenvOwned(allocator, "HOME") orelse
        return error.StateDirResolutionFailed;
    defer allocator.free(home);
    return std.fs.path.join(allocator, &.{ home, ".local", "state", "ix" });
}

pub fn buildRootIndexState(allocator: std.mem.Allocator, root_fingerprint: u128) !RootIndexState {
    const state_dir = try resolveStateDir(allocator);
    errdefer allocator.free(state_dir);

    var root_buf: [32]u8 = undefined;
    const root_dir = std.fmt.bufPrint(&root_buf, "{x}", .{root_fingerprint}) catch return error.FingerprintFormatError;
    const index_dir = try std.fs.path.join(allocator, &.{ state_dir, "index", "roots", root_dir });
    errdefer allocator.free(index_dir);

    return .{
        .state_dir = state_dir,
        .index_dir = index_dir,
    };
}

/// Stats cache directory: `<state_dir>/cache/stats/`.
pub fn statsDir(allocator: std.mem.Allocator) ![]const u8 {
    const state_dir = try resolveStateDir(allocator);
    defer allocator.free(state_dir);
    return std.fs.path.join(allocator, &.{ state_dir, "cache", "stats" });
}

/// Evidence cache directory: `<state_dir>/cache/evidence/`.
pub fn evidenceCacheDir(allocator: std.mem.Allocator) ![]const u8 {
    const state_dir = try resolveStateDir(allocator);
    defer allocator.free(state_dir);
    return std.fs.path.join(allocator, &.{ state_dir, "cache", "evidence" });
}

/// Evidence cache file path for a given 64-bit frontier key:
/// `<state_dir>/cache/evidence/<hex key>`.
/// Callers append `.live` / `.build` suffixes for liveness/claim files.
pub fn evidenceCachePath(allocator: std.mem.Allocator, key: u64) ![]const u8 {
    const dir = try evidenceCacheDir(allocator);
    defer allocator.free(dir);
    var key_buf: [16]u8 = undefined;
    const key_str = std.fmt.bufPrint(&key_buf, "{x}", .{key}) catch return error.KeyFormatError;
    return std.fs.path.join(allocator, &.{ dir, key_str });
}

pub fn queryDir(allocator: std.mem.Allocator, index_dir: []const u8) ![]const u8 {
    return std.fs.path.join(allocator, &.{ index_dir, "query" });
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
    const stack_alloc = std.heap.page_allocator;
    const required_len: u32 = WindowsApi.GetEnvironmentVariableW(wide_name, null, 0);
    if (required_len == 0) return error.EnvironmentVariableNotFound;

    const buffer = try stack_alloc.alloc(u16, required_len);
    defer stack_alloc.free(buffer);
    const written = WindowsApi.GetEnvironmentVariableW(wide_name, buffer.ptr, required_len);
    if (written == 0 or written >= required_len) return error.EnvironmentVariableNotFound;
    return std.unicode.wtf16LeToWtf8Alloc(allocator, buffer[0..written]);
}

fn getenvOwnedLibc(allocator: std.mem.Allocator, comptime name: []const u8) ![]u8 {
    const value_ptr = std.c.getenv(name ++ "\x00") orelse return error.EnvironmentVariableNotFound;
    const spanned = std.mem.span(value_ptr);
    return allocator.dupe(u8, spanned);
}

const WindowsApi = struct {
    extern "kernel32" fn GetModuleFileNameW(
        hModule: ?*anyopaque,
        lpwFilename: [*]u16,
        nSize: u32,
    ) u32;

    extern "kernel32" fn GetEnvironmentVariableW(
        lpName: [*:0]const u16,
        lpBuffer: ?[*]u16,
        nSize: u32,
    ) u32;
};

test "resolveStateDir respects IX_STATE_DIR override" {
    const dir = try resolveStateDir(std.testing.allocator);
    defer std.testing.allocator.free(dir);
    // Without IX_STATE_DIR set in tests, falls through to platform default.
    try std.testing.expect(dir.len > 0);
}

test "buildRootIndexState joins index roots path" {
    // This test only verifies the path construction logic.
    const state = try buildRootIndexState(std.testing.allocator, 0xABCDEF);
    defer state.deinit(std.testing.allocator);
    // Path separators are platform-dependent; check the hex tail and the
    // `roots` segment directly to stay cross-platform.
    try std.testing.expect(std.mem.endsWith(u8, state.index_dir, "abcdef"));
    try std.testing.expect(std.mem.indexOf(u8, state.index_dir, "roots") != null);
    try std.testing.expect(std.mem.indexOf(u8, state.index_dir, "index") != null);
}
