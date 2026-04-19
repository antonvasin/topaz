const std = @import("std");
const assert = std.debug.assert;
const graph = @import("./graph.zig");
const PageGraph = graph.PageGraph;
const Page = graph.Page;
const log = @import("./utils.zig").log;
const c = @cImport({
    @cInclude("md4c.h");
});

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
        if (self.buf.getLastOrNull()) |last_char| {
            if (last_char == '\n') try self.indent();
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
        const title = try std.fmt.bufPrint(&title_buf, "<title>{s}</title>", .{page_title});
        try self.writeString(title);

        try self.writeClose("</head>");
        try self.writeOpen("<body>");
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

    pub fn renderText(self: *RenderContext, text_type: c.MD_TEXTTYPE, data: []const u8) !void {
        if (self.buf.getLastOrNull()) |last_char|
            if (last_char == '\n') try self.indent();

        switch (text_type) {
            c.MD_TEXT_NULLCHAR => try self.renderUtf8Codepoint(0),
            c.MD_TEXT_HTML => try self.writeString(data),
            c.MD_TEXT_ENTITY => try self.renderEntity(data),
            c.MD_TEXT_CODE => try self.writeString(data),
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
};
