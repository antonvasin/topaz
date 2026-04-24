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
    MissingTitle,
    Create,
    Serialization,
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

pub const Document = struct {
    raw: *c.lxb_html_document_t,

    pub fn init() !Document {
        const doc = c.lxb_html_document_create();
        if (doc == null) return error.Create;
        doc.*.ready_state = c.LXB_HTML_DOCUMENT_READY_STATE_COMPLETE;
        return .{ .raw = doc };
    }

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

    pub fn head(self: *const Document) Element {
        return .{ .raw = c.lxb_dom_interface_element(self.raw.head) };
    }

    pub fn title(self: *const Document) ![]const u8 {
        var title_len: usize = 0;
        const doc_title = c.lxb_html_document_title(self.raw, &title_len);
        if (doc_title == null) return error.Title;
        return doc_title[0..title_len];
    }

    pub fn titleSet(self: *const Document, new_title: []const u8) !void {
        const status = c.lxb_html_document_title_set(self.raw, new_title.ptr, new_title.len);
        if (status != c.LXB_STATUS_OK) return error.Title;
    }

    pub fn importNode(self: *const Document, node: Node) Node {
        const clone = c.lxb_html_document_import_node(self.raw, node.raw, true);
        return .{ .raw = clone };
    }

    pub fn body(self: *const Document) Element {
        return .{ .raw = c.lxb_dom_interface_element(self.raw.body) };
    }

    pub fn toNode(self: *const Document) Node {
        return .{ .raw = c.lxb_dom_interface_node(self.raw) };
    }

    pub fn print(self: *const Document) !void {
        try self.toNode().print();
    }

    pub fn deinit(self: *Document) void {
        _ = c.lxb_html_document_destroy(self.raw);
    }
};

pub const Element = struct {
    raw: *c.lxb_dom_element_t,

    pub fn print(self: *const Element) !void {
        try self.toNode().print();
    }

    pub fn deinit(self: *Element) void {
        _ = c.lxb_dom_node_destroy_deep(self.raw);
    }

    pub fn toNode(self: *const Element) Node {
        return .{ .raw = c.lxb_dom_interface_node(self.raw) };
    }

    /// Serializes element to string. Caller must destroy parent Document in order to free the memory
    pub fn serialize(self: *const Element) ![]const u8 {
        var str: c.lexbor_str_t = std.mem.zeroes(c.lexbor_str_t);
        const status = c.lxb_html_serialize_deep_str(self.toNode().raw, &str);
        if (status != c.LXB_STATUS_OK) return error.Serialization;

        return str.data[0..str.length];
    }
};

pub const Node = struct {
    raw: *c.lxb_dom_node_t,

    pub fn insertChild(self: *const Node, child: Node) void {
        c.lxb_dom_node_insert_child(self.raw, child.raw);
    }

    pub fn firstChild(self: *const Node) ?Node {
        const first_node = c.lxb_dom_node_first_child(self.raw) orelse return null;
        return .{ .raw = first_node };
    }

    pub fn next(self: *const Node) ?Node {
        const next_node = c.lxb_dom_node_next(self.raw) orelse return null;
        return .{ .raw = next_node };
    }

    pub fn print(self: *const Node) !void {
        const status = c.lxb_html_serialize_pretty_tree_cb(self.raw, c.LXB_HTML_SERIALIZE_EXT_OPT_UNDEF, 0, &serialize, null);
        if (status != c.LXB_STATUS_OK) return error.Print;
    }

    fn serialize(data: ?[*]const c.lxb_char_t, len: usize, _: ?*anyopaque) callconv(.c) c.lxb_status_t {
        const text: []const u8 = (data orelse return c.LXB_STATUS_ERROR)[0..len];
        std.debug.print("{s}", .{text});
        return c.LXB_STATUS_OK;
    }
};

const test_html_doc =
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

test "parse HTML" {
    var doc = try Document.parse(test_html_doc);
    defer doc.deinit();

    const body = doc.body();
    const first_child = c.lxb_dom_node_first_child(c.lxb_dom_interface_node(body.raw));
    var text_len: usize = 0;
    const text = c.lxb_dom_node_text_content(first_child, &text_len);
    try std.testing.expectEqualStrings("Hello!", text[0..text_len]);
}

test "get and set title" {
    var doc = try Document.parse(test_html_doc);
    defer doc.deinit();
    const title = try doc.title();
    try std.testing.expectEqualStrings("Hello world!", title);

    try doc.titleSet("New title");
    const new_title = try doc.title();
    try std.testing.expectEqualStrings("New title", new_title);
}

test "serialize element" {
    var doc = try Document.parse(test_html_doc);
    defer doc.deinit();
    const head = try doc.head().serialize();
    try std.testing.expectEqualStrings("<title>Hello world!</title>", head);
}

test "clone and modify element" {
    const html_doc =
        \\<!doctype html>
        \\<html>
        \\    <head>
        \\        <title>Hello world!</title>
        \\        <!-- some comment to be stripped -->
        \\        <meta charset="utf-8" />
        \\        <meta name="viewport" content="width=device-width, initial-scale=1" />
        \\    </head>
        \\    <body>
        \\        <h1>Hello!</h1>
        \\    </body>
        \\</html>
    ;

    var doc = try Document.parse(html_doc);
    defer doc.deinit();
    var doc2 = try Document.parse("");
    defer doc2.deinit();
    const head = doc.head().toNode();
    const head2 = doc2.head().toNode();

    var child_node = head.firstChild();
    while (child_node) |node| {
        const clone = doc2.importNode(node);
        head2.insertChild(clone);
        child_node = node.next();
    }

    const newTitle = "My awesome webpage";
    try doc2.titleSet(newTitle);
    try std.testing.expectEqualStrings(newTitle, try doc2.title());
    try std.testing.expectEqualStrings("Hello world!", try doc.title());
}
