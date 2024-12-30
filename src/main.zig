const std = @import("std");
const builtin = @import("builtin");
const c = @cImport({
    @cInclude("md4c.h");
});

fn enter_block(blk: c.MD_BLOCKTYPE, detail: ?*anyopaque, userdetail: ?*anyopaque) callconv(.C) c_int {
    _ = detail; // autofix
    _ = userdetail;
    std.debug.print("Entering block {any}\n", .{blk});
    return 0;
}

fn leave_block(blk: c.MD_BLOCKTYPE, detail: ?*anyopaque, userdetail: ?*anyopaque) callconv(.C) c_int {
    _ = userdetail; // autofix
    _ = detail; // autofix
    std.debug.print("Leaving block {any}\n", .{blk});
    return 0;
}

fn enter_span(blk: c.MD_SPANTYPE, detail: ?*anyopaque, userdetail: ?*anyopaque) callconv(.C) c_int {
    _ = userdetail; // autofix
    _ = detail; // autofix
    std.debug.print("Entering span {any}\n", .{blk});
    return 0;
}

fn leave_span(blk: c.MD_SPANTYPE, detail: ?*anyopaque, userdetail: ?*anyopaque) callconv(.C) c_int {
    _ = userdetail; // autofix
    _ = detail; // autofix
    std.debug.print("Leaving span {any}\n", .{blk});
    return 0;
}

fn text(blk: c.MD_TEXTTYPE, char: [*c]const c.MD_CHAR, size: c.MD_SIZE, userdata: ?*anyopaque) callconv(.C) c_int {
    _ = blk;
    _ = userdata;
    std.debug.print("Handling text {s}\n", .{char[0..size]});
    return 0;
}

pub fn main() !void {
    var alloc = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = alloc.deinit();
    const allocator = alloc.allocator();

    // const args = try std.process.argsAlloc(alloc);
    // defer std.process.argsFree(alloc, args);
    //
    // for (args) |arg| {
    //     std.debug.print("Arg: {s}.\n", .{arg});
    // }

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
            // std.debug.print("File {s}: {s}\n", .{ entry.path, buf });
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
