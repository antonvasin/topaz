const sqlite = @import("./db.zig");
const DB = sqlite.DB;
const Statement = sqlite.Statement;
const std = @import("std");
const log = std.log.scoped(.indexer);
const Page = @import("./graph.zig").Page;

pub fn init(db_name: [:0]const u8) !DB {
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
        \\    content_hash INTEGER,
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

    return db;
}

fn contentHash(buf: []const u8) u32 {
    var hasher = std.hash.XxHash32.init(0);
    hasher.update(buf);
    return hasher.final();
}

pub fn ingestDocument(db: *DB, page: *const Page, buf: []const u8) !void {
    var stmt = try db.prepare(
        \\INSERT OR REPLACE INTO documents (path, content, content_hash, created_at, updated_at)
        \\VALUES (:path, :content, :content_hash, :created_at, :updated_at);
    );
    try stmt.bind(try stmt.paramIndex(":path"), .{ .text = page.path });
    try stmt.bind(try stmt.paramIndex(":content"), .{ .text = page.buf });
    try stmt.bind(try stmt.paramIndex(":content_hash"), .{ .int64 = @intCast(contentHash(buf)) });
    try stmt.bind(try stmt.paramIndex(":created_at"), .{ .text = page.meta.created_at });
    try stmt.bind(try stmt.paramIndex(":updated_at"), .{ .text = page.meta.updated_at });

    _ = try stmt.step();
    defer stmt.finalize() catch {};
}

/// Full-text search. Returns bound Statement that caller must step through
/// and/or finalize
pub fn query(db: *DB, search: []const u8) !Statement {
    var stmt = try db.prepare("SELECT m.path from documents as m JOIN documents_fts AS f ON m.id = f.rowid WHERE f.documents_fts MATCH :query");
    try stmt.bind(1, .{ .text = search });

    return stmt;
}

pub fn checkModified(db: *DB, path: []const u8, stat: std.fs.File.Stat, buf: []const u8) !bool {
    // TODO: use subsec
    var stmt = try db.prepare("SELECT path, unixepoch(updated_at), content_hash FROM documents WHERE path = :path");
    try stmt.bind(1, .{ .text = path });
    const res = try stmt.step();
    if (res == .Done) return true;

    const mtime = stmt.column(1, .int).int;
    const known_hash = stmt.column(2, .int64).int64;

    defer stmt.finalize() catch {};

    return if (stat.mtime > mtime) contentHash(buf) != known_hash else false;
}
