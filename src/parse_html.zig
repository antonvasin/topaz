const std = @import("std");
const utils = @import("./utils.zig");
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
    Insert,
    MissingNode,
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

    pub fn tag(self: *const Node) Tag {
        return Tag.fromInt(c.lxb_dom_node_tag_id(self.raw));
    }

    /// Appends child node with validation
    pub fn appendChild(self: *const Node, child: Node) !void {
        const status = c.lxb_dom_node_append_child(self.raw, child.raw);
        if (status != c.LXB_DOM_EXCEPTION_OK) return error.Insert;
    }

    pub fn firstChild(self: *const Node) ?Node {
        const first_node = c.lxb_dom_node_first_child(self.raw) orelse return null;
        return .{ .raw = first_node };
    }

    pub fn lastChild(self: *const Node) ?Node {
        const first_node = c.lxb_dom_node_last_child(self.raw) orelse return null;
        return .{ .raw = first_node };
    }

    pub fn next(self: *const Node) ?Node {
        const next_node = c.lxb_dom_node_next(self.raw) orelse return null;
        return .{ .raw = next_node };
    }

    pub fn prev(self: *const Node) ?Node {
        const next_node = c.lxb_dom_node_prev(self.raw) orelse return null;
        return .{ .raw = next_node };
    }

    pub fn parent(self: *const Node) ?Node {
        const parent_node = c.lxb_dom_node_parent(self.raw) orelse return null;
        return .{ .raw = parent_node };
    }

    pub fn walk(self: *const Node, comptime cb: fn (Node, ?*anyopaque) bool) void {
        const walker = struct {
            fn walker_cb(node: ?*c.lxb_dom_node_t, ctx: ?*anyopaque) callconv(.c) c.lexbor_action_t {
                if (node) |actual_node| {
                    return if (cb(.{ .raw = actual_node }, ctx)) c.LEXBOR_ACTION_OK else c.LEXBOR_ACTION_STOP;
                } else {
                    return c.LEXBOR_ACTION_STOP;
                }
            }
        }.walker_cb;

        c.lxb_dom_node_simple_walk(self.raw, walker, null);
    }

    pub fn textContent(self: *const Node) []const u8 {
        var len: usize = 0;
        const text_content = c.lxb_dom_node_text_content(self.raw, &len);
        return text_content[0..len];
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

const Tag = enum(usize) {
    tag__undef = 0x0000,
    tag__end_of_file = 0x0001,
    tag__text = 0x0002,
    tag__document = 0x0003,
    tag__em_comment = 0x0004,
    tag__em_doctype = 0x0005,
    // // Intentionally has the same value as the first tag below. Marks the beginning of real tags.
    // LXB_TAG__BEGIN              = 0x0006,
    tag_a = 0x0006,
    tag_abbr = 0x0007,
    tag_acronym = 0x0008,
    tag_address = 0x0009,
    tag_altglyph = 0x000a,
    tag_altglyphdef = 0x000b,
    tag_altglyphitem = 0x000c,
    tag_animatecolor = 0x000d,
    tag_animatemotion = 0x000e,
    tag_animatetransform = 0x000f,
    tag_annotation_xml = 0x0010,
    tag_applet = 0x0011,
    tag_area = 0x0012,
    tag_article = 0x0013,
    tag_aside = 0x0014,
    tag_audio = 0x0015,
    tag_b = 0x0016,
    tag_base = 0x0017,
    tag_basefont = 0x0018,
    tag_bdi = 0x0019,
    tag_bdo = 0x001a,
    tag_bgsound = 0x001b,
    tag_big = 0x001c,
    tag_blink = 0x001d,
    tag_blockquote = 0x001e,
    tag_body = 0x001f,
    tag_br = 0x0020,
    tag_button = 0x0021,
    tag_canvas = 0x0022,
    tag_caption = 0x0023,
    tag_center = 0x0024,
    tag_cite = 0x0025,
    tag_clippath = 0x0026,
    tag_code = 0x0027,
    tag_col = 0x0028,
    tag_colgroup = 0x0029,
    tag_data = 0x002a,
    tag_datalist = 0x002b,
    tag_dd = 0x002c,
    tag_del = 0x002d,
    tag_desc = 0x002e,
    tag_details = 0x002f,
    tag_dfn = 0x0030,
    tag_dialog = 0x0031,
    tag_dir = 0x0032,
    tag_div = 0x0033,
    tag_dl = 0x0034,
    tag_dt = 0x0035,
    tag_em = 0x0036,
    tag_embed = 0x0037,
    tag_feblend = 0x0038,
    tag_fecolormatrix = 0x0039,
    tag_fecomponenttransfer = 0x003a,
    tag_fecomposite = 0x003b,
    tag_feconvolvematrix = 0x003c,
    tag_fediffuselighting = 0x003d,
    tag_fedisplacementmap = 0x003e,
    tag_fedistantlight = 0x003f,
    tag_fedropshadow = 0x0040,
    tag_feflood = 0x0041,
    tag_fefunca = 0x0042,
    tag_fefuncb = 0x0043,
    tag_fefuncg = 0x0044,
    tag_fefuncr = 0x0045,
    tag_fegaussianblur = 0x0046,
    tag_feimage = 0x0047,
    tag_femerge = 0x0048,
    tag_femergenode = 0x0049,
    tag_femorphology = 0x004a,
    tag_feoffset = 0x004b,
    tag_fepointlight = 0x004c,
    tag_fespecularlighting = 0x004d,
    tag_fespotlight = 0x004e,
    tag_fetile = 0x004f,
    tag_feturbulence = 0x0050,
    tag_fieldset = 0x0051,
    tag_figcaption = 0x0052,
    tag_figure = 0x0053,
    tag_font = 0x0054,
    tag_footer = 0x0055,
    tag_foreignobject = 0x0056,
    tag_form = 0x0057,
    tag_frame = 0x0058,
    tag_frameset = 0x0059,
    tag_glyphref = 0x005a,
    tag_h1 = 0x005b,
    tag_h2 = 0x005c,
    tag_h3 = 0x005d,
    tag_h4 = 0x005e,
    tag_h5 = 0x005f,
    tag_h6 = 0x0060,
    tag_head = 0x0061,
    tag_header = 0x0062,
    tag_hgroup = 0x0063,
    tag_hr = 0x0064,
    tag_html = 0x0065,
    tag_i = 0x0066,
    tag_iframe = 0x0067,
    tag_image = 0x0068,
    tag_img = 0x0069,
    tag_input = 0x006a,
    tag_ins = 0x006b,
    tag_isindex = 0x006c,
    tag_kbd = 0x006d,
    tag_keygen = 0x006e,
    tag_label = 0x006f,
    tag_legend = 0x0070,
    tag_li = 0x0071,
    tag_lineargradient = 0x0072,
    tag_link = 0x0073,
    tag_listing = 0x0074,
    tag_main = 0x0075,
    tag_malignmark = 0x0076,
    tag_map = 0x0077,
    tag_mark = 0x0078,
    tag_marquee = 0x0079,
    tag_math = 0x007a,
    tag_menu = 0x007b,
    tag_meta = 0x007c,
    tag_meter = 0x007d,
    tag_mfenced = 0x007e,
    tag_mglyph = 0x007f,
    tag_mi = 0x0080,
    tag_mn = 0x0081,
    tag_mo = 0x0082,
    tag_ms = 0x0083,
    tag_mtext = 0x0084,
    tag_multicol = 0x0085,
    tag_nav = 0x0086,
    tag_nextid = 0x0087,
    tag_nobr = 0x0088,
    tag_noembed = 0x0089,
    tag_noframes = 0x008a,
    tag_noscript = 0x008b,
    tag_object = 0x008c,
    tag_ol = 0x008d,
    tag_optgroup = 0x008e,
    tag_option = 0x008f,
    tag_output = 0x0090,
    tag_p = 0x0091,
    tag_param = 0x0092,
    tag_path = 0x0093,
    tag_picture = 0x0094,
    tag_plaintext = 0x0095,
    tag_pre = 0x0096,
    tag_progress = 0x0097,
    tag_q = 0x0098,
    tag_radialgradient = 0x0099,
    tag_rb = 0x009a,
    tag_rp = 0x009b,
    tag_rt = 0x009c,
    tag_rtc = 0x009d,
    tag_ruby = 0x009e,
    tag_s = 0x009f,
    tag_samp = 0x00a0,
    tag_script = 0x00a1,
    tag_search = 0x00a2,
    tag_section = 0x00a3,
    tag_select = 0x00a4,
    tag_selectedcontent = 0x00a5,
    tag_slot = 0x00a6,
    tag_small = 0x00a7,
    tag_source = 0x00a8,
    tag_spacer = 0x00a9,
    tag_span = 0x00aa,
    tag_strike = 0x00ab,
    tag_strong = 0x00ac,
    tag_style = 0x00ad,
    tag_sub = 0x00ae,
    tag_summary = 0x00af,
    tag_sup = 0x00b0,
    tag_svg = 0x00b1,
    tag_table = 0x00b2,
    tag_tbody = 0x00b3,
    tag_td = 0x00b4,
    tag_template = 0x00b5,
    tag_textarea = 0x00b6,
    tag_textpath = 0x00b7,
    tag_tfoot = 0x00b8,
    tag_th = 0x00b9,
    tag_thead = 0x00ba,
    tag_time = 0x00bb,
    tag_title = 0x00bc,
    tag_tr = 0x00bd,
    tag_track = 0x00be,
    tag_tt = 0x00bf,
    tag_u = 0x00c0,
    tag_ul = 0x00c1,
    tag_var = 0x00c2,
    tag_video = 0x00c3,
    tag_wbr = 0x00c4,
    tag_xmp = 0x00c5,
    tag__last_entry = 0x00c6,

    pub fn fromInt(tag: usize) Tag {
        return @enumFromInt(tag);
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
    \\        <article>
    \\            <h2>Subheader</h2>
    \\            <p>Paragraph text with <a href="https://hello">link</a></p>
    \\        </article>
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
        try head2.appendChild(clone);
        child_node = node.next();
    }

    const newTitle = "My awesome webpage";
    try doc2.titleSet(newTitle);
    try std.testing.expectEqualStrings(newTitle, try doc2.title());
    try std.testing.expectEqualStrings("Hello world!", try doc.title());
}

test "tree traversal" {
    var doc = try Document.parse(test_html_doc);
    defer doc.deinit();
    const body_node = doc.body().toNode();
    var child: Node = body_node.firstChild() orelse return error.MissingNode;
    // const first_child = body_node.firstChild() orelse return error.MissingNode;
    const first_child_text = child.textContent();
    try std.testing.expectEqualStrings("Hello!", first_child_text);
    child = child.next() orelse return error.MissingNode;
    const tag = child.tag();
    try std.testing.expectEqual(Tag.tag_article, tag);

    const walker = struct {
        fn walk(node: Node, ctx: ?*anyopaque) bool {
            _ = ctx;
            if (node.tag() == Tag.tag_a) {
                node.print() catch return false;
                return false;
            }
            return true;
        }
    }.walk;

    child.walk(walker);
}
