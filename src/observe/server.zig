const std = @import("std");
const json = std.json;
const debug_log = @import("../debug_log.zig");
const session_mod = @import("session.zig");
const types = @import("types.zig");
const Stringify = json.Stringify;
const Writer = std.io.Writer;

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

// ── Tool Definitions ────────────────────────────────────────────────────

pub const ToolDef = struct {
    name: []const u8,
    description: []const u8,
    input_schema: []const u8,
};

pub const tool_definitions = [_]ToolDef{
    .{
        .name = "observe_start",
        .description = "Start an observation session. Captures system-level events (syscalls, GPU operations, network flows, or cost data) for a target process. Returns a session ID for querying results.",
        .input_schema =
        \\{"type":"object","properties":{"backend":{"type":"string","enum":["syscall","gpu","net","cost"],"description":"Observation backend to use"},"pid":{"type":"integer","description":"Process ID to observe"},"command":{"type":"string","description":"Command to launch and observe (alternative to pid)"},"filters":{"type":"object","description":"Backend-specific event filters"}},"required":["backend"]}
        ,
    },
    .{
        .name = "observe_stop",
        .description = "Stop an active observation session. Finalizes the investigation database and computes causal chains from captured events.",
        .input_schema =
        \\{"type":"object","properties":{"session_id":{"type":"string","description":"Session ID returned by observe_start"}},"required":["session_id"]}
        ,
    },
    .{
        .name = "observe_events",
        .description = "Query raw events from an observation session. Supports filtering by event type, PID, and time range. Returns events with full metadata.",
        .input_schema =
        \\{"type":"object","properties":{"session_id":{"type":"string","description":"Session ID to query"},"event_type":{"type":"string","description":"Filter by event type (e.g. 'sys_enter', 'cuda_launch')"},"pid":{"type":"integer","description":"Filter by process ID"},"limit":{"type":"integer","description":"Maximum events to return (default: 100)"},"offset":{"type":"integer","description":"Skip first N events"},"time_range":{"type":"object","properties":{"start_ns":{"type":"integer"},"end_ns":{"type":"integer"}},"description":"Filter by timestamp range"}},"required":["session_id"]}
        ,
    },
    .{
        .name = "observe_sessions",
        .description = "List observation sessions. Shows active and completed investigation databases with backend type, status, and event counts.",
        .input_schema =
        \\{"type":"object","properties":{"status":{"type":"string","enum":["capturing","stopped","finalized","error"],"description":"Filter by session status"}}}
        ,
    },
    .{
        .name = "observe_status",
        .description = "Check observation subsystem status. Reports available backends, active sessions, and platform capabilities.",
        .input_schema =
        \\{"type":"object","properties":{}}
        ,
    },
    .{
        .name = "observe_causal_chains",
        .description = "Get pre-computed causal chains from an observation session. Causal chains explain sequences of events that led to performance issues, errors, or notable behavior — in plain language.",
        .input_schema =
        \\{"type":"object","properties":{"session_id":{"type":"string","description":"Session ID to query"},"chain_type":{"type":"string","description":"Filter by chain type (e.g. 'io_blocking', 'error_cascade', 'gpu_stall')"},"event_id":{"type":"integer","description":"Find chains involving a specific event"}},"required":["session_id"]}
        ,
    },
    .{
        .name = "observe_query",
        .description = "Run a read-only SQL query against an observation session's investigation database. The database contains 'events', 'causal_chains', and 'sessions' tables. Use this for ad-hoc analysis that the structured tools don't cover.",
        .input_schema =
        \\{"type":"object","properties":{"session_id":{"type":"string","description":"Session ID identifying the investigation database"},"sql":{"type":"string","description":"Read-only SQL query (SELECT only)"}},"required":["session_id","sql"]}
        ,
    },
};

// ── Observe Server ──────────────────────────────────────────────────────

pub const ObserveServer = struct {
    allocator: std.mem.Allocator,
    session_manager: session_mod.SessionManager,
    mutex: std.Thread.Mutex = .{},

    pub fn init(allocator: std.mem.Allocator) !ObserveServer {
        return .{
            .allocator = allocator,
            .session_manager = try session_mod.SessionManager.init(allocator),
        };
    }

    pub fn deinit(self: *ObserveServer) void {
        self.session_manager.deinit();
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
        debug_log.log("toolStart: entered", .{});
        const a = args orelse return .{ .err = .{ .code = INVALID_PARAMS, .message = "Missing arguments" } };
        if (a != .object) return .{ .err = .{ .code = INVALID_PARAMS, .message = "Arguments must be object" } };

        const backend_val = a.object.get("backend") orelse return .{ .err = .{ .code = INVALID_PARAMS, .message = "Missing required field: backend" } };
        if (backend_val != .string) return .{ .err = .{ .code = INVALID_PARAMS, .message = "backend must be a string" } };

        const backend = types.Backend.fromString(backend_val.string) orelse {
            return .{ .err = .{ .code = INVALID_PARAMS, .message = "Invalid backend. Must be one of: syscall, gpu, net, cost" } };
        };

        if (!backend.isImplemented()) {
            debug_log.log("toolStart: rejecting unavailable backend={s} reason={s}", .{ backend.toString(), backend.unavailableReason() });
            return .{ .err = .{ .code = INVALID_PARAMS, .message = backend.unavailableReason() } };
        }

        const target_pid: ?i64 = if (a.object.get("pid")) |v| (if (v == .integer) v.integer else null) else null;

        debug_log.log("toolStart: backend={s} pid={?d}", .{ backend.toString(), target_pid });

        const session_id = self.session_manager.createSession(backend, target_pid) catch {
            return .{ .err = .{ .code = INTERNAL_ERROR, .message = "Failed to create observation session" } };
        };

        // TODO: actual backend capture starts here in Phase 3
        debug_log.log("toolStart: session created id={s}", .{session_id});

        return okJson(allocator, .{ .session_id = session_id, .backend = backend.toString(), .status = "capturing", .message = "Observation session started. Backend capture is not yet implemented — session is ready for manual event insertion or future backend integration." });
    }

    fn toolStop(self: *ObserveServer, allocator: std.mem.Allocator, args: ?json.Value) !ToolResult {
        debug_log.log("toolStop: entered", .{});
        const a = args orelse return .{ .err = .{ .code = INVALID_PARAMS, .message = "Missing arguments" } };
        if (a != .object) return .{ .err = .{ .code = INVALID_PARAMS, .message = "Arguments must be object" } };

        const session_val = a.object.get("session_id") orelse return .{ .err = .{ .code = INVALID_PARAMS, .message = "Missing required field: session_id" } };
        if (session_val != .string) return .{ .err = .{ .code = INVALID_PARAMS, .message = "session_id must be a string" } };

        const sid = session_val.string;
        debug_log.log("toolStop: session_id={s}", .{sid});

        self.session_manager.finalizeSession(sid) catch {
            return .{ .err = .{ .code = INVALID_PARAMS, .message = "Session not found" } };
        };

        const event_count = self.session_manager.getEventCount(sid) catch 0;

        return okJson(allocator, .{ .session_id = sid, .status = "finalized", .event_count = event_count });
    }

    fn toolEvents(self: *ObserveServer, allocator: std.mem.Allocator, args: ?json.Value) !ToolResult {
        debug_log.log("toolEvents: entered", .{});
        const a = args orelse return .{ .err = .{ .code = INVALID_PARAMS, .message = "Missing arguments" } };
        if (a != .object) return .{ .err = .{ .code = INVALID_PARAMS, .message = "Arguments must be object" } };

        const session_val = a.object.get("session_id") orelse return .{ .err = .{ .code = INVALID_PARAMS, .message = "Missing required field: session_id" } };
        if (session_val != .string) return .{ .err = .{ .code = INVALID_PARAMS, .message = "session_id must be a string" } };

        const sid = session_val.string;
        debug_log.log("toolEvents: session_id={s}", .{sid});

        const session = self.session_manager.getSession(sid) orelse {
            return .{ .err = .{ .code = INVALID_PARAMS, .message = "Session not found" } };
        };

        const limit = parseBoundedInteger(a.object.get("limit"), 100, 1, 1000) orelse {
            return .{ .err = .{ .code = INVALID_PARAMS, .message = "limit must be an integer between 1 and 1000" } };
        };
        const offset = parseBoundedInteger(a.object.get("offset"), 0, 0, 1_000_000) orelse {
            return .{ .err = .{ .code = INVALID_PARAMS, .message = "offset must be an integer between 0 and 1000000" } };
        };

        var stmt = session.db.prepare("SELECT id, timestamp_ns, event_type, pid, tid, data_json FROM events WHERE session_id = ? ORDER BY timestamp_ns LIMIT ? OFFSET ?") catch {
            return .{ .err = .{ .code = INTERNAL_ERROR, .message = "Failed to query events" } };
        };
        defer stmt.finalize();
        stmt.bindText(1, sid) catch return .{ .err = .{ .code = INTERNAL_ERROR, .message = "Failed to bind query parameters" } };
        stmt.bindInt(2, limit) catch return .{ .err = .{ .code = INTERNAL_ERROR, .message = "Failed to bind query parameters" } };
        stmt.bindInt(3, offset) catch return .{ .err = .{ .code = INTERNAL_ERROR, .message = "Failed to bind query parameters" } };

        var aw: Writer.Allocating = .init(allocator);
        errdefer aw.deinit();
        var jw: Stringify = .{ .writer = &aw.writer };
        var count: usize = 0;

        jw.beginObject() catch return error.OutOfMemory;
        jw.objectField("events") catch return error.OutOfMemory;
        jw.beginArray() catch return error.OutOfMemory;

        while (true) {
            const row = stmt.step() catch {
                debug_log.log("toolEvents: query execution failed", .{});
                return .{ .err = .{ .code = INTERNAL_ERROR, .message = "Failed while reading observation events" } };
            };
            if (row != .row) break;

            jw.beginObject() catch return error.OutOfMemory;
            jw.objectField("id") catch return error.OutOfMemory;
            jw.write(stmt.columnInt(0)) catch return error.OutOfMemory;
            jw.objectField("timestamp_ns") catch return error.OutOfMemory;
            jw.write(stmt.columnInt(1)) catch return error.OutOfMemory;
            jw.objectField("event_type") catch return error.OutOfMemory;
            jw.write(stmt.columnText(2)) catch return error.OutOfMemory;
            if (stmt.columnText(3)) |pid_text| {
                jw.objectField("pid") catch return error.OutOfMemory;
                jw.write(pid_text) catch return error.OutOfMemory;
            }
            if (stmt.columnText(5)) |data| {
                jw.objectField("data") catch return error.OutOfMemory;
                jw.write(data) catch return error.OutOfMemory;
            }
            jw.endObject() catch return error.OutOfMemory;
            count += 1;
        }

        jw.endArray() catch return error.OutOfMemory;
        jw.objectField("count") catch return error.OutOfMemory;
        jw.write(count) catch return error.OutOfMemory;
        jw.endObject() catch return error.OutOfMemory;

        return .{ .ok = try aw.toOwnedSlice() };
    }

    fn toolSessions(self: *ObserveServer, allocator: std.mem.Allocator, args: ?json.Value) !ToolResult {
        debug_log.log("toolSessions: entered", .{});

        var status_filter: ?types.SessionStatus = null;
        if (args) |a| {
            if (a != .object) return .{ .err = .{ .code = INVALID_PARAMS, .message = "Arguments must be object" } };
            if (a.object.get("status")) |status_value| {
                if (status_value != .string) return .{ .err = .{ .code = INVALID_PARAMS, .message = "status must be a string" } };
                status_filter = types.SessionStatus.fromString(status_value.string) orelse {
                    return .{ .err = .{ .code = INVALID_PARAMS, .message = "Invalid status. Must be one of: capturing, stopped, finalized, error" } };
                };
            }
        }

        const sessions = self.session_manager.listSessions(allocator, status_filter) catch {
            return .{ .err = .{ .code = INTERNAL_ERROR, .message = "Failed to list observation sessions; one or more databases may be corrupt" } };
        };
        defer self.session_manager.freeSessionInfos(allocator, sessions);

        var aw: Writer.Allocating = .init(allocator);
        errdefer aw.deinit();
        var jw: Stringify = .{ .writer = &aw.writer };

        jw.beginObject() catch return error.OutOfMemory;
        jw.objectField("sessions") catch return error.OutOfMemory;
        jw.beginArray() catch return error.OutOfMemory;

        for (sessions) |s| {
            jw.beginObject() catch return error.OutOfMemory;
            jw.objectField("id") catch return error.OutOfMemory;
            jw.write(s.id) catch return error.OutOfMemory;
            jw.objectField("backend") catch return error.OutOfMemory;
            jw.write(s.backend.toString()) catch return error.OutOfMemory;
            jw.objectField("status") catch return error.OutOfMemory;
            jw.write(s.status.toString()) catch return error.OutOfMemory;
            if (s.target_pid) |pid| {
                jw.objectField("pid") catch return error.OutOfMemory;
                jw.write(pid) catch return error.OutOfMemory;
            }
            jw.objectField("event_count") catch return error.OutOfMemory;
            jw.write(s.event_count) catch return error.OutOfMemory;
            jw.endObject() catch return error.OutOfMemory;
        }

        jw.endArray() catch return error.OutOfMemory;
        jw.objectField("total") catch return error.OutOfMemory;
        jw.write(sessions.len) catch return error.OutOfMemory;
        jw.objectField("corrupt_databases") catch return error.OutOfMemory;
        jw.beginArray() catch return error.OutOfMemory;
        for (self.session_manager.corruptDatabasePaths()) |path| {
            jw.beginObject() catch return error.OutOfMemory;
            jw.objectField("path") catch return error.OutOfMemory;
            jw.write(path) catch return error.OutOfMemory;
            jw.objectField("reason") catch return error.OutOfMemory;
            jw.write("database could not be opened or did not contain one valid observation session") catch return error.OutOfMemory;
            jw.endObject() catch return error.OutOfMemory;
        }
        jw.endArray() catch return error.OutOfMemory;
        jw.endObject() catch return error.OutOfMemory;

        return .{ .ok = try aw.toOwnedSlice() };
    }

    fn toolStatus(self: *ObserveServer, allocator: std.mem.Allocator, args: ?json.Value) !ToolResult {
        _ = args;
        debug_log.log("toolStatus: entered", .{});

        const count = self.session_manager.sessionCount();

        return okJson(allocator, .{
            .active_sessions = count,
            .corrupt_database_count = self.session_manager.corruptDatabasePaths().len,
            .backends = .{
                .syscall = .{ .available = types.Backend.syscall.isImplemented(), .reason = types.Backend.syscall.unavailableReason() },
                .gpu = .{ .available = types.Backend.gpu.isImplemented(), .reason = types.Backend.gpu.unavailableReason() },
                .net = .{ .available = types.Backend.net.isImplemented(), .reason = types.Backend.net.unavailableReason() },
                .cost = .{ .available = types.Backend.cost.isImplemented(), .reason = types.Backend.cost.unavailableReason() },
            },
            .platform = @tagName(@import("builtin").os.tag),
        });
    }

    fn toolCausalChains(self: *ObserveServer, allocator: std.mem.Allocator, args: ?json.Value) !ToolResult {
        debug_log.log("toolCausalChains: entered", .{});
        const a = args orelse return .{ .err = .{ .code = INVALID_PARAMS, .message = "Missing arguments" } };
        if (a != .object) return .{ .err = .{ .code = INVALID_PARAMS, .message = "Arguments must be object" } };

        const session_val = a.object.get("session_id") orelse return .{ .err = .{ .code = INVALID_PARAMS, .message = "Missing required field: session_id" } };
        if (session_val != .string) return .{ .err = .{ .code = INVALID_PARAMS, .message = "session_id must be a string" } };

        const sid = session_val.string;
        debug_log.log("toolCausalChains: session_id={s}", .{sid});

        const session = self.session_manager.getSession(sid) orelse {
            return .{ .err = .{ .code = INVALID_PARAMS, .message = "Session not found" } };
        };

        var stmt = session.db.prepare("SELECT id, chain_type, description, root_event_id, event_ids_json FROM causal_chains WHERE session_id = ? ORDER BY id") catch {
            return .{ .err = .{ .code = INTERNAL_ERROR, .message = "Failed to query causal chains" } };
        };
        defer stmt.finalize();
        stmt.bindText(1, sid) catch return .{ .err = .{ .code = INTERNAL_ERROR, .message = "Failed to bind query parameters" } };

        var aw: Writer.Allocating = .init(allocator);
        errdefer aw.deinit();
        var jw: Stringify = .{ .writer = &aw.writer };
        var count: usize = 0;

        jw.beginObject() catch return error.OutOfMemory;
        jw.objectField("causal_chains") catch return error.OutOfMemory;
        jw.beginArray() catch return error.OutOfMemory;

        while (true) {
            const row = stmt.step() catch {
                debug_log.log("toolCausalChains: query execution failed", .{});
                return .{ .err = .{ .code = INTERNAL_ERROR, .message = "Failed while reading causal chains" } };
            };
            if (row != .row) break;

            jw.beginObject() catch return error.OutOfMemory;
            jw.objectField("id") catch return error.OutOfMemory;
            jw.write(stmt.columnInt(0)) catch return error.OutOfMemory;
            jw.objectField("chain_type") catch return error.OutOfMemory;
            jw.write(stmt.columnText(1)) catch return error.OutOfMemory;
            jw.objectField("description") catch return error.OutOfMemory;
            jw.write(stmt.columnText(2)) catch return error.OutOfMemory;
            jw.endObject() catch return error.OutOfMemory;
            count += 1;
        }

        jw.endArray() catch return error.OutOfMemory;
        jw.objectField("count") catch return error.OutOfMemory;
        jw.write(count) catch return error.OutOfMemory;
        jw.endObject() catch return error.OutOfMemory;

        return .{ .ok = try aw.toOwnedSlice() };
    }

    fn toolQuery(self: *ObserveServer, allocator: std.mem.Allocator, args: ?json.Value) !ToolResult {
        debug_log.log("toolQuery: entered", .{});
        const a = args orelse return .{ .err = .{ .code = INVALID_PARAMS, .message = "Missing arguments" } };
        if (a != .object) return .{ .err = .{ .code = INVALID_PARAMS, .message = "Arguments must be object" } };

        const session_val = a.object.get("session_id") orelse return .{ .err = .{ .code = INVALID_PARAMS, .message = "Missing required field: session_id" } };
        if (session_val != .string) return .{ .err = .{ .code = INVALID_PARAMS, .message = "session_id must be a string" } };

        const sql_val = a.object.get("sql") orelse return .{ .err = .{ .code = INVALID_PARAMS, .message = "Missing required field: sql" } };
        if (sql_val != .string) return .{ .err = .{ .code = INVALID_PARAMS, .message = "sql must be a string" } };

        const sql = sql_val.string;
        if (!isReadOnlyQuery(sql)) {
            return .{ .err = .{ .code = INVALID_PARAMS, .message = "Only SELECT queries are allowed. Write operations are not permitted on investigation databases." } };
        }

        const sid = session_val.string;
        debug_log.log("toolQuery: session_id={s} sql_len={d}", .{ sid, sql.len });

        const session = self.session_manager.getSession(sid) orelse {
            return .{ .err = .{ .code = INVALID_PARAMS, .message = "Session not found" } };
        };

        // SQLite prepare requires null-terminated string
        const sql_z = allocator.dupeZ(u8, sql) catch return error.OutOfMemory;
        defer allocator.free(sql_z);

        var stmt = session.db.prepare(sql_z) catch {
            return .{ .err = .{ .code = INVALID_PARAMS, .message = "SQL query failed to prepare — check syntax" } };
        };
        defer stmt.finalize();

        var aw: Writer.Allocating = .init(allocator);
        errdefer aw.deinit();
        var jw: Stringify = .{ .writer = &aw.writer };
        var row_count: usize = 0;
        var result_bytes: usize = 0;

        jw.beginObject() catch return error.OutOfMemory;
        jw.objectField("rows") catch return error.OutOfMemory;
        jw.beginArray() catch return error.OutOfMemory;

        while (true) {
            const row = stmt.step() catch {
                debug_log.log("toolQuery: query execution failed", .{});
                return .{ .err = .{ .code = INVALID_PARAMS, .message = "SQL query failed during execution" } };
            };
            if (row != .row) break;

            // Each row as an array of text values.
            const column_count = stmt.columnCount();
            if (column_count < 0 or column_count > @as(c_int, @intCast(MAX_QUERY_COLUMNS))) {
                debug_log.log("toolQuery: rejecting result column_count={d}", .{column_count});
                return .{ .err = .{ .code = INVALID_PARAMS, .message = "SQL query returns too many columns" } };
            }
            jw.beginArray() catch return error.OutOfMemory;
            const col_count: usize = @intCast(column_count);
            var col: usize = 0;
            while (col < col_count) : (col += 1) {
                const text = stmt.columnText(@intCast(col));
                if (text) |value| {
                    if (value.len > MAX_QUERY_CELL_BYTES or result_bytes > MAX_QUERY_RESULT_BYTES -| value.len) {
                        debug_log.log("toolQuery: rejecting oversized result row={d} column={d}", .{ row_count, col });
                        return .{ .err = .{ .code = INVALID_PARAMS, .message = "SQL query result exceeds output bounds" } };
                    }
                    result_bytes += value.len;
                }
                jw.write(text) catch return error.OutOfMemory;
            }
            jw.endArray() catch return error.OutOfMemory;
            row_count += 1;

            // Safety limit
            if (row_count >= MAX_QUERY_ROWS) break;
        }

        jw.endArray() catch return error.OutOfMemory;
        jw.objectField("row_count") catch return error.OutOfMemory;
        jw.write(row_count) catch return error.OutOfMemory;
        jw.endObject() catch return error.OutOfMemory;

        return .{ .ok = try aw.toOwnedSlice() };
    }
};

// ── Helpers ─────────────────────────────────────────────────────────────

fn okJson(allocator: std.mem.Allocator, value: anytype) !ToolResult {
    var aw: Writer.Allocating = .init(allocator);
    errdefer aw.deinit();
    var jw: Stringify = .{ .writer = &aw.writer };
    jw.write(value) catch return error.OutOfMemory;
    return .{ .ok = try aw.toOwnedSlice() };
}

const MAX_SQL_BYTES: usize = 64 * 1024;
const MAX_QUERY_ROWS: usize = 1000;
const MAX_QUERY_COLUMNS: usize = 256;
const MAX_QUERY_CELL_BYTES: usize = 256 * 1024;
const MAX_QUERY_RESULT_BYTES: usize = 4 * 1024 * 1024;

fn parseBoundedInteger(value: ?json.Value, default_value: i64, min: i64, max: i64) ?i64 {
    const result = if (value) |v| switch (v) {
        .integer => |integer| integer,
        else => return null,
    } else default_value;
    if (result < min or result > max) return null;
    return result;
}

fn isSqlIdentifierByte(byte: u8) bool {
    return std.ascii.isAlphanumeric(byte) or byte == '_';
}

fn isForbiddenSqlToken(token: []const u8) bool {
    const forbidden = [_][]const u8{
        "INSERT", "UPDATE",   "DELETE",    "REPLACE", "CREATE",         "DROP",      "ALTER",
        "ATTACH", "DETACH",   "PRAGMA",    "VACUUM",  "REINDEX",        "ANALYZE",   "BEGIN",
        "COMMIT", "ROLLBACK", "SAVEPOINT", "RELEASE", "LOAD_EXTENSION", "WRITEFILE",
    };
    for (forbidden) |candidate| {
        if (std.ascii.eqlIgnoreCase(token, candidate)) return true;
    }
    return false;
}

/// Validate one bounded, comment-free, read-only SQLite statement.
fn isReadOnlyQuery(sql: []const u8) bool {
    if (sql.len == 0 or sql.len > MAX_SQL_BYTES) return false;

    var first_token: ?[]const u8 = null;
    var second_token: ?[]const u8 = null;
    var third_token: ?[]const u8 = null;
    var fourth_token: ?[]const u8 = null;
    var statement_ended = false;
    var i: usize = 0;

    while (i < sql.len) {
        const byte = sql[i];
        if (byte == 0) return false;
        if (std.ascii.isWhitespace(byte)) {
            i += 1;
            continue;
        }
        if (statement_ended) return false;
        if (byte == '-' and i + 1 < sql.len and sql[i + 1] == '-') return false;
        if (byte == '/' and i + 1 < sql.len and sql[i + 1] == '*') return false;
        if (byte == ';') {
            statement_ended = true;
            i += 1;
            continue;
        }

        if (byte == '\'' or byte == '"' or byte == '`' or byte == '[') {
            const closing: u8 = if (byte == '[') ']' else byte;
            i += 1;
            var closed = false;
            while (i < sql.len) {
                if (sql[i] == 0) return false;
                if (sql[i] == closing) {
                    if (closing != ']' and i + 1 < sql.len and sql[i + 1] == closing) {
                        i += 2;
                        continue;
                    }
                    i += 1;
                    closed = true;
                    break;
                }
                i += 1;
            }
            if (!closed) return false;
            continue;
        }

        if (isSqlIdentifierByte(byte)) {
            const start = i;
            while (i < sql.len and isSqlIdentifierByte(sql[i])) : (i += 1) {}
            const token = sql[start..i];
            if (isForbiddenSqlToken(token)) return false;
            if (first_token == null) {
                first_token = token;
            } else if (second_token == null) {
                second_token = token;
            } else if (third_token == null) {
                third_token = token;
            } else if (fourth_token == null) {
                fourth_token = token;
            }
            continue;
        }

        i += 1;
    }

    const first = first_token orelse return false;
    if (std.ascii.eqlIgnoreCase(first, "SELECT") or std.ascii.eqlIgnoreCase(first, "WITH")) return true;
    if (!std.ascii.eqlIgnoreCase(first, "EXPLAIN")) return false;

    const second = second_token orelse return false;
    if (std.ascii.eqlIgnoreCase(second, "SELECT") or std.ascii.eqlIgnoreCase(second, "WITH")) return true;
    return std.ascii.eqlIgnoreCase(second, "QUERY") and
        third_token != null and
        std.ascii.eqlIgnoreCase(third_token.?, "PLAN") and
        fourth_token != null and
        (std.ascii.eqlIgnoreCase(fourth_token.?, "SELECT") or std.ascii.eqlIgnoreCase(fourth_token.?, "WITH"));
}

// ── Tests ───────────────────────────────────────────────────────────────

test "isReadOnlyQuery accepts one bounded SELECT statement" {
    try std.testing.expect(isReadOnlyQuery("SELECT * FROM events"));
    try std.testing.expect(isReadOnlyQuery("  SELECT count(*) FROM events;  "));
    try std.testing.expect(isReadOnlyQuery("select id from sessions"));
    try std.testing.expect(isReadOnlyQuery("WITH recent AS (SELECT * FROM events) SELECT * FROM recent"));
    try std.testing.expect(isReadOnlyQuery("EXPLAIN SELECT * FROM events"));
    try std.testing.expect(isReadOnlyQuery("EXPLAIN QUERY PLAN SELECT * FROM events"));
    try std.testing.expect(!isReadOnlyQuery("EXPLAIN QUERY PLAN"));
}

test "isReadOnlyQuery rejects writes comments and additional statements" {
    try std.testing.expect(!isReadOnlyQuery("INSERT INTO events VALUES (1)"));
    try std.testing.expect(!isReadOnlyQuery("UPDATE events SET pid = 1"));
    try std.testing.expect(!isReadOnlyQuery("DELETE FROM events"));
    try std.testing.expect(!isReadOnlyQuery("DROP TABLE events"));
    try std.testing.expect(!isReadOnlyQuery("ALTER TABLE events ADD COLUMN x"));
    try std.testing.expect(!isReadOnlyQuery("SELECT * FROM events; DELETE FROM events"));
    try std.testing.expect(!isReadOnlyQuery("SELECT 'safe'; DROP TABLE events"));
    try std.testing.expect(!isReadOnlyQuery("SELECT * FROM events -- hidden write\n; DELETE FROM events"));
    try std.testing.expect(!isReadOnlyQuery("/* comment */ SELECT * FROM events"));
    try std.testing.expect(!isReadOnlyQuery(""));
}

test "query bounds reject invalid pagination" {
    try std.testing.expectEqual(@as(?i64, 100), parseBoundedInteger(null, 100, 1, 1000));
    try std.testing.expectEqual(@as(?i64, null), parseBoundedInteger(.{ .integer = 0 }, 100, 1, 1000));
    try std.testing.expectEqual(@as(?i64, null), parseBoundedInteger(.{ .integer = 1001 }, 100, 1, 1000));
    try std.testing.expectEqual(@as(?i64, 250), parseBoundedInteger(.{ .integer = 250 }, 100, 1, 1000));
    try std.testing.expectEqual(@as(?i64, null), parseBoundedInteger(.{ .string = "10" }, 100, 1, 1000));
}

test "callTool dispatches known tools" {
    var server = try ObserveServer.init(std.testing.allocator);
    defer server.deinit();

    // observe_status requires no arguments
    const result = try server.callTool(std.testing.allocator, "observe_status", null);
    switch (result) {
        .ok => |payload| {
            defer std.testing.allocator.free(payload);
            try std.testing.expect(std.mem.indexOf(u8, payload, "active_sessions") != null);
        },
        else => return error.UnexpectedResult,
    }
}

test "observe_start rejects unavailable backend without creating database" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var old_cwd = try std.fs.cwd().openDir(".", .{});
    defer {
        old_cwd.setAsCwd() catch {};
        old_cwd.close();
    }
    try tmp.dir.setAsCwd();

    var server = try ObserveServer.init(std.testing.allocator);
    defer server.deinit();

    var args = json.ObjectMap.init(std.testing.allocator);
    defer args.deinit();
    try args.put("backend", .{ .string = "syscall" });

    const result = try server.callTool(std.testing.allocator, "observe_start", .{ .object = args });
    switch (result) {
        .err => |err| try std.testing.expect(std.mem.indexOf(u8, err.message, "not implemented") != null),
        else => return error.UnexpectedResult,
    }
    try std.testing.expectError(error.FileNotFound, std.fs.cwd().access(".cog/observe", .{}));
}

test "callTool returns error for unknown tool" {
    var server = try ObserveServer.init(std.testing.allocator);
    defer server.deinit();

    const result = try server.callTool(std.testing.allocator, "observe_nonexistent", null);
    switch (result) {
        .err => |e| {
            try std.testing.expectEqual(METHOD_NOT_FOUND, e.code);
        },
        else => return error.UnexpectedResult,
    }
}
