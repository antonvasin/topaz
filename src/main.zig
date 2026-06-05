const std = @import("std");
const print = std.debug.print;
const mem = std.mem;
const assert = std.debug.assert;
const testing = std.testing;
const builtin = @import("builtin");

const DB = @import("./db.zig").DB;
const graph = @import("./graph.zig");
const PageGraph = graph.PageGraph;
const Page = graph.Page;
const md = @import("./md.zig");
const Parser = md.Parser;
const parse_html = @import("./parse_html.zig");
const render_html = @import("./render_html.zig");
const RenderContext = render_html.RenderContext;
const Indexer = @import("./indexer.zig").Indexer;
const log = @import("./utils.zig").log;

const TOPAZ_VERSION = "0.0.1";
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

    var stdout_buf: [128]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&stdout_buf);
    const stdout = &stdout_writer.interface;

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
        } else if (mem.startsWith(u8, arg, "--help")) {
            const help =
                \\topaz {s}
                \\
                \\  --out=<outdir>              Directory to output rendered HTML
                \\  --template=<template.html>  HTML Template to use
                \\  --help                      Print this help message
                \\
            ;
            try stdout.print(help, .{TOPAZ_VERSION});
            try stdout.flush();
            return;
        }
    }

    // Initialize db
    {
        var dirname: [1024]u8 = undefined;
        const cur_dir = try std.fs.cwd().realpath(".", &dirname);
        const db_name = try std.fmt.allocPrintSentinel(allocator, "{s}.db", .{std.fs.path.basename(cur_dir)}, 0);

        var indexer = try Indexer.init(db_name);

        defer indexer.deinit();
    }

    var input_files = std.ArrayList([]const u8).empty;

    const stat = try std.fs.cwd().statFile(config.input_path);

    // Collect all .md files from dirs
    if (stat.kind == .directory) {
        var dir = try std.fs.cwd().openDir(config.input_path, .{ .iterate = true });
        defer dir.close();
        var walker = try dir.walk(allocator);

        while (try walker.next()) |entry| {
            var lower: [1024]u8 = undefined;
            const normalized_basename = std.ascii.lowerString(&lower, entry.basename);

            if (entry.kind == .file and mem.eql(u8, std.fs.path.extension(normalized_basename), ".md") and !mem.eql(u8, normalized_basename, "readme.md")) {
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
        if (config.template_file) |template| {
            try ctx.setTemplate(template);
        } else {
            try ctx.setTemplate("");
        }
        ctx.cur_page = page_name;
        try contexts.append(allocator, ctx);
    }

    // Second pass: parse markdown and index blocks/links
    for (page_graph.page_list.items, 0..) |*page, i| {
        if (page.meta.skip) continue;
        parser.parse(page.markdown, &contexts.items[i]);
    }

    // Third pass: write to disk
    for (page_graph.page_list.items, 0..) |*page, i| {
        if (page.meta.skip) continue;
        log.debug("Writing {s}", .{page.out_path});
        var ctx = &contexts.items[i];
        try ctx.writeHtmlHead(page.meta.title);
        try ctx.writeContents(page.meta.title);

        const dir_path = if (std.fs.path.dirname(page.out_path)) |dir|
            try std.fs.path.join(allocator, &[_][]const u8{ config.output_path, dir })
        else
            config.output_path;

        const out_path = try std.fs.path.join(allocator, &[_][]const u8{ config.output_path, page.out_path });
        try std.fs.cwd().makePath(dir_path);
        const dest_file = try std.fs.cwd().createFile(out_path, .{});
        defer dest_file.close();
        var file_buf: [1024]u8 = undefined;
        var file_writer = dest_file.writer(&file_buf);
        const writer = &file_writer.interface;
        try writer.writeAll(try ctx.serialize());
        try writer.flush();
    }
}

test {
    testing.refAllDecls(@This());
}
