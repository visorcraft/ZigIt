const std = @import("std");
const app_io = @import("app_io");
const testing = std.testing;
const cmp = @import("compositor");

const labwc_rc =
    "<?xml version=\"1.0\"?>\n" ++
    "<openbox_config>\n" ++
    "  <keyboard>\n" ++
    "    <keybind key=\"W-q\"><action name=\"Close\"/></keybind>\n" ++
    "  </keyboard>\n" ++
    "</openbox_config>\n";

const kde_rc =
    "[kwin]\n" ++
    "_k_friendly_name=KWin\n" ++
    "\n" ++
    "[plasmashell]\n" ++
    "activate widget 4=Meta+V,none,Clipboard\n";

fn freeBinding(b: cmp.Binding) void {
    testing.allocator.free(b.snippet);
    testing.allocator.free(b.snippetPath);
}

test "labwc uninstall removes only the zigit block" {
    const home = "/tmp/zigit-test-uninstall-labwc";
    try std.Io.Dir.createDirAbsolute(app_io.get(), home, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(app_io.get(), home) catch {};

    const dir = home ++ "/.config/labwc";
    try std.Io.Dir.cwd().createDirPath(app_io.get(), dir);
    try writeAbsolute(dir ++ "/rc.xml", labwc_rc);

    const b = try cmp.install(testing.allocator, .labwc, home, "Print", "zigit capture --overlay");
    defer freeBinding(b);

    // Sanity: the marker block is present after install.
    {
        const content = try readAbsolute(b.snippetPath);
        defer testing.allocator.free(content);
        try testing.expect(std.mem.indexOf(u8, content, "<!-- BEGIN ZIGIT -->") != null);
    }

    try cmp.uninstall(testing.allocator, .labwc, b);

    const content = try readAbsolute(b.snippetPath);
    defer testing.allocator.free(content);
    try testing.expectEqualStrings(labwc_rc, content);
}

test "kde uninstall removes only the ZigIt service section" {
    const home = "/tmp/zigit-test-uninstall-kde";
    try std.Io.Dir.createDirAbsolute(app_io.get(), home, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(app_io.get(), home) catch {};

    const dir = home ++ "/.config";
    try std.Io.Dir.cwd().createDirPath(app_io.get(), dir);
    try writeAbsolute(dir ++ "/kglobalshortcutsrc", kde_rc);

    const b = try cmp.install(testing.allocator, .kde, home, "Print", "zigit capture --overlay");
    defer freeBinding(b);

    {
        const content = try readAbsolute(b.snippetPath);
        defer testing.allocator.free(content);
        try testing.expect(std.mem.indexOf(u8, content, "[services][com.visorcraft.zigit.desktop]") != null);
    }

    try cmp.uninstall(testing.allocator, .kde, b);

    const content = try readAbsolute(b.snippetPath);
    defer testing.allocator.free(content);
    try testing.expectEqualStrings(kde_rc, content);
}

test "kde uninstall keeps following sections when zigit is mid-file" {
    const home = "/tmp/zigit-test-uninstall-kde-mid";
    try std.Io.Dir.createDirAbsolute(app_io.get(), home, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(app_io.get(), home) catch {};

    const dir = home ++ "/.config";
    try std.Io.Dir.cwd().createDirPath(app_io.get(), dir);
    const initial = kde_rc ++ "\n[zigit]\n_s=Print,old,none,old\n\n[other]\nfoo=bar\n";
    try writeAbsolute(dir ++ "/kglobalshortcutsrc", initial);

    const b = try cmp.install(testing.allocator, .kde, home, "Print", "zigit capture --overlay");
    defer freeBinding(b);

    const content = try readAbsolute(b.snippetPath);
    defer testing.allocator.free(content);
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, content, "[services][com.visorcraft.zigit.desktop]"));
    try testing.expect(std.mem.indexOf(u8, content, "_launch=Print") != null);
    try testing.expect(std.mem.indexOf(u8, content, "[other]\nfoo=bar") != null);
    try testing.expect(std.mem.indexOf(u8, content, "old") == null);
}

test "kde uninstall restores a replaced Spectacle shortcut" {
    const home = "/tmp/zigit-test-uninstall-kde-spectacle";
    try std.Io.Dir.createDirAbsolute(app_io.get(), home, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(app_io.get(), home) catch {};

    const dir = home ++ "/.config";
    try std.Io.Dir.cwd().createDirPath(app_io.get(), dir);
    const initial =
        "[services][org.kde.spectacle.desktop]\n" ++
        "OpenWithoutScreenshot=none\n";
    try writeAbsolute(dir ++ "/kglobalshortcutsrc", initial);

    const b = try cmp.install(testing.allocator, .kde, home, "Print", "zigit capture --overlay");
    defer freeBinding(b);
    const owner = cmp.ShortcutOwner{
        .component = @constCast("org.kde.spectacle.desktop"),
        .action = @constCast("_launch"),
        .name = @constCast("Spectacle"),
    };
    try cmp.overrideKdeShortcut(testing.allocator, home, owner);

    {
        const content = try readAbsolute(b.snippetPath);
        defer testing.allocator.free(content);
        try testing.expect(std.mem.indexOf(u8, content, "_launch=none") != null);
    }

    try cmp.uninstall(testing.allocator, .kde, b);
    const content = try readAbsolute(b.snippetPath);
    defer testing.allocator.free(content);
    try testing.expectEqualStrings(initial, content);
    try testing.expectError(error.FileNotFound, std.Io.Dir.openFileAbsolute(app_io.get(), home ++ "/.local/share/applications/com.visorcraft.zigit.desktop", .{}));
}

test "changing KDE hotkey restores the previous Spectacle shortcut" {
    const home = "/tmp/zigit-test-change-kde-shortcut";
    try std.Io.Dir.createDirAbsolute(app_io.get(), home, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(app_io.get(), home) catch {};

    const dir = home ++ "/.config";
    try std.Io.Dir.cwd().createDirPath(app_io.get(), dir);
    const initial =
        "[services][org.kde.spectacle.desktop]\n" ++
        "OpenWithoutScreenshot=none\n";
    try writeAbsolute(dir ++ "/kglobalshortcutsrc", initial);
    const first = try cmp.install(testing.allocator, .kde, home, "Print", "zigit capture --overlay");
    defer freeBinding(first);
    const owner = cmp.ShortcutOwner{
        .component = @constCast("org.kde.spectacle.desktop"),
        .action = @constCast("_launch"),
        .name = @constCast("Spectacle"),
    };
    try cmp.overrideKdeShortcut(testing.allocator, home, owner);

    const second = try cmp.install(testing.allocator, .kde, home, "Super+Shift+S", "zigit capture --overlay");
    defer freeBinding(second);
    const content = try readAbsolute(second.snippetPath);
    defer testing.allocator.free(content);
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, content, "_launch="));
    try testing.expect(std.mem.indexOf(u8, content, "_launch=Meta+Shift+S") != null);
    try testing.expectError(error.FileNotFound, std.Io.Dir.openFileAbsolute(app_io.get(), home ++ "/.config/zigit/kde-shortcut-backup", .{}));
}

test "sway uninstall deletes the dedicated file" {
    const home = "/tmp/zigit-test-uninstall-sway";
    try std.Io.Dir.createDirAbsolute(app_io.get(), home, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(app_io.get(), home) catch {};

    const b = try cmp.install(testing.allocator, .sway, home, "Print", "zigit capture --overlay");
    defer freeBinding(b);

    try cmp.uninstall(testing.allocator, .sway, b);

    try testing.expectError(error.FileNotFound, std.Io.Dir.openFileAbsolute(app_io.get(), b.snippetPath, .{}));
}

test "uninstall is a no-op when file is missing or has no zigit content" {
    const home = "/tmp/zigit-test-uninstall-noop";
    try std.Io.Dir.createDirAbsolute(app_io.get(), home, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(app_io.get(), home) catch {};

    const missing = try std.fs.path.join(testing.allocator, &.{ home, "nope.conf" });
    defer testing.allocator.free(missing);
    try cmp.uninstall(testing.allocator, .sway, .{
        .snippetPath = missing,
        .reload = .none,
        .snippet = @constCast(""),
    });

    const dir = home ++ "/.config/labwc";
    try std.Io.Dir.cwd().createDirPath(app_io.get(), dir);
    try writeAbsolute(dir ++ "/rc.xml", labwc_rc);
    const path = try std.fs.path.join(testing.allocator, &.{ dir, "rc.xml" });
    defer testing.allocator.free(path);
    try cmp.uninstall(testing.allocator, .labwc, .{
        .snippetPath = path,
        .reload = .none,
        .snippet = @constCast(""),
    });

    const content = try readAbsolute(path);
    defer testing.allocator.free(content);
    try testing.expectEqualStrings(labwc_rc, content);
}

test "gnome uninstall is unsupported" {
    try testing.expectError(error.UnsupportedCompositor, cmp.uninstall(testing.allocator, .gnome, .{
        .snippetPath = @constCast("/tmp/zigit-test-uninstall-gnome"),
        .reload = .none,
        .snippet = @constCast(""),
    }));
}

fn writeAbsolute(path: []const u8, content: []const u8) !void {
    const f = try std.Io.Dir.createFileAbsolute(app_io.get(), path, .{ .truncate = true });
    defer f.close(app_io.get());
    try f.writeStreamingAll(app_io.get(), content);
}

fn readAbsolute(path: []const u8) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(app_io.get(), path, testing.allocator, .limited(1 << 22));
}
