const std = @import("std");
const app_io = @import("app_io");
const testing = std.testing;
const editor = @import("editor");
const png = @import("png");

test "save writes PNG file with applied ops" {
    var doc = try editor.Document.init(testing.allocator, 4, 4);
    defer doc.deinit();
    @memset(doc.base.pixels, 0x80);
    try doc.push(.{ .rect = .{ .rect = .{ .x = 1, .y = 1, .w = 2, .h = 2 }, .thickness = 1, .color = .{ .r = 255, .g = 0, .b = 0 } } });

    const path = "/tmp/zigit-editor-save-test.png";
    defer std.Io.Dir.deleteFileAbsolute(app_io.get(), path) catch {};
    try doc.save(testing.allocator, path);

    const bytes = try std.Io.Dir.cwd().readFileAlloc(app_io.get(), path, testing.allocator, .limited(1 << 16));
    defer testing.allocator.free(bytes);
    try testing.expect(bytes.len > 8);
    try testing.expectEqual(@as(u8, 0x89), bytes[0]);
}

test "crop op rebases image and save writes the cropped PNG" {
    var doc = try editor.Document.init(testing.allocator, 4, 4);
    defer doc.deinit();
    // Tag each pixel with its index (y * 4 + x) so the crop is verifiable.
    var i: usize = 0;
    while (i < 16) : (i += 1) {
        doc.base.pixels[i * 4 + 0] = @intCast(i);
        doc.base.pixels[i * 4 + 1] = @intCast(i);
        doc.base.pixels[i * 4 + 2] = @intCast(i);
        doc.base.pixels[i * 4 + 3] = 255;
    }
    try doc.push(.{ .crop = .{ .x = 1, .y = 1, .w = 2, .h = 2 } });

    const path = "/tmp/zigit-editor-crop-test.png";
    defer std.Io.Dir.deleteFileAbsolute(app_io.get(), path) catch {};
    try doc.save(testing.allocator, path);

    const bytes = try std.Io.Dir.cwd().readFileAlloc(app_io.get(), path, testing.allocator, .limited(1 << 16));
    defer testing.allocator.free(bytes);
    var w: u32 = 0;
    var h: u32 = 0;
    const px = try png.decode(testing.allocator, bytes, &w, &h);
    defer testing.allocator.free(px);
    try testing.expectEqual(@as(u32, 2), w);
    try testing.expectEqual(@as(u32, 2), h);
    // The 2x2 window at (1,1) covers source indices 5, 6, 9, 10.
    const expected = [_]u8{ 5, 6, 9, 10 };
    for (expected, 0..) |e, j| {
        try testing.expectEqual(e, px[j * 4 + 0]);
        try testing.expectEqual(@as(u8, 255), px[j * 4 + 3]);
    }
}
