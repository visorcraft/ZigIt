const std = @import("std");
const app_io = @import("app_io");
const wayland = @import("wayland");
const capture = @import("capture");
const storage = @import("storage");
const clipboard = @import("clipboard");
const toplevel = @import("toplevel");
const spawn = @import("spawn");
const config = @import("config");

pub const Overlay = struct {
    pub fn run(allocator: std.mem.Allocator, argv: []const []const u8) !void {
        var window_pick = false;
        var fullscreen = false;
        for (argv) |a| {
            if (std.mem.eql(u8, a, "--overlay")) {
                // Explicit full-screen capture; the flag the compositor hotkey
                // action installs. Without it the default is an interactive
                // rectangle pick.
                fullscreen = true;
            } else if (std.mem.eql(u8, a, "--window")) {
                window_pick = true;
            } else {
                std.debug.print("zigit: unknown flag '{s}'\nusage: zigit capture [--overlay|--window]\n", .{a});
                return error.UnknownFlag;
            }
        }

        runWlr(allocator, window_pick) catch |e| switch (e) {
            // Compositor lacks zwlr_screencopy_manager_v1 (e.g. KWin): fall
            // back to spectacle, KDE's native capture tool.
            error.ScreencopyUnavailable => return runSpectacle(allocator, window_pick, fullscreen),
            else => return e,
        };
    }

    /// KDE/portal fallback: let spectacle do the capture. No flag means an
    /// interactive drag-rectangle pick (spectacle --region), matching the
    /// core "Print Screen → drag rectangle" UX; --overlay means fullscreen.
    fn runSpectacle(allocator: std.mem.Allocator, window_pick: bool, fullscreen: bool) !void {
        const mode: []const u8 = if (window_pick)
            "--activewindow"
        else if (fullscreen)
            "--fullscreen"
        else
            "--region";
        // Resolve the output path first so the file lands directly in the
        // captures dir the daemon's marquee watches.
        const save_dir = try configuredCaptureDir(allocator);
        defer allocator.free(save_dir);
        const out_path = try storage.newCapturePath(allocator, save_dir);
        defer allocator.free(out_path);
        try spawn.spectacle(allocator, mode, out_path);
        // spectacle exits 0 even when the user cancels the region pick; a
        // missing output file is a quiet cancel, not an error.
        std.Io.Dir.accessAbsolute(app_io.get(), out_path, .{}) catch |e| switch (e) {
            error.FileNotFound => {
                std.debug.print("zigit: capture cancelled\n", .{});
                return;
            },
            else => return e,
        };
        const png = try std.Io.Dir.cwd().readFileAlloc(app_io.get(), out_path, allocator, .limited(16 * 1024 * 1024));
        defer allocator.free(png);
        try clipboard.copyPNG(allocator, png);
        try spawn.editor(allocator, out_path);
    }

    fn runWlr(allocator: std.mem.Allocator, window_pick: bool) !void {
        // 1. Fresh connection: the overlay is a transient process and does
        //    not share the daemon's display.
        var conn = try wayland.Connection.init();
        defer conn.deinit();
        var en = try conn.enumerate(allocator);
        defer en.deinit(allocator);
        const sc = en.screencopy orelse return error.ScreencopyUnavailable;
        const shm = en.shm orelse return error.ScreencopyUnavailable;
        if (en.outputs.len == 0) return error.NoOutputs;

        // 2. Capture every output into a Buffer.
        const manager = capture.bindScreencopyManager(conn.registry, sc.name, sc.version) orelse return error.BindFailed;
        const wl_outputs = try allocator.alloc(*anyopaque, en.outputs.len);
        defer allocator.free(wl_outputs);
        for (en.outputs, 0..) |o, i| wl_outputs[i] = o.wl_output orelse return error.NoOutputProxy;
        const bufs = try capture.captureAllOutputs(allocator, conn.display, manager, shm, wl_outputs);
        defer {
            for (bufs) |b| allocator.free(b.data);
            allocator.free(bufs);
        }

        // 3. Region selection. The interactive drag overlay depends on the
        //    layer-shell surface (still a stub), so v1 captures the full
        //    extent of the first output; multi-output stitching is v1.1.
        var rect: capture.Rect = .{ .x = 0, .y = 0, .w = bufs[0].width, .h = bufs[0].height };
        if (window_pick) {
            // zwlr_foreign_toplevel_management_v1 exposes no window geometry,
            // so underCursor can only resolve on compositors with a geometry
            // extension; otherwise keep the full-output rect and warn.
            if (try toplevel.underCursor(allocator, manager, 0, 0)) |r| {
                rect = r;
            } else {
                std.debug.print("zigit: window pick unavailable (compositor exposes no toplevel geometry); capturing full output\n", .{});
            }
        }
        const cropped = try stitchAndCrop(allocator, bufs, rect);
        defer allocator.free(cropped.data);

        // 4. Encode + save + clipboard + spawn. Use the cropped buffer's
        //    clamped dimensions, not the unclamped rect: a rect extending
        //    past the output would otherwise encode out-of-bounds rows.
        const result = try capture.Pipeline.run(allocator, cropped.data, cropped.width, cropped.height);
        defer allocator.free(result.png);
        const save_dir = try configuredCaptureDir(allocator);
        defer allocator.free(save_dir);
        const out_path = try storage.newCapturePath(allocator, save_dir);
        defer allocator.free(out_path);
        try storage.writeFileAbsolute(out_path, result.png);
        try clipboard.copyPNG(allocator, result.png);
        try spawn.editor(allocator, out_path);
    }
};

/// Loads ~/.config/zigit/config.toml save_dir (or ~/screenshots when unset).
fn configuredCaptureDir(allocator: std.mem.Allocator) ![]u8 {
    const cfg_path = config.Config.configPath(allocator) catch {
        return storage.captureDir(allocator, "");
    };
    defer allocator.free(cfg_path);
    const cfg = config.Config.load(allocator, cfg_path) catch {
        return storage.captureDir(allocator, "");
    };
    defer cfg.deinit(allocator);
    return storage.captureDir(allocator, cfg.save_dir);
}

fn stitchAndCrop(allocator: std.mem.Allocator, buffers: []capture.Buffer, rect: capture.Rect) !capture.Buffer {
    // For v1: assume single-output capture (rect fully inside buffers[0]).
    // Multi-output stitching is v1.1.
    const rgba = try buffers[0].toRGBA(allocator);
    defer allocator.free(rgba.data);
    return rgba.cropRect(allocator, rect); // ownership transferred; caller frees .data
}
