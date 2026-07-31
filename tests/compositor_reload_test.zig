const std = @import("std");
const testing = std.testing;
const cmp = @import("compositor");

test "reload runs the configured command with injected env" {
    // Build a tmpdir containing a fake swaymsg that touches a marker file.
    const tmp = "/tmp/zigit-test-reload";
    try std.fs.makeDirAbsolute(tmp);
    defer std.fs.deleteTreeAbsolute(tmp) catch {};
    const marker = tmp ++ "/hit";
    const script = "#!/bin/sh\ntouch " ++ marker ++ "\n";
    const swaymsg_path = tmp ++ "/swaymsg";
    {
        const f = try std.fs.createFileAbsolute(swaymsg_path, .{ .mode = 0o755 });
        defer f.close();
        try f.writeAll(script);
    }

    // No-op case: must succeed without touching the filesystem.
    try cmp.reload(testing.allocator, .none);

    // Real case: pass env_map with PATH=tmp so runCommand's spawned swaymsg resolves there.
    var env = std.process.EnvMap.init(testing.allocator);
    defer env.deinit();
    try env.put("PATH", tmp ++ ":/usr/local/bin:/usr/bin:/bin");
    try cmp.reloadWithEnv(testing.allocator, .swaymsg, &env);
    const exists = !std.meta.isError(std.fs.accessAbsolute(marker, .{}));
    try testing.expect(exists);
}

test "KDE reload refreshes services and restarts global shortcuts" {
    const tmp = "/tmp/zigit-test-kde-reload";
    try std.fs.makeDirAbsolute(tmp);
    defer std.fs.deleteTreeAbsolute(tmp) catch {};
    const cache_marker = tmp ++ "/cache";
    const restart_marker = tmp ++ "/restart";
    try writeScript(tmp ++ "/kbuildsycoca6", "#!/bin/sh\n/usr/bin/touch " ++ cache_marker ++ "\n");
    try writeScript(tmp ++ "/systemctl", "#!/bin/sh\n/usr/bin/touch " ++ restart_marker ++ "\n");

    var env = std.process.EnvMap.init(testing.allocator);
    defer env.deinit();
    try env.put("PATH", tmp);
    try cmp.reloadWithEnv(testing.allocator, .kglobalaccel, &env);
    try testing.expect(!std.meta.isError(std.fs.accessAbsolute(cache_marker, .{})));
    try testing.expect(!std.meta.isError(std.fs.accessAbsolute(restart_marker, .{})));
}

fn writeScript(path: []const u8, content: []const u8) !void {
    const file = try std.fs.createFileAbsolute(path, .{ .mode = 0o755 });
    defer file.close();
    try file.writeAll(content);
}
