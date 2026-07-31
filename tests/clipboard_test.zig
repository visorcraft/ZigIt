const std = @import("std");
const app_io = @import("app_io");
const testing = std.testing;
const clipboard = @import("clipboard");

// Zig 0.13's std.process.Child resolves argv[0] against the parent process's
// own PATH (posix.getenvZ), not Child.env_map, so tests override the real
// PATH via libc setenv and restore it afterwards.
extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;

fn overridePath(new_path: [*:0]const u8) ![:0]u8 {
    const orig = try testing.allocator.dupeZ(u8, (if (std.c.getenv("PATH")) |z| std.mem.span(z) else null) orelse "");
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
    std.Io.Dir.cwd().deleteTree(app_io.get(), tmp) catch {};
    try std.Io.Dir.createDirAbsolute(app_io.get(), tmp, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(app_io.get(), tmp) catch {};

    const script = "#!/bin/sh\necho \"$@\" > " ++ tmp ++ "/args\ncat > " ++ tmp ++ "/stdin.bin\n";
    const wlcopy = tmp ++ "/wl-copy";
    {
        const f = try std.Io.Dir.createFileAbsolute(app_io.get(), wlcopy, .{ .permissions = .executable_file });
        defer f.close(app_io.get());
        try f.writeStreamingAll(app_io.get(), script);
    }

    // Keep /usr/bin:/bin so the script's `cat` still resolves; the mock
    // wl-copy in tmp is found first.
    const orig_path = try overridePath(tmp ++ ":/usr/bin:/bin");
    defer restorePath(orig_path);

    try clipboard.copyPNG(testing.allocator, "PNG-BYTES-HERE");
    const args = try std.Io.Dir.cwd().readFileAlloc(app_io.get(), tmp ++ "/args", testing.allocator, .limited(1 << 16));
    defer testing.allocator.free(args);
    try testing.expect(std.mem.indexOf(u8, args, "--type") != null);
    try testing.expect(std.mem.indexOf(u8, args, "image/png") != null);

    const stdin = try std.Io.Dir.cwd().readFileAlloc(app_io.get(), tmp ++ "/stdin.bin", testing.allocator, .limited(1 << 16));
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
    std.Io.Dir.cwd().deleteTree(app_io.get(), tmp) catch {};
    try std.Io.Dir.createDirAbsolute(app_io.get(), tmp, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(app_io.get(), tmp) catch {};

    // The mock writes to stderr (now ignored) and exits non-zero.
    const script = "#!/bin/sh\necho 'mock wl-copy failure' >&2\nexit 1\n";
    const wlcopy = tmp ++ "/wl-copy";
    {
        const f = try std.Io.Dir.createFileAbsolute(app_io.get(), wlcopy, .{ .permissions = .executable_file });
        defer f.close(app_io.get());
        try f.writeStreamingAll(app_io.get(), script);
    }

    const orig_path = try overridePath(tmp ++ ":/usr/bin:/bin");
    defer restorePath(orig_path);

    try testing.expectError(error.WlCopyFailed, clipboard.copyPNG(testing.allocator, "PNG-BYTES-HERE"));
}
