const std = @import("std");
const sqlite = @import("../sqlite.zig");
const schema = @import("schema.zig");
const types = @import("types.zig");
const debug_log = @import("../debug_log.zig");
const paths = @import("../paths.zig");
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
    observe_dir: ?[]const u8,

    pub fn init(allocator: std.mem.Allocator) !SessionManager {
        var manager: SessionManager = .{
            .sessions = std.StringHashMap(*Session).init(allocator),
            .corrupt_database_paths = .empty,
            .allocator = allocator,
            .observe_dir = null,
        };
        errdefer manager.deinit();
        try manager.discoverPersistedSessions();
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
        if (self.observe_dir) |observe_dir| self.allocator.free(observe_dir);
    }

    fn resolveObserveDir(self: *SessionManager, create_if_missing: bool) !?[]const u8 {
        if (self.observe_dir == null) {
            const cog_dir = paths.findCogDir(self.allocator) catch |err| switch (err) {
                error.NoCogDir => blk: {
                    if (!create_if_missing) {
                        debug_log.log("SessionManager.resolveObserveDir: no project Cog directory available for discovery", .{});
                        return null;
                    }
                    debug_log.log("SessionManager.resolveObserveDir: creating project Cog directory in cwd", .{});
                    break :blk paths.findOrCreateCogDir(self.allocator) catch |create_err| {
                        debug_log.log("SessionManager.resolveObserveDir: project Cog directory creation failed: {s}", .{@errorName(create_err)});
                        return create_err;
                    };
                },
                else => {
                    debug_log.log("SessionManager.resolveObserveDir: project Cog directory resolution failed: {s}", .{@errorName(err)});
                    return err;
                },
            };
            defer self.allocator.free(cog_dir);
            debug_log.log("SessionManager.resolveObserveDir: resolved project Cog directory {s}", .{cog_dir});

            self.observe_dir = try std.fs.path.join(self.allocator, &.{ cog_dir, "observe" });
            debug_log.log("SessionManager.resolveObserveDir: storage and discovery path {s}", .{self.observe_dir.?});
        } else {
            debug_log.log("SessionManager.resolveObserveDir: using cached path {s}", .{self.observe_dir.?});
        }

        const observe_dir = self.observe_dir.?;
        if (create_if_missing) {
            const cog_dir = std.fs.path.dirname(observe_dir) orelse return error.NoCogDir;
            var project_dir = std.fs.openDirAbsolute(cog_dir, .{}) catch |err| {
                debug_log.log("SessionManager.resolveObserveDir: failed to open project Cog directory {s}: {s}", .{ cog_dir, @errorName(err) });
                return err;
            };
            defer project_dir.close();
            project_dir.makePath("observe") catch |err| {
                debug_log.log("SessionManager.resolveObserveDir: failed to create observe directory in {s}: {s}", .{ cog_dir, @errorName(err) });
                return err;
            };
        }

        return observe_dir;
    }

    fn discoverPersistedSessions(self: *SessionManager) !void {
        const observe_dir = (try self.resolveObserveDir(false)) orelse return;
        var dir = std.fs.openDirAbsolute(observe_dir, .{ .iterate = true }) catch |err| switch (err) {
            error.FileNotFound => {
                debug_log.log("SessionManager.discover: no persisted observe directory at {s}", .{observe_dir});
                return;
            },
            else => {
                debug_log.log("SessionManager.discover: failed to open {s}: {s}", .{ observe_dir, @errorName(err) });
                return err;
            },
        };
        defer dir.close();

        debug_log.log("SessionManager.discover: scanning {s}", .{observe_dir});
        var iterator = dir.iterate();
        while (try iterator.next()) |entry| {
            if (entry.kind != .file or !std.mem.endsWith(u8, entry.name, ".db")) continue;

            const db_path = try std.fs.path.join(self.allocator, &.{ observe_dir, entry.name });
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
        const target_pid = if (stmt.columnText(2) != null) stmt.columnInt(2) else null;
        const id = try self.allocator.dupe(u8, id_text);
        errdefer self.allocator.free(id);

        const second_result = stmt.step() catch |err| {
            debug_log.log("SessionManager.discover: second row read failed path={s} error={s}", .{ db_path, @errorName(err) });
            return error.CorruptSessionDatabase;
        };
        if (second_result != .done) {
            debug_log.log("SessionManager.discover: multiple session rows path={s}", .{db_path});
            return error.CorruptSessionDatabase;
        }

        const session = try self.allocator.create(Session);
        errdefer self.allocator.destroy(session);
        session.* = .{
            .id = id,
            .backend = backend,
            .target_pid = target_pid,
            .status = status,
            .db = db,
            .db_path = db_path,
        };
        try self.sessions.put(id, session);
        debug_log.log("SessionManager.discover: loaded id={s} status={s}", .{ id, status.toString() });
    }

    /// Explicitly delete finalized sessions older than the configured retention.
    pub fn pruneExpiredSessions(self: *SessionManager, retention_days: i64) !usize {
        if (retention_days < 0) {
            debug_log.log("SessionManager.prune: invalid retention_days={d}", .{retention_days});
            return error.InvalidRetention;
        }

        debug_log.log("SessionManager.prune: scanning sessions retention_days={d}", .{retention_days});
        var expired_ids: std.ArrayListUnmanaged([]const u8) = .empty;
        defer expired_ids.deinit(self.allocator);

        var iterator = self.sessions.iterator();
        while (iterator.next()) |entry| {
            const session = entry.value_ptr.*;
            if (session.status != .finalized) {
                debug_log.log("SessionManager.prune: preserving id={s} status={s}", .{ session.id, session.status.toString() });
                continue;
            }

            var stmt = session.db.prepare(
                "SELECT 1 FROM sessions WHERE id = ? AND status = 'finalized' AND stopped_at IS NOT NULL AND stopped_at <= datetime('now', '-' || ? || ' days')",
            ) catch |err| {
                debug_log.log("SessionManager.prune: expiration query prepare failed id={s} error={s}", .{ session.id, @errorName(err) });
                return err;
            };
            defer stmt.finalize();
            stmt.bindText(1, session.id) catch |err| {
                debug_log.log("SessionManager.prune: expiration query bind id failed id={s} error={s}", .{ session.id, @errorName(err) });
                return err;
            };
            stmt.bindInt(2, retention_days) catch |err| {
                debug_log.log("SessionManager.prune: expiration query bind retention failed id={s} error={s}", .{ session.id, @errorName(err) });
                return err;
            };
            const result = stmt.step() catch |err| {
                debug_log.log("SessionManager.prune: expiration query failed id={s} error={s}", .{ session.id, @errorName(err) });
                return err;
            };
            if (result == .row) {
                debug_log.log("SessionManager.prune: expired finalized id={s}", .{session.id});
                try expired_ids.append(self.allocator, session.id);
            } else {
                debug_log.log("SessionManager.prune: preserving unexpired finalized id={s}", .{session.id});
            }
        }

        var pruned: usize = 0;
        for (expired_ids.items) |id| {
            const session = self.sessions.get(id) orelse continue;
            const path = try self.allocator.dupe(u8, session.db_path);
            defer self.allocator.free(path);
            debug_log.log("SessionManager.prune: closing expired finalized id={s} path={s}", .{ id, path });
            std.debug.assert(self.destroySession(id));
            debug_log.log("SessionManager.prune: deleting database path={s}", .{path});
            std.fs.deleteFileAbsolute(path) catch |err| {
                debug_log.log("SessionManager.prune: delete failed path={s} error={s}", .{ path, @errorName(err) });
                return err;
            };
            pruned += 1;
            debug_log.log("SessionManager.prune: deleted database path={s}", .{path});
        }

        debug_log.log("SessionManager.prune: completed pruned={d}", .{pruned});
        return pruned;
    }

    /// Create a new observation session with its own investigation database.
    pub fn createSession(self: *SessionManager, backend: types.Backend, target_pid: ?i64) ![]const u8 {
        const id_bytes = uuid.v4.new();
        const id_array = uuid.urn.serialize(id_bytes);
        const id = try self.allocator.dupe(u8, &id_array);
        errdefer self.allocator.free(id);

        debug_log.log("SessionManager.createSession: id={s} backend={s}", .{ id, backend.toString() });

        const observe_dir = (try self.resolveObserveDir(true)).?;

        // Create the investigation database in the resolved project Cog directory.
        const db_filename = try std.fmt.allocPrint(self.allocator, "{s}.db", .{id});
        defer self.allocator.free(db_filename);
        const db_path = try std.fs.path.join(self.allocator, &.{ observe_dir, db_filename });
        errdefer self.allocator.free(db_path);
        errdefer {
            debug_log.log("SessionManager.createSession: removing partial database {s}", .{db_path});
            std.fs.deleteFileAbsolute(db_path) catch |err| switch (err) {
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

        // Update status in the database before mutating in-memory state.
        {
            var stmt = session.db.prepare("UPDATE sessions SET status = 'finalized', stopped_at = datetime('now') WHERE id = ?") catch |err| {
                debug_log.log("SessionManager.finalizeSession: prepare failed id={s} error={s}", .{ id, @errorName(err) });
                return err;
            };
            defer stmt.finalize();
            stmt.bindText(1, id) catch |err| {
                debug_log.log("SessionManager.finalizeSession: bind failed id={s} error={s}", .{ id, @errorName(err) });
                return err;
            };
            _ = stmt.step() catch |err| {
                debug_log.log("SessionManager.finalizeSession: update failed id={s} error={s}", .{ id, @errorName(err) });
                return err;
            };
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
        var stmt = session.db.prepare("SELECT count(*) FROM events WHERE session_id = ?") catch |err| {
            debug_log.log("SessionManager.getEventCount: prepare failed id={s} error={s}", .{ id, @errorName(err) });
            return err;
        };
        defer stmt.finalize();
        stmt.bindText(1, id) catch |err| {
            debug_log.log("SessionManager.getEventCount: bind failed id={s} error={s}", .{ id, @errorName(err) });
            return err;
        };
        const result = stmt.step() catch |err| {
            debug_log.log("SessionManager.getEventCount: query failed id={s} error={s}", .{ id, @errorName(err) });
            return err;
        };
        if (result == .row) return stmt.columnInt(0);
        return 0;
    }
};

// ── Tests ───────────────────────────────────────────────────────────────

test "SessionManager stores and discovers sessions from nested project cwd" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.makePath(".cog");
    try tmp.dir.makePath("nested/deep");

    const project_root = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(project_root);

    var nested = try tmp.dir.openDir("nested/deep", .{});
    defer nested.close();

    var old_cwd = try std.fs.cwd().openDir(".", .{});
    defer {
        old_cwd.setAsCwd() catch {};
        old_cwd.close();
    }
    try nested.setAsCwd();

    var first = try SessionManager.init(std.testing.allocator);
    const id = try std.testing.allocator.dupe(u8, try first.createSession(.syscall, null));
    defer std.testing.allocator.free(id);
    const db_filename = try std.testing.allocator.dupe(u8, std.fs.path.basename(first.getSession(id).?.db_path));
    defer std.testing.allocator.free(db_filename);
    first.deinit();

    const expected_db_path = try std.fs.path.join(std.testing.allocator, &.{ project_root, ".cog", "observe", db_filename });
    defer std.testing.allocator.free(expected_db_path);
    var db_file = try std.fs.openFileAbsolute(expected_db_path, .{});
    db_file.close();

    var second = try SessionManager.init(std.testing.allocator);
    defer second.deinit();
    const discovered = second.getSession(id) orelse return error.SessionNotDiscovered;
    try std.testing.expectEqualStrings(expected_db_path, discovered.db_path);
    try std.testing.expectError(error.FileNotFound, nested.openDir(".cog", .{}));
}

test "SessionManager discovers persisted sessions after restart" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var old_cwd = try std.fs.cwd().openDir(".", .{});
    defer {
        old_cwd.setAsCwd() catch {};
        old_cwd.close();
    }
    try tmp.dir.makePath(".cog");
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
    try tmp.dir.makePath(".cog");
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
    try tmp.dir.makePath(".cog");
    try tmp.dir.setAsCwd();

    var first = try SessionManager.init(std.testing.allocator);
    _ = try first.createSession(.syscall, null);
    first.deinit();

    const file = try std.fs.cwd().createFile(".cog/observe/corrupt.db", .{});
    try file.writeAll("not sqlite");
    file.close();
    const corrupt_path = try std.fs.cwd().realpathAlloc(std.testing.allocator, ".cog/observe/corrupt.db");
    defer std.testing.allocator.free(corrupt_path);

    var second = try SessionManager.init(std.testing.allocator);
    defer second.deinit();
    try std.testing.expectEqual(@as(usize, 1), second.sessionCount());
    try std.testing.expectEqual(@as(usize, 1), second.corruptDatabasePaths().len);
    try std.testing.expectEqualStrings(corrupt_path, second.corruptDatabasePaths()[0]);
}

test "pruneExpiredSessions deletes only expired finalized databases" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var old_cwd = try std.fs.cwd().openDir(".", .{});
    defer {
        old_cwd.setAsCwd() catch {};
        old_cwd.close();
    }
    try tmp.dir.makePath(".cog");
    try tmp.dir.setAsCwd();

    var mgr = try SessionManager.init(std.testing.allocator);
    defer mgr.deinit();

    const expired_finalized_id = try std.testing.allocator.dupe(u8, try mgr.createSession(.syscall, null));
    defer std.testing.allocator.free(expired_finalized_id);
    const recent_finalized_id = try std.testing.allocator.dupe(u8, try mgr.createSession(.cost, null));
    defer std.testing.allocator.free(recent_finalized_id);
    const active_id = try std.testing.allocator.dupe(u8, try mgr.createSession(.gpu, null));
    defer std.testing.allocator.free(active_id);
    const stopped_id = try std.testing.allocator.dupe(u8, try mgr.createSession(.net, null));
    defer std.testing.allocator.free(stopped_id);
    const error_id = try std.testing.allocator.dupe(u8, try mgr.createSession(.syscall, null));
    defer std.testing.allocator.free(error_id);

    try mgr.finalizeSession(expired_finalized_id);
    try mgr.finalizeSession(recent_finalized_id);
    try mgr.stopSession(stopped_id);
    mgr.getSession(error_id).?.status = .@"error";
    try mgr.getSession(error_id).?.db.exec("UPDATE sessions SET status = 'error', stopped_at = datetime('now', '-40 days')");
    try mgr.getSession(expired_finalized_id).?.db.exec("UPDATE sessions SET stopped_at = datetime('now', '-40 days')");
    try mgr.getSession(stopped_id).?.db.exec("UPDATE sessions SET stopped_at = datetime('now', '-40 days')");
    try mgr.getSession(active_id).?.db.exec("UPDATE sessions SET started_at = datetime('now', '-40 days')");

    const expired_path = try std.testing.allocator.dupe(u8, mgr.getSession(expired_finalized_id).?.db_path);
    defer std.testing.allocator.free(expired_path);

    const pruned = try mgr.pruneExpiredSessions(30);

    try std.testing.expectEqual(@as(usize, 1), pruned);
    try std.testing.expect(mgr.getSession(expired_finalized_id) == null);
    try std.testing.expect(mgr.getSession(recent_finalized_id) != null);
    try std.testing.expect(mgr.getSession(active_id) != null);
    try std.testing.expect(mgr.getSession(stopped_id) != null);
    try std.testing.expect(mgr.getSession(error_id) != null);
    try std.testing.expectError(error.FileNotFound, std.fs.accessAbsolute(expired_path, .{}));
}

test "SessionManager initialization never prunes expired finalized databases" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var old_cwd = try std.fs.cwd().openDir(".", .{});
    defer {
        old_cwd.setAsCwd() catch {};
        old_cwd.close();
    }
    try tmp.dir.makePath(".cog");
    try tmp.dir.setAsCwd();

    var settings_file = try std.fs.cwd().createFile(".cog/settings.json", .{});
    try settings_file.writeAll(
        \\{
        \\  "observe": {
        \\    "retention_days": 0
        \\  }
        \\}
        \\
    );
    settings_file.close();

    var first = try SessionManager.init(std.testing.allocator);
    const id = try std.testing.allocator.dupe(u8, try first.createSession(.syscall, null));
    defer std.testing.allocator.free(id);
    try first.finalizeSession(id);
    try first.getSession(id).?.db.exec("UPDATE sessions SET stopped_at = datetime('now', '-1 day')");
    first.deinit();

    var second = try SessionManager.init(std.testing.allocator);
    defer second.deinit();
    try std.testing.expect(second.getSession(id) != null);
}

test "pruneExpiredSessions propagates database errors" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var old_cwd = try std.fs.cwd().openDir(".", .{});
    defer {
        old_cwd.setAsCwd() catch {};
        old_cwd.close();
    }
    try tmp.dir.makePath(".cog");
    try tmp.dir.setAsCwd();

    var mgr = try SessionManager.init(std.testing.allocator);
    defer mgr.deinit();
    const id = try mgr.createSession(.syscall, null);
    try mgr.finalizeSession(id);
    try mgr.getSession(id).?.db.exec("DROP TABLE sessions");

    try std.testing.expectError(error.SqliteError, mgr.pruneExpiredSessions(30));
}

test "pruneExpiredSessions propagates database deletion errors" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var old_cwd = try std.fs.cwd().openDir(".", .{});
    defer {
        old_cwd.setAsCwd() catch {};
        old_cwd.close();
    }
    try tmp.dir.makePath(".cog");
    try tmp.dir.setAsCwd();

    var mgr = try SessionManager.init(std.testing.allocator);
    defer mgr.deinit();
    const id = try mgr.createSession(.syscall, null);
    try mgr.finalizeSession(id);
    const db_path = try std.testing.allocator.dupe(u8, mgr.getSession(id).?.db_path);
    defer std.testing.allocator.free(db_path);
    try mgr.getSession(id).?.db.exec("UPDATE sessions SET stopped_at = datetime('now', '-40 days')");

    try std.fs.deleteFileAbsolute(db_path);
    try std.fs.makeDirAbsolute(db_path);

    if (mgr.pruneExpiredSessions(30)) |_| {
        return error.ExpectedDeleteError;
    } else |_| {}
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
    try tmp.dir.makePath(".cog");
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
    try tmp.dir.makePath(".cog");
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
    try tmp.dir.makePath(".cog");
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
    try tmp.dir.makePath(".cog");
    tmp.dir.setAsCwd() catch return;

    var mgr = try SessionManager.init(std.testing.allocator);
    defer mgr.deinit();

    _ = try mgr.createSession(.syscall, 100);
    _ = try mgr.createSession(.gpu, 200);

    const sessions = try mgr.listSessions(std.testing.allocator, null);
    defer mgr.freeSessionInfos(std.testing.allocator, sessions);

    try std.testing.expectEqual(@as(usize, 2), sessions.len);
}
