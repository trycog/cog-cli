const std = @import("std");
const json = std.json;
const debug_log = @import("../debug_log.zig");

// Error codes
const INVALID_PARAMS: i32 = -32602;
const METHOD_NOT_FOUND: i32 = -32601;
const INTERNAL_ERROR: i32 = -32603;

// ── Tool Result ─────────────────────────────────────────────────────────

pub const ToolResult = union(enum) {
    ok: []const u8,
    ok_static: []const u8,
    err: ToolError,

    pub const ToolError = struct {
        code: i32,
        message: []const u8,
    };
};

// ── Tool Tier ───────────────────────────────────────────────────────────

pub const ToolTier = enum {
    core,
    extended,

    pub fn isWithin(self: ToolTier, threshold: ToolTier) bool {
        return @intFromEnum(self) <= @intFromEnum(threshold);
    }
};

// ── Tool Definitions ────────────────────────────────────────────────────

pub const ToolDef = struct {
    name: []const u8,
    description: []const u8,
    input_schema: []const u8,
    tier: ToolTier = .extended,
};

pub const tool_definitions = [_]ToolDef{
    // ── Core tier ──
    .{
        .name = "observe_start",
        .description = "Start an observation session. Captures system-level events (syscalls, GPU operations, network flows, or cost data) for a target process. Returns a session ID for querying results.",
        .input_schema =
        \\{"type":"object","properties":{"backend":{"type":"string","enum":["syscall","gpu","net","cost"],"description":"Observation backend to use"},"pid":{"type":"integer","description":"Process ID to observe"},"command":{"type":"string","description":"Command to launch and observe (alternative to pid)"},"filters":{"type":"object","description":"Backend-specific event filters"}},"required":["backend"]}
        ,
        .tier = .core,
    },
    .{
        .name = "observe_stop",
        .description = "Stop an active observation session. Finalizes the investigation database and computes causal chains from captured events.",
        .input_schema =
        \\{"type":"object","properties":{"session_id":{"type":"string","description":"Session ID returned by observe_start"}},"required":["session_id"]}
        ,
        .tier = .core,
    },
    .{
        .name = "observe_events",
        .description = "Query raw events from an observation session. Supports filtering by event type, PID, and time range. Returns events with full metadata.",
        .input_schema =
        \\{"type":"object","properties":{"session_id":{"type":"string","description":"Session ID to query"},"event_type":{"type":"string","description":"Filter by event type (e.g. 'sys_enter', 'cuda_launch')"},"pid":{"type":"integer","description":"Filter by process ID"},"limit":{"type":"integer","description":"Maximum events to return (default: 100)"},"offset":{"type":"integer","description":"Skip first N events"},"time_range":{"type":"object","properties":{"start_ns":{"type":"integer"},"end_ns":{"type":"integer"}},"description":"Filter by timestamp range"}},"required":["session_id"]}
        ,
        .tier = .core,
    },
    .{
        .name = "observe_sessions",
        .description = "List observation sessions. Shows active and completed investigation databases with backend type, status, and event counts.",
        .input_schema =
        \\{"type":"object","properties":{"status":{"type":"string","enum":["capturing","stopped","finalized","error"],"description":"Filter by session status"}}}
        ,
        .tier = .core,
    },
    .{
        .name = "observe_status",
        .description = "Check observation subsystem status. Reports available backends, daemon health, and platform capabilities.",
        .input_schema =
        \\{"type":"object","properties":{}}
        ,
        .tier = .core,
    },
    // ── Extended tier ──
    .{
        .name = "observe_causal_chains",
        .description = "Get pre-computed causal chains from an observation session. Causal chains explain sequences of events that led to performance issues, errors, or notable behavior — in plain language.",
        .input_schema =
        \\{"type":"object","properties":{"session_id":{"type":"string","description":"Session ID to query"},"chain_type":{"type":"string","description":"Filter by chain type (e.g. 'io_blocking', 'error_cascade', 'gpu_stall')"},"event_id":{"type":"integer","description":"Find chains involving a specific event"}},"required":["session_id"]}
        ,
        .tier = .extended,
    },
    .{
        .name = "observe_query",
        .description = "Run a read-only SQL query against an observation session's investigation database. The database contains 'events', 'causal_chains', and 'sessions' tables. Use this for ad-hoc analysis that the structured tools don't cover.",
        .input_schema =
        \\{"type":"object","properties":{"session_id":{"type":"string","description":"Session ID identifying the investigation database"},"sql":{"type":"string","description":"Read-only SQL query (SELECT only)"}},"required":["session_id","sql"]}
        ,
        .tier = .extended,
    },
};

// ── Observe Server ──────────────────────────────────────────────────────

pub const ObserveServer = struct {
    allocator: std.mem.Allocator,
    mutex: std.Thread.Mutex = .{},

    pub fn init(allocator: std.mem.Allocator) ObserveServer {
        return .{
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *ObserveServer) void {
        _ = self;
    }

    pub fn callTool(self: *ObserveServer, allocator: std.mem.Allocator, tool_name: []const u8, tool_args: ?json.Value) !ToolResult {
        debug_log.log("ObserveServer.callTool: acquiring mutex for {s}", .{tool_name});
        self.mutex.lock();
        defer {
            debug_log.log("ObserveServer.callTool: {s} completed", .{tool_name});
            self.mutex.unlock();
            debug_log.log("ObserveServer.callTool: mutex released for {s}", .{tool_name});
        }
        debug_log.log("ObserveServer.callTool: mutex acquired for {s}", .{tool_name});

        if (std.mem.eql(u8, tool_name, "observe_start")) {
            return self.toolStart(allocator, tool_args);
        } else if (std.mem.eql(u8, tool_name, "observe_stop")) {
            return self.toolStop(allocator, tool_args);
        } else if (std.mem.eql(u8, tool_name, "observe_events")) {
            return self.toolEvents(allocator, tool_args);
        } else if (std.mem.eql(u8, tool_name, "observe_sessions")) {
            return self.toolSessions(allocator, tool_args);
        } else if (std.mem.eql(u8, tool_name, "observe_status")) {
            return self.toolStatus(allocator, tool_args);
        } else if (std.mem.eql(u8, tool_name, "observe_causal_chains")) {
            return self.toolCausalChains(allocator, tool_args);
        } else if (std.mem.eql(u8, tool_name, "observe_query")) {
            return self.toolQuery(allocator, tool_args);
        } else {
            debug_log.log("ObserveServer.callTool: unknown tool {s}", .{tool_name});
            return .{ .err = .{ .code = METHOD_NOT_FOUND, .message = "Unknown observe tool" } };
        }
    }

    // ── Tool Handlers ───────────────────────────────────────────────────

    fn toolStart(self: *ObserveServer, allocator: std.mem.Allocator, args: ?json.Value) !ToolResult {
        _ = self;
        debug_log.log("toolStart: entered", .{});
        const a = args orelse return .{ .err = .{ .code = INVALID_PARAMS, .message = "Missing arguments" } };
        if (a != .object) return .{ .err = .{ .code = INVALID_PARAMS, .message = "Arguments must be object" } };

        const backend_val = a.object.get("backend") orelse return .{ .err = .{ .code = INVALID_PARAMS, .message = "Missing required field: backend" } };
        if (backend_val != .string) return .{ .err = .{ .code = INVALID_PARAMS, .message = "backend must be a string" } };

        const backend_name = backend_val.string;
        _ = allocator;

        debug_log.log("toolStart: backend={s}", .{backend_name});

        // Phase 1 stub — backend execution comes in Phase 3
        return .{ .ok_static = "{\"status\":\"not_implemented\",\"message\":\"Observe backends are not yet available. This feature is under development.\"}" };
    }

    fn toolStop(self: *ObserveServer, allocator: std.mem.Allocator, args: ?json.Value) !ToolResult {
        _ = self;
        _ = allocator;
        debug_log.log("toolStop: entered", .{});
        const a = args orelse return .{ .err = .{ .code = INVALID_PARAMS, .message = "Missing arguments" } };
        if (a != .object) return .{ .err = .{ .code = INVALID_PARAMS, .message = "Arguments must be object" } };

        const session_val = a.object.get("session_id") orelse return .{ .err = .{ .code = INVALID_PARAMS, .message = "Missing required field: session_id" } };
        if (session_val != .string) return .{ .err = .{ .code = INVALID_PARAMS, .message = "session_id must be a string" } };

        debug_log.log("toolStop: session_id={s}", .{session_val.string});
        return .{ .ok_static = "{\"status\":\"not_implemented\",\"message\":\"No active observation sessions.\"}" };
    }

    fn toolEvents(self: *ObserveServer, allocator: std.mem.Allocator, args: ?json.Value) !ToolResult {
        _ = self;
        _ = allocator;
        debug_log.log("toolEvents: entered", .{});
        const a = args orelse return .{ .err = .{ .code = INVALID_PARAMS, .message = "Missing arguments" } };
        if (a != .object) return .{ .err = .{ .code = INVALID_PARAMS, .message = "Arguments must be object" } };

        const session_val = a.object.get("session_id") orelse return .{ .err = .{ .code = INVALID_PARAMS, .message = "Missing required field: session_id" } };
        if (session_val != .string) return .{ .err = .{ .code = INVALID_PARAMS, .message = "session_id must be a string" } };

        debug_log.log("toolEvents: session_id={s}", .{session_val.string});
        return .{ .ok_static = "{\"events\":[],\"total\":0}" };
    }

    fn toolSessions(self: *ObserveServer, allocator: std.mem.Allocator, args: ?json.Value) !ToolResult {
        _ = self;
        _ = allocator;
        _ = args;
        debug_log.log("toolSessions: entered", .{});
        return .{ .ok_static = "{\"sessions\":[],\"total\":0}" };
    }

    fn toolStatus(self: *ObserveServer, allocator: std.mem.Allocator, args: ?json.Value) !ToolResult {
        _ = self;
        _ = allocator;
        _ = args;
        debug_log.log("toolStatus: entered", .{});
        return .{ .ok_static = "{\"daemon\":\"not_running\",\"backends\":{\"syscall\":\"not_available\",\"gpu\":\"not_available\",\"net\":\"not_available\",\"cost\":\"not_available\"},\"platform\":\"" ++ @tagName(@import("builtin").os.tag) ++ "\"}" };
    }

    fn toolCausalChains(self: *ObserveServer, allocator: std.mem.Allocator, args: ?json.Value) !ToolResult {
        _ = self;
        _ = allocator;
        debug_log.log("toolCausalChains: entered", .{});
        const a = args orelse return .{ .err = .{ .code = INVALID_PARAMS, .message = "Missing arguments" } };
        if (a != .object) return .{ .err = .{ .code = INVALID_PARAMS, .message = "Arguments must be object" } };

        const session_val = a.object.get("session_id") orelse return .{ .err = .{ .code = INVALID_PARAMS, .message = "Missing required field: session_id" } };
        if (session_val != .string) return .{ .err = .{ .code = INVALID_PARAMS, .message = "session_id must be a string" } };

        debug_log.log("toolCausalChains: session_id={s}", .{session_val.string});
        return .{ .ok_static = "{\"causal_chains\":[],\"total\":0}" };
    }

    fn toolQuery(self: *ObserveServer, allocator: std.mem.Allocator, args: ?json.Value) !ToolResult {
        _ = self;
        _ = allocator;
        debug_log.log("toolQuery: entered", .{});
        const a = args orelse return .{ .err = .{ .code = INVALID_PARAMS, .message = "Missing arguments" } };
        if (a != .object) return .{ .err = .{ .code = INVALID_PARAMS, .message = "Arguments must be object" } };

        const session_val = a.object.get("session_id") orelse return .{ .err = .{ .code = INVALID_PARAMS, .message = "Missing required field: session_id" } };
        if (session_val != .string) return .{ .err = .{ .code = INVALID_PARAMS, .message = "session_id must be a string" } };

        const sql_val = a.object.get("sql") orelse return .{ .err = .{ .code = INVALID_PARAMS, .message = "Missing required field: sql" } };
        if (sql_val != .string) return .{ .err = .{ .code = INVALID_PARAMS, .message = "sql must be a string" } };

        // Validate read-only
        const sql = sql_val.string;
        if (!isReadOnlyQuery(sql)) {
            return .{ .err = .{ .code = INVALID_PARAMS, .message = "Only SELECT queries are allowed. Write operations are not permitted on investigation databases." } };
        }

        debug_log.log("toolQuery: session_id={s} sql_len={d}", .{ session_val.string, sql.len });
        return .{ .ok_static = "{\"columns\":[],\"rows\":[],\"row_count\":0}" };
    }
};

/// Check if a SQL query is read-only (SELECT only).
fn isReadOnlyQuery(sql: []const u8) bool {
    // Skip leading whitespace
    var i: usize = 0;
    while (i < sql.len and (sql[i] == ' ' or sql[i] == '\t' or sql[i] == '\n' or sql[i] == '\r')) : (i += 1) {}
    if (i + 6 > sql.len) return false;

    // Case-insensitive check for "SELECT"
    const prefix = sql[i .. i + 6];
    return (std.ascii.eqlIgnoreCase(prefix, "SELECT") or std.ascii.eqlIgnoreCase(prefix, "EXPLAI"));
}

// ── Tests ───────────────────────────────────────────────────────────────

test "isReadOnlyQuery accepts SELECT" {
    try std.testing.expect(isReadOnlyQuery("SELECT * FROM events"));
    try std.testing.expect(isReadOnlyQuery("  SELECT count(*) FROM events"));
    try std.testing.expect(isReadOnlyQuery("select id from sessions"));
    try std.testing.expect(isReadOnlyQuery("EXPLAIN SELECT * FROM events"));
}

test "isReadOnlyQuery rejects writes" {
    try std.testing.expect(!isReadOnlyQuery("INSERT INTO events VALUES (1)"));
    try std.testing.expect(!isReadOnlyQuery("UPDATE events SET pid = 1"));
    try std.testing.expect(!isReadOnlyQuery("DELETE FROM events"));
    try std.testing.expect(!isReadOnlyQuery("DROP TABLE events"));
    try std.testing.expect(!isReadOnlyQuery("ALTER TABLE events ADD COLUMN x"));
    try std.testing.expect(!isReadOnlyQuery(""));
}

test "callTool dispatches known tools" {
    var server = ObserveServer.init(std.testing.allocator);
    defer server.deinit();

    // observe_status requires no arguments
    const result = try server.callTool(std.testing.allocator, "observe_status", null);
    switch (result) {
        .ok_static => |payload| {
            try std.testing.expect(std.mem.indexOf(u8, payload, "daemon") != null);
        },
        else => return error.UnexpectedResult,
    }
}

test "callTool returns error for unknown tool" {
    var server = ObserveServer.init(std.testing.allocator);
    defer server.deinit();

    const result = try server.callTool(std.testing.allocator, "observe_nonexistent", null);
    switch (result) {
        .err => |e| {
            try std.testing.expectEqual(METHOD_NOT_FOUND, e.code);
        },
        else => return error.UnexpectedResult,
    }
}
