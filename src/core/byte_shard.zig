const std = @import("std");
const expr = @import("expr.zig");
const literal_alternates = @import("literal_alternates.zig");
const simd = @import("simd.zig");

pub const LINE_BOUNDARY_SEARCH_LIMIT: usize = 1024 * 1024;
const REGEX_DECOMPOSITION_MIN_LITERAL_LEN: usize = 3;

pub const Strategy = enum {
    literal_occurrence,
    literal_alternates_line,
    word_boundary_line,
    regex_decomposition_line,

    pub fn text(self: Strategy) []const u8 {
        return switch (self) {
            .literal_occurrence => "literal",
            .literal_alternates_line => "literal_alternates",
            .word_boundary_line => "word_boundary_literal",
            .regex_decomposition_line => "regex_decomposition",
        };
    }
};

pub const Plan = struct {
    strategy: Strategy,
    needle: []const u8,
    pattern: []const u8 = "",
    case_insensitive: bool = false,
};

pub const Range = struct {
    logical_start: usize,
    logical_end: usize,
    widened_start: usize,
    widened_end: usize,
    line_aligned: bool = false,
};

pub fn plan(expression_plan: expr.ExpressionPlan) ?Plan {
    if (expression_plan.predicate_count != 1) return null;
    const predicate = expression_plan.predicates[0];
    return switch (predicate.kind) {
        .literal => if (predicate.value.len >= 2) .{
            .strategy = .literal_occurrence,
            .needle = predicate.value,
        } else null,
        .regex => switch (predicate.strategy) {
            .regex_plain_literal => if (std.mem.indexOfScalar(u8, predicate.value, '\\') == null and predicate.value.len >= 2) .{
                .strategy = .literal_occurrence,
                .needle = predicate.value,
            } else null,
            .regex_word_boundary_literal => blk: {
                const body = stripWordBoundaryAnchors(predicate.value);
                break :blk if (body.len >= 2) .{
                    .strategy = .word_boundary_line,
                    .needle = body,
                } else null;
            },
            .regex_literal_alternates => blk: {
                const pattern_body = expr.literalAlternatesBody(predicate.value);
                const branch = literal_alternates.firstBranchAtLeast(pattern_body, 2) orelse break :blk null;
                break :blk .{
                    .strategy = .literal_alternates_line,
                    .needle = branch,
                    .pattern = pattern_body,
                    .case_insensitive = std.mem.startsWith(u8, predicate.value, "(?i)"),
                };
            },
            .regex_decomposition_candidate_lines => blk: {
                const needle = regexDecompositionNeedle(predicate.value) orelse break :blk null;
                break :blk .{
                    .strategy = .regex_decomposition_line,
                    .needle = needle,
                    .pattern = predicate.value,
                };
            },
            else => null,
        },
        else => null,
    };
}

pub fn rangeFor(data: []const u8, shard_plan: Plan, logical_start: usize, logical_end: usize, index: usize, range_count: usize) ?Range {
    return switch (shard_plan.strategy) {
        .literal_occurrence => blk: {
            const overlap = shard_plan.needle.len - 1;
            break :blk .{
                .logical_start = logical_start,
                .logical_end = logical_end,
                .widened_start = logical_start -| overlap,
                .widened_end = @min(logical_end + overlap, data.len),
            };
        },
        .literal_alternates_line => lineOwnedRange(data, logical_start, logical_end, index, range_count),
        .word_boundary_line => lineOwnedRange(data, logical_start, logical_end, index, range_count),
        .regex_decomposition_line => lineOwnedRange(data, logical_start, logical_end, index, range_count),
    };
}

pub fn lineOwnedRange(data: []const u8, nominal_start: usize, nominal_end: usize, index: usize, range_count: usize) ?Range {
    const start = if (index == 0)
        @min(nominal_start, data.len)
    else
        findOwnedLineBoundaryAfter(data, nominal_start) orelse return null;
    const end = if (index + 1 >= range_count)
        data.len
    else
        findOwnedLineBoundaryAfter(data, nominal_end) orelse return null;
    if (start > end) return null;
    return .{
        .logical_start = start,
        .logical_end = end,
        .widened_start = start,
        .widened_end = end,
        .line_aligned = true,
    };
}

pub fn findOwnedLineBoundaryAfter(data: []const u8, position: usize) ?usize {
    if (position >= data.len) return data.len;
    const end = @min(data.len, position + LINE_BOUNDARY_SEARCH_LIMIT);
    const relative = simd.indexOfByte(data[position..end], '\n') orelse return null;
    return position + relative + 1;
}

pub fn stripWordBoundaryAnchors(pattern: []const u8) []const u8 {
    var body = pattern;
    if (body.len >= 2 and body[0] == '\\' and body[1] == 'b') body = body[2..];
    if (body.len >= 2 and body[body.len - 2] == '\\' and body[body.len - 1] == 'b') body = body[0 .. body.len - 2];
    return body;
}

pub fn regexDecompositionNeedle(pattern: []const u8) ?[]const u8 {
    if (std.mem.startsWith(u8, pattern, "(?i)")) return null;
    const fragment = expr.regexDecompositionLiteralCandidate(pattern) orelse return null;
    if (fragment.len < REGEX_DECOMPOSITION_MIN_LITERAL_LEN) return null;
    return fragment;
}

test "plan admits line and byte-shard kernels" {
    const literal_plan = try expr.parse("lit:Sherlock Holmes");
    const literal = plan(literal_plan).?;
    try std.testing.expectEqual(Strategy.literal_occurrence, literal.strategy);
    try std.testing.expectEqualStrings("Sherlock Holmes", literal.needle);

    const regex_literal = try expr.parse("re:Sherlock Holmes");
    const regex_plain = plan(regex_literal).?;
    try std.testing.expectEqual(Strategy.literal_occurrence, regex_plain.strategy);
    try std.testing.expectEqualStrings("Sherlock Holmes", regex_plain.needle);

    const regex_word = try expr.parse("re:\\bSherlock Holmes\\b");
    const word = plan(regex_word).?;
    try std.testing.expectEqual(Strategy.word_boundary_line, word.strategy);
    try std.testing.expectEqualStrings("Sherlock Holmes", word.needle);

    const regex_decomposed = try expr.parse("re:Sherlock\\s+Holmes");
    const decomposed = plan(regex_decomposed).?;
    try std.testing.expectEqual(Strategy.regex_decomposition_line, decomposed.strategy);
    try std.testing.expectEqualStrings("Sherlock", decomposed.needle);
    try std.testing.expectEqualStrings("Sherlock\\s+Holmes", decomposed.pattern);

    const regex_alternates = try expr.parse("re:Sherlock Holmes|John Watson|Irene Adler");
    const alternates = plan(regex_alternates).?;
    try std.testing.expectEqual(Strategy.literal_alternates_line, alternates.strategy);
    try std.testing.expectEqualStrings("Sherlock Holmes", alternates.needle);
    try std.testing.expectEqualStrings("Sherlock Holmes|John Watson|Irene Adler", alternates.pattern);

    const regex_wrapped_alternates = try expr.parse("re:(Sherlock Holmes|John Watson|Irene Adler)");
    const wrapped_alternates = plan(regex_wrapped_alternates).?;
    try std.testing.expectEqual(Strategy.literal_alternates_line, wrapped_alternates.strategy);
    try std.testing.expectEqualStrings("Sherlock Holmes", wrapped_alternates.needle);
    try std.testing.expectEqualStrings("Sherlock Holmes|John Watson|Irene Adler", wrapped_alternates.pattern);
    try std.testing.expect(!wrapped_alternates.case_insensitive);

    const regex_casefold_alternates = try expr.parse("re:(?i)(Sherlock Holmes|John Watson|Irene Adler)");
    const casefold_alternates = plan(regex_casefold_alternates).?;
    try std.testing.expectEqual(Strategy.literal_alternates_line, casefold_alternates.strategy);
    try std.testing.expect(casefold_alternates.case_insensitive);
    try std.testing.expectEqualStrings("Sherlock Holmes|John Watson|Irene Adler", casefold_alternates.pattern);

    const regex_casefold_word = try expr.parse("re:(?i)\\bSherlock Holmes\\b");
    try std.testing.expect(plan(regex_casefold_word) == null);
}
