const std = @import("std");
const json = std.json;
const Stringify = json.Stringify;
const Writer = std.io.Writer;
const posix = std.posix;
const MAX_DASHBOARD_SESSIONS = 16;
const MAX_DASHBOARD_BREAKPOINTS = 32;
const MAX_DASHBOARD_EVENT_BYTES = 8192;
const DASHBOARD_SOURCE_ID_BYTES = 16;
const DASHBOARD_SOURCE_ID_LEN = DASHBOARD_SOURCE_ID_BYTES * 2;
const types = @import("types.zig");
const session_mod = @import("session.zig");
const driver_mod = @import("driver.zig");
const dashboard_mod = @import("dashboard.zig");
const extensions = @import("../extensions.zig");
const debug_log = @import("../debug_log.zig");
const paths = @import("../paths.zig");
const ipc_identity = @import("ipc_identity.zig");

// Debug logging to file
var server_log_file: ?std.fs.File = null;

fn serverLog(comptime fmt: []const u8, args: anytype) void {
    if (server_log_file == null) {
        const path = paths.getDapLogPath(std.heap.page_allocator) catch |err| {
            debug_log.log("serverLog: failed to resolve diagnostic log path: {s}", .{@errorName(err)});
            return;
        };
        defer std.heap.page_allocator.free(path);
        debug_log.log("serverLog: opening diagnostic log {s}", .{path});
        server_log_file = std.fs.createFileAbsolute(path, .{ .truncate = false, .mode = 0o600 }) catch |err| blk: {
            debug_log.log("serverLog: failed to open {s}: {s}", .{ path, @errorName(err) });
            break :blk null;
        };
        if (server_log_file) |f| {
            if (@import("builtin").os.tag != .windows) f.chmod(0o600) catch |err| {
                debug_log.log("serverLog: failed to restrict {s}: {s}", .{ path, @errorName(err) });
            };
            f.seekFromEnd(0) catch |err| debug_log.log("serverLog: failed to seek {s}: {s}", .{ path, @errorName(err) });
        }
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
    if (err == error.DownloadFailed) return "Failed to download vscode-js-debug DAP server";
    if (err == error.ExtractFailed) return "Failed to extract vscode-js-debug archive";
    if (err == error.InstallFailed) return "vscode-js-debug installation failed";
    if (err == error.PortParseFailed) return "Failed to parse DAP server listening port";
    if (err == error.ConnectionFailed) return "Failed to connect to DAP server";
    if (err == error.JavaNotFound) return "java not found on PATH";
    if (err == error.JavacNotFound) return "javac not found on PATH";
    if (err == error.JdiCompileFailed) return "Failed to compile JDI debug adapter";
    if (err == error.UnsupportedLanguage) return "Unsupported language for debugging";
    if (err == error.NoDebugInfo) return "Binary has no debug info. Make sure you are launching the built executable (not the compiler/interpreter). For compiled languages, build first then pass the output binary path.";
    return @errorName(err);
}

// ── Tool Definitions ────────────────────────────────────────────────────

pub const tool_definitions = [_]ToolDef{
    // ── Core tier (7 tools) ─────────────────────────────────────────────
    .{
        .name = "debug_launch",
        .description = "Start a new debug session by launching a program. Returns a session_id used by all other debug tools. The program is paused before execution begins if stop_on_entry is true, otherwise it runs until a breakpoint is hit or it exits.",
        .input_schema = debug_launch_schema,
        .tier = .core,
    },
    .{
        .name = "debug_breakpoint",
        .description = "Manage breakpoints in a debug session. Use action 'set' for line breakpoints (requires file + line), 'set_function' for function-name breakpoints (requires function), 'set_exception' for exception breakpoints (use filters to specify exception types, e.g. [\"raised\"] or [\"uncaught\"]), 'remove' to delete a breakpoint by id, 'list' to show all active breakpoints.",
        .input_schema = debug_breakpoint_schema,
        .tier = .core,
    },
    .{
        .name = "debug_run",
        .description = "Control program execution. Actions: 'continue' resumes until next breakpoint or exit, 'step_over' executes current line and stops at next line, 'step_into' enters function calls, 'step_out' runs until current function returns, 'pause' suspends a running program, 'restart' re-runs from the beginning, 'goto' jumps to a specific file:line (use with file and line params). 'step_over_inspect' steps repeatedly while evaluating expressions from the 'expressions' array, returning all results in one call (use 'max_steps' to limit, default 5).",
        .input_schema = debug_run_schema,
        .tier = .core,
    },
    .{
        .name = "debug_inspect",
        .description = "Evaluate expressions or inspect variables. To evaluate an expression, pass 'expression' (e.g. \"x + y\", \"len(items)\"). To list variables in a scope, pass 'scope' (locals, globals, or arguments). To expand a compound variable (object, array, struct), pass the 'variable_ref' number from a previous inspect result. Use 'frame_id' to inspect a specific stack frame (default: topmost).",
        .input_schema = debug_inspect_schema,
        .tier = .core,
    },
    .{
        .name = "debug_stop",
        .description = "End a debug session and terminate the debuggee process. Always call this when done debugging to clean up resources.",
        .input_schema = debug_stop_schema,
        .tier = .core,
    },
    .{
        .name = "debug_stacktrace",
        .description = "Get the call stack for a thread, showing the chain of function calls that led to the current execution point. Each frame includes a frame_id, function name, file path, and line number. Use frame_id with inspect to examine variables in a specific frame.",
        .input_schema = debug_stacktrace_schema,
        .tier = .core,
    },
    .{
        .name = "debug_sessions",
        .description = "List all active debug sessions with their IDs and status. Use to find session_id values or check if a previous session is still alive.",
        .input_schema = debug_sessions_schema,
        .tier = .core,
    },
    // ── Extended tier (6 tools) ─────────────────────────────────────────
    .{
        .name = "debug_threads",
        .description = "List all threads in the debuggee process with their IDs and names. Use thread IDs with stacktrace to inspect specific threads.",
        .input_schema = debug_threads_schema,
        .tier = .extended,
    },
    .{
        .name = "debug_attach",
        .description = "Attach the debugger to an already-running process by its PID. Returns a session_id for use with other debug tools. The process is paused upon attach.",
        .input_schema = debug_attach_schema,
        .tier = .extended,
    },
    .{
        .name = "debug_set_variable",
        .description = "Modify a variable's value at runtime in the current scope. Use for testing hypotheses during debugging (e.g. \"what if this value were 0?\"). The change is temporary and only affects the running process.",
        .input_schema = debug_set_variable_schema,
        .tier = .extended,
    },
    .{
        .name = "debug_watchpoint",
        .description = "Set a data breakpoint that pauses execution when a variable is read, written, or both. Useful for finding where a value gets unexpectedly changed.",
        .input_schema = debug_watchpoint_schema,
        .tier = .extended,
    },
    .{
        .name = "debug_exception_info",
        .description = "Get details about the exception that caused the program to stop, including the exception type, message, and full stack trace. Call this when the program stops at an exception breakpoint.",
        .input_schema = debug_exception_info_schema,
        .tier = .extended,
    },
    .{
        .name = "debug_restart",
        .description = "Restart the entire debug session from the beginning, re-launching the program with the same arguments and breakpoints.",
        .input_schema = debug_restart_schema,
        .tier = .extended,
    },
    // ── Specialist tier (23 tools) ──────────────────────────────────────
    .{
        .name = "debug_memory",
        .description = "Read or write raw process memory at a hex address. Use action 'read' with address and size to read bytes, 'write' with address and hex data string to write bytes.",
        .input_schema = debug_memory_schema,
    },
    .{
        .name = "debug_disassemble",
        .description = "Disassemble machine instructions at a memory address. Returns assembly instructions with addresses and optional symbol names. Useful for low-level debugging of compiled code.",
        .input_schema = debug_disassemble_schema,
    },
    .{
        .name = "debug_scopes",
        .description = "List the variable scopes (locals, globals, arguments) available in a stack frame. Returns scope names and variable reference IDs. Pass a variable_ref to inspect to expand and view the variables within each scope.",
        .input_schema = debug_scopes_schema,
    },
    .{
        .name = "debug_capabilities",
        .description = "Query what features the debug driver supports (e.g. variable mutation, conditional breakpoints, restart frame, goto). Call this after launch to know what operations are available for the target language/runtime.",
        .input_schema = debug_capabilities_schema,
    },
    .{
        .name = "debug_completions",
        .description = "Get auto-completions for partial variable names or expressions in the debug REPL context. Useful for discovering available variables and methods.",
        .input_schema = debug_completions_schema,
    },
    .{
        .name = "debug_modules",
        .description = "List all loaded shared libraries and modules in the debuggee process, including their paths and address ranges.",
        .input_schema = debug_modules_schema,
    },
    .{
        .name = "debug_loaded_sources",
        .description = "List all source files the debugger knows about in the current session. Useful for finding the correct file paths for setting breakpoints.",
        .input_schema = debug_loaded_sources_schema,
    },
    .{
        .name = "debug_source",
        .description = "Retrieve source code for a file identified by its source_reference ID (from stacktrace or loadedSources results). Use when the source isn't available on disk.",
        .input_schema = debug_source_schema,
    },
    .{
        .name = "debug_set_expression",
        .description = "Evaluate an expression and assign its result to a new value. More powerful than setVariable — supports complex left-hand expressions like struct fields or array elements.",
        .input_schema = debug_set_expression_schema,
    },
    .{
        .name = "debug_restart_frame",
        .description = "Re-execute a function from the beginning of a specific stack frame. Useful for re-running a function with modified variables without restarting the whole program.",
        .input_schema = debug_restart_frame_schema,
    },
    .{
        .name = "debug_registers",
        .description = "Read CPU register values (native engine only, not available for DAP sessions). Returns register names and their current values.",
        .input_schema = debug_registers_schema,
    },
    .{
        .name = "debug_instruction_breakpoint",
        .description = "Set a breakpoint at a specific machine instruction address. For low-level debugging when source-level breakpoints aren't sufficient.",
        .input_schema = debug_instruction_breakpoint_schema,
    },
    .{
        .name = "debug_step_in_targets",
        .description = "When a line has multiple function calls, list which functions can be stepped into individually. Use the returned target ID with a step_into action to enter a specific call.",
        .input_schema = debug_step_in_targets_schema,
    },
    .{
        .name = "debug_breakpoint_locations",
        .description = "Find the valid positions where breakpoints can be set within a line range. Use this when a breakpoint on a specific line doesn't work — the actual valid location may differ.",
        .input_schema = debug_breakpoint_locations_schema,
    },
    .{
        .name = "debug_cancel",
        .description = "Cancel a long-running debug request that hasn't completed yet.",
        .input_schema = debug_cancel_schema,
    },
    .{
        .name = "debug_terminate_threads",
        .description = "Terminate specific threads by their IDs while keeping the debug session alive.",
        .input_schema = debug_terminate_threads_schema,
    },
    .{
        .name = "debug_goto_targets",
        .description = "Find valid goto target locations for a source line. Returns target IDs that can be used with the 'goto' action in run to jump execution to that point.",
        .input_schema = debug_goto_targets_schema,
    },
    .{
        .name = "debug_find_symbol",
        .description = "Search for a symbol definition by name in the debuggee's symbol table (native engine only, not available for DAP sessions). Returns the symbol's address and type.",
        .input_schema = debug_find_symbol_schema,
    },
    .{
        .name = "debug_write_register",
        .description = "Write a value to a CPU register (native engine only, not available for DAP sessions). Use with caution — incorrect values can crash the debuggee.",
        .input_schema = debug_write_register_schema,
    },
    .{
        .name = "debug_variable_location",
        .description = "Get the physical storage location of a variable — whether it's in a register, on the stack, or in memory (native engine only, not available for DAP sessions).",
        .input_schema = debug_variable_location_schema,
    },
    .{
        .name = "debug_poll_events",
        .description = "Check for pending debug events like breakpoint hits, program exits, or thread stops. Results include per-session bounded queue, drop, retention, and breakpoint counters.",
        .input_schema = debug_poll_events_schema,
    },
    .{
        .name = "debug_load_core",
        .description = "Load a core dump file for post-mortem debugging. Allows inspecting the program state at the time of a crash without re-running the program.",
        .input_schema = debug_load_core_schema,
    },
    .{
        .name = "debug_dap_request",
        .description = "Send a raw DAP (Debug Adapter Protocol) request directly to the debug adapter. Escape hatch for DAP features not covered by other tools. Requires knowledge of the DAP specification.",
        .input_schema = debug_dap_request_schema,
    },
};

pub const ToolTier = enum {
    /// Core tools: launch, breakpoint, run, inspect, stacktrace, stop, sessions.
    /// These cover 95% of debugging workflows.
    core,
    /// Extended tools: threads, watchpoint, set_variable, exception_info, attach, restart.
    /// Useful for multi-threaded debugging and hypothesis testing.
    extended,
    /// Specialist tools: memory, disassemble, registers, etc.
    /// Low-level or rarely needed by AI agents.
    specialist,

    /// Returns true if self is at or below the given tier threshold.
    pub fn isWithin(self: ToolTier, threshold: ToolTier) bool {
        return @intFromEnum(self) <= @intFromEnum(threshold);
    }
};

const ToolDef = struct {
    name: []const u8,
    description: []const u8,
    input_schema: []const u8,
    tier: ToolTier = .specialist,
};

pub const debug_launch_schema =
    \\{"type":"object","properties":{"program":{"type":"string","description":"Path to the script or executable to debug (e.g. /path/to/script.py, /path/to/app.js)"},"module":{"type":"string","description":"Module to run via the language runtime's module system (e.g. \"pytest\" for python -m pytest). Use instead of program when invoking a module. Pass module arguments in args."},"args":{"type":"array","items":{"type":"string"},"description":"Program arguments (e.g. [\"tests/test_foo.py::test_bar\", \"-xvs\"])"},"env":{"type":"object","description":"Environment variables"},"cwd":{"type":"string","description":"Working directory"},"language":{"type":"string","description":"Language hint (e.g. python, javascript). Auto-detected from file extension or interpreter name."},"stop_on_entry":{"type":"boolean","default":false}},"additionalProperties":false}
;

pub const debug_breakpoint_schema =
    \\{"type":"object","properties":{"session_id":{"type":"string","description":"Debug session ID from launch or attach"},"action":{"type":"string","enum":["set","remove","list","set_function","set_exception"],"description":"set: line breakpoint (file+line), set_function: break on function entry (function), set_exception: break on exceptions (filters), remove: delete by id, list: show all"},"file":{"type":"string","description":"Source file path (for set action)"},"line":{"type":"integer","description":"Line number (for set action)"},"condition":{"type":"string","description":"Expression that must be true for breakpoint to trigger"},"hit_condition":{"type":"string","description":"Break after N hits (e.g. \"> 5\", \"== 3\")"},"log_message":{"type":"string","description":"Log this message instead of stopping (logpoint). Expressions in {} are interpolated."},"function":{"type":"string","description":"Function name (for set_function action)"},"filters":{"type":"array","items":{"type":"string"},"description":"Exception filter IDs for set_exception (e.g. [\"raised\"], [\"uncaught\"])"},"id":{"type":"integer","description":"Breakpoint ID to remove (for remove action)"}},"required":["session_id","action"],"additionalProperties":false}
;

pub const debug_run_schema =
    \\{"type":"object","properties":{"session_id":{"type":"string","description":"Debug session ID"},"action":{"type":"string","enum":["continue","step_into","step_over","step_out","restart","pause","goto","reverse_continue","step_back","step_over_inspect"],"description":"continue: run until next breakpoint, step_over: next line, step_into: enter function, step_out: finish current function, pause: suspend running program, goto: jump to file:line, restart: re-run from start, step_over_inspect: step over repeatedly while evaluating expressions"},"file":{"type":"string","description":"Target file for goto action"},"line":{"type":"integer","description":"Target line for goto action"},"granularity":{"type":"string","enum":["statement","line","instruction"],"description":"Stepping granularity (default: statement)"},"timeout_ms":{"type":"integer","description":"Block until debuggee stops or timeout (ms). Default 30000. Set to 0 for async (returns immediately with status:running).","default":30000},"expressions":{"type":"array","items":{"type":"string"},"description":"Expressions to evaluate at each step (for step_over_inspect action)"},"max_steps":{"type":"integer","description":"Maximum number of steps before stopping (for step_over_inspect, default 5)","default":5}},"required":["session_id","action"],"additionalProperties":false}
;

pub const debug_inspect_schema =
    \\{"type":"object","properties":{"session_id":{"type":"string","description":"Debug session ID"},"expression":{"type":"string","description":"Expression to evaluate (e.g. \"x + 1\", \"obj.field\", \"len(arr)\")"},"variable_ref":{"type":"integer","description":"Variable reference ID from a previous inspect or scopes result — use to expand compound variables (objects, arrays, structs)"},"frame_id":{"type":"integer","description":"Stack frame to evaluate in (0 = topmost frame, from stacktrace results)"},"scope":{"type":"string","enum":["locals","globals","arguments"],"description":"List all variables in this scope instead of evaluating an expression"},"context":{"type":"string","enum":["watch","repl","hover","clipboard"],"description":"Evaluation context hint for the debug adapter (default: repl)"}},"required":["session_id"],"additionalProperties":false}
;

pub const debug_stop_schema =
    \\{"type":"object","properties":{"session_id":{"type":"string","description":"Debug session ID"},"terminate_only":{"type":"boolean","default":false,"description":"If true, terminate the debuggee but keep the debug adapter alive (DAP only)"},"detach":{"type":"boolean","default":false,"description":"Detach from debuggee without terminating"}},"required":["session_id"],"additionalProperties":false}
;

pub const debug_threads_schema =
    \\{"type":"object","properties":{"session_id":{"type":"string","description":"Debug session ID"}},"required":["session_id"],"additionalProperties":false}
;

pub const debug_stacktrace_schema =
    \\{"type":"object","properties":{"session_id":{"type":"string","description":"Debug session ID"},"thread_id":{"type":"integer","default":1,"description":"Thread to get stack from (default: main thread)"},"start_frame":{"type":"integer","default":0,"description":"Skip this many frames from the top"},"levels":{"type":"integer","default":20,"description":"Maximum number of frames to return"}},"required":["session_id"],"additionalProperties":false}
;

pub const debug_memory_schema =
    \\{"type":"object","properties":{"session_id":{"type":"string"},"action":{"type":"string","enum":["read","write"]},"address":{"type":"string","description":"Hex address e.g. 0x1000"},"size":{"type":"integer","default":64},"data":{"type":"string","description":"Hex string for write"},"offset":{"type":"integer","description":"Byte offset from the base address"}},"required":["session_id","action","address"],"additionalProperties":false}
;

pub const debug_disassemble_schema =
    \\{"type":"object","properties":{"session_id":{"type":"string"},"address":{"type":"string","description":"Hex address e.g. 0x1000"},"instruction_count":{"type":"integer","default":10},"instruction_offset":{"type":"integer","description":"Offset in instructions from the address"},"resolve_symbols":{"type":"boolean","description":"Whether to resolve symbol names","default":true}},"required":["session_id","address"],"additionalProperties":false}
;

pub const debug_attach_schema =
    \\{"type":"object","properties":{"pid":{"type":"integer","description":"Process ID to attach to"},"language":{"type":"string","description":"Language hint"}},"required":["pid"],"additionalProperties":false}
;

pub const debug_set_variable_schema =
    \\{"type":"object","properties":{"session_id":{"type":"string","description":"Debug session ID"},"variable":{"type":"string","description":"Variable name to modify"},"value":{"type":"string","description":"New value as a string (e.g. \"42\", \"true\", \"\\\"hello\\\"\")"},"frame_id":{"type":"integer","default":0,"description":"Stack frame context (0 = topmost)"}},"required":["session_id","variable","value"],"additionalProperties":false}
;

pub const debug_scopes_schema =
    \\{"type":"object","properties":{"session_id":{"type":"string","description":"Debug session ID"},"frame_id":{"type":"integer","default":0,"description":"Stack frame to get scopes for (0 = topmost, from stacktrace results)"}},"required":["session_id"],"additionalProperties":false}
;

pub const debug_watchpoint_schema =
    \\{"type":"object","properties":{"session_id":{"type":"string","description":"Debug session ID"},"variable":{"type":"string","description":"Variable name to watch"},"access_type":{"type":"string","enum":["read","write","readWrite"],"default":"write","description":"Break on read, write, or both (default: write)"},"frame_id":{"type":"integer","description":"Stack frame context for variable resolution"}},"required":["session_id","variable"],"additionalProperties":false}
;

pub const debug_capabilities_schema =
    \\{"type":"object","properties":{"session_id":{"type":"string","description":"Debug session ID"}},"required":["session_id"],"additionalProperties":false}
;

pub const debug_completions_schema =
    \\{"type":"object","properties":{"session_id":{"type":"string","description":"Debug session ID"},"text":{"type":"string","description":"Partial text to complete"},"column":{"type":"integer","default":0,"description":"Cursor column position in the text"},"frame_id":{"type":"integer","description":"Stack frame context for completions"}},"required":["session_id","text"],"additionalProperties":false}
;

pub const debug_modules_schema =
    \\{"type":"object","properties":{"session_id":{"type":"string","description":"Debug session ID"}},"required":["session_id"],"additionalProperties":false}
;

pub const debug_loaded_sources_schema =
    \\{"type":"object","properties":{"session_id":{"type":"string","description":"Debug session ID"}},"required":["session_id"],"additionalProperties":false}
;

pub const debug_source_schema =
    \\{"type":"object","properties":{"session_id":{"type":"string","description":"Debug session ID"},"source_reference":{"type":"integer","description":"Source reference ID from stacktrace or loadedSources results"}},"required":["session_id","source_reference"],"additionalProperties":false}
;

pub const debug_set_expression_schema =
    \\{"type":"object","properties":{"session_id":{"type":"string","description":"Debug session ID"},"expression":{"type":"string","description":"Left-hand expression to assign to (e.g. \"obj.field\", \"arr[0]\")"},"value":{"type":"string","description":"New value to assign"},"frame_id":{"type":"integer","default":0,"description":"Stack frame context"}},"required":["session_id","expression","value"],"additionalProperties":false}
;

pub const debug_restart_frame_schema =
    \\{"type":"object","properties":{"session_id":{"type":"string","description":"Debug session ID"},"frame_id":{"type":"integer","description":"Stack frame ID to restart from (from stacktrace results)"}},"required":["session_id","frame_id"],"additionalProperties":false}
;

pub const debug_exception_info_schema =
    \\{"type":"object","properties":{"session_id":{"type":"string","description":"Debug session ID"},"thread_id":{"type":"integer","default":1,"description":"Thread that hit the exception"}},"required":["session_id"],"additionalProperties":false}
;

pub const debug_registers_schema =
    \\{"type":"object","properties":{"session_id":{"type":"string","description":"Debug session ID"},"thread_id":{"type":"integer","default":1,"description":"Thread to read registers from"}},"required":["session_id"],"additionalProperties":false}
;

pub const debug_instruction_breakpoint_schema =
    \\{"type":"object","properties":{"session_id":{"type":"string"},"instruction_reference":{"type":"string","description":"Memory reference to an instruction"},"offset":{"type":"integer","description":"Optional offset from the instruction reference"},"condition":{"type":"string","description":"Optional breakpoint condition expression"},"hit_condition":{"type":"string","description":"Optional hit count condition"}},"required":["session_id","instruction_reference"],"additionalProperties":false}
;

pub const debug_step_in_targets_schema =
    \\{"type":"object","properties":{"session_id":{"type":"string"},"frame_id":{"type":"integer","description":"Stack frame ID to get step-in targets for"}},"required":["session_id","frame_id"],"additionalProperties":false}
;

pub const debug_breakpoint_locations_schema =
    \\{"type":"object","properties":{"session_id":{"type":"string"},"source":{"type":"string","description":"Source file path"},"line":{"type":"integer","description":"Start line to query"},"end_line":{"type":"integer","description":"Optional end line for range query"}},"required":["session_id","source","line"],"additionalProperties":false}
;

pub const debug_cancel_schema =
    \\{"type":"object","properties":{"session_id":{"type":"string","description":"Debug session ID"},"request_id":{"type":"integer","description":"ID of the request to cancel"},"progress_id":{"type":"string","description":"ID of the progress to cancel"}},"required":["session_id"],"additionalProperties":false}
;

pub const debug_terminate_threads_schema =
    \\{"type":"object","properties":{"session_id":{"type":"string","description":"Debug session ID"},"thread_ids":{"type":"array","items":{"type":"integer"},"description":"Thread IDs to terminate (from threads results)"}},"required":["session_id","thread_ids"],"additionalProperties":false}
;

pub const debug_restart_schema =
    \\{"type":"object","properties":{"session_id":{"type":"string","description":"Debug session ID"}},"required":["session_id"],"additionalProperties":false}
;

pub const debug_sessions_schema =
    \\{"type":"object","properties":{},"additionalProperties":false}
;

pub const debug_goto_targets_schema =
    \\{"type":"object","properties":{"session_id":{"type":"string","description":"Debug session ID"},"file":{"type":"string","description":"Source file path"},"line":{"type":"integer","description":"Target line number"}},"required":["session_id","file","line"],"additionalProperties":false}
;

pub const debug_find_symbol_schema =
    \\{"type":"object","properties":{"session_id":{"type":"string","description":"Debug session ID"},"name":{"type":"string","description":"Symbol name to search for"}},"required":["session_id","name"],"additionalProperties":false}
;

pub const debug_write_register_schema =
    \\{"type":"object","properties":{"session_id":{"type":"string","description":"Debug session ID"},"name":{"type":"string","description":"Register name (e.g. rax, rsp, pc)"},"value":{"type":"integer","description":"Value to write"},"thread_id":{"type":"integer","default":0,"description":"Thread to write register in"}},"required":["session_id","name","value"],"additionalProperties":false}
;

pub const debug_variable_location_schema =
    \\{"type":"object","properties":{"session_id":{"type":"string","description":"Debug session ID"},"name":{"type":"string","description":"Variable name to locate"},"frame_id":{"type":"integer","default":0,"description":"Stack frame context"}},"required":["session_id","name"],"additionalProperties":false}
;

pub const debug_poll_events_schema =
    \\{"type":"object","properties":{"session_id":{"type":"string","description":"Poll specific session, or omit for all sessions"}},"additionalProperties":false}
;

pub const debug_load_core_schema =
    \\{"type":"object","properties":{"core_path":{"type":"string","description":"Path to core dump file"},"executable":{"type":"string","description":"Path to the executable that generated the core dump"}},"required":["core_path"],"additionalProperties":false}
;

pub const debug_dap_request_schema =
    \\{"type":"object","properties":{"session_id":{"type":"string"},"command":{"type":"string","description":"DAP command name (e.g. evaluate, threads)"},"arguments":{"type":"object","description":"DAP request arguments"}},"required":["session_id","command"],"additionalProperties":false}
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
    /// Millisecond timestamp of the last failed dashboard connection attempt.
    last_dashboard_attempt_ms: i64 = 0,
    /// Consecutive failed dashboard connection attempts, used for bounded backoff.
    dashboard_failure_count: u8 = 0,
    /// Unique producer-generation identity included in every dashboard event.
    dashboard_source_id: [DASHBOARD_SOURCE_ID_LEN]u8,
    /// Stable state snapshot replayed when the dashboard reconnects.
    dashboard_sessions: [MAX_DASHBOARD_SESSIONS]DashboardSessionState = [_]DashboardSessionState{.{}} ** MAX_DASHBOARD_SESSIONS,
    dashboard_session_count: usize = 0,
    /// Serializes tool dispatch so the session map and session state are safely
    /// accessed from handler threads. Released during blocking runEx() calls.
    mutex: std.Thread.Mutex = .{},
    /// Serializes dashboard connection state and complete NDJSON frame writes.
    dashboard_mutex: std.Thread.Mutex = .{},

    pub fn init(allocator: std.mem.Allocator) DebugServer {
        var source_bytes: [DASHBOARD_SOURCE_ID_BYTES]u8 = undefined;
        std.crypto.random.bytes(&source_bytes);
        return .{
            .session_manager = SessionManager.init(allocator),
            .allocator = allocator,
            .dashboard = dashboard_mod.Dashboard.init(),
            .dashboard_source_id = std.fmt.bytesToHex(source_bytes, .lower),
        };
    }

    pub fn deinit(self: *DebugServer) void {
        self.session_manager.deinit();
        self.dashboard_mutex.lock();
        defer self.dashboard_mutex.unlock();
        if (self.dashboard_socket) |sock| {
            debug_log.log("DebugServer.deinit: closing dashboard socket fd={d}", .{sock});
            posix.close(sock);
            self.dashboard_socket = null;
        }
    }

    /// Dispatch a tool call and return the raw result.
    /// Used by the daemon socket transport.
    pub fn callTool(self: *DebugServer, allocator: std.mem.Allocator, tool_name: []const u8, tool_args: ?json.Value) !ToolResult {
        debug_log.log("DebugServer.callTool: acquiring mutex for {s}", .{tool_name});
        self.mutex.lock();
        defer {
            debug_log.log("DebugServer.callTool: {s} completed", .{tool_name});
            self.mutex.unlock();
            debug_log.log("DebugServer.callTool: mutex released for {s}", .{tool_name});
        }
        debug_log.log("DebugServer.callTool: mutex acquired for {s}", .{tool_name});
        serverLog("[DebugServer.callTool] Dispatching tool: {s}", .{tool_name});
        if (std.mem.eql(u8, tool_name, "debug_launch")) {
            serverLog("[DebugServer.callTool] -> toolLaunch", .{});
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
        } else if (std.mem.eql(u8, tool_name, "debug_load_core")) {
            return self.toolLoadCore(allocator, tool_args);
        } else if (std.mem.eql(u8, tool_name, "debug_dap_request")) {
            return self.toolDapRequest(allocator, tool_args);
        } else {
            debug_log.log("DebugServer.callTool: unknown tool {s}", .{tool_name});
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

    const TextOutput = struct {
        buf: std.ArrayListUnmanaged(u8) = .empty,
        allocator: std.mem.Allocator,

        fn init(allocator: std.mem.Allocator) TextOutput {
            return .{ .allocator = allocator };
        }

        fn deinit(self: *TextOutput) void {
            self.buf.deinit(self.allocator);
        }

        fn append(self: *TextOutput, text: []const u8) !void {
            try self.buf.appendSlice(self.allocator, text);
        }

        fn print(self: *TextOutput, comptime fmt: []const u8, args: anytype) !void {
            try std.fmt.format(self.buf.writer(self.allocator), fmt, args);
        }

        fn toOwnedSlice(self: *TextOutput) ![]const u8 {
            return self.buf.toOwnedSlice(self.allocator);
        }
    };

    fn okText(allocator: std.mem.Allocator, comptime fmt: []const u8, args: anytype) !ToolResult {
        return .{ .ok = try std.fmt.allocPrint(allocator, fmt, args) };
    }

    fn appendBreakpointText(out: *TextOutput, bp: *const types.BreakpointInfo) !void {
        try out.print("- breakpoint #{d}: {s}:{d} ({s})", .{ bp.id, bp.file, bp.actual_line orelse bp.line, if (bp.verified) "verified" else "unverified" });
        if (bp.condition) |condition| {
            try out.print(" condition={s}", .{condition});
        }
        if (bp.hit_condition) |hit_condition| {
            try out.print(" hit={s}", .{hit_condition});
        }
        if (bp.log_message) |log_message| {
            try out.print(" log={s}", .{log_message});
        }
    }

    fn formatStopStateText(allocator: std.mem.Allocator, state: *const types.StopState) ![]const u8 {
        var out = TextOutput.init(allocator);
        errdefer out.deinit();

        try out.print("stop reason: {s}\n", .{@tagName(state.stop_reason)});
        if (state.location) |loc| {
            try out.print("location: {s}:{d}", .{ loc.file, loc.line });
            if (loc.function.len > 0) {
                try out.print(" in {s}", .{loc.function});
            }
            try out.append("\n");
        }
        if (state.exit_code) |code| {
            try out.print("exit code: {d}\n", .{code});
        }
        if (state.hit_breakpoint_ids.len > 0) {
            try out.append("hit breakpoints:");
            for (state.hit_breakpoint_ids) |bp_id| {
                try out.print(" #{d}", .{bp_id});
            }
            try out.append("\n");
        }
        if (state.exception) |exc| {
            try out.print("exception: {s}", .{exc.type});
            if (exc.message.len > 0) {
                try out.print(" - {s}", .{exc.message});
            }
            try out.append("\n");
        }
        if (state.log_messages.len > 0) {
            try out.append("log messages:\n");
            for (state.log_messages) |msg| {
                try out.print("- {s}\n", .{msg});
            }
        }
        if (state.output.len > 0) {
            try out.append("output:\n");
            for (state.output) |entry| {
                try out.print("- [{s}] {s}\n", .{ entry.category, entry.text });
            }
        }
        if (state.stack_trace.len > 0) {
            try out.append("stack trace:\n");
            for (state.stack_trace, 0..) |frame, i| {
                try out.print("{d}. {s} at {s}:{d}\n", .{ i + 1, frame.name, frame.source, frame.line });
            }
        }
        if (state.locals.len > 0) {
            try out.append("locals:\n");
            for (state.locals) |local| {
                try out.print("- {s} = {s}", .{ local.name, local.value });
                if (local.type.len > 0) {
                    try out.print(" ({s})", .{local.type});
                }
                if (local.variables_reference > 0) {
                    try out.print(" [ref: {d}]", .{local.variables_reference});
                }
                try out.append("\n");
            }
        }

        return out.toOwnedSlice();
    }

    fn formatThreadsText(allocator: std.mem.Allocator, threads: []const types.ThreadInfo) ![]const u8 {
        var out = TextOutput.init(allocator);
        errdefer out.deinit();
        if (threads.len == 0) {
            try out.append("No threads.");
            return out.toOwnedSlice();
        }
        try out.print("threads ({d}):\n", .{threads.len});
        for (threads) |thread| {
            try out.print("- #{d}: {s}", .{ thread.id, thread.name });
            if (thread.is_stopped) try out.append(" [stopped]");
            try out.append("\n");
        }
        return out.toOwnedSlice();
    }

    fn formatStackTraceText(allocator: std.mem.Allocator, frames: []const types.StackFrame) ![]const u8 {
        var out = TextOutput.init(allocator);
        errdefer out.deinit();
        if (frames.len == 0) {
            try out.append("No stack frames.");
            return out.toOwnedSlice();
        }
        try out.print("stack trace ({d} frames):\n", .{frames.len});
        for (frames, 0..) |frame, i| {
            try out.print("{d}. {s} at {s}:{d}:{d} [frame_id={d}]\n", .{ i + 1, frame.name, frame.source, frame.line, frame.column, frame.id });
        }
        return out.toOwnedSlice();
    }

    fn formatScopesText(allocator: std.mem.Allocator, scopes: []const types.Scope) ![]const u8 {
        var out = TextOutput.init(allocator);
        errdefer out.deinit();
        if (scopes.len == 0) {
            try out.append("No scopes.");
            return out.toOwnedSlice();
        }
        try out.append("scopes:\n");
        for (scopes) |scope| {
            try out.print("- {s} [ref: {d}]", .{ scope.name, scope.variables_reference });
            if (scope.expensive) try out.append(" [expensive]");
            try out.append("\n");
        }
        return out.toOwnedSlice();
    }

    fn formatModulesText(allocator: std.mem.Allocator, modules: []const types.Module) ![]const u8 {
        var out = TextOutput.init(allocator);
        errdefer out.deinit();
        if (modules.len == 0) {
            try out.append("No modules.");
            return out.toOwnedSlice();
        }
        try out.print("modules ({d}):\n", .{modules.len});
        for (modules) |module| {
            try out.print("- {s}", .{module.name});
            if (module.path.len > 0) try out.print(" ({s})", .{module.path});
            if (module.symbol_status.len > 0) try out.print(" symbols={s}", .{module.symbol_status});
            if (module.is_optimized) try out.append(" optimized");
            try out.append("\n");
        }
        return out.toOwnedSlice();
    }

    fn formatLoadedSourcesText(allocator: std.mem.Allocator, sources: []const types.LoadedSource) ![]const u8 {
        var out = TextOutput.init(allocator);
        errdefer out.deinit();
        if (sources.len == 0) {
            try out.append("No loaded sources.");
            return out.toOwnedSlice();
        }
        try out.print("loaded sources ({d}):\n", .{sources.len});
        for (sources) |source| {
            try out.print("- {s}", .{source.name});
            if (source.path.len > 0) try out.print(" ({s})", .{source.path});
            if (source.source_reference > 0) try out.print(" [source_reference={d}]", .{source.source_reference});
            try out.append("\n");
        }
        return out.toOwnedSlice();
    }

    fn formatRegistersText(allocator: std.mem.Allocator, registers: []const types.RegisterInfo) ![]const u8 {
        var out = TextOutput.init(allocator);
        errdefer out.deinit();
        if (registers.len == 0) {
            try out.append("No registers.");
            return out.toOwnedSlice();
        }
        try out.append("registers:\n");
        for (registers) |reg| {
            try out.print("- {s} = 0x{x}\n", .{ reg.name, reg.value });
        }
        return out.toOwnedSlice();
    }

    fn formatMemoryReadText(allocator: std.mem.Allocator, address: []const u8, size: u64, data: []const u8) ![]const u8 {
        return std.fmt.allocPrint(allocator, "memory read {s} ({d} bytes)\n{s}", .{ address, size, data });
    }

    fn formatDisassemblyText(allocator: std.mem.Allocator, instructions: []const types.DisassembledInstruction) ![]const u8 {
        var out = TextOutput.init(allocator);
        errdefer out.deinit();
        if (instructions.len == 0) {
            try out.append("No instructions.");
            return out.toOwnedSlice();
        }
        try out.append("instructions:\n");
        for (instructions) |inst| {
            try out.print("- {s}: {s}", .{ inst.address, inst.instruction });
            if (inst.instruction_bytes.len > 0) try out.print(" [{s}]", .{inst.instruction_bytes});
            try out.append("\n");
        }
        return out.toOwnedSlice();
    }

    fn formatBreakpointLocationsText(allocator: std.mem.Allocator, locations: []const types.BreakpointLocation) ![]const u8 {
        var out = TextOutput.init(allocator);
        errdefer out.deinit();
        if (locations.len == 0) {
            try out.append("No valid breakpoint locations.");
            return out.toOwnedSlice();
        }
        try out.append("valid breakpoint locations:\n");
        for (locations) |loc| {
            try out.print("- line {d}", .{loc.line});
            if (loc.column) |column| try out.print(":{d}", .{column});
            if (loc.end_line) |end_line| {
                try out.print(" -> {d}", .{end_line});
                if (loc.end_column) |end_column| try out.print(":{d}", .{end_column});
            }
            try out.append("\n");
        }
        return out.toOwnedSlice();
    }

    fn formatStepInTargetsText(allocator: std.mem.Allocator, targets: []const types.StepInTarget) ![]const u8 {
        var out = TextOutput.init(allocator);
        errdefer out.deinit();
        if (targets.len == 0) {
            try out.append("No step-in targets.");
            return out.toOwnedSlice();
        }
        try out.append("step-in targets:\n");
        for (targets) |target| {
            try out.print("- #{d}: {s}", .{ target.id, target.label });
            if (target.line) |line| {
                try out.print(" at line {d}", .{line});
                if (target.column) |column| try out.print(":{d}", .{column});
            }
            try out.append("\n");
        }
        return out.toOwnedSlice();
    }

    fn formatGotoTargetsText(allocator: std.mem.Allocator, targets: []const types.GotoTarget) ![]const u8 {
        var out = TextOutput.init(allocator);
        errdefer out.deinit();
        if (targets.len == 0) {
            try out.append("No goto targets.");
            return out.toOwnedSlice();
        }
        try out.append("goto targets:\n");
        for (targets) |target| {
            try out.print("- #{d}: {s} at line {d}", .{ target.id, target.label, target.line });
            if (target.column) |column| try out.print(":{d}", .{column});
            try out.append("\n");
        }
        return out.toOwnedSlice();
    }

    fn formatSymbolsText(allocator: std.mem.Allocator, symbols: []const types.SymbolInfo) ![]const u8 {
        var out = TextOutput.init(allocator);
        errdefer out.deinit();
        if (symbols.len == 0) {
            try out.append("No symbols found.");
            return out.toOwnedSlice();
        }
        try out.append("symbols:\n");
        for (symbols) |symbol| {
            try out.print("- {s}", .{symbol.name});
            if (symbol.kind.len > 0) try out.print(" ({s})", .{symbol.kind});
            if (symbol.file.len > 0) {
                try out.print(" in {s}", .{symbol.file});
                if (symbol.line) |line| try out.print(":{d}", .{line});
            }
            if (symbol.container.len > 0) try out.print(" container={s}", .{symbol.container});
            try out.append("\n");
        }
        return out.toOwnedSlice();
    }

    fn formatVariableLocationText(allocator: std.mem.Allocator, loc: *const types.VariableLocationInfo) ![]const u8 {
        var out = TextOutput.init(allocator);
        errdefer out.deinit();
        try out.print("{s}: {s}", .{ loc.name, loc.location_type });
        if (loc.register.len > 0) try out.print(" register={s}", .{loc.register});
        if (loc.stack_offset) |stack_offset| try out.print(" stack_offset={d}", .{stack_offset});
        if (loc.address) |address| try out.print(" address=0x{x}", .{address});
        if (loc.pieces.len > 0) try out.print(" pieces={s}", .{loc.pieces});
        return out.toOwnedSlice();
    }

    fn formatExceptionInfoText(allocator: std.mem.Allocator, info: *const types.ExceptionInfo) ![]const u8 {
        var out = TextOutput.init(allocator);
        errdefer out.deinit();
        try out.print("exception: {s}\n", .{info.type});
        if (info.message.len > 0) try out.print("message: {s}\n", .{info.message});
        try out.print("break mode: {s}", .{info.break_mode});
        if (info.details) |details| {
            if (details.type_name.len > 0) try out.print("\ntype: {s}", .{details.type_name});
            if (details.message.len > 0) try out.print("\ndetails: {s}", .{details.message});
            if (details.stack_trace.len > 0) try out.print("\nstack:\n{s}", .{details.stack_trace});
        }
        return out.toOwnedSlice();
    }

    fn formatSessionListText(allocator: std.mem.Allocator, sessions: anytype) ![]const u8 {
        var out = TextOutput.init(allocator);
        errdefer out.deinit();
        if (sessions.len == 0) {
            try out.append("No active sessions.");
            return out.toOwnedSlice();
        }
        try out.append("active sessions:\n");
        for (sessions) |session| {
            try out.print("- {s}: {s} ({s})\n", .{ session.id, @tagName(session.status), @tagName(session.driver_type) });
        }
        return out.toOwnedSlice();
    }

    // ── Tool Implementations ────────────────────────────────────────────

    fn toolLaunch(self: *DebugServer, allocator: std.mem.Allocator, args: ?json.Value) !ToolResult {
        serverLog("[toolLaunch] Entered toolLaunch", .{});
        debug_log.log("toolLaunch: entered", .{});
        const a = args orelse return .{ .err = .{ .code = INVALID_PARAMS, .message = "Missing arguments" } };
        if (a != .object) return .{ .err = .{ .code = INVALID_PARAMS, .message = "Arguments must be object" } };

        serverLog("[toolLaunch] Parsing launch config...", .{});
        const config = types.LaunchConfig.parseFromJson(allocator, a) catch {
            serverLog("[toolLaunch] Failed to parse launch config", .{});
            return .{ .err = .{ .code = INVALID_PARAMS, .message = "Invalid launch config: program is required" } };
        };
        defer config.deinit(allocator);
        serverLog("[toolLaunch] Config parsed: program={s} module={s}", .{ config.program, config.module orelse "(none)" });
        debug_log.log("toolLaunch: program={s} language={s}", .{ config.program, config.language orelse "(auto)" });

        const client_pid: ?std.posix.pid_t = if (a.object.get("client_pid")) |v|
            (if (v == .integer) @as(std.posix.pid_t, @intCast(v.integer)) else null)
        else
            null;

        // Resolve extension to determine debug driver
        const resolved_ext = blk: {
            if (config.language) |lang| {
                if (extensions.resolveByLanguageHint(allocator, lang)) |ext| break :blk ext;
            }
            // "module" launch mode implies Python (debugpy)
            if (config.module != null) {
                if (extensions.resolveByLanguageHint(allocator, "python")) |e| break :blk e;
            }
            const ext = std.fs.path.extension(config.program);
            if (ext.len > 0) {
                if (extensions.resolveByExtension(allocator, ext)) |e| break :blk e;
            }
            // No extension or unknown extension — try resolving from the
            // program basename as an interpreter name (e.g. "python3" → python,
            // "node" → javascript).
            const basename = std.fs.path.basename(config.program);
            if (interpreterToLanguage(basename)) |lang| {
                if (extensions.resolveByLanguageHint(allocator, lang)) |e| break :blk e;
            }
            break :blk null;
        };
        defer if (resolved_ext) |re| extensions.freeExtension(allocator, &re);

        const debug_config = if (resolved_ext) |re| re.debug else null;
        const use_dap = if (debug_config) |dc| dc == .dap else false;

        debug_log.log("toolLaunch: extension resolved, use_dap={}", .{use_dap});

        if (use_dap) {
            serverLog("[toolLaunch] Using DAP transport, creating proxy...", .{});
            const dap_proxy = @import("dap/proxy.zig");
            var proxy = try allocator.create(dap_proxy.DapProxy);
            proxy.* = dap_proxy.DapProxy.init(allocator);
            // Pass the DAP config to the proxy
            if (debug_config) |dc| {
                proxy.debug_config = dc.dap;
            }
            errdefer {
                proxy.deinit();
                allocator.destroy(proxy);
            }

            serverLog("[toolLaunch] Calling driver.launch()...", .{});
            var driver = proxy.activeDriver();
            driver.launch(allocator, config) catch |err| {
                serverLog("[toolLaunch] driver.launch() FAILED: {s}", .{@errorName(err)});
                debug_log.log("toolLaunch: DAP driver launch failed: {s}", .{@errorName(err)});
                const msg = errorMessage(err);
                self.dashboard.onError("debug_launch", msg);
                return .{ .err = .{ .code = errorToCode(err), .message = msg } };
            };
            serverLog("[toolLaunch] driver.launch() succeeded", .{});
            debug_log.log("toolLaunch: DAP driver launch succeeded", .{});

            const session_id = try self.session_manager.createSession(driver, client_pid, .terminate);
            if (self.session_manager.getSession(session_id)) |s| {
                s.status = .stopped;
            }
            const display_name = if (config.program.len > 0) config.program else config.module orelse "unknown";
            debug_log.log("toolLaunch: session created id={s} driver=dap", .{session_id});
            self.dashboard.onLaunch(session_id, display_name, "dap");
            self.emitLaunchEvent(session_id, display_name, "dap");

            return okText(allocator, "Started debug session `{s}` for `{s}` using dap.", .{ session_id, display_name });
        } else {
            const dwarf_engine = @import("dwarf/engine.zig");
            var engine = try allocator.create(dwarf_engine.DwarfEngine);
            engine.* = dwarf_engine.DwarfEngine.init(allocator);
            errdefer {
                engine.deinit();
                allocator.destroy(engine);
            }

            debug_log.log("toolLaunch: using native/DWARF engine", .{});
            var driver = engine.activeDriver();
            driver.launch(allocator, config) catch |err| {
                debug_log.log("toolLaunch: DWARF driver launch failed: {s}", .{@errorName(err)});
                const msg = errorMessage(err);
                self.dashboard.onError("debug_launch", msg);
                return .{ .err = .{ .code = errorToCode(err), .message = msg } };
            };
            debug_log.log("toolLaunch: DWARF driver launch succeeded", .{});

            const session_id = try self.session_manager.createSession(driver, client_pid, .terminate);
            if (self.session_manager.getSession(session_id)) |ss| {
                ss.status = .stopped;
            }
            debug_log.log("toolLaunch: session created id={s} driver=native", .{session_id});
            self.dashboard.onLaunch(session_id, config.program, "native");
            self.emitLaunchEvent(session_id, config.program, "native");

            return okText(allocator, "Started debug session `{s}` for `{s}` using native.", .{ session_id, config.program });
        }
    }

    fn toolBreakpoint(self: *DebugServer, allocator: std.mem.Allocator, args: ?json.Value) !ToolResult {
        const a = args orelse return .{ .err = .{ .code = INVALID_PARAMS, .message = "Missing arguments" } };
        if (a != .object) return .{ .err = .{ .code = INVALID_PARAMS, .message = "Arguments must be object" } };

        const session_id_val = a.object.get("session_id") orelse return .{ .err = .{ .code = INVALID_PARAMS, .message = "Missing session_id" } };
        if (session_id_val != .string) return .{ .err = .{ .code = INVALID_PARAMS, .message = "session_id must be string" } };

        debug_log.log("toolBreakpoint: session_id={s}", .{session_id_val.string});

        const session = self.session_manager.getSession(session_id_val.string) orelse
            return .{ .err = .{ .code = INVALID_PARAMS, .message = "Unknown session" } };

        const action_val = a.object.get("action") orelse return .{ .err = .{ .code = INVALID_PARAMS, .message = "Missing action" } };
        if (action_val != .string) return .{ .err = .{ .code = INVALID_PARAMS, .message = "action must be string" } };
        const action_str = action_val.string;

        debug_log.log("toolBreakpoint: action={s}", .{action_str});

        if (std.mem.eql(u8, action_str, "set")) {
            const file_val = a.object.get("file") orelse return .{ .err = .{ .code = INVALID_PARAMS, .message = "Missing file for set" } };
            if (file_val != .string) return .{ .err = .{ .code = INVALID_PARAMS, .message = "file must be string" } };
            const line_val = a.object.get("line") orelse return .{ .err = .{ .code = INVALID_PARAMS, .message = "Missing line for set" } };
            if (line_val != .integer) return .{ .err = .{ .code = INVALID_PARAMS, .message = "line must be integer" } };

            const condition = if (a.object.get("condition")) |c| (if (c == .string) c.string else null) else null;
            const hit_condition = if (a.object.get("hit_condition")) |c| (if (c == .string) c.string else null) else null;
            const log_message = if (a.object.get("log_message")) |c| (if (c == .string) c.string else null) else null;

            debug_log.log("toolBreakpoint: set file={s} line={d}", .{ file_val.string, @as(i64, line_val.integer) });
            const bp = session.driver.setBreakpointEx(allocator, file_val.string, @intCast(line_val.integer), condition, hit_condition, log_message) catch |err| {
                debug_log.log("toolBreakpoint: set failed: {s}", .{@errorName(err)});
                self.dashboard.onError("debug_breakpoint", @errorName(err));
                if (err == error.NoAddressForLine) {
                    return .{ .err = .{ .code = errorToCode(err), .message = "No executable code at this line (function may be inlined/optimized). Try set_function with the function name, or a nearby line." } };
                }
                return .{ .err = .{ .code = errorToCode(err), .message = @errorName(err) } };
            };
            debug_log.log("toolBreakpoint: set bp#{d} verified={}", .{ bp.id, bp.verified });
            self.dashboard.onBreakpoint("set", bp);
            self.emitBreakpointEvent(session_id_val.string, "set", bp);

            var out = TextOutput.init(allocator);
            errdefer out.deinit();
            try out.append("Set breakpoint:\n");
            try appendBreakpointText(&out, &bp);
            return .{ .ok = try out.toOwnedSlice() };
        } else if (std.mem.eql(u8, action_str, "remove")) {
            const bp_id_val = a.object.get("id") orelse return .{ .err = .{ .code = INVALID_PARAMS, .message = "Missing id for remove" } };
            if (bp_id_val != .integer) return .{ .err = .{ .code = INVALID_PARAMS, .message = "id must be integer" } };

            session.driver.removeBreakpoint(allocator, @intCast(bp_id_val.integer)) catch |err| {
                debug_log.log("toolBreakpoint: remove bp#{d} failed: {s}", .{ @as(i64, bp_id_val.integer), @errorName(err) });
                self.dashboard.onError("debug_breakpoint", @errorName(err));
                return .{ .err = .{ .code = errorToCode(err), .message = @errorName(err) } };
            };
            debug_log.log("toolBreakpoint: removed bp#{d}", .{@as(i64, bp_id_val.integer)});
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

            return okText(allocator, "Removed breakpoint #{d}.", .{@as(u32, @intCast(bp_id_val.integer))});
        } else if (std.mem.eql(u8, action_str, "list")) {
            const bps = session.driver.listBreakpoints(allocator) catch |err| {
                debug_log.log("toolBreakpoint: list failed: {s}", .{@errorName(err)});
                self.dashboard.onError("debug_breakpoint", @errorName(err));
                return .{ .err = .{ .code = errorToCode(err), .message = @errorName(err) } };
            };
            debug_log.log("toolBreakpoint: listed {d} breakpoints", .{bps.len});
            self.dashboard.onBreakpoint("list", .{
                .id = 0,
                .verified = false,
                .file = "",
                .line = 0,
            });

            var out = TextOutput.init(allocator);
            errdefer out.deinit();
            if (bps.len == 0) {
                try out.append("No breakpoints set.");
            } else {
                try out.append("Breakpoints:\n");
                for (bps) |*bp| {
                    try appendBreakpointText(&out, bp);
                    try out.append("\n");
                }
            }
            return .{ .ok = try out.toOwnedSlice() };
        } else if (std.mem.eql(u8, action_str, "set_function")) {
            const func_val = a.object.get("function") orelse return .{ .err = .{ .code = INVALID_PARAMS, .message = "Missing function name" } };
            if (func_val != .string) return .{ .err = .{ .code = INVALID_PARAMS, .message = "function must be string" } };

            const condition = if (a.object.get("condition")) |c| (if (c == .string) c.string else null) else null;

            const bp = session.driver.setFunctionBreakpoint(allocator, func_val.string, condition) catch |err| {
                self.dashboard.onError("debug_breakpoint", @errorName(err));
                return .{ .err = .{ .code = errorToCode(err), .message = @errorName(err) } };
            };
            self.dashboard.onBreakpoint("set", bp);

            var out = TextOutput.init(allocator);
            errdefer out.deinit();
            // Report which function was matched (may differ from requested name due to suffix matching)
            try out.append("Set function breakpoint:\n");
            try appendBreakpointText(&out, &bp);
            // Hint: if the matched file/name differs from the request, note it
            if (!std.mem.eql(u8, bp.file, func_val.string) and bp.file.len > 0) {
                try out.append("  (matched: ");
                try out.append(bp.file);
                try out.append(")\n");
            }
            return .{ .ok = try out.toOwnedSlice() };
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

            return okText(allocator, "Configured exception breakpoints ({d} filters).", .{filter_list.items.len});
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

        debug_log.log("toolRun: session_id={s} action={s}", .{ session_id_val.string, action_val.string });

        // Handle goto separately — it dispatches through gotoFn, not runFn
        if (std.mem.eql(u8, action_val.string, "goto")) {
            const file_val = a.object.get("file") orelse return .{ .err = .{ .code = INVALID_PARAMS, .message = "Missing file for goto" } };
            if (file_val != .string) return .{ .err = .{ .code = INVALID_PARAMS, .message = "file must be string" } };
            const line_val = a.object.get("line") orelse return .{ .err = .{ .code = INVALID_PARAMS, .message = "Missing line for goto" } };
            if (line_val != .integer) return .{ .err = .{ .code = INVALID_PARAMS, .message = "line must be integer" } };

            var state = session.driver.goto(allocator, file_val.string, @intCast(line_val.integer)) catch |err| {
                self.dashboard.onError("debug_run", @errorName(err));
                return .{ .err = .{ .code = errorToCode(err), .message = @errorName(err) } };
            };
            defer state.deinit(allocator);

            session.status = .stopped;
            self.dashboard.onRun(session_id_val.string, "goto", state);
            self.emitStopEvent(session_id_val.string, "goto", state);

            return .{ .ok = try formatStopStateText(allocator, &state) };
        }

        // Handle step_over_inspect — composite action: step + evaluate in a loop
        if (std.mem.eql(u8, action_val.string, "step_over_inspect")) {
            return self.toolStepOverInspect(allocator, a, session);
        }

        const action = types.RunAction.parse(action_val.string) orelse
            return .{ .err = .{ .code = INVALID_PARAMS, .message = "Invalid action" } };

        const run_options = types.RunOptions{
            .granularity = if (a.object.get("granularity")) |v| (if (v == .string) types.SteppingGranularity.parse(v.string) else null) else null,
            .target_id = if (a.object.get("target_id")) |v| (if (v == .integer) @as(u32, @intCast(v.integer)) else null) else null,
            .thread_id = if (a.object.get("thread_id")) |v| (if (v == .integer) @as(u32, @intCast(v.integer)) else null) else null,
        };

        // When pause is requested and a background run is active, use
        // write-only sendPause to avoid a data race (two threads reading
        // from the same socket).  The background thread will pick up the
        // stopped event; the caller should use debug_poll_events to see it.
        if (action == .pause and session.pending_run != null) {
            const thread_id: ?u32 = if (run_options.thread_id) |t| t else null;
            session.driver.sendPause(allocator, thread_id) catch |err| {
                self.dashboard.onError("debug_run", @errorName(err));
                return .{ .err = .{ .code = errorToCode(err), .message = @errorName(err) } };
            };

            return okText(allocator, "Pausing session `{s}`.", .{session_id_val.string});
        }

        // Restart delegates to driver.restart() which handles the full
        // restart flow (re-arm breakpoints, re-initialize, etc.).
        if (action == .restart) {
            session.driver.restart(allocator) catch |err| {
                self.dashboard.onError("debug_run", @errorName(err));
                return .{ .err = .{ .code = errorToCode(err), .message = @errorName(err) } };
            };
            session.status = .stopped;
            return okText(allocator, "Restarted session `{s}`.", .{session_id_val.string});
        }

        // Pause is non-blocking — keep synchronous
        if (action == .pause) {
            session.status = .running;
            var state = session.driver.runEx(allocator, action, run_options) catch |err| {
                self.dashboard.onError("debug_run", @errorName(err));
                return .{ .err = .{ .code = errorToCode(err), .message = @errorName(err) } };
            };
            defer state.deinit(allocator);

            session.status = if (state.exit_code != null) .terminated else .stopped;
            self.dashboard.onRun(session_id_val.string, action_val.string, state);
            self.emitStopEvent(session_id_val.string, action_val.string, state);

            return .{ .ok = try formatStopStateText(allocator, &state) };
        }

        // Execution control: continue, step_into, step_over, step_out,
        // reverse_continue, step_back.
        if (session.pending_run != null) {
            return .{ .err = .{ .code = INTERNAL_ERROR, .message = "Session is already running. Use debug_poll_events to check status or debug_stop to cancel." } };
        }

        // Parse timeout_ms: default 30000 (synchronous blocking), 0 = async
        const timeout_ms: i64 = if (a.object.get("timeout_ms")) |v|
            (if (v == .integer) v.integer else 30000)
        else
            30000;

        const pending_run = session_mod.Session.PendingRun.create(self.allocator, session_id_val.string, action_val.string) catch {
            return .{ .err = .{ .code = INTERNAL_ERROR, .message = "Failed to allocate run state" } };
        };

        session.status = .running;
        session.pending_run = pending_run;
        self.emitRunEvent(session_id_val.string, action_val.string);

        debug_log.log("toolRun: spawning background run session_id={s} action={s}", .{ pending_run.session_id, pending_run.action_name });
        pending_run.thread = std.Thread.spawn(.{}, runBackground, .{ pending_run, session.driver, self.allocator, action, run_options }) catch |err| {
            session.status = .stopped;
            session.pending_run = null;
            pending_run.release();
            self.dashboard.onError("debug_run", @errorName(err));
            return .{ .err = .{ .code = INTERNAL_ERROR, .message = "Failed to spawn run thread" } };
        };

        // Async path: return immediately with status:running
        if (timeout_ms <= 0) {
            debug_log.log("toolRun: async (non-blocking) path, returning immediately", .{});
            return okText(allocator, "Session `{s}` is running in the background.", .{session_id_val.string});
        }

        pending_run.retain();
        defer pending_run.release();
        pending_run.waiter_owns_completion.store(true, .release);
        defer pending_run.waiter_owns_completion.store(false, .release);
        const run_driver = session.driver;
        debug_log.log("toolRun: blocking path, timeout_ms={d}", .{timeout_ms});

        // Synchronous blocking path: release mutex while the run owns its
        // stable PendingRun reference, then re-resolve the session afterward.
        debug_log.log("toolRun: releasing mutex for blocking poll", .{});
        self.mutex.unlock();
        var mutex_locked = false;
        defer if (!mutex_locked) {
            debug_log.log("toolRun: re-acquiring mutex before return", .{});
            self.mutex.lock();
        };

        const deadline_ms: i128 = @as(i128, std.time.milliTimestamp()) + timeout_ms;
        const poll_interval_ns: u64 = 10 * std.time.ns_per_ms; // 10ms

        while (pending_run.result.load(.acquire) == 0) {
            if (std.time.milliTimestamp() >= deadline_ms) {
                debug_log.log("toolRun: timeout reached, requesting pause session_id={s}", .{pending_run.session_id});
                var driver = run_driver;
                driver.sendPause(allocator, null) catch |pause_err| {
                    debug_log.log("toolRun: pause failed session_id={s}: {s}; interrupting active run", .{ pending_run.session_id, @errorName(pause_err) });
                    driver.interruptRun();
                };
                const pause_deadline_ms = std.time.milliTimestamp() + 250;
                while (pending_run.result.load(.acquire) == 0 and
                    std.time.milliTimestamp() < pause_deadline_ms)
                {
                    std.Thread.sleep(poll_interval_ns);
                }
                if (pending_run.result.load(.acquire) == 0) {
                    debug_log.log("toolRun: pause did not complete session_id={s}; interrupting active run", .{pending_run.session_id});
                    driver.interruptRun();
                    const interrupt_deadline_ms = std.time.milliTimestamp() + 250;
                    while (pending_run.result.load(.acquire) == 0 and
                        std.time.milliTimestamp() < interrupt_deadline_ms)
                    {
                        std.Thread.sleep(poll_interval_ns);
                    }
                }
                if (pending_run.result.load(.acquire) == 0) {
                    debug_log.log("toolRun: interrupt did not complete session_id={s}; run remains session-owned", .{pending_run.session_id});
                    return okText(allocator, "Timed out waiting for session `{s}`; the run remains active in the background.", .{pending_run.session_id});
                }
                break;
            }
            std.Thread.sleep(poll_interval_ns);
        }

        debug_log.log("toolRun: re-acquiring mutex to consume session_id={s}", .{pending_run.session_id});
        self.mutex.lock();
        mutex_locked = true;
        const removed_or_session = self.session_manager.sessions.get(pending_run.session_id);
        if (removed_or_session) |current_session| {
            if (current_session.pending_run == pending_run) {
                current_session.pending_run = null;
                pending_run.join();
                defer pending_run.release();
                return self.finishRun(allocator, current_session, pending_run, true);
            }
        }
        return .{ .err = .{ .code = INVALID_PARAMS, .message = "Session ended while run was active" } };
    }

    /// Background thread function for async execution control. The worker only
    /// touches the stable heap-owned PendingRun record passed at spawn time.
    fn runBackground(pending_run: *session_mod.Session.PendingRun, driver_value: driver_mod.ActiveDriver, alloc: std.mem.Allocator, action: types.RunAction, opts: types.RunOptions) void {
        var driver = driver_value;
        debug_log.log("runBackground: entering driver.runEx session_id={s} action={s}", .{ pending_run.session_id, pending_run.action_name });
        const state = driver.runEx(alloc, action, opts) catch |err| {
            pending_run.error_msg = @errorName(err);
            pending_run.result.store(2, .release);
            debug_log.log("runBackground: failed session_id={s}: {s}", .{ pending_run.session_id, @errorName(err) });
            return;
        };
        pending_run.stop_state = state;
        pending_run.result.store(1, .release);
        debug_log.log("runBackground: completed session_id={s} reason={s}", .{ pending_run.session_id, @tagName(state.stop_reason) });
    }

    fn finishRun(self: *DebugServer, allocator: std.mem.Allocator, session: *session_mod.Session, pending_run: *session_mod.Session.PendingRun, emit_event: bool) !ToolResult {
        const status = pending_run.result.load(.acquire);
        if (status == 1) {
            const state = pending_run.stop_state orelse {
                session.status = .stopped;
                return .{ .err = .{ .code = INTERNAL_ERROR, .message = "Run completed but no stop state" } };
            };
            session.status = if (state.exit_code != null) .terminated else .stopped;
            if (emit_event) {
                self.dashboard.onRun(pending_run.session_id, pending_run.action_name, state);
                self.emitStopEvent(pending_run.session_id, pending_run.action_name, state);
            }
            return .{ .ok = try formatStopStateText(allocator, &state) };
        }

        session.status = .stopped;
        return .{ .err = .{ .code = INTERNAL_ERROR, .message = pending_run.error_msg orelse "unknown error" } };
    }

    /// Composite action: step over repeatedly while evaluating expressions.
    /// At each stop, evaluates ALL expressions and records per-step results.
    /// Expressions that haven't resolved yet stay in the pending list; once all
    /// have resolved at least once the loop can stop early. Stops when: all
    /// resolved, max steps reached, function returned (stack depth decreased),
    /// or program exited.
    fn toolStepOverInspect(self: *DebugServer, allocator: std.mem.Allocator, a: json.Value, session: *session_mod.Session) !ToolResult {
        if (requireStopped(session)) |err_result| return err_result;

        // Parse expressions array
        const expr_val = a.object.get("expressions") orelse
            return .{ .err = .{ .code = INVALID_PARAMS, .message = "Missing expressions for step_over_inspect" } };
        if (expr_val != .array) return .{ .err = .{ .code = INVALID_PARAMS, .message = "expressions must be array" } };
        if (expr_val.array.items.len == 0) return .{ .err = .{ .code = INVALID_PARAMS, .message = "expressions must not be empty" } };

        const max_steps: u32 = if (a.object.get("max_steps")) |v|
            (if (v == .integer and v.integer > 0) @as(u32, @intCast(v.integer)) else 5)
        else
            5;

        // Collect expression strings
        var expressions = std.ArrayListUnmanaged([]const u8).empty;
        defer expressions.deinit(allocator);
        for (expr_val.array.items) |item| {
            if (item == .string) {
                try expressions.append(allocator, item.string);
            }
        }
        if (expressions.items.len == 0) return .{ .err = .{ .code = INVALID_PARAMS, .message = "No valid string expressions" } };

        // Get initial stack depth via stacktrace
        const initial_depth: usize = blk: {
            const frames = session.driver.stackTrace(allocator, 1, 0, 100) catch break :blk 0;
            defer types.StackFrame.deinitSlice(allocator, frames);
            break :blk frames.len;
        };

        // Per-step records: each entry is one stop point
        const StepRecord = struct {
            file: []const u8,
            line: u32,
            function: []const u8,
            /// One value per expression (same order as `expressions`).
            /// null = evaluation failed / not in scope at this step.
            values: []?[]const u8,
        };
        var steps = std.ArrayListUnmanaged(StepRecord).empty;
        defer {
            for (steps.items) |step| {
                if (step.file.len > 0) allocator.free(step.file);
                if (step.function.len > 0) allocator.free(step.function);
                for (step.values) |maybe_val| {
                    if (maybe_val) |v| allocator.free(v);
                }
                allocator.free(step.values);
            }
            steps.deinit(allocator);
        }

        // Track which expressions have resolved at least once (for early stop)
        var resolved = try allocator.alloc(bool, expressions.items.len);
        defer allocator.free(resolved);
        @memset(resolved, false);

        // Mark session as running so concurrent tool calls are rejected
        session.status = .running;

        // Release mutex for blocking DAP calls
        debug_log.log("toolStepOverInspect: releasing mutex for blocking DAP calls", .{});
        self.mutex.unlock();
        defer {
            debug_log.log("toolStepOverInspect: re-acquiring mutex after DAP calls", .{});
            self.mutex.lock();
            debug_log.log("toolStepOverInspect: mutex re-acquired after DAP calls", .{});
        }

        var steps_taken: u32 = 0;
        var final_stop_reason: []const u8 = "max_steps";
        var exited = false;

        while (true) {
            // Get current location via stacktrace. Step records own their copies.
            var step_file: []const u8 = "";
            var step_line: u32 = 0;
            var step_func: []const u8 = "";
            if (session.driver.stackTrace(allocator, 1, 0, 1)) |frames| {
                defer types.StackFrame.deinitSlice(allocator, frames);
                if (frames.len > 0) {
                    step_file = try allocator.dupe(u8, frames[0].source);
                    errdefer allocator.free(step_file);
                    step_line = frames[0].line;
                    step_func = try allocator.dupe(u8, frames[0].name);
                }
            } else |_| {}

            // Evaluate every expression at this stop
            const values = try allocator.alloc(?[]const u8, expressions.items.len);
            errdefer {
                for (values) |maybe_val| {
                    if (maybe_val) |v| allocator.free(v);
                }
                allocator.free(values);
            }

            var all_resolved = true;
            for (expressions.items, 0..) |expr, i| {
                const inspect_result = session.driver.inspect(allocator, .{
                    .expression = expr,
                    .frame_id = 0,
                }) catch {
                    values[i] = null;
                    if (!resolved[i]) all_resolved = false;
                    continue;
                };
                defer inspect_result.deinit(allocator);

                if (!inspect_result.is_error and inspect_result.result.len > 0) {
                    values[i] = try allocator.dupe(u8, inspect_result.result);
                    resolved[i] = true;
                } else {
                    values[i] = null;
                    if (!resolved[i]) all_resolved = false;
                }
            }

            try steps.append(allocator, .{
                .file = step_file,
                .line = step_line,
                .function = step_func,
                .values = values,
            });

            // Check early termination: all expressions resolved at least once
            if (all_resolved) {
                final_stop_reason = "all_resolved";
                break;
            }

            // Step over
            var state = session.driver.runEx(allocator, .step_over, .{}) catch {
                final_stop_reason = "error";
                break;
            };
            defer state.deinit(allocator);

            // Check if program exited
            if (state.exit_code != null or state.stop_reason == .exited) {
                exited = true;
                final_stop_reason = "exited";
                break;
            }

            // Check if we stepped out of the function (stack depth decreased)
            const current_depth: usize = depth_blk: {
                const frames = session.driver.stackTrace(allocator, 1, 0, 100) catch break :depth_blk initial_depth;
                defer types.StackFrame.deinitSlice(allocator, frames);
                break :depth_blk frames.len;
            };
            if (current_depth < initial_depth) {
                final_stop_reason = "stepped_out";
                break;
            }

            steps_taken += 1;
            if (steps_taken >= max_steps) {
                final_stop_reason = "max_steps";
                break;
            }
        }

        // Restore session status
        session.status = if (exited) .terminated else .stopped;

        // Build JSON response
        var aw: Writer.Allocating = .init(allocator);
        defer aw.deinit();
        var jw: Stringify = .{ .writer = &aw.writer };
        try jw.beginObject();

        // Per-step trace
        try jw.objectField("steps");
        try jw.beginArray();
        for (steps.items, 0..) |step, step_idx| {
            try jw.beginObject();
            try jw.objectField("step");
            try jw.write(step_idx + 1);
            try jw.objectField("file");
            try jw.write(step.file);
            try jw.objectField("line");
            try jw.write(step.line);
            try jw.objectField("function");
            try jw.write(step.function);
            try jw.objectField("values");
            try jw.beginObject();
            for (expressions.items, 0..) |expr, i| {
                try jw.objectField(expr);
                if (step.values[i]) |val| {
                    try jw.write(val);
                } else {
                    try jw.write(null);
                }
            }
            try jw.endObject();
            try jw.endObject();
        }
        try jw.endArray();

        // Unresolved expressions (never succeeded at any step)
        {
            var has_unresolved = false;
            for (resolved) |r| {
                if (!r) {
                    has_unresolved = true;
                    break;
                }
            }
            if (has_unresolved) {
                try jw.objectField("unresolved");
                try jw.beginArray();
                for (expressions.items, 0..) |expr, i| {
                    if (!resolved[i]) try jw.write(expr);
                }
                try jw.endArray();
            }
        }

        try jw.objectField("steps_taken");
        try jw.write(steps.items.len);
        try jw.objectField("stop_reason");
        try jw.write(final_stop_reason);

        try jw.endObject();
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

        if (requireStopped(session)) |err_result| return err_result;

        {
            const expr_hint = if (a.object.get("expression")) |v| (if (v == .string) v.string else "(none)") else "(none)";
            debug_log.log("toolInspect: session_id={s} expression={s}", .{ session_id_val.string, expr_hint });
        }

        const request = types.InspectRequest{
            .expression = if (a.object.get("expression")) |v| (if (v == .string) v.string else null) else null,
            .variable_ref = if (a.object.get("variable_ref")) |v| (if (v == .integer) @as(u32, @intCast(v.integer)) else null) else null,
            .frame_id = if (a.object.get("frame_id")) |v| (if (v == .integer) @as(u32, @intCast(v.integer)) else null) else null,
            .scope = if (a.object.get("scope")) |v| (if (v == .string) v.string else null) else null,
            .context = if (a.object.get("context")) |v| (if (v == .string) types.EvaluateContext.parse(v.string) else null) else null,
        };

        const result_val = session.driver.inspect(allocator, request) catch |err| {
            debug_log.log("toolInspect: inspect failed: {s}", .{@errorName(err)});
            self.dashboard.onError("debug_inspect", @errorName(err));
            return .{ .err = .{ .code = errorToCode(err), .message = @errorName(err) } };
        };
        defer result_val.deinit(allocator);
        debug_log.log("toolInspect: result={s} type={s} children={d} is_error={}", .{ result_val.result, result_val.type, result_val.children.len, result_val.is_error });
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
        const end_mode: EndMode = if (terminate_only) .terminate else if (detach) .detach else .stop;
        debug_log.log("toolStop: session_id={s} mode={s}", .{ session_id, @tagName(end_mode) });

        return self.endSessionLocked(allocator, session_id, end_mode, true);
    }

    pub const EndMode = enum { stop, terminate, detach };

    /// Remove a session from discoverable state while holding the server mutex,
    /// then interrupt and join its active run outside the mutex.
    pub fn endSessionLocked(self: *DebugServer, allocator: std.mem.Allocator, session_id: []const u8, mode: EndMode, emit_event: bool) !ToolResult {
        const session = self.session_manager.sessions.get(session_id) orelse
            return ToolResult{ .err = .{ .code = INVALID_PARAMS, .message = "Unknown session" } };
        session.status = .ending;
        const removed = self.session_manager.removeSession(session_id) orelse
            return .{ .ok_static = "{\"stopped\":true}" };

        debug_log.log("endSessionLocked: removed session_id={s} mode={s} active={}", .{ session_id, @tagName(mode), removed.session.pending_run != null });
        self.mutex.unlock();
        defer self.mutex.lock();

        var driver = removed.session.driver;
        if (removed.session.pending_run) |pending_run| {
            debug_log.log("endSessionLocked: interrupting active run session_id={s}", .{removed.key});
            driver.interruptRun();
            pending_run.join();
        }

        switch (mode) {
            .detach => driver.detach(allocator) catch |err| {
                debug_log.log("endSessionLocked: detach failed session_id={s}: {s}", .{ removed.key, @errorName(err) });
                driver.stop(allocator) catch {};
            },
            .terminate => driver.terminate(allocator) catch |err| {
                debug_log.log("endSessionLocked: terminate failed session_id={s}: {s}", .{ removed.key, @errorName(err) });
                driver.stop(allocator) catch {};
            },
            .stop => driver.stop(allocator) catch |err| {
                debug_log.log("endSessionLocked: stop failed session_id={s}: {s}", .{ removed.key, @errorName(err) });
                driver.terminate(allocator) catch {};
            },
        }

        if (emit_event) {
            self.dashboard.onStop(removed.key);
            _ = self.emitSessionEndEvent(removed.key);
        }
        self.session_manager.destroyRemovedSession(removed);
        debug_log.log("endSessionLocked: destroyed session_id={s}", .{session_id});
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
            self.dashboard.onError("debug_threads", @errorName(err));
            return .{ .err = .{ .code = errorToCode(err), .message = @errorName(err) } };
        };
        self.dashboard.onThreads(session_id_val.string, thread_list.len);
        {
            var abuf: [64]u8 = undefined;
            const asum = std.fmt.bufPrint(&abuf, "{d} thread(s)", .{thread_list.len}) catch "threads listed";
            self.emitActivityEvent(session_id_val.string, "debug_threads", asum);
        }

        return .{ .ok = try formatThreadsText(allocator, thread_list) };
    }

    fn toolStackTrace(self: *DebugServer, allocator: std.mem.Allocator, args: ?json.Value) !ToolResult {
        const a = args orelse return .{ .err = .{ .code = INVALID_PARAMS, .message = "Missing arguments" } };
        if (a != .object) return .{ .err = .{ .code = INVALID_PARAMS, .message = "Arguments must be object" } };

        const session_id_val = a.object.get("session_id") orelse return .{ .err = .{ .code = INVALID_PARAMS, .message = "Missing session_id" } };
        if (session_id_val != .string) return .{ .err = .{ .code = INVALID_PARAMS, .message = "session_id must be string" } };

        const session = self.session_manager.getSession(session_id_val.string) orelse
            return .{ .err = .{ .code = INVALID_PARAMS, .message = "Unknown session" } };

        if (requireStopped(session)) |err_result| return err_result;

        const thread_id: u32 = if (a.object.get("thread_id")) |v| (if (v == .integer) @intCast(v.integer) else 0) else 0;
        const start_frame: u32 = if (a.object.get("start_frame")) |v| (if (v == .integer) @intCast(v.integer) else 0) else 0;
        const levels: u32 = if (a.object.get("levels")) |v| (if (v == .integer) @intCast(v.integer) else 20) else 20;

        const frames = session.driver.stackTrace(allocator, thread_id, start_frame, levels) catch |err| {
            self.dashboard.onError("debug_stacktrace", @errorName(err));
            return .{ .err = .{ .code = errorToCode(err), .message = @errorName(err) } };
        };
        defer types.StackFrame.deinitSlice(allocator, frames);
        self.dashboard.onStackTrace(session_id_val.string, frames.len);
        {
            var abuf: [64]u8 = undefined;
            const asum = std.fmt.bufPrint(&abuf, "{d} frame(s)", .{frames.len}) catch "stack trace";
            self.emitActivityEvent(session_id_val.string, "debug_stacktrace", asum);
        }

        return .{ .ok = try formatStackTraceText(allocator, frames) };
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
                self.dashboard.onError("debug_memory", @errorName(err));
                return .{ .err = .{ .code = errorToCode(err), .message = @errorName(err) } };
            };
            self.dashboard.onMemory(session_id_val.string, "read", addr_val.string);

            return .{ .ok = try formatMemoryReadText(allocator, addr_val.string, size, hex_data) };
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

            return okText(allocator, "Wrote memory at {s}.", .{addr_val.string});
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
            self.dashboard.onError("debug_disassemble", @errorName(err));
            return .{ .err = .{ .code = errorToCode(err), .message = @errorName(err) } };
        };
        var addr_buf: [18]u8 = undefined;
        const addr_display = std.fmt.bufPrint(&addr_buf, "0x{x}", .{address}) catch "0x?";
        self.dashboard.onDisassemble(session_id_val.string, addr_display, instructions.len);

        return .{ .ok = try formatDisassemblyText(allocator, instructions) };
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
                    std.mem.eql(u8, lang, "typescript") or
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

        const session_id = try self.session_manager.createSession(driver, client_pid, .detach);
        if (self.session_manager.getSession(session_id)) |s| {
            s.status = .stopped;
        }
        debug_log.log("toolAttach: session created id={s} driver={s}", .{ session_id, driver_type_name });
        self.dashboard.onLaunch(session_id, "attached", driver_type_name);
        self.dashboard.onAttach(session_id, pid_val.integer);
        self.emitLaunchEvent(session_id, "attached", driver_type_name);

        return okText(allocator, "Attached session `{s}` to pid {d} using {s}.", .{ session_id, pid_val.integer, driver_type_name });
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

        if (requireStopped(session)) |err_result| return err_result;

        const frame_id: u32 = if (a.object.get("frame_id")) |v| (if (v == .integer) @intCast(v.integer) else 0) else 0;

        const scope_list = session.driver.scopes(allocator, frame_id) catch |err| {
            self.dashboard.onError("debug_scopes", @errorName(err));
            return .{ .err = .{ .code = errorToCode(err), .message = @errorName(err) } };
        };
        self.dashboard.onScopes(session_id_val.string, scope_list.len);

        return .{ .ok = try formatScopesText(allocator, scope_list) };
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

        debug_log.log("toolModules: session_id={s}", .{session_id_val.string});

        const session = self.session_manager.getSession(session_id_val.string) orelse
            return .{ .err = .{ .code = INVALID_PARAMS, .message = "Unknown session" } };

        const mod_list = session.driver.modules(allocator) catch |err| {
            debug_log.log("toolModules: failed: {s}", .{@errorName(err)});
            self.dashboard.onError("debug_modules", @errorName(err));
            return .{ .err = .{ .code = errorToCode(err), .message = @errorName(err) } };
        };
        debug_log.log("toolModules: found {d} modules", .{mod_list.len});
        self.dashboard.onModules(session_id_val.string, mod_list.len);

        return .{ .ok = try formatModulesText(allocator, mod_list) };
    }

    fn toolLoadedSources(self: *DebugServer, allocator: std.mem.Allocator, args: ?json.Value) !ToolResult {
        const a = args orelse return .{ .err = .{ .code = INVALID_PARAMS, .message = "Missing arguments" } };
        if (a != .object) return .{ .err = .{ .code = INVALID_PARAMS, .message = "Arguments must be object" } };

        const session_id_val = a.object.get("session_id") orelse return .{ .err = .{ .code = INVALID_PARAMS, .message = "Missing session_id" } };
        if (session_id_val != .string) return .{ .err = .{ .code = INVALID_PARAMS, .message = "session_id must be string" } };

        debug_log.log("toolLoadedSources: session_id={s}", .{session_id_val.string});

        const session = self.session_manager.getSession(session_id_val.string) orelse
            return .{ .err = .{ .code = INVALID_PARAMS, .message = "Unknown session" } };

        const source_list = session.driver.loadedSources(allocator) catch |err| {
            debug_log.log("toolLoadedSources: failed: {s}", .{@errorName(err)});
            self.dashboard.onError("debug_loaded_sources", @errorName(err));
            return .{ .err = .{ .code = errorToCode(err), .message = @errorName(err) } };
        };
        debug_log.log("toolLoadedSources: found {d} sources", .{source_list.len});
        self.dashboard.onLoadedSources(session_id_val.string, source_list.len);

        return .{ .ok = try formatLoadedSourcesText(allocator, source_list) };
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

        return .{ .ok = content };
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

        if (requireStopped(session)) |err_result| return err_result;

        const frame_id_val = a.object.get("frame_id") orelse return .{ .err = .{ .code = INVALID_PARAMS, .message = "Missing frame_id" } };
        if (frame_id_val != .integer) return .{ .err = .{ .code = INVALID_PARAMS, .message = "frame_id must be integer" } };

        session.driver.restartFrame(allocator, @intCast(frame_id_val.integer)) catch |err| {
            self.dashboard.onError("debug_restart_frame", @errorName(err));
            return .{ .err = .{ .code = errorToCode(err), .message = @errorName(err) } };
        };
        self.dashboard.onRestartFrame(session_id_val.string, @intCast(frame_id_val.integer));

        return okText(allocator, "Restarted frame {d} in session `{s}`.", .{ @as(u32, @intCast(frame_id_val.integer)), session_id_val.string });
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

        const thread_id: u32 = if (a.object.get("thread_id")) |v| (if (v == .integer) @intCast(v.integer) else 0) else 0;

        const info = session.driver.exceptionInfo(allocator, thread_id) catch |err| {
            self.dashboard.onError("debug_exception_info", @errorName(err));
            return .{ .err = .{ .code = errorToCode(err), .message = @errorName(err) } };
        };
        self.dashboard.onExceptionInfo(session_id_val.string);

        return .{ .ok = try formatExceptionInfoText(allocator, &info) };
    }

    fn toolRegisters(self: *DebugServer, allocator: std.mem.Allocator, args: ?json.Value) !ToolResult {
        const a = args orelse return .{ .err = .{ .code = INVALID_PARAMS, .message = "Missing arguments" } };
        if (a != .object) return .{ .err = .{ .code = INVALID_PARAMS, .message = "Arguments must be object" } };

        const session_id_val = a.object.get("session_id") orelse return .{ .err = .{ .code = INVALID_PARAMS, .message = "Missing session_id" } };
        if (session_id_val != .string) return .{ .err = .{ .code = INVALID_PARAMS, .message = "session_id must be string" } };

        const session = self.session_manager.getSession(session_id_val.string) orelse
            return .{ .err = .{ .code = INVALID_PARAMS, .message = "Unknown session" } };

        if (requireStopped(session)) |err_result| return err_result;

        const thread_id: u32 = if (a.object.get("thread_id")) |v| (if (v == .integer) @intCast(v.integer) else 0) else 0;

        const regs = session.driver.readRegisters(allocator, thread_id) catch |err| {
            self.dashboard.onError("debug_registers", @errorName(err));
            return .{ .err = .{ .code = errorToCode(err), .message = @errorName(err) } };
        };
        self.dashboard.onRegisters(session_id_val.string, regs.len);

        return .{ .ok = try formatRegistersText(allocator, regs) };
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

        if (requireStopped(session)) |err_result| return err_result;

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

        return .{ .ok = try formatBreakpointLocationsText(allocator, locations) };
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

        return okText(allocator, "Cancelled outstanding debug work for session `{s}`.", .{session_id_val.string});
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

        return okText(allocator, "Terminated {d} thread(s) in session `{s}`.", .{ id_list.items.len, session_id_val.string });
    }

    fn toolRestart(self: *DebugServer, allocator: std.mem.Allocator, args: ?json.Value) !ToolResult {
        const a = args orelse return .{ .err = .{ .code = INVALID_PARAMS, .message = "Missing arguments" } };
        if (a != .object) return .{ .err = .{ .code = INVALID_PARAMS, .message = "Arguments must be object" } };

        const session_id_val = a.object.get("session_id") orelse return .{ .err = .{ .code = INVALID_PARAMS, .message = "Missing session_id" } };
        if (session_id_val != .string) return .{ .err = .{ .code = INVALID_PARAMS, .message = "session_id must be string" } };

        const session = self.session_manager.getSession(session_id_val.string) orelse
            return .{ .err = .{ .code = INVALID_PARAMS, .message = "Unknown session" } };

        if (requireStopped(session)) |err_result| return err_result;

        session.driver.restart(allocator) catch |err| {
            self.dashboard.onError("debug_restart", @errorName(err));
            return .{ .err = .{ .code = errorToCode(err), .message = @errorName(err) } };
        };
        self.dashboard.onRestart(session_id_val.string);

        return okText(allocator, "Restarted session `{s}`.", .{session_id_val.string});
    }

    // ── Phase 4: New Tool Implementations ────────────────────────────────

    fn toolSessions(self: *DebugServer, allocator: std.mem.Allocator) !ToolResult {
        const sessions = self.session_manager.listSessions(allocator) catch |err| {
            return .{ .err = .{ .code = errorToCode(err), .message = @errorName(err) } };
        };
        defer allocator.free(sessions);

        return .{ .ok = try formatSessionListText(allocator, sessions) };
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

        return .{ .ok = try formatGotoTargetsText(allocator, targets) };
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

        return .{ .ok = try formatSymbolsText(allocator, symbols) };
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
            self.dashboard.onError("debug_write_register", @errorName(err));
            return .{ .err = .{ .code = errorToCode(err), .message = @errorName(err) } };
        };

        return okText(allocator, "Wrote register `{s}` in session `{s}`.", .{ name_val.string, session_id_val.string });
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
            self.dashboard.onError("debug_variable_location", @errorName(err));
            return .{ .err = .{ .code = errorToCode(err), .message = @errorName(err) } };
        };

        return .{ .ok = try formatVariableLocationText(allocator, &loc) };
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
        const now = std.time.milliTimestamp();

        try jw.beginObject();
        try jw.objectField("diagnostics");
        try jw.beginArray();
        var diagnostics_it = self.session_manager.sessions.iterator();
        while (diagnostics_it.next()) |entry| {
            if (session_id_filter) |filter| {
                if (!std.mem.eql(u8, entry.key_ptr.*, filter)) continue;
            }
            const session = entry.value_ptr.*;
            session.last_activity = now;
            debug_log.log("DebugServer.toolPollEvents: refreshed activity session_id={s}", .{entry.key_ptr.*});
            const counters = session.driver.diagnostics() orelse continue;
            debug_log.log("DebugServer.toolPollEvents: reporting driver diagnostics session_id={s} dropped_notifications={d} dropped_events={d} dropped_output={d}", .{ entry.key_ptr.*, counters.dropped_notifications, counters.dropped_buffered_events, counters.dropped_output_entries });
            try jw.beginObject();
            try jw.objectField("session_id");
            try jw.write(entry.key_ptr.*);
            try jw.objectField("driver");
            try jw.write(@tagName(session.driver.driver_type));
            try jw.objectField("counters");
            try jw.write(counters);
            try jw.endObject();
        }
        try jw.endArray();

        try jw.objectField("events");
        try jw.beginArray();

        // Collect notifications from all or specific sessions.
        var it = self.session_manager.sessions.iterator();
        while (it.next()) |entry| {
            if (session_id_filter) |filter| {
                if (!std.mem.eql(u8, entry.key_ptr.*, filter)) continue;
            }

            const session = entry.value_ptr.*;

            // Check for completed async run
            if (session.pending_run) |pr| {
                if (pr.waiter_owns_completion.load(.acquire)) continue;
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
                    session.pending_run = null;
                    pr.join();
                    pr.release();
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

                    session.pending_run = null;
                    pr.join();
                    pr.release();
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
            self.dashboard.onError("debug_load_core", @errorName(err));
            return .{ .err = .{ .code = errorToCode(err), .message = @errorName(err) } };
        };

        const session_id = try self.session_manager.createSession(driver, client_pid, .terminate);
        if (self.session_manager.getSession(session_id)) |s| {
            s.status = .stopped;
        }
        debug_log.log("toolLoadCore: session created id={s} driver=native", .{session_id});
        self.dashboard.onLaunch(session_id, "core_dump", "native");
        self.emitLaunchEvent(session_id, "core_dump", "native");

        return okText(allocator, "Loaded core dump into session `{s}`.", .{session_id});
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
            self.dashboard.onError("debug_dap_request", @errorName(err));
            return .{ .err = .{ .code = errorToCode(err), .message = @errorName(err) } };
        };

        return .{ .ok = response };
    }

    // ── Prompts ──────────────────────────────────────────────────────────

    // ── Dashboard Socket ────────────────────────────────────────────────

    /// Attempt to connect to the standalone dashboard TUI.
    /// Silently continues if no TUI is running.
    pub fn connectDashboardSocket(self: *DebugServer) void {
        const path = paths.getDashboardSocketPath(self.allocator) catch |err| {
            debug_log.log("DebugServer.connectDashboardSocket: failed to resolve path: {s}", .{@errorName(err)});
            return;
        };
        defer self.allocator.free(path);
        paths.validateUnixSocketPath(path) catch |err| {
            debug_log.log("DebugServer.connectDashboardSocket: rejected path {s}: {s}", .{ path, @errorName(err) });
            return;
        };

        const sock = posix.socket(posix.AF.UNIX, posix.SOCK.STREAM | posix.SOCK.CLOEXEC, 0) catch |err| {
            debug_log.log("DebugServer.connectDashboardSocket: socket creation failed: {s}", .{@errorName(err)});
            return;
        };
        errdefer posix.close(sock);

        var addr: posix.sockaddr.un = .{ .path = undefined };
        @memset(&addr.path, 0);
        @memcpy(addr.path[0..path.len], path);

        debug_log.log("DebugServer.connectDashboardSocket: connecting to {s}", .{path});
        posix.connect(sock, @ptrCast(&addr), @sizeOf(posix.sockaddr.un)) catch |err| {
            debug_log.log("DebugServer.connectDashboardSocket: connection failed: {s}", .{@errorName(err)});
            posix.close(sock);
            return;
        };
        ipc_identity.validatePeerUid(sock) catch |err| {
            debug_log.log("DebugServer.connectDashboardSocket: rejected peer: {s}", .{@errorName(err)});
            posix.close(sock);
            return;
        };

        debug_log.log("DebugServer.connectDashboardSocket: connected to {s}", .{path});
        self.dashboard_socket = sock;
        self.dashboard_available = true;
        self.dashboard_failure_count = 0;
    }

    pub fn rememberDashboardLaunch(self: *DebugServer, session_id: []const u8, program: []const u8, driver_type: []const u8, status: []const u8) void {
        for (self.dashboard_sessions[0..self.dashboard_session_count]) |*session| {
            if (std.mem.eql(u8, session.sessionIdSlice(), session_id)) {
                copyDashboardText(&session.program, &session.program_len, program);
                copyDashboardText(&session.driver_type, &session.driver_type_len, driver_type);
                copyDashboardText(&session.status, &session.status_len, status);
                session.pending_end = false;
                return;
            }
        }
        if (self.dashboard_session_count == self.dashboard_sessions.len) {
            debug_log.log("DebugServer.rememberDashboardLaunch: session cache full limit={d}", .{self.dashboard_sessions.len});
            return;
        }
        const session = &self.dashboard_sessions[self.dashboard_session_count];
        session.* = .{};
        copyDashboardText(&session.session_id, &session.session_id_len, session_id);
        copyDashboardText(&session.program, &session.program_len, program);
        copyDashboardText(&session.driver_type, &session.driver_type_len, driver_type);
        copyDashboardText(&session.status, &session.status_len, status);
        self.dashboard_session_count += 1;
    }

    fn rememberDashboardStatus(self: *DebugServer, session_id: []const u8, status: []const u8) void {
        for (self.dashboard_sessions[0..self.dashboard_session_count]) |*session| {
            if (!std.mem.eql(u8, session.sessionIdSlice(), session_id)) continue;
            copyDashboardText(&session.status, &session.status_len, status);
            return;
        }
    }

    fn markDashboardSessionEnding(self: *DebugServer, session_id: []const u8) void {
        for (self.dashboard_sessions[0..self.dashboard_session_count]) |*session| {
            if (!std.mem.eql(u8, session.sessionIdSlice(), session_id)) continue;
            session.pending_end = true;
            return;
        }
    }

    fn forgetDashboardSession(self: *DebugServer, session_id: []const u8) void {
        var index: usize = 0;
        while (index < self.dashboard_session_count) : (index += 1) {
            if (!std.mem.eql(u8, self.dashboard_sessions[index].sessionIdSlice(), session_id)) continue;
            var shift = index;
            while (shift + 1 < self.dashboard_session_count) : (shift += 1) {
                self.dashboard_sessions[shift] = self.dashboard_sessions[shift + 1];
            }
            self.dashboard_session_count -= 1;
            return;
        }
    }

    fn dashboardSession(self: *DebugServer, session_id: []const u8) ?*DashboardSessionState {
        for (self.dashboard_sessions[0..self.dashboard_session_count]) |*session| {
            if (std.mem.eql(u8, session.sessionIdSlice(), session_id)) return session;
        }
        return null;
    }

    fn rememberDashboardBreakpoint(self: *DebugServer, session_id: []const u8, action: []const u8, bp: types.BreakpointInfo) void {
        const session = self.dashboardSession(session_id) orelse return;
        if (std.mem.eql(u8, action, "remove")) {
            var index: usize = 0;
            while (index < session.breakpoint_count) : (index += 1) {
                const item = &session.breakpoints[index];
                if (item.id != bp.id) continue;
                var shift = index;
                while (shift + 1 < session.breakpoint_count) : (shift += 1) {
                    session.breakpoints[shift] = session.breakpoints[shift + 1];
                }
                session.breakpoint_count -= 1;
                return;
            }
            return;
        }
        if (!std.mem.eql(u8, action, "set")) return;
        for (session.breakpoints[0..session.breakpoint_count]) |*item| {
            if (item.id == bp.id) {
                item.verified = bp.verified;
                item.line = bp.line;
                copyDashboardText(&item.file, &item.file_len, bp.file);
                return;
            }
        }
        if (session.breakpoint_count == session.breakpoints.len) {
            debug_log.log("DebugServer.rememberDashboardBreakpoint: cache full session={s} limit={d}", .{ session_id, session.breakpoints.len });
            return;
        }
        const item = &session.breakpoints[session.breakpoint_count];
        item.* = .{};
        item.id = bp.id;
        item.verified = bp.verified;
        item.line = bp.line;
        copyDashboardText(&item.file, &item.file_len, bp.file);
        session.breakpoint_count += 1;
    }

    /// Write a JSON event line to the dashboard socket. Fire-and-forget.
    /// Proactively detects dead connections via poll(), reconnects, and
    /// retries once so events are not silently lost after dashboard restart.
    fn pushDashboardEvent(self: *DebugServer, event_json: []const u8) bool {
        self.dashboard_mutex.lock();
        defer self.dashboard_mutex.unlock();
        return self.pushDashboardEventLocked(event_json);
    }

    fn pushDashboardEventLocked(self: *DebugServer, event_json: []const u8) bool {
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
                debug_log.log("DebugServer.pushDashboardEvent: dashboard socket reported hangup/error fd={d}", .{sock});
                self.markDashboardDisconnected();
            }
        }

        if (self.dashboard_socket == null) {
            if (!self.dashboard_available) {
                const now_ms = std.time.milliTimestamp();
                const backoff_ms = dashboardBackoffMs(self.dashboard_failure_count);
                const elapsed_ms = now_ms - self.last_dashboard_attempt_ms;
                if (elapsed_ms < backoff_ms) {
                    debug_log.log("DebugServer.pushDashboardEvent: reconnect deferred elapsed_ms={d} backoff_ms={d}", .{ elapsed_ms, backoff_ms });
                    return false;
                }
            }
            debug_log.log("DebugServer.pushDashboardEvent: reconnecting dashboard", .{});
            self.connectDashboardSocket();
            if (self.dashboard_socket != null) {
                if (!self.replayDashboardState()) {
                    self.markDashboardDisconnected();
                    self.noteDashboardFailure();
                    return false;
                }
            } else {
                self.noteDashboardFailure();
                return false;
            }
        }

        if (self.sendDashboardData(event_json)) return true;

        // Send failed — connection is stale. Reconnect, replay state, and retry once.
        self.markDashboardDisconnected();
        debug_log.log("DebugServer.pushDashboardEvent: reconnecting after send failure", .{});
        self.connectDashboardSocket();
        if (self.dashboard_socket != null) {
            if (self.replayDashboardState() and self.sendDashboardData(event_json)) return true;
            self.markDashboardDisconnected();
        }
        self.noteDashboardFailure();
        return false;
    }

    fn noteDashboardFailure(self: *DebugServer) void {
        self.dashboard_available = false;
        self.last_dashboard_attempt_ms = std.time.milliTimestamp();
        self.dashboard_failure_count +|= 1;
        debug_log.log("DebugServer.noteDashboardFailure: failures={d} backoff_ms={d}", .{ self.dashboard_failure_count, dashboardBackoffMs(self.dashboard_failure_count) });
    }

    fn markDashboardDisconnected(self: *DebugServer) void {
        if (self.dashboard_socket) |sock| {
            debug_log.log("DebugServer.markDashboardDisconnected: closing socket fd={d}", .{sock});
            posix.close(sock);
            self.dashboard_socket = null;
        }
    }

    /// Send a complete newline-delimited event, handling short writes.
    fn sendDashboardData(self: *DebugServer, event_json: []const u8) bool {
        const sock = self.dashboard_socket orelse return false;
        var bytes_written: usize = 0;
        while (bytes_written < event_json.len) {
            const n = posix.write(sock, event_json[bytes_written..]) catch |err| {
                debug_log.log("DebugServer.sendDashboardData: event write failed fd={d} offset={d}: {s}", .{ sock, bytes_written, @errorName(err) });
                return false;
            };
            if (n == 0) {
                debug_log.log("DebugServer.sendDashboardData: event write made no progress fd={d} offset={d}", .{ sock, bytes_written });
                return false;
            }
            bytes_written += n;
        }
        var newline_written: usize = 0;
        while (newline_written < 1) {
            const n = posix.write(sock, "\n"[newline_written..]) catch |err| {
                debug_log.log("DebugServer.sendDashboardData: newline write failed fd={d}: {s}", .{ sock, @errorName(err) });
                return false;
            };
            if (n == 0) {
                debug_log.log("DebugServer.sendDashboardData: newline write made no progress fd={d}", .{sock});
                return false;
            }
            newline_written += n;
        }
        debug_log.log("DebugServer.sendDashboardData: sent event fd={d} bytes={d}", .{ sock, event_json.len + 1 });
        return true;
    }

    fn replayDashboardState(self: *DebugServer) bool {
        debug_log.log("DebugServer.replayDashboardState: replaying sessions={d}", .{self.dashboard_session_count});
        var session_index: usize = 0;
        while (session_index < self.dashboard_session_count) {
            const session = &self.dashboard_sessions[session_index];
            if (session.pending_end) {
                const session_id = session.sessionIdSlice();
                const end_event = self.buildStringEvent(self.allocator, "session_end", &.{
                    .{ .name = "session_id", .value = session_id, .max = 32 },
                }) catch |err| {
                    debug_log.log("DebugServer.replayDashboardState: session_end serialization failed: {s}", .{@errorName(err)});
                    return false;
                };
                defer self.allocator.free(end_event);
                if (!self.sendDashboardData(end_event)) return false;

                debug_log.log("DebugServer.replayDashboardState: delivered tombstone session={s}", .{session_id});
                var shift = session_index;
                while (shift + 1 < self.dashboard_session_count) : (shift += 1) {
                    self.dashboard_sessions[shift] = self.dashboard_sessions[shift + 1];
                }
                self.dashboard_session_count -= 1;
                continue;
            }
            const event = self.buildLaunchEvent(self.allocator, session.sessionIdSlice(), session.programSlice(), session.driverTypeSlice(), session.statusSlice()) catch |err| {
                debug_log.log("DebugServer.replayDashboardState: launch serialization failed: {s}", .{@errorName(err)});
                return false;
            };
            defer self.allocator.free(event);
            if (!self.sendDashboardData(event)) return false;
            for (session.breakpoints[0..session.breakpoint_count]) |*item| {
                const replay_bp = types.BreakpointInfo{
                    .id = item.id,
                    .verified = item.verified,
                    .file = item.fileSlice(),
                    .line = item.line,
                };
                const bp_event = self.buildBreakpointEvent(self.allocator, session.sessionIdSlice(), "set", replay_bp) catch |err| {
                    debug_log.log("DebugServer.replayDashboardState: breakpoint serialization failed: {s}", .{@errorName(err)});
                    return false;
                };
                defer self.allocator.free(bp_event);
                if (!self.sendDashboardData(bp_event)) return false;
            }
            session_index += 1;
        }
        return true;
    }

    fn buildLaunchEvent(self: *DebugServer, allocator: std.mem.Allocator, session_id: []const u8, program: []const u8, driver_type: []const u8, status: []const u8) ![]u8 {
        var aw: Writer.Allocating = .init(allocator);
        defer aw.deinit();
        var jw: Stringify = .{ .writer = &aw.writer };
        try jw.beginObject();
        try jw.objectField("type");
        try jw.write("launch");
        try jw.objectField("source_id");
        try jw.write(&self.dashboard_source_id);
        try jw.objectField("session_id");
        try jw.write(truncateStr(session_id, 32));
        try jw.objectField("program");
        try jw.write(truncateStr(program, 200));
        try jw.objectField("driver");
        try jw.write(truncateStr(driver_type, 16));
        try jw.objectField("status");
        try jw.write(truncateStr(status, 16));
        try jw.endObject();
        return try aw.toOwnedSlice();
    }

    /// Emit a launch event to the dashboard TUI.
    fn emitLaunchEvent(self: *DebugServer, session_id: []const u8, program: []const u8, driver_type: []const u8) void {
        self.rememberDashboardLaunch(session_id, program, driver_type, "stopped");
        const event = self.buildLaunchEvent(self.allocator, session_id, program, driver_type, "stopped") catch |err| {
            debug_log.log("DebugServer.emitLaunchEvent: serialization failed: {s}", .{@errorName(err)});
            return;
        };
        defer self.allocator.free(event);
        _ = self.pushDashboardEvent(event);
    }

    fn buildBreakpointEvent(self: *DebugServer, allocator: std.mem.Allocator, session_id: []const u8, action: []const u8, bp: types.BreakpointInfo) ![]u8 {
        var aw: Writer.Allocating = .init(allocator);
        defer aw.deinit();
        var jw: Stringify = .{ .writer = &aw.writer };
        try jw.beginObject();
        try jw.objectField("type");
        try jw.write("breakpoint");
        try jw.objectField("source_id");
        try jw.write(&self.dashboard_source_id);
        try jw.objectField("session_id");
        try jw.write(truncateStr(session_id, 32));
        try jw.objectField("action");
        try jw.write(truncateStr(action, 16));
        try jw.objectField("bp");
        try jw.beginObject();
        try jw.objectField("id");
        try jw.write(bp.id);
        try jw.objectField("file");
        try jw.write(truncateStr(bp.file, 200));
        try jw.objectField("line");
        try jw.write(bp.line);
        try jw.objectField("verified");
        try jw.write(bp.verified);
        try jw.endObject();
        try jw.endObject();
        return try aw.toOwnedSlice();
    }

    /// Emit a breakpoint event to the dashboard TUI.
    fn emitBreakpointEvent(self: *DebugServer, session_id: []const u8, action: []const u8, bp: types.BreakpointInfo) void {
        self.rememberDashboardBreakpoint(session_id, action, bp);
        const event = self.buildBreakpointEvent(self.allocator, session_id, action, bp) catch |err| {
            debug_log.log("DebugServer.emitBreakpointEvent: serialization failed: {s}", .{@errorName(err)});
            return;
        };
        defer self.allocator.free(event);
        _ = self.pushDashboardEvent(event);
    }

    fn buildStopEvent(self: *DebugServer, allocator: std.mem.Allocator, session_id: []const u8, action: []const u8, state: types.StopState) ![]u8 {
        var frame_count = @min(state.stack_trace.len, 32);
        var local_count = @min(state.locals.len, 32);

        while (true) {
            const event = try self.serializeStopEvent(
                allocator,
                session_id,
                action,
                state,
                frame_count,
                local_count,
            );
            if (event.len < MAX_DASHBOARD_EVENT_BYTES) return event;

            allocator.free(event);
            if (frame_count == 0 and local_count == 0) {
                debug_log.log("DebugServer.buildStopEvent: base event exceeds limit={d}", .{MAX_DASHBOARD_EVENT_BYTES});
                return error.DashboardEventTooLarge;
            }

            debug_log.log(
                "DebugServer.buildStopEvent: event exceeds limit={d}, reducing frames={d} locals={d}",
                .{ MAX_DASHBOARD_EVENT_BYTES, frame_count, local_count },
            );
            frame_count /= 2;
            local_count /= 2;
        }
    }

    fn serializeStopEvent(
        self: *DebugServer,
        allocator: std.mem.Allocator,
        session_id: []const u8,
        action: []const u8,
        state: types.StopState,
        frame_count: usize,
        local_count: usize,
    ) ![]u8 {
        var aw: Writer.Allocating = .init(allocator);
        defer aw.deinit();
        var jw: Stringify = .{ .writer = &aw.writer };

        try jw.beginObject();
        try jw.objectField("type");
        try jw.write("stop");
        try jw.objectField("source_id");
        try jw.write(&self.dashboard_source_id);
        try jw.objectField("session_id");
        try jw.write(truncateStr(session_id, 32));
        try jw.objectField("action");
        try jw.write(truncateStr(action, 32));
        try jw.objectField("reason");
        try jw.write(@tagName(state.stop_reason));

        if (state.location) |loc| {
            try jw.objectField("location");
            try jw.beginObject();
            try jw.objectField("file");
            try jw.write(truncateStr(loc.file, 128));
            try jw.objectField("line");
            try jw.write(loc.line);
            try jw.objectField("function");
            try jw.write(truncateStr(loc.function, 64));
            try jw.endObject();
        }

        if (frame_count > 0) {
            try jw.objectField("stack_trace");
            try jw.beginArray();
            for (state.stack_trace[0..frame_count]) |*frame| {
                try jw.beginObject();
                try jw.objectField("name");
                try jw.write(truncateStr(frame.name, 64));
                try jw.objectField("source");
                try jw.write(truncateStr(frame.source, 128));
                try jw.objectField("line");
                try jw.write(frame.line);
                try jw.endObject();
            }
            try jw.endArray();
        }

        if (local_count > 0) {
            try jw.objectField("locals");
            try jw.beginArray();
            for (state.locals[0..local_count]) |*v| {
                try jw.beginObject();
                try jw.objectField("name");
                try jw.write(truncateStr(v.name, 32));
                try jw.objectField("value");
                try jw.write(truncateStr(v.value, 64));
                try jw.objectField("type");
                try jw.write(truncateStr(v.type, 32));
                try jw.endObject();
            }
            try jw.endArray();
        }

        try jw.endObject();
        return try aw.toOwnedSlice();
    }

    /// Emit a stop event (richest event — carries stack trace + locals).
    fn emitStopEvent(self: *DebugServer, session_id: []const u8, action: []const u8, state: types.StopState) void {
        self.rememberDashboardStatus(session_id, "stopped");
        const event = self.buildStopEvent(self.allocator, session_id, action, state) catch |err| {
            debug_log.log("DebugServer.emitStopEvent: serialization failed: {s}", .{@errorName(err)});
            return;
        };
        defer self.allocator.free(event);
        _ = self.pushDashboardEvent(event);
    }

    fn buildStringEvent(self: *DebugServer, allocator: std.mem.Allocator, event_type: []const u8, fields: []const struct { name: []const u8, value: []const u8, max: usize }) ![]u8 {
        var aw: Writer.Allocating = .init(allocator);
        defer aw.deinit();
        var jw: Stringify = .{ .writer = &aw.writer };
        try jw.beginObject();
        try jw.objectField("type");
        try jw.write(event_type);
        try jw.objectField("source_id");
        try jw.write(&self.dashboard_source_id);
        for (fields) |field| {
            try jw.objectField(field.name);
            try jw.write(truncateStr(field.value, field.max));
        }
        try jw.endObject();
        return try aw.toOwnedSlice();
    }

    /// Emit an inspect event to the dashboard TUI.
    fn emitInspectEvent(self: *DebugServer, session_id: []const u8, expression: []const u8, result_str: []const u8, var_type: []const u8) void {
        const event = self.buildStringEvent(self.allocator, "inspect", &.{
            .{ .name = "session_id", .value = session_id, .max = 32 },
            .{ .name = "expression", .value = expression, .max = 100 },
            .{ .name = "result", .value = result_str, .max = 200 },
            .{ .name = "var_type", .value = var_type, .max = 64 },
        }) catch |err| {
            debug_log.log("DebugServer.emitInspectEvent: serialization failed: {s}", .{@errorName(err)});
            return;
        };
        defer self.allocator.free(event);
        _ = self.pushDashboardEvent(event);
    }

    /// Emit a session end event to the dashboard TUI.
    pub fn emitSessionEndEvent(self: *DebugServer, session_id: []const u8) bool {
        self.markDashboardSessionEnding(session_id);
        const event = self.buildStringEvent(self.allocator, "session_end", &.{
            .{ .name = "session_id", .value = session_id, .max = 32 },
        }) catch |err| {
            debug_log.log("DebugServer.emitSessionEndEvent: serialization failed: {s}", .{@errorName(err)});
            return false;
        };
        defer self.allocator.free(event);
        if (!self.pushDashboardEvent(event)) return false;
        self.forgetDashboardSession(session_id);
        return true;
    }

    /// Emit an error event to the dashboard TUI.
    fn emitErrorEvent(self: *DebugServer, session_id: []const u8, method: []const u8, message: []const u8) void {
        const event = self.buildStringEvent(self.allocator, "error", &.{
            .{ .name = "session_id", .value = session_id, .max = 32 },
            .{ .name = "method", .value = method, .max = 32 },
            .{ .name = "message", .value = message, .max = 200 },
        }) catch |err| {
            debug_log.log("DebugServer.emitErrorEvent: serialization failed: {s}", .{@errorName(err)});
            return;
        };
        defer self.allocator.free(event);
        _ = self.pushDashboardEvent(event);
    }

    /// Emit a generic activity event to the dashboard TUI.
    fn emitActivityEvent(self: *DebugServer, session_id: []const u8, tool: []const u8, summary: []const u8) void {
        const event = self.buildStringEvent(self.allocator, "activity", &.{
            .{ .name = "session_id", .value = session_id, .max = 32 },
            .{ .name = "tool", .value = tool, .max = 32 },
            .{ .name = "summary", .value = summary, .max = 200 },
        }) catch |err| {
            debug_log.log("DebugServer.emitActivityEvent: serialization failed: {s}", .{@errorName(err)});
            return;
        };
        defer self.allocator.free(event);
        _ = self.pushDashboardEvent(event);
    }

    /// Emit a run event (execution resumed, before stop).
    fn emitRunEvent(self: *DebugServer, session_id: []const u8, action: []const u8) void {
        self.rememberDashboardStatus(session_id, "running");
        const event = self.buildStringEvent(self.allocator, "run", &.{
            .{ .name = "session_id", .value = session_id, .max = 32 },
            .{ .name = "action", .value = action, .max = 32 },
        }) catch |err| {
            debug_log.log("DebugServer.emitRunEvent: serialization failed: {s}", .{@errorName(err)});
            return;
        };
        defer self.allocator.free(event);
        _ = self.pushDashboardEvent(event);
    }
};

const DashboardSessionState = struct {
    session_id: [32]u8 = undefined,
    session_id_len: usize = 0,
    program: [200]u8 = undefined,
    program_len: usize = 0,
    driver_type: [16]u8 = undefined,
    driver_type_len: usize = 0,
    status: [16]u8 = undefined,
    status_len: usize = 0,
    pending_end: bool = false,
    breakpoints: [MAX_DASHBOARD_BREAKPOINTS]DashboardBreakpointState = [_]DashboardBreakpointState{.{}} ** MAX_DASHBOARD_BREAKPOINTS,
    breakpoint_count: usize = 0,

    fn sessionIdSlice(self: *const DashboardSessionState) []const u8 {
        return self.session_id[0..self.session_id_len];
    }

    fn programSlice(self: *const DashboardSessionState) []const u8 {
        return self.program[0..self.program_len];
    }

    fn driverTypeSlice(self: *const DashboardSessionState) []const u8 {
        return self.driver_type[0..self.driver_type_len];
    }

    fn statusSlice(self: *const DashboardSessionState) []const u8 {
        return self.status[0..self.status_len];
    }
};

const DashboardBreakpointState = struct {
    id: u32 = 0,
    verified: bool = false,
    file: [200]u8 = undefined,
    file_len: usize = 0,
    line: u32 = 0,

    fn fileSlice(self: *const DashboardBreakpointState) []const u8 {
        return self.file[0..self.file_len];
    }
};

fn copyDashboardText(dest: []u8, len: *usize, src: []const u8) void {
    const copy_len = @min(dest.len, src.len);
    @memcpy(dest[0..copy_len], src[0..copy_len]);
    len.* = copy_len;
}

fn dashboardBackoffMs(failure_count: u8) i64 {
    if (failure_count == 0) return 0;
    const shift: u3 = @intCast(@min(failure_count - 1, 5));
    return @min(@as(i64, 250) << shift, 5000);
}

fn truncateStr(s: []const u8, max: usize) []const u8 {
    return if (s.len <= max) s else s[0..max];
}

/// Map common interpreter basenames to language hints for extension resolution.
/// Handles versioned names like "python3.11" or "node18" by stripping digits.
fn interpreterToLanguage(basename: []const u8) ?[]const u8 {
    // Strip trailing version digits (e.g. "python3.11" → "python", "node18" → "node")
    var name = basename;
    while (name.len > 0 and (name[name.len - 1] >= '0' and name[name.len - 1] <= '9' or name[name.len - 1] == '.')) {
        name = name[0 .. name.len - 1];
    }
    if (name.len == 0) name = basename;

    const map = .{
        .{ "python", "python" },
        .{ "node", "javascript" },
        .{ "java", "java" },
        .{ "go", "go" },
        .{ "ruby", "ruby" },
        .{ "perl", "perl" },
        .{ "cargo", "rust" },
        .{ "rustc", "rust" },
    };
    inline for (map) |entry| {
        if (std.mem.eql(u8, name, entry[0])) return entry[1];
    }
    return null;
}

// ── Tests ───────────────────────────────────────────────────────────────

test "dashboard event JSON escapes adversarial strings" {
    var server = DebugServer.init(std.testing.allocator);
    defer server.deinit();

    const event = try server.buildLaunchEvent(
        std.testing.allocator,
        "session-\"one\\two\nthree",
        "/tmp/\x1b[2J\"quoted\"\\program\nline",
        "native\tdebugger",
        "running",
    );
    defer std.testing.allocator.free(event);

    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, event, .{});
    defer parsed.deinit();

    try std.testing.expectEqualStrings("launch", parsed.value.object.get("type").?.string);
    try std.testing.expectEqualStrings("session-\"one\\two\nthree", parsed.value.object.get("session_id").?.string);
    try std.testing.expectEqualStrings("/tmp/\x1b[2J\"quoted\"\\program\nline", parsed.value.object.get("program").?.string);
    try std.testing.expectEqualStrings("native\tdebugger", parsed.value.object.get("driver").?.string);
    try std.testing.expectEqualStrings("running", parsed.value.object.get("status").?.string);
    try std.testing.expectEqualStrings(&server.dashboard_source_id, parsed.value.object.get("source_id").?.string);
    try std.testing.expect(std.mem.indexOfScalar(u8, event, '\n') == null);
    try std.testing.expect(std.mem.indexOfScalar(u8, event, 0x1b) == null);
}

test "dashboard send writes a complete JSON line" {
    var sockets: [2]std.c.fd_t = undefined;
    try std.testing.expectEqual(@as(c_int, 0), std.c.socketpair(posix.AF.UNIX, posix.SOCK.STREAM, 0, &sockets));
    defer posix.close(sockets[1]);

    var server = DebugServer.init(std.testing.allocator);
    defer server.deinit();
    server.dashboard_socket = sockets[0];

    try std.testing.expect(server.sendDashboardData("{\"type\":\"run\"}"));
    var received: [64]u8 = undefined;
    const count = try posix.read(sockets[1], &received);
    try std.testing.expectEqualStrings("{\"type\":\"run\"}\n", received[0..count]);
}

test "dashboard concurrent events remain complete NDJSON frames" {
    var sockets: [2]std.c.fd_t = undefined;
    try std.testing.expectEqual(@as(c_int, 0), std.c.socketpair(posix.AF.UNIX, posix.SOCK.STREAM, 0, &sockets));
    defer posix.close(sockets[1]);

    var server = DebugServer.init(std.testing.allocator);
    defer server.deinit();
    server.dashboard_socket = sockets[0];

    const Context = struct {
        server: *DebugServer,
        event: []const u8,
        delivered: bool = false,

        fn send(ctx: *@This()) void {
            ctx.delivered = ctx.server.pushDashboardEvent(ctx.event);
        }
    };
    var first = Context{ .server = &server, .event = "{\"type\":\"run\",\"session_id\":\"one\"}" };
    var second = Context{ .server = &server, .event = "{\"type\":\"run\",\"session_id\":\"two\"}" };
    const first_thread = try std.Thread.spawn(.{}, Context.send, .{&first});
    const second_thread = try std.Thread.spawn(.{}, Context.send, .{&second});
    first_thread.join();
    second_thread.join();
    try std.testing.expect(first.delivered);
    try std.testing.expect(second.delivered);

    var received: [256]u8 = undefined;
    var received_len: usize = 0;
    var newline_count: usize = 0;
    while (newline_count < 2) {
        const count = try posix.read(sockets[1], received[received_len..]);
        try std.testing.expect(count > 0);
        for (received[received_len .. received_len + count]) |byte| {
            if (byte == '\n') newline_count += 1;
        }
        received_len += count;
    }

    var lines = std.mem.splitScalar(u8, received[0..received_len], '\n');
    var parsed_count: usize = 0;
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, line, .{});
        defer parsed.deinit();
        try std.testing.expectEqualStrings("run", parsed.value.object.get("type").?.string);
        parsed_count += 1;
    }
    try std.testing.expectEqual(@as(usize, 2), parsed_count);
}

test "dashboard replay retains per-session status and breakpoint capacity" {
    var server = DebugServer.init(std.testing.allocator);
    defer server.deinit();
    server.rememberDashboardLaunch("session-1", "/tmp/app", "native", "running");

    for (0..32) |index| {
        server.rememberDashboardBreakpoint("session-1", "set", .{
            .id = @intCast(index + 1),
            .verified = false,
            .file = "/tmp/app.c",
            .line = @intCast(index + 1),
        });
    }
    server.rememberDashboardBreakpoint("session-1", "set", .{
        .id = 32,
        .verified = true,
        .file = "/tmp/updated.c",
        .line = 99,
    });

    try std.testing.expectEqual(@as(usize, 1), server.dashboard_session_count);
    try std.testing.expectEqualStrings("/tmp/app", server.dashboard_sessions[0].programSlice());
    try std.testing.expectEqualStrings("running", server.dashboard_sessions[0].statusSlice());
    try std.testing.expectEqual(@as(usize, 32), server.dashboard_sessions[0].breakpoint_count);
    try std.testing.expect(server.dashboard_sessions[0].breakpoints[31].verified);
    try std.testing.expectEqualStrings("/tmp/updated.c", server.dashboard_sessions[0].breakpoints[31].fileSlice());

    server.rememberDashboardBreakpoint("session-1", "remove", .{ .id = 32, .verified = false, .file = "", .line = 0 });
    server.forgetDashboardSession("session-1");
    try std.testing.expectEqual(@as(usize, 0), server.dashboard_session_count);
}

test "dashboard replay cache matches TUI session capacity" {
    var server = DebugServer.init(std.testing.allocator);
    defer server.deinit();

    for (0..16) |index| {
        var id_buf: [32]u8 = undefined;
        const id = try std.fmt.bufPrint(&id_buf, "session-{d}", .{index + 1});
        server.rememberDashboardLaunch(id, "/tmp/app", "native", "stopped");
        server.rememberDashboardBreakpoint(id, "set", .{
            .id = 1,
            .verified = true,
            .file = "/tmp/app.c",
            .line = 1,
        });
    }

    try std.testing.expectEqual(@as(usize, 16), server.dashboard_session_count);
    for (server.dashboard_sessions[0..server.dashboard_session_count]) |*session| {
        try std.testing.expectEqual(@as(usize, 1), session.breakpoint_count);
    }
}

test "dashboard session end state is retained until delivery" {
    var server = DebugServer.init(std.testing.allocator);
    defer server.deinit();
    server.rememberDashboardLaunch("session-1", "/tmp/app", "native", "stopped");
    server.dashboard_available = false;
    server.dashboard_failure_count = 1;
    server.last_dashboard_attempt_ms = std.time.milliTimestamp();

    try std.testing.expect(!server.emitSessionEndEvent("session-1"));
    try std.testing.expectEqual(@as(usize, 1), server.dashboard_session_count);
    try std.testing.expect(server.dashboard_sessions[0].pending_end);
}

test "dashboard replay delivers tombstones once and forgets them" {
    var sockets: [2]std.c.fd_t = undefined;
    try std.testing.expectEqual(@as(c_int, 0), std.c.socketpair(posix.AF.UNIX, posix.SOCK.STREAM, 0, &sockets));
    defer posix.close(sockets[1]);

    var server = DebugServer.init(std.testing.allocator);
    defer server.deinit();
    server.dashboard_socket = sockets[0];
    server.rememberDashboardLaunch("session-1", "/tmp/app", "native", "stopped");
    server.markDashboardSessionEnding("session-1");

    try std.testing.expect(server.replayDashboardState());
    try std.testing.expectEqual(@as(usize, 0), server.dashboard_session_count);
}

test "dashboard stop event stays within protocol frame limit" {
    var server = DebugServer.init(std.testing.allocator);
    defer server.deinit();
    const adversarial = [_]u8{0x1b} ** 512;
    const frames = [_]types.StackFrame{.{
        .id = 1,
        .name = &adversarial,
        .source = &adversarial,
        .line = 1,
    }} ** 32;
    const locals = [_]types.Variable{.{
        .name = &adversarial,
        .value = &adversarial,
        .type = &adversarial,
    }} ** 32;
    const state = types.StopState{
        .stop_reason = .breakpoint,
        .location = .{ .file = &adversarial, .line = 1, .function = &adversarial },
        .stack_trace = &frames,
        .locals = &locals,
    };

    const event = try server.buildStopEvent(std.testing.allocator, "session-1", "continue", state);
    defer std.testing.allocator.free(event);
    try std.testing.expect(event.len < 8192);
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, event, .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings("stop", parsed.value.object.get("type").?.string);
}

test "dashboard reconnect backoff grows and stays bounded" {
    try std.testing.expectEqual(@as(i64, 250), dashboardBackoffMs(1));
    try std.testing.expectEqual(@as(i64, 500), dashboardBackoffMs(2));
    try std.testing.expectEqual(@as(i64, 4000), dashboardBackoffMs(5));
    try std.testing.expectEqual(@as(i64, 5000), dashboardBackoffMs(20));
}

test "dashboard replay failures increase reconnect backoff" {
    var sockets: [2]std.c.fd_t = undefined;
    try std.testing.expectEqual(@as(c_int, 0), std.c.socketpair(posix.AF.UNIX, posix.SOCK.STREAM, 0, &sockets));

    var server = DebugServer.init(std.testing.allocator);
    defer server.deinit();
    server.dashboard_socket = sockets[0];
    server.rememberDashboardLaunch("session-1", "/tmp/app", "native", "stopped");
    posix.close(sockets[1]);

    try std.testing.expect(!server.pushDashboardEvent("{\"type\":\"run\"}"));
    try std.testing.expectEqual(@as(u8, 1), server.dashboard_failure_count);
    try std.testing.expectEqual(@as(i64, 250), dashboardBackoffMs(server.dashboard_failure_count));
}

test "tool_definitions has 36 entries" {
    try std.testing.expectEqual(@as(usize, 36), tool_definitions.len);
}

test "tool tier counts" {
    var core: usize = 0;
    var extended: usize = 0;
    var specialist: usize = 0;
    for (tool_definitions) |tool| {
        switch (tool.tier) {
            .core => core += 1,
            .extended => extended += 1,
            .specialist => specialist += 1,
        }
    }
    try std.testing.expectEqual(@as(usize, 7), core);
    try std.testing.expectEqual(@as(usize, 6), extended);
    try std.testing.expectEqual(@as(usize, 23), specialist);
}

test "ToolTier.isWithin" {
    try std.testing.expect(ToolTier.core.isWithin(.core));
    try std.testing.expect(ToolTier.core.isWithin(.extended));
    try std.testing.expect(ToolTier.core.isWithin(.specialist));
    try std.testing.expect(!ToolTier.extended.isWithin(.core));
    try std.testing.expect(ToolTier.extended.isWithin(.extended));
    try std.testing.expect(ToolTier.extended.isWithin(.specialist));
    try std.testing.expect(!ToolTier.specialist.isWithin(.core));
    try std.testing.expect(!ToolTier.specialist.isWithin(.extended));
    try std.testing.expect(ToolTier.specialist.isWithin(.specialist));
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

test "debug_stop returns unknown-session error" {
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
        .err => |err_result| {
            try std.testing.expectEqual(INVALID_PARAMS, err_result.code);
            try std.testing.expectEqualStrings("Unknown session", err_result.message);
        },
        .ok, .ok_static => unreachable,
    }
}

test "debug_stop terminate_only takes precedence over detach" {
    const allocator = std.testing.allocator;
    var srv = DebugServer.init(allocator);
    defer srv.deinit();

    var mock = driver_mod.MockDriver{};
    const session_id = try srv.session_manager.createSession(mock.activeDriver(), null, .none);
    srv.session_manager.getSession(session_id).?.status = .stopped;

    const args_parsed = try json.parseFromSlice(json.Value, allocator,
        \\{"session_id":"session-1","terminate_only":true,"detach":true}
    , .{});
    defer args_parsed.deinit();
    try expectStoppedResult(try srv.callTool(allocator, "debug_stop", args_parsed.value));

    try std.testing.expect(mock.terminated);
    try std.testing.expect(!mock.detached);
}

const BlockingRunCall = struct {
    server: *DebugServer,
    allocator: std.mem.Allocator,
    args: json.Value,
    result: ?ToolResult = null,
    finished: std.atomic.Value(bool) = .init(false),

    fn run(self: *BlockingRunCall) void {
        self.result = self.server.callTool(self.allocator, "debug_run", self.args) catch unreachable;
        self.finished.store(true, .release);
    }
};

const PollCall = struct {
    server: *DebugServer,
    allocator: std.mem.Allocator,
    args: json.Value,
    result: ?ToolResult = null,

    fn run(self: *PollCall) void {
        self.result = self.server.callTool(self.allocator, "debug_poll_events", self.args) catch unreachable;
    }
};

fn expectStoppedResult(result: ToolResult) !void {
    switch (result) {
        .ok => |raw| std.testing.allocator.free(raw),
        .ok_static => {},
        .err => |err_result| {
            std.debug.print("unexpected tool error: {d} {s}\n", .{ err_result.code, err_result.message });
            return error.UnexpectedToolError;
        },
    }
}

test "debug_stop during blocking run owns join and frees session once" {
    const allocator = std.testing.allocator;
    var srv = DebugServer.init(allocator);
    defer srv.deinit();

    var mock = driver_mod.MockDriver{};
    mock.setBlockRun(true);
    const session_id = try srv.session_manager.createSession(mock.activeDriver(), null, .none);
    srv.session_manager.getSession(session_id).?.status = .stopped;

    const run_args_parsed = try json.parseFromSlice(json.Value, allocator,
        \\{"session_id":"session-1","action":"continue","timeout_ms":30000}
    , .{});
    defer run_args_parsed.deinit();
    var run_call = BlockingRunCall{ .server = &srv, .allocator = allocator, .args = run_args_parsed.value };
    const run_thread = try std.Thread.spawn(.{}, BlockingRunCall.run, .{&run_call});
    defer run_thread.join();

    mock.waitForRunEntered();

    const stop_args_parsed = try json.parseFromSlice(json.Value, allocator,
        \\{"session_id":"session-1"}
    , .{});
    defer stop_args_parsed.deinit();
    try expectStoppedResult(try srv.callTool(allocator, "debug_stop", stop_args_parsed.value));

    while (!run_call.finished.load(.acquire)) std.Thread.sleep(std.time.ns_per_ms);
    try std.testing.expectEqual(@as(usize, 0), srv.session_manager.sessionCount());
    try std.testing.expect(mock.stopped);
    try std.testing.expect(mock.deinitialized);
    try std.testing.expect(!mock.terminated);
    try std.testing.expect(!mock.detached);

    if (run_call.result) |result| switch (result) {
        .ok => |raw| allocator.free(raw),
        .ok_static, .err => {},
    };
}

test "debug_stop preserves active terminate and detach semantics" {
    inline for (.{ false, true }) |detach_mode| {
        const allocator = std.testing.allocator;
        var srv = DebugServer.init(allocator);
        defer srv.deinit();

        var mock = driver_mod.MockDriver{};
        mock.setBlockRun(true);
        const session_id = try srv.session_manager.createSession(mock.activeDriver(), null, .none);
        srv.session_manager.getSession(session_id).?.status = .stopped;

        const run_args_parsed = try json.parseFromSlice(json.Value, allocator,
            \\{"session_id":"session-1","action":"continue","timeout_ms":0}
        , .{});
        defer run_args_parsed.deinit();
        const run_result = try srv.callTool(allocator, "debug_run", run_args_parsed.value);
        try expectStoppedResult(run_result);
        mock.waitForRunEntered();

        const stop_args = if (detach_mode)
            \\{"session_id":"session-1","detach":true}
        else
            \\{"session_id":"session-1","terminate_only":true}
        ;
        const stop_args_parsed = try json.parseFromSlice(json.Value, allocator, stop_args, .{});
        defer stop_args_parsed.deinit();
        try expectStoppedResult(try srv.callTool(allocator, "debug_stop", stop_args_parsed.value));

        try std.testing.expectEqual(detach_mode, mock.detached);
        try std.testing.expectEqual(!detach_mode, mock.terminated);
        try std.testing.expect(!mock.stopped);
        try std.testing.expect(!mock.sync_lifecycle_while_run_active);
        try std.testing.expect(mock.deinitialized);
    }
}

test "debug_poll_events refreshes intentional session activity" {
    const allocator = std.testing.allocator;
    var srv = DebugServer.init(allocator);
    defer srv.deinit();

    var mock1 = driver_mod.MockDriver{};
    var mock2 = driver_mod.MockDriver{};
    const session_id1 = try srv.session_manager.createSession(mock1.activeDriver(), null, .none);
    const session_id2 = try srv.session_manager.createSession(mock2.activeDriver(), null, .none);
    const session1 = srv.session_manager.sessions.get(session_id1).?;
    const session2 = srv.session_manager.sessions.get(session_id2).?;

    const stale = std.time.milliTimestamp() - 10_000;
    session1.last_activity = stale;
    session2.last_activity = stale;

    const filtered_args = try json.parseFromSlice(json.Value, allocator,
        \\{"session_id":"session-1"}
    , .{});
    defer filtered_args.deinit();
    try expectStoppedResult(try srv.callTool(allocator, "debug_poll_events", filtered_args.value));

    try std.testing.expect(session1.last_activity > stale);
    try std.testing.expectEqual(stale, session2.last_activity);

    session1.last_activity = stale;
    try expectStoppedResult(try srv.callTool(allocator, "debug_poll_events", null));

    try std.testing.expect(session1.last_activity > stale);
    try std.testing.expect(session2.last_activity > stale);
}

test "debug_poll_events exposes driver queue and drop diagnostics" {
    const allocator = std.testing.allocator;
    var srv = DebugServer.init(allocator);
    defer srv.deinit();

    var mock = driver_mod.MockDriver{};
    mock.diagnostics = .{
        .pending_notifications = 3,
        .dropped_notifications = 4,
        .buffered_events = 5,
        .dropped_buffered_events = 6,
        .output_entries = 7,
        .dropped_output_entries = 8,
        .rejected_line_breakpoints = 9,
    };
    _ = try srv.session_manager.createSession(mock.activeDriver(), null, .none);

    const result = try srv.callTool(allocator, "debug_poll_events", null);
    const raw = switch (result) {
        .ok => |value| value,
        .ok_static => return error.UnexpectedStaticResult,
        .err => return error.UnexpectedToolError,
    };
    defer allocator.free(raw);

    const parsed = try json.parseFromSlice(json.Value, allocator, raw, .{});
    defer parsed.deinit();
    const diagnostics = parsed.value.object.get("diagnostics").?.array;
    try std.testing.expectEqual(@as(usize, 1), diagnostics.items.len);
    const entry = diagnostics.items[0].object;
    try std.testing.expectEqualStrings("session-1", entry.get("session_id").?.string);
    try std.testing.expectEqualStrings("dap", entry.get("driver").?.string);
    const counters = entry.get("counters").?.object;
    try std.testing.expectEqual(@as(i64, 3), counters.get("pending_notifications").?.integer);
    try std.testing.expectEqual(@as(i64, 4), counters.get("dropped_notifications").?.integer);
    try std.testing.expectEqual(@as(i64, 5), counters.get("buffered_events").?.integer);
    try std.testing.expectEqual(@as(i64, 6), counters.get("dropped_buffered_events").?.integer);
    try std.testing.expectEqual(@as(i64, 7), counters.get("output_entries").?.integer);
    try std.testing.expectEqual(@as(i64, 8), counters.get("dropped_output_entries").?.integer);
    try std.testing.expectEqual(@as(i64, 9), counters.get("rejected_line_breakpoints").?.integer);
}

test "debug_poll_events does not consume synchronous run completion" {
    const allocator = std.testing.allocator;
    var srv = DebugServer.init(allocator);
    defer srv.deinit();

    var mock = driver_mod.MockDriver{};
    mock.setBlockRun(true);
    const session_id = try srv.session_manager.createSession(mock.activeDriver(), null, .none);
    srv.session_manager.getSession(session_id).?.status = .stopped;

    const run_args = try json.parseFromSlice(json.Value, allocator,
        \\{"session_id":"session-1","action":"continue","timeout_ms":30000}
    , .{});
    defer run_args.deinit();
    var run_call = BlockingRunCall{ .server = &srv, .allocator = allocator, .args = run_args.value };
    const run_thread = try std.Thread.spawn(.{}, BlockingRunCall.run, .{&run_call});
    defer run_thread.join();
    mock.waitForRunEntered();

    const poll_args = try json.parseFromSlice(json.Value, allocator,
        \\{"session_id":"session-1"}
    , .{});
    defer poll_args.deinit();
    var poll_call = PollCall{ .server = &srv, .allocator = allocator, .args = poll_args.value };
    const poll_thread = try std.Thread.spawn(.{}, PollCall.run, .{&poll_call});

    mock.releaseRun();
    poll_thread.join();
    while (!run_call.finished.load(.acquire)) std.Thread.sleep(std.time.ns_per_ms);

    if (poll_call.result) |result| try expectStoppedResult(result);
    if (run_call.result) |result| switch (result) {
        .ok => |raw| allocator.free(raw),
        .ok_static => {},
        .err => return error.UnexpectedToolError,
    };
    try std.testing.expect(srv.session_manager.getSession(session_id).?.pending_run == null);
}

test "debug_run lifecycle fixture is stable across repeated active stops" {
    const allocator = std.testing.allocator;
    var srv = DebugServer.init(allocator);
    defer srv.deinit();

    var mocks: [25]driver_mod.MockDriver = [_]driver_mod.MockDriver{.{}} ** 25;
    for (&mocks, 0..) |*mock, i| {
        mock.setBlockRun(true);
        const session_id = try srv.session_manager.createSession(mock.activeDriver(), null, .none);
        srv.session_manager.getSession(session_id).?.status = .stopped;

        const run_args_text = try std.fmt.allocPrint(allocator, "{{\"session_id\":\"session-{d}\",\"action\":\"continue\",\"timeout_ms\":0}}", .{i + 1});
        defer allocator.free(run_args_text);
        const run_args = try json.parseFromSlice(json.Value, allocator, run_args_text, .{});
        defer run_args.deinit();
        try expectStoppedResult(try srv.callTool(allocator, "debug_run", run_args.value));
        mock.waitForRunEntered();

        const stop_args_text = try std.fmt.allocPrint(allocator, "{{\"session_id\":\"session-{d}\"}}", .{i + 1});
        defer allocator.free(stop_args_text);
        const stop_args = try json.parseFromSlice(json.Value, allocator, stop_args_text, .{});
        defer stop_args.deinit();
        try expectStoppedResult(try srv.callTool(allocator, "debug_stop", stop_args.value));

        try std.testing.expect(mock.stopped);
        try std.testing.expect(mock.deinitialized);
        try std.testing.expectEqual(@as(usize, 0), srv.session_manager.sessionCount());
    }
}

test "debug_run timeout pauses then deterministically joins completed run" {
    const allocator = std.testing.allocator;
    var srv = DebugServer.init(allocator);
    defer srv.deinit();

    var mock = driver_mod.MockDriver{};
    mock.setBlockRun(true);
    const session_id = try srv.session_manager.createSession(mock.activeDriver(), null, .none);
    srv.session_manager.getSession(session_id).?.status = .stopped;

    const run_args_parsed = try json.parseFromSlice(json.Value, allocator,
        \\{"session_id":"session-1","action":"continue","timeout_ms":1}
    , .{});
    defer run_args_parsed.deinit();
    const result = try srv.callTool(allocator, "debug_run", run_args_parsed.value);
    try expectStoppedResult(result);

    try std.testing.expect(mock.paused or mock.cancelled);
    const session = srv.session_manager.getSession(session_id).?;
    try std.testing.expect(session.pending_run == null);
    try std.testing.expectEqual(session_mod.Session.Status.stopped, session.status);
}

test "debug_run timeout remains bounded when pause does not complete run" {
    const allocator = std.testing.allocator;
    var srv = DebugServer.init(allocator);
    defer srv.deinit();

    var mock = driver_mod.MockDriver{};
    mock.setBlockRun(true);
    mock.setPauseReleasesRun(false);
    const session_id = try srv.session_manager.createSession(mock.activeDriver(), null, .none);
    srv.session_manager.getSession(session_id).?.status = .stopped;

    const run_args_parsed = try json.parseFromSlice(json.Value, allocator,
        \\{"session_id":"session-1","action":"continue","timeout_ms":1}
    , .{});
    defer run_args_parsed.deinit();
    const before = std.time.milliTimestamp();
    const result = try srv.callTool(allocator, "debug_run", run_args_parsed.value);
    const elapsed = std.time.milliTimestamp() - before;
    try expectStoppedResult(result);

    try std.testing.expect(elapsed < 1000);
    try std.testing.expect(mock.paused);
    try std.testing.expect(mock.cancelled);
    const session = srv.session_manager.getSession(session_id).?;
    try std.testing.expect(session.pending_run == null);
    try std.testing.expectEqual(session_mod.Session.Status.stopped, session.status);
}

test "tool schema for debug_launch has program and module fields" {
    const schema = try json.parseFromSlice(json.Value, std.testing.allocator, debug_launch_schema, .{});
    defer schema.deinit();
    const obj = schema.value.object;

    try std.testing.expectEqualStrings("object", obj.get("type").?.string);
    const props = obj.get("properties").?.object;
    // Both program and module should be defined (either can be used)
    try std.testing.expect(props.get("program") != null);
    try std.testing.expect(props.get("module") != null);
    // No required array — either program or module suffices
    try std.testing.expect(obj.get("required") == null);
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
