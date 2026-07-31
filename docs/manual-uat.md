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

## Persistence

- [ ] Quit daemon, relaunch → marquee populated from disk
- [ ] Delete a capture from ~/screenshots/ → marquee reflects within 2s
- [ ] Restart compositor → Print Screen still works (binding re-installed)
