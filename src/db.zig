const std = @import("std");
const log = std.log.scoped(.sqlite);
const testing = std.testing;

const c = @cImport({
    @cInclude("sqlite3.h");
});

pub const ExecCallback = *const fn (
    ctx: ?*anyopaque,
    num_results: c_int,
    cols: [*c][*c]u8,
    rows: [*c][*c]u8,
) callconv(.c) c_int;

pub const DB = struct {
    db: *c.sqlite3,

    /// https://www.sqlite.org/c3ref/open.html
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

    /// https://www.sqlite.org/c3ref/close.html
    pub fn close(self: *DB) void {
        _ = c.sqlite3_close(self.db);
        self.db = undefined;
    }

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

    /// https://sqlite.org/c3ref/prepare.html
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

pub const Statement = struct {
    db: *c.sqlite3,
    stmt: *c.sqlite3_stmt,

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

    /// Bind value to a statement, wraps various sqlite_bind_* functions.
    /// For .blob, .blob64, .text, .text16, and .text64 the caller is
    /// responsible for managing value lifetime.
    /// https://www.sqlite.org/c3ref/bind_blob.html
    pub fn bind(self: *Statement, index: usize, value: BindValue) !void {
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
            log.err("{} on bind: {s}", .{ res, errorMessage(self.db) orelse "null" });
            return error.Bind;
        }
    }

    // https://www.sqlite.org/c3ref/bind_parameter_index.html
    pub fn paramIndex(self: *const Statement, name: [:0]const u8) !usize {
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
                log.err("{} on step: {s}", .{ res, errorMessage(self.db) orelse "null" });
                break :res error.Step;
            },
        };
    }

    pub const ColumnType = enum {
        blob,
        double,
        int,
        int64,
        text,
        text16,
        value,
    };

    pub const ColumnValue = union(ColumnType) {
        /// Owned by SQLite; valid until the next step/reset/finalize or a
        /// type conversion on the same column. Caller must copy to retain.
        blob: []const u8,
        double: f64,
        int: c_int,
        int64: c.sqlite3_int64,
        /// See `blob` note on lifetime. UTF-8 bytes, may contain embedded nulls.
        text: []const u8,
        /// See `blob` note on lifetime. Raw UTF-16 bytes.
        text16: []const u8,
        value: *c.sqlite3_value,
    };

    /// Read a column from the current row, wraps various sqlite3_column_*
    /// functions. For .blob, .text, and .text16 the returned slice is owned by
    /// SQLite and only valid until the next step/reset/finalize.
    /// https://www.sqlite.org/c3ref/column_blob.html
    pub fn column(self: *const Statement, index: usize, col_type: ColumnType) ColumnValue {
        const idx: c_int = @intCast(index);
        return switch (col_type) {
            // const void *sqlite3_column_blob(sqlite3_stmt*, int iCol);
            .blob => b: {
                // Per SQLite, call the data function before the size function.
                const ptr = c.sqlite3_column_blob(self.stmt, idx);
                const len: usize = @intCast(c.sqlite3_column_bytes(self.stmt, idx));
                const bytes: [*]const u8 = @ptrCast(ptr orelse break :b .{ .blob = &.{} });
                break :b .{ .blob = bytes[0..len] };
            },
            // double sqlite3_column_double(sqlite3_stmt*, int iCol);
            .double => .{ .double = c.sqlite3_column_double(self.stmt, idx) },
            // int sqlite3_column_int(sqlite3_stmt*, int iCol);
            .int => .{ .int = c.sqlite3_column_int(self.stmt, idx) },
            // sqlite3_int64 sqlite3_column_int64(sqlite3_stmt*, int iCol);
            .int64 => .{ .int64 = c.sqlite3_column_int64(self.stmt, idx) },
            // const unsigned char *sqlite3_column_text(sqlite3_stmt*, int iCol);
            .text => b: {
                const ptr = c.sqlite3_column_text(self.stmt, idx);
                const len: usize = @intCast(c.sqlite3_column_bytes(self.stmt, idx));
                const bytes: [*]const u8 = @ptrCast(ptr orelse break :b .{ .text = &.{} });
                break :b .{ .text = bytes[0..len] };
            },
            // const void *sqlite3_column_text16(sqlite3_stmt*, int iCol);
            .text16 => b: {
                const ptr = c.sqlite3_column_text16(self.stmt, idx);
                const len: usize = @intCast(c.sqlite3_column_bytes16(self.stmt, idx));
                const bytes: [*]const u8 = @ptrCast(ptr orelse break :b .{ .text16 = &.{} });
                break :b .{ .text16 = bytes[0..len] };
            },
            // sqlite3_value *sqlite3_column_value(sqlite3_stmt*, int iCol);
            .value => .{ .value = c.sqlite3_column_value(self.stmt, idx).? },
        };
    }

    /// https://www.sqlite.org/c3ref/finalize.html
    pub fn finalize(self: *const Statement) !void {
        const res = c.sqlite3_finalize(self.stmt);
        if (res != c.SQLITE_OK) {
            log.err("Error finalizing statement {}: {s}", .{ res, errorMessage(self.db) orelse "null" });
            return error.Finalize;
        }
    }
};

/// https://sqlite.org/c3ref/errcode.html
fn errorMessage(db: ?*c.sqlite3) ?[:0]const u8 {
    const maybe_msg = c.sqlite3_errmsg(db);
    if (maybe_msg) |msg| {
        // System retains ownership of memory
        return std.mem.span(msg);
    }
    return null;
}

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

    try testing.expectEqual(@as(usize, 1), try stmt.paramIndex(":foo"));
    try testing.expectEqual(@as(usize, 2), try stmt.paramIndex(":bar"));
    // try testing.expectError(error.Bind, stmt.paramIndex(":missing"));
}

test "step" {
    var db = try DB.open(":memory:");
    defer db.close();

    try db.exec("CREATE TABLE t (n INTEGER)", null, null);
    try db.exec("INSERT INTO t (n) VALUES (10), (20)", null, null);

    const stmt = try db.prepare("SELECT n FROM t ORDER BY n");
    defer _ = c.sqlite3_finalize(stmt.stmt);

    // First row.
    try testing.expectEqual(Statement.StepResult.RowAvailable, try stmt.step());
    try testing.expectEqual(@as(c_int, 10), c.sqlite3_column_int(stmt.stmt, 0));
    // Second row.
    try testing.expectEqual(Statement.StepResult.RowAvailable, try stmt.step());
    try testing.expectEqual(@as(c_int, 20), c.sqlite3_column_int(stmt.stmt, 0));
    // No more rows.
    try testing.expectEqual(Statement.StepResult.Done, try stmt.step());
}

test "finalize" {
    var db = try DB.open(":memory:");
    defer db.close();

    const stmt = try db.prepare("SELECT 1");
    try testing.expectEqual(Statement.StepResult.RowAvailable, try stmt.step());
    try stmt.finalize();
}

test "column" {
    var db = try DB.open(":memory:");
    defer db.close();

    const utf16 = std.unicode.utf8ToUtf16LeStringLiteral("wide");

    var stmt = try db.prepare(
        "SELECT ?1, ?2, ?3, ?4, ?5, ?6",
    );
    defer _ = c.sqlite3_finalize(stmt.stmt);

    try stmt.bind(1, .{ .blob = "blob" });
    try stmt.bind(2, .{ .double = 3.14 });
    try stmt.bind(3, .{ .int = 42 });
    try stmt.bind(4, .{ .int64 = 9_000_000_000 });
    try stmt.bind(5, .{ .text = "hello" });
    try stmt.bind(6, .{ .text16 = std.mem.sliceAsBytes(utf16) });

    try testing.expectEqual(Statement.StepResult.RowAvailable, try stmt.step());

    try testing.expectEqualStrings("blob", stmt.column(0, .blob).blob);
    try testing.expectEqual(@as(f64, 3.14), stmt.column(1, .double).double);
    try testing.expectEqual(@as(c_int, 42), stmt.column(2, .int).int);
    try testing.expectEqual(@as(i64, 9_000_000_000), stmt.column(3, .int64).int64);
    try testing.expectEqualStrings("hello", stmt.column(4, .text).text);
    try testing.expectEqualSlices(u8, std.mem.sliceAsBytes(utf16), stmt.column(5, .text16).text16);

    // .value returns a live sqlite3_value*, usable with the raw API.
    const v = stmt.column(2, .value).value;
    try testing.expectEqual(@as(c_int, 42), c.sqlite3_value_int(v));
}
