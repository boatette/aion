const std = @import("std");
const wl = @import("wayland").server.wl;
const wlr = @import("wlroots");
const xkb = @import("xkbcommon");
const c = @import("c");

const config = @import("config.zig");
const actions = @import("actions.zig");
const scroll = @import("scroll.zig");
const server = &@import("main.zig").server;
const Client = @import("Client.zig");
const Monitor = @import("Monitor.zig");

const gpa = std.heap.c_allocator;

pub const CursorMode = enum { normal, pressed, move, resize };

pub var locked = false;
pub var cursor_mode: CursorMode = .normal;
var grabc: ?*Client = null;
var grabcx: i32 = 0;
var grabcy: i32 = 0;

var xcursor: *wlr.XcursorManager = undefined;
var group: *wlr.KeyboardGroup = undefined;
var group_keyboard: Keyboard = undefined;
/// Keys whose press ran a binding; their release is not sent to clients.
var consumed: std.StaticBitSet(1024) = .initEmpty();

var new_input: wl.Listener(*wlr.InputDevice) = .init(onNewInput);
var motion: wl.Listener(*wlr.Pointer.event.Motion) = .init(onMotion);
var motion_absolute: wl.Listener(*wlr.Pointer.event.MotionAbsolute) = .init(onMotionAbsolute);
var button: wl.Listener(*wlr.Pointer.event.Button) = .init(onButton);
var axis: wl.Listener(*wlr.Pointer.event.Axis) = .init(onAxis);
var frame: wl.Listener(*wlr.Cursor) = .init(onFrame);
var request_cursor: wl.Listener(*wlr.Seat.event.RequestSetCursor) = .init(onRequestCursor);
var request_selection: wl.Listener(*wlr.Seat.event.RequestSetSelection) = .init(onRequestSelection);
var request_start_drag: wl.Listener(*wlr.Seat.event.RequestStartDrag) = .init(onRequestStartDrag);
var start_drag: wl.Listener(*wlr.Drag) = .init(onStartDrag);
var drag_icon_destroy: wl.Listener(*wlr.Drag.Icon) = .init(onDragIconDestroy);

pub fn init() !void {
    const cursor = server.cursor;
    cursor.attachOutputLayout(server.output_layout);
    const size: u32 = if (c.getenv("XCURSOR_SIZE")) |s| std.fmt.parseInt(u32, std.mem.span(s), 10) catch 24 else 24;
    xcursor = try wlr.XcursorManager.create(c.getenv("XCURSOR_THEME"), size);

    cursor.events.motion.add(&motion);
    cursor.events.motion_absolute.add(&motion_absolute);
    cursor.events.button.add(&button);
    cursor.events.axis.add(&axis);
    cursor.events.frame.add(&frame);

    server.backend.events.new_input.add(&new_input);
    server.seat.events.request_set_cursor.add(&request_cursor);
    server.seat.events.request_set_selection.add(&request_selection);
    server.seat.events.request_start_drag.add(&request_start_drag);
    server.seat.events.start_drag.add(&start_drag);

    drag_icon_destroy.link.init();
    group = try wlr.KeyboardGroup.create();
    try group_keyboard.init(&group.keyboard);
    server.seat.setKeyboard(&group.keyboard);
    server.seat.setCapabilities(.{ .pointer = true, .keyboard = true });
}

pub fn loadCursorScale(scale: f32) void {
    xcursor.load(scale) catch {};
}

pub fn updateCursor() void {
    server.cursor.setXcursor(xcursor, "default");
}

pub fn clientGone(cl: *Client) void {
    if (grabc == cl) {
        grabc = null;
        cursor_mode = .normal;
    }
}

pub fn keyboardEnter(s: *wlr.Surface) void {
    if (server.seat.getKeyboard()) |kb| {
        server.seat.keyboardNotifyEnter(s, kb.keycodes[0..kb.num_keycodes], &kb.modifiers);
    } else {
        server.seat.keyboardNotifyEnter(s, &.{}, null);
    }
}

pub fn modifiers() u32 {
    const kb = server.seat.getKeyboard() orelse return 0;
    return @bitCast(kb.getModifiers());
}

fn clean(mods: u32) u32 {
    const caps: u32 = 1 << 1;
    return mods & ~caps;
}

const Keyboard = struct {
    kb: *wlr.Keyboard,
    syms: [2]xkb.Keysym = .{ .NoSymbol, .NoSymbol },
    mods: u32 = 0,
    repeat_source: *wl.EventSource,
    key: wl.Listener(*wlr.Keyboard.event.Key) = .init(onKey),
    modifiers: wl.Listener(*wlr.Keyboard) = .init(onModifiers),

    fn init(k: *Keyboard, kb: *wlr.Keyboard) !void {
        const context = xkb.Context.new(.no_flags) orelse return error.XkbContext;
        defer context.unref();
        const keymap = xkb.Keymap.newFromNames(context, &config.xkb_rules, .no_flags) orelse return error.XkbKeymap;
        defer keymap.unref();
        _ = kb.setKeymap(keymap);
        kb.setRepeatInfo(config.repeat_rate, config.repeat_delay);

        k.* = .{
            .kb = kb,
            .repeat_source = try server.wl_server.getEventLoop().addTimer(*Keyboard, repeat, k),
        };
        kb.events.key.add(&k.key);
        kb.events.modifiers.add(&k.modifiers);
    }

    fn binding(k: *Keyboard) ?*const actions.Key {
        for (k.syms) |sym| {
            for (&config.keys) |*key| {
                if (clean(k.mods) == clean(key.mod) and sym == key.sym) return key;
            }
        }
        return null;
    }

    fn onKey(listener: *wl.Listener(*wlr.Keyboard.event.Key), event: *wlr.Keyboard.event.Key) void {
        const k: *Keyboard = @fieldParentPtr("key", listener);
        const keycode = event.keycode + 8;
        const keymap = k.kb.keymap orelse return;
        const layout = k.kb.xkb_state.?.keyGetLayout(keycode);
        // Match bindings on the unshifted and shifted symbols, so Mod+Shift+1
        // works whatever symbol Shift+1 types.
        for (&k.syms, 0..) |*sym, level| {
            const syms = keymap.keyGetSymsByLevel(keycode, layout, @intCast(level));
            sym.* = if (syms.len > 0) syms[0] else .NoSymbol;
        }
        k.mods = @bitCast(k.kb.getModifiers());

        var handled = false;
        if (!locked and event.state == .pressed) {
            if (k.binding()) |key| {
                consumed.set(event.keycode);
                key.func(&key.arg);
                handled = true;
            }
        }
        k.repeat_source.timerUpdate(if (handled) @max(k.kb.repeat_info.delay, 0) else 0) catch {};
        if (handled) return;

        if (event.keycode < consumed.capacity() and consumed.isSet(event.keycode)) {
            if (event.state == .released) consumed.unset(event.keycode);
            return;
        }
        server.seat.setKeyboard(k.kb);
        server.seat.keyboardNotifyKey(event.time_msec, event.keycode, event.state);
    }

    fn onModifiers(listener: *wl.Listener(*wlr.Keyboard), _: *wlr.Keyboard) void {
        const k: *Keyboard = @fieldParentPtr("modifiers", listener);
        server.seat.setKeyboard(k.kb);
        server.seat.keyboardNotifyModifiers(&k.kb.modifiers);
    }

    fn repeat(k: *Keyboard) c_int {
        if (k.kb.repeat_info.rate > 0) k.repeat_source.timerUpdate(@divTrunc(1000, k.kb.repeat_info.rate)) catch {};
        if (k.binding()) |key| key.func(&key.arg);
        return 0;
    }
};

fn onNewInput(_: *wl.Listener(*wlr.InputDevice), device: *wlr.InputDevice) void {
    switch (device.type) {
        .keyboard => _ = group.addKeyboard(device.toKeyboard()),
        .pointer => {
            configurePointer(device);
            server.cursor.attachInputDevice(device);
        },
        else => {},
    }
}

fn configurePointer(device: *wlr.InputDevice) void {
    const li: *c.struct_libinput_device = @ptrCast(device.getLibinputDevice() orelse return);
    const touchpad = c.libinput_device_config_tap_get_finger_count(li) > 0;
    if (touchpad) {
        _ = c.libinput_device_config_tap_set_enabled(li, @intFromBool(config.tap_to_click));
        _ = c.libinput_device_config_tap_set_drag_enabled(li, @intFromBool(config.tap_and_drag));
        _ = c.libinput_device_config_tap_set_drag_lock_enabled(li, @intFromBool(config.drag_lock));
        _ = c.libinput_device_config_tap_set_button_map(li, config.button_map);
    }
    // Natural scrolling is for touchpads; mice keep the usual wheel direction.
    if (c.libinput_device_config_scroll_has_natural_scroll(li) != 0)
        _ = c.libinput_device_config_scroll_set_natural_scroll_enabled(li, @intFromBool(config.natural_scrolling and touchpad));
    if (c.libinput_device_config_dwt_is_available(li) != 0)
        _ = c.libinput_device_config_dwt_set_enabled(li, @intFromBool(config.disable_while_typing));
    if (c.libinput_device_config_left_handed_is_available(li) != 0)
        _ = c.libinput_device_config_left_handed_set(li, @intFromBool(config.left_handed));
    if (c.libinput_device_config_middle_emulation_is_available(li) != 0)
        _ = c.libinput_device_config_middle_emulation_set_enabled(li, @intFromBool(config.middle_button_emulation));
    if (c.libinput_device_config_scroll_get_methods(li) != c.LIBINPUT_CONFIG_SCROLL_NO_SCROLL)
        _ = c.libinput_device_config_scroll_set_method(li, config.scroll_method);
    if (c.libinput_device_config_click_get_methods(li) != c.LIBINPUT_CONFIG_CLICK_METHOD_NONE)
        _ = c.libinput_device_config_click_set_method(li, config.click_method);
    if (c.libinput_device_config_send_events_get_modes(li) != 0)
        _ = c.libinput_device_config_send_events_set_mode(li, config.send_events_mode);
    if (c.libinput_device_config_accel_is_available(li) != 0) {
        _ = c.libinput_device_config_accel_set_profile(li, config.accel_profile);
        _ = c.libinput_device_config_accel_set_speed(li, config.accel_speed);
    }
}

fn monAt(x: f64, y: f64) ?*Monitor {
    const output = server.output_layout.outputAt(x, y) orelse return null;
    return Monitor.fromOutput(output);
}

fn now() u32 {
    var ts: std.posix.timespec = undefined;
    _ = std.c.clock_gettime(.MONOTONIC, &ts);
    return @truncate(@as(u64, @intCast(ts.sec)) * 1000 + @as(u64, @intCast(ts.nsec)) / 1_000_000);
}

fn onMotion(_: *wl.Listener(*wlr.Pointer.event.Motion), event: *wlr.Pointer.event.Motion) void {
    motionNotify(event.time_msec, event.device, event.delta_x, event.delta_y, event.unaccel_dx, event.unaccel_dy);
}

fn onMotionAbsolute(_: *wl.Listener(*wlr.Pointer.event.MotionAbsolute), event: *wlr.Pointer.event.MotionAbsolute) void {
    var lx: f64 = undefined;
    var ly: f64 = undefined;
    server.cursor.absoluteToLayoutCoords(event.device, event.x, event.y, &lx, &ly);
    const dx = lx - server.cursor.x;
    const dy = ly - server.cursor.y;
    motionNotify(event.time_msec, event.device, dx, dy, dx, dy);
}

/// time == 0 means nothing moved and pointer focus should just be refreshed.
pub fn motionNotify(time: u32, device: ?*wlr.InputDevice, dx: f64, dy: f64, dx_unaccel: f64, dy_unaccel: f64) void {
    _ = dx_unaccel;
    _ = dy_unaccel;
    const cursor = server.cursor;
    if (time != 0) {
        cursor.move(device, dx, dy);
        if (config.sloppyfocus) server.selmon = monAt(cursor.x, cursor.y) orelse server.selmon;
    }
    server.drag_icons.node.setPosition(@intFromFloat(@round(cursor.x)), @intFromFloat(@round(cursor.y)));

    switch (cursor_mode) {
        .move => if (grabc) |g| {
            g.resize(.{
                .x = @as(i32, @intFromFloat(@round(cursor.x))) - grabcx,
                .y = @as(i32, @intFromFloat(@round(cursor.y))) - grabcy,
                .width = g.geom.width,
                .height = g.geom.height,
            }, true);
            return;
        },
        .resize => if (grabc) |g| {
            g.resize(.{
                .x = g.geom.x,
                .y = g.geom.y,
                .width = @as(i32, @intFromFloat(@round(cursor.x))) - g.geom.x,
                .height = @as(i32, @intFromFloat(@round(cursor.y))) - g.geom.y,
            }, true);
            return;
        },
        else => {},
    }

    var hit = server.hitTest(cursor.x, cursor.y);

    // While a button is held, keep sending motion to the surface it was pressed on.
    if (cursor_mode == .pressed and server.seat.drag == null) {
        if (server.seat.pointer_state.focused_surface) |focused| {
            if (focused != hit.surface) {
                if (Client.fromSurface(focused)) |cl| {
                    hit = .{
                        .surface = focused,
                        .client = cl,
                        .sx = cursor.x - @as(f64, @floatFromInt(cl.geom.x + cl.bw)),
                        .sy = cursor.y - @as(f64, @floatFromInt(cl.geom.y + cl.bw)),
                    };
                }
            }
        }
    }

    if (hit.surface == null and server.seat.drag == null) updateCursor();
    pointerFocus(hit.client, hit.surface, hit.sx, hit.sy, time);
}

fn pointerFocus(cl: ?*Client, s: ?*wlr.Surface, sx: f64, sy: f64, time: u32) void {
    if (config.sloppyfocus and time != 0 and cl != null and s != server.seat.pointer_state.focused_surface)
        server.focus(cl, false);
    const surf = s orelse {
        server.seat.pointerNotifyClearFocus();
        return;
    };
    server.seat.pointerNotifyEnter(surf, sx, sy);
    server.seat.pointerNotifyMotion(if (time != 0) time else now(), sx, sy);
}

fn onButton(_: *wl.Listener(*wlr.Pointer.event.Button), event: *wlr.Pointer.event.Button) void {
    switch (event.state) {
        .pressed => {
            cursor_mode = .pressed;
            server.selmon = monAt(server.cursor.x, server.cursor.y) orelse server.selmon;
            if (locked) {} else {
                const hit = server.hitTest(server.cursor.x, server.cursor.y);
                if (hit.client) |cl| {
                    server.focus(cl, true);
                    if (cl.tiled()) scroll.reveal(cl);
                }
                const mods = clean(modifiers());
                for (&config.buttons) |*b| {
                    if (mods == clean(b.mod) and event.button == b.button) {
                        b.func(&b.arg);
                        return;
                    }
                }
            }
        },
        .released => {
            if (!locked and cursor_mode != .normal and cursor_mode != .pressed) {
                updateCursor();
                cursor_mode = .normal;
                server.selmon = monAt(server.cursor.x, server.cursor.y) orelse server.selmon;
                if (grabc) |g| g.setMon(server.selmon, 0);
                grabc = null;
                return;
            }
            cursor_mode = .normal;
        },
        else => {},
    }
    _ = server.seat.pointerNotifyButton(event.time_msec, event.button, event.state);
}

fn onAxis(_: *wl.Listener(*wlr.Pointer.event.Axis), event: *wlr.Pointer.event.Axis) void {
    server.seat.pointerNotifyAxis(event.time_msec, event.orientation, event.delta, event.delta_discrete, event.source, event.relative_direction);
}

fn onFrame(_: *wl.Listener(*wlr.Cursor), _: *wlr.Cursor) void {
    server.seat.pointerNotifyFrame();
}

fn onRequestCursor(_: *wl.Listener(*wlr.Seat.event.RequestSetCursor), event: *wlr.Seat.event.RequestSetCursor) void {
    if (cursor_mode != .normal and cursor_mode != .pressed) return;
    if (event.seat_client == server.seat.pointer_state.focused_client)
        server.cursor.setSurface(event.surface, event.hotspot_x, event.hotspot_y);
}

fn onRequestSelection(_: *wl.Listener(*wlr.Seat.event.RequestSetSelection), event: *wlr.Seat.event.RequestSetSelection) void {
    server.seat.setSelection(event.source, event.serial);
}

fn onRequestStartDrag(_: *wl.Listener(*wlr.Seat.event.RequestStartDrag), event: *wlr.Seat.event.RequestStartDrag) void {
    if (server.seat.validatePointerGrabSerial(event.origin, event.serial)) {
        server.seat.startPointerDrag(event.drag, event.serial);
    } else if (event.drag.source) |source| {
        source.destroy();
    }
}

fn onStartDrag(_: *wl.Listener(*wlr.Drag), drag: *wlr.Drag) void {
    const icon = drag.icon orelse return;
    _ = server.drag_icons.createSceneDragIcon(icon) catch return;
    drag_icon_destroy.link.remove();
    icon.events.destroy.add(&drag_icon_destroy);
}

fn onDragIconDestroy(_: *wl.Listener(*wlr.Drag.Icon), _: *wlr.Drag.Icon) void {
    drag_icon_destroy.link.remove();
    drag_icon_destroy.link.init();
    server.focus(server.focustop(server.selmon), true);
    motionNotify(0, null, 0, 0, 0, 0);
}

/// Start an interactive move or resize of the client under the cursor.
pub fn grab(mode: CursorMode) void {
    if (cursor_mode != .pressed) return;
    const hit = server.hitTest(server.cursor.x, server.cursor.y);
    const cl = hit.client orelse return;
    if (cl.fullscreen) return;
    grabc = cl;
    cl.setFloating(true);
    cursor_mode = mode;
    const x: i32 = @intFromFloat(@round(server.cursor.x));
    const y: i32 = @intFromFloat(@round(server.cursor.y));
    switch (mode) {
        .move => {
            grabcx = x - cl.geom.x;
            grabcy = y - cl.geom.y;
            server.cursor.setXcursor(xcursor, "all-scroll");
        },
        .resize => {
            server.cursor.warpClosest(null, @floatFromInt(cl.geom.x + cl.geom.width), @floatFromInt(cl.geom.y + cl.geom.height));
            server.cursor.setXcursor(xcursor, "se-resize");
        },
        else => {},
    }
}
