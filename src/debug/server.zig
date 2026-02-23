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

// Debug logging to file
var server_log_file: ?std.fs.File = null;

fn serverLog(comptime fmt: []const u8, args: anytype) void {
    if (server_log_file == null) {
        server_log_file = std.fs.cwd().createFile("/tmp/cog-dap-debug.log", .{ .truncate = false }) catch null;
        if (server_log_file) |f| f.seekFromEnd(0) catch {};
    }
    const f = server_log_file orelse return;
    var buf: [128]u8 = undefined;
    const ts = std.time.timestamp();
    const prefix = std.fmt.bufPrint(&buf, "[{d}] ", .{ts}) catch return;
    f.writeAll(prefix) catch return;
    var msg_buf: [8192]u8 = undefined;
    const msg = std.fmt.bufPrint(&msg_buf, fmt, args) catch return;
    f.writeAll(msg) catch return;
    f.writeAll("\n") catch return;
}

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

/// Map dependency errors to human-readable messages with install instructions.
pub fn errorMessage(err: anyerror) []const u8 {
    if (err == error.PythonNotFound) return "python3 not found on PATH";
    if (err == error.DebugpyNotInstalled) return "debugpy module not found for python3";
    if (err == error.DelveNotFound) return "dlv (Delve) not found on PATH";
    if (err == error.NodeNotFound) return "node not found on PATH";
    if (err == error.UnsupportedLanguage) return "Unsupported language for debugging";
    return @errorName(err);
}

// ── Tool Definitions ────────────────────────────────────────────────────

pub const tool_definitions = [_]ToolDef{
    .{
        .name = "cog_debug_launch",
        .description = "Start a new debug session by launching a program. Returns a session_id used by all other debug tools. The program is paused before execution begins if stop_on_entry is true, otherwise it runs until a breakpoint is hit or it exits.",
        .input_schema = debug_launch_schema,
    },
    .{
        .name = "cog_debug_breakpoint",
        .description = "Manage breakpoints in a debug session. Use action 'set' for line breakpoints (requires file + line), 'set_function' for function-name breakpoints (requires function), 'set_exception' for exception breakpoints (use filters to specify exception types, e.g. [\"raised\"] or [\"uncaught\"]), 'remove' to delete a breakpoint by id, 'list' to show all active breakpoints.",
        .input_schema = debug_breakpoint_schema,
    },
    .{
        .name = "cog_debug_run",
        .description = "Control program execution. Actions: 'continue' resumes until next breakpoint or exit, 'step_over' executes current line and stops at next line, 'step_into' enters function calls, 'step_out' runs until current function returns, 'pause' suspends a running program, 'restart' re-runs from the beginning, 'goto' jumps to a specific file:line (use with file and line params).",
        .input_schema = debug_run_schema,
    },
    .{
        .name = "cog_debug_inspect",
        .description = "Evaluate expressions or inspect variables. To evaluate an expression, pass 'expression' (e.g. \"x + y\", \"len(items)\"). To list variables in a scope, pass 'scope' (locals, globals, or arguments). To expand a compound variable (object, array, struct), pass the 'variable_ref' number from a previous inspect result. Use 'frame_id' to inspect a specific stack frame (default: topmost).",
        .input_schema = debug_inspect_schema,
    },
    .{
        .name = "cog_debug_stop",
        .description = "End a debug session and terminate the debuggee process. Always call this when done debugging to clean up resources.",
        .input_schema = debug_stop_schema,
    },
    .{
        .name = "cog_debug_threads",
        .description = "List all threads in the debuggee process with their IDs and names. Use thread IDs with stacktrace to inspect specific threads.",
        .input_schema = debug_threads_schema,
    },
    .{
        .name = "cog_debug_stacktrace",
        .description = "Get the call stack for a thread, showing the chain of function calls that led to the current execution point. Each frame includes a frame_id, function name, file path, and line number. Use frame_id with inspect to examine variables in a specific frame.",
        .input_schema = debug_stacktrace_schema,
    },
    .{
        .name = "cog_debug_memory",
        .description = "Read or write raw process memory at a hex address. Use action 'read' with address and size to read bytes, 'write' with address and hex data string to write bytes.",
        .input_schema = debug_memory_schema,
    },
    .{
        .name = "cog_debug_disassemble",
        .description = "Disassemble machine instructions at a memory address. Returns assembly instructions with addresses and optional symbol names. Useful for low-level debugging of compiled code.",
        .input_schema = debug_disassemble_schema,
    },
    .{
        .name = "cog_debug_attach",
        .description = "Attach the debugger to an already-running process by its PID. Returns a session_id for use with other debug tools. The process is paused upon attach.",
        .input_schema = debug_attach_schema,
    },
    .{
        .name = "cog_debug_set_variable",
        .description = "Modify a variable's value at runtime in the current scope. Use for testing hypotheses during debugging (e.g. \"what if this value were 0?\"). The change is temporary and only affects the running process.",
        .input_schema = debug_set_variable_schema,
    },
    .{
        .name = "cog_debug_scopes",
        .description = "List the variable scopes (locals, globals, arguments) available in a stack frame. Returns scope names and variable reference IDs. Pass a variable_ref to inspect to expand and view the variables within each scope.",
        .input_schema = debug_scopes_schema,
    },
    .{
        .name = "cog_debug_watchpoint",
        .description = "Set a data breakpoint that pauses execution when a variable is read, written, or both. Useful for finding where a value gets unexpectedly changed.",
        .input_schema = debug_watchpoint_schema,
    },
    .{
        .name = "cog_debug_capabilities",
        .description = "Query what features the debug driver supports (e.g. variable mutation, conditional breakpoints, restart frame, goto). Call this after launch to know what operations are available for the target language/runtime.",
        .input_schema = debug_capabilities_schema,
    },
    .{
        .name = "cog_debug_completions",
        .description = "Get auto-completions for partial variable names or expressions in the debug REPL context. Useful for discovering available variables and methods.",
        .input_schema = debug_completions_schema,
    },
    .{
        .name = "cog_debug_modules",
        .description = "List all loaded shared libraries and modules in the debuggee process, including their paths and address ranges.",
        .input_schema = debug_modules_schema,
    },
    .{
        .name = "cog_debug_loaded_sources",
        .description = "List all source files the debugger knows about in the current session. Useful for finding the correct file paths for setting breakpoints.",
        .input_schema = debug_loaded_sources_schema,
    },
    .{
        .name = "cog_debug_source",
        .description = "Retrieve source code for a file identified by its source_reference ID (from stacktrace or loadedSources results). Use when the source isn't available on disk.",
        .input_schema = debug_source_schema,
    },
    .{
        .name = "cog_debug_set_expression",
        .description = "Evaluate an expression and assign its result to a new value. More powerful than setVariable — supports complex left-hand expressions like struct fields or array elements.",
        .input_schema = debug_set_expression_schema,
    },
    .{
        .name = "cog_debug_restart_frame",
        .description = "Re-execute a function from the beginning of a specific stack frame. Useful for re-running a function with modified variables without restarting the whole program.",
        .input_schema = debug_restart_frame_schema,
    },
    .{
        .name = "cog_debug_exception_info",
        .description = "Get details about the exception that caused the program to stop, including the exception type, message, and full stack trace. Call this when the program stops at an exception breakpoint.",
        .input_schema = debug_exception_info_schema,
    },
    .{
        .name = "cog_debug_registers",
        .description = "Read CPU register values (native engine only, not available for DAP sessions). Returns register names and their current values.",
        .input_schema = debug_registers_schema,
    },
    .{
        .name = "cog_debug_instruction_breakpoint",
        .description = "Set a breakpoint at a specific machine instruction address. For low-level debugging when source-level breakpoints aren't sufficient.",
        .input_schema = debug_instruction_breakpoint_schema,
    },
    .{
        .name = "cog_debug_step_in_targets",
        .description = "When a line has multiple function calls, list which functions can be stepped into individually. Use the returned target ID with a step_into action to enter a specific call.",
        .input_schema = debug_step_in_targets_schema,
    },
    .{
        .name = "cog_debug_breakpoint_locations",
        .description = "Find the valid positions where breakpoints can be set within a line range. Use this when a breakpoint on a specific line doesn't work — the actual valid location may differ.",
        .input_schema = debug_breakpoint_locations_schema,
    },
    .{
        .name = "cog_debug_cancel",
        .description = "Cancel a long-running debug request that hasn't completed yet.",
        .input_schema = debug_cancel_schema,
    },
    .{
        .name = "cog_debug_terminate_threads",
        .description = "Terminate specific threads by their IDs while keeping the debug session alive.",
        .input_schema = debug_terminate_threads_schema,
    },
    .{
        .name = "cog_debug_restart",
        .description = "Restart the entire debug session from the beginning, re-launching the program with the same arguments and breakpoints.",
        .input_schema = debug_restart_schema,
    },
    .{
        .name = "cog_debug_sessions",
        .description = "List all active debug sessions with their IDs and status. Use to find session_id values or check if a previous session is still alive.",
        .input_schema = debug_sessions_schema,
    },
    .{
        .name = "cog_debug_goto_targets",
        .description = "Find valid goto target locations for a source line. Returns target IDs that can be used with the 'goto' action in run to jump execution to that point.",
        .input_schema = debug_goto_targets_schema,
    },
    .{
        .name = "cog_debug_find_symbol",
        .description = "Search for a symbol definition by name in the debuggee's symbol table (native engine only, not available for DAP sessions). Returns the symbol's address and type.",
        .input_schema = debug_find_symbol_schema,
    },
    .{
        .name = "cog_debug_write_register",
        .description = "Write a value to a CPU register (native engine only, not available for DAP sessions). Use with caution — incorrect values can crash the debuggee.",
        .input_schema = debug_write_register_schema,
    },
    .{
        .name = "cog_debug_variable_location",
        .description = "Get the physical storage location of a variable — whether it's in a register, on the stack, or in memory (native engine only, not available for DAP sessions).",
        .input_schema = debug_variable_location_schema,
    },
    .{
        .name = "cog_debug_poll_events",
        .description = "Check for pending debug events like breakpoint hits, program exits, or thread stops. Call this after a 'continue' or 'step' action to see what happened.",
        .input_schema = debug_poll_events_schema,
    },
    .{
        .name = "cog_debug_load_core",
        .description = "Load a core dump file for post-mortem debugging. Allows inspecting the program state at the time of a crash without re-running the program.",
        .input_schema = debug_load_core_schema,
    },
    .{
        .name = "cog_debug_dap_request",
        .description = "Send a raw DAP (Debug Adapter Protocol) request directly to the debug adapter. Escape hatch for DAP features not covered by other tools. Requires knowledge of the DAP specification.",
        .input_schema = debug_dap_request_schema,
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
    \\{"type":"object","properties":{"session_id":{"type":"string","description":"Debug session ID from launch or attach"},"action":{"type":"string","enum":["set","remove","list","set_function","set_exception"],"description":"set: line breakpoint (file+line), set_function: break on function entry (function), set_exception: break on exceptions (filters), remove: delete by id, list: show all"},"file":{"type":"string","description":"Source file path (for set action)"},"line":{"type":"integer","description":"Line number (for set action)"},"condition":{"type":"string","description":"Expression that must be true for breakpoint to trigger"},"hit_condition":{"type":"string","description":"Break after N hits (e.g. \"> 5\", \"== 3\")"},"log_message":{"type":"string","description":"Log this message instead of stopping (logpoint). Expressions in {} are interpolated."},"function":{"type":"string","description":"Function name (for set_function action)"},"filters":{"type":"array","items":{"type":"string"},"description":"Exception filter IDs for set_exception (e.g. [\"raised\"], [\"uncaught\"])"},"id":{"type":"integer","description":"Breakpoint ID to remove (for remove action)"}},"required":["session_id","action"]}
;

pub const debug_run_schema =
    \\{"type":"object","properties":{"session_id":{"type":"string","description":"Debug session ID"},"action":{"type":"string","enum":["continue","step_into","step_over","step_out","restart","pause","goto","reverse_continue","step_back"],"description":"continue: run until next breakpoint, step_over: next line, step_into: enter function, step_out: finish current function, pause: suspend running program, goto: jump to file:line, restart: re-run from start"},"file":{"type":"string","description":"Target file for goto action"},"line":{"type":"integer","description":"Target line for goto action"},"granularity":{"type":"string","enum":["statement","line","instruction"],"description":"Stepping granularity (default: statement)"}},"required":["session_id","action"]}
;

pub const debug_inspect_schema =
    \\{"type":"object","properties":{"session_id":{"type":"string","description":"Debug session ID"},"expression":{"type":"string","description":"Expression to evaluate (e.g. \"x + 1\", \"obj.field\", \"len(arr)\")"},"variable_ref":{"type":"integer","description":"Variable reference ID from a previous inspect or scopes result — use to expand compound variables (objects, arrays, structs)"},"frame_id":{"type":"integer","description":"Stack frame to evaluate in (0 = topmost frame, from stacktrace results)"},"scope":{"type":"string","enum":["locals","globals","arguments"],"description":"List all variables in this scope instead of evaluating an expression"},"context":{"type":"string","enum":["watch","repl","hover","clipboard"],"description":"Evaluation context hint for the debug adapter (default: repl)"}},"required":["session_id"]}
;

pub const debug_stop_schema =
    \\{"type":"object","properties":{"session_id":{"type":"string","description":"Debug session ID"},"terminate_only":{"type":"boolean","default":false,"description":"If true, terminate the debuggee but keep the debug adapter alive (DAP only)"},"detach":{"type":"boolean","default":false,"description":"Detach from debuggee without terminating"}},"required":["session_id"]}
;

pub const debug_threads_schema =
    \\{"type":"object","properties":{"session_id":{"type":"string","description":"Debug session ID"}},"required":["session_id"]}
;

pub const debug_stacktrace_schema =
    \\{"type":"object","properties":{"session_id":{"type":"string","description":"Debug session ID"},"thread_id":{"type":"integer","default":1,"description":"Thread to get stack from (default: main thread)"},"start_frame":{"type":"integer","default":0,"description":"Skip this many frames from the top"},"levels":{"type":"integer","default":20,"description":"Maximum number of frames to return"}},"required":["session_id"]}
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
    \\{"type":"object","properties":{"session_id":{"type":"string","description":"Debug session ID"},"variable":{"type":"string","description":"Variable name to modify"},"value":{"type":"string","description":"New value as a string (e.g. \"42\", \"true\", \"\\\"hello\\\"\")"},"frame_id":{"type":"integer","default":0,"description":"Stack frame context (0 = topmost)"}},"required":["session_id","variable","value"]}
;

pub const debug_scopes_schema =
    \\{"type":"object","properties":{"session_id":{"type":"string","description":"Debug session ID"},"frame_id":{"type":"integer","default":0,"description":"Stack frame to get scopes for (0 = topmost, from stacktrace results)"}},"required":["session_id"]}
;

pub const debug_watchpoint_schema =
    \\{"type":"object","properties":{"session_id":{"type":"string","description":"Debug session ID"},"variable":{"type":"string","description":"Variable name to watch"},"access_type":{"type":"string","enum":["read","write","readWrite"],"default":"write","description":"Break on read, write, or both (default: write)"},"frame_id":{"type":"integer","description":"Stack frame context for variable resolution"}},"required":["session_id","variable"]}
;

pub const debug_capabilities_schema =
    \\{"type":"object","properties":{"session_id":{"type":"string","description":"Debug session ID"}},"required":["session_id"]}
;

pub const debug_completions_schema =
    \\{"type":"object","properties":{"session_id":{"type":"string","description":"Debug session ID"},"text":{"type":"string","description":"Partial text to complete"},"column":{"type":"integer","default":0,"description":"Cursor column position in the text"},"frame_id":{"type":"integer","description":"Stack frame context for completions"}},"required":["session_id","text"]}
;

pub const debug_modules_schema =
    \\{"type":"object","properties":{"session_id":{"type":"string","description":"Debug session ID"}},"required":["session_id"]}
;

pub const debug_loaded_sources_schema =
    \\{"type":"object","properties":{"session_id":{"type":"string","description":"Debug session ID"}},"required":["session_id"]}
;

pub const debug_source_schema =
    \\{"type":"object","properties":{"session_id":{"type":"string","description":"Debug session ID"},"source_reference":{"type":"integer","description":"Source reference ID from stacktrace or loadedSources results"}},"required":["session_id","source_reference"]}
;

pub const debug_set_expression_schema =
    \\{"type":"object","properties":{"session_id":{"type":"string","description":"Debug session ID"},"expression":{"type":"string","description":"Left-hand expression to assign to (e.g. \"obj.field\", \"arr[0]\")"},"value":{"type":"string","description":"New value to assign"},"frame_id":{"type":"integer","default":0,"description":"Stack frame context"}},"required":["session_id","expression","value"]}
;

pub const debug_restart_frame_schema =
    \\{"type":"object","properties":{"session_id":{"type":"string","description":"Debug session ID"},"frame_id":{"type":"integer","description":"Stack frame ID to restart from (from stacktrace results)"}},"required":["session_id","frame_id"]}
;

pub const debug_exception_info_schema =
    \\{"type":"object","properties":{"session_id":{"type":"string","description":"Debug session ID"},"thread_id":{"type":"integer","default":1,"description":"Thread that hit the exception"}},"required":["session_id"]}
;

pub const debug_registers_schema =
    \\{"type":"object","properties":{"session_id":{"type":"string","description":"Debug session ID"},"thread_id":{"type":"integer","default":1,"description":"Thread to read registers from"}},"required":["session_id"]}
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
    \\{"type":"object","properties":{"session_id":{"type":"string","description":"Debug session ID"},"request_id":{"type":"integer","description":"ID of the request to cancel"},"progress_id":{"type":"string","description":"ID of the progress to cancel"}},"required":["session_id"]}
;

pub const debug_terminate_threads_schema =
    \\{"type":"object","properties":{"session_id":{"type":"string","description":"Debug session ID"},"thread_ids":{"type":"array","items":{"type":"integer"},"description":"Thread IDs to terminate (from threads results)"}},"required":["session_id","thread_ids"]}
;

pub const debug_restart_schema =
    \\{"type":"object","properties":{"session_id":{"type":"string","description":"Debug session ID"}},"required":["session_id"]}
;

pub const debug_sessions_schema =
    \\{"type":"object","properties":{}}
;

pub const debug_goto_targets_schema =
    \\{"type":"object","properties":{"session_id":{"type":"string","description":"Debug session ID"},"file":{"type":"string","description":"Source file path"},"line":{"type":"integer","description":"Target line number"}},"required":["session_id","file","line"]}
;

pub const debug_find_symbol_schema =
    \\{"type":"object","properties":{"session_id":{"type":"string","description":"Debug session ID"},"name":{"type":"string","description":"Symbol name to search for"}},"required":["session_id","name"]}
;

pub const debug_write_register_schema =
    \\{"type":"object","properties":{"session_id":{"type":"string","description":"Debug session ID"},"name":{"type":"string","description":"Register name (e.g. rax, rsp, pc)"},"value":{"type":"integer","description":"Value to write"},"thread_id":{"type":"integer","default":0,"description":"Thread to write register in"}},"required":["session_id","name","value"]}
;

pub const debug_variable_location_schema =
    \\{"type":"object","properties":{"session_id":{"type":"string","description":"Debug session ID"},"name":{"type":"string","description":"Variable name to locate"},"frame_id":{"type":"integer","default":0,"description":"Stack frame context"}},"required":["session_id","name"]}
;

pub const debug_poll_events_schema =
    \\{"type":"object","properties":{"session_id":{"type":"string","description":"Poll specific session, or omit for all sessions"}}}
;

pub const debug_load_core_schema =
    \\{"type":"object","properties":{"core_path":{"type":"string","description":"Path to core dump file"},"executable":{"type":"string","description":"Path to the executable that generated the core dump"}},"required":["core_path"]}
;

pub const debug_dap_request_schema =
    \\{"type":"object","properties":{"session_id":{"type":"string"},"command":{"type":"string","description":"DAP command name (e.g. evaluate, threads)"},"arguments":{"type":"object","description":"DAP request arguments"}},"required":["session_id","command"]}
;

// ── Tool Result Type ────────────────────────────────────────────────────

pub const ToolResult = union(enum) {
    ok: []const u8, // raw JSON result string (caller-owned)
    ok_static: []const u8, // raw JSON result string (static literal, not freed)
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
    /// Whether a dashboard TUI is likely available (false after failed connection)
    dashboard_available: bool = true,
    /// Timestamp of last failed dashboard connection attempt (for backoff)
    last_dashboard_attempt: i64 = 0,

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
        serverLog("[DebugServer.callTool] Dispatching tool: {s}", .{tool_name});
        if (std.mem.eql(u8, tool_name, "cog_debug_launch")) {
            serverLog("[DebugServer.callTool] -> toolLaunch", .{});
            return self.toolLaunch(allocator, tool_args);
        } else if (std.mem.eql(u8, tool_name, "cog_debug_breakpoint")) {
            return self.toolBreakpoint(allocator, tool_args);
        } else if (std.mem.eql(u8, tool_name, "cog_debug_run")) {
            return self.toolRun(allocator, tool_args);
        } else if (std.mem.eql(u8, tool_name, "cog_debug_inspect")) {
            return self.toolInspect(allocator, tool_args);
        } else if (std.mem.eql(u8, tool_name, "cog_debug_stop")) {
            return self.toolStop(allocator, tool_args);
        } else if (std.mem.eql(u8, tool_name, "cog_debug_threads")) {
            return self.toolThreads(allocator, tool_args);
        } else if (std.mem.eql(u8, tool_name, "cog_debug_stacktrace")) {
            return self.toolStackTrace(allocator, tool_args);
        } else if (std.mem.eql(u8, tool_name, "cog_debug_memory")) {
            return self.toolMemory(allocator, tool_args);
        } else if (std.mem.eql(u8, tool_name, "cog_debug_disassemble")) {
            return self.toolDisassemble(allocator, tool_args);
        } else if (std.mem.eql(u8, tool_name, "cog_debug_attach")) {
            return self.toolAttach(allocator, tool_args);
        } else if (std.mem.eql(u8, tool_name, "cog_debug_set_variable")) {
            return self.toolSetVariable(allocator, tool_args);
        } else if (std.mem.eql(u8, tool_name, "cog_debug_scopes")) {
            return self.toolScopes(allocator, tool_args);
        } else if (std.mem.eql(u8, tool_name, "cog_debug_watchpoint")) {
            return self.toolWatchpoint(allocator, tool_args);
        } else if (std.mem.eql(u8, tool_name, "cog_debug_capabilities")) {
            return self.toolCapabilities(allocator, tool_args);
        } else if (std.mem.eql(u8, tool_name, "cog_debug_completions")) {
            return self.toolCompletions(allocator, tool_args);
        } else if (std.mem.eql(u8, tool_name, "cog_debug_modules")) {
            return self.toolModules(allocator, tool_args);
        } else if (std.mem.eql(u8, tool_name, "cog_debug_loaded_sources")) {
            return self.toolLoadedSources(allocator, tool_args);
        } else if (std.mem.eql(u8, tool_name, "cog_debug_source")) {
            return self.toolSource(allocator, tool_args);
        } else if (std.mem.eql(u8, tool_name, "cog_debug_set_expression")) {
            return self.toolSetExpression(allocator, tool_args);
        } else if (std.mem.eql(u8, tool_name, "cog_debug_restart_frame")) {
            return self.toolRestartFrame(allocator, tool_args);
        } else if (std.mem.eql(u8, tool_name, "cog_debug_exception_info")) {
            return self.toolExceptionInfo(allocator, tool_args);
        } else if (std.mem.eql(u8, tool_name, "cog_debug_registers")) {
            return self.toolRegisters(allocator, tool_args);
        } else if (std.mem.eql(u8, tool_name, "cog_debug_instruction_breakpoint")) {
            return self.toolInstructionBreakpoint(allocator, tool_args);
        } else if (std.mem.eql(u8, tool_name, "cog_debug_step_in_targets")) {
            return self.toolStepInTargets(allocator, tool_args);
        } else if (std.mem.eql(u8, tool_name, "cog_debug_breakpoint_locations")) {
            return self.toolBreakpointLocations(allocator, tool_args);
        } else if (std.mem.eql(u8, tool_name, "cog_debug_cancel")) {
            return self.toolCancel(allocator, tool_args);
        } else if (std.mem.eql(u8, tool_name, "cog_debug_terminate_threads")) {
            return self.toolTerminateThreads(allocator, tool_args);
        } else if (std.mem.eql(u8, tool_name, "cog_debug_restart")) {
            return self.toolRestart(allocator, tool_args);
        } else if (std.mem.eql(u8, tool_name, "cog_debug_sessions")) {
            return self.toolSessions(allocator);
        } else if (std.mem.eql(u8, tool_name, "cog_debug_goto_targets")) {
            return self.toolGotoTargets(allocator, tool_args);
        } else if (std.mem.eql(u8, tool_name, "cog_debug_find_symbol")) {
            return self.toolFindSymbol(allocator, tool_args);
        } else if (std.mem.eql(u8, tool_name, "cog_debug_write_register")) {
            return self.toolWriteRegister(allocator, tool_args);
        } else if (std.mem.eql(u8, tool_name, "cog_debug_variable_location")) {
            return self.toolVariableLocation(allocator, tool_args);
        } else if (std.mem.eql(u8, tool_name, "cog_debug_poll_events")) {
            return self.toolPollEvents(allocator, tool_args);
        } else if (std.mem.eql(u8, tool_name, "cog_debug_load_core")) {
            return self.toolLoadCore(allocator, tool_args);
        } else if (std.mem.eql(u8, tool_name, "cog_debug_dap_request")) {
            return self.toolDapRequest(allocator, tool_args);
        } else {
            return .{ .err = .{ .code = METHOD_NOT_FOUND, .message = "Unknown tool" } };
        }
    }

    // ── Helpers ────────────────────────────────────────────────────────

    const RUNNING_ERROR = "Session is running. Use debug_poll_events to check status or debug_stop to cancel.";

    /// Return an error result if the session is currently executing (has a pending async run).
    fn requireStopped(session: *session_mod.Session) ?ToolResult {
        if (session.pending_run != null or session.status == .running) {
            return .{ .err = .{ .code = INTERNAL_ERROR, .message = RUNNING_ERROR } };
        }
        return null;
    }

    // ── Tool Implementations ────────────────────────────────────────────

    fn toolLaunch(self: *DebugServer, allocator: std.mem.Allocator, args: ?json.Value) !ToolResult {
        serverLog("[toolLaunch] Entered toolLaunch", .{});
        const a = args orelse return .{ .err = .{ .code = INVALID_PARAMS, .message = "Missing arguments" } };
        if (a != .object) return .{ .err = .{ .code = INVALID_PARAMS, .message = "Arguments must be object" } };

        serverLog("[toolLaunch] Parsing launch config...", .{});
        const config = types.LaunchConfig.parseFromJson(allocator, a) catch {
            serverLog("[toolLaunch] Failed to parse launch config", .{});
            return .{ .err = .{ .code = INVALID_PARAMS, .message = "Invalid launch config: program is required" } };
        };
        defer config.deinit(allocator);
        serverLog("[toolLaunch] Config parsed: program={s}", .{config.program});

        const client_pid: ?std.posix.pid_t = if (a.object.get("client_pid")) |v|
            (if (v == .integer) @as(std.posix.pid_t, @intCast(v.integer)) else null)
        else
            null;

        // Determine driver type from language hint or file extension
        const use_dap = blk: {
            if (config.language) |lang| {
                if (std.mem.eql(u8, lang, "python") or
                    std.mem.eql(u8, lang, "javascript") or
                    std.mem.eql(u8, lang, "java")) break :blk true;
            }
            // Check file extension
            const ext = std.fs.path.extension(config.program);
            if (std.mem.eql(u8, ext, ".py") or
                std.mem.eql(u8, ext, ".js") or
                std.mem.eql(u8, ext, ".java")) break :blk true;
            break :blk false;
        };

        if (use_dap) {
            serverLog("[toolLaunch] Using DAP transport, creating proxy...", .{});
            const dap_proxy = @import("dap/proxy.zig");
            var proxy = try allocator.create(dap_proxy.DapProxy);
            proxy.* = dap_proxy.DapProxy.init(allocator);
            errdefer {
                proxy.deinit();
                allocator.destroy(proxy);
            }

            serverLog("[toolLaunch] Calling driver.launch()...", .{});
            var driver = proxy.activeDriver();
            driver.launch(allocator, config) catch |err| {
                serverLog("[toolLaunch] driver.launch() FAILED: {s}", .{@errorName(err)});
                const msg = errorMessage(err);
                self.dashboard.onError("cog_debug_launch", msg);
                return .{ .err = .{ .code = errorToCode(err), .message = msg } };
            };
            serverLog("[toolLaunch] driver.launch() succeeded", .{});

            const session_id = try self.session_manager.createSession(driver, client_pid, .terminate);
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
                const msg = errorMessage(err);
                self.dashboard.onError("cog_debug_launch", msg);
                return .{ .err = .{ .code = errorToCode(err), .message = msg } };
            };

            const session_id = try self.session_manager.createSession(driver, client_pid, .terminate);
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
                self.dashboard.onError("cog_debug_breakpoint", @errorName(err));
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
                self.dashboard.onError("cog_debug_breakpoint", @errorName(err));
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

            return .{ .ok_static = "{\"removed\":true}" };
        } else if (std.mem.eql(u8, action_str, "list")) {
            const bps = session.driver.listBreakpoints(allocator) catch |err| {
                self.dashboard.onError("cog_debug_breakpoint", @errorName(err));
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
                self.dashboard.onError("cog_debug_breakpoint", @errorName(err));
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
                self.dashboard.onError("cog_debug_breakpoint", @errorName(err));
                return .{ .err = .{ .code = errorToCode(err), .message = @errorName(err) } };
            };

            return .{ .ok_static = "{\"exception_breakpoints_set\":true}" };
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
                self.dashboard.onError("cog_debug_run", @errorName(err));
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

        // Pause and restart are non-blocking — keep synchronous
        if (action == .pause or action == .restart) {
            session.status = .running;
            const state = session.driver.runEx(allocator, action, run_options) catch |err| {
                self.dashboard.onError("cog_debug_run", @errorName(err));
                return .{ .err = .{ .code = errorToCode(err), .message = @errorName(err) } };
            };

            session.status = if (state.exit_code != null) .terminated else .stopped;
            self.dashboard.onRun(session_id_val.string, action_val.string, state);
            self.emitStopEvent(session_id_val.string, action_val.string, state);

            var aw: Writer.Allocating = .init(allocator);
            defer aw.deinit();
            var jw: Stringify = .{ .writer = &aw.writer };
            try state.jsonStringify(&jw);
            const result = try aw.toOwnedSlice();
            return .{ .ok = result };
        }

        // Async execution control: continue, step_into, step_over, step_out,
        // reverse_continue, step_back — spawn background thread, return immediately.
        if (session.pending_run != null) {
            return .{ .err = .{ .code = INTERNAL_ERROR, .message = "Session is already running. Use debug_poll_events to check status or debug_stop to cancel." } };
        }

        session.status = .running;
        self.emitRunEvent(session_id_val.string, action_val.string);

        // Dupe session_id and action_name so they outlive the parsed JSON request.
        const owned_session_id = self.allocator.dupe(u8, session_id_val.string) catch
            return .{ .err = .{ .code = INTERNAL_ERROR, .message = "Failed to allocate session_id" } };
        const owned_action_name = self.allocator.dupe(u8, action_val.string) catch {
            self.allocator.free(owned_session_id);
            return .{ .err = .{ .code = INTERNAL_ERROR, .message = "Failed to allocate action_name" } };
        };

        session.pending_run = .{
            .thread = std.Thread.spawn(.{}, runBackground, .{ session, self.allocator, action, run_options }) catch |err| {
                session.status = .stopped;
                self.allocator.free(owned_session_id);
                self.allocator.free(owned_action_name);
                session.pending_run = null;
                self.dashboard.onError("cog_debug_run", @errorName(err));
                return .{ .err = .{ .code = INTERNAL_ERROR, .message = "Failed to spawn run thread" } };
            },
            .session_id = owned_session_id,
            .action_name = owned_action_name,
            .allocator = self.allocator,
        };

        var aw: Writer.Allocating = .init(allocator);
        defer aw.deinit();
        var jw: Stringify = .{ .writer = &aw.writer };
        try jw.beginObject();
        try jw.objectField("status");
        try jw.write("running");
        try jw.objectField("session_id");
        try jw.write(session_id_val.string);
        try jw.endObject();
        const result = try aw.toOwnedSlice();
        return .{ .ok = result };
    }

    /// Background thread function for async execution control.
    /// Calls driver.runEx() which blocks until the debuggee stops.
    /// Writes result to session.pending_run using release/acquire ordering.
    fn runBackground(session: *session_mod.Session, alloc: std.mem.Allocator, action: types.RunAction, opts: types.RunOptions) void {
        const state = session.driver.runEx(alloc, action, opts) catch |err| {
            if (session.pending_run) |*pr| {
                pr.error_msg = @errorName(err);
                pr.result.store(2, .release);
            }
            return;
        };
        if (session.pending_run) |*pr| {
            pr.stop_state = state;
            pr.result.store(1, .release);
        }
    }

    fn toolInspect(self: *DebugServer, allocator: std.mem.Allocator, args: ?json.Value) !ToolResult {
        const a = args orelse return .{ .err = .{ .code = INVALID_PARAMS, .message = "Missing arguments" } };
        if (a != .object) return .{ .err = .{ .code = INVALID_PARAMS, .message = "Arguments must be object" } };

        const session_id_val = a.object.get("session_id") orelse return .{ .err = .{ .code = INVALID_PARAMS, .message = "Missing session_id" } };
        if (session_id_val != .string) return .{ .err = .{ .code = INVALID_PARAMS, .message = "session_id must be string" } };

        const session = self.session_manager.getSession(session_id_val.string) orelse
            return .{ .err = .{ .code = INVALID_PARAMS, .message = "Unknown session" } };

        if (requireStopped(session)) |err_result| return err_result;

        const request = types.InspectRequest{
            .expression = if (a.object.get("expression")) |v| (if (v == .string) v.string else null) else null,
            .variable_ref = if (a.object.get("variable_ref")) |v| (if (v == .integer) @as(u32, @intCast(v.integer)) else null) else null,
            .frame_id = if (a.object.get("frame_id")) |v| (if (v == .integer) @as(u32, @intCast(v.integer)) else null) else null,
            .scope = if (a.object.get("scope")) |v| (if (v == .string) v.string else null) else null,
            .context = if (a.object.get("context")) |v| (if (v == .string) types.EvaluateContext.parse(v.string) else null) else null,
        };

        const result_val = session.driver.inspect(allocator, request) catch |err| {
            self.dashboard.onError("cog_debug_inspect", @errorName(err));
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
            result_val.type,
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
            if (session.pending_run != null) {
                // Background thread is blocking on waitpid/read.
                // Kill the process directly via SIGKILL — this is safe from any
                // thread (unlike ptrace) and unblocks the background thread.
                // Do NOT call driver.stop() which would race on waitpid.
                if (session.driver.getPid()) |pid| {
                    posix.kill(pid, posix.SIG.KILL) catch {};
                }
                // The background thread will detect the kill and set result to
                // completed/error. destroySession joins the thread.
            } else if (terminate_only) {
                // Terminate the debuggee and clean up session
                session.driver.terminate(allocator) catch {
                    // Fall back to full stop if terminate not supported
                    session.driver.stop(allocator) catch {};
                };
                // Fall through to destroy session below
            } else if (detach) {
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

        return .{ .ok_static = "{\"stopped\":true}" };
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
            self.dashboard.onError("cog_debug_threads", @errorName(err));
            return .{ .err = .{ .code = errorToCode(err), .message = @errorName(err) } };
        };
        self.dashboard.onThreads(session_id_val.string, thread_list.len);
        {
            var abuf: [64]u8 = undefined;
            const asum = std.fmt.bufPrint(&abuf, "{d} thread(s)", .{thread_list.len}) catch "threads listed";
            self.emitActivityEvent(session_id_val.string, "cog_debug_threads", asum);
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

        if (requireStopped(session)) |err_result| return err_result;

        const thread_id: u32 = if (a.object.get("thread_id")) |v| (if (v == .integer) @intCast(v.integer) else 1) else 1;
        const start_frame: u32 = if (a.object.get("start_frame")) |v| (if (v == .integer) @intCast(v.integer) else 0) else 0;
        const levels: u32 = if (a.object.get("levels")) |v| (if (v == .integer) @intCast(v.integer) else 20) else 20;

        const frames = session.driver.stackTrace(allocator, thread_id, start_frame, levels) catch |err| {
            self.dashboard.onError("cog_debug_stacktrace", @errorName(err));
            return .{ .err = .{ .code = errorToCode(err), .message = @errorName(err) } };
        };
        self.dashboard.onStackTrace(session_id_val.string, frames.len);
        {
            var abuf: [64]u8 = undefined;
            const asum = std.fmt.bufPrint(&abuf, "{d} frame(s)", .{frames.len}) catch "stack trace";
            self.emitActivityEvent(session_id_val.string, "cog_debug_stacktrace", asum);
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

        if (requireStopped(session)) |err_result| return err_result;

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
                self.dashboard.onError("cog_debug_memory", @errorName(err));
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
                self.dashboard.onError("cog_debug_memory", @errorName(err));
                return .{ .err = .{ .code = errorToCode(err), .message = @errorName(err) } };
            };
            self.dashboard.onMemory(session_id_val.string, "write", addr_val.string);

            return .{ .ok_static = "{\"written\":true}" };
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

        if (requireStopped(session)) |err_result| return err_result;

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
            break :blk if (reg_infos.len > 0) reg_infos[0].value else return .{ .err = .{ .code = INVALID_PARAMS, .message = "Missing address and unable to read PC" } };
        };

        const count: u32 = if (a.object.get("instruction_count")) |v| (if (v == .integer) @intCast(v.integer) else 10) else 10;

        const instruction_offset: ?i64 = if (a.object.get("instruction_offset")) |v| (if (v == .integer) v.integer else null) else null;
        const resolve_symbols: ?bool = if (a.object.get("resolve_symbols")) |v| (if (v == .bool) v.bool else null) else null;

        const instructions = session.driver.disassembleEx(allocator, address, count, instruction_offset, resolve_symbols) catch |err| {
            self.dashboard.onError("cog_debug_disassemble", @errorName(err));
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

        const client_pid: ?std.posix.pid_t = if (a.object.get("client_pid")) |v|
            (if (v == .integer) @as(std.posix.pid_t, @intCast(v.integer)) else null)
        else
            null;

        // Determine driver type from language hint
        const use_dap = if (a.object.get("language")) |lang_val| blk: {
            if (lang_val == .string) {
                const lang = lang_val.string;
                if (std.mem.eql(u8, lang, "python") or
                    std.mem.eql(u8, lang, "javascript") or
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
                self.dashboard.onError("cog_debug_attach", @errorName(err));
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
                self.dashboard.onError("cog_debug_attach", @errorName(err));
                return .{ .err = .{ .code = errorToCode(err), .message = @errorName(err) } };
            };
            driver_type_name = "native";
        }

        const session_id = try self.session_manager.createSession(driver, client_pid, .detach);
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

        if (requireStopped(session)) |err_result| return err_result;

        const var_val = a.object.get("variable") orelse return .{ .err = .{ .code = INVALID_PARAMS, .message = "Missing variable" } };
        if (var_val != .string) return .{ .err = .{ .code = INVALID_PARAMS, .message = "variable must be string" } };

        const value_val = a.object.get("value") orelse return .{ .err = .{ .code = INVALID_PARAMS, .message = "Missing value" } };
        if (value_val != .string) return .{ .err = .{ .code = INVALID_PARAMS, .message = "value must be string" } };

        const frame_id: u32 = if (a.object.get("frame_id")) |v| (if (v == .integer) @intCast(v.integer) else 0) else 0;

        const result_val = session.driver.setVariable(allocator, var_val.string, value_val.string, frame_id) catch |err| {
            self.dashboard.onError("cog_debug_set_variable", @errorName(err));
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

        if (requireStopped(session)) |err_result| return err_result;

        const frame_id: u32 = if (a.object.get("frame_id")) |v| (if (v == .integer) @intCast(v.integer) else 0) else 0;

        const scope_list = session.driver.scopes(allocator, frame_id) catch |err| {
            self.dashboard.onError("cog_debug_scopes", @errorName(err));
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
            self.dashboard.onError("cog_debug_watchpoint", @errorName(err));
            return .{ .err = .{ .code = errorToCode(err), .message = @errorName(err) } };
        };

        const data_id = info.data_id orelse {
            return .{ .err = .{ .code = INTERNAL_ERROR, .message = "Variable cannot be watched" } };
        };

        // Then set the data breakpoint
        const bp = session.driver.setDataBreakpoint(allocator, data_id, access_type) catch |err| {
            self.dashboard.onError("cog_debug_watchpoint", @errorName(err));
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
            self.dashboard.onError("cog_debug_completions", @errorName(err));
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
            self.dashboard.onError("cog_debug_modules", @errorName(err));
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
            self.dashboard.onError("cog_debug_loaded_sources", @errorName(err));
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
            self.dashboard.onError("cog_debug_source", @errorName(err));
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

        if (requireStopped(session)) |err_result| return err_result;

        const expr_val = a.object.get("expression") orelse return .{ .err = .{ .code = INVALID_PARAMS, .message = "Missing expression" } };
        if (expr_val != .string) return .{ .err = .{ .code = INVALID_PARAMS, .message = "expression must be string" } };

        const value_val = a.object.get("value") orelse return .{ .err = .{ .code = INVALID_PARAMS, .message = "Missing value" } };
        if (value_val != .string) return .{ .err = .{ .code = INVALID_PARAMS, .message = "value must be string" } };

        const frame_id: u32 = if (a.object.get("frame_id")) |v| (if (v == .integer) @intCast(v.integer) else 0) else 0;

        const result_val = session.driver.setExpression(allocator, expr_val.string, value_val.string, frame_id) catch |err| {
            self.dashboard.onError("cog_debug_set_expression", @errorName(err));
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

        if (requireStopped(session)) |err_result| return err_result;

        const frame_id_val = a.object.get("frame_id") orelse return .{ .err = .{ .code = INVALID_PARAMS, .message = "Missing frame_id" } };
        if (frame_id_val != .integer) return .{ .err = .{ .code = INVALID_PARAMS, .message = "frame_id must be integer" } };

        session.driver.restartFrame(allocator, @intCast(frame_id_val.integer)) catch |err| {
            self.dashboard.onError("cog_debug_restart_frame", @errorName(err));
            return .{ .err = .{ .code = errorToCode(err), .message = @errorName(err) } };
        };
        self.dashboard.onRestartFrame(session_id_val.string, @intCast(frame_id_val.integer));

        return .{ .ok_static = "{\"restarted\":true}" };
    }

    // ── Phase 7 Tool Implementations ────────────────────────────────

    fn toolExceptionInfo(self: *DebugServer, allocator: std.mem.Allocator, args: ?json.Value) !ToolResult {
        const a = args orelse return .{ .err = .{ .code = INVALID_PARAMS, .message = "Missing arguments" } };
        if (a != .object) return .{ .err = .{ .code = INVALID_PARAMS, .message = "Arguments must be object" } };

        const session_id_val = a.object.get("session_id") orelse return .{ .err = .{ .code = INVALID_PARAMS, .message = "Missing session_id" } };
        if (session_id_val != .string) return .{ .err = .{ .code = INVALID_PARAMS, .message = "session_id must be string" } };

        const session = self.session_manager.getSession(session_id_val.string) orelse
            return .{ .err = .{ .code = INVALID_PARAMS, .message = "Unknown session" } };

        if (requireStopped(session)) |err_result| return err_result;

        const thread_id: u32 = if (a.object.get("thread_id")) |v| (if (v == .integer) @intCast(v.integer) else 1) else 1;

        const info = session.driver.exceptionInfo(allocator, thread_id) catch |err| {
            self.dashboard.onError("cog_debug_exception_info", @errorName(err));
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

        if (requireStopped(session)) |err_result| return err_result;

        const thread_id: u32 = if (a.object.get("thread_id")) |v| (if (v == .integer) @intCast(v.integer) else 1) else 1;

        const regs = session.driver.readRegisters(allocator, thread_id) catch |err| {
            self.dashboard.onError("cog_debug_registers", @errorName(err));
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
            self.dashboard.onError("cog_debug_instruction_breakpoint", @errorName(err));
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

        if (requireStopped(session)) |err_result| return err_result;

        const frame_id_val = a.object.get("frame_id") orelse return .{ .err = .{ .code = INVALID_PARAMS, .message = "Missing frame_id" } };
        if (frame_id_val != .integer) return .{ .err = .{ .code = INVALID_PARAMS, .message = "frame_id must be integer" } };

        const targets = session.driver.stepInTargets(allocator, @intCast(frame_id_val.integer)) catch |err| {
            self.dashboard.onError("cog_debug_step_in_targets", @errorName(err));
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
            self.dashboard.onError("cog_debug_breakpoint_locations", @errorName(err));
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
            self.dashboard.onError("cog_debug_cancel", @errorName(err));
            return .{ .err = .{ .code = errorToCode(err), .message = @errorName(err) } };
        };
        self.dashboard.onCancel(session_id_val.string);

        return .{ .ok_static = "{\"cancelled\":true}" };
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
            self.dashboard.onError("cog_debug_terminate_threads", @errorName(err));
            return .{ .err = .{ .code = errorToCode(err), .message = @errorName(err) } };
        };
        self.dashboard.onTerminateThreads(session_id_val.string, id_list.items.len);

        return .{ .ok_static = "{\"terminated\":true}" };
    }

    fn toolRestart(self: *DebugServer, allocator: std.mem.Allocator, args: ?json.Value) !ToolResult {
        const a = args orelse return .{ .err = .{ .code = INVALID_PARAMS, .message = "Missing arguments" } };
        if (a != .object) return .{ .err = .{ .code = INVALID_PARAMS, .message = "Arguments must be object" } };

        const session_id_val = a.object.get("session_id") orelse return .{ .err = .{ .code = INVALID_PARAMS, .message = "Missing session_id" } };
        if (session_id_val != .string) return .{ .err = .{ .code = INVALID_PARAMS, .message = "session_id must be string" } };

        const session = self.session_manager.getSession(session_id_val.string) orelse
            return .{ .err = .{ .code = INVALID_PARAMS, .message = "Unknown session" } };

        session.driver.restart(allocator) catch |err| {
            self.dashboard.onError("cog_debug_restart", @errorName(err));
            return .{ .err = .{ .code = errorToCode(err), .message = @errorName(err) } };
        };
        self.dashboard.onRestart(session_id_val.string);

        return .{ .ok_static = "{\"restarted\":true}" };
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
            self.dashboard.onError("cog_debug_goto_targets", @errorName(err));
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
            self.dashboard.onError("cog_debug_find_symbol", @errorName(err));
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

        if (requireStopped(session)) |err_result| return err_result;

        const name_val = a.object.get("name") orelse return .{ .err = .{ .code = INVALID_PARAMS, .message = "Missing name" } };
        if (name_val != .string) return .{ .err = .{ .code = INVALID_PARAMS, .message = "name must be string" } };

        const value_val = a.object.get("value") orelse return .{ .err = .{ .code = INVALID_PARAMS, .message = "Missing value" } };
        if (value_val != .integer) return .{ .err = .{ .code = INVALID_PARAMS, .message = "value must be integer" } };

        const thread_id: u32 = if (a.object.get("thread_id")) |v| (if (v == .integer) @intCast(v.integer) else 0) else 0;

        session.driver.writeRegisters(allocator, thread_id, name_val.string, @intCast(value_val.integer)) catch |err| {
            self.dashboard.onError("cog_debug_write_register", @errorName(err));
            return .{ .err = .{ .code = errorToCode(err), .message = @errorName(err) } };
        };

        return .{ .ok_static = "{\"written\":true}" };
    }

    fn toolVariableLocation(self: *DebugServer, allocator: std.mem.Allocator, args: ?json.Value) !ToolResult {
        const a = args orelse return .{ .err = .{ .code = INVALID_PARAMS, .message = "Missing arguments" } };
        if (a != .object) return .{ .err = .{ .code = INVALID_PARAMS, .message = "Arguments must be object" } };

        const session_id_val = a.object.get("session_id") orelse return .{ .err = .{ .code = INVALID_PARAMS, .message = "Missing session_id" } };
        if (session_id_val != .string) return .{ .err = .{ .code = INVALID_PARAMS, .message = "session_id must be string" } };

        const session = self.session_manager.getSession(session_id_val.string) orelse
            return .{ .err = .{ .code = INVALID_PARAMS, .message = "Unknown session" } };

        if (requireStopped(session)) |err_result| return err_result;

        const name_val = a.object.get("name") orelse return .{ .err = .{ .code = INVALID_PARAMS, .message = "Missing name" } };
        if (name_val != .string) return .{ .err = .{ .code = INVALID_PARAMS, .message = "name must be string" } };

        const frame_id: u32 = if (a.object.get("frame_id")) |v| (if (v == .integer) @intCast(v.integer) else 0) else 0;

        const loc = session.driver.variableLocation(allocator, name_val.string, frame_id) catch |err| {
            self.dashboard.onError("cog_debug_variable_location", @errorName(err));
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

            const session = entry.value_ptr;

            // Check for completed async run
            if (session.pending_run) |*pr| {
                const status = pr.result.load(.acquire);
                if (status == 1) {
                    // Completed successfully — emit stopped event
                    if (pr.stop_state) |state| {
                        session.status = if (state.exit_code != null) .terminated else .stopped;
                        self.dashboard.onRun(entry.key_ptr.*, pr.action_name, state);
                        self.emitStopEvent(entry.key_ptr.*, pr.action_name, state);

                        try jw.beginObject();
                        try jw.objectField("session_id");
                        try jw.write(entry.key_ptr.*);
                        try jw.objectField("method");
                        try jw.write("stopped");
                        try jw.objectField("params");
                        try state.jsonStringify(&jw);
                        try jw.endObject();
                    }
                    pr.thread.join();
                    pr.deinit();
                    session.pending_run = null;
                } else if (status == 2) {
                    // Error — emit error event
                    const err_msg = pr.error_msg orelse "unknown error";
                    session.status = .stopped;

                    try jw.beginObject();
                    try jw.objectField("session_id");
                    try jw.write(entry.key_ptr.*);
                    try jw.objectField("method");
                    try jw.write("error");
                    try jw.objectField("params");
                    try jw.beginObject();
                    try jw.objectField("error");
                    try jw.write(err_msg);
                    try jw.endObject();
                    try jw.endObject();

                    pr.thread.join();
                    pr.deinit();
                    session.pending_run = null;
                }
                // status == 0: still running, skip
            }

            // Drain driver notifications (DAP events, etc.)
            const notifications = session.driver.drainNotifications(allocator);
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
                // Write raw pre-serialized JSON params using the raw streaming API
                // to keep the Stringify state machine consistent.
                try jw.beginWriteRaw();
                try jw.writer.writeAll(n.params_json);
                jw.endWriteRaw();
                try jw.endObject();
            }
        }

        try jw.endArray();
        try jw.endObject();

        const result = try aw.toOwnedSlice();
        return .{ .ok = result };
    }

    fn toolLoadCore(self: *DebugServer, allocator: std.mem.Allocator, args: ?json.Value) !ToolResult {
        const a = args orelse return .{ .err = .{ .code = INVALID_PARAMS, .message = "Missing arguments" } };
        if (a != .object) return .{ .err = .{ .code = INVALID_PARAMS, .message = "Arguments must be object" } };

        const core_path_val = a.object.get("core_path") orelse return .{ .err = .{ .code = INVALID_PARAMS, .message = "Missing core_path" } };
        if (core_path_val != .string) return .{ .err = .{ .code = INVALID_PARAMS, .message = "core_path must be string" } };

        const executable_val = a.object.get("executable");
        const executable: ?[]const u8 = if (executable_val) |v| (if (v == .string) v.string else null) else null;
        const client_pid: ?std.posix.pid_t = if (a.object.get("client_pid")) |v|
            (if (v == .integer) @as(std.posix.pid_t, @intCast(v.integer)) else null)
        else
            null;

        // Core dumps always use the native engine
        const dwarf_engine = @import("dwarf/engine.zig");
        var engine = try allocator.create(dwarf_engine.DwarfEngine);
        engine.* = dwarf_engine.DwarfEngine.init(allocator);
        errdefer {
            engine.deinit();
            allocator.destroy(engine);
        }

        var driver = engine.activeDriver();
        driver.loadCore(allocator, core_path_val.string, executable) catch |err| {
            self.dashboard.onError("cog_debug_load_core", @errorName(err));
            return .{ .err = .{ .code = errorToCode(err), .message = @errorName(err) } };
        };

        const session_id = try self.session_manager.createSession(driver, client_pid, .terminate);
        if (self.session_manager.getSession(session_id)) |s| {
            s.status = .stopped;
        }
        self.dashboard.onLaunch(session_id, "core_dump", "native");
        self.emitLaunchEvent(session_id, "core_dump", "native");

        var aw: Writer.Allocating = .init(allocator);
        defer aw.deinit();
        var s: Stringify = .{ .writer = &aw.writer };
        try s.beginObject();
        try s.objectField("session_id");
        try s.write(session_id);
        try s.objectField("status");
        try s.write("stopped");
        try s.objectField("mode");
        try s.write("core_dump");
        try s.endObject();
        const result = try aw.toOwnedSlice();
        return .{ .ok = result };
    }

    fn toolDapRequest(self: *DebugServer, allocator: std.mem.Allocator, args: ?json.Value) !ToolResult {
        const a = args orelse return .{ .err = .{ .code = INVALID_PARAMS, .message = "Missing arguments" } };
        if (a != .object) return .{ .err = .{ .code = INVALID_PARAMS, .message = "Arguments must be object" } };

        const session_id_val = a.object.get("session_id") orelse return .{ .err = .{ .code = INVALID_PARAMS, .message = "Missing session_id" } };
        if (session_id_val != .string) return .{ .err = .{ .code = INVALID_PARAMS, .message = "session_id must be string" } };

        const command_val = a.object.get("command") orelse return .{ .err = .{ .code = INVALID_PARAMS, .message = "Missing command" } };
        if (command_val != .string) return .{ .err = .{ .code = INVALID_PARAMS, .message = "command must be string" } };

        const session = self.session_manager.getSession(session_id_val.string) orelse
            return .{ .err = .{ .code = INVALID_PARAMS, .message = "Unknown session" } };

        // Serialize arguments to JSON string if present
        const arguments_str: ?[]const u8 = if (a.object.get("arguments")) |args_val| blk: {
            if (args_val == .object or args_val == .array) {
                var aw: Writer.Allocating = .init(allocator);
                defer aw.deinit();
                var jw: Stringify = .{ .writer = &aw.writer };
                args_val.jsonStringify(&jw) catch break :blk null;
                break :blk aw.toOwnedSlice() catch null;
            }
            break :blk null;
        } else null;
        defer if (arguments_str) |s| allocator.free(s);

        const response = session.driver.rawRequest(allocator, command_val.string, arguments_str) catch |err| {
            self.dashboard.onError("cog_debug_dap_request", @errorName(err));
            return .{ .err = .{ .code = errorToCode(err), .message = @errorName(err) } };
        };

        return .{ .ok = response };
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
            // Apply connection backoff: only retry every 5 seconds
            if (!self.dashboard_available) {
                const now = std.time.timestamp();
                if (now - self.last_dashboard_attempt < 5) return;
            }
            self.connectDashboardSocket();
            if (self.dashboard_socket != null) {
                self.dashboard_available = true;
            } else {
                self.dashboard_available = false;
                self.last_dashboard_attempt = std.time.timestamp();
                return;
            }
        }

        if (self.sendDashboardData(event_json)) return;

        // Send failed — connection is stale. Reconnect and retry once.
        if (self.dashboard_socket) |sock| {
            posix.close(sock);
            self.dashboard_socket = null;
        }
        self.connectDashboardSocket();
        if (self.dashboard_socket != null) {
            self.dashboard_available = true;
            _ = self.sendDashboardData(event_json);
        } else {
            self.dashboard_available = false;
            self.last_dashboard_attempt = std.time.timestamp();
        }
    }

    /// Send event data + newline on the dashboard socket in a single writev. Returns true on success.
    fn sendDashboardData(self: *DebugServer, event_json: []const u8) bool {
        const sock = self.dashboard_socket orelse return false;
        const iovecs = [_]posix.iovec_const{
            .{ .base = event_json.ptr, .len = event_json.len },
            .{ .base = "\n", .len = 1 },
        };
        _ = posix.writev(sock, &iovecs) catch {
            posix.close(sock);
            self.dashboard_socket = null;
            return false;
        };
        return true;
    }

    /// Emit a launch event to the dashboard TUI.
    fn emitLaunchEvent(self: *DebugServer, session_id: []const u8, program: []const u8, driver_type: []const u8) void {
        if (self.dashboard_socket == null and !self.dashboard_available) return;
        var buf: [512]u8 = undefined;
        const event = std.fmt.bufPrint(&buf,
            \\{{"type":"launch","session_id":"{s}","program":"{s}","driver":"{s}"}}
        , .{ truncateStr(session_id, 32), truncateStr(program, 200), truncateStr(driver_type, 16) }) catch return;
        self.pushDashboardEvent(event);
    }

    /// Emit a breakpoint event to the dashboard TUI.
    fn emitBreakpointEvent(self: *DebugServer, session_id: []const u8, action: []const u8, bp: types.BreakpointInfo) void {
        if (self.dashboard_socket == null and !self.dashboard_available) return;
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
        if (self.dashboard_socket == null and !self.dashboard_available) return;
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
                jw.write(v.type) catch return;
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
        if (self.dashboard_socket == null and !self.dashboard_available) return;
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
        if (self.dashboard_socket == null and !self.dashboard_available) return;
        var buf: [128]u8 = undefined;
        const event = std.fmt.bufPrint(&buf,
            \\{{"type":"session_end","session_id":"{s}"}}
        , .{truncateStr(session_id, 32)}) catch return;
        self.pushDashboardEvent(event);
    }

    /// Emit an error event to the dashboard TUI.
    fn emitErrorEvent(self: *DebugServer, session_id: []const u8, method: []const u8, message: []const u8) void {
        if (self.dashboard_socket == null and !self.dashboard_available) return;
        var buf: [512]u8 = undefined;
        const event = std.fmt.bufPrint(&buf,
            \\{{"type":"error","session_id":"{s}","method":"{s}","message":"{s}"}}
        , .{ truncateStr(session_id, 32), truncateStr(method, 32), truncateStr(message, 200) }) catch return;
        self.pushDashboardEvent(event);
    }

    /// Emit a generic activity event to the dashboard TUI.
    fn emitActivityEvent(self: *DebugServer, session_id: []const u8, tool: []const u8, summary: []const u8) void {
        if (self.dashboard_socket == null and !self.dashboard_available) return;
        var buf: [512]u8 = undefined;
        const event = std.fmt.bufPrint(&buf,
            \\{{"type":"activity","session_id":"{s}","tool":"{s}","summary":"{s}"}}
        , .{ truncateStr(session_id, 32), truncateStr(tool, 32), truncateStr(summary, 200) }) catch return;
        self.pushDashboardEvent(event);
    }

    /// Emit a run event (execution resumed, before stop).
    fn emitRunEvent(self: *DebugServer, session_id: []const u8, action: []const u8) void {
        if (self.dashboard_socket == null and !self.dashboard_available) return;
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

test "tool_definitions has 36 entries" {
    try std.testing.expectEqual(@as(usize, 36), tool_definitions.len);
}

test "callTool returns error for unknown tool" {
    const allocator = std.testing.allocator;
    var srv = DebugServer.init(allocator);
    defer srv.deinit();

    const result = try srv.callTool(allocator, "nonexistent_tool", null);
    switch (result) {
        .err => |e| try std.testing.expectEqual(METHOD_NOT_FOUND, e.code),
        .ok, .ok_static => unreachable,
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

    const result = try srv.callTool(allocator, "cog_debug_stop", args_parsed.value);
    switch (result) {
        .ok => |raw| {
            defer allocator.free(raw);
            try std.testing.expect(std.mem.indexOf(u8, raw, "\"stopped\":true") != null);
        },
        .ok_static => |raw| {
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
