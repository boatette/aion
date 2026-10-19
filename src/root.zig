const std = @import("std");

test "smoke" {
    try std.testing.expect(std.mem.eql(u8, "aion", "aion"));
}
