const std = @import("std");
const app_io = @import("app_io");
const ui = @import("ui");
const overlay = @import("overlay");
const setup = @import("setup");
const editor_window = @import("editor_window");
const png = @import("png");

pub const version = "0.2.0";

pub fn main(init: std.process.Init) !void {
    app_io.set(init.io);
    const allocator = init.gpa;

    var args_list: std.array_list.Managed([]const u8) = .init(allocator);
    defer args_list.deinit();
    var arg_it = try std.process.Args.Iterator.initAllocator(init.minimal.args, allocator);
    defer arg_it.deinit();
    while (arg_it.next()) |a| {
        try args_list.append(try allocator.dupe(u8, a));
    }
    defer for (args_list.items) |a| allocator.free(a);
    const args = args_list.items;

    if (args.len == 2 and std.mem.eql(u8, args[1], "--version")) {
        std.debug.print("ZigIt {s}\n", .{version});
        return;
    }
    if (args.len < 2) {
        std.debug.print("usage: zigit <daemon|capture|edit|setup|decode>\n", .{});
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
    } else if (std.mem.eql(u8, args[1], "decode")) {
        // Smoke-check PNG decode without starting the UI (marquee path).
        if (args.len < 3) {
            std.debug.print("usage: zigit decode PATH\n", .{});
            std.process.exit(2);
        }
        const path = args[2];
        const bytes = try std.Io.Dir.cwd().readFileAlloc(app_io.get(), path, allocator, .limited(256 * 1024 * 1024));
        defer allocator.free(bytes);
        var w: u32 = 0;
        var h: u32 = 0;
        const px = png.decode(allocator, bytes, &w, &h) catch |e| {
            std.debug.print("zigit: decode failed {s} ({d}B): {s}\n", .{ path, bytes.len, @errorName(e) });
            std.process.exit(1);
        };
        defer allocator.free(px);
        std.debug.print("ok {s} {d}x{d} rgba={d}\n", .{ path, w, h, px.len });
    } else {
        std.debug.print("zigit: unknown subcommand {s}\n", .{args[1]});
        std.process.exit(2);
    }
}
