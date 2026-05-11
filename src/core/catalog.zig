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

pub const CatalogSnapshot = struct {
    header: CatalogHeader,
    entries: []PathEntry,
    metas: []FileMeta,
    path_bytes: []u8,

    pub fn deinit(self: CatalogSnapshot, allocator: std.mem.Allocator) void {
        allocator.free(self.entries);
        allocator.free(self.metas);
        allocator.free(self.path_bytes);
    }

    pub fn path(self: CatalogSnapshot, entry: PathEntry) []const u8 {
        const start: usize = @intCast(entry.path_offset);
        const end = start + entry.path_len;
        return self.path_bytes[start..end];
    }
};

pub const TombstoneSet = struct {
    file_ids: []const FileId = &.{},
    paths: []const []const u8 = &.{},

    pub fn contains(self: TombstoneSet, file_id: FileId, path: []const u8) bool {
        return self.containsFileId(file_id) or self.containsPath(path);
    }

    pub fn containsFileId(self: TombstoneSet, file_id: FileId) bool {
        for (self.file_ids) |candidate| {
            if (candidate == file_id) return true;
        }
        return false;
    }

    pub fn containsPath(self: TombstoneSet, path: []const u8) bool {
        for (self.paths) |candidate| {
            if (std.mem.eql(u8, candidate, path)) return true;
        }
        return false;
    }
};

pub const FoldedCatalog = struct {
    entries: []PathEntry,
    metas: []FileMeta,
    path_bytes: []u8,
    removed_count: usize,

    pub fn deinit(self: FoldedCatalog, allocator: std.mem.Allocator) void {
        allocator.free(self.entries);
        allocator.free(self.metas);
        allocator.free(self.path_bytes);
    }

    pub fn path(self: FoldedCatalog, entry: PathEntry) []const u8 {
        const start: usize = @intCast(entry.path_offset);
        const end = start + entry.path_len;
        return self.path_bytes[start..end];
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

pub const CatalogFileInput = struct {
    path: []const u8,
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

pub fn buildCatalogBytes(
    allocator: std.mem.Allocator,
    root: []const u8,
    generation: u64,
    files: []const CatalogFileInput,
) ![]u8 {
    const root_identity = try identifyRoot(allocator, root);
    defer root_identity.deinit(allocator);

    const ordered = try allocator.dupe(CatalogFileInput, files);
    defer allocator.free(ordered);
    std.mem.sort(CatalogFileInput, ordered, {}, lessThanFileInputPath);

    const paths = try allocator.alloc([]const u8, ordered.len);
    defer allocator.free(paths);
    for (ordered, 0..) |file, index| paths[index] = file.path;

    const table = try buildPathTable(allocator, paths);
    defer table.deinit(allocator);

    const metas = try allocator.alloc(FileMeta, ordered.len);
    defer allocator.free(metas);
    for (ordered, 0..) |file, index| {
        metas[index] = makeFileMeta(.{
            .file_id = table.entries[index].file_id,
            .size = file.size,
            .mtime_ns = file.mtime_ns,
            .file_index_or_inode = file.file_index_or_inode,
            .kind = file.kind,
            .sample = file.sample,
        });
    }

    return serializeCatalog(allocator, root_identity.fingerprint, generation, table, metas);
}

fn lessThanFileInputPath(_: void, lhs: CatalogFileInput, rhs: CatalogFileInput) bool {
    return std.mem.lessThan(u8, lhs.path, rhs.path);
}

pub fn serializeCatalog(
    allocator: std.mem.Allocator,
    root_fingerprint: RootFingerprint,
    generation: u64,
    table: PathTable,
    metas: []const FileMeta,
) ![]u8 {
    var header = CatalogHeader.withRootFingerprint(root_fingerprint);
    header.path_count = table.entries.len;
    header.meta_count = metas.len;
    header.path_bytes = table.bytes.len;
    header.generation = generation;

    var bytes = std.ArrayList(u8).empty;
    try writeHeader(&bytes, allocator, header);
    for (table.entries) |entry| try writePathEntry(&bytes, allocator, entry);
    for (metas) |meta| try writeFileMeta(&bytes, allocator, meta);
    try bytes.appendSlice(allocator, table.bytes);
    return bytes.toOwnedSlice(allocator);
}

pub fn parseCatalog(allocator: std.mem.Allocator, bytes: []const u8) !CatalogSnapshot {
    var cursor = Cursor{ .bytes = bytes };
    const header = try readHeader(&cursor);
    if (!std.mem.eql(u8, &header.magic, &MAGIC)) return error.InvalidCatalogMagic;
    if (header.version != FORMAT_VERSION) return error.UnsupportedCatalogVersion;
    if (header.header_size != @sizeOf(CatalogHeader)) return error.InvalidCatalogHeaderSize;

    const path_count: usize = try checkedCount(header.path_count);
    const meta_count: usize = try checkedCount(header.meta_count);
    const path_bytes_len: usize = try checkedCount(header.path_bytes);

    const entries = try allocator.alloc(PathEntry, path_count);
    errdefer allocator.free(entries);
    for (entries) |*entry| entry.* = try readPathEntry(&cursor);

    const metas = try allocator.alloc(FileMeta, meta_count);
    errdefer allocator.free(metas);
    for (metas) |*meta| meta.* = try readFileMeta(&cursor);

    const path_bytes = try allocator.dupe(u8, try cursor.take(path_bytes_len));
    errdefer allocator.free(path_bytes);
    if (cursor.remaining() != 0) return error.TrailingCatalogBytes;
    try validateCatalogShape(entries, metas, path_bytes);

    return .{
        .header = header,
        .entries = entries,
        .metas = metas,
        .path_bytes = path_bytes,
    };
}

pub fn parseCatalogForRoot(allocator: std.mem.Allocator, bytes: []const u8, expected_root: RootFingerprint) !CatalogSnapshot {
    const snapshot = try parseCatalog(allocator, bytes);
    errdefer snapshot.deinit(allocator);
    if (snapshot.header.rootFingerprint() != expected_root) return error.WrongCatalogRoot;
    return snapshot;
}

pub fn foldTombstonedCatalogEntries(
    allocator: std.mem.Allocator,
    snapshot: CatalogSnapshot,
    tombstones: TombstoneSet,
) !FoldedCatalog {
    var entries = std.ArrayList(PathEntry).empty;
    errdefer entries.deinit(allocator);
    var metas = std.ArrayList(FileMeta).empty;
    errdefer metas.deinit(allocator);
    var path_bytes = std.ArrayList(u8).empty;
    errdefer path_bytes.deinit(allocator);

    var removed_count: usize = 0;
    for (snapshot.entries, 0..) |entry, index| {
        const existing_path = snapshot.path(entry);
        if (tombstones.contains(entry.file_id, existing_path)) {
            removed_count += 1;
            continue;
        }

        var folded_entry = entry;
        folded_entry.path_offset = @intCast(path_bytes.items.len);
        try path_bytes.appendSlice(allocator, existing_path);
        try entries.append(allocator, folded_entry);
        try metas.append(allocator, snapshot.metas[index]);
    }

    const owned_entries = try entries.toOwnedSlice(allocator);
    errdefer allocator.free(owned_entries);
    const owned_metas = try metas.toOwnedSlice(allocator);
    errdefer allocator.free(owned_metas);
    const owned_path_bytes = try path_bytes.toOwnedSlice(allocator);
    errdefer allocator.free(owned_path_bytes);

    try validateCatalogShape(owned_entries, owned_metas, owned_path_bytes);
    return .{
        .entries = owned_entries,
        .metas = owned_metas,
        .path_bytes = owned_path_bytes,
        .removed_count = removed_count,
    };
}

pub fn publishCatalogBytes(io: std.Io, dir: std.Io.Dir, sub_path: []const u8, data: []const u8) !void {
    var atomic_file = try dir.createFileAtomic(io, sub_path, .{ .replace = true });
    defer atomic_file.deinit(io);
    try atomic_file.file.writeStreamingAll(io, data);
    try atomic_file.file.sync(io);
    try atomic_file.replace(io);
}

fn validateCatalogShape(entries: []const PathEntry, metas: []const FileMeta, path_bytes: []const u8) !void {
    if (entries.len != metas.len) return error.CatalogMetaCountMismatch;

    var previous_path: ?[]const u8 = null;
    for (entries, 0..) |entry, index| {
        if (!isValidFileId(entry.file_id)) return error.InvalidCatalogFileId;
        if (entry.file_id != metas[index].file_id) return error.CatalogFileIdMismatch;
        if (entry.path_offset > std.math.maxInt(usize)) return error.CatalogPathBounds;
        const start: usize = @intCast(entry.path_offset);
        if (entry.path_len > path_bytes.len - start) return error.CatalogPathBounds;
        const current_path = path_bytes[start .. start + entry.path_len];
        if (current_path.len == 0) return error.EmptyCatalogPath;
        if (previous_path) |prev| {
            if (!std.mem.lessThan(u8, prev, current_path)) return error.UnsortedCatalogPaths;
        }
        previous_path = current_path;
    }
}

fn writeHeader(bytes: *std.ArrayList(u8), allocator: std.mem.Allocator, header: CatalogHeader) !void {
    try bytes.appendSlice(allocator, &header.magic);
    try appendU16(bytes, allocator, header.version);
    try appendU16(bytes, allocator, header.header_size);
    try appendU32(bytes, allocator, catalogFlagsBits(header.flags));
    try appendU64(bytes, allocator, header.root_fingerprint_hi);
    try appendU64(bytes, allocator, header.root_fingerprint_lo);
    try appendU64(bytes, allocator, header.path_count);
    try appendU64(bytes, allocator, header.meta_count);
    try appendU64(bytes, allocator, header.path_bytes);
    try appendU64(bytes, allocator, header.generation);
}

fn readHeader(cursor: *Cursor) !CatalogHeader {
    var header = CatalogHeader{};
    @memcpy(&header.magic, try cursor.take(MAGIC.len));
    header.version = try cursor.readU16();
    header.header_size = try cursor.readU16();
    header.flags = catalogFlagsFromBits(try cursor.readU32());
    header.root_fingerprint_hi = try cursor.readU64();
    header.root_fingerprint_lo = try cursor.readU64();
    header.path_count = try cursor.readU64();
    header.meta_count = try cursor.readU64();
    header.path_bytes = try cursor.readU64();
    header.generation = try cursor.readU64();
    return header;
}

fn writePathEntry(bytes: *std.ArrayList(u8), allocator: std.mem.Allocator, entry: PathEntry) !void {
    try appendU64(bytes, allocator, entry.file_id);
    try appendU64(bytes, allocator, entry.path_offset);
    try appendU32(bytes, allocator, entry.path_len);
    try appendU32(bytes, allocator, pathFlagsBits(entry.flags));
}

fn readPathEntry(cursor: *Cursor) !PathEntry {
    return .{
        .file_id = try cursor.readU64(),
        .path_offset = try cursor.readU64(),
        .path_len = try cursor.readU32(),
        .flags = pathFlagsFromBits(try cursor.readU32()),
    };
}

fn writeFileMeta(bytes: *std.ArrayList(u8), allocator: std.mem.Allocator, meta: FileMeta) !void {
    try appendU64(bytes, allocator, meta.file_id);
    try appendU64(bytes, allocator, meta.size);
    try appendU128(bytes, allocator, @bitCast(meta.mtime_ns));
    try appendU128(bytes, allocator, meta.file_index_or_inode);
    try bytes.append(allocator, @intFromEnum(meta.kind));
    try bytes.append(allocator, @intFromEnum(meta.text));
    try appendU16(bytes, allocator, meta.reserved);
}

fn readFileMeta(cursor: *Cursor) !FileMeta {
    return .{
        .file_id = try cursor.readU64(),
        .size = try cursor.readU64(),
        .mtime_ns = @bitCast(try cursor.readU128()),
        .file_index_or_inode = try cursor.readU128(),
        .kind = @enumFromInt(try cursor.readByte()),
        .text = @enumFromInt(try cursor.readByte()),
        .reserved = try cursor.readU16(),
    };
}

fn catalogFlagsBits(flags: CatalogFlags) u32 {
    var bits: u32 = 0;
    if (flags.case_sensitive_paths) bits |= 1 << 0;
    if (flags.has_file_index) bits |= 1 << 1;
    if (flags.has_inode) bits |= 1 << 2;
    return bits;
}

fn catalogFlagsFromBits(bits: u32) CatalogFlags {
    return .{
        .case_sensitive_paths = (bits & (1 << 0)) != 0,
        .has_file_index = (bits & (1 << 1)) != 0,
        .has_inode = (bits & (1 << 2)) != 0,
    };
}

fn pathFlagsBits(flags: PathFlags) u32 {
    var bits: u32 = 0;
    if (flags.hidden) bits |= 1 << 0;
    if (flags.generated) bits |= 1 << 1;
    if (flags.vendor) bits |= 1 << 2;
    return bits;
}

fn pathFlagsFromBits(bits: u32) PathFlags {
    return .{
        .hidden = (bits & (1 << 0)) != 0,
        .generated = (bits & (1 << 1)) != 0,
        .vendor = (bits & (1 << 2)) != 0,
    };
}

fn checkedCount(value: u64) !usize {
    if (value > std.math.maxInt(usize)) return error.CatalogCountOverflow;
    return @intCast(value);
}

fn appendU16(bytes: *std.ArrayList(u8), allocator: std.mem.Allocator, value: u16) !void {
    try bytes.append(allocator, @intCast(value & 0xff));
    try bytes.append(allocator, @intCast((value >> 8) & 0xff));
}

fn appendU32(bytes: *std.ArrayList(u8), allocator: std.mem.Allocator, value: u32) !void {
    var index: u5 = 0;
    while (index < 4) : (index += 1) try bytes.append(allocator, @intCast((value >> (index * 8)) & 0xff));
}

fn appendU64(bytes: *std.ArrayList(u8), allocator: std.mem.Allocator, value: u64) !void {
    var index: u6 = 0;
    while (index < 8) : (index += 1) try bytes.append(allocator, @intCast((value >> (index * 8)) & 0xff));
}

fn appendU128(bytes: *std.ArrayList(u8), allocator: std.mem.Allocator, value: u128) !void {
    var index: u7 = 0;
    while (index < 16) : (index += 1) try bytes.append(allocator, @intCast((value >> (index * 8)) & 0xff));
}

const Cursor = struct {
    bytes: []const u8,
    offset: usize = 0,

    fn take(self: *Cursor, len: usize) ![]const u8 {
        if (len > self.bytes.len - self.offset) return error.TruncatedCatalog;
        const start = self.offset;
        self.offset += len;
        return self.bytes[start..self.offset];
    }

    fn remaining(self: Cursor) usize {
        return self.bytes.len - self.offset;
    }

    fn readByte(self: *Cursor) !u8 {
        return (try self.take(1))[0];
    }

    fn readU16(self: *Cursor) !u16 {
        const slice = try self.take(2);
        return @as(u16, slice[0]) | (@as(u16, slice[1]) << 8);
    }

    fn readU32(self: *Cursor) !u32 {
        const slice = try self.take(4);
        var value: u32 = 0;
        var index: u5 = 0;
        while (index < 4) : (index += 1) value |= @as(u32, slice[index]) << (index * 8);
        return value;
    }

    fn readU64(self: *Cursor) !u64 {
        const slice = try self.take(8);
        var value: u64 = 0;
        var index: u6 = 0;
        while (index < 8) : (index += 1) value |= @as(u64, slice[index]) << (index * 8);
        return value;
    }

    fn readU128(self: *Cursor) !u128 {
        const slice = try self.take(16);
        var value: u128 = 0;
        var index: u7 = 0;
        while (index < 16) : (index += 1) value |= @as(u128, slice[index]) << (index * 8);
        return value;
    }
};

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

test "catalog serialization round-trips header paths and metadata" {
    const paths = [_][]const u8{
        "src/main.zig",
        "README.md",
    };
    const table = try buildPathTable(std.testing.allocator, &paths);
    defer table.deinit(std.testing.allocator);

    const metas = [_]FileMeta{
        makeFileMeta(.{
            .file_id = table.entries[0].file_id,
            .size = 9,
            .mtime_ns = 11,
            .file_index_or_inode = 13,
            .sample = "text",
        }),
        makeFileMeta(.{
            .file_id = table.entries[1].file_id,
            .size = 17,
            .mtime_ns = -19,
            .file_index_or_inode = 23,
            .sample = "\x00",
        }),
    };

    const fingerprint = fingerprintRoot("e:/Workspaces/ix-zig");
    const encoded = try serializeCatalog(std.testing.allocator, fingerprint, 7, table, &metas);
    defer std.testing.allocator.free(encoded);

    const parsed = try parseCatalog(std.testing.allocator, encoded);
    defer parsed.deinit(std.testing.allocator);

    try std.testing.expectEqual(fingerprint, parsed.header.rootFingerprint());
    try std.testing.expectEqual(@as(u64, 7), parsed.header.generation);
    try std.testing.expectEqual(@as(usize, 2), parsed.entries.len);
    try std.testing.expectEqualStrings("README.md", parsed.path(parsed.entries[0]));
    try std.testing.expectEqualStrings("src/main.zig", parsed.path(parsed.entries[1]));
    try std.testing.expectEqual(TextKind.text, parsed.metas[0].text);
    try std.testing.expectEqual(TextKind.binary, parsed.metas[1].text);
    try std.testing.expectEqual(@as(i128, -19), parsed.metas[1].mtime_ns);
}

test "catalog parser rejects invalid magic" {
    const paths = [_][]const u8{"README.md"};
    const table = try buildPathTable(std.testing.allocator, &paths);
    defer table.deinit(std.testing.allocator);
    const metas = [_]FileMeta{makeFileMeta(.{
        .file_id = table.entries[0].file_id,
        .size = 1,
        .mtime_ns = 2,
        .sample = "x",
    })};

    const encoded = try serializeCatalog(std.testing.allocator, 1, 1, table, &metas);
    defer std.testing.allocator.free(encoded);
    encoded[0] = 'x';

    try std.testing.expectError(error.InvalidCatalogMagic, parseCatalog(std.testing.allocator, encoded));
}

test "catalog parser rejects wrong root" {
    const paths = [_][]const u8{"README.md"};
    const table = try buildPathTable(std.testing.allocator, &paths);
    defer table.deinit(std.testing.allocator);
    const metas = [_]FileMeta{makeFileMeta(.{
        .file_id = table.entries[0].file_id,
        .size = 1,
        .mtime_ns = 2,
        .sample = "x",
    })};

    const encoded = try serializeCatalog(std.testing.allocator, 1, 1, table, &metas);
    defer std.testing.allocator.free(encoded);

    try std.testing.expectError(error.WrongCatalogRoot, parseCatalogForRoot(std.testing.allocator, encoded, 2));
}

test "catalog parser rejects truncated payloads" {
    const paths = [_][]const u8{"README.md"};
    const table = try buildPathTable(std.testing.allocator, &paths);
    defer table.deinit(std.testing.allocator);
    const metas = [_]FileMeta{makeFileMeta(.{
        .file_id = table.entries[0].file_id,
        .size = 1,
        .mtime_ns = 2,
        .sample = "x",
    })};

    const encoded = try serializeCatalog(std.testing.allocator, 1, 1, table, &metas);
    defer std.testing.allocator.free(encoded);

    try std.testing.expectError(error.TruncatedCatalog, parseCatalog(std.testing.allocator, encoded[0 .. encoded.len - 1]));
}

test "catalog parser rejects path bounds outside path byte table" {
    const paths = [_][]const u8{"README.md"};
    const table = try buildPathTable(std.testing.allocator, &paths);
    defer table.deinit(std.testing.allocator);
    var broken_entry = table.entries[0];
    broken_entry.path_len = 1000;
    const broken_entries = [_]PathEntry{broken_entry};
    const broken_table = PathTable{
        .entries = @constCast(&broken_entries),
        .bytes = table.bytes,
    };
    const metas = [_]FileMeta{makeFileMeta(.{
        .file_id = broken_entry.file_id,
        .size = 1,
        .mtime_ns = 2,
        .sample = "x",
    })};

    const encoded = try serializeCatalog(std.testing.allocator, 1, 1, broken_table, &metas);
    defer std.testing.allocator.free(encoded);

    try std.testing.expectError(error.CatalogPathBounds, parseCatalog(std.testing.allocator, encoded));
}

test "catalog publish writes through atomic replacement" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try publishCatalogBytes(std.testing.io, tmp.dir, "catalog.bin", "first");
    try publishCatalogBytes(std.testing.io, tmp.dir, "catalog.bin", "second");

    var buffer: [16]u8 = undefined;
    const contents = try tmp.dir.readFile(std.testing.io, "catalog.bin", &buffer);
    try std.testing.expectEqualStrings("second", contents);
}

test "catalog build entrypoint creates sorted parseable catalog bytes" {
    const files = [_]CatalogFileInput{
        .{
            .path = "src/main.zig",
            .size = 30,
            .mtime_ns = 300,
            .file_index_or_inode = 3,
            .sample = "pub fn main() void {}",
        },
        .{
            .path = "README.md",
            .size = 10,
            .mtime_ns = 100,
            .file_index_or_inode = 1,
            .sample = "# ix",
        },
    };

    const encoded = try buildCatalogBytes(std.testing.allocator, "E:\\Workspaces\\ix-zig\\", 9, &files);
    defer std.testing.allocator.free(encoded);

    const expected_root = fingerprintRoot("e:/Workspaces/ix-zig");
    const parsed = try parseCatalogForRoot(std.testing.allocator, encoded, expected_root);
    defer parsed.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(u64, 9), parsed.header.generation);
    try std.testing.expectEqualStrings("README.md", parsed.path(parsed.entries[0]));
    try std.testing.expectEqualStrings("src/main.zig", parsed.path(parsed.entries[1]));
    try std.testing.expectEqual(@as(u64, 10), parsed.metas[0].size);
    try std.testing.expectEqual(@as(u64, 30), parsed.metas[1].size);
}

test "catalog tombstone folding removes deleted file ids and stale paths" {
    const files = [_]CatalogFileInput{
        .{
            .path = "src/a.zig",
            .size = 10,
            .mtime_ns = 100,
            .sample = "const a = 1;",
        },
        .{
            .path = "src/b.zig",
            .size = 20,
            .mtime_ns = 200,
            .sample = "const b = 2;",
        },
        .{
            .path = "src/c.zig",
            .size = 30,
            .mtime_ns = 300,
            .sample = "const c = 3;",
        },
    };

    const encoded = try buildCatalogBytes(std.testing.allocator, "E:\\Workspaces\\ix-zig\\", 12, &files);
    defer std.testing.allocator.free(encoded);
    const snapshot = try parseCatalog(std.testing.allocator, encoded);
    defer snapshot.deinit(std.testing.allocator);

    const folded = try foldTombstonedCatalogEntries(std.testing.allocator, snapshot, .{
        .file_ids = &.{makeFileId(1)},
        .paths = &.{"src/c.zig"},
    });
    defer folded.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 1), folded.entries.len);
    try std.testing.expectEqual(@as(usize, 1), folded.metas.len);
    try std.testing.expectEqual(@as(usize, 2), folded.removed_count);
    try std.testing.expectEqual(makeFileId(0), folded.entries[0].file_id);
    try std.testing.expectEqual(makeFileId(0), folded.metas[0].file_id);
    try std.testing.expectEqualStrings("src/a.zig", folded.path(folded.entries[0]));
}

test "catalog tombstone folding preserves sorted shape when nothing is removed" {
    const files = [_]CatalogFileInput{
        .{
            .path = "README.md",
            .size = 10,
            .mtime_ns = 100,
            .sample = "# ix",
        },
        .{
            .path = "src/main.zig",
            .size = 20,
            .mtime_ns = 200,
            .sample = "pub fn main() void {}",
        },
    };

    const encoded = try buildCatalogBytes(std.testing.allocator, "E:\\Workspaces\\ix-zig\\", 13, &files);
    defer std.testing.allocator.free(encoded);
    const snapshot = try parseCatalog(std.testing.allocator, encoded);
    defer snapshot.deinit(std.testing.allocator);

    const folded = try foldTombstonedCatalogEntries(std.testing.allocator, snapshot, .{});
    defer folded.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 2), folded.entries.len);
    try std.testing.expectEqual(@as(usize, 0), folded.removed_count);
    try std.testing.expectEqualStrings("README.md", folded.path(folded.entries[0]));
    try std.testing.expectEqualStrings("src/main.zig", folded.path(folded.entries[1]));
    try std.testing.expectEqual(@as(u64, 20), folded.metas[1].size);
}

test "catalog build entrypoint is deterministic across input order" {
    const files_a = [_]CatalogFileInput{
        .{
            .path = "src/main.zig",
            .size = 30,
            .mtime_ns = 300,
            .file_index_or_inode = 3,
            .sample = "pub fn main() void {}",
        },
        .{
            .path = "README.md",
            .size = 10,
            .mtime_ns = 100,
            .file_index_or_inode = 1,
            .sample = "# ix",
        },
        .{
            .path = "src/core/search.zig",
            .size = 20,
            .mtime_ns = 200,
            .file_index_or_inode = 2,
            .sample = "pub const SearchConfig = struct {};",
        },
    };
    const files_b = [_]CatalogFileInput{
        files_a[2],
        files_a[0],
        files_a[1],
    };

    const encoded_a = try buildCatalogBytes(std.testing.allocator, "E:\\Workspaces\\ix-zig\\", 11, &files_a);
    defer std.testing.allocator.free(encoded_a);
    const encoded_b = try buildCatalogBytes(std.testing.allocator, "e:/Workspaces/ix-zig", 11, &files_b);
    defer std.testing.allocator.free(encoded_b);

    try std.testing.expectEqualSlices(u8, encoded_a, encoded_b);
}
