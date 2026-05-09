const std = @import("std");

/// Maximum number of predicates in a single expression. IX expressions are
/// composed of predicates joined by && (all) or || (any). Example:
///   "lit:ERROR && lit:timeout"  → 2 predicates, mode=all
///   "lit:ERROR || lit:latency"  → 2 predicates, mode=any
/// 32 is generous — real-world IX expressions rarely exceed 4 predicates.
pub const MAX_PREDICATES = 32;

/// Logic mode for combining predicates.
///   .all (&&): every predicate must match the line (logical AND)
///   .any (||): at least one predicate must match (logical OR)
/// An expression cannot mix && and || — the presence of "||" switches
/// the entire expression to .any mode.
pub const LogicMode = enum {
    all,
    any,
};

/// The four IX predicate types, each with distinct matching semantics:
///   literal  → substring match anywhere in the line (uses StringZilla SIMD)
///   regex    → Zig-native regex engine (recursive backtracking)
///   prefix   → line must start with the value
///   suffix   → line must end with the value
/// Expressed in IX grammar as: lit:, re:, prefix:, suffix:
pub const PredicateKind = enum {
    literal,
    regex,
    prefix,
    suffix,
};

/// Matcher strategy classifies how the search engine will execute a predicate.
/// This mirrors Rust's HIR (High-level Intermediate Representation) classifier,
/// which routes patterns to specialized fast paths. For example, `re:ERROR` is
/// classified as regex_plain_literal because the pattern contains no regex
/// metacharacters — it can be searched as a literal substring, avoiding the
/// regex engine entirely.
///
/// These classifications drive telemetry parity with Rust: the JSON stats
/// envelope reports which strategy was used, and benchmark comparisons
/// require identical strategy selection for valid measurement.
pub const MatcherStrategy = enum {
    literal,
    prefix,
    suffix,
    regex_full,
    regex_plain_literal,
    regex_ascii_casefold_literal,
    regex_fixed_width_bytes,
    regex_word_boundary_literal,
    regex_ascii_casefold_word_boundary_literal,
    regex_literal_alternates,
    regex_decomposition_candidate_lines,

    pub fn text(self: MatcherStrategy) []const u8 {
        return switch (self) {
            .literal => "literal",
            .prefix => "prefix",
            .suffix => "suffix",
            .regex_full => "regex_full",
            .regex_plain_literal => "regex_plain_literal",
            .regex_ascii_casefold_literal => "regex_ascii_casefold_literal",
            .regex_fixed_width_bytes => "regex_fixed_width_bytes",
            .regex_word_boundary_literal => "regex_word_boundary_literal",
            .regex_ascii_casefold_word_boundary_literal => "regex_ascii_casefold_word_boundary_literal",
            .regex_literal_alternates => "regex_literal_alternates",
            .regex_decomposition_candidate_lines => "regex_decomposition_candidate_lines",
        };
    }
};

pub const Predicate = struct {
    kind: PredicateKind,
    value: []const u8,
    strategy: MatcherStrategy,
    decomposition: bool = false,

    pub fn kindText(self: Predicate) []const u8 {
        return switch (self.kind) {
            .literal => "literal",
            .regex => "regex",
            .prefix => "prefix",
            .suffix => "suffix",
        };
    }
};

pub const ExpressionPlan = struct {
    source: []const u8,
    mode: LogicMode,
    predicates: [MAX_PREDICATES]Predicate,
    predicate_count: usize,

    pub fn modeText(self: ExpressionPlan) []const u8 {
        return switch (self.mode) {
            .all => "all",
            .any => "any",
        };
    }

    pub fn supportsByteMode(_: ExpressionPlan) bool {
        return true;
    }

    /// Whether this plan could be executed with Rust's outer parallel shard
    /// fast-count strategy. In Rust, eligible single-predicate plans are split
    /// across threads where each thread counts matches in its byte range
    /// independently, then results are summed. Zig doesn't implement this yet
    /// (serial scan only), but reports the field for telemetry parity.
    pub fn supportsOuterParallelShardFastCount(self: ExpressionPlan) bool {
        if (self.predicate_count != 1) return false;
        const predicate = self.predicates[0];
        if (predicate.kind != .regex) return self.supportsParallelFastCountRanges();
        return switch (predicate.strategy) {
            .regex_literal_alternates,
            .regex_word_boundary_literal,
            .regex_ascii_casefold_word_boundary_literal,
            => false,
            else => self.supportsParallelFastCountRanges(),
        };
    }

    pub fn supportsLargeDirectoryStreamingSelector(self: ExpressionPlan) bool {
        return self.supportsByteMode() and self.supportsParallelFastCountRanges();
    }

    pub fn supportsParallelFastCountRanges(self: ExpressionPlan) bool {
        if (self.predicate_count != 1) return false;
        const predicate = self.predicates[0];
        if (predicate.kind == .literal) return true;
        if (predicate.kind != .regex) return false;
        return switch (predicate.strategy) {
            .regex_plain_literal,
            .regex_ascii_casefold_literal,
            .regex_fixed_width_bytes,
            .regex_word_boundary_literal,
            .regex_ascii_casefold_word_boundary_literal,
            .regex_literal_alternates,
            => true,
            else => false,
        };
    }

    pub fn usesSingleLiteralCounter(self: ExpressionPlan) bool {
        if (self.predicate_count != 1) return false;
        const predicate = self.predicates[0];
        if (predicate.kind == .literal) return true;
        if (predicate.kind != .regex) return false;
        return switch (predicate.strategy) {
            .regex_plain_literal,
            .regex_ascii_casefold_literal,
            .regex_word_boundary_literal,
            .regex_ascii_casefold_word_boundary_literal,
            => true,
            else => false,
        };
    }

    /// Returns the overlap window (in bytes) needed when splitting a file
    /// into byte-sharded ranges for parallel counting. For literal search,
    /// overlap = needle.len - 1 because a match could straddle a range
    /// boundary. Word-boundary patterns need needle.len because \b checks
    /// the byte before the match start. Returns null if the plan can't be
    /// byte-sharded (multi-predicate or unsupported regex strategy).
    pub fn fastMatchCountRangeOverlap(self: ExpressionPlan) ?usize {
        if (self.predicate_count != 1) return null;
        const predicate = self.predicates[0];
        return switch (predicate.strategy) {
            .literal, .regex_plain_literal, .regex_ascii_casefold_literal, .regex_fixed_width_bytes, .regex_literal_alternates => predicate.value.len -| 1,
            .regex_word_boundary_literal, .regex_ascii_casefold_word_boundary_literal => predicate.value.len,
            else => null,
        };
    }
};

pub const ParseError = error{
    EmptyExpression,
    EmptyLiteral,
    EmptyPrefix,
    EmptySuffix,
    EmptyPredicate,
    TooManyPredicates,
};

/// Parses an IX expression string into a structured plan.
///
/// IX EXPRESSION GRAMMAR:
///   "lit:ERROR && lit:timeout"     → two literal predicates, AND mode
///   "lit:ERROR || lit:latency"     → two literal predicates, OR mode
///   "re:\\b(session|handshake)\\b" → one regex predicate
///   "prefix:WARN"                 → one prefix predicate
///   "suffix:.log"                 → one suffix predicate
///   "ERROR"                       → bare text → treated as literal
///
/// The parser splits on "||" (if present) or "&&", trims whitespace from
/// each segment, and classifies each into a Predicate with kind + strategy.
/// Mixed && and || in the same expression is not supported — the presence
/// of "||" anywhere switches the entire plan to .any mode.
pub fn parse(source: []const u8) ParseError!ExpressionPlan {
    const trimmed_source = std.mem.trim(u8, source, " \t\r\n");
    if (trimmed_source.len == 0) return ParseError.EmptyExpression;
    const has_or = std.mem.indexOf(u8, trimmed_source, "||") != null;

    var plan = ExpressionPlan{
        .source = trimmed_source,
        .mode = if (has_or) .any else .all,
        .predicates = undefined,
        .predicate_count = 0,
    };

    const delimiter = if (has_or) "||" else "&&";
    var cursor: usize = 0;
    while (cursor <= trimmed_source.len) {
        const rest = trimmed_source[cursor..];
        const next = std.mem.indexOf(u8, rest, delimiter);
        const end = if (next) |offset| cursor + offset else trimmed_source.len;
        const segment = std.mem.trim(u8, trimmed_source[cursor..end], " \t\r\n");
        if (segment.len > 0) {
            if (plan.predicate_count >= MAX_PREDICATES) return ParseError.TooManyPredicates;
            plan.predicates[plan.predicate_count] = try parsePredicate(segment);
            plan.predicate_count += 1;
        }
        if (next == null) break;
        cursor = end + delimiter.len;
    }
    if (plan.predicate_count == 0) return ParseError.EmptyPredicate;

    return plan;
}

fn parsePredicate(source: []const u8) ParseError!Predicate {
    if (std.mem.startsWith(u8, source, "re:")) {
        const value = source[3..];
        return .{
            .kind = .regex,
            .value = value,
            .strategy = classifyRegex(value),
            .decomposition = classifyRegexDecomposition(value),
        };
    }
    if (std.mem.startsWith(u8, source, "prefix:")) {
        const value = source[7..];
        if (value.len == 0) return ParseError.EmptyPrefix;
        return .{ .kind = .prefix, .value = value, .strategy = .prefix };
    }
    if (std.mem.startsWith(u8, source, "suffix:")) {
        const value = source[7..];
        if (value.len == 0) return ParseError.EmptySuffix;
        return .{ .kind = .suffix, .value = value, .strategy = .suffix };
    }
    const value = if (std.mem.startsWith(u8, source, "lit:")) source[4..] else source;
    if (value.len == 0) return ParseError.EmptyLiteral;
    return .{ .kind = .literal, .value = value, .strategy = .literal };
}

fn classifyRegex(pattern: []const u8) MatcherStrategy {
    const body = if (std.mem.startsWith(u8, pattern, "(?i)")) pattern[4..] else pattern;
    const casefold = body.len != pattern.len;
    if (isWordBoundaryLiteral(body)) {
        return if (casefold) .regex_ascii_casefold_word_boundary_literal else .regex_word_boundary_literal;
    }
    if (isTopLevelLiteralAlternates(body)) return .regex_literal_alternates;
    if (isPlainLiteralRegex(body)) {
        return if (casefold) .regex_ascii_casefold_literal else .regex_plain_literal;
    }
    if (isFixedWidthBytesRegex(body)) return .regex_fixed_width_bytes;
    if (classifyRegexDecomposition(body)) return .regex_decomposition_candidate_lines;
    return .regex_full;
}

fn classifyRegexDecomposition(pattern: []const u8) bool {
    const body = if (std.mem.startsWith(u8, pattern, "(?i)")) pattern[4..] else pattern;
    return std.mem.indexOf(u8, body, "\\w+\\s+") != null and std.mem.indexOf(u8, body, "\\s+\\w+") != null;
}

fn isWordBoundaryLiteral(pattern: []const u8) bool {
    return pattern.len > 4 and std.mem.startsWith(u8, pattern, "\\b") and std.mem.endsWith(u8, pattern, "\\b") and isPlainLiteralRegex(pattern[2 .. pattern.len - 2]);
}

fn isTopLevelLiteralAlternates(pattern: []const u8) bool {
    if (std.mem.indexOfScalar(u8, pattern, '|') == null) return false;
    var start: usize = 0;
    while (start <= pattern.len) {
        const end = findTopLevelAlternation(pattern, start) orelse pattern.len;
        if (!isPlainLiteralRegex(pattern[start..end])) return false;
        if (end == pattern.len) break;
        start = end + 1;
    }
    return true;
}

fn isPlainLiteralRegex(pattern: []const u8) bool {
    if (pattern.len == 0) return false;
    var index: usize = 0;
    while (index < pattern.len) : (index += 1) {
        const byte = pattern[index];
        if (byte == '\\') {
            if (index + 1 >= pattern.len) return false;
            const escaped = pattern[index + 1];
            if (escaped == 'b' or escaped == 'w' or escaped == 'd' or escaped == 's' or escaped == 'x') return false;
            index += 1;
            continue;
        }
        if (isRegexMeta(byte)) return false;
    }
    return true;
}

fn isFixedWidthBytesRegex(pattern: []const u8) bool {
    if (pattern.len == 0) return false;
    var index: usize = 0;
    while (index < pattern.len) {
        const token_end = tokenEnd(pattern, index) orelse return false;
        if (token_end < pattern.len) {
            switch (pattern[token_end]) {
                '?', '*', '+', '|' => return false,
                '{' => {
                    const close = std.mem.indexOfScalarPos(u8, pattern, token_end + 1, '}') orelse return false;
                    if (std.mem.indexOfScalar(u8, pattern[token_end + 1 .. close], ',') != null) return false;
                    index = close + 1;
                    continue;
                },
                else => {},
            }
        }
        index = token_end;
    }
    return true;
}

fn tokenEnd(pattern: []const u8, index: usize) ?usize {
    if (index >= pattern.len) return null;
    if (pattern[index] == '\\') {
        if (index + 1 >= pattern.len) return null;
        if (pattern[index + 1] == 'x') return if (index + 3 < pattern.len) index + 4 else null;
        return index + 2;
    }
    if (pattern[index] == '[') {
        const close = std.mem.indexOfScalarPos(u8, pattern, index + 1, ']') orelse return null;
        return close + 1;
    }
    if (pattern[index] == '(') {
        return null;
    }
    return index + 1;
}

fn findTopLevelAlternation(pattern: []const u8, start: usize) ?usize {
    var depth: usize = 0;
    var index = start;
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
            return index;
        }
    }
    return null;
}

fn isRegexMeta(byte: u8) bool {
    return switch (byte) {
        '.', '^', '$', '*', '+', '?', '(', ')', '[', ']', '{', '}', '|' => true,
        else => false,
    };
}

test "bare text remains literal" {
    const plan = try parse("a|b");
    try std.testing.expectEqual(LogicMode.all, plan.mode);
    try std.testing.expectEqual(PredicateKind.literal, plan.predicates[0].kind);
    try std.testing.expectEqual(@as(usize, 1), plan.predicate_count);
}

test "regex requires explicit prefix" {
    const plan = try parse("re:a|b");
    try std.testing.expectEqual(PredicateKind.regex, plan.predicates[0].kind);
    try std.testing.expectEqual(MatcherStrategy.regex_literal_alternates, plan.predicates[0].strategy);
}

test "parser trims source and splits rust-style boolean tokens" {
    const plan = try parse(" lit:alpha|| prefix:beta && suffix:gamma ");
    try std.testing.expectEqual(LogicMode.any, plan.mode);
    try std.testing.expectEqual(@as(usize, 2), plan.predicate_count);
    try std.testing.expectEqualStrings("lit:alpha|| prefix:beta && suffix:gamma", plan.source);
    try std.testing.expectEqual(PredicateKind.literal, plan.predicates[0].kind);
    try std.testing.expectEqual(PredicateKind.prefix, plan.predicates[1].kind);
    try std.testing.expectEqualStrings("beta && suffix:gamma", plan.predicates[1].value);
}

test "plan exposes rust capability predicates" {
    const literal = try parse("lit:needle");
    try std.testing.expect(literal.supportsByteMode());
    try std.testing.expect(literal.supportsParallelFastCountRanges());
    try std.testing.expect(literal.usesSingleLiteralCounter());
    try std.testing.expectEqual(@as(?usize, 5), literal.fastMatchCountRangeOverlap());

    const alternates = try parse("re:alpha|beta");
    try std.testing.expect(alternates.supportsParallelFastCountRanges());
    try std.testing.expect(!alternates.supportsOuterParallelShardFastCount());
}
