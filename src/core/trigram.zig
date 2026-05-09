const std = @import("std");
const expr = @import("expr.zig");

pub const MAX_GROUPS = expr.MAX_PREDICATES;
pub const MAX_TRIGRAMS_PER_GROUP = 64;

pub const Trigram = u32;

pub const AdmissionMode = enum {
    all,
    any,
};

pub const IneligibleReason = enum {
    none,
    no_mandatory_trigram,
    disjunction_has_unindexed_branch,
};

pub const PredicateEvidence = struct {
    source_index: usize = 0,
    trigrams: [MAX_TRIGRAMS_PER_GROUP]Trigram = undefined,
    trigram_count: usize = 0,

    pub fn contains(self: PredicateEvidence, value: Trigram) bool {
        for (self.trigrams[0..self.trigram_count]) |candidate| {
            if (candidate == value) return true;
        }
        return false;
    }
};

pub const Admission = struct {
    eligible: bool = false,
    mode: AdmissionMode = .all,
    groups: [MAX_GROUPS]PredicateEvidence = undefined,
    group_count: usize = 0,
    ignored_predicates: usize = 0,
    reason: IneligibleReason = .none,

    pub fn first(self: Admission) ?PredicateEvidence {
        if (self.group_count == 0) return null;
        return self.groups[0];
    }
};

pub fn key(bytes: []const u8) Trigram {
    std.debug.assert(bytes.len == 3);
    return (@as(Trigram, bytes[0]) << 16) | (@as(Trigram, bytes[1]) << 8) | @as(Trigram, bytes[2]);
}

pub fn admit(plan: expr.ExpressionPlan) Admission {
    var admission = Admission{
        .mode = if (plan.mode == .any) .any else .all,
    };

    var index: usize = 0;
    while (index < plan.predicate_count) : (index += 1) {
        const evidence = evidenceForPredicate(plan.predicates[index], index);
        if (evidence.trigram_count == 0) {
            admission.ignored_predicates += 1;
            if (plan.mode == .any) {
                admission.eligible = false;
                admission.group_count = 0;
                admission.reason = .disjunction_has_unindexed_branch;
                return admission;
            }
            continue;
        }
        admission.groups[admission.group_count] = evidence;
        admission.group_count += 1;
    }

    admission.eligible = admission.group_count > 0;
    admission.reason = if (admission.eligible) .none else .no_mandatory_trigram;
    return admission;
}

fn evidenceForPredicate(predicate: expr.Predicate, source_index: usize) PredicateEvidence {
    var evidence = PredicateEvidence{ .source_index = source_index };
    switch (predicate.kind) {
        .literal, .prefix, .suffix => appendTrigramsFromLiteral(&evidence, predicate.value),
        .regex => appendTrigramsFromRegex(&evidence, predicate.value),
    }
    return evidence;
}

fn appendTrigramsFromLiteral(evidence: *PredicateEvidence, literal: []const u8) void {
    if (literal.len < 3) return;
    var index: usize = 0;
    while (index + 3 <= literal.len) : (index += 1) {
        appendUnique(evidence, key(literal[index .. index + 3]));
    }
}

fn appendTrigramsFromRegex(evidence: *PredicateEvidence, pattern: []const u8) void {
    if (std.mem.startsWith(u8, pattern, "(?i)")) return;
    const body = pattern;
    if (hasTopLevelAlternation(body)) return;

    if (body.len > 4 and std.mem.startsWith(u8, body, "\\b") and std.mem.endsWith(u8, body, "\\b")) {
        appendDecodedRegexLiteral(evidence, body[2 .. body.len - 2]);
        return;
    }

    appendMandatoryRegexPrefix(evidence, body);
}

fn appendMandatoryRegexPrefix(evidence: *PredicateEvidence, pattern: []const u8) void {
    var literal: [256]u8 = undefined;
    var literal_len: usize = 0;
    var index: usize = if (pattern.len > 0 and pattern[0] == '^') 1 else 0;
    if (index + 2 <= pattern.len and std.mem.eql(u8, pattern[index .. index + 2], "\\b")) index += 2;

    while (index < pattern.len) {
        const token = regexLiteralToken(pattern, index) orelse break;
        if (token.end < pattern.len and isQuantifierStart(pattern[token.end])) break;
        if (literal_len >= literal.len) break;
        literal[literal_len] = token.byte;
        literal_len += 1;
        index = token.end;
    }

    appendTrigramsFromLiteral(evidence, literal[0..literal_len]);
}

fn appendDecodedRegexLiteral(evidence: *PredicateEvidence, pattern: []const u8) void {
    var literal: [256]u8 = undefined;
    var literal_len: usize = 0;
    var index: usize = 0;
    while (index < pattern.len) {
        const token = regexLiteralToken(pattern, index) orelse return;
        if (literal_len >= literal.len) break;
        literal[literal_len] = token.byte;
        literal_len += 1;
        index = token.end;
    }
    appendTrigramsFromLiteral(evidence, literal[0..literal_len]);
}

const RegexLiteralToken = struct {
    byte: u8,
    end: usize,
};

fn regexLiteralToken(pattern: []const u8, index: usize) ?RegexLiteralToken {
    if (index >= pattern.len) return null;
    const byte = pattern[index];
    if (byte == '\\') {
        if (index + 1 >= pattern.len) return null;
        const escaped = pattern[index + 1];
        return switch (escaped) {
            'b', 'w', 'd', 's', 'x' => null,
            else => .{ .byte = escaped, .end = index + 2 },
        };
    }
    if (isRegexMeta(byte)) return null;
    return .{ .byte = byte, .end = index + 1 };
}

fn appendUnique(evidence: *PredicateEvidence, value: Trigram) void {
    if (evidence.contains(value)) return;
    if (evidence.trigram_count >= evidence.trigrams.len) return;
    evidence.trigrams[evidence.trigram_count] = value;
    evidence.trigram_count += 1;
}

fn hasTopLevelAlternation(pattern: []const u8) bool {
    var depth: usize = 0;
    var index: usize = 0;
    while (index < pattern.len) : (index += 1) {
        const byte = pattern[index];
        if (byte == '\\') {
            index += 1;
            continue;
        }
        if (byte == '(') {
            depth += 1;
        } else if (byte == ')') {
            if (depth > 0) depth -= 1;
        } else if (byte == '|' and depth == 0) {
            return true;
        }
    }
    return false;
}

fn isRegexMeta(byte: u8) bool {
    return switch (byte) {
        '.', '^', '$', '*', '+', '?', '(', ')', '[', ']', '{', '}', '|' => true,
        else => false,
    };
}

fn isQuantifierStart(byte: u8) bool {
    return byte == '?' or byte == '*' or byte == '+' or byte == '{';
}

test "literal admission extracts exact overlapping trigrams" {
    const plan = try expr.parse("lit:abcd");
    const admission = admit(plan);

    try std.testing.expect(admission.eligible);
    try std.testing.expectEqual(AdmissionMode.all, admission.mode);
    try std.testing.expectEqual(@as(usize, 1), admission.group_count);
    const evidence = admission.first().?;
    try std.testing.expectEqual(@as(usize, 2), evidence.trigram_count);
    try std.testing.expectEqual(key("abc"), evidence.trigrams[0]);
    try std.testing.expectEqual(key("bcd"), evidence.trigrams[1]);
}

test "conjunction can prune from indexed predicates while verifier owns the rest" {
    const plan = try expr.parse("lit:auth && lit:x");
    const admission = admit(plan);

    try std.testing.expect(admission.eligible);
    try std.testing.expectEqual(AdmissionMode.all, admission.mode);
    try std.testing.expectEqual(@as(usize, 1), admission.group_count);
    try std.testing.expectEqual(@as(usize, 1), admission.ignored_predicates);
    try std.testing.expect(admission.groups[0].contains(key("aut")));
    try std.testing.expect(admission.groups[0].contains(key("uth")));
}

test "disjunction rejects when any branch lacks mandatory trigram evidence" {
    const plan = try expr.parse("lit:auth || lit:x");
    const admission = admit(plan);

    try std.testing.expect(!admission.eligible);
    try std.testing.expectEqual(IneligibleReason.disjunction_has_unindexed_branch, admission.reason);
    try std.testing.expectEqual(@as(usize, 0), admission.group_count);
}

test "regex prefix evidence admits exact mandatory bytes before regex classes" {
    const plan = try expr.parse("re:auth_\\d+");
    const admission = admit(plan);

    try std.testing.expect(admission.eligible);
    const evidence = admission.first().?;
    try std.testing.expectEqual(@as(usize, 3), evidence.trigram_count);
    try std.testing.expectEqual(key("aut"), evidence.trigrams[0]);
    try std.testing.expectEqual(key("uth"), evidence.trigrams[1]);
    try std.testing.expectEqual(key("th_"), evidence.trigrams[2]);
}

test "regex without mandatory exact bytes is not index admissible" {
    const plan = try expr.parse("re:\\w+");
    const admission = admit(plan);

    try std.testing.expect(!admission.eligible);
    try std.testing.expectEqual(IneligibleReason.no_mandatory_trigram, admission.reason);
}

test "casefold regex is verifier-only until folded byte semantics are explicit" {
    const plan = try expr.parse("re:(?i)sherlock");
    const admission = admit(plan);

    try std.testing.expect(!admission.eligible);
    try std.testing.expectEqual(IneligibleReason.no_mandatory_trigram, admission.reason);
}
