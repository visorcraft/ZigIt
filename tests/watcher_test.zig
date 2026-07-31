const std = @import("std");
const testing = std.testing;
const watcher = @import("watcher");

test "watcher fires Created event when file added" {
    const tmp = "/tmp/zigit-test-watch";
    std.fs.makeDirAbsolute(tmp) catch |e| switch (e) {
        error.PathAlreadyExists => {},
        else => return e,
    };
    defer {
        std.fs.deleteFileAbsolute(tmp ++ "/x.png") catch {};
        std.fs.deleteDirAbsolute(tmp) catch {};
    }

    var w = try watcher.Watcher.init(tmp);
    defer w.deinit();

    const f = try std.fs.createFileAbsolute(tmp ++ "/x.png", .{});
    f.close();

    var got_created = false;
    const deadline = std.time.milliTimestamp() + 2000;
    while (std.time.milliTimestamp() < deadline) {
        if (try w.tryRead()) |ev| {
            if (ev == .created) {
                got_created = true;
                break;
            }
        } else {
            std.time.sleep(20 * std.time.ns_per_ms);
        }
    }
    try testing.expect(got_created);
}
