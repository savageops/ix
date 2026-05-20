const std = @import("std");

const catalog = @import("catalog.zig");
const generation = @import("generation.zig");
const postings = @import("postings.zig");
const usn = @import("usn.zig");

pub const Policy = struct {
    max_upserts: usize = 256,
    max_deletes: usize = 256,

    pub fn admits(self: Policy, upsert_count: usize, delete_count: usize) bool {
        return upsert_count <= self.max_upserts and delete_count <= self.max_deletes;
    }
};

pub const Upsert = struct {
    file_id: catalog.FileId,
};

pub const Overlay = struct {
    base_epoch: generation.Epoch,
    delta_epoch: generation.Epoch,
    upserts: []Upsert = &.{},
    deletes: []catalog.FileId = &.{},

    pub fn deinit(self: Overlay, allocator: std.mem.Allocator) void {
        allocator.free(self.upserts);
        allocator.free(self.deletes);
    }

    pub fn hasDelta(self: Overlay) bool {
        return self.upserts.len != 0 or self.deletes.len != 0;
    }
};

pub const BuildPlan = union(enum) {
    overlay: Overlay,
    reconcile: usn.DeltaApplyPlan,

    pub fn deinit(self: BuildPlan, allocator: std.mem.Allocator) void {
        switch (self) {
            .overlay => |overlay| overlay.deinit(allocator),
            .reconcile => {},
        }
    }
};

pub const CandidateOverlay = struct {
    upsert_file_ids: []const postings.FileId = &.{},
    delete_file_ids: []const postings.FileId = &.{},
};

pub fn build(
    allocator: std.mem.Allocator,
    tasks: []const usn.DeltaTask,
    policy: Policy,
    base_epoch: generation.Epoch,
    delta_epoch: generation.Epoch,
) !BuildPlan {
    var upserts = std.ArrayList(Upsert).empty;
    errdefer upserts.deinit(allocator);
    var deletes = std.ArrayList(catalog.FileId).empty;
    errdefer deletes.deinit(allocator);

    for (tasks) |task| {
        if (task.kind == .reconcile_root or task.resolution == null) {
            return .{ .reconcile = usn.planDeltaApply(tasks) };
        }

        const file_id = switch (task.resolution.?) {
            .catalog_file_id => |id| id,
            .pending_path_lookup => return .{ .reconcile = usn.planDeltaApply(tasks) },
        };

        switch (task.kind) {
            .upsert_file => {
                removeFileId(&deletes, file_id);
                if (findUpsert(upserts.items, file_id)) |index| {
                    upserts.items[index] = .{ .file_id = file_id };
                } else {
                    try upserts.append(allocator, .{ .file_id = file_id });
                }
            },
            .delete_file => {
                if (findUpsert(upserts.items, file_id)) |index| {
                    _ = upserts.swapRemove(index);
                }
                if (!containsFileId(deletes.items, file_id)) {
                    try deletes.append(allocator, file_id);
                }
            },
            .reconcile_root => unreachable,
        }

        if (!policy.admits(upserts.items.len, deletes.items.len)) {
            const overflow_plan = usn.DeltaApplyPlan{
                .mode = .root_reconcile_publish,
                .upsert_count = upserts.items.len,
                .delete_count = deletes.items.len,
                .reconcile_required = true,
            };
            upserts.deinit(allocator);
            deletes.deinit(allocator);
            return .{ .reconcile = overflow_plan };
        }
    }

    std.mem.sort(Upsert, upserts.items, {}, upsertLessThan);
    std.mem.sort(catalog.FileId, deletes.items, {}, fileIdLessThan);
    return .{ .overlay = .{
        .base_epoch = base_epoch,
        .delta_epoch = delta_epoch,
        .upserts = try upserts.toOwnedSlice(allocator),
        .deletes = try deletes.toOwnedSlice(allocator),
    } };
}

pub fn applyCandidates(
    allocator: std.mem.Allocator,
    base_file_ids: []const postings.FileId,
    overlay: CandidateOverlay,
) ![]postings.FileId {
    var filtered_base = std.ArrayList(postings.FileId).empty;
    defer filtered_base.deinit(allocator);

    for (base_file_ids) |file_id| {
        if (!postings.containsFileId(overlay.delete_file_ids, file_id)) {
            if (filtered_base.items.len == 0 or filtered_base.items[filtered_base.items.len - 1] != file_id) {
                try filtered_base.append(allocator, file_id);
            }
        }
    }

    const upserts = try allocator.dupe(postings.FileId, overlay.upsert_file_ids);
    defer allocator.free(upserts);
    std.mem.sort(postings.FileId, upserts, {}, fileIdLessThan);
    const upsert_len = uniqueSortedFileIds(upserts);

    return unionFileIds(allocator, filtered_base.items, upserts[0..upsert_len]);
}

fn unionFileIds(allocator: std.mem.Allocator, lhs: []const postings.FileId, rhs: []const postings.FileId) ![]postings.FileId {
    var out = std.ArrayList(postings.FileId).empty;
    errdefer out.deinit(allocator);

    var left_index: usize = 0;
    var right_index: usize = 0;
    while (left_index < lhs.len or right_index < rhs.len) {
        const value = if (right_index >= rhs.len or (left_index < lhs.len and lhs[left_index] < rhs[right_index])) blk: {
            const file_id = lhs[left_index];
            left_index += 1;
            break :blk file_id;
        } else if (left_index >= lhs.len or rhs[right_index] < lhs[left_index]) blk: {
            const file_id = rhs[right_index];
            right_index += 1;
            break :blk file_id;
        } else blk: {
            const file_id = lhs[left_index];
            left_index += 1;
            right_index += 1;
            break :blk file_id;
        };
        if (out.items.len == 0 or out.items[out.items.len - 1] != value) try out.append(allocator, value);
    }
    return out.toOwnedSlice(allocator);
}

fn uniqueSortedFileIds(file_ids: []postings.FileId) usize {
    if (file_ids.len == 0) return 0;
    var write_index: usize = 1;
    for (file_ids[1..]) |file_id| {
        if (file_id != file_ids[write_index - 1]) {
            file_ids[write_index] = file_id;
            write_index += 1;
        }
    }
    return write_index;
}

fn findUpsert(entries: []const Upsert, file_id: catalog.FileId) ?usize {
    for (entries, 0..) |entry, index| {
        if (entry.file_id == file_id) return index;
    }
    return null;
}

fn containsFileId(file_ids: []const catalog.FileId, file_id: catalog.FileId) bool {
    for (file_ids) |existing| {
        if (existing == file_id) return true;
    }
    return false;
}

fn removeFileId(file_ids: *std.ArrayList(catalog.FileId), file_id: catalog.FileId) void {
    for (file_ids.items, 0..) |existing, index| {
        if (existing == file_id) {
            _ = file_ids.swapRemove(index);
            return;
        }
    }
}

fn upsertLessThan(_: void, lhs: Upsert, rhs: Upsert) bool {
    return lhs.file_id < rhs.file_id;
}

fn fileIdLessThan(_: void, lhs: catalog.FileId, rhs: catalog.FileId) bool {
    return lhs < rhs;
}

test "ram delta overlay coalesces file upserts and tombstones" {
    const tasks = [_]usn.DeltaTask{
        .{
            .kind = .delete_file,
            .reason = usn.USN_REASON_FILE_DELETE,
            .resolution = .{ .catalog_file_id = 9 },
        },
        .{
            .kind = .upsert_file,
            .reason = usn.USN_REASON_DATA_EXTEND,
            .resolution = .{ .catalog_file_id = 7 },
        },
        .{
            .kind = .upsert_file,
            .reason = usn.USN_REASON_FILE_CREATE,
            .resolution = .{ .catalog_file_id = 9 },
        },
        .{
            .kind = .delete_file,
            .reason = usn.USN_REASON_FILE_DELETE,
            .resolution = .{ .catalog_file_id = 7 },
        },
    };

    const plan = try build(std.testing.allocator, &tasks, .{}, 41, 42);
    defer plan.deinit(std.testing.allocator);
    const overlay = plan.overlay;
    try std.testing.expect(overlay.hasDelta());
    try std.testing.expectEqual(@as(generation.Epoch, 41), overlay.base_epoch);
    try std.testing.expectEqual(@as(generation.Epoch, 42), overlay.delta_epoch);
    try std.testing.expectEqual(@as(usize, 1), overlay.upserts.len);
    try std.testing.expectEqual(@as(catalog.FileId, 9), overlay.upserts[0].file_id);
    try std.testing.expectEqual(@as(usize, 1), overlay.deletes.len);
    try std.testing.expectEqual(@as(catalog.FileId, 7), overlay.deletes[0]);
}

test "ram delta overlay promotes unresolved or excessive churn to reconcile" {
    const unresolved = [_]usn.DeltaTask{
        .{
            .kind = .upsert_file,
            .reason = usn.USN_REASON_RENAME_NEW_NAME,
            .resolution = .{ .pending_path_lookup = .{
                .file_reference = .{ .v2 = 4 },
                .parent_reference = .{ .v2 = 1 },
                .file_name_offset = 60,
                .file_name_length = 18,
            } },
        },
    };

    const unresolved_plan = try build(std.testing.allocator, &unresolved, .{}, 1, 2);
    try std.testing.expect(unresolved_plan.reconcile.publishesFullGeneration());

    const churn = [_]usn.DeltaTask{
        .{
            .kind = .upsert_file,
            .reason = usn.USN_REASON_DATA_EXTEND,
            .resolution = .{ .catalog_file_id = 1 },
        },
        .{
            .kind = .upsert_file,
            .reason = usn.USN_REASON_DATA_EXTEND,
            .resolution = .{ .catalog_file_id = 2 },
        },
    };

    const churn_plan = try build(std.testing.allocator, &churn, .{ .max_upserts = 1 }, 1, 2);
    try std.testing.expect(churn_plan.reconcile.publishesFullGeneration());
}

test "ram delta overlay applies tombstones and refreshed candidates" {
    const base = [_]postings.FileId{ 1, 3, 5, 9 };
    const deletes = [_]postings.FileId{ 3, 9 };
    const upserts = [_]postings.FileId{ 2, 3, 7 };

    const merged = try applyCandidates(std.testing.allocator, &base, .{
        .upsert_file_ids = &upserts,
        .delete_file_ids = &deletes,
    });
    defer std.testing.allocator.free(merged);

    try std.testing.expectEqualSlices(postings.FileId, &.{ 1, 2, 3, 5, 7 }, merged);
}

test "ram delta overlay preserves sorted unique candidates" {
    const base = [_]postings.FileId{ 1, 2, 2, 4 };
    const upserts = [_]postings.FileId{ 4, 3, 3 };

    const merged = try applyCandidates(std.testing.allocator, &base, .{
        .upsert_file_ids = &upserts,
    });
    defer std.testing.allocator.free(merged);

    try std.testing.expectEqualSlices(postings.FileId, &.{ 1, 2, 3, 4 }, merged);
}
