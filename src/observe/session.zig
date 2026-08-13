const std = @import("std");
const sqlite = @import("../sqlite.zig");
const schema = @import("schema.zig");
const types = @import("types.zig");
const debug_log = @import("../debug_log.zig");
const settings = @import("../settings.zig");
const uuid = @import("uuid");

const Db = sqlite.Db;

/// An active observation session with an open investigation database.
pub const Session = struct {
    id: []const u8,
    backend: types.Backend,
    target_pid: ?i64,
    status: types.SessionStatus,
    db: Db,
    db_path: []const u8,

    pub fn close(self: *Session) void {
        self.db.close();
    }
};

/// Manages observation sessions and their investigation databases.
///
/// Each session gets a dedicated SQLite database at `.cog/observe/<id>.db`.
/// Sessions are tracked in-memory while active and can be discovered
/// from disk for offline inspection.
pub const SessionManager = struct {
    sessions: std.StringHashMap(*Session),
    corrupt_database_paths: std.ArrayListUnmanaged([]const u8),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) !SessionManager {
        var manager: SessionManager = .{
            .sessions = std.StringHashMap(*Session).init(allocator),
            .corrupt_database_paths = .empty,
            .allocator = allocator,
        };
        errdefer manager.deinit();
        try manager.discoverPersistedSessions();
        try manager.cleanupExpiredSessions(settings.observeRetentionDays(allocator));
        return manager;
    }

    pub fn deinit(self: *SessionManager) void {
        var iter = self.sessions.iterator();
        while (iter.next()) |entry| {
            const session = entry.value_ptr.*;
            session.close();
            self.allocator.free(session.db_path);
            self.allocator.free(entry.key_ptr.*);
            self.allocator.destroy(session);
        }
        self.sessions.deinit();
        for (self.corrupt_database_paths.items) |path| self.allocator.free(path);
        self.corrupt_database_paths.deinit(self.allocator);
    }

    fn discoverPersistedSessions(self: *SessionManager) !void {
        var dir = std.fs.cwd().openDir(".cog/observe", .{ .iterate = true }) catch |err| switch (err) {
            error.FileNotFound => {
                debug_log.log("SessionManager.discover: no persisted observe directory", .{});
                return;
            },
            else => return err,
        };
        defer dir.close();

        debug_log.log("SessionManager.discover: scanning .cog/observe", .{});
        var iterator = dir.iterate();
        while (try iterator.next()) |entry| {
            if (entry.kind != .file or !std.mem.endsWith(u8, entry.name, ".db")) continue;

            const db_path = try std.fs.path.join(self.allocator, &.{ ".cog/observe", entry.name });
            self.discoverPersistedSession(db_path) catch |err| switch (err) {
                error.CorruptSessionDatabase => {
                    debug_log.log("SessionManager.discover: reporting corrupt database path={s}", .{db_path});
                    try self.corrupt_database_paths.append(self.allocator, db_path);
                },
                else => {
                    self.allocator.free(db_path);
                    return err;
                },
            };
        }
    }

    fn discoverPersistedSession(self: *SessionManager, db_path: []const u8) !void {
        const db_path_z = try self.allocator.dupeZ(u8, db_path);
        defer self.allocator.free(db_path_z);

        var db = Db.open(db_path_z) catch |err| {
            debug_log.log("SessionManager.discover: open failed path={s} error={s}", .{ db_path, @errorName(err) });
            return error.CorruptSessionDatabase;
        };
        errdefer db.close();

        var stmt = db.prepare("SELECT id, backend, target_pid, status FROM sessions LIMIT 2") catch |err| {
            debug_log.log("SessionManager.discover: invalid schema path={s} error={s}", .{ db_path, @errorName(err) });
            return error.CorruptSessionDatabase;
        };
        defer stmt.finalize();

        const first_result = stmt.step() catch |err| {
            debug_log.log("SessionManager.discover: row read failed path={s} error={s}", .{ db_path, @errorName(err) });
            return error.CorruptSessionDatabase;
        };
        if (first_result != .row) {
            debug_log.log("SessionManager.discover: missing session row path={s}", .{db_path});
            return error.CorruptSessionDatabase;
        }

        const id_text = stmt.columnText(0) orelse return error.CorruptSessionDatabase;
        const backend_text = stmt.columnText(1) orelse return error.CorruptSessionDatabase;
        const status_text = stmt.columnText(3) orelse return error.CorruptSessionDatabase;
        const backend = types.Backend.fromString(backend_text) orelse return error.CorruptSessionDatabase;
        const status = types.SessionStatus.fromString(status_text) orelse return error.CorruptSessionDatabase;
        if (self.sessions.contains(id_text)) return error.CorruptSessionDatabase;

        const second_result = stmt.step() catch |err| {
            debug_log.log("SessionManager.discover: second row read failed path={s} error={s}", .{ db_path, @errorName(err) });
            return error.CorruptSessionDatabase;
        };
        if (second_result != .done) {
            debug_log.log("SessionManager.discover: multiple session rows path={s}", .{db_path});
            return error.CorruptSessionDatabase;
        }

        const id = try self.allocator.dupe(u8, id_text);
        errdefer self.allocator.free(id);
        const session = try self.allocator.create(Session);
        errdefer self.allocator.destroy(session);
        session.* = .{
            .id = id,
            .backend = backend,
            .target_pid = if (stmt.columnText(2) != null) stmt.columnInt(2) else null,
            .status = status,
            .db = db,
            .db_path = db_path,
        };
        try self.sessions.put(id, session);
        debug_log.log("SessionManager.discover: loaded id={s} status={s}", .{ id, status.toString() });
    }

    /// Delete finalized, stopped, or failed sessions older than the configured retention.
    pub fn cleanupExpiredSessions(self: *SessionManager, retention_days: i64) !void {
        if (retention_days < 0) return error.InvalidRetention;

        var expired_ids: std.ArrayListUnmanaged([]const u8) = .empty;
        defer expired_ids.deinit(self.allocator);

        var iterator = self.sessions.iterator();
        while (iterator.next()) |entry| {
            const session = entry.value_ptr.*;
            if (session.status == .capturing) {
                debug_log.log("SessionManager.cleanup: preserving active id={s}", .{session.id});
                continue;
            }

            var stmt = try session.db.prepare(
                "SELECT 1 FROM sessions WHERE id = ? AND COALESCE(stopped_at, started_at) <= datetime('now', '-' || ? || ' days')",
            );
            defer stmt.finalize();
            try stmt.bindText(1, session.id);
            try stmt.bindInt(2, retention_days);
            if (try stmt.step() == .row) {
                try expired_ids.append(self.allocator, session.id);
            }
        }

        for (expired_ids.items) |id| {
            const session = self.sessions.get(id) orelse continue;
            const path = try self.allocator.dupe(u8, session.db_path);
            defer self.allocator.free(path);
            debug_log.log("SessionManager.cleanup: deleting expired id={s} path={s}", .{ id, path });
            std.debug.assert(self.destroySession(id));
            std.fs.cwd().deleteFile(path) catch |err| {
                debug_log.log("SessionManager.cleanup: delete failed path={s} error={s}", .{ path, @errorName(err) });
                return err;
            };
        }
    }

    /// Create a new observation session with its own investigation database.
    pub fn createSession(self: *SessionManager, backend: types.Backend, target_pid: ?i64) ![]const u8 {
        const id_bytes = uuid.v4.new();
        const id_array = uuid.urn.serialize(id_bytes);
        const id = try self.allocator.dupe(u8, &id_array);
        errdefer self.allocator.free(id);

        debug_log.log("SessionManager.createSession: id={s} backend={s}", .{ id, backend.toString() });

        // Ensure .cog/observe/ directory exists
        std.fs.cwd().makePath(".cog/observe") catch {
            debug_log.log("SessionManager.createSession: failed to create .cog/observe/", .{});
            return error.Explained;
        };

        // Create the investigation database
        const db_path = try std.fmt.allocPrint(self.allocator, ".cog/observe/{s}.db", .{id});
        errdefer self.allocator.free(db_path);
        errdefer {
            debug_log.log("SessionManager.createSession: removing partial database {s}", .{db_path});
            std.fs.cwd().deleteFile(db_path) catch |err| switch (err) {
                error.FileNotFound => {},
                else => debug_log.log("SessionManager.createSession: failed to remove partial database {s}: {s}", .{ db_path, @errorName(err) }),
            };
        }

        const db_path_z = try self.allocator.dupeZ(u8, db_path);
        defer self.allocator.free(db_path_z);

        var db = try Db.open(db_path_z);
        errdefer db.close();

        try schema.ensureSchema(&db);

        // Insert session record
        {
            var stmt = try db.prepare("INSERT INTO sessions (id, backend, target_pid, status) VALUES (?, ?, ?, 'capturing')");
            defer stmt.finalize();
            try stmt.bindText(1, id);
            try stmt.bindText(2, backend.toString());
            if (target_pid) |pid| {
                try stmt.bindInt(3, pid);
            }
            _ = try stmt.step();
        }

        debug_log.log("SessionManager.createSession: db created at {s}", .{db_path});

        const session = try self.allocator.create(Session);
        session.* = .{
            .id = id,
            .backend = backend,
            .target_pid = target_pid,
            .status = .capturing,
            .db = db,
            .db_path = db_path,
        };
        errdefer self.allocator.destroy(session);

        try self.sessions.put(id, session);

        return id;
    }

    /// Get an active session by ID.
    pub fn getSession(self: *SessionManager, id: []const u8) ?*Session {
        return self.sessions.get(id);
    }

    /// Stop a session: update status, set stopped_at.
    pub fn stopSession(self: *SessionManager, id: []const u8) !void {
        const session = self.sessions.get(id) orelse return error.SessionNotFound;
        debug_log.log("SessionManager.stopSession: id={s}", .{id});

        session.status = .stopped;

        // Update in the database
        var stmt = try session.db.prepare("UPDATE sessions SET status = 'stopped', stopped_at = datetime('now') WHERE id = ?");
        defer stmt.finalize();
        try stmt.bindText(1, id);
        _ = try stmt.step();
    }

    /// Finalize a session: mark as finalized and close.
    pub fn finalizeSession(self: *SessionManager, id: []const u8) !void {
        const session = self.sessions.get(id) orelse return error.SessionNotFound;
        debug_log.log("SessionManager.finalizeSession: id={s}", .{id});

        // Update status in the database
        {
            var stmt = try session.db.prepare("UPDATE sessions SET status = 'finalized', stopped_at = datetime('now') WHERE id = ?");
            defer stmt.finalize();
            try stmt.bindText(1, id);
            _ = try stmt.step();
        }

        session.status = .finalized;
    }

    /// Remove a session from the active map and close its database.
    pub fn destroySession(self: *SessionManager, id: []const u8) bool {
        if (self.sessions.fetchRemove(id)) |kv| {
            const session = kv.value;
            session.close();
            self.allocator.free(session.db_path);
            self.allocator.free(kv.key);
            self.allocator.destroy(session);
            return true;
        }
        return false;
    }

    pub fn sessionCount(self: *const SessionManager) usize {
        return self.sessions.count();
    }

    pub fn corruptDatabasePaths(self: *const SessionManager) []const []const u8 {
        return self.corrupt_database_paths.items;
    }

    /// Summary info for listing sessions.
    pub const SessionInfo = struct {
        id: []const u8,
        backend: types.Backend,
        status: types.SessionStatus,
        target_pid: ?i64,
        event_count: i64,
    };

    /// List active and persisted sessions, optionally filtered by status.
    pub fn listSessions(self: *const SessionManager, allocator: std.mem.Allocator, status_filter: ?types.SessionStatus) ![]const SessionInfo {
        var result = std.ArrayListUnmanaged(SessionInfo).empty;
        errdefer {
            for (result.items) |info| allocator.free(info.id);
            result.deinit(allocator);
        }

        var iter = self.sessions.iterator();
        while (iter.next()) |entry| {
            const session = entry.value_ptr.*;
            if (status_filter) |wanted| {
                if (session.status != wanted) continue;
            }

            var count_stmt = try session.db.prepare("SELECT count(*) FROM events WHERE session_id = ?");
            defer count_stmt.finalize();
            try count_stmt.bindText(1, session.id);
            const event_count = if (try count_stmt.step() == .row) count_stmt.columnInt(0) else 0;

            try result.append(allocator, .{
                .id = try allocator.dupe(u8, session.id),
                .backend = session.backend,
                .status = session.status,
                .target_pid = session.target_pid,
                .event_count = event_count,
            });
        }
        return result.toOwnedSlice(allocator);
    }

    pub fn freeSessionInfos(_: *const SessionManager, allocator: std.mem.Allocator, sessions: []const SessionInfo) void {
        for (sessions) |info| allocator.free(info.id);
        allocator.free(sessions);
    }

    /// Get event count for a session.
    pub fn getEventCount(self: *SessionManager, id: []const u8) !i64 {
        const session = self.sessions.get(id) orelse return error.SessionNotFound;
        var stmt = try session.db.prepare("SELECT count(*) FROM events WHERE session_id = ?");
        defer stmt.finalize();
        try stmt.bindText(1, id);
        const result = try stmt.step();
        if (result == .row) return stmt.columnInt(0);
        return 0;
    }
};

// ── Tests ───────────────────────────────────────────────────────────────

test "SessionManager discovers persisted sessions after restart" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var old_cwd = try std.fs.cwd().openDir(".", .{});
    defer {
        old_cwd.setAsCwd() catch {};
        old_cwd.close();
    }
    try tmp.dir.setAsCwd();

    var first = try SessionManager.init(std.testing.allocator);
    const id_copy = try std.testing.allocator.dupe(u8, try first.createSession(.syscall, 42));
    defer std.testing.allocator.free(id_copy);
    try first.finalizeSession(id_copy);
    first.deinit();

    var second = try SessionManager.init(std.testing.allocator);
    defer second.deinit();

    const sessions = try second.listSessions(std.testing.allocator, null);
    defer second.freeSessionInfos(std.testing.allocator, sessions);
    try std.testing.expectEqual(@as(usize, 1), sessions.len);
    try std.testing.expectEqualStrings(id_copy, sessions[0].id);
    try std.testing.expectEqual(types.SessionStatus.finalized, sessions[0].status);
    try std.testing.expectEqual(@as(i64, 0), sessions[0].event_count);
}

test "SessionManager filters persisted sessions by status" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var old_cwd = try std.fs.cwd().openDir(".", .{});
    defer {
        old_cwd.setAsCwd() catch {};
        old_cwd.close();
    }
    try tmp.dir.setAsCwd();

    var mgr = try SessionManager.init(std.testing.allocator);
    defer mgr.deinit();
    const stopped_id = try std.testing.allocator.dupe(u8, try mgr.createSession(.net, null));
    defer std.testing.allocator.free(stopped_id);
    _ = try mgr.createSession(.gpu, null);
    try mgr.stopSession(stopped_id);

    const sessions = try mgr.listSessions(std.testing.allocator, .stopped);
    defer mgr.freeSessionInfos(std.testing.allocator, sessions);
    try std.testing.expectEqual(@as(usize, 1), sessions.len);
    try std.testing.expectEqual(types.SessionStatus.stopped, sessions[0].status);
}

test "SessionManager reports corrupt persisted databases without hiding healthy sessions" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var old_cwd = try std.fs.cwd().openDir(".", .{});
    defer {
        old_cwd.setAsCwd() catch {};
        old_cwd.close();
    }
    try tmp.dir.setAsCwd();

    var first = try SessionManager.init(std.testing.allocator);
    _ = try first.createSession(.syscall, null);
    first.deinit();

    const file = try std.fs.cwd().createFile(".cog/observe/corrupt.db", .{});
    try file.writeAll("not sqlite");
    file.close();

    var second = try SessionManager.init(std.testing.allocator);
    defer second.deinit();
    try std.testing.expectEqual(@as(usize, 1), second.sessionCount());
    try std.testing.expectEqual(@as(usize, 1), second.corruptDatabasePaths().len);
    try std.testing.expectEqualStrings(".cog/observe/corrupt.db", second.corruptDatabasePaths()[0]);
}

test "cleanupExpiredSessions deletes expired completed databases and preserves active sessions" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var old_cwd = try std.fs.cwd().openDir(".", .{});
    defer {
        old_cwd.setAsCwd() catch {};
        old_cwd.close();
    }
    try tmp.dir.setAsCwd();

    var mgr = try SessionManager.init(std.testing.allocator);
    defer mgr.deinit();
    const expired_id = try std.testing.allocator.dupe(u8, try mgr.createSession(.syscall, null));
    defer std.testing.allocator.free(expired_id);
    const active_id = try std.testing.allocator.dupe(u8, try mgr.createSession(.gpu, null));
    defer std.testing.allocator.free(active_id);
    try mgr.finalizeSession(expired_id);

    const expired_path = try std.testing.allocator.dupe(u8, mgr.getSession(expired_id).?.db_path);
    defer std.testing.allocator.free(expired_path);
    try mgr.getSession(expired_id).?.db.exec("UPDATE sessions SET stopped_at = datetime('now', '-40 days')");

    try mgr.cleanupExpiredSessions(30);

    try std.testing.expect(mgr.getSession(expired_id) == null);
    try std.testing.expect(mgr.getSession(active_id) != null);
    try std.testing.expectError(error.FileNotFound, std.fs.cwd().access(expired_path, .{}));
}

test "createSession and getSession" {
    // Use a temp directory so we don't pollute the working tree
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // Change to tmp dir for the duration of the test
    var old_cwd = try std.fs.cwd().openDir(".", .{});
    defer {
        old_cwd.setAsCwd() catch {};
        old_cwd.close();
    }
    tmp.dir.setAsCwd() catch return;

    var mgr = try SessionManager.init(std.testing.allocator);
    defer mgr.deinit();

    const id = try mgr.createSession(.syscall, 1234);
    try std.testing.expect(id.len == 36); // UUID length

    const session = mgr.getSession(id);
    try std.testing.expect(session != null);
    try std.testing.expectEqual(types.Backend.syscall, session.?.backend);
    try std.testing.expectEqual(types.SessionStatus.capturing, session.?.status);
    try std.testing.expectEqual(@as(?i64, 1234), session.?.target_pid);
}

test "stopSession updates status" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var old_cwd = try std.fs.cwd().openDir(".", .{});
    defer {
        old_cwd.setAsCwd() catch {};
        old_cwd.close();
    }
    tmp.dir.setAsCwd() catch return;

    var mgr = try SessionManager.init(std.testing.allocator);
    defer mgr.deinit();

    const id = try mgr.createSession(.gpu, null);
    try mgr.stopSession(id);

    const session = mgr.getSession(id).?;
    try std.testing.expectEqual(types.SessionStatus.stopped, session.status);
}

test "destroySession removes and cleans up" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var old_cwd = try std.fs.cwd().openDir(".", .{});
    defer {
        old_cwd.setAsCwd() catch {};
        old_cwd.close();
    }
    tmp.dir.setAsCwd() catch return;

    var mgr = try SessionManager.init(std.testing.allocator);
    defer mgr.deinit();

    const id_copy = try std.testing.allocator.dupe(u8, try mgr.createSession(.net, null));
    defer std.testing.allocator.free(id_copy);

    try std.testing.expectEqual(@as(usize, 1), mgr.sessionCount());

    const removed = mgr.destroySession(id_copy);
    try std.testing.expect(removed);
    try std.testing.expectEqual(@as(usize, 0), mgr.sessionCount());
    try std.testing.expect(mgr.getSession(id_copy) == null);
}

test "listSessions returns all active" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var old_cwd = try std.fs.cwd().openDir(".", .{});
    defer {
        old_cwd.setAsCwd() catch {};
        old_cwd.close();
    }
    tmp.dir.setAsCwd() catch return;

    var mgr = try SessionManager.init(std.testing.allocator);
    defer mgr.deinit();

    _ = try mgr.createSession(.syscall, 100);
    _ = try mgr.createSession(.gpu, 200);

    const sessions = try mgr.listSessions(std.testing.allocator, null);
    defer mgr.freeSessionInfos(std.testing.allocator, sessions);

    try std.testing.expectEqual(@as(usize, 2), sessions.len);
}
