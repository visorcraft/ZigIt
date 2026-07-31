const std = @import("std");

fn crc32(data: []const u8) u32 {
    return std.hash.crc.Crc32.hash(data);
}

fn adler32(data: []const u8) u32 {
    var s1: u32 = 1;
    var s2: u32 = 0;
    for (data) |b| {
        s1 = (s1 + b) % 65521;
        s2 = (s2 + s1) % 65521;
    }
    return (s2 << 16) | s1;
}

fn writeBe32(list: *std.array_list.Managed(u8), v: u32) !void {
    var buf: [4]u8 = undefined;
    std.mem.writeInt(u32, &buf, v, .big);
    try list.appendSlice(&buf);
}

fn writeChunk(list: *std.array_list.Managed(u8), tag: *const [4]u8, payload: []const u8) !void {
    try writeBe32(list, @intCast(payload.len));
    const start = list.items.len;
    try list.appendSlice(tag);
    try list.appendSlice(payload);
    // CRC over type + payload
    const crc = crc32(list.items[start..]);
    try writeBe32(list, crc);
}

/// Encode 8-bit RGBA into a non-interlaced PNG (filter None, zlib stored blocks).
pub fn encode(allocator: std.mem.Allocator, rgba: []const u8, w: u32, h: u32) ![]u8 {
    const width: usize = w;
    const height: usize = h;
    if (rgba.len < width * height * 4) return error.EncodeFailed;

    // Raw image with filter byte 0 per scanline.
    const rowbytes = width * 4;
    const raw_len = height * (rowbytes + 1);
    const raw = try allocator.alloc(u8, raw_len);
    defer allocator.free(raw);
    for (0..height) |y| {
        raw[y * (rowbytes + 1)] = 0; // filter None
        @memcpy(raw[y * (rowbytes + 1) + 1 ..][0..rowbytes], rgba[y * rowbytes ..][0..rowbytes]);
    }

    // zlib stream: CMF/FLG + stored deflate blocks + adler32.
    var zlib_buf: std.array_list.Managed(u8) = .init(allocator);
    defer zlib_buf.deinit();
    // CMF=8 (deflate), CINFO=7 (32K); FLG makes CMF*256+FLG divisible by 31, FLEVEL=0.
    try zlib_buf.appendSlice(&.{ 0x78, 0x01 });

    var pos: usize = 0;
    while (pos < raw.len) {
        const remaining = raw.len - pos;
        const chunk_len: u16 = @intCast(@min(remaining, 65535));
        const is_final = pos + chunk_len >= raw.len;
        // BFINAL + BTYPE=00 (stored)
        try zlib_buf.append(if (is_final) 0x01 else 0x00);
        var len_bytes: [2]u8 = undefined;
        std.mem.writeInt(u16, &len_bytes, chunk_len, .little);
        try zlib_buf.appendSlice(&len_bytes);
        var nlen_bytes: [2]u8 = undefined;
        std.mem.writeInt(u16, &nlen_bytes, ~chunk_len, .little);
        try zlib_buf.appendSlice(&nlen_bytes);
        try zlib_buf.appendSlice(raw[pos .. pos + chunk_len]);
        pos += chunk_len;
    }
    try writeBe32(&zlib_buf, adler32(raw));

    var out: std.array_list.Managed(u8) = .init(allocator);
    errdefer out.deinit();
    try out.appendSlice("\x89PNG\r\n\x1a\n");

    var ihdr: [13]u8 = undefined;
    std.mem.writeInt(u32, ihdr[0..4], w, .big);
    std.mem.writeInt(u32, ihdr[4..8], h, .big);
    ihdr[8] = 8; // bit depth
    ihdr[9] = 6; // RGBA
    ihdr[10] = 0; // compression
    ihdr[11] = 0; // filter
    ihdr[12] = 0; // interlace
    try writeChunk(&out, "IHDR", &ihdr);
    try writeChunk(&out, "IDAT", zlib_buf.items);
    try writeChunk(&out, "IEND", &.{});

    return try out.toOwnedSlice();
}

fn paeth(a: u8, b: u8, cc: u8) u8 {
    const ai: i32 = a;
    const bi: i32 = b;
    const ci: i32 = cc;
    const p = ai + bi - ci;
    const pa = @abs(p - ai);
    const pb = @abs(p - bi);
    const pc = @abs(p - ci);
    if (pa <= pb and pa <= pc) return a;
    if (pb <= pc) return b;
    return cc;
}

/// Minimal PNG decoder: accepts only the format `encode` produces (8-bit
/// RGBA, non-interlaced). Used by the round-trip tests and by the editor
/// when loading a saved capture.
pub fn decode(allocator: std.mem.Allocator, bytes: []const u8, out_w: *u32, out_h: *u32) ![]u8 {
    const sig = "\x89PNG\r\n\x1a\n";
    if (bytes.len < 8 or !std.mem.eql(u8, bytes[0..8], sig)) return error.DecodeFailed;

    var w: u32 = 0;
    var h: u32 = 0;
    var saw_ihdr = false;
    var idat: std.array_list.Managed(u8) = .init(allocator);
    defer idat.deinit();

    var pos: usize = 8;
    while (pos + 12 <= bytes.len) {
        const len = std.mem.readInt(u32, bytes[pos..][0..4], .big);
        const ctype = bytes[pos + 4 ..][0..4];
        pos += 8;
        if (pos + len + 4 > bytes.len) return error.DecodeFailed;
        const data = bytes[pos..][0..len];
        pos += len + 4; // payload + CRC
        if (std.mem.eql(u8, ctype, "IHDR")) {
            if (len != 13) return error.DecodeFailed;
            w = std.mem.readInt(u32, data[0..4], .big);
            h = std.mem.readInt(u32, data[4..8], .big);
            // bit depth 8, color type 6 (RGBA), no interlace.
            if (data[8] != 8 or data[9] != 6 or data[12] != 0) return error.UnsupportedFormat;
            saw_ihdr = true;
        } else if (std.mem.eql(u8, ctype, "IDAT")) {
            try idat.appendSlice(data);
        } else if (std.mem.eql(u8, ctype, "IEND")) {
            break;
        }
    }
    if (!saw_ihdr or w == 0 or h == 0) return error.DecodeFailed;

    const width: usize = w;
    const height: usize = h;
    const rowbytes = width * 4;
    const raw = try allocator.alloc(u8, height * (rowbytes + 1));
    defer allocator.free(raw);

    var input: std.Io.Reader = .fixed(idat.items);
    var window: [std.compress.flate.max_window_len]u8 = undefined;
    var decomp: std.compress.flate.Decompress = .init(&input, .zlib, &window);
    decomp.reader.readSliceAll(raw) catch return error.DecodeFailed;

    const out = try allocator.alloc(u8, width * height * 4);
    errdefer allocator.free(out);
    for (0..height) |y| {
        const scan = raw[y * (rowbytes + 1) + 1 ..][0..rowbytes];
        const recon = out[y * rowbytes ..][0..rowbytes];
        const prior: ?[]const u8 = if (y == 0) null else out[(y - 1) * rowbytes ..][0..rowbytes];
        switch (raw[y * (rowbytes + 1)]) {
            0 => @memcpy(recon, scan),
            1 => for (scan, 0..) |s, i| {
                const left: u8 = if (i >= 4) recon[i - 4] else 0;
                recon[i] = s +% left;
            },
            2 => for (scan, 0..) |s, i| {
                const up: u8 = if (prior) |p| p[i] else 0;
                recon[i] = s +% up;
            },
            3 => for (scan, 0..) |s, i| {
                const left: u8 = if (i >= 4) recon[i - 4] else 0;
                const up: u8 = if (prior) |p| p[i] else 0;
                recon[i] = s +% @as(u8, @intCast((@as(u16, left) + up) / 2));
            },
            4 => for (scan, 0..) |s, i| {
                const a: u8 = if (i >= 4) recon[i - 4] else 0;
                const b: u8 = if (prior) |p| p[i] else 0;
                const cc: u8 = if (i >= 4 and prior != null) prior.?[i - 4] else 0;
                recon[i] = s +% paeth(a, b, cc);
            },
            else => return error.DecodeFailed,
        }
    }
    out_w.* = w;
    out_h.* = h;
    return out;
}
