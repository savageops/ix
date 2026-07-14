const std = @import("std");

/// P10: Roaring Bitmap implementation for posting-list compression.
///
/// Roaring bitmaps partition the 32-bit integer space into 16-bit high
/// and low halves. Each 2^16-element "chunk" (indexed by the high 16 bits)
/// uses one of three container types based on cardinality:
///
/// - ArrayContainer: sorted u16 array. Best for sparse chunks (< 4096 elements).
/// - BitmapContainer: fixed 8 KiB bitset. Best for dense chunks (>= 4096 elements).
/// - Empty: chunk has no elements (not stored).
///
/// The 4096 threshold is the crossover where the array (2 bytes × 4096 = 8 KiB)
/// equals the bitmap (8 KiB = 65536 bits). Below it, arrays are smaller;
/// above it, bitmaps are smaller and faster for intersection.
///
/// Intersection and union operate chunk-by-chunk, with the optimal
/// algorithm chosen per chunk pair (array-array merge, bitmap-bitmap AND,
/// bitmap-array linear scan). This is SIMD-vectorizable via @Vector on
/// the bitmap containers (64-byte AND operations).

const ARRAY_THRESHOLD: usize = 4096;

pub const ContainerType = enum { array, bitmap };

pub const Container = union(ContainerType) {
    // Array: sorted u16 values, no duplicates.
    array: []u16,
    // Bitmap: 65536 bits = 8192 bytes = 1024 u64 words.
    bitmap: [1024]u64,

    pub fn cardinality(self: Container) usize {
        return switch (self) {
            .array => |arr| arr.len,
            .bitmap => |bits| blk: {
                var total: usize = 0;
                for (bits) |word| total += @popCount(word);
                break :blk total;
            },
        };
    }

    pub fn contains(self: Container, value: u16) bool {
        return switch (self) {
            .array => |arr| blk: {
                // Binary search in sorted array
                var lo: usize = 0;
                var hi: usize = arr.len;
                while (lo < hi) {
                    const mid = lo + (hi - lo) / 2;
                    if (arr[mid] == value) break :blk true;
                    if (arr[mid] < value) lo = mid + 1 else hi = mid;
                }
                break :blk false;
            },
            .bitmap => |bits| (bits[value >> 6] & (@as(u64, 1) << @intCast(value & 63))) != 0,
        };
    }

    /// Convert array container to bitmap if it exceeds the threshold.
    pub fn maybeUpgrade(self: *Container, allocator: std.mem.Allocator) !void {
        switch (self.*) {
            .array => |arr| {
                if (arr.len >= ARRAY_THRESHOLD) {
                    var bits: [1024]u64 = std.mem.zeroes([1024]u64);
                    for (arr) |val| {
                        bits[val >> 6] |= @as(u64, 1) << @intCast(val & 63);
                    }
                    allocator.free(arr);
                    self.* = .{ .bitmap = bits };
                }
            },
            .bitmap => {},
        }
    }
};

/// A Roaring bitmap: a collection of containers indexed by high 16 bits.
pub const RoaringBitmap = struct {
    chunks: std.AutoHashMap(u16, Container),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) RoaringBitmap {
        return .{
            .chunks = std.AutoHashMap(u16, Container).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *RoaringBitmap) void {
        var it = self.chunks.iterator();
        while (it.next()) |entry| {
            switch (entry.value_ptr.*) {
                .array => |arr| self.allocator.free(arr),
                .bitmap => {},
            }
        }
        self.chunks.deinit();
    }

    pub fn add(self: *RoaringBitmap, value: u32) !void {
        const high: u16 = @intCast(value >> 16);
        const low: u16 = @intCast(value & 0xFFFF);

        const gop = try self.chunks.getOrPut(high);
        if (!gop.found_existing) {
            // New chunk: start as single-element array.
            const arr = try self.allocator.alloc(u16, 1);
            arr[0] = low;
            gop.value_ptr.* = .{ .array = arr };
            return;
        }

        switch (gop.value_ptr.*) {
            .array => |arr| {
                // Check if already present.
                for (arr) |v| if (v == low) return;
                // Insert in sorted position.
                const new_arr = try self.allocator.alloc(u16, arr.len + 1);
                var inserted = false;
                var j: usize = 0;
                for (arr) |v| {
                    if (!inserted and low < v) {
                        new_arr[j] = low;
                        j += 1;
                        inserted = true;
                    }
                    new_arr[j] = v;
                    j += 1;
                }
                if (!inserted) {
                    new_arr[j] = low;
                    j += 1;
                }
                self.allocator.free(arr);
                gop.value_ptr.* = .{ .array = new_arr[0..j] };
                // Maybe upgrade to bitmap.
                try gop.value_ptr.maybeUpgrade(self.allocator);
            },
            .bitmap => |*bits| {
                bits.*[low >> 6] |= @as(u64, 1) << @intCast(low & 63);
            },
        }
    }

    pub fn contains(self: *const RoaringBitmap, value: u32) bool {
        const high: u16 = @intCast(value >> 16);
        const low: u16 = @intCast(value & 0xFFFF);
        const entry = self.chunks.get(high) orelse return false;
        return entry.contains(low);
    }

    pub fn cardinality(self: *const RoaringBitmap) usize {
        var total: usize = 0;
        var it = self.chunks.iterator();
        while (it.next()) |entry| {
            total += entry.value_ptr.cardinality();
        }
        return total;
    }

    /// Compute the intersection of two Roaring bitmaps.
    /// Result contains only values present in both. Uses optimal per-chunk
    /// algorithm: bitmap-bitmap AND (SIMD-vectorizable), array-array merge,
    /// bitmap-array scan.
    pub fn intersect(self: *const RoaringBitmap, other: *const RoaringBitmap, allocator: std.mem.Allocator) !RoaringBitmap {
        var result = RoaringBitmap.init(allocator);
        errdefer result.deinit();

        // Iterate the smaller bitmap's chunks.
        const smaller, const larger = if (self.chunks.count() <= other.chunks.count())
            .{ self, other }
        else
            .{ other, self };

        var it = smaller.chunks.iterator();
        while (it.next()) |entry| {
            const high = entry.key_ptr.*;
            const other_entry = larger.chunks.get(high) orelse continue;

            const intersected = intersectContainers(entry.value_ptr.*, other_entry, allocator) catch continue;
            switch (intersected) {
                .array => |arr| if (arr.len > 0) {
                    try result.chunks.put(high, intersected);
                } else {
                    allocator.free(arr);
                },
                .bitmap => |bits| {
                    // Only store if non-empty
                    var has_any = false;
                    for (bits) |word| if (word != 0) { has_any = true; break; };
                    if (has_any) {
                        try result.chunks.put(high, intersected);
                    }
                },
            }
        }

        return result;
    }

    /// Iterate over all values in the bitmap.
    pub fn iterator(self: *const RoaringBitmap) Iterator {
        return .{ .bm = self, .chunk_it = self.chunks.iterator(), .current_high = 0, .current_low = 0 };
    }

    pub const Iterator = struct {
        bm: *const RoaringBitmap,
        chunk_it: std.AutoHashMap(u16, Container).Iterator,
        current_high: u16,
        current_low: u16,
        current_container: ?Container = null,

        pub fn next(self: *Iterator) ?u32 {
            while (true) {
                if (self.current_container) |c| {
                    switch (c) {
                        .array => |arr| {
                            if (self.current_low < arr.len) {
                                const val = arr[self.current_low];
                                self.current_low += 1;
                                return (@as(u32, self.current_high) << 16) | val;
                            }
                            // Exhausted this array, move to next chunk.
                        },
                        .bitmap => |bits| {
                            // Scan for next set bit.
                            while (self.current_low < 65536) : (self.current_low += 1) {
                                if (bits[self.current_low >> 6] & (@as(u64, 1) << @intCast(self.current_low & 63)) != 0) {
                                    const val = self.current_low;
                                    self.current_low += 1;
                                    return (@as(u32, self.current_high) << 16) | val;
                                }
                            }
                        },
                    }
                    self.current_container = null;
                }

                const entry = self.chunk_it.next() orelse return null;
                self.current_high = entry.key_ptr.*;
                self.current_low = 0;
                self.current_container = entry.value_ptr.*;
            }
        }
    };
};

fn intersectContainers(a: Container, b: Container, allocator: std.mem.Allocator) !Container {
    return switch (a) {
        .bitmap => |bits_a| switch (b) {
            .bitmap => |bits_b| blk: {
                // Bitmap AND bitmap — SIMD-vectorizable via @Vector(4, u64)
                var result: [1024]u64 = undefined;
                const va: @Vector(1024, u64) = bits_a;
                const vb: @Vector(1024, u64) = bits_b;
                result = @bitCast(va & vb);
                break :blk .{ .bitmap = result };
            },
            .array => |arr_b| blk: {
                // Bitmap AND array — scan array against bitmap.
                var result = std.ArrayList(u16).empty;
                defer result.deinit(allocator);
                for (arr_b) |val| {
                    if (bits_a[val >> 6] & (@as(u64, 1) << @intCast(val & 63)) != 0) {
                        try result.append(allocator, val);
                    }
                }
                const owned = try result.toOwnedSlice(allocator);
                break :blk .{ .array = owned };
            },
        },
        .array => |arr_a| switch (b) {
            .bitmap => |bits_b| blk: {
                // Array AND bitmap — scan array against bitmap.
                var result = std.ArrayList(u16).empty;
                defer result.deinit(allocator);
                for (arr_a) |val| {
                    if (bits_b[val >> 6] & (@as(u64, 1) << @intCast(val & 63)) != 0) {
                        try result.append(allocator, val);
                    }
                }
                const owned = try result.toOwnedSlice(allocator);
                break :blk .{ .array = owned };
            },
            .array => |arr_b| blk: {
                // Array AND array — merge intersection.
                var result = std.ArrayList(u16).empty;
                defer result.deinit(allocator);
                var i: usize = 0;
                var j: usize = 0;
                while (i < arr_a.len and j < arr_b.len) {
                    if (arr_a[i] == arr_b[j]) {
                        try result.append(allocator, arr_a[i]);
                        i += 1;
                        j += 1;
                    } else if (arr_a[i] < arr_b[j]) {
                        i += 1;
                    } else {
                        j += 1;
                    }
                }
                const owned = try result.toOwnedSlice(allocator);
                break :blk .{ .array = owned };
            },
        },
    };
}

test "roaring bitmap add and contains" {
    var bm = RoaringBitmap.init(std.testing.allocator);
    defer bm.deinit();
    try bm.add(42);
    try bm.add(1000);
    try bm.add(70000);
    try std.testing.expect(bm.contains(42));
    try std.testing.expect(bm.contains(1000));
    try std.testing.expect(bm.contains(70000));
    try std.testing.expect(!bm.contains(43));
    try std.testing.expectEqual(@as(usize, 3), bm.cardinality());
}

test "roaring bitmap intersection" {
    var a = RoaringBitmap.init(std.testing.allocator);
    defer a.deinit();
    var b = RoaringBitmap.init(std.testing.allocator);
    defer b.deinit();
    try a.add(1);
    try a.add(2);
    try a.add(3);
    try a.add(70000);
    try b.add(2);
    try b.add(3);
    try b.add(4);
    try b.add(70000);
    var result = try a.intersect(&b, std.testing.allocator);
    defer result.deinit();
    try std.testing.expectEqual(@as(usize, 3), result.cardinality());
    try std.testing.expect(result.contains(2));
    try std.testing.expect(result.contains(3));
    try std.testing.expect(result.contains(70000));
    try std.testing.expect(!result.contains(1));
}

test "roaring bitmap array-to-bitmap upgrade" {
    var bm = RoaringBitmap.init(std.testing.allocator);
    defer bm.deinit();
    // Add enough values in one chunk to trigger upgrade.
    var i: u32 = 0;
    while (i < 4100) : (i += 1) {
        try bm.add(i);
    }
    try std.testing.expectEqual(@as(usize, 4100), bm.cardinality());
    try std.testing.expect(bm.contains(0));
    try std.testing.expect(bm.contains(4099));
}

test "roaring bitmap iterator" {
    var bm = RoaringBitmap.init(std.testing.allocator);
    defer bm.deinit();
    try bm.add(5);
    try bm.add(70000);
    try bm.add(3);
    var it = bm.iterator();
    try std.testing.expectEqual(@as(?u32, 3), it.next());
    try std.testing.expectEqual(@as(?u32, 5), it.next());
    try std.testing.expectEqual(@as(?u32, 70000), it.next());
    try std.testing.expectEqual(@as(?u32, null), it.next());
}
