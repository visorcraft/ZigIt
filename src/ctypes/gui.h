// Translation unit for the GUI bindings.
//
// Zig 0.17 removed @cImport, so the C headers are translated at build time
// (see build.zig) and imported as the "c_gui" module.
//
// GLFW, GLES2 and cimgui live in one unit on purpose: cimgui_backends.h
// declares the backend entry points with GLFWwindow*, and sharing the unit
// keeps GLFWwindow, ImFont and the other ImGui types identical everywhere.
#pragma once

#include <GLFW/glfw3.h>
#include <GLES2/gl2.h>
#include <cimgui.h>
#include <cimgui_backends.h>
