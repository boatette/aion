const std = @import("std");
const Io = std.Io;

const build_options = @import("build_options");

pub fn main(init: std.process.Init) !void {
    comptime {
        _ = @import("wayland");
        _ = @import("wlroots");
        _ = @import("xkbcommon");
        _ = @import("pixman");
        _ = @import("c");
        _ = @import("aion");
    }

    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);
    if (args.len > 1) {
        if (std.mem.eql(u8, args[1], "--version") or std.mem.eql(u8, args[1], "-version")) {
            try writeStdout(init.io, build_options.version ++ "\n");
            return;
        }
        if (std.mem.eql(u8, args[1], "--help") or std.mem.eql(u8, args[1], "-h")) {
            try writeStdout(init.io, "usage: aion [--version]\n");
            return;
        }
    }

    std.log.info("aion {s}", .{build_options.version});
}

fn writeStdout(io: Io, bytes: []const u8) !void {
    var buffer: [256]u8 = undefined;
    var file_writer: Io.File.Writer = .init(.stdout(), io, &buffer);
    const writer = &file_writer.interface;
    try writer.writeAll(bytes);
    try writer.flush();
}
