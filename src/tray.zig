const std = @import("std");

const c = @cImport({
    @cInclude("tray_c.h");
});

pub const Tray = struct {
    handle: ?*c.ZigitTray = null,

    pub fn init() Tray {
        const handle = c.zigit_tray_create();
        if (handle == null) {
            std.debug.print("zigit: tray unavailable; continuing without system tray icon\n", .{});
        }
        return .{ .handle = handle };
    }

    pub fn deinit(self: *Tray) void {
        if (self.handle) |h| {
            c.zigit_tray_destroy(h);
            self.handle = null;
        }
    }

    pub fn ok(self: *const Tray) bool {
        return self.handle != null;
    }

    pub fn poll(self: *Tray) void {
        if (self.handle) |h| c.zigit_tray_poll(h);
    }

    /// Tray-only idle: wait on GLib/DBus so the StatusNotifier menu stays snappy.
    pub fn wait(self: *Tray, timeout_ms: u32) void {
        // C side accepts NULL and falls back to g_usleep.
        c.zigit_tray_wait(self.handle, timeout_ms);
    }

    pub fn takeShow(self: *Tray) bool {
        return if (self.handle) |h| c.zigit_tray_take_show(h) else false;
    }
    pub fn takeQuit(self: *Tray) bool {
        return if (self.handle) |h| c.zigit_tray_take_quit(h) else false;
    }
    pub fn takeCaptureRegion(self: *Tray) bool {
        return if (self.handle) |h| c.zigit_tray_take_capture_region(h) else false;
    }
    pub fn takeCaptureWindow(self: *Tray) bool {
        return if (self.handle) |h| c.zigit_tray_take_capture_window(h) else false;
    }
};
