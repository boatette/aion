const std = @import("std");
const wl = @import("wayland").server.wl;
const wlr = @import("wlroots");
const xkb = @import("xkbcommon");
const c = @import("c");

const config = @import("config.zig");
const input = @import("input.zig");
const scroll = @import("scroll.zig");
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
            focus(cl);
            return;
        }
    }
}

pub fn moveresize(arg: *const Arg) void {
    input.grab(if (arg.ui == 0) .move else .resize);
}

/// Keyboard-driven focus: also scrolls the window's column into view.
pub fn focus(cl: *Client) void {
    server.focus(cl, true);
    if (cl.tiled()) scroll.reveal(cl);
}

fn tagmask() u32 {
    return (@as(u32, 1) << config.tags.len) - 1;
}

pub fn view(arg: *const Arg) void {
    const m = server.selmon orelse return;
    const t = arg.ui & tagmask();
    if (t == m.tags()) return;
    m.seltags ^= 1;
    if (t != 0) m.tagset[m.seltags] = t;
    server.focus(server.focustop(m), true);
    m.arrange();
}

pub fn toggleview(arg: *const Arg) void {
    const m = server.selmon orelse return;
    const t = m.tags() ^ (arg.ui & tagmask());
    if (t == 0) return;
    m.tagset[m.seltags] = t;
    server.focus(server.focustop(m), true);
    m.arrange();
}

/// Moving to another tag opens the window as that tag's last column.
fn retag(cl: *Client, t: u32) void {
    scroll.remove(cl);
    cl.link.remove();
    server.clients.append(cl);
    cl.stacked = false;
    cl.tags = t;
}

pub fn tag(arg: *const Arg) void {
    const sel = server.focustop(server.selmon) orelse return;
    const t = arg.ui & tagmask();
    if (t == 0) return;
    retag(sel, t);
    server.focus(server.focustop(server.selmon), true);
    server.selmon.?.arrange();
}

pub fn toggletag(arg: *const Arg) void {
    const sel = server.focustop(server.selmon) orelse return;
    const t = sel.tags ^ (arg.ui & tagmask());
    if (t == 0) return;
    sel.tags = t;
    server.focus(server.focustop(server.selmon), true);
    server.selmon.?.arrange();
}

pub fn tagfollow(arg: *const Arg) void {
    const sel = server.focustop(server.selmon) orelse return;
    if (arg.ui & tagmask() == 0) return;
    tag(arg);
    view(arg);
    focus(sel);
}

fn seltag() ?u5 {
    const m = server.selmon orelse return null;
    const t = m.tags();
    return if (t == 0) null else @ctz(t);
}

/// Previous/next tag, without wrapping.
pub fn viewrel(arg: *const Arg) void {
    const i: i32 = seltag() orelse return;
    const n = i + arg.i;
    if (n < 0 or n >= config.tags.len) return;
    view(&.{ .ui = @as(u32, 1) << @intCast(n) });
}

pub fn tagrel(arg: *const Arg) void {
    const i: i32 = seltag() orelse return;
    const n = i + arg.i;
    if (n < 0 or n >= config.tags.len) return;
    tagfollow(&.{ .ui = @as(u32, 1) << @intCast(n) });
}

pub fn focusmon(arg: *const Arg) void {
    const n = server.monitors.length();
    var i: usize = 0;
    while (i < n) : (i += 1) {
        server.selmon = server.dirtomon(@enumFromInt(arg.i));
        if (server.selmon != null and server.selmon.?.output.enabled) break;
    }
    server.focus(server.focustop(server.selmon), true);
}

pub fn tagmon(arg: *const Arg) void {
    const sel = server.focustop(server.selmon) orelse return;
    const m = server.dirtomon(@enumFromInt(arg.i)) orelse return;
    scroll.remove(sel);
    sel.link.remove();
    server.clients.append(sel);
    sel.setMon(m, 0);
}

pub fn setlayout(arg: *const Arg) void {
    const m = server.selmon orelse return;
    const lt: ?*const Layout = @ptrCast(@alignCast(arg.v));
    if (lt == null or lt.? != m.layout()) m.sellt ^= 1;
    if (lt) |l| m.lt[m.sellt] = l;
    m.arrange();
    if (server.focustop(m)) |sel| if (sel.tiled()) scroll.reveal(sel);
}

pub fn togglefloating(_: *const Arg) void {
    const sel = server.focustop(server.selmon) orelse return;
    if (sel.fullscreen) return;
    if (!sel.floating) scroll.remove(sel);
    sel.stacked = false;
    sel.setFloating(!sel.floating);
    if (sel.tiled()) scroll.reveal(sel);
}

pub fn togglefullscreen(_: *const Arg) void {
    const sel = server.focustop(server.selmon) orelse return;
    sel.setFullscreen(!sel.fullscreen);
}

pub fn chvt(arg: *const Arg) void {
    if (server.session) |s| s.changeVt(arg.ui) catch {};
}

/// SIGKILL the focused window's process, for apps that ignore a close.
pub fn forcekill(_: *const Arg) void {
    const sel = server.focustop(server.selmon) orelse return;
    const pid = sel.pid();
    if (pid > 0) _ = c.kill(pid, c.SIGKILL);
}

pub const Dir = enum(u32) { left, right, up, down };

/// Nearest visible window in a direction, by distance between corners.
pub fn focusnearest(arg: *const Arg) void {
    const sel = server.focustop(server.selmon) orelse return;
    if (sel.fullscreen) return;
    const dir: Dir = @enumFromInt(arg.ui);
    var best: ?*Client = null;
    var best_dist: i64 = std.math.maxInt(i64);
    var it = server.clients.iterator(.forward);
    while (it.next()) |cl| {
        if (cl == sel or !cl.visibleOn(server.selmon)) continue;
        const ok = switch (dir) {
            .left => cl.geom.x < sel.geom.x,
            .right => cl.geom.x > sel.geom.x,
            .up => cl.geom.y < sel.geom.y,
            .down => cl.geom.y > sel.geom.y,
        };
        if (!ok) continue;
        const dist = @as(i64, @abs(sel.geom.x - cl.geom.x)) + @abs(sel.geom.y - cl.geom.y);
        if (dist < best_dist) {
            best_dist = dist;
            best = cl;
        }
    }
    if (best) |b| focus(b);
}

fn selTiled() ?*Client {
    const m = server.selmon orelse return null;
    const sel = server.focustop(m) orelse return null;
    return if (sel.tiled() and scroll.isScrolling(m)) sel else null;
}

/// Move a window one place along the strip order; used outside the scroll layout.
pub fn movestack(arg: *const Arg) void {
    const sel = server.focustop(server.selmon) orelse return;
    var link = &sel.link;
    while (true) {
        link = if (arg.i > 0) link.next.? else link.prev.?;
        if (link == &sel.link) return;
        if (link == &server.clients.link) continue;
        const cl: *Client = @fieldParentPtr("link", link);
        if (cl.visibleOn(server.selmon)) break;
    }
    sel.link.remove();
    if (arg.i > 0) link.insert(&sel.link) else link.prev.?.insert(&sel.link);
    server.selmon.?.arrange();
}

/// h/j/k/l: columns and windows in a column in the scroll layout, the stack
/// in monocle, and the nearest window for floating ones.
pub fn focusdir(arg: *const Arg) void {
    const m = server.selmon orelse return;
    const sel = server.focustop(m) orelse return;
    const dir: Dir = @enumFromInt(arg.ui);
    const step: i32 = if (dir == .left or dir == .up) -1 else 1;
    if (m.layout().arrange == scroll.monocle) return focusstack(&.{ .i = step });
    if (selTiled() == null) return focusnearest(arg);
    switch (dir) {
        .left, .right => if (scroll.neighbour(sel, step, false)) |col| focus(scroll.lastFocused(col)),
        .up, .down => {
            const col = scroll.columnOf(sel) orelse return;
            var buf: [32]*Client = undefined;
            const ms = scroll.members(col, &buf);
            const i: i64 = @intCast(std.mem.indexOfScalar(*Client, ms, sel).?);
            if (i + step >= 0 and i + step < ms.len) focus(ms[@intCast(i + step)]);
        },
    }
}

pub fn focusend(arg: *const Arg) void {
    const sel = selTiled() orelse return;
    if (scroll.neighbour(sel, arg.i, true)) |col| focus(scroll.lastFocused(col));
}

pub fn movecolumn(arg: *const Arg) void {
    const sel = selTiled() orelse return movestack(arg);
    scroll.moveColumn(sel, arg.i, false);
}

pub fn movecolumnend(arg: *const Arg) void {
    const sel = selTiled() orelse return;
    scroll.moveColumn(sel, arg.i, true);
}

pub fn movewindow(arg: *const Arg) void {
    const sel = selTiled() orelse return movestack(arg);
    scroll.moveWindow(sel, arg.i);
}

pub fn consumeorexpel(arg: *const Arg) void {
    if (selTiled()) |sel| scroll.consumeOrExpel(sel, arg.i);
}

pub fn centercolumn(_: *const Arg) void {
    if (selTiled()) |sel| scroll.center(sel);
}

pub fn setwidth(arg: *const Arg) void {
    const sel = selTiled() orelse return;
    const h = scroll.head(sel) orelse return;
    scroll.setWidth(sel, h.width + arg.f);
}

pub fn cyclewidth(arg: *const Arg) void {
    if (selTiled()) |sel| scroll.cycleWidth(sel, arg.i);
}

pub fn togglefullwidth(_: *const Arg) void {
    if (selTiled()) |sel| scroll.toggleFullWidth(sel);
}

pub fn setheight(arg: *const Arg) void {
    if (selTiled()) |sel| scroll.changeHeight(sel, arg.f);
}
