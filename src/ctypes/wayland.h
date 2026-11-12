// Translation unit for the Wayland client core (imported as "c_wayland").
//
// The screencopy / layer-shell / toplevel protocol glue is compiled from
// vendor/ into a separate static library; the interfaces used by the capture
// code (wl_shm, wl_buffer, wl_output) come from libwayland-client itself.
#pragma once

#include <wayland-client.h>
