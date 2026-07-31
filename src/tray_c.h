#pragma once
#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Opaque tray handle. Owns its own event flags (never dangling). */
typedef struct ZigitTray ZigitTray;

/* Returns NULL on failure (daemon continues without tray). */
ZigitTray *zigit_tray_create(void);

void zigit_tray_destroy(ZigitTray *tray);

/* Non-blocking pump of GLib/DBus (StatusNotifier + DBusMenu). Call each UI frame. */
void zigit_tray_poll(ZigitTray *tray);

/* Tray-only idle: block on GLib up to timeout_ms so menu AboutToShow/activate
 * are handled immediately (do NOT sleep on GLFW while the window is hidden). */
void zigit_tray_wait(ZigitTray *tray, unsigned timeout_ms);

/* Read-and-clear event flags set by menu callbacks. */
bool zigit_tray_take_show(ZigitTray *tray);
bool zigit_tray_take_quit(ZigitTray *tray);
bool zigit_tray_take_capture_region(ZigitTray *tray);
bool zigit_tray_take_capture_window(ZigitTray *tray);

#ifdef __cplusplus
}
#endif
