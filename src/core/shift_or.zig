const std = @import("std");

/// Bit-Parallel Shift-Or exact string matching (Baeza-Yates–Gonnet 1992).
///
/// For patterns up to 64 bytes, simulates an NFA in a single u64 register.
/// Each input byte advances the entire pattern state in one ALU cycle:
///   R = ((R << 1) | 1) & M[c]
/// where M[c] is a precomputed 64-bit mask with bit i set iff pattern[i] == c.
/// A match is detected when bit (pattern_len - 1) is set in R.
///
/// For case-insensitive matching, M[c] includes both upper and lower case
/// positions — no separate casefold pass is needed. This eliminates the
/// 2 KiB + 256 B stack buffer allocation that the casefold path requires,
/// avoiding __chkstk page probes on every line.
///
/// Mathematical invariant: R after processing byte j has bit i set iff
/// pattern[0..i+1] matches text[j-i..j+1]. This is exact — zero false
/// positives, zero false negatives.

pub const MAX_PATTERN_LEN: usize = 64;

pub const ShiftOr = struct {
    masks: [256]u64 = [_]u64{0} ** 256,
    pattern_len: usize = 0,
    match_bit: u64 = 0,

    /// Builds the Shift-Or mask table for a pattern.
    /// For case_insensitive=true, each ASCII letter position is set in
    /// both its lowercase and uppercase mask entries.
    pub fn init(pattern: []const u8, case_insensitive: bool) ?ShiftOr {
        if (pattern.len == 0 or pattern.len > MAX_PATTERN_LEN) return null;
        var so = ShiftOr{
            .pattern_len = pattern.len,
            .match_bit = @as(u64, 1) << @intCast(pattern.len - 1),
        };
        for (pattern, 0..) |c, i| {
            const bit = @as(u64, 1) << @intCast(i);
            so.masks[c] |= bit;
            if (case_insensitive) {
                if (c >= 'a' and c <= 'z') {
                    so.masks[c - 32] |= bit;
                } else if (c >= 'A' and c <= 'Z') {
                    so.masks[c + 32] |= bit;
                }
            }
        }
        return so;
    }

    /// Returns the byte offset of the first match, or null.
    pub inline fn indexOf(self: *const ShiftOr, text: []const u8) ?usize {
        var state: u64 = 0;
        for (text, 0..) |c, i| {
            state = ((state << 1) | 1) & self.masks[c];
            if (state & self.match_bit != 0) {
                return i + 1 - self.pattern_len;
            }
        }
        return null;
    }

    /// Counts non-overlapping occurrences.
    pub inline fn count(self: *const ShiftOr, text: []const u8) usize {
        var state: u64 = 0;
        var total: usize = 0;
        var i: usize = 0;
        while (i < text.len) : (i += 1) {
            state = ((state << 1) | 1) & self.masks[text[i]];
            if (state & self.match_bit != 0) {
                total += 1;
                state = 0;
            }
        }
        return total;
    }

    /// Returns true if the text contains at least one match.
    pub inline fn contains(self: *const ShiftOr, text: []const u8) bool {
        var state: u64 = 0;
        for (text) |c| {
            state = ((state << 1) | 1) & self.masks[c];
            if (state & self.match_bit != 0) return true;
        }
        return false;
    }
};

test "shift-or finds exact match case-sensitive" {
    const so = ShiftOr.init("world", false).?;
    try std.testing.expectEqual(@as(?usize, 6), so.indexOf("hello world"));
    try std.testing.expect(so.contains("hello world"));
    try std.testing.expect(!so.contains("hello earth"));
}

test "shift-or finds match at start" {
    const so = ShiftOr.init("hello", false).?;
    try std.testing.expectEqual(@as(?usize, 0), so.indexOf("hello world"));
}

test "shift-or returns null when absent" {
    const so = ShiftOr.init("xyz", false).?;
    try std.testing.expectEqual(@as(?usize, null), so.indexOf("hello world"));
}

test "shift-or case-insensitive matches mixed case" {
    const so = ShiftOr.init("Hello", true).?;
    try std.testing.expectEqual(@as(?usize, 0), so.indexOf("HELLO world"));
    try std.testing.expectEqual(@as(?usize, 0), so.indexOf("hello world"));
    try std.testing.expectEqual(@as(?usize, 0), so.indexOf("HeLLo world"));
    try std.testing.expect(so.contains("say HELLO now"));
    try std.testing.expect(!so.contains("say GOODBYE now"));
}

test "shift-or counts non-overlapping" {
    const so = ShiftOr.init("ab", false).?;
    try std.testing.expectEqual(@as(usize, 3), so.count("ababab"));
    try std.testing.expectEqual(@as(usize, 0), so.count("xyz"));
    try std.testing.expectEqual(@as(usize, 2), so.count("abcab"));
}

test "shift-or single-byte pattern" {
    const so = ShiftOr.init("x", false).?;
    try std.testing.expectEqual(@as(?usize, 1), so.indexOf("axb"));
    try std.testing.expectEqual(@as(usize, 3), so.count("axxxb"));
}

test "shift-or rejects empty pattern" {
    try std.testing.expect(ShiftOr.init("", false) == null);
}

test "shift-or rejects pattern over 64 bytes" {
    const long = "a" ** 65;
    try std.testing.expect(ShiftOr.init(long, false) == null);
}

test "shift-or handles max 64-byte pattern" {
    var pattern: [64]u8 = undefined;
    for (&pattern, 0..) |*c, i| c.* = @intCast('a' + (i % 26));
    const so = ShiftOr.init(&pattern, false).?;
    try std.testing.expectEqual(@as(?usize, 0), so.indexOf(&pattern));
}

test "shift-or case-insensitive count" {
    const so = ShiftOr.init("error", true).?;
    try std.testing.expectEqual(@as(usize, 3), so.count("ERROR error ErRoR"));
}
