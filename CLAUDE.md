# Topaz Development Guide

## Build/Run Commands
- `zig build` - Build the project
- `zig run` - Build and run the application
- `zig test` - Run tests
- `zig build run -- test` to build and run with the `test` folder as input. Default output is `topaz-out`.

## Code Style Guidelines
- **Naming**: Follow idiomatic Zig coding style
- **Imports**: Group standard library first, then external imports
- **Error handling**: Use Zig's `try/catch` pattern
- **Memory management**: Use single `ArenaAllocator` for allocations, close resources once with single `defer` at the end of `main`
- **C interop**: app uses `md4c` C library via zig C-interop
- Do not write any comments unless asked to!
- Write minimal amount of code to solve the problem. Avoid unnecessary variables.
- Do not extract code into functions unless it is written at least 3 times.
- Do not rename variables and functions.

## Project Information
- Indexer and static site generator that converts markdown notes into HTML websistes
- Supports Obsidian notes and GitHub Flavored Markdown
- Processes both individual files and directories, linking only what's in the current graph
- Indexes markdown and it's frontmatter for tags, backlinks, table of contents, header anchors, links, footnotes and similar meta-information
- Each note/page can has it's own template, js and css via frontmatter attrbiutes making it a micro-site
