# TODO

## TODO

- [ ] Pass src directory via args
- [ ] Get list of files to process, filter out empty and drafts/private notes

- For each file:
   - [ ] Split Frontmatter and Markdown
   - [ ] Parse markdown with https://github.com/mity/md4c
   - [ ] Process wiki-links
   - [ ] Add anchors to headers, generate slugs
   - [ ] Generate Table of contents
   - [ ] Collect backlinks for each file
- [ ] Collect table of contents data /w metadata for all files

- [ ] Test with https://github.com/progit/progit/tree/master/en
- [ ] Test with Obsidian vault

- [ ] Get output directory from arguments, use `out` otherwise
- [ ] Write output to HTML files
- [ ] Collect JS files
   - [ ] Parse frontmatter, dedupe, get map of source files to bundle
   - [ ] Use esbuild to bundle+minimize JS
- [ ] Collect CSS and bundle CSS
- [ ] Copy images/files to `/public`

- [ ] SPA navigation
- [ ] Layout/component support

- [ ] Fetch content from git repo
- [ ] Generate changelog from git

## In Progress

## Done
