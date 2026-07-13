const std = @import("std");
const cli = @import("../cli/args.zig");
const output = @import("../cli/output.zig");
const preview = @import("preview.zig");

const MAX_QUERY_TERMS = 16;
const MAX_FILES = 1024;
const MAX_FILE_BYTES = 1024 * 1024;
const MAX_INPUT_BYTES = 16 * 1024 * 1024;
const MAX_CANDIDATE_LINES = 65_536;
const MAX_RADIUS = 8;
const MAX_OUTPUT_SPANS = cli.MAX_XO_SPANS;

const Coverage = struct {
    files_discovered: usize = 0,
    files_read: usize = 0,
    lines_read: usize = 0,
    bytes_read: usize = 0,
    candidate_lines: usize = 0,
    skipped_hidden: usize = 0,
    skipped_generated: usize = 0,
    skipped_binary: usize = 0,
    skipped_oversize: usize = 0,
    skipped_budget: usize = 0,
    errors: usize = 0,
    candidate_limit_reached: bool = false,
};

const QueryTerm = struct {
    text: []const u8,
    document_frequency: usize = 0,
};

const SourceLine = struct {
    number: usize,
    text: []const u8,
    token_count: usize,
};

const SourceFile = struct {
    path: []const u8,
    lines: []const SourceLine,
    path_term_hits: u16,
};

const DiscoveredFile = struct {
    path: []const u8,
    size: u64,
};

const Candidate = struct {
    file_index: usize,
    line_index: usize,
    frequencies: [MAX_QUERY_TERMS]u8,
    score: f64 = 0,
    focus_column: usize = 0,
};

const Span = struct {
    file_index: usize,
    focus_line_index: usize,
    start_line_index: usize,
    end_line_index: usize,
    score: f64,
    focus_column: usize = 0,
};

/// Builds one deterministic, bounded context projection without entering the search hot path.
///
/// Exact search remains the truth owner. XO reads a bounded corpus, scores source lines with
/// BM25 plus a small structural prior, then expands exact source spans while the output budget
/// permits. Every omission and incomplete traversal remains visible in the projection envelope.
pub fn run(io: std.Io, allocator: std.mem.Allocator, request: cli.XoRequest, writer: anytype) !void {
    const terms = try tokenizeQuery(allocator, request.query);
    if (terms.len == 0) return error.EmptyInsightQuery;

    var files = std.ArrayList(SourceFile).empty;
    var candidates = std.ArrayList(Candidate).empty;
    var discovered = std.ArrayList(DiscoveredFile).empty;
    var coverage = Coverage{};
    for (request.paths[0..request.path_count]) |path| {
        try discoverPath(io, allocator, path, &discovered, &coverage);
    }
    std.mem.sort(DiscoveredFile, discovered.items, {}, struct {
        fn lessThan(_: void, lhs: DiscoveredFile, rhs: DiscoveredFile) bool {
            return std.mem.lessThan(u8, lhs.path, rhs.path);
        }
    }.lessThan);
    var previous_path: []const u8 = "";
    for (discovered.items) |candidate_file| {
        if (previous_path.len != 0 and std.mem.eql(u8, previous_path, candidate_file.path)) continue;
        previous_path = candidate_file.path;
        try loadSourceFile(io, allocator, candidate_file, terms, &files, &candidates, &coverage);
    }

    scoreCandidates(files.items, terms, candidates.items, coverage.lines_read);
    std.mem.sort(Candidate, candidates.items, files.items, candidateLessThan);
    var spans = try selectSpans(allocator, files.items, candidates.items, request.max_spans);

    while (spans.len > 0 and try renderedLength(request, files.items, spans, coverage) > request.max_bytes) {
        spans.len -= 1;
    }
    if (spans.len == 0 and candidates.items.len != 0) return error.ByteBudgetTooSmall;

    try expandWithinBudget(request, files.items, spans, coverage);
    const bytes = try render(allocator, request, files.items, spans, coverage);
    if (bytes.len > request.max_bytes) return error.ByteBudgetTooSmall;
    try writer.writeAll(bytes);
}

/// Extracts distinct, useful query terms so natural-language glue cannot dominate code evidence.
fn tokenizeQuery(allocator: std.mem.Allocator, query: []const u8) ![]QueryTerm {
    var terms = std.ArrayList(QueryTerm).empty;
    var index: usize = 0;
    while (index < query.len and terms.items.len < MAX_QUERY_TERMS) {
        while (index < query.len and !isTermByte(query[index])) : (index += 1) {}
        const start = index;
        while (index < query.len and isTermByte(query[index])) : (index += 1) {}
        if (index - start < 2) continue;
        const term = query[start..index];
        if (isStopWord(term) or containsTerm(terms.items, term)) continue;
        try terms.append(allocator, .{ .text = try allocator.dupe(u8, term) });
    }
    return terms.toOwnedSlice(allocator);
}

/// Keeps query boundaries locale-independent and aligned with common code identifiers.
fn isTermByte(byte: u8) bool {
    return std.ascii.isAlphanumeric(byte) or byte == '_';
}

/// Removes natural-language glue whose frequency would drown the identifying code terms.
fn isStopWord(term: []const u8) bool {
    const words = [_][]const u8{ "a", "an", "and", "are", "as", "at", "be", "by", "code", "for", "from", "how", "in", "is", "it", "of", "on", "or", "that", "the", "this", "to", "with" };
    for (words) |word| if (std.ascii.eqlIgnoreCase(term, word)) return true;
    return false;
}

/// Prevents repeated query words from multiplying the same retrieval evidence.
fn containsTerm(terms: []const QueryTerm, candidate: []const u8) bool {
    for (terms) |term| if (std.ascii.eqlIgnoreCase(term.text, candidate)) return true;
    return false;
}

/// Discovers only regular files/directories and makes every skipped scope attributable.
fn discoverPath(
    io: std.Io,
    allocator: std.mem.Allocator,
    path: []const u8,
    discovered: *std.ArrayList(DiscoveredFile),
    coverage: *Coverage,
) !void {
    const stat = std.Io.Dir.cwd().statFile(io, path, .{}) catch {
        coverage.errors += 1;
        return;
    };
    if (stat.kind == .directory) {
        var dir = std.Io.Dir.cwd().openDir(io, path, .{ .iterate = true }) catch {
            coverage.errors += 1;
            return;
        };
        defer dir.close(io);
        var iterator = dir.iterate();
        while (iterator.next(io) catch {
            coverage.errors += 1;
            return;
        }) |entry| {
            if (entry.name.len > 0 and entry.name[0] == '.') {
                coverage.skipped_hidden += 1;
                continue;
            }
            if (entry.kind == .directory and isGeneratedDirectory(entry.name)) {
                coverage.skipped_generated += 1;
                continue;
            }
            if (entry.kind != .file and entry.kind != .directory) continue;
            const child = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ path, entry.name });
            try discoverPath(io, allocator, child, discovered, coverage);
        }
        return;
    }
    if (stat.kind != .file) return;
    coverage.files_discovered += 1;
    try discovered.append(allocator, .{ .path = try allocator.dupe(u8, path), .size = stat.size });
}

/// Excludes derived copies that otherwise crowd out canonical source with duplicate evidence.
fn isGeneratedDirectory(name: []const u8) bool {
    const names = [_][]const u8{ "build", "coverage", "dist", "node_modules", "target", "tmp", "zig-out" };
    for (names) |generated| if (std.ascii.eqlIgnoreCase(name, generated)) return true;
    return false;
}

/// Reads the deterministic discovered frontier under hard file and aggregate-byte limits.
fn loadSourceFile(
    io: std.Io,
    allocator: std.mem.Allocator,
    candidate_file: DiscoveredFile,
    terms: []QueryTerm,
    files: *std.ArrayList(SourceFile),
    candidates: *std.ArrayList(Candidate),
    coverage: *Coverage,
) !void {
    if (coverage.files_read >= MAX_FILES or coverage.bytes_read >= MAX_INPUT_BYTES) {
        coverage.skipped_budget += 1;
        return;
    }
    if (candidate_file.size > MAX_FILE_BYTES) {
        coverage.skipped_oversize += 1;
        return;
    }
    if (candidate_file.size > MAX_INPUT_BYTES - coverage.bytes_read) {
        coverage.skipped_budget += 1;
        return;
    }

    const bytes = std.Io.Dir.cwd().readFileAlloc(io, candidate_file.path, allocator, .limited(MAX_FILE_BYTES)) catch {
        coverage.errors += 1;
        return;
    };
    coverage.files_read += 1;
    coverage.bytes_read += bytes.len;
    if (isBinary(bytes)) {
        coverage.skipped_binary += 1;
        return;
    }
    try appendSourceFile(allocator, candidate_file.path, bytes, terms, files, candidates, coverage);
}

/// Applies the same bounded NUL-byte admission signal used by the other reading lanes.
fn isBinary(bytes: []const u8) bool {
    return std.mem.indexOfScalar(u8, bytes[0..@min(bytes.len, 1024)], 0) != null;
}

/// Materializes addressable lines once so scoring and later expansion share exact source slices.
fn appendSourceFile(
    allocator: std.mem.Allocator,
    path: []const u8,
    bytes: []const u8,
    terms: []QueryTerm,
    files: *std.ArrayList(SourceFile),
    candidates: *std.ArrayList(Candidate),
    coverage: *Coverage,
) !void {
    var lines = std.ArrayList(SourceLine).empty;
    var cursor: usize = 0;
    var line_number: usize = 1;
    while (cursor < bytes.len) : (line_number += 1) {
        const newline = std.mem.indexOfScalar(u8, bytes[cursor..], '\n');
        const end = if (newline) |offset| cursor + offset else bytes.len;
        const text = std.mem.trimEnd(u8, bytes[cursor..end], "\r");
        try lines.append(allocator, .{ .number = line_number, .text = text, .token_count = countTokens(text) });
        cursor = if (newline == null) bytes.len else end + 1;
    }
    if (bytes.len == 0) try lines.append(allocator, .{ .number = 1, .text = "", .token_count = 0 });

    const file_index = files.items.len;
    const owned_lines = try lines.toOwnedSlice(allocator);
    var path_hits: u16 = 0;
    for (terms, 0..) |term, term_index| {
        if (containsFold(path, term.text)) path_hits |= @as(u16, 1) << @intCast(term_index);
    }
    try files.append(allocator, .{ .path = try normalizePath(allocator, path), .lines = owned_lines, .path_term_hits = path_hits });

    for (owned_lines, 0..) |line, line_index| {
        coverage.lines_read += 1;
        if (candidates.items.len >= MAX_CANDIDATE_LINES) {
            coverage.candidate_limit_reached = true;
            continue;
        }
        var frequencies: [MAX_QUERY_TERMS]u8 = @splat(0);
        var matched = false;
        for (terms, 0..) |*term, term_index| {
            frequencies[term_index] = countFold(line.text, term.text);
            if (frequencies[term_index] != 0) {
                term.document_frequency += 1;
                matched = true;
            }
        }
        if (!matched) continue;
        coverage.candidate_lines += 1;
        var focus_column: usize = 0;
        for (terms, 0..) |term, term_index| {
            if (frequencies[term_index] == 0) continue;
            focus_column = findFirstFold(line.text, term.text) orelse 0;
            break;
        }
        try candidates.append(allocator, .{ .file_index = file_index, .line_index = line_index, .frequencies = frequencies, .focus_column = focus_column });
    }
}

/// Emits one stable, compact display spelling independent of the shell's separator choice.
fn normalizePath(allocator: std.mem.Allocator, path: []const u8) ![]const u8 {
    var display = path;
    while (display.len >= 2 and display[0] == '.' and (display[1] == '/' or display[1] == '\\')) display = display[2..];
    const normalized = try allocator.dupe(u8, if (display.len == 0) "." else display);
    for (normalized) |*byte| if (byte.* == '\\') {
        byte.* = '/';
    };
    return normalized;
}

/// Supplies BM25 document length without allocating a second token stream.
fn countTokens(text: []const u8) usize {
    var count: usize = 0;
    var in_token = false;
    for (text) |byte| {
        const current = isTermByte(byte);
        if (current and !in_token) count += 1;
        in_token = current;
    }
    return count;
}

/// Counts bounded ASCII-insensitive term frequency with saturating storage.
fn countFold(haystack: []const u8, needle: []const u8) u8 {
    if (needle.len == 0 or needle.len > haystack.len) return 0;
    var count: u8 = 0;
    var offset: usize = 0;
    while (offset + needle.len <= haystack.len) : (offset += 1) {
        if (!std.ascii.eqlIgnoreCase(haystack[offset .. offset + needle.len], needle)) continue;
        count +|= 1;
        offset += needle.len - 1;
    }
    return count;
}

/// Reuses the exact frequency matcher for path and structural presence tests.
fn containsFold(haystack: []const u8, needle: []const u8) bool {
    return countFold(haystack, needle) != 0;
}

/// Returns the 0-based byte offset of the first case-insensitive occurrence, or null.
fn findFirstFold(haystack: []const u8, needle: []const u8) ?usize {
    if (needle.len == 0 or needle.len > haystack.len) return null;
    var offset: usize = 0;
    while (offset + needle.len <= haystack.len) : (offset += 1) {
        if (std.ascii.eqlIgnoreCase(haystack[offset .. offset + needle.len], needle)) return offset;
    }
    return null;
}

/// Computes standard BM25 line relevance; structural/path priors only break lexical ties.
fn scoreCandidates(files: []const SourceFile, terms: []const QueryTerm, candidates: []Candidate, total_lines: usize) void {
    var total_tokens: usize = 0;
    for (files) |file| for (file.lines) |line| {
        total_tokens += line.token_count;
    };
    const average_length = @max(@as(f64, @floatFromInt(total_tokens)) / @as(f64, @floatFromInt(@max(total_lines, 1))), 1.0);
    const document_count = @as(f64, @floatFromInt(@max(total_lines, 1)));
    for (candidates) |*candidate| {
        const file = files[candidate.file_index];
        const line = file.lines[candidate.line_index];
        const line_length = @as(f64, @floatFromInt(@max(line.token_count, 1)));
        var value: f64 = 0;
        for (terms, 0..) |term, term_index| {
            const frequency = @as(f64, @floatFromInt(candidate.frequencies[term_index]));
            if (frequency == 0) continue;
            const df = @as(f64, @floatFromInt(term.document_frequency));
            const idf = @log(1.0 + (document_count - df + 0.5) / (df + 0.5));
            const denominator = frequency + 1.2 * (1.0 - 0.75 + 0.75 * line_length / average_length);
            value += idf * (frequency * 2.2) / denominator;
        }
        const path_matches: u16 = @popCount(file.path_term_hits);
        candidate.score = value + @as(f64, @floatFromInt(path_matches)) * 0.08 + structuralPrior(line.text);
    }
}

/// Gives declarations and rationale comments a small tie-breaker, never lexical eligibility.
/// Checks comment prefix first to avoid false-positive keyword matches inside comments.
/// Anchors declaration markers to the start of the trimmed line to avoid matching
/// keywords inside string literals.
fn structuralPrior(line: []const u8) f64 {
    const trimmed = std.mem.trimStart(u8, line, " \t");
    if (std.mem.startsWith(u8, trimmed, "//") or std.mem.startsWith(u8, trimmed, "#")) return 0.08;
    const markers = [_][]const u8{ "fn ", "function ", "class ", "struct ", "const ", "pub ", "export ", "impl ", "interface " };
    for (markers) |marker| if (std.mem.startsWith(u8, trimmed, marker)) return 0.18;
    return 0;
}

/// Freezes ranking ties by canonical path and line so repeated runs are byte-stable.
fn candidateLessThan(files: []const SourceFile, lhs: Candidate, rhs: Candidate) bool {
    if (lhs.score != rhs.score) return lhs.score > rhs.score;
    const lhs_path = files[lhs.file_index].path;
    const rhs_path = files[rhs.file_index].path;
    if (!std.mem.eql(u8, lhs_path, rhs_path)) return std.mem.lessThan(u8, lhs_path, rhs_path);
    return lhs.line_index < rhs.line_index;
}

/// Selects separated focus points so one dense cluster cannot consume the whole projection.
fn selectSpans(allocator: std.mem.Allocator, files: []const SourceFile, candidates: []const Candidate, max_spans: usize) ![]Span {
    var spans = std.ArrayList(Span).empty;
    for (candidates) |candidate| {
        if (spans.items.len >= max_spans) break;
        var too_close = false;
        for (spans.items) |span| {
            if (span.file_index != candidate.file_index) continue;
            const distance = if (span.focus_line_index > candidate.line_index) span.focus_line_index - candidate.line_index else candidate.line_index - span.focus_line_index;
            if (distance <= MAX_RADIUS * 2 + 1) {
                too_close = true;
                break;
            }
        }
        if (too_close) continue;
        const line_count = files[candidate.file_index].lines.len;
        if (line_count == 0) continue;
        try spans.append(allocator, .{
            .file_index = candidate.file_index,
            .focus_line_index = candidate.line_index,
            .start_line_index = candidate.line_index,
            .end_line_index = candidate.line_index,
            .score = candidate.score,
            .focus_column = candidate.focus_column,
        });
    }
    return spans.toOwnedSlice(allocator);
}

/// Expands highest-value focus points geometrically and accepts a line only when the full envelope still fits.
fn expandWithinBudget(request: cli.XoRequest, files: []const SourceFile, spans: []Span, coverage: Coverage) !void {
    var distance: usize = 1;
    while (distance <= MAX_RADIUS) : (distance += 1) {
        var changed = false;
        for (spans) |*span| {
            if (span.score / @as(f64, @floatFromInt(distance + 1)) < 0.20) continue;
            if (span.focus_line_index >= distance) {
                const previous = span.start_line_index;
                span.start_line_index = span.focus_line_index - distance;
                if (try renderedLength(request, files, spans, coverage) <= request.max_bytes) changed = true else span.start_line_index = previous;
            }
            if (span.focus_line_index + distance < files[span.file_index].lines.len) {
                const previous = span.end_line_index;
                span.end_line_index = span.focus_line_index + distance;
                if (try renderedLength(request, files, spans, coverage) <= request.max_bytes) changed = true else span.end_line_index = previous;
            }
        }
        if (!changed) break;
    }
}

/// Measures the real serializer through a discard writer so budget trials allocate nothing.
fn renderedLength(request: cli.XoRequest, files: []const SourceFile, spans: []const Span, coverage: Coverage) !usize {
    var buffer: [256]u8 = undefined;
    var discarding: std.Io.Writer.Discarding = .init(&buffer);
    try writeProjection(&discarding.writer, request, files, spans, coverage);
    return @intCast(discarding.fullCount());
}

/// Allocates only the final envelope after all candidate shapes pass measurement.
fn render(allocator: std.mem.Allocator, request: cli.XoRequest, files: []const SourceFile, spans: []const Span, coverage: Coverage) ![]u8 {
    var rendered: std.Io.Writer.Allocating = .init(allocator);
    try writeProjection(&rendered.writer, request, files, spans, coverage);
    return rendered.toOwnedSlice();
}

/// Routes both projections through identical span selection and budget accounting.
fn writeProjection(writer: anytype, request: cli.XoRequest, files: []const SourceFile, spans: []const Span, coverage: Coverage) !void {
    if (request.format == .json)
        try writeJson(writer, request, files, spans, coverage)
    else
        try writeGrouped(writer, request, files, spans, coverage);
}

/// Groups each path once while preserving source order and making every discontinuity visible.
fn writeGrouped(writer: anytype, request: cli.XoRequest, files: []const SourceFile, spans: []const Span, coverage: Coverage) !void {
    try writer.writeAll("-- ix.xo.v1 query=");
    try output.writeJsonString(writer, request.query);
    try writer.print(" retrieval=bm25_line assembly=degree_of_interest files_read={} bytes_read={} candidates={} returned={} coverage={s} --\n", .{
        coverage.files_read,
        coverage.bytes_read,
        coverage.candidate_lines,
        spans.len,
        coverageState(coverage),
    });
    var emitted: [MAX_OUTPUT_SPANS]usize = undefined;
    var emitted_count: usize = 0;
    while (true) {
        const next_file = nextFileByScore(spans, emitted[0..emitted_count]) orelse break;
        emitted[emitted_count] = next_file;
        emitted_count += 1;
        try writer.print("{s}:\n", .{files[next_file].path});
        var previous_end: ?usize = null;
        while (nextSpanInFile(spans, next_file, previous_end)) |span_index| {
            const span = spans[span_index];
            const first = files[next_file].lines[span.start_line_index].number;
            const last = files[next_file].lines[span.end_line_index].number;
            if (previous_end) |end_line| if (first > end_line + 1) try writer.print("  ... {} lines omitted ...\n", .{first - end_line - 1});
            try writer.print("  lines {}:{} focus={} score={d:.4}\n", .{ first, last, files[next_file].lines[span.focus_line_index].number, span.score });
            for (files[next_file].lines[span.start_line_index .. span.end_line_index + 1]) |line| {
                if (line.text.len > 300) {
                    const span_start = if (line.number == files[next_file].lines[span.focus_line_index].number) span.focus_column else 0;
                    const compact = preview.make(std.heap.page_allocator, line.text, .{ .start = span_start, .end = span_start }) catch line.text;
                    try writer.print("  {} | {s}\n", .{ line.number, compact.text });
                } else {
                    try writer.print("  {} | {s}\n", .{ line.number, line.text });
                }
            }
            previous_end = last;
        }
    }
}

/// Orders file groups by their strongest focus while keeping each path contiguous.
fn nextFileByScore(spans: []const Span, emitted: []const usize) ?usize {
    var best_file: ?usize = null;
    var best_score: f64 = -1;
    for (spans) |span| {
        if (containsFile(emitted, span.file_index) or span.score <= best_score) continue;
        best_file = span.file_index;
        best_score = span.score;
    }
    return best_file;
}

/// Tracks the tiny emitted group set on stack instead of allocating during size probes.
fn containsFile(files: []const usize, candidate: usize) bool {
    for (files) |file| if (file == candidate) return true;
    return false;
}

/// Restores narrative source order inside a relevance-ranked file group.
fn nextSpanInFile(spans: []const Span, file_index: usize, previous_end: ?usize) ?usize {
    var best: ?usize = null;
    var best_start: usize = std.math.maxInt(usize);
    for (spans, 0..) |span, index| {
        if (span.file_index != file_index) continue;
        const line = span.start_line_index;
        if (previous_end) |end| if (line <= end) continue;
        if (line < best_start) {
            best = index;
            best_start = line;
        }
    }
    return best;
}

/// Emits a versioned machine contract whose retrieval labels name only stages that actually ran.
fn writeJson(writer: anytype, request: cli.XoRequest, files: []const SourceFile, spans: []const Span, coverage: Coverage) !void {
    try writer.writeAll("{\"schema\":\"ix.xo.v1\",\"query\":");
    try output.writeJsonString(writer, request.query);
    try writer.writeAll(",\"retrieval\":{\"candidate\":\"bm25_line\",\"structural_prior\":true,\"semantic\":false,\"assembly\":\"degree_of_interest\"},\"coverage\":{");
    try writer.print("\"state\":\"{s}\",\"files_discovered\":{},\"files_read\":{},\"lines_read\":{},\"bytes_read\":{},\"candidate_lines\":{},\"skipped_hidden\":{},\"skipped_generated\":{},\"skipped_binary\":{},\"skipped_oversize\":{},\"skipped_budget\":{},\"errors\":{},\"candidate_limit_reached\":{s}", .{
        coverageState(coverage),                    coverage.files_discovered,  coverage.files_read,     coverage.lines_read,       coverage.bytes_read,     coverage.candidate_lines,
        coverage.skipped_hidden,                    coverage.skipped_generated, coverage.skipped_binary, coverage.skipped_oversize, coverage.skipped_budget, coverage.errors,
        boolText(coverage.candidate_limit_reached),
    });
    try writer.writeAll("},\"projection\":{");
    try writer.print("\"max_bytes\":{},\"max_spans\":{},\"returned_spans\":{}", .{ request.max_bytes, request.max_spans, spans.len });
    try writer.writeAll("},\"files\":[");
    var emitted: [MAX_OUTPUT_SPANS]usize = undefined;
    var emitted_count: usize = 0;
    var file_output_index: usize = 0;
    while (true) {
        const next_file = nextFileByScore(spans, emitted[0..emitted_count]) orelse break;
        emitted[emitted_count] = next_file;
        emitted_count += 1;
        if (file_output_index != 0) try writer.writeByte(',');
        file_output_index += 1;
        try writer.writeAll("{\"path\":");
        try output.writeJsonString(writer, files[next_file].path);
        try writer.writeAll(",\"spans\":[");
        var previous_end: ?usize = null;
        var span_output_index: usize = 0;
        while (nextSpanInFile(spans, next_file, previous_end)) |span_index| {
            const span = spans[span_index];
            if (span_output_index != 0) try writer.writeByte(',');
            span_output_index += 1;
            const first = files[next_file].lines[span.start_line_index].number;
            const last = files[next_file].lines[span.end_line_index].number;
            try writer.print("{{\"start_line\":{},\"end_line\":{},\"focus_line\":{},\"score\":{d:.6},\"omitted_before\":{},\"lines\":[", .{
                first, last, files[next_file].lines[span.focus_line_index].number, span.score, if (previous_end) |end| first - end - 1 else first - 1,
            });
            for (files[next_file].lines[span.start_line_index .. span.end_line_index + 1], 0..) |line, line_index| {
                if (line_index != 0) try writer.writeByte(',');
                try writer.print("{{\"line\":{},\"text\":", .{line.number});
                if (line.text.len > 300) {
                    const span_start = if (line.number == files[next_file].lines[span.focus_line_index].number) span.focus_column else 0;
                    const compact = preview.make(std.heap.page_allocator, line.text, .{ .start = span_start, .end = span_start }) catch line.text;
                    try output.writeJsonString(writer, compact.text);
                } else {
                    try output.writeJsonString(writer, line.text);
                }
                try writer.writeByte('}');
            }
            try writer.writeAll("]}");
            previous_end = last;
        }
        // Emit trailing omission count so agents can see if the file continues past the last span.
        const total_lines_in_file = files[next_file].lines.len;
        const omitted_after: usize = if (previous_end) |last_line| total_lines_in_file -| last_line else total_lines_in_file;
        try writer.print(",\"omitted_after\":{}}}", .{omitted_after});
    }
    try writer.writeAll("]}\n");
}

/// Refuses to call policy omissions or bounded traversal exhaustive coverage.
fn coverageState(coverage: Coverage) []const u8 {
    return if (coverage.errors != 0 or coverage.skipped_hidden != 0 or coverage.skipped_generated != 0 or coverage.skipped_binary != 0 or coverage.skipped_budget != 0 or coverage.skipped_oversize != 0 or coverage.candidate_limit_reached) "partial" else "complete";
}

/// Keeps JSON booleans allocation-free and unquoted.
fn boolText(value: bool) []const u8 {
    return if (value) "true" else "false";
}

test "xo query tokenization removes glue and deduplicates terms" {
    const terms = try tokenizeQuery(std.testing.allocator, "code with worker events and WORKER");
    defer {
        for (terms) |term| std.testing.allocator.free(term.text);
        std.testing.allocator.free(terms);
    }
    try std.testing.expectEqual(@as(usize, 2), terms.len);
    try std.testing.expectEqualStrings("worker", terms[0].text);
    try std.testing.expectEqualStrings("events", terms[1].text);
}

test "xo BM25 ranks multi-term declaration over incidental mention" {
    var terms = [_]QueryTerm{ .{ .text = "worker", .document_frequency = 2 }, .{ .text = "events", .document_frequency = 1 } };
    const lines = [_]SourceLine{
        .{ .number = 1, .text = "const worker = 1;", .token_count = 3 },
        .{ .number = 2, .text = "pub fn worker_events() void {", .token_count = 5 },
    };
    const files = [_]SourceFile{.{ .path = "worker.zig", .lines = &lines, .path_term_hits = 1 }};
    var candidates = [_]Candidate{
        .{ .file_index = 0, .line_index = 0, .frequencies = .{ 1, 0 } ++ .{0} ** (MAX_QUERY_TERMS - 2) },
        .{ .file_index = 0, .line_index = 1, .frequencies = .{ 1, 1 } ++ .{0} ** (MAX_QUERY_TERMS - 2) },
    };
    scoreCandidates(&files, &terms, &candidates, lines.len);
    try std.testing.expect(candidates[1].score > candidates[0].score);
}

test "xo rendering groups a path once and honors byte measurement" {
    const lines = [_]SourceLine{
        .{ .number = 1, .text = "alpha", .token_count = 1 },
        .{ .number = 2, .text = "worker events", .token_count = 2 },
        .{ .number = 3, .text = "omega", .token_count = 1 },
    };
    const files = [_]SourceFile{.{ .path = "src/a.zig", .lines = &lines, .path_term_hits = 0 }};
    const spans = [_]Span{.{ .file_index = 0, .focus_line_index = 1, .start_line_index = 0, .end_line_index = 2, .score = 2 }};
    const request = cli.XoRequest{ .query = "worker \"events\"\nnext", .paths = undefined, .path_count = 0, .max_bytes = 4096 };
    const bytes = try render(std.testing.allocator, request, &files, &spans, .{ .files_read = 1, .lines_read = 3, .bytes_read = 25, .candidate_lines = 1 });
    defer std.testing.allocator.free(bytes);
    try std.testing.expect(std.mem.count(u8, bytes, "src/a.zig") == 1);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "query=\"worker \\\"events\\\"\\nnext\"") != null);
    try std.testing.expect(bytes.len <= request.max_bytes);
}
