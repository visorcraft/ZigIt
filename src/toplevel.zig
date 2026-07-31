const std = @import("std");
const wl = @cImport({
    @cInclude("wayland-client.h");
    @cInclude("wlr-foreign-toplevel-management-unstable-v1-client.h");
});
const capture = @import("capture");

pub const Toplevel = struct {
    app_id: []u8,
    title: []u8,
    // zwlr_foreign_toplevel_management_v1 does not report window geometry;
    // compositor-specific extensions carry it. All zero until an extension
    // surfaces.
    x: i32 = 0,
    y: i32 = 0,
    w: u32 = 0,
    h: u32 = 0,

    pub fn deinit(self: *Toplevel, allocator: std.mem.Allocator) void {
        allocator.free(self.app_id);
        allocator.free(self.title);
    }
};

const HandleState = struct {
    handle: *wl.zwlr_foreign_toplevel_handle_v1,
    allocator: std.mem.Allocator,
    app_id: ?[]u8 = null,
    title: ?[]u8 = null,

    fn deinitTemp(self: *HandleState, allocator: std.mem.Allocator) void {
        if (self.app_id) |s| allocator.free(s);
        if (self.title) |s| allocator.free(s);
        wl.zwlr_foreign_toplevel_handle_v1_destroy(self.handle);
    }
};

const ListCtx = struct {
    allocator: std.mem.Allocator,
    /// One heap entry per toplevel handle. Heap-allocated so ArrayList growth
    /// when the manager announces more toplevels never moves an entry a
    /// handle listener already points at.
    states: std.ArrayList(*HandleState),
    manager: ?*wl.zwlr_foreign_toplevel_manager_v1 = null,
    manager_global: ?struct { name: u32, version: u32 } = null,
};

// Listener structs live at module level: a proxy keeps the listener pointer
// until the proxy is destroyed, so a stack-local listener would become dead
// memory if any event were dispatched after the registering frame returned.
const reg_listener = wl.wl_registry_listener{ .global = onRegistryGlobal, .global_remove = onRegistryGlobalRemove };

const mgr_listener = wl.zwlr_foreign_toplevel_manager_v1_listener{ .toplevel = onManagerToplevel, .finished = onManagerFinished };

const handle_listener = wl.zwlr_foreign_toplevel_handle_v1_listener{
    .title = onHandleTitle,
    .app_id = onHandleAppId,
    .output_enter = onHandleOutputEnter,
    .output_leave = onHandleOutputLeave,
    .state = onHandleState,
    .done = onHandleDone,
    .closed = onHandleClosed,
    .parent = onHandleParent,
};

/// Lists all toplevels known to the compositor (app_id + title; geometry is
/// not part of the protocol). Opens its own short-lived connection. Returns
/// error.ToplevelManagerUnavailable when the compositor does not advertise
/// zwlr_foreign_toplevel_manager_v1.
///
/// Lifetime note: `ctx` and the listener data it holds are stack-local, but
/// every proxy is destroyed before they go out of scope — the manager and
/// all toplevel handles via defers below, the registry when the display is
/// disconnected — and no event is dispatched after the final roundtrip, so
/// no listener ever fires into dead memory.
pub fn toplevels(allocator: std.mem.Allocator) ![]Toplevel {
    const display = wl.wl_display_connect(null) orelse return error.ConnectFailed;
    defer wl.wl_display_disconnect(display);
    const registry = wl.wl_display_get_registry(display) orelse return error.NoRegistry;

    var ctx: ListCtx = .{ .allocator = allocator, .states = std.ArrayList(*HandleState).init(allocator) };
    defer {
        for (ctx.states.items) |s| {
            s.deinitTemp(allocator);
            allocator.destroy(s);
        }
        ctx.states.deinit();
    }

    if (wl.wl_registry_add_listener(registry, &reg_listener, &ctx) < 0) return error.ListenerFailed;
    if (wl.wl_display_roundtrip(display) < 0) return error.RoundtripFailed;

    const g = ctx.manager_global orelse return error.ToplevelManagerUnavailable;
    const manager: *wl.zwlr_foreign_toplevel_manager_v1 = @ptrCast(wl.wl_registry_bind(registry, g.name, &wl.zwlr_foreign_toplevel_manager_v1_interface, @min(g.version, 3)) orelse return error.BindFailed);
    defer wl.zwlr_foreign_toplevel_manager_v1_destroy(manager);

    if (wl.zwlr_foreign_toplevel_manager_v1_add_listener(manager, &mgr_listener, &ctx) < 0) return error.ListenerFailed;
    // Roundtrip 1 collects the toplevel handles; listeners attach afterwards
    // so every known HandleState has a listener before roundtrip 2 dispatches
    // title/app_id events. Entries are heap-allocated, so handles announced
    // during a later roundtrip cannot move them.
    if (wl.wl_display_roundtrip(display) < 0) return error.RoundtripFailed;

    for (ctx.states.items) |s| {
        if (wl.zwlr_foreign_toplevel_handle_v1_add_listener(s.handle, &handle_listener, s) < 0) return error.ListenerFailed;
    }
    if (wl.wl_display_roundtrip(display) < 0) return error.RoundtripFailed;

    const out = try allocator.alloc(Toplevel, ctx.states.items.len);
    var filled: usize = 0;
    errdefer {
        for (out[0..filled]) |*t| t.deinit(allocator);
        allocator.free(out);
    }
    for (ctx.states.items, 0..) |s, i| {
        out[i] = .{
            .app_id = try allocator.dupe(u8, s.app_id orelse ""),
            .title = try allocator.dupe(u8, s.title orelse ""),
        };
        filled += 1;
    }
    return out;
}

/// Finds a toplevel whose bounds contain (cursor_x, cursor_y). v1 always
/// returns null: the base protocol exposes no toplevel geometry, so there is
/// nothing to hit-test against. Callers fall back to a full-output capture.
/// `manager` is the caller's bound manager proxy (unused until a
/// geometry extension lands).
pub fn underCursor(
    allocator: std.mem.Allocator,
    manager: *anyopaque,
    cursor_x: i32,
    cursor_y: i32,
) !?capture.Rect {
    _ = allocator;
    _ = manager;
    _ = cursor_x;
    _ = cursor_y;
    return null;
}

fn ctxFrom(data: ?*anyopaque) *ListCtx {
    return @ptrCast(@alignCast(data.?));
}

fn onRegistryGlobal(data: ?*anyopaque, registry: ?*wl.wl_registry, name: u32, interface: ?[*:0]const u8, version: u32) callconv(.C) void {
    _ = registry;
    const ctx = ctxFrom(data);
    const iface = std.mem.span(interface orelse return);
    if (std.mem.eql(u8, iface, "zwlr_foreign_toplevel_manager_v1")) {
        ctx.manager_global = .{ .name = name, .version = version };
    }
}

fn onRegistryGlobalRemove(data: ?*anyopaque, registry: ?*wl.wl_registry, name: u32) callconv(.C) void {
    _ = data;
    _ = registry;
    _ = name;
}

fn onManagerToplevel(data: ?*anyopaque, manager: ?*wl.zwlr_foreign_toplevel_manager_v1, handle: ?*wl.zwlr_foreign_toplevel_handle_v1) callconv(.C) void {
    _ = manager;
    const ctx = ctxFrom(data);
    const h = handle orelse return;
    const s = ctx.allocator.create(HandleState) catch return;
    s.* = .{ .handle = h, .allocator = ctx.allocator };
    ctx.states.append(s) catch {
        // No listener was attached yet, so destroying the handle is safe.
        wl.zwlr_foreign_toplevel_handle_v1_destroy(h);
        ctx.allocator.destroy(s);
    };
}

fn onManagerFinished(data: ?*anyopaque, manager: ?*wl.zwlr_foreign_toplevel_manager_v1) callconv(.C) void {
    _ = data;
    _ = manager;
}

fn stateFrom(data: ?*anyopaque) *HandleState {
    return @ptrCast(@alignCast(data.?));
}

fn dupeReplace(allocator: std.mem.Allocator, slot: *?[]u8, value: ?[*:0]const u8) void {
    const v = value orelse return;
    if (slot.*) |old| allocator.free(old);
    slot.* = allocator.dupe(u8, std.mem.span(v)) catch null;
}

fn onHandleTitle(data: ?*anyopaque, handle: ?*wl.zwlr_foreign_toplevel_handle_v1, title: ?[*:0]const u8) callconv(.C) void {
    _ = handle;
    const s = stateFrom(data);
    dupeReplace(s.allocator, &s.title, title);
}

fn onHandleAppId(data: ?*anyopaque, handle: ?*wl.zwlr_foreign_toplevel_handle_v1, app_id: ?[*:0]const u8) callconv(.C) void {
    _ = handle;
    const s = stateFrom(data);
    dupeReplace(s.allocator, &s.app_id, app_id);
}

fn onHandleOutputEnter(data: ?*anyopaque, handle: ?*wl.zwlr_foreign_toplevel_handle_v1, output: ?*wl.wl_output) callconv(.C) void {
    _ = data;
    _ = handle;
    _ = output;
}

fn onHandleOutputLeave(data: ?*anyopaque, handle: ?*wl.zwlr_foreign_toplevel_handle_v1, output: ?*wl.wl_output) callconv(.C) void {
    _ = data;
    _ = handle;
    _ = output;
}

fn onHandleState(data: ?*anyopaque, handle: ?*wl.zwlr_foreign_toplevel_handle_v1, state: ?*wl.wl_array) callconv(.C) void {
    _ = data;
    _ = handle;
    _ = state;
}

fn onHandleDone(data: ?*anyopaque, handle: ?*wl.zwlr_foreign_toplevel_handle_v1) callconv(.C) void {
    _ = data;
    _ = handle;
}

fn onHandleClosed(data: ?*anyopaque, handle: ?*wl.zwlr_foreign_toplevel_handle_v1) callconv(.C) void {
    _ = data;
    _ = handle;
}

fn onHandleParent(data: ?*anyopaque, handle: ?*wl.zwlr_foreign_toplevel_handle_v1, parent: ?*wl.zwlr_foreign_toplevel_handle_v1) callconv(.C) void {
    _ = data;
    _ = handle;
    _ = parent;
}
