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
const png = @import("png");
const editor = @import("editor");
const theme_mod = @import("theme");
const config_mod = @import("config");

const Tool = enum { crop, arrow, rect, pen, text, blur, step };

const ToolInfo = struct {
    tool: Tool,
    label: [:0]const u8,
    hint: [:0]const u8,
};

const tools = [_]ToolInfo{
    .{ .tool = .crop, .label = "Crop", .hint = "Drag to crop" },
    .{ .tool = .arrow, .label = "Arrow", .hint = "Drag to draw an arrow" },
    .{ .tool = .rect, .label = "Rect", .hint = "Drag a rectangle outline" },
    .{ .tool = .pen, .label = "Pen", .hint = "Freehand pen" },
    .{ .tool = .text, .label = "Text", .hint = "Click to place text" },
    .{ .tool = .blur, .label = "Blur", .hint = "Drag to pixelate/blur" },
    .{ .tool = .step, .label = "Step", .hint = "Numbered step marker" },
};

fn uploadTexture(rgba: []const u8, w: u32, h: u32) c_uint {
    var tex: c_uint = 0;
    c.glGenTextures(1, &tex);
    c.glBindTexture(c.GL_TEXTURE_2D, tex);
    c.glTexParameteri(c.GL_TEXTURE_2D, c.GL_TEXTURE_MIN_FILTER, c.GL_LINEAR);
    c.glTexParameteri(c.GL_TEXTURE_2D, c.GL_TEXTURE_MAG_FILTER, c.GL_LINEAR);
    // GL_RGBA8 lives in gl3.h; GLES2's gl2.h only guarantees GL_RGBA, which is
    // also accepted as the internal format here.
    c.glTexImage2D(c.GL_TEXTURE_2D, 0, c.GL_RGBA, @intCast(w), @intCast(h), 0, c.GL_RGBA, c.GL_UNSIGNED_BYTE, rgba.ptr);
    return tex;
}

pub const EditorWindow = struct {
    pub fn run(allocator: std.mem.Allocator, path: []const u8) !void {
        const bytes = try std.fs.cwd().readFileAlloc(allocator, path, 32 * 1024 * 1024);
        defer allocator.free(bytes);
        var w: u32 = 0;
        var h: u32 = 0;
        const px = try png.decode(allocator, bytes, &w, &h);
        defer allocator.free(px);

        var doc = try editor.Document.init(allocator, w, h);
        defer doc.deinit();
        @memcpy(doc.base.pixels, px);

        const path_z = try allocator.dupeZ(u8, path);
        defer allocator.free(path_z.ptr[0 .. path_z.len + 1]);

        // Prefer user theme from config when available.
        var theme: config_mod.Theme = .dark;
        var default_color: [4]f32 = .{ 1.0, 0.23, 0.19, 1.0 };
        {
            const cfg_path = config_mod.Config.configPath(allocator) catch null;
            if (cfg_path) |p| {
                defer allocator.free(p);
                var cfg = config_mod.Config.load(allocator, p) catch null;
                if (cfg) |*loaded| {
                    defer loaded.deinit(allocator);
                    theme = loaded.theme;
                    default_color = .{
                        @as(f32, @floatFromInt(loaded.default_color_rgba[0])) / 255.0,
                        @as(f32, @floatFromInt(loaded.default_color_rgba[1])) / 255.0,
                        @as(f32, @floatFromInt(loaded.default_color_rgba[2])) / 255.0,
                        @as(f32, @floatFromInt(loaded.default_color_rgba[3])) / 255.0,
                    };
                }
            }
        }

        // Window sized to the image + chrome, capped at 1400x900.
        if (c.glfwInit() == 0) return error.GlfwInitFailed;
        defer c.glfwTerminate();
        c.glfwWindowHint(c.GLFW_CLIENT_API, c.GLFW_OPENGL_ES_API);
        c.glfwWindowHint(c.GLFW_CONTEXT_VERSION_MAJOR, 3);
        c.glfwWindowHint(c.GLFW_CONTEXT_VERSION_MINOR, 0);
        const win_w: c_int = @intCast(@min(w + 120, 1400));
        const win_h: c_int = @intCast(@min(h + 100, 900));
        const win = c.glfwCreateWindow(win_w, win_h, "ZigIt Editor", null, null);
        if (win == null) return error.WindowFailed;
        defer c.glfwDestroyWindow(win);
        c.glfwMakeContextCurrent(win);
        c.glfwSwapInterval(1);

        const ctx = c.igCreateContext(null);
        defer c.igDestroyContext(ctx);
        theme_mod.loadFonts();
        theme_mod.apply(theme);
        _ = c.cImGui_ImplGlfw_InitForOpenGL(win, true);
        defer c.cImGui_ImplGlfw_Shutdown();
        _ = c.cImGui_ImplOpenGL3_Init("#version 300 es");
        defer c.cImGui_ImplOpenGL3_Shutdown();

        const tex = uploadTexture(doc.base.pixels, w, h);
        defer c.glDeleteTextures(1, &tex);

        var current_tool: Tool = .arrow;
        var color = default_color;
        var status: enum { idle, saved, save_failed } = .idle;
        var status_ticks: u32 = 0;

        while (c.glfwWindowShouldClose(win) == 0) {
            c.glfwPollEvents();
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
                c.ImGuiWindowFlags_MenuBar;
            _ = c.igBegin("##editor_main", null, main_flags);

            // ── Menu bar ────────────────────────────────────────────
            if (c.igBeginMenuBar()) {
                if (c.igBeginMenu("File", true)) {
                    if (c.igMenuItem_Bool("Save", "Ctrl+S", false, true)) {
                        status = if (doc.save(allocator, path)) |_| .saved else |_| .save_failed;
                        status_ticks = 120;
                    }
                    if (c.igMenuItem_Bool("Close", "Esc", false, true)) {
                        c.glfwSetWindowShouldClose(win, c.GLFW_TRUE);
                    }
                    c.igEndMenu();
                }
                if (c.igBeginMenu("Edit", true)) {
                    if (c.igMenuItem_Bool("Undo", "Ctrl+Z", false, doc.ops.items.len > 0)) {
                        doc.undo();
                    }
                    if (c.igMenuItem_Bool("Redo", "Ctrl+Y", false, doc.redo_stack.items.len > 0)) {
                        doc.redo();
                    }
                    c.igEndMenu();
                }
                c.igEndMenuBar();
            }

            // ── Left tool rail ──────────────────────────────────────
            const rail_w: f32 = 96.0;
            _ = c.igBeginChild_Str("##tools", .{ .x = rail_w, .y = 0 }, c.ImGuiChildFlags_Borders, 0);
            theme_mod.pushHeading();
            c.igText("Tools");
            theme_mod.popHeading();
            c.igSpacing();
            for (tools) |ti| {
                const selected = current_tool == ti.tool;
                if (selected) theme_mod.pushAccent() else theme_mod.pushGhost();
                if (c.igButton(ti.label.ptr, .{ .x = rail_w - 20, .y = 34 })) {
                    current_tool = ti.tool;
                }
                if (selected) theme_mod.popAccent() else theme_mod.popGhost();
                if (c.igIsItemHovered(0)) c.igSetTooltip("%s", ti.hint.ptr);
            }
            c.igSpacing();
            c.igSeparator();
            c.igSpacing();
            c.igText("Color");
            _ = c.igColorEdit4("##ann_color", &color, c.ImGuiColorEditFlags_NoInputs | c.ImGuiColorEditFlags_NoLabel | c.ImGuiColorEditFlags_AlphaBar);
            c.igSpacing();
            if (c.igButton("Undo", .{ .x = rail_w - 20, .y = 28 })) doc.undo();
            if (c.igButton("Redo", .{ .x = rail_w - 20, .y = 28 })) doc.redo();
            c.igSpacing();
            theme_mod.pushAccent();
            if (c.igButton("Save", .{ .x = rail_w - 20, .y = 32 })) {
                status = if (doc.save(allocator, path)) |_| .saved else |_| .save_failed;
                status_ticks = 120;
            }
            theme_mod.popAccent();
            c.igEndChild();

            c.igSameLine(0.0, 10.0);

            // ── Canvas ──────────────────────────────────────────────
            _ = c.igBeginChild_Str("##canvas", .{ .x = 0, .y = 0 }, c.ImGuiChildFlags_Borders, c.ImGuiWindowFlags_HorizontalScrollbar);
            // Header line: path + dimensions + active tool.
            c.igTextDisabled("%s", path_z.ptr);
            c.igSameLine(0.0, 12.0);
            c.igText("%dx%d", w, h);
            c.igSameLine(0.0, 12.0);
            c.igTextDisabled("· %s", toolNameZ(current_tool));
            if (status_ticks > 0) {
                status_ticks -= 1;
                c.igSameLine(0.0, 16.0);
                switch (status) {
                    .saved => {
                        c.igPushStyleColor_Vec4(c.ImGuiCol_Text, .{ .x = 0.40, .y = 0.85, .z = 0.45, .w = 1.0 });
                        c.igText("Saved");
                        c.igPopStyleColor(1);
                    },
                    .save_failed => {
                        c.igPushStyleColor_Vec4(c.ImGuiCol_Text, .{ .x = 1.0, .y = 0.35, .z = 0.30, .w = 1.0 });
                        c.igText("Save failed");
                        c.igPopStyleColor(1);
                    },
                    .idle => {},
                }
            }
            c.igSeparator();
            c.igSpacing();

            // Fit image to available region while preserving aspect.
            var avail: c.ImVec2 = undefined;
            c.igGetContentRegionAvail(&avail);
            const iw: f32 = @floatFromInt(w);
            const ih: f32 = @floatFromInt(h);
            var disp_w = iw;
            var disp_h = ih;
            if (disp_w > avail.x or disp_h > avail.y - 4) {
                const sx = avail.x / iw;
                const sy = (avail.y - 4) / ih;
                const s = @min(sx, sy);
                if (s > 0 and s < 1.0) {
                    disp_w = @floor(iw * s);
                    disp_h = @floor(ih * s);
                }
            }
            c.igImage(
                @as(c.ImTextureID, tex),
                .{ .x = disp_w, .y = disp_h },
                .{ .x = 0, .y = 0 },
                .{ .x = 1, .y = 1 },
                .{ .x = 1, .y = 1, .z = 1, .w = 1 },
                .{ .x = 0.28, .y = 0.28, .z = 0.32, .w = 1 },
            );
            c.igEndChild();

            c.igEnd();

            // Keyboard shortcuts.
            if (c.igIsKeyDown_Nil(c.ImGuiKey_LeftCtrl) or c.igIsKeyDown_Nil(c.ImGuiKey_RightCtrl)) {
                if (c.igIsKeyPressed_Bool(c.ImGuiKey_S, false)) {
                    status = if (doc.save(allocator, path)) |_| .saved else |_| .save_failed;
                    status_ticks = 120;
                }
                if (c.igIsKeyPressed_Bool(c.ImGuiKey_Z, false)) doc.undo();
                if (c.igIsKeyPressed_Bool(c.ImGuiKey_Y, false)) doc.redo();
            }

            c.igRender();
            var fb_w: c_int = 0;
            var fb_h: c_int = 0;
            c.glfwGetFramebufferSize(win, &fb_w, &fb_h);
            c.glViewport(0, 0, fb_w, fb_h);
            if (theme == .light) {
                c.glClearColor(0.96, 0.96, 0.97, 1.0);
            } else {
                c.glClearColor(0.10, 0.10, 0.11, 1.0);
            }
            c.glClear(c.GL_COLOR_BUFFER_BIT);
            c.cImGui_ImplOpenGL3_RenderDrawData(c.igGetDrawData());
            c.glfwSwapBuffers(win);
            if (c.glfwGetKey(win, c.GLFW_KEY_ESCAPE) == c.GLFW_PRESS) break;
        }
    }
};

fn toolNameZ(t: Tool) [*:0]const u8 {
    return switch (t) {
        .crop => "crop",
        .arrow => "arrow",
        .rect => "rect",
        .pen => "pen",
        .text => "text",
        .blur => "blur",
        .step => "step",
    };
}
