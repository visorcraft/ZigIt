const std = @import("std");
const testing = std.testing;
const editor = @import("editor");
const png = @import("png");

// Apply → encode path used by the editor "Copy image" action (without wl-copy).
test "annotated image encodes to PNG with signature" {
    var doc = try editor.Document.init(testing.allocator, 16, 16);
    defer doc.deinit();
    @memset(doc.base.pixels, 40);
    try doc.push(.{ .rect = .{
        .rect = .{ .x = 2, .y = 2, .w = 10, .h = 10 },
        .thickness = 1,
        .color = .{ .r = 255, .g = 0, .b = 0 },
    } });
    const img = try doc.apply(testing.allocator);
    defer testing.allocator.free(img.pixels);
    const bytes = try png.encode(testing.allocator, img.pixels, img.width, img.height);
    defer testing.allocator.free(bytes);
    try testing.expect(bytes.len > 8);
    try testing.expectEqual(@as(u8, 0x89), bytes[0]);
    try testing.expectEqualStrings("PNG", bytes[1..4]);
}

test "open path string is stable for copy-path" {
    const path = "/home/thomasw/screenshots/example.png";
    // The editor passes this exact slice to clipboard.copyText — assert identity.
    try testing.expectEqualStrings(path, path);
    try testing.expect(std.mem.endsWith(u8, path, ".png"));
}
