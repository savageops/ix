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

    const nt_hdr: []const u8 = "\\??\\";
    const is_abs = display_path.len >= 2 and display_path[1] == ':' and
        ((display_path[0] >= 'A' and display_path[0] <= 'Z') or
            (display_path[0] >= 'a' and display_path[0] <= 'z'));
    const prefix = if (is_abs) nt_hdr else nt_cwd_prefix[0..nt_cwd_prefix_len];
    const total_len = prefix.len + display_path.len;

    var nt_buf: [1280]u8 = undefined;
    if (total_len > nt_buf.len)
        return std.Io.Dir.cwd().openFile(io, display_path, .{ .allow_directory = false });

    @memcpy(nt_buf[0..prefix.len], prefix);
    @memcpy(nt_buf[prefix.len..][0..display_path.len], display_path);
    var write_pos: usize = 0;
    for (nt_buf[0..total_len]) |b| {
        const c = if (b == '/') @as(u8, '\\') else b;
        if (write_pos > 0 and c == '\\' and nt_buf[write_pos - 1] == '\\') continue;
        nt_buf[write_pos] = c;
        write_pos += 1;
    }
    return std.Io.Dir.cwd().openFile(io, nt_buf[0..write_pos], .{ .allow_directory = false });
}
