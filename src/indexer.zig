const DB = @import("./db.zig").DB;
const std = @import("std");
const log = std.log.scoped(.indexer);
const Page = @import("./graph.zig").Page;

pub const Indexer = struct {
    db: DB,

    pub fn init(db_name: [:0]const u8) !Indexer {
        log.debug("Using DB file \"{s}\"\n", .{db_name});
        var db = try DB.open(db_name);

        // documents
        // ---------
        // path             TEXT canonical document name
        // content          TEXT text content
        // created_at       TEXT ISO-8601
        // updated_at       TEXT ISO-8601
        try db.exec(
            \\CREATE TABLE IF NOT EXISTS documents(id INTEGER PRIMARY KEY,
            \\    path TEXT UNIQUE NOT NULL,
            \\    content TEXT,
            \\    created_at TEXT NOT NULL,
            \\    updated_at TEXT NOT NULL);
            \\
            \\CREATE UNIQUE INDEX IF NOT EXISTS idx_documents_path ON documents(path);
        , null, null);

        // documents_fts
        // -------------
        // title            documents.path
        // content          documents.content
        try db.exec(
            \\CREATE VIRTUAL TABLE IF NOT EXISTS documents_fts
            \\USING fts5(title,
            \\    content,
            \\    content = "documents",
            \\    content_rowid = "id",
            \\    tokenize = "porter unicode61");
            \\
            \\CREATE TRIGGER IF NOT EXISTS documents_fts_insert AFTER
            \\INSERT ON documents
            \\BEGIN
            \\  INSERT INTO documents_fts (rowid, title, content)
            \\  VALUES (new.id, new.path, new.content);
            \\END;
            \\
            \\CREATE TRIGGER IF NOT EXISTS documents_fts_update AFTER
            \\UPDATE ON documents
            \\BEGIN
            \\  INSERT INTO documents_fts (rowid, title, content)
            \\  VALUES (new.id, new.path, new.content);
            \\END;
            \\
            \\CREATE TRIGGER IF NOT EXISTS documents_fts_delet AFTER
            \\DELETE ON documents
            \\BEGIN
            \\  DELETE FROM documents_fts WHERE rowid = old.id;
            \\END;
        , null, null);

        return .{ .db = db };
    }

    pub fn ingestDocument(self: *Indexer, page: *const Page) !void {
        var stmt = try self.db.prepare(
            \\INSERT OR REPLACE INTO documents (path, content, created_at, updated_at)
            \\VALUES (:path, :content, :created_at, :updated_at);
        );
        try stmt.bind(try stmt.paramIndex(":path"), .{ .text = page.path });
        try stmt.bind(try stmt.paramIndex(":content"), .{ .text = page.buf });
        try stmt.bind(try stmt.paramIndex(":created_at"), .{ .text = page.meta.created_at });
        try stmt.bind(try stmt.paramIndex(":updated_at"), .{ .text = page.meta.updated_at });

        _ = try stmt.step();
        try stmt.finalize();
    }

    pub fn deinit(self: *Indexer) void {
        self.db.close();
    }
};
