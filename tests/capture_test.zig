const std = @import("std");
const testing = std.testing;
const capture = @import("capture");

test "BGRA to RGBA swaps R and B channels" {
    const b = capture.Buffer{
        .width = 2,
        .height = 2,
        .stride = 8,
        .format = .bgra,
        .data = &[_]u8{
            0x00, 0x01, 0x02, 0x03,
            0x10, 0x11, 0x12, 0x13,
            0x20, 0x21, 0x22, 0x23,
            0x30, 0x31, 0x32, 0x33,
        },
    };
    const r = try b.toRGBA(testing.allocator);
    defer testing.allocator.free(r.data);
    try testing.expectEqual(@as(u8, 0x02), r.data[0]);
    try testing.expectEqual(@as(u8, 0x00), r.data[2]);
    try testing.expectEqual(@as(u8, 0x33), r.data[15]);
}

test "RGBA buffer is returned unchanged" {
    const b = capture.Buffer{
        .width = 1, .height = 1, .stride = 4, .format = .rgba,
        .data = &[_]u8{ 0xaa, 0xbb, 0xcc, 0xdd },
    };
    const r = try b.toRGBA(testing.allocator);
    defer testing.allocator.free(r.data);
    try testing.expectEqualSlices(u8, b.data, r.data);
}

test "cropRect extracts a sub-region" {
    var data: [16 * 16 * 4]u8 = undefined;
    for (0..16 * 16) |i| {
        data[i * 4 + 0] = @intCast(i & 0xff);
        data[i * 4 + 1] = @intCast((i * 2) & 0xff);
        data[i * 4 + 2] = @intCast((i * 3) & 0xff);
        data[i * 4 + 3] = 255;
    }
    const b = capture.Buffer{
        .width = 16, .height = 16, .stride = 16 * 4,
        .format = .rgba, .data = &data,
    };
    const out = try b.cropRect(testing.allocator, .{ .x = 4, .y = 4, .w = 4, .h = 4 });
    defer testing.allocator.free(out.data);
    try testing.expectEqual(@as(u32, 4), out.width);
    try testing.expectEqual(@as(u32, 4), out.height);
    // First pixel should be (4,4) in source: r = ((4*16 + 4) & 0xff) = 68
    try testing.expectEqual(@as(u8, 68), out.data[0]);
}

test "cropRect clamps to buffer bounds" {
    const data = [_]u8{0x77} ** (4 * 4 * 4);
    const b = capture.Buffer{
        .width = 4, .height = 4, .stride = 4 * 4,
        .format = .rgba, .data = &data,
    };
    const out = try b.cropRect(testing.allocator, .{ .x = -2, .y = -2, .w = 10, .h = 10 });
    defer testing.allocator.free(out.data);
    try testing.expectEqual(@as(u32, 4), out.width);
    try testing.expectEqual(@as(u32, 4), out.height);
}

test "cropToplevel crops to the toplevel bounds" {
    const data = [_]u8{0x11} ** (8 * 8 * 4);
    const b = capture.Buffer{
        .width = 8, .height = 8, .stride = 8 * 4,
        .format = .rgba, .data = &data,
    };
    const out = try b.cropToplevel(testing.allocator, .{ .x = 2, .y = 2, .w = 3, .h = 3 });
    defer testing.allocator.free(out.data);
    try testing.expectEqual(@as(u32, 3), out.width);
    try testing.expectEqual(@as(u32, 3), out.height);
}

test "Pipeline.run encodes RGBA buffer to PNG" {
    const w: u32 = 8;
    const h: u32 = 8;
    var px: [8 * 8 * 4]u8 = undefined;
    @memset(&px, 0x42);
    const res = try capture.Pipeline.run(testing.allocator, &px, w, h);
    defer testing.allocator.free(res.png);
    try testing.expect(res.png.len > 8);
    try testing.expectEqual(@as(u8, 0x89), res.png[0]);
}

test "cropPolygon masks a convex polygon" {
    var data: [8 * 8 * 4]u8 = undefined;
    @memset(&data, 0xaa);
    const b = capture.Buffer{ .width = 8, .height = 8, .stride = 32, .format = .rgba, .data = &data };
    // Triangle covering pixels (2,2), (5,2), (3,5) — mask outside to zero.
    const poly = capture.Polygon{ .points = &.{
        .{ .x = 2, .y = 2 }, .{ .x = 5, .y = 2 }, .{ .x = 3, .y = 5 },
    } };
    const out = try b.cropPolygon(testing.allocator, poly);
    defer testing.allocator.free(out.data);
    try testing.expectEqual(@as(u32, 4), out.width);
    try testing.expectEqual(@as(u32, 4), out.height);
}

test "cropPolygon handles concave and self-intersecting" {
    var data: [16 * 16 * 4]u8 = undefined;
    @memset(&data, 0x55);
    const b = capture.Buffer{ .width = 16, .height = 16, .stride = 64, .format = .rgba, .data = &data };
    // Concave (L-shape).
    const concave = capture.Polygon{ .points = &.{
        .{ .x = 2, .y = 2 }, .{ .x = 8, .y = 2 }, .{ .x = 8, .y = 5 },
        .{ .x = 4, .y = 5 }, .{ .x = 4, .y = 8 }, .{ .x = 2, .y = 8 },
    } };
    const out = try b.cropPolygon(testing.allocator, concave);
    defer testing.allocator.free(out.data);
    try testing.expect(out.width > 0 and out.height > 0);
}
