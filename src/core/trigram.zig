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
    case_insensitive: bool = false,
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
    if (literalAlternatesAdmission(plan)) |admission| return admission;

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

fn literalAlternatesAdmission(plan: expr.ExpressionPlan) ?Admission {
    if (plan.predicate_count != 1) return null;

    const predicate = plan.predicates[0];
    if (predicate.kind != .regex) return null;
    if (predicate.strategy != .regex_literal_alternates) return null;
    const case_insensitive = std.mem.startsWith(u8, predicate.value, "(?i)");

    const body = expr.literalAlternatesBody(predicate.value);
    var admission = Admission{
        .eligible = true,
        .mode = .any,
        .case_insensitive = case_insensitive,
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

        if (admission.group_count == admission.groups.len) return null;
        const evidence = evidenceForLiteralAlternateBranch(body[branch_start..index], admission.group_count, case_insensitive);
        if (evidence.trigram_count == 0) return null;
        admission.groups[admission.group_count] = evidence;
        admission.group_count += 1;
        branch_start = index + 1;
    }

    if (admission.group_count == 0) return null;
    admission.reason = .none;
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

fn evidenceForLiteralAlternateBranch(branch: []const u8, source_index: usize, case_insensitive: bool) PredicateEvidence {
    var evidence = PredicateEvidence{ .source_index = source_index };
    appendTrigramsFromLiteralAlternateBranch(&evidence, branch, case_insensitive);
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

fn appendTrigramsFromLiteralAlternateBranch(evidence: *PredicateEvidence, branch: []const u8, case_insensitive: bool) void {
    var decoded_len: usize = 0;
    var last: [2]u8 = undefined;
    var index: usize = 0;

    while (index < branch.len) : (index += 1) {
        var byte = branch[index];
        if (byte == '\\') {
            index += 1;
            if (index >= branch.len) return;
            byte = branch[index];
            switch (byte) {
                'b', 'B', 'd', 'D', 's', 'S', 'w', 'W', 'x', 'u', 'p', 'P' => return,
                else => {},
            }
        } else if (isRegexMeta(byte)) {
            return;
        }

        // For case-insensitive admission, lowercase the byte before
        // building trigram keys. The probe will also lowercase file bytes
        // so lowercased keys match case-insensitively.
        if (case_insensitive) byte = std.ascii.toLower(byte);

        if (decoded_len >= 2) {
            appendUnique(evidence, key(&.{ last[0], last[1], byte }));
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

    if (decoded_len < 3) {
        evidence.trigram_count = 0;
    }
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

test "literal alternates admission lowers each branch as any-mode evidence" {
    const plan = try expr.parse("re:(ERR_SYS|PME_TURN_OFF|LINK_REQ_RST|CFG_BME_EVT)");
    const admission = admit(plan);

    try std.testing.expect(admission.eligible);
    try std.testing.expectEqual(AdmissionMode.any, admission.mode);
    try std.testing.expectEqual(@as(usize, 4), admission.group_count);
    try std.testing.expect(admission.groups[0].contains(key("ERR")));
    try std.testing.expect(admission.groups[1].contains(key("PME")));
    try std.testing.expect(admission.groups[2].contains(key("LIN")));
    try std.testing.expect(admission.groups[3].contains(key("CFG")));
}

test "literal alternates admission rejects short or regexy branches" {
    try std.testing.expect(!admit(try expr.parse("re:(ab|cde)")).eligible);
    try std.testing.expect(!admit(try expr.parse("re:(abc|de\\w)")).eligible);
}

test "literal alternates admission supports case-insensitive alternates" {
    const admission = admit(try expr.parse("re:(?i)(alpha|beta)"));
    try std.testing.expect(admission.eligible);
    try std.testing.expect(admission.case_insensitive);
    try std.testing.expectEqual(AdmissionMode.any, admission.mode);
}
