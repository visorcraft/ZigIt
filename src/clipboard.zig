const std = @import("std");
const app_io = @import("app_io");

pub const Error = error{WlCopyMissing};

pub fn copyPNG(allocator: std.mem.Allocator, png_bytes: []const u8) !void {
    _ = allocator;
    const io = app_io.get();
    var child = std.process.spawn(io, .{
        .argv = &.{ "wl-copy", "--type", "image/png" },
        .stdin = .pipe,
        .stdout = .ignore,
        // stderr must NOT be a pipe: wl-copy forks a background servant that
        // inherits our stderr and holds it open while it serves the selection,
        // so a drain thread would never see EOF and join() would deadlock.
        .stderr = .ignore,
    }) catch |e| switch (e) {
        error.FileNotFound => return error.WlCopyMissing,
        else => return e,
    };
    var write_failed = false;
    if (child.stdin) |stdin| {
        stdin.writeStreamingAll(io, png_bytes) catch {
            // Child may have died already (bad exec or early exit); wait()
            // below reaps it and reports the more specific error.
            write_failed = true;
        };
        stdin.close(io);
        child.stdin = null;
    }
    const term = try child.wait(io);
    if (write_failed) return error.WlCopyFailed;
    switch (term) {
        .exited => |code| if (code != 0) return error.WlCopyFailed,
        else => return error.WlCopyFailed,
    }
}

pub fn copyPNGToFile(allocator: std.mem.Allocator, path: []const u8) !void {
    const io = app_io.get();
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(16 * 1024 * 1024));
    defer allocator.free(bytes);
    try copyPNG(allocator, bytes);
}

/// Copy plain text to the clipboard via wl-copy (Wayland).
pub fn copyText(allocator: std.mem.Allocator, text: []const u8) !void {
    _ = allocator;
    const io = app_io.get();
    var child = std.process.spawn(io, .{
        .argv = &.{ "wl-copy", "--type", "text/plain" },
        .stdin = .pipe,
        .stdout = .ignore,
        .stderr = .ignore,
    }) catch |e| switch (e) {
        error.FileNotFound => return error.WlCopyMissing,
        else => return e,
    };
    var write_failed = false;
    if (child.stdin) |stdin| {
        stdin.writeStreamingAll(io, text) catch {
            write_failed = true;
        };
        stdin.close(io);
        child.stdin = null;
    }
    const term = try child.wait(io);
    if (write_failed) return error.WlCopyFailed;
    switch (term) {
        .exited => |code| if (code != 0) return error.WlCopyFailed,
        else => return error.WlCopyFailed,
    }
}
