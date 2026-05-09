const std = @import("std");

pub const MAX_SEARCH_PATHS = 128;

pub const CommandTag = enum {
    help,
    search,
    matches,
    inspect,
    explain,
};

pub const HelpTopic = enum {
    top,
    search,
    matches,
    inspect,
    explain,
};

pub const SearchRequest = struct {
    expression: []const u8,
    paths: [MAX_SEARCH_PATHS][]const u8,
    path_count: usize,
    json: bool,
    stats_only: bool,
    hidden: bool,
    line_numbers: bool,
    fixed_strings: bool,
    case_insensitive: bool,
    follow_symlinks: bool,
    max_hits: ?usize,
    threads: ?usize,
    emit_report: ?[]const u8,
};

pub const InspectRequest = struct {
    paths: [MAX_SEARCH_PATHS][]const u8,
    path_count: usize,
    expression: ?[]const u8,
    range: ?[]const u8,
    start_line: ?usize,
    end_line: ?usize,
    limit: ?usize,
    total_count: ?usize,
    skip: ?usize,
    all: bool,
    context: ?usize,
    before_context: ?usize,
    after_context: ?usize,
    hidden: bool,
    follow_symlinks: bool,
    threads: ?usize,
    max_hits: ?usize,
    json: bool,
    format: InspectFormat,
};

pub const InspectFormat = enum {
    grouped,
    records,
    json,
};

pub const ExplainRequest = struct {
    expression: []const u8,
};

pub const Command = union(CommandTag) {
    help: HelpTopic,
    search: SearchRequest,
    matches: SearchRequest,
    inspect: InspectRequest,
    explain: ExplainRequest,
};

pub const Invocation = struct {
    command: Command,
};

pub const ParseError = error{
    MissingCommand,
    MissingExpression,
    MissingValue,
    UnsupportedFlag,
    AmbiguousBooleanRegex,
};

pub fn parseInvocation(allocator: std.mem.Allocator, argv: []const []const u8) !Invocation {
    if (argv.len <= 1) {
        return .{ .command = .{ .help = .top } };
    }

    const first = argv[1];
    if (std.mem.eql(u8, first, "--help") or std.mem.eql(u8, first, "-h") or std.mem.eql(u8, first, "help")) {
        if (argv.len >= 3) return .{ .command = .{ .help = helpTopic(argv[2]) orelse .top } };
        return .{ .command = .{ .help = .top } };
    }
    if (std.mem.eql(u8, first, "search")) {
        if (argv.len >= 3 and isHelpArg(argv[2])) return .{ .command = .{ .help = .search } };
        return .{ .command = .{ .search = try parseSearch(argv[2..]) } };
    }
    if (std.mem.eql(u8, first, "matches")) {
        if (argv.len >= 3 and isHelpArg(argv[2])) return .{ .command = .{ .help = .matches } };
        return .{ .command = .{ .matches = try parseSearch(argv[2..]) } };
    }
    if (std.mem.eql(u8, first, "inspect")) {
        if (argv.len >= 3 and isHelpArg(argv[2])) return .{ .command = .{ .help = .inspect } };
        return .{ .command = .{ .inspect = try parseInspect(argv[2..]) } };
    }
    if (std.mem.eql(u8, first, "explain")) {
        if (argv.len >= 3 and isHelpArg(argv[2])) return .{ .command = .{ .help = .explain } };
        if (argv.len < 3) return ParseError.MissingExpression;
        return .{ .command = .{ .explain = .{ .expression = argv[2] } } };
    }

    return .{ .command = .{ .search = try parseCompatSearch(allocator, argv[1..]) } };
}

fn isHelpArg(arg: []const u8) bool {
    return std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h");
}

fn helpTopic(arg: []const u8) ?HelpTopic {
    if (std.mem.eql(u8, arg, "search")) return .search;
    if (std.mem.eql(u8, arg, "matches")) return .matches;
    if (std.mem.eql(u8, arg, "inspect")) return .inspect;
    if (std.mem.eql(u8, arg, "explain")) return .explain;
    return null;
}

fn parseSearch(args: []const []const u8) ParseError!SearchRequest {
    if (args.len == 0) return ParseError.MissingExpression;
    var request = emptySearchRequest("");
    var expression: ?[]const u8 = null;
    var index: usize = 0;
    while (index < args.len) : (index += 1) {
        const arg = args[index];
        if (!std.mem.startsWith(u8, arg, "-")) {
            if (expression == null) {
                expression = arg;
            } else {
                try pushPath(&request, arg);
            }
            continue;
        }
        if (std.mem.eql(u8, arg, "--json") or std.mem.eql(u8, arg, "-j")) request.json = true else if (std.mem.eql(u8, arg, "--stats-only")) request.stats_only = true else if (std.mem.eql(u8, arg, "--hidden")) request.hidden = true else if (std.mem.eql(u8, arg, "--line-number") or std.mem.eql(u8, arg, "-n")) request.line_numbers = true else if (std.mem.eql(u8, arg, "--fixed-strings") or std.mem.eql(u8, arg, "-F")) request.fixed_strings = true else if (std.mem.eql(u8, arg, "--ignore-case") or std.mem.eql(u8, arg, "-i")) request.case_insensitive = true else if (std.mem.eql(u8, arg, "--follow-symlinks")) request.follow_symlinks = true else if (std.mem.eql(u8, arg, "--max-hits")) {
            index += 1;
            if (index >= args.len) return ParseError.MissingValue;
            request.max_hits = std.fmt.parseInt(usize, args[index], 10) catch return ParseError.MissingValue;
        } else if (std.mem.eql(u8, arg, "--threads") or std.mem.eql(u8, arg, "-t")) {
            index += 1;
            if (index >= args.len) return ParseError.MissingValue;
            request.threads = std.fmt.parseInt(usize, args[index], 10) catch return ParseError.MissingValue;
        } else if (std.mem.eql(u8, arg, "--emit-report")) {
            index += 1;
            if (index >= args.len) return ParseError.MissingValue;
            request.emit_report = args[index];
        } else return ParseError.UnsupportedFlag;
    }
    request.expression = expression orelse return ParseError.MissingExpression;
    return request;
}

fn emptySearchRequest(expression: []const u8) SearchRequest {
    return .{
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
        .max_hits = null,
        .threads = null,
        .emit_report = null,
    };
}

fn pushPath(request: *SearchRequest, path: []const u8) ParseError!void {
    if (request.path_count >= MAX_SEARCH_PATHS) return ParseError.MissingValue;
    request.paths[request.path_count] = path;
    request.path_count += 1;
}

fn parseInspect(args: []const []const u8) ParseError!InspectRequest {
    var request = InspectRequest{
        .paths = undefined,
        .path_count = 0,
        .expression = null,
        .range = null,
        .start_line = null,
        .end_line = null,
        .limit = null,
        .total_count = null,
        .skip = null,
        .all = false,
        .context = null,
        .before_context = null,
        .after_context = null,
        .hidden = false,
        .follow_symlinks = false,
        .threads = null,
        .max_hits = null,
        .json = false,
        .format = .grouped,
    };
    var index: usize = 0;
    while (index < args.len) : (index += 1) {
        const arg = args[index];
        if (std.mem.eql(u8, arg, "--json")) {
            request.json = true;
            request.format = .json;
        } else if (std.mem.eql(u8, arg, "--format")) {
            index += 1;
            if (index >= args.len) return ParseError.MissingValue;
            request.format = parseInspectFormat(args[index]) orelse return ParseError.MissingValue;
            if (request.format == .json) request.json = true;
        } else if (std.mem.eql(u8, arg, "--expr")) {
            index += 1;
            if (index >= args.len) return ParseError.MissingValue;
            request.expression = args[index];
        } else if (std.mem.eql(u8, arg, "--range")) {
            index += 1;
            if (index >= args.len) return ParseError.MissingValue;
            request.range = args[index];
        } else if (std.mem.eql(u8, arg, "--context") or std.mem.eql(u8, arg, "-C")) {
            index += 1;
            if (index >= args.len) return ParseError.MissingValue;
            request.context = std.fmt.parseInt(usize, args[index], 10) catch return ParseError.MissingValue;
        } else if (std.mem.eql(u8, arg, "--before-context") or std.mem.eql(u8, arg, "-B")) {
            index += 1;
            if (index >= args.len) return ParseError.MissingValue;
            request.before_context = std.fmt.parseInt(usize, args[index], 10) catch return ParseError.MissingValue;
        } else if (std.mem.eql(u8, arg, "--after-context") or std.mem.eql(u8, arg, "-A")) {
            index += 1;
            if (index >= args.len) return ParseError.MissingValue;
            request.after_context = std.fmt.parseInt(usize, args[index], 10) catch return ParseError.MissingValue;
        } else if (std.mem.eql(u8, arg, "--start-line")) {
            index += 1;
            if (index >= args.len) return ParseError.MissingValue;
            request.start_line = std.fmt.parseInt(usize, args[index], 10) catch return ParseError.MissingValue;
        } else if (std.mem.eql(u8, arg, "--end-line")) {
            index += 1;
            if (index >= args.len) return ParseError.MissingValue;
            request.end_line = std.fmt.parseInt(usize, args[index], 10) catch return ParseError.MissingValue;
        } else if (std.mem.eql(u8, arg, "--limit")) {
            index += 1;
            if (index >= args.len) return ParseError.MissingValue;
            request.limit = std.fmt.parseInt(usize, args[index], 10) catch return ParseError.MissingValue;
        } else if (std.mem.eql(u8, arg, "--total-count") or std.mem.eql(u8, arg, "--head")) {
            index += 1;
            if (index >= args.len) return ParseError.MissingValue;
            request.total_count = std.fmt.parseInt(usize, args[index], 10) catch return ParseError.MissingValue;
        } else if (std.mem.eql(u8, arg, "--skip")) {
            index += 1;
            if (index >= args.len) return ParseError.MissingValue;
            request.skip = std.fmt.parseInt(usize, args[index], 10) catch return ParseError.MissingValue;
        } else if (std.mem.eql(u8, arg, "--all")) {
            request.all = true;
        } else if (std.mem.eql(u8, arg, "--hidden")) {
            request.hidden = true;
        } else if (std.mem.eql(u8, arg, "--follow-symlinks")) {
            request.follow_symlinks = true;
        } else if (std.mem.eql(u8, arg, "--threads") or std.mem.eql(u8, arg, "-t")) {
            index += 1;
            if (index >= args.len) return ParseError.MissingValue;
            request.threads = std.fmt.parseInt(usize, args[index], 10) catch return ParseError.MissingValue;
        } else if (std.mem.eql(u8, arg, "--max-hits")) {
            index += 1;
            if (index >= args.len) return ParseError.MissingValue;
            request.max_hits = std.fmt.parseInt(usize, args[index], 10) catch return ParseError.MissingValue;
        } else if (std.mem.startsWith(u8, arg, "-")) {
            return ParseError.UnsupportedFlag;
        } else {
            try pushInspectPath(&request, arg);
        }
    }
    return request;
}

fn pushInspectPath(request: *InspectRequest, path: []const u8) ParseError!void {
    if (request.path_count >= MAX_SEARCH_PATHS) return ParseError.MissingValue;
    request.paths[request.path_count] = path;
    request.path_count += 1;
}

fn parseInspectFormat(value: []const u8) ?InspectFormat {
    if (std.mem.eql(u8, value, "grouped")) return .grouped;
    if (std.mem.eql(u8, value, "records")) return .records;
    if (std.mem.eql(u8, value, "json")) return .json;
    return null;
}

fn parseCompatSearch(allocator: std.mem.Allocator, args: []const []const u8) !SearchRequest {
    if (args.len == 0) return ParseError.MissingExpression;
    var expressions: [32][]const u8 = undefined;
    var expression_count: usize = 0;
    var request = emptySearchRequest("");
    var index: usize = 0;
    while (index < args.len) : (index += 1) {
        const arg = args[index];
        if (std.mem.eql(u8, arg, "-e") or std.mem.eql(u8, arg, "--regexp")) {
            index += 1;
            if (index >= args.len) return ParseError.MissingValue;
            if (expression_count >= expressions.len) return ParseError.MissingValue;
            expressions[expression_count] = args[index];
            expression_count += 1;
        } else if (std.mem.startsWith(u8, arg, "-e") and arg.len > 2) {
            if (expression_count >= expressions.len) return ParseError.MissingValue;
            expressions[expression_count] = arg[2..];
            expression_count += 1;
        } else if (std.mem.startsWith(u8, arg, "--regexp=")) {
            if (expression_count >= expressions.len) return ParseError.MissingValue;
            expressions[expression_count] = arg["--regexp=".len..];
            expression_count += 1;
        } else if (std.mem.eql(u8, arg, "--json") or std.mem.eql(u8, arg, "-j")) {
            if (std.mem.eql(u8, arg, "-j")) {
                index += 1;
                if (index >= args.len) return ParseError.MissingValue;
                request.threads = std.fmt.parseInt(usize, args[index], 10) catch return ParseError.MissingValue;
            } else {
                request.json = true;
            }
        } else if (std.mem.startsWith(u8, arg, "-j") and arg.len > 2) {
            request.threads = std.fmt.parseInt(usize, arg[2..], 10) catch return ParseError.MissingValue;
        } else if (std.mem.eql(u8, arg, "--threads")) {
            index += 1;
            if (index >= args.len) return ParseError.MissingValue;
            request.threads = std.fmt.parseInt(usize, args[index], 10) catch return ParseError.MissingValue;
        } else if (std.mem.startsWith(u8, arg, "--threads=")) {
            request.threads = std.fmt.parseInt(usize, arg["--threads=".len..], 10) catch return ParseError.MissingValue;
        } else if (std.mem.eql(u8, arg, "--hidden")) {
            request.hidden = true;
        } else if (std.mem.eql(u8, arg, "--line-number") or std.mem.eql(u8, arg, "-n")) {
            request.line_numbers = true;
        } else if (std.mem.eql(u8, arg, "--fixed-strings") or std.mem.eql(u8, arg, "-F")) {
            request.fixed_strings = true;
        } else if (std.mem.eql(u8, arg, "--ignore-case") or std.mem.eql(u8, arg, "-i")) {
            request.case_insensitive = true;
        } else if (std.mem.startsWith(u8, arg, "-")) {
            return ParseError.UnsupportedFlag;
        } else if (expression_count == 0) {
            expressions[expression_count] = arg;
            expression_count += 1;
        } else {
            try pushPath(&request, arg);
        }
    }
    if (expression_count == 0) return ParseError.MissingExpression;
    request.expression = try materializeCompatExpression(allocator, expressions[0..expression_count], request.fixed_strings, request.case_insensitive);
    if (std.mem.indexOf(u8, request.expression, "&&") != null or std.mem.indexOf(u8, request.expression, "||") != null) {
        if (!std.mem.startsWith(u8, request.expression, "re:")) return ParseError.AmbiguousBooleanRegex;
    }
    return request;
}

fn materializeCompatExpression(allocator: std.mem.Allocator, expressions: []const []const u8, fixed_strings: bool, case_insensitive: bool) ![]const u8 {
    if (expressions.len == 1) return try lowerCompatPattern(allocator, expressions[0], fixed_strings, case_insensitive);
    var list = std.ArrayList(u8).empty;
    errdefer list.deinit(allocator);
    for (expressions, 0..) |expression, index| {
        if (index > 0) try list.appendSlice(allocator, " || ");
        try list.appendSlice(allocator, try lowerCompatPattern(allocator, expression, fixed_strings, case_insensitive));
    }
    return try list.toOwnedSlice(allocator);
}

fn lowerCompatPattern(allocator: std.mem.Allocator, expression: []const u8, fixed_strings: bool, case_insensitive: bool) ![]const u8 {
    if (!fixed_strings and !case_insensitive and isExplicitExpression(expression)) return expression;
    var list = std.ArrayList(u8).empty;
    errdefer list.deinit(allocator);
    if (fixed_strings) {
        const force_regex = case_insensitive or containsBooleanOperator(expression);
        if (force_regex) {
            if (case_insensitive) try list.appendSlice(allocator, "re:(?i)") else try list.appendSlice(allocator, "re:");
        } else {
            try list.appendSlice(allocator, "lit:");
        }
        try appendEscapedLiteral(allocator, &list, expression, force_regex);
    } else {
        try list.appendSlice(allocator, "re:");
        if (case_insensitive) try list.appendSlice(allocator, "(?i)");
        try list.appendSlice(allocator, expression);
    }
    return try list.toOwnedSlice(allocator);
}

fn isExplicitExpression(expression: []const u8) bool {
    return std.mem.startsWith(u8, expression, "re:") or
        std.mem.startsWith(u8, expression, "lit:") or
        std.mem.startsWith(u8, expression, "prefix:") or
        std.mem.startsWith(u8, expression, "suffix:");
}

fn appendEscapedLiteral(allocator: std.mem.Allocator, list: *std.ArrayList(u8), expression: []const u8, force_regex: bool) !void {
    for (expression) |byte| {
        if (force_regex and byte == '&') {
            try list.appendSlice(allocator, "\\x26");
            continue;
        }
        if (force_regex and isRegexMeta(byte)) try list.append(allocator, '\\');
        try list.append(allocator, byte);
    }
}

fn containsBooleanOperator(expression: []const u8) bool {
    return std.mem.indexOf(u8, expression, "&&") != null or std.mem.indexOf(u8, expression, "||") != null;
}

fn isRegexMeta(byte: u8) bool {
    return switch (byte) {
        '.', '*', '+', '?', '^', '$', '|', '(', ')', '[', ']', '{', '}', '\\' => true,
        else => false,
    };
}

test "canonical commands parse before compat lowering" {
    const argv = [_][]const u8{ "ix-zig", "explain", "lit:needle" };
    const invocation = try parseInvocation(std.testing.allocator, &argv);
    try std.testing.expect(invocation.command == .explain);
}
