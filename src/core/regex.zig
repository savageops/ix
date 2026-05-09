const std = @import("std");

/// Zig-native regex engine — a recursive backtracking matcher.
///
/// WHY NOT USE A LIBRARY:
/// Zig doesn't have a mature regex crate equivalent. Rust uses the `regex`
/// crate which compiles patterns to a Thompson NFA with SIMD-accelerated
/// literal extraction and DFA caching. This engine is intentionally simpler:
/// it handles the IX operator subset (literals, alternation, character classes,
/// word boundaries, quantifiers) without building an NFA. For the tested IX
/// patterns, the bottleneck is literal search (handled by StringZilla), not
/// regex compilation — so this simple matcher is sufficient.
///
/// SUPPORTED CONSTRUCTS:
///   Literals, `.` (any), `\w` `\d` `\s`, `\b` (word boundary),
///   `^` `$` (line anchors), `[a-z]` `[^0-9]` (character classes),
///   `?` `*` `+` (quantifiers), `{N}` (exact repetition),
///   `(a|b)` (grouped alternation), `(?i)` (inline case-insensitive),
///   `\xNN` (hex byte literals), escaped metacharacters.
///
/// Returns the 1-based column of the first match, or null.
pub fn column(line: []const u8, pattern: []const u8, case_insensitive: bool) ?usize {
    // (?i) prefix triggers case-insensitive mode regardless of the flag.
    // This matches Rust's regex crate behavior for inline mode modifiers.
    const effective_case_insensitive = case_insensitive or std.mem.startsWith(u8, pattern, "(?i)");
    const effective_pattern = if (std.mem.startsWith(u8, pattern, "(?i)")) pattern[4..] else pattern;
    var best: ?usize = null;
    var branch_start: usize = 0;
    while (branch_start <= effective_pattern.len) {
        const branch_end = findTopLevelAlternation(effective_pattern, branch_start) orelse effective_pattern.len;
        const branch = effective_pattern[branch_start..branch_end];
        if (branchColumn(line, branch, effective_case_insensitive)) |candidate| {
            if (best == null or candidate < best.?) best = candidate;
        }
        if (branch_end == effective_pattern.len) break;
        branch_start = branch_end + 1;
    }
    return best;
}

/// Counts non-overlapping regex matches in a line.
/// After each match, the cursor advances to match.end (or start+1 for
/// zero-width matches) to prevent infinite loops on patterns like `\b`.
pub fn count(line: []const u8, pattern: []const u8, case_insensitive: bool) usize {
    const effective_case_insensitive = case_insensitive or std.mem.startsWith(u8, pattern, "(?i)");
    const effective_pattern = if (std.mem.startsWith(u8, pattern, "(?i)")) pattern[4..] else pattern;
    var total: usize = 0;
    var start: usize = 0;
    while (start <= line.len) {
        const matched = earliestMatch(line, effective_pattern, start, effective_case_insensitive) orelse break;
        total += 1;
        // Advance past the match. For zero-width matches (e.g. \b at a
        // boundary), advance by 1 to avoid an infinite loop at the same pos.
        start = if (matched.end > matched.start) matched.end else matched.start + 1;
    }
    return total;
}

const MatchSpan = struct {
    start: usize,
    end: usize,
};

fn earliestMatch(line: []const u8, pattern: []const u8, start: usize, case_insensitive: bool) ?MatchSpan {
    var best: ?MatchSpan = null;
    var branch_start: usize = 0;
    while (branch_start <= pattern.len) {
        const branch_end = findTopLevelAlternation(pattern, branch_start) orelse pattern.len;
        const branch = pattern[branch_start..branch_end];
        if (branchMatch(line, branch, start, case_insensitive)) |candidate| {
            if (best == null or candidate.start < best.?.start or (candidate.start == best.?.start and candidate.end < best.?.end)) {
                best = candidate;
            }
        }
        if (branch_end == pattern.len) break;
        branch_start = branch_end + 1;
    }
    return best;
}

fn branchMatch(line: []const u8, pattern: []const u8, start: usize, case_insensitive: bool) ?MatchSpan {
    var cursor: usize = start;
    while (cursor <= line.len) : (cursor += 1) {
        if (matchPatternEnd(pattern, 0, line, cursor, case_insensitive)) |end| return .{ .start = cursor, .end = end };
    }
    return null;
}

fn branchColumn(line: []const u8, pattern: []const u8, case_insensitive: bool) ?usize {
    var start: usize = 0;
    while (start <= line.len) : (start += 1) {
        if (matchPatternEnd(pattern, 0, line, start, case_insensitive) != null) return start + 1;
    }
    return null;
}

/// Recursive pattern matcher — attempts to match the pattern starting at
/// pattern_index against the line starting at cursor. Returns the end
/// position of the match if successful, null otherwise.
///
/// This is a classic recursive descent approach. Each call processes one
/// token and recurses for the rest. Quantifiers (?, *, +, {N}) consume
/// multiple characters before recursing. Groups recurse into each
/// alternation branch via matchGroupThenRest.
///
/// WHY RECURSIVE AND NOT NFA:
/// The IX operator set produces simple, short patterns (typically <30
/// tokens). Recursive backtracking is fast enough for these and avoids
/// the complexity of NFA state management. Pathological exponential
/// patterns (e.g., (a*)* ) are not in the IX expression grammar.
fn matchPatternEnd(pattern: []const u8, pattern_index: usize, line: []const u8, cursor: usize, case_insensitive: bool) ?usize {
    if (pattern_index >= pattern.len) return cursor;
    if (cursor > line.len) return null;

    const token = parseToken(pattern, pattern_index) orelse return null;
    if (token.kind == .group) {
        const close = matchingGroupEnd(pattern, pattern_index) orelse return null;
        return matchGroupThenRest(pattern[pattern_index + 1 .. close], pattern[close + 1 ..], line, cursor, case_insensitive);
    }
    if (token.kind == .word_boundary) {
        if (!isWordBoundary(line, cursor)) return null;
        return matchPatternEnd(pattern, token.next_index, line, cursor, case_insensitive);
    }
    if (token.kind == .line_start) {
        if (cursor != 0) return null;
        return matchPatternEnd(pattern, token.next_index, line, cursor, case_insensitive);
    }
    if (token.kind == .line_end) {
        if (cursor != line.len) return null;
        return matchPatternEnd(pattern, token.next_index, line, cursor, case_insensitive);
    }
    // OPTIONAL (?) — match 0 or 1 times. Tries consuming one character
    // first (greedy), falls back to matching zero characters.
    if (token.next_index < pattern.len and pattern[token.next_index] == '?') {
        if (cursor < line.len and tokenMatches(token, line[cursor], case_insensitive)) {
            if (matchPatternEnd(pattern, token.next_index + 1, line, cursor + 1, case_insensitive)) |end| return end;
        }
        return matchPatternEnd(pattern, token.next_index + 1, line, cursor, case_insensitive);
    }
    // STAR (*) — match 0 or more times, greedy with backtracking.
    // First consumes as many matching bytes as possible (greedy), then
    // backtracks one position at a time trying to match the rest of the
    // pattern. This ensures the longest possible match is found first.
    if (token.next_index < pattern.len and pattern[token.next_index] == '*') {
        var next_cursor = cursor;
        while (next_cursor < line.len and tokenMatches(token, line[next_cursor], case_insensitive)) : (next_cursor += 1) {}
        // Backtrack from the greedy maximum toward the minimum (cursor).
        while (next_cursor >= cursor) : (next_cursor -= 1) {
            if (matchPatternEnd(pattern, token.next_index + 1, line, next_cursor, case_insensitive)) |end| return end;
            if (next_cursor == 0) break;
        }
        return null;
    }
    // PLUS (+) — match 1 or more times. Like * but requires at least one
    // match. Uses eager (non-greedy) matching: tries the shortest match
    // first, extending forward if the rest of the pattern fails.
    if (token.next_index < pattern.len and pattern[token.next_index] == '+') {
        if (cursor >= line.len or !tokenMatches(token, line[cursor], case_insensitive)) return null;
        var next_cursor = cursor + 1;
        while (true) {
            if (matchPatternEnd(pattern, token.next_index + 1, line, next_cursor, case_insensitive)) |end| return end;
            if (next_cursor >= line.len or !tokenMatches(token, line[next_cursor], case_insensitive)) break;
            next_cursor += 1;
        }
        return null;
    }

    // EXACT REPETITION {N} — match exactly N times. If no {N} quantifier
    // follows the token, defaults to exactly 1 match (bare token).
    const repeat_count = exactRepeatCount(pattern, token.next_index) orelse 1;
    const repeat_end = if (repeat_count == 1) token.next_index else repeatTokenEnd(pattern, token.next_index);
    var next_cursor = cursor;
    var remaining = repeat_count;
    while (remaining > 0) : (remaining -= 1) {
        if (next_cursor >= line.len or !tokenMatches(token, line[next_cursor], case_insensitive)) return null;
        next_cursor += 1;
    }
    return matchPatternEnd(pattern, repeat_end, line, next_cursor, case_insensitive);
}

/// Matches a parenthesized group with alternation, then the rest of the pattern.
///
/// For `(alpha|beta)suffix`, this splits the group into branches ["alpha", "beta"],
/// tries matching each branch at the cursor, and if one succeeds, tries matching
/// `suffix` starting at where the branch ended. The key insight is that the
/// group's end position feeds into the rest pattern's start — this is what makes
/// `(session|handshake)\b` work correctly: the word boundary check happens at
/// the exact byte after "session" or "handshake" ends.
fn matchGroupThenRest(group: []const u8, rest: []const u8, line: []const u8, cursor: usize, case_insensitive: bool) ?usize {
    var branch_start: usize = 0;
    while (branch_start <= group.len) {
        const branch_end = findTopLevelAlternation(group, branch_start) orelse group.len;
        const branch = group[branch_start..branch_end];
        if (matchPatternEnd(branch, 0, line, cursor, case_insensitive)) |group_end| {
            if (matchPatternEnd(rest, 0, line, group_end, case_insensitive)) |end| return end;
        }
        if (branch_end == group.len) break;
        branch_start = branch_end + 1;
    }
    return null;
}

const TokenKind = enum {
    literal,
    any,
    word,
    digit,
    whitespace,
    word_boundary,
    line_start,
    line_end,
    class,
    negated_class,
    group,
};

const Token = struct {
    kind: TokenKind,
    literal: u8,
    next_index: usize,
    class: []const u8 = "",
};

fn parseToken(pattern: []const u8, index: usize) ?Token {
    if (index >= pattern.len) return null;
    const byte = pattern[index];
    if (byte == '(') return .{ .kind = .group, .literal = 0, .next_index = index + 1 };
    if (byte == '.') return .{ .kind = .any, .literal = 0, .next_index = index + 1 };
    if (byte == '^') return .{ .kind = .line_start, .literal = 0, .next_index = index + 1 };
    if (byte == '$') return .{ .kind = .line_end, .literal = 0, .next_index = index + 1 };
    if (byte == '[') {
        const close = findClassEnd(pattern, index) orelse return null;
        const body_start = index + 1;
        const negated = body_start < close and pattern[body_start] == '^';
        return .{
            .kind = if (negated) .negated_class else .class,
            .literal = 0,
            .next_index = close + 1,
            .class = pattern[(if (negated) body_start + 1 else body_start)..close],
        };
    }
    if (byte == '\\') {
        if (index + 1 >= pattern.len) return null;
        const escaped = pattern[index + 1];
        return switch (escaped) {
            'b' => .{ .kind = .word_boundary, .literal = 0, .next_index = index + 2 },
            'w' => .{ .kind = .word, .literal = 0, .next_index = index + 2 },
            'd' => .{ .kind = .digit, .literal = 0, .next_index = index + 2 },
            's' => .{ .kind = .whitespace, .literal = 0, .next_index = index + 2 },
            'x' => parseHexByte(pattern, index),
            else => .{ .kind = .literal, .literal = escaped, .next_index = index + 2 },
        };
    }
    return .{ .kind = .literal, .literal = byte, .next_index = index + 1 };
}

fn parseHexByte(pattern: []const u8, index: usize) ?Token {
    if (index + 3 >= pattern.len) return null;
    const value = std.fmt.parseInt(u8, pattern[index + 2 .. index + 4], 16) catch return null;
    return .{ .kind = .literal, .literal = value, .next_index = index + 4 };
}

fn tokenMatches(token: Token, byte: u8, case_insensitive: bool) bool {
    return switch (token.kind) {
        .literal => byteEquals(byte, token.literal, case_insensitive),
        .any => true,
        .word => isWordByte(byte),
        .digit => std.ascii.isDigit(byte),
        .whitespace => byte == ' ' or byte == '\t' or byte == '\r' or byte == '\n',
        .class => classMatches(token.class, byte, case_insensitive),
        .negated_class => !classMatches(token.class, byte, case_insensitive),
        else => false,
    };
}

fn findClassEnd(pattern: []const u8, start: usize) ?usize {
    var index = start + 1;
    while (index < pattern.len) : (index += 1) {
        if (pattern[index] == '\\') {
            index += 1;
            continue;
        }
        if (pattern[index] == ']') return index;
    }
    return null;
}

fn classMatches(class: []const u8, byte: u8, case_insensitive: bool) bool {
    var index: usize = 0;
    while (index < class.len) : (index += 1) {
        const first = if (class[index] == '\\' and index + 1 < class.len) escapedClassByte(class[index + 1]) else class[index];
        if (class[index] == '\\' and index + 1 < class.len) index += 1;
        if (index + 2 < class.len and class[index + 1] == '-') {
            const last = class[index + 2];
            if (byteInRange(byte, first, last, case_insensitive)) return true;
            index += 2;
            continue;
        }
        if (byteEquals(byte, first, case_insensitive)) return true;
    }
    return false;
}

fn escapedClassByte(byte: u8) u8 {
    return switch (byte) {
        't' => '\t',
        'r' => '\r',
        'n' => '\n',
        else => byte,
    };
}

fn byteInRange(byte: u8, first: u8, last: u8, case_insensitive: bool) bool {
    const value = if (case_insensitive) std.ascii.toLower(byte) else byte;
    const start = if (case_insensitive) std.ascii.toLower(first) else first;
    const end = if (case_insensitive) std.ascii.toLower(last) else last;
    return value >= start and value <= end;
}

fn exactRepeatCount(pattern: []const u8, index: usize) ?usize {
    if (index >= pattern.len or pattern[index] != '{') return null;
    const close = std.mem.indexOfScalarPos(u8, pattern, index + 1, '}') orelse return null;
    return std.fmt.parseInt(usize, pattern[index + 1 .. close], 10) catch null;
}

fn repeatTokenEnd(pattern: []const u8, index: usize) usize {
    if (index >= pattern.len or pattern[index] != '{') return index;
    const close = std.mem.indexOfScalarPos(u8, pattern, index + 1, '}') orelse return index;
    return close + 1;
}

/// Finds the next top-level `|` alternation operator, skipping over nested
/// groups. This ensures that `(a|b)|c` correctly finds the `|` between
/// `)` and `c`, not the `|` inside the parentheses. Escaped pipes (`\|`)
/// are also skipped.
fn findTopLevelAlternation(pattern: []const u8, start: usize) ?usize {
    var depth: usize = 0;
    var index = start;
    while (index < pattern.len) : (index += 1) {
        const byte = pattern[index];
        if (byte == '\\') {
            index += 1;
            continue;
        }
        if (byte == '(') depth += 1 else if (byte == ')') {
            if (depth > 0) depth -= 1;
        } else if (byte == '|' and depth == 0) return index;
    }
    return null;
}

fn matchingGroupEnd(pattern: []const u8, start: usize) ?usize {
    var depth: usize = 0;
    var index = start;
    while (index < pattern.len) : (index += 1) {
        const byte = pattern[index];
        if (byte == '\\') {
            index += 1;
            continue;
        }
        if (byte == '(') depth += 1 else if (byte == ')') {
            depth -= 1;
            if (depth == 0) return index;
        }
    }
    return null;
}

/// Word boundary (\b) — true at a transition between word and non-word bytes.
/// A word byte is [a-zA-Z0-9_]. The boundary exists at position 0 if the
/// first byte is a word byte, at position len if the last byte is a word byte,
/// and at any position where the left and right byte differ in word-ness.
/// This matches the PCRE/Rust regex definition of \b.
fn isWordBoundary(line: []const u8, cursor: usize) bool {
    const left = if (cursor == 0) false else isWordByte(line[cursor - 1]);
    const right = if (cursor >= line.len) false else isWordByte(line[cursor]);
    return left != right;
}

fn isWordByte(byte: u8) bool {
    return std.ascii.isAlphanumeric(byte) or byte == '_';
}

fn byteEquals(left: u8, right: u8, case_insensitive: bool) bool {
    if (!case_insensitive) return left == right;
    return std.ascii.toLower(left) == std.ascii.toLower(right);
}

test "regex column carries group consumption before suffix" {
    try std.testing.expectEqual(@as(?usize, 1), column("group suffix", "(group|prefix) suffix", false));
    try std.testing.expectEqual(@as(?usize, null), column("group other", "(group|prefix) suffix", false));
}

test "regex column supports classes and repetition" {
    try std.testing.expectEqual(@as(?usize, 1), column("ERR42: color", "[A-Z]+\\d+: colo?r", false));
    try std.testing.expectEqual(@as(?usize, 1), column("ERR42: colr", "[A-Z]+\\d+: colo?r", false));
    try std.testing.expectEqual(@as(?usize, 7), column("INFO: colouur", "colou*r", false));
}
