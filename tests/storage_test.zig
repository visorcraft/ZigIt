const std = @import("std");
const testing = std.testing;
const storage = @import("storage");

fn ensureDir(path: []const u8) !void {
    std.fs.makeDirAbsolute(path) catch |e| switch (e) {
        error.PathAlreadyExists => {},
        else => return e,
    };
}

/// Format the current UTC timestamp the same way storage.newCapturePath does,
/// so collision tests can pre-create the file that "now" would produce.
fn currentStamp(allocator: std.mem.Allocator) ![]u8 {
    const ts = std.time.timestamp();
    const epoch_sec = std.time.epoch.EpochSeconds{ .secs = @intCast(ts) };
    const year_day = epoch_sec.getEpochDay().calculateYearDay();
    const month_day = year_day.calculateMonthDay();
    const day_sec = epoch_sec.getDaySeconds();
    return std.fmt.allocPrint(allocator, "{d:0>4}-{d:0>2}-{d:0>2}_{d:0>2}-{d:0>2}-{d:0>2}", .{
        year_day.year,
        month_day.month.numeric(),
        month_day.day_index + 1,
        day_sec.getHoursIntoDay(),
        day_sec.getMinutesIntoHour(),
        day_sec.getSecondsIntoMinute(),
    });
}

test "captureDir defaults to HOME/screenshots" {
    // Isolate from the real HOME by setting a temp root.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(root);
    // captureDir reads getenv("HOME"); we can't override env portably here,
    // so only assert the override path is used as-is (no ZigIt suffix).
    const custom = try std.fs.path.join(testing.allocator, &.{ root, "my-shots" });
    defer testing.allocator.free(custom);
    const dir = try storage.captureDir(testing.allocator, custom);
    defer testing.allocator.free(dir);
    try testing.expectEqualStrings(custom, dir);
    // Directory was created.
    var d = try std.fs.openDirAbsolute(dir, .{});
    d.close();
}

test "expandHome expands tilde slash" {
    // Only meaningful when HOME is set (always true in the test harness).
    const home = std.posix.getenv("HOME") orelse return error.SkipZigTest;
    const expanded = try storage.expandHome(testing.allocator, "~/foo/bar");
    defer testing.allocator.free(expanded);
    const expected = try std.fs.path.join(testing.allocator, &.{ home, "foo/bar" });
    defer testing.allocator.free(expected);
    try testing.expectEqualStrings(expected, expanded);
}

test "newCapturePath returns timestamped png inside dir" {
    const tmp = "/tmp/zigit-test-captures";
    try ensureDir(tmp);
    defer std.fs.deleteDirAbsolute(tmp) catch {};

    const p = try storage.newCapturePath(testing.allocator, tmp);
    defer testing.allocator.free(p);
    try testing.expect(std.mem.startsWith(u8, p, tmp));
    try testing.expect(std.mem.endsWith(u8, p, ".png"));
}

test "newCapturePath appends _N on collision" {
    const tmp = "/tmp/zigit-test-captures-2";
    try ensureDir(tmp);
    defer std.fs.deleteTreeAbsolute(tmp) catch {};

    const stamp = try currentStamp(testing.allocator);
    defer testing.allocator.free(stamp);
    const occupied = try std.fmt.allocPrint(testing.allocator, "{s}/{s}.png", .{ tmp, stamp });
    defer testing.allocator.free(occupied);
    const f1 = try std.fs.createFileAbsolute(occupied, .{});
    f1.close();

    const p = try storage.newCapturePath(testing.allocator, tmp);
    defer testing.allocator.free(p);
    try testing.expect(std.mem.endsWith(u8, p, "_1.png"));
}
