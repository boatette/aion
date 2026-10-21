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
const LayerSurface = @import("LayerSurface.zig");
const lock = @import("lock.zig");
const Bar = @import("Bar.zig");

const gpa = std.heap.c_allocator;

link: wl.list.Link = undefined,
output: *wlr.Output,
scene_output: *wlr.SceneOutput,
fullscreen_bg: *wlr.SceneRect,
/// whole monitor, then the part left for windows, in layout coordinates
m: wlr.Box = .{ .x = 0, .y = 0, .width = 0, .height = 0 },
w: wlr.Box = .{ .x = 0, .y = 0, .width = 0, .height = 0 },
tagset: [2]u32 = .{ 1, 1 },
seltags: u1 = 0,
lt: [2]*const actions.Layout,
sellt: u1 = 0,
ltsymbol: [16:0]u8 = @splat(0),
/// strip scroll per tag, plus one for multi-tag views
scroll: [config.tags.len + 1]i32 = @splat(0),
/// a tag swipe pushing the view up by offset pixels (down when negative) as tags slide in
swipe: ?struct { tags: u32, offset: i32 } = null,
/// how far down the layout being arranged is drawn
shift: i32 = 0,
/// layer surfaces per layer, background to overlay, newest first
layers: [4]wl.list.Head(LayerSurface, .link) = undefined,
lock_surface: ?*lock.LockSurface = null,
/// turned off by output power management but kept in the layout
asleep: bool = false,
bar: Bar = undefined,

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

    const scene_output = try server.scene.createSceneOutput(output);
    errdefer scene_output.destroy();
    const fullscreen_bg = try server.layers.get(.fs).createSceneRect(0, 0, &config.fullscreen_bg);
    errdefer fullscreen_bg.node.destroy();
    const m = try gpa.create(Monitor);
    errdefer gpa.destroy(m);
    m.* = .{
        .output = output,
        .scene_output = scene_output,
        .fullscreen_bg = fullscreen_bg,
        .lt = .{ rule.layout, &config.layouts[1] },
    };
    for (&m.layers) |*l| l.init();
    try m.bar.init(m);
    output.data = m;
    m.fullscreen_bg.node.setEnabled(false);

    output.events.frame.add(&m.frame);
    output.events.destroy.add(&m.destroy);
    output.events.request_state.add(&m.request_state);
    server.monitors.append(m);
    if (server.selmon == null) server.selmon = m;
    input.loadCursorScale(output.scale);

    // m is linked now, so a failure leaves it out of the layout instead of freeing it
    const lo = (if (rule.x < 0 or rule.y < 0)
        server.output_layout.addAuto(output)
    else
        server.output_layout.add(output, rule.x, rule.y)) catch |err| {
        log.err("could not add output {s} to the layout: {}", .{ output.name, err });
        return;
    };
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
    for (&m.layers) |*list| {
        var lit = list.iterator(.forward);
        while (lit.next()) |l| l.layer_surface.destroy();
    }
    lock.monitorGone(m);
    input.monitorGone(m);
    m.frame.link.remove();
    m.destroy.link.remove();
    m.request_state.link.remove();
    m.link.remove();
    m.output.data = null;
    server.output_layout.remove(m.output);
    m.scene_output.destroy();
    m.close();
    m.fullscreen_bg.node.destroy();
    m.bar.deinit();
    gpa.destroy(m);
}

/// move everything off a monitor that is going away or being disabled
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

var output_manager: *wlr.OutputManagerV1 = undefined;
var manager_apply: wl.Listener(*wlr.OutputConfigurationV1) = .init(onManagerApply);
var manager_test: wl.Listener(*wlr.OutputConfigurationV1) = .init(onManagerTest);
var power_set_mode: wl.Listener(*wlr.OutputPowerManagerV1.event.SetMode) = .init(onPowerSetMode);

pub fn initManagers() !void {
    output_manager = try wlr.OutputManagerV1.create(server.wl_server);
    output_manager.events.apply.add(&manager_apply);
    output_manager.events.@"test".add(&manager_test);
    (try wlr.OutputPowerManagerV1.create(server.wl_server)).events.set_mode.add(&power_set_mode);
}

pub fn deinitManagers() void {
    manager_apply.link.remove();
    manager_test.link.remove();
    power_set_mode.link.remove();
}

fn onManagerApply(_: *wl.Listener(*wlr.OutputConfigurationV1), config_: *wlr.OutputConfigurationV1) void {
    applyConfig(config_, false);
}

fn onManagerTest(_: *wl.Listener(*wlr.OutputConfigurationV1), config_: *wlr.OutputConfigurationV1) void {
    applyConfig(config_, true);
}

fn applyConfig(cfg: *wlr.OutputConfigurationV1, test_only: bool) void {
    var ok = true;
    var it = cfg.heads.iterator(.forward);
    while (it.next()) |head| {
        const output = head.state.output;
        const m = fromOutput(output) orelse continue;
        var state = wlr.Output.State.init();
        defer state.finish();
        head.state.apply(&state);
        if (test_only) {
            ok = output.testState(&state) and ok;
            continue;
        }
        ok = output.commitState(&state) and ok;
        m.asleep = false;
        input.loadCursorScale(output.scale);
        // re-adding an output that didn't move would mark it manually placed
        if (output.enabled and (m.m.x != head.state.x or m.m.y != head.state.y))
            _ = server.output_layout.add(output, head.state.x, head.state.y) catch {};
    }
    if (ok) cfg.sendSucceeded() else cfg.sendFailed();
    cfg.destroy();
    updateAll();
}

fn onPowerSetMode(_: *wl.Listener(*wlr.OutputPowerManagerV1.event.SetMode), event: *wlr.OutputPowerManagerV1.event.SetMode) void {
    const m = fromOutput(event.output) orelse return;
    var state = wlr.Output.State.init();
    defer state.finish();
    state.setEnabled(event.mode == .on);
    _ = m.output.commitState(&state);
    m.asleep = event.mode == .off;
    updateAll();
}

/// tell output management clients how things look now
fn publishConfig() void {
    const cfg = wlr.OutputConfigurationV1.create() catch return;
    var it = server.monitors.iterator(.forward);
    while (it.next()) |m| {
        const head = wlr.OutputConfigurationV1.Head.create(cfg, m.output) catch continue;
        head.state.enabled = m.output.enabled;
        head.state.x = m.m.x;
        head.state.y = m.m.y;
    }
    output_manager.setConfiguration(cfg);
}

var updating = false;

pub fn updateAll() void {
    // the layout changes made here fire this again; the outer pass sees the result anyway
    if (updating) return;
    updating = true;
    defer updating = false;

    var it = server.monitors.iterator(.forward);
    while (it.next()) |m| {
        if (m.output.enabled or m.asleep) continue;
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
    lock.updateLayout(all);

    it = server.monitors.iterator(.forward);
    while (it.next()) |m| {
        if (!m.output.enabled) continue;
        server.output_layout.getBox(m.output, &m.m);
        m.w = m.m;
        m.scene_output.setPosition(m.m.x, m.m.y);
        m.fullscreen_bg.node.setPosition(m.m.x, m.m.y);
        m.fullscreen_bg.setSize(m.m.width, m.m.height);
        m.arrangeLayers();
        m.arrange();
        if (server.focustop(m)) |cl| if (cl.fullscreen) cl.resize(m.m, false);
    }

    if (server.selmon) |sel| if (sel.output.enabled) {
        var cit = server.clients.iterator(.forward);
        while (cit.next()) |cl| if (cl.mon == null and cl.mapped()) cl.setMon(sel, cl.tags);
        server.focus(server.focustop(sel), true);
    };
    publishConfig();
    Bar.redraw();
}

/// place layer surfaces and shrink the window area by their exclusive zones
pub fn arrangeLayers(m: *Monitor) void {
    if (!m.output.enabled) return;
    var usable = m.m;
    const bar = Bar.reserved(m);
    usable.y += bar;
    usable.height -= bar;
    var i: usize = m.layers.len;
    while (i > 0) : (i -= 1) m.arrangeLayer(i - 1, &usable, true);
    if (!usable.equal(&m.w)) {
        m.w = usable;
        m.arrange();
    }
    i = m.layers.len;
    while (i > 0) : (i -= 1) m.arrangeLayer(i - 1, &usable, false);

    if (input.locked) return;
    for ([_]usize{ 3, 2 }) |li| {
        var it = m.layers[li].iterator(.forward);
        while (it.next()) |l| {
            if (l.layer_surface.current.keyboard_interactive != .exclusive or !l.mapped) continue;
            if (server.seat.keyboard_state.focused_surface != l.layer_surface.surface) {
                server.focus(null, false);
                input.keyboardEnter(l.layer_surface.surface);
            }
            server.exclusive_focus = l;
            return;
        }
    }
    // the surface holding the keyboard stopped asking for it
    if (server.exclusive_focus) |l| if (l.mon == m) {
        server.exclusive_focus = null;
        server.focus(server.focustop(server.selmon), true);
    };
}

fn arrangeLayer(m: *Monitor, i: usize, usable: *wlr.Box, exclusive: bool) void {
    var it = m.layers[i].iterator(.forward);
    while (it.next()) |l| {
        const ls = l.layer_surface;
        if (!ls.initialized or exclusive != (ls.current.exclusive_zone > 0)) continue;
        l.scene_layer.configure(&m.m, usable);
        l.popups.node.setPosition(l.scene.node.x, l.scene.node.y);
    }
}

pub fn tags(m: *const Monitor) u32 {
    return m.tagset[m.seltags];
}

pub fn layout(m: *const Monitor) *const actions.Layout {
    return m.lt[m.sellt];
}

pub fn arrange(m: *Monitor) void {
    if (!m.output.enabled) return;
    const incoming: u32 = if (m.swipe) |s| s.tags else 0;

    var it = server.clients.iterator(.forward);
    while (it.next()) |cl| {
        if (cl.mon != m) continue;
        const visible = cl.tags & (m.tags() | incoming) != 0;
        cl.scene.node.setEnabled(visible);
        cl.setSuspended(!visible);
    }

    const top = server.focustop(m);
    const fs = top != null and top.?.fullscreen;
    m.fullscreen_bg.node.setEnabled(fs);
    if (fs) m.fullscreen_bg.node.setPosition(m.m.x, m.m.y + m.swipeShift(top.?.tags));

    const lt = m.layout();

    // the floating layout keeps every window in one layer, so earlier floaters don't stay on top
    it = server.clients.iterator(.forward);
    while (it.next()) |cl| {
        if (cl.mon != m or cl.scene.node.parent == server.layers.get(.fs)) continue;
        cl.scene.node.reparent(server.layers.get(if (cl.floating and lt.arrange != null) .float else .tile));
    }

    // incoming tags go first, so windows shared with the current view end up in it
    if (m.swipe) |s| {
        const cur = m.tags();
        m.tagset[m.seltags] = s.tags;
        m.arrangeShifted(lt, m.swipeShift(s.tags));
        m.tagset[m.seltags] = cur;
    }
    m.setSymbol(lt.symbol);
    m.arrangeShifted(lt, m.swipeShift(m.tags()));
    // counts and occupied tags may have changed; the bar skips drawing if nothing did
    Bar.redraw();
    input.motionNotify(0, null, 0, 0, 0, 0);
    lock.checkInhibitors(null);
}

/// how far a tag swipe moves windows on tags t, the current view winning for shared ones
pub fn swipeShift(m: *const Monitor, t: u32) i32 {
    const s = m.swipe orelse return 0;
    if (t & m.tags() != 0) return -s.offset;
    if (t & s.tags != 0) return if (s.offset > 0) m.w.height - s.offset else -m.w.height - s.offset;
    return 0;
}

fn arrangeShifted(m: *Monitor, lt: *const actions.Layout, shift: i32) void {
    m.shift = shift;
    defer m.shift = 0;
    if (lt.arrange) |f| f(m);
    // layouts only place tiled windows, so move the rest along with them
    var it = server.clients.iterator(.forward);
    while (it.next()) |cl| {
        if (!cl.visibleOn(m) or (cl.tiled() and lt.arrange != null)) continue;
        cl.scene.node.setPosition(cl.geom.x, cl.geom.y + shift);
    }
}

pub fn setSymbol(m: *Monitor, s: []const u8) void {
    const n = @min(s.len, m.ltsymbol.len);
    @memcpy(m.ltsymbol[0..n], s[0..n]);
    m.ltsymbol[n] = 0;
}

pub fn fromOutput(output: *wlr.Output) ?*Monitor {
    return @ptrCast(@alignCast(output.data));
}
