const std = @import("std");
const builtin = @import("builtin");

const c = @cImport({
    @cInclude("md4c.h");
});

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

    const stdout_file = std.io.getStdOut().writer();
    var bw = std.io.bufferedWriter(stdout_file);
    // const stdout = bw.writer();

    var dir = try std.fs.cwd().openDir(".", .{ .iterate = true });
    defer dir.close();
    var walker = try dir.walk(allocator);
    defer walker.deinit();


    while (try walker.next()) |entry| {
        if (entry.kind == .file) {
            const ext = std.fs.path.extension(entry.basename);
            if (std.mem.eql(u8, ext, ".md")) {
                std.debug.print("Processing {s}...\n", .{entry.path});
                const file = try dir.openFile(entry.path, .{});
                const bufReader = std.io.bufferedReader(file.reader());
                var line = std.ArrayList(u8).init(allocator);
                defer line.deinit();


                defer file.close();
            }
        }
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
