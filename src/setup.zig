const std = @import("std");
const app_io = @import("app_io");
const app_icon = @import("app_icon");
const compositor = @import("compositor");
const config = @import("config");

pub fn run(allocator: std.mem.Allocator, argv: []const []const u8) !void {
    // Desktop icons for Wayland titlebar/taskbar (app_id → icon theme).
    app_icon.installUserChrome(allocator);

    var dry_run = false;
    var uninstall = false;
    var explicit: ?compositor.Compositor = null;
    var i: usize = 0;
    while (i < argv.len) : (i += 1) {
        if (std.mem.eql(u8, argv[i], "--dry-run")) dry_run = true;
        if (std.mem.eql(u8, argv[i], "--uninstall")) uninstall = true;
        if (std.mem.startsWith(u8, argv[i], "--compositor=")) {
            const v = argv[i][std.mem.indexOf(u8, argv[i], "=").? + 1 ..];
            inline for (@typeInfo(compositor.Compositor).@"enum".field_names) |f| {
                if (std.mem.eql(u8, v, f)) {
                    explicit = @field(compositor.Compositor, f);
                }
            }
        }
    }

    var env = try app_io.processEnvMap(allocator);
    defer env.deinit();
    const detected = compositor.detect(&env);
    const kind = explicit orelse detected;

    const home = (if (std.c.getenv("HOME")) |z| std.mem.span(z) else null) orelse return error.NoHome;

    if (uninstall) {
        const path = try compositor.snippetPathFor(allocator, kind, home);
        defer allocator.free(path);
        if (dry_run) {
            std.debug.print("--- would remove ZigIt binding from {s} ---\n", .{path});
            return;
        }
        // snippet is unused by uninstall; reload is recomputed afterwards.
        const binding = compositor.Binding{ .snippetPath = path, .reload = .none, .snippet = &.{} };
        try compositor.uninstall(allocator, kind, binding);
        compositor.reload(allocator, compositor.reloadFor(kind)) catch |e| {
            std.debug.print("ZigIt: removed binding for {s}, but reload failed ({s}); reload your compositor manually\n", .{ kind.displayName(), @errorName(e) });
            return;
        };
        std.debug.print("ZigIt: removed binding for {s}\n", .{kind.displayName()});
        return;
    }

    const cfg_path = config.Config.configPath(allocator) catch "/dev/null";
    defer if (!std.mem.eql(u8, cfg_path, "/dev/null")) allocator.free(cfg_path);
    const cfg = try config.Config.load(allocator, cfg_path);
    defer cfg.deinit(allocator);
    // Absolute system path when available (KDE hotkeys don't honor user PATH).
    const exe = try config.launcherExe(allocator);
    defer allocator.free(exe);
    const action = try config.formatCaptureAction(allocator, exe, cfg.capture_mode);
    defer allocator.free(action);
    const maybe_owner = if (kind == .kde)
        try compositor.kdeShortcutOwner(allocator, cfg.hotkey)
    else
        null;
    defer if (maybe_owner) |owner| owner.deinit(allocator);

    if (dry_run) {
        // Build the snippet in memory only; do not touch disk, do not reload.
        const snippet = try compositor.snippetFor(allocator, kind, cfg.hotkey, action);
        defer allocator.free(snippet);
        const path = try compositor.snippetPathFor(allocator, kind, home);
        defer allocator.free(path);
        std.debug.print("--- {s} ---\n{s}\n", .{ path, snippet });
        if (maybe_owner) |owner| {
            if (!owner.isZigit()) std.debug.print("ZigIt: {s} currently owns {s}\n", .{ owner.name, cfg.hotkey });
        }
        return;
    }

    if (maybe_owner) |owner| {
        if (!owner.isZigit() and !owner.isSpectacle()) {
            std.debug.print("ZigIt: {s} already owns {s}; choose another hotkey\n", .{ owner.name, cfg.hotkey });
            return error.HotkeyConflict;
        }
    }

    const binding = try compositor.install(allocator, kind, home, cfg.hotkey, action);
    defer allocator.free(binding.snippetPath);
    defer allocator.free(binding.snippet);
    if (maybe_owner) |owner| {
        if (owner.isSpectacle()) {
            try compositor.overrideKdeShortcut(allocator, home, owner);
            std.debug.print("ZigIt: replaced {s}'s {s} shortcut\n", .{ owner.name, cfg.hotkey });
        }
    }

    // The binding is on disk at this point; a failed reload (compositor not
    // running, reload tool missing) is a warning, not a setup failure.
    compositor.reload(allocator, binding.reload) catch |e| {
        std.debug.print("ZigIt: installed binding for {s}, but reload failed ({s}); reload your compositor manually\n", .{ kind.displayName(), @errorName(e) });
        return;
    };
    std.debug.print("ZigIt: installed binding for {s}\n", .{kind.displayName()});
}
