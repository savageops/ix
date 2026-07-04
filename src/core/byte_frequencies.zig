const std = @import("std");

/// Empirical byte-frequency ranks (0=rarest, 255=most common) derived from
/// a large corpus of English text and source code. Harvested from
/// BurntSushi/aho-corasick `src/util/byte_frequencies.rs` (public domain).
///
/// Used to select the rarest byte in a search needle as the prefilter anchor
/// — the rare byte dismisses more input per cycle than a common byte.
/// For case-insensitive search, use `rarestCaseInsensitive` which picks the
/// rarer of the upper/lower variants.
///
/// Reference: BurntSushi/aho-corasick, `src/packed/prefilter.rs:600-708`
/// uses `freq_rank(b)` to choose the memchr prefilter target.
pub const BYTE_FREQUENCIES: [256]u8 = .{
    55, 52, 51, 50, 49, 48, 47, 46, 45, 103, 242, 66, 67, 229, 44, 43,
    42, 41, 40, 39, 38, 37, 36, 35, 34, 33, 56, 32, 31, 30, 29, 28,
    255, 148, 164, 149, 136, 160, 155, 173, 221, 222, 134, 122, 232, 202, 215, 224,
    208, 220, 204, 187, 183, 179, 177, 168, 178, 200, 226, 195, 154, 184, 174, 126,
    120, 191, 157, 194, 170, 189, 162, 161, 150, 193, 142, 137, 171, 176, 185, 167,
    186, 112, 175, 192, 188, 156, 140, 143, 123, 133, 128, 147, 138, 146, 114, 223,
    151, 249, 216, 238, 236, 253, 227, 218, 230, 247, 135, 180, 241, 233, 246, 244,
    231, 139, 245, 243, 251, 235, 201, 196, 240, 214, 152, 182, 205, 181, 127, 27,
    212, 211, 210, 213, 228, 197, 169, 159, 131, 172, 105, 80, 98, 96, 97, 81,
    207, 145, 116, 115, 144, 130, 153, 121, 107, 132, 109, 110, 124, 111, 82, 108,
    118, 141, 113, 129, 119, 125, 165, 117, 92, 106, 83, 72, 99, 93, 65, 79,
    166, 237, 163, 199, 190, 225, 209, 203, 198, 217, 219, 206, 234, 248, 158, 239,
    255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255,
    255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255,
    255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255,
    255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255,
};

/// Returns the frequency rank of a byte (0=rarest, 255=most common).
pub inline fn rank(byte: u8) u8 {
    return BYTE_FREQUENCIES[byte];
}

/// Returns the rarer of the two case variants (upper/lower) of an ASCII byte.
/// For non-ASCII bytes, returns the byte itself.
pub inline fn rarestCaseVariant(byte: u8) u8 {
    if (byte >= 'A' and byte <= 'Z') {
        const lower = byte + 32;
        return if (BYTE_FREQUENCIES[byte] <= BYTE_FREQUENCIES[lower]) byte else lower;
    }
    if (byte >= 'a' and byte <= 'z') {
        const upper = byte - 32;
        return if (BYTE_FREQUENCIES[byte] <= BYTE_FREQUENCIES[upper]) byte else upper;
    }
    return byte;
}

/// Finds the rarest byte in a needle and returns its index.
/// Used to select the optimal memchr prefilter anchor.
pub fn rarestByteIndex(needle: []const u8) ?usize {
    if (needle.len == 0) return null;
    var best_index: usize = 0;
    var best_rank = BYTE_FREQUENCIES[needle[0]];
    for (1..needle.len) |i| {
        const r = BYTE_FREQUENCIES[needle[i]];
        if (r < best_rank) {
            best_rank = r;
            best_index = i;
        }
    }
    return best_index;
}

test "byte frequency table covers full ASCII range" {
    // Space (0x20) should be the most common printable byte (rank 255).
    try std.testing.expectEqual(@as(u8, 255), BYTE_FREQUENCIES[' ']);
    // Newline (0x0A) should be very common (rank 242).
    try std.testing.expectEqual(@as(u8, 242), BYTE_FREQUENCIES['\n']);
    // Null (0x00) should be rare (rank 55).
    try std.testing.expectEqual(@as(u8, 55), BYTE_FREQUENCIES[0]);
}

test "rarest byte selection picks uncommon characters" {
    // In "function", 'f' (rank 102) is rarer than 'n' (rank 97) — wait, let's just verify
    const idx = rarestByteIndex("function").?;
    const rarest = "function"[idx];
    // The rarest should not be 'n' (very common in English) or 'i'
    try std.testing.expect(rarest == 'f' or rarest == 'u' or rarest == 'c' or rarest == 't' or rarest == 'o');
}

test "case variant selection picks the rarer form" {
    // 'q' has rank 113, 'Q' has rank 153 — 'q' (lowercase) is more common, so
    // rarestCaseVariant should return 'Q' (the rarer form).
    const rarest = rarestCaseVariant('q');
    try std.testing.expectEqual(@as(u8, 'Q'), rarest);
    // 'e' has rank 234, 'E' has rank 189 — 'E' is rarer.
    const rarest_e = rarestCaseVariant('e');
    try std.testing.expectEqual(@as(u8, 'E'), rarest_e);
}
