const Server = @This();

const std = @import("std");
const Io = std.Io;
const log = std.log.scoped(.server);
const mime = @import("mime");

root_dir: []const u8,
allocator: std.mem.Allocator,
io: Io,

pub fn init(allocator: std.mem.Allocator, io: Io, root_dir: []const u8) Server {
    return .{
        .allocator = allocator,
        .io = io,
        .root_dir = root_dir,
    };
}

pub fn startServer(self: *Server, port: u16) !void {
    log.info("Starting server on http://{s}:{d}", .{ "127.0.0.1", port });

    const addr = std.Io.net.IpAddress{ .ip4 = .loopback(port) };
    var server = try addr.listen(self.io, .{ .reuse_address = true });
    defer server.deinit(self.io);

    var group: Io.Group = .init;
    defer group.cancel(self.io);

    while (true) {
        const stream = try server.accept(self.io);
        group.async(self.io, handleStream, .{ self, stream });
    }

    try group.await(self.io);
}

pub fn handleStream(self: *Server, stream: Io.net.Stream) std.Io.Cancelable!void {
    defer stream.close(self.io);

    var read_buf: [4096]u8 = undefined;
    var write_buf: [4096]u8 = undefined;
    var reader = stream.reader(self.io, &read_buf);
    var writer = stream.writer(self.io, &write_buf);

    var http_server = std.http.Server.init(&reader.interface, &writer.interface);

    while (true) {
        var req = http_server.receiveHead() catch |err| switch (err) {
            error.HttpConnectionClosing => break,
            else => {
                log.err("Error: {s}", .{@errorName(err)});
                break;
            },
        };
        self.handleRequest(&req) catch return std.Io.Cancelable.Canceled;
    }
}

fn handleRequest(self: *Server, req: *std.http.Server.Request) !void {
    var status: std.http.Status = .ok;
    var res_body: []const u8 = "";
    var headers: ?[]std.http.Header = null;
    var response: ?Response = null;
    defer if (response) |*r| r.deinit(self.allocator);

    const target = req.head.target;
    const path, const query = if (std.mem.indexOfScalar(u8, target, '?')) |q| .{ target[0..q], target[q..] } else .{ target, "" };

    const sanitized = try self.sanitizePath(path);
    defer if (sanitized) |s| self.allocator.free(s);

    if (sanitized) |sanitized_path| {
        const full_path = try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ self.root_dir, sanitized_path });
        defer self.allocator.free(full_path);

        switch (req.head.method) {
            .GET => {
                if (std.mem.eql(u8, sanitized_path, "/foo")) {
                    status = .ok;
                    res_body = "Foo";
                } else {
                    response = try self.serveFile(full_path);
                    status = response.?.status;
                    res_body = response.?.body orelse std.http.Status.phrase(status) orelse "";
                    if (response.?.headers) |h| headers = h;
                }
            },
            else => {
                status = .not_found;
                res_body = std.http.Status.phrase(status) orelse "";
            },
        }
    } else {
        status = .bad_request;
        res_body = std.http.Status.phrase(status) orelse "";
    }

    var opts: std.http.Server.Request.RespondOptions = .{
        .status = status,
    };

    if (headers) |h| opts.extra_headers = h;

    req.respond(res_body, opts) catch |err| {
        log.err("Failed to respond: {s}", .{@errorName(err)});
    };
    // NOTE: for debug only
    log.info("{s} {s}{s} {d}", .{ std.enums.tagName(std.http.Method, req.head.method) orelse "", sanitized orelse "", query, status });
}

const MaxFileSize = 10 * 1024;

const Response = struct {
    status: std.http.Status,
    headers: ?[]std.http.Header = null,
    body: ?[]const u8 = null,

    fn deinit(self: *Response, gpa: std.mem.Allocator) void {
        if (self.headers) |h| gpa.free(h);
        if (self.body) |b| gpa.free(b);
    }
};

fn serveFile(self: *Server, path: []const u8) !Response {
    const normalized_path = if (std.mem.endsWith(u8, path, ".html")) try self.allocator.dupe(u8, path) else try std.fmt.allocPrint(self.allocator, "{s}.html", .{path});
    defer self.allocator.free(normalized_path);

    const file_buf = Io.Dir.cwd().readFileAlloc(self.io, normalized_path, self.allocator, Io.Limit.limited(10 * 1024)) catch |err| {
        switch (err) {
            error.FileNotFound => return .{ .status = .not_found },
            error.AccessDenied => return .{ .status = .forbidden },
            else => return .{ .status = .internal_server_error },
        }
    };

    const extension = normalized_path[std.mem.lastIndexOfScalar(u8, normalized_path, '.') orelse normalized_path.len - 1 ..];
    const mime_type = mime.extension_map.get(extension) orelse mime.Type.@"text/plain";

    var headers: std.ArrayList(std.http.Header) = .empty;
    try headers.append(self.allocator, .{ .name = "Content-Type", .value = std.enums.tagName(mime.Type, mime_type) orelse unreachable });

    return .{
        .status = .ok,
        .headers = try headers.toOwnedSlice(self.allocator),
        .body = file_buf,
    };
}

/// Sanitize request path, `null` means invalid request. Caller must free returned string
fn sanitizePath(self: *Server, url_path: []const u8) !?[]const u8 {
    var is_empty = false;
    const target = if (url_path.len > 0 and url_path[0] == '/') url_path[1..] else url_path;
    if (target.len == 0) is_empty = true; // serve index
    var iter = std.mem.splitScalar(u8, target, '/');
    var parts: std.ArrayList([]const u8) = .empty;
    defer parts.deinit(self.allocator);
    while (iter.next()) |part| {
        if (part.len == 0) continue; // skip "//"
        if (std.mem.eql(u8, part, "..")) return null; // reject "foo/../../etc/passwd"
        if (std.mem.eql(u8, part, ".")) continue; // skip "foo/./bar"
        if (std.mem.eql(u8, part, "..")) return null; // reject "foo/../../etc/passwd"
        if (std.mem.startsWith(u8, part, ".")) return null; // reject "foo/.hidden"
        if (std.mem.endsWith(u8, part, "~")) return null; // reject "foo/tmp~
        if (std.mem.indexOfScalar(u8, part, 0) != null) return null; // reject null bytes
        try parts.append(self.allocator, part);
    }
    if (parts.items.len == 0) is_empty = true; // serve index
    return if (is_empty) try std.fmt.allocPrint(self.allocator, "index.html", .{}) else try std.mem.join(self.allocator, "/", parts.items);
}

// fn formatHttpDate(timestamp: Io.Timestamp, buf: []u8) ?[]const u8 {
//
// }
