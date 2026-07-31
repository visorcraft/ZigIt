const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // cimgui + Dear ImGui (vendored C++ compiled as a static library; cimgui is the
    // C-friendly shim that @cImport can ingest. imgui.h itself is C++ and Zig's
    // @cImport cannot parse it.)
    const imgui = b.addStaticLibrary(.{
        .name = "imgui",
        .target = target,
        .optimize = optimize,
    });
    imgui.addCSourceFiles(.{
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
    imgui.addIncludePath(b.path("vendor/imgui"));
    imgui.addIncludePath(b.path("vendor/imgui/backends"));
    imgui.addIncludePath(b.path("vendor/imgui/cimgui"));
    imgui.linkLibC();
    imgui.linkLibCpp();
    b.installArtifact(imgui);

    // Generated wlr-screencopy protocol glue (checked in under vendor/).
    const wl_proto = b.addStaticLibrary(.{
        .name = "wl_proto",
        .target = target,
        .optimize = optimize,
    });
    wl_proto.addCSourceFile(.{
        .file = b.path("vendor/wl_proto_screencopy.c"),
        .flags = &.{},
    });
    wl_proto.addCSourceFile(.{
        .file = b.path("vendor/wl_proto_layer_shell.c"),
        .flags = &.{},
    });
    wl_proto.addCSourceFile(.{
        .file = b.path("vendor/wl_proto_toplevel.c"),
        .flags = &.{},
    });
    wl_proto.addIncludePath(b.path("vendor"));
    wl_proto.linkLibC();
    wl_proto.linkSystemLibrary("wayland-client");
    b.installArtifact(wl_proto);

    // ZigIt binary
    const exe = b.addExecutable(.{
        .name = "zigit",
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    exe.linkLibrary(imgui);
    exe.linkLibrary(wl_proto);
    exe.addIncludePath(b.path("vendor"));
    exe.linkLibC();
    exe.linkLibCpp();
    exe.linkSystemLibrary("glfw3");
    exe.linkSystemLibrary("wayland-client");
    exe.linkSystemLibrary("wayland-cursor");
    exe.linkSystemLibrary("wayland-egl");
    exe.linkSystemLibrary("egl");
    exe.linkSystemLibrary("glesv2");
    exe.linkSystemLibrary("xkbcommon");
    // inotify is in glibc; no link needed.
    b.installArtifact(exe);

    // Src files are exposed as named modules: Zig 0.13 forbids file imports
    // outside a module's root directory, so tests cannot reach "../src/x.zig"
    // directly, and sibling src files cross-import by module name
    // (`@import("png")` etc.) so include paths stay attached to one instance.
    const mod_names = [_][]const u8{
        "config", "watcher", "compositor", "clipboard", "wayland", "log",
    };
    var mods: [mod_names.len]*std.Build.Module = undefined;
    inline for (mod_names, 0..) |name, i| {
        mods[i] = b.addModule(name, .{ .root_source_file = b.path("src/" ++ name ++ ".zig") });
    }
    // Shared ImGui chrome (daemon + editor). @cImports cimgui.
    const theme_mod = b.addModule("theme", .{ .root_source_file = b.path("src/theme.zig") });
    theme_mod.addIncludePath(b.path("vendor/imgui"));
    theme_mod.addIncludePath(b.path("vendor/imgui/cimgui"));
    theme_mod.addImport("config", mods[0]);
    const storage_mod = b.addModule("storage", .{ .root_source_file = b.path("src/storage.zig") });
    // png @cImports the vendored stb headers, so its include path must be
    // attached to the module itself (artifact-level -I does not reach
    // dependency-module cImports in 0.13).
    const png_mod = b.addModule("png", .{ .root_source_file = b.path("src/png.zig") });
    png_mod.addIncludePath(b.path("vendor/imgui"));
    const capture_mod = b.addModule("capture", .{ .root_source_file = b.path("src/capture.zig") });
    capture_mod.addImport("png", png_mod);
    const editor_mod = b.addModule("editor", .{ .root_source_file = b.path("src/editor.zig") });
    editor_mod.addImport("png", png_mod);
    editor_mod.addImport("storage", storage_mod);
    const marquee_mod = b.addModule("marquee", .{ .root_source_file = b.path("src/marquee.zig") });
    // marquee @cImports cimgui, so the vendored include paths must be attached
    // to the module itself. mods[] follows mod_names order: watcher is index 1.
    marquee_mod.addIncludePath(b.path("vendor/imgui"));
    marquee_mod.addIncludePath(b.path("vendor/imgui/cimgui"));
    marquee_mod.addImport("watcher", mods[1]);
    marquee_mod.addImport("png", png_mod);
    const layer_shell_mod = b.addModule("layer_shell", .{ .root_source_file = b.path("src/layer_shell.zig") });
    const toast_mod = b.addModule("toast", .{ .root_source_file = b.path("src/toast.zig") });
    // toast @cImports cimgui, so the vendored include paths must be attached
    // to the module itself.
    toast_mod.addIncludePath(b.path("vendor/imgui"));
    toast_mod.addIncludePath(b.path("vendor/imgui/cimgui"));
    const overlay_mod = b.addModule("overlay", .{ .root_source_file = b.path("src/overlay.zig") });
    // mods[] follows mod_names order: config is 0, clipboard is 3, wayland is 4.
    overlay_mod.addImport("capture", capture_mod);
    overlay_mod.addImport("storage", storage_mod);
    overlay_mod.addImport("clipboard", mods[3]);
    overlay_mod.addImport("wayland", mods[4]);
    overlay_mod.addImport("config", mods[0]);
    const spawn_mod = b.addModule("spawn", .{ .root_source_file = b.path("src/spawn.zig") });
    const toplevel_mod = b.addModule("toplevel", .{ .root_source_file = b.path("src/toplevel.zig") });
    // toplevel @cImports the vendored foreign-toplevel header, so the include
    // path must be attached to the module itself.
    toplevel_mod.addIncludePath(b.path("vendor"));
    toplevel_mod.addImport("capture", capture_mod);
    overlay_mod.addImport("spawn", spawn_mod);
    overlay_mod.addImport("toplevel", toplevel_mod);
    exe.root_module.addImport("overlay", overlay_mod);
    const setup_mod = b.addModule("setup", .{ .root_source_file = b.path("src/setup.zig") });
    // mods[] follows mod_names order: config is index 0, compositor index 2.
    setup_mod.addImport("config", mods[0]);
    setup_mod.addImport("compositor", mods[2]);
    exe.root_module.addImport("setup", setup_mod);
    const editor_window_mod = b.addModule("editor_window", .{ .root_source_file = b.path("src/editor_window.zig") });
    // editor_window @cImports cimgui + the backend shims, so the vendored
    // include paths must be attached to the module itself.
    editor_window_mod.addIncludePath(b.path("vendor/imgui"));
    editor_window_mod.addIncludePath(b.path("vendor/imgui/cimgui"));
    editor_window_mod.addImport("png", png_mod);
    editor_window_mod.addImport("editor", editor_mod);
    editor_window_mod.addImport("theme", theme_mod);
    editor_window_mod.addImport("config", mods[0]);
    exe.root_module.addImport("editor_window", editor_window_mod);
    const ui_mod = b.addModule("ui", .{ .root_source_file = b.path("src/ui.zig") });
    // ui @cImports cimgui + the backend shims, so the vendored include paths
    // must be attached to the module itself (artifact-level -I does not reach
    // dependency-module cImports in 0.13).
    ui_mod.addIncludePath(b.path("vendor/imgui"));
    ui_mod.addIncludePath(b.path("vendor/imgui/cimgui"));
    ui_mod.addImport("marquee", marquee_mod);
    ui_mod.addImport("storage", storage_mod);
    ui_mod.addImport("toast", toast_mod);
    // mods[] follows mod_names order: compositor is index 2, config is index 0.
    ui_mod.addImport("compositor", mods[2]);
    ui_mod.addImport("config", mods[0]);
    ui_mod.addImport("theme", theme_mod);
    exe.root_module.addImport("ui", ui_mod);

    // Tests: iterate every tests/*_test.zig
    const test_step = b.step("test", "Run unit tests");
    {
        var dir = std.fs.cwd().openDir("tests", .{ .iterate = true }) catch @panic("cannot open tests dir");
        defer dir.close();
        var it = dir.iterate();
        while (it.next() catch @panic("cannot iterate tests dir")) |entry| {
            if (entry.kind != .file) continue;
            if (!std.mem.endsWith(u8, entry.name, "_test.zig")) continue;
            const t = b.addTest(.{
                .root_source_file = b.path(b.fmt("tests/{s}", .{entry.name})),
                .target = target,
                .optimize = optimize,
            });
            inline for (mod_names, 0..) |name, i| {
                t.root_module.addImport(name, mods[i]);
            }
            t.root_module.addImport("storage", storage_mod);
            t.root_module.addImport("png", png_mod);
            t.root_module.addImport("capture", capture_mod);
            t.root_module.addImport("editor", editor_mod);
            t.root_module.addImport("marquee", marquee_mod);
            t.root_module.addImport("layer_shell", layer_shell_mod);
            t.root_module.addImport("toast", toast_mod);
            t.root_module.addImport("overlay", overlay_mod);
            t.root_module.addImport("spawn", spawn_mod);
            t.root_module.addImport("toplevel", toplevel_mod);
            t.root_module.addImport("setup", setup_mod);
            t.root_module.addImport("editor_window", editor_window_mod);
            t.root_module.addImport("ui", ui_mod);
            t.root_module.addImport("theme", theme_mod);
            t.linkLibC();
            t.addIncludePath(b.path("vendor/imgui"));
            t.addIncludePath(b.path("vendor"));
            t.linkSystemLibrary("wayland-client");
            t.linkSystemLibrary("glfw3");
            test_step.dependOn(&b.addRunArtifact(t).step);
        }
    }
}
