const std = @import("std");
const expr = @import("expr.zig");
const trigram = @import("trigram.zig");

pub const MAX_PROOF_TERMS = trigram.MAX_GROUPS * trigram.MAX_TRIGRAMS_PER_GROUP;

pub const PostingRepr = enum {
    singleton,
    sorted_u32,
    roaring,
    dense_bitset,
    unknown,

    pub fn text(self: PostingRepr) []const u8 {
        return switch (self) {
            .singleton => "singleton",
            .sorted_u32 => "sorted_u32",
            .roaring => "roaring",
            .dense_bitset => "dense_bitset",
            .unknown => "unknown",
        };
    }
};

pub const ProofTerm = struct {
    key: trigram.Trigram,
    source_index: usize,
    cardinality: ?usize = null,
    repr: PostingRepr = .unknown,
};

pub const ProofProgram = struct {
    query_class: []const u8,
    verifier: []const u8,
    fallback: ?[]const u8,
    terms: [MAX_PROOF_TERMS]ProofTerm = undefined,
    term_count: usize = 0,
    candidate_files_before: ?usize = null,
    candidate_files_after: ?usize = null,
};

pub fn compileProofProgram(plan: expr.ExpressionPlan) ProofProgram {
    const admission = trigram.admit(plan);
    var program = ProofProgram{
        .query_class = classifyQuery(plan, admission),
        .verifier = verifierFor(plan),
        .fallback = if (admission.eligible) null else ineligibleText(admission.reason),
    };
    if (!admission.eligible) return program;

    var group_index: usize = 0;
    while (group_index < admission.group_count) : (group_index += 1) {
        const group = admission.groups[group_index];
        for (group.trigrams[0..group.trigram_count]) |key| {
            if (program.term_count >= program.terms.len) return program;
            program.terms[program.term_count] = .{
                .key = key,
                .source_index = group.source_index,
            };
            program.term_count += 1;
        }
    }
    return program;
}

fn classifyQuery(plan: expr.ExpressionPlan, admission: trigram.Admission) []const u8 {
    if (!admission.eligible) return "verifier_only";
    if (plan.mode == .any) return "disjunctive_byte_evidence";
    var has_regex = false;
    for (plan.predicates[0..plan.predicate_count]) |predicate| {
        if (predicate.kind == .regex) has_regex = true;
    }
    return if (has_regex) "conjunctive_regex_with_mandatory_evidence" else "conjunctive_literal_evidence";
}

fn verifierFor(plan: expr.ExpressionPlan) []const u8 {
    for (plan.predicates[0..plan.predicate_count]) |predicate| {
        if (predicate.kind == .regex and predicate.strategy == .regex_full) return "regex_window";
        if (predicate.kind == .regex and predicate.decomposition) return "regex_window";
    }
    return "line_exact";
}

fn ineligibleText(reason: trigram.IneligibleReason) []const u8 {
    return switch (reason) {
        .none => "none",
        .no_mandatory_trigram => "no_mandatory_evidence",
        .disjunction_has_unindexed_branch => "disjunction_has_unindexed_branch",
    };
}

pub fn trigramBytes(key: trigram.Trigram) [3]u8 {
    return .{
        @intCast((key >> 16) & 0xff),
        @intCast((key >> 8) & 0xff),
        @intCast(key & 0xff),
    };
}

test "proof program lowers conjunctive regex to mandatory byte evidence" {
    const plan = try expr.parse("lit:auth && re:token_\\d+");
    const program = compileProofProgram(plan);
    try std.testing.expectEqualStrings("conjunctive_regex_with_mandatory_evidence", program.query_class);
    try std.testing.expectEqualStrings("regex_window", program.verifier);
    try std.testing.expect(program.term_count >= 5);
    try std.testing.expect(program.fallback == null);
}

test "proof program is verifier-only when no mandatory evidence exists" {
    const plan = try expr.parse("re:\\d+");
    const program = compileProofProgram(plan);
    try std.testing.expectEqualStrings("verifier_only", program.query_class);
    try std.testing.expectEqualStrings("no_mandatory_evidence", program.fallback.?);
    try std.testing.expectEqual(@as(usize, 0), program.term_count);
}
