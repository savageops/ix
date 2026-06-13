const std = @import("std");
const builtin = @import("builtin");

pub const SkipPolicy = struct {
    stats_only: bool = false,
};

pub fn shouldSkipBinaryContainer(policy: SkipPolicy, path: []const u8) bool {
    if (comptime builtin.os.tag != .windows) return false;
    if (!isWindowsPath(path)) return false;
    if (isVolatileSystemStore(path)) return true;
    const ext = pathExtension(path) orelse return false;
    if (!policy.stats_only) return hasBinaryContainerExtension(ext);
    return !hasTextExtension(ext);
}

pub fn isWindowsPath(path: []const u8) bool {
    if (path.len < "C:\\Windows".len) return false;
    if (path[1] != ':') return false;
    const slash = path[2];
    if (slash != '\\' and slash != '/') return false;
    if (!std.ascii.eqlIgnoreCase(path[3..10], "Windows")) return false;
    if (path.len == 10) return true;
    return path[10] == '\\' or path[10] == '/';
}

fn pathExtension(path: []const u8) ?[]const u8 {
    var base_start = path.len;
    while (base_start > 0) {
        base_start -= 1;
        if (path[base_start] == '\\' or path[base_start] == '/') {
            base_start += 1;
            break;
        }
    }
    const name = path[base_start..];
    const dot_index = std.mem.lastIndexOfScalar(u8, name, '.') orelse return null;
    return name[dot_index..];
}

fn hasTextExtension(ext: []const u8) bool {
    const text_extensions = [_][]const u8{
        ".inf",  ".inf_loc", ".mof",     ".man",   ".cdxml", ".ps1xml", ".log",
        ".ini",  ".psd1",    ".xml",     ".psm1",  ".yaml",  ".yml",    ".xsd",
        ".msc",  ".gpd",     ".strings", ".forms", ".rtf",   ".dis",    ".txt",
        ".json", ".xsl",     ".rs",      ".gdl",   ".vbs",   ".table",  ".hlp",
        ".cfg",  ".dic",     ".1",       ".ppd",
    };
    for (text_extensions) |candidate| {
        if (std.ascii.eqlIgnoreCase(ext, candidate)) return true;
    }
    return false;
}

fn isVolatileSystemStore(path: []const u8) bool {
    return containsPathSegmentPairIgnoreCase(path, "System32", "catroot2");
}

fn containsPathSegmentPairIgnoreCase(path: []const u8, first: []const u8, second: []const u8) bool {
    var segments = std.mem.tokenizeAny(u8, path, "\\/");
    var saw_first = false;
    while (segments.next()) |segment| {
        if (!saw_first) {
            saw_first = std.ascii.eqlIgnoreCase(segment, first);
            continue;
        }
        if (std.ascii.eqlIgnoreCase(segment, second)) return true;
        saw_first = std.ascii.eqlIgnoreCase(segment, first);
    }
    return false;
}

fn hasBinaryContainerExtension(ext: []const u8) bool {
    const binary_extensions = [_][]const u8{
        ".dll", ".exe", ".sys", ".mui", ".cat", ".ocx", ".cpl", ".drv",
        ".efi", ".scr", ".msi", ".msp", ".msu", ".cab", ".pnf", ".nls",
        ".ttf", ".ttc", ".otf", ".fon",
    };
    for (binary_extensions) |candidate| {
        if (std.ascii.eqlIgnoreCase(ext, candidate)) return true;
    }
    return false;
}

test "protected Windows stats-only binary container skip stays scoped" {
    var policy: SkipPolicy = .{ .stats_only = true };

    if (builtin.os.tag == .windows) {
        try std.testing.expect(shouldSkipBinaryContainer(policy, "C:\\Windows\\System32\\kernel32.dll"));
        try std.testing.expect(shouldSkipBinaryContainer(policy, "C:/Windows/System32/catroot/example.cat"));
        try std.testing.expect(shouldSkipBinaryContainer(policy, "C:\\Windows\\System32\\en-US\\shell32.dll.mui"));
        try std.testing.expect(shouldSkipBinaryContainer(policy, "C:\\Windows\\System32\\catroot2\\edbtmp.log"));
        try std.testing.expect(!shouldSkipBinaryContainer(policy, "C:\\Windows\\System32\\DriverStore\\sample.inf"));
        try std.testing.expect(!shouldSkipBinaryContainer(policy, "C:\\Windows\\System32\\drivers\\etc\\hosts"));
        try std.testing.expect(!shouldSkipBinaryContainer(policy, "E:\\repo\\fake.dll"));
        policy.stats_only = false;
        try std.testing.expect(shouldSkipBinaryContainer(policy, "C:\\Windows\\System32\\kernel32.dll"));
        try std.testing.expect(shouldSkipBinaryContainer(policy, "C:\\Windows\\System32\\en-US\\shell32.dll.mui"));
        try std.testing.expect(shouldSkipBinaryContainer(policy, "C:\\Windows\\Globalization\\Sorting\\sortdefault.nls"));
        try std.testing.expect(shouldSkipBinaryContainer(policy, "C:\\Windows\\Fonts\\arial.ttf"));
        try std.testing.expect(shouldSkipBinaryContainer(policy, "C:\\Windows\\Fonts\\msgothic.ttc"));
        try std.testing.expect(shouldSkipBinaryContainer(policy, "C:\\Windows\\Fonts\\cascadia.otf"));
        try std.testing.expect(shouldSkipBinaryContainer(policy, "C:\\Windows\\Fonts\\vgaoem.fon"));
        try std.testing.expect(shouldSkipBinaryContainer(policy, "C:\\Windows\\System32\\catroot2\\edbtmp.log"));
        try std.testing.expect(!shouldSkipBinaryContainer(policy, "C:\\Windows\\System32\\DriverStore\\sample.inf"));
        try std.testing.expect(!shouldSkipBinaryContainer(policy, "E:\\repo\\arial.ttf"));
    } else {
        try std.testing.expect(!shouldSkipBinaryContainer(policy, "C:\\Windows\\System32\\kernel32.dll"));
    }
}
