const std = @import("std");
const c = @cImport({
    @cInclude("GLFW/glfw3.h");
});

/// Set by the GLFW input callbacks below.
///
/// The UI loops consume it and repaint only when it is set. Without this an
/// idle window keeps swapping buffers on every vsync tick, which on a
/// software rasterizer (llvmpipe) burns whole cores while nothing happens.
pub var dirty: bool = false;

/// Consume the flag. True when GLFW delivered input since the last call.
pub fn takeDirty() bool {
    const was_dirty = dirty;
    dirty = false;
    return was_dirty;
}

/// Set when the pointer moved or entered the window.
///
/// ImGui waits for the hover to settle before it shows a tooltip, and that
/// wait needs frames to pass. The UI schedules a delayed repaint from this so
/// tooltips still appear when the pointer rests on a control.
pub var mouse_moved: bool = false;

/// Consume the flag. True when the pointer moved since the last call.
pub fn takeMouseMoved() bool {
    const moved = mouse_moved;
    mouse_moved = false;
    return moved;
}

/// ImGui shows a hover tooltip only after the pointer has been still for a
/// moment, and that wait needs frames to pass. Two frames are needed: one to
/// unlock the hover, one to draw the tooltip.
const tooltip_frames: u8 = 2;
/// Delay before the first of those frames.
const tooltip_delay_ms: i64 = 600;
/// Gap between the frames.
const tooltip_gap_ms: i64 = 50;

/// Plans the extra frames ImGui needs to show a delayed hover tooltip.
pub const TooltipWake = struct {
    /// Frames still to draw.
    pending: u8 = 0,
    /// When the next frame is due (wall-clock ms), 0 when none is planned.
    at_ms: i64 = 0,

    /// The pointer moved: plan the tooltip frames.
    pub fn schedule(self: *TooltipWake, now_ms: i64) void {
        self.pending = tooltip_frames;
        self.at_ms = now_ms + tooltip_delay_ms;
    }

    /// True when a tooltip frame is due.
    pub fn due(self: *const TooltipWake, now_ms: i64) bool {
        return self.at_ms != 0 and now_ms >= self.at_ms;
    }

    /// A due frame was drawn: plan the next one, or stop.
    pub fn consumed(self: *TooltipWake, now_ms: i64) void {
        if (self.pending == 0) return;
        self.pending -= 1;
        self.at_ms = if (self.pending > 0) now_ms + tooltip_gap_ms else 0;
    }

    /// Milliseconds until the next due frame, or null when none is planned.
    pub fn remainingMs(self: *const TooltipWake, now_ms: i64) ?i64 {
        if (self.at_ms == 0) return null;
        return @max(self.at_ms - now_ms, 0);
    }
};

/// GLFW key code of the last key press seen, or -1.
///
/// A press is remembered even when the release arrives in the same event
/// batch, so a quick tap is never lost: ImGui's IsKeyPressed only reports a
/// key that is still down when the frame runs.
var last_key_press: c_int = -1;

/// Remember a key press. Called from the GLFW key callback.
pub fn recordKeyPress(key: c_int) void {
    last_key_press = key;
}

/// Consume the recorded key press. True when the key was pressed since the
/// last call.
pub fn tookKeyPress(key: c_int) bool {
    if (last_key_press != key) return false;
    last_key_press = -1;
    return true;
}

/// Install the input callbacks. Must run before the ImGui GLFW backend init:
/// ImGui chains to whatever callback was installed before it.
///
/// The window is taken as `anyopaque` because each @cImport of glfw3.h yields
/// its own opaque GLFWwindow type.
pub fn install(win: ?*anyopaque) void {
    const w: ?*c.GLFWwindow = @ptrCast(win);
    _ = c.glfwSetCursorPosCallback(w, onCursorPos);
    _ = c.glfwSetCursorEnterCallback(w, onCursorEnter);
    _ = c.glfwSetMouseButtonCallback(w, onMouseButton);
    _ = c.glfwSetScrollCallback(w, onScroll);
    _ = c.glfwSetKeyCallback(w, onKey);
    _ = c.glfwSetCharCallback(w, onChar);
    _ = c.glfwSetWindowSizeCallback(w, onWindowSize);
    _ = c.glfwSetFramebufferSizeCallback(w, onFramebufferSize);
    _ = c.glfwSetWindowContentScaleCallback(w, onContentScale);
    _ = c.glfwSetWindowRefreshCallback(w, onWindowRefresh);
}

fn onCursorPos(_: ?*c.GLFWwindow, _: f64, _: f64) callconv(.c) void {
    dirty = true;
    mouse_moved = true;
}

fn onCursorEnter(_: ?*c.GLFWwindow, _: c_int) callconv(.c) void {
    dirty = true;
    mouse_moved = true;
}

fn onMouseButton(_: ?*c.GLFWwindow, _: c_int, _: c_int, _: c_int) callconv(.c) void {
    dirty = true;
}

fn onScroll(_: ?*c.GLFWwindow, _: f64, _: f64) callconv(.c) void {
    dirty = true;
}

fn onKey(_: ?*c.GLFWwindow, key: c_int, _: c_int, action: c_int, _: c_int) callconv(.c) void {
    dirty = true;
    if (action == c.GLFW_PRESS) recordKeyPress(key);
}

fn onChar(_: ?*c.GLFWwindow, _: c_uint) callconv(.c) void {
    dirty = true;
}

fn onWindowSize(_: ?*c.GLFWwindow, _: c_int, _: c_int) callconv(.c) void {
    dirty = true;
}

fn onFramebufferSize(_: ?*c.GLFWwindow, _: c_int, _: c_int) callconv(.c) void {
    dirty = true;
}

fn onContentScale(_: ?*c.GLFWwindow, _: f32, _: f32) callconv(.c) void {
    dirty = true;
}

fn onWindowRefresh(_: ?*c.GLFWwindow) callconv(.c) void {
    dirty = true;
}
