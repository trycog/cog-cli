const std = @import("std");
const json = std.json;
const Stringify = json.Stringify;
const Writer = std.io.Writer;
const types = @import("types.zig");
const session_mod = @import("session.zig");
const driver_mod = @import("driver.zig");
const dashboard_mod = @import("dashboard.zig");

const SessionManager = session_mod.SessionManager;

// ── JSON-RPC Types ──────────────────────────────────────────────────────

pub const JsonRpcRequest = struct {
    jsonrpc: []const u8,
    id: ?json.Value = null,
    method: []const u8,
    params: ?json.Value = null,
    /// Owns the parsed JSON tree — must be kept alive while id/params are in use.
    _parsed: json.Parsed(json.Value),

    pub fn deinit(self: *const JsonRpcRequest, allocator: std.mem.Allocator) void {
        allocator.free(self.method);
        // deinit is not const-qualified on Parsed, so we need a mutable copy
        var p = self._parsed;
        p.deinit();
    }
};

pub const JsonRpcError = struct {
    code: i32,
    message: []const u8,
    data: ?json.Value = null,
};

// Standard JSON-RPC error codes
pub const PARSE_ERROR = -32700;
pub const INVALID_REQUEST = -32600;
pub const METHOD_NOT_FOUND = -32601;
pub const INVALID_PARAMS = -32602;
pub const INTERNAL_ERROR = -32603;

// ── Parsing ─────────────────────────────────────────────────────────────

pub fn parseJsonRpc(allocator: std.mem.Allocator, data: []const u8) !JsonRpcRequest {
    const parsed = try json.parseFromSlice(json.Value, allocator, data, .{});
    errdefer parsed.deinit();

    if (parsed.value != .object) return error.InvalidRequest;
    const obj = parsed.value.object;

    const method_val = obj.get("method") orelse return error.MissingMethod;
    if (method_val != .string) return error.MissingMethod;

    const id_val = obj.get("id");

    return .{
        .jsonrpc = "2.0",
        .id = if (id_val) |v| switch (v) {
            .integer => v,
            .string => v,
            .null => v,
            else => null,
        } else null,
        .method = try allocator.dupe(u8, method_val.string),
        .params = if (obj.get("params")) |p| switch (p) {
            .object, .array => p,
            else => null,
        } else null,
        ._parsed = parsed,
    };
}

// ── Response Formatting ─────────────────────────────────────────────────

pub fn formatJsonRpcResponse(allocator: std.mem.Allocator, id: ?json.Value, result: []const u8) ![]const u8 {
    var aw: Writer.Allocating = .init(allocator);
    errdefer aw.deinit();

    // Build manually to embed raw JSON for the result field
    try aw.writer.writeAll("{\"jsonrpc\":\"2.0\",\"id\":");
    if (id) |v| {
        switch (v) {
            .integer => |i| {
                var buf: [32]u8 = undefined;
                const s = std.fmt.bufPrint(&buf, "{d}", .{i}) catch "null";
                try aw.writer.writeAll(s);
            },
            .string => |s| {
                try aw.writer.writeByte('"');
                try aw.writer.writeAll(s);
                try aw.writer.writeByte('"');
            },
            else => try aw.writer.writeAll("null"),
        }
    } else {
        try aw.writer.writeAll("null");
    }
    try aw.writer.writeAll(",\"result\":");
    try aw.writer.writeAll(result);
    try aw.writer.writeByte('}');

    return try aw.toOwnedSlice();
}

pub fn formatJsonRpcError(allocator: std.mem.Allocator, id: ?json.Value, code: i32, message: []const u8) ![]const u8 {
    var aw: Writer.Allocating = .init(allocator);
    errdefer aw.deinit();
    var s: Stringify = .{ .writer = &aw.writer };

    try s.beginObject();
    try s.objectField("jsonrpc");
    try s.write("2.0");
    try s.objectField("id");
    if (id) |v| {
        try s.write(v);
    } else {
        try s.write(null);
    }
    try s.objectField("error");
    try s.beginObject();
    try s.objectField("code");
    try s.write(code);
    try s.objectField("message");
    try s.write(message);
    try s.endObject();
    try s.endObject();

    return try aw.toOwnedSlice();
}

// ── MCP Tool Definitions ────────────────────────────────────────────────

pub const tool_definitions = [_]ToolDef{
    .{
        .name = "debug_launch",
        .description = "Launch a program under the debugger",
        .input_schema = debug_launch_schema,
    },
    .{
        .name = "debug_breakpoint",
        .description = "Set, remove, or list breakpoints",
        .input_schema = debug_breakpoint_schema,
    },
    .{
        .name = "debug_run",
        .description = "Continue, step, or restart execution",
        .input_schema = debug_run_schema,
    },
    .{
        .name = "debug_inspect",
        .description = "Evaluate expressions and inspect variables",
        .input_schema = debug_inspect_schema,
    },
    .{
        .name = "debug_stop",
        .description = "Stop a debug session",
        .input_schema = debug_stop_schema,
    },
    .{
        .name = "debug_threads",
        .description = "List threads in a debug session",
        .input_schema = debug_threads_schema,
    },
    .{
        .name = "debug_stacktrace",
        .description = "Get stack trace for a thread",
        .input_schema = debug_stacktrace_schema,
    },
    .{
        .name = "debug_memory",
        .description = "Read or write process memory",
        .input_schema = debug_memory_schema,
    },
    .{
        .name = "debug_disassemble",
        .description = "Disassemble instructions at an address",
        .input_schema = debug_disassemble_schema,
    },
    .{
        .name = "debug_attach",
        .description = "Attach to a running process",
        .input_schema = debug_attach_schema,
    },
    .{
        .name = "debug_set_variable",
        .description = "Set the value of a variable in the current scope",
        .input_schema = debug_set_variable_schema,
    },
    .{
        .name = "debug_scopes",
        .description = "List variable scopes for a stack frame",
        .input_schema = debug_scopes_schema,
    },
    .{
        .name = "debug_watchpoint",
        .description = "Set a data breakpoint (watchpoint) on a variable",
        .input_schema = debug_watchpoint_schema,
    },
    .{
        .name = "debug_capabilities",
        .description = "Query debug driver capabilities",
        .input_schema = debug_capabilities_schema,
    },
    .{
        .name = "debug_completions",
        .description = "Get completions for variable names and expressions",
        .input_schema = debug_completions_schema,
    },
    .{
        .name = "debug_modules",
        .description = "List loaded modules and shared libraries",
        .input_schema = debug_modules_schema,
    },
    .{
        .name = "debug_loaded_sources",
        .description = "List all source files available in the debug session",
        .input_schema = debug_loaded_sources_schema,
    },
    .{
        .name = "debug_source",
        .description = "Retrieve source code by source reference",
        .input_schema = debug_source_schema,
    },
    .{
        .name = "debug_set_expression",
        .description = "Evaluate and assign a complex expression",
        .input_schema = debug_set_expression_schema,
    },
    .{
        .name = "debug_restart_frame",
        .description = "Restart execution from a specific stack frame",
        .input_schema = debug_restart_frame_schema,
    },
    .{
        .name = "debug_exception_info",
        .description = "Get detailed information about the current exception",
        .input_schema = debug_exception_info_schema,
    },
    .{
        .name = "debug_registers",
        .description = "Read CPU register values",
        .input_schema = debug_registers_schema,
    },
    .{
        .name = "debug_instruction_breakpoint",
        .description = "Set or remove instruction-level breakpoints",
        .input_schema = debug_instruction_breakpoint_schema,
    },
    .{
        .name = "debug_step_in_targets",
        .description = "List step-in targets for a stack frame",
        .input_schema = debug_step_in_targets_schema,
    },
    .{
        .name = "debug_breakpoint_locations",
        .description = "Query valid breakpoint positions in a source file",
        .input_schema = debug_breakpoint_locations_schema,
    },
    .{
        .name = "debug_cancel",
        .description = "Cancel a pending debug request",
        .input_schema = debug_cancel_schema,
    },
    .{
        .name = "debug_terminate_threads",
        .description = "Terminate specific threads",
        .input_schema = debug_terminate_threads_schema,
    },
    .{
        .name = "debug_restart",
        .description = "Restart the debug session",
        .input_schema = debug_restart_schema,
    },
    .{
        .name = "debug_sessions",
        .description = "List all active debug sessions",
        .input_schema = debug_sessions_schema,
    },
    .{
        .name = "debug_root_cause",
        .description = "Composite exception analysis: walks stack frames, captures locals and exception info at each level",
        .input_schema = debug_root_cause_schema,
    },
    .{
        .name = "debug_state_delta",
        .description = "Show what changed between the last two stops (variables, stack depth)",
        .input_schema = debug_state_delta_schema,
    },
    .{
        .name = "debug_goto_targets",
        .description = "Discover valid goto target locations for a source line",
        .input_schema = debug_goto_targets_schema,
    },
    .{
        .name = "debug_find_symbol",
        .description = "Search for symbol definitions by name",
        .input_schema = debug_find_symbol_schema,
    },
    .{
        .name = "debug_write_register",
        .description = "Write a value to a CPU register",
        .input_schema = debug_write_register_schema,
    },
    .{
        .name = "debug_variable_location",
        .description = "Get the physical storage location of a variable (register, stack, etc.)",
        .input_schema = debug_variable_location_schema,
    },
    .{
        .name = "debug_suggest_breakpoints",
        .description = "Suggest interesting breakpoint locations for a file or function",
        .input_schema = debug_suggest_breakpoints_schema,
    },
    .{
        .name = "debug_expand_macro",
        .description = "Expand a preprocessor macro definition",
        .input_schema = debug_expand_macro_schema,
    },
    .{
        .name = "debug_diff_state",
        .description = "Compare debug state between two sessions",
        .input_schema = debug_diff_state_schema,
    },
    .{
        .name = "debug_value_history",
        .description = "Track how a variable's value changed across recent stops",
        .input_schema = debug_value_history_schema,
    },
    .{
        .name = "debug_execution_trace",
        .description = "Get the sequence of function calls between the last N stops",
        .input_schema = debug_execution_trace_schema,
    },
    .{
        .name = "debug_hypothesis_test",
        .description = "Set a temporary breakpoint with condition, run, collect results, remove breakpoint",
        .input_schema = debug_hypothesis_test_schema,
    },
    .{
        .name = "debug_deadlock_detect",
        .description = "Analyze thread states to detect potential deadlocks",
        .input_schema = debug_deadlock_detect_schema,
    },
    .{
        .name = "debug_audit_log",
        .description = "Retrieve audit log of state-mutating debug operations",
        .input_schema = debug_audit_log_schema,
    },
    .{
        .name = "debug_poll_events",
        .description = "Poll for pending debug events and notifications",
        .input_schema = debug_poll_events_schema,
    },
};

const ToolDef = struct {
    name: []const u8,
    description: []const u8,
    input_schema: []const u8,
};

const debug_launch_schema =
    \\{"type":"object","properties":{"program":{"type":"string","description":"Path to executable or script"},"args":{"type":"array","items":{"type":"string"},"description":"Program arguments"},"env":{"type":"object","description":"Environment variables"},"cwd":{"type":"string","description":"Working directory"},"language":{"type":"string","description":"Language hint (auto-detected from extension)"},"stop_on_entry":{"type":"boolean","default":false}},"required":["program"]}
;

const debug_breakpoint_schema =
    \\{"type":"object","properties":{"session_id":{"type":"string"},"action":{"type":"string","enum":["set","remove","list","set_function","set_exception"]},"file":{"type":"string"},"line":{"type":"integer"},"condition":{"type":"string"},"hit_condition":{"type":"string"},"log_message":{"type":"string"},"function":{"type":"string"},"filters":{"type":"array","items":{"type":"string"}},"id":{"type":"integer"}},"required":["session_id","action"]}
;

const debug_run_schema =
    \\{"type":"object","properties":{"session_id":{"type":"string"},"action":{"type":"string","enum":["continue","step_into","step_over","step_out","restart","pause","goto","reverse_continue","step_back"]},"file":{"type":"string","description":"Target file for goto"},"line":{"type":"integer","description":"Target line for goto"},"granularity":{"type":"string","enum":["statement","line","instruction"],"description":"Stepping granularity"}},"required":["session_id","action"]}
;

const debug_inspect_schema =
    \\{"type":"object","properties":{"session_id":{"type":"string"},"expression":{"type":"string"},"variable_ref":{"type":"integer"},"frame_id":{"type":"integer"},"scope":{"type":"string","enum":["locals","globals","arguments"]},"context":{"type":"string","enum":["watch","repl","hover","clipboard"],"description":"Evaluation context"}},"required":["session_id"]}
;

const debug_stop_schema =
    \\{"type":"object","properties":{"session_id":{"type":"string"},"terminate_only":{"type":"boolean","default":false,"description":"If true, terminate the debuggee but keep the debug adapter alive (DAP only)"}},"required":["session_id"]}
;

const debug_threads_schema =
    \\{"type":"object","properties":{"session_id":{"type":"string"}},"required":["session_id"]}
;

const debug_stacktrace_schema =
    \\{"type":"object","properties":{"session_id":{"type":"string"},"thread_id":{"type":"integer","default":1},"start_frame":{"type":"integer","default":0},"levels":{"type":"integer","default":20}},"required":["session_id"]}
;

const debug_memory_schema =
    \\{"type":"object","properties":{"session_id":{"type":"string"},"action":{"type":"string","enum":["read","write"]},"address":{"type":"string","description":"Hex address e.g. 0x1000"},"size":{"type":"integer","default":64},"data":{"type":"string","description":"Hex string for write"},"offset":{"type":"integer","description":"Byte offset from the base address"}},"required":["session_id","action","address"]}
;

const debug_disassemble_schema =
    \\{"type":"object","properties":{"session_id":{"type":"string"},"address":{"type":"string","description":"Hex address e.g. 0x1000"},"instruction_count":{"type":"integer","default":10},"instruction_offset":{"type":"integer","description":"Offset in instructions from the address"},"resolve_symbols":{"type":"boolean","description":"Whether to resolve symbol names","default":true}},"required":["session_id","address"]}
;

const debug_attach_schema =
    \\{"type":"object","properties":{"pid":{"type":"integer","description":"Process ID to attach to"},"language":{"type":"string","description":"Language hint"}},"required":["pid"]}
;

const debug_set_variable_schema =
    \\{"type":"object","properties":{"session_id":{"type":"string"},"variable":{"type":"string","description":"Variable name"},"value":{"type":"string","description":"New value"},"frame_id":{"type":"integer","default":0}},"required":["session_id","variable","value"]}
;

const debug_scopes_schema =
    \\{"type":"object","properties":{"session_id":{"type":"string"},"frame_id":{"type":"integer","default":0}},"required":["session_id"]}
;

const debug_watchpoint_schema =
    \\{"type":"object","properties":{"session_id":{"type":"string"},"variable":{"type":"string","description":"Variable name to watch"},"access_type":{"type":"string","enum":["read","write","readWrite"],"default":"write"},"frame_id":{"type":"integer"}},"required":["session_id","variable"]}
;

const debug_capabilities_schema =
    \\{"type":"object","properties":{"session_id":{"type":"string"}},"required":["session_id"]}
;

const debug_completions_schema =
    \\{"type":"object","properties":{"session_id":{"type":"string"},"text":{"type":"string","description":"Partial text to complete"},"column":{"type":"integer","default":0},"frame_id":{"type":"integer"}},"required":["session_id","text"]}
;

const debug_modules_schema =
    \\{"type":"object","properties":{"session_id":{"type":"string"}},"required":["session_id"]}
;

const debug_loaded_sources_schema =
    \\{"type":"object","properties":{"session_id":{"type":"string"}},"required":["session_id"]}
;

const debug_source_schema =
    \\{"type":"object","properties":{"session_id":{"type":"string"},"source_reference":{"type":"integer","description":"Source reference ID"}},"required":["session_id","source_reference"]}
;

const debug_set_expression_schema =
    \\{"type":"object","properties":{"session_id":{"type":"string"},"expression":{"type":"string","description":"Expression to evaluate and set"},"value":{"type":"string","description":"New value"},"frame_id":{"type":"integer","default":0}},"required":["session_id","expression","value"]}
;

const debug_restart_frame_schema =
    \\{"type":"object","properties":{"session_id":{"type":"string"},"frame_id":{"type":"integer","description":"Stack frame ID to restart from"}},"required":["session_id","frame_id"]}
;

const debug_exception_info_schema =
    \\{"type":"object","properties":{"session_id":{"type":"string"},"thread_id":{"type":"integer","default":1}},"required":["session_id"]}
;

const debug_registers_schema =
    \\{"type":"object","properties":{"session_id":{"type":"string"},"thread_id":{"type":"integer","default":1}},"required":["session_id"]}
;

const debug_instruction_breakpoint_schema =
    \\{"type":"object","properties":{"session_id":{"type":"string"},"instruction_reference":{"type":"string","description":"Memory reference to an instruction"},"offset":{"type":"integer","description":"Optional offset from the instruction reference"},"condition":{"type":"string","description":"Optional breakpoint condition expression"},"hit_condition":{"type":"string","description":"Optional hit count condition"}},"required":["session_id","instruction_reference"]}
;

const debug_step_in_targets_schema =
    \\{"type":"object","properties":{"session_id":{"type":"string"},"frame_id":{"type":"integer","description":"Stack frame ID to get step-in targets for"}},"required":["session_id","frame_id"]}
;

const debug_breakpoint_locations_schema =
    \\{"type":"object","properties":{"session_id":{"type":"string"},"source":{"type":"string","description":"Source file path"},"line":{"type":"integer","description":"Start line to query"},"end_line":{"type":"integer","description":"Optional end line for range query"}},"required":["session_id","source","line"]}
;

const debug_cancel_schema =
    \\{"type":"object","properties":{"session_id":{"type":"string"},"request_id":{"type":"integer","description":"ID of the request to cancel"},"progress_id":{"type":"string","description":"ID of the progress to cancel"}},"required":["session_id"]}
;

const debug_terminate_threads_schema =
    \\{"type":"object","properties":{"session_id":{"type":"string"},"thread_ids":{"type":"array","items":{"type":"integer"},"description":"IDs of threads to terminate"}},"required":["session_id","thread_ids"]}
;

const debug_restart_schema =
    \\{"type":"object","properties":{"session_id":{"type":"string"}},"required":["session_id"]}
;

const debug_sessions_schema =
    \\{"type":"object","properties":{}}
;

const debug_root_cause_schema =
    \\{"type":"object","properties":{"session_id":{"type":"string"},"max_frames":{"type":"integer","default":5}},"required":["session_id"]}
;

const debug_state_delta_schema =
    \\{"type":"object","properties":{"session_id":{"type":"string"}},"required":["session_id"]}
;

const debug_goto_targets_schema =
    \\{"type":"object","properties":{"session_id":{"type":"string"},"file":{"type":"string"},"line":{"type":"integer"}},"required":["session_id","file","line"]}
;

const debug_find_symbol_schema =
    \\{"type":"object","properties":{"session_id":{"type":"string"},"name":{"type":"string"}},"required":["session_id","name"]}
;

const debug_write_register_schema =
    \\{"type":"object","properties":{"session_id":{"type":"string"},"name":{"type":"string"},"value":{"type":"integer"}},"required":["session_id","name","value"]}
;

const debug_variable_location_schema =
    \\{"type":"object","properties":{"session_id":{"type":"string"},"name":{"type":"string"},"frame_id":{"type":"integer","default":0}},"required":["session_id","name"]}
;

const debug_suggest_breakpoints_schema =
    \\{"type":"object","properties":{"session_id":{"type":"string"},"query":{"type":"string"}},"required":["session_id","query"]}
;


const debug_expand_macro_schema =
    \\{"type":"object","properties":{"session_id":{"type":"string"},"name":{"type":"string"}},"required":["session_id","name"]}
;


const debug_diff_state_schema =
    \\{"type":"object","properties":{"session_id_a":{"type":"string"},"session_id_b":{"type":"string"}},"required":["session_id_a","session_id_b"]}
;


const debug_value_history_schema =
    \\{"type":"object","properties":{"session_id":{"type":"string"},"variable":{"type":"string","description":"Variable name to get history for"},"max_entries":{"type":"integer","default":10}},"required":["session_id","variable"]}
;

const debug_execution_trace_schema =
    \\{"type":"object","properties":{"session_id":{"type":"string"},"max_stops":{"type":"integer","default":8,"description":"Number of recent stops to include"}},"required":["session_id"]}
;

const debug_hypothesis_test_schema =
    \\{"type":"object","properties":{"session_id":{"type":"string"},"file":{"type":"string"},"line":{"type":"integer"},"condition":{"type":"string","description":"Breakpoint condition to test"},"expression":{"type":"string","description":"Expression to evaluate when hit"},"max_hits":{"type":"integer","default":5}},"required":["session_id","file","line"]}
;

const debug_deadlock_detect_schema =
    \\{"type":"object","properties":{"session_id":{"type":"string"}},"required":["session_id"]}
;

const debug_audit_log_schema =
    \\{"type":"object","properties":{"limit":{"type":"integer","default":50,"description":"Maximum number of entries to return"}}}
;

const debug_poll_events_schema =
    \\{"type":"object","properties":{"session_id":{"type":"string","description":"Poll specific session, or omit for all sessions"}}}
;

// ── MCP Server ──────────────────────────────────────────────────────────

pub const McpServer = struct {
    session_manager: SessionManager,
    allocator: std.mem.Allocator,
    dashboard: dashboard_mod.Dashboard,
    /// Ring buffer of recent stop states for state delta computation
    stop_history: [8]?StopSnapshot = [_]?StopSnapshot{null} ** 8,
    stop_history_idx: u8 = 0,
    /// Resource URIs that clients have subscribed to
    resource_subscriptions: std.StringHashMapUnmanaged(void) = .empty,
    /// Pending notification lines to emit after tool call
    pending_notification_lines: std.ArrayListUnmanaged([]const u8) = .empty,

    // Rate limiting
    rate_limit_window_start: i64 = 0,
    rate_limit_count: u32 = 0,

    // Audit logging
    audit_log: std.ArrayListUnmanaged(AuditEntry) = .empty,

    const RATE_LIMIT_MAX: u32 = 100;
    const RATE_LIMIT_WINDOW_MS: i64 = 10_000;
    const RATE_LIMIT_ERROR: i32 = -32000;

    const StopSnapshot = struct {
        session_id: []const u8,
        stop_reason: types.StopReason,
        locals_json: []const u8,
        stack_depth: u32,
    };

    pub const AuditEntry = struct {
        timestamp_ms: i64,
        tool_name: []const u8,
        session_id: []const u8,
        details: []const u8,
    };

    pub fn init(allocator: std.mem.Allocator) McpServer {
        return .{
            .session_manager = SessionManager.init(allocator),
            .allocator = allocator,
            .dashboard = dashboard_mod.Dashboard.init(),
        };
    }

    pub fn deinit(self: *McpServer) void {
        // Free stop history snapshots
        for (&self.stop_history) |*slot| {
            if (slot.*) |snap| {
                self.allocator.free(snap.locals_json);
                self.allocator.free(snap.session_id);
                slot.* = null;
            }
        }
        // Free resource subscriptions
        {
            var it = self.resource_subscriptions.keyIterator();
            while (it.next()) |key| {
                self.allocator.free(key.*);
            }
            self.resource_subscriptions.deinit(self.allocator);
        }
        // Free pending notification lines
        for (self.pending_notification_lines.items) |line| {
            self.allocator.free(line);
        }
        self.pending_notification_lines.deinit(self.allocator);
        // Free audit log entries
        for (self.audit_log.items) |entry| {
            self.allocator.free(entry.tool_name);
            self.allocator.free(entry.session_id);
            self.allocator.free(entry.details);
        }
        self.audit_log.deinit(self.allocator);
        self.session_manager.deinit();
    }

    /// Handle an MCP JSON-RPC request and return a response.
    pub fn handleRequest(self: *McpServer, allocator: std.mem.Allocator, method: []const u8, params: ?json.Value, id: ?json.Value) ![]const u8 {
        if (std.mem.eql(u8, method, "initialize")) {
            return self.handleInitialize(allocator, id);
        } else if (std.mem.eql(u8, method, "tools/list")) {
            return self.handleToolsList(allocator, id);
        } else if (std.mem.eql(u8, method, "tools/call")) {
            return self.handleToolsCall(allocator, params, id);
        } else if (std.mem.eql(u8, method, "resources/list")) {
            return self.handleResourcesList(allocator, id);
        } else if (std.mem.eql(u8, method, "resources/read")) {
            return self.handleResourcesRead(allocator, params, id);
        } else if (std.mem.eql(u8, method, "resources/subscribe")) {
            return self.handleResourcesSubscribe(allocator, params, id);
        } else if (std.mem.eql(u8, method, "resources/unsubscribe")) {
            return self.handleResourcesUnsubscribe(allocator, params, id);
        } else if (std.mem.eql(u8, method, "prompts/list")) {
            return self.handlePromptsList(allocator, id);
        } else if (std.mem.eql(u8, method, "prompts/get")) {
            return self.handlePromptsGet(allocator, params, id);
        } else {
            return formatJsonRpcError(allocator, id, METHOD_NOT_FOUND, "Method not found");
        }
    }

    fn handleInitialize(self: *McpServer, allocator: std.mem.Allocator, id: ?json.Value) ![]const u8 {
        _ = self;
        const result =
            \\{"protocolVersion":"2024-11-05","capabilities":{"tools":{"listChanged":false},"resources":{"subscribe":true,"listChanged":false},"notifications":true,"prompts":{"listChanged":false}},"serverInfo":{"name":"cog-debug","version":"0.1.0"}}
        ;
        return formatJsonRpcResponse(allocator, id, result);
    }

    fn handleToolsList(self: *McpServer, allocator: std.mem.Allocator, id: ?json.Value) ![]const u8 {
        _ = self;
        var aw: Writer.Allocating = .init(allocator);
        defer aw.deinit();

        // Build tools list with raw schema embedding
        try aw.writer.writeAll("{\"tools\":[");
        for (&tool_definitions, 0..) |*tool, i| {
            if (i > 0) try aw.writer.writeByte(',');
            try aw.writer.writeAll("{\"name\":\"");
            try aw.writer.writeAll(tool.name);
            try aw.writer.writeAll("\",\"description\":\"");
            try aw.writer.writeAll(tool.description);
            try aw.writer.writeAll("\",\"inputSchema\":");
            try aw.writer.writeAll(tool.input_schema);
            try aw.writer.writeByte('}');
        }
        try aw.writer.writeAll("]}");

        const result = try aw.toOwnedSlice();
        defer allocator.free(result);
        return formatJsonRpcResponse(allocator, id, result);
    }

    fn handleToolsCall(self: *McpServer, allocator: std.mem.Allocator, params: ?json.Value, id: ?json.Value) ![]const u8 {
        // Rate limiting check
        const now_ms = std.time.milliTimestamp();
        if (now_ms - self.rate_limit_window_start > RATE_LIMIT_WINDOW_MS) {
            self.rate_limit_window_start = now_ms;
            self.rate_limit_count = 0;
        }
        self.rate_limit_count += 1;
        if (self.rate_limit_count > RATE_LIMIT_MAX) {
            return formatJsonRpcError(allocator, id, RATE_LIMIT_ERROR, "Rate limit exceeded");
        }

        const p = params orelse return formatJsonRpcError(allocator, id, INVALID_PARAMS, "Missing params");
        if (p != .object) return formatJsonRpcError(allocator, id, INVALID_PARAMS, "Params must be object");

        const name_val = p.object.get("name") orelse return formatJsonRpcError(allocator, id, INVALID_PARAMS, "Missing tool name");
        if (name_val != .string) return formatJsonRpcError(allocator, id, INVALID_PARAMS, "Tool name must be string");
        const tool_name = name_val.string;

        const tool_args = p.object.get("arguments");

        // Audit log state-mutating tools
        if (isMutatingTool(tool_name)) {
            self.recordAudit(tool_name, tool_args) catch {};
        }

        if (std.mem.eql(u8, tool_name, "debug_launch")) {
            return self.toolLaunch(allocator, tool_args, id);
        } else if (std.mem.eql(u8, tool_name, "debug_breakpoint")) {
            return self.toolBreakpoint(allocator, tool_args, id);
        } else if (std.mem.eql(u8, tool_name, "debug_run")) {
            return self.toolRun(allocator, tool_args, id);
        } else if (std.mem.eql(u8, tool_name, "debug_inspect")) {
            return self.toolInspect(allocator, tool_args, id);
        } else if (std.mem.eql(u8, tool_name, "debug_stop")) {
            return self.toolStop(allocator, tool_args, id);
        } else if (std.mem.eql(u8, tool_name, "debug_threads")) {
            return self.toolThreads(allocator, tool_args, id);
        } else if (std.mem.eql(u8, tool_name, "debug_stacktrace")) {
            return self.toolStackTrace(allocator, tool_args, id);
        } else if (std.mem.eql(u8, tool_name, "debug_memory")) {
            return self.toolMemory(allocator, tool_args, id);
        } else if (std.mem.eql(u8, tool_name, "debug_disassemble")) {
            return self.toolDisassemble(allocator, tool_args, id);
        } else if (std.mem.eql(u8, tool_name, "debug_attach")) {
            return self.toolAttach(allocator, tool_args, id);
        } else if (std.mem.eql(u8, tool_name, "debug_set_variable")) {
            return self.toolSetVariable(allocator, tool_args, id);
        } else if (std.mem.eql(u8, tool_name, "debug_scopes")) {
            return self.toolScopes(allocator, tool_args, id);
        } else if (std.mem.eql(u8, tool_name, "debug_watchpoint")) {
            return self.toolWatchpoint(allocator, tool_args, id);
        } else if (std.mem.eql(u8, tool_name, "debug_capabilities")) {
            return self.toolCapabilities(allocator, tool_args, id);
        } else if (std.mem.eql(u8, tool_name, "debug_completions")) {
            return self.toolCompletions(allocator, tool_args, id);
        } else if (std.mem.eql(u8, tool_name, "debug_modules")) {
            return self.toolModules(allocator, tool_args, id);
        } else if (std.mem.eql(u8, tool_name, "debug_loaded_sources")) {
            return self.toolLoadedSources(allocator, tool_args, id);
        } else if (std.mem.eql(u8, tool_name, "debug_source")) {
            return self.toolSource(allocator, tool_args, id);
        } else if (std.mem.eql(u8, tool_name, "debug_set_expression")) {
            return self.toolSetExpression(allocator, tool_args, id);
        } else if (std.mem.eql(u8, tool_name, "debug_restart_frame")) {
            return self.toolRestartFrame(allocator, tool_args, id);
        } else if (std.mem.eql(u8, tool_name, "debug_exception_info")) {
            return self.toolExceptionInfo(allocator, tool_args, id);
        } else if (std.mem.eql(u8, tool_name, "debug_registers")) {
            return self.toolRegisters(allocator, tool_args, id);
        } else if (std.mem.eql(u8, tool_name, "debug_instruction_breakpoint")) {
            return self.toolInstructionBreakpoint(allocator, tool_args, id);
        } else if (std.mem.eql(u8, tool_name, "debug_step_in_targets")) {
            return self.toolStepInTargets(allocator, tool_args, id);
        } else if (std.mem.eql(u8, tool_name, "debug_breakpoint_locations")) {
            return self.toolBreakpointLocations(allocator, tool_args, id);
        } else if (std.mem.eql(u8, tool_name, "debug_cancel")) {
            return self.toolCancel(allocator, tool_args, id);
        } else if (std.mem.eql(u8, tool_name, "debug_terminate_threads")) {
            return self.toolTerminateThreads(allocator, tool_args, id);
        } else if (std.mem.eql(u8, tool_name, "debug_restart")) {
            return self.toolRestart(allocator, tool_args, id);
        } else if (std.mem.eql(u8, tool_name, "debug_sessions")) {
            return self.toolSessions(allocator, id);
        } else if (std.mem.eql(u8, tool_name, "debug_root_cause")) {
            return self.toolRootCause(allocator, tool_args, id);
        } else if (std.mem.eql(u8, tool_name, "debug_state_delta")) {
            return self.toolStateDelta(allocator, tool_args, id);
        } else if (std.mem.eql(u8, tool_name, "debug_goto_targets")) {
            return self.toolGotoTargets(allocator, tool_args, id);
        } else if (std.mem.eql(u8, tool_name, "debug_find_symbol")) {
            return self.toolFindSymbol(allocator, tool_args, id);
        } else if (std.mem.eql(u8, tool_name, "debug_write_register")) {
            return self.toolWriteRegister(allocator, tool_args, id);
        } else if (std.mem.eql(u8, tool_name, "debug_variable_location")) {
            return self.toolVariableLocation(allocator, tool_args, id);
        } else if (std.mem.eql(u8, tool_name, "debug_suggest_breakpoints")) {
            return self.toolSuggestBreakpoints(allocator, tool_args, id);
        } else if (std.mem.eql(u8, tool_name, "debug_expand_macro")) {
            return self.toolExpandMacro(allocator, tool_args, id);
        } else if (std.mem.eql(u8, tool_name, "debug_diff_state")) {
            return self.toolDiffState(allocator, tool_args, id);
        } else if (std.mem.eql(u8, tool_name, "debug_value_history")) {
            return self.toolValueHistory(allocator, tool_args, id);
        } else if (std.mem.eql(u8, tool_name, "debug_execution_trace")) {
            return self.toolExecutionTrace(allocator, tool_args, id);
        } else if (std.mem.eql(u8, tool_name, "debug_hypothesis_test")) {
            return self.toolHypothesisTest(allocator, tool_args, id);
        } else if (std.mem.eql(u8, tool_name, "debug_deadlock_detect")) {
            return self.toolDeadlockDetect(allocator, tool_args, id);
        } else if (std.mem.eql(u8, tool_name, "debug_audit_log")) {
            return self.toolAuditLog(allocator, tool_args, id);
        } else if (std.mem.eql(u8, tool_name, "debug_poll_events")) {
            return self.toolPollEvents(allocator, tool_args, id);
        } else {
            return formatJsonRpcError(allocator, id, METHOD_NOT_FOUND, "Unknown tool");
        }
    }

    // ── Resource Handlers ─────────────────────────────────────────────

    fn handleResourcesList(self: *McpServer, allocator: std.mem.Allocator, id: ?json.Value) ![]const u8 {
        _ = self;
        const result =
            \\{"resources":[{"uri":"debug://sessions","name":"Debug Sessions","description":"List of all active debug sessions","mimeType":"application/json"},{"uri":"debug://session/{id}/state","name":"Session State","description":"Current stop state for a debug session","mimeType":"application/json"},{"uri":"debug://session/{id}/threads","name":"Session Threads","description":"Thread list for a debug session","mimeType":"application/json"},{"uri":"debug://session/{id}/breakpoints","name":"Session Breakpoints","description":"Active breakpoints for a debug session","mimeType":"application/json"},{"uri":"debug://session/{id}/modules","name":"Session Modules","description":"Loaded modules and shared libraries for a debug session","mimeType":"application/json"},{"uri":"debug://session/{id}/sources","name":"Session Sources","description":"Available source files for a debug session","mimeType":"application/json"},{"uri":"debug://session/{id}/capabilities","name":"Session Capabilities","description":"Debug driver capability flags for a session","mimeType":"application/json"},{"uri":"debug://session/{id}/stack/{thread_id}","name":"Session Stack Trace","description":"Stack trace for a specific thread in a debug session","mimeType":"application/json"}]}
        ;
        return formatJsonRpcResponse(allocator, id, result);
    }

    fn handleResourcesRead(self: *McpServer, allocator: std.mem.Allocator, params: ?json.Value, id: ?json.Value) ![]const u8 {
        const p = params orelse return formatJsonRpcError(allocator, id, INVALID_PARAMS, "Missing params");
        if (p != .object) return formatJsonRpcError(allocator, id, INVALID_PARAMS, "Params must be object");

        const uri_val = p.object.get("uri") orelse return formatJsonRpcError(allocator, id, INVALID_PARAMS, "Missing uri");
        if (uri_val != .string) return formatJsonRpcError(allocator, id, INVALID_PARAMS, "uri must be string");
        const uri = uri_val.string;

        if (std.mem.eql(u8, uri, "debug://sessions")) {
            // Return session list
            const sessions = self.session_manager.listSessions(allocator) catch |err| {
                return formatJsonRpcError(allocator, id, INTERNAL_ERROR, @errorName(err));
            };
            defer allocator.free(sessions);

            var aw: Writer.Allocating = .init(allocator);
            defer aw.deinit();
            var jw: Stringify = .{ .writer = &aw.writer };
            try jw.beginObject();
            try jw.objectField("contents");
            try jw.beginArray();
            try jw.beginObject();
            try jw.objectField("uri");
            try jw.write("debug://sessions");
            try jw.objectField("mimeType");
            try jw.write("application/json");
            try jw.objectField("text");
            // Serialize session array as a string value
            {
                var inner_aw: Writer.Allocating = .init(allocator);
                defer inner_aw.deinit();
                var inner_jw: Stringify = .{ .writer = &inner_aw.writer };
                try inner_jw.beginArray();
                for (sessions) |*s| {
                    try inner_jw.beginObject();
                    try inner_jw.objectField("id");
                    try inner_jw.write(s.id);
                    try inner_jw.objectField("status");
                    try inner_jw.write(@tagName(s.status));
                    try inner_jw.objectField("driver_type");
                    try inner_jw.write(@tagName(s.driver_type));
                    try inner_jw.endObject();
                }
                try inner_jw.endArray();
                const inner_text = try inner_aw.toOwnedSlice();
                defer allocator.free(inner_text);
                try jw.write(inner_text);
            }
            try jw.endObject();
            try jw.endArray();
            try jw.endObject();
            const result = try aw.toOwnedSlice();
            defer allocator.free(result);
            return formatJsonRpcResponse(allocator, id, result);
        }

        // Parse session-specific URIs: debug://session/{id}/...
        const session_prefix = "debug://session/";
        if (std.mem.startsWith(u8, uri, session_prefix)) {
            const rest = uri[session_prefix.len..];
            // Find the session ID and sub-resource
            if (std.mem.indexOf(u8, rest, "/")) |slash_pos| {
                const session_id = rest[0..slash_pos];
                const sub_resource = rest[slash_pos + 1 ..];

                const session = self.session_manager.getSession(session_id) orelse
                    return formatJsonRpcError(allocator, id, INVALID_PARAMS, "Unknown session");

                var aw: Writer.Allocating = .init(allocator);
                defer aw.deinit();
                var jw: Stringify = .{ .writer = &aw.writer };
                try jw.beginObject();
                try jw.objectField("contents");
                try jw.beginArray();
                try jw.beginObject();
                try jw.objectField("uri");
                try jw.write(uri);
                try jw.objectField("mimeType");
                try jw.write("application/json");
                try jw.objectField("text");

                if (std.mem.eql(u8, sub_resource, "state")) {
                    try jw.write(@tagName(session.status));
                } else if (std.mem.eql(u8, sub_resource, "threads")) {
                    if (session.driver.threads(allocator)) |thread_list| {
                        var inner_aw: Writer.Allocating = .init(allocator);
                        defer inner_aw.deinit();
                        var inner_jw: Stringify = .{ .writer = &inner_aw.writer };
                        try inner_jw.beginArray();
                        for (thread_list) |*t| {
                            try t.jsonStringify(&inner_jw);
                        }
                        try inner_jw.endArray();
                        const inner_text = try inner_aw.toOwnedSlice();
                        defer allocator.free(inner_text);
                        try jw.write(inner_text);
                    } else |_| {
                        try jw.write("[]");
                    }
                } else if (std.mem.eql(u8, sub_resource, "breakpoints")) {
                    if (session.driver.listBreakpoints(allocator)) |bp_list| {
                        var inner_aw: Writer.Allocating = .init(allocator);
                        defer inner_aw.deinit();
                        var inner_jw: Stringify = .{ .writer = &inner_aw.writer };
                        try inner_jw.beginArray();
                        for (bp_list) |*bp| {
                            try bp.jsonStringify(&inner_jw);
                        }
                        try inner_jw.endArray();
                        const inner_text = try inner_aw.toOwnedSlice();
                        defer allocator.free(inner_text);
                        try jw.write(inner_text);
                    } else |_| {
                        try jw.write("[]");
                    }
                } else if (std.mem.eql(u8, sub_resource, "modules")) {
                    if (session.driver.modules(allocator)) |module_list| {
                        var inner_aw: Writer.Allocating = .init(allocator);
                        defer inner_aw.deinit();
                        var inner_jw: Stringify = .{ .writer = &inner_aw.writer };
                        try inner_jw.beginArray();
                        for (module_list) |*m| {
                            try m.jsonStringify(&inner_jw);
                        }
                        try inner_jw.endArray();
                        const inner_text = try inner_aw.toOwnedSlice();
                        defer allocator.free(inner_text);
                        try jw.write(inner_text);
                    } else |_| {
                        try jw.write("[]");
                    }
                } else if (std.mem.eql(u8, sub_resource, "sources")) {
                    if (session.driver.loadedSources(allocator)) |source_list| {
                        var inner_aw: Writer.Allocating = .init(allocator);
                        defer inner_aw.deinit();
                        var inner_jw: Stringify = .{ .writer = &inner_aw.writer };
                        try inner_jw.beginArray();
                        for (source_list) |*s| {
                            try s.jsonStringify(&inner_jw);
                        }
                        try inner_jw.endArray();
                        const inner_text = try inner_aw.toOwnedSlice();
                        defer allocator.free(inner_text);
                        try jw.write(inner_text);
                    } else |_| {
                        try jw.write("[]");
                    }
                } else if (std.mem.eql(u8, sub_resource, "capabilities")) {
                    const caps = session.driver.capabilities();
                    var inner_aw: Writer.Allocating = .init(allocator);
                    defer inner_aw.deinit();
                    var inner_jw: Stringify = .{ .writer = &inner_aw.writer };
                    try caps.jsonStringify(&inner_jw);
                    const inner_text = try inner_aw.toOwnedSlice();
                    defer allocator.free(inner_text);
                    try jw.write(inner_text);
                } else if (std.mem.startsWith(u8, sub_resource, "stack/")) {
                    const thread_id_str = sub_resource["stack/".len..];
                    const thread_id = std.fmt.parseInt(u32, thread_id_str, 10) catch {
                        try jw.endObject();
                        try jw.endArray();
                        try jw.endObject();
                        const discard = try aw.toOwnedSlice();
                        defer allocator.free(discard);
                        return formatJsonRpcError(allocator, id, INVALID_PARAMS, "Invalid thread_id");
                    };
                    if (session.driver.stackTrace(allocator, thread_id, 0, 100)) |frames| {
                        var inner_aw: Writer.Allocating = .init(allocator);
                        defer inner_aw.deinit();
                        var inner_jw: Stringify = .{ .writer = &inner_aw.writer };
                        try inner_jw.beginArray();
                        for (frames) |*f| {
                            try f.jsonStringify(&inner_jw);
                        }
                        try inner_jw.endArray();
                        const inner_text = try inner_aw.toOwnedSlice();
                        defer allocator.free(inner_text);
                        try jw.write(inner_text);
                    } else |_| {
                        try jw.write("[]");
                    }
                } else {
                    try jw.endObject();
                    try jw.endArray();
                    try jw.endObject();
                    const discard = try aw.toOwnedSlice();
                    defer allocator.free(discard);
                    return formatJsonRpcError(allocator, id, INVALID_PARAMS, "Unknown sub-resource");
                }

                try jw.endObject();
                try jw.endArray();
                try jw.endObject();
                const result = try aw.toOwnedSlice();
                defer allocator.free(result);
                return formatJsonRpcResponse(allocator, id, result);
            }
        }

        return formatJsonRpcError(allocator, id, INVALID_PARAMS, "Unknown resource URI");
    }

    fn handleResourcesSubscribe(self: *McpServer, allocator: std.mem.Allocator, params: ?json.Value, id: ?json.Value) ![]const u8 {
        const p = params orelse return formatJsonRpcError(allocator, id, INVALID_PARAMS, "Missing params");
        if (p != .object) return formatJsonRpcError(allocator, id, INVALID_PARAMS, "Params must be object");

        const uri_val = p.object.get("uri") orelse return formatJsonRpcError(allocator, id, INVALID_PARAMS, "Missing uri");
        if (uri_val != .string) return formatJsonRpcError(allocator, id, INVALID_PARAMS, "uri must be string");

        const key = try allocator.dupe(u8, uri_val.string);
        self.resource_subscriptions.put(self.allocator, key, {}) catch {
            allocator.free(key);
            return formatJsonRpcError(allocator, id, INTERNAL_ERROR, "Subscription failed");
        };

        return formatJsonRpcResponse(allocator, id, "{}");
    }

    fn handleResourcesUnsubscribe(self: *McpServer, allocator: std.mem.Allocator, params: ?json.Value, id: ?json.Value) ![]const u8 {
        const p = params orelse return formatJsonRpcError(allocator, id, INVALID_PARAMS, "Missing params");
        if (p != .object) return formatJsonRpcError(allocator, id, INVALID_PARAMS, "Params must be object");

        const uri_val = p.object.get("uri") orelse return formatJsonRpcError(allocator, id, INVALID_PARAMS, "Missing uri");
        if (uri_val != .string) return formatJsonRpcError(allocator, id, INVALID_PARAMS, "uri must be string");

        if (self.resource_subscriptions.fetchRemove(uri_val.string)) |kv| {
            self.allocator.free(kv.key);
        }

        return formatJsonRpcResponse(allocator, id, "{}");
    }

    // ── Notification Emission ────────────────────────────────────────────

    /// Collect notifications from all active sessions' drivers and format as JSON-RPC notification lines.
    pub fn collectNotifications(self: *McpServer) void {
        var iter = self.session_manager.sessions.iterator();
        while (iter.next()) |entry| {
            const notifications = entry.value_ptr.driver.drainNotifications(self.allocator);
            defer self.allocator.free(notifications);
            for (notifications) |*notif| {
                // Format as JSON-RPC notification line
                var aw: Writer.Allocating = .init(self.allocator);
                var jw: Stringify = .{ .writer = &aw.writer };
                notif.jsonStringify(&jw) catch {
                    aw.deinit();
                    continue;
                };
                if (aw.toOwnedSlice()) |line| {
                    self.pending_notification_lines.append(self.allocator, line) catch {
                        self.allocator.free(line);
                    };
                } else |_| {}
                // Free the notification data
                self.allocator.free(notif.method);
                self.allocator.free(notif.params_json);
            }
        }
    }

    // ── Tool Implementations ────────────────────────────────────────────

    fn toolLaunch(self: *McpServer, allocator: std.mem.Allocator, args: ?json.Value, id: ?json.Value) ![]const u8 {
        const a = args orelse return formatJsonRpcError(allocator, id, INVALID_PARAMS, "Missing arguments");
        if (a != .object) return formatJsonRpcError(allocator, id, INVALID_PARAMS, "Arguments must be object");

        const config = types.LaunchConfig.parseFromJson(allocator, a) catch {
            return formatJsonRpcError(allocator, id, INVALID_PARAMS, "Invalid launch config: program is required");
        };
        defer config.deinit(allocator);

        // Determine driver type from language hint or file extension
        const use_dap = blk: {
            if (config.language) |lang| {
                if (std.mem.eql(u8, lang, "python") or
                    std.mem.eql(u8, lang, "javascript") or
                    std.mem.eql(u8, lang, "go") or
                    std.mem.eql(u8, lang, "java")) break :blk true;
            }
            // Check file extension
            const ext = std.fs.path.extension(config.program);
            if (std.mem.eql(u8, ext, ".py") or
                std.mem.eql(u8, ext, ".js") or
                std.mem.eql(u8, ext, ".go") or
                std.mem.eql(u8, ext, ".java")) break :blk true;
            break :blk false;
        };

        if (use_dap) {
            const dap_proxy = @import("dap/proxy.zig");
            var proxy = try allocator.create(dap_proxy.DapProxy);
            proxy.* = dap_proxy.DapProxy.init(allocator);
            errdefer {
                proxy.deinit();
                allocator.destroy(proxy);
            }

            var driver = proxy.activeDriver();
            driver.launch(allocator, config) catch |err| {
                self.dashboard.onError("debug_launch", @errorName(err));
                return formatJsonRpcError(allocator, id, INTERNAL_ERROR, @errorName(err));
            };

            const session_id = try self.session_manager.createSession(driver);
            if (self.session_manager.getSession(session_id)) |s| {
                s.status = .stopped;
            }
            self.dashboard.onLaunch(session_id, config.program, "dap");

            var aw: Writer.Allocating = .init(allocator);
            defer aw.deinit();
            var s: Stringify = .{ .writer = &aw.writer };
            try s.beginObject();
            try s.objectField("session_id");
            try s.write(session_id);
            try s.objectField("status");
            try s.write("stopped");
            try s.endObject();
            const result = try aw.toOwnedSlice();
            defer allocator.free(result);
            return formatJsonRpcResponse(allocator, id, result);
        } else {
            const dwarf_engine = @import("dwarf/engine.zig");
            var engine = try allocator.create(dwarf_engine.DwarfEngine);
            engine.* = dwarf_engine.DwarfEngine.init(allocator);
            errdefer {
                engine.deinit();
                allocator.destroy(engine);
            }

            var driver = engine.activeDriver();
            driver.launch(allocator, config) catch |err| {
                self.dashboard.onError("debug_launch", @errorName(err));
                return formatJsonRpcError(allocator, id, INTERNAL_ERROR, @errorName(err));
            };

            const session_id = try self.session_manager.createSession(driver);
            if (self.session_manager.getSession(session_id)) |ss| {
                ss.status = .stopped;
            }
            self.dashboard.onLaunch(session_id, config.program, "native");

            var aw: Writer.Allocating = .init(allocator);
            defer aw.deinit();
            var s: Stringify = .{ .writer = &aw.writer };
            try s.beginObject();
            try s.objectField("session_id");
            try s.write(session_id);
            try s.objectField("status");
            try s.write("stopped");
            try s.endObject();
            const result = try aw.toOwnedSlice();
            defer allocator.free(result);
            return formatJsonRpcResponse(allocator, id, result);
        }
    }

    fn toolBreakpoint(self: *McpServer, allocator: std.mem.Allocator, args: ?json.Value, id: ?json.Value) ![]const u8 {
        const a = args orelse return formatJsonRpcError(allocator, id, INVALID_PARAMS, "Missing arguments");
        if (a != .object) return formatJsonRpcError(allocator, id, INVALID_PARAMS, "Arguments must be object");

        const session_id_val = a.object.get("session_id") orelse return formatJsonRpcError(allocator, id, INVALID_PARAMS, "Missing session_id");
        if (session_id_val != .string) return formatJsonRpcError(allocator, id, INVALID_PARAMS, "session_id must be string");

        const session = self.session_manager.getSession(session_id_val.string) orelse
            return formatJsonRpcError(allocator, id, INVALID_PARAMS, "Unknown session");

        const action_val = a.object.get("action") orelse return formatJsonRpcError(allocator, id, INVALID_PARAMS, "Missing action");
        if (action_val != .string) return formatJsonRpcError(allocator, id, INVALID_PARAMS, "action must be string");
        const action_str = action_val.string;

        if (std.mem.eql(u8, action_str, "set")) {
            const file_val = a.object.get("file") orelse return formatJsonRpcError(allocator, id, INVALID_PARAMS, "Missing file for set");
            if (file_val != .string) return formatJsonRpcError(allocator, id, INVALID_PARAMS, "file must be string");
            const line_val = a.object.get("line") orelse return formatJsonRpcError(allocator, id, INVALID_PARAMS, "Missing line for set");
            if (line_val != .integer) return formatJsonRpcError(allocator, id, INVALID_PARAMS, "line must be integer");

            const condition = if (a.object.get("condition")) |c| (if (c == .string) c.string else null) else null;
            const hit_condition = if (a.object.get("hit_condition")) |c| (if (c == .string) c.string else null) else null;
            const log_message = if (a.object.get("log_message")) |c| (if (c == .string) c.string else null) else null;

            const bp = session.driver.setBreakpointEx(allocator, file_val.string, @intCast(line_val.integer), condition, hit_condition, log_message) catch |err| {
                self.dashboard.onError("debug_breakpoint", @errorName(err));
                return formatJsonRpcError(allocator, id, INTERNAL_ERROR, @errorName(err));
            };
            self.dashboard.onBreakpoint("set", bp);

            var aw: Writer.Allocating = .init(allocator);
            defer aw.deinit();
            var s: Stringify = .{ .writer = &aw.writer };
            try s.beginObject();
            try s.objectField("breakpoints");
            try s.beginArray();
            try bp.jsonStringify(&s);
            try s.endArray();
            try s.endObject();
            const result = try aw.toOwnedSlice();
            defer allocator.free(result);
            return formatJsonRpcResponse(allocator, id, result);
        } else if (std.mem.eql(u8, action_str, "remove")) {
            const bp_id_val = a.object.get("id") orelse return formatJsonRpcError(allocator, id, INVALID_PARAMS, "Missing id for remove");
            if (bp_id_val != .integer) return formatJsonRpcError(allocator, id, INVALID_PARAMS, "id must be integer");

            session.driver.removeBreakpoint(allocator, @intCast(bp_id_val.integer)) catch |err| {
                self.dashboard.onError("debug_breakpoint", @errorName(err));
                return formatJsonRpcError(allocator, id, INTERNAL_ERROR, @errorName(err));
            };
            self.dashboard.onBreakpoint("remove", .{
                .id = @intCast(bp_id_val.integer),
                .verified = false,
                .file = "",
                .line = 0,
            });

            return formatJsonRpcResponse(allocator, id, "{\"removed\":true}");
        } else if (std.mem.eql(u8, action_str, "list")) {
            const bps = session.driver.listBreakpoints(allocator) catch |err| {
                self.dashboard.onError("debug_breakpoint", @errorName(err));
                return formatJsonRpcError(allocator, id, INTERNAL_ERROR, @errorName(err));
            };
            self.dashboard.onBreakpoint("list", .{
                .id = 0,
                .verified = false,
                .file = "",
                .line = 0,
            });

            var aw: Writer.Allocating = .init(allocator);
            defer aw.deinit();
            var s: Stringify = .{ .writer = &aw.writer };
            try s.beginObject();
            try s.objectField("breakpoints");
            try s.beginArray();
            for (bps) |*bp| {
                try bp.jsonStringify(&s);
            }
            try s.endArray();
            try s.endObject();
            const result = try aw.toOwnedSlice();
            defer allocator.free(result);
            return formatJsonRpcResponse(allocator, id, result);
        } else if (std.mem.eql(u8, action_str, "set_function")) {
            const func_val = a.object.get("function") orelse return formatJsonRpcError(allocator, id, INVALID_PARAMS, "Missing function name");
            if (func_val != .string) return formatJsonRpcError(allocator, id, INVALID_PARAMS, "function must be string");

            const condition = if (a.object.get("condition")) |c| (if (c == .string) c.string else null) else null;

            const bp = session.driver.setFunctionBreakpoint(allocator, func_val.string, condition) catch |err| {
                self.dashboard.onError("debug_breakpoint", @errorName(err));
                return formatJsonRpcError(allocator, id, INTERNAL_ERROR, @errorName(err));
            };
            self.dashboard.onBreakpoint("set", bp);

            var aw: Writer.Allocating = .init(allocator);
            defer aw.deinit();
            var s: Stringify = .{ .writer = &aw.writer };
            try s.beginObject();
            try s.objectField("breakpoints");
            try s.beginArray();
            try bp.jsonStringify(&s);
            try s.endArray();
            try s.endObject();
            const result = try aw.toOwnedSlice();
            defer allocator.free(result);
            return formatJsonRpcResponse(allocator, id, result);
        } else if (std.mem.eql(u8, action_str, "set_exception")) {
            const filters_val = a.object.get("filters") orelse return formatJsonRpcError(allocator, id, INVALID_PARAMS, "Missing filters for set_exception");
            if (filters_val != .array) return formatJsonRpcError(allocator, id, INVALID_PARAMS, "filters must be array");

            // Extract string filters
            var filter_list = std.ArrayListUnmanaged([]const u8).empty;
            defer filter_list.deinit(allocator);
            for (filters_val.array.items) |item| {
                if (item == .string) {
                    try filter_list.append(allocator, item.string);
                }
            }

            session.driver.setExceptionBreakpoints(allocator, filter_list.items) catch |err| {
                self.dashboard.onError("debug_breakpoint", @errorName(err));
                return formatJsonRpcError(allocator, id, INTERNAL_ERROR, @errorName(err));
            };

            return formatJsonRpcResponse(allocator, id, "{\"exception_breakpoints_set\":true}");
        } else {
            return formatJsonRpcError(allocator, id, INVALID_PARAMS, "action must be set, remove, list, set_function, or set_exception");
        }
    }

    fn toolRun(self: *McpServer, allocator: std.mem.Allocator, args: ?json.Value, id: ?json.Value) ![]const u8 {
        const a = args orelse return formatJsonRpcError(allocator, id, INVALID_PARAMS, "Missing arguments");
        if (a != .object) return formatJsonRpcError(allocator, id, INVALID_PARAMS, "Arguments must be object");

        const session_id_val = a.object.get("session_id") orelse return formatJsonRpcError(allocator, id, INVALID_PARAMS, "Missing session_id");
        if (session_id_val != .string) return formatJsonRpcError(allocator, id, INVALID_PARAMS, "session_id must be string");

        const session = self.session_manager.getSession(session_id_val.string) orelse
            return formatJsonRpcError(allocator, id, INVALID_PARAMS, "Unknown session");

        const action_val = a.object.get("action") orelse return formatJsonRpcError(allocator, id, INVALID_PARAMS, "Missing action");
        if (action_val != .string) return formatJsonRpcError(allocator, id, INVALID_PARAMS, "action must be string");

        // Handle goto separately — it dispatches through gotoFn, not runFn
        if (std.mem.eql(u8, action_val.string, "goto")) {
            const file_val = a.object.get("file") orelse return formatJsonRpcError(allocator, id, INVALID_PARAMS, "Missing file for goto");
            if (file_val != .string) return formatJsonRpcError(allocator, id, INVALID_PARAMS, "file must be string");
            const line_val = a.object.get("line") orelse return formatJsonRpcError(allocator, id, INVALID_PARAMS, "Missing line for goto");
            if (line_val != .integer) return formatJsonRpcError(allocator, id, INVALID_PARAMS, "line must be integer");

            const state = session.driver.goto(allocator, file_val.string, @intCast(line_val.integer)) catch |err| {
                self.dashboard.onError("debug_run", @errorName(err));
                return formatJsonRpcError(allocator, id, INTERNAL_ERROR, @errorName(err));
            };

            session.status = .stopped;
            self.dashboard.onRun(session_id_val.string, "goto", state);

            var aw: Writer.Allocating = .init(allocator);
            defer aw.deinit();
            var s: Stringify = .{ .writer = &aw.writer };
            try state.jsonStringify(&s);
            const result = try aw.toOwnedSlice();
            defer allocator.free(result);
            return formatJsonRpcResponse(allocator, id, result);
        }

        const action = types.RunAction.parse(action_val.string) orelse
            return formatJsonRpcError(allocator, id, INVALID_PARAMS, "Invalid action");

        const run_options = types.RunOptions{
            .granularity = if (a.object.get("granularity")) |v| (if (v == .string) types.SteppingGranularity.parse(v.string) else null) else null,
            .target_id = if (a.object.get("target_id")) |v| (if (v == .integer) @as(u32, @intCast(v.integer)) else null) else null,
            .thread_id = if (a.object.get("thread_id")) |v| (if (v == .integer) @as(u32, @intCast(v.integer)) else null) else null,
        };

        session.status = .running;
        const state = session.driver.runEx(allocator, action, run_options) catch |err| {
            self.dashboard.onError("debug_run", @errorName(err));
            return formatJsonRpcError(allocator, id, INTERNAL_ERROR, @errorName(err));
        };

        session.status = if (state.stop_reason == .exit) .terminated else .stopped;
        self.dashboard.onRun(session_id_val.string, action_val.string, state);

        // Record stop snapshot for state delta computation
        self.recordStopSnapshot(allocator, session_id_val.string, state);

        var aw: Writer.Allocating = .init(allocator);
        defer aw.deinit();
        var s: Stringify = .{ .writer = &aw.writer };
        try state.jsonStringify(&s);
        const result = try aw.toOwnedSlice();
        defer allocator.free(result);
        return formatJsonRpcResponse(allocator, id, result);
    }

    fn toolInspect(self: *McpServer, allocator: std.mem.Allocator, args: ?json.Value, id: ?json.Value) ![]const u8 {
        const a = args orelse return formatJsonRpcError(allocator, id, INVALID_PARAMS, "Missing arguments");
        if (a != .object) return formatJsonRpcError(allocator, id, INVALID_PARAMS, "Arguments must be object");

        const session_id_val = a.object.get("session_id") orelse return formatJsonRpcError(allocator, id, INVALID_PARAMS, "Missing session_id");
        if (session_id_val != .string) return formatJsonRpcError(allocator, id, INVALID_PARAMS, "session_id must be string");

        const session = self.session_manager.getSession(session_id_val.string) orelse
            return formatJsonRpcError(allocator, id, INVALID_PARAMS, "Unknown session");

        const request = types.InspectRequest{
            .expression = if (a.object.get("expression")) |v| (if (v == .string) v.string else null) else null,
            .variable_ref = if (a.object.get("variable_ref")) |v| (if (v == .integer) @as(u32, @intCast(v.integer)) else null) else null,
            .frame_id = if (a.object.get("frame_id")) |v| (if (v == .integer) @as(u32, @intCast(v.integer)) else null) else null,
            .scope = if (a.object.get("scope")) |v| (if (v == .string) v.string else null) else null,
            .context = if (a.object.get("context")) |v| (if (v == .string) types.EvaluateContext.parse(v.string) else null) else null,
        };

        const result_val = session.driver.inspect(allocator, request) catch |err| {
            self.dashboard.onError("debug_inspect", @errorName(err));
            return formatJsonRpcError(allocator, id, INTERNAL_ERROR, @errorName(err));
        };
        defer result_val.deinit(allocator);
        self.dashboard.onInspect(
            session_id_val.string,
            if (request.expression) |e| e else "(scope)",
            result_val.result,
        );

        var aw: Writer.Allocating = .init(allocator);
        defer aw.deinit();
        var s: Stringify = .{ .writer = &aw.writer };
        try result_val.jsonStringify(&s);
        const result = try aw.toOwnedSlice();
        defer allocator.free(result);
        return formatJsonRpcResponse(allocator, id, result);
    }

    fn toolStop(self: *McpServer, allocator: std.mem.Allocator, args: ?json.Value, id: ?json.Value) ![]const u8 {
        const a = args orelse return formatJsonRpcError(allocator, id, INVALID_PARAMS, "Missing arguments");
        if (a != .object) return formatJsonRpcError(allocator, id, INVALID_PARAMS, "Arguments must be object");

        const session_id_val = a.object.get("session_id") orelse return formatJsonRpcError(allocator, id, INVALID_PARAMS, "Missing session_id");
        if (session_id_val != .string) return formatJsonRpcError(allocator, id, INVALID_PARAMS, "session_id must be string");

        const session_id = session_id_val.string;

        const terminate_only = if (a.object.get("terminate_only")) |v| (v == .bool and v.bool) else false;
        const detach = if (a.object.get("detach")) |v| (v == .bool and v.bool) else false;

        if (self.session_manager.getSession(session_id)) |session| {
            if (terminate_only) {
                // Terminate the debuggee but keep the adapter alive (DAP only)
                session.driver.terminate(allocator) catch {
                    // Fall back to full stop if terminate not supported
                    session.driver.stop(allocator) catch {};
                };
                return formatJsonRpcResponse(allocator, id, "{\"terminated\":true}");
            }
            if (detach) {
                // Detach without killing the debuggee
                session.driver.detach(allocator) catch {
                    // Fall back to full stop if detach not supported
                    session.driver.stop(allocator) catch {};
                };
            } else {
                session.driver.stop(allocator) catch {};
            }
        }

        self.dashboard.onStop(session_id);

        // Copy key before destroying since destroySession frees the key
        const id_copy = try allocator.dupe(u8, session_id);
        defer allocator.free(id_copy);
        _ = self.session_manager.destroySession(id_copy);

        return formatJsonRpcResponse(allocator, id, "{\"stopped\":true}");
    }

    // ── New Tool Implementations (Phase 3) ────────────────────────────

    fn toolThreads(self: *McpServer, allocator: std.mem.Allocator, args: ?json.Value, id: ?json.Value) ![]const u8 {
        const a = args orelse return formatJsonRpcError(allocator, id, INVALID_PARAMS, "Missing arguments");
        if (a != .object) return formatJsonRpcError(allocator, id, INVALID_PARAMS, "Arguments must be object");

        const session_id_val = a.object.get("session_id") orelse return formatJsonRpcError(allocator, id, INVALID_PARAMS, "Missing session_id");
        if (session_id_val != .string) return formatJsonRpcError(allocator, id, INVALID_PARAMS, "session_id must be string");

        const session = self.session_manager.getSession(session_id_val.string) orelse
            return formatJsonRpcError(allocator, id, INVALID_PARAMS, "Unknown session");

        const thread_list = session.driver.threads(allocator) catch |err| {
            self.dashboard.onError("debug_threads", @errorName(err));
            return formatJsonRpcError(allocator, id, INTERNAL_ERROR, @errorName(err));
        };
        self.dashboard.onThreads(session_id_val.string, thread_list.len);

        var aw: Writer.Allocating = .init(allocator);
        defer aw.deinit();
        var s: Stringify = .{ .writer = &aw.writer };
        try s.beginObject();
        try s.objectField("threads");
        try s.beginArray();
        for (thread_list) |*t| {
            try t.jsonStringify(&s);
        }
        try s.endArray();
        try s.endObject();
        const result = try aw.toOwnedSlice();
        defer allocator.free(result);
        return formatJsonRpcResponse(allocator, id, result);
    }

    fn toolStackTrace(self: *McpServer, allocator: std.mem.Allocator, args: ?json.Value, id: ?json.Value) ![]const u8 {
        const a = args orelse return formatJsonRpcError(allocator, id, INVALID_PARAMS, "Missing arguments");
        if (a != .object) return formatJsonRpcError(allocator, id, INVALID_PARAMS, "Arguments must be object");

        const session_id_val = a.object.get("session_id") orelse return formatJsonRpcError(allocator, id, INVALID_PARAMS, "Missing session_id");
        if (session_id_val != .string) return formatJsonRpcError(allocator, id, INVALID_PARAMS, "session_id must be string");

        const session = self.session_manager.getSession(session_id_val.string) orelse
            return formatJsonRpcError(allocator, id, INVALID_PARAMS, "Unknown session");

        const thread_id: u32 = if (a.object.get("thread_id")) |v| (if (v == .integer) @intCast(v.integer) else 1) else 1;
        const start_frame: u32 = if (a.object.get("start_frame")) |v| (if (v == .integer) @intCast(v.integer) else 0) else 0;
        const levels: u32 = if (a.object.get("levels")) |v| (if (v == .integer) @intCast(v.integer) else 20) else 20;

        const frames = session.driver.stackTrace(allocator, thread_id, start_frame, levels) catch |err| {
            self.dashboard.onError("debug_stacktrace", @errorName(err));
            return formatJsonRpcError(allocator, id, INTERNAL_ERROR, @errorName(err));
        };
        self.dashboard.onStackTrace(session_id_val.string, frames.len);

        var aw: Writer.Allocating = .init(allocator);
        defer aw.deinit();
        var s: Stringify = .{ .writer = &aw.writer };
        try s.beginObject();
        try s.objectField("stack_trace");
        try s.beginArray();
        for (frames) |*f| {
            try f.jsonStringify(&s);
        }
        try s.endArray();
        try s.endObject();
        const result = try aw.toOwnedSlice();
        defer allocator.free(result);
        return formatJsonRpcResponse(allocator, id, result);
    }

    fn toolMemory(self: *McpServer, allocator: std.mem.Allocator, args: ?json.Value, id: ?json.Value) ![]const u8 {
        const a = args orelse return formatJsonRpcError(allocator, id, INVALID_PARAMS, "Missing arguments");
        if (a != .object) return formatJsonRpcError(allocator, id, INVALID_PARAMS, "Arguments must be object");

        const session_id_val = a.object.get("session_id") orelse return formatJsonRpcError(allocator, id, INVALID_PARAMS, "Missing session_id");
        if (session_id_val != .string) return formatJsonRpcError(allocator, id, INVALID_PARAMS, "session_id must be string");

        const session = self.session_manager.getSession(session_id_val.string) orelse
            return formatJsonRpcError(allocator, id, INVALID_PARAMS, "Unknown session");

        const action_val = a.object.get("action") orelse return formatJsonRpcError(allocator, id, INVALID_PARAMS, "Missing action");
        if (action_val != .string) return formatJsonRpcError(allocator, id, INVALID_PARAMS, "action must be string");

        const addr_val = a.object.get("address") orelse return formatJsonRpcError(allocator, id, INVALID_PARAMS, "Missing address");
        if (addr_val != .string) return formatJsonRpcError(allocator, id, INVALID_PARAMS, "address must be string");

        // Parse hex address (e.g. "0x1000" or "1000")
        const addr_str = addr_val.string;
        const trimmed = if (std.mem.startsWith(u8, addr_str, "0x") or std.mem.startsWith(u8, addr_str, "0X"))
            addr_str[2..]
        else
            addr_str;
        const address = std.fmt.parseInt(u64, trimmed, 16) catch
            return formatJsonRpcError(allocator, id, INVALID_PARAMS, "Invalid address format");

        // Apply optional offset to address
        const offset: i64 = if (a.object.get("offset")) |v| (if (v == .integer) v.integer else 0) else 0;
        const effective_address: u64 = if (offset >= 0)
            address +% @as(u64, @intCast(offset))
        else
            address -% @as(u64, @intCast(-offset));

        if (std.mem.eql(u8, action_val.string, "read")) {
            const size: u64 = if (a.object.get("size")) |v| (if (v == .integer) @intCast(v.integer) else 64) else 64;

            const hex_data = session.driver.readMemory(allocator, effective_address, size) catch |err| {
                self.dashboard.onError("debug_memory", @errorName(err));
                return formatJsonRpcError(allocator, id, INTERNAL_ERROR, @errorName(err));
            };
            self.dashboard.onMemory(session_id_val.string, "read", addr_val.string);

            var aw: Writer.Allocating = .init(allocator);
            defer aw.deinit();
            var s: Stringify = .{ .writer = &aw.writer };
            try s.beginObject();
            try s.objectField("data");
            try s.write(hex_data);
            try s.objectField("address");
            try s.write(addr_val.string);
            try s.objectField("size");
            try s.write(size);
            try s.endObject();
            const result = try aw.toOwnedSlice();
            defer allocator.free(result);
            return formatJsonRpcResponse(allocator, id, result);
        } else if (std.mem.eql(u8, action_val.string, "write")) {
            const data_val = a.object.get("data") orelse return formatJsonRpcError(allocator, id, INVALID_PARAMS, "Missing data for write");
            if (data_val != .string) return formatJsonRpcError(allocator, id, INVALID_PARAMS, "data must be hex string");

            // Parse hex string to bytes
            const hex_str = data_val.string;
            if (hex_str.len % 2 != 0) return formatJsonRpcError(allocator, id, INVALID_PARAMS, "data must be even-length hex string");

            const byte_len = hex_str.len / 2;
            const bytes = try allocator.alloc(u8, byte_len);
            defer allocator.free(bytes);
            for (0..byte_len) |i| {
                bytes[i] = std.fmt.parseInt(u8, hex_str[i * 2 .. i * 2 + 2], 16) catch
                    return formatJsonRpcError(allocator, id, INVALID_PARAMS, "Invalid hex data");
            }

            session.driver.writeMemory(allocator, effective_address, bytes) catch |err| {
                self.dashboard.onError("debug_memory", @errorName(err));
                return formatJsonRpcError(allocator, id, INTERNAL_ERROR, @errorName(err));
            };
            self.dashboard.onMemory(session_id_val.string, "write", addr_val.string);

            return formatJsonRpcResponse(allocator, id, "{\"written\":true}");
        } else {
            return formatJsonRpcError(allocator, id, INVALID_PARAMS, "action must be read or write");
        }
    }

    fn toolDisassemble(self: *McpServer, allocator: std.mem.Allocator, args: ?json.Value, id: ?json.Value) ![]const u8 {
        const a = args orelse return formatJsonRpcError(allocator, id, INVALID_PARAMS, "Missing arguments");
        if (a != .object) return formatJsonRpcError(allocator, id, INVALID_PARAMS, "Arguments must be object");

        const session_id_val = a.object.get("session_id") orelse return formatJsonRpcError(allocator, id, INVALID_PARAMS, "Missing session_id");
        if (session_id_val != .string) return formatJsonRpcError(allocator, id, INVALID_PARAMS, "session_id must be string");

        const session = self.session_manager.getSession(session_id_val.string) orelse
            return formatJsonRpcError(allocator, id, INVALID_PARAMS, "Unknown session");

        const addr_val = a.object.get("address") orelse return formatJsonRpcError(allocator, id, INVALID_PARAMS, "Missing address");
        if (addr_val != .string) return formatJsonRpcError(allocator, id, INVALID_PARAMS, "address must be string");

        const addr_str = addr_val.string;
        const trimmed = if (std.mem.startsWith(u8, addr_str, "0x") or std.mem.startsWith(u8, addr_str, "0X"))
            addr_str[2..]
        else
            addr_str;
        const address = std.fmt.parseInt(u64, trimmed, 16) catch
            return formatJsonRpcError(allocator, id, INVALID_PARAMS, "Invalid address format");

        const count: u32 = if (a.object.get("instruction_count")) |v| (if (v == .integer) @intCast(v.integer) else 10) else 10;

        const instruction_offset: ?i64 = if (a.object.get("instruction_offset")) |v| (if (v == .integer) v.integer else null) else null;
        const resolve_symbols: ?bool = if (a.object.get("resolve_symbols")) |v| (if (v == .bool) v.bool else null) else null;

        const instructions = session.driver.disassembleEx(allocator, address, count, instruction_offset, resolve_symbols) catch |err| {
            self.dashboard.onError("debug_disassemble", @errorName(err));
            return formatJsonRpcError(allocator, id, INTERNAL_ERROR, @errorName(err));
        };
        self.dashboard.onDisassemble(session_id_val.string, addr_val.string, instructions.len);

        var aw: Writer.Allocating = .init(allocator);
        defer aw.deinit();
        var s: Stringify = .{ .writer = &aw.writer };
        try s.beginObject();
        try s.objectField("instructions");
        try s.beginArray();
        for (instructions) |*inst| {
            try inst.jsonStringify(&s);
        }
        try s.endArray();
        try s.endObject();
        const result = try aw.toOwnedSlice();
        defer allocator.free(result);
        return formatJsonRpcResponse(allocator, id, result);
    }

    fn toolAttach(self: *McpServer, allocator: std.mem.Allocator, args: ?json.Value, id: ?json.Value) ![]const u8 {
        const a = args orelse return formatJsonRpcError(allocator, id, INVALID_PARAMS, "Missing arguments");
        if (a != .object) return formatJsonRpcError(allocator, id, INVALID_PARAMS, "Arguments must be object");

        const pid_val = a.object.get("pid") orelse return formatJsonRpcError(allocator, id, INVALID_PARAMS, "Missing pid");
        if (pid_val != .integer) return formatJsonRpcError(allocator, id, INVALID_PARAMS, "pid must be integer");

        // Determine driver type from language hint
        const use_dap = if (a.object.get("language")) |lang_val| blk: {
            if (lang_val == .string) {
                const lang = lang_val.string;
                if (std.mem.eql(u8, lang, "python") or
                    std.mem.eql(u8, lang, "javascript") or
                    std.mem.eql(u8, lang, "go") or
                    std.mem.eql(u8, lang, "java")) break :blk true;
            }
            break :blk false;
        } else false;

        var driver: @import("driver.zig").ActiveDriver = undefined;
        var driver_type_name: []const u8 = undefined;

        if (use_dap) {
            const dap_proxy = @import("dap/proxy.zig");
            var proxy = try allocator.create(dap_proxy.DapProxy);
            proxy.* = dap_proxy.DapProxy.init(allocator);
            errdefer {
                proxy.deinit();
                allocator.destroy(proxy);
            }

            driver = proxy.activeDriver();
            driver.attach(allocator, @intCast(pid_val.integer)) catch |err| {
                self.dashboard.onError("debug_attach", @errorName(err));
                return formatJsonRpcError(allocator, id, INTERNAL_ERROR, @errorName(err));
            };
            driver_type_name = "dap";
        } else {
            const dwarf_engine = @import("dwarf/engine.zig");
            var engine = try allocator.create(dwarf_engine.DwarfEngine);
            engine.* = dwarf_engine.DwarfEngine.init(allocator);
            errdefer {
                engine.deinit();
                allocator.destroy(engine);
            }

            driver = engine.activeDriver();
            driver.attach(allocator, @intCast(pid_val.integer)) catch |err| {
                self.dashboard.onError("debug_attach", @errorName(err));
                return formatJsonRpcError(allocator, id, INTERNAL_ERROR, @errorName(err));
            };
            driver_type_name = "native";
        }

        const session_id = try self.session_manager.createSession(driver);
        if (self.session_manager.getSession(session_id)) |s| {
            s.status = .stopped;
        }
        self.dashboard.onLaunch(session_id, "attached", driver_type_name);
        self.dashboard.onAttach(session_id, pid_val.integer);

        var aw: Writer.Allocating = .init(allocator);
        defer aw.deinit();
        var s: Stringify = .{ .writer = &aw.writer };
        try s.beginObject();
        try s.objectField("session_id");
        try s.write(session_id);
        try s.objectField("status");
        try s.write("stopped");
        try s.endObject();
        const result = try aw.toOwnedSlice();
        defer allocator.free(result);
        return formatJsonRpcResponse(allocator, id, result);
    }

    fn toolSetVariable(self: *McpServer, allocator: std.mem.Allocator, args: ?json.Value, id: ?json.Value) ![]const u8 {
        const a = args orelse return formatJsonRpcError(allocator, id, INVALID_PARAMS, "Missing arguments");
        if (a != .object) return formatJsonRpcError(allocator, id, INVALID_PARAMS, "Arguments must be object");

        const session_id_val = a.object.get("session_id") orelse return formatJsonRpcError(allocator, id, INVALID_PARAMS, "Missing session_id");
        if (session_id_val != .string) return formatJsonRpcError(allocator, id, INVALID_PARAMS, "session_id must be string");

        const session = self.session_manager.getSession(session_id_val.string) orelse
            return formatJsonRpcError(allocator, id, INVALID_PARAMS, "Unknown session");

        const var_val = a.object.get("variable") orelse return formatJsonRpcError(allocator, id, INVALID_PARAMS, "Missing variable");
        if (var_val != .string) return formatJsonRpcError(allocator, id, INVALID_PARAMS, "variable must be string");

        const value_val = a.object.get("value") orelse return formatJsonRpcError(allocator, id, INVALID_PARAMS, "Missing value");
        if (value_val != .string) return formatJsonRpcError(allocator, id, INVALID_PARAMS, "value must be string");

        const frame_id: u32 = if (a.object.get("frame_id")) |v| (if (v == .integer) @intCast(v.integer) else 0) else 0;

        const result_val = session.driver.setVariable(allocator, var_val.string, value_val.string, frame_id) catch |err| {
            self.dashboard.onError("debug_set_variable", @errorName(err));
            return formatJsonRpcError(allocator, id, INTERNAL_ERROR, @errorName(err));
        };
        self.dashboard.onSetVariable(session_id_val.string, var_val.string, value_val.string);
        defer result_val.deinit(allocator);

        var aw: Writer.Allocating = .init(allocator);
        defer aw.deinit();
        var s: Stringify = .{ .writer = &aw.writer };
        try result_val.jsonStringify(&s);
        const result = try aw.toOwnedSlice();
        defer allocator.free(result);
        return formatJsonRpcResponse(allocator, id, result);
    }

    // ── Phase 4 Tool Implementations ────────────────────────────────

    fn toolScopes(self: *McpServer, allocator: std.mem.Allocator, args: ?json.Value, id: ?json.Value) ![]const u8 {
        const a = args orelse return formatJsonRpcError(allocator, id, INVALID_PARAMS, "Missing arguments");
        if (a != .object) return formatJsonRpcError(allocator, id, INVALID_PARAMS, "Arguments must be object");

        const session_id_val = a.object.get("session_id") orelse return formatJsonRpcError(allocator, id, INVALID_PARAMS, "Missing session_id");
        if (session_id_val != .string) return formatJsonRpcError(allocator, id, INVALID_PARAMS, "session_id must be string");

        const session = self.session_manager.getSession(session_id_val.string) orelse
            return formatJsonRpcError(allocator, id, INVALID_PARAMS, "Unknown session");

        const frame_id: u32 = if (a.object.get("frame_id")) |v| (if (v == .integer) @intCast(v.integer) else 0) else 0;

        const scope_list = session.driver.scopes(allocator, frame_id) catch |err| {
            self.dashboard.onError("debug_scopes", @errorName(err));
            return formatJsonRpcError(allocator, id, INTERNAL_ERROR, @errorName(err));
        };
        self.dashboard.onScopes(session_id_val.string, scope_list.len);

        var aw: Writer.Allocating = .init(allocator);
        defer aw.deinit();
        var s: Stringify = .{ .writer = &aw.writer };
        try s.beginObject();
        try s.objectField("scopes");
        try s.beginArray();
        for (scope_list) |*sc| {
            try sc.jsonStringify(&s);
        }
        try s.endArray();
        try s.endObject();
        const result = try aw.toOwnedSlice();
        defer allocator.free(result);
        return formatJsonRpcResponse(allocator, id, result);
    }

    fn toolWatchpoint(self: *McpServer, allocator: std.mem.Allocator, args: ?json.Value, id: ?json.Value) ![]const u8 {
        const a = args orelse return formatJsonRpcError(allocator, id, INVALID_PARAMS, "Missing arguments");
        if (a != .object) return formatJsonRpcError(allocator, id, INVALID_PARAMS, "Arguments must be object");

        const session_id_val = a.object.get("session_id") orelse return formatJsonRpcError(allocator, id, INVALID_PARAMS, "Missing session_id");
        if (session_id_val != .string) return formatJsonRpcError(allocator, id, INVALID_PARAMS, "session_id must be string");

        const session = self.session_manager.getSession(session_id_val.string) orelse
            return formatJsonRpcError(allocator, id, INVALID_PARAMS, "Unknown session");

        const var_val = a.object.get("variable") orelse return formatJsonRpcError(allocator, id, INVALID_PARAMS, "Missing variable");
        if (var_val != .string) return formatJsonRpcError(allocator, id, INVALID_PARAMS, "variable must be string");

        const access_str = if (a.object.get("access_type")) |v| (if (v == .string) v.string else "write") else "write";
        const access_type = types.DataBreakpointAccessType.parse(access_str) orelse .write;

        const frame_id: ?u32 = if (a.object.get("frame_id")) |v| (if (v == .integer) @as(u32, @intCast(v.integer)) else null) else null;

        // First, get data breakpoint info
        const info = session.driver.dataBreakpointInfo(allocator, var_val.string, frame_id) catch |err| {
            self.dashboard.onError("debug_watchpoint", @errorName(err));
            return formatJsonRpcError(allocator, id, INTERNAL_ERROR, @errorName(err));
        };

        const data_id = info.data_id orelse {
            return formatJsonRpcError(allocator, id, INTERNAL_ERROR, "Variable cannot be watched");
        };

        // Then set the data breakpoint
        const bp = session.driver.setDataBreakpoint(allocator, data_id, access_type) catch |err| {
            self.dashboard.onError("debug_watchpoint", @errorName(err));
            return formatJsonRpcError(allocator, id, INTERNAL_ERROR, @errorName(err));
        };
        self.dashboard.onWatchpoint(session_id_val.string, var_val.string, access_str);

        var aw: Writer.Allocating = .init(allocator);
        defer aw.deinit();
        var s: Stringify = .{ .writer = &aw.writer };
        try s.beginObject();
        try s.objectField("breakpoint");
        try bp.jsonStringify(&s);
        try s.objectField("description");
        try s.write(info.description);
        try s.endObject();
        const result = try aw.toOwnedSlice();
        defer allocator.free(result);
        return formatJsonRpcResponse(allocator, id, result);
    }

    fn toolCapabilities(self: *McpServer, allocator: std.mem.Allocator, args: ?json.Value, id: ?json.Value) ![]const u8 {
        const a = args orelse return formatJsonRpcError(allocator, id, INVALID_PARAMS, "Missing arguments");
        if (a != .object) return formatJsonRpcError(allocator, id, INVALID_PARAMS, "Arguments must be object");

        const session_id_val = a.object.get("session_id") orelse return formatJsonRpcError(allocator, id, INVALID_PARAMS, "Missing session_id");
        if (session_id_val != .string) return formatJsonRpcError(allocator, id, INVALID_PARAMS, "session_id must be string");

        const session = self.session_manager.getSession(session_id_val.string) orelse
            return formatJsonRpcError(allocator, id, INVALID_PARAMS, "Unknown session");

        const caps = session.driver.capabilities();
        self.dashboard.onCapabilities(session_id_val.string);

        var aw: Writer.Allocating = .init(allocator);
        defer aw.deinit();
        var s: Stringify = .{ .writer = &aw.writer };
        try caps.jsonStringify(&s);
        const result = try aw.toOwnedSlice();
        defer allocator.free(result);
        return formatJsonRpcResponse(allocator, id, result);
    }

    // ── Phase 5 Tool Implementations ────────────────────────────────

    fn toolCompletions(self: *McpServer, allocator: std.mem.Allocator, args: ?json.Value, id: ?json.Value) ![]const u8 {
        const a = args orelse return formatJsonRpcError(allocator, id, INVALID_PARAMS, "Missing arguments");
        if (a != .object) return formatJsonRpcError(allocator, id, INVALID_PARAMS, "Arguments must be object");

        const session_id_val = a.object.get("session_id") orelse return formatJsonRpcError(allocator, id, INVALID_PARAMS, "Missing session_id");
        if (session_id_val != .string) return formatJsonRpcError(allocator, id, INVALID_PARAMS, "session_id must be string");

        const session = self.session_manager.getSession(session_id_val.string) orelse
            return formatJsonRpcError(allocator, id, INVALID_PARAMS, "Unknown session");

        const text_val = a.object.get("text") orelse return formatJsonRpcError(allocator, id, INVALID_PARAMS, "Missing text");
        if (text_val != .string) return formatJsonRpcError(allocator, id, INVALID_PARAMS, "text must be string");

        const column: u32 = if (a.object.get("column")) |v| (if (v == .integer) @intCast(v.integer) else 0) else 0;
        const frame_id: ?u32 = if (a.object.get("frame_id")) |v| (if (v == .integer) @as(u32, @intCast(v.integer)) else null) else null;

        const items = session.driver.completions(allocator, text_val.string, column, frame_id) catch |err| {
            self.dashboard.onError("debug_completions", @errorName(err));
            return formatJsonRpcError(allocator, id, INTERNAL_ERROR, @errorName(err));
        };
        self.dashboard.onCompletions(session_id_val.string, items.len);

        var aw: Writer.Allocating = .init(allocator);
        defer aw.deinit();
        var s: Stringify = .{ .writer = &aw.writer };
        try s.beginObject();
        try s.objectField("targets");
        try s.beginArray();
        for (items) |*item| {
            try item.jsonStringify(&s);
        }
        try s.endArray();
        try s.endObject();
        const result = try aw.toOwnedSlice();
        defer allocator.free(result);
        return formatJsonRpcResponse(allocator, id, result);
    }

    fn toolModules(self: *McpServer, allocator: std.mem.Allocator, args: ?json.Value, id: ?json.Value) ![]const u8 {
        const a = args orelse return formatJsonRpcError(allocator, id, INVALID_PARAMS, "Missing arguments");
        if (a != .object) return formatJsonRpcError(allocator, id, INVALID_PARAMS, "Arguments must be object");

        const session_id_val = a.object.get("session_id") orelse return formatJsonRpcError(allocator, id, INVALID_PARAMS, "Missing session_id");
        if (session_id_val != .string) return formatJsonRpcError(allocator, id, INVALID_PARAMS, "session_id must be string");

        const session = self.session_manager.getSession(session_id_val.string) orelse
            return formatJsonRpcError(allocator, id, INVALID_PARAMS, "Unknown session");

        const mod_list = session.driver.modules(allocator) catch |err| {
            self.dashboard.onError("debug_modules", @errorName(err));
            return formatJsonRpcError(allocator, id, INTERNAL_ERROR, @errorName(err));
        };
        self.dashboard.onModules(session_id_val.string, mod_list.len);

        var aw: Writer.Allocating = .init(allocator);
        defer aw.deinit();
        var s: Stringify = .{ .writer = &aw.writer };
        try s.beginObject();
        try s.objectField("modules");
        try s.beginArray();
        for (mod_list) |*m| {
            try m.jsonStringify(&s);
        }
        try s.endArray();
        try s.endObject();
        const result = try aw.toOwnedSlice();
        defer allocator.free(result);
        return formatJsonRpcResponse(allocator, id, result);
    }

    fn toolLoadedSources(self: *McpServer, allocator: std.mem.Allocator, args: ?json.Value, id: ?json.Value) ![]const u8 {
        const a = args orelse return formatJsonRpcError(allocator, id, INVALID_PARAMS, "Missing arguments");
        if (a != .object) return formatJsonRpcError(allocator, id, INVALID_PARAMS, "Arguments must be object");

        const session_id_val = a.object.get("session_id") orelse return formatJsonRpcError(allocator, id, INVALID_PARAMS, "Missing session_id");
        if (session_id_val != .string) return formatJsonRpcError(allocator, id, INVALID_PARAMS, "session_id must be string");

        const session = self.session_manager.getSession(session_id_val.string) orelse
            return formatJsonRpcError(allocator, id, INVALID_PARAMS, "Unknown session");

        const source_list = session.driver.loadedSources(allocator) catch |err| {
            self.dashboard.onError("debug_loaded_sources", @errorName(err));
            return formatJsonRpcError(allocator, id, INTERNAL_ERROR, @errorName(err));
        };
        self.dashboard.onLoadedSources(session_id_val.string, source_list.len);

        var aw: Writer.Allocating = .init(allocator);
        defer aw.deinit();
        var s: Stringify = .{ .writer = &aw.writer };
        try s.beginObject();
        try s.objectField("sources");
        try s.beginArray();
        for (source_list) |*src| {
            try src.jsonStringify(&s);
        }
        try s.endArray();
        try s.endObject();
        const result = try aw.toOwnedSlice();
        defer allocator.free(result);
        return formatJsonRpcResponse(allocator, id, result);
    }

    fn toolSource(self: *McpServer, allocator: std.mem.Allocator, args: ?json.Value, id: ?json.Value) ![]const u8 {
        const a = args orelse return formatJsonRpcError(allocator, id, INVALID_PARAMS, "Missing arguments");
        if (a != .object) return formatJsonRpcError(allocator, id, INVALID_PARAMS, "Arguments must be object");

        const session_id_val = a.object.get("session_id") orelse return formatJsonRpcError(allocator, id, INVALID_PARAMS, "Missing session_id");
        if (session_id_val != .string) return formatJsonRpcError(allocator, id, INVALID_PARAMS, "session_id must be string");

        const session = self.session_manager.getSession(session_id_val.string) orelse
            return formatJsonRpcError(allocator, id, INVALID_PARAMS, "Unknown session");

        const ref_val = a.object.get("source_reference") orelse return formatJsonRpcError(allocator, id, INVALID_PARAMS, "Missing source_reference");
        if (ref_val != .integer) return formatJsonRpcError(allocator, id, INVALID_PARAMS, "source_reference must be integer");

        const content = session.driver.source(allocator, @intCast(ref_val.integer)) catch |err| {
            self.dashboard.onError("debug_source", @errorName(err));
            return formatJsonRpcError(allocator, id, INTERNAL_ERROR, @errorName(err));
        };

        var aw: Writer.Allocating = .init(allocator);
        defer aw.deinit();
        var s: Stringify = .{ .writer = &aw.writer };
        try s.beginObject();
        try s.objectField("content");
        try s.write(content);
        try s.endObject();
        const result = try aw.toOwnedSlice();
        defer allocator.free(result);
        return formatJsonRpcResponse(allocator, id, result);
    }

    fn toolSetExpression(self: *McpServer, allocator: std.mem.Allocator, args: ?json.Value, id: ?json.Value) ![]const u8 {
        const a = args orelse return formatJsonRpcError(allocator, id, INVALID_PARAMS, "Missing arguments");
        if (a != .object) return formatJsonRpcError(allocator, id, INVALID_PARAMS, "Arguments must be object");

        const session_id_val = a.object.get("session_id") orelse return formatJsonRpcError(allocator, id, INVALID_PARAMS, "Missing session_id");
        if (session_id_val != .string) return formatJsonRpcError(allocator, id, INVALID_PARAMS, "session_id must be string");

        const session = self.session_manager.getSession(session_id_val.string) orelse
            return formatJsonRpcError(allocator, id, INVALID_PARAMS, "Unknown session");

        const expr_val = a.object.get("expression") orelse return formatJsonRpcError(allocator, id, INVALID_PARAMS, "Missing expression");
        if (expr_val != .string) return formatJsonRpcError(allocator, id, INVALID_PARAMS, "expression must be string");

        const value_val = a.object.get("value") orelse return formatJsonRpcError(allocator, id, INVALID_PARAMS, "Missing value");
        if (value_val != .string) return formatJsonRpcError(allocator, id, INVALID_PARAMS, "value must be string");

        const frame_id: u32 = if (a.object.get("frame_id")) |v| (if (v == .integer) @intCast(v.integer) else 0) else 0;

        const result_val = session.driver.setExpression(allocator, expr_val.string, value_val.string, frame_id) catch |err| {
            self.dashboard.onError("debug_set_expression", @errorName(err));
            return formatJsonRpcError(allocator, id, INTERNAL_ERROR, @errorName(err));
        };
        defer result_val.deinit(allocator);

        var aw: Writer.Allocating = .init(allocator);
        defer aw.deinit();
        var s: Stringify = .{ .writer = &aw.writer };
        try result_val.jsonStringify(&s);
        const result = try aw.toOwnedSlice();
        defer allocator.free(result);
        return formatJsonRpcResponse(allocator, id, result);
    }

    // ── Phase 6 Tool Implementations ────────────────────────────────

    fn toolRestartFrame(self: *McpServer, allocator: std.mem.Allocator, args: ?json.Value, id: ?json.Value) ![]const u8 {
        const a = args orelse return formatJsonRpcError(allocator, id, INVALID_PARAMS, "Missing arguments");
        if (a != .object) return formatJsonRpcError(allocator, id, INVALID_PARAMS, "Arguments must be object");

        const session_id_val = a.object.get("session_id") orelse return formatJsonRpcError(allocator, id, INVALID_PARAMS, "Missing session_id");
        if (session_id_val != .string) return formatJsonRpcError(allocator, id, INVALID_PARAMS, "session_id must be string");

        const session = self.session_manager.getSession(session_id_val.string) orelse
            return formatJsonRpcError(allocator, id, INVALID_PARAMS, "Unknown session");

        const frame_id_val = a.object.get("frame_id") orelse return formatJsonRpcError(allocator, id, INVALID_PARAMS, "Missing frame_id");
        if (frame_id_val != .integer) return formatJsonRpcError(allocator, id, INVALID_PARAMS, "frame_id must be integer");

        session.driver.restartFrame(allocator, @intCast(frame_id_val.integer)) catch |err| {
            self.dashboard.onError("debug_restart_frame", @errorName(err));
            return formatJsonRpcError(allocator, id, INTERNAL_ERROR, @errorName(err));
        };
        self.dashboard.onRestartFrame(session_id_val.string, @intCast(frame_id_val.integer));

        return formatJsonRpcResponse(allocator, id, "{\"restarted\":true}");
    }

    // ── Phase 7 Tool Implementations ────────────────────────────────

    fn toolExceptionInfo(self: *McpServer, allocator: std.mem.Allocator, args: ?json.Value, id: ?json.Value) ![]const u8 {
        const a = args orelse return formatJsonRpcError(allocator, id, INVALID_PARAMS, "Missing arguments");
        if (a != .object) return formatJsonRpcError(allocator, id, INVALID_PARAMS, "Arguments must be object");

        const session_id_val = a.object.get("session_id") orelse return formatJsonRpcError(allocator, id, INVALID_PARAMS, "Missing session_id");
        if (session_id_val != .string) return formatJsonRpcError(allocator, id, INVALID_PARAMS, "session_id must be string");

        const session = self.session_manager.getSession(session_id_val.string) orelse
            return formatJsonRpcError(allocator, id, INVALID_PARAMS, "Unknown session");

        const thread_id: u32 = if (a.object.get("thread_id")) |v| (if (v == .integer) @intCast(v.integer) else 1) else 1;

        const info = session.driver.exceptionInfo(allocator, thread_id) catch |err| {
            self.dashboard.onError("debug_exception_info", @errorName(err));
            return formatJsonRpcError(allocator, id, INTERNAL_ERROR, @errorName(err));
        };
        self.dashboard.onExceptionInfo(session_id_val.string);

        var aw: Writer.Allocating = .init(allocator);
        defer aw.deinit();
        var s: Stringify = .{ .writer = &aw.writer };
        try info.jsonStringify(&s);
        const result = try aw.toOwnedSlice();
        defer allocator.free(result);
        return formatJsonRpcResponse(allocator, id, result);
    }

    fn toolRegisters(self: *McpServer, allocator: std.mem.Allocator, args: ?json.Value, id: ?json.Value) ![]const u8 {
        const a = args orelse return formatJsonRpcError(allocator, id, INVALID_PARAMS, "Missing arguments");
        if (a != .object) return formatJsonRpcError(allocator, id, INVALID_PARAMS, "Arguments must be object");

        const session_id_val = a.object.get("session_id") orelse return formatJsonRpcError(allocator, id, INVALID_PARAMS, "Missing session_id");
        if (session_id_val != .string) return formatJsonRpcError(allocator, id, INVALID_PARAMS, "session_id must be string");

        const session = self.session_manager.getSession(session_id_val.string) orelse
            return formatJsonRpcError(allocator, id, INVALID_PARAMS, "Unknown session");

        const thread_id: u32 = if (a.object.get("thread_id")) |v| (if (v == .integer) @intCast(v.integer) else 1) else 1;

        const regs = session.driver.readRegisters(allocator, thread_id) catch |err| {
            self.dashboard.onError("debug_registers", @errorName(err));
            return formatJsonRpcError(allocator, id, INTERNAL_ERROR, @errorName(err));
        };
        self.dashboard.onRegisters(session_id_val.string, regs.len);

        var aw: Writer.Allocating = .init(allocator);
        defer aw.deinit();
        var s: Stringify = .{ .writer = &aw.writer };
        try s.beginObject();
        try s.objectField("registers");
        try s.beginArray();
        for (regs) |*r| {
            try r.jsonStringify(&s);
        }
        try s.endArray();
        try s.endObject();
        const result = try aw.toOwnedSlice();
        defer allocator.free(result);
        return formatJsonRpcResponse(allocator, id, result);
    }

    // ── Phase 12 Tool Implementations ────────────────────────────────

    fn toolInstructionBreakpoint(self: *McpServer, allocator: std.mem.Allocator, args: ?json.Value, id: ?json.Value) ![]const u8 {
        const a = args orelse return formatJsonRpcError(allocator, id, INVALID_PARAMS, "Missing arguments");
        if (a != .object) return formatJsonRpcError(allocator, id, INVALID_PARAMS, "Arguments must be object");

        const session_id_val = a.object.get("session_id") orelse return formatJsonRpcError(allocator, id, INVALID_PARAMS, "Missing session_id");
        if (session_id_val != .string) return formatJsonRpcError(allocator, id, INVALID_PARAMS, "session_id must be string");

        const session = self.session_manager.getSession(session_id_val.string) orelse
            return formatJsonRpcError(allocator, id, INVALID_PARAMS, "Unknown session");

        // Support both single breakpoint and batch array
        var bp_list = std.ArrayListUnmanaged(types.InstructionBreakpoint).empty;
        defer bp_list.deinit(allocator);

        if (a.object.get("breakpoints")) |bps_val| {
            // Batch mode: array of instruction breakpoints
            if (bps_val == .array) {
                for (bps_val.array.items) |item| {
                    if (item != .object) continue;
                    const bp_obj = item.object;
                    const ref = if (bp_obj.get("instruction_reference")) |v| (if (v == .string) v.string else continue) else continue;
                    try bp_list.append(allocator, .{
                        .instruction_reference = ref,
                        .offset = if (bp_obj.get("offset")) |v| (if (v == .integer) v.integer else null) else null,
                        .condition = if (bp_obj.get("condition")) |v| (if (v == .string) v.string else null) else null,
                        .hit_condition = if (bp_obj.get("hit_condition")) |v| (if (v == .string) v.string else null) else null,
                    });
                }
            }
        }

        if (bp_list.items.len == 0) {
            // Single breakpoint mode (backward compatible)
            const instr_ref_val = a.object.get("instruction_reference") orelse return formatJsonRpcError(allocator, id, INVALID_PARAMS, "Missing instruction_reference or breakpoints array");
            if (instr_ref_val != .string) return formatJsonRpcError(allocator, id, INVALID_PARAMS, "instruction_reference must be string");

            try bp_list.append(allocator, .{
                .instruction_reference = instr_ref_val.string,
                .offset = if (a.object.get("offset")) |v| (if (v == .integer) v.integer else null) else null,
                .condition = if (a.object.get("condition")) |v| (if (v == .string) v.string else null) else null,
                .hit_condition = if (a.object.get("hit_condition")) |v| (if (v == .string) v.string else null) else null,
            });
        }

        const results = session.driver.setInstructionBreakpoints(allocator, bp_list.items) catch |err| {
            self.dashboard.onError("debug_instruction_breakpoint", @errorName(err));
            return formatJsonRpcError(allocator, id, INTERNAL_ERROR, @errorName(err));
        };
        const first_ref = if (bp_list.items.len > 0) bp_list.items[0].instruction_reference else "";
        self.dashboard.onInstructionBreakpoint(session_id_val.string, first_ref, results.len);

        var aw: Writer.Allocating = .init(allocator);
        defer aw.deinit();
        var s: Stringify = .{ .writer = &aw.writer };
        try s.beginObject();
        try s.objectField("breakpoints");
        try s.beginArray();
        for (results) |*b| {
            try b.jsonStringify(&s);
        }
        try s.endArray();
        try s.endObject();
        const result = try aw.toOwnedSlice();
        defer allocator.free(result);
        return formatJsonRpcResponse(allocator, id, result);
    }

    fn toolStepInTargets(self: *McpServer, allocator: std.mem.Allocator, args: ?json.Value, id: ?json.Value) ![]const u8 {
        const a = args orelse return formatJsonRpcError(allocator, id, INVALID_PARAMS, "Missing arguments");
        if (a != .object) return formatJsonRpcError(allocator, id, INVALID_PARAMS, "Arguments must be object");

        const session_id_val = a.object.get("session_id") orelse return formatJsonRpcError(allocator, id, INVALID_PARAMS, "Missing session_id");
        if (session_id_val != .string) return formatJsonRpcError(allocator, id, INVALID_PARAMS, "session_id must be string");

        const session = self.session_manager.getSession(session_id_val.string) orelse
            return formatJsonRpcError(allocator, id, INVALID_PARAMS, "Unknown session");

        const frame_id_val = a.object.get("frame_id") orelse return formatJsonRpcError(allocator, id, INVALID_PARAMS, "Missing frame_id");
        if (frame_id_val != .integer) return formatJsonRpcError(allocator, id, INVALID_PARAMS, "frame_id must be integer");

        const targets = session.driver.stepInTargets(allocator, @intCast(frame_id_val.integer)) catch |err| {
            self.dashboard.onError("debug_step_in_targets", @errorName(err));
            return formatJsonRpcError(allocator, id, INTERNAL_ERROR, @errorName(err));
        };
        self.dashboard.onStepInTargets(session_id_val.string, @intCast(frame_id_val.integer), targets.len);

        var aw: Writer.Allocating = .init(allocator);
        defer aw.deinit();
        var s: Stringify = .{ .writer = &aw.writer };
        try s.beginObject();
        try s.objectField("targets");
        try s.beginArray();
        for (targets) |*t| {
            try t.jsonStringify(&s);
        }
        try s.endArray();
        try s.endObject();
        const result = try aw.toOwnedSlice();
        defer allocator.free(result);
        return formatJsonRpcResponse(allocator, id, result);
    }

    fn toolBreakpointLocations(self: *McpServer, allocator: std.mem.Allocator, args: ?json.Value, id: ?json.Value) ![]const u8 {
        const a = args orelse return formatJsonRpcError(allocator, id, INVALID_PARAMS, "Missing arguments");
        if (a != .object) return formatJsonRpcError(allocator, id, INVALID_PARAMS, "Arguments must be object");

        const session_id_val = a.object.get("session_id") orelse return formatJsonRpcError(allocator, id, INVALID_PARAMS, "Missing session_id");
        if (session_id_val != .string) return formatJsonRpcError(allocator, id, INVALID_PARAMS, "session_id must be string");

        const session = self.session_manager.getSession(session_id_val.string) orelse
            return formatJsonRpcError(allocator, id, INVALID_PARAMS, "Unknown session");

        const source_val = a.object.get("source") orelse return formatJsonRpcError(allocator, id, INVALID_PARAMS, "Missing source");
        if (source_val != .string) return formatJsonRpcError(allocator, id, INVALID_PARAMS, "source must be string");

        const line_val = a.object.get("line") orelse return formatJsonRpcError(allocator, id, INVALID_PARAMS, "Missing line");
        if (line_val != .integer) return formatJsonRpcError(allocator, id, INVALID_PARAMS, "line must be integer");

        const end_line: ?u32 = if (a.object.get("end_line")) |v| (if (v == .integer) @as(u32, @intCast(v.integer)) else null) else null;

        const locations = session.driver.breakpointLocations(allocator, source_val.string, @intCast(line_val.integer), end_line) catch |err| {
            self.dashboard.onError("debug_breakpoint_locations", @errorName(err));
            return formatJsonRpcError(allocator, id, INTERNAL_ERROR, @errorName(err));
        };
        self.dashboard.onBreakpointLocations(session_id_val.string, source_val.string, @intCast(line_val.integer), locations.len);

        var aw: Writer.Allocating = .init(allocator);
        defer aw.deinit();
        var s: Stringify = .{ .writer = &aw.writer };
        try s.beginObject();
        try s.objectField("breakpoints");
        try s.beginArray();
        for (locations) |*loc| {
            try loc.jsonStringify(&s);
        }
        try s.endArray();
        try s.endObject();
        const result = try aw.toOwnedSlice();
        defer allocator.free(result);
        return formatJsonRpcResponse(allocator, id, result);
    }

    fn toolCancel(self: *McpServer, allocator: std.mem.Allocator, args: ?json.Value, id: ?json.Value) ![]const u8 {
        const a = args orelse return formatJsonRpcError(allocator, id, INVALID_PARAMS, "Missing arguments");
        if (a != .object) return formatJsonRpcError(allocator, id, INVALID_PARAMS, "Arguments must be object");

        const session_id_val = a.object.get("session_id") orelse return formatJsonRpcError(allocator, id, INVALID_PARAMS, "Missing session_id");
        if (session_id_val != .string) return formatJsonRpcError(allocator, id, INVALID_PARAMS, "session_id must be string");

        const session = self.session_manager.getSession(session_id_val.string) orelse
            return formatJsonRpcError(allocator, id, INVALID_PARAMS, "Unknown session");

        const request_id: ?u32 = if (a.object.get("request_id")) |v| (if (v == .integer) @as(u32, @intCast(v.integer)) else null) else null;
        const progress_id: ?[]const u8 = if (a.object.get("progress_id")) |v| (if (v == .string) v.string else null) else null;

        session.driver.cancel(allocator, request_id, progress_id) catch |err| {
            self.dashboard.onError("debug_cancel", @errorName(err));
            return formatJsonRpcError(allocator, id, INTERNAL_ERROR, @errorName(err));
        };
        self.dashboard.onCancel(session_id_val.string);

        return formatJsonRpcResponse(allocator, id, "{\"cancelled\":true}");
    }

    fn toolTerminateThreads(self: *McpServer, allocator: std.mem.Allocator, args: ?json.Value, id: ?json.Value) ![]const u8 {
        const a = args orelse return formatJsonRpcError(allocator, id, INVALID_PARAMS, "Missing arguments");
        if (a != .object) return formatJsonRpcError(allocator, id, INVALID_PARAMS, "Arguments must be object");

        const session_id_val = a.object.get("session_id") orelse return formatJsonRpcError(allocator, id, INVALID_PARAMS, "Missing session_id");
        if (session_id_val != .string) return formatJsonRpcError(allocator, id, INVALID_PARAMS, "session_id must be string");

        const session = self.session_manager.getSession(session_id_val.string) orelse
            return formatJsonRpcError(allocator, id, INVALID_PARAMS, "Unknown session");

        const ids_val = a.object.get("thread_ids") orelse return formatJsonRpcError(allocator, id, INVALID_PARAMS, "Missing thread_ids");
        if (ids_val != .array) return formatJsonRpcError(allocator, id, INVALID_PARAMS, "thread_ids must be array");

        var id_list = std.ArrayListUnmanaged(u32).empty;
        defer id_list.deinit(allocator);
        for (ids_val.array.items) |item| {
            if (item == .integer) {
                try id_list.append(allocator, @intCast(item.integer));
            }
        }

        session.driver.terminateThreads(allocator, id_list.items) catch |err| {
            self.dashboard.onError("debug_terminate_threads", @errorName(err));
            return formatJsonRpcError(allocator, id, INTERNAL_ERROR, @errorName(err));
        };
        self.dashboard.onTerminateThreads(session_id_val.string, id_list.items.len);

        return formatJsonRpcResponse(allocator, id, "{\"terminated\":true}");
    }

    fn toolRestart(self: *McpServer, allocator: std.mem.Allocator, args: ?json.Value, id: ?json.Value) ![]const u8 {
        const a = args orelse return formatJsonRpcError(allocator, id, INVALID_PARAMS, "Missing arguments");
        if (a != .object) return formatJsonRpcError(allocator, id, INVALID_PARAMS, "Arguments must be object");

        const session_id_val = a.object.get("session_id") orelse return formatJsonRpcError(allocator, id, INVALID_PARAMS, "Missing session_id");
        if (session_id_val != .string) return formatJsonRpcError(allocator, id, INVALID_PARAMS, "session_id must be string");

        const session = self.session_manager.getSession(session_id_val.string) orelse
            return formatJsonRpcError(allocator, id, INVALID_PARAMS, "Unknown session");

        session.driver.restart(allocator) catch |err| {
            self.dashboard.onError("debug_restart", @errorName(err));
            return formatJsonRpcError(allocator, id, INTERNAL_ERROR, @errorName(err));
        };
        self.dashboard.onRestart(session_id_val.string);

        return formatJsonRpcResponse(allocator, id, "{\"restarted\":true}");

    }

    // ── Stop Snapshot Recording ─────────────────────────────────────────

    fn recordStopSnapshot(self: *McpServer, allocator: std.mem.Allocator, session_id: []const u8, state: types.StopState) void {
        // Serialize locals to JSON for later comparison
        var aw: Writer.Allocating = .init(allocator);
        defer aw.deinit();
        var jw: Stringify = .{ .writer = &aw.writer };
        jw.beginArray() catch return;
        for (state.locals) |*v| {
            v.jsonStringify(&jw) catch return;
        }
        jw.endArray() catch return;
        const locals_json = aw.toOwnedSlice() catch return;

        // Free previous snapshot's locals_json at this ring buffer position
        if (self.stop_history[self.stop_history_idx]) |prev| {
            allocator.free(prev.locals_json);
            allocator.free(prev.session_id);
        }

        const sid = allocator.dupe(u8, session_id) catch {
            allocator.free(locals_json);
            return;
        };

        self.stop_history[self.stop_history_idx] = .{
            .session_id = sid,
            .stop_reason = state.stop_reason,
            .locals_json = locals_json,
            .stack_depth = @intCast(state.stack_trace.len),
        };
        self.stop_history_idx = (self.stop_history_idx + 1) % 8;
    }

    // ── Phase 4: New Tool Implementations ────────────────────────────────

    fn toolSessions(self: *McpServer, allocator: std.mem.Allocator, id: ?json.Value) ![]const u8 {
        const sessions = self.session_manager.listSessions(allocator) catch |err| {
            return formatJsonRpcError(allocator, id, INTERNAL_ERROR, @errorName(err));
        };
        defer allocator.free(sessions);

        var aw: Writer.Allocating = .init(allocator);
        defer aw.deinit();
        var jw: Stringify = .{ .writer = &aw.writer };
        try jw.beginArray();
        for (sessions) |*s| {
            try jw.beginObject();
            try jw.objectField("id");
            try jw.write(s.id);
            try jw.objectField("status");
            try jw.write(@tagName(s.status));
            try jw.objectField("driver_type");
            try jw.write(@tagName(s.driver_type));
            try jw.endObject();
        }
        try jw.endArray();
        const result = try aw.toOwnedSlice();
        defer allocator.free(result);
        return formatJsonRpcResponse(allocator, id, result);
    }

    fn toolRootCause(self: *McpServer, allocator: std.mem.Allocator, args: ?json.Value, id: ?json.Value) ![]const u8 {
        const a = args orelse return formatJsonRpcError(allocator, id, INVALID_PARAMS, "Missing arguments");
        if (a != .object) return formatJsonRpcError(allocator, id, INVALID_PARAMS, "Arguments must be object");

        const session_id_val = a.object.get("session_id") orelse return formatJsonRpcError(allocator, id, INVALID_PARAMS, "Missing session_id");
        if (session_id_val != .string) return formatJsonRpcError(allocator, id, INVALID_PARAMS, "session_id must be string");

        const session = self.session_manager.getSession(session_id_val.string) orelse
            return formatJsonRpcError(allocator, id, INVALID_PARAMS, "Unknown session");

        const max_frames: u32 = if (a.object.get("max_frames")) |v| (if (v == .integer) @intCast(v.integer) else 5) else 5;

        var aw: Writer.Allocating = .init(allocator);
        defer aw.deinit();
        var jw: Stringify = .{ .writer = &aw.writer };
        try jw.beginObject();

        // 1. Get exception info (use thread 0 as default)
        if (session.driver.exceptionInfo(allocator, 0)) |exc_info| {
            try jw.objectField("exception");
            try exc_info.jsonStringify(&jw);
        } else |_| {
            // No exception info available — not an error
        }

        // 2. Get stack trace
        const frames = session.driver.stackTrace(allocator, 0, 0, max_frames) catch |err| {
            try jw.objectField("error");
            try jw.write(@errorName(err));
            try jw.endObject();
            const result = try aw.toOwnedSlice();
            defer allocator.free(result);
            return formatJsonRpcResponse(allocator, id, result);
        };

        try jw.objectField("frames");
        try jw.beginArray();
        for (frames) |*frame| {
            try jw.beginObject();
            try jw.objectField("id");
            try jw.write(frame.id);
            try jw.objectField("name");
            try jw.write(frame.name);
            try jw.objectField("source");
            try jw.write(frame.source);
            try jw.objectField("line");
            try jw.write(frame.line);

            // 3. Get scopes + locals for each frame
            if (session.driver.scopes(allocator, frame.id)) |frame_scopes| {
                try jw.objectField("scopes");
                try jw.beginArray();
                for (frame_scopes) |*scope| {
                    try jw.beginObject();
                    try jw.objectField("name");
                    try jw.write(scope.name);
                    // Get variables for non-expensive scopes
                    if (!scope.expensive and scope.variables_reference > 0) {
                        const inspect_result = session.driver.inspect(allocator, .{
                            .variable_ref = scope.variables_reference,
                            .frame_id = frame.id,
                        }) catch null;
                        if (inspect_result) |ir| {
                            defer ir.deinit(allocator);
                            if (ir.children.len > 0) {
                                try jw.objectField("variables");
                                try jw.beginArray();
                                for (ir.children) |*child| {
                                    try child.jsonStringify(&jw);
                                }
                                try jw.endArray();
                            }
                        }
                    }
                    try jw.endObject();
                }
                try jw.endArray();
            } else |_| {}

            try jw.endObject();
        }
        try jw.endArray();

        try jw.objectField("total_frames");
        try jw.write(frames.len);

        try jw.endObject();
        const result = try aw.toOwnedSlice();
        defer allocator.free(result);
        return formatJsonRpcResponse(allocator, id, result);
    }

    fn toolStateDelta(self: *McpServer, allocator: std.mem.Allocator, args: ?json.Value, id: ?json.Value) ![]const u8 {
        const a = args orelse return formatJsonRpcError(allocator, id, INVALID_PARAMS, "Missing arguments");
        if (a != .object) return formatJsonRpcError(allocator, id, INVALID_PARAMS, "Arguments must be object");

        const session_id_val = a.object.get("session_id") orelse return formatJsonRpcError(allocator, id, INVALID_PARAMS, "Missing session_id");
        if (session_id_val != .string) return formatJsonRpcError(allocator, id, INVALID_PARAMS, "session_id must be string");

        // Verify session exists
        _ = self.session_manager.getSession(session_id_val.string) orelse
            return formatJsonRpcError(allocator, id, INVALID_PARAMS, "Unknown session");

        // Find the two most recent snapshots for this session
        var current: ?StopSnapshot = null;
        var previous: ?StopSnapshot = null;

        // Walk backwards from most recent entry
        var i: u8 = 0;
        while (i < 8) : (i += 1) {
            const idx = (self.stop_history_idx + 7 - i) % 8;
            if (self.stop_history[idx]) |snap| {
                if (std.mem.eql(u8, snap.session_id, session_id_val.string)) {
                    if (current == null) {
                        current = snap;
                    } else if (previous == null) {
                        previous = snap;
                        break;
                    }
                }
            }
        }

        var aw: Writer.Allocating = .init(allocator);
        defer aw.deinit();
        var jw: Stringify = .{ .writer = &aw.writer };

        if (current == null) {
            // No snapshots available
            try jw.beginObject();
            try jw.objectField("available");
            try jw.write(false);
            try jw.objectField("message");
            try jw.write("No stop states recorded for this session");
            try jw.endObject();
            const result = try aw.toOwnedSlice();
            defer allocator.free(result);
            return formatJsonRpcResponse(allocator, id, result);
        }

        const cur = current.?;
        try jw.beginObject();
        try jw.objectField("available");
        try jw.write(true);
        try jw.objectField("stop_reason");
        try jw.write(@tagName(cur.stop_reason));

        if (previous) |prev| {
            try jw.objectField("stack_depth_change");
            try jw.write(@as(i32, @intCast(cur.stack_depth)) - @as(i32, @intCast(prev.stack_depth)));
            try jw.objectField("previous_stop_reason");
            try jw.write(@tagName(prev.stop_reason));
            try jw.objectField("current_locals");
            try jw.writer.writeAll(cur.locals_json);
            try jw.objectField("previous_locals");
            try jw.writer.writeAll(prev.locals_json);
        } else {
            try jw.objectField("stack_depth");
            try jw.write(cur.stack_depth);
            try jw.objectField("current_locals");
            try jw.writer.writeAll(cur.locals_json);
            try jw.objectField("message");
            try jw.write("Only one stop state available, no delta to compute");
        }

        try jw.endObject();
        const result = try aw.toOwnedSlice();
        defer allocator.free(result);
        return formatJsonRpcResponse(allocator, id, result);
    }

    fn toolGotoTargets(self: *McpServer, allocator: std.mem.Allocator, args: ?json.Value, id: ?json.Value) ![]const u8 {
        const a = args orelse return formatJsonRpcError(allocator, id, INVALID_PARAMS, "Missing arguments");
        if (a != .object) return formatJsonRpcError(allocator, id, INVALID_PARAMS, "Arguments must be object");

        const session_id_val = a.object.get("session_id") orelse return formatJsonRpcError(allocator, id, INVALID_PARAMS, "Missing session_id");
        if (session_id_val != .string) return formatJsonRpcError(allocator, id, INVALID_PARAMS, "session_id must be string");

        const session = self.session_manager.getSession(session_id_val.string) orelse
            return formatJsonRpcError(allocator, id, INVALID_PARAMS, "Unknown session");

        const file_val = a.object.get("file") orelse return formatJsonRpcError(allocator, id, INVALID_PARAMS, "Missing file");
        if (file_val != .string) return formatJsonRpcError(allocator, id, INVALID_PARAMS, "file must be string");

        const line_val = a.object.get("line") orelse return formatJsonRpcError(allocator, id, INVALID_PARAMS, "Missing line");
        if (line_val != .integer) return formatJsonRpcError(allocator, id, INVALID_PARAMS, "line must be integer");

        const targets = session.driver.gotoTargets(allocator, file_val.string, @intCast(line_val.integer)) catch |err| {
            self.dashboard.onError("debug_goto_targets", @errorName(err));
            return formatJsonRpcError(allocator, id, INTERNAL_ERROR, @errorName(err));
        };

        var aw: Writer.Allocating = .init(allocator);
        defer aw.deinit();
        var jw: Stringify = .{ .writer = &aw.writer };
        try jw.beginArray();
        for (targets) |*t| {
            try t.jsonStringify(&jw);
        }
        try jw.endArray();
        const result = try aw.toOwnedSlice();
        defer allocator.free(result);
        return formatJsonRpcResponse(allocator, id, result);
    }

    fn toolFindSymbol(self: *McpServer, allocator: std.mem.Allocator, args: ?json.Value, id: ?json.Value) ![]const u8 {
        const a = args orelse return formatJsonRpcError(allocator, id, INVALID_PARAMS, "Missing arguments");
        if (a != .object) return formatJsonRpcError(allocator, id, INVALID_PARAMS, "Arguments must be object");

        const session_id_val = a.object.get("session_id") orelse return formatJsonRpcError(allocator, id, INVALID_PARAMS, "Missing session_id");
        if (session_id_val != .string) return formatJsonRpcError(allocator, id, INVALID_PARAMS, "session_id must be string");

        const session = self.session_manager.getSession(session_id_val.string) orelse
            return formatJsonRpcError(allocator, id, INVALID_PARAMS, "Unknown session");

        const name_val = a.object.get("name") orelse return formatJsonRpcError(allocator, id, INVALID_PARAMS, "Missing name");
        if (name_val != .string) return formatJsonRpcError(allocator, id, INVALID_PARAMS, "name must be string");

        const symbols = session.driver.findSymbol(allocator, name_val.string) catch |err| {
            self.dashboard.onError("debug_find_symbol", @errorName(err));
            return formatJsonRpcError(allocator, id, INTERNAL_ERROR, @errorName(err));
        };

        var aw: Writer.Allocating = .init(allocator);
        defer aw.deinit();
        var jw: Stringify = .{ .writer = &aw.writer };
        try jw.beginArray();
        for (symbols) |*s| {
            try s.jsonStringify(&jw);
        }
        try jw.endArray();
        const result = try aw.toOwnedSlice();
        defer allocator.free(result);
        return formatJsonRpcResponse(allocator, id, result);
    }

    // ── Phase 6: DWARF Engine Tools ─────────────────────────────────────

    fn toolWriteRegister(self: *McpServer, allocator: std.mem.Allocator, args: ?json.Value, id: ?json.Value) ![]const u8 {
        const a = args orelse return formatJsonRpcError(allocator, id, INVALID_PARAMS, "Missing arguments");
        if (a != .object) return formatJsonRpcError(allocator, id, INVALID_PARAMS, "Arguments must be object");

        const session_id_val = a.object.get("session_id") orelse return formatJsonRpcError(allocator, id, INVALID_PARAMS, "Missing session_id");
        if (session_id_val != .string) return formatJsonRpcError(allocator, id, INVALID_PARAMS, "session_id must be string");

        const session = self.session_manager.getSession(session_id_val.string) orelse
            return formatJsonRpcError(allocator, id, INVALID_PARAMS, "Unknown session");

        const name_val = a.object.get("name") orelse return formatJsonRpcError(allocator, id, INVALID_PARAMS, "Missing name");
        if (name_val != .string) return formatJsonRpcError(allocator, id, INVALID_PARAMS, "name must be string");

        const value_val = a.object.get("value") orelse return formatJsonRpcError(allocator, id, INVALID_PARAMS, "Missing value");
        if (value_val != .integer) return formatJsonRpcError(allocator, id, INVALID_PARAMS, "value must be integer");

        session.driver.writeRegisters(allocator, 0, name_val.string, @intCast(value_val.integer)) catch |err| {
            self.dashboard.onError("debug_write_register", @errorName(err));
            return formatJsonRpcError(allocator, id, INTERNAL_ERROR, @errorName(err));
        };

        return formatJsonRpcResponse(allocator, id, "{\"written\":true}");
    }

    fn toolVariableLocation(self: *McpServer, allocator: std.mem.Allocator, args: ?json.Value, id: ?json.Value) ![]const u8 {
        const a = args orelse return formatJsonRpcError(allocator, id, INVALID_PARAMS, "Missing arguments");
        if (a != .object) return formatJsonRpcError(allocator, id, INVALID_PARAMS, "Arguments must be object");

        const session_id_val = a.object.get("session_id") orelse return formatJsonRpcError(allocator, id, INVALID_PARAMS, "Missing session_id");
        if (session_id_val != .string) return formatJsonRpcError(allocator, id, INVALID_PARAMS, "session_id must be string");

        const session = self.session_manager.getSession(session_id_val.string) orelse
            return formatJsonRpcError(allocator, id, INVALID_PARAMS, "Unknown session");

        const name_val = a.object.get("name") orelse return formatJsonRpcError(allocator, id, INVALID_PARAMS, "Missing name");
        if (name_val != .string) return formatJsonRpcError(allocator, id, INVALID_PARAMS, "name must be string");

        const frame_id: u32 = if (a.object.get("frame_id")) |v| (if (v == .integer) @intCast(v.integer) else 0) else 0;

        const loc = session.driver.variableLocation(allocator, name_val.string, frame_id) catch |err| {
            self.dashboard.onError("debug_variable_location", @errorName(err));
            return formatJsonRpcError(allocator, id, INTERNAL_ERROR, @errorName(err));
        };

        var aw: Writer.Allocating = .init(allocator);
        defer aw.deinit();
        var jw: Stringify = .{ .writer = &aw.writer };
        try loc.jsonStringify(&jw);
        const result = try aw.toOwnedSlice();
        defer allocator.free(result);
        return formatJsonRpcResponse(allocator, id, result);
    }

    fn toolSuggestBreakpoints(self: *McpServer, allocator: std.mem.Allocator, args: ?json.Value, id: ?json.Value) ![]const u8 {
        const a = args orelse return formatJsonRpcError(allocator, id, INVALID_PARAMS, "Missing arguments");
        if (a != .object) return formatJsonRpcError(allocator, id, INVALID_PARAMS, "Arguments must be object");

        const session_id_val = a.object.get("session_id") orelse return formatJsonRpcError(allocator, id, INVALID_PARAMS, "Missing session_id");
        if (session_id_val != .string) return formatJsonRpcError(allocator, id, INVALID_PARAMS, "session_id must be string");

        const session = self.session_manager.getSession(session_id_val.string) orelse
            return formatJsonRpcError(allocator, id, INVALID_PARAMS, "Unknown session");

        const query_val = a.object.get("query") orelse return formatJsonRpcError(allocator, id, INVALID_PARAMS, "Missing query");
        if (query_val != .string) return formatJsonRpcError(allocator, id, INVALID_PARAMS, "query must be string");

        const suggestions = session.driver.suggestBreakpoints(allocator, query_val.string) catch |err| {
            self.dashboard.onError("debug_suggest_breakpoints", @errorName(err));
            return formatJsonRpcError(allocator, id, INTERNAL_ERROR, @errorName(err));
        };

        var aw: Writer.Allocating = .init(allocator);
        defer aw.deinit();
        var jw: Stringify = .{ .writer = &aw.writer };
        try jw.beginArray();
        for (suggestions) |*s| {
            try s.jsonStringify(&jw);
        }
        try jw.endArray();
        const result = try aw.toOwnedSlice();
        defer allocator.free(result);
        return formatJsonRpcResponse(allocator, id, result);
    }

    fn toolExpandMacro(self: *McpServer, allocator: std.mem.Allocator, args: ?json.Value, id: ?json.Value) ![]const u8 {
        const a = args orelse return formatJsonRpcError(allocator, id, INVALID_PARAMS, "Missing arguments");
        if (a != .object) return formatJsonRpcError(allocator, id, INVALID_PARAMS, "Arguments must be object");

        const session_id_val = a.object.get("session_id") orelse return formatJsonRpcError(allocator, id, INVALID_PARAMS, "Missing session_id");
        if (session_id_val != .string) return formatJsonRpcError(allocator, id, INVALID_PARAMS, "session_id must be string");

        const session = self.session_manager.getSession(session_id_val.string) orelse
            return formatJsonRpcError(allocator, id, INVALID_PARAMS, "Unknown session");

        const name_val = a.object.get("name") orelse return formatJsonRpcError(allocator, id, INVALID_PARAMS, "Missing name");
        if (name_val != .string) return formatJsonRpcError(allocator, id, INVALID_PARAMS, "name must be string");

        const expansion = session.driver.expandMacro(allocator, name_val.string) catch |err| {
            self.dashboard.onError("debug_expand_macro", @errorName(err));
            return formatJsonRpcError(allocator, id, INTERNAL_ERROR, @errorName(err));
        };

        var aw: Writer.Allocating = .init(allocator);
        defer aw.deinit();
        var jw: Stringify = .{ .writer = &aw.writer };
        try expansion.jsonStringify(&jw);
        const result = try aw.toOwnedSlice();
        defer allocator.free(result);
        return formatJsonRpcResponse(allocator, id, result);
    }

    fn toolDiffState(self: *McpServer, allocator: std.mem.Allocator, args: ?json.Value, id: ?json.Value) ![]const u8 {
        const a = args orelse return formatJsonRpcError(allocator, id, INVALID_PARAMS, "Missing arguments");
        if (a != .object) return formatJsonRpcError(allocator, id, INVALID_PARAMS, "Arguments must be object");

        const sid_a_val = a.object.get("session_id_a") orelse return formatJsonRpcError(allocator, id, INVALID_PARAMS, "Missing session_id_a");
        if (sid_a_val != .string) return formatJsonRpcError(allocator, id, INVALID_PARAMS, "session_id_a must be string");

        const sid_b_val = a.object.get("session_id_b") orelse return formatJsonRpcError(allocator, id, INVALID_PARAMS, "Missing session_id_b");
        if (sid_b_val != .string) return formatJsonRpcError(allocator, id, INVALID_PARAMS, "session_id_b must be string");

        const session_a = self.session_manager.getSession(sid_a_val.string) orelse
            return formatJsonRpcError(allocator, id, INVALID_PARAMS, "Unknown session_id_a");
        const session_b = self.session_manager.getSession(sid_b_val.string) orelse
            return formatJsonRpcError(allocator, id, INVALID_PARAMS, "Unknown session_id_b");

        var aw: Writer.Allocating = .init(allocator);
        defer aw.deinit();
        var jw: Stringify = .{ .writer = &aw.writer };
        try jw.beginObject();

        // Compare stack traces
        if (session_a.driver.stackTrace(allocator, 0, 0, 10)) |frames_a| {
            if (session_b.driver.stackTrace(allocator, 0, 0, 10)) |frames_b| {
                try jw.objectField("stack_depth_a");
                try jw.write(frames_a.len);
                try jw.objectField("stack_depth_b");
                try jw.write(frames_b.len);
            } else |_| {}
        } else |_| {}

        // Compare status
        try jw.objectField("status_a");
        try jw.write(@tagName(session_a.status));
        try jw.objectField("status_b");
        try jw.write(@tagName(session_b.status));

        try jw.endObject();
        const result = try aw.toOwnedSlice();
        defer allocator.free(result);
        return formatJsonRpcResponse(allocator, id, result);
    }

    // ── Phase 9: AI-Specific Composite Tools ─────────────────────────────

    fn toolValueHistory(self: *McpServer, allocator: std.mem.Allocator, args: ?json.Value, id: ?json.Value) ![]const u8 {
        const a = args orelse return formatJsonRpcError(allocator, id, INVALID_PARAMS, "Missing arguments");
        if (a != .object) return formatJsonRpcError(allocator, id, INVALID_PARAMS, "Arguments must be object");

        const session_id_val = a.object.get("session_id") orelse return formatJsonRpcError(allocator, id, INVALID_PARAMS, "Missing session_id");
        if (session_id_val != .string) return formatJsonRpcError(allocator, id, INVALID_PARAMS, "session_id must be string");

        _ = self.session_manager.getSession(session_id_val.string) orelse
            return formatJsonRpcError(allocator, id, INVALID_PARAMS, "Unknown session");

        const var_name_val = a.object.get("variable") orelse return formatJsonRpcError(allocator, id, INVALID_PARAMS, "Missing variable");
        if (var_name_val != .string) return formatJsonRpcError(allocator, id, INVALID_PARAMS, "variable must be string");
        const var_name = var_name_val.string;

        const max_entries: u32 = if (a.object.get("max_entries")) |v| (if (v == .integer) @intCast(v.integer) else 10) else 10;

        // Walk the stop_history ring buffer and show locals at each snapshot for this session
        var aw: Writer.Allocating = .init(allocator);
        defer aw.deinit();
        var jw: Stringify = .{ .writer = &aw.writer };
        try jw.beginObject();
        try jw.objectField("variable");
        try jw.write(var_name);
        try jw.objectField("history");
        try jw.beginArray();

        var count: u32 = 0;
        var i: u8 = 0;
        while (i < 8 and count < max_entries) : (i += 1) {
            const idx = (self.stop_history_idx + 7 - i) % 8;
            if (self.stop_history[idx]) |snap| {
                if (std.mem.eql(u8, snap.session_id, session_id_val.string)) {
                    try jw.beginObject();
                    try jw.objectField("stop_index");
                    try jw.write(i);
                    try jw.objectField("stop_reason");
                    try jw.write(@tagName(snap.stop_reason));
                    // Include the locals snapshot so the caller can find the variable
                    try jw.objectField("locals_snapshot");
                    try jw.writer.writeAll(snap.locals_json);
                    try jw.endObject();
                    count += 1;
                }
            }
        }

        try jw.endArray();
        try jw.objectField("entries_found");
        try jw.write(count);
        try jw.endObject();
        const result = try aw.toOwnedSlice();
        defer allocator.free(result);
        return formatJsonRpcResponse(allocator, id, result);
    }

    fn toolExecutionTrace(self: *McpServer, allocator: std.mem.Allocator, args: ?json.Value, id: ?json.Value) ![]const u8 {
        const a = args orelse return formatJsonRpcError(allocator, id, INVALID_PARAMS, "Missing arguments");
        if (a != .object) return formatJsonRpcError(allocator, id, INVALID_PARAMS, "Arguments must be object");

        const session_id_val = a.object.get("session_id") orelse return formatJsonRpcError(allocator, id, INVALID_PARAMS, "Missing session_id");
        if (session_id_val != .string) return formatJsonRpcError(allocator, id, INVALID_PARAMS, "session_id must be string");

        const session = self.session_manager.getSession(session_id_val.string) orelse
            return formatJsonRpcError(allocator, id, INVALID_PARAMS, "Unknown session");

        const max_stops: u32 = if (a.object.get("max_stops")) |v| (if (v == .integer) @intCast(v.integer) else 8) else 8;

        var aw: Writer.Allocating = .init(allocator);
        defer aw.deinit();
        var jw: Stringify = .{ .writer = &aw.writer };
        try jw.beginObject();
        try jw.objectField("trace");
        try jw.beginArray();

        // Walk recent stop history for this session
        var count: u32 = 0;
        var i: u8 = 0;
        while (i < 8 and count < max_stops) : (i += 1) {
            const idx = (self.stop_history_idx + 7 - i) % 8;
            if (self.stop_history[idx]) |snap| {
                if (std.mem.eql(u8, snap.session_id, session_id_val.string)) {
                    try jw.beginObject();
                    try jw.objectField("stop_index");
                    try jw.write(i);
                    try jw.objectField("stop_reason");
                    try jw.write(@tagName(snap.stop_reason));
                    try jw.objectField("stack_depth");
                    try jw.write(snap.stack_depth);
                    try jw.endObject();
                    count += 1;
                }
            }
        }

        try jw.endArray();

        // Also include the current live stack trace
        try jw.objectField("current_stack");
        if (session.driver.stackTrace(allocator, 0, 0, 20)) |frames| {
            try jw.beginArray();
            for (frames) |*frame| {
                try jw.beginObject();
                try jw.objectField("id");
                try jw.write(frame.id);
                try jw.objectField("name");
                try jw.write(frame.name);
                try jw.objectField("source");
                try jw.write(frame.source);
                try jw.objectField("line");
                try jw.write(frame.line);
                try jw.endObject();
            }
            try jw.endArray();
        } else |_| {
            try jw.beginArray();
            try jw.endArray();
        }

        try jw.objectField("stops_found");
        try jw.write(count);
        try jw.endObject();
        const result = try aw.toOwnedSlice();
        defer allocator.free(result);
        return formatJsonRpcResponse(allocator, id, result);
    }

    fn toolHypothesisTest(self: *McpServer, allocator: std.mem.Allocator, args: ?json.Value, id: ?json.Value) ![]const u8 {
        const a = args orelse return formatJsonRpcError(allocator, id, INVALID_PARAMS, "Missing arguments");
        if (a != .object) return formatJsonRpcError(allocator, id, INVALID_PARAMS, "Arguments must be object");

        const session_id_val = a.object.get("session_id") orelse return formatJsonRpcError(allocator, id, INVALID_PARAMS, "Missing session_id");
        if (session_id_val != .string) return formatJsonRpcError(allocator, id, INVALID_PARAMS, "session_id must be string");

        const session = self.session_manager.getSession(session_id_val.string) orelse
            return formatJsonRpcError(allocator, id, INVALID_PARAMS, "Unknown session");

        const file_val = a.object.get("file") orelse return formatJsonRpcError(allocator, id, INVALID_PARAMS, "Missing file");
        if (file_val != .string) return formatJsonRpcError(allocator, id, INVALID_PARAMS, "file must be string");

        const line_val = a.object.get("line") orelse return formatJsonRpcError(allocator, id, INVALID_PARAMS, "Missing line");
        if (line_val != .integer) return formatJsonRpcError(allocator, id, INVALID_PARAMS, "line must be integer");

        const condition: ?[]const u8 = if (a.object.get("condition")) |v| (if (v == .string) v.string else null) else null;
        const expression: ?[]const u8 = if (a.object.get("expression")) |v| (if (v == .string) v.string else null) else null;
        const max_hits: u32 = if (a.object.get("max_hits")) |v| (if (v == .integer) @intCast(v.integer) else 5) else 5;

        var aw: Writer.Allocating = .init(allocator);
        defer aw.deinit();
        var jw: Stringify = .{ .writer = &aw.writer };
        try jw.beginObject();

        // 1. Set temporary breakpoint with condition
        const bp = session.driver.setBreakpointEx(
            allocator,
            file_val.string,
            @intCast(line_val.integer),
            condition,
            null,
            null,
        ) catch |err| {
            try jw.objectField("error");
            try jw.write("Failed to set breakpoint");
            try jw.objectField("detail");
            try jw.write(@errorName(err));
            try jw.endObject();
            const result = try aw.toOwnedSlice();
            defer allocator.free(result);
            return formatJsonRpcResponse(allocator, id, result);
        };

        try jw.objectField("breakpoint_id");
        try jw.write(bp.id);
        try jw.objectField("hits");
        try jw.beginArray();

        // 2. Run and collect hits
        var hit_count: u32 = 0;
        var run_error: ?[]const u8 = null;
        var final_stop_reason: ?[]const u8 = null;
        while (hit_count < max_hits) {
            const stop = session.driver.run(allocator, .@"continue") catch |err| {
                run_error = @errorName(err);
                break;
            };

            // Check if we stopped at our breakpoint
            if (stop.stop_reason != .breakpoint) {
                final_stop_reason = @tagName(stop.stop_reason);
                break;
            }

            try jw.beginObject();
            try jw.objectField("hit");
            try jw.write(hit_count + 1);

            // 3. Evaluate expression if provided
            if (expression) |expr| {
                const eval_result = session.driver.inspect(allocator, .{
                    .expression = expr,
                    .frame_id = 0,
                }) catch null;
                if (eval_result) |ir| {
                    defer ir.deinit(allocator);
                    try jw.objectField("expression");
                    try jw.write(expr);
                    try jw.objectField("value");
                    try jw.write(ir.result);
                    if (ir.@"type".len > 0) {
                        try jw.objectField("type");
                        try jw.write(ir.@"type");
                    }
                }
            }

            // Include stop location
            if (stop.location) |loc| {
                try jw.objectField("file");
                try jw.write(loc.file);
                try jw.objectField("line");
                try jw.write(loc.line);
            }

            try jw.endObject();
            hit_count += 1;
        }
        try jw.endArray();

        if (run_error) |err_name| {
            try jw.objectField("run_error");
            try jw.write(err_name);
        }
        if (final_stop_reason) |reason| {
            try jw.objectField("stopped_reason");
            try jw.write(reason);
        }

        try jw.objectField("total_hits");
        try jw.write(hit_count);

        // 4. Remove the temporary breakpoint
        session.driver.removeBreakpoint(allocator, bp.id) catch |err| {
            try jw.objectField("cleanup_error");
            try jw.write(@errorName(err));
        };

        try jw.objectField("breakpoint_removed");
        try jw.write(true);

        try jw.endObject();
        const result = try aw.toOwnedSlice();
        defer allocator.free(result);
        return formatJsonRpcResponse(allocator, id, result);
    }

    fn toolDeadlockDetect(self: *McpServer, allocator: std.mem.Allocator, args: ?json.Value, id: ?json.Value) ![]const u8 {
        const a = args orelse return formatJsonRpcError(allocator, id, INVALID_PARAMS, "Missing arguments");
        if (a != .object) return formatJsonRpcError(allocator, id, INVALID_PARAMS, "Arguments must be object");

        const session_id_val = a.object.get("session_id") orelse return formatJsonRpcError(allocator, id, INVALID_PARAMS, "Missing session_id");
        if (session_id_val != .string) return formatJsonRpcError(allocator, id, INVALID_PARAMS, "session_id must be string");

        const session = self.session_manager.getSession(session_id_val.string) orelse
            return formatJsonRpcError(allocator, id, INVALID_PARAMS, "Unknown session");

        var aw: Writer.Allocating = .init(allocator);
        defer aw.deinit();
        var jw: Stringify = .{ .writer = &aw.writer };
        try jw.beginObject();

        // 1. Get all threads
        const thread_list = session.driver.threads(allocator) catch |err| {
            try jw.objectField("error");
            try jw.write("Failed to list threads");
            try jw.objectField("detail");
            try jw.write(@errorName(err));
            try jw.endObject();
            const result = try aw.toOwnedSlice();
            defer allocator.free(result);
            return formatJsonRpcResponse(allocator, id, result);
        };

        try jw.objectField("thread_count");
        try jw.write(thread_list.len);
        try jw.objectField("threads");
        try jw.beginArray();

        // 2. For each thread, get stack trace and look for blocking patterns
        var blocked_count: u32 = 0;
        for (thread_list) |*thread| {
            try jw.beginObject();
            try jw.objectField("id");
            try jw.write(thread.id);
            try jw.objectField("name");
            try jw.write(thread.name);

            // Get stack trace for this thread
            if (session.driver.stackTrace(allocator, thread.id, 0, 10)) |frames| {
                try jw.objectField("stack_depth");
                try jw.write(frames.len);
                try jw.objectField("top_frames");
                try jw.beginArray();

                var is_blocked = false;
                for (frames, 0..) |*frame, fi| {
                    if (fi >= 5) break; // Top 5 frames only
                    try jw.beginObject();
                    try jw.objectField("name");
                    try jw.write(frame.name);
                    try jw.objectField("source");
                    try jw.write(frame.source);
                    try jw.objectField("line");
                    try jw.write(frame.line);
                    try jw.endObject();

                    // Heuristic: look for common blocking function names
                    if (containsBlockingPattern(frame.name)) {
                        is_blocked = true;
                    }
                }
                try jw.endArray();

                try jw.objectField("appears_blocked");
                try jw.write(is_blocked);
                if (is_blocked) blocked_count += 1;
            } else |_| {
                try jw.objectField("stack_error");
                try jw.write(true);
            }

            try jw.endObject();
        }

        try jw.endArray();

        // 3. Summary analysis
        try jw.objectField("blocked_threads");
        try jw.write(blocked_count);
        try jw.objectField("potential_deadlock");
        try jw.write(blocked_count >= 2);
        if (blocked_count >= 2) {
            try jw.objectField("analysis");
            try jw.write("Multiple threads appear to be blocked on synchronization primitives. This may indicate a deadlock. Examine the stack traces to identify the lock ordering.");
        } else if (blocked_count == 1) {
            try jw.objectField("analysis");
            try jw.write("One thread appears blocked. This may be normal waiting behavior or a single-thread hang.");
        } else {
            try jw.objectField("analysis");
            try jw.write("No threads appear to be blocked on synchronization primitives.");
        }

        try jw.endObject();
        const result = try aw.toOwnedSlice();
        defer allocator.free(result);
        return formatJsonRpcResponse(allocator, id, result);
    }

    fn containsBlockingPattern(name: []const u8) bool {
        const patterns = [_][]const u8{
            "pthread_mutex_lock",
            "pthread_cond_wait",
            "pthread_rwlock",
            "__lll_lock_wait",
            "futex_wait",
            "sem_wait",
            "WaitForSingleObject",
            "WaitForMultipleObjects",
            "EnterCriticalSection",
            "std.Thread.Mutex.lock",
            "Mutex.lock",
            "RwLock.lock",
            "Semaphore.wait",
            "__lock",
            "lock_slow",
            "epoll_wait",
            "select",
            "poll",
            "recv",
            "accept",
        };
        for (patterns) |pat| {
            if (std.mem.indexOf(u8, name, pat) != null) return true;
        }
        return false;
    }

    // ── Audit & Safety ──────────────────────────────────────────────────

    fn isMutatingTool(name: []const u8) bool {
        const mutating = [_][]const u8{
            "debug_set_variable",
            "debug_memory",
            "debug_write_register",
            "debug_set_expression",
            "debug_run",
            "debug_breakpoint",
            "debug_watchpoint",
            "debug_instruction_breakpoint",
        };
        for (mutating) |m| {
            if (std.mem.eql(u8, name, m)) return true;
        }
        return false;
    }

    fn recordAudit(self: *McpServer, tool_name: []const u8, args: ?json.Value) !void {
        const session_id = if (args) |a| blk: {
            if (a == .object) {
                if (a.object.get("session_id")) |v| {
                    if (v == .string) break :blk try self.allocator.dupe(u8, v.string);
                }
            }
            break :blk try self.allocator.dupe(u8, "");
        } else try self.allocator.dupe(u8, "");

        // Build compact details from args using allocating writer
        const details: []const u8 = if (args) |a| blk: {
            var aw: Writer.Allocating = .init(self.allocator);
            errdefer aw.deinit();
            var s: Stringify = .{ .writer = &aw.writer };
            s.write(a) catch {
                aw.deinit();
                break :blk try self.allocator.dupe(u8, "");
            };
            break :blk aw.toOwnedSlice() catch try self.allocator.dupe(u8, "");
        } else try self.allocator.dupe(u8, "");

        try self.audit_log.append(self.allocator, .{
            .timestamp_ms = std.time.milliTimestamp(),
            .tool_name = try self.allocator.dupe(u8, tool_name),
            .session_id = session_id,
            .details = details,
        });

        // Cap audit log at 1000 entries
        if (self.audit_log.items.len > 1000) {
            const entry = self.audit_log.orderedRemove(0);
            self.allocator.free(entry.tool_name);
            self.allocator.free(entry.session_id);
            self.allocator.free(entry.details);
        }
    }

    fn toolAuditLog(self: *McpServer, allocator: std.mem.Allocator, args: ?json.Value, id: ?json.Value) ![]const u8 {
        var limit: usize = 50;
        if (args) |a| {
            if (a == .object) {
                if (a.object.get("limit")) |v| {
                    if (v == .integer and v.integer > 0) limit = @intCast(v.integer);
                }
            }
        }

        var aw: Writer.Allocating = .init(allocator);
        defer aw.deinit();
        var jw: Stringify = .{ .writer = &aw.writer };

        try jw.beginObject();
        try jw.objectField("entries");
        try jw.beginArray();

        const start = if (self.audit_log.items.len > limit) self.audit_log.items.len - limit else 0;
        for (self.audit_log.items[start..]) |entry| {
            try jw.beginObject();
            try jw.objectField("timestamp_ms");
            try jw.write(entry.timestamp_ms);
            try jw.objectField("tool");
            try jw.write(entry.tool_name);
            try jw.objectField("session_id");
            try jw.write(entry.session_id);
            try jw.objectField("details");
            try jw.write(entry.details);
            try jw.endObject();
        }

        try jw.endArray();
        try jw.objectField("total");
        try jw.write(self.audit_log.items.len);
        try jw.endObject();

        const result = try aw.toOwnedSlice();
        defer allocator.free(result);
        return formatJsonRpcResponse(allocator, id, result);
    }

    // ── Event Polling ──────────────────────────────────────────────────

    fn toolPollEvents(self: *McpServer, allocator: std.mem.Allocator, args: ?json.Value, id: ?json.Value) ![]const u8 {
        const session_id_filter: ?[]const u8 = if (args) |a| blk: {
            if (a == .object) {
                if (a.object.get("session_id")) |v| {
                    if (v == .string) break :blk v.string;
                }
            }
            break :blk null;
        } else null;

        var aw: Writer.Allocating = .init(allocator);
        defer aw.deinit();
        var jw: Stringify = .{ .writer = &aw.writer };

        try jw.beginObject();
        try jw.objectField("events");
        try jw.beginArray();

        // Collect notifications from all or specific sessions
        var it = self.session_manager.sessions.iterator();
        while (it.next()) |entry| {
            if (session_id_filter) |filter| {
                if (!std.mem.eql(u8, entry.key_ptr.*, filter)) continue;
            }
            const notifications = entry.value_ptr.*.driver.drainNotifications(allocator);
            defer {
                for (notifications) |n| {
                    allocator.free(n.method);
                    allocator.free(n.params_json);
                }
                allocator.free(notifications);
            }
            for (notifications) |n| {
                try jw.beginObject();
                try jw.objectField("session_id");
                try jw.write(entry.key_ptr.*);
                try jw.objectField("method");
                try jw.write(n.method);
                try jw.objectField("params");
                // Write raw JSON params
                try jw.writer.writeAll(n.params_json);
                try jw.endObject();
            }
        }

        try jw.endArray();
        try jw.endObject();

        const result = try aw.toOwnedSlice();
        defer allocator.free(result);
        return formatJsonRpcResponse(allocator, id, result);
    }

    // ── Prompts ──────────────────────────────────────────────────────────

    fn handlePromptsList(self: *McpServer, allocator: std.mem.Allocator, id: ?json.Value) ![]const u8 {
        _ = self;
        const result =
            \\{"prompts":[
            \\{"name":"diagnose-crash","description":"Diagnose a crash by examining exception info, stack trace, locals, and execution history"},
            \\{"name":"trace-data-flow","description":"Trace how a variable's value changes through execution using value history and breakpoints"},
            \\{"name":"find-root-cause","description":"Systematically find the root cause of a bug using hypothesis testing and state deltas"},
            \\{"name":"compare-runs","description":"Compare two debug sessions to find behavioral differences"},
            \\{"name":"detect-memory-corruption","description":"Investigate memory corruption using watchpoints, memory reads, and execution tracing"},
            \\{"name":"detect-deadlock","description":"Analyze threads for potential deadlocks and blocking patterns"},
            \\{"name":"hypothesis-driven-debug","description":"Test a hypothesis about a bug by setting conditional breakpoints and collecting evidence"},
            \\{"name":"trace-execution-path","description":"Trace the execution path through a program to understand control flow"}
            \\]}
        ;
        return formatJsonRpcResponse(allocator, id, result);
    }

    fn handlePromptsGet(self: *McpServer, allocator: std.mem.Allocator, params: ?json.Value, id: ?json.Value) ![]const u8 {
        _ = self;
        const p = params orelse return formatJsonRpcError(allocator, id, INVALID_PARAMS, "Missing params");
        if (p != .object) return formatJsonRpcError(allocator, id, INVALID_PARAMS, "Params must be object");

        const name_val = p.object.get("name") orelse return formatJsonRpcError(allocator, id, INVALID_PARAMS, "Missing name");
        if (name_val != .string) return formatJsonRpcError(allocator, id, INVALID_PARAMS, "name must be string");

        const prompt_text = if (std.mem.eql(u8, name_val.string, "diagnose-crash"))
            \\{"description":"Diagnose a crash","messages":[{"role":"user","content":{"type":"text","text":"A crash occurred. Follow these steps:\n1. Use debug_exception_info to get the exception details\n2. Use debug_root_cause to analyze the full stack with locals at each frame\n3. Use debug_execution_trace to see what function calls led to the crash\n4. Use debug_value_history to check if any variables changed unexpectedly before the crash\n5. Use debug_registers to check CPU state if it's a low-level crash (segfault, illegal instruction)\n6. Report the likely cause, the chain of events that led to it, and suggest a fix."}}]}
        else if (std.mem.eql(u8, name_val.string, "trace-data-flow"))
            \\{"description":"Trace data flow","messages":[{"role":"user","content":{"type":"text","text":"Trace how a variable changes through execution:\n1. Use debug_value_history to see how the variable changed across recent stops\n2. Use debug_suggest_breakpoints to find assignment sites for the variable\n3. Use debug_hypothesis_test to set conditional breakpoints at those sites and collect values\n4. Use debug_variable_location to check where the variable is stored (register, stack, heap)\n5. If the value is corrupted, use debug_memory to read the raw memory at that location\n6. Report the complete sequence of value changes with source locations and identify where the unexpected change occurs."}}]}
        else if (std.mem.eql(u8, name_val.string, "find-root-cause"))
            \\{"description":"Find root cause","messages":[{"role":"user","content":{"type":"text","text":"Systematically find the root cause of a bug:\n1. Use debug_root_cause for initial stack and locals analysis\n2. Use debug_state_delta to compare what changed between the last two stops\n3. Use debug_execution_trace to understand the recent call sequence\n4. Formulate a hypothesis about the cause\n5. Use debug_hypothesis_test to set a conditional breakpoint that tests your theory\n6. Use debug_value_history to verify the variable behavior matches your hypothesis\n7. If the hypothesis fails, use debug_find_symbol to explore related code and try again\n8. Report the root cause with evidence from each step."}}]}
        else if (std.mem.eql(u8, name_val.string, "compare-runs"))
            \\{"description":"Compare runs","messages":[{"role":"user","content":{"type":"text","text":"Compare two debug sessions to find where behavior diverges:\n1. Use debug_sessions to list all active sessions\n2. Use debug_diff_state with both session IDs to compare stack traces and status\n3. For each session, use debug_execution_trace to get the call sequence\n4. For each session, use debug_value_history on key variables to compare their evolution\n5. Use debug_stacktrace on both sessions to compare call stacks at equivalent points\n6. Report the first point of divergence and the differences in variable state."}}]}
        else if (std.mem.eql(u8, name_val.string, "detect-memory-corruption"))
            \\{"description":"Detect memory corruption","messages":[{"role":"user","content":{"type":"text","text":"Investigate potential memory corruption:\n1. Use debug_memory to read the suspected corrupted memory region\n2. Use debug_watchpoint to set a data breakpoint on the corrupted address\n3. Use debug_run to continue execution until the watchpoint triggers\n4. Use debug_root_cause to analyze the stack at the point of corruption\n5. Use debug_execution_trace to see what code path led to the write\n6. Use debug_memory_diff to compare memory before and after the corruption\n7. Use debug_disassemble at the writing instruction to verify the operation\n8. Report what wrote to the memory, from where, and whether it was an out-of-bounds write, use-after-free, or other corruption pattern."}}]}
        else if (std.mem.eql(u8, name_val.string, "detect-deadlock"))
            \\{"description":"Detect deadlock","messages":[{"role":"user","content":{"type":"text","text":"Analyze the program for deadlocks:\n1. Use debug_deadlock_detect to scan all threads for blocking patterns\n2. For any blocked threads, use debug_stacktrace to get full call stacks\n3. Use debug_inspect to examine lock/mutex variables visible in each thread's scope\n4. Use debug_scopes on each blocked frame to find synchronization primitives\n5. Use debug_variable_location to find where locks are stored in memory\n6. Map out the wait-for graph: which thread holds which lock and is waiting for which other lock\n7. Report whether a deadlock cycle exists, which threads are involved, and the lock ordering that caused it."}}]}
        else if (std.mem.eql(u8, name_val.string, "hypothesis-driven-debug"))
            \\{"description":"Hypothesis-driven debugging","messages":[{"role":"user","content":{"type":"text","text":"Test a specific debugging hypothesis:\n1. State your hypothesis clearly (e.g., 'the crash happens when x > 100')\n2. Use debug_find_symbol to locate the relevant code\n3. Use debug_breakpoint_locations to find valid breakpoint positions near the code\n4. Use debug_hypothesis_test to set a conditional breakpoint and collect evidence\n5. Analyze the collected hit data - do the values support or refute the hypothesis?\n6. Use debug_value_history to see if the variable's trend matches expectations\n7. If refuted, formulate a new hypothesis based on the evidence and repeat\n8. Report: hypothesis, evidence collected, conclusion, and suggested fix."}}]}
        else if (std.mem.eql(u8, name_val.string, "trace-execution-path"))
            \\{"description":"Trace execution path","messages":[{"role":"user","content":{"type":"text","text":"Trace the execution path through the program:\n1. Use debug_execution_trace to get the sequence of recent stops and call depths\n2. Use debug_stacktrace to get the current full call stack\n3. For key functions in the stack, use debug_callers and debug_callees to map the call graph\n4. Use debug_breakpoint_locations to find decision points (branches, conditions)\n5. Use debug_hypothesis_test at branch points to determine which paths are taken\n6. Use debug_step_in_targets to see what functions are called at each step\n7. Report the complete execution path with source locations and key decision points."}}]}
        else
            return formatJsonRpcError(allocator, id, INVALID_PARAMS, "Unknown prompt name");

        return formatJsonRpcResponse(allocator, id, prompt_text);
    }

    // ── Stdio Transport ─────────────────────────────────────────────────

    pub fn runStdio(self: *McpServer) !void {
        const stdin = std.fs.File.stdin();
        const stdout = std.fs.File.stdout();
        var reader_buf: [65536]u8 = undefined;
        var reader = stdin.reader(&reader_buf);

        // Initial render
        self.dashboard.render();

        while (true) {
            const line = reader.interface.takeDelimiter('\n') catch |err| switch (err) {
                error.ReadFailed => return,
                error.StreamTooLong => continue,
            } orelse return; // null = EOF

            if (line.len == 0) continue;

            // Parse JSON-RPC
            const parsed = parseJsonRpc(self.allocator, line) catch {
                const err_resp = try formatJsonRpcError(self.allocator, null, PARSE_ERROR, "Parse error");
                defer self.allocator.free(err_resp);
                var write_buf: [65536]u8 = undefined;
                var w = stdout.writer(&write_buf);
                w.interface.writeAll(err_resp) catch {};
                w.interface.writeByte('\n') catch {};
                w.interface.flush() catch {};
                self.dashboard.onError("parse", "Parse error");
                self.dashboard.render();
                continue;
            };
            defer parsed.deinit(self.allocator);

            const response = try self.handleRequest(self.allocator, parsed.method, parsed.params, parsed.id);
            defer self.allocator.free(response);

            var write_buf: [65536]u8 = undefined;
            var w = stdout.writer(&write_buf);
            w.interface.writeAll(response) catch {};
            w.interface.writeByte('\n') catch {};

            // Emit any pending notifications after tool call
            self.collectNotifications();
            for (self.pending_notification_lines.items) |notif_line| {
                w.interface.writeAll(notif_line) catch {};
                w.interface.writeByte('\n') catch {};
                self.allocator.free(notif_line);
            }
            self.pending_notification_lines.items.len = 0;

            w.interface.flush() catch {};

            self.dashboard.render();
        }
    }
};

// ── Tests ───────────────────────────────────────────────────────────────

test "parseJsonRpc extracts method and params from valid request" {
    const allocator = std.testing.allocator;
    const input =
        \\{"jsonrpc":"2.0","id":1,"method":"tools/list","params":{}}
    ;
    const req = try parseJsonRpc(allocator, input);
    defer req.deinit(allocator);

    try std.testing.expectEqualStrings("tools/list", req.method);
}

test "parseJsonRpc returns error for missing method" {
    const allocator = std.testing.allocator;
    const input =
        \\{"jsonrpc":"2.0","id":1}
    ;
    const result = parseJsonRpc(allocator, input);
    try std.testing.expectError(error.MissingMethod, result);
}

test "parseJsonRpc handles request without params" {
    const allocator = std.testing.allocator;
    const input =
        \\{"jsonrpc":"2.0","id":1,"method":"initialize"}
    ;
    const req = try parseJsonRpc(allocator, input);
    defer req.deinit(allocator);

    try std.testing.expectEqualStrings("initialize", req.method);
    try std.testing.expect(req.params == null);
}

test "formatJsonRpcError produces error response with code" {
    const allocator = std.testing.allocator;
    const result = try formatJsonRpcError(allocator, null, METHOD_NOT_FOUND, "Method not found");
    defer allocator.free(result);

    const parsed = try json.parseFromSlice(json.Value, allocator, result, .{});
    defer parsed.deinit();
    const obj = parsed.value.object;

    try std.testing.expectEqualStrings("2.0", obj.get("jsonrpc").?.string);
    const err_obj = obj.get("error").?.object;
    try std.testing.expectEqual(@as(i64, METHOD_NOT_FOUND), err_obj.get("code").?.integer);
    try std.testing.expectEqualStrings("Method not found", err_obj.get("message").?.string);
}

test "handleInitialize returns server capabilities" {
    const allocator = std.testing.allocator;
    var mcp = McpServer.init(allocator);
    defer mcp.deinit();

    const response = try mcp.handleRequest(allocator, "initialize", null, null);
    defer allocator.free(response);

    const parsed = try json.parseFromSlice(json.Value, allocator, response, .{});
    defer parsed.deinit();
    const obj = parsed.value.object;

    const result = obj.get("result").?.object;
    try std.testing.expectEqualStrings("cog-debug", result.get("serverInfo").?.object.get("name").?.string);
}

test "handleToolsList returns 10 debug tools with schemas" {
    const allocator = std.testing.allocator;
    var mcp = McpServer.init(allocator);
    defer mcp.deinit();

    const response = try mcp.handleRequest(allocator, "tools/list", null, null);
    defer allocator.free(response);

    const parsed = try json.parseFromSlice(json.Value, allocator, response, .{});
    defer parsed.deinit();
    const obj = parsed.value.object;
    const result = obj.get("result").?.object;
    const tools = result.get("tools").?.array;

    try std.testing.expectEqual(@as(usize, 44), tools.items.len);

    const expected_names = [_][]const u8{ "debug_launch", "debug_breakpoint", "debug_run", "debug_inspect", "debug_stop", "debug_threads", "debug_stacktrace", "debug_memory", "debug_disassemble", "debug_attach", "debug_set_variable", "debug_scopes", "debug_watchpoint", "debug_capabilities", "debug_completions", "debug_modules", "debug_loaded_sources", "debug_source", "debug_set_expression", "debug_restart_frame", "debug_exception_info", "debug_registers", "debug_instruction_breakpoint", "debug_step_in_targets", "debug_breakpoint_locations", "debug_cancel", "debug_terminate_threads", "debug_restart", "debug_sessions", "debug_root_cause", "debug_state_delta", "debug_goto_targets", "debug_find_symbol", "debug_write_register", "debug_variable_location", "debug_suggest_breakpoints", "debug_expand_macro", "debug_diff_state", "debug_value_history", "debug_execution_trace", "debug_hypothesis_test", "debug_deadlock_detect", "debug_audit_log", "debug_poll_events" };
    for (tools.items, 0..) |tool, i| {
        try std.testing.expectEqualStrings(expected_names[i], tool.object.get("name").?.string);
    }
}

test "handleToolsCall dispatches to correct tool handler" {
    const allocator = std.testing.allocator;
    var mcp = McpServer.init(allocator);
    defer mcp.deinit();

    // debug_stop with unknown session should return a result (stopped:true)
    const params_str =
        \\{"name":"debug_stop","arguments":{"session_id":"nonexistent"}}
    ;
    const params_parsed = try json.parseFromSlice(json.Value, allocator, params_str, .{});
    defer params_parsed.deinit();

    const response = try mcp.handleRequest(allocator, "tools/call", params_parsed.value, null);
    defer allocator.free(response);

    const parsed = try json.parseFromSlice(json.Value, allocator, response, .{});
    defer parsed.deinit();
    const obj = parsed.value.object;
    // Should have a result with stopped:true
    const result = obj.get("result").?.object;
    try std.testing.expect(result.get("stopped").?.bool);
}

test "formatJsonRpcResponse produces valid JSON-RPC 2.0 response" {
    const allocator = std.testing.allocator;
    const result = try formatJsonRpcResponse(allocator, .{ .integer = 42 }, "{\"status\":\"ok\"}");
    defer allocator.free(result);

    const parsed = try json.parseFromSlice(json.Value, allocator, result, .{});
    defer parsed.deinit();
    const obj = parsed.value.object;

    try std.testing.expectEqualStrings("2.0", obj.get("jsonrpc").?.string);
    try std.testing.expectEqual(@as(i64, 42), obj.get("id").?.integer);
    const res_obj = obj.get("result").?.object;
    try std.testing.expectEqualStrings("ok", res_obj.get("status").?.string);
}

test "handleToolsCall returns MethodNotFound for unknown tool" {
    const allocator = std.testing.allocator;
    var mcp = McpServer.init(allocator);
    defer mcp.deinit();

    const params_str =
        \\{"name":"nonexistent_tool","arguments":{}}
    ;
    const params_parsed = try json.parseFromSlice(json.Value, allocator, params_str, .{});
    defer params_parsed.deinit();

    const response = try mcp.handleRequest(allocator, "tools/call", params_parsed.value, null);
    defer allocator.free(response);

    const parsed = try json.parseFromSlice(json.Value, allocator, response, .{});
    defer parsed.deinit();
    const err = parsed.value.object.get("error").?.object;
    try std.testing.expectEqual(@as(i64, METHOD_NOT_FOUND), err.get("code").?.integer);
}

test "tool schema for debug_launch has required program field" {
    const schema = try json.parseFromSlice(json.Value, std.testing.allocator, debug_launch_schema, .{});
    defer schema.deinit();
    const obj = schema.value.object;

    try std.testing.expectEqualStrings("object", obj.get("type").?.string);
    const required = obj.get("required").?.array;
    try std.testing.expectEqual(@as(usize, 1), required.items.len);
    try std.testing.expectEqualStrings("program", required.items[0].string);
}

test "tool schema for debug_run has required session_id and action" {
    const schema = try json.parseFromSlice(json.Value, std.testing.allocator, debug_run_schema, .{});
    defer schema.deinit();
    const required = schema.value.object.get("required").?.array;

    try std.testing.expectEqual(@as(usize, 2), required.items.len);
    try std.testing.expectEqualStrings("session_id", required.items[0].string);
    try std.testing.expectEqualStrings("action", required.items[1].string);
}

// ── Phase 12 Tests ──────────────────────────────────────────────────────

test "new Phase 12 tools appear in tool list" {
    const allocator = std.testing.allocator;
    var mcp = McpServer.init(allocator);
    defer mcp.deinit();

    const response = try mcp.handleRequest(allocator, "tools/list", null, null);
    defer allocator.free(response);

    const parsed = try json.parseFromSlice(json.Value, allocator, response, .{});
    defer parsed.deinit();
    const tools = parsed.value.object.get("result").?.object.get("tools").?.array;

    // Collect tool names
    var found_instruction_bp = false;
    var found_step_in_targets = false;
    var found_bp_locations = false;
    var found_cancel = false;
    var found_terminate_threads = false;
    var found_restart = false;

    for (tools.items) |tool| {
        const name = tool.object.get("name").?.string;
        if (std.mem.eql(u8, name, "debug_instruction_breakpoint")) found_instruction_bp = true;
        if (std.mem.eql(u8, name, "debug_step_in_targets")) found_step_in_targets = true;
        if (std.mem.eql(u8, name, "debug_breakpoint_locations")) found_bp_locations = true;
        if (std.mem.eql(u8, name, "debug_cancel")) found_cancel = true;
        if (std.mem.eql(u8, name, "debug_terminate_threads")) found_terminate_threads = true;
        if (std.mem.eql(u8, name, "debug_restart")) found_restart = true;
    }

    try std.testing.expect(found_instruction_bp);
    try std.testing.expect(found_step_in_targets);
    try std.testing.expect(found_bp_locations);
    try std.testing.expect(found_cancel);
    try std.testing.expect(found_terminate_threads);
    try std.testing.expect(found_restart);
}

test "dispatch routes to new Phase 12 handlers" {
    const allocator = std.testing.allocator;
    var mcp = McpServer.init(allocator);
    defer mcp.deinit();

    // Each new tool should return "Unknown session" error (not "Unknown tool")
    // because the dispatch found the handler, which then checked the session
    const new_tools = [_][]const u8{
        \\{"name":"debug_instruction_breakpoint","arguments":{"session_id":"fake","instruction_reference":"0x1000"}}
        ,
        \\{"name":"debug_step_in_targets","arguments":{"session_id":"fake","frame_id":0}}
        ,
        \\{"name":"debug_breakpoint_locations","arguments":{"session_id":"fake","source":"test.zig","line":1}}
        ,
        \\{"name":"debug_cancel","arguments":{"session_id":"fake"}}
        ,
        \\{"name":"debug_terminate_threads","arguments":{"session_id":"fake","thread_ids":[1]}}
        ,
        \\{"name":"debug_restart","arguments":{"session_id":"fake"}}
        ,
    };

    for (new_tools) |tool_params| {
        const params_parsed = try json.parseFromSlice(json.Value, allocator, tool_params, .{});
        defer params_parsed.deinit();

        const response = try mcp.handleRequest(allocator, "tools/call", params_parsed.value, null);
        defer allocator.free(response);

        const parsed = try json.parseFromSlice(json.Value, allocator, response, .{});
        defer parsed.deinit();

        // Should get an error response with "Unknown session" (not "Unknown tool")
        const err_obj = parsed.value.object.get("error").?.object;
        try std.testing.expectEqualStrings("Unknown session", err_obj.get("message").?.string);
        try std.testing.expectEqual(@as(i64, INVALID_PARAMS), err_obj.get("code").?.integer);
    }
}

test "Phase 12 handlers return error for missing session" {
    const allocator = std.testing.allocator;
    var mcp = McpServer.init(allocator);
    defer mcp.deinit();

    // Test debug_instruction_breakpoint with nonexistent session
    const params_str =
        \\{"name":"debug_instruction_breakpoint","arguments":{"session_id":"nonexistent","instruction_reference":"0x4000"}}
    ;
    const params_parsed = try json.parseFromSlice(json.Value, allocator, params_str, .{});
    defer params_parsed.deinit();

    const response = try mcp.handleRequest(allocator, "tools/call", params_parsed.value, null);
    defer allocator.free(response);

    const parsed = try json.parseFromSlice(json.Value, allocator, response, .{});
    defer parsed.deinit();

    const err_obj = parsed.value.object.get("error").?.object;
    try std.testing.expectEqualStrings("Unknown session", err_obj.get("message").?.string);
}

test "enriched debug_run schema includes granularity" {
    const schema = try json.parseFromSlice(json.Value, std.testing.allocator, debug_run_schema, .{});
    defer schema.deinit();
    const props = schema.value.object.get("properties").?.object;

    const granularity = props.get("granularity").?.object;
    try std.testing.expectEqualStrings("string", granularity.get("type").?.string);
}

test "enriched debug_inspect schema includes context" {
    const schema = try json.parseFromSlice(json.Value, std.testing.allocator, debug_inspect_schema, .{});
    defer schema.deinit();
    const props = schema.value.object.get("properties").?.object;

    const context = props.get("context").?.object;
    try std.testing.expectEqualStrings("string", context.get("type").?.string);
}

test "enriched debug_memory schema includes offset" {
    const schema = try json.parseFromSlice(json.Value, std.testing.allocator, debug_memory_schema, .{});
    defer schema.deinit();
    const props = schema.value.object.get("properties").?.object;

    const offset = props.get("offset").?.object;
    try std.testing.expectEqualStrings("integer", offset.get("type").?.string);
}

test "enriched debug_disassemble schema includes instruction_offset and resolve_symbols" {
    const schema = try json.parseFromSlice(json.Value, std.testing.allocator, debug_disassemble_schema, .{});
    defer schema.deinit();
    const props = schema.value.object.get("properties").?.object;

    const instr_offset = props.get("instruction_offset").?.object;
    try std.testing.expectEqualStrings("integer", instr_offset.get("type").?.string);

    const resolve = props.get("resolve_symbols").?.object;
    try std.testing.expectEqualStrings("boolean", resolve.get("type").?.string);
}

test "new tool schemas are valid JSON" {
    const schemas = [_][]const u8{
        debug_instruction_breakpoint_schema,
        debug_step_in_targets_schema,
        debug_breakpoint_locations_schema,
        debug_cancel_schema,
        debug_terminate_threads_schema,
        debug_restart_schema,
    };
    for (schemas) |schema_str| {
        const parsed = try json.parseFromSlice(json.Value, std.testing.allocator, schema_str, .{});
        defer parsed.deinit();
        try std.testing.expectEqualStrings("object", parsed.value.object.get("type").?.string);
    }
}
