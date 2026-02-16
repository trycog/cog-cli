const std = @import("std");
const driver_mod = @import("driver.zig");
const ActiveDriver = driver_mod.ActiveDriver;

pub const Session = struct {
    id: []const u8,
    driver: ActiveDriver,
    status: Status,

    pub const Status = enum {
        launching,
        running,
        stopped,
        terminated,
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
            entry.value_ptr.driver.deinit();
            self.allocator.free(entry.key_ptr.*);
        }
        self.sessions.deinit();
    }

    pub fn createSession(self: *SessionManager, driver: ActiveDriver) ![]const u8 {
        const id_num = self.next_id;
        self.next_id += 1;

        const id = try std.fmt.allocPrint(self.allocator, "session-{d}", .{id_num});
        errdefer self.allocator.free(id);

        try self.sessions.put(id, .{
            .id = id,
            .driver = driver,
            .status = .launching,
        });

        return id;
    }

    pub fn getSession(self: *SessionManager, id: []const u8) ?*Session {
        return self.sessions.getPtr(id);
    }

    pub fn destroySession(self: *SessionManager, id: []const u8) bool {
        if (self.sessions.fetchRemove(id)) |kv| {
            var session = kv.value;
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

    const id1 = try mgr.createSession(mock1.activeDriver());
    const id2 = try mgr.createSession(mock2.activeDriver());

    try std.testing.expectEqualStrings("session-1", id1);
    try std.testing.expectEqualStrings("session-2", id2);
}

test "SessionManager retrieves session by ID" {
    const allocator = std.testing.allocator;
    var mgr = SessionManager.init(allocator);
    defer mgr.deinit();

    var mock = driver_mod.MockDriver{};
    const id = try mgr.createSession(mock.activeDriver());

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
    const id = try mgr.createSession(mock.activeDriver());

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
        ids[i] = try mgr.createSession(m.activeDriver());
    }

    try std.testing.expectEqual(@as(usize, 5), mgr.sessionCount());

    for (ids) |id| {
        try std.testing.expect(mgr.getSession(id) != null);
    }
}
