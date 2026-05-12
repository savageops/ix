//! PCRE2 JIT regex engine — compile-once, match-many.
//!
//! Drop-in replacement for regex.zig's column() and count() using PCRE2
//! with JIT compilation. A threadlocal cache compiles each pattern once
//! per thread and reuses the compiled code for all subsequent lines.
//!
//! Returns error.CompileFailed if PCRE2 cannot compile a pattern,
//! allowing callers to fall back via: pcre_regex.column(...) catch regex.column(...)

const std = @import("std");

const PCRE2_CASELESS: c_uint = 0x00000008;
const PCRE2_JIT_COMPLETE: c_uint = 0x00000001;
const PCRE2_SIZE = usize;

const pcre2_code_8 = opaque {};
const pcre2_match_data_8 = opaque {};

extern fn pcre2_compile_8(
    pattern: [*]const u8,
    length: PCRE2_SIZE,
    options: c_uint,
    errorcode: *c_int,
    erroroffset: *PCRE2_SIZE,
    compile_context: ?*anyopaque,
) ?*pcre2_code_8;

extern fn pcre2_jit_compile_8(code: *pcre2_code_8, options: c_uint) c_int;
extern fn pcre2_match_data_create_from_pattern_8(code: *pcre2_code_8, general_context: ?*anyopaque) ?*pcre2_match_data_8;
extern fn pcre2_match_data_free_8(match_data: *pcre2_match_data_8) void;
extern fn pcre2_code_free_8(code: *pcre2_code_8) void;
extern fn pcre2_match_8(
    code: *const pcre2_code_8,
    subject: [*]const u8,
    length: PCRE2_SIZE,
    startoffset: PCRE2_SIZE,
    options: u32,
    match_data: *pcre2_match_data_8,
    match_context: ?*anyopaque,
) c_int;
extern fn pcre2_get_ovector_pointer_8(match_data: *pcre2_match_data_8) [*]PCRE2_SIZE;

const MAX_CACHED_PATTERN = 512;

/// Threadlocal single-entry compiled regex cache. The search loop uses the
/// same pattern for every line in a file, so a single-entry cache gives
/// compile-once semantics without changing any function signatures.
const CachedRegex = struct {
    code: ?*pcre2_code_8 = null,
    match_data: ?*pcre2_match_data_8 = null,
    pattern_buf: [MAX_CACHED_PATTERN]u8 = undefined,
    pattern_len: usize = 0,
    compile_flags: c_uint = 0,
    state: State = .empty,

    const State = enum { empty, compiled, failed };

    fn isCacheHit(self: *const CachedRegex, pattern: []const u8, flags: c_uint) bool {
        return self.pattern_len == pattern.len and
            self.compile_flags == flags and
            std.mem.eql(u8, self.pattern_buf[0..self.pattern_len], pattern);
    }

    fn ensureCompiled(self: *CachedRegex, pattern: []const u8, case_insensitive: bool) bool {
        const flags: c_uint = if (case_insensitive) PCRE2_CASELESS else 0;

        if (self.state == .compiled and self.isCacheHit(pattern, flags)) return true;
        if (self.state == .failed and self.isCacheHit(pattern, flags)) return false;

        self.release();

        if (pattern.len > MAX_CACHED_PATTERN) {
            self.state = .failed;
            return false;
        }

        @memcpy(self.pattern_buf[0..pattern.len], pattern);
        self.pattern_len = pattern.len;
        self.compile_flags = flags;

        var err: c_int = undefined;
        var err_offset: PCRE2_SIZE = undefined;

        self.code = pcre2_compile_8(
            @ptrCast(pattern.ptr),
            pattern.len,
            flags,
            &err,
            &err_offset,
            null,
        );

        if (self.code == null) {
            self.state = .failed;
            return false;
        }

        // JIT compile for native machine code execution.
        // If JIT is unsupported on this platform, pcre2_match_8
        // transparently falls back to the PCRE2 interpreter
        // (still much faster than recursive backtracking).
        _ = pcre2_jit_compile_8(self.code.?, PCRE2_JIT_COMPLETE);

        self.match_data = pcre2_match_data_create_from_pattern_8(
            self.code.?,
            null,
        );

        if (self.match_data == null) {
            pcre2_code_free_8(self.code.?);
            self.code = null;
            self.state = .failed;
            return false;
        }

        self.state = .compiled;
        return true;
    }

    fn release(self: *CachedRegex) void {
        if (self.match_data) |md| pcre2_match_data_free_8(md);
        if (self.code) |cd| pcre2_code_free_8(cd);
        self.match_data = null;
        self.code = null;
        self.state = .empty;
    }
};

threadlocal var cache: CachedRegex = .{};

/// Returns the 1-based column of the first regex match, or null if no match.
/// Returns error.CompileFailed if PCRE2 cannot compile the pattern.
pub fn column(line: []const u8, pattern: []const u8, case_insensitive: bool) error{CompileFailed}!?usize {
    if (!cache.ensureCompiled(pattern, case_insensitive)) return error.CompileFailed;
    // Empty subjects need zero-width regex semantics. Use the native fallback
    // instead of collapsing every empty line into no-match.
    if (line.len == 0) return error.CompileFailed;

    const rc: c_int = pcre2_match_8(
        cache.code.?,
        @ptrCast(line.ptr),
        line.len,
        0,
        0,
        cache.match_data.?,
        null,
    );

    if (rc < 0) return null;

    const ovector = pcre2_get_ovector_pointer_8(cache.match_data.?);
    return ovector[0] + 1;
}

/// Counts non-overlapping regex matches in a line.
/// Returns error.CompileFailed if PCRE2 cannot compile the pattern.
pub fn count(line: []const u8, pattern: []const u8, case_insensitive: bool) error{CompileFailed}!usize {
    if (!cache.ensureCompiled(pattern, case_insensitive)) return error.CompileFailed;
    if (line.len == 0) return error.CompileFailed;

    var total: usize = 0;
    var offset: usize = 0;

    while (offset <= line.len) {
        const rc: c_int = pcre2_match_8(
            cache.code.?,
            @ptrCast(line.ptr),
            line.len,
            offset,
            0,
            cache.match_data.?,
            null,
        );

        if (rc < 0) break;

        total += 1;
        const ovector = pcre2_get_ovector_pointer_8(cache.match_data.?);
        const match_start: usize = ovector[0];
        const match_end: usize = ovector[1];
        // Advance past match; for zero-width matches advance by 1
        // to prevent infinite loops (same semantics as regex.count).
        offset = if (match_end > match_start) match_end else match_start + 1;
    }

    return total;
}
