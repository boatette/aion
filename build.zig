const std = @import("std");
const Build = std.Build;

const manifest = @import("build.zig.zon");

const Scanner = @import("wayland").Scanner;

const system_protocols = [_][]const u8{
    "stable/viewporter/viewporter.xml",
    "stable/xdg-shell/xdg-shell.xml",
    "staging/cursor-shape/cursor-shape-v1.xml",
    "staging/ext-data-control/ext-data-control-v1.xml",
    "staging/ext-idle-notify/ext-idle-notify-v1.xml",
    "staging/ext-image-capture-source/ext-image-capture-source-v1.xml",
    "staging/ext-image-copy-capture/ext-image-copy-capture-v1.xml",
    "staging/ext-session-lock/ext-session-lock-v1.xml",
    "staging/fractional-scale/fractional-scale-v1.xml",
    "staging/linux-drm-syncobj/linux-drm-syncobj-v1.xml",
    "staging/single-pixel-buffer/single-pixel-buffer-v1.xml",
    "staging/xdg-activation/xdg-activation-v1.xml",
    "unstable/idle-inhibit/idle-inhibit-unstable-v1.xml",
    "unstable/linux-dmabuf/linux-dmabuf-unstable-v1.xml",
    "unstable/pointer-constraints/pointer-constraints-unstable-v1.xml",
    "unstable/pointer-gestures/pointer-gestures-unstable-v1.xml",
    "unstable/primary-selection/primary-selection-unstable-v1.xml",
    "unstable/relative-pointer/relative-pointer-unstable-v1.xml",
    "unstable/xdg-decoration/xdg-decoration-unstable-v1.xml",
    "unstable/xdg-output/xdg-output-unstable-v1.xml",
};

const custom_protocols = [_][]const u8{
    "virtual-keyboard-unstable-v1.xml",
    "wlr-data-control-unstable-v1.xml",
    "wlr-layer-shell-unstable-v1.xml",
    "wlr-output-management-unstable-v1.xml",
    "wlr-output-power-management-unstable-v1.xml",
    "wlr-screencopy-unstable-v1.xml",
    "wlr-virtual-pointer-unstable-v1.xml",
};

// server-side bindings only cover what aion calls; wlroots advertises its own versions
const generated = [_]struct { []const u8, u32 }{
    .{ "wl_compositor", 4 },
    .{ "wl_subcompositor", 1 },
    .{ "wl_shm", 1 },
    .{ "wl_output", 4 },
    .{ "wl_seat", 7 },
    .{ "wl_data_device_manager", 3 },
    .{ "xdg_wm_base", 2 },
    .{ "wp_viewporter", 1 },
    .{ "wp_cursor_shape_manager_v1", 1 },
    .{ "wp_fractional_scale_manager_v1", 1 },
    .{ "wp_linux_drm_syncobj_manager_v1", 1 },
    .{ "wp_single_pixel_buffer_manager_v1", 1 },
    .{ "xdg_activation_v1", 1 },
    .{ "ext_data_control_manager_v1", 1 },
    .{ "ext_idle_notifier_v1", 1 },
    .{ "ext_image_copy_capture_manager_v1", 1 },
    .{ "ext_output_image_capture_source_manager_v1", 1 },
    .{ "ext_session_lock_manager_v1", 1 },
    .{ "zwp_idle_inhibit_manager_v1", 1 },
    .{ "zwp_linux_dmabuf_v1", 4 },
    .{ "zwp_pointer_constraints_v1", 1 },
    .{ "zwp_pointer_gestures_v1", 3 },
    .{ "zwp_primary_selection_device_manager_v1", 1 },
    .{ "zwp_relative_pointer_manager_v1", 1 },
    .{ "zwp_virtual_keyboard_manager_v1", 1 },
    .{ "zxdg_decoration_manager_v1", 1 },
    .{ "zxdg_output_manager_v1", 3 },
    .{ "zwlr_data_control_manager_v1", 2 },
    .{ "zwlr_layer_shell_v1", 4 },
    .{ "zwlr_output_manager_v1", 4 },
    .{ "zwlr_output_power_manager_v1", 1 },
    .{ "zwlr_screencopy_manager_v1", 3 },
    .{ "zwlr_virtual_pointer_manager_v1", 2 },
};

pub fn build(b: *Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const strip = b.option(bool, "strip", "Omit debug information") orelse false;
    const xwayland = b.option(bool, "xwayland", "Enable Xwayland support") orelse true;

    const options = b.addOptions();
    options.addOption([]const u8, "version", manifest.version);
    options.addOption(bool, "xwayland", xwayland);

    const scanner = Scanner.create(b, .{});
    for (system_protocols) |p| scanner.addSystemProtocol(p);
    for (custom_protocols) |p| scanner.addCustomProtocol(b.path(b.pathJoin(&.{ "protocol", p })));
    for (generated) |g| scanner.generate(g[0], g[1]);

    const wayland = b.createModule(.{ .root_source_file = scanner.result });
    const xkbcommon = b.dependency("xkbcommon", .{}).module("xkbcommon");
    const pixman = b.dependency("pixman", .{}).module("pixman");
    const wlroots = b.dependency("wlroots", .{}).module("wlroots");
    wlroots.addImport("wayland", wayland);
    wlroots.addImport("xkbcommon", xkbcommon);
    wlroots.addImport("pixman", pixman);
    // @cImport("wlr/version.h") in the bindings reads this module's include path
    wlroots.resolved_target = target;
    wlroots.linkSystemLibrary("wlroots-0.20", .{});

    const c = b.addTranslateC(.{
        .root_source_file = b.path("src/c.h"),
        .target = target,
        .optimize = optimize,
    });
    c.linkSystemLibrary("libinput", .{});
    c.linkSystemLibrary("fcft", .{});
    // nix has no /usr/include, so the flake exports these; elsewhere the compiler default works
    if (b.graph.environ_map.get("AION_LIBC_INCLUDE")) |path| c.addAfterIncludePath(.{ .cwd_relative = path });
    if (b.graph.environ_map.get("AION_LINUX_HEADERS")) |path| c.addAfterIncludePath(.{ .cwd_relative = path });

    const exe = b.addExecutable(.{
        .name = "aion",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .strip = strip,
            .link_libc = true,
        }),
    });
    const mod = exe.root_module;
    mod.addOptions("build_options", options);
    mod.addImport("wayland", wayland);
    mod.addImport("xkbcommon", xkbcommon);
    mod.addImport("pixman", pixman);
    mod.addImport("wlroots", wlroots);
    mod.addImport("c", c.createModule());
    for ([_][]const u8{ "wayland-server", "wlroots-0.20", "xkbcommon", "pixman-1", "libinput", "fcft" }) |lib|
        mod.linkSystemLibrary(lib, .{});

    b.installArtifact(exe);
    b.installFile("contrib/aion.desktop", "share/wayland-sessions/aion.desktop");

    const run = b.addRunArtifact(exe);
    run.step.dependOn(b.getInstallStep());
    run.addPassthruArgs();
    b.step("run", "Run the compositor").dependOn(&run.step);

    b.step("check", "Check the compositor compiles").dependOn(&exe.step);

    const fmt_paths: []const Build.LazyPath = &.{ b.path("build.zig"), b.path("build.zig.zon"), b.path("src") };
    b.step("fmt", "Format Zig sources").dependOn(&b.addFmt(.{ .paths = fmt_paths }).step);
    b.step("fmt-check", "Fail if Zig sources are unformatted").dependOn(&b.addFmt(.{ .paths = fmt_paths, .check = true }).step);
}
