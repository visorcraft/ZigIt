const std = @import("std");
const app_io = @import("app_io");
const c = @cImport({
    // Without this define cimgui.h falls back to C++ template typedefs
    // (ImPool<T>, ImVector<T>, ...) that translate-c cannot parse.
    @cDefine("CIMGUI_DEFINE_ENUMS_AND_STRUCTS", "1");
    @cInclude("cimgui.h");
});
const config = @import("config");

/// Loaded once per ImGui context. Null when only the default (pixel) font is available.
pub var font_body: ?*c.ImFont = null;
pub var font_heading: ?*c.ImFont = null;
pub var font_title: ?*c.ImFont = null;

/// Prefer modern system UI fonts over ImGui's built-in Proggy pixel face.
/// Call after igCreateContext, before the first NewFrame.
pub fn loadFonts() void {
    const io = c.igGetIO();
    const atlas = io.*.Fonts orelse return;

    // Clear any default so we don't keep Proggy as a secondary face.
    c.ImFontAtlas_Clear(atlas);

    // Body / heading / title pairs. First match wins.
    const candidates = [_]struct { body: [*:0]const u8, heading: [*:0]const u8, title: [*:0]const u8 }{
        .{
            .body = "/usr/share/fonts/Adwaita/AdwaitaSans-Regular.ttf",
            .heading = "/usr/share/fonts/Adwaita/AdwaitaSans-Regular.ttf",
            .title = "/usr/share/fonts/Adwaita/AdwaitaSans-Regular.ttf",
        },
        .{
            .body = "/usr/share/fonts/TTF/OpenSans-Regular.ttf",
            .heading = "/usr/share/fonts/TTF/OpenSans-SemiBold.ttf",
            .title = "/usr/share/fonts/TTF/OpenSans-Bold.ttf",
        },
        .{
            .body = "/usr/share/fonts/TTF/DejaVuSans.ttf",
            .heading = "/usr/share/fonts/TTF/DejaVuSans-Bold.ttf",
            .title = "/usr/share/fonts/TTF/DejaVuSans-Bold.ttf",
        },
    };

    for (candidates) |pair| {
        if (!fileExists(pair.body)) continue;
        const body = c.ImFontAtlas_AddFontFromFileTTF(atlas, pair.body, 16.0, null, null);
        if (body == null) continue;
        font_body = body;

        if (fileExists(pair.heading)) {
            font_heading = c.ImFontAtlas_AddFontFromFileTTF(atlas, pair.heading, 15.0, null, null) orelse body;
        } else {
            font_heading = body;
        }
        if (fileExists(pair.title)) {
            font_title = c.ImFontAtlas_AddFontFromFileTTF(atlas, pair.title, 22.0, null, null) orelse body;
        } else {
            font_title = body;
        }
        // Rasterize at higher density for HiDPI; ImGui will scale down via DisplayFramebufferScale.
        atlas.*.FontBuilderFlags = 0;
        return;
    }

    // Last resort: default Proggy at a less-ugly size.
    font_body = c.ImFontAtlas_AddFontDefault(atlas, null);
    font_heading = font_body;
    font_title = font_body;
}

fn fileExists(path: [*:0]const u8) bool {
    const p = std.mem.span(path);
    std.Io.Dir.accessAbsolute(app_io.get(), p, .{}) catch return false;
    return true;
}

pub fn pushBody() void {
    if (font_body) |f| c.igPushFont(f);
}

pub fn popBody() void {
    if (font_body != null) c.igPopFont();
}

pub fn pushHeading() void {
    if (font_heading) |f| c.igPushFont(f);
}

pub fn popHeading() void {
    if (font_heading != null) c.igPopFont();
}

pub fn pushTitle() void {
    if (font_title) |f| c.igPushFont(f);
}

pub fn popTitle() void {
    if (font_title != null) c.igPopFont();
}

/// Section label with modern weight (no 90s SeparatorText chrome).
pub fn sectionHeader(label: [*:0]const u8) void {
    c.igSpacing();
    pushHeading();
    c.igPushStyleColor_Vec4(c.ImGuiCol_Text, col(0.72, 0.72, 0.78, 1.0));
    c.igText("%s", label);
    c.igPopStyleColor(1);
    popHeading();
    c.igPushStyleColor_Vec4(c.ImGuiCol_Separator, col(0.22, 0.22, 0.26, 1.0));
    c.igSeparator();
    c.igPopStyleColor(1);
    c.igSpacing();
}

/// Shared product chrome for daemon and editor windows.
pub fn apply(theme: config.Theme) void {
    const style = c.igGetStyle();
    style.*.WindowRounding = 12.0;
    style.*.ChildRounding = 10.0;
    style.*.FrameRounding = 8.0;
    style.*.PopupRounding = 10.0;
    style.*.ScrollbarRounding = 10.0;
    style.*.GrabRounding = 8.0;
    style.*.TabRounding = 8.0;
    style.*.WindowBorderSize = 0.0;
    style.*.FrameBorderSize = 0.0;
    style.*.PopupBorderSize = 1.0;
    style.*.ChildBorderSize = 1.0;
    style.*.WindowPadding = .{ .x = 20.0, .y = 16.0 };
    style.*.FramePadding = .{ .x = 12.0, .y = 8.0 };
    style.*.ItemSpacing = .{ .x = 12.0, .y = 10.0 };
    style.*.ItemInnerSpacing = .{ .x = 10.0, .y = 6.0 };
    style.*.IndentSpacing = 20.0;
    // Horizontal strip scrollbars (captures marquee, etc.) need a chunky grab.
    style.*.ScrollbarSize = 20.0;
    style.*.GrabMinSize = 12.0;
    style.*.WindowTitleAlign = .{ .x = 0.0, .y = 0.5 };
    style.*.ButtonTextAlign = .{ .x = 0.5, .y = 0.5 };
    style.*.CellPadding = .{ .x = 10.0, .y = 6.0 };
    // Slight letter-spacing feel via taller controls.
    style.*.TabBarBorderSize = 0.0;
    style.*.TabBarOverlineSize = 2.0;

    const io = c.igGetIO();
    // Real TTF is already sized; don't double-scale into blurry territory.
    io.*.FontGlobalScale = 1.0;
    io.*.IniFilename = null;

    switch (theme) {
        .dark => applyDark(style),
        .light => applyLight(style),
    }
}

fn col(r: f32, g: f32, b: f32, a: f32) c.ImVec4 {
    return .{ .x = r, .y = g, .z = b, .w = a };
}

fn applyDark(style: *c.ImGuiStyle) void {
    const bg = col(0.09, 0.09, 0.10, 1.0);
    const bg2 = col(0.13, 0.13, 0.15, 1.0);
    const bg3 = col(0.17, 0.17, 0.19, 1.0);
    const border = col(0.24, 0.24, 0.28, 1.0);
    const text = col(0.93, 0.93, 0.95, 1.0);
    const text_dim = col(0.52, 0.52, 0.58, 1.0);
    const accent = col(0.93, 0.32, 0.30, 1.0);
    const accent_hov = col(1.00, 0.42, 0.38, 1.0);
    const accent_act = col(0.78, 0.22, 0.20, 1.0);

    style.Colors[@as(usize, @intCast(c.ImGuiCol_Text))] = text;
    style.Colors[@as(usize, @intCast(c.ImGuiCol_TextDisabled))] = text_dim;
    style.Colors[@as(usize, @intCast(c.ImGuiCol_WindowBg))] = bg;
    style.Colors[@as(usize, @intCast(c.ImGuiCol_ChildBg))] = col(0.08, 0.08, 0.09, 1.0);
    style.Colors[@as(usize, @intCast(c.ImGuiCol_PopupBg))] = col(0.11, 0.11, 0.13, 0.98);
    style.Colors[@as(usize, @intCast(c.ImGuiCol_Border))] = border;
    style.Colors[@as(usize, @intCast(c.ImGuiCol_BorderShadow))] = col(0, 0, 0, 0);
    style.Colors[@as(usize, @intCast(c.ImGuiCol_FrameBg))] = bg2;
    style.Colors[@as(usize, @intCast(c.ImGuiCol_FrameBgHovered))] = bg3;
    style.Colors[@as(usize, @intCast(c.ImGuiCol_FrameBgActive))] = col(0.20, 0.20, 0.23, 1.0);
    style.Colors[@as(usize, @intCast(c.ImGuiCol_TitleBg))] = col(0.07, 0.07, 0.08, 1.0);
    style.Colors[@as(usize, @intCast(c.ImGuiCol_TitleBgActive))] = col(0.10, 0.10, 0.12, 1.0);
    style.Colors[@as(usize, @intCast(c.ImGuiCol_TitleBgCollapsed))] = col(0.07, 0.07, 0.08, 0.8);
    style.Colors[@as(usize, @intCast(c.ImGuiCol_MenuBarBg))] = col(0.10, 0.10, 0.11, 1.0);
    style.Colors[@as(usize, @intCast(c.ImGuiCol_ScrollbarBg))] = col(0.07, 0.07, 0.08, 1.0);
    style.Colors[@as(usize, @intCast(c.ImGuiCol_ScrollbarGrab))] = col(0.32, 0.32, 0.36, 1.0);
    style.Colors[@as(usize, @intCast(c.ImGuiCol_ScrollbarGrabHovered))] = col(0.42, 0.42, 0.48, 1.0);
    style.Colors[@as(usize, @intCast(c.ImGuiCol_ScrollbarGrabActive))] = accent;
    style.Colors[@as(usize, @intCast(c.ImGuiCol_CheckMark))] = accent;
    style.Colors[@as(usize, @intCast(c.ImGuiCol_SliderGrab))] = accent;
    style.Colors[@as(usize, @intCast(c.ImGuiCol_SliderGrabActive))] = accent_act;
    style.Colors[@as(usize, @intCast(c.ImGuiCol_Button))] = bg3;
    style.Colors[@as(usize, @intCast(c.ImGuiCol_ButtonHovered))] = col(0.26, 0.26, 0.30, 1.0);
    style.Colors[@as(usize, @intCast(c.ImGuiCol_ButtonActive))] = accent_act;
    style.Colors[@as(usize, @intCast(c.ImGuiCol_Header))] = bg3;
    style.Colors[@as(usize, @intCast(c.ImGuiCol_HeaderHovered))] = col(0.28, 0.20, 0.20, 1.0);
    style.Colors[@as(usize, @intCast(c.ImGuiCol_HeaderActive))] = accent_act;
    style.Colors[@as(usize, @intCast(c.ImGuiCol_Separator))] = border;
    style.Colors[@as(usize, @intCast(c.ImGuiCol_SeparatorHovered))] = accent_hov;
    style.Colors[@as(usize, @intCast(c.ImGuiCol_SeparatorActive))] = accent;
    style.Colors[@as(usize, @intCast(c.ImGuiCol_ResizeGrip))] = col(0.30, 0.30, 0.34, 0.4);
    style.Colors[@as(usize, @intCast(c.ImGuiCol_ResizeGripHovered))] = accent_hov;
    style.Colors[@as(usize, @intCast(c.ImGuiCol_ResizeGripActive))] = accent;
    style.Colors[@as(usize, @intCast(c.ImGuiCol_Tab))] = col(0.11, 0.11, 0.12, 1.0);
    style.Colors[@as(usize, @intCast(c.ImGuiCol_TabHovered))] = col(0.28, 0.18, 0.18, 1.0);
    style.Colors[@as(usize, @intCast(c.ImGuiCol_TabSelected))] = col(0.16, 0.16, 0.18, 1.0);
    style.Colors[@as(usize, @intCast(c.ImGuiCol_TabSelectedOverline))] = accent;
    style.Colors[@as(usize, @intCast(c.ImGuiCol_TabDimmed))] = bg;
    style.Colors[@as(usize, @intCast(c.ImGuiCol_TabDimmedSelected))] = bg2;
    style.Colors[@as(usize, @intCast(c.ImGuiCol_TableHeaderBg))] = bg2;
    style.Colors[@as(usize, @intCast(c.ImGuiCol_TableBorderStrong))] = border;
    style.Colors[@as(usize, @intCast(c.ImGuiCol_TableBorderLight))] = col(0.20, 0.20, 0.23, 1.0);
    style.Colors[@as(usize, @intCast(c.ImGuiCol_TableRowBg))] = col(0, 0, 0, 0);
    style.Colors[@as(usize, @intCast(c.ImGuiCol_TableRowBgAlt))] = col(1, 1, 1, 0.015);
    style.Colors[@as(usize, @intCast(c.ImGuiCol_TextSelectedBg))] = col(0.93, 0.32, 0.30, 0.30);
    style.Colors[@as(usize, @intCast(c.ImGuiCol_DragDropTarget))] = accent;
    style.Colors[@as(usize, @intCast(c.ImGuiCol_NavCursor))] = accent;
    style.Colors[@as(usize, @intCast(c.ImGuiCol_NavWindowingHighlight))] = col(1, 1, 1, 0.7);
    style.Colors[@as(usize, @intCast(c.ImGuiCol_NavWindowingDimBg))] = col(0, 0, 0, 0.4);
    style.Colors[@as(usize, @intCast(c.ImGuiCol_ModalWindowDimBg))] = col(0, 0, 0, 0.55);
    style.Colors[@as(usize, @intCast(c.ImGuiCol_PlotLines))] = accent;
    style.Colors[@as(usize, @intCast(c.ImGuiCol_PlotLinesHovered))] = accent_hov;
    style.Colors[@as(usize, @intCast(c.ImGuiCol_PlotHistogram))] = accent;
    style.Colors[@as(usize, @intCast(c.ImGuiCol_PlotHistogramHovered))] = accent_hov;
}

fn applyLight(style: *c.ImGuiStyle) void {
    const bg = col(0.97, 0.97, 0.98, 1.0);
    const bg2 = col(1.00, 1.00, 1.00, 1.0);
    const bg3 = col(0.91, 0.91, 0.93, 1.0);
    const border = col(0.82, 0.82, 0.86, 1.0);
    const text = col(0.14, 0.14, 0.16, 1.0);
    const text_dim = col(0.48, 0.48, 0.52, 1.0);
    const accent = col(0.86, 0.22, 0.20, 1.0);
    const accent_hov = col(0.95, 0.30, 0.28, 1.0);
    const accent_act = col(0.72, 0.16, 0.14, 1.0);

    style.Colors[@as(usize, @intCast(c.ImGuiCol_Text))] = text;
    style.Colors[@as(usize, @intCast(c.ImGuiCol_TextDisabled))] = text_dim;
    style.Colors[@as(usize, @intCast(c.ImGuiCol_WindowBg))] = bg;
    style.Colors[@as(usize, @intCast(c.ImGuiCol_ChildBg))] = bg2;
    style.Colors[@as(usize, @intCast(c.ImGuiCol_PopupBg))] = col(1, 1, 1, 0.98);
    style.Colors[@as(usize, @intCast(c.ImGuiCol_Border))] = border;
    style.Colors[@as(usize, @intCast(c.ImGuiCol_BorderShadow))] = col(0, 0, 0, 0);
    style.Colors[@as(usize, @intCast(c.ImGuiCol_FrameBg))] = bg2;
    style.Colors[@as(usize, @intCast(c.ImGuiCol_FrameBgHovered))] = bg3;
    style.Colors[@as(usize, @intCast(c.ImGuiCol_FrameBgActive))] = col(0.88, 0.88, 0.90, 1.0);
    style.Colors[@as(usize, @intCast(c.ImGuiCol_TitleBg))] = bg3;
    style.Colors[@as(usize, @intCast(c.ImGuiCol_TitleBgActive))] = col(0.90, 0.90, 0.92, 1.0);
    style.Colors[@as(usize, @intCast(c.ImGuiCol_TitleBgCollapsed))] = bg3;
    style.Colors[@as(usize, @intCast(c.ImGuiCol_MenuBarBg))] = bg3;
    style.Colors[@as(usize, @intCast(c.ImGuiCol_ScrollbarBg))] = col(0.95, 0.95, 0.96, 1.0);
    style.Colors[@as(usize, @intCast(c.ImGuiCol_ScrollbarGrab))] = col(0.72, 0.72, 0.76, 1.0);
    style.Colors[@as(usize, @intCast(c.ImGuiCol_ScrollbarGrabHovered))] = col(0.55, 0.55, 0.60, 1.0);
    style.Colors[@as(usize, @intCast(c.ImGuiCol_ScrollbarGrabActive))] = accent;
    style.Colors[@as(usize, @intCast(c.ImGuiCol_CheckMark))] = accent;
    style.Colors[@as(usize, @intCast(c.ImGuiCol_SliderGrab))] = accent;
    style.Colors[@as(usize, @intCast(c.ImGuiCol_SliderGrabActive))] = accent_act;
    style.Colors[@as(usize, @intCast(c.ImGuiCol_Button))] = bg3;
    style.Colors[@as(usize, @intCast(c.ImGuiCol_ButtonHovered))] = col(0.86, 0.86, 0.90, 1.0);
    style.Colors[@as(usize, @intCast(c.ImGuiCol_ButtonActive))] = accent_hov;
    style.Colors[@as(usize, @intCast(c.ImGuiCol_Header))] = bg3;
    style.Colors[@as(usize, @intCast(c.ImGuiCol_HeaderHovered))] = col(0.95, 0.88, 0.88, 1.0);
    style.Colors[@as(usize, @intCast(c.ImGuiCol_HeaderActive))] = col(0.95, 0.80, 0.80, 1.0);
    style.Colors[@as(usize, @intCast(c.ImGuiCol_Separator))] = border;
    style.Colors[@as(usize, @intCast(c.ImGuiCol_SeparatorHovered))] = accent_hov;
    style.Colors[@as(usize, @intCast(c.ImGuiCol_SeparatorActive))] = accent;
    style.Colors[@as(usize, @intCast(c.ImGuiCol_ResizeGrip))] = col(0.70, 0.70, 0.74, 0.4);
    style.Colors[@as(usize, @intCast(c.ImGuiCol_ResizeGripHovered))] = accent_hov;
    style.Colors[@as(usize, @intCast(c.ImGuiCol_ResizeGripActive))] = accent;
    style.Colors[@as(usize, @intCast(c.ImGuiCol_Tab))] = bg3;
    style.Colors[@as(usize, @intCast(c.ImGuiCol_TabHovered))] = col(0.95, 0.88, 0.88, 1.0);
    style.Colors[@as(usize, @intCast(c.ImGuiCol_TabSelected))] = bg2;
    style.Colors[@as(usize, @intCast(c.ImGuiCol_TabSelectedOverline))] = accent;
    style.Colors[@as(usize, @intCast(c.ImGuiCol_TabDimmed))] = bg;
    style.Colors[@as(usize, @intCast(c.ImGuiCol_TabDimmedSelected))] = bg2;
    style.Colors[@as(usize, @intCast(c.ImGuiCol_TableHeaderBg))] = bg3;
    style.Colors[@as(usize, @intCast(c.ImGuiCol_TableBorderStrong))] = border;
    style.Colors[@as(usize, @intCast(c.ImGuiCol_TableBorderLight))] = col(0.88, 0.88, 0.90, 1.0);
    style.Colors[@as(usize, @intCast(c.ImGuiCol_TableRowBg))] = col(0, 0, 0, 0);
    style.Colors[@as(usize, @intCast(c.ImGuiCol_TableRowBgAlt))] = col(0, 0, 0, 0.02);
    style.Colors[@as(usize, @intCast(c.ImGuiCol_TextSelectedBg))] = col(0.95, 0.30, 0.28, 0.22);
    style.Colors[@as(usize, @intCast(c.ImGuiCol_DragDropTarget))] = accent;
    style.Colors[@as(usize, @intCast(c.ImGuiCol_NavCursor))] = accent;
    style.Colors[@as(usize, @intCast(c.ImGuiCol_NavWindowingHighlight))] = col(0.2, 0.2, 0.2, 0.5);
    style.Colors[@as(usize, @intCast(c.ImGuiCol_NavWindowingDimBg))] = col(0, 0, 0, 0.2);
    style.Colors[@as(usize, @intCast(c.ImGuiCol_ModalWindowDimBg))] = col(0, 0, 0, 0.35);
    style.Colors[@as(usize, @intCast(c.ImGuiCol_PlotLines))] = accent;
    style.Colors[@as(usize, @intCast(c.ImGuiCol_PlotLinesHovered))] = accent_hov;
    style.Colors[@as(usize, @intCast(c.ImGuiCol_PlotHistogram))] = accent;
    style.Colors[@as(usize, @intCast(c.ImGuiCol_PlotHistogramHovered))] = accent_hov;
}

/// Pushes accent styling for a primary action button. Call popAccent after.
pub fn pushAccent() void {
    c.igPushStyleColor_Vec4(c.ImGuiCol_Button, col(0.86, 0.24, 0.22, 1.0));
    c.igPushStyleColor_Vec4(c.ImGuiCol_ButtonHovered, col(0.95, 0.34, 0.30, 1.0));
    c.igPushStyleColor_Vec4(c.ImGuiCol_ButtonActive, col(0.72, 0.16, 0.14, 1.0));
    c.igPushStyleColor_Vec4(c.ImGuiCol_Text, col(1.0, 1.0, 1.0, 1.0));
}

pub fn popAccent() void {
    c.igPopStyleColor(4);
}

/// Secondary (outline-ish) button on dark chrome.
pub fn pushGhost() void {
    c.igPushStyleColor_Vec4(c.ImGuiCol_Button, col(0.16, 0.16, 0.18, 1.0));
    c.igPushStyleColor_Vec4(c.ImGuiCol_ButtonHovered, col(0.22, 0.22, 0.26, 1.0));
    c.igPushStyleColor_Vec4(c.ImGuiCol_ButtonActive, col(0.28, 0.28, 0.32, 1.0));
}

pub fn popGhost() void {
    c.igPopStyleColor(3);
}
