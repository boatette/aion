const std = @import("std");
const wl = @import("wayland").server.wl;
const wlr = @import("wlroots");
const xkb = @import("xkbcommon");
const c = @import("c");

const config = @import("config.zig");
const input = @import("input.zig");
const server = &@import("main.zig").server;
const Client = @import("Client.zig");
const Monitor = @import("Monitor.zig");

pub const SHIFT: u32 = 1 << 0;
pub const CTRL: u32 = 1 << 2;
pub const ALT: u32 = 1 << 3;
pub const LOGO: u32 = 1 << 6;

pub const Arg = extern union {
    i: i32,
    ui: u32,
    f: f32,
    v: ?*const anyopaque,
    argv: [*:null]const ?[*:0]const u8,
};

pub const Func = *const fn (*const Arg) void;

pub const Key = struct {
    mod: u32,
    sym: xkb.Keysym,
    func: Func,
    arg: Arg = .{ .i = 0 },
};

pub const Button = struct {
    mod: u32,
    button: u32,
    func: Func,
    arg: Arg = .{ .i = 0 },
};

pub const Layout = struct {
    symbol: [:0]const u8,
    arrange: ?*const fn (*Monitor) void,
};

pub const Rule = struct {
    app_id: ?[]const u8 = null,
    title: ?[]const u8 = null,
    tags: u32 = 0,
    floating: bool = false,
    monitor: i32 = -1,
};

pub const MonitorRule = struct {
    name: ?[]const u8 = null,
    scale: f32 = 1,
    layout: *const Layout = &config.layouts[0],
    transform: wl.Output.Transform = .normal,
    x: i32 = -1,
    y: i32 = -1,
};

pub fn color(comptime hex: u32) [4]f32 {
    return .{
        @as(f32, @floatFromInt((hex >> 24) & 0xff)) / 255,
        @as(f32, @floatFromInt((hex >> 16) & 0xff)) / 255,
        @as(f32, @floatFromInt((hex >> 8) & 0xff)) / 255,
        @as(f32, @floatFromInt(hex & 0xff)) / 255,
    };
}

pub fn cmd(comptime argv: []const [:0]const u8) Arg {
    const S = struct {
        const a = blk: {
            var arr: [argv.len:null]?[*:0]const u8 = undefined;
            for (argv, 0..) |s, i| arr[i] = s.ptr;
            break :blk arr;
        };
    };
    return .{ .argv = &S.a };
}

pub fn sh(comptime s: [:0]const u8) Arg {
    return cmd(&.{ "/bin/sh", "-c", s });
}

pub fn spawn(arg: *const Arg) void {
    spawnArgv(arg.argv);
}

/// Double fork so children are reparented and never need reaping here.
pub fn spawnArgv(argv: [*:null]const ?[*:0]const u8) void {
    const pid = c.fork();
    if (pid == 0) {
        if (c.fork() == 0) {
            resetChild();
            _ = c.execvp(argv[0].?, @ptrCast(argv));
            c._exit(127);
        }
        c._exit(0);
    }
    if (pid > 0) _ = c.waitpid(pid, null, 0);
}

/// Undo what the compositor changed for itself before exec'ing a client.
pub fn resetChild() void {
    _ = c.setsid();
    var set: c.sigset_t = undefined;
    _ = c.sigemptyset(&set);
    _ = c.sigprocmask(c.SIG_SETMASK, &set, null);
}

pub fn quit(_: *const Arg) void {
    server.wl_server.terminate();
}

pub fn killclient(_: *const Arg) void {
    if (server.focustop(server.selmon)) |sel| sel.close();
}

pub fn focusstack(arg: *const Arg) void {
    const sel = server.focustop(server.selmon) orelse return;
    if (sel.fullscreen) return;
    var link = &sel.link;
    while (true) {
        link = if (arg.i > 0) link.next.? else link.prev.?;
        if (link == &server.clients.link) continue;
        const cl: *Client = @fieldParentPtr("link", link);
        if (cl == sel) return;
        if (cl.visibleOn(server.selmon)) {
            server.focus(cl, true);
            return;
        }
    }
}

pub fn moveresize(arg: *const Arg) void {
    input.grab(if (arg.ui == 0) .move else .resize);
}
