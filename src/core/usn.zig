const std = @import("std");

const windows = std.os.windows;

pub const CURSOR_MAGIC: [8]u8 = .{ 'I', 'X', 'U', 'S', 'N', '0', '0', '1' };
pub const CURSOR_FORMAT_VERSION: u16 = 1;
pub const CURSOR_READ_LIMIT: usize = 4096;

pub const USN = i64;
pub const DWORDLONG = u64;
pub const RootFingerprint = u128;
pub const FILE_DEVICE_FILE_SYSTEM: windows.DWORD = 0x0000_0009;
pub const METHOD_BUFFERED: windows.DWORD = 0;
pub const METHOD_NEITHER: windows.DWORD = 3;
pub const FILE_ANY_ACCESS: windows.DWORD = 0;

pub const FSCTL_QUERY_USN_JOURNAL: windows.DWORD = ctlCode(FILE_DEVICE_FILE_SYSTEM, 61, METHOD_BUFFERED, FILE_ANY_ACCESS);
pub const FSCTL_READ_USN_JOURNAL: windows.DWORD = ctlCode(FILE_DEVICE_FILE_SYSTEM, 46, METHOD_NEITHER, FILE_ANY_ACCESS);

pub const USN_REASON_DATA_OVERWRITE: windows.DWORD = 0x0000_0001;
pub const USN_REASON_DATA_EXTEND: windows.DWORD = 0x0000_0002;
pub const USN_REASON_DATA_TRUNCATION: windows.DWORD = 0x0000_0004;
pub const USN_REASON_FILE_CREATE: windows.DWORD = 0x0000_0100;
pub const USN_REASON_FILE_DELETE: windows.DWORD = 0x0000_0200;
pub const USN_REASON_RENAME_OLD_NAME: windows.DWORD = 0x0000_1000;
pub const USN_REASON_RENAME_NEW_NAME: windows.DWORD = 0x0000_2000;
pub const USN_REASON_CLOSE: windows.DWORD = 0x8000_0000;

pub const USN_REASON_IX_DELTA_RELEVANT: windows.DWORD =
    USN_REASON_DATA_OVERWRITE |
    USN_REASON_DATA_EXTEND |
    USN_REASON_DATA_TRUNCATION |
    USN_REASON_FILE_CREATE |
    USN_REASON_FILE_DELETE |
    USN_REASON_RENAME_OLD_NAME |
    USN_REASON_RENAME_NEW_NAME;

pub const UsnJournalDataV0 = extern struct {
    usn_journal_id: DWORDLONG = 0,
    first_usn: USN = 0,
    next_usn: USN = 0,
    lowest_valid_usn: USN = 0,
    max_usn: USN = 0,
    maximum_size: DWORDLONG = 0,
    allocation_delta: DWORDLONG = 0,
};

pub const ReadUsnJournalDataV1 = extern struct {
    start_usn: USN = 0,
    reason_mask: windows.DWORD = USN_REASON_IX_DELTA_RELEVANT,
    return_only_on_close: windows.DWORD = 0,
    timeout: DWORDLONG = 0,
    bytes_to_wait_for: DWORDLONG = 0,
    usn_journal_id: DWORDLONG = 0,
    min_major_version: u16 = 2,
    max_major_version: u16 = 3,
};

pub const FileId128 = extern struct {
    identifier: [16]u8 = [_]u8{0} ** 16,
};

pub const FileSystemKind = enum(u8) {
    unknown = 0,
    ntfs = 1,
    refs = 2,
    unsupported = 255,
};

pub const VolumeIdentity = struct {
    root_fingerprint: RootFingerprint,
    volume_serial_number: windows.DWORD,
    filesystem: FileSystemKind,

    pub fn supportsUsn(self: VolumeIdentity) bool {
        return self.filesystem == .ntfs or self.filesystem == .refs;
    }
};

pub const JournalCursor = struct {
    volume: VolumeIdentity,
    usn_journal_id: DWORDLONG,
    first_usn: USN,
    next_usn: USN,
    lowest_valid_usn: USN,

    pub fn canContinue(self: JournalCursor, current: JournalCursor) bool {
        return self.volume.root_fingerprint == current.volume.root_fingerprint and
            self.volume.volume_serial_number == current.volume.volume_serial_number and
            self.volume.filesystem == current.volume.filesystem and
            self.usn_journal_id == current.usn_journal_id and
            self.next_usn >= current.lowest_valid_usn and
            self.next_usn <= current.next_usn;
    }
};

pub const JournalAvailabilityKind = enum(u8) {
    usable = 1,
    inaccessible = 2,
    unsupported_filesystem = 3,
    invalid_journal = 4,
};

pub const JournalProbeInput = union(enum) {
    journal: UsnJournalDataV0,
    inaccessible,
    unsupported_filesystem,
};

pub const JournalAvailability = struct {
    kind: JournalAvailabilityKind,
    cursor: ?JournalCursor = null,
    fallback_reason: []const u8 = "",

    pub fn canUseUsn(self: JournalAvailability) bool {
        return self.kind == .usable and self.cursor != null;
    }
};

pub const ReadBatchOptions = struct {
    max_records: usize = 1024,
    max_bytes: usize = 64 * 1024,
    cancelled: bool = false,
};

pub const UsnRecordSummary = struct {
    major_version: u16,
    minor_version: u16,
    record_length: windows.DWORD,
    reason: windows.DWORD,
    file_name_offset: u16,
    file_name_length: u16,
};

pub const ReadBatchResult = struct {
    next_start_usn: USN,
    records: []UsnRecordSummary,
    truncated_by_limit: bool = false,

    pub fn deinit(self: ReadBatchResult, allocator: std.mem.Allocator) void {
        allocator.free(self.records);
    }
};

pub const JournalPaths = struct {
    journals_dir: []const u8,
    cursor_path: []const u8,
    tmp_cursor_path: []const u8,

    pub fn deinit(self: JournalPaths, allocator: std.mem.Allocator) void {
        allocator.free(self.journals_dir);
        allocator.free(self.cursor_path);
        allocator.free(self.tmp_cursor_path);
    }
};

pub const UsnRecordHeader = extern struct {
    record_length: windows.DWORD,
    major_version: u16,
    minor_version: u16,
};

pub const UsnRecordV2Prefix = extern struct {
    record_length: windows.DWORD,
    major_version: u16,
    minor_version: u16,
    file_reference_number: u64,
    parent_file_reference_number: u64,
    usn: USN,
    timestamp: i64,
    reason: windows.DWORD,
    source_info: windows.DWORD,
    security_id: windows.DWORD,
    file_attributes: windows.DWORD,
    file_name_length: u16,
    file_name_offset: u16,
};

pub const UsnRecordV3Prefix = extern struct {
    record_length: windows.DWORD,
    major_version: u16,
    minor_version: u16,
    file_reference_number: FileId128,
    parent_file_reference_number: FileId128,
    usn: USN,
    timestamp: i64,
    reason: windows.DWORD,
    source_info: windows.DWORD,
    security_id: windows.DWORD,
    file_attributes: windows.DWORD,
    file_name_length: u16,
    file_name_offset: u16,
};

pub extern "kernel32" fn DeviceIoControl(
    hDevice: windows.HANDLE,
    dwIoControlCode: windows.DWORD,
    lpInBuffer: ?*const anyopaque,
    nInBufferSize: windows.DWORD,
    lpOutBuffer: ?*anyopaque,
    nOutBufferSize: windows.DWORD,
    lpBytesReturned: ?*windows.DWORD,
    lpOverlapped: ?*anyopaque,
) callconv(.winapi) windows.BOOL;

pub fn ctlCode(device_type: windows.DWORD, function: windows.DWORD, method: windows.DWORD, access: windows.DWORD) windows.DWORD {
    return (device_type << 16) | (access << 14) | (function << 2) | method;
}

pub fn readRequest(start_usn: USN, journal_id: DWORDLONG) ReadUsnJournalDataV1 {
    return .{
        .start_usn = start_usn,
        .usn_journal_id = journal_id,
    };
}

pub fn readBatchRequest(cursor: JournalCursor, timeout_ms: DWORDLONG, bytes_to_wait_for: DWORDLONG) ReadUsnJournalDataV1 {
    var request = readRequest(cursor.next_usn, cursor.usn_journal_id);
    request.timeout = timeout_ms;
    request.bytes_to_wait_for = bytes_to_wait_for;
    return request;
}

pub fn buildJournalPaths(allocator: std.mem.Allocator, root: []const u8) !JournalPaths {
    const journals_dir = try std.fs.path.join(allocator, &.{ root, ".ix", "index", "journals" });
    errdefer allocator.free(journals_dir);
    const cursor_path = try std.fs.path.join(allocator, &.{ journals_dir, "ntfs-usn.cursor" });
    errdefer allocator.free(cursor_path);
    const tmp_cursor_path = try std.fs.path.join(allocator, &.{ journals_dir, "ntfs-usn.cursor.tmp" });
    errdefer allocator.free(tmp_cursor_path);
    return .{
        .journals_dir = journals_dir,
        .cursor_path = cursor_path,
        .tmp_cursor_path = tmp_cursor_path,
    };
}

pub fn cursorFromJournalData(volume: VolumeIdentity, data: UsnJournalDataV0) !JournalCursor {
    if (!volume.supportsUsn()) return error.UnsupportedJournalFileSystem;
    if (data.usn_journal_id == 0) return error.InvalidUsnJournalId;
    if (data.next_usn < data.first_usn) return error.InvalidUsnRange;
    if (data.lowest_valid_usn < data.first_usn) return error.InvalidUsnRange;
    if (data.lowest_valid_usn > data.next_usn) return error.InvalidUsnRange;

    return .{
        .volume = volume,
        .usn_journal_id = data.usn_journal_id,
        .first_usn = data.first_usn,
        .next_usn = data.next_usn,
        .lowest_valid_usn = data.lowest_valid_usn,
    };
}

pub fn classifyJournalAvailability(volume: VolumeIdentity, input: JournalProbeInput) JournalAvailability {
    if (!volume.supportsUsn()) {
        return .{
            .kind = .unsupported_filesystem,
            .fallback_reason = "unsupported_filesystem",
        };
    }

    return switch (input) {
        .journal => |data| blk: {
            const cursor = cursorFromJournalData(volume, data) catch break :blk .{
                .kind = .invalid_journal,
                .fallback_reason = "invalid_journal",
            };
            break :blk .{
                .kind = .usable,
                .cursor = cursor,
                .fallback_reason = "",
            };
        },
        .inaccessible => .{
            .kind = .inaccessible,
            .fallback_reason = "journal_inaccessible",
        },
        .unsupported_filesystem => .{
            .kind = .unsupported_filesystem,
            .fallback_reason = "unsupported_filesystem",
        },
    };
}

pub fn parseReadBatch(allocator: std.mem.Allocator, bytes: []const u8, options: ReadBatchOptions) !ReadBatchResult {
    if (options.cancelled) return error.OperationCancelled;
    if (options.max_records == 0) return error.EmptyUsnBatchCapacity;
    if (bytes.len > options.max_bytes) return error.UsnBatchTooLarge;

    var cursor = ByteCursor{ .bytes = bytes };
    const next_start_usn = try cursor.readI64();
    var records = std.ArrayList(UsnRecordSummary).empty;
    errdefer records.deinit(allocator);

    var truncated_by_limit = false;
    while (cursor.remaining() > 0) {
        if (options.cancelled) return error.OperationCancelled;
        if (records.items.len >= options.max_records) {
            truncated_by_limit = true;
            break;
        }

        const remaining = cursor.bytes[cursor.index..];
        const summary = try parseRecordSummary(remaining);
        try records.append(allocator, summary);
        _ = try cursor.take(summary.record_length);
    }

    return .{
        .next_start_usn = next_start_usn,
        .records = try records.toOwnedSlice(allocator),
        .truncated_by_limit = truncated_by_limit,
    };
}

pub fn serializeJournalCursor(allocator: std.mem.Allocator, cursor: JournalCursor) ![]u8 {
    try validateJournalCursor(cursor);

    var bytes = std.ArrayList(u8).empty;
    errdefer bytes.deinit(allocator);
    try bytes.appendSlice(allocator, &CURSOR_MAGIC);
    try appendU16(&bytes, allocator, CURSOR_FORMAT_VERSION);
    try bytes.append(allocator, @intFromEnum(cursor.volume.filesystem));
    try bytes.appendNTimes(allocator, 0, 5);
    try appendU64(&bytes, allocator, @intCast(cursor.volume.root_fingerprint >> 64));
    try appendU64(&bytes, allocator, @intCast(cursor.volume.root_fingerprint & std.math.maxInt(u64)));
    try appendU32(&bytes, allocator, cursor.volume.volume_serial_number);
    try appendU32(&bytes, allocator, 0);
    try appendU64(&bytes, allocator, cursor.usn_journal_id);
    try appendI64(&bytes, allocator, cursor.first_usn);
    try appendI64(&bytes, allocator, cursor.next_usn);
    try appendI64(&bytes, allocator, cursor.lowest_valid_usn);
    return bytes.toOwnedSlice(allocator);
}

pub fn parseJournalCursorForVolume(bytes: []const u8, expected_volume: VolumeIdentity) !JournalCursor {
    var cursor = ByteCursor{ .bytes = bytes };
    if (!std.mem.eql(u8, try cursor.take(CURSOR_MAGIC.len), &CURSOR_MAGIC)) return error.BadUsnCursorMagic;
    if (try cursor.readU16() != CURSOR_FORMAT_VERSION) return error.UnsupportedUsnCursorVersion;
    const filesystem_byte = try cursor.readByte();
    _ = try cursor.take(5);
    const root_hi = try cursor.readU64();
    const root_lo = try cursor.readU64();
    const volume_serial_number = try cursor.readU32();
    _ = try cursor.readU32();
    const journal_id = try cursor.readU64();
    const first_usn = try cursor.readI64();
    const next_usn = try cursor.readI64();
    const lowest_valid_usn = try cursor.readI64();
    if (cursor.remaining() != 0) return error.TrailingUsnCursorData;

    const filesystem = fileSystemKindFromByte(filesystem_byte) orelse return error.UnsupportedJournalFileSystem;
    const volume = VolumeIdentity{
        .root_fingerprint = (@as(RootFingerprint, root_hi) << 64) | @as(RootFingerprint, root_lo),
        .volume_serial_number = volume_serial_number,
        .filesystem = filesystem,
    };
    if (volume.root_fingerprint != expected_volume.root_fingerprint or
        volume.volume_serial_number != expected_volume.volume_serial_number or
        volume.filesystem != expected_volume.filesystem)
    {
        return error.WrongUsnCursorVolume;
    }
    return try cursorFromJournalData(volume, .{
        .usn_journal_id = journal_id,
        .first_usn = first_usn,
        .next_usn = next_usn,
        .lowest_valid_usn = lowest_valid_usn,
    });
}

pub fn publishJournalCursor(io: std.Io, allocator: std.mem.Allocator, paths: JournalPaths, cursor: JournalCursor) !void {
    const bytes = try serializeJournalCursor(allocator, cursor);
    defer allocator.free(bytes);
    try publishJournalCursorBytes(io, paths, bytes);
}

pub fn publishJournalCursorBytes(io: std.Io, paths: JournalPaths, bytes: []const u8) !void {
    if (bytes.len == 0) return error.EmptyUsnCursor;

    try std.Io.Dir.cwd().createDirPath(io, paths.journals_dir);
    var atomic_file = try std.Io.Dir.cwd().createFileAtomic(io, paths.cursor_path, .{ .replace = true });
    defer atomic_file.deinit(io);
    try atomic_file.file.writeStreamingAll(io, bytes);
    try atomic_file.file.sync(io);
    try atomic_file.replace(io);
}

pub fn tryLoadJournalCursor(io: std.Io, allocator: std.mem.Allocator, path: []const u8, expected_volume: VolumeIdentity) !?JournalCursor {
    const bytes = std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(CURSOR_READ_LIMIT)) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    defer allocator.free(bytes);
    return parseJournalCursorForVolume(bytes, expected_volume) catch null;
}

fn validateJournalCursor(cursor: JournalCursor) !void {
    if (!cursor.volume.supportsUsn()) return error.UnsupportedJournalFileSystem;
    if (cursor.usn_journal_id == 0) return error.InvalidUsnJournalId;
    if (cursor.next_usn < cursor.first_usn) return error.InvalidUsnRange;
    if (cursor.lowest_valid_usn < cursor.first_usn) return error.InvalidUsnRange;
    if (cursor.lowest_valid_usn > cursor.next_usn) return error.InvalidUsnRange;
}

fn parseRecordSummary(bytes: []const u8) !UsnRecordSummary {
    if (bytes.len < @sizeOf(UsnRecordHeader)) return error.TruncatedUsnRecord;
    var cursor = ByteCursor{ .bytes = bytes };
    const record_length = try cursor.readU32();
    const major_version = try cursor.readU16();
    const minor_version = try cursor.readU16();
    if (record_length < @sizeOf(UsnRecordHeader)) return error.InvalidUsnRecordLength;
    if (record_length > bytes.len) return error.TruncatedUsnRecord;

    const reason_offset: usize, const file_name_length_offset: usize, const file_name_offset_offset: usize = switch (major_version) {
        2 => .{ 40, 56, 58 },
        3 => .{ 56, 72, 74 },
        else => return error.UnsupportedUsnRecordVersion,
    };
    if (record_length < file_name_offset_offset + @sizeOf(u16)) return error.TruncatedUsnRecord;

    const reason = readU32At(bytes, reason_offset);
    const file_name_length = readU16At(bytes, file_name_length_offset);
    const file_name_offset = readU16At(bytes, file_name_offset_offset);
    if (@as(usize, file_name_offset) + file_name_length > record_length) return error.InvalidUsnRecordNameBounds;

    return .{
        .major_version = major_version,
        .minor_version = minor_version,
        .record_length = record_length,
        .reason = reason,
        .file_name_offset = file_name_offset,
        .file_name_length = file_name_length,
    };
}

fn readU16At(bytes: []const u8, offset: usize) u16 {
    return @as(u16, bytes[offset]) | (@as(u16, bytes[offset + 1]) << 8);
}

fn readU32At(bytes: []const u8, offset: usize) u32 {
    return @as(u32, bytes[offset]) |
        (@as(u32, bytes[offset + 1]) << 8) |
        (@as(u32, bytes[offset + 2]) << 16) |
        (@as(u32, bytes[offset + 3]) << 24);
}

fn fileSystemKindFromByte(byte: u8) ?FileSystemKind {
    return switch (byte) {
        @intFromEnum(FileSystemKind.unknown) => .unknown,
        @intFromEnum(FileSystemKind.ntfs) => .ntfs,
        @intFromEnum(FileSystemKind.refs) => .refs,
        @intFromEnum(FileSystemKind.unsupported) => .unsupported,
        else => null,
    };
}

fn appendU16(bytes: *std.ArrayList(u8), allocator: std.mem.Allocator, value: u16) !void {
    try bytes.append(allocator, @intCast(value & 0xff));
    try bytes.append(allocator, @intCast((value >> 8) & 0xff));
}

fn appendU32(bytes: *std.ArrayList(u8), allocator: std.mem.Allocator, value: u32) !void {
    var shift: u6 = 0;
    while (shift < 32) : (shift += 8) try bytes.append(allocator, @intCast((value >> @as(u5, @intCast(shift))) & 0xff));
}

fn appendU64(bytes: *std.ArrayList(u8), allocator: std.mem.Allocator, value: u64) !void {
    var shift: usize = 0;
    while (shift < 64) : (shift += 8) try bytes.append(allocator, @intCast((value >> @as(u6, @intCast(shift))) & 0xff));
}

fn appendI64(bytes: *std.ArrayList(u8), allocator: std.mem.Allocator, value: i64) !void {
    try appendU64(bytes, allocator, @bitCast(value));
}

const ByteCursor = struct {
    bytes: []const u8,
    index: usize = 0,

    fn take(self: *ByteCursor, len: usize) ![]const u8 {
        if (len > self.bytes.len - self.index) return error.TruncatedUsnCursor;
        const start = self.index;
        self.index += len;
        return self.bytes[start..self.index];
    }

    fn remaining(self: ByteCursor) usize {
        return self.bytes.len - self.index;
    }

    fn readByte(self: *ByteCursor) !u8 {
        return (try self.take(1))[0];
    }

    fn readU16(self: *ByteCursor) !u16 {
        const raw = try self.take(2);
        return @as(u16, raw[0]) | (@as(u16, raw[1]) << 8);
    }

    fn readU32(self: *ByteCursor) !u32 {
        const raw = try self.take(4);
        return @as(u32, raw[0]) |
            (@as(u32, raw[1]) << 8) |
            (@as(u32, raw[2]) << 16) |
            (@as(u32, raw[3]) << 24);
    }

    fn readU64(self: *ByteCursor) !u64 {
        const raw = try self.take(8);
        var value: u64 = 0;
        var index: usize = 0;
        while (index < raw.len) : (index += 1) value |= @as(u64, raw[index]) << @intCast(index * 8);
        return value;
    }

    fn readI64(self: *ByteCursor) !i64 {
        return @bitCast(try self.readU64());
    }
};

test "usn control codes match winioctl contract" {
    try std.testing.expectEqual(@as(windows.DWORD, 0x0009_00f4), FSCTL_QUERY_USN_JOURNAL);
    try std.testing.expectEqual(@as(windows.DWORD, 0x0009_00bb), FSCTL_READ_USN_JOURNAL);
}

test "usn ffi structs preserve Windows field offsets" {
    try std.testing.expectEqual(@as(usize, 0), @offsetOf(UsnJournalDataV0, "usn_journal_id"));
    try std.testing.expectEqual(@as(usize, 8), @offsetOf(UsnJournalDataV0, "first_usn"));
    try std.testing.expectEqual(@as(usize, 48), @offsetOf(UsnJournalDataV0, "allocation_delta"));
    try std.testing.expectEqual(@as(usize, 0), @offsetOf(ReadUsnJournalDataV1, "start_usn"));
    try std.testing.expectEqual(@as(usize, 40), @offsetOf(ReadUsnJournalDataV1, "min_major_version"));
    try std.testing.expectEqual(@as(usize, 42), @offsetOf(ReadUsnJournalDataV1, "max_major_version"));
    try std.testing.expectEqual(@as(usize, 58), @offsetOf(UsnRecordV2Prefix, "file_name_offset"));
    try std.testing.expectEqual(@as(usize, 74), @offsetOf(UsnRecordV3Prefix, "file_name_offset"));
}

test "usn read request defaults to ix delta-relevant reasons" {
    const request = readRequest(123, 456);
    try std.testing.expectEqual(@as(USN, 123), request.start_usn);
    try std.testing.expectEqual(@as(DWORDLONG, 456), request.usn_journal_id);
    try std.testing.expectEqual(USN_REASON_IX_DELTA_RELEVANT, request.reason_mask);
    try std.testing.expectEqual(@as(u16, 2), request.min_major_version);
    try std.testing.expectEqual(@as(u16, 3), request.max_major_version);
}

test "journal cursor captures volume identity journal id and usn range" {
    const volume = VolumeIdentity{
        .root_fingerprint = 0x1234,
        .volume_serial_number = 0xfeed,
        .filesystem = .ntfs,
    };
    const cursor = try cursorFromJournalData(volume, .{
        .usn_journal_id = 0x99,
        .first_usn = 10,
        .next_usn = 100,
        .lowest_valid_usn = 10,
    });

    try std.testing.expectEqual(@as(RootFingerprint, 0x1234), cursor.volume.root_fingerprint);
    try std.testing.expectEqual(@as(windows.DWORD, 0xfeed), cursor.volume.volume_serial_number);
    try std.testing.expectEqual(@as(DWORDLONG, 0x99), cursor.usn_journal_id);
    try std.testing.expectEqual(@as(USN, 100), cursor.next_usn);
}

test "journal cursor rejects unsupported or discontinuous identity" {
    const unsupported = VolumeIdentity{
        .root_fingerprint = 0x1234,
        .volume_serial_number = 0xfeed,
        .filesystem = .unsupported,
    };
    try std.testing.expectError(error.UnsupportedJournalFileSystem, cursorFromJournalData(unsupported, .{
        .usn_journal_id = 1,
        .first_usn = 1,
        .next_usn = 2,
        .lowest_valid_usn = 1,
    }));

    const ntfs = VolumeIdentity{
        .root_fingerprint = 0x1234,
        .volume_serial_number = 0xfeed,
        .filesystem = .ntfs,
    };
    try std.testing.expectError(error.InvalidUsnRange, cursorFromJournalData(ntfs, .{
        .usn_journal_id = 1,
        .first_usn = 10,
        .next_usn = 9,
        .lowest_valid_usn = 10,
    }));

    const previous = try cursorFromJournalData(ntfs, .{
        .usn_journal_id = 7,
        .first_usn = 1,
        .next_usn = 50,
        .lowest_valid_usn = 1,
    });
    const current = try cursorFromJournalData(ntfs, .{
        .usn_journal_id = 7,
        .first_usn = 1,
        .next_usn = 80,
        .lowest_valid_usn = 60,
    });
    try std.testing.expect(!previous.canContinue(current));
}

test "journal cursor serializes validates and rejects wrong volume" {
    const volume = VolumeIdentity{
        .root_fingerprint = 0x123456789abcdef,
        .volume_serial_number = 0xabcd,
        .filesystem = .ntfs,
    };
    const cursor = try cursorFromJournalData(volume, .{
        .usn_journal_id = 9,
        .first_usn = 1,
        .next_usn = 40,
        .lowest_valid_usn = 1,
    });
    const bytes = try serializeJournalCursor(std.testing.allocator, cursor);
    defer std.testing.allocator.free(bytes);

    const parsed = try parseJournalCursorForVolume(bytes, volume);
    try std.testing.expectEqual(cursor.usn_journal_id, parsed.usn_journal_id);
    try std.testing.expectEqual(cursor.next_usn, parsed.next_usn);

    const wrong_volume = VolumeIdentity{
        .root_fingerprint = 0x9999,
        .volume_serial_number = 0xabcd,
        .filesystem = .ntfs,
    };
    try std.testing.expectError(error.WrongUsnCursorVolume, parseJournalCursorForVolume(bytes, wrong_volume));
    try std.testing.expectError(error.TruncatedUsnCursor, parseJournalCursorForVolume(bytes[0 .. bytes.len - 1], volume));
}

test "journal cursor publishes atomically under journals directory" {
    const root = ".zig-cache\\ix-usn-cursor-publish-test";
    std.Io.Dir.cwd().deleteTree(std.testing.io, root) catch {};
    defer std.Io.Dir.cwd().deleteTree(std.testing.io, root) catch {};

    const paths = try buildJournalPaths(std.testing.allocator, root);
    defer paths.deinit(std.testing.allocator);
    const volume = VolumeIdentity{
        .root_fingerprint = 0x7777,
        .volume_serial_number = 0xaaaa,
        .filesystem = .ntfs,
    };
    const cursor = try cursorFromJournalData(volume, .{
        .usn_journal_id = 11,
        .first_usn = 5,
        .next_usn = 55,
        .lowest_valid_usn = 5,
    });

    try publishJournalCursor(std.testing.io, std.testing.allocator, paths, cursor);
    const loaded = (try tryLoadJournalCursor(std.testing.io, std.testing.allocator, paths.cursor_path, volume)).?;
    try std.testing.expectEqual(@as(USN, 55), loaded.next_usn);
    try std.testing.expectEqual(@as(DWORDLONG, 11), loaded.usn_journal_id);
}

test "journal availability classifies usable inaccessible and unsupported states" {
    const ntfs = VolumeIdentity{
        .root_fingerprint = 0x8888,
        .volume_serial_number = 0x1234,
        .filesystem = .ntfs,
    };
    const usable = classifyJournalAvailability(ntfs, .{ .journal = .{
        .usn_journal_id = 1,
        .first_usn = 1,
        .next_usn = 9,
        .lowest_valid_usn = 1,
    } });
    try std.testing.expect(usable.canUseUsn());
    try std.testing.expectEqual(@as(USN, 9), usable.cursor.?.next_usn);

    const inaccessible = classifyJournalAvailability(ntfs, .inaccessible);
    try std.testing.expect(!inaccessible.canUseUsn());
    try std.testing.expectEqual(JournalAvailabilityKind.inaccessible, inaccessible.kind);
    try std.testing.expectEqualStrings("journal_inaccessible", inaccessible.fallback_reason);

    const unsupported_volume = VolumeIdentity{
        .root_fingerprint = 0x8888,
        .volume_serial_number = 0x1234,
        .filesystem = .unsupported,
    };
    const unsupported = classifyJournalAvailability(unsupported_volume, .unsupported_filesystem);
    try std.testing.expect(!unsupported.canUseUsn());
    try std.testing.expectEqual(JournalAvailabilityKind.unsupported_filesystem, unsupported.kind);
    try std.testing.expectEqualStrings("unsupported_filesystem", unsupported.fallback_reason);
}

test "journal availability rejects malformed journal data as invalid" {
    const ntfs = VolumeIdentity{
        .root_fingerprint = 0x9999,
        .volume_serial_number = 0x1234,
        .filesystem = .ntfs,
    };
    const invalid = classifyJournalAvailability(ntfs, .{ .journal = .{
        .usn_journal_id = 0,
        .first_usn = 1,
        .next_usn = 9,
        .lowest_valid_usn = 1,
    } });
    try std.testing.expect(!invalid.canUseUsn());
    try std.testing.expectEqual(JournalAvailabilityKind.invalid_journal, invalid.kind);
    try std.testing.expectEqualStrings("invalid_journal", invalid.fallback_reason);
}

test "usn read batch request carries cursor timeout and byte wait" {
    const volume = VolumeIdentity{
        .root_fingerprint = 0x1111,
        .volume_serial_number = 0x2222,
        .filesystem = .ntfs,
    };
    const cursor = try cursorFromJournalData(volume, .{
        .usn_journal_id = 44,
        .first_usn = 1,
        .next_usn = 100,
        .lowest_valid_usn = 1,
    });
    const request = readBatchRequest(cursor, 250, 4096);
    try std.testing.expectEqual(@as(USN, 100), request.start_usn);
    try std.testing.expectEqual(@as(DWORDLONG, 44), request.usn_journal_id);
    try std.testing.expectEqual(@as(DWORDLONG, 250), request.timeout);
    try std.testing.expectEqual(@as(DWORDLONG, 4096), request.bytes_to_wait_for);
}

test "usn read batch parser reads bounded records" {
    var bytes = std.ArrayList(u8).empty;
    defer bytes.deinit(std.testing.allocator);
    try appendI64(&bytes, std.testing.allocator, 200);
    try appendFakeUsnRecordV2(&bytes, std.testing.allocator, USN_REASON_FILE_CREATE, "alpha.zig");
    try appendFakeUsnRecordV2(&bytes, std.testing.allocator, USN_REASON_DATA_EXTEND, "beta.zig");

    const parsed = try parseReadBatch(std.testing.allocator, bytes.items, .{ .max_records = 1 });
    defer parsed.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(USN, 200), parsed.next_start_usn);
    try std.testing.expectEqual(@as(usize, 1), parsed.records.len);
    try std.testing.expect(parsed.truncated_by_limit);
    try std.testing.expectEqual(USN_REASON_FILE_CREATE, parsed.records[0].reason);
}

test "usn read batch parser rejects hostile buffers and cancellation" {
    var bytes = std.ArrayList(u8).empty;
    defer bytes.deinit(std.testing.allocator);
    try appendI64(&bytes, std.testing.allocator, 200);
    try appendFakeUsnRecordV2(&bytes, std.testing.allocator, USN_REASON_FILE_DELETE, "gamma.zig");

    try std.testing.expectError(error.OperationCancelled, parseReadBatch(std.testing.allocator, bytes.items, .{ .cancelled = true }));
    try std.testing.expectError(error.UsnBatchTooLarge, parseReadBatch(std.testing.allocator, bytes.items, .{ .max_bytes = 4 }));
    try std.testing.expectError(error.TruncatedUsnRecord, parseReadBatch(std.testing.allocator, bytes.items[0 .. bytes.items.len - 1], .{}));
}

fn appendFakeUsnRecordV2(bytes: *std.ArrayList(u8), allocator: std.mem.Allocator, reason: windows.DWORD, name: []const u8) !void {
    const record_start = bytes.items.len;
    const file_name_offset: u16 = 60;
    const file_name_length: u16 = @intCast(name.len * 2);
    const record_length: u32 = file_name_offset + file_name_length;

    try appendU32(bytes, allocator, record_length);
    try appendU16(bytes, allocator, 2);
    try appendU16(bytes, allocator, 0);
    try appendU64(bytes, allocator, 1);
    try appendU64(bytes, allocator, 1);
    try appendI64(bytes, allocator, 101);
    try appendI64(bytes, allocator, 0);
    try appendU32(bytes, allocator, reason);
    try appendU32(bytes, allocator, 0);
    try appendU32(bytes, allocator, 0);
    try appendU32(bytes, allocator, 0);
    try appendU16(bytes, allocator, file_name_length);
    try appendU16(bytes, allocator, file_name_offset);
    while (bytes.items.len < record_start + file_name_offset) try bytes.append(allocator, 0);
    for (name) |byte| {
        try bytes.append(allocator, byte);
        try bytes.append(allocator, 0);
    }
}
