const std = @import("std");
const testing = std.testing;
const cmp = @import("compositor");

const EnvSlice = []const []const u8;

fn detectWith(env: EnvSlice) !cmp.Compositor {
    var map = std.process.EnvMap.init(testing.allocator);
    defer map.deinit();
    for (env) |kv| {
        const eq = std.mem.indexOfScalar(u8, kv, '=').?;
        try map.put(kv[0..eq], kv[eq + 1 ..]);
    }
    return cmp.detect(&map);
}

test "sway detected by SWAYSOCK" {
    try testing.expectEqual(cmp.Compositor.sway, try detectWith(&.{"SWAYSOCK=/run/user/1000/sway-ipc.sock"}));
}

test "hyprland detected by HYPRLAND_INSTANCE_SIGNATURE" {
    try testing.expectEqual(cmp.Compositor.hyprland, try detectWith(&.{"HYPRLAND_INSTANCE_SIGNATURE=abc"}));
}

test "unknown when no markers" {
    try testing.expectEqual(cmp.Compositor.unknown, try detectWith(&.{}));
}

test "river detected by socket in XDG_RUNTIME_DIR" {
    const tmp = "/tmp/zigit-test-rt";
    try std.fs.makeDirAbsolute(tmp);
    defer std.fs.deleteTreeAbsolute(tmp) catch {};
    // Create a dummy river.sock file (empty; we only stat it).
    {
        const f = try std.fs.createFileAbsolute(tmp ++ "/river.sock", .{});
        f.close();
    }
    try testing.expectEqual(cmp.Compositor.river, try detectWith(&.{"XDG_RUNTIME_DIR=" ++ tmp}));
}

test "labwc detected by socket in XDG_RUNTIME_DIR" {
    const tmp = "/tmp/zigit-test-rt-labwc";
    try std.fs.makeDirAbsolute(tmp);
    defer std.fs.deleteTreeAbsolute(tmp) catch {};
    {
        const f = try std.fs.createFileAbsolute(tmp ++ "/labwc.sock", .{});
        f.close();
    }
    try testing.expectEqual(cmp.Compositor.labwc, try detectWith(&.{"XDG_RUNTIME_DIR=" ++ tmp}));
}

test "KDE hotkeys convert to Qt key codes" {
    try testing.expectEqual(@as(?i32, 0x01000009), cmp.qtKeyForHotkey("Print"));
    try testing.expectEqual(@as(?i32, 0x12000053), cmp.qtKeyForHotkey("Super+Shift+S"));
    try testing.expect(cmp.qtKeyForHotkey("Nope") == null);
}
