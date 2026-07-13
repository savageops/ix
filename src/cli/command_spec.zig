const std = @import("std");

/// Canonical output projections. Legacy flags lower into this enum at parse time.
pub const OutputFormat = enum {
    text,
    agent_v2,
    agent_v3,
    json,
    json_compact,
    files,
    count,
    stats,
};

pub const FormatSpec = struct {
    name: []const u8,
    format: OutputFormat,
    compatibility: []const u8,
    help: []const u8,
};

/// One table owns accepted format names, migration posture, and help text.
pub const formats = [_]FormatSpec{
    .{ .name = "text", .format = .text, .compatibility = "current", .help = "Hit records with the v1 terminal result" },
    .{ .name = "agent", .format = .agent_v2, .compatibility = "current", .help = "Compact grouped ix.result.v2" },
    .{ .name = "agent-v3", .format = .agent_v3, .compatibility = "versioned", .help = "Bounded, cursorable ix.result.v3" },
    .{ .name = "json", .format = .json, .compatibility = "current", .help = "Full compatible JSON with debug telemetry" },
    .{ .name = "json-compact", .format = .json_compact, .compatibility = "versioned", .help = "Raw compact v3 JSON without sentinel framing" },
    .{ .name = "files", .format = .files, .compatibility = "alias:-l", .help = "Unique paths with matches" },
    .{ .name = "count", .format = .count, .compatibility = "alias:-c", .help = "Per-file match counts" },
    .{ .name = "stats", .format = .stats, .compatibility = "alias:--stats-only", .help = "Suppress hit records and emit result telemetry" },
};

/// Resolves a public format name through the canonical table.
pub fn parseFormat(name: []const u8) ?OutputFormat {
    for (formats) |spec| if (std.mem.eql(u8, name, spec.name)) return spec.format;
    return null;
}

/// Writes the accepted names from the same table the parser consumes.
pub fn writeFormatNames(writer: anytype) !void {
    for (formats, 0..) |spec, index| {
        if (index != 0) try writer.writeAll(", ");
        try writer.writeAll(spec.name);
    }
}

test "every public output format round trips through the command specification" {
    inline for (formats) |spec| try std.testing.expectEqual(spec.format, parseFormat(spec.name).?);
    try std.testing.expect(parseFormat("unknown") == null);
}
