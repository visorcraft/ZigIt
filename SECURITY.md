<!-- SPDX-FileCopyrightText: 2026 VisorCraft LLC -->
<!-- SPDX-License-Identifier: GPL-3.0-only -->

# Security and Privacy

ZigIt is a local Wayland screenshot tool. It captures screen content, writes
PNG files, copies images through `wl-copy`, and can install compositor hotkey
bindings. Read this page before reporting a vulnerability or deploying ZigIt on
a shared machine.

## Report a vulnerability

**Do not open a public issue, discussion, or pull request for a suspected
security problem.**

Use [GitHub private vulnerability reporting](https://github.com/visorcraft/ZigIt/security/advisories/new)
from this repository's **Security** tab.

Please include:

- ZigIt version (`zigit --version`);
- Linux distribution and architecture;
- compositor (Sway, Hyprland, KDE Plasma, River, Labwc, GNOME, other);
- impact and realistic attack scenario;
- minimal reproduction steps or proof of concept;
- relevant configuration with secrets redacted;
- a suggested mitigation, if known.

Do not attach real screenshots that contain private content, API keys, or
credentials. Maintainers will coordinate validation, remediation, release, and
disclosure in the private advisory.

## Supported versions

| Version | Security support |
| ------- | ---------------- |
| Latest stable release | Supported |
| Older releases | Upgrade required unless a backport is announced |
| Unreleased `master` snapshots | Best effort only |

The [latest GitHub release](https://github.com/visorcraft/ZigIt/releases/latest)
is the version source of truth.

## Security model

ZigIt runs with the permissions of the current user. It is not a sandbox.

- Capture uses compositor protocols (wlr-screencopy) or the KDE/system capture
  path. Screen content is sensitive by nature.
- Saved PNGs live under the configured capture directory (default
  `~/screenshots`). Anyone who can read that directory can read captures.
- Clipboard handoff spawns local `wl-copy` with image/png data. Clipboard
  consumers on the same session may access that data while it is offered.
- `zigit setup` can write compositor config snippets and a KDE desktop entry
  under the user's home directory. It does not require root for normal setup.
- The daemon and editor are local GUI processes. They do not open network
  listeners.

Do not run ZigIt with more privilege than required. Avoid installing hotkeys
that launch untrusted binaries.

## Local data

| Data | Default path | Notes |
| ---- | ------------ | ----- |
| Preferences | `~/.config/zigit/config.toml` | Save directory, theme, hotkey, editor defaults |
| Captures | `~/screenshots/` (or configured `save_dir`) | PNG files; no cloud upload |
| Log file (optional) | path chosen by caller / tests | May include paths and error text |
| KDE launcher | `~/.local/share/applications/com.visorcraft.zigit.desktop` | Capture action / shortcuts |
| User icons | `~/.local/share/icons/hicolor/*/apps/com.visorcraft.zigit.png` | Desktop icon theme |

ZigIt has **no telemetry**, analytics, crash uploader, or automatic update
checker. Captures remain local unless another tool moves them.

Uninstalling hotkey bindings does not delete captures, preferences, or icons.

## Capture and clipboard risks

- Screenshots can include passwords, 2FA codes, private messages, and other
  secrets visible on screen. Treat the capture directory as sensitive.
- Region/window selection is a convenience UX boundary, not an OS security
  boundary.
- Clipboard images may persist in the Wayland clipboard manager until replaced
  or the session ends, depending on compositor and `wl-copy` behavior.
- Editors open local PNG paths; opening untrusted PNGs is ordinary image
  parsing risk (decode in pure Zig for ZigIt-produced files; third-party PNGs
  should still be treated carefully).

## Compositor integration

`zigit setup` may:

- write snippets under Sway/Hyprland/River/Labwc config paths;
- create or update a KDE desktop entry and shortcut backup;
- request compositor reload commands (`swaymsg`, `hyprctl`, `labwc`, KDE tools).

Review dry-run output first:

```bash
zigit setup --dry-run
```

Hotkey install that replaces another screenshot action is intentional and
documented. Uninstall restores the previous KDE binding when a backup exists.

## Network and external processes

| Action | Process / API | Trigger |
| ------ | ------------- | ------- |
| Clipboard copy | `wl-copy` | Capture / copy path |
| KDE capture fallback | `spectacle` (when available) | Capture without wlr-screencopy |
| Folder picker | `kdialog` or `zenity` | Settings browse |
| Open folder | `xdg-open` | UI action |
| Spawn editor / capture | `zigit` child process | Daemon UI |
| Shortcut query/block (KDE) | `qdbus6`, `kbuildsycoca6`, `systemctl --user` | Setup / reload |

ZigIt does not implement HTTP clients, cloud upload, or remote command
execution. OS components and tools above have their own security properties.

## Dependency security

Maintainers should:

- keep the Zig toolchain current enough for supported builds (Zig 0.16+);
- review vendored Dear ImGui / cimgui / protocol sources when updating
  `vendor/`;
- run `zig build test` before tagging a release;
- use private advisories for coordinated fixes.

## Release integrity

Official sources are this repository's GitHub Releases and the AUR package
[`zigit`](https://aur.archlinux.org/packages/zigit). Prefer:

1. the canonical `https://github.com/visorcraft/ZigIt/releases` page;
2. tag provenance and release notes;
3. AUR packages maintained by `visorcraft` when using Arch.

Verify checksums when distro packaging publishes them. Build from tagged source
when possible.

## Hardening recommendations

- Keep the capture directory private (`0700` or equivalent home permissions).
- Prefer a dedicated screenshots folder for sensitive work.
- Clear the clipboard after pasting sensitive captures.
- Review `zigit setup --dry-run` before installing hotkeys.
- Do not run the daemon as root.
- Upgrade promptly when a security release is published.

## Security non-goals

ZigIt does not claim:

- sandboxed capture isolation beyond compositor policy;
- encrypted storage of preferences or captures;
- secure deletion of PNGs;
- protection against malicious image files beyond ordinary decode limits;
- signed release binaries (unless a future release says otherwise);
- multi-user or remote multi-seat threat models.
