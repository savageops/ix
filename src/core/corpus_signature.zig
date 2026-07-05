const std = @import("std");

/// Corpus signature for stale-index detection.
///
/// Computed from the exact files that were indexed (at publish time) and
/// compared against a live stat walk (at query time). If any field differs,
/// the index is stale and search falls back to cold scan.
///
/// The `path_hash_xor` field is an order-independent XOR rollup of
/// `hashFileSignature(normalized_path, size, mtime_ns)` per file. This
/// catches renames (path changes even if size+mtime preserved), moved files
/// (same content, different path), and swapped-content cases that
/// file_count + total_bytes + max_mtime alone would miss.
pub const CorpusSignature = struct {
    file_count: usize = 0,
    total_bytes: u64 = 0,
    max_mtime_ns: i128 = 0,
    path_hash_xor: u64 = 0,
    coverage_gap: bool = false,

    /// Compares all signature fields. Returns true if signatures match
    /// (corpus is unchanged since indexing).
    pub fn matches(self: CorpusSignature, other: CorpusSignature) bool {
        return self.file_count == other.file_count and
            self.total_bytes == other.total_bytes and
            self.max_mtime_ns == other.max_mtime_ns and
            self.path_hash_xor == other.path_hash_xor;
    }
};

/// Normalizes a file path for signature hashing: backslash → forward slash,
/// lowercase drive letter, no trailing slash. Applied identically by both
/// the indexer (from IndexedFile.path) and the search (from stat walk).
/// This ensures both call sites produce the same hash for the same file.
pub fn normalizePathForSignature(path: []const u8) []const u8 {
    // The caller is responsible for normalization before calling hashFileSignature.
    // This function exists as documentation of the contract; actual normalization
    // happens inline in the wrappers to avoid allocation.
    return path;
}

/// Shared per-file hash function used by both the indexer and the search path.
/// Normalizes the path (backslash→slash, lowercase drive letter) and hashes
/// (normalized_path, size, mtime_ns) into a single u64 via Wyhash.
///
/// Both call sites MUST use this function — no alternate implementations.
/// This is the single-source-of-truth hash that prevents drift between
/// the index-time signature and the query-time signature.
pub fn hashFileSignature(path: []const u8, size: u64, mtime_ns: i128) u64 {
    // Normalize path in-place (no allocation): backslash → slash, lowercase drive.
    var buf: [4096]u8 = undefined;
    if (path.len > buf.len) {
        // Path too long for stack buffer — hash the raw path (rare edge case).
        return hashFileSignatureRaw(path, size, mtime_ns);
    }
    var len: usize = 0;
    for (path) |byte| {
        if (byte == '\\') {
            buf[len] = '/';
        } else {
            buf[len] = byte;
        }
        len += 1;
    }
    // Lowercase drive letter: "E:/..." → "e:/..."
    if (len >= 2 and buf[1] == ':') {
        if (buf[0] >= 'A' and buf[0] <= 'Z') buf[0] += 32;
    }
    // Strip trailing slash.
    if (len > 1 and buf[len - 1] == '/') len -= 1;
    return hashFileSignatureRaw(buf[0..len], size, mtime_ns);
}

fn hashFileSignatureRaw(path: []const u8, size: u64, mtime_ns: i128) u64 {
    var hasher = std.hash.Wyhash.init(0x4958_5349_4741_5445); // "IXSIGATURE"
    hasher.update(path);
    hasher.update(std.mem.asBytes(&size));
    hasher.update(std.mem.asBytes(&mtime_ns));
    return hasher.final();
}

/// Serializes a CorpusSignature to a compact byte buffer for .ixsignature file.
pub fn serializeSignature(allocator: std.mem.Allocator, sig: CorpusSignature) ![]u8 {
    var list = std.ArrayList(u8).empty;
    errdefer list.deinit(allocator);
    var buf: [256]u8 = undefined;
    const writer = std.fmt.bufPrint(&buf, "IXSIG1\ncount={}\nbytes={}\nmtime={}\nxor={x}\n", .{
        sig.file_count, sig.total_bytes, sig.max_mtime_ns, sig.path_hash_xor,
    }) catch return error.SignatureFormatError;
    try list.appendSlice(allocator, writer);
    return list.toOwnedSlice(allocator);
}

/// Parses a CorpusSignature from a .ixsignature file's bytes.
pub fn parseSignature(bytes: []const u8) ?CorpusSignature {
    var lines = std.mem.splitScalar(u8, bytes, '\n');
    const magic = std.mem.trimEnd(u8, lines.next() orelse return null, "\r");
    if (!std.mem.eql(u8, magic, "IXSIG1")) return null;

    var sig = CorpusSignature{};
    while (lines.next()) |line| {
        const trimmed = std.mem.trimEnd(u8, line, "\r");
        if (trimmed.len == 0) continue;
        if (std.mem.startsWith(u8, trimmed, "count=")) {
            sig.file_count = std.fmt.parseInt(usize, trimmed["count=".len..], 10) catch return null;
        } else if (std.mem.startsWith(u8, trimmed, "bytes=")) {
            sig.total_bytes = std.fmt.parseInt(u64, trimmed["bytes=".len..], 10) catch return null;
        } else if (std.mem.startsWith(u8, trimmed, "mtime=")) {
            sig.max_mtime_ns = std.fmt.parseInt(i128, trimmed["mtime=".len..], 10) catch return null;
        } else if (std.mem.startsWith(u8, trimmed, "xor=")) {
            sig.path_hash_xor = std.fmt.parseInt(u64, trimmed["xor=".len..], 16) catch return null;
        }
    }
    return sig;
}

test "corpus signature matches identical inputs" {
    const sig_a = CorpusSignature{
        .file_count = 100,
        .total_bytes = 50000,
        .max_mtime_ns = 123456789,
        .path_hash_xor = 0xDEADBEEF,
    };
    const sig_b = CorpusSignature{
        .file_count = 100,
        .total_bytes = 50000,
        .max_mtime_ns = 123456789,
        .path_hash_xor = 0xDEADBEEF,
    };
    try std.testing.expect(sig_a.matches(sig_b));
}

test "corpus signature rejects count mismatch" {
    const sig_a = CorpusSignature{ .file_count = 100, .total_bytes = 50000, .max_mtime_ns = 1, .path_hash_xor = 42 };
    const sig_b = CorpusSignature{ .file_count = 101, .total_bytes = 50000, .max_mtime_ns = 1, .path_hash_xor = 42 };
    try std.testing.expect(!sig_a.matches(sig_b));
}

test "corpus signature rejects mtime mismatch (edited file same count)" {
    const sig_a = CorpusSignature{ .file_count = 100, .total_bytes = 50000, .max_mtime_ns = 100, .path_hash_xor = 42 };
    const sig_b = CorpusSignature{ .file_count = 100, .total_bytes = 50000, .max_mtime_ns = 200, .path_hash_xor = 42 };
    try std.testing.expect(!sig_a.matches(sig_b));
}

test "corpus signature rejects xor mismatch (renamed file same count+size+mtime)" {
    const sig_a = CorpusSignature{ .file_count = 100, .total_bytes = 50000, .max_mtime_ns = 100, .path_hash_xor = 0xAAA };
    const sig_b = CorpusSignature{ .file_count = 100, .total_bytes = 50000, .max_mtime_ns = 100, .path_hash_xor = 0xBBB };
    try std.testing.expect(!sig_a.matches(sig_b));
}

test "hashFileSignature normalizes backslash paths" {
    const h1 = hashFileSignature("E:\\repo\\src\\file.c", 1000, 99999);
    const h2 = hashFileSignature("e:/repo/src/file.c", 1000, 99999);
    try std.testing.expectEqual(h1, h2);
}

test "hashFileSignature differs on renamed file" {
    const h1 = hashFileSignature("e:/repo/src/old_name.c", 1000, 99999);
    const h2 = hashFileSignature("e:/repo/src/new_name.c", 1000, 99999);
    try std.testing.expect(h1 != h2);
}

test "hashFileSignature differs on edited file (same path, different size)" {
    const h1 = hashFileSignature("e:/repo/src/file.c", 1000, 99999);
    const h2 = hashFileSignature("e:/repo/src/file.c", 2000, 99999);
    try std.testing.expect(h1 != h2);
}

test "serialize and parse round-trip" {
    const allocator = std.testing.allocator;
    const sig = CorpusSignature{
        .file_count = 79405,
        .total_bytes = 1340828181,
        .max_mtime_ns = 1783207702445636600,
        .path_hash_xor = 0xABCDEF1234567890,
    };
    const bytes = try serializeSignature(allocator, sig);
    defer allocator.free(bytes);
    const parsed = parseSignature(bytes) orelse return error.ParseFailed;
    try std.testing.expect(sig.matches(parsed));
}
