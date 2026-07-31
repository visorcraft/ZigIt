#ifndef CIMGUI_BACKENDS_H
#define CIMGUI_BACKENDS_H

// C wrappers for the Dear ImGui GLFW/OpenGL3 backends. The stock
// imgui_impl_*.h headers are C++ (name-mangled symbols, C++-only
// declarations) and cannot be ingested by Zig's @cImport, so these
// thin extern "C" shims expose the entry points the UI needs.

#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct GLFWwindow GLFWwindow;
typedef struct ImDrawData ImDrawData;

bool cImGui_ImplGlfw_InitForOpenGL(GLFWwindow* window, bool install_callbacks);
void cImGui_ImplGlfw_Shutdown(void);
void cImGui_ImplGlfw_NewFrame(void);

bool cImGui_ImplOpenGL3_Init(const char* glsl_version);
void cImGui_ImplOpenGL3_Shutdown(void);
void cImGui_ImplOpenGL3_NewFrame(void);
void cImGui_ImplOpenGL3_RenderDrawData(ImDrawData* draw_data);

#ifdef __cplusplus
}
#endif

#endif
