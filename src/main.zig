const std = @import("std");
const builtin = @import("builtin");
const Parser = @import("./md.zig").Parser;
const RenderContext = @import("./render_html.zig").RenderContext;
const graph = @import("./graph.zig");
const PageGraph = graph.PageGraph;
const Page = graph.Page;
const log = @import("./utils.zig").log;
const parse_html = @import("./parse_html.zig");

const print = std.debug.print;
const mem = std.mem;
const assert = std.debug.assert;
const testing = std.testing;

var debug_enabled: bool = false;

pub const std_options: std.Options = .{
    .logFn = struct {
        pub fn logFn(
            comptime level: std.log.Level,
            comptime scope: @TypeOf(.enum_literal),
            comptime format: []const u8,
            args: anytype,
        ) void {
            if (scope == .parser or scope == .tokenizer) {
                if (level != .err) return;
            }
            if (level == .debug and !debug_enabled) return;
            std.log.defaultLog(level, scope, format, args);
        }
    }.logFn,
    .log_scope_levels = &.{
        .{ .scope = .parser, .level = .err },
        .{ .scope = .tokenizer, .level = .err },
    },
};

/// Read file from disk, parse metadata and add to graph
fn processFile(allocator: mem.Allocator, file_path: []const u8, page_graph: *PageGraph, config: *Config) !void {
    const full_path = try std.fs.path.join(allocator, &[_][]const u8{ config.input_path, file_path });
    const file = std.fs.cwd().openFile(full_path, .{}) catch |err| {
        log.err("Failed to read {s}, skipping\n", .{full_path});
        return err;
    };
    defer allocator.free(full_path);

    const file_size = try file.getEndPos();
    print("Processing {s} ({d}b)\n", .{ file_path, file_size });
    const buf = try allocator.alloc(u8, file_size);
    errdefer allocator.free(buf);
    _ = try file.readAll(buf);

    const page = try Page.init(allocator, file_path, buf);

    try page_graph.addPage(page);

    defer file.close();
}

const Config = struct {
    /// Defaults to current directory
    input_path: []const u8,
    /// Defaults to 'topaz-out'
    output_path: []const u8,
    /// Debug output
    is_debug: bool = false,
    /// Defaults to 'template.html'
    template: ?[]const u8 = null,
    template_file: ?[]const u8 = null,
};

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const allocator = arena.allocator();
    defer arena.deinit();

    var config = Config{ .input_path = ".", .output_path = "topaz-out", .is_debug = false };

    const args = try std.process.argsAlloc(allocator);
    // Parse the command line arguments. Config arguments that take a value
    // must use '='. The first non-flag argument is treated as input source.
    // TODO: add support for list of inputs
    var found_input = false;
    for (args[1..]) |arg| {
        if (mem.eql(u8, arg, "--debug")) {
            config.is_debug = true;
            debug_enabled = true;
        } else if (!mem.startsWith(u8, arg, "--")) {
            if (!found_input) {
                config.input_path = arg;
                found_input = true;
            }
        } else if (mem.startsWith(u8, arg, "--out=")) {
            config.output_path = arg[6..];
            log.info("Out dir is \"{s}\"\n", .{config.output_path});
        } else if (mem.startsWith(u8, arg, "--template=")) {
            config.template = arg[11..];
            log.info("Using template {s}", .{config.template.?});
        }
    }

    var input_files = std.ArrayList([]const u8).empty;

    const stat = try std.fs.cwd().statFile(config.input_path);

    // Collect all .md files from dirs
    if (stat.kind == .directory) {
        var dir = try std.fs.cwd().openDir(config.input_path, .{ .iterate = true });
        defer dir.close();
        var walker = try dir.walk(allocator);

        while (try walker.next()) |entry| {
            if (entry.kind == .file and mem.eql(u8, std.fs.path.extension(entry.basename), ".md")) {
                const path = try allocator.dupe(u8, entry.path);
                try input_files.append(allocator, path);
            }
        }
    } else if (stat.kind == .file and mem.eql(u8, std.fs.path.extension(config.input_path), ".md")) {
        // Collect individual input files
        try input_files.append(allocator, config.input_path);
    }

    var parser = try Parser.init();

    // Create output directory
    const dest_dir = std.fs.path.resolve(allocator, &[_][]const u8{config.output_path}) catch |err| {
        std.log.err("Failed to resolve dest path: {any}\n", .{err});
        return err;
    };
    try std.fs.cwd().makePath(dest_dir);

    // Process files
    var page_graph = try PageGraph.init(allocator);
    var contexts = std.ArrayList(RenderContext).empty;

    if (config.template) |template| {
        const tmpl_stat = try std.fs.cwd().statFile(template);
        const data = try std.fs.Dir.readFileAlloc(std.fs.cwd(), allocator, template, tmpl_stat.size);
        config.template_file = data;
    }

    // First pass: read files into memory and parse metadata
    for (input_files.items) |path| {
        try processFile(allocator, path, &page_graph, &config);
        const page_name = path[0 .. path.len - 3];
        var ctx = try RenderContext.init(allocator, &page_graph);
        if (config.template_file) |template| ctx.template = .{ .content = template };
        ctx.cur_page = page_name;
        try contexts.append(allocator, ctx);
    }

    // Second pass: parse markdown and index blocks/links
    for (page_graph.page_list.items, 0..) |*page, i| {
        if (page.meta.skip) continue;
        try contexts.items[i].writeHtmlHead(page.meta.title);
        parser.parse(page.markdown, &contexts.items[i]);
    }

    // Third pass: write to disk
    for (page_graph.page_list.items, 0..) |*page, i| {
        if (page.meta.skip) continue;
        log.debug("Writing {s}", .{page.out_path});
        var ctx = &contexts.items[i];
        // TODO: write header/footer to separate bufs so we can prepend generated HTML later
        try ctx.writeFooter();
        try ctx.writeHtmlTail();

        const dir_path = if (std.fs.path.dirname(page.out_path)) |dir|
            try std.fs.path.join(allocator, &[_][]const u8{ config.output_path, dir })
        else
            config.output_path;

        const out_path = try std.fs.path.join(allocator, &[_][]const u8{ config.output_path, page.out_path });
        try std.fs.cwd().makePath(dir_path);
        const dest_file = try std.fs.cwd().createFile(out_path, .{});
        defer dest_file.close();
        try dest_file.writeAll(ctx.buf.items);
    }
}

test "Page" {
    const allocator = std.testing.allocator;

    {
        const buf: []const u8 =
            \\---
            \\title: "Note Title"
            \\---
            \\
            \\# Note
            \\
            \\Paragraph text
        ;
        var page = try Page.init(allocator, "note.md", buf);
        defer page.deinit(allocator);
        try testing.expect(mem.eql(u8, page.name, "note"));
        try testing.expect(mem.eql(u8, page.meta.title, "Note Title"));
        try testing.expectEqual(page.meta.skip, false);
    }

    {
        const buf: []const u8 =
            \\---
            \\title: "Note Title"
            \\publish: false
            \\---
            \\# Note
            \\
            \\Paragraph text
        ;

        var page = try Page.init(allocator, "note.md", buf);
        defer page.deinit(allocator);
        try testing.expectEqual(page.meta.skip, true);
    }
}

test "RenderContext" {
    const allocator = std.testing.allocator;

    var page_graph = try PageGraph.init(allocator);
    var ctx = try RenderContext.init(allocator, &page_graph);
    defer ctx.deinit();

    try ctx.writeHtmlHead("Page Title");
    try ctx.writeOpen("<h1>");
    try ctx.writeString("Page ");
    try ctx.writeString("<em>");
    try ctx.writeString("Title");
    try ctx.writeString("</em>");
    try ctx.writeClose("</h1>");
    try ctx.writeOpen("<p>");
    try ctx.writeString("Paragraph text.");
    try ctx.writeOpen("<ul>");
    for (0..3) |_| {
        try ctx.writeOpen("<li>");
        try ctx.writeString("List item");
        try ctx.writeClose("</li>");
    }
    try ctx.writeClose("</ul>");
    try ctx.writeClose("</p>");
    try ctx.writeHtmlTail();

    const buf =
        \\<!DOCTYPE html>
        \\<html>
        \\    <head>
        \\        <meta charset="UTF-8">
        \\        <meta name="generator" content="topaz">
        \\        <title>Page Title</title>
        \\    </head>
        \\    <body>
        \\        <h1>
        \\            Page <em>Title</em>
        \\        </h1>
        \\        <p>
        \\            Paragraph text.
        \\            <ul>
        \\                <li>
        \\                    List item
        \\                </li>
        \\                <li>
        \\                    List item
        \\                </li>
        \\                <li>
        \\                    List item
        \\                </li>
        \\            </ul>
        \\        </p>
        \\    </body>
        \\</html>
        \\
    ;

    testing.expect(mem.eql(u8, ctx.buf.items, buf)) catch |err| {
        print("\n\ngot:\n---\n{s}\n---\n\nexpected:\n---\n{s}\n---\n", .{ ctx.buf.items, buf });
        return err;
    };
}

// FIXME:
test {
    _ = parse_html;
}
