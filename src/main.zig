const std = @import("std");
const builtin = @import("builtin");
const cli = @import("cli/args.zig");
const output = @import("cli/output.zig");
const expr = @import("core/expr.zig");
const indexd = @import("core/indexd.zig");
const inspect = @import("core/inspect.zig");
const process_tool = @import("core/process_tool.zig");
const search = @import("core/search.zig");

const NEXUS_MIN_BUILD_FRONTIER_FILES: usize = 4096;

test {
    _ = @import("core/trigram.zig");
    _ = @import("core/corpus.zig");
    _ = @import("core/catalog.zig");
    _ = @import("core/byte_shard.zig");
    _ = @import("core/discovered_files.zig");
    _ = @import("core/postings.zig");
    _ = @import("core/literal_alternates.zig");
    _ = @import("core/process_tool.zig");
    _ = @import("core/process_memory.zig");
    _ = @import("core/protected_paths.zig");
    _ = @import("core/resource_profile.zig");
    _ = @import("core/byte_frequencies.zig");
    _ = @import("core/indexd.zig");
    _ = @import("core/generation.zig");
    _ = @import("core/usn.zig");
}

/// IX Zig binary entry point.
///
/// PIPELINE OVERVIEW:
///   argv → parseInvocation → command dispatch → engine execution → output
///
/// The pipeline is designed so that user-visible contracts (command grammar,
/// output schema, sentinel format) freeze early and engine internals can
/// change without breaking consumers. This mirrors the Rust binary's
/// pipeline at crates/iex-cli/src/main.rs.
///
/// MEMORY STRATEGY:
/// Uses Zig's arena allocator from process init for short-lived command paths.
/// The hidden indexd watch command is long-lived and switches to a freeing
/// allocator at dispatch so regeneration cycles can release indexed buffers.
pub fn main(init: std.process.Init) !void {
    const allocator = init.arena.allocator();

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(init.io, &stdout_buffer);
    const stdout = &stdout_writer.interface;
    var stderr_buffer: [4096]u8 = undefined;
    var stderr_writer = std.Io.File.stderr().writer(init.io, &stderr_buffer);
    const stderr = &stderr_writer.interface;

    const raw_argv = try init.minimal.args.toSlice(allocator);
    var argv_storage: [256][]const u8 = undefined;
    if (raw_argv.len > argv_storage.len) {
        try output.writeError(stderr, "invalid_arguments", "TooManyArguments");
        try stderr.flush();
        std.process.exit(1);
    }
    for (raw_argv, 0..) |arg, index| argv_storage[index] = arg;
    const argv = argv_storage[0..raw_argv.len];

    // Parse argv into a typed command. If the first arg isn't a known
    // subcommand (search/matches/inspect/explain/help), it falls through
    // to parseCompatSearch — the rg-shaped compatibility translator that
    // lowers bare `ix PATTERN [PATH]` into canonical search arguments.
    // This is intentionally a translator, not a second search engine.
    const invocation = cli.parseInvocation(allocator, argv) catch |err| {
        if (err == cli.ParseError.UnsupportedFlag and argv.len > 1 and std.mem.startsWith(u8, argv[1], "-")) {
            try output.writeCompatUnsupportedFlag(stderr, argv[1]);
        } else {
            try output.writeError(stderr, "invalid_arguments", @errorName(err));
        }
        try stderr.flush();
        std.process.exit(1);
    };

    switch (invocation.command) {
        .help => |topic| try output.writeHelp(stdout, topic),
        .search => |request| {
            var effective_request = request;
            effective_request.nexus_disabled = nexusDisabled(init);
            effective_request.index_enabled = indexdEnabled(init);
            const plan = expr.parse(request.expression) catch |err| {
                try output.writeError(stderr, "invalid_expression", @errorName(err));
                try stderr.flush();
                std.process.exit(1);
            };
            const report = search.run(init.io, allocator, effective_request, plan) catch |err| {
                try output.writeError(stderr, "search_failed", @errorName(err));
                try stderr.flush();
                std.process.exit(1);
            };
            if (effective_request.emit_report) |path| output.writeSearchJsonReportToFile(init.io, path, report) catch |err| {
                try output.writeError(stderr, "emit_report_failed", @errorName(err));
                try stderr.flush();
                std.process.exit(1);
            };
            if (shouldLaunchNexusSidecar(init.io, allocator, effective_request, plan, report)) launchNexusSidecar(init.io, allocator, argv[0], effective_request);
            if (shouldLaunchIndexdSidecar(effective_request.index_enabled, effective_request, report)) launchIndexdSidecar(init.io, allocator, argv[0], effective_request.paths[0]);
            if (effective_request.json) {
                try output.writeSearchJsonReport(stdout, report);
            } else {
                if (!effective_request.stats_only) try output.writeSearchHits(stdout, report);
                try output.writeSearchReport(stdout, report);
            }
        },
        .matches => |request| {
            var effective_request = request;
            effective_request.nexus_disabled = nexusDisabled(init);
            effective_request.index_enabled = indexdEnabled(init);
            const plan = expr.parse(request.expression) catch |err| {
                try output.writeError(stderr, "invalid_expression", @errorName(err));
                try stderr.flush();
                std.process.exit(1);
            };
            const report = search.run(init.io, allocator, effective_request, plan) catch |err| {
                try output.writeError(stderr, "search_failed", @errorName(err));
                try stderr.flush();
                std.process.exit(1);
            };
            if (effective_request.emit_report) |path| output.writeSearchJsonReportToFile(init.io, path, report) catch |err| {
                try output.writeError(stderr, "emit_report_failed", @errorName(err));
                try stderr.flush();
                std.process.exit(1);
            };
            if (shouldLaunchNexusSidecar(init.io, allocator, effective_request, plan, report)) launchNexusSidecar(init.io, allocator, argv[0], effective_request);
            if (shouldLaunchIndexdSidecar(effective_request.index_enabled, effective_request, report)) launchIndexdSidecar(init.io, allocator, argv[0], effective_request.paths[0]);
            if (effective_request.json) {
                try output.writeMatchesJsonHits(stdout, report);
            } else if (!effective_request.stats_only) {
                try output.writeSearchHits(stdout, report);
            }
        },
        .inspect => |request| {
            if (request.expression) |expression| {
                const plan = expr.parse(expression) catch |err| {
                    try output.writeError(stderr, "invalid_expression", @errorName(err));
                    try stderr.flush();
                    std.process.exit(1);
                };
                const search_request = inspectSearchRequest(init, request, expression);
                const search_report = search.run(init.io, allocator, search_request, plan) catch |err| {
                    try output.writeError(stderr, "inspect_search_failed", @errorName(err));
                    try stderr.flush();
                    std.process.exit(1);
                };
                const reports = inspect.contextReportsFromSearchReport(init.io, allocator, request, search_report) catch |err| {
                    try output.writeError(stderr, "inspect_failed", @errorName(err));
                    try stderr.flush();
                    std.process.exit(1);
                };
                if (request.format == .json) {
                    const context_expression = request.expression orelse plan.source;
                    try output.writeInspectContextJsonReports(stdout, context_expression, reports);
                } else if (request.format == .records) {
                    for (reports) |report| try output.writeInspectContextRecords(stdout, report);
                } else {
                    for (reports) |report| try output.writeInspectContext(stdout, report);
                }
            } else {
                const windows = try allocator.alloc(inspect.InspectWindow, request.path_count);
                var window_count: usize = 0;
                var path_index: usize = 0;
                while (path_index < request.path_count) : (path_index += 1) {
                    windows[window_count] = inspect.windowForPath(init.io, allocator, request, request.paths[path_index]) catch |err| {
                        try output.writeError(stderr, "inspect_failed", @errorName(err));
                        try stderr.flush();
                        std.process.exit(1);
                    };
                    window_count += 1;
                }
                if (request.format == .json) {
                    try output.writeInspectWindowJsonReports(stdout, windows[0..window_count]);
                } else if (request.format == .records) {
                    for (windows[0..window_count]) |window| try output.writeInspectWindowRecords(stdout, window);
                } else {
                    for (windows[0..window_count]) |window| try output.writeInspectWindow(stdout, window);
                }
            }
        },
        .explain => |request| {
            const plan = expr.parse(request.expression) catch |err| {
                try output.writeError(stderr, "invalid_expression", @errorName(err));
                try stderr.flush();
                std.process.exit(1);
            };
            try output.writeExplain(stdout, plan);
        },
        .process => |request| {
            const report = process_tool.run(init.io, allocator, .{
                .action = switch (request.action) {
                    .status => .status,
                    .cleanup => .cleanup,
                },
                .json = request.json,
                .dry_run = request.dry_run,
            }) catch |err| {
                try output.writeError(stderr, "process_failed", @errorName(err));
                try stderr.flush();
                std.process.exit(1);
            };
            defer report.deinit(allocator);
            try process_tool.writeReport(stdout, report, request.json);
        },
        .nexus => |request| {
            const effective_request = request;
            const plan = expr.parse(effective_request.expression) catch std.process.exit(0);
            _ = search.run(init.io, allocator, effective_request, plan) catch std.process.exit(0);
            search.holdEvidenceFrontierLive(init.io, allocator, effective_request, plan);
        },
        .indexd => |request| {
            _ = indexd.run(init.io, indexdCommandAllocator(), .{
                .root = request.root,
                .foreground = request.foreground,
                .once = request.once,
                .repair = request.repair,
            }) catch |err| {
                try output.writeError(stderr, "indexd_failed", @errorName(err));
                try stderr.flush();
                std.process.exit(1);
            };
        },
    }
    try stdout.flush();
}

fn indexdCommandAllocator() std.mem.Allocator {
    return std.heap.page_allocator;
}

fn nexusDisabled(init: std.process.Init) bool {
    const value = init.environ_map.getPtr("IX_NEXUS") orelse return true;
    return !sidecarEnvValueEnabled(value.*);
}

fn indexdEnabled(init: std.process.Init) bool {
    const value = init.environ_map.getPtr("IX_INDEX") orelse return false;
    return sidecarEnvValueEnabled(value.*);
}

fn sidecarEnvValueEnabled(value: []const u8) bool {
    return std.mem.eql(u8, value, "1") or std.ascii.eqlIgnoreCase(value, "true") or std.ascii.eqlIgnoreCase(value, "on");
}

fn inspectSearchRequest(init: std.process.Init, request: cli.InspectRequest, expression: []const u8) cli.SearchRequest {
    return .{
        .expression = expression,
        .paths = request.paths,
        .path_count = request.path_count,
        .json = false,
        .stats_only = false,
        .hidden = request.hidden,
        .line_numbers = true,
        .fixed_strings = false,
        .case_insensitive = false,
        .follow_symlinks = request.follow_symlinks,
        .no_ignore = true,
        .ignore_files = undefined,
        .ignore_file_count = 0,
        .max_hits = request.max_hits,
        .threads = request.threads,
        .emit_report = null,
        .nexus_build = false,
        .nexus_disabled = nexusDisabled(init),
        .index_enabled = false,
    };
}

fn shouldLaunchNexusSidecar(io: std.Io, allocator: std.mem.Allocator, request: cli.SearchRequest, plan: expr.ExpressionPlan, report: search.SearchReport) bool {
    if (!shouldConsiderNexusSidecar(request, report)) return false;
    return search.tryClaimEvidenceFrontierBuild(io, allocator, request, plan);
}

fn shouldConsiderNexusSidecar(request: cli.SearchRequest, report: search.SearchReport) bool {
    if (request.nexus_disabled) return false;
    if (request.stats_only) return false;
    if (request.path_count != 1) return false;
    if (report.files_discovered < NEXUS_MIN_BUILD_FRONTIER_FILES) return false;
    if (report.stats.trigram_acceleration.pruned_files != 0) return false;
    return true;
}

fn shouldLaunchIndexdSidecar(enabled: bool, request: cli.SearchRequest, report: search.SearchReport) bool {
    if (!enabled) return false;
    if (request.nexus_build) return false;
    if (request.case_insensitive) return false;
    if (request.hidden) return false;
    if (request.path_count != 1) return false;
    return report.files_discovered > 0;
}

fn launchNexusSidecar(io: std.Io, allocator: std.mem.Allocator, argv0: []const u8, request: cli.SearchRequest) void {
    if (request.nexus_build) return;
    if (request.case_insensitive) return;
    if (request.path_count > 1) return;
    if (!std.process.can_spawn) return;

    var argv = std.ArrayList([]const u8).empty;
    argv.append(allocator, argv0) catch return;
    argv.append(allocator, "__ix_nexus") catch return;
    argv.append(allocator, request.expression) catch return;
    var path_index: usize = 0;
    while (path_index < request.path_count) : (path_index += 1) argv.append(allocator, request.paths[path_index]) catch return;
    if (request.hidden) argv.append(allocator, "--hidden") catch return;
    if (request.no_ignore) argv.append(allocator, "--no-ignore") catch return;
    for (request.ignore_files[0..request.ignore_file_count]) |ignore_file| {
        argv.append(allocator, "--ignore-file") catch return;
        argv.append(allocator, ignore_file) catch return;
    }
    if (request.follow_symlinks) argv.append(allocator, "--follow-symlinks") catch return;
    if (request.threads) |threads| {
        argv.append(allocator, "--threads") catch return;
        argv.append(allocator, std.fmt.allocPrint(allocator, "{}", .{threads}) catch return) catch return;
    }
    launchDetachedProcess(io, allocator, argv.items) catch return;
}

fn launchIndexdSidecar(io: std.Io, allocator: std.mem.Allocator, argv0: []const u8, root: []const u8) void {
    if (!std.process.can_spawn) return;

    var argv = std.ArrayList([]const u8).empty;
    argv.append(allocator, argv0) catch return;
    argv.append(allocator, "__ix_indexd") catch return;
    argv.append(allocator, root) catch return;

    launchDetachedProcess(io, allocator, argv.items) catch return;
}

fn launchDetachedProcess(io: std.Io, allocator: std.mem.Allocator, argv: []const []const u8) !void {
    if (comptime builtin.os.tag == .windows) {
        try launchDetachedProcessWindows(allocator, argv);
        return;
    }

    const child = std.process.spawn(io, .{
        .argv = argv,
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
        .create_no_window = true,
    }) catch return;
    _ = child;
}

fn launchDetachedProcessWindows(allocator: std.mem.Allocator, argv: []const []const u8) !void {
    const windows = std.os.windows;
    const app_w = try std.unicode.wtf8ToWtf16LeAllocZ(allocator, argv[0]);
    var command_line = std.ArrayList(u8).empty;
    for (argv, 0..) |arg, index| {
        if (index != 0) try command_line.append(allocator, ' ');
        try appendWindowsCommandArg(allocator, &command_line, arg);
    }
    const command_w = try std.unicode.wtf8ToWtf16LeAllocZ(allocator, command_line.items);

    var startup = std.mem.zeroes(windows.STARTUPINFOW);
    startup.cb = @sizeOf(windows.STARTUPINFOW);
    var info: windows.PROCESS.INFORMATION = undefined;
    const ok = windows.kernel32.CreateProcessW(
        app_w.ptr,
        command_w.ptr,
        null,
        null,
        .FALSE,
        .{
            .detached_process = true,
            .create_new_process_group = true,
            .create_no_window = true,
        },
        null,
        null,
        &startup,
        &info,
    );
    if (ok == .FALSE) return error.DetachedSpawnFailed;
    windows.CloseHandle(info.hThread);
    windows.CloseHandle(info.hProcess);
}

fn appendWindowsCommandArg(allocator: std.mem.Allocator, list: *std.ArrayList(u8), arg: []const u8) !void {
    try list.append(allocator, '"');
    var backslashes: usize = 0;
    for (arg) |byte| {
        if (byte == '\\') {
            backslashes += 1;
            continue;
        }
        if (byte == '"') {
            try appendRepeated(allocator, list, '\\', backslashes * 2 + 1);
            try list.append(allocator, '"');
        } else {
            try appendRepeated(allocator, list, '\\', backslashes);
            try list.append(allocator, byte);
        }
        backslashes = 0;
    }
    try appendRepeated(allocator, list, '\\', backslashes * 2);
    try list.append(allocator, '"');
}

fn appendRepeated(allocator: std.mem.Allocator, list: *std.ArrayList(u8), byte: u8, count: usize) !void {
    var index: usize = 0;
    while (index < count) : (index += 1) try list.append(allocator, byte);
}

test "nexus sidecar launch is gated after evidence-pruned foreground reuse" {
    var enabled = testSearchRequestForSidecar(false);
    const disabled = testSearchRequestForSidecar(true);
    enabled.stats_only = false;
    var cold_report = testSearchReportForSidecar(0);
    cold_report.files_discovered = NEXUS_MIN_BUILD_FRONTIER_FILES;
    try std.testing.expect(shouldConsiderNexusSidecar(enabled, cold_report));
    var small_report = testSearchReportForSidecar(0);
    small_report.files_discovered = NEXUS_MIN_BUILD_FRONTIER_FILES - 1;
    try std.testing.expect(!shouldConsiderNexusSidecar(enabled, small_report));
    var stats_only = enabled;
    stats_only.stats_only = true;
    try std.testing.expect(!shouldConsiderNexusSidecar(stats_only, cold_report));
    try std.testing.expect(!shouldConsiderNexusSidecar(enabled, testSearchReportForSidecar(1)));
    try std.testing.expect(!shouldConsiderNexusSidecar(enabled, testSearchReportForSidecar(79041)));
    try std.testing.expect(!shouldConsiderNexusSidecar(disabled, testSearchReportForSidecar(0)));
}

test "indexd sidecar launch is default-on single root and workload gated" {
    var request = testSearchRequestForSidecar(false);
    request.paths[0] = "src";
    var report = testSearchReportForSidecar(0);
    report.files_discovered = 12;

    try std.testing.expect(!shouldLaunchIndexdSidecar(false, request, report));
    try std.testing.expect(shouldLaunchIndexdSidecar(true, request, report));

    request.path_count = 2;
    try std.testing.expect(!shouldLaunchIndexdSidecar(true, request, report));
    request.path_count = 1;

    request.case_insensitive = true;
    try std.testing.expect(!shouldLaunchIndexdSidecar(true, request, report));
    request.case_insensitive = false;

    report.files_discovered = 0;
    try std.testing.expect(!shouldLaunchIndexdSidecar(true, request, report));
}

test "indexd sidecar launch allows generated-looking roots after central state split" {
    var request = testSearchRequestForSidecar(false);
    var report = testSearchReportForSidecar(0);
    report.files_discovered = 12;

    request.paths[0] = "src";
    try std.testing.expect(shouldLaunchIndexdSidecar(true, request, report));

    request.paths[0] = "apps/backend/node_modules/convex/dist";
    try std.testing.expect(shouldLaunchIndexdSidecar(true, request, report));

    request.paths[0] = ".docs/reports/subzero";
    try std.testing.expect(shouldLaunchIndexdSidecar(true, request, report));

    request.paths[0] = "zig-out/bin";
    try std.testing.expect(shouldLaunchIndexdSidecar(true, request, report));
}

test "background sidecar environment gate is explicit opt in" {
    try std.testing.expect(sidecarEnvValueEnabled("1"));
    try std.testing.expect(sidecarEnvValueEnabled("true"));
    try std.testing.expect(sidecarEnvValueEnabled("TRUE"));
    try std.testing.expect(sidecarEnvValueEnabled("on"));
    try std.testing.expect(!sidecarEnvValueEnabled("0"));
    try std.testing.expect(!sidecarEnvValueEnabled("false"));
    try std.testing.expect(!sidecarEnvValueEnabled("off"));
    try std.testing.expect(!sidecarEnvValueEnabled(""));
    try std.testing.expect(!sidecarEnvValueEnabled("yes"));
}

test "windows command argument quoting preserves spaces quotes and trailing slashes" {
    const allocator = std.testing.allocator;
    var list = std.ArrayList(u8).empty;
    defer list.deinit(allocator);

    try appendWindowsCommandArg(allocator, &list, "plain");
    try std.testing.expectEqualStrings("\"plain\"", list.items);
    list.clearRetainingCapacity();

    try appendWindowsCommandArg(allocator, &list, "has space");
    try std.testing.expectEqualStrings("\"has space\"", list.items);
    list.clearRetainingCapacity();

    try appendWindowsCommandArg(allocator, &list, "a\"b");
    try std.testing.expectEqualStrings("\"a\\\"b\"", list.items);
    list.clearRetainingCapacity();

    try appendWindowsCommandArg(allocator, &list, "tail\\");
    try std.testing.expectEqualStrings("\"tail\\\\\"", list.items);
}

test "indexd sidecar launch keeps hidden argv shape" {
    const allocator = std.testing.allocator;
    var argv = std.ArrayList([]const u8).empty;
    defer argv.deinit(allocator);

    try argv.append(allocator, "ix-zig");
    try argv.append(allocator, "__ix_indexd");
    try argv.append(allocator, "E:\\Workspaces\\ix-zig");

    try std.testing.expectEqualStrings("__ix_indexd", argv.items[1]);
    try std.testing.expectEqualStrings("E:\\Workspaces\\ix-zig", argv.items[2]);
}

test "indexd command uses freeing allocator for watch lifecycle" {
    const allocator = indexdCommandAllocator();
    try std.testing.expectEqual(std.heap.page_allocator.vtable, allocator.vtable);
    const bytes = try allocator.alloc(u8, 4096);
    allocator.free(bytes);
}

fn testSearchReportForSidecar(pruned_files: usize) search.SearchReport {
    var report = search.SearchReport{
        .expression = "lit:needle",
        .cwd = ".",
        .input_roots = 1,
        .effective_roots = 1,
        .pruned_roots = 0,
        .overlap_pruned_roots = 0,
        .discovered_duplicate_paths = 0,
        .collect_hits = true,
        .stats = .{},
        .bytes_scanned = 0,
        .files_discovered = 0,
        .files_scanned = 0,
        .files_skipped = 0,
        .matches_found = 0,
        .truncated = false,
        .slowest_path = "",
        .slowest_bytes = 0,
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
        .matcher_strategy_supported = false,
        .outer_parallel_shard_safe = false,
        .uses_single_literal_counter = false,
        .fast_count_range_overlap = null,
        .available_threads = 1,
        .outer_scan_threads = 0,
        .hits = undefined,
        .hit_count = 0,
    };
    report.stats.trigram_acceleration.pruned_files = pruned_files;
    return report;
}

fn testSearchRequestForSidecar(nexus_disabled: bool) cli.SearchRequest {
    return .{
        .expression = "lit:needle",
        .paths = undefined,
        .path_count = 1,
        .json = true,
        .stats_only = true,
        .hidden = false,
        .line_numbers = false,
        .fixed_strings = false,
        .case_insensitive = false,
        .follow_symlinks = false,
        .no_ignore = false,
        .ignore_files = undefined,
        .ignore_file_count = 0,
        .max_hits = null,
        .threads = null,
        .emit_report = null,
        .nexus_build = false,
        .nexus_disabled = nexus_disabled,
        .index_enabled = false,
    };
}

test {
    std.testing.refAllDecls(@This());
}
