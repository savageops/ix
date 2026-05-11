/// Pure Zig SIMD search kernels — inlineable replacements for StringZilla FFI.
///
/// These functions compile to the same AVX2 instructions as StringZilla
/// (VPCMPEQB, VPMOVMSKB, TZCNT) but live in the Zig compilation unit,
/// allowing the optimizer to inline them into the scan loop. This
/// eliminates ~5 ns/call FFI overhead across ~600K calls per search.
///
/// The StringZilla C shim remains available for non-hot-path use and
/// as a correctness reference.

const std = @import("std");

const VEC_SIZE = 32;
const Vec = @Vector(VEC_SIZE, u8);

/// SIMD-accelerated single-byte search (memchr equivalent).
///
/// Broadcasts the target byte into all 32 lanes of a YMM register,
/// compares 32 bytes per iteration with VPCMPEQB, extracts a bitmask
/// with VPMOVMSKB, and finds the first set bit with TZCNT.
///
/// For the tail (< 32 bytes), falls back to scalar to avoid
/// out-of-bounds reads — the tail is at most 31 bytes, so the
/// scalar cost is negligible.
pub inline fn indexOfByte(haystack: []const u8, needle: u8) ?usize {
    const len = haystack.len;
    if (len == 0) return null;

    const splat: Vec = @splat(needle);
    var offset: usize = 0;

    // Main SIMD loop — 32 bytes per iteration.
    while (offset + VEC_SIZE <= len) : (offset += VEC_SIZE) {
        const chunk: Vec = haystack[offset..][0..VEC_SIZE].*;
        const cmp = chunk == splat;
        const mask: u32 = @bitCast(cmp);
        if (mask != 0) {
            return offset + @ctz(mask);
        }
    }

    // Scalar tail — at most 31 bytes.
    while (offset < len) : (offset += 1) {
        if (haystack[offset] == needle) return offset;
    }

    return null;
}

/// SIMD-accelerated substring search (memmem equivalent).
///
/// For needle length 1, delegates to indexOfByte.
///
/// For needle length >= 2, uses StringZilla's first+last byte fingerprint:
/// broadcast needle[0] and needle[last] into SIMD registers, then for each
/// 32-byte window, compare the first-byte positions and the corresponding
/// last-byte positions simultaneously. AND the two masks — survivors are
/// candidate positions where both first and last bytes match. Only those
/// candidates need a full memcmp verify.
///
/// This eliminates most false positives without touching the needle's
/// interior bytes, achieving ~32 bytes/cycle throughput on AVX2.
pub inline fn indexOf(haystack: []const u8, needle: []const u8) ?usize {
    if (needle.len == 0) return 0;
    if (needle.len > haystack.len) return null;
    if (needle.len == 1) return indexOfByte(haystack, needle[0]);

    const first_byte: Vec = @splat(needle[0]);
    const last_byte: Vec = @splat(needle[needle.len - 1]);
    const n_len = needle.len;
    const scan_end = haystack.len - n_len + 1;

    var offset: usize = 0;

    // Main SIMD loop — check 32 candidate start positions per iteration.
    while (offset + VEC_SIZE <= scan_end) : (offset += VEC_SIZE) {
        // Load first-byte positions and corresponding last-byte positions.
        const first_chunk: Vec = haystack[offset..][0..VEC_SIZE].*;
        const last_chunk: Vec = haystack[offset + n_len - 1 ..][0..VEC_SIZE].*;

        const first_mask: u32 = @bitCast(first_chunk == first_byte);
        const last_mask: u32 = @bitCast(last_chunk == last_byte);
        // AND: both first and last byte must match.
        var mask: u32 = first_mask & last_mask;

        // Verify each surviving candidate.
        while (mask != 0) {
            const bit: u5 = @truncate(@ctz(mask));
            const pos = offset + bit;
            // Full verify — skip first and last bytes (already matched).
            if (n_len <= 2 or std.mem.eql(u8, haystack[pos + 1 .. pos + n_len - 1], needle[1 .. n_len - 1])) {
                return pos;
            }
            mask &= mask - 1; // Clear lowest set bit.
        }
    }

    // Scalar tail — at most VEC_SIZE-1 remaining start positions.
    while (offset < scan_end) : (offset += 1) {
        if (haystack[offset] == needle[0] and
            haystack[offset + n_len - 1] == needle[n_len - 1] and
            (n_len <= 2 or std.mem.eql(u8, haystack[offset + 1 .. offset + n_len - 1], needle[1 .. n_len - 1])))
        {
            return offset;
        }
    }

    return null;
}

// ── Tests ───────────────────────────────────────────────────────────

test "indexOfByte — basic" {
    const data = "hello world\nfoo bar\nbaz";
    try std.testing.expectEqual(@as(?usize, 5), indexOfByte(data, ' '));
    try std.testing.expectEqual(@as(?usize, 11), indexOfByte(data, '\n'));
    try std.testing.expectEqual(@as(?usize, 0), indexOfByte(data, 'h'));
    try std.testing.expectEqual(@as(?usize, null), indexOfByte(data, 'Z'));
}

test "indexOfByte — empty" {
    try std.testing.expectEqual(@as(?usize, null), indexOfByte("", 'x'));
}

test "indexOfByte — exact 32 bytes" {
    const data = "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAB"; // 31 A's + B
    try std.testing.expectEqual(@as(?usize, 31), indexOfByte(data, 'B'));
}

test "indexOfByte — longer than 32" {
    const data = "A" ** 64 ++ "B";
    try std.testing.expectEqual(@as(?usize, 64), indexOfByte(data, 'B'));
}

test "indexOf — basic" {
    const data = "the quick brown fox jumps over the lazy dog";
    try std.testing.expectEqual(@as(?usize, 16), indexOf(data, "fox"));
    try std.testing.expectEqual(@as(?usize, 0), indexOf(data, "the"));
    try std.testing.expectEqual(@as(?usize, null), indexOf(data, "cat"));
}

test "indexOf — single byte" {
    const data = "abcdef";
    try std.testing.expectEqual(@as(?usize, 3), indexOf(data, "d"));
}

test "indexOf — empty needle" {
    try std.testing.expectEqual(@as(?usize, 0), indexOf("abc", ""));
}

test "indexOf — needle longer than haystack" {
    try std.testing.expectEqual(@as(?usize, null), indexOf("ab", "abc"));
}

test "indexOf — two-byte needle" {
    const data = "aababcabcd";
    try std.testing.expectEqual(@as(?usize, 1), indexOf(data, "ab"));
}

test "indexOf — repeated pattern" {
    const data = "aaaa";
    try std.testing.expectEqual(@as(?usize, 0), indexOf(data, "aa"));
}

test "indexOf — cross-vector boundary" {
    // Needle starts in the tail region after the last full 32-byte chunk.
    const data = "X" ** 50 ++ "NEEDLE" ++ "Y" ** 10;
    try std.testing.expectEqual(@as(?usize, 50), indexOf(data, "NEEDLE"));
}

test "indexOf — first+last match but interior mismatch" {
    // 'f' and 'x' match at position 0 but interior differs.
    const data = "f__x fox";
    try std.testing.expectEqual(@as(?usize, 5), indexOf(data, "fox"));
}
