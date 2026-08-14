const std = @import("std");
const Io = std.Io;
const log = std.log.scoped(.server);

pub fn startServer(io: Io, port: u16) !void {
    log.info("Starting server on http://{s}:{d}", .{ "127.0.0.1", port });

    const addr = std.Io.net.IpAddress{ .ip4 = .loopback(port) };
    var server = try addr.listen(io, .{ .reuse_address = true });
    defer server.deinit(io);

    var group: Io.Group = .init;
    defer group.cancel(io);

    while (true) {
        const stream = try server.accept(io);
        group.async(io, handleStream, .{ io, stream });
    }

    try group.await(io);
}

pub fn handleStream(io: Io, stream: Io.net.Stream) void {
    defer stream.close(io);

    var read_buf: [4096]u8 = undefined;
    var write_buf: [4096]u8 = undefined;
    var reader = stream.reader(io, &read_buf);
    var writer = stream.writer(io, &write_buf);

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

        // log.info("target: {s}", .{req.head.target});

        // req.respond("Hellow", .{ .status = .ok }) catch |err| {
        //     log.err("Failed to respond: {s}", .{@errorName(err)});
        // };
        try handleRequest(&req);
    }
}

fn handleRequest(req: *std.http.Server.Request) !void {
    var status: std.http.Status = .ok;
    var res_body: []const u8 = undefined;

    switch (req.head.method) {
        .GET => {
            if (std.mem.eql(u8, req.head.target, "/foo")) {
                res_body = "Foo";
            }
        },
        else => {
            status = .not_found;
            res_body = "Not found";
        },
    }

    req.respond(res_body, .{ .status = status }) catch |err| {
        log.err("Failed to respond: {s}", .{@errorName(err)});
    };
}

pub fn defaultIgnoreFile(path: []const u8) bool {
    const basename = std.Dir.path.basename(path);
    return std.mem.startsWith(u8, basename, ".") or
        std.mem.endsWith(u8, basename, "~");
}
