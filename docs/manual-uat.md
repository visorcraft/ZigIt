# ZigIt Manual UAT

## Pre-flight

- [ ] Build: `zig build` succeeds
- [ ] wl-clipboard installed: `which wl-copy`
- [ ] Compositor detected: `./zig-out/bin/zigit setup --dry-run` shows a snippet
- [ ] Hotkey installed: `./zig-out/bin/zigit setup` (one-time)

## Capture flow

- [ ] Press Print Screen → fullscreen overlay appears within 500ms
- [ ] Drag rectangle → live selection outline follows cursor
- [ ] Release mouse → screenshot saved to ~/screenshots/, clipboard contains PNG
- [ ] Marquee in top-right shows the new thumbnail within 2s
- [ ] Press Esc on overlay → no file written, no copy
- [ ] Hold Alt + click on a window → screenshot of that window

## Hotkey settings

- [ ] Click Record, then press Esc → recording cancels and daemon stays open
- [ ] On KDE, click Record and press Print → key is recorded without launching another tool
- [ ] On KDE with an existing screenshot binding, ZigIt identifies the owner
- [ ] Install the KDE binding → Print launches ZigIt
- [ ] Uninstall the KDE binding → the prior screenshot shortcut works again

## Editor flow

- [ ] Click a marquee thumbnail → editor window opens with the capture
- [ ] Tool palette shows: Crop, Arrow, Rect, Pen, Text, Blur, Step, Color
- [ ] Draw an arrow, save (Ctrl+S) → file overwritten, marquee refreshes
- [ ] Undo (Ctrl+Z) → arrow removed
- [ ] Close editor (Esc) → file persisted, no errors
- [ ] Text tool → click the image, type, press Enter → text placed on the capture
- [ ] Text tool → click the image, press Esc → text cancelled, editor stays open

## Idle CPU

Windows must not present frames while nothing happens.

- [ ] Open the editor, leave it untouched → `top` shows ~0% CPU (no `llvmpipe-*`
      threads burning cycles), the main thread sits blocked in `poll`
- [ ] Move the mouse over the canvas → the crosshair follows, one repaint
- [ ] Drag an arrow → the rubber band follows the cursor
- [ ] Save (Ctrl+S) → "Saved" appears, stays readable for ~2s, then disappears
- [ ] Open the main window (`zigit daemon`) and leave it idle → ~0% CPU
- [ ] Escape in the main window → it hides to the tray and stays at ~0% CPU
- [ ] Run `zigit daemon` again → the running daemon raises its window

## Persistence

- [ ] Quit daemon, relaunch → marquee populated from disk
- [ ] Delete a capture from ~/screenshots/ → marquee reflects within 2s
- [ ] Restart compositor → Print Screen still works (binding re-installed)
