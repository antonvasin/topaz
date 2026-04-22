const std = @import("std");
const mem = std.mem;

const c = @cImport({
    @cInclude("lexbor/html/html.h");
    @cInclude("lexbor/dom/interfaces/element.h");
});

pub const Error = error{
    ParserInit,
    Parse,
    Print,
};

const LxbFilterCtx = extern struct {
    original_callback: c.lxb_html_tokenizer_token_f,
    original_ctx: ?*anyopaque,
    skipped: c_uint,
};

fn token_filter(tkz: ?*c.lxb_html_tokenizer_t, token: ?*c.lxb_html_token_t, ctx: ?*anyopaque) callconv(.c) *c.lxb_html_token_t {
    const fctx = @as(*LxbFilterCtx, @ptrCast(@alignCast(ctx)));

    const tag = token.?.*.tag_id;
    switch (tag) {
        c.LXB_TAG__TEXT => {},
        c.LXB_TAG__EM_COMMENT => {
            fctx.skipped += 1;
            return token.?;
        },
        else => return fctx.original_callback.?(tkz, token, fctx.original_ctx),
    }

    // if (tag_id != c.LXB_TAG__TEXT or ) return fctx.original_callback.?(tkz, token, fctx.original_ctx);

    // Check if text is whitespace-only
    const len: usize = @intFromPtr(token.?.text_end) - @intFromPtr(token.?.text_start);
    const text: []const u8 = token.?.text_start[0..len];
    for (text) |char| {
        switch (char) {
            '\t', '\n', '\x0C', '\r', ' ' => {},
            else => return fctx.original_callback.?(tkz, token, fctx.original_ctx),
        }
    }

    fctx.skipped += 1;
    // std.debug.print("Skipped whitespace only token ({d}b)\n", .{text.len});
    return token.?;
}

fn serialize(data: ?[*]const c.lxb_char_t, len: usize, _: ?*anyopaque) callconv(.c) c.lxb_status_t {
    const text: []const u8 = (data orelse return c.LXB_STATUS_ERROR)[0..len];
    std.debug.print("{s}", .{text});
    return c.LXB_STATUS_OK;
}

pub const Document = struct {
    raw: *c.lxb_html_document_t,

    /// Parses html document stripping whitespace and comments
    pub fn parse(html: [*c]const u8) !Document {
        const html_len = std.mem.len(html);

        // initialize the parser
        const parser = c.lxb_html_parser_create();
        defer _ = c.lxb_html_parser_destroy(parser);
        const parser_status = c.lxb_html_parser_init(parser);
        if (parser_status != c.LXB_STATUS_OK) return error.ParserInit;

        // save original callback
        const tkz = c.lxb_html_parser_tokenizer(parser);
        var fctx: LxbFilterCtx = .{
            .original_callback = tkz.*.callback_token_done,
            .original_ctx = c.lxb_html_tokenizer_callback_token_done_ctx(tkz).?,
            .skipped = 0,
        };

        // replace callback with own filter
        c.lxb_html_tokenizer_callback_token_done_set(tkz, token_filter, &fctx);
        // std.debug.print("\nSkipped {d} whitespace-only text token(s).\n\n", .{fctx.skipped});

        // parse
        const doc = c.lxb_html_parse(parser, html, html_len);
        if (doc == null) return error.Parse;
        return .{ .raw = doc };
    }

    pub fn print(self: *Document) !void {
        const status = c.lxb_html_serialize_pretty_tree_cb(c.lxb_dom_interface_node(self.raw), c.LXB_HTML_SERIALIZE_EXT_OPT_UNDEF, 0, &serialize, null);
        if (status != c.LXB_STATUS_OK) return error.Print;
    }

    pub fn deinit(self: *Document) void {
        _ = c.lxb_html_document_destroy(self.raw);
    }
};

test "parse" {
    const html =
        \\<!doctype html>
        \\<html>
        \\    <head>
        \\        <title>Hello world!</title>
        \\        <!-- some comment to be stripped -->
        \\    </head>
        \\    <body>
        \\        <h1>Hello!</h1>
        \\    </body>
        \\</html>
    ;
    var doc = try Document.parse(html);
    defer doc.deinit();
    const body = c.lxb_dom_interface_element(doc.raw.body);
    const h1 = c.lxb_dom_node_first_child(c.lxb_dom_interface_node(body));
    var text_len: usize = 0;
    const text = c.lxb_dom_node_text_content(h1, &text_len);
    const match = "Hello!";
    try std.testing.expect(std.mem.eql(u8, text[0..text_len], match));
}
