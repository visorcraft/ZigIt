const std = @import("std");

pub const Theme = enum { dark, light };
pub const MarqueePosition = enum { top_right, top_left, bottom_right, bottom_left };

pub const Config = struct {
    save_dir: []const u8,
    hotkey: []const u8,
    marquee_position: MarqueePosition,
    theme: Theme,
    default_color_rgba: [4]u8,
    default_font_size: u32,

    /// Returns the built-in defaults. The returned strings are non-owned
    /// string literals; do NOT pass a defaults() Config to deinit.
    pub fn defaults() Config {
        return .{
            .save_dir = "", // empty → storage.captureDir resolves to ~/screenshots
            .hotkey = "Print",
            .marquee_position = .top_right,
            .theme = .dark,
            .default_color_rgba = .{ 0xff, 0x3b, 0x30, 0xff },
            .default_font_size = 18,
        };
    }

    /// Frees the allocator-owned strings of a Config returned by load().
    /// Only valid on configs from load(); defaults() returns non-owned
    /// literals.
    pub fn deinit(self: Config, allocator: std.mem.Allocator) void {
        allocator.free(self.hotkey);
        if (self.save_dir.len > 0) allocator.free(self.save_dir);
    }

    /// Absolute path to ~/.config/zigit/config.toml (or $XDG_CONFIG_HOME).
    /// Caller owns the returned slice.
    pub fn configPath(allocator: std.mem.Allocator) ![]u8 {
        if (std.posix.getenv("XDG_CONFIG_HOME")) |xdg| {
            return std.fs.path.join(allocator, &.{ xdg, "zigit", "config.toml" });
        }
        const home = std.posix.getenv("HOME") orelse return error.NoHome;
        return std.fs.path.join(allocator, &.{ home, ".config", "zigit", "config.toml" });
    }

    /// Loads config from `path`, falling back to defaults for missing keys.
    /// Every string in the returned Config is allocator-owned (defaults are
    /// duped too); free it with deinit.
    pub fn load(allocator: std.mem.Allocator, path: []const u8) !Config {
        var c = defaults();
        // Dupe the default hotkey so the returned Config is uniformly owned.
        c.hotkey = try allocator.dupe(u8, c.hotkey);
        errdefer allocator.free(c.hotkey);
        errdefer if (c.save_dir.len > 0) allocator.free(c.save_dir);
        const file = std.fs.openFileAbsolute(path, .{}) catch return c;
        defer file.close();
        const content = try file.readToEndAlloc(allocator, 1 << 16);
        defer allocator.free(content);
        // Minimal TOML: parse one key = "value" (or bare number) per line.
        var lines = std.mem.splitScalar(u8, content, '\n');
        while (lines.next()) |line| {
            const trimmed = std.mem.trim(u8, line, " \t\r");
            if (trimmed.len == 0 or trimmed[0] == '#' or trimmed[0] == '[') continue;
            if (std.mem.indexOfScalar(u8, trimmed, '=')) |eq| {
                const key = std.mem.trim(u8, trimmed[0..eq], " \t");
                var value = std.mem.trim(u8, trimmed[eq + 1 ..], " \t");
                if (value.len >= 2 and value[0] == '"' and value[value.len - 1] == '"') {
                    value = value[1 .. value.len - 1];
                }
                if (std.mem.eql(u8, key, "hotkey")) {
                    allocator.free(c.hotkey);
                    c.hotkey = try allocator.dupe(u8, value);
                } else if (std.mem.eql(u8, key, "save_dir")) {
                    if (c.save_dir.len > 0) allocator.free(c.save_dir);
                    c.save_dir = if (value.len > 0) try allocator.dupe(u8, value) else "";
                } else if (std.mem.eql(u8, key, "marquee_position")) {
                    c.marquee_position = parseMarqueePosition(value) orelse c.marquee_position;
                } else if (std.mem.eql(u8, key, "theme")) {
                    c.theme = parseTheme(value) orelse c.theme;
                } else if (std.mem.eql(u8, key, "default_color") or std.mem.eql(u8, key, "default_color_rgba")) {
                    if (parseHexColor(value)) |rgba| c.default_color_rgba = rgba;
                } else if (std.mem.eql(u8, key, "font_size") or std.mem.eql(u8, key, "default_font_size")) {
                    c.default_font_size = std.fmt.parseInt(u32, value, 10) catch c.default_font_size;
                }
            }
        }
        return c;
    }

    /// Writes config atomically to `path`, creating parent directories as needed.
    pub fn save(self: Config, path: []const u8) !void {
        const dir = std.fs.path.dirname(path) orelse return error.BadPath;
        try ensureDirAbsolute(dir);

        var buf: [2048]u8 = undefined;
        var fbs = std.io.fixedBufferStream(&buf);
        const w = fbs.writer();
        try w.writeAll("# ZigIt preferences — edit here or via the Settings tab in the daemon.\n");
        try w.print("save_dir = \"{s}\"\n", .{self.save_dir});
        try w.print("hotkey = \"{s}\"\n", .{self.hotkey});
        try w.print("marquee_position = \"{s}\"\n", .{marqueePositionName(self.marquee_position)});
        try w.print("theme = \"{s}\"\n", .{themeName(self.theme)});
        try w.print("default_color = \"#{x:0>2}{x:0>2}{x:0>2}\"\n", .{
            self.default_color_rgba[0],
            self.default_color_rgba[1],
            self.default_color_rgba[2],
        });
        try w.print("font_size = {d}\n", .{self.default_font_size});
        const content = fbs.getWritten();

        var tmp_buf: [std.fs.max_path_bytes]u8 = undefined;
        const tmp = try std.fmt.bufPrint(&tmp_buf, "{s}.tmp", .{path});
        {
            const f = try std.fs.createFileAbsolute(tmp, .{ .truncate = true });
            defer f.close();
            try f.writeAll(content);
        }
        try std.fs.renameAbsolute(tmp, path);
    }
};

pub fn themeName(t: Theme) []const u8 {
    return switch (t) {
        .dark => "dark",
        .light => "light",
    };
}

pub fn marqueePositionName(p: MarqueePosition) []const u8 {
    return switch (p) {
        .top_right => "top-right",
        .top_left => "top-left",
        .bottom_right => "bottom-right",
        .bottom_left => "bottom-left",
    };
}

fn parseTheme(s: []const u8) ?Theme {
    if (std.mem.eql(u8, s, "dark")) return .dark;
    if (std.mem.eql(u8, s, "light")) return .light;
    return null;
}

fn parseMarqueePosition(s: []const u8) ?MarqueePosition {
    if (std.mem.eql(u8, s, "top-right") or std.mem.eql(u8, s, "top_right")) return .top_right;
    if (std.mem.eql(u8, s, "top-left") or std.mem.eql(u8, s, "top_left")) return .top_left;
    if (std.mem.eql(u8, s, "bottom-right") or std.mem.eql(u8, s, "bottom_right")) return .bottom_right;
    if (std.mem.eql(u8, s, "bottom-left") or std.mem.eql(u8, s, "bottom_left")) return .bottom_left;
    return null;
}

/// Parses "#rrggbb" or "#rrggbbaa" (optional leading #). Returns null on failure.
pub fn parseHexColor(s: []const u8) ?[4]u8 {
    var hex = s;
    if (hex.len > 0 and hex[0] == '#') hex = hex[1..];
    if (hex.len != 6 and hex.len != 8) return null;
    const r = std.fmt.parseInt(u8, hex[0..2], 16) catch return null;
    const g = std.fmt.parseInt(u8, hex[2..4], 16) catch return null;
    const b = std.fmt.parseInt(u8, hex[4..6], 16) catch return null;
    const a: u8 = if (hex.len == 8)
        (std.fmt.parseInt(u8, hex[6..8], 16) catch return null)
    else
        0xff;
    return .{ r, g, b, a };
}

/// Creates `path` and any missing parents (absolute paths only).
fn ensureDirAbsolute(path: []const u8) !void {
    std.fs.makeDirAbsolute(path) catch |e| switch (e) {
        error.PathAlreadyExists => return,
        error.FileNotFound => {
            if (std.fs.path.dirname(path)) |parent| {
                if (parent.len > 0 and !std.mem.eql(u8, parent, path)) {
                    try ensureDirAbsolute(parent);
                    try std.fs.makeDirAbsolute(path);
                    return;
                }
            }
            return e;
        },
        else => return e,
    };
}
