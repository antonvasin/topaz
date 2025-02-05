const std = @import("std");
const builtin = @import("builtin");
const print = std.debug.print;
const c = @cImport({
    @cInclude("md4c.h");
});

fn enter_block(blk: c.MD_BLOCKTYPE, detail: ?*anyopaque, userdetail: ?*anyopaque) callconv(.C) c_int {
    _ = userdetail; // autofix
    const tag = switch (blk) {
        c.MD_BLOCK_DOC => "<body>",
        c.MD_BLOCK_QUOTE => "<blockquote>",
        c.MD_BLOCK_UL => "<ul>",
        c.MD_BLOCK_OL => "<ol>",
        c.MD_BLOCK_LI => "<li>",
        c.MD_BLOCK_HR => "<hr>",
        c.MD_BLOCK_H => blk: {
            var buf: [16]u8 = undefined;
            const level = @as(*const c.MD_BLOCK_H_DETAIL, @ptrCast(@alignCast(detail))).level;
            const str = std.fmt.bufPrint(&buf, "<h{d}>", .{@as(u32, @intCast(level))}) catch unreachable;
            break :blk str;
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
    print("{s}", .{tag});
    return 0;
}

fn leave_block(blk: c.MD_BLOCKTYPE, detail: ?*anyopaque, userdetail: ?*anyopaque) callconv(.C) c_int {
    _ = userdetail; // autofix
    const tag = switch (blk) {
        c.MD_BLOCK_DOC => "</body>",
        c.MD_BLOCK_QUOTE => "</blockquote>",
        c.MD_BLOCK_UL => "</ul>",
        c.MD_BLOCK_OL => "</ol>",
        c.MD_BLOCK_LI => "</li>",
        c.MD_BLOCK_HR => "</hr>",
        c.MD_BLOCK_H => blk: {
            var buf: [16]u8 = undefined;
            const level = @as(*const c.MD_BLOCK_H_DETAIL, @ptrCast(@alignCast(detail))).level;
            const str = std.fmt.bufPrint(&buf, "</h{d}>", .{@as(u32, @intCast(level))}) catch unreachable;
            break :blk str;
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
    print("{s}", .{tag});
    return 0;
}

fn enter_span(blk: c.MD_SPANTYPE, detail: ?*anyopaque, userdetail: ?*anyopaque) callconv(.C) c_int {
    _ = userdetail; // autofix
    _ = detail; // autofix

    // FIXME: add support for span attributes
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
        else => "---"
    };

    print("{s}", .{tag});
    return 0;
}

fn leave_span(blk: c.MD_SPANTYPE, detail: ?*anyopaque, userdetail: ?*anyopaque) callconv(.C) c_int {
    _ = userdetail; // autofix
    _ = detail; // autofix

    // FIXME: add support for span attributes
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
        else => "---"
    };

    print("{s}", .{tag});
    return 0;
}

fn text(blk: c.MD_TEXTTYPE, char: [*c]const c.MD_CHAR, size: c.MD_SIZE, userdata: ?*anyopaque) callconv(.C) c_int {
    _ = blk;
    _ = userdata;
    print("{s}", .{char[0..size]});
    return 0;
}

fn processFile(path: []const u8, parser: *const c.MD_PARSER) !void {
    print("Processing '{s}...'\n", .{path});
    var buf: [1 << 10]u8 = undefined;
    const file = try std.fs.cwd().openFile(path, .{});
    const bytes_read = try file.readAll(&buf);
    if (bytes_read < buf.len) {
        // TODO: we probably want a nice wrapper around md4c and its C types
        _ = c.md_parse(&buf, @intCast(bytes_read), parser, null);
        print("\n\n", .{});
    }
    defer file.close();
}

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const args = try std.process.argsAlloc(allocator);

    // User arguments
    var arg_sources = std.ArrayList([]const u8).init(allocator);

    // Parse the command line arguments. Config arguments that take a value
    // must use '='. All arguments not starting with '--' are treated as input sources.
    for (args[1..]) |arg| {
        if (!std.mem.startsWith(u8, arg, "--")) {
            try arg_sources.append(arg);
            continue;
        }
    }

    if (arg_sources.items.len > 0) {
        print("Sources to convert:\n", .{});
        for (arg_sources.items) |source| {
            print("{s}\n", .{source});
        }
        print("\n", .{});
    }

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
    while (iter.next()) |file| {
        try processFile(file.*, &parser);
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
