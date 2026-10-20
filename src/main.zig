const std = @import("std");

const build_options = @import("build_options");
const wl = @import("wayland").server.wl;
const wlr = @import("wlroots");
const c = @import("c");

pub fn main() !void {
    std.log.info("aion {s} {any} {any} {any}", .{ build_options.version, wl.Server, wlr.Backend, c.libinput_device });
}
