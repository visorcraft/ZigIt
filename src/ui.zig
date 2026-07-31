const std = @import("std");
const c = @cImport({
    @cInclude("GLFW/glfw3.h");
    @cInclude("GLES2/gl2.h");
    // Without this define cimgui.h falls back to C++ template typedefs
    // (ImPool<T>, ImVector<T>, ...) that translate-c cannot parse.
    @cDefine("CIMGUI_DEFINE_ENUMS_AND_STRUCTS", "1");
    @cInclude("cimgui.h");
    @cInclude("cimgui_backends.h");
});
const marquee_mod = @import("marquee");
const storage = @import("storage");
const toast_mod = @import("toast");
const compositor = @import("compositor");
const config_mod = @import("config");
const theme_mod = @import("theme");

/// Editable form buffers for the Settings tab. Mirrors Config fields.
const SettingsForm = struct {
    hotkey: [64]u8 = undefined,
    hotkey_len: usize = 0,
    save_dir: [512]u8 = undefined,
    save_dir_len: usize = 0,
    marquee_idx: c_int = 0,
    theme_idx: c_int = 0,
    color: [4]f32 = .{ 1.0, 0.23, 0.19, 1.0 },
    font_size: c_int = 18,
    dirty: bool = false,
    /// True while the hotkey field is listening for a chord.
    recording_hotkey: bool = false,
    status_msg: [128]u8 = undefined,
    status_len: usize = 0,
    status_is_error: bool = false,

    fn fromConfig(self: *SettingsForm, cfg: config_mod.Config) void {
        self.setBuf(&self.hotkey, &self.hotkey_len, cfg.hotkey);
        self.setBuf(&self.save_dir, &self.save_dir_len, cfg.save_dir);
        self.marquee_idx = switch (cfg.marquee_position) {
            .top_right => 0,
            .top_left => 1,
            .bottom_right => 2,
            .bottom_left => 3,
        };
        self.theme_idx = if (cfg.theme == .light) 1 else 0;
        self.color = .{
            @as(f32, @floatFromInt(cfg.default_color_rgba[0])) / 255.0,
            @as(f32, @floatFromInt(cfg.default_color_rgba[1])) / 255.0,
            @as(f32, @floatFromInt(cfg.default_color_rgba[2])) / 255.0,
            @as(f32, @floatFromInt(cfg.default_color_rgba[3])) / 255.0,
        };
        self.font_size = @intCast(cfg.default_font_size);
        self.dirty = false;
        self.recording_hotkey = false;
        self.status_len = 0;
    }

    fn setHotkey(self: *SettingsForm, chord: []const u8) void {
        self.setBuf(&self.hotkey, &self.hotkey_len, chord);
        self.dirty = true;
        self.recording_hotkey = false;
    }

    fn setBuf(self: *SettingsForm, buf: []u8, len: *usize, src: []const u8) void {
        _ = self;
        const n = @min(src.len, buf.len - 1);
        @memcpy(buf[0..n], src[0..n]);
        buf[n] = 0;
        len.* = n;
    }

    fn setStatus(self: *SettingsForm, msg: []const u8, is_error: bool) void {
        const n = @min(msg.len, self.status_msg.len - 1);
        @memcpy(self.status_msg[0..n], msg[0..n]);
        self.status_msg[n] = 0;
        self.status_len = n;
        self.status_is_error = is_error;
    }

    fn toConfig(self: *const SettingsForm, allocator: std.mem.Allocator) !config_mod.Config {
        const hotkey = try allocator.dupe(u8, self.hotkey[0..self.hotkey_len]);
        errdefer allocator.free(hotkey);
        const save_dir = if (self.save_dir_len == 0)
            ""
        else
            try allocator.dupe(u8, self.save_dir[0..self.save_dir_len]);
        errdefer if (save_dir.len > 0) allocator.free(save_dir);
        const marquee: config_mod.MarqueePosition = switch (self.marquee_idx) {
            1 => .top_left,
            2 => .bottom_right,
            3 => .bottom_left,
            else => .top_right,
        };
        const theme: config_mod.Theme = if (self.theme_idx == 1) .light else .dark;
        const rgba: [4]u8 = .{
            @intFromFloat(std.math.clamp(self.color[0] * 255.0, 0, 255)),
            @intFromFloat(std.math.clamp(self.color[1] * 255.0, 0, 255)),
            @intFromFloat(std.math.clamp(self.color[2] * 255.0, 0, 255)),
            @intFromFloat(std.math.clamp(self.color[3] * 255.0, 0, 255)),
        };
        return .{
            .save_dir = save_dir,
            .hotkey = hotkey,
            .marquee_position = marquee,
            .theme = theme,
            .default_color_rgba = rgba,
            .default_font_size = @intCast(@max(8, @min(72, self.font_size))),
        };
    }
};

pub const Ui = struct {
    pub fn run(allocator: std.mem.Allocator) !void {
        if (c.glfwInit() == 0) return error.GlfwInitFailed;
        defer c.glfwTerminate();
        c.glfwWindowHint(c.GLFW_CLIENT_API, c.GLFW_OPENGL_ES_API);
        c.glfwWindowHint(c.GLFW_CONTEXT_VERSION_MAJOR, 3);
        c.glfwWindowHint(c.GLFW_CONTEXT_VERSION_MINOR, 0);
        const w = c.glfwCreateWindow(820, 560, "ZigIt", null, null);
        if (w == null) return error.WindowFailed;
        defer c.glfwDestroyWindow(w);
        c.glfwMakeContextCurrent(w);
        c.glfwSwapInterval(1);

        const ctx = c.igCreateContext(null);
        defer c.igDestroyContext(ctx);

        // Load preferences before styling so theme is applied once.
        const cfg_path = try config_mod.Config.configPath(allocator);
        defer allocator.free(cfg_path);
        var cfg = try config_mod.Config.load(allocator, cfg_path);
        defer cfg.deinit(allocator);

        // Real TTF (Inter/Adwaita/OpenSans) instead of Proggy pixel font —
        // must run before first NewFrame so the atlas is ready.
        theme_mod.loadFonts();
        theme_mod.apply(cfg.theme);

        _ = c.cImGui_ImplGlfw_InitForOpenGL(w, true);
        defer c.cImGui_ImplGlfw_Shutdown();
        _ = c.cImGui_ImplOpenGL3_Init("#version 300 es");
        defer c.cImGui_ImplOpenGL3_Shutdown();

        const capture_dir = try storage.captureDir(allocator, cfg.save_dir);
        defer allocator.free(capture_dir);
        var marquee = try marquee_mod.Marquee.init(allocator, capture_dir);
        defer marquee.deinit();
        var toast = toast_mod.Toast.init(allocator);
        defer toast.deinit();

        var form: SettingsForm = .{};
        form.fromConfig(cfg);

        var env = try std.process.getEnvMap(allocator);
        defer env.deinit();
        const detected = compositor.detect(&env);
        if (detected == .unknown) {
            toast.show(.warn, "Unknown compositor — open Settings to bind a hotkey manually.") catch {};
        }

        var applied_theme = cfg.theme;
        var kde_shortcuts_blocked = false;
        defer if (kde_shortcuts_blocked) compositor.setKdeShortcutsBlocked(allocator, false) catch {};

        while (c.glfwWindowShouldClose(w) == 0) {
            c.glfwPollEvents();
            const recording_before_frame = form.recording_hotkey;
            try marquee.poll();
            c.cImGui_ImplOpenGL3_NewFrame();
            c.cImGui_ImplGlfw_NewFrame();
            c.igNewFrame();

            const io = c.igGetIO();
            c.igSetNextWindowPos(.{ .x = 0, .y = 0 }, c.ImGuiCond_Always, .{ .x = 0, .y = 0 });
            c.igSetNextWindowSize(io.*.DisplaySize, c.ImGuiCond_Always);
            const main_flags = c.ImGuiWindowFlags_NoTitleBar |
                c.ImGuiWindowFlags_NoResize |
                c.ImGuiWindowFlags_NoMove |
                c.ImGuiWindowFlags_NoCollapse |
                c.ImGuiWindowFlags_NoBringToFrontOnFocus;
            _ = c.igBegin("##zigit_main", null, main_flags);

            // ── Header ──────────────────────────────────────────────
            theme_mod.pushTitle();
            c.igPushStyleColor_Vec4(c.ImGuiCol_Text, .{ .x = 0.95, .y = 0.34, .z = 0.32, .w = 1.0 });
            c.igText("ZigIt");
            c.igPopStyleColor(1);
            theme_mod.popTitle();
            c.igSameLine(0.0, 14.0);
            c.igSetCursorPosY(c.igGetCursorPosY() + 6.0);
            c.igTextDisabled("Screenshot tool");
            // Right-aligned compositor badge.
            var badge_sz: c.ImVec2 = undefined;
            c.igCalcTextSize(&badge_sz, compositorNameZ(detected), null, false, -1.0);
            c.igSameLine(io.*.DisplaySize.x - badge_sz.x - 36.0, 0.0);
            c.igSetCursorPosY(c.igGetCursorPosY() + 6.0);
            c.igTextDisabled("%s", compositorNameZ(detected));

            c.igSpacing();
            c.igSpacing();

            // ── Tabs ────────────────────────────────────────────────
            c.igPushStyleVar_Vec2(c.ImGuiStyleVar_FramePadding, .{ .x = 16.0, .y = 10.0 });
            if (c.igBeginTabBar("##tabs", 0)) {
                if (c.igBeginTabItem("Captures", null, 0)) {
                    c.igSpacing();
                    drawCaptures(allocator, &marquee, capture_dir, &toast);
                    c.igEndTabItem();
                }
                if (c.igBeginTabItem("Settings", null, 0)) {
                    c.igSpacing();
                    _ = drawSettings(allocator, &form, &cfg, cfg_path, detected, &toast);
                    const want: config_mod.Theme = if (form.theme_idx == 1) .light else .dark;
                    if (want != applied_theme) {
                        theme_mod.apply(want);
                        applied_theme = want;
                    }
                    c.igEndTabItem();
                }
                if (c.igBeginTabItem("About", null, 0)) {
                    c.igSpacing();
                    drawAbout(capture_dir, cfg_path, detected, cfg.hotkey);
                    c.igEndTabItem();
                }
                c.igEndTabBar();
            }
            c.igPopStyleVar(1);

            c.igEnd();

            if (detected == .kde and form.recording_hotkey != recording_before_frame) {
                if (form.recording_hotkey) {
                    if (compositor.setKdeShortcutsBlocked(allocator, true)) |_| {
                        kde_shortcuts_blocked = true;
                    } else |_| {
                        form.setStatus("Could not pause KDE shortcuts; use Clear for Print", true);
                    }
                } else if (kde_shortcuts_blocked) {
                    compositor.setKdeShortcutsBlocked(allocator, false) catch {};
                    kde_shortcuts_blocked = false;
                }
            }

            toast.draw();
            c.igRender();
            var fb_w: c_int = 0;
            var fb_h: c_int = 0;
            c.glfwGetFramebufferSize(w, &fb_w, &fb_h);
            c.glViewport(0, 0, fb_w, fb_h);
            // Match theme clear color.
            if (applied_theme == .light) {
                c.glClearColor(0.96, 0.96, 0.97, 1.0);
            } else {
                c.glClearColor(0.10, 0.10, 0.11, 1.0);
            }
            c.glClear(c.GL_COLOR_BUFFER_BIT);
            c.cImGui_ImplOpenGL3_RenderDrawData(c.igGetDrawData());
            c.glfwSwapBuffers(w);
            if (!recording_before_frame and !form.recording_hotkey and
                c.igIsKeyPressed_Bool(c.ImGuiKey_Escape, false)) break;
        }
    }
};

const label_col_w: f32 = 150.0;

fn formRowStart(label: [*:0]const u8) void {
    c.igAlignTextToFramePadding();
    c.igText("%s", label);
    c.igSameLine(label_col_w, 0.0);
}

fn drawCaptures(
    allocator: std.mem.Allocator,
    marquee: *marquee_mod.Marquee,
    capture_dir: []const u8,
    toast: *toast_mod.Toast,
) void {
    c.igTextDisabled("Recent captures. Click a thumbnail to open the editor.");
    c.igSpacing();

    // Quick actions
    theme_mod.pushAccent();
    if (c.igButton("Capture region", .{ .x = 148, .y = 36 })) {
        spawnCapture(allocator, &.{ "zigit", "capture" }, toast);
    }
    theme_mod.popAccent();
    c.igSameLine(0.0, 10.0);
    theme_mod.pushGhost();
    if (c.igButton("Capture window", .{ .x = 148, .y = 36 })) {
        spawnCapture(allocator, &.{ "zigit", "capture", "--window" }, toast);
    }
    theme_mod.popGhost();
    c.igSameLine(0.0, 10.0);
    theme_mod.pushGhost();
    if (c.igButton("Open folder", .{ .x = 128, .y = 36 })) {
        openFolder(allocator, capture_dir, toast);
    }
    theme_mod.popGhost();
    c.igSameLine(0.0, 14.0);
    c.igSetCursorPosY(c.igGetCursorPosY() + 8.0);
    c.igTextDisabled("%zu capture(s)", marquee.thumbnails.items.len);

    c.igSpacing();
    c.igSpacing();

    // Thumbnail strip fills remaining space.
    var avail: c.ImVec2 = undefined;
    c.igGetContentRegionAvail(&avail);
    _ = c.igBeginChild_Str("##marquee_strip", .{ .x = avail.x, .y = avail.y - 4 }, 0, c.ImGuiWindowFlags_HorizontalScrollbar);
    marquee.drawContent();
    c.igEndChild();
}

fn drawSettings(
    allocator: std.mem.Allocator,
    form: *SettingsForm,
    cfg: *config_mod.Config,
    cfg_path: []const u8,
    detected: compositor.Compositor,
    toast: *toast_mod.Toast,
) bool {
    var changed = false;

    theme_mod.pushHeading();
    c.igText("Preferences");
    theme_mod.popHeading();
    c.igTextDisabled("%s", pathCstr(cfg_path));
    c.igSpacing();

    // ── Capture ─────────────────────────────────────────────────
    theme_mod.sectionHeader("Capture");
    formRowStart("Hotkey");
    if (drawHotkeyRecorder(form)) {
        changed = true;
        if (detected == .kde) showKdeHotkeyOwner(allocator, form);
    }
    c.igIndent(label_col_w);
    c.igTextDisabled("Click Record, then press the keys you want. Esc cancels.");
    c.igUnindent(label_col_w);

    formRowStart("Save directory");
    c.igSetNextItemWidth(360);
    if (c.igInputTextWithHint(
        "##save_dir",
        "~/screenshots",
        &form.save_dir,
        form.save_dir.len,
        0,
        null,
        null,
    )) {
        form.save_dir_len = std.mem.len(@as([*:0]const u8, @ptrCast(&form.save_dir)));
        form.dirty = true;
        changed = true;
    }
    if (c.igIsItemHovered(0)) {
        c.igSetTooltip("Empty uses ~/screenshots. You can also type a path or click Browse.");
    }
    c.igSameLine(0.0, 8.0);
    if (c.igButton("Browse…", .{ .x = 90, .y = 0 })) {
        const picked = browseDirectory(allocator, form) catch |e| blk: {
            form.setStatus(@errorName(e), true);
            toast.show(.@"error", "Folder picker failed") catch {};
            break :blk false;
        };
        if (picked) {
            form.dirty = true;
            changed = true;
        }
    }
    c.igIndent(label_col_w);
    c.igTextDisabled("After capture: copy PNG to clipboard and open the editor.");
    c.igUnindent(label_col_w);

    // ── Appearance ──────────────────────────────────────────────
    theme_mod.sectionHeader("Appearance");
    formRowStart("Theme");
    if (c.igRadioButton_Bool("Dark", form.theme_idx == 0)) {
        form.theme_idx = 0;
        form.dirty = true;
        changed = true;
    }
    c.igSameLine(0.0, 20.0);
    if (c.igRadioButton_Bool("Light", form.theme_idx == 1)) {
        form.theme_idx = 1;
        form.dirty = true;
        changed = true;
    }

    formRowStart("Marquee");
    c.igSetNextItemWidth(220);
    const positions = "top-right\x00top-left\x00bottom-right\x00bottom-left\x00";
    if (c.igCombo_Str("##marquee_pos", &form.marquee_idx, positions, -1)) {
        form.dirty = true;
        changed = true;
    }
    c.igIndent(label_col_w);
    c.igTextDisabled("Preferred corner for the floating capture strip.");
    c.igUnindent(label_col_w);

    // ── Editor defaults ─────────────────────────────────────────
    theme_mod.sectionHeader("Editor defaults");
    formRowStart("Color");
    if (c.igColorEdit4("##ann_color", &form.color, c.ImGuiColorEditFlags_NoInputs | c.ImGuiColorEditFlags_NoLabel | c.ImGuiColorEditFlags_AlphaBar)) {
        form.dirty = true;
        changed = true;
    }
    formRowStart("Font size");
    c.igSetNextItemWidth(120);
    if (c.igInputInt("##font_size", &form.font_size, 1, 2, 0)) {
        if (form.font_size < 8) form.font_size = 8;
        if (form.font_size > 72) form.font_size = 72;
        form.dirty = true;
        changed = true;
    }

    // ── Compositor / hotkey install ─────────────────────────────
    theme_mod.sectionHeader("Hotkey binding");
    formRowStart("Compositor");
    c.igAlignTextToFramePadding();
    c.igText("%s", compositorNameZ(detected));

    if (detected == .unknown) {
        c.igTextWrapped("Could not identify your compositor. Bind a key yourself to run:  zigit capture");
    } else if (detected == .gnome) {
        c.igTextWrapped("GNOME: use Settings → Keyboard → Custom Shortcuts, or run zigit setup.");
    } else {
        c.igTextDisabled("Writes a compositor snippet so your hotkey launches a capture.");
        c.igSpacing();
        if (c.igButton("Install hotkey binding", .{ .x = 200, .y = 34 })) {
            installBinding(allocator, form, detected, toast) catch |e| {
                form.setStatus(@errorName(e), true);
                toast.show(.@"error", "Failed to install hotkey binding") catch {};
            };
        }
        c.igSameLine(0.0, 10.0);
        theme_mod.pushGhost();
        if (c.igButton("Uninstall", .{ .x = 120, .y = 34 })) {
            uninstallBinding(allocator, detected, toast) catch |e| {
                form.setStatus(@errorName(e), true);
            };
        }
        theme_mod.popGhost();
        c.igSameLine(0.0, 10.0);
        theme_mod.pushGhost();
        if (c.igButton("Dry-run setup", .{ .x = 130, .y = 34 })) {
            var child = std.process.Child.init(&.{ "zigit", "setup", "--dry-run" }, allocator);
            child.spawn() catch |e| {
                std.debug.print("zigit: setup spawn failed: {s}\n", .{@errorName(e)});
            };
            toast.show(.info, "Ran setup --dry-run (see terminal)") catch {};
        }
        theme_mod.popGhost();
    }

    c.igSpacing();
    c.igSpacing();
    c.igSeparator();
    c.igSpacing();

    // ── Save / reset ────────────────────────────────────────────
    if (form.dirty) {
        theme_mod.pushAccent();
    }
    if (c.igButton("Save preferences", .{ .x = 168, .y = 36 })) {
        savePrefs(allocator, form, cfg, cfg_path, toast) catch |e| {
            form.setStatus(@errorName(e), true);
            toast.show(.@"error", "Could not save preferences") catch {};
        };
    }
    if (form.dirty) theme_mod.popAccent();

    c.igSameLine(0.0, 10.0);
    theme_mod.pushGhost();
    if (c.igButton("Reset to defaults", .{ .x = 156, .y = 36 })) {
        const d = config_mod.Config.defaults();
        form.fromConfig(d);
        form.dirty = true;
        form.setStatus("Reset — click Save preferences to write disk", false);
    }
    theme_mod.popGhost();

    if (form.status_len > 0) {
        c.igSpacing();
        if (form.status_is_error) {
            c.igPushStyleColor_Vec4(c.ImGuiCol_Text, .{ .x = 1.0, .y = 0.40, .z = 0.35, .w = 1.0 });
        } else {
            c.igPushStyleColor_Vec4(c.ImGuiCol_Text, .{ .x = 0.45, .y = 0.85, .z = 0.50, .w = 1.0 });
        }
        c.igText("%s", @as([*:0]const u8, @ptrCast(&form.status_msg)));
        c.igPopStyleColor(1);
    }

    return changed;
}

fn drawAbout(
    capture_dir: []const u8,
    cfg_path: []const u8,
    detected: compositor.Compositor,
    hotkey: []const u8,
) void {
    theme_mod.pushTitle();
    c.igPushStyleColor_Vec4(c.ImGuiCol_Text, .{ .x = 0.95, .y = 0.34, .z = 0.32, .w = 1.0 });
    c.igText("ZigIt");
    c.igPopStyleColor(1);
    theme_mod.popTitle();
    c.igTextDisabled("Wayland-first screenshot workflow for Linux.");
    c.igSpacing();

    theme_mod.sectionHeader("How to capture");
    c.igBulletText("Press your hotkey (default: Print Screen)");
    c.igBulletText("Or use Capture region / Capture window on the Captures tab");
    c.igBulletText("PNG is saved and copied to the clipboard automatically");
    c.igBulletText("The editor opens so you can annotate immediately");

    theme_mod.sectionHeader("Paths");
    formRowStart("Captures");
    c.igTextWrapped("%s", pathCstr(capture_dir));
    formRowStart("Config");
    c.igTextWrapped("%s", pathCstr(cfg_path));
    formRowStart("Hotkey");
    c.igText("%s", pathCstr(hotkey));
    formRowStart("Session");
    c.igText("%s", compositorNameZ(detected));

    theme_mod.sectionHeader("CLI");
    c.igTextDisabled("zigit daemon            this window + capture history");
    c.igTextDisabled("zigit capture           interactive region capture");
    c.igTextDisabled("zigit capture --window  active window capture");
    c.igTextDisabled("zigit edit <path>       open editor");
    c.igTextDisabled("zigit setup             install compositor hotkey");
}

fn savePrefs(
    allocator: std.mem.Allocator,
    form: *SettingsForm,
    cfg: *config_mod.Config,
    cfg_path: []const u8,
    toast: *toast_mod.Toast,
) !void {
    // Refresh length from C buffer (InputText writes NUL-terminated).
    // Hotkey length is maintained by the recorder, not free-typed.
    form.save_dir_len = std.mem.len(@as([*:0]const u8, @ptrCast(&form.save_dir)));
    form.recording_hotkey = false;

    var next = try form.toConfig(allocator);
    // Don't free on error after save — transfer ownership into cfg.
    try next.save(cfg_path);
    cfg.deinit(allocator);
    cfg.* = next;
    form.dirty = false;
    form.setStatus("Preferences saved (restart daemon if save directory changed)", false);
    toast.show(.info, "Preferences saved") catch {};
}

/// Click-to-record hotkey control. Returns true when the chord changes.
fn drawHotkeyRecorder(form: *SettingsForm) bool {
    var changed = false;

    // Display box — not editable by typing.
    const label: [*:0]const u8 = if (form.recording_hotkey)
        "Press keys…"
    else if (form.hotkey_len > 0)
        @as([*:0]const u8, @ptrCast(&form.hotkey))
    else
        "Print";

    if (form.recording_hotkey) {
        theme_mod.pushAccent();
    }
    // Fixed-width so the Record button doesn't jump around.
    c.igPushStyleColor_Vec4(c.ImGuiCol_Button, .{ .x = 0.13, .y = 0.13, .z = 0.15, .w = 1.0 });
    c.igPushStyleColor_Vec4(c.ImGuiCol_ButtonHovered, .{ .x = 0.18, .y = 0.18, .z = 0.20, .w = 1.0 });
    c.igPushStyleColor_Vec4(c.ImGuiCol_ButtonActive, .{ .x = 0.18, .y = 0.18, .z = 0.20, .w = 1.0 });
    _ = c.igButton(label, .{ .x = 220, .y = 0 });
    c.igPopStyleColor(3);
    if (form.recording_hotkey) theme_mod.popAccent();

    c.igSameLine(0.0, 8.0);
    if (form.recording_hotkey) {
        if (c.igButton("Cancel", .{ .x = 90, .y = 0 })) {
            form.recording_hotkey = false;
        }
        // Capture the next non-modifier key while modifiers are held.
        if (pollHotkeyChord(form)) changed = true;
    } else {
        if (c.igButton("Record", .{ .x = 90, .y = 0 })) {
            form.recording_hotkey = true;
        }
        c.igSameLine(0.0, 8.0);
        theme_mod.pushGhost();
        if (c.igButton("Clear", .{ .x = 70, .y = 0 })) {
            form.setHotkey("Print");
            changed = true;
        }
        theme_mod.popGhost();
    }
    if (c.igIsItemHovered(0) and !form.recording_hotkey) {
        c.igSetTooltip("Record a key combination (e.g. Print, Super+Shift+S)");
    }
    return changed;
}

/// While recording: Esc cancels; any non-modifier key press commits Super/Ctrl/Alt/Shift+key.
fn pollHotkeyChord(form: *SettingsForm) bool {
    if (c.igIsKeyPressed_Bool(c.ImGuiKey_Escape, false)) {
        form.recording_hotkey = false;
        return false;
    }

    const ctrl = c.igIsKeyDown_Nil(c.ImGuiKey_LeftCtrl) or c.igIsKeyDown_Nil(c.ImGuiKey_RightCtrl);
    const shift = c.igIsKeyDown_Nil(c.ImGuiKey_LeftShift) or c.igIsKeyDown_Nil(c.ImGuiKey_RightShift);
    const alt = c.igIsKeyDown_Nil(c.ImGuiKey_LeftAlt) or c.igIsKeyDown_Nil(c.ImGuiKey_RightAlt);
    const super = c.igIsKeyDown_Nil(c.ImGuiKey_LeftSuper) or c.igIsKeyDown_Nil(c.ImGuiKey_RightSuper);

    // Keys we accept as the "main" key of a chord (not pure modifiers).
    // ImGuiKey is an unsigned enum in cimgui.
    const keys = [_]struct { key: c_uint, name: []const u8 }{
        .{ .key = c.ImGuiKey_PrintScreen, .name = "Print" },
        .{ .key = c.ImGuiKey_ScrollLock, .name = "Scroll_Lock" },
        .{ .key = c.ImGuiKey_Pause, .name = "Pause" },
        .{ .key = c.ImGuiKey_Insert, .name = "Insert" },
        .{ .key = c.ImGuiKey_Delete, .name = "Delete" },
        .{ .key = c.ImGuiKey_Home, .name = "Home" },
        .{ .key = c.ImGuiKey_End, .name = "End" },
        .{ .key = c.ImGuiKey_PageUp, .name = "Page_Up" },
        .{ .key = c.ImGuiKey_PageDown, .name = "Page_Down" },
        .{ .key = c.ImGuiKey_UpArrow, .name = "Up" },
        .{ .key = c.ImGuiKey_DownArrow, .name = "Down" },
        .{ .key = c.ImGuiKey_LeftArrow, .name = "Left" },
        .{ .key = c.ImGuiKey_RightArrow, .name = "Right" },
        .{ .key = c.ImGuiKey_Tab, .name = "Tab" },
        .{ .key = c.ImGuiKey_Space, .name = "Space" },
        .{ .key = c.ImGuiKey_Enter, .name = "Return" },
        .{ .key = c.ImGuiKey_F1, .name = "F1" },
        .{ .key = c.ImGuiKey_F2, .name = "F2" },
        .{ .key = c.ImGuiKey_F3, .name = "F3" },
        .{ .key = c.ImGuiKey_F4, .name = "F4" },
        .{ .key = c.ImGuiKey_F5, .name = "F5" },
        .{ .key = c.ImGuiKey_F6, .name = "F6" },
        .{ .key = c.ImGuiKey_F7, .name = "F7" },
        .{ .key = c.ImGuiKey_F8, .name = "F8" },
        .{ .key = c.ImGuiKey_F9, .name = "F9" },
        .{ .key = c.ImGuiKey_F10, .name = "F10" },
        .{ .key = c.ImGuiKey_F11, .name = "F11" },
        .{ .key = c.ImGuiKey_F12, .name = "F12" },
        .{ .key = c.ImGuiKey_0, .name = "0" },
        .{ .key = c.ImGuiKey_1, .name = "1" },
        .{ .key = c.ImGuiKey_2, .name = "2" },
        .{ .key = c.ImGuiKey_3, .name = "3" },
        .{ .key = c.ImGuiKey_4, .name = "4" },
        .{ .key = c.ImGuiKey_5, .name = "5" },
        .{ .key = c.ImGuiKey_6, .name = "6" },
        .{ .key = c.ImGuiKey_7, .name = "7" },
        .{ .key = c.ImGuiKey_8, .name = "8" },
        .{ .key = c.ImGuiKey_9, .name = "9" },
        .{ .key = c.ImGuiKey_A, .name = "A" },
        .{ .key = c.ImGuiKey_B, .name = "B" },
        .{ .key = c.ImGuiKey_C, .name = "C" },
        .{ .key = c.ImGuiKey_D, .name = "D" },
        .{ .key = c.ImGuiKey_E, .name = "E" },
        .{ .key = c.ImGuiKey_F, .name = "F" },
        .{ .key = c.ImGuiKey_G, .name = "G" },
        .{ .key = c.ImGuiKey_H, .name = "H" },
        .{ .key = c.ImGuiKey_I, .name = "I" },
        .{ .key = c.ImGuiKey_J, .name = "J" },
        .{ .key = c.ImGuiKey_K, .name = "K" },
        .{ .key = c.ImGuiKey_L, .name = "L" },
        .{ .key = c.ImGuiKey_M, .name = "M" },
        .{ .key = c.ImGuiKey_N, .name = "N" },
        .{ .key = c.ImGuiKey_O, .name = "O" },
        .{ .key = c.ImGuiKey_P, .name = "P" },
        .{ .key = c.ImGuiKey_Q, .name = "Q" },
        .{ .key = c.ImGuiKey_R, .name = "R" },
        .{ .key = c.ImGuiKey_S, .name = "S" },
        .{ .key = c.ImGuiKey_T, .name = "T" },
        .{ .key = c.ImGuiKey_U, .name = "U" },
        .{ .key = c.ImGuiKey_V, .name = "V" },
        .{ .key = c.ImGuiKey_W, .name = "W" },
        .{ .key = c.ImGuiKey_X, .name = "X" },
        .{ .key = c.ImGuiKey_Y, .name = "Y" },
        .{ .key = c.ImGuiKey_Z, .name = "Z" },
    };

    for (keys) |k| {
        if (!c.igIsKeyPressed_Bool(k.key, false)) continue;

        var buf: [64]u8 = undefined;
        var fbs = std.io.fixedBufferStream(&buf);
        const w = fbs.writer();
        // Order matches common compositor convention: Super, Ctrl, Alt, Shift, key.
        if (super) w.writeAll("Super+") catch {};
        if (ctrl) w.writeAll("Ctrl+") catch {};
        if (alt) w.writeAll("Alt+") catch {};
        if (shift) w.writeAll("Shift+") catch {};
        w.writeAll(k.name) catch {};
        form.setHotkey(fbs.getWritten());
        return true;
    }
    return false;
}

/// Opens a native directory picker (kdialog on KDE, else zenity).
/// On success, writes the chosen absolute path into form.save_dir and returns true.
fn browseDirectory(allocator: std.mem.Allocator, form: *SettingsForm) !bool {
    // Start the dialog in the currently configured dir, or ~/screenshots.
    const start = blk: {
        if (form.save_dir_len > 0) {
            break :blk try storage.expandHome(allocator, form.save_dir[0..form.save_dir_len]);
        }
        break :blk try storage.captureDir(allocator, "");
    };
    defer allocator.free(start);

    const picked = try pickDirectory(allocator, start);
    if (picked) |path| {
        defer allocator.free(path);
        form.setBuf(&form.save_dir, &form.save_dir_len, path);
        return true;
    }
    return false;
}

/// Returns an owned absolute path, or null if the user cancelled.
fn pickDirectory(allocator: std.mem.Allocator, start: []const u8) !?[]u8 {
    // Prefer kdialog on KDE; fall back to zenity.
    if (try runDirPicker(allocator, &.{ "kdialog", "--getexistingdirectory", start })) |p| return p;
    if (try runDirPicker(allocator, &.{ "zenity", "--file-selection", "--directory", "--filename", start })) |p| return p;
    return error.NoFolderPicker;
}

fn runDirPicker(allocator: std.mem.Allocator, argv: []const []const u8) !?[]u8 {
    var child = std.process.Child.init(argv, allocator);
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Ignore;
    child.spawn() catch return null;
    const raw = child.stdout.?.readToEndAlloc(allocator, 4096) catch {
        _ = child.wait() catch {};
        return null;
    };
    errdefer allocator.free(raw);
    const term = child.wait() catch {
        allocator.free(raw);
        return null;
    };
    switch (term) {
        .Exited => |code| {
            if (code != 0) {
                allocator.free(raw);
                return null; // cancel
            }
        },
        else => {
            allocator.free(raw);
            return null;
        },
    }
    const trimmed = std.mem.trim(u8, raw, " \t\r\n");
    if (trimmed.len == 0) {
        allocator.free(raw);
        return null;
    }
    // Return a clean dupe of the trimmed path; free the raw buffer.
    const out = try allocator.dupe(u8, trimmed);
    allocator.free(raw);
    return out;
}

fn showKdeHotkeyOwner(allocator: std.mem.Allocator, form: *SettingsForm) void {
    const hotkey = form.hotkey[0..form.hotkey_len];
    const maybe_owner = compositor.kdeShortcutOwner(allocator, hotkey) catch return;
    const owner = maybe_owner orelse return;
    defer owner.deinit(allocator);
    if (owner.isZigit()) return;
    var buf: [128]u8 = undefined;
    const message = if (owner.isSpectacle())
        std.fmt.bufPrint(&buf, "{s} already uses this key; Install will replace it", .{owner.name}) catch return
    else
        std.fmt.bufPrint(&buf, "{s} already uses this key; choose another", .{owner.name}) catch return;
    form.setStatus(message, !owner.isSpectacle());
}

fn installBinding(
    allocator: std.mem.Allocator,
    form: *SettingsForm,
    detected: compositor.Compositor,
    toast: *toast_mod.Toast,
) !void {
    form.hotkey_len = std.mem.len(@as([*:0]const u8, @ptrCast(&form.hotkey)));
    const hotkey = form.hotkey[0..form.hotkey_len];
    const home = std.posix.getenv("HOME") orelse return error.NoHome;
    const exe = try std.fs.selfExePathAlloc(allocator);
    defer allocator.free(exe);
    const action = try std.fmt.allocPrint(allocator, "\"{s}\" capture --overlay", .{exe});
    defer allocator.free(action);
    const maybe_owner = if (detected == .kde)
        try compositor.kdeShortcutOwner(allocator, hotkey)
    else
        null;
    defer if (maybe_owner) |owner| owner.deinit(allocator);
    if (maybe_owner) |owner| {
        if (!owner.isZigit() and !owner.isSpectacle()) {
            var buf: [128]u8 = undefined;
            const message = std.fmt.bufPrint(&buf, "{s} already uses this hotkey", .{owner.name}) catch "Hotkey already in use";
            form.setStatus(message, true);
            toast.show(.warn, "Choose another hotkey") catch {};
            return;
        }
    }
    const binding = try compositor.install(allocator, detected, home, hotkey, action);
    defer allocator.free(binding.snippetPath);
    defer allocator.free(binding.snippet);
    if (maybe_owner) |owner| {
        if (owner.isSpectacle()) try compositor.overrideKdeShortcut(allocator, home, owner);
    }
    compositor.reload(allocator, binding.reload) catch {
        form.setStatus("Binding installed; reload compositor manually", false);
        toast.show(.warn, "Binding installed — reload compositor to apply") catch {};
        return;
    };
    if (maybe_owner != null and maybe_owner.?.isSpectacle()) {
        form.setStatus("Hotkey installed; previous screenshot shortcut replaced", false);
        toast.show(.info, "ZigIt now owns the hotkey") catch {};
    } else {
        form.setStatus("Hotkey binding installed", false);
        toast.show(.info, "Hotkey binding installed") catch {};
    }
}

fn uninstallBinding(
    allocator: std.mem.Allocator,
    detected: compositor.Compositor,
    toast: *toast_mod.Toast,
) !void {
    const home = std.posix.getenv("HOME") orelse return error.NoHome;
    const path = try compositor.snippetPathFor(allocator, detected, home);
    defer allocator.free(path);
    const binding = compositor.Binding{ .snippetPath = path, .reload = .none, .snippet = &.{} };
    try compositor.uninstall(allocator, detected, binding);
    compositor.reload(allocator, compositor.reloadFor(detected)) catch {};
    toast.show(.info, "Hotkey binding removed") catch {};
}

fn spawnCapture(allocator: std.mem.Allocator, argv: []const []const u8, toast: *toast_mod.Toast) void {
    var child = std.process.Child.init(argv, allocator);
    child.spawn() catch |e| {
        std.debug.print("zigit: capture spawn failed: {s}\n", .{@errorName(e)});
        toast.show(.@"error", "Failed to start capture") catch {};
        return;
    };
    toast.show(.info, "Starting capture…") catch {};
}

fn openFolder(allocator: std.mem.Allocator, dir: []const u8, toast: *toast_mod.Toast) void {
    // xdg-open is the portable Linux choice.
    var child = std.process.Child.init(&.{ "xdg-open", dir }, allocator);
    child.spawn() catch |e| {
        std.debug.print("zigit: open folder failed: {s}\n", .{@errorName(e)});
        toast.show(.@"error", "Could not open captures folder") catch {};
        return;
    };
}

/// Thread-local-ish scratch for NUL-terminated paths passed to ImGui.
/// ImGui reads the pointer during the call only, so a static buffer is fine
/// as long as we don't nest two pathCstr uses in one printf (we don't).
var path_scratch: [std.fs.max_path_bytes]u8 = undefined;

fn pathCstr(path: []const u8) [*:0]const u8 {
    const n = @min(path.len, path_scratch.len - 1);
    @memcpy(path_scratch[0..n], path[0..n]);
    path_scratch[n] = 0;
    return path_scratch[0..n :0].ptr;
}

fn compositorNameZ(k: compositor.Compositor) [*:0]const u8 {
    return switch (k) {
        .sway => "Sway",
        .hyprland => "Hyprland",
        .river => "River",
        .labwc => "Labwc",
        .kde => "KDE Plasma",
        .gnome => "GNOME",
        .unknown => "Unknown",
    };
}
