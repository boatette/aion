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

const max_column = 32;

/// The column's windows in order, top to bottom.
pub fn members(col: Column, buf: *[max_column]*Client) []*Client {
    const m = col.first.mon.?;
    var n: usize = 0;
    var link = &col.first.link;
    while (true) : (link = link.next.?) {
        const cl: *Client = @fieldParentPtr("link", link);
        if (tiledOn(cl, m) and n < buf.len) {
            buf[n] = cl;
            n += 1;
        }
        if (cl == col.last) break;
    }
    return buf[0..n];
}

/// The column dir columns away from cl's, clamped to the ends when far is set.
pub fn neighbour(cl: *const Client, dir: i32, far: bool) ?Column {
    const m = cl.mon orelse return null;
    const own = columnOf(cl) orelse return null;
    var it = Columns.init(m);
    var prev: ?Column = null;
    var found: ?Column = null;
    while (it.next()) |col| {
        if (dir < 0) {
            if (col.index == own.index) return if (far) found orelse null else prev;
            if (found == null) found = col;
        } else if (col.index > own.index) {
            if (!far) return col;
            found = col;
        }
        prev = col;
    }
    return if (dir > 0) found else null;
}

/// The window of a column focused most recently.
pub fn lastFocused(col: Column) *Client {
    var it = server.fstack.iterator(.forward);
    while (it.next()) |cl| if (col.contains(cl)) return cl;
    return col.first;
}

fn moveAfter(clients: []const *Client, anchor: *wl.list.Link) void {
    var a = anchor;
    for (clients) |cl| {
        cl.link.remove();
        a.insert(&cl.link);
        a = &cl.link;
    }
}

/// Swap a column with the one dir columns away (or the far end).
pub fn moveColumn(cl: *Client, dir: i32, far: bool) void {
    const own = columnOf(cl) orelse return;
    const other = neighbour(cl, dir, far) orelse return;
    var buf: [max_column]*Client = undefined;
    const mine = members(own, &buf);
    moveAfter(mine, if (dir > 0) &other.last.link else other.first.link.prev.?);
    reveal(cl);
}

/// Swap a window with its neighbour inside its column.
pub fn moveWindow(cl: *Client, dir: i32) void {
    const col = columnOf(cl) orelse return;
    var buf: [max_column]*Client = undefined;
    const ms = members(col, &buf);
    const i = std.mem.indexOfScalar(*Client, ms, cl).?;
    const j = @as(i64, @intCast(i)) + dir;
    if (j < 0 or j >= ms.len) return;
    const other = ms[@intCast(j)];
    cl.link.swapWith(&other.link);
    std.mem.swap(bool, &cl.stacked, &other.stacked);
    std.mem.swap(f32, &cl.width, &other.width);
    cl.mon.?.arrange();
}

/// Expel a window from a shared column, or move a lone window into the
/// neighbouring column.
pub fn consumeOrExpel(cl: *Client, dir: i32) void {
    const col = columnOf(cl) orelse return;
    var buf: [max_column]*Client = undefined;
    const ms = members(col, &buf);
    if (ms.len > 1) {
        if (!cl.stacked) {
            ms[1].stacked = false;
            ms[1].width = cl.width;
        }
        cl.width = col.first.width;
        cl.stacked = false;
        var anchor = if (dir > 0) &col.last.link else col.first.link.prev.?;
        if (anchor == &cl.link) anchor = cl.link.prev.?;
        moveAfter(&.{cl}, anchor);
    } else {
        const other = neighbour(cl, dir, false) orelse return;
        cl.stacked = true;
        moveAfter(&.{cl}, &other.last.link);
    }
    reveal(cl);
}

pub fn head(cl: *Client) ?*Client {
    return (columnOf(cl) orelse return null).first;
}

pub fn setWidth(cl: *Client, width: f32) void {
    const h = head(cl) orelse return;
    h.width = std.math.clamp(width, 0.05, 1);
    reveal(cl);
}

pub fn cycleWidth(cl: *Client, dir: i32) void {
    const h = head(cl) orelse return;
    const presets = config.width_presets;
    var next: f32 = if (dir > 0) presets[0] else presets[presets.len - 1];
    if (dir > 0) {
        for (presets) |p| if (p > h.width + 0.01) {
            next = p;
            break;
        };
    } else {
        var i = presets.len;
        while (i > 0) : (i -= 1) if (presets[i - 1] < h.width - 0.01) {
            next = presets[i - 1];
            break;
        };
    }
    setWidth(cl, next);
}

pub fn toggleFullWidth(cl: *Client) void {
    const h = head(cl) orelse return;
    if (h.width >= 0.999) {
        setWidth(cl, if (h.saved_width > 0) h.saved_width else config.default_width);
    } else {
        h.saved_width = h.width;
        setWidth(cl, 1);
    }
}

/// Grow or shrink a window's share of its column's height by delta.
pub fn changeHeight(cl: *Client, delta: f32) void {
    const col = columnOf(cl) orelse return;
    var buf: [max_column]*Client = undefined;
    const ms = members(col, &buf);
    if (ms.len < 2) return;
    var total: f32 = 0;
    for (ms) |x| total += x.weight;
    const rest = total - cl.weight;
    const share = std.math.clamp(cl.weight / total + delta, 0.05, 0.95);
    cl.weight = share * rest / (1 - share);
    cl.mon.?.arrange();
}
