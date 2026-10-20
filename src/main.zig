const std = @import("std");
const build_options = @import("build_options");
const wlr = @import("wlroots");
const c = @import("c");

const Server = @import("Server.zig");

pub var server: Server = undefined;

pub const std_options: std.Options = .{ .log_level = .info };

fn usage() noreturn {
    write(2, "usage: aion [-v] [-d] [-s startup command]\n");
    c.exit(1);
}

fn write(fd: c_int, s: []const u8) void {
    _ = c.write(fd, s.ptr, s.len);
}

fn quitSignal(_: std.posix.SIG) callconv(.c) void {
    server.wl_server.terminate();
}

fn setupSignals() void {
    const posix = std.posix;
    const quit: posix.Sigaction = .{ .handler = .{ .handler = quitSignal }, .mask = posix.sigemptyset(), .flags = posix.SA.RESTART };
    posix.sigaction(.INT, &quit, null);
    posix.sigaction(.TERM, &quit, null);
    // A status command exiting must not take the compositor with it.
    const ignore: posix.Sigaction = .{ .handler = .{ .handler = posix.SIG.IGN }, .mask = posix.sigemptyset(), .flags = 0 };
    posix.sigaction(.PIPE, &ignore, null);
}

pub fn main(init: std.process.Init.Minimal) !void {
    var startup: ?[*:0]const u8 = null;
    var debug = false;

    var args = init.args.iterate();
    _ = args.next();
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "-v") or std.mem.eql(u8, arg, "--version")) {
            write(1, "aion " ++ build_options.version ++ "\n");
            return;
        } else if (std.mem.eql(u8, arg, "-d")) {
            debug = true;
        } else if (std.mem.eql(u8, arg, "-s")) {
            startup = (args.next() orelse usage()).ptr;
        } else usage();
    }

    if (c.getenv("XDG_RUNTIME_DIR") == null) {
        write(2, "XDG_RUNTIME_DIR must be set\n");
        c.exit(1);
    }

    wlr.log.init(if (debug) .debug else .err, null);

    try server.init();
    setupSignals();
    defer server.deinit();
    try server.start(startup);
    server.wl_server.run();
}
