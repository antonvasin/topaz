const std = @import("std");
const mem = std.mem;

const c = @cImport({
    @cInclude("lexbor/html/parser.h");
    @cInclude("lexbor/dom/interfaces/element.h");
});

pub const Error = error{Parse};

pub const Document = struct {
    raw: *c.lxb_html_document_t,

    pub fn parse(html: [*c]const u8) !Document {
        const doc = c.lxb_html_document_create();
        errdefer _ = c.lxb_html_document_destroy(doc);
        const status = c.lxb_html_document_parse(doc, html, std.mem.len(html));
        if (status != c.LXB_STATUS_OK) return error.Parse;
        return .{ .raw = doc };
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
        \\    </head>
        \\    <body><h1>Hello!</h1></body>
        \\</html>
    ;
    var doc = try Document.parse(html);
    defer doc.deinit();
    const body = c.lxb_dom_interface_element(doc.raw.body);
    const h1 = c.lxb_dom_node_first_child(c.lxb_dom_interface_node(body));
    var text_len: usize = 0;
    const text = c.lxb_dom_node_text_content(h1, &text_len);
    try std.testing.expect(std.mem.eql(u8, text[0..text_len], "Hello!"));
}
