const std = @import("std");
const command_spec = @import("command_spec.zig");

pub const MAX_SEARCH_PATHS = 128;
pub const MAX_IGNORE_FILES = 32;
pub const MAX_XO_SPANS = 128;

pub const CommandTag = enum {
    help,
    version,
    search,
    matches,
    inspect,
    explain,
    process,
    similar,
    xo,
    why,
    watch,
    replace,
    mcp,
    nexus,
    indexd,
};

pub const HelpTopic = enum {
    top,
    search,
    matches,
    inspect,
    explain,
    process,
    similar,
    xo,
    completions_bash,
    completions_zsh,
    completions_fish,
    completions_powershell,
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
    no_ignore: bool,
    ignore_files: [MAX_IGNORE_FILES][]const u8,
    ignore_file_count: usize,
    max_hits: ?usize,
    threads: ?usize,
    emit_report: ?[]const u8,
    record: RecordGranularity = .line,
    nexus_build: bool,
    nexus_disabled: bool,
    index_enabled: bool,
    output_mode: OutputMode = .normal,
    output_format: OutputFormat = .text,
    context: ?usize = null,
    max_bytes: ?usize = null,
    cursor: ?[]const u8 = null,
    stable_output: bool = false,
    cursor_path: ?[]const u8 = null,
    cursor_line: usize = 0,
    cursor_column: usize = 0,
    cursor_corpus_signature: ?u64 = null,
    cursor_request_fingerprint: ?u64 = null,
    /// P9: Wall-clock time budget in milliseconds. When set, the scan loop
    /// checks elapsed time between files and truncates when exceeded. No false
    /// negatives — all hits discovered before the deadline are emitted; the
    /// sentinel carries status:"truncated" and budget_exceeded:true.
    budget_ms: ?u64 = null,
    /// P9: Pre-execution cost estimate. When set, emits a JSON estimate object
    /// with predicted cost class (instant/fast/moderate/slow) and candidate
    /// counts (if warm index available), then exits without scanning.
    estimate: bool = false,
};

/// P22: Structural record granularity for the --record flag.
/// Controls how matches are grouped and presented.
/// line: one hit per matching line (default, ripgrep-compatible)
/// block: one hit per enclosing brace-block (function body, struct body, etc.)
/// section: one hit per enclosing section (markdown heading, function, class)
pub const RecordGranularity = enum {
    line,
    block,
    section,
    paragraph,
    /// AST-aware granularity requires tree-sitter grammars. Not yet vendored
    /// (violates zero-external-packages invariant until vendored from source).
    /// Accepted at parse time, lowered to `section` as the closest structural
    /// approximation. A query using --record ast gets brace-depth + keyword
    /// boundary deduplication, which covers the common case (function bodies,
    /// class blocks) without the full grammar tree.
    ast,
};

/// Adjacent Operations Vector output modes (spec point 29).
/// normal: hit records with line/column/preview.
/// files_with_matches: unique file paths, no bodies (-l / --files-with-matches).
/// count: per-file match cardinality (-c / --count).
pub const OutputMode = enum {
    normal,
    files_with_matches,
    count,
};

/// Output format selector. Controls the serialization shape of search results.
/// default: hit records + ix.result.v1 sentinel (ripgrep-compatible)
/// agent: ix.result.v2 compact grouped format (LLM-optimized, token-minimal)
pub const OutputFormat = command_spec.OutputFormat;

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

pub const IndexdRequest = struct {
    root: []const u8,
    foreground: bool,
    once: bool,
    repair: bool,
    serve: bool = false,
};

pub const ProcessAction = enum {
    status,
    cleanup,
};

pub const ProcessRequest = struct {
    action: ProcessAction,
    json: bool,
    dry_run: bool,
};

pub const SimilarRequest = struct {
    query: ?[]const u8,
    paths: [MAX_SEARCH_PATHS][]const u8,
    path_count: usize,
    anti: bool,
    json: bool,
    max_results: usize,
    output_format: OutputFormat = .text,
    candidate_budget: usize = 512,
    cursor: ?[]const u8 = null,
    cursor_ordinal: usize = 0,
    cursor_corpus_signature: ?u64 = null,
    cursor_request_fingerprint: ?u64 = null,
    /// P9: Wall-clock time budget in milliseconds. When set, the scan loop
    /// checks elapsed time between files and truncates when exceeded. No false
    /// negatives — all hits discovered before the deadline are emitted; the
    /// sentinel carries status:"truncated" and budget_exceeded:true.
    budget_ms: ?u64 = null,
    /// P9: Pre-execution cost estimate. When set, emits a JSON estimate object
    /// with predicted cost class (instant/fast/moderate/slow) and candidate
    /// counts (if warm index available), then exits without scanning.
    estimate: bool = false,
};

pub const XoFormat = enum { grouped, json };

pub const XoRequest = struct {
    query: []const u8,
    paths: [MAX_SEARCH_PATHS][]const u8,
    path_count: usize,
    max_bytes: usize = 8000,
    max_spans: usize = 12,
    format: XoFormat = .grouped,
};

pub const Command = union(CommandTag) {
    help: HelpTopic,
    version: void,
    search: SearchRequest,
    matches: SearchRequest,
    inspect: InspectRequest,
    explain: ExplainRequest,
    process: ProcessRequest,
    similar: SimilarRequest,
    xo: XoRequest,
    why: WhyRequest,
    watch: SearchRequest,
    replace: ReplaceRequest,
    mcp: McpRequest,
    nexus: SearchRequest,
    indexd: IndexdRequest,
};

pub const McpRequest = struct {
    transport: McpTransport = .stdio,
};

pub const McpTransport = enum {
    stdio,
};

/// P29: Adjacent Operations Vector — 'why' command.
/// Traces a match to its posting-list lineage: which trigram evidence caused
/// a file to be admitted as a candidate, the per-gram file count, and the
/// intersection result. This makes the sub-linear pruning pipeline
/// transparent to the consumer.
pub const WhyRequest = struct {
    expression: []const u8,
    paths: [MAX_SEARCH_PATHS][]const u8,
    path_count: usize,
    json: bool = false,
};

/// P29: Adjacent Operations Vector — 'replace' command.
/// Performs indexed structural rewrites: finds literal matches in files
/// and replaces them with a replacement string. Uses --dry-run to preview
/// changes without writing. Requires explicit confirmation by default.
pub const ReplaceRequest = struct {
    pattern: []const u8,
    replacement: []const u8,
    paths: [MAX_SEARCH_PATHS][]const u8,
    path_count: usize,
    dry_run: bool = false,
    json: bool = false,
};

pub const Invocation = struct {
    command: Command,
};

pub const ParseError = error{
    MissingCommand,
    MissingExpression,
    MissingValue,
    UnsupportedFlag,
    ConflictingOutputFormat,
    StatsOnlyOutputCapConflict,
    AmbiguousBooleanRegex,
};

pub const ParseFailureDetail = struct {
    argument: ?[]const u8 = null,
    hint: ?[]const u8 = null,
};

/// Recovers the exact rejected token from the canonical command specification.
pub fn diagnoseParseFailure(argv: []const []const u8, err: anyerror) ParseFailureDetail {
    if (err == ParseError.ConflictingOutputFormat) return .{
        .hint = "choose one output format; --json may combine only with --stats-only",
    };
    if (err == ParseError.StatsOnlyOutputCapConflict) return .{
        .hint = "remove --total-count/--max-hits for a complete stats-only scan, or remove --stats-only for a bounded projection",
    };
    if (err != ParseError.UnsupportedFlag or argv.len < 2) return .{};
    const is_search = std.mem.eql(u8, argv[1], "search");
    const is_matches = std.mem.eql(u8, argv[1], "matches");
    if (!is_search and !is_matches) return .{ .hint = "run ix help <command> to list accepted options" };
    var index: usize = 2;
    while (index < argv.len) : (index += 1) {
        const argument = argv[index];
        if (!std.mem.startsWith(u8, argument, "-")) continue;
        const spec = command_spec.findSearchOption(argument, is_search) orelse return .{
            .argument = argument,
            .hint = if (is_search) "run ix help search to list accepted options" else "run ix help matches to list accepted options",
        };
        if (std.mem.eql(u8, argument, "--format") and index + 1 < argv.len) {
            const value = argv[index + 1];
            if (command_spec.parseFormat(value) == null) return .{
                .argument = value,
                .hint = "use --format with a value listed by ix help search",
            };
        }
        if (spec.takes_value and index + 1 < argv.len) index += 1;
    }
    return .{ .hint = "run ix help <command> to review accepted option combinations" };
}

pub fn parseInvocation(allocator: std.mem.Allocator, argv: []const []const u8) !Invocation {
    if (argv.len <= 1) {
        return .{ .command = .{ .help = .top } };
    }

    const first = argv[1];
    if (std.mem.eql(u8, first, "--help") or std.mem.eql(u8, first, "-h") or std.mem.eql(u8, first, "help")) {
        if (argv.len >= 3) return .{ .command = .{ .help = helpTopic(argv[2]) orelse .top } };
        return .{ .command = .{ .help = .top } };
    }
    if (std.mem.eql(u8, first, "--completions")) {
        const shell = if (argv.len >= 3) argv[2] else "bash";
        if (std.mem.eql(u8, shell, "bash")) return .{ .command = .{ .help = .completions_bash } };
        if (std.mem.eql(u8, shell, "zsh")) return .{ .command = .{ .help = .completions_zsh } };
        if (std.mem.eql(u8, shell, "fish")) return .{ .command = .{ .help = .completions_fish } };
        if (std.mem.eql(u8, shell, "powershell") or std.mem.eql(u8, shell, "pwsh")) return .{ .command = .{ .help = .completions_powershell } };
        return .{ .command = .{ .help = .completions_bash } };
    }
    if (std.mem.eql(u8, first, "--version") or std.mem.eql(u8, first, "-V") or std.mem.eql(u8, first, "version")) {
        return .{ .command = .{ .version = {} } };
    }
    if (std.mem.eql(u8, first, "search")) {
        if (argv.len >= 3 and isHelpArg(argv[2])) return .{ .command = .{ .help = .search } };
        return .{ .command = .{ .search = try parseSearch(argv[2..]) } };
    }
    if (std.mem.eql(u8, first, "matches")) {
        if (argv.len >= 3 and isHelpArg(argv[2])) return .{ .command = .{ .help = .matches } };
        return .{ .command = .{ .matches = try parseMatches(argv[2..]) } };
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
    if (std.mem.eql(u8, first, "process")) {
        if (argv.len >= 3 and isHelpArg(argv[2])) return .{ .command = .{ .help = .process } };
        return .{ .command = .{ .process = try parseProcess(argv[2..]) } };
    }
    if (std.mem.eql(u8, first, "similar")) {
        if (argv.len >= 3 and isHelpArg(argv[2])) return .{ .command = .{ .help = .similar } };
        return .{ .command = .{ .similar = try parseSimilar(argv[2..]) } };
    }
    if (std.mem.eql(u8, first, "xo")) {
        if (argv.len >= 3 and isHelpArg(argv[2])) return .{ .command = .{ .help = .xo } };
        return .{ .command = .{ .xo = try parseXo(argv[2..]) } };
    }
    if (std.mem.eql(u8, first, "why")) {
        if (argv.len >= 3 and isHelpArg(argv[2])) return .{ .command = .{ .help = .explain } };
        return .{ .command = .{ .why = try parseWhy(argv[2..]) } };
    }
    if (std.mem.eql(u8, first, "watch")) {
        if (argv.len >= 3 and isHelpArg(argv[2])) return .{ .command = .{ .help = .search } };
        return .{ .command = .{ .watch = try parseSearch(argv[2..]) } };
    }
    if (std.mem.eql(u8, first, "replace")) {
        if (argv.len >= 3 and isHelpArg(argv[2])) return .{ .command = .{ .help = .search } };
        return .{ .command = .{ .replace = try parseReplace(argv[2..]) } };
    }
    if (std.mem.eql(u8, first, "mcp")) {
        return .{ .command = .{ .mcp = .{} } };
    }
    if (std.mem.eql(u8, first, "__ix_nexus")) {
        var request = try parseSearch(argv[2..]);
        request.stats_only = true;
        request.json = true;
        request.nexus_build = true;
        return .{ .command = .{ .nexus = request } };
    }
    if (std.mem.eql(u8, first, "__ix_indexd")) {
        return .{ .command = .{ .indexd = try parseIndexd(argv[2..]) } };
    }

    return .{ .command = .{ .search = try parseCompatSearch(allocator, argv[1..]) } };
}

/// Keeps the record-only command from accepting projections that require a terminal envelope.
fn parseMatches(args: []const []const u8) ParseError!SearchRequest {
    const request = try parseSearch(args);
    if (request.context != null or request.max_bytes != null or request.cursor != null) return ParseError.UnsupportedFlag;
    switch (request.output_format) {
        .agent_v2, .agent_v3, .stats => return ParseError.UnsupportedFlag,
        else => return request,
    }
}

fn isHelpArg(arg: []const u8) bool {
    return std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h");
}

fn helpTopic(arg: []const u8) ?HelpTopic {
    if (std.mem.eql(u8, arg, "search")) return .search;
    if (std.mem.eql(u8, arg, "matches")) return .matches;
    if (std.mem.eql(u8, arg, "inspect")) return .inspect;
    if (std.mem.eql(u8, arg, "explain")) return .explain;
    if (std.mem.eql(u8, arg, "process")) return .process;
    if (std.mem.eql(u8, arg, "similar")) return .similar;
    if (std.mem.eql(u8, arg, "xo")) return .xo;
    return null;
}

fn parseProcess(args: []const []const u8) ParseError!ProcessRequest {
    var request = ProcessRequest{
        .action = .status,
        .json = false,
        .dry_run = false,
    };
    var action_seen = false;
    for (args) |arg| {
        if (std.mem.eql(u8, arg, "status")) {
            request.action = .status;
            action_seen = true;
        } else if (std.mem.eql(u8, arg, "cleanup")) {
            request.action = .cleanup;
            action_seen = true;
        } else if (std.mem.eql(u8, arg, "--json")) {
            request.json = true;
        } else if (std.mem.eql(u8, arg, "--dry-run")) {
            request.dry_run = true;
        } else if (std.mem.startsWith(u8, arg, "-")) {
            return ParseError.UnsupportedFlag;
        } else {
            return ParseError.MissingValue;
        }
    }
    if (!action_seen and args.len != 0) return ParseError.MissingValue;
    return request;
}

fn parseSimilar(args: []const []const u8) ParseError!SimilarRequest {
    var request = SimilarRequest{
        .query = null,
        .paths = undefined,
        .path_count = 0,
        .anti = false,
        .json = false,
        .max_results = 20,
        .output_format = .text,
    };
    var index: usize = 0;
    while (index < args.len) : (index += 1) {
        const arg = args[index];
        if (std.mem.eql(u8, arg, "--anti")) {
            request.anti = true;
        } else if (std.mem.eql(u8, arg, "--json")) {
            try selectSimilarOutputFormat(&request, .json);
        } else if (std.mem.eql(u8, arg, "--agent")) {
            try selectSimilarOutputFormat(&request, .agent_v2);
        } else if (std.mem.eql(u8, arg, "--format")) {
            index += 1;
            if (index >= args.len) return ParseError.MissingValue;
            try selectSimilarOutputFormat(&request, command_spec.parseFormat(args[index]) orelse return ParseError.UnsupportedFlag);
        } else if (std.mem.eql(u8, arg, "--max-results")) {
            index += 1;
            if (index >= args.len) return ParseError.MissingValue;
            request.max_results = std.fmt.parseInt(usize, args[index], 10) catch return ParseError.MissingValue;
            if (request.max_results == 0) return ParseError.MissingValue;
        } else if (std.mem.startsWith(u8, arg, "--max-results=")) {
            request.max_results = std.fmt.parseInt(usize, arg["--max-results=".len..], 10) catch return ParseError.MissingValue;
            if (request.max_results == 0) return ParseError.MissingValue;
        } else if (std.mem.eql(u8, arg, "--candidate-budget")) {
            index += 1;
            if (index >= args.len) return ParseError.MissingValue;
            request.candidate_budget = std.fmt.parseInt(usize, args[index], 10) catch return ParseError.MissingValue;
            if (request.candidate_budget == 0) return ParseError.MissingValue;
        } else if (std.mem.eql(u8, arg, "--cursor")) {
            index += 1;
            if (index >= args.len or args[index].len == 0) return ParseError.MissingValue;
            request.cursor = args[index];
        } else if (std.mem.startsWith(u8, arg, "-")) {
            return ParseError.UnsupportedFlag;
        } else {
            // First non-flag arg is the query (text concept or file path).
            // Remaining non-flag args are candidate paths.
            if (request.query == null) {
                request.query = arg;
            } else {
                if (request.path_count >= MAX_SEARCH_PATHS) return ParseError.MissingValue;
                request.paths[request.path_count] = normalizePathArgument(arg);
                request.path_count += 1;
            }
        }
    }
    if (request.query == null) return ParseError.MissingValue;
    if (request.path_count == 0) return ParseError.MissingValue;
    if (request.cursor != null and request.output_format == .text) request.output_format = .agent_v3;
    if (request.cursor != null and request.output_format != .agent_v3 and request.output_format != .json_compact) return ParseError.ConflictingOutputFormat;
    return request;
}

/// Parses the bounded insight lane independently from exact search and inspect grammars.
fn parseXo(args: []const []const u8) ParseError!XoRequest {
    if (args.len == 0) return ParseError.MissingExpression;
    var request = XoRequest{ .query = "", .paths = undefined, .path_count = 0 };
    var index: usize = 0;
    while (index < args.len) : (index += 1) {
        const arg = args[index];
        if (std.mem.eql(u8, arg, "--json")) {
            request.format = .json;
        } else if (std.mem.eql(u8, arg, "--format")) {
            index += 1;
            if (index >= args.len) return ParseError.MissingValue;
            if (std.mem.eql(u8, args[index], "grouped")) request.format = .grouped else if (std.mem.eql(u8, args[index], "json")) request.format = .json else return ParseError.UnsupportedFlag;
        } else if (std.mem.eql(u8, arg, "--max-bytes")) {
            index += 1;
            if (index >= args.len) return ParseError.MissingValue;
            request.max_bytes = std.fmt.parseInt(usize, args[index], 10) catch return ParseError.MissingValue;
            if (request.max_bytes == 0) return ParseError.MissingValue;
        } else if (std.mem.startsWith(u8, arg, "--max-bytes=")) {
            request.max_bytes = std.fmt.parseInt(usize, arg["--max-bytes=".len..], 10) catch return ParseError.MissingValue;
            if (request.max_bytes == 0) return ParseError.MissingValue;
        } else if (std.mem.eql(u8, arg, "--max-spans")) {
            index += 1;
            if (index >= args.len) return ParseError.MissingValue;
            request.max_spans = std.fmt.parseInt(usize, args[index], 10) catch return ParseError.MissingValue;
            if (request.max_spans == 0 or request.max_spans > MAX_XO_SPANS) return ParseError.MissingValue;
        } else if (std.mem.startsWith(u8, arg, "--max-spans=")) {
            request.max_spans = std.fmt.parseInt(usize, arg["--max-spans=".len..], 10) catch return ParseError.MissingValue;
            if (request.max_spans == 0 or request.max_spans > MAX_XO_SPANS) return ParseError.MissingValue;
        } else if (std.mem.startsWith(u8, arg, "-")) {
            return ParseError.UnsupportedFlag;
        } else if (request.query.len == 0) {
            request.query = arg;
        } else {
            if (request.path_count >= MAX_SEARCH_PATHS) return ParseError.MissingValue;
            request.paths[request.path_count] = normalizePathArgument(arg);
            request.path_count += 1;
        }
    }
    if (request.query.len == 0 or request.path_count == 0) return ParseError.MissingValue;
    return request;
}

fn parseWhy(args: []const []const u8) ParseError!WhyRequest {
    if (args.len == 0) return ParseError.MissingExpression;
    var expression: ?[]const u8 = null;
    var request = WhyRequest{ .expression = "", .paths = undefined, .path_count = 0 };
    for (args) |arg| {
        if (std.mem.eql(u8, arg, "--json")) {
            request.json = true;
        } else if (!std.mem.startsWith(u8, arg, "-")) {
            if (expression == null) {
                expression = arg;
            } else {
                if (request.path_count >= MAX_SEARCH_PATHS) return ParseError.MissingValue;
                request.paths[request.path_count] = arg;
                request.path_count += 1;
            }
        } else return ParseError.UnsupportedFlag;
    }
    request.expression = expression orelse return ParseError.MissingExpression;
    if (request.path_count == 0) return ParseError.MissingValue;
    return request;
}

fn parseReplace(args: []const []const u8) ParseError!ReplaceRequest {
    if (args.len == 0) return ParseError.MissingExpression;
    var pattern: ?[]const u8 = null;
    var replacement: ?[]const u8 = null;
    var request = ReplaceRequest{
        .pattern = "",
        .replacement = "",
        .paths = undefined,
        .path_count = 0,
    };
    for (args) |arg| {
        if (std.mem.eql(u8, arg, "--dry-run")) {
            request.dry_run = true;
        } else if (std.mem.eql(u8, arg, "--json")) {
            request.json = true;
        } else if (!std.mem.startsWith(u8, arg, "-")) {
            if (pattern == null) {
                pattern = arg;
            } else if (replacement == null) {
                replacement = arg;
            } else {
                if (request.path_count >= MAX_SEARCH_PATHS) return ParseError.MissingValue;
                request.paths[request.path_count] = arg;
                request.path_count += 1;
            }
        } else return ParseError.UnsupportedFlag;
    }
    request.pattern = pattern orelse return ParseError.MissingExpression;
    request.replacement = replacement orelse return ParseError.MissingValue;
    if (request.path_count == 0) return ParseError.MissingValue;
    return request;
}

/// Keeps the semantic lane's compatibility formats explicit while reusing the public format vocabulary.
fn selectSimilarOutputFormat(request: *SimilarRequest, format: OutputFormat) ParseError!void {
    switch (format) {
        .text, .agent_v2, .agent_v3, .json, .json_compact => {},
        else => return ParseError.UnsupportedFlag,
    }
    if (request.output_format != .text and request.output_format != format) return ParseError.ConflictingOutputFormat;
    request.output_format = format;
    request.json = format == .json or format == .json_compact;
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
        if (std.mem.eql(u8, arg, "--json") or std.mem.eql(u8, arg, "-j")) {
            try selectOutputFormat(&request, .json);
        } else if (std.mem.eql(u8, arg, "--stats-only")) {
            try selectOutputFormat(&request, .stats);
        } else if (std.mem.eql(u8, arg, "--agent")) {
            try selectOutputFormat(&request, .agent_v2);
        } else if (std.mem.eql(u8, arg, "--format")) {
            index += 1;
            if (index >= args.len) return ParseError.MissingValue;
            try selectOutputFormat(&request, command_spec.parseFormat(args[index]) orelse return ParseError.UnsupportedFlag);
        } else if (std.mem.eql(u8, arg, "--files-with-matches") or std.mem.eql(u8, arg, "-l")) {
            try selectOutputFormat(&request, .files);
        } else if (std.mem.eql(u8, arg, "--count") or std.mem.eql(u8, arg, "-c")) {
            try selectOutputFormat(&request, .count);
        } else if (std.mem.eql(u8, arg, "--hidden")) request.hidden = true else if (std.mem.eql(u8, arg, "--no-ignore")) request.no_ignore = true else if (std.mem.eql(u8, arg, "--unrestricted") or std.mem.eql(u8, arg, "-u")) {
            request.hidden = true;
            request.no_ignore = true;
        } else if (std.mem.eql(u8, arg, "--ignore-file")) {
            index += 1;
            if (index >= args.len) return ParseError.MissingValue;
            request.no_ignore = false;
            try pushIgnoreFile(&request, args[index]);
        } else if (std.mem.eql(u8, arg, "--line-number") or std.mem.eql(u8, arg, "-n")) {
            try parseLineNumberLimit(args, &index, &request);
        } else if (std.mem.eql(u8, arg, "--fixed-strings") or std.mem.eql(u8, arg, "-F")) request.fixed_strings = true else if (std.mem.eql(u8, arg, "--ignore-case") or std.mem.eql(u8, arg, "-i")) request.case_insensitive = true else if (std.mem.eql(u8, arg, "--follow-symlinks")) request.follow_symlinks = true else if (std.mem.eql(u8, arg, "--max-hits") or std.mem.eql(u8, arg, "--total-count")) {
            index += 1;
            if (index >= args.len) return ParseError.MissingValue;
            request.max_hits = std.fmt.parseInt(usize, args[index], 10) catch return ParseError.MissingValue;
            if (request.max_hits.? == 0) return ParseError.MissingValue;
        } else if (std.mem.eql(u8, arg, "--threads") or std.mem.eql(u8, arg, "-t")) {
            index += 1;
            if (index >= args.len) return ParseError.MissingValue;
            request.threads = std.fmt.parseInt(usize, args[index], 10) catch return ParseError.MissingValue;
        } else if (std.mem.eql(u8, arg, "--emit-report")) {
            index += 1;
            if (index >= args.len) return ParseError.MissingValue;
            request.emit_report = args[index];
        } else if (std.mem.eql(u8, arg, "--context")) {
            index += 1;
            if (index >= args.len) return ParseError.MissingValue;
            request.context = std.fmt.parseInt(usize, args[index], 10) catch return ParseError.MissingValue;
        } else if (std.mem.eql(u8, arg, "--max-bytes")) {
            index += 1;
            if (index >= args.len) return ParseError.MissingValue;
            request.max_bytes = std.fmt.parseInt(usize, args[index], 10) catch return ParseError.MissingValue;
            if (request.max_bytes.? == 0) return ParseError.MissingValue;
        } else if (std.mem.eql(u8, arg, "--cursor")) {
            index += 1;
            if (index >= args.len or args[index].len == 0) return ParseError.MissingValue;
            request.cursor = args[index];
        } else if (std.mem.eql(u8, arg, "--record")) {
            index += 1;
            if (index >= args.len) return ParseError.MissingValue;
            if (std.mem.eql(u8, args[index], "line")) {
                request.record = .line;
            } else if (std.mem.eql(u8, args[index], "block")) {
                request.record = .block;
            } else if (std.mem.eql(u8, args[index], "section")) {
                request.record = .section;
            } else if (std.mem.eql(u8, args[index], "paragraph")) {
                request.record = .paragraph;
            } else if (std.mem.eql(u8, args[index], "ast")) {
                request.record = .ast;
            } else return ParseError.UnsupportedFlag;
        } else if (std.mem.eql(u8, arg, "--budget-ms")) {
            index += 1;
            if (index >= args.len) return ParseError.MissingValue;
            request.budget_ms = std.fmt.parseInt(u64, args[index], 10) catch return ParseError.MissingValue;
            if (request.budget_ms.? == 0) return ParseError.MissingValue;
        } else if (std.mem.eql(u8, arg, "--estimate")) {
            request.estimate = true;
        } else return ParseError.UnsupportedFlag;
    }
    request.expression = expression orelse return ParseError.MissingExpression;
    if (request.context != null) {
        request.output_format = switch (request.output_format) {
            .text, .agent_v2 => .agent_v3,
            .json => .json_compact,
            else => request.output_format,
        };
    }
    if (request.max_bytes != null or request.cursor != null) {
        if (request.output_format == .text) request.output_format = .agent_v3;
        if (request.output_format != .agent_v3 and request.output_format != .json_compact) return ParseError.ConflictingOutputFormat;
    }
    // Stats-only is a complete-count projection. A hit cap would stop the
    // scanner early and turn an exact count into an unlabeled lower bound.
    if (request.stats_only and request.max_hits != null) return ParseError.StatsOnlyOutputCapConflict;
    request.stable_output = request.output_format == .agent_v3 or request.output_format == .json_compact;
    return request;
}

fn parseIndexd(args: []const []const u8) ParseError!IndexdRequest {
    var request = IndexdRequest{
        .root = ".",
        .foreground = false,
        .once = false,
        .repair = false,
    };
    var root_seen = false;
    for (args) |arg| {
        if (std.mem.eql(u8, arg, "--foreground")) {
            request.foreground = true;
        } else if (std.mem.eql(u8, arg, "--once")) {
            request.once = true;
        } else if (std.mem.eql(u8, arg, "--serve")) {
            request.serve = true;
            request.foreground = true;
        } else if (std.mem.eql(u8, arg, "--repair")) {
            request.repair = true;
        } else if (std.mem.startsWith(u8, arg, "-")) {
            return ParseError.UnsupportedFlag;
        } else {
            if (root_seen) return ParseError.MissingValue;
            request.root = arg;
            root_seen = true;
        }
    }
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
        .no_ignore = true,
        .ignore_files = undefined,
        .ignore_file_count = 0,
        .max_hits = null,
        .threads = null,
        .emit_report = null,
        .nexus_build = false,
        .nexus_disabled = false,
        .index_enabled = false,
    };
}

/// Lowers every legacy selector into one format and rejects ambiguous writer policy.
fn selectOutputFormat(request: *SearchRequest, format: OutputFormat) ParseError!void {
    if ((request.output_format == .json and format == .stats) or
        (request.output_format == .stats and format == .json))
    {
        request.output_format = .json;
        request.json = true;
        request.stats_only = true;
        request.output_mode = .normal;
        return;
    }
    const selected = format;
    if (request.output_format != .text and request.output_format != selected) return ParseError.ConflictingOutputFormat;
    request.output_format = selected;
    request.json = selected == .json or selected == .json_compact;
    request.stats_only = selected == .stats;
    request.output_mode = switch (selected) {
        .files => .files_with_matches,
        .count => .count,
        else => .normal,
    };
}

fn pushPath(request: *SearchRequest, path: []const u8) ParseError!void {
    if (request.path_count >= MAX_SEARCH_PATHS) return ParseError.MissingValue;
    request.paths[request.path_count] = normalizePathArgument(path);
    request.path_count += 1;
}

/// Canonicalizes the shell's equivalent relative-root spellings once at the CLI boundary.
fn normalizePathArgument(path: []const u8) []const u8 {
    var normalized = path;
    while (normalized.len >= 2 and normalized[0] == '.' and (normalized[1] == '/' or normalized[1] == '\\')) {
        normalized = normalized[2..];
    }
    return if (normalized.len == 0) "." else normalized;
}

fn pushIgnoreFile(request: *SearchRequest, path: []const u8) ParseError!void {
    if (request.ignore_file_count >= MAX_IGNORE_FILES) return ParseError.MissingValue;
    request.ignore_files[request.ignore_file_count] = path;
    request.ignore_file_count += 1;
}

fn parseLineNumberLimit(args: []const []const u8, index: *usize, request: *SearchRequest) ParseError!void {
    request.line_numbers = true;
    const next_index = index.* + 1;
    if (next_index >= args.len or request.max_hits != null or !isUnsignedDecimal(args[next_index])) return;
    request.max_hits = std.fmt.parseInt(usize, args[next_index], 10) catch return ParseError.MissingValue;
    if (request.max_hits.? == 0) return ParseError.MissingValue;
    index.* = next_index;
}

fn isUnsignedDecimal(value: []const u8) bool {
    if (value.len == 0) return false;
    for (value) |byte| {
        if (byte < '0' or byte > '9') return false;
    }
    return true;
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
    request.paths[request.path_count] = normalizePathArgument(path);
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
                try selectOutputFormat(&request, .json);
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
        } else if (std.mem.eql(u8, arg, "--no-ignore")) {
            request.no_ignore = true;
        } else if (std.mem.eql(u8, arg, "--unrestricted") or std.mem.eql(u8, arg, "-u")) {
            request.hidden = true;
            request.no_ignore = true;
        } else if (std.mem.eql(u8, arg, "--ignore-file")) {
            index += 1;
            if (index >= args.len) return ParseError.MissingValue;
            request.no_ignore = false;
            try pushIgnoreFile(&request, args[index]);
        } else if (std.mem.eql(u8, arg, "--line-number") or std.mem.eql(u8, arg, "-n")) {
            try parseLineNumberLimit(args, &index, &request);
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
    // For explicit IX-native expressions (lit:, prefix:, suffix:) with case_insensitive,
    // convert to re:(?i) with the value extracted (not the prefix re-wrapped as a regex body).
    if (!fixed_strings and case_insensitive) {
        if (std.mem.startsWith(u8, expression, "lit:")) {
            return try std.fmt.allocPrint(allocator, "re:(?i){s}", .{expression[4..]});
        }
        if (std.mem.startsWith(u8, expression, "prefix:")) {
            return try std.fmt.allocPrint(allocator, "re:(?i)^{s}", .{expression[7..]});
        }
        if (std.mem.startsWith(u8, expression, "suffix:")) {
            return try std.fmt.allocPrint(allocator, "re:(?i){s}$", .{expression[7..]});
        }
    }
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

test "hidden nexus command forces silent stats json build mode" {
    const argv = [_][]const u8{
        "ix-zig",
        "__ix_nexus",
        "re:\\bPM_RESUME\\b",
        "src",
        "--hidden",
        "--follow-symlinks",
        "--threads",
        "7",
    };
    const invocation = try parseInvocation(std.testing.allocator, &argv);
    try std.testing.expect(invocation.command == .nexus);
    const request = invocation.command.nexus;
    try std.testing.expectEqualStrings("re:\\bPM_RESUME\\b", request.expression);
    try std.testing.expectEqual(@as(usize, 1), request.path_count);
    try std.testing.expectEqualStrings("src", request.paths[0]);
    try std.testing.expect(request.stats_only);
    try std.testing.expect(request.json);
    try std.testing.expect(request.nexus_build);
    try std.testing.expect(request.hidden);
    try std.testing.expect(request.follow_symlinks);
    try std.testing.expectEqual(@as(?usize, 7), request.threads);
}

test "search admission flags parse into one deterministic contract" {
    const argv = [_][]const u8{
        "ix-zig",
        "search",
        "--ignore-file",
        "extra.ignore",
        "--unrestricted",
        "lit:needle",
        "src",
    };
    const invocation = try parseInvocation(std.testing.allocator, &argv);
    try std.testing.expect(invocation.command == .search);
    const request = invocation.command.search;
    try std.testing.expect(request.hidden);
    try std.testing.expect(request.no_ignore);
    try std.testing.expectEqual(@as(usize, 1), request.ignore_file_count);
    try std.testing.expectEqualStrings("extra.ignore", request.ignore_files[0]);
    try std.testing.expectEqual(@as(usize, 1), request.path_count);
    try std.testing.expectEqualStrings("src", request.paths[0]);
}

test "search defaults preserve explicit no-ignore discovery" {
    const argv = [_][]const u8{
        "ix-zig",
        "search",
        "lit:needle",
        "src",
    };
    const invocation = try parseInvocation(std.testing.allocator, &argv);
    try std.testing.expect(invocation.command == .search);
    const request = invocation.command.search;
    try std.testing.expect(request.no_ignore);
    try std.testing.expect(!request.hidden);
}

test "search accepts agent line-number limit shorthand without treating the number as a path" {
    const argv = [_][]const u8{
        "ix-zig",
        "search",
        "lit:needle",
        "src",
        "-n",
        "80",
    };
    const invocation = try parseInvocation(std.testing.allocator, &argv);
    try std.testing.expect(invocation.command == .search);
    const request = invocation.command.search;
    try std.testing.expect(request.line_numbers);
    try std.testing.expectEqual(@as(?usize, 80), request.max_hits);
    try std.testing.expectEqual(@as(usize, 1), request.path_count);
    try std.testing.expectEqualStrings("src", request.paths[0]);
}

test "compat admission flags preserve rg-shaped entrypoint" {
    const argv = [_][]const u8{
        "ix-zig",
        "--ignore-file",
        "extra.ignore",
        "--no-ignore",
        "needle",
        "src",
    };
    const invocation = try parseInvocation(std.testing.allocator, &argv);
    try std.testing.expect(invocation.command == .search);
    const request = invocation.command.search;
    defer std.testing.allocator.free(request.expression);
    try std.testing.expect(request.no_ignore);
    try std.testing.expectEqual(@as(usize, 1), request.ignore_file_count);
    try std.testing.expectEqualStrings("extra.ignore", request.ignore_files[0]);
}

test "compat defaults preserve explicit no-ignore discovery" {
    const argv = [_][]const u8{
        "ix-zig",
        "needle",
        "src",
    };
    const invocation = try parseInvocation(std.testing.allocator, &argv);
    try std.testing.expect(invocation.command == .search);
    const request = invocation.command.search;
    defer std.testing.allocator.free(request.expression);
    try std.testing.expect(request.no_ignore);
    try std.testing.expect(!request.hidden);
}

test "compat search accepts agent line-number limit shorthand without treating the number as a path" {
    const argv = [_][]const u8{
        "ix-zig",
        "needle",
        "src",
        "-n",
        "80",
    };
    const invocation = try parseInvocation(std.testing.allocator, &argv);
    try std.testing.expect(invocation.command == .search);
    const request = invocation.command.search;
    defer std.testing.allocator.free(request.expression);
    try std.testing.expect(request.line_numbers);
    try std.testing.expectEqual(@as(?usize, 80), request.max_hits);
    try std.testing.expectEqual(@as(usize, 1), request.path_count);
    try std.testing.expectEqualStrings("src", request.paths[0]);
}

test "hidden indexd command parses without public command exposure" {
    const argv = [_][]const u8{
        "ix-zig",
        "__ix_indexd",
        "E:\\Workspaces\\01_Projects\\01_Github\\ix-zig",
        "--foreground",
        "--once",
        "--repair",
    };
    const invocation = try parseInvocation(std.testing.allocator, &argv);
    try std.testing.expect(invocation.command == .indexd);
    const request = invocation.command.indexd;
    try std.testing.expectEqualStrings("E:\\Workspaces\\01_Projects\\01_Github\\ix-zig", request.root);
    try std.testing.expect(request.foreground);
    try std.testing.expect(request.once);
    try std.testing.expect(request.repair);
}

test "hidden indexd command rejects unsupported lifecycle flags and duplicate roots" {
    const bad_flag = [_][]const u8{
        "ix-zig",
        "__ix_indexd",
        ".",
        "--verbose",
    };
    try std.testing.expectError(ParseError.UnsupportedFlag, parseInvocation(std.testing.allocator, &bad_flag));

    const duplicate_root = [_][]const u8{
        "ix-zig",
        "__ix_indexd",
        ".",
        "src",
    };
    try std.testing.expectError(ParseError.MissingValue, parseInvocation(std.testing.allocator, &duplicate_root));
}

test "process command parses status and cleanup flags" {
    const status_argv = [_][]const u8{
        "ix-zig",
        "process",
        "status",
        "--json",
    };
    const status_invocation = try parseInvocation(std.testing.allocator, &status_argv);
    try std.testing.expect(status_invocation.command == .process);
    try std.testing.expectEqual(.status, status_invocation.command.process.action);
    try std.testing.expect(status_invocation.command.process.json);

    const cleanup_argv = [_][]const u8{
        "ix-zig",
        "process",
        "cleanup",
        "--dry-run",
    };
    const cleanup_invocation = try parseInvocation(std.testing.allocator, &cleanup_argv);
    try std.testing.expect(cleanup_invocation.command == .process);
    try std.testing.expectEqual(.cleanup, cleanup_invocation.command.process.action);
    try std.testing.expect(cleanup_invocation.command.process.dry_run);
}

test "versioned search formats enable deterministic traversal" {
    const argv = [_][]const u8{
        "ix-zig", "search", "re:needle.+", "src", "--format", "agent-v3", "--max-hits", "7", "--max-bytes", "4096",
    };
    const invocation = try parseInvocation(std.testing.allocator, &argv);
    const request = invocation.command.search;
    try std.testing.expectEqual(OutputFormat.agent_v3, request.output_format);
    try std.testing.expect(request.stable_output);
    try std.testing.expectEqual(@as(?usize, 7), request.max_hits);
    try std.testing.expectEqual(@as(?usize, 4096), request.max_bytes);
}

test "search accepts the shared records and total-count vocabulary" {
    const argv = [_][]const u8{
        "ix-zig", "search", "re:insightMemoryLimitBytes|INSIGHT_MEMORY_PERCENT|Thread\\.spawn|effectiveThreadCount|requested_threads", "src", "--format", "records", "--total-count", "300",
    };
    const request = (try parseInvocation(std.testing.allocator, &argv)).command.search;
    try std.testing.expectEqual(OutputFormat.text, request.output_format);
    try std.testing.expectEqual(@as(?usize, 300), request.max_hits);
}

test "search parse diagnostics identify rejected flags and format values" {
    const unknown = [_][]const u8{ "ix-zig", "search", "lit:needle", "src", "--invented" };
    const unknown_detail = diagnoseParseFailure(&unknown, ParseError.UnsupportedFlag);
    try std.testing.expectEqualStrings("--invented", unknown_detail.argument.?);
    try std.testing.expect(std.mem.indexOf(u8, unknown_detail.hint.?, "help search") != null);

    const invalid_format = [_][]const u8{ "ix-zig", "search", "lit:needle", "src", "--format", "nonsense" };
    const format_detail = diagnoseParseFailure(&invalid_format, ParseError.UnsupportedFlag);
    try std.testing.expectEqualStrings("nonsense", format_detail.argument.?);
    try std.testing.expect(std.mem.indexOf(u8, format_detail.hint.?, "--format") != null);
}

test "legacy json stats composition preserves raw telemetry without hit collection" {
    const json_first = [_][]const u8{ "ix-zig", "search", "lit:needle", "src", "--json", "--stats-only" };
    const stats_first = [_][]const u8{ "ix-zig", "search", "lit:needle", "src", "--stats-only", "--json" };
    for ([_][]const []const u8{ &json_first, &stats_first }) |argv| {
        const request = (try parseInvocation(std.testing.allocator, argv)).command.search;
        try std.testing.expectEqual(OutputFormat.json, request.output_format);
        try std.testing.expect(request.stats_only);
        try std.testing.expect(request.json);
    }
}

test "stats-only rejects a hit cap instead of reporting a partial count as complete" {
    const argv = [_][]const u8{ "ix-zig", "search", "lit:needle", "src", "--stats-only", "--total-count", "10" };
    try std.testing.expectError(ParseError.StatsOnlyOutputCapConflict, parseInvocation(std.testing.allocator, &argv));
}

test "matches rejects terminal-envelope projections and accepts record-only JSON" {
    const versioned = [_][]const u8{ "ix-zig", "matches", "lit:needle", "src", "--format", "agent-v3" };
    try std.testing.expectError(ParseError.UnsupportedFlag, parseInvocation(std.testing.allocator, &versioned));

    const contextual = [_][]const u8{ "ix-zig", "matches", "lit:needle", "src", "--context", "2" };
    try std.testing.expectError(ParseError.UnsupportedFlag, parseInvocation(std.testing.allocator, &contextual));

    const stats = [_][]const u8{ "ix-zig", "matches", "lit:needle", "src", "--stats-only" };
    try std.testing.expectError(ParseError.UnsupportedFlag, parseInvocation(std.testing.allocator, &stats));

    const json = [_][]const u8{ "ix-zig", "matches", "lit:needle", "src", "--json" };
    const request = (try parseInvocation(std.testing.allocator, &json)).command.matches;
    try std.testing.expectEqual(OutputFormat.json, request.output_format);
}

test "path arguments normalize equivalent Windows relative spellings" {
    const forward = [_][]const u8{ "ix-zig", "search", "lit:needle", "./src" };
    const backward = [_][]const u8{ "ix-zig", "search", "lit:needle", ".\\src" };
    const plain = [_][]const u8{ "ix-zig", "search", "lit:needle", "src" };
    const forward_request = (try parseInvocation(std.testing.allocator, &forward)).command.search;
    const backward_request = (try parseInvocation(std.testing.allocator, &backward)).command.search;
    const plain_request = (try parseInvocation(std.testing.allocator, &plain)).command.search;
    try std.testing.expectEqualStrings(plain_request.paths[0], forward_request.paths[0]);
    try std.testing.expectEqualStrings(plain_request.paths[0], backward_request.paths[0]);
}

test "search context upgrades compatible legacy projections to exact v3" {
    const text_argv = [_][]const u8{ "ix-zig", "search", "lit:needle", "src", "--context", "2" };
    const text_request = (try parseInvocation(std.testing.allocator, &text_argv)).command.search;
    try std.testing.expectEqual(OutputFormat.agent_v3, text_request.output_format);
    try std.testing.expect(text_request.stable_output);

    const json_argv = [_][]const u8{ "ix-zig", "search", "lit:needle", "src", "--json", "--context", "2" };
    const json_request = (try parseInvocation(std.testing.allocator, &json_argv)).command.search;
    try std.testing.expectEqual(OutputFormat.json_compact, json_request.output_format);
    try std.testing.expect(json_request.json);
}

test "search rejects ambiguous format and bounded legacy combinations" {
    const conflicting = [_][]const u8{ "ix-zig", "search", "lit:needle", "src", "--agent", "--json" };
    try std.testing.expectError(ParseError.ConflictingOutputFormat, parseInvocation(std.testing.allocator, &conflicting));

    const bounded_legacy = [_][]const u8{ "ix-zig", "search", "lit:needle", "src", "--json", "--max-bytes", "1000" };
    try std.testing.expectError(ParseError.ConflictingOutputFormat, parseInvocation(std.testing.allocator, &bounded_legacy));

    const zero_budget = [_][]const u8{ "ix-zig", "search", "lit:needle", "src", "--max-bytes", "0" };
    try std.testing.expectError(ParseError.MissingValue, parseInvocation(std.testing.allocator, &zero_budget));
}

test "similar parses bounded versioned frontier controls" {
    const argv = [_][]const u8{
        "ix-zig", "similar", "cache ownership", "src", "--format", "agent-v3", "--candidate-budget", "64", "--max-results", "9",
    };
    const request = (try parseInvocation(std.testing.allocator, &argv)).command.similar;
    try std.testing.expectEqual(OutputFormat.agent_v3, request.output_format);
    try std.testing.expectEqual(@as(usize, 64), request.candidate_budget);
    try std.testing.expectEqual(@as(usize, 9), request.max_results);

    const conflicting = [_][]const u8{ "ix-zig", "similar", "cache", "src", "--agent", "--json" };
    try std.testing.expectError(ParseError.ConflictingOutputFormat, parseInvocation(std.testing.allocator, &conflicting));
}

test "xo parses bounded grouped insight request" {
    const argv = [_][]const u8{
        "ix-zig", "xo", "agentSimulation worker events", "src", "--max-bytes", "4096", "--max-spans", "7", "--format", "json",
    };
    const request = (try parseInvocation(std.testing.allocator, &argv)).command.xo;
    try std.testing.expectEqualStrings("agentSimulation worker events", request.query);
    try std.testing.expectEqual(@as(usize, 4096), request.max_bytes);
    try std.testing.expectEqual(@as(usize, 7), request.max_spans);
    try std.testing.expectEqual(XoFormat.json, request.format);
}
