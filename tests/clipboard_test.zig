const std = @import("std");
const testing = std.testing;
const clipboard = @import("clipboard");

// Zig 0.13's std.process.Child resolves argv[0] against the parent process's
// own PATH (posix.getenvZ), not Child.env_map, so tests override the real
// PATH via libc setenv and restore it afterwards.
extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;

fn overridePath(new_path: [*:0]const u8) ![:0]u8 {
    const orig = try testing.allocator.dupeZ(u8, std.posix.getenv("PATH") orelse "");
    errdefer testing.allocator.free(orig);
    try testing.expectEqual(@as(c_int, 0), setenv("PATH", new_path, 1));
    return orig;
}

fn restorePath(orig: [:0]const u8) void {
    _ = setenv("PATH", orig, 1);
    testing.allocator.free(orig);
}

test "copyPNG spawns wl-copy with stdin piped" {
    const tmp = "/tmp/zigit-test-clipboard";
    std.fs.deleteTreeAbsolute(tmp) catch {};
    try std.fs.makeDirAbsolute(tmp);
    defer std.fs.deleteTreeAbsolute(tmp) catch {};

    const script = "#!/bin/sh\necho \"$@\" > " ++ tmp ++ "/args\ncat > " ++ tmp ++ "/stdin.bin\n";
    const wlcopy = tmp ++ "/wl-copy";
    {
        const f = try std.fs.createFileAbsolute(wlcopy, .{ .mode = 0o755 });
        defer f.close();
        try f.writeAll(script);
    }

    // Keep /usr/bin:/bin so the script's `cat` still resolves; the mock
    // wl-copy in tmp is found first.
    const orig_path = try overridePath(tmp ++ ":/usr/bin:/bin");
    defer restorePath(orig_path);

    try clipboard.copyPNG(testing.allocator, "PNG-BYTES-HERE");
    const args = try std.fs.cwd().readFileAlloc(testing.allocator, tmp ++ "/args", 1 << 16);
    defer testing.allocator.free(args);
    try testing.expect(std.mem.indexOf(u8, args, "--type") != null);
    try testing.expect(std.mem.indexOf(u8, args, "image/png") != null);

    const stdin = try std.fs.cwd().readFileAlloc(testing.allocator, tmp ++ "/stdin.bin", 1 << 16);
    defer testing.allocator.free(stdin);
    try testing.expectEqualStrings("PNG-BYTES-HERE", stdin);
}

test "copyPNG returns error.WlCopyMissing when binary not found" {
    const orig_path = try overridePath("/nonexistent");
    defer restorePath(orig_path);
    try testing.expectError(error.WlCopyMissing, clipboard.copyPNG(testing.allocator, "x"));
}

test "copyPNG returns error.WlCopyFailed when wl-copy exits non-zero" {
    const tmp = "/tmp/zigit-test-clipboard-fail";
    std.fs.deleteTreeAbsolute(tmp) catch {};
    try std.fs.makeDirAbsolute(tmp);
    defer std.fs.deleteTreeAbsolute(tmp) catch {};

    // The mock writes to stderr (now ignored) and exits non-zero.
    const script = "#!/bin/sh\necho 'mock wl-copy failure' >&2\nexit 1\n";
    const wlcopy = tmp ++ "/wl-copy";
    {
        const f = try std.fs.createFileAbsolute(wlcopy, .{ .mode = 0o755 });
        defer f.close();
        try f.writeAll(script);
    }

    const orig_path = try overridePath(tmp ++ ":/usr/bin:/bin");
    defer restorePath(orig_path);

    try testing.expectError(error.WlCopyFailed, clipboard.copyPNG(testing.allocator, "PNG-BYTES-HERE"));
}
