const std = @import("std");
const app_io = @import("app_io");
// cimgui bindings, translated at build time (Zig 0.17 has no @cImport).
// See src/ctypes/gui.h.
const c = @import("c_gui");

pub const Level = enum { info, warn, @"error" };

/// Maximum number of active toasts; older ones are dropped past this.
const max_toasts: usize = 8;

pub const Toast = struct {
    allocator: std.mem.Allocator,
    items: std.array_list.Managed(Item),
    /// Set when a toast was queued since the last draw. The caller repaints
    /// only when something changed, so this tells it a toast needs showing.
    pending: bool = false,

    pub const Item = struct {
        level: Level,
        /// NUL-terminated for cimgui; the allocation is msg.len + 1 bytes.
        msg: [:0]u8,
        deadline_ms: i64,
    };

    pub fn init(allocator: std.mem.Allocator) Toast {
        return .{ .allocator = allocator, .items = std.array_list.Managed(Item).init(allocator) };
    }

    pub fn deinit(self: *Toast) void {
        for (self.items.items) |it| self.freeMsg(it.msg);
        self.items.deinit();
    }

    pub fn show(self: *Toast, level: Level, msg: []const u8) !void {
        const copy = try self.allocator.dupeSentinel(u8, msg, 0);
        errdefer self.freeMsg(copy);
        const deadline = std.Io.Clock.real.now(app_io.get()).toMilliseconds() + 3500;
        try self.items.append(.{ .level = level, .msg = copy, .deadline_ms = deadline });
        self.pending = true;
        // Cap the list: drop the oldest toasts when it grows past max_toasts.
        while (self.items.items.len > max_toasts) {
            self.freeMsg(self.items.items[0].msg);
            _ = self.items.orderedRemove(0);
        }
    }

    pub fn draw(self: *Toast) void {
        self.pending = false;
        const now = std.Io.Clock.real.now(app_io.get()).toMilliseconds();
        var i: usize = 0;
        while (i < self.items.items.len) {
            if (self.items.items[i].deadline_ms < now) {
                self.freeMsg(self.items.items[i].msg);
                _ = self.items.orderedRemove(i);
                continue;
            }
            i += 1;
        }
        if (self.items.items.len == 0) return;

        const io = c.igGetIO();
        const pad: f32 = 16.0;
        const toast_w: f32 = 340.0;
        var y = io.*.DisplaySize.y - pad;

        // Draw newest at the bottom.
        var idx: isize = @intCast(self.items.items.len);
        while (idx > 0) {
            idx -= 1;
            const it = self.items.items[@intCast(idx)];
            const toast_h: f32 = 52.0;
            y -= toast_h + 8.0;

            const bg: c.ImVec4 = switch (it.level) {
                .info => .{ .x = 0.14, .y = 0.16, .z = 0.20, .w = 0.96 },
                .warn => .{ .x = 0.28, .y = 0.22, .z = 0.10, .w = 0.96 },
                .@"error" => .{ .x = 0.30, .y = 0.12, .z = 0.12, .w = 0.96 },
            };
            const accent: c.ImVec4 = switch (it.level) {
                .info => .{ .x = 0.40, .y = 0.70, .z = 0.95, .w = 1.0 },
                .warn => .{ .x = 0.95, .y = 0.75, .z = 0.30, .w = 1.0 },
                .@"error" => .{ .x = 0.95, .y = 0.35, .z = 0.30, .w = 1.0 },
            };

            var name_buf: [32]u8 = undefined;
            const name = std.fmt.bufPrintSentinel(&name_buf, "##toast{d}", .{idx}, 0) catch "##toast";

            c.igSetNextWindowPos(.{ .x = io.*.DisplaySize.x - toast_w - pad, .y = y }, c.ImGuiCond_Always, .{ .x = 0, .y = 0 });
            c.igSetNextWindowSize(.{ .x = toast_w, .y = toast_h }, c.ImGuiCond_Always);
            c.igPushStyleColor_Vec4(c.ImGuiCol_WindowBg, bg);
            c.igPushStyleColor_Vec4(c.ImGuiCol_Border, accent);
            c.igPushStyleVar_Float(c.ImGuiStyleVar_WindowRounding, 8.0);
            c.igPushStyleVar_Float(c.ImGuiStyleVar_WindowBorderSize, 1.5);
            c.igPushStyleVar_Vec2(c.ImGuiStyleVar_WindowPadding, .{ .x = 14.0, .y = 12.0 });
            const flags = c.ImGuiWindowFlags_NoTitleBar | c.ImGuiWindowFlags_NoResize |
                c.ImGuiWindowFlags_NoMove | c.ImGuiWindowFlags_NoScrollbar |
                c.ImGuiWindowFlags_NoFocusOnAppearing | c.ImGuiWindowFlags_NoNav;
            _ = c.igBegin(name.ptr, null, flags);
            c.igPushStyleColor_Vec4(c.ImGuiCol_Text, accent);
            const prefix: [*:0]const u8 = switch (it.level) {
                .info => "*",
                .warn => "!",
                .@"error" => "X",
            };
            c.igText("%s", prefix);
            c.igPopStyleColor(1);
            c.igSameLine(0.0, 8.0);
            c.igTextWrapped("%s", it.msg.ptr);
            c.igEnd();
            c.igPopStyleVar(3);
            c.igPopStyleColor(2);
        }
    }

    /// Deadline of the toast that expires first, or null when none are queued.
    pub fn nextDeadlineMs(self: *const Toast) ?i64 {
        var best: ?i64 = null;
        for (self.items.items) |it| {
            if (best == null or it.deadline_ms < best.?) best = it.deadline_ms;
        }
        return best;
    }

    fn freeMsg(self: *Toast, msg: [:0]u8) void {
        // dupeSentinel allocates len + 1 bytes; free the full allocation.
        self.allocator.free(msg.ptr[0 .. msg.len + 1]);
    }
};
