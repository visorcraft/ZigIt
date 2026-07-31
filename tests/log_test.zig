const std = @import("std");
const testing = std.testing;
const log = @import("log");

test "rotates when file exceeds 1 MiB" {
    const tmp = "/tmp/zigit-test-log";
    try std.fs.makeDirAbsolute(tmp);
    defer std.fs.deleteTreeAbsolute(tmp) catch {};

    var l = try log.Log.init(tmp ++ "/zigit.log");
    defer l.deinit();
    // Stuff the file just over 1 MiB.
    var chunk: [4096]u8 = undefined;
    @memset(&chunk, 'x');
    var i: usize = 0;
    while (i < (1 << 21) / chunk.len) : (i += 1) try l.write(.info, &chunk);
    // The last write must have rotated. Confirm a backup exists.
    const stat = try std.fs.cwd().statFile(tmp ++ "/zigit.log.1");
    try testing.expect(stat.size > 0);
}
