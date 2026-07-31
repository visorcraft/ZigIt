<!-- SPDX-FileCopyrightText: 2026 VisorCraft LLC -->
<!-- SPDX-License-Identifier: GPL-3.0-only -->

# Contributing to ZigIt

Thanks for helping improve ZigIt. This project is a small Zig + Dear ImGui
Wayland screenshot tool. Changes should stay focused, tested, and easy to
review.

## Before you start

- Search [existing issues](https://github.com/visorcraft/ZigIt/issues).
- For a bug, include ZigIt version, distro, compositor, and reproduction steps.
- For a feature, describe the user problem and the smallest useful behavior.
- **Do not disclose vulnerabilities publicly.** Use
  [private vulnerability reporting](https://github.com/visorcraft/ZigIt/security/advisories/new).
  See [SECURITY.md](SECURITY.md).

## Contribution workflow

1. Fork the repository.
2. Clone your fork:

   ```bash
   git clone https://github.com/<you>/ZigIt.git
   cd ZigIt
   ```

3. Create a focused branch:

   ```bash
   git switch -c fix-capture-path
   ```

4. Install build dependencies (Arch/CachyOS example):

   ```bash
   sudo pacman -S base-devel zig glfw wayland libxkbcommon mesa wl-clipboard
   ```

   Zig **0.16.0** or newer is required (`build.zig.zon`).

5. Make the smallest complete change.
6. Add or update a `tests/*_test.zig` regression for non-trivial logic.
7. Run the local gate (below).
8. Push and open a pull request against `master`.

A pull request should state:

- the problem;
- the behavior change;
- commands you ran;
- compositor-specific assumptions or manual test gaps;
- screenshots for UI changes.

## Local development gate

```bash
zig fmt --check path/to/changed-file.zig
zig build
zig build test
```

For UI, compositor, clipboard, or capture changes, also work through
[docs/manual-uat.md](docs/manual-uat.md) on your target compositor when you can.

## Project layout

| Path | Purpose |
| ---- | ------- |
| `src/` | Application modules (`main`, capture, UI, editor, setup, …) |
| `tests/` | One `*_test.zig` file per feature area; auto-discovered by `build.zig` |
| `vendor/` | Checked-in Dear ImGui, cimgui, and Wayland protocol glue |
| `packaging/` | Desktop entry, icons, AUR-oriented assets, GitHub banner |
| `docs/` | User guide and manual UAT checklist |

Prefer editing `src/` and `tests/`. Change `vendor/` only when intentionally
updating vendored code.

## Coding standards

- Follow `zig fmt` output and four-space indentation.
- Use `PascalCase` for types, `camelCase` for functions, `snake_case` for
  variables, fields, and filenames.
- Keep modules focused; prefer the standard library before new helpers.
- Preserve explicit allocator ownership and pair allocations with `defer`.
- Route process I/O through existing `app_io` patterns where present.
- Do not add speculative abstractions or unused configuration.
- Match existing error-handling and logging style.

## Tests

- Use `std.testing`.
- Name files `<feature>_test.zig` so `build.zig` discovers them.
- Name tests after behavior: `test "save round-trips preferences"`.
- Add the smallest regression test that proves each non-trivial fix.
- Prefer testing through public module interfaces over private internals.

## Documentation

Update docs in the same pull request when behavior changes:

| Topic | File |
| ----- | ---- |
| Landing / install | [README.md](README.md) |
| Capture, editing, settings, hotkeys | [docs/usage.md](docs/usage.md) |
| Manual release checks | [docs/manual-uat.md](docs/manual-uat.md) |
| Security and privacy | [SECURITY.md](SECURITY.md) |

Documentation must describe current code. Do not claim platforms, features, or
guarantees that are not implemented.

## Commit messages

Use Conventional Commit-style subjects:

```text
fix: restore KDE shortcut backup on uninstall
feat: install hicolor icons for Wayland app_id
docs: add security policy
chore: release v0.1.2
```

Keep subjects imperative and scoped. Commits are authored by the human
committer only. **Do not** add AI co-author trailers, generated-by footers, or
bot attribution.

## Pull request checklist

- [ ] One clear purpose
- [ ] `zig fmt` clean on touched Zig files
- [ ] `zig build test` passes
- [ ] Regression test for non-trivial fixes
- [ ] Docs updated when user-visible behavior changes
- [ ] Compositor/manual gaps called out
- [ ] No secrets, build output (`.zig-cache/`, `zig-out/`), or attribution trailers

## Releases (maintainers)

1. Start from clean, current `master`.
2. Run `zig build test` and, when relevant, manual UAT.
3. Bump version in `src/main.zig`, `build.zig.zon`, and README.
4. Commit with `chore: release vX.Y.Z`.
5. Tag and push:

   ```bash
   git tag -a vX.Y.Z -m "ZigIt X.Y.Z"
   git push origin master
   git push origin vX.Y.Z
   ```

6. Create the GitHub release from the tag.
7. Update the AUR package (`zigit`) with the new source checksum when
   publishing to Arch users.

## Licensing

ZigIt is licensed under [GPL-3.0-only](LICENSE). By contributing, you agree
that your changes are available under the same license.
