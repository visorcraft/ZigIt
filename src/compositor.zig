const std = @import("std");

pub const Compositor = enum {
    sway,
    hyprland,
    river,
    labwc,
    kde,
    gnome,
    unknown,

    pub fn displayName(self: Compositor) []const u8 {
        return switch (self) {
            .sway => "Sway",
            .hyprland => "Hyprland",
            .river => "River",
            .labwc => "Labwc",
            .kde => "KDE Plasma",
            .gnome => "GNOME",
            .unknown => "Unknown",
        };
    }
};

pub fn detect(env: *std.process.EnvMap) Compositor {
    if (env.get("SWAYSOCK") != null) return .sway;
    if (env.get("HYPRLAND_INSTANCE_SIGNATURE") != null) return .hyprland;

    // River / labwc detection: scan $XDG_RUNTIME_DIR for known compositor sockets.
    if (env.get("XDG_RUNTIME_DIR")) |rtdir| {
        if (detectSocket(rtdir, "river")) return .river;
        if (detectSocket(rtdir, "labwc")) return .labwc;
    }

    if (env.get("XDG_CURRENT_DESKTOP")) |xdg| {
        if (std.mem.indexOf(u8, xdg, "KDE") != null) return .kde;
        if (std.mem.indexOf(u8, xdg, "GNOME") != null) return .gnome;
    }
    if (env.get("LABWC") != null) return .labwc;
    return .unknown;
}

fn detectSocket(rtdir: []const u8, name: []const u8) bool {
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, "{s}/{s}.sock", .{ rtdir, name }) catch return false;
    const f = std.fs.openFileAbsolute(path, .{}) catch return false;
    f.close();
    return true;
}

pub const Reload = enum { swaymsg, hyprctl, kglobalaccel, labwc_reload, none };

pub const Binding = struct {
    snippetPath: []u8,
    reload: Reload,
    snippet: []const u8,
};

pub const ShortcutOwner = struct {
    component: []u8,
    action: []u8,
    name: []u8,

    pub fn deinit(self: ShortcutOwner, allocator: std.mem.Allocator) void {
        allocator.free(self.component);
        allocator.free(self.action);
        allocator.free(self.name);
    }

    pub fn isZigit(self: ShortcutOwner) bool {
        return std.mem.eql(u8, self.component, kde_component);
    }

    pub fn isSpectacle(self: ShortcutOwner) bool {
        return std.mem.eql(u8, self.component, "org.kde.spectacle.desktop");
    }
};

/// The reload command appropriate for each compositor. Only valid for
/// compositors with a supported install path (gnome/unknown are unreachable).
pub fn reloadFor(compositor_enum: Compositor) Reload {
    return switch (compositor_enum) {
        .sway => .swaymsg,
        .hyprland => .hyprctl,
        .kde => .kglobalaccel,
        .labwc => .labwc_reload,
        .river => .none,
        .gnome, .unknown => unreachable,
    };
}

pub fn snippetFor(
    allocator: std.mem.Allocator,
    compositor_enum: Compositor,
    hotkey: []const u8,
    action: []const u8,
) ![]u8 {
    return switch (compositor_enum) {
        .sway => std.fmt.allocPrint(allocator, "# zigit: installed by ZigIt\n" ++
            "bindsym {s} exec {s}\n", .{ hotkey, action }),
        .hyprland => std.fmt.allocPrint(allocator, "# zigit: installed by ZigIt\n" ++
            "bind = , {s}, exec, {s}\n", .{ hotkey, action }),
        .river => std.fmt.allocPrint(allocator, "# zigit: installed by ZigIt\n" ++
            "riverctl map normal {s} spawn {s}\n", .{ hotkey, action }),
        .labwc => std.fmt.allocPrint(allocator, "  <keybind key=\"{s}\">\n" ++
            "    <action name=\"Execute\">sh -c '{s}'</action>\n" ++
            "  </keybind>\n", .{ hotkey, action }),
        .kde => blk: {
            const key = try kdeHotkey(allocator, hotkey);
            defer allocator.free(key);
            break :blk std.fmt.allocPrint(allocator, "[services][" ++ kde_component ++ "]\n_launch={s}\n", .{key});
        },
        // GNOME keybindings live in a binary dconf database; there is no text
        // snippet we can safely write, so installation is unsupported.
        .gnome => return error.UnsupportedCompositor,
        .unknown => return error.UnsupportedCompositor,
    };
}

pub fn snippetPathFor(
    allocator: std.mem.Allocator,
    compositor_enum: Compositor,
    home: []const u8,
) ![]u8 {
    return switch (compositor_enum) {
        .sway => std.fs.path.join(allocator, &.{ home, ".config/sway/config.d/zigit.conf" }),
        .hyprland => std.fs.path.join(allocator, &.{ home, ".config/hypr/zigit.conf" }),
        .river => std.fs.path.join(allocator, &.{ home, ".config/river/init.d/zigit.sh" }),
        .labwc => std.fs.path.join(allocator, &.{ home, ".config/labwc/rc.xml" }),
        .kde => std.fs.path.join(allocator, &.{ home, ".config/kglobalshortcutsrc" }),
        .gnome => std.fs.path.join(allocator, &.{ home, ".local/share/dconf/user" }),
        .unknown => return error.UnsupportedCompositor,
    };
}

// Pre-existing compositor configs can be large (e.g. a long rc.xml or
// kglobalshortcutsrc); read them with a generous cap instead of failing.
const max_config_bytes = 1 << 22; // 4 MiB

const labwc_begin = "<!-- BEGIN ZIGIT -->\n";
const labwc_end = "<!-- END ZIGIT -->\n";
const kde_component = "com.visorcraft.zigit.desktop";
const kde_header = "[services][" ++ kde_component ++ "]";
const kde_legacy_header = "[zigit]";
const kde_config_suffix = "/.config/kglobalshortcutsrc";

const Range = struct { start: usize, end: usize };

// Range of the zigit-owned marker block inside labwc's rc.xml.
fn labwcBlockRange(content: []const u8) ?Range {
    const start = std.mem.indexOf(u8, content, labwc_begin) orelse return null;
    const end = if (std.mem.indexOfPos(u8, content, start + labwc_begin.len, labwc_end)) |i|
        i + labwc_end.len
    else
        content.len;
    return .{ .start = start, .end = end };
}

// Range of a KConfig section, from its header to the next section or EOF.
fn kdeSectionRange(content: []const u8, header: []const u8) ?Range {
    var idx: usize = 0;
    while (std.mem.indexOfPos(u8, content, idx, header)) |i| {
        if (i == 0 or content[i - 1] == '\n') {
            var end = content.len;
            if (std.mem.indexOfPos(u8, content, i + header.len, "\n[")) |j| {
                end = j + 1;
            }
            return .{ .start = i, .end = end };
        }
        idx = i + header.len;
    }
    return null;
}

fn kdeHotkey(allocator: std.mem.Allocator, hotkey: []const u8) ![]u8 {
    if (std.mem.startsWith(u8, hotkey, "Super+")) {
        return std.fmt.allocPrint(allocator, "Meta+{s}", .{hotkey["Super+".len..]});
    }
    return allocator.dupe(u8, hotkey);
}

fn readExisting(allocator: std.mem.Allocator, path: []const u8, out: *std.ArrayList(u8)) !void {
    if (std.fs.openFileAbsolute(path, .{})) |f| {
        defer f.close();
        const buf = try f.readToEndAlloc(allocator, max_config_bytes);
        defer allocator.free(buf);
        try out.appendSlice(buf);
    } else |e| switch (e) {
        error.FileNotFound => {},
        else => return e,
    }
}

fn writeFileAbsolute(path: []const u8, content: []const u8) !void {
    const f = try std.fs.createFileAbsolute(path, .{ .truncate = true });
    defer f.close();
    try f.writeAll(content);
}

fn kdeEntryRange(content: []const u8, section: Range, key: []const u8) ?Range {
    const header_end = std.mem.indexOfPos(u8, content, section.start, "\n") orelse return null;
    var line_start = header_end + 1;
    while (line_start < section.end) {
        const line_end = std.mem.indexOfPos(u8, content, line_start, "\n") orelse section.end;
        const line = content[line_start..line_end];
        if (line.len > key.len and line[key.len] == '=' and std.mem.eql(u8, line[0..key.len], key)) {
            return .{ .start = line_start, .end = @min(line_end + 1, content.len) };
        }
        line_start = @min(line_end + 1, content.len);
    }
    return null;
}

fn kdeEntryValue(content: []const u8, header: []const u8, key: []const u8) ?[]const u8 {
    const section = kdeSectionRange(content, header) orelse return null;
    const entry = kdeEntryRange(content, section, key) orelse return null;
    const end = if (entry.end > entry.start and content[entry.end - 1] == '\n') entry.end - 1 else entry.end;
    return content[entry.start + key.len + 1 .. end];
}

fn setKdeEntry(content: *std.ArrayList(u8), header: []const u8, key: []const u8, value: []const u8) !void {
    const line = try std.fmt.allocPrint(content.allocator, "{s}={s}\n", .{ key, value });
    defer content.allocator.free(line);
    if (kdeSectionRange(content.items, header)) |section| {
        if (kdeEntryRange(content.items, section, key)) |entry| {
            try content.replaceRange(entry.start, entry.end - entry.start, line);
        } else {
            if (section.end > 0 and content.items[section.end - 1] != '\n') {
                const prefixed = try std.fmt.allocPrint(content.allocator, "\n{s}", .{line});
                defer content.allocator.free(prefixed);
                try content.replaceRange(section.end, 0, prefixed);
            } else {
                try content.replaceRange(section.end, 0, line);
            }
        }
        return;
    }
    if (content.items.len > 0 and content.items[content.items.len - 1] != '\n') try content.append('\n');
    try content.writer().print("{s}\n{s}", .{ header, line });
}

fn removeKdeEntry(content: *std.ArrayList(u8), header: []const u8, key: []const u8) !void {
    const section = kdeSectionRange(content.items, header) orelse return;
    const entry = kdeEntryRange(content.items, section, key) orelse return;
    try content.replaceRange(entry.start, entry.end - entry.start, "");
}

fn kdeSectionEmpty(content: []const u8, header: []const u8) bool {
    const section = kdeSectionRange(content, header) orelse return false;
    const header_end = std.mem.indexOfPos(u8, content, section.start, "\n") orelse return true;
    return std.mem.trim(u8, content[header_end + 1 .. section.end], " \t\r\n").len == 0;
}

fn kdeHomeFromConfigPath(path: []const u8) ?[]const u8 {
    if (!std.mem.endsWith(u8, path, kde_config_suffix)) return null;
    return path[0 .. path.len - kde_config_suffix.len];
}

fn kdeLauncherPath(allocator: std.mem.Allocator, home: []const u8) ![]u8 {
    return std.fs.path.join(allocator, &.{ home, ".local/share/applications/" ++ kde_component });
}

fn kdeBackupPath(allocator: std.mem.Allocator, home: []const u8) ![]u8 {
    return std.fs.path.join(allocator, &.{ home, ".config/zigit/kde-shortcut-backup" });
}

fn writeKdeLauncher(
    allocator: std.mem.Allocator,
    home: []const u8,
    hotkey: []const u8,
    action: []const u8,
) !void {
    const path = try kdeLauncherPath(allocator, home);
    defer allocator.free(path);
    if (std.fs.path.dirname(path)) |dir| try std.fs.cwd().makePath(dir);
    const key = try kdeHotkey(allocator, hotkey);
    defer allocator.free(key);
    const desktop = try std.fmt.allocPrint(allocator, "[Desktop Entry]\n" ++
        "Type=Application\n" ++
        "Name=ZigIt Capture\n" ++
        "Comment=Capture a screenshot with ZigIt\n" ++
        "Exec={s}\n" ++
        "Icon=camera-photo\n" ++
        "NoDisplay=true\n" ++
        "X-KDE-Shortcuts={s}\n", .{ action, key });
    defer allocator.free(desktop);
    try writeFileAbsolute(path, desktop);
}

fn backupField(content: []const u8, key: []const u8) ?[]const u8 {
    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |line| {
        if (line.len > key.len and line[key.len] == '=' and std.mem.eql(u8, line[0..key.len], key)) {
            return line[key.len + 1 ..];
        }
    }
    return null;
}

fn backupKdeShortcut(
    allocator: std.mem.Allocator,
    home: []const u8,
    content: []const u8,
    owner: ShortcutOwner,
) !void {
    const path = try kdeBackupPath(allocator, home);
    defer allocator.free(path);
    if (std.fs.accessAbsolute(path, .{})) |_| return else |e| switch (e) {
        error.FileNotFound => {},
        else => return e,
    }
    if (std.fs.path.dirname(path)) |dir| try std.fs.cwd().makePath(dir);
    const header = try std.fmt.allocPrint(allocator, "[services][{s}]", .{owner.component});
    defer allocator.free(header);
    var backup = std.ArrayList(u8).init(allocator);
    defer backup.deinit();
    try backup.writer().print("component={s}\naction={s}\nsection={s}\n", .{
        owner.component,
        owner.action,
        if (kdeSectionRange(content, header) != null) "true" else "false",
    });
    if (kdeEntryValue(content, header, owner.action)) |value| {
        try backup.writer().print("value={s}\n", .{value});
    }
    try writeFileAbsolute(path, backup.items);
}

fn restoreKdeShortcut(
    allocator: std.mem.Allocator,
    home: []const u8,
    content: *std.ArrayList(u8),
) !?[]u8 {
    const path = try kdeBackupPath(allocator, home);
    errdefer allocator.free(path);
    const backup = std.fs.cwd().readFileAlloc(allocator, path, 4096) catch |e| switch (e) {
        error.FileNotFound => {
            allocator.free(path);
            return null;
        },
        else => return e,
    };
    defer allocator.free(backup);
    const component = backupField(backup, "component") orelse return error.InvalidKdeShortcutBackup;
    const action = backupField(backup, "action") orelse return error.InvalidKdeShortcutBackup;
    const header = try std.fmt.allocPrint(allocator, "[services][{s}]", .{component});
    defer allocator.free(header);
    if (kdeEntryValue(content.items, header, action)) |current| {
        if (std.mem.eql(u8, current, "none")) {
            if (backupField(backup, "value")) |value| {
                try setKdeEntry(content, header, action, value);
            } else {
                try removeKdeEntry(content, header, action);
                if (std.mem.eql(u8, backupField(backup, "section") orelse "true", "false") and
                    kdeSectionEmpty(content.items, header))
                {
                    const section = kdeSectionRange(content.items, header).?;
                    try content.replaceRange(section.start, section.end - section.start, "");
                }
            }
        }
    }
    return path;
}

pub fn overrideKdeShortcut(
    allocator: std.mem.Allocator,
    home: []const u8,
    owner: ShortcutOwner,
) !void {
    if (!owner.isSpectacle()) return error.HotkeyConflict;
    const path = try snippetPathFor(allocator, .kde, home);
    defer allocator.free(path);
    var content = std.ArrayList(u8).init(allocator);
    defer content.deinit();
    try readExisting(allocator, path, &content);
    try backupKdeShortcut(allocator, home, content.items, owner);
    const header = try std.fmt.allocPrint(allocator, "[services][{s}]", .{owner.component});
    defer allocator.free(header);
    try setKdeEntry(&content, header, owner.action, "none");
    try writeFileAbsolute(path, content.items);
}

pub fn install(
    allocator: std.mem.Allocator,
    compositor_enum: Compositor,
    home: []const u8,
    hotkey: []const u8,
    action: []const u8,
) !Binding {
    // GNOME keybindings live in a binary dconf database; appending text to it
    // would corrupt the database, so installing there is unsupported.
    if (compositor_enum == .gnome) return error.UnsupportedCompositor;

    const snippet = try snippetFor(allocator, compositor_enum, hotkey, action);
    errdefer allocator.free(snippet);

    const path = try snippetPathFor(allocator, compositor_enum, home);
    errdefer allocator.free(path);

    if (std.fs.path.dirname(path)) |dir| {
        try std.fs.cwd().makePath(dir);
    }

    const reload_kind = reloadFor(compositor_enum);

    var content = std.ArrayList(u8).init(allocator);
    defer content.deinit();
    var restored_kde_backup: ?[]u8 = null;
    defer if (restored_kde_backup) |backup| allocator.free(backup);

    switch (compositor_enum) {
        .sway, .hyprland, .river => {
            // Dedicated zigit-owned file: write the snippet fresh (truncate) so
            // repeated installs stay idempotent.
            try content.appendSlice(snippet);
        },
        .labwc => {
            // rc.xml belongs to the user: replace our previous marker block if
            // present, otherwise append a new one.
            try readExisting(allocator, path, &content);
            const block = try std.fmt.allocPrint(allocator, labwc_begin ++ "{s}" ++ labwc_end, .{snippet});
            defer allocator.free(block);
            if (labwcBlockRange(content.items)) |r| {
                try content.replaceRange(r.start, r.end - r.start, block);
            } else {
                try content.appendSlice(block);
            }
        },
        .kde => {
            // KDE discovers launch shortcuts from desktop files and stores
            // user overrides under [services][desktop-file-id].
            try readExisting(allocator, path, &content);
            const key = try kdeHotkey(allocator, hotkey);
            defer allocator.free(key);
            const previous_key = kdeEntryValue(content.items, kde_header, "_launch");
            if (previous_key == null or !std.mem.eql(u8, previous_key.?, key)) {
                restored_kde_backup = try restoreKdeShortcut(allocator, home, &content);
            }
            if (kdeSectionRange(content.items, kde_header)) |r| {
                try content.replaceRange(r.start, r.end - r.start, "");
            }
            if (kdeSectionRange(content.items, kde_legacy_header)) |r| {
                try content.replaceRange(r.start, r.end - r.start, "");
            }
            if (content.items.len > 0 and content.items[content.items.len - 1] != '\n') {
                try content.append('\n');
            }
            try content.appendSlice(snippet);
            try writeKdeLauncher(allocator, home, hotkey, action);
        },
        .gnome, .unknown => unreachable,
    }

    try writeFileAbsolute(path, content.items);
    if (restored_kde_backup) |backup| std.fs.deleteFileAbsolute(backup) catch {};

    return .{ .snippetPath = path, .reload = reload_kind, .snippet = snippet };
}

pub fn uninstall(
    allocator: std.mem.Allocator,
    compositor_enum: Compositor,
    binding: Binding,
) !void {
    switch (compositor_enum) {
        .sway, .hyprland, .river => {
            // Dedicated zigit-owned file: delete it outright.
            std.fs.deleteFileAbsolute(binding.snippetPath) catch |e| switch (e) {
                error.FileNotFound => {},
                else => return e,
            };
        },
        .labwc, .kde => {
            // Shared user config: remove only the zigit-owned content and
            // rewrite the rest of the file untouched.
            var content = std.ArrayList(u8).init(allocator);
            defer content.deinit();
            try readExisting(allocator, binding.snippetPath, &content);
            if (compositor_enum == .labwc) {
                const r = labwcBlockRange(content.items) orelse return;
                try content.replaceRange(r.start, r.end - r.start, "");
            } else {
                const home = kdeHomeFromConfigPath(binding.snippetPath) orelse return error.InvalidKdeConfigPath;
                const backup_path = try restoreKdeShortcut(allocator, home, &content);
                defer if (backup_path) |p| allocator.free(p);
                if (kdeSectionRange(content.items, kde_header)) |r| {
                    try content.replaceRange(r.start, r.end - r.start, "");
                }
                if (kdeSectionRange(content.items, kde_legacy_header)) |r| {
                    try content.replaceRange(r.start, r.end - r.start, "");
                }
                const launcher_path = try kdeLauncherPath(allocator, home);
                defer allocator.free(launcher_path);
                std.fs.deleteFileAbsolute(launcher_path) catch |e| switch (e) {
                    error.FileNotFound => {},
                    else => return e,
                };
                try writeFileAbsolute(binding.snippetPath, content.items);
                if (backup_path) |p| std.fs.deleteFileAbsolute(p) catch {};
                return;
            }
            try writeFileAbsolute(binding.snippetPath, content.items);
        },
        // See install(): we never write to the binary dconf database.
        .gnome => return error.UnsupportedCompositor,
        .unknown => return error.UnsupportedCompositor,
    }
}

pub fn qtKeyForHotkey(hotkey: []const u8) ?i32 {
    var code: u32 = 0;
    var key: ?u32 = null;
    var parts = std.mem.splitScalar(u8, hotkey, '+');
    while (parts.next()) |part| {
        if (std.mem.eql(u8, part, "Super") or std.mem.eql(u8, part, "Meta")) {
            code |= 0x10000000;
        } else if (std.mem.eql(u8, part, "Ctrl")) {
            code |= 0x04000000;
        } else if (std.mem.eql(u8, part, "Alt")) {
            code |= 0x08000000;
        } else if (std.mem.eql(u8, part, "Shift")) {
            code |= 0x02000000;
        } else {
            if (key != null) return null;
            key = qtBaseKey(part) orelse return null;
        }
    }
    code |= key orelse return null;
    return @intCast(code);
}

fn qtBaseKey(name: []const u8) ?u32 {
    if (name.len == 1 and std.ascii.isAlphanumeric(name[0])) return std.ascii.toUpper(name[0]);
    if (name.len >= 2 and name[0] == 'F') {
        const n = std.fmt.parseInt(u8, name[1..], 10) catch 0;
        if (n >= 1 and n <= 12) return 0x01000030 + @as(u32, n) - 1;
    }
    const names = [_]struct { name: []const u8, key: u32 }{
        .{ .name = "Print", .key = 0x01000009 },
        .{ .name = "Scroll_Lock", .key = 0x01000026 },
        .{ .name = "Pause", .key = 0x01000008 },
        .{ .name = "Insert", .key = 0x01000006 },
        .{ .name = "Delete", .key = 0x01000007 },
        .{ .name = "Home", .key = 0x01000010 },
        .{ .name = "End", .key = 0x01000011 },
        .{ .name = "Page_Up", .key = 0x01000016 },
        .{ .name = "Page_Down", .key = 0x01000017 },
        .{ .name = "Up", .key = 0x01000013 },
        .{ .name = "Down", .key = 0x01000015 },
        .{ .name = "Left", .key = 0x01000012 },
        .{ .name = "Right", .key = 0x01000014 },
        .{ .name = "Tab", .key = 0x01000001 },
        .{ .name = "Space", .key = 0x20 },
        .{ .name = "Return", .key = 0x01000004 },
    };
    for (names) |entry| if (std.mem.eql(u8, name, entry.name)) return entry.key;
    return null;
}

pub fn kdeShortcutOwner(allocator: std.mem.Allocator, hotkey: []const u8) !?ShortcutOwner {
    const key = qtKeyForHotkey(hotkey) orelse return null;
    const key_arg = try std.fmt.allocPrint(allocator, "{d}", .{key});
    defer allocator.free(key_arg);
    var child = std.process.Child.init(&.{
        "qdbus6",
        "org.kde.kglobalaccel",
        "/kglobalaccel",
        "org.kde.KGlobalAccel.action",
        key_arg,
    }, allocator);
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Ignore;
    child.spawn() catch return null;
    const output = child.stdout.?.readToEndAlloc(allocator, 4096) catch {
        _ = child.wait() catch {};
        return null;
    };
    defer allocator.free(output);
    const term = child.wait() catch return null;
    switch (term) {
        .Exited => |status| if (status != 0) return null,
        else => return null,
    }
    var lines = std.mem.splitScalar(u8, std.mem.trim(u8, output, " \t\r\n"), '\n');
    const component = std.mem.trim(u8, lines.next() orelse return null, "\r");
    const action = std.mem.trim(u8, lines.next() orelse return null, "\r");
    const name = std.mem.trim(u8, lines.next() orelse return null, "\r");
    if (component.len == 0 or action.len == 0) return null;
    const owned_component = try allocator.dupe(u8, component);
    errdefer allocator.free(owned_component);
    const owned_action = try allocator.dupe(u8, action);
    errdefer allocator.free(owned_action);
    const owned_name = try allocator.dupe(u8, if (name.len > 0) name else component);
    return .{ .component = owned_component, .action = owned_action, .name = owned_name };
}

pub fn setKdeShortcutsBlocked(allocator: std.mem.Allocator, blocked: bool) !void {
    var env = try std.process.getEnvMap(allocator);
    defer env.deinit();
    try runCommand(allocator, &env, &.{
        "qdbus6",
        "org.kde.kglobalaccel",
        "/kglobalaccel",
        "org.kde.KGlobalAccel.blockGlobalShortcuts",
        if (blocked) "true" else "false",
    });
}

pub fn reload(allocator: std.mem.Allocator, kind: Reload) !void {
    var env = try std.process.getEnvMap(allocator);
    defer env.deinit();
    try reloadWithEnv(allocator, kind, &env);
}

pub fn reloadWithEnv(
    allocator: std.mem.Allocator,
    kind: Reload,
    env: *std.process.EnvMap,
) !void {
    switch (kind) {
        .none => return,
        .swaymsg => try runCommand(allocator, env, &.{ "swaymsg", "reload" }),
        .hyprctl => try runCommand(allocator, env, &.{ "hyprctl", "reload" }),
        .kglobalaccel => {
            try runCommand(allocator, env, &.{"kbuildsycoca6"});
            try runCommand(allocator, env, &.{ "systemctl", "--user", "restart", "plasma-kglobalaccel.service" });
        },
        .labwc_reload => try runCommand(allocator, env, &.{ "labwc", "-r" }),
    }
}

fn runCommand(
    allocator: std.mem.Allocator,
    env: *std.process.EnvMap,
    argv: []const []const u8,
) !void {
    // Resolve argv[0] against the PATH of the injected env_map: std.process.Child
    // searches the parent process's PATH, not env_map's, so the injected PATH
    // would otherwise be ignored.
    var resolved_argv = try std.ArrayList([]const u8).initCapacity(allocator, argv.len);
    defer resolved_argv.deinit();
    try resolved_argv.appendSlice(argv);
    if (std.mem.indexOfScalar(u8, argv[0], '/') == null) {
        if (try resolveOnPath(allocator, env, argv[0])) |full| {
            defer allocator.free(full);
            resolved_argv.items[0] = full;
            try spawnAndCheck(allocator, env, resolved_argv.items);
            return;
        }
    }
    try spawnAndCheck(allocator, env, resolved_argv.items);
}

fn resolveOnPath(
    allocator: std.mem.Allocator,
    env: *std.process.EnvMap,
    name: []const u8,
) !?[]u8 {
    const path_env = env.get("PATH") orelse return null;
    var it = std.mem.tokenizeScalar(u8, path_env, ':');
    while (it.next()) |dir| {
        const candidate = try std.fs.path.join(allocator, &.{ dir, name });
        if (std.fs.accessAbsolute(candidate, .{})) |_| {
            return candidate;
        } else |_| {
            allocator.free(candidate);
        }
    }
    return null;
}

fn spawnAndCheck(
    allocator: std.mem.Allocator,
    env: *std.process.EnvMap,
    argv: []const []const u8,
) !void {
    var child = std.process.Child.init(argv, allocator);
    child.env_map = env;
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Ignore;
    child.stderr_behavior = .Pipe;
    const term = try child.spawnAndWait();
    switch (term) {
        .Exited => |code| if (code != 0) return error.ReloadFailed,
        else => return error.ReloadFailed,
    }
}
