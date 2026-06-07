const std = @import("std");
const mem = std.mem;
const assert = std.debug.assert;
const testing = std.testing;
const builtin = @import("builtin");

const DB = @import("./db.zig").DB;
const graph = @import("./graph.zig");
const PageGraph = graph.PageGraph;
const Page = graph.Page;
const indexer = @import("./indexer.zig");
const md = @import("./md.zig");
const Parser = md.Parser;
const parse_html = @import("./parse_html.zig");
const RenderContext = @import("./render_html.zig").RenderContext;

const log = std.log.scoped(.cli);

const TOPAZ_VERSION = "0.0.2";
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

const RenderArgs = struct {
    /// Input source, defaults to current directory.
    input_path: []const u8 = ".",
    /// Output directory, defaults to 'topaz-out'.
    output_path: []const u8 = "topaz-out",
    /// HTML template path to use, if any.
    template: ?[]const u8 = null,
};

const QueryArgs = struct {
    query: []const u8 = "",
};

const Command = union(enum) {
    render: RenderArgs,
    query: QueryArgs,
};

const Cli = struct {
    /// Global --debug flag, accepted anywhere on the command line.
    debug: bool = false,
    command: Command,
};

const usage =
    \\topaz {s}
    \\
    \\Usage: topaz [--debug] <command> [args]
    \\
    \\Commands:
    \\  render [input]              Render markdown to HTML
    \\    --out=<outdir>            Directory to output rendered HTML (default: topaz-out)
    \\    --template=<template>     HTML template to use
    \\
    \\  query [query]               Full-text search the index
    \\
    \\Global:
    \\  --debug                     Enable debug logging
    \\  --help                      Print this help message
    \\
;

/// Parse argv into a `Cli`. Returns null when there is nothing to run
/// (after printing help for --help, a missing/unknown command, or a bad flag).
///
/// TODO: drive this from comptime type and remove hard-coded arguments
fn parseArgs(allocator: mem.Allocator, args: []const [:0]u8, stdout: *std.Io.Writer) !?Cli {
    var cli = Cli{ .command = undefined };
    var have_command = false;

    for (args[1..]) |arg| {
        if (mem.eql(u8, arg, "--debug")) {
            cli.debug = true;
            debug_enabled = true;
            continue;
        }
        if (mem.eql(u8, arg, "--help")) {
            try stdout.print(usage, .{TOPAZ_VERSION});
            try stdout.flush();
            return null;
        }

        if (!have_command) {
            if (mem.eql(u8, arg, "render")) {
                cli.command = .{ .render = .{} };
            } else if (mem.eql(u8, arg, "query")) {
                cli.command = .{ .query = .{} };
            } else {
                log.err("Unknown command \"{s}\"\n", .{arg});
                try stdout.print(usage, .{TOPAZ_VERSION});
                try stdout.flush();
                return null;
            }
            have_command = true;
            continue;
        }

        switch (cli.command) {
            .render => |*r| {
                if (mem.startsWith(u8, arg, "--out=")) {
                    r.output_path = try allocator.dupe(u8, arg[6..]);
                    log.info("Out dir is \"{s}\"\n", .{r.output_path});
                } else if (mem.startsWith(u8, arg, "--template=")) {
                    r.template = try allocator.dupe(u8, arg[11..]);
                    log.info("Using template {s}", .{r.template.?});
                } else if (!mem.startsWith(u8, arg, "--")) {
                    r.input_path = try allocator.dupe(u8, arg);
                } else {
                    log.err("Unknown flag for render: \"{s}\"\n", .{arg});
                    try stdout.print(usage, .{TOPAZ_VERSION});
                    try stdout.flush();
                    return null;
                }
            },
            .query => |*q| {
                if (!mem.startsWith(u8, arg, "--")) {
                    q.query = try allocator.dupe(u8, arg);
                    log.info("Processing query {s}", .{q.query});
                } else {
                    log.err("Unknown flag for query: \"{s}\"\n", .{arg});
                    try stdout.print(usage, .{TOPAZ_VERSION});
                    try stdout.flush();
                    return null;
                }
            },
        }
    }

    if (!have_command) {
        try stdout.print(usage, .{TOPAZ_VERSION});
        try stdout.flush();
        return null;
    }

    return cli;
}

/// Read file from disk, parse metadata and add to graph
fn processFile(allocator: mem.Allocator, file_path: []const u8, page_graph: *PageGraph, input_path: []const u8, db: *DB) !void {
    const full_path = try std.fs.path.join(allocator, &[_][]const u8{ input_path, file_path });
    defer allocator.free(full_path);
    const file = std.fs.cwd().openFile(full_path, .{}) catch |err| {
        log.err("Failed to read {s}, skipping\n", .{full_path});
        return err;
    };
    defer file.close();

    const stat = try file.stat();
    log.info("Processing {s} ({d}b)\n", .{ file_path, stat.size });
    const buf = try allocator.alloc(u8, stat.size);
    errdefer allocator.free(buf);
    _ = try std.fs.cwd().readFile(full_path, buf);

    const page = try Page.init(allocator, file_path, buf, stat);
    try page_graph.addPage(page);

    try indexer.ingestDocument(db, &page);
}
fn runQuery(db: *DB, q: QueryArgs) !void {
    var stmt = try indexer.query(db, q.query);

    std.debug.print("Query results:\n", .{});
    var count: u64 = 1;
    while (try stmt.step() == .RowAvailable) : (count += 1) {
        const path = stmt.column(0, .text).text;
        std.debug.print("  {d}: {s}\n", .{ count, path });
    }

    try stmt.finalize();
}

fn runRender(allocator: mem.Allocator, db: *DB, r: RenderArgs) !void {
    var input_files = std.ArrayList([]const u8).empty;

    const stat = try std.fs.cwd().statFile(r.input_path);

    // Collect all .md files from dirs
    if (stat.kind == .directory) {
        var dir = try std.fs.cwd().openDir(r.input_path, .{ .iterate = true });
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
    } else if (stat.kind == .file and mem.eql(u8, std.fs.path.extension(r.input_path), ".md")) {
        // Collect individual input files
        try input_files.append(allocator, r.input_path);
    }

    var parser = try Parser.init();

    // Create output directory
    const dest_dir = std.fs.path.resolve(allocator, &[_][]const u8{r.output_path}) catch |err| {
        std.log.err("Failed to resolve dest path: {any}\n", .{err});
        return err;
    };
    try std.fs.cwd().makePath(dest_dir);

    // Process files
    var page_graph = try PageGraph.init(allocator);
    var contexts = std.ArrayList(RenderContext).empty;

    const template_file: ?[]const u8 = if (r.template) |template|
        try std.fs.cwd().readFileAlloc(allocator, template, std.math.maxInt(usize))
    else
        null;

    // First pass: read files into memory and parse metadata
    for (input_files.items) |path| {
        try processFile(allocator, path, &page_graph, r.input_path, db);
        const page_name = path[0 .. path.len - 3];
        var ctx = try RenderContext.init(allocator, &page_graph);
        if (template_file) |template| {
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
            try std.fs.path.join(allocator, &[_][]const u8{ r.output_path, dir })
        else
            r.output_path;

        const out_path = try std.fs.path.join(allocator, &[_][]const u8{ r.output_path, page.out_path });
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

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const allocator = arena.allocator();
    defer arena.deinit();

    var stdout_buf: [128]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&stdout_buf);
    const stdout = &stdout_writer.interface;

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    const cli = (try parseArgs(allocator, args, stdout)) orelse return;

    // Initialize db
    var dirname: [1024]u8 = undefined;
    const cur_dir = try std.fs.cwd().realpath(".", &dirname);
    const db_name = try std.fmt.allocPrintSentinel(allocator, "{s}.db", .{std.fs.path.basename(cur_dir)}, 0);

    var db = try indexer.init(db_name);
    defer db.close();

    switch (cli.command) {
        .query => |q| try runQuery(&db, q),
        .render => |r| try runRender(allocator, &db, r),
    }
}

test {
    testing.refAllDecls(@This());
}
