const std = @import("std");
const Build = std.Build;

const manifest = @import("build.zig.zon");

const Scanner = @import("wayland").Scanner;
const Translator = @import("translate_c").Translator;

const wlroots_pkgconf = "wlroots-0.20";

pub fn build(b: *Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const strip = b.option(bool, "strip", "Omit debug information") orelse false;
    const pie = b.option(bool, "pie", "Build a position-independent executable") orelse false;
    const use_llvm = b.option(bool, "llvm", "Force Zig's LLVM backend and lld");
    const xwayland = b.option(bool, "xwayland", "Enable Xwayland support") orelse false;
    const xwayland_path = b.option([]const u8, "xwayland-path", "Path to the Xwayland binary") orelse "Xwayland";

    const options = b.addOptions();
    options.addOption([]const u8, "version", manifest.version);
    options.addOption(bool, "xwayland", xwayland);
    options.addOption([]const u8, "xwayland_path", xwayland_path);

    const scanner = Scanner.create(b, .{});
    const system_protocols = [_][]const u8{
        "stable/viewporter/viewporter.xml",
        "stable/xdg-shell/xdg-shell.xml",
        "staging/alpha-modifier/alpha-modifier-v1.xml",
        "staging/color-management/color-management-v1.xml",
        "staging/color-representation/color-representation-v1.xml",
        "staging/commit-timing/commit-timing-v1.xml",
        "staging/content-type/content-type-v1.xml",
        "staging/cursor-shape/cursor-shape-v1.xml",
        "staging/drm-lease/drm-lease-v1.xml",
        "staging/ext-data-control/ext-data-control-v1.xml",
        "staging/ext-foreign-toplevel-list/ext-foreign-toplevel-list-v1.xml",
        "staging/ext-idle-notify/ext-idle-notify-v1.xml",
        "staging/ext-image-capture-source/ext-image-capture-source-v1.xml",
        "staging/ext-image-copy-capture/ext-image-copy-capture-v1.xml",
        "staging/ext-session-lock/ext-session-lock-v1.xml",
        "staging/ext-transient-seat/ext-transient-seat-v1.xml",
        "staging/ext-workspace/ext-workspace-v1.xml",
        "staging/fifo/fifo-v1.xml",
        "staging/fractional-scale/fractional-scale-v1.xml",
        "staging/linux-drm-syncobj/linux-drm-syncobj-v1.xml",
        "staging/pointer-warp/pointer-warp-v1.xml",
        "staging/security-context/security-context-v1.xml",
        "staging/single-pixel-buffer/single-pixel-buffer-v1.xml",
        "staging/tearing-control/tearing-control-v1.xml",
        "staging/xdg-activation/xdg-activation-v1.xml",
        "staging/xdg-dialog/xdg-dialog-v1.xml",
        "staging/xdg-toplevel-tag/xdg-toplevel-tag-v1.xml",
        "unstable/idle-inhibit/idle-inhibit-unstable-v1.xml",
        "unstable/input-timestamps/input-timestamps-unstable-v1.xml",
        "unstable/keyboard-shortcuts-inhibit/keyboard-shortcuts-inhibit-unstable-v1.xml",
        "unstable/linux-dmabuf/linux-dmabuf-unstable-v1.xml",
        "unstable/pointer-constraints/pointer-constraints-unstable-v1.xml",
        "unstable/pointer-gestures/pointer-gestures-unstable-v1.xml",
        "unstable/primary-selection/primary-selection-unstable-v1.xml",
        "unstable/relative-pointer/relative-pointer-unstable-v1.xml",
        "unstable/tablet/tablet-unstable-v2.xml",
        "unstable/text-input/text-input-unstable-v3.xml",
        "unstable/xdg-decoration/xdg-decoration-unstable-v1.xml",
        "unstable/xdg-foreign/xdg-foreign-unstable-v2.xml",
        "unstable/xdg-output/xdg-output-unstable-v1.xml",
    };
    for (system_protocols) |protocol| scanner.addSystemProtocol(protocol);

    const pkg_config = b.graph.environ_map.get("PKG_CONFIG") orelse "pkg-config";
    const wlr_protocols = std.mem.trim(
        u8,
        b.run(&.{ pkg_config, "--variable=pkgdatadir", "wlr-protocols" }),
        &std.ascii.whitespace,
    );
    const wlr_protocol_xmls = [_][]const u8{
        "unstable/wlr-data-control-unstable-v1.xml",
        "unstable/wlr-export-dmabuf-unstable-v1.xml",
        "unstable/wlr-foreign-toplevel-management-unstable-v1.xml",
        "unstable/wlr-gamma-control-unstable-v1.xml",
        "unstable/wlr-layer-shell-unstable-v1.xml",
        "unstable/wlr-output-management-unstable-v1.xml",
        "unstable/wlr-output-power-management-unstable-v1.xml",
        "unstable/wlr-screencopy-unstable-v1.xml",
        "unstable/wlr-virtual-pointer-unstable-v1.xml",
    };
    for (wlr_protocol_xmls) |protocol| {
        scanner.addCustomProtocol(.{
            .cwd_relative = b.pathJoin(&.{ wlr_protocols, protocol }),
        });
    }
    scanner.addCustomProtocol(b.path("protocol/virtual-keyboard-unstable-v1.xml"));

    // Versions zig-wlroots' own test generates. Newer than this only fails
    // the build if compositor code calls a method the generated bindings lack.
    const generated = [_]struct { []const u8, u32 }{
        .{ "wl_compositor", 4 },
        .{ "wl_subcompositor", 1 },
        .{ "wl_shm", 1 },
        .{ "wl_output", 4 },
        .{ "wl_seat", 7 },
        .{ "wl_data_device_manager", 3 },
        .{ "xdg_wm_base", 2 },
        .{ "wp_viewporter", 1 },
        .{ "wp_fractional_scale_manager_v1", 1 },
        .{ "wp_cursor_shape_manager_v1", 1 },
        .{ "wp_tearing_control_manager_v1", 1 },
        .{ "wp_content_type_manager_v1", 1 },
        .{ "wp_color_manager_v1", 2 },
        .{ "wp_color_representation_manager_v1", 1 },
        .{ "wp_alpha_modifier_v1", 1 },
        .{ "wp_single_pixel_buffer_manager_v1", 1 },
        .{ "wp_security_context_manager_v1", 1 },
        .{ "wp_commit_timing_manager_v1", 1 },
        .{ "wp_fifo_manager_v1", 1 },
        .{ "wp_linux_drm_syncobj_manager_v1", 1 },
        .{ "wp_pointer_warp_v1", 1 },
        .{ "wp_drm_lease_device_v1", 1 },
        .{ "xdg_activation_v1", 1 },
        .{ "xdg_wm_dialog_v1", 1 },
        .{ "xdg_toplevel_tag_manager_v1", 1 },
        .{ "ext_session_lock_manager_v1", 1 },
        .{ "ext_transient_seat_manager_v1", 1 },
        .{ "ext_idle_notifier_v1", 1 },
        .{ "ext_data_control_manager_v1", 1 },
        .{ "ext_foreign_toplevel_list_v1", 1 },
        .{ "ext_workspace_manager_v1", 1 },
        .{ "ext_image_copy_capture_manager_v1", 1 },
        .{ "ext_output_image_capture_source_manager_v1", 1 },
        .{ "ext_foreign_toplevel_image_capture_source_manager_v1", 1 },
        .{ "zwp_pointer_gestures_v1", 3 },
        .{ "zwp_pointer_constraints_v1", 1 },
        .{ "zwp_relative_pointer_manager_v1", 1 },
        .{ "zwp_idle_inhibit_manager_v1", 1 },
        .{ "zwp_primary_selection_device_manager_v1", 1 },
        .{ "zwp_text_input_manager_v3", 1 },
        .{ "zwp_keyboard_shortcuts_inhibit_manager_v1", 1 },
        .{ "zwp_input_timestamps_manager_v1", 1 },
        .{ "zwp_tablet_manager_v2", 1 },
        .{ "zwp_linux_dmabuf_v1", 4 },
        .{ "zwp_virtual_keyboard_manager_v1", 1 },
        .{ "zxdg_decoration_manager_v1", 1 },
        .{ "zxdg_importer_v2", 1 },
        .{ "zxdg_exporter_v2", 1 },
        .{ "zxdg_output_manager_v1", 3 },
        .{ "zwlr_layer_shell_v1", 4 },
        .{ "zwlr_output_power_manager_v1", 1 },
        .{ "zwlr_output_manager_v1", 4 },
        .{ "zwlr_foreign_toplevel_manager_v1", 3 },
        .{ "zwlr_data_control_manager_v1", 2 },
        .{ "zwlr_gamma_control_manager_v1", 1 },
        .{ "zwlr_screencopy_manager_v1", 3 },
        .{ "zwlr_export_dmabuf_manager_v1", 1 },
        .{ "zwlr_virtual_pointer_manager_v1", 2 },
    };
    for (generated) |item| scanner.generate(item[0], item[1]);

    const wayland = b.createModule(.{ .root_source_file = scanner.result });
    const xkbcommon = b.dependency("xkbcommon", .{}).module("xkbcommon");
    const pixman = b.dependency("pixman", .{}).module("pixman");
    const wlroots = b.dependency("wlroots", .{}).module("wlroots");
    wlroots.addImport("wayland", wayland);
    wlroots.addImport("xkbcommon", xkbcommon);
    wlroots.addImport("pixman", pixman);
    // @cImport("wlr/version.h") in the bindings reads this module's include path.
    wlroots.resolved_target = target;
    wlroots.linkSystemLibrary(wlroots_pkgconf, .{});

    const translate_c: Translator = .init(b.dependency("translate_c", .{}), .{
        .name = "c",
        .c_source_file = b.path("src/c.h"),
        .target = target,
        .optimize = optimize,
    });
    translate_c.linkSystemLibrary("libevdev", .{});
    translate_c.linkSystemLibrary("libinput", .{});
    translate_c.linkSystemLibrary("libudev", .{});
    // Nix has no /usr/include. The flake exports these; other systems use the compiler default.
    if (b.graph.environ_map.get("AION_LIBC_INCLUDE")) |path| {
        translate_c.addAfterIncludePath(.{ .cwd_relative = path });
    }
    if (b.graph.environ_map.get("AION_LINUX_HEADERS")) |path| {
        translate_c.addAfterIncludePath(.{ .cwd_relative = path });
    }

    const mod = b.addModule("aion", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    const exe = b.addExecutable(.{
        .name = "aion",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .strip = strip,
            .link_libc = true,
            .imports = &.{
                .{ .name = "aion", .module = mod },
            },
        }),
        .use_llvm = use_llvm,
        .use_lld = use_llvm,
    });
    exe.root_module.addOptions("build_options", options);
    exe.root_module.addImport("wayland", wayland);
    exe.root_module.addImport("xkbcommon", xkbcommon);
    exe.root_module.addImport("pixman", pixman);
    exe.root_module.addImport("wlroots", wlroots);
    exe.root_module.addImport("c", translate_c.mod);
    exe.root_module.linkSystemLibrary("libevdev", .{});
    exe.root_module.linkSystemLibrary("libinput", .{});
    exe.root_module.linkSystemLibrary("libudev", .{});
    exe.root_module.linkSystemLibrary("wayland-server", .{});
    exe.root_module.linkSystemLibrary(wlroots_pkgconf, .{});
    exe.root_module.linkSystemLibrary("xkbcommon", .{});
    exe.root_module.linkSystemLibrary("pixman-1", .{});
    if (xwayland) {
        exe.root_module.linkSystemLibrary("xcb", .{});
    }
    exe.pie = pie;

    b.installArtifact(exe);
    b.installBinFile("contrib/aion-session", "aion-session");
    b.installFile("contrib/aion.desktop", "share/wayland-sessions/aion.desktop");

    const run_step = b.step("run", "Run the compositor");
    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);

    const check_step = b.step("check", "Check the compositor compiles");
    check_step.dependOn(&exe.step);

    const test_step = b.step("test", "Run tests");
    const tests = b.addTest(.{ .root_module = mod });
    test_step.dependOn(&b.addRunArtifact(tests).step);

    const fmt_paths = &.{ "build.zig", "src" };
    const fmt_step = b.step("fmt", "Format Zig sources");
    fmt_step.dependOn(&b.addFmt(.{ .paths = fmt_paths }).step);
    const fmt_check = b.step("fmt-check", "Fail if Zig sources are unformatted");
    fmt_check.dependOn(&b.addFmt(.{ .paths = fmt_paths, .check = true }).step);
}
