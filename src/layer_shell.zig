const std = @import("std");

pub const Layer = enum { top, overlay, bottom };

pub const Surface = struct {
    width: u32,
    height: u32,

    pub fn init(allocator: std.mem.Allocator, output: []const u8, layer: Layer) !Surface {
        _ = allocator;
        _ = output;
        _ = layer;
        return error.NotImplemented;
    }

    pub fn deinit(self: *Surface) void {
        _ = self;
    }
};
