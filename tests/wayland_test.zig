const std = @import("std");
const testing = std.testing;
const wayland = @import("wayland");

extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;
extern "c" fn unsetenv(name: [*:0]const u8) c_int;

test "Connection.init fails when WAYLAND_DISPLAY invalid" {
    // Point the client library at a socket that does not exist.
    try testing.expectEqual(@as(c_int, 0), setenv("WAYLAND_DISPLAY", "/tmp/nonexistent.sock", 1));
    defer _ = unsetenv("WAYLAND_DISPLAY");
    try testing.expectError(error.ConnectFailed, wayland.Connection.init());
}

test "Connection.outputs returns a slice (empty until enumeration lands)" {
    // Without a compositor we cannot enumerate, but the API must return a
    // valid, freeable slice rather than crashing.
    if (wayland.Connection.init()) |*conn_raw| {
        var conn = conn_raw.*;
        defer conn.deinit();
        const outs = try conn.outputs(testing.allocator);
        defer testing.allocator.free(outs);
        for (outs) |*o| o.deinit(testing.allocator);
    } else |_| {
        // Headless CI: no compositor available, nothing to assert.
    }
}
