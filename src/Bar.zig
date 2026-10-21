//! dwm-style bar drawn with fcft and pixman
//! text drawing follows drwl (https://codeberg.org/sewn/drwl, MIT, Copyright (c) 2023-2025 sewn)
const Bar = @This();

const std = @import("std");
const wl = @import("wayland").server.wl;
const wlr = @import("wlroots");
const c = @import("c");

const config = @import("config.zig");
const actions = @import("actions.zig");
const menu = @import("menu.zig");
const server = &@import("main.zig").server;
const Monitor = @import("Monitor.zig");
const Server = @import("Server.zig");

const gpa = std.heap.c_allocator;

pub const Click = enum { tagbar, ltsymbol, status, title, client, root };

scene: *wlr.SceneBuffer,
owner: Server.Owner,
font: ?*c.struct_fcft_font = null,
scale: f32 = 0,
shown: bool = config.showbar,
/// height in layout coordinates, which windows make room for
height: i32 = 0,
/// digest of what the current buffer shows
drawn: u64 = 0,

var status_buf: [512]u8 = undefined;
var status_len: usize = 0;
var pending_buf: [512]u8 = undefined;
var pending_len: usize = 0;
var status_pid: c.pid_t = 0;
var status_source: ?*wl.EventSource = null;
var idle: ?*wl.EventSource = null;

pub fn init(b: *Bar, m: *Monitor) !void {
    b.* = .{
        .scene = try server.layers.get(.bottom).createSceneBuffer(null),
        .owner = .{ .bar = m },
    };
    b.scene.node.data = &b.owner;
    b.loadFont(m.output.scale);
}

pub fn deinit(b: *Bar) void {
    b.scene.node.destroy();
    if (b.font) |f| c.fcft_destroy(f);
}

fn loadFont(b: *Bar, scale: f32) void {
    if (b.font != null and b.scale == scale) return;
    if (b.font) |f| c.fcft_destroy(f);
    var attrs: [32:0]u8 = undefined;
    _ = std.fmt.bufPrintSentinel(&attrs, "dpi={d:.2}", .{96 * scale}, 0) catch unreachable;
    var names: [config.fonts.len][*c]const u8 = undefined;
    for (config.fonts, 0..) |f, i| names[i] = f;
    b.font = c.fcft_from_name(names.len, &names, &attrs);
    b.scale = scale;
    b.drawn = 0;
}

/// room the bar takes at the top of the monitor, in layout coordinates
pub fn reserved(m: *Monitor) i32 {
    const b = &m.bar;
    if (!b.shown) return 0;
    b.loadFont(m.output.scale);
    const f = b.font orelse return 0;
    b.height = @intFromFloat(@ceil(@as(f32, @floatFromInt(f.height + 2)) / b.scale));
    return b.height;
}

/// redraw every bar once the current batch of events is handled
pub fn redraw() void {
    if (idle != null) return;
    idle = server.wl_server.getEventLoop().addIdle(?*anyopaque, drawAll, null) catch null;
}

fn drawAll(_: ?*anyopaque) void {
    idle = null;
    var it = server.monitors.iterator(.forward);
    while (it.next()) |m| draw(m);
}

pub const Scheme = struct { fg: u32, bg: u32 };

fn pixmanColor(rgba: u32) c.pixman_color_t {
    const a: u32 = rgba & 0xff;
    return .{
        .red = @intCast(((rgba >> 24) & 0xff) * 0x101 * a / 0xff),
        .green = @intCast(((rgba >> 16) & 0xff) * 0x101 * a / 0xff),
        .blue = @intCast(((rgba >> 8) & 0xff) * 0x101 * a / 0xff),
        .alpha = @intCast(a * 0x101),
    };
}

pub const Painter = struct {
    img: *c.pixman_image_t,
    font: *c.struct_fcft_font,
    scheme: Scheme,
    height: i32,

    pub fn pad(p: *const Painter) i32 {
        return p.font.height;
    }

    pub fn rect(p: *const Painter, x: i32, y: i32, w: i32, h: i32, filled: bool, invert: bool) void {
        if (w <= 0 or h <= 0) return;
        var color = pixmanColor(if (invert) p.scheme.bg else p.scheme.fg);
        if (filled) {
            const box: c.pixman_box32_t = .{ .x1 = x, .y1 = y, .x2 = x + w, .y2 = y + h };
            _ = c.pixman_image_fill_boxes(c.PIXMAN_OP_SRC, p.img, &color, 1, &box);
        } else {
            const boxes = [4]c.pixman_box32_t{
                .{ .x1 = x, .y1 = y, .x2 = x + w, .y2 = y + 1 },
                .{ .x1 = x, .y1 = y + h - 1, .x2 = x + w, .y2 = y + h },
                .{ .x1 = x, .y1 = y, .x2 = x + 1, .y2 = y + h },
                .{ .x1 = x + w - 1, .y1 = y, .x2 = x + w, .y2 = y + h },
            };
            _ = c.pixman_image_fill_boxes(c.PIXMAN_OP_SRC, p.img, &color, 4, &boxes);
        }
    }

    fn glyph(p: *const Painter, cp: u32) ?*const c.struct_fcft_glyph {
        return c.fcft_rasterize_char_utf32(p.font, cp, c.FCFT_SUBPIXEL_DEFAULT);
    }

    pub fn textWidth(p: *const Painter, s: []const u8) i32 {
        var w: i32 = 0;
        var it = codepoints(s);
        while (it.next()) |cp| if (p.glyph(cp)) |g| {
            w += g.advance.x;
        };
        return w;
    }

    /// width of s plus padding, like dwm's TEXTW
    pub fn textw(p: *const Painter, s: []const u8) i32 {
        return p.textWidth(s) + p.pad();
    }

    /// fill a box and draw s in it, ellipsized if too long; returns where the box ends
    pub fn text(p: *const Painter, x0: i32, w0: i32, lpad: i32, s: []const u8, invert: bool) i32 {
        if (w0 <= 0) return x0;
        p.rect(x0, 0, w0, p.height, true, !invert);
        var fg = pixmanColor(if (invert) p.scheme.bg else p.scheme.fg);
        const fill = c.pixman_image_create_solid_fill(&fg) orelse return x0 + w0;
        defer _ = c.pixman_image_unref(fill);

        var x = x0 + lpad;
        var w = w0 - lpad;
        const baseline = @divTrunc(p.height - p.font.height, 2) + p.font.ascent;
        const ellipsis = p.glyph(0x2026);
        const full = p.textWidth(s) <= w;
        var it = codepoints(s);
        while (it.next()) |cp| {
            const g = p.glyph(cp) orelse continue;
            const room = if (full or ellipsis == null) w else w - ellipsis.?.advance.x;
            if (g.advance.x > room) {
                if (!full) if (ellipsis) |e| p.blit(fill, e, x, baseline);
                break;
            }
            p.blit(fill, g, x, baseline);
            x += g.advance.x;
            w -= g.advance.x;
        }
        return x0 + w0;
    }

    fn blit(p: *const Painter, fill: *c.pixman_image_t, g: *const c.struct_fcft_glyph, x: i32, baseline: i32) void {
        if (g.is_color_glyph) {
            c.pixman_image_composite32(c.PIXMAN_OP_OVER, g.pix, null, p.img, 0, 0, 0, 0, x + g.x, baseline - g.y, g.width, g.height);
        } else {
            c.pixman_image_composite32(c.PIXMAN_OP_OVER, fill, g.pix, p.img, 0, 0, 0, 0, x + g.x, baseline - g.y, g.width, g.height);
        }
    }
};

const Codepoints = struct {
    bytes: []const u8,
    i: usize = 0,

    fn next(it: *Codepoints) ?u32 {
        if (it.i >= it.bytes.len) return null;
        const len = std.unicode.utf8ByteSequenceLength(it.bytes[it.i]) catch {
            it.i += 1;
            return 0xfffd;
        };
        if (it.i + len > it.bytes.len) {
            it.i = it.bytes.len;
            return 0xfffd;
        }
        const cp = std.unicode.utf8Decode(it.bytes[it.i..][0..len]) catch 0xfffd;
        it.i += len;
        return cp;
    }
};

fn codepoints(s: []const u8) Codepoints {
    return .{ .bytes = s };
}

/// pixel memory the scene reads the bar from
const Buffer = struct {
    base: wlr.Buffer,
    data: []u32,
    stride: usize,

    const drm_format_argb8888 = 0x34325241;

    const impl: wlr.Buffer.Impl = .{
        .destroy = destroy,
        .get_dmabuf = null,
        .get_shm = null,
        .begin_data_ptr_access = beginAccess,
        .end_data_ptr_access = endAccess,
    };

    fn create(width: i32, height: i32) ?*Buffer {
        const buf = gpa.create(Buffer) catch return null;
        const n: usize = @intCast(width * height);
        buf.data = gpa.alloc(u32, n) catch {
            gpa.destroy(buf);
            return null;
        };
        buf.stride = @as(usize, @intCast(width)) * 4;
        buf.base.init(&impl, width, height);
        return buf;
    }

    fn destroy(base: *wlr.Buffer) callconv(.c) void {
        const buf: *Buffer = @fieldParentPtr("base", base);
        gpa.free(buf.data);
        gpa.destroy(buf);
    }

    fn beginAccess(base: *wlr.Buffer, _: u32, data: **anyopaque, format: *u32, stride: *usize) callconv(.c) bool {
        const buf: *Buffer = @fieldParentPtr("base", base);
        data.* = buf.data.ptr;
        format.* = drm_format_argb8888;
        stride.* = buf.stride;
        return true;
    }

    fn endAccess(_: *wlr.Buffer) callconv(.c) void {}
};

pub fn draw(m: *Monitor) void {
    const b = &m.bar;
    if (!b.shown or !m.output.enabled) {
        b.scene.node.setEnabled(false);
        return;
    }
    b.loadFont(m.output.scale);
    const font = b.font orelse return;
    const width = pixelWidth(m);
    const height: i32 = font.height + 2;
    if (width <= 0) return;
    b.scene.setDestSize(m.m.width, b.height);
    b.scene.node.setPosition(m.m.x, m.m.y);
    b.scene.node.setEnabled(true);

    // the menu isn't in the digest, so it draws every time while open
    const key = digest(m, width, height);
    if (key == b.drawn and !(m == server.selmon and menu.active())) return;

    const buf = Buffer.create(width, height) orelse return;
    const img = c.pixman_image_create_bits(c.PIXMAN_a8r8g8b8, width, height, buf.data.ptr, @intCast(buf.stride)) orelse {
        buf.base.drop();
        return;
    };
    var p: Painter = .{ .img = img, .font = font, .scheme = config.bar_norm, .height = height };
    paint(m, &p, width);
    _ = c.pixman_image_unref(img);

    b.scene.setBuffer(&buf.base);
    buf.base.drop();
    b.drawn = key;
}

/// width of the bar's buffer in pixels
fn pixelWidth(m: *const Monitor) i32 {
    return @intFromFloat(@ceil(@as(f32, @floatFromInt(m.m.width)) * m.bar.scale));
}

const TagState = struct { occupied: u32 = 0, urgent: u32 = 0 };

fn tagState(m: *const Monitor) TagState {
    var t: TagState = .{};
    var it = server.clients.iterator(.forward);
    while (it.next()) |cl| {
        if (cl.mon != m) continue;
        if (cl.tags != actions.tagmask()) t.occupied |= cl.tags;
        if (cl.urgent) t.urgent |= cl.tags;
    }
    return t;
}

/// hash of everything paint shows, so a redraw with nothing new is skipped
fn digest(m: *Monitor, width: i32, height: i32) u64 {
    const selected = m == server.selmon;
    const sel = server.focustop(m);
    const t = tagState(m);
    const nums = [_]u32{
        @bitCast(width),
        @bitCast(height),
        @intFromBool(selected),
        @intFromBool(selected and menu.active()),
        m.tags(),
        t.occupied,
        t.urgent,
        if (sel) |cl| cl.tags else 0,
        if (sel) |cl| @intFromBool(cl.floating) else 2,
    };
    var h: std.hash.Wyhash = .init(0);
    h.update(std.mem.sliceAsBytes(&nums));
    h.update(std.mem.sliceTo(&m.ltsymbol, 0));
    h.update(&[_]u8{0});
    if (selected) h.update(status());
    h.update(&[_]u8{0});
    if (sel) |cl| h.update(cl.title());
    return h.final();
}

fn paint(m: *Monitor, p: *Painter, width: i32) void {
    const selected = m == server.selmon;
    const boxs = @divTrunc(p.font.height, 9);
    const boxw = @divTrunc(p.font.height, 6) + 2;

    // status first, so tags can draw over it on a narrow monitor
    var tw: i32 = 0;
    if (selected) {
        p.scheme = config.bar_norm;
        tw = p.textWidth(status()) + 2;
        _ = p.text(width - tw, tw, 0, status(), false);
    }

    const t = tagState(m);
    const sel = server.focustop(m);
    var x: i32 = 0;
    for (config.tags, 0..) |tag, i| {
        const bit = @as(u32, 1) << @intCast(i);
        const w = p.textw(tag);
        p.scheme = if (m.tags() & bit != 0) config.bar_sel else config.bar_norm;
        _ = p.text(x, w, @divTrunc(p.pad(), 2), tag, t.urgent & bit != 0);
        if (t.occupied & bit != 0)
            p.rect(x + boxs, boxs, boxw, boxw, selected and sel != null and sel.?.tags & bit != 0, t.urgent & bit != 0);
        x += w;
    }

    p.scheme = config.bar_norm;
    const symbol = std.mem.sliceTo(&m.ltsymbol, 0);
    x = p.text(x, p.textw(symbol), @divTrunc(p.pad(), 2), symbol, false);

    if (selected and menu.draw(p, x, width)) return;

    const w = width - tw - x;
    if (w <= p.height) return;
    if (sel) |cl| {
        p.scheme = if (selected) config.bar_sel else config.bar_norm;
        _ = p.text(x, w, @divTrunc(p.pad(), 2), cl.title(), false);
        if (cl.floating) p.rect(x + boxs, boxs, boxw, boxw, false, false);
    } else {
        p.scheme = config.bar_norm;
        p.rect(x, 0, w, p.height, true, true);
    }
}

/// which part of the bar is at layout x
pub fn clickAt(m: *Monitor, lx: f64, tag: *u32) Click {
    const b = &m.bar;
    const font = b.font orelse return .root;
    const p: Painter = .{ .img = undefined, .font = font, .scheme = config.bar_norm, .height = font.height + 2 };
    const x: i32 = @intFromFloat((lx - @as(f64, @floatFromInt(m.m.x))) * b.scale);
    var end: i32 = 0;
    for (config.tags, 0..) |t, i| {
        end += p.textw(t);
        if (x < end) {
            tag.* = @as(u32, 1) << @intCast(i);
            return .tagbar;
        }
    }
    if (x < end + p.textw(std.mem.sliceTo(&m.ltsymbol, 0))) return .ltsymbol;
    if (m == server.selmon and x > pixelWidth(m) - (p.textWidth(status()) + 2)) return .status;
    return .title;
}

pub fn status() []const u8 {
    return if (status_len == 0) "aion" else status_buf[0..status_len];
}

/// status lines come from status_cmd's output, or stdin when there is none
pub fn startStatus() void {
    var fd: c_int = 0;
    if (config.status_cmd) |argv| {
        var fds: [2]c_int = undefined;
        if (c.pipe(&fds) != 0) return;
        const pid = c.fork();
        if (pid < 0) return;
        if (pid == 0) {
            _ = c.dup2(fds[1], 1);
            _ = c.close(fds[0]);
            _ = c.close(fds[1]);
            actions.resetChild();
            _ = c.execvp(argv.argv[0].?, @ptrCast(argv.argv));
            c._exit(127);
        }
        _ = c.close(fds[1]);
        _ = c.fcntl(fds[0], c.F_SETFD, c.FD_CLOEXEC);
        status_pid = pid;
        fd = fds[0];
    } else if (c.isatty(0) != 0) {
        return;
    }
    status_source = server.wl_server.getEventLoop().addFd(?*anyopaque, fd, .{ .readable = true }, onStatus, null) catch null;
}

pub fn stopStatus() void {
    if (status_source) |s| s.remove();
    status_source = null;
    if (status_pid > 0) {
        // the whole group so a sleeping status loop goes too, killed so the wait can't hang
        _ = c.kill(-status_pid, c.SIGKILL);
        _ = c.waitpid(status_pid, null, 0);
        status_pid = 0;
    }
}

fn onStatus(fd: c_int, _: wl.EventMask, _: ?*anyopaque) c_int {
    var chunk: [512]u8 = undefined;
    const n = c.read(fd, &chunk, chunk.len);
    if (n <= 0) {
        stopStatus();
        // a closed stdin would hand fd 0 to whatever opens next
        if (fd != 0) _ = c.close(fd);
        return 0;
    }
    var changed = false;
    for (chunk[0..@intCast(n)]) |ch| {
        if (ch == '\n') {
            @memcpy(status_buf[0..pending_len], pending_buf[0..pending_len]);
            status_len = pending_len;
            pending_len = 0;
            changed = true;
        } else if (pending_len < pending_buf.len) {
            pending_buf[pending_len] = ch;
            pending_len += 1;
        }
    }
    if (changed) redraw();
    return 0;
}
