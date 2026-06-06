const DB = @import("./db.zig").DB;
const std = @import("std");
const log = std.log.scoped(.indexer);

pub const Indexer = struct {
    db: DB,

    pub fn init(db_name: [:0]const u8) !Indexer {
        log.debug("Using DB file \"{s}\"\n", .{db_name});
        var db = try DB.open(db_name);

        // path             TEXT canonical document name
        // content          TEXT text content
        // created_at       TEXT ISO-8601
        // updated_at       TEXT ISO-8601
        try db.exec("CREATE TABLE IF NOT EXISTS documents(id INTEGER PRIMARY KEY, path TEXT UNIQUE NOT NULL, content TEXT, created_at TEXT NOT NULL, updated_at TEXT NOT NULL)", null, null);

        return .{ .db = db };
    }

    pub fn ingestDocument(self: *Indexer) !void {
        try self.db.exec("INSERT INTO documents (path, content, created_at, updated_at) VALUES (:path, :content, :created_at, :updated_at)");
    }

    pub fn deinit(self: *Indexer) void {
        self.db.close();
    }
};
