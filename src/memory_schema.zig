const std = @import("std");
const sqlite = @import("sqlite.zig");
const debug_log = @import("debug_log.zig");

const Db = sqlite.Db;

// ── Schema DDL ──────────────────────────────────────────────────────────

const pragmas =
    \\PRAGMA journal_mode=WAL;
    \\PRAGMA foreign_keys=ON;
;

const schema_version_ddl =
    \\CREATE TABLE IF NOT EXISTS schema_version (
    \\  version INTEGER NOT NULL
    \\);
;

const engrams_ddl =
    \\CREATE TABLE IF NOT EXISTS engrams (
    \\  id TEXT PRIMARY KEY,
    \\  brain_id TEXT NOT NULL,
    \\  term TEXT NOT NULL,
    \\  definition TEXT NOT NULL,
    \\  memory_term TEXT NOT NULL DEFAULT 'short',
    \\  weight REAL NOT NULL DEFAULT 1.0,
    \\  created_at TEXT NOT NULL DEFAULT (datetime('now')),
    \\  updated_at TEXT NOT NULL DEFAULT (datetime('now'))
    \\);
;

const synapses_ddl =
    \\CREATE TABLE IF NOT EXISTS synapses (
    \\  id TEXT PRIMARY KEY,
    \\  brain_id TEXT NOT NULL,
    \\  source_id TEXT NOT NULL REFERENCES engrams(id) ON DELETE CASCADE,
    \\  target_id TEXT NOT NULL REFERENCES engrams(id) ON DELETE CASCADE,
    \\  relation TEXT NOT NULL DEFAULT 'related_to',
    \\  weight REAL NOT NULL DEFAULT 1.0,
    \\  created_at TEXT NOT NULL DEFAULT (datetime('now')),
    \\  UNIQUE(brain_id, source_id, target_id)
    \\);
;

const engrams_fts_ddl =
    \\CREATE VIRTUAL TABLE IF NOT EXISTS engrams_fts USING fts5(
    \\  term,
    \\  definition,
    \\  content='engrams',
    \\  content_rowid='rowid'
    \\);
;

const indexes_ddl =
    \\CREATE INDEX IF NOT EXISTS idx_engrams_brain ON engrams(brain_id);
    \\CREATE INDEX IF NOT EXISTS idx_engrams_brain_memory ON engrams(brain_id, memory_term);
    \\CREATE INDEX IF NOT EXISTS idx_synapses_brain ON synapses(brain_id);
    \\CREATE INDEX IF NOT EXISTS idx_synapses_source ON synapses(source_id);
    \\CREATE INDEX IF NOT EXISTS idx_synapses_target ON synapses(target_id);
;

const triggers_ddl =
    \\CREATE TRIGGER IF NOT EXISTS engrams_ai AFTER INSERT ON engrams BEGIN
    \\  INSERT INTO engrams_fts(rowid, term, definition) VALUES (new.rowid, new.term, new.definition);
    \\END;
    \\CREATE TRIGGER IF NOT EXISTS engrams_ad AFTER DELETE ON engrams BEGIN
    \\  INSERT INTO engrams_fts(engrams_fts, rowid, term, definition) VALUES ('delete', old.rowid, old.term, old.definition);
    \\END;
    \\CREATE TRIGGER IF NOT EXISTS engrams_au AFTER UPDATE ON engrams BEGIN
    \\  INSERT INTO engrams_fts(engrams_fts, rowid, term, definition) VALUES ('delete', old.rowid, old.term, old.definition);
    \\  INSERT INTO engrams_fts(rowid, term, definition) VALUES (new.rowid, new.term, new.definition);
    \\END;
;

const cleanup_short_term =
    \\DELETE FROM engrams WHERE memory_term = 'short' AND created_at < datetime('now', '-24 hours');
;

const current_schema_version: i64 = 1;

// ── Public API ──────────────────────────────────────────────────────────

pub fn ensureSchema(db: *Db) !void {
    debug_log.log("memory_schema: ensuring schema", .{});

    // Pragmas (WAL, foreign keys)
    try db.exec(pragmas);

    // Schema version table
    try db.exec(schema_version_ddl);

    // Check current version
    const version = getSchemaVersion(db);
    debug_log.log("memory_schema: current version={d}", .{version});

    if (version < current_schema_version) {
        // Create all tables
        try db.exec(engrams_ddl);
        try db.exec(synapses_ddl);
        try db.exec(engrams_fts_ddl);
        try db.exec(indexes_ddl);
        try db.exec(triggers_ddl);

        // Set version
        try setSchemaVersion(db, current_schema_version);
        debug_log.log("memory_schema: schema created at version {d}", .{current_schema_version});
    }

    // Cleanup expired short-term memories
    db.exec(cleanup_short_term) catch |err| {
        debug_log.log("memory_schema: cleanup failed: {s}", .{@errorName(err)});
    };

    debug_log.log("memory_schema: ready", .{});
}

fn getSchemaVersion(db: *Db) i64 {
    var stmt = db.prepare("SELECT version FROM schema_version LIMIT 1") catch return 0;
    defer stmt.finalize();
    const result = stmt.step() catch return 0;
    if (result == .row) return stmt.columnInt(0);
    return 0;
}

fn setSchemaVersion(db: *Db, version: i64) !void {
    try db.exec("DELETE FROM schema_version");
    var stmt = try db.prepare("INSERT INTO schema_version (version) VALUES (?)");
    defer stmt.finalize();
    try stmt.bindInt(1, version);
    _ = try stmt.step();
}

// ── Tests ───────────────────────────────────────────────────────────────

test "ensureSchema creates tables and triggers" {
    var db = try Db.open(":memory:");
    defer db.close();

    try ensureSchema(&db);

    // Verify tables exist
    const tables = [_][]const u8{ "engrams", "synapses", "engrams_fts", "schema_version" };
    for (tables) |table_name| {
        var stmt = try db.prepare("SELECT name FROM sqlite_master WHERE type IN ('table') AND name = ?");
        defer stmt.finalize();
        try stmt.bindText(1, table_name);
        const result = try stmt.step();
        try std.testing.expectEqual(sqlite.StepResult.row, result);
    }

    // Verify triggers exist
    const trigger_names = [_][]const u8{ "engrams_ai", "engrams_ad", "engrams_au" };
    for (trigger_names) |trigger_name| {
        var stmt = try db.prepare("SELECT name FROM sqlite_master WHERE type = 'trigger' AND name = ?");
        defer stmt.finalize();
        try stmt.bindText(1, trigger_name);
        const result = try stmt.step();
        try std.testing.expectEqual(sqlite.StepResult.row, result);
    }

    // Verify schema version
    const version = getSchemaVersion(&db);
    try std.testing.expectEqual(current_schema_version, version);
}

test "ensureSchema is idempotent" {
    var db = try Db.open(":memory:");
    defer db.close();

    try ensureSchema(&db);
    try ensureSchema(&db); // Should not error

    const version = getSchemaVersion(&db);
    try std.testing.expectEqual(current_schema_version, version);
}

test "FTS5 trigger keeps index in sync" {
    var db = try Db.open(":memory:");
    defer db.close();
    try ensureSchema(&db);

    // Insert an engram
    try db.exec("INSERT INTO engrams (id, brain_id, term, definition) VALUES ('e1', 'test', 'Zig language', 'A systems programming language')");

    // FTS5 should find it
    {
        var stmt = try db.prepare("SELECT term FROM engrams_fts WHERE engrams_fts MATCH 'zig'");
        defer stmt.finalize();
        const result = try stmt.step();
        try std.testing.expectEqual(sqlite.StepResult.row, result);
        try std.testing.expectEqualStrings("Zig language", stmt.columnText(0).?);
    }

    // Update the engram
    try db.exec("UPDATE engrams SET term = 'Zig lang' WHERE id = 'e1'");

    // FTS5 should reflect the update
    {
        var stmt = try db.prepare("SELECT term FROM engrams_fts WHERE engrams_fts MATCH 'lang'");
        defer stmt.finalize();
        const result = try stmt.step();
        try std.testing.expectEqual(sqlite.StepResult.row, result);
        try std.testing.expectEqualStrings("Zig lang", stmt.columnText(0).?);
    }

    // Delete the engram
    try db.exec("DELETE FROM engrams WHERE id = 'e1'");

    // FTS5 should be empty
    {
        var stmt = try db.prepare("SELECT term FROM engrams_fts WHERE engrams_fts MATCH 'zig'");
        defer stmt.finalize();
        const result = try stmt.step();
        try std.testing.expectEqual(sqlite.StepResult.done, result);
    }
}
