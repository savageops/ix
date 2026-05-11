const std = @import("std");
const builtin = @import("builtin");
const windows = std.os.windows;

pub const Request = struct {
    root: []const u8,
    foreground: bool = false,
    once: bool = false,
};

pub const Mode = enum {
    foreground_once,
    foreground_watch,
    background_watch,
};

pub const Config = struct {
    root: []const u8,
    index_dir: []const u8,
    mode: Mode,
    foreground: bool,
    once: bool,

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

pub fn run(io: std.Io, allocator: std.mem.Allocator, request: Request) !RunResult {
    const config = try buildConfig(allocator, request);
    var lock = try acquireRootLock(io, allocator, config);
    defer lock.release(io, allocator);
    const heartbeat = try writeHeartbeat(io, allocator, config, currentProcessId());
    defer heartbeat.remove(io, allocator);
    if (config.mode == .foreground_once) try writeBootstrapState(io, allocator, config);
    return .{
        .config = config,
    };
}

pub fn buildConfig(allocator: std.mem.Allocator, request: Request) !Config {
    return .{
        .root = request.root,
        .index_dir = try std.fs.path.join(allocator, &.{ request.root, ".ix", "index" }),
        .mode = modeFor(request),
        .foreground = request.foreground,
        .once = request.once,
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

fn modeFor(request: Request) Mode {
    if (request.foreground and request.once) return .foreground_once;
    if (request.foreground) return .foreground_watch;
    return .background_watch;
}

fn modeText(mode: Mode) []const u8 {
    return switch (mode) {
        .foreground_once => "foreground_once",
        .foreground_watch => "foreground_watch",
        .background_watch => "background_watch",
    };
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
    });
    defer config.deinit(std.testing.allocator);

    try std.testing.expectEqual(Mode.background_watch, config.mode);
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
