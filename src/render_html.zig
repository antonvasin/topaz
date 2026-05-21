const std = @import("std");
const assert = std.debug.assert;
const c = @cImport({
    @cInclude("md4c.h");
});
const graph = @import("./graph.zig");
const PageGraph = graph.PageGraph;
const parser = @import("./parse_html.zig");
const Document = parser.Document;
const Element = parser.Element;
const Page = graph.Page;
const log = @import("./utils.zig").log;

/// Incrementally builds HTML string with correct indentation.
/// Caller should not care about neither indentation nor newlines.
///
/// Calling this code:
///
///     try ctx.writeOpen("<p>");
///     try ctx.writeString("Paragraph text");
///     try ctx.writeString("<img src=\"\" />");
///     try ctx.writeOpen("<ul>");
///     try ctx.writeOpen("<li>");
///     try ctx.writeString("List item");
///     try ctx.writeClose("</li>");
///     try ctx.writeClose("</ul>");
///     try ctx.writeClose("</p>");
///
/// Produces this markup
///
///     <p>
///         Paragraph text <img src="..." />
///         <ul>
///             <li>
///                 List item
///             </li>
///             <li>
///                 List item
///             </li>
///         </ul>
///     </p>
pub const RenderContext = struct {
    allocator: std.mem.Allocator,
    buf: std.ArrayList(u8),

    graph: *PageGraph,
    cur_page: []const u8 = undefined,

    image_nesting_level: u32 = 0,
    current_level: u32 = 0,

    // For building internal links incrementally
    // TODO: move to Parser
    cur_link_url: ?[]const u8 = null,
    cur_link_text: std.ArrayList(u8),

    cur_header_text: std.ArrayList(u8),
    cur_header_level: ?Page.HeaderLevel = null,

    cur_code_block_lang: ?[]const u8 = null,

    template: ?Template = null,

    pub fn init(allocator: std.mem.Allocator, page_graph: *PageGraph) !RenderContext {
        const buf = std.ArrayList(u8).empty;
        const link_text = std.ArrayList(u8).empty;
        const header_text = std.ArrayList(u8).empty;

        return .{
            .buf = buf,
            .allocator = allocator,
            .graph = page_graph,
            .cur_link_text = link_text,
            .cur_header_text = header_text,
        };
    }

    pub fn deinit(self: *RenderContext) void {
        self.buf.deinit(self.allocator);
        self.cur_link_text.deinit(self.allocator);
        self.cur_header_text.deinit(self.allocator);
    }

    /// Write text as is
    pub fn write(self: *RenderContext, str: []const u8) !void {
        try self.buf.appendSlice(self.allocator, str);
    }

    /// Write string with indentation
    pub fn writeString(self: *RenderContext, str: []const u8) !void {
        if (self.cur_code_block_lang == null) {
            if (self.buf.getLastOrNull() == '\n') try self.indent();
        }
        // TODO: write to buffer automatically when calling from header tags
        try self.write(str);
    }

    fn indent(self: *RenderContext) !void {
        for (0..self.current_level) |_| try self.write("    ");
    }

    /// Write openning tag with indentation and newline
    pub fn writeOpen(self: *RenderContext, str: []const u8) !void {
        if (self.buf.getLastOrNull()) |last_char| {
            if (last_char != '\n') {
                try self.write("\n");
                try self.indent();
            }
            if (last_char == '\n') try self.indent();
        }

        try self.write(str);
        try self.write("\n");
        self.current_level += 1;
    }

    /// Write closing tag with indentation and newline
    pub fn writeClose(self: *RenderContext, str: []const u8) !void {
        assert(self.current_level > 0);
        if (self.current_level > 0) self.current_level -= 1 else log.warn("Lost indentation {s}\n", .{str});
        if (self.buf.getLastOrNull()) |last_char| {
            if (last_char != '\n') {
                try self.write("\n");
                try self.indent();
            }
            if (last_char == '\n') try self.indent();
        }
        try self.write(str);
        try self.write("\n");
    }

    pub fn writeHtmlHead(self: *RenderContext, page_title: []const u8) !void {
        if (self.template) |tmpl| {
            try tmpl.doc.titleSet(page_title);
            try tmpl.addCharset();
            _ = try tmpl.addMeta("generator", "topaz");
        }
    }

    pub fn writeContents(self: *const RenderContext) !void {
        if (self.template) |tmpl| {
            try tmpl.writeContents(self.buf.items);
        }
    }

    pub fn writeHtmlTail(self: *RenderContext) !void {
        try self.writeClose("</body>");
        try self.writeClose("</html>");
    }

    pub fn writeTableOfContents(self: *RenderContext) !void {
        try self.writeOpen("<section>");
        try self.writeString("<h3>Table of contents");
        try self.writeOpen("<ol>");
        const headers_list = self.graph.headers_lists.get(self.cur_page) orelse return error.MissingHeaders;
        for (headers_list.items) |header_id| {
            const header = self.graph.headers.get(header_id) orelse return error.MissingHeaders;
            try self.writeOpen("<li>");
            try self.writeString("<a href=\"#");
            try self.writeString(header.id);
            try self.writeString("\">");
            try self.writeString(header.text);
            try self.writeString("</a>");
            try self.writeClose("</li>");
        }
        try self.writeClose("</ol>");
        try self.writeClose("</section>");
    }

    pub fn writeFooter(self: *RenderContext) !void {
        const page = self.cur_page;
        const forward_links = self.graph.forward.get(page) orelse return error.MissingLinks;

        try self.writeOpen("<footer>");
        try self.writeTableOfContents();
        if (forward_links.count() > 0) {
            try self.writeString("<h3>Forward Links</h3>");
            try self.writeOpen("<ul>");
            var iterator = forward_links.valueIterator();
            while (iterator.next()) |link| {
                try self.writeOpen("<li>");

                try self.writeString("<a href=\"/");
                try self.renderUrlEscaped(link.link);
                try self.writeString(".html\">");
                try self.writeString(link.text);
                try self.writeString("</a>\n");

                try self.writeClose("</li>");
            }
            try self.writeClose("</ul>");
        }

        const backward_links = self.graph.backward.get(page);
        if (backward_links) |links| {
            if (links.count() > 0) {
                try self.writeString("<h3>Back Links</h3>");
                try self.writeOpen("<ul>");
                var iterator = links.valueIterator();
                while (iterator.next()) |link| {
                    try self.writeOpen("<li>");

                    try self.writeString("<a href=\"/");
                    try self.renderUrlEscaped(link.link);
                    try self.writeString(".html\">");
                    try self.writeString(link.text);
                    try self.writeString("</a>\n");
                    try self.writeClose("</li>");
                }
                try self.writeClose("</ul>");
            }
        }
        try self.writeClose("</footer>");
    }

    pub fn serialize(self: *const RenderContext) ![]const u8 {
        if (self.template) |tmpl| {
            const str = try tmpl.doc.serialize();
            return str.toSlice();
        }
        return error.Template;
    }

    pub fn renderText(self: *RenderContext, text_type: c.MD_TEXTTYPE, data: []const u8) !void {
        if (self.cur_code_block_lang == null) {
            if (self.buf.getLastOrNull() == '\n') try self.indent();
        }

        switch (text_type) {
            c.MD_TEXT_NULLCHAR => try self.renderUtf8Codepoint(0),
            c.MD_TEXT_HTML => try self.writeString(data),
            c.MD_TEXT_ENTITY => try self.renderEntity(data),
            c.MD_TEXT_CODE => try self.renderHtmlEscaped(data),
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
        try self.writeString(data);
    }

    pub fn renderHtmlEscaped(self: *RenderContext, data: []const u8) !void {
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

    pub fn renderUrlEscaped(self: *RenderContext, data: []const u8) !void {
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
                try self.buf.append(self.allocator, char);
            } else if (char == '&') {
                try self.write("&amp;");
            } else {
                try self.buf.writer(self.allocator).print("%{X:0>2}", .{char});
            }
        }
    }

    pub fn renderUtf8Codepoint(self: *RenderContext, codepoint: u32) !void {
        var buf: [4]u8 = undefined;
        const len = try std.unicode.utf8Encode(@intCast(codepoint), &buf);
        try self.write(buf[0..len]);
    }

    pub fn renderAttribute(self: *RenderContext, attr: *const c.MD_ATTRIBUTE) !void {
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

    pub fn setTemplate(self: *RenderContext, html: []const u8) !void {
        self.template = try Template.init(html);
    }
};

// - create Document
// - find <head>
// - collect <template> tags
// - find <body>
//
//  - setTitle()
//  - setDescription()
//  - setOgTags()
//  - addJs()
//  - addCss()
//  - addChild()
//
//  data- attributes (slots):
//    data-topaz-title
//    data-topaz-description
//    data-topaz-body
//    data-topaz-backlinks
//    data-topaz-forwardlinks
//    data-topaz-table-of-contents
//
//  components (<templates>s):
//    topaz-body
//    topaz-backlinks
//    topaz-forwardlinks
//    topaz-table-of-contents

/// Parses HTML template and uses it to build resulting document
pub const Template = struct {
    content: []const u8,
    tmpl: Document,
    doc: Document,
    content_tmpl: ?Element,

    pub fn init(html: []const u8) !Template {
        const tmpl = try Document.parse(html);
        const doc = try Document.init();
        doc.setDoctype();

        const doc_head = doc.head().toNode();
        const doc_body = doc.body().toNode();

        // Clone <head>
        const tmpl_head = tmpl.head().toNode();
        var cur_child_node = tmpl_head.firstChild();
        while (cur_child_node) |node| {
            const clone = doc.importNode(node);
            try doc_head.appendChild(clone);
            cur_child_node = node.next();
        }

        // Clone <body>
        const tmpl_body = tmpl.body();
        cur_child_node = tmpl_body.toNode().firstChild();
        while (cur_child_node) |node| {
            const clone = doc.importNode(node);
            try doc_body.appendChild(clone);
            cur_child_node = node.next();
        }

        var content_tmpl: ?Element = null;
        var content_tmpl_col = try doc.findByAttr(doc.body(), "data-topaz-body", "");
        defer content_tmpl_col.deinit();
        if (content_tmpl_col.len() > 0) content_tmpl = content_tmpl_col.items()[0];

        return .{
            .tmpl = tmpl,
            .content = html,
            .doc = doc,
            .content_tmpl = content_tmpl,
        };
    }

    /// Sets content of or creates `<meta name="description" />` tag
    pub fn setDescription(self: *const Template, text: []const u8) !void {
        const name = "description";
        var meta_tags = try self.doc.findByTag(self.doc.head(), "meta");
        defer meta_tags.deinit();
        var description: ?Element = null;
        for (meta_tags.items()) |el| {
            if (std.mem.eql(u8, el.getAttribute("name"), name)) description = el;
        }

        if (description) |desc| {
            try desc.setAttribute("content", text);
        } else {
            _ = try self.addMeta(name, text);
        }
    }

    pub fn addMeta(self: *const Template, name: []const u8, content: []const u8) !Element {
        const meta = try self.doc.createElement("meta");
        try meta.setAttribute("name", name);
        try meta.setAttribute("content", content);
        try self.doc.head().toNode().appendChild(meta.toNode());
        return meta;
    }

    pub fn addCharset(self: *const Template) !void {
        var has_charset = false;
        var meta_tags = try self.doc.findByTag(self.doc.head(), "meta");
        defer meta_tags.deinit();
        for (meta_tags.items()) |el| {
            if (el.hasAttrbitue("charset")) {
                has_charset = true;
                break;
            }
        }

        if (!has_charset) {
            const meta = try self.doc.createElement("meta");
            try meta.setAttribute("charset", "utf-8");
            try self.doc.head().toNode().appendChild(meta.toNode());
        }
    }

    pub fn writeContents(self: *const Template, contents: []const u8) !void {
        const root = self.content_tmpl orelse self.doc.body();
        try self.doc.importFragment(root, contents);
    }

    pub fn deinit(self: *Template) void {
        self.tmpl.deinit();
        self.doc.deinit();
    }
};

test "RenderContext serialize" {
    const allocator = std.testing.allocator;

    var page_graph = try PageGraph.init(allocator);
    var ctx = try RenderContext.init(allocator, &page_graph);
    try ctx.setTemplate("");
    defer ctx.deinit();

    try ctx.writeHtmlHead("Page Title");
    try ctx.writeOpen("<h1>");
    try ctx.writeString("Page ");
    try ctx.writeString("<em>");
    try ctx.writeString("Title");
    try ctx.writeString("</em>");
    try ctx.writeClose("</h1>");
    try ctx.writeOpen("<p>");
    try ctx.writeString("Paragraph text.");
    try ctx.writeClose("</p>");
    try ctx.writeOpen("<ul>");
    for (0..3) |_| {
        try ctx.writeOpen("<li>");
        try ctx.writeString("List item");
        try ctx.writeClose("</li>");
    }
    try ctx.writeClose("</ul>");
    try ctx.writeContents();

    // const buf =
    //     \\<!DOCTYPE html>
    //     \\<html>
    //     \\<head>
    //     \\    <title>Page Title</title>
    //     \\    <meta name="generator" content="topaz">
    //     \\</head>
    //     \\<body>
    //     \\    <h1>
    //     \\        Page <em>Title</em>
    //     \\    </h1>
    //     \\    <p>
    //     \\        Paragraph text.
    //     \\    </p>
    //     \\    <ul>
    //     \\        <li>
    //     \\            List item
    //     \\        </li>
    //     \\        <li>
    //     \\            List item
    //     \\        </li>
    //     \\        <li>
    //     \\            List item
    //     \\        </li>
    //     \\    </ul>
    //     \\</body>
    //     \\</html>
    //     \\
    // ;

    // FIXME: pretty print
    const res =
        \\<!DOCTYPE html><html><head><title>Page Title</title><meta charset="utf-8"><meta name="generator" content="topaz"></head><body><h1>
        \\    Page <em>Title</em></h1><p>
        \\    Paragraph text.
        \\</p><ul><li>
        \\        List item
        \\    </li><li>
        \\        List item
        \\    </li><li>
        \\        List item
        \\    </li></ul></body></html>
    ;

    const str = try ctx.serialize();
    try std.testing.expectEqualStrings(res, str);
}

const html_tmpl_input =
    \\<!doctype html>
    \\<html>
    \\<head><title>Hello world!</title></head>
    \\<body>Hello</body>
    \\</html>
;

test "set title" {
    var tmpl = try Template.init(html_tmpl_input);
    defer tmpl.deinit();
    try tmpl.doc.titleSet("New Title");
    try std.testing.expectEqualStrings("<title>New Title</title>", try tmpl.doc.head().serialize());
}

test "set description" {
    var tmpl = try Template.init(html_tmpl_input);
    defer tmpl.deinit();
    try tmpl.setDescription("New Description");
    try std.testing.expectEqualStrings(
        "<title>Hello world!</title><meta name=\"description\" content=\"New Description\">",
        try tmpl.doc.head().serialize(),
    );
}

test "update description" {
    const html_tmpl_with_title =
        \\<!doctype html>
        \\<html>
        \\<head><title>Hello world!</title><meta name="description" content="Old Description" /></head>
        \\<body>Hello</body>
        \\</html>
    ;
    var tmpl = try Template.init(html_tmpl_with_title);
    defer tmpl.deinit();
    try tmpl.setDescription("New Description");
    try std.testing.expectEqualStrings(
        "<title>Hello world!</title><meta name=\"description\" content=\"New Description\">",
        try tmpl.doc.head().serialize(),
    );
}

test "content template" {
    const html_tmpl_with_title =
        \\<!doctype html>
        \\<html>
        \\<head><title>Hello world!</title><meta name="description" content="Old Description" /></head>
        \\<body>Hello<main data-topaz-body></main></body>
        \\</html>
    ;
    var tmpl = try Template.init(html_tmpl_with_title);
    defer tmpl.deinit();
    try tmpl.setDescription("New Description");
    try tmpl.writeContents("content");
    try std.testing.expectEqualStrings(
        "Hello<main data-topaz-body=\"\">content</main>",
        try tmpl.doc.body().serialize(),
    );
}
