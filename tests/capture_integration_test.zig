const std = @import("std");
const testing = std.testing;
const wayland = @import("wayland");
const capture = @import("capture");

test "captureAllOutputs returns a buffer per output" {
    // Real test requires a running compositor with zwlr_screencopy_manager_v1.
    // Skipped in CI without it: set HAVE_WAYLAND=1 and WAYLAND_DISPLAY to opt in.
    if (std.posix.getenv("HAVE_WAYLAND") == null) return error.SkipZigTest;
    if (std.posix.getenv("WAYLAND_DISPLAY") == null) return error.SkipZigTest;

    var conn = try wayland.Connection.init();
    defer conn.deinit();
    var en = try conn.enumerate(testing.allocator);
    defer en.deinit(testing.allocator);

    // The session compositor may not support wlr-screencopy; skip gracefully.
    const sc = en.screencopy orelse return error.SkipZigTest;
    if (en.outputs.len == 0) return error.SkipZigTest;
    const shm = en.shm orelse return error.SkipZigTest;

    const manager = capture.bindScreencopyManager(conn.registry, sc.name, sc.version) orelse return error.BindFailed;

    const wl_outputs = try testing.allocator.alloc(*anyopaque, en.outputs.len);
    defer testing.allocator.free(wl_outputs);
    for (en.outputs, 0..) |o, i| wl_outputs[i] = o.wl_output orelse return error.NoOutputProxy;

    const bufs = try capture.captureAllOutputs(testing.allocator, conn.display, manager, shm, wl_outputs);
    defer {
        for (bufs) |b| testing.allocator.free(b.data);
        testing.allocator.free(bufs);
    }
    try testing.expectEqual(en.outputs.len, bufs.len);
    for (bufs) |b| {
        try testing.expect(b.width > 0 and b.height > 0);
        try testing.expectEqual(@as(usize, b.stride) * b.height, b.data.len);
    }
}
