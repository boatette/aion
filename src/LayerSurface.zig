const LayerSurface = @This();

const std = @import("std");
const wl = @import("wayland").server.wl;
const wlr = @import("wlroots");
const zwlr = @import("wayland").server.zwlr;

const input = @import("input.zig");
const server = &@import("main.zig").server;
const Server = @import("Server.zig");
const Monitor = @import("Monitor.zig");

const gpa = std.heap.c_allocator;

link: wl.list.Link = undefined,
owner: Server.Owner,
layer_surface: *wlr.LayerSurfaceV1,
scene_layer: *wlr.SceneLayerSurfaceV1,
scene: *wlr.SceneTree,
popups: *wlr.SceneTree,
mon: *Monitor,
mapped: bool = false,

commit: wl.Listener(*wlr.Surface) = .init(onCommit),
unmap: wl.Listener(void) = .init(onUnmap),
destroy: wl.Listener(*wlr.LayerSurfaceV1) = .init(onDestroy),

pub fn sceneLayer(layer: zwlr.LayerShellV1.Layer) *wlr.SceneTree {
    return server.layers.get(switch (layer) {
        .background => .bg,
        .bottom => .bottom,
        .top => .top,
        .overlay => .overlay,
        _ => .top,
    });
}

fn index(layer: zwlr.LayerShellV1.Layer) usize {
    return @intCast(std.math.clamp(@intFromEnum(layer), 0, 3));
}

/// Popups of background and bottom surfaces still need to show above windows.
fn popupLayer(layer: zwlr.LayerShellV1.Layer) *wlr.SceneTree {
    return if (@intFromEnum(layer) < @intFromEnum(zwlr.LayerShellV1.Layer.top)) server.layers.get(.top) else sceneLayer(layer);
}

pub fn create(_: *wl.Listener(*wlr.LayerSurfaceV1), layer_surface: *wlr.LayerSurfaceV1) void {
    if (layer_surface.output == null) {
        layer_surface.output = if (server.selmon) |m| m.output else null;
    }
    const output = layer_surface.output orelse return layer_surface.destroy();
    const m = Monitor.fromOutput(output) orelse return layer_surface.destroy();

    const l = gpa.create(LayerSurface) catch return layer_surface.destroy();
    const layer = layer_surface.pending.layer;
    const scene_layer = sceneLayer(layer).createSceneLayerSurfaceV1(layer_surface) catch {
        gpa.destroy(l);
        return layer_surface.destroy();
    };
    l.* = .{
        .owner = .{ .layer = l },
        .layer_surface = layer_surface,
        .scene_layer = scene_layer,
        .scene = scene_layer.tree,
        .popups = popupLayer(layer).createSceneTree() catch {
            gpa.destroy(l);
            return layer_surface.destroy();
        },
        .mon = m,
    };
    layer_surface.data = l;
    layer_surface.surface.data = l.popups;
    l.scene.node.data = &l.owner;
    l.popups.node.data = &l.owner;
    m.layers[index(layer)].prepend(l);

    layer_surface.surface.events.commit.add(&l.commit);
    layer_surface.surface.events.unmap.add(&l.unmap);
    layer_surface.events.destroy.add(&l.destroy);
    layer_surface.surface.sendEnter(output);
}

pub fn fromSurface(s: *wlr.Surface) ?*LayerSurface {
    const ls = wlr.LayerSurfaceV1.tryFromWlrSurface(s) orelse return null;
    return @ptrCast(@alignCast(ls.data orelse return null));
}

fn onCommit(listener: *wl.Listener(*wlr.Surface), _: *wlr.Surface) void {
    const l: *LayerSurface = @fieldParentPtr("commit", listener);
    const ls = l.layer_surface;

    if (ls.initial_commit) {
        // Arrange with the pending state so the first configure has the right size.
        const old = ls.current;
        ls.current = ls.pending;
        l.mon.arrangeLayers();
        ls.current = old;
        return;
    }

    if (@as(u32, @bitCast(ls.current.committed)) == 0 and l.mapped == ls.surface.mapped) return;
    const mapping = ls.surface.mapped and !l.mapped;
    l.mapped = ls.surface.mapped;

    const target = sceneLayer(ls.current.layer);
    if (l.scene.node.parent != target) {
        l.scene.node.reparent(target);
        l.link.remove();
        l.mon.layers[index(ls.current.layer)].prepend(l);
        l.popups.node.reparent(popupLayer(ls.current.layer));
    }
    l.mon.arrangeLayers();

    // like sway, on_demand surfaces above windows get the keyboard once when they appear
    const above = @intFromEnum(ls.current.layer) >= @intFromEnum(zwlr.LayerShellV1.Layer.top);
    if (mapping and above and ls.current.keyboard_interactive == .on_demand and !input.locked and server.exclusive_focus == null) {
        server.focus(null, false);
        input.keyboardEnter(ls.surface);
    }
}

fn onUnmap(listener: *wl.Listener(void)) void {
    const l: *LayerSurface = @fieldParentPtr("unmap", listener);
    l.mapped = false;
    l.scene.node.setEnabled(false);
    if (server.exclusive_focus == l) server.exclusive_focus = null;
    if (l.layer_surface.output) |o| if (Monitor.fromOutput(o)) |m| {
        l.mon = m;
        m.arrangeLayers();
    };
    if (l.layer_surface.surface == server.seat.keyboard_state.focused_surface)
        server.focus(server.focustop(server.selmon), true);
    input.motionNotify(0, null, 0, 0, 0, 0);
}

fn onDestroy(listener: *wl.Listener(*wlr.LayerSurfaceV1), _: *wlr.LayerSurfaceV1) void {
    const l: *LayerSurface = @fieldParentPtr("destroy", listener);
    l.link.remove();
    l.commit.link.remove();
    l.unmap.link.remove();
    l.destroy.link.remove();
    l.popups.node.destroy();
    gpa.destroy(l);
}
