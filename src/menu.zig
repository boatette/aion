//! Key modes shown in the bar: session keys (one key picks an action) and a
//! dmenu-like launcher. A mode takes the keyboard until it ends.

const std = @import("std");
const wl = @import("wayland").server.wl;
const xkb = @import("xkbcommon");
const c = @import("c");

const config = @import("config.zig");
const actions = @import("actions.zig");
const server = &@import("main.zig").server;
const Bar = @import("Bar.zig");

const gpa = std.heap.c_allocator;
const K = xkb.Keysym;

const Mode = enum { none, session, launch };
var mode: Mode = .none;

const App = struct { name: []const u8, path: [:0]const u8 };
var apps_text: std.ArrayList(u8) = .empty;
var apps: std.ArrayList(App) = .empty;
var matches: std.ArrayList(usize) = .empty;
var selected: usize = 0;
var first: usize = 0;
var query_buf: [128]u8 = undefined;
var query_len: usize = 0;
var loader_source: ?*wl.EventSource = null;
var loader_pid: c.pid_t = 0;

pub fn active() bool {
    return mode != .none;
}

fn setMode(m: Mode) void {
    if (mode == m) return;
    mode = m;
    Bar.redraw();
}

pub fn session(_: *const actions.Arg) void {
    setMode(.session);
}

pub fn launcher(_: *const actions.Arg) void {
    query_len = 0;
    loadApps();
    filter();
    setMode(.launch);
}

pub fn key(mods: u32, sym: K) void {
    switch (mode) {
        .none => {},
        .session => sessionKey(sym),
        .launch => launchKey(mods, sym),
    }
}

fn isModifier(sym: K) bool {
    const v = @intFromEnum(sym);
    return v >= @intFromEnum(K.Shift_L) and v <= @intFromEnum(K.Hyper_R);
}

fn sessionKey(sym: K) void {
    const lower = sym.toLower();
    // A held Mod+x repeats x, which must not end the mode.
    if (isModifier(sym) or lower == K.x) return;
    setMode(.none);
    for (&config.session_keys) |*k| {
        if (lower == k.sym) return k.func(&k.arg);
    }
}

fn query() []const u8 {
    return query_buf[0..query_len];
}

fn launchKey(mods_in: u32, sym_in: K) void {
    var sym = sym_in;
    if (sym == K.Tab and mods_in & actions.SHIFT != 0) sym = K.ISO_Left_Tab;
    const mods = mods_in & (actions.LOGO | actions.CTRL | actions.ALT);
    if (mods == actions.CTRL and sym == K.n) {
        sym = K.Down;
    } else if (mods == actions.CTRL and sym == K.p) {
        sym = K.Up;
    } else if (mods == actions.CTRL and sym == K.u) {
        sym = K.Clear;
    } else if (mods != 0) {
        return;
    }

    var dir: i32 = 0;
    if (sym == K.Escape) {
        return setMode(.none);
    } else if (sym == K.Return or sym == K.KP_Enter) {
        setMode(.none);
        if (matches.items.len > 0) launch(apps.items[matches.items[selected]].path);
        return;
    } else if (sym == K.Tab or sym == K.Right or sym == K.Down) {
        dir = 1;
    } else if (sym == K.ISO_Left_Tab or sym == K.Left or sym == K.Up) {
        dir = -1;
    } else if (sym == K.Clear) {
        query_len = 0;
    } else if (sym == K.BackSpace) {
        // Drop the last UTF-8 character.
        while (query_len > 0) {
            query_len -= 1;
            if (query_buf[query_len] & 0xc0 != 0x80) break;
        }
    } else {
        const cp = sym.toUTF32();
        if (cp < 0x20 or cp == 0x7f) return;
        var utf8: [8]u8 = undefined;
        const n = sym.toUTF8(&utf8, utf8.len);
        // toUTF8 counts the terminating NUL.
        if (n <= 1 or query_len + @as(usize, @intCast(n - 1)) > query_buf.len) return;
        const len: usize = @intCast(n - 1);
        @memcpy(query_buf[query_len..][0..len], utf8[0..len]);
        query_len += len;
    }

    if (dir != 0) {
        const n = matches.items.len;
        if (n > 0) selected = @intCast(@mod(@as(i64, @intCast(selected)) + dir, @as(i64, @intCast(n))));
    } else {
        filter();
    }
    Bar.redraw();
}

fn launch(path: [:0]const u8) void {
    const prefix = config.launch_cmd;
    var argv: [prefix.len + 2]?[*:0]const u8 = undefined;
    for (prefix, 0..) |a, i| argv[i] = a.ptr;
    argv[prefix.len] = path.ptr;
    argv[prefix.len + 1] = null;
    actions.spawnArgv(@ptrCast(&argv));
}

/// Names starting with the query first, then the rest that contain it.
fn filter() void {
    matches.clearRetainingCapacity();
    selected = 0;
    first = 0;
    const q = query();
    for ([_]bool{ true, false }) |prefix| {
        for (apps.items, 0..) |app, i| {
            const at = std.ascii.indexOfIgnoreCase(app.name, q) orelse continue;
            if ((at == 0) == prefix) matches.append(gpa, i) catch return;
        }
    }
}

/// Read the app list again every time, so new installs show up. It loads in
/// the background; typing filters whatever has arrived.
fn loadApps() void {
    if (loader_source != null) return;
    apps_text.clearRetainingCapacity();
    apps.clearRetainingCapacity();
    var fds: [2]c_int = undefined;
    if (c.pipe(&fds) != 0) return;
    const pid = c.fork();
    if (pid < 0) return;
    if (pid == 0) {
        const devnull = c.open("/dev/null", c.O_RDONLY);
        _ = c.dup2(devnull, 0);
        _ = c.dup2(fds[1], 1);
        _ = c.close(fds[0]);
        _ = c.close(fds[1]);
        actions.resetChild();
        const argv = config.apps_cmd.argv;
        _ = c.execvp(argv[0].?, @ptrCast(argv));
        c._exit(127);
    }
    _ = c.close(fds[1]);
    _ = c.fcntl(fds[0], c.F_SETFD, c.FD_CLOEXEC);
    loader_pid = pid;
    loader_source = server.wl_server.getEventLoop().addFd(?*anyopaque, fds[0], .{ .readable = true }, onApps, null) catch null;
}

fn onApps(fd: c_int, _: wl.EventMask, _: ?*anyopaque) c_int {
    var chunk: [4096]u8 = undefined;
    const n = c.read(fd, &chunk, chunk.len);
    if (n > 0) {
        apps_text.appendSlice(gpa, chunk[0..@intCast(n)]) catch {};
        return 0;
    }
    loader_source.?.remove();
    loader_source = null;
    _ = c.close(fd);
    _ = c.waitpid(loader_pid, null, 0);
    parseApps();
    filter();
    Bar.redraw();
    return 0;
}

/// Lines are "Name<TAB>path"; paths get NUL-terminated in place for exec.
fn parseApps() void {
    apps.clearRetainingCapacity();
    apps_text.append(gpa, '\n') catch return;
    var start: usize = 0;
    const text = apps_text.items;
    for (text, 0..) |ch, i| {
        if (ch != '\n') continue;
        const line = text[start..i];
        if (std.mem.indexOfScalar(u8, line, '\t')) |tab| {
            text[i] = 0;
            apps.append(gpa, .{ .name = line[0..tab], .path = text[start + tab + 1 .. i :0] }) catch return;
        }
        start = i + 1;
    }
}

/// Clear the rest of the bar and draw the mode's prompt; returns where it ends.
fn prompt(p: *Bar.Painter, x: i32, width: i32, s: []const u8) i32 {
    p.scheme = config.bar_norm;
    p.rect(x, 0, width - x, p.height, true, true);
    p.scheme = config.bar_sel;
    return p.text(x, p.textw(s), @divTrunc(p.pad(), 2), s, false);
}

/// Called by the bar on the selected monitor, with where the layout symbol ends.
pub fn draw(p: *Bar.Painter, x0: i32, width: i32) bool {
    switch (mode) {
        .none => return false,
        .session => {
            const x = prompt(p, x0, width, "session");
            p.scheme = config.bar_norm;
            _ = p.text(x, width - x, @divTrunc(p.pad(), 2), config.session_hint, false);
        },
        .launch => {
            var x = prompt(p, x0, width, "run");
            const inputw = @divTrunc(width, 6);
            const lpad = @divTrunc(p.pad(), 2);
            p.scheme = config.bar_norm;
            _ = p.text(x, inputw, lpad, query(), false);
            const fh = p.font.height;
            p.rect(x + @min(lpad + p.textWidth(query()), inputw - 2), @divTrunc(p.height - fh, 2) + 2, 2, fh - 4, true, false);
            x += inputw;

            // Scroll so the selected match fits.
            const ms = matches.items;
            if (selected < first) first = selected;
            while (first < selected) : (first += 1) {
                var end = x;
                for (ms[first .. selected + 1]) |i| end += p.textw(apps.items[i].name);
                if (end <= width) break;
            }

            var i = first;
            while (i < ms.len and x < width) : (i += 1) {
                const name = apps.items[ms[i]].name;
                const w = @min(p.textw(name), width - x);
                p.scheme = if (i == selected) config.bar_sel else config.bar_norm;
                x = p.text(x, w, lpad, name, false);
            }
        },
    }
    return true;
}
