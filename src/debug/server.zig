const std = @import("std");
const json = std.json;
const Stringify = json.Stringify;
const Writer = std.io.Writer;
const posix = std.posix;
const types = @import("types.zig");
const session_mod = @import("session.zig");
const driver_mod = @import("driver.zig");
const dashboard_mod = @import("dashboard.zig");
const dashboard_tui = @import("dashboard_tui.zig");

const SessionManager = session_mod.SessionManager;

// Standard error codes
pub const PARSE_ERROR = -32700;
pub const INVALID_REQUEST = -32600;
pub const METHOD_NOT_FOUND = -32601;
pub const INVALID_PARAMS = -32602;
pub const INTERNAL_ERROR = -32603;
pub const NOT_SUPPORTED = -32001;

/// Map an error to the appropriate error code.
/// NotSupported gets a dedicated code (-32001) instead of INTERNAL_ERROR.
pub fn errorToCode(err: anyerror) i32 {
    return if (err == error.NotSupported) NOT_SUPPORTED else INTERNAL_ERROR;
}

// ── Tool Definitions ────────────────────────────────────────────────────

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
        .description = "Read CPU register values (native engine only, not available for DAP sessions)",
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
        .name = "debug_goto_targets",
        .description = "Discover valid goto target locations for a source line",
        .input_schema = debug_goto_targets_schema,
    },
    .{
        .name = "debug_find_symbol",
        .description = "Search for symbol definitions by name (native engine only, not available for DAP sessions)",
        .input_schema = debug_find_symbol_schema,
    },
    .{
        .name = "debug_write_register",
        .description = "Write a value to a CPU register (native engine only, not available for DAP sessions)",
        .input_schema = debug_write_register_schema,
    },
    .{
        .name = "debug_variable_location",
        .description = "Get the physical storage location of a variable (native engine only, not available for DAP sessions)",
        .input_schema = debug_variable_location_schema,
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

pub const debug_launch_schema =
    \\{"type":"object","properties":{"program":{"type":"string","description":"Path to executable or script"},"args":{"type":"array","items":{"type":"string"},"description":"Program arguments"},"env":{"type":"object","description":"Environment variables"},"cwd":{"type":"string","description":"Working directory"},"language":{"type":"string","description":"Language hint (auto-detected from extension)"},"stop_on_entry":{"type":"boolean","default":false}},"required":["program"]}
;

pub const debug_breakpoint_schema =
    \\{"type":"object","properties":{"session_id":{"type":"string"},"action":{"type":"string","enum":["set","remove","list","set_function","set_exception"]},"file":{"type":"string"},"line":{"type":"integer"},"condition":{"type":"string"},"hit_condition":{"type":"string"},"log_message":{"type":"string"},"function":{"type":"string"},"filters":{"type":"array","items":{"type":"string"}},"id":{"type":"integer"}},"required":["session_id","action"]}
;

pub const debug_run_schema =
    \\{"type":"object","properties":{"session_id":{"type":"string"},"action":{"type":"string","enum":["continue","step_into","step_over","step_out","restart","pause","goto","reverse_continue","step_back"]},"file":{"type":"string","description":"Target file for goto"},"line":{"type":"integer","description":"Target line for goto"},"granularity":{"type":"string","enum":["statement","line","instruction"],"description":"Stepping granularity"}},"required":["session_id","action"]}
;

pub const debug_inspect_schema =
    \\{"type":"object","properties":{"session_id":{"type":"string"},"expression":{"type":"string"},"variable_ref":{"type":"integer"},"frame_id":{"type":"integer"},"scope":{"type":"string","enum":["locals","globals","arguments"]},"context":{"type":"string","enum":["watch","repl","hover","clipboard"],"description":"Evaluation context"}},"required":["session_id"]}
;

pub const debug_stop_schema =
    \\{"type":"object","properties":{"session_id":{"type":"string"},"terminate_only":{"type":"boolean","default":false,"description":"If true, terminate the debuggee but keep the debug adapter alive (DAP only)"},"detach":{"type":"boolean","default":false,"description":"Detach from debuggee without terminating"}},"required":["session_id"]}
;

pub const debug_threads_schema =
    \\{"type":"object","properties":{"session_id":{"type":"string"}},"required":["session_id"]}
;

pub const debug_stacktrace_schema =
    \\{"type":"object","properties":{"session_id":{"type":"string"},"thread_id":{"type":"integer","default":1},"start_frame":{"type":"integer","default":0},"levels":{"type":"integer","default":20}},"required":["session_id"]}
;

pub const debug_memory_schema =
    \\{"type":"object","properties":{"session_id":{"type":"string"},"action":{"type":"string","enum":["read","write"]},"address":{"type":"string","description":"Hex address e.g. 0x1000"},"size":{"type":"integer","default":64},"data":{"type":"string","description":"Hex string for write"},"offset":{"type":"integer","description":"Byte offset from the base address"}},"required":["session_id","action","address"]}
;

pub const debug_disassemble_schema =
    \\{"type":"object","properties":{"session_id":{"type":"string"},"address":{"type":"string","description":"Hex address e.g. 0x1000"},"instruction_count":{"type":"integer","default":10},"instruction_offset":{"type":"integer","description":"Offset in instructions from the address"},"resolve_symbols":{"type":"boolean","description":"Whether to resolve symbol names","default":true}},"required":["session_id","address"]}
;

pub const debug_attach_schema =
    \\{"type":"object","properties":{"pid":{"type":"integer","description":"Process ID to attach to"},"language":{"type":"string","description":"Language hint"}},"required":["pid"]}
;

pub const debug_set_variable_schema =
    \\{"type":"object","properties":{"session_id":{"type":"string"},"variable":{"type":"string","description":"Variable name"},"value":{"type":"string","description":"New value"},"frame_id":{"type":"integer","default":0}},"required":["session_id","variable","value"]}
;

pub const debug_scopes_schema =
    \\{"type":"object","properties":{"session_id":{"type":"string"},"frame_id":{"type":"integer","default":0}},"required":["session_id"]}
;

pub const debug_watchpoint_schema =
    \\{"type":"object","properties":{"session_id":{"type":"string"},"variable":{"type":"string","description":"Variable name to watch"},"access_type":{"type":"string","enum":["read","write","readWrite"],"default":"write"},"frame_id":{"type":"integer"}},"required":["session_id","variable"]}
;

pub const debug_capabilities_schema =
    \\{"type":"object","properties":{"session_id":{"type":"string"}},"required":["session_id"]}
;

pub const debug_completions_schema =
    \\{"type":"object","properties":{"session_id":{"type":"string"},"text":{"type":"string","description":"Partial text to complete"},"column":{"type":"integer","default":0},"frame_id":{"type":"integer"}},"required":["session_id","text"]}
;

pub const debug_modules_schema =
    \\{"type":"object","properties":{"session_id":{"type":"string"}},"required":["session_id"]}
;

pub const debug_loaded_sources_schema =
    \\{"type":"object","properties":{"session_id":{"type":"string"}},"required":["session_id"]}
;

pub const debug_source_schema =
    \\{"type":"object","properties":{"session_id":{"type":"string"},"source_reference":{"type":"integer","description":"Source reference ID"}},"required":["session_id","source_reference"]}
;

pub const debug_set_expression_schema =
    \\{"type":"object","properties":{"session_id":{"type":"string"},"expression":{"type":"string","description":"Expression to evaluate and set"},"value":{"type":"string","description":"New value"},"frame_id":{"type":"integer","default":0}},"required":["session_id","expression","value"]}
;

pub const debug_restart_frame_schema =
    \\{"type":"object","properties":{"session_id":{"type":"string"},"frame_id":{"type":"integer","description":"Stack frame ID to restart from"}},"required":["session_id","frame_id"]}
;

pub const debug_exception_info_schema =
    \\{"type":"object","properties":{"session_id":{"type":"string"},"thread_id":{"type":"integer","default":1}},"required":["session_id"]}
;

pub const debug_registers_schema =
    \\{"type":"object","properties":{"session_id":{"type":"string"},"thread_id":{"type":"integer","default":1}},"required":["session_id"]}
;

pub const debug_instruction_breakpoint_schema =
    \\{"type":"object","properties":{"session_id":{"type":"string"},"instruction_reference":{"type":"string","description":"Memory reference to an instruction"},"offset":{"type":"integer","description":"Optional offset from the instruction reference"},"condition":{"type":"string","description":"Optional breakpoint condition expression"},"hit_condition":{"type":"string","description":"Optional hit count condition"}},"required":["session_id","instruction_reference"]}
;

pub const debug_step_in_targets_schema =
    \\{"type":"object","properties":{"session_id":{"type":"string"},"frame_id":{"type":"integer","description":"Stack frame ID to get step-in targets for"}},"required":["session_id","frame_id"]}
;

pub const debug_breakpoint_locations_schema =
    \\{"type":"object","properties":{"session_id":{"type":"string"},"source":{"type":"string","description":"Source file path"},"line":{"type":"integer","description":"Start line to query"},"end_line":{"type":"integer","description":"Optional end line for range query"}},"required":["session_id","source","line"]}
;

pub const debug_cancel_schema =
    \\{"type":"object","properties":{"session_id":{"type":"string"},"request_id":{"type":"integer","description":"ID of the request to cancel"},"progress_id":{"type":"string","description":"ID of the progress to cancel"}},"required":["session_id"]}
;

pub const debug_terminate_threads_schema =
    \\{"type":"object","properties":{"session_id":{"type":"string"},"thread_ids":{"type":"array","items":{"type":"integer"},"description":"IDs of threads to terminate"}},"required":["session_id","thread_ids"]}
;

pub const debug_restart_schema =
    \\{"type":"object","properties":{"session_id":{"type":"string"}},"required":["session_id"]}
;

pub const debug_sessions_schema =
    \\{"type":"object","properties":{}}
;

pub const debug_goto_targets_schema =
    \\{"type":"object","properties":{"session_id":{"type":"string"},"file":{"type":"string"},"line":{"type":"integer"}},"required":["session_id","file","line"]}
;

pub const debug_find_symbol_schema =
    \\{"type":"object","properties":{"session_id":{"type":"string"},"name":{"type":"string"}},"required":["session_id","name"]}
;

pub const debug_write_register_schema =
    \\{"type":"object","properties":{"session_id":{"type":"string"},"name":{"type":"string"},"value":{"type":"integer"},"thread_id":{"type":"integer","default":0}},"required":["session_id","name","value"]}
;

pub const debug_variable_location_schema =
    \\{"type":"object","properties":{"session_id":{"type":"string"},"name":{"type":"string"},"frame_id":{"type":"integer","default":0}},"required":["session_id","name"]}
;



pub const debug_poll_events_schema =
    \\{"type":"object","properties":{"session_id":{"type":"string","description":"Poll specific session, or omit for all sessions"}}}
;

// ── Tool Result Type ────────────────────────────────────────────────────

pub const ToolResult = union(enum) {
    ok: []const u8, // raw JSON result string (caller-owned)
    err: ToolError,

    pub const ToolError = struct {
        code: i32,
        message: []const u8, // static string literal
    };
};

// ── Debug Server ────────────────────────────────────────────────────────

pub const DebugServer = struct {
    session_manager: SessionManager,
    allocator: std.mem.Allocator,
    dashboard: dashboard_mod.Dashboard,
    /// Socket connection to standalone dashboard TUI (null if not connected)
    dashboard_socket: ?posix.socket_t = null,

    pub fn init(allocator: std.mem.Allocator) DebugServer {
        return .{
            .session_manager = SessionManager.init(allocator),
            .allocator = allocator,
            .dashboard = dashboard_mod.Dashboard.init(),
        };
    }

    pub fn deinit(self: *DebugServer) void {
        // Close dashboard socket
        if (self.dashboard_socket) |sock| {
            posix.close(sock);
            self.dashboard_socket = null;
        }
        self.session_manager.deinit();
    }

    /// Dispatch a tool call and return the raw result.
    /// Used by the daemon socket transport.
    pub fn callTool(self: *DebugServer, allocator: std.mem.Allocator, tool_name: []const u8, tool_args: ?json.Value) !ToolResult {
        if (std.mem.eql(u8, tool_name, "debug_launch")) {
            return self.toolLaunch(allocator, tool_args);
        } else if (std.mem.eql(u8, tool_name, "debug_breakpoint")) {
            return self.toolBreakpoint(allocator, tool_args);
        } else if (std.mem.eql(u8, tool_name, "debug_run")) {
            return self.toolRun(allocator, tool_args);
        } else if (std.mem.eql(u8, tool_name, "debug_inspect")) {
            return self.toolInspect(allocator, tool_args);
        } else if (std.mem.eql(u8, tool_name, "debug_stop")) {
            return self.toolStop(allocator, tool_args);
        } else if (std.mem.eql(u8, tool_name, "debug_threads")) {
            return self.toolThreads(allocator, tool_args);
        } else if (std.mem.eql(u8, tool_name, "debug_stacktrace")) {
            return self.toolStackTrace(allocator, tool_args);
        } else if (std.mem.eql(u8, tool_name, "debug_memory")) {
            return self.toolMemory(allocator, tool_args);
        } else if (std.mem.eql(u8, tool_name, "debug_disassemble")) {
            return self.toolDisassemble(allocator, tool_args);
        } else if (std.mem.eql(u8, tool_name, "debug_attach")) {
            return self.toolAttach(allocator, tool_args);
        } else if (std.mem.eql(u8, tool_name, "debug_set_variable")) {
            return self.toolSetVariable(allocator, tool_args);
        } else if (std.mem.eql(u8, tool_name, "debug_scopes")) {
            return self.toolScopes(allocator, tool_args);
        } else if (std.mem.eql(u8, tool_name, "debug_watchpoint")) {
            return self.toolWatchpoint(allocator, tool_args);
        } else if (std.mem.eql(u8, tool_name, "debug_capabilities")) {
            return self.toolCapabilities(allocator, tool_args);
        } else if (std.mem.eql(u8, tool_name, "debug_completions")) {
            return self.toolCompletions(allocator, tool_args);
        } else if (std.mem.eql(u8, tool_name, "debug_modules")) {
            return self.toolModules(allocator, tool_args);
        } else if (std.mem.eql(u8, tool_name, "debug_loaded_sources")) {
            return self.toolLoadedSources(allocator, tool_args);
        } else if (std.mem.eql(u8, tool_name, "debug_source")) {
            return self.toolSource(allocator, tool_args);
        } else if (std.mem.eql(u8, tool_name, "debug_set_expression")) {
            return self.toolSetExpression(allocator, tool_args);
        } else if (std.mem.eql(u8, tool_name, "debug_restart_frame")) {
            return self.toolRestartFrame(allocator, tool_args);
        } else if (std.mem.eql(u8, tool_name, "debug_exception_info")) {
            return self.toolExceptionInfo(allocator, tool_args);
        } else if (std.mem.eql(u8, tool_name, "debug_registers")) {
            return self.toolRegisters(allocator, tool_args);
        } else if (std.mem.eql(u8, tool_name, "debug_instruction_breakpoint")) {
            return self.toolInstructionBreakpoint(allocator, tool_args);
        } else if (std.mem.eql(u8, tool_name, "debug_step_in_targets")) {
            return self.toolStepInTargets(allocator, tool_args);
        } else if (std.mem.eql(u8, tool_name, "debug_breakpoint_locations")) {
            return self.toolBreakpointLocations(allocator, tool_args);
        } else if (std.mem.eql(u8, tool_name, "debug_cancel")) {
            return self.toolCancel(allocator, tool_args);
        } else if (std.mem.eql(u8, tool_name, "debug_terminate_threads")) {
            return self.toolTerminateThreads(allocator, tool_args);
        } else if (std.mem.eql(u8, tool_name, "debug_restart")) {
            return self.toolRestart(allocator, tool_args);
        } else if (std.mem.eql(u8, tool_name, "debug_sessions")) {
            return self.toolSessions(allocator);
        } else if (std.mem.eql(u8, tool_name, "debug_goto_targets")) {
            return self.toolGotoTargets(allocator, tool_args);
        } else if (std.mem.eql(u8, tool_name, "debug_find_symbol")) {
            return self.toolFindSymbol(allocator, tool_args);
        } else if (std.mem.eql(u8, tool_name, "debug_write_register")) {
            return self.toolWriteRegister(allocator, tool_args);
        } else if (std.mem.eql(u8, tool_name, "debug_variable_location")) {
            return self.toolVariableLocation(allocator, tool_args);
        } else if (std.mem.eql(u8, tool_name, "debug_poll_events")) {
            return self.toolPollEvents(allocator, tool_args);
        } else {
            return .{ .err = .{ .code = METHOD_NOT_FOUND, .message = "Unknown tool" } };
        }
    }

    // ── Tool Implementations ────────────────────────────────────────────

    fn toolLaunch(self: *DebugServer, allocator: std.mem.Allocator, args: ?json.Value) !ToolResult {
        const a = args orelse return .{ .err = .{ .code = INVALID_PARAMS, .message = "Missing arguments" } };
        if (a != .object) return .{ .err = .{ .code = INVALID_PARAMS, .message = "Arguments must be object" } };

        const config = types.LaunchConfig.parseFromJson(allocator, a) catch {
            return .{ .err = .{ .code = INVALID_PARAMS, .message = "Invalid launch config: program is required" } };
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
                return .{ .err = .{ .code = errorToCode(err), .message = @errorName(err) } };
            };

            const session_id = try self.session_manager.createSession(driver);
            if (self.session_manager.getSession(session_id)) |s| {
                s.status = .stopped;
            }
            self.dashboard.onLaunch(session_id, config.program, "dap");
            self.emitLaunchEvent(session_id, config.program, "dap");

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
            return .{ .ok = result };
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
                return .{ .err = .{ .code = errorToCode(err), .message = @errorName(err) } };
            };

            const session_id = try self.session_manager.createSession(driver);
            if (self.session_manager.getSession(session_id)) |ss| {
                ss.status = .stopped;
            }
            self.dashboard.onLaunch(session_id, config.program, "native");
            self.emitLaunchEvent(session_id, config.program, "native");

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
            return .{ .ok = result };
        }
    }

    fn toolBreakpoint(self: *DebugServer, allocator: std.mem.Allocator, args: ?json.Value) !ToolResult {
        const a = args orelse return .{ .err = .{ .code = INVALID_PARAMS, .message = "Missing arguments" } };
        if (a != .object) return .{ .err = .{ .code = INVALID_PARAMS, .message = "Arguments must be object" } };

        const session_id_val = a.object.get("session_id") orelse return .{ .err = .{ .code = INVALID_PARAMS, .message = "Missing session_id" } };
        if (session_id_val != .string) return .{ .err = .{ .code = INVALID_PARAMS, .message = "session_id must be string" } };

        const session = self.session_manager.getSession(session_id_val.string) orelse
            return .{ .err = .{ .code = INVALID_PARAMS, .message = "Unknown session" } };

        const action_val = a.object.get("action") orelse return .{ .err = .{ .code = INVALID_PARAMS, .message = "Missing action" } };
        if (action_val != .string) return .{ .err = .{ .code = INVALID_PARAMS, .message = "action must be string" } };
        const action_str = action_val.string;

        if (std.mem.eql(u8, action_str, "set")) {
            const file_val = a.object.get("file") orelse return .{ .err = .{ .code = INVALID_PARAMS, .message = "Missing file for set" } };
            if (file_val != .string) return .{ .err = .{ .code = INVALID_PARAMS, .message = "file must be string" } };
            const line_val = a.object.get("line") orelse return .{ .err = .{ .code = INVALID_PARAMS, .message = "Missing line for set" } };
            if (line_val != .integer) return .{ .err = .{ .code = INVALID_PARAMS, .message = "line must be integer" } };

            const condition = if (a.object.get("condition")) |c| (if (c == .string) c.string else null) else null;
            const hit_condition = if (a.object.get("hit_condition")) |c| (if (c == .string) c.string else null) else null;
            const log_message = if (a.object.get("log_message")) |c| (if (c == .string) c.string else null) else null;

            const bp = session.driver.setBreakpointEx(allocator, file_val.string, @intCast(line_val.integer), condition, hit_condition, log_message) catch |err| {
                self.dashboard.onError("debug_breakpoint", @errorName(err));
                return .{ .err = .{ .code = errorToCode(err), .message = @errorName(err) } };
            };
            self.dashboard.onBreakpoint("set", bp);
            self.emitBreakpointEvent(session_id_val.string, "set", bp);

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
            return .{ .ok = result };
        } else if (std.mem.eql(u8, action_str, "remove")) {
            const bp_id_val = a.object.get("id") orelse return .{ .err = .{ .code = INVALID_PARAMS, .message = "Missing id for remove" } };
            if (bp_id_val != .integer) return .{ .err = .{ .code = INVALID_PARAMS, .message = "id must be integer" } };

            session.driver.removeBreakpoint(allocator, @intCast(bp_id_val.integer)) catch |err| {
                self.dashboard.onError("debug_breakpoint", @errorName(err));
                return .{ .err = .{ .code = errorToCode(err), .message = @errorName(err) } };
            };
            self.dashboard.onBreakpoint("remove", .{
                .id = @intCast(bp_id_val.integer),
                .verified = false,
                .file = "",
                .line = 0,
            });
            self.emitBreakpointEvent(session_id_val.string, "remove", .{
                .id = @intCast(bp_id_val.integer),
                .verified = false,
                .file = "",
                .line = 0,
            });

            return .{ .ok = try allocator.dupe(u8, "{\"removed\":true}") };
        } else if (std.mem.eql(u8, action_str, "list")) {
            const bps = session.driver.listBreakpoints(allocator) catch |err| {
                self.dashboard.onError("debug_breakpoint", @errorName(err));
                return .{ .err = .{ .code = errorToCode(err), .message = @errorName(err) } };
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
            return .{ .ok = result };
        } else if (std.mem.eql(u8, action_str, "set_function")) {
            const func_val = a.object.get("function") orelse return .{ .err = .{ .code = INVALID_PARAMS, .message = "Missing function name" } };
            if (func_val != .string) return .{ .err = .{ .code = INVALID_PARAMS, .message = "function must be string" } };

            const condition = if (a.object.get("condition")) |c| (if (c == .string) c.string else null) else null;

            const bp = session.driver.setFunctionBreakpoint(allocator, func_val.string, condition) catch |err| {
                self.dashboard.onError("debug_breakpoint", @errorName(err));
                return .{ .err = .{ .code = errorToCode(err), .message = @errorName(err) } };
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
            return .{ .ok = result };
        } else if (std.mem.eql(u8, action_str, "set_exception")) {
            const filters_val = a.object.get("filters") orelse return .{ .err = .{ .code = INVALID_PARAMS, .message = "Missing filters for set_exception" } };
            if (filters_val != .array) return .{ .err = .{ .code = INVALID_PARAMS, .message = "filters must be array" } };

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
                return .{ .err = .{ .code = errorToCode(err), .message = @errorName(err) } };
            };

            return .{ .ok = try allocator.dupe(u8, "{\"exception_breakpoints_set\":true}") };
        } else {
            return .{ .err = .{ .code = INVALID_PARAMS, .message = "action must be set, remove, list, set_function, or set_exception" } };
        }
    }

    fn toolRun(self: *DebugServer, allocator: std.mem.Allocator, args: ?json.Value) !ToolResult {
        const a = args orelse return .{ .err = .{ .code = INVALID_PARAMS, .message = "Missing arguments" } };
        if (a != .object) return .{ .err = .{ .code = INVALID_PARAMS, .message = "Arguments must be object" } };

        const session_id_val = a.object.get("session_id") orelse return .{ .err = .{ .code = INVALID_PARAMS, .message = "Missing session_id" } };
        if (session_id_val != .string) return .{ .err = .{ .code = INVALID_PARAMS, .message = "session_id must be string" } };

        const session = self.session_manager.getSession(session_id_val.string) orelse
            return .{ .err = .{ .code = INVALID_PARAMS, .message = "Unknown session" } };

        const action_val = a.object.get("action") orelse return .{ .err = .{ .code = INVALID_PARAMS, .message = "Missing action" } };
        if (action_val != .string) return .{ .err = .{ .code = INVALID_PARAMS, .message = "action must be string" } };

        // Handle goto separately — it dispatches through gotoFn, not runFn
        if (std.mem.eql(u8, action_val.string, "goto")) {
            const file_val = a.object.get("file") orelse return .{ .err = .{ .code = INVALID_PARAMS, .message = "Missing file for goto" } };
            if (file_val != .string) return .{ .err = .{ .code = INVALID_PARAMS, .message = "file must be string" } };
            const line_val = a.object.get("line") orelse return .{ .err = .{ .code = INVALID_PARAMS, .message = "Missing line for goto" } };
            if (line_val != .integer) return .{ .err = .{ .code = INVALID_PARAMS, .message = "line must be integer" } };

            const state = session.driver.goto(allocator, file_val.string, @intCast(line_val.integer)) catch |err| {
                self.dashboard.onError("debug_run", @errorName(err));
                return .{ .err = .{ .code = errorToCode(err), .message = @errorName(err) } };
            };

            session.status = .stopped;
            self.dashboard.onRun(session_id_val.string, "goto", state);
            self.emitStopEvent(session_id_val.string, "goto", state);

            var aw: Writer.Allocating = .init(allocator);
            defer aw.deinit();
            var s: Stringify = .{ .writer = &aw.writer };
            try state.jsonStringify(&s);
            const result = try aw.toOwnedSlice();
            return .{ .ok = result };
        }

        const action = types.RunAction.parse(action_val.string) orelse
            return .{ .err = .{ .code = INVALID_PARAMS, .message = "Invalid action" } };

        const run_options = types.RunOptions{
            .granularity = if (a.object.get("granularity")) |v| (if (v == .string) types.SteppingGranularity.parse(v.string) else null) else null,
            .target_id = if (a.object.get("target_id")) |v| (if (v == .integer) @as(u32, @intCast(v.integer)) else null) else null,
            .thread_id = if (a.object.get("thread_id")) |v| (if (v == .integer) @as(u32, @intCast(v.integer)) else null) else null,
        };

        session.status = .running;
        const state = session.driver.runEx(allocator, action, run_options) catch |err| {
            self.dashboard.onError("debug_run", @errorName(err));
            return .{ .err = .{ .code = errorToCode(err), .message = @errorName(err) } };
        };

        session.status = if (state.exit_code != null) .terminated else .stopped;
        self.dashboard.onRun(session_id_val.string, action_val.string, state);
        self.emitStopEvent(session_id_val.string, action_val.string, state);

        var aw: Writer.Allocating = .init(allocator);
        defer aw.deinit();
        var s: Stringify = .{ .writer = &aw.writer };
        try state.jsonStringify(&s);
        const result = try aw.toOwnedSlice();
        return .{ .ok = result };
    }

    fn toolInspect(self: *DebugServer, allocator: std.mem.Allocator, args: ?json.Value) !ToolResult {
        const a = args orelse return .{ .err = .{ .code = INVALID_PARAMS, .message = "Missing arguments" } };
        if (a != .object) return .{ .err = .{ .code = INVALID_PARAMS, .message = "Arguments must be object" } };

        const session_id_val = a.object.get("session_id") orelse return .{ .err = .{ .code = INVALID_PARAMS, .message = "Missing session_id" } };
        if (session_id_val != .string) return .{ .err = .{ .code = INVALID_PARAMS, .message = "session_id must be string" } };

        const session = self.session_manager.getSession(session_id_val.string) orelse
            return .{ .err = .{ .code = INVALID_PARAMS, .message = "Unknown session" } };

        const request = types.InspectRequest{
            .expression = if (a.object.get("expression")) |v| (if (v == .string) v.string else null) else null,
            .variable_ref = if (a.object.get("variable_ref")) |v| (if (v == .integer) @as(u32, @intCast(v.integer)) else null) else null,
            .frame_id = if (a.object.get("frame_id")) |v| (if (v == .integer) @as(u32, @intCast(v.integer)) else null) else null,
            .scope = if (a.object.get("scope")) |v| (if (v == .string) v.string else null) else null,
            .context = if (a.object.get("context")) |v| (if (v == .string) types.EvaluateContext.parse(v.string) else null) else null,
        };

        const result_val = session.driver.inspect(allocator, request) catch |err| {
            self.dashboard.onError("debug_inspect", @errorName(err));
            return .{ .err = .{ .code = errorToCode(err), .message = @errorName(err) } };
        };
        defer result_val.deinit(allocator);
        self.dashboard.onInspect(
            session_id_val.string,
            if (request.expression) |e| e else "(scope)",
            result_val.result,
        );
        self.emitInspectEvent(
            session_id_val.string,
            if (request.expression) |e| e else "(scope)",
            result_val.result,
            result_val.@"type",
        );

        var aw: Writer.Allocating = .init(allocator);
        defer aw.deinit();
        var s: Stringify = .{ .writer = &aw.writer };
        try result_val.jsonStringify(&s);
        const result = try aw.toOwnedSlice();
        return .{ .ok = result };
    }

    fn toolStop(self: *DebugServer, allocator: std.mem.Allocator, args: ?json.Value) !ToolResult {
        const a = args orelse return .{ .err = .{ .code = INVALID_PARAMS, .message = "Missing arguments" } };
        if (a != .object) return .{ .err = .{ .code = INVALID_PARAMS, .message = "Arguments must be object" } };

        const session_id_val = a.object.get("session_id") orelse return .{ .err = .{ .code = INVALID_PARAMS, .message = "Missing session_id" } };
        if (session_id_val != .string) return .{ .err = .{ .code = INVALID_PARAMS, .message = "session_id must be string" } };

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
                return .{ .ok = try allocator.dupe(u8, "{\"terminated\":true}") };
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
        self.emitSessionEndEvent(session_id);

        // Copy key before destroying since destroySession frees the key
        const id_copy = try allocator.dupe(u8, session_id);
        defer allocator.free(id_copy);
        _ = self.session_manager.destroySession(id_copy);

        return .{ .ok = try allocator.dupe(u8, "{\"stopped\":true}") };
    }

    // ── New Tool Implementations (Phase 3) ────────────────────────────

    fn toolThreads(self: *DebugServer, allocator: std.mem.Allocator, args: ?json.Value) !ToolResult {
        const a = args orelse return .{ .err = .{ .code = INVALID_PARAMS, .message = "Missing arguments" } };
        if (a != .object) return .{ .err = .{ .code = INVALID_PARAMS, .message = "Arguments must be object" } };

        const session_id_val = a.object.get("session_id") orelse return .{ .err = .{ .code = INVALID_PARAMS, .message = "Missing session_id" } };
        if (session_id_val != .string) return .{ .err = .{ .code = INVALID_PARAMS, .message = "session_id must be string" } };

        const session = self.session_manager.getSession(session_id_val.string) orelse
            return .{ .err = .{ .code = INVALID_PARAMS, .message = "Unknown session" } };

        const thread_list = session.driver.threads(allocator) catch |err| {
            self.dashboard.onError("debug_threads", @errorName(err));
            return .{ .err = .{ .code = errorToCode(err), .message = @errorName(err) } };
        };
        self.dashboard.onThreads(session_id_val.string, thread_list.len);
        {
            var abuf: [64]u8 = undefined;
            const asum = std.fmt.bufPrint(&abuf, "{d} thread(s)", .{thread_list.len}) catch "threads listed";
            self.emitActivityEvent(session_id_val.string, "debug_threads", asum);
        }

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
        return .{ .ok = result };
    }

    fn toolStackTrace(self: *DebugServer, allocator: std.mem.Allocator, args: ?json.Value) !ToolResult {
        const a = args orelse return .{ .err = .{ .code = INVALID_PARAMS, .message = "Missing arguments" } };
        if (a != .object) return .{ .err = .{ .code = INVALID_PARAMS, .message = "Arguments must be object" } };

        const session_id_val = a.object.get("session_id") orelse return .{ .err = .{ .code = INVALID_PARAMS, .message = "Missing session_id" } };
        if (session_id_val != .string) return .{ .err = .{ .code = INVALID_PARAMS, .message = "session_id must be string" } };

        const session = self.session_manager.getSession(session_id_val.string) orelse
            return .{ .err = .{ .code = INVALID_PARAMS, .message = "Unknown session" } };

        const thread_id: u32 = if (a.object.get("thread_id")) |v| (if (v == .integer) @intCast(v.integer) else 1) else 1;
        const start_frame: u32 = if (a.object.get("start_frame")) |v| (if (v == .integer) @intCast(v.integer) else 0) else 0;
        const levels: u32 = if (a.object.get("levels")) |v| (if (v == .integer) @intCast(v.integer) else 20) else 20;

        const frames = session.driver.stackTrace(allocator, thread_id, start_frame, levels) catch |err| {
            self.dashboard.onError("debug_stacktrace", @errorName(err));
            return .{ .err = .{ .code = errorToCode(err), .message = @errorName(err) } };
        };
        self.dashboard.onStackTrace(session_id_val.string, frames.len);
        {
            var abuf: [64]u8 = undefined;
            const asum = std.fmt.bufPrint(&abuf, "{d} frame(s)", .{frames.len}) catch "stack trace";
            self.emitActivityEvent(session_id_val.string, "debug_stacktrace", asum);
        }

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
        return .{ .ok = result };
    }

    fn toolMemory(self: *DebugServer, allocator: std.mem.Allocator, args: ?json.Value) !ToolResult {
        const a = args orelse return .{ .err = .{ .code = INVALID_PARAMS, .message = "Missing arguments" } };
        if (a != .object) return .{ .err = .{ .code = INVALID_PARAMS, .message = "Arguments must be object" } };

        const session_id_val = a.object.get("session_id") orelse return .{ .err = .{ .code = INVALID_PARAMS, .message = "Missing session_id" } };
        if (session_id_val != .string) return .{ .err = .{ .code = INVALID_PARAMS, .message = "session_id must be string" } };

        const session = self.session_manager.getSession(session_id_val.string) orelse
            return .{ .err = .{ .code = INVALID_PARAMS, .message = "Unknown session" } };

        const action_val = a.object.get("action") orelse return .{ .err = .{ .code = INVALID_PARAMS, .message = "Missing action" } };
        if (action_val != .string) return .{ .err = .{ .code = INVALID_PARAMS, .message = "action must be string" } };

        const addr_val = a.object.get("address") orelse return .{ .err = .{ .code = INVALID_PARAMS, .message = "Missing address" } };
        if (addr_val != .string) return .{ .err = .{ .code = INVALID_PARAMS, .message = "address must be string" } };

        // Parse hex address (e.g. "0x1000" or "1000")
        const addr_str = addr_val.string;
        const trimmed = if (std.mem.startsWith(u8, addr_str, "0x") or std.mem.startsWith(u8, addr_str, "0X"))
            addr_str[2..]
        else
            addr_str;
        const address = std.fmt.parseInt(u64, trimmed, 16) catch
            return .{ .err = .{ .code = INVALID_PARAMS, .message = "Invalid address format" } };

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
                return .{ .err = .{ .code = errorToCode(err), .message = @errorName(err) } };
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
            return .{ .ok = result };
        } else if (std.mem.eql(u8, action_val.string, "write")) {
            const data_val = a.object.get("data") orelse return .{ .err = .{ .code = INVALID_PARAMS, .message = "Missing data for write" } };
            if (data_val != .string) return .{ .err = .{ .code = INVALID_PARAMS, .message = "data must be hex string" } };

            // Parse hex string to bytes
            const hex_str = data_val.string;
            if (hex_str.len % 2 != 0) return .{ .err = .{ .code = INVALID_PARAMS, .message = "data must be even-length hex string" } };

            const byte_len = hex_str.len / 2;
            const bytes = try allocator.alloc(u8, byte_len);
            defer allocator.free(bytes);
            for (0..byte_len) |i| {
                bytes[i] = std.fmt.parseInt(u8, hex_str[i * 2 .. i * 2 + 2], 16) catch
                    return .{ .err = .{ .code = INVALID_PARAMS, .message = "Invalid hex data" } };
            }

            session.driver.writeMemory(allocator, effective_address, bytes) catch |err| {
                self.dashboard.onError("debug_memory", @errorName(err));
                return .{ .err = .{ .code = errorToCode(err), .message = @errorName(err) } };
            };
            self.dashboard.onMemory(session_id_val.string, "write", addr_val.string);

            return .{ .ok = try allocator.dupe(u8, "{\"written\":true}") };
        } else {
            return .{ .err = .{ .code = INVALID_PARAMS, .message = "action must be read or write" } };
        }
    }

    fn toolDisassemble(self: *DebugServer, allocator: std.mem.Allocator, args: ?json.Value) !ToolResult {
        const a = args orelse return .{ .err = .{ .code = INVALID_PARAMS, .message = "Missing arguments" } };
        if (a != .object) return .{ .err = .{ .code = INVALID_PARAMS, .message = "Arguments must be object" } };

        const session_id_val = a.object.get("session_id") orelse return .{ .err = .{ .code = INVALID_PARAMS, .message = "Missing session_id" } };
        if (session_id_val != .string) return .{ .err = .{ .code = INVALID_PARAMS, .message = "session_id must be string" } };

        const session = self.session_manager.getSession(session_id_val.string) orelse
            return .{ .err = .{ .code = INVALID_PARAMS, .message = "Unknown session" } };

        const address: u64 = if (a.object.get("address")) |addr_val| blk: {
            if (addr_val != .string) return .{ .err = .{ .code = INVALID_PARAMS, .message = "address must be string" } };
            const addr_str = addr_val.string;
            const trimmed = if (std.mem.startsWith(u8, addr_str, "0x") or std.mem.startsWith(u8, addr_str, "0X"))
                addr_str[2..]
            else
                addr_str;
            break :blk std.fmt.parseInt(u64, trimmed, 16) catch
                return .{ .err = .{ .code = INVALID_PARAMS, .message = "Invalid address format" } };
        } else blk: {
            // No address provided — fall back to current PC from registers
            const reg_infos = session.driver.readRegisters(allocator, 1) catch
                return .{ .err = .{ .code = INVALID_PARAMS, .message = "Missing address and unable to read PC" } };
            defer allocator.free(reg_infos);
            for (reg_infos) |ri| {
                if (std.mem.eql(u8, ri.name, "pc") or std.mem.eql(u8, ri.name, "rip")) {
                    break :blk ri.value;
                }
            }
            break :blk if (reg_infos.len > 0) reg_infos[0].value else
                return .{ .err = .{ .code = INVALID_PARAMS, .message = "Missing address and unable to read PC" } };
        };

        const count: u32 = if (a.object.get("instruction_count")) |v| (if (v == .integer) @intCast(v.integer) else 10) else 10;

        const instruction_offset: ?i64 = if (a.object.get("instruction_offset")) |v| (if (v == .integer) v.integer else null) else null;
        const resolve_symbols: ?bool = if (a.object.get("resolve_symbols")) |v| (if (v == .bool) v.bool else null) else null;

        const instructions = session.driver.disassembleEx(allocator, address, count, instruction_offset, resolve_symbols) catch |err| {
            self.dashboard.onError("debug_disassemble", @errorName(err));
            return .{ .err = .{ .code = errorToCode(err), .message = @errorName(err) } };
        };
        var addr_buf: [18]u8 = undefined;
        const addr_display = std.fmt.bufPrint(&addr_buf, "0x{x}", .{address}) catch "0x?";
        self.dashboard.onDisassemble(session_id_val.string, addr_display, instructions.len);

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
        return .{ .ok = result };
    }

    fn toolAttach(self: *DebugServer, allocator: std.mem.Allocator, args: ?json.Value) !ToolResult {
        const a = args orelse return .{ .err = .{ .code = INVALID_PARAMS, .message = "Missing arguments" } };
        if (a != .object) return .{ .err = .{ .code = INVALID_PARAMS, .message = "Arguments must be object" } };

        const pid_val = a.object.get("pid") orelse return .{ .err = .{ .code = INVALID_PARAMS, .message = "Missing pid" } };
        if (pid_val != .integer) return .{ .err = .{ .code = INVALID_PARAMS, .message = "pid must be integer" } };

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
                return .{ .err = .{ .code = errorToCode(err), .message = @errorName(err) } };
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
                return .{ .err = .{ .code = errorToCode(err), .message = @errorName(err) } };
            };
            driver_type_name = "native";
        }

        const session_id = try self.session_manager.createSession(driver);
        if (self.session_manager.getSession(session_id)) |s| {
            s.status = .stopped;
        }
        self.dashboard.onLaunch(session_id, "attached", driver_type_name);
        self.dashboard.onAttach(session_id, pid_val.integer);
        self.emitLaunchEvent(session_id, "attached", driver_type_name);

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
        return .{ .ok = result };
    }

    fn toolSetVariable(self: *DebugServer, allocator: std.mem.Allocator, args: ?json.Value) !ToolResult {
        const a = args orelse return .{ .err = .{ .code = INVALID_PARAMS, .message = "Missing arguments" } };
        if (a != .object) return .{ .err = .{ .code = INVALID_PARAMS, .message = "Arguments must be object" } };

        const session_id_val = a.object.get("session_id") orelse return .{ .err = .{ .code = INVALID_PARAMS, .message = "Missing session_id" } };
        if (session_id_val != .string) return .{ .err = .{ .code = INVALID_PARAMS, .message = "session_id must be string" } };

        const session = self.session_manager.getSession(session_id_val.string) orelse
            return .{ .err = .{ .code = INVALID_PARAMS, .message = "Unknown session" } };

        const var_val = a.object.get("variable") orelse return .{ .err = .{ .code = INVALID_PARAMS, .message = "Missing variable" } };
        if (var_val != .string) return .{ .err = .{ .code = INVALID_PARAMS, .message = "variable must be string" } };

        const value_val = a.object.get("value") orelse return .{ .err = .{ .code = INVALID_PARAMS, .message = "Missing value" } };
        if (value_val != .string) return .{ .err = .{ .code = INVALID_PARAMS, .message = "value must be string" } };

        const frame_id: u32 = if (a.object.get("frame_id")) |v| (if (v == .integer) @intCast(v.integer) else 0) else 0;

        const result_val = session.driver.setVariable(allocator, var_val.string, value_val.string, frame_id) catch |err| {
            self.dashboard.onError("debug_set_variable", @errorName(err));
            return .{ .err = .{ .code = errorToCode(err), .message = @errorName(err) } };
        };
        self.dashboard.onSetVariable(session_id_val.string, var_val.string, value_val.string);
        defer result_val.deinit(allocator);

        var aw: Writer.Allocating = .init(allocator);
        defer aw.deinit();
        var s: Stringify = .{ .writer = &aw.writer };
        try result_val.jsonStringify(&s);
        const result = try aw.toOwnedSlice();
        return .{ .ok = result };
    }

    // ── Phase 4 Tool Implementations ────────────────────────────────

    fn toolScopes(self: *DebugServer, allocator: std.mem.Allocator, args: ?json.Value) !ToolResult {
        const a = args orelse return .{ .err = .{ .code = INVALID_PARAMS, .message = "Missing arguments" } };
        if (a != .object) return .{ .err = .{ .code = INVALID_PARAMS, .message = "Arguments must be object" } };

        const session_id_val = a.object.get("session_id") orelse return .{ .err = .{ .code = INVALID_PARAMS, .message = "Missing session_id" } };
        if (session_id_val != .string) return .{ .err = .{ .code = INVALID_PARAMS, .message = "session_id must be string" } };

        const session = self.session_manager.getSession(session_id_val.string) orelse
            return .{ .err = .{ .code = INVALID_PARAMS, .message = "Unknown session" } };

        const frame_id: u32 = if (a.object.get("frame_id")) |v| (if (v == .integer) @intCast(v.integer) else 0) else 0;

        const scope_list = session.driver.scopes(allocator, frame_id) catch |err| {
            self.dashboard.onError("debug_scopes", @errorName(err));
            return .{ .err = .{ .code = errorToCode(err), .message = @errorName(err) } };
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
        return .{ .ok = result };
    }

    fn toolWatchpoint(self: *DebugServer, allocator: std.mem.Allocator, args: ?json.Value) !ToolResult {
        const a = args orelse return .{ .err = .{ .code = INVALID_PARAMS, .message = "Missing arguments" } };
        if (a != .object) return .{ .err = .{ .code = INVALID_PARAMS, .message = "Arguments must be object" } };

        const session_id_val = a.object.get("session_id") orelse return .{ .err = .{ .code = INVALID_PARAMS, .message = "Missing session_id" } };
        if (session_id_val != .string) return .{ .err = .{ .code = INVALID_PARAMS, .message = "session_id must be string" } };

        const session = self.session_manager.getSession(session_id_val.string) orelse
            return .{ .err = .{ .code = INVALID_PARAMS, .message = "Unknown session" } };

        const var_val = a.object.get("variable") orelse return .{ .err = .{ .code = INVALID_PARAMS, .message = "Missing variable" } };
        if (var_val != .string) return .{ .err = .{ .code = INVALID_PARAMS, .message = "variable must be string" } };

        const access_str = if (a.object.get("access_type")) |v| (if (v == .string) v.string else "write") else "write";
        const access_type = types.DataBreakpointAccessType.parse(access_str) orelse .write;

        const frame_id: ?u32 = if (a.object.get("frame_id")) |v| (if (v == .integer) @as(u32, @intCast(v.integer)) else null) else null;

        // First, get data breakpoint info
        const info = session.driver.dataBreakpointInfo(allocator, var_val.string, frame_id) catch |err| {
            self.dashboard.onError("debug_watchpoint", @errorName(err));
            return .{ .err = .{ .code = errorToCode(err), .message = @errorName(err) } };
        };

        const data_id = info.data_id orelse {
            return .{ .err = .{ .code = INTERNAL_ERROR, .message = "Variable cannot be watched" } };
        };

        // Then set the data breakpoint
        const bp = session.driver.setDataBreakpoint(allocator, data_id, access_type) catch |err| {
            self.dashboard.onError("debug_watchpoint", @errorName(err));
            return .{ .err = .{ .code = errorToCode(err), .message = @errorName(err) } };
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
        return .{ .ok = result };
    }

    fn toolCapabilities(self: *DebugServer, allocator: std.mem.Allocator, args: ?json.Value) !ToolResult {
        const a = args orelse return .{ .err = .{ .code = INVALID_PARAMS, .message = "Missing arguments" } };
        if (a != .object) return .{ .err = .{ .code = INVALID_PARAMS, .message = "Arguments must be object" } };

        const session_id_val = a.object.get("session_id") orelse return .{ .err = .{ .code = INVALID_PARAMS, .message = "Missing session_id" } };
        if (session_id_val != .string) return .{ .err = .{ .code = INVALID_PARAMS, .message = "session_id must be string" } };

        const session = self.session_manager.getSession(session_id_val.string) orelse
            return .{ .err = .{ .code = INVALID_PARAMS, .message = "Unknown session" } };

        const caps = session.driver.capabilities();
        self.dashboard.onCapabilities(session_id_val.string);

        var aw: Writer.Allocating = .init(allocator);
        defer aw.deinit();
        var s: Stringify = .{ .writer = &aw.writer };
        try caps.jsonStringify(&s);
        const result = try aw.toOwnedSlice();
        return .{ .ok = result };
    }

    // ── Phase 5 Tool Implementations ────────────────────────────────

    fn toolCompletions(self: *DebugServer, allocator: std.mem.Allocator, args: ?json.Value) !ToolResult {
        const a = args orelse return .{ .err = .{ .code = INVALID_PARAMS, .message = "Missing arguments" } };
        if (a != .object) return .{ .err = .{ .code = INVALID_PARAMS, .message = "Arguments must be object" } };

        const session_id_val = a.object.get("session_id") orelse return .{ .err = .{ .code = INVALID_PARAMS, .message = "Missing session_id" } };
        if (session_id_val != .string) return .{ .err = .{ .code = INVALID_PARAMS, .message = "session_id must be string" } };

        const session = self.session_manager.getSession(session_id_val.string) orelse
            return .{ .err = .{ .code = INVALID_PARAMS, .message = "Unknown session" } };

        const text_val = a.object.get("text") orelse return .{ .err = .{ .code = INVALID_PARAMS, .message = "Missing text" } };
        if (text_val != .string) return .{ .err = .{ .code = INVALID_PARAMS, .message = "text must be string" } };

        const column: u32 = if (a.object.get("column")) |v| (if (v == .integer) @intCast(v.integer) else 0) else 0;
        const frame_id: ?u32 = if (a.object.get("frame_id")) |v| (if (v == .integer) @as(u32, @intCast(v.integer)) else null) else null;

        const items = session.driver.completions(allocator, text_val.string, column, frame_id) catch |err| {
            self.dashboard.onError("debug_completions", @errorName(err));
            return .{ .err = .{ .code = errorToCode(err), .message = @errorName(err) } };
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
        return .{ .ok = result };
    }

    fn toolModules(self: *DebugServer, allocator: std.mem.Allocator, args: ?json.Value) !ToolResult {
        const a = args orelse return .{ .err = .{ .code = INVALID_PARAMS, .message = "Missing arguments" } };
        if (a != .object) return .{ .err = .{ .code = INVALID_PARAMS, .message = "Arguments must be object" } };

        const session_id_val = a.object.get("session_id") orelse return .{ .err = .{ .code = INVALID_PARAMS, .message = "Missing session_id" } };
        if (session_id_val != .string) return .{ .err = .{ .code = INVALID_PARAMS, .message = "session_id must be string" } };

        const session = self.session_manager.getSession(session_id_val.string) orelse
            return .{ .err = .{ .code = INVALID_PARAMS, .message = "Unknown session" } };

        const mod_list = session.driver.modules(allocator) catch |err| {
            self.dashboard.onError("debug_modules", @errorName(err));
            return .{ .err = .{ .code = errorToCode(err), .message = @errorName(err) } };
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
        return .{ .ok = result };
    }

    fn toolLoadedSources(self: *DebugServer, allocator: std.mem.Allocator, args: ?json.Value) !ToolResult {
        const a = args orelse return .{ .err = .{ .code = INVALID_PARAMS, .message = "Missing arguments" } };
        if (a != .object) return .{ .err = .{ .code = INVALID_PARAMS, .message = "Arguments must be object" } };

        const session_id_val = a.object.get("session_id") orelse return .{ .err = .{ .code = INVALID_PARAMS, .message = "Missing session_id" } };
        if (session_id_val != .string) return .{ .err = .{ .code = INVALID_PARAMS, .message = "session_id must be string" } };

        const session = self.session_manager.getSession(session_id_val.string) orelse
            return .{ .err = .{ .code = INVALID_PARAMS, .message = "Unknown session" } };

        const source_list = session.driver.loadedSources(allocator) catch |err| {
            self.dashboard.onError("debug_loaded_sources", @errorName(err));
            return .{ .err = .{ .code = errorToCode(err), .message = @errorName(err) } };
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
        return .{ .ok = result };
    }

    fn toolSource(self: *DebugServer, allocator: std.mem.Allocator, args: ?json.Value) !ToolResult {
        const a = args orelse return .{ .err = .{ .code = INVALID_PARAMS, .message = "Missing arguments" } };
        if (a != .object) return .{ .err = .{ .code = INVALID_PARAMS, .message = "Arguments must be object" } };

        const session_id_val = a.object.get("session_id") orelse return .{ .err = .{ .code = INVALID_PARAMS, .message = "Missing session_id" } };
        if (session_id_val != .string) return .{ .err = .{ .code = INVALID_PARAMS, .message = "session_id must be string" } };

        const session = self.session_manager.getSession(session_id_val.string) orelse
            return .{ .err = .{ .code = INVALID_PARAMS, .message = "Unknown session" } };

        const ref_val = a.object.get("source_reference") orelse return .{ .err = .{ .code = INVALID_PARAMS, .message = "Missing source_reference" } };
        if (ref_val != .integer) return .{ .err = .{ .code = INVALID_PARAMS, .message = "source_reference must be integer" } };

        const content = session.driver.source(allocator, @intCast(ref_val.integer)) catch |err| {
            self.dashboard.onError("debug_source", @errorName(err));
            return .{ .err = .{ .code = errorToCode(err), .message = @errorName(err) } };
        };

        var aw: Writer.Allocating = .init(allocator);
        defer aw.deinit();
        var s: Stringify = .{ .writer = &aw.writer };
        try s.beginObject();
        try s.objectField("content");
        try s.write(content);
        try s.endObject();
        const result = try aw.toOwnedSlice();
        return .{ .ok = result };
    }

    fn toolSetExpression(self: *DebugServer, allocator: std.mem.Allocator, args: ?json.Value) !ToolResult {
        const a = args orelse return .{ .err = .{ .code = INVALID_PARAMS, .message = "Missing arguments" } };
        if (a != .object) return .{ .err = .{ .code = INVALID_PARAMS, .message = "Arguments must be object" } };

        const session_id_val = a.object.get("session_id") orelse return .{ .err = .{ .code = INVALID_PARAMS, .message = "Missing session_id" } };
        if (session_id_val != .string) return .{ .err = .{ .code = INVALID_PARAMS, .message = "session_id must be string" } };

        const session = self.session_manager.getSession(session_id_val.string) orelse
            return .{ .err = .{ .code = INVALID_PARAMS, .message = "Unknown session" } };

        const expr_val = a.object.get("expression") orelse return .{ .err = .{ .code = INVALID_PARAMS, .message = "Missing expression" } };
        if (expr_val != .string) return .{ .err = .{ .code = INVALID_PARAMS, .message = "expression must be string" } };

        const value_val = a.object.get("value") orelse return .{ .err = .{ .code = INVALID_PARAMS, .message = "Missing value" } };
        if (value_val != .string) return .{ .err = .{ .code = INVALID_PARAMS, .message = "value must be string" } };

        const frame_id: u32 = if (a.object.get("frame_id")) |v| (if (v == .integer) @intCast(v.integer) else 0) else 0;

        const result_val = session.driver.setExpression(allocator, expr_val.string, value_val.string, frame_id) catch |err| {
            self.dashboard.onError("debug_set_expression", @errorName(err));
            return .{ .err = .{ .code = errorToCode(err), .message = @errorName(err) } };
        };
        defer result_val.deinit(allocator);

        var aw: Writer.Allocating = .init(allocator);
        defer aw.deinit();
        var s: Stringify = .{ .writer = &aw.writer };
        try result_val.jsonStringify(&s);
        const result = try aw.toOwnedSlice();
        return .{ .ok = result };
    }

    // ── Phase 6 Tool Implementations ────────────────────────────────

    fn toolRestartFrame(self: *DebugServer, allocator: std.mem.Allocator, args: ?json.Value) !ToolResult {
        const a = args orelse return .{ .err = .{ .code = INVALID_PARAMS, .message = "Missing arguments" } };
        if (a != .object) return .{ .err = .{ .code = INVALID_PARAMS, .message = "Arguments must be object" } };

        const session_id_val = a.object.get("session_id") orelse return .{ .err = .{ .code = INVALID_PARAMS, .message = "Missing session_id" } };
        if (session_id_val != .string) return .{ .err = .{ .code = INVALID_PARAMS, .message = "session_id must be string" } };

        const session = self.session_manager.getSession(session_id_val.string) orelse
            return .{ .err = .{ .code = INVALID_PARAMS, .message = "Unknown session" } };

        const frame_id_val = a.object.get("frame_id") orelse return .{ .err = .{ .code = INVALID_PARAMS, .message = "Missing frame_id" } };
        if (frame_id_val != .integer) return .{ .err = .{ .code = INVALID_PARAMS, .message = "frame_id must be integer" } };

        session.driver.restartFrame(allocator, @intCast(frame_id_val.integer)) catch |err| {
            self.dashboard.onError("debug_restart_frame", @errorName(err));
            return .{ .err = .{ .code = errorToCode(err), .message = @errorName(err) } };
        };
        self.dashboard.onRestartFrame(session_id_val.string, @intCast(frame_id_val.integer));

        return .{ .ok = try allocator.dupe(u8, "{\"restarted\":true}") };
    }

    // ── Phase 7 Tool Implementations ────────────────────────────────

    fn toolExceptionInfo(self: *DebugServer, allocator: std.mem.Allocator, args: ?json.Value) !ToolResult {
        const a = args orelse return .{ .err = .{ .code = INVALID_PARAMS, .message = "Missing arguments" } };
        if (a != .object) return .{ .err = .{ .code = INVALID_PARAMS, .message = "Arguments must be object" } };

        const session_id_val = a.object.get("session_id") orelse return .{ .err = .{ .code = INVALID_PARAMS, .message = "Missing session_id" } };
        if (session_id_val != .string) return .{ .err = .{ .code = INVALID_PARAMS, .message = "session_id must be string" } };

        const session = self.session_manager.getSession(session_id_val.string) orelse
            return .{ .err = .{ .code = INVALID_PARAMS, .message = "Unknown session" } };

        const thread_id: u32 = if (a.object.get("thread_id")) |v| (if (v == .integer) @intCast(v.integer) else 1) else 1;

        const info = session.driver.exceptionInfo(allocator, thread_id) catch |err| {
            self.dashboard.onError("debug_exception_info", @errorName(err));
            return .{ .err = .{ .code = errorToCode(err), .message = @errorName(err) } };
        };
        self.dashboard.onExceptionInfo(session_id_val.string);

        var aw: Writer.Allocating = .init(allocator);
        defer aw.deinit();
        var s: Stringify = .{ .writer = &aw.writer };
        try info.jsonStringify(&s);
        const result = try aw.toOwnedSlice();
        return .{ .ok = result };
    }

    fn toolRegisters(self: *DebugServer, allocator: std.mem.Allocator, args: ?json.Value) !ToolResult {
        const a = args orelse return .{ .err = .{ .code = INVALID_PARAMS, .message = "Missing arguments" } };
        if (a != .object) return .{ .err = .{ .code = INVALID_PARAMS, .message = "Arguments must be object" } };

        const session_id_val = a.object.get("session_id") orelse return .{ .err = .{ .code = INVALID_PARAMS, .message = "Missing session_id" } };
        if (session_id_val != .string) return .{ .err = .{ .code = INVALID_PARAMS, .message = "session_id must be string" } };

        const session = self.session_manager.getSession(session_id_val.string) orelse
            return .{ .err = .{ .code = INVALID_PARAMS, .message = "Unknown session" } };

        const thread_id: u32 = if (a.object.get("thread_id")) |v| (if (v == .integer) @intCast(v.integer) else 1) else 1;

        const regs = session.driver.readRegisters(allocator, thread_id) catch |err| {
            self.dashboard.onError("debug_registers", @errorName(err));
            return .{ .err = .{ .code = errorToCode(err), .message = @errorName(err) } };
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
        return .{ .ok = result };
    }

    // ── Phase 12 Tool Implementations ────────────────────────────────

    fn toolInstructionBreakpoint(self: *DebugServer, allocator: std.mem.Allocator, args: ?json.Value) !ToolResult {
        const a = args orelse return .{ .err = .{ .code = INVALID_PARAMS, .message = "Missing arguments" } };
        if (a != .object) return .{ .err = .{ .code = INVALID_PARAMS, .message = "Arguments must be object" } };

        const session_id_val = a.object.get("session_id") orelse return .{ .err = .{ .code = INVALID_PARAMS, .message = "Missing session_id" } };
        if (session_id_val != .string) return .{ .err = .{ .code = INVALID_PARAMS, .message = "session_id must be string" } };

        const session = self.session_manager.getSession(session_id_val.string) orelse
            return .{ .err = .{ .code = INVALID_PARAMS, .message = "Unknown session" } };

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
            const instr_ref_val = a.object.get("instruction_reference") orelse return .{ .err = .{ .code = INVALID_PARAMS, .message = "Missing instruction_reference or breakpoints array" } };
            if (instr_ref_val != .string) return .{ .err = .{ .code = INVALID_PARAMS, .message = "instruction_reference must be string" } };

            try bp_list.append(allocator, .{
                .instruction_reference = instr_ref_val.string,
                .offset = if (a.object.get("offset")) |v| (if (v == .integer) v.integer else null) else null,
                .condition = if (a.object.get("condition")) |v| (if (v == .string) v.string else null) else null,
                .hit_condition = if (a.object.get("hit_condition")) |v| (if (v == .string) v.string else null) else null,
            });
        }

        const results = session.driver.setInstructionBreakpoints(allocator, bp_list.items) catch |err| {
            self.dashboard.onError("debug_instruction_breakpoint", @errorName(err));
            return .{ .err = .{ .code = errorToCode(err), .message = @errorName(err) } };
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
        return .{ .ok = result };
    }

    fn toolStepInTargets(self: *DebugServer, allocator: std.mem.Allocator, args: ?json.Value) !ToolResult {
        const a = args orelse return .{ .err = .{ .code = INVALID_PARAMS, .message = "Missing arguments" } };
        if (a != .object) return .{ .err = .{ .code = INVALID_PARAMS, .message = "Arguments must be object" } };

        const session_id_val = a.object.get("session_id") orelse return .{ .err = .{ .code = INVALID_PARAMS, .message = "Missing session_id" } };
        if (session_id_val != .string) return .{ .err = .{ .code = INVALID_PARAMS, .message = "session_id must be string" } };

        const session = self.session_manager.getSession(session_id_val.string) orelse
            return .{ .err = .{ .code = INVALID_PARAMS, .message = "Unknown session" } };

        const frame_id_val = a.object.get("frame_id") orelse return .{ .err = .{ .code = INVALID_PARAMS, .message = "Missing frame_id" } };
        if (frame_id_val != .integer) return .{ .err = .{ .code = INVALID_PARAMS, .message = "frame_id must be integer" } };

        const targets = session.driver.stepInTargets(allocator, @intCast(frame_id_val.integer)) catch |err| {
            self.dashboard.onError("debug_step_in_targets", @errorName(err));
            return .{ .err = .{ .code = errorToCode(err), .message = @errorName(err) } };
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
        return .{ .ok = result };
    }

    fn toolBreakpointLocations(self: *DebugServer, allocator: std.mem.Allocator, args: ?json.Value) !ToolResult {
        const a = args orelse return .{ .err = .{ .code = INVALID_PARAMS, .message = "Missing arguments" } };
        if (a != .object) return .{ .err = .{ .code = INVALID_PARAMS, .message = "Arguments must be object" } };

        const session_id_val = a.object.get("session_id") orelse return .{ .err = .{ .code = INVALID_PARAMS, .message = "Missing session_id" } };
        if (session_id_val != .string) return .{ .err = .{ .code = INVALID_PARAMS, .message = "session_id must be string" } };

        const session = self.session_manager.getSession(session_id_val.string) orelse
            return .{ .err = .{ .code = INVALID_PARAMS, .message = "Unknown session" } };

        const source_val = a.object.get("source") orelse return .{ .err = .{ .code = INVALID_PARAMS, .message = "Missing source" } };
        if (source_val != .string) return .{ .err = .{ .code = INVALID_PARAMS, .message = "source must be string" } };

        const line_val = a.object.get("line") orelse return .{ .err = .{ .code = INVALID_PARAMS, .message = "Missing line" } };
        if (line_val != .integer) return .{ .err = .{ .code = INVALID_PARAMS, .message = "line must be integer" } };

        const end_line: ?u32 = if (a.object.get("end_line")) |v| (if (v == .integer) @as(u32, @intCast(v.integer)) else null) else null;

        const locations = session.driver.breakpointLocations(allocator, source_val.string, @intCast(line_val.integer), end_line) catch |err| {
            self.dashboard.onError("debug_breakpoint_locations", @errorName(err));
            return .{ .err = .{ .code = errorToCode(err), .message = @errorName(err) } };
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
        return .{ .ok = result };
    }

    fn toolCancel(self: *DebugServer, allocator: std.mem.Allocator, args: ?json.Value) !ToolResult {
        const a = args orelse return .{ .err = .{ .code = INVALID_PARAMS, .message = "Missing arguments" } };
        if (a != .object) return .{ .err = .{ .code = INVALID_PARAMS, .message = "Arguments must be object" } };

        const session_id_val = a.object.get("session_id") orelse return .{ .err = .{ .code = INVALID_PARAMS, .message = "Missing session_id" } };
        if (session_id_val != .string) return .{ .err = .{ .code = INVALID_PARAMS, .message = "session_id must be string" } };

        const session = self.session_manager.getSession(session_id_val.string) orelse
            return .{ .err = .{ .code = INVALID_PARAMS, .message = "Unknown session" } };

        const request_id: ?u32 = if (a.object.get("request_id")) |v| (if (v == .integer) @as(u32, @intCast(v.integer)) else null) else null;
        const progress_id: ?[]const u8 = if (a.object.get("progress_id")) |v| (if (v == .string) v.string else null) else null;

        session.driver.cancel(allocator, request_id, progress_id) catch |err| {
            self.dashboard.onError("debug_cancel", @errorName(err));
            return .{ .err = .{ .code = errorToCode(err), .message = @errorName(err) } };
        };
        self.dashboard.onCancel(session_id_val.string);

        return .{ .ok = try allocator.dupe(u8, "{\"cancelled\":true}") };
    }

    fn toolTerminateThreads(self: *DebugServer, allocator: std.mem.Allocator, args: ?json.Value) !ToolResult {
        const a = args orelse return .{ .err = .{ .code = INVALID_PARAMS, .message = "Missing arguments" } };
        if (a != .object) return .{ .err = .{ .code = INVALID_PARAMS, .message = "Arguments must be object" } };

        const session_id_val = a.object.get("session_id") orelse return .{ .err = .{ .code = INVALID_PARAMS, .message = "Missing session_id" } };
        if (session_id_val != .string) return .{ .err = .{ .code = INVALID_PARAMS, .message = "session_id must be string" } };

        const session = self.session_manager.getSession(session_id_val.string) orelse
            return .{ .err = .{ .code = INVALID_PARAMS, .message = "Unknown session" } };

        const ids_val = a.object.get("thread_ids") orelse return .{ .err = .{ .code = INVALID_PARAMS, .message = "Missing thread_ids" } };
        if (ids_val != .array) return .{ .err = .{ .code = INVALID_PARAMS, .message = "thread_ids must be array" } };

        var id_list = std.ArrayListUnmanaged(u32).empty;
        defer id_list.deinit(allocator);
        for (ids_val.array.items) |item| {
            if (item == .integer) {
                try id_list.append(allocator, @intCast(item.integer));
            }
        }

        session.driver.terminateThreads(allocator, id_list.items) catch |err| {
            self.dashboard.onError("debug_terminate_threads", @errorName(err));
            return .{ .err = .{ .code = errorToCode(err), .message = @errorName(err) } };
        };
        self.dashboard.onTerminateThreads(session_id_val.string, id_list.items.len);

        return .{ .ok = try allocator.dupe(u8, "{\"terminated\":true}") };
    }

    fn toolRestart(self: *DebugServer, allocator: std.mem.Allocator, args: ?json.Value) !ToolResult {
        const a = args orelse return .{ .err = .{ .code = INVALID_PARAMS, .message = "Missing arguments" } };
        if (a != .object) return .{ .err = .{ .code = INVALID_PARAMS, .message = "Arguments must be object" } };

        const session_id_val = a.object.get("session_id") orelse return .{ .err = .{ .code = INVALID_PARAMS, .message = "Missing session_id" } };
        if (session_id_val != .string) return .{ .err = .{ .code = INVALID_PARAMS, .message = "session_id must be string" } };

        const session = self.session_manager.getSession(session_id_val.string) orelse
            return .{ .err = .{ .code = INVALID_PARAMS, .message = "Unknown session" } };

        session.driver.restart(allocator) catch |err| {
            self.dashboard.onError("debug_restart", @errorName(err));
            return .{ .err = .{ .code = errorToCode(err), .message = @errorName(err) } };
        };
        self.dashboard.onRestart(session_id_val.string);

        return .{ .ok = try allocator.dupe(u8, "{\"restarted\":true}") };
    }

    // ── Phase 4: New Tool Implementations ────────────────────────────────

    fn toolSessions(self: *DebugServer, allocator: std.mem.Allocator) !ToolResult {
        const sessions = self.session_manager.listSessions(allocator) catch |err| {
            return .{ .err = .{ .code = errorToCode(err), .message = @errorName(err) } };
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
        return .{ .ok = result };
    }

    fn toolGotoTargets(self: *DebugServer, allocator: std.mem.Allocator, args: ?json.Value) !ToolResult {
        const a = args orelse return .{ .err = .{ .code = INVALID_PARAMS, .message = "Missing arguments" } };
        if (a != .object) return .{ .err = .{ .code = INVALID_PARAMS, .message = "Arguments must be object" } };

        const session_id_val = a.object.get("session_id") orelse return .{ .err = .{ .code = INVALID_PARAMS, .message = "Missing session_id" } };
        if (session_id_val != .string) return .{ .err = .{ .code = INVALID_PARAMS, .message = "session_id must be string" } };

        const session = self.session_manager.getSession(session_id_val.string) orelse
            return .{ .err = .{ .code = INVALID_PARAMS, .message = "Unknown session" } };

        const file_val = a.object.get("file") orelse return .{ .err = .{ .code = INVALID_PARAMS, .message = "Missing file" } };
        if (file_val != .string) return .{ .err = .{ .code = INVALID_PARAMS, .message = "file must be string" } };

        const line_val = a.object.get("line") orelse return .{ .err = .{ .code = INVALID_PARAMS, .message = "Missing line" } };
        if (line_val != .integer) return .{ .err = .{ .code = INVALID_PARAMS, .message = "line must be integer" } };

        const targets = session.driver.gotoTargets(allocator, file_val.string, @intCast(line_val.integer)) catch |err| {
            self.dashboard.onError("debug_goto_targets", @errorName(err));
            return .{ .err = .{ .code = errorToCode(err), .message = @errorName(err) } };
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
        return .{ .ok = result };
    }

    fn toolFindSymbol(self: *DebugServer, allocator: std.mem.Allocator, args: ?json.Value) !ToolResult {
        const a = args orelse return .{ .err = .{ .code = INVALID_PARAMS, .message = "Missing arguments" } };
        if (a != .object) return .{ .err = .{ .code = INVALID_PARAMS, .message = "Arguments must be object" } };

        const session_id_val = a.object.get("session_id") orelse return .{ .err = .{ .code = INVALID_PARAMS, .message = "Missing session_id" } };
        if (session_id_val != .string) return .{ .err = .{ .code = INVALID_PARAMS, .message = "session_id must be string" } };

        const session = self.session_manager.getSession(session_id_val.string) orelse
            return .{ .err = .{ .code = INVALID_PARAMS, .message = "Unknown session" } };

        const name_val = a.object.get("name") orelse return .{ .err = .{ .code = INVALID_PARAMS, .message = "Missing name" } };
        if (name_val != .string) return .{ .err = .{ .code = INVALID_PARAMS, .message = "name must be string" } };

        const symbols = session.driver.findSymbol(allocator, name_val.string) catch |err| {
            self.dashboard.onError("debug_find_symbol", @errorName(err));
            return .{ .err = .{ .code = errorToCode(err), .message = @errorName(err) } };
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
        return .{ .ok = result };
    }

    // ── Phase 6: DWARF Engine Tools ─────────────────────────────────────

    fn toolWriteRegister(self: *DebugServer, allocator: std.mem.Allocator, args: ?json.Value) !ToolResult {
        const a = args orelse return .{ .err = .{ .code = INVALID_PARAMS, .message = "Missing arguments" } };
        if (a != .object) return .{ .err = .{ .code = INVALID_PARAMS, .message = "Arguments must be object" } };

        const session_id_val = a.object.get("session_id") orelse return .{ .err = .{ .code = INVALID_PARAMS, .message = "Missing session_id" } };
        if (session_id_val != .string) return .{ .err = .{ .code = INVALID_PARAMS, .message = "session_id must be string" } };

        const session = self.session_manager.getSession(session_id_val.string) orelse
            return .{ .err = .{ .code = INVALID_PARAMS, .message = "Unknown session" } };

        const name_val = a.object.get("name") orelse return .{ .err = .{ .code = INVALID_PARAMS, .message = "Missing name" } };
        if (name_val != .string) return .{ .err = .{ .code = INVALID_PARAMS, .message = "name must be string" } };

        const value_val = a.object.get("value") orelse return .{ .err = .{ .code = INVALID_PARAMS, .message = "Missing value" } };
        if (value_val != .integer) return .{ .err = .{ .code = INVALID_PARAMS, .message = "value must be integer" } };

        const thread_id: u32 = if (a.object.get("thread_id")) |v| (if (v == .integer) @intCast(v.integer) else 0) else 0;

        session.driver.writeRegisters(allocator, thread_id, name_val.string, @intCast(value_val.integer)) catch |err| {
            self.dashboard.onError("debug_write_register", @errorName(err));
            return .{ .err = .{ .code = errorToCode(err), .message = @errorName(err) } };
        };

        return .{ .ok = try allocator.dupe(u8, "{\"written\":true}") };
    }

    fn toolVariableLocation(self: *DebugServer, allocator: std.mem.Allocator, args: ?json.Value) !ToolResult {
        const a = args orelse return .{ .err = .{ .code = INVALID_PARAMS, .message = "Missing arguments" } };
        if (a != .object) return .{ .err = .{ .code = INVALID_PARAMS, .message = "Arguments must be object" } };

        const session_id_val = a.object.get("session_id") orelse return .{ .err = .{ .code = INVALID_PARAMS, .message = "Missing session_id" } };
        if (session_id_val != .string) return .{ .err = .{ .code = INVALID_PARAMS, .message = "session_id must be string" } };

        const session = self.session_manager.getSession(session_id_val.string) orelse
            return .{ .err = .{ .code = INVALID_PARAMS, .message = "Unknown session" } };

        const name_val = a.object.get("name") orelse return .{ .err = .{ .code = INVALID_PARAMS, .message = "Missing name" } };
        if (name_val != .string) return .{ .err = .{ .code = INVALID_PARAMS, .message = "name must be string" } };

        const frame_id: u32 = if (a.object.get("frame_id")) |v| (if (v == .integer) @intCast(v.integer) else 0) else 0;

        const loc = session.driver.variableLocation(allocator, name_val.string, frame_id) catch |err| {
            self.dashboard.onError("debug_variable_location", @errorName(err));
            return .{ .err = .{ .code = errorToCode(err), .message = @errorName(err) } };
        };

        var aw: Writer.Allocating = .init(allocator);
        defer aw.deinit();
        var jw: Stringify = .{ .writer = &aw.writer };
        try loc.jsonStringify(&jw);
        const result = try aw.toOwnedSlice();
        return .{ .ok = result };
    }

    // ── Event Polling ──────────────────────────────────────────────────

    fn toolPollEvents(self: *DebugServer, allocator: std.mem.Allocator, args: ?json.Value) !ToolResult {
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
        return .{ .ok = result };
    }

    // ── Prompts ──────────────────────────────────────────────────────────

    // ── Dashboard Socket ────────────────────────────────────────────────

    /// Attempt to connect to the standalone dashboard TUI.
    /// Silently continues if no TUI is running.
    pub fn connectDashboardSocket(self: *DebugServer) void {
        var path_buf: [128]u8 = undefined;
        const path = dashboard_tui.getSocketPath(&path_buf) orelse return;

        const sock = posix.socket(posix.AF.UNIX, posix.SOCK.STREAM, 0) catch return;
        errdefer posix.close(sock);

        var addr: posix.sockaddr.un = .{ .path = undefined };
        @memset(&addr.path, 0);
        if (path.len > addr.path.len) return;
        @memcpy(addr.path[0..path.len], path);

        posix.connect(sock, @ptrCast(&addr), @sizeOf(posix.sockaddr.un)) catch {
            posix.close(sock);
            return;
        };

        self.dashboard_socket = sock;
    }

    /// Write a JSON event line to the dashboard socket. Fire-and-forget.
    /// Proactively detects dead connections via poll(), reconnects, and
    /// retries once so events are not silently lost after dashboard restart.
    fn pushDashboardEvent(self: *DebugServer, event_json: []const u8) void {
        // Proactively detect dead connections before sending.
        // On macOS, send() to a broken Unix socket may deliver SIGPIPE
        // or silently succeed; poll() for HUP catches both cases.
        if (self.dashboard_socket) |sock| {
            var fds = [_]posix.pollfd{.{
                .fd = sock,
                .events = 0, // just check for error/hangup
                .revents = 0,
            }};
            const poll_result = posix.poll(&fds, 0) catch 0;
            if (poll_result > 0 and (fds[0].revents & (posix.POLL.HUP | posix.POLL.ERR) != 0)) {
                posix.close(sock);
                self.dashboard_socket = null;
            }
        }

        if (self.dashboard_socket == null) {
            self.connectDashboardSocket();
        }

        if (self.sendDashboardData(event_json)) return;

        // Send failed — connection is stale. Reconnect and retry once.
        if (self.dashboard_socket) |sock| {
            posix.close(sock);
            self.dashboard_socket = null;
        }
        self.connectDashboardSocket();
        _ = self.sendDashboardData(event_json);
    }

    /// Send event data + newline on the dashboard socket. Returns true on success.
    fn sendDashboardData(self: *DebugServer, event_json: []const u8) bool {
        const sock = self.dashboard_socket orelse return false;
        _ = posix.send(sock, event_json, 0) catch {
            posix.close(sock);
            self.dashboard_socket = null;
            return false;
        };
        _ = posix.send(sock, "\n", 0) catch {
            posix.close(sock);
            self.dashboard_socket = null;
            return false;
        };
        return true;
    }

    /// Emit a launch event to the dashboard TUI.
    fn emitLaunchEvent(self: *DebugServer, session_id: []const u8, program: []const u8, driver_type: []const u8) void {
        var buf: [512]u8 = undefined;
        const event = std.fmt.bufPrint(&buf,
            \\{{"type":"launch","session_id":"{s}","program":"{s}","driver":"{s}"}}
        , .{ truncateStr(session_id, 32), truncateStr(program, 200), truncateStr(driver_type, 16) }) catch return;
        self.pushDashboardEvent(event);
    }

    /// Emit a breakpoint event to the dashboard TUI.
    fn emitBreakpointEvent(self: *DebugServer, session_id: []const u8, action: []const u8, bp: types.BreakpointInfo) void {
        var buf: [512]u8 = undefined;
        const event = std.fmt.bufPrint(&buf,
            \\{{"type":"breakpoint","session_id":"{s}","action":"{s}","bp":{{"id":{d},"file":"{s}","line":{d},"verified":{s}}}}}
        , .{
            truncateStr(session_id, 32),
            truncateStr(action, 16),
            bp.id,
            truncateStr(bp.file, 200),
            bp.line,
            if (bp.verified) "true" else "false",
        }) catch return;
        self.pushDashboardEvent(event);
    }

    /// Emit a stop event (richest event — carries stack trace + locals).
    fn emitStopEvent(self: *DebugServer, session_id: []const u8, action: []const u8, state: types.StopState) void {
        // Build JSON using allocator since stop events can be large
        var aw: Writer.Allocating = .init(self.allocator);
        defer aw.deinit();
        var jw: Stringify = .{ .writer = &aw.writer };

        jw.beginObject() catch return;
        jw.objectField("type") catch return;
        jw.write("stop") catch return;
        jw.objectField("session_id") catch return;
        jw.write(session_id) catch return;
        jw.objectField("action") catch return;
        jw.write(action) catch return;
        jw.objectField("reason") catch return;
        jw.write(@tagName(state.stop_reason)) catch return;

        if (state.location) |loc| {
            jw.objectField("location") catch return;
            jw.beginObject() catch return;
            jw.objectField("file") catch return;
            jw.write(loc.file) catch return;
            jw.objectField("line") catch return;
            jw.write(loc.line) catch return;
            jw.objectField("function") catch return;
            jw.write(loc.function) catch return;
            jw.endObject() catch return;
        }

        if (state.stack_trace.len > 0) {
            jw.objectField("stack_trace") catch return;
            jw.beginArray() catch return;
            for (state.stack_trace) |*frame| {
                jw.beginObject() catch return;
                jw.objectField("name") catch return;
                jw.write(frame.name) catch return;
                jw.objectField("source") catch return;
                jw.write(frame.source) catch return;
                jw.objectField("line") catch return;
                jw.write(frame.line) catch return;
                jw.endObject() catch return;
            }
            jw.endArray() catch return;
        }

        if (state.locals.len > 0) {
            jw.objectField("locals") catch return;
            jw.beginArray() catch return;
            for (state.locals) |*v| {
                jw.beginObject() catch return;
                jw.objectField("name") catch return;
                jw.write(v.name) catch return;
                jw.objectField("value") catch return;
                jw.write(v.value) catch return;
                jw.objectField("type") catch return;
                jw.write(v.@"type") catch return;
                jw.endObject() catch return;
            }
            jw.endArray() catch return;
        }

        jw.endObject() catch return;

        const event = aw.toOwnedSlice() catch return;
        defer self.allocator.free(event);
        self.pushDashboardEvent(event);
    }

    /// Emit an inspect event to the dashboard TUI.
    fn emitInspectEvent(self: *DebugServer, session_id: []const u8, expression: []const u8, result_str: []const u8, var_type: []const u8) void {
        var buf: [512]u8 = undefined;
        const event = std.fmt.bufPrint(&buf,
            \\{{"type":"inspect","session_id":"{s}","expression":"{s}","result":"{s}","var_type":"{s}"}}
        , .{
            truncateStr(session_id, 32),
            truncateStr(expression, 100),
            truncateStr(result_str, 200),
            truncateStr(var_type, 64),
        }) catch return;
        self.pushDashboardEvent(event);
    }

    /// Emit a session end event to the dashboard TUI.
    fn emitSessionEndEvent(self: *DebugServer, session_id: []const u8) void {
        var buf: [128]u8 = undefined;
        const event = std.fmt.bufPrint(&buf,
            \\{{"type":"session_end","session_id":"{s}"}}
        , .{truncateStr(session_id, 32)}) catch return;
        self.pushDashboardEvent(event);
    }

    /// Emit an error event to the dashboard TUI.
    fn emitErrorEvent(self: *DebugServer, session_id: []const u8, method: []const u8, message: []const u8) void {
        var buf: [512]u8 = undefined;
        const event = std.fmt.bufPrint(&buf,
            \\{{"type":"error","session_id":"{s}","method":"{s}","message":"{s}"}}
        , .{ truncateStr(session_id, 32), truncateStr(method, 32), truncateStr(message, 200) }) catch return;
        self.pushDashboardEvent(event);
    }

    /// Emit a generic activity event to the dashboard TUI.
    fn emitActivityEvent(self: *DebugServer, session_id: []const u8, tool: []const u8, summary: []const u8) void {
        var buf: [512]u8 = undefined;
        const event = std.fmt.bufPrint(&buf,
            \\{{"type":"activity","session_id":"{s}","tool":"{s}","summary":"{s}"}}
        , .{ truncateStr(session_id, 32), truncateStr(tool, 32), truncateStr(summary, 200) }) catch return;
        self.pushDashboardEvent(event);
    }

    /// Emit a run event (execution resumed, before stop).
    fn emitRunEvent(self: *DebugServer, session_id: []const u8, action: []const u8) void {
        var buf: [256]u8 = undefined;
        const event = std.fmt.bufPrint(&buf,
            \\{{"type":"run","session_id":"{s}","action":"{s}"}}
        , .{ truncateStr(session_id, 32), truncateStr(action, 32) }) catch return;
        self.pushDashboardEvent(event);
    }

};

fn truncateStr(s: []const u8, max: usize) []const u8 {
    return if (s.len <= max) s else s[0..max];
}

// ── Tests ───────────────────────────────────────────────────────────────

test "tool_definitions has 34 entries" {
    try std.testing.expectEqual(@as(usize, 34), tool_definitions.len);
}

test "callTool returns error for unknown tool" {
    const allocator = std.testing.allocator;
    var srv = DebugServer.init(allocator);
    defer srv.deinit();

    const result = try srv.callTool(allocator, "nonexistent_tool", null);
    switch (result) {
        .err => |e| try std.testing.expectEqual(METHOD_NOT_FOUND, e.code),
        .ok => unreachable,
    }
}

test "callTool dispatches debug_stop" {
    const allocator = std.testing.allocator;
    var srv = DebugServer.init(allocator);
    defer srv.deinit();

    const args_str =
        \\{"session_id":"nonexistent"}
    ;
    const args_parsed = try json.parseFromSlice(json.Value, allocator, args_str, .{});
    defer args_parsed.deinit();

    const result = try srv.callTool(allocator, "debug_stop", args_parsed.value);
    switch (result) {
        .ok => |raw| {
            defer allocator.free(raw);
            // Should contain stopped:true
            try std.testing.expect(std.mem.indexOf(u8, raw, "\"stopped\":true") != null);
        },
        .err => unreachable,
    }
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
