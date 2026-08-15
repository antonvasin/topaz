const Server = @This();

const std = @import("std");
const Io = std.Io;
const log = std.log.scoped(.server);

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
            error.HttpConnectionClosing => continue,
            else => {
                log.err("Error: {s}", .{@errorName(err)});
                break;
            },
        };
        // var it = req.iterateHeaders();
        // while (it.next()) |header| {
        //     log.info("header: {s}: {s}", .{ header.name, header.value });
        // }

        // req.respond("Hellow", .{ .status = .ok }) catch |err| {
        //     log.err("Failed to respond: {s}", .{@errorName(err)});
        // };
        self.handleRequest(&req) catch return std.Io.Cancelable.Canceled;
    }
}

fn handleRequest(self: *Server, req: *std.http.Server.Request) !void {
    var status: std.http.Status = .ok;
    var res_body: []const u8 = "";

    const target = req.head.target;
    const path, const query = if (std.mem.indexOfScalar(u8, target, '?')) |q| .{ target[0..q], target[q..] } else .{ target, "" };

    const sanitized = try self.sanitizePath(path);
    defer if (sanitized) |s| self.allocator.free(s);

    if (sanitized) |sanitized_path| {
        switch (req.head.method) {
            .GET => {
                if (std.mem.eql(u8, sanitized_path, "/foo")) {
                    status = .ok;
                    res_body = "Foo";
                } else {
                    status = .not_found;
                    res_body = std.http.Status.phrase(status) orelse "";
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

    req.respond(res_body, .{ .status = status }) catch |err| {
        log.err("Failed to respond: {s}", .{@errorName(err)});
    };
    // NOTE: for debug only
    log.info("{s} {s}{s} {d}", .{ std.enums.tagName(std.http.Method, req.head.method) orelse "", sanitized orelse "", query, status });
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
