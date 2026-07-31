const std = @import("std");
const app_io = @import("app_io");
const png = @import("png");
const storage = @import("storage");

pub const Point = struct { x: i32, y: i32 };
pub const Rect = struct { x: i32, y: i32, w: u32, h: u32 };
pub const Color = struct { r: u8, g: u8, b: u8, a: u8 = 255 };

pub const Op = union(enum) {
    crop: Rect,
    arrow: struct { from: Point, to: Point, thickness: u8, color: Color },
    rect: struct { rect: Rect, thickness: u8, color: Color },
    pen: struct { points: []Point, thickness: u8, color: Color },
    text: struct { pos: Point, content: []const u8, size: u8, color: Color },
    blur: struct { rect: Rect, radius: u8 },
    step: struct { pos: Point, number: u32, color: Color },
};

pub const Image = struct {
    width: u32,
    height: u32,
    pixels: []u8,

    pub fn deinit(self: *Image, allocator: std.mem.Allocator) void {
        allocator.free(self.pixels);
    }
};

pub const Document = struct {
    base: Image,
    ops: std.array_list.Managed(Op),
    redo_stack: std.array_list.Managed(Op),

    pub fn init(allocator: std.mem.Allocator, w: u32, h: u32) !Document {
        // usize math: w * h * 4 can overflow u32 for large captures.
        const pixels = try allocator.alloc(u8, @as(usize, w) * @as(usize, h) * 4);
        errdefer allocator.free(pixels);
        return .{
            .base = .{ .width = w, .height = h, .pixels = pixels },
            .ops = std.array_list.Managed(Op).init(allocator),
            .redo_stack = std.array_list.Managed(Op).init(allocator),
        };
    }

    pub fn deinit(self: *Document) void {
        self.base.deinit(self.ops.allocator);
        for (self.ops.items) |*op| freeOp(op, self.ops.allocator);
        for (self.redo_stack.items) |*op| freeOp(op, self.ops.allocator);
        self.ops.deinit();
        self.redo_stack.deinit();
    }

    pub fn push(self: *Document, op: Op) !void {
        // Append first: if it fails (OOM) the redo history is left intact.
        try self.ops.append(op);
        for (self.redo_stack.items) |*op2| freeOp(op2, self.ops.allocator);
        self.redo_stack.clearRetainingCapacity();
    }

    pub fn undo(self: *Document) void {
        if (self.ops.items.len == 0) return;
        const op = self.ops.pop() orelse return;
        self.redo_stack.append(op) catch return;
    }

    pub fn redo(self: *Document) void {
        if (self.redo_stack.items.len == 0) return;
        const op = self.redo_stack.pop() orelse return;
        self.ops.append(op) catch return;
    }

    pub fn apply(self: *Document, allocator: std.mem.Allocator) !Image {
        const out = try allocator.alloc(u8, self.base.pixels.len);
        @memcpy(out, self.base.pixels);
        var result = Image{ .width = self.base.width, .height = self.base.height, .pixels = out };
        errdefer allocator.free(result.pixels);
        for (self.ops.items) |op| switch (op) {
            .crop => |r| {
                // Crop rebases the working image: pixels outside the clamped
                // rect are dropped and the result shrinks to the rect. Ops are
                // applied in order, so ops before a crop drew in the original
                // coordinate space while ops after it draw in cropped
                // coordinates.
                try cropImage(allocator, &result, r);
            },
            .arrow => |a| drawArrow(&result, a.from, a.to, a.thickness, a.color),
            .rect => |r2| drawRectOutline(&result, r2.rect, r2.thickness, r2.color),
            .pen => |p| drawPolyline(&result, p.points, p.thickness, p.color),
            .text => |t| drawText(&result, t.pos, t.content, t.size, t.color),
            .blur => |b| drawBlurPixelate(&result, b.rect, b.radius),
            .step => |s| drawStepMarker(&result, s.pos, s.number, s.color),
        };
        return result;
    }

    pub fn save(self: *Document, allocator: std.mem.Allocator, path: []const u8) !void {
        const result = try self.apply(allocator);
        defer allocator.free(result.pixels);
        const bytes = try png.encode(allocator, result.pixels, result.width, result.height);
        defer allocator.free(bytes);
        // Atomic overwrite: write to a sibling temp file, then rename over the
        // target so a crash mid-write cannot leave a truncated source PNG.
        const tmp_path = try std.fmt.allocPrint(allocator, "{s}.tmp", .{path});
        defer allocator.free(tmp_path);
        try storage.writeFileAbsolute(tmp_path, bytes);
        try std.Io.Dir.renameAbsolute(tmp_path, path, app_io.get());
    }
};

/// Rebases `img` to the sub-rect `r`, clamped to the image bounds with the
/// same semantics as capture.cropRect. Frees the previous pixel buffer.
fn cropImage(allocator: std.mem.Allocator, img: *Image, r: Rect) !void {
    const x0: i64 = @max(0, r.x);
    const y0: i64 = @max(0, r.y);
    const x1: i64 = @min(img.width, @max(0, @as(i64, r.x) + r.w));
    const y1: i64 = @min(img.height, @max(0, @as(i64, r.y) + r.h));
    const cw: u32 = @intCast(@max(0, x1 - x0));
    const ch: u32 = @intCast(@max(0, y1 - y0));
    const out = try allocator.alloc(u8, @as(usize, cw) * @as(usize, ch) * 4);
    var y: u32 = 0;
    while (y < ch) : (y += 1) {
        const src_off = (@as(usize, @intCast(y0)) + y) * img.width * 4 + @as(usize, @intCast(x0)) * 4;
        @memcpy(out[@as(usize, y) * cw * 4 ..][0 .. @as(usize, cw) * 4], img.pixels[src_off..][0 .. @as(usize, cw) * 4]);
    }
    allocator.free(img.pixels);
    img.* = .{ .width = cw, .height = ch, .pixels = out };
}

fn setPixel(img: *Image, x: i32, y: i32, c: Color) void {
    if (x < 0 or y < 0 or x >= @as(i32, @intCast(img.width)) or y >= @as(i32, @intCast(img.height))) return;
    const i: usize = @intCast(@as(usize, @intCast(y)) * img.width + @as(usize, @intCast(x)));
    img.pixels[i * 4 + 0] = c.r;
    img.pixels[i * 4 + 1] = c.g;
    img.pixels[i * 4 + 2] = c.b;
    img.pixels[i * 4 + 3] = c.a;
}

/// Filled disk brush — keeps strokes solid when the image is later downscaled
/// in the editor (1px L-stamps look dashed under GL_LINEAR minify).
fn stampDisk(img: *Image, cx: i32, cy: i32, radius: i32, c: Color) void {
    const r: i32 = if (radius < 0) 0 else radius;
    const r2: i32 = r * r;
    var dy: i32 = -r;
    while (dy <= r) : (dy += 1) {
        var dx: i32 = -r;
        while (dx <= r) : (dx += 1) {
            if (dx * dx + dy * dy <= r2) setPixel(img, cx + dx, cy + dy, c);
        }
    }
}

fn drawLine(img: *Image, from: Point, to: Point, thickness: u8, c: Color) void {
    // Radius so total stroke diameter ≈ thickness (thickness 1 → 1px, 2 → ~3px).
    const rad: i32 = @divTrunc(@as(i32, @intCast(@max(thickness, 1))), 2);
    var x0 = from.x;
    var y0 = from.y;
    const x1 = to.x;
    const y1 = to.y;
    const dx: i32 = @intCast(@abs(x1 - x0));
    const dy = -@as(i32, @intCast(@abs(y1 - y0)));
    var sx: i32 = 1;
    if (x0 >= x1) sx = -1;
    var sy: i32 = 1;
    if (y0 >= y1) sy = -1;
    var err = dx + dy;
    while (true) {
        stampDisk(img, x0, y0, rad, c);
        if (x0 == x1 and y0 == y1) break;
        const e2 = 2 * err;
        if (e2 >= dy) {
            err += dy;
            x0 += sx;
        }
        if (e2 <= dx) {
            err += dx;
            y0 += sy;
        }
    }
}

fn drawRectOutline(img: *Image, r: Rect, thickness: u8, c: Color) void {
    // Use the same solid stroke as drawLine so corners and downscales stay solid.
    const x0 = r.x;
    const y0 = r.y;
    const x1 = r.x + @as(i32, @intCast(r.w)) - 1;
    const y1 = r.y + @as(i32, @intCast(r.h)) - 1;
    if (r.w == 0 or r.h == 0) return;
    drawLine(img, .{ .x = x0, .y = y0 }, .{ .x = x1, .y = y0 }, thickness, c);
    drawLine(img, .{ .x = x1, .y = y0 }, .{ .x = x1, .y = y1 }, thickness, c);
    drawLine(img, .{ .x = x1, .y = y1 }, .{ .x = x0, .y = y1 }, thickness, c);
    drawLine(img, .{ .x = x0, .y = y1 }, .{ .x = x0, .y = y0 }, thickness, c);
}

fn drawPolyline(img: *Image, pts: []Point, thickness: u8, c: Color) void {
    if (pts.len < 2) return;
    var i: usize = 0;
    while (i < pts.len - 1) : (i += 1) {
        drawLine(img, pts[i], pts[i + 1], thickness, c);
    }
}

/// 5×7 monochrome glyphs for digits and basic Latin (row-major, bit7 = left).
/// Index: '0'..'9' = 0..9, 'A'..'Z' = 10..35, 'a'..'z' = 10..35, space = 36, else box.
const glyph_w: i32 = 5;
const glyph_h: i32 = 7;

fn glyphRows(ch: u8) [7]u8 {
    // Each byte: bits 4..0 are columns left→right (bit4 = leftmost).
    const digits = [_][7]u8{
        .{ 0x0E, 0x11, 0x13, 0x15, 0x19, 0x11, 0x0E }, // 0
        .{ 0x04, 0x0C, 0x04, 0x04, 0x04, 0x04, 0x0E }, // 1
        .{ 0x0E, 0x11, 0x01, 0x02, 0x04, 0x08, 0x1F }, // 2
        .{ 0x1E, 0x01, 0x01, 0x0E, 0x01, 0x01, 0x1E }, // 3
        .{ 0x02, 0x06, 0x0A, 0x12, 0x1F, 0x02, 0x02 }, // 4
        .{ 0x1F, 0x10, 0x1E, 0x01, 0x01, 0x11, 0x0E }, // 5
        .{ 0x06, 0x08, 0x10, 0x1E, 0x11, 0x11, 0x0E }, // 6
        .{ 0x1F, 0x01, 0x02, 0x04, 0x08, 0x08, 0x08 }, // 7
        .{ 0x0E, 0x11, 0x11, 0x0E, 0x11, 0x11, 0x0E }, // 8
        .{ 0x0E, 0x11, 0x11, 0x0F, 0x01, 0x02, 0x0C }, // 9
    };
    const letters = [_][7]u8{
        .{ 0x0E, 0x11, 0x11, 0x1F, 0x11, 0x11, 0x11 }, // A
        .{ 0x1E, 0x11, 0x11, 0x1E, 0x11, 0x11, 0x1E }, // B
        .{ 0x0E, 0x11, 0x10, 0x10, 0x10, 0x11, 0x0E }, // C
        .{ 0x1E, 0x11, 0x11, 0x11, 0x11, 0x11, 0x1E }, // D
        .{ 0x1F, 0x10, 0x10, 0x1E, 0x10, 0x10, 0x1F }, // E
        .{ 0x1F, 0x10, 0x10, 0x1E, 0x10, 0x10, 0x10 }, // F
        .{ 0x0E, 0x11, 0x10, 0x17, 0x11, 0x11, 0x0F }, // G
        .{ 0x11, 0x11, 0x11, 0x1F, 0x11, 0x11, 0x11 }, // H
        .{ 0x0E, 0x04, 0x04, 0x04, 0x04, 0x04, 0x0E }, // I
        .{ 0x01, 0x01, 0x01, 0x01, 0x11, 0x11, 0x0E }, // J
        .{ 0x11, 0x12, 0x14, 0x18, 0x14, 0x12, 0x11 }, // K
        .{ 0x10, 0x10, 0x10, 0x10, 0x10, 0x10, 0x1F }, // L
        .{ 0x11, 0x1B, 0x15, 0x15, 0x11, 0x11, 0x11 }, // M
        .{ 0x11, 0x19, 0x15, 0x13, 0x11, 0x11, 0x11 }, // N
        .{ 0x0E, 0x11, 0x11, 0x11, 0x11, 0x11, 0x0E }, // O
        .{ 0x1E, 0x11, 0x11, 0x1E, 0x10, 0x10, 0x10 }, // P
        .{ 0x0E, 0x11, 0x11, 0x11, 0x15, 0x12, 0x0D }, // Q
        .{ 0x1E, 0x11, 0x11, 0x1E, 0x14, 0x12, 0x11 }, // R
        .{ 0x0F, 0x10, 0x10, 0x0E, 0x01, 0x01, 0x1E }, // S
        .{ 0x1F, 0x04, 0x04, 0x04, 0x04, 0x04, 0x04 }, // T
        .{ 0x11, 0x11, 0x11, 0x11, 0x11, 0x11, 0x0E }, // U
        .{ 0x11, 0x11, 0x11, 0x11, 0x11, 0x0A, 0x04 }, // V
        .{ 0x11, 0x11, 0x11, 0x15, 0x15, 0x1B, 0x11 }, // W
        .{ 0x11, 0x11, 0x0A, 0x04, 0x0A, 0x11, 0x11 }, // X
        .{ 0x11, 0x11, 0x0A, 0x04, 0x04, 0x04, 0x04 }, // Y
        .{ 0x1F, 0x01, 0x02, 0x04, 0x08, 0x10, 0x1F }, // Z
    };
    if (ch == ' ') return .{ 0, 0, 0, 0, 0, 0, 0 };
    if (ch >= '0' and ch <= '9') return digits[ch - '0'];
    var up = ch;
    if (up >= 'a' and up <= 'z') up = up - 'a' + 'A';
    if (up >= 'A' and up <= 'Z') return letters[up - 'A'];
    // Unknown: filled box.
    return .{ 0x1F, 0x11, 0x11, 0x11, 0x11, 0x11, 0x1F };
}

fn drawGlyph(img: *Image, pos: Point, ch: u8, scale: i32, c: Color) void {
    const rows = glyphRows(ch);
    const s: i32 = @max(1, scale);
    var row: i32 = 0;
    while (row < glyph_h) : (row += 1) {
        const bits = rows[@intCast(row)];
        var col: i32 = 0;
        while (col < glyph_w) : (col += 1) {
            // bit4 is left column
            if ((bits >> @intCast(4 - col)) & 1 != 0) {
                var sy: i32 = 0;
                while (sy < s) : (sy += 1) {
                    var sx: i32 = 0;
                    while (sx < s) : (sx += 1) {
                        setPixel(img, pos.x + col * s + sx, pos.y + row * s + sy, c);
                    }
                }
            }
        }
    }
}

fn drawText(img: *Image, pos: Point, content: []const u8, size: u8, c: Color) void {
    // Scale so a default size of 16 ≈ 2× the 5×7 cell.
    const scale: i32 = @max(1, @divTrunc(@as(i32, @intCast(size)), 8));
    var x = pos.x;
    const advance = glyph_w * scale + scale; // 1px gap in scale units
    for (content) |ch| {
        if (ch == '\n') continue;
        drawGlyph(img, .{ .x = x, .y = pos.y }, ch, scale, c);
        x += advance;
    }
}

fn drawArrow(img: *Image, from: Point, to: Point, thickness: u8, c: Color) void {
    drawLine(img, from, to, thickness, c);
    const dx: f32 = @floatFromInt(to.x - from.x);
    const dy: f32 = @floatFromInt(to.y - from.y);
    const len = @sqrt(dx * dx + dy * dy);
    if (len < 1.0) return;
    // Unit direction from → to.
    const ux = dx / len;
    const uy = dy / len;
    // Head length ~ 10 + 2*thickness, wings perpendicular.
    const head_len: f32 = @floatFromInt(10 + @as(i32, thickness) * 2);
    const wing: f32 = head_len * 0.55;
    const bx = @as(f32, @floatFromInt(to.x)) - ux * head_len;
    const by = @as(f32, @floatFromInt(to.y)) - uy * head_len;
    // Perpendicular.
    const px = -uy;
    const py = ux;
    const left = Point{
        .x = @intFromFloat(bx + px * wing),
        .y = @intFromFloat(by + py * wing),
    };
    const right = Point{
        .x = @intFromFloat(bx - px * wing),
        .y = @intFromFloat(by - py * wing),
    };
    const thick: u8 = @max(thickness, 2);
    drawLine(img, to, left, thick, c);
    drawLine(img, to, right, thick, c);
    // Fill head triangle roughly by connecting wing base.
    drawLine(img, left, right, 1, c);
}

/// Block-average pixelate of the rect. Block size grows with radius.
fn drawBlurPixelate(img: *Image, r: Rect, radius: u8) void {
    const x0: i32 = @max(0, r.x);
    const y0: i32 = @max(0, r.y);
    const x1: i32 = @min(@as(i32, @intCast(img.width)), r.x + @as(i32, @intCast(r.w)));
    const y1: i32 = @min(@as(i32, @intCast(img.height)), r.y + @as(i32, @intCast(r.h)));
    if (x1 <= x0 or y1 <= y0) return;
    const block: i32 = @max(2, @as(i32, @intCast(@max(radius, 1))));
    var by = y0;
    while (by < y1) : (by += block) {
        var bx = x0;
        while (bx < x1) : (bx += block) {
            const bx1 = @min(bx + block, x1);
            const by1 = @min(by + block, y1);
            var sum_r: u32 = 0;
            var sum_g: u32 = 0;
            var sum_b: u32 = 0;
            var sum_a: u32 = 0;
            var count: u32 = 0;
            var y = by;
            while (y < by1) : (y += 1) {
                var x = bx;
                while (x < bx1) : (x += 1) {
                    const i: usize = @intCast(@as(usize, @intCast(y)) * img.width + @as(usize, @intCast(x)));
                    sum_r += img.pixels[i * 4 + 0];
                    sum_g += img.pixels[i * 4 + 1];
                    sum_b += img.pixels[i * 4 + 2];
                    sum_a += img.pixels[i * 4 + 3];
                    count += 1;
                }
            }
            if (count == 0) continue;
            const avg = Color{
                .r = @intCast(@divTrunc(sum_r, count)),
                .g = @intCast(@divTrunc(sum_g, count)),
                .b = @intCast(@divTrunc(sum_b, count)),
                .a = @intCast(@divTrunc(sum_a, count)),
            };
            y = by;
            while (y < by1) : (y += 1) {
                var x = bx;
                while (x < bx1) : (x += 1) setPixel(img, x, y, avg);
            }
        }
    }
}

fn drawStepMarker(img: *Image, pos: Point, number: u32, c: Color) void {
    const radius: i32 = 14;
    // Filled circle in annotation color.
    var dx: i32 = -radius;
    while (dx <= radius) : (dx += 1) {
        var dy: i32 = -radius;
        while (dy <= radius) : (dy += 1) {
            if (dx * dx + dy * dy <= radius * radius) setPixel(img, pos.x + dx, pos.y + dy, c);
        }
    }
    // Digits in contrasting ink (white on dark accent, dark on light).
    const ink: Color = if (@as(u16, c.r) + c.g + c.b > 380)
        .{ .r = 20, .g = 20, .b = 20, .a = 255 }
    else
        .{ .r = 255, .g = 255, .b = 255, .a = 255 };
    // Format number (cap at 99 for fit inside the circle).
    const n = @min(number, 99);
    var buf: [2]u8 = undefined;
    const text = if (n < 10) blk: {
        buf[0] = '0' + @as(u8, @intCast(n));
        break :blk buf[0..1];
    } else blk: {
        buf[0] = '0' + @as(u8, @intCast(@divTrunc(n, 10)));
        buf[1] = '0' + @as(u8, @intCast(n % 10));
        break :blk buf[0..2];
    };
    // Center 5×7 glyphs at scale 1 inside the circle.
    const scale: i32 = 1;
    const total_w = @as(i32, @intCast(text.len)) * (glyph_w * scale + scale) - scale;
    const total_h = glyph_h * scale;
    var x = pos.x - @divTrunc(total_w, 2);
    const y = pos.y - @divTrunc(total_h, 2);
    for (text) |ch| {
        drawGlyph(img, .{ .x = x, .y = y }, ch, scale, ink);
        x += glyph_w * scale + scale;
    }
}

fn freeOp(op: *Op, allocator: std.mem.Allocator) void {
    switch (op.*) {
        .pen => |*p| allocator.free(p.points),
        .text => |*t| allocator.free(t.content),
        else => {},
    }
}
