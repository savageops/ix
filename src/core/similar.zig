const std = @import("std");
const cli = @import("../cli/args.zig");

pub const Config = struct {
    base_url: []const u8,
    api_key: ?[]const u8,
    embedding_model: []const u8,
    rerank_model: []const u8,

    pub fn fromEnv(env: *const std.process.Environ.Map) Config {
        return .{
            .base_url = value(env, "IX_AI_BASE_URL") orelse "https://api.deepinfra.com/v1/openai",
            .api_key = value(env, "IX_AI_API_KEY") orelse value(env, "DEEPINFRA_TOKEN"),
            .embedding_model = value(env, "IX_AI_EMBED_MODEL") orelse "Qwen/Qwen3-Embedding-8B",
            .rerank_model = value(env, "IX_AI_RERANK_MODEL") orelse "cross-encoder/ms-marco-MiniLM-L-12-v2",
        };
    }

    fn value(env: *const std.process.Environ.Map, name: []const u8) ?[]const u8 {
        if (env.getPtr(name)) |entry| return entry.*;
        return null;
    }
};

const Document = struct {
    path: []const u8,
    text: []const u8,
    embedding: []f64 = &.{},
};

const Result = struct {
    path: []const u8,
    embedding_score: f64,
    rerank_score: f64,
};

const MAX_FILES: usize = 512;
const MAX_FILE_BYTES: usize = 256 * 1024;
const BINARY_SNIFF_BYTES: usize = 1024;

/// Runs the agent-facing semantic similarity lane.
///
/// Two modes:
///   1. Text query + paths: `ix similar "concept" <DIR_OR_FILE>...`
///      The query text is the anchor. Files discovered from paths are candidates.
///   2. File anchor + files: `ix similar <ANCHOR_FILE> <CANDIDATE_FILE>...`
///      The first file is the anchor; remaining are candidates (legacy mode).
///
/// Retrieval uses embeddings for broad recall, then a reranker for precision.
/// `--anti` reverses the final ranking so parity drift and unrelated peers
/// are first-class queries.
pub fn run(
    io: std.Io,
    allocator: std.mem.Allocator,
    request: cli.SimilarRequest,
    env: *const std.process.Environ.Map,
    writer: anytype,
) !void {
    const config = Config.fromEnv(env);
    const key = config.api_key orelse return error.ApiKeyRequired;
    if (key.len == 0) return error.ApiKeyRequired;

    const query = request.query orelse return error.MissingValue;

    // Determine if this is text-query mode or legacy file-anchor mode.
    // If the query string is an existing file path, use legacy mode.
    // Otherwise, treat it as a text concept and discover files from paths.
    const query_is_file = blk: {
        std.Io.Dir.cwd().access(io, query, .{}) catch break :blk false;
        break :blk true;
    };

    var document_list = std.ArrayList(Document).empty;

    if (query_is_file and request.path_count >= 1) {
        // Legacy mode: query is the anchor file, paths are candidates.
        const anchor_bytes = try std.Io.Dir.cwd().readFileAlloc(io, query, allocator, .limited(MAX_FILE_BYTES));
        try document_list.append(allocator, .{ .path = query, .text = anchor_bytes });
        for (request.paths[0..request.path_count]) |path| {
            if (std.mem.eql(u8, path, query)) continue;
            _ = try collectFile(io, allocator, &document_list, path);
        }
    } else {
        // Text-query mode: query is the concept, discover files from paths.
        for (request.paths[0..request.path_count]) |path| {
            try collectPath(io, allocator, &document_list, path);
        }
    }

    if (document_list.items.len < 2) return error.MissingValue;

    var documents = try document_list.toOwnedSlice(allocator);
    defer allocator.free(documents);

    // Embed all documents (including anchor if legacy mode).
    const inputs = try allocator.alloc([]const u8, documents.len);
    defer allocator.free(inputs);
    for (documents, 0..) |document, index| inputs[index] = document.text;

    const embedding_url = try std.fmt.allocPrint(allocator, "{s}/embeddings", .{config.base_url});
    defer allocator.free(embedding_url);
    const embedding_response = try postJson(io, allocator, embedding_url, key, try jsonPayload(allocator, .{
        .model = config.embedding_model,
        .input = inputs,
        .encoding_format = "float",
    }));
    defer allocator.free(embedding_response);
    const embeddings = try parseEmbeddings(allocator, embedding_response, documents.len);
    for (documents, 0..) |*document, index| document.embedding = embeddings[index];

    // Determine anchor: query text (text-query mode) or first document (legacy mode).
    const anchor_embedding: []f64 = if (query_is_file) documents[0].embedding else blk: {
        // Embed the query text separately.
        const query_input = [_][]const u8{query};
        const query_response = try postJson(io, allocator, embedding_url, key, try jsonPayload(allocator, .{
            .model = config.embedding_model,
            .input = &query_input,
            .encoding_format = "float",
        }));
        defer allocator.free(query_response);
        const query_embeddings = try parseEmbeddings(allocator, query_response, 1);
        break :blk query_embeddings[0];
    };

    // Candidate documents: all except anchor (in legacy mode, skip index 0).
    const candidate_start: usize = if (query_is_file) 1 else 0;
    const candidate_count = documents.len - candidate_start;

    var results = try allocator.alloc(Result, candidate_count);
    defer allocator.free(results);

    const rerank_documents = try allocator.alloc([]const u8, candidate_count);
    defer allocator.free(rerank_documents);
    for (documents[candidate_start..], 0..) |document, index| rerank_documents[index] = document.text;

    const rerank_url = try rerankUrl(allocator, config.base_url, config.rerank_model);
    defer allocator.free(rerank_url);
    const rerank_response = try postJson(io, allocator, rerank_url, key, try jsonPayload(allocator, .{
        .query = if (query_is_file) documents[0].text else query,
        .documents = rerank_documents,
    }));
    defer allocator.free(rerank_response);
    const rerank_scores = try parseScores(allocator, rerank_response, candidate_count);

    for (documents[candidate_start..], 0..) |document, index| {
        results[index] = .{
            .path = document.path,
            .embedding_score = cosine(anchor_embedding, document.embedding),
            .rerank_score = rerank_scores[index],
        };
    }
    std.sort.block(Result, results, {}, struct {
        fn lessThan(_: void, lhs: Result, rhs: Result) bool {
            return lhs.rerank_score > rhs.rerank_score;
        }
    }.lessThan);
    if (request.anti) std.mem.reverse(Result, results);
    const count = @min(request.max_results, results.len);

    // Output.
    if (request.output_format == .agent) {
        try writeAgentResult(writer, query, request.anti, results, count);
    } else if (request.json) {
        try writer.writeAll("{\"status\":\"ok\",\"query\":");
        try std.json.Stringify.value(if (query_is_file) documents[0].path else query, .{}, writer);
        try writer.writeAll(",\"anti\":");
        try writer.writeAll(if (request.anti) "true" else "false");
        try writer.writeAll(",\"results\":[");
        for (results[0..count], 0..) |result, index| {
            if (index != 0) try writer.writeByte(',');
            try writer.writeAll("{\"path\":");
            try std.json.Stringify.value(result.path, .{}, writer);
            try writer.print(",\"embedding\":{d:.6},\"rerank\":{d:.6}}}", .{ result.embedding_score, result.rerank_score });
        }
        try writer.writeAll("]}\n");
    } else {
        for (results[0..count]) |result| try writer.print("{d:.6}\t{d:.6}\t{s}\n", .{ result.rerank_score, result.embedding_score, result.path });
    }
}

/// Agent format: compact, one line per result with scores.
fn writeAgentResult(writer: anytype, query: []const u8, anti: bool, results: []const Result, count: usize) !void {
    try writer.writeAll("-- ix.similar.v1 {\"query\":");
    try std.json.Stringify.value(query, .{}, writer);
    try writer.writeAll(",\"anti\":");
    try writer.writeAll(if (anti) "true" else "false");
    try writer.print(",\"results\":{d}", .{count});
    try writer.writeAll(",\"hits\":[");
    for (results[0..count], 0..) |result, index| {
        if (index != 0) try writer.writeByte(',');
        try writer.writeAll("{\"path\":");
        try std.json.Stringify.value(result.path, .{}, writer);
        try writer.print(",\"e\":{d:.4},\"r\":{d:.4}}}", .{ result.embedding_score, result.rerank_score });
    }
    try writer.writeAll("]} --\n");
}

/// Collects a single file into the document list. Skips binary files
/// (null byte in first 1024 bytes) and files larger than MAX_FILE_BYTES.
fn collectFile(io: std.Io, allocator: std.mem.Allocator, list: *std.ArrayList(Document), path: []const u8) !bool {
    if (list.items.len >= MAX_FILES) return false;
    const bytes = std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(MAX_FILE_BYTES)) catch return false;
    // Binary sniff: skip files with null bytes in first 1024 bytes.
    const sniff_len = @min(BINARY_SNIFF_BYTES, bytes.len);
    for (bytes[0..sniff_len]) |b| {
        if (b == 0) {
            allocator.free(bytes);
            return false;
        }
    }
    // Skip empty files.
    if (bytes.len == 0) {
        allocator.free(bytes);
        return false;
    }
    try list.append(allocator, .{ .path = path, .text = bytes });
    return true;
}

/// Collects files from a path. If the path is a directory, recursively
/// discovers files within it. If it's a file, collects it directly.
fn collectPath(io: std.Io, allocator: std.mem.Allocator, list: *std.ArrayList(Document), path: []const u8) !void {
    // Check if path is a directory.
    const stat = std.Io.Dir.cwd().statFile(io, path, .{}) catch return;
    if (stat.kind == .directory) {
        var dir = std.Io.Dir.cwd().openDir(io, path, .{ .iterate = true }) catch return;
        defer dir.close(io);
        var iterator = dir.iterate();
        while (true) {
            const entry = iterator.next(io) catch break;
            const e = entry orelse break;
            if (e.kind == .file) {
                if (list.items.len >= MAX_FILES) break;
                // Join path with entry name.
                const child_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ path, e.name });
                const kept = collectFile(io, allocator, list, child_path) catch {
                    allocator.free(child_path);
                    continue;
                };
                if (!kept) allocator.free(child_path);
            } else if (e.kind == .directory) {
                if (e.name.len > 0 and e.name[0] == '.') continue;
                const child_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ path, e.name });
                collectPath(io, allocator, list, child_path) catch {};
                allocator.free(child_path);
            }
        }
    } else {
        _ = try collectFile(io, allocator, list, path);
    }
}

fn jsonPayload(allocator: std.mem.Allocator, value: anytype) ![]u8 {
    var output: std.Io.Writer.Allocating = .init(allocator);
    errdefer output.deinit();
    try std.json.Stringify.value(value, .{}, &output.writer);
    return output.toOwnedSlice();
}

fn postJson(io: std.Io, allocator: std.mem.Allocator, url: []const u8, key: []const u8, payload: []const u8) ![]u8 {
    var client: std.http.Client = .{ .allocator = allocator, .io = io };
    defer client.deinit();
    const auth = try std.fmt.allocPrint(allocator, "Bearer {s}", .{key});
    defer allocator.free(auth);
    var response: std.Io.Writer.Allocating = .init(allocator);
    errdefer response.deinit();
    const result = try client.fetch(.{
        .location = .{ .url = url },
        .method = .POST,
        .payload = payload,
        .headers = .{ .content_type = .{ .override = "application/json" }, .authorization = .{ .override = auth } },
        .response_writer = &response.writer,
    });
    if (result.status != .ok) return error.ApiRequestFailed;
    return response.toOwnedSlice();
}

fn rerankUrl(allocator: std.mem.Allocator, base_url: []const u8, model: []const u8) ![]u8 {
    const openai_suffix = "/openai";
    const root = if (std.mem.endsWith(u8, base_url, openai_suffix)) base_url[0 .. base_url.len - openai_suffix.len] else base_url;
    return std.fmt.allocPrint(allocator, "{s}/inference/{s}", .{ root, model });
}

fn parseEmbeddings(allocator: std.mem.Allocator, bytes: []const u8, count: usize) ![][]f64 {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, bytes, .{});
    defer parsed.deinit();
    const data = parsed.value.object.get("data") orelse return error.InvalidApiResponse;
    if (data != .array or data.array.items.len != count) return error.InvalidApiResponse;
    const result = try allocator.alloc([]f64, count);
    for (data.array.items, 0..) |item, index| {
        const values = item.object.get("embedding") orelse return error.InvalidApiResponse;
        if (values != .array) return error.InvalidApiResponse;
        const vector = try allocator.alloc(f64, values.array.items.len);
        for (values.array.items, 0..) |value, vector_index| vector[vector_index] = jsonNumber(value) orelse return error.InvalidApiResponse;
        result[index] = vector;
    }
    return result;
}

fn parseScores(allocator: std.mem.Allocator, bytes: []const u8, count: usize) ![]f64 {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, bytes, .{});
    defer parsed.deinit();
    const scores = parsed.value.object.get("scores") orelse return error.InvalidApiResponse;
    if (scores != .array or scores.array.items.len != count) return error.InvalidApiResponse;
    const result = try allocator.alloc(f64, count);
    for (scores.array.items, 0..) |score, index| result[index] = jsonNumber(score) orelse return error.InvalidApiResponse;
    return result;
}

fn jsonNumber(value: std.json.Value) ?f64 {
    return switch (value) {
        .float => |number| number,
        .integer => |number| @floatFromInt(number),
        else => null,
    };
}

fn cosine(lhs: []const f64, rhs: []const f64) f64 {
    if (lhs.len == 0 or lhs.len != rhs.len) return 0;
    var dot: f64 = 0;
    var lhs_norm: f64 = 0;
    var rhs_norm: f64 = 0;
    for (lhs, rhs) |left, right| {
        dot += left * right;
        lhs_norm += left * left;
        rhs_norm += right * right;
    }
    if (lhs_norm == 0 or rhs_norm == 0) return 0;
    return dot / (@sqrt(lhs_norm) * @sqrt(rhs_norm));
}

test "similar config defaults and env overrides" {
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    try env.put("IX_AI_API_KEY", "secret");
    try env.put("IX_AI_RERANK_MODEL", "custom-reranker");
    const config = Config.fromEnv(&env);
    try std.testing.expectEqualStrings("secret", config.api_key.?);
    try std.testing.expectEqualStrings("custom-reranker", config.rerank_model);
}

test "similar rerank URL derives from OpenAI-compatible base" {
    const url = try rerankUrl(std.testing.allocator, "https://api.deepinfra.com/v1/openai", "model");
    defer std.testing.allocator.free(url);
    try std.testing.expectEqualStrings("https://api.deepinfra.com/v1/inference/model", url);
}
