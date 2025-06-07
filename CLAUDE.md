# Topaz Development Guide

## Build/Run Commands
- `zig build` - Build the project
- `zig run` - Build and run the application
- `zig test` - Run tests
- `zig build run -- test` to build and run with the `test` folder as input. Default output is `topaz-out`.

## Code Style Guidelines
- **Naming**: use snake_case for variables, PascalCase for types/structs and camelCase for callables.
- **Imports**: Group standard library first, then external imports.
- **Error handling**: Use Zig's `try/catch` pattern. Avoid re-returning errors, instead handle user facing error in one place.
- **Memory management**: This is CLI application, use single `ArenaAllocator` for allocations, close resources once with single `defer` at the end of `main`.
- **C interop**: app uses `md4c` C library via zig C-interop.
- Do not rename variables or functions when solving problems.
- Do not write any comments unless explicitly asked to do so.
- Prefer dense coding style. Avoid unnecessary variables.
