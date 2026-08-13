const std = @import("std");
const posix = std.posix;
const driver_mod = @import("driver.zig");
const types = @import("types.zig");
const ActiveDriver = driver_mod.ActiveDriver;
const debug_log = @import("../debug_log.zig");

pub const Session = struct {
    id: []const u8,
    driver: ActiveDriver,
    status: Status,
    owner_pid: ?posix.pid_t = null,
    orphan_action: OrphanAction = .none,
    last_activity: i64 = 0,
    pending_run: ?*PendingRun = null,

    pub const Status = enum {
        launching,
        running,
        stopped,
        ending,
        terminated,
    };

    /// Heap-owned execution state shared by the session lifecycle owner and an
    /// optional synchronous waiter. The stable pointer is published before the
    /// worker starts, and exactly one caller claims the thread join.
    pub const PendingRun = struct {
        thread: ?std.Thread = null,
        /// 0 = running, 1 = completed, 2 = error
        result: std.atomic.Value(u8) = .init(0),
        stop_state: ?types.StopState = null,
        error_msg: ?[]const u8 = null,
        session_id: []const u8,
        action_name: []const u8,
        allocator: std.mem.Allocator,
        references: std.atomic.Value(usize) = .init(1),
        joined: std.atomic.Value(bool) = .init(false),
        waiter_owns_completion: std.atomic.Value(bool) = .init(false),

        pub fn create(allocator: std.mem.Allocator, session_id: []const u8, action_name: []const u8) !*PendingRun {
            debug_log.log("PendingRun.create: session_id={s} action={s}", .{ session_id, action_name });
            const self = try allocator.create(PendingRun);
            errdefer allocator.destroy(self);

            const owned_session_id = try allocator.dupe(u8, session_id);
            errdefer allocator.free(owned_session_id);
            const owned_action_name = try allocator.dupe(u8, action_name);

            self.* = .{
                .session_id = owned_session_id,
                .action_name = owned_action_name,
                .allocator = allocator,
            };
            return self;
        }

        pub fn retain(self: *PendingRun) void {
            _ = self.references.fetchAdd(1, .monotonic);
        }

        pub fn join(self: *PendingRun) void {
            if (self.joined.swap(true, .acq_rel)) return;
            debug_log.log("PendingRun.join: session_id={s} action={s}", .{ self.session_id, self.action_name });
            if (self.thread) |thread| thread.join();
        }

        pub fn release(self: *PendingRun) void {
            if (self.references.fetchSub(1, .release) != 1) return;
            _ = self.references.load(.acquire);
            std.debug.assert(self.thread == null or self.joined.load(.acquire));
            if (self.stop_state) |*state| state.deinit(self.allocator);
            self.allocator.free(self.session_id);
            self.allocator.free(self.action_name);
            self.allocator.destroy(self);
        }
    };

    pub const OrphanAction = enum {
        none,
        terminate,
        detach,
    };
};

pub const SessionManager = struct {
    sessions: std.StringHashMap(*Session),
    next_id: u64 = 1,
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
            if (session.pending_run) |run| {
                var driver = session.driver;
                debug_log.log("SessionManager.deinit: interrupting active run session_id={s}", .{session.id});
                driver.interruptRun();
                run.join();
                run.release();
                session.pending_run = null;
            }
            session.driver.deinit();
            self.allocator.free(entry.key_ptr.*);
            self.allocator.destroy(session);
        }
        self.sessions.deinit();
    }

    pub fn createSession(self: *SessionManager, driver: ActiveDriver, owner_pid: ?posix.pid_t, orphan_action: Session.OrphanAction) ![]const u8 {
        const id_num = self.next_id;
        self.next_id += 1;

        const id = try std.fmt.allocPrint(self.allocator, "session-{d}", .{id_num});
        errdefer self.allocator.free(id);

        const session = try self.allocator.create(Session);
        session.* = .{
            .id = id,
            .driver = driver,
            .status = .launching,
            .owner_pid = owner_pid,
            .orphan_action = orphan_action,
            .last_activity = std.time.milliTimestamp(),
        };
        errdefer self.allocator.destroy(session);

        try self.sessions.put(id, session);

        return id;
    }

    pub fn getSession(self: *SessionManager, id: []const u8) ?*Session {
        const session = self.sessions.get(id) orelse return null;
        session.last_activity = std.time.milliTimestamp();
        return session;
    }

    pub const RemovedSession = struct {
        key: []const u8,
        session: *Session,
    };

    pub fn removeSession(self: *SessionManager, id: []const u8) ?RemovedSession {
        const kv = self.sessions.fetchRemove(id) orelse return null;
        return .{ .key = kv.key, .session = kv.value };
    }

    pub fn destroyRemovedSession(self: *SessionManager, removed: RemovedSession) void {
        const session = removed.session;
        if (session.pending_run) |run| {
            var driver = session.driver;
            debug_log.log("SessionManager.destroyRemovedSession: interrupting active run session_id={s}", .{session.id});
            driver.interruptRun();
            run.join();
            run.release();
            session.pending_run = null;
        }
        session.driver.deinit();
        self.allocator.free(removed.key);
        self.allocator.destroy(session);
    }

    pub fn destroySession(self: *SessionManager, id: []const u8) bool {
        const removed = self.removeSession(id) orelse return false;
        self.destroyRemovedSession(removed);
        return true;
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
            const session = entry.value_ptr.*;
            try result.append(allocator, .{
                .id = entry.key_ptr.*,
                .status = session.status,
                .driver_type = session.driver.driver_type,
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
        if (std.mem.eql(u8, entry.key_ptr.*, id)) break entry.value_ptr.*;
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
            if (std.mem.eql(u8, entry.key_ptr.*, id)) break entry.value_ptr.*.last_activity;
        } else 0;
    };

    // Small sleep so the clock advances
    std.Thread.sleep(2 * std.time.ns_per_ms);

    // getSession should update last_activity
    const session = mgr.getSession(id);
    try std.testing.expect(session != null);
    try std.testing.expect(session.?.last_activity > initial_ts);
}
