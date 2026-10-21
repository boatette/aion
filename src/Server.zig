const Server = @This();

const std = @import("std");
const log = std.log;
const wl = @import("wayland").server.wl;
const wlr = @import("wlroots");
const c = @import("c");

const config = @import("config.zig");
const actions = @import("actions.zig");
const input = @import("input.zig");
const Client = @import("Client.zig");
const Monitor = @import("Monitor.zig");
const LayerSurface = @import("LayerSurface.zig");
const Bar = @import("Bar.zig");
const build_options = @import("build_options");

pub const Layer = enum { bg, bottom, tile, float, top, fs, overlay, block };

/// what a scene node belongs to, stored in node.data
pub const Owner = union(enum) {
    client: *Client,
    layer: *LayerSurface,
    bar: *Monitor,
};

const gpa = std.heap.c_allocator;

wl_server: *wl.Server,
backend: *wlr.Backend,
session: ?*wlr.Session,
renderer: *wlr.Renderer,
allocator: *wlr.Allocator,
compositor: *wlr.Compositor,
scene: *wlr.Scene,
scene_layout: *wlr.SceneOutputLayout,
output_layout: *wlr.OutputLayout,
layers: std.EnumArray(Layer, *wlr.SceneTree),
drag_icons: *wlr.SceneTree,
root_bg: *wlr.SceneRect,
xdg_shell: *wlr.XdgShell,
layer_shell: *wlr.LayerShellV1,
seat: *wlr.Seat,
cursor: *wlr.Cursor,
xwayland: ?*wlr.Xwayland = null,

monitors: wl.list.Head(Monitor, .link),
clients: wl.list.Head(Client, .link),
fstack: wl.list.Head(Client, .flink),
selmon: ?*Monitor = null,
/// a top or overlay layer surface holding the keyboard, like a launcher
exclusive_focus: ?*LayerSurface = null,
socket: [11]u8 = undefined,

new_output: wl.Listener(*wlr.Output) = .init(Monitor.create),
layout_change: wl.Listener(*wlr.OutputLayout) = .init(layoutChange),
new_toplevel: wl.Listener(*wlr.XdgToplevel) = .init(Client.createXdg),
new_popup: wl.Listener(*wlr.XdgPopup) = .init(createPopup),
new_layer_surface: wl.Listener(*wlr.LayerSurfaceV1) = .init(LayerSurface.create),
new_decoration: wl.Listener(*wlr.XdgToplevelDecorationV1) = .init(Client.createDecoration),
request_activate: wl.Listener(*wlr.XdgActivationV1.event.RequestActivate) = .init(Client.requestActivate),
xwayland_ready: wl.Listener(void) = .init(xwaylandReady),
new_xwayland_surface: wl.Listener(*wlr.XwaylandSurface) = .init(Client.createX11),
renderer_lost: wl.Listener(void) = .init(rendererLost),

pub fn init(s: *Server) !void {
    const wl_server = try wl.Server.create();
    const loop = wl_server.getEventLoop();

    var session: ?*wlr.Session = null;
    const backend = try wlr.Backend.autocreate(loop, &session);
    const renderer = try wlr.Renderer.autocreate(backend);
    const scene = try wlr.Scene.create();
    const output_layout = try wlr.OutputLayout.create(wl_server);

    s.* = .{
        .wl_server = wl_server,
        .backend = backend,
        .session = session,
        .renderer = renderer,
        .allocator = try wlr.Allocator.autocreate(backend, renderer),
        .compositor = try wlr.Compositor.create(wl_server, 6, renderer),
        .scene = scene,
        .scene_layout = try scene.attachOutputLayout(output_layout),
        .output_layout = output_layout,
        .layers = undefined,
        .drag_icons = undefined,
        .root_bg = try scene.tree.createSceneRect(0, 0, &config.rootcolor),
        .xdg_shell = try wlr.XdgShell.create(wl_server, 6),
        .layer_shell = try wlr.LayerShellV1.create(wl_server, 4),
        .seat = try wlr.Seat.create(wl_server, "seat0"),
        .cursor = try wlr.Cursor.create(),
        .monitors = undefined,
        .clients = undefined,
        .fstack = undefined,
    };
    s.monitors.init();
    s.clients.init();
    s.fstack.init();

    for (&s.layers.values) |*tree| tree.* = try scene.tree.createSceneTree();
    s.drag_icons = try scene.tree.createSceneTree();
    s.layers.get(.block).node.raiseToTop();

    _ = try wlr.Shm.createWithRenderer(wl_server, 2, renderer);
    if (renderer.getTextureFormats(@backingInt(wlr.BufferCap.dmabuf)) != null) {
        scene.setLinuxDmabufV1(try wlr.LinuxDmabufV1.createWithRenderer(wl_server, 5, renderer));
        // explicit sync, which nvidia needs for tear-free offloaded clients
        const drm_fd = renderer.getDrmFd();
        if (drm_fd >= 0 and renderer.features.timeline and backend.features.timeline)
            _ = wlr.LinuxDrmSyncobjManagerV1.create(wl_server, 1, drm_fd);
    }
    _ = try wlr.Subcompositor.create(wl_server);
    _ = try wlr.DataDeviceManager.create(wl_server);
    _ = try wlr.PrimarySelectionDeviceManagerV1.create(wl_server);
    _ = try wlr.DataControlManagerV1.create(wl_server);
    _ = try wlr.ExtDataControlManagerV1.create(wl_server, 1);
    _ = try wlr.ScreencopyManagerV1.create(wl_server);
    _ = try wlr.ExtImageCopyCaptureManagerV1.create(wl_server, 1);
    _ = try wlr.ExtOutputImageCaptureSourceManagerV1.create(wl_server, 1);
    _ = try wlr.XdgOutputManagerV1.create(wl_server, output_layout);
    _ = try wlr.Viewporter.create(wl_server);
    _ = try wlr.SinglePixelBufferManagerV1.create(wl_server);
    _ = try wlr.FractionalScaleManagerV1.create(wl_server, 1);
    _ = try wlr.Presentation.create(wl_server, backend, 2);
    (try wlr.XdgDecorationManagerV1.create(wl_server)).events.new_toplevel_decoration.add(&s.new_decoration);
    (try wlr.XdgActivationV1.create(wl_server)).events.request_activate.add(&s.request_activate);

    backend.events.new_output.add(&s.new_output);
    output_layout.events.change.add(&s.layout_change);
    s.xdg_shell.events.new_toplevel.add(&s.new_toplevel);
    s.xdg_shell.events.new_popup.add(&s.new_popup);
    s.layer_shell.events.new_surface.add(&s.new_layer_surface);
    renderer.events.lost.add(&s.renderer_lost);

    // lazy, so xwayland only starts once an x11 client connects
    if (build_options.xwayland) {
        if (wlr.Xwayland.create(wl_server, s.compositor, true)) |x| {
            s.xwayland = x;
            x.events.ready.add(&s.xwayland_ready);
            x.events.new_surface.add(&s.new_xwayland_surface);
            _ = c.setenv("DISPLAY", x.display_name, 1);
        } else |_| log.err("could not set up Xwayland, continuing without it", .{});
    }

    _ = c.fcft_init(c.FCFT_LOG_COLORIZE_AUTO, false, c.FCFT_LOG_CLASS_ERROR);
    try Monitor.initManagers();
    try input.init();
    try @import("lock.zig").init();
}

pub fn start(s: *Server, startup: ?[*:0]const u8) !void {
    const socket = try s.wl_server.addSocketAuto(&s.socket);
    try s.backend.start();
    _ = c.setenv("WAYLAND_DISPLAY", socket.ptr, 1);
    Bar.startStatus();

    // startup commands get the session environment the compositor sees
    if (startup) |cmd| {
        const argv = [_:null]?[*:0]const u8{ "/bin/sh", "-c", cmd };
        actions.spawnArgv(&argv);
    }

    // the backend placed the cursor while adding outputs, so put it somewhere sane
    if (s.selmon) |m| s.cursor.warpClosest(null, @floatFromInt(m.m.x + @divTrunc(m.m.width, 2)), @floatFromInt(m.m.y + @divTrunc(m.m.height, 2)));
    input.updateCursor();
}

/// wlroots asserts nothing still listens to what it destroys, so every global listener goes first
pub fn deinit(s: *Server) void {
    Bar.stopStatus();
    input.deinit();
    @import("lock.zig").deinit();
    Monitor.deinitManagers();
    inline for (.{ &s.new_output, &s.layout_change, &s.new_toplevel, &s.new_popup, &s.new_layer_surface, &s.new_decoration, &s.request_activate, &s.renderer_lost }) |l| l.link.remove();
    if (build_options.xwayland) if (s.xwayland) |x| {
        s.xwayland_ready.link.remove();
        s.new_xwayland_surface.link.remove();
        x.destroy();
    };
    s.wl_server.destroyClients();
    s.backend.destroy();
    s.wl_server.destroy();
    s.scene.tree.node.destroy();
    c.fcft_fini();
}

pub fn focustop(s: *Server, m: ?*Monitor) ?*Client {
    var it = s.fstack.iterator(.forward);
    while (it.next()) |cl| if (cl.visibleOn(m)) return cl;
    return null;
}

pub fn focus(s: *Server, cl: ?*Client, lift: bool) void {
    const old = s.seat.keyboard_state.focused_surface;
    if (input.locked) return;

    if (cl) |new| {
        if (lift) new.scene.node.raiseToTop();
        if (new.surface() == old) return;
        new.flink.remove();
        s.fstack.prepend(new);
        s.selmon = new.mon;
        new.urgent = false;
        if (s.exclusive_focus == null) new.setBorderColor(&config.focuscolor);
    }

    Bar.redraw();
    // the client gets the keyboard once the layer surface holding it closes
    if (s.exclusive_focus != null) return;

    if (old) |o| {
        if (Client.fromSurface(o)) |prev| {
            if (cl != prev) {
                prev.activate(false);
                prev.setBorderColor(&config.bordercolor);
            }
        }
    }

    const new = cl orelse {
        s.seat.keyboardNotifyClearFocus();
        return;
    };
    input.motionNotify(0, null, 0, 0, 0, 0);
    input.keyboardEnter(new.surface());
    new.activate(true);
}

pub const Hit = struct {
    surface: ?*wlr.Surface = null,
    client: ?*Client = null,
    layer: ?*LayerSurface = null,
    bar: ?*Monitor = null,
    sx: f64 = 0,
    sy: f64 = 0,
};

/// find what is under a layout coordinate, walking layers top to bottom
pub fn hitTest(s: *Server, x: f64, y: f64) Hit {
    var hit: Hit = .{};
    const order = [_]Layer{ .block, .overlay, .fs, .top, .float, .tile, .bottom, .bg };
    for (order) |layer| {
        var sx: f64 = undefined;
        var sy: f64 = undefined;
        const node = s.layers.get(layer).node.at(x, y, &sx, &sy) orelse continue;
        if (node.type == .buffer) {
            if (wlr.SceneSurface.tryFromBuffer(wlr.SceneBuffer.fromNode(node))) |ss| {
                hit.surface = ss.surface;
                hit.sx = sx;
                hit.sy = sy;
            }
        }
        // walk up to the tree that owns this node
        var n: ?*wlr.SceneNode = node;
        while (n) |cur| : (n = if (cur.parent) |p| &p.node else null) {
            const owner: *Owner = @ptrCast(@alignCast(cur.data orelse continue));
            switch (owner.*) {
                .client => |cl| hit.client = cl,
                .layer => |l| hit.layer = l,
                .bar => |m| hit.bar = m,
            }
            break;
        }
        break;
    }
    return hit;
}

pub fn dirtomon(s: *Server, dir: wlr.OutputLayout.Direction) ?*Monitor {
    const m = s.selmon orelse return null;
    const cx: f64 = @floatFromInt(m.m.x + @divTrunc(m.m.width, 2));
    const cy: f64 = @floatFromInt(m.m.y + @divTrunc(m.m.height, 2));
    if (s.output_layout.adjacentOutput(dir, m.output, cx, cy)) |next| return @ptrCast(@alignCast(next.data));
    if (s.output_layout.farthestOutput(@fromBackingInt(@intCast(@backingInt(opposite(dir)))), m.output, cx, cy)) |next| return @ptrCast(@alignCast(next.data));
    return m;
}

fn opposite(dir: wlr.OutputLayout.Direction) wlr.OutputLayout.Direction {
    return switch (dir) {
        .up => .down,
        .down => .up,
        .left => .right,
        .right => .left,
    };
}

pub fn arrangeAll(s: *Server) void {
    var it = s.monitors.iterator(.forward);
    while (it.next()) |m| m.arrange();
}

fn xwaylandReady(_: *wl.Listener(void)) void {
    const server = &@import("main.zig").server;
    const x = server.xwayland orelse return;
    x.setSeat(server.seat);
    input.setXwaylandCursor(x);
}

fn layoutChange(_: *wl.Listener(*wlr.OutputLayout), _: *wlr.OutputLayout) void {
    Monitor.updateAll();
}

fn createPopup(_: *wl.Listener(*wlr.XdgPopup), popup: *wlr.XdgPopup) void {
    const p = gpa.create(Popup) catch return;
    p.* = .{ .popup = popup };
    popup.base.surface.events.commit.add(&p.commit);
    popup.events.destroy.add(&p.destroy);
}

const Popup = struct {
    popup: *wlr.XdgPopup,
    commit: wl.Listener(*wlr.Surface) = .init(onCommit),
    destroy: wl.Listener(void) = .init(onDestroy),

    fn onCommit(listener: *wl.Listener(*wlr.Surface), _: *wlr.Surface) void {
        const p: *Popup = @fieldParentPtr("commit", listener);
        if (!p.popup.base.initial_commit) return;
        const server = &@import("main.zig").server;
        const parent = p.popup.parent orelse return;
        // toplevels and popups keep their scene tree in surface.data
        const parent_tree: *wlr.SceneTree = @ptrCast(@alignCast(parent.data orelse return));
        const tree = parent_tree.createSceneXdgSurface(p.popup.base) catch return;
        p.popup.base.surface.data = tree;

        // keep popups on the monitor their toplevel is on
        var root = parent;
        var box: wlr.Box = undefined;
        while (wlr.XdgSurface.tryFromWlrSurface(root)) |xs| {
            if (xs.role == .popup) root = xs.role_data.popup.?.parent orelse break else break;
        }
        if (LayerSurface.fromSurface(root)) |l| {
            box = l.mon.m;
            box.x -= l.scene.node.x;
            box.y -= l.scene.node.y;
        } else {
            const cl = Client.fromSurface(root) orelse return;
            const m = cl.mon orelse server.selmon orelse return;
            box = m.w;
            box.x -= cl.geom.x;
            box.y -= cl.geom.y;
        }
        p.popup.unconstrainFromBox(&box);
    }

    fn onDestroy(listener: *wl.Listener(void)) void {
        const p: *Popup = @fieldParentPtr("destroy", listener);
        p.commit.link.remove();
        p.destroy.link.remove();
        gpa.destroy(p);
    }
};

fn rendererLost(_: *wl.Listener(void)) void {
    const server = &@import("main.zig").server;
    log.info("renderer lost, recreating it", .{});
    const old_renderer = server.renderer;
    const old_allocator = server.allocator;
    server.renderer = wlr.Renderer.autocreate(server.backend) catch @panic("could not recreate renderer");
    server.allocator = wlr.Allocator.autocreate(server.backend, server.renderer) catch @panic("could not recreate allocator");
    server.renderer_lost.link.remove();
    server.renderer.events.lost.add(&server.renderer_lost);
    server.compositor.setRenderer(server.renderer);
    var it = server.monitors.iterator(.forward);
    while (it.next()) |m| _ = m.output.initRender(server.allocator, server.renderer);
    old_allocator.destroy();
    old_renderer.destroy();
}
