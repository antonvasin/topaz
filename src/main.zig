const std = @import("std");
const builtin = @import("builtin");
const c = @cImport({
    @cInclude("md4c.h");
});

const print = std.debug.print;

const html_head_open =
    \\<!DOCTYPE html>
    \\<html>
    \\  <head>
    \\    <meta name="generator" content="topaz">
    \\    <meta charset="UTF-8">
    \\
;

const html_head_close = "\n</head>\n";
const html_body_open = "  <body>\n";
const html_body_close = "  </body>\n</html>";

const RenderContext = struct {
    buf: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    page_title: []const u8 = "",
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
        c.MD_BLOCK_QUOTE => "<blockquote>\n",
        c.MD_BLOCK_UL => "<ul>\n",
        c.MD_BLOCK_OL => "<ol>\n",
        c.MD_BLOCK_LI => "<li>\n",
        c.MD_BLOCK_HR => "<hr>\n",
        c.MD_BLOCK_H => blk: {
            const level = @as(*const c.MD_BLOCK_H_DETAIL, @ptrCast(@alignCast(detail))).level;
            break :blk headers_openning_tags[level - 1];
        },
        c.MD_BLOCK_CODE => "<pre>\n<code>\n",
        c.MD_BLOCK_P => "<p>\n",
        c.MD_BLOCK_TABLE => "<table>\n",
        c.MD_BLOCK_THEAD => "<thead>\n",
        c.MD_BLOCK_TBODY => "<tbody>\n",
        c.MD_BLOCK_TR => "<tr>\n",
        c.MD_BLOCK_TH => "<th>",
        c.MD_BLOCK_TD => "<td>",
        else => "",
    };

    ctx.buf.appendSlice(tag) catch return 1;

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
        c.MD_BLOCK_QUOTE => "</blockquote>\n",
        c.MD_BLOCK_UL => "</ul>\n",
        c.MD_BLOCK_OL => "</ol>\n",
        c.MD_BLOCK_LI => "</li>\n",
        c.MD_BLOCK_H => blk: {
            const level = @as(*const c.MD_BLOCK_H_DETAIL, @ptrCast(@alignCast(detail))).level;
            break :blk headers_closing_tags[level - 1];
        },
        c.MD_BLOCK_CODE => "</pre>\n</code>\n",
        c.MD_BLOCK_P => "</p>\n",
        c.MD_BLOCK_TABLE => "</table>\n",
        c.MD_BLOCK_THEAD => "</thead>\n",
        c.MD_BLOCK_TBODY => "</tbody>\n",
        c.MD_BLOCK_TR => "</tr>\n",
        c.MD_BLOCK_TH => "</th>\n",
        c.MD_BLOCK_TD => "</td>\n",
        else => "",
    };

    ctx.buf.appendSlice(tag) catch return 1;

    return 0;
}

fn enter_span(blk: c.MD_SPANTYPE, detail: ?*anyopaque, userdata: ?*anyopaque) callconv(.C) c_int {
    const ctx = @as(*RenderContext, @ptrCast(@alignCast(userdata)));

    // TODO: add support for span attributes
    const tag = switch (blk) {
        c.MD_SPAN_EM => "<em>",
        c.MD_SPAN_STRONG => "<strong>",
        c.MD_SPAN_U => "<u>",
        c.MD_SPAN_A => {
            const a_detail = @as(*const c.MD_SPAN_A_DETAIL, @ptrCast(@alignCast(detail)));
            ctx.buf.appendSlice("<a href=\"") catch return 1;
            ctx.buf.appendSlice(a_detail.href.text[0..a_detail.href.size]) catch return 1;
            ctx.buf.appendSlice("\">") catch return 1;

            return 0;
        },
        c.MD_SPAN_IMG => "<img>",
        c.MD_SPAN_CODE => "<code>",
        c.MD_SPAN_DEL => "<del>",
        c.MD_SPAN_LATEXMATH => "<x-equation>",
        c.MD_SPAN_LATEXMATH_DISPLAY => "<x-equation type=\"display\">",
        c.MD_SPAN_WIKILINK => "<a>",
        else => "---",
    };
    ctx.buf.appendSlice(tag) catch return 1;

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

    return 0;
}

fn text(blk: c.MD_TEXTTYPE, char: [*c]const c.MD_CHAR, size: c.MD_SIZE, userdata: ?*anyopaque) callconv(.C) c_int {
    const ctx = @as(*RenderContext, @ptrCast(@alignCast(userdata)));
    const slice = char[0..size];

    // TODO: handle text type
    _ = blk;
    ctx.buf.appendSlice(slice) catch return 1;
    return 0;
}

fn processFile(file: std.fs.File, parser: *const c.MD_PARSER, ctx: *RenderContext) !void {
    const file_size = try file.getEndPos();
    var buf = try ctx.allocator.alloc(u8, file_size);
    errdefer ctx.allocator.free(buf);
    const bytes_read = try file.readAll(buf);
    var yaml_end: usize = 0;

    // Cutting out YAML
    if (std.mem.startsWith(u8, buf, "---\n")) {
        var i: usize = 4;
        while (i < buf.len - 3) {
            if (std.mem.eql(u8, buf[i .. i + 4], "\n---")) yaml_end = i + 4;
            i += 1;
        }
    }

    if (yaml_end != 0) print("YAML found [0..{d}]\n", .{yaml_end});
    _ = c.md_parse(@ptrCast(&buf[yaml_end]), @intCast(bytes_read - yaml_end), parser, ctx);
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

    // User arguments - support only one input path or current directory if none provided
    var input_path: []const u8 = "."; // Default to current directory

    const args = try std.process.argsAlloc(allocator);
    // Parse the command line arguments. Config arguments that take a value
    // must use '='. The first non-flag argument is treated as input source.
    var found_input = false;
    for (args[1..]) |arg| {
        if (!std.mem.startsWith(u8, arg, "--")) {
            if (!found_input) {
                input_path = arg;
                found_input = true;
            }
        } else if (std.mem.startsWith(u8, arg, "--out=")) {
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
            if (entry.kind == .file and std.mem.eql(u8, std.fs.path.extension(entry.basename), ".md")) {
                const full_path = try std.fs.path.join(allocator, &[_][]const u8{ input_path_absolute, entry.path });
                const rel_path = try allocator.dupe(u8, entry.path);
                try input_files.put(full_path, rel_path);
            }
        }
        // Collect individual files
    } else if (stat.kind == .file and std.mem.eql(u8, std.fs.path.extension(input_path_absolute), ".md")) {
        try input_files.put(input_path_absolute, std.fs.path.basename(input_path_absolute));
    }

    const parser = c.MD_PARSER{
        .abi_version = 0,
        .flags = c.MD_FLAG_TABLES | c.MD_FLAG_TASKLISTS | c.MD_FLAG_WIKILINKS | c.MD_FLAG_LATEXMATHSPANS | c.MD_FLAG_PERMISSIVEAUTOLINKS | c.MD_FLAG_STRIKETHROUGH,
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

    // Process input items
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

        // Create full destination path
        const dest_path = try std.fs.path.join(allocator, &[_][]const u8{ dest_dir_full, html_filename });
        const dest_file = try std.fs.cwd().createFile(dest_path, .{});
        defer dest_file.close();

        var out_buf = std.ArrayList(u8).init(allocator);
        defer out_buf.deinit();

        var ctx = RenderContext{
            .buf = &out_buf,
            .allocator = allocator,
            .page_title = page_name,
        };

        try out_buf.appendSlice(html_head_open);
        try out_buf.appendSlice(html_head_close);
        try out_buf.appendSlice(html_body_open);

        try processFile(file, &parser, &ctx);
        try out_buf.appendSlice(html_body_close);
        try out_buf.append('\n');
        print("Processing {s} ({d}b)-> {s} ({d}b)...\n\n", .{ file_path, file_stat.size, dest_path, out_buf.items.len * @sizeOf(u8) });
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
