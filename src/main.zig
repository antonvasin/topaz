const std = @import("std");
const builtin = @import("builtin");
const c = @cImport({
    @cInclude("md4c.h");
});

const print = std.debug.print;
const mem = std.mem;
const assert = std.debug.assert;

// Default template

const RenderContext = struct {
    allocator: mem.Allocator,
    /// String builder
    buf: std.ArrayList(u8),
    page_title: []const u8,
    image_nesting_level: u32 = 0,
    current_level: u32 = 0,

    pub fn init(allocator: mem.Allocator, page_title: []const u8) !RenderContext {
        const buf = std.ArrayList(u8).init(allocator);

        return .{
            .buf = buf,
            .allocator = allocator,
            .page_title = page_title,
        };
    }

    pub fn deinit(self: *RenderContext) void {
        self.buf.deinit();
    }

    // TODO: return status code for md4c callbacks to avoid typing `catch return 1`
    /// Print string inline (no indentation)
    pub fn write(self: *RenderContext, str: []const u8) !void {
        try self.buf.appendSlice(str);
    }

    /// Print tag inline without nesting e.g. `        <title>Title</title>\n`
    pub fn writeInline(self: *RenderContext, str: []const u8) !void {
        for (0..self.current_level) |_| try self.write("    ");
        try self.write(str);
        try self.write("\n");
    }

    /// Print open tag with indentation
    pub fn writeOpen(self: *RenderContext, str: []const u8) !void {
        for (0..self.current_level) |_| try self.write("    ");
        try self.write(str);
        try self.write("\n");
        self.current_level += 1;
    }

    // Print closing tag with indentation
    pub fn writeClose(self: *RenderContext, str: []const u8) !void {
        // assert(self.current_level > 0);
        if (self.current_level > 0) self.current_level -= 1 else print("Lost indentation {s}\n", .{str});
        for (0..self.current_level) |_| try self.write("    ");
        try self.write(str);
        try self.write("\n");
    }

    /// Writes title and meta, run before md parsing
    pub fn writeHtmlHead(self: *RenderContext) !void {
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
        const title = try std.fmt.bufPrint(&title_buf, "<title>{s}</title>", .{self.page_title});
        try self.writeInline(title);

        try self.writeClose("</head>");
        try self.writeOpen("<body>");
    }

    /// Closes tags, run after md parsing
    pub fn writeHtmlTail(self: *RenderContext) !void {
        try self.writeClose("</body>");
        try self.writeClose("</html>");
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
        c.MD_BLOCK_QUOTE => ctx.writeOpen("<blockquote>") catch return 1,
        c.MD_BLOCK_UL => ctx.writeOpen("<ul>") catch return 1,
        c.MD_BLOCK_OL => {
            const ol_detail = @as(*const c.MD_BLOCK_OL_DETAIL, @ptrCast(@alignCast(detail)));
            if (ol_detail.start == 1) {
                ctx.writeOpen("<ol>") catch return 1;
            } else {
                var buf: [32]u8 = undefined;
                const ol_tag = std.fmt.bufPrint(&buf, "<ol start=\"{d}\">", .{ol_detail.start}) catch return 1;
                ctx.writeOpen(ol_tag) catch return 1;
            }
        },
        c.MD_BLOCK_LI => {
            const li_detail = @as(*const c.MD_BLOCK_LI_DETAIL, @ptrCast(@alignCast(detail)));
            if (li_detail.is_task != 0) {
                // TODO: this really have no length limit
                var ol_buf: [4096]u8 = undefined;
                const checked: []const u8 = if (li_detail.task_mark == 'x' or li_detail.task_mark == 'X') "checked" else "";
                const li_tag = std.fmt.bufPrint(&ol_buf, "<li class=\"task-list-item\"><input type=\"checkbox\" class=\"task-list-item-checkbox\" disabled {s}>", .{checked}) catch return 1;
                ctx.writeOpen(li_tag) catch return 1;
            } else {
                ctx.writeOpen("<li>") catch return 1;
            }
        },
        c.MD_BLOCK_HR => ctx.writeInline("<hr>") catch return 1,
        c.MD_BLOCK_H => {
            const h_detail = @as(*const c.MD_BLOCK_H_DETAIL, @ptrCast(@alignCast(detail)));
            const level = h_detail.level;
            if (level >= 1 and level <= 6) {
                ctx.writeOpen(headers_openning_tags[level - 1]) catch return 1;
            }
        },
        c.MD_BLOCK_CODE => {
            const code_detail = @as(*const c.MD_BLOCK_CODE_DETAIL, @ptrCast(@alignCast(detail)));
            ctx.writeOpen("<pre>") catch return 1;
            ctx.writeInline("<code") catch return 1;

            if (code_detail.lang.text != null and code_detail.lang.size > 0) {
                ctx.write(" class=\"language-") catch return 1;
                ctx.renderHtmlEscaped(code_detail.lang.text[0..code_detail.lang.size]) catch return 1;
                ctx.write("\"") catch return 1;
            }

            ctx.write(">\n") catch return 1;
            // TODO: handle in writer
            ctx.current_level += 1;
        },
        c.MD_BLOCK_P => ctx.writeOpen("<p>") catch return 1,
        c.MD_BLOCK_TABLE => ctx.writeOpen("<table>") catch return 1,
        c.MD_BLOCK_THEAD => ctx.writeOpen("<thead>") catch return 1,
        c.MD_BLOCK_TBODY => ctx.writeOpen("<tbody>") catch return 1,
        c.MD_BLOCK_TR => ctx.writeOpen("<tr>") catch return 1,
        c.MD_BLOCK_TH => {
            const header_detail = @as(*const c.MD_BLOCK_TD_DETAIL, @ptrCast(@alignCast(detail)));
            ctx.writeInline("<th") catch return 1;

            const alignment = @field(header_detail, "align");
            if (alignment != c.MD_ALIGN_DEFAULT) {
                ctx.write(" align=\"") catch return 1;

                switch (alignment) {
                    c.MD_ALIGN_LEFT => ctx.write("left") catch return 1,
                    c.MD_ALIGN_CENTER => ctx.write("center") catch return 1,
                    c.MD_ALIGN_RIGHT => ctx.write("right") catch return 1,
                    else => {},
                }

                ctx.write("\"") catch return 1;
            }

            ctx.write(">\n") catch return 1;
            // TODO: handle in writer
            ctx.current_level += 1;
        },
        c.MD_BLOCK_TD => {
            const cell_detail = @as(*const c.MD_BLOCK_TD_DETAIL, @ptrCast(@alignCast(detail)));
            ctx.writeInline("<td") catch return 1;

            const alignment = @field(cell_detail, "align");
            if (alignment != c.MD_ALIGN_DEFAULT) {
                ctx.write(" align=\"") catch return 1;

                switch (alignment) {
                    c.MD_ALIGN_LEFT => ctx.write("left") catch return 1,
                    c.MD_ALIGN_CENTER => ctx.write("center") catch return 1,
                    c.MD_ALIGN_RIGHT => ctx.write("right") catch return 1,
                    else => {},
                }

                ctx.write("\"") catch return 1;
            }

            ctx.write(">\n") catch return 1;
            ctx.current_level += 1;
        },
        else => {},
    }

    return 0;
}

fn leave_block(blk: c.MD_BLOCKTYPE, detail: ?*anyopaque, userdata: ?*anyopaque) callconv(.C) c_int {
    const ctx = @as(*RenderContext, @ptrCast(@alignCast(userdata)));

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
        c.MD_BLOCK_QUOTE => ctx.writeClose("</blockquote>") catch return 1,
        c.MD_BLOCK_UL => ctx.writeClose("</ul>") catch return 1,
        c.MD_BLOCK_OL => ctx.writeClose("</ol>") catch return 1,
        c.MD_BLOCK_LI => ctx.writeClose("</li>") catch return 1,
        c.MD_BLOCK_HR => {},
        c.MD_BLOCK_H => {
            const h_detail = @as(*const c.MD_BLOCK_H_DETAIL, @ptrCast(@alignCast(detail)));
            const level = h_detail.level;
            if (level >= 1 and level <= 6) {
                ctx.writeClose(headers_closing_tags[level - 1]) catch return 1;
            }
        },
        c.MD_BLOCK_CODE => {
            ctx.writeClose("</code>") catch return 1;
            ctx.writeClose("</pre>\n") catch return 1;
        },
        c.MD_BLOCK_P => ctx.writeClose("</p>") catch return 1,
        c.MD_BLOCK_TABLE => ctx.writeClose("</table>") catch return 1,
        c.MD_BLOCK_THEAD => ctx.writeClose("</thead>") catch return 1,
        c.MD_BLOCK_TBODY => ctx.writeClose("</tbody>") catch return 1,
        c.MD_BLOCK_TR => ctx.writeClose("</tr>") catch return 1,
        c.MD_BLOCK_TH => ctx.writeClose("</th>") catch return 1,
        c.MD_BLOCK_TD => ctx.writeClose("</td>") catch return 1,
        else => {},
    }

    return 0;
}

fn enter_span(span: c.MD_SPANTYPE, detail: ?*anyopaque, userdata: ?*anyopaque) callconv(.C) c_int {
    const ctx = @as(*RenderContext, @ptrCast(@alignCast(userdata)));

    switch (span) {
        c.MD_SPAN_EM => ctx.write("<em>") catch return 1,
        c.MD_SPAN_STRONG => ctx.write("<strong>") catch return 1,
        c.MD_SPAN_A => {
            // TODO: check if it's a link to a page, that this page exists and is not ignored and add .html
            const a_detail = @as(*const c.MD_SPAN_A_DETAIL, @ptrCast(@alignCast(detail)));
            ctx.write("<a href=\"") catch return 1;
            ctx.renderUrlEscaped(a_detail.href.text[0..a_detail.href.size]) catch return 1;

            if (a_detail.title.text != null and a_detail.title.size > 0) {
                ctx.write("\" title=\"") catch return 1;
                ctx.renderHtmlEscaped(a_detail.title.text[0..a_detail.title.size]) catch return 1;
            }

            ctx.write("\">") catch return 1;
        },
        c.MD_SPAN_IMG => {
            ctx.image_nesting_level += 1;

            const img_detail = @as(*const c.MD_SPAN_IMG_DETAIL, @ptrCast(@alignCast(detail)));
            ctx.write("<img src=\"") catch return 1;
            ctx.renderUrlEscaped(img_detail.src.text[0..img_detail.src.size]) catch return 1;

            if (img_detail.title.text != null and img_detail.title.size > 0) {
                ctx.write("\" title=\"") catch return 1;
                ctx.renderHtmlEscaped(img_detail.title.text[0..img_detail.title.size]) catch return 1;
            }

            ctx.write("\" alt=\"") catch return 1;
        },
        c.MD_SPAN_CODE => ctx.write("<code>") catch return 1,
        c.MD_SPAN_DEL => ctx.write("<del>") catch return 1,
        c.MD_SPAN_U => ctx.write("<u>") catch return 1,
        c.MD_SPAN_LATEXMATH => ctx.write("<x-equation>") catch return 1,
        c.MD_SPAN_LATEXMATH_DISPLAY => ctx.write("<x-equation type=\"display\">") catch return 1,
        c.MD_SPAN_WIKILINK => {
            // TODO: check if page exists and is not ignored
            const wikilink_detail = @as(*const c.MD_SPAN_WIKILINK_DETAIL, @ptrCast(@alignCast(detail)));
            ctx.write("<a href=\"") catch return 1;
            ctx.renderUrlEscaped(wikilink_detail.target.text[0..wikilink_detail.target.size]) catch return 1;
            ctx.write(".html\">") catch return 1;
        },
        else => {},
    }

    return 0;
}

fn leave_span(span: c.MD_SPANTYPE, detail: ?*anyopaque, userdata: ?*anyopaque) callconv(.C) c_int {
    const ctx = @as(*RenderContext, @ptrCast(@alignCast(userdata)));
    _ = detail;

    switch (span) {
        c.MD_SPAN_EM => ctx.write("</em>") catch return 1,
        c.MD_SPAN_STRONG => ctx.write("</strong>") catch return 1,
        c.MD_SPAN_A => ctx.write("</a>") catch return 1,
        c.MD_SPAN_IMG => {
            ctx.write("\"") catch return 1;
            ctx.write(">") catch return 1;
            ctx.image_nesting_level -= 1;
        },
        c.MD_SPAN_CODE => ctx.write("</code>") catch return 1,
        c.MD_SPAN_DEL => ctx.write("</del>") catch return 1,
        c.MD_SPAN_U => ctx.write("</u>") catch return 1,
        c.MD_SPAN_LATEXMATH => ctx.write("</x-equation>") catch return 1,
        c.MD_SPAN_LATEXMATH_DISPLAY => ctx.write("</x-equation>") catch return 1,
        c.MD_SPAN_WIKILINK => ctx.write("</a>") catch return 1,
        else => {},
    }

    return 0;
}

fn text(type_val: c.MD_TEXTTYPE, text_data: [*c]const c.MD_CHAR, size: c.MD_SIZE, userdata: ?*anyopaque) callconv(.C) c_int {
    const ctx = @as(*RenderContext, @ptrCast(@alignCast(userdata)));
    const data = text_data[0..size];

    // Skip image alt text rendering when inside an image, as it's handled separately
    if (ctx.image_nesting_level > 0 and type_val != c.MD_TEXT_NULLCHAR) {
        return 0;
    }

    ctx.renderText(type_val, data) catch return 1;
    return 0;
}

fn processFile(file: std.fs.File, parser: *const c.MD_PARSER, ctx: *RenderContext) !void {
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

    if (yaml_end != 0) print("YAML found [0..{d}]\n", .{yaml_end});

    // Parse the markdown content
    _ = c.md_parse(@ptrCast(&buf[yaml_end]), @intCast(bytes_read - yaml_end), parser, ctx);
    defer ctx.allocator.free(buf);
    defer file.close();
}

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const allocator = arena.allocator();
    defer arena.deinit();

    const default_dest = "topaz-out";
    var dest_dir_path: [std.fs.max_path_bytes]u8 = undefined;
    var dest_dir_path_len: usize = default_dest.len;
    @memcpy(dest_dir_path[0..default_dest.len], default_dest);

    var input_path: []const u8 = "."; // Default to current directory

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
            dest_dir_path_len = arg.len - 6;
            @memcpy(dest_dir_path[0..dest_dir_path_len], arg[6..]);
        }
    }

    // Collect inputs for processing
    var input_files = std.StringHashMap([]const u8).init(allocator);

    const input_path_absolute = try std.fs.realpathAlloc(allocator, input_path);
    const stat = try std.fs.cwd().statFile(input_path_absolute);
    print("Input arg resolved to '{s}'\n", .{input_path_absolute});

    // Collect all .md files from dirs
    if (stat.kind == .directory) {
        var dir = try std.fs.cwd().openDir(input_path_absolute, .{ .iterate = true });
        defer dir.close();
        var walker = try dir.walk(allocator);

        while (try walker.next()) |entry| {
            if (entry.kind == .file and mem.eql(u8, std.fs.path.extension(entry.basename), ".md")) {
                const full_path = try std.fs.path.join(allocator, &[_][]const u8{ input_path_absolute, entry.path });
                const rel_path = try allocator.dupe(u8, entry.path);
                try input_files.put(full_path, rel_path);
            }
        }
        // Collect individual files
    } else if (stat.kind == .file and mem.eql(u8, std.fs.path.extension(input_path_absolute), ".md")) {
        try input_files.put(input_path_absolute, std.fs.path.basename(input_path_absolute));
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

    // Create the output directory
    const dest_dir = std.fs.path.resolve(allocator, &[_][]const u8{dest_dir_path[0..dest_dir_path_len]}) catch |err| {
        print("Failed to resolve dest path: {any}\n", .{err});
        return err;
    };
    @memcpy(dest_dir_path[0..dest_dir.len], dest_dir);
    dest_dir_path_len = dest_dir.len;
    print("Out dir is \"{s}\"\n", .{dest_dir_path[0..dest_dir_path_len]});
    try std.fs.cwd().makePath(dest_dir);

    var iter = input_files.iterator();
    while (iter.next()) |entry| {
        const file_path = entry.key_ptr.*;
        const relative_path = entry.value_ptr.*;

        const file = try std.fs.cwd().openFile(file_path, .{});
        const file_stat = try file.stat();

        const dir_part = std.fs.path.dirname(relative_path) orelse "";
        const dest_dir_full = if (dir_part.len > 0)
            try std.fs.path.join(allocator, &[_][]const u8{ dest_dir_path[0..dest_dir_path_len], dir_part })
        else
            dest_dir_path[0..dest_dir_path_len];

        try std.fs.cwd().makePath(dest_dir_full);

        const page_name = std.fs.path.stem(std.fs.path.basename(relative_path));
        const html_filename = try std.fmt.allocPrint(allocator, "{s}.html", .{page_name});

        const dest_path = try std.fs.path.join(allocator, &[_][]const u8{ dest_dir_full, html_filename });
        const dest_file = try std.fs.cwd().createFile(dest_path, .{});
        defer dest_file.close();

        var ctx = try RenderContext.init(allocator, page_name);
        defer ctx.deinit();

        print("Processing {s} ({d}b)-> {s}\n", .{ file_path, file_stat.size, dest_path });

        // Render HTMl
        try ctx.writeHtmlHead();
        try processFile(file, &parser, &ctx);
        try ctx.writeHtmlTail();

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
