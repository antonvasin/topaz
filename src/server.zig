const Server = @This();

const std = @import("std");
const Io = std.Io;
const testing = std.testing;
const log = std.log.scoped(.server);
const mime = @import("mime");

pub const Headers = enum {
    @"Content-Type",
    @"Cache-Control",
    @"If-None-Match",
    @"If-Modified-Since",
    @"Last-Modified",
    Expires,
    ETag,
};

root_dir: Io.Dir, // must be opened with .iterate = true
allocator: std.mem.Allocator,
io: Io,
/// Present when server is listening on a port
server: ?Io.net.Server,

pub fn init(allocator: std.mem.Allocator, io: Io, root_dir: Io.Dir) Server {
    return .{
        .allocator = allocator,
        .io = io,
        .root_dir = root_dir,
        .server = null,
    };
}

pub fn startServer(self: *Server, port: u16) !void {
    log.info("Starting server on http://{s}:{d}", .{ "127.0.0.1", port });

    const addr = std.Io.net.IpAddress{ .ip4 = .loopback(port) };
    var server = try addr.listen(self.io, .{ .reuse_address = true });
    self.server = server;
    defer server.deinit(self.io);

    var group: Io.Group = .init;
    defer group.cancel(self.io);

    while (true) {
        const stream = server.accept(self.io) catch |err| switch (err) {
            error.Canceled => break,
            else => return err,
        };
        group.async(self.io, handleStream, .{ self, stream });
    }
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
            error.ReadFailed => {
                if (reader.err) |read_err| {
                    if (read_err == error.Canceled) return error.Canceled;
                    log.err("Error: {s}", .{@errorName(read_err)});
                }
                break;
            },
            else => {
                log.err("Error: {s}", .{@errorName(err)});
                break;
            },
        };
        self.handleRequest(&req) catch |err| switch (err) {
            error.Canceled => return error.Canceled,
            error.WriteFailed => {
                if (writer.err) |write_err| {
                    if (write_err == error.Canceled) return error.Canceled;
                    log.err("Failed to respond: {s}", .{@errorName(write_err)});
                }
                break;
            },
            else => {
                log.err("Failed to handle request: {s}", .{@errorName(err)});
                break;
            },
        };
    }
}

fn handleRequest(self: *Server, req: *std.http.Server.Request) !void {
    var arena = std.heap.ArenaAllocator.init(self.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var status: std.http.Status = .ok;
    var res_body: []const u8 = "";
    var headers: std.ArrayList(std.http.Header) = .empty;

    const target = req.head.target;
    const path, const query = if (std.mem.indexOfScalar(u8, target, '?')) |q| .{ target[0..q], target[q..] } else .{ target, "" };

    // TODO: url un-escape
    const unescaped = try unescapeUrl(allocator, path);
    const sanitized = try sanitizePath(allocator, unescaped);

    if (sanitized) |sanitized_path| {
        switch (req.head.method) {
            .GET => {
                if (std.mem.eql(u8, sanitized_path, "/foo")) {
                    status = .ok;
                    res_body = "Foo";
                } else {
                    const response = try self.serveFile(allocator, req, sanitized_path);
                    status = response.status;
                    res_body = if (status == .not_modified) "" else response.body orelse std.http.Status.phrase(status) orelse "";
                    if (response.headers) |h| try headers.appendSlice(allocator, h);
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

    const date_str = try toRfc1123Date(allocator, Io.Timestamp.now(self.io, .real));
    if (date_str) |d| try headers.append(allocator, .{ .name = "Date", .value = d });

    const opts: std.http.Server.Request.RespondOptions = .{
        .status = status,
        .extra_headers = headers.items,
    };

    try req.respond(res_body, opts);
    log.debug("{s} {s}{s} {d}", .{ std.enums.tagName(std.http.Method, req.head.method) orelse "", sanitized orelse "", query, status });
}

const Response = struct {
    status: std.http.Status,
    headers: ?[]std.http.Header = null,
    body: ?[]const u8 = null,
};

/// Produces Response for static file request. Caller must free returned Response
fn serveFile(self: *Server, allocator: std.mem.Allocator, req: *std.http.Server.Request, path: []const u8) !Response {
    var headers: std.ArrayList(std.http.Header) = .empty;

    var extension = if (std.mem.lastIndexOfScalar(u8, path, '.')) |ext_i| path[ext_i..] else null;
    const normalized_path = if (extension) |_| try allocator.dupe(u8, path) else try std.fmt.allocPrint(allocator, "{s}.html", .{path});
    if (extension == null) extension = ".html";

    const mime_type = if (extension) |ext| mime.extension_map.get(ext) orelse mime.Type.@"text/plain" else mime.Type.@"text/plain";
    const mime_str = std.enums.tagName(mime.Type, mime_type) orelse unreachable;
    try headers.append(allocator, .{ .name = @tagName(Headers.@"Content-Type"), .value = mime_str });

    try headers.append(allocator, .{ .name = @tagName(Headers.@"Cache-Control"), .value = "public, max-age=0, must-revalidate" });

    const stat = self.root_dir.statFile(self.io, normalized_path, .{}) catch |err| return switch (err) {
        error.FileNotFound => .{ .status = .not_found },
        error.AccessDenied => .{ .status = .forbidden },
        error.Canceled => return error.Canceled,
        else => |e| {
            log.err("Internal error: {s}", .{@errorName(e)});
            return .{ .status = .internal_server_error };
        },
    };
    // TODO: replace with proper hash
    const etag_str = try std.fmt.allocPrint(allocator, "\"{d}-{d}\"", .{ stat.mtime.toNanoseconds(), stat.size });
    var not_modified = false;
    // RFC 7232: If-None-Match takes precedence over If-Modified-Since
    var it = req.iterateHeaders();
    while (it.next()) |header| {
        if (std.ascii.eqlIgnoreCase(header.name, @tagName(Headers.@"If-None-Match"))) {
            not_modified = std.mem.eql(u8, header.value, etag_str);
        } else if (std.ascii.eqlIgnoreCase(header.name, @tagName(Headers.@"If-Modified-Since"))) {
            if (fromRfc1123Date(header.value)) |ims_ts| {
                not_modified = ims_ts.toSeconds() >= stat.mtime.toSeconds();
            }
        }
    }

    const mtime_str = try toRfc1123Date(allocator, stat.mtime);

    if (mtime_str) |m| {
        try headers.append(allocator, .{ .name = @tagName(Headers.@"Last-Modified"), .value = m });
        try headers.append(allocator, .{ .name = @tagName(Headers.Expires), .value = m });
    }

    try headers.append(allocator, .{ .name = @tagName(Headers.ETag), .value = etag_str });

    if (not_modified) {
        return .{
            .status = .not_modified,
            .headers = try headers.toOwnedSlice(allocator),
        };
    } else {
        const file = self.root_dir.openFile(self.io, normalized_path, .{}) catch |err| return switch (err) {
            error.FileNotFound => .{ .status = .not_found },
            error.AccessDenied => .{ .status = .forbidden },
            error.Canceled => return error.Canceled,
            else => |e| {
                log.err("Internal error: {s}", .{@errorName(e)});
                return .{ .status = .internal_server_error };
            },
        };

        defer file.close(self.io);

        // var file_buf: [1024]u8 = undefined;
        var file_buf = try allocator.alloc(u8, 2048);
        var fr = file.reader(self.io, file_buf);
        const reader = fr.interface;

        // TODO: replace with File.Reader and avoid the limit
        // const file_buf = self.root_dir.readFileAlloc(self.io, normalized_path, allocator, Io.Limit.limited(1024 * 1024)) catch |err| return switch (err) {
        //     error.FileNotFound => .{ .status = .not_found },
        //     error.AccessDenied => .{ .status = .forbidden },
        //     error.Canceled => return error.Canceled,
        //     else => |e| {
        //         log.err("Internal error: {s}", .{@errorName(e)});
        //         return .{ .status = .internal_server_error };
        //     },
        // };

        return .{
            .status = .ok,
            .headers = try headers.toOwnedSlice(allocator),
            .body = file_buf,
        };
    }
}

/// Sanitize request path, `null` means invalid request. Caller must free returned string.
fn sanitizePath(gpa: std.mem.Allocator, url_path: []const u8) !?[]const u8 {
    var is_empty = false;
    const target = if (url_path.len > 0 and url_path[0] == '/') url_path[1..] else url_path;
    if (target.len == 0) is_empty = true; // serve index
    var iter = std.mem.splitScalar(u8, target, '/');
    var parts: std.ArrayList([]const u8) = .empty;
    defer parts.deinit(gpa);
    while (iter.next()) |part| {
        if (part.len == 0) continue; // skip "//"
        if (std.mem.eql(u8, part, "..")) return null; // reject "foo/../../etc/passwd"
        if (std.mem.eql(u8, part, ".")) continue; // skip "foo/./bar"
        if (std.mem.startsWith(u8, part, ".")) return null; // reject "foo/.hidden"
        if (std.mem.endsWith(u8, part, "~")) return null; // reject "foo/tmp~
        if (std.mem.indexOfScalar(u8, part, 0) != null) return null; // reject null bytes
        try parts.append(gpa, part);
    }
    if (parts.items.len == 0) is_empty = true; // serve index
    return if (is_empty) try std.fmt.allocPrint(gpa, "index.html", .{}) else try std.mem.join(gpa, "/", parts.items);
}

// Caller frees the memory
pub fn unescapeUrl(gpa: std.mem.Allocator, input: []const u8) ![]const u8 {
    var url: std.ArrayList(u8) = .empty;

    var i: usize = 0;
    while (i < input.len) {
        if (input[i] == '%' and i + 2 < input.len) {
            const bytes = input[i + 1 .. i + 3];
            const byte_val = std.fmt.parseInt(u8, bytes, 16) catch { // FIXME: error handling as logic
                try url.append(gpa, '%');
                i += 1;
                continue;
            };
            try url.append(gpa, byte_val);
            i += 3;
        } else {
            try url.append(gpa, input[i]);
            i += 1;
        }
    }
    return url.toOwnedSlice(gpa);
}

test "static server" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{
        .sub_path = "index.html",
        .data = "<!doctype html>",
    });

    var server = Server.init(gpa, io, tmp.dir);
    const addr = std.Io.net.IpAddress{ .ip4 = .loopback(0) };
    var listener = try addr.listen(io, .{ .reuse_address = true });
    defer listener.deinit(io);

    const AcceptAndHandle = struct {
        fn run(s: *Server, l: *std.Io.net.Server) void {
            const stream = l.accept(s.io) catch return;
            s.handleStream(stream) catch {};
        }
    };
    const server_thread = try std.Thread.spawn(.{}, AcceptAndHandle.run, .{ &server, &listener });
    defer server_thread.join();

    var client: std.http.Client = .{ .allocator = gpa, .io = io };
    defer client.deinit();

    {
        var req = try client.request(.GET, .{
            .scheme = "http",
            .host = .{ .percent_encoded = "127.0.0.1" },
            .port = listener.socket.address.ip4.port,
            .path = .{ .percent_encoded = "/" },
        }, .{});
        defer req.deinit();
        try req.sendBodiless();
        var head_buf: [2048]u8 = undefined;
        var response = try req.receiveHead(&head_buf);
        try testing.expectEqualStrings("text/html", response.head.content_type.?);
        var response_buf: [1000]u8 = undefined;
        const reader = response.reader(&response_buf);
        var body_buf: [1000]u8 = undefined;
        const has_read = try reader.readSliceShort(&body_buf);
        const body = body_buf[0..has_read];
        try std.testing.expectEqualStrings("<!doctype html>", body);
    }
}

const day_names = [_][]const u8{ "Thu", "Fri", "Sat", "Sun", "Mon", "Tue", "Wed" };

const month_names = [_][]const u8{ "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec" };

// Converts timestamp to RFC 1123 date (Sun, 21 Oct 2018 12:16:24 GMT). Caller must free the result
fn toRfc1123Date(gpa: std.mem.Allocator, timestamp: Io.Timestamp) !?[]const u8 {
    const epoch = std.time.epoch.EpochSeconds{ .secs = @intCast(timestamp.toSeconds()) };
    const day_info = epoch.getDaySeconds();
    const year_day = epoch.getEpochDay().calculateYearDay();
    const month_day = year_day.calculateMonthDay();
    const day_of_week = epoch.getEpochDay().day % 7;

    return std.fmt.allocPrint(gpa, "{s}, {d:0>2} {s} {d} {d:0>2}:{d:0>2}:{d:0>2} GMT", .{
        day_names[@intCast(day_of_week)],
        month_day.day_index + 1,
        month_names[@intCast(@intFromEnum(month_day.month) - 1)],
        year_day.year,
        day_info.getHoursIntoDay(),
        day_info.getMinutesIntoHour(),
        day_info.getSecondsIntoMinute(),
    }) catch return null;
}

test toRfc1123Date {
    const date_str = try toRfc1123Date(testing.allocator, Io.Timestamp.fromNanoseconds(std.time.ns_per_s + std.time.ns_per_day));
    try testing.expect(date_str != null);
    try testing.expectEqualStrings("Fri, 02 Jan 1970 00:00:01 GMT", date_str.?);
    defer std.testing.allocator.free(date_str.?);
}

fn fromRfc1123Date(timestamp: []const u8) ?Io.Timestamp {
    if (!std.mem.endsWith(u8, timestamp, " GMT")) return null;

    var parts: struct {
        day: []const u8,
        date: u5,
        month: u4,
        year: u16,
        h: u6,
        m: u6,
        s: u6,
    } = undefined;

    var cur: usize = 0;
    var part: usize = 0;

    //      Sun, 21 Oct 2018 12:16:24 GMT
    // cur  0->4                            day
    // cur      4->                         date
    //           5->7
    // cur         7->8                     month
    //              8->11
    // cur             11->12               year
    //                  12->16
    // cur                  16->17          time
    //                       17->25
    blk: while (cur < timestamp.len) {
        switch (part) {
            0 => {
                const weekday_idx = std.mem.findPos(u8, timestamp, 0, ", ") orelse return null;
                parts.day = timestamp[cur .. cur + weekday_idx];
                cur += weekday_idx + 1;
                part += 1;
            },
            1 => {
                if (cur + 1 >= timestamp.len) return null else cur += 1;
                const date_idx = std.mem.findScalar(u8, timestamp[cur..], ' ') orelse return null;
                parts.date = std.fmt.parseInt(u5, timestamp[cur .. cur + date_idx], 10) catch return null;
                cur += date_idx;
                part += 1;
            },
            2 => {
                if (cur + 1 >= timestamp.len) return null else cur += 1;
                const month_idx = std.mem.findScalar(u8, timestamp[cur..], ' ') orelse return null;
                parts.month = blk2: {
                    for (month_names, 0..) |name, i| {
                        if (std.mem.eql(u8, name, timestamp[cur .. cur + month_idx])) break :blk2 @intCast(i + 1);
                    }
                    return null;
                };
                cur += month_idx;
                part += 1;
            },
            3 => {
                if (cur + 1 >= timestamp.len) return null else cur += 1;
                const year_idx = std.mem.findScalar(u8, timestamp[cur..], ' ') orelse return null;
                parts.year = std.fmt.parseInt(u16, timestamp[cur .. cur + year_idx], 10) catch return null;
                cur += year_idx;
                part += 1;
            },
            4 => {
                if (cur + 1 >= timestamp.len) return null else cur += 1;
                const time_idx = std.mem.findScalar(u8, timestamp[cur..], ' ') orelse return null;
                const time = timestamp[cur .. cur + time_idx];

                var time_parts = std.mem.splitScalar(u8, time, ':');
                parts.h = std.fmt.parseInt(u6, time_parts.next() orelse return null, 10) catch return null;
                parts.m = std.fmt.parseInt(u6, time_parts.next() orelse return null, 10) catch return null;
                parts.s = std.fmt.parseInt(u6, time_parts.next() orelse return null, 10) catch return null;
                break :blk;
            },
            else => unreachable,
        }
    }

    if (parts.year < std.time.epoch.epoch_year or parts.date == 0) return null;

    var days: u64 = 0;
    for (std.time.epoch.epoch_year..parts.year) |year| days += std.time.epoch.getDaysInYear(@intCast(year));
    for (1..parts.month) |month| days += std.time.epoch.getDaysInMonth(parts.year, @enumFromInt(month));
    days += parts.date - 1;
    // zig fmt: off
    const secs = days * std.time.epoch.secs_per_day
        + @as(u32, parts.h) * std.time.s_per_hour
        + @as(u32, parts.m) * std.time.s_per_min
        + parts.s;
    // zig fmt: on
    return Io.Timestamp.fromNanoseconds(@as(i96, secs) * std.time.ns_per_s);
}

test fromRfc1123Date {
    const ts = fromRfc1123Date("Sun, 21 Oct 2018 12:16:24 GMT") orelse return error.TestUnexpectedResult;
    try testing.expectEqual(1540124184, ts.toSeconds());

    const all_days = fromRfc1123Date("Thu, 01 Jan 1970 00:00:00 GMT") orelse return error.TestUnexpectedResult;
    try testing.expectEqual(0, all_days.toSeconds());

    try testing.expect(fromRfc1123Date("Sun, 21 Oct 2018 12:16:24 PST") == null); // non-GMT -> rejected
    try testing.expect(fromRfc1123Date("Sun, 21 Oct 2018 12:16 GMT") == null); // missing seconds -> rejected
}
