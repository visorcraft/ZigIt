const std = @import("std");
const app_io = @import("app_io");
const testing = std.testing;
const cmp = @import("compositor");

test "install writes sway snippet and marks swaymsg reload" {
    const home = "/tmp/zigit-test-home";
    try std.Io.Dir.createDirAbsolute(app_io.get(), home, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(app_io.get(), home) catch {};

    const b = try cmp.install(testing.allocator, .sway, home, "Print", "zigit capture --overlay");
    defer testing.allocator.free(b.snippet);
    defer testing.allocator.free(b.snippetPath);

    try testing.expectEqual(cmp.Reload.swaymsg, b.reload);
    try testing.expect(std.mem.endsWith(u8, b.snippetPath, "config.d/zigit.conf"));

    const content = try std.Io.Dir.cwd().readFileAlloc(app_io.get(), b.snippetPath, testing.allocator, .limited(1 << 16));
    defer testing.allocator.free(content);
    try testing.expect(std.mem.indexOf(u8, content, "Print") != null);
    try testing.expect(std.mem.indexOf(u8, content, "zigit capture --overlay") != null);
}

test "install writes hyprland snippet" {
    const home = "/tmp/zigit-test-home-2";
    try std.Io.Dir.createDirAbsolute(app_io.get(), home, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(app_io.get(), home) catch {};

    const b = try cmp.install(testing.allocator, .hyprland, home, "Print", "zigit capture --overlay");
    defer testing.allocator.free(b.snippet);
    defer testing.allocator.free(b.snippetPath);

    try testing.expectEqual(cmp.Reload.hyprctl, b.reload);
    const content = try std.Io.Dir.cwd().readFileAlloc(app_io.get(), b.snippetPath, testing.allocator, .limited(1 << 16));
    defer testing.allocator.free(content);
    try testing.expect(std.mem.indexOf(u8, content, "bind = , Print") != null);
}

test "install returns error for unknown compositor" {
    try std.testing.expectError(error.UnsupportedCompositor, cmp.install(testing.allocator, .unknown, "/tmp/zigit-test-home-3", "Print", "x"));
}

test "install returns error for gnome" {
    try std.testing.expectError(error.UnsupportedCompositor, cmp.install(testing.allocator, .gnome, "/tmp/zigit-test-home-4", "Print", "x"));
}

test "double install keeps exactly one snippet (dedicated file)" {
    const home = "/tmp/zigit-test-home-5";
    try std.Io.Dir.createDirAbsolute(app_io.get(), home, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(app_io.get(), home) catch {};

    const b1 = try cmp.install(testing.allocator, .sway, home, "Print", "zigit capture --overlay");
    testing.allocator.free(b1.snippet);
    testing.allocator.free(b1.snippetPath);
    const b2 = try cmp.install(testing.allocator, .sway, home, "Print", "zigit capture --overlay");
    defer testing.allocator.free(b2.snippet);
    defer testing.allocator.free(b2.snippetPath);

    const content = try std.Io.Dir.cwd().readFileAlloc(app_io.get(), b2.snippetPath, testing.allocator, .limited(1 << 22));
    defer testing.allocator.free(content);
    try testing.expectEqualStrings(b2.snippet, content);
}

test "labwc double install yields exactly one marker block" {
    const home = "/tmp/zigit-test-home-6";
    try std.Io.Dir.createDirAbsolute(app_io.get(), home, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(app_io.get(), home) catch {};

    const b1 = try cmp.install(testing.allocator, .labwc, home, "Print", "zigit capture --overlay");
    testing.allocator.free(b1.snippet);
    const b2 = try cmp.install(testing.allocator, .labwc, home, "Print", "zigit capture --overlay");
    defer testing.allocator.free(b2.snippet);
    defer testing.allocator.free(b2.snippetPath);
    testing.allocator.free(b1.snippetPath);

    const content = try std.Io.Dir.cwd().readFileAlloc(app_io.get(), b2.snippetPath, testing.allocator, .limited(1 << 22));
    defer testing.allocator.free(content);
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, content, "<!-- BEGIN ZIGIT -->"));
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, content, "<!-- END ZIGIT -->"));
}

test "kde install writes one service shortcut and launcher" {
    const home = "/tmp/zigit-test-home-7";
    try std.Io.Dir.createDirAbsolute(app_io.get(), home, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(app_io.get(), home) catch {};

    const b1 = try cmp.install(testing.allocator, .kde, home, "Print", "zigit capture --overlay");
    testing.allocator.free(b1.snippet);
    const b2 = try cmp.install(testing.allocator, .kde, home, "Print", "zigit capture --overlay");
    defer testing.allocator.free(b2.snippet);
    defer testing.allocator.free(b2.snippetPath);
    testing.allocator.free(b1.snippetPath);

    const content = try std.Io.Dir.cwd().readFileAlloc(app_io.get(), b2.snippetPath, testing.allocator, .limited(1 << 22));
    defer testing.allocator.free(content);
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, content, "[services][com.visorcraft.zigit.desktop]"));
    try testing.expect(std.mem.indexOf(u8, content, "_launch=Print") != null);

    const desktop = try std.Io.Dir.cwd().readFileAlloc(app_io.get(), home ++ "/.local/share/applications/com.visorcraft.zigit.desktop", testing.allocator, .limited(1 << 16));
    defer testing.allocator.free(desktop);
    try testing.expect(std.mem.indexOf(u8, desktop, "Exec=zigit capture --overlay") != null);
    try testing.expect(std.mem.indexOf(u8, desktop, "X-KDE-Shortcuts=Print") != null);
    try testing.expect(std.mem.indexOf(u8, desktop, "Icon=com.visorcraft.zigit") != null);
}

test "install reads pre-existing config larger than 64 KiB" {
    const home = "/tmp/zigit-test-home-8";
    try std.Io.Dir.createDirAbsolute(app_io.get(), home, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(app_io.get(), home) catch {};

    const dir = home ++ "/.config/labwc";
    try std.Io.Dir.cwd().createDirPath(app_io.get(), dir);
    const padding = "x" ** (128 * 1024);
    {
        const f = try std.Io.Dir.createFileAbsolute(app_io.get(), dir ++ "/rc.xml", .{});
        defer f.close(app_io.get());
        try f.writeStreamingAll(app_io.get(), padding);
    }

    const b = try cmp.install(testing.allocator, .labwc, home, "Print", "zigit capture --overlay");
    defer testing.allocator.free(b.snippet);
    defer testing.allocator.free(b.snippetPath);

    const content = try std.Io.Dir.cwd().readFileAlloc(app_io.get(), b.snippetPath, testing.allocator, .limited(1 << 22));
    defer testing.allocator.free(content);
    try testing.expect(std.mem.startsWith(u8, content, padding));
    try testing.expect(std.mem.indexOf(u8, content, "<!-- BEGIN ZIGIT -->") != null);
}
