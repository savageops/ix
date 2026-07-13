const std = @import("std");
const cli = @import("../cli/args.zig");
const semantic_cursor = @import("../cli/cursor.zig");
const output_contract = @import("../cli/output_contract.zig");

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
    start_line: usize = 1,
    end_line: usize,
    embedding: []f64 = &.{},
};

const Result = struct {
    path: []const u8,
    start_line: usize,
    end_line: usize,
    embedding_score: f64,
    rerank_score: f64,
};

const Candidate = struct {
    path: []const u8,
    size: u64,
    mtime_ns: i128,
};

const Coverage = struct {
    files_eligible: usize,
    frontier_start: usize,
    candidates_evaluated: usize,
    files_read: usize,
    chunks_embedded: usize,
    bytes_submitted: usize,
    candidates_omitted: usize,
    skipped_binary: usize,
    skipped_empty: usize,
    skipped_oversize: usize,
    discovery_errors: usize,
    read_errors: usize,
};

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

    var candidate_list = std.ArrayList(Candidate).empty;
    var skipped_oversize: usize = 0;
    var discovery_errors: usize = 0;
    for (request.paths[0..request.path_count]) |path| {
        try collectCandidatePath(io, allocator, &candidate_list, path, query_is_file, query, &skipped_oversize, &discovery_errors);
    }
    canonicalizeCandidates(&candidate_list);
    const candidates = candidate_list.items;
    const corpus_signature = candidateCorpusSignature(candidates);
    const request_fingerprint = semantic_cursor.similarRequestFingerprint(request);
    if (request.cursor_request_fingerprint) |expected| {
        if (expected != request_fingerprint) return error.CursorRequestMismatch;
    }
    if (request.cursor_corpus_signature) |expected| {
        if (expected != corpus_signature) return error.StaleCursor;
    }

    const frontier_order = try buildFrontierOrder(allocator, candidates, query, request.candidate_budget);
    defer allocator.free(frontier_order);
    const frontier_start = request.cursor_ordinal;
    if (frontier_start > frontier_order.len) return error.StaleCursor;
    const frontier_end = @min(frontier_start + request.candidate_budget, frontier_order.len);

    var coverage = Coverage{
        .files_eligible = candidates.len,
        .frontier_start = frontier_start,
        .candidates_evaluated = frontier_end - frontier_start,
        .files_read = 0,
        .chunks_embedded = 0,
        .bytes_submitted = 0,
        .candidates_omitted = frontier_order.len - frontier_end,
        .skipped_binary = 0,
        .skipped_empty = 0,
        .skipped_oversize = skipped_oversize,
        .discovery_errors = discovery_errors,
        .read_errors = 0,
    };

    var document_list = std.ArrayList(Document).empty;
    defer document_list.deinit(allocator);
    if (query_is_file) {
        const anchor = try readAnchorDocument(io, allocator, query);
        try document_list.append(allocator, anchor);
    }
    for (frontier_order[frontier_start..frontier_end]) |candidate_index| {
        if (try readCandidateDocument(io, allocator, candidates[candidate_index], &coverage)) |document| {
            try document_list.append(allocator, document);
        }
    }

    const candidate_document_count = document_list.items.len - @intFromBool(query_is_file);
    coverage.chunks_embedded = candidate_document_count;
    if (candidate_document_count == 0) {
        if (isVersioned(request.output_format)) {
            const next_cursor = try semanticNextCursor(allocator, candidates, frontier_order, frontier_end, corpus_signature, request_fingerprint);
            try writeVersionedResult(writer, request, query, corpus_signature, request_fingerprint, coverage, &.{}, 0, next_cursor, null);
            return;
        }
        return error.MissingValue;
    }

    var documents = try document_list.toOwnedSlice(allocator);
    defer allocator.free(documents);

    // Embed all documents (including anchor if legacy mode).
    const inputs = try allocator.alloc([]const u8, documents.len);
    defer allocator.free(inputs);
    for (documents, 0..) |document, index| {
        inputs[index] = document.text;
        coverage.bytes_submitted += document.text.len;
    }

    const embedding_url = try std.fmt.allocPrint(allocator, "{s}/embeddings", .{config.base_url});
    defer allocator.free(embedding_url);
    const embedding_response = postJson(io, allocator, embedding_url, key, try jsonPayload(allocator, .{
        .model = config.embedding_model,
        .input = inputs,
        .encoding_format = "float",
    })) catch |err| return reportSemanticFailure(writer, request, query, corpus_signature, request_fingerprint, coverage, "embedding", err);
    defer allocator.free(embedding_response);
    const embeddings = try parseEmbeddings(allocator, embedding_response, documents.len);
    for (documents, 0..) |*document, index| document.embedding = embeddings[index];

    // Determine anchor: query text (text-query mode) or first document (legacy mode).
    const anchor_embedding: []f64 = if (query_is_file) documents[0].embedding else blk: {
        // Embed the query text separately.
        const query_input = [_][]const u8{query};
        coverage.bytes_submitted += query.len;
        const query_response = postJson(io, allocator, embedding_url, key, try jsonPayload(allocator, .{
            .model = config.embedding_model,
            .input = &query_input,
            .encoding_format = "float",
        })) catch |err| return reportSemanticFailure(writer, request, query, corpus_signature, request_fingerprint, coverage, "query_embedding", err);
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
    for (documents[candidate_start..], 0..) |document, index| {
        rerank_documents[index] = document.text;
        coverage.bytes_submitted += document.text.len;
    }
    coverage.bytes_submitted += if (query_is_file) documents[0].text.len else query.len;

    const rerank_url = try rerankUrl(allocator, config.base_url, config.rerank_model);
    defer allocator.free(rerank_url);
    const rerank_response = postJson(io, allocator, rerank_url, key, try jsonPayload(allocator, .{
        .query = if (query_is_file) documents[0].text else query,
        .documents = rerank_documents,
    })) catch |err| return reportSemanticFailure(writer, request, query, corpus_signature, request_fingerprint, coverage, "rerank", err);
    defer allocator.free(rerank_response);
    const rerank_scores = try parseScores(allocator, rerank_response, candidate_count);

    for (documents[candidate_start..], 0..) |document, index| {
        results[index] = .{
            .path = document.path,
            .start_line = document.start_line,
            .end_line = document.end_line,
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

    const next_cursor = try semanticNextCursor(allocator, candidates, frontier_order, frontier_end, corpus_signature, request_fingerprint);

    // Output. Legacy surfaces remain byte-compatible; the versioned surface owns coverage.
    if (isVersioned(request.output_format)) {
        try writeVersionedResult(writer, request, query, corpus_signature, request_fingerprint, coverage, results, count, next_cursor, null);
    } else if (request.output_format == .agent_v2) {
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

/// Discovers semantic candidates without reading their bodies or defining
/// eligibility through lexical overlap. Oversized files are explicit policy skips.
fn collectCandidatePath(
    io: std.Io,
    allocator: std.mem.Allocator,
    list: *std.ArrayList(Candidate),
    path: []const u8,
    exclude_anchor: bool,
    anchor: []const u8,
    skipped_oversize: *usize,
    discovery_errors: *usize,
) !void {
    const stat = std.Io.Dir.cwd().statFile(io, path, .{}) catch {
        discovery_errors.* += 1;
        return;
    };
    if (stat.kind == .directory) {
        var dir = std.Io.Dir.cwd().openDir(io, path, .{ .iterate = true }) catch {
            discovery_errors.* += 1;
            return;
        };
        defer dir.close(io);
        var iterator = dir.iterate();
        while (iterator.next(io) catch {
            discovery_errors.* += 1;
            return;
        }) |entry| {
            if (entry.kind == .directory and entry.name.len > 0 and entry.name[0] == '.') continue;
            if (entry.kind != .file and entry.kind != .directory) continue;
            const child_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ path, entry.name });
            defer allocator.free(child_path);
            try collectCandidatePath(io, allocator, list, child_path, exclude_anchor, anchor, skipped_oversize, discovery_errors);
        }
        return;
    }
    if (stat.kind != .file or (exclude_anchor and std.mem.eql(u8, path, anchor))) return;
    if (stat.size > MAX_FILE_BYTES) {
        skipped_oversize.* += 1;
        return;
    }
    try list.append(allocator, .{
        .path = try allocator.dupe(u8, path),
        .size = stat.size,
        .mtime_ns = stat.mtime.nanoseconds,
    });
}

/// Sorts and de-duplicates overlapping roots so one file is never paid for twice.
fn canonicalizeCandidates(list: *std.ArrayList(Candidate)) void {
    std.mem.sort(Candidate, list.items, {}, struct {
        fn lessThan(_: void, lhs: Candidate, rhs: Candidate) bool {
            return std.mem.lessThan(u8, lhs.path, rhs.path);
        }
    }.lessThan);
    var write_index: usize = 0;
    for (list.items) |candidate| {
        if (write_index != 0 and std.mem.eql(u8, list.items[write_index - 1].path, candidate.path)) continue;
        list.items[write_index] = candidate;
        write_index += 1;
    }
    list.items.len = write_index;
}

/// Binds continuation to the exact deterministic candidate corpus.
fn candidateCorpusSignature(candidates: []const Candidate) u64 {
    var hasher = std.hash.Wyhash.init(0x4958_5345_4d43_4f52);
    hashSignatureU64(&hasher, candidates.len);
    for (candidates) |candidate| {
        hashSignatureU64(&hasher, candidate.path.len);
        hasher.update(candidate.path);
        hashSignatureU64(&hasher, candidate.size);
        hashSignatureU128(&hasher, @bitCast(candidate.mtime_ns));
    }
    return hasher.final();
}

/// Writes one stable fixed-width corpus-signature word independent of host endianness.
fn hashSignatureU64(hasher: *std.hash.Wyhash, value: u64) void {
    var bytes: [8]u8 = undefined;
    for (&bytes, 0..) |*byte, index| byte.* = @truncate(value >> @intCast(index * 8));
    hasher.update(&bytes);
}

/// Preserves signed nanosecond identity as its exact two's-complement bit pattern.
fn hashSignatureU128(hasher: *std.hash.Wyhash, value: u128) void {
    var bytes: [16]u8 = undefined;
    for (&bytes, 0..) |*byte, index| byte.* = @truncate(value >> @intCast(index * 8));
    hasher.update(&bytes);
}

const RankedCandidate = struct { index: usize, lexical_score: usize };

/// Orders the first bounded batch as a union of lexical signal and evenly
/// distributed corpus coverage, then appends every remaining path canonically.
fn buildFrontierOrder(allocator: std.mem.Allocator, candidates: []const Candidate, query: []const u8, budget: usize) ![]usize {
    const order = try allocator.alloc(usize, candidates.len);
    errdefer allocator.free(order);
    if (candidates.len == 0) return order;
    const selected = try allocator.alloc(bool, candidates.len);
    defer allocator.free(selected);
    @memset(selected, false);
    const ranked = try allocator.alloc(RankedCandidate, candidates.len);
    defer allocator.free(ranked);
    for (candidates, 0..) |candidate, index| ranked[index] = .{ .index = index, .lexical_score = lexicalPathScore(candidate.path, query) };
    std.mem.sort(RankedCandidate, ranked, candidates, struct {
        fn lessThan(paths: []const Candidate, lhs: RankedCandidate, rhs: RankedCandidate) bool {
            if (lhs.lexical_score != rhs.lexical_score) return lhs.lexical_score > rhs.lexical_score;
            return std.mem.lessThan(u8, paths[lhs.index].path, paths[rhs.index].path);
        }
    }.lessThan);

    const first_batch = @min(budget, candidates.len);
    const lexical_target = @min((first_batch + 1) / 2, first_batch);
    var written: usize = 0;
    for (ranked) |candidate| {
        if (written >= lexical_target or candidate.lexical_score == 0) break;
        order[written] = candidate.index;
        selected[candidate.index] = true;
        written += 1;
    }
    const coverage_target = first_batch - written;
    var slot: usize = 0;
    while (slot < coverage_target) : (slot += 1) {
        const target = @min(((slot * 2 + 1) * candidates.len) / (coverage_target * 2), candidates.len - 1);
        const picked = nearestUnselected(selected, target) orelse break;
        order[written] = picked;
        selected[picked] = true;
        written += 1;
    }
    for (candidates, 0..) |_, index| {
        if (selected[index]) continue;
        order[written] = index;
        written += 1;
    }
    std.debug.assert(written == candidates.len);
    return order;
}

/// Finds the closest still-unselected corpus position with stable forward tie-breaking.
fn nearestUnselected(selected: []const bool, target: usize) ?usize {
    var distance: usize = 0;
    while (distance < selected.len) : (distance += 1) {
        const forward = target + distance;
        if (forward < selected.len and !selected[forward]) return forward;
        if (distance <= target) {
            const backward = target - distance;
            if (!selected[backward]) return backward;
        }
    }
    return null;
}

/// Scores path-name evidence only as prioritization; zero-scored files remain eligible.
fn lexicalPathScore(path: []const u8, query: []const u8) usize {
    var score: usize = 0;
    var start: usize = 0;
    while (start < query.len) {
        while (start < query.len and !std.ascii.isAlphanumeric(query[start])) : (start += 1) {}
        var end = start;
        while (end < query.len and std.ascii.isAlphanumeric(query[end])) : (end += 1) {}
        if (end > start + 1 and containsIgnoreCase(path, query[start..end])) score += 1;
        start = if (end == start) start + 1 else end;
    }
    return score;
}

/// Performs allocation-free ASCII-insensitive token lookup over one path.
fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0 or needle.len > haystack.len) return false;
    var offset: usize = 0;
    while (offset + needle.len <= haystack.len) : (offset += 1) {
        var equal = true;
        for (needle, 0..) |byte, index| {
            if (std.ascii.toLower(haystack[offset + index]) != std.ascii.toLower(byte)) {
                equal = false;
                break;
            }
        }
        if (equal) return true;
    }
    return false;
}

/// Reads the explicit file anchor through the same bounded whole-file policy.
fn readAnchorDocument(io: std.Io, allocator: std.mem.Allocator, path: []const u8) !Document {
    const stat = try std.Io.Dir.cwd().statFile(io, path, .{});
    if (stat.kind != .file or stat.size > MAX_FILE_BYTES) return error.MissingValue;
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(MAX_FILE_BYTES));
    if (bytes.len == 0 or isBinary(bytes)) return error.MissingValue;
    return .{ .path = path, .text = bytes, .end_line = sourceLineCount(bytes) };
}

/// Reads one selected candidate and records every non-embedded outcome explicitly.
fn readCandidateDocument(io: std.Io, allocator: std.mem.Allocator, candidate: Candidate, coverage: *Coverage) !?Document {
    const bytes = std.Io.Dir.cwd().readFileAlloc(io, candidate.path, allocator, .limited(MAX_FILE_BYTES)) catch {
        coverage.read_errors += 1;
        return null;
    };
    coverage.files_read += 1;
    if (bytes.len == 0) {
        coverage.skipped_empty += 1;
        allocator.free(bytes);
        return null;
    }
    if (isBinary(bytes)) {
        coverage.skipped_binary += 1;
        allocator.free(bytes);
        return null;
    }
    return .{ .path = candidate.path, .text = bytes, .end_line = sourceLineCount(bytes) };
}

/// Applies the bounded binary sniff used by the semantic body reader.
fn isBinary(bytes: []const u8) bool {
    const sniff_len = @min(BINARY_SNIFF_BYTES, bytes.len);
    return std.mem.indexOfScalar(u8, bytes[0..sniff_len], 0) != null;
}

/// Counts addressable source lines without inventing a trailing empty line.
fn sourceLineCount(bytes: []const u8) usize {
    if (bytes.len == 0) return 0;
    var lines = std.mem.count(u8, bytes, "\n");
    if (bytes[bytes.len - 1] != '\n') lines += 1;
    return @max(lines, 1);
}

/// Identifies the semantic formats with explicit coverage and continuation.
fn isVersioned(format: cli.OutputFormat) bool {
    return format == .agent_v3 or format == .json_compact;
}

/// Encodes the next frontier ordinal against corpus and request identity.
fn semanticNextCursor(
    allocator: std.mem.Allocator,
    candidates: []const Candidate,
    order: []const usize,
    frontier_end: usize,
    corpus_signature: u64,
    request_fingerprint: u64,
) !?[]const u8 {
    if (frontier_end == 0 or frontier_end >= order.len) return null;
    return try semantic_cursor.encode(allocator, .{
        .corpus_signature = corpus_signature,
        .request_fingerprint = request_fingerprint,
        .path = candidates[order[frontier_end - 1]].path,
        .line = frontier_end,
        .column = 1,
    });
}

/// Emits the one versioned semantic envelope with exact ranges and coverage.
fn writeVersionedResult(
    writer: anytype,
    request: cli.SimilarRequest,
    query: []const u8,
    corpus_signature: u64,
    request_fingerprint: u64,
    coverage: Coverage,
    results: []const Result,
    count: usize,
    next_cursor: ?[]const u8,
    failure: ?struct { phase: []const u8, code: []const u8 },
) !void {
    const raw = request.output_format == .json_compact;
    if (!raw) try writer.writeAll("-- ix.similar.v2 ");
    try writer.writeAll("{\"schema\":\"ix.similar.v2\",\"status\":");
    try writeJsonString(writer, if (failure == null) "ok" else "error");
    try writer.writeAll(",\"query\":");
    try writeJsonString(writer, query);
    try writer.print(",\"anti\":{s},\"corpus_signature\":\"{x}\",\"request_fingerprint\":\"{x}\"", .{
        if (request.anti) "true" else "false",
        corpus_signature,
        request_fingerprint,
    });
    const coverage_partial = coverage.candidates_omitted != 0 or coverage.discovery_errors != 0 or coverage.read_errors != 0;
    try writer.writeAll(",\"coverage\":{\"state\":");
    try writeJsonString(writer, if (coverage_partial) "partial" else "complete");
    try writer.print(",\"files_eligible\":{},\"frontier_start\":{},\"candidates_evaluated\":{},\"files_read\":{},\"chunks_embedded\":{},\"bytes_submitted\":{},\"candidates_omitted\":{},\"skipped_binary\":{},\"skipped_empty\":{},\"skipped_oversize\":{},\"discovery_errors\":{},\"read_errors\":{}", .{
        coverage.files_eligible,
        coverage.frontier_start,
        coverage.candidates_evaluated,
        coverage.files_read,
        coverage.chunks_embedded,
        coverage.bytes_submitted,
        coverage.candidates_omitted,
        coverage.skipped_binary,
        coverage.skipped_empty,
        coverage.skipped_oversize,
        coverage.discovery_errors,
        coverage.read_errors,
    });
    if (coverage.candidates_omitted != 0) {
        try writer.writeAll(",\"truncation_reason\":");
        try writeJsonString(writer, @tagName(output_contract.TruncationReason.similar_candidate_budget));
    }
    if (next_cursor) |value| {
        try writer.writeAll(",\"next_cursor\":");
        try writeJsonString(writer, value);
    }
    try writer.writeByte('}');
    if (failure) |value| {
        try writer.writeAll(",\"error\":{\"phase\":");
        try writeJsonString(writer, value.phase);
        try writer.writeAll(",\"code\":");
        try writeJsonString(writer, value.code);
        try writer.writeAll(",\"recovery\":\"verify semantic endpoint, model, credentials, and retry this cursor page\"}");
    }
    try writer.writeAll(",\"results\":[");
    for (results[0..count], 0..) |result, index| {
        if (index != 0) try writer.writeByte(',');
        try writer.writeAll("{\"path\":");
        try writeJsonString(writer, result.path);
        try writer.print(",\"start_line\":{},\"end_line\":{},\"embedding\":{d:.6},\"rerank\":{d:.6}}}", .{
            result.start_line,
            result.end_line,
            result.embedding_score,
            result.rerank_score,
        });
    }
    try writer.writeAll("]}");
    if (raw) try writer.writeByte('\n') else try writer.writeAll(" --\n");
}

/// Preserves partial semantic coverage when a remote provider rejects a page.
fn reportSemanticFailure(
    writer: anytype,
    request: cli.SimilarRequest,
    query: []const u8,
    corpus_signature: u64,
    request_fingerprint: u64,
    coverage: Coverage,
    phase: []const u8,
    source_error: anyerror,
) !void {
    if (!isVersioned(request.output_format)) return source_error;
    try writeVersionedResult(writer, request, query, corpus_signature, request_fingerprint, coverage, &.{}, 0, null, .{
        .phase = phase,
        .code = "provider_request_failed",
    });
    try writer.flush();
    return error.SemanticFailureReported;
}

/// Uses the canonical JSON stringifier for every public semantic string.
fn writeJsonString(writer: anytype, value: []const u8) !void {
    try std.json.Stringify.value(value, .{}, writer);
}

test "semantic discovery records inaccessible scope instead of claiming completeness" {
    const io = std.testing.io;
    var candidates = std.ArrayList(Candidate).empty;
    defer candidates.deinit(std.testing.allocator);
    var skipped_oversize: usize = 0;
    var discovery_errors: usize = 0;
    try collectCandidatePath(
        io,
        std.testing.allocator,
        &candidates,
        ".ix-missing-semantic-candidate-root",
        false,
        "",
        &skipped_oversize,
        &discovery_errors,
    );
    try std.testing.expectEqual(@as(usize, 0), candidates.items.len);
    try std.testing.expectEqual(@as(usize, 1), discovery_errors);
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

test "semantic frontier unions lexical signal with corpus coverage without hard filtering" {
    const candidates = [_]Candidate{
        .{ .path = "00/a.zig", .size = 1, .mtime_ns = 1 },
        .{ .path = "10/b.zig", .size = 1, .mtime_ns = 1 },
        .{ .path = "20/cache_owner.zig", .size = 1, .mtime_ns = 1 },
        .{ .path = "30/d.zig", .size = 1, .mtime_ns = 1 },
        .{ .path = "40/e.zig", .size = 1, .mtime_ns = 1 },
        .{ .path = "50/f.zig", .size = 1, .mtime_ns = 1 },
        .{ .path = "60/g.zig", .size = 1, .mtime_ns = 1 },
        .{ .path = "70/h.zig", .size = 1, .mtime_ns = 1 },
    };
    const first = try buildFrontierOrder(std.testing.allocator, &candidates, "cache ownership", 4);
    defer std.testing.allocator.free(first);
    const second = try buildFrontierOrder(std.testing.allocator, &candidates, "cache ownership", 4);
    defer std.testing.allocator.free(second);
    try std.testing.expectEqualSlices(usize, first, second);
    try std.testing.expectEqual(@as(usize, 2), first[0]);

    var seen = [_]bool{false} ** candidates.len;
    var zero_score_in_first_batch = false;
    for (first, 0..) |index, position| {
        try std.testing.expect(!seen[index]);
        seen[index] = true;
        if (position < 4 and lexicalPathScore(candidates[index].path, "cache ownership") == 0) zero_score_in_first_batch = true;
    }
    try std.testing.expect(zero_score_in_first_batch);
}

test "whole-file semantic coordinates remain exact until chunking is measured" {
    try std.testing.expectEqual(@as(usize, 1), sourceLineCount("one"));
    try std.testing.expectEqual(@as(usize, 2), sourceLineCount("one\ntwo"));
    try std.testing.expectEqual(@as(usize, 2), sourceLineCount("one\ntwo\n"));
}
