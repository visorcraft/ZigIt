const std = @import("std");
const builtin = @import("builtin");

/// Process-wide Io handle. Set once from `main` via `set`. Unit tests fall
/// back to `std.testing.io` when `set` was not called.
var current: ?std.Io = null;

pub fn set(io: std.Io) void {
    current = io;
}

pub fn get() std.Io {
    if (current) |io| return io;
    if (builtin.is_test) return std.testing.io;
    @panic("app_io not initialized; call app_io.set from main");
}

/// Snapshot the process environment into an owned `Environ.Map`.
/// Caller must `deinit` the map.
pub fn processEnvMap(allocator: std.mem.Allocator) !std.process.Environ.Map {
    var map = std.process.Environ.Map.init(allocator);
    errdefer map.deinit();
    var i: usize = 0;
    while (std.c.environ[i]) |entry| : (i += 1) {
        const s = std.mem.span(entry);
        const eq = std.mem.indexOfScalar(u8, s, '=') orelse continue;
        try map.put(s[0..eq], s[eq + 1 ..]);
    }
    return map;
}
