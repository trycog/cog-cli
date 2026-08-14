const std = @import("std");
const sqlite = @import("sqlite.zig");
const debug_log = @import("debug_log.zig");

const Db = sqlite.Db;

// ── Schema DDL ──────────────────────────────────────────────────────────

const pragmas =
    \\PRAGMA foreign_keys=ON;
;

const wal_pragma = "PRAGMA journal_mode=WAL;";

const schema_version_ddl =
    \\CREATE TABLE IF NOT EXISTS schema_version (
    \\  version INTEGER NOT NULL
    \\);
;

const engrams_v1_ddl =
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

const engrams_ddl =
    \\CREATE TABLE IF NOT EXISTS engrams (
    \\  id TEXT PRIMARY KEY,
    \\  brain_id TEXT NOT NULL,
    \\  term TEXT NOT NULL,
    \\  definition TEXT NOT NULL,
    \\  memory_term TEXT NOT NULL DEFAULT 'short',
    \\  weight REAL NOT NULL DEFAULT 1.0,
    \\  created_at TEXT NOT NULL DEFAULT (datetime('now')),
    \\  updated_at TEXT NOT NULL DEFAULT (datetime('now')),
    \\  deprecated_at TEXT,
    \\  expires_at TEXT,
    \\  recall_count INTEGER NOT NULL DEFAULT 0,
    \\  last_recalled_at TEXT
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
    \\CREATE TRIGGER IF NOT EXISTS engrams_au AFTER UPDATE OF term, definition ON engrams BEGIN
    \\  INSERT INTO engrams_fts(engrams_fts, rowid, term, definition) VALUES ('delete', old.rowid, old.term, old.definition);
    \\  INSERT INTO engrams_fts(rowid, term, definition) VALUES (new.rowid, new.term, new.definition);
    \\END;
;

const cleanup_short_term =
    \\DELETE FROM engrams
    \\WHERE memory_term = 'short'
    \\  AND deprecated_at IS NULL
    \\  AND expires_at IS NULL
    \\  AND created_at < datetime('now', '-24 hours');
;

const current_schema_version: i64 = 1;

const lifecycle_columns = [_]struct {
    name: []const u8,
    ddl: [*:0]const u8,
}{
    .{ .name = "deprecated_at", .ddl = "ALTER TABLE engrams ADD COLUMN deprecated_at TEXT" },
    .{ .name = "expires_at", .ddl = "ALTER TABLE engrams ADD COLUMN expires_at TEXT" },
    .{ .name = "recall_count", .ddl = "ALTER TABLE engrams ADD COLUMN recall_count INTEGER NOT NULL DEFAULT 0" },
    .{ .name = "last_recalled_at", .ddl = "ALTER TABLE engrams ADD COLUMN last_recalled_at TEXT" },
};

fn expectColumn(db: *Db, column_name: []const u8) !void {
    var stmt = try db.prepare("SELECT name FROM pragma_table_info('engrams') WHERE name = ?");
    defer stmt.finalize();
    try stmt.bindText(1, column_name);
    try std.testing.expectEqual(sqlite.StepResult.row, try stmt.step());
}

// ── Public API ──────────────────────────────────────────────────────────

pub fn ensureSchema(db: *Db) !void {
    debug_log.log("memory_schema: ensuring schema", .{});

    // Pragmas (WAL, foreign keys)
    db.exec(wal_pragma) catch |err| {
        debug_log.log("memory_schema: WAL setup deferred: {s}", .{@errorName(err)});
    };
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

    try db.exec("BEGIN IMMEDIATE");
    errdefer db.exec("ROLLBACK") catch {};
    try ensureLifecycleColumns(db);
    try db.exec("DROP TRIGGER IF EXISTS engrams_au");
    try db.exec(triggers_ddl);
    try commitSchemaMigration(db, Db.exec);

    // Cleanup expired short-term memories
    db.exec(cleanup_short_term) catch |err| {
        debug_log.log("memory_schema: cleanup failed: {s}", .{@errorName(err)});
    };

    debug_log.log("memory_schema: ready", .{});
}

fn commitSchemaMigration(db: *Db, commit: anytype) sqlite.Error!void {
    const max_attempts = 3;
    var attempt: usize = 1;
    while (true) : (attempt += 1) {
        commit(db, "COMMIT") catch |err| switch (err) {
            error.SqliteBusy => {
                if (attempt >= max_attempts) return err;
                debug_log.log("memory_schema: commit busy; retrying attempt={d}", .{attempt + 1});
                std.Thread.yield() catch {};
                continue;
            },
            else => return err,
        };
        return;
    }
}

fn ensureLifecycleColumns(db: *Db) !void {
    debug_log.log("memory_schema: ensuring lifecycle columns", .{});
    for (lifecycle_columns) |column| {
        if (hasEngramColumn(db, column.name)) continue;
        debug_log.log("memory_schema: adding engrams.{s}", .{column.name});
        try db.exec(column.ddl);
    }
}

fn hasEngramColumn(db: *Db, column_name: []const u8) bool {
    var stmt = db.prepare("SELECT name FROM pragma_table_info('engrams') WHERE name = ?") catch return false;
    defer stmt.finalize();
    stmt.bindText(1, column_name) catch return false;
    return (stmt.step() catch return false) == .row;
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

test "ensureSchema creates lifecycle and recall metadata columns" {
    var db = try Db.open(":memory:");
    defer db.close();

    try ensureSchema(&db);

    for (lifecycle_columns) |column| try expectColumn(&db, column.name);

    var stmt = try db.prepare("SELECT deprecated_at, expires_at, recall_count, last_recalled_at FROM engrams WHERE id = 'defaults'");
    defer stmt.finalize();
    try db.exec("INSERT INTO engrams (id, brain_id, term, definition) VALUES ('defaults', 'test', 'Defaults', 'Lifecycle defaults')");
    try std.testing.expectEqual(sqlite.StepResult.row, try stmt.step());
    try std.testing.expect(stmt.columnText(0) == null);
    try std.testing.expect(stmt.columnText(1) == null);
    try std.testing.expectEqual(@as(i64, 0), stmt.columnInt(2));
    try std.testing.expect(stmt.columnText(3) == null);
}

test "ensureSchema migrates version 1 databases without losing data" {
    var db = try Db.open(":memory:");
    defer db.close();

    try db.exec(schema_version_ddl);
    try db.exec(engrams_v1_ddl);
    try db.exec(synapses_ddl);
    try db.exec(engrams_fts_ddl);
    try db.exec(indexes_ddl);
    try db.exec(triggers_ddl);
    try setSchemaVersion(&db, 1);
    try db.exec("INSERT INTO engrams (id, brain_id, term, definition, memory_term, weight) VALUES ('legacy', 'test', 'Legacy', 'Preserved definition', 'long', 2.5)");

    try ensureSchema(&db);
    try ensureSchema(&db);

    for (lifecycle_columns) |column| try expectColumn(&db, column.name);

    var stmt = try db.prepare("SELECT term, definition, memory_term, weight, recall_count FROM engrams WHERE id = 'legacy'");
    defer stmt.finalize();
    try std.testing.expectEqual(sqlite.StepResult.row, try stmt.step());
    try std.testing.expectEqualStrings("Legacy", stmt.columnText(0).?);
    try std.testing.expectEqualStrings("Preserved definition", stmt.columnText(1).?);
    try std.testing.expectEqualStrings("long", stmt.columnText(2).?);
    try std.testing.expectApproxEqAbs(@as(f64, 2.5), stmt.columnReal(3), 0.001);
    try std.testing.expectEqual(@as(i64, 0), stmt.columnInt(4));
    try std.testing.expectEqual(@as(i64, 1), getSchemaVersion(&db));
}

test "schema commit retries busy writers" {
    var db = try Db.open(":memory:");
    defer db.close();
    try db.exec("BEGIN");

    const Committer = struct {
        var attempts: usize = 0;

        fn commit(test_db: *Db, sql: [*:0]const u8) sqlite.Error!void {
            attempts += 1;
            if (attempts == 1) return error.SqliteBusy;
            try test_db.exec(sql);
        }
    };

    try commitSchemaMigration(&db, Committer.commit);
    try std.testing.expectEqual(@as(usize, 2), Committer.attempts);
}

test "concurrent schema migration is idempotent" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(root);
    const path = try std.fs.path.joinZ(std.testing.allocator, &.{ root, "memory.db" });
    defer std.testing.allocator.free(path);

    {
        var db = try Db.open(path);
        defer db.close();
        try db.exec(schema_version_ddl);
        try db.exec(engrams_v1_ddl);
        try db.exec(synapses_ddl);
        try db.exec(engrams_fts_ddl);
        try db.exec(indexes_ddl);
        try db.exec(triggers_ddl);
        try setSchemaVersion(&db, 1);
    }

    var started = std.atomic.Value(usize).init(0);
    var go = std.atomic.Value(bool).init(false);
    const Migrator = struct {
        fn run(db_path: [*:0]const u8, ready: *std.atomic.Value(usize), start: *std.atomic.Value(bool)) void {
            _ = ready.fetchAdd(1, .acq_rel);
            while (!start.load(.acquire)) std.Thread.yield() catch {};
            var db = Db.open(db_path) catch @panic("failed to open migration database");
            defer db.close();
            ensureSchema(&db) catch @panic("concurrent migration failed");
        }
    };

    const first = try std.Thread.spawn(.{}, Migrator.run, .{ path.ptr, &started, &go });
    const second = try std.Thread.spawn(.{}, Migrator.run, .{ path.ptr, &started, &go });
    while (started.load(.acquire) < 2) std.Thread.yield() catch {};
    go.store(true, .release);
    first.join();
    second.join();

    var db = try Db.open(path);
    defer db.close();
    for (lifecycle_columns) |column| try expectColumn(&db, column.name);
}

test "cleanup retains deprecated short-term history" {
    var db = try Db.open(":memory:");
    defer db.close();
    try ensureSchema(&db);

    try db.exec("INSERT INTO engrams (id, brain_id, term, definition, created_at, deprecated_at) VALUES ('deprecated-short', 'test', 'Deprecated short', 'Retained history', datetime('now', '-25 hours'), datetime('now', '-1 hour'))");
    try db.exec("INSERT INTO engrams (id, brain_id, term, definition, created_at, expires_at) VALUES ('scheduled-short', 'test', 'Scheduled short', 'Retained until expiry', datetime('now', '-25 hours'), datetime('now', '+1 hour'))");
    try ensureSchema(&db);

    var stmt = try db.prepare("SELECT definition FROM engrams WHERE id = ?");
    defer stmt.finalize();
    for ([_]struct { id: []const u8, definition: []const u8 }{
        .{ .id = "deprecated-short", .definition = "Retained history" },
        .{ .id = "scheduled-short", .definition = "Retained until expiry" },
    }) |expected| {
        try stmt.bindText(1, expected.id);
        try std.testing.expectEqual(sqlite.StepResult.row, try stmt.step());
        try std.testing.expectEqualStrings(expected.definition, stmt.columnText(0).?);
        try stmt.reset();
    }
}

test "recall metadata updates do not rewrite FTS entries" {
    var db = try Db.open(":memory:");
    defer db.close();
    try ensureSchema(&db);

    var stmt = try db.prepare("SELECT sql FROM sqlite_master WHERE type = 'trigger' AND name = 'engrams_au'");
    defer stmt.finalize();
    try std.testing.expectEqual(sqlite.StepResult.row, try stmt.step());
    const trigger_sql = stmt.columnText(0).?;
    try std.testing.expect(std.mem.indexOf(u8, trigger_sql, "UPDATE OF term, definition") != null);
    try std.testing.expect(std.mem.indexOf(u8, trigger_sql, "recall_count") == null);
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
