const std = @import("std");
const builtin = @import("builtin");

// Windows stdlib path canonicalization routes through RtlGetFullPathName_U,
// which takes the process-global PEB lock. At high scan fanout that serializes
// opens. This owner constructs \??\ NT object paths once per open so NtCreateFile
// receives an absolute object-manager path without the canonicalization lock.

/// NT CWD prefix: \??\E:\path\to\cwd\ (backslash-terminated UTF-8).
/// Resolved once on the main thread, read-only during parallel scan.
var nt_cwd_prefix: [1024]u8 = undefined;
var nt_cwd_prefix_len: usize = 0;

fn ntPathPrefix(display_path: []const u8) []const u8 {
    const nt_hdr = "\\??\\";
    const is_abs = display_path.len >= 2 and display_path[1] == ':' and
        ((display_path[0] >= 'A' and display_path[0] <= 'Z') or
            (display_path[0] >= 'a' and display_path[0] <= 'z'));
    return if (is_abs) nt_hdr else nt_cwd_prefix[0..nt_cwd_prefix_len];
}

fn writeNtPath(prefix: []const u8, display_path: []const u8, out: []u8) ?[]const u8 {
    const total_len = prefix.len + display_path.len;
    if (total_len > out.len) return null;

    @memcpy(out[0..prefix.len], prefix);
    var write_pos: usize = prefix.len;
    var previous_was_separator = write_pos > 0 and out[write_pos - 1] == '\\';
    for (display_path) |byte| {
        const normalized: u8 = if (byte == '/') '\\' else byte;
        if (normalized == '\\' and previous_was_separator) continue;
        out[write_pos] = normalized;
        write_pos += 1;
        previous_was_separator = normalized == '\\';
    }
    return out[0..write_pos];
}

/// Resolves CWD into an NT object path prefix.
pub fn initCwdPrefix(io: std.Io) void {
    if (comptime builtin.os.tag != .windows) return;
    const nt_hdr = "\\??\\";
    @memcpy(nt_cwd_prefix[0..nt_hdr.len], nt_hdr);
    const cwd_len = std.process.currentPath(io, nt_cwd_prefix[nt_hdr.len .. nt_cwd_prefix.len - 1]) catch return;
    var total = nt_hdr.len + cwd_len;
    for (nt_cwd_prefix[nt_hdr.len..total]) |*b| {
        if (b.* == '/') b.* = '\\';
    }
    if (total == 0 or nt_cwd_prefix[total - 1] != '\\') {
        nt_cwd_prefix[total] = '\\';
        total += 1;
    }
    nt_cwd_prefix_len = total;
}

/// Opens a file through the NT object namespace on Windows to avoid the
/// RtlGetFullPathName_U PEB lock taken by standard path canonicalization.
pub inline fn openFile(io: std.Io, display_path: []const u8) !std.Io.File {
    if (comptime builtin.os.tag != .windows)
        return std.Io.Dir.cwd().openFile(io, display_path, .{ .allow_directory = false });
    if (nt_cwd_prefix_len == 0)
        return std.Io.Dir.cwd().openFile(io, display_path, .{ .allow_directory = false });

    var nt_buf: [1280]u8 = undefined;
    const prefix = ntPathPrefix(display_path);
    const nt_path = writeNtPath(prefix, display_path, &nt_buf) orelse
        return std.Io.Dir.cwd().openFile(io, display_path, .{ .allow_directory = false });
    return std.Io.Dir.cwd().openFile(io, nt_path, .{ .allow_directory = false });
}

test "writeNtPath normalizes only the display path payload" {
    var out: [128]u8 = undefined;
    const prefix = "\\??\\C:\\repo\\";
    const encoded = writeNtPath(prefix, "src/core//search.zig", &out) orelse return error.TestExpectedPath;
    try std.testing.expectEqualStrings("\\??\\C:\\repo\\src\\core\\search.zig", encoded);
}

test "writeNtPath keeps absolute drive paths rooted at nt header" {
    var out: [128]u8 = undefined;
    const encoded = writeNtPath("\\??\\", "E:/Workspaces//ix-zig/src/core/search.zig", &out) orelse return error.TestExpectedPath;
    try std.testing.expectEqualStrings("\\??\\E:\\Workspaces\\ix-zig\\src\\core\\search.zig", encoded);
}
