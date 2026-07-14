const std = @import("std");

const MAX_IGNORE_FILE_BYTES: usize = 1024 * 1024;

pub const Decision = enum {
    admit,
    ignore,
};

const Pattern = struct {
    base: []const u8,
    glob: []const u8,
    negated: bool,
    directory_only: bool,
    anchored: bool,
    path_glob: bool,
    has_meta: bool,
};

pub const Engine = struct {
    allocator: std.mem.Allocator,
    enabled: bool,
    patterns: std.ArrayList(Pattern),

    pub fn init(allocator: std.mem.Allocator, enabled: bool) Engine {
        return .{
            .allocator = allocator,
            .enabled = enabled,
            .patterns = .empty,
        };
    }

    pub fn checkpoint(self: *const Engine) usize {
        return self.patterns.items.len;
    }

    pub fn restore(self: *Engine, mark: usize) void {
        for (self.patterns.items[mark..]) |pattern| self.freePattern(pattern);
        self.patterns.shrinkRetainingCapacity(mark);
    }

    pub fn deinit(self: *Engine) void {
        self.restore(0);
        self.patterns.deinit(self.allocator);
    }

    pub fn loadExternalIgnoreFile(self: *Engine, io: std.Io, path: []const u8) !bool {
        if (!self.enabled) return false;
        try self.loadIgnoreFile(io, path, ".");
        return true;
    }

    pub fn loadDirectoryIgnoreFiles(self: *Engine, io: std.Io, directory: []const u8) !usize {
        if (!self.enabled) return 0;
        var loaded: usize = 0;
        const gitignore = try joinPath(self.allocator, directory, ".gitignore");
        defer self.allocator.free(gitignore);
        if (try self.loadOptionalIgnoreFile(io, gitignore, directory)) loaded += 1;
        const ignore = try joinPath(self.allocator, directory, ".ignore");
        defer self.allocator.free(ignore);
        if (try self.loadOptionalIgnoreFile(io, ignore, directory)) loaded += 1;
        // P21: .agignore is the silver-searcher convention. Same syntax as
        // .gitignore. Loaded after .gitignore and .ignore so its patterns
        // can override or extend the social contract users expect.
        const agignore = try joinPath(self.allocator, directory, ".agignore");
        defer self.allocator.free(agignore);
        if (try self.loadOptionalIgnoreFile(io, agignore, directory)) loaded += 1;
        return loaded;
    }

    pub fn loadDirectoryIgnoreFile(self: *Engine, io: std.Io, directory: []const u8, file_name: []const u8) !bool {
        if (!self.enabled) return false;
        const path = try joinPath(self.allocator, directory, file_name);
        defer self.allocator.free(path);
        return try self.loadOptionalIgnoreFile(io, path, directory);
    }

    fn loadOptionalIgnoreFile(self: *Engine, io: std.Io, path: []const u8, base: []const u8) !bool {
        self.loadIgnoreFile(io, path, base) catch |err| switch (err) {
            error.FileNotFound, error.NotDir, error.AccessDenied => return false,
            else => return err,
        };
        return true;
    }

    fn loadIgnoreFile(self: *Engine, io: std.Io, path: []const u8, base: []const u8) !void {
        const bytes = try std.Io.Dir.cwd().readFileAlloc(io, path, self.allocator, .limited(MAX_IGNORE_FILE_BYTES));
        defer self.allocator.free(bytes);
        var lines = std.mem.splitScalar(u8, bytes, '\n');
        while (lines.next()) |line| {
            try self.addPatternLine(base, line);
        }
    }

    pub fn addPatternLine(self: *Engine, base: []const u8, raw_line: []const u8) !void {
        const parsed = parsePattern(raw_line) orelse return;
        const normalized_base = try normalizePath(self.allocator, base);
        const normalized_glob = try normalizePath(self.allocator, parsed.glob);
        try self.patterns.append(self.allocator, .{
            .base = normalized_base,
            .glob = normalized_glob,
            .negated = parsed.negated,
            .directory_only = parsed.directory_only,
            .anchored = parsed.anchored,
            .path_glob = parsed.path_glob,
            .has_meta = hasGlobMeta(normalized_glob),
        });
    }

    pub fn decide(self: *const Engine, path: []const u8, is_directory: bool) Decision {
        if (!self.enabled) return .admit;
        if (self.patterns.items.len == 0) return .admit;
        var path_buf: [4096]u8 = undefined;
        const normalized = normalizePathBounded(path, &path_buf) orelse return .admit;
        var ignored = false;
        for (self.patterns.items) |pattern| {
            if (!matchesPatternNormalized(pattern, normalized, is_directory)) continue;
            ignored = !pattern.negated;
        }
        if (!ignored) return .admit;
        return .ignore;
    }

    fn freePattern(self: *Engine, pattern: Pattern) void {
        self.allocator.free(pattern.base);
        self.allocator.free(pattern.glob);
    }
};

const ParsedPattern = struct {
    glob: []const u8,
    negated: bool,
    directory_only: bool,
    anchored: bool,
    path_glob: bool,
};

fn parsePattern(raw_line: []const u8) ?ParsedPattern {
    var line = std.mem.trim(u8, raw_line, " \r");
    if (line.len == 0) return null;
    if (line[0] == '#') return null;
    var negated = false;
    if (line[0] == '\\' and line.len >= 2 and (line[1] == '#' or line[1] == '!')) {
        line = line[1..];
    } else if (line[0] == '!') {
        negated = true;
        line = line[1..];
        if (line.len == 0) return null;
    }
    var directory_only = false;
    if (line.len > 0 and line[line.len - 1] == '/') {
        directory_only = true;
        line = line[0 .. line.len - 1];
        if (line.len == 0) return null;
    }
    var anchored = false;
    if (line.len > 0 and line[0] == '/') {
        anchored = true;
        line = line[1..];
        if (line.len == 0) return null;
    }
    return .{
        .glob = line,
        .negated = negated,
        .directory_only = directory_only,
        .anchored = anchored,
        .path_glob = anchored or std.mem.indexOfScalar(u8, line, '/') != null,
    };
}

fn matchesPattern(pattern: Pattern, raw_path: []const u8, is_directory: bool) bool {
    if (pattern.directory_only and !is_directory) return false;
    var path_buf: [4096]u8 = undefined;
    const normalized = normalizePathBounded(raw_path, &path_buf) orelse return false;
    return matchesPatternNormalized(pattern, normalized, is_directory);
}

fn matchesPatternNormalized(pattern: Pattern, normalized: []const u8, is_directory: bool) bool {
    if (pattern.directory_only and !is_directory) return false;
    const rel = relativeTo(pattern.base, normalized) orelse return false;
    if (rel.len == 0) return false;
    if (pattern.path_glob) {
        if (!pattern.has_meta) return std.mem.eql(u8, pattern.glob, rel);
        if (simpleGlobMatch(pattern.glob, rel)) |matched| return matched;
        return globMatch(pattern.glob, rel);
    }
    var segments = std.mem.tokenizeScalar(u8, rel, '/');
    while (segments.next()) |segment| {
        if (!pattern.has_meta) {
            if (std.mem.eql(u8, pattern.glob, segment)) return true;
            continue;
        }
        if (simpleGlobMatch(pattern.glob, segment)) |matched| {
            if (matched) return true;
            continue;
        }
        if (globMatch(pattern.glob, segment)) return true;
    }
    return false;
}

fn hasGlobMeta(pattern: []const u8) bool {
    for (pattern) |byte| {
        if (byte == '*' or byte == '?' or byte == '[' or byte == '\\') return true;
    }
    return false;
}

fn simpleGlobMatch(pattern: []const u8, text: []const u8) ?bool {
    var star_index: ?usize = null;
    for (pattern, 0..) |byte, index| {
        switch (byte) {
            '*' => {
                if (star_index != null) return null;
                star_index = index;
            },
            '?', '[', '\\' => return null,
            else => {},
        }
    }
    const star = star_index orelse return std.mem.eql(u8, pattern, text);
    const prefix = pattern[0..star];
    const suffix = pattern[star + 1 ..];
    return text.len >= prefix.len + suffix.len and
        std.mem.startsWith(u8, text, prefix) and
        std.mem.endsWith(u8, text, suffix);
}

fn relativeTo(base: []const u8, path: []const u8) ?[]const u8 {
    if (base.len == 0 or std.mem.eql(u8, base, ".")) return path;
    if (!std.mem.startsWith(u8, path, base)) return null;
    if (path.len == base.len) return "";
    if (path[base.len] != '/') return null;
    return path[base.len + 1 ..];
}

fn globMatch(pattern: []const u8, text: []const u8) bool {
    return globMatchAt(pattern, 0, text, 0);
}

fn globMatchAt(pattern: []const u8, p0: usize, text: []const u8, t0: usize) bool {
    var p = p0;
    var t = t0;
    while (p < pattern.len) {
        const c = pattern[p];
        if (c == '*') {
            const is_double = p + 1 < pattern.len and pattern[p + 1] == '*';
            if (is_double) {
                p += 2;
                if (p < pattern.len and pattern[p] == '/') {
                    p += 1;
                    if (globMatchAt(pattern, p, text, t)) return true;
                }
                var i = t;
                while (i <= text.len) : (i += 1) {
                    if (globMatchAt(pattern, p, text, i)) return true;
                }
                return false;
            }
            p += 1;
            var i = t;
            while (i <= text.len) : (i += 1) {
                if (i > t and text[i - 1] == '/') return false;
                if (globMatchAt(pattern, p, text, i)) return true;
            }
            return false;
        }
        if (t >= text.len) return false;
        if (c == '?') {
            if (text[t] == '/') return false;
            p += 1;
            t += 1;
            continue;
        }
        if (c == '[') {
            const close = std.mem.indexOfScalarPos(u8, pattern, p + 1, ']') orelse return false;
            if (text[t] == '/' or !classMatch(pattern[p + 1 .. close], text[t])) return false;
            p = close + 1;
            t += 1;
            continue;
        }
        if (c == '\\' and p + 1 < pattern.len) p += 1;
        if (pattern[p] != text[t]) return false;
        p += 1;
        t += 1;
    }
    return t == text.len;
}

fn classMatch(class: []const u8, byte: u8) bool {
    var i: usize = 0;
    var negated = false;
    if (class.len > 0 and (class[0] == '!' or class[0] == '^')) {
        negated = true;
        i = 1;
    }
    var matched = false;
    while (i < class.len) : (i += 1) {
        if (i + 2 < class.len and class[i + 1] == '-') {
            if (byte >= class[i] and byte <= class[i + 2]) matched = true;
            i += 2;
        } else if (byte == class[i]) {
            matched = true;
        }
    }
    return if (negated) !matched else matched;
}

fn normalizePath(allocator: std.mem.Allocator, path: []const u8) ![]const u8 {
    var list = std.ArrayList(u8).empty;
    try list.ensureTotalCapacity(allocator, path.len);
    for (path) |byte| {
        const c = if (byte == '\\') '/' else byte;
        if (c == '/' and list.items.len > 0 and list.items[list.items.len - 1] == '/') continue;
        try list.append(allocator, c);
    }
    while (list.items.len > 1 and list.items[list.items.len - 1] == '/') _ = list.pop();
    return list.toOwnedSlice(allocator);
}

fn normalizePathBounded(path: []const u8, out: []u8) ?[]const u8 {
    if (path.len > out.len) return null;
    var n: usize = 0;
    for (path) |byte| {
        const c = if (byte == '\\') '/' else byte;
        if (c == '/' and n > 0 and out[n - 1] == '/') continue;
        out[n] = c;
        n += 1;
    }
    while (n > 1 and out[n - 1] == '/') n -= 1;
    return out[0..n];
}

fn joinPath(allocator: std.mem.Allocator, left: []const u8, right: []const u8) ![]const u8 {
    if (left.len == 0 or std.mem.eql(u8, left, ".")) return try allocator.dupe(u8, right);
    var list = std.ArrayList(u8).empty;
    try list.appendSlice(allocator, left);
    if (left[left.len - 1] != '/' and left[left.len - 1] != '\\') try list.append(allocator, '/');
    try list.appendSlice(allocator, right);
    return list.toOwnedSlice(allocator);
}

test "gitignore pattern parser handles comments negation and directory-only rules" {
    try std.testing.expect(parsePattern("# comment") == null);
    const negated = parsePattern("!src/main.zig").?;
    try std.testing.expect(negated.negated);
    try std.testing.expect(negated.path_glob);
    const dir = parsePattern("target/").?;
    try std.testing.expect(dir.directory_only);
    try std.testing.expect(!dir.path_glob);
    const escaped = parsePattern("\\!important").?;
    try std.testing.expect(!escaped.negated);
    try std.testing.expectEqualStrings("!important", escaped.glob);
}

test "admission engine honors last match and excluded parent directory contract" {
    var engine = Engine.init(std.testing.allocator, true);
    defer engine.deinit();
    try engine.addPatternLine(".", "target/");
    try engine.addPatternLine(".", "!target/keep.txt");
    try std.testing.expectEqual(Decision.ignore, engine.decide("target", true));
    try std.testing.expectEqual(Decision.ignore, engine.decide("src/target", true));
    try std.testing.expectEqual(Decision.admit, engine.decide("target/keep.txt", false));
}

test "admission engine supports slash anchored glob and character class semantics" {
    var engine = Engine.init(std.testing.allocator, true);
    defer engine.deinit();
    try engine.addPatternLine("root", "/build/**/*.o");
    try engine.addPatternLine("root", "*.tmp");
    try engine.addPatternLine("root", "file[0-9].txt");
    try std.testing.expectEqual(Decision.ignore, engine.decide("root/build/a/b/main.o", false));
    try std.testing.expectEqual(Decision.ignore, engine.decide("root/src/cache.tmp", false));
    try std.testing.expectEqual(Decision.ignore, engine.decide("root/file7.txt", false));
    try std.testing.expectEqual(Decision.admit, engine.decide("root/filex.txt", false));
}
