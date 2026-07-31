const std = @import("std");
const c = @cImport(@cInclude("sys/inotify.h"));

pub const Event = enum { created, deleted, modified };

pub const Watcher = struct {
    fd: std.posix.fd_t,
    dir: []const u8,

    pub fn init(dir: []const u8) !Watcher {
        const fd = std.posix.inotify_init1(c.IN_NONBLOCK | c.IN_CLOEXEC) catch
            return error.InotifyInitFailed;
        errdefer std.posix.close(fd);
        _ = std.posix.inotify_add_watch(fd, dir, c.IN_CREATE | c.IN_DELETE | c.IN_MODIFY | c.IN_MOVED_FROM | c.IN_MOVED_TO) catch
            return error.InotifyAddWatchFailed;
        return .{ .fd = fd, .dir = dir };
    }

    pub fn deinit(self: *Watcher) void {
        std.posix.close(self.fd);
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
