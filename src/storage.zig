const std = @import("std");
const app_io = @import("app_io");

/// Default relative path under $HOME when no save_dir is configured.
pub const default_capture_rel = "screenshots";

fn homeDir() ![]const u8 {
    const z = std.c.getenv("HOME") orelse return error.NoHome;
    return std.mem.span(z);
}

/// Returns the absolute captures directory, creating it if needed.
///
/// - Non-empty `override`: used as the full capture directory (supports a
///   leading `~/`). ZigIt no longer appends an extra subdirectory.
/// - Empty `override`: `$HOME/screenshots`.
///
/// Caller owns the returned slice.
pub fn captureDir(allocator: std.mem.Allocator, override: []const u8) ![]u8 {
    const full = if (override.len > 0)
        try expandHome(allocator, override)
    else blk: {
        const home = try homeDir();
        break :blk try std.fs.path.join(allocator, &.{ home, default_capture_rel });
    };
    errdefer allocator.free(full);

    const io = app_io.get();
    std.Io.Dir.createDirAbsolute(io, full, .default_dir) catch |e| switch (e) {
        error.PathAlreadyExists => {},
        error.FileNotFound => {
            // Parent missing: create the tree.
            try ensureDirTree(full);
        },
        else => return e,
    };
    return full;
}

/// Expands a leading `~/` to $HOME. Other paths are duped as-is.
/// Caller owns the returned slice.
pub fn expandHome(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    if (path.len >= 2 and path[0] == '~' and path[1] == '/') {
        const home = try homeDir();
        return std.fs.path.join(allocator, &.{ home, path[2..] });
    }
    if (std.mem.eql(u8, path, "~")) {
        const home = try homeDir();
        return allocator.dupe(u8, home);
    }
    return allocator.dupe(u8, path);
}

fn ensureDirTree(path: []const u8) !void {
    const io = app_io.get();
    std.Io.Dir.createDirAbsolute(io, path, .default_dir) catch |e| switch (e) {
        error.PathAlreadyExists => return,
        error.FileNotFound => {
            if (std.fs.path.dirname(path)) |parent| {
                if (parent.len > 0 and !std.mem.eql(u8, parent, path)) {
                    try ensureDirTree(parent);
                    try std.Io.Dir.createDirAbsolute(io, path, .default_dir);
                    return;
                }
            }
            return e;
        },
        else => return e,
    };
}

/// Returns a unique timestamped PNG path inside `dir`
/// (<YYYY-MM-DD_HH-MM-SS.png>, appending _1, _2, ... on collision).
/// Caller owns the returned slice.
pub fn newCapturePath(allocator: std.mem.Allocator, dir: []const u8) ![]u8 {
    const io = app_io.get();
    const stamp = blk: {
        const ts = std.Io.Clock.real.now(app_io.get()).toSeconds();
        const epoch_sec = std.time.epoch.EpochSeconds{ .secs = @intCast(ts) };
        const year_day = epoch_sec.getEpochDay().calculateYearDay();
        const month_day = year_day.calculateMonthDay();
        const day_sec = epoch_sec.getDaySeconds();
        break :blk try std.fmt.allocPrint(allocator, "{d:0>4}-{d:0>2}-{d:0>2}_{d:0>2}-{d:0>2}-{d:0>2}", .{
            year_day.year,
            month_day.month.numeric(),
            month_day.day_index + 1,
            day_sec.getHoursIntoDay(),
            day_sec.getMinutesIntoHour(),
            day_sec.getSecondsIntoMinute(),
        });
    };
    defer allocator.free(stamp);
    var attempt: u32 = 0;
    while (attempt < 1000) : (attempt += 1) {
        const name = if (attempt == 0)
            try std.fmt.allocPrint(allocator, "{s}.png", .{stamp})
        else
            try std.fmt.allocPrint(allocator, "{s}_{d}.png", .{ stamp, attempt });
        defer allocator.free(name);
        const candidate = try std.fs.path.join(allocator, &.{ dir, name });
        std.Io.Dir.accessAbsolute(io, candidate, .{}) catch |e| switch (e) {
            error.FileNotFound => return candidate,
            else => return e,
        };
        allocator.free(candidate);
    }
    return error.TooManyCollisions;
}

/// Writes `bytes` to `path`, truncating any existing file.
pub fn writeFileAbsolute(path: []const u8, bytes: []const u8) !void {
    const io = app_io.get();
    const f = try std.Io.Dir.createFileAbsolute(io, path, .{ .truncate = true });
    defer f.close(io);
    try f.writeStreamingAll(io, bytes);
}
