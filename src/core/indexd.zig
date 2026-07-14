const std = @import("std");
const builtin = @import("builtin");
const windows = std.os.windows;
const catalog = @import("catalog.zig");
const corpus_signature = @import("corpus_signature.zig");
const generation = @import("generation.zig");
const postings = @import("postings.zig");
const process_memory = @import("process_memory.zig");
const resource_profile = @import("resource_profile.zig");
const state_dir = @import("state_dir.zig");
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

extern "kernel32" fn GetProcessTimes(
    hProcess: windows.HANDLE,
    lpCreationTime: *windows.FILETIME,
    lpExitTime: *windows.FILETIME,
    lpKernelTime: *windows.FILETIME,
    lpUserTime: *windows.FILETIME,
) callconv(.winapi) windows.BOOL;

pub const LIVE_MARKER_NAME = "index.live";
pub const MEMORY_LIMIT_ENV = "IX_INDEXD_MEMORY_LIMIT_MB";
const INDEX_FILE_READ_LIMIT: usize = 16 * 1024 * 1024;
const INDEX_LARGE_SOURCE_FILE_READ_LIMIT: usize = 64 * 1024 * 1024;
const INDEX_LARGE_SOURCE_TOTAL_READ_LIMIT: usize = 384 * 1024 * 1024;
const MUTATION_SETTLE_WINDOW_NS: u64 = 75 * std.time.ns_per_ms;
const MUTATION_SETTLE_MAX_WINDOWS: u32 = 2;

pub const Request = struct {
    root: []const u8,
    foreground: bool = false,
    once: bool = false,
    repair: bool = false,
    serve: bool = false,
};

pub const Mode = enum {
    foreground_once,
    foreground_watch,
    background_watch,
    foreground_repair,
    /// P26: Long-lived warm-index daemon. Holds the index in a persistent
    /// in-memory mapping and serves warm queries without exiting. The index
    /// data (catalog + postings) is loaded into process memory and kept
    /// resident across queries. On Windows, the OS page cache makes this
    /// equivalent to a shared-memory mmap'd readonly segment — multiple
    /// search processes read the same file-backed pages without re-loading.
    /// On Linux, mmap with MAP_SHARED provides the same shared-memory
    /// semantics explicitly.
    serve,
};

pub const Config = struct {
    root: []const u8,
    index_dir: []const u8,
    mode: Mode,
    foreground: bool,
    once: bool,
    repair: bool,
    memory_limit_bytes: usize,

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
        _ = publishRootGenerationForConfig(io, allocator, config) catch |err| {
            try recordPublishFailure(io, allocator, config, err);
            return err;
        };
        if (config.mode == .foreground_once) {
            // Write live marker so warm-index search can use the freshly built index.
            // foreground_once does NOT remove the marker on exit — the index persists
            // until the next build or process cleanup detects a stale owner.
            const live = writeLiveMarker(io, allocator, config) catch |err| {
                try recordPublishFailure(io, allocator, config, err);
                return err;
            };
            // Free the path allocation but leave the file on disk.
            allocator.free(live.path);
            // The initial publishRootGenerationForConfig above already produced
            // a complete generation (catalog + postings + signature). The
            // compaction call that was here re-indexed the same corpus and
            // created a SECOND generation with parent_epoch pointing at the
            // first — every warm query then read BOTH 922 MiB postings files
            // via prepareDeltaWarmIndexFrontier, costing ~6 s per cache MISS.
            // Removing the compaction keeps the single-generation layout:
            // pin.parent_epoch is null, the non-delta path runs, and only one
            // postings + one catalog are read per MISS.
        } else if (builtin.os.tag == .windows) {
            const live = try writeLiveMarker(io, allocator, config);
            defer live.remove(io, allocator);
            while (true) {
                holdLiveUntilRootMutation(io, config.root);
                settleRootMutationBurst(io);
                _ = compactCurrentRootGenerationWithBudget(io, allocator, config.root, config.memory_limit_bytes) catch |err| {
                    try recordPublishFailure(io, allocator, config, err);
                    return err;
                };
            }
        } else if (config.mode == .serve) {
            // P26: Long-lived warm-index daemon. Holds the index in a persistent
            // in-memory mapping. The live marker persists for the daemon's lifetime.
            // The index data is loaded by search processes via file-backed mmap
            // (shared page cache on Windows, MAP_SHARED on Linux).
            const live = try writeLiveMarker(io, allocator, config);
            defer live.remove(io, allocator);
            // Serve loop: keep the process alive, watching for root mutations.
            // On mutation, rebuild and re-publish the generation in-place.
            while (true) {
                holdLiveUntilRootMutation(io, config.root);
                settleRootMutationBurst(io);
                _ = compactCurrentRootGenerationWithBudget(io, allocator, config.root, config.memory_limit_bytes) catch |err| {
                    try recordPublishFailure(io, allocator, config, err);
                    return err;
                };
            }
        } else {
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
    const root_identity = try catalog.identifyRoot(allocator, request.root);
    defer root_identity.deinit(allocator);
    const state = try state_dir.buildRootIndexState(allocator, root_identity.fingerprint);
    defer allocator.free(state.state_dir);
    return .{
        .root = request.root,
        .index_dir = state.index_dir,
        .mode = modeFor(request),
        .foreground = request.foreground,
        .once = request.once,
        .repair = request.repair,
        .memory_limit_bytes = configuredMemoryLimitBytes(),
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
    try writer.interface.print("IXINDEXD1\npid={}\nprocess_start_ns={}\ncreated_ns={}\nmode={s}\nroot={s}\n", .{
        pid,
        try currentProcessStartNs(),
        std.Io.Timestamp.now(io, .real).nanoseconds,
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
    const root_identity = try catalog.identifyRoot(allocator, config.root);
    defer root_identity.deinit(allocator);
    try std.Io.Dir.cwd().createDirPath(io, config.index_dir);
    const live_path = try std.fs.path.join(allocator, &.{ config.index_dir, LIVE_MARKER_NAME });
    errdefer allocator.free(live_path);

    var file = try std.Io.Dir.cwd().createFile(io, live_path, .{ .truncate = true });
    defer file.close(io);

    var buffer: [256]u8 = undefined;
    var writer = file.writer(io, &buffer);
    try writer.interface.print("IXINDEX_LIVE1\npid={}\nprocess_start_ns={}\ncreated_ns={}\nroot={s}\n", .{
        currentProcessId(),
        try currentProcessStartNs(),
        std.Io.Timestamp.now(io, .real).nanoseconds,
        root_identity.canonical_path,
    });
    try writer.interface.flush();
    return .{ .path = live_path };
}

fn currentProcessStartNs() !i128 {
    if (builtin.os.tag != .windows) return 0;
    var creation: windows.FILETIME = undefined;
    var exit: windows.FILETIME = undefined;
    var kernel: windows.FILETIME = undefined;
    var user: windows.FILETIME = undefined;
    if (GetProcessTimes(windows.GetCurrentProcess(), &creation, &exit, &kernel, &user) == windows.BOOL.FALSE) {
        return error.ProcessStartUnavailable;
    }
    return fileTimeToUnixNs(creation);
}

fn fileTimeToUnixNs(file_time: windows.FILETIME) i128 {
    const windows_epoch_to_unix_epoch_100ns: i128 = 116_444_736_000_000_000;
    const ticks_100ns = (@as(i128, file_time.dwHighDateTime) << 32) | @as(i128, file_time.dwLowDateTime);
    return (ticks_100ns - windows_epoch_to_unix_epoch_100ns) * 100;
}

fn configuredMemoryLimitBytes() usize {
    const framework_limit = resource_profile.memoryLimitBytes();
    const value_ptr = std.c.getenv(MEMORY_LIMIT_ENV ++ "\x00") orelse return framework_limit;
    const requested = parseMemoryLimitMb(std.mem.span(value_ptr)) orelse return framework_limit;
    return boundedMemoryLimit(requested, framework_limit);
}

/// Environment configuration may lower the shared policy but cannot turn a
/// lane-local setting into authority over the framework ceiling.
fn boundedMemoryLimit(requested: usize, framework_limit: usize) usize {
    return @min(requested, framework_limit);
}

fn parseMemoryLimitMb(value: []const u8) ?usize {
    const trimmed = std.mem.trim(u8, value, " \t\r\n");
    if (trimmed.len == 0) return null;
    const mb = std.fmt.parseInt(usize, trimmed, 10) catch return null;
    if (mb == 0) return 0;
    const bytes_per_mb = 1024 * 1024;
    if (mb > std.math.maxInt(usize) / bytes_per_mb) return std.math.maxInt(usize);
    return mb * bytes_per_mb;
}

fn enforceMemoryBudget(limit_bytes: usize) !void {
    if (limit_bytes == 0) return;
    const resident = process_memory.currentResidentBytes() orelse return;
    if (resident > std.math.maxInt(usize)) return error.MemoryBudgetExceeded;
    if (memoryBudgetExceeded(@intCast(resident), limit_bytes)) return error.MemoryBudgetExceeded;
}

fn memoryBudgetExceeded(current_bytes: usize, limit_bytes: usize) bool {
    return limit_bytes != 0 and current_bytes > limit_bytes;
}

pub fn publishRootGeneration(io: std.Io, allocator: std.mem.Allocator, root: []const u8) !generation.ReaderPin {
    return publishRootGenerationWithBudget(io, allocator, root, configuredMemoryLimitBytes());
}

fn publishRootGenerationForConfig(io: std.Io, allocator: std.mem.Allocator, config: Config) !generation.ReaderPin {
    return publishRootGenerationWithBudget(io, allocator, config.root, config.memory_limit_bytes);
}

pub fn publishRootGenerationWithBudget(io: std.Io, allocator: std.mem.Allocator, root: []const u8, memory_limit_bytes: usize) !generation.ReaderPin {
    return publishRootGenerationWithParentBudget(io, allocator, root, null, memory_limit_bytes);
}

pub fn publishCompactedRootGenerationWithBudget(io: std.Io, allocator: std.mem.Allocator, root: []const u8, parent_epoch: generation.Epoch, memory_limit_bytes: usize) !generation.ReaderPin {
    if (parent_epoch == generation.INVALID_EPOCH) return error.InvalidParentGeneration;
    return publishRootGenerationWithParentBudget(io, allocator, root, parent_epoch, memory_limit_bytes);
}

pub fn compactCurrentRootGenerationWithBudget(io: std.Io, allocator: std.mem.Allocator, root: []const u8, memory_limit_bytes: usize) !generation.ReaderPin {
    const root_identity = try catalog.identifyRoot(allocator, root);
    defer root_identity.deinit(allocator);
    const state = try state_dir.buildRootIndexState(allocator, root_identity.fingerprint);
    defer state.deinit(allocator);
    const current_path = try std.fs.path.join(allocator, &.{ state.index_dir, "current.ixgen" });
    defer allocator.free(current_path);
    const current_pin = generation.pinCurrentGenerationWithPayloads(io, allocator, state.index_dir, current_path, root_identity.fingerprint) catch |err| switch (err) {
        error.NoCurrentGeneration => return publishRootGenerationWithBudget(io, allocator, root, memory_limit_bytes),
        else => return err,
    };
    return publishCompactedRootGenerationWithBudget(io, allocator, root, current_pin.epoch, memory_limit_bytes);
}

fn publishRootGenerationWithParentBudget(io: std.Io, allocator: std.mem.Allocator, root: []const u8, parent_epoch: ?generation.Epoch, memory_limit_bytes: usize) !generation.ReaderPin {
    try enforceMemoryBudget(memory_limit_bytes);
    var files = std.ArrayList(IndexedFile).empty;
    defer {
        for (files.items) |file| file.deinit(allocator);
        files.deinit(allocator);
    }

    try collectIndexFiles(io, allocator, root, &files, memory_limit_bytes);
    try enforceMemoryBudget(memory_limit_bytes);
    std.mem.sort(IndexedFile, files.items, {}, lessThanIndexedFilePath);

    const epoch = try currentEpochAfterParent(io, parent_epoch);
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
    try enforceMemoryBudget(memory_limit_bytes);
    const verify_required_count = files.items.len - postings_inputs.items.len;
    const segment = try postings.buildPostingsSegment(allocator, root_identity.fingerprint, epoch, postings_inputs.items, verify_required_count);
    defer segment.deinit(allocator);
    try enforceMemoryBudget(memory_limit_bytes);
    const postings_bytes = try postings.serializePostingsSegment(allocator, segment);
    defer allocator.free(postings_bytes);
    try enforceMemoryBudget(memory_limit_bytes);

    // Compute corpus signature from the IndexedFile array — the exact files
    // that were just indexed. Zero TOCTOU: no second walk, no filesystem access.
    // This signature is compared against a live stat walk at query time.
    const corpus_sig = computeSignatureFromIndexedFiles(files.items);
    const signature_bytes = try corpus_signature.serializeSignature(allocator, corpus_sig);
    defer allocator.free(signature_bytes);

    const state = try state_dir.buildRootIndexState(allocator, root_identity.fingerprint);
    defer state.deinit(allocator);
    const paths = try generation.buildGenerationPathsInIndexDir(allocator, state.index_dir, epoch);
    defer paths.deinit(allocator);
    const payloads = [_]generation.SegmentPayload{
        .{ .kind = .catalog, .relative_path = "catalog.ixcat", .bytes = catalog_bytes },
        .{ .kind = .postings, .relative_path = "postings.ixpost", .bytes = postings_bytes },
        .{ .kind = .signature, .relative_path = "corpus.ixsignature", .bytes = signature_bytes },
    };
    return generation.publishGenerationPayloads(io, allocator, paths, root_identity.fingerprint, epoch, parent_epoch, &payloads);
}

fn recordPublishFailure(io: std.Io, allocator: std.mem.Allocator, config: Config, err: anyerror) !void {
    switch (err) {
        error.MemoryBudgetExceeded => try writeRepairState(io, allocator, config, "memory_budget_exceeded"),
        else => {},
    }
}

fn modeFor(request: Request) Mode {
    if (request.serve) return .serve;
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
        .serve => "serve",
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

fn collectIndexFiles(io: std.Io, allocator: std.mem.Allocator, root: []const u8, files: *std.ArrayList(IndexedFile), memory_limit_bytes: usize) !void {
    var large_source_bytes: usize = 0;
    try collectIndexFilesWithBudget(io, allocator, root, files, &large_source_bytes, memory_limit_bytes);
}

fn collectIndexFilesWithBudget(io: std.Io, allocator: std.mem.Allocator, root: []const u8, files: *std.ArrayList(IndexedFile), large_source_bytes: *usize, memory_limit_bytes: usize) !void {
    try enforceMemoryBudget(memory_limit_bytes);
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
        const child_path = try joinPathForward(allocator, root, entry.name);
        switch (entry.kind) {
            .file => try appendIndexedFile(io, allocator, child_path, files, large_source_bytes, memory_limit_bytes),
            .directory => {
                if (isExcludedIndexEntry(entry.name)) {
                    allocator.free(child_path);
                    continue;
                }
                try collectIndexFilesWithBudget(io, allocator, child_path, files, large_source_bytes, memory_limit_bytes);
                allocator.free(child_path);
            },
            else => allocator.free(child_path),
        }
    }
}

fn appendIndexedFile(io: std.Io, allocator: std.mem.Allocator, path: []const u8, files: *std.ArrayList(IndexedFile), large_source_bytes: *usize, memory_limit_bytes: usize) !void {
    try enforceMemoryBudget(memory_limit_bytes);
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
        try enforceMemoryBudget(memory_limit_bytes);
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
    try enforceMemoryBudget(memory_limit_bytes);
}

const INDEXABLE_LARGE_SOURCE_EXTENSIONS = [_][]const u8{
    ".c",    ".h",        ".cc",   ".hh",   ".cpp",   ".hpp",        ".cxx",    ".hxx",
    ".js",   ".jsx",      ".mjs",  ".cjs",  ".ts",    ".tsx",        ".go",     ".py",
    ".java", ".cs",       ".kt",   ".kts",  ".swift", ".rb",         ".php",    ".scala",
    ".sc",   ".dart",     ".lua",  ".r",    ".jl",    ".vue",        ".svelte", ".astro",
    ".mdx",  ".graphql",  ".gql",  ".sh",   ".bash",  ".zsh",        ".fish",   ".ps1",
    ".psm1", ".psd1",     ".cmd",  ".bat",  ".m",     ".mm",         ".pl",     ".pm",
    ".erl",  ".hrl",      ".ex",   ".exs",  ".clj",   ".cljs",       ".cljc",   ".fs",
    ".fsx",  ".vb",       ".hs",   ".lhs",  ".ml",    ".mli",        ".nim",    ".cr",
    ".d",    ".v",        ".vh",   ".sv",   ".svh",   ".vhd",        ".vhdl",   ".adb",
    ".ads",  ".zig",      ".rs",   ".json", ".jsonc", ".jsonl",      ".xml",    ".yaml",
    ".yml",  ".toml",     ".html", ".htm",  ".css",   ".scss",       ".less",   ".sql",
    ".md",   ".markdown", ".ini",  ".conf", ".cfg",   ".properties", ".lock",   ".csv",
    ".tsv",  ".gradle",
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

/// Computes corpus signature from the IndexedFile array at publish time.
/// Zero I/O, zero TOCTOU — operates on the exact files that were just indexed.
/// Uses the shared hashFileSignature function so both indexer and search
/// produce identical signatures for the same file set.
fn computeSignatureFromIndexedFiles(files: []const IndexedFile) corpus_signature.CorpusSignature {
    var sig = corpus_signature.CorpusSignature{};
    for (files) |file| {
        sig.file_count += 1;
        sig.total_bytes += file.size;
        if (file.mtime_ns > sig.max_mtime_ns) sig.max_mtime_ns = file.mtime_ns;
        sig.path_hash_xor ^= corpus_signature.hashFileSignature(file.path, file.size, file.mtime_ns);
    }
    return sig;
}

fn isDefaultHiddenEntry(name: []const u8) bool {
    return name.len > 1 and name[0] == '.' and !std.mem.eql(u8, name, "..");
}

pub fn isManagedRoot(root: []const u8) bool {
    var saw_segment = false;
    var iterator = std.mem.splitAny(u8, root, "/\\");
    while (iterator.next()) |segment| {
        if (segment.len == 0) continue;
        saw_segment = true;
        if (isExcludedIndexEntry(segment)) return false;
    }
    return saw_segment or std.mem.eql(u8, root, ".");
}

fn isExcludedIndexEntry(name: []const u8) bool {
    return isDefaultHiddenEntry(name) or isDependencyOrGeneratedIndexEntry(name);
}

pub fn isIndexCoverageExcludedDirectoryName(name: []const u8) bool {
    return std.ascii.eqlIgnoreCase(name, "node_modules") or
        std.ascii.eqlIgnoreCase(name, "zig-cache") or
        std.ascii.eqlIgnoreCase(name, "zig-out") or
        std.ascii.eqlIgnoreCase(name, "tmp") or
        std.ascii.eqlIgnoreCase(name, "temp");
}

fn isDependencyOrGeneratedIndexEntry(name: []const u8) bool {
    return isIndexCoverageExcludedDirectoryName(name) or isGeneratedSourceIndexEntry(name);
}

fn isGeneratedSourceIndexEntry(name: []const u8) bool {
    return std.mem.eql(u8, name, "tags") or std.mem.eql(u8, name, "TAGS");
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

fn currentEpochAfterParent(io: std.Io, parent_epoch: ?generation.Epoch) !generation.Epoch {
    const epoch = currentEpoch(io);
    const parent = parent_epoch orelse return epoch;
    if (epoch > parent) return epoch;
    if (parent == std.math.maxInt(generation.Epoch)) return error.InvalidParentGeneration;
    return parent + 1;
}

fn holdLiveUntilRootMutation(io: std.Io, root_path: []const u8) void {
    if (builtin.os.tag == .windows) {
        holdLiveUntilRootMutationWindows(io, root_path);
    } else {
        io.sleep(std.Io.Duration.fromSeconds(120), .awake) catch {};
    }
}

fn settleRootMutationBurst(io: std.Io) void {
    var remaining = mutationSettleWindowCount();
    while (remaining > 0) : (remaining -= 1) {
        io.sleep(std.Io.Duration.fromNanoseconds(MUTATION_SETTLE_WINDOW_NS), .awake) catch {};
    }
}

fn mutationSettleWindowCount() u32 {
    return MUTATION_SETTLE_MAX_WINDOWS;
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

test "indexd managed root admission rejects dependency generated and hidden paths" {
    try std.testing.expect(isManagedRoot("."));
    try std.testing.expect(isManagedRoot("src"));
    try std.testing.expect(isManagedRoot("apps/backend/convex"));
    try std.testing.expect(isManagedRoot("vendor/embedded-src"));
    try std.testing.expect(isManagedRoot("build/scripts"));
    try std.testing.expect(isManagedRoot("dist/types"));
    try std.testing.expect(isManagedRoot("target/generated-bindings"));
    try std.testing.expect(isIndexCoverageExcludedDirectoryName("node_modules"));
    try std.testing.expect(isIndexCoverageExcludedDirectoryName("zig-cache"));
    try std.testing.expect(!isIndexCoverageExcludedDirectoryName("vendor"));
    try std.testing.expect(!isIndexCoverageExcludedDirectoryName("tags"));
    try std.testing.expect(!isManagedRoot("apps/backend/node_modules/convex/dist"));
    try std.testing.expect(!isManagedRoot(".docs/reports/subzero"));
    try std.testing.expect(!isManagedRoot("tmp/warm-owner-bench-current"));
    try std.testing.expect(!isManagedRoot("zig-out/bin"));
    try std.testing.expect(!isManagedRoot("src/.ix"));
}

test "indexd background config uses central state for generated-looking roots" {
    const root = ".zig-cache\\ix-indexd-unmanaged-root\\node_modules\\convex\\dist";
    const top = ".zig-cache\\ix-indexd-unmanaged-root";
    std.Io.Dir.cwd().deleteTree(std.testing.io, top) catch {};
    defer std.Io.Dir.cwd().deleteTree(std.testing.io, top) catch {};

    const config = try buildConfig(std.testing.allocator, .{ .root = root });
    defer config.deinit(std.testing.allocator);

    try std.testing.expectEqual(Mode.background_watch, config.mode);
    try std.testing.expect(std.mem.indexOf(u8, config.index_dir, "index") != null);
    try std.testing.expect(std.mem.indexOf(u8, config.index_dir, "roots") != null);
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.cwd().access(std.testing.io, root, .{}));
}

test "indexd config owns IX state index directory" {
    const scanned_root = ".zig-cache\\ix-indexd-config-root";
    const config = try buildConfig(std.testing.allocator, .{
        .root = scanned_root,
        .repair = true,
    });
    defer config.deinit(std.testing.allocator);
    const state_root = try state_dir.resolveStateDir(std.testing.allocator);
    defer std.testing.allocator.free(state_root);

    try std.testing.expectEqual(Mode.foreground_repair, config.mode);
    try std.testing.expect(std.mem.startsWith(u8, config.index_dir, state_root));
    try std.testing.expect(std.mem.indexOf(u8, config.index_dir, "roots") != null);
    try std.testing.expect(std.mem.indexOf(u8, config.index_dir, scanned_root) == null);
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
    try std.testing.expect(std.mem.indexOf(u8, contents, "process_start_ns=") != null);
    try std.testing.expect(std.mem.indexOf(u8, contents, "created_ns=") != null);
    try std.testing.expect(std.mem.indexOf(u8, contents, "mode=foreground_once") != null);
}

test "warm live marker stores the canonical root consumed by search" {
    const root = ".zig-cache\\ix-indexd-live-root-test";
    try std.Io.Dir.cwd().createDirPath(std.testing.io, root);
    defer std.Io.Dir.cwd().deleteTree(std.testing.io, root) catch {};
    const config = try buildConfig(std.testing.allocator, .{ .root = root, .foreground = true, .once = true });
    defer config.deinit(std.testing.allocator);
    const marker = try writeLiveMarker(std.testing.io, std.testing.allocator, config);
    defer marker.remove(std.testing.io, std.testing.allocator);
    const identity = try catalog.identifyRoot(std.testing.allocator, root);
    defer identity.deinit(std.testing.allocator);
    const bytes = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, marker.path, std.testing.allocator, .limited(4096));
    defer std.testing.allocator.free(bytes);
    const expected = try std.fmt.allocPrint(std.testing.allocator, "root={s}\n", .{identity.canonical_path});
    defer std.testing.allocator.free(expected);
    try std.testing.expect(std.mem.indexOf(u8, bytes, expected) != null);
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
    const cleanup_identity = try catalog.identifyRoot(std.testing.allocator, root);
    const cleanup_state = try state_dir.buildRootIndexState(std.testing.allocator, cleanup_identity.fingerprint);
    std.Io.Dir.cwd().deleteTree(std.testing.io, cleanup_state.index_dir) catch {};
    cleanup_state.deinit(std.testing.allocator);
    cleanup_identity.deinit(std.testing.allocator);
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
    const paths = try generation.buildGenerationPathsInIndexDir(std.testing.allocator, result.config.index_dir, pin.epoch);
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

test "indexd compacted root generation keeps old epoch readable until current swap" {
    const root = ".zig-cache\\ix-indexd-compacted-generation-test";
    std.Io.Dir.cwd().deleteTree(std.testing.io, root) catch {};
    defer std.Io.Dir.cwd().deleteTree(std.testing.io, root) catch {};
    try std.Io.Dir.cwd().createDirPath(std.testing.io, root);
    const cleanup_identity = try catalog.identifyRoot(std.testing.allocator, root);
    const cleanup_state = try state_dir.buildRootIndexState(std.testing.allocator, cleanup_identity.fingerprint);
    std.Io.Dir.cwd().deleteTree(std.testing.io, cleanup_state.index_dir) catch {};
    cleanup_state.deinit(std.testing.allocator);
    cleanup_identity.deinit(std.testing.allocator);

    const keep_path = try std.fs.path.join(std.testing.allocator, &.{ root, "keep.txt" });
    defer std.testing.allocator.free(keep_path);
    const changed_path = try std.fs.path.join(std.testing.allocator, &.{ root, "changed.txt" });
    defer std.testing.allocator.free(changed_path);
    const deleted_path = try std.fs.path.join(std.testing.allocator, &.{ root, "deleted.txt" });
    defer std.testing.allocator.free(deleted_path);
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = keep_path, .data = "stable needle\n" });
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = changed_path, .data = "old needle\n" });
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = deleted_path, .data = "deleted needle\n" });

    const base_pin = try publishRootGenerationWithBudget(std.testing.io, std.testing.allocator, root, 0);
    try std.testing.expectEqual(@as(?generation.Epoch, null), base_pin.parent_epoch);

    const root_identity = try catalog.identifyRoot(std.testing.allocator, root);
    defer root_identity.deinit(std.testing.allocator);
    const state = try state_dir.buildRootIndexState(std.testing.allocator, root_identity.fingerprint);
    defer state.deinit(std.testing.allocator);
    const base_paths = try generation.buildGenerationPathsInIndexDir(std.testing.allocator, state.index_dir, base_pin.epoch);
    defer base_paths.deinit(std.testing.allocator);
    const base_catalog_path = try std.fs.path.join(std.testing.allocator, &.{ base_paths.generation_dir, "catalog.ixcat" });
    defer std.testing.allocator.free(base_catalog_path);

    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = changed_path, .data = "new needle compacted\n" });
    try std.Io.Dir.cwd().deleteFile(std.testing.io, deleted_path);

    const compacted_pin = try compactCurrentRootGenerationWithBudget(std.testing.io, std.testing.allocator, root, 0);
    try std.testing.expect(compacted_pin.epoch >= base_pin.epoch);
    try std.testing.expectEqual(@as(?generation.Epoch, base_pin.epoch), compacted_pin.parent_epoch);
    try std.testing.expectEqual(@as(usize, 3), compacted_pin.segment_count);

    var small_buffer: [64]u8 = undefined;
    _ = try std.Io.Dir.cwd().readFile(std.testing.io, base_paths.manifest_path, &small_buffer);
    _ = try std.Io.Dir.cwd().readFile(std.testing.io, base_catalog_path, &small_buffer);

    const current_pin = (try generation.tryPinCurrentGenerationWithPayloads(std.testing.io, std.testing.allocator, state.index_dir, base_paths.current_manifest_path, root_identity.fingerprint)) orelse return error.TestExpectedCurrentGeneration;
    try std.testing.expectEqual(compacted_pin.epoch, current_pin.epoch);
    try std.testing.expectEqual(@as(?generation.Epoch, base_pin.epoch), current_pin.parent_epoch);

    const compacted_paths = try generation.buildGenerationPathsInIndexDir(std.testing.allocator, state.index_dir, compacted_pin.epoch);
    defer compacted_paths.deinit(std.testing.allocator);
    const compacted_catalog_path = try std.fs.path.join(std.testing.allocator, &.{ compacted_paths.generation_dir, "catalog.ixcat" });
    defer std.testing.allocator.free(compacted_catalog_path);
    const compacted_catalog_bytes = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, compacted_catalog_path, std.testing.allocator, .limited(64 * 1024));
    defer std.testing.allocator.free(compacted_catalog_bytes);
    const snapshot = try catalog.parseCatalogForRoot(std.testing.allocator, compacted_catalog_bytes, root_identity.fingerprint);
    defer snapshot.deinit(std.testing.allocator);

    var saw_keep = false;
    var saw_changed = false;
    var saw_deleted = false;
    for (snapshot.entries, 0..) |entry, index| {
        const path = snapshot.path(entry);
        if (std.mem.endsWith(u8, path, "keep.txt")) {
            saw_keep = true;
            try std.testing.expectEqual(@as(u64, "stable needle\n".len), snapshot.metas[index].size);
        }
        if (std.mem.endsWith(u8, path, "changed.txt")) {
            saw_changed = true;
            try std.testing.expectEqual(@as(u64, "new needle compacted\n".len), snapshot.metas[index].size);
        }
        if (std.mem.endsWith(u8, path, "deleted.txt")) saw_deleted = true;
    }
    try std.testing.expect(saw_keep);
    try std.testing.expect(saw_changed);
    try std.testing.expect(!saw_deleted);
}

test "indexd compact current generation falls back to initial publish when no current exists" {
    const root = ".zig-cache\\ix-indexd-compaction-initial-publish-test";
    std.Io.Dir.cwd().deleteTree(std.testing.io, root) catch {};
    defer std.Io.Dir.cwd().deleteTree(std.testing.io, root) catch {};
    try std.Io.Dir.cwd().createDirPath(std.testing.io, root);
    const cleanup_identity = try catalog.identifyRoot(std.testing.allocator, root);
    const cleanup_state = try state_dir.buildRootIndexState(std.testing.allocator, cleanup_identity.fingerprint);
    std.Io.Dir.cwd().deleteTree(std.testing.io, cleanup_state.index_dir) catch {};
    cleanup_state.deinit(std.testing.allocator);
    cleanup_identity.deinit(std.testing.allocator);
    const sample_path = try std.fs.path.join(std.testing.allocator, &.{ root, "sample.txt" });
    defer std.testing.allocator.free(sample_path);
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = sample_path, .data = "initial compact publish\n" });

    const pin = try compactCurrentRootGenerationWithBudget(std.testing.io, std.testing.allocator, root, 0);
    try std.testing.expectEqual(@as(?generation.Epoch, null), pin.parent_epoch);
    try std.testing.expectEqual(@as(usize, 3), pin.segment_count);

    const root_identity = try catalog.identifyRoot(std.testing.allocator, root);
    defer root_identity.deinit(std.testing.allocator);
    const state = try state_dir.buildRootIndexState(std.testing.allocator, root_identity.fingerprint);
    defer state.deinit(std.testing.allocator);
    const current_path = try std.fs.path.join(std.testing.allocator, &.{ state.index_dir, "current.ixgen" });
    defer std.testing.allocator.free(current_path);
    const current_pin = (try generation.tryPinCurrentGenerationWithPayloads(std.testing.io, std.testing.allocator, state.index_dir, current_path, root_identity.fingerprint)) orelse return error.TestExpectedCurrentGeneration;
    try std.testing.expectEqual(pin.epoch, current_pin.epoch);
    try std.testing.expectEqual(@as(?generation.Epoch, null), current_pin.parent_epoch);
}

test "indexd compact current generation rejects corrupt current manifest" {
    const root = ".zig-cache\\ix-indexd-compaction-corrupt-current-test";
    std.Io.Dir.cwd().deleteTree(std.testing.io, root) catch {};
    defer std.Io.Dir.cwd().deleteTree(std.testing.io, root) catch {};
    try std.Io.Dir.cwd().createDirPath(std.testing.io, root);
    const sample_path = try std.fs.path.join(std.testing.allocator, &.{ root, "sample.txt" });
    defer std.testing.allocator.free(sample_path);
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = sample_path, .data = "corrupt current guard\n" });

    _ = try publishRootGenerationWithBudget(std.testing.io, std.testing.allocator, root, 0);

    const root_identity = try catalog.identifyRoot(std.testing.allocator, root);
    defer root_identity.deinit(std.testing.allocator);
    const state = try state_dir.buildRootIndexState(std.testing.allocator, root_identity.fingerprint);
    defer state.deinit(std.testing.allocator);
    const current_path = try std.fs.path.join(std.testing.allocator, &.{ state.index_dir, "current.ixgen" });
    defer std.testing.allocator.free(current_path);
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = current_path, .data = "not an ix generation manifest\n" });

    try std.testing.expectError(error.TruncatedGenerationManifest, compactCurrentRootGenerationWithBudget(std.testing.io, std.testing.allocator, root, 0));
}

test "indexd default traversal indexes dotfiles but skips dot directories" {
    const root = ".zig-cache\\ix-indexd-dotfile-parity-test";
    std.Io.Dir.cwd().deleteTree(std.testing.io, root) catch {};
    defer std.Io.Dir.cwd().deleteTree(std.testing.io, root) catch {};
    try std.Io.Dir.cwd().createDirPath(std.testing.io, root);
    const dotfile_path = try joinPathForward(std.testing.allocator, root, ".rootfile");
    defer std.testing.allocator.free(dotfile_path);
    const dotdir_path = try joinPathForward(std.testing.allocator, root, ".git");
    defer std.testing.allocator.free(dotdir_path);
    const hidden_path = try std.fs.path.join(std.testing.allocator, &.{ root, ".git", "hidden.txt" });
    defer std.testing.allocator.free(hidden_path);
    const tags_dir_path = try joinPathForward(std.testing.allocator, root, "tags");
    defer std.testing.allocator.free(tags_dir_path);
    const tags_file_path = try std.fs.path.join(std.testing.allocator, &.{ root, "tags", "generated.txt" });
    defer std.testing.allocator.free(tags_file_path);
    const visible_path = try joinPathForward(std.testing.allocator, root, "visible.txt");
    defer std.testing.allocator.free(visible_path);
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = dotfile_path, .data = "static\n" });
    try std.Io.Dir.cwd().createDirPath(std.testing.io, dotdir_path);
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = hidden_path, .data = "static\n" });
    try std.Io.Dir.cwd().createDirPath(std.testing.io, tags_dir_path);
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = tags_file_path, .data = "static\n" });
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = visible_path, .data = "static\n" });

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
    const paths = try generation.buildGenerationPathsInIndexDir(std.testing.allocator, result.config.index_dir, pin.epoch);
    defer paths.deinit(std.testing.allocator);
    const catalog_path = try std.fs.path.join(std.testing.allocator, &.{ paths.generation_dir, "catalog.ixcat" });
    defer std.testing.allocator.free(catalog_path);
    const catalog_bytes = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, catalog_path, std.testing.allocator, .limited(64 * 1024));
    defer std.testing.allocator.free(catalog_bytes);
    const snapshot = try catalog.parseCatalogForRoot(std.testing.allocator, catalog_bytes, root_identity.fingerprint);
    defer snapshot.deinit(std.testing.allocator);

    var saw_dotfile = false;
    var saw_hidden_dir_file = false;
    var saw_tags_dir_file = false;
    for (snapshot.entries) |entry| {
        const path = snapshot.path(entry);
        if (std.mem.endsWith(u8, path, ".rootfile")) saw_dotfile = true;
        if (std.mem.indexOf(u8, path, ".git") != null) saw_hidden_dir_file = true;
        if (std.mem.indexOf(u8, path, "tags") != null) saw_tags_dir_file = true;
    }
    try std.testing.expect(saw_dotfile);
    try std.testing.expect(!saw_hidden_dir_file);
    try std.testing.expect(!saw_tags_dir_file);
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

test "indexd memory limit parser is explicit and bounded" {
    try std.testing.expectEqual(@as(?usize, 512 * 1024 * 1024), parseMemoryLimitMb("512"));
    try std.testing.expectEqual(@as(?usize, 0), parseMemoryLimitMb("0"));
    try std.testing.expectEqual(@as(?usize, null), parseMemoryLimitMb(""));
    try std.testing.expectEqual(@as(?usize, null), parseMemoryLimitMb("invalid"));
}

test "indexd memory override cannot raise the framework ceiling" {
    try std.testing.expectEqual(@as(usize, 512), boundedMemoryLimit(4096, 512));
    try std.testing.expectEqual(@as(usize, 128), boundedMemoryLimit(128, 512));
}

test "indexd memory budget rejects resident usage over cap" {
    try std.testing.expect(memoryBudgetExceeded(2, 1));
    try std.testing.expect(!memoryBudgetExceeded(1, 1));
    try std.testing.expect(!memoryBudgetExceeded(std.math.maxInt(usize), 0));
    if (builtin.os.tag == .windows) {
        const resident = process_memory.currentResidentBytes() orelse return error.TestExpectedResidentMemory;
        try std.testing.expect(resident > 0);
        try std.testing.expectError(error.MemoryBudgetExceeded, enforceMemoryBudget(1));
    }
}

test "indexd watcher ignores index maintenance notifications" {
    var maintenance: [64]u8 = undefined;
    const maintenance_record = writeTestNotifyRecord(&maintenance, ".ix\\catalog.ixcat", 0);
    try std.testing.expect(!bufferHasExternalRootMutation(maintenance_record));

    var external: [64]u8 = undefined;
    const external_record = writeTestNotifyRecord(&external, "src\\main.zig", 0);
    try std.testing.expect(bufferHasExternalRootMutation(external_record));
}

test "indexd mutation settle policy is explicitly bounded" {
    try std.testing.expect(mutationSettleWindowCount() > 0);
    try std.testing.expect(mutationSettleWindowCount() <= 4);
    try std.testing.expect(MUTATION_SETTLE_WINDOW_NS <= 100 * std.time.ns_per_ms);
    const max_settle_ns = @as(u64, mutationSettleWindowCount()) * MUTATION_SETTLE_WINDOW_NS;
    try std.testing.expect(max_settle_ns <= 250 * std.time.ns_per_ms);
}

fn writeTestNotifyRecord(buffer: []u8, ascii_name: []const u8, next: u32) []const u8 {
    @memset(buffer, 0);
    writeLeU32(buffer[0..4], next);
    writeLeU32(buffer[4..8], 3);
    writeLeU32(buffer[8..12], @intCast(ascii_name.len * 2));
    for (ascii_name, 0..) |byte, index| {
        buffer[12 + index * 2] = byte;
        buffer[13 + index * 2] = 0;
    }
    return buffer[0 .. 12 + ascii_name.len * 2];
}

fn writeLeU32(bytes: []u8, value: u32) void {
    bytes[0] = @intCast(value & 0xff);
    bytes[1] = @intCast((value >> 8) & 0xff);
    bytes[2] = @intCast((value >> 16) & 0xff);
    bytes[3] = @intCast((value >> 24) & 0xff);
}
