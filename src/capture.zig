const std = @import("std");
const png = @import("png");

pub const Format = enum { bgra, rgba };

pub const Rect = struct { x: i32, y: i32, w: u32, h: u32 };

pub const Buffer = struct {
    width: u32,
    height: u32,
    stride: u32,
    format: Format,
    data: []const u8,

    /// Returns a freshly allocated RGBA copy. BGRA sources have their R and B
    /// channels swapped and the stride is tightened to width * 4; RGBA sources
    /// are copied unchanged. The caller owns the returned buffer's data.
    pub fn toRGBA(self: Buffer, allocator: std.mem.Allocator) !Buffer {
        if (self.format == .rgba) {
            const copy = try allocator.alloc(u8, self.data.len);
            @memcpy(copy, self.data);
            return .{ .width = self.width, .height = self.height, .stride = self.stride, .format = .rgba, .data = copy };
        }
        const out = try allocator.alloc(u8, @as(usize, self.width) * self.height * 4);
        var y: u32 = 0;
        while (y < self.height) : (y += 1) {
            // Row bases in usize so large buffers can't wrap u32 offsets.
            const row_src: usize = @as(usize, y) * self.stride;
            const row_dst: usize = @as(usize, y) * self.width * 4;
            var x: u32 = 0;
            while (x < self.width) : (x += 1) {
                const si = row_src + @as(usize, x) * 4;
                const di = row_dst + @as(usize, x) * 4;
                out[di + 0] = self.data[si + 2]; // R = B
                out[di + 1] = self.data[si + 1]; // G = G
                out[di + 2] = self.data[si + 0]; // B = R
                out[di + 3] = self.data[si + 3]; // A = A
            }
        }
        return .{ .width = self.width, .height = self.height, .stride = self.width * 4, .format = .rgba, .data = out };
    }

    /// Returns a freshly allocated copy of the sub-region `r`, clamped to the
    /// buffer bounds. The caller owns the returned buffer's data.
    pub fn cropRect(self: Buffer, allocator: std.mem.Allocator, r: Rect) !Buffer {
        const x0: i64 = @max(0, r.x);
        const y0: i64 = @max(0, r.y);
        const x1: i64 = @min(self.width, @max(0, @as(i64, r.x) + r.w));
        const y1: i64 = @min(self.height, @max(0, @as(i64, r.y) + r.h));
        const cw: u32 = @intCast(@max(0, x1 - x0));
        const ch: u32 = @intCast(@max(0, y1 - y0));
        const out = try allocator.alloc(u8, @as(usize, cw) * ch * 4);
        const row_bytes: usize = @as(usize, cw) * 4;
        var y: u32 = 0;
        while (y < ch) : (y += 1) {
            const src_off = (@as(usize, @intCast(y0)) + y) * self.stride + @as(usize, @intCast(x0)) * 4;
            const dst_off = @as(usize, y) * row_bytes;
            @memcpy(out[dst_off..][0..row_bytes], self.data[src_off..][0..row_bytes]);
        }
        return .{ .width = cw, .height = ch, .stride = cw * 4, .format = self.format, .data = out };
    }

    /// Crops to a toplevel window's bounds; identical to cropRect but named
    /// for window-pick use.
    pub fn cropToplevel(self: Buffer, allocator: std.mem.Allocator, bounds: Rect) !Buffer {
        return self.cropRect(allocator, bounds);
    }

    /// Crops to the bounding box of `poly`, masking pixels outside the polygon
    /// to zero (even-odd scanline rule). Polygon vertices are treated as
    /// inclusive pixel coordinates. The caller owns the returned buffer's data.
    pub fn cropPolygon(self: Buffer, allocator: std.mem.Allocator, poly: Polygon) !Buffer {
        // 1. Compute the bounding rect of poly; reject if empty.
        var min_x: i32 = std.math.maxInt(i32);
        var min_y: i32 = std.math.maxInt(i32);
        var max_x: i32 = std.math.minInt(i32);
        var max_y: i32 = std.math.minInt(i32);
        for (poly.points) |p| {
            if (p.x < min_x) min_x = p.x;
            if (p.y < min_y) min_y = p.y;
            if (p.x > max_x) max_x = p.x;
            if (p.y > max_y) max_y = p.y;
        }
        const x0 = @max(0, min_x);
        const y0 = @max(0, min_y);
        // +1: vertices name pixels, so the exclusive bound is one past the max.
        const x1: i32 = @intCast(@min(@as(i64, self.width), @as(i64, max_x) + 1));
        const y1: i32 = @intCast(@min(@as(i64, self.height), @as(i64, max_y) + 1));
        if (poly.points.len == 0 or x1 <= x0 or y1 <= y0) return Buffer{
            .width = 0,
            .height = 0,
            .stride = 0,
            .format = self.format,
            .data = try allocator.alloc(u8, 0),
        };
        const cw: u32 = @intCast(x1 - x0);
        const ch: u32 = @intCast(y1 - y0);
        const out = try allocator.alloc(u8, @as(usize, cw) * ch * 4);
        // Zero-fill outside polygon via even-odd scanline rule.
        var y: u32 = 0;
        while (y < ch) : (y += 1) {
            const sy: i32 = @as(i32, @intCast(y)) + y0;
            var x: u32 = 0;
            while (x < cw) : (x += 1) {
                const sx: i32 = @as(i32, @intCast(x)) + x0;
                const di: usize = @as(usize, y) * cw * 4 + @as(usize, x) * 4;
                if (pointInPolygon(.{ .x = sx, .y = sy }, poly)) {
                    const si: usize = @as(usize, @intCast(sy)) * self.stride + @as(usize, @intCast(sx)) * 4;
                    @memcpy(out[di..][0..4], self.data[si..][0..4]);
                } else {
                    @memset(out[di..][0..4], 0);
                }
            }
        }
        return .{ .width = cw, .height = ch, .stride = cw * 4, .format = self.format, .data = out };
    }
};

pub const Point = struct { x: i32, y: i32 };
pub const Polygon = struct { points: []const Point };

fn pointInPolygon(p: Point, poly: Polygon) bool {
    // Even-odd ray-cast.
    var inside = false;
    var i: usize = 0;
    var j: usize = poly.points.len - 1;
    while (i < poly.points.len) {
        const pi = poly.points[i];
        const pj = poly.points[j];
        if ((pi.y > p.y) != (pj.y > p.y)) {
            const x_intersect = @as(f32, @floatFromInt(pj.x - pi.x)) *
                @as(f32, @floatFromInt(p.y - pi.y)) /
                @as(f32, @floatFromInt(pj.y - pi.y)) +
                @as(f32, @floatFromInt(pi.x));
            if (@as(i32, @intFromFloat(x_intersect)) > p.x) inside = !inside;
        }
        j = i;
        i += 1;
    }
    return inside;
}

pub const PipelineResult = struct { png: []u8, width: u32, height: u32 };

pub const Pipeline = struct {
    /// Encodes a packed RGBA pixel buffer to PNG. The caller owns
    /// the returned PNG bytes.
    pub fn run(allocator: std.mem.Allocator, rgba: []const u8, w: u32, h: u32) !PipelineResult {
        const bytes = try png.encode(allocator, rgba, w, h);
        return .{ .png = bytes, .width = w, .height = h };
    }
};

// --- wlr-screencopy ---------------------------------------------------------
//
// The zwlr-screencopy protocol marshalling is hand-declared here (transcribed
// from vendor/wl_proto_screencopy.c, wayland-scanner 1.25.0 output) instead of
// @cImport'ing the generated client header: the capture module has no vendored
// include path and test artifacts do not link libwl_proto, and both of those
// are build.zig concerns this module cannot rely on. wl_shm / wl_buffer /
// wl_output interfaces come from libwayland-client itself.
// Wayland client bindings, translated at build time (Zig 0.17 has no
// @cImport). See src/ctypes/wayland.h.
const wl = @import("c_wayland");

// The interface/message tables reference each other (manager's types point at
// the frame interface, frame's messages point back into the shared types
// table), which is a comptime dependency loop in Zig, so they are filled in
// once at runtime instead.
var screencopy_types: [16]?*const wl.wl_interface = undefined;
var screencopy_manager_requests: [3]wl.wl_message = undefined;
var screencopy_frame_requests: [3]wl.wl_message = undefined;
var screencopy_frame_events: [7]wl.wl_message = undefined;
var screencopy_manager_interface: wl.wl_interface = undefined;
var screencopy_frame_interface: wl.wl_interface = undefined;

var protocol_ready = std.atomic.Value(bool).init(false);

fn ensureProtocolTables() void {
    // Idempotent pure table writes; a race only double-initializes.
    if (protocol_ready.load(.acquire)) return;
    initProtocolTables();
    protocol_ready.store(true, .release);
}

fn typePtr(offset: usize) [*c][*c]const wl.wl_interface {
    return @ptrCast(&screencopy_types[offset]);
}

fn initProtocolTables() void {
    screencopy_types = .{
        null, null, null, null,
        &screencopy_frame_interface, // capture_output: new_id frame
        null, //                        capture_output: overlay_cursor
        &wl.wl_output_interface, //       capture_output: output
        &screencopy_frame_interface, // capture_output_region: new_id frame
        null, //                        capture_output_region: overlay_cursor
        &wl.wl_output_interface, //       capture_output_region: output
        null, null, null, null, //       capture_output_region: x, y, width, height
        &wl.wl_buffer_interface, //      copy: buffer
        &wl.wl_buffer_interface, //      copy_with_damage: buffer
    };
    screencopy_manager_requests = .{
        .{ .name = "capture_output", .signature = "nio", .types = typePtr(4) },
        .{ .name = "capture_output_region", .signature = "nioiiii", .types = typePtr(7) },
        .{ .name = "destroy", .signature = "", .types = typePtr(0) },
    };
    screencopy_frame_requests = .{
        .{ .name = "copy", .signature = "o", .types = typePtr(14) },
        .{ .name = "destroy", .signature = "", .types = typePtr(0) },
        .{ .name = "copy_with_damage", .signature = "2o", .types = typePtr(15) },
    };
    screencopy_frame_events = .{
        .{ .name = "buffer", .signature = "uuuu", .types = typePtr(0) },
        .{ .name = "flags", .signature = "u", .types = typePtr(0) },
        .{ .name = "ready", .signature = "uuu", .types = typePtr(0) },
        .{ .name = "failed", .signature = "", .types = typePtr(0) },
        .{ .name = "damage", .signature = "2uuuu", .types = typePtr(0) },
        .{ .name = "linux_dmabuf", .signature = "3uuu", .types = typePtr(0) },
        .{ .name = "buffer_done", .signature = "3", .types = typePtr(0) },
    };
    screencopy_manager_interface = .{
        .name = "zwlr_screencopy_manager_v1",
        .version = 3,
        .method_count = screencopy_manager_requests.len,
        .methods = &screencopy_manager_requests,
        .event_count = 0,
        .events = null,
    };
    screencopy_frame_interface = .{
        .name = "zwlr_screencopy_frame_v1",
        .version = 3,
        .method_count = screencopy_frame_requests.len,
        .methods = &screencopy_frame_requests,
        .event_count = screencopy_frame_events.len,
        .events = &screencopy_frame_events,
    };
}

const CAPTURE_OUTPUT_OPCODE = 0;
const FRAME_COPY_OPCODE = 0;
const FRAME_DESTROY_OPCODE = 1;

/// Binds the compositor's zwlr_screencopy_manager_v1 global (at version <= 3).
/// `registry` is a wl_registry proxy; it is opaque here because the wayland
/// module's @cImport types are distinct from this module's.
pub fn bindScreencopyManager(registry: *anyopaque, name: u32, version: u32) ?*anyopaque {
    ensureProtocolTables();
    const reg: *wl.wl_registry = @ptrCast(@alignCast(registry));
    return wl.wl_registry_bind(reg, name, &screencopy_manager_interface, @min(version, 3));
}

const FrameCtx = struct {
    allocator: std.mem.Allocator,
    shm: *wl.wl_shm,
    frame: ?*wl.wl_proxy = null,
    wl_buffer: ?*wl.wl_buffer = null,
    map: []align(std.heap.page_size_min) u8 = &[_]u8{},
    fd: std.posix.fd_t = -1,
    result: ?Buffer = null,
    status: enum { pending, ready, failed } = .pending,
    width: u32 = 0,
    height: u32 = 0,
    stride: u32 = 0,
    format: u32 = 0,
    shm_offered: bool = false,

    fn cleanup(self: *FrameCtx) void {
        if (self.wl_buffer) |b| wl.wl_buffer_destroy(b);
        self.wl_buffer = null;
        if (self.map.len > 0) std.posix.munmap(self.map);
        self.map = &[_]u8{};
        if (self.fd >= 0) _ = std.c.close(self.fd);
        self.fd = -1;
        if (self.frame) |f| {
            // Sends the frame destroy request and destroys the proxy.
            _ = wl.wl_proxy_marshal_flags(f, FRAME_DESTROY_OPCODE, null, wl.wl_proxy_get_version(f), wl.WL_MARSHAL_FLAG_DESTROY);
            self.frame = null;
        }
    }
};

/// Issues one capture_output per wl_output proxy and blocks until every frame
/// reports ready (or fails). On success the caller owns each Buffer's data and
/// the returned slice. Proxies are opaque for the same reason as
/// bindScreencopyManager: callers pass their own @cImport's pointer types.
pub fn captureAllOutputs(
    allocator: std.mem.Allocator,
    display: *anyopaque,
    manager: *anyopaque,
    shm: *anyopaque,
    wl_outputs: []const *anyopaque,
) ![]Buffer {
    const dpy: *wl.wl_display = @ptrCast(@alignCast(display));
    const mgr: *wl.wl_proxy = @ptrCast(@alignCast(manager));
    const shm_proxy: *wl.wl_shm = @ptrCast(@alignCast(shm));
    ensureProtocolTables();

    const bufs = try allocator.alloc(Buffer, wl_outputs.len);
    errdefer allocator.free(bufs);
    const ctxs = try allocator.alloc(FrameCtx, wl_outputs.len);
    defer allocator.free(ctxs);

    for (wl_outputs, 0..) |out, i| {
        ctxs[i] = .{ .allocator = allocator, .shm = shm_proxy };
        const version = wl.wl_proxy_get_version(mgr);
        const frame = wl.wl_proxy_marshal_flags(mgr, CAPTURE_OUTPUT_OPCODE, &screencopy_frame_interface, version, 0, @as(?*wl.wl_proxy, null), @as(c_int, 0), out) orelse return error.CaptureAllocFailed;
        ctxs[i].frame = frame;
        // @constCast is required because wl_proxy_add_listener takes a
        // non-const pointer, while frame_listener is a module-level const
        // that libwayland only reads.
        if (wl.wl_proxy_add_listener(frame, @ptrCast(@constCast(&frame_listener)), &ctxs[i]) < 0) return error.ListenerFailed;
    }
    defer for (ctxs) |*cx| cx.cleanup();

    // Roundtrip until every frame resolves. A compositor that never answers
    // must not spin forever: bail out after a few stalled roundtrips.
    var stalled: usize = 0;
    while (true) {
        var pending: usize = 0;
        for (ctxs) |*cx| {
            if (cx.status == .pending) pending += 1;
        }
        if (pending == 0) break;
        if (stalled > 4) return error.CaptureStalled;
        if (wl.wl_display_roundtrip(dpy) < 0) return error.RoundtripFailed;
        stalled += 1;
    }

    var filled: usize = 0;
    errdefer for (bufs[0..filled]) |b| allocator.free(b.data);
    for (ctxs, 0..) |*cx, i| {
        if (cx.status != .ready or cx.result == null) return error.CaptureFailed;
        bufs[i] = cx.result.?;
        filled += 1;
    }
    return bufs;
}

const FrameListener = extern struct {
    buffer: *const fn (?*anyopaque, ?*wl.wl_proxy, u32, u32, u32, u32) callconv(.c) void,
    flags: *const fn (?*anyopaque, ?*wl.wl_proxy, u32) callconv(.c) void,
    ready: *const fn (?*anyopaque, ?*wl.wl_proxy, u32, u32, u32) callconv(.c) void,
    failed: *const fn (?*anyopaque, ?*wl.wl_proxy) callconv(.c) void,
    damage: *const fn (?*anyopaque, ?*wl.wl_proxy, u32, u32, u32, u32) callconv(.c) void,
    linux_dmabuf: *const fn (?*anyopaque, ?*wl.wl_proxy, u32, u32, u32) callconv(.c) void,
    buffer_done: *const fn (?*anyopaque, ?*wl.wl_proxy) callconv(.c) void,
};

const frame_listener = FrameListener{
    .buffer = onFrameBuffer,
    .flags = onFrameFlags,
    .ready = onFrameReady,
    .failed = onFrameFailed,
    .damage = onFrameDamage,
    .linux_dmabuf = onFrameLinuxDmabuf,
    .buffer_done = onFrameBufferDone,
};

fn ctxFrom(data: ?*anyopaque) *FrameCtx {
    return @ptrCast(@alignCast(data.?));
}

fn onFrameBuffer(data: ?*anyopaque, frame: ?*wl.wl_proxy, format: u32, width: u32, height: u32, stride: u32) callconv(.c) void {
    _ = frame;
    const cx = ctxFrom(data);
    if (cx.status != .pending) return;
    cx.width = width;
    cx.height = height;
    cx.stride = stride;
    cx.format = format;
    // Little-endian ARGB8888/XRGB8888 are BGRA bytes in memory; both map to
    // our .bgra (XRGB's unused channel reads as opaque).
    cx.shm_offered = format == wl.WL_SHM_FORMAT_ARGB8888 or format == wl.WL_SHM_FORMAT_XRGB8888;
}

fn onFrameBufferDone(data: ?*anyopaque, frame: ?*wl.wl_proxy) callconv(.c) void {
    const cx = ctxFrom(data);
    if (cx.status != .pending) return;
    const f = frame orelse {
        cx.status = .failed;
        return;
    };
    if (!cx.shm_offered or cx.width == 0 or cx.height == 0) {
        cx.status = .failed;
        return;
    }
    const size: usize = @as(usize, cx.stride) * cx.height;
    const fd_rc = std.os.linux.memfd_create("zigit-capture", std.os.linux.MFD.CLOEXEC);
    if (std.os.linux.errno(fd_rc) != .SUCCESS) {
        cx.status = .failed;
        return;
    }
    cx.fd = @intCast(fd_rc);
    if (std.c.ftruncate(cx.fd, @intCast(size)) != 0) {
        cx.status = .failed;
        return;
    }
    cx.map = std.posix.mmap(null, size, .{ .READ = true, .WRITE = true }, .{ .TYPE = .SHARED }, cx.fd, 0) catch {
        cx.status = .failed;
        return;
    };
    const pool = wl.wl_shm_create_pool(cx.shm, cx.fd, @intCast(size)) orelse {
        cx.status = .failed;
        return;
    };
    defer wl.wl_shm_pool_destroy(pool);
    cx.wl_buffer = wl.wl_shm_pool_create_buffer(pool, 0, @intCast(cx.width), @intCast(cx.height), @intCast(cx.stride), cx.format) orelse {
        cx.status = .failed;
        return;
    };
    _ = wl.wl_proxy_marshal_flags(f, FRAME_COPY_OPCODE, null, wl.wl_proxy_get_version(f), 0, cx.wl_buffer);
}

fn onFrameReady(data: ?*anyopaque, frame: ?*wl.wl_proxy, tv_sec_hi: u32, tv_sec_lo: u32, tv_nsec: u32) callconv(.c) void {
    _ = frame;
    _ = tv_sec_hi;
    _ = tv_sec_lo;
    _ = tv_nsec;
    const cx = ctxFrom(data);
    if (cx.status != .pending) return;
    const size: usize = @as(usize, cx.stride) * cx.height;
    if (cx.map.len < size) {
        cx.status = .failed;
        return;
    }
    const copy = cx.allocator.alloc(u8, size) catch {
        cx.status = .failed;
        return;
    };
    @memcpy(copy, cx.map[0..size]);
    cx.result = .{ .width = cx.width, .height = cx.height, .stride = cx.stride, .format = .bgra, .data = copy };
    cx.status = .ready;
    // The copy is complete; drop compositor resources immediately.
    cx.cleanup();
}

fn onFrameFailed(data: ?*anyopaque, frame: ?*wl.wl_proxy) callconv(.c) void {
    _ = frame;
    const cx = ctxFrom(data);
    cx.status = .failed;
    cx.cleanup();
}

fn onFrameFlags(data: ?*anyopaque, frame: ?*wl.wl_proxy, flags: u32) callconv(.c) void {
    _ = data;
    _ = frame;
    _ = flags;
}

fn onFrameDamage(data: ?*anyopaque, frame: ?*wl.wl_proxy, x: u32, y: u32, width: u32, height: u32) callconv(.c) void {
    _ = data;
    _ = frame;
    _ = x;
    _ = y;
    _ = width;
    _ = height;
}

fn onFrameLinuxDmabuf(data: ?*anyopaque, frame: ?*wl.wl_proxy, format: u32, width: u32, height: u32) callconv(.c) void {
    // Only shm capture is implemented; the compositor also advertises the
    // plain "buffer" event when it supports shm.
    _ = data;
    _ = frame;
    _ = format;
    _ = width;
    _ = height;
}
