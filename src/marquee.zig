const std = @import("std");
const app_io = @import("app_io");
const c = @cImport({
    @cInclude("GLES2/gl2.h");
    // Without this define cimgui.h falls back to C++ template typedefs
    // (ImPool<T>, ImVector<T>, ...) that translate-c cannot parse.
    @cDefine("CIMGUI_DEFINE_ENUMS_AND_STRUCTS", "1");
    @cInclude("cimgui.h");
});
const png = @import("png");
const watcher = @import("watcher");

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

pub const Marquee = struct {
    allocator: std.mem.Allocator,
    dir: []const u8,
    thumbnails: std.array_list.Managed(Thumbnail),
    watch: watcher.Watcher,

    pub const Thumbnail = struct {
        path: []u8,
        last_modified: i128,
        // GL texture id; 0 means not yet uploaded (or upload failed).
        texture: c_uint = 0,
        width: u32 = 0,
        height: u32 = 0,
        // Permanent failure after a complete PNG failed to decode. Incomplete
        // (still-writing) files are retried until IEND appears or this is set.
        broken: bool = false,
        // Last byte size we logged a permanent failure for (avoid spam).
        logged_fail_size: u64 = 0,
    };

    pub fn init(allocator: std.mem.Allocator, dir: []const u8) !Marquee {
        var thumbs = std.array_list.Managed(Thumbnail).init(allocator);
        // On any failure, free both the backing array and every path string
        // already appended.
        errdefer {
            for (thumbs.items) |t| freeThumb(allocator, t);
            thumbs.deinit();
        }
        // Pre-load existing PNGs in dir.
        const io = app_io.get();
        var d = try std.Io.Dir.openDirAbsolute(io, dir, .{ .iterate = true });
        defer d.close(io);
        var it = d.iterate();
        while (try it.next(io)) |entry| {
            if (entry.kind != .file) continue;
            if (!std.mem.endsWith(u8, entry.name, ".png")) continue;
            const p = try std.fs.path.join(allocator, &.{ dir, entry.name });
            thumbs.append(.{ .path = p, .last_modified = 0 }) catch |e| {
                allocator.free(p);
                return e;
            };
        }
        sortNewestFirst(&thumbs);
        const w = try watcher.Watcher.init(dir);
        return .{ .allocator = allocator, .dir = dir, .thumbnails = thumbs, .watch = w };
    }

    pub fn deinit(self: *Marquee) void {
        for (self.thumbnails.items) |t| freeThumb(self.allocator, t);
        self.thumbnails.deinit();
        self.watch.deinit();
    }

    pub fn poll(self: *Marquee) !void {
        while (try self.watch.tryRead()) |ev| {
            switch (ev) {
                // CREATE/MOVED_TO often fire before Spectacle finishes the write;
                // refresh adds the path and ensureTexture retries until complete.
                .created => try self.refresh(),
                .deleted => try self.refresh(),
                // MODIFY while writing: clear permanent-fail so a prior partial
                // read does not stick once the file grows.
                .modified => {
                    for (self.thumbnails.items) |*t| {
                        if (t.texture == 0) t.broken = false;
                    }
                },
            }
        }
    }

    // Release one entry's GL texture and path. Textures are deleted here, and
    // only here, so repeated refresh/deinit cannot double-free.
    fn freeThumb(allocator: std.mem.Allocator, t: Thumbnail) void {
        if (t.texture != 0) {
            var tex = t.texture;
            c.glDeleteTextures(1, &tex);
        }
        allocator.free(t.path);
    }

    fn refresh(self: *Marquee) !void {
        for (self.thumbnails.items) |t| freeThumb(self.allocator, t);
        self.thumbnails.clearRetainingCapacity();
        // If repopulation fails partway, free the paths appended so far and
        // leave the list empty rather than holding stale half-state.
        errdefer {
            for (self.thumbnails.items) |t| freeThumb(self.allocator, t);
            self.thumbnails.clearRetainingCapacity();
        }
        const io = app_io.get();
        var d = try std.Io.Dir.openDirAbsolute(io, self.dir, .{ .iterate = true });
        defer d.close(io);
        var it = d.iterate();
        while (try it.next(io)) |entry| {
            if (entry.kind != .file) continue;
            if (!std.mem.endsWith(u8, entry.name, ".png")) continue;
            const p = try std.fs.path.join(self.allocator, &.{ self.dir, entry.name });
            self.thumbnails.append(.{ .path = p, .last_modified = 0 }) catch |e| {
                self.allocator.free(p);
                return e;
            };
        }
        sortNewestFirst(&self.thumbnails);
    }

    fn sortNewestFirst(thumbs: *std.array_list.Managed(Thumbnail)) void {
        // Lexicographic reverse on basename works for our timestamped names
        // (YYYY-MM-DD_HH-MM-SS.png sorts chronologically).
        std.mem.sort(Thumbnail, thumbs.items, {}, struct {
            fn less(_: void, a: Thumbnail, b: Thumbnail) bool {
                const an = std.fs.path.basename(a.path);
                const bn = std.fs.path.basename(b.path);
                return std.mem.order(u8, an, bn) == .gt;
            }
        }.less);
    }

    // Lazily decode the PNG and upload it as a GL texture on first draw.
    // Incomplete files (Spectacle still writing) are skipped quietly and
    // retried on later frames; only complete-file failures stick as broken.
    fn ensureTexture(self: *Marquee, t: *Thumbnail) void {
        if (t.texture != 0 or t.broken) return;
        // Dual-monitor RGBA PNGs compress to several MB; allow a generous cap.
        // Absolute paths are accepted by cwd().readFileAlloc (Dir handle ignored).
        const bytes = std.Io.Dir.cwd().readFileAlloc(app_io.get(), t.path, self.allocator, .limited(256 * 1024 * 1024)) catch {
            // File may have been deleted mid-frame; refresh will drop it.
            return;
        };
        defer self.allocator.free(bytes);

        // Race: inotify CREATE often lands before the last IDAT/IEND is flushed.
        if (!png.looksComplete(bytes)) return;

        var w: u32 = 0;
        var h: u32 = 0;
        const px = png.decode(self.allocator, bytes, &w, &h) catch |e| {
            const sz: u64 = bytes.len;
            if (t.logged_fail_size != sz) {
                std.debug.print("zigit: marquee: cannot decode {s} ({d}B): {s}\n", .{ t.path, bytes.len, @errorName(e) });
                t.logged_fail_size = sz;
            }
            t.broken = true;
            return;
        };
        defer self.allocator.free(px);
        t.texture = uploadTexture(px, w, h);
        t.width = w;
        t.height = h;
    }

    /// Draw as a standalone floating window (legacy / simple mode).
    pub fn draw(self: *Marquee) void {
        c.igSetNextWindowPos(.{ .x = 10, .y = 10 }, c.ImGuiCond_FirstUseEver, .{ .x = 0, .y = 0 });
        c.igSetNextWindowSize(.{ .x = 420, .y = 200 }, c.ImGuiCond_FirstUseEver);
        _ = c.igBegin("ZigIt Captures", null, c.ImGuiWindowFlags_HorizontalScrollbar);
        self.drawContent();
        c.igEnd();
    }

    /// Draw the horizontal thumbnail strip into the current ImGui window/child.
    pub fn drawContent(self: *Marquee) void {
        if (self.thumbnails.items.len == 0) {
            // Centered empty state.
            var avail: c.ImVec2 = undefined;
            c.igGetContentRegionAvail(&avail);
            c.igDummy(.{ .x = 1, .y = @max(0, avail.y * 0.22) });
            c.igPushStyleColor_Vec4(c.ImGuiCol_Text, .{ .x = 0.93, .y = 0.30, .z = 0.28, .w = 1.0 });
            // Simple camera-ish glyph via text.
            const title: [*:0]const u8 = "No captures yet";
            var tsz: c.ImVec2 = undefined;
            c.igCalcTextSize(&tsz, title, null, false, -1.0);
            c.igSetCursorPosX(c.igGetCursorPosX() + @max(0, (avail.x - tsz.x) * 0.5));
            c.igText("%s", title);
            c.igPopStyleColor(1);
            c.igSpacing();
            const hint: [*:0]const u8 = "Press Print Screen or click Capture region";
            var hsz: c.ImVec2 = undefined;
            c.igCalcTextSize(&hsz, hint, null, false, -1.0);
            c.igSetCursorPosX(c.igGetCursorPosX() + @max(0, (avail.x - hsz.x) * 0.5));
            c.igPushStyleColor_Vec4(c.ImGuiCol_Text, .{ .x = 0.55, .y = 0.55, .z = 0.60, .w = 1.0 });
            c.igText("%s", hint);
            c.igPopStyleColor(1);
            return;
        }

        // Tight card chrome so thumbs fill the box; height sized so thumb +
        // filename fit without a vertical scrollbar (global WindowPadding is 20).
        const card_w: f32 = 200.0;
        const card_pad: f32 = 6.0;
        const thumb_max_w: f32 = card_w - card_pad * 2.0 - 2.0;
        const thumb_max_h: f32 = 152.0;
        // pad*2 + frame pad + thumb + item gap + filename line + a little slack
        const card_h: f32 = card_pad * 2.0 + 4.0 + thumb_max_h + 6.0 + 20.0 + 4.0; // ~192

        for (self.thumbnails.items, 0..) |*t, i| {
            if (i > 0) c.igSameLine(0.0, 12.0);

            // Unique child id per path.
            var id_buf: [32]u8 = undefined;
            const id_z = std.fmt.bufPrintZ(&id_buf, "##card{d}", .{i}) catch "##card";
            // Pull card fill from the active theme so light mode stays readable.
            const style = c.igGetStyle().*;
            // ImGuiCol_FrameBg == 7; index as usize for Zig 0.16 C array access.
            const frame_bg: c.ImVec4 = style.Colors[7];
            c.igPushStyleColor_Vec4(c.ImGuiCol_ChildBg, frame_bg);
            c.igPushStyleVar_Float(c.ImGuiStyleVar_ChildRounding, 10.0);
            c.igPushStyleVar_Vec2(c.ImGuiStyleVar_WindowPadding, .{ .x = card_pad, .y = card_pad });
            c.igPushStyleVar_Vec2(c.ImGuiStyleVar_FramePadding, .{ .x = 2.0, .y = 2.0 });
            c.igPushStyleVar_Vec2(c.ImGuiStyleVar_ItemSpacing, .{ .x = 4.0, .y = 6.0 });
            // NoScrollbar: content is laid out to fit; avoid per-card vertical bars.
            _ = c.igBeginChild_Str(
                id_z.ptr,
                .{ .x = card_w, .y = card_h },
                c.ImGuiChildFlags_Borders,
                c.ImGuiWindowFlags_NoScrollbar | c.ImGuiWindowFlags_NoScrollWithMouse,
            );

            self.ensureTexture(t);
            if (t.texture != 0 and t.width > 0 and t.height > 0) {
                const scale = @min(thumb_max_w / @as(f32, @floatFromInt(t.width)), thumb_max_h / @as(f32, @floatFromInt(t.height)));
                const size: c.ImVec2 = .{
                    .x = @floor(@as(f32, @floatFromInt(t.width)) * scale),
                    .y = @floor(@as(f32, @floatFromInt(t.height)) * scale),
                };
                // Center thumbnail using the card's content width (tight pad).
                const pad_x = @max(0, (thumb_max_w - size.x) * 0.5);
                if (pad_x > 0) c.igSetCursorPosX(c.igGetCursorPosX() + pad_x);

                var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
                const n = @min(t.path.len, buf.len - 1);
                @memcpy(buf[0..n], t.path[0..n]);
                buf[n] = 0;
                if (c.igImageButton(
                    buf[0..n :0].ptr,
                    @as(c.ImTextureID, t.texture),
                    size,
                    .{ .x = 0, .y = 0 },
                    .{ .x = 1, .y = 1 },
                    .{ .x = 0, .y = 0, .z = 0, .w = 0 },
                    .{ .x = 1, .y = 1, .z = 1, .w = 1 },
                )) {
                    _ = std.process.spawn(app_io.get(), .{
                        .argv = &.{ "zigit", "edit", t.path },
                        .stdin = .ignore,
                        .stdout = .ignore,
                        .stderr = .ignore,
                    }) catch |e| {
                        std.debug.print("zigit: failed to open editor for {s}: {s}\n", .{ t.path, @errorName(e) });
                    };
                }
                if (c.igIsItemHovered(0)) {
                    c.igSetTooltip("%s", buf[0..n :0].ptr);
                }
                // Right-click context menu.
                if (c.igBeginPopupContextItem(buf[0..n :0].ptr, 1)) {
                    if (c.igMenuItem_Bool("Open", null, false, true)) {
                        _ = std.process.spawn(app_io.get(), .{
                            .argv = &.{ "zigit", "edit", t.path },
                            .stdin = .ignore,
                            .stdout = .ignore,
                            .stderr = .ignore,
                        }) catch {};
                    }
                    if (c.igMenuItem_Bool("Copy path", null, false, true)) {
                        // Best-effort: wl-copy the path as text.
                        _ = std.process.spawn(app_io.get(), .{
                            .argv = &.{ "wl-copy", t.path },
                            .stdin = .ignore,
                            .stdout = .ignore,
                            .stderr = .ignore,
                        }) catch {};
                    }
                    if (c.igMenuItem_Bool("Delete", null, false, true)) {
                        std.Io.Dir.deleteFileAbsolute(app_io.get(), t.path) catch |e| {
                            std.debug.print("zigit: delete failed: {s}\n", .{@errorName(e)});
                        };
                    }
                    c.igEndPopup();
                }

                // "Latest" badge on the newest capture.
                if (i == 0) {
                    var rmin: c.ImVec2 = undefined;
                    c.igGetItemRectMin(&rmin);
                    const dl = c.igGetWindowDrawList();
                    const badge_min = c.ImVec2{ .x = rmin.x + 4, .y = rmin.y + 4 };
                    const badge_max = c.ImVec2{ .x = rmin.x + 48, .y = rmin.y + 20 };
                    c.ImDrawList_AddRectFilled(dl, badge_min, badge_max, c.igColorConvertFloat4ToU32(.{ .x = 0.86, .y = 0.24, .z = 0.22, .w = 0.92 }), 5.0, 0);
                    c.ImDrawList_AddText_Vec2(dl, .{ .x = badge_min.x + 7, .y = badge_min.y + 2 }, c.igColorConvertFloat4ToU32(.{ .x = 1, .y = 1, .z = 1, .w = 1 }), "NEW", null);
                }
            } else if (t.broken) {
                c.igTextDisabled("(broken)");
            } else {
                c.igTextDisabled("(loading…)");
            }

            // Truncate long basenames for the label under the thumb.
            const name = std.fs.path.basename(t.path);
            var nbuf: [48]u8 = undefined;
            const shown = truncateMiddle(name, nbuf[0..47]);
            nbuf[shown.len] = 0;
            c.igTextDisabled("%s", nbuf[0..shown.len :0].ptr);

            c.igEndChild();
            // Hover accent ring around the whole card.
            if (c.igIsItemHovered(0)) {
                var rmin: c.ImVec2 = undefined;
                var rmax: c.ImVec2 = undefined;
                c.igGetItemRectMin(&rmin);
                c.igGetItemRectMax(&rmax);
                c.ImDrawList_AddRect(
                    c.igGetWindowDrawList(),
                    rmin,
                    rmax,
                    c.igColorConvertFloat4ToU32(.{ .x = 0.93, .y = 0.32, .z = 0.28, .w = 0.85 }),
                    10.0,
                    0,
                    1.5,
                );
            }
            c.igPopStyleVar(4); // ItemSpacing, FramePadding, WindowPadding, ChildRounding
            c.igPopStyleColor(1);
        }
    }
};

/// Truncate `name` into `out` with a middle `...` when too long.
fn truncateMiddle(name: []const u8, out: []u8) []const u8 {
    const max = out.len;
    if (name.len <= max) {
        @memcpy(out[0..name.len], name);
        return out[0..name.len];
    }
    if (max < 7) {
        const n = @min(name.len, max);
        @memcpy(out[0..n], name[0..n]);
        return out[0..n];
    }
    const dots = "...";
    const keep = max - dots.len;
    const left = keep / 2;
    const right = keep - left;
    @memcpy(out[0..left], name[0..left]);
    @memcpy(out[left..][0..dots.len], dots);
    @memcpy(out[left + dots.len ..][0..right], name[name.len - right ..]);
    return out[0 .. left + dots.len + right];
}
