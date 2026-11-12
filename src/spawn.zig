const std = @import("std");
const app_io = @import("app_io");

var token_counter: std.atomic.Value(u32) = .init(1);

pub fn editor(allocator: std.mem.Allocator, png_path: []const u8) !void {
    _ = allocator;
    const io = app_io.get();
    _ = std.process.spawn(io, .{
        .argv = &.{ "zigit", "edit", png_path },
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .inherit,
    }) catch |e| switch (e) {
        error.FileNotFound => return error.ZigitMissing,
        else => return e,
    };
}

/// Returns true if `name` is an executable on PATH.
pub fn commandExists(allocator: std.mem.Allocator, name: []const u8) bool {
    const io = app_io.get();
    const result = std.process.run(allocator, io, .{
        .argv = &.{ "which", name },
        .stdout_limit = .limited(512),
        .stderr_limit = .limited(512),
    }) catch return false;
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    return switch (result.term) {
        .exited => |code| code == 0,
        else => false,
    };
}

pub const SlurpRect = struct { x: i32, y: i32, w: u32, h: u32 };

/// Interactive region pick via `slurp`. Cancel → null.
pub fn slurpRegion(allocator: std.mem.Allocator) !?SlurpRect {
    const io = app_io.get();
    const result = std.process.run(allocator, io, .{
        .argv = &.{ "slurp", "-f", "%x,%y %wx%h" },
        .stdout_limit = .limited(256),
        .stderr_limit = .limited(1024),
    }) catch |e| switch (e) {
        error.FileNotFound => return error.SlurpMissing,
        else => return e,
    };
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    switch (result.term) {
        .exited => |code| if (code != 0) return null,
        else => return error.SlurpFailed,
    }
    const line = std.mem.trim(u8, result.stdout, " \t\r\n");
    if (line.len == 0) return null;
    var it = std.mem.tokenizeAny(u8, line, ", x");
    const xs = it.next() orelse return error.SlurpParse;
    const ys = it.next() orelse return error.SlurpParse;
    const ws = it.next() orelse return error.SlurpParse;
    const hs = it.next() orelse return error.SlurpParse;
    return .{
        .x = try std.fmt.parseInt(i32, xs, 10),
        .y = try std.fmt.parseInt(i32, ys, 10),
        .w = try std.fmt.parseInt(u32, ws, 10),
        .h = try std.fmt.parseInt(u32, hs, 10),
    };
}

pub fn grim(allocator: std.mem.Allocator, out_path: []const u8, geometry: ?[]const u8) !void {
    const io = app_io.get();
    var argv_buf: [6][]const u8 = undefined;
    var n: usize = 0;
    argv_buf[n] = "grim";
    n += 1;
    if (geometry) |g| {
        argv_buf[n] = "-g";
        n += 1;
        argv_buf[n] = g;
        n += 1;
    }
    argv_buf[n] = out_path;
    n += 1;
    const result = std.process.run(allocator, io, .{
        .argv = argv_buf[0..n],
        .stdout_limit = .limited(256),
        .stderr_limit = .limited(4096),
    }) catch |e| switch (e) {
        error.FileNotFound => return error.GrimMissing,
        else => return e,
    };
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    switch (result.term) {
        .exited => |code| if (code != 0) return error.GrimFailed,
        else => return error.GrimFailed,
    }
}

/// xdg-desktop-portal Screenshot. Interactive opens the desktop's region UI
/// (on KDE that is portal-kde — it may *look* like Spectacle but is not our
/// direct spectacle spawn).
pub fn portalScreenshot(allocator: std.mem.Allocator, out_path: []const u8, interactive: bool) !void {
    const io = app_io.get();
    if (!commandExists(allocator, "gdbus")) return error.PortalMissing;

    // Unique token; we still parse the request path from the call result.
    const token_n = token_counter.fetchAdd(1, .monotonic);
    var token_buf: [32]u8 = undefined;
    const token = try std.fmt.bufPrint(&token_buf, "zigit{d}", .{token_n});

    const interactive_lit: []const u8 = if (interactive) "true" else "false";
    var opt_buf: [160]u8 = undefined;
    const options = try std.fmt.bufPrint(
        &opt_buf,
        "{{'interactive': <{s}>, 'handle_token': <'{s}'>}}",
        .{ interactive_lit, token },
    );

    // Start monitor BEFORE the call so we cannot miss a fast Response.
    var rule_buf: [96]u8 = undefined;
    // Broad filter; we match handle_token / file:// in the stream.
    const rule = try std.fmt.bufPrint(
        &rule_buf,
        "type='signal',interface='org.freedesktop.portal.Request',member='Response'",
        .{},
    );

    var mon = std.process.spawn(io, .{
        .argv = &.{ "dbus-monitor", "--session", rule },
        .stdin = .ignore,
        .stdout = .pipe,
        .stderr = .ignore,
    }) catch |e| switch (e) {
        error.FileNotFound => return error.PortalMissing,
        else => return e,
    };

    const call = std.process.run(allocator, io, .{
        .argv = &.{
            "gdbus",                                        "call",
            "--session",                                    "--dest",
            "org.freedesktop.portal.Desktop",               "--object-path",
            "/org/freedesktop/portal/desktop",              "--method",
            "org.freedesktop.portal.Screenshot.Screenshot", "",
            options,
        },
        .stdout_limit = .limited(1024),
        .stderr_limit = .limited(4096),
    }) catch |e| {
        mon.kill(io);
        if (mon.stdout) |s| {
            s.close(io);
            mon.stdout = null;
        }
        _ = mon.wait(io) catch {};
        return switch (e) {
            error.FileNotFound => error.PortalMissing,
            else => e,
        };
    };
    defer allocator.free(call.stdout);
    defer allocator.free(call.stderr);

    if (call.term != .exited or call.term.exited != 0) {
        mon.kill(io);
        if (mon.stdout) |s| {
            s.close(io);
            mon.stdout = null;
        }
        _ = mon.wait(io) catch {};
        if (call.stderr.len > 0) {
            std.debug.print("zigit: portal Screenshot call failed: {s}\n", .{std.mem.trim(u8, call.stderr, " \t\r\n")});
        }
        return error.PortalFailed;
    }

    // Optional: extract request path for logging.
    const resp = std.mem.trim(u8, call.stdout, " \t\r\n");
    if (std.mem.indexOf(u8, resp, "'/")) |ps| {
        const rest = resp[ps + 1 ..];
        if (std.mem.indexOfScalar(u8, rest, '\'')) |pe| {
            std.debug.print("zigit: portal request {s}\n", .{rest[0..pe]});
        }
    }

    const uri = waitPortalResponse(io, &mon, allocator) catch |e| {
        mon.kill(io);
        if (mon.stdout) |s| {
            s.close(io);
            mon.stdout = null;
        }
        _ = mon.wait(io) catch {};
        return e;
    };
    defer allocator.free(uri);

    mon.kill(io);
    if (mon.stdout) |s| {
        s.close(io);
        mon.stdout = null;
    }
    _ = mon.wait(io) catch {};

    const local = if (std.mem.startsWith(u8, uri, "file://")) uri["file://".len..] else uri;
    // Percent-decode minimal %20 etc. if present — portal usually gives plain paths.
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, local, allocator, .limited(256 << 20));
    defer allocator.free(bytes);
    try writeFileAbsolute(out_path, bytes);
}

fn waitPortalResponse(io: std.Io, mon: *std.process.Child, allocator: std.mem.Allocator) ![]u8 {
    var acc: std.array_list.Managed(u8) = .init(allocator);
    defer acc.deinit();
    const stdout = mon.stdout orelse return error.PortalFailed;
    var tmp: [2048]u8 = undefined;
    while (true) {
        const n = stdout.readStreaming(io, &.{&tmp}) catch return error.PortalTimeout;
        if (n == 0) return error.PortalTimeout;
        try acc.appendSlice(tmp[0..n]);

        // Success: uri string in results dict.
        if (std.mem.indexOf(u8, acc.items, "file://")) |fi| {
            const rest = acc.items[fi..];
            var end: usize = 0;
            while (end < rest.len) : (end += 1) {
                const ch = rest[end];
                if (ch == '"' or ch == '\'' or ch == '\n' or ch == '\r' or ch == ' ' or ch == ',') break;
            }
            return try allocator.dupe(u8, rest[0..end]);
        }
        // Cancel: response code 1 (common in dbus-monitor dump).
        if (std.mem.indexOf(u8, acc.items, "Response") != null and
            std.mem.indexOf(u8, acc.items, "uint32 1") != null and
            std.mem.indexOf(u8, acc.items, "file://") == null and
            acc.items.len > 100)
        {
            return error.PortalCancelled;
        }
    }
}

fn writeFileAbsolute(path: []const u8, bytes: []const u8) !void {
    const io = app_io.get();
    const f = try std.Io.Dir.createFileAbsolute(io, path, .{ .truncate = true });
    defer f.close(io);
    try f.writeStreamingAll(io, bytes);
}

pub fn spectacle(allocator: std.mem.Allocator, mode: []const u8, out_path: []const u8) !void {
    const io = app_io.get();
    const result = std.process.run(allocator, io, .{
        .argv = &.{ "spectacle", "--background", "--nonotify", mode, "--output", out_path },
        .stdout_limit = .limited(256),
        .stderr_limit = .limited(4096),
    }) catch |e| switch (e) {
        error.FileNotFound => return error.SpectacleMissing,
        else => return e,
    };
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    switch (result.term) {
        .exited => |code| if (code != 0) return error.SpectacleFailed,
        else => return error.SpectacleFailed,
    }
}
