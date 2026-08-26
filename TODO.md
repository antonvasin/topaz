# TODO

## Timeline

### 0.0.1

- [x] Integrate [`md4c`](https://github.com/mity/md4c)
- [x] Generate slugs for URLs and headers
- [x] Process Wiki-style links
- [x] Extensionless links
- [x] Implement basic HTML renderer
- [x] Replace reserved chars with HTML entities
- [x] Pretty print HTML
- [x] Collect backlinks
- [x] Read and parse frontmatter, probably with [zig-yaml](https://github.com/kubkon/zig-yaml/)
- [x] Filter out empty and drafts/private notes
- [x] Pass sources via args
- [x] Pass output dir via args
- [x] Tests for rendered HTML pages


### 0.0.2

- [x] zig 0.15
- [x] Basic templates
- [x] `--help` argument

### 0.0.3

- [x] Index text content into sqlite DB
- [x] Basic FTS5 search and querying via CLI
- [x] Check for modified files, fetch from DB if not modified
- [x] Copy linked images/files to output directory
- [x] Stream long files from disc view reader interface
- [x] zig 0.16

### 0.0.4

- [ ] Basic `/search` endpoint for UI
- [ ] Setup sqlite-vec extension
- [ ] Generate embeddings during parsing
- [ ] Basic semantic search

## Tasks

### Markdown parsing

- [ ] Add tests for [Git book](https://github.com/progit/progit/tree/master/en)
- [ ] Add tests for Obsidian vault

### HTML

- [ ] Templates: support backlinks
- [ ] Templates: table of contents
- [ ] Bundle JS & CSS (get dep graph, dedupe, bundle with esbuild)
- [ ] Enhanced client-side navigation, prefetching
- [ ] Web Components/frameworks support
- [ ] Render formulas with [KaTeX](https://github.com/KaTeX/KaTeX)
- [ ] Write basic tests for md-html conversion
- [ ] Generate Table of Contents
- [ ] Embeds

### Sources/Indexing

- [ ] Fetch content from git repo
- [ ] Versioning
- [ ] Generate chronological Archive/All posts info
- [ ] Pin current pages version
- [ ] Generate RSS feed
- [ ] Hash/diff individual paragraphs
- [ ] Fix single-file input, `processFile` fails with `NotDir`
- [ ] Parallel indexing/rendering

### Server

- [ ] Support for `Range` header

### Metadata

- [ ] Created/last edited at timestamps
- [ ] Support `alias`

### CLI

### Chores

