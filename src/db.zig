const std = @import("std");
const log = std.log.scoped(.sqlite);
const testing = std.testing;

const c = @cImport({
    @cInclude("sqlite3.h");
});

pub const DB = struct {
    pub const Statement = struct {
        db: *c.sqlite3,
        stmt: *c.sqlite3_stmt,

        /// Bind value to a statement, wraps various sqlite_bind_* functions.
        /// For .blob, .blob64, .text, .text16, and .text64 the caller is
        /// responsible for managing value lifetime.
        /// https://www.sqlite.org/c3ref/bind_blob.html
        pub fn bind(self: *Statement, index: usize, value: DB.BindValue) !void {
            const idx: c_int = @intCast(index);
            const res: c_int = switch (value) {
                // int sqlite3_bind_blob(sqlite3_stmt*, int, const void*, int n, void(*)(void*));
                .blob => |v| c.sqlite3_bind_blob(self.stmt, idx, v.ptr, @intCast(v.len), c.SQLITE_STATIC),
                // int sqlite3_bind_blob64(sqlite3_stmt*, int, const void*, sqlite3_uint64, void(*)(void*));
                .blob64 => |v| c.sqlite3_bind_blob64(self.stmt, idx, v.ptr, @intCast(v.len), c.SQLITE_STATIC),
                // int sqlite3_bind_double(sqlite3_stmt*, int, double);
                .double => |v| c.sqlite3_bind_double(self.stmt, idx, v),
                // int sqlite3_bind_int(sqlite3_stmt*, int, int);
                .int => |v| c.sqlite3_bind_int(self.stmt, idx, v),
                // int sqlite3_bind_int64(sqlite3_stmt*, int, sqlite3_int64);
                .int64 => |v| c.sqlite3_bind_int64(self.stmt, idx, v),
                // int sqlite3_bind_null(sqlite3_stmt*, int);
                .null => c.sqlite3_bind_null(self.stmt, idx),
                // int sqlite3_bind_text(sqlite3_stmt*,int,const char*,int,void(*)(void*));
                .text => |v| c.sqlite3_bind_text(self.stmt, idx, v.ptr, @intCast(v.len), c.SQLITE_STATIC),
                // int sqlite3_bind_text16(sqlite3_stmt*, int, const void*, int, void(*)(void*));
                .text16 => |v| c.sqlite3_bind_text16(self.stmt, idx, v.ptr, @intCast(v.len), c.SQLITE_STATIC),
                // int sqlite3_bind_text64(sqlite3_stmt*, int, const char*, sqlite3_uint64, void(*)(void*), unsigned char encoding);
                .text64 => |v| c.sqlite3_bind_text64(self.stmt, idx, v.text.ptr, @intCast(v.text.len), c.SQLITE_STATIC, v.encoding),
                // int sqlite3_bind_value(sqlite3_stmt*, int, const sqlite3_value*);
                .value => |v| c.sqlite3_bind_value(self.stmt, idx, v),
                // int sqlite3_bind_pointer(sqlite3_stmt*, int, void*, const char*, void(*)(void*));
                .pointer => |v| c.sqlite3_bind_pointer(self.stmt, idx, v.ptr, v.type_name.ptr, v.destructor),
                // int sqlite3_bind_zeroblob(sqlite3_stmt*, int, int n);
                .zeroblob => |v| c.sqlite3_bind_zeroblob(self.stmt, idx, v),
                // int sqlite3_bind_zeroblob64(sqlite3_stmt*, int, sqlite3_uint64);
                .zeroblob64 => |v| c.sqlite3_bind_zeroblob64(self.stmt, idx, v),
            };

            if (res != c.SQLITE_OK) {
                log.err("{} on bind: {s}", .{ res, DB.errorMessage(self.db) orelse "null" });
                return error.Bind;
            }
        }

        // https://www.sqlite.org/c3ref/bind_parameter_index.html
        pub fn paramIndex(self: *const Statement, name: [:0]const u8) !c_int {
            const rv = c.sqlite3_bind_parameter_index(self.stmt, name.ptr);
            if (rv == 0) {
                log.err("No parameter found: {s}", .{name});
                return error.Bind;
            }
            return @intCast(rv);
        }

        pub const StepResult = enum { RowAvailable, Done };

        // https://www.sqlite.org/c3ref/step.html
        pub fn step(self: *const Statement) !StepResult {
            const res = c.sqlite3_step(self.stmt);
            return res: switch (res) {
                c.SQLITE_ROW => StepResult.RowAvailable,
                c.SQLITE_DONE => StepResult.Done,
                else => {
                    log.err("{} on step: {s}", .{ res, DB.errorMessage(self.db) orelse "null" });
                    break :res error.Step;
                },
            };
        }

        // https://www.sqlite.org/c3ref/finalize.html
        pub fn finalize(self: *const Statement) void {
            const res = c.sqlite3_finalize(self.stmt);
            if (res != c.SQLITE_OK) {
                log.err("Error finalizing statement {}: {s}", .{ res, DB.errorMessage(self.db) });
                return error.Finalize;
            }
        }
    };

    db: *c.sqlite3,

    pub const BindType = enum {
        blob,
        blob64,
        double,
        int,
        int64,
        null,
        text,
        text16,
        text64,
        value,
        pointer,
        zeroblob,
        zeroblob64,
    };

    pub const BindValue = union(BindType) {
        blob: []const u8,
        blob64: []const u8,
        double: f64,
        int: c_int,
        int64: c.sqlite3_int64,
        null: void,
        text: []const u8,
        /// Raw UTF-16 bytes.
        text16: []const u8,
        text64: struct { text: []const u8, encoding: u8 = c.SQLITE_UTF8 },
        value: *const c.sqlite3_value,
        pointer: struct {
            ptr: ?*anyopaque,
            type_name: [:0]const u8,
            destructor: c.sqlite3_destructor_type = null,
        },
        zeroblob: c_int,
        zeroblob64: c.sqlite3_uint64,
    };

    // https://www.sqlite.org/c3ref/open.html
    // https://www.sqlite.org/c3ref/close.html
    pub fn open(path: [:0]const u8) !DB {
        var db: ?*c.sqlite3 = null;
        errdefer _ = c.sqlite3_close(db);
        const res = c.sqlite3_open_v2(path, &db, c.SQLITE_OPEN_READWRITE | c.SQLITE_OPEN_CREATE, null);
        if (res != c.SQLITE_OK) {
            log.err("{} on open: {s}", .{ res, errorMessage(db) orelse "null" });
            return error.Connection;
        }

        return .{ .db = db.? };
    }

    pub fn close(self: *DB) void {
        _ = c.sqlite3_close(self.db);
        self.db = undefined;
    }

    pub const ExecCallback = *const fn (
        ctx: ?*anyopaque,
        num_results: c_int,
        cols: [*c][*c]c_char,
        rows: [*c][*c]c_char,
    ) callconv(.c) c_int;

    /// Execute query on the DB with optional callback
    /// https://www.sqlite.org/c3ref/exec.html
    pub fn exec(self: *DB, query: []const u8, cb: ?ExecCallback, ctx: ?*anyopaque) !void {
        var errmsg: [*c]u8 = null;
        const rc = c.sqlite3_exec(self.db, query.ptr, cb, ctx, &errmsg);
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

    // https://sqlite.org/c3ref/prepare.html
    pub fn prepare(self: *DB, sql: [:0]const u8) !Statement {
        var stmt: ?*c.sqlite3_stmt = null;
        const res = c.sqlite3_prepare_v2(self.db, sql.ptr, -1, &stmt, null);
        if (res != c.SQLITE_OK) {
            log.err("sqlite prepare failed: {s}", .{errorMessage(self.db) orelse "null"});
            return error.Statement;
        }

        return .{ .db = self.db, .stmt = stmt.? };
    }
};

test "bind" {
    var db = try DB.open(":memory:");
    defer db.close();

    var stmt = try db.prepare(
        "SELECT ?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13",
    );
    defer _ = c.sqlite3_finalize(stmt.stmt);

    // XXX: `value` needs a live sqlite3_value*, taken from another stepped statement.
    const src = try db.prepare("SELECT 99");
    defer _ = c.sqlite3_finalize(src.stmt);
    try testing.expectEqual(c.SQLITE_ROW, c.sqlite3_step(src.stmt));
    const some_value: *const c.sqlite3_value = c.sqlite3_column_value(src.stmt, 0).?;

    const utf16 = std.unicode.utf8ToUtf16LeStringLiteral("wide");
    var sentinel: u32 = 7;

    try stmt.bind(1, .{ .blob = "blob" });
    try stmt.bind(2, .{ .blob64 = "blob64" });
    try stmt.bind(3, .{ .double = 3.14 });
    try stmt.bind(4, .{ .int = 42 });
    try stmt.bind(5, .{ .int64 = 9_000_000_000 });
    try stmt.bind(6, .{ .null = {} });
    try stmt.bind(7, .{ .text = "hello" });
    try stmt.bind(8, .{ .text16 = std.mem.sliceAsBytes(utf16) });
    try stmt.bind(9, .{ .text64 = .{ .text = "world" } });
    try stmt.bind(10, .{ .value = some_value });
    try stmt.bind(11, .{ .pointer = .{ .ptr = &sentinel, .type_name = "topaz-test" } });
    try stmt.bind(12, .{ .zeroblob = 4 });
    try stmt.bind(13, .{ .zeroblob64 = 8 });

    try testing.expectEqual(c.SQLITE_ROW, c.sqlite3_step(stmt.stmt));
    try testing.expectEqual(@as(f64, 3.14), c.sqlite3_column_double(stmt.stmt, 2));
    try testing.expectEqual(@as(c_int, 42), c.sqlite3_column_int(stmt.stmt, 3));
    try testing.expectEqual(@as(i64, 9_000_000_000), c.sqlite3_column_int64(stmt.stmt, 4));
    try testing.expectEqual(c.SQLITE_NULL, c.sqlite3_column_type(stmt.stmt, 5));
    const text: [*:0]const u8 = @ptrCast(c.sqlite3_column_text(stmt.stmt, 6));
    try testing.expectEqualStrings("hello", std.mem.span(text));
    try testing.expectEqual(@as(c_int, 99), c.sqlite3_column_int(stmt.stmt, 9));
    try testing.expectEqual(@as(c_int, 4), c.sqlite3_column_bytes(stmt.stmt, 11)); // zeroblob length
}

test "paramIndex" {
    var db = try DB.open(":memory:");
    defer db.close();

    const stmt = try db.prepare("SELECT :foo, :bar");
    defer _ = c.sqlite3_finalize(stmt.stmt);

    try testing.expectEqual(@as(c_int, 1), try stmt.paramIndex(":foo"));
    try testing.expectEqual(@as(c_int, 2), try stmt.paramIndex(":bar"));
    // try testing.expectError(error.Bind, stmt.paramIndex(":missing"));
}

test "step" {
    // TODO: test step() and finalize()
}
