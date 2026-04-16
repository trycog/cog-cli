const std = @import("std");
const sqlite = @import("../sqlite.zig");
const schema = @import("schema.zig");
const types = @import("types.zig");
const debug_log = @import("../debug_log.zig");
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
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) SessionManager {
        return .{
            .sessions = std.StringHashMap(*Session).init(allocator),
            .allocator = allocator,
        };
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
        var stmt = session.db.prepare("UPDATE sessions SET status = 'stopped', stopped_at = datetime('now') WHERE id = ?") catch return;
        defer stmt.finalize();
        stmt.bindText(1, id) catch return;
        _ = stmt.step() catch return;
    }

    /// Finalize a session: mark as finalized and close.
    pub fn finalizeSession(self: *SessionManager, id: []const u8) !void {
        const session = self.sessions.get(id) orelse return error.SessionNotFound;
        debug_log.log("SessionManager.finalizeSession: id={s}", .{id});

        // Update status in the database
        {
            var stmt = session.db.prepare("UPDATE sessions SET status = 'finalized', stopped_at = datetime('now') WHERE id = ?") catch return;
            defer stmt.finalize();
            stmt.bindText(1, id) catch return;
            _ = stmt.step() catch return;
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

    /// Summary info for listing sessions.
    pub const SessionInfo = struct {
        id: []const u8,
        backend: types.Backend,
        status: types.SessionStatus,
        target_pid: ?i64,
    };

    /// List all active sessions.
    pub fn listSessions(self: *const SessionManager, allocator: std.mem.Allocator) ![]const SessionInfo {
        var result = std.ArrayListUnmanaged(SessionInfo).empty;
        var iter = self.sessions.iterator();
        while (iter.next()) |entry| {
            const session = entry.value_ptr.*;
            try result.append(allocator, .{
                .id = session.id,
                .backend = session.backend,
                .status = session.status,
                .target_pid = session.target_pid,
            });
        }
        return result.toOwnedSlice(allocator);
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

    var mgr = SessionManager.init(std.testing.allocator);
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

    var mgr = SessionManager.init(std.testing.allocator);
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

    var mgr = SessionManager.init(std.testing.allocator);
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

    var mgr = SessionManager.init(std.testing.allocator);
    defer mgr.deinit();

    _ = try mgr.createSession(.syscall, 100);
    _ = try mgr.createSession(.gpu, 200);

    const sessions = try mgr.listSessions(std.testing.allocator);
    defer std.testing.allocator.free(sessions);

    try std.testing.expectEqual(@as(usize, 2), sessions.len);
}
