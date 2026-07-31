const std = @import("std");

pub fn editor(allocator: std.mem.Allocator, png_path: []const u8) !void {
    var child = std.process.Child.init(&.{ "zigit", "edit", png_path }, allocator);
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Ignore;
    child.stderr_behavior = .Inherit;
    child.spawn() catch |e| switch (e) {
        error.FileNotFound => return error.ZigitMissing,
        else => return e,
    };
    // Fire-and-forget: overlay exits; spawned editor runs independently.
}

/// Runs spectacle (KDE's capture tool) in background mode and waits for it
/// to save. `mode` is one of --fullscreen / --region / --activewindow.
/// Deliberate override of the "no shell-outs except wl-copy" rule: this is
/// the KDE/portal fallback for compositors without wlr-screencopy.
pub fn spectacle(allocator: std.mem.Allocator, mode: []const u8, out_path: []const u8) !void {
    var child = std.process.Child.init(&.{ "spectacle", "--background", "--nonotify", mode, "--output", out_path }, allocator);
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Ignore;
    child.stderr_behavior = .Inherit;
    // Note: on POSIX a failed exec surfaces from wait(), not spawn().
    const term = child.spawnAndWait() catch |e| switch (e) {
        error.FileNotFound => {
            std.debug.print("zigit: spectacle not found; install it (e.g. 'sudo apt install spectacle') for KDE/portal compositors\n", .{});
            return error.SpectacleMissing;
        },
        else => return e,
    };
    switch (term) {
        .Exited => |code| if (code != 0) {
            std.debug.print("zigit: spectacle exited with code {d}\n", .{code});
            return error.SpectacleFailed;
        },
        else => return error.SpectacleFailed,
    }
}
