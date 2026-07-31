const std = @import("std");

pub const Error = error{WlCopyMissing};

pub fn copyPNG(allocator: std.mem.Allocator, png_bytes: []const u8) !void {
    var child = std.process.Child.init(&.{ "wl-copy", "--type", "image/png" }, allocator);
    child.stdin_behavior = .Pipe;
    child.stdout_behavior = .Ignore;
    // stderr must NOT be a pipe: wl-copy forks a background servant that
    // inherits our stderr and holds it open while it serves the selection,
    // so a drain thread would never see EOF and join() would deadlock.
    child.stderr_behavior = .Ignore;
    child.spawn() catch |e| switch (e) {
        error.FileNotFound => return error.WlCopyMissing,
        else => return e,
    };
    // Note: on POSIX a failed exec (e.g. wl-copy not on PATH) is reported via
    // the child's error pipe and only surfaces from wait(), not spawn().
    var write_failed = false;
    if (child.stdin) |*stdin| {
        stdin.writeAll(png_bytes) catch {
            // Child may have died already (bad exec or early exit); wait()
            // below reaps it and reports the more specific error.
            write_failed = true;
        };
        stdin.close();
        child.stdin = null;
    }
    const term = child.wait() catch |e| switch (e) {
        error.FileNotFound => return error.WlCopyMissing,
        else => return e,
    };
    if (write_failed) return error.WlCopyFailed;
    switch (term) {
        .Exited => |code| if (code != 0) return error.WlCopyFailed,
        else => return error.WlCopyFailed,
    }
}

pub fn copyPNGToFile(allocator: std.mem.Allocator, path: []const u8) !void {
    const bytes = try std.fs.cwd().readFileAlloc(allocator, path, 16 * 1024 * 1024);
    defer allocator.free(bytes);
    try copyPNG(allocator, bytes);
}
