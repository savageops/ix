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
