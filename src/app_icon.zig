const std = @import("std");
const app_io = @import("app_io");

/// Freedesktop application id / icon name / desktop file id (without .desktop).
pub const app_id = "com.visorcraft.zigit";

// RGBA pixels for glfwSetWindowIcon (little help on pure Wayland, useful on X11
// and for compositors that still honor it).
const icon48_rgba = @embedFile("assets/icon_48.rgba");
const icon128_rgba = @embedFile("assets/icon_128.rgba");

// PNG payloads installed into the user icon theme so Wayland titlebars and
// taskbars resolve `Icon=com.visorcraft.zigit` via the desktop file.
const icon_pngs = [_]struct { size: []const u8, bytes: []const u8 }{
    .{ .size = "16x16", .bytes = @embedFile("assets/icon_16.png") },
    .{ .size = "24x24", .bytes = @embedFile("assets/icon_24.png") },
    .{ .size = "32x32", .bytes = @embedFile("assets/icon_32.png") },
    .{ .size = "48x48", .bytes = @embedFile("assets/icon_48.png") },
    .{ .size = "64x64", .bytes = @embedFile("assets/icon_64.png") },
    .{ .size = "96x96", .bytes = @embedFile("assets/icon_96.png") },
    .{ .size = "128x128", .bytes = @embedFile("assets/icon_128.png") },
    .{ .size = "192x192", .bytes = @embedFile("assets/icon_192.png") },
    .{ .size = "256x256", .bytes = @embedFile("assets/icon_256.png") },
    .{ .size = "512x512", .bytes = @embedFile("assets/icon_512.png") },
};

const desktop_entry =
    \\[Desktop Entry]
    \\Type=Application
    \\Name=ZigIt
    \\GenericName=Screenshot Tool
    \\Comment=Fast screenshots, clipboard handoff, and annotation for Wayland
    \\Keywords=screenshot;capture;annotate;wayland;
    \\Exec=zigit daemon
    \\Icon=com.visorcraft.zigit
    \\Terminal=false
    \\StartupWMClass=zigit
    \\Categories=Utility;Graphics;
    \\
;

/// Apply GLFW window hints that identify ZigIt to the compositor. Call before
/// `glfwCreateWindow`.
pub fn applyWindowHints(c: anytype) void {
    // Wayland app_id must match the desktop file basename so the shell can
    // look up Icon=com.visorcraft.zigit in the icon theme.
    c.glfwWindowHintString(c.GLFW_WAYLAND_APP_ID, app_id);
}

/// Set the window icon from embedded RGBA (best-effort; no-op on some Wayland
/// compositors that only use the desktop-file icon).
pub fn setWindowIcon(c: anytype, window: anytype) void {
    var images = [_]c.GLFWimage{
        .{
            .width = 48,
            .height = 48,
            .pixels = @constCast(icon48_rgba.ptr),
        },
        .{
            .width = 128,
            .height = 128,
            .pixels = @constCast(icon128_rgba.ptr),
        },
    };
    c.glfwSetWindowIcon(window, @intCast(images.len), &images);
}

/// Install icons + desktop entry under `$XDG_DATA_HOME` (default
/// `~/.local/share`) so the Wayland shell can resolve the app icon.
/// Best-effort: failures are logged and ignored so the UI still starts.
pub fn installUserChrome(allocator: std.mem.Allocator) void {
    installUserChromeInner(allocator) catch |e| {
        std.debug.print("zigit: could not install desktop icons: {s}\n", .{@errorName(e)});
    };
}

fn installUserChromeInner(allocator: std.mem.Allocator) !void {
    const io = app_io.get();
    const data_home = try dataHome(allocator);
    defer allocator.free(data_home);

    // Icons: ~/.local/share/icons/hicolor/<size>/apps/com.visorcraft.zigit.png
    for (icon_pngs) |entry| {
        const dir = try std.fmt.allocPrint(allocator, "{s}/icons/hicolor/{s}/apps", .{ data_home, entry.size });
        defer allocator.free(dir);
        try std.Io.Dir.cwd().createDirPath(io, dir);
        const path = try std.fmt.allocPrint(allocator, "{s}/{s}.png", .{ dir, app_id });
        defer allocator.free(path);
        try writeIfChanged(path, entry.bytes);
    }

    // Desktop file: ~/.local/share/applications/com.visorcraft.zigit.desktop
    // Only write if missing or still using the old generic Icon=camera-photo /
    // no Icon line: do not clobber a user-customized entry that already has
    // our icon name.
    const apps_dir = try std.fmt.allocPrint(allocator, "{s}/applications", .{data_home});
    defer allocator.free(apps_dir);
    try std.Io.Dir.cwd().createDirPath(io, apps_dir);
    const desktop_path = try std.fmt.allocPrint(allocator, "{s}/{s}.desktop", .{ apps_dir, app_id });
    defer allocator.free(desktop_path);
    try installDesktopFile(desktop_path);

    // Refresh icon cache when the tool is present (best-effort).
    var hicolor_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const hicolor = std.fmt.bufPrint(&hicolor_buf, "{s}/icons/hicolor", .{data_home}) catch return;
    _ = std.process.spawn(io, .{
        .argv = &.{ "gtk-update-icon-cache", "-f", "-t", hicolor },
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
    }) catch {};
}

fn installDesktopFile(path: []const u8) !void {
    const io = app_io.get();
    if (std.Io.Dir.cwd().readFileAlloc(io, path, std.heap.page_allocator, .limited(1 << 16))) |existing| {
        defer std.heap.page_allocator.free(existing);
        // Already ours with the correct icon; leave alone.
        if (std.mem.indexOf(u8, existing, "Icon=com.visorcraft.zigit") != null) return;
        // KDE capture-only launcher (NoDisplay=true) is managed separately;
        // if this is that file, still rewrite Icon= but preserve Exec/shortcuts
        // when possible. Simple path: if NoDisplay is set, just patch Icon.
        if (std.mem.indexOf(u8, existing, "NoDisplay=true") != null) {
            if (std.mem.indexOf(u8, existing, "Icon=")) |icon_at| {
                // Replace the Icon= line value.
                const line_end = std.mem.indexOfScalarPos(u8, existing, icon_at, '\n') orelse existing.len;
                var rebuilt: std.array_list.Managed(u8) = .init(std.heap.page_allocator);
                defer rebuilt.deinit();
                try rebuilt.appendSlice(existing[0..icon_at]);
                try rebuilt.appendSlice("Icon=com.visorcraft.zigit");
                try rebuilt.appendSlice(existing[line_end..]);
                try writeIfChanged(path, rebuilt.items);
                return;
            }
        }
    } else |_| {}
    try writeIfChanged(path, desktop_entry);
}

fn writeIfChanged(path: []const u8, bytes: []const u8) !void {
    const io = app_io.get();
    if (std.Io.Dir.cwd().readFileAlloc(io, path, std.heap.page_allocator, .limited(1 << 20))) |existing| {
        defer std.heap.page_allocator.free(existing);
        if (std.mem.eql(u8, existing, bytes)) return;
    } else |_| {}
    const f = try std.Io.Dir.createFileAbsolute(io, path, .{ .truncate = true });
    defer f.close(io);
    try f.writeStreamingAll(io, bytes);
}

fn dataHome(allocator: std.mem.Allocator) ![]u8 {
    if (std.c.getenv("XDG_DATA_HOME")) |z| {
        const v = std.mem.span(z);
        if (v.len > 0) return try allocator.dupe(u8, v);
    }
    const home_z = std.c.getenv("HOME") orelse return error.NoHome;
    const home = std.mem.span(home_z);
    return try std.fs.path.join(allocator, &.{ home, ".local/share" });
}
