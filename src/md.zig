const std = @import("std");
const mem = std.mem;
const c = @cImport({
    @cInclude("md4c.h");
});
const anyascii = @import("anyascii.zig");

const log = @import("./utils.zig").log;
const RenderContext = @import("./html.zig").RenderContext;
const Page = @import("./graph.zig").Page;

/// Wraps MD4C for markdown parsing with RenderContext
pub const Parser = struct {
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

    fn enter_block(blk: c.MD_BLOCKTYPE, detail: ?*anyopaque, userdata: ?*anyopaque) callconv(.c) c_int {
        const ctx = @as(*RenderContext, @ptrCast(@alignCast(userdata)));
        enter_block_impl(blk, detail, ctx) catch return 1;
        return 0;
    }

    fn enter_block_impl(blk: c.MD_BLOCKTYPE, detail: ?*anyopaque, ctx: *RenderContext) !void {
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
            c.MD_BLOCK_HR => try ctx.writeString("<hr>\n"),
            c.MD_BLOCK_H => {
                const h_detail = @as(*const c.MD_BLOCK_H_DETAIL, @ptrCast(@alignCast(detail)));
                const level = h_detail.level;

                // We only save the header level because we want to get full
                // text before writing tag with id attribute.
                if (ctx.cur_header_level == null) {
                    ctx.cur_header_level = Page.HeaderLevel.fromInt(@intCast(level));
                }
            },
            c.MD_BLOCK_CODE => {
                const code_detail = @as(*const c.MD_BLOCK_CODE_DETAIL, @ptrCast(@alignCast(detail)));
                try ctx.writeOpen("<pre>");
                try ctx.writeString("<code");

                if (code_detail.lang.text != null and code_detail.lang.size > 0) {
                    try ctx.writeString(" class=\"language-");
                    try ctx.renderHtmlEscaped(code_detail.lang.text[0..code_detail.lang.size]);
                    try ctx.writeString("\"");
                }

                try ctx.writeString(">");
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
                try ctx.writeString("<th");

                const alignment = @field(header_detail, "align");
                if (alignment != c.MD_ALIGN_DEFAULT) {
                    try ctx.writeString(" align=\"");

                    switch (alignment) {
                        c.MD_ALIGN_LEFT => try ctx.writeString("left"),
                        c.MD_ALIGN_CENTER => try ctx.writeString("center"),
                        c.MD_ALIGN_RIGHT => try ctx.writeString("right"),
                        else => {},
                    }

                    try ctx.writeString("\"");
                }

                try ctx.writeString(">\n");
                // TODO: handle in writer
                ctx.current_level += 1;
            },
            c.MD_BLOCK_TD => {
                const cell_detail = @as(*const c.MD_BLOCK_TD_DETAIL, @ptrCast(@alignCast(detail)));
                try ctx.writeString("<td");

                const alignment = @field(cell_detail, "align");
                if (alignment != c.MD_ALIGN_DEFAULT) {
                    try ctx.writeString(" align=\"");

                    switch (alignment) {
                        c.MD_ALIGN_LEFT => try ctx.writeString("left"),
                        c.MD_ALIGN_CENTER => try ctx.writeString("center"),
                        c.MD_ALIGN_RIGHT => try ctx.writeString("right"),
                        else => {},
                    }

                    try ctx.writeString("\"");
                }

                try ctx.writeString(">\n");
                ctx.current_level += 1;
            },
            else => {},
        }
    }

    fn leave_block(blk: c.MD_BLOCKTYPE, detail: ?*anyopaque, userdata: ?*anyopaque) callconv(.c) c_int {
        const ctx = @as(*RenderContext, @ptrCast(@alignCast(userdata)));
        leave_block_impl(blk, detail, ctx) catch return 1;
        return 0;
    }

    fn leave_block_impl(blk: c.MD_BLOCKTYPE, detail: ?*anyopaque, ctx: *RenderContext) !void {
        switch (blk) {
            c.MD_BLOCK_DOC => {},
            c.MD_BLOCK_QUOTE => try ctx.writeClose("</blockquote>"),
            c.MD_BLOCK_UL => try ctx.writeClose("</ul>"),
            c.MD_BLOCK_OL => try ctx.writeClose("</ol>"),
            c.MD_BLOCK_LI => try ctx.writeClose("</li>"),
            c.MD_BLOCK_HR => {},
            c.MD_BLOCK_H => {
                _ = @as(*const c.MD_BLOCK_H_DETAIL, @ptrCast(@alignCast(detail)));

                if (ctx.cur_header_level) |cur_header_level| {
                    var raw_header_text = try ctx.cur_header_text.toOwnedSlice(ctx.allocator);
                    var header_text: []const u8 = undefined;
                    defer ctx.allocator.free(raw_header_text);

                    var id: []const u8 = undefined;
                    var has_custom_id: bool = false;
                    if (mem.indexOf(u8, raw_header_text, "{#")) |start_idx| {
                        if (mem.endsWith(u8, raw_header_text, "}")) {
                            id = try ctx.allocator.dupe(u8, raw_header_text[start_idx + 2 .. raw_header_text.len - 1]);
                            header_text = try ctx.allocator.dupe(u8, raw_header_text[0..start_idx]);
                            has_custom_id = true;
                        }
                    }

                    if (!has_custom_id) {
                        header_text = try ctx.allocator.dupe(u8, raw_header_text);
                        id = try toSlug(ctx.allocator, header_text);
                    }

                    const opening_tag = try std.fmt.allocPrint(ctx.allocator, "<h{d} id=\"{s}\">", .{ cur_header_level.toInt(), id });
                    try ctx.writeString(opening_tag);
                    try ctx.writeString(header_text);
                    const closing_tag = try std.fmt.allocPrint(ctx.allocator, "</h{d}>\n", .{cur_header_level.toInt()});
                    try ctx.writeString(closing_tag);

                    const header = Page.Header{
                        .id = id,
                        .level = cur_header_level,
                        .text = header_text,
                    };
                    try ctx.graph.addHeader(ctx.cur_page, header);
                    ctx.cur_header_level = null;
                }
            },
            c.MD_BLOCK_CODE => {
                try ctx.writeClose("</code>");
                try ctx.writeClose("</pre>");
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

    fn enter_span(span: c.MD_SPANTYPE, detail: ?*anyopaque, userdata: ?*anyopaque) callconv(.c) c_int {
        const ctx = @as(*RenderContext, @ptrCast(@alignCast(userdata)));
        enter_span_impl(span, detail, ctx) catch return 1;
        return 0;
    }

    fn enter_span_impl(span: c.MD_SPANTYPE, detail: ?*anyopaque, ctx: *RenderContext) !void {
        switch (span) {
            c.MD_SPAN_EM => try ctx.writeString("<em>"),
            c.MD_SPAN_STRONG => try ctx.writeString("<strong>"),
            c.MD_SPAN_A => {
                const a_detail = @as(*const c.MD_SPAN_A_DETAIL, @ptrCast(@alignCast(detail)));
                const href = a_detail.href.text[0..a_detail.href.size];
                var page_link = href;
                if (mem.startsWith(u8, href, "/")) page_link = page_link[1..];
                if (mem.endsWith(u8, href, ".md")) page_link = page_link[0 .. page_link.len - 3];
                const is_known_page = ctx.graph.pages.contains(page_link);
                try ctx.writeString("<a href=\"");
                if (mem.endsWith(u8, href, ".md") and is_known_page) {
                    log.debug("[{s}] Rewriting internal .md link {s}", .{ ctx.cur_page, href });
                    try ctx.renderUrlEscaped(href[0 .. href.len - 3]);
                    try ctx.write(".html");
                } else {
                    try ctx.renderUrlEscaped(href);
                }

                const has_title = a_detail.title.text != null and a_detail.title.size > 0;
                if (has_title) {
                    try ctx.writeString("\" title=\"");
                    try ctx.renderHtmlEscaped(a_detail.title.text[0..a_detail.title.size]);
                }

                try ctx.writeString("\">");

                // TODO: do not add links for ignored pages
                if (ctx.cur_link_url == null) {
                    if (is_known_page) {
                        log.debug("[{s}] Markdown link to {s}", .{ ctx.cur_page, page_link });
                        ctx.cur_link_url = page_link;
                    }
                }
            },
            c.MD_SPAN_IMG => {
                ctx.image_nesting_level += 1;

                const img_detail = @as(*const c.MD_SPAN_IMG_DETAIL, @ptrCast(@alignCast(detail)));
                try ctx.writeString("<img src=\"");
                try ctx.renderUrlEscaped(img_detail.src.text[0..img_detail.src.size]);

                if (img_detail.title.text != null and img_detail.title.size > 0) {
                    try ctx.writeString("\" title=\"");
                    try ctx.renderHtmlEscaped(img_detail.title.text[0..img_detail.title.size]);
                }

                try ctx.writeString("\" alt=\"");
            },
            c.MD_SPAN_CODE => try ctx.writeString("<code>"),
            c.MD_SPAN_DEL => try ctx.writeString("<del>"),
            c.MD_SPAN_U => try ctx.writeString("<u>"),
            c.MD_SPAN_LATEXMATH => try ctx.writeString("<x-equation>"),
            c.MD_SPAN_LATEXMATH_DISPLAY => try ctx.writeString("<x-equation type=\"display\">"),
            c.MD_SPAN_WIKILINK => {
                // TODO: do not add links for ignored pages
                const wikilink_detail = @as(*const c.MD_SPAN_WIKILINK_DETAIL, @ptrCast(@alignCast(detail)));
                const target = wikilink_detail.target;
                try ctx.writeString("<a href=\"");
                try ctx.renderUrlEscaped(target.text[0..target.size]);
                try ctx.writeString(".html\">");
                ctx.cur_link_url = target.text[0..target.size];
            },
            else => {},
        }
    }

    fn leave_span(span: c.MD_SPANTYPE, detail: ?*anyopaque, userdata: ?*anyopaque) callconv(.c) c_int {
        const ctx = @as(*RenderContext, @ptrCast(@alignCast(userdata)));
        leave_span_impl(span, detail, ctx) catch return 1;
        return 0;
    }

    fn leave_span_impl(span: c.MD_SPANTYPE, detail: ?*anyopaque, ctx: *RenderContext) !void {
        _ = detail;

        switch (span) {
            c.MD_SPAN_EM => try ctx.writeString("</em>"),
            c.MD_SPAN_STRONG => try ctx.writeString("</strong>"),
            c.MD_SPAN_A => {
                try ctx.writeString("</a>");
                if (ctx.cur_link_url) |link_url| {
                    const link_text = try ctx.cur_link_text.toOwnedSlice(ctx.allocator);
                    const link = Page.Link{
                        .link = link_url,
                        .text = link_text,
                    };
                    try ctx.graph.addLink(ctx.cur_page, link);
                    ctx.cur_link_url = null;
                }
            },
            c.MD_SPAN_IMG => {
                try ctx.writeString("\">");
                ctx.image_nesting_level -= 1;
            },
            c.MD_SPAN_CODE => try ctx.writeString("</code>"),
            c.MD_SPAN_DEL => try ctx.writeString("</del>"),
            c.MD_SPAN_U => try ctx.writeString("</u>"),
            c.MD_SPAN_LATEXMATH => try ctx.writeString("</x-equation>"),
            c.MD_SPAN_LATEXMATH_DISPLAY => try ctx.writeString("</x-equation>"),
            c.MD_SPAN_WIKILINK => {
                try ctx.writeString("</a>");
                if (ctx.cur_link_url) |link_url| {
                    const link_text = try ctx.cur_link_text.toOwnedSlice(ctx.allocator);
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

    fn text(type_val: c.MD_TEXTTYPE, text_data: [*c]const c.MD_CHAR, size: c.MD_SIZE, userdata: ?*anyopaque) callconv(.c) c_int {
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

        if (ctx.cur_header_level != null) {
            try ctx.cur_header_text.appendSlice(ctx.allocator, data);
            return;
        }

        if (ctx.cur_link_url != null) {
            try ctx.cur_link_text.appendSlice(ctx.allocator, data);
        }

        try ctx.renderText(type_val, data);
    }
};

fn toSlug(allocator: std.mem.Allocator, text: []const u8) ![]u8 {
    const ascii = try anyascii.transliterate(allocator, text);
    defer allocator.free(ascii);

    var slug = std.ArrayList(u8).empty;

    var need_dash = false;
    var started = false;
    for (ascii) |char| {
        const ch = std.ascii.toLower(char);
        if (std.ascii.isAlphanumeric(ch)) {
            if (!started) started = true;
            if (need_dash) {
                try slug.append(allocator, '-');
                need_dash = false;
            }
            try slug.append(allocator, ch);
        } else if (!need_dash and started)
            need_dash = true;
    }

    return try slug.toOwnedSlice(allocator);
}
