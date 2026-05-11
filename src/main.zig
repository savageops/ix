const std = @import("std");
const builtin = @import("builtin");
const cli = @import("cli/args.zig");
const output = @import("cli/output.zig");
const expr = @import("core/expr.zig");
const inspect = @import("core/inspect.zig");
const search = @import("core/search.zig");

test {
    _ = @import("core/trigram.zig");
    _ = @import("core/corpus.zig");
    _ = @import("core/catalog.zig");
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
/// Uses Zig's arena allocator from process init. All allocations live for
/// the process lifetime — no individual frees needed. This is safe because
/// IX is a short-lived CLI tool, not a long-running server. The arena is
/// backed by the OS page allocator and released on process exit.
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
            if (shouldLaunchNexusSidecar(effective_request, report)) launchNexusSidecar(init.io, allocator, argv[0], effective_request);
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
            if (shouldLaunchNexusSidecar(effective_request, report)) launchNexusSidecar(init.io, allocator, argv[0], effective_request);
            if (effective_request.json) {
                try output.writeSearchJsonReport(stdout, report);
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
                const reports = try allocator.alloc(inspect.ContextReport, request.path_count);
                var report_count: usize = 0;
                var path_index: usize = 0;
                while (path_index < request.path_count) : (path_index += 1) {
                    reports[report_count] = inspect.contextForPath(init.io, allocator, request, request.paths[path_index], plan) catch |err| {
                        try output.writeError(stderr, "inspect_failed", @errorName(err));
                        try stderr.flush();
                        std.process.exit(1);
                    };
                    report_count += 1;
                }
                if (request.format == .json) {
                    const context_expression = request.expression orelse plan.source;
                    try output.writeInspectContextJsonReports(stdout, context_expression, reports[0..report_count]);
                } else if (request.format == .records) {
                    for (reports[0..report_count]) |report| try output.writeInspectContextRecords(stdout, report);
                } else {
                    for (reports[0..report_count]) |report| try output.writeInspectContext(stdout, report);
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
        .nexus => |request| {
            const plan = expr.parse(request.expression) catch std.process.exit(0);
            _ = search.run(init.io, allocator, request, plan) catch std.process.exit(0);
            search.holdEvidenceFrontierLive(init.io, allocator, request, plan);
        },
    }
    try stdout.flush();
}

fn nexusDisabled(init: std.process.Init) bool {
    const value = init.environ_map.getPtr("IX_NEXUS") orelse return false;
    return std.mem.eql(u8, value.*, "0") or std.ascii.eqlIgnoreCase(value.*, "false") or std.ascii.eqlIgnoreCase(value.*, "off");
}

fn shouldLaunchNexusSidecar(request: cli.SearchRequest, report: search.SearchReport) bool {
    if (request.nexus_disabled) return false;
    return report.stats.trigram_acceleration.pruned_files == 0;
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
    if (request.follow_symlinks) argv.append(allocator, "--follow-symlinks") catch return;
    if (request.threads) |threads| {
        argv.append(allocator, "--threads") catch return;
        argv.append(allocator, std.fmt.allocPrint(allocator, "{}", .{threads}) catch return) catch return;
    }

    if (comptime builtin.os.tag == .windows) {
        launchNexusSidecarWindows(allocator, argv.items) catch return;
        return;
    }

    const child = std.process.spawn(io, .{
        .argv = argv.items,
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
        .create_no_window = true,
    }) catch return;
    _ = child;
}

fn launchNexusSidecarWindows(allocator: std.mem.Allocator, argv: []const []const u8) !void {
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
    if (ok == .FALSE) return error.NexusSpawnFailed;
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
    const enabled = testSearchRequestForSidecar(false);
    const disabled = testSearchRequestForSidecar(true);
    try std.testing.expect(shouldLaunchNexusSidecar(enabled, testSearchReportForSidecar(0)));
    try std.testing.expect(!shouldLaunchNexusSidecar(enabled, testSearchReportForSidecar(1)));
    try std.testing.expect(!shouldLaunchNexusSidecar(enabled, testSearchReportForSidecar(79041)));
    try std.testing.expect(!shouldLaunchNexusSidecar(disabled, testSearchReportForSidecar(0)));
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

fn testSearchReportForSidecar(pruned_files: usize) search.SearchReport {
    var report = search.SearchReport{
        .expression = "lit:needle",
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
        .max_hits = null,
        .threads = null,
        .emit_report = null,
        .nexus_build = false,
        .nexus_disabled = nexus_disabled,
    };
}

test {
    std.testing.refAllDecls(@This());
}
