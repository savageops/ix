const std = @import("std");
const cli = @import("args.zig");
const expr = @import("../core/expr.zig");
const corpus = @import("../core/corpus.zig");
const inspect = @import("../core/inspect.zig");
const search = @import("../core/search.zig");

pub fn writeHelp(writer: anytype, topic: cli.HelpTopic) !void {
    return switch (topic) {
        .top => writeTopHelp(writer),
        .search => writeSearchHelp(writer, "Hit records plus terminal result state", "search"),
        .matches => writeSearchHelp(writer, "Hit records only, same search engine", "matches"),
        .inspect => writeInspectHelp(writer),
        .explain => writeExplainHelp(writer),
    };
}

fn writeTopHelp(writer: anytype) !void {
    try writer.writeAll(
        \\IX v2 intelligent expression toolkit
        \\
        \\Usage: ix.exe <COMMAND>
        \\
        \\Commands:
        \\  search   Hit records plus terminal result state
        \\  matches  Hit records only, same search engine
        \\  inspect  Read-only file windows and match context
        \\  explain  Expression plan JSON
        \\  help     Print this message or the help of the given subcommand(s)
        \\
        \\Options:
        \\  -h, --help  Print help
        \\
        \\SCHEMA
        \\  ix search EXPR is the canonical IX command surface
        \\  bare text in ix search is a literal substring, so a|b means the bytes "a|b"
        \\  regex syntax requires re:pattern; literal alternation uses lit:a || lit:b
        \\  expr: lit:text | re:pattern | prefix:x | suffix:x | A && B | A || B
        \\COMPAT TRANSLATOR
        \\  top-level ix PATTERN [PATH]... accepts a narrow rg-shaped subset for agents
        \\  supported: PATTERN, -e PATTERN, repeated -e, -F, -i, -j, -n, --json, --hidden
        \\  accepted input lowers into canonical IX search; unsupported flags fail guided
        \\  raw regex patterns containing && or || are ambiguous and rejected
        \\  use ix search <expr> [PATH]... for native IX boolean expressions
        \\AGENT OUTPUT
        \\  search prints one ix.result.v1 JSON sentinel unless --json is used
        \\  zero-match search is status:"ok" with matches:0, not an error
        \\  matches prints hit records only, no terminal result sentinel
        \\  inspect grouped output prints ix.inspect.* sentinels and ix.next.v1 hints
        \\  inspect without file bounds uses a bounded first window
        \\SNIPS
        \\  ix error src
        \\  ix -e timeout -e error src
        \\  ix -F -i 'session timeout' logs
        \\  ix search 'lit:fn' crates --json
        \\  ix search 're:TODO|FIXME' .
        \\  ix search 'lit:TODO || lit:FIXME' .
        \\  ix matches 're:TODO|FIXME' .
        \\  ix inspect src/main.rs
        \\  ix inspect src/main.rs --range 40:80
        \\  ix inspect --expr 'lit:SearchConfig' crates --context 2 --json
        \\  ix explain 'lit:breach && lit:auth'
        \\
    );
}

fn writeSearchHelp(writer: anytype, summary: []const u8, command: []const u8) !void {
    try writer.print(
        \\{s}
        \\
        \\Usage: ix.exe {s} [OPTIONS] <EXPR> [PATH]...
        \\
        \\Arguments:
        \\  <EXPR>     IX expression; bare text is literal, regex requires re:pattern
        \\  [PATH]...  Files or directories to scan [default: .]
        \\
        \\Options:
        \\      --hidden                     
        \\      --follow-symlinks            
        \\      --json                       
        \\      --stats-only                 
        \\      --max-hits <MAX_HITS>        
        \\  -t, --threads <THREADS>          
        \\      --emit-report <EMIT_REPORT>  
        \\  -h, --help                       Print help
        \\
        \\EXPRESSION CONTRACT
        \\  ix search EXPR and ix matches EXPR use the canonical native IX expression surface
        \\  bare text is a literal substring: ix search 'a|b' searches for the bytes a|b
        \\  regex alternation requires re:pattern: ix search 're:a|b' .
        \\  literal alternation uses ||: ix search 'lit:a || lit:b' .
        \\  top-level ix PATTERN [PATH]... is an rg-shaped translator into this surface
        \\  translator regex patterns containing && or || are rejected as ambiguous
        \\AGENT OUTPUT
        \\  ix search emits hit records followed by one ix.result.v1 JSON sentinel
        \\  zero-match search is status:"ok" with matches:0, not an error
        \\  ix matches emits hit records only, no terminal result sentinel
        \\  --json emits the structured SearchReport contract
        \\
    , .{ summary, command });
}

fn writeInspectHelp(writer: anytype) !void {
    try writer.writeAll(
        \\Read-only file windows and match context
        \\
        \\Usage: ix.exe inspect [OPTIONS] [PATH]...
        \\
        \\Arguments:
        \\  [PATH]...  Files or search roots
        \\
        \\Options:
        \\      --total-count <TOTAL_COUNT>
        \\          Emit first N lines
        \\      --skip <SKIP>
        \\          Skip N lines before emitting
        \\      --limit <LIMIT>
        \\          Emit at most N lines
        \\      --start-line <START_LINE>
        \\          Inclusive 1-based start line
        \\      --end-line <END_LINE>
        \\          Inclusive 1-based end line
        \\      --range <RANGE>
        \\          Inclusive START:END line range
        \\      --all
        \\          Allow explicit full/tail file output beyond the default window
        \\      --json
        \\          Emit JSON
        \\      --format <FORMAT>
        \\          Output format: grouped, records, or json [default: grouped] [possible values: grouped, records, json]
        \\      --expr <EXPR>
        \\          IX expression for match-context mode
        \\  -C, --context <CONTEXT>
        \\          Lines before and after each match
        \\  -B, --before-context <BEFORE_CONTEXT>
        \\          Lines before each match
        \\  -A, --after-context <AFTER_CONTEXT>
        \\          Lines after each match
        \\      --hidden
        \\          
        \\      --follow-symlinks
        \\          
        \\  -t, --threads <THREADS>
        \\          
        \\      --max-hits <MAX_HITS>
        \\          
        \\  -h, --help
        \\          Print help
        \\
        \\CONTRACT
        \\  ix inspect is read-only: no mutation, replacement, shell delegation, or sed delegation
        \\  file-window mode reads bounded UTF-8 line windows from explicit PATH arguments
        \\  omitted file-window bounds default to a 240-line first window; eof=true means whole small file
        \\  match-context mode uses --expr and the same search engine as ix search
        \\AGENT OUTPUT
        \\  grouped output emits ix.inspect.* sentinels with request/eof metadata and ix.next.v1 argv hints
        \\  --format records preserves path:line:text output for pipe consumers
        \\  --json / --format json emits the structured report contract
        \\CONTINUATION
        \\  limit-shaped reads continue with --start-line next --limit N
        \\  range-shaped reads continue with --range next:next+span-1
        \\  eof=true suppresses continuation and carries total_lines when the file horizon is known
        \\SNIPS
        \\  ix inspect src/main.rs
        \\  ix inspect src/main.rs --total-count 40
        \\  ix inspect src/main.rs --skip 120 --limit 30
        \\  ix inspect src/main.rs --range 40:80
        \\  ix inspect --expr 'lit:SearchConfig' crates --context 2 --json
        \\
    );
}

fn writeExplainHelp(writer: anytype) !void {
    try writer.writeAll(
        \\Expression plan JSON
        \\
        \\Usage: ix.exe explain <EXPR>
        \\
        \\Arguments:
        \\  <EXPR>  Expression to parse into an IX plan
        \\
        \\Options:
        \\  -h, --help  Print help
        \\
        \\EXPRESSION CONTRACT
        \\  ix explain uses the same native IX expression parser as ix search and ix matches
        \\  bare text is literal; regex requires re:pattern; boolean composition uses && and ||
        \\  output is the structured ExpressionPlan JSON used to inspect lowering before execution
        \\SNIPS
        \\  ix explain 'lit:timeout'
        \\  ix explain 're:TODO|FIXME'
        \\  ix explain 'lit:error && re:\btimeout\b'
        \\
    );
}

pub fn writeError(writer: anytype, code: []const u8, message: []const u8) !void {
    try writer.print("-- ix.error.v1 {{\"code\":\"{s}\",\"message\":\"{s}\"}} --\n", .{ code, message });
}

pub fn writeCompatUnsupportedFlag(writer: anytype, flag: []const u8) !void {
    try writer.print(
        "-- ix.error.v1 {{\"cmd\":\"ix\",\"code\":\"command_failed\",\"hint\":null,\"message\":\"rg-shaped compatibility translator does not support `{s}`. Supported subset: `ix PATTERN [PATH]...`, `-e/--regexp`, `-F/--fixed-strings`, `-i/--ignore-case`, `-j/--threads`, `-n/--line-number`, `--json`, and `--hidden`. Use canonical `ix search <expr> [PATH]...` for native IX syntax.\",\"severity\":\"error\",\"status\":\"error\"}} --\n",
        .{flag},
    );
}

pub fn writeExplain(writer: anytype, plan: expr.ExpressionPlan) !void {
    const proof = corpus.compileProofProgram(plan);
    try writer.writeAll("{\"source\":");
    try writeJsonString(writer, plan.source);
    try writer.print(",\"mode\":\"{s}\",\"predicates\":[", .{plan.modeText()});
    for (plan.predicates[0..plan.predicate_count], 0..) |predicate, index| {
        if (index > 0) try writer.writeAll(",");
        try writer.print("{{\"type\":\"{s}\",\"value\":", .{predicate.kindText()});
        try writeJsonString(writer, predicate.value);
        try writer.writeAll("}");
    }
    try writer.writeAll("],\"proof_program\":{\"query_class\":");
    try writeJsonString(writer, proof.query_class);
    try writer.writeAll(",\"mandatory_evidence\":[");
    for (proof.terms[0..proof.term_count], 0..) |term, index| {
        if (index > 0) try writer.writeAll(",");
        const bytes = corpus.trigramBytes(term.key);
        try writeJsonString(writer, bytes[0..]);
    }
    try writer.writeAll("],\"posting_plan\":[");
    for (proof.terms[0..proof.term_count], 0..) |term, index| {
        if (index > 0) try writer.writeAll(",");
        const bytes = corpus.trigramBytes(term.key);
        try writer.writeAll("{\"key\":");
        try writeJsonString(writer, bytes[0..]);
        try writer.print(",\"source_index\":{},\"cardinality\":null,\"repr\":\"{s}\"}}", .{ term.source_index, term.repr.text() });
    }
    try writer.writeAll("],\"candidate_files_before\":null,\"candidate_files_after\":null,\"verifier\":");
    try writeJsonString(writer, proof.verifier);
    try writer.writeAll(",\"fallback\":");
    if (proof.fallback) |fallback| {
        try writeJsonString(writer, fallback);
    } else {
        try writer.writeAll("null");
    }
    try writer.writeAll("}}\n");
}

pub fn writeSearchReport(writer: anytype, report: search.SearchReport) !void {
    try writer.print(
        "-- ix.result.v1 {{\"bytes\":{},\"cmd\":\"search\",\"dedupe\":{{\"discovered_duplicate_paths\":{},\"overlap_pruned_roots\":{}}},\"expr\":",
        .{ report.bytes_scanned, report.discovered_duplicate_paths, report.overlap_pruned_roots },
    );
    try writeJsonString(writer, report.expression);
    try writer.print(
        ",\"files\":{{\"discovered\":{},\"scanned\":{},\"skipped\":{}}},\"matches\":{},\"ms\":{{\"aggregate\":{d},\"discover\":{d},\"scan\":{d},\"total\":{d}}},\"slowest\":{{\"bytes\":{},\"ms\":{d},\"path\":",
        .{ report.files_discovered, report.files_scanned, report.files_skipped, report.matches_found, report.aggregate_ms, report.discover_ms, report.scan_ms, report.total_ms, report.slowest_bytes, report.slowest_ms },
    );
    try writeJsonString(writer, report.slowest_path);
    try writer.writeAll("},\"status\":\"ok\"} --\n");
}

pub fn writeSearchJsonReport(writer: anytype, report: search.SearchReport) !void {
    try writer.writeAll("{\"expression\":");
    try writeJsonString(writer, report.expression);
    try writer.writeAll(",\"hits\":[");
    for (report.hits[0..report.hit_count], 0..) |hit, index| {
        if (index > 0) try writer.writeAll(",");
        try writer.writeAll("{\"path\":");
        try writeJsonString(writer, hit.path);
        try writer.print(",\"line\":{},\"column\":{},\"preview\":", .{ hit.line, hit.column });
        try writeJsonString(writer, hit.preview);
        try writer.writeAll("}");
    }
    try writer.print(
        "],\"stats\":{{\"input_roots\":{},\"effective_roots\":{},\"pruned_roots\":{},\"overlap_pruned_roots\":{},\"discovered_duplicate_paths\":{},\"acceleration_bailouts\":0,\"files_discovered\":{},\"files_scanned\":{},\"files_skipped\":{},\"matches_found\":{},\"bytes_scanned\":{},",
        .{ report.stats.input_roots, report.stats.effective_roots, report.stats.pruned_roots, report.stats.overlap_pruned_roots, report.stats.discovered_duplicate_paths, report.stats.files_discovered, report.stats.files_scanned, report.stats.files_skipped, report.stats.matches_found, report.stats.bytes_scanned },
    );
    try writer.print("\"linux_strategy\":{{\"selector_eligible\":{s},\"current_strategy\":\"{s}\",\"matcher_strategy_supported\":{s},\"effective_roots\":{},\"directory_roots\":{},\"root_entry_count\":{},\"files_discovered\":{},\"collect_hits\":{s},\"outer_parallel_shard_safe\":{s}}},", .{ boolText(report.stats.linux_strategy.selector_eligible), report.stats.linux_strategy.current_strategy, boolText(report.stats.linux_strategy.matcher_strategy_supported), report.stats.linux_strategy.effective_roots, report.stats.linux_strategy.directory_roots, report.stats.linux_strategy.root_entry_count, report.stats.linux_strategy.files_discovered, boolText(report.stats.linux_strategy.collect_hits), boolText(report.stats.linux_strategy.outer_parallel_shard_safe) });
    try writer.print("\"linux_dominant_file\":{{\"target_class\":\"{s}\",\"min_bytes\":{},\"targeted_files_scanned\":{},\"targeted_bytes_scanned\":{},\"targeted_slowest_files\":{},\"targeted_slowest_bytes\":{},\"eligible_files\":{},\"activated_files\":{},\"bailout_files\":{},\"max_shard_threads\":{},\"max_range_count\":{},\"max_chunk_bytes\":{}}},", .{ report.stats.linux_dominant_file.target_class, report.stats.linux_dominant_file.min_bytes, report.stats.linux_dominant_file.targeted_files_scanned, report.stats.linux_dominant_file.targeted_bytes_scanned, report.stats.linux_dominant_file.targeted_slowest_files, report.stats.linux_dominant_file.targeted_slowest_bytes, report.stats.linux_dominant_file.eligible_files, report.stats.linux_dominant_file.activated_files, report.stats.linux_dominant_file.bailout_files, report.stats.linux_dominant_file.max_shard_threads, report.stats.linux_dominant_file.max_range_count, report.stats.linux_dominant_file.max_chunk_bytes });
    try writer.writeAll("\"regex_decomposition\":{\"eligible_files\":0,\"counted_files\":0,\"bailout_files\":0,\"candidate_lines_checked\":0,\"duplicate_candidate_hits_skipped\":0,\"candidate_lines_matched\":0},");
    try writer.writeAll("\"unicode_casefold_prefilter\":{\"full_scan_calls\":0,\"range_scan_calls\":0,\"candidate_prefix_hits\":0,\"candidate_windows_verified\":0,\"confirmed_matches\":0,\"rejected_candidates\":0,\"candidate_gap_bytes_total\":0,\"candidate_gap_samples\":0,\"max_prefix_variant_count\":0,\"max_prefix_len\":0,\"max_match_len\":0},");
    try writer.writeAll("\"fast_count_density\":{\"literal_reject_fast_calls\":0,\"literal_reject_fast_bytes\":0,\"literal_range_calls\":0,\"literal_range_bytes\":0,\"literal_matches\":0,\"alternate_reject_fast_calls\":0,\"alternate_reject_fast_bytes\":0,\"alternate_full_scan_calls\":0,\"alternate_full_scan_bytes\":0,\"alternate_full_scan_matches\":0,\"alternate_range_calls\":0,\"alternate_range_bytes\":0,\"alternate_matches\":0,\"shard_merge_calls\":0,\"shard_merge_ranges\":0,\"shard_merge_matches\":0},");
    try writer.writeAll("\"byte_shard_kernel\":{\"enabled\":false,\"files_profiled\":0,\"range_calls\":0,\"logical_range_bytes\":0,\"widened_range_bytes\":0,\"overlap_bytes\":0,\"range_elapsed_ns_total\":0,\"max_range_elapsed_ns\":0,\"reduce_elapsed_ns_total\":0,\"max_reduce_elapsed_ns\":0,\"matches\":0},");
    try writer.print("\"trigram_acceleration\":{{\"eligible\":{s},\"mode\":\"{s}\",\"mandatory_groups\":{},\"mandatory_trigrams\":{},\"candidate_files_checked\":{},\"pruned_files\":{},\"verified_files\":{},\"ineligible_files\":{}}},", .{ boolText(report.stats.trigram_acceleration.eligible), report.stats.trigram_acceleration.mode, report.stats.trigram_acceleration.mandatory_groups, report.stats.trigram_acceleration.mandatory_trigrams, report.stats.trigram_acceleration.candidate_files_checked, report.stats.trigram_acceleration.pruned_files, report.stats.trigram_acceleration.verified_files, report.stats.trigram_acceleration.ineligible_files });
    try writer.print("\"timings\":{{\"discover_ms\":{d},\"scan_ms\":{d},\"aggregate_ms\":{d},\"total_ms\":{d},\"scan_work_ms_total\":{d},\"aggregate_merge_ms\":{d},\"aggregate_finalize_ms\":{d}}},", .{ report.stats.timings.discover_ms, report.stats.timings.scan_ms, report.stats.timings.aggregate_ms, report.stats.timings.total_ms, report.stats.timings.scan_work_ms_total, report.stats.timings.aggregate_merge_ms, report.stats.timings.aggregate_finalize_ms });
    try writer.print("\"concurrency\":{{\"available_threads\":{},\"outer_scan_threads\":{},\"execution_mode\":\"{s}\",\"sharding_enabled\":{s},\"sharded_files\":{},\"max_shard_threads\":{},\"max_shard_ranges\":{},\"max_shard_chunk_bytes\":{}}},", .{ report.stats.concurrency.available_threads, report.stats.concurrency.outer_scan_threads, report.stats.concurrency.execution_mode, boolText(report.stats.concurrency.sharding_enabled), report.stats.concurrency.sharded_files, report.stats.concurrency.max_shard_threads, report.stats.concurrency.max_shard_ranges, report.stats.concurrency.max_shard_chunk_bytes });
    try writer.writeAll("\"slowest_files\":[");
    if (report.stats.slowest_file_count > 0) {
        try writer.writeAll("{\"path\":");
        const slowest = report.stats.slowest_files[0];
        try writeJsonString(writer, slowest.path);
        try writer.print(",\"duration_ms\":{d},\"bytes\":{},\"linux_dominant_target\":{s}}}", .{ slowest.duration_ms, slowest.bytes, boolText(slowest.linux_dominant_target) });
    }
    try writer.writeAll("]}}\n");
}

pub fn writeSearchHits(writer: anytype, report: search.SearchReport) !void {
    for (report.hits[0..report.hit_count]) |hit| {
        try writer.print("{s}:{}:{}:{s}\n", .{ hit.path, hit.line, hit.column, hit.preview });
    }
}

pub fn writeInspectWindow(writer: anytype, window: inspect.InspectWindow) !void {
    try writer.print(
        "== ix.inspect.file path=\"{s}\" request={s} range={}:{} emitted={} eof={s}",
        .{ window.path, window.request_label, window.start_line, window.end_line, window.line_count, boolText(window.eof) },
    );
    if (window.total_lines) |total_lines| try writer.print(" total_lines={}", .{total_lines});
    try writer.writeAll(" ==\n");
    for (window.lines[0..window.line_count]) |line| {
        try writer.print("{} | {s}\n", .{ line.number, line.text });
    }
    if (window.has_more) {
        if (window.requested_end_line) |requested_end| {
            const span = requested_end - window.start_line + 1;
            if (window.line_count >= span) {
                try writer.print("-- ix.next.v1 {{\"argv\":[\"ix\",\"inspect\",\"{s}\",\"--range\",\"{}:{}\"],\"cmd\":\"inspect\"}} --\n", .{ window.path, window.end_line + 1, window.end_line + span });
            }
        } else if (window.limit) |limit| {
            if (limit > 0 and window.line_count >= limit) {
                try writer.print("-- ix.next.v1 {{\"argv\":[\"ix\",\"inspect\",\"{s}\",\"--start-line\",\"{}\",\"--limit\",\"{}\"],\"cmd\":\"inspect\"}} --\n", .{ window.path, window.end_line + 1, limit });
            }
        }
    }
}

pub fn writeInspectWindowJsonReports(writer: anytype, windows: []const inspect.InspectWindow) !void {
    try writer.writeAll("{\"reports\":[");
    for (windows, 0..) |window, index| {
        if (index > 0) try writer.writeAll(",");
        try writeInspectWindowJsonObject(writer, window);
    }
    try writer.writeAll("]}\n");
}

fn writeInspectWindowJsonObject(writer: anytype, window: inspect.InspectWindow) !void {
    try writer.print("{{\"eof\":{s},\"lines\":[", .{boolText(window.eof)});
    for (window.lines[0..window.line_count], 0..) |line, index| {
        if (index > 0) try writer.writeAll(",");
        try writer.print("{{\"line\":{},\"text\":", .{line.number});
        try writeJsonString(writer, line.text);
        try writer.writeAll("}");
    }
    try writer.writeAll("],\"path\":");
    try writeJsonString(writer, window.path);
    try writer.writeAll(",\"requested\":{\"allow_full\":");
    try writer.writeAll(boolText(window.allow_full));
    try writer.writeAll(",\"end_line\":");
    try writeOptionalUsize(writer, window.requested_end_line);
    try writer.print(",\"limit\":", .{});
    try writeOptionalUsize(writer, window.limit);
    try writer.print(",\"skip\":{},\"start_line\":{}}},\"total_emitted_lines\":{},\"total_lines\":", .{ window.skip, window.start_line, window.line_count });
    try writeOptionalUsize(writer, window.total_lines);
    try writer.writeAll("}");
}

pub fn writeInspectContextJsonReports(writer: anytype, expression: []const u8, reports: []const inspect.ContextReport) !void {
    try writer.writeAll("{\"expression\":");
    try writeJsonString(writer, expression);
    try writer.writeAll(",\"reports\":[");
    for (reports, 0..) |report, index| {
        if (index > 0) try writer.writeAll(",");
        try writeInspectContextJsonObject(writer, report);
    }
    try writer.writeAll("]}\n");
}

fn writeInspectContextJsonObject(writer: anytype, report: inspect.ContextReport) !void {
    try writer.writeAll("{\"lines\":[");
    for (report.lines[0..report.line_count], 0..) |line, index| {
        if (index > 0) try writer.writeAll(",");
        try writer.print("{{\"line\":{},\"role\":\"{s}\",\"text\":", .{ line.number, line.role });
        try writeJsonString(writer, line.text);
        try writer.writeAll("}");
    }
    try writer.writeAll("],\"path\":");
    try writeJsonString(writer, report.path);
    try writer.writeAll("}");
}

fn writeOptionalUsize(writer: anytype, value: ?usize) !void {
    if (value) |number| {
        try writer.print("{}", .{number});
    } else {
        try writer.writeAll("null");
    }
}

pub fn writeSearchJsonReportToFile(io: std.Io, path: []const u8, report: search.SearchReport) !void {
    var file = try std.Io.Dir.cwd().createFile(io, path, .{ .truncate = true });
    defer file.close(io);
    var buffer: [8192]u8 = undefined;
    var writer = file.writer(io, &buffer);
    try writeSearchJsonReport(&writer.interface, report);
    try writer.interface.flush();
}

pub fn writeInspectWindowJson(writer: anytype, window: inspect.InspectWindow) !void {
    try writer.writeAll("{\"reports\":[");
    try writeInspectWindowJsonObject(writer, window);
    try writer.writeAll("]}\n");
}

pub fn writeInspectContextJson(writer: anytype, report: inspect.ContextReport) !void {
    try writer.writeAll("{\"expression\":");
    try writeJsonString(writer, report.expression);
    try writer.writeAll(",\"reports\":[");
    try writeInspectContextJsonObject(writer, report);
    try writer.writeAll("]}\n");
}

pub fn writeInspectWindowRecords(writer: anytype, window: inspect.InspectWindow) !void {
    for (window.lines[0..window.line_count]) |line| {
        try writer.print("{s}:{}:{s}\n", .{ window.path, line.number, line.text });
    }
}

pub fn writeInspectContextRecords(writer: anytype, report: inspect.ContextReport) !void {
    for (report.lines[0..report.line_count]) |line| {
        try writer.print("{s}:{}:{s}:{s}\n", .{ report.path, line.number, line.role, line.text });
    }
}

pub fn writeInspectContext(writer: anytype, report: inspect.ContextReport) !void {
    try writer.print("== ix.inspect.context path=\"{s}\" emitted={} ==\n", .{ report.path, report.line_count });
    for (report.lines[0..report.line_count]) |line| {
        try writer.print("{} {s:<7} | {s}\n", .{ line.number, line.role, line.text });
    }
}

fn boolText(value: bool) []const u8 {
    return if (value) "true" else "false";
}

fn writeJsonString(writer: anytype, value: []const u8) !void {
    try writer.writeByte('"');
    for (value) |byte| {
        switch (byte) {
            '\\' => try writer.writeAll("\\\\"),
            '"' => try writer.writeAll("\\\""),
            '\n' => try writer.writeAll("\\n"),
            '\r' => try writer.writeAll("\\r"),
            '\t' => try writer.writeAll("\\t"),
            else => try writer.writeByte(byte),
        }
    }
    try writer.writeByte('"');
}

test "error sentinel is versioned" {
    var buffer: [128]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    try writeError(&writer, "invalid_arguments", "MissingCommand");
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "ix.error.v1") != null);
}
