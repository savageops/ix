const std = @import("std");

/// Canonical output projections. Legacy flags lower into this enum at parse time.
pub const OutputFormat = enum {
    text,
    agent_v2,
    agent_v3,
    json,
    json_compact,
    files,
    count,
    stats,
    /// P23: Streaming NDJSON — one JSON hit object per line, flushed as
    /// discovered. Terminated by a result sentinel JSON object on the
    /// final line. No monolithic array materialization.
    ndjson,
};

pub const FormatSpec = struct {
    name: []const u8,
    format: OutputFormat,
    compatibility: []const u8,
    help: []const u8,
};

pub const OptionSpec = struct {
    syntax: []const u8,
    names: []const []const u8,
    help: []const u8,
    search_only: bool = false,
    takes_value: bool = false,
};

/// One table owns the canonical search grammar presented by help and diagnostics.
pub const search_options = [_]OptionSpec{
    .{ .syntax = "--hidden", .names = &.{"--hidden"}, .help = "Include hidden files and directories" },
    .{ .syntax = "--no-ignore", .names = &.{"--no-ignore"}, .help = "Disable ignore-file admission" },
    .{ .syntax = "-u, --unrestricted", .names = &.{ "-u", "--unrestricted" }, .help = "Include hidden and ignored paths" },
    .{ .syntax = "--ignore-file <PATH>", .names = &.{"--ignore-file"}, .help = "Add an explicit ignore source", .takes_value = true },
    .{ .syntax = "--follow-symlinks", .names = &.{"--follow-symlinks"}, .help = "Follow symbolic links" },
    .{ .syntax = "-F, --fixed-strings", .names = &.{ "-F", "--fixed-strings" }, .help = "Treat the expression as a literal" },
    .{ .syntax = "-i, --ignore-case", .names = &.{ "-i", "--ignore-case" }, .help = "Match ASCII case-insensitively" },
    .{ .syntax = "--json", .names = &.{ "--json", "-j" }, .help = "Emit full structured JSON telemetry" },
    .{ .syntax = "--stats-only", .names = &.{"--stats-only"}, .help = "Disable hit collection and emit telemetry" },
    .{ .syntax = "--agent", .names = &.{"--agent"}, .help = "Emit compact grouped ix.result.v2", .search_only = true },
    .{ .syntax = "--format <FORMAT>", .names = &.{"--format"}, .help = "Select a canonical output projection", .takes_value = true },
    .{ .syntax = "-l, --files-with-matches", .names = &.{ "-l", "--files-with-matches" }, .help = "Emit unique matching paths" },
    .{ .syntax = "-c, --count", .names = &.{ "-c", "--count" }, .help = "Emit per-file match counts" },
    .{ .syntax = "--max-hits <N>", .names = &.{"--max-hits"}, .help = "Limit retained hit records", .takes_value = true },
    .{ .syntax = "--total-count <N>", .names = &.{"--total-count"}, .help = "Output cap; scanning may continue (alias of --max-hits)", .takes_value = true },
    .{ .syntax = "-t, --threads <N>", .names = &.{ "-t", "--threads" }, .help = "Request workers below the framework ceiling", .takes_value = true },
    .{ .syntax = "--emit-report <PATH>", .names = &.{"--emit-report"}, .help = "Write the full JSON report to a file", .takes_value = true },
    .{ .syntax = "--context <N>", .names = &.{"--context"}, .help = "Include exact coalesced context in v3", .search_only = true, .takes_value = true },
    .{ .syntax = "--max-bytes <N>", .names = &.{"--max-bytes"}, .help = "Bound one complete v3 envelope", .search_only = true, .takes_value = true },
    .{ .syntax = "--cursor <TOKEN>", .names = &.{"--cursor"}, .help = "Continue a request-bound v3 result", .search_only = true, .takes_value = true },
    .{ .syntax = "--budget-ms <N>", .names = &.{"--budget-ms"}, .help = "Wall-clock time budget; truncate scan when exceeded (P9)", .takes_value = true },
    .{ .syntax = "--estimate", .names = &.{"--estimate"}, .help = "Emit pre-execution cost estimate and exit (P9)" },
    .{ .syntax = "-n, --line-number [N]", .names = &.{ "-n", "--line-number" }, .help = "Emit line numbers; optional N also limits hits" },
    .{ .syntax = "-h, --help", .names = &.{ "-h", "--help" }, .help = "Print help" },
};

pub const min_options = [_]OptionSpec{
    .{ .syntax = "--level <LEVEL>", .names = &.{"--level"}, .help = "Select low, med, or high", .takes_value = true },
    .{ .syntax = "--max-bytes <N>", .names = &.{"--max-bytes"}, .help = "Bound the complete stdout payload", .takes_value = true },
    .{ .syntax = "--format <FORMAT>", .names = &.{"--format"}, .help = "Select text or json", .takes_value = true },
    .{ .syntax = "--json", .names = &.{"--json"}, .help = "Alias for --format json" },
    .{ .syntax = "-h, --help", .names = &.{ "-h", "--help" }, .help = "Print help" },
};

pub const min_levels = [_][]const u8{ "low", "med", "high" };
pub const min_formats = [_][]const u8{ "text", "json" };

/// One table owns accepted format names, migration posture, and help text.
pub const formats = [_]FormatSpec{
    .{ .name = "records", .format = .text, .compatibility = "current", .help = "Hit records with the v1 terminal result" },
    .{ .name = "text", .format = .text, .compatibility = "alias:records", .help = "Alias of records" },
    .{ .name = "agent", .format = .agent_v2, .compatibility = "current", .help = "Compact grouped ix.result.v2" },
    .{ .name = "agent-v3", .format = .agent_v3, .compatibility = "versioned", .help = "Bounded, cursorable ix.result.v3" },
    .{ .name = "json", .format = .json, .compatibility = "current", .help = "Full compatible JSON with debug telemetry" },
    .{ .name = "json-compact", .format = .json_compact, .compatibility = "versioned", .help = "Raw compact v3 JSON without sentinel framing" },
    .{ .name = "files", .format = .files, .compatibility = "alias:-l", .help = "Unique paths with matches" },
    .{ .name = "count", .format = .count, .compatibility = "alias:-c", .help = "Per-file match counts" },
    .{ .name = "stats", .format = .stats, .compatibility = "alias:--stats-only", .help = "Suppress hit records and emit result telemetry" },
    .{ .name = "ndjson", .format = .ndjson, .compatibility = "streaming", .help = "Streaming NDJSON — one hit per line, sentinel-terminated (P23)" },
};

/// Resolves a public format name through the canonical table.
pub fn parseFormat(name: []const u8) ?OutputFormat {
    for (formats) |spec| if (std.mem.eql(u8, name, spec.name)) return spec.format;
    return null;
}

/// Writes the accepted names from the same table the parser consumes.
pub fn writeFormatNames(writer: anytype) !void {
    for (formats, 0..) |spec, index| {
        if (index != 0) try writer.writeAll(", ");
        try writer.writeAll(spec.name);
    }
}

pub fn writeSearchOptions(writer: anytype, include_search_only: bool) !void {
    for (search_options) |spec| {
        if (spec.search_only and !include_search_only) continue;
        try writer.print("  {s:<30} {s}\n", .{ spec.syntax, spec.help });
    }
}

pub fn findSearchOption(name: []const u8, include_search_only: bool) ?OptionSpec {
    for (search_options) |spec| {
        if (spec.search_only and !include_search_only) continue;
        for (spec.names) |candidate| if (std.mem.eql(u8, name, candidate)) return spec;
    }
    return null;
}

test "every public output format round trips through the command specification" {
    inline for (formats) |spec| try std.testing.expectEqual(spec.format, parseFormat(spec.name).?);
    try std.testing.expect(parseFormat("unknown") == null);
}

test "search help metadata covers every bounded agent control" {
    inline for (.{ "--format", "--total-count", "--context", "--max-bytes", "--cursor" }) |name| {
        try std.testing.expect(findSearchOption(name, true) != null);
    }
}

test "all shell completion command sources advertise min" {
    var found = false;
    for (commands) |command| if (std.mem.eql(u8, command, "min")) {
        found = true;
        break;
    };
    try std.testing.expect(found);
}

// ── Shell Completions (P30) ─────────────────────────────────────────
//
// Generated from the same command_spec tables that own the parser and
// help text. Four shells: bash, zsh, fish, PowerShell. Each uses the
// canonical command list and option list — single source of truth.

pub const commands = [_][]const u8{
    "search", "matches", "inspect", "min", "explain", "process", "similar", "xo", "why", "watch", "replace", "diff-matches", "mcp", "help",
};

/// Writes bash completion to the given writer.
pub fn writeBashCompletion(writer: anytype) !void {
    try writer.writeAll("# bash completion for ix\n");
    try writer.writeAll("_ix() {\n");
    try writer.writeAll("    local cur prev cmds\n");
    try writer.writeAll("    cur=${COMP_WORDS[COMP_CWORD]}\n");
    try writer.writeAll("    prev=${COMP_WORDS[COMP_CWORD-1]}\n");
    try writer.writeAll("    cmds=\"");
    for (commands, 0..) |cmd, i| {
        if (i > 0) try writer.writeByte(' ');
        try writer.writeAll(cmd);
    }
    try writer.writeAll("\"\n");
    try writer.writeAll("    if [ $COMP_CWORD -eq 1 ]; then\n");
    try writer.writeAll("        COMPREPLY=( $(compgen -W \"$cmds\" -- \"$cur\") )\n");
    try writer.writeAll("        return 0\n");
    try writer.writeAll("    fi\n");
    // Format and level values remain command-specific so completion cannot advertise invalid enums.
    try writer.writeAll("    case \"$prev\" in\n");
    try writer.writeAll("        --level)\n");
    try writer.writeAll("            if [ \"${COMP_WORDS[1]}\" = \"min\" ]; then COMPREPLY=( $(compgen -W \"low med high\" -- \"$cur\") ); return 0; fi ;;\n");
    try writer.writeAll("        --format)\n");
    try writer.writeAll("            if [ \"${COMP_WORDS[1]}\" = \"min\" ]; then COMPREPLY=( $(compgen -W \"text json\" -- \"$cur\") ); return 0; fi\n");
    try writer.writeAll("            COMPREPLY=( $(compgen -W \"");
    for (formats, 0..) |spec, i| {
        if (i > 0) try writer.writeByte(' ');
        try writer.writeAll(spec.name);
    }
    try writer.writeAll("\" -- \"$cur\") )\n");
    try writer.writeAll("            return 0 ;;\n");
    try writer.writeAll("    esac\n");
    // Options
    try writer.writeAll("    case \"${COMP_WORDS[1]}\" in\n");
    try writer.writeAll("        search|matches)\n");
    try writer.writeAll("            COMPREPLY=( $(compgen -W \"");
    for (search_options) |spec| {
        for (spec.names) |name| {
            try writer.writeAll(name);
            try writer.writeByte(' ');
        }
    }
    try writer.writeAll("--version\" -- \"$cur\") )\n");
    try writer.writeAll("            ;;\n");
    try writer.writeAll("        min)\n");
    try writer.writeAll("            COMPREPLY=( $(compgen -W \"");
    for (min_options) |spec| for (spec.names) |name| try writer.print("{s} ", .{name});
    try writer.writeAll("\" -- \"$cur\") )\n");
    try writer.writeAll("            ;;\n");
    try writer.writeAll("    esac\n");
    try writer.writeAll("    COMPREPLY=( $(compgen -f -- \"$cur\") )\n");
    try writer.writeAll("    return 0\n");
    try writer.writeAll("}\n");
    try writer.writeAll("complete -F _ix ix ix-zig\n");
}

/// Writes zsh completion to the given writer.
pub fn writeZshCompletion(writer: anytype) !void {
    try writer.writeAll("#compdef ix ix-zig\n");
    try writer.writeAll("_ix() {\n");
    try writer.writeAll("    local -a commands formats options\n");
    try writer.writeAll("    commands=( ");
    for (commands) |cmd| {
        try writer.print("{s} ", .{cmd});
    }
    try writer.writeAll(")\n");
    try writer.writeAll("    formats=( ");
    for (formats) |spec| {
        try writer.print("{s} ", .{spec.name});
    }
    try writer.writeAll(")\n");
    try writer.writeAll("    options=( ");
    for (search_options) |spec| {
        for (spec.names) |name| {
            try writer.print("{s} ", .{name});
        }
    }
    try writer.writeAll(")\n");
    try writer.writeAll("    _arguments -C \\\n");
    try writer.writeAll("        '1:command:->cmds' \\\n");
    try writer.writeAll("        '*::arg:->args'\n");
    try writer.writeAll("    case \"$state\" in\n");
    try writer.writeAll("        cmds) _describe 'command' commands ;;\n");
    try writer.writeAll("        args)\n");
    try writer.writeAll("            case \"${words[1]}\" in\n");
    try writer.writeAll("                search|matches)\n");
    try writer.writeAll("                    _arguments \"--format[Output projection]:format:->fmts\" ");
    for (search_options) |spec| {
        for (spec.names) |name| {
            try writer.print("\"{s}\" ", .{name});
        }
    }
    try writer.writeAll("\n");
    try writer.writeAll("                    ;;\n");
    try writer.writeAll("                min)\n");
    try writer.writeAll("                    _arguments '--level[Compaction policy]:level:(low med high)' '--max-bytes[Complete stdout byte cap]:bytes:' '--format[Output format]:format:(text json)' '--json[Emit JSON]' '-h[Print help]' '--help[Print help]'\n");
    try writer.writeAll("                    ;;\n");
    try writer.writeAll("            esac\n");
    try writer.writeAll("            case \"$state\" in\n");
    try writer.writeAll("                fmts) _describe 'format' formats ;;\n");
    try writer.writeAll("            esac\n");
    try writer.writeAll("            ;;\n");
    try writer.writeAll("    esac\n");
    try writer.writeAll("}\n");
    try writer.writeAll("_ix \"$@\"\n");
}

/// Writes fish completion to the given writer.
pub fn writeFishCompletion(writer: anytype) !void {
    for (commands) |cmd| {
        try writer.print("complete -c ix -n \"__fish_use_subcommand\" -a \"{s}\"\n", .{cmd});
    }
    for (formats) |spec| {
        try writer.print("complete -c ix -n \"__fish_seen_subcommand_from search; and __fish_seen_argument --format\" -a \"{s}\"\n", .{spec.name});
    }
    for (search_options) |spec| {
        for (spec.names) |name| {
            try writer.print("complete -c ix -n \"__fish_seen_subcommand_from search matches\" -l \"{s}\"", .{name[2..]});
            try writer.writeAll("\n");
        }
    }
    for (min_levels) |level| try writer.print("complete -c ix -n \"__fish_seen_subcommand_from min; and __fish_seen_argument --level\" -a \"{s}\"\n", .{level});
    for (min_formats) |format| try writer.print("complete -c ix -n \"__fish_seen_subcommand_from min; and __fish_seen_argument --format\" -a \"{s}\"\n", .{format});
    for (min_options) |spec| {
        for (spec.names) |name| {
            if (std.mem.startsWith(u8, name, "--")) try writer.print("complete -c ix -n \"__fish_seen_subcommand_from min\" -l \"{s}\"\n", .{name[2..]});
        }
    }
}

/// Writes PowerShell completion to the given writer.
pub fn writePowerShellCompletion(writer: anytype) !void {
    try writer.writeAll("Register-ArgumentCompleter -Native -CommandName ix -ScriptBlock {\n");
    try writer.writeAll("    param($wordToComplete, $commandAst, $cursorPosition)\n");
    try writer.writeAll("    $commands = @(");
    for (commands, 0..) |cmd, i| {
        if (i > 0) try writer.writeAll(", ");
        try writer.print("'{s}'", .{cmd});
    }
    try writer.writeAll(")\n");
    try writer.writeAll("    $formats = @(");
    for (formats, 0..) |spec, i| {
        if (i > 0) try writer.writeAll(", ");
        try writer.print("'{s}'", .{spec.name});
    }
    try writer.writeAll(")\n");
    try writer.writeAll("    $options = @(");
    var option_index: usize = 0;
    for (search_options) |spec| {
        if (option_index > 0) try writer.writeAll(", ");
        try writer.print("'{s}'", .{spec.names[0]});
        option_index += 1;
    }
    for (min_options) |spec| {
        if (option_index > 0) try writer.writeAll(", ");
        try writer.print("'{s}'", .{spec.names[0]});
        option_index += 1;
    }
    try writer.writeAll(")\n");
    try writer.writeAll("    if ($wordToComplete.StartsWith('-')) {\n");
    try writer.writeAll("        $options | Where-Object { $_ -like \"$wordToComplete*\" } |\n");
    try writer.writeAll("            ForEach-Object { [System.Management.Automation.CompletionResult]::new($_, $_, 'ParameterValue', $_) }\n");
    try writer.writeAll("    } else {\n");
    try writer.writeAll("        $commands | Where-Object { $_ -like \"$wordToComplete*\" } |\n");
    try writer.writeAll("            ForEach-Object { [System.Management.Automation.CompletionResult]::new($_, $_, 'ParameterValue', $_) }\n");
    try writer.writeAll("    }\n");
    try writer.writeAll("}\n");
}
