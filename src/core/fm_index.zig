const std = @import("std");

/// FM-Index on the Burrows-Wheeler Transform (Ferragina–Manzini 2000).
///
/// Spec point 11: "implementing the FM-Index on the Burrows-Wheeler
/// Transform with LF-Mapping (LF(i) = C[L[i]] + Occ(L[i], i)). Pattern
/// existence and offset location are resolved by traversing compressed
/// bit-vectors backward in exact O(p) time."
///
/// This module implements the core FM-Index data structure with LF-Mapping
/// and backward search. The text is terminated with a unique sentinel ($)
/// that is lexicographically smaller than all other characters.
///
/// Components:
///   - BWT: the Burrows-Wheeler Transform of the text
///   - C[c]: number of characters in the text that are lexicographically < c
///   - Occ(c, i): number of occurrences of c in BWT[0, i] (prefix-sum table)
///
/// The backward search processes the pattern from right to left,
/// maintaining a half-open range [first, last) in the BWT's sorted
/// suffix array. Each step is O(1) via LF-Mapping:
///   first  = C[P[j]] + Occ(P[j], first)
///   last   = C[P[j]] + Occ(P[j], last)
/// If last > first after all pattern bytes, the pattern exists.
/// Total: O(p) time independent of text length — sub-linear in corpus size.

const ALPHABET_SIZE: usize = 256;
const SENTINEL: u8 = 0; // We use byte 0 as the unique sentinel.

/// The FM-Index structure. Owns the BWT, C table, and Occ prefix sums.
pub const FMIndex = struct {
    bwt: []u8,
    c_table: [ALPHABET_SIZE + 1]u64,
    /// Occ prefix sums: occ[c * (text_len + 1) + i] = count of c in BWT[0, i].
    /// This is the uncompressed form — a production index would use
    /// wavelet trees or compressed bit-vectors (spec point 11 mentions
    /// "compressed bit-vectors"). The interface is identical.
    occ: []u64,
    text_len: usize,
    /// The original text positions, sorted lexicographically by suffix.
    /// Used for locate() — mapping BWT positions back to text offsets.
    sa: []u64,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *FMIndex) void {
        self.allocator.free(self.bwt);
        self.allocator.free(self.occ);
        self.allocator.free(self.sa);
    }

    /// Returns true if the pattern exists in the indexed text.
    /// O(p) time where p = pattern length.
    pub fn contains(self: *const FMIndex, pattern: []const u8) bool {
        return self.count(pattern) > 0;
    }

    /// Returns the number of occurrences of the pattern.
    /// O(p) time.
    pub fn count(self: *const FMIndex, pattern: []const u8) usize {
        if (pattern.len == 0) return 0;
        const range = self.backwardSearch(pattern);
        return if (range.last > range.first) range.last - range.first else 0;
    }

    /// Locates all occurrences of the pattern, writing text offsets to `out`.
    /// Returns the number of occurrences found.
    /// O(p + occ) where occ is the number of occurrences.
    pub fn locate(self: *const FMIndex, pattern: []const u8, out: []u64) usize {
        if (pattern.len == 0) return 0;
        const range = self.backwardSearch(pattern);
        if (range.last <= range.first) return 0;
        const num = @min(range.last - range.first, out.len);
        for (0..num) |i| {
            out[i] = self.sa[range.first + i];
        }
        return num;
    }

    const Range = struct { first: u64, last: u64 };

    /// Core backward search. Processes the pattern right-to-left.
    fn backwardSearch(self: *const FMIndex, pattern: []const u8) Range {
        var first: u64 = 0;
        var last: u64 = @intCast(self.text_len);
        var j: usize = pattern.len;
        while (j > 0) {
            j -= 1;
            const c = pattern[j];
            const c_idx = @as(usize, c) + 1; // +1 offset for sentinel at index 0.
            first = self.c_table[c_idx] + self.occAt(c_idx, first);
            last = self.c_table[c_idx] + self.occAt(c_idx, last);
            if (last <= first) break;
        }
        return .{ .first = first, .last = last };
    }

    /// Occ(c, i): count of character c in BWT at positions before i.
    /// O(1) lookup into the prefix-sum table.
    fn occAt(self: *const FMIndex, c: usize, i: u64) u64 {
        return self.occ[c * (self.text_len + 1) + i];
    }
};

/// Builds an FM-Index from a text string. The text must not contain the
/// sentinel byte (0x00). Uses a naive suffix array sort (O(n log n)) —
/// suitable for texts up to ~100K bytes. A production index would use
/// a linear-time suffix array construction algorithm.
///
/// For larger texts, the caller should build the BWT and suffix array
/// externally and construct the FM-Index from those.
pub fn buildFMIndex(allocator: std.mem.Allocator, text: []const u8) !FMIndex {
    const n = text.len;

    // The effective text includes a sentinel at the end.
    // We use byte 0 as the sentinel, so the text must not contain 0x00.
    for (text) |c| {
        if (c == SENTINEL) return error.TextContainsSentinel;
    }

    // Build suffix array by sorting suffix indices.
    // Each suffix is text[i..n] — we compare by actual byte comparison.
    const sa = try allocator.alloc(u64, n + 1);
    errdefer allocator.free(sa);
    for (0..n + 1) |i| sa[i] = i;

    // Sort suffixes lexicographically. The sentinel (position n, empty suffix)
    // sorts first.
    std.mem.sort(u64, sa, text, suffixLessThan);

    // Build BWT from the sorted suffix array.
    // BWT[i] = text[SA[i] - 1] if SA[i] > 0, else sentinel.
    const bwt = try allocator.alloc(u8, n + 1);
    errdefer allocator.free(bwt);
    for (sa, 0..) |sa_val, i| {
        bwt[i] = if (sa_val == 0) SENTINEL else text[sa_val - 1];
    }

    // Build C table: C[c] = number of characters in text lexicographically < c.
    // The sentinel (byte 0) sorts first. Characters use their natural byte value
    // as the index; the sentinel occupies index 0.
    var char_counts: [ALPHABET_SIZE + 1]u64 = [_]u64{0} ** (ALPHABET_SIZE + 1);
    for (text) |c| char_counts[@as(usize, c) + 1] += 1;
    char_counts[0] = 1; // The sentinel at index 0.

    var c_table: [ALPHABET_SIZE + 1]u64 = [_]u64{0} ** (ALPHABET_SIZE + 1);
    var cumulative: u64 = 0;
    // c_table[c+1] gives the rank for byte value c (shifted by 1 for sentinel).
    // During backward search, we look up c_table[c+1] for a byte value c.
    for (0..ALPHABET_SIZE + 1) |idx| {
        c_table[idx] = cumulative;
        cumulative += char_counts[idx];
    }

    // Build Occ prefix-sum table: Occ(c, i) = count of c in BWT[0, i).
    const occ = try allocator.alloc(u64, (ALPHABET_SIZE + 1) * (n + 2));
    errdefer allocator.free(occ);
    @memset(occ, 0);

    // Initialize row 0 to all zeros.
    for (0..ALPHABET_SIZE + 1) |c| {
        occ[c * (n + 2) + 0] = 0;
    }
    // Fill prefix sums. BWT character at position i is indexed at bwt[i]+1
    // in the Occ table (matching the C table's sentinel offset).
    for (0..n + 1) |i| {
        const bwt_idx = @as(usize, bwt[i]) + 1;
        for (0..ALPHABET_SIZE + 1) |c| {
            occ[c * (n + 2) + i + 1] = occ[c * (n + 2) + i] + (if (c == bwt_idx) @as(u64, 1) else 0);
        }
    }

    return FMIndex{
        .bwt = bwt,
        .c_table = c_table,
        .occ = occ,
        .text_len = n + 1,
        .sa = sa,
        .allocator = allocator,
    };
}

fn suffixLessThan(ctx: []const u8, a: u64, b: u64) bool {
    const n = ctx.len;
    // Suffix at position n (empty suffix, the sentinel) sorts first.
    if (a == n) return b != n;
    if (b == n) return false;
    // Compare suffixes text[a..] and text[b..].
    const a_slice = ctx[a..];
    const b_slice = ctx[b..];
    return std.mem.lessThan(u8, a_slice, b_slice);
}

// ============================================================================
// Tests
// ============================================================================

test "fm-index finds pattern in simple text" {
    var fmi = try buildFMIndex(std.testing.allocator, "banana");
    defer fmi.deinit();

    try std.testing.expect(fmi.contains("ana"));
    try std.testing.expect(fmi.contains("ban"));
    try std.testing.expect(fmi.contains("a"));
    try std.testing.expect(fmi.contains("banana"));
    try std.testing.expect(!fmi.contains("xyz"));
    try std.testing.expect(!fmi.contains("bananas"));
}

test "fm-index count matches expected occurrences" {
    var fmi = try buildFMIndex(std.testing.allocator, "banana");
    defer fmi.deinit();

    // "ana" appears at positions 1 and 3.
    try std.testing.expectEqual(@as(usize, 2), fmi.count("ana"));
    // "a" appears at positions 1, 3, 5.
    try std.testing.expectEqual(@as(usize, 3), fmi.count("a"));
    // "ban" appears once.
    try std.testing.expectEqual(@as(usize, 1), fmi.count("ban"));
    // "na" appears twice.
    try std.testing.expectEqual(@as(usize, 2), fmi.count("na"));
    // "xyz" absent.
    try std.testing.expectEqual(@as(usize, 0), fmi.count("xyz"));
}

test "fm-index locate returns text offsets" {
    var fmi = try buildFMIndex(std.testing.allocator, "banana");
    defer fmi.deinit();

    var offsets: [4]u64 = undefined;
    const num = fmi.locate("ana", &offsets);
    try std.testing.expectEqual(@as(usize, 2), num);
    // "ana" at positions 1 and 3 in "banana". Suffix-array order:
    // offset 3 ("ana") sorts before offset 1 ("anana").
    try std.testing.expectEqual(@as(u64, 3), offsets[0]);
    try std.testing.expectEqual(@as(u64, 1), offsets[1]);
}

test "fm-index handles single character text" {
    var fmi = try buildFMIndex(std.testing.allocator, "a");
    defer fmi.deinit();

    try std.testing.expect(fmi.contains("a"));
    try std.testing.expect(!fmi.contains("b"));
    try std.testing.expectEqual(@as(usize, 1), fmi.count("a"));
}

test "fm-index handles repeated pattern" {
    var fmi = try buildFMIndex(std.testing.allocator, "aaaa");
    defer fmi.deinit();

    try std.testing.expectEqual(@as(usize, 4), fmi.count("a"));
    try std.testing.expectEqual(@as(usize, 3), fmi.count("aa"));
    try std.testing.expectEqual(@as(usize, 2), fmi.count("aaa"));
    try std.testing.expectEqual(@as(usize, 1), fmi.count("aaaa"));
    try std.testing.expectEqual(@as(usize, 0), fmi.count("aaaaa"));
}

test "fm-index handles text with multi-byte patterns" {
    var fmi = try buildFMIndex(std.testing.allocator, "mississippi");
    defer fmi.deinit();

    try std.testing.expect(fmi.contains("iss"));
    try std.testing.expectEqual(@as(usize, 2), fmi.count("iss"));
    try std.testing.expectEqual(@as(usize, 2), fmi.count("ss"));
    try std.testing.expectEqual(@as(usize, 4), fmi.count("i"));
    try std.testing.expectEqual(@as(usize, 1), fmi.count("miss"));
    try std.testing.expect(!fmi.contains("xyz"));
}

test "fm-index empty pattern returns zero" {
    var fmi = try buildFMIndex(std.testing.allocator, "hello");
    defer fmi.deinit();

    try std.testing.expectEqual(@as(usize, 0), fmi.count(""));
    try std.testing.expect(!fmi.contains(""));
}

test "fm-index backward search handles overlapping patterns" {
    var fmi = try buildFMIndex(std.testing.allocator, "abababab");
    defer fmi.deinit();

    try std.testing.expectEqual(@as(usize, 3), fmi.count("aba"));
    try std.testing.expectEqual(@as(usize, 4), fmi.count("ab"));
    try std.testing.expect(fmi.contains("babab"));
}
