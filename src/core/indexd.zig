const std = @import("std");
const builtin = @import("builtin");
const windows = std.os.windows;
const catalog = @import("catalog.zig");
const generation = @import("generation.zig");
const postings = @import("postings.zig");
const usn = @import("usn.zig");

extern "kernel32" fn ReadDirectoryChangesW(
    hDirectory: windows.HANDLE,
    lpBuffer: ?*anyopaque,
    nBufferLength: windows.DWORD,
    bWatchSubtree: windows.BOOL,
    dwNotifyFilter: windows.DWORD,
    lpBytesReturned: ?*windows.DWORD,
    lpOverlapped: ?*anyopaque,
    lpCompletionRoutine: ?*anyopaque,
) callconv(.winapi) windows.BOOL;

pub const LIVE_MARKER_NAME = "index.live";
const INDEX_FILE_READ_LIMIT: usize = 16 * 1024 * 1024;
const INDEX_LARGE_SOURCE_FILE_READ_LIMIT: usize = 64 * 1024 * 1024;
const INDEX_LARGE_SOURCE_TOTAL_READ_LIMIT: usize = 384 * 1024 * 1024;

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

pub const LiveMarker = struct {
    path: []const u8,

    pub fn remove(self: LiveMarker, io: std.Io, allocator: std.mem.Allocator) void {
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
    try std.Io.Dir.cwd().createDirPath(io, config.root);
    var lock = try acquireRootLock(io, allocator, config);
    defer lock.release(io, allocator);
    const heartbeat = try writeHeartbeat(io, allocator, config, currentProcessId());
    defer heartbeat.remove(io, allocator);
    if (config.repair) try writeRepairState(io, allocator, config, "operator_requested_reconcile");
    if (config.mode == .foreground_once) try writeBootstrapState(io, allocator, config);
    if (!config.repair) {
        _ = try publishRootGeneration(io, allocator, config.root);
        if (config.mode != .foreground_once) {
            const live = try writeLiveMarker(io, allocator, config);
            defer live.remove(io, allocator);
            holdLiveUntilRootMutation(io, config.root);
        }
    }
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

pub fn writeLiveMarker(io: std.Io, allocator: std.mem.Allocator, config: Config) !LiveMarker {
    try std.Io.Dir.cwd().createDirPath(io, config.index_dir);
    const live_path = try std.fs.path.join(allocator, &.{ config.index_dir, LIVE_MARKER_NAME });
    errdefer allocator.free(live_path);

    var file = try std.Io.Dir.cwd().createFile(io, live_path, .{ .truncate = true });
    defer file.close(io);

    var buffer: [256]u8 = undefined;
    var writer = file.writer(io, &buffer);
    try writer.interface.print("IXINDEX_LIVE1\npid={}\nroot={s}\n", .{ currentProcessId(), config.root });
    try writer.interface.flush();
    return .{ .path = live_path };
}

pub fn publishRootGeneration(io: std.Io, allocator: std.mem.Allocator, root: []const u8) !generation.ReaderPin {
    var files = std.ArrayList(IndexedFile).empty;
    defer {
        for (files.items) |file| file.deinit(allocator);
        files.deinit(allocator);
    }

    try collectIndexFiles(io, allocator, root, &files);
    std.mem.sort(IndexedFile, files.items, {}, lessThanIndexedFilePath);

    const epoch = currentEpoch(io);
    const root_identity = try catalog.identifyRoot(allocator, root);
    defer root_identity.deinit(allocator);

    const catalog_inputs = try allocator.alloc(catalog.CatalogFileInput, files.items.len);
    defer allocator.free(catalog_inputs);
    var postings_inputs = std.ArrayList(postings.PostingsFileInput).empty;
    defer postings_inputs.deinit(allocator);

    for (files.items, 0..) |file, index| {
        const file_id = catalog.makeFileId(@intCast(index));
        catalog_inputs[index] = .{
            .path = file.path,
            .size = file.size,
            .mtime_ns = file.mtime_ns,
            .file_index_or_inode = file.file_index_or_inode,
            .kind = .regular,
            .sample = file.bytes[0..@min(file.bytes.len, 4096)],
            .verify_required = file.verify_required,
        };
        if (!file.verify_required) {
            try postings_inputs.append(allocator, .{
                .file_id = file_id,
                .bytes = file.bytes,
            });
        }
    }

    const catalog_bytes = try catalog.buildCatalogBytes(allocator, root, epoch, catalog_inputs);
    defer allocator.free(catalog_bytes);
    const segment = try postings.buildPostingsSegment(allocator, root_identity.fingerprint, epoch, postings_inputs.items);
    defer segment.deinit(allocator);
    const postings_bytes = try postings.serializePostingsSegment(allocator, segment);
    defer allocator.free(postings_bytes);

    const paths = try generation.buildGenerationPaths(allocator, root, epoch);
    defer paths.deinit(allocator);
    const payloads = [_]generation.SegmentPayload{
        .{ .kind = .catalog, .relative_path = "catalog.ixcat", .bytes = catalog_bytes },
        .{ .kind = .postings, .relative_path = "postings.ixpost", .bytes = postings_bytes },
    };
    return generation.publishGenerationPayloads(io, allocator, paths, root_identity.fingerprint, epoch, null, &payloads);
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

const IndexedFile = struct {
    path: []const u8,
    bytes: []u8,
    size: u64,
    mtime_ns: i128,
    file_index_or_inode: u128 = 0,
    verify_required: bool = false,

    fn deinit(self: IndexedFile, allocator: std.mem.Allocator) void {
        allocator.free(self.path);
        allocator.free(self.bytes);
    }
};

fn collectIndexFiles(io: std.Io, allocator: std.mem.Allocator, root: []const u8, files: *std.ArrayList(IndexedFile)) !void {
    var large_source_bytes: usize = 0;
    try collectIndexFilesWithBudget(io, allocator, root, files, &large_source_bytes);
}

fn collectIndexFilesWithBudget(io: std.Io, allocator: std.mem.Allocator, root: []const u8, files: *std.ArrayList(IndexedFile), large_source_bytes: *usize) !void {
    const dir = std.Io.Dir.cwd().openDir(io, root, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return,
        error.AccessDenied => return,
        else => return err,
    };
    defer dir.close(io);

    var iterator = dir.iterate();
    while (true) {
        const maybe_entry = iterator.next(io) catch |err| switch (err) {
            error.AccessDenied => return,
            else => return err,
        };
        const entry = maybe_entry orelse break;
        if (std.mem.eql(u8, entry.name, ".ix")) continue;
        if (isDefaultHiddenEntry(entry.name)) continue;
        const child_path = try joinPathForward(allocator, root, entry.name);
        switch (entry.kind) {
            .file => try appendIndexedFile(io, allocator, child_path, files, large_source_bytes),
            .directory => {
                try collectIndexFilesWithBudget(io, allocator, child_path, files, large_source_bytes);
                allocator.free(child_path);
            },
            else => allocator.free(child_path),
        }
    }
}

fn appendIndexedFile(io: std.Io, allocator: std.mem.Allocator, path: []const u8, files: *std.ArrayList(IndexedFile), large_source_bytes: *usize) !void {
    var file = std.Io.Dir.cwd().openFile(io, path, .{}) catch |err| switch (err) {
        error.AccessDenied, error.FileNotFound => {
            allocator.free(path);
            return;
        },
        else => return err,
    };
    defer file.close(io);
    const stat = file.stat(io) catch |err| switch (err) {
        error.AccessDenied => {
            allocator.free(path);
            return;
        },
        else => return err,
    };
    const large_source = stat.size <= INDEX_LARGE_SOURCE_FILE_READ_LIMIT and isIndexableLargeSourcePath(path);
    const large_source_allowed = large_source and stat.size <= INDEX_LARGE_SOURCE_TOTAL_READ_LIMIT - large_source_bytes.*;
    if (stat.size > INDEX_FILE_READ_LIMIT and !large_source_allowed) {
        const bytes = try allocator.alloc(u8, 0);
        try files.append(allocator, .{
            .path = path,
            .bytes = bytes,
            .size = stat.size,
            .mtime_ns = stat.mtime.nanoseconds,
            .verify_required = true,
        });
        return;
    }
    const read_limit: usize = if (stat.size > INDEX_FILE_READ_LIMIT) INDEX_LARGE_SOURCE_FILE_READ_LIMIT else INDEX_FILE_READ_LIMIT;
    const bytes = std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(read_limit)) catch |err| switch (err) {
        error.AccessDenied, error.FileNotFound => {
            allocator.free(path);
            return;
        },
        else => return err,
    };
    if (stat.size > INDEX_FILE_READ_LIMIT) large_source_bytes.* += bytes.len;
    try files.append(allocator, .{
        .path = path,
        .bytes = bytes,
        .size = stat.size,
        .mtime_ns = stat.mtime.nanoseconds,
    });
}

const INDEXABLE_LARGE_SOURCE_EXTENSIONS = [_][]const u8{
    ".c",    ".h",       ".cc",  ".hh",  ".cpp",   ".hpp",  ".cxx",    ".hxx",
    ".js",   ".jsx",     ".mjs", ".cjs", ".ts",    ".tsx",  ".go",     ".py",
    ".java", ".cs",      ".kt",  ".kts", ".swift", ".rb",   ".php",    ".scala",
    ".sc",   ".dart",    ".lua", ".r",   ".jl",    ".vue",  ".svelte", ".astro",
    ".mdx",  ".graphql", ".gql", ".sh",  ".bash",  ".zsh",  ".fish",   ".ps1",
    ".psm1", ".psd1",    ".cmd", ".bat", ".m",     ".mm",   ".pl",     ".pm",
    ".erl",  ".hrl",     ".ex",  ".exs", ".clj",   ".cljs", ".cljc",   ".fs",
    ".fsx",  ".vb",      ".hs",  ".lhs", ".ml",    ".mli",  ".nim",    ".cr",
    ".d",    ".v",       ".vh",  ".sv",  ".svh",   ".vhd",  ".vhdl",   ".adb",
    ".ads",  ".zig",     ".rs",  ".json", ".jsonc", ".jsonl", ".xml",    ".yaml",
    ".yml",  ".toml",    ".html",".htm",  ".css",   ".scss",  ".less",   ".sql",
    ".md",   ".markdown", ".ini", ".conf", ".cfg",   ".properties", ".lock",
    ".csv",  ".tsv",      ".gradle",
};

const INDEXABLE_LARGE_SOURCE_BASENAMES = [_][]const u8{
    "Dockerfile",
    "Containerfile",
    "Makefile",
    "CMakeLists.txt",
    "BUILD",
    "BUILD.bazel",
    "WORKSPACE",
    "WORKSPACE.bazel",
    "BUCK",
    "Justfile",
    "Taskfile",
};

fn isIndexableLargeSourcePath(path: []const u8) bool {
    const basename = std.fs.path.basename(path);
    for (INDEXABLE_LARGE_SOURCE_BASENAMES) |candidate| {
        if (std.ascii.eqlIgnoreCase(basename, candidate)) return true;
    }
    const ext = std.fs.path.extension(path);
    for (INDEXABLE_LARGE_SOURCE_EXTENSIONS) |candidate| {
        if (std.ascii.eqlIgnoreCase(ext, candidate)) return true;
    }
    return false;
}

test "large source index admission includes script source family" {
    try std.testing.expect(isIndexableLargeSourcePath("src/main.zig"));
    try std.testing.expect(isIndexableLargeSourcePath("crates/lib.rs"));
    try std.testing.expect(isIndexableLargeSourcePath("assets/bundle.js"));
    try std.testing.expect(isIndexableLargeSourcePath("assets/component.jsx"));
    try std.testing.expect(isIndexableLargeSourcePath("assets/server.mjs"));
    try std.testing.expect(isIndexableLargeSourcePath("assets/runtime.cjs"));
    try std.testing.expect(isIndexableLargeSourcePath("src/app.ts"));
    try std.testing.expect(isIndexableLargeSourcePath("src/app.tsx"));
    try std.testing.expect(isIndexableLargeSourcePath("cmd/search/main.go"));
    try std.testing.expect(isIndexableLargeSourcePath("tools/frontier.py"));
    try std.testing.expect(isIndexableLargeSourcePath("src/SearchFrontier.java"));
    try std.testing.expect(isIndexableLargeSourcePath("src/SearchFrontier.cs"));
    try std.testing.expect(isIndexableLargeSourcePath("src/SearchFrontier.kt"));
    try std.testing.expect(isIndexableLargeSourcePath("scripts/frontier.kts"));
    try std.testing.expect(isIndexableLargeSourcePath("Sources/SearchFrontier.swift"));
    try std.testing.expect(isIndexableLargeSourcePath("lib/frontier.rb"));
    try std.testing.expect(isIndexableLargeSourcePath("app/frontier.php"));
    try std.testing.expect(isIndexableLargeSourcePath("src/SearchFrontier.scala"));
    try std.testing.expect(isIndexableLargeSourcePath("scripts/frontier.sc"));
    try std.testing.expect(isIndexableLargeSourcePath("lib/frontier.dart"));
    try std.testing.expect(isIndexableLargeSourcePath("runtime/frontier.lua"));
    try std.testing.expect(isIndexableLargeSourcePath("analysis/frontier.R"));
    try std.testing.expect(isIndexableLargeSourcePath("notebooks/frontier.jl"));
    try std.testing.expect(isIndexableLargeSourcePath("components/Frontier.vue"));
    try std.testing.expect(isIndexableLargeSourcePath("components/Frontier.svelte"));
    try std.testing.expect(isIndexableLargeSourcePath("pages/frontier.astro"));
    try std.testing.expect(isIndexableLargeSourcePath("docs/frontier.mdx"));
    try std.testing.expect(isIndexableLargeSourcePath("schema/frontier.graphql"));
    try std.testing.expect(isIndexableLargeSourcePath("schema/frontier.gql"));
    try std.testing.expect(isIndexableLargeSourcePath("scripts/frontier.sh"));
    try std.testing.expect(isIndexableLargeSourcePath("scripts/frontier.bash"));
    try std.testing.expect(isIndexableLargeSourcePath("scripts/frontier.zsh"));
    try std.testing.expect(isIndexableLargeSourcePath("scripts/frontier.fish"));
    try std.testing.expect(isIndexableLargeSourcePath("scripts/frontier.ps1"));
    try std.testing.expect(isIndexableLargeSourcePath("modules/frontier.psm1"));
    try std.testing.expect(isIndexableLargeSourcePath("modules/frontier.psd1"));
    try std.testing.expect(isIndexableLargeSourcePath("scripts/frontier.cmd"));
    try std.testing.expect(isIndexableLargeSourcePath("scripts/frontier.bat"));
    try std.testing.expect(isIndexableLargeSourcePath("runtime/frontier.m"));
    try std.testing.expect(isIndexableLargeSourcePath("runtime/frontier.mm"));
    try std.testing.expect(isIndexableLargeSourcePath("lib/frontier.pl"));
    try std.testing.expect(isIndexableLargeSourcePath("lib/frontier.pm"));
    try std.testing.expect(isIndexableLargeSourcePath("src/frontier.erl"));
    try std.testing.expect(isIndexableLargeSourcePath("src/frontier.hrl"));
    try std.testing.expect(isIndexableLargeSourcePath("lib/frontier.ex"));
    try std.testing.expect(isIndexableLargeSourcePath("lib/frontier.exs"));
    try std.testing.expect(isIndexableLargeSourcePath("src/frontier.clj"));
    try std.testing.expect(isIndexableLargeSourcePath("src/frontier.cljs"));
    try std.testing.expect(isIndexableLargeSourcePath("src/frontier.cljc"));
    try std.testing.expect(isIndexableLargeSourcePath("src/frontier.fs"));
    try std.testing.expect(isIndexableLargeSourcePath("src/frontier.fsx"));
    try std.testing.expect(isIndexableLargeSourcePath("src/frontier.vb"));
    try std.testing.expect(isIndexableLargeSourcePath("src/frontier.hs"));
    try std.testing.expect(isIndexableLargeSourcePath("src/frontier.lhs"));
    try std.testing.expect(isIndexableLargeSourcePath("src/frontier.ml"));
    try std.testing.expect(isIndexableLargeSourcePath("src/frontier.mli"));
    try std.testing.expect(isIndexableLargeSourcePath("src/frontier.nim"));
    try std.testing.expect(isIndexableLargeSourcePath("src/frontier.cr"));
    try std.testing.expect(isIndexableLargeSourcePath("src/frontier.d"));
    try std.testing.expect(isIndexableLargeSourcePath("rtl/frontier.v"));
    try std.testing.expect(isIndexableLargeSourcePath("rtl/frontier.vh"));
    try std.testing.expect(isIndexableLargeSourcePath("rtl/frontier.sv"));
    try std.testing.expect(isIndexableLargeSourcePath("rtl/frontier.svh"));
    try std.testing.expect(isIndexableLargeSourcePath("hdl/frontier.vhd"));
    try std.testing.expect(isIndexableLargeSourcePath("hdl/frontier.vhdl"));
    try std.testing.expect(isIndexableLargeSourcePath("src/frontier.adb"));
    try std.testing.expect(isIndexableLargeSourcePath("src/frontier.ads"));
    try std.testing.expect(isIndexableLargeSourcePath("data/frontier.json"));
    try std.testing.expect(isIndexableLargeSourcePath("data/frontier.jsonl"));
    try std.testing.expect(isIndexableLargeSourcePath("config/frontier.yaml"));
    try std.testing.expect(isIndexableLargeSourcePath("config/frontier.toml"));
    try std.testing.expect(isIndexableLargeSourcePath("docs/frontier.xml"));
    try std.testing.expect(isIndexableLargeSourcePath("pages/frontier.html"));
    try std.testing.expect(isIndexableLargeSourcePath("styles/frontier.css"));
    try std.testing.expect(isIndexableLargeSourcePath("queries/frontier.sql"));
    try std.testing.expect(isIndexableLargeSourcePath("docs/frontier.markdown"));
    try std.testing.expect(isIndexableLargeSourcePath("config/frontier.ini"));
    try std.testing.expect(isIndexableLargeSourcePath("config/frontier.conf"));
    try std.testing.expect(isIndexableLargeSourcePath("config/frontier.cfg"));
    try std.testing.expect(isIndexableLargeSourcePath("config/frontier.properties"));
    try std.testing.expect(isIndexableLargeSourcePath("Cargo.lock"));
    try std.testing.expect(isIndexableLargeSourcePath("data/frontier.csv"));
    try std.testing.expect(isIndexableLargeSourcePath("data/frontier.tsv"));
    try std.testing.expect(isIndexableLargeSourcePath("build/frontier.gradle"));
    try std.testing.expect(isIndexableLargeSourcePath("Dockerfile"));
    try std.testing.expect(isIndexableLargeSourcePath("containers/Containerfile"));
    try std.testing.expect(isIndexableLargeSourcePath("Makefile"));
    try std.testing.expect(isIndexableLargeSourcePath("build/CMakeLists.txt"));
    try std.testing.expect(isIndexableLargeSourcePath("bazel/BUILD"));
    try std.testing.expect(isIndexableLargeSourcePath("bazel/WORKSPACE.bazel"));
    try std.testing.expect(isIndexableLargeSourcePath("buck/BUCK"));
    try std.testing.expect(isIndexableLargeSourcePath("tasks/Justfile"));
    try std.testing.expect(isIndexableLargeSourcePath("tasks/Taskfile"));
    try std.testing.expect(!isIndexableLargeSourcePath("logs/runtime.txt"));
    try std.testing.expect(!isIndexableLargeSourcePath("assets/bundle.map"));
}

fn lessThanIndexedFilePath(_: void, lhs: IndexedFile, rhs: IndexedFile) bool {
    return std.mem.lessThan(u8, lhs.path, rhs.path);
}

fn isDefaultHiddenEntry(name: []const u8) bool {
    return name.len > 1 and name[0] == '.' and !std.mem.eql(u8, name, "..");
}

fn joinPathForward(allocator: std.mem.Allocator, parent: []const u8, name: []const u8) ![]u8 {
    if (parent.len == 0 or std.mem.eql(u8, parent, ".")) return allocator.dupe(u8, name);
    const sep: []const u8 = if (std.mem.endsWith(u8, parent, "/") or std.mem.endsWith(u8, parent, "\\")) "" else "/";
    return std.fmt.allocPrint(allocator, "{s}{s}{s}", .{ parent, sep, name });
}

fn currentEpoch(io: std.Io) generation.Epoch {
    const now = std.Io.Timestamp.now(io, .real).nanoseconds;
    if (now <= 0) return 1;
    return @intCast(now);
}

fn holdLiveUntilRootMutation(io: std.Io, root_path: []const u8) void {
    if (builtin.os.tag == .windows) {
        holdLiveUntilRootMutationWindows(io, root_path);
    } else {
        std.Thread.sleep(@as(u64, 120) * std.time.ns_per_s);
    }
}

fn holdLiveUntilRootMutationWindows(io: std.Io, root_path: []const u8) void {
    const dir = std.Io.Dir.cwd().openDir(io, root_path, .{ .iterate = true }) catch return;
    defer dir.close(io);
    var buffer: [64 * 1024]u8 align(4) = undefined;
    var bytes_returned: windows.DWORD = 0;
    const filter: windows.DWORD =
        0x0000_0001 |
        0x0000_0002 |
        0x0000_0008 |
        0x0000_0010 |
        0x0000_0040;
    while (true) {
        bytes_returned = 0;
        _ = ReadDirectoryChangesW(
            dir.handle,
            &buffer,
            @intCast(buffer.len),
            windows.BOOL.TRUE,
            filter,
            &bytes_returned,
            null,
            null,
        );
        if (bytes_returned == 0) return;
        if (bufferHasExternalRootMutation(buffer[0..@intCast(bytes_returned)])) return;
    }
}

fn bufferHasExternalRootMutation(bytes: []const u8) bool {
    var offset: usize = 0;
    while (offset + 12 <= bytes.len) {
        const next = readLeU32(bytes[offset..][0..4]);
        const name_len = readLeU32(bytes[offset + 8 ..][0..4]);
        if (offset + 12 + name_len > bytes.len) return true;
        const name_bytes = bytes[offset + 12 .. offset + 12 + name_len];
        if (!isIndexMaintenancePath(name_bytes)) return true;
        if (next == 0) break;
        offset += next;
    }
    return false;
}

fn isIndexMaintenancePath(name_bytes: []const u8) bool {
    if (name_bytes.len < 6) return false;
    const dot = readLeU16(name_bytes[0..2]);
    const i = readLeU16(name_bytes[2..4]);
    const x = readLeU16(name_bytes[4..6]);
    if (dot != '.' or std.ascii.toLower(@intCast(i)) != 'i' or std.ascii.toLower(@intCast(x)) != 'x') return false;
    if (name_bytes.len == 6) return true;
    const sep = readLeU16(name_bytes[6..8]);
    return sep == '\\' or sep == '/';
}

fn readLeU16(bytes: *const [2]u8) u16 {
    return @as(u16, bytes[0]) | (@as(u16, bytes[1]) << 8);
}

fn readLeU32(bytes: *const [4]u8) u32 {
    return @as(u32, bytes[0]) |
        (@as(u32, bytes[1]) << 8) |
        (@as(u32, bytes[2]) << 16) |
        (@as(u32, bytes[3]) << 24);
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

test "indexd foreground once publishes catalog postings generation" {
    const root = ".zig-cache\\ix-indexd-generation-test";
    std.Io.Dir.cwd().deleteTree(std.testing.io, root) catch {};
    defer std.Io.Dir.cwd().deleteTree(std.testing.io, root) catch {};
    try std.Io.Dir.cwd().createDirPath(std.testing.io, root);
    const sample_path = try std.fs.path.join(std.testing.allocator, &.{ root, "sample.txt" });
    defer std.testing.allocator.free(sample_path);
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = sample_path, .data = "needle\n" });

    const result = try run(std.testing.io, std.testing.allocator, .{
        .root = root,
        .foreground = true,
        .once = true,
    });
    defer result.deinit(std.testing.allocator);

    const root_identity = try catalog.identifyRoot(std.testing.allocator, root);
    defer root_identity.deinit(std.testing.allocator);
    const current_path = try std.fs.path.join(std.testing.allocator, &.{ result.config.index_dir, "current.ixgen" });
    defer std.testing.allocator.free(current_path);
    const pin = (try generation.tryPinCurrentGeneration(std.testing.io, std.testing.allocator, current_path, root_identity.fingerprint)) orelse return error.TestExpectedCurrentGeneration;
    const paths = try generation.buildGenerationPaths(std.testing.allocator, root, pin.epoch);
    defer paths.deinit(std.testing.allocator);

    var buffer: [32]u8 = undefined;
    _ = try std.Io.Dir.cwd().readFile(std.testing.io, paths.manifest_path, &buffer);
    const catalog_path = try std.fs.path.join(std.testing.allocator, &.{ paths.generation_dir, "catalog.ixcat" });
    defer std.testing.allocator.free(catalog_path);
    _ = try std.Io.Dir.cwd().readFile(std.testing.io, catalog_path, &buffer);
    const postings_path = try std.fs.path.join(std.testing.allocator, &.{ paths.generation_dir, "postings.ixpost" });
    defer std.testing.allocator.free(postings_path);
    _ = try std.Io.Dir.cwd().readFile(std.testing.io, postings_path, &buffer);
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
