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
            .arrow => |a| drawLine(&result, a.from, a.to, a.thickness, a.color),
            .rect => |r2| drawRectOutline(&result, r2.rect, r2.thickness, r2.color),
            .pen => |p| drawPolyline(&result, p.points, p.thickness, p.color),
            .text => |t| drawTextPlaceholder(&result, t.pos, t.size, t.color),
            .blur => |b| drawBlurPlaceholder(&result, b.rect),
            .step => |s| drawStepCircle(&result, s.pos, s.number, s.color),
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

fn drawLine(img: *Image, from: Point, to: Point, thickness: u8, c: Color) void {
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
        var t: i32 = 0;
        while (t < thickness) : (t += 1) {
            setPixel(img, x0 + t, y0, c);
            setPixel(img, x0, y0 + t, c);
        }
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
    var i: i32 = 0;
    while (i < @as(i32, @intCast(r.w))) : (i += 1) {
        var t: i32 = 0;
        while (t < thickness) : (t += 1) {
            setPixel(img, r.x + i, r.y + t, c);
            setPixel(img, r.x + i, r.y + @as(i32, @intCast(r.h)) - 1 - t, c);
        }
    }
    var j: i32 = 0;
    while (j < @as(i32, @intCast(r.h))) : (j += 1) {
        var t: i32 = 0;
        while (t < thickness) : (t += 1) {
            setPixel(img, r.x + t, r.y + j, c);
            setPixel(img, r.x + @as(i32, @intCast(r.w)) - 1 - t, r.y + j, c);
        }
    }
}

fn drawPolyline(img: *Image, pts: []Point, thickness: u8, c: Color) void {
    if (pts.len < 2) return;
    var i: usize = 0;
    while (i < pts.len - 1) : (i += 1) {
        drawLine(img, pts[i], pts[i + 1], thickness, c);
    }
}

fn drawTextPlaceholder(img: *Image, pos: Point, size: u8, c: Color) void {
    // Bitmap font stub: draw a colored rectangle to indicate text bounds.
    var i: i32 = 0;
    while (i < size * 6) : (i += 1) setPixel(img, pos.x + i, pos.y, c);
    var j: i32 = 0;
    while (j < size * 6) : (j += 1) setPixel(img, pos.x, pos.y + j, c);
}

fn drawBlurPlaceholder(img: *Image, r: Rect) void {
    const c = Color{ .r = 0, .g = 0, .b = 0, .a = 128 };
    var i: i32 = 0;
    while (i < @as(i32, @intCast(r.w))) : (i += 1) {
        var j: i32 = 0;
        while (j < @as(i32, @intCast(r.h))) : (j += 1) setPixel(img, r.x + i, r.y + j, c);
    }
}

fn drawStepCircle(img: *Image, pos: Point, number: u32, c: Color) void {
    const radius: i32 = 14;
    var dx: i32 = -radius;
    while (dx <= radius) : (dx += 1) {
        var dy: i32 = -radius;
        while (dy <= radius) : (dy += 1) {
            if (dx * dx + dy * dy <= radius * radius) setPixel(img, pos.x + dx, pos.y + dy, c);
        }
    }
    _ = number;
}

fn freeOp(op: *Op, allocator: std.mem.Allocator) void {
    switch (op.*) {
        .pen => |*p| allocator.free(p.points),
        else => {},
    }
}
