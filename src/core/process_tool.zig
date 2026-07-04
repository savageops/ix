const std = @import("std");
const builtin = @import("builtin");
const catalog = @import("catalog.zig");
const generation = @import("generation.zig");
const indexd = @import("indexd.zig");
const process_memory = @import("process_memory.zig");
const state_dir = @import("state_dir.zig");

const windows = std.os.windows;

extern "kernel32" fn OpenProcess(
    dwDesiredAccess: windows.DWORD,
    bInheritHandle: windows.BOOL,
    dwProcessId: windows.DWORD,
) callconv(.winapi) ?windows.HANDLE;

extern "kernel32" fn CloseHandle(hObject: windows.HANDLE) callconv(.winapi) windows.BOOL;

extern "kernel32" fn GetProcessTimes(
    hProcess: windows.HANDLE,
    lpCreationTime: *windows.FILETIME,
    lpExitTime: *windows.FILETIME,
    lpKernelTime: *windows.FILETIME,
    lpUserTime: *windows.FILETIME,
) callconv(.winapi) windows.BOOL;

const PROCESS_QUERY_LIMITED_INFORMATION: windows.DWORD = 0x0000_1000;
const DEFAULT_MEMORY_LIMIT_BYTES: usize = 4 * 1024 * 1024 * 1024;
const MARKER_READ_LIMIT: usize = 4096;

pub const Action = enum {
    status,
    cleanup,
};

pub const Request = struct {
    action: Action = .status,
    json: bool = false,
    dry_run: bool = false,
    state_dir_override: ?[]const u8 = null,
};

pub const MarkerKind = enum {
    index_live,
    indexd_heartbeat,
};

pub const EntryStatus = enum {
    live,
    stale,
    malformed,
};

pub const CleanupAction = enum {
    none,
    delete_marker,
};

pub const ProcessEntry = struct {
    kind: MarkerKind,
    marker_path: []const u8,
    root: []const u8,
    fingerprint_text: []const u8,
    command: []const u8,
    mode: ?[]const u8,
    pid: u32,
    process_start_ns: i128,
    created_ns: i128,
    epoch: ?generation.Epoch,
    status: EntryStatus,
    cleanup_action: CleanupAction,
    cleanup_result: ?[]const u8,
    memory_bytes: ?u64,
    memory_limit_bytes: u64,
    warning: ?[]const u8,

    fn deinit(self: ProcessEntry, allocator: std.mem.Allocator) void {
        allocator.free(self.marker_path);
        allocator.free(self.root);
        allocator.free(self.fingerprint_text);
        allocator.free(self.command);
        if (self.mode) |value| allocator.free(value);
        if (self.cleanup_result) |value| allocator.free(value);
        if (self.warning) |value| allocator.free(value);
    }
};

pub const Report = struct {
    state_dir: []const u8,
    entries: []ProcessEntry,
    live_count: usize,
    stale_count: usize,
    malformed_count: usize,
    warning_count: usize,
    cleanup_removed_count: usize,

    pub fn deinit(self: Report, allocator: std.mem.Allocator) void {
        allocator.free(self.state_dir);
        for (self.entries) |entry| entry.deinit(allocator);
        allocator.free(self.entries);
    }
};

pub fn run(io: std.Io, allocator: std.mem.Allocator, request: Request) !Report {
    const owned_state_dir = if (request.state_dir_override) |override|
        try allocator.dupe(u8, override)
    else
        try state_dir.resolveStateDir(allocator);
    errdefer allocator.free(owned_state_dir);

    const memory_limit_bytes = resolveMemoryLimitBytes();
    const roots_dir = try std.fs.path.join(allocator, &.{ owned_state_dir, "index", "roots" });
    defer allocator.free(roots_dir);

    var entries = std.ArrayList(ProcessEntry).empty;
    defer if (@errorReturnTrace() != null) {
        for (entries.items) |entry| entry.deinit(allocator);
        entries.deinit(allocator);
    };

    const dir = std.Io.Dir.cwd().openDir(io, roots_dir, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => {
            return .{
                .state_dir = owned_state_dir,
                .entries = try allocator.alloc(ProcessEntry, 0),
                .live_count = 0,
                .stale_count = 0,
                .malformed_count = 0,
                .warning_count = 0,
                .cleanup_removed_count = 0,
            };
        },
        else => return err,
    };
    defer dir.close(io);

    var iterator = dir.iterate();
    while (try iterator.next(io)) |entry| {
        if (entry.kind != .directory) continue;
        try collectRootEntries(io, allocator, &entries, roots_dir, entry.name, memory_limit_bytes, request);
    }

    var live_count: usize = 0;
    var stale_count: usize = 0;
    var malformed_count: usize = 0;
    var warning_count: usize = 0;
    var cleanup_removed_count: usize = 0;
    for (entries.items) |entry| {
        switch (entry.status) {
            .live => live_count += 1,
            .stale => stale_count += 1,
            .malformed => malformed_count += 1,
        }
        if (entry.warning != null) warning_count += 1;
        if (entry.cleanup_result) |result| {
            if (std.mem.eql(u8, result, "deleted")) cleanup_removed_count += 1;
        }
    }

    return .{
        .state_dir = owned_state_dir,
        .entries = try entries.toOwnedSlice(allocator),
        .live_count = live_count,
        .stale_count = stale_count,
        .malformed_count = malformed_count,
        .warning_count = warning_count,
        .cleanup_removed_count = cleanup_removed_count,
    };
}

pub fn writeReport(writer: anytype, report: Report, json: bool) !void {
    if (json) return writeReportJson(writer, report);
    try writer.print(
        "IX process {s}\nlive={d} stale={d} malformed={d} warnings={d} removed={d}\n",
        .{ report.state_dir, report.live_count, report.stale_count, report.malformed_count, report.warning_count, report.cleanup_removed_count },
    );
    for (report.entries) |entry| {
        try writer.print(
            "{s} {s} pid={d} root={s}",
            .{ markerKindText(entry.kind), entryStatusText(entry.status), entry.pid, entry.root },
        );
        if (entry.memory_bytes) |memory_bytes| {
            try writer.print(" memory_mb={d}", .{@divFloor(memory_bytes, 1024 * 1024)});
        }
        if (entry.epoch) |epoch| {
            try writer.print(" epoch={d}", .{epoch});
        }
        if (entry.warning) |warning| {
            try writer.print(" warning={s}", .{warning});
        }
        if (entry.cleanup_result) |cleanup_result| {
            try writer.print(" cleanup={s}", .{cleanup_result});
        }
        try writer.print(" marker={s}\n", .{entry.marker_path});
    }
}

fn writeReportJson(writer: anytype, report: Report) !void {
    try writer.writeAll("{\"cmd\":\"process\",\"state_dir\":");
    try writeJsonString(writer, report.state_dir);
    try writer.print(",\"live\":{},\"stale\":{},\"malformed\":{},\"warnings\":{},\"removed\":{},\"entries\":[", .{
        report.live_count,
        report.stale_count,
        report.malformed_count,
        report.warning_count,
        report.cleanup_removed_count,
    });
    for (report.entries, 0..) |entry, index| {
        if (index > 0) try writer.writeAll(",");
        try writer.writeAll("{\"kind\":");
        try writeJsonString(writer, markerKindText(entry.kind));
        try writer.writeAll(",\"status\":");
        try writeJsonString(writer, entryStatusText(entry.status));
        try writer.writeAll(",\"command\":");
        try writeJsonString(writer, entry.command);
        try writer.writeAll(",\"marker_path\":");
        try writeJsonString(writer, entry.marker_path);
        try writer.writeAll(",\"root\":");
        try writeJsonString(writer, entry.root);
        try writer.writeAll(",\"fingerprint\":");
        try writeJsonString(writer, entry.fingerprint_text);
        try writer.print(",\"pid\":{},\"process_start_ns\":{},\"created_ns\":{},\"memory_limit_bytes\":{}", .{
            entry.pid,
            entry.process_start_ns,
            entry.created_ns,
            entry.memory_limit_bytes,
        });
        try writer.writeAll(",\"epoch\":");
        if (entry.epoch) |epoch| try writer.print("{}", .{epoch}) else try writer.writeAll("null");
        try writer.writeAll(",\"memory_bytes\":");
        if (entry.memory_bytes) |memory_bytes| try writer.print("{}", .{memory_bytes}) else try writer.writeAll("null");
        try writer.writeAll(",\"mode\":");
        if (entry.mode) |mode| try writeJsonString(writer, mode) else try writer.writeAll("null");
        try writer.writeAll(",\"warning\":");
        if (entry.warning) |warning| try writeJsonString(writer, warning) else try writer.writeAll("null");
        try writer.writeAll(",\"cleanup_action\":");
        try writeJsonString(writer, cleanupActionText(entry.cleanup_action));
        try writer.writeAll(",\"cleanup_result\":");
        if (entry.cleanup_result) |cleanup_result| try writeJsonString(writer, cleanup_result) else try writer.writeAll("null");
        try writer.writeAll("}");
    }
    try writer.writeAll("]}\n");
}

fn collectRootEntries(
    io: std.Io,
    allocator: std.mem.Allocator,
    entries: *std.ArrayList(ProcessEntry),
    roots_dir: []const u8,
    fingerprint_text: []const u8,
    memory_limit_bytes: u64,
    request: Request,
) !void {
    const index_dir = try std.fs.path.join(allocator, &.{ roots_dir, fingerprint_text });
    defer allocator.free(index_dir);
    const fingerprint = std.fmt.parseInt(catalog.RootFingerprint, fingerprint_text, 16) catch null;
    const epoch = if (fingerprint) |root_fingerprint|
        readCurrentEpoch(io, allocator, index_dir, root_fingerprint)
    else
        null;

    try maybeAppendMarker(io, allocator, entries, index_dir, fingerprint_text, epoch, "index.live", .index_live, memory_limit_bytes, request);
    try maybeAppendMarker(io, allocator, entries, index_dir, fingerprint_text, epoch, "indexd.heartbeat", .indexd_heartbeat, memory_limit_bytes, request);
}

fn maybeAppendMarker(
    io: std.Io,
    allocator: std.mem.Allocator,
    entries: *std.ArrayList(ProcessEntry),
    index_dir: []const u8,
    fingerprint_text: []const u8,
    epoch: ?generation.Epoch,
    marker_name: []const u8,
    kind: MarkerKind,
    memory_limit_bytes: u64,
    request: Request,
) !void {
    const marker_path = try std.fs.path.join(allocator, &.{ index_dir, marker_name });
    defer allocator.free(marker_path);
    const bytes = std.Io.Dir.cwd().readFileAlloc(io, marker_path, allocator, .limited(MARKER_READ_LIMIT)) catch |err| switch (err) {
        error.FileNotFound => {
            return;
        },
        else => return err,
    };
    defer allocator.free(bytes);

    var entry = try parseMarker(allocator, kind, marker_path, fingerprint_text, epoch, bytes, memory_limit_bytes);
    if (request.action == .cleanup and entry.cleanup_action == .delete_marker) {
        if (request.dry_run) {
            entry.cleanup_result = try allocator.dupe(u8, "would_delete");
        } else {
            std.Io.Dir.cwd().deleteFile(io, entry.marker_path) catch {};
            entry.cleanup_result = try allocator.dupe(u8, "deleted");
        }
    }
    try entries.append(allocator, entry);
}

fn parseMarker(
    allocator: std.mem.Allocator,
    kind: MarkerKind,
    marker_path: []const u8,
    fingerprint_text: []const u8,
    epoch: ?generation.Epoch,
    bytes: []const u8,
    memory_limit_bytes: u64,
) !ProcessEntry {
    var pid: ?u32 = null;
    var process_start_ns: ?i128 = null;
    var created_ns: ?i128 = null;
    var root: ?[]const u8 = null;
    var mode: ?[]const u8 = null;

    var lines = std.mem.splitScalar(u8, bytes, '\n');
    const magic = std.mem.trimEnd(u8, lines.next() orelse "", "\r");
    const valid_magic = switch (kind) {
        .index_live => std.mem.eql(u8, magic, "IXINDEX_LIVE1"),
        .indexd_heartbeat => std.mem.eql(u8, magic, "IXINDEXD1"),
    };

    while (lines.next()) |raw_line| {
        const line = std.mem.trimEnd(u8, raw_line, "\r");
        if (std.mem.startsWith(u8, line, "pid=")) pid = std.fmt.parseInt(u32, line[4..], 10) catch null else if (std.mem.startsWith(u8, line, "process_start_ns=")) process_start_ns = std.fmt.parseInt(i128, line["process_start_ns=".len..], 10) catch null else if (std.mem.startsWith(u8, line, "created_ns=")) created_ns = std.fmt.parseInt(i128, line["created_ns=".len..], 10) catch null else if (std.mem.startsWith(u8, line, "root=")) root = try allocator.dupe(u8, line[5..]) else if (std.mem.startsWith(u8, line, "mode=")) mode = try allocator.dupe(u8, line[5..]);
    }

    const owned_marker_path = try allocator.dupe(u8, marker_path);
    errdefer allocator.free(owned_marker_path);
    const owned_fingerprint_text = try allocator.dupe(u8, fingerprint_text);
    errdefer allocator.free(owned_fingerprint_text);
    const owned_root = if (root) |value| value else try allocator.dupe(u8, "");
    errdefer allocator.free(owned_root);
    const command = try allocator.dupe(u8, switch (kind) {
        .index_live => "search_warm_live",
        .indexd_heartbeat => "indexd_watch",
    });
    errdefer allocator.free(command);

    if (!valid_magic or pid == null or process_start_ns == null or created_ns == null or owned_root.len == 0) {
        return .{
            .kind = kind,
            .marker_path = owned_marker_path,
            .root = owned_root,
            .fingerprint_text = owned_fingerprint_text,
            .command = command,
            .mode = mode,
            .pid = pid orelse 0,
            .process_start_ns = process_start_ns orelse 0,
            .created_ns = created_ns orelse 0,
            .epoch = epoch,
            .status = .malformed,
            .cleanup_action = .delete_marker,
            .cleanup_result = null,
            .memory_bytes = null,
            .memory_limit_bytes = memory_limit_bytes,
            .warning = null,
        };
    }

    const live = processStartMatches(pid.?, process_start_ns.?);
    const memory_bytes = if (live) processMemoryBytes(pid.?) else null;
    const warning = if (memory_bytes != null and memory_bytes.? > memory_limit_bytes)
        try allocator.dupe(u8, "memory_limit_exceeded")
    else
        null;

    return .{
        .kind = kind,
        .marker_path = owned_marker_path,
        .root = owned_root,
        .fingerprint_text = owned_fingerprint_text,
        .command = command,
        .mode = mode,
        .pid = pid.?,
        .process_start_ns = process_start_ns.?,
        .created_ns = created_ns.?,
        .epoch = epoch,
        .status = if (live) .live else .stale,
        .cleanup_action = if (live) .none else .delete_marker,
        .cleanup_result = null,
        .memory_bytes = memory_bytes,
        .memory_limit_bytes = memory_limit_bytes,
        .warning = warning,
    };
}

fn readCurrentEpoch(io: std.Io, allocator: std.mem.Allocator, index_dir: []const u8, fingerprint: catalog.RootFingerprint) ?generation.Epoch {
    const current_manifest_path = std.fs.path.join(allocator, &.{ index_dir, "current.ixgen" }) catch return null;
    defer allocator.free(current_manifest_path);
    const pin = generation.tryPinCurrentGeneration(io, allocator, current_manifest_path, fingerprint) catch return null;
    return if (pin) |value| value.epoch else null;
}

fn resolveMemoryLimitBytes() u64 {
    const value_ptr = std.c.getenv(indexd.MEMORY_LIMIT_ENV) orelse return DEFAULT_MEMORY_LIMIT_BYTES;
    const value = std.mem.span(value_ptr);
    const parsed = std.fmt.parseInt(u64, value, 10) catch return DEFAULT_MEMORY_LIMIT_BYTES / (1024 * 1024);
    return parsed * 1024 * 1024;
}

fn processStartMatches(pid: u32, expected_start_ns: i128) bool {
    return processStartNs(pid) == expected_start_ns;
}

fn processStartNs(pid: u32) ?i128 {
    if (builtin.os.tag != .windows or pid == 0) return null;
    const handle = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, windows.BOOL.FALSE, @intCast(pid)) orelse return null;
    defer _ = CloseHandle(handle);
    var creation: windows.FILETIME = undefined;
    var exit: windows.FILETIME = undefined;
    var kernel: windows.FILETIME = undefined;
    var user: windows.FILETIME = undefined;
    if (GetProcessTimes(handle, &creation, &exit, &kernel, &user) == windows.BOOL.FALSE) return null;
    return fileTimeToUnixNs(creation);
}

fn processMemoryBytes(pid: u32) ?u64 {
    if (builtin.os.tag != .windows or pid == 0) return null;
    const handle = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, windows.BOOL.FALSE, @intCast(pid)) orelse return null;
    defer _ = CloseHandle(handle);
    const snapshot = process_memory.snapshotForHandle(handle) orelse return null;
    return snapshot.current_resident_bytes;
}

fn fileTimeToUnixNs(file_time: windows.FILETIME) i128 {
    const windows_epoch_to_unix_epoch_100ns: i128 = 116_444_736_000_000_000;
    const ticks_100ns = (@as(i128, file_time.dwHighDateTime) << 32) | @as(i128, file_time.dwLowDateTime);
    return (ticks_100ns - windows_epoch_to_unix_epoch_100ns) * 100;
}

fn markerKindText(kind: MarkerKind) []const u8 {
    return switch (kind) {
        .index_live => "index_live",
        .indexd_heartbeat => "indexd_heartbeat",
    };
}

fn entryStatusText(status: EntryStatus) []const u8 {
    return switch (status) {
        .live => "live",
        .stale => "stale",
        .malformed => "malformed",
    };
}

fn cleanupActionText(action: CleanupAction) []const u8 {
    return switch (action) {
        .none => "none",
        .delete_marker => "delete_marker",
    };
}

fn writeJsonString(writer: anytype, value: []const u8) !void {
    try writer.writeByte('"');
    for (value) |byte| switch (byte) {
        '"' => try writer.writeAll("\\\""),
        '\\' => try writer.writeAll("\\\\"),
        '\n' => try writer.writeAll("\\n"),
        '\r' => try writer.writeAll("\\r"),
        '\t' => try writer.writeAll("\\t"),
        else => if (byte < 0x20) {
            try writer.print("\\u{x:0>4}", .{byte});
        } else {
            try writer.writeByte(byte);
        },
    };
    try writer.writeByte('"');
}

test "process tool classifies stale markers from IX state dir" {
    const root = ".zig-cache\\ix-process-tool-status";
    std.Io.Dir.cwd().deleteTree(std.testing.io, root) catch {};
    defer std.Io.Dir.cwd().deleteTree(std.testing.io, root) catch {};

    const marker_dir = try std.fs.path.join(std.testing.allocator, &.{ root, "index", "roots", "0000000000000000000000000000beef" });
    defer std.testing.allocator.free(marker_dir);
    try std.Io.Dir.cwd().createDirPath(std.testing.io, marker_dir);
    const marker_path = try std.fs.path.join(std.testing.allocator, &.{ marker_dir, "indexd.heartbeat" });
    defer std.testing.allocator.free(marker_path);
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{
        .sub_path = marker_path,
        .data = "IXINDEXD1\npid=999999\nprocess_start_ns=1\ncreated_ns=2\nmode=background_watch\nroot=C:/repo\n",
    });

    const report = try run(std.testing.io, std.testing.allocator, .{ .state_dir_override = root });
    defer report.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 1), report.entries.len);
    try std.testing.expectEqual(@as(usize, 1), report.stale_count);
    try std.testing.expectEqualStrings("C:/repo", report.entries[0].root);
    try std.testing.expectEqual(.delete_marker, report.entries[0].cleanup_action);
}

test "process cleanup deletes stale markers" {
    const root = ".zig-cache\\ix-process-tool-cleanup";
    std.Io.Dir.cwd().deleteTree(std.testing.io, root) catch {};
    defer std.Io.Dir.cwd().deleteTree(std.testing.io, root) catch {};

    const marker_dir = try std.fs.path.join(std.testing.allocator, &.{ root, "index", "roots", "0000000000000000000000000000beef" });
    defer std.testing.allocator.free(marker_dir);
    try std.Io.Dir.cwd().createDirPath(std.testing.io, marker_dir);
    const marker_path = try std.fs.path.join(std.testing.allocator, &.{ marker_dir, "index.live" });
    defer std.testing.allocator.free(marker_path);
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{
        .sub_path = marker_path,
        .data = "IXINDEX_LIVE1\npid=999999\nprocess_start_ns=1\ncreated_ns=2\nroot=C:/repo\n",
    });

    const report = try run(std.testing.io, std.testing.allocator, .{
        .action = .cleanup,
        .state_dir_override = root,
    });
    defer report.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 1), report.cleanup_removed_count);
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.cwd().access(std.testing.io, marker_path, .{}));
}
