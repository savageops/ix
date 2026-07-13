const std = @import("std");
const cli = @import("args.zig");
const cursor = @import("cursor.zig");
const legacy_output = @import("output.zig");
const output_contract = @import("output_contract.zig");
const inspect = @import("../core/inspect.zig");
const search = @import("../core/search.zig");

pub const RenderOptions = struct {
    visible_count: usize,
    byte_truncated: bool,
    raw_json: bool,
};

/// Renders one complete versioned result so the caller can enforce an exact aggregate byte budget.
pub fn render(
    allocator: std.mem.Allocator,
    request: cli.SearchRequest,
    report: search.SearchReport,
    context_reports: []const inspect.ContextReport,
    options: RenderOptions,
) ![]u8 {
    var output: std.Io.Writer.Allocating = .init(allocator);
    errdefer output.deinit();
    try write(&output.writer, allocator, request, report, context_reports, options);
    return output.toOwnedSlice();
}

/// Writes the v3 contract with separate verification, scan, and projection truth.
fn write(
    writer: anytype,
    allocator: std.mem.Allocator,
    request: cli.SearchRequest,
    report: search.SearchReport,
    context_reports: []const inspect.ContextReport,
    options: RenderOptions,
) !void {
    const visible_count = @min(options.visible_count, report.hit_count);
    const eligible = report.matches_after_cursor;
    const remaining = eligible -| visible_count;
    const reason = truncationReason(request, report, visible_count, options.byte_truncated);
    const scan_completion: output_contract.ScanCompletion = if (report.stats.access_errors.total == 0) .complete else .partial_access;
    const projection_completion: output_contract.ProjectionCompletion = if (remaining == 0) .complete else .truncated;
    const verification: output_contract.Verification = .canonical;

    if (!options.raw_json) try writer.writeAll("-- ix.result.v3 ");
    try writer.writeAll("{\"schema\":\"ix.result.v3\",\"verification\":");
    try writeJsonString(writer, @tagName(verification));
    try writer.writeAll(",\"scan\":{\"state\":");
    try writeJsonString(writer, @tagName(scan_completion));
    try writer.print(",\"access_errors\":{},\"files_discovered\":{},\"files_scanned\":{},\"policy_skipped\":{}}}", .{
        report.stats.access_errors.total,
        report.files_discovered,
        report.files_scanned,
        report.files_skipped,
    });
    try writer.writeAll(",\"projection\":{\"state\":");
    try writeJsonString(writer, @tagName(projection_completion));
    try writer.print(",\"returned\":{},\"eligible\":{},\"remaining\":{}", .{ visible_count, eligible, remaining });
    if (reason) |value| {
        try writer.writeAll(",\"reason\":");
        try writeJsonString(writer, @tagName(value));
    }
    if (request.max_bytes) |budget| try writer.print(",\"byte_budget\":{}", .{budget});
    if (remaining > 0 and visible_count > 0) {
        const signature = report.corpus_signature orelse return error.MissingCorpusSignature;
        const last = report.hits[visible_count - 1];
        const next = try cursor.encode(allocator, .{
            .corpus_signature = signature,
            .request_fingerprint = report.request_fingerprint,
            .path = last.path,
            .line = last.line,
            .column = last.column,
        });
        try writer.writeAll(",\"next_cursor\":");
        try writeJsonString(writer, next);
    }
    try writer.writeAll("}");

    try writer.writeAll(",\"expr\":");
    try writeJsonString(writer, report.expression);
    try writer.writeAll(",\"cwd\":");
    try writeJsonString(writer, report.cwd);
    try writer.writeAll(",\"stats\":");
    try legacy_output.writeStats(writer, report.stats, .agent);
    try writer.writeAll(",\"route\":{\"lane\":");
    try writeJsonString(writer, if (report.stats.postings_index.available) "warm" else "cold");
    try writer.print(",\"index_enabled\":{s}", .{boolText(report.stats.postings_index.enabled)});
    if (report.stats.postings_index.generation) |generation| try writer.print(",\"generation\":{}", .{generation});
    if ((report.stats.postings_index.enabled or report.stats.postings_index.available) and report.stats.generation_refresh.refresh_status.len != 0) {
        try writer.writeAll(",\"refresh\":");
        try writeJsonString(writer, report.stats.generation_refresh.refresh_status);
    }
    if (report.stats.postings_index.enabled and !report.stats.postings_index.available and report.stats.postings_index.fallback_reason.len != 0) {
        try writer.writeAll(",\"fallback_reason\":");
        try writeJsonString(writer, report.stats.postings_index.fallback_reason);
    }
    try writer.writeByte('}');

    try writer.writeAll(",\"hits\":{");
    var current_path: ?[]const u8 = null;
    for (report.hits[0..visible_count], 0..) |hit, index| {
        if (current_path == null or !std.mem.eql(u8, current_path.?, hit.path)) {
            if (current_path != null) try writer.writeByte(']');
            if (index != 0) try writer.writeByte(',');
            try writeJsonString(writer, hit.path);
            try writer.writeAll(":[");
            current_path = hit.path;
        } else {
            try writer.writeByte(',');
        }
        try writer.print("{{\"l\":{},\"c\":{},\"n\":{},\"p\":", .{ hit.line, hit.column, hit.match_len });
        try writeJsonString(writer, hit.preview);
        try writer.print(",\"w\":{{\"s\":{},\"e\":{},\"l\":{s},\"r\":{s}}}}}", .{
            hit.preview_start,
            hit.preview_end,
            boolText(hit.preview_elided_left),
            boolText(hit.preview_elided_right),
        });
    }
    if (current_path != null) try writer.writeByte(']');
    try writer.writeByte('}');

    if (context_reports.len > 0) {
        try writer.writeAll(",\"context\":[");
        for (context_reports, 0..) |context_report, report_index| {
            if (report_index != 0) try writer.writeByte(',');
            try writer.writeAll("{\"path\":");
            try writeJsonString(writer, context_report.path);
            try writer.writeAll(",\"lines\":[");
            for (context_report.lines[0..context_report.line_count], 0..) |line, line_index| {
                if (line_index != 0) try writer.writeByte(',');
                try writer.print("{{\"l\":{},\"r\":", .{line.number});
                try writeJsonString(writer, line.role);
                try writer.writeAll(",\"t\":");
                try writeJsonString(writer, line.text);
                try writer.writeByte('}');
            }
            try writer.writeAll("]}");
        }
        try writer.writeByte(']');
    }
    try writer.writeByte('}');
    if (options.raw_json) try writer.writeByte('\n') else try writer.writeAll(" --\n");
}

/// Selects the one recovery reason that explains the current projection boundary.
fn truncationReason(request: cli.SearchRequest, report: search.SearchReport, visible_count: usize, byte_truncated: bool) ?output_contract.TruncationReason {
    if (report.matches_after_cursor <= visible_count) return null;
    if (byte_truncated) return .byte_budget;
    if (request.max_hits != null) return .max_hits;
    return .retention_limit;
}

/// Emits a JSON string through Zig's canonical escaping implementation.
fn writeJsonString(writer: anytype, value: []const u8) !void {
    try std.json.Stringify.value(value, .{}, writer);
}

/// Serializes booleans without format-policy duplication.
fn boolText(value: bool) []const u8 {
    return if (value) "true" else "false";
}
