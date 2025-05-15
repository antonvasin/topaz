# Topaz Development Guide

## Build/Run Commands
- `zig build` - Build the project
- `zig run` - Build and run the application
- `zig test` - Run tests
- `zig build run -- test` to build and run with the `test` folder as input. Default output is `topaz-out`.

## Code Style Guidelines
- **Naming**: use snake_case for variables, PascalCase for types/structs and camelCase for callables.
- **Imports**: Group standard library first, then external imports.
- **Error handling**: Use Zig's `try/catch` pattern.
- **Memory management**: Use single `ArenaAllocator` for allocations, close resources once with single `defer` at the end of `main`.
- **C interop**: app uses `md4c` C library via zig C-interop.
- Do not rename variables or functions.
- Do not write any comments.
- Write minimal amount of code to solve the problem. Avoid unnecessary variables.

## Project Information
- Markdown-HTML static site generator with support for Obisidian vaults and wiki-style notes.
- Indexes notes for backlinks, meta-info, header- and paragraph-level internal links to support graph-like knowledge management (PKM) notes.
- Distributes as single binary with no runtime dependencies and produces static HTML+JS+CSS website with support for templates and custom JS and CSS via Frontmatter.
- Produces sites with enhanced SPA-like client code for self-hosting personal websites, docs and wiki-style knowledge bases.
