const std = @import("std");
const app_io = @import("app_io");

pub const Level = enum { debug, info, warn, @"error" };

const max_bytes: u64 = 1 << 20;
const keep_rotations: u32 = 3;

pub const Log = struct {
    path: []u8,
    file: std.Io.File,
    size: u64,

    pub fn init(path: []const u8) !Log {
        const io = app_io.get();
        if (std.fs.path.dirname(path)) |d| {
            std.Io.Dir.cwd().createDirPath(io, d) catch |e| switch (e) {
                error.PathAlreadyExists => {},
                else => return e,
            };
        }
        const f = try std.Io.Dir.createFileAbsolute(io, path, .{ .truncate = false });
        const pos = try f.length(io);
        if (pos > 0) {
            var w = f.writer(io, &.{});
            try w.seekTo(pos);
        }
        return .{ .path = try std.heap.page_allocator.dupe(u8, path), .file = f, .size = pos };
    }

    pub fn deinit(self: *Log) void {
        self.file.close(app_io.get());
        std.heap.page_allocator.free(self.path);
    }

    pub fn write(self: *Log, level: Level, msg: []const u8) !void {
        const io = app_io.get();
        if (self.size + msg.len + 64 > max_bytes) try self.rotate();
        const ts = std.Io.Clock.real.now(app_io.get()).toSeconds();
        const line = try std.fmt.allocPrint(std.heap.page_allocator, "[{d}] [{s}] {s}\n", .{ ts, @tagName(level), msg });
        defer std.heap.page_allocator.free(line);
        try self.file.writeStreamingAll(io, line);
        self.size += line.len;
    }

    fn rotate(self: *Log) !void {
        const io = app_io.get();
        // Shift zigit.log.N -> zigit.log.N+1 up to keep_rotations; drop oldest.
        var i: u32 = keep_rotations;
        while (i > 0) : (i -= 1) {
            const src = try std.fmt.allocPrint(std.heap.page_allocator, "{s}.{d}", .{ self.path, i });
            defer std.heap.page_allocator.free(src);
            const dst = try std.fmt.allocPrint(std.heap.page_allocator, "{s}.{d}", .{ self.path, i + 1 });
            defer std.heap.page_allocator.free(dst);
            std.Io.Dir.renameAbsolute(src, dst, io) catch |e| switch (e) {
                error.FileNotFound => {},
                else => return e,
            };
        }
        self.file.close(io);
        const first = try std.fmt.allocPrint(std.heap.page_allocator, "{s}.1", .{self.path});
        defer std.heap.page_allocator.free(first);
        try std.Io.Dir.renameAbsolute(self.path, first, io);
        self.file = try std.Io.Dir.createFileAbsolute(io, self.path, .{ .truncate = true });
        self.size = 0;
    }
};
