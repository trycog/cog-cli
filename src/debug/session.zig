const std = @import("std");
const posix = std.posix;
const driver_mod = @import("driver.zig");
const types = @import("types.zig");
const ActiveDriver = driver_mod.ActiveDriver;

pub const Session = struct {
    id: []const u8,
    driver: ActiveDriver,
    status: Status,
    owner_pid: ?posix.pid_t = null,
    orphan_action: OrphanAction = .none,
    last_activity: i64 = 0,
    pending_run: ?PendingRun = null,

    pub const Status = enum {
        launching,
        running,
        stopped,
        terminated,
    };

    /// Tracks a background execution control operation (continue, step, etc.).
    /// The background thread writes stop_state/error_msg then does
    /// result.store(.release). The main thread checks result.load(.acquire)
    /// before reading fields — release/acquire ordering guarantees visibility.
    pub const PendingRun = struct {
        thread: std.Thread,
        /// 0 = running, 1 = completed, 2 = error
        result: std.atomic.Value(u8) = .init(0),
        stop_state: ?types.StopState = null,
        error_msg: ?[]const u8 = null,
        session_id: []const u8 = "",
        action_name: []const u8 = "",
        allocator: ?std.mem.Allocator = null,

        /// Free owned copies of session_id and action_name.
        pub fn deinit(self: *PendingRun) void {
            if (self.allocator) |a| {
                if (self.session_id.len > 0) a.free(self.session_id);
                if (self.action_name.len > 0) a.free(self.action_name);
            }
        }
    };

    pub const OrphanAction = enum {
        none,
        terminate,
        detach,
    };
};

pub const SessionManager = struct {
    sessions: std.StringHashMap(Session),
    next_id: u64 = 1,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) SessionManager {
        return .{
            .sessions = std.StringHashMap(Session).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *SessionManager) void {
        var iter = self.sessions.iterator();
        while (iter.next()) |entry| {
            // Join any pending background run thread before destroying
            if (entry.value_ptr.pending_run) |*pr| {
                pr.thread.join();
                pr.deinit();
                entry.value_ptr.pending_run = null;
            }
            entry.value_ptr.driver.deinit();
            self.allocator.free(entry.key_ptr.*);
        }
        self.sessions.deinit();
    }

    pub fn createSession(self: *SessionManager, driver: ActiveDriver, owner_pid: ?posix.pid_t, orphan_action: Session.OrphanAction) ![]const u8 {
        const id_num = self.next_id;
        self.next_id += 1;

        const id = try std.fmt.allocPrint(self.allocator, "session-{d}", .{id_num});
        errdefer self.allocator.free(id);

        try self.sessions.put(id, .{
            .id = id,
            .driver = driver,
            .status = .launching,
            .owner_pid = owner_pid,
            .orphan_action = orphan_action,
            .last_activity = std.time.milliTimestamp(),
        });

        return id;
    }

    pub fn getSession(self: *SessionManager, id: []const u8) ?*Session {
        const session = self.sessions.getPtr(id) orelse return null;
        session.last_activity = std.time.milliTimestamp();
        return session;
    }

    pub fn destroySession(self: *SessionManager, id: []const u8) bool {
        if (self.sessions.fetchRemove(id)) |kv| {
            var session = kv.value;
            // Join any pending background run thread before destroying
            if (session.pending_run) |*pr| {
                pr.thread.join();
                pr.deinit();
                session.pending_run = null;
            }
            session.driver.deinit();
            self.allocator.free(kv.key);
            return true;
        }
        return false;
    }

    pub fn sessionCount(self: *const SessionManager) usize {
        return self.sessions.count();
    }

    pub const SessionInfo = struct {
        id: []const u8,
        status: Session.Status,
        driver_type: ActiveDriver.DriverType,
    };

    pub fn listSessions(self: *const SessionManager, allocator: std.mem.Allocator) ![]const SessionInfo {
        var result = std.ArrayListUnmanaged(SessionInfo).empty;
        errdefer result.deinit(allocator);

        var iter = self.sessions.iterator();
        while (iter.next()) |entry| {
            try result.append(allocator, .{
                .id = entry.key_ptr.*,
                .status = entry.value_ptr.status,
                .driver_type = entry.value_ptr.driver.driver_type,
            });
        }
        return try result.toOwnedSlice(allocator);
    }
};

// ── Tests ───────────────────────────────────────────────────────────────

test "SessionManager creates session with incrementing IDs" {
    const allocator = std.testing.allocator;
    var mgr = SessionManager.init(allocator);
    defer mgr.deinit();

    var mock1 = driver_mod.MockDriver{};
    var mock2 = driver_mod.MockDriver{};

    const id1 = try mgr.createSession(mock1.activeDriver(), null, .none);
    const id2 = try mgr.createSession(mock2.activeDriver(), null, .none);

    try std.testing.expectEqualStrings("session-1", id1);
    try std.testing.expectEqualStrings("session-2", id2);
}

test "SessionManager retrieves session by ID" {
    const allocator = std.testing.allocator;
    var mgr = SessionManager.init(allocator);
    defer mgr.deinit();

    var mock = driver_mod.MockDriver{};
    const id = try mgr.createSession(mock.activeDriver(), null, .none);

    const session = mgr.getSession(id);
    try std.testing.expect(session != null);
    try std.testing.expectEqualStrings(id, session.?.id);
    try std.testing.expectEqual(Session.Status.launching, session.?.status);
}

test "SessionManager returns null for unknown session" {
    const allocator = std.testing.allocator;
    var mgr = SessionManager.init(allocator);
    defer mgr.deinit();

    try std.testing.expect(mgr.getSession("nonexistent") == null);
}

test "SessionManager destroys session and frees resources" {
    const allocator = std.testing.allocator;
    var mgr = SessionManager.init(allocator);
    defer mgr.deinit();

    var mock = driver_mod.MockDriver{};
    const id = try mgr.createSession(mock.activeDriver(), null, .none);

    // Copy the id since it will be freed
    const id_copy = try allocator.dupe(u8, id);
    defer allocator.free(id_copy);

    try std.testing.expect(mgr.destroySession(id_copy));
    try std.testing.expect(mgr.getSession(id_copy) == null);
    try std.testing.expectEqual(@as(usize, 0), mgr.sessionCount());
}

test "SessionManager handles multiple concurrent sessions" {
    const allocator = std.testing.allocator;
    var mgr = SessionManager.init(allocator);
    defer mgr.deinit();

    var mocks: [5]driver_mod.MockDriver = [_]driver_mod.MockDriver{.{}} ** 5;
    var ids: [5][]const u8 = undefined;

    for (&mocks, 0..) |*m, i| {
        ids[i] = try mgr.createSession(m.activeDriver(), null, .none);
    }

    try std.testing.expectEqual(@as(usize, 5), mgr.sessionCount());

    for (ids) |id| {
        try std.testing.expect(mgr.getSession(id) != null);
    }
}

test "createSession initializes last_activity to recent timestamp" {
    const allocator = std.testing.allocator;
    var mgr = SessionManager.init(allocator);
    defer mgr.deinit();

    const before = std.time.milliTimestamp();
    var mock = driver_mod.MockDriver{};
    const id = try mgr.createSession(mock.activeDriver(), null, .none);
    const after = std.time.milliTimestamp();

    // Access via iterator to avoid getSession updating the timestamp
    var iter = mgr.sessions.iterator();
    const session = while (iter.next()) |entry| {
        if (std.mem.eql(u8, entry.key_ptr.*, id)) break entry.value_ptr;
    } else null;

    try std.testing.expect(session != null);
    try std.testing.expect(session.?.last_activity >= before);
    try std.testing.expect(session.?.last_activity <= after);
}

test "getSession updates last_activity" {
    const allocator = std.testing.allocator;
    var mgr = SessionManager.init(allocator);
    defer mgr.deinit();

    var mock = driver_mod.MockDriver{};
    const id = try mgr.createSession(mock.activeDriver(), null, .none);

    // Read initial timestamp via iterator (bypasses getSession)
    const initial_ts = blk: {
        var iter = mgr.sessions.iterator();
        break :blk while (iter.next()) |entry| {
            if (std.mem.eql(u8, entry.key_ptr.*, id)) break entry.value_ptr.last_activity;
        } else 0;
    };

    // Small sleep so the clock advances
    std.Thread.sleep(2 * std.time.ns_per_ms);

    // getSession should update last_activity
    const session = mgr.getSession(id);
    try std.testing.expect(session != null);
    try std.testing.expect(session.?.last_activity > initial_ts);
}
