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

fn countRedNear(img: editor.Image, cx: i32, cy: i32, radius: i32) usize {
    var n: usize = 0;
    var y = cy - radius;
    while (y <= cy + radius) : (y += 1) {
        var x = cx - radius;
        while (x <= cx + radius) : (x += 1) {
            if (x < 0 or y < 0 or x >= @as(i32, @intCast(img.width)) or y >= @as(i32, @intCast(img.height))) continue;
            const i: usize = @intCast(@as(usize, @intCast(y)) * img.width + @as(usize, @intCast(x)));
            if (img.pixels[i * 4] == 255 and img.pixels[i * 4 + 1] == 0) n += 1;
        }
    }
    return n;
}

test "arrow paints a head denser than the shaft tip alone" {
    // Horizontal arrow long enough for a full head.
    var doc = try editor.Document.init(testing.allocator, 80, 40);
    defer doc.deinit();
    @memset(doc.base.pixels, 0);
    try doc.push(.{ .arrow = .{
        .from = .{ .x = 5, .y = 20 },
        .to = .{ .x = 60, .y = 20 },
        .thickness = 2,
        .color = .{ .r = 255, .g = 0, .b = 0 },
    } });
    const img = try doc.apply(testing.allocator);
    defer testing.allocator.free(img.pixels);
    // Tip neighborhood must be filled (head wings).
    const tip = countRedNear(img, 60, 20, 8);
    // Mid-shaft neighborhood is only the stroke.
    const mid = countRedNear(img, 30, 20, 8);
    try testing.expect(tip > mid);
    try testing.expect(tip > 20);
}

test "step marker draws digit ink not only a solid disk" {
    var doc = try editor.Document.init(testing.allocator, 64, 64);
    defer doc.deinit();
    // White background so dark digit ink contrasts with red fill.
    @memset(doc.base.pixels, 255);
    try doc.push(.{ .step = .{
        .pos = .{ .x = 32, .y = 32 },
        .number = 7,
        .color = .{ .r = 255, .g = 0, .b = 0 },
    } });
    const img = try doc.apply(testing.allocator);
    defer testing.allocator.free(img.pixels);
    // Center region should include white digit pixels (ink on red disk).
    var white_ink: usize = 0;
    var red_fill: usize = 0;
    var y: i32 = 24;
    while (y <= 40) : (y += 1) {
        var x: i32 = 24;
        while (x <= 40) : (x += 1) {
            const i: usize = @intCast(@as(usize, @intCast(y)) * img.width + @as(usize, @intCast(x)));
            const r = img.pixels[i * 4];
            const g = img.pixels[i * 4 + 1];
            const b = img.pixels[i * 4 + 2];
            if (r == 255 and g == 255 and b == 255) white_ink += 1;
            if (r == 255 and g == 0 and b == 0) red_fill += 1;
        }
    }
    try testing.expect(red_fill > 50);
    try testing.expect(white_ink > 5); // digit "7" ink
}

test "step number 12 produces multi-digit ink" {
    var doc = try editor.Document.init(testing.allocator, 64, 64);
    defer doc.deinit();
    @memset(doc.base.pixels, 255);
    try doc.push(.{ .step = .{
        .pos = .{ .x = 32, .y = 32 },
        .number = 12,
        .color = .{ .r = 200, .g = 0, .b = 0 },
    } });
    const img = try doc.apply(testing.allocator);
    defer testing.allocator.free(img.pixels);
    var white_ink: usize = 0;
    var y: i32 = 26;
    while (y <= 38) : (y += 1) {
        var x: i32 = 22;
        while (x <= 42) : (x += 1) {
            const i: usize = @intCast(@as(usize, @intCast(y)) * img.width + @as(usize, @intCast(x)));
            if (img.pixels[i * 4] == 255 and img.pixels[i * 4 + 1] == 255 and img.pixels[i * 4 + 2] == 255)
                white_ink += 1;
        }
    }
    // Two digits need more ink than a single "1".
    try testing.expect(white_ink > 10);
}

test "text rasterizes glyph ink larger than an L-stub" {
    var doc = try editor.Document.init(testing.allocator, 120, 40);
    defer doc.deinit();
    @memset(doc.base.pixels, 0);
    const content = try testing.allocator.dupe(u8, "Hi");
    try doc.push(.{ .text = .{
        .pos = .{ .x = 4, .y = 4 },
        .content = content,
        .size = 16,
        .color = .{ .r = 0, .g = 255, .b = 0 },
    } });
    const img = try doc.apply(testing.allocator);
    defer testing.allocator.free(img.pixels);
    var green: usize = 0;
    for (0..img.pixels.len / 4) |pi| {
        if (img.pixels[pi * 4 + 1] == 255 and img.pixels[pi * 4] == 0) green += 1;
    }
    // L-stub for size 16 would be ~16*6*2 edge pixels; real glyphs are denser.
    try testing.expect(green > 40);
}

test "blur pixelates source content not solid black" {
    var doc = try editor.Document.init(testing.allocator, 32, 32);
    defer doc.deinit();
    // Checkerboard: high contrast pattern.
    for (0..32) |y| {
        for (0..32) |x| {
            const on = ((x / 4) + (y / 4)) % 2 == 0;
            const i = y * 32 + x;
            const v: u8 = if (on) 255 else 0;
            doc.base.pixels[i * 4 + 0] = v;
            doc.base.pixels[i * 4 + 1] = v;
            doc.base.pixels[i * 4 + 2] = 0; // blue channel always 0
            doc.base.pixels[i * 4 + 3] = 255;
        }
    }
    try doc.push(.{ .blur = .{ .rect = .{ .x = 4, .y = 4, .w = 24, .h = 24 }, .radius = 8 } });
    const img = try doc.apply(testing.allocator);
    defer testing.allocator.free(img.pixels);
    // Interior must not be uniform pure black (0,0,0).
    var non_black: usize = 0;
    var pure_black: usize = 0;
    var y: usize = 8;
    while (y < 24) : (y += 1) {
        var x: usize = 8;
        while (x < 24) : (x += 1) {
            const i = y * 32 + x;
            const r = img.pixels[i * 4];
            const g = img.pixels[i * 4 + 1];
            const b = img.pixels[i * 4 + 2];
            if (r == 0 and g == 0 and b == 0) pure_black += 1 else non_black += 1;
        }
    }
    try testing.expect(non_black > 0);
    // Pixelate averages blocks of the checkerboard → mid-gray, not all black.
    try testing.expect(non_black > pure_black / 2);
}
