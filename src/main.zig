const std = @import("std");
const builtin = @import("builtin");
const c = @cImport({
    @cInclude("md4c.h");
});
const yaml = @import("yaml");
const Yaml = yaml.Yaml;

const print = std.debug.print;
const log = std.log.scoped(.topaz);
const mem = std.mem;
const assert = std.debug.assert;

pub const std_options: std.Options = .{
    // Set the log level to info
    // .log_level = .info,

    .log_scope_levels = &.{
        .{ .scope = .parser, .level = .err },
        .{ .scope = .tokenizer, .level = .err },
    },
};

const Page = struct {
    name: []const u8,
    path: []const u8,
    out_path: []const u8,
    meta: Meta,

    buf: []const u8,
    markdown: []const u8,
    frontmatter: ?[]const u8 = null,

    const Meta = struct {
        title: []const u8,
        url: ?[]const u8,
        date: ?[]const u8 = null,
        skip: bool = false,
    };

    const Link = struct {
        link: []const u8,
        text: []const u8,
    };

    pub fn init(allocator: mem.Allocator, file_path: []const u8, buf: []const u8) !Page {
        // input_folder  /note-01           .md
        // input_folder  /subfolder/note-02 .md
        //
        // [input_dir]   /      [name]      .md
        // [outdir]      /      [name]      .html
        const name = file_path[0 .. file_path.len - 3];
        const out_path = try std.fmt.allocPrint(allocator, "{s}.html", .{name});

        var yaml_end: usize = 0;

        // Cutting out YAML frontmatter
        if (mem.startsWith(u8, buf, "---\n")) {
            var i: usize = 4;
            while (i < buf.len - 3) {
                if (mem.eql(u8, buf[i .. i + 4], "\n---")) {
                    if (i + 4 >= buf.len or buf[i + 4] == '\n') {
                        yaml_end = i + 4;
                        break;
                    }
                }
                i += 1;
            }
        }

        const frontmatter = if (yaml_end > 0) buf[0..yaml_end] else null;

        var meta = Page.Meta{
            .title = name,
            .skip = false,
            .url = name,
        };

        if (frontmatter) |yml| {
            // Process Frontmatter. We want to support at least Obsidian and GitHub style metadata.
            //
            // Obsidian
            //
            // https://help.obsidian.md/properties#Default+properties
            // https://help.obsidian.md/publish/seo#Metadata
            // https://help.obsidian.md/publish/permalinks
            //
            // Property            Type         Description
            // ────────────────────────────────────────────
            // tags                [][]const u8 List of tags
            // aliases             [][]const u8 List of aliases
            // cssclasses          [][]const u8 Allows you to style individual notes using CSS snippets.
            // publish             bool         See Automatically select notes to publish.
            // permalink           []const u8   See Permalinks.
            // description         []const u8   See Description.
            // image               []const u8   See Image.
            // cover               []const u8   See Image.
            //
            // GitHub Pages
            //
            // https://docs.github.com/en/contributing/writing-for-github-docs/using-yaml-frontmatter
            //
            // Property            Type         Description
            // ────────────────────────────────────────────
            // versions
            // redirect_from
            // title
            // shortTitle
            // intro
            // permissions
            // product
            // layout
            // children
            // childGroups
            // featuredLinks
            // showMiniToc
            // allowTitleToDifferFromFilename
            // changelog
            // defaultPlatform
            // defaultTool
            // learningTracks
            // includeGuides
            // type
            // topics
            // communityRedirect
            // effectiveDate

            var yaml_parser: Yaml = .{ .source = yml };
            // Pages are not following any fixed schema so we won't try to parse them
            // into a struct. Instead we attempt to parse fields important to us one by one.
            try yaml_parser.load(allocator);
            // TODO: defer yaml_parser.deinit(allocator);
            const map = yaml_parser.docs.items[0].map;
            if (map.contains("title")) meta.title = try map.get("title").?.asString();
            if (map.contains("draft")) meta.skip = try map.get("draft").?.asBool();
            if (map.contains("publish")) meta.skip = !try map.get("publish").?.asBool();
        }

        return .{
            .name = name,
            .path = file_path,
            .out_path = out_path,
            .buf = buf,
            .markdown = buf[yaml_end .. buf.len - 1],
            .frontmatter = frontmatter,
            .meta = meta,
        };
    }

    pub fn deinit(self: *Page, allocator: mem.Allocator) void {
        allocator.free(self.out_path);
        allocator.free(self.buf);
    }
};

const LinkValues = std.StringHashMap(Page.Link);
const Links = std.StringHashMap(LinkValues);

///  Stores relationships between Pages
const PageGraph = struct {
    allocator: mem.Allocator,
    page_list: std.ArrayList(Page),
    pages: std.StringHashMap(usize),
    ///  What links page have
    forward: Links,
    //  Who links to that page
    backward: Links,

    pub fn init(allocator: mem.Allocator) !PageGraph {
        const page_list = std.ArrayList(Page).init(allocator);
        const pages = std.StringHashMap(usize).init(allocator);
        const forward = Links.init(allocator);
        const backward = Links.init(allocator);

        return .{
            .allocator = allocator,
            .page_list = page_list,
            .pages = pages,
            .forward = forward,
            .backward = backward,
        };
    }

    pub fn deinit(self: *PageGraph) void {
        self.page_list.deinit();
        self.pages.deinit();
        self.forward.deinit();
        self.backward.deinit();
    }

    pub fn addPage(self: *PageGraph, page: Page) !void {
        try self.page_list.append(page);
        const index = self.page_list.items.len - 1;
        try self.pages.put(page.name, index);

        if (!self.forward.contains(page.name)) {
            try self.forward.put(page.name, std.StringHashMap(Page.Link).init(self.allocator));
        }
        if (!self.backward.contains(page.name)) {
            try self.backward.put(page.name, std.StringHashMap(Page.Link).init(self.allocator));
        }
    }

    pub fn addLink(self: *PageGraph, page_name: []const u8, link: Page.Link) !void {
        // TODO: we probably want to use real hashing function here
        const id = try std.fmt.allocPrint(self.allocator, "{s}{s}{any}", .{ page_name, link.link, link.text });

        var forward_links_ptr = self.forward.getPtr(page_name) orelse return error.LinksNotFound;
        try forward_links_ptr.put(id, link);

        var backward_links_ptr = try self.backward.getOrPut(link.link);
        if (!backward_links_ptr.found_existing) {
            backward_links_ptr.value_ptr.* = std.StringHashMap(Page.Link).init(self.allocator);
        }
        const backward_link = Page.Link{
            .link = page_name,
            .text = page_name,
        };
        try backward_links_ptr.value_ptr.put(id, backward_link);
    }

    pub fn listPages(self: *PageGraph) void {
        var iterator = self.pages.keyIterator();

        var i: usize = 0;
        while (iterator.next()) |k| {
            log.debug("{d} {s}\n", .{ i, k.* });
            i += 1;
        }
    }
};

/// Context for building HTML string inside md4c callbacks
const RenderContext = struct {
    allocator: mem.Allocator,
    buf: std.ArrayList(u8),

    graph: *PageGraph,
    cur_page: []const u8 = undefined,

    image_nesting_level: u32 = 0,
    current_level: u32 = 0,

    // For building internal links incrementally
    cur_link_url: ?[]const u8 = null,
    cur_link_text: std.ArrayList(u8),

    pub fn init(allocator: mem.Allocator, graph: *PageGraph) !RenderContext {
        const buf = std.ArrayList(u8).init(allocator);
        const link_text = std.ArrayList(u8).init(allocator);

        return .{
            .buf = buf,
            .allocator = allocator,
            .graph = graph,
            .cur_link_text = link_text,
        };
    }

    pub fn deinit(self: *RenderContext) void {
        self.buf.deinit();
        self.cur_link_text.deinit();
    }

    pub fn write(self: *RenderContext, str: []const u8) !void {
        try self.buf.appendSlice(str);
    }

    pub fn writeIndented(self: *RenderContext, str: []const u8) !void {
        for (0..self.current_level) |_| try self.write("    ");
        try self.write(str);
    }

    pub fn writeOpen(self: *RenderContext, str: []const u8) !void {
        for (0..self.current_level) |_| try self.write("    ");
        try self.write(str);
        try self.write("\n");
        self.current_level += 1;
    }

    pub fn writeClose(self: *RenderContext, str: []const u8) !void {
        // assert(self.current_level > 0);
        if (self.current_level > 0) self.current_level -= 1 else print("Lost indentation {s}\n", .{str});
        for (0..self.current_level) |_| try self.write("    ");
        try self.write(str);
        try self.write("\n");
    }

    pub fn writeHtmlHead(self: *RenderContext, page_title: []const u8) !void {
        const html_head_open =
            \\<!DOCTYPE html>
            \\<html>
            \\    <head>
            \\        <meta name="generator" content="topaz">
            \\        <meta charset="UTF-8">
            \\
        ;

        try self.write(html_head_open);
        self.current_level = 2;

        var title_buf: [1024]u8 = undefined;
        const title = try std.fmt.bufPrint(&title_buf, "<title>{s}</title>\n", .{page_title});
        try self.writeIndented(title);

        try self.writeClose("</head>");
        try self.writeOpen("<body>");
    }

    pub fn writeHtmlTail(self: *RenderContext) !void {
        try self.writeClose("</body>");
        try self.writeClose("</html>");
    }

    pub fn writeFooter(self: *RenderContext) !void {
        const page = self.cur_page;
        const forward_links = self.graph.forward.get(page) orelse return error.MissingLinks;

        try self.writeOpen("<footer>");
        if (forward_links.count() > 0) {
            try self.writeIndented("<h3>Forward Links</h3>\n");
            try self.writeOpen("<ul>");
            var iterator = forward_links.valueIterator();
            while (iterator.next()) |link| {
                try self.writeOpen("<li>");

                try self.writeIndented("<a href=\"");
                try self.renderUrlEscaped(link.link);
                try self.write(".html\">");
                try self.write(link.text);
                try self.write("</a>\n");
                try self.writeClose("</li>");
            }
            try self.writeClose("</ul>");
        }

        const backward_links = self.graph.backward.get(page);
        if (backward_links) |links| {
            if (links.count() > 0) {
                try self.writeIndented("<h3>Back Links</h3>\n");
                try self.writeOpen("<ul>");
                var iterator = links.valueIterator();
                while (iterator.next()) |link| {
                    try self.writeOpen("<li>");

                    try self.writeIndented("<a href=\"");
                    try self.renderUrlEscaped(link.link);
                    try self.write(".html\">");
                    try self.write(link.text);
                    try self.write("</a>\n");
                    try self.writeClose("</li>");
                }
                try self.writeClose("</ul>");
            }
        }
        try self.writeClose("</footer>");
    }

    pub fn renderText(self: *RenderContext, text_type: c.MD_TEXTTYPE, data: []const u8) !void {
        switch (text_type) {
            c.MD_TEXT_NULLCHAR => try self.renderUtf8Codepoint(0),
            c.MD_TEXT_HTML => try self.write(data),
            c.MD_TEXT_ENTITY => try self.renderEntity(data),
            c.MD_TEXT_CODE => try self.write(data),
            else => try self.renderHtmlEscaped(data),
        }
    }

    /// Renders HTML entity as UTF-8 if possible
    fn renderEntity(self: *RenderContext, data: []const u8) !void {
        // Handle numeric entities
        if (data.len > 3 and data[1] == '#') {
            var codepoint: u32 = 0;

            if (data[2] == 'x' or data[2] == 'X') {
                // Hexadecimal entity
                var i: usize = 3;
                while (i < data.len - 1) : (i += 1) {
                    const hex_val: u4 = switch (data[i]) {
                        '0'...'9' => @intCast(data[i] - '0'),
                        'A'...'F' => @intCast(data[i] - 'A' + 10),
                        'a'...'f' => @intCast(data[i] - 'a' + 10),
                        else => 0,
                    };
                    codepoint = 16 * codepoint + hex_val;
                }
            } else {
                // Decimal entity
                var i: usize = 2;
                while (i < data.len - 1) : (i += 1) {
                    codepoint = 10 * codepoint + (data[i] - '0');
                }
            }

            try self.renderUtf8Codepoint(codepoint);
            return;
        }

        // Write named entity as is without checking
        try self.write(data);
    }

    fn renderHtmlEscaped(self: *RenderContext, data: []const u8) !void {
        var beg: usize = 0;
        var off: usize = 0;

        while (off < data.len) {
            const ch = data[off];
            const needs_escape = (ch == '&') or
                (ch == '<') or
                (ch == '>') or
                (ch == '"') or false;

            // Skip characters that don't need escaping
            while (off < data.len and !needs_escape) {
                off += 1;
            }

            // Write the unescaped part
            if (off > beg) {
                try self.write(data[beg..off]);
            }

            // Handle only characters that absolutely need escaping in HTML
            if (off < data.len) {
                const char = data[off];
                switch (char) {
                    '&' => try self.write("&amp;"),
                    '<' => try self.write("&lt;"),
                    '>' => try self.write("&gt;"),
                    '"' => try self.write("&quot;"),
                    else => try self.write(&[_]u8{char}),
                }
                off += 1;
            } else {
                break;
            }

            beg = off;
        }
    }

    fn renderUrlEscaped(self: *RenderContext, data: []const u8) !void {
        for (data) |char| {
            if ((char >= 'a' and char <= 'z') or
                (char >= 'A' and char <= 'Z') or
                (char >= '0' and char <= '9') or
                char == '-' or
                char == '.' or
                char == '_' or
                char == '~' or
                char == '/' or
                char == ':' or
                char == '@')
            {
                // FIXME: use writer fn for single chars
                try self.buf.append(char);
            } else if (char == '&') {
                try self.write("&amp;");
            } else {
                try self.buf.writer().print("%{X:0>2}", .{char});
            }
        }
    }

    fn renderUtf8Codepoint(self: *RenderContext, codepoint: u32) !void {
        var buf: [4]u8 = undefined;
        const len = try std.unicode.utf8Encode(@intCast(codepoint), &buf);
        try self.write(buf[0..len]);
    }

    fn renderAttribute(self: *RenderContext, attr: *const c.MD_ATTRIBUTE) !void {
        var i: usize = 0;
        while (attr.substr_offsets[i] < attr.size) : (i += 1) {
            const type_val = attr.substr_types[i];
            const off = attr.substr_offsets[i];
            const size = attr.substr_offsets[i + 1] - off;
            const attr_text = attr.text + off;
            const data = attr_text[0..size];

            switch (type_val) {
                c.MD_TEXT_NULLCHAR => try self.renderUtf8Codepoint(0),
                c.MD_TEXT_ENTITY => try self.renderEntity(data),
                c.MD_TEXT_NORMAL => {
                    // For attributes, we need to escape quotes and ampersands
                    var j: usize = 0;
                    var start: usize = 0;

                    while (j < data.len) {
                        if (data[j] == '"' or data[j] == '&') {
                            // Write the part before the character that needs escaping
                            if (j > start) try self.write(data[start..j]);

                            // Write the escaped character
                            if (data[j] == '"') try self.write("&quot;") else try self.write("&amp;");

                            start = j + 1;
                        }
                        j += 1;
                    }

                    // Write the remaining part
                    if (start < data.len) try self.write(data[start..]);
                },
                else => try self.write(data),
            }
        }
    }
};

/// Wraps MD4C for markdown parsing with RenderContext
const Parser = struct {
    md4c: c.MD_PARSER,

    pub fn init() !Parser {
        const parser = c.MD_PARSER{
            .abi_version = 0,
            .flags = c.MD_FLAG_TABLES |
                c.MD_FLAG_TASKLISTS |
                c.MD_FLAG_WIKILINKS |
                c.MD_FLAG_LATEXMATHSPANS |
                c.MD_FLAG_PERMISSIVEAUTOLINKS |
                c.MD_FLAG_STRIKETHROUGH,
            .enter_block = Parser.enter_block,
            .leave_block = Parser.leave_block,
            .enter_span = Parser.enter_span,
            .leave_span = Parser.leave_span,
            .text = Parser.text,
            .debug_log = null,
            .syntax = null,
        };

        return .{
            .md4c = parser,
        };
    }

    pub fn parse(self: *Parser, markdown: []const u8, ctx: *RenderContext) void {
        _ = c.md_parse(@ptrCast(markdown), @intCast(markdown.len), &self.md4c, @ptrCast(ctx));
    }

    fn enter_block(blk: c.MD_BLOCKTYPE, detail: ?*anyopaque, userdata: ?*anyopaque) callconv(.C) c_int {
        const ctx = @as(*RenderContext, @ptrCast(@alignCast(userdata)));
        enter_block_impl(blk, detail, ctx) catch return 1;
        return 0;
    }

    fn enter_block_impl(blk: c.MD_BLOCKTYPE, detail: ?*anyopaque, ctx: *RenderContext) !void {
        const headers_openning_tags: [6][]const u8 = .{
            "<h1>",
            "<h2>",
            "<h3>",
            "<h4>",
            "<h5>",
            "<h6>",
        };

        switch (blk) {
            c.MD_BLOCK_DOC => {},
            c.MD_BLOCK_QUOTE => try ctx.writeOpen("<blockquote>"),
            c.MD_BLOCK_UL => try ctx.writeOpen("<ul>"),
            c.MD_BLOCK_OL => {
                const ol_detail = @as(*const c.MD_BLOCK_OL_DETAIL, @ptrCast(@alignCast(detail)));
                if (ol_detail.start == 1) {
                    try ctx.writeOpen("<ol>");
                } else {
                    var buf: [32]u8 = undefined;
                    const ol_tag = try std.fmt.bufPrint(&buf, "<ol start=\"{d}\">", .{ol_detail.start});
                    try ctx.writeOpen(ol_tag);
                }
            },
            c.MD_BLOCK_LI => {
                const li_detail = @as(*const c.MD_BLOCK_LI_DETAIL, @ptrCast(@alignCast(detail)));
                if (li_detail.is_task != 0) {
                    // TODO: this really have no length limit
                    var ol_buf: [4096]u8 = undefined;
                    const checked: []const u8 = if (li_detail.task_mark == 'x' or li_detail.task_mark == 'X') "checked" else "";
                    const li_tag = try std.fmt.bufPrint(&ol_buf, "<li class=\"task-list-item\"><input type=\"checkbox\" class=\"task-list-item-checkbox\" disabled {s}>", .{checked});
                    try ctx.writeOpen(li_tag);
                } else {
                    try ctx.writeOpen("<li>");
                }
            },
            c.MD_BLOCK_HR => try ctx.writeIndented("<hr>\n"),
            c.MD_BLOCK_H => {
                const h_detail = @as(*const c.MD_BLOCK_H_DETAIL, @ptrCast(@alignCast(detail)));
                const level = h_detail.level;
                if (level >= 1 and level <= 6) {
                    try ctx.writeOpen(headers_openning_tags[level - 1]);
                }
            },
            c.MD_BLOCK_CODE => {
                const code_detail = @as(*const c.MD_BLOCK_CODE_DETAIL, @ptrCast(@alignCast(detail)));
                try ctx.writeOpen("<pre>");
                try ctx.writeIndented("<code");

                if (code_detail.lang.text != null and code_detail.lang.size > 0) {
                    try ctx.write(" class=\"language-");
                    try ctx.renderHtmlEscaped(code_detail.lang.text[0..code_detail.lang.size]);
                    try ctx.write("\"");
                }

                try ctx.write(">\n");
                // TODO: handle in writer
                ctx.current_level += 1;
            },
            c.MD_BLOCK_P => try ctx.writeOpen("<p>"),
            c.MD_BLOCK_TABLE => try ctx.writeOpen("<table>"),
            c.MD_BLOCK_THEAD => try ctx.writeOpen("<thead>"),
            c.MD_BLOCK_TBODY => try ctx.writeOpen("<tbody>"),
            c.MD_BLOCK_TR => try ctx.writeOpen("<tr>"),
            c.MD_BLOCK_TH => {
                const header_detail = @as(*const c.MD_BLOCK_TD_DETAIL, @ptrCast(@alignCast(detail)));
                try ctx.writeIndented("<th");

                const alignment = @field(header_detail, "align");
                if (alignment != c.MD_ALIGN_DEFAULT) {
                    try ctx.write(" align=\"");

                    switch (alignment) {
                        c.MD_ALIGN_LEFT => try ctx.write("left"),
                        c.MD_ALIGN_CENTER => try ctx.write("center"),
                        c.MD_ALIGN_RIGHT => try ctx.write("right"),
                        else => {},
                    }

                    try ctx.write("\"");
                }

                try ctx.write(">\n");
                // TODO: handle in writer
                ctx.current_level += 1;
            },
            c.MD_BLOCK_TD => {
                const cell_detail = @as(*const c.MD_BLOCK_TD_DETAIL, @ptrCast(@alignCast(detail)));
                try ctx.writeIndented("<td");

                const alignment = @field(cell_detail, "align");
                if (alignment != c.MD_ALIGN_DEFAULT) {
                    try ctx.write(" align=\"");

                    switch (alignment) {
                        c.MD_ALIGN_LEFT => try ctx.write("left"),
                        c.MD_ALIGN_CENTER => try ctx.write("center"),
                        c.MD_ALIGN_RIGHT => try ctx.write("right"),
                        else => {},
                    }

                    try ctx.write("\"");
                }

                try ctx.write(">\n");
                ctx.current_level += 1;
            },
            else => {},
        }
    }

    fn leave_block(blk: c.MD_BLOCKTYPE, detail: ?*anyopaque, userdata: ?*anyopaque) callconv(.C) c_int {
        const ctx = @as(*RenderContext, @ptrCast(@alignCast(userdata)));
        leave_block_impl(blk, detail, ctx) catch return 1;
        return 0;
    }

    fn leave_block_impl(blk: c.MD_BLOCKTYPE, detail: ?*anyopaque, ctx: *RenderContext) !void {
        const headers_closing_tags: [6][]const u8 = .{
            "</h1>",
            "</h2>",
            "</h3>",
            "</h4>",
            "</h5>",
            "</h6>",
        };

        switch (blk) {
            c.MD_BLOCK_DOC => {},
            c.MD_BLOCK_QUOTE => try ctx.writeClose("</blockquote>"),
            c.MD_BLOCK_UL => try ctx.writeClose("</ul>"),
            c.MD_BLOCK_OL => try ctx.writeClose("</ol>"),
            c.MD_BLOCK_LI => try ctx.writeClose("</li>"),
            c.MD_BLOCK_HR => {},
            c.MD_BLOCK_H => {
                const h_detail = @as(*const c.MD_BLOCK_H_DETAIL, @ptrCast(@alignCast(detail)));
                const level = h_detail.level;
                if (level >= 1 and level <= 6) {
                    try ctx.writeClose(headers_closing_tags[level - 1]);
                }
            },
            c.MD_BLOCK_CODE => {
                try ctx.writeClose("</code>");
                try ctx.writeClose("</pre>\n");
            },
            c.MD_BLOCK_P => try ctx.writeClose("</p>"),
            c.MD_BLOCK_TABLE => try ctx.writeClose("</table>"),
            c.MD_BLOCK_THEAD => try ctx.writeClose("</thead>"),
            c.MD_BLOCK_TBODY => try ctx.writeClose("</tbody>"),
            c.MD_BLOCK_TR => try ctx.writeClose("</tr>"),
            c.MD_BLOCK_TH => try ctx.writeClose("</th>"),
            c.MD_BLOCK_TD => try ctx.writeClose("</td>"),
            else => {},
        }
    }

    fn enter_span(span: c.MD_SPANTYPE, detail: ?*anyopaque, userdata: ?*anyopaque) callconv(.C) c_int {
        const ctx = @as(*RenderContext, @ptrCast(@alignCast(userdata)));
        enter_span_impl(span, detail, ctx) catch return 1;
        return 0;
    }

    fn enter_span_impl(span: c.MD_SPANTYPE, detail: ?*anyopaque, ctx: *RenderContext) !void {
        switch (span) {
            c.MD_SPAN_EM => try ctx.write("<em>"),
            c.MD_SPAN_STRONG => try ctx.write("<strong>"),
            c.MD_SPAN_A => {
                const a_detail = @as(*const c.MD_SPAN_A_DETAIL, @ptrCast(@alignCast(detail)));
                const href = a_detail.href.text[0..a_detail.href.size];
                try ctx.write("<a href=\"");
                try ctx.renderUrlEscaped(href);

                const has_title = a_detail.title.text != null and a_detail.title.size > 0;
                if (has_title) {
                    try ctx.write("\" title=\"");
                    try ctx.renderHtmlEscaped(a_detail.title.text[0..a_detail.title.size]);
                }

                try ctx.write("\">");

                // TODO: do not add links for ignored pages
                if (ctx.cur_link_url == null) {
                    var page_link = href;
                    if (mem.startsWith(u8, href, "/")) page_link = page_link[1..];
                    if (mem.endsWith(u8, href, ".md")) page_link = page_link[0 .. page_link.len - 3];
                    if (ctx.graph.pages.contains(page_link)) {
                        log.debug("Markdown link to note page {s} from {s}\n", .{ page_link, ctx.cur_page });
                        ctx.cur_link_url = page_link;
                    }
                }
            },
            c.MD_SPAN_IMG => {
                ctx.image_nesting_level += 1;

                const img_detail = @as(*const c.MD_SPAN_IMG_DETAIL, @ptrCast(@alignCast(detail)));
                try ctx.write("<img src=\"");
                try ctx.renderUrlEscaped(img_detail.src.text[0..img_detail.src.size]);

                if (img_detail.title.text != null and img_detail.title.size > 0) {
                    try ctx.write("\" title=\"");
                    try ctx.renderHtmlEscaped(img_detail.title.text[0..img_detail.title.size]);
                }

                try ctx.write("\" alt=\"");
            },
            c.MD_SPAN_CODE => try ctx.write("<code>"),
            c.MD_SPAN_DEL => try ctx.write("<del>"),
            c.MD_SPAN_U => try ctx.write("<u>"),
            c.MD_SPAN_LATEXMATH => try ctx.write("<x-equation>"),
            c.MD_SPAN_LATEXMATH_DISPLAY => try ctx.write("<x-equation type=\"display\">"),
            c.MD_SPAN_WIKILINK => {
                // TODO: do not add links for ignored pages
                const wikilink_detail = @as(*const c.MD_SPAN_WIKILINK_DETAIL, @ptrCast(@alignCast(detail)));
                const target = wikilink_detail.target;
                try ctx.write("<a href=\"");
                try ctx.renderUrlEscaped(target.text[0..target.size]);
                try ctx.write(".html\">");
                ctx.cur_link_url = target.text[0..target.size];
            },
            else => {},
        }
    }

    fn leave_span(span: c.MD_SPANTYPE, detail: ?*anyopaque, userdata: ?*anyopaque) callconv(.C) c_int {
        const ctx = @as(*RenderContext, @ptrCast(@alignCast(userdata)));
        leave_span_impl(span, detail, ctx) catch return 1;
        return 0;
    }

    fn leave_span_impl(span: c.MD_SPANTYPE, detail: ?*anyopaque, ctx: *RenderContext) !void {
        _ = detail;

        switch (span) {
            c.MD_SPAN_EM => try ctx.write("</em>"),
            c.MD_SPAN_STRONG => try ctx.write("</strong>"),
            c.MD_SPAN_A => {
                try ctx.write("</a>");
                if (ctx.cur_link_url) |link_url| {
                    const link_text = try ctx.cur_link_text.toOwnedSlice();
                    const link = Page.Link{
                        .link = link_url,
                        .text = link_text,
                    };
                    try ctx.graph.addLink(ctx.cur_page, link);
                    ctx.cur_link_url = null;
                }
            },
            c.MD_SPAN_IMG => {
                try ctx.write("\"");
                try ctx.write(">");
                ctx.image_nesting_level -= 1;
            },
            c.MD_SPAN_CODE => try ctx.write("</code>"),
            c.MD_SPAN_DEL => try ctx.write("</del>"),
            c.MD_SPAN_U => try ctx.write("</u>"),
            c.MD_SPAN_LATEXMATH => try ctx.write("</x-equation>"),
            c.MD_SPAN_LATEXMATH_DISPLAY => try ctx.write("</x-equation>"),
            c.MD_SPAN_WIKILINK => {
                try ctx.write("</a>");
                if (ctx.cur_link_url) |link_url| {
                    const link_text = try ctx.cur_link_text.toOwnedSlice();
                    const wikilink = Page.Link{
                        .link = link_url,
                        .text = link_text,
                    };
                    try ctx.graph.addLink(ctx.cur_page, wikilink);
                    ctx.cur_link_url = null;
                }
            },
            else => {},
        }
    }

    fn text(type_val: c.MD_TEXTTYPE, text_data: [*c]const c.MD_CHAR, size: c.MD_SIZE, userdata: ?*anyopaque) callconv(.C) c_int {
        const ctx = @as(*RenderContext, @ptrCast(@alignCast(userdata)));
        text_impl(type_val, text_data, size, ctx) catch return 1;
        return 0;
    }

    fn text_impl(type_val: c.MD_TEXTTYPE, text_data: [*c]const c.MD_CHAR, size: c.MD_SIZE, ctx: *RenderContext) !void {
        // Skip image alt text rendering when inside an image, as it's handled separately
        if (ctx.image_nesting_level > 0 and type_val != c.MD_TEXT_NULLCHAR) {
            return;
        }

        const data = text_data[0..size];

        if (ctx.cur_link_url != null) {
            try ctx.cur_link_text.appendSlice(data);
        }

        try ctx.renderText(type_val, data);
    }
};

/// Read file from disk, parse metadata and add to graph
fn processFile(allocator: mem.Allocator, file_path: []const u8, graph: *PageGraph, config: *Config) !void {
    const full_path = try std.fs.path.join(allocator, &[_][]const u8{ config.input_path, file_path });
    const file = std.fs.cwd().openFile(full_path, .{}) catch |err| {
        log.err("Failed to read {s}, skipping\n", .{full_path});
        return err;
    };
    defer allocator.free(full_path);

    const file_size = try file.getEndPos();
    print("Processing {s} ({d}b)\n", .{ file_path, file_size });
    const buf = try allocator.alloc(u8, file_size);
    errdefer allocator.free(buf);
    _ = try file.readAll(buf);

    const page = try Page.init(allocator, file_path, buf);

    try graph.addPage(page);

    defer file.close();
}

const Config = struct {
    input_path: []const u8, // Default to current directory
    output_path: []const u8,
    is_debug: bool = false,
};

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const allocator = arena.allocator();
    defer arena.deinit();

    var config = Config{
        .input_path = ".",
        .output_path = "topaz-out",
        .is_debug = false,
    };

    const args = try std.process.argsAlloc(allocator);
    // Parse the command line arguments. Config arguments that take a value
    // must use '='. The first non-flag argument is treated as input source.
    // TODO: add support for list of inputs
    var found_input = false;
    for (args[1..]) |arg| {
        if (!mem.startsWith(u8, arg, "--")) {
            if (!found_input) {
                config.input_path = arg;
                found_input = true;
            }
        } else if (mem.startsWith(u8, arg, "--out=")) {
            config.output_path = arg[6..];
        } else if (mem.eql(u8, arg, "--debug")) {
            config.is_debug = true;
        }
    }

    var input_files = std.ArrayList([]const u8).init(allocator);
    defer input_files.deinit();

    const stat = try std.fs.cwd().statFile(config.input_path);

    // Collect all .md files from dirs
    if (stat.kind == .directory) {
        var dir = try std.fs.cwd().openDir(config.input_path, .{ .iterate = true });
        defer dir.close();
        var walker = try dir.walk(allocator);

        while (try walker.next()) |entry| {
            if (entry.kind == .file and mem.eql(u8, std.fs.path.extension(entry.basename), ".md")) {
                const path = try allocator.dupe(u8, entry.path);
                try input_files.append(path);
            }
        }
    } else if (stat.kind == .file and mem.eql(u8, std.fs.path.extension(config.input_path), ".md")) {
        // Collect individual input files
        try input_files.append(config.input_path);
    }

    var parser = try Parser.init();

    // Create output directory
    const dest_dir = std.fs.path.resolve(allocator, &[_][]const u8{config.output_path}) catch |err| {
        std.log.err("Failed to resolve dest path: {any}\n", .{err});
        return err;
    };
    std.log.info("Out dir is \"{s}\"\n", .{config.output_path});
    try std.fs.cwd().makePath(dest_dir);

    // Process files
    var graph = try PageGraph.init(allocator);
    var contexts = std.ArrayList(RenderContext).init(allocator);

    // First pass: read files into memory and parse metadata
    for (input_files.items) |path| {
        try processFile(allocator, path, &graph, &config);
        const page_name = path[0 .. path.len - 3];
        var ctx = try RenderContext.init(allocator, &graph);
        ctx.cur_page = page_name;
        try contexts.append(ctx);
    }

    // Second pass: parse markdown and index blocks/links
    for (graph.page_list.items, 0..) |*page, i| {
        if (page.meta.skip) continue;
        try contexts.items[i].writeHtmlHead(page.meta.title);
        parser.parse(page.markdown, &contexts.items[i]);
    }

    // Third pass: write to disk
    for (graph.page_list.items, 0..) |*page, i| {
        if (page.meta.skip) continue;
        log.debug("Writing {s}\n", .{page.out_path});
        var ctx = &contexts.items[i];
        try ctx.writeFooter();
        try ctx.writeHtmlTail();

        const dir_path = if (std.fs.path.dirname(page.out_path)) |dir|
            try std.fs.path.join(allocator, &[_][]const u8{ config.output_path, dir })
        else
            config.output_path;

        const out_path = try std.fs.path.join(allocator, &[_][]const u8{ config.output_path, page.out_path });
        try std.fs.cwd().makePath(dir_path);
        const dest_file = try std.fs.cwd().createFile(out_path, .{});
        defer dest_file.close();
        const fw = dest_file.writer();
        _ = try fw.writeAll(ctx.buf.items);
    }
}

// test "simple test" {
//     var list = std.ArrayList(i32).init(std.testing.allocator);
//     defer list.deinit(); // Try commenting this out and see if zig detects the memory leak!
//     try list.append(42);
//     try std.testing.expectEqual(@as(i32, 42), list.pop());
// }

// test "fuzz example" {
//     // Try passing `--fuzz` to `zig build` and see if it manages to fail this test case!
//     const input_bytes = std.testing.fuzzInput(.{});
//     try std.testing.expect(!mem.eql(u8, "canyoufindme", input_bytes));
// }
