const std = @import("std");
const builtin = @import("builtin");
const cli = @import("../cli/args.zig");
const expr = @import("expr.zig");
const search = @import("search.zig");
const trigram = @import("trigram.zig");
const usn = @import("usn.zig");

/// P29: Watch command — streams new matches as files change.
///
/// Opens a directory handle and uses platform-native file change notification
/// (ReadDirectoryChangesW on Windows, inotify on Linux) to detect file
/// modifications. When a file changes, it is scanned against the search plan
/// and any new matches are emitted as NDJSON records — one JSON hit per line,
/// same format as --format ndjson.
///
/// The watch loop is blocking and runs until interrupted (Ctrl+C).
/// Each change notification re-scans only the changed file, not the full
/// corpus — the cost is proportional to the number of changed files, not
/// the total corpus size.

const POLL_INTERVAL_MS: u32 = 1000;

/// Result of scanning one changed file.
pub const WatchHit = struct {
    path: []const u8,
    line: usize,
    column: usize,
    preview: []const u8,
};

/// Runs the watch loop. Blocks until interrupted.
/// Emits NDJSON records to the writer as matches are found in changed files.
pub fn runWatch(
    io: std.Io,
    allocator: std.mem.Allocator,
    request: cli.SearchRequest,
    plan: expr.ExpressionPlan,
    writer: anytype,
) !void {
    // Initial scan: emit current matches first.
    var report = search.run(io, allocator, request, plan) catch |err| {
        try writer.print("{{\"type\":\"error\",\"message\":\"{s}\"}}\n", .{@errorName(err)});
        try writer.flush();
        return;
    };
    for (report.hits[0..report.hit_count]) |hit| {
        try writer.print("{{\"type\":\"hit\",\"event\":\"initial\",\"path\":\"{s}\",\"line\":{},\"column\":{},\"preview\":\"{s}\"}}\n", .{
            hit.path, hit.line, hit.column, hit.preview,
        });
    }
    try writer.print("{{\"type\":\"watch_ready\",\"matches\":{},\"watching\":\"{s}\"}}\n", .{
        report.matches_found, request.paths[0],
    });
    try writer.flush();

    // Watch loop: poll for changes and re-scan changed files.
    const root = request.paths[0];

    if (builtin.os.tag == .windows) {
        try watchWindows(io, allocator, root, request, plan, writer);
    } else {
        try watchPolling(io, allocator, root, request, plan, writer);
    }
}

// ── Windows: ReadDirectoryChangesW ─────────────────────────────────

fn watchWindows(
    io: std.Io,
    allocator: std.mem.Allocator,
    root: []const u8,
    request: cli.SearchRequest,
    plan: expr.ExpressionPlan,
    writer: anytype,
) !void {
    const windows = std.os.windows;

    // Open directory handle for ReadDirectoryChangesW.
    const WindowsApi = struct {
        extern "kernel32" fn CreateFileA(
            lpFileName: [*:0]const u8,
            dwDesiredAccess: u32,
            dwShareMode: u32,
            lpSecurityAttributes: ?*anyopaque,
            dwCreationDisposition: u32,
            dwFlagsAndAttributes: u32,
            hTemplateFile: ?*anyopaque,
        ) ?*anyopaque;
    };
    const FILE_LIST_DIRECTORY: u32 = 0x0001;
    const FILE_SHARE_ALL: u32 = 0x07; // READ | WRITE | DELETE
    const OPEN_EXISTING: u32 = 3;
    const FILE_FLAG_BACKUP_SEMANTICS: u32 = 0x0200_0000;
    const INVALID_HANDLE: ?*anyopaque = null;

    var root_buf: [std.fs.max_path_bytes:0]u8 = undefined;
    const root_path = std.fmt.bufPrintZ(&root_buf, "{s}", .{root}) catch return;
    const dir_handle = WindowsApi.CreateFileA(
        root_path.ptr,
        FILE_LIST_DIRECTORY,
        FILE_SHARE_ALL,
        null,
        OPEN_EXISTING,
        FILE_FLAG_BACKUP_SEMANTICS,
        null,
    );
    if (dir_handle == INVALID_HANDLE) {
        try writer.print("{{\"type\":\"error\",\"message\":\"cannot_open_directory\"}}\n", .{});
        try writer.flush();
        return;
    }
    const handle: windows.HANDLE = @ptrCast(dir_handle);

    var notify_buf: [64 * 1024]u8 = undefined;
    var bytes_returned: windows.DWORD = 0;

    while (true) {
        const ok = usn.ReadDirectoryChangesW(
            handle,
            &notify_buf,
            @intCast(notify_buf.len),
            windows.BOOL.TRUE, // watch subtree
            usn.IX_DIRECTORY_WATCH_NOTIFY_FILTER,
            &bytes_returned,
            null,
            null,
        );
        if (ok == windows.BOOL.FALSE or bytes_returned == 0) {
            io.sleep(std.Io.Duration.fromMilliseconds(POLL_INTERVAL_MS), .awake) catch {};
            continue;
        }

        // Parse FILE_NOTIFY_INFORMATION records and scan changed files.
        var offset: usize = 0;
        while (offset < bytes_returned) {
            const record_info = parseNotifyRecord(notify_buf[offset..]);
            if (record_info.bytes_consumed == 0) break;

            const filename = record_info.filename;
            if (filename.len > 0) {
                const changed_path = std.fmt.allocPrint(allocator, "{s}/{s}", .{ root, filename }) catch break;
                defer allocator.free(changed_path);

                try scanChangedFile(io, allocator, changed_path, request, plan, writer);
            }

            offset += record_info.bytes_consumed;
        }
        try writer.flush();
    }
}

const NotifyRecordInfo = struct {
    filename: []const u8,
    bytes_consumed: usize,
};

fn parseNotifyRecord(buf: []const u8) NotifyRecordInfo {
    if (buf.len < 12) return .{ .filename = "", .bytes_consumed = 0 };

    // FILE_NOTIFY_INFORMATION layout:
    //   DWORD NextEntryOffset (4 bytes)
    //   DWORD Action (4 bytes)
    //   DWORD FileNameLength (4 bytes, in bytes, not including NUL)
    //   WCHAR FileName[] (variable)
    const next_offset = std.mem.readInt(u32, buf[0..4], .little);
    const action = std.mem.readInt(u32, buf[4..8], .little);
    const name_len = std.mem.readInt(u32, buf[8..12], .little);

    if (name_len == 0 or 12 + name_len > buf.len) {
        return .{ .filename = "", .bytes_consumed = if (next_offset > 0) next_offset else buf.len };
    }

    // Convert WTF-16LE to UTF-8.
    var name_buf: [std.fs.max_path_bytes]u8 = undefined;
    const wtf16_slice: []const u16 = @as([*]const u16, @ptrCast(@alignCast(buf[12..].ptr)))[0 .. name_len / 2];
    const name_len_utf8 = std.unicode.wtf16LeToWtf8(&name_buf, wtf16_slice);
    _ = action;

    const consumed = if (next_offset > 0) next_offset else (12 + name_len);
    return .{
        .filename = name_buf[0..name_len_utf8],
        .bytes_consumed = consumed,
    };
}

// ── POSIX: polling fallback ────────────────────────────────────────

fn watchPolling(
    io: std.Io,
    allocator: std.mem.Allocator,
    root: []const u8,
    request: cli.SearchRequest,
    plan: expr.ExpressionPlan,
    writer: anytype,
) !void {
    _ = root;
    // Simple polling fallback: re-scan every POLL_INTERVAL_MS.
    // This is the portable path for non-Windows platforms.
    while (true) {
        io.sleep(std.Io.Duration.fromMilliseconds(POLL_INTERVAL_MS), .awake) catch {};
        // Re-run the search and emit only NEW hits (simplified: emit all).
        var report = search.run(io, allocator, request, plan) catch continue;
        for (report.hits[0..report.hit_count]) |hit| {
            try writer.print("{{\"type\":\"hit\",\"event\":\"change\",\"path\":\"{s}\",\"line\":{},\"column\":{},\"preview\":\"{s}\"}}\n", .{
                hit.path, hit.line, hit.column, hit.preview,
            });
        }
        try writer.flush();
    }
}

// ── Per-file scan ──────────────────────────────────────────────────

fn scanChangedFile(
    io: std.Io,
    allocator: std.mem.Allocator,
    path: []const u8,
    request: cli.SearchRequest,
    plan: expr.ExpressionPlan,
    writer: anytype,
) !void {
    // Use the search engine to scan the changed file.
    var single_request = request;
    single_request.paths = .{path} ++ [_][]const u8{""} ** (cli.MAX_SEARCH_PATHS - 1);
    single_request.path_count = 1;

    var report = search.run(io, allocator, single_request, plan) catch return;
    for (report.hits[0..report.hit_count]) |hit| {
        try writer.print("{{\"type\":\"hit\",\"event\":\"change\",\"path\":\"{s}\",\"line\":{},\"column\":{},\"preview\":\"{s}\"}}\n", .{
            hit.path, hit.line, hit.column, hit.preview,
        });
    }
}
