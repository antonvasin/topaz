const std = @import("std");
const log = std.log.scoped(.sqlite);
// const testing = std.testing;

const c = @cImport({
    @cInclude("sqlite3.h");
});

pub const DB = struct {
    db: *c.sqlite3,

    // https://www.sqlite.org/c3ref/open.html
    // https://www.sqlite.org/c3ref/close.html
    pub fn open(path: [:0]const u8) !DB {
        var db: ?*c.sqlite3 = null;
        errdefer _ = c.sqlite3_close(db);
        const res = c.sqlite3_open(path, &db);
        if (res != c.SQLITE_OK) {
            log.err(
                "{} on open: {s}",
                .{ res, errorMessage(db) orelse "null" },
            );
            return error.Connection;
        }

        return .{ .db = db.? };
    }

    pub fn close(self: *DB) void {
        _ = c.sqlite3_close(self.db);
        self.db = undefined;
    }

    // https://www.sqlite.org/c3ref/exec.html
    pub fn exec(self: *DB, query: []const u8) !void {
        var errmsg: [*c]u8 = null;
        const rc = c.sqlite3_exec(self.handle, query.ptr, null, null, &errmsg);
        if (rc != c.SQLITE_OK) {
            if (errmsg != null) {
                log.err("sqlite exec failed: {s}", .{errmsg});
                c.sqlite3_free(errmsg);
            }
            return error.Statement;
        }
    }

    // https://sqlite.org/c3ref/errcode.html

    fn errorMessage(db: ?*c.sqlite3) ?[:0]const u8 {
        const maybe_msg = c.sqlite3_errmsg(db);
        if (maybe_msg) |msg| {
            // System retains ownership of memory
            return std.mem.span(msg);
        }
        return null;
    }
};
