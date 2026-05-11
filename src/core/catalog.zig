const std = @import("std");

pub const MAGIC: [8]u8 = .{ 'I', 'X', 'C', 'A', 'T', '0', '0', '1' };
pub const FORMAT_VERSION: u16 = 1;
pub const MIN_HEADER_SIZE: usize = @sizeOf(CatalogHeader);
pub const INVALID_FILE_ID: FileId = 0;

pub const FileId = u64;
pub const RootFingerprint = u128;

pub const RootIdentity = struct {
    canonical_path: []const u8,
    fingerprint: RootFingerprint,

    pub fn deinit(self: RootIdentity, allocator: std.mem.Allocator) void {
        allocator.free(self.canonical_path);
    }
};

pub const FileKind = enum(u8) {
    regular = 0,
    symlink = 1,
    other = 2,
};

pub const TextKind = enum(u8) {
    unknown = 0,
    text = 1,
    binary = 2,
};

pub const CatalogFlags = packed struct(u32) {
    case_sensitive_paths: bool = true,
    has_file_index: bool = false,
    has_inode: bool = false,
    reserved: u29 = 0,
};

pub const CatalogHeader = extern struct {
    magic: [8]u8 = MAGIC,
    version: u16 = FORMAT_VERSION,
    header_size: u16 = @sizeOf(CatalogHeader),
    flags: CatalogFlags = .{},
    root_fingerprint_hi: u64 = 0,
    root_fingerprint_lo: u64 = 0,
    path_count: u64 = 0,
    meta_count: u64 = 0,
    path_bytes: u64 = 0,
    generation: u64 = 0,

    pub fn rootFingerprint(self: CatalogHeader) RootFingerprint {
        return (@as(RootFingerprint, self.root_fingerprint_hi) << 64) | @as(RootFingerprint, self.root_fingerprint_lo);
    }

    pub fn withRootFingerprint(value: RootFingerprint) CatalogHeader {
        var header = CatalogHeader{};
        header.root_fingerprint_hi = @intCast(value >> 64);
        header.root_fingerprint_lo = @intCast(value & std.math.maxInt(u64));
        return header;
    }
};

pub const PathEntry = extern struct {
    file_id: FileId = INVALID_FILE_ID,
    path_offset: u64 = 0,
    path_len: u32 = 0,
    flags: PathFlags = .{},
};

pub const PathTable = struct {
    entries: []PathEntry,
    bytes: []u8,

    pub fn deinit(self: PathTable, allocator: std.mem.Allocator) void {
        allocator.free(self.entries);
        allocator.free(self.bytes);
    }

    pub fn path(self: PathTable, entry: PathEntry) []const u8 {
        const start: usize = @intCast(entry.path_offset);
        const end = start + entry.path_len;
        return self.bytes[start..end];
    }
};

pub const PathFlags = packed struct(u32) {
    hidden: bool = false,
    generated: bool = false,
    vendor: bool = false,
    reserved: u29 = 0,
};

pub const FileMeta = extern struct {
    file_id: FileId = INVALID_FILE_ID,
    size: u64 = 0,
    mtime_ns: i128 = 0,
    file_index_or_inode: u128 = 0,
    kind: FileKind = .regular,
    text: TextKind = .unknown,
    reserved: u16 = 0,
};

pub const FileMetaInput = struct {
    file_id: FileId,
    size: u64,
    mtime_ns: i128,
    file_index_or_inode: u128 = 0,
    kind: FileKind = .regular,
    sample: []const u8 = "",
};

pub fn isValidFileId(value: FileId) bool {
    return value != INVALID_FILE_ID;
}

pub fn makeFileId(ordinal: u64) FileId {
    return ordinal + 1;
}

pub fn identifyRoot(allocator: std.mem.Allocator, root: []const u8) !RootIdentity {
    const canonical_path = try canonicalizeRoot(allocator, root);
    return .{
        .canonical_path = canonical_path,
        .fingerprint = fingerprintRoot(canonical_path),
    };
}

pub fn canonicalizeRoot(allocator: std.mem.Allocator, root: []const u8) ![]u8 {
    if (root.len == 0) return allocator.dupe(u8, ".");

    var normalized = try allocator.alloc(u8, root.len);
    var index: usize = 0;
    while (index < root.len) : (index += 1) {
        const byte = root[index];
        normalized[index] = if (byte == '\\') '/' else byte;
    }

    if (normalized.len >= 2 and normalized[1] == ':') normalized[0] = std.ascii.toLower(normalized[0]);

    const keep_len = trimmedRootLen(normalized);
    if (keep_len == normalized.len) return normalized;

    const trimmed = try allocator.realloc(normalized, keep_len);
    return trimmed;
}

pub fn fingerprintRoot(canonical_root: []const u8) RootFingerprint {
    const hi = std.hash.Wyhash.hash(0x49584341545f4849, canonical_root);
    const lo = std.hash.Wyhash.hash(0x49584341545f4c4f, canonical_root);
    return (@as(RootFingerprint, hi) << 64) | @as(RootFingerprint, lo);
}

pub fn buildPathTable(allocator: std.mem.Allocator, paths: []const []const u8) !PathTable {
    const ordered = try allocator.dupe([]const u8, paths);
    defer allocator.free(ordered);
    std.mem.sort([]const u8, ordered, {}, lessThanPath);

    var total_bytes: usize = 0;
    for (ordered) |path| total_bytes += path.len;

    const entries = try allocator.alloc(PathEntry, ordered.len);
    errdefer allocator.free(entries);
    const bytes = try allocator.alloc(u8, total_bytes);
    errdefer allocator.free(bytes);

    var offset: usize = 0;
    for (ordered, 0..) |path, index| {
        @memcpy(bytes[offset .. offset + path.len], path);
        entries[index] = .{
            .file_id = makeFileId(index),
            .path_offset = @intCast(offset),
            .path_len = @intCast(path.len),
            .flags = .{},
        };
        offset += path.len;
    }

    return .{
        .entries = entries,
        .bytes = bytes,
    };
}

fn lessThanPath(_: void, lhs: []const u8, rhs: []const u8) bool {
    return std.mem.lessThan(u8, lhs, rhs);
}

pub fn makeFileMeta(input: FileMetaInput) FileMeta {
    return .{
        .file_id = input.file_id,
        .size = input.size,
        .mtime_ns = input.mtime_ns,
        .file_index_or_inode = input.file_index_or_inode,
        .kind = input.kind,
        .text = classifySample(input.sample),
        .reserved = 0,
    };
}

pub fn classifySample(sample: []const u8) TextKind {
    if (sample.len == 0) return .unknown;
    for (sample) |byte| {
        if (byte == 0) return .binary;
    }
    return .text;
}

fn trimmedRootLen(path: []const u8) usize {
    if (path.len <= 1) return path.len;
    if (path.len == 3 and path[1] == ':' and path[2] == '/') return path.len;

    var keep_len = path.len;
    while (keep_len > 1 and path[keep_len - 1] == '/') {
        if (keep_len == 3 and path[1] == ':') break;
        keep_len -= 1;
    }
    return keep_len;
}

test "catalog constants define a versioned file format" {
    try std.testing.expectEqualStrings("IXCAT001", &MAGIC);
    try std.testing.expectEqual(@as(u16, 1), FORMAT_VERSION);
    try std.testing.expect(MIN_HEADER_SIZE >= 64);
}

test "catalog root fingerprint splits and joins deterministically" {
    const fingerprint: RootFingerprint = 0x112233445566778899aabbccddeeff00;
    const header = CatalogHeader.withRootFingerprint(fingerprint);
    try std.testing.expectEqual(@as(u64, 0x1122334455667788), header.root_fingerprint_hi);
    try std.testing.expectEqual(@as(u64, 0x99aabbccddeeff00), header.root_fingerprint_lo);
    try std.testing.expectEqual(fingerprint, header.rootFingerprint());
}

test "catalog file ids reserve zero as invalid" {
    try std.testing.expect(!isValidFileId(INVALID_FILE_ID));
    try std.testing.expectEqual(@as(FileId, 1), makeFileId(0));
    try std.testing.expect(isValidFileId(makeFileId(42)));
}

test "catalog root canonicalization normalizes separators and trailing slash" {
    const path = try canonicalizeRoot(std.testing.allocator, "C:\\Workspaces\\ix-zig\\");
    defer std.testing.allocator.free(path);
    try std.testing.expectEqualStrings("c:/Workspaces/ix-zig", path);
}

test "catalog root canonicalization preserves drive root" {
    const path = try canonicalizeRoot(std.testing.allocator, "E:\\");
    defer std.testing.allocator.free(path);
    try std.testing.expectEqualStrings("e:/", path);
}

test "catalog root identity owns canonical path and stable fingerprint" {
    const a = try identifyRoot(std.testing.allocator, "E:\\Workspaces\\ix-zig");
    defer a.deinit(std.testing.allocator);
    const b = try identifyRoot(std.testing.allocator, "e:/Workspaces/ix-zig/");
    defer b.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("e:/Workspaces/ix-zig", a.canonical_path);
    try std.testing.expectEqual(a.fingerprint, b.fingerprint);
}

test "catalog path table assigns stable ids in lexical path order" {
    const input = [_][]const u8{
        "src/main.zig",
        "README.md",
        "src/core/search.zig",
    };
    const table = try buildPathTable(std.testing.allocator, &input);
    defer table.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 3), table.entries.len);
    try std.testing.expectEqual(@as(FileId, 1), table.entries[0].file_id);
    try std.testing.expectEqualStrings("README.md", table.path(table.entries[0]));
    try std.testing.expectEqualStrings("src/core/search.zig", table.path(table.entries[1]));
    try std.testing.expectEqualStrings("src/main.zig", table.path(table.entries[2]));
}

test "catalog file metadata captures stable identity and text classification" {
    const meta = makeFileMeta(.{
        .file_id = makeFileId(7),
        .size = 128,
        .mtime_ns = 42,
        .file_index_or_inode = 0xabc,
        .sample = "const std = @import(\"std\");",
    });

    try std.testing.expectEqual(makeFileId(7), meta.file_id);
    try std.testing.expectEqual(@as(u64, 128), meta.size);
    try std.testing.expectEqual(@as(i128, 42), meta.mtime_ns);
    try std.testing.expectEqual(@as(u128, 0xabc), meta.file_index_or_inode);
    try std.testing.expectEqual(TextKind.text, meta.text);
}

test "catalog file metadata treats null byte samples as binary" {
    const meta = makeFileMeta(.{
        .file_id = makeFileId(1),
        .size = 3,
        .mtime_ns = 0,
        .sample = "\x01\x00\x02",
    });
    try std.testing.expectEqual(TextKind.binary, meta.text);
}
