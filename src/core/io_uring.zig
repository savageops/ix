const std = @import("std");
const builtin = @import("builtin");

/// P16: OS Annihilation & Kernel-Bypass I/O — io_uring implementation.
///
/// On Linux 5.1+, io_uring provides zero-syscall I/O submission via
/// IORING_SETUP_SQPOLL mode. The kernel polls the submission queue
/// from a dedicated kernel thread — no `io_uring_enter()` syscall
/// needed per submission. Pre-registered buffers (IORING_OP_READ_FIXED)
/// eliminate per-I/O buffer allocation.
///
/// This module is compiled only on Linux. On other platforms it is a
/// no-op stub — the scan loop falls back to `std.Io.File.readStreaming`.
///
/// Thread-local instances are lazily initialized per scan worker, giving
/// each worker its own SQ/CQ ring with zero cross-thread contention.

pub const supported = builtin.os.tag == .linux;

pub const IoUring = if (supported) IoUringImpl else IoUringStub;

const IoUringStub = struct {
    pub fn init(_: std.mem.Allocator) !IoUringStub {
        return .{};
    }
    pub fn deinit(_: *IoUringStub) void {}
    pub fn submitRead(_: *IoUringStub, _: std.Io.File, _: []u8, _: u64) !u32 {
        return error.UnsupportedPlatform;
    }
    pub fn pollCompletion(_: *IoUringStub) !?Completion {
        return null;
    }
};

pub const Completion = struct {
    user_data: u64,
    result: i32,
};

// io_uring constants (Linux kernel ABI)
const IORING_OFF_SQ_RING: u64 = 0;
const IORING_OFF_CQ_RING: u64 = 0x8000000;
const IORING_OFF_SQES: u64 = 0x10000000;

const IORING_ENTER_GETEVENTS: u32 = 1;

const IORING_OP_READ_FIXED: u8 = 5;

// io_uring_register opcodes
const IORING_REGISTER_BUFFERS: u32 = 0;

// Maximum pre-registered buffers per ring instance.
const MAX_FIXED_BUFFERS: usize = 4;

const SQE_SIZE: usize = 64;
const CQE_SIZE: usize = 16;

// iovec struct for io_uring_register
const iovec = extern struct {
    iov_base: *anyopaque,
    iov_len: usize,
};

// io_uring_params struct (kernel ABI)
const io_uring_params = extern struct {
    sq_entries: u32,
    cq_entries: u32,
    sq_off: extern struct {
        head: u32,
        tail: u32,
        ring_mask: u32,
        ring_entries: u32,
        flags: u32,
        dropped: u32,
        array: u32,
        resv1: u32,
        resv2: u64,
    },
    cq_off: extern struct {
        head: u32,
        tail: u32,
        ring_mask: u32,
        ring_entries: u32,
        overflow: u32,
        cqes: u32,
        flags: u32,
        resv1: u32,
        resv2: u64,
    },
    flags: u32,
    resv: [3]u32,
};

// SQE (submission queue entry) — 64 bytes
const io_uring_sqe = extern struct {
    opcode: u8,
    flags: u8,
    ioprio: u16,
    fd: i32,
    off: u64,
    addr: u64,
    len: u32,
    op_flags: u32,
    user_data: u64,
    buf_index: u16,
    personality: u16,
    splice_fd_in: i32,
    addr3: u64,
    pad: [1]u64,
};

// CQE (completion queue entry) — 16 bytes
const io_uring_cqe = extern struct {
    user_data: u64,
    res: i32,
    flags: u32,
};

const IoUringImpl = struct {
    fd: i32 = -1,
    sq_ring_ptr: [*]volatile u8 = undefined,
    cq_ring_ptr: [*]volatile u8 = undefined,
    sqes_ptr: [*]volatile io_uring_sqe = undefined,
    sq_ring_sz: usize = 0,
    cq_ring_sz: usize = 0,
    sqes_sz: usize = 0,
    sq_head_off: u32 = 0,
    sq_tail_off: u32 = 0,
    sq_mask_off: u32 = 0,
    sq_array_off: u32 = 0,
    cq_head_off: u32 = 0,
    cq_tail_off: u32 = 0,
    cq_mask_off: u32 = 0,
    cq_cqes_off: u32 = 0,
    sq_mask: u32 = 0,
    cq_mask: u32 = 0,
    sqpoll_enabled: bool = false,
    // P16: Pre-registered fixed buffers for IORING_OP_READ_FIXED.
    fixed_buffers: [MAX_FIXED_BUFFERS]?[]u8 = .{null} ** MAX_FIXED_BUFFERS,
    fixed_buffer_count: usize = 0,

    pub fn init(allocator: std.mem.Allocator) !IoUringImpl {
        _ = allocator;
        var params = std.mem.zeroes(io_uring_params);

        // IORING_SETUP_SQPOLL = (1 << 1) — kernel polls SQ, no enter() syscall
        params.flags = 1 << 1;

        const entries: u32 = 32;

        // Use stdlib wrapper with ptrCast for local vs stdlib params struct compat.
        const fd_raw = std.os.linux.io_uring_setup(entries, @ptrCast(&params));
        const fd: i32 = @intCast(@as(isize, @bitCast(fd_raw)));
        var self = IoUringImpl{ .fd = fd, .sqpoll_enabled = true };

        if (fd < 0) {
            // SQPOLL requires CAP_SYS_NICE — fall back without it
            params = std.mem.zeroes(io_uring_params);
            const fd2_raw = std.os.linux.io_uring_setup(entries, @ptrCast(&params));
            const fd2: i32 = @intCast(@as(isize, @bitCast(fd2_raw)));
            if (fd2 < 0) return error.IoUringSetupFailed;
            self.fd = fd2;
            self.sqpoll_enabled = false;
            // Re-read params for the non-SQPOLL setup
            // params was filled by the kernel during the syscall
        }

        // mmap the SQ ring
        const sq_ring_sz = params.sq_entries * @sizeOf(u32) + params.sq_off.array;
        self.sq_ring_sz = sq_ring_sz;
        const sq_ring_mmap = std.os.linux.mmap(
            null,
            sq_ring_sz,
            std.os.linux.PROT.READ | std.os.linux.PROT.WRITE,
            .{ .TYPE = .SHARED },
            self.fd,
            IORING_OFF_SQ_RING,
        );
        if (sq_ring_mmap == std.os.linux.MAP.FAILED) {
            _ = std.os.linux.close(@intCast(self.fd));
            return error.MmapFailed;
        }
        self.sq_ring_ptr = @ptrCast(sq_ring_mmap);

        // mmap the CQ ring
        const cq_ring_sz = params.cq_entries * @sizeOf(io_uring_cqe) + params.cq_off.cqes;
        self.cq_ring_sz = cq_ring_sz;
        const cq_ring_mmap = std.os.linux.mmap(
            null,
            cq_ring_sz,
            std.os.linux.PROT.READ | std.os.linux.PROT.WRITE,
            .{ .TYPE = .SHARED },
            self.fd,
            IORING_OFF_CQ_RING,
        );
        if (cq_ring_mmap == std.os.linux.MAP.FAILED) {
            _ = std.os.linux.munmap(@ptrCast(self.sq_ring_ptr), sq_ring_sz);
            _ = std.os.linux.close(@intCast(self.fd));
            return error.MmapFailed;
        }
        self.cq_ring_ptr = @ptrCast(cq_ring_mmap);

        // mmap the SQE array
        const sqes_sz = params.sq_entries * @sizeOf(io_uring_sqe);
        self.sqes_sz = sqes_sz;
        const sqes_mmap = std.os.linux.mmap(
            null,
            sqes_sz,
            std.os.linux.PROT.READ | std.os.linux.PROT.WRITE,
            .{ .TYPE = .SHARED },
            self.fd,
            IORING_OFF_SQES,
        );
        if (sqes_mmap == std.os.linux.MAP.FAILED) {
            _ = std.os.linux.munmap(@ptrCast(self.cq_ring_ptr), cq_ring_sz);
            _ = std.os.linux.munmap(@ptrCast(self.sq_ring_ptr), sq_ring_sz);
            _ = std.os.linux.close(@intCast(self.fd));
            return error.MmapFailed;
        }
        self.sqes_ptr = @ptrCast(sqes_mmap);

        // Store ring offsets and mask
        self.sq_head_off = params.sq_off.head;
        self.sq_tail_off = params.sq_off.tail;
        self.sq_mask_off = params.sq_off.ring_mask;
        self.sq_array_off = params.sq_off.array;
        self.cq_head_off = params.cq_off.head;
        self.cq_tail_off = params.cq_off.tail;
        self.cq_mask_off = params.cq_off.ring_mask;
        self.cq_cqes_off = params.cq_off.cqes;

        // Read the mask values
        self.sq_mask = self.readSqU32(self.sq_mask_off);
        self.cq_mask = self.readCqU32(self.cq_mask_off);

        return self;
    }

    pub fn deinit(self: *IoUringImpl) void {
        if (self.sq_ring_sz > 0) _ = std.os.linux.munmap(@ptrCast(self.sq_ring_ptr), self.sq_ring_sz);
        if (self.cq_ring_sz > 0) _ = std.os.linux.munmap(@ptrCast(self.cq_ring_ptr), self.cq_ring_sz);
        if (self.sqes_sz > 0) _ = std.os.linux.munmap(@ptrCast(self.sqes_ptr), self.sqes_sz);
        if (self.fd >= 0) _ = std.os.linux.close(@intCast(self.fd));
        self.fd = -1;
    }

    fn readSqU32(self: *const IoUringImpl, off: u32) u32 {
        const ptr: *volatile u32 = @ptrCast(@alignCast(self.sq_ring_ptr + off));
        return ptr.*;
    }

    fn writeSqU32(self: *IoUringImpl, off: u32, val: u32) void {
        const ptr: *volatile u32 = @ptrCast(@alignCast(self.sq_ring_ptr + off));
        ptr.* = val;
    }

    fn readCqU32(self: *const IoUringImpl, off: u32) u32 {
        const ptr: *volatile u32 = @ptrCast(@alignCast(self.cq_ring_ptr + off));
        return ptr.*;
    }

    fn writeCqU32(self: *IoUringImpl, off: u32, val: u32) void {
        const ptr: *volatile u32 = @ptrCast(@alignCast(self.cq_ring_ptr + off));
        ptr.* = val;
    }

    /// P16: Register a fixed buffer for IORING_OP_READ_FIXED.
    /// Pre-registers the buffer with the kernel via io_uring_register,
    /// eliminating per-I/O buffer allocation. Returns the buffer index
    /// to use in submitRead's buf_index field.
    pub fn registerFixedBuffer(self: *IoUringImpl, buffer: []u8) !u16 {
        if (self.fixed_buffer_count >= MAX_FIXED_BUFFERS) return error.TooManyFixedBuffers;

        const buf_index = self.fixed_buffer_count;
        self.fixed_buffers[buf_index] = buffer;

        // Build iovec array for all registered buffers (must include all up to count)
        var iovecs: [MAX_FIXED_BUFFERS]iovec = undefined;
        for (0..self.fixed_buffer_count + 1) |i| {
            const buf = self.fixed_buffers[i] orelse break;
            iovecs[i] = .{
                .iov_base = @ptrCast(@constCast(buf.ptr)),
                .iov_len = buf.len,
            };
        }

        // io_uring_register(fd, IORING_REGISTER_BUFFERS, iovecs, nr_bufs)
        // Syscall number 427 on x86_64
        const ret = std.os.linux.io_uring_register(
            self.fd,
            @enumFromInt(IORING_REGISTER_BUFFERS),
            @ptrCast(&iovecs),
            self.fixed_buffer_count + 1,
        );
        if (@as(isize, @bitCast(ret)) < 0) return error.RegisterBuffersFailed;

        self.fixed_buffer_count += 1;
        return @intCast(buf_index);
    }

    /// Submit an IORING_OP_READ_FIXED request using a pre-registered buffer.
    /// The kernel reads directly into the pre-registered buffer at `buf_index`,
    /// eliminating per-I/O buffer allocation. This is the zero-copy path.
    pub fn submitRead(self: *IoUringImpl, file: std.Io.File, buffer: []u8, offset: u64) !u32 {
        const tail = self.readSqU32(self.sq_tail_off);
        const next_tail = (tail + 1) & self.sq_mask;
        const head = self.readSqU32(self.sq_head_off);

        // Check if SQ is full
        if (next_tail == head) return error.SubmissionQueueFull;

        const sqe_index = tail & self.sq_mask;
        const sqe: *volatile io_uring_sqe = @ptrCast(@alignCast(self.sqes_ptr + sqe_index));

        // Determine buffer index: use pre-registered if available, else register on first use.
        var buf_index: u16 = 0;
        if (self.fixed_buffer_count == 0) {
            buf_index = try self.registerFixedBuffer(buffer);
        } else {
            // Find the matching pre-registered buffer.
            var found = false;
            for (0..self.fixed_buffer_count) |i| {
                if (self.fixed_buffers[i]) |fb| {
                    if (fb.ptr == buffer.ptr and fb.len == buffer.len) {
                        buf_index = @intCast(i);
                        found = true;
                        break;
                    }
                }
            }
            if (!found) {
                buf_index = try self.registerFixedBuffer(buffer);
            }
        }

        // Fill the SQE with IORING_OP_READ_FIXED
        sqe.* = std.mem.zeroes(io_uring_sqe);
        sqe.opcode = IORING_OP_READ_FIXED;
        sqe.fd = @intCast(file.handle);
        sqe.off = offset;
        sqe.addr = @intFromPtr(buffer.ptr);
        sqe.len = @intCast(buffer.len);
        sqe.buf_index = buf_index;
        sqe.user_data = sqe_index;

        // Update the SQ array to point to this SQE
        const sq_array: [*]volatile u32 = @ptrCast(@alignCast(self.sq_ring_ptr + self.sq_array_off));
        sq_array[sqe_index] = sqe_index;

        // Memory barrier before updating tail
        asm volatile("" ::: "memory");
        self.writeSqU32(self.sq_tail_off, next_tail);

        // If SQPOLL is not enabled, we need to call io_uring_enter
        if (!self.sqpoll_enabled) {
            _ = std.os.linux.io_uring_enter(self.fd, 1, 1, 0, null);
        }

        return sqe_index;
    }

    /// Poll for a completion. Returns null if no completion is ready.
    pub fn pollCompletion(self: *IoUringImpl) !?Completion {
        const head = self.readCqU32(self.cq_head_off);
        const tail = self.readCqU32(self.cq_tail_off);

        if (head == tail) return null; // No completions

        const cq_index = head & self.cq_mask;
        const cqes: [*]volatile io_uring_cqe = @ptrCast(@alignCast(self.cq_ring_ptr + self.cq_cqes_off));
        const cqe = cqes[cq_index];

        // Advance the CQ head
        asm volatile("" ::: "memory");
        self.writeCqU32(self.cq_head_off, (head + 1) & self.cq_mask);

        return Completion{
            .user_data = cqe.user_data,
            .result = cqe.res,
        };
    }

    /// Submit a read and wait for its completion (blocking).
    pub fn readBlocking(self: *IoUringImpl, file: std.Io.File, buffer: []u8, offset: u64) !i32 {
        _ = try self.submitRead(file, buffer, offset);

        // Wait for completion
        while (true) {
            if (try self.pollCompletion()) |comp| {
                return comp.result;
            }
            // If SQPOLL, the kernel is polling — just spin.
            // If not SQPOLL, we should call io_uring_enter with GETEVENTS.
            if (!self.sqpoll_enabled) {
                _ = std.os.linux.io_uring_enter(self.fd, 0, 1, IORING_ENTER_GETEVENTS, null);
            }
        }
    }
};

/// Returns true if io_uring is available on the current platform.
pub fn isAvailable() bool {
    return supported;
}

/// Creates a thread-local io_uring instance for the calling scan worker.
/// On non-Linux platforms, returns null (caller falls back to std.Io).
pub fn createWorkerRing(allocator: std.mem.Allocator) ?IoUring {
    if (!supported) return null;
    return IoUring.init(allocator) catch null;
}
