const std = @import("std");

pub const Level = enum { debug, info, warn, @"error" };

const max_bytes: u64 = 1 << 20;
const keep_rotations: u32 = 3;

pub const Log = struct {
    path: []u8,
    file: std.fs.File,
    size: u64,

    pub fn init(path: []const u8) !Log {
        if (std.fs.path.dirname(path)) |d| {
            std.fs.makeDirAbsolute(d) catch |e| switch (e) {
                error.PathAlreadyExists => {},
                else => return e,
            };
        }
        const f = try std.fs.createFileAbsolute(path, .{ .truncate = false });
        // Append to any existing log instead of overwriting from offset 0.
        const pos = try f.getEndPos();
        try f.seekFromEnd(0);
        return .{ .path = try std.heap.page_allocator.dupe(u8, path), .file = f, .size = pos };
    }

    pub fn deinit(self: *Log) void {
        self.file.close();
        std.heap.page_allocator.free(self.path);
    }

    pub fn write(self: *Log, level: Level, msg: []const u8) !void {
        if (self.size + msg.len + 64 > max_bytes) try self.rotate();
        const ts = std.time.timestamp();
        const line = try std.fmt.allocPrint(std.heap.page_allocator, "[{d}] [{s}] {s}\n", .{ ts, @tagName(level), msg });
        defer std.heap.page_allocator.free(line);
        try self.file.writeAll(line);
        self.size += line.len;
    }

    fn rotate(self: *Log) !void {
        // Shift zigit.log.N -> zigit.log.N+1 up to keep_rotations; drop oldest.
        var i: u32 = keep_rotations;
        while (i > 0) : (i -= 1) {
            const src = try std.fmt.allocPrint(std.heap.page_allocator, "{s}.{d}", .{ self.path, i });
            defer std.heap.page_allocator.free(src);
            const dst = try std.fmt.allocPrint(std.heap.page_allocator, "{s}.{d}", .{ self.path, i + 1 });
            defer std.heap.page_allocator.free(dst);
            std.fs.renameAbsolute(src, dst) catch |e| switch (e) {
                error.FileNotFound => {},
                else => return e,
            };
        }
        self.file.close();
        const first = try std.fmt.allocPrint(std.heap.page_allocator, "{s}.1", .{self.path});
        defer std.heap.page_allocator.free(first);
        try std.fs.renameAbsolute(self.path, first);
        self.file = try std.fs.createFileAbsolute(self.path, .{ .truncate = true });
        self.size = 0;
    }
};
