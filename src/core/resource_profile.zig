const std = @import("std");

pub const FRAMEWORK_RESOURCE_PERCENT: usize = 5;

const MIB: usize = 1024 * 1024;
const FALLBACK_FRAMEWORK_MEMORY_BYTES: usize = 512 * MIB;

/// Computes the single hardware-relative ceiling used by every IX lane.
/// Integer ceiling preserves one worker on small machines while never making
/// an explicit command option a route around the framework policy.
pub fn threadLimit(available: usize) usize {
    const total = @max(available, 1);
    const quotient = total / 100;
    const remainder = total % 100;
    const scaled = quotient * FRAMEWORK_RESOURCE_PERCENT +
        (remainder * FRAMEWORK_RESOURCE_PERCENT + 99) / 100;
    return @max(@as(usize, 1), @min(total, scaled));
}

/// Applies a requested worker count beneath the framework ceiling. Callers
/// may spend less for tiny work, but no lane or explicit flag may spend more.
pub fn clampThreads(requested: usize, available: usize) usize {
    return @min(@max(requested, 1), threadLimit(available));
}

pub fn memoryPercentCapBytes(physical_memory_bytes: ?usize, percent: usize) ?usize {
    const total = physical_memory_bytes orelse return null;
    if (total == 0 or percent == 0) return if (percent == 0) 0 else null;
    if (percent >= 100) return total;
    return @max(@as(usize, 1), (total / 100) * percent + ((total % 100) * percent) / 100);
}

/// Uses Zig's cross-platform system-memory owner instead of lane-local OS
/// probes so the same policy governs Windows, Linux, BSD, and Darwin builds.
pub fn detectedPhysicalMemoryBytes() ?usize {
    const total = std.process.totalSystemMemory() catch return null;
    if (total == 0) return null;
    return @intCast(@min(total, std.math.maxInt(usize)));
}

/// Returns the allocation budget shared by search, inspect, similar, xo,
/// nexus, and indexd. Detection failure chooses a conservative documented
/// fallback; it never silently removes the ceiling.
pub fn memoryLimitBytes() usize {
    return memoryPercentCapBytes(detectedPhysicalMemoryBytes(), FRAMEWORK_RESOURCE_PERCENT) orelse
        FALLBACK_FRAMEWORK_MEMORY_BYTES;
}

/// A thread-safe accounting allocator makes the framework memory ceiling an
/// allocation-time contract rather than an after-the-fact RSS observation.
/// The child allocator still owns alignment and platform allocation behavior.
pub const CappedAllocator = struct {
    child: std.mem.Allocator,
    limit: usize,
    used: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),

    pub fn init(child: std.mem.Allocator, limit: usize) CappedAllocator {
        return .{ .child = child, .limit = limit };
    }

    pub fn allocator(self: *CappedAllocator) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &vtable };
    }

    pub fn usedBytes(self: *const CappedAllocator) usize {
        return self.used.load(.monotonic);
    }

    fn reserve(self: *CappedAllocator, amount: usize) bool {
        var observed_used = self.used.load(.monotonic);
        while (true) {
            const next = std.math.add(usize, observed_used, amount) catch return false;
            if (next > self.limit) return false;
            if (self.used.cmpxchgWeak(observed_used, next, .monotonic, .monotonic)) |actual| {
                observed_used = actual;
            } else return true;
        }
    }

    fn release(self: *CappedAllocator, amount: usize) void {
        _ = self.used.fetchSub(amount, .monotonic);
    }

    fn alloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
        const self: *CappedAllocator = @ptrCast(@alignCast(ctx));
        if (!self.reserve(len)) return null;
        return self.child.rawAlloc(len, alignment, ret_addr) orelse {
            self.release(len);
            return null;
        };
    }

    fn resize(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
        const self: *CappedAllocator = @ptrCast(@alignCast(ctx));
        if (new_len > memory.len and !self.reserve(new_len - memory.len)) return false;
        if (!self.child.rawResize(memory, alignment, new_len, ret_addr)) {
            if (new_len > memory.len) self.release(new_len - memory.len);
            return false;
        }
        if (new_len < memory.len) self.release(memory.len - new_len);
        return true;
    }

    fn remap(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
        const self: *CappedAllocator = @ptrCast(@alignCast(ctx));
        if (new_len > memory.len and !self.reserve(new_len - memory.len)) return null;
        const result = self.child.rawRemap(memory, alignment, new_len, ret_addr) orelse {
            if (new_len > memory.len) self.release(new_len - memory.len);
            return null;
        };
        if (new_len < memory.len) self.release(memory.len - new_len);
        return result;
    }

    fn free(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
        const self: *CappedAllocator = @ptrCast(@alignCast(ctx));
        self.child.rawFree(memory, alignment, ret_addr);
        self.release(memory.len);
    }

    const vtable: std.mem.Allocator.VTable = .{
        .alloc = alloc,
        .resize = resize,
        .remap = remap,
        .free = free,
    };
};

test "framework thread ceiling applies to defaults and explicit requests" {
    try std.testing.expectEqual(@as(usize, 1), threadLimit(1));
    try std.testing.expectEqual(@as(usize, 1), threadLimit(8));
    try std.testing.expectEqual(@as(usize, 2), threadLimit(32));
    try std.testing.expectEqual(@as(usize, 4), threadLimit(64));
    try std.testing.expectEqual(@as(usize, 2), clampThreads(128, 32));
    try std.testing.expectEqual(@as(usize, 1), clampThreads(1, 32));
}

test "framework memory ceiling is five percent" {
    try std.testing.expectEqual(@as(usize, 512), memoryPercentCapBytes(10 * 1024, FRAMEWORK_RESOURCE_PERCENT).?);
    try std.testing.expect(memoryLimitBytes() > 0);
}

test "capped allocator rejects aggregate allocation above its owner" {
    var capped = CappedAllocator.init(std.testing.allocator, 16);
    const allocator = capped.allocator();
    const first = try allocator.alloc(u8, 12);
    try std.testing.expectError(error.OutOfMemory, allocator.alloc(u8, 5));
    try std.testing.expectEqual(@as(usize, 12), capped.usedBytes());
    allocator.free(first);
    try std.testing.expectEqual(@as(usize, 0), capped.usedBytes());
}
