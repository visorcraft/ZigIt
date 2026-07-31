const std = @import("std");
const app_io = @import("app_io");
const app_icon = @import("app_icon");
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
const clipboard = @import("clipboard");

const Tool = enum { crop, arrow, rect, pen, text, blur, step };

const ToolInfo = struct {
    tool: Tool,
    label: [:0]const u8,
    /// Short id used as the invisible button label (unique ImGui id).
    id: [:0]const u8,
    hint: [:0]const u8,
};

const tools = [_]ToolInfo{
    .{ .tool = .crop, .label = "Crop", .id = "##tool_crop", .hint = "Drag to crop" },
    .{ .tool = .arrow, .label = "Arrow", .id = "##tool_arrow", .hint = "Drag to draw an arrow" },
    .{ .tool = .rect, .label = "Rect", .id = "##tool_rect", .hint = "Drag a rectangle outline" },
    .{ .tool = .pen, .label = "Pen", .id = "##tool_pen", .hint = "Freehand pen" },
    .{ .tool = .text, .label = "Text", .id = "##tool_text", .hint = "Click to place text" },
    .{ .tool = .blur, .label = "Blur", .id = "##tool_blur", .hint = "Drag to pixelate/blur" },
    .{ .tool = .step, .label = "Step", .id = "##tool_step", .hint = "Numbered step marker" },
};

// Collapsed = icons only; expanded = icon + full label.
// Widths include the rail's own WindowPadding so buttons are never clipped.
const rail_pad: f32 = 12.0;
const rail_collapsed_w: f32 = 72.0;
const rail_expanded_w: f32 = 200.0;

// Default GLFW client size (matches a comfortable editor layout screenshot).
const default_win_w: c_int = 1093;
const default_win_h: c_int = 822;

/// Draw a simple geometric tool glyph inside `rect` (ImGui screen coords).
fn drawToolIcon(tool: Tool, rect_min: c.ImVec2, rect_max: c.ImVec2, col_u32: c_uint) void {
    const dl = c.igGetWindowDrawList();
    // Less padding → larger, more readable glyphs in the rail buttons.
    const pad: f32 = 6.0;
    const x0 = rect_min.x + pad;
    const y0 = rect_min.y + pad;
    const x1 = rect_max.x - pad;
    const y1 = rect_max.y - pad;
    const cx = (x0 + x1) * 0.5;
    const cy = (y0 + y1) * 0.5;
    switch (tool) {
        .crop => {
            // Two corner brackets.
            const arm = (x1 - x0) * 0.35;
            c.ImDrawList_AddLine(dl, .{ .x = x0, .y = y0 + arm }, .{ .x = x0, .y = y0 }, col_u32, 2.0);
            c.ImDrawList_AddLine(dl, .{ .x = x0, .y = y0 }, .{ .x = x0 + arm, .y = y0 }, col_u32, 2.0);
            c.ImDrawList_AddLine(dl, .{ .x = x1 - arm, .y = y1 }, .{ .x = x1, .y = y1 }, col_u32, 2.0);
            c.ImDrawList_AddLine(dl, .{ .x = x1, .y = y1 }, .{ .x = x1, .y = y1 - arm }, col_u32, 2.0);
        },
        .arrow => {
            c.ImDrawList_AddLine(dl, .{ .x = x0, .y = y1 }, .{ .x = x1, .y = y0 }, col_u32, 2.0);
            c.ImDrawList_AddLine(dl, .{ .x = x1, .y = y0 }, .{ .x = x1 - 6, .y = y0 + 2 }, col_u32, 2.0);
            c.ImDrawList_AddLine(dl, .{ .x = x1, .y = y0 }, .{ .x = x1 - 2, .y = y0 + 6 }, col_u32, 2.0);
        },
        .rect => {
            c.ImDrawList_AddRect(dl, .{ .x = x0, .y = y0 }, .{ .x = x1, .y = y1 }, col_u32, 0, 0, 2.0);
        },
        .pen => {
            // S-curve stroke + tip.
            c.ImDrawList_AddBezierCubic(
                dl,
                .{ .x = x0, .y = y1 - 2 },
                .{ .x = x0 + 4, .y = y0 + 2 },
                .{ .x = x1 - 4, .y = y1 - 2 },
                .{ .x = x1, .y = y0 + 2 },
                col_u32,
                2.0,
                0,
            );
            c.ImDrawList_AddTriangleFilled(
                dl,
                .{ .x = x1, .y = y0 },
                .{ .x = x1 - 5, .y = y0 + 2 },
                .{ .x = x1 - 2, .y = y0 + 5 },
                col_u32,
            );
        },
        .text => {
            // Capital "A".
            c.ImDrawList_AddLine(dl, .{ .x = cx, .y = y0 }, .{ .x = x0 + 2, .y = y1 }, col_u32, 2.0);
            c.ImDrawList_AddLine(dl, .{ .x = cx, .y = y0 }, .{ .x = x1 - 2, .y = y1 }, col_u32, 2.0);
            c.ImDrawList_AddLine(dl, .{ .x = cx - 4, .y = cy + 2 }, .{ .x = cx + 4, .y = cy + 2 }, col_u32, 2.0);
        },
        .blur => {
            // Grid of soft squares (pixelate).
            const step = (x1 - x0) / 3.0;
            var row: i32 = 0;
            while (row < 3) : (row += 1) {
                var col: i32 = 0;
                while (col < 3) : (col += 1) {
                    const rx = x0 + @as(f32, @floatFromInt(col)) * step + 1;
                    const ry = y0 + @as(f32, @floatFromInt(row)) * step + 1;
                    c.ImDrawList_AddRectFilled(
                        dl,
                        .{ .x = rx, .y = ry },
                        .{ .x = rx + step - 2, .y = ry + step - 2 },
                        col_u32,
                        0,
                        0,
                    );
                }
            }
        },
        .step => {
            c.ImDrawList_AddCircleFilled(dl, .{ .x = cx, .y = cy }, (x1 - x0) * 0.4, col_u32, 16);
            // Light numeral "1" as a vertical bar.
            const ink = c.igColorConvertFloat4ToU32(.{ .x = 1, .y = 1, .z = 1, .w = 1 });
            c.ImDrawList_AddLine(dl, .{ .x = cx, .y = cy - 5 }, .{ .x = cx, .y = cy + 5 }, ink, 2.0);
            c.ImDrawList_AddLine(dl, .{ .x = cx - 2, .y = cy - 3 }, .{ .x = cx, .y = cy - 5 }, ink, 2.0);
        },
    }
}

fn toolIconColor(selected: bool) c_uint {
    if (selected) {
        return c.igColorConvertFloat4ToU32(.{ .x = 1, .y = 1, .z = 1, .w = 1 });
    }
    return c.igColorConvertFloat4ToU32(.{ .x = 0.85, .y = 0.85, .z = 0.88, .w = 1 });
}

fn uploadTexture(rgba: []const u8, w: u32, h: u32) c_uint {
    var tex: c_uint = 0;
    c.glGenTextures(1, &tex);
    c.glBindTexture(c.GL_TEXTURE_2D, tex);
    // NEAREST minify keeps thin strokes from looking dashed when a large
    // capture is fitted into the editor window.
    c.glTexParameteri(c.GL_TEXTURE_2D, c.GL_TEXTURE_MIN_FILTER, c.GL_NEAREST);
    c.glTexParameteri(c.GL_TEXTURE_2D, c.GL_TEXTURE_MAG_FILTER, c.GL_NEAREST);
    // GL_RGBA8 lives in gl3.h; GLES2's gl2.h only guarantees GL_RGBA, which is
    // also accepted as the internal format here.
    c.glTexImage2D(c.GL_TEXTURE_2D, 0, c.GL_RGBA, @intCast(w), @intCast(h), 0, c.GL_RGBA, c.GL_UNSIGNED_BYTE, rgba.ptr);
    return tex;
}

/// Stroke width in image pixels so annotations stay solid when the preview
/// is downscaled (dual-monitor captures are often 4–8× the window width).
fn strokeThickness(img_w: u32, img_h: u32) u8 {
    const m = @max(img_w, img_h);
    // ~1px on-screen at ~1200px display width for an m-wide image.
    const t = @max(@as(u32, 3), m / 500);
    return @intCast(@min(t, 24));
}

fn colorFromF32(rgba: [4]f32) editor.Color {
    return .{
        .r = @intFromFloat(std.math.clamp(rgba[0] * 255.0, 0, 255)),
        .g = @intFromFloat(std.math.clamp(rgba[1] * 255.0, 0, 255)),
        .b = @intFromFloat(std.math.clamp(rgba[2] * 255.0, 0, 255)),
        .a = @intFromFloat(std.math.clamp(rgba[3] * 255.0, 0, 255)),
    };
}

fn normalizeRect(a: editor.Point, b: editor.Point) editor.Rect {
    const x0 = @min(a.x, b.x);
    const y0 = @min(a.y, b.y);
    const x1 = @max(a.x, b.x);
    const y1 = @max(a.y, b.y);
    const w: u32 = @intCast(@max(1, x1 - x0));
    const h: u32 = @intCast(@max(1, y1 - y0));
    return .{ .x = x0, .y = y0, .w = w, .h = h };
}

/// Map screen mouse position into image pixel coordinates for the displayed image rect.
fn screenToImage(mouse: c.ImVec2, img_min: c.ImVec2, disp_w: f32, disp_h: f32, img_w: u32, img_h: u32) ?editor.Point {
    if (disp_w <= 0 or disp_h <= 0 or img_w == 0 or img_h == 0) return null;
    const lx = mouse.x - img_min.x;
    const ly = mouse.y - img_min.y;
    if (lx < 0 or ly < 0 or lx > disp_w or ly > disp_h) return null;
    const ix: i32 = @intFromFloat(std.math.clamp(lx / disp_w * @as(f32, @floatFromInt(img_w)), 0, @as(f32, @floatFromInt(img_w - 1))));
    const iy: i32 = @intFromFloat(std.math.clamp(ly / disp_h * @as(f32, @floatFromInt(img_h)), 0, @as(f32, @floatFromInt(img_h - 1))));
    return .{ .x = ix, .y = iy };
}

fn refreshPreview(
    allocator: std.mem.Allocator,
    doc: *editor.Document,
    tex: *c_uint,
    tex_w: *u32,
    tex_h: *u32,
) void {
    const img = doc.apply(allocator) catch |e| {
        std.debug.print("zigit: editor preview failed: {s}\n", .{@errorName(e)});
        return;
    };
    defer allocator.free(img.pixels);
    if (tex.* != 0) {
        var old = tex.*;
        c.glDeleteTextures(1, &old);
    }
    tex.* = uploadTexture(img.pixels, img.width, img.height);
    tex_w.* = img.width;
    tex_h.* = img.height;
}

pub const EditorWindow = struct {
    pub fn run(allocator: std.mem.Allocator, path: []const u8) !void {
        // Dual-monitor PNGs can exceed 32MB compressed; match marquee cap.
        const bytes = try std.Io.Dir.cwd().readFileAlloc(app_io.get(), path, allocator, .limited(256 * 1024 * 1024));
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

        // Fixed comfortable default; image scales inside the canvas.
        app_icon.installUserChrome(allocator);
        if (c.glfwInit() == 0) return error.GlfwInitFailed;
        defer c.glfwTerminate();
        c.glfwWindowHint(c.GLFW_CLIENT_API, c.GLFW_OPENGL_ES_API);
        c.glfwWindowHint(c.GLFW_CONTEXT_VERSION_MAJOR, 3);
        c.glfwWindowHint(c.GLFW_CONTEXT_VERSION_MINOR, 0);
        app_icon.applyWindowHints(c);
        const win = c.glfwCreateWindow(default_win_w, default_win_h, "ZigIt Editor", null, null);
        if (win == null) return error.WindowFailed;
        defer c.glfwDestroyWindow(win);
        // Keep the tools rail usable if the user shrinks the window.
        c.glfwSetWindowSizeLimits(win, 900, 640, c.GLFW_DONT_CARE, c.GLFW_DONT_CARE);
        app_icon.setWindowIcon(c, win);
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

        var tex: c_uint = uploadTexture(doc.base.pixels, w, h);
        defer {
            if (tex != 0) c.glDeleteTextures(1, &tex);
        }
        var tex_w: u32 = w;
        var tex_h: u32 = h;

        var current_tool: Tool = .arrow;
        var color = default_color;
        var status: enum { idle, saved, save_failed, copied, copy_failed } = .idle;
        var status_ticks: u32 = 0;

        var drag_active = false;
        var drag_start: editor.Point = .{ .x = 0, .y = 0 };
        var drag_cur: editor.Point = .{ .x = 0, .y = 0 };
        var pen_points: std.array_list.Managed(editor.Point) = .init(allocator);
        defer pen_points.deinit();
        var step_n: u32 = 1;

        // Text placement: click opens modal; Enter commits, Esc cancels.
        var text_editing = false;
        var text_pos: editor.Point = .{ .x = 0, .y = 0 };
        var text_buf: [256]u8 = undefined;
        @memset(&text_buf, 0);
        var text_focus_request = false;
        // Start expanded so labels are fully visible; user can collapse to icons.
        var tools_expanded = true;

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
                    if (c.igMenuItem_Bool("Copy path", null, false, true)) {
                        status = if (clipboard.copyText(allocator, path)) |_| .copied else |_| .copy_failed;
                        status_ticks = 120;
                    }
                    if (c.igMenuItem_Bool("Copy image", "Ctrl+C", false, true)) {
                        status = if (copyAnnotatedImage(allocator, &doc)) |_| .copied else |_| .copy_failed;
                        status_ticks = 120;
                    }
                    if (c.igMenuItem_Bool("Close", "Esc", false, !text_editing)) {
                        c.glfwSetWindowShouldClose(win, c.GLFW_TRUE);
                    }
                    c.igEndMenu();
                }
                if (c.igBeginMenu("Edit", true)) {
                    if (c.igMenuItem_Bool("Undo", "Ctrl+Z", false, doc.ops.items.len > 0)) {
                        doc.undo();
                        refreshPreview(allocator, &doc, &tex, &tex_w, &tex_h);
                    }
                    if (c.igMenuItem_Bool("Redo", "Ctrl+Y", false, doc.redo_stack.items.len > 0)) {
                        doc.redo();
                        refreshPreview(allocator, &doc, &tex, &tex_w, &tex_h);
                    }
                    c.igEndMenu();
                }
                c.igEndMenuBar();
            }

            // ── Left tool rail (icon + label; collapse to icons only) ─
            // Global theme WindowPadding is 20px — far too wide for a rail.
            // Use a tighter pad so full button chrome stays inside the child.
            const rail_w: f32 = if (tools_expanded) rail_expanded_w else rail_collapsed_w;
            c.igPushStyleVar_Vec2(c.ImGuiStyleVar_WindowPadding, .{ .x = rail_pad, .y = rail_pad });
            c.igPushStyleVar_Vec2(c.ImGuiStyleVar_ItemSpacing, .{ .x = 8.0, .y = 8.0 });
            c.igPushStyleVar_Vec2(c.ImGuiStyleVar_FramePadding, .{ .x = 12.0, .y = 10.0 });
            _ = c.igBeginChild_Str("##tools", .{ .x = rail_w, .y = 0 }, c.ImGuiChildFlags_Borders, 0);

            // Size buttons to the *actual* content width so rounded frames
            // are never clipped by the child (was: rail_w - 12 > avail).
            var rail_avail: c.ImVec2 = undefined;
            c.igGetContentRegionAvail(&rail_avail);
            const btn_w: f32 = @max(40.0, rail_avail.x);
            const btn_h: f32 = if (tools_expanded) 44.0 else 48.0;
            const icon_slot: f32 = if (tools_expanded) 40.0 else btn_w;

            // Expand / collapse toggle.
            const toggle_label: [*:0]const u8 = if (tools_expanded) "<<##rail_toggle" else ">>##rail_toggle";
            if (c.igButton(toggle_label, .{ .x = btn_w, .y = 30 })) {
                tools_expanded = !tools_expanded;
            }
            if (c.igIsItemHovered(0)) {
                const tip: [*:0]const u8 = if (tools_expanded) "Collapse tools" else "Expand tools (show names)";
                c.igSetTooltip("%s", tip);
            }
            c.igSpacing();
            if (tools_expanded) {
                theme_mod.pushHeading();
                c.igText("Tools");
                theme_mod.popHeading();
                c.igSpacing();
            }

            for (tools) |ti| {
                const selected = current_tool == ti.tool;
                if (selected) theme_mod.pushAccent() else theme_mod.pushGhost();
                // Invisible-id button; we paint icon (+ optional label) ourselves.
                const pressed = c.igButton(ti.id.ptr, .{ .x = btn_w, .y = btn_h });
                var rmin: c.ImVec2 = undefined;
                var rmax: c.ImVec2 = undefined;
                c.igGetItemRectMin(&rmin);
                c.igGetItemRectMax(&rmax);
                if (selected) theme_mod.popAccent() else theme_mod.popGhost();

                if (tools_expanded) {
                    // Icon on the left, label to the right (full width reserved).
                    const icon_max = c.ImVec2{ .x = rmin.x + icon_slot, .y = rmax.y };
                    drawToolIcon(ti.tool, rmin, icon_max, toolIconColor(selected));
                    const dl = c.igGetWindowDrawList();
                    const tcol = toolIconColor(selected);
                    c.ImDrawList_AddText_Vec2(
                        dl,
                        .{ .x = rmin.x + icon_slot + 6, .y = rmin.y + (btn_h - c.igGetTextLineHeight()) * 0.5 },
                        tcol,
                        ti.label.ptr,
                        null,
                    );
                } else {
                    drawToolIcon(ti.tool, rmin, rmax, toolIconColor(selected));
                }

                if (pressed) {
                    current_tool = ti.tool;
                    drag_active = false;
                    pen_points.clearRetainingCapacity();
                }
                if (c.igIsItemHovered(0)) {
                    c.igSetTooltip("%s — %s", ti.label.ptr, ti.hint.ptr);
                }
            }

            c.igSpacing();
            c.igSeparator();
            c.igSpacing();
            if (tools_expanded) c.igText("Color");
            _ = c.igColorEdit4("##ann_color", &color, c.ImGuiColorEditFlags_NoInputs | c.ImGuiColorEditFlags_NoLabel | c.ImGuiColorEditFlags_AlphaBar);
            c.igSpacing();
            if (tools_expanded) {
                if (c.igButton("Undo", .{ .x = btn_w, .y = 34 })) {
                    doc.undo();
                    refreshPreview(allocator, &doc, &tex, &tex_w, &tex_h);
                }
                if (c.igButton("Redo", .{ .x = btn_w, .y = 34 })) {
                    doc.redo();
                    refreshPreview(allocator, &doc, &tex, &tex_w, &tex_h);
                }
                c.igSpacing();
                theme_mod.pushAccent();
                if (c.igButton("Save", .{ .x = btn_w, .y = 38 })) {
                    status = if (doc.save(allocator, path)) |_| .saved else |_| .save_failed;
                    status_ticks = 120;
                }
                theme_mod.popAccent();
            } else {
                // Compact action buttons (still roomy).
                if (c.igButton("Z##undo", .{ .x = btn_w, .y = 34 })) {
                    doc.undo();
                    refreshPreview(allocator, &doc, &tex, &tex_w, &tex_h);
                }
                if (c.igIsItemHovered(0)) c.igSetTooltip("Undo (Ctrl+Z)");
                if (c.igButton("Y##redo", .{ .x = btn_w, .y = 34 })) {
                    doc.redo();
                    refreshPreview(allocator, &doc, &tex, &tex_w, &tex_h);
                }
                if (c.igIsItemHovered(0)) c.igSetTooltip("Redo (Ctrl+Y)");
                c.igSpacing();
                theme_mod.pushAccent();
                if (c.igButton("S##save", .{ .x = btn_w, .y = 38 })) {
                    status = if (doc.save(allocator, path)) |_| .saved else |_| .save_failed;
                    status_ticks = 120;
                }
                theme_mod.popAccent();
                if (c.igIsItemHovered(0)) c.igSetTooltip("Save (Ctrl+S)");
            }
            c.igEndChild();
            c.igPopStyleVar(3);

            c.igSameLine(0.0, 10.0);

            // ── Canvas ──────────────────────────────────────────────
            _ = c.igBeginChild_Str("##canvas", .{ .x = 0, .y = 0 }, c.ImGuiChildFlags_Borders, c.ImGuiWindowFlags_HorizontalScrollbar);
            // Header line: path + dimensions + active tool.
            c.igTextDisabled("%s", path_z.ptr);
            c.igSameLine(0.0, 12.0);
            c.igText("%dx%d", tex_w, tex_h);
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
                    .copied => {
                        c.igPushStyleColor_Vec4(c.ImGuiCol_Text, .{ .x = 0.40, .y = 0.85, .z = 0.45, .w = 1.0 });
                        c.igText("Copied");
                        c.igPopStyleColor(1);
                    },
                    .copy_failed => {
                        c.igPushStyleColor_Vec4(c.ImGuiCol_Text, .{ .x = 1.0, .y = 0.35, .z = 0.30, .w = 1.0 });
                        c.igText("Copy failed");
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
            const iw: f32 = @floatFromInt(tex_w);
            const ih: f32 = @floatFromInt(tex_h);
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

            // Image interaction: map mouse → image pixels and commit ops.
            var img_min: c.ImVec2 = undefined;
            var img_max: c.ImVec2 = undefined;
            c.igGetItemRectMin(&img_min);
            c.igGetItemRectMax(&img_max);
            const hovered = c.igIsItemHovered(0);
            const mouse = io.*.MousePos;
            const lmb_down = c.igIsMouseDown_Nil(c.ImGuiMouseButton_Left);
            const lmb_clicked = c.igIsMouseClicked_Bool(c.ImGuiMouseButton_Left, false);
            const lmb_released = c.igIsMouseReleased_Nil(c.ImGuiMouseButton_Left);

            if (hovered and !text_editing) {
                if (screenToImage(mouse, img_min, disp_w, disp_h, tex_w, tex_h)) |pt| {
                    const col = colorFromF32(color);
                    switch (current_tool) {
                        .text => {
                            if (lmb_clicked) {
                                text_editing = true;
                                text_pos = pt;
                                @memset(&text_buf, 0);
                                text_focus_request = true;
                            }
                        },
                        .step => {
                            if (lmb_clicked) {
                                doc.push(.{ .step = .{
                                    .pos = pt,
                                    .number = step_n,
                                    .color = col,
                                } }) catch {};
                                step_n += 1;
                                refreshPreview(allocator, &doc, &tex, &tex_w, &tex_h);
                            }
                        },
                        .pen => {
                            if (lmb_clicked) {
                                drag_active = true;
                                pen_points.clearRetainingCapacity();
                                pen_points.append(pt) catch {};
                                drag_start = pt;
                                drag_cur = pt;
                            } else if (drag_active and lmb_down) {
                                // Sample when the cursor moves at least ~1 image pixel.
                                const last = if (pen_points.items.len > 0) pen_points.items[pen_points.items.len - 1] else pt;
                                if (@abs(pt.x - last.x) + @abs(pt.y - last.y) >= 1) {
                                    pen_points.append(pt) catch {};
                                }
                                drag_cur = pt;
                            }
                        },
                        .arrow, .rect, .crop, .blur => {
                            if (lmb_clicked) {
                                drag_active = true;
                                drag_start = pt;
                                drag_cur = pt;
                            } else if (drag_active and lmb_down) {
                                drag_cur = pt;
                            }
                        },
                    }
                }
            }

            if (drag_active and lmb_released) {
                const col = colorFromF32(color);
                const start = drag_start;
                const end = drag_cur;
                const thick = strokeThickness(tex_w, tex_h);
                drag_active = false;
                switch (current_tool) {
                    .arrow => {
                        if (start.x != end.x or start.y != end.y) {
                            doc.push(.{ .arrow = .{
                                .from = start,
                                .to = end,
                                .thickness = thick,
                                .color = col,
                            } }) catch {};
                            refreshPreview(allocator, &doc, &tex, &tex_w, &tex_h);
                        }
                    },
                    .rect => {
                        const r = normalizeRect(start, end);
                        if (r.w > 1 and r.h > 1) {
                            doc.push(.{ .rect = .{
                                .rect = r,
                                .thickness = thick,
                                .color = col,
                            } }) catch {};
                            refreshPreview(allocator, &doc, &tex, &tex_w, &tex_h);
                        }
                    },
                    .crop => {
                        const r = normalizeRect(start, end);
                        if (r.w > 1 and r.h > 1) {
                            doc.push(.{ .crop = r }) catch {};
                            refreshPreview(allocator, &doc, &tex, &tex_w, &tex_h);
                        }
                    },
                    .blur => {
                        const r = normalizeRect(start, end);
                        if (r.w > 1 and r.h > 1) {
                            doc.push(.{ .blur = .{ .rect = r, .radius = 8 } }) catch {};
                            refreshPreview(allocator, &doc, &tex, &tex_w, &tex_h);
                        }
                    },
                    .pen => {
                        if (pen_points.items.len >= 2) {
                            const pts = pen_points.toOwnedSlice() catch null;
                            if (pts) |owned| {
                                doc.push(.{ .pen = .{
                                    .points = owned,
                                    .thickness = thick,
                                    .color = col,
                                } }) catch {
                                    allocator.free(owned);
                                };
                                refreshPreview(allocator, &doc, &tex, &tex_w, &tex_h);
                            }
                        } else {
                            pen_points.clearRetainingCapacity();
                        }
                    },
                    .text, .step => {},
                }
            }

            // Live rubber-band overlay while dragging.
            if (drag_active) {
                const dl = c.igGetWindowDrawList();
                const scale_x = if (tex_w > 0) disp_w / @as(f32, @floatFromInt(tex_w)) else 1;
                const scale_y = if (tex_h > 0) disp_h / @as(f32, @floatFromInt(tex_h)) else 1;
                const toScreen = struct {
                    fn go(p: editor.Point, min: c.ImVec2, sx: f32, sy: f32) c.ImVec2 {
                        return .{
                            .x = min.x + @as(f32, @floatFromInt(p.x)) * sx,
                            .y = min.y + @as(f32, @floatFromInt(p.y)) * sy,
                        };
                    }
                }.go;
                const col_u32 = c.igColorConvertFloat4ToU32(.{
                    .x = color[0],
                    .y = color[1],
                    .z = color[2],
                    .w = 0.9,
                });
                switch (current_tool) {
                    .arrow, .pen => {
                        if (current_tool == .pen and pen_points.items.len >= 2) {
                            var i: usize = 0;
                            while (i + 1 < pen_points.items.len) : (i += 1) {
                                const a = toScreen(pen_points.items[i], img_min, scale_x, scale_y);
                                const b = toScreen(pen_points.items[i + 1], img_min, scale_x, scale_y);
                                c.ImDrawList_AddLine(dl, a, b, col_u32, 2.0);
                            }
                        } else {
                            const a = toScreen(drag_start, img_min, scale_x, scale_y);
                            const b = toScreen(drag_cur, img_min, scale_x, scale_y);
                            c.ImDrawList_AddLine(dl, a, b, col_u32, 2.0);
                        }
                    },
                    .rect, .crop, .blur => {
                        const r = normalizeRect(drag_start, drag_cur);
                        const a = toScreen(.{ .x = r.x, .y = r.y }, img_min, scale_x, scale_y);
                        const b = toScreen(.{
                            .x = r.x + @as(i32, @intCast(r.w)),
                            .y = r.y + @as(i32, @intCast(r.h)),
                        }, img_min, scale_x, scale_y);
                        c.ImDrawList_AddRect(dl, a, b, col_u32, 0, 0, 2.0);
                    },
                    .text, .step => {},
                }
            }

            c.igEndChild();

            c.igEnd();

            // Text entry modal.
            if (text_editing) {
                c.igOpenPopup_Str("##text_entry", 0);
            }
            if (c.igBeginPopupModal("##text_entry", null, c.ImGuiWindowFlags_AlwaysAutoResize)) {
                c.igText("Enter text (Enter to place, Esc to cancel)");
                if (text_focus_request) {
                    c.igSetKeyboardFocusHere(0);
                    text_focus_request = false;
                }
                const enter = c.igInputText(
                    "##text_input",
                    &text_buf,
                    text_buf.len,
                    c.ImGuiInputTextFlags_EnterReturnsTrue,
                    null,
                    null,
                );
                if (enter or c.igButton("Place", .{ .x = 100, .y = 0 })) {
                    const len = std.mem.len(@as([*:0]const u8, @ptrCast(&text_buf)));
                    if (len > 0) {
                        const owned = allocator.dupe(u8, text_buf[0..len]) catch null;
                        if (owned) |s| {
                            doc.push(.{ .text = .{
                                .pos = text_pos,
                                .content = s,
                                .size = 16,
                                .color = colorFromF32(color),
                            } }) catch {
                                allocator.free(s);
                            };
                            refreshPreview(allocator, &doc, &tex, &tex_w, &tex_h);
                        }
                    }
                    text_editing = false;
                    c.igCloseCurrentPopup();
                }
                c.igSameLine(0.0, 8.0);
                if (c.igButton("Cancel", .{ .x = 100, .y = 0 }) or c.igIsKeyPressed_Bool(c.ImGuiKey_Escape, false)) {
                    text_editing = false;
                    c.igCloseCurrentPopup();
                }
                c.igEndPopup();
            }

            // Keyboard shortcuts (skip while typing text).
            if (!text_editing) {
                if (c.igIsKeyDown_Nil(c.ImGuiKey_LeftCtrl) or c.igIsKeyDown_Nil(c.ImGuiKey_RightCtrl)) {
                    if (c.igIsKeyPressed_Bool(c.ImGuiKey_S, false)) {
                        status = if (doc.save(allocator, path)) |_| .saved else |_| .save_failed;
                        status_ticks = 120;
                    }
                    if (c.igIsKeyPressed_Bool(c.ImGuiKey_C, false)) {
                        status = if (copyAnnotatedImage(allocator, &doc)) |_| .copied else |_| .copy_failed;
                        status_ticks = 120;
                    }
                    if (c.igIsKeyPressed_Bool(c.ImGuiKey_Z, false)) {
                        doc.undo();
                        refreshPreview(allocator, &doc, &tex, &tex_w, &tex_h);
                    }
                    if (c.igIsKeyPressed_Bool(c.ImGuiKey_Y, false)) {
                        doc.redo();
                        refreshPreview(allocator, &doc, &tex, &tex_w, &tex_h);
                    }
                }
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
            if (!text_editing and c.glfwGetKey(win, c.GLFW_KEY_ESCAPE) == c.GLFW_PRESS) break;
        }
    }
};

fn copyAnnotatedImage(allocator: std.mem.Allocator, doc: *editor.Document) !void {
    const img = try doc.apply(allocator);
    defer allocator.free(img.pixels);
    const bytes = try png.encode(allocator, img.pixels, img.width, img.height);
    defer allocator.free(bytes);
    try clipboard.copyPNG(allocator, bytes);
}

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
