const std = @import("std");

/// Add -I include paths from `pkg-config --cflags-only-I <pkg>`.
fn addPkgConfigIncludes(mod: *std.Build.Module, pkg: []const u8) void {
    // Build scripts may not have process I/O; shell out via std.ChildProcess-less
    // approach using known include roots when pkg-config is unavailable.
    const defaults = [_][]const u8{
        "/usr/include/libayatana-appindicator3-0.1",
        "/usr/include/gtk-3.0",
        "/usr/include/glib-2.0",
        "/usr/lib/glib-2.0/include",
        "/usr/include/pango-1.0",
        "/usr/include/cairo",
        "/usr/include/gdk-pixbuf-2.0",
        "/usr/include/atk-1.0",
        "/usr/include/harfbuzz",
        "/usr/include/freetype2",
    };
    _ = pkg;
    for (defaults) |p| {
        mod.addIncludePath(.{ .cwd_relative = p });
    }
}

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // C bindings. Zig 0.17 removed @cImport, so the headers are translated at
    // build time and imported as modules ("c_gui", "c_wayland", ...).
    //
    // Zig 0.17 also deprecates std.Build.Step.TranslateC in favour of the
    // standalone translate-c package. The built-in step is used here because
    // it needs no network access at build time; switch to
    // `zig fetch --save git+https://codeberg.org/ziglang/translate-c#zig-0.17.x`
    // if the packaged build can depend on it.
    //
    // GLFW, GLES2 and cimgui share one unit: cimgui_backends.h declares the
    // backend entry points with GLFWwindow*, and one unit keeps GLFWwindow,
    // ImFont and the other ImGui types identical across modules.
    const c_gui_step = b.addTranslateC(.{
        .root_source_file = b.path("src/ctypes/gui.h"),
        .target = target,
        .optimize = optimize,
    });
    c_gui_step.addIncludePath(b.path("vendor/imgui"));
    c_gui_step.addIncludePath(b.path("vendor/imgui/cimgui"));
    // Without this define cimgui.h falls back to C++ template typedefs
    // (ImPool<T>, ImVector<T>, ...) that translate-c cannot parse.
    c_gui_step.defineCMacro("CIMGUI_DEFINE_ENUMS_AND_STRUCTS", "1");
    const c_gui = c_gui_step.addModule("c_gui");

    const c_wayland_step = b.addTranslateC(.{
        .root_source_file = b.path("src/ctypes/wayland.h"),
        .target = target,
        .optimize = optimize,
    });
    c_wayland_step.linkSystemLibrary("wayland-client", .{});
    const c_wayland = c_wayland_step.addModule("c_wayland");

    const c_toplevel_step = b.addTranslateC(.{
        .root_source_file = b.path("src/ctypes/toplevel.h"),
        .target = target,
        .optimize = optimize,
    });
    c_toplevel_step.addIncludePath(b.path("vendor"));
    c_toplevel_step.linkSystemLibrary("wayland-client", .{});
    const c_toplevel = c_toplevel_step.addModule("c_toplevel");

    const c_inotify_step = b.addTranslateC(.{
        .root_source_file = b.path("src/ctypes/inotify.h"),
        .target = target,
        .optimize = optimize,
    });
    const c_inotify = c_inotify_step.addModule("c_inotify");

    const c_tray_step = b.addTranslateC(.{
        .root_source_file = b.path("src/tray_c.h"),
        .target = target,
        .optimize = optimize,
    });
    const c_tray = c_tray_step.addModule("c_tray");

    // cimgui + Dear ImGui (vendored C++ compiled as a static library; cimgui is
    // the C-friendly shim the "c_gui" module is translated from. imgui.h itself
    // is C++ and cannot be translated directly.)
    const imgui_mod = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .link_libcpp = true,
    });
    imgui_mod.addCSourceFiles(.{
        .files = &.{
            "vendor/imgui/imgui.cpp",
            "vendor/imgui/imgui_demo.cpp",
            "vendor/imgui/imgui_draw.cpp",
            "vendor/imgui/imgui_tables.cpp",
            "vendor/imgui/imgui_widgets.cpp",
            "vendor/imgui/cimgui/cimgui.cpp",
            "vendor/imgui/cimgui/cimgui_backends.cpp",
            "vendor/imgui/backends/imgui_impl_glfw.cpp",
            "vendor/imgui/backends/imgui_impl_opengl3.cpp",
        },
        .flags = &.{
            "-DIMGUI_IMPL_OPENGL_LOADER_CUSTOM",
            "-DIMGUI_IMPL_OPENGL_ES3",
        },
    });
    imgui_mod.addIncludePath(b.path("vendor/imgui"));
    imgui_mod.addIncludePath(b.path("vendor/imgui/backends"));
    imgui_mod.addIncludePath(b.path("vendor/imgui/cimgui"));
    const imgui = b.addLibrary(.{
        .name = "imgui",
        .linkage = .static,
        .root_module = imgui_mod,
    });
    b.installArtifact(imgui);

    // Generated wlr-screencopy protocol glue (checked in under vendor/).
    const wl_proto_mod = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    wl_proto_mod.addCSourceFile(.{
        .file = b.path("vendor/wl_proto_screencopy.c"),
        .flags = &.{},
    });
    wl_proto_mod.addCSourceFile(.{
        .file = b.path("vendor/wl_proto_layer_shell.c"),
        .flags = &.{},
    });
    wl_proto_mod.addCSourceFile(.{
        .file = b.path("vendor/wl_proto_toplevel.c"),
        .flags = &.{},
    });
    wl_proto_mod.addIncludePath(b.path("vendor"));
    // Do not link wayland-client on this static lib: Zig would embed the .so
    // path into the archive and LLD fails under ReleaseSafe. The final
    // executable links wayland-client instead.
    const wl_proto = b.addLibrary(.{
        .name = "wl_proto",
        .linkage = .static,
        .root_module = wl_proto_mod,
    });
    b.installArtifact(wl_proto);

    // Shared modules. Zig forbids file imports outside a module's root, so
    // tests and sibling sources cross-import by module name.
    const mod_names = [_][]const u8{
        "app_io", "config", "watcher", "compositor", "clipboard", "wayland", "log",
    };
    var mods: [mod_names.len]*std.Build.Module = undefined;
    inline for (mod_names, 0..) |name, i| {
        mods[i] = b.addModule(name, .{
            .root_source_file = b.path(b.fmt("src/{s}.zig", .{name})),
            .target = target,
            .optimize = optimize,
        });
    }
    // app_io is index 0; wire it into modules that perform process I/O.
    const app_io_mod = mods[0];
    // watcher (index 2) and wayland (index 5) need their C bindings.
    const watcher_mod = mods[2];
    watcher_mod.addImport("c_inotify", c_inotify);
    const wayland_mod = mods[5];
    wayland_mod.addImport("c_wayland", c_wayland);

    const app_icon_mod = b.addModule("app_icon", .{
        .root_source_file = b.path("src/app_icon.zig"),
        .target = target,
        .optimize = optimize,
    });
    app_icon_mod.addImport("app_io", app_io_mod);

    const theme_mod = b.addModule("theme", .{
        .root_source_file = b.path("src/theme.zig"),
        .target = target,
        .optimize = optimize,
    });
    theme_mod.addImport("c_gui", c_gui);
    theme_mod.addImport("config", mods[1]);
    theme_mod.addImport("app_io", app_io_mod);

    const storage_mod = b.addModule("storage", .{
        .root_source_file = b.path("src/storage.zig"),
        .target = target,
        .optimize = optimize,
    });
    storage_mod.addImport("app_io", app_io_mod);

    const png_mod = b.addModule("png", .{
        .root_source_file = b.path("src/png.zig"),
        .target = target,
        .optimize = optimize,
    });

    const capture_mod = b.addModule("capture", .{
        .root_source_file = b.path("src/capture.zig"),
        .target = target,
        .optimize = optimize,
    });
    capture_mod.addImport("c_wayland", c_wayland);
    capture_mod.addImport("png", png_mod);

    const editor_mod = b.addModule("editor", .{
        .root_source_file = b.path("src/editor.zig"),
        .target = target,
        .optimize = optimize,
    });
    editor_mod.addImport("png", png_mod);
    editor_mod.addImport("storage", storage_mod);
    editor_mod.addImport("app_io", app_io_mod);

    const marquee_mod = b.addModule("marquee", .{
        .root_source_file = b.path("src/marquee.zig"),
        .target = target,
        .optimize = optimize,
    });
    marquee_mod.addImport("c_gui", c_gui);
    marquee_mod.addImport("watcher", mods[2]);
    marquee_mod.addImport("png", png_mod);
    marquee_mod.addImport("app_io", app_io_mod);

    const layer_shell_mod = b.addModule("layer_shell", .{
        .root_source_file = b.path("src/layer_shell.zig"),
        .target = target,
        .optimize = optimize,
    });

    const toast_mod = b.addModule("toast", .{
        .root_source_file = b.path("src/toast.zig"),
        .target = target,
        .optimize = optimize,
    });
    toast_mod.addImport("c_gui", c_gui);
    toast_mod.addImport("app_io", app_io_mod);

    const spawn_mod = b.addModule("spawn", .{
        .root_source_file = b.path("src/spawn.zig"),
        .target = target,
        .optimize = optimize,
    });
    spawn_mod.addImport("app_io", app_io_mod);

    const toplevel_mod = b.addModule("toplevel", .{
        .root_source_file = b.path("src/toplevel.zig"),
        .target = target,
        .optimize = optimize,
    });
    toplevel_mod.addImport("c_toplevel", c_toplevel);
    toplevel_mod.addIncludePath(b.path("vendor"));
    toplevel_mod.addImport("capture", capture_mod);

    const clipboard_mod = mods[4];
    clipboard_mod.addImport("app_io", app_io_mod);

    const compositor_mod = mods[3];
    compositor_mod.addImport("app_io", app_io_mod);

    const config_mod = mods[1];
    config_mod.addImport("app_io", app_io_mod);

    const log_mod = mods[6];
    log_mod.addImport("app_io", app_io_mod);

    const overlay_mod = b.addModule("overlay", .{
        .root_source_file = b.path("src/overlay.zig"),
        .target = target,
        .optimize = optimize,
    });
    overlay_mod.addImport("capture", capture_mod);
    overlay_mod.addImport("storage", storage_mod);
    overlay_mod.addImport("clipboard", clipboard_mod);
    overlay_mod.addImport("wayland", mods[5]);
    overlay_mod.addImport("config", config_mod);
    overlay_mod.addImport("spawn", spawn_mod);
    overlay_mod.addImport("toplevel", toplevel_mod);
    overlay_mod.addImport("app_io", app_io_mod);

    const setup_mod = b.addModule("setup", .{
        .root_source_file = b.path("src/setup.zig"),
        .target = target,
        .optimize = optimize,
    });
    setup_mod.addImport("config", config_mod);
    setup_mod.addImport("compositor", compositor_mod);
    setup_mod.addImport("app_io", app_io_mod);
    setup_mod.addImport("app_icon", app_icon_mod);

    const redraw_mod = b.addModule("redraw", .{
        .root_source_file = b.path("src/redraw.zig"),
        .target = target,
        .optimize = optimize,
    });
    redraw_mod.addImport("c_gui", c_gui);

    const editor_window_mod = b.addModule("editor_window", .{
        .root_source_file = b.path("src/editor_window.zig"),
        .target = target,
        .optimize = optimize,
    });
    editor_window_mod.addImport("c_gui", c_gui);
    editor_window_mod.addImport("png", png_mod);
    editor_window_mod.addImport("editor", editor_mod);
    editor_window_mod.addImport("theme", theme_mod);
    editor_window_mod.addImport("config", config_mod);
    editor_window_mod.addImport("app_io", app_io_mod);
    editor_window_mod.addImport("app_icon", app_icon_mod);
    editor_window_mod.addImport("clipboard", clipboard_mod);
    editor_window_mod.addImport("redraw", redraw_mod);

    const instance_mod = b.addModule("instance", .{
        .root_source_file = b.path("src/instance.zig"),
        .target = target,
        .optimize = optimize,
    });
    instance_mod.addImport("app_io", app_io_mod);

    const tray_mod = b.addModule("tray", .{
        .root_source_file = b.path("src/tray.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    tray_mod.addImport("c_tray", c_tray);
    tray_mod.addCSourceFile(.{
        .file = b.path("src/tray_c.c"),
        .flags = &.{},
    });
    tray_mod.addIncludePath(b.path("src"));
    addPkgConfigIncludes(tray_mod, "ayatana-appindicator3-0.1");
    addPkgConfigIncludes(tray_mod, "gtk+-3.0");
    tray_mod.linkSystemLibrary("ayatana-appindicator3", .{});
    tray_mod.linkSystemLibrary("gtk-3", .{});
    tray_mod.linkSystemLibrary("glib-2.0", .{});
    tray_mod.linkSystemLibrary("gobject-2.0", .{});

    const ui_mod = b.addModule("ui", .{
        .root_source_file = b.path("src/ui.zig"),
        .target = target,
        .optimize = optimize,
    });
    ui_mod.addImport("c_gui", c_gui);
    ui_mod.addImport("marquee", marquee_mod);
    ui_mod.addImport("storage", storage_mod);
    ui_mod.addImport("toast", toast_mod);
    ui_mod.addImport("compositor", compositor_mod);
    ui_mod.addImport("config", config_mod);
    ui_mod.addImport("theme", theme_mod);
    ui_mod.addImport("app_io", app_io_mod);
    ui_mod.addImport("app_icon", app_icon_mod);
    ui_mod.addImport("instance", instance_mod);
    ui_mod.addImport("tray", tray_mod);
    ui_mod.addImport("redraw", redraw_mod);

    const root_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .link_libcpp = true,
        .imports = &.{
            .{ .name = "app_io", .module = app_io_mod },
            .{ .name = "overlay", .module = overlay_mod },
            .{ .name = "setup", .module = setup_mod },
            .{ .name = "editor_window", .module = editor_window_mod },
            .{ .name = "ui", .module = ui_mod },
            .{ .name = "png", .module = png_mod },
        },
    });
    root_mod.linkLibrary(imgui);
    root_mod.linkLibrary(wl_proto);
    root_mod.addIncludePath(b.path("vendor"));
    root_mod.linkSystemLibrary("glfw3", .{});
    root_mod.linkSystemLibrary("wayland-client", .{});
    root_mod.linkSystemLibrary("wayland-cursor", .{});
    root_mod.linkSystemLibrary("wayland-egl", .{});
    root_mod.linkSystemLibrary("egl", .{});
    root_mod.linkSystemLibrary("glesv2", .{});
    root_mod.linkSystemLibrary("xkbcommon", .{});
    // Tray (Ayatana AppIndicator + GTK)
    root_mod.linkSystemLibrary("ayatana-appindicator3", .{});
    root_mod.linkSystemLibrary("gtk-3", .{});
    root_mod.linkSystemLibrary("glib-2.0", .{});
    root_mod.linkSystemLibrary("gobject-2.0", .{});

    const exe = b.addExecutable(.{
        .name = "zigit",
        .root_module = root_mod,
    });
    b.installArtifact(exe);

    // Freedesktop icons + desktop entry for packaging (AUR/system install).
    const icon_sizes = [_][]const u8{ "16x16", "24x24", "32x32", "48x48", "64x64", "96x96", "128x128", "192x192", "256x256", "512x512" };
    for (icon_sizes) |size| {
        const install_icon = b.addInstallFile(
            b.path(b.fmt("packaging/icons/hicolor/{s}/apps/com.visorcraft.zigit.png", .{size})),
            b.fmt("share/icons/hicolor/{s}/apps/com.visorcraft.zigit.png", .{size}),
        );
        b.getInstallStep().dependOn(&install_icon.step);
    }
    const install_desktop = b.addInstallFile(
        b.path("packaging/com.visorcraft.zigit.desktop"),
        "share/applications/com.visorcraft.zigit.desktop",
    );
    b.getInstallStep().dependOn(&install_desktop.step);

    const test_step = b.step("test", "Run unit tests");
    {
        const io = b.graph.io;
        var dir = std.Io.Dir.cwd().openDir(io, "tests", .{ .iterate = true }) catch @panic("cannot open tests dir");
        defer dir.close(io);
        var it = dir.iterate();
        while (it.next(io) catch @panic("cannot iterate tests dir")) |entry| {
            if (entry.kind != .file) continue;
            if (!std.mem.endsWith(u8, entry.name, "_test.zig")) continue;

            const t_mod = b.createModule(.{
                .root_source_file = b.path(b.fmt("tests/{s}", .{entry.name})),
                .target = target,
                .optimize = optimize,
                .link_libc = true,
            });
            inline for (mod_names, 0..) |name, i| {
                t_mod.addImport(name, mods[i]);
            }
            t_mod.addImport("storage", storage_mod);
            t_mod.addImport("png", png_mod);
            t_mod.addImport("capture", capture_mod);
            t_mod.addImport("editor", editor_mod);
            t_mod.addImport("marquee", marquee_mod);
            t_mod.addImport("layer_shell", layer_shell_mod);
            t_mod.addImport("toast", toast_mod);
            t_mod.addImport("overlay", overlay_mod);
            t_mod.addImport("spawn", spawn_mod);
            t_mod.addImport("toplevel", toplevel_mod);
            t_mod.addImport("setup", setup_mod);
            t_mod.addImport("editor_window", editor_window_mod);
            t_mod.addImport("ui", ui_mod);
            t_mod.addImport("theme", theme_mod);
            t_mod.addImport("app_icon", app_icon_mod);
            t_mod.addImport("instance", instance_mod);
            t_mod.addImport("tray", tray_mod);
            t_mod.addImport("redraw", redraw_mod);
            t_mod.addIncludePath(b.path("vendor"));
            t_mod.linkSystemLibrary("wayland-client", .{});
            t_mod.linkSystemLibrary("glfw3", .{});

            const t = b.addTest(.{
                .root_module = t_mod,
            });
            test_step.dependOn(&b.addRunArtifact(t).step);
        }
    }
}
