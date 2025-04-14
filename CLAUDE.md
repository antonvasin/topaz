# Topaz Development Guide

## Build/Run Commands
- `zig build` - Build the project
- `zig run` - Build and run the application
- `zig test` - Run tests
- `zig run -- [input files/dirs] --out=[output dir]` - Run with specific inputs and output. *Use `./test --out=dest` for local testing.*

## Code Style Guidelines
- **Naming**: Follow idiomatic Zig coding style
- **Imports**: Group standard library first, then external imports
- **Error handling**: Use Zig's `try/catch` pattern
- **Memory management**: Use single `ArenaAllocator` for allocations, close resources once with single `defer` at the end of `main`
- **C interop**: app uses `md4c` C library via zig C-interop
- Write detailed comments explaining non-obvious code. Don't write unnecessary comments just explaining next line of code.
- Write minimal amount of code to solve the problem. Avoid unnecessary variables.
- Do not extract code into functions unless it is written at least 3 times.
- Do not rename variables and functions not made by you.

## Project Information
- Indexer and static site generator that converts markdown notes into HTML websistes
- Supports Obsidian notes and GitHub Flavored Markdown
- Processes both individual files and directories, linking only what's in the
  current graph
- Indexes markdown and it's frontmatter for tags, backlinks, table of contents,
  header anchors, links, footnotes and similar meta-information
- Each note/page can has it's own template, js and css via frontmatter attrbiutes making it a micro-site
