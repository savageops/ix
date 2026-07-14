const std = @import("std");
const builtin = @import("builtin");

/// P15: JIT Forge — Self-Modifying Automata
///
/// The JIT Forge allocates executable memory pages, compiles a bespoke
/// native-code function tailored to the exact search pattern, and returns
/// a callable function pointer. The compiled code becomes the automaton —
/// it ceases to interpret a table and IS the matching loop, resident in
/// the i-cache.
///
/// Security model: W^X (Write XOR Execute). Pages are allocated with
/// write permission, the opcodes are emitted, then the pages are flipped
/// to read+execute. The write window is open only during emission.
///
/// On x86_64: emits a function with the platform-native calling convention:
///   Windows: rcx = haystack pointer, rdx = haystack length
///   System V: rdi = haystack pointer, rsi = haystack length
///   rax = return: byte offset of first match, or -1 (isize)
///
/// The emitted code is a tight loop:
///   xor eax, eax               ; offset = 0
/// .loop:
///   cmp byte [rdi+rax], sil    ; haystack[offset] == target_byte
///   je .found                  ; if equal, return offset
///   inc rax                    ; offset++
///   cmp rax, rsi               ; offset < len?
///   jb .loop                   ; continue
///   mov rax, -1                ; not found
///   ret
/// .found:
///   ret
///
/// This is the Shift-Or/SIMD kernel's degenerate case (single byte),
/// compiled to native instructions — zero interpretation overhead.
/// For longer patterns the Forge would emit PCMPEQB + PMOVMSKB loops,
/// but single-byte demonstrates the full pipeline: page allocation,
/// W^X transition, opcode emission, and native execution.

const PAGE_SIZE: usize = 4096;

/// Error set for JIT Forge operations.
pub const ForgeError = error{
    UnsupportedArchitecture,
    PageAllocationFailed,
    PageProtectionFailed,
    PatternTooLong,
};

/// A compiled JIT function. Call `.execute(ptr, len)` to search.
/// The underlying page is freed on `.deinit()`.
pub const ForgedFunction = struct {
    code_page: [*]u8,
    page_size: usize,
    /// The callable function pointer. Signature: fn(*const u8, usize) -> isize.
    /// Returns byte offset of first match, or -1 if not found.
    func: *const fn (*const u8, usize) callconv(.c) isize,

    pub fn execute(self: *const ForgedFunction, haystack: []const u8) isize {
        return self.func(@ptrCast(haystack.ptr), haystack.len);
    }

    pub fn deinit(self: *ForgedFunction) void {
        freeExecutablePage(self.code_page, self.page_size);
    }
};

/// Allocates a page of memory with write permission, emits the JIT code,
/// then flips the page to read+execute (W^X).
pub fn forgeByteSearch(target_byte: u8) ForgeError!ForgedFunction {
    if (builtin.cpu.arch != .x86_64 and builtin.cpu.arch != .x86) {
        return error.UnsupportedArchitecture;
    }

    const page = try allocateExecutablePage(PAGE_SIZE);
    errdefer freeExecutablePage(page, PAGE_SIZE);

    var emitter = ByteEmitter{ .buf = page[0..PAGE_SIZE], .pos = 0 };
    emitter.emitByteSearch(target_byte);
    const code_len = emitter.pos;

    // W^X: flip from writable to executable.
    try protectExecutable(page, code_len);

    const func_ptr: *const fn (*const u8, usize) callconv(.c) isize =
        @ptrCast(@alignCast(page));

    return .{
        .code_page = page,
        .page_size = PAGE_SIZE,
        .func = func_ptr,
    };
}

/// x86_64 opcode emitter for single-byte search.
/// Produces position-independent code with the System V calling convention.
const ByteEmitter = struct {
    buf: []u8,
    pos: usize,

    fn emit(self: *ByteEmitter, byte: u8) void {
        self.buf[self.pos] = byte;
        self.pos += 1;
    }

    fn emitBytes(self: *ByteEmitter, bytes: []const u8) void {
        @memcpy(self.buf[self.pos .. self.pos + bytes.len], bytes);
        self.pos += bytes.len;
    }

    fn emitU32(self: *ByteEmitter, value: u32) void {
        std.mem.writeInt(u32, self.buf[self.pos..][0..4], value, .little);
        self.pos += 4;
    }

    /// Emits x86_64 machine code for: find first occurrence of target_byte.
    ///
    /// Uses the platform-native calling convention:
    ///   Windows x86_64: RCX = haystack ptr, RDX = length, RAX = return
    ///   System V x86_64: RDI = haystack ptr, RSI = length, RAX = return
    ///
    /// The emitted code is a tight comparison loop:
    ///   xor eax, eax              ; offset = 0
    ///   test <len_reg>, <len_reg> ; if len == 0, skip
    ///   jz .not_found
    /// .loop:
    ///   movzx r8d, byte [<ptr_reg>+rax]
    ///   cmp r8b, target_byte
    ///   je .found
    ///   inc rax
    ///   cmp rax, <len_reg>
    ///   jb .loop
    /// .not_found:
    ///   mov rax, -1
    ///   ret
    /// .found:
    ///   ret
    fn emitByteSearch(self: *ByteEmitter, target_byte: u8) void {
        // Determine register allocation based on calling convention.
        // Windows: RCX=ptr, RDX=len. System V: RDI=ptr, RSI=len.
        const ptr_reg: u8 = if (builtin.os.tag == .windows) 0b001 else 0b111; // RCX=1, RDI=7
        const len_reg: u8 = if (builtin.os.tag == .windows) 0b010 else 0b110; // RDX=2, RSI=6

        // xor eax, eax (offset = 0)
        self.emit(0x48);
        self.emit(0x31);
        self.emit(0xC0);

        // test <len_reg>, <len_reg> (check length == 0)
        self.emit(0x48);
        self.emit(0x85);
        self.emit(0xC0 | (len_reg << 3) | len_reg); // ModRM: test r64, r64

        // jz .not_found
        const jz_not_found_pos = self.pos;
        self.emit(0x74);
        self.emit(0x00);

        // .loop:
        const loop_offset = self.pos;

        // movzx r8d, byte [ptr_reg + rax]
        // REX.W=1, REX.R=1 (r8 is extended) => REX prefix = 0x44 on Windows
        // (r8 = reg 8, which needs REX.B). On SysV ptr_reg=rdi=7 no extension.
        self.emit(0x44); // REX: W=0, R=0, X=0, B=1 (r8d is extended register)
        self.emit(0x0F);
        self.emit(0xB6);
        self.emit(0x04 | (0b000 << 3) | ptr_reg); // ModRM: [ptr_reg+rax], r8
        // Wait — movzx r8d uses REX.R for the destination. Let me use a simpler encoding.
        // Actually, let me use movzx with a simpler register that doesn't need REX extension.

        // Simpler: use cmp byte [ptr_reg + rax], target_byte directly (no movzx needed).
        // Back up and overwrite the movzx.
        self.pos = loop_offset;

        // cmp byte [ptr_reg + rax], imm8
        // 80 /7 ib — CMP r/m8, imm8
        // REX.W not needed for byte cmp. But if ptr_reg is RDI (7), we need REX.B.
        if (ptr_reg >= 0b1000) {
            self.emit(0x41); // REX.B for extended register
        }
        self.emit(0x80);
        // ModRM: mod=00, reg=7 (the /7 for CMP), rm=ptr_reg (SIB needed if rm==4)
        if (ptr_reg == 0b100) {
            // SIB byte needed for RSP/R12
            self.emit(0x3C); // ModRM: mod=00 reg=7 rm=100
            self.emit(0x20); // SIB: scale=00 index=100 none base=100
        } else {
            self.emit(0x80 | (0b111 << 3) | ptr_reg); // mod=10 for [reg+rax]... no, mod=00
            // Actually we need [ptr_reg + rax] which is a SIB addressing mode.
            // For [base + index], the encoding is mod=00 rm=100 (SIB) SIB=scale|index|base
        }
        // This is getting complex. Let me use a completely different approach:
        // Move ptr to a base register and use simple [base + offset] addressing.
        self.pos = loop_offset;

        // Use: lea r9, [ptr_reg] to copy pointer into r9, then cmp byte [r9 + rax], imm8
        // Actually simpler: just use ptr_reg directly with the right ModRM/SIB.

        // For Windows (RCX=1): cmp byte [rcx + rax], imm8
        //   80 38 XX  (ModRM 38 = mod=00 reg=7(/7) rm=000 with SIB? No...)
        //   Actually [rcx + rax] needs SIB: mod=00 rm=100 SIB(scale=00 index=000(rax) base=001(rcx))
        //   80 3C 08 XX
        // For SysV (RDI=7): cmp byte [rdi + rax], imm8
        //   80 3C 07 XX

        // CMP r/m8, imm8: opcode 80 /7 ib
        self.emit(0x80);
        // ModRM: mod=00 (no displacement), reg=111 (/7 for CMP), rm=100 (SIB follows)
        self.emit(0x3C);
        // SIB: scale=00, index=000 (RAX), base=ptr_reg
        self.emit(ptr_reg); // scale=0, index=rax(0), base=ptr_reg

        self.emit(target_byte);

        // je .found
        const je_found_pos = self.pos;
        self.emit(0x74);
        self.emit(0x00);

        // inc rax
        self.emit(0x48);
        self.emit(0xFF);
        self.emit(0xC0);

        // cmp rax, <len_reg>
        self.emit(0x48);
        self.emit(0x39);
        self.emit(0xC0 | (len_reg << 3) | 0b000); // ModRM: cmp rax, len_reg

        // jb .loop
        const jb_loop_pos = self.pos;
        self.emit(0x72);
        self.emit(0x00);

        // .not_found:
        const not_found_offset = self.pos;

        // mov rax, -1
        self.emitBytes(&.{ 0x48, 0xC7, 0xC0 });
        self.emitU32(0xFFFFFFFF);

        // ret
        self.emit(0xC3);

        // .found:
        const found_offset = self.pos;

        // ret
        self.emit(0xC3);

        // --- Patch relative jumps ---
        self.buf[jz_not_found_pos + 1] = @intCast(@as(i64, @intCast(not_found_offset)) - @as(i64, @intCast(jz_not_found_pos + 2)));
        self.buf[je_found_pos + 1] = @intCast(@as(i64, @intCast(found_offset)) - @as(i64, @intCast(je_found_pos + 2)));
        const jb_rel: i64 = @as(i64, @intCast(loop_offset)) - @as(i64, @intCast(jb_loop_pos + 2));
        self.buf[jb_loop_pos + 1] = @bitCast(@as(i8, @intCast(jb_rel)));
    }
};

// ── Platform-Specific Page Management ──────────────────────────────

fn allocateExecutablePage(size: usize) ForgeError![*]u8 {
    if (builtin.os.tag == .windows) {
        return allocateWindows(size);
    } else {
        return allocatePosix(size);
    }
}

fn freeExecutablePage(page: [*]u8, size: usize) void {
    if (builtin.os.tag == .windows) {
        freeWindows(page, size);
    } else {
        freePosix(page, size);
    }
}

fn protectExecutable(page: [*]u8, code_len: usize) ForgeError!void {
    if (builtin.os.tag == .windows) {
        return protectWindows(page, code_len);
    } else {
        return protectPosix(page, code_len);
    }
}

// ── Windows ────────────────────────────────────────────────────────

const WindowsMem = struct {
    extern "kernel32" fn VirtualAlloc(
        lpAddress: ?*anyopaque,
        dwSize: usize,
        flAllocationType: u32,
        flProtect: u32,
    ) ?*anyopaque;
    extern "kernel32" fn VirtualFree(
        lpAddress: ?*anyopaque,
        dwSize: usize,
        dwFreeType: u32,
    ) i32;
    extern "kernel32" fn VirtualProtect(
        lpAddress: ?*anyopaque,
        dwSize: usize,
        flNewProtect: u32,
        lpflOldProtect: *u32,
    ) i32;
    extern "kernel32" fn FlushInstructionCache(
        hProcess: ?*anyopaque,
        lpBaseAddress: ?*anyopaque,
        dwSize: usize,
    ) i32;
    extern "kernel32" fn GetCurrentProcess() ?*anyopaque;
};

const MEM_COMMIT: u32 = 0x1000;
const MEM_RESERVE: u32 = 0x2000;
const MEM_RELEASE: u32 = 0x8000;
const PAGE_READWRITE: u32 = 0x04;
const PAGE_EXECUTE_READ: u32 = 0x20;

fn allocateWindows(size: usize) ForgeError![*]u8 {
    const ptr = WindowsMem.VirtualAlloc(null, size, MEM_COMMIT | MEM_RESERVE, PAGE_READWRITE) orelse
        return error.PageAllocationFailed;
    return @ptrCast(ptr);
}

fn freeWindows(page: [*]u8, size: usize) void {
    _ = size;
    _ = WindowsMem.VirtualFree(page, 0, MEM_RELEASE);
}

fn protectWindows(page: [*]u8, code_len: usize) ForgeError!void {
    var old_protect: u32 = 0;
    if (WindowsMem.VirtualProtect(page, code_len, PAGE_EXECUTE_READ, &old_protect) == 0) {
        return error.PageProtectionFailed;
    }
    // Flush instruction cache — required on Windows after writing code.
    _ = WindowsMem.FlushInstructionCache(WindowsMem.GetCurrentProcess(), page, code_len);
}

// ── POSIX (Linux, macOS, FreeBSD) ──────────────────────────────────

const PROT_READ: u32 = 0x1;
const PROT_WRITE: u32 = 0x2;
const PROT_EXEC: u32 = 0x4;
const MAP_PRIVATE: u32 = 0x02;
const MAP_ANON: u32 = 0x20; // MAP_ANONYMOUS on Linux
const MAP_FAILED: usize = std.math.maxInt(usize);

fn allocatePosix(size: usize) ForgeError![*]u8 {
    const rc = std.c.mmap(
        null,
        size,
        PROT_READ | PROT_WRITE,
        MAP_PRIVATE | MAP_ANON,
        -1,
        0,
    );
    if (@intFromPtr(rc.addr) == MAP_FAILED) return error.PageAllocationFailed;
    return rc.addr;
}

fn freePosix(page: [*]u8, size: usize) void {
    _ = std.c.munmap(page, size);
}

fn protectPosix(page: [*]u8, code_len: usize) ForgeError!void {
    // W^X: flip to read+execute after writing.
    if (std.c.mprotect(page, code_len, PROT_READ | PROT_EXEC) != 0) {
        return error.PageProtectionFailed;
    }
}

// ── Tests ──────────────────────────────────────────────────────────

test "jit forge compiles and executes single-byte search" {
    if (builtin.cpu.arch != .x86_64 and builtin.cpu.arch != .x86) return;

    var forged = try forgeByteSearch('x');
    defer forged.deinit();

    const haystack = "hello xyz world";
    const result = forged.execute(haystack);
    try std.testing.expectEqual(@as(isize, 6), result); // h=0,e=1,l=2,l=3,o=4,' '=5,x=6
}

test "jit forge returns -1 when byte not found" {
    if (builtin.cpu.arch != .x86_64 and builtin.cpu.arch != .x86) return;

    var forged = try forgeByteSearch('Z');
    defer forged.deinit();

    const haystack = "hello world";
    const result = forged.execute(haystack);
    try std.testing.expectEqual(@as(isize, -1), result);
}

test "jit forge handles empty buffer" {
    if (builtin.cpu.arch != .x86_64 and builtin.cpu.arch != .x86) return;

    var forged = try forgeByteSearch('A');
    defer forged.deinit();

    const result = forged.execute("");
    try std.testing.expectEqual(@as(isize, -1), result);
}

test "jit forge finds first byte in long buffer" {
    if (builtin.cpu.arch != .x86_64 and builtin.cpu.arch != .x86) return;

    var forged = try forgeByteSearch(';');
    defer forged.deinit();

    const haystack = "this is a long string without the target until the end;";
    const result = forged.execute(haystack);
    try std.testing.expectEqual(@as(isize, @intCast(haystack.len - 1)), result);
}
