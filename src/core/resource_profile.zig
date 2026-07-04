const std = @import("std");

pub const ENV = "IX_RESOURCE_PROFILE";

const GIB: usize = 1024 * 1024 * 1024;

pub const Profile = enum {
    low,
    medium,
    high,

    pub fn label(self: Profile) []const u8 {
        return switch (self) {
            .low => "low",
            .medium => "medium",
            .high => "high",
        };
    }

    pub fn discoveryThreadCap(self: Profile, available: usize) usize {
        const cpus = @max(available, 1);
        return switch (self) {
            .low => @min(cpus, @as(usize, 16)),
            .medium => @min(cpus, @as(usize, 24)),
            .high => @min(cpus, @as(usize, 24)),
        };
    }

    pub fn smallCorpusThreadCap(self: Profile, available: usize) usize {
        const cpus = @max(available, 1);
        return switch (self) {
            .low => @min(cpus, @as(usize, 2)),
            .medium => @min(cpus, @as(usize, 4)),
            .high => @min(cpus, @as(usize, 8)),
        };
    }

    pub fn largeCorpusThreadReserve(self: Profile, available: usize) usize {
        return switch (self) {
            .low => if (available > 8) 3 else 0,
            .medium => if (available > 12) 1 else 0,
            .high => 0,
        };
    }

    pub fn byteShardThreadCap(self: Profile, available: usize, low_profile_cap: usize) usize {
        const cpus = @max(available, 1);
        return switch (self) {
            .low => @min(cpus, low_profile_cap),
            .medium, .high => cpus,
        };
    }

    pub fn indexdDefaultMemoryLimitBytes(self: Profile) usize {
        return switch (self) {
            .low => 4 * GIB,
            .medium => 6 * GIB,
            .high => 8 * GIB,
        };
    }
};

pub fn current() Profile {
    const value_ptr = std.c.getenv(ENV) orelse return .low;
    return fromValue(std.mem.span(value_ptr));
}

pub fn fromValue(raw: []const u8) Profile {
    if (raw.len == 0) return .low;
    if (std.ascii.eqlIgnoreCase(raw, "medium")) return .medium;
    if (std.ascii.eqlIgnoreCase(raw, "high")) return .high;
    return .low;
}

test "resource profile parser defaults to low" {
    try std.testing.expectEqual(Profile.low, fromValue(""));
    try std.testing.expectEqual(Profile.low, fromValue("unexpected"));
}

test "resource profile parser accepts explicit values" {
    try std.testing.expectEqual(Profile.low, fromValue("low"));
    try std.testing.expectEqual(Profile.medium, fromValue("medium"));
    try std.testing.expectEqual(Profile.high, fromValue("high"));
}

test "resource profile scales thread caps by level" {
    try std.testing.expectEqual(@as(usize, 16), Profile.low.discoveryThreadCap(32));
    try std.testing.expectEqual(@as(usize, 24), Profile.medium.discoveryThreadCap(32));
    try std.testing.expectEqual(@as(usize, 24), Profile.high.discoveryThreadCap(32));
    try std.testing.expectEqual(@as(usize, 2), Profile.low.smallCorpusThreadCap(32));
    try std.testing.expectEqual(@as(usize, 4), Profile.medium.smallCorpusThreadCap(32));
    try std.testing.expectEqual(@as(usize, 8), Profile.high.smallCorpusThreadCap(32));
    try std.testing.expectEqual(@as(usize, 3), Profile.low.largeCorpusThreadReserve(32));
    try std.testing.expectEqual(@as(usize, 1), Profile.medium.largeCorpusThreadReserve(32));
    try std.testing.expectEqual(@as(usize, 0), Profile.high.largeCorpusThreadReserve(32));
    try std.testing.expectEqual(@as(usize, 16), Profile.low.byteShardThreadCap(64, 16));
    try std.testing.expectEqual(@as(usize, 64), Profile.high.byteShardThreadCap(64, 16));
}

test "resource profile owns indexd memory defaults" {
    try std.testing.expectEqual(@as(usize, 4 * GIB), Profile.low.indexdDefaultMemoryLimitBytes());
    try std.testing.expectEqual(@as(usize, 6 * GIB), Profile.medium.indexdDefaultMemoryLimitBytes());
    try std.testing.expectEqual(@as(usize, 8 * GIB), Profile.high.indexdDefaultMemoryLimitBytes());
}
