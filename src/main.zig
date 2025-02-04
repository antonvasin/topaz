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
            const str = std.fmt.bufPrint(&buf, "<h{d}>", .{@as(u8, @intCast(level))}) catch unreachable;
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
    print("{s}\n", .{tag});
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
            const str = std.fmt.bufPrint(&buf, "</h{d}>", .{@as(u8, @intCast(level))}) catch unreachable;
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
    print("{s}\n", .{tag});
    return 0;
}

fn enter_span(blk: c.MD_SPANTYPE, detail: ?*anyopaque, userdetail: ?*anyopaque) callconv(.C) c_int {
    _ = blk; // autofix
    _ = userdetail; // autofix
    _ = detail; // autofix
    print("<span>", .{});
    return 0;
}

fn leave_span(blk: c.MD_SPANTYPE, detail: ?*anyopaque, userdetail: ?*anyopaque) callconv(.C) c_int {
    _ = blk; // autofix
    _ = userdetail; // autofix
    _ = detail; // autofix
    print("</span>", .{});
    return 0;
}

fn text(blk: c.MD_TEXTTYPE, char: [*c]const c.MD_CHAR, size: c.MD_SIZE, userdata: ?*anyopaque) callconv(.C) c_int {
    _ = blk;
    _ = userdata;
    print("{s}\n", .{char[0..size]});
    return 0;
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var parser = c.MD_PARSER{
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

    var dir = try std.fs.cwd().openDir(".", .{ .iterate = true });
    defer dir.close();
    var walker = try dir.walk(allocator);
    defer walker.deinit();

    var buf: [1 << 10]u8 = undefined;
    while (try walker.next()) |entry| {
        if (entry.kind != .file) continue;
        const ext = std.fs.path.extension(entry.basename);
        if (!std.mem.eql(u8, ext, ".md")) continue;

        const file = try dir.openFile(entry.path, .{});
        const bytes_read = try file.readAll(&buf);
        if (bytes_read < buf.len) {
            // print("File {s}: {s}\n", .{ entry.path, buf });
            _ = c.md_parse(&buf, buf.len, &parser, null);
        }
        defer file.close();
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
