const std = @import("std");

pub const OPEN_TIMING_ENV = "IX_SCAN_OPEN_TIMING";

pub fn captureOpenTiming() bool {
    const value_ptr = std.c.getenv(OPEN_TIMING_ENV) orelse return false;
    const value = std.mem.span(value_ptr);
    if (value.len == 0) return false;
    if (std.mem.eql(u8, value, "0")) return false;
    if (std.ascii.eqlIgnoreCase(value, "false")) return false;
    if (std.ascii.eqlIgnoreCase(value, "off")) return false;
    if (std.ascii.eqlIgnoreCase(value, "no")) return false;
    return true;
}

test "open timing env parser defaults off for absent variable" {
    try std.testing.expect(!captureOpenTiming());
}
