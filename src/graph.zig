const std = @import("std");
const mem = std.mem;
const Yaml = @import("yaml").Yaml;
const log = @import("./utils.zig").log;

pub const Page = struct {
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
        date: ?[]const u8 = null,
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

    pub fn init(allocator: mem.Allocator, file_path: []const u8, buf: []const u8) !Page {
        // input_folder  /note-01           .md
        // input_folder  /subfolder/note-02 .md
        //
        // [input_dir]   /      [name]      .md
        // [outdir]      /      [name]      .html
        const name = file_path[0 .. file_path.len - 3];
        const out_path = try std.fmt.allocPrint(allocator, "{s}.html", .{name});

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

        var meta = Page.Meta{
            .title = try allocator.dupe(u8, name),
            .skip = false,
            .url = name,
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
            try yaml_parser.load(allocator);
            defer yaml_parser.deinit(allocator);
            const map = yaml_parser.docs.items[0].map;
            if (map.contains("title")) {
                allocator.free(meta.title);
                meta.title = try allocator.dupe(u8, map.get("title").?.scalar);
            }
            if (map.contains("draft")) meta.skip = mem.eql(u8, map.get("draft").?.scalar, "true");
            if (map.contains("publish")) meta.skip = !mem.eql(u8, map.get("publish").?.scalar, "true");
        }

        return .{
            .name = name,
            .path = file_path,
            .out_path = out_path,
            .buf = buf,
            .markdown = buf[yaml_end .. buf.len - 1],
            .frontmatter = frontmatter,
            .meta = meta,
        };
    }

    pub fn deinit(self: *Page, allocator: mem.Allocator) void {
        allocator.free(self.out_path);
        allocator.free(self.meta.title);
    }
};

///  Stores relationships between Pages
pub const PageGraph = struct {
    allocator: mem.Allocator,
    page_list: std.ArrayList(Page),
    pages: std.StringHashMap(usize),
    ///  What links page have
    forward: Links,
    //  Who links to that page
    backward: Links,

    // We store list headers inside hash map which maps page to a list of header ids
    headers_lists: std.StringHashMap(std.ArrayList([]const u8)),
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
            .headers_lists = headers_lists,
            .headers = headers,
        };
    }

    pub fn deinit(self: *PageGraph) void {
        self.page_list.deinit(self.allocator);
        self.pages.deinit();
        self.forward.deinit();
        self.backward.deinit();
        self.headers_lists.deinit();
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

        const headers_list = try self.headers_lists.getOrPut(page_name);
        if (!headers_list.found_existing) {
            headers_list.value_ptr.* = std.ArrayList([]const u8).empty;
        }
        try headers_list.value_ptr.append(self.allocator, header.id);
    }
};

const LinkValues = std.StringHashMap(Page.Link);
const Links = std.StringHashMap(LinkValues);
