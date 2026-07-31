const std = @import("std");

// stb_image_write's implementation translates cleanly under Zig 0.13's
// translate-c. stb_image's does not (its vertical-flip and Adam7 paths use
// pointer compound-assignments that translate-c 0.13 miscompiles), so the
// decode path below is a minimal PNG reader in pure Zig: 8-bit
// RGBA (color type 6), non-interlaced, all five scanline filters.
const c = @cImport({
    @cDefine("STB_IMAGE_WRITE_IMPLEMENTATION", "1");
    // Keep everything static: otherwise the header's extern declarations of the
    // tunable globals (stbi_write_png_compression_level etc.) shadow their
    // definitions and translate-c leaves them as undefined extern symbols.
    @cDefine("STB_IMAGE_WRITE_STATIC", "1");
    @cInclude("stdlib.h");
    @cInclude("string.h");
    @cInclude("stb_image_write.h");
});

const WriteCtx = extern struct {
    buf: [*]u8,
    offset: usize,
    capacity: usize,
};

fn writeCb(ctx: ?*anyopaque, data: ?*anyopaque, size: c_int) callconv(.C) void {
    const wc: *WriteCtx = @ptrCast(@alignCast(ctx orelse return));
    const src: [*]const u8 = @ptrCast(data orelse return);
    const n: usize = @intCast(size);
    if (wc.offset + n > wc.capacity) return;
    @memcpy(wc.buf[wc.offset..][0..n], src[0..n]);
    wc.offset += n;
}

pub fn encode(allocator: std.mem.Allocator, rgba: []const u8, w: u32, h: u32) ![]u8 {
    // PNG worst case: filter byte per row + raw bytes + zlib overhead (~1.1x),
    // plus fixed container overhead (sig, IHDR, IDAT/IEND headers, CRCs) that
    // dominates for tiny images.
    const width: usize = w;
    const height: usize = h;
    const upper = (width * height * 4 + height) * 2 + 128;
    const out = try allocator.alloc(u8, upper);
    defer allocator.free(out);
    var wc = WriteCtx{ .buf = out.ptr, .offset = 0, .capacity = upper };
    const ok = c.stbi_write_png_to_func(
        writeCb,
        &wc,
        @intCast(width),
        @intCast(height),
        4,
        rgba.ptr,
        @intCast(width * 4),
    );
    if (ok == 0) return error.EncodeFailed;
    // Shrink to the exact encoded size so the caller can free the slice directly.
    return try allocator.dupe(u8, out[0..wc.offset]);
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
    var idat = std.ArrayList(u8).init(allocator);
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
    var stream = std.io.fixedBufferStream(idat.items);
    var decomp = std.compress.zlib.decompressor(stream.reader());
    decomp.reader().readNoEof(raw) catch return error.DecodeFailed;

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
