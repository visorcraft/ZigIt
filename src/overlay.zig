const std = @import("std");
const app_io = @import("app_io");
const wayland = @import("wayland");
const capture = @import("capture");
const storage = @import("storage");
const clipboard = @import("clipboard");
const toplevel = @import("toplevel");
const spawn = @import("spawn");
const config = @import("config");

/// Capture mode for `zigit capture` (aligned with config.CaptureMode).
const Mode = enum { region, fullscreen, window };

pub const Overlay = struct {
    pub fn run(allocator: std.mem.Allocator, argv: []const []const u8) !void {
        var mode: Mode = .region;
        for (argv) |a| {
            if (std.mem.eql(u8, a, "--overlay") or std.mem.eql(u8, a, "--fullscreen")) {
                mode = .fullscreen;
            } else if (std.mem.eql(u8, a, "--window")) {
                mode = .window;
            } else if (std.mem.eql(u8, a, "--region")) {
                mode = .region;
            } else {
                std.debug.print("zigit: unknown flag '{s}'\nusage: zigit capture [--region|--overlay|--window]\n", .{a});
                return error.UnknownFlag;
            }
        }

        // Detect wlr-screencopy once. grim and native wlr both need it; probing
        // avoids running slurp on KDE then failing at grim (double UI).
        const wlr = hasWlrScreencopy(allocator);

        // Backend order (UX first):
        //  1–2. wlr stack (Hyprland/Sway): grim + slurp, else native screencopy
        //  3. spectacle when installed — best KDE region UX (no portal "Request
        //     Screenshot" permission dialog every time)
        //  4. xdg-desktop-portal only if spectacle is missing (works, but the
        //     desktop may show a permission prompt and a Spectacle-like UI)
        if (wlr) {
            if (tryCapture(allocator, mode, "grim", captureGrim)) return;
            if (tryCapture(allocator, mode, "wlr-screencopy", captureWlr)) return;
        }
        if (tryCapture(allocator, mode, "spectacle", captureSpectacle)) return;
        if (tryCapture(allocator, mode, "xdg-desktop-portal", capturePortal)) return;

        std.debug.print(
            \\zigit: no capture backend available.
            \\  On Sway/Hyprland: install grim and slurp (e.g. pacman -S grim slurp).
            \\  On KDE: install spectacle for region capture, or use a portal
            \\    that does not require a permission dialog every shot.
            \\
        , .{});
        return error.NoCaptureBackend;
    }
};

const CaptureFn = *const fn (std.mem.Allocator, Mode, []const u8) anyerror!void;

fn hasWlrScreencopy(allocator: std.mem.Allocator) bool {
    var conn = wayland.Connection.init() catch return false;
    defer conn.deinit();
    var en = conn.enumerate(allocator) catch return false;
    defer en.deinit(allocator);
    return en.screencopy != null;
}

fn tryCapture(allocator: std.mem.Allocator, mode: Mode, name: []const u8, f: CaptureFn) bool {
    const save_dir = configuredCaptureDir(allocator) catch return false;
    defer allocator.free(save_dir);
    const out_path = storage.newCapturePath(allocator, save_dir) catch return false;
    defer allocator.free(out_path);

    f(allocator, mode, out_path) catch |e| {
        switch (e) {
            error.GrimMissing, error.SlurpMissing, error.ScreencopyUnavailable, error.PortalMissing, error.SpectacleMissing, error.PortalCancelled, error.Cancelled => {
                std.debug.print("zigit: backend {s}: skip ({s})\n", .{ name, @errorName(e) });
            },
            else => std.debug.print("zigit: backend {s} failed: {s}\n", .{ name, @errorName(e) }),
        }
        std.Io.Dir.deleteFileAbsolute(app_io.get(), out_path) catch {};
        return false;
    };

    std.debug.print("zigit: captured via {s} → {s}\n", .{ name, out_path });
    finishCapture(allocator, out_path) catch |e| {
        std.debug.print("zigit: post-capture failed: {s}\n", .{@errorName(e)});
    };
    return true;
}

fn finishCapture(allocator: std.mem.Allocator, out_path: []const u8) !void {
    std.Io.Dir.accessAbsolute(app_io.get(), out_path, .{}) catch |e| switch (e) {
        error.FileNotFound => {
            std.debug.print("zigit: capture cancelled\n", .{});
            return;
        },
        else => return e,
    };
    const png_bytes = try std.Io.Dir.cwd().readFileAlloc(app_io.get(), out_path, allocator, .limited(256 << 20));
    defer allocator.free(png_bytes);
    clipboard.copyPNG(allocator, png_bytes) catch |e| {
        std.debug.print("zigit: clipboard copy failed: {s}\n", .{@errorName(e)});
    };
    try spawn.editor(allocator, out_path);
}

// ── grim (+ slurp) ──────────────────────────────────────────────────

fn captureGrim(allocator: std.mem.Allocator, mode: Mode, out_path: []const u8) !void {
    if (!spawn.commandExists(allocator, "grim")) return error.GrimMissing;
    switch (mode) {
        .region => {
            if (!spawn.commandExists(allocator, "slurp")) return error.SlurpMissing;
            const rect = try spawn.slurpRegion(allocator);
            const r = rect orelse return error.Cancelled;
            var geom_buf: [64]u8 = undefined;
            const geom = try std.fmt.bufPrint(&geom_buf, "{d},{d} {d}x{d}", .{ r.x, r.y, r.w, r.h });
            try spawn.grim(allocator, out_path, geom);
        },
        .fullscreen => try spawn.grim(allocator, out_path, null),
        .window => return error.GrimMissing,
    }
}

// ── native wlr-screencopy ───────────────────────────────────────────

fn captureWlr(allocator: std.mem.Allocator, mode: Mode, out_path: []const u8) !void {
    var conn = try wayland.Connection.init();
    defer conn.deinit();
    var en = try conn.enumerate(allocator);
    defer en.deinit(allocator);
    const sc = en.screencopy orelse return error.ScreencopyUnavailable;
    const shm = en.shm orelse return error.ScreencopyUnavailable;
    if (en.outputs.len == 0) return error.NoOutputs;

    const manager = capture.bindScreencopyManager(conn.registry, sc.name, sc.version) orelse return error.BindFailed;
    const wl_outputs = try allocator.alloc(*anyopaque, en.outputs.len);
    defer allocator.free(wl_outputs);
    for (en.outputs, 0..) |o, i| wl_outputs[i] = o.wl_output orelse return error.NoOutputProxy;
    const bufs = try capture.captureAllOutputs(allocator, conn.display, manager, shm, wl_outputs);
    defer {
        for (bufs) |b| allocator.free(b.data);
        allocator.free(bufs);
    }

    var rect: capture.Rect = .{ .x = 0, .y = 0, .w = bufs[0].width, .h = bufs[0].height };
    switch (mode) {
        .fullscreen => {},
        .region => {
            if (spawn.commandExists(allocator, "slurp")) {
                if (try spawn.slurpRegion(allocator)) |r| {
                    rect = .{ .x = r.x, .y = r.y, .w = r.w, .h = r.h };
                } else return error.Cancelled;
            } else {
                std.debug.print("zigit: slurp not found; capturing full output (install slurp for region select)\n", .{});
            }
        },
        .window => {
            if (try toplevel.underCursor(allocator, manager, 0, 0)) |r| {
                rect = r;
            } else {
                std.debug.print("zigit: window pick unavailable; capturing full output\n", .{});
            }
        },
    }

    const cropped = try stitchAndCrop(allocator, bufs, rect);
    defer allocator.free(cropped.data);
    const result = try capture.Pipeline.run(allocator, cropped.data, cropped.width, cropped.height);
    defer allocator.free(result.png);
    try storage.writeFileAbsolute(out_path, result.png);
}

// ── xdg-desktop-portal ──────────────────────────────────────────────

fn capturePortal(allocator: std.mem.Allocator, mode: Mode, out_path: []const u8) !void {
    const interactive = mode != .fullscreen;
    try spawn.portalScreenshot(allocator, out_path, interactive);
}

// ── spectacle (optional last resort) ────────────────────────────────

fn captureSpectacle(allocator: std.mem.Allocator, mode: Mode, out_path: []const u8) !void {
    if (!spawn.commandExists(allocator, "spectacle")) return error.SpectacleMissing;
    const flag: []const u8 = switch (mode) {
        .region => "--region",
        .fullscreen => "--fullscreen",
        .window => "--activewindow",
    };
    try spawn.spectacle(allocator, flag, out_path);
}

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
    const rgba = try buffers[0].toRGBA(allocator);
    defer allocator.free(rgba.data);
    return rgba.cropRect(allocator, rect);
}
