const Monitor = @This();

const std = @import("std");
const log = std.log;
const wl = @import("wayland").server.wl;
const wlr = @import("wlroots");

const config = @import("config.zig");
const actions = @import("actions.zig");
const input = @import("input.zig");
const server = &@import("main.zig").server;
const Client = @import("Client.zig");

const gpa = std.heap.c_allocator;

link: wl.list.Link = undefined,
output: *wlr.Output,
scene_output: *wlr.SceneOutput,
fullscreen_bg: *wlr.SceneRect,
/// Whole monitor, then the part left for windows, in layout coordinates.
m: wlr.Box = .{ .x = 0, .y = 0, .width = 0, .height = 0 },
w: wlr.Box = .{ .x = 0, .y = 0, .width = 0, .height = 0 },
tagset: [2]u32 = .{ 1, 1 },
seltags: u1 = 0,
lt: [2]*const actions.Layout,
sellt: u1 = 0,
ltsymbol: [16:0]u8 = @splat(0),
/// Horizontal scroll of the strip, per tag plus one for multi-tag views.
scroll: [config.tags.len + 1]i32 = @splat(0),

frame: wl.Listener(*wlr.Output) = .init(onFrame),
destroy: wl.Listener(*wlr.Output) = .init(onDestroy),
request_state: wl.Listener(*wlr.Output.event.RequestState) = .init(onRequestState),

pub fn create(_: *wl.Listener(*wlr.Output), output: *wlr.Output) void {
    createInner(output) catch |err| log.err("could not set up output {s}: {}", .{ output.name, err });
}

fn createInner(output: *wlr.Output) !void {
    if (!output.initRender(server.allocator, server.renderer)) return error.InitRenderFailed;

    const rule = for (&config.monrules) |*r| {
        if (r.name == null or std.mem.eql(u8, r.name.?, std.mem.span(output.name))) break r;
    } else &config.monrules[config.monrules.len - 1];

    var state = wlr.Output.State.init();
    defer state.finish();
    state.setEnabled(true);
    if (output.preferredMode()) |mode| state.setMode(mode);
    state.setScale(rule.scale);
    state.setTransform(rule.transform);
    if (!output.commitState(&state)) log.err("could not enable output {s}", .{output.name});

    const m = try gpa.create(Monitor);
    errdefer gpa.destroy(m);
    m.* = .{
        .output = output,
        .scene_output = try server.scene.createSceneOutput(output),
        .fullscreen_bg = try server.layers.get(.fs).createSceneRect(0, 0, &config.fullscreen_bg),
        .lt = .{ rule.layout, &config.layouts[1] },
    };
    output.data = m;
    m.fullscreen_bg.node.setEnabled(false);

    output.events.frame.add(&m.frame);
    output.events.destroy.add(&m.destroy);
    output.events.request_state.add(&m.request_state);
    server.monitors.append(m);
    if (server.selmon == null) server.selmon = m;
    input.loadCursorScale(output.scale);

    const lo = if (rule.x < 0 or rule.y < 0)
        try server.output_layout.addAuto(output)
    else
        try server.output_layout.add(output, rule.x, rule.y);
    server.scene_layout.addOutput(lo, m.scene_output);
}

fn onFrame(listener: *wl.Listener(*wlr.Output), _: *wlr.Output) void {
    const m: *Monitor = @fieldParentPtr("frame", listener);
    _ = m.scene_output.commit(null);
    var now: std.posix.timespec = undefined;
    _ = std.c.clock_gettime(.MONOTONIC, &now);
    m.scene_output.sendFrameDone(&now);
}

fn onRequestState(_: *wl.Listener(*wlr.Output.event.RequestState), event: *wlr.Output.event.RequestState) void {
    _ = event.output.commitState(event.state);
    updateAll();
}

fn onDestroy(listener: *wl.Listener(*wlr.Output), _: *wlr.Output) void {
    const m: *Monitor = @fieldParentPtr("destroy", listener);
    m.frame.link.remove();
    m.destroy.link.remove();
    m.request_state.link.remove();
    m.link.remove();
    m.output.data = null;
    server.output_layout.remove(m.output);
    m.scene_output.destroy();
    m.close();
    m.fullscreen_bg.node.destroy();
    gpa.destroy(m);
}

/// Move everything off a monitor that is going away or being disabled.
fn close(m: *Monitor) void {
    if (server.selmon == m) {
        server.selmon = null;
        var it = server.monitors.iterator(.forward);
        while (it.next()) |other| if (other != m and other.output.enabled) {
            server.selmon = other;
            break;
        };
    }
    var it = server.clients.iterator(.forward);
    while (it.next()) |cl| {
        if (cl.mon != m) continue;
        if (cl.floating and cl.geom.x > m.m.width) {
            const g = cl.geom;
            cl.resize(.{ .x = g.x - m.w.width, .y = g.y, .width = g.width, .height = g.height }, false);
        }
        cl.setMon(server.selmon, cl.tags);
    }
    server.focus(server.focustop(server.selmon), true);
}

pub fn updateAll() void {
    var it = server.monitors.iterator(.forward);
    while (it.next()) |m| {
        if (m.output.enabled) continue;
        server.output_layout.remove(m.output);
        m.close();
        m.m = std.mem.zeroes(wlr.Box);
        m.w = m.m;
    }
    it = server.monitors.iterator(.forward);
    while (it.next()) |m| {
        if (m.output.enabled and server.output_layout.get(m.output) == null)
            _ = server.output_layout.addAuto(m.output) catch {};
    }

    var all: wlr.Box = undefined;
    server.output_layout.getBox(null, &all);
    server.root_bg.node.setPosition(all.x, all.y);
    server.root_bg.setSize(all.width, all.height);

    it = server.monitors.iterator(.forward);
    while (it.next()) |m| {
        if (!m.output.enabled) continue;
        server.output_layout.getBox(m.output, &m.m);
        m.w = m.m;
        m.scene_output.setPosition(m.m.x, m.m.y);
        m.fullscreen_bg.node.setPosition(m.m.x, m.m.y);
        m.fullscreen_bg.setSize(m.m.width, m.m.height);
        m.arrange();
        if (server.focustop(m)) |cl| if (cl.fullscreen) cl.resize(m.m, false);
    }

    if (server.selmon) |sel| if (sel.output.enabled) {
        var cit = server.clients.iterator(.forward);
        while (cit.next()) |cl| if (cl.mon == null and cl.surface().mapped) cl.setMon(sel, cl.tags);
        server.focus(server.focustop(sel), true);
    };
}

pub fn tags(m: *const Monitor) u32 {
    return m.tagset[m.seltags];
}

pub fn layout(m: *const Monitor) *const actions.Layout {
    return m.lt[m.sellt];
}

pub fn arrange(m: *Monitor) void {
    if (!m.output.enabled) return;

    var it = server.clients.iterator(.forward);
    while (it.next()) |cl| {
        if (cl.mon != m) continue;
        const visible = cl.visibleOn(m);
        cl.scene.node.setEnabled(visible);
        cl.setSuspended(!visible);
    }

    const top = server.focustop(m);
    m.fullscreen_bg.node.setEnabled(top != null and top.?.fullscreen);

    const lt = m.layout();
    m.setSymbol(lt.symbol);

    // In the floating layout every window shares one layer, so windows that
    // were floating before don't stay pinned above the rest.
    it = server.clients.iterator(.forward);
    while (it.next()) |cl| {
        if (cl.mon != m or cl.scene.node.parent == server.layers.get(.fs)) continue;
        cl.scene.node.reparent(server.layers.get(if (cl.floating and lt.arrange != null) .float else .tile));
    }

    if (lt.arrange) |f| f(m);
    input.motionNotify(0, null, 0, 0, 0, 0);
}

pub fn setSymbol(m: *Monitor, s: []const u8) void {
    const n = @min(s.len, m.ltsymbol.len);
    @memcpy(m.ltsymbol[0..n], s[0..n]);
    m.ltsymbol[n] = 0;
}

pub fn fromOutput(output: *wlr.Output) ?*Monitor {
    return @ptrCast(@alignCast(output.data));
}
