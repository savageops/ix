const std = @import("std");
const cli = @import("cli/args.zig");
const output = @import("cli/output.zig");
const expr = @import("core/expr.zig");
const inspect = @import("core/inspect.zig");
const search = @import("core/search.zig");

test {
    _ = @import("core/trigram.zig");
    _ = @import("core/corpus.zig");
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
            const plan = expr.parse(request.expression) catch |err| {
                try output.writeError(stderr, "invalid_expression", @errorName(err));
                try stderr.flush();
                std.process.exit(1);
            };
            const report = search.run(init.io, allocator, request, plan) catch |err| {
                try output.writeError(stderr, "search_failed", @errorName(err));
                try stderr.flush();
                std.process.exit(1);
            };
            if (request.emit_report) |path| output.writeSearchJsonReportToFile(init.io, path, report) catch |err| {
                try output.writeError(stderr, "emit_report_failed", @errorName(err));
                try stderr.flush();
                std.process.exit(1);
            };
            if (request.json) {
                try output.writeSearchJsonReport(stdout, report);
            } else {
                if (!request.stats_only) try output.writeSearchHits(stdout, report);
                try output.writeSearchReport(stdout, report);
            }
        },
        .matches => |request| {
            const plan = expr.parse(request.expression) catch |err| {
                try output.writeError(stderr, "invalid_expression", @errorName(err));
                try stderr.flush();
                std.process.exit(1);
            };
            const report = search.run(init.io, allocator, request, plan) catch |err| {
                try output.writeError(stderr, "search_failed", @errorName(err));
                try stderr.flush();
                std.process.exit(1);
            };
            if (request.emit_report) |path| output.writeSearchJsonReportToFile(init.io, path, report) catch |err| {
                try output.writeError(stderr, "emit_report_failed", @errorName(err));
                try stderr.flush();
                std.process.exit(1);
            };
            if (request.json) {
                try output.writeSearchJsonReport(stdout, report);
            } else if (!request.stats_only) {
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
    }
    try stdout.flush();
}

test {
    std.testing.refAllDecls(@This());
}
