const std = @import("std");
// Wayland client bindings, translated at build time (Zig 0.17 has no
// @cImport). See src/ctypes/wayland.h.
const wayland = @import("c_wayland");

pub const Output = struct {
    name: []u8,
    width: i32,
    height: i32,
    scale: i32,
    transform: u32,
    /// Compositor-side proxy, valid until deinit. Null for synthetic Outputs.
    wl_output: ?*wayland.wl_output = null,

    pub fn deinit(self: *Output, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        if (self.wl_output) |o| wayland.wl_output_destroy(o);
        self.wl_output = null;
    }
};

/// A registry global the client may bind later (interface name implied by
/// context). `name` is the registry name used with wl_registry_bind.
pub const Global = struct { name: u32, version: u32 };

pub const Enumeration = struct {
    outputs: []Output,
    shm: ?*wayland.wl_shm,
    /// Advertised zwlr_screencopy_manager_v1 global, if the compositor
    /// supports wlr-screencopy. Binding requires the vendored protocol
    /// headers, so it happens in the capture module.
    screencopy: ?Global,
    /// Listener data for the wl_output proxies in `outputs`. The proxies can
    /// receive events on any display roundtrip, so this must stay alive until
    /// every proxy is destroyed; deinit frees it after Output.deinit.
    states: []OutputState,

    pub fn deinit(self: *Enumeration, allocator: std.mem.Allocator) void {
        for (self.outputs) |*o| o.deinit(allocator);
        allocator.free(self.outputs);
        // Freed only after the wl_output proxies above are destroyed: the
        // proxies' listeners point into this slice.
        allocator.free(self.states);
        if (self.shm) |s| wayland.wl_shm_destroy(s);
        self.shm = null;
    }
};

/// A connected Wayland display plus its registry.
///
/// Teardown order matters: every Enumeration obtained from enumerate() must
/// be deinitialized BEFORE Connection.deinit. Enumeration.deinit destroys
/// the wl_output/wl_shm proxies and frees their listener state; destroying
/// proxies after the display is disconnected (or after the registry listener
/// context is freed) is a use-after-free.
pub const Connection = struct {
    display: *wayland.wl_display,
    registry: *wayland.wl_registry,
    /// Heap-allocated registry-listener context. The registry lives as long
    /// as the display and later roundtrips can still dispatch global events
    /// into it, so it must outlive enumerate() and is freed in deinit.
    enum_ctx: ?*EnumCtx = null,

    pub fn init() !Connection {
        const d = wayland.wl_display_connect(null) orelse return error.ConnectFailed;
        const reg = wayland.wl_display_get_registry(d) orelse {
            wayland.wl_display_disconnect(d);
            return error.NoRegistry;
        };
        return .{ .display = d, .registry = reg };
    }

    pub fn deinit(self: *Connection) void {
        if (self.enum_ctx) |ctx| {
            ctx.deinit();
            self.enum_ctx = null;
        }
        wayland.wl_display_disconnect(self.display);
    }

    /// Creates the registry-listener context on first use and attaches the
    /// registry listener exactly once for the connection's lifetime.
    fn ensureEnumCtx(self: *Connection, allocator: std.mem.Allocator) !*EnumCtx {
        if (self.enum_ctx) |ctx| return ctx;
        const ctx = try allocator.create(EnumCtx);
        ctx.* = .{ .allocator = allocator, .pending = std.array_list.Managed(*PendingOutput).init(allocator) };
        if (wayland.wl_registry_add_listener(self.registry, &reg_listener, ctx) < 0) {
            ctx.pending.deinit();
            allocator.destroy(ctx);
            return error.ListenerFailed;
        }
        self.enum_ctx = ctx;
        return ctx;
    }

    /// Enumerates wl_output globals (binding each at version <= 2 and reading
    /// geometry/mode/scale), binds wl_shm, and records whether the compositor
    /// advertises zwlr_screencopy_manager_v1.
    pub fn enumerate(self: *Connection, allocator: std.mem.Allocator) !Enumeration {
        const ctx = try self.ensureEnumCtx(allocator);
        if (wayland.wl_display_roundtrip(self.display) < 0) return error.RoundtripFailed;

        // The registry may report more outputs on later roundtrips; each
        // PendingOutput is heap-allocated so ArrayList growth never moves a
        // `pending` pointer the wl_output listeners hold.
        const states = try allocator.alloc(OutputState, ctx.pending.items.len);
        errdefer allocator.free(states);
        for (ctx.pending.items, 0..) |p, i| {
            states[i] = .{ .pending = p, .allocator = allocator };
            const ver = @min(p.version, 2);
            const proxy = wayland.wl_registry_bind(self.registry, p.reg_name, &wayland.wl_output_interface, ver) orelse return error.BindFailed;
            const out: *wayland.wl_output = @ptrCast(proxy);
            states[i].out.wl_output = out;
            if (wayland.wl_output_add_listener(out, &out_listener, &states[i]) < 0) return error.ListenerFailed;
        }
        if (wayland.wl_display_roundtrip(self.display) < 0) return error.RoundtripFailed;

        const outs = try allocator.alloc(Output, states.len);
        errdefer allocator.free(outs);
        for (states, 0..) |*s, i| {
            s.out.name = try s.pending.displayName(allocator);
            outs[i] = s.out;
        }
        return .{ .outputs = outs, .shm = ctx.shm, .screencopy = ctx.screencopy, .states = states };
    }

    /// Returns the enumerated outputs, discarding shm/screencopy details. The
    /// wl_output proxies are destroyed here so the returned Outputs are
    /// metadata-only; that lets the listener state be freed before returning
    /// instead of having to outlive the slice.
    pub fn outputs(self: *Connection, allocator: std.mem.Allocator) ![]Output {
        var en = try self.enumerate(allocator);
        if (en.shm) |s| wayland.wl_shm_destroy(s);
        en.shm = null;
        for (en.outputs) |*o| {
            if (o.wl_output) |p| {
                wayland.wl_output_destroy(p);
                o.wl_output = null;
            }
        }
        allocator.free(en.states);
        return en.outputs;
    }
};

const PendingOutput = struct {
    reg_name: u32,
    version: u32,
    make: ?[]u8 = null,
    model: ?[]u8 = null,

    fn deinitTemp(self: *PendingOutput, allocator: std.mem.Allocator) void {
        if (self.make) |m| allocator.free(m);
        if (self.model) |m| allocator.free(m);
    }

    fn displayName(self: *const PendingOutput, allocator: std.mem.Allocator) ![]u8 {
        if (self.make != null and self.model != null)
            return try std.fmt.allocPrint(allocator, "{s} {s}", .{ self.make.?, self.model.? });
        return try std.fmt.allocPrint(allocator, "output-{d}", .{self.reg_name});
    }
};

const OutputState = struct {
    pending: *PendingOutput,
    allocator: std.mem.Allocator,
    out: Output = .{ .name = &[_]u8{}, .width = 0, .height = 0, .scale = 1, .transform = 0 },
};

const EnumCtx = struct {
    allocator: std.mem.Allocator,
    /// One heap entry per advertised wl_output. Heap-allocated so ArrayList
    /// growth on later registry events never moves an entry a wl_output
    /// listener still points at.
    pending: std.array_list.Managed(*PendingOutput),
    shm: ?*wayland.wl_shm = null,
    screencopy: ?Global = null,

    fn deinit(self: *EnumCtx) void {
        for (self.pending.items) |p| {
            p.deinitTemp(self.allocator);
            self.allocator.destroy(p);
        }
        self.pending.deinit();
        self.allocator.destroy(self);
    }
};

// Listener structs live at module level: the proxies they attach to outlive
// the registering function, so a stack-local listener would leave the proxy
// pointing at dead stack memory on later event dispatches.
const reg_listener = wayland.wl_registry_listener{ .global = onRegistryGlobal, .global_remove = onRegistryGlobalRemove };

const shm_listener = wayland.wl_shm_listener{ .format = onShmFormat };

const out_listener = wayland.wl_output_listener{
    .geometry = onOutputGeometry,
    .mode = onOutputMode,
    .done = onOutputDone,
    .scale = onOutputScale,
};

fn onRegistryGlobal(data: ?*anyopaque, registry: ?*wayland.wl_registry, name: u32, interface: ?[*:0]const u8, version: u32) callconv(.c) void {
    const ctx: *EnumCtx = @ptrCast(@alignCast(data orelse return));
    const iface = std.mem.span(interface orelse return);
    if (std.mem.eql(u8, iface, "wl_output")) {
        const p = ctx.allocator.create(PendingOutput) catch return;
        p.* = .{ .reg_name = name, .version = version };
        ctx.pending.append(p) catch {
            ctx.allocator.destroy(p);
            return;
        };
    } else if (std.mem.eql(u8, iface, "wl_shm")) {
        // Bind once; a re-advertised wl_shm must not leak the first proxy
        // (each Enumeration owns the proxy current when it was created).
        if (ctx.shm != null) return;
        const proxy = wayland.wl_registry_bind(registry, name, &wayland.wl_shm_interface, 1) orelse return;
        const shm: *wayland.wl_shm = @ptrCast(proxy);
        // wl_shm sends "format" events; a null handler would abort the client.
        if (wayland.wl_shm_add_listener(shm, &shm_listener, null) < 0) {
            wayland.wl_shm_destroy(shm);
            return;
        }
        ctx.shm = shm;
    } else if (std.mem.eql(u8, iface, "zwlr_screencopy_manager_v1")) {
        ctx.screencopy = .{ .name = name, .version = version };
    }
}

fn onRegistryGlobalRemove(data: ?*anyopaque, registry: ?*wayland.wl_registry, name: u32) callconv(.c) void {
    _ = data;
    _ = registry;
    _ = name;
}

fn onShmFormat(data: ?*anyopaque, shm: ?*wayland.wl_shm, format: u32) callconv(.c) void {
    _ = data;
    _ = shm;
    _ = format;
}

fn onOutputGeometry(data: ?*anyopaque, output: ?*wayland.wl_output, x: i32, y: i32, physical_width: i32, physical_height: i32, subpixel: i32, make: ?[*:0]const u8, model: ?[*:0]const u8, transform: i32) callconv(.c) void {
    _ = output;
    _ = x;
    _ = y;
    _ = physical_width;
    _ = physical_height;
    _ = subpixel;
    const state: *OutputState = @ptrCast(@alignCast(data orelse return));
    state.out.transform = @intCast(transform);
    const alloc = state.allocator;
    if (make) |m| {
        if (state.pending.make) |old| alloc.free(old);
        state.pending.make = alloc.dupe(u8, std.mem.span(m)) catch null;
    }
    if (model) |m| {
        if (state.pending.model) |old| alloc.free(old);
        state.pending.model = alloc.dupe(u8, std.mem.span(m)) catch null;
    }
}

fn onOutputMode(data: ?*anyopaque, output: ?*wayland.wl_output, flags: u32, width: i32, height: i32, refresh: i32) callconv(.c) void {
    _ = output;
    _ = refresh;
    const state: *OutputState = @ptrCast(@alignCast(data orelse return));
    // Prefer the current mode; otherwise keep the first advertised one.
    if (flags & wayland.WL_OUTPUT_MODE_CURRENT != 0 or state.out.width == 0) {
        state.out.width = width;
        state.out.height = height;
    }
}

fn onOutputDone(data: ?*anyopaque, output: ?*wayland.wl_output) callconv(.c) void {
    _ = data;
    _ = output;
}

fn onOutputScale(data: ?*anyopaque, output: ?*wayland.wl_output, factor: i32) callconv(.c) void {
    _ = output;
    const state: *OutputState = @ptrCast(@alignCast(data orelse return));
    state.out.scale = factor;
}
