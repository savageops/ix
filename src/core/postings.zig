const std = @import("std");
const catalog = @import("catalog.zig");
const expr = @import("expr.zig");
const trigram = @import("trigram.zig");

pub const MAGIC: [8]u8 = .{ 'I', 'X', 'P', 'O', 'S', 'T', '0', '1' };
pub const FORMAT_VERSION: u16 = 2;
pub const MIN_HEADER_SIZE: usize = @sizeOf(PostingsSegmentHeader);
pub const INVALID_TRIGRAM_KEY: TrigramKey = 0;
pub const SERIALIZED_HEADER_SIZE: u64 = 8 + 2 + 2 + 4 + 8 + 8 + 8 + 8 + 8 + 8 + 8;
pub const SERIALIZED_ENTRY_SIZE: u64 = 4 + 8 + 4 + 1 + 1 + 2;
pub const SERIALIZED_FILE_ID_SIZE: u64 = 8;

pub const TrigramKey = u32;
pub const FileId = catalog.FileId;
pub const RootFingerprint = catalog.RootFingerprint;

pub const DensityClass = enum(u8) {
    empty = 0,
    sparse = 1,
    medium = 2,
    dense = 3,
};

pub const SegmentFlags = packed struct(u32) {
    sorted_keys: bool = true,
    sorted_file_ids: bool = true,
    unique_file_ids: bool = true,
    reserved: u29 = 0,
};

pub const PostingsSegmentHeader = extern struct {
    magic: [8]u8 = MAGIC,
    version: u16 = FORMAT_VERSION,
    header_size: u16 = @sizeOf(PostingsSegmentHeader),
    flags: SegmentFlags = .{},
    root_fingerprint_hi: u64 = 0,
    root_fingerprint_lo: u64 = 0,
    generation: u64 = 0,
    trigram_count: u64 = 0,
    postings_count: u64 = 0,
    file_count: u64 = 0,
    verify_required_count: u64 = 0,

    pub fn rootFingerprint(self: PostingsSegmentHeader) RootFingerprint {
        return (@as(RootFingerprint, self.root_fingerprint_hi) << 64) | @as(RootFingerprint, self.root_fingerprint_lo);
    }

    pub fn withRootFingerprint(value: RootFingerprint) PostingsSegmentHeader {
        var header = PostingsSegmentHeader{};
        header.root_fingerprint_hi = @intCast(value >> 64);
        header.root_fingerprint_lo = @intCast(value & std.math.maxInt(u64));
        return header;
    }
};

pub const PostingsEntry = extern struct {
    key: TrigramKey = INVALID_TRIGRAM_KEY,
    file_offset: u64 = 0,
    file_count: u32 = 0,
    density: DensityClass = .empty,
    reserved: u8 = 0,
    reserved2: u16 = 0,
};

pub const PostingsSegment = struct {
    header: PostingsSegmentHeader,
    entries: []PostingsEntry,
    file_ids: []FileId,

    pub fn deinit(self: PostingsSegment, allocator: std.mem.Allocator) void {
        allocator.free(self.entries);
        allocator.free(self.file_ids);
    }

    pub fn fileIds(self: PostingsSegment, entry: PostingsEntry) []const FileId {
        const start: usize = @intCast(entry.file_offset);
        const end = start + entry.file_count;
        return self.file_ids[start..end];
    }
};

pub const PostingsFileLookup = struct {
    header: PostingsSegmentHeader,
    candidates: []FileId,

    pub fn deinit(self: PostingsFileLookup, allocator: std.mem.Allocator) void {
        allocator.free(self.candidates);
    }
};

pub const PostingsFileInput = struct {
    file_id: FileId,
    bytes: []const u8,
};

pub const LookupMode = enum {
    all,
    any,
};

pub const LookupFallback = enum {
    none,
    no_mandatory_evidence,
    disjunction_has_unindexed_branch,
};

pub const LookupGroup = struct {
    source_index: usize = 0,
    keys: [trigram.MAX_TRIGRAMS_PER_GROUP]TrigramKey = undefined,
    key_count: usize = 0,
};

pub const LookupPlan = struct {
    eligible: bool = false,
    mode: LookupMode = .all,
    groups: [trigram.MAX_GROUPS]LookupGroup = undefined,
    group_count: usize = 0,
    ignored_predicates: usize = 0,
    fallback: LookupFallback = .none,
};

const PostingPair = struct {
    key: TrigramKey,
    file_id: FileId,
};

pub fn makeTrigramKey(bytes: *const [3]u8) TrigramKey {
    return (@as(TrigramKey, bytes[0]) << 16) | (@as(TrigramKey, bytes[1]) << 8) | @as(TrigramKey, bytes[2]);
}

pub fn isValidTrigramKey(key: TrigramKey) bool {
    return key != INVALID_TRIGRAM_KEY and (key & 0xff000000) == 0;
}

pub fn trigramBytes(key: TrigramKey) [3]u8 {
    return .{
        @intCast((key >> 16) & 0xff),
        @intCast((key >> 8) & 0xff),
        @intCast(key & 0xff),
    };
}

pub fn classifyDensity(file_count: usize, total_files: usize) DensityClass {
    if (file_count == 0 or total_files == 0) return .empty;
    if (file_count <= 4) return .sparse;
    if (file_count * 4 <= total_files) return .medium;
    return .dense;
}

pub fn extractFileTrigrams(allocator: std.mem.Allocator, bytes: []const u8) ![]TrigramKey {
    if (bytes.len < 3) return allocator.alloc(TrigramKey, 0);

    var keys = std.ArrayList(TrigramKey).empty;
    errdefer keys.deinit(allocator);

    var index: usize = 0;
    while (index + 3 <= bytes.len) : (index += 1) {
        const key = makeTrigramKey(bytes[index..][0..3]);
        if (isValidTrigramKey(key)) try keys.append(allocator, key);
    }
    std.sort.heap(TrigramKey, keys.items, {}, lessThanTrigramKey);

    var unique_count: usize = 0;
    for (keys.items) |key_value| {
        if (unique_count == 0 or keys.items[unique_count - 1] != key_value) {
            keys.items[unique_count] = key_value;
            unique_count += 1;
        }
    }

    const result = try allocator.dupe(TrigramKey, keys.items[0..unique_count]);
    keys.deinit(allocator);
    return result;
}

pub fn buildPostingsSegment(
    allocator: std.mem.Allocator,
    root_fingerprint: RootFingerprint,
    generation: u64,
    files: []const PostingsFileInput,
    verify_required_count: u64,
) !PostingsSegment {
    var pairs = std.ArrayList(PostingPair).empty;
    errdefer pairs.deinit(allocator);

    for (files) |file| {
        if (!catalog.isValidFileId(file.file_id)) return error.InvalidCatalogFileId;
        const keys = try extractFileTrigrams(allocator, file.bytes);
        defer allocator.free(keys);
        for (keys) |key_value| try pairs.append(allocator, .{
            .key = key_value,
            .file_id = file.file_id,
        });
    }
    std.sort.heap(PostingPair, pairs.items, {}, lessThanPostingPair);

    var unique_pair_count: usize = 0;
    for (pairs.items) |pair| {
        if (unique_pair_count == 0 or !samePostingPair(pairs.items[unique_pair_count - 1], pair)) {
            pairs.items[unique_pair_count] = pair;
            unique_pair_count += 1;
        }
    }

    var entry_count: usize = 0;
    var index: usize = 0;
    while (index < unique_pair_count) {
        entry_count += 1;
        const key_value = pairs.items[index].key;
        while (index < unique_pair_count and pairs.items[index].key == key_value) : (index += 1) {}
    }

    const entries = try allocator.alloc(PostingsEntry, entry_count);
    errdefer allocator.free(entries);
    const file_ids = try allocator.alloc(FileId, unique_pair_count);
    errdefer allocator.free(file_ids);

    var entry_index: usize = 0;
    var file_offset: usize = 0;
    index = 0;
    while (index < unique_pair_count) {
        const key_value = pairs.items[index].key;
        const start = file_offset;
        while (index < unique_pair_count and pairs.items[index].key == key_value) : (index += 1) {
            file_ids[file_offset] = pairs.items[index].file_id;
            file_offset += 1;
        }
        entries[entry_index] = .{
            .key = key_value,
            .file_offset = @intCast(start),
            .file_count = @intCast(file_offset - start),
            .density = classifyDensity(file_offset - start, files.len),
        };
        entry_index += 1;
    }

    var header = PostingsSegmentHeader.withRootFingerprint(root_fingerprint);
    header.generation = generation;
    header.trigram_count = @intCast(entries.len);
    header.postings_count = @intCast(file_ids.len);
    header.file_count = @intCast(files.len);
    header.verify_required_count = verify_required_count;

    pairs.deinit(allocator);
    return .{
        .header = header,
        .entries = entries,
        .file_ids = file_ids,
    };
}

pub fn lowerExpressionToLookupPlan(plan: expr.ExpressionPlan) LookupPlan {
    if (literalAlternatesLookupPlan(plan)) |lookup| return lookup;

    const admission = trigram.admit(plan);
    var lookup = LookupPlan{
        .eligible = admission.eligible,
        .mode = if (admission.mode == .any) .any else .all,
        .ignored_predicates = admission.ignored_predicates,
        .fallback = lookupFallback(admission.reason),
    };
    if (!admission.eligible) return lookup;

    var group_index: usize = 0;
    while (group_index < admission.group_count) : (group_index += 1) {
        const group = admission.groups[group_index];
        lookup.groups[group_index] = .{
            .source_index = group.source_index,
            .key_count = group.trigram_count,
        };
        for (group.trigrams[0..group.trigram_count], 0..) |key_value, key_index| {
            lookup.groups[group_index].keys[key_index] = key_value;
        }
    }
    lookup.group_count = admission.group_count;
    return lookup;
}

fn literalAlternatesLookupPlan(plan: expr.ExpressionPlan) ?LookupPlan {
    if (plan.predicate_count != 1) return null;

    const predicate = plan.predicates[0];
    if (predicate.kind != .regex) return null;
    if (predicate.strategy != .regex_literal_alternates) return null;

    const body = expr.literalAlternatesBody(predicate.value);
    var lookup = LookupPlan{
        .eligible = true,
        .mode = .any,
        .fallback = .none,
    };

    var branch_start: usize = 0;
    var index: usize = 0;
    while (index <= body.len) : (index += 1) {
        if (index < body.len) {
            if (body[index] == '\\') {
                index += 1;
                continue;
            }
            if (body[index] != '|') continue;
        }

        if (lookup.group_count == lookup.groups.len) return null;

        var group = LookupGroup{ .source_index = 0 };
        if (!appendLiteralBranchTrigrams(&group, body[branch_start..index])) return null;
        lookup.groups[lookup.group_count] = group;
        lookup.group_count += 1;
        branch_start = index + 1;
    }

    if (lookup.group_count == 0) return null;
    return lookup;
}

fn appendLiteralBranchTrigrams(group: *LookupGroup, branch: []const u8) bool {
    var decoded_len: usize = 0;
    var last: [2]u8 = undefined;
    var index: usize = 0;

    while (index < branch.len) : (index += 1) {
        var byte = branch[index];
        if (byte == '\\') {
            index += 1;
            if (index >= branch.len) return false;
            byte = branch[index];
            switch (byte) {
                'b', 'B', 'd', 'D', 's', 'S', 'w', 'W', 'x', 'u', 'p', 'P' => return false,
                else => {},
            }
        } else switch (byte) {
            '(', ')', '[', ']', '{', '}', '.', '^', '$', '*', '+', '?', '|' => return false,
            else => {},
        }

        if (decoded_len >= 2) {
            const key = makeTrigramKey(&.{ last[0], last[1], byte });
            appendUniqueLookupKey(group, key);
        }

        if (decoded_len == 0) {
            last[0] = byte;
        } else if (decoded_len == 1) {
            last[1] = byte;
        } else {
            last[0] = last[1];
            last[1] = byte;
        }
        decoded_len += 1;
    }

    return decoded_len >= 3 and group.key_count != 0;
}

fn appendUniqueLookupKey(group: *LookupGroup, key: TrigramKey) void {
    for (group.keys[0..group.key_count]) |existing| {
        if (existing == key) return;
    }
    if (group.key_count == group.keys.len) return;
    group.keys[group.key_count] = key;
    group.key_count += 1;
}

pub fn lookupRequiresFullScan(lookup: LookupPlan) bool {
    return !lookup.eligible or lookup.group_count == 0 or lookup.fallback != .none;
}

pub fn lookupFallbackReasonText(lookup: LookupPlan) []const u8 {
    if (lookup.fallback != .none) {
        return switch (lookup.fallback) {
            .none => "none",
            .no_mandatory_evidence => "no_mandatory_evidence",
            .disjunction_has_unindexed_branch => "disjunction_has_unindexed_branch",
        };
    }
    if (!lookup.eligible) return "not_eligible";
    if (lookup.group_count == 0) return "empty_lookup_groups";
    return "";
}

pub fn evaluateLookupPlan(allocator: std.mem.Allocator, segment: PostingsSegment, lookup: LookupPlan) ![]FileId {
    if (lookupRequiresFullScan(lookup)) return error.RequiresFullScan;

    var current = try evaluateLookupGroup(allocator, segment, lookup.groups[0]);
    errdefer allocator.free(current);

    var group_index: usize = 1;
    while (group_index < lookup.group_count) : (group_index += 1) {
        const next_group = try evaluateLookupGroup(allocator, segment, lookup.groups[group_index]);
        defer allocator.free(next_group);
        const merged = switch (lookup.mode) {
            .all => try intersectFileIds(allocator, current, next_group),
            .any => try unionFileIds(allocator, current, next_group),
        };
        allocator.free(current);
        current = merged;
    }

    return current;
}

pub fn evaluateLookupPlanFromFile(
    io: std.Io,
    allocator: std.mem.Allocator,
    path: []const u8,
    expected_root: RootFingerprint,
    expected_generation: u64,
    lookup: LookupPlan,
) !PostingsFileLookup {
    var file = try std.Io.Dir.cwd().openFile(io, path, .{ .allow_directory = false });
    defer file.close(io);
    return evaluateLookupPlanFromOpenFile(io, allocator, &file, expected_root, expected_generation, lookup);
}

pub fn evaluateLookupPlanFromOpenFile(
    io: std.Io,
    allocator: std.mem.Allocator,
    file: *std.Io.File,
    expected_root: RootFingerprint,
    expected_generation: u64,
    lookup: LookupPlan,
) !PostingsFileLookup {
    if (lookupRequiresFullScan(lookup)) return error.RequiresFullScan;
    const header = try readHeaderAt(io, file, 0);
    try validatePostingsHeader(header, expected_root, expected_generation);
    const candidates = try evaluateLookupPlanFromOpenFileHeader(io, allocator, file, header, lookup);
    return .{
        .header = header,
        .candidates = candidates,
    };
}

pub fn selectCatalogEntriesForCandidates(
    allocator: std.mem.Allocator,
    snapshot: catalog.CatalogSnapshot,
    candidate_file_ids: []const FileId,
) ![]catalog.PathEntry {
    var selected = std.ArrayList(catalog.PathEntry).empty;
    errdefer selected.deinit(allocator);

    for (snapshot.entries) |entry| {
        if (containsFileId(candidate_file_ids, entry.file_id)) {
            try selected.append(allocator, entry);
        }
    }
    return selected.toOwnedSlice(allocator);
}

pub fn serializePostingsSegment(allocator: std.mem.Allocator, segment: PostingsSegment) ![]u8 {
    var bytes = std.ArrayList(u8).empty;
    errdefer bytes.deinit(allocator);

    var header = segment.header;
    header.trigram_count = @intCast(segment.entries.len);
    header.postings_count = @intCast(segment.file_ids.len);

    try writeHeader(&bytes, allocator, header);
    for (segment.entries) |entry| try writeEntry(&bytes, allocator, entry);
    for (segment.file_ids) |file_id| try appendU64(&bytes, allocator, file_id);

    return bytes.toOwnedSlice(allocator);
}

pub fn parsePostingsSegment(allocator: std.mem.Allocator, bytes: []const u8) !PostingsSegment {
    var cursor = Cursor{ .bytes = bytes };
    const header = try readHeader(&cursor);
    if (!std.mem.eql(u8, &header.magic, &MAGIC)) return error.InvalidPostingsMagic;
    if (header.version != FORMAT_VERSION) return error.UnsupportedPostingsVersion;
    if (header.header_size != @sizeOf(PostingsSegmentHeader)) return error.InvalidPostingsHeaderSize;

    const entry_count = try checkedCount(header.trigram_count);
    const file_id_count = try checkedCount(header.postings_count);

    const entries = try allocator.alloc(PostingsEntry, entry_count);
    errdefer allocator.free(entries);
    for (entries) |*entry| entry.* = try readEntry(&cursor);

    const file_ids = try allocator.alloc(FileId, file_id_count);
    errdefer allocator.free(file_ids);
    for (file_ids) |*file_id| file_id.* = try cursor.readU64();

    if (cursor.remaining() != 0) return error.TrailingPostingsBytes;
    try validatePostingsSegmentShape(header, entries, file_ids);
    return .{
        .header = header,
        .entries = entries,
        .file_ids = file_ids,
    };
}

pub fn parsePostingsSegmentForRootGeneration(
    allocator: std.mem.Allocator,
    bytes: []const u8,
    expected_root: RootFingerprint,
    expected_generation: u64,
) !PostingsSegment {
    const segment = try parsePostingsSegment(allocator, bytes);
    errdefer segment.deinit(allocator);
    if (segment.header.rootFingerprint() != expected_root) return error.WrongPostingsRoot;
    if (segment.header.generation != expected_generation) return error.WrongPostingsGeneration;
    return segment;
}

pub fn isValidEntry(entry: PostingsEntry, file_ids_len: usize) bool {
    if (!isValidTrigramKey(entry.key)) return false;
    if (entry.file_offset > std.math.maxInt(usize)) return false;
    const start: usize = @intCast(entry.file_offset);
    if (start > file_ids_len) return false;
    return entry.file_count <= file_ids_len - start;
}

fn validatePostingsSegmentShape(header: PostingsSegmentHeader, entries: []const PostingsEntry, file_ids: []const FileId) !void {
    if (header.trigram_count != entries.len) return error.PostingsEntryCountMismatch;
    if (header.postings_count != file_ids.len) return error.PostingsFileIdCountMismatch;

    var previous_key: ?TrigramKey = null;
    for (entries) |entry| {
        if (!isValidEntry(entry, file_ids.len)) return error.InvalidPostingsEntry;
        if (previous_key) |key_value| {
            if (key_value >= entry.key) return error.UnsortedPostingsKeys;
        }
        previous_key = entry.key;

        const start: usize = @intCast(entry.file_offset);
        const ids = file_ids[start .. start + entry.file_count];
        var previous_file_id: ?FileId = null;
        for (ids) |file_id| {
            if (!catalog.isValidFileId(file_id)) return error.InvalidCatalogFileId;
            if (previous_file_id) |prev| {
                if (prev >= file_id) return error.DuplicateOrUnsortedPostingsFileIds;
            }
            previous_file_id = file_id;
        }
    }
}

fn lessThanTrigramKey(_: void, lhs: TrigramKey, rhs: TrigramKey) bool {
    return lhs < rhs;
}

fn lessThanPostingPair(_: void, lhs: PostingPair, rhs: PostingPair) bool {
    if (lhs.key != rhs.key) return lhs.key < rhs.key;
    return lhs.file_id < rhs.file_id;
}

fn samePostingPair(lhs: PostingPair, rhs: PostingPair) bool {
    return lhs.key == rhs.key and lhs.file_id == rhs.file_id;
}

fn lookupFallback(reason: trigram.IneligibleReason) LookupFallback {
    return switch (reason) {
        .none => .none,
        .no_mandatory_trigram => .no_mandatory_evidence,
        .disjunction_has_unindexed_branch => .disjunction_has_unindexed_branch,
    };
}

fn evaluateLookupGroup(allocator: std.mem.Allocator, segment: PostingsSegment, group: LookupGroup) ![]FileId {
    if (group.key_count == 0) return allocator.alloc(FileId, 0);
    var current = try allocator.dupe(FileId, lookupFileIds(segment, group.keys[0]) orelse return allocator.alloc(FileId, 0));
    errdefer allocator.free(current);

    var key_index: usize = 1;
    while (key_index < group.key_count) : (key_index += 1) {
        const ids = lookupFileIds(segment, group.keys[key_index]) orelse {
            allocator.free(current);
            return allocator.alloc(FileId, 0);
        };
        const merged = try intersectFileIds(allocator, current, ids);
        allocator.free(current);
        current = merged;
    }
    return current;
}

fn lookupFileIds(segment: PostingsSegment, key_value: TrigramKey) ?[]const FileId {
    var low: usize = 0;
    var high: usize = segment.entries.len;
    while (low < high) {
        const mid = low + (high - low) / 2;
        const entry = segment.entries[mid];
        if (entry.key == key_value) return segment.fileIds(entry);
        if (entry.key < key_value) {
            low = mid + 1;
        } else {
            high = mid;
        }
    }
    return null;
}

fn evaluateLookupPlanFromOpenFileHeader(
    io: std.Io,
    allocator: std.mem.Allocator,
    file: *std.Io.File,
    header: PostingsSegmentHeader,
    lookup: LookupPlan,
) ![]FileId {
    var current = try evaluateLookupGroupFromOpenFile(io, allocator, file, header, lookup.groups[0]);
    errdefer allocator.free(current);

    var group_index: usize = 1;
    while (group_index < lookup.group_count) : (group_index += 1) {
        const next_group = try evaluateLookupGroupFromOpenFile(io, allocator, file, header, lookup.groups[group_index]);
        defer allocator.free(next_group);
        const merged = switch (lookup.mode) {
            .all => try intersectFileIds(allocator, current, next_group),
            .any => try unionFileIds(allocator, current, next_group),
        };
        allocator.free(current);
        current = merged;
    }

    return current;
}

fn evaluateLookupGroupFromOpenFile(
    io: std.Io,
    allocator: std.mem.Allocator,
    file: *std.Io.File,
    header: PostingsSegmentHeader,
    group: LookupGroup,
) ![]FileId {
    if (group.key_count == 0) return allocator.alloc(FileId, 0);
    if (group.key_count > 1) {
        for (group.keys[0..group.key_count]) |key| {
            _ = try lookupEntryFromOpenFile(io, file, header, key) orelse return allocator.alloc(FileId, 0);
        }
    }

    var current = try lookupFileIdsFromOpenFile(io, allocator, file, header, group.keys[0]) orelse return allocator.alloc(FileId, 0);
    errdefer allocator.free(current);

    var key_index: usize = 1;
    while (key_index < group.key_count) : (key_index += 1) {
        const ids = try lookupFileIdsFromOpenFile(io, allocator, file, header, group.keys[key_index]) orelse {
            allocator.free(current);
            return allocator.alloc(FileId, 0);
        };
        defer allocator.free(ids);
        const merged = try intersectFileIds(allocator, current, ids);
        allocator.free(current);
        current = merged;
    }
    return current;
}

fn lookupFileIdsFromOpenFile(
    io: std.Io,
    allocator: std.mem.Allocator,
    file: *std.Io.File,
    header: PostingsSegmentHeader,
    key_value: TrigramKey,
) !?[]FileId {
    const entry = try lookupEntryFromOpenFile(io, file, header, key_value) orelse return null;
    return try readFileIdsForEntryFromOpenFile(io, allocator, file, header, entry);
}

fn readFileIdsForEntryFromOpenFile(
    io: std.Io,
    allocator: std.mem.Allocator,
    file: *std.Io.File,
    header: PostingsSegmentHeader,
    entry: PostingsEntry,
) ![]FileId {
    const count = try checkedCount(entry.file_count);
    const ids = try allocator.alloc(FileId, count);
    errdefer allocator.free(ids);
    const start = try fileIdByteOffset(header, entry.file_offset);
    var offset = start;
    for (ids) |*file_id| {
        file_id.* = try readU64At(io, file, offset);
        if (!catalog.isValidFileId(file_id.*)) return error.InvalidCatalogFileId;
        offset += SERIALIZED_FILE_ID_SIZE;
    }
    var index: usize = 1;
    while (index < ids.len) : (index += 1) {
        if (ids[index - 1] >= ids[index]) return error.DuplicateOrUnsortedPostingsFileIds;
    }
    return ids;
}

fn lookupEntryFromOpenFile(
    io: std.Io,
    file: *std.Io.File,
    header: PostingsSegmentHeader,
    key_value: TrigramKey,
) !?PostingsEntry {
    var low: u64 = 0;
    var high = header.trigram_count;
    while (low < high) {
        const mid = low + (high - low) / 2;
        const entry = try readEntryAt(io, file, try entryByteOffset(mid));
        if (entry.key == key_value) {
            if (!isValidEntryForHeader(entry, header)) return error.InvalidPostingsEntry;
            return entry;
        }
        if (entry.key < key_value) {
            low = mid + 1;
        } else {
            high = mid;
        }
    }
    return null;
}

fn validatePostingsHeader(header: PostingsSegmentHeader, expected_root: RootFingerprint, expected_generation: u64) !void {
    if (!std.mem.eql(u8, &header.magic, &MAGIC)) return error.InvalidPostingsMagic;
    if (header.version != FORMAT_VERSION) return error.UnsupportedPostingsVersion;
    if (header.header_size != @sizeOf(PostingsSegmentHeader)) return error.InvalidPostingsHeaderSize;
    if (header.rootFingerprint() != expected_root) return error.WrongPostingsRoot;
    if (header.generation != expected_generation) return error.WrongPostingsGeneration;
    _ = try checkedCount(header.trigram_count);
    _ = try checkedCount(header.postings_count);
}

fn isValidEntryForHeader(entry: PostingsEntry, header: PostingsSegmentHeader) bool {
    if (!isValidTrigramKey(entry.key)) return false;
    if (entry.file_offset > header.postings_count) return false;
    return entry.file_count <= header.postings_count - entry.file_offset;
}

fn entryByteOffset(entry_index: u64) !u64 {
    if (entry_index > (std.math.maxInt(u64) - SERIALIZED_HEADER_SIZE) / SERIALIZED_ENTRY_SIZE) return error.PostingsOffsetOverflow;
    return SERIALIZED_HEADER_SIZE + entry_index * SERIALIZED_ENTRY_SIZE;
}

fn fileIdsByteOffset(header: PostingsSegmentHeader) !u64 {
    if (header.trigram_count > (std.math.maxInt(u64) - SERIALIZED_HEADER_SIZE) / SERIALIZED_ENTRY_SIZE) return error.PostingsOffsetOverflow;
    return SERIALIZED_HEADER_SIZE + header.trigram_count * SERIALIZED_ENTRY_SIZE;
}

fn fileIdByteOffset(header: PostingsSegmentHeader, file_offset: u64) !u64 {
    const base = try fileIdsByteOffset(header);
    if (file_offset > (std.math.maxInt(u64) - base) / SERIALIZED_FILE_ID_SIZE) return error.PostingsOffsetOverflow;
    return base + file_offset * SERIALIZED_FILE_ID_SIZE;
}

fn readHeaderAt(io: std.Io, file: *std.Io.File, offset: u64) !PostingsSegmentHeader {
    var buffer: [SERIALIZED_HEADER_SIZE]u8 = undefined;
    try readExactAt(io, file, &buffer, offset);
    var cursor = Cursor{ .bytes = &buffer };
    return readHeader(&cursor);
}

fn readEntryAt(io: std.Io, file: *std.Io.File, offset: u64) !PostingsEntry {
    var buffer: [SERIALIZED_ENTRY_SIZE]u8 = undefined;
    try readExactAt(io, file, &buffer, offset);
    var cursor = Cursor{ .bytes = &buffer };
    return readEntry(&cursor);
}

fn readU64At(io: std.Io, file: *std.Io.File, offset: u64) !u64 {
    var buffer: [SERIALIZED_FILE_ID_SIZE]u8 = undefined;
    try readExactAt(io, file, &buffer, offset);
    var cursor = Cursor{ .bytes = &buffer };
    return cursor.readU64();
}

fn readExactAt(io: std.Io, file: *std.Io.File, buffer: []u8, offset: u64) !void {
    const read_len = try file.readPositionalAll(io, buffer, offset);
    if (read_len != buffer.len) return error.TruncatedPostingsSegment;
}

fn intersectFileIds(allocator: std.mem.Allocator, lhs: []const FileId, rhs: []const FileId) ![]FileId {
    var out = std.ArrayList(FileId).empty;
    errdefer out.deinit(allocator);

    var left_index: usize = 0;
    var right_index: usize = 0;
    while (left_index < lhs.len and right_index < rhs.len) {
        if (lhs[left_index] == rhs[right_index]) {
            try out.append(allocator, lhs[left_index]);
            left_index += 1;
            right_index += 1;
        } else if (lhs[left_index] < rhs[right_index]) {
            left_index += 1;
        } else {
            right_index += 1;
        }
    }
    return out.toOwnedSlice(allocator);
}

fn unionFileIds(allocator: std.mem.Allocator, lhs: []const FileId, rhs: []const FileId) ![]FileId {
    var out = std.ArrayList(FileId).empty;
    errdefer out.deinit(allocator);

    var left_index: usize = 0;
    var right_index: usize = 0;
    while (left_index < lhs.len or right_index < rhs.len) {
        const value = if (right_index >= rhs.len or (left_index < lhs.len and lhs[left_index] < rhs[right_index])) blk: {
            const file_id = lhs[left_index];
            left_index += 1;
            break :blk file_id;
        } else if (left_index >= lhs.len or rhs[right_index] < lhs[left_index]) blk: {
            const file_id = rhs[right_index];
            right_index += 1;
            break :blk file_id;
        } else blk: {
            const file_id = lhs[left_index];
            left_index += 1;
            right_index += 1;
            break :blk file_id;
        };
        if (out.items.len == 0 or out.items[out.items.len - 1] != value) try out.append(allocator, value);
    }
    return out.toOwnedSlice(allocator);
}

pub fn containsFileId(sorted_file_ids: []const FileId, file_id: FileId) bool {
    var low: usize = 0;
    var high: usize = sorted_file_ids.len;
    while (low < high) {
        const mid = low + (high - low) / 2;
        if (sorted_file_ids[mid] == file_id) return true;
        if (sorted_file_ids[mid] < file_id) {
            low = mid + 1;
        } else {
            high = mid;
        }
    }
    return false;
}

fn writeHeader(bytes: *std.ArrayList(u8), allocator: std.mem.Allocator, header: PostingsSegmentHeader) !void {
    try bytes.appendSlice(allocator, &header.magic);
    try appendU16(bytes, allocator, header.version);
    try appendU16(bytes, allocator, header.header_size);
    try appendU32(bytes, allocator, segmentFlagsBits(header.flags));
    try appendU64(bytes, allocator, header.root_fingerprint_hi);
    try appendU64(bytes, allocator, header.root_fingerprint_lo);
    try appendU64(bytes, allocator, header.generation);
    try appendU64(bytes, allocator, header.trigram_count);
    try appendU64(bytes, allocator, header.postings_count);
    try appendU64(bytes, allocator, header.file_count);
    try appendU64(bytes, allocator, header.verify_required_count);
}

fn readHeader(cursor: *Cursor) !PostingsSegmentHeader {
    var header = PostingsSegmentHeader{};
    @memcpy(&header.magic, try cursor.take(MAGIC.len));
    header.version = try cursor.readU16();
    header.header_size = try cursor.readU16();
    header.flags = segmentFlagsFromBits(try cursor.readU32());
    header.root_fingerprint_hi = try cursor.readU64();
    header.root_fingerprint_lo = try cursor.readU64();
    header.generation = try cursor.readU64();
    header.trigram_count = try cursor.readU64();
    header.postings_count = try cursor.readU64();
    header.file_count = try cursor.readU64();
    header.verify_required_count = try cursor.readU64();
    return header;
}

fn writeEntry(bytes: *std.ArrayList(u8), allocator: std.mem.Allocator, entry: PostingsEntry) !void {
    try appendU32(bytes, allocator, entry.key);
    try appendU64(bytes, allocator, entry.file_offset);
    try appendU32(bytes, allocator, entry.file_count);
    try bytes.append(allocator, @intFromEnum(entry.density));
    try bytes.append(allocator, entry.reserved);
    try appendU16(bytes, allocator, entry.reserved2);
}

fn readEntry(cursor: *Cursor) !PostingsEntry {
    return .{
        .key = try cursor.readU32(),
        .file_offset = try cursor.readU64(),
        .file_count = try cursor.readU32(),
        .density = try densityFromByte(try cursor.readByte()),
        .reserved = try cursor.readByte(),
        .reserved2 = try cursor.readU16(),
    };
}

fn densityFromByte(value: u8) !DensityClass {
    return switch (value) {
        0 => .empty,
        1 => .sparse,
        2 => .medium,
        3 => .dense,
        else => error.InvalidPostingsDensity,
    };
}

fn segmentFlagsBits(flags: SegmentFlags) u32 {
    var bits: u32 = 0;
    if (flags.sorted_keys) bits |= 1 << 0;
    if (flags.sorted_file_ids) bits |= 1 << 1;
    if (flags.unique_file_ids) bits |= 1 << 2;
    return bits;
}

fn segmentFlagsFromBits(bits: u32) SegmentFlags {
    return .{
        .sorted_keys = (bits & (1 << 0)) != 0,
        .sorted_file_ids = (bits & (1 << 1)) != 0,
        .unique_file_ids = (bits & (1 << 2)) != 0,
    };
}

fn checkedCount(value: u64) !usize {
    if (value > std.math.maxInt(usize)) return error.PostingsCountOverflow;
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

const Cursor = struct {
    bytes: []const u8,
    offset: usize = 0,

    fn take(self: *Cursor, len: usize) ![]const u8 {
        if (len > self.bytes.len - self.offset) return error.TruncatedPostingsSegment;
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
};

test "postings constants define a versioned file format" {
    try std.testing.expectEqualStrings("IXPOST01", &MAGIC);
    try std.testing.expectEqual(@as(u16, 2), FORMAT_VERSION);
    try std.testing.expect(MIN_HEADER_SIZE >= 64);
}

test "postings root fingerprint splits and joins deterministically" {
    const fingerprint: RootFingerprint = 0x102030405060708090a0b0c0d0e0f000;
    const header = PostingsSegmentHeader.withRootFingerprint(fingerprint);
    try std.testing.expectEqual(@as(u64, 0x1020304050607080), header.root_fingerprint_hi);
    try std.testing.expectEqual(@as(u64, 0x90a0b0c0d0e0f000), header.root_fingerprint_lo);
    try std.testing.expectEqual(fingerprint, header.rootFingerprint());
}

test "postings trigram key round trips raw bytes" {
    const key = makeTrigramKey(&.{ 'a', 'u', 't' });
    try std.testing.expectEqual(@as(TrigramKey, 0x617574), key);
    try std.testing.expectEqual([3]u8{ 'a', 'u', 't' }, trigramBytes(key));
}

test "postings density class keeps empty sparse medium and dense distinct" {
    try std.testing.expectEqual(DensityClass.empty, classifyDensity(0, 100));
    try std.testing.expectEqual(DensityClass.sparse, classifyDensity(4, 100));
    try std.testing.expectEqual(DensityClass.medium, classifyDensity(10, 100));
    try std.testing.expectEqual(DensityClass.dense, classifyDensity(30, 100));
}

test "postings entry validates file id bounds" {
    const entry = PostingsEntry{
        .key = makeTrigramKey(&.{ 'i', 'd', 'x' }),
        .file_offset = 1,
        .file_count = 2,
        .density = .sparse,
    };
    try std.testing.expect(isValidEntry(entry, 3));

    var broken = entry;
    broken.file_count = 3;
    try std.testing.expect(!isValidEntry(broken, 3));
}

test "postings extraction returns sorted unique overlapping trigrams" {
    const keys = try extractFileTrigrams(std.testing.allocator, "banana");
    defer std.testing.allocator.free(keys);

    try std.testing.expectEqual(@as(usize, 3), keys.len);
    try std.testing.expectEqual(makeTrigramKey(&.{ 'a', 'n', 'a' }), keys[0]);
    try std.testing.expectEqual(makeTrigramKey(&.{ 'b', 'a', 'n' }), keys[1]);
    try std.testing.expectEqual(makeTrigramKey(&.{ 'n', 'a', 'n' }), keys[2]);
}

test "postings extraction is binary safe" {
    const keys = try extractFileTrigrams(std.testing.allocator, "\x00ab\x00ab");
    defer std.testing.allocator.free(keys);

    try std.testing.expectEqual(@as(usize, 3), keys.len);
    try std.testing.expectEqual(makeTrigramKey(&.{ 0, 'a', 'b' }), keys[0]);
    try std.testing.expectEqual(makeTrigramKey(&.{ 'a', 'b', 0 }), keys[1]);
    try std.testing.expectEqual(makeTrigramKey(&.{ 'b', 0, 'a' }), keys[2]);
}

test "postings extraction drops reserved zero trigram sentinel" {
    const keys = try extractFileTrigrams(std.testing.allocator, "\x00\x00\x00abc");
    defer std.testing.allocator.free(keys);

    for (keys) |key| try std.testing.expect(isValidTrigramKey(key));
    try std.testing.expectEqual(@as(usize, 3), keys.len);
    try std.testing.expectEqual(makeTrigramKey(&.{ 0, 0, 'a' }), keys[0]);
    try std.testing.expectEqual(makeTrigramKey(&.{ 0, 'a', 'b' }), keys[1]);
    try std.testing.expectEqual(makeTrigramKey(&.{ 'a', 'b', 'c' }), keys[2]);
}

test "postings extraction handles files shorter than one trigram" {
    const keys = try extractFileTrigrams(std.testing.allocator, "ix");
    defer std.testing.allocator.free(keys);
    try std.testing.expectEqual(@as(usize, 0), keys.len);
}

test "postings builder emits sorted unique trigram to file-id postings" {
    const files = [_]PostingsFileInput{
        .{ .file_id = catalog.makeFileId(0), .bytes = "banana" },
        .{ .file_id = catalog.makeFileId(1), .bytes = "bandana" },
        .{ .file_id = catalog.makeFileId(2), .bytes = "ix" },
    };
    const segment = try buildPostingsSegment(std.testing.allocator, 0x1234, 7, &files, 0);
    defer segment.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(u64, 7), segment.header.generation);
    try std.testing.expectEqual(@as(u64, 3), segment.header.file_count);
    try std.testing.expect(segment.entries.len > 0);
    try std.testing.expectEqual(makeTrigramKey(&.{ 'a', 'n', 'a' }), segment.entries[0].key);
    try std.testing.expectEqualSlices(FileId, &.{ catalog.makeFileId(0), catalog.makeFileId(1) }, segment.fileIds(segment.entries[0]));

    var index: usize = 1;
    while (index < segment.entries.len) : (index += 1) {
        try std.testing.expect(segment.entries[index - 1].key < segment.entries[index].key);
        try std.testing.expect(isValidEntry(segment.entries[index], segment.file_ids.len));
    }
}

test "postings builder rejects invalid catalog file ids" {
    const files = [_]PostingsFileInput{
        .{ .file_id = catalog.INVALID_FILE_ID, .bytes = "auth" },
    };
    try std.testing.expectError(error.InvalidCatalogFileId, buildPostingsSegment(std.testing.allocator, 1, 1, &files, 0));
}

test "postings builder deduplicates repeated file trigram pairs" {
    const files = [_]PostingsFileInput{
        .{ .file_id = catalog.makeFileId(0), .bytes = "auth" },
        .{ .file_id = catalog.makeFileId(0), .bytes = "auth" },
    };
    const segment = try buildPostingsSegment(std.testing.allocator, 1, 1, &files, 0);
    defer segment.deinit(std.testing.allocator);

    const key = makeTrigramKey(&.{ 'a', 'u', 't' });
    const file_ids = lookupFileIds(segment, key) orelse return error.TestExpectedPostingsEntry;

    try std.testing.expectEqualSlices(FileId, &.{catalog.makeFileId(0)}, file_ids);
}

test "postings lookup lowering maps expression evidence to lookup keys" {
    const plan = try expr.parse("lit:auth && re:token_\\d+");
    const lookup = lowerExpressionToLookupPlan(plan);

    try std.testing.expect(lookup.eligible);
    try std.testing.expectEqual(LookupMode.all, lookup.mode);
    try std.testing.expectEqual(@as(usize, 2), lookup.group_count);
    try std.testing.expectEqual(makeTrigramKey(&.{ 'a', 'u', 't' }), lookup.groups[0].keys[0]);
    try std.testing.expectEqual(makeTrigramKey(&.{ 't', 'o', 'k' }), lookup.groups[1].keys[0]);
    try std.testing.expectEqual(LookupFallback.none, lookup.fallback);
}

test "postings lookup lowering maps literal alternate regex to branch evidence" {
    const lookup = lowerExpressionToLookupPlan(try expr.parse("re:(alpha|beta)"));

    try std.testing.expect(lookup.eligible);
    try std.testing.expectEqual(LookupMode.any, lookup.mode);
    try std.testing.expectEqual(@as(usize, 2), lookup.group_count);
    try std.testing.expectEqual(LookupFallback.none, lookup.fallback);
    try std.testing.expectEqual(makeTrigramKey(&.{ 'a', 'l', 'p' }), lookup.groups[0].keys[0]);
    try std.testing.expectEqual(makeTrigramKey(&.{ 'l', 'p', 'h' }), lookup.groups[0].keys[1]);
    try std.testing.expectEqual(makeTrigramKey(&.{ 'p', 'h', 'a' }), lookup.groups[0].keys[2]);
    try std.testing.expectEqual(makeTrigramKey(&.{ 'b', 'e', 't' }), lookup.groups[1].keys[0]);
    try std.testing.expectEqual(makeTrigramKey(&.{ 'e', 't', 'a' }), lookup.groups[1].keys[1]);
}

test "postings lookup lowering refuses literal alternates with short evidence branch" {
    const lookup = lowerExpressionToLookupPlan(try expr.parse("re:(alpha|ix)"));

    try std.testing.expect(!lookup.eligible);
    try std.testing.expectEqual(LookupFallback.no_mandatory_evidence, lookup.fallback);
    try std.testing.expect(lookupRequiresFullScan(lookup));
}

test "postings lookup lowering fails closed for unindexed disjunction branch" {
    const plan = try expr.parse("lit:auth || lit:x");
    const lookup = lowerExpressionToLookupPlan(plan);

    try std.testing.expect(!lookup.eligible);
    try std.testing.expectEqual(LookupMode.any, lookup.mode);
    try std.testing.expectEqual(@as(usize, 0), lookup.group_count);
    try std.testing.expectEqual(LookupFallback.disjunction_has_unindexed_branch, lookup.fallback);
    try std.testing.expect(lookupRequiresFullScan(lookup));
    try std.testing.expectEqualStrings("disjunction_has_unindexed_branch", lookupFallbackReasonText(lookup));
}

test "postings lookup lowering forces full scan for no-evidence query" {
    const lookup = lowerExpressionToLookupPlan(try expr.parse("lit:ix"));

    try std.testing.expect(!lookup.eligible);
    try std.testing.expectEqual(LookupFallback.no_mandatory_evidence, lookup.fallback);
    try std.testing.expect(lookupRequiresFullScan(lookup));
    try std.testing.expectEqualStrings("no_mandatory_evidence", lookupFallbackReasonText(lookup));
}

test "postings lookup evaluation intersects mandatory evidence" {
    const files = [_]PostingsFileInput{
        .{ .file_id = catalog.makeFileId(0), .bytes = "auth token" },
        .{ .file_id = catalog.makeFileId(1), .bytes = "auth only" },
        .{ .file_id = catalog.makeFileId(2), .bytes = "token only" },
    };
    const segment = try buildPostingsSegment(std.testing.allocator, 1, 1, &files, 0);
    defer segment.deinit(std.testing.allocator);

    const lookup = lowerExpressionToLookupPlan(try expr.parse("lit:auth && lit:token"));
    const candidates = try evaluateLookupPlan(std.testing.allocator, segment, lookup);
    defer std.testing.allocator.free(candidates);

    try std.testing.expectEqualSlices(FileId, &.{catalog.makeFileId(0)}, candidates);
}

test "postings lookup evaluation unions disjunctive evidence" {
    const files = [_]PostingsFileInput{
        .{ .file_id = catalog.makeFileId(0), .bytes = "auth" },
        .{ .file_id = catalog.makeFileId(1), .bytes = "token" },
        .{ .file_id = catalog.makeFileId(2), .bytes = "none" },
    };
    const segment = try buildPostingsSegment(std.testing.allocator, 1, 1, &files, 0);
    defer segment.deinit(std.testing.allocator);

    const lookup = lowerExpressionToLookupPlan(try expr.parse("lit:auth || lit:token"));
    const candidates = try evaluateLookupPlan(std.testing.allocator, segment, lookup);
    defer std.testing.allocator.free(candidates);

    try std.testing.expectEqualSlices(FileId, &.{ catalog.makeFileId(0), catalog.makeFileId(1) }, candidates);
}

test "postings lookup evaluation unions literal alternate regex branch evidence" {
    const files = [_]PostingsFileInput{
        .{ .file_id = catalog.makeFileId(0), .bytes = "alpha" },
        .{ .file_id = catalog.makeFileId(1), .bytes = "beta" },
        .{ .file_id = catalog.makeFileId(2), .bytes = "gamma" },
        .{ .file_id = catalog.makeFileId(3), .bytes = "alphabet" },
    };
    const segment = try buildPostingsSegment(std.testing.allocator, 1, 1, &files, 0);
    defer segment.deinit(std.testing.allocator);

    const lookup = lowerExpressionToLookupPlan(try expr.parse("re:(alpha|beta)"));
    const candidates = try evaluateLookupPlan(std.testing.allocator, segment, lookup);
    defer std.testing.allocator.free(candidates);

    try std.testing.expectEqualSlices(FileId, &.{ catalog.makeFileId(0), catalog.makeFileId(1), catalog.makeFileId(3) }, candidates);
}

test "postings lookup evaluation returns empty candidates for missing evidence" {
    const files = [_]PostingsFileInput{
        .{ .file_id = catalog.makeFileId(0), .bytes = "auth" },
    };
    const segment = try buildPostingsSegment(std.testing.allocator, 1, 1, &files, 0);
    defer segment.deinit(std.testing.allocator);

    const lookup = lowerExpressionToLookupPlan(try expr.parse("lit:missing"));
    const candidates = try evaluateLookupPlan(std.testing.allocator, segment, lookup);
    defer std.testing.allocator.free(candidates);

    try std.testing.expectEqual(@as(usize, 0), candidates.len);
}

test "postings file lookup evaluates candidates without full segment parse" {
    const files = [_]PostingsFileInput{
        .{ .file_id = catalog.makeFileId(0), .bytes = "alpha beta gamma" },
        .{ .file_id = catalog.makeFileId(1), .bytes = "alpha gamma" },
        .{ .file_id = catalog.makeFileId(2), .bytes = "beta gamma" },
        .{ .file_id = catalog.makeFileId(3), .bytes = "omega" },
    };
    const segment = try buildPostingsSegment(std.testing.allocator, 0x1234, 77, &files, 0);
    defer segment.deinit(std.testing.allocator);
    const encoded = try serializePostingsSegment(std.testing.allocator, segment);
    defer std.testing.allocator.free(encoded);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "postings.ixpost", .data = encoded });
    var file = try tmp.dir.openFile(std.testing.io, "postings.ixpost", .{});
    defer file.close(std.testing.io);

    const lookup = lowerExpressionToLookupPlan(try expr.parse("lit:alpha && lit:gamma"));
    const expected = try evaluateLookupPlan(std.testing.allocator, segment, lookup);
    defer std.testing.allocator.free(expected);
    const actual = try evaluateLookupPlanFromOpenFile(std.testing.io, std.testing.allocator, &file, 0x1234, 77, lookup);
    defer actual.deinit(std.testing.allocator);

    try std.testing.expectEqual(segment.header.trigram_count, actual.header.trigram_count);
    try std.testing.expectEqual(segment.header.postings_count, actual.header.postings_count);
    try std.testing.expectEqualSlices(FileId, expected, actual.candidates);
}

test "postings lookup evaluation refuses unsafe fallback as zero candidates" {
    const files = [_]PostingsFileInput{
        .{ .file_id = catalog.makeFileId(0), .bytes = "auth" },
    };
    const segment = try buildPostingsSegment(std.testing.allocator, 1, 1, &files, 0);
    defer segment.deinit(std.testing.allocator);

    const lookup = lowerExpressionToLookupPlan(try expr.parse("lit:auth || lit:x"));

    try std.testing.expect(lookupRequiresFullScan(lookup));
    try std.testing.expectError(error.RequiresFullScan, evaluateLookupPlan(std.testing.allocator, segment, lookup));
}

test "postings candidates select catalog entries for verifier handoff" {
    const catalog_files = [_]catalog.CatalogFileInput{
        .{ .path = "src/main.zig", .size = 10, .mtime_ns = 1, .sample = "main" },
        .{ .path = "README.md", .size = 20, .mtime_ns = 2, .sample = "readme" },
        .{ .path = "src/core/search.zig", .size = 30, .mtime_ns = 3, .sample = "search" },
    };
    const encoded = try catalog.buildCatalogBytes(std.testing.allocator, "E:\\Workspaces\\ix-zig", 1, &catalog_files);
    defer std.testing.allocator.free(encoded);
    const snapshot = try catalog.parseCatalog(std.testing.allocator, encoded);
    defer snapshot.deinit(std.testing.allocator);

    const selected = try selectCatalogEntriesForCandidates(std.testing.allocator, snapshot, &.{ catalog.makeFileId(0), catalog.makeFileId(2) });
    defer std.testing.allocator.free(selected);

    try std.testing.expectEqual(@as(usize, 2), selected.len);
    try std.testing.expectEqual(catalog.makeFileId(0), selected[0].file_id);
    try std.testing.expectEqualStrings("README.md", snapshot.path(selected[0]));
    try std.testing.expectEqual(catalog.makeFileId(2), selected[1].file_id);
    try std.testing.expectEqualStrings("src/main.zig", snapshot.path(selected[1]));
}

test "postings serialization round trips header entries and file ids" {
    const files = [_]PostingsFileInput{
        .{ .file_id = catalog.makeFileId(0), .bytes = "auth" },
        .{ .file_id = catalog.makeFileId(1), .bytes = "author" },
    };
    const segment = try buildPostingsSegment(std.testing.allocator, 0xfeed, 3, &files, 2);
    defer segment.deinit(std.testing.allocator);

    const encoded = try serializePostingsSegment(std.testing.allocator, segment);
    defer std.testing.allocator.free(encoded);

    const parsed = try parsePostingsSegment(std.testing.allocator, encoded);
    defer parsed.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(RootFingerprint, 0xfeed), parsed.header.rootFingerprint());
    try std.testing.expectEqual(@as(u64, 3), parsed.header.generation);
    try std.testing.expectEqual(@as(u64, 2), parsed.header.verify_required_count);
    try std.testing.expectEqual(segment.entries.len, parsed.entries.len);
    try std.testing.expectEqual(segment.file_ids.len, parsed.file_ids.len);
    try std.testing.expectEqual(segment.entries[0].key, parsed.entries[0].key);
    try std.testing.expectEqualSlices(FileId, segment.fileIds(segment.entries[0]), parsed.fileIds(parsed.entries[0]));
}

test "postings parser rejects invalid magic" {
    const segment = PostingsSegment{
        .header = PostingsSegmentHeader.withRootFingerprint(1),
        .entries = &.{},
        .file_ids = &.{},
    };
    const encoded = try serializePostingsSegment(std.testing.allocator, segment);
    defer std.testing.allocator.free(encoded);
    encoded[0] = 'x';

    try std.testing.expectError(error.InvalidPostingsMagic, parsePostingsSegment(std.testing.allocator, encoded));
}

test "postings parser rejects invalid density byte" {
    const files = [_]PostingsFileInput{
        .{ .file_id = catalog.makeFileId(0), .bytes = "auth" },
    };
    const segment = try buildPostingsSegment(std.testing.allocator, 0xfeed, 3, &files, 0);
    defer segment.deinit(std.testing.allocator);

    const encoded = try serializePostingsSegment(std.testing.allocator, segment);
    defer std.testing.allocator.free(encoded);

    const density_offset: usize = @intCast(SERIALIZED_HEADER_SIZE + 4 + 8 + 4);
    encoded[density_offset] = 255;

    try std.testing.expectError(error.InvalidPostingsDensity, parsePostingsSegment(std.testing.allocator, encoded));
}

test "postings parser rejects wrong root and generation" {
    const segment = PostingsSegment{
        .header = blk: {
            var header = PostingsSegmentHeader.withRootFingerprint(10);
            header.generation = 5;
            break :blk header;
        },
        .entries = &.{},
        .file_ids = &.{},
    };
    const encoded = try serializePostingsSegment(std.testing.allocator, segment);
    defer std.testing.allocator.free(encoded);

    try std.testing.expectError(error.WrongPostingsRoot, parsePostingsSegmentForRootGeneration(std.testing.allocator, encoded, 11, 5));
    try std.testing.expectError(error.WrongPostingsGeneration, parsePostingsSegmentForRootGeneration(std.testing.allocator, encoded, 10, 6));
}

test "postings parser rejects truncated segments" {
    const segment = PostingsSegment{
        .header = PostingsSegmentHeader.withRootFingerprint(1),
        .entries = &.{},
        .file_ids = &.{},
    };
    const encoded = try serializePostingsSegment(std.testing.allocator, segment);
    defer std.testing.allocator.free(encoded);

    try std.testing.expectError(error.TruncatedPostingsSegment, parsePostingsSegment(std.testing.allocator, encoded[0 .. encoded.len - 1]));
}

test "postings parser rejects unsorted keys and duplicate file ids" {
    const unsorted_entries = [_]PostingsEntry{
        .{ .key = makeTrigramKey(&.{ 'z', 'z', 'z' }), .file_offset = 0, .file_count = 1, .density = .sparse },
        .{ .key = makeTrigramKey(&.{ 'a', 'a', 'a' }), .file_offset = 1, .file_count = 1, .density = .sparse },
    };
    const unsorted_ids = [_]FileId{ catalog.makeFileId(0), catalog.makeFileId(1) };
    const unsorted = PostingsSegment{
        .header = PostingsSegmentHeader.withRootFingerprint(1),
        .entries = @constCast(&unsorted_entries),
        .file_ids = @constCast(&unsorted_ids),
    };
    const unsorted_encoded = try serializePostingsSegment(std.testing.allocator, unsorted);
    defer std.testing.allocator.free(unsorted_encoded);
    try std.testing.expectError(error.UnsortedPostingsKeys, parsePostingsSegment(std.testing.allocator, unsorted_encoded));

    const duplicate_entries = [_]PostingsEntry{
        .{ .key = makeTrigramKey(&.{ 'a', 'u', 't' }), .file_offset = 0, .file_count = 2, .density = .sparse },
    };
    const duplicate_ids = [_]FileId{ catalog.makeFileId(0), catalog.makeFileId(0) };
    const duplicate = PostingsSegment{
        .header = PostingsSegmentHeader.withRootFingerprint(1),
        .entries = @constCast(&duplicate_entries),
        .file_ids = @constCast(&duplicate_ids),
    };
    const duplicate_encoded = try serializePostingsSegment(std.testing.allocator, duplicate);
    defer std.testing.allocator.free(duplicate_encoded);
    try std.testing.expectError(error.DuplicateOrUnsortedPostingsFileIds, parsePostingsSegment(std.testing.allocator, duplicate_encoded));
}
