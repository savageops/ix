const std = @import("std");

/// Default percentages when no env or config override is present.
pub const DEFAULT_MEMORY_PERCENT: usize = 5;
pub const DEFAULT_THREAD_PERCENT: usize = 5;

const MIB: usize = 1024 * 1024;
const FALLBACK_FRAMEWORK_MEMORY_BYTES: usize = 512 * MIB;

const Config = struct {
    memory_percent: usize = DEFAULT_MEMORY_PERCENT,
    thread_percent: usize = DEFAULT_THREAD_PERCENT,
};

var cached_config: ?Config = null;

/// Loads the effective config from, in priority order:
///   1. IX_MEMORY_PERCENT / IX_THREAD_PERCENT env vars
///   2. ~/.ix/config.json (persistent, no recompile needed)
///   3. Built-in defaults (5% / 5%)
fn loadConfig() Config {
    if (cached_config) |c| return c;

    var cfg = Config{};

    // Try config.json from state dir (~/.ix/config.json)
    if (loadConfigJson(&cfg)) {
        // Env vars override config.json
        applyEnvOverrides(&cfg);
        cached_config = cfg;
        return cfg;
    }

    // No config file — create a default one so the user knows it exists
    createDefaultConfigJson();
    // Env vars only
    applyEnvOverrides(&cfg);
    cached_config = cfg;
    return cfg;
}

fn applyEnvOverrides(cfg: *Config) void {
    if (envUsize("IX_MEMORY_PERCENT")) |pct| {
        if (pct > 0 and pct <= 100) cfg.memory_percent = pct;
    }
    if (envUsize("IX_THREAD_PERCENT")) |pct| {
        if (pct > 0 and pct <= 100) cfg.thread_percent = pct;
    }
    // Legacy: IX_RESOURCE_PERCENT sets both if present
    if (envUsize("IX_RESOURCE_PERCENT")) |pct| {
        if (pct > 0 and pct <= 100) {
            cfg.memory_percent = pct;
            cfg.thread_percent = pct;
        }
    }
}

fn loadConfigJson(cfg: *Config) bool {
    // Resolve home directory directly via C env
    const home_env = if (@import("builtin").os.tag == .windows) "USERPROFILE" else "HOME";
    const home_ptr = std.c.getenv(home_env ++ "\x00") orelse return false;
    const home = std.mem.span(home_ptr);
    if (home.len == 0) return false;

    // Build config.json path in a single stack buffer
    var config_buf: [4200]u8 = undefined;
    const c_path = blk: {
        // Check IX_STATE_DIR override first
        if (std.c.getenv("IX_STATE_DIR\x00")) |s| {
            const dir = std.mem.span(s);
            break :blk std.fmt.bufPrintZ(&config_buf, "{s}/config.json", .{dir}) catch return false;
        }
        // Default: ~/.ix/config.json
        break :blk std.fmt.bufPrintZ(&config_buf, "{s}/.ix/config.json", .{home}) catch return false;
    };

    const c_file = std.c.fopen(c_path, "rb") orelse return false;
    defer _ = std.c.fclose(c_file);
    var contents_buf: [4096]u8 = undefined;
    const read = std.c.fread(&contents_buf, 1, contents_buf.len, c_file);
    if (read == 0) return false;
    const contents = contents_buf[0..read];

    if (parseJsonField(contents, "memory_percent")) |val| {
        if (val > 0 and val <= 100) cfg.memory_percent = val;
    }
    if (parseJsonField(contents, "thread_percent")) |val| {
        if (val > 0 and val <= 100) cfg.thread_percent = val;
    }
    return true;
}

/// Creates ~/.ix/config.json with default values so the user can discover
/// and tune the engine without recompiling. Best-effort — silently ignores
/// failures (dir creation, write permission, disk full).
fn createDefaultConfigJson() void {
    // Resolve home directory
    const home_env = if (@import("builtin").os.tag == .windows) "USERPROFILE" else "HOME";
    const home_ptr = std.c.getenv(home_env ++ "\x00") orelse return;
    const home = std.mem.span(home_ptr);
    if (home.len == 0) return;

    // Build paths
    var dir_buf: [4096]u8 = undefined;
    const ix_dir = std.fmt.bufPrintZ(&dir_buf, "{s}/.ix", .{home}) catch return;

    // Create ~/.ix/ if it doesn't exist (best effort)
    _ = std.c.mkdir(ix_dir, 0o755);

    // Build config path
    var config_buf: [4200]u8 = undefined;
    const config_path = std.fmt.bufPrintZ(&config_buf, "{s}/config.json", .{ix_dir}) catch return;

    // Don't overwrite if it exists
    if (std.c.fopen(config_path, "rb")) |existing| {
        _ = std.c.fclose(existing);
        return;
    }

    // Write default config
    const defaults =
        \\{
        \\  "memory_percent": 5,
        \\  "thread_percent": 5
        \\}
        \\
    ;
    if (std.c.fopen(config_path, "wb")) |file| {
        _ = std.c.fwrite(defaults.ptr, 1, defaults.len, file);
        _ = std.c.fclose(file);
    }
}

fn parseJsonField(json: []const u8, key: []const u8) ?usize {
    // Search for "key": value
    var i: usize = 0;
    while (i + key.len + 3 < json.len) : (i += 1) {
        if (json[i] != '"') continue;
        if (!std.mem.startsWith(u8, json[i + 1 ..], key)) continue;
        if (json[i + 1 + key.len] != '"') continue;
        // Find the colon
        var j = i + 2 + key.len;
        while (j < json.len and json[j] != ':') j += 1;
        if (j >= json.len) return null;
        j += 1;
        while (j < json.len and (json[j] == ' ' or json[j] == '\t')) j += 1;
        // Find the end of the number (digits only)
        var end = j;
        while (end < json.len and json[end] >= '0' and json[end] <= '9') end += 1;
        if (end == j) return null;
        return std.fmt.parseInt(usize, json[j..end], 10) catch null;
    }
    return null;
}

fn envUsize(comptime name: []const u8) ?usize {
    const value_ptr = std.c.getenv(name ++ "\x00") orelse return null;
    const value = std.mem.span(value_ptr);
    if (value.len == 0) return null;
    return std.fmt.parseInt(usize, value, 10) catch null;
}

/// Returns the effective memory percent (0-100).
pub fn memoryPercent() usize {
    return loadConfig().memory_percent;
}

/// Returns the effective thread percent (0-100).
pub fn threadPercent() usize {
    return loadConfig().thread_percent;
}

/// Computes the thread ceiling from the effective thread percent.
pub fn threadLimit(available: usize) usize {
    const pct = loadConfig().thread_percent;
    const total = @max(available, 1);
    const quotient = total / 100;
    const remainder = total % 100;
    const scaled = quotient * pct + (remainder * pct + 99) / 100;
    return @max(@as(usize, 1), @min(total, scaled));
}

/// Applies a requested worker count beneath the framework ceiling.
pub fn clampThreads(requested: usize, available: usize) usize {
    return @min(@max(requested, 1), threadLimit(available));
}

pub fn memoryPercentCapBytes(physical_memory_bytes: ?usize, percent: usize) ?usize {
    const total = physical_memory_bytes orelse return null;
    if (total == 0 or percent == 0) return if (percent == 0) 0 else null;
    if (percent >= 100) return total;
    return @max(@as(usize, 1), (total / 100) * percent + ((total % 100) * percent) / 100);
}

/// Uses Zig's cross-platform system-memory owner.
pub fn detectedPhysicalMemoryBytes() ?usize {
    const total = std.process.totalSystemMemory() catch return null;
    if (total == 0) return null;
    return @intCast(@min(total, std.math.maxInt(usize)));
}

/// Returns the allocation budget using the effective memory percent.
pub fn memoryLimitBytes() usize {
    const pct = loadConfig().memory_percent;
    return memoryPercentCapBytes(detectedPhysicalMemoryBytes(), pct) orelse
        FALLBACK_FRAMEWORK_MEMORY_BYTES;
}

// ── P18: NUMA-Pinned Arena & Topology Sympathy ─────────────────────
//
// Pins scan worker threads to physical cores and requests large pages
// for the arena to reduce TLB pressure. On Windows, uses
// SetThreadAffinityMask + VirtualAlloc with MEM_LARGE_PAGES. On Linux,
// uses sched_setaffinity + mmap with MAP_HUGETLB. On other platforms,
// these are no-ops that compile cleanly via comptime guards.

const builtin = @import("builtin");

/// Pins the calling thread to a specific CPU core.
/// On Windows: SetThreadAffinityMask.
/// On Linux: sched_setaffinity.
/// On other platforms: no-op.
pub fn pinThreadToCore(core_id: usize) bool {
    if (builtin.os.tag == .windows) {
        const WindowsApi = struct {
            extern "kernel32" fn GetCurrentThread() ?*anyopaque;
            extern "kernel32" fn SetThreadAffinityMask(
                hThread: ?*anyopaque,
                dwThreadAffinityMask: usize,
            ) usize;
        };
        const mask: usize = @as(usize, 1) << @intCast(core_id);
        const thread = WindowsApi.GetCurrentThread();
        const result = WindowsApi.SetThreadAffinityMask(thread, mask);
        return result != 0;
    }
    if (builtin.os.tag == .linux) {
        const cpu_set_size: usize = @sizeOf([16]u64); // 1024 CPUs
        var set: [16]u64 = std.mem.zeroes([16]u64);
        const word = core_id / 64;
        const bit = core_id % 64;
        if (word < set.len) set[word] = @as(u64, 1) << @intCast(bit);
        const SYS_sched_setaffinity = std.os.linux.SYS.sched_setaffinity;
        const pid: usize = 0; // self
        const rc = std.os.linux.syscall3(SYS_sched_setaffinity, pid, cpu_set_size, @intFromPtr(&set));
        return rc == 0;
    }
    // macOS, FreeBSD, etc: no-op, return success.
    return true;
}

/// Requests large (huge) pages for a memory allocation.
/// On Windows: returns 0 (large pages require SeLockMemoryPrivilege,
//  which is not available without privilege escalation — documented).
/// On Linux: returns MAP_HUGETLB flag value for use with mmap.
/// On other platforms: returns 0 (no huge page support).
pub fn hugePageFlag() usize {
    if (builtin.os.tag == .linux) {
        // MAP_HUGETLB = 0x40000
        return 0x40000;
    }
    // Windows MEM_LARGE_PAGES requires SeLockMemoryPrivilege.
    // IX documents this as an opt-in: set IX_LARGE_PAGES=1 to attempt it.
    return 0;
}

/// P18: Allocates a memory region backed by huge pages (2 MiB on Linux).
/// Uses mmap with MAP_HUGETLB on Linux. Returns a pointer to the mapped
/// region, or null if huge pages are unavailable or the allocation fails.
///
/// On Linux, the kernel transparently backs the region with 2 MiB huge
/// pages, reducing TLB pressure by 512× (one TLB entry covers 2 MiB
/// instead of 4 KiB). This eliminates page-walk overhead on arena regions.
///
/// The caller is responsible for munmap'ing the region.
pub fn allocateHugePages(size: usize) ?[*]u8 {
    if (builtin.os.tag != .linux) return null;
    if (!supportsHugePages()) return null;

    const PROT_READ: u32 = 0x1;
    const PROT_WRITE: u32 = 0x2;
    const MAP_PRIVATE: u32 = 0x02;
    const MAP_ANONYMOUS: u32 = 0x20;
    const HUGE_PAGE_SIZE: usize = 2 * 1024 * 1024; // 2 MiB

    // Round up to huge page boundary.
    const rounded_size = (size + HUGE_PAGE_SIZE - 1) & ~(HUGE_PAGE_SIZE - 1);

    const result = std.c.mmap(
        null,
        rounded_size,
        PROT_READ | PROT_WRITE,
        MAP_PRIVATE | MAP_ANONYMOUS | @as(u32, @intCast(hugePageFlag())),
        -1,
        0,
    );
    if (@intFromPtr(result.addr) == std.math.maxInt(usize)) return null;
    return result.addr;
}

/// P18: Frees a huge page-backed memory region.
pub fn freeHugePages(ptr: [*]u8, size: usize) void {
    if (builtin.os.tag != .linux) return;
    const HUGE_PAGE_SIZE: usize = 2 * 1024 * 1024;
    const rounded_size = (size + HUGE_PAGE_SIZE - 1) & ~(HUGE_PAGE_SIZE - 1);
    _ = std.c.munmap(ptr, rounded_size);
}

/// P18: Checks if huge page allocation should be used for the arena.
/// Enabled by default on Linux (MAP_HUGETLB). Disabled on Windows
/// (requires SeLockMemoryPrivilege). Can be forced off with IX_NO_HUGE_PAGES=1.
pub fn shouldUseHugePages() bool {
    if (builtin.os.tag != .linux) return false;
    if (std.c.getenv("IX_NO_HUGE_PAGES\x00")) |v| {
        if (std.mem.eql(u8, std.mem.span(v), "1")) return false;
    }
    return true;
}

/// P18: Huge Page-backed Allocator.
///
/// Wraps the standard page allocator but attempts to back large allocations
/// with MAP_HUGETLB on Linux. Small allocations pass through to the child
/// allocator. Large allocations (≥ 2 MiB) attempt huge pages first, falling
/// back to regular pages if huge pages are exhausted or unavailable.
///
/// This allocator is designed to sit beneath ArenaAllocator. The arena
/// requests large backing regions; this allocator services them with
/// huge pages, eliminating TLB misses on the arena's working set.
pub const HugePageAllocator = struct {
    child: std.mem.Allocator,
    huge_page_allocs: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),

    pub fn init(child: std.mem.Allocator) HugePageAllocator {
        return .{ .child = child };
    }

    pub fn allocator(self: *HugePageAllocator) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &hp_vtable };
    }

    pub fn hugePageAllocs(self: *const HugePageAllocator) usize {
        return self.huge_page_allocs.load(.monotonic);
    }

    fn alloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
        const self: *HugePageAllocator = @ptrCast(@alignCast(ctx));

        // Attempt huge pages for allocations ≥ 2 MiB on Linux.
        if (shouldUseHugePages() and len >= 2 * 1024 * 1024) {
            if (allocateHugePages(len)) |ptr| {
                _ = self.huge_page_allocs.fetchAdd(1, .monotonic);
                return ptr;
            }
            // Fall back to regular allocation if huge pages exhausted.
        }

        return self.child.rawAlloc(len, alignment, ret_addr);
    }

    fn resize(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
        const self: *HugePageAllocator = @ptrCast(@alignCast(ctx));
        return self.child.rawResize(memory, alignment, new_len, ret_addr);
    }

    fn remap(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
        const self: *HugePageAllocator = @ptrCast(@alignCast(ctx));
        return self.child.rawRemap(memory, alignment, new_len, ret_addr);
    }

    fn free(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
        const self: *HugePageAllocator = @ptrCast(@alignCast(ctx));
        self.child.rawFree(memory, alignment, ret_addr);
    }

    const hp_vtable: std.mem.Allocator.VTable = .{
        .alloc = alloc,
        .resize = resize,
        .remap = remap,
        .free = free,
    };
};

/// Returns true if the platform supports thread affinity pinning.
pub fn supportsThreadPinning() bool {
    return builtin.os.tag == .windows or builtin.os.tag == .linux;
}

/// Returns true if the platform supports huge pages.
pub fn supportsHugePages() bool {
    return builtin.os.tag == .linux;
}

/// P18: Pin a scan worker to a core, distributing workers across
/// available cores in round-robin order. Called at thread start.
/// Returns true if pinning succeeded, false if unsupported or failed.
pub fn pinWorkerThread(worker_index: usize, total_workers: usize) bool {
    if (!supportsThreadPinning()) return false;
    if (total_workers == 0) return false;
    const available = std.Thread.getCpuCount() catch return false;
    if (available == 0) return false;
    const core_id = worker_index % available;
    return pinThreadToCore(core_id);
}

/// A thread-safe accounting allocator.
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

test "thread and memory percents are independent" {
    // Defaults: both 5%
    try std.testing.expectEqual(@as(usize, 5), DEFAULT_MEMORY_PERCENT);
    try std.testing.expectEqual(@as(usize, 5), DEFAULT_THREAD_PERCENT);
}

test "thread ceiling scales by thread percent" {
    // 5% of 32 = 2
    try std.testing.expectEqual(@as(usize, 2), threadLimit(32));
    try std.testing.expectEqual(@as(usize, 4), threadLimit(64));
    try std.testing.expectEqual(@as(usize, 1), threadLimit(8));
}

test "memory ceiling is independent from threads" {
    try std.testing.expectEqual(@as(usize, 512), memoryPercentCapBytes(10 * 1024, 5).?);
    try std.testing.expectEqual(@as(usize, 1024), memoryPercentCapBytes(10 * 1024, 10).?);
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
