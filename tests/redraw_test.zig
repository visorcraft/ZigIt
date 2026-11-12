const std = @import("std");
const redraw = @import("redraw");

const esc: c_int = 256; // GLFW_KEY_ESCAPE
const other: c_int = 65; // GLFW_KEY_A

test "dirty flag is consumed once" {
    redraw.dirty = false;
    try std.testing.expect(!redraw.takeDirty());

    redraw.dirty = true;
    try std.testing.expect(redraw.takeDirty());
    try std.testing.expect(!redraw.takeDirty());
}

test "key press is reported once and only for that key" {
    try std.testing.expect(!redraw.tookKeyPress(esc));

    redraw.recordKeyPress(esc);
    try std.testing.expect(!redraw.tookKeyPress(other));
    try std.testing.expect(redraw.tookKeyPress(esc));
    try std.testing.expect(!redraw.tookKeyPress(esc));
}
