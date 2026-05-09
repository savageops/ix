/**
 * StringZilla C shim for Zig FFI.
 *
 * WHY THIS FILE EXISTS:
 * StringZilla is a header-only C library — all functions are declared
 * `static inline`. Zig's `@cImport` can parse headers but cannot link
 * static inline functions (there are no emitted symbols to link against).
 * This shim forces the compiler to emit real linkable symbols by wrapping
 * each StringZilla call in a non-static function.
 *
 * HOW SIMD BACKEND SELECTION WORKS:
 * SZ_DYNAMIC_DISPATCH=0 disables StringZilla's runtime CPU feature
 * detection (which requires DllMain on Windows). Instead, the `-mavx2`
 * compiler flag defines `__AVX2__`, which triggers StringZilla's
 * compile-time macro chain:
 *
 *   -mavx2  →  __AVX2__ defined  →  SZ_USE_HASWELL=1  →  AVX2 backend
 *
 * The AVX2 (Haswell) backend uses 256-bit YMM registers to process 32
 * bytes per VPCMPEQB instruction. Without -mavx2, the SWAR fallback
 * processes 8 bytes per cycle using 64-bit integer arithmetic — still
 * 8x faster than a naive byte-by-byte loop.
 *
 * INCLUDE CHAIN (why link_libc is required in build.zig):
 *   stringzilla/find.h  →  immintrin.h  →  xmmintrin.h  →  mm_malloc.h
 *   →  stdlib.h (requires system libc headers)
 */
#define SZ_DYNAMIC_DISPATCH 0
#include <stringzilla/find.h>
#include <stringzilla/compare.h>

/*
 * Substring search — SIMD memmem equivalent.
 * For needles >1 byte, StringZilla fingerprints by first+last byte,
 * checks 32 positions per SIMD pass, then verifies surviving candidates.
 */
char const *ix_sz_find(char const *haystack, size_t h_len,
                       char const *needle, size_t n_len) {
    return sz_find(haystack, (sz_size_t)h_len, needle, (sz_size_t)n_len);
}

/*
 * Single-byte search — SIMD memchr equivalent.
 * Broadcasts the target byte across all 32 YMM lanes, compares with
 * VPCMPEQB, then uses VPMOVMSKB + TZCNT to find the first match.
 */
char const *ix_sz_find_byte(char const *haystack, size_t h_len,
                            char const *needle) {
    return sz_find_byte(haystack, (sz_size_t)h_len, needle);
}

/*
 * Byte equality — SIMD memcmp equivalent.
 * Compares two buffers using SIMD-width chunks. Currently unused in
 * hot paths but available for future case-insensitive prefilters.
 */
int ix_sz_equal(char const *a, char const *b, size_t len) {
    return (int)sz_equal(a, b, (sz_size_t)len);
}
