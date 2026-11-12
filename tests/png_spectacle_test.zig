const std = @import("std");
const testing = std.testing;
const png = @import("png");
const app_io = @import("app_io");

fn writeBe32(buf: *[4]u8, v: u32) void {
    std.mem.writeInt(u32, buf, v, .big);
}

fn appendChunk(list: *std.array_list.Managed(u8), tag: *const [4]u8, payload: []const u8) !void {
    var len_buf: [4]u8 = undefined;
    writeBe32(&len_buf, @intCast(payload.len));
    try list.appendSlice(&len_buf);
    const start = list.items.len;
    try list.appendSlice(tag);
    try list.appendSlice(payload);
    const crc = std.hash.Crc32.hash(list.items[start..]);
    var crc_buf: [4]u8 = undefined;
    writeBe32(&crc_buf, crc);
    try list.appendSlice(&crc_buf);
}

/// Split a single-IDAT PNG (as produced by `png.encode`) into many small IDAT
/// chunks so the decoder path matches Spectacle/libpng multi-IDAT streams.
fn splitIdat(allocator: std.mem.Allocator, single: []const u8, piece: usize) ![]u8 {
    if (single.len < 8 or !std.mem.eql(u8, single[0..8], "\x89PNG\r\n\x1a\n")) return error.BadPng;
    var out: std.array_list.Managed(u8) = .init(allocator);
    errdefer out.deinit();
    try out.appendSlice(single[0..8]);

    var pos: usize = 8;
    var idat_payload: std.array_list.Managed(u8) = .init(allocator);
    defer idat_payload.deinit();

    while (pos + 12 <= single.len) {
        const len = std.mem.readInt(u32, single[pos..][0..4], .big);
        const ctype = single[pos + 4 ..][0..4];
        pos += 8;
        if (pos + len + 4 > single.len) return error.BadPng;
        const data = single[pos..][0..len];
        pos += len + 4;
        if (std.mem.eql(u8, ctype, "IDAT")) {
            try idat_payload.appendSlice(data);
        } else if (std.mem.eql(u8, ctype, "IEND")) {
            // Emit collected IDAT as pieces, then IEND.
            var off: usize = 0;
            while (off < idat_payload.items.len) {
                const n = @min(piece, idat_payload.items.len - off);
                try appendChunk(&out, "IDAT", idat_payload.items[off .. off + n]);
                off += n;
            }
            try appendChunk(&out, "IEND", &.{});
            break;
        } else {
            const tag: *const [4]u8 = ctype;
            try appendChunk(&out, tag, data);
        }
    }
    return try out.toOwnedSlice();
}

test "looksComplete requires IEND" {
    const w: u32 = 2;
    const h: u32 = 2;
    var pixels: [16]u8 = @splat(255);
    const full = try png.encode(testing.allocator, &pixels, w, h);
    defer testing.allocator.free(full);
    try testing.expect(png.looksComplete(full));
    try testing.expect(!png.looksComplete(full[0 .. full.len / 2]));
    try testing.expect(!png.looksComplete("not a png"));
}

test "decode multi-IDAT stream with filters" {
    // Large enough that zlib stored blocks + multi-IDAT split are non-trivial.
    const w: u32 = 64;
    const h: u32 = 48;
    const rgba = try testing.allocator.alloc(u8, w * h * 4);
    defer testing.allocator.free(rgba);
    for (0..w * h) |i| {
        rgba[i * 4 + 0] = @truncate(i);
        rgba[i * 4 + 1] = @truncate(i * 3);
        rgba[i * 4 + 2] = @truncate(i * 7);
        rgba[i * 4 + 3] = 255;
    }
    const single = try png.encode(testing.allocator, rgba, w, h);
    defer testing.allocator.free(single);
    // 256-byte IDAT pieces ≈ Spectacle's style of many chunks.
    const multi = try splitIdat(testing.allocator, single, 256);
    defer testing.allocator.free(multi);

    var dw: u32 = 0;
    var dh: u32 = 0;
    const decoded = try png.decode(testing.allocator, multi, &dw, &dh);
    defer testing.allocator.free(decoded);
    try testing.expectEqual(w, dw);
    try testing.expectEqual(h, dh);
    try testing.expectEqualSlices(u8, rgba, decoded);
}

test "decode local Spectacle region PNG if present" {
    const path = "/home/thomasw/screenshots/2026-07-31_14-30-23.png";
    const bytes = std.Io.Dir.cwd().readFileAlloc(app_io.get(), path, testing.allocator, .limited(32 << 20)) catch {
        return error.SkipZigTest;
    };
    defer testing.allocator.free(bytes);
    var w: u32 = 0;
    var h: u32 = 0;
    const px = try png.decode(testing.allocator, bytes, &w, &h);
    defer testing.allocator.free(px);
    try testing.expectEqual(@as(u32, 994), w);
    try testing.expectEqual(@as(u32, 762), h);
    try testing.expectEqual(w * h * 4, px.len);
}

test "decode local dual-monitor Spectacle PNG if present" {
    const path = "/home/thomasw/screenshots/2026-07-31_14-31-20.png";
    const bytes = std.Io.Dir.cwd().readFileAlloc(app_io.get(), path, testing.allocator, .limited(256 << 20)) catch {
        return error.SkipZigTest;
    };
    defer testing.allocator.free(bytes);
    var w: u32 = 0;
    var h: u32 = 0;
    const px = try png.decode(testing.allocator, bytes, &w, &h);
    defer testing.allocator.free(px);
    try testing.expectEqual(@as(u32, 7680), w);
    try testing.expectEqual(@as(u32, 2160), h);
    try testing.expectEqual(w * h * 4, px.len);
}
