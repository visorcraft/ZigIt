# Repository Guidelines

## Project Structure & Module Organization

`src/` contains the Zig application. `main.zig` dispatches the `daemon`, `capture`, `edit`, and `setup` subcommands; supporting modules separate UI, Wayland integration, capture, storage, configuration, and editing concerns. `tests/` contains one `*_test.zig` file per feature area. `vendor/` holds checked-in Dear ImGui and Wayland protocol sources; change it only when intentionally updating vendored code. `docs/` contains user guidance and the manual UAT checklist. Build outputs belong in `zig-out/` and `.zig-cache/`.

## Build, Test, and Development Commands

- `zig build`: compile and install `zig-out/bin/zigit` using the default debug profile.
- `zig build -Doptimize=ReleaseSafe`: create an optimized build with safety checks.
- `zig build test`: compile and run every `tests/*_test.zig` target.
- `zig fmt --check path/to/file.zig`: verify changed Zig files without rewriting them.
- `zig fmt path/to/file.zig`: format a changed Zig file.
- `./zig-out/bin/zigit daemon`: launch the main UI after building. Other entry points include `capture`, `edit PATH`, and `setup`.

Use Zig 0.16.0 or newer compatible tooling. The native build links GLFW, Wayland, EGL, GLESv2, and xkbcommon development libraries.

## Coding Style & Naming Conventions

Follow `zig fmt` output and four-space indentation. Use `PascalCase` for types, `camelCase` for functions, and `snake_case` for variables, fields, and filenames, matching existing code. Keep modules focused and reuse Zig's standard library before adding helpers. Preserve explicit allocator ownership and pair allocations with `defer` cleanup. Avoid drive-by edits to vendored sources.

## Testing Guidelines

Use Zig's `std.testing` APIs. Name files `<feature>_test.zig` so `build.zig` discovers them automatically, and give tests behavior-focused names such as `test "save round-trips preferences"`. Add the smallest regression test that proves each non-trivial fix. There is no configured coverage threshold. Run `zig build test` before submitting; use `docs/manual-uat.md` for UI, compositor, clipboard, and capture changes.

## Commit & Pull Request Guidelines

History follows Conventional Commit prefixes such as `feat:`, `fix:`, `docs:`, and `chore:`. Keep each commit scoped and describe the outcome in an imperative subject. Pull requests should explain user-visible behavior, list verification performed, link relevant issues, and include screenshots for UI changes. Call out compositor-specific assumptions or manual test gaps. Do not add AI co-author trailers, generated-by footers, or bot attribution.
