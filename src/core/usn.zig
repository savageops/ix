const std = @import("std");

const catalog = @import("catalog.zig");
const generation = @import("generation.zig");
const postings = @import("postings.zig");
const state_dir = @import("state_dir.zig");
const windows = std.os.windows;

pub const CURSOR_MAGIC: [8]u8 = .{ 'I', 'X', 'U', 'S', 'N', '0', '0', '1' };
pub const CURSOR_FORMAT_VERSION: u16 = 1;
pub const CURSOR_READ_LIMIT: usize = 4096;

pub const USN = i64;
pub const DWORDLONG = u64;
pub const RootFingerprint = u128;
pub const FILE_DEVICE_FILE_SYSTEM: windows.DWORD = 0x0000_0009;
pub const METHOD_BUFFERED: windows.DWORD = 0;
pub const METHOD_NEITHER: windows.DWORD = 3;
pub const FILE_ANY_ACCESS: windows.DWORD = 0;

pub const FSCTL_QUERY_USN_JOURNAL: windows.DWORD = ctlCode(FILE_DEVICE_FILE_SYSTEM, 61, METHOD_BUFFERED, FILE_ANY_ACCESS);
pub const FSCTL_READ_USN_JOURNAL: windows.DWORD = ctlCode(FILE_DEVICE_FILE_SYSTEM, 46, METHOD_NEITHER, FILE_ANY_ACCESS);

pub const FILE_NOTIFY_CHANGE_FILE_NAME: windows.DWORD = 0x0000_0001;
pub const FILE_NOTIFY_CHANGE_DIR_NAME: windows.DWORD = 0x0000_0002;
pub const FILE_NOTIFY_CHANGE_ATTRIBUTES: windows.DWORD = 0x0000_0004;
pub const FILE_NOTIFY_CHANGE_SIZE: windows.DWORD = 0x0000_0008;
pub const FILE_NOTIFY_CHANGE_LAST_WRITE: windows.DWORD = 0x0000_0010;
pub const FILE_NOTIFY_CHANGE_CREATION: windows.DWORD = 0x0000_0040;
pub const IX_DIRECTORY_WATCH_NOTIFY_FILTER: windows.DWORD =
    FILE_NOTIFY_CHANGE_FILE_NAME |
    FILE_NOTIFY_CHANGE_DIR_NAME |
    FILE_NOTIFY_CHANGE_ATTRIBUTES |
    FILE_NOTIFY_CHANGE_SIZE |
    FILE_NOTIFY_CHANGE_LAST_WRITE |
    FILE_NOTIFY_CHANGE_CREATION;

pub const USN_REASON_DATA_OVERWRITE: windows.DWORD = 0x0000_0001;
pub const USN_REASON_DATA_EXTEND: windows.DWORD = 0x0000_0002;
pub const USN_REASON_DATA_TRUNCATION: windows.DWORD = 0x0000_0004;
pub const USN_REASON_FILE_CREATE: windows.DWORD = 0x0000_0100;
pub const USN_REASON_FILE_DELETE: windows.DWORD = 0x0000_0200;
pub const USN_REASON_RENAME_OLD_NAME: windows.DWORD = 0x0000_1000;
pub const USN_REASON_RENAME_NEW_NAME: windows.DWORD = 0x0000_2000;
pub const USN_REASON_CLOSE: windows.DWORD = 0x8000_0000;

pub const USN_REASON_IX_DELTA_RELEVANT: windows.DWORD =
    USN_REASON_DATA_OVERWRITE |
    USN_REASON_DATA_EXTEND |
    USN_REASON_DATA_TRUNCATION |
    USN_REASON_FILE_CREATE |
    USN_REASON_FILE_DELETE |
    USN_REASON_RENAME_OLD_NAME |
    USN_REASON_RENAME_NEW_NAME;

pub const UsnJournalDataV0 = extern struct {
    usn_journal_id: DWORDLONG = 0,
    first_usn: USN = 0,
    next_usn: USN = 0,
    lowest_valid_usn: USN = 0,
    max_usn: USN = 0,
    maximum_size: DWORDLONG = 0,
    allocation_delta: DWORDLONG = 0,
};

pub const ReadUsnJournalDataV1 = extern struct {
    start_usn: USN = 0,
    reason_mask: windows.DWORD = USN_REASON_IX_DELTA_RELEVANT,
    return_only_on_close: windows.DWORD = 0,
    timeout: DWORDLONG = 0,
    bytes_to_wait_for: DWORDLONG = 0,
    usn_journal_id: DWORDLONG = 0,
    min_major_version: u16 = 2,
    max_major_version: u16 = 3,
};

pub const FileId128 = extern struct {
    identifier: [16]u8 = @splat(0),
};

pub const FileSystemKind = enum(u8) {
    unknown = 0,
    ntfs = 1,
    refs = 2,
    unsupported = 255,
};

pub const VolumeIdentity = struct {
    root_fingerprint: RootFingerprint,
    volume_serial_number: windows.DWORD,
    filesystem: FileSystemKind,

    pub fn supportsUsn(self: VolumeIdentity) bool {
        return self.filesystem == .ntfs or self.filesystem == .refs;
    }
};

pub const JournalCursor = struct {
    volume: VolumeIdentity,
    usn_journal_id: DWORDLONG,
    first_usn: USN,
    next_usn: USN,
    lowest_valid_usn: USN,

    pub fn canContinue(self: JournalCursor, current: JournalCursor) bool {
        return self.volume.root_fingerprint == current.volume.root_fingerprint and
            self.volume.volume_serial_number == current.volume.volume_serial_number and
            self.volume.filesystem == current.volume.filesystem and
            self.usn_journal_id == current.usn_journal_id and
            self.next_usn >= current.lowest_valid_usn and
            self.next_usn <= current.next_usn;
    }
};

pub const JournalAvailabilityKind = enum(u8) {
    usable = 1,
    inaccessible = 2,
    unsupported_filesystem = 3,
    invalid_journal = 4,
};

pub const JournalProbeInput = union(enum) {
    journal: UsnJournalDataV0,
    inaccessible,
    unsupported_filesystem,
};

pub const JournalAvailability = struct {
    kind: JournalAvailabilityKind,
    cursor: ?JournalCursor = null,
    fallback_reason: []const u8 = "",

    pub fn canUseUsn(self: JournalAvailability) bool {
        return self.kind == .usable and self.cursor != null;
    }
};

pub const ReadBatchOptions = struct {
    max_records: usize = 1024,
    max_bytes: usize = 64 * 1024,
    cancelled: bool = false,
};

pub const UsnRecordSummary = struct {
    major_version: u16,
    minor_version: u16,
    record_length: windows.DWORD,
    reason: windows.DWORD,
    file_reference: JournalFileReference,
    parent_reference: JournalFileReference,
    file_name_offset: u16,
    file_name_length: u16,
};

pub const JournalFileReference = union(enum) {
    v2: u64,
    v3: FileId128,

    pub fn eql(self: JournalFileReference, other: JournalFileReference) bool {
        return switch (self) {
            .v2 => |lhs| switch (other) {
                .v2 => |rhs| lhs == rhs,
                .v3 => false,
            },
            .v3 => |lhs| switch (other) {
                .v2 => false,
                .v3 => |rhs| std.mem.eql(u8, &lhs.identifier, &rhs.identifier),
            },
        };
    }
};

pub const CatalogReferenceEntry = struct {
    journal_reference: JournalFileReference,
    file_id: catalog.FileId,
};

pub const CatalogReferenceResolver = struct {
    entries: []const CatalogReferenceEntry = &.{},

    pub fn resolve(self: CatalogReferenceResolver, journal_reference: JournalFileReference) ?catalog.FileId {
        for (self.entries) |entry| {
            if (entry.journal_reference.eql(journal_reference)) return entry.file_id;
        }
        return null;
    }
};

pub const PendingPathLookup = struct {
    file_reference: JournalFileReference,
    parent_reference: JournalFileReference,
    file_name_offset: u16,
    file_name_length: u16,
};

pub const RecordPathResolution = union(enum) {
    catalog_file_id: catalog.FileId,
    pending_path_lookup: PendingPathLookup,
};

pub const DeltaTaskKind = enum {
    upsert_file,
    delete_file,
    reconcile_root,
};

pub const DeltaTask = struct {
    kind: DeltaTaskKind,
    reason: windows.DWORD,
    resolution: ?RecordPathResolution = null,
};

pub const ContinuityFailureKind = enum {
    lost_cursor,
    journal_wrapped,
    batch_overflow,
};

pub const ContinuityDecision = union(enum) {
    apply_delta,
    reconcile_root: ContinuityFailureKind,
};

pub const FreshnessBackendKind = enum {
    usn_delta,
    directory_watch_invalidate,
};

pub const FreshnessBackend = struct {
    kind: FreshnessBackendKind,
    notify_filter: windows.DWORD = 0,
    fallback_reason: []const u8 = "",

    pub fn requiresRootReconcile(self: FreshnessBackend) bool {
        return self.kind == .directory_watch_invalidate;
    }
};

pub const DeltaApplyMode = enum {
    incremental_segment_update,
    root_reconcile_publish,
};

pub const DeltaApplyPolicy = struct {
    max_delta_tasks: usize = 256,

    pub fn admits(self: DeltaApplyPolicy, task_count: usize) bool {
        return task_count <= self.max_delta_tasks;
    }
};

pub const DeltaApplyPlan = struct {
    mode: DeltaApplyMode,
    upsert_count: usize = 0,
    delete_count: usize = 0,
    reconcile_required: bool = false,

    pub fn publishesFullGeneration(self: DeltaApplyPlan) bool {
        return self.mode == .root_reconcile_publish;
    }
};

pub const DeltaOverlayState = enum {
    clean,
    upsert_pending,
    delete_pending,
    tombstone,
    root_reconcile_required,
};

pub const DeltaOverlayEntry = struct {
    state: DeltaOverlayState,
    file_id: ?catalog.FileId = null,
    resolution: ?RecordPathResolution = null,
    reason: windows.DWORD = 0,

    pub fn blocksBaseCandidate(self: DeltaOverlayEntry, candidate_file_id: catalog.FileId) bool {
        return self.file_id != null and
            self.file_id.? == candidate_file_id and
            (self.state == .delete_pending or self.state == .tombstone or self.state == .root_reconcile_required);
    }
};

pub const DeltaOverlayPlan = struct {
    base_epoch: generation.Epoch,
    delta_epoch: generation.Epoch,
    entries: []DeltaOverlayEntry = &.{},
    reconcile_required: bool = false,
    fallback_reason: []const u8 = "",
    upsert_count: usize = 0,
    tombstone_count: usize = 0,

    pub fn deinit(self: DeltaOverlayPlan, allocator: std.mem.Allocator) void {
        allocator.free(self.entries);
    }

    pub fn pinsConsistentView(self: DeltaOverlayPlan) bool {
        return self.base_epoch != generation.INVALID_EPOCH and
            self.delta_epoch != generation.INVALID_EPOCH and
            self.delta_epoch >= self.base_epoch;
    }
};

pub const DeltaGenerationInput = struct {
    root: []const u8,
    root_fingerprint: catalog.RootFingerprint,
    epoch: generation.Epoch,
    parent_epoch: ?generation.Epoch = null,
    catalog_files: []const catalog.CatalogFileInput,
    postings_files: []const postings.PostingsFileInput,
};

pub const ReadBatchResult = struct {
    next_start_usn: USN,
    records: []UsnRecordSummary,
    truncated_by_limit: bool = false,

    pub fn deinit(self: ReadBatchResult, allocator: std.mem.Allocator) void {
        allocator.free(self.records);
    }
};

pub const JournalPaths = struct {
    journals_dir: []const u8,
    cursor_path: []const u8,
    tmp_cursor_path: []const u8,

    pub fn deinit(self: JournalPaths, allocator: std.mem.Allocator) void {
        allocator.free(self.journals_dir);
        allocator.free(self.cursor_path);
        allocator.free(self.tmp_cursor_path);
    }
};

pub const UsnRecordHeader = extern struct {
    record_length: windows.DWORD,
    major_version: u16,
    minor_version: u16,
};

pub const UsnRecordV2Prefix = extern struct {
    record_length: windows.DWORD,
    major_version: u16,
    minor_version: u16,
    file_reference_number: u64,
    parent_file_reference_number: u64,
    usn: USN,
    timestamp: i64,
    reason: windows.DWORD,
    source_info: windows.DWORD,
    security_id: windows.DWORD,
    file_attributes: windows.DWORD,
    file_name_length: u16,
    file_name_offset: u16,
};

pub const UsnRecordV3Prefix = extern struct {
    record_length: windows.DWORD,
    major_version: u16,
    minor_version: u16,
    file_reference_number: FileId128,
    parent_file_reference_number: FileId128,
    usn: USN,
    timestamp: i64,
    reason: windows.DWORD,
    source_info: windows.DWORD,
    security_id: windows.DWORD,
    file_attributes: windows.DWORD,
    file_name_length: u16,
    file_name_offset: u16,
};

pub extern "kernel32" fn DeviceIoControl(
    hDevice: windows.HANDLE,
    dwIoControlCode: windows.DWORD,
    lpInBuffer: ?*const anyopaque,
    nInBufferSize: windows.DWORD,
    lpOutBuffer: ?*anyopaque,
    nOutBufferSize: windows.DWORD,
    lpBytesReturned: ?*windows.DWORD,
    lpOverlapped: ?*anyopaque,
) callconv(.winapi) windows.BOOL;

pub extern "kernel32" fn ReadDirectoryChangesW(
    hDirectory: windows.HANDLE,
    lpBuffer: ?*anyopaque,
    nBufferLength: windows.DWORD,
    bWatchSubtree: windows.BOOL,
    dwNotifyFilter: windows.DWORD,
    lpBytesReturned: ?*windows.DWORD,
    lpOverlapped: ?*anyopaque,
    lpCompletionRoutine: ?*anyopaque,
) callconv(.winapi) windows.BOOL;

pub fn ctlCode(device_type: windows.DWORD, function: windows.DWORD, method: windows.DWORD, access: windows.DWORD) windows.DWORD {
    return (device_type << 16) | (access << 14) | (function << 2) | method;
}

pub fn readRequest(start_usn: USN, journal_id: DWORDLONG) ReadUsnJournalDataV1 {
    return .{
        .start_usn = start_usn,
        .usn_journal_id = journal_id,
    };
}

pub fn readBatchRequest(cursor: JournalCursor, timeout_ms: DWORDLONG, bytes_to_wait_for: DWORDLONG) ReadUsnJournalDataV1 {
    var request = readRequest(cursor.next_usn, cursor.usn_journal_id);
    request.timeout = timeout_ms;
    request.bytes_to_wait_for = bytes_to_wait_for;
    return request;
}

pub fn buildJournalPaths(allocator: std.mem.Allocator, root: []const u8) !JournalPaths {
    const identity = try catalog.identifyRoot(allocator, root);
    defer identity.deinit(allocator);
    const state = try state_dir.buildRootIndexState(allocator, identity.fingerprint);
    defer state.deinit(allocator);
    return buildJournalPathsInIndexDir(allocator, state.index_dir);
}

pub fn buildJournalPathsInIndexDir(allocator: std.mem.Allocator, index_dir: []const u8) !JournalPaths {
    const journals_dir = try std.fs.path.join(allocator, &.{ index_dir, "journals" });
    errdefer allocator.free(journals_dir);
    const cursor_path = try std.fs.path.join(allocator, &.{ journals_dir, "ntfs-usn.cursor" });
    errdefer allocator.free(cursor_path);
    const tmp_cursor_path = try std.fs.path.join(allocator, &.{ journals_dir, "ntfs-usn.cursor.tmp" });
    errdefer allocator.free(tmp_cursor_path);
    return .{
        .journals_dir = journals_dir,
        .cursor_path = cursor_path,
        .tmp_cursor_path = tmp_cursor_path,
    };
}

pub fn cursorFromJournalData(volume: VolumeIdentity, data: UsnJournalDataV0) !JournalCursor {
    if (!volume.supportsUsn()) return error.UnsupportedJournalFileSystem;
    if (data.usn_journal_id == 0) return error.InvalidUsnJournalId;
    if (data.next_usn < data.first_usn) return error.InvalidUsnRange;
    if (data.lowest_valid_usn < data.first_usn) return error.InvalidUsnRange;
    if (data.lowest_valid_usn > data.next_usn) return error.InvalidUsnRange;

    return .{
        .volume = volume,
        .usn_journal_id = data.usn_journal_id,
        .first_usn = data.first_usn,
        .next_usn = data.next_usn,
        .lowest_valid_usn = data.lowest_valid_usn,
    };
}

pub fn classifyJournalAvailability(volume: VolumeIdentity, input: JournalProbeInput) JournalAvailability {
    if (!volume.supportsUsn()) {
        return .{
            .kind = .unsupported_filesystem,
            .fallback_reason = "unsupported_filesystem",
        };
    }

    return switch (input) {
        .journal => |data| blk: {
            const cursor = cursorFromJournalData(volume, data) catch break :blk .{
                .kind = .invalid_journal,
                .fallback_reason = "invalid_journal",
            };
            break :blk .{
                .kind = .usable,
                .cursor = cursor,
                .fallback_reason = "",
            };
        },
        .inaccessible => .{
            .kind = .inaccessible,
            .fallback_reason = "journal_inaccessible",
        },
        .unsupported_filesystem => .{
            .kind = .unsupported_filesystem,
            .fallback_reason = "unsupported_filesystem",
        },
    };
}

pub fn parseReadBatch(allocator: std.mem.Allocator, bytes: []const u8, options: ReadBatchOptions) !ReadBatchResult {
    if (options.cancelled) return error.OperationCancelled;
    if (options.max_records == 0) return error.EmptyUsnBatchCapacity;
    if (bytes.len > options.max_bytes) return error.UsnBatchTooLarge;

    var cursor = ByteCursor{ .bytes = bytes };
    const next_start_usn = try cursor.readI64();
    var records = std.ArrayList(UsnRecordSummary).empty;
    errdefer records.deinit(allocator);

    var truncated_by_limit = false;
    while (cursor.remaining() > 0) {
        if (options.cancelled) return error.OperationCancelled;
        if (records.items.len >= options.max_records) {
            truncated_by_limit = true;
            break;
        }

        const remaining = cursor.bytes[cursor.index..];
        const summary = try parseRecordSummary(remaining);
        try records.append(allocator, summary);
        _ = try cursor.take(summary.record_length);
    }

    return .{
        .next_start_usn = next_start_usn,
        .records = try records.toOwnedSlice(allocator),
        .truncated_by_limit = truncated_by_limit,
    };
}

pub fn resolveRecordPath(summary: UsnRecordSummary, resolver: CatalogReferenceResolver) RecordPathResolution {
    if (resolver.resolve(summary.file_reference)) |file_id| {
        return .{ .catalog_file_id = file_id };
    }

    return .{ .pending_path_lookup = .{
        .file_reference = summary.file_reference,
        .parent_reference = summary.parent_reference,
        .file_name_offset = summary.file_name_offset,
        .file_name_length = summary.file_name_length,
    } };
}

pub fn mapRecordToDeltaTask(summary: UsnRecordSummary, resolver: CatalogReferenceResolver) DeltaTask {
    const upsert_bits = USN_REASON_DATA_OVERWRITE |
        USN_REASON_DATA_EXTEND |
        USN_REASON_DATA_TRUNCATION |
        USN_REASON_FILE_CREATE |
        USN_REASON_RENAME_NEW_NAME;
    const delete_bits = USN_REASON_FILE_DELETE | USN_REASON_RENAME_OLD_NAME;
    const has_upsert = (summary.reason & upsert_bits) != 0;
    const has_delete = (summary.reason & delete_bits) != 0;
    const resolution = resolveRecordPath(summary, resolver);

    if (has_upsert and !has_delete) {
        return .{
            .kind = .upsert_file,
            .reason = summary.reason,
            .resolution = resolution,
        };
    }
    if (has_delete and !has_upsert) {
        return .{
            .kind = .delete_file,
            .reason = summary.reason,
            .resolution = resolution,
        };
    }

    return .{
        .kind = .reconcile_root,
        .reason = summary.reason,
        .resolution = resolution,
    };
}

pub fn coalesceDeltaTasks(allocator: std.mem.Allocator, tasks: []const DeltaTask) ![]DeltaTask {
    var coalesced = std.ArrayList(DeltaTask).empty;
    errdefer coalesced.deinit(allocator);
    var reconcile_reason: windows.DWORD = 0;

    for (tasks) |task| {
        reconcile_reason |= task.reason;
        if (task.kind == .reconcile_root or task.resolution == null) {
            coalesced.deinit(allocator);
            return singletonDeltaTask(allocator, .{
                .kind = .reconcile_root,
                .reason = reconcile_reason,
                .resolution = task.resolution,
            });
        }

        var replaced = false;
        for (coalesced.items) |*existing| {
            if (recordPathResolutionEql(existing.resolution.?, task.resolution.?)) {
                existing.* = .{
                    .kind = task.kind,
                    .reason = existing.reason | task.reason,
                    .resolution = task.resolution,
                };
                replaced = true;
                break;
            }
        }
        if (!replaced) try coalesced.append(allocator, task);
    }

    return coalesced.toOwnedSlice(allocator);
}

pub fn evaluateDeltaContinuity(previous: ?JournalCursor, current: JournalCursor, batch: ReadBatchResult) ContinuityDecision {
    const previous_cursor = previous orelse return .{ .reconcile_root = .lost_cursor };
    if (!previous_cursor.canContinue(current)) return .{ .reconcile_root = .journal_wrapped };
    if (batch.truncated_by_limit) return .{ .reconcile_root = .batch_overflow };
    return .apply_delta;
}

pub fn continuityReconcileTask(decision: ContinuityDecision) ?DeltaTask {
    return switch (decision) {
        .apply_delta => null,
        .reconcile_root => .{
            .kind = .reconcile_root,
            .reason = 0,
            .resolution = null,
        },
    };
}

pub fn chooseFreshnessBackend(availability: JournalAvailability) FreshnessBackend {
    if (availability.canUseUsn()) {
        return .{
            .kind = .usn_delta,
            .notify_filter = 0,
            .fallback_reason = "",
        };
    }

    return .{
        .kind = .directory_watch_invalidate,
        .notify_filter = IX_DIRECTORY_WATCH_NOTIFY_FILTER,
        .fallback_reason = availability.fallback_reason,
    };
}

pub fn directoryWatchInvalidationTask(backend: FreshnessBackend) ?DeltaTask {
    if (!backend.requiresRootReconcile()) return null;
    return .{
        .kind = .reconcile_root,
        .reason = 0,
        .resolution = null,
    };
}

pub fn planDeltaApply(tasks: []const DeltaTask) DeltaApplyPlan {
    return planDeltaApplyWithPolicy(tasks, .{});
}

pub fn planDeltaApplyWithPolicy(tasks: []const DeltaTask, policy: DeltaApplyPolicy) DeltaApplyPlan {
    var plan = DeltaApplyPlan{ .mode = .incremental_segment_update };
    if (!policy.admits(tasks.len)) {
        plan.mode = .root_reconcile_publish;
        plan.reconcile_required = true;
    }
    for (tasks) |task| {
        switch (task.kind) {
            .upsert_file => plan.upsert_count += 1,
            .delete_file => plan.delete_count += 1,
            .reconcile_root => {
                plan.mode = .root_reconcile_publish;
                plan.reconcile_required = true;
            },
        }
        if (task.resolution) |resolution| {
            switch (resolution) {
                .catalog_file_id => {},
                .pending_path_lookup => {
                    plan.mode = .root_reconcile_publish;
                    plan.reconcile_required = true;
                },
            }
        } else {
            plan.mode = .root_reconcile_publish;
            plan.reconcile_required = true;
        }
    }
    return plan;
}

pub fn planDeltaOverlay(
    allocator: std.mem.Allocator,
    base_epoch: generation.Epoch,
    delta_epoch: generation.Epoch,
    tasks: []const DeltaTask,
    policy: DeltaApplyPolicy,
) !DeltaOverlayPlan {
    if (base_epoch == generation.INVALID_EPOCH or delta_epoch == generation.INVALID_EPOCH or delta_epoch < base_epoch) {
        return error.InvalidDeltaEpoch;
    }

    if (!policy.admits(tasks.len)) {
        return .{
            .base_epoch = base_epoch,
            .delta_epoch = delta_epoch,
            .reconcile_required = true,
            .fallback_reason = "root_reconcile_required",
        };
    }

    var entries = std.ArrayList(DeltaOverlayEntry).empty;
    errdefer entries.deinit(allocator);
    var upsert_count: usize = 0;
    var tombstone_count: usize = 0;
    for (tasks) |task| {
        if (task.kind == .reconcile_root) {
            entries.deinit(allocator);
            return .{
                .base_epoch = base_epoch,
                .delta_epoch = delta_epoch,
                .reconcile_required = true,
                .fallback_reason = "root_reconcile_required",
            };
        }
        const resolution = task.resolution orelse {
            entries.deinit(allocator);
            return .{
                .base_epoch = base_epoch,
                .delta_epoch = delta_epoch,
                .reconcile_required = true,
                .fallback_reason = "unresolved_delta_task",
            };
        };
        const file_id = switch (resolution) {
            .catalog_file_id => |id| id,
            .pending_path_lookup => {
                entries.deinit(allocator);
                return .{
                    .base_epoch = base_epoch,
                    .delta_epoch = delta_epoch,
                    .reconcile_required = true,
                    .fallback_reason = "pending_path_lookup",
                };
            },
        };
        const state: DeltaOverlayState = switch (task.kind) {
            .upsert_file => .upsert_pending,
            .delete_file => .tombstone,
            .reconcile_root => .root_reconcile_required,
        };
        switch (state) {
            .upsert_pending => upsert_count += 1,
            .tombstone => tombstone_count += 1,
            .clean, .delete_pending, .root_reconcile_required => {},
        }
        try entries.append(allocator, .{
            .state = state,
            .file_id = file_id,
            .resolution = resolution,
            .reason = task.reason,
        });
    }

    return .{
        .base_epoch = base_epoch,
        .delta_epoch = delta_epoch,
        .entries = try entries.toOwnedSlice(allocator),
        .reconcile_required = false,
        .upsert_count = upsert_count,
        .tombstone_count = tombstone_count,
    };
}

pub fn publishDeltaGeneration(
    io: std.Io,
    allocator: std.mem.Allocator,
    paths: generation.GenerationPaths,
    input: DeltaGenerationInput,
) !generation.ReaderPin {
    if (input.postings_files.len > input.catalog_files.len) return error.DeltaApplyInputCountMismatch;

    const catalog_bytes = try catalog.buildCatalogBytes(allocator, input.root, input.epoch, input.catalog_files);
    defer allocator.free(catalog_bytes);
    const postings_segment = try postings.buildPostingsSegment(allocator, input.root_fingerprint, input.epoch, input.postings_files, 0);
    defer postings_segment.deinit(allocator);
    const postings_bytes = try postings.serializePostingsSegment(allocator, postings_segment);
    defer allocator.free(postings_bytes);

    const payloads = [_]generation.SegmentPayload{
        .{ .kind = .catalog, .relative_path = "catalog.ixcat", .bytes = catalog_bytes },
        .{ .kind = .postings, .relative_path = "postings.ixpost", .bytes = postings_bytes },
    };
    return generation.publishGenerationPayloads(io, allocator, paths, input.root_fingerprint, input.epoch, input.parent_epoch, &payloads);
}

pub fn serializeJournalCursor(allocator: std.mem.Allocator, cursor: JournalCursor) ![]u8 {
    try validateJournalCursor(cursor);

    var bytes = std.ArrayList(u8).empty;
    errdefer bytes.deinit(allocator);
    try bytes.appendSlice(allocator, &CURSOR_MAGIC);
    try appendU16(&bytes, allocator, CURSOR_FORMAT_VERSION);
    try bytes.append(allocator, @intFromEnum(cursor.volume.filesystem));
    try bytes.appendNTimes(allocator, 0, 5);
    try appendU64(&bytes, allocator, @intCast(cursor.volume.root_fingerprint >> 64));
    try appendU64(&bytes, allocator, @intCast(cursor.volume.root_fingerprint & std.math.maxInt(u64)));
    try appendU32(&bytes, allocator, cursor.volume.volume_serial_number);
    try appendU32(&bytes, allocator, 0);
    try appendU64(&bytes, allocator, cursor.usn_journal_id);
    try appendI64(&bytes, allocator, cursor.first_usn);
    try appendI64(&bytes, allocator, cursor.next_usn);
    try appendI64(&bytes, allocator, cursor.lowest_valid_usn);
    return bytes.toOwnedSlice(allocator);
}

pub fn parseJournalCursorForVolume(bytes: []const u8, expected_volume: VolumeIdentity) !JournalCursor {
    var cursor = ByteCursor{ .bytes = bytes };
    if (!std.mem.eql(u8, try cursor.take(CURSOR_MAGIC.len), &CURSOR_MAGIC)) return error.BadUsnCursorMagic;
    if (try cursor.readU16() != CURSOR_FORMAT_VERSION) return error.UnsupportedUsnCursorVersion;
    const filesystem_byte = try cursor.readByte();
    _ = try cursor.take(5);
    const root_hi = try cursor.readU64();
    const root_lo = try cursor.readU64();
    const volume_serial_number = try cursor.readU32();
    _ = try cursor.readU32();
    const journal_id = try cursor.readU64();
    const first_usn = try cursor.readI64();
    const next_usn = try cursor.readI64();
    const lowest_valid_usn = try cursor.readI64();
    if (cursor.remaining() != 0) return error.TrailingUsnCursorData;

    const filesystem = fileSystemKindFromByte(filesystem_byte) orelse return error.UnsupportedJournalFileSystem;
    const volume = VolumeIdentity{
        .root_fingerprint = (@as(RootFingerprint, root_hi) << 64) | @as(RootFingerprint, root_lo),
        .volume_serial_number = volume_serial_number,
        .filesystem = filesystem,
    };
    if (volume.root_fingerprint != expected_volume.root_fingerprint or
        volume.volume_serial_number != expected_volume.volume_serial_number or
        volume.filesystem != expected_volume.filesystem)
    {
        return error.WrongUsnCursorVolume;
    }
    return try cursorFromJournalData(volume, .{
        .usn_journal_id = journal_id,
        .first_usn = first_usn,
        .next_usn = next_usn,
        .lowest_valid_usn = lowest_valid_usn,
    });
}

pub fn publishJournalCursor(io: std.Io, allocator: std.mem.Allocator, paths: JournalPaths, cursor: JournalCursor) !void {
    const bytes = try serializeJournalCursor(allocator, cursor);
    defer allocator.free(bytes);
    try publishJournalCursorBytes(io, paths, bytes);
}

pub fn publishJournalCursorBytes(io: std.Io, paths: JournalPaths, bytes: []const u8) !void {
    if (bytes.len == 0) return error.EmptyUsnCursor;

    try std.Io.Dir.cwd().createDirPath(io, paths.journals_dir);
    var atomic_file = try std.Io.Dir.cwd().createFileAtomic(io, paths.cursor_path, .{ .replace = true });
    defer atomic_file.deinit(io);
    try atomic_file.file.writeStreamingAll(io, bytes);
    try atomic_file.file.sync(io);
    try atomic_file.replace(io);
}

pub fn tryLoadJournalCursor(io: std.Io, allocator: std.mem.Allocator, path: []const u8, expected_volume: VolumeIdentity) !?JournalCursor {
    const bytes = std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(CURSOR_READ_LIMIT)) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    defer allocator.free(bytes);
    return parseJournalCursorForVolume(bytes, expected_volume) catch null;
}

fn validateJournalCursor(cursor: JournalCursor) !void {
    if (!cursor.volume.supportsUsn()) return error.UnsupportedJournalFileSystem;
    if (cursor.usn_journal_id == 0) return error.InvalidUsnJournalId;
    if (cursor.next_usn < cursor.first_usn) return error.InvalidUsnRange;
    if (cursor.lowest_valid_usn < cursor.first_usn) return error.InvalidUsnRange;
    if (cursor.lowest_valid_usn > cursor.next_usn) return error.InvalidUsnRange;
}

fn parseRecordSummary(bytes: []const u8) !UsnRecordSummary {
    if (bytes.len < @sizeOf(UsnRecordHeader)) return error.TruncatedUsnRecord;
    var cursor = ByteCursor{ .bytes = bytes };
    const record_length = try cursor.readU32();
    const major_version = try cursor.readU16();
    const minor_version = try cursor.readU16();
    if (record_length < @sizeOf(UsnRecordHeader)) return error.InvalidUsnRecordLength;
    if (record_length > bytes.len) return error.TruncatedUsnRecord;

    const file_reference: JournalFileReference, const parent_reference: JournalFileReference, const reason_offset: usize, const file_name_length_offset: usize, const file_name_offset_offset: usize = switch (major_version) {
        2 => .{
            .{ .v2 = readU64At(bytes, 8) },
            .{ .v2 = readU64At(bytes, 16) },
            40,
            56,
            58,
        },
        3 => .{
            .{ .v3 = readFileId128At(bytes, 8) },
            .{ .v3 = readFileId128At(bytes, 24) },
            56,
            72,
            74,
        },
        else => return error.UnsupportedUsnRecordVersion,
    };
    if (record_length < file_name_offset_offset + @sizeOf(u16)) return error.TruncatedUsnRecord;

    const reason = readU32At(bytes, reason_offset);
    const file_name_length = readU16At(bytes, file_name_length_offset);
    const file_name_offset = readU16At(bytes, file_name_offset_offset);
    if (@as(usize, file_name_offset) + file_name_length > record_length) return error.InvalidUsnRecordNameBounds;

    return .{
        .major_version = major_version,
        .minor_version = minor_version,
        .record_length = record_length,
        .reason = reason,
        .file_reference = file_reference,
        .parent_reference = parent_reference,
        .file_name_offset = file_name_offset,
        .file_name_length = file_name_length,
    };
}

fn readU16At(bytes: []const u8, offset: usize) u16 {
    return @as(u16, bytes[offset]) | (@as(u16, bytes[offset + 1]) << 8);
}

fn readU32At(bytes: []const u8, offset: usize) u32 {
    return @as(u32, bytes[offset]) |
        (@as(u32, bytes[offset + 1]) << 8) |
        (@as(u32, bytes[offset + 2]) << 16) |
        (@as(u32, bytes[offset + 3]) << 24);
}

fn readU64At(bytes: []const u8, offset: usize) u64 {
    var value: u64 = 0;
    var index: usize = 0;
    while (index < @sizeOf(u64)) : (index += 1) value |= @as(u64, bytes[offset + index]) << @intCast(index * 8);
    return value;
}

fn readFileId128At(bytes: []const u8, offset: usize) FileId128 {
    var id = FileId128{};
    @memcpy(&id.identifier, bytes[offset .. offset + id.identifier.len]);
    return id;
}

fn singletonDeltaTask(allocator: std.mem.Allocator, task: DeltaTask) ![]DeltaTask {
    const tasks = try allocator.alloc(DeltaTask, 1);
    tasks[0] = task;
    return tasks;
}

fn recordPathResolutionEql(lhs: RecordPathResolution, rhs: RecordPathResolution) bool {
    return switch (lhs) {
        .catalog_file_id => |lhs_file_id| switch (rhs) {
            .catalog_file_id => |rhs_file_id| lhs_file_id == rhs_file_id,
            .pending_path_lookup => false,
        },
        .pending_path_lookup => |lhs_lookup| switch (rhs) {
            .catalog_file_id => false,
            .pending_path_lookup => |rhs_lookup| lhs_lookup.file_reference.eql(rhs_lookup.file_reference),
        },
    };
}

fn fileSystemKindFromByte(byte: u8) ?FileSystemKind {
    return switch (byte) {
        @intFromEnum(FileSystemKind.unknown) => .unknown,
        @intFromEnum(FileSystemKind.ntfs) => .ntfs,
        @intFromEnum(FileSystemKind.refs) => .refs,
        @intFromEnum(FileSystemKind.unsupported) => .unsupported,
        else => null,
    };
}

fn appendU16(bytes: *std.ArrayList(u8), allocator: std.mem.Allocator, value: u16) !void {
    try bytes.append(allocator, @intCast(value & 0xff));
    try bytes.append(allocator, @intCast((value >> 8) & 0xff));
}

fn appendU32(bytes: *std.ArrayList(u8), allocator: std.mem.Allocator, value: u32) !void {
    var shift: u6 = 0;
    while (shift < 32) : (shift += 8) try bytes.append(allocator, @intCast((value >> @as(u5, @intCast(shift))) & 0xff));
}

fn appendU64(bytes: *std.ArrayList(u8), allocator: std.mem.Allocator, value: u64) !void {
    var shift: usize = 0;
    while (shift < 64) : (shift += 8) try bytes.append(allocator, @intCast((value >> @as(u6, @intCast(shift))) & 0xff));
}

fn appendI64(bytes: *std.ArrayList(u8), allocator: std.mem.Allocator, value: i64) !void {
    try appendU64(bytes, allocator, @bitCast(value));
}

const ByteCursor = struct {
    bytes: []const u8,
    index: usize = 0,

    fn take(self: *ByteCursor, len: usize) ![]const u8 {
        if (len > self.bytes.len - self.index) return error.TruncatedUsnCursor;
        const start = self.index;
        self.index += len;
        return self.bytes[start..self.index];
    }

    fn remaining(self: ByteCursor) usize {
        return self.bytes.len - self.index;
    }

    fn readByte(self: *ByteCursor) !u8 {
        return (try self.take(1))[0];
    }

    fn readU16(self: *ByteCursor) !u16 {
        const raw = try self.take(2);
        return @as(u16, raw[0]) | (@as(u16, raw[1]) << 8);
    }

    fn readU32(self: *ByteCursor) !u32 {
        const raw = try self.take(4);
        return @as(u32, raw[0]) |
            (@as(u32, raw[1]) << 8) |
            (@as(u32, raw[2]) << 16) |
            (@as(u32, raw[3]) << 24);
    }

    fn readU64(self: *ByteCursor) !u64 {
        const raw = try self.take(8);
        var value: u64 = 0;
        var index: usize = 0;
        while (index < raw.len) : (index += 1) value |= @as(u64, raw[index]) << @intCast(index * 8);
        return value;
    }

    fn readI64(self: *ByteCursor) !i64 {
        return @bitCast(try self.readU64());
    }
};

test "usn control codes match winioctl contract" {
    try std.testing.expectEqual(@as(windows.DWORD, 0x0009_00f4), FSCTL_QUERY_USN_JOURNAL);
    try std.testing.expectEqual(@as(windows.DWORD, 0x0009_00bb), FSCTL_READ_USN_JOURNAL);
}

test "directory watch fallback constants cover invalidating file tree changes" {
    try std.testing.expect((IX_DIRECTORY_WATCH_NOTIFY_FILTER & FILE_NOTIFY_CHANGE_FILE_NAME) != 0);
    try std.testing.expect((IX_DIRECTORY_WATCH_NOTIFY_FILTER & FILE_NOTIFY_CHANGE_DIR_NAME) != 0);
    try std.testing.expect((IX_DIRECTORY_WATCH_NOTIFY_FILTER & FILE_NOTIFY_CHANGE_SIZE) != 0);
    try std.testing.expect((IX_DIRECTORY_WATCH_NOTIFY_FILTER & FILE_NOTIFY_CHANGE_LAST_WRITE) != 0);
}

test "usn ffi structs preserve Windows field offsets" {
    try std.testing.expectEqual(@as(usize, 0), @offsetOf(UsnJournalDataV0, "usn_journal_id"));
    try std.testing.expectEqual(@as(usize, 8), @offsetOf(UsnJournalDataV0, "first_usn"));
    try std.testing.expectEqual(@as(usize, 48), @offsetOf(UsnJournalDataV0, "allocation_delta"));
    try std.testing.expectEqual(@as(usize, 0), @offsetOf(ReadUsnJournalDataV1, "start_usn"));
    try std.testing.expectEqual(@as(usize, 40), @offsetOf(ReadUsnJournalDataV1, "min_major_version"));
    try std.testing.expectEqual(@as(usize, 42), @offsetOf(ReadUsnJournalDataV1, "max_major_version"));
    try std.testing.expectEqual(@as(usize, 58), @offsetOf(UsnRecordV2Prefix, "file_name_offset"));
    try std.testing.expectEqual(@as(usize, 74), @offsetOf(UsnRecordV3Prefix, "file_name_offset"));
}

test "usn read request defaults to ix delta-relevant reasons" {
    const request = readRequest(123, 456);
    try std.testing.expectEqual(@as(USN, 123), request.start_usn);
    try std.testing.expectEqual(@as(DWORDLONG, 456), request.usn_journal_id);
    try std.testing.expectEqual(USN_REASON_IX_DELTA_RELEVANT, request.reason_mask);
    try std.testing.expectEqual(@as(u16, 2), request.min_major_version);
    try std.testing.expectEqual(@as(u16, 3), request.max_major_version);
}

test "journal cursor captures volume identity journal id and usn range" {
    const volume = VolumeIdentity{
        .root_fingerprint = 0x1234,
        .volume_serial_number = 0xfeed,
        .filesystem = .ntfs,
    };
    const cursor = try cursorFromJournalData(volume, .{
        .usn_journal_id = 0x99,
        .first_usn = 10,
        .next_usn = 100,
        .lowest_valid_usn = 10,
    });

    try std.testing.expectEqual(@as(RootFingerprint, 0x1234), cursor.volume.root_fingerprint);
    try std.testing.expectEqual(@as(windows.DWORD, 0xfeed), cursor.volume.volume_serial_number);
    try std.testing.expectEqual(@as(DWORDLONG, 0x99), cursor.usn_journal_id);
    try std.testing.expectEqual(@as(USN, 100), cursor.next_usn);
}

test "journal cursor rejects unsupported or discontinuous identity" {
    const unsupported = VolumeIdentity{
        .root_fingerprint = 0x1234,
        .volume_serial_number = 0xfeed,
        .filesystem = .unsupported,
    };
    try std.testing.expectError(error.UnsupportedJournalFileSystem, cursorFromJournalData(unsupported, .{
        .usn_journal_id = 1,
        .first_usn = 1,
        .next_usn = 2,
        .lowest_valid_usn = 1,
    }));

    const ntfs = VolumeIdentity{
        .root_fingerprint = 0x1234,
        .volume_serial_number = 0xfeed,
        .filesystem = .ntfs,
    };
    try std.testing.expectError(error.InvalidUsnRange, cursorFromJournalData(ntfs, .{
        .usn_journal_id = 1,
        .first_usn = 10,
        .next_usn = 9,
        .lowest_valid_usn = 10,
    }));

    const previous = try cursorFromJournalData(ntfs, .{
        .usn_journal_id = 7,
        .first_usn = 1,
        .next_usn = 50,
        .lowest_valid_usn = 1,
    });
    const current = try cursorFromJournalData(ntfs, .{
        .usn_journal_id = 7,
        .first_usn = 1,
        .next_usn = 80,
        .lowest_valid_usn = 60,
    });
    try std.testing.expect(!previous.canContinue(current));
}

test "journal cursor serializes validates and rejects wrong volume" {
    const volume = VolumeIdentity{
        .root_fingerprint = 0x123456789abcdef,
        .volume_serial_number = 0xabcd,
        .filesystem = .ntfs,
    };
    const cursor = try cursorFromJournalData(volume, .{
        .usn_journal_id = 9,
        .first_usn = 1,
        .next_usn = 40,
        .lowest_valid_usn = 1,
    });
    const bytes = try serializeJournalCursor(std.testing.allocator, cursor);
    defer std.testing.allocator.free(bytes);

    const parsed = try parseJournalCursorForVolume(bytes, volume);
    try std.testing.expectEqual(cursor.usn_journal_id, parsed.usn_journal_id);
    try std.testing.expectEqual(cursor.next_usn, parsed.next_usn);

    const wrong_volume = VolumeIdentity{
        .root_fingerprint = 0x9999,
        .volume_serial_number = 0xabcd,
        .filesystem = .ntfs,
    };
    try std.testing.expectError(error.WrongUsnCursorVolume, parseJournalCursorForVolume(bytes, wrong_volume));
    try std.testing.expectError(error.TruncatedUsnCursor, parseJournalCursorForVolume(bytes[0 .. bytes.len - 1], volume));
}

test "journal cursor publishes atomically under journals directory" {
    const root = ".zig-cache\\ix-usn-cursor-publish-test";
    std.Io.Dir.cwd().deleteTree(std.testing.io, root) catch {};
    defer std.Io.Dir.cwd().deleteTree(std.testing.io, root) catch {};

    const paths = try buildJournalPathsInIndexDir(std.testing.allocator, root);
    defer paths.deinit(std.testing.allocator);
    const volume = VolumeIdentity{
        .root_fingerprint = 0x7777,
        .volume_serial_number = 0xaaaa,
        .filesystem = .ntfs,
    };
    const cursor = try cursorFromJournalData(volume, .{
        .usn_journal_id = 11,
        .first_usn = 5,
        .next_usn = 55,
        .lowest_valid_usn = 5,
    });

    try publishJournalCursor(std.testing.io, std.testing.allocator, paths, cursor);
    const loaded = (try tryLoadJournalCursor(std.testing.io, std.testing.allocator, paths.cursor_path, volume)).?;
    try std.testing.expectEqual(@as(USN, 55), loaded.next_usn);
    try std.testing.expectEqual(@as(DWORDLONG, 11), loaded.usn_journal_id);
}

test "journal root helper uses canonical state directory outside scanned root" {
    const paths = try buildJournalPaths(std.testing.allocator, ".zig-cache\\ix-usn-canonical-root-test");
    defer paths.deinit(std.testing.allocator);

    try std.testing.expect(std.mem.indexOf(u8, paths.journals_dir, ".ix\\index") == null);
    try std.testing.expect(std.mem.indexOf(u8, paths.journals_dir, ".ix/index") == null);
    try std.testing.expect(std.mem.indexOf(u8, paths.journals_dir, "roots") != null);
    try std.testing.expect(std.mem.endsWith(u8, paths.journals_dir, "journals"));
}

test "journal availability classifies usable inaccessible and unsupported states" {
    const ntfs = VolumeIdentity{
        .root_fingerprint = 0x8888,
        .volume_serial_number = 0x1234,
        .filesystem = .ntfs,
    };
    const usable = classifyJournalAvailability(ntfs, .{ .journal = .{
        .usn_journal_id = 1,
        .first_usn = 1,
        .next_usn = 9,
        .lowest_valid_usn = 1,
    } });
    try std.testing.expect(usable.canUseUsn());
    try std.testing.expectEqual(@as(USN, 9), usable.cursor.?.next_usn);

    const inaccessible = classifyJournalAvailability(ntfs, .inaccessible);
    try std.testing.expect(!inaccessible.canUseUsn());
    try std.testing.expectEqual(JournalAvailabilityKind.inaccessible, inaccessible.kind);
    try std.testing.expectEqualStrings("journal_inaccessible", inaccessible.fallback_reason);

    const unsupported_volume = VolumeIdentity{
        .root_fingerprint = 0x8888,
        .volume_serial_number = 0x1234,
        .filesystem = .unsupported,
    };
    const unsupported = classifyJournalAvailability(unsupported_volume, .unsupported_filesystem);
    try std.testing.expect(!unsupported.canUseUsn());
    try std.testing.expectEqual(JournalAvailabilityKind.unsupported_filesystem, unsupported.kind);
    try std.testing.expectEqualStrings("unsupported_filesystem", unsupported.fallback_reason);
}

test "journal availability rejects malformed journal data as invalid" {
    const ntfs = VolumeIdentity{
        .root_fingerprint = 0x9999,
        .volume_serial_number = 0x1234,
        .filesystem = .ntfs,
    };
    const invalid = classifyJournalAvailability(ntfs, .{ .journal = .{
        .usn_journal_id = 0,
        .first_usn = 1,
        .next_usn = 9,
        .lowest_valid_usn = 1,
    } });
    try std.testing.expect(!invalid.canUseUsn());
    try std.testing.expectEqual(JournalAvailabilityKind.invalid_journal, invalid.kind);
    try std.testing.expectEqualStrings("invalid_journal", invalid.fallback_reason);
}

test "freshness backend uses usn when available and directory watch as invalidating fallback" {
    const volume = VolumeIdentity{
        .root_fingerprint = 0x9999,
        .volume_serial_number = 0x1234,
        .filesystem = .ntfs,
    };
    const usable = classifyJournalAvailability(volume, .{ .journal = .{
        .usn_journal_id = 9,
        .first_usn = 1,
        .next_usn = 20,
        .lowest_valid_usn = 1,
    } });
    const usn_backend = chooseFreshnessBackend(usable);
    try std.testing.expectEqual(FreshnessBackendKind.usn_delta, usn_backend.kind);
    try std.testing.expect(!usn_backend.requiresRootReconcile());
    try std.testing.expectEqual(@as(?DeltaTask, null), directoryWatchInvalidationTask(usn_backend));

    const inaccessible = classifyJournalAvailability(volume, .inaccessible);
    const watch_backend = chooseFreshnessBackend(inaccessible);
    try std.testing.expectEqual(FreshnessBackendKind.directory_watch_invalidate, watch_backend.kind);
    try std.testing.expect(watch_backend.requiresRootReconcile());
    try std.testing.expectEqual(IX_DIRECTORY_WATCH_NOTIFY_FILTER, watch_backend.notify_filter);
    try std.testing.expectEqualStrings("journal_inaccessible", watch_backend.fallback_reason);
    try std.testing.expectEqual(DeltaTaskKind.reconcile_root, directoryWatchInvalidationTask(watch_backend).?.kind);
}

test "usn read batch request carries cursor timeout and byte wait" {
    const volume = VolumeIdentity{
        .root_fingerprint = 0x1111,
        .volume_serial_number = 0x2222,
        .filesystem = .ntfs,
    };
    const cursor = try cursorFromJournalData(volume, .{
        .usn_journal_id = 44,
        .first_usn = 1,
        .next_usn = 100,
        .lowest_valid_usn = 1,
    });
    const request = readBatchRequest(cursor, 250, 4096);
    try std.testing.expectEqual(@as(USN, 100), request.start_usn);
    try std.testing.expectEqual(@as(DWORDLONG, 44), request.usn_journal_id);
    try std.testing.expectEqual(@as(DWORDLONG, 250), request.timeout);
    try std.testing.expectEqual(@as(DWORDLONG, 4096), request.bytes_to_wait_for);
}

test "usn read batch parser reads bounded records" {
    var bytes = std.ArrayList(u8).empty;
    defer bytes.deinit(std.testing.allocator);
    try appendI64(&bytes, std.testing.allocator, 200);
    try appendFakeUsnRecordV2(&bytes, std.testing.allocator, USN_REASON_FILE_CREATE, "alpha.zig");
    try appendFakeUsnRecordV2(&bytes, std.testing.allocator, USN_REASON_DATA_EXTEND, "beta.zig");

    const parsed = try parseReadBatch(std.testing.allocator, bytes.items, .{ .max_records = 1 });
    defer parsed.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(USN, 200), parsed.next_start_usn);
    try std.testing.expectEqual(@as(usize, 1), parsed.records.len);
    try std.testing.expect(parsed.truncated_by_limit);
    try std.testing.expectEqual(USN_REASON_FILE_CREATE, parsed.records[0].reason);
    try std.testing.expect(parsed.records[0].file_reference.eql(.{ .v2 = 1 }));
    try std.testing.expect(parsed.records[0].parent_reference.eql(.{ .v2 = 1 }));
}

test "usn read batch parser rejects hostile buffers and cancellation" {
    var bytes = std.ArrayList(u8).empty;
    defer bytes.deinit(std.testing.allocator);
    try appendI64(&bytes, std.testing.allocator, 200);
    try appendFakeUsnRecordV2(&bytes, std.testing.allocator, USN_REASON_FILE_DELETE, "gamma.zig");

    try std.testing.expectError(error.OperationCancelled, parseReadBatch(std.testing.allocator, bytes.items, .{ .cancelled = true }));
    try std.testing.expectError(error.UsnBatchTooLarge, parseReadBatch(std.testing.allocator, bytes.items, .{ .max_bytes = 4 }));
    try std.testing.expectError(error.TruncatedUsnRecord, parseReadBatch(std.testing.allocator, bytes.items[0 .. bytes.items.len - 1], .{}));
}

test "usn record path resolution maps known file references to catalog ids" {
    var bytes = std.ArrayList(u8).empty;
    defer bytes.deinit(std.testing.allocator);
    try appendI64(&bytes, std.testing.allocator, 200);
    try appendFakeUsnRecordV2(&bytes, std.testing.allocator, USN_REASON_DATA_OVERWRITE, "known.zig");

    const parsed = try parseReadBatch(std.testing.allocator, bytes.items, .{});
    defer parsed.deinit(std.testing.allocator);
    const resolver = CatalogReferenceResolver{ .entries = &.{
        .{ .journal_reference = .{ .v2 = 1 }, .file_id = 77 },
    } };

    const resolution = resolveRecordPath(parsed.records[0], resolver);
    switch (resolution) {
        .catalog_file_id => |file_id| try std.testing.expectEqual(@as(catalog.FileId, 77), file_id),
        .pending_path_lookup => return error.TestExpectedEqual,
    }
}

test "usn record path resolution preserves pending lookup identity and name bounds" {
    var bytes = std.ArrayList(u8).empty;
    defer bytes.deinit(std.testing.allocator);
    try appendI64(&bytes, std.testing.allocator, 200);
    try appendFakeUsnRecordV2(&bytes, std.testing.allocator, USN_REASON_FILE_CREATE, "missing.zig");

    const parsed = try parseReadBatch(std.testing.allocator, bytes.items, .{});
    defer parsed.deinit(std.testing.allocator);
    const resolution = resolveRecordPath(parsed.records[0], .{});

    switch (resolution) {
        .catalog_file_id => return error.TestExpectedEqual,
        .pending_path_lookup => |lookup| {
            try std.testing.expect(lookup.file_reference.eql(.{ .v2 = 1 }));
            try std.testing.expect(lookup.parent_reference.eql(.{ .v2 = 1 }));
            try std.testing.expectEqual(@as(u16, 60), lookup.file_name_offset);
            try std.testing.expectEqual(@as(u16, 22), lookup.file_name_length);
        },
    }
}

test "usn delta task mapping translates content creates and deletes" {
    var bytes = std.ArrayList(u8).empty;
    defer bytes.deinit(std.testing.allocator);
    try appendI64(&bytes, std.testing.allocator, 200);
    try appendFakeUsnRecordV2(&bytes, std.testing.allocator, USN_REASON_FILE_CREATE, "created.zig");
    try appendFakeUsnRecordV2(&bytes, std.testing.allocator, USN_REASON_RENAME_OLD_NAME, "old.zig");

    const parsed = try parseReadBatch(std.testing.allocator, bytes.items, .{});
    defer parsed.deinit(std.testing.allocator);
    const resolver = CatalogReferenceResolver{ .entries = &.{
        .{ .journal_reference = .{ .v2 = 1 }, .file_id = 88 },
    } };

    const upsert = mapRecordToDeltaTask(parsed.records[0], resolver);
    try std.testing.expectEqual(DeltaTaskKind.upsert_file, upsert.kind);
    try std.testing.expectEqual(USN_REASON_FILE_CREATE, upsert.reason);
    switch (upsert.resolution.?) {
        .catalog_file_id => |file_id| try std.testing.expectEqual(@as(catalog.FileId, 88), file_id),
        .pending_path_lookup => return error.TestExpectedEqual,
    }

    const delete = mapRecordToDeltaTask(parsed.records[1], resolver);
    try std.testing.expectEqual(DeltaTaskKind.delete_file, delete.kind);
    try std.testing.expectEqual(USN_REASON_RENAME_OLD_NAME, delete.reason);
}

test "usn delta task mapping reconciles ambiguous reason masks" {
    var bytes = std.ArrayList(u8).empty;
    defer bytes.deinit(std.testing.allocator);
    try appendI64(&bytes, std.testing.allocator, 200);
    try appendFakeUsnRecordV2(&bytes, std.testing.allocator, USN_REASON_FILE_DELETE | USN_REASON_FILE_CREATE, "ambiguous.zig");
    try appendFakeUsnRecordV2(&bytes, std.testing.allocator, USN_REASON_CLOSE, "close.zig");

    const parsed = try parseReadBatch(std.testing.allocator, bytes.items, .{});
    defer parsed.deinit(std.testing.allocator);

    try std.testing.expectEqual(DeltaTaskKind.reconcile_root, mapRecordToDeltaTask(parsed.records[0], .{}).kind);
    try std.testing.expectEqual(DeltaTaskKind.reconcile_root, mapRecordToDeltaTask(parsed.records[1], .{}).kind);
}

test "usn delta task coalescing keeps last mutation for duplicate identities" {
    const resolution = RecordPathResolution{ .catalog_file_id = 12 };
    const tasks = [_]DeltaTask{
        .{
            .kind = .upsert_file,
            .reason = USN_REASON_FILE_CREATE,
            .resolution = resolution,
        },
        .{
            .kind = .upsert_file,
            .reason = USN_REASON_DATA_EXTEND,
            .resolution = resolution,
        },
        .{
            .kind = .delete_file,
            .reason = USN_REASON_FILE_DELETE,
            .resolution = resolution,
        },
    };

    const coalesced = try coalesceDeltaTasks(std.testing.allocator, &tasks);
    defer std.testing.allocator.free(coalesced);
    try std.testing.expectEqual(@as(usize, 1), coalesced.len);
    try std.testing.expectEqual(DeltaTaskKind.delete_file, coalesced[0].kind);
    try std.testing.expectEqual(USN_REASON_FILE_CREATE | USN_REASON_DATA_EXTEND | USN_REASON_FILE_DELETE, coalesced[0].reason);
}

test "usn delta task coalescing collapses reconcile batches" {
    const lookup = RecordPathResolution{ .pending_path_lookup = .{
        .file_reference = .{ .v2 = 10 },
        .parent_reference = .{ .v2 = 1 },
        .file_name_offset = 60,
        .file_name_length = 8,
    } };
    const tasks = [_]DeltaTask{
        .{
            .kind = .upsert_file,
            .reason = USN_REASON_FILE_CREATE,
            .resolution = lookup,
        },
        .{
            .kind = .reconcile_root,
            .reason = USN_REASON_CLOSE,
            .resolution = null,
        },
    };

    const coalesced = try coalesceDeltaTasks(std.testing.allocator, &tasks);
    defer std.testing.allocator.free(coalesced);
    try std.testing.expectEqual(@as(usize, 1), coalesced.len);
    try std.testing.expectEqual(DeltaTaskKind.reconcile_root, coalesced[0].kind);
    try std.testing.expectEqual(USN_REASON_FILE_CREATE | USN_REASON_CLOSE, coalesced[0].reason);
}

test "usn continuity decision escalates lost wrapped and overflowed cursors" {
    const volume = VolumeIdentity{
        .root_fingerprint = 0x1234,
        .volume_serial_number = 0x77,
        .filesystem = .ntfs,
    };
    const previous = try cursorFromJournalData(volume, .{
        .usn_journal_id = 1,
        .first_usn = 1,
        .next_usn = 50,
        .lowest_valid_usn = 1,
    });
    const current_continuous = try cursorFromJournalData(volume, .{
        .usn_journal_id = 1,
        .first_usn = 1,
        .next_usn = 80,
        .lowest_valid_usn = 40,
    });
    const current_wrapped = try cursorFromJournalData(volume, .{
        .usn_journal_id = 1,
        .first_usn = 1,
        .next_usn = 90,
        .lowest_valid_usn = 60,
    });
    const empty_batch = ReadBatchResult{
        .next_start_usn = 80,
        .records = &.{},
    };
    const overflow_batch = ReadBatchResult{
        .next_start_usn = 80,
        .records = &.{},
        .truncated_by_limit = true,
    };

    try std.testing.expectEqual(ContinuityFailureKind.lost_cursor, evaluateDeltaContinuity(null, current_continuous, empty_batch).reconcile_root);
    try std.testing.expectEqual(ContinuityFailureKind.journal_wrapped, evaluateDeltaContinuity(previous, current_wrapped, empty_batch).reconcile_root);
    try std.testing.expectEqual(ContinuityFailureKind.batch_overflow, evaluateDeltaContinuity(previous, current_continuous, overflow_batch).reconcile_root);

    const task = continuityReconcileTask(evaluateDeltaContinuity(previous, current_wrapped, empty_batch)).?;
    try std.testing.expectEqual(DeltaTaskKind.reconcile_root, task.kind);
}

test "usn continuity decision permits continuous bounded delta" {
    const volume = VolumeIdentity{
        .root_fingerprint = 0x1234,
        .volume_serial_number = 0x77,
        .filesystem = .ntfs,
    };
    const previous = try cursorFromJournalData(volume, .{
        .usn_journal_id = 1,
        .first_usn = 1,
        .next_usn = 50,
        .lowest_valid_usn = 1,
    });
    const current = try cursorFromJournalData(volume, .{
        .usn_journal_id = 1,
        .first_usn = 1,
        .next_usn = 80,
        .lowest_valid_usn = 40,
    });
    const batch = ReadBatchResult{
        .next_start_usn = 80,
        .records = &.{},
    };

    try std.testing.expectEqual(ContinuityDecision.apply_delta, evaluateDeltaContinuity(previous, current, batch));
    try std.testing.expectEqual(@as(?DeltaTask, null), continuityReconcileTask(.apply_delta));
}

test "usn adversarial branch switch forces root reconcile" {
    const previous_volume = VolumeIdentity{
        .root_fingerprint = 0xaaaa,
        .volume_serial_number = 0x77,
        .filesystem = .ntfs,
    };
    const current_volume = VolumeIdentity{
        .root_fingerprint = 0xbbbb,
        .volume_serial_number = 0x77,
        .filesystem = .ntfs,
    };
    const previous = try cursorFromJournalData(previous_volume, .{
        .usn_journal_id = 1,
        .first_usn = 1,
        .next_usn = 50,
        .lowest_valid_usn = 1,
    });
    const current = try cursorFromJournalData(current_volume, .{
        .usn_journal_id = 1,
        .first_usn = 1,
        .next_usn = 80,
        .lowest_valid_usn = 40,
    });
    const batch = ReadBatchResult{
        .next_start_usn = 80,
        .records = &.{},
    };

    try std.testing.expectEqual(ContinuityFailureKind.journal_wrapped, evaluateDeltaContinuity(previous, current, batch).reconcile_root);
}

test "usn adversarial rename storm and delete recreate never expose stale path state" {
    const same_file = RecordPathResolution{ .catalog_file_id = 12 };
    const rename_storm = [_]DeltaTask{
        .{ .kind = .delete_file, .reason = USN_REASON_RENAME_OLD_NAME, .resolution = same_file },
        .{ .kind = .upsert_file, .reason = USN_REASON_RENAME_NEW_NAME, .resolution = same_file },
        .{ .kind = .delete_file, .reason = USN_REASON_RENAME_OLD_NAME, .resolution = same_file },
        .{ .kind = .upsert_file, .reason = USN_REASON_RENAME_NEW_NAME, .resolution = same_file },
    };

    const coalesced = try coalesceDeltaTasks(std.testing.allocator, &rename_storm);
    defer std.testing.allocator.free(coalesced);
    try std.testing.expectEqual(@as(usize, 1), coalesced.len);
    try std.testing.expectEqual(DeltaTaskKind.upsert_file, coalesced[0].kind);
    try std.testing.expectEqual(
        USN_REASON_RENAME_OLD_NAME | USN_REASON_RENAME_NEW_NAME,
        coalesced[0].reason,
    );

    const delete_recreate = DeltaTask{
        .kind = .reconcile_root,
        .reason = USN_REASON_FILE_DELETE | USN_REASON_FILE_CREATE,
        .resolution = same_file,
    };
    const reconcile = try coalesceDeltaTasks(std.testing.allocator, &.{delete_recreate});
    defer std.testing.allocator.free(reconcile);
    try std.testing.expectEqual(@as(usize, 1), reconcile.len);
    try std.testing.expectEqual(DeltaTaskKind.reconcile_root, reconcile[0].kind);
    try std.testing.expect(planDeltaApply(reconcile).publishesFullGeneration());
}

test "usn delta apply planning distinguishes surgical and reconcile batches" {
    const surgical = [_]DeltaTask{
        .{
            .kind = .upsert_file,
            .reason = USN_REASON_DATA_EXTEND,
            .resolution = .{ .catalog_file_id = 1 },
        },
        .{
            .kind = .delete_file,
            .reason = USN_REASON_FILE_DELETE,
            .resolution = .{ .catalog_file_id = 2 },
        },
    };
    const surgical_plan = planDeltaApply(&surgical);
    try std.testing.expectEqual(DeltaApplyMode.incremental_segment_update, surgical_plan.mode);
    try std.testing.expect(!surgical_plan.publishesFullGeneration());
    try std.testing.expectEqual(@as(usize, 1), surgical_plan.upsert_count);
    try std.testing.expectEqual(@as(usize, 1), surgical_plan.delete_count);

    const reconcile = [_]DeltaTask{
        .{
            .kind = .upsert_file,
            .reason = USN_REASON_FILE_CREATE,
            .resolution = .{ .pending_path_lookup = .{
                .file_reference = .{ .v2 = 4 },
                .parent_reference = .{ .v2 = 1 },
                .file_name_offset = 60,
                .file_name_length = 18,
            } },
        },
    };
    const reconcile_plan = planDeltaApply(&reconcile);
    try std.testing.expectEqual(DeltaApplyMode.root_reconcile_publish, reconcile_plan.mode);
    try std.testing.expect(reconcile_plan.publishesFullGeneration());
    try std.testing.expect(reconcile_plan.reconcile_required);
}

test "usn delta apply policy caps churn before overlay publish" {
    const tasks = [_]DeltaTask{
        .{
            .kind = .upsert_file,
            .reason = USN_REASON_DATA_EXTEND,
            .resolution = .{ .catalog_file_id = 1 },
        },
        .{
            .kind = .delete_file,
            .reason = USN_REASON_FILE_DELETE,
            .resolution = .{ .catalog_file_id = 2 },
        },
    };

    const admitted = planDeltaApplyWithPolicy(&tasks, .{ .max_delta_tasks = 2 });
    try std.testing.expectEqual(DeltaApplyMode.incremental_segment_update, admitted.mode);
    try std.testing.expect(!admitted.reconcile_required);
    try std.testing.expectEqual(@as(usize, 1), admitted.upsert_count);
    try std.testing.expectEqual(@as(usize, 1), admitted.delete_count);

    const overflow = planDeltaApplyWithPolicy(&tasks, .{ .max_delta_tasks = 1 });
    try std.testing.expectEqual(DeltaApplyMode.root_reconcile_publish, overflow.mode);
    try std.testing.expect(overflow.reconcile_required);
    try std.testing.expectEqual(@as(usize, 1), overflow.upsert_count);
    try std.testing.expectEqual(@as(usize, 1), overflow.delete_count);
}

test "usn delta overlay model covers file mutation pressure and tombstone semantics" {
    var checked: usize = 0;
    const upsert_one = DeltaTask{ .kind = .upsert_file, .reason = USN_REASON_DATA_EXTEND, .resolution = .{ .catalog_file_id = 1 } };
    const delete_two = DeltaTask{ .kind = .delete_file, .reason = USN_REASON_FILE_DELETE, .resolution = .{ .catalog_file_id = 2 } };
    const upsert_three = DeltaTask{ .kind = .upsert_file, .reason = USN_REASON_DATA_OVERWRITE, .resolution = .{ .catalog_file_id = 3 } };
    const pending_lookup = RecordPathResolution{ .pending_path_lookup = .{
        .file_reference = .{ .v2 = 33 },
        .parent_reference = .{ .v2 = 3 },
        .file_name_offset = 60,
        .file_name_length = 20,
    } };

    try std.testing.expectError(error.InvalidDeltaEpoch, planDeltaOverlay(std.testing.allocator, generation.INVALID_EPOCH, 2, &.{}, .{}));
    checked += 1;
    try std.testing.expectError(error.InvalidDeltaEpoch, planDeltaOverlay(std.testing.allocator, 2, generation.INVALID_EPOCH, &.{}, .{}));
    checked += 1;
    try std.testing.expectError(error.InvalidDeltaEpoch, planDeltaOverlay(std.testing.allocator, 4, 3, &.{}, .{}));
    checked += 1;

    var empty = try planDeltaOverlay(std.testing.allocator, 10, 10, &.{}, .{});
    defer empty.deinit(std.testing.allocator);
    try std.testing.expect(empty.pinsConsistentView());
    checked += 1;
    try std.testing.expect(!empty.reconcile_required);
    checked += 1;
    try std.testing.expectEqual(@as(usize, 0), empty.entries.len);
    checked += 1;

    var upsert_plan = try planDeltaOverlay(std.testing.allocator, 10, 11, &.{upsert_one}, .{});
    defer upsert_plan.deinit(std.testing.allocator);
    try std.testing.expect(upsert_plan.pinsConsistentView());
    checked += 1;
    try std.testing.expectEqual(@as(usize, 1), upsert_plan.entries.len);
    checked += 1;
    try std.testing.expectEqual(DeltaOverlayState.upsert_pending, upsert_plan.entries[0].state);
    checked += 1;
    try std.testing.expectEqual(@as(?catalog.FileId, 1), upsert_plan.entries[0].file_id);
    checked += 1;
    try std.testing.expectEqual(@as(usize, 1), upsert_plan.upsert_count);
    checked += 1;
    try std.testing.expect(!upsert_plan.entries[0].blocksBaseCandidate(1));
    checked += 1;

    var delete_plan = try planDeltaOverlay(std.testing.allocator, 10, 12, &.{delete_two}, .{});
    defer delete_plan.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), delete_plan.entries.len);
    checked += 1;
    try std.testing.expectEqual(DeltaOverlayState.tombstone, delete_plan.entries[0].state);
    checked += 1;
    try std.testing.expectEqual(@as(?catalog.FileId, 2), delete_plan.entries[0].file_id);
    checked += 1;
    try std.testing.expectEqual(@as(usize, 1), delete_plan.tombstone_count);
    checked += 1;
    try std.testing.expect(delete_plan.entries[0].blocksBaseCandidate(2));
    checked += 1;
    try std.testing.expect(!delete_plan.entries[0].blocksBaseCandidate(3));
    checked += 1;

    const mixed = [_]DeltaTask{ upsert_one, delete_two, upsert_three };
    var mixed_plan = try planDeltaOverlay(std.testing.allocator, 10, 13, &mixed, .{ .max_delta_tasks = 3 });
    defer mixed_plan.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 3), mixed_plan.entries.len);
    checked += 1;
    try std.testing.expectEqual(@as(usize, 2), mixed_plan.upsert_count);
    checked += 1;
    try std.testing.expectEqual(@as(usize, 1), mixed_plan.tombstone_count);
    checked += 1;
    try std.testing.expect(!mixed_plan.reconcile_required);
    checked += 1;

    var overflow = try planDeltaOverlay(std.testing.allocator, 10, 14, &mixed, .{ .max_delta_tasks = 2 });
    defer overflow.deinit(std.testing.allocator);
    try std.testing.expect(overflow.reconcile_required);
    checked += 1;
    try std.testing.expectEqualStrings("root_reconcile_required", overflow.fallback_reason);
    checked += 1;
    try std.testing.expectEqual(@as(usize, 0), overflow.entries.len);
    checked += 1;

    const unresolved = DeltaTask{ .kind = .upsert_file, .reason = USN_REASON_FILE_CREATE, .resolution = pending_lookup };
    var unresolved_plan = try planDeltaOverlay(std.testing.allocator, 10, 15, &.{unresolved}, .{});
    defer unresolved_plan.deinit(std.testing.allocator);
    try std.testing.expect(unresolved_plan.reconcile_required);
    checked += 1;
    try std.testing.expectEqualStrings("pending_path_lookup", unresolved_plan.fallback_reason);
    checked += 1;

    const null_resolution = DeltaTask{ .kind = .delete_file, .reason = USN_REASON_FILE_DELETE, .resolution = null };
    var null_plan = try planDeltaOverlay(std.testing.allocator, 10, 16, &.{null_resolution}, .{});
    defer null_plan.deinit(std.testing.allocator);
    try std.testing.expect(null_plan.reconcile_required);
    checked += 1;
    try std.testing.expectEqualStrings("unresolved_delta_task", null_plan.fallback_reason);
    checked += 1;

    const reconcile_task = DeltaTask{ .kind = .reconcile_root, .reason = USN_REASON_CLOSE, .resolution = null };
    var reconcile_plan = try planDeltaOverlay(std.testing.allocator, 10, 17, &.{reconcile_task}, .{});
    defer reconcile_plan.deinit(std.testing.allocator);
    try std.testing.expect(reconcile_plan.reconcile_required);
    checked += 1;
    try std.testing.expectEqualStrings("root_reconcile_required", reconcile_plan.fallback_reason);
    checked += 1;

    const delete_after_upsert = [_]DeltaTask{
        .{ .kind = .upsert_file, .reason = USN_REASON_FILE_CREATE, .resolution = .{ .catalog_file_id = 44 } },
        .{ .kind = .delete_file, .reason = USN_REASON_FILE_DELETE, .resolution = .{ .catalog_file_id = 44 } },
    };
    const coalesced_delete = try coalesceDeltaTasks(std.testing.allocator, &delete_after_upsert);
    defer std.testing.allocator.free(coalesced_delete);
    var coalesced_delete_plan = try planDeltaOverlay(std.testing.allocator, 10, 18, coalesced_delete, .{});
    defer coalesced_delete_plan.deinit(std.testing.allocator);
    try std.testing.expectEqual(DeltaOverlayState.tombstone, coalesced_delete_plan.entries[0].state);
    checked += 1;
    try std.testing.expect(coalesced_delete_plan.entries[0].blocksBaseCandidate(44));
    checked += 1;

    const upsert_after_delete = [_]DeltaTask{
        .{ .kind = .delete_file, .reason = USN_REASON_RENAME_OLD_NAME, .resolution = .{ .catalog_file_id = 45 } },
        .{ .kind = .upsert_file, .reason = USN_REASON_RENAME_NEW_NAME, .resolution = .{ .catalog_file_id = 45 } },
    };
    const coalesced_upsert = try coalesceDeltaTasks(std.testing.allocator, &upsert_after_delete);
    defer std.testing.allocator.free(coalesced_upsert);
    var coalesced_upsert_plan = try planDeltaOverlay(std.testing.allocator, 10, 19, coalesced_upsert, .{});
    defer coalesced_upsert_plan.deinit(std.testing.allocator);
    try std.testing.expectEqual(DeltaOverlayState.upsert_pending, coalesced_upsert_plan.entries[0].state);
    checked += 1;
    try std.testing.expect(!coalesced_upsert_plan.entries[0].blocksBaseCandidate(45));
    checked += 1;

    try std.testing.expectEqual(@as(usize, 35), checked);
}

test "usn delta generation publish writes refreshed catalog postings and manifest" {
    const root = ".zig-cache\\ix-usn-delta-generation-test";
    std.Io.Dir.cwd().deleteTree(std.testing.io, root) catch {};
    defer std.Io.Dir.cwd().deleteTree(std.testing.io, root) catch {};

    try std.Io.Dir.cwd().createDirPath(std.testing.io, root);
    const root_identity = try catalog.identifyRoot(std.testing.allocator, root);
    defer root_identity.deinit(std.testing.allocator);
    const paths = try generation.buildGenerationPathsInIndexDir(std.testing.allocator, root, 7);
    defer paths.deinit(std.testing.allocator);
    const catalog_files = [_]catalog.CatalogFileInput{
        .{
            .path = "src/main.zig",
            .size = 11,
            .mtime_ns = 123,
            .sample = "const a = 1;",
        },
    };
    const postings_files = [_]postings.PostingsFileInput{
        .{ .file_id = 1, .bytes = "const a = 1;" },
    };

    const pin = try publishDeltaGeneration(std.testing.io, std.testing.allocator, paths, .{
        .root = root,
        .root_fingerprint = root_identity.fingerprint,
        .epoch = 7,
        .catalog_files = &catalog_files,
        .postings_files = &postings_files,
    });
    try std.testing.expectEqual(@as(generation.Epoch, 7), pin.epoch);
    try std.testing.expectEqual(root_identity.fingerprint, pin.root_fingerprint);
    try std.testing.expectEqual(@as(usize, 2), pin.segment_count);
}

fn appendFakeUsnRecordV2(bytes: *std.ArrayList(u8), allocator: std.mem.Allocator, reason: windows.DWORD, name: []const u8) !void {
    const record_start = bytes.items.len;
    const file_name_offset: u16 = 60;
    const file_name_length: u16 = @intCast(name.len * 2);
    const record_length: u32 = file_name_offset + file_name_length;

    try appendU32(bytes, allocator, record_length);
    try appendU16(bytes, allocator, 2);
    try appendU16(bytes, allocator, 0);
    try appendU64(bytes, allocator, 1);
    try appendU64(bytes, allocator, 1);
    try appendI64(bytes, allocator, 101);
    try appendI64(bytes, allocator, 0);
    try appendU32(bytes, allocator, reason);
    try appendU32(bytes, allocator, 0);
    try appendU32(bytes, allocator, 0);
    try appendU32(bytes, allocator, 0);
    try appendU16(bytes, allocator, file_name_length);
    try appendU16(bytes, allocator, file_name_offset);
    while (bytes.items.len < record_start + file_name_offset) try bytes.append(allocator, 0);
    for (name) |byte| {
        try bytes.append(allocator, byte);
        try bytes.append(allocator, 0);
    }
}
