## Parsing & Processing

- [ ] Get list of files to process, filter out empty and drafts/private notes

- For each file:
   - [ ] Split Frontmatter and Markdown
   - [ ] Process wiki-links
   - [ ] Add anchors to headers, generate slugs
   - [ ] Generate Table of contents
   - [ ] Collect backlinks for each file

## Building

- [ ] Write output to HTML files
- [ ] Collect JS files
  - [ ] Parse frontmatter, dedupe, get map of source files to bundle
  - [ ] Use esbuild to bundle+minimize JS
- [ ] Collect CSS and bundle CSS
- [ ] Copy images/files to `/public`


## Client

- [ ] SPA navigation
- [ ] Layout/component support
