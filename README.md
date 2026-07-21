# topaz

Create static website from a folder of Markdown files. Supports Obsidian notes and GitHub Flavoured Markdown.

```
topaz 0.0.2

Usage: topaz [--debug] <command> [args]

Commands:
  render [input]                Render markdown to HTML
    --out=<outdir>              Directory to output rendered HTML (default: topaz-out)
    --template=<template.html>  HTML template to use
    --db=<myindex.db>           SQLite DB file to use

  index [input]                 Index documents
    --db=<myindex.db>           SQLite DB file to use

  query [query]                 Full-text search the index
    --db=<myindex.db>           SQLite DB file to use

Global:
  --debug                       Enable debug logging
  --help                        Print this help message
```
