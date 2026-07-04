const std = @import("std");
const builtin = @import("builtin");

const windows = std.os.windows;

pub const Snapshot = struct {
    available: bool = false,
    current_resident_bytes: u64 = 0,
    peak_resident_bytes: u64 = 0,
};

extern "kernel32" fn K32GetProcessMemoryInfo(
    Process: windows.HANDLE,
    ppsmemCounters: *PROCESS_MEMORY_COUNTERS,
    cb: windows.DWORD,
) callconv(.winapi) windows.BOOL;

const PROCESS_MEMORY_COUNTERS = extern struct {
    cb: windows.DWORD,
    PageFaultCount: windows.DWORD,
    PeakWorkingSetSize: windows.SIZE_T,
    WorkingSetSize: windows.SIZE_T,
    QuotaPeakPagedPoolUsage: windows.SIZE_T,
    QuotaPagedPoolUsage: windows.SIZE_T,
    QuotaPeakNonPagedPoolUsage: windows.SIZE_T,
    QuotaNonPagedPoolUsage: windows.SIZE_T,
    PagefileUsage: windows.SIZE_T,
    PeakPagefileUsage: windows.SIZE_T,
};

pub fn currentProcessSnapshot() Snapshot {
    if (builtin.os.tag != .windows) return .{};
    return snapshotForHandle(windows.GetCurrentProcess()) orelse .{};
}

pub fn currentResidentBytes() ?u64 {
    const snapshot = currentProcessSnapshot();
    if (!snapshot.available) return null;
    return snapshot.current_resident_bytes;
}

pub fn snapshotForHandle(handle: windows.HANDLE) ?Snapshot {
    if (builtin.os.tag != .windows) return null;
    var counters = std.mem.zeroes(PROCESS_MEMORY_COUNTERS);
    counters.cb = @sizeOf(PROCESS_MEMORY_COUNTERS);
    if (K32GetProcessMemoryInfo(handle, &counters, @sizeOf(PROCESS_MEMORY_COUNTERS)) == windows.BOOL.FALSE) return null;
    return .{
        .available = true,
        .current_resident_bytes = @intCast(counters.WorkingSetSize),
        .peak_resident_bytes = @intCast(counters.PeakWorkingSetSize),
    };
}

test "current process memory snapshot is explicit about availability" {
    const snapshot = currentProcessSnapshot();
    if (builtin.os.tag == .windows) {
        try std.testing.expect(snapshot.available);
        try std.testing.expect(snapshot.current_resident_bytes > 0);
        try std.testing.expect(snapshot.peak_resident_bytes >= snapshot.current_resident_bytes);
    } else {
        try std.testing.expect(!snapshot.available);
    }
}
