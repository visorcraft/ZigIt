const std = @import("std");
const testing = std.testing;
const cmp = @import("compositor");

test "install writes sway snippet and marks swaymsg reload" {
    const home = "/tmp/zigit-test-home";
    try std.fs.makeDirAbsolute(home);
    defer std.fs.deleteTreeAbsolute(home) catch {};

    const b = try cmp.install(testing.allocator, .sway, home, "Print", "zigit capture --overlay");
    defer testing.allocator.free(b.snippet);
    defer testing.allocator.free(b.snippetPath);

    try testing.expectEqual(cmp.Reload.swaymsg, b.reload);
    try testing.expect(std.mem.endsWith(u8, b.snippetPath, "config.d/zigit.conf"));

    const content = try std.fs.cwd().readFileAlloc(testing.allocator, b.snippetPath, 1 << 16);
    defer testing.allocator.free(content);
    try testing.expect(std.mem.indexOf(u8, content, "Print") != null);
    try testing.expect(std.mem.indexOf(u8, content, "zigit capture --overlay") != null);
}

test "install writes hyprland snippet" {
    const home = "/tmp/zigit-test-home-2";
    try std.fs.makeDirAbsolute(home);
    defer std.fs.deleteTreeAbsolute(home) catch {};

    const b = try cmp.install(testing.allocator, .hyprland, home, "Print", "zigit capture --overlay");
    defer testing.allocator.free(b.snippet);
    defer testing.allocator.free(b.snippetPath);

    try testing.expectEqual(cmp.Reload.hyprctl, b.reload);
    const content = try std.fs.cwd().readFileAlloc(testing.allocator, b.snippetPath, 1 << 16);
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
    try std.fs.makeDirAbsolute(home);
    defer std.fs.deleteTreeAbsolute(home) catch {};

    const b1 = try cmp.install(testing.allocator, .sway, home, "Print", "zigit capture --overlay");
    testing.allocator.free(b1.snippet);
    testing.allocator.free(b1.snippetPath);
    const b2 = try cmp.install(testing.allocator, .sway, home, "Print", "zigit capture --overlay");
    defer testing.allocator.free(b2.snippet);
    defer testing.allocator.free(b2.snippetPath);

    const content = try std.fs.cwd().readFileAlloc(testing.allocator, b2.snippetPath, 1 << 22);
    defer testing.allocator.free(content);
    try testing.expectEqualStrings(b2.snippet, content);
}

test "labwc double install yields exactly one marker block" {
    const home = "/tmp/zigit-test-home-6";
    try std.fs.makeDirAbsolute(home);
    defer std.fs.deleteTreeAbsolute(home) catch {};

    const b1 = try cmp.install(testing.allocator, .labwc, home, "Print", "zigit capture --overlay");
    testing.allocator.free(b1.snippet);
    const b2 = try cmp.install(testing.allocator, .labwc, home, "Print", "zigit capture --overlay");
    defer testing.allocator.free(b2.snippet);
    defer testing.allocator.free(b2.snippetPath);
    testing.allocator.free(b1.snippetPath);

    const content = try std.fs.cwd().readFileAlloc(testing.allocator, b2.snippetPath, 1 << 22);
    defer testing.allocator.free(content);
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, content, "<!-- BEGIN ZIGIT -->"));
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, content, "<!-- END ZIGIT -->"));
}

test "kde install writes one service shortcut and launcher" {
    const home = "/tmp/zigit-test-home-7";
    try std.fs.makeDirAbsolute(home);
    defer std.fs.deleteTreeAbsolute(home) catch {};

    const b1 = try cmp.install(testing.allocator, .kde, home, "Print", "zigit capture --overlay");
    testing.allocator.free(b1.snippet);
    const b2 = try cmp.install(testing.allocator, .kde, home, "Print", "zigit capture --overlay");
    defer testing.allocator.free(b2.snippet);
    defer testing.allocator.free(b2.snippetPath);
    testing.allocator.free(b1.snippetPath);

    const content = try std.fs.cwd().readFileAlloc(testing.allocator, b2.snippetPath, 1 << 22);
    defer testing.allocator.free(content);
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, content, "[services][com.visorcraft.zigit.desktop]"));
    try testing.expect(std.mem.indexOf(u8, content, "_launch=Print") != null);

    const desktop = try std.fs.cwd().readFileAlloc(testing.allocator, home ++ "/.local/share/applications/com.visorcraft.zigit.desktop", 1 << 16);
    defer testing.allocator.free(desktop);
    try testing.expect(std.mem.indexOf(u8, desktop, "Exec=zigit capture --overlay") != null);
    try testing.expect(std.mem.indexOf(u8, desktop, "X-KDE-Shortcuts=Print") != null);
}

test "install reads pre-existing config larger than 64 KiB" {
    const home = "/tmp/zigit-test-home-8";
    try std.fs.makeDirAbsolute(home);
    defer std.fs.deleteTreeAbsolute(home) catch {};

    const dir = home ++ "/.config/labwc";
    try std.fs.cwd().makePath(dir);
    const padding = "x" ** (128 * 1024);
    {
        const f = try std.fs.createFileAbsolute(dir ++ "/rc.xml", .{});
        defer f.close();
        try f.writeAll(padding);
    }

    const b = try cmp.install(testing.allocator, .labwc, home, "Print", "zigit capture --overlay");
    defer testing.allocator.free(b.snippet);
    defer testing.allocator.free(b.snippetPath);

    const content = try std.fs.cwd().readFileAlloc(testing.allocator, b.snippetPath, 1 << 22);
    defer testing.allocator.free(content);
    try testing.expect(std.mem.startsWith(u8, content, padding));
    try testing.expect(std.mem.indexOf(u8, content, "<!-- BEGIN ZIGIT -->") != null);
}
