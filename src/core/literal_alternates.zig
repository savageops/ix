const std = @import("std");
const pcre_regex = @import("pcre_regex.zig");
const simd = @import("simd.zig");
const sz = @import("sz.zig");

pub const MAX_BRANCHES = 32;
const TEDDY_MAX_BRANCHES = 8;
const TEDDY_FINGERPRINT_BYTES = 3;
const TEDDY_BUCKETS = 8;
const TEDDY_RANGE_SHIFT_MIN_LINE_BYTES = 64;
const COUNTER_CACHE_ENV = "IX_LITERAL_ALTERNATES_COUNTER_CACHE";

pub const RangeCount = struct {
    matches: usize = 0,
    used_pcre: bool = false,
    used_teddy: bool = false,
    bailed_out: bool = false,
};

pub const Counter = struct {
    alternates: LiteralAlternates,
    teddy_plan: ?TeddyPlan = null,
    short_line_teddy_plan: ?TeddyPlan = null,

    pub inline fn init(pattern: []const u8, case_insensitive: bool) ?Counter {
        return initWithFingerprintOffset(pattern, case_insensitive, null);
    }

    pub inline fn initWithFingerprintOffset(pattern: []const u8, case_insensitive: bool, fingerprint_offset: ?usize) ?Counter {
        const alternates = parse(pattern) orelse return null;
        return .{
            .alternates = alternates,
            .teddy_plan = teddyPlanWithOffset(alternates, case_insensitive, fingerprint_offset),
            .short_line_teddy_plan = null,
        };
    }

    pub inline fn initForLogicalLineRange(pattern: []const u8, case_insensitive: bool) ?Counter {
        const alternates = parse(pattern) orelse return null;
        const range_offset = teddyRangeFingerprintOffset(alternates);
        return .{
            .alternates = alternates,
            .teddy_plan = teddyPlanWithOffset(alternates, case_insensitive, range_offset),
            .short_line_teddy_plan = if (range_offset != null) teddyPlanWithOffset(alternates, case_insensitive, 0) else null,
        };
    }

    pub inline fn countMatches(self: *const Counter, line: []const u8, case_insensitive: bool) usize {
        if (self.short_line_teddy_plan) |*plan| {
            if (line.len < TEDDY_RANGE_SHIFT_MIN_LINE_BYTES) {
                return countTeddyPrefix3(line, &self.alternates, plan, case_insensitive);
            }
        }
        if (self.teddy_plan) |*plan| {
            return countTeddyPrefix3(line, &self.alternates, plan, case_insensitive);
        }
        return self.alternates.countMatchesScalar(line, case_insensitive);
    }

    pub inline fn usesTeddy(self: *const Counter) bool {
        return self.teddy_plan != null;
    }
};

const CachedCounter = struct {
    pattern_ptr: [*]const u8 = undefined,
    pattern_len: usize = 0,
    case_insensitive: bool = false,
    counter: Counter = undefined,
    state: State = .empty,

    const State = enum { empty, compiled, failed };

    inline fn isCacheHit(self: *const CachedCounter, pattern: []const u8, case_insensitive: bool) bool {
        return self.state != .empty and
            self.pattern_ptr == pattern.ptr and
            self.pattern_len == pattern.len and
            self.case_insensitive == case_insensitive;
    }

    inline fn ensureCompiled(self: *CachedCounter, pattern: []const u8, case_insensitive: bool) ?*const Counter {
        if (self.isCacheHit(pattern, case_insensitive)) {
            return if (self.state == .compiled) &self.counter else null;
        }

        self.pattern_ptr = pattern.ptr;
        self.pattern_len = pattern.len;
        self.case_insensitive = case_insensitive;
        if (Counter.init(pattern, case_insensitive)) |counter| {
            self.counter = counter;
            self.state = .compiled;
            return &self.counter;
        }
        self.state = .failed;
        return null;
    }
};

threadlocal var counter_cache: CachedCounter = .{};

const CounterCacheSwitch = enum { unknown, disabled, enabled };
threadlocal var counter_cache_switch: CounterCacheSwitch = .unknown;

inline fn counterCacheEnabled() bool {
    switch (counter_cache_switch) {
        .enabled => return true,
        .disabled => return false,
        .unknown => {
            const value_ptr = std.c.getenv(COUNTER_CACHE_ENV) orelse {
                counter_cache_switch = .enabled;
                return true;
            };
            const value = std.mem.span(value_ptr);
            const disabled = std.mem.eql(u8, value, "0") or
                std.ascii.eqlIgnoreCase(value, "false") or
                std.ascii.eqlIgnoreCase(value, "no") or
                std.ascii.eqlIgnoreCase(value, "off");
            counter_cache_switch = if (disabled) .disabled else .enabled;
            return !disabled;
        },
    }
}

pub const LiteralAlternates = struct {
    branches: [MAX_BRANCHES][]const u8 = undefined,
    first_byte_mask: [4]u64 = [_]u64{0} ** 4,
    first_byte_folded_mask: [4]u64 = [_]u64{0} ** 4,
    first_byte_set: sz.ByteSet = .{},
    first_byte_case_set: sz.ByteSet = .{},
    first_byte_folded_set: sz.ByteSet = .{},
    first_byte_branch_masks: [256]u32 = [_]u32{0} ** 256,
    first_byte_folded_branch_masks: [256]u32 = [_]u32{0} ** 256,
    count: usize = 0,

    pub fn slice(self: *const LiteralAlternates) []const []const u8 {
        return self.branches[0..self.count];
    }

    pub fn addBranch(self: *LiteralAlternates, branch: []const u8) void {
        const byte = branch[0];
        const lower = std.ascii.toLower(byte);
        const upper = std.ascii.toUpper(byte);
        const branch_index = self.count;
        const branch_bit = @as(u32, 1) << @intCast(branch_index);
        self.branches[self.count] = branch;
        self.count += 1;
        setByteMask(&self.first_byte_mask, byte);
        setByteMask(&self.first_byte_folded_mask, lower);
        self.first_byte_set.add(byte);
        self.first_byte_case_set.add(byte);
        self.first_byte_case_set.add(lower);
        self.first_byte_case_set.add(upper);
        self.first_byte_folded_set.add(lower);
        self.first_byte_branch_masks[byte] |= branch_bit;
        self.first_byte_folded_branch_masks[lower] |= branch_bit;
    }

    pub fn mayContainStartByte(self: *const LiteralAlternates, line: []const u8, case_insensitive: bool) bool {
        if (line.len == 0) return false;
        return self.nextStartByteOffset(line, case_insensitive) != null;
    }

    pub inline fn column(self: *const LiteralAlternates, line: []const u8, case_insensitive: bool) ?usize {
        var cursor: usize = 0;
        while (cursor < line.len) {
            const remaining = line[cursor..];
            const start_offset = self.nextStartByteOffset(remaining, case_insensitive) orelse return null;
            cursor += start_offset;
            const candidate = line[cursor..];
            if (self.firstMatchingBranchLen(candidate, case_insensitive) != null) return cursor + 1;
            cursor += 1;
        }
        return null;
    }

    pub inline fn countMatches(self: *const LiteralAlternates, line: []const u8, case_insensitive: bool) usize {
        const counter = Counter{
            .alternates = self.*,
            .teddy_plan = teddyPlanWithOffset(self.*, case_insensitive, null),
            .short_line_teddy_plan = null,
        };
        return counter.countMatches(line, case_insensitive);
    }

    pub inline fn countMatchesScalar(self: *const LiteralAlternates, line: []const u8, case_insensitive: bool) usize {
        var total: usize = 0;
        var cursor: usize = 0;
        while (cursor < line.len) {
            const remaining = line[cursor..];
            const start_offset = self.nextStartByteOffset(remaining, case_insensitive) orelse break;
            cursor += start_offset;
            const candidate = line[cursor..];
            const best_len = self.firstMatchingBranchLen(candidate, case_insensitive) orelse {
                cursor += 1;
                continue;
            };
            total += 1;
            cursor += best_len;
        }
        return total;
    }

    pub inline fn nextStartByteOffset(self: *const LiteralAlternates, line: []const u8, case_insensitive: bool) ?usize {
        if (line.len == 0) return null;
        if (!case_insensitive) return sz.indexOfByteSet(line, &self.first_byte_set);
        return sz.indexOfByteSet(line, &self.first_byte_case_set);
    }

    pub inline fn firstMatchingBranchLen(self: *const LiteralAlternates, candidate: []const u8, case_insensitive: bool) ?usize {
        if (candidate.len == 0) return null;
        var branch_mask = self.branchMaskForByte(candidate[0], case_insensitive);
        while (branch_mask != 0) {
            const branch_index: u5 = @intCast(@ctz(branch_mask));
            branch_mask &= branch_mask - 1;
            const branch = self.branches[branch_index];
            if (startsWithLiteral(candidate, branch, case_insensitive)) return branch.len;
        }
        return null;
    }

    pub inline fn branchMaskForByte(self: *const LiteralAlternates, byte: u8, case_insensitive: bool) u32 {
        if (!case_insensitive) return self.first_byte_branch_masks[byte];
        return self.first_byte_folded_branch_masks[std.ascii.toLower(byte)];
    }
};

pub const TeddyPlan = struct {
    branch_count: usize = 0,
    fingerprint_bytes: usize = TEDDY_FINGERPRINT_BYTES,
    fingerprint_offset: usize = 0,
    bucket_count: usize = TEDDY_BUCKETS,
    bucket_masks: [TEDDY_BUCKETS]u32 = [_]u32{0} ** TEDDY_BUCKETS,
    fingerprint_first_set: sz.ByteSet = .{},
    fingerprint_first_case_set: sz.ByteSet = .{},
    fingerprints: [MAX_BRANCHES][TEDDY_FINGERPRINT_BYTES]u8 = undefined,
};

pub inline fn teddyPlan(alternates: LiteralAlternates, case_insensitive: bool) ?TeddyPlan {
    return teddyPlanWithOffset(alternates, case_insensitive, null);
}

pub inline fn teddyPlanWithOffset(alternates: LiteralAlternates, case_insensitive: bool, fingerprint_offset: ?usize) ?TeddyPlan {
    if (alternates.count < 2 or alternates.count > TEDDY_MAX_BRANCHES) return null;
    const branches = alternates.slice();
    for (branches, 0..) |branch, index| {
        if (branch.len < TEDDY_FINGERPRINT_BYTES) return null;
        if (std.mem.indexOfScalar(u8, branch, '\\') != null) return null;
        for (branches[index + 1 ..]) |other| {
            if (literalPrefixCollision(branch, other, case_insensitive)) return null;
        }
    }

    var plan = TeddyPlan{ .branch_count = alternates.count };
    var min_branch_len: usize = std.math.maxInt(usize);
    for (branches) |branch| min_branch_len = @min(min_branch_len, branch.len);
    const max_offset = min_branch_len - TEDDY_FINGERPRINT_BYTES;
    plan.fingerprint_offset = if (fingerprint_offset) |offset|
        @min(offset, max_offset)
    else
        teddyFingerprintOffsetOverride(max_offset);
    for (branches, 0..) |branch, index| {
        const bucket = index % TEDDY_BUCKETS;
        plan.bucket_masks[bucket] |= @as(u32, 1) << @intCast(index);
        for (0..TEDDY_FINGERPRINT_BYTES) |fingerprint_index| {
            const byte = branch[plan.fingerprint_offset + fingerprint_index];
            const folded = if (case_insensitive) std.ascii.toLower(byte) else byte;
            plan.fingerprints[index][fingerprint_index] = folded;
            if (fingerprint_index == 0) {
                plan.fingerprint_first_set.add(folded);
                plan.fingerprint_first_case_set.add(folded);
                if (case_insensitive) {
                    plan.fingerprint_first_case_set.add(std.ascii.toUpper(byte));
                    plan.fingerprint_first_case_set.add(std.ascii.toLower(byte));
                }
            }
        }
    }
    return plan;
}

pub inline fn column(line: []const u8, pattern: []const u8, case_insensitive: bool) ?usize {
    if (counterCacheEnabled()) {
        if (counter_cache.ensureCompiled(pattern, case_insensitive)) |counter| {
            return counter.alternates.column(line, case_insensitive);
        }
    }

    var best: ?usize = null;
    var start: usize = 0;
    while (start <= pattern.len) {
        const end = std.mem.indexOfScalarPos(u8, pattern, start, '|') orelse pattern.len;
        const branch = pattern[start..end];
        if (branch.len > 0) {
            if (indexOfLiteral(line, branch, case_insensitive)) |index| {
                const col = index + 1;
                if (best == null or col < best.?) best = col;
            }
        }
        if (end == pattern.len) break;
        start = end + 1;
    }
    return best;
}

pub inline fn count(line: []const u8, pattern: []const u8, case_insensitive: bool) usize {
    if (counterCacheEnabled()) {
        if (counter_cache.ensureCompiled(pattern, case_insensitive)) |counter| {
            return counter.countMatches(line, case_insensitive);
        }
    }

    var total: usize = 0;
    var cursor: usize = 0;
    while (cursor < line.len) {
        var best_index: ?usize = null;
        var best_len: usize = 0;
        var start: usize = 0;
        while (start <= pattern.len) {
            const end = std.mem.indexOfScalarPos(u8, pattern, start, '|') orelse pattern.len;
            const branch = pattern[start..end];
            if (branch.len > 0) {
                if (indexOfLiteral(line[cursor..], branch, case_insensitive)) |index| {
                    if (best_index == null or index < best_index.?) {
                        best_index = index;
                        best_len = branch.len;
                    }
                }
            }
            if (end == pattern.len) break;
            start = end + 1;
        }
        const index = best_index orelse break;
        total += 1;
        cursor += index + best_len;
    }
    return total;
}

pub inline fn parse(pattern: []const u8) ?LiteralAlternates {
    var alternates: LiteralAlternates = .{};
    var start: usize = 0;
    while (start <= pattern.len) {
        const end = std.mem.indexOfScalarPos(u8, pattern, start, '|') orelse pattern.len;
        const branch = pattern[start..end];
        if (branch.len == 0) return null;
        if (alternates.count == MAX_BRANCHES) return null;
        alternates.addBranch(branch);
        if (end == pattern.len) break;
        start = end + 1;
    }
    return if (alternates.count > 1) alternates else null;
}

pub inline fn firstBranchAtLeast(pattern: []const u8, min_len: usize) ?[]const u8 {
    var start: usize = 0;
    while (start <= pattern.len) {
        const end = std.mem.indexOfScalarPos(u8, pattern, start, '|') orelse pattern.len;
        const branch = pattern[start..end];
        if (branch.len >= min_len) return branch;
        if (end == pattern.len) break;
        start = end + 1;
    }
    return null;
}

pub fn countLogicalLinesRange(buffer: []const u8, pattern: []const u8, case_insensitive: bool, logical_start: usize, logical_end: usize) RangeCount {
    if (pattern.len == 0 or logical_start >= logical_end) return .{};
    const counter = Counter.initForLogicalLineRange(pattern, case_insensitive) orelse return .{ .bailed_out = true };
    const end = @min(logical_end, buffer.len);
    var counted = RangeCount{};
    const start = @min(logical_start, end);

    if (counter.usesTeddy()) {
        counted.used_teddy = true;
    } else if (pcreRangeEligible(pattern, counter.alternates.count)) {
        if (pcre_regex.count(buffer[start..end], pattern, case_insensitive)) |matches| {
            counted.matches = matches;
            counted.used_pcre = true;
            return counted;
        } else |_| {}
    }

    var cursor = start;
    while (cursor < end) {
        const newline = simd.indexOfByte(buffer[cursor..end], '\n');
        const line_end = if (newline) |offset| cursor + offset else end;
        const raw_line = buffer[cursor..line_end];
        const line = if (raw_line.len != 0 and raw_line[raw_line.len - 1] == '\r')
            raw_line[0 .. raw_line.len - 1]
        else
            raw_line;
        counted.matches += counter.countMatches(line, case_insensitive);
        if (newline) |offset| {
            cursor += offset + 1;
        } else {
            break;
        }
    }
    return counted;
}

fn pcreRangeEligible(pattern: []const u8, branch_count: usize) bool {
    if (pattern.len == 0) return false;
    if (branch_count < 5) return false;
    return std.mem.indexOfScalar(u8, pattern, '\\') == null;
}

fn teddyFingerprintOffsetOverride(max_offset: usize) usize {
    const value_ptr = std.c.getenv("IX_TEDDY_FINGERPRINT_OFFSET") orelse return 0;
    const value = std.mem.span(value_ptr);
    if (value.len == 0) return 0;
    const parsed = std.fmt.parseUnsigned(usize, value, 10) catch return 0;
    return @min(parsed, max_offset);
}

fn teddyRangeFingerprintOffset(alternates: LiteralAlternates) ?usize {
    if (alternates.count != 4) return null;
    var min_branch_len: usize = std.math.maxInt(usize);
    for (alternates.slice()) |branch| min_branch_len = @min(min_branch_len, branch.len);
    if (min_branch_len < TEDDY_FINGERPRINT_BYTES) return null;
    const max_offset = min_branch_len - TEDDY_FINGERPRINT_BYTES;
    return teddyRangeFingerprintOffsetOverride(max_offset);
}

fn teddyRangeFingerprintOffsetOverride(max_offset: usize) ?usize {
    const value_ptr = std.c.getenv("IX_TEDDY_RANGE_FINGERPRINT_OFFSET") orelse return null;
    const value = std.mem.span(value_ptr);
    if (value.len == 0) return null;
    const parsed = std.fmt.parseUnsigned(usize, value, 10) catch return null;
    return @min(parsed, max_offset);
}

fn literalPrefixCollision(left: []const u8, right: []const u8, case_insensitive: bool) bool {
    if (left.len == 0 or right.len == 0) return false;
    const min_len = @min(left.len, right.len);
    var index: usize = 0;
    while (index < min_len) : (index += 1) {
        const left_byte = if (case_insensitive) std.ascii.toLower(left[index]) else left[index];
        const right_byte = if (case_insensitive) std.ascii.toLower(right[index]) else right[index];
        if (left_byte != right_byte) return false;
    }
    return true;
}

inline fn countTeddyPrefix3(line: []const u8, alternates: *const LiteralAlternates, plan: *const TeddyPlan, case_insensitive: bool) usize {
    if (line.len < TEDDY_FINGERPRINT_BYTES) return 0;
    if (plan.fingerprint_offset > 0) {
        if (plan.fingerprint_offset >= line.len) return 0;
        const fingerprint_lane = line[plan.fingerprint_offset..];
        const first_byte_set = if (case_insensitive) &plan.fingerprint_first_case_set else &plan.fingerprint_first_set;
        if (sz.indexOfByteSet(fingerprint_lane, first_byte_set) == null) return 0;
    }

    var total: usize = 0;
    var cursor: usize = 0;
    const scan_limit = line.len - TEDDY_FINGERPRINT_BYTES + 1;

    while (cursor < scan_limit) {
        if (nextTeddyCandidate(line, cursor, plan, case_insensitive)) |candidate| {
            const branch_len = alternates.firstMatchingBranchLen(line[candidate..], case_insensitive) orelse {
                cursor = candidate + 1;
                continue;
            };
            total += 1;
            cursor = candidate + branch_len;
        } else {
            break;
        }
    }

    return total;
}

inline fn nextTeddyCandidate(line: []const u8, start: usize, plan: *const TeddyPlan, case_insensitive: bool) ?usize {
    const Vec = @Vector(32, u8);
    const VEC_SIZE = 32;
    if (line.len < TEDDY_FINGERPRINT_BYTES) return null;
    if (start + plan.fingerprint_offset + TEDDY_FINGERPRINT_BYTES > line.len) return null;
    const scan_limit = line.len - TEDDY_FINGERPRINT_BYTES + 1;
    var offset = start + plan.fingerprint_offset;

    while (offset + VEC_SIZE <= scan_limit) : (offset += VEC_SIZE) {
        var c0: Vec = line[offset..][0..VEC_SIZE].*;
        var c1: Vec = line[offset + 1 ..][0..VEC_SIZE].*;
        var c2: Vec = line[offset + 2 ..][0..VEC_SIZE].*;
        if (case_insensitive) {
            c0 = asciiLowerVec32(c0);
            c1 = asciiLowerVec32(c1);
            c2 = asciiLowerVec32(c2);
        }

        var mask: u32 = 0;
        for (0..plan.branch_count) |branch_index| {
            const f0: Vec = @splat(plan.fingerprints[branch_index][0]);
            const f1: Vec = @splat(plan.fingerprints[branch_index][1]);
            const f2: Vec = @splat(plan.fingerprints[branch_index][2]);
            mask |= @bitCast((c0 == f0) & (c1 == f1) & (c2 == f2));
        }
        if (mask != 0) return offset + @ctz(mask) - plan.fingerprint_offset;
    }

    while (offset < scan_limit) : (offset += 1) {
        const b0 = if (case_insensitive) std.ascii.toLower(line[offset]) else line[offset];
        const b1 = if (case_insensitive) std.ascii.toLower(line[offset + 1]) else line[offset + 1];
        const b2 = if (case_insensitive) std.ascii.toLower(line[offset + 2]) else line[offset + 2];
        for (0..plan.branch_count) |branch_index| {
            if (b0 == plan.fingerprints[branch_index][0] and
                b1 == plan.fingerprints[branch_index][1] and
                b2 == plan.fingerprints[branch_index][2])
            {
                return offset - plan.fingerprint_offset;
            }
        }
    }

    return null;
}

inline fn asciiLowerVec32(chunk: @Vector(32, u8)) @Vector(32, u8) {
    const A: @Vector(32, u8) = @splat('A');
    const Z: @Vector(32, u8) = @splat('Z');
    const lower_bit: @Vector(32, u8) = @splat(0x20);
    const is_upper = (chunk >= A) & (chunk <= Z);
    return @select(u8, is_upper, chunk | lower_bit, chunk);
}

fn setByteMask(mask: *[4]u64, byte: u8) void {
    const word: usize = @as(usize, byte) >> 6;
    const bit: u6 = @intCast(byte & 63);
    mask[word] |= @as(u64, 1) << bit;
}

inline fn indexOfLiteral(line: []const u8, needle: []const u8, case_insensitive: bool) ?usize {
    if (!case_insensitive) return sz.indexOf(line, needle);
    if (needle.len == 0) return 0;
    if (needle.len > line.len) return null;
    var index: usize = 0;
    while (index + needle.len <= line.len) : (index += 1) {
        if (literalEquals(line[index .. index + needle.len], needle, true)) return index;
    }
    return null;
}

inline fn startsWithLiteral(line: []const u8, needle: []const u8, case_insensitive: bool) bool {
    return line.len >= needle.len and literalEquals(line[0..needle.len], needle, case_insensitive);
}

inline fn literalEquals(left: []const u8, right: []const u8, case_insensitive: bool) bool {
    if (left.len != right.len) return false;
    for (left, right) |a, b| {
        if (!byteEquals(a, b, case_insensitive)) return false;
    }
    return true;
}

inline fn byteEquals(left: u8, right: u8, case_insensitive: bool) bool {
    if (!case_insensitive) return left == right;
    return std.ascii.toLower(left) == std.ascii.toLower(right);
}

test "literal alternates line range counts regex occurrences" {
    const buffer =
        "Sherlock Holmes and John Watson\n" ++
        "Irene Adler\n" ++
        "Professor Moriarty\n" ++
        "plain line\n";
    const range_count = countLogicalLinesRange(buffer, "Sherlock Holmes|John Watson|Irene Adler", false, 0, buffer.len);
    try std.testing.expect(!range_count.bailed_out);
    try std.testing.expectEqual(@as(usize, 3), range_count.matches);

    try std.testing.expectEqual(@as(?usize, 1), column(buffer, "Sherlock Holmes|John Watson|Irene Adler", false));
    try std.testing.expectEqual(@as(usize, 3), count(buffer, "Sherlock Holmes|John Watson|Irene Adler", false));

    const folded = countLogicalLinesRange("sherlock holmes and irene adler\n", "Sherlock Holmes|Irene Adler", true, 0, "sherlock holmes and irene adler\n".len);
    try std.testing.expect(!folded.bailed_out);
    try std.testing.expectEqual(@as(usize, 2), folded.matches);
}

test "literal alternates compiled start mask rejects impossible lines" {
    const alternates = parse("Sherlock Holmes|John Watson|Irene Adler").?;

    try std.testing.expect(!alternates.mayContainStartByte("plain line", false));
    try std.testing.expectEqual(@as(?usize, null), alternates.column("plain line", false));
    try std.testing.expectEqual(@as(usize, 0), alternates.countMatches("plain line", false));

    try std.testing.expect(alternates.mayContainStartByte("John Watson", false));
    try std.testing.expectEqual(@as(?usize, 1), alternates.column("John Watson", false));
    try std.testing.expectEqual(@as(usize, 1), alternates.countMatches("John Watson", false));
}

test "literal alternates compiled folded start mask admits case insensitive lines" {
    const alternates = parse("Sherlock Holmes|John Watson|Irene Adler").?;

    try std.testing.expect(!alternates.mayContainStartByte("sherlock holmes", false));
    try std.testing.expect(alternates.mayContainStartByte("sherlock holmes", true));
    try std.testing.expect(alternates.mayContainStartByte("SHERLOCK HOLMES", true));
    try std.testing.expectEqual(@as(?usize, 4), alternates.nextStartByteOffset("zzz SHERLOCK HOLMES", true));
    try std.testing.expectEqual(@as(?usize, 0), alternates.nextStartByteOffset("SHERLOCK HOLMES", true));
    try std.testing.expectEqual(@as(?usize, 1), alternates.column("sherlock holmes", true));
    try std.testing.expectEqual(@as(usize, 2), alternates.countMatches("sherlock holmes and irene adler", true));
}

test "literal alternates skip false start bytes and continue to later full match" {
    const alternates = parse("aba|abc").?;
    try std.testing.expectEqual(@as(?usize, 5), alternates.column("abx abc", false));
    try std.testing.expectEqual(@as(usize, 1), alternates.countMatches("abx abc", false));
    try std.testing.expectEqual(@as(?usize, 5), alternates.column("ABX abc", true));
    try std.testing.expectEqual(@as(usize, 1), alternates.countMatches("ABX abc", true));
}

test "large literal alternates range prefers teddy before pcre when eligible" {
    const pattern = "Sherlock Holmes|John Watson|Irene Adler|Inspector Lestrade|Professor Moriarty";
    const buffer =
        "Sherlock Holmes and John Watson\n" ++
        "Irene Adler\n" ++
        "Inspector Lestrade\n" ++
        "Professor Moriarty Sherlock Holmes\n";

    const alternates = parse(pattern).?;
    try std.testing.expect(pcreRangeEligible(pattern, alternates.count));

    const range_count = countLogicalLinesRange(buffer, pattern, false, 0, buffer.len);
    try std.testing.expect(!range_count.bailed_out);
    try std.testing.expect(!range_count.used_pcre);
    try std.testing.expect(range_count.used_teddy);
    try std.testing.expectEqual(@as(usize, 6), range_count.matches);

    const four_branch = parse("Sherlock Holmes|John Watson|Irene Adler|Inspector Lestrade").?;
    try std.testing.expect(!pcreRangeEligible("Sherlock Holmes|John Watson|Irene Adler|Inspector Lestrade", four_branch.count));
    const four_branch_count = countLogicalLinesRange(buffer, "Sherlock Holmes|John Watson|Irene Adler|Inspector Lestrade", false, 0, buffer.len);
    try std.testing.expect(!four_branch_count.bailed_out);
    try std.testing.expect(!four_branch_count.used_pcre);
    try std.testing.expect(four_branch_count.used_teddy);
    try std.testing.expectEqual(@as(usize, 5), four_branch_count.matches);

    const small = parse("Sherlock Holmes|John Watson|Irene Adler").?;
    try std.testing.expect(!pcreRangeEligible("Sherlock Holmes|John Watson|Irene Adler", small.count));
    const small_count = countLogicalLinesRange(buffer, "Sherlock Holmes|John Watson|Irene Adler", false, 0, buffer.len);
    try std.testing.expect(!small_count.bailed_out);
    try std.testing.expect(!small_count.used_pcre);
    try std.testing.expect(small_count.used_teddy);
    const escaped = parse("Sherlock\\.Holmes|John Watson|Irene Adler|Inspector Lestrade|Professor Moriarty").?;
    try std.testing.expect(!pcreRangeEligible("Sherlock\\.Holmes|John Watson|Irene Adler|Inspector Lestrade|Professor Moriarty", escaped.count));
}

test "teddy literal alternates planner admits branch four ripgrep shape" {
    const alternates = parse("ERR_SYS|PME_TURN_OFF|LINK_REQ_RST|CFG_BME_EVT").?;
    const plan = teddyPlan(alternates, true) orelse return error.TestExpectedEqual;

    try std.testing.expectEqual(@as(usize, 4), plan.branch_count);
    try std.testing.expectEqual(@as(usize, 3), plan.fingerprint_bytes);
    try std.testing.expectEqual(@as(usize, 8), plan.bucket_count);
    try std.testing.expectEqual(@as(u32, 1), plan.bucket_masks[0]);
    try std.testing.expectEqual(@as(u32, 2), plan.bucket_masks[1]);
    try std.testing.expectEqual(@as(u32, 4), plan.bucket_masks[2]);
    try std.testing.expectEqual(@as(u32, 8), plan.bucket_masks[3]);
    try std.testing.expectEqual(@as(usize, 0), plan.fingerprint_offset);
    try std.testing.expectEqualSlices(u8, "err", plan.fingerprints[0][0..3]);
    try std.testing.expectEqualSlices(u8, "pme", plan.fingerprints[1][0..3]);
    try std.testing.expectEqualSlices(u8, "lin", plan.fingerprints[2][0..3]);
    try std.testing.expectEqualSlices(u8, "cfg", plan.fingerprints[3][0..3]);
}

test "literal alternates counter hoists teddy plan for repeated line counts" {
    const counter = Counter.init("ERR_SYS|PME_TURN_OFF|LINK_REQ_RST|CFG_BME_EVT", true) orelse return error.TestExpectedEqual;
    try std.testing.expect(counter.usesTeddy());
    try std.testing.expectEqual(@as(usize, 4), counter.teddy_plan.?.branch_count);
    try std.testing.expectEqual(@as(usize, 0), counter.teddy_plan.?.fingerprint_offset);

    const range_counter = Counter.initForLogicalLineRange("ERR_SYS|PME_TURN_OFF|LINK_REQ_RST|CFG_BME_EVT", true) orelse return error.TestExpectedEqual;
    try std.testing.expect(range_counter.usesTeddy());
    try std.testing.expectEqual(@as(usize, 0), range_counter.teddy_plan.?.fingerprint_offset);

    const line =
        "err_sys pme_turn_off link_req_rst cfg_bme_evt " ++
        "unrelated payload " ++
        "ERR_SYS";
    try std.testing.expectEqual(@as(usize, 5), counter.countMatches(line, true));
    try std.testing.expectEqual(@as(usize, 0), counter.countMatches("unrelated payload only", true));

    const range =
        line ++ "\n" ++
        "unrelated payload only\n" ++
        "cfg_bme_evt\n";
    const counted = countLogicalLinesRange(range, "ERR_SYS|PME_TURN_OFF|LINK_REQ_RST|CFG_BME_EVT", true, 0, range.len);
    try std.testing.expect(!counted.bailed_out);
    try std.testing.expect(counted.used_teddy);
    try std.testing.expect(!counted.used_pcre);
    try std.testing.expectEqual(@as(usize, 6), counted.matches);
}

test "teddy literal alternates planner rejects unsupported shapes" {
    const prefix_collision = parse("Sherlock|Sherlock Holmes|Irene Adler|Inspector Lestrade").?;
    try std.testing.expect(teddyPlan(prefix_collision, false) == null);

    const folded_prefix_collision = parse("ERR|err_sys|PME_TURN_OFF|LINK_REQ_RST").?;
    try std.testing.expect(teddyPlan(folded_prefix_collision, true) == null);

    const shared_prefix_non_collision = parse("PME_TURN_OFF|PM_RESUME|PCI_WAKE|DPM_FLAG").?;
    try std.testing.expect(teddyPlan(shared_prefix_non_collision, true) != null);

    const short_branch = parse("ab|cde|fgh|ijk").?;
    try std.testing.expect(teddyPlan(short_branch, false) == null);

    const escaped = parse("ERR\\.SYS|PME_TURN_OFF|LINK_REQ_RST|CFG_BME_EVT").?;
    try std.testing.expect(teddyPlan(escaped, false) == null);

    const too_many = parse("aa0|bb1|cc2|dd3|ee4|ff5|gg6|hh7|ii8").?;
    try std.testing.expect(teddyPlan(too_many, false) == null);
}
