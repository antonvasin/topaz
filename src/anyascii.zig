const std = @import("std");

const c = @cImport({
    @cInclude("anyascii.h");
});

pub fn transliterate(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
    if (input.len == 0) return try allocator.dupe(u8, "");

    var result = std.ArrayList(u8).init(allocator);
    defer result.deinit();

    var i: usize = 0;
    while (i < input.len) {
        const len = std.unicode.utf8ByteSequenceLength(input[i]) catch 1;
        if (i + len > input.len) break;

        const codepoint = std.unicode.utf8Decode(input[i .. i + len]) catch {
            i += 1;
            continue;
        };

        var ascii_ptr: [*c]const u8 = undefined;
        const ascii_len = c.anyascii(@intCast(codepoint), &ascii_ptr);

        if (ascii_ptr != null and ascii_len > 0) {
            try result.appendSlice(ascii_ptr[0..ascii_len]);
        }
        i += len;
    }

    return try result.toOwnedSlice();
}

