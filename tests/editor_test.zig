const std = @import("std");
const testing = std.testing;
const editor = @import("editor");

test "apply with no ops returns base unchanged" {
    var doc = try editor.Document.init(testing.allocator, 4, 4);
    defer doc.deinit();
    @memset(doc.base.pixels, 0x55);
    const img = try doc.apply(testing.allocator);
    defer testing.allocator.free(img.pixels);
    try testing.expectEqualSlices(u8, doc.base.pixels, img.pixels);
}

test "push appends op and clears redo" {
    var doc = try editor.Document.init(testing.allocator, 4, 4);
    defer doc.deinit();
    try doc.push(.{ .rect = .{ .rect = .{ .x = 0, .y = 0, .w = 2, .h = 2 }, .thickness = 1, .color = .{ .r = 255, .g = 0, .b = 0 } } });
    try doc.push(.{ .rect = .{ .rect = .{ .x = 1, .y = 1, .w = 2, .h = 2 }, .thickness = 1, .color = .{ .r = 0, .g = 255, .b = 0 } } });
    doc.undo();
    doc.redo();
    try testing.expectEqual(@as(usize, 2), doc.ops.items.len);
}

test "undo then push clears redo" {
    var doc = try editor.Document.init(testing.allocator, 4, 4);
    defer doc.deinit();
    try doc.push(.{ .rect = .{ .rect = .{ .x = 0, .y = 0, .w = 1, .h = 1 }, .thickness = 1, .color = .{ .r = 0, .g = 0, .b = 0 } } });
    doc.undo();
    try doc.push(.{ .rect = .{ .rect = .{ .x = 0, .y = 0, .w = 1, .h = 1 }, .thickness = 1, .color = .{ .r = 1, .g = 1, .b = 1 } } });
    try testing.expectEqual(@as(usize, 0), doc.redo_stack.items.len);
}

fn pixelIsSet(img: editor.Image, x: i32, y: i32) bool {
    const i: usize = @intCast(@as(usize, @intCast(y)) * img.width + @as(usize, @intCast(x)));
    return img.pixels[i * 4] != 0;
}

test "thick line is solid: every Bresenham pixel and its +1 x/y neighbors are set" {
    var doc = try editor.Document.init(testing.allocator, 6, 4);
    defer doc.deinit();
    @memset(doc.base.pixels, 0);
    try doc.push(.{ .arrow = .{ .from = .{ .x = 0, .y = 0 }, .to = .{ .x = 5, .y = 3 }, .thickness = 2, .color = .{ .r = 255, .g = 0, .b = 0 } } });
    const img = try doc.apply(testing.allocator);
    defer testing.allocator.free(img.pixels);

    // 8-connected Bresenham pixels of (0,0)->(5,3).
    const line = [_]editor.Point{
        .{ .x = 0, .y = 0 }, .{ .x = 1, .y = 1 }, .{ .x = 2, .y = 1 },
        .{ .x = 3, .y = 2 }, .{ .x = 4, .y = 2 }, .{ .x = 5, .y = 3 },
    };
    for (line) |p| {
        try testing.expect(pixelIsSet(img, p.x, p.y));
        // The per-step thickness fill covers the +1 x / +1 y neighbors of
        // every line pixel, so the stroke has no holes (never dotted).
        if (p.x + 1 < 6) try testing.expect(pixelIsSet(img, p.x + 1, p.y));
        if (p.y + 1 < 4) try testing.expect(pixelIsSet(img, p.x, p.y + 1));
    }
}
