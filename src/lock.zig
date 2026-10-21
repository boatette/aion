//! Session lock (swaylock) and idle notification (swayidle).

const std = @import("std");
const wl = @import("wayland").server.wl;
const wlr = @import("wlroots");

const input = @import("input.zig");
const server = &@import("main.zig").server;
const Monitor = @import("Monitor.zig");

const gpa = std.heap.c_allocator;

var locked_bg: *wlr.SceneRect = undefined;
var idle_notifier: *wlr.IdleNotifierV1 = undefined;
var inhibit_manager: *wlr.IdleInhibitManagerV1 = undefined;
var current: ?*Lock = null;

var new_lock: wl.Listener(*wlr.SessionLockV1) = .init(onNewLock);
var new_inhibitor: wl.Listener(*wlr.IdleInhibitorV1) = .init(onNewInhibitor);

pub fn init() !void {
    locked_bg = try server.layers.get(.block).createSceneRect(0, 0, &.{ 0.1, 0.1, 0.1, 1 });
    locked_bg.node.setEnabled(false);
    (try wlr.SessionLockManagerV1.create(server.wl_server)).events.new_lock.add(&new_lock);
    idle_notifier = try wlr.IdleNotifierV1.create(server.wl_server);
    inhibit_manager = try wlr.IdleInhibitManagerV1.create(server.wl_server);
    inhibit_manager.events.new_inhibitor.add(&new_inhibitor);
}

pub fn deinit() void {
    new_lock.link.remove();
    new_inhibitor.link.remove();
}

pub fn activity() void {
    idle_notifier.notifyActivity(server.seat);
}

/// Called when the output layout changes.
pub fn updateLayout(all: wlr.Box) void {
    locked_bg.node.setPosition(all.x, all.y);
    locked_bg.setSize(all.width, all.height);
    var it = server.monitors.iterator(.forward);
    while (it.next()) |m| if (m.lock_surface) |ls| ls.place();
}

pub fn monitorGone(m: *Monitor) void {
    const ls = m.lock_surface orelse return;
    ls.destroy.link.remove();
    m.lock_surface = null;
    gpa.destroy(ls);
}

/// Idle is inhibited while an inhibiting surface is actually on screen.
pub fn checkInhibitors(exclude: ?*wlr.Surface) void {
    var inhibited = false;
    var it = inhibit_manager.inhibitors.iterator(.forward);
    while (it.next()) |inhibitor| {
        const root = inhibitor.surface.getRootSurface();
        if (root == exclude) continue;
        const tree: ?*wlr.SceneTree = @ptrCast(@alignCast(root.data));
        var x: c_int = undefined;
        var y: c_int = undefined;
        if (tree != null and tree.?.node.coords(&x, &y)) {
            inhibited = true;
            break;
        }
    }
    idle_notifier.setInhibited(inhibited);
}

const Inhibitor = struct {
    destroy: wl.Listener(*wlr.Surface) = .init(onDestroy),

    fn onDestroy(listener: *wl.Listener(*wlr.Surface), surface: *wlr.Surface) void {
        const i: *Inhibitor = @fieldParentPtr("destroy", listener);
        i.destroy.link.remove();
        gpa.destroy(i);
        checkInhibitors(surface.getRootSurface());
    }
};

fn onNewInhibitor(_: *wl.Listener(*wlr.IdleInhibitorV1), inhibitor: *wlr.IdleInhibitorV1) void {
    const i = gpa.create(Inhibitor) catch return;
    i.* = .{};
    inhibitor.events.destroy.add(&i.destroy);
    checkInhibitors(null);
}

const Lock = struct {
    lock: *wlr.SessionLockV1,
    scene: *wlr.SceneTree,
    new_surface: wl.Listener(*wlr.SessionLockSurfaceV1) = .init(onNewSurface),
    unlock: wl.Listener(void) = .init(onUnlock),
    destroy: wl.Listener(void) = .init(onDestroy),

    fn finish(l: *Lock, unlocked: bool) void {
        server.seat.keyboardNotifyClearFocus();
        input.locked = !unlocked;
        if (unlocked) {
            locked_bg.node.setEnabled(false);
            server.focus(server.focustop(server.selmon), false);
            if (server.exclusive_focus) |e| input.keyboardEnter(e.layer_surface.surface);
            input.motionNotify(0, null, 0, 0, 0, 0);
        }
        l.new_surface.link.remove();
        l.unlock.link.remove();
        l.destroy.link.remove();
        l.scene.node.destroy();
        current = null;
        gpa.destroy(l);
    }

    fn onUnlock(listener: *wl.Listener(void)) void {
        const l: *Lock = @fieldParentPtr("unlock", listener);
        l.finish(true);
    }

    /// The locker went away without unlocking, so the session stays locked.
    fn onDestroy(listener: *wl.Listener(void)) void {
        const l: *Lock = @fieldParentPtr("destroy", listener);
        l.finish(false);
    }

    fn onNewSurface(listener: *wl.Listener(*wlr.SessionLockSurfaceV1), surface: *wlr.SessionLockSurfaceV1) void {
        const l: *Lock = @fieldParentPtr("new_surface", listener);
        const m = Monitor.fromOutput(surface.output) orelse return;
        const ls = gpa.create(LockSurface) catch return;
        ls.* = .{
            .surface = surface,
            .mon = m,
            .tree = l.scene.createSceneSubsurfaceTree(surface.surface) catch {
                gpa.destroy(ls);
                return;
            },
        };
        surface.surface.data = ls.tree;
        m.lock_surface = ls;
        ls.place();
        surface.events.destroy.add(&ls.destroy);
        if (m == server.selmon) input.keyboardEnter(surface.surface);
    }
};

pub const LockSurface = struct {
    surface: *wlr.SessionLockSurfaceV1,
    mon: *Monitor,
    tree: *wlr.SceneTree,
    destroy: wl.Listener(void) = .init(onDestroy),

    fn place(ls: *LockSurface) void {
        ls.tree.node.setPosition(ls.mon.m.x, ls.mon.m.y);
        _ = ls.surface.configure(@intCast(ls.mon.m.width), @intCast(ls.mon.m.height));
    }

    fn onDestroy(listener: *wl.Listener(void)) void {
        const ls: *LockSurface = @fieldParentPtr("destroy", listener);
        ls.destroy.link.remove();
        if (ls.mon.lock_surface == ls) ls.mon.lock_surface = null;
        const focused = ls.surface.surface == server.seat.keyboard_state.focused_surface;
        gpa.destroy(ls);
        if (!focused) return;
        if (input.locked and current != null) {
            if (current.?.lock.surfaces.first()) |other| input.keyboardEnter(other.surface) else server.seat.keyboardClearFocus();
        } else if (!input.locked) {
            server.focus(server.focustop(server.selmon), true);
        } else {
            server.seat.keyboardClearFocus();
        }
    }
};

fn onNewLock(_: *wl.Listener(*wlr.SessionLockV1), session_lock: *wlr.SessionLockV1) void {
    locked_bg.node.setEnabled(true);
    if (current != null) return session_lock.destroy();
    const l = gpa.create(Lock) catch return session_lock.destroy();
    l.* = .{
        .lock = session_lock,
        .scene = server.layers.get(.block).createSceneTree() catch {
            gpa.destroy(l);
            return session_lock.destroy();
        },
    };
    server.focus(null, false);
    current = l;
    input.locked = true;
    session_lock.events.new_surface.add(&l.new_surface);
    session_lock.events.unlock.add(&l.unlock);
    session_lock.events.destroy.add(&l.destroy);
    session_lock.sendLocked();
}
