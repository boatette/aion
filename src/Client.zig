const Client = @This();

const std = @import("std");
const wl = @import("wayland").server.wl;
const wlr = @import("wlroots");

const config = @import("config.zig");
const input = @import("input.zig");
const scroll = @import("scroll.zig");
const server = &@import("main.zig").server;
const Monitor = @import("Monitor.zig");

const gpa = std.heap.c_allocator;

/// Strip order; columns are runs of visible tiled clients in this list.
link: wl.list.Link = undefined,
/// Focus order, most recent first.
flink: wl.list.Link = undefined,
toplevel: *wlr.XdgToplevel,
scene: *wlr.SceneTree = undefined,
scene_surface: *wlr.SceneTree = undefined,
border: [4]*wlr.SceneRect = undefined,
geom: wlr.Box = .{ .x = 0, .y = 0, .width = 0, .height = 0 },
prev: wlr.Box = .{ .x = 0, .y = 0, .width = 0, .height = 0 },
mon: ?*Monitor = null,
tags: u32 = 0,
bw: i32 = config.borderpx,
floating: bool = false,
fullscreen: bool = false,
urgent: bool = false,
suspended: bool = false,
activated: bool = false,
/// Joins the column of the visible tiled client before it.
stacked: bool = false,
/// Column width as a fraction of the monitor, read from a column's first client.
width: f32 = config.default_width,
/// Share of the column's height.
weight: f32 = 1,
/// Width to go back to when full width is toggled off.
saved_width: f32 = 0,
resize_serial: u32 = 0,

commit: wl.Listener(*wlr.Surface) = .init(onCommit),
map: wl.Listener(void) = .init(onMap),
unmap: wl.Listener(void) = .init(onUnmap),
destroy: wl.Listener(void) = .init(onDestroy),
set_title: wl.Listener(void) = .init(onSetTitle),
request_fullscreen: wl.Listener(void) = .init(onRequestFullscreen),
request_maximize: wl.Listener(void) = .init(onRequestMaximize),

pub fn createXdg(_: *wl.Listener(*wlr.XdgToplevel), toplevel: *wlr.XdgToplevel) void {
    const cl = gpa.create(Client) catch return;
    cl.* = .{ .toplevel = toplevel };
    toplevel.base.data = cl;
    toplevel.base.surface.events.commit.add(&cl.commit);
    toplevel.base.surface.events.map.add(&cl.map);
    toplevel.base.surface.events.unmap.add(&cl.unmap);
    toplevel.events.destroy.add(&cl.destroy);
    toplevel.events.set_title.add(&cl.set_title);
    toplevel.events.request_fullscreen.add(&cl.request_fullscreen);
    toplevel.events.request_maximize.add(&cl.request_maximize);
}

pub fn surface(cl: *const Client) *wlr.Surface {
    return cl.toplevel.base.surface;
}

pub fn fromSurface(s: *wlr.Surface) ?*Client {
    var cur = s.getRootSurface();
    while (wlr.XdgSurface.tryFromWlrSurface(cur)) |xs| {
        switch (xs.role) {
            .toplevel => return @ptrCast(@alignCast(xs.data orelse return null)),
            .popup => cur = (xs.role_data.popup.?.parent orelse return null).getRootSurface(),
            .none => return null,
        }
    }
    return null;
}

pub fn title(cl: *const Client) []const u8 {
    return std.mem.span(cl.toplevel.title orelse return "");
}

pub fn appId(cl: *const Client) []const u8 {
    return std.mem.span(cl.toplevel.app_id orelse return "");
}

pub fn parent(cl: *const Client) ?*Client {
    const p = cl.toplevel.parent orelse return null;
    return @ptrCast(@alignCast(p.base.data orelse return null));
}

pub fn visibleOn(cl: *const Client, m: ?*const Monitor) bool {
    const mon = m orelse return false;
    return cl.mon == mon and cl.tags & mon.tags() != 0;
}

pub fn tiled(cl: *const Client) bool {
    return !cl.floating and !cl.fullscreen;
}

pub fn close(cl: *Client) void {
    cl.toplevel.sendClose();
}

pub fn activate(cl: *Client, on: bool) void {
    if (cl.activated == on) return;
    cl.activated = on;
    _ = cl.toplevel.setActivated(on);
}

pub fn setSuspended(cl: *Client, on: bool) void {
    if (cl.suspended == on) return;
    cl.suspended = on;
    _ = cl.toplevel.setSuspended(on);
}

pub fn setBorderColor(cl: *Client, color: *const [4]f32) void {
    if (!cl.surface().mapped) return;
    for (cl.border) |b| b.setColor(color);
}

fn setSize(cl: *Client, width: i32, height: i32) void {
    const s = &cl.toplevel.scheduled;
    if (s.width == width and s.height == height) return;
    cl.resize_serial = cl.toplevel.setSize(width, height);
}

/// Place the client at geo (layout coordinates, borders included). Tiled
/// clients may sit partly off their monitor; that part is clipped away so it
/// never shows on a neighbouring output.
pub fn resize(cl: *Client, geo: wlr.Box, interact: bool) void {
    const m = cl.mon orelse return;
    if (!cl.surface().mapped) return;

    const bw = cl.bw;
    cl.geom = geo;
    cl.geom.width = @max(cl.geom.width, 1 + 2 * bw);
    cl.geom.height = @max(cl.geom.height, 1 + 2 * bw);
    if (interact or cl.floating) {
        const b = if (interact) blk: {
            var all: wlr.Box = undefined;
            server.output_layout.getBox(null, &all);
            break :blk all;
        } else m.w;
        const g = &cl.geom;
        if (g.x >= b.x + b.width) g.x = b.x + b.width - g.width;
        if (g.y >= b.y + b.height) g.y = b.y + b.height - g.height;
        if (g.x + g.width <= b.x) g.x = b.x;
        if (g.y + g.height <= b.y) g.y = b.y;
    }

    const g = cl.geom;
    cl.scene.node.setPosition(g.x, g.y);
    cl.scene_surface.node.setPosition(bw, bw);
    cl.setSize(g.width - 2 * bw, g.height - 2 * bw);

    // Visible part, relative to the client's own origin.
    var vis: wlr.Box = .{ .x = 0, .y = 0, .width = g.width, .height = g.height };
    if (cl.tiled()) {
        var on: wlr.Box = undefined;
        if (!on.intersection(&g, &m.w)) on = .{ .x = g.x, .y = g.y, .width = 0, .height = 0 };
        vis = .{ .x = on.x - g.x, .y = on.y - g.y, .width = on.width, .height = on.height };
    }

    const rects = [4]wlr.Box{
        .{ .x = 0, .y = 0, .width = g.width, .height = bw },
        .{ .x = 0, .y = g.height - bw, .width = g.width, .height = bw },
        .{ .x = 0, .y = bw, .width = bw, .height = g.height - 2 * bw },
        .{ .x = g.width - bw, .y = bw, .width = bw, .height = g.height - 2 * bw },
    };
    for (cl.border, rects) |b, r| {
        var i: wlr.Box = undefined;
        if (!i.intersection(&r, &vis)) i = .{ .x = r.x, .y = r.y, .width = 0, .height = 0 };
        b.node.setPosition(i.x, i.y);
        b.setSize(i.width, i.height);
    }

    const content: wlr.Box = .{ .x = bw, .y = bw, .width = g.width - 2 * bw, .height = g.height - 2 * bw };
    var cv: wlr.Box = undefined;
    const shown = cv.intersection(&content, &vis);
    cl.scene_surface.node.setEnabled(shown);
    if (shown) {
        const geometry = cl.toplevel.base.geometry;
        const clip: wlr.Box = .{
            .x = geometry.x + cv.x - bw,
            .y = geometry.y + cv.y - bw,
            .width = cv.width,
            .height = cv.height,
        };
        cl.scene_surface.node.subsurfaceTreeSetClip(&clip);
    }
}

pub fn setFullscreen(cl: *Client, on: bool) void {
    cl.fullscreen = on;
    const m = cl.mon orelse return;
    if (!cl.surface().mapped) return;
    cl.bw = if (on) 0 else config.borderpx;
    _ = cl.toplevel.setFullscreen(on);
    cl.scene.node.reparent(server.layers.get(if (on) .fs else if (cl.floating) .float else .tile));
    if (on) {
        cl.prev = cl.geom;
        cl.resize(m.m, false);
    } else {
        cl.resize(cl.prev, false);
    }
    m.arrange();
}

pub fn setFloating(cl: *Client, on: bool) void {
    cl.floating = on;
    const m = cl.mon orelse return;
    if (!cl.surface().mapped or m.layout().arrange == null) return;
    const p = cl.parent();
    cl.scene.node.reparent(server.layers.get(if (cl.fullscreen or (p != null and p.?.fullscreen)) .fs else if (on) .float else .tile));
    m.arrange();
}

pub fn setMon(cl: *Client, m: ?*Monitor, newtags: u32) void {
    const old = cl.mon;
    if (old == m) return;
    cl.mon = m;
    cl.prev = cl.geom;
    cl.stacked = false;
    if (old) |o| o.arrange();
    if (m) |mon| {
        cl.resize(cl.geom, false);
        cl.tags = if (newtags != 0) newtags else mon.tags();
        cl.setFullscreen(cl.fullscreen);
        cl.setFloating(cl.floating);
    }
    server.focus(server.focustop(server.selmon), true);
}

fn matches(cl: *const Client, r: anytype) bool {
    if (r.title) |t| if (std.mem.indexOf(u8, cl.title(), t) == null) return false;
    if (r.app_id) |id| if (std.mem.indexOf(u8, cl.appId(), id) == null) return false;
    return true;
}

pub fn ruleFloating(cl: *const Client) bool {
    var floating = false;
    for (config.rules) |r| if (matches(cl, r)) {
        floating = r.floating;
    };
    return floating;
}

fn applyRules(cl: *Client) void {
    var m = server.selmon;
    var newtags: u32 = 0;
    for (config.rules) |r| {
        if (!matches(cl, r)) continue;
        cl.floating = r.floating;
        newtags |= r.tags;
        if (r.monitor >= 0) {
            var i: i32 = 0;
            var it = server.monitors.iterator(.forward);
            while (it.next()) |mon| : (i += 1) if (i == r.monitor) {
                m = mon;
            };
        }
    }
    cl.setMon(m, newtags);
}

fn onCommit(listener: *wl.Listener(*wlr.Surface), _: *wlr.Surface) void {
    const cl: *Client = @fieldParentPtr("commit", listener);
    if (cl.toplevel.base.initial_commit) {
        _ = cl.toplevel.setWmCapabilities(.{ .fullscreen = true });
        // Tiled windows get their column size in the first configure, so they
        // don't draw once at a size they never keep.
        const size = scroll.initialSize(cl);
        _ = cl.toplevel.setSize(size[0], size[1]);
        return;
    }
    if (cl.mon == null) return;
    cl.resize(cl.geom, cl.floating and !cl.fullscreen);
    if (cl.resize_serial != 0 and cl.resize_serial <= cl.toplevel.base.current.configure_serial)
        cl.resize_serial = 0;
}

fn onMap(listener: *wl.Listener(void)) void {
    const cl: *Client = @fieldParentPtr("map", listener);
    cl.scene = server.layers.get(.tile).createSceneTree() catch return;
    cl.scene_surface = cl.scene.createSceneXdgSurface(cl.toplevel.base) catch return;
    cl.scene.node.data = cl;
    cl.surface().data = cl.scene;
    for (&cl.border) |*b| b.* = cl.scene.createSceneRect(0, 0, &config.bordercolor) catch return;

    const geometry = cl.toplevel.base.geometry;
    cl.geom = .{
        .x = 0,
        .y = 0,
        .width = geometry.width + 2 * cl.bw,
        .height = geometry.height + 2 * cl.bw,
    };

    scroll.insert(cl);
    server.fstack.prepend(cl);

    if (cl.parent()) |p| {
        cl.floating = true;
        cl.setMon(p.mon, p.tags);
    } else {
        applyRules(cl);
    }
    if (cl.tiled()) scroll.reveal(cl);
}

fn onUnmap(listener: *wl.Listener(void)) void {
    const cl: *Client = @fieldParentPtr("unmap", listener);
    input.clientGone(cl);
    scroll.remove(cl);
    cl.link.remove();
    cl.setMon(null, 0);
    cl.flink.remove();
    cl.scene.node.destroy();
    input.motionNotify(0, null, 0, 0, 0, 0);
}

fn onDestroy(listener: *wl.Listener(void)) void {
    const cl: *Client = @fieldParentPtr("destroy", listener);
    cl.commit.link.remove();
    cl.map.link.remove();
    cl.unmap.link.remove();
    cl.destroy.link.remove();
    cl.set_title.link.remove();
    cl.request_fullscreen.link.remove();
    cl.request_maximize.link.remove();
    gpa.destroy(cl);
}

fn onSetTitle(_: *wl.Listener(void)) void {}

fn onRequestFullscreen(listener: *wl.Listener(void)) void {
    const cl: *Client = @fieldParentPtr("request_fullscreen", listener);
    if (cl.mon == null or !cl.surface().mapped) {
        cl.fullscreen = cl.toplevel.requested.fullscreen;
        return;
    }
    cl.setFullscreen(cl.toplevel.requested.fullscreen);
}

fn onRequestMaximize(listener: *wl.Listener(void)) void {
    const cl: *Client = @fieldParentPtr("request_maximize", listener);
    // Maximizing means nothing here, but the protocol still wants a configure.
    if (cl.toplevel.base.initialized) _ = cl.toplevel.base.scheduleConfigure();
}
