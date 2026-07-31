# Using ZigIt

ZigIt combines screenshot capture, clipboard copy, recent-capture browsing,
and annotation in one Wayland-native application.

## Install and start

Build ZigIt with Zig 0.13.0:

```bash
zig build
zig build test
```

Install the binary to give compositor shortcuts a stable path:

```bash
sudo install -Dm755 zig-out/bin/zigit /usr/local/bin/zigit
zigit setup --dry-run
zigit setup
zigit daemon
```

`setup --dry-run` prints the target configuration without changing it.
`setup --uninstall` removes ZigIt's binding. Sway, Hyprland, River, Labwc,
and KDE Plasma have automatic setup. On GNOME, create a custom keyboard
shortcut that runs `zigit capture`.

## Capture screenshots

The **Captures** tab provides three actions:

- **Capture region:** starts the normal capture flow. KDE opens its system
  region selector.
- **Capture window:** captures the active window where compositor support is
  available.
- **Open folder:** opens the configured capture directory.

The installed compositor hotkey runs a full-screen capture. Successful
captures are written as timestamped PNG files, copied with `wl-copy`, opened
in the editor, and added to the recent-capture list.

The default directory is `~/screenshots`. Change it under **Settings**. A path
beginning with `~/` is expanded against the current home directory.

## Configure the hotkey

Open **Settings**, click **Record**, then press the desired key combination.
Modifier order is displayed as `Super+Ctrl+Alt+Shift+Key`. Press `Esc` or click
**Cancel** to stop recording without changing the shortcut. **Clear** resets
the field to `Print`.

Save preferences and select **Install hotkey binding**. **Dry-run setup** shows
the generated binding. **Uninstall** removes it.

### KDE Plasma shortcut conflicts

KDE normally assigns `Print` to its screenshot action. While ZigIt records a key, it asks
KGlobalAccel to pause global shortcut activation so the key reaches the
focused ZigIt window. ZigIt then checks KGlobalAccel for the key's owner.

If the KDE screenshot action owns the key, ZigIt displays a warning. Clicking **Install hotkey
binding** explicitly transfers that shortcut to ZigIt. ZigIt stores the prior
shortcut override and restores it when the binding is removed or changed. A
conflict owned by another application is not replaced; choose another key.

KDE setup creates
`~/.local/share/applications/com.visorcraft.zigit.desktop`, updates
`~/.config/kglobalshortcutsrc`, refreshes the KDE service cache, and restarts
the user global-shortcut service.

## Edit a capture

Click a recent thumbnail or run `zigit edit PATH`. The palette provides Crop,
Arrow, Rect, Pen, Text, Blur, Step, and color controls.

| Shortcut | Action |
| -------- | ------ |
| `Ctrl+S` | Save the PNG |
| `Ctrl+Z` | Undo |
| `Ctrl+Y` | Redo |
| `Esc` | Close the editor |

## Command reference

```bash
zigit daemon                         # main window and capture history
zigit capture                        # normal capture flow
zigit capture --overlay              # full-screen capture
zigit capture --window               # active-window capture
zigit edit PATH                      # edit one PNG
zigit setup --dry-run                # preview compositor changes
zigit setup --compositor=kde         # override auto-detection
zigit setup --uninstall              # remove ZigIt hotkey
```

Accepted compositor names are `sway`, `hyprland`, `river`, `labwc`, `kde`,
`gnome`, and `unknown`.

## Troubleshooting

### Print still launches another screenshot tool

Run `zigit setup --compositor=kde` from the final installed binary path. If
setup reports another owner, choose a different key in Settings. Log out and
back in if KDE cannot restart its shortcut service.

### KDE capture fails

Verify KDE's system screenshot component is installed and functional. KDE does
not expose the wlr-screencopy protocol, so ZigIt uses the system capture backend.

### Clipboard copy fails

Install `wl-clipboard` and verify `command -v wl-copy`.

### The editor does not open

Install ZigIt somewhere on `PATH`, such as `/usr/local/bin/zigit`, then rerun
`zigit setup`. Build-tree hotkeys stop working if `zig-out/` moves or is
removed.

### wlroots region capture selects the full output

This is a current limitation. The layer-shell region selector and multi-output
stitching are not complete. KDE's system fallback provides a region picker.
