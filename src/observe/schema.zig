const std = @import("std");
const sqlite = @import("../sqlite.zig");
const debug_log = @import("../debug_log.zig");

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

const sessions_ddl =
    \\CREATE TABLE IF NOT EXISTS sessions (
    \\  id TEXT PRIMARY KEY,
    \\  backend TEXT NOT NULL,
    \\  target_pid INTEGER,
    \\  status TEXT NOT NULL DEFAULT 'capturing',
    \\  started_at TEXT NOT NULL DEFAULT (datetime('now')),
    \\  stopped_at TEXT,
    \\  metadata_json TEXT
    \\);
;

const events_ddl =
    \\CREATE TABLE IF NOT EXISTS events (
    \\  id INTEGER PRIMARY KEY,
    \\  session_id TEXT NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
    \\  timestamp_ns INTEGER NOT NULL,
    \\  event_type TEXT NOT NULL,
    \\  pid INTEGER,
    \\  tid INTEGER,
    \\  data_json TEXT,
    \\  created_at TEXT NOT NULL DEFAULT (datetime('now'))
    \\);
;

const causal_chains_ddl =
    \\CREATE TABLE IF NOT EXISTS causal_chains (
    \\  id INTEGER PRIMARY KEY,
    \\  session_id TEXT NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
    \\  chain_type TEXT NOT NULL,
    \\  description TEXT NOT NULL,
    \\  root_event_id INTEGER REFERENCES events(id),
    \\  event_ids_json TEXT,
    \\  computed_at TEXT NOT NULL DEFAULT (datetime('now'))
    \\);
;

const events_fts_ddl =
    \\CREATE VIRTUAL TABLE IF NOT EXISTS events_fts USING fts5(
    \\  event_type,
    \\  data_json,
    \\  content='events',
    \\  content_rowid='rowid'
    \\);
;

const indexes_ddl =
    \\CREATE INDEX IF NOT EXISTS idx_events_session ON events(session_id, timestamp_ns);
    \\CREATE INDEX IF NOT EXISTS idx_events_type ON events(event_type);
    \\CREATE INDEX IF NOT EXISTS idx_events_pid ON events(pid);
    \\CREATE INDEX IF NOT EXISTS idx_causal_chains_session ON causal_chains(session_id);
;

const triggers_ddl =
    \\CREATE TRIGGER IF NOT EXISTS events_ai AFTER INSERT ON events BEGIN
    \\  INSERT INTO events_fts(rowid, event_type, data_json) VALUES (new.rowid, new.event_type, new.data_json);
    \\END;
    \\CREATE TRIGGER IF NOT EXISTS events_ad AFTER DELETE ON events BEGIN
    \\  INSERT INTO events_fts(events_fts, rowid, event_type, data_json) VALUES ('delete', old.rowid, old.event_type, old.data_json);
    \\END;
    \\CREATE TRIGGER IF NOT EXISTS events_au AFTER UPDATE ON events BEGIN
    \\  INSERT INTO events_fts(events_fts, rowid, event_type, data_json) VALUES ('delete', old.rowid, old.event_type, old.data_json);
    \\  INSERT INTO events_fts(rowid, event_type, data_json) VALUES (new.rowid, new.event_type, new.data_json);
    \\END;
;

const current_schema_version: i64 = 1;

// ── Public API ──────────────────────────────────────────────────────────

pub fn ensureSchema(db: *Db) !void {
    debug_log.log("observe_schema: ensuring schema", .{});

    try db.exec(pragmas);
    try db.exec(schema_version_ddl);

    const version = getSchemaVersion(db);
    debug_log.log("observe_schema: current version={d}", .{version});

    if (version < current_schema_version) {
        try db.exec(sessions_ddl);
        try db.exec(events_ddl);
        try db.exec(causal_chains_ddl);
        try db.exec(events_fts_ddl);
        try db.exec(indexes_ddl);
        try db.exec(triggers_ddl);

        try setSchemaVersion(db, current_schema_version);
        debug_log.log("observe_schema: schema created at version {d}", .{current_schema_version});
    }

    debug_log.log("observe_schema: ready", .{});
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

    const tables = [_][]const u8{ "sessions", "events", "causal_chains", "events_fts", "schema_version" };
    for (tables) |table_name| {
        var stmt = try db.prepare("SELECT name FROM sqlite_master WHERE type IN ('table') AND name = ?");
        defer stmt.finalize();
        try stmt.bindText(1, table_name);
        const result = try stmt.step();
        try std.testing.expectEqual(sqlite.StepResult.row, result);
    }

    const trigger_names = [_][]const u8{ "events_ai", "events_ad", "events_au" };
    for (trigger_names) |trigger_name| {
        var stmt = try db.prepare("SELECT name FROM sqlite_master WHERE type = 'trigger' AND name = ?");
        defer stmt.finalize();
        try stmt.bindText(1, trigger_name);
        const result = try stmt.step();
        try std.testing.expectEqual(sqlite.StepResult.row, result);
    }

    const version = getSchemaVersion(&db);
    try std.testing.expectEqual(current_schema_version, version);
}

test "ensureSchema is idempotent" {
    var db = try Db.open(":memory:");
    defer db.close();

    try ensureSchema(&db);
    try ensureSchema(&db);

    const version = getSchemaVersion(&db);
    try std.testing.expectEqual(current_schema_version, version);
}

test "FTS5 trigger keeps index in sync" {
    var db = try Db.open(":memory:");
    defer db.close();
    try ensureSchema(&db);

    // Create a session first (foreign key)
    try db.exec("INSERT INTO sessions (id, backend) VALUES ('s1', 'syscall')");

    // Insert an event
    try db.exec("INSERT INTO events (session_id, timestamp_ns, event_type, data_json) VALUES ('s1', 1000, 'sys_enter', '{\"syscall\":\"read\"}')");

    // FTS5 should find it
    {
        var stmt = try db.prepare("SELECT event_type FROM events_fts WHERE events_fts MATCH 'read'");
        defer stmt.finalize();
        const result = try stmt.step();
        try std.testing.expectEqual(sqlite.StepResult.row, result);
    }

    // Delete the event
    try db.exec("DELETE FROM events WHERE session_id = 's1'");

    // FTS5 should be empty
    {
        var stmt = try db.prepare("SELECT event_type FROM events_fts WHERE events_fts MATCH 'read'");
        defer stmt.finalize();
        const result = try stmt.step();
        try std.testing.expectEqual(sqlite.StepResult.done, result);
    }
}
