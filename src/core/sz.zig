const std = @import("std");

/// Thin Zig wrapper over StringZilla SIMD search kernels.
///
/// StringZilla (v4.6.0, Ash Vardanian) provides hardware-accelerated string
/// search using SIMD intrinsics. The library lives at `.refs/stringzilla/`
/// and is compiled into the Zig binary via a C shim (`sz_shim.c`).
///
/// Performance tiers (bytes searched per CPU cycle):
///   AVX2 (Haswell+):  ~32 bytes/cycle using 256-bit YMM registers
///   SWAR fallback:     ~8 bytes/cycle using 64-bit integer arithmetic
///   std.mem.indexOf:    ~1 byte/cycle (scalar comparison loop)
///
/// The AVX2 backend is selected at compile time: the C shim is compiled
/// with `-mavx2`, which defines `__AVX2__`, which triggers StringZilla's
/// `SZ_USE_HASWELL=1` macro (see stringzilla/types.h:270). No runtime
/// feature detection or dispatch overhead exists in the final binary.
///
/// This module replaces three hot paths in search.zig:
///   1. Newline scanning (splitting files into lines)
///   2. Null-byte detection (binary file sniffing)
///   3. Literal substring matching (the core search operation)
///
/// These three operations account for the majority of search engine wall
/// time because every byte of every scanned file passes through at least
/// one of them.

// C shim symbols from sz_shim.c — these are non-static wrappers around
// StringZilla's header-only `static inline` functions. The shim exists
// because Zig's `@cImport` cannot link static inline functions directly;
// the C compiler must emit them as real symbols first.
extern fn ix_sz_find(haystack: [*]const u8, h_len: usize, needle: [*]const u8, n_len: usize) ?[*]const u8;
extern fn ix_sz_find_byte(haystack: [*]const u8, h_len: usize, needle: [*]const u8) ?[*]const u8;
extern fn ix_sz_find_byteset(haystack: [*]const u8, h_len: usize, set: *const ByteSet) ?[*]const u8;

const AdmissionSkipCache = struct {
    initialized: bool = false,
    ptr: [*]const u8 = undefined,
    len: usize = 0,
    table: [256]usize = undefined,
};

threadlocal var admission_skip_cache: AdmissionSkipCache = .{};

/// 256-bit byte membership bitmap, ABI-compatible with `sz_byteset_t`.
/// 4 × u64 = 32 bytes. Bit `c` is set iff byte value `c` is in the set.
pub const ByteSet = extern struct {
    _u64s: [4]u64 = .{ 0, 0, 0, 0 },

    pub fn add(self: *ByteSet, byte: u8) void {
        self._u64s[byte >> 6] |= @as(u64, 1) << @as(u6, @intCast(byte & 63));
    }
};

/// SIMD-accelerated substring search (memmem equivalent).
///
/// For needles >1 byte, StringZilla uses a fingerprint approach: it loads
/// the first and last bytes of the needle into SIMD lanes, compares 32
/// candidate positions simultaneously with VPCMPEQB, ANDs the two result
/// masks, then only does a full byte-by-byte verify on survivors. This
/// eliminates most false positives without touching the needle's interior.
///
/// Returns the index of the first occurrence of `needle` in `haystack`, or null.
pub fn indexOf(haystack: []const u8, needle: []const u8) ?usize {
    if (needle.len == 0) return 0;
    if (needle.len > haystack.len) return null;
    // Zig slices carry ptr+len, but C expects separate arguments.
    // The pointer arithmetic below converts the C return pointer back
    // to a Zig slice index: result_ptr - haystack_ptr = offset.
    const result = ix_sz_find(haystack.ptr, haystack.len, needle.ptr, needle.len) orelse return null;
    return @intFromPtr(result) - @intFromPtr(haystack.ptr);
}

/// Existence probe for long mandatory needles.
///
/// StringZilla's fingerprint kernel is the canonical substring engine. For
/// cold-path admission, however, long absent needles profit from Horspool's
/// skip distance because the caller only needs null/not-null. Keep the selector
/// conservative so short literals and match counting remain on StringZilla.
pub fn indexOfAdmission(haystack: []const u8, needle: []const u8) ?usize {
    if (needle.len >= 16 and haystack.len >= 4096) {
        return indexOfBoyerMooreHorspool(haystack, needle);
    }
    return indexOf(haystack, needle);
}

/// Case-insensitive existence probe that avoids casefolding the haystack.
///
/// Standard case-insensitive admission calls asciiLowerBuf on the full 1 MiB
/// buffer, then runs exact indexOf on each lowercased needle. That write is
/// expensive — it dirties cache lines across the entire buffer, evicting hot
/// scan data from L1/L2.
///
/// This function eliminates the write by building a Horspool skip table that
/// maps both ASCII case variants of each needle byte to the same skip distance,
/// and verifying candidates with a case-folded byte comparison. The haystack
/// is read-only throughout.
///
/// For needles <2 bytes or haystacks too small for Horspool's skip to pay off,
/// falls back to a scalar case-insensitive scan.
pub fn indexOfAdmissionCaseInsensitive(haystack: []const u8, lower_needle: []const u8) ?usize {
    if (lower_needle.len == 0) return 0;
    if (lower_needle.len > haystack.len) return null;

    // Horspool benefits from needle length ≥3 (meaningful skip distances).
    // For length 1-2, scalar case-insensitive search is faster.
    if (lower_needle.len >= 3 and haystack.len >= 64) {
        return indexOfBoyerMooreHorspoolCI(haystack, lower_needle);
    }
    return indexOfScalarCI(haystack, lower_needle);
}

/// Scalar case-insensitive substring search for short needles.
fn indexOfScalarCI(haystack: []const u8, needle: []const u8) ?usize {
    const limit = haystack.len - needle.len;
    var i: usize = 0;
    while (i <= limit) : (i += 1) {
        var match = true;
        for (needle, 0..) |nc, j| {
            const hc = haystack[i + j];
            const hl = if (hc >= 'A' and hc <= 'Z') hc + 32 else hc;
            if (hl != nc) {
                match = false;
                break;
            }
        }
        if (match) return i;
    }
    return null;
}

threadlocal var ci_skip_cache: AdmissionSkipCache = .{};

/// Case-insensitive Boyer-Moore-Horspool. Skip table maps both case variants
/// of each needle byte to the same distance. Candidate verification compares
/// case-folded haystack bytes against the pre-lowercased needle.
fn indexOfBoyerMooreHorspoolCI(haystack: []const u8, lower_needle: []const u8) ?usize {
    if (!ci_skip_cache.initialized or
        ci_skip_cache.ptr != lower_needle.ptr or
        ci_skip_cache.len != lower_needle.len)
    {
        ci_skip_cache.initialized = true;
        ci_skip_cache.ptr = lower_needle.ptr;
        ci_skip_cache.len = lower_needle.len;
        @memset(&ci_skip_cache.table, lower_needle.len);
        for (lower_needle[0 .. lower_needle.len - 1], 0..) |byte, index| {
            const skip = lower_needle.len - 1 - index;
            ci_skip_cache.table[byte] = skip;
            // Map uppercase variant to the same skip distance.
            if (byte >= 'a' and byte <= 'z') {
                ci_skip_cache.table[byte - 32] = skip;
            }
        }
    }

    var cursor: usize = 0;
    const last = lower_needle.len - 1;
    const limit = haystack.len - lower_needle.len;
    while (cursor <= limit) {
        const tail_raw = haystack[cursor + last];
        const tail = if (tail_raw >= 'A' and tail_raw <= 'Z') tail_raw + 32 else tail_raw;
        if (tail == lower_needle[last]) {
            // Verify full match with case-folded comparison.
            var match = true;
            for (lower_needle[0..last], 0..) |nc, j| {
                const hc_raw = haystack[cursor + j];
                const hc = if (hc_raw >= 'A' and hc_raw <= 'Z') hc_raw + 32 else hc_raw;
                if (hc != nc) {
                    match = false;
                    break;
                }
            }
            if (match) return cursor;
        }
        cursor += ci_skip_cache.table[tail_raw];
    }
    return null;
}

fn indexOfBoyerMooreHorspool(haystack: []const u8, needle: []const u8) ?usize {
    if (needle.len == 0) return 0;
    if (needle.len > haystack.len) return null;
    if (!admission_skip_cache.initialized or
        admission_skip_cache.ptr != needle.ptr or
        admission_skip_cache.len != needle.len)
    {
        admission_skip_cache.initialized = true;
        admission_skip_cache.ptr = needle.ptr;
        admission_skip_cache.len = needle.len;
        @memset(&admission_skip_cache.table, needle.len);
        for (needle[0 .. needle.len - 1], 0..) |byte, index| {
            admission_skip_cache.table[byte] = needle.len - 1 - index;
        }
    }

    var cursor: usize = 0;
    const last = needle.len - 1;
    const limit = haystack.len - needle.len;
    while (cursor <= limit) {
        const tail = haystack[cursor + last];
        if (tail == needle[last] and std.mem.eql(u8, haystack[cursor .. cursor + needle.len], needle)) return cursor;
        cursor += admission_skip_cache.table[tail];
    }
    return null;
}

/// SIMD-accelerated single-byte search (memchr equivalent).
///
/// Uses VPCMPEQB to compare 32 bytes against the target byte in one
/// instruction, producing a 32-bit mask. TZCNT (trailing zero count)
/// then gives the position of the first match. This processes ~32 bytes
/// per cycle vs the 1 byte/cycle of std.mem.indexOfScalar.
///
/// Returns the index of the first occurrence of `byte` in `haystack`, or null.
pub fn indexOfByte(haystack: []const u8, byte: u8) ?usize {
    if (haystack.len == 0) return null;
    // StringZilla's find_byte takes a pointer to the needle byte, not the
    // byte value itself — this is a C API convention for consistency with
    // the multi-byte find function signature.
    const needle_buf = [1]u8{byte};
    const result = ix_sz_find_byte(haystack.ptr, haystack.len, &needle_buf) orelse return null;
    return @intFromPtr(result) - @intFromPtr(haystack.ptr);
}

/// SIMD-accelerated byte-set search (find first byte in set).
///
/// On Haswell uses VPSHUFB nibble-mask to classify 32 bytes per cycle.
/// The `ByteSet` is a 256-bit bitmap where bit `c` indicates byte value
/// `c` is in the target set.
///
/// Returns the index of the first byte in `haystack` that belongs to `set`, or null.
pub fn indexOfByteSet(haystack: []const u8, set: *const ByteSet) ?usize {
    if (haystack.len == 0) return null;
    const result = ix_sz_find_byteset(haystack.ptr, haystack.len, set) orelse return null;
    return @intFromPtr(result) - @intFromPtr(haystack.ptr);
}

test "admission index matches stringzilla semantics" {
    try std.testing.expectEqual(@as(?usize, 0), indexOfAdmission("abcdef", ""));
    try std.testing.expectEqual(@as(?usize, null), indexOfAdmission("abc", "abcd"));
    try std.testing.expectEqual(@as(?usize, 6), indexOfAdmission("prefix0123456789abcdefsuffix", "0123456789abcdef"));
    try std.testing.expectEqual(@as(?usize, null), indexOfAdmission("prefix0123456789abcxefsuffix", "0123456789abcdef"));

    const haystack = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa0123456789abcdef";
    try std.testing.expectEqual(indexOf(haystack, "0123456789abcdef"), indexOfAdmission(haystack, "0123456789abcdef"));
}
