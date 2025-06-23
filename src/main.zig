const std = @import("std");
const builtin = @import("builtin");
const c = @cImport({
    @cInclude("md4c.h");
});

const print = std.debug.print;
const mem = std.mem;
const assert = std.debug.assert;

const Page = struct {
    path: []const u8,
    meta: Meta,

    // https://help.obsidian.md/properties
    // https://help.obsidian.md/publish/seo#Metadata
    // https://help.obsidian.md/publish/permalinks
    // https://docs.github.com/en/contributing/writing-for-github-docs/using-yaml-frontmatter
    const Meta = struct {
        title: []const u8,
        url: ?[]const u8,
        date: ?[]const u8 = null,
        skip: bool = false,
    };

    const Link = struct {
        link: []const u8,
        text: ?[]const u8 = null,
    };
};

const LinkValues = std.StringHashMap(Page.Link);
const Links = std.StringHashMap(LinkValues);

///  Stores relationships between Pages
const PageGraph = struct {
    allocator: std.mem.Allocator,
    pages: std.StringHashMap(Page),
    ///  What links page have
    forward: Links,
    //  Who links to that page
    // backward: Links,

    pub fn init(allocator: std.mem.Allocator) !PageGraph {
        const pages = std.StringHashMap(Page).init(allocator);
        const forward = Links.init(allocator);

        return .{
            .allocator = allocator,
            .pages = pages,
            .forward = forward,
        };
    }

    pub fn deinit(self: *PageGraph) void {
        self.pages.deinit();
        self.forward.deinit();
        // self.backward.deinit();
    }

    pub fn addPage(self: *PageGraph, page: Page) !void {
        try self.pages.put(page.path, page);

        try self.forward.put(page.path, std.StringHashMap(Page.Link).init(self.allocator));
    }

    pub fn addLink(self: *PageGraph, page: Page, link: Page.Link) !void {
        if (!self.pages.contains(page.path)) try self.addPage(page);
        var forward_links_ptr = self.forward.getPtr(page.path) orelse return error.LinksNotFound;
        // TODO: we probably want to use real hashing function here
        const id = try std.fmt.allocPrint(self.allocator, "{s}{s}{any}", .{ page.path, link.link, link.text });
        try forward_links_ptr.put(id, link);
    }
};

/// Context for building HTML string inside md4c callbacks
const RenderContext = struct {
    allocator: mem.Allocator,
    buf: std.ArrayList(u8),
    image_nesting_level: u32 = 0,
    current_level: u32 = 0,

    cur_wikilink_link: ?Page.Link = null,

    graph: PageGraph,
    cur_page: ?Page = null,

    pub fn init(allocator: mem.Allocator, graph: PageGraph) !RenderContext {
        const buf = std.ArrayList(u8).init(allocator);

        return .{
            .buf = buf,
            .allocator = allocator,
            .graph = graph,
        };
    }

    pub fn deinit(self: *RenderContext) void {
        self.buf.deinit();
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
        const page = self.cur_page orelse unreachable;
        const links = self.graph.forward.get(page.path) orelse return error.MissingLinks;

        if (links.count() > 0) {
            try self.writeOpen("<footer>");
            try self.writeIndented("<h3>Outcoming Links</h3>\n");
            try self.writeOpen("<ul>");
            var iterator = links.valueIterator();
            while (iterator.next()) |link| {
                try self.writeOpen("<li>");

                try self.writeIndented("<a href=\"");
                try self.renderUrlEscaped(link.link);
                try self.write(".html\">");
                if (link.text) |link_text| {
                    try self.write(link_text);
                } else {
                    try self.write(link.link);
                }
                try self.write("</a>\n");
                try self.writeClose("</li>");
            }
            try self.writeClose("</ul>");
            try self.writeClose("</footer>");
        }
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
            // TODO: check if it's a link to a page, that this page exists and is not ignored and add .html
            const a_detail = @as(*const c.MD_SPAN_A_DETAIL, @ptrCast(@alignCast(detail)));
            try ctx.write("<a href=\"");
            try ctx.renderUrlEscaped(a_detail.href.text[0..a_detail.href.size]);

            if (a_detail.title.text != null and a_detail.title.size > 0) {
                try ctx.write("\" title=\"");
                try ctx.renderHtmlEscaped(a_detail.title.text[0..a_detail.title.size]);
            }

            try ctx.write("\">");
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
            // TODO: check if page exists and is not ignored
            const wikilink_detail = @as(*const c.MD_SPAN_WIKILINK_DETAIL, @ptrCast(@alignCast(detail)));
            const target = wikilink_detail.target;
            try ctx.write("<a href=\"");
            try ctx.renderUrlEscaped(target.text[0..target.size]);
            try ctx.write(".html\">");
            ctx.cur_wikilink_link = Page.Link{
                .link = try ctx.allocator.dupe(u8, target.text[0..target.size]),
            };
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
        c.MD_SPAN_A => try ctx.write("</a>"),
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
            if (ctx.cur_wikilink_link) |cur_wikilink| {
                if (ctx.cur_page) |cur_page| {
                    try ctx.graph.addLink(cur_page, cur_wikilink);
                }
                ctx.cur_wikilink_link = null;
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
    const data = text_data[0..size];

    // Skip image alt text rendering when inside an image, as it's handled separately
    if (ctx.image_nesting_level > 0 and type_val != c.MD_TEXT_NULLCHAR) {
        return;
    }

    if (ctx.cur_wikilink_link) |*wikilink| {
        if (wikilink.text == null) {
            wikilink.text = try ctx.allocator.dupe(u8, data);
        }
    }

    try ctx.renderText(type_val, data);
}

fn processFile(file: std.fs.File, name: []const u8, parser: *const c.MD_PARSER, ctx: *RenderContext) !void {
    const file_size = try file.getEndPos();
    var buf = try ctx.allocator.alloc(u8, file_size);
    errdefer ctx.allocator.free(buf);
    const bytes_read = try file.readAll(buf);
    var yaml_end: usize = 0;

    // Cutting out YAML frontmatter
    if (mem.startsWith(u8, buf, "---\n")) {
        var i: usize = 4;
        while (i < buf.len - 3) {
            // TODO: distinguish between YAML terminators and <hr />
            if (mem.eql(u8, buf[i .. i + 4], "\n---")) yaml_end = i + 4;
            i += 1;
        }
    }

    // if (yaml_end != 0) print("YAML found [0..{d}]\n", .{yaml_end});

    const page = Page{
        .path = name,
        .meta = .{
            .title = name,
            .skip = false,
            .url = name,
        },
    };

    try ctx.graph.addPage(page);
    ctx.cur_page = page;

    // Parse the markdown content
    try ctx.writeHtmlHead(page.meta.title);
    _ = c.md_parse(@ptrCast(&buf[yaml_end]), @intCast(bytes_read - yaml_end), parser, ctx);
    try ctx.writeFooter();
    try ctx.writeHtmlTail();
    defer ctx.allocator.free(buf);
    defer file.close();
}

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const allocator = arena.allocator();
    defer arena.deinit();

    var input_path: []const u8 = "."; // Default to current directory
    var output_path: []const u8 = "topaz-out";

    const args = try std.process.argsAlloc(allocator);
    // Parse the command line arguments. Config arguments that take a value
    // must use '='. The first non-flag argument is treated as input source.
    var found_input = false;
    for (args[1..]) |arg| {
        if (!mem.startsWith(u8, arg, "--")) {
            if (!found_input) {
                input_path = arg;
                found_input = true;
            }
        } else if (mem.startsWith(u8, arg, "--out=")) {
            output_path = arg[6..];
        }
    }

    var input_files = std.StringHashMap([]const u8).init(allocator);

    // Collect all .md files from dirs
    const stat = try std.fs.cwd().statFile(input_path);

    if (stat.kind == .directory) {
        var dir = try std.fs.cwd().openDir(input_path, .{ .iterate = true });
        defer dir.close();
        var walker = try dir.walk(allocator);

        while (try walker.next()) |entry| {
            if (entry.kind == .file and mem.eql(u8, std.fs.path.extension(entry.basename), ".md")) {
                const full_path = try std.fs.path.join(allocator, &[_][]const u8{ input_path, entry.path });
                const rel_path = try allocator.dupe(u8, entry.path);
                try input_files.put(full_path, rel_path);
            }
        }
        // Collect individual files
    } else if (stat.kind == .file and mem.eql(u8, std.fs.path.extension(input_path), ".md")) {
        try input_files.put(input_path, std.fs.path.basename(input_path));
    }

    const parser = c.MD_PARSER{
        .abi_version = 0,
        .flags = c.MD_FLAG_TABLES |
            c.MD_FLAG_TASKLISTS |
            c.MD_FLAG_WIKILINKS |
            c.MD_FLAG_LATEXMATHSPANS |
            c.MD_FLAG_PERMISSIVEAUTOLINKS |
            c.MD_FLAG_STRIKETHROUGH,
        .enter_block = enter_block,
        .leave_block = leave_block,
        .enter_span = enter_span,
        .leave_span = leave_span,
        .text = text,
        .debug_log = null,
        .syntax = null,
    };

    // Create output directory
    const dest_dir = std.fs.path.resolve(allocator, &[_][]const u8{output_path}) catch |err| {
        print("Failed to resolve dest path: {any}\n", .{err});
        return err;
    };
    print("Out dir is \"{s}\"\n", .{output_path});
    try std.fs.cwd().makePath(dest_dir);

    // Process files
    const graph = try PageGraph.init(allocator);

    var iter = input_files.iterator();
    while (iter.next()) |entry| {
        const file_path = entry.key_ptr.*;
        const relative_path = entry.value_ptr.*;

        const dir_part = std.fs.path.dirname(relative_path) orelse "";
        const dest_dir_full = if (dir_part.len > 0)
            try std.fs.path.join(allocator, &[_][]const u8{ output_path, dir_part })
        else
            output_path;

        try std.fs.cwd().makePath(dest_dir_full);

        const page_name = std.fs.path.stem(std.fs.path.basename(relative_path));
        const dest_filename = try std.fmt.allocPrint(allocator, "{s}.html", .{page_name});
        const dest_path = try std.fs.path.join(allocator, &[_][]const u8{ dest_dir_full, dest_filename });

        // Render HTMl
        var ctx = try RenderContext.init(allocator, graph);
        defer ctx.deinit();
        const file = try std.fs.cwd().openFile(file_path, .{});
        const file_stat = try file.stat();
        print("Processing {s} ({d}b)-> {s}\n", .{ file_path, file_stat.size, dest_path });
        try processFile(file, page_name, &parser, &ctx);

        const dest_file = try std.fs.cwd().createFile(dest_path, .{});
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
