const std = @import("std");
const mem = std.mem;
const Io = std.Io;
const assert = std.debug.assert;
const testing = std.testing;
const log = std.log.scoped(.cli);
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
const Server = @import("./server.zig");

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

const GlobalArgs = struct {
    debug: bool = false,
    help: bool = false,
};

const RenderArgs = struct {
    /// Input source
    input: []const u8 = ".",
    /// Output directory
    output_path: []const u8 = "topaz-out",
    /// HTML template path to use
    template: ?[]const u8 = null,
    /// SQLite DB file to use
    db: ?[:0]const u8 = null,
};

const QueryArgs = struct {
    query: []const u8 = "",
    /// SQLite DB file to use
    db: ?[:0]const u8 = null,
};

const IndexArgs = struct {
    /// Input source
    input: []const u8 = ".",
    /// SQLite DB file to use
    db: ?[:0]const u8 = null,
};

const ServerArgs = struct {
    port: u16,
    /// Input source
    input: []const u8 = ".",
    /// Output directory
    output_path: []const u8 = "topaz-out",
    /// HTML template path to use
    template: ?[]const u8 = null,
    /// SQLite DB file to use
    db: ?[:0]const u8 = null,
};

const Cli = struct {
    args: GlobalArgs,
    command: union(enum) {
        render: RenderArgs,
        query: QueryArgs,
        index: IndexArgs,
        serve: ServerArgs,
    },
};

const usage =
    \\topaz {s}
    \\
    \\Usage: topaz [--debug] <command> [args]
    \\
    \\ Global args
    \\  --debug                       Enable debug logging
    \\  --help                        Print this help message
    \\
    \\Commands:
    \\  render [input]                Render markdown to HTML
    \\    --out=<outdir>              Directory to output rendered HTML (default: topaz-out)
    \\    --template=<template.html>  HTML template to use
    \\
    \\  index [input]                 Index documents
    \\    --db=<myindex.db>           SQLite DB file to use
    \\
    \\  query [query]                 Full-text search the index
    \\    --db=<myindex.db>           SQLite DB file to use
    \\
    \\  serve [input]                 Serve static files
    \\    --port=<10547>              Port for HTTP server to use
    \\    --out=<outdir>              Directory to output rendered HTML (default: topaz-out)
    \\    --template=<template.html>  HTML template to use
    \\    --db=<myindex.db>           SQLite DB file to use
    \\
;

fn collectInput(allocator: mem.Allocator, io: Io, input: []const u8) !std.ArrayList([]const u8) {
    var input_files = std.ArrayList([]const u8).empty;

    const cwd = Io.Dir.cwd();
    const stat = try cwd.statFile(io, input, .{});

    // Collect all .md files from dirs
    if (stat.kind == .directory) {
        var dir = try cwd.openDir(io, input, .{ .iterate = true });
        defer dir.close(io);
        var walker = try Io.Dir.walk(dir, allocator);

        while (try walker.next(io)) |entry| {
            var lower: [1024]u8 = undefined;
            const normalized_basename = std.ascii.lowerString(&lower, entry.basename);

            if (entry.kind == .file and mem.eql(u8, std.fs.path.extension(normalized_basename), ".md")) {
                const path = try allocator.dupe(u8, entry.path);
                try input_files.append(allocator, path);
            }
        }
    } else if (stat.kind == .file and mem.eql(u8, std.fs.path.extension(input), ".md")) {
        // Collect individual input files
        try input_files.append(allocator, input);
    }

    return input_files;
}

/// Read file from disk, parse metadata and add to graph
fn processFile(allocator: mem.Allocator, io: Io, file_path: []const u8, page_graph: ?*PageGraph, input_path: []const u8, db: *DB) !void {
    const full_path = try std.fs.path.join(allocator, &[_][]const u8{ input_path, file_path });
    defer allocator.free(full_path);
    const cwd = Io.Dir.cwd();
    const file = cwd.openFile(io, full_path, .{}) catch |err| {
        log.err("Failed to read {s}, skipping\n", .{full_path});
        return err;
    };
    defer file.close(io);

    const stat = try file.stat(io);
    log.info("Processing {s} ({d}b)\n", .{ file_path, stat.size });

    const buf = try allocator.alloc(u8, stat.size);
    errdefer allocator.free(buf);
    _ = try cwd.readFile(io, full_path, buf);

    const page = try Page.init(allocator, file_path, buf, stat);
    if (page_graph) |g| try g.addPage(page);

    try indexer.ingestDocument(db, &page, buf);
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

fn runIndex(allocator: mem.Allocator, io: Io, db: *DB, i: IndexArgs) !void {
    var input_files = try collectInput(allocator, io, i.input);
    defer input_files.deinit(allocator);
    var index = try indexer.getChecksums(allocator, db);
    defer index.deinit();

    for (input_files.items) |path| {
        const full_path = try std.fs.path.join(allocator, &[_][]const u8{ i.input, path });
        defer allocator.free(full_path);
        const cwd = Io.Dir.cwd();
        const file = cwd.openFile(io, full_path, .{ .mode = .read_only }) catch {
            log.err("Failed to read file {s}", .{path});
            continue;
        };
        defer file.close(io);
        const stat = try file.stat(io);

        if (index.get(path)) |entry| {
            if (entry.mtime == stat.mtime.toSeconds()) continue;
            std.debug.print("Reading file contents {s}\n", .{full_path});
            const buf = try allocator.alloc(u8, stat.size);
            errdefer allocator.free(buf);
            const content = try cwd.readFile(io, full_path, buf);
            const hash = indexer.contentHash(content);
            if (hash == entry.hash) continue;
        }

        try processFile(allocator, io, path, null, i.input, db);
    }
}

fn runRender(allocator: mem.Allocator, io: Io, db: *DB, r: RenderArgs) !void {
    var input_files = try collectInput(allocator, io, r.input);
    defer input_files.deinit(allocator);

    const cwd = Io.Dir.cwd();

    // First pass: read files into memory and parse metadata
    var page_graph = try PageGraph.init(allocator);
    var contexts = std.ArrayList(RenderContext).empty;

    const template_file: ?[]const u8 = if (r.template) |template|
        try cwd.readFileAlloc(io, template, allocator, .limited(std.math.maxInt(usize)))
    else
        null;

    for (input_files.items) |path| {
        try processFile(allocator, io, path, &page_graph, r.input, db);
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
    var parser = try Parser.init();

    for (page_graph.page_list.items, 0..) |*page, i| {
        if (page.meta.skip) continue;
        parser.parse(page.markdown, &contexts.items[i]);
    }

    // Third pass: write to disk
    const out_dir = try cwd.createDirPathOpen(io, r.output_path, .{});
    defer out_dir.close(io);

    for (page_graph.page_list.items, 0..) |*page, i| {
        if (page.meta.skip) continue;
        log.debug("Writing {s}", .{page.out_path});
        var ctx = &contexts.items[i];
        try ctx.writeHtmlHead(page.meta.title);
        try ctx.writeContents(page.meta.title);

        if (std.fs.path.dirname(page.out_path)) |dir| {
            try out_dir.createDirPath(io, dir);
        }

        const dest_file = try out_dir.createFile(io, page.out_path, .{});
        defer dest_file.close(io);
        var file_buf: [1024]u8 = undefined;
        var file_writer = dest_file.writer(io, &file_buf);
        const writer = &file_writer.interface;
        try writer.writeAll(try ctx.serialize());
        try writer.flush();
    }

    // Static files are resolved relative to the input directory, or to the
    // cwd for a single file input.
    const input = try cwd.statFile(io, r.input, .{});
    const input_dir = if (input.kind == .directory) try cwd.openDir(io, r.input, .{}) else cwd;
    defer if (input.kind == .directory) input_dir.close(io);

    var it = page_graph.static_paths.keyIterator();
    while (it.next()) |path| {
        const static_path = std.mem.trimStart(u8, path.*, "/");

        input_dir.copyFile(static_path, out_dir, static_path, io, .{ .make_path = true }) catch |err| switch (err) {
            error.FileNotFound => {
                var in_buf: [1024]u8 = undefined;
                const in = try input_dir.realPath(io, &in_buf);
                log.warn("Not found {s} in {s}", .{ static_path, in_buf[0..in] });
            },
            else => return err,
        };
    }
}

fn runServer(allocator: mem.Allocator, io: Io, db: *DB, s: ServerArgs) !void {
    try runRender(allocator, io, db, .{
        .input = s.input,
        .output_path = s.output_path,
        .template = s.template,
    });
    const dir = try Io.Dir.cwd().openDir(io, s.output_path, .{ .iterate = true });
    var server = Server.init(allocator, io, dir);
    try server.startServer(s.port);
}

/// Parse argv into a `Cli`. Returns null when there is nothing to run
/// (after printing help for --help, a missing/unknown command, or a bad flag).
/// TODO: implement proper args parser that uses comptime
fn parseArgs(allocator: mem.Allocator, args: []const [:0]const u8) !?Cli {
    var cli = Cli{ .command = undefined, .args = undefined };
    var have_command = false;

    for (args[1..]) |arg| {
        if (mem.eql(u8, arg, "--debug")) {
            cli.args.debug = true;
            debug_enabled = true;
            continue;
        }
        if (mem.eql(u8, arg, "--help")) {
            return null;
        }

        if (!have_command) {
            if (mem.eql(u8, arg, "render")) {
                cli.command = .{ .render = .{} };
            } else if (mem.eql(u8, arg, "query")) {
                cli.command = .{ .query = .{} };
            } else if (mem.eql(u8, arg, "index")) {
                cli.command = .{ .index = .{} };
            } else if (mem.eql(u8, arg, "serve")) {
                cli.command = .{ .serve = .{ .port = 10547 } };
            } else {
                log.err("Unknown command \"{s}\"\n", .{arg});
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
                } else if (mem.startsWith(u8, arg, "--db=")) {
                    // FIXME: dupeZ is deprecated
                    r.db = try allocator.dupeZ(u8, arg["--db=".len..]);
                } else if (!mem.startsWith(u8, arg, "--")) {
                    r.input = try allocator.dupe(u8, arg);
                } else {
                    log.err("Unknown flag for render: \"{s}\"\n", .{arg});
                    return null;
                }
            },
            .query => |*q| {
                if (!mem.startsWith(u8, arg, "--")) {
                    q.query = try allocator.dupe(u8, arg);
                    log.info("Processing query {s}", .{q.query});
                } else if (mem.startsWith(u8, arg, "--db=")) {
                    // FIXME: dupeZ is deprecated
                    q.db = try allocator.dupeZ(u8, arg["--db=".len..]);
                } else {
                    log.err("Unknown flag for query: \"{s}\"\n", .{arg});
                    return null;
                }
            },
            .index => |*i| {
                if (!mem.startsWith(u8, arg, "--")) {
                    i.input = try allocator.dupe(u8, arg);
                } else if (mem.startsWith(u8, arg, "--db=")) {
                    // FIXME: dupeZ is deprecated
                    i.db = try allocator.dupeZ(u8, arg["--db=".len..]);
                } else {
                    log.err("Unknown flag for query: \"{s}\"\n", .{arg});
                    return null;
                }
            },
            .serve => |*s| {
                if (mem.startsWith(u8, arg, "--port=")) {
                    const portArg = arg[7..];
                    s.port = std.fmt.parseInt(u16, portArg, 10) catch |err| {
                        std.process.fatal("Unable to parse port '{s}': {s}", .{ portArg, @errorName(err) });
                    };
                } else if (mem.startsWith(u8, arg, "--db=")) {
                    // FIXME: dupeZ is deprecated
                    s.db = try allocator.dupeZ(u8, arg["--db=".len..]);
                } else if (mem.startsWith(u8, arg, "--out=")) {
                    s.output_path = try allocator.dupe(u8, arg[6..]);
                    log.info("Out dir is \"{s}\"\n", .{s.output_path});
                } else if (!mem.startsWith(u8, arg, "--")) {
                    s.input = try allocator.dupe(u8, arg);
                } else {
                    log.err("Unknown flag for serve: \"{s}\"\n", .{arg});
                    return null;
                }
            },
        }
    }

    if (!have_command) {
        return null;
    }

    return cli;
}

pub fn main(init: std.process.Init) !void {
    const allocator = init.arena.allocator();
    const io = init.io;

    var stdout_buf: [128]u8 = undefined;
    var stdout_writer = Io.File.stdout().writer(io, &stdout_buf);
    const stdout = &stdout_writer.interface;

    const args = try init.minimal.args.toSlice(allocator);

    if (try parseArgs(allocator, args)) |cli| {
        const db_override = switch (cli.command) {
            .index => |*i| i.db,
            .render => |*r| r.db,
            .query => |*q| q.db,
            .serve => |*s| s.db,
        };
        // Uses --db arg or defaults to {dirname}.db
        const db_name = db_override orelse blk: {
            var dirname: [1024]u8 = undefined;
            const n = try std.process.currentPath(io, &dirname);
            break :blk try std.fmt.allocPrintSentinel(allocator, "{s}.db", .{std.fs.path.basename(dirname[0..n])}, 0);
        };

        var db = try indexer.init(db_name);
        defer db.close();

        switch (cli.command) {
            .index => |i| try runIndex(allocator, io, &db, i),
            .query => |q| try runQuery(&db, q),
            .render => |r| try runRender(allocator, io, &db, r),
            .serve => |s| try runServer(allocator, io, &db, s),
        }
    } else {
        try stdout.print(usage, .{TOPAZ_VERSION});
        try stdout.flush();
        std.process.exit(0);
    }
}

test {
    testing.refAllDecls(@This());
}
