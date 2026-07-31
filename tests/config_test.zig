const std = @import("std");
const testing = std.testing;
const cfg = @import("config");

test "defaults returns sensible paths" {
    const c = cfg.Config.defaults();
    try testing.expect(c.hotkey.len > 0);
    try testing.expect(c.theme == .dark or c.theme == .light);
    try testing.expect(c.marquee_position == .top_right or
        c.marquee_position == .top_left or
        c.marquee_position == .bottom_right or
        c.marquee_position == .bottom_left);
}

test "load returns defaults when config file missing" {
    const c = try cfg.Config.load(testing.allocator, "/nonexistent");
    defer c.deinit(testing.allocator);
    try testing.expectEqualStrings("Print", c.hotkey);
    try testing.expect(c.theme == .dark);
    try testing.expect(c.marquee_position == .top_right);
}

test "load parses full schema" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(.{
        .sub_path = "config.toml",
        .data =
        \\hotkey = "Super+Shift+S"
        \\save_dir = "/tmp/shots"
        \\marquee_position = "bottom-left"
        \\theme = "light"
        \\default_color = "#00ff88"
        \\font_size = 22
        \\
        ,
    });
    const path = try tmp.dir.realpathAlloc(testing.allocator, "config.toml");
    defer testing.allocator.free(path);

    const c = try cfg.Config.load(testing.allocator, path);
    defer c.deinit(testing.allocator);
    try testing.expectEqualStrings("Super+Shift+S", c.hotkey);
    try testing.expectEqualStrings("/tmp/shots", c.save_dir);
    try testing.expect(c.marquee_position == .bottom_left);
    try testing.expect(c.theme == .light);
    try testing.expectEqual(@as(u8, 0x00), c.default_color_rgba[0]);
    try testing.expectEqual(@as(u8, 0xff), c.default_color_rgba[1]);
    try testing.expectEqual(@as(u8, 0x88), c.default_color_rgba[2]);
    try testing.expectEqual(@as(u32, 22), c.default_font_size);
}

test "save round-trips preferences" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    // Real absolute path under the tmp dir.
    const dir_path = try tmp.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(dir_path);
    const path = try std.fs.path.join(testing.allocator, &.{ dir_path, "zigit", "config.toml" });
    defer testing.allocator.free(path);

    const original = cfg.Config{
        .save_dir = "/tmp/zigit-captures",
        .hotkey = "Print",
        .marquee_position = .top_left,
        .theme = .light,
        .default_color_rgba = .{ 0xaa, 0xbb, 0xcc, 0xff },
        .default_font_size = 20,
    };
    try original.save(path);

    const loaded = try cfg.Config.load(testing.allocator, path);
    defer loaded.deinit(testing.allocator);
    try testing.expectEqualStrings(original.save_dir, loaded.save_dir);
    try testing.expectEqualStrings(original.hotkey, loaded.hotkey);
    try testing.expect(loaded.marquee_position == .top_left);
    try testing.expect(loaded.theme == .light);
    try testing.expectEqual(@as(u8, 0xaa), loaded.default_color_rgba[0]);
    try testing.expectEqual(@as(u8, 0xbb), loaded.default_color_rgba[1]);
    try testing.expectEqual(@as(u8, 0xcc), loaded.default_color_rgba[2]);
    try testing.expectEqual(@as(u32, 20), loaded.default_font_size);
}

test "parseHexColor accepts rrggbb and rrggbbaa" {
    const a = cfg.parseHexColor("#ff3b30").?;
    try testing.expectEqual(@as(u8, 0xff), a[0]);
    try testing.expectEqual(@as(u8, 0x3b), a[1]);
    try testing.expectEqual(@as(u8, 0x30), a[2]);
    try testing.expectEqual(@as(u8, 0xff), a[3]);
    const b = cfg.parseHexColor("11223344").?;
    try testing.expectEqual(@as(u8, 0x11), b[0]);
    try testing.expectEqual(@as(u8, 0x44), b[3]);
    try testing.expect(cfg.parseHexColor("zz") == null);
}
