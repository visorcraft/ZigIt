const std = @import("std");
const app_io = @import("app_io");
const net = std.Io.net;

/// Single-instance control for the daemon.
/// First process binds `$XDG_RUNTIME_DIR/zigit.sock` (or /tmp fallback).
/// Later processes connect, send "show\n", and exit so only one UI runs.
pub const Command = enum { none, show };

pub const Role = enum { primary, secondary_shown };

pub const Instance = struct {
    server: ?net.Server = null,
    path: []u8,
    allocator: std.mem.Allocator,

    /// Try to become the primary daemon. If another is running, send show and
    /// return `.secondary_shown` (caller should exit).
    pub fn acquire(allocator: std.mem.Allocator) !struct { Instance, Role } {
        const path = try socketPath(allocator);
        errdefer allocator.free(path);
        const io = app_io.get();
        const ua = try net.UnixAddress.init(path);

        // Try connect first — if success, another daemon is up.
        if (net.UnixAddress.connect(&ua, io)) |stream| {
            defer stream.close(io);
            var wbuf: [8]u8 = undefined;
            var w = stream.writer(io, &wbuf);
            w.interface.writeAll("show\n") catch {};
            w.interface.flush() catch {};
            return .{
                .{ .server = null, .path = path, .allocator = allocator },
                .secondary_shown,
            };
        } else |_| {}

        // Remove stale socket from a crashed previous run.
        std.Io.Dir.deleteFileAbsolute(io, path) catch {};

        const server = net.UnixAddress.listen(&ua, io, .{ .kernel_backlog = 4 }) catch |e| {
            // Race: another process bound between connect and bind.
            if (e == error.AddressInUse) {
                if (net.UnixAddress.connect(&ua, io)) |stream| {
                    defer stream.close(io);
                    var wbuf: [8]u8 = undefined;
                    var w = stream.writer(io, &wbuf);
                    w.interface.writeAll("show\n") catch {};
                    w.interface.flush() catch {};
                    return .{
                        .{ .server = null, .path = path, .allocator = allocator },
                        .secondary_shown,
                    };
                } else |_| {}
            }
            return e;
        };

        // Non-blocking accept so the UI loop never stalls.
        setNonblock(server.socket.handle) catch {};

        return .{
            .{ .server = server, .path = path, .allocator = allocator },
            .primary,
        };
    }

    pub fn deinit(self: *Instance) void {
        const io = app_io.get();
        if (self.server) |*s| {
            s.deinit(io);
            self.server = null;
        }
        std.Io.Dir.deleteFileAbsolute(io, self.path) catch {};
        self.allocator.free(self.path);
    }

    /// Non-blocking: accept clients and return .show if any asked to raise UI.
    pub fn poll(self: *Instance) Command {
        const server = if (self.server) |*s| s else return .none;
        const io = app_io.get();
        var saw_show = false;
        while (true) {
            const stream = server.accept(io) catch |e| switch (e) {
                error.WouldBlock => break,
                else => break,
            };
            defer stream.close(io);
            var rbuf: [64]u8 = undefined;
            var r = stream.reader(io, &rbuf);
            var msg: [64]u8 = undefined;
            const n = r.interface.readSliceShort(&msg) catch 0;
            if (n > 0 and std.mem.indexOf(u8, msg[0..n], "show") != null) {
                saw_show = true;
            }
        }
        return if (saw_show) .show else .none;
    }
};

fn socketPath(allocator: std.mem.Allocator) ![]u8 {
    if (std.c.getenv("XDG_RUNTIME_DIR")) |z| {
        const runtime = std.mem.span(z);
        return std.fs.path.join(allocator, &.{ runtime, "zigit.sock" });
    }
    const uid = std.os.linux.getuid();
    return std.fmt.allocPrint(allocator, "/tmp/zigit-{d}.sock", .{uid});
}

fn setNonblock(fd: std.posix.socket_t) !void {
    // O_NONBLOCK so Server.accept returns WouldBlock when idle.
    const O_NONBLOCK: c_int = 0x800; // linux
    const F_GETFL: c_int = 3;
    const F_SETFL: c_int = 4;
    const flags = std.c.fcntl(fd, F_GETFL);
    if (flags < 0) return error.FcntlFailed;
    if (std.c.fcntl(fd, F_SETFL, flags | O_NONBLOCK) < 0) return error.FcntlFailed;
}
