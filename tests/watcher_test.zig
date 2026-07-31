const std = @import("std");
const app_io = @import("app_io");
const testing = std.testing;
const watcher = @import("watcher");

test "watcher fires Created event when file added" {
    const tmp = "/tmp/zigit-test-watch";
    std.Io.Dir.createDirAbsolute(app_io.get(), tmp, .default_dir) catch |e| switch (e) {
        error.PathAlreadyExists => {},
        else => return e,
    };
    defer {
        std.Io.Dir.deleteFileAbsolute(app_io.get(), tmp ++ "/x.png") catch {};
        std.Io.Dir.deleteDirAbsolute(app_io.get(), tmp) catch {};
    }

    var w = try watcher.Watcher.init(tmp);
    defer w.deinit();

    const f = try std.Io.Dir.createFileAbsolute(app_io.get(), tmp ++ "/x.png", .{});
    f.close(app_io.get());

    var got_created = false;
    const deadline = std.Io.Clock.real.now(app_io.get()).toMilliseconds() + 2000;
    while (std.Io.Clock.real.now(app_io.get()).toMilliseconds() < deadline) {
        if (try w.tryRead()) |ev| {
            if (ev == .created) {
                got_created = true;
                break;
            }
        } else {
            std.Io.sleep(app_io.get(), .{ .nanoseconds = 20 * std.time.ns_per_ms }, .awake) catch {};
        }
    }
    try testing.expect(got_created);
}
