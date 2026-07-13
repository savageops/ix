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

pub const OptionSpec = struct {
    syntax: []const u8,
    names: []const []const u8,
    help: []const u8,
    search_only: bool = false,
    takes_value: bool = false,
};

/// One table owns the canonical search grammar presented by help and diagnostics.
pub const search_options = [_]OptionSpec{
    .{ .syntax = "--hidden", .names = &.{"--hidden"}, .help = "Include hidden files and directories" },
    .{ .syntax = "--no-ignore", .names = &.{"--no-ignore"}, .help = "Disable ignore-file admission" },
    .{ .syntax = "-u, --unrestricted", .names = &.{ "-u", "--unrestricted" }, .help = "Include hidden and ignored paths" },
    .{ .syntax = "--ignore-file <PATH>", .names = &.{"--ignore-file"}, .help = "Add an explicit ignore source", .takes_value = true },
    .{ .syntax = "--follow-symlinks", .names = &.{"--follow-symlinks"}, .help = "Follow symbolic links" },
    .{ .syntax = "-F, --fixed-strings", .names = &.{ "-F", "--fixed-strings" }, .help = "Treat the expression as a literal" },
    .{ .syntax = "-i, --ignore-case", .names = &.{ "-i", "--ignore-case" }, .help = "Match ASCII case-insensitively" },
    .{ .syntax = "--json", .names = &.{ "--json", "-j" }, .help = "Emit full structured JSON telemetry" },
    .{ .syntax = "--stats-only", .names = &.{"--stats-only"}, .help = "Disable hit collection and emit telemetry" },
    .{ .syntax = "--agent", .names = &.{"--agent"}, .help = "Emit compact grouped ix.result.v2", .search_only = true },
    .{ .syntax = "--format <FORMAT>", .names = &.{"--format"}, .help = "Select a canonical output projection", .takes_value = true },
    .{ .syntax = "-l, --files-with-matches", .names = &.{ "-l", "--files-with-matches" }, .help = "Emit unique matching paths" },
    .{ .syntax = "-c, --count", .names = &.{ "-c", "--count" }, .help = "Emit per-file match counts" },
    .{ .syntax = "--max-hits <N>", .names = &.{"--max-hits"}, .help = "Limit retained hit records", .takes_value = true },
    .{ .syntax = "--total-count <N>", .names = &.{"--total-count"}, .help = "Alias of --max-hits for bounded readers", .takes_value = true },
    .{ .syntax = "-t, --threads <N>", .names = &.{ "-t", "--threads" }, .help = "Request workers below the framework ceiling", .takes_value = true },
    .{ .syntax = "--emit-report <PATH>", .names = &.{"--emit-report"}, .help = "Write the full JSON report to a file", .takes_value = true },
    .{ .syntax = "--context <N>", .names = &.{"--context"}, .help = "Include exact coalesced context in v3", .search_only = true, .takes_value = true },
    .{ .syntax = "--max-bytes <N>", .names = &.{"--max-bytes"}, .help = "Bound one complete v3 envelope", .search_only = true, .takes_value = true },
    .{ .syntax = "--cursor <TOKEN>", .names = &.{"--cursor"}, .help = "Continue a request-bound v3 result", .search_only = true, .takes_value = true },
    .{ .syntax = "-n, --line-number [N]", .names = &.{ "-n", "--line-number" }, .help = "Emit line numbers; optional N also limits hits" },
    .{ .syntax = "-h, --help", .names = &.{ "-h", "--help" }, .help = "Print help" },
};

/// One table owns accepted format names, migration posture, and help text.
pub const formats = [_]FormatSpec{
    .{ .name = "records", .format = .text, .compatibility = "current", .help = "Hit records with the v1 terminal result" },
    .{ .name = "text", .format = .text, .compatibility = "alias:records", .help = "Alias of records" },
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

pub fn writeSearchOptions(writer: anytype, include_search_only: bool) !void {
    for (search_options) |spec| {
        if (spec.search_only and !include_search_only) continue;
        try writer.print("  {s:<30} {s}\n", .{ spec.syntax, spec.help });
    }
}

pub fn findSearchOption(name: []const u8, include_search_only: bool) ?OptionSpec {
    for (search_options) |spec| {
        if (spec.search_only and !include_search_only) continue;
        for (spec.names) |candidate| if (std.mem.eql(u8, name, candidate)) return spec;
    }
    return null;
}

test "every public output format round trips through the command specification" {
    inline for (formats) |spec| try std.testing.expectEqual(spec.format, parseFormat(spec.name).?);
    try std.testing.expect(parseFormat("unknown") == null);
}

test "search help metadata covers every bounded agent control" {
    inline for (.{ "--format", "--total-count", "--context", "--max-bytes", "--cursor" }) |name| {
        try std.testing.expect(findSearchOption(name, true) != null);
    }
}
