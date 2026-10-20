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

pub const tags = [_][]const u8{ "1", "2", "3", "4", "5", "6", "7", "8", "9", "10" };

pub const layouts = [_]a.Layout{
    .{ .symbol = "[S]", .arrange = scroll.arrange },
    .{ .symbol = "><>", .arrange = null },
    .{ .symbol = "[M]", .arrange = scroll.monocle },
};

pub const monrules = [_]a.MonitorRule{
    .{},
};

pub const rules = [_]a.Rule{};

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

pub const keys = [_]a.Key{
    .{ .mod = MOD, .sym = K.t, .func = a.spawn, .arg = a.cmd(&.{"foot"}) },
    .{ .mod = MOD, .sym = K.q, .func = a.killclient },
    .{ .mod = ALT, .sym = K.Tab, .func = a.focusstack, .arg = .{ .i = 1 } },
    .{ .mod = ALT | SHIFT, .sym = K.Tab, .func = a.focusstack, .arg = .{ .i = -1 } },
    .{ .mod = CTRL | ALT, .sym = K.BackSpace, .func = a.quit },
};

pub const buttons = [_]a.Button{
    .{ .mod = MOD, .button = c.BTN_LEFT, .func = a.moveresize, .arg = .{ .ui = 0 } },
    .{ .mod = MOD, .button = c.BTN_RIGHT, .func = a.moveresize, .arg = .{ .ui = 1 } },
};
