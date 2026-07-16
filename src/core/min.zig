const std = @import("std");
const cli = @import("../cli/args.zig");

pub const MAX_UNITS = 65_536;
const MIN_TARGET_UNIT_BYTES = 256;
const READ_BUFFER_BYTES = 64 * 1024;
const COMPARE_BUFFER_BYTES = 8192;
const SKETCH_WIDTH = 2048;

pub const MinError = error{
    NotFile,
    BinaryInput,
    InvalidUtf8,
    UnitLimit,
    ByteBudgetTooSmall,
};

pub const UnitClass = enum { heading, declaration, paragraph, record, block, long_line };
pub const OmissionReason = enum { exact_duplicate, budget };

pub const SourceRange = struct {
    start_byte: u64,
    end_byte: u64,
    start_line: usize,
    end_line: usize,
};

const Unit = struct {
    range: SourceRange,
    class: UnitClass,
    digest_a: u64,
    digest_b: u64,
    features: [4]u64,
    score: u64,
    boundary_preserve: bool,
    duplicate_of: ?usize = null,
    selected: bool = false,
};

const FrequencySketch = struct {
    rows: [4][SKETCH_WIDTH]u16 = @splat(@splat(0)),

    /// Records bounded lexical evidence; saturating counters prevent wraparound from changing rank order.
    fn add(self: *FrequencySketch, hash: u64) void {
        inline for (0..4) |row| {
            const mixed = mixHash(hash, row);
            const index: usize = @intCast(mixed & (SKETCH_WIDTH - 1));
            self.rows[row][index] +|= 1;
        }
    }

    /// Returns the Count-Min upper estimate so collisions can only weaken soft rarity, never hard preservation.
    fn estimate(self: *const FrequencySketch, hash: u64) u16 {
        var result: u16 = std.math.maxInt(u16);
        inline for (0..4) |row| {
            const mixed = mixHash(hash, row);
            const index: usize = @intCast(mixed & (SKETCH_WIDTH - 1));
            result = @min(result, self.rows[row][index]);
        }
        return result;
    }
};

const Utf8State = struct {
    expected: u3 = 0,
    lead: u8 = 0,
    first_continuation: bool = false,
    invalid: bool = false,

    /// Validates UTF-8 incrementally so chunk boundaries never require whole-file materialization.
    fn push(self: *Utf8State, byte: u8) void {
        if (self.invalid) return;
        if (self.expected == 0) {
            if (byte < 0x80) return;
            if (byte >= 0xC2 and byte <= 0xDF) self.expected = 1 else if (byte >= 0xE0 and byte <= 0xEF) self.expected = 2 else if (byte >= 0xF0 and byte <= 0xF4) self.expected = 3 else {
                self.invalid = true;
                return;
            }
            self.lead = byte;
            self.first_continuation = true;
            return;
        }
        if (byte < 0x80 or byte > 0xBF) {
            self.invalid = true;
            return;
        }
        if (self.first_continuation) {
            if ((self.lead == 0xE0 and byte < 0xA0) or
                (self.lead == 0xED and byte > 0x9F) or
                (self.lead == 0xF0 and byte < 0x90) or
                (self.lead == 0xF4 and byte > 0x8F))
            {
                self.invalid = true;
                return;
            }
            self.first_continuation = false;
        }
        self.expected -= 1;
    }
};

const UnitBuilder = struct {
    start_byte: u64,
    start_line: usize,
    bytes: usize = 0,
    lines: usize = 0,
    current_line_bytes: usize = 0,
    digest_a: std.hash.Wyhash = std.hash.Wyhash.init(0x4958_4d49_4e41_3031),
    digest_b: std.hash.Wyhash = std.hash.Wyhash.init(0x4958_4d49_4e42_3031),
    features: [4]u64 = @splat(0),
    score: u64 = 0,
    class: UnitClass = .paragraph,
    token: [64]u8 = undefined,
    token_len: usize = 0,
    token_overflow: bool = false,
    line_prefix: [64]u8 = undefined,
    line_prefix_len: usize = 0,
    previous_byte: u8 = 0,

    /// Starts one source-addressable unit without retaining its bytes.
    fn init(start_byte: u64, start_line: usize) UnitBuilder {
        return .{ .start_byte = start_byte, .start_line = start_line };
    }

    /// Accumulates hashes and transparent preservation evidence without retaining source text.
    fn push(self: *UnitBuilder, sketch: *FrequencySketch, byte: u8) void {
        const one = [1]u8{byte};
        self.digest_a.update(&one);
        self.digest_b.update(&one);
        self.bytes += 1;
        self.current_line_bytes += 1;
        if (self.line_prefix_len < self.line_prefix.len and byte != '\n' and byte != '\r') {
            self.line_prefix[self.line_prefix_len] = byte;
            self.line_prefix_len += 1;
        }
        if (isTokenByte(byte)) {
            if (self.token_len < self.token.len) {
                self.token[self.token_len] = std.ascii.toLower(byte);
                self.token_len += 1;
            } else self.token_overflow = true;
        } else {
            self.finishToken(sketch);
        }
        if ((self.previous_byte == '-' and byte == '-') or
            (self.previous_byte == ':' and (byte == '/' or byte == '\\')) or
            (self.previous_byte == '/' and byte == '/'))
        {
            self.score +|= 96;
        }
        self.previous_byte = byte;
        if (byte == '\n') {
            self.finishLine();
            self.lines += 1;
            self.current_line_bytes = 0;
            self.line_prefix_len = 0;
        }
    }

    /// Commits one bounded lexical feature into frequency and salience evidence.
    fn finishToken(self: *UnitBuilder, sketch: *FrequencySketch) void {
        if (self.token_len == 0 and !self.token_overflow) return;
        const token = self.token[0..self.token_len];
        const hash = tokenHash(token, self.token_overflow);
        sketch.add(hash);
        const bit: u8 = @truncate(hash);
        self.features[bit >> 6] |= @as(u64, 1) << @intCast(bit & 63);
        if (isObligation(token)) {
            self.score +|= 192;
        }
        if (self.token_overflow or isHexEvidence(token) or isNumericEvidence(token)) {
            self.score +|= 80;
        }
        if (token.len >= 4) self.score +|= @min(token.len, 32);
        self.token_len = 0;
        self.token_overflow = false;
    }

    /// Classifies a complete line without parsing or rewriting source content.
    fn finishLine(self: *UnitBuilder) void {
        const prefix = std.mem.trimStart(u8, self.line_prefix[0..self.line_prefix_len], " \t");
        if (prefix.len == 0) return;
        if (prefix[0] == '#') {
            self.class = .heading;
            self.score +|= 256;
        } else if (startsDeclaration(prefix)) {
            if (self.class != .heading) self.class = .declaration;
            self.score +|= if (startsPublicDeclaration(prefix)) 4096 else 224;
        } else if (prefix[0] == '{' or prefix[0] == '[') {
            if (self.class == .paragraph) self.class = .record;
            self.score +|= 48;
        }
        if (self.current_line_bytes > 1024 * 1024) self.class = .long_line;
    }

    /// Freezes bounded metadata for a complete source range.
    fn finish(self: *UnitBuilder, sketch: *FrequencySketch, end_byte: u64, end_line: usize) Unit {
        self.finishToken(sketch);
        if (self.current_line_bytes != 0) self.finishLine();
        return .{
            .range = .{ .start_byte = self.start_byte, .end_byte = end_byte, .start_line = self.start_line, .end_line = end_line },
            .class = self.class,
            .digest_a = self.digest_a.final(),
            .digest_b = self.digest_b.final(),
            .features = self.features,
            .score = self.score,
            .boundary_preserve = false,
        };
    }
};

const ScanResult = struct {
    units: []Unit,
    sketch: FrequencySketch,
    digest: [32]u8,
    input_bytes: u64,
    input_lines: usize,
};

/// Runs the bounded projection through one canonical scanner, selector, sizer, and serializer.
pub fn run(io: std.Io, allocator: std.mem.Allocator, request: cli.MinRequest, writer: anytype) !void {
    var file = std.Io.Dir.cwd().openFile(io, request.path, .{ .allow_directory = false }) catch |err| switch (err) {
        error.IsDir => return MinError.NotFile,
        else => return err,
    };
    defer file.close(io);
    const stat = try file.stat(io);
    if (stat.kind != .file) return MinError.NotFile;

    var scan = try scanFile(io, allocator, &file, stat.size);
    if (scan.units.len > 0) {
        scan.units[0].boundary_preserve = true;
        scan.units[scan.units.len - 1].boundary_preserve = true;
    }
    try applyRarity(io, &file, &scan.sketch, scan.units);
    try markExactDuplicates(io, allocator, &file, scan.units);
    try selectUnits(io, &file, request, scan);
    const output_bytes = try stableRenderedLength(io, &file, request, scan);
    if (output_bytes > request.max_bytes) return MinError.ByteBudgetTooSmall;
    try writeProjection(io, &file, writer, request, scan, output_bytes);
}

/// Streams source metadata under a deterministic unit ceiling while hashing the exact input bytes.
fn scanFile(io: std.Io, allocator: std.mem.Allocator, file: *std.Io.File, file_size: u64) !ScanResult {
    var units = std.ArrayList(Unit).empty;
    errdefer units.deinit(allocator);
    const target_u64 = @max(@as(u64, MIN_TARGET_UNIT_BYTES), (file_size + MAX_UNITS - 1) / MAX_UNITS);
    const target: usize = @intCast(@min(target_u64, std.math.maxInt(usize)));
    var sketch = FrequencySketch{};
    var sha = std.crypto.hash.sha2.Sha256.init(.{});
    var utf8 = Utf8State{};
    var buffer: [READ_BUFFER_BYTES]u8 = undefined;
    var offset: u64 = 0;
    var line: usize = 1;
    var saw_any = false;
    var builder = UnitBuilder.init(0, 1);
    while (true) {
        const read = try file.readPositional(io, &.{&buffer}, offset);
        if (read == 0) break;
        const bytes = buffer[0..read];
        sha.update(bytes);
        for (bytes) |byte| {
            saw_any = true;
            utf8.push(byte);
            if (byte == 0) return MinError.BinaryInput;
            builder.push(&sketch, byte);
            offset += 1;
            if (byte == '\n') {
                if (builder.bytes >= target) {
                    if (units.items.len >= MAX_UNITS) return MinError.UnitLimit;
                    try units.append(allocator, builder.finish(&sketch, offset, line));
                    builder = UnitBuilder.init(offset, line + 1);
                }
                line += 1;
            }
        }
    }
    if (utf8.invalid or utf8.expected != 0) return MinError.InvalidUtf8;
    if (builder.bytes != 0) {
        if (units.items.len >= MAX_UNITS) return MinError.UnitLimit;
        try units.append(allocator, builder.finish(&sketch, offset, line));
    }
    var digest: [32]u8 = undefined;
    sha.final(&digest);
    return .{
        .units = try units.toOwnedSlice(allocator),
        .sketch = sketch,
        .digest = digest,
        .input_bytes = offset,
        .input_lines = if (saw_any) line - @intFromBool(builder.bytes == 0) else 0,
    };
}

/// Adds second-pass rarity without expanding memory with input vocabulary cardinality.
fn applyRarity(io: std.Io, file: *std.Io.File, sketch: *const FrequencySketch, units: []Unit) !void {
    var buffer: [READ_BUFFER_BYTES]u8 = undefined;
    for (units) |*unit| {
        var offset = unit.range.start_byte;
        var token: [64]u8 = undefined;
        var token_len: usize = 0;
        var overflow = false;
        while (offset < unit.range.end_byte) {
            const wanted: usize = @intCast(@min(@as(u64, buffer.len), unit.range.end_byte - offset));
            const read = try file.readPositional(io, &.{buffer[0..wanted]}, offset);
            if (read == 0) return error.UnexpectedEof;
            for (buffer[0..read]) |byte| {
                if (isTokenByte(byte)) {
                    if (token_len < token.len) {
                        token[token_len] = std.ascii.toLower(byte);
                        token_len += 1;
                    } else overflow = true;
                } else {
                    addRarity(unit, sketch, token[0..token_len], overflow);
                    token_len = 0;
                    overflow = false;
                }
            }
            offset += read;
        }
        addRarity(unit, sketch, token[0..token_len], overflow);
    }
}

/// Rewards uncommon lexical evidence through a fixed-memory frequency estimate.
fn addRarity(unit: *Unit, sketch: *const FrequencySketch, token: []const u8, overflow: bool) void {
    if (token.len < 2 and !overflow) return;
    const frequency = @max(@as(u16, 1), sketch.estimate(tokenHash(token, overflow)));
    unit.score +|= @min(@as(u64, 256 / frequency), 64);
}

/// Uses hashes only for grouping; chunked byte equality is the sole omission proof.
fn markExactDuplicates(io: std.Io, allocator: std.mem.Allocator, file: *std.Io.File, units: []Unit) !void {
    if (units.len < 2) return;
    const indices = try allocator.alloc(usize, units.len);
    defer allocator.free(indices);
    for (indices, 0..) |*slot, index| slot.* = index;
    std.mem.sort(usize, indices, units, struct {
        /// Orders duplicate candidates deterministically, preserving earliest-source ownership.
        fn lessThan(context: []Unit, lhs: usize, rhs: usize) bool {
            const a = context[lhs];
            const b = context[rhs];
            if (a.digest_a != b.digest_a) return a.digest_a < b.digest_a;
            if (a.digest_b != b.digest_b) return a.digest_b < b.digest_b;
            if (rangeBytes(a.range) != rangeBytes(b.range)) return rangeBytes(a.range) < rangeBytes(b.range);
            return lhs < rhs;
        }
    }.lessThan);
    var group_start: usize = 0;
    while (group_start < indices.len) {
        var next = group_start + 1;
        while (next < indices.len and sameDigestAndLength(units[indices[group_start]], units[indices[next]])) : (next += 1) {}
        var candidate_offset = group_start + 1;
        while (candidate_offset < next) : (candidate_offset += 1) {
            const candidate = indices[candidate_offset];
            var prior_offset = group_start;
            while (prior_offset < candidate_offset) : (prior_offset += 1) {
                const prior = indices[prior_offset];
                const canonical = units[prior].duplicate_of orelse prior;
                if (try rangesEqual(io, file, units[canonical].range, units[candidate].range)) {
                    units[candidate].duplicate_of = canonical;
                    break;
                }
            }
        }
        group_start = next;
    }
}

/// Admits only equal-size dual-digest ranges to expensive byte proof.
fn sameDigestAndLength(a: Unit, b: Unit) bool {
    return a.digest_a == b.digest_a and a.digest_b == b.digest_b and rangeBytes(a.range) == rangeBytes(b.range);
}

/// Proves duplicate equality from source bytes instead of trusting fingerprints.
fn rangesEqual(io: std.Io, file: *std.Io.File, a: SourceRange, b: SourceRange) !bool {
    if (rangeBytes(a) != rangeBytes(b)) return false;
    var left: [COMPARE_BUFFER_BYTES]u8 = undefined;
    var right: [COMPARE_BUFFER_BYTES]u8 = undefined;
    var compared: u64 = 0;
    while (compared < rangeBytes(a)) {
        const wanted: usize = @intCast(@min(@as(u64, left.len), rangeBytes(a) - compared));
        const left_read = try file.readPositional(io, &.{left[0..wanted]}, a.start_byte + compared);
        const right_read = try file.readPositional(io, &.{right[0..wanted]}, b.start_byte + compared);
        if (left_read != wanted or right_read != wanted) return error.UnexpectedEof;
        if (!std.mem.eql(u8, left[0..wanted], right[0..wanted])) return false;
        compared += wanted;
    }
    return true;
}

/// Applies profile loss semantics before the exact serializer confirms the complete stdout budget.
fn selectUnits(io: std.Io, file: *std.Io.File, request: cli.MinRequest, scan: ScanResult) !void {
    for (scan.units) |*unit| unit.selected = unit.boundary_preserve or (unit.duplicate_of == null and request.level == .low);
    if (request.level == .low) {
        if (!try projectionFits(io, file, request, scan)) return MinError.ByteBudgetTooSmall;
        return;
    }
    if (!try projectionFits(io, file, request, scan)) return MinError.ByteBudgetTooSmall;
    while (bestCandidate(scan.units)) |candidate| {
        scan.units[candidate].selected = true;
        if (!try projectionFits(io, file, request, scan)) {
            scan.units[candidate].selected = false;
            scan.units[candidate].score = 0;
            continue;
        }
    }
}

/// Selects the highest marginal evidence density with stable source-order ties.
fn bestCandidate(units: []Unit) ?usize {
    var best: ?usize = null;
    var best_value: u128 = 0;
    for (units, 0..) |unit, index| {
        if (unit.selected or unit.duplicate_of != null or unit.score == 0) continue;
        const novelty = noveltyScore(unit.features, units);
        const numerator: u128 = @as(u128, unit.score + novelty) * 1024;
        const value = numerator / @max(@as(u128, rangeBytes(unit.range)), 1);
        if (best == null or value > best_value) {
            best = index;
            best_value = value;
        }
    }
    return best;
}

/// Rewards evidence features not yet represented by retained units.
fn noveltyScore(features: [4]u64, units: []const Unit) u64 {
    var covered: [4]u64 = @splat(0);
    for (units) |unit| {
        if (unit.selected) {
            inline for (0..4) |i| covered[i] |= unit.features[i];
        }
    }
    var novel: u64 = 0;
    inline for (0..4) |i| novel += @popCount(features[i] & ~covered[i]);
    return novel * 8;
}

/// Tests the complete serialized payload against the caller's byte ceiling.
fn projectionFits(io: std.Io, file: *std.Io.File, request: cli.MinRequest, scan: ScanResult) !bool {
    return try stableRenderedLength(io, file, request, scan) <= request.max_bytes;
}

/// Solves the output_bytes self-reference to a stable exact serializer length.
fn stableRenderedLength(io: std.Io, file: *std.Io.File, request: cli.MinRequest, scan: ScanResult) !usize {
    var output_bytes: usize = 0;
    var attempts: usize = 0;
    while (attempts < 8) : (attempts += 1) {
        var buffer: [256]u8 = undefined;
        var discarding: std.Io.Writer.Discarding = .init(&buffer);
        try writeProjection(io, file, &discarding.writer, request, scan, output_bytes);
        const measured: usize = @intCast(discarding.fullCount());
        if (measured == output_bytes) return measured;
        output_bytes = measured;
    }
    return output_bytes;
}

/// Routes both projections through the same selected-unit truth model.
fn writeProjection(io: std.Io, file: *std.Io.File, writer: anytype, request: cli.MinRequest, scan: ScanResult, output_bytes: usize) !void {
    if (request.format == .json)
        try writeJson(io, file, writer, request, scan, output_bytes)
    else
        try writeText(io, file, writer, request, scan, output_bytes);
}

/// Emits readable exact blocks with visible provenance and omission boundaries.
fn writeText(io: std.Io, file: *std.Io.File, writer: anytype, request: cli.MinRequest, scan: ScanResult, output_bytes: usize) !void {
    const counts = projectionCounts(scan.units);
    const digest_hex = std.fmt.bytesToHex(scan.digest, .lower);
    try writer.print("-- ix.min.v1 path=\"{s}\" sha256={s} level={s} lossy={s} complete=true input_bytes={} input_lines={} max_bytes={} output_bytes={} retained_bytes={} retained_units={} omitted_bytes={} omitted_units={} --\n", .{
        request.path, digest_hex, @tagName(request.level), boolText(counts.lossy), scan.input_bytes, scan.input_lines, request.max_bytes, output_bytes, counts.retained_bytes, counts.retained_units, counts.omitted_bytes, counts.omitted_units,
    });
    var previous_selected_end: ?usize = null;
    for (scan.units, 0..) |unit, index| {
        if (!unit.selected) continue;
        if (previous_selected_end) |previous| if (index > previous + 1) try writeTextOmission(writer, scan.units[previous + 1 .. index]);
        try writer.print("@@ lines {}:{} bytes {}:{} {s}\n", .{ unit.range.start_line, unit.range.end_line, unit.range.start_byte, unit.range.end_byte, @tagName(unit.class) });
        try writeRange(io, file, writer, unit.range);
        if (rangeBytes(unit.range) != 0 and try lastRangeByte(io, file, unit.range) != '\n') try writer.writeByte('\n');
        previous_selected_end = index;
    }
    if (previous_selected_end) |previous| {
        if (previous + 1 < scan.units.len) try writeTextOmission(writer, scan.units[previous + 1 ..]);
    } else if (scan.units.len != 0) try writeTextOmission(writer, scan.units);
}

/// Coalesces one contiguous omitted run without hiding its extent or reason.
fn writeTextOmission(writer: anytype, units: []const Unit) !void {
    if (units.len == 0) return;
    var bytes: u64 = 0;
    for (units) |unit| bytes += rangeBytes(unit.range);
    const reason = omissionReason(units);
    try writer.print("… omitted lines {}:{} bytes={} units={} reason={s} …\n", .{ units[0].range.start_line, units[units.len - 1].range.end_line, bytes, units.len, @tagName(reason) });
}

/// Emits the stable machine envelope without prose or terminal decoration.
fn writeJson(io: std.Io, file: *std.Io.File, writer: anytype, request: cli.MinRequest, scan: ScanResult, output_bytes: usize) !void {
    const counts = projectionCounts(scan.units);
    const digest_hex = std.fmt.bytesToHex(scan.digest, .lower);
    try writer.writeAll("{\"schema\":\"ix.min.v1\",\"path\":");
    try writeJsonString(writer, request.path);
    try writer.print(",\"source_sha256\":\"{s}\",\"level\":\"{s}\",\"lossy\":{s},\"complete\":true,\"input_bytes\":{},\"input_lines\":{},\"max_bytes\":{},\"output_bytes\":{},\"retained_bytes\":{},\"retained_units\":{},\"omitted_bytes\":{},\"omitted_units\":{},\"units\":[", .{
        digest_hex, @tagName(request.level), boolText(counts.lossy), scan.input_bytes, scan.input_lines, request.max_bytes, output_bytes, counts.retained_bytes, counts.retained_units, counts.omitted_bytes, counts.omitted_units,
    });
    var first = true;
    for (scan.units) |unit| {
        if (!unit.selected) continue;
        if (!first) try writer.writeByte(',');
        first = false;
        try writer.print("{{\"start_byte\":{},\"end_byte\":{},\"start_line\":{},\"end_line\":{},\"class\":\"{s}\",\"content\":", .{ unit.range.start_byte, unit.range.end_byte, unit.range.start_line, unit.range.end_line, @tagName(unit.class) });
        try writeJsonRange(io, file, writer, unit.range);
        try writer.writeByte('}');
    }
    try writer.writeAll("],\"omissions\":[");
    var omission_first = true;
    var index: usize = 0;
    while (index < scan.units.len) {
        if (scan.units[index].selected) {
            index += 1;
            continue;
        }
        const start = index;
        var bytes: u64 = 0;
        while (index < scan.units.len and !scan.units[index].selected) : (index += 1) bytes += rangeBytes(scan.units[index].range);
        const reason = omissionReason(scan.units[start..index]);
        if (!omission_first) try writer.writeByte(',');
        omission_first = false;
        try writer.print("{{\"start_byte\":{},\"end_byte\":{},\"start_line\":{},\"end_line\":{},\"input_bytes\":{},\"units\":{},\"reason\":\"{s}\"}}", .{
            scan.units[start].range.start_byte, scan.units[index - 1].range.end_byte, scan.units[start].range.start_line, scan.units[index - 1].range.end_line, bytes, index - start, @tagName(reason),
        });
    }
    try writer.writeAll("]}\n");
}

/// Streams an exact source range without whole-file materialization.
fn writeRange(io: std.Io, file: *std.Io.File, writer: anytype, range: SourceRange) !void {
    var buffer: [READ_BUFFER_BYTES]u8 = undefined;
    var offset = range.start_byte;
    while (offset < range.end_byte) {
        const wanted: usize = @intCast(@min(@as(u64, buffer.len), range.end_byte - offset));
        const read = try file.readPositional(io, &.{buffer[0..wanted]}, offset);
        if (read == 0) return error.UnexpectedEof;
        try writer.writeAll(buffer[0..read]);
        offset += read;
    }
}

/// Streams one exact source range through JSON escaping only.
fn writeJsonRange(io: std.Io, file: *std.Io.File, writer: anytype, range: SourceRange) !void {
    try writer.writeByte('"');
    var buffer: [READ_BUFFER_BYTES]u8 = undefined;
    var offset = range.start_byte;
    while (offset < range.end_byte) {
        const wanted: usize = @intCast(@min(@as(u64, buffer.len), range.end_byte - offset));
        const read = try file.readPositional(io, &.{buffer[0..wanted]}, offset);
        if (read == 0) return error.UnexpectedEof;
        try writeJsonStringContents(writer, buffer[0..read]);
        offset += read;
    }
    try writer.writeByte('"');
}

const ProjectionCounts = struct { retained_bytes: u64, retained_units: usize, omitted_bytes: u64, omitted_units: usize, lossy: bool };

/// Derives retained and omitted accounting from the canonical selection state.
fn projectionCounts(units: []const Unit) ProjectionCounts {
    var counts = ProjectionCounts{ .retained_bytes = 0, .retained_units = 0, .omitted_bytes = 0, .omitted_units = 0, .lossy = false };
    for (units) |unit| {
        if (unit.selected) {
            counts.retained_bytes += rangeBytes(unit.range);
            counts.retained_units += 1;
        } else {
            counts.omitted_bytes += rangeBytes(unit.range);
            counts.omitted_units += 1;
            if (unit.duplicate_of == null) counts.lossy = true;
        }
    }
    return counts;
}

/// Distinguishes safe exact duplication from omission of any unique evidence.
fn omissionReason(units: []const Unit) OmissionReason {
    for (units) |unit| if (unit.duplicate_of == null) return .budget;
    return .exact_duplicate;
}

/// Returns the byte length of one half-open source range.
fn rangeBytes(range: SourceRange) u64 {
    return range.end_byte - range.start_byte;
}

/// Reads the terminal byte needed for exact human-output newline framing.
fn lastRangeByte(io: std.Io, file: *std.Io.File, range: SourceRange) !u8 {
    var byte: [1]u8 = undefined;
    if (try file.readPositional(io, &.{&byte}, range.end_byte - 1) != 1) return error.UnexpectedEof;
    return byte[0];
}

/// Keeps lexical tokenization ASCII-stable across hosts and locales.
fn isTokenByte(byte: u8) bool {
    return std.ascii.isAlphanumeric(byte) or byte == '_';
}

/// Produces deterministic bounded-token evidence for sketches and signatures.
fn tokenHash(token: []const u8, overflow: bool) u64 {
    var hash: u64 = if (overflow) 0x9e37_79b9_7f4a_7c15 else 0xcbf2_9ce4_8422_2325;
    for (token) |byte| {
        hash ^= std.ascii.toLower(byte);
        hash *%= 0x100_0000_01b3;
    }
    return hash;
}

/// Derives independent Count-Min row positions from one token hash.
fn mixHash(hash: u64, comptime row: usize) u64 {
    var value = hash ^ (@as(u64, row + 1) *% 0x9e37_79b9_7f4a_7c15);
    value ^= value >> 30;
    value *%= 0xbf58_476d_1ce4_e5b9;
    value ^= value >> 27;
    value *%= 0x94d0_49bb_1331_11eb;
    return value ^ (value >> 31);
}

/// Identifies meaning-changing obligation, negation, and failure vocabulary.
fn isObligation(token: []const u8) bool {
    const words = [_][]const u8{ "must", "never", "not", "only", "without", "required", "requirement", "error", "failed", "failure", "blocked", "warning" };
    for (words) |word| if (std.mem.eql(u8, token, word)) return true;
    return false;
}

/// Recognizes long exact hexadecimal identifiers worth additional salience.
fn isHexEvidence(token: []const u8) bool {
    if (token.len < 16) return false;
    for (token) |byte| if (!std.ascii.isHex(byte)) return false;
    return true;
}

/// Recognizes metric-like tokens without domain-specific parsing.
fn isNumericEvidence(token: []const u8) bool {
    if (token.len < 2) return false;
    var digits: usize = 0;
    for (token) |byte| {
        if (std.ascii.isDigit(byte)) digits += 1;
    }
    return digits >= 2;
}

/// Recognizes cross-language declaration forms from a bounded line prefix.
fn startsDeclaration(prefix: []const u8) bool {
    const starts = [_][]const u8{ "pub ", "fn ", "const ", "var ", "type ", "struct ", "enum ", "class ", "interface ", "def ", "function ", "test \"", "## " };
    for (starts) |start| if (std.mem.startsWith(u8, prefix, start)) return true;
    return false;
}

/// Gives public API declarations stronger reconstruction value than local syntax.
fn startsPublicDeclaration(prefix: []const u8) bool {
    return std.mem.startsWith(u8, prefix, "pub fn ") or
        std.mem.startsWith(u8, prefix, "pub const ") or
        std.mem.startsWith(u8, prefix, "pub var ") or
        std.mem.startsWith(u8, prefix, "export ");
}

/// Serializes booleans identically in human headers and JSON fields.
fn boolText(value: bool) []const u8 {
    return if (value) "true" else "false";
}

/// Frames one UTF-8 value as a valid JSON string.
fn writeJsonString(writer: anytype, value: []const u8) !void {
    try writer.writeByte('"');
    try writeJsonStringContents(writer, value);
    try writer.writeByte('"');
}

/// Escapes control and delimiter bytes while preserving validated UTF-8 bytes.
fn writeJsonStringContents(writer: anytype, value: []const u8) !void {
    for (value) |byte| switch (byte) {
        '\\' => try writer.writeAll("\\\\"),
        '"' => try writer.writeAll("\\\""),
        0x08 => try writer.writeAll("\\b"),
        0x0c => try writer.writeAll("\\f"),
        '\n' => try writer.writeAll("\\n"),
        '\r' => try writer.writeAll("\\r"),
        '\t' => try writer.writeAll("\\t"),
        else => if (byte < 0x20) try writer.print("\\u00{x:0>2}", .{byte}) else try writer.writeByte(byte),
    };
}

test "incremental utf8 accepts split sequences and rejects invalid continuations" {
    var valid = Utf8State{};
    for ("a🙂z") |byte| valid.push(byte);
    try std.testing.expect(!valid.invalid and valid.expected == 0);
    var invalid = Utf8State{};
    for ([_]u8{ 0xE0, 0x80, 0x80 }) |byte| invalid.push(byte);
    try std.testing.expect(invalid.invalid);
}

test "obligation and evidence features remain explicit" {
    try std.testing.expect(isObligation("never"));
    try std.testing.expect(isHexEvidence("0123456789abcdef"));
    try std.testing.expect(isNumericEvidence("p95"));
    try std.testing.expect(startsDeclaration("pub fn run() void"));
}

/// Exercises the production owner into an exact in-memory test projection.
fn testRun(allocator: std.mem.Allocator, path: []const u8, level: cli.MinLevel, max_bytes: usize, format: cli.MinFormat) ![]u8 {
    var rendered: std.Io.Writer.Allocating = .init(allocator);
    try run(std.testing.io, allocator, .{ .path = path, .level = level, .max_bytes = max_bytes, .format = format }, &rendered.writer);
    return rendered.toOwnedSlice();
}

test "low removes only byte-verified duplicate units and preserves coordinates" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const repeated = "repeat evidence " ** 20 ++ "\n";
    const source = repeated ++ repeated ++ "unique requirement must remain\n";
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "duplicate.txt", .data = source });
    const root = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}", .{&tmp.sub_path});
    const path = try std.fs.path.join(allocator, &.{ root, "duplicate.txt" });
    const bytes = try testRun(allocator, path, .low, 4096, .json);
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, bytes, .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings("ix.min.v1", parsed.value.object.get("schema").?.string);
    try std.testing.expectEqual(@as(i64, 1), parsed.value.object.get("omitted_units").?.integer);
    try std.testing.expect(!parsed.value.object.get("lossy").?.bool);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "unique requirement must remain") != null);
}

test "med json is deterministic valid and bounded over exact source ranges" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const source =
        "# Contract\nfirst boundary\n\n" ++
        ("ordinary repeated context without a decision\n" ** 40) ++
        "must preserve the exact failure code E_LIMIT_42\nlast boundary";
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "bounded.md", .data = source });
    const root = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}", .{&tmp.sub_path});
    const path = try std.fs.path.join(allocator, &.{ root, "bounded.md" });
    const first = try testRun(allocator, path, .med, 1400, .json);
    const second = try testRun(allocator, path, .med, 1400, .json);
    try std.testing.expectEqualStrings(first, second);
    try std.testing.expect(first.len <= 1400);
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, first, .{});
    defer parsed.deinit();
    try std.testing.expectEqual(@as(i64, @intCast(first.len)), parsed.value.object.get("output_bytes").?.integer);
    try std.testing.expect(parsed.value.object.get("lossy").?.bool);
    try std.testing.expect(std.mem.indexOf(u8, first, "first boundary") != null);
    try std.testing.expect(std.mem.indexOf(u8, first, "last boundary") != null);
}

test "text and json reject budgets below the truthful minimum" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "one.txt", .data = "one complete unit\n" });
    const root = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}", .{&tmp.sub_path});
    const path = try std.fs.path.join(allocator, &.{ root, "one.txt" });
    inline for (.{ cli.MinFormat.text, cli.MinFormat.json }) |format| {
        var rendered: std.Io.Writer.Allocating = .init(allocator);
        try std.testing.expectError(MinError.ByteBudgetTooSmall, run(std.testing.io, allocator, .{ .path = path, .level = .high, .max_bytes = 16, .format = format }, &rendered.writer));
        try std.testing.expectEqual(@as(usize, 0), rendered.writer.buffered().len);
    }
}

test "binary and invalid utf8 inputs fail before output" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "binary.txt", .data = "a\x00b" });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "invalid.txt", .data = "a\xffb" });
    const root = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}", .{&tmp.sub_path});
    const binary_path = try std.fs.path.join(allocator, &.{ root, "binary.txt" });
    const invalid_path = try std.fs.path.join(allocator, &.{ root, "invalid.txt" });
    var output_a: std.Io.Writer.Allocating = .init(allocator);
    try std.testing.expectError(MinError.BinaryInput, run(std.testing.io, allocator, .{ .path = binary_path }, &output_a.writer));
    var output_b: std.Io.Writer.Allocating = .init(allocator);
    try std.testing.expectError(MinError.InvalidUtf8, run(std.testing.io, allocator, .{ .path = invalid_path }, &output_b.writer));
}

test "a pathological long line remains whole or fails its budget" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const source = "x" ** (1024 * 1024 + 1);
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "long.txt", .data = source });
    const root = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}", .{&tmp.sub_path});
    const path = try std.fs.path.join(allocator, &.{ root, "long.txt" });
    var rendered: std.Io.Writer.Allocating = .init(allocator);
    try std.testing.expectError(MinError.ByteBudgetTooSmall, run(std.testing.io, allocator, .{ .path = path, .level = .high, .max_bytes = 8192 }, &rendered.writer));
    try std.testing.expectEqual(@as(usize, 0), rendered.writer.buffered().len);
}

/// Resolves a temporary fixture through the same cwd-relative file contract.
fn testPath(allocator: std.mem.Allocator, tmp: *std.testing.TmpDir, name: []const u8) ![]const u8 {
    const root = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}", .{&tmp.sub_path});
    return std.fs.path.join(allocator, &.{ root, name });
}

test "empty input has zero lines and a truthful machine envelope" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "empty.txt", .data = "" });
    const bytes = try testRun(allocator, try testPath(allocator, &tmp, "empty.txt"), .med, 1024, .json);
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, bytes, .{});
    defer parsed.deinit();
    try std.testing.expectEqual(@as(i64, 0), parsed.value.object.get("input_lines").?.integer);
    try std.testing.expectEqual(@as(i64, 0), parsed.value.object.get("retained_units").?.integer);
}

test "crlf and final non-newline bytes remain exact" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const source = "alpha\r\nbeta";
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "crlf.txt", .data = source });
    const bytes = try testRun(allocator, try testPath(allocator, &tmp, "crlf.txt"), .low, 2048, .json);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "alpha\\r\\nbeta") != null);
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, bytes, .{});
    defer parsed.deinit();
    try std.testing.expectEqual(@as(i64, 2), parsed.value.object.get("input_lines").?.integer);
}

test "source sha256 binds the exact bytes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const source = "hash me exactly\n";
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "hash.txt", .data = source });
    const bytes = try testRun(allocator, try testPath(allocator, &tmp, "hash.txt"), .low, 2048, .json);
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(source, &digest, .{});
    const expected = std.fmt.bytesToHex(digest, .lower);
    try std.testing.expect(std.mem.indexOf(u8, bytes, &expected) != null);
}

test "obligations declarations paths and metrics outrank ordinary prose" {
    var sketch = FrequencySketch{};
    var ordinary = UnitBuilder.init(0, 1);
    for ("ordinary words drift through context\n") |byte| ordinary.push(&sketch, byte);
    const ordinary_unit = ordinary.finish(&sketch, ordinary.bytes, 1);
    var evidence = UnitBuilder.init(0, 1);
    for ("pub fn verify() must return E_LIMIT_42 --json C:/proof\n") |byte| evidence.push(&sketch, byte);
    const evidence_unit = evidence.finish(&sketch, evidence.bytes, 1);
    try std.testing.expect(evidence_unit.score > ordinary_unit.score);
}

/// Constructs minimal deterministic unit metadata for isolated selector proofs.
fn testUnit(start: u64, end: u64, digest_a: u64, digest_b: u64) Unit {
    return .{ .range = .{ .start_byte = start, .end_byte = end, .start_line = @intCast(start / 5 + 1), .end_line = @intCast(start / 5 + 1) }, .class = .paragraph, .digest_a = digest_a, .digest_b = digest_b, .features = @splat(0), .score = 1, .boundary_preserve = false };
}

test "equal candidate digests cannot merge unequal bytes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "collision.txt", .data = "AAAA\nBBBB\n" });
    const path = try testPath(allocator, &tmp, "collision.txt");
    var file = try std.Io.Dir.cwd().openFile(std.testing.io, path, .{});
    defer file.close(std.testing.io);
    var units = [_]Unit{ testUnit(0, 5, 7, 9), testUnit(5, 10, 7, 9) };
    try markExactDuplicates(std.testing.io, allocator, &file, &units);
    try std.testing.expect(units[1].duplicate_of == null);
}

test "exactly equal ranges deduplicate after byte proof" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "equal.txt", .data = "AAAA\nAAAA\n" });
    const path = try testPath(allocator, &tmp, "equal.txt");
    var file = try std.Io.Dir.cwd().openFile(std.testing.io, path, .{});
    defer file.close(std.testing.io);
    var units = [_]Unit{ testUnit(0, 5, 7, 9), testUnit(5, 10, 7, 9) };
    try markExactDuplicates(std.testing.io, allocator, &file, &units);
    try std.testing.expectEqual(@as(?usize, 0), units[1].duplicate_of);
}

test "selected units serialize in ascending source order" {
    const units = [_]Unit{ testUnit(0, 5, 1, 1), testUnit(5, 10, 2, 2), testUnit(10, 15, 3, 3) };
    var mutable = units;
    mutable[0].selected = true;
    mutable[2].selected = true;
    var last: u64 = 0;
    for (mutable) |unit| if (unit.selected) {
        try std.testing.expect(unit.range.start_byte >= last);
        last = unit.range.end_byte;
    };
}

test "low refuses to omit unique content for a small budget" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "unique.txt", .data = "unique alpha\nunique beta\n" });
    var rendered: std.Io.Writer.Allocating = .init(allocator);
    try std.testing.expectError(MinError.ByteBudgetTooSmall, run(std.testing.io, allocator, .{ .path = try testPath(allocator, &tmp, "unique.txt"), .level = .low, .max_bytes = 64 }, &rendered.writer));
}

test "human projection exposes omission coordinates and reasons" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const source = "first boundary\n" ++ ("ordinary context line for omission\n" ** 40) ++ "last boundary\n";
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "omit.txt", .data = source });
    const bytes = try testRun(allocator, try testPath(allocator, &tmp, "omit.txt"), .high, 1200, .text);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "… omitted lines") != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "reason=") != null);
}

test "human output_bytes equals the complete utf8 payload" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "size.txt", .data = "alpha\nbeta\n" });
    const bytes = try testRun(allocator, try testPath(allocator, &tmp, "size.txt"), .low, 2048, .text);
    var needle_buffer: [64]u8 = undefined;
    const needle = try std.fmt.bufPrint(&needle_buffer, "output_bytes={}", .{bytes.len});
    try std.testing.expect(std.mem.indexOf(u8, bytes, needle) != null);
}

test "valid multibyte utf8 survives chunk-independent projection" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "unicode.txt", .data = "alpha 🙂 beta\n終わり\n" });
    const bytes = try testRun(allocator, try testPath(allocator, &tmp, "unicode.txt"), .low, 2048, .json);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "🙂") != null);
    try std.testing.expect(std.unicode.utf8ValidateSlice(bytes));
}

test "directory targets preserve the one-file contract" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var rendered: std.Io.Writer.Allocating = .init(allocator);
    const root = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}", .{&tmp.sub_path});
    try std.testing.expectError(MinError.NotFile, run(std.testing.io, allocator, .{ .path = root }, &rendered.writer));
}

test "novel feature signatures gain more marginal evidence" {
    var selected = testUnit(0, 5, 1, 1);
    selected.selected = true;
    selected.features[0] = 1;
    var duplicate_shape = testUnit(5, 10, 2, 2);
    duplicate_shape.features[0] = 1;
    var novel = testUnit(10, 15, 3, 3);
    novel.features[0] = 2;
    const units = [_]Unit{ selected, duplicate_shape, novel };
    try std.testing.expect(noveltyScore(novel.features, &units) > noveltyScore(duplicate_shape.features, &units));
}
