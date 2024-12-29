const std = @import("std");
const builtin = @import("builtin");
const c = @cImport({
    @cInclude("md4c.h");
});

fn enter_block(blk: c.MD_BLOCKTYPE, detail: ?*anyopaque, usedetail: ?*anyopaque) callconv(.C) c_int {
    _ = usedetail; // autofix
    _ = detail; // autofix
    std.debug.print("Entering block {any}\n", .{blk});
    return 0;
}

fn leave_block(blk: c.MD_BLOCKTYPE, detail: ?*anyopaque, usedetail: ?*anyopaque) callconv(.C) c_int {
    _ = usedetail; // autofix
    _ = detail; // autofix
    std.debug.print("Leaving block {any}\n", .{blk});
    return 0;
}

fn enter_span(blk: c.MD_SPANTYPE, detail: ?*anyopaque, usedetail: ?*anyopaque) callconv(.C) c_int {
    _ = usedetail; // autofix
    _ = detail; // autofix
    std.debug.print("Entering span {any}\n", .{blk});
    return 0;
}

fn leave_span(blk: c.MD_SPANTYPE, detail: ?*anyopaque, usedetail: ?*anyopaque) callconv(.C) c_int {
    _ = usedetail; // autofix
    _ = detail; // autofix
    std.debug.print("Leaving span {any}\n", .{blk});
    return 0;
}

fn text(blk: c.MD_TEXTTYPE, char: [*c]const c.MD_CHAR, size: c.MD_SIZE, userdata: ?*anyopaque) callconv(.C) c_int {
    _ = blk;
    _ = userdata;
    std.debug.print("Handling text {any} of size {any}\n", .{ char, size });
    return 0;
}

pub fn main() !void {
    var alloc = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = alloc.deinit();
    const allocator = alloc.allocator();

    var parser = c.MD_PARSER{
        .abi_version = 0,
        .flags = c.MD_FLAG_TABLES | c.MD_FLAG_TASKLISTS | c.MD_FLAG_WIKILINKS | c.MD_FLAG_LATEXMATHSPANS | c.MD_FLAG_PERMISSIVEAUTOLINKS,

        // TODO: implement
        .enter_block = enter_block,
        .leave_block = leave_block,
        .enter_span = enter_span,
        .leave_span = leave_span,
        .text = text,

        .debug_log = null,
        .syntax = null,
    };

    const md = "# Hello, world!\n\n* Foo\n* Bar\n";

    _ = c.md_parse(md, md.len, &parser, null);

    // const args = try std.process.argsAlloc(alloc);
    // defer std.process.argsFree(alloc, args);
    //
    // for (args) |arg| {
    //     std.debug.print("Arg: {s}.\n", .{arg});
    // }

    const stdout_file = std.io.getStdOut().writer();
    var bw = std.io.bufferedWriter(stdout_file);
    // const stdout = bw.writer();

    var dir = try std.fs.cwd().openDir(".", .{ .iterate = true });
    defer dir.close();
    var walker = try dir.walk(allocator);
    defer walker.deinit();

    while (try walker.next()) |entry| {
        if (entry.kind != .file) continue;
        const ext = std.fs.path.extension(entry.basename);
        if (!std.mem.eql(u8, ext, ".md")) continue;

        std.debug.print("{s}\n", .{entry.path});

        const file = try dir.openFile(entry.path, .{});
        defer file.close();

        // var bufReader = std.io.bufferedReader(file.reader());
        // var reader = bufReader.reader();
        //
        // var line = std.ArrayList(u8).init(allocator);
        // defer line.deinit();
        //
        // const writer = line.writer();
        // var line_no: usize = 0;
        // while (reader.streamUntilDelimiter(writer, '\n', null)) {
        //     // Clear the line so we can reuse it.
        //     defer line.clearRetainingCapacity();
        //     line_no += 1;
        //
        //     std.debug.print("{d}--{s}\n", .{ line_no, line.items });
        // } else |err| switch (err) {
        //     error.EndOfStream => { // end of file
        //         if (line.items.len > 0) {
        //             line_no += 1;
        //             std.debug.print("{d}--{s}\n", .{ line_no, line.items });
        //         }
        //     },
        //     else => return err, // Propagate error
        // }
        //
        // std.debug.print("Total lines: {d}\n", .{line_no});
    }

    try bw.flush(); // Don't forget to flush!
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
