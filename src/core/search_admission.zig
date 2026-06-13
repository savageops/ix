const std = @import("std");
const expr = @import("expr.zig");
const sz = @import("sz.zig");
const trigram = @import("trigram.zig");

const TRIGRAM_ADMISSION_CAPACITY = 4096;
const TRIGRAM_ADMISSION_HASH_MASK: usize = TRIGRAM_ADMISSION_CAPACITY - 1;
const FILE_ADMISSION_MAX_NEEDLES = expr.MAX_PREDICATES;

pub const FileAdmissionMode = enum {
    disabled,
    all,
    any,
};

pub const TrigramAdmissionProgram = struct {
    eligible: bool = false,
    mode: trigram.AdmissionMode = .all,
    group_count: usize = 0,
    group_complete_mask: u64 = 0,
    required_counts: [trigram.MAX_GROUPS]u8 = @splat(0),
    keys: [TRIGRAM_ADMISSION_CAPACITY]trigram.Trigram = @splat(0),
    group_masks: [TRIGRAM_ADMISSION_CAPACITY]u64 = @splat(0),
    occupied: [TRIGRAM_ADMISSION_CAPACITY]bool = @splat(false),
    file_admission_mode: FileAdmissionMode = .disabled,
    file_admission_count: usize = 0,
    file_admission_needles: [FILE_ADMISSION_MAX_NEEDLES][]const u8 = @splat(""),

    pub fn compile(admission: trigram.Admission, plan: expr.ExpressionPlan, case_insensitive: bool) TrigramAdmissionProgram {
        var program = TrigramAdmissionProgram{
            .eligible = admission.eligible,
            .mode = admission.mode,
            .group_count = admission.group_count,
        };
        program.compileFileAdmission(plan, case_insensitive);
        if (!admission.eligible) return program;

        for (admission.groups[0..admission.group_count], 0..) |group, group_index| {
            program.required_counts[group_index] = @intCast(group.trigram_count);
            program.group_complete_mask |= groupBit(group_index);
            for (group.trigrams[0..group.trigram_count]) |needle| {
                program.insert(needle, group_index);
            }
        }
        return program;
    }

    fn compileFileAdmission(self: *TrigramAdmissionProgram, plan: expr.ExpressionPlan, case_insensitive: bool) void {
        if (case_insensitive or plan.predicate_count < 2) return;
        const predicates = plan.predicates[0..plan.predicate_count];
        switch (plan.mode) {
            .any => {
                for (predicates) |predicate| {
                    const needle = fileAdmissionNeedleRuntime(predicate) orelse {
                        self.file_admission_mode = .disabled;
                        self.file_admission_count = 0;
                        return;
                    };
                    self.appendFileAdmissionNeedle(needle);
                }
                if (self.file_admission_count != 0) self.file_admission_mode = .any;
            },
            .all => {
                for (predicates) |predicate| {
                    if (fileAdmissionNeedleRuntime(predicate)) |needle| self.appendFileAdmissionNeedle(needle);
                }
                if (self.file_admission_count != 0) self.file_admission_mode = .all;
            },
        }
    }

    fn appendFileAdmissionNeedle(self: *TrigramAdmissionProgram, needle: []const u8) void {
        if (self.file_admission_count >= self.file_admission_needles.len) return;
        self.file_admission_needles[self.file_admission_count] = needle;
        self.file_admission_count += 1;
    }

    pub fn fileAdmissionMiss(self: *const TrigramAdmissionProgram, bytes: []const u8) bool {
        return switch (self.file_admission_mode) {
            .disabled => false,
            .all => {
                for (self.file_admission_needles[0..self.file_admission_count]) |needle| {
                    if (sz.indexOfAdmission(bytes, needle) == null) return true;
                }
                return false;
            },
            .any => {
                for (self.file_admission_needles[0..self.file_admission_count]) |needle| {
                    if (sz.indexOfAdmission(bytes, needle) != null) return false;
                }
                return self.file_admission_count != 0;
            },
        };
    }

    pub fn mayMatch(self: *const TrigramAdmissionProgram, bytes: []const u8) bool {
        if (!self.eligible) return true;
        if (bytes.len < 3) return false;

        var seen_slots: [TRIGRAM_ADMISSION_CAPACITY]bool = @splat(false);
        var group_seen_counts: [trigram.MAX_GROUPS]u8 = @splat(0);
        var satisfied_groups: u64 = 0;
        var rolling: trigram.Trigram = trigram.key(bytes[0..3]);
        if (self.recordTrigram(rolling, &seen_slots, &group_seen_counts, &satisfied_groups)) return true;

        var index: usize = 3;
        while (index < bytes.len) : (index += 1) {
            rolling = ((rolling & 0xffff) << 8) | bytes[index];
            if (self.recordTrigram(rolling, &seen_slots, &group_seen_counts, &satisfied_groups)) return true;
        }
        return false;
    }

    fn insert(self: *TrigramAdmissionProgram, needle: trigram.Trigram, group_index: usize) void {
        var slot = hashTrigram(needle);
        while (self.occupied[slot]) : (slot = (slot + 1) & TRIGRAM_ADMISSION_HASH_MASK) {
            if (self.keys[slot] == needle) {
                self.group_masks[slot] |= groupBit(group_index);
                return;
            }
        }
        self.occupied[slot] = true;
        self.keys[slot] = needle;
        self.group_masks[slot] = groupBit(group_index);
    }

    fn findSlot(self: *const TrigramAdmissionProgram, needle: trigram.Trigram) ?usize {
        var slot = hashTrigram(needle);
        while (self.occupied[slot]) : (slot = (slot + 1) & TRIGRAM_ADMISSION_HASH_MASK) {
            if (self.keys[slot] == needle) return slot;
        }
        return null;
    }

    fn recordTrigram(
        self: *const TrigramAdmissionProgram,
        needle: trigram.Trigram,
        seen_slots: *[TRIGRAM_ADMISSION_CAPACITY]bool,
        group_seen_counts: *[trigram.MAX_GROUPS]u8,
        satisfied_groups: *u64,
    ) bool {
        const slot = self.findSlot(needle) orelse return false;
        if (seen_slots[slot]) return false;
        seen_slots[slot] = true;

        var mask = self.group_masks[slot];
        while (mask != 0) {
            const group_index: usize = @intCast(@ctz(mask));
            group_seen_counts[group_index] += 1;
            if (group_seen_counts[group_index] == self.required_counts[group_index]) {
                satisfied_groups.* |= groupBit(group_index);
                if (self.mode == .any) return true;
                if ((satisfied_groups.* & self.group_complete_mask) == self.group_complete_mask) return true;
            }
            mask &= mask - 1;
        }
        return false;
    }
};

fn groupBit(group_index: usize) u64 {
    return @as(u64, 1) << @as(u6, @intCast(group_index));
}

fn hashTrigram(needle: trigram.Trigram) usize {
    var value = needle *% 0x9E3779B1;
    value ^= value >> 16;
    return @as(usize, value) & TRIGRAM_ADMISSION_HASH_MASK;
}

/// Extracts only contract-safe whole-file admission needles.
/// These needles are mandatory substrings for the predicate shape, so absence
/// from the file proves absence of a match without invoking the line verifier.
pub fn fileAdmissionNeedle(comptime kind: expr.PredicateKind, comptime strategy: expr.MatcherStrategy, predicate: expr.Predicate) ?[]const u8 {
    switch (kind) {
        .literal, .prefix, .suffix => return admissionProbeNeedle(predicate.value),
        .regex => switch (strategy) {
            .regex_plain_literal => {
                if (std.mem.indexOfScalar(u8, predicate.value, '\\') == null and predicate.value.len >= 2)
                    return admissionProbeNeedle(predicate.value);
                return null;
            },
            .regex_word_boundary_literal => {
                const body = expr.stripWordBoundaryAnchors(predicate.value);
                return admissionProbeNeedle(body);
            },
            else => return null,
        },
    }
}

pub fn fileAdmissionNeedleRuntime(predicate: expr.Predicate) ?[]const u8 {
    switch (predicate.kind) {
        .literal, .prefix, .suffix => return admissionProbeNeedle(predicate.value),
        .regex => switch (predicate.strategy) {
            .regex_plain_literal => {
                if (std.mem.indexOfScalar(u8, predicate.value, '\\') == null and predicate.value.len >= 2)
                    return admissionProbeNeedle(predicate.value);
                return null;
            },
            .regex_word_boundary_literal => {
                const body = expr.stripWordBoundaryAnchors(predicate.value);
                return admissionProbeNeedle(body);
            },
            else => return null,
        },
    }
}

pub fn admissionProbeNeedle(needle: []const u8) ?[]const u8 {
    if (needle.len < 2) return null;
    if (needle.len <= 16) return needle;
    return needle[0..8];
}

test "multi predicate file admission proves literal any absence" {
    const plan = try expr.parse("lit:PM_RESUME || lit:PM_SUSPEND");
    const admission = trigram.admit(plan);
    const program = TrigramAdmissionProgram.compile(admission, plan, false);
    try std.testing.expectEqual(FileAdmissionMode.any, program.file_admission_mode);
    try std.testing.expectEqual(@as(usize, 2), program.file_admission_count);
    try std.testing.expect(program.fileAdmissionMiss("no power-management token here"));
    try std.testing.expect(!program.fileAdmissionMiss("calls PM_RESUME once"));
}

test "compiled file admission rejects all-mode missing mandatory needle" {
    const plan = try expr.parse("lit:alpha && lit:omega");
    const admission = trigram.admit(plan);
    const program = TrigramAdmissionProgram.compile(admission, plan, false);
    try std.testing.expectEqual(FileAdmissionMode.all, program.file_admission_mode);
    try std.testing.expectEqual(@as(usize, 2), program.file_admission_count);
    try std.testing.expect(program.fileAdmissionMiss("alpha only"));
    try std.testing.expect(!program.fileAdmissionMiss("alpha and omega"));
}

test "multi predicate file admission preserves unsupported any predicates" {
    const plan = try expr.parse("lit:PM_RESUME || re:PM_.*");
    const admission = trigram.admit(plan);
    const program = TrigramAdmissionProgram.compile(admission, plan, false);
    try std.testing.expectEqual(FileAdmissionMode.disabled, program.file_admission_mode);
    try std.testing.expect(!program.fileAdmissionMiss("PM_SUSPEND"));
}

test "compiled file admission keeps supported all-mode subset" {
    const plan = try expr.parse("lit:PM_RESUME && re:PM_.*");
    const admission = trigram.admit(plan);
    const program = TrigramAdmissionProgram.compile(admission, plan, false);
    try std.testing.expectEqual(FileAdmissionMode.all, program.file_admission_mode);
    try std.testing.expectEqual(@as(usize, 1), program.file_admission_count);
    try std.testing.expect(program.fileAdmissionMiss("PM_SUSPEND"));
    try std.testing.expect(!program.fileAdmissionMiss("PM_RESUME"));
}

test "compiled file admission disables for case insensitive search" {
    const plan = try expr.parse("lit:alpha && lit:omega");
    const admission = trigram.admit(plan);
    const program = TrigramAdmissionProgram.compile(admission, plan, true);
    try std.testing.expectEqual(FileAdmissionMode.disabled, program.file_admission_mode);
    try std.testing.expect(!program.fileAdmissionMiss("alpha only"));
}

test "compiled file admission stores long prefix probe once" {
    const plan = try expr.parse("lit:__IX_ABSENT_SENTINEL_DO_NOT_MATCH__ && lit:omega");
    const admission = trigram.admit(plan);
    const program = TrigramAdmissionProgram.compile(admission, plan, false);
    try std.testing.expectEqual(FileAdmissionMode.all, program.file_admission_mode);
    try std.testing.expectEqualStrings("__IX_ABS", program.file_admission_needles[0]);
    try std.testing.expect(program.fileAdmissionMiss("__IX_ABS prefix without suffix"));
}

test "long file admission uses mandatory prefix probe" {
    const probe = admissionProbeNeedle("__IX_ABSENT_SENTINEL_DO_NOT_MATCH__") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("__IX_ABS", probe);
    try std.testing.expectEqualStrings("static", admissionProbeNeedle("static").?);
    try std.testing.expect(admissionProbeNeedle("x") == null);
}

test "trigram program requires every all-mode evidence group" {
    const plan = try expr.parse("lit:alpha && lit:omega");
    const admission = trigram.admit(plan);
    const program = TrigramAdmissionProgram.compile(admission, plan, false);
    var bytes: [4096]u8 = undefined;
    @memset(bytes[0..], 'z');
    @memcpy(bytes[64..69], "alpha");

    try std.testing.expect(!program.mayMatch(bytes[0..]));
    @memcpy(bytes[128..133], "omega");
    try std.testing.expect(program.mayMatch(bytes[0..]));
}

test "trigram program admits any-mode satisfied branch" {
    const plan = try expr.parse("lit:alpha || lit:omega");
    const admission = trigram.admit(plan);
    const program = TrigramAdmissionProgram.compile(admission, plan, false);
    var bytes: [4096]u8 = undefined;
    @memset(bytes[0..], 'z');
    @memcpy(bytes[96..101], "omega");

    try std.testing.expect(program.mayMatch(bytes[0..]));
}

test "file admission needle lowers only contract-safe predicate shapes" {
    const word_plan = try expr.parse("re:\\bPM_RESUME\\b");
    try std.testing.expectEqualStrings(
        "PM_RESUME",
        fileAdmissionNeedle(.regex, .regex_word_boundary_literal, word_plan.predicates[0]).?,
    );

    const full_plan = try expr.parse("re:PM_.*RESUME");
    try std.testing.expect(fileAdmissionNeedle(.regex, .regex_full, full_plan.predicates[0]) == null);
}
