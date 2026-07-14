const std = @import("std");
const sz = @import("sz.zig");

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
    const matched = span(line, pattern, case_insensitive) orelse return null;
    return matched.start + 1;
}

/// Returns the exact byte span of the first native-regex match.
pub fn span(line: []const u8, pattern: []const u8, case_insensitive: bool) ?MatchSpan {
    // (?i) prefix triggers case-insensitive mode regardless of the flag.
    // This matches Rust's regex crate behavior for inline mode modifiers.
    const effective_case_insensitive = case_insensitive or std.mem.startsWith(u8, pattern, "(?i)");
    const effective_pattern = if (std.mem.startsWith(u8, pattern, "(?i)")) pattern[4..] else pattern;
    return earliestMatch(line, effective_pattern, 0, effective_case_insensitive);
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

pub const MatchSpan = struct {
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

/// Extracts the set of byte values that can start a match for a pattern.
/// Returns null if the first token matches any byte (`.`, `[^...]` covering
/// all values, etc.) — in that case SIMD skip provides no benefit.
fn extractStartSet(pattern: []const u8, case_insensitive: bool) ?sz.ByteSet {
    const token = parseToken(pattern, 0) orelse return null;
    var set = sz.ByteSet{};
    switch (token.kind) {
        .literal => {
            set.add(token.literal);
            if (case_insensitive) {
                set.add(std.ascii.toUpper(token.literal));
                set.add(std.ascii.toLower(token.literal));
            }
        },
        .word => {
            for (0..256) |i| {
                if (CLASS_TABLE[i].word != 0) set.add(@intCast(i));
            }
        },
        .digit => {
            for ('0'..('9' + 1)) |i| set.add(@intCast(i));
        },
        .whitespace => {
            set.add(' ');
            set.add('\t');
            set.add('\r');
            set.add('\n');
        },
        .class => {
            populateClassSet(&set, token.class, case_insensitive);
        },
        // These match too broadly or are zero-width — skip SIMD prefilter.
        .any, .negated_class, .group, .word_boundary, .line_start, .line_end => return null,
    }
    return set;
}

/// Populates a ByteSet from a character class body (e.g., the `a-zA-Z` in `[a-zA-Z]`).
fn populateClassSet(set: *sz.ByteSet, class: []const u8, case_insensitive: bool) void {
    var index: usize = 0;
    while (index < class.len) : (index += 1) {
        const first = if (class[index] == '\\' and index + 1 < class.len) blk: {
            index += 1;
            break :blk escapedClassByte(class[index]);
        } else class[index];
        if (index + 2 < class.len and class[index + 1] == '-') {
            const last = class[index + 2];
            var c: u16 = first;
            while (c <= last) : (c += 1) {
                set.add(@intCast(c));
                if (case_insensitive) {
                    set.add(std.ascii.toUpper(@intCast(c)));
                    set.add(std.ascii.toLower(@intCast(c)));
                }
            }
            index += 2;
            continue;
        }
        set.add(first);
        if (case_insensitive) {
            set.add(std.ascii.toUpper(first));
            set.add(std.ascii.toLower(first));
        }
    }
}

fn branchMatch(line: []const u8, pattern: []const u8, start: usize, case_insensitive: bool) ?MatchSpan {
    // Visited set shared across starting cursors: matchPatternEnd is a pure
    // function of (pattern, pattern_index, line, cursor, case_insensitive),
    // so a memoized failure at (pat_pos, cursor) is valid regardless of
    // which outer starting position triggered the exploration.
    var visited = VisitedSet.init(pattern, line);
    const start_set = extractStartSet(pattern, case_insensitive);
    var cursor: usize = start;
    while (cursor <= line.len) {
        if (matchPatternEnd(pattern, 0, line, cursor, case_insensitive, &visited)) |end| return .{ .start = cursor, .end = end };
        // SIMD skip: jump to the next byte that could start a match.
        if (start_set) |*ss| {
            if (cursor + 1 < line.len) {
                cursor = if (sz.indexOfByteSet(line[cursor + 1 ..], ss)) |offset| cursor + 1 + offset else return null;
            } else {
                cursor += 1;
            }
        } else {
            cursor += 1;
        }
    }
    return null;
}

fn branchColumn(line: []const u8, pattern: []const u8, case_insensitive: bool) ?usize {
    var visited = VisitedSet.init(pattern, line);
    const start_set = extractStartSet(pattern, case_insensitive);
    var start: usize = 0;
    while (start <= line.len) {
        if (matchPatternEnd(pattern, 0, line, start, case_insensitive, &visited) != null) return start + 1;
        if (start_set) |*ss| {
            if (start + 1 < line.len) {
                start = if (sz.indexOfByteSet(line[start + 1 ..], ss)) |offset| start + 1 + offset else return null;
            } else {
                start += 1;
            }
        } else {
            start += 1;
        }
    }
    return null;
}

/// Visited-state bitset for bounded backtracking. Prevents exponential
/// blow-up on pathological patterns (e.g., `a*a*a*a*b` vs `aaaa`) by
/// memoizing failed (pattern_offset, cursor) pairs. If the key space
/// exceeds the stack budget, the check degrades to a no-op — correctness
/// is preserved, only the exponential bound is lost.
const VisitedSet = struct {
    const MAX_BITS = 64 * 1024; // 8 KiB bitset
    const WORDS = MAX_BITS / 64;

    bits: [WORDS]u64,
    pattern_base: [*]const u8,
    stride: usize, // line.len + 1
    active: bool,

    fn init(pattern: []const u8, line: []const u8) VisitedSet {
        const stride = line.len + 1;
        const total = pattern.len * stride;
        if (total > MAX_BITS) {
            return .{ .bits = undefined, .pattern_base = pattern.ptr, .stride = stride, .active = false };
        }
        return .{ .bits = @splat(0), .pattern_base = pattern.ptr, .stride = stride, .active = true };
    }

    /// Returns true if this (pattern_pos, cursor) was already visited (=> known failure).
    /// Sets the bit and returns false on first visit.
    fn checkAndSet(self: *VisitedSet, pattern_ptr: [*]const u8, pattern_index: usize, cursor: usize) bool {
        if (!self.active) return false;
        const pat_offset = @intFromPtr(pattern_ptr) -% @intFromPtr(self.pattern_base);
        const key = (pat_offset + pattern_index) * self.stride + cursor;
        if (key >= MAX_BITS) return false; // out of budget — skip
        const word = key / 64;
        const bit: u6 = @intCast(key % 64);
        const mask: u64 = @as(u64, 1) << bit;
        if (self.bits[word] & mask != 0) return true;
        self.bits[word] |= mask;
        return false;
    }
};

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
fn matchPatternEnd(pattern: []const u8, pattern_index: usize, line: []const u8, cursor: usize, case_insensitive: bool, visited: *VisitedSet) ?usize {
    if (pattern_index >= pattern.len) return cursor;
    if (cursor > line.len) return null;

    // Visited-bitset pruning: if we already explored this (pattern_pos, cursor)
    // and it failed, skip immediately. This bounds worst-case to O(P × L).
    if (visited.checkAndSet(pattern.ptr, pattern_index, cursor)) return null;

    const token = parseToken(pattern, pattern_index) orelse return null;
    if (token.kind == .group) {
        const close = matchingGroupEnd(pattern, pattern_index) orelse return null;
        return matchGroupThenRest(pattern[pattern_index + 1 .. close], pattern[close + 1 ..], line, cursor, case_insensitive, visited);
    }
    if (token.kind == .word_boundary) {
        if (!isWordBoundary(line, cursor)) return null;
        return matchPatternEnd(pattern, token.next_index, line, cursor, case_insensitive, visited);
    }
    if (token.kind == .line_start) {
        if (cursor != 0) return null;
        return matchPatternEnd(pattern, token.next_index, line, cursor, case_insensitive, visited);
    }
    if (token.kind == .line_end) {
        if (cursor != line.len) return null;
        return matchPatternEnd(pattern, token.next_index, line, cursor, case_insensitive, visited);
    }
    // OPTIONAL (?) — match 0 or 1 times. Tries consuming one character
    // first (greedy), falls back to matching zero characters.
    if (token.next_index < pattern.len and pattern[token.next_index] == '?') {
        if (cursor < line.len and tokenMatches(token, line[cursor], case_insensitive)) {
            if (matchPatternEnd(pattern, token.next_index + 1, line, cursor + 1, case_insensitive, visited)) |end| return end;
        }
        return matchPatternEnd(pattern, token.next_index + 1, line, cursor, case_insensitive, visited);
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
            if (matchPatternEnd(pattern, token.next_index + 1, line, next_cursor, case_insensitive, visited)) |end| return end;
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
            if (matchPatternEnd(pattern, token.next_index + 1, line, next_cursor, case_insensitive, visited)) |end| return end;
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
    return matchPatternEnd(pattern, repeat_end, line, next_cursor, case_insensitive, visited);
}

/// Matches a parenthesized group with alternation, then the rest of the pattern.
///
/// For `(alpha|beta)suffix`, this splits the group into branches ["alpha", "beta"],
/// tries matching each branch at the cursor, and if one succeeds, tries matching
/// `suffix` starting at where the branch ended. The key insight is that the
/// group's end position feeds into the rest pattern's start — this is what makes
/// `(session|handshake)\b` work correctly: the word boundary check happens at
/// the exact byte after "session" or "handshake" ends.
fn matchGroupThenRest(group: []const u8, rest: []const u8, line: []const u8, cursor: usize, case_insensitive: bool, visited: *VisitedSet) ?usize {
    var branch_start: usize = 0;
    while (branch_start <= group.len) {
        const branch_end = findTopLevelAlternation(group, branch_start) orelse group.len;
        const branch = group[branch_start..branch_end];
        if (matchPatternEnd(branch, 0, line, cursor, case_insensitive, visited)) |group_end| {
            if (matchPatternEnd(rest, 0, line, group_end, case_insensitive, visited)) |end| return end;
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

/// Comptime-generated 256-byte classification table. Single indexed load
/// replaces branch cascade in the hot path. Bit layout:
///   bit 0: word      [a-zA-Z0-9_]
///   bit 1: digit     [0-9]
///   bit 2: whitespace [ \t\r\n]
const CharClass = packed struct {
    word: u1 = 0,
    digit: u1 = 0,
    whitespace: u1 = 0,
    _pad: u5 = 0,
};

const CLASS_TABLE: [256]CharClass = blk: {
    var table: [256]CharClass = @splat(CharClass{});
    for (0..256) |i| {
        const c: u8 = @intCast(i);
        if ((c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or
            (c >= '0' and c <= '9') or c == '_')
        {
            table[i].word = 1;
        }
        if (c >= '0' and c <= '9') {
            table[i].digit = 1;
        }
        if (c == ' ' or c == '\t' or c == '\r' or c == '\n') {
            table[i].whitespace = 1;
        }
    }
    break :blk table;
};

fn tokenMatches(token: Token, byte: u8, case_insensitive: bool) bool {
    return switch (token.kind) {
        .literal => byteEquals(byte, token.literal, case_insensitive),
        .any => true,
        .word => CLASS_TABLE[byte].word != 0,
        .digit => CLASS_TABLE[byte].digit != 0,
        .whitespace => CLASS_TABLE[byte].whitespace != 0,
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
    return CLASS_TABLE[byte].word != 0;
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

// ── P14: Thompson NFA Construction and O(pm) Simulation ────────────
//
// The Thompson construction builds an NFA from a regex pattern using
// epsilon transitions. The simulation uses the classic two-list approach
// (current active states + next active states) that runs in O(pm) time
// — p = number of NFA states, m = text length — with NO catastrophic
// backtracking. This is the Russ Cox RE2 execution model.
//
// The NFA is built from the same AST the recursive backtracker uses,
// but the execution is forward-only: no backtracking, no visited-set,
// no exponential blowup. For patterns that cause catastrophic backtracking
// in the recursive engine (e.g., (a+)+b against aaaaa...), the Thompson
// NFA runs in linear time.

const MAX_NFA_STATES: usize = 512;

/// State kind: epsilon (no char), character, character class, any, or accept.
const StateKind = enum(u8) { epsilon, char, class, any, accept };

const NFAState = struct {
    kind: StateKind = .epsilon,
    /// Character to match (for kind == .char).
    char: u8 = 0,
    /// Character class bitmap (for kind == .class). Bit i = 1 means byte i matches.
    class: [32]u8 = [_]u8{0} ** 32,
    /// Next state on match (0 = none, states are 1-indexed).
    next1: u16 = 0,
    /// Epsilon transition target (0 = none). Used for split states.
    next2: u16 = 0,
};

/// A compiled Thompson NFA. Supports alternation, quantifiers, character classes.
pub const ThompsonNFA = struct {
    states: [MAX_NFA_STATES]NFAState = [_]NFAState{.{}} ** MAX_NFA_STATES,
    state_count: usize = 0,
    start_state: u16 = 0,

    /// Simulate the NFA against input text. O(pm) — no backtracking.
    pub fn simulate(self: *const ThompsonNFA, text: []const u8) ?usize {
        if (self.state_count == 0) return null;

        var current_list: [MAX_NFA_STATES]u16 = undefined;
        var current_len: usize = 0;
        var next_list: [MAX_NFA_STATES]u16 = undefined;
        var next_len: usize = 0;
        var visited: [MAX_NFA_STATES]bool = [_]bool{false} ** MAX_NFA_STATES;

        current_len = epsilonClosure(self, self.start_state, &current_list, current_len, &visited);

        for (current_list[0..current_len]) |s| {
            if (self.states[s].kind == .accept) return 1;
        }

        for (text, 0..) |byte, i| {
            @memset(visited[0..self.state_count], false);
            next_len = 0;

            for (current_list[0..current_len]) |s| {
                const state = self.states[s];
                const matches = switch (state.kind) {
                    .char => state.char == byte,
                    .any => byte != '\n',
                    .class => (state.class[byte >> 3] & (@as(u8, 1) << @intCast(byte & 7))) != 0,
                    else => false,
                };
                if (matches) {
                    next_len = epsilonClosure(self, state.next1, &next_list, next_len, &visited);
                }
            }

            current_len = next_len;
            @memcpy(current_list[0..current_len], next_list[0..current_len]);

            for (current_list[0..current_len]) |s| {
                if (self.states[s].kind == .accept) return @intCast(i + 1);
            }

            if (current_len == 0) {
                @memset(visited[0..self.state_count], false);
                current_len = epsilonClosure(self, self.start_state, &current_list, current_len, &visited);
            }
        }

        return null;
    }

    pub fn stateCount(self: *const ThompsonNFA) usize {
        return self.state_count;
    }
};

fn epsilonClosure(nfa: *const ThompsonNFA, start: u16, list: *[MAX_NFA_STATES]u16, len: usize, visited: *[MAX_NFA_STATES]bool) usize {
    if (start == 0 or start > nfa.state_count) return len;
    if (visited[start]) return len;
    visited[start] = true;
    var pos = len;
    const state = nfa.states[start];
    if (state.kind == .epsilon) {
        pos = epsilonClosure(nfa, state.next1, list, pos, visited);
        pos = epsilonClosure(nfa, state.next2, list, pos, visited);
    } else {
        list[pos] = start;
        pos += 1;
    }
    return pos;
}

// ── Thompson Construction Compiler ─────────────────────────────────
//
// Recursive-descent compiler that parses regex syntax and builds NFA
// fragments using Thompson's construction:
//
// alternation: A|B  → split → A → join, split → B → join
// concatenation: AB → A.out → B.start
// star: A*   → split → A → split (loop), split → out
// plus: A+   → A → split → A (loop), split → out
// optional: A? → split → A → out, split → out
// {N}: A{3}  → AAA
// [a-z]:     → character class state with bitmap

const Fragment = struct {
    start: u16,
    out: u16, // state index whose next1 is the dangling edge to patch
};

const NfaBuilder = struct {
    nfa: ThompsonNFA = .{},
    pos: usize = 0,
    pattern: []const u8 = "",

    fn newState(self: *NfaBuilder) u16 {
        if (self.nfa.state_count >= MAX_NFA_STATES) return 0;
        const idx = self.nfa.state_count;
        self.nfa.state_count += 1;
        self.nfa.states[idx] = .{};
        return @intCast(idx);
    }

    fn patch(self: *NfaBuilder, state_idx: u16, target: u16) void {
        if (state_idx == 0) return;
        if (self.nfa.states[state_idx].next1 == 0) {
            self.nfa.states[state_idx].next1 = target;
        } else {
            self.nfa.states[state_idx].next2 = target;
        }
    }

    fn charState(self: *NfaBuilder, c: u8) Fragment {
        const s = self.newState();
        self.nfa.states[s] = .{ .kind = .char, .char = c };
        return .{ .start = s, .out = s };
    }

    fn anyState(self: *NfaBuilder) Fragment {
        const s = self.newState();
        self.nfa.states[s] = .{ .kind = .any };
        return .{ .start = s, .out = s };
    }

    fn classState(self: *NfaBuilder, bitmap: [32]u8) Fragment {
        const s = self.newState();
        self.nfa.states[s] = .{ .kind = .class, .class = bitmap };
        return .{ .start = s, .out = s };
    }

    /// Parse alternation: expr ('|' expr)*
    fn parseAlternation(self: *NfaBuilder) ?Fragment {
        var left = self.parseConcat() orelse return null;
        while (self.pos < self.pattern.len and self.pattern[self.pos] == '|') {
            self.pos += 1;
            const right = self.parseConcat() orelse return left;
            // split state: epsilon to left.start and right.start
            const split = self.newState();
            self.nfa.states[split].kind = .epsilon;
            self.nfa.states[split].next1 = left.start;
            self.nfa.states[split].next2 = right.start;
            // join state: epsilon, both fragments point to it
            const join = self.newState();
            self.nfa.states[join].kind = .epsilon;
            self.patch(left.out, join);
            self.patch(right.out, join);
            left = .{ .start = split, .out = join };
        }
        return left;
    }

    /// Parse concatenation: quantified*
    fn parseConcat(self: *NfaBuilder) ?Fragment {
        if (self.pos >= self.pattern.len) return null;
        var first: ?Fragment = null;
        while (self.pos < self.pattern.len) {
            const c = self.pattern[self.pos];
            if (c == '|' or c == ')') break;
            const frag = self.parseQuantified() orelse break;
            if (first) |*f| {
                self.patch(f.out, frag.start);
                f.out = frag.out;
            } else {
                first = frag;
            }
        }
        return first;
    }

    /// Parse quantified: atom ('*' | '+' | '?' | '{N}')*
    fn parseQuantified(self: *NfaBuilder) ?Fragment {
        const atom_start_pos = self.pos;
        var atom = self.parseAtom() orelse return null;
        while (self.pos < self.pattern.len) {
            const c = self.pattern[self.pos];
            switch (c) {
                '*' => {
                    self.pos += 1;
                    const split = self.newState();
                    self.nfa.states[split].kind = .epsilon;
                    self.nfa.states[split].next1 = atom.start;
                    self.patch(atom.out, split);
                    atom = .{ .start = split, .out = split };
                },
                '+' => {
                    self.pos += 1;
                    const split = self.newState();
                    self.nfa.states[split].kind = .epsilon;
                    self.nfa.states[split].next1 = atom.start;
                    self.patch(atom.out, split);
                    atom = .{ .start = atom.start, .out = split };
                },
                '?' => {
                    self.pos += 1;
                    // split: epsilon to atom.start, second edge skips atom
                    const split = self.newState();
                    self.nfa.states[split].kind = .epsilon;
                    self.nfa.states[split].next1 = atom.start;
                    // The split's next2 is the skip path — patched by concat.
                    atom = .{ .start = split, .out = split };
                    // Patch atom's original out to point to split (dangling).
                    // The concat linker will patch split's second edge.
                    // Actually: the fragment's out is split, whose next1 is
                    // already set. The next2 is dangling — concat will patch it.
                },
                '{' => {
                    self.pos += 1;
                    var rep_count: u32 = 0;
                    while (self.pos < self.pattern.len and std.ascii.isDigit(self.pattern[self.pos])) : (self.pos += 1) {
                        rep_count = rep_count * 10 + (self.pattern[self.pos] - '0');
                    }
                    if (self.pos < self.pattern.len and self.pattern[self.pos] == '}') self.pos += 1;
                    // Expand {N} as N repetitions.
                    var result = atom;
                    var k: u32 = 1;
                    while (k < rep_count) : (k += 1) {
                        // Save/restore position to re-parse the same atom.
                        const saved_pos = self.pos;
                        self.pos = atom_start_pos;
                        const copy = self.parseAtom() orelse {
                            self.pos = saved_pos;
                            break;
                        };
                        self.patch(result.out, copy.start);
                        result = .{ .start = result.start, .out = copy.out };
                    }
                    atom = result;
                },
                else => break,
            }
        }
        return atom;
    }

    /// Parse atom: literal | '.' | '\d' | '\w' | '\s' | [class] | (group)
    fn parseAtom(self: *NfaBuilder) ?Fragment {
        if (self.pos >= self.pattern.len) return null;
        const c = self.pattern[self.pos];
        switch (c) {
            '(' => {
                self.pos += 1;
                const inner = self.parseAlternation() orelse return null;
                if (self.pos < self.pattern.len and self.pattern[self.pos] == ')') self.pos += 1;
                return inner;
            },
            '.' => {
                self.pos += 1;
                return self.anyState();
            },
            '[' => {
                self.pos += 1;
                return self.parseClass();
            },
            '\\' => {
                self.pos += 1;
                if (self.pos >= self.pattern.len) return null;
                const esc = self.pattern[self.pos];
                self.pos += 1;
                return self.escapeState(esc);
            },
            else => {
                self.pos += 1;
                return self.charState(c);
            },
        }
    }

    fn parseClass(self: *NfaBuilder) ?Fragment {
        var bitmap = [_]u8{0} ** 32;
        var negate = false;
        if (self.pos < self.pattern.len and self.pattern[self.pos] == '^') {
            negate = true;
            self.pos += 1;
        }
        while (self.pos < self.pattern.len and self.pattern[self.pos] != ']') {
            const lo = self.pattern[self.pos];
            self.pos += 1;
            if (self.pos + 1 < self.pattern.len and self.pattern[self.pos] == '-' and self.pattern[self.pos + 1] != ']') {
                self.pos += 1; // skip '-'
                const hi = self.pattern[self.pos];
                self.pos += 1;
                var ch = lo;
                while (ch <= hi) : (ch += 1) {
                    bitmap[ch >> 3] |= @as(u8, 1) << @intCast(ch & 7);
                }
            } else {
                bitmap[lo >> 3] |= @as(u8, 1) << @intCast(lo & 7);
            }
        }
        if (self.pos < self.pattern.len and self.pattern[self.pos] == ']') self.pos += 1;
        if (negate) {
            for (&bitmap) |*b| b.* = ~b.*;
        }
        return self.classState(bitmap);
    }

    fn escapeState(self: *NfaBuilder, esc: u8) ?Fragment {
        switch (esc) {
            'd' => {
                var bm = [_]u8{0} ** 32;
                var ch: u8 = '0';
                while (ch <= '9') : (ch += 1) bm[ch >> 3] |= @as(u8, 1) << @intCast(ch & 7);
                return self.classState(bm);
            },
            'w' => {
                var bm = [_]u8{0} ** 32;
                var ch: u8 = 'a';
                while (ch <= 'z') : (ch += 1) bm[ch >> 3] |= @as(u8, 1) << @intCast(ch & 7);
                ch = 'A';
                while (ch <= 'Z') : (ch += 1) bm[ch >> 3] |= @as(u8, 1) << @intCast(ch & 7);
                ch = '0';
                while (ch <= '9') : (ch += 1) bm[ch >> 3] |= @as(u8, 1) << @intCast(ch & 7);
                bm['_' >> 3] |= @as(u8, 1) << @intCast('_' & 7);
                return self.classState(bm);
            },
            's' => {
                var bm = [_]u8{0} ** 32;
                for ([_]u8{ ' ', '\t', '\n', '\r', 0x0B, 0x0C }) |ch| bm[ch >> 3] |= @as(u8, 1) << @intCast(ch & 7);
                return self.classState(bm);
            },
            'n' => return self.charState('\n'),
            't' => return self.charState('\t'),
            'r' => return self.charState('\r'),
            else => return self.charState(esc),
        }
    }
};

/// Builds a Thompson NFA from a regex pattern supporting:
/// - Literals: abc
/// - Any: .
/// - Alternation: a|b|c
/// - Quantifiers: a*, a+, a?, a{3}
/// - Character classes: [a-z], [^0-9], \d, \w, \s
/// - Groups: (abc|def)
pub fn buildThompsonNFA(pattern: []const u8) ThompsonNFA {
    var builder = NfaBuilder{ .pattern = pattern };
    const root = builder.parseAlternation() orelse return .{};
    // Add accept state.
    const accept = builder.newState();
    builder.nfa.states[accept].kind = .accept;
    builder.patch(root.out, accept);
    builder.nfa.start_state = root.start;
    return builder.nfa;
}

/// P14: Thompson NFA column search. O(pm) — no backtracking.
/// Handles literals, alternation, quantifiers (*, +, ?, {N}),
/// character classes ([a-z], \d, \w, \s), and groups.
/// Falls back to recursive backtracker only for case-insensitive
/// or when the pattern is too complex for the NFA state budget.
pub fn columnNFA(line: []const u8, pattern: []const u8, case_insensitive: bool) ?usize {
    // Case-insensitive still uses the backtracker (the NFA doesn't
    // fold character classes case-insensitively yet).
    if (case_insensitive) return column(line, pattern, case_insensitive);

    // Build and simulate the Thompson NFA.
    const nfa = buildThompsonNFA(pattern);
    if (nfa.state_count == 0) return column(line, pattern, case_insensitive);
    return nfa.simulate(line);
}

test "P14 Thompson NFA matches literal pattern" {
    const nfa = buildThompsonNFA("hello");
    try std.testing.expect(nfa.simulate("hello world") != null);
    try std.testing.expect(nfa.simulate("say hello there") != null);
    try std.testing.expect(nfa.simulate("no match") == null);
}

test "P14 Thompson NFA alternation" {
    const nfa = buildThompsonNFA("cat|dog");
    try std.testing.expect(nfa.simulate("I have a cat") != null);
    try std.testing.expect(nfa.simulate("I have a dog") != null);
    try std.testing.expect(nfa.simulate("I have a bird") == null);
}

test "P14 Thompson NFA quantifiers" {
    // Kleene star: a* matches zero or more 'a'
    const star = buildThompsonNFA("ab*c");
    try std.testing.expect(star.simulate("ac") != null);
    try std.testing.expect(star.simulate("abc") != null);
    try std.testing.expect(star.simulate("abbbbc") != null);

    // Plus: a+ matches one or more
    const plus = buildThompsonNFA("ab+c");
    try std.testing.expect(plus.simulate("abc") != null);
    try std.testing.expect(plus.simulate("abbc") != null);
    try std.testing.expect(plus.simulate("ac") == null);

    // Optional: colou?r
    const opt = buildThompsonNFA("colou?r");
    try std.testing.expect(opt.simulate("color") != null);
    try std.testing.expect(opt.simulate("colour") != null);
}

test "P14 Thompson NFA character classes" {
    // [a-z]+
    const lc = buildThompsonNFA("[a-z]+");
    try std.testing.expect(lc.simulate("hello") != null);
    try std.testing.expect(lc.simulate("HELLO") == null);

    // \d+ — digits
    const digits = buildThompsonNFA("\\d+");
    try std.testing.expect(digits.simulate("12345") != null);
    try std.testing.expect(digits.simulate("abc") == null);

    // \w+ — word chars
    const word = buildThompsonNFA("\\w+");
    try std.testing.expect(word.simulate("hello_world123") != null);
}

test "P14 Thompson NFA O(pm) no catastrophic backtracking" {
    // (a+)+b causes catastrophic backtracking in recursive engines.
    // The Thompson NFA handles it in O(pm) — linear time.
    const nfa = buildThompsonNFA("(a+)+b");
    var buf: [100]u8 = undefined;
    for (&buf, 0..) |*b, i| {
        b.* = if (i < 88) 'a' else if (i == 88) 'b' else 'x';
    }
    const result = nfa.simulate(buf[0..89]);
    try std.testing.expect(result != null);
}

test "P14 Thompson NFA column search matches backtracker for literals" {
    try std.testing.expectEqual(column("find hello here", "hello", false), columnNFA("find hello here", "hello", false));
    try std.testing.expectEqual(column("no match here", "hello", false), columnNFA("no match here", "hello", false));
    try std.testing.expectEqual(@as(?usize, null), columnNFA("", "hello", false));
}

test "P14 Thompson NFA groups with alternation" {
    const nfa = buildThompsonNFA("(cat|dog)s");
    try std.testing.expect(nfa.simulate("cats") != null);
    try std.testing.expect(nfa.simulate("dogs") != null);
    try std.testing.expect(nfa.simulate("birds") == null);
}
