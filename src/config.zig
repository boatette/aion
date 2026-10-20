const wlr = @import("wlroots");
const xkb = @import("xkbcommon");
const c = @import("c");
const a = @import("actions.zig");
const scroll = @import("scroll.zig");

const K = xkb.Keysym;
const MOD = a.LOGO;
const SHIFT = a.SHIFT;
const CTRL = a.CTRL;
const ALT = a.ALT;

// Rosé Pine
const base = 0x191724ff;
const overlay = 0x26233aff;
const muted = 0x6e6a86ff;
const subtle = 0x908caaff;
const text = 0xe0def4ff;
const love = 0xeb6f92ff;
const rose = 0xebbcbaff;

pub const sloppyfocus = true;
pub const borderpx = 1;
pub const rootcolor = a.color(base);
pub const bordercolor = a.color(muted);
pub const focuscolor = a.color(rose);
pub const urgentcolor = a.color(love);
pub const fullscreen_bg = a.color(0x000000ff);

pub const default_width: f32 = 0.5;
pub const width_presets = [_]f32{ 1.0 / 3.0, 0.5, 2.0 / 3.0 };

pub const tags = [_][]const u8{ "1", "2", "3", "4", "5", "6", "7", "8", "9", "10" };

pub const layouts = [_]a.Layout{
    .{ .symbol = "[S]", .arrange = scroll.arrange },
    .{ .symbol = "><>", .arrange = null },
    .{ .symbol = "[M]", .arrange = scroll.monocle },
};

pub const monrules = [_]a.MonitorRule{
    .{},
};

/// app_id and title match as substrings. Dialogs with a parent float on their own.
pub const rules = [_]a.Rule{
    .{ .app_id = "xdg-desktop-portal-gtk", .floating = true },
    .{ .app_id = "org.gtk.FileChooserDialog", .floating = true },
    .{ .title = "Sign in - Google Accounts", .floating = true },
    .{ .title = "Picture-in-Picture", .floating = true },
    .{ .app_id = "io.bassi.Amberol", .floating = true },
    .{ .app_id = "qimgv", .title = "dvp.webp", .tags = ~@as(u32, 0), .floating = true },
};

pub const xkb_rules: xkb.RuleNames = .{
    .rules = null,
    .model = null,
    .layout = "us",
    .variant = null,
    .options = "caps:super",
};
pub const repeat_rate = 35;
pub const repeat_delay = 200;

pub const tap_to_click = true;
pub const tap_and_drag = true;
pub const drag_lock = true;
pub const natural_scrolling = true;
pub const disable_while_typing = true;
pub const left_handed = false;
pub const middle_button_emulation = false;
pub const scroll_method = c.LIBINPUT_CONFIG_SCROLL_2FG;
pub const click_method = c.LIBINPUT_CONFIG_CLICK_METHOD_BUTTON_AREAS;
pub const send_events_mode = c.LIBINPUT_CONFIG_SEND_EVENTS_ENABLED;
pub const accel_profile = c.LIBINPUT_CONFIG_ACCEL_PROFILE_ADAPTIVE;
pub const accel_speed = 0.0;
pub const button_map = c.LIBINPUT_CONFIG_TAP_MAP_LRM;

const LEFT = @intFromEnum(wlr.OutputLayout.Direction.left);
const RIGHT = @intFromEnum(wlr.OutputLayout.Direction.right);
const UP = @intFromEnum(wlr.OutputLayout.Direction.up);
const DOWN = @intFromEnum(wlr.OutputLayout.Direction.down);

/// Mod+N views tag N, Mod+Shift+N moves the window there and follows, Mod+Ctrl+N moves it quietly.
fn tagkeys(comptime sym: xkb.Keysym, comptime i: u5) [3]a.Key {
    return .{
        .{ .mod = MOD, .sym = sym, .func = a.view, .arg = .{ .ui = 1 << i } },
        .{ .mod = MOD | SHIFT, .sym = sym, .func = a.tagfollow, .arg = .{ .ui = 1 << i } },
        .{ .mod = MOD | CTRL, .sym = sym, .func = a.tag, .arg = .{ .ui = 1 << i } },
    };
}

/// The same action on a vim key and its arrow.
fn both(comptime mod: u32, comptime vim: xkb.Keysym, comptime arrow: xkb.Keysym, comptime func: a.Func, comptime arg: a.Arg) [2]a.Key {
    return .{
        .{ .mod = mod, .sym = vim, .func = func, .arg = arg },
        .{ .mod = mod, .sym = arrow, .func = func, .arg = arg },
    };
}

fn chvt(comptime n: u32) a.Key {
    return .{ .mod = CTRL | ALT, .sym = @enumFromInt(@intFromEnum(K.F1) + n - 1), .func = a.chvt, .arg = .{ .ui = n } };
}

pub const keys = [_]a.Key{
    .{ .mod = MOD, .sym = K.t, .func = a.spawn, .arg = a.cmd(&.{"foot"}) },
    .{ .mod = MOD, .sym = K.w, .func = a.spawn, .arg = a.cmd(&.{"qutebrowser"}) },
    .{ .mod = MOD, .sym = K.e, .func = a.spawn, .arg = a.cmd(&.{"dolphin"}) },
    .{ .mod = MOD | ALT, .sym = K.e, .func = a.spawn, .arg = a.cmd(&.{ "foot", "zsh", "-ic", "y; exec zsh" }) },
    .{ .mod = CTRL | SHIFT, .sym = K.Escape, .func = a.spawn, .arg = a.cmd(&.{ "foot", "-e", "btop" }) },
    .{ .mod = ALT, .sym = K.Tab, .func = a.focusstack, .arg = .{ .i = 1 } },
    .{ .mod = ALT | SHIFT, .sym = K.Tab, .func = a.focusstack, .arg = .{ .i = -1 } },

    .{ .mod = MOD, .sym = K.g, .func = a.view, .arg = .{ .ui = ~@as(u32, 0) } },
    .{ .mod = MOD, .sym = K.q, .func = a.killclient },
    .{ .mod = MOD | ALT, .sym = K.q, .func = a.forcekill },
    .{ .mod = MOD, .sym = K.v, .func = a.togglefloating },
    .{ .mod = MOD, .sym = K.p, .func = a.tag, .arg = .{ .ui = ~@as(u32, 0) } },

    .{ .mod = MOD, .sym = K.c, .func = a.centercolumn },
    .{ .mod = MOD, .sym = K.f, .func = a.togglefullwidth },
    .{ .mod = MOD, .sym = K.r, .func = a.cyclewidth, .arg = .{ .i = 1 } },
    .{ .mod = MOD | SHIFT, .sym = K.r, .func = a.cyclewidth, .arg = .{ .i = -1 } },
    .{ .mod = MOD, .sym = K.minus, .func = a.setwidth, .arg = .{ .f = -0.05 } },
    .{ .mod = MOD, .sym = K.equal, .func = a.setwidth, .arg = .{ .f = 0.05 } },
    .{ .mod = MOD | SHIFT, .sym = K.minus, .func = a.setheight, .arg = .{ .f = -0.1 } },
    .{ .mod = MOD | SHIFT, .sym = K.equal, .func = a.setheight, .arg = .{ .f = 0.1 } },
    .{ .mod = MOD, .sym = K.bracketleft, .func = a.consumeorexpel, .arg = .{ .i = -1 } },
    .{ .mod = MOD, .sym = K.bracketright, .func = a.consumeorexpel, .arg = .{ .i = 1 } },
    .{ .mod = MOD, .sym = K.Home, .func = a.focusend, .arg = .{ .i = -1 } },
    .{ .mod = MOD, .sym = K.End, .func = a.focusend, .arg = .{ .i = 1 } },
    .{ .mod = MOD | SHIFT, .sym = K.Home, .func = a.movecolumnend, .arg = .{ .i = -1 } },
    .{ .mod = MOD | SHIFT, .sym = K.End, .func = a.movecolumnend, .arg = .{ .i = 1 } },

    .{ .mod = MOD, .sym = K.a, .func = a.setlayout, .arg = .{ .v = &layouts[2] } },
    .{ .mod = MOD | SHIFT, .sym = K.f, .func = a.togglefullscreen },
    .{ .mod = MOD | CTRL, .sym = K.f, .func = a.togglefullscreen },
    .{ .mod = MOD, .sym = K.o, .func = a.setlayout, .arg = .{ .v = null } },
    .{ .mod = MOD | SHIFT, .sym = K.o, .func = a.setlayout, .arg = .{ .v = &layouts[1] } },
    .{ .mod = MOD | CTRL, .sym = K.o, .func = a.setlayout, .arg = .{ .v = &layouts[0] } },

    .{ .mod = MOD, .sym = K.Tab, .func = a.view, .arg = .{ .ui = 0 } },
    .{ .mod = CTRL | ALT, .sym = K.BackSpace, .func = a.quit },
} ++ both(MOD, K.h, K.Left, a.focusdir, .{ .ui = 0 }) ++
    both(MOD, K.l, K.Right, a.focusdir, .{ .ui = 1 }) ++
    both(MOD, K.k, K.Up, a.focusdir, .{ .ui = 2 }) ++
    both(MOD, K.j, K.Down, a.focusdir, .{ .ui = 3 }) ++
    both(MOD | SHIFT, K.h, K.Left, a.movecolumn, .{ .i = -1 }) ++
    both(MOD | SHIFT, K.l, K.Right, a.movecolumn, .{ .i = 1 }) ++
    both(MOD | SHIFT, K.k, K.Up, a.movewindow, .{ .i = -1 }) ++
    both(MOD | SHIFT, K.j, K.Down, a.movewindow, .{ .i = 1 }) ++
    both(MOD | CTRL, K.h, K.Left, a.focusmon, .{ .i = LEFT }) ++
    both(MOD | CTRL, K.l, K.Right, a.focusmon, .{ .i = RIGHT }) ++
    both(MOD | CTRL, K.k, K.Up, a.focusmon, .{ .i = UP }) ++
    both(MOD | CTRL, K.j, K.Down, a.focusmon, .{ .i = DOWN }) ++
    both(MOD | SHIFT | CTRL, K.h, K.Left, a.tagmon, .{ .i = LEFT }) ++
    both(MOD | SHIFT | CTRL, K.l, K.Right, a.tagmon, .{ .i = RIGHT }) ++
    both(MOD | SHIFT | CTRL, K.k, K.Up, a.tagmon, .{ .i = UP }) ++
    both(MOD | SHIFT | CTRL, K.j, K.Down, a.tagmon, .{ .i = DOWN }) ++
    tagkeys(K.@"1", 0) ++ tagkeys(K.@"2", 1) ++ tagkeys(K.@"3", 2) ++ tagkeys(K.@"4", 3) ++ tagkeys(K.@"5", 4) ++
    tagkeys(K.@"6", 5) ++ tagkeys(K.@"7", 6) ++ tagkeys(K.@"8", 7) ++ tagkeys(K.@"9", 8) ++ tagkeys(K.@"0", 9) ++
    [_]a.Key{ chvt(1), chvt(2), chvt(3), chvt(4), chvt(5), chvt(6), chvt(7), chvt(8), chvt(9), chvt(10), chvt(11), chvt(12) };

pub const buttons = [_]a.Button{
    .{ .mod = MOD, .button = c.BTN_LEFT, .func = a.moveresize, .arg = .{ .ui = 0 } },
    .{ .mod = MOD, .button = c.BTN_RIGHT, .func = a.moveresize, .arg = .{ .ui = 1 } },
};
