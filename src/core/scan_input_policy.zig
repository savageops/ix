const std = @import("std");

pub const ENV = "IX_SCAN_INPUT_POLICY";

pub const Mode = enum {
    auto,
    mmap,
    buffered,

    pub fn label(self: Mode) []const u8 {
        return switch (self) {
            .auto => "auto",
            .mmap => "mmap",
            .buffered => "buffered",
        };
    }

    pub fn shouldAttemptMmap(self: Mode) bool {
        return self != .buffered;
    }
};

pub fn current() Mode {
    const value_ptr = std.c.getenv(ENV) orelse return .auto;
    return parse(std.mem.span(value_ptr));
}

pub fn parse(raw: []const u8) Mode {
    if (raw.len == 0) return .auto;
    if (std.ascii.eqlIgnoreCase(raw, "mmap")) return .mmap;
    if (std.ascii.eqlIgnoreCase(raw, "buffered")) return .buffered;
    return .auto;
}

test "scan input policy parser defaults to auto" {
    try std.testing.expectEqual(Mode.auto, parse(""));
    try std.testing.expectEqual(Mode.auto, parse("unexpected"));
}

test "scan input policy parser accepts explicit modes" {
    try std.testing.expectEqual(Mode.auto, parse("auto"));
    try std.testing.expectEqual(Mode.mmap, parse("mmap"));
    try std.testing.expectEqual(Mode.buffered, parse("buffered"));
}
