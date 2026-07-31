const std = @import("std");
const app_io = @import("app_io");

pub fn editor(allocator: std.mem.Allocator, png_path: []const u8) !void {
    _ = allocator;
    const io = app_io.get();
    _ = std.process.spawn(io, .{
        .argv = &.{ "zigit", "edit", png_path },
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .inherit,
    }) catch |e| switch (e) {
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
    _ = allocator;
    const io = app_io.get();
    // Note: on POSIX a failed exec surfaces from wait(), not spawn().
    var child = std.process.spawn(io, .{
        .argv = &.{ "spectacle", "--background", "--nonotify", mode, "--output", out_path },
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .inherit,
    }) catch |e| switch (e) {
        error.FileNotFound => {
            std.debug.print("zigit: spectacle not found; install it (e.g. 'sudo apt install spectacle') for KDE/portal compositors\n", .{});
            return error.SpectacleMissing;
        },
        else => return e,
    };
    const term = try child.wait(io);
    switch (term) {
        .exited => |code| if (code != 0) {
            std.debug.print("zigit: spectacle exited with code {d}\n", .{code});
            return error.SpectacleFailed;
        },
        else => return error.SpectacleFailed,
    }
}
