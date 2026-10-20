const std = @import("std");
const wl = @import("wayland").server.wl;
const wlr = @import("wlroots");

const config = @import("config.zig");
const server = &@import("main.zig").server;
const Client = @import("Client.zig");
const Monitor = @import("Monitor.zig");

pub const Column = struct {
    first: *Client,
    last: *Client,
    /// Position in the strip and width, in pixels.
    x: i32,
    w: i32,
    index: u32,

    pub fn contains(col: Column, cl: *const Client) bool {
        var link = &col.first.link;
        while (true) : (link = link.next.?) {
            const cur: *Client = @fieldParentPtr("link", link);
            if (cur == cl) return true;
            if (cur == col.last) return false;
        }
    }
};

pub fn tiledOn(cl: *const Client, m: *const Monitor) bool {
    return cl.tiled() and cl.visibleOn(m);
}

pub fn isScrolling(m: *const Monitor) bool {
    return m.layout().arrange == arrange;
}

pub fn columnWidth(cl: *const Client, m: *const Monitor) i32 {
    const w: i32 = @intFromFloat(@round(cl.width * @as(f32, @floatFromInt(m.w.width))));
    return std.math.clamp(w, 1, @max(m.w.width, 1));
}

/// Walks the columns of a monitor's current view, left to right.
pub const Columns = struct {
    m: *Monitor,
    link: *wl.list.Link,
    x: i32 = 0,
    index: u32 = 0,

    pub fn init(m: *Monitor) Columns {
        return .{ .m = m, .link = &server.clients.link };
    }

    fn nextTiled(it: *const Columns, from: *wl.list.Link) ?*Client {
        var link = from.next.?;
        while (link != &server.clients.link) : (link = link.next.?) {
            const cl: *Client = @fieldParentPtr("link", link);
            if (tiledOn(cl, it.m)) return cl;
        }
        return null;
    }

    pub fn next(it: *Columns) ?Column {
        const first = it.nextTiled(it.link) orelse return null;
        var last = first;
        while (it.nextTiled(&last.link)) |cl| {
            if (!cl.stacked) break;
            last = cl;
        }
        it.link = &last.link;
        const col: Column = .{ .first = first, .last = last, .x = it.x, .w = columnWidth(first, it.m), .index = it.index };
        it.x += col.w;
        it.index += 1;
        return col;
    }
};

pub fn columnOf(cl: *const Client) ?Column {
    const m = cl.mon orelse return null;
    if (!tiledOn(cl, m)) return null;
    var it = Columns.init(m);
    while (it.next()) |col| if (col.contains(cl)) return col;
    return null;
}

pub fn slot(m: *const Monitor) usize {
    const t = m.tags();
    return if (@popCount(t) == 1) @ctz(t) else config.tags.len;
}

pub fn arrange(m: *Monitor) void {
    var total: i32 = 0;
    var n: u32 = 0;
    var it = Columns.init(m);
    while (it.next()) |col| {
        total += col.w;
        n += 1;
    }

    const s = &m.scroll[slot(m)];
    s.* = std.math.clamp(s.*, 0, @max(0, total - m.w.width));

    var focused: u32 = 0;
    const sel = server.focustop(m);
    it = Columns.init(m);
    while (it.next()) |col| {
        const left = m.w.x + col.x - s.*;
        const visible = left < m.w.x + m.w.width and left + col.w > m.w.x;
        if (sel != null and col.contains(sel.?)) focused = col.index + 1;

        var weights: f32 = 0;
        var link = &col.first.link;
        while (true) : (link = link.next.?) {
            const cl: *Client = @fieldParentPtr("link", link);
            if (tiledOn(cl, m)) weights += cl.weight;
            if (cl == col.last) break;
        }

        var y = m.w.y;
        link = &col.first.link;
        while (true) : (link = link.next.?) {
            const cl: *Client = @fieldParentPtr("link", link);
            if (tiledOn(cl, m)) {
                const h = if (cl == col.last)
                    m.w.y + m.w.height - y
                else
                    @as(i32, @intFromFloat(@round(@as(f32, @floatFromInt(m.w.height)) * cl.weight / weights)));
                cl.resize(.{ .x = left, .y = y, .width = col.w, .height = h }, false);
                cl.scene.node.setEnabled(visible);
                cl.setSuspended(!visible);
                y += h;
            }
            if (cl == col.last) break;
        }
    }

    var buf: [16]u8 = undefined;
    m.setSymbol(if (n == 0) "[S]" else std.fmt.bufPrint(&buf, "[{d}/{d}]", .{ focused, n }) catch "[S]");
}

pub fn monocle(m: *Monitor) void {
    var n: u32 = 0;
    var it = server.clients.iterator(.forward);
    while (it.next()) |cl| {
        if (!tiledOn(cl, m)) continue;
        cl.resize(m.w, false);
        n += 1;
    }
    var buf: [16]u8 = undefined;
    if (n > 0) m.setSymbol(std.fmt.bufPrint(&buf, "[{d}]", .{n}) catch "[M]");
    if (server.focustop(m)) |cl| cl.scene.node.raiseToTop();
}

/// Scroll just enough for the client's column to be fully visible.
pub fn reveal(cl: *Client) void {
    const m = cl.mon orelse return;
    if (!isScrolling(m)) return;
    const col = columnOf(cl) orelse return;
    const s = &m.scroll[slot(m)];
    if (col.w >= m.w.width or col.x < s.*) {
        s.* = col.x;
    } else if (col.x + col.w > s.* + m.w.width) {
        s.* = col.x + col.w - m.w.width;
    }
    m.arrange();
}

pub fn center(cl: *Client) void {
    const m = cl.mon orelse return;
    if (!isScrolling(m)) return;
    const col = columnOf(cl) orelse return;
    m.scroll[slot(m)] = col.x + @divTrunc(col.w - m.w.width, 2);
    m.arrange();
}

/// New windows open as a column right after the focused one.
pub fn insert(cl: *Client) void {
    if (server.focustop(server.selmon)) |sel| {
        if (columnOf(sel)) |col| {
            col.last.link.insert(&cl.link);
            return;
        }
    }
    server.clients.append(cl);
}

/// Hand a leaving column head's place to the next window in its column.
pub fn remove(cl: *Client) void {
    if (cl.stacked) return;
    const m = cl.mon orelse return;
    var link = cl.link.next.?;
    while (link != &server.clients.link) : (link = link.next.?) {
        const next: *Client = @fieldParentPtr("link", link);
        if (next.mon != m or next.tags & cl.tags == 0 or !next.tiled()) continue;
        if (next.stacked) {
            next.stacked = false;
            next.width = cl.width;
        }
        return;
    }
}

/// Size for a window's first configure, before it is mapped.
pub fn initialSize(cl: *const Client) [2]i32 {
    const m = server.selmon orelse return .{ 0, 0 };
    if (cl.parent() != null or Client.ruleFloating(cl) or m.layout().arrange == null) return .{ 0, 0 };
    const bw = 2 * config.borderpx;
    if (!isScrolling(m)) return .{ m.w.width - bw, m.w.height - bw };
    return .{ columnWidth(cl, m) - bw, m.w.height - bw };
}
