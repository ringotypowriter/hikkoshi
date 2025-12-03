# Repository Guidelines

This repository contains `hikkoshi`, a Zig CLI tool for running commands under profile-specific HOME/XDG environments.

## Project Structure & Modules
- `src/` – main implementation (`main.zig`, `config.zig`, `env.zig`, `root.zig`).
- `docs/` – design notes and CLI/semantics (`docs/design.md`).
- `zig-out/` and `.zig-cache/` – build outputs and cache; never edit these by hand.

## Build, Run, and Test
- `zig build` – build and install `hikkoshi` into `zig-out/bin/hikkoshi`.
- `zig build run -- <args>` – build and run the CLI, e.g. `zig build run -- example nvim`.
- `zig build test` – run all Zig tests defined in the library and CLI modules.

## Coding Style & Conventions
- Language: Zig, using the standard library and idioms from `std`.
- Formatting: run `zig fmt src/*.zig` before committing.
- Naming: `PascalCase` for types, `snake_case` for functions and variables, constants in `ALL_CAPS` only when they are process-wide.
- Principle: code is for humans first; keep functions small, error messages explicit, and control flow straightforward.

## Testing Guidelines
- Prefer small, focused `test` blocks near the code they exercise.
- Use deterministic inputs; avoid tests that depend on external files or network.
- Ensure `zig build test` passes before opening a pull request.

## Commit & Pull Request Guidelines
- Follow a lightweight conventional style, e.g. `feat: add list subcommand`, `fix: handle missing HOME`, `chore: update docs`.
- Each pull request should describe the motivation, main changes, and any user-visible CLI or config behavior differences.
- If you change semantics, update `docs/design.md` and include examples or usage notes.

## Agent-Specific Instructions
- When using automated tools or assistants, prefer editing `src/` and `docs/` and avoid touching build output directories.
- Keep dependencies minimal; if you add a new Zig package, update both `build.zig` and `build.zig.zon` consistently.

### Zig 0.15.2 Specific Gotchas
- **Stdout/Stderr Writer API**  
  - Do not use `std.io.getStdOut()` / `std.io.getStdErr()` here; Zig 0.15.2’s stdlib exposes writers via `std.fs.File` with an explicit buffer.  
  - Preferred pattern for CLI output:
    ```zig
    var buf: [1024]u8 = undefined;
    var file_writer = std.fs.File.stdout().writer(&buf);
    const out = &file_writer.interface;
    defer out.flush() catch {};
    try out.print("...", .{});
    ```
  - Use the same pattern for stderr with `std.fs.File.stderr()`.

- **ArrayList Usage**  
  - `std.ArrayList(T)` in 0.15.2 is an alias to the managed array list type; it does not have a static `init(allocator)` constructor.  
  - If you really need an `ArrayList`, allocate via:
    ```zig
    var list: std.ArrayList(T) = .empty;
    // or:
    var list = try std.ArrayList(T).initCapacity(allocator, n);
    ```
  - For simple path building, avoid `ArrayList`; prefer a small fixed array plus `std.fs.path.join` (as in `src/env.zig`), to keep code and ownership simpler.

- **Sorting API (`std.sort`)**  
  - There is no generic `std.sort.sort` function in Zig 0.15.2; use concrete algorithms such as `std.sort.block` / `std.sort.heap` / `std.sort.pdq`.  
  - Example for sorting a slice of strings:
    ```zig
    std.sort.block([]const u8, names, {}, struct {
        fn lessThan(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.lessThan);
    ```
  - Make sure the slice you pass to `block` is mutable (`[][]const u8` is fine; `[]const []const u8` is not).
