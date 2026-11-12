const std = @import("std");
// inotify bindings, translated at build time (Zig 0.17 has no @cImport).
// See src/ctypes/inotify.h.
const c = @import("c_inotify");

pub const Event = enum { created, deleted, modified };

pub const Watcher = struct {
    fd: std.posix.fd_t,
    dir: []const u8,

    pub fn init(dir: []const u8) !Watcher {
        const fd = std.c.inotify_init1(c.IN_NONBLOCK | c.IN_CLOEXEC);
        if (fd < 0) return error.InotifyInitFailed;
        errdefer _ = std.c.close(fd);
        const dir_z = try std.heap.page_allocator.dupeSentinel(u8, dir, 0);
        defer std.heap.page_allocator.free(dir_z);
        if (std.c.inotify_add_watch(fd, dir_z.ptr, c.IN_CREATE | c.IN_DELETE | c.IN_MODIFY | c.IN_MOVED_FROM | c.IN_MOVED_TO) < 0)
            return error.InotifyAddWatchFailed;
        return .{ .fd = fd, .dir = dir };
    }

    pub fn deinit(self: *Watcher) void {
        _ = std.c.close(self.fd);
    }

    pub fn tryRead(self: *Watcher) !?Event {
        var buf: [4096]u8 align(@alignOf(c.inotify_event)) = undefined;
        const n = std.posix.read(self.fd, &buf) catch |e| switch (e) {
            error.WouldBlock => return null,
            else => return e,
        };
        if (n == 0) return null;
        var offset: usize = 0;
        while (offset < n) {
            const ev: *const c.inotify_event = @ptrCast(@alignCast(buf[offset..].ptr));
            if (ev.mask & c.IN_CREATE != 0 or ev.mask & c.IN_MOVED_TO != 0) return .created;
            if (ev.mask & c.IN_DELETE != 0 or ev.mask & c.IN_MOVED_FROM != 0) return .deleted;
            if (ev.mask & c.IN_MODIFY != 0) return .modified;
            const step = @sizeOf(c.inotify_event) + ev.len;
            if (step == 0) break;
            offset += step;
        }
        return null;
    }
};
