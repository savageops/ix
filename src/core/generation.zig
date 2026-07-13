const std = @import("std");
const catalog = @import("catalog.zig");
const state_dir = @import("state_dir.zig");

pub const MAGIC: [8]u8 = .{ 'I', 'X', 'G', 'E', 'N', '0', '0', '1' };
pub const FORMAT_VERSION: u16 = 1;
pub const INVALID_EPOCH: Epoch = 0;
pub const MANIFEST_READ_LIMIT: usize = 4 * 1024 * 1024;
const SEGMENT_VALIDATION_CHUNK_SIZE: usize = 64 * 1024;

pub const Epoch = u64;
pub const RootFingerprint = catalog.RootFingerprint;

pub const SegmentKind = enum(u8) {
    catalog = 1,
    postings = 2,
    signature = 3,
};

pub const ManifestFlags = packed struct(u32) {
    complete: bool = false,
    has_parent: bool = false,
    reserved: u30 = 0,
};

pub const GenerationManifestHeader = extern struct {
    magic: [8]u8 = MAGIC,
    version: u16 = FORMAT_VERSION,
    header_size: u16 = @sizeOf(GenerationManifestHeader),
    flags: ManifestFlags = .{},
    root_fingerprint_hi: u64 = 0,
    root_fingerprint_lo: u64 = 0,
    epoch: Epoch = INVALID_EPOCH,
    parent_epoch: Epoch = INVALID_EPOCH,
    segment_count: u64 = 0,

    pub fn rootFingerprint(self: GenerationManifestHeader) RootFingerprint {
        return (@as(RootFingerprint, self.root_fingerprint_hi) << 64) | @as(RootFingerprint, self.root_fingerprint_lo);
    }

    pub fn withRootFingerprint(value: RootFingerprint) GenerationManifestHeader {
        var header = GenerationManifestHeader{};
        header.root_fingerprint_hi = @intCast(value >> 64);
        header.root_fingerprint_lo = @intCast(value & std.math.maxInt(u64));
        return header;
    }
};

pub const GenerationSegment = struct {
    kind: SegmentKind,
    relative_path: []const u8,
    generation: Epoch,
    byte_len: u64 = 0,
    checksum: u64 = 0,
};

pub const SegmentPayload = struct {
    kind: SegmentKind,
    relative_path: []const u8,
    bytes: []const u8,
};

pub const GenerationManifest = struct {
    header: GenerationManifestHeader,
    segments: []const GenerationSegment,

    pub fn rootFingerprint(self: GenerationManifest) RootFingerprint {
        return self.header.rootFingerprint();
    }

    pub fn epoch(self: GenerationManifest) Epoch {
        return self.header.epoch;
    }

    pub fn parentEpoch(self: GenerationManifest) ?Epoch {
        if (!self.header.flags.has_parent) return null;
        return self.header.parent_epoch;
    }

    pub fn hasSegmentKind(self: GenerationManifest, kind: SegmentKind) bool {
        for (self.segments) |segment| {
            if (segment.kind == kind) return true;
        }
        return false;
    }
};

pub const GenerationPaths = struct {
    index_dir: []const u8,
    generations_dir: []const u8,
    generation_dir: []const u8,
    tmp_dir: []const u8,
    current_manifest_path: []const u8,
    manifest_path: []const u8,
    tmp_manifest_path: []const u8,

    pub fn deinit(self: GenerationPaths, allocator: std.mem.Allocator) void {
        allocator.free(self.index_dir);
        allocator.free(self.generations_dir);
        allocator.free(self.generation_dir);
        allocator.free(self.tmp_dir);
        allocator.free(self.current_manifest_path);
        allocator.free(self.manifest_path);
        allocator.free(self.tmp_manifest_path);
    }
};

pub const ReaderPin = struct {
    root_fingerprint: RootFingerprint,
    epoch: Epoch,
    parent_epoch: ?Epoch,
    segment_count: usize,

    pub fn fromHeader(header: GenerationManifestHeader) !ReaderPin {
        if (!header.flags.complete) return error.IncompleteGenerationManifest;
        if (header.epoch == INVALID_EPOCH) return error.InvalidGenerationEpoch;
        if (header.segment_count > std.math.maxInt(usize)) return error.GenerationSegmentCountOverflow;
        return .{
            .root_fingerprint = header.rootFingerprint(),
            .epoch = header.epoch,
            .parent_epoch = if (header.flags.has_parent) header.parent_epoch else null,
            .segment_count = @intCast(header.segment_count),
        };
    }
};

pub const CompactionPolicy = struct {
    min_segment_count: usize = 4,
    small_segment_bytes: u64 = 64 * 1024,
    dense_segment_bytes: u64 = 16 * 1024 * 1024,
    deleted_ratio_per_mille: u16 = 250,
};

pub const CompactionReasonFlags = packed struct(u8) {
    small_segment: bool = false,
    dense_segment: bool = false,
    deleted_entries: bool = false,
    reserved: u5 = 0,

    pub fn any(self: CompactionReasonFlags) bool {
        return self.small_segment or self.dense_segment or self.deleted_entries;
    }
};

pub const CompactionSegmentState = struct {
    segment: GenerationSegment,
    total_entries: u64 = 0,
    deleted_entries: u64 = 0,
    reader_pinned: bool = false,
};

pub const CompactionCandidate = struct {
    segment: GenerationSegment,
    reasons: CompactionReasonFlags,
};

pub const CompactedGenerationInput = struct {
    root_fingerprint: RootFingerprint,
    epoch: Epoch,
    parent_epoch: ?Epoch = null,
    catalog_bytes: []const u8,
    postings_bytes: []const u8,
};

pub const GenerationGcPolicy = struct {
    retain_newest: usize = 2,
};

pub fn readerPinRetainedAfterPublish(pin: ReaderPin, published_epoch: Epoch) bool {
    if (pin.epoch == INVALID_EPOCH) return false;
    return pin.epoch <= published_epoch;
}

pub fn planGenerationGc(
    allocator: std.mem.Allocator,
    epochs: []const Epoch,
    reader_pins: []const ReaderPin,
    current_epoch: Epoch,
    policy: GenerationGcPolicy,
) ![]Epoch {
    if (current_epoch == INVALID_EPOCH) return error.InvalidGenerationEpoch;

    const sorted_epochs = try allocator.dupe(Epoch, epochs);
    defer allocator.free(sorted_epochs);
    std.mem.sort(Epoch, sorted_epochs, {}, lessThanEpoch);

    var delete_epochs = std.ArrayList(Epoch).empty;
    errdefer delete_epochs.deinit(allocator);
    for (sorted_epochs) |epoch| {
        if (epoch == INVALID_EPOCH) continue;
        if (containsEpoch(delete_epochs.items, epoch)) continue;
        if (epoch >= current_epoch) continue;
        if (isReaderPinnedEpoch(epoch, reader_pins)) continue;
        if (isNewestRetainedEpoch(epoch, sorted_epochs, policy.retain_newest)) continue;
        try delete_epochs.append(allocator, epoch);
    }

    return delete_epochs.toOwnedSlice(allocator);
}

pub fn planCompaction(
    allocator: std.mem.Allocator,
    states: []const CompactionSegmentState,
    policy: CompactionPolicy,
) ![]CompactionCandidate {
    var candidates = std.ArrayList(CompactionCandidate).empty;
    errdefer candidates.deinit(allocator);
    const segment_pressure = states.len >= policy.min_segment_count;

    for (states) |state| {
        if (state.reader_pinned) continue;
        var reasons = CompactionReasonFlags{};
        if (segment_pressure and state.segment.byte_len <= policy.small_segment_bytes) {
            reasons.small_segment = true;
        }
        if (state.segment.byte_len >= policy.dense_segment_bytes) {
            reasons.dense_segment = true;
        }
        if (deletedRatioExceeded(state.deleted_entries, state.total_entries, policy.deleted_ratio_per_mille)) {
            reasons.deleted_entries = true;
        }
        if (reasons.any()) {
            try candidates.append(allocator, .{
                .segment = state.segment,
                .reasons = reasons,
            });
        }
    }

    return candidates.toOwnedSlice(allocator);
}

pub fn makeManifest(root_fingerprint: RootFingerprint, epoch: Epoch, parent_epoch: ?Epoch, segments: []const GenerationSegment) GenerationManifest {
    var header = GenerationManifestHeader.withRootFingerprint(root_fingerprint);
    header.epoch = epoch;
    header.segment_count = segments.len;
    header.flags.complete = true;
    if (parent_epoch) |parent| {
        header.flags.has_parent = true;
        header.parent_epoch = parent;
    }
    return .{
        .header = header,
        .segments = segments,
    };
}

pub fn buildGenerationPaths(allocator: std.mem.Allocator, root: []const u8, epoch: Epoch) !GenerationPaths {
    const identity = try catalog.identifyRoot(allocator, root);
    defer identity.deinit(allocator);
    const state = try state_dir.buildRootIndexState(allocator, identity.fingerprint);
    defer state.deinit(allocator);
    return buildGenerationPathsInIndexDir(allocator, state.index_dir, epoch);
}

pub fn buildGenerationPathsInIndexDir(allocator: std.mem.Allocator, index_root: []const u8, epoch: Epoch) !GenerationPaths {
    if (epoch == INVALID_EPOCH) return error.InvalidGenerationEpoch;

    const epoch_text = try std.fmt.allocPrint(allocator, "{d}", .{epoch});
    defer allocator.free(epoch_text);

    const index_dir = try allocator.dupe(u8, index_root);
    errdefer allocator.free(index_dir);
    const generations_dir = try std.fs.path.join(allocator, &.{ index_dir, "generations" });
    errdefer allocator.free(generations_dir);
    const generation_dir = try std.fs.path.join(allocator, &.{ generations_dir, epoch_text });
    errdefer allocator.free(generation_dir);
    const tmp_dir = try std.fs.path.join(allocator, &.{ index_dir, "tmp", epoch_text });
    errdefer allocator.free(tmp_dir);
    const current_manifest_path = try std.fs.path.join(allocator, &.{ index_dir, "current.ixgen" });
    errdefer allocator.free(current_manifest_path);
    const manifest_path = try std.fs.path.join(allocator, &.{ generation_dir, "manifest.ixgen" });
    errdefer allocator.free(manifest_path);
    const tmp_manifest_path = try std.fs.path.join(allocator, &.{ tmp_dir, "manifest.ixgen.tmp" });
    errdefer allocator.free(tmp_manifest_path);

    return .{
        .index_dir = index_dir,
        .generations_dir = generations_dir,
        .generation_dir = generation_dir,
        .tmp_dir = tmp_dir,
        .current_manifest_path = current_manifest_path,
        .manifest_path = manifest_path,
        .tmp_manifest_path = tmp_manifest_path,
    };
}

pub fn publishManifestBytes(io: std.Io, paths: GenerationPaths, bytes: []const u8) !void {
    if (bytes.len == 0) return error.EmptyGenerationManifest;

    try std.Io.Dir.cwd().createDirPath(io, paths.generation_dir);
    try std.Io.Dir.cwd().createDirPath(io, paths.tmp_dir);

    var atomic_file = try std.Io.Dir.cwd().createFileAtomic(io, paths.manifest_path, .{ .replace = true });
    defer atomic_file.deinit(io);
    try atomic_file.file.writeStreamingAll(io, bytes);
    try atomic_file.file.sync(io);
    try atomic_file.replace(io);
}

pub fn publishGenerationPayloads(
    io: std.Io,
    allocator: std.mem.Allocator,
    paths: GenerationPaths,
    root_fingerprint: RootFingerprint,
    epoch: Epoch,
    parent_epoch: ?Epoch,
    payloads: []const SegmentPayload,
) !ReaderPin {
    if (payloads.len == 0) return error.EmptyGenerationManifest;

    try std.Io.Dir.cwd().createDirPath(io, paths.generation_dir);
    try std.Io.Dir.cwd().createDirPath(io, paths.tmp_dir);

    const segments = try allocator.alloc(GenerationSegment, payloads.len);
    defer allocator.free(segments);

    for (payloads, 0..) |payload, index| {
        if (payload.bytes.len == 0) return error.EmptyGenerationSegment;
        segments[index] = .{
            .kind = payload.kind,
            .relative_path = payload.relative_path,
            .generation = epoch,
            .byte_len = payload.bytes.len,
            .checksum = std.hash.Wyhash.hash(0, payload.bytes),
        };
        try validateManifestShape(makeManifest(root_fingerprint, epoch, parent_epoch, segments[0 .. index + 1]));
        try publishGenerationFileBytes(io, allocator, paths, payload.relative_path, payload.bytes);
    }

    const manifest = makeManifest(root_fingerprint, epoch, parent_epoch, segments);
    const manifest_bytes = try serializeManifest(allocator, manifest);
    defer allocator.free(manifest_bytes);
    try publishManifestBytes(io, paths, manifest_bytes);
    try publishCurrentManifestBytes(io, paths, manifest_bytes);
    return try pinManifestBytesForRoot(manifest_bytes, root_fingerprint);
}

pub fn publishCompactedGeneration(
    io: std.Io,
    allocator: std.mem.Allocator,
    paths: GenerationPaths,
    input: CompactedGenerationInput,
) !ReaderPin {
    if (input.catalog_bytes.len == 0) return error.EmptyGenerationSegment;
    if (input.postings_bytes.len == 0) return error.EmptyGenerationSegment;

    const payloads = [_]SegmentPayload{
        .{ .kind = .catalog, .relative_path = "catalog.ixcat", .bytes = input.catalog_bytes },
        .{ .kind = .postings, .relative_path = "postings.ixpost", .bytes = input.postings_bytes },
    };
    return publishGenerationPayloads(io, allocator, paths, input.root_fingerprint, input.epoch, input.parent_epoch, &payloads);
}

pub fn publishCurrentManifestBytes(io: std.Io, paths: GenerationPaths, bytes: []const u8) !void {
    if (bytes.len == 0) return error.EmptyGenerationManifest;

    try std.Io.Dir.cwd().createDirPath(io, paths.index_dir);
    var atomic_file = try std.Io.Dir.cwd().createFileAtomic(io, paths.current_manifest_path, .{ .replace = true });
    defer atomic_file.deinit(io);
    try atomic_file.file.writeStreamingAll(io, bytes);
    try atomic_file.file.sync(io);
    try atomic_file.replace(io);
}

fn publishGenerationFileBytes(io: std.Io, allocator: std.mem.Allocator, paths: GenerationPaths, relative_path: []const u8, bytes: []const u8) !void {
    if (relative_path.len == 0) return error.EmptyGenerationSegmentPath;
    if (std.fs.path.isAbsolute(relative_path)) return error.AbsoluteGenerationSegmentPath;

    const visible_path = try std.fs.path.join(allocator, &.{ paths.generation_dir, relative_path });
    defer allocator.free(visible_path);
    var atomic_file = try std.Io.Dir.cwd().createFileAtomic(io, visible_path, .{ .replace = true });
    defer atomic_file.deinit(io);
    try atomic_file.file.writeStreamingAll(io, bytes);
    try atomic_file.file.sync(io);
    try atomic_file.replace(io);
}

pub fn serializeManifest(allocator: std.mem.Allocator, manifest: GenerationManifest) ![]u8 {
    try validateManifestShape(manifest);

    var bytes = std.ArrayList(u8).empty;
    errdefer bytes.deinit(allocator);

    try writeHeader(&bytes, allocator, manifest.header);
    for (manifest.segments) |segment| {
        try bytes.append(allocator, @intFromEnum(segment.kind));
        try bytes.appendNTimes(allocator, 0, 3);
        try appendU64(&bytes, allocator, segment.generation);
        try appendU64(&bytes, allocator, segment.byte_len);
        try appendU64(&bytes, allocator, segment.checksum);
        try appendU32(&bytes, allocator, @intCast(segment.relative_path.len));
        try bytes.appendSlice(allocator, segment.relative_path);
    }

    return bytes.toOwnedSlice(allocator);
}

pub fn validateManifestBytesForRoot(bytes: []const u8, expected_root: RootFingerprint) !GenerationManifestHeader {
    var cursor = Cursor{ .bytes = bytes };
    const header = try readHeader(&cursor);
    if (!std.mem.eql(u8, &header.magic, &MAGIC)) return error.BadGenerationMagic;
    if (header.version > FORMAT_VERSION) return error.UnsupportedGenerationVersion;
    if (header.header_size != @sizeOf(GenerationManifestHeader)) return error.BadGenerationHeaderSize;
    if (!header.flags.complete) return error.IncompleteGenerationManifest;
    if (header.rootFingerprint() != expected_root) return error.WrongGenerationRoot;
    if (header.epoch == INVALID_EPOCH) return error.InvalidGenerationEpoch;
    if (header.flags.has_parent and header.parent_epoch >= header.epoch) return error.InvalidParentGeneration;
    if (header.segment_count > std.math.maxInt(usize)) return error.GenerationSegmentCountOverflow;

    var index: usize = 0;
    while (index < header.segment_count) : (index += 1) {
        _ = try readSegmentRecord(&cursor, header.epoch);
    }
    if (cursor.remaining() != 0) return error.TrailingGenerationManifestData;
    return header;
}

pub fn pinManifestBytesForRoot(bytes: []const u8, expected_root: RootFingerprint) !ReaderPin {
    return ReaderPin.fromHeader(try validateManifestBytesForRoot(bytes, expected_root));
}

pub fn tryPinCurrentGeneration(io: std.Io, allocator: std.mem.Allocator, manifest_path: []const u8, expected_root: RootFingerprint) !?ReaderPin {
    const bytes = std.Io.Dir.cwd().readFileAlloc(io, manifest_path, allocator, .limited(MANIFEST_READ_LIMIT)) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    defer allocator.free(bytes);
    return pinManifestBytesForRoot(bytes, expected_root) catch null;
}

/// Reads and parses the current generation manifest WITHOUT validating
/// segment payload checksums. Returns a ReaderPin whose epoch can be used
/// for cache lookup. The caller MUST run `validatePinnedPayloads` before
/// reading any segment payload (catalog/postings) if the cache misses.
///
/// This split exists because payload validation reads every segment file
/// in full (catalog + postings + signature) to verify Wyhash checksums —
/// for the linux bench corpus that's ~937 MB read on every warm query.
/// On a cache hit the validated candidate list is already on disk and
/// the payload bytes are never touched, so the checksum re-read is pure
/// overhead. Pinning the manifest alone is a 198-byte file read.
pub fn pinCurrentGenerationManifest(
    io: std.Io,
    allocator: std.mem.Allocator,
    manifest_path: []const u8,
    expected_root: RootFingerprint,
) !ReaderPin {
    const bytes = std.Io.Dir.cwd().readFileAlloc(io, manifest_path, allocator, .limited(MANIFEST_READ_LIMIT)) catch |err| switch (err) {
        error.FileNotFound => return error.NoCurrentGeneration,
        else => return err,
    };
    defer allocator.free(bytes);
    return pinManifestBytesForRoot(bytes, expected_root);
}

/// Validates segment payload checksums for a pin obtained from
/// `pinCurrentGenerationManifest`. Runs the expensive full-segment read
/// only when the cache misses and the caller is about to touch the
/// catalog/postings payloads.
pub fn validatePinnedPayloads(
    io: std.Io,
    allocator: std.mem.Allocator,
    index_dir: []const u8,
    pin: ReaderPin,
) !void {
    const paths = try buildGenerationPathsInIndexDir(allocator, index_dir, pin.epoch);
    defer paths.deinit(allocator);

    // Re-read the manifest to get segment records. The pin carries the
    // segment count but not the per-segment paths/checksums (those are
    // validated from the manifest bytes directly).
    const manifest_bytes = std.Io.Dir.cwd().readFileAlloc(io, paths.current_manifest_path, allocator, .limited(MANIFEST_READ_LIMIT)) catch return error.NoCurrentGeneration;
    defer allocator.free(manifest_bytes);

    var cursor = Cursor{ .bytes = manifest_bytes };
    const header = try readHeader(&cursor);
    _ = try validateManifestHeaderForRoot(header, pin.root_fingerprint);

    var index: usize = 0;
    while (index < pin.segment_count) : (index += 1) {
        const segment = try readSegmentRecord(&cursor, pin.epoch);
        try validatePublishedSegmentPayload(io, allocator, paths.generation_dir, segment);
    }
    if (cursor.remaining() != 0) return error.TrailingGenerationManifestData;
}

pub fn tryPinCurrentGenerationWithPayloads(
    io: std.Io,
    allocator: std.mem.Allocator,
    index_dir: []const u8,
    manifest_path: []const u8,
    expected_root: RootFingerprint,
) !?ReaderPin {
    return pinCurrentGenerationWithPayloads(io, allocator, index_dir, manifest_path, expected_root) catch |err| switch (err) {
        error.NoCurrentGeneration => return null,
        else => return null,
    };
}

pub fn pinCurrentGenerationWithPayloads(
    io: std.Io,
    allocator: std.mem.Allocator,
    index_dir: []const u8,
    manifest_path: []const u8,
    expected_root: RootFingerprint,
) !ReaderPin {
    const bytes = std.Io.Dir.cwd().readFileAlloc(io, manifest_path, allocator, .limited(MANIFEST_READ_LIMIT)) catch |err| switch (err) {
        error.FileNotFound => return error.NoCurrentGeneration,
        else => return err,
    };
    defer allocator.free(bytes);
    return pinManifestBytesAndPayloadsForRoot(io, allocator, index_dir, bytes, expected_root);
}

pub fn pinManifestBytesAndPayloadsForRoot(
    io: std.Io,
    allocator: std.mem.Allocator,
    index_dir: []const u8,
    bytes: []const u8,
    expected_root: RootFingerprint,
) !ReaderPin {
    var cursor = Cursor{ .bytes = bytes };
    const header = try readHeader(&cursor);
    const pin = try ReaderPin.fromHeader(try validateManifestHeaderForRoot(header, expected_root));
    const paths = try buildGenerationPathsInIndexDir(allocator, index_dir, pin.epoch);
    defer paths.deinit(allocator);

    var index: usize = 0;
    while (index < pin.segment_count) : (index += 1) {
        const segment = try readSegmentRecord(&cursor, pin.epoch);
        try validatePublishedSegmentPayload(io, allocator, paths.generation_dir, segment);
    }
    if (cursor.remaining() != 0) return error.TrailingGenerationManifestData;
    return pin;
}

pub fn validateManifestShape(manifest: GenerationManifest) !void {
    if (!std.mem.eql(u8, &manifest.header.magic, &MAGIC)) return error.BadGenerationMagic;
    if (manifest.header.version != FORMAT_VERSION) return error.UnsupportedGenerationVersion;
    if (!manifest.header.flags.complete) return error.IncompleteGenerationManifest;
    if (manifest.rootFingerprint() == 0) return error.InvalidGenerationRoot;
    if (manifest.header.epoch == INVALID_EPOCH) return error.InvalidGenerationEpoch;
    if (manifest.header.flags.has_parent and manifest.header.parent_epoch >= manifest.header.epoch) return error.InvalidParentGeneration;
    if (manifest.header.segment_count != manifest.segments.len) return error.GenerationSegmentCountMismatch;

    for (manifest.segments) |segment| {
        if (segment.relative_path.len == 0) return error.EmptyGenerationSegmentPath;
        if (std.fs.path.isAbsolute(segment.relative_path)) return error.AbsoluteGenerationSegmentPath;
        if (segment.generation != manifest.header.epoch) return error.WrongSegmentGeneration;
    }
}

fn validateManifestHeaderForRoot(header: GenerationManifestHeader, expected_root: RootFingerprint) !GenerationManifestHeader {
    if (!std.mem.eql(u8, &header.magic, &MAGIC)) return error.BadGenerationMagic;
    if (header.version > FORMAT_VERSION) return error.UnsupportedGenerationVersion;
    if (header.header_size != @sizeOf(GenerationManifestHeader)) return error.BadGenerationHeaderSize;
    if (!header.flags.complete) return error.IncompleteGenerationManifest;
    if (header.rootFingerprint() != expected_root) return error.WrongGenerationRoot;
    if (header.epoch == INVALID_EPOCH) return error.InvalidGenerationEpoch;
    if (header.flags.has_parent and header.parent_epoch >= header.epoch) return error.InvalidParentGeneration;
    if (header.segment_count > std.math.maxInt(usize)) return error.GenerationSegmentCountOverflow;
    return header;
}

fn validatePublishedSegmentPayload(
    io: std.Io,
    allocator: std.mem.Allocator,
    generation_dir: []const u8,
    segment: GenerationSegment,
) !void {
    if (segment.byte_len > std.math.maxInt(usize) - 1) return error.GenerationSegmentTooLarge;
    const segment_path = try std.fs.path.join(allocator, &.{ generation_dir, segment.relative_path });
    defer allocator.free(segment_path);
    try validatePublishedSegmentPayloadFromFile(io, segment_path, segment);
}

fn validatePublishedSegmentPayloadFromFile(
    io: std.Io,
    segment_path: []const u8,
    segment: GenerationSegment,
) !void {
    var file = std.Io.Dir.cwd().openFile(io, segment_path, .{ .allow_directory = false }) catch |err| switch (err) {
        error.FileNotFound => return error.MissingGenerationSegment,
        else => return err,
    };
    defer file.close(io);

    var hasher = std.hash.Wyhash.init(0);
    var buffer: [SEGMENT_VALIDATION_CHUNK_SIZE]u8 = undefined;
    var offset: u64 = 0;
    while (offset < segment.byte_len) {
        const remaining = segment.byte_len - offset;
        const target_len: usize = @intCast(@min(@as(u64, buffer.len), remaining));
        const read_len = try file.readPositionalAll(io, buffer[0..target_len], offset);
        if (read_len != target_len) return error.GenerationSegmentLengthMismatch;
        hasher.update(buffer[0..read_len]);
        offset += read_len;
    }

    var extra: [1]u8 = undefined;
    const extra_len = try file.readPositionalAll(io, &extra, segment.byte_len);
    if (extra_len != 0) return error.GenerationSegmentLengthMismatch;
    if (hasher.final() != segment.checksum) return error.GenerationSegmentChecksumMismatch;
}

fn writeHeader(bytes: *std.ArrayList(u8), allocator: std.mem.Allocator, header: GenerationManifestHeader) !void {
    try bytes.appendSlice(allocator, &header.magic);
    try appendU16(bytes, allocator, header.version);
    try appendU16(bytes, allocator, header.header_size);
    try appendU32(bytes, allocator, manifestFlagsBits(header.flags));
    try appendU64(bytes, allocator, header.root_fingerprint_hi);
    try appendU64(bytes, allocator, header.root_fingerprint_lo);
    try appendU64(bytes, allocator, header.epoch);
    try appendU64(bytes, allocator, header.parent_epoch);
    try appendU64(bytes, allocator, header.segment_count);
}

fn readHeader(cursor: *Cursor) !GenerationManifestHeader {
    var header = GenerationManifestHeader{};
    @memcpy(&header.magic, try cursor.take(MAGIC.len));
    header.version = try cursor.readU16();
    header.header_size = try cursor.readU16();
    header.flags = manifestFlagsFromBits(try cursor.readU32());
    header.root_fingerprint_hi = try cursor.readU64();
    header.root_fingerprint_lo = try cursor.readU64();
    header.epoch = try cursor.readU64();
    header.parent_epoch = try cursor.readU64();
    header.segment_count = try cursor.readU64();
    return header;
}

fn readSegmentRecord(cursor: *Cursor, expected_epoch: Epoch) !GenerationSegment {
    const kind = try segmentKindFromByte(try cursor.readByte());
    _ = try cursor.take(3);
    const generation = try cursor.readU64();
    const byte_len = try cursor.readU64();
    const checksum = try cursor.readU64();
    const path_len = try cursor.readU32();
    const path = try cursor.take(path_len);
    if (path.len == 0) return error.EmptyGenerationSegmentPath;
    if (std.fs.path.isAbsolute(path)) return error.AbsoluteGenerationSegmentPath;
    if (generation != expected_epoch) return error.WrongSegmentGeneration;
    return .{
        .kind = kind,
        .relative_path = path,
        .generation = generation,
        .byte_len = byte_len,
        .checksum = checksum,
    };
}

fn deletedRatioExceeded(deleted_entries: u64, total_entries: u64, threshold_per_mille: u16) bool {
    if (total_entries == 0 or deleted_entries == 0) return false;
    return deleted_entries * 1000 >= total_entries * @as(u64, threshold_per_mille);
}

fn lessThanEpoch(_: void, lhs: Epoch, rhs: Epoch) bool {
    return lhs < rhs;
}

fn containsEpoch(epochs: []const Epoch, target: Epoch) bool {
    for (epochs) |epoch| {
        if (epoch == target) return true;
    }
    return false;
}

fn isReaderPinnedEpoch(epoch: Epoch, pins: []const ReaderPin) bool {
    for (pins) |pin| {
        if (pin.epoch == epoch) return true;
        if (pin.parent_epoch != null and pin.parent_epoch.? == epoch) return true;
    }
    return false;
}

fn isNewestRetainedEpoch(epoch: Epoch, sorted_epochs: []const Epoch, retain_newest: usize) bool {
    if (retain_newest == 0) return false;

    var newer_count: usize = 0;
    for (sorted_epochs) |candidate| {
        if (candidate != INVALID_EPOCH and candidate > epoch) newer_count += 1;
    }
    return newer_count < retain_newest;
}

fn segmentKindFromByte(byte: u8) !SegmentKind {
    return switch (byte) {
        @intFromEnum(SegmentKind.catalog) => .catalog,
        @intFromEnum(SegmentKind.postings) => .postings,
        @intFromEnum(SegmentKind.signature) => .signature,
        else => error.UnknownGenerationSegment,
    };
}

fn manifestFlagsBits(flags: ManifestFlags) u32 {
    var bits: u32 = 0;
    if (flags.complete) bits |= 1;
    if (flags.has_parent) bits |= 2;
    bits |= @as(u32, flags.reserved) << 2;
    return bits;
}

fn manifestFlagsFromBits(bits: u32) ManifestFlags {
    return .{
        .complete = (bits & 1) != 0,
        .has_parent = (bits & 2) != 0,
        .reserved = @intCast(bits >> 2),
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

const Cursor = struct {
    bytes: []const u8,
    index: usize = 0,

    fn take(self: *Cursor, len: usize) ![]const u8 {
        if (len > self.bytes.len - self.index) return error.TruncatedGenerationManifest;
        const start = self.index;
        self.index += len;
        return self.bytes[start..self.index];
    }

    fn remaining(self: Cursor) usize {
        return self.bytes.len - self.index;
    }

    fn readByte(self: *Cursor) !u8 {
        return (try self.take(1))[0];
    }

    fn readU16(self: *Cursor) !u16 {
        const raw = try self.take(2);
        return @as(u16, raw[0]) | (@as(u16, raw[1]) << 8);
    }

    fn readU32(self: *Cursor) !u32 {
        const raw = try self.take(4);
        return @as(u32, raw[0]) |
            (@as(u32, raw[1]) << 8) |
            (@as(u32, raw[2]) << 16) |
            (@as(u32, raw[3]) << 24);
    }

    fn readU64(self: *Cursor) !u64 {
        const raw = try self.take(8);
        var value: u64 = 0;
        var index: usize = 0;
        while (index < raw.len) : (index += 1) value |= @as(u64, raw[index]) << @intCast(index * 8);
        return value;
    }
};

test "generation manifest skeleton pins root epoch parent and segments" {
    const root: RootFingerprint = 0x1234;
    const segments = [_]GenerationSegment{
        .{ .kind = .catalog, .relative_path = "catalog.ixcat", .generation = 7, .byte_len = 128 },
        .{ .kind = .postings, .relative_path = "postings.ixpost", .generation = 7, .byte_len = 256 },
    };

    const manifest = makeManifest(root, 7, 6, &segments);
    try validateManifestShape(manifest);

    try std.testing.expectEqual(root, manifest.rootFingerprint());
    try std.testing.expectEqual(@as(Epoch, 7), manifest.epoch());
    try std.testing.expectEqual(@as(?Epoch, 6), manifest.parentEpoch());
    try std.testing.expect(manifest.hasSegmentKind(.catalog));
    try std.testing.expect(manifest.hasSegmentKind(.postings));
}

test "generation manifest fails closed for incomplete or partial shapes" {
    const root: RootFingerprint = 0x1234;
    const segments = [_]GenerationSegment{
        .{ .kind = .catalog, .relative_path = "catalog.ixcat", .generation = 3 },
    };

    var incomplete = makeManifest(root, 3, null, &segments);
    incomplete.header.flags.complete = false;
    try std.testing.expectError(error.IncompleteGenerationManifest, validateManifestShape(incomplete));

    var wrong_epoch = makeManifest(root, 3, null, &segments);
    wrong_epoch.segments = &[_]GenerationSegment{
        .{ .kind = .catalog, .relative_path = "catalog.ixcat", .generation = 2 },
    };
    try std.testing.expectError(error.WrongSegmentGeneration, validateManifestShape(wrong_epoch));

    const absolute = makeManifest(root, 3, null, &[_]GenerationSegment{
        .{ .kind = .catalog, .relative_path = "C:\\tmp\\catalog.ixcat", .generation = 3 },
    });
    try std.testing.expectError(error.AbsoluteGenerationSegmentPath, validateManifestShape(absolute));
}

test "generation storage paths isolate tmp and visible epoch directories" {
    const paths = try buildGenerationPathsInIndexDir(std.testing.allocator, ".zig-cache\\ix-generation-layout-test", 42);
    defer paths.deinit(std.testing.allocator);

    try std.testing.expect(std.mem.endsWith(u8, paths.index_dir, "ix-generation-layout-test"));
    try std.testing.expect(std.mem.indexOf(u8, paths.generation_dir, "generations") != null);
    try std.testing.expect(std.mem.endsWith(u8, paths.generation_dir, "42"));
    try std.testing.expect(std.mem.indexOf(u8, paths.tmp_dir, "tmp") != null);
    try std.testing.expect(std.mem.endsWith(u8, paths.current_manifest_path, "current.ixgen"));
    try std.testing.expect(std.mem.endsWith(u8, paths.manifest_path, "manifest.ixgen"));
    try std.testing.expect(std.mem.endsWith(u8, paths.tmp_manifest_path, "manifest.ixgen.tmp"));
}

test "generation storage paths reject invalid visible epoch" {
    try std.testing.expectError(error.InvalidGenerationEpoch, buildGenerationPathsInIndexDir(std.testing.allocator, ".", INVALID_EPOCH));
}

test "generation root helper uses canonical state directory outside scanned root" {
    const scanned_root = ".zig-cache\\ix-generation-canonical-root-test";
    const paths = try buildGenerationPaths(std.testing.allocator, scanned_root, 43);
    defer paths.deinit(std.testing.allocator);
    const state_root = try state_dir.resolveStateDir(std.testing.allocator);
    defer std.testing.allocator.free(state_root);

    try std.testing.expect(std.mem.startsWith(u8, paths.index_dir, state_root));
    try std.testing.expect(std.mem.indexOf(u8, paths.index_dir, scanned_root) == null);
    try std.testing.expect(std.mem.indexOf(u8, paths.index_dir, "roots") != null);
}

test "generation manifest publish exposes only replaced visible manifest" {
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const root = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}", .{&tmp.sub_path});
    defer std.testing.allocator.free(root);

    const paths = try buildGenerationPathsInIndexDir(std.testing.allocator, root, 9);
    defer paths.deinit(std.testing.allocator);

    try publishManifestBytes(std.testing.io, paths, "IXGEN-A");
    try publishManifestBytes(std.testing.io, paths, "IXGEN-B");

    var buffer: [64]u8 = undefined;
    const visible = try std.Io.Dir.cwd().readFile(std.testing.io, paths.manifest_path, &buffer);
    try std.testing.expectEqualStrings("IXGEN-B", visible);
}

test "generation manifest publish rejects empty manifest body" {
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const root = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}", .{&tmp.sub_path});
    defer std.testing.allocator.free(root);

    const paths = try buildGenerationPathsInIndexDir(std.testing.allocator, root, 1);
    defer paths.deinit(std.testing.allocator);

    try std.testing.expectError(error.EmptyGenerationManifest, publishManifestBytes(std.testing.io, paths, ""));
}

test "generation manifest bytes validate root version and segment records" {
    const root: RootFingerprint = 0x1234;
    const segments = [_]GenerationSegment{
        .{ .kind = .catalog, .relative_path = "catalog.ixcat", .generation = 11 },
        .{ .kind = .postings, .relative_path = "postings.ixpost", .generation = 11 },
    };
    const manifest = makeManifest(root, 11, 10, &segments);
    const bytes = try serializeManifest(std.testing.allocator, manifest);
    defer std.testing.allocator.free(bytes);

    const header = try validateManifestBytesForRoot(bytes, root);
    try std.testing.expectEqual(@as(Epoch, 11), header.epoch);
    try std.testing.expectError(error.WrongGenerationRoot, validateManifestBytesForRoot(bytes, 0x9999));

    var future = try std.testing.allocator.dupe(u8, bytes);
    defer std.testing.allocator.free(future);
    future[MAGIC.len] = FORMAT_VERSION + 1;
    try std.testing.expectError(error.UnsupportedGenerationVersion, validateManifestBytesForRoot(future, root));

    try std.testing.expectError(error.TruncatedGenerationManifest, validateManifestBytesForRoot(bytes[0 .. bytes.len - 1], root));

    var unknown = try std.testing.allocator.dupe(u8, bytes);
    defer std.testing.allocator.free(unknown);
    unknown[@sizeOf(GenerationManifestHeader)] = 99;
    try std.testing.expectError(error.UnknownGenerationSegment, validateManifestBytesForRoot(unknown, root));
}

test "generation reader pin selects only validated complete epoch" {
    const root: RootFingerprint = 0x5678;
    const segments = [_]GenerationSegment{
        .{ .kind = .catalog, .relative_path = "catalog.ixcat", .generation = 12 },
    };
    const manifest = makeManifest(root, 12, 11, &segments);
    const bytes = try serializeManifest(std.testing.allocator, manifest);
    defer std.testing.allocator.free(bytes);

    const pin = try pinManifestBytesForRoot(bytes, root);
    try std.testing.expectEqual(root, pin.root_fingerprint);
    try std.testing.expectEqual(@as(Epoch, 12), pin.epoch);
    try std.testing.expectEqual(@as(?Epoch, 11), pin.parent_epoch);
    try std.testing.expectEqual(@as(usize, 1), pin.segment_count);
    try std.testing.expectError(error.WrongGenerationRoot, pinManifestBytesForRoot(bytes, 0x9999));
}

test "generation compaction planner selects small dense and tombstoned segments without pinned readers" {
    const states = [_]CompactionSegmentState{
        .{ .segment = .{ .kind = .catalog, .relative_path = "catalog-a.ixcat", .generation = 10, .byte_len = 1024 }, .total_entries = 10 },
        .{ .segment = .{ .kind = .postings, .relative_path = "postings-a.ixpost", .generation = 10, .byte_len = 32 * 1024 * 1024 }, .total_entries = 10 },
        .{ .segment = .{ .kind = .catalog, .relative_path = "catalog-b.ixcat", .generation = 10, .byte_len = 512 * 1024 }, .total_entries = 100, .deleted_entries = 40 },
        .{ .segment = .{ .kind = .postings, .relative_path = "postings-pinned.ixpost", .generation = 10, .byte_len = 512 }, .total_entries = 100, .deleted_entries = 90, .reader_pinned = true },
    };

    const candidates = try planCompaction(std.testing.allocator, &states, .{});
    defer std.testing.allocator.free(candidates);
    try std.testing.expectEqual(@as(usize, 3), candidates.len);
    try std.testing.expect(candidates[0].reasons.small_segment);
    try std.testing.expect(candidates[1].reasons.dense_segment);
    try std.testing.expect(candidates[2].reasons.deleted_entries);
}

test "generation compaction planner requires segment pressure before small segment merging" {
    const states = [_]CompactionSegmentState{
        .{ .segment = .{ .kind = .catalog, .relative_path = "catalog-a.ixcat", .generation = 10, .byte_len = 1024 }, .total_entries = 10 },
        .{ .segment = .{ .kind = .postings, .relative_path = "postings-a.ixpost", .generation = 10, .byte_len = 1024 }, .total_entries = 10 },
    };

    const candidates = try planCompaction(std.testing.allocator, &states, .{ .min_segment_count = 3 });
    defer std.testing.allocator.free(candidates);
    try std.testing.expectEqual(@as(usize, 0), candidates.len);
}

test "generation gc planner protects current newest and reader pinned epochs" {
    const epochs = [_]Epoch{ 10, 11, 12, 13, 14, 15 };
    const pins = [_]ReaderPin{
        .{ .root_fingerprint = 0xaaaa, .epoch = 11, .parent_epoch = null, .segment_count = 2 },
        .{ .root_fingerprint = 0xaaaa, .epoch = 14, .parent_epoch = 13, .segment_count = 2 },
    };

    const delete_epochs = try planGenerationGc(std.testing.allocator, &epochs, &pins, 15, .{ .retain_newest = 2 });
    defer std.testing.allocator.free(delete_epochs);

    try std.testing.expectEqual(@as(usize, 2), delete_epochs.len);
    try std.testing.expectEqual(@as(Epoch, 10), delete_epochs[0]);
    try std.testing.expectEqual(@as(Epoch, 12), delete_epochs[1]);
}

test "generation gc planner deduplicates and refuses invalid current epoch" {
    const epochs = [_]Epoch{ 1, 1, 2, 3, 4 };
    const delete_epochs = try planGenerationGc(std.testing.allocator, &epochs, &.{}, 4, .{ .retain_newest = 1 });
    defer std.testing.allocator.free(delete_epochs);

    try std.testing.expectEqual(@as(usize, 3), delete_epochs.len);
    try std.testing.expectEqual(@as(Epoch, 1), delete_epochs[0]);
    try std.testing.expectEqual(@as(Epoch, 2), delete_epochs[1]);
    try std.testing.expectEqual(@as(Epoch, 3), delete_epochs[2]);
    try std.testing.expectError(error.InvalidGenerationEpoch, planGenerationGc(std.testing.allocator, &epochs, &.{}, INVALID_EPOCH, .{}));
}

test "generation payload publish writes catalog postings and manifest through epoch directory" {
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const root = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}", .{&tmp.sub_path});
    defer std.testing.allocator.free(root);

    const paths = try buildGenerationPathsInIndexDir(std.testing.allocator, root, 13);
    defer paths.deinit(std.testing.allocator);

    const payloads = [_]SegmentPayload{
        .{ .kind = .catalog, .relative_path = "catalog.ixcat", .bytes = "CATALOG" },
        .{ .kind = .postings, .relative_path = "postings.ixpost", .bytes = "POSTINGS" },
    };
    const pin = try publishGenerationPayloads(std.testing.io, std.testing.allocator, paths, 0x9876, 13, 12, &payloads);
    try std.testing.expectEqual(@as(Epoch, 13), pin.epoch);
    try std.testing.expectEqual(@as(usize, 2), pin.segment_count);

    var buffer: [512]u8 = undefined;
    const manifest_bytes = try std.Io.Dir.cwd().readFile(std.testing.io, paths.manifest_path, &buffer);
    _ = try validateManifestBytesForRoot(manifest_bytes, 0x9876);

    const current_manifest_bytes = try std.Io.Dir.cwd().readFile(std.testing.io, paths.current_manifest_path, &buffer);
    const current_pin = try pinManifestBytesForRoot(current_manifest_bytes, 0x9876);
    try std.testing.expectEqual(@as(Epoch, 13), current_pin.epoch);

    const catalog_path = try std.fs.path.join(std.testing.allocator, &.{ paths.generation_dir, "catalog.ixcat" });
    defer std.testing.allocator.free(catalog_path);
    const catalog_bytes = try std.Io.Dir.cwd().readFile(std.testing.io, catalog_path, &buffer);
    try std.testing.expectEqualStrings("CATALOG", catalog_bytes);
}

test "generation payload validation rejects missing published segment" {
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const root = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}", .{&tmp.sub_path});
    defer std.testing.allocator.free(root);

    const paths = try buildGenerationPathsInIndexDir(std.testing.allocator, root, 61);
    defer paths.deinit(std.testing.allocator);

    const payloads = [_]SegmentPayload{
        .{ .kind = .catalog, .relative_path = "catalog.ixcat", .bytes = "CATALOG-61" },
        .{ .kind = .postings, .relative_path = "postings.ixpost", .bytes = "POSTINGS-61" },
    };
    _ = try publishGenerationPayloads(std.testing.io, std.testing.allocator, paths, 0x6161, 61, null, &payloads);

    const postings_path = try std.fs.path.join(std.testing.allocator, &.{ paths.generation_dir, "postings.ixpost" });
    defer std.testing.allocator.free(postings_path);
    try std.Io.Dir.cwd().deleteFile(std.testing.io, postings_path);

    var buffer: [1024]u8 = undefined;
    const manifest_bytes = try std.Io.Dir.cwd().readFile(std.testing.io, paths.current_manifest_path, &buffer);
    try std.testing.expectError(error.MissingGenerationSegment, pinManifestBytesAndPayloadsForRoot(std.testing.io, std.testing.allocator, paths.index_dir, manifest_bytes, 0x6161));
    try std.testing.expectError(error.MissingGenerationSegment, pinCurrentGenerationWithPayloads(std.testing.io, std.testing.allocator, paths.index_dir, paths.current_manifest_path, 0x6161));
    try std.testing.expectEqual(@as(?ReaderPin, null), tryPinCurrentGenerationWithPayloads(std.testing.io, std.testing.allocator, paths.index_dir, paths.current_manifest_path, 0x6161));
}

test "generation payload validation rejects checksum mismatch" {
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const root = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}", .{&tmp.sub_path});
    defer std.testing.allocator.free(root);

    const paths = try buildGenerationPathsInIndexDir(std.testing.allocator, root, 62);
    defer paths.deinit(std.testing.allocator);

    const payloads = [_]SegmentPayload{
        .{ .kind = .catalog, .relative_path = "catalog.ixcat", .bytes = "CATALOG-62" },
        .{ .kind = .postings, .relative_path = "postings.ixpost", .bytes = "POSTINGS-62" },
    };
    _ = try publishGenerationPayloads(std.testing.io, std.testing.allocator, paths, 0x6262, 62, null, &payloads);

    const catalog_path = try std.fs.path.join(std.testing.allocator, &.{ paths.generation_dir, "catalog.ixcat" });
    defer std.testing.allocator.free(catalog_path);
    var file = try std.Io.Dir.cwd().createFile(std.testing.io, catalog_path, .{ .truncate = true });
    defer file.close(std.testing.io);
    try file.writeStreamingAll(std.testing.io, "CATALOG-XX");

    var buffer: [1024]u8 = undefined;
    const manifest_bytes = try std.Io.Dir.cwd().readFile(std.testing.io, paths.current_manifest_path, &buffer);
    try std.testing.expectError(error.GenerationSegmentChecksumMismatch, pinManifestBytesAndPayloadsForRoot(std.testing.io, std.testing.allocator, paths.index_dir, manifest_bytes, 0x6262));
    try std.testing.expectError(error.GenerationSegmentChecksumMismatch, pinCurrentGenerationWithPayloads(std.testing.io, std.testing.allocator, paths.index_dir, paths.current_manifest_path, 0x6262));
    try std.testing.expectEqual(@as(?ReaderPin, null), tryPinCurrentGenerationWithPayloads(std.testing.io, std.testing.allocator, paths.index_dir, paths.current_manifest_path, 0x6262));
}

test "generation payload validation streams segment bytes without whole payload allocation" {
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const root = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}", .{&tmp.sub_path});
    defer std.testing.allocator.free(root);

    const paths = try buildGenerationPathsInIndexDir(std.testing.allocator, root, 63);
    defer paths.deinit(std.testing.allocator);

    var large_catalog: [16 * 1024]u8 = undefined;
    @memset(&large_catalog, 'C');
    large_catalog[0] = 'I';
    large_catalog[large_catalog.len - 1] = 'X';

    const payloads = [_]SegmentPayload{
        .{ .kind = .catalog, .relative_path = "catalog.ixcat", .bytes = &large_catalog },
        .{ .kind = .postings, .relative_path = "postings.ixpost", .bytes = "POSTINGS-63" },
    };
    _ = try publishGenerationPayloads(std.testing.io, std.testing.allocator, paths, 0x6363, 63, null, &payloads);

    const catalog_path = try std.fs.path.join(std.testing.allocator, &.{ paths.generation_dir, "catalog.ixcat" });
    defer std.testing.allocator.free(catalog_path);

    var budget_bytes: [4096]u8 = undefined;
    var fixed = std.heap.FixedBufferAllocator.init(&budget_bytes);
    try std.testing.expectError(
        error.OutOfMemory,
        std.Io.Dir.cwd().readFileAlloc(std.testing.io, catalog_path, fixed.allocator(), .limited(128 * 1024)),
    );

    fixed.reset();
    var manifest_buffer: [1024]u8 = undefined;
    const manifest_bytes = try std.Io.Dir.cwd().readFile(std.testing.io, paths.current_manifest_path, &manifest_buffer);
    const pin = try pinManifestBytesAndPayloadsForRoot(std.testing.io, fixed.allocator(), paths.index_dir, manifest_bytes, 0x6363);
    try std.testing.expectEqual(@as(Epoch, 63), pin.epoch);
    try std.testing.expectEqual(@as(usize, 2), pin.segment_count);
}

test "generation compacted publish writes canonical catalog and postings payloads" {
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const root = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}", .{&tmp.sub_path});
    defer std.testing.allocator.free(root);

    const paths = try buildGenerationPathsInIndexDir(std.testing.allocator, root, 14);
    defer paths.deinit(std.testing.allocator);
    const pin = try publishCompactedGeneration(std.testing.io, std.testing.allocator, paths, .{
        .root_fingerprint = 0xface,
        .epoch = 14,
        .parent_epoch = 13,
        .catalog_bytes = "COMPACTED-CATALOG",
        .postings_bytes = "COMPACTED-POSTINGS",
    });
    try std.testing.expectEqual(@as(Epoch, 14), pin.epoch);
    try std.testing.expectEqual(@as(?Epoch, 13), pin.parent_epoch);
    try std.testing.expectEqual(@as(usize, 2), pin.segment_count);

    var buffer: [512]u8 = undefined;
    const current_manifest_bytes = try std.Io.Dir.cwd().readFile(std.testing.io, paths.current_manifest_path, &buffer);
    const current_pin = try pinManifestBytesForRoot(current_manifest_bytes, 0xface);
    try std.testing.expectEqual(@as(Epoch, 14), current_pin.epoch);
}

test "generation compacted publish rejects missing segment payloads" {
    const paths = try buildGenerationPathsInIndexDir(std.testing.allocator, ".zig-cache\\unused-generation-compacted-empty-test", 15);
    defer paths.deinit(std.testing.allocator);
    try std.testing.expectError(error.EmptyGenerationSegment, publishCompactedGeneration(std.testing.io, std.testing.allocator, paths, .{
        .root_fingerprint = 0xbeef,
        .epoch = 15,
        .catalog_bytes = "",
        .postings_bytes = "POSTINGS",
    }));
}

test "generation publish retains prior reader pinned epoch" {
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const root = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}", .{&tmp.sub_path});
    defer std.testing.allocator.free(root);

    const first_paths = try buildGenerationPathsInIndexDir(std.testing.allocator, root, 21);
    defer first_paths.deinit(std.testing.allocator);
    const second_paths = try buildGenerationPathsInIndexDir(std.testing.allocator, root, 22);
    defer second_paths.deinit(std.testing.allocator);

    const first_payloads = [_]SegmentPayload{
        .{ .kind = .catalog, .relative_path = "catalog.ixcat", .bytes = "CATALOG-21" },
    };
    const first_pin = try publishGenerationPayloads(std.testing.io, std.testing.allocator, first_paths, 0xaaaa, 21, null, &first_payloads);

    const second_payloads = [_]SegmentPayload{
        .{ .kind = .catalog, .relative_path = "catalog.ixcat", .bytes = "CATALOG-22" },
    };
    const second_pin = try publishGenerationPayloads(std.testing.io, std.testing.allocator, second_paths, 0xaaaa, 22, 21, &second_payloads);
    try std.testing.expect(readerPinRetainedAfterPublish(first_pin, second_pin.epoch));

    var buffer: [512]u8 = undefined;
    const old_manifest = try std.Io.Dir.cwd().readFile(std.testing.io, first_paths.manifest_path, &buffer);
    const old_pin = try pinManifestBytesForRoot(old_manifest, 0xaaaa);
    try std.testing.expectEqual(@as(Epoch, 21), old_pin.epoch);
}

test "failed generation publish leaves prior generation active" {
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const root = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}", .{&tmp.sub_path});
    defer std.testing.allocator.free(root);

    const first_paths = try buildGenerationPathsInIndexDir(std.testing.allocator, root, 31);
    defer first_paths.deinit(std.testing.allocator);
    const second_paths = try buildGenerationPathsInIndexDir(std.testing.allocator, root, 32);
    defer second_paths.deinit(std.testing.allocator);

    const first_payloads = [_]SegmentPayload{
        .{ .kind = .catalog, .relative_path = "catalog.ixcat", .bytes = "CATALOG-31" },
    };
    _ = try publishGenerationPayloads(std.testing.io, std.testing.allocator, first_paths, 0xbbbb, 31, null, &first_payloads);

    const bad_payloads = [_]SegmentPayload{
        .{ .kind = .catalog, .relative_path = "catalog.ixcat", .bytes = "" },
    };
    try std.testing.expectError(error.EmptyGenerationSegment, publishGenerationPayloads(std.testing.io, std.testing.allocator, second_paths, 0xbbbb, 32, 31, &bad_payloads));

    var buffer: [512]u8 = undefined;
    const old_manifest = try std.Io.Dir.cwd().readFile(std.testing.io, first_paths.manifest_path, &buffer);
    const old_pin = try pinManifestBytesForRoot(old_manifest, 0xbbbb);
    try std.testing.expectEqual(@as(Epoch, 31), old_pin.epoch);
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.cwd().readFile(std.testing.io, second_paths.manifest_path, &buffer));
}

test "search adoption guard pins complete current generation or falls back" {
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const root = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}", .{&tmp.sub_path});
    defer std.testing.allocator.free(root);

    const paths = try buildGenerationPathsInIndexDir(std.testing.allocator, root, 41);
    defer paths.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(?ReaderPin, null), tryPinCurrentGeneration(std.testing.io, std.testing.allocator, paths.manifest_path, 0xcccc));

    const payloads = [_]SegmentPayload{
        .{ .kind = .catalog, .relative_path = "catalog.ixcat", .bytes = "CATALOG-41" },
    };
    _ = try publishGenerationPayloads(std.testing.io, std.testing.allocator, paths, 0xcccc, 41, null, &payloads);

    const pin = (try tryPinCurrentGeneration(std.testing.io, std.testing.allocator, paths.manifest_path, 0xcccc)).?;
    try std.testing.expectEqual(@as(Epoch, 41), pin.epoch);
    try std.testing.expectEqual(@as(?ReaderPin, null), tryPinCurrentGeneration(std.testing.io, std.testing.allocator, paths.manifest_path, 0xdddd));

    try publishManifestBytes(std.testing.io, paths, "not-a-valid-manifest");
    try std.testing.expectEqual(@as(?ReaderPin, null), tryPinCurrentGeneration(std.testing.io, std.testing.allocator, paths.manifest_path, 0xcccc));
}

test "current generation pin survives refresh while new epoch publishes" {
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const root = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}", .{&tmp.sub_path});
    defer std.testing.allocator.free(root);

    const first_paths = try buildGenerationPathsInIndexDir(std.testing.allocator, root, 51);
    defer first_paths.deinit(std.testing.allocator);
    const second_paths = try buildGenerationPathsInIndexDir(std.testing.allocator, root, 52);
    defer second_paths.deinit(std.testing.allocator);

    const first_payloads = [_]SegmentPayload{
        .{ .kind = .catalog, .relative_path = "catalog.ixcat", .bytes = "CATALOG-51" },
    };
    _ = try publishGenerationPayloads(std.testing.io, std.testing.allocator, first_paths, 0xdddd, 51, null, &first_payloads);
    const pinned_before_refresh = (try tryPinCurrentGeneration(std.testing.io, std.testing.allocator, first_paths.current_manifest_path, 0xdddd)).?;
    try std.testing.expectEqual(@as(Epoch, 51), pinned_before_refresh.epoch);

    const second_payloads = [_]SegmentPayload{
        .{ .kind = .catalog, .relative_path = "catalog.ixcat", .bytes = "CATALOG-52" },
    };
    _ = try publishGenerationPayloads(std.testing.io, std.testing.allocator, second_paths, 0xdddd, 52, 51, &second_payloads);

    const pinned_after_refresh = (try tryPinCurrentGeneration(std.testing.io, std.testing.allocator, second_paths.current_manifest_path, 0xdddd)).?;
    try std.testing.expectEqual(@as(Epoch, 52), pinned_after_refresh.epoch);
    try std.testing.expect(readerPinRetainedAfterPublish(pinned_before_refresh, pinned_after_refresh.epoch));
    try std.testing.expectEqual(@as(?Epoch, 51), pinned_after_refresh.parent_epoch);
}
