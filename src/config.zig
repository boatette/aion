const wlr = @import("wlroots");
const xkb = @import("xkbcommon");
const c = @import("c");
const a = @import("actions.zig");
const menu = @import("menu.zig");

const K = xkb.Keysym;
const MOD = a.LOGO;
const SHIFT = a.SHIFT;
const CTRL = a.CTRL;
const ALT = a.ALT;

const gray1 = 0x222222ff;
const gray2 = 0x444444ff;
const gray3 = 0xbbbbbbff;
const gray4 = 0xeeeeeeff;
const cyan = 0x005577ff;
const red = 0xff0000ff;

pub const sloppyfocus = true;
/// windows asking for attention get focused (switching tag if needed) instead of marked urgent
pub const focus_on_activate = false;
pub const borderpx = 1;
pub const rootcolor = a.color(gray1);
pub const bordercolor = a.color(gray2);
pub const focuscolor = a.color(cyan);
pub const urgentcolor = a.color(red);
pub const fullscreen_bg = a.color(0x000000ff);

pub const showbar = true;
pub const fonts = [_][*:0]const u8{"monospace:size=10"};
pub const bar_norm: a.Scheme = .{ .fg = gray3, .bg = gray1 };
pub const bar_sel: a.Scheme = .{ .fg = gray4, .bg = cyan };
/// prints one status line at a time; null reads the status from stdin
pub const status_cmd: ?a.Arg = null;

/// apps_cmd prints "Name<TAB>path" lines for mod+d, and launch_cmd plus a path starts one
pub const apps_cmd = a.cmd(&.{
    "sh", "-c",
    \\IFS=:; for d in $PATH; do for f in "$d"/*; do
    \\[ -f "$f" ] && [ -x "$f" ] && printf '%s\t%s\n' "${f##*/}" "${f##*/}"
    \\done; done | sort -u
});
pub const launch_cmd = [_][:0]const u8{};

/// mod+x then one of these keys; any other key leaves the mode
pub const session_keys = [_]a.Key{
    .{ .mod = 0, .sym = K.l, .func = a.spawn, .arg = a.cmd(&.{ "loginctl", "lock-session" }) },
    .{ .mod = 0, .sym = K.u, .func = a.spawn, .arg = a.cmd(&.{ "systemctl", "suspend" }) },
    .{ .mod = 0, .sym = K.e, .func = a.quit },
    .{ .mod = 0, .sym = K.r, .func = a.spawn, .arg = a.cmd(&.{ "systemctl", "reboot" }) },
    .{ .mod = 0, .sym = K.s, .func = a.spawn, .arg = a.cmd(&.{ "systemctl", "poweroff" }) },
};
pub const session_hint = "l lock  u suspend  e logout  r reboot  s shutdown";

pub const default_width: f32 = 0.5;
/// size of a window first floated with mod+v, as a fraction of the monitor
pub const float_size = [2]f32{ 0.6, 0.6 };
pub const width_presets = [_]f32{ 1.0 / 3.0, 0.5, 2.0 / 3.0 };

pub const tags = [_][]const u8{ "1", "2", "3", "4", "5", "6", "7", "8", "9", "10" };

pub const monrules = [_]a.MonitorRule{
    .{},
};

/// app_id and title match as substrings; dialogs with a parent float on their own
pub const rules = [_]a.Rule{
    .{ .app_id = "xdg-desktop-portal-gtk", .floating = true },
    .{ .app_id = "org.gtk.FileChooserDialog", .floating = true },
    .{ .title = "Picture-in-Picture", .floating = true },
};

pub const xkb_rules: xkb.RuleNames = .{
    .rules = null,
    .model = null,
    .layout = "us",
    .variant = null,
    .options = null,
};
pub const repeat_rate = 25;
pub const repeat_delay = 600;

pub const tap_to_click = true;
pub const tap_and_drag = true;
pub const drag_lock = true;
pub const natural_scrolling = false;
pub const disable_while_typing = true;
pub const left_handed = false;
pub const middle_button_emulation = false;
pub const scroll_method = c.LIBINPUT_CONFIG_SCROLL_2FG;
pub const click_method = c.LIBINPUT_CONFIG_CLICK_METHOD_BUTTON_AREAS;
pub const send_events_mode = c.LIBINPUT_CONFIG_SEND_EVENTS_ENABLED;
pub const accel_profile = c.LIBINPUT_CONFIG_ACCEL_PROFILE_ADAPTIVE;
pub const accel_speed = 0.0;
pub const button_map = c.LIBINPUT_CONFIG_TAP_MAP_LRM;

const LEFT = @backingInt(wlr.OutputLayout.Direction.left);
const RIGHT = @backingInt(wlr.OutputLayout.Direction.right);
const UP = @backingInt(wlr.OutputLayout.Direction.up);
const DOWN = @backingInt(wlr.OutputLayout.Direction.down);

/// mod+n views tag n, +shift moves the window there and follows, +ctrl moves it quietly
fn tagkeys(comptime sym: xkb.Keysym, comptime i: u5) [3]a.Key {
    return .{
        .{ .mod = MOD, .sym = sym, .func = a.view, .arg = .{ .ui = 1 << i } },
        .{ .mod = MOD | SHIFT, .sym = sym, .func = a.tagfollow, .arg = .{ .ui = 1 << i } },
        .{ .mod = MOD | CTRL, .sym = sym, .func = a.tag, .arg = .{ .ui = 1 << i } },
    };
}

/// the same action on a vim key and its arrow
fn both(comptime mod: u32, comptime vim: xkb.Keysym, comptime arrow: xkb.Keysym, comptime func: a.Func, comptime arg: a.Arg) [2]a.Key {
    return .{
        .{ .mod = mod, .sym = vim, .func = func, .arg = arg },
        .{ .mod = mod, .sym = arrow, .func = func, .arg = arg },
    };
}

fn helper(comptime mod: u32, comptime sym: xkb.Keysym, comptime argv: []const [:0]const u8) a.Key {
    return .{ .mod = mod, .sym = sym, .func = a.spawn, .arg = a.cmd(argv), .locked = true };
}

fn chvt(comptime n: u32) a.Key {
    return .{ .mod = CTRL | ALT, .sym = @fromBackingInt(@intCast(@backingInt(K.F1) + n - 1)), .func = a.chvt, .arg = .{ .ui = n }, .locked = true };
}

pub const keys = [_]a.Key{
    .{ .mod = MOD, .sym = K.Return, .func = a.spawn, .arg = a.cmd(&.{"foot"}) },
    .{ .mod = MOD, .sym = K.d, .func = menu.launcher },
    .{ .mod = MOD, .sym = K.x, .func = menu.session },
    .{ .mod = ALT, .sym = K.Tab, .func = a.focusstack, .arg = .{ .i = 1 } },
    .{ .mod = ALT | SHIFT, .sym = K.Tab, .func = a.focusstack, .arg = .{ .i = -1 } },

    .{ .mod = MOD, .sym = K.g, .func = a.view, .arg = .{ .ui = ~@as(u32, 0) } },
    .{ .mod = MOD, .sym = K.q, .func = a.killclient },
    .{ .mod = MOD, .sym = K.b, .func = a.togglebar },
    .{ .mod = MOD | ALT, .sym = K.q, .func = a.forcekill },
    .{ .mod = MOD, .sym = K.v, .func = a.togglefloating },
    .{ .mod = MOD, .sym = K.p, .func = a.togglepin },

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

    .{ .mod = MOD | SHIFT, .sym = K.f, .func = a.togglefullscreen },
    .{ .mod = MOD | CTRL, .sym = K.f, .func = a.togglefullscreen },

    .{ .mod = MOD, .sym = K.Tab, .func = a.view, .arg = .{ .ui = 0 } },

    // these also work while locked
    helper(0, K.XF86AudioRaiseVolume, &.{ "wpctl", "set-volume", "-l", "1", "@DEFAULT_AUDIO_SINK@", "5%+" }),
    helper(0, K.XF86AudioLowerVolume, &.{ "wpctl", "set-volume", "@DEFAULT_AUDIO_SINK@", "5%-" }),
    helper(0, K.XF86AudioMute, &.{ "wpctl", "set-mute", "@DEFAULT_AUDIO_SINK@", "toggle" }),
    helper(0, K.XF86AudioMicMute, &.{ "wpctl", "set-mute", "@DEFAULT_AUDIO_SOURCE@", "toggle" }),
    helper(0, K.XF86MonBrightnessUp, &.{ "brightnessctl", "set", "5%+" }),
    helper(0, K.XF86MonBrightnessDown, &.{ "brightnessctl", "set", "5%-" }),

    .{ .mod = 0, .sym = K.Print, .func = a.spawn, .arg = a.cmd(&.{"grim"}) },
    .{ .mod = MOD | SHIFT, .sym = K.s, .func = a.spawn, .arg = a.cmd(&.{ "sh", "-c", "grim -g \"$(slurp)\"" }) },

    .{ .mod = CTRL | ALT, .sym = K.BackSpace, .func = a.quit },
} ++ both(MOD, K.h, K.Left, a.focusdir, .{ .ui = @backingInt(a.Dir.left) }) ++
    both(MOD, K.l, K.Right, a.focusdir, .{ .ui = @backingInt(a.Dir.right) }) ++
    both(MOD, K.k, K.Up, a.focusdir, .{ .ui = @backingInt(a.Dir.up) }) ++
    both(MOD, K.j, K.Down, a.focusdir, .{ .ui = @backingInt(a.Dir.down) }) ++
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

/// mod with a wheel: tags up and down, columns sideways; touchpads fire once per axis_step
pub const axes = [_]a.Axis{
    .{ .mod = MOD, .dir = .up, .func = a.viewrel, .arg = .{ .i = -1 } },
    .{ .mod = MOD, .dir = .down, .func = a.viewrel, .arg = .{ .i = 1 } },
    .{ .mod = MOD | SHIFT, .dir = .up, .func = a.tagrel, .arg = .{ .i = -1 } },
    .{ .mod = MOD | SHIFT, .dir = .down, .func = a.tagrel, .arg = .{ .i = 1 } },
    .{ .mod = MOD, .dir = .left, .func = a.focusdir, .arg = .{ .ui = @backingInt(a.Dir.left) } },
    .{ .mod = MOD, .dir = .right, .func = a.focusdir, .arg = .{ .ui = @backingInt(a.Dir.right) } },
    .{ .mod = MOD | CTRL, .dir = .left, .func = a.movecolumn, .arg = .{ .i = -1 } },
    .{ .mod = MOD | CTRL, .dir = .right, .func = a.movecolumn, .arg = .{ .i = 1 } },
};
pub const axis_step = 40.0;
/// sideways touchpad scrolling with this held moves the strip instead of running the axes above
pub const scroll_mod = MOD;

/// fingers that drag the strip sideways, or slide in the next (up) or previous (down) tag
pub const scroll_fingers = 3;
pub const swipe_speed = 1.0;
/// travel that views a slid-in tag on release, and that other swipes need per step
pub const swipe_threshold = 120.0;
pub const gestures = [_]a.Gesture{
    .{ .fingers = 4, .dir = .left, .func = a.movecolumn, .arg = .{ .i = -1 } },
    .{ .fingers = 4, .dir = .right, .func = a.movecolumn, .arg = .{ .i = 1 } },
    .{ .fingers = 4, .dir = .up, .func = a.tagrel, .arg = .{ .i = 1 } },
    .{ .fingers = 4, .dir = .down, .func = a.tagrel, .arg = .{ .i = -1 } },
};

pub const buttons = [_]a.Button{
    .{ .click = .title, .mod = 0, .button = c.BTN_MIDDLE, .func = a.centercolumn },
    .{ .click = .client, .mod = MOD, .button = c.BTN_LEFT, .func = a.moveresize, .arg = .{ .ui = 0 } },
    .{ .click = .client, .mod = MOD, .button = c.BTN_RIGHT, .func = a.moveresize, .arg = .{ .ui = 1 } },
    .{ .click = .client, .mod = MOD, .button = c.BTN_MIDDLE, .func = a.scrolldrag },
    .{ .click = .root, .mod = MOD, .button = c.BTN_MIDDLE, .func = a.scrolldrag },
    .{ .click = .tagbar, .mod = 0, .button = c.BTN_LEFT, .func = a.view },
    .{ .click = .tagbar, .mod = 0, .button = c.BTN_RIGHT, .func = a.toggleview },
    .{ .click = .tagbar, .mod = MOD, .button = c.BTN_LEFT, .func = a.tag },
    .{ .click = .tagbar, .mod = MOD, .button = c.BTN_RIGHT, .func = a.toggletag },
};
