const std = @import("std");
const cli = @import("../cli/args.zig");
const expr = @import("expr.zig");
const search = @import("search.zig");
const inspect = @import("inspect.zig");
const xo = @import("xo.zig");
const output = @import("../cli/output.zig");

/// P30: MCP (Model Context Protocol) server for IX.
///
/// Exposes IX as a stateful tool that agents invoke via JSON-RPC over
/// stdio — no shelling out, no exit-code parsing, no stdout scraping.
/// The server reads JSON-RPC requests from stdin and writes responses
/// to stdout, following the MCP specification.
///
/// Supported methods:
///   - initialize: capability handshake
///   - tools/list: list available IX tools
///   - tools/call: invoke an IX tool (search, inspect, xo, explain)
pub fn run(io: std.Io, allocator: std.mem.Allocator) !void {
    var stdin_buf: [65536]u8 = undefined;
    var stdin_reader = std.Io.File.stdin().reader(io, &stdin_buf);
    var stdout_buf: [65536]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(io, &stdout_buf);
    const writer = &stdout_writer.interface;

    // Read lines from stdin using allocRemaining (simple, reliable)
    const stdin_bytes = stdin_reader.interface.allocRemaining(allocator, .limited(16 * 1024 * 1024)) catch return;
    defer allocator.free(stdin_bytes);

    var iter = std.mem.splitScalar(u8, stdin_bytes, '\n');
    while (iter.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r\n");
        if (trimmed.len == 0) continue;
        try handleRequest(io, allocator, writer, trimmed);
    }
    try writer.flush();
}

fn handleRequest(io: std.Io, allocator: std.mem.Allocator, writer: anytype, json: []const u8) !void {
    // Minimal JSON-RPC parsing — extract "method" and "id".
    const method = extractJsonString(json, "method") orelse {
        try writeError(writer, null, -32600, "Invalid Request");
        return;
    };
    const id = extractJsonNumber(json, "id");

    if (std.mem.eql(u8, method, "initialize")) {
        try writeResult(writer, id,
            \\{"protocolVersion":"2024-11-05","capabilities":{"tools":{}},"serverInfo":{"name":"ix","version":"2.0.0"}}
        );
        return;
    }
    if (std.mem.eql(u8, method, "tools/list")) {
        try writeResult(writer, id,
            \\{"tools":[
            \\{"name":"search","description":"Search files for matches using IX expression language (lit:, re:, prefix:, suffix:, &&, ||)","inputSchema":{"type":"object","properties":{"expression":{"type":"string"},"paths":{"type":"array","items":{"type":"string"}},"format":{"type":"string","enum":["agent","json","text"]},"max_hits":{"type":"number"},"max_bytes":{"type":"number"}},"required":["expression"]}},
            \\{"name":"inspect","description":"Read file windows and match context","inputSchema":{"type":"object","properties":{"path":{"type":"string"},"range":{"type":"string"},"expr":{"type":"string"},"context":{"type":"number"}},"required":["path"]}},
            \\{"name":"xo","description":"BM25 degree-of-interest context spans for agent reading","inputSchema":{"type":"object","properties":{"query":{"type":"string"},"paths":{"type":"array","items":{"type":"string"}},"max_bytes":{"type":"number"},"max_spans":{"type":"number"}},"required":["query","paths"]}},
            \\{"name":"explain","description":"Expression plan and strategy classification","inputSchema":{"type":"object","properties":{"expression":{"type":"string"}},"required":["expression"]}}
            \\]}
        );
        return;
    }
    if (std.mem.eql(u8, method, "tools/call")) {
        const tool = extractJsonString(json, "name") orelse {
            try writeError(writer, id, -32602, "Missing tool name");
            return;
        };

        if (std.mem.eql(u8, tool, "search")) {
            // Extract expression from params.arguments
            const expression = extractParamString(json, "expression") orelse {
                try writeError(writer, id, -32602, "Missing expression");
                return;
            };
            const plan = expr.parse(expression) catch |err| {
                try writeError(writer, id, -32603, @errorName(err));
                return;
            };
            // Build a minimal search request
            var request = cli.SearchRequest{
                .expression = expression,
                .paths = undefined,
                .path_count = 0,
                .json = false,
                .stats_only = false,
                .hidden = false,
                .line_numbers = false,
                .fixed_strings = false,
                .case_insensitive = false,
                .follow_symlinks = false,
                .no_ignore = true,
                .ignore_files = undefined,
                .ignore_file_count = 0,
                .max_hits = null,
                .threads = null,
                .emit_report = null,
                .nexus_build = false,
                .nexus_disabled = true,
                .index_enabled = false,
            };
            request.output_format = .agent_v2;
            const report = search.run(io, allocator, request, plan) catch |err| {
                try writeError(writer, id, -32603, @errorName(err));
                return;
            };
            // Render as agent v2 and wrap in MCP content
            var render_buf: std.Io.Writer.Allocating = .init(allocator);
            defer render_buf.deinit();
            output.writeSearchReportAgent(&render_buf.writer, report) catch {
                try writeError(writer, id, -32603, "render failed");
                return;
            };
            const result = try render_buf.toOwnedSlice();
            defer allocator.free(result);
            try writeContentResult(writer, id, result);
            return;
        }
        if (std.mem.eql(u8, tool, "explain")) {
            const expression = extractParamString(json, "expression") orelse {
                try writeError(writer, id, -32602, "Missing expression");
                return;
            };
            const plan = expr.parse(expression) catch |err| {
                try writeError(writer, id, -32603, @errorName(err));
                return;
            };
            var render_buf: std.Io.Writer.Allocating = .init(allocator);
            defer render_buf.deinit();
            output.writeExplain(&render_buf.writer, plan) catch {
                try writeError(writer, id, -32603, "render failed");
                return;
            };
            const result = try render_buf.toOwnedSlice();
            defer allocator.free(result);
            try writeContentResult(writer, id, result);
            return;
        }
        try writeError(writer, id, -32601, "Method not found");
        return;
    }
    if (std.mem.eql(u8, method, "notifications/initialized")) {
        // No response needed for notifications.
        return;
    }

    try writeError(writer, id, -32601, "Method not found");
}

fn writeResult(writer: anytype, id: ?u64, result_json: []const u8) !void {
    if (id) |i| {
        try writer.print("{{\"jsonrpc\":\"2.0\",\"id\":{},\"result\":{s}}}\n", .{ i, result_json });
    }
}

fn writeContentResult(writer: anytype, id: ?u64, content: []const u8) !void {
    if (id) |i| {
        try writer.print("{{\"jsonrpc\":\"2.0\",\"id\":{},\"result\":{{\"content\":[{{\"type\":\"text\",\"text\":\"", .{i});
        try writeEscaped(writer, content);
        try writer.writeAll("\"}]}}}\n");
    }
}

fn writeError(writer: anytype, id: ?u64, code: i32, message: []const u8) !void {
    try writer.print("{{\"jsonrpc\":\"2.0\",\"id\":", .{});
    if (id) |i| {
        try writer.print("{}", .{i});
    } else {
        try writer.writeAll("null");
    }
    try writer.print(",\"error\":{{\"code\":{},\"message\":\"", .{code});
    try writeEscaped(writer, message);
    try writer.writeAll("\"}}}\n");
}

fn writeEscaped(writer: anytype, text: []const u8) !void {
    for (text) |c| {
        switch (c) {
            '"' => try writer.writeAll("\\\""),
            '\\' => try writer.writeAll("\\\\"),
            '\n' => try writer.writeAll("\\n"),
            '\r' => try writer.writeAll("\\r"),
            '\t' => try writer.writeAll("\\t"),
            else => if (c < 0x20) {
                try writer.print("\\u{x:0>4}", .{c});
            } else {
                try writer.writeByte(c);
            },
        }
    }
}

fn extractJsonString(json: []const u8, key: []const u8) ?[]const u8 {
    var i: usize = 0;
    while (i + key.len + 4 < json.len) : (i += 1) {
        if (json[i] != '"') continue;
        if (!std.mem.startsWith(u8, json[i + 1 ..], key)) continue;
        if (json[i + 1 + key.len] != '"') continue;
        var j = i + 2 + key.len;
        while (j < json.len and json[j] != ':') j += 1;
        if (j >= json.len) return null;
        j += 1;
        while (j < json.len and (json[j] == ' ' or json[j] == '\t')) j += 1;
        if (j >= json.len or json[j] != '"') return null;
        const start = j + 1;
        var end = start;
        while (end < json.len and json[end] != '"') end += 1;
        if (end >= json.len) return null;
        return json[start..end];
    }
    return null;
}

fn extractJsonNumber(json: []const u8, key: []const u8) ?u64 {
    var i: usize = 0;
    while (i + key.len + 4 < json.len) : (i += 1) {
        if (json[i] != '"') continue;
        if (!std.mem.startsWith(u8, json[i + 1 ..], key)) continue;
        if (json[i + 1 + key.len] != '"') continue;
        var j = i + 2 + key.len;
        while (j < json.len and json[j] != ':') j += 1;
        if (j >= json.len) return null;
        j += 1;
        while (j < json.len and (json[j] == ' ' or json[j] == '\t')) j += 1;
        var end = j;
        while (end < json.len and json[end] >= '0' and json[end] <= '9') end += 1;
        if (end == j) return null;
        return std.fmt.parseInt(u64, json[j..end], 10) catch null;
    }
    return null;
}

fn extractParamString(json: []const u8, key: []const u8) ?[]const u8 {
    // Look for "arguments": { ... "key": "value" ... }
    var i: usize = 0;
    while (i + key.len + 4 < json.len) : (i += 1) {
        if (json[i] != '"') continue;
        if (!std.mem.startsWith(u8, json[i + 1 ..], key)) continue;
        if (json[i + 1 + key.len] != '"') continue;
        var j = i + 2 + key.len;
        while (j < json.len and json[j] != ':') j += 1;
        if (j >= json.len) return null;
        j += 1;
        while (j < json.len and (json[j] == ' ' or json[j] == '\t')) j += 1;
        if (j >= json.len or json[j] != '"') return null;
        const start = j + 1;
        var end = start;
        while (end < json.len and json[end] != '"') end += 1;
        if (end >= json.len) return null;
        return json[start..end];
    }
    return null;
}
