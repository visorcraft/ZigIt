const std = @import("std");
const ui = @import("ui");
const overlay = @import("overlay");
const setup = @import("setup");
const editor_window = @import("editor_window");

pub const version = "0.1.0";

pub fn main() !void {
    var gpa: std.heap.GeneralPurposeAllocator(.{}) = .{};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);
    if (args.len == 2 and std.mem.eql(u8, args[1], "--version")) {
        std.debug.print("ZigIt {s}\n", .{version});
        return;
    }
    if (args.len < 2) {
        std.debug.print("usage: zigit <daemon|capture|edit|setup>\n", .{});
        std.process.exit(2);
    }
    if (std.mem.eql(u8, args[1], "daemon")) {
        try ui.Ui.run(allocator);
    } else if (std.mem.eql(u8, args[1], "capture")) {
        try overlay.Overlay.run(allocator, args[2..]);
    } else if (std.mem.eql(u8, args[1], "setup")) {
        try setup.run(allocator, args[2..]);
    } else if (std.mem.eql(u8, args[1], "edit")) {
        if (args.len < 3) return error.MissingPath;
        try editor_window.EditorWindow.run(allocator, args[2]);
    } else {
        std.debug.print("zigit: unknown subcommand {s}\n", .{args[1]});
        std.process.exit(2);
    }
}
