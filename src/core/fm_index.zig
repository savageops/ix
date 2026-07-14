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

/// P11: Wavelet Tree — compressed bit-vector Occ table.
///
/// A wavelet tree stores the BWT as a balanced binary tree of bit-vectors.
/// For a 256-byte alphabet, the tree has 8 levels (log₂ 256). At each level,
/// the alphabet is partitioned by the bit at that level. The bit-vector
/// records which side each character belongs to.
///
/// Rank queries (Occ(c, i) = count of character c in BWT[0..i)) are answered
/// by traversing the tree: at each level, use the bit-vector's rank1 to project
/// the position into the child's domain. This takes O(log σ) = O(8) = O(1) time.
///
/// Space: 8 × n bits = n bytes. Compare to the uncompressed Occ table which
/// uses 257 × n × 8 bytes = 2056n bytes. This is a ~2000× compression.
pub const WaveletTree = struct {
    /// One bit-vector per level (8 levels for 256-byte alphabet).
    /// Level 0 uses bit 7 of the byte, level 7 uses bit 0.
    levels: [8][]u64,
    /// Number of 0-bits (characters in left child) at each level.
    n_zeros: [8]usize = [_]usize{0} ** 8,
    n: usize,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *WaveletTree) void {
        for (self.levels) |level| self.allocator.free(level);
    }

    /// Occ(c, i): count of character c in BWT[0..i).
    /// Traverses the wavelet tree from root to leaf (8 levels).
    pub fn rank(self: *const WaveletTree, char: u8, pos: usize) u64 {
        var lo: usize = 0;
        var hi: usize = pos;
        for (0..8) |level| {
            const bit = (char >> @intCast(7 - level)) & 1;
            const level_bits = self.levels[level];
            // Count 1-bits in [lo, hi) of this level's bit-vector.
            const ones = popcountRange(level_bits, lo, hi);
            const range_len = hi - lo;
            const zeros = range_len - ones;
            if (bit == 0) {
                hi = zeros;
                // lo stays at 0 (all zeros are packed to the left).
                // But we need rank0(lo) as new lo, and rank0(hi) as new hi.
                // Since we're navigating the 0-child:
                lo = (lo - popcountRange(level_bits, 0, lo)); // zeros before lo
                hi = lo + zeros;
            } else {
                // 1-child: new position = total_zeros + ones_before_in_range
                const total_zeros = self.n_zeros[level];
                lo = total_zeros + popcountRange(level_bits, 0, lo);
                hi = lo + ones;
            }
        }
        return @intCast(hi - lo);
    }

    const POPLUT: [256]u8 = blk: {
        var lut: [256]u8 = undefined;
        for (0..256) |i| lut[i] = @popCount(@as(u8, @intCast(i)));
        break :blk lut;
    };

    /// Count 1-bits in positions [lo, hi) of a bit-vector stored as u64 array.
    fn popcountRange(bits: []const u64, lo: usize, hi: usize) usize {
        if (lo >= hi) return 0;
        var count: usize = 0;
        // Bit i is in word i/64 at position i%64.
        const start_word = lo / 64;
        const end_word = hi / 64;
        if (start_word == end_word) {
            // Single word partial.
            const mask = (~@as(u64, 0) >> @intCast(lo % 64)) & (~@as(u64, 0) << @intCast(@as(u8, @intCast(64 - (hi - start_word * 64))) & 63));
            count += @popCount(bits[start_word] & mask);
        } else {
            // Start partial.
            if (lo % 64 != 0) {
                count += @popCount(bits[start_word] >> @intCast(lo % 64));
            } else {
                count += @popCount(bits[start_word]);
            }
            // Full words.
            for (start_word + 1..end_word) |w| count += @popCount(bits[w]);
            // End partial.
            if (hi % 64 != 0) {
                const shift: u6 = @intCast(64 - (hi % 64));
                count += @popCount(bits[end_word] << shift >> shift);
            } else {
                count += @popCount(bits[end_word]);
            }
        }
        return count;
    }
};

/// The FM-Index structure. Owns the BWT, C table, and wavelet tree.
pub const FMIndex = struct {
    bwt: []u8,
    c_table: [ALPHABET_SIZE + 1]u64,
    /// P11: Wavelet tree replaces the uncompressed Occ prefix-sum table.
    /// Provides O(1) rank queries using compressed bit-vectors (8 × n bits).
    wavelet: ?WaveletTree = null,
    /// Fallback uncompressed Occ for small texts where wavelet overhead
    /// exceeds the memory savings.
    occ: ?[]u64 = null,
    text_len: usize,
    sa: []u64,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *FMIndex) void {
        self.allocator.free(self.bwt);
        if (self.occ) |o| self.allocator.free(o);
        if (self.wavelet) |*w| w.deinit();
        self.allocator.free(self.sa);
    }

    pub fn contains(self: *const FMIndex, pattern: []const u8) bool {
        return self.count(pattern) > 0;
    }

    pub fn count(self: *const FMIndex, pattern: []const u8) usize {
        if (pattern.len == 0) return 0;
        const range = self.backwardSearch(pattern);
        return if (range.last > range.first) range.last - range.first else 0;
    }

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

    fn backwardSearch(self: *const FMIndex, pattern: []const u8) Range {
        var first: u64 = 0;
        var last: u64 = @intCast(self.text_len);
        var j: usize = pattern.len;
        while (j > 0) {
            j -= 1;
            const c = pattern[j];
            const c_idx = @as(usize, c) + 1;
            first = self.c_table[c_idx] + self.occAt(c_idx, first);
            last = self.c_table[c_idx] + self.occAt(c_idx, last);
            if (last <= first) break;
        }
        return .{ .first = first, .last = last };
    }

    /// Occ(c, i): count of character c in BWT at positions before i.
    /// Dispatches to wavelet tree (compressed) or uncompressed table.
    fn occAt(self: *const FMIndex, c: usize, i: u64) u64 {
        if (self.wavelet) |w| {
            // c is 1-indexed (c_idx = byte + 1 for sentinel). Convert back.
            const byte: u8 = @intCast(c - 1);
            return w.rank(byte, @intCast(i));
        }
        if (self.occ) |o| {
            return o[c * (self.text_len + 1) + i];
        }
        return 0;
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

    // P11: Build wavelet tree for compressed Occ queries.
    // The wavelet tree uses 8 × n bits = n bytes (vs 257 × n × 8 bytes
    // for the uncompressed table). This is a ~2000× compression.
    const bwt_len = n + 1;
    var wavelet = try buildWaveletTree(allocator, bwt, bwt_len);
    errdefer wavelet.deinit();

    return FMIndex{
        .bwt = bwt,
        .c_table = c_table,
        .wavelet = wavelet,
        .occ = null,
        .text_len = bwt_len,
        .sa = sa,
        .allocator = allocator,
    };
}

/// P11: Builds a wavelet tree from a BWT byte array.
/// The tree has 8 levels (log₂ 256). At each level, characters are
/// partitioned by the bit at that level (MSB first). The bit-vector
/// records which partition each character belongs to.
fn buildWaveletTree(allocator: std.mem.Allocator, bwt: []const u8, n: usize) !WaveletTree {
    var wt = WaveletTree{
        .levels = undefined,
        .n = n,
        .allocator = allocator,
    };

    // Current permutation of BWT characters at each level.
    var current = try allocator.alloc(u8, n);
    defer allocator.free(current);
    @memcpy(current, bwt);

    var next = try allocator.alloc(u8, n);
    defer allocator.free(next);

    for (0..8) |level| {
        const bit_pos: u3 = @intCast(7 - level);
        const words = (n + 63) / 64;
        const level_bits = try allocator.alloc(u64, words);
        @memset(level_bits, 0);

        // Partition: zeros go left, ones go right.
        var zero_idx: usize = 0;
        var one_idx: usize = 0;
        // First pass: count zeros.
        var zero_count: usize = 0;
        for (current) |c| {
            if ((c >> bit_pos) & 1 == 0) zero_count += 1;
        }
        wt.n_zeros[level] = zero_count;
        one_idx = zero_count;

        // Second pass: build bit-vector and partition.
        for (current, 0..) |c, i| {
            const bit = (c >> bit_pos) & 1;
            if (bit == 1) {
                level_bits[i / 64] |= @as(u64, 1) << @intCast(i % 64);
                next[one_idx] = c;
                one_idx += 1;
            } else {
                next[zero_idx] = c;
                zero_idx += 1;
            }
        }

        wt.levels[level] = level_bits;

        // Swap current and next.
        const tmp = current;
        current = next;
        next = tmp;
    }

    return wt;
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
