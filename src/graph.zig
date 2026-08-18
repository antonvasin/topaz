const std = @import("std");
const mem = std.mem;
const Io = std.Io;
const Yaml = @import("yaml").Yaml;
const log = std.log.scoped(.graph);

/// Page contents with meta information.
/// Responsible for all page-related memory.
pub const Page = struct {
    arena: std.heap.ArenaAllocator,
    name: []const u8,
    path: []const u8,
    out_path: []const u8,
    meta: Meta,

    buf: []const u8,
    markdown: []const u8,
    frontmatter: ?[]const u8 = null,

    pub const Meta = struct {
        title: []const u8,
        url: ?[]const u8,
        size: u64,
        created_at: []const u8,
        updated_at: []const u8,
        skip: bool = false,
    };

    pub const Link = struct {
        link: []const u8,
        text: []const u8,
    };

    pub const HeaderLevel = enum(u3) {
        h1 = 1,
        h2 = 2,
        h3 = 3,
        h4 = 4,
        h5 = 5,
        h6 = 6,

        pub fn fromInt(level: u8) HeaderLevel {
            return switch (level) {
                1 => .h1,
                2 => .h2,
                3 => .h3,
                4 => .h4,
                5 => .h5,
                6 => .h6,
                else => .h6,
            };
        }

        pub fn toInt(self: HeaderLevel) u8 {
            return @intFromEnum(self);
        }
    };

    pub const Header = struct {
        text: []const u8,
        id: []const u8,
        level: HeaderLevel,
    };

    pub fn init(allocator: mem.Allocator, file_path: []const u8, buf: []const u8, stat: Io.File.Stat) !Page {
        var arena = std.heap.ArenaAllocator.init(allocator);
        const page_allocator = arena.allocator();

        // input_folder  /note-01           .md
        // input_folder  /subfolder/note-02 .md
        //
        // [input_dir]   /      [name]      .md
        // [outdir]      /      [name]      .html
        const name = file_path[0 .. file_path.len - 3];
        const out_path = try std.fmt.allocPrint(page_allocator, "{s}.html", .{name});

        var yaml_end: usize = 0;

        // Cutting out YAML frontmatter
        if (mem.startsWith(u8, buf, "---\n")) {
            var i: usize = 4;
            while (i < buf.len - 3) {
                if (mem.eql(u8, buf[i .. i + 4], "\n---")) {
                    if (i + 4 >= buf.len or buf[i + 4] == '\n') {
                        yaml_end = i + 4;
                        break;
                    }
                }
                i += 1;
            }
        }

        const frontmatter = if (yaml_end > 0) buf[0..yaml_end] else null;

        const created_at = try page_allocator.alloc(u8, 32);
        const updated_at = try page_allocator.alloc(u8, 32);

        var meta = Page.Meta{
            .title = try page_allocator.dupe(u8, name),
            .skip = false,
            .url = name,
            .size = stat.size,
            .created_at = formatTimestamp(created_at, stat.ctime.toSeconds()),
            .updated_at = formatTimestamp(updated_at, stat.mtime.toSeconds()),
        };

        if (frontmatter) |yml| {
            // Process Frontmatter. We want to support at least Obsidian and GitHub style metadata.
            //
            // Obsidian
            //
            // https://help.obsidian.md/properties#Default+properties
            // https://help.obsidian.md/publish/seo#Metadata
            // https://help.obsidian.md/publish/permalinks
            //
            // Property            Type                  Description
            // ─────────────────────────────────────────────────────
            // tags                List of strings       List of tags
            // aliases             List of strings       List of aliases
            // cssclasses          List of strings       Allows you to style individual notes using CSS snippets.
            // publish             Boolean               See Automatically select notes to publish.
            // permalink           List of strings       See Permalinks.
            // description         List of strings       See Description.
            // image               List of strings       See Image.
            // cover               List of strings       See Image.
            //
            // GitHub Pages
            //
            // https://docs.github.com/en/contributing/writing-for-github-docs/using-yaml-frontmatter
            //
            // Property            Type         Description
            // ────────────────────────────────────────────
            // versions
            // redirect_from
            // title
            // shortTitle
            // intro
            // permissions
            // product
            // layout
            // children
            // childGroups
            // featuredLinks
            // showMiniToc
            // allowTitleToDifferFromFilename
            // changelog
            // defaultPlatform
            // defaultTool
            // learningTracks
            // includeGuides
            // type
            // topics
            // communityRedirect
            // effectiveDate

            var yaml_parser: Yaml = .{ .source = yml };
            // Pages are not following any fixed schema so we won't try to parse them
            // into a struct. Instead we attempt to parse fields important to us one by one.
            // TODO: come up with the solution for wrongly formatted frontematter e.g. unquoted /, {{ }}
            if (yaml_parser.load(page_allocator)) {
                const map = yaml_parser.docs.items[0].map;
                if (map.contains("title")) {
                    page_allocator.free(meta.title);
                    meta.title = try page_allocator.dupe(u8, map.get("title").?.scalar);
                }
                if (map.contains("draft")) meta.skip = mem.eql(u8, map.get("draft").?.scalar, "true");
                if (map.contains("publish")) meta.skip = !mem.eql(u8, map.get("publish").?.scalar, "true");
            } else |err| switch (err) {
                error.ParseFailure => log.err("Frontmatter parsing failed for {s}: {s}", .{ name, yaml_parser.parse_errors.getCompileLogOutput() }),
                else => return err,
            }

            defer yaml_parser.deinit(page_allocator);
        }

        return .{
            .name = name,
            .path = file_path,
            .out_path = out_path,
            .buf = buf,
            .markdown = buf[yaml_end..],
            .frontmatter = frontmatter,
            .meta = meta,
            .arena = arena,
        };
    }

    pub fn deinit(self: *Page) void {
        self.arena.deinit();
    }
};

const LinkValues = std.StringHashMap(Page.Link);
const Links = std.StringHashMap(LinkValues);

///  Stores relationships between Pages
pub const PageGraph = struct {
    allocator: mem.Allocator,
    page_list: std.ArrayList(Page),
    /// page_name -> page_list[i]
    pages: std.StringHashMap(usize),
    ///  What links page have
    forward: Links,
    //  Who links to that page
    backward: Links,

    // We store list headers inside hash map which maps page to a list of header ids
    header_lists: std.StringHashMap(std.ArrayList([]const u8)),
    // Page headers by id
    headers: std.StringHashMap(Page.Header),

    pub fn init(allocator: mem.Allocator) !PageGraph {
        const page_list = std.ArrayList(Page).empty;
        const pages = std.StringHashMap(usize).init(allocator);
        const forward = Links.init(allocator);
        const backward = Links.init(allocator);
        const headers_lists = std.StringHashMap(std.ArrayList([]const u8)).init(allocator);
        const headers = std.StringHashMap(Page.Header).init(allocator);

        return .{
            .allocator = allocator,
            .page_list = page_list,
            .pages = pages,
            .forward = forward,
            .backward = backward,
            .header_lists = headers_lists,
            .headers = headers,
        };
    }

    pub fn deinit(self: *PageGraph) void {
        self.page_list.deinit(self.allocator);
        self.pages.deinit();
        self.forward.deinit();
        self.backward.deinit();
        self.header_lists.deinit();
        self.headers.deinit();
    }

    pub fn addPage(self: *PageGraph, page: Page) !void {
        try self.page_list.append(self.allocator, page);
        const index = self.page_list.items.len - 1;
        try self.pages.put(page.name, index);

        if (!self.forward.contains(page.name)) {
            try self.forward.put(page.name, std.StringHashMap(Page.Link).init(self.allocator));
        }
        if (!self.backward.contains(page.name)) {
            try self.backward.put(page.name, std.StringHashMap(Page.Link).init(self.allocator));
        }
    }

    pub fn addLink(self: *PageGraph, page_name: []const u8, link: Page.Link) !void {
        // TODO: we probably want to use real hashing function here
        const id = try std.fmt.allocPrint(self.allocator, "{s}{s}{any}", .{ page_name, link.link, link.text });

        var forward_links_ptr = self.forward.getPtr(page_name) orelse return error.LinksNotFound;
        try forward_links_ptr.put(id, link);

        var backward_links_ptr = try self.backward.getOrPut(link.link);
        if (!backward_links_ptr.found_existing) {
            backward_links_ptr.value_ptr.* = std.StringHashMap(Page.Link).init(self.allocator);
        }
        const backward_link = Page.Link{
            .link = page_name,
            .text = page_name,
        };
        try backward_links_ptr.value_ptr.put(id, backward_link);
    }

    /// For debug
    pub fn listPages(self: *PageGraph) void {
        var iterator = self.pages.keyIterator();

        var i: usize = 0;
        while (iterator.next()) |k| {
            log.debug("{d} {s}", .{ i, k.* });
            i += 1;
        }
    }

    pub fn addHeader(self: *PageGraph, page_name: []const u8, header: Page.Header) !void {
        log.debug("[{s}] Adding header h{d} #{s} \"{s}\"", .{ page_name, header.level.toInt(), header.id, header.text });

        try self.headers.put(header.id, header);

        const headers_list = try self.header_lists.getOrPut(page_name);
        if (!headers_list.found_existing) {
            headers_list.value_ptr.* = std.ArrayList([]const u8).empty;
        }
        try headers_list.value_ptr.append(self.allocator, header.id);
    }
};

test "Page" {
    const testing = std.testing;
    const allocator = testing.allocator;

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
        var page = try Page.init(allocator, "note.md", buf, .{
            .ctime = .{ .nanoseconds = 1 },
            .mtime = .{ .nanoseconds = 2 },
            .atime = .{ .nanoseconds = 3 },
            .size = 4,
            .kind = .file,
            .inode = 5,
            .nlink = 1,
            .permissions = @enumFromInt(0),
            .block_size = 4096,
        });
        defer page.deinit();
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

        var page = try Page.init(allocator, "note.md", buf, .{
            .ctime = .{ .nanoseconds = 1 },
            .mtime = .{ .nanoseconds = 2 },
            .atime = .{ .nanoseconds = 3 },
            .size = 4,
            .kind = .file,
            .inode = 5,
            .nlink = 1,
            .permissions = @enumFromInt(0),
            .block_size = 4096,
        });
        defer page.deinit();
        try testing.expectEqual(page.meta.skip, true);
    }
}

/// Format a Unix timestamp as an ISO-8601 UTC string
/// (`YYYY-MM-DDTHH:MM:SSZ`) into `buf`, which must be at least 20 bytes.
/// Out-of-range input is clamped so this can't crash on a garbage cache line.
/// Taken from https://github.com/ghostty-org/ghostty/blob/5a1edfb25402f06bc11568de3fcbf4bcc4b898be/src/cli/ssh_cache.zig#L344
fn formatTimestamp(buf: []u8, timestamp: i64) []const u8 {
    // Clamp to [epoch, last second of 9999-12-31Z]: `std.time.epoch`
    // accumulates the year in a `u16` (panics beyond that), and the buffer
    // only fits a 4-digit year.
    const secs: u64 = @intCast(std.math.clamp(timestamp, 0, 253402300799));

    const epoch = std.time.epoch;
    const epoch_secs: epoch.EpochSeconds = .{ .secs = secs };
    const day = epoch_secs.getEpochDay();
    const year_day = day.calculateYearDay();
    const month_day = year_day.calculateMonthDay();
    const ds = epoch_secs.getDaySeconds();
    return std.fmt.bufPrint(buf, "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}Z", .{
        year_day.year,
        month_day.month.numeric(),
        month_day.day_index + 1,
        ds.getHoursIntoDay(),
        ds.getMinutesIntoHour(),
        ds.getSecondsIntoMinute(),
    }) catch unreachable;
}
