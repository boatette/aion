const Client = @This();

const std = @import("std");
const wl = @import("wayland").server.wl;
const wlr = @import("wlroots");

const config = @import("config.zig");
const input = @import("input.zig");
const scroll = @import("scroll.zig");
const server = &@import("main.zig").server;
const Monitor = @import("Monitor.zig");
const Server = @import("Server.zig");
const xwayland = @import("build_options").xwayland;

const gpa = std.heap.c_allocator;

pub const Shell = union(enum) {
    xdg: *wlr.XdgToplevel,
    x11: *wlr.XwaylandSurface,
};

/// Strip order; columns are runs of visible tiled clients in this list.
link: wl.list.Link = undefined,
/// Focus order, most recent first.
flink: wl.list.Link = undefined,
owner: Server.Owner = undefined,
shell: Shell,
decoration: ?*wlr.XdgToplevelDecorationV1 = null,
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
/// Where the window last floated, to go back to when floated again.
float_geom: ?wlr.Box = null,
resize_serial: u32 = 0,

commit: wl.Listener(*wlr.Surface) = .init(onCommit),
map: wl.Listener(void) = .init(onMap),
unmap: wl.Listener(void) = .init(onUnmap),
destroy: wl.Listener(void) = .init(onDestroy),
set_title: wl.Listener(void) = .init(onSetTitle),
request_fullscreen: wl.Listener(void) = .init(onRequestFullscreen),
request_maximize: wl.Listener(void) = .init(onRequestMaximize),
decoration_mode: wl.Listener(*wlr.XdgToplevelDecorationV1) = .init(onDecorationMode),
decoration_destroy: wl.Listener(*wlr.XdgToplevelDecorationV1) = .init(onDecorationDestroy),
associate: wl.Listener(void) = .init(onAssociate),
dissociate: wl.Listener(void) = .init(onDissociate),
request_configure: wl.Listener(*wlr.XwaylandSurface.event.Configure) = .init(onRequestConfigure),
request_activate_x11: wl.Listener(void) = .init(onRequestActivateX11),
set_hints: wl.Listener(void) = .init(onSetHints),

pub fn createXdg(_: *wl.Listener(*wlr.XdgToplevel), toplevel: *wlr.XdgToplevel) void {
    const cl = gpa.create(Client) catch return;
    cl.* = .{ .shell = .{ .xdg = toplevel } };
    cl.owner = .{ .client = cl };
    toplevel.base.data = cl;
    toplevel.base.surface.events.commit.add(&cl.commit);
    toplevel.base.surface.events.map.add(&cl.map);
    toplevel.base.surface.events.unmap.add(&cl.unmap);
    toplevel.events.destroy.add(&cl.destroy);
    toplevel.events.set_title.add(&cl.set_title);
    toplevel.events.request_fullscreen.add(&cl.request_fullscreen);
    toplevel.events.request_maximize.add(&cl.request_maximize);
}

pub fn createX11(_: *wl.Listener(*wlr.XwaylandSurface), xsurface: *wlr.XwaylandSurface) void {
    const cl = gpa.create(Client) catch return;
    cl.* = .{ .shell = .{ .x11 = xsurface } };
    cl.owner = .{ .client = cl };
    xsurface.data = cl;
    xsurface.events.associate.add(&cl.associate);
    xsurface.events.dissociate.add(&cl.dissociate);
    xsurface.events.destroy.add(&cl.destroy);
    xsurface.events.set_title.add(&cl.set_title);
    xsurface.events.request_fullscreen.add(&cl.request_fullscreen);
    xsurface.events.request_configure.add(&cl.request_configure);
    xsurface.events.request_activate.add(&cl.request_activate_x11);
    xsurface.events.set_hints.add(&cl.set_hints);
}

/// Only valid once mapped; X11 windows have no surface before that.
pub fn surface(cl: *const Client) *wlr.Surface {
    return switch (cl.shell) {
        .xdg => |t| t.base.surface,
        .x11 => |x| x.surface.?,
    };
}

pub fn mapped(cl: *const Client) bool {
    return switch (cl.shell) {
        .xdg => |t| t.base.surface.mapped,
        .x11 => |x| if (x.surface) |s| s.mapped else false,
    };
}

/// Override-redirect X11 windows: menus and tooltips placed by the app itself.
pub fn unmanaged(cl: *const Client) bool {
    return switch (cl.shell) {
        .xdg => false,
        .x11 => |x| x.override_redirect,
    };
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
    if (xwayland) if (wlr.XwaylandSurface.tryFromWlrSurface(cur)) |x| return @ptrCast(@alignCast(x.data orelse return null));
    return null;
}

pub fn title(cl: *const Client) []const u8 {
    const t = switch (cl.shell) {
        .xdg => |t| t.title,
        .x11 => |x| x.title,
    };
    return std.mem.span(t orelse return "");
}

pub fn appId(cl: *const Client) []const u8 {
    const id = switch (cl.shell) {
        .xdg => |t| t.app_id,
        .x11 => |x| x.class,
    };
    return std.mem.span(id orelse return "");
}

pub fn parent(cl: *const Client) ?*Client {
    const data = switch (cl.shell) {
        .xdg => |t| (t.parent orelse return null).base.data,
        .x11 => |x| (x.parent orelse return null).data,
    };
    return @ptrCast(@alignCast(data orelse return null));
}

extern fn wlr_xwayland_surface_has_window_type(surface: *const wlr.XwaylandSurface, window_type: c_int) bool;

/// Dialogs, fixed-size windows and the like float by default.
pub fn floatType(cl: *const Client) bool {
    switch (cl.shell) {
        .xdg => |t| {
            const cur = t.current;
            const sized = cur.min_width > 0 or cur.min_height > 0 or cur.max_width > 0 or cur.max_height > 0;
            return t.parent != null or (sized and (cur.min_width == cur.max_width or cur.min_height == cur.max_height));
        },
        .x11 => |x| {
            if (!xwayland) unreachable;
            if (x.modal) return true;
            // toolbar, utility, splash, dialog
            for ([_]c_int{ 2, 4, 5, 6 }) |t| if (wlr_xwayland_surface_has_window_type(x, t)) return true;
            const h = x.size_hints orelse return false;
            return h.min_width > 0 and h.min_height > 0 and (h.max_width == h.min_width or h.max_height == h.min_height);
        },
    }
}

pub fn visibleOn(cl: *const Client, m: ?*const Monitor) bool {
    const mon = m orelse return false;
    return cl.mon == mon and cl.tags & mon.tags() != 0;
}

pub fn tiled(cl: *const Client) bool {
    return !cl.floating and !cl.fullscreen;
}

pub fn pid(cl: *const Client) i32 {
    return switch (cl.shell) {
        .xdg => |t| t.base.client.client.getCredentials().pid,
        .x11 => |x| x.pid,
    };
}

pub fn close(cl: *Client) void {
    switch (cl.shell) {
        .xdg => |t| t.sendClose(),
        .x11 => |x| if (xwayland) x.close() else unreachable,
    }
}

pub fn activate(cl: *Client, on: bool) void {
    if (cl.activated == on) return;
    cl.activated = on;
    switch (cl.shell) {
        .xdg => |t| _ = t.setActivated(on),
        .x11 => |x| if (xwayland) x.activate(on) else unreachable,
    }
}

pub fn setSuspended(cl: *Client, on: bool) void {
    if (cl.suspended == on) return;
    cl.suspended = on;
    switch (cl.shell) {
        .xdg => |t| _ = t.setSuspended(on),
        .x11 => {},
    }
}

/// Tiled windows are told so, which stops terminals snapping to whole cells.
fn setTiled(cl: *Client, on: bool) void {
    const all: wlr.Edges = .{ .top = true, .bottom = true, .left = true, .right = true };
    switch (cl.shell) {
        .xdg => |t| _ = t.setTiled(if (on) all else .{}),
        .x11 => {},
    }
}

pub fn setBorderColor(cl: *Client, color: *const [4]f32) void {
    if (!cl.mapped() or cl.unmanaged()) return;
    for (cl.border) |b| b.setColor(color);
}

fn setSize(cl: *Client, width: i32, height: i32) void {
    switch (cl.shell) {
        .xdg => |t| {
            const s = &t.scheduled;
            if (s.width == width and s.height == height) return;
            cl.resize_serial = t.setSize(width, height);
        },
        // X11 windows also need their position, which changes when scrolling.
        .x11 => |x| if (xwayland) x.configure(
            @intCast(std.math.clamp(cl.geom.x + cl.bw, std.math.minInt(i16), std.math.maxInt(i16))),
            @intCast(std.math.clamp(cl.geom.y + cl.bw, std.math.minInt(i16), std.math.maxInt(i16))),
            @intCast(@max(width, 1)),
            @intCast(@max(height, 1)),
        ) else unreachable,
    }
}

fn geometryOffset(cl: *const Client) [2]i32 {
    return switch (cl.shell) {
        .xdg => |t| .{ t.base.geometry.x, t.base.geometry.y },
        .x11 => .{ 0, 0 },
    };
}

/// Place the client at geo (layout coordinates, borders included). Tiled
/// clients may sit partly off their monitor; that part is clipped away so it
/// never shows on a neighbouring output.
pub fn resize(cl: *Client, geo: wlr.Box, interact: bool) void {
    const m = cl.mon orelse return;
    if (!cl.mapped()) return;

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
        const off = cl.geometryOffset();
        const clip: wlr.Box = .{
            .x = off[0] + cv.x - bw,
            .y = off[1] + cv.y - bw,
            .width = cv.width,
            .height = cv.height,
        };
        cl.scene_surface.node.subsurfaceTreeSetClip(&clip);
    }
}

pub fn setFullscreen(cl: *Client, on: bool) void {
    cl.fullscreen = on;
    const m = cl.mon orelse return;
    if (!cl.mapped()) return;
    cl.bw = if (on) 0 else config.borderpx;
    switch (cl.shell) {
        .xdg => |t| _ = t.setFullscreen(on),
        .x11 => |x| if (xwayland) x.setFullscreen(on) else unreachable,
    }
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
    cl.setTiled(!on);
    const m = cl.mon orelse return;
    if (!cl.mapped() or m.layout().arrange == null) return;
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

const Matched = struct {
    floating: ?bool = null,
    fullscreen: bool = false,
    width: ?f32 = null,
    tags: u32 = 0,
    monitor: i32 = -1,
};

/// Every matching rule applies, later ones winning.
pub fn matchRules(cl: *const Client) Matched {
    var res: Matched = .{};
    for (config.rules) |r| {
        if (r.title) |t| if (std.mem.indexOf(u8, cl.title(), t) == null) continue;
        if (r.app_id) |id| if (std.mem.indexOf(u8, cl.appId(), id) == null) continue;
        if (r.floating) |f| res.floating = f;
        if (r.width) |w| res.width = w;
        res.fullscreen = res.fullscreen or r.fullscreen;
        res.tags |= r.tags;
        if (r.monitor >= 0) res.monitor = r.monitor;
    }
    return res;
}

fn applyRules(cl: *Client) void {
    const r = cl.matchRules();
    if (r.floating) |f| cl.floating = f;
    if (r.width) |w| cl.width = w;
    if (r.fullscreen) cl.fullscreen = true;
    var m = server.selmon;
    if (r.monitor >= 0) {
        var i: i32 = 0;
        var it = server.monitors.iterator(.forward);
        while (it.next()) |mon| : (i += 1) if (i == r.monitor) {
            m = mon;
        };
    }
    cl.setMon(m, r.tags & @import("actions.zig").tagmask());
}

fn onCommit(listener: *wl.Listener(*wlr.Surface), _: *wlr.Surface) void {
    const cl: *Client = @fieldParentPtr("commit", listener);
    const t = cl.shell.xdg;
    if (t.base.initial_commit) {
        _ = t.setWmCapabilities(.{ .fullscreen = true });
        // Tiled windows get their column size in the first configure, so they
        // don't draw once at a size they never keep.
        if (cl.matchRules().width) |w| cl.width = w;
        const size = scroll.initialSize(cl);
        _ = t.setSize(size[0], size[1]);
        cl.setTiled(size[0] != 0);
        if (cl.decoration) |d| _ = d.setMode(.server_side);
        return;
    }
    const m = cl.mon orelse return;
    if (cl.resize_serial != 0 and cl.resize_serial <= t.base.current.configure_serial)
        cl.resize_serial = 0;
    // Untiled windows may settle on a size other than the one asked for, like
    // terminals snapping to whole cells, so the frame follows what they drew.
    var geo = cl.geom;
    const s = t.base.geometry;
    if (!cl.fullscreen and (cl.floating or m.layout().arrange == null) and
        cl.resize_serial == 0 and s.width > 0 and s.height > 0)
    {
        geo.width = s.width + 2 * cl.bw;
        geo.height = s.height + 2 * cl.bw;
    }
    cl.resize(geo, cl.floating and !cl.fullscreen);
}

fn onMap(listener: *wl.Listener(void)) void {
    const cl: *Client = @fieldParentPtr("map", listener);
    cl.scene = server.layers.get(.tile).createSceneTree() catch return;
    cl.scene_surface = switch (cl.shell) {
        .xdg => |t| cl.scene.createSceneXdgSurface(t.base),
        .x11 => |x| cl.scene.createSceneSubsurfaceTree(x.surface.?),
    } catch return;
    cl.scene.node.data = &cl.owner;
    cl.surface().data = cl.scene;

    switch (cl.shell) {
        .xdg => |t| cl.geom = .{ .x = 0, .y = 0, .width = t.base.geometry.width, .height = t.base.geometry.height },
        .x11 => |x| cl.geom = .{ .x = x.x, .y = x.y, .width = x.width, .height = x.height },
    }

    if (cl.unmanaged()) {
        const x = cl.shell.x11;
        cl.bw = 0;
        cl.scene.node.reparent(server.layers.get(.float));
        cl.scene.node.setPosition(cl.geom.x, cl.geom.y);
        if (xwayland and x.overrideRedirectWantsFocus() and x.icccmInputModel() != .none)
            input.keyboardEnter(cl.surface());
        return;
    }

    for (&cl.border) |*b| b.* = cl.scene.createSceneRect(0, 0, &config.bordercolor) catch return;
    cl.geom.width += 2 * cl.bw;
    cl.geom.height += 2 * cl.bw;

    scroll.insert(cl);
    server.fstack.prepend(cl);

    if (cl.parent()) |p| {
        cl.floating = true;
        cl.setMon(p.mon, p.tags);
    } else {
        cl.floating = cl.floatType();
        applyRules(cl);
    }
    if (cl.tiled()) {
        scroll.reveal(cl);
    } else if (cl.mon) |m| {
        // Floating windows open centred on their monitor, unless an X11 app placed itself.
        const placed = cl.shell == .x11 and (cl.geom.x != 0 or cl.geom.y != 0);
        if (!placed and !cl.fullscreen) cl.resize(.{
            .x = m.w.x + @divTrunc(m.w.width - cl.geom.width, 2),
            .y = m.w.y + @divTrunc(m.w.height - cl.geom.height, 2),
            .width = cl.geom.width,
            .height = cl.geom.height,
        }, false);
    }
}

fn onUnmap(listener: *wl.Listener(void)) void {
    const cl: *Client = @fieldParentPtr("unmap", listener);
    if (cl.unmanaged()) {
        if (server.seat.keyboard_state.focused_surface == cl.surface()) server.focus(server.focustop(server.selmon), true);
    } else {
        input.clientGone(cl);
        scroll.remove(cl);
        cl.link.remove();
        cl.setMon(null, 0);
        cl.flink.remove();
    }
    cl.surface().data = null;
    cl.scene.node.destroy();
    input.motionNotify(0, null, 0, 0, 0, 0);
}

fn onDestroy(listener: *wl.Listener(void)) void {
    const cl: *Client = @fieldParentPtr("destroy", listener);
    cl.destroy.link.remove();
    cl.set_title.link.remove();
    cl.request_fullscreen.link.remove();
    switch (cl.shell) {
        .xdg => {
            cl.commit.link.remove();
            cl.map.link.remove();
            cl.unmap.link.remove();
            cl.request_maximize.link.remove();
            // the decoration's own destroy fires after this one when a client dies first
            if (cl.decoration != null) {
                cl.decoration_mode.link.remove();
                cl.decoration_destroy.link.remove();
            }
        },
        .x11 => {
            cl.associate.link.remove();
            cl.dissociate.link.remove();
            cl.request_configure.link.remove();
            cl.request_activate_x11.link.remove();
            cl.set_hints.link.remove();
        },
    }
    gpa.destroy(cl);
}

fn onSetTitle(listener: *wl.Listener(void)) void {
    const cl: *Client = @fieldParentPtr("set_title", listener);
    if (cl.mon) |m| if (cl == server.focustop(m)) @import("Bar.zig").redraw();
}

fn onRequestFullscreen(listener: *wl.Listener(void)) void {
    const cl: *Client = @fieldParentPtr("request_fullscreen", listener);
    const want = switch (cl.shell) {
        .xdg => |t| t.requested.fullscreen,
        .x11 => |x| x.fullscreen,
    };
    if (cl.mon == null or !cl.mapped()) {
        cl.fullscreen = want;
        return;
    }
    cl.setFullscreen(want);
}

fn onRequestMaximize(listener: *wl.Listener(void)) void {
    const cl: *Client = @fieldParentPtr("request_maximize", listener);
    // Maximizing means nothing here, but the protocol still wants a configure.
    const t = cl.shell.xdg;
    if (t.base.initialized) _ = t.base.scheduleConfigure();
}

fn onAssociate(listener: *wl.Listener(void)) void {
    const cl: *Client = @fieldParentPtr("associate", listener);
    const s = cl.surface();
    s.events.map.add(&cl.map);
    s.events.unmap.add(&cl.unmap);
}

fn onDissociate(listener: *wl.Listener(void)) void {
    const cl: *Client = @fieldParentPtr("dissociate", listener);
    cl.map.link.remove();
    cl.unmap.link.remove();
}

fn onRequestConfigure(listener: *wl.Listener(*wlr.XwaylandSurface.event.Configure), event: *wlr.XwaylandSurface.event.Configure) void {
    if (!xwayland) unreachable;
    const cl: *Client = @fieldParentPtr("request_configure", listener);
    const x = cl.shell.x11;
    if (!cl.mapped() or cl.unmanaged()) {
        if (cl.mapped()) cl.scene.node.setPosition(event.x, event.y);
        x.configure(event.x, event.y, event.width, event.height);
        return;
    }
    const m = cl.mon orelse return;
    if (cl.floating or m.layout().arrange == null) {
        cl.resize(.{
            .x = event.x - cl.bw,
            .y = event.y - cl.bw,
            .width = @as(i32, event.width) + 2 * cl.bw,
            .height = @as(i32, event.height) + 2 * cl.bw,
        }, false);
    } else {
        m.arrange();
    }
}

fn onRequestActivateX11(listener: *wl.Listener(void)) void {
    if (!xwayland) unreachable;
    const cl: *Client = @fieldParentPtr("request_activate_x11", listener);
    if (!cl.unmanaged()) cl.shell.x11.activate(true);
}

fn onSetHints(listener: *wl.Listener(void)) void {
    const cl: *Client = @fieldParentPtr("set_hints", listener);
    const hints = cl.shell.x11.hints orelse return;
    if (cl == server.focustop(server.selmon)) return;
    // XUrgencyHint
    cl.urgent = hints.flags & (1 << 8) != 0;
    if (cl.urgent) cl.setBorderColor(&config.urgentcolor);
    @import("Bar.zig").redraw();
}

pub fn createDecoration(_: *wl.Listener(*wlr.XdgToplevelDecorationV1), deco: *wlr.XdgToplevelDecorationV1) void {
    const cl: *Client = @ptrCast(@alignCast(deco.toplevel.base.data orelse return));
    cl.decoration = deco;
    deco.events.request_mode.add(&cl.decoration_mode);
    deco.events.destroy.add(&cl.decoration_destroy);
    onDecorationMode(&cl.decoration_mode, deco);
}

/// Borders are drawn here, so clients never draw their own decorations.
fn onDecorationMode(listener: *wl.Listener(*wlr.XdgToplevelDecorationV1), deco: *wlr.XdgToplevelDecorationV1) void {
    const cl: *Client = @fieldParentPtr("decoration_mode", listener);
    if (cl.shell.xdg.base.initialized) _ = deco.setMode(.server_side);
}

fn onDecorationDestroy(listener: *wl.Listener(*wlr.XdgToplevelDecorationV1), _: *wlr.XdgToplevelDecorationV1) void {
    const cl: *Client = @fieldParentPtr("decoration_destroy", listener);
    cl.decoration_mode.link.remove();
    cl.decoration_destroy.link.remove();
    cl.decoration = null;
}

pub fn requestActivate(_: *wl.Listener(*wlr.XdgActivationV1.event.RequestActivate), event: *wlr.XdgActivationV1.event.RequestActivate) void {
    const cl = fromSurface(event.surface) orelse return;
    if (cl == server.focustop(server.selmon) or !cl.mapped()) return;
    if (config.focus_on_activate) {
        const m = cl.mon orelse return;
        if (!cl.visibleOn(m)) {
            m.seltags ^= 1;
            m.tagset[m.seltags] = cl.tags;
        }
        @import("actions.zig").focus(cl);
        m.arrange();
    } else {
        cl.urgent = true;
        cl.setBorderColor(&config.urgentcolor);
        @import("Bar.zig").redraw();
    }
}
