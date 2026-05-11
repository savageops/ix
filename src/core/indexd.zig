const std = @import("std");
const builtin = @import("builtin");
const windows = std.os.windows;
const generation = @import("generation.zig");
const usn = @import("usn.zig");

pub const Request = struct {
    root: []const u8,
    foreground: bool = false,
    once: bool = false,
    repair: bool = false,
};

pub const Mode = enum {
    foreground_once,
    foreground_watch,
    background_watch,
    foreground_repair,
};

pub const Config = struct {
    root: []const u8,
    index_dir: []const u8,
    mode: Mode,
    foreground: bool,
    once: bool,
    repair: bool,

    pub fn deinit(self: Config, allocator: std.mem.Allocator) void {
        allocator.free(self.index_dir);
    }
};

pub const RootLock = struct {
    file: std.Io.File,
    path: []const u8,

    pub fn release(self: *RootLock, io: std.Io, allocator: std.mem.Allocator) void {
        self.file.close(io);
        std.Io.Dir.cwd().deleteFile(io, self.path) catch {};
        allocator.free(self.path);
        self.* = undefined;
    }
};

pub const Heartbeat = struct {
    path: []const u8,

    pub fn remove(self: Heartbeat, io: std.Io, allocator: std.mem.Allocator) void {
        std.Io.Dir.cwd().deleteFile(io, self.path) catch {};
        allocator.free(self.path);
    }
};

pub const RunResult = struct {
    config: Config,

    pub fn deinit(self: RunResult, allocator: std.mem.Allocator) void {
        self.config.deinit(allocator);
    }
};

pub const LockState = enum {
    absent,
    held_by_current_process,
    held_by_other_process,
};

pub const IndexDiagnosticsInput = struct {
    root: []const u8,
    manifest: ?generation.GenerationManifestHeader = null,
    generation_count: usize = 0,
    journal_cursor: ?usn.JournalCursor = null,
    lock_state: LockState = .absent,
};

pub const IndexDiagnostics = struct {
    root: []const u8,
    manifest_epoch: ?generation.Epoch,
    manifest_parent_epoch: ?generation.Epoch,
    manifest_segment_count: usize,
    generation_count: usize,
    journal_next_usn: ?usn.USN,
    journal_lowest_valid_usn: ?usn.USN,
    lock_state: LockState,
};

pub fn run(io: std.Io, allocator: std.mem.Allocator, request: Request) !RunResult {
    const config = try buildConfig(allocator, request);
    var lock = try acquireRootLock(io, allocator, config);
    defer lock.release(io, allocator);
    const heartbeat = try writeHeartbeat(io, allocator, config, currentProcessId());
    defer heartbeat.remove(io, allocator);
    if (config.repair) try writeRepairState(io, allocator, config, "operator_requested_reconcile");
    if (config.mode == .foreground_once) try writeBootstrapState(io, allocator, config);
    return .{
        .config = config,
    };
}

pub fn buildIndexDiagnostics(input: IndexDiagnosticsInput) !IndexDiagnostics {
    var manifest_epoch: ?generation.Epoch = null;
    var manifest_parent_epoch: ?generation.Epoch = null;
    var manifest_segment_count: usize = 0;
    if (input.manifest) |manifest| {
        const pin = try generation.ReaderPin.fromHeader(manifest);
        manifest_epoch = pin.epoch;
        manifest_parent_epoch = pin.parent_epoch;
        manifest_segment_count = pin.segment_count;
    }

    return .{
        .root = input.root,
        .manifest_epoch = manifest_epoch,
        .manifest_parent_epoch = manifest_parent_epoch,
        .manifest_segment_count = manifest_segment_count,
        .generation_count = input.generation_count,
        .journal_next_usn = if (input.journal_cursor) |cursor| cursor.next_usn else null,
        .journal_lowest_valid_usn = if (input.journal_cursor) |cursor| cursor.lowest_valid_usn else null,
        .lock_state = input.lock_state,
    };
}

pub fn formatIndexDiagnostics(allocator: std.mem.Allocator, diagnostics: IndexDiagnostics) ![]u8 {
    var text = std.ArrayList(u8).empty;
    errdefer text.deinit(allocator);
    try text.appendSlice(allocator, "IXINDEX_DIAGNOSTICS1\n");
    try appendFormat(&text, allocator, "root={s}\n", .{diagnostics.root});
    try appendOptionalEpoch(&text, allocator, "manifest_epoch", diagnostics.manifest_epoch);
    try appendOptionalEpoch(&text, allocator, "manifest_parent_epoch", diagnostics.manifest_parent_epoch);
    try appendFormat(&text, allocator, "manifest_segment_count={}\n", .{diagnostics.manifest_segment_count});
    try appendFormat(&text, allocator, "generation_count={}\n", .{diagnostics.generation_count});
    try appendOptionalUsn(&text, allocator, "journal_next_usn", diagnostics.journal_next_usn);
    try appendOptionalUsn(&text, allocator, "journal_lowest_valid_usn", diagnostics.journal_lowest_valid_usn);
    try appendFormat(&text, allocator, "lock_state={s}\n", .{lockStateText(diagnostics.lock_state)});
    return text.toOwnedSlice(allocator);
}

pub fn buildConfig(allocator: std.mem.Allocator, request: Request) !Config {
    return .{
        .root = request.root,
        .index_dir = try std.fs.path.join(allocator, &.{ request.root, ".ix", "index" }),
        .mode = modeFor(request),
        .foreground = request.foreground,
        .once = request.once,
        .repair = request.repair,
    };
}

pub fn acquireRootLock(io: std.Io, allocator: std.mem.Allocator, config: Config) !RootLock {
    try std.Io.Dir.cwd().createDirPath(io, config.index_dir);
    const lock_path = try std.fs.path.join(allocator, &.{ config.index_dir, "indexd.lock" });
    errdefer allocator.free(lock_path);
    const file = try std.Io.Dir.cwd().createFile(io, lock_path, .{
        .read = true,
        .truncate = false,
        .lock = .exclusive,
        .lock_nonblocking = true,
    });
    return .{
        .file = file,
        .path = lock_path,
    };
}

pub fn writeHeartbeat(io: std.Io, allocator: std.mem.Allocator, config: Config, pid: u32) !Heartbeat {
    try std.Io.Dir.cwd().createDirPath(io, config.index_dir);
    const heartbeat_path = try std.fs.path.join(allocator, &.{ config.index_dir, "indexd.heartbeat" });
    errdefer allocator.free(heartbeat_path);

    var file = try std.Io.Dir.cwd().createFile(io, heartbeat_path, .{ .truncate = true });
    defer file.close(io);

    var buffer: [256]u8 = undefined;
    var writer = file.writer(io, &buffer);
    try writer.interface.print("IXINDEXD1\npid={}\nmode={s}\nroot={s}\n", .{
        pid,
        modeText(config.mode),
        config.root,
    });
    try writer.interface.flush();

    return .{ .path = heartbeat_path };
}

pub fn writeBootstrapState(io: std.Io, allocator: std.mem.Allocator, config: Config) !void {
    try std.Io.Dir.cwd().createDirPath(io, config.index_dir);
    const bootstrap_path = try std.fs.path.join(allocator, &.{ config.index_dir, "bootstrap.state" });
    defer allocator.free(bootstrap_path);

    var file = try std.Io.Dir.cwd().createFile(io, bootstrap_path, .{ .truncate = true });
    defer file.close(io);

    var buffer: [256]u8 = undefined;
    var writer = file.writer(io, &buffer);
    try writer.interface.print("IXINDEXD_BOOTSTRAP1\nstate=ready\nmode={s}\nroot={s}\n", .{
        modeText(config.mode),
        config.root,
    });
    try writer.interface.flush();
}

pub fn writeRepairState(io: std.Io, allocator: std.mem.Allocator, config: Config, reason: []const u8) !void {
    try std.Io.Dir.cwd().createDirPath(io, config.index_dir);
    const repair_path = try std.fs.path.join(allocator, &.{ config.index_dir, "repair.state" });
    defer allocator.free(repair_path);

    var file = try std.Io.Dir.cwd().createFile(io, repair_path, .{ .truncate = true });
    defer file.close(io);

    var buffer: [256]u8 = undefined;
    var writer = file.writer(io, &buffer);
    try writer.interface.print("IXINDEXD_REPAIR1\nstate=reconcile_requested\nreason={s}\nmode={s}\nroot={s}\n", .{
        reason,
        modeText(config.mode),
        config.root,
    });
    try writer.interface.flush();
}

fn modeFor(request: Request) Mode {
    if (request.repair) return .foreground_repair;
    if (request.foreground and request.once) return .foreground_once;
    if (request.foreground) return .foreground_watch;
    return .background_watch;
}

fn modeText(mode: Mode) []const u8 {
    return switch (mode) {
        .foreground_once => "foreground_once",
        .foreground_watch => "foreground_watch",
        .background_watch => "background_watch",
        .foreground_repair => "foreground_repair",
    };
}

fn lockStateText(state: LockState) []const u8 {
    return switch (state) {
        .absent => "absent",
        .held_by_current_process => "held_by_current_process",
        .held_by_other_process => "held_by_other_process",
    };
}

fn appendOptionalEpoch(text: *std.ArrayList(u8), allocator: std.mem.Allocator, key: []const u8, value: ?generation.Epoch) !void {
    if (value) |epoch| {
        try appendFormat(text, allocator, "{s}={}\n", .{ key, epoch });
    } else {
        try appendFormat(text, allocator, "{s}=none\n", .{key});
    }
}

fn appendOptionalUsn(text: *std.ArrayList(u8), allocator: std.mem.Allocator, key: []const u8, value: ?usn.USN) !void {
    if (value) |cursor_usn| {
        try appendFormat(text, allocator, "{s}={}\n", .{ key, cursor_usn });
    } else {
        try appendFormat(text, allocator, "{s}=none\n", .{key});
    }
}

fn appendFormat(text: *std.ArrayList(u8), allocator: std.mem.Allocator, comptime fmt: []const u8, args: anytype) !void {
    const rendered = try std.fmt.allocPrint(allocator, fmt, args);
    defer allocator.free(rendered);
    try text.appendSlice(allocator, rendered);
}

fn currentProcessId() u32 {
    if (comptime builtin.os.tag == .windows) return windows.GetCurrentProcessId();
    return 0;
}

test "indexd entrypoint preserves hidden request shape" {
    const root = ".zig-cache\\ix-indexd-entrypoint-test";
    std.Io.Dir.cwd().deleteTree(std.testing.io, root) catch {};
    defer std.Io.Dir.cwd().deleteTree(std.testing.io, root) catch {};

    const result = try run(std.testing.io, std.testing.allocator, .{
        .root = root,
        .foreground = true,
        .once = true,
    });
    defer result.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings(root, result.config.root);
    try std.testing.expectEqual(Mode.foreground_once, result.config.mode);
    try std.testing.expect(result.config.foreground);
    try std.testing.expect(result.config.once);
}

test "indexd config owns repo-local index directory" {
    const config = try buildConfig(std.testing.allocator, .{
        .root = "E:\\Workspaces\\ix-zig",
        .repair = true,
    });
    defer config.deinit(std.testing.allocator);

    try std.testing.expectEqual(Mode.foreground_repair, config.mode);
    try std.testing.expect(std.mem.endsWith(u8, config.index_dir, ".ix\\index") or std.mem.endsWith(u8, config.index_dir, ".ix/index"));
}

test "indexd root lock prevents overlapping mutation owner" {
    const root = ".zig-cache\\ix-indexd-lock-test";
    std.Io.Dir.cwd().deleteTree(std.testing.io, root) catch {};
    defer std.Io.Dir.cwd().deleteTree(std.testing.io, root) catch {};

    const config = try buildConfig(std.testing.allocator, .{ .root = root });
    defer config.deinit(std.testing.allocator);

    var first = try acquireRootLock(std.testing.io, std.testing.allocator, config);
    defer first.release(std.testing.io, std.testing.allocator);

    try std.testing.expectError(error.WouldBlock, acquireRootLock(std.testing.io, std.testing.allocator, config));
}

test "indexd heartbeat marker records process ownership" {
    const root = ".zig-cache\\ix-indexd-heartbeat-test";
    std.Io.Dir.cwd().deleteTree(std.testing.io, root) catch {};
    defer std.Io.Dir.cwd().deleteTree(std.testing.io, root) catch {};

    const config = try buildConfig(std.testing.allocator, .{
        .root = root,
        .foreground = true,
        .once = true,
    });
    defer config.deinit(std.testing.allocator);

    const heartbeat = try writeHeartbeat(std.testing.io, std.testing.allocator, config, 42);
    defer heartbeat.remove(std.testing.io, std.testing.allocator);

    var buffer: [256]u8 = undefined;
    const contents = try std.Io.Dir.cwd().readFile(std.testing.io, heartbeat.path, &buffer);
    try std.testing.expect(std.mem.indexOf(u8, contents, "IXINDEXD1") != null);
    try std.testing.expect(std.mem.indexOf(u8, contents, "pid=42") != null);
    try std.testing.expect(std.mem.indexOf(u8, contents, "mode=foreground_once") != null);
}

test "indexd diagnostics render manifest journal and lock state" {
    const root: generation.RootFingerprint = 0x1234;
    const segments = [_]generation.GenerationSegment{
        .{ .kind = .catalog, .relative_path = "catalog.ixcat", .generation = 9 },
        .{ .kind = .postings, .relative_path = "postings.ixpost", .generation = 9 },
    };
    const manifest = generation.makeManifest(root, 9, 8, &segments);
    const cursor = usn.JournalCursor{
        .volume = .{
            .root_fingerprint = root,
            .volume_serial_number = 77,
            .filesystem = .ntfs,
        },
        .usn_journal_id = 99,
        .first_usn = 10,
        .next_usn = 44,
        .lowest_valid_usn = 12,
    };

    const diagnostics = try buildIndexDiagnostics(.{
        .root = "E:\\Workspaces\\ix-zig",
        .manifest = manifest.header,
        .generation_count = 3,
        .journal_cursor = cursor,
        .lock_state = .held_by_current_process,
    });
    const rendered = try formatIndexDiagnostics(std.testing.allocator, diagnostics);
    defer std.testing.allocator.free(rendered);

    try std.testing.expect(std.mem.indexOf(u8, rendered, "IXINDEX_DIAGNOSTICS1") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "manifest_epoch=9") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "manifest_parent_epoch=8") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "manifest_segment_count=2") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "generation_count=3") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "journal_next_usn=44") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "journal_lowest_valid_usn=12") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "lock_state=held_by_current_process") != null);
}

test "indexd diagnostics fail closed for incomplete manifest" {
    var header = generation.GenerationManifestHeader.withRootFingerprint(0x1234);
    header.epoch = 1;
    header.segment_count = 1;

    try std.testing.expectError(error.IncompleteGenerationManifest, buildIndexDiagnostics(.{
        .root = ".",
        .manifest = header,
    }));
}

test "indexd run removes heartbeat and releases lock on return" {
    const root = ".zig-cache\\ix-indexd-cleanup-test";
    std.Io.Dir.cwd().deleteTree(std.testing.io, root) catch {};
    defer std.Io.Dir.cwd().deleteTree(std.testing.io, root) catch {};

    const result = try run(std.testing.io, std.testing.allocator, .{
        .root = root,
        .foreground = true,
        .once = true,
    });
    defer result.deinit(std.testing.allocator);

    const heartbeat_path = try std.fs.path.join(std.testing.allocator, &.{ result.config.index_dir, "indexd.heartbeat" });
    defer std.testing.allocator.free(heartbeat_path);
    var buffer: [8]u8 = undefined;
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.cwd().readFile(std.testing.io, heartbeat_path, &buffer));

    var lock = try acquireRootLock(std.testing.io, std.testing.allocator, result.config);
    lock.release(std.testing.io, std.testing.allocator);
}

test "indexd foreground once writes bootstrap state" {
    const root = ".zig-cache\\ix-indexd-bootstrap-test";
    std.Io.Dir.cwd().deleteTree(std.testing.io, root) catch {};
    defer std.Io.Dir.cwd().deleteTree(std.testing.io, root) catch {};

    const result = try run(std.testing.io, std.testing.allocator, .{
        .root = root,
        .foreground = true,
        .once = true,
    });
    defer result.deinit(std.testing.allocator);

    const bootstrap_path = try std.fs.path.join(std.testing.allocator, &.{ result.config.index_dir, "bootstrap.state" });
    defer std.testing.allocator.free(bootstrap_path);
    var buffer: [256]u8 = undefined;
    const contents = try std.Io.Dir.cwd().readFile(std.testing.io, bootstrap_path, &buffer);

    try std.testing.expect(std.mem.indexOf(u8, contents, "IXINDEXD_BOOTSTRAP1") != null);
    try std.testing.expect(std.mem.indexOf(u8, contents, "state=ready") != null);
    try std.testing.expect(std.mem.indexOf(u8, contents, "mode=foreground_once") != null);
}

test "indexd repair command writes reconcile request marker" {
    const root = ".zig-cache\\ix-indexd-repair-test";
    std.Io.Dir.cwd().deleteTree(std.testing.io, root) catch {};
    defer std.Io.Dir.cwd().deleteTree(std.testing.io, root) catch {};

    const result = try run(std.testing.io, std.testing.allocator, .{
        .root = root,
        .repair = true,
    });
    defer result.deinit(std.testing.allocator);

    const repair_path = try std.fs.path.join(std.testing.allocator, &.{ result.config.index_dir, "repair.state" });
    defer std.testing.allocator.free(repair_path);
    var buffer: [256]u8 = undefined;
    const contents = try std.Io.Dir.cwd().readFile(std.testing.io, repair_path, &buffer);

    try std.testing.expect(std.mem.indexOf(u8, contents, "IXINDEXD_REPAIR1") != null);
    try std.testing.expect(std.mem.indexOf(u8, contents, "state=reconcile_requested") != null);
    try std.testing.expect(std.mem.indexOf(u8, contents, "reason=operator_requested_reconcile") != null);
    try std.testing.expect(std.mem.indexOf(u8, contents, "mode=foreground_repair") != null);
}
