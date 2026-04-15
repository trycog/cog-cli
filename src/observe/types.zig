const std = @import("std");

/// Observation backend type.
pub const Backend = enum {
    syscall,
    gpu,
    net,
    cost,

    pub fn toString(self: Backend) []const u8 {
        return switch (self) {
            .syscall => "syscall",
            .gpu => "gpu",
            .net => "net",
            .cost => "cost",
        };
    }

    pub fn fromString(s: []const u8) ?Backend {
        if (std.mem.eql(u8, s, "syscall")) return .syscall;
        if (std.mem.eql(u8, s, "gpu")) return .gpu;
        if (std.mem.eql(u8, s, "net")) return .net;
        if (std.mem.eql(u8, s, "cost")) return .cost;
        return null;
    }
};

/// Status of an observation session.
pub const SessionStatus = enum {
    capturing,
    stopped,
    finalized,
    @"error",

    pub fn toString(self: SessionStatus) []const u8 {
        return switch (self) {
            .capturing => "capturing",
            .stopped => "stopped",
            .finalized => "finalized",
            .@"error" => "error",
        };
    }

    pub fn fromString(s: []const u8) ?SessionStatus {
        if (std.mem.eql(u8, s, "capturing")) return .capturing;
        if (std.mem.eql(u8, s, "stopped")) return .stopped;
        if (std.mem.eql(u8, s, "finalized")) return .finalized;
        if (std.mem.eql(u8, s, "error")) return .@"error";
        return null;
    }
};

/// A raw observation event stored in the investigation database.
pub const Event = struct {
    id: i64,
    session_id: []const u8,
    timestamp_ns: i64,
    event_type: []const u8,
    pid: ?i64,
    tid: ?i64,
    data_json: ?[]const u8,
};

/// A pre-computed causal chain explaining a sequence of events.
pub const CausalChain = struct {
    id: i64,
    session_id: []const u8,
    chain_type: []const u8,
    description: []const u8,
    root_event_id: ?i64,
    event_ids_json: ?[]const u8,
};

/// Metadata for an observation session.
pub const ObserveSession = struct {
    id: []const u8,
    backend: Backend,
    target_pid: ?i64,
    status: SessionStatus,
    db_path: []const u8,
    started_at: []const u8,
    stopped_at: ?[]const u8,
};

// ── Tests ───────────────────────────────────────────────────────────────

test "Backend round-trip" {
    const backends = [_]Backend{ .syscall, .gpu, .net, .cost };
    for (backends) |b| {
        const s = b.toString();
        const parsed = Backend.fromString(s);
        try std.testing.expectEqual(b, parsed.?);
    }
    try std.testing.expect(Backend.fromString("unknown") == null);
}

test "SessionStatus round-trip" {
    const statuses = [_]SessionStatus{ .capturing, .stopped, .finalized, .@"error" };
    for (statuses) |s| {
        const str = s.toString();
        const parsed = SessionStatus.fromString(str);
        try std.testing.expectEqual(s, parsed.?);
    }
    try std.testing.expect(SessionStatus.fromString("unknown") == null);
}
