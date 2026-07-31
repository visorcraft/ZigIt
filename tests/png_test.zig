const std = @import("std");
const testing = std.testing;
const png = @import("png");

test "round-trip preserves RGBA pixels" {
    const w: u32 = 4;
    const h: u32 = 4;
    var pixels: [16 * 4]u8 = undefined;
    for (0..16) |i| {
        pixels[i * 4 + 0] = @intCast(i * 16);
        pixels[i * 4 + 1] = @intCast(255 - i * 16);
        pixels[i * 4 + 2] = @intCast(i * 8);
        pixels[i * 4 + 3] = 255;
    }
    const bytes = try png.encode(testing.allocator, &pixels, w, h);
    defer testing.allocator.free(bytes);
    try testing.expect(bytes.len > 8);
    try testing.expectEqual(@as(u8, 0x89), bytes[0]);
    try testing.expectEqualStrings("PNG", bytes[1..4]);

    var dw: u32 = 0;
    var dh: u32 = 0;
    const decoded = try png.decode(testing.allocator, bytes, &dw, &dh);
    defer testing.allocator.free(decoded);
    try testing.expectEqual(w, dw);
    try testing.expectEqual(h, dh);
    try testing.expectEqualSlices(u8, &pixels, decoded);
}
