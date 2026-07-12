const std = @import("std");
const cli = @import("args.zig");
const expr = @import("../core/expr.zig");
const corpus = @import("../core/corpus.zig");
const inspect = @import("../core/inspect.zig");
const search = @import("../core/search.zig");
const core_stats = @import("../core/stats.zig");

pub fn writeHelp(writer: anytype, topic: cli.HelpTopic) !void {
    return switch (topic) {
        .top => writeTopHelp(writer),
        .search => writeSearchHelp(writer, "Hit records plus terminal result state", "search"),
        .matches => writeSearchHelp(writer, "Hit records only, same search engine", "matches"),
        .inspect => writeInspectHelp(writer),
        .explain => writeExplainHelp(writer),
        .process => writeProcessHelp(writer),
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
        \\  process  IX-owned state-dir process inspection and cleanup
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
        \\  supported: PATTERN, -e PATTERN, repeated -e, -F, -i, -j, -n, --json, --hidden, --no-ignore, -u, --ignore-file
        \\  accepted input lowers into canonical IX search; unsupported flags fail guided
        \\  raw regex patterns containing && or || are ambiguous and rejected
        \\  use ix search <expr> [PATH]... for native IX boolean expressions
        \\AGENT OUTPUT
        \\  search prints one ix.result.v1 JSON sentinel unless --json is used
        \\  zero-match search is status:"ok" with matches:0, not an error
        \\  matches prints hit records only, no terminal result sentinel
        \\  inspect grouped output prints ix.inspect.* sentinels and ix.next.v1 hints
        \\  inspect without file bounds uses a bounded first window
        \\  agent shorthand: -n N means line numbers plus max N hits
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
        \\      --hidden                     Include hidden files and directories
        \\      --no-ignore                  Disable explicit ignore-file admission
        \\  -u, --unrestricted              Include hidden and ignored paths
        \\      --ignore-file <PATH>         Add an explicit ignore source
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
        \\  agent shorthand: -n N means line numbers plus max N hits
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

fn writeProcessHelp(writer: anytype) !void {
    try writer.writeAll(
        \\IX-owned state-dir process inspection and cleanup
        \\
        \\Usage: ix.exe process [status|cleanup] [OPTIONS]
        \\
        \\Options:
        \\      --json     Emit structured JSON
        \\      --dry-run  Show cleanup actions without deleting stale markers
        \\  -h, --help     Print help
        \\
        \\CONTRACT
        \\  scans IX_STATE_DIR ownership surfaces under index/roots/*
        \\  classifies index.live and indexd.heartbeat markers as live, stale, or malformed
        \\  emits memory-limit warnings for live Windows workers above IX_INDEXD_MEMORY_LIMIT_MB
        \\  cleanup deletes stale or malformed IX-owned markers only
        \\
    );
}

pub fn writeError(writer: anytype, code: []const u8, message: []const u8) !void {
    try writer.print("-- ix.error.v1 {{\"code\":\"{s}\",\"message\":\"{s}\"}} --\n", .{ code, message });
}

pub fn writeCompatUnsupportedFlag(writer: anytype, flag: []const u8) !void {
    try writer.print(
        "-- ix.error.v1 {{\"cmd\":\"ix\",\"code\":\"command_failed\",\"hint\":null,\"message\":\"rg-shaped compatibility translator does not support `{s}`. Supported subset: `ix PATTERN [PATH]...`, `-e/--regexp`, `-F/--fixed-strings`, `-i/--ignore-case`, `-j/--threads`, `-n/--line-number`, `--json`, `--hidden`, `--no-ignore`, `-u/--unrestricted`, and `--ignore-file`. Use canonical `ix search <expr> [PATH]...` for native IX syntax.\",\"severity\":\"error\",\"status\":\"error\"}} --\n",
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
        ",\"access_errors\":{{\"total\":{},\"access_denied\":{}}},\"files\":{{\"discovered\":{},\"scanned\":{},\"skipped\":{}}},\"matches\":{},\"ms\":{{\"aggregate\":{d},\"discover\":{d},\"scan\":{d},\"total\":{d}}},\"slowest\":{{\"bytes\":{},\"ms\":{d},\"path\":",
        .{ report.stats.access_errors.total, report.stats.access_errors.access_denied, report.files_discovered, report.files_scanned, report.files_skipped, report.matches_found, report.aggregate_ms, report.discover_ms, report.scan_ms, report.total_ms, report.slowest_bytes, report.slowest_ms },
    );
    try writeJsonString(writer, report.slowest_path);
    try writer.writeAll("},\"hits\":[");
    for (report.hits[0..report.hit_count], 0..) |hit, index| {
        if (index > 0) try writer.writeAll(",");
        try writeSearchHitJson(writer, report, hit);
    }
    try writer.print("],\"status\":\"{s}\"}} --\n", .{searchStatus(report)});
}

pub fn writeSearchJsonReport(writer: anytype, report: search.SearchReport) !void {
    try writer.writeAll("{\"expression\":");
    try writeJsonString(writer, report.expression);
    try writer.print(",\"status\":\"{s}\"", .{searchStatus(report)});
    try writer.writeAll(",\"cwd\":");
    try writeJsonString(writer, report.cwd);
    try writer.writeAll(",\"hits\":[");
    for (report.hits[0..report.hit_count], 0..) |hit, index| {
        if (index > 0) try writer.writeAll(",");
        try writeSearchHitJson(writer, report, hit);
    }
    try writer.print(
        "],\"stats\":{{\"input_roots\":{},\"effective_roots\":{},\"pruned_roots\":{},\"overlap_pruned_roots\":{},\"discovered_duplicate_paths\":{},\"acceleration_bailouts\":{},\"files_discovered\":{},\"files_scanned\":{},\"files_skipped\":{},\"matches_found\":{},\"bytes_scanned\":{},",
        .{ report.stats.input_roots, report.stats.effective_roots, report.stats.pruned_roots, report.stats.overlap_pruned_roots, report.stats.discovered_duplicate_paths, report.stats.acceleration_bailouts, report.stats.files_discovered, report.stats.files_scanned, report.stats.files_skipped, report.stats.matches_found, report.stats.bytes_scanned },
    );
    try writer.print("\"linux_strategy\":{{\"selector_eligible\":{s},\"current_strategy\":\"{s}\",\"matcher_strategy_supported\":{s},\"effective_roots\":{},\"directory_roots\":{},\"root_entry_count\":{},\"files_discovered\":{},\"collect_hits\":{s},\"outer_parallel_shard_safe\":{s}}},", .{ boolText(report.stats.linux_strategy.selector_eligible), report.stats.linux_strategy.current_strategy, boolText(report.stats.linux_strategy.matcher_strategy_supported), report.stats.linux_strategy.effective_roots, report.stats.linux_strategy.directory_roots, report.stats.linux_strategy.root_entry_count, report.stats.linux_strategy.files_discovered, boolText(report.stats.linux_strategy.collect_hits), boolText(report.stats.linux_strategy.outer_parallel_shard_safe) });
    try writer.print("\"linux_dominant_file\":{{\"target_class\":\"{s}\",\"min_bytes\":{},\"targeted_files_scanned\":{},\"targeted_bytes_scanned\":{},\"targeted_slowest_files\":{},\"targeted_slowest_bytes\":{},\"eligible_files\":{},\"activated_files\":{},\"bailout_files\":{},\"max_shard_threads\":{},\"max_range_count\":{},\"max_chunk_bytes\":{}}},", .{ report.stats.linux_dominant_file.target_class, report.stats.linux_dominant_file.min_bytes, report.stats.linux_dominant_file.targeted_files_scanned, report.stats.linux_dominant_file.targeted_bytes_scanned, report.stats.linux_dominant_file.targeted_slowest_files, report.stats.linux_dominant_file.targeted_slowest_bytes, report.stats.linux_dominant_file.eligible_files, report.stats.linux_dominant_file.activated_files, report.stats.linux_dominant_file.bailout_files, report.stats.linux_dominant_file.max_shard_threads, report.stats.linux_dominant_file.max_range_count, report.stats.linux_dominant_file.max_chunk_bytes });
    try writer.print("\"regex_decomposition\":{{\"eligible_files\":{},\"counted_files\":{},\"bailout_files\":{},\"candidate_lines_checked\":{},\"duplicate_candidate_hits_skipped\":{},\"candidate_lines_matched\":{}}},", .{ report.stats.regex_decomposition.eligible_files, report.stats.regex_decomposition.counted_files, report.stats.regex_decomposition.bailout_files, report.stats.regex_decomposition.candidate_lines_checked, report.stats.regex_decomposition.duplicate_candidate_hits_skipped, report.stats.regex_decomposition.candidate_lines_matched });
    try writer.writeAll("\"unicode_casefold_prefilter\":{\"full_scan_calls\":0,\"range_scan_calls\":0,\"candidate_prefix_hits\":0,\"candidate_windows_verified\":0,\"confirmed_matches\":0,\"rejected_candidates\":0,\"candidate_gap_bytes_total\":0,\"candidate_gap_samples\":0,\"max_prefix_variant_count\":0,\"max_prefix_len\":0,\"max_match_len\":0},");
    try writeFastCountDensityJson(writer, report.stats.fast_count_density);
    try writer.writeAll(",");
    try writer.print("\"byte_shard_kernel\":{{\"enabled\":{s},\"strategy\":\"{s}\",\"files_profiled\":{},\"range_calls\":{},\"line_aligned_ranges\":{},\"logical_range_bytes\":{},\"widened_range_bytes\":{},\"overlap_bytes\":{},\"boundary_verified_candidates\":{},\"boundary_rejected_candidates\":{},\"range_elapsed_ns_total\":{},\"max_range_elapsed_ns\":{},\"reduce_elapsed_ns_total\":{},\"max_reduce_elapsed_ns\":{},\"matches\":{}}},", .{ boolText(report.stats.byte_shard_kernel.enabled), report.stats.byte_shard_kernel.strategy, report.stats.byte_shard_kernel.files_profiled, report.stats.byte_shard_kernel.range_calls, report.stats.byte_shard_kernel.line_aligned_ranges, report.stats.byte_shard_kernel.logical_range_bytes, report.stats.byte_shard_kernel.widened_range_bytes, report.stats.byte_shard_kernel.overlap_bytes, report.stats.byte_shard_kernel.boundary_verified_candidates, report.stats.byte_shard_kernel.boundary_rejected_candidates, report.stats.byte_shard_kernel.range_elapsed_ns_total, report.stats.byte_shard_kernel.max_range_elapsed_ns, report.stats.byte_shard_kernel.reduce_elapsed_ns_total, report.stats.byte_shard_kernel.max_reduce_elapsed_ns, report.stats.byte_shard_kernel.matches });
    try writer.print("\"trigram_acceleration\":{{\"eligible\":{s},\"mode\":\"{s}\",\"mandatory_groups\":{},\"mandatory_trigrams\":{},\"candidate_files_checked\":{},\"pruned_files\":{},\"verified_files\":{},\"ineligible_files\":{}}},", .{ boolText(report.stats.trigram_acceleration.eligible), report.stats.trigram_acceleration.mode, report.stats.trigram_acceleration.mandatory_groups, report.stats.trigram_acceleration.mandatory_trigrams, report.stats.trigram_acceleration.candidate_files_checked, report.stats.trigram_acceleration.pruned_files, report.stats.trigram_acceleration.verified_files, report.stats.trigram_acceleration.ineligible_files });
    try writeCatalogIndexJson(writer, report.stats.catalog_index);
    try writer.writeAll(",");
    try writePostingsIndexJson(writer, report.stats.postings_index);
    try writer.writeAll(",");
    try writeGenerationRefreshJson(writer, report.stats.generation_refresh);
    try writer.writeAll(",");
    try writeAccessErrorsJson(writer, report.stats.access_errors);
    try writer.writeAll(",");
    try writeAdmissionJson(writer, report.stats.admission);
    try writer.writeAll(",");
    try writer.print("\"timings\":{{\"discover_ms\":{d},\"scan_ms\":{d},\"aggregate_ms\":{d},\"total_ms\":{d},\"scan_work_ms_total\":{d},\"scan_open_ms_total\":{d},\"scan_file_ms_total\":{d},\"scan_file_mmap_ms_total\":{d},\"scan_file_buffered_ms_total\":{d},\"aggregate_merge_ms\":{d},\"aggregate_finalize_ms\":{d}}},", .{ report.stats.timings.discover_ms, report.stats.timings.scan_ms, report.stats.timings.aggregate_ms, report.stats.timings.total_ms, report.stats.timings.scan_work_ms_total, report.stats.timings.scan_open_ms_total, report.stats.timings.scan_file_ms_total, report.stats.timings.scan_file_mmap_ms_total, report.stats.timings.scan_file_buffered_ms_total, report.stats.timings.aggregate_merge_ms, report.stats.timings.aggregate_finalize_ms });
    try writer.print("\"process_memory\":{{\"available\":{s},\"current_resident_bytes\":{},\"peak_resident_bytes\":{}}},", .{ boolText(report.stats.process_memory.available), report.stats.process_memory.current_resident_bytes, report.stats.process_memory.peak_resident_bytes });
    try writer.print("\"concurrency\":{{\"available_threads\":{},\"outer_scan_threads\":{},\"execution_mode\":\"{s}\",\"resource_profile\":\"{s}\",\"scan_input_policy\":\"{s}\",\"sharding_enabled\":{s},\"sharded_files\":{},\"max_shard_threads\":{},\"max_shard_ranges\":{},\"max_shard_chunk_bytes\":{}}},", .{ report.stats.concurrency.available_threads, report.stats.concurrency.outer_scan_threads, report.stats.concurrency.execution_mode, report.stats.concurrency.resource_profile, report.stats.concurrency.scan_input_policy, boolText(report.stats.concurrency.sharding_enabled), report.stats.concurrency.sharded_files, report.stats.concurrency.max_shard_threads, report.stats.concurrency.max_shard_ranges, report.stats.concurrency.max_shard_chunk_bytes });
    try writer.writeAll("\"slowest_files\":[");
    for (report.stats.slowest_files[0..report.stats.slowest_file_count], 0..) |slowest, index| {
        if (index != 0) try writer.writeAll(",");
        try writer.writeAll("{\"path\":");
        try writeJsonString(writer, slowest.path);
        try writer.print(",\"duration_ms\":{d},\"bytes\":{},\"linux_dominant_target\":{s}}}", .{ slowest.duration_ms, slowest.bytes, boolText(slowest.linux_dominant_target) });
    }
    try writer.writeAll("]}}\n");
}

fn searchStatus(report: search.SearchReport) []const u8 {
    return if (report.stats.access_errors.total == 0) "ok" else "partial";
}

fn writeFastCountDensityJson(writer: anytype, stats: core_stats.FastCountDensityStats) !void {
    try writer.print("\"fast_count_density\":{{\"literal_reject_fast_calls\":{},\"literal_reject_fast_bytes\":{},\"literal_range_calls\":{},\"literal_range_bytes\":{},\"literal_matches\":{},\"alternate_reject_fast_calls\":{},\"alternate_reject_fast_bytes\":{},\"alternate_full_scan_calls\":{},\"alternate_full_scan_bytes\":{},\"alternate_full_scan_matches\":{},\"alternate_range_calls\":{},\"alternate_range_bytes\":{},\"alternate_pcre_range_calls\":{},\"alternate_pcre_range_bytes\":{},\"alternate_teddy_range_calls\":{},\"alternate_teddy_range_bytes\":{},\"alternate_compiled_range_calls\":{},\"alternate_compiled_range_bytes\":{},\"alternate_matches\":{},\"shard_merge_calls\":{},\"shard_merge_ranges\":{},\"shard_merge_matches\":{}}}", .{
        stats.literal_reject_fast_calls,
        stats.literal_reject_fast_bytes,
        stats.literal_range_calls,
        stats.literal_range_bytes,
        stats.literal_matches,
        stats.alternate_reject_fast_calls,
        stats.alternate_reject_fast_bytes,
        stats.alternate_full_scan_calls,
        stats.alternate_full_scan_bytes,
        stats.alternate_full_scan_matches,
        stats.alternate_range_calls,
        stats.alternate_range_bytes,
        stats.alternate_pcre_range_calls,
        stats.alternate_pcre_range_bytes,
        stats.alternate_teddy_range_calls,
        stats.alternate_teddy_range_bytes,
        stats.alternate_compiled_range_calls,
        stats.alternate_compiled_range_bytes,
        stats.alternate_matches,
        stats.shard_merge_calls,
        stats.shard_merge_ranges,
        stats.shard_merge_matches,
    });
}

fn writeAdmissionJson(writer: anytype, stats: core_stats.AdmissionStats) !void {
    try writer.print("\"admission\":{{\"enabled\":{s},\"ignore_files_loaded\":{},\"hidden_entries_skipped\":{},\"hidden_file_bytes\":{},\"ignored_entries_skipped\":{},\"ignored_file_bytes\":{},\"explicit_files_included\":{},\"protected_entries_skipped\":{},\"binary_entries_skipped\":{},\"binary_file_bytes\":{}}}", .{
        boolText(stats.enabled),
        stats.ignore_files_loaded,
        stats.hidden_entries_skipped,
        stats.hidden_file_bytes,
        stats.ignored_entries_skipped,
        stats.ignored_file_bytes,
        stats.explicit_files_included,
        stats.protected_entries_skipped,
        stats.binary_entries_skipped,
        stats.binary_file_bytes,
    });
}

fn writeAccessErrorsJson(writer: anytype, access_errors: core_stats.AccessErrorStats) !void {
    try writer.print("\"access_errors\":{{\"total\":{},\"access_denied\":{},\"discovery\":{},\"scan\":{},\"directory_open\":{},\"directory_iterate\":{},\"file_open\":{},\"file_read\":{},\"samples\":[", .{
        access_errors.total,
        access_errors.access_denied,
        access_errors.discovery,
        access_errors.scan,
        access_errors.directory_open,
        access_errors.directory_iterate,
        access_errors.file_open,
        access_errors.file_read,
    });
    for (access_errors.samples[0..access_errors.sample_count], 0..) |sample, index| {
        if (index > 0) try writer.writeAll(",");
        try writer.writeAll("{\"phase\":");
        try writeJsonString(writer, sample.phase);
        try writer.writeAll(",\"operation\":");
        try writeJsonString(writer, sample.operation);
        try writer.writeAll(",\"path\":");
        try writeJsonString(writer, sample.path);
        try writer.writeAll(",\"error\":");
        try writeJsonString(writer, sample.error_name);
        try writer.writeAll("}");
    }
    try writer.writeAll("]}");
}

fn writeCatalogIndexJson(writer: anytype, catalog_index: core_stats.CatalogIndexStats) !void {
    try writer.print("\"catalog_index\":{{\"enabled\":{s},\"available\":{s},\"generation\":", .{
        boolText(catalog_index.enabled),
        boolText(catalog_index.available),
    });
    if (catalog_index.generation) |generation| {
        try writer.print("{}", .{generation});
    } else {
        try writer.writeAll("null");
    }
    try writer.print(",\"path_count\":{},\"meta_count\":{},\"fallback_reason\":", .{
        catalog_index.path_count,
        catalog_index.meta_count,
    });
    try writeJsonString(writer, catalog_index.fallback_reason);
    try writer.writeAll("}");
}

fn writePostingsIndexJson(writer: anytype, postings_index: core_stats.PostingsIndexStats) !void {
    try writer.print("\"postings_index\":{{\"enabled\":{s},\"available\":{s},\"generation\":", .{
        boolText(postings_index.enabled),
        boolText(postings_index.available),
    });
    if (postings_index.generation) |generation| {
        try writer.print("{}", .{generation});
    } else {
        try writer.writeAll("null");
    }
    try writer.print(",\"trigram_count\":{},\"postings_count\":{},\"file_count\":{},\"candidate_files\":{},\"pruned_files\":{},\"verified_files\":{},\"block_proof_enabled\":{s},\"block_count\":{},\"block_prune_candidate_blocks\":{},\"block_prune_candidate_postings\":{},\"block_prune_candidate_compressed_bytes\":{},\"fallback_reason\":", .{
        postings_index.trigram_count,
        postings_index.postings_count,
        postings_index.file_count,
        postings_index.candidate_files,
        postings_index.pruned_files,
        postings_index.verified_files,
        boolText(postings_index.block_proof_enabled),
        postings_index.block_count,
        postings_index.block_prune_candidate_blocks,
        postings_index.block_prune_candidate_postings,
        postings_index.block_prune_candidate_compressed_bytes,
    });
    try writeJsonString(writer, postings_index.fallback_reason);
    try writer.writeAll(",\"index_created_ns\":");
    if (postings_index.index_created_ns) |created| {
        try writer.print("{}", .{created});
    } else {
        try writer.writeAll("null");
    }
    try writer.writeAll(",\"index_age_ms\":");
    if (postings_index.index_age_ms) |age| {
        try writer.print("{}", .{age});
    } else {
        try writer.writeAll("null");
    }
    try writer.writeAll("}");
}

fn writeGenerationRefreshJson(writer: anytype, generation_refresh: core_stats.GenerationRefreshStats) !void {
    try writer.print("\"generation_refresh\":{{\"enabled\":{s},\"available\":{s},\"epoch\":", .{
        boolText(generation_refresh.enabled),
        boolText(generation_refresh.available),
    });
    if (generation_refresh.epoch) |epoch| {
        try writer.print("{}", .{epoch});
    } else {
        try writer.writeAll("null");
    }
    try writer.writeAll(",\"parent_epoch\":");
    if (generation_refresh.parent_epoch) |parent_epoch| {
        try writer.print("{}", .{parent_epoch});
    } else {
        try writer.writeAll("null");
    }
    try writer.print(",\"delta_entries\":{},\"delta_tombstones\":{}", .{
        generation_refresh.delta_entries,
        generation_refresh.delta_tombstones,
    });
    try writer.print(",\"base_candidate_files\":{},\"delta_candidate_files\":{},\"delta_overlay_pruned\":{},\"delta_tombstone_pruned\":{}", .{
        generation_refresh.base_candidate_files,
        generation_refresh.delta_candidate_files,
        generation_refresh.delta_overlay_pruned,
        generation_refresh.delta_tombstone_pruned,
    });
    try writer.writeAll(",\"overlay_route\":");
    try writeJsonString(writer, generation_refresh.overlay_route);
    try writer.writeAll(",\"refresh_status\":");
    try writeJsonString(writer, generation_refresh.refresh_status);
    try writer.writeAll(",\"fallback_reason\":");
    try writeJsonString(writer, generation_refresh.fallback_reason);
    try writer.writeAll("}");
}

pub fn writeSearchHits(writer: anytype, report: search.SearchReport) !void {
    for (report.hits[0..report.hit_count]) |hit| {
        try writer.print("{s}:{}:{}:{s}\n", .{ hit.path, hit.line, hit.column, hit.preview });
    }
}

pub fn writeMatchesJsonHits(writer: anytype, report: search.SearchReport) !void {
    try writer.writeAll("{\"hits\":[");
    for (report.hits[0..report.hit_count], 0..) |hit, index| {
        if (index > 0) try writer.writeAll(",");
        try writeSearchHitJson(writer, report, hit);
    }
    try writer.writeAll("]}\n");
}

fn writeSearchHitJson(writer: anytype, report: search.SearchReport, hit: search.SearchHit) !void {
    try writer.writeAll("{\"path\":");
    try writeJsonString(writer, hit.path);
    try writer.writeAll(",\"absolute_path\":");
    try writeAbsoluteHitPath(writer, report.cwd, hit.path);
    try writer.print(",\"line\":{},\"column\":{},\"preview\":", .{ hit.line, hit.column });
    try writeJsonString(writer, hit.preview);
    try writer.writeAll("}");
}

fn writeAbsoluteHitPath(writer: anytype, cwd: []const u8, path: []const u8) !void {
    if (isAbsolutePath(path) or cwd.len == 0 or std.mem.eql(u8, cwd, ".")) {
        return writeJsonString(writer, path);
    }
    try writer.writeByte('"');
    try writeJsonStringContents(writer, cwd);
    if (!endsWithSeparator(cwd) and path.len > 0 and !startsWithSeparator(path)) try writer.writeByte('/');
    try writeJsonStringContents(writer, path);
    try writer.writeByte('"');
}

fn isAbsolutePath(path: []const u8) bool {
    if (path.len >= 1 and (path[0] == '/' or path[0] == '\\')) return true;
    return path.len >= 3 and path[1] == ':' and (path[2] == '/' or path[2] == '\\') and std.ascii.isAlphabetic(path[0]);
}

fn startsWithSeparator(path: []const u8) bool {
    return path.len > 0 and (path[0] == '/' or path[0] == '\\');
}

fn endsWithSeparator(path: []const u8) bool {
    return path.len > 0 and (path[path.len - 1] == '/' or path[path.len - 1] == '\\');
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
                try writeInspectNextRange(writer, window.path, window.end_line + 1, window.end_line + span);
            }
        } else if (window.limit) |limit| {
            if (limit > 0 and window.line_count >= limit) {
                try writeInspectNextStartLimit(writer, window.path, window.end_line + 1, limit);
            }
        }
    }
}

fn writeInspectNextRange(writer: anytype, path: []const u8, start_line: usize, end_line: usize) !void {
    try writer.writeAll("-- ix.next.v1 {\"argv\":[\"ix\",\"inspect\",");
    try writeJsonString(writer, path);
    try writer.writeAll(",\"--range\",");
    try writer.writeByte('"');
    try writer.print("{}:{}", .{ start_line, end_line });
    try writer.writeAll("\"],\"cmd\":\"inspect\"} --\n");
}

fn writeInspectNextStartLimit(writer: anytype, path: []const u8, start_line: usize, limit: usize) !void {
    try writer.writeAll("-- ix.next.v1 {\"argv\":[\"ix\",\"inspect\",");
    try writeJsonString(writer, path);
    try writer.writeAll(",\"--start-line\",");
    try writer.writeByte('"');
    try writer.print("{}", .{start_line});
    try writer.writeAll("\",\"--limit\",");
    try writer.writeByte('"');
    try writer.print("{}", .{limit});
    try writer.writeAll("\"],\"cmd\":\"inspect\"} --\n");
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
    try writeJsonStringContents(writer, value);
    try writer.writeByte('"');
}

fn writeJsonStringContents(writer: anytype, value: []const u8) !void {
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
}

test "error sentinel is versioned" {
    var buffer: [128]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    try writeError(&writer, "invalid_arguments", "MissingCommand");
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "ix.error.v1") != null);
}

test "matches json emits hit records only" {
    var report = search.SearchReport{
        .expression = "lit:needle",
        .cwd = "C:/repo",
        .input_roots = 1,
        .effective_roots = 1,
        .pruned_roots = 0,
        .overlap_pruned_roots = 0,
        .discovered_duplicate_paths = 0,
        .collect_hits = true,
        .stats = .{},
        .bytes_scanned = 128,
        .files_discovered = 1,
        .files_scanned = 1,
        .files_skipped = 0,
        .matches_found = 1,
        .truncated = false,
        .slowest_path = "fixture.txt",
        .slowest_bytes = 128,
        .slowest_ms = 0,
        .discover_ms = 0,
        .scan_ms = 0,
        .aggregate_ms = 0,
        .total_ms = 0,
        .scan_work_ms_total = 0,
        .scan_open_ms_total = 0,
        .scan_file_ms_total = 0,
        .capture_scan_open_timing = false,
        .capture_linux_dominant_attribution = false,
        .capture_discovery_skip_bytes = false,
        .matcher_strategy_supported = true,
        .outer_parallel_shard_safe = true,
        .uses_single_literal_counter = true,
        .fast_count_range_overlap = null,
        .available_threads = 1,
        .outer_scan_threads = 1,
        .hits = undefined,
        .hit_count = 1,
    };
    report.hits[0] = .{ .path = "fixture.txt", .line = 7, .column = 3, .preview = "a needle" };

    var buffer: [512]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    try writeMatchesJsonHits(&writer, report);
    const out = writer.buffered();

    try std.testing.expect(std.mem.indexOf(u8, out, "\"hits\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"path\":\"fixture.txt\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"absolute_path\":\"C:/repo/fixture.txt\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"line\":7") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"stats\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"matches_found\"") == null);
}

test "search result sentinel includes agent-safe absolute hit paths" {
    var report = search.SearchReport{
        .expression = "lit:needle",
        .cwd = "C:/repo",
        .input_roots = 1,
        .effective_roots = 1,
        .pruned_roots = 0,
        .overlap_pruned_roots = 0,
        .discovered_duplicate_paths = 0,
        .collect_hits = true,
        .stats = .{},
        .bytes_scanned = 128,
        .files_discovered = 1,
        .files_scanned = 1,
        .files_skipped = 0,
        .matches_found = 1,
        .truncated = false,
        .slowest_path = "src/fixture.txt",
        .slowest_bytes = 128,
        .slowest_ms = 0,
        .discover_ms = 0,
        .scan_ms = 0,
        .aggregate_ms = 0,
        .total_ms = 0,
        .scan_work_ms_total = 0,
        .scan_open_ms_total = 0,
        .scan_file_ms_total = 0,
        .capture_scan_open_timing = false,
        .capture_linux_dominant_attribution = false,
        .capture_discovery_skip_bytes = false,
        .matcher_strategy_supported = true,
        .outer_parallel_shard_safe = true,
        .uses_single_literal_counter = true,
        .fast_count_range_overlap = null,
        .available_threads = 1,
        .outer_scan_threads = 1,
        .hits = undefined,
        .hit_count = 1,
    };
    report.hits[0] = .{ .path = "src/fixture.txt", .line = 7, .column = 3, .preview = "a needle" };

    var buffer: [1024]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    try writeSearchReport(&writer, report);
    const out = writer.buffered();

    try std.testing.expect(std.mem.indexOf(u8, out, "ix.result.v1") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"hits\":[") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "}},\"hits\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"path\":\"src/fixture.txt\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"absolute_path\":\"C:/repo/src/fixture.txt\"") != null);
}

test "inspect next sentinel json escapes path argv" {
    var window = inspect.InspectWindow{
        .path = "C:\\repo\\quote\"dir\\file.zig",
        .request_label = "range",
        .start_line = 1,
        .limit = null,
        .skip = 0,
        .allow_full = false,
        .requested_end_line = 2,
        .end_line = 2,
        .has_more = true,
        .eof = false,
        .total_lines = null,
        .lines = undefined,
        .line_count = 2,
    };
    window.lines[0] = .{ .number = 1, .text = "one" };
    window.lines[1] = .{ .number = 2, .text = "two" };

    var buffer: [1024]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    try writeInspectWindow(&writer, window);
    const out = writer.buffered();

    try std.testing.expect(std.mem.indexOf(u8, out, "ix.next.v1") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"C:\\\\repo\\\\quote\\\"dir\\\\file.zig\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"--range\",\"3:4\"") != null);
}

test "access error json exposes partial-search diagnostics" {
    var access_errors = core_stats.AccessErrorStats{};
    access_errors.record("discovery", "open_dir", "C:/Windows/System32/config", error.AccessDenied);

    var buffer: [512]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    try writeAccessErrorsJson(&writer, access_errors);
    const out = writer.buffered();

    try std.testing.expect(std.mem.indexOf(u8, out, "\"access_errors\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"access_denied\":1") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"operation\":\"open_dir\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"error\":\"AccessDenied\"") != null);
}

test "fast count density json exposes live counters" {
    var buffer: [1024]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    try writeFastCountDensityJson(&writer, .{
        .alternate_range_calls = 2,
        .alternate_range_bytes = 4096,
        .alternate_pcre_range_calls = 1,
        .alternate_pcre_range_bytes = 2048,
        .alternate_teddy_range_calls = 1,
        .alternate_teddy_range_bytes = 2048,
        .alternate_compiled_range_calls = 1,
        .alternate_compiled_range_bytes = 2048,
        .alternate_matches = 7,
    });
    const out = writer.buffered();

    try std.testing.expect(std.mem.indexOf(u8, out, "\"fast_count_density\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"alternate_range_calls\":2") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"alternate_pcre_range_calls\":1") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"alternate_teddy_range_calls\":1") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"alternate_compiled_range_calls\":1") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"alternate_matches\":7") != null);
}

test "search json emits bounded slowest file attribution list" {
    var report = search.SearchReport{
        .expression = "lit:needle",
        .cwd = "C:/repo",
        .input_roots = 1,
        .effective_roots = 1,
        .pruned_roots = 0,
        .overlap_pruned_roots = 0,
        .discovered_duplicate_paths = 0,
        .collect_hits = false,
        .stats = .{},
        .bytes_scanned = 512,
        .files_discovered = 2,
        .files_scanned = 2,
        .files_skipped = 0,
        .matches_found = 0,
        .truncated = false,
        .slowest_path = "slow.h",
        .slowest_bytes = 256,
        .slowest_ms = 3.5,
        .discover_ms = 0,
        .scan_ms = 0,
        .aggregate_ms = 0,
        .total_ms = 0,
        .scan_work_ms_total = 0,
        .scan_open_ms_total = 0,
        .scan_file_ms_total = 0,
        .capture_scan_open_timing = false,
        .capture_linux_dominant_attribution = false,
        .capture_discovery_skip_bytes = false,
        .matcher_strategy_supported = true,
        .outer_parallel_shard_safe = true,
        .uses_single_literal_counter = true,
        .fast_count_range_overlap = null,
        .available_threads = 1,
        .outer_scan_threads = 1,
        .hits = undefined,
        .hit_count = 0,
    };
    report.stats.recordSlowFile("fast.h", 1.0, 128, false);
    report.stats.recordSlowFile("slow.h", 3.5, 256, true);

    var buffer: [16384]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    try writeSearchJsonReport(&writer, report);
    const out = writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, out, "\"scan_open_ms_total\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"scan_file_ms_total\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"scan_file_mmap_ms_total\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"scan_file_buffered_ms_total\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"scan_input_policy\":\"auto\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"resource_profile\":\"low\"") != null);
    const slow_index = std.mem.indexOf(u8, out, "\"path\":\"slow.h\"") orelse return error.MissingSlowFile;
    const fast_index = std.mem.indexOf(u8, out, "\"path\":\"fast.h\"") orelse return error.MissingFastFile;

    try std.testing.expect(slow_index < fast_index);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"targeted_slowest_files\":1") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"targeted_slowest_bytes\":256") != null);
}

test "catalog index json exposes inactive default state" {
    var buffer: [256]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    try writeCatalogIndexJson(&writer, .{});
    const out = writer.buffered();

    try std.testing.expect(std.mem.indexOf(u8, out, "\"catalog_index\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"enabled\":false") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"available\":false") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"generation\":null") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"fallback_reason\":\"not_wired\"") != null);
}

test "postings index json exposes candidate pruning counters" {
    var buffer: [512]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    try writePostingsIndexJson(&writer, .{
        .enabled = true,
        .available = true,
        .generation = 7,
        .trigram_count = 3,
        .postings_count = 5,
        .file_count = 11,
        .candidate_files = 2,
        .pruned_files = 9,
        .verified_files = 2,
        .block_proof_enabled = true,
        .block_count = 4,
        .block_prune_candidate_blocks = 3,
        .block_prune_candidate_postings = 12,
        .block_prune_candidate_compressed_bytes = 6,
        .fallback_reason = "",
    });
    const out = writer.buffered();

    try std.testing.expect(std.mem.indexOf(u8, out, "\"postings_index\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"enabled\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"generation\":7") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"candidate_files\":2") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"pruned_files\":9") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"verified_files\":2") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"block_proof_enabled\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"block_prune_candidate_blocks\":3") != null);
}

test "generation refresh json exposes epoch status and fallback" {
    var buffer: [1024]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    try writeGenerationRefreshJson(&writer, .{
        .enabled = true,
        .available = true,
        .epoch = 42,
        .parent_epoch = 40,
        .delta_entries = 3,
        .delta_tombstones = 1,
        .base_candidate_files = 2,
        .delta_candidate_files = 1,
        .delta_overlay_pruned = 1,
        .delta_tombstone_pruned = 1,
        .overlay_route = "base_plus_delta",
        .refresh_status = "pinned",
        .fallback_reason = "",
    });
    const out = writer.buffered();

    try std.testing.expect(std.mem.indexOf(u8, out, "\"generation_refresh\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"enabled\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"available\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"epoch\":42") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"parent_epoch\":40") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"delta_entries\":3") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"delta_tombstones\":1") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"base_candidate_files\":2") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"delta_candidate_files\":1") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"delta_overlay_pruned\":1") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"delta_tombstone_pruned\":1") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"overlay_route\":\"base_plus_delta\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"refresh_status\":\"pinned\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"fallback_reason\":\"\"") != null);
}
