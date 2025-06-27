# TODO

## Markdown parsing

- [x] Integrate [`md4c`](https://github.com/mity/md4c)
- [ ] Generate slugs for URLs and headers
- [x] Process Wiki-style links
- [ ] Add tests for [Git book](https://github.com/progit/progit/tree/master/en)
- [ ] Add tests for Obsidian vault
- [x] Extensionless links

## HTML

- [x] Implement basic HTML renderer
- [ ] Implement templating
- [ ] Bundle JS & CSS (get dep graph, dedupe, bundle with esbuild)
- [ ] Copy linked images/files to `/public`
- [ ] Enhanced client-side navigation, prefetching
- [ ] Web Components/frameworks support
- [ ] Replace reserved chars with HTML entities
- [ ] Render formulas with [KaTeX](https://github.com/KaTeX/KaTeX)
- [ ] Write basic tests for md-html conversion
- [/] Pretty print HTML
- [ ] Embeds

## Sources/Indexing

- [ ] Fetch content from git repo
- [ ] Versioning
- [ ] Generate chronological Archive/All posts info
- [ ] Pin current pages version
- [ ] Generate RSS feed
- [x] Collect backlinks
- [ ] Parse headers, generate Table of Contents
- [ ] Hash/diff individual paragraphs

## Metadata

- [x] Read and parse frontmatter, probably with [zig-yaml](https://github.com/kubkon/zig-yaml/)
- [x] Filter out empty and drafts/private notes
- [ ] Created/last edited at timestamps
- [ ] Support `alias`

## CLI

- [x] Pass sources via args
- [x] Pass output dir via args
