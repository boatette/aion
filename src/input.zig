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
const lock = @import("lock.zig");
const Bar = @import("Bar.zig");
const menu = @import("menu.zig");

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
var request_primary_selection: wl.Listener(*wlr.Seat.event.RequestSetPrimarySelection) = .init(onRequestPrimarySelection);
var request_shape: wl.Listener(*wlr.CursorShapeManagerV1.event.RequestSetShape) = .init(onRequestShape);
var new_constraint: wl.Listener(*wlr.PointerConstraintV1) = .init(onNewConstraint);
var swipe_begin: wl.Listener(*wlr.Pointer.event.SwipeBegin) = .init(onSwipeBegin);
var swipe_update: wl.Listener(*wlr.Pointer.event.SwipeUpdate) = .init(onSwipeUpdate);
var swipe_end: wl.Listener(*wlr.Pointer.event.SwipeEnd) = .init(onSwipeEnd);
var pinch_begin: wl.Listener(*wlr.Pointer.event.PinchBegin) = .init(onPinchBegin);
var pinch_update: wl.Listener(*wlr.Pointer.event.PinchUpdate) = .init(onPinchUpdate);
var pinch_end: wl.Listener(*wlr.Pointer.event.PinchEnd) = .init(onPinchEnd);
var hold_begin: wl.Listener(*wlr.Pointer.event.HoldBegin) = .init(onHoldBegin);
var hold_end: wl.Listener(*wlr.Pointer.event.HoldEnd) = .init(onHoldEnd);

var relative_pointer: *wlr.RelativePointerManagerV1 = undefined;
var constraints: *wlr.PointerConstraintsV1 = undefined;
var active_constraint: ?*wlr.PointerConstraintV1 = null;
var gestures: *wlr.PointerGesturesV1 = undefined;

var new_virtual_keyboard: wl.Listener(*wlr.VirtualKeyboardV1) = .init(onNewVirtualKeyboard);
var new_virtual_pointer: wl.Listener(*wlr.VirtualPointerManagerV1.event.NewPointer) = .init(onNewVirtualPointer);

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
    cursor.events.swipe_begin.add(&swipe_begin);
    cursor.events.swipe_update.add(&swipe_update);
    cursor.events.swipe_end.add(&swipe_end);
    cursor.events.pinch_begin.add(&pinch_begin);
    cursor.events.pinch_update.add(&pinch_update);
    cursor.events.pinch_end.add(&pinch_end);
    cursor.events.hold_begin.add(&hold_begin);
    cursor.events.hold_end.add(&hold_end);

    relative_pointer = try wlr.RelativePointerManagerV1.create(server.wl_server);
    constraints = try wlr.PointerConstraintsV1.create(server.wl_server);
    constraints.events.new_constraint.add(&new_constraint);
    gestures = try wlr.PointerGesturesV1.create(server.wl_server);
    (try wlr.CursorShapeManagerV1.create(server.wl_server, 1)).events.request_set_shape.add(&request_shape);

    server.backend.events.new_input.add(&new_input);
    server.seat.events.request_set_cursor.add(&request_cursor);
    server.seat.events.request_set_selection.add(&request_selection);
    server.seat.events.request_set_primary_selection.add(&request_primary_selection);
    server.seat.events.request_start_drag.add(&request_start_drag);
    server.seat.events.start_drag.add(&start_drag);

    drag_icon_destroy.link.init();
    group = try wlr.KeyboardGroup.create();
    try setKeymap(&group.keyboard);
    try group_keyboard.init(&group.keyboard);
    server.seat.setKeyboard(&group.keyboard);

    (try wlr.VirtualKeyboardManagerV1.create(server.wl_server)).events.new_virtual_keyboard.add(&new_virtual_keyboard);
    (try wlr.VirtualPointerManagerV1.create(server.wl_server)).events.new_virtual_pointer.add(&new_virtual_pointer);
    server.seat.setCapabilities(.{ .pointer = true, .keyboard = true });
}

pub fn deinit() void {
    inline for (.{
        &new_input,         &motion,               &motion_absolute,           &button,            &axis,
        &frame,             &swipe_begin,          &swipe_update,              &swipe_end,         &pinch_begin,
        &pinch_update,      &pinch_end,            &hold_begin,                &hold_end,          &request_cursor,
        &request_selection, &request_start_drag,   &request_primary_selection, &start_drag,        &request_shape,
        &new_constraint,    &new_virtual_keyboard, &new_virtual_pointer,       &drag_icon_destroy,
    }) |l| l.link.remove();
    group_keyboard.key.link.remove();
    group_keyboard.modifiers.link.remove();
    group_keyboard.repeat_source.remove();
    group.destroy();
    xcursor.destroy();
}

pub fn loadCursorScale(scale: f32) void {
    xcursor.load(scale) catch {};
}

pub fn updateCursor() void {
    server.cursor.setXcursor(xcursor, "default");
}

pub fn setXwaylandCursor(x: *wlr.Xwayland) void {
    const xc = xcursor.getXcursor("default", 1) orelse return;
    const img = xc.images[0];
    x.setCursor(img.getBuffer(), @intCast(img.hotspot_x), @intCast(img.hotspot_y));
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

fn setKeymap(kb: *wlr.Keyboard) !void {
    const context = xkb.Context.new(.no_flags) orelse return error.XkbContext;
    defer context.unref();
    const keymap = xkb.Keymap.newFromNames(context, &config.xkb_rules, .no_flags) orelse return error.XkbKeymap;
    defer keymap.unref();
    _ = kb.setKeymap(keymap);
    kb.setRepeatInfo(config.repeat_rate, config.repeat_delay);
}

/// Physical keyboards share one group; virtual keyboards keep their own keymap.
const Keyboard = struct {
    kb: *wlr.Keyboard,
    syms: [2]xkb.Keysym = .{ .NoSymbol, .NoSymbol },
    mods: u32 = 0,
    /// The key a bar mode got, so holding it repeats there instead.
    menu_sym: ?xkb.Keysym = null,
    repeat_source: *wl.EventSource,
    key: wl.Listener(*wlr.Keyboard.event.Key) = .init(onKey),
    modifiers: wl.Listener(*wlr.Keyboard) = .init(onModifiers),
    destroy: wl.Listener(*wlr.InputDevice) = .init(onDestroy),

    fn init(k: *Keyboard, kb: *wlr.Keyboard) !void {
        k.* = .{
            .kb = kb,
            .repeat_source = try server.wl_server.getEventLoop().addTimer(*Keyboard, repeat, k),
        };
        kb.events.key.add(&k.key);
        kb.events.modifiers.add(&k.modifiers);
    }

    fn onDestroy(listener: *wl.Listener(*wlr.InputDevice), _: *wlr.InputDevice) void {
        const k: *Keyboard = @fieldParentPtr("destroy", listener);
        k.key.link.remove();
        k.modifiers.link.remove();
        k.destroy.link.remove();
        k.repeat_source.remove();
        gpa.destroy(k);
    }

    fn binding(k: *Keyboard) ?*const actions.Key {
        for (k.syms) |sym| {
            for (&config.keys) |*key| {
                if (locked and !key.locked) continue;
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
        lock.activity();

        k.menu_sym = null;
        if (event.state == .pressed and !locked and menu.active()) {
            const sym = k.kb.xkb_state.?.keyGetOneSym(keycode);
            k.menu_sym = sym;
            consumed.set(event.keycode);
            menu.key(k.mods, sym);
            k.repeat_source.timerUpdate(@max(k.kb.repeat_info.delay, 0)) catch {};
            return;
        }

        var handled = false;
        if (event.state == .pressed) {
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
        if (k.menu_sym) |sym| {
            if (menu.active()) menu.key(k.mods, sym);
        } else if (k.binding()) |key| key.func(&key.arg);
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

fn onNewVirtualKeyboard(_: *wl.Listener(*wlr.VirtualKeyboardV1), vkb: *wlr.VirtualKeyboardV1) void {
    const k = gpa.create(Keyboard) catch return;
    k.init(&vkb.keyboard) catch {
        gpa.destroy(k);
        return;
    };
    vkb.keyboard.base.events.destroy.add(&k.destroy);
}

fn onNewVirtualPointer(_: *wl.Listener(*wlr.VirtualPointerManagerV1.event.NewPointer), event: *wlr.VirtualPointerManagerV1.event.NewPointer) void {
    const device = &event.new_pointer.pointer.base;
    server.cursor.attachInputDevice(device);
    if (event.suggested_output) |output| server.cursor.mapInputToOutput(device, output);
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
pub fn motionNotify(time: u32, device: ?*wlr.InputDevice, dx_in: f64, dy_in: f64, dx_unaccel: f64, dy_unaccel: f64) void {
    const cursor = server.cursor;
    var dx = dx_in;
    var dy = dy_in;
    if (time != 0) {
        lock.activity();
        relative_pointer.sendRelativeMotion(server.seat, @as(u64, time) * 1000, dx, dy, dx_unaccel, dy_unaccel);
        if (constrain(&dx, &dy)) return;
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
    if (config.sloppyfocus and time != 0 and cl != null and !cl.?.unmanaged() and s != server.seat.pointer_state.focused_surface)
        server.focus(cl, false);
    const surf = s orelse {
        server.seat.pointerNotifyClearFocus();
        return;
    };
    server.seat.pointerNotifyEnter(surf, sx, sy);
    server.seat.pointerNotifyMotion(if (time != 0) time else now(), sx, sy);
}

fn onButton(_: *wl.Listener(*wlr.Pointer.event.Button), event: *wlr.Pointer.event.Button) void {
    lock.activity();
    switch (event.state) {
        .pressed => {
            cursor_mode = .pressed;
            server.selmon = monAt(server.cursor.x, server.cursor.y) orelse server.selmon;
            if (locked) {} else {
                const hit = server.hitTest(server.cursor.x, server.cursor.y);
                if (hit.client) |cl| {
                    if (cl.unmanaged()) {
                        keyboardEnter(cl.surface());
                    } else {
                        server.focus(cl, true);
                        if (cl.tiled()) scroll.reveal(cl);
                    }
                } else if (hit.layer) |l| {
                    if (l.layer_surface.current.keyboard_interactive != .none) keyboardEnter(l.layer_surface.surface);
                }
                var tag: u32 = 0;
                const click: Bar.Click = if (hit.bar) |m| Bar.clickAt(m, server.cursor.x, &tag) else if (hit.client != null) .client else .root;
                const mods = clean(modifiers());
                for (&config.buttons) |*b| {
                    if (mods == clean(b.mod) and event.button == b.button and click == b.click) {
                        // Tag bar buttons without their own argument act on the clicked tag.
                        b.func(if (click == .tagbar and b.arg.ui == 0) &.{ .ui = tag } else &b.arg);
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
    lock.activity();
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

fn onRequestPrimarySelection(_: *wl.Listener(*wlr.Seat.event.RequestSetPrimarySelection), event: *wlr.Seat.event.RequestSetPrimarySelection) void {
    server.seat.setPrimarySelection(event.source, event.serial);
}

fn onRequestShape(_: *wl.Listener(*wlr.CursorShapeManagerV1.event.RequestSetShape), event: *wlr.CursorShapeManagerV1.event.RequestSetShape) void {
    if (cursor_mode != .normal and cursor_mode != .pressed) return;
    if (event.seat_client == server.seat.pointer_state.focused_client)
        server.cursor.setXcursor(xcursor, wlr.CursorShapeManagerV1.shapeName(event.shape));
}

/// Apply the focused surface's pointer constraint to a motion. Returns true
/// when the pointer is locked and must not move.
fn constrain(dx: *f64, dy: *f64) bool {
    const focused = server.seat.pointer_state.focused_surface;
    const want = if (focused) |f| constraints.constraintForSurface(f, server.seat) else null;
    if (want != active_constraint) {
        if (active_constraint) |old| old.sendDeactivated();
        active_constraint = want;
        if (want) |w| w.sendActivated();
    }
    const con = active_constraint orelse return false;
    if (cursor_mode == .move or cursor_mode == .resize) return false;
    const cl = Client.fromSurface(con.surface) orelse return false;
    const sx = server.cursor.x - @as(f64, @floatFromInt(cl.geom.x + cl.bw));
    const sy = server.cursor.y - @as(f64, @floatFromInt(cl.geom.y + cl.bw));
    var cx: f64 = undefined;
    var cy: f64 = undefined;
    if (wlr.region.confine(&con.region, sx, sy, sx + dx.*, sy + dy.*, &cx, &cy)) {
        dx.* = cx - sx;
        dy.* = cy - sy;
    }
    return con.type == .locked;
}

const Constraint = struct {
    destroy: wl.Listener(*wlr.PointerConstraintV1) = .init(onDestroy),

    fn onDestroy(listener: *wl.Listener(*wlr.PointerConstraintV1), con: *wlr.PointerConstraintV1) void {
        const self: *Constraint = @fieldParentPtr("destroy", listener);
        if (active_constraint == con) {
            active_constraint = null;
            // Put the cursor where the client last asked, for locked pointers.
            if (con.current.cursor_hint.enabled) if (Client.fromSurface(con.surface)) |cl| {
                const hx = con.current.cursor_hint.x;
                const hy = con.current.cursor_hint.y;
                _ = server.cursor.warp(null, hx + @as(f64, @floatFromInt(cl.geom.x + cl.bw)), hy + @as(f64, @floatFromInt(cl.geom.y + cl.bw)));
                server.seat.pointerWarp(hx, hy);
            };
        }
        self.destroy.link.remove();
        gpa.destroy(self);
    }
};

fn onNewConstraint(_: *wl.Listener(*wlr.PointerConstraintV1), con: *wlr.PointerConstraintV1) void {
    const self = gpa.create(Constraint) catch return;
    self.* = .{};
    con.events.destroy.add(&self.destroy);
    motionNotify(0, null, 0, 0, 0, 0);
}

fn onSwipeBegin(_: *wl.Listener(*wlr.Pointer.event.SwipeBegin), event: *wlr.Pointer.event.SwipeBegin) void {
    lock.activity();
    gestures.sendSwipeBegin(server.seat, event.time_msec, event.fingers);
}

fn onSwipeUpdate(_: *wl.Listener(*wlr.Pointer.event.SwipeUpdate), event: *wlr.Pointer.event.SwipeUpdate) void {
    lock.activity();
    gestures.sendSwipeUpdate(server.seat, event.time_msec, event.dx, event.dy);
}

fn onSwipeEnd(_: *wl.Listener(*wlr.Pointer.event.SwipeEnd), event: *wlr.Pointer.event.SwipeEnd) void {
    gestures.sendSwipeEnd(server.seat, event.time_msec, event.cancelled);
}

fn onPinchBegin(_: *wl.Listener(*wlr.Pointer.event.PinchBegin), event: *wlr.Pointer.event.PinchBegin) void {
    lock.activity();
    gestures.sendPinchBegin(server.seat, event.time_msec, event.fingers);
}

fn onPinchUpdate(_: *wl.Listener(*wlr.Pointer.event.PinchUpdate), event: *wlr.Pointer.event.PinchUpdate) void {
    lock.activity();
    gestures.sendPinchUpdate(server.seat, event.time_msec, event.dx, event.dy, event.scale, event.rotation);
}

fn onPinchEnd(_: *wl.Listener(*wlr.Pointer.event.PinchEnd), event: *wlr.Pointer.event.PinchEnd) void {
    gestures.sendPinchEnd(server.seat, event.time_msec, event.cancelled);
}

fn onHoldBegin(_: *wl.Listener(*wlr.Pointer.event.HoldBegin), event: *wlr.Pointer.event.HoldBegin) void {
    lock.activity();
    gestures.sendHoldBegin(server.seat, event.time_msec, event.fingers);
}

fn onHoldEnd(_: *wl.Listener(*wlr.Pointer.event.HoldEnd), event: *wlr.Pointer.event.HoldEnd) void {
    gestures.sendHoldEnd(server.seat, event.time_msec, event.cancelled);
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
    if (cl.fullscreen or cl.unmanaged()) return;
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
