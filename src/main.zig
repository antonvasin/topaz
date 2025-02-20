const std = @import("std");
const builtin = @import("builtin");
const print = std.debug.print;
const c = @cImport({
    @cInclude("md4c.h");
});

const INDENT_STEP = "  ";

const html_head_open =
    \\<!DOCTYPE html>
    \\<html>
    \\  <head>
    \\    <meta name="generator" content="topaz">
    \\    <meta charset="UTF-8">
;

const html_head_close =
    \\
    \\  </head>
    \\  <body>
;

const html_body_close =
    \\
    \\  </body>
    \\</html>
;

const RenderContext = struct {
    buf: *std.ArrayList(u8),
    indent_level: usize = 0,
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

    const tag = switch (blk) {
        c.MD_BLOCK_DOC => "<body>",
        c.MD_BLOCK_QUOTE => "<blockquote>",
        c.MD_BLOCK_UL => "<ul>",
        c.MD_BLOCK_OL => "<ol>",
        c.MD_BLOCK_LI => "<li>",
        c.MD_BLOCK_HR => "<hr>",
        c.MD_BLOCK_H => blk: {
            const level = @as(*const c.MD_BLOCK_H_DETAIL, @ptrCast(@alignCast(detail))).level;
            break :blk headers_openning_tags[level - 1];
        },
        c.MD_BLOCK_CODE => "<pre><code>",
        c.MD_BLOCK_HTML => "<html>",
        c.MD_BLOCK_P => "<p>",
        c.MD_BLOCK_TABLE => "<table>",
        c.MD_BLOCK_THEAD => "<thead>",
        c.MD_BLOCK_TBODY => "<tbody>",
        c.MD_BLOCK_TR => "<tr>",
        c.MD_BLOCK_TH => "<th>",
        c.MD_BLOCK_TD => "<td>",
        else => "----",
    };
    ctx.buf.appendSlice(tag) catch return 1;
    ctx.buf.append('\n') catch return 1;

    return 0;
}

fn leave_block(blk: c.MD_BLOCKTYPE, detail: ?*anyopaque, userdata: ?*anyopaque) callconv(.C) c_int {
    const ctx = @as(*RenderContext, @ptrCast(@alignCast(userdata)));

    const headers_closing_tags: [6][]const u8 = .{
        "</h1>\n",
        "</h2>\n",
        "</h3>\n",
        "</h4>\n",
        "</h5>\n",
        "</h6>\n",
    };

    const tag = switch (blk) {
        c.MD_BLOCK_DOC => "</body>",
        c.MD_BLOCK_QUOTE => "</blockquote>",
        c.MD_BLOCK_UL => "</ul>",
        c.MD_BLOCK_OL => "</ol>",
        c.MD_BLOCK_LI => "</li>",
        c.MD_BLOCK_HR => "</hr>",
        c.MD_BLOCK_H => blk: {
            const level = @as(*const c.MD_BLOCK_H_DETAIL, @ptrCast(@alignCast(detail))).level;
            break :blk headers_closing_tags[level - 1];
        },
        c.MD_BLOCK_CODE => "</pre></code>",
        c.MD_BLOCK_HTML => "</html>",
        c.MD_BLOCK_P => "</p>",
        c.MD_BLOCK_TABLE => "</table>",
        c.MD_BLOCK_THEAD => "</thead>",
        c.MD_BLOCK_TBODY => "</tbody>",
        c.MD_BLOCK_TR => "</tr>",
        c.MD_BLOCK_TH => "</th>",
        c.MD_BLOCK_TD => "</td>",
        else => "----",
    };

    ctx.buf.appendSlice(tag) catch return 1;
    ctx.buf.append('\n') catch return 1;

    return 0;
}

fn enter_span(blk: c.MD_SPANTYPE, detail: ?*anyopaque, userdata: ?*anyopaque) callconv(.C) c_int {
    const ctx = @as(*RenderContext, @ptrCast(@alignCast(userdata)));
    _ = detail; // autofix

    // TODO: add support for span attributes
    const tag = switch (blk) {
        c.MD_SPAN_EM => "<em>",
        c.MD_SPAN_STRONG => "<strong>",
        c.MD_SPAN_U => "<u>",
        c.MD_SPAN_A => "<a>",
        c.MD_SPAN_IMG => "<img>",
        c.MD_SPAN_CODE => "<code>",
        c.MD_SPAN_DEL => "<del>",
        c.MD_SPAN_LATEXMATH => "<x-equation>",
        c.MD_SPAN_LATEXMATH_DISPLAY => "<x-equation type=\"display\">",
        c.MD_SPAN_WIKILINK => "<a>",
        else => "---",
    };
    ctx.buf.appendSlice(tag) catch return 1;
    ctx.buf.append('\n') catch return 1;

    return 0;
}

fn leave_span(blk: c.MD_SPANTYPE, detail: ?*anyopaque, userdata: ?*anyopaque) callconv(.C) c_int {
    const ctx = @as(*RenderContext, @ptrCast(@alignCast(userdata)));
    _ = detail; // autofix

    // TODO: add support for span attributes
    const tag = switch (blk) {
        c.MD_SPAN_EM => "</em>",
        c.MD_SPAN_STRONG => "</strong>",
        c.MD_SPAN_U => "</u>",
        c.MD_SPAN_A => "</a>",
        c.MD_SPAN_IMG => "</img>",
        c.MD_SPAN_CODE => "</code>",
        c.MD_SPAN_DEL => "</del>",
        c.MD_SPAN_LATEXMATH => "</x-equation>",
        c.MD_SPAN_LATEXMATH_DISPLAY => "</x-equation type=\"display\">",
        c.MD_SPAN_WIKILINK => "</a>",
        else => "---",
    };

    ctx.buf.appendSlice(tag) catch return 1;
    ctx.buf.append('\n') catch return 1;

    return 0;
}

fn text(blk: c.MD_TEXTTYPE, char: [*c]const c.MD_CHAR, size: c.MD_SIZE, userdata: ?*anyopaque) callconv(.C) c_int {
    const ctx = @as(*RenderContext, @ptrCast(@alignCast(userdata)));
    _ = blk;
    ctx.buf.appendSlice(char[0..size]) catch return 1;
    return 0;
}

fn processFile(file: std.fs.File, parser: *const c.MD_PARSER, ctx: *RenderContext) !void {
    var buf: [1 << 10]u8 = undefined;
    const bytes_read = try file.readAll(&buf);
    if (bytes_read < buf.len) {
        // _ = c.md_parse(&buf, @intCast(bytes_read), parser, @ptrCast(@constCast(&out_buf)));
        _ = c.md_parse(&buf, @intCast(bytes_read), parser, ctx);
    }
    defer file.close();
}

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const args = try std.process.argsAlloc(allocator);
    var dest_arg: [std.fs.max_path_bytes]u8 = undefined;
    var dest_len: usize = 0;

    const default_dest = ".";
    @memcpy(dest_arg[0..default_dest.len], default_dest);
    dest_len = default_dest.len;

    // User arguments
    var arg_sources = std.ArrayList([]const u8).init(allocator);

    // Parse the command line arguments. Config arguments that take a value
    // must use '='. All arguments not starting with '--' are treated as input sources.
    for (args[1..]) |arg| {
        if (!std.mem.startsWith(u8, arg, "--")) {
            try arg_sources.append(arg);
            continue;
        } else {
            if (std.mem.startsWith(u8, arg, "--out=")) {
                const out = arg[6..];
                @memcpy(dest_arg[0..out.len], out);
                dest_len = out.len;
            }
        }
    }

    try std.fs.cwd().makePath(dest_arg[0..dest_len]);
    const resolved_dest = try std.fs.realpathAlloc(allocator, dest_arg[0..dest_len]);
    @memcpy(dest_arg[0..resolved_dest.len], resolved_dest);
    dest_len = resolved_dest.len;

    if (arg_sources.items.len > 0) {
        print("Sources to convert: ", .{});
        for (arg_sources.items, 0..) |source, i| {
            if (i > 0) print(", ", .{});
            print("\"{s}\"", .{source});
        }
        print("\n", .{});
    }

    print("Out dir is \"{s}\"\n", .{dest_arg[0..dest_len]});

    const parser = c.MD_PARSER{
        .abi_version = 0,
        .flags = c.MD_FLAG_TABLES | c.MD_FLAG_TASKLISTS | c.MD_FLAG_WIKILINKS | c.MD_FLAG_LATEXMATHSPANS | c.MD_FLAG_PERMISSIVEAUTOLINKS,
        .enter_block = enter_block,
        .leave_block = leave_block,
        .enter_span = enter_span,
        .leave_span = leave_span,
        .text = text,
        .debug_log = null,
        .syntax = null,
    };

    // Collect inputs for processing
    var processed_sources = std.StringHashMap([]const u8).init(allocator);

    for (arg_sources.items) |source| {
        const path = try std.fs.realpathAlloc(allocator, source);
        const stat = try std.fs.cwd().statFile(path);

        if (stat.kind == .directory) {
            // Collect all .md files from dirs
            var dir = try std.fs.cwd().openDir(".", .{ .iterate = true });
            defer dir.close();
            var walker = try dir.walk(allocator);

            while (try walker.next()) |entry| {
                if (entry.kind == .file and std.mem.eql(u8, std.fs.path.extension(entry.basename), ".md")) {
                    const absolute_path = try std.fs.realpathAlloc(allocator, entry.path);
                    _ = try processed_sources.getOrPut(absolute_path);
                }
            }
        } else if (stat.kind == .file and std.mem.eql(u8, std.fs.path.extension(path), ".md")) {
            // Collect individual files
            const path_copy = try allocator.dupe(u8, path);
            _ = try processed_sources.getOrPut(path_copy);
        }
    }

    var iter = processed_sources.keyIterator();
    while (iter.next()) |path| {
        const file = try std.fs.cwd().openFile(path.*, .{});
        const stat = try file.stat();

        // Constructing "/dest/path/file.html"
        const dest_path = try std.fs.path.join(allocator, &[_][]const u8{ dest_arg[0..dest_len], try std.fmt.allocPrint(allocator, "{s}.html", .{std.fs.path.stem(path.*)}) });
        const dest_file = try std.fs.createFileAbsolute(dest_path, .{});
        defer dest_file.close();

        var out_buf = std.ArrayList(u8).init(allocator);
        defer out_buf.deinit();

        var ctx = RenderContext{
            .buf = &out_buf,
        };

        try out_buf.appendSlice(html_head_open);
        try out_buf.appendSlice(html_head_close);

        print("Processing {s} ({d} bytes) -> {s}...\n\n", .{ path.*, stat.size, dest_path });

        try processFile(file, &parser, &ctx);
        try out_buf.appendSlice(html_body_close);
        try out_buf.append('\n');
        const fw = dest_file.writer();
        _ = try fw.writeAll(out_buf.items);
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
//     try std.testing.expect(!std.mem.eql(u8, "canyoufindme", input_bytes));
// }
