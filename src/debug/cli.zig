const std = @import("std");
const json = std.json;
const Stringify = json.Stringify;
const Writer = std.io.Writer;
const posix = std.posix;
const daemon_mod = @import("daemon.zig");

// ── Arg Schema Types ────────────────────────────────────────────────────

const ArgKind = enum {
    positional_string, // next positional → string field
    positional_int, // next positional → integer field
    positional_file_line, // "path:N" → sets file + line fields
    flag_string, // --name value → string field
    flag_string_list, // --name a,b → string array field (comma-separated)
    flag_int, // --name N → integer field
    flag_bool, // --name → true
    collect_strings, // remaining positionals → string array
    collect_ints, // remaining positionals → int array
};

const ArgDef = struct {
    kind: ArgKind,
    flag: ?[]const u8, // null for positionals, "--session" for flags
    json_name: []const u8, // primary JSON field
    json_name2: ?[]const u8 = null, // secondary field (file_line uses this for "line")
    description: []const u8,
};

// ── CLI Tool Definition Table ───────────────────────────────────────────

const CliToolDef = struct {
    cli_name: []const u8, // short name: "launch", "breakpoint_set"
    server_tool: []const u8, // daemon tool: "debug_launch"
    inject_action: ?[]const u8, // auto-injected action field
    description: []const u8,
    args: []const ArgDef,
};

const cli_tools = [_]CliToolDef{
    // ── Core ────────────────────────────────────────────────────────────
    .{
        .cli_name = "launch",
        .server_tool = "debug_launch",
        .inject_action = null,
        .description = "Launch a program under the debugger",
        .args = &.{
            .{ .kind = .positional_string, .flag = null, .json_name = "program", .description = "Path to executable" },
            .{ .kind = .flag_string, .flag = "--cwd", .json_name = "cwd", .description = "Working directory" },
            .{ .kind = .flag_string, .flag = "--language", .json_name = "language", .description = "Language hint (c, zig, etc.)" },
            .{ .kind = .flag_int, .flag = "--owner-pid", .json_name = "client_pid", .description = "Owner PID for orphan cleanup" },
            .{ .kind = .flag_bool, .flag = "--stop-on-entry", .json_name = "stop_on_entry", .description = "Stop at program entry point" },
            .{ .kind = .collect_strings, .flag = null, .json_name = "args", .description = "Program arguments (after --)" },
        },
    },
    .{
        .cli_name = "stop",
        .server_tool = "debug_stop",
        .inject_action = null,
        .description = "Stop a debug session",
        .args = &.{
            .{ .kind = .flag_string, .flag = "--session", .json_name = "session_id", .description = "Session ID" },
            .{ .kind = .flag_bool, .flag = "--terminate-only", .json_name = "terminate_only", .description = "Terminate without cleanup" },
            .{ .kind = .flag_bool, .flag = "--detach", .json_name = "detach", .description = "Detach instead of terminate" },
        },
    },
    .{
        .cli_name = "attach",
        .server_tool = "debug_attach",
        .inject_action = null,
        .description = "Attach to a running process",
        .args = &.{
            .{ .kind = .positional_int, .flag = null, .json_name = "pid", .description = "Process ID" },
            .{ .kind = .flag_string, .flag = "--language", .json_name = "language", .description = "Language hint" },
            .{ .kind = .flag_int, .flag = "--owner-pid", .json_name = "client_pid", .description = "Owner PID for orphan cleanup" },
        },
    },
    .{
        .cli_name = "restart",
        .server_tool = "debug_restart",
        .inject_action = null,
        .description = "Restart the debug session",
        .args = &.{
            .{ .kind = .flag_string, .flag = "--session", .json_name = "session_id", .description = "Session ID" },
        },
    },
    .{
        .cli_name = "sessions",
        .server_tool = "debug_sessions",
        .inject_action = null,
        .description = "List all active debug sessions",
        .args = &.{},
    },
    // ── Breakpoints ─────────────────────────────────────────────────────
    .{
        .cli_name = "breakpoint_set",
        .server_tool = "debug_breakpoint",
        .inject_action = "set",
        .description = "Set a line breakpoint",
        .args = &.{
            .{ .kind = .positional_file_line, .flag = null, .json_name = "file", .json_name2 = "line", .description = "file:line (e.g. src/main.c:42)" },
            .{ .kind = .flag_string, .flag = "--session", .json_name = "session_id", .description = "Session ID" },
            .{ .kind = .flag_string, .flag = "--condition", .json_name = "condition", .description = "Conditional expression" },
            .{ .kind = .flag_string, .flag = "--hit-condition", .json_name = "hit_condition", .description = "Hit count condition" },
            .{ .kind = .flag_string, .flag = "--log-message", .json_name = "log_message", .description = "Log message (logpoint)" },
        },
    },
    .{
        .cli_name = "breakpoint_set_function",
        .server_tool = "debug_breakpoint",
        .inject_action = "set_function",
        .description = "Set a function breakpoint",
        .args = &.{
            .{ .kind = .positional_string, .flag = null, .json_name = "function", .description = "Function name" },
            .{ .kind = .flag_string, .flag = "--session", .json_name = "session_id", .description = "Session ID" },
        },
    },
    .{
        .cli_name = "breakpoint_set_exception",
        .server_tool = "debug_breakpoint",
        .inject_action = "set_exception",
        .description = "Set an exception breakpoint",
        .args = &.{
            .{ .kind = .flag_string, .flag = "--session", .json_name = "session_id", .description = "Session ID" },
            .{ .kind = .flag_string_list, .flag = "--filters", .json_name = "filters", .description = "Exception filters (comma-separated)" },
        },
    },
    .{
        .cli_name = "breakpoint_remove",
        .server_tool = "debug_breakpoint",
        .inject_action = "remove",
        .description = "Remove a breakpoint",
        .args = &.{
            .{ .kind = .positional_int, .flag = null, .json_name = "id", .description = "Breakpoint ID" },
            .{ .kind = .flag_string, .flag = "--session", .json_name = "session_id", .description = "Session ID" },
        },
    },
    .{
        .cli_name = "breakpoint_list",
        .server_tool = "debug_breakpoint",
        .inject_action = "list",
        .description = "List all breakpoints",
        .args = &.{
            .{ .kind = .flag_string, .flag = "--session", .json_name = "session_id", .description = "Session ID" },
        },
    },
    .{
        .cli_name = "breakpoint_locations",
        .server_tool = "debug_breakpoint_locations",
        .inject_action = null,
        .description = "Query valid breakpoint positions",
        .args = &.{
            .{ .kind = .positional_file_line, .flag = null, .json_name = "source", .json_name2 = "line", .description = "source:line" },
            .{ .kind = .flag_string, .flag = "--session", .json_name = "session_id", .description = "Session ID" },
            .{ .kind = .flag_int, .flag = "--end-line", .json_name = "end_line", .description = "End line for range query" },
        },
    },
    .{
        .cli_name = "instruction_breakpoint",
        .server_tool = "debug_instruction_breakpoint",
        .inject_action = null,
        .description = "Set instruction-level breakpoints",
        .args = &.{
            .{ .kind = .positional_string, .flag = null, .json_name = "instruction_reference", .description = "Instruction address (e.g. 0x100003f00)" },
            .{ .kind = .flag_string, .flag = "--session", .json_name = "session_id", .description = "Session ID" },
            .{ .kind = .flag_int, .flag = "--offset", .json_name = "offset", .description = "Byte offset from reference" },
            .{ .kind = .flag_string, .flag = "--condition", .json_name = "condition", .description = "Conditional expression" },
            .{ .kind = .flag_string, .flag = "--hit-condition", .json_name = "hit_condition", .description = "Hit count condition" },
        },
    },
    .{
        .cli_name = "watchpoint",
        .server_tool = "debug_watchpoint",
        .inject_action = null,
        .description = "Set a data breakpoint",
        .args = &.{
            .{ .kind = .positional_string, .flag = null, .json_name = "variable", .description = "Variable name" },
            .{ .kind = .flag_string, .flag = "--session", .json_name = "session_id", .description = "Session ID" },
            .{ .kind = .flag_string, .flag = "--access-type", .json_name = "access_type", .description = "read, write, or readWrite" },
            .{ .kind = .flag_int, .flag = "--frame", .json_name = "frame_id", .description = "Frame ID" },
        },
    },
    // ── Execution ───────────────────────────────────────────────────────
    .{
        .cli_name = "run",
        .server_tool = "debug_run",
        .inject_action = null,
        .description = "Continue, step, or restart execution",
        .args = &.{
            .{ .kind = .positional_string, .flag = null, .json_name = "action", .description = "continue, step_into, step_over, step_out, pause, goto, restart" },
            .{ .kind = .flag_string, .flag = "--session", .json_name = "session_id", .description = "Session ID" },
            .{ .kind = .flag_string, .flag = "--file", .json_name = "file", .description = "File for goto target" },
            .{ .kind = .flag_int, .flag = "--line", .json_name = "line", .description = "Line for goto target" },
            .{ .kind = .flag_string, .flag = "--granularity", .json_name = "granularity", .description = "statement, line, or instruction" },
        },
    },
    .{
        .cli_name = "goto_targets",
        .server_tool = "debug_goto_targets",
        .inject_action = null,
        .description = "Discover goto target locations",
        .args = &.{
            .{ .kind = .positional_file_line, .flag = null, .json_name = "file", .json_name2 = "line", .description = "file:line" },
            .{ .kind = .flag_string, .flag = "--session", .json_name = "session_id", .description = "Session ID" },
        },
    },
    .{
        .cli_name = "step_in_targets",
        .server_tool = "debug_step_in_targets",
        .inject_action = null,
        .description = "List step-in targets",
        .args = &.{
            .{ .kind = .flag_string, .flag = "--session", .json_name = "session_id", .description = "Session ID" },
            .{ .kind = .flag_int, .flag = "--frame", .json_name = "frame_id", .description = "Frame ID" },
        },
    },
    .{
        .cli_name = "restart_frame",
        .server_tool = "debug_restart_frame",
        .inject_action = null,
        .description = "Restart from a stack frame",
        .args = &.{
            .{ .kind = .flag_string, .flag = "--session", .json_name = "session_id", .description = "Session ID" },
            .{ .kind = .flag_int, .flag = "--frame", .json_name = "frame_id", .description = "Frame ID" },
        },
    },
    // ── Inspection ──────────────────────────────────────────────────────
    .{
        .cli_name = "inspect",
        .server_tool = "debug_inspect",
        .inject_action = null,
        .description = "Evaluate expressions and inspect variables",
        .args = &.{
            .{ .kind = .positional_string, .flag = null, .json_name = "expression", .description = "Expression to evaluate" },
            .{ .kind = .flag_string, .flag = "--session", .json_name = "session_id", .description = "Session ID" },
            .{ .kind = .flag_int, .flag = "--frame", .json_name = "frame_id", .description = "Frame ID" },
            .{ .kind = .flag_string, .flag = "--scope", .json_name = "scope", .description = "Variable scope (locals, globals, arguments)" },
            .{ .kind = .flag_string, .flag = "--context", .json_name = "context", .description = "Evaluation context (watch, repl, hover)" },
            .{ .kind = .flag_int, .flag = "--variable-ref", .json_name = "variable_ref", .description = "Variable reference for expansion" },
        },
    },
    .{
        .cli_name = "set_variable",
        .server_tool = "debug_set_variable",
        .inject_action = null,
        .description = "Set the value of a variable",
        .args = &.{
            .{ .kind = .positional_string, .flag = null, .json_name = "variable", .description = "Variable name" },
            .{ .kind = .positional_string, .flag = null, .json_name = "value", .description = "New value" },
            .{ .kind = .flag_string, .flag = "--session", .json_name = "session_id", .description = "Session ID" },
            .{ .kind = .flag_int, .flag = "--frame", .json_name = "frame_id", .description = "Frame ID" },
        },
    },
    .{
        .cli_name = "set_expression",
        .server_tool = "debug_set_expression",
        .inject_action = null,
        .description = "Evaluate and assign an expression",
        .args = &.{
            .{ .kind = .positional_string, .flag = null, .json_name = "expression", .description = "Expression" },
            .{ .kind = .positional_string, .flag = null, .json_name = "value", .description = "New value" },
            .{ .kind = .flag_string, .flag = "--session", .json_name = "session_id", .description = "Session ID" },
            .{ .kind = .flag_int, .flag = "--frame", .json_name = "frame_id", .description = "Frame ID" },
        },
    },
    // ── Threads and Stack ───────────────────────────────────────────────
    .{
        .cli_name = "threads",
        .server_tool = "debug_threads",
        .inject_action = null,
        .description = "List threads",
        .args = &.{
            .{ .kind = .flag_string, .flag = "--session", .json_name = "session_id", .description = "Session ID" },
        },
    },
    .{
        .cli_name = "stacktrace",
        .server_tool = "debug_stacktrace",
        .inject_action = null,
        .description = "Get stack trace for a thread",
        .args = &.{
            .{ .kind = .flag_string, .flag = "--session", .json_name = "session_id", .description = "Session ID" },
            .{ .kind = .flag_int, .flag = "--thread", .json_name = "thread_id", .description = "Thread ID" },
            .{ .kind = .flag_int, .flag = "--start-frame", .json_name = "start_frame", .description = "Start frame index" },
            .{ .kind = .flag_int, .flag = "--levels", .json_name = "levels", .description = "Number of frames to return" },
        },
    },
    .{
        .cli_name = "scopes",
        .server_tool = "debug_scopes",
        .inject_action = null,
        .description = "List variable scopes for a frame",
        .args = &.{
            .{ .kind = .flag_string, .flag = "--session", .json_name = "session_id", .description = "Session ID" },
            .{ .kind = .flag_int, .flag = "--frame", .json_name = "frame_id", .description = "Frame ID" },
        },
    },
    .{
        .cli_name = "variable_location",
        .server_tool = "debug_variable_location",
        .inject_action = null,
        .description = "Get variable storage location",
        .args = &.{
            .{ .kind = .positional_string, .flag = null, .json_name = "name", .description = "Variable name" },
            .{ .kind = .flag_string, .flag = "--session", .json_name = "session_id", .description = "Session ID" },
            .{ .kind = .flag_int, .flag = "--frame", .json_name = "frame_id", .description = "Frame ID" },
        },
    },
    // ── Memory and Low-Level ────────────────────────────────────────────
    .{
        .cli_name = "memory",
        .server_tool = "debug_memory",
        .inject_action = null,
        .description = "Read or write process memory",
        .args = &.{
            .{ .kind = .positional_string, .flag = null, .json_name = "action", .description = "read or write" },
            .{ .kind = .positional_string, .flag = null, .json_name = "address", .description = "Memory address (e.g. 0x1000)" },
            .{ .kind = .flag_string, .flag = "--session", .json_name = "session_id", .description = "Session ID" },
            .{ .kind = .flag_int, .flag = "--size", .json_name = "size", .description = "Number of bytes to read" },
            .{ .kind = .flag_string, .flag = "--data", .json_name = "data", .description = "Hex data to write" },
            .{ .kind = .flag_int, .flag = "--offset", .json_name = "offset", .description = "Byte offset" },
        },
    },
    .{
        .cli_name = "disassemble",
        .server_tool = "debug_disassemble",
        .inject_action = null,
        .description = "Disassemble instructions",
        .args = &.{
            .{ .kind = .positional_string, .flag = null, .json_name = "address", .description = "Start address" },
            .{ .kind = .flag_string, .flag = "--session", .json_name = "session_id", .description = "Session ID" },
            .{ .kind = .flag_int, .flag = "--count", .json_name = "instruction_count", .description = "Number of instructions" },
            .{ .kind = .flag_int, .flag = "--offset", .json_name = "offset", .description = "Byte offset" },
            .{ .kind = .flag_bool, .flag = "--no-symbols", .json_name = "resolve_symbols", .description = "Disable symbol resolution" },
        },
    },
    .{
        .cli_name = "registers",
        .server_tool = "debug_registers",
        .inject_action = null,
        .description = "Read CPU register values",
        .args = &.{
            .{ .kind = .flag_string, .flag = "--session", .json_name = "session_id", .description = "Session ID" },
            .{ .kind = .flag_int, .flag = "--thread", .json_name = "thread_id", .description = "Thread ID" },
        },
    },
    .{
        .cli_name = "write_register",
        .server_tool = "debug_write_register",
        .inject_action = null,
        .description = "Write a CPU register value",
        .args = &.{
            .{ .kind = .positional_string, .flag = null, .json_name = "name", .description = "Register name" },
            .{ .kind = .positional_int, .flag = null, .json_name = "value", .description = "Value to write" },
            .{ .kind = .flag_string, .flag = "--session", .json_name = "session_id", .description = "Session ID" },
            .{ .kind = .flag_int, .flag = "--thread", .json_name = "thread_id", .description = "Thread ID" },
        },
    },
    .{
        .cli_name = "find_symbol",
        .server_tool = "debug_find_symbol",
        .inject_action = null,
        .description = "Search for symbol definitions",
        .args = &.{
            .{ .kind = .positional_string, .flag = null, .json_name = "name", .description = "Symbol name" },
            .{ .kind = .flag_string, .flag = "--session", .json_name = "session_id", .description = "Session ID" },
        },
    },
    // ── Capabilities and Introspection ──────────────────────────────────
    .{
        .cli_name = "capabilities",
        .server_tool = "debug_capabilities",
        .inject_action = null,
        .description = "Query driver capabilities",
        .args = &.{
            .{ .kind = .flag_string, .flag = "--session", .json_name = "session_id", .description = "Session ID" },
        },
    },
    .{
        .cli_name = "modules",
        .server_tool = "debug_modules",
        .inject_action = null,
        .description = "List loaded modules",
        .args = &.{
            .{ .kind = .flag_string, .flag = "--session", .json_name = "session_id", .description = "Session ID" },
        },
    },
    .{
        .cli_name = "loaded_sources",
        .server_tool = "debug_loaded_sources",
        .inject_action = null,
        .description = "List available source files",
        .args = &.{
            .{ .kind = .flag_string, .flag = "--session", .json_name = "session_id", .description = "Session ID" },
        },
    },
    .{
        .cli_name = "source",
        .server_tool = "debug_source",
        .inject_action = null,
        .description = "Retrieve source code",
        .args = &.{
            .{ .kind = .positional_int, .flag = null, .json_name = "source_reference", .description = "Source reference ID" },
            .{ .kind = .flag_string, .flag = "--session", .json_name = "session_id", .description = "Session ID" },
        },
    },
    .{
        .cli_name = "completions",
        .server_tool = "debug_completions",
        .inject_action = null,
        .description = "Get expression completions",
        .args = &.{
            .{ .kind = .positional_string, .flag = null, .json_name = "text", .description = "Text to complete" },
            .{ .kind = .flag_string, .flag = "--session", .json_name = "session_id", .description = "Session ID" },
            .{ .kind = .flag_int, .flag = "--column", .json_name = "column", .description = "Cursor column" },
            .{ .kind = .flag_int, .flag = "--frame", .json_name = "frame_id", .description = "Frame ID" },
        },
    },
    // ── Exception and Events ────────────────────────────────────────────
    .{
        .cli_name = "exception_info",
        .server_tool = "debug_exception_info",
        .inject_action = null,
        .description = "Get exception information",
        .args = &.{
            .{ .kind = .flag_string, .flag = "--session", .json_name = "session_id", .description = "Session ID" },
            .{ .kind = .flag_int, .flag = "--thread", .json_name = "thread_id", .description = "Thread ID" },
        },
    },
    .{
        .cli_name = "poll_events",
        .server_tool = "debug_poll_events",
        .inject_action = null,
        .description = "Poll for debug events",
        .args = &.{
            .{ .kind = .flag_string, .flag = "--session", .json_name = "session_id", .description = "Session ID" },
        },
    },
    // ── Cancellation ────────────────────────────────────────────────────
    .{
        .cli_name = "cancel",
        .server_tool = "debug_cancel",
        .inject_action = null,
        .description = "Cancel a pending request",
        .args = &.{
            .{ .kind = .flag_string, .flag = "--session", .json_name = "session_id", .description = "Session ID" },
            .{ .kind = .flag_int, .flag = "--request-id", .json_name = "request_id", .description = "Request ID to cancel" },
            .{ .kind = .flag_string, .flag = "--progress-id", .json_name = "progress_id", .description = "Progress token to cancel" },
        },
    },
    .{
        .cli_name = "terminate_threads",
        .server_tool = "debug_terminate_threads",
        .inject_action = null,
        .description = "Terminate specific threads",
        .args = &.{
            .{ .kind = .flag_string, .flag = "--session", .json_name = "session_id", .description = "Session ID" },
            .{ .kind = .collect_ints, .flag = null, .json_name = "thread_ids", .description = "Thread IDs to terminate" },
        },
    },
    // ── Core Dump & DAP Passthrough ────────────────────────────────────
    .{
        .cli_name = "load_core",
        .server_tool = "debug_load_core",
        .inject_action = null,
        .description = "Load a core dump for post-mortem debugging",
        .args = &.{
            .{ .kind = .positional_string, .flag = null, .json_name = "core_path", .description = "Path to core dump file" },
            .{ .kind = .flag_string, .flag = "--executable", .json_name = "executable", .description = "Path to executable" },
            .{ .kind = .flag_int, .flag = "--owner-pid", .json_name = "client_pid", .description = "Owner PID for orphan cleanup" },
        },
    },
    .{
        .cli_name = "dap_request",
        .server_tool = "debug_dap_request",
        .inject_action = null,
        .description = "Send a raw DAP request (DAP sessions only)",
        .args = &.{
            .{ .kind = .positional_string, .flag = null, .json_name = "command", .description = "DAP command name" },
            .{ .kind = .flag_string, .flag = "--session", .json_name = "session_id", .description = "Session ID" },
            .{ .kind = .flag_string, .flag = "--args", .json_name = "arguments", .description = "JSON arguments" },
        },
    },
};

// ── CLI Dispatch ────────────────────────────────────────────────────────

pub fn dispatch(allocator: std.mem.Allocator, args: []const [:0]const u8) !void {
    // No args or --help → print tool list
    if (args.len == 0 or (args.len == 1 and (std.mem.eql(u8, args[0], "--help") or std.mem.eql(u8, args[0], "-h")))) {
        printSendHelp();
        return;
    }

    const tool_name: []const u8 = args[0];

    // <tool> --help → per-tool help
    if (args.len >= 2 and (std.mem.eql(u8, args[1], "--help") or std.mem.eql(u8, args[1], "-h"))) {
        const def = findTool(tool_name) orelse {
            printErr("error: unknown tool '");
            printErr(tool_name);
            printErr("'\nRun 'cog debug/send --help' to list all tools.\n");
            return error.Explained;
        };
        printToolHelp(def);
        return;
    }

    // Find the tool
    const def = findTool(tool_name) orelse {
        printErr("error: unknown tool '");
        printErr(tool_name);
        printErr("'\nRun 'cog debug/send --help' to list all tools.\n");
        return error.Explained;
    };

    // Parse args and build request JSON
    const request = parseAndBuildRequest(allocator, def, args[1..]) catch |err| switch (err) {
        error.Explained => return error.Explained,
        else => {
            printErr("error: failed to build request\n");
            return error.Explained;
        },
    };
    defer allocator.free(request);

    // Connect to daemon and send
    sendRequest(allocator, request);
}

// ── Arg Parser ──────────────────────────────────────────────────────────

fn parseAndBuildRequest(allocator: std.mem.Allocator, def: *const CliToolDef, args: []const [:0]const u8) ![]const u8 {
    var aw: Writer.Allocating = .init(allocator);
    defer aw.deinit();
    var jw: Stringify = .{ .writer = &aw.writer };

    try jw.beginObject();
    try jw.objectField("tool");
    try jw.write(def.server_tool);
    try jw.objectField("args");
    try jw.beginObject();

    // Inject action field if needed
    if (def.inject_action) |action| {
        try jw.objectField("action");
        try jw.write(action);
    }

    // Separate flags from positionals
    var positionals = std.ArrayListUnmanaged([]const u8).empty;
    defer positionals.deinit(allocator);
    var flag_values = std.StringHashMapUnmanaged([]const u8).empty;
    defer flag_values.deinit(allocator);
    var bool_flags = std.StringHashMapUnmanaged(void).empty;
    defer bool_flags.deinit(allocator);

    // Collect positionals that come after "--" separator
    var collect_after_separator = std.ArrayListUnmanaged([]const u8).empty;
    defer collect_after_separator.deinit(allocator);
    var saw_separator = false;

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg: []const u8 = args[i];

        if (saw_separator) {
            try collect_after_separator.append(allocator, arg);
            continue;
        }

        if (std.mem.eql(u8, arg, "--")) {
            saw_separator = true;
            continue;
        }

        if (std.mem.startsWith(u8, arg, "--")) {
            // Find matching ArgDef
            var found = false;
            for (def.args) |arg_def| {
                if (arg_def.flag) |flag| {
                    if (std.mem.eql(u8, arg, flag)) {
                        found = true;
                        if (arg_def.kind == .flag_bool) {
                            try bool_flags.put(allocator, flag, {});
                        } else {
                            // Consume next arg as value
                            i += 1;
                            if (i >= args.len) {
                                printErr("error: flag '");
                                printErr(flag);
                                printErr("' requires a value\n");
                                return error.Explained;
                            }
                            try flag_values.put(allocator, flag, args[i]);
                        }
                        break;
                    }
                }
            }
            if (!found) {
                printErr("error: unknown flag '");
                printErr(arg);
                printErr("'\n");
                return error.Explained;
            }
        } else {
            try positionals.append(allocator, arg);
        }
    }

    // Process ArgDefs and emit JSON fields
    var pos_idx: usize = 0;
    for (def.args) |arg_def| {
        switch (arg_def.kind) {
            .positional_string => {
                if (pos_idx < positionals.items.len) {
                    try jw.objectField(arg_def.json_name);
                    try jw.write(positionals.items[pos_idx]);
                    pos_idx += 1;
                }
            },
            .positional_int => {
                if (pos_idx < positionals.items.len) {
                    const val = std.fmt.parseInt(i64, positionals.items[pos_idx], 10) catch {
                        printErr("error: expected integer for ");
                        printErr(arg_def.json_name);
                        printErr(", got '");
                        printErr(positionals.items[pos_idx]);
                        printErr("'\n");
                        return error.Explained;
                    };
                    try jw.objectField(arg_def.json_name);
                    try jw.write(val);
                    pos_idx += 1;
                }
            },
            .positional_file_line => {
                if (pos_idx < positionals.items.len) {
                    const raw = positionals.items[pos_idx];
                    // Split on last ':'
                    const colon = std.mem.lastIndexOfScalar(u8, raw, ':') orelse {
                        printErr("error: expected file:line format, got '");
                        printErr(raw);
                        printErr("'\n");
                        return error.Explained;
                    };
                    const file_part = raw[0..colon];
                    const line_part = raw[colon + 1 ..];
                    const line_num = std.fmt.parseInt(i64, line_part, 10) catch {
                        printErr("error: invalid line number '");
                        printErr(line_part);
                        printErr("'\n");
                        return error.Explained;
                    };
                    try jw.objectField(arg_def.json_name);
                    try jw.write(file_part);
                    if (arg_def.json_name2) |name2| {
                        try jw.objectField(name2);
                        try jw.write(line_num);
                    }
                    pos_idx += 1;
                }
            },
            .flag_string => {
                if (arg_def.flag) |flag| {
                    if (flag_values.get(flag)) |val| {
                        try jw.objectField(arg_def.json_name);
                        try jw.write(val);
                    }
                }
            },
            .flag_string_list => {
                if (arg_def.flag) |flag| {
                    if (flag_values.get(flag)) |val| {
                        try jw.objectField(arg_def.json_name);
                        try jw.beginArray();
                        var it = std.mem.splitScalar(u8, val, ',');
                        while (it.next()) |item| {
                            const trimmed = std.mem.trim(u8, item, " ");
                            if (trimmed.len > 0) {
                                try jw.write(trimmed);
                            }
                        }
                        try jw.endArray();
                    }
                }
            },
            .flag_int => {
                if (arg_def.flag) |flag| {
                    if (flag_values.get(flag)) |val| {
                        const num = std.fmt.parseInt(i64, val, 10) catch {
                            printErr("error: expected integer for ");
                            printErr(flag);
                            printErr(", got '");
                            printErr(val);
                            printErr("'\n");
                            return error.Explained;
                        };
                        try jw.objectField(arg_def.json_name);
                        try jw.write(num);
                    }
                }
            },
            .flag_bool => {
                if (arg_def.flag) |flag| {
                    if (bool_flags.get(flag) != null) {
                        try jw.objectField(arg_def.json_name);
                        // --no-symbols is a negation flag
                        if (std.mem.startsWith(u8, flag, "--no-")) {
                            try jw.write(false);
                        } else {
                            try jw.write(true);
                        }
                    }
                }
            },
            .collect_strings => {
                // Use items after "--" separator if present, otherwise remaining positionals
                const items = if (saw_separator)
                    collect_after_separator.items
                else if (pos_idx < positionals.items.len)
                    positionals.items[pos_idx..]
                else
                    &[_][]const u8{};

                if (items.len > 0) {
                    try jw.objectField(arg_def.json_name);
                    try jw.beginArray();
                    for (items) |item| {
                        try jw.write(item);
                    }
                    try jw.endArray();
                }
            },
            .collect_ints => {
                const items = if (pos_idx < positionals.items.len)
                    positionals.items[pos_idx..]
                else
                    &[_][]const u8{};

                if (items.len > 0) {
                    try jw.objectField(arg_def.json_name);
                    try jw.beginArray();
                    for (items) |item| {
                        const num = std.fmt.parseInt(i64, item, 10) catch {
                            printErr("error: expected integer, got '");
                            printErr(item);
                            printErr("'\n");
                            return error.Explained;
                        };
                        try jw.write(num);
                    }
                    try jw.endArray();
                }
            },
        }
    }

    try jw.endObject(); // args
    try jw.endObject(); // root

    return try aw.toOwnedSlice();
}

// ── Send to Daemon ──────────────────────────────────────────────────────

fn sendRequest(allocator: std.mem.Allocator, request: []const u8) void {
    // Connect to daemon (auto-start if needed)
    const sock = connectToDaemon(allocator) catch {
        printErr("error: could not connect to debug daemon\n");
        return;
    };
    defer posix.close(sock);

    // Send request (single writev for request + newline)
    const iovecs = [_]posix.iovec_const{
        .{ .base = request.ptr, .len = request.len },
        .{ .base = "\n", .len = 1 },
    };
    _ = posix.writev(sock, &iovecs) catch {
        printErr("error: failed to send request to daemon\n");
        return;
    };

    // Shutdown write side to signal end of request
    std.posix.shutdown(sock, .send) catch {};

    // Read response
    var resp_buf = std.ArrayListUnmanaged(u8).empty;
    defer resp_buf.deinit(allocator);

    var read_buf: [65536]u8 = undefined;
    while (true) {
        const n = posix.read(sock, &read_buf) catch break;
        if (n == 0) break;
        resp_buf.appendSlice(allocator, read_buf[0..n]) catch break;
    }

    if (resp_buf.items.len == 0) {
        printErr("error: no response from daemon\n");
        return;
    }

    // Trim trailing newline
    var response = resp_buf.items;
    if (response.len > 0 and response[response.len - 1] == '\n') response = response[0 .. response.len - 1];

    // Fast path: extract result substring without full JSON parse-reserialize
    const ok_prefix = "{\"ok\":true,\"result\":";
    if (std.mem.startsWith(u8, response, ok_prefix) and response.len > ok_prefix.len and response[response.len - 1] == '}') {
        writeStdout(response[ok_prefix.len .. response.len - 1]);
        writeStdout("\n");
        return;
    }

    // Fallback: full JSON parse for error responses and unexpected formats
    const resp_parsed = json.parseFromSlice(json.Value, allocator, response, .{}) catch {
        writeStdout(response);
        writeStdout("\n");
        return;
    };
    defer resp_parsed.deinit();

    if (resp_parsed.value != .object) {
        writeStdout(response);
        writeStdout("\n");
        return;
    }

    const ok_val = resp_parsed.value.object.get("ok");
    if (ok_val) |ok| {
        if (ok == .bool and !ok.bool) {
            if (resp_parsed.value.object.get("error")) |err_val| {
                if (err_val == .object) {
                    if (err_val.object.get("message")) |msg| {
                        if (msg == .string) {
                            printErr("error: ");
                            printErr(msg.string);
                            printErr("\n");
                            return;
                        }
                    }
                }
            }
            printErr("error: daemon returned an error\n");
            return;
        }
    }

    // Success with non-standard format - extract and print the result field
    if (resp_parsed.value.object.get("result")) |result_val| {
        var result_aw: Writer.Allocating = .init(allocator);
        defer result_aw.deinit();
        var result_jw: Stringify = .{ .writer = &result_aw.writer };
        result_jw.write(result_val) catch {
            writeStdout(response);
            writeStdout("\n");
            return;
        };
        const result_str = result_aw.toOwnedSlice() catch {
            writeStdout(response);
            writeStdout("\n");
            return;
        };
        defer allocator.free(result_str);
        writeStdout(result_str);
        writeStdout("\n");
    } else {
        writeStdout(response);
        writeStdout("\n");
    }
}

// ── Help Functions ──────────────────────────────────────────────────────

// ANSI styles
const cyan = "\x1B[36m";
const bold = "\x1B[1m";
const dim = "\x1B[2m";
const reset = "\x1B[0m";

fn printSendHelp() void {
    printErr(bold ++ "  cog debug/send" ++ reset ++ " — Send a debug command to the daemon\n\n");
    printErr(cyan ++ bold ++ "  Usage" ++ reset ++ "\n");
    printErr("    cog debug/send <tool> [args] [--flags]\n");
    printErr("    cog debug/send <tool> --help\n\n");
    printErr(cyan ++ bold ++ "  Tools" ++ reset ++ "\n");

    for (&cli_tools) |*def| {
        printErr("    " ++ bold);
        printErr(def.cli_name);
        printErr(reset);
        // Pad to column 30
        const name_len = def.cli_name.len;
        if (name_len < 26) {
            var pad_buf: [26]u8 = undefined;
            const pad_len = 26 - name_len;
            @memset(pad_buf[0..pad_len], ' ');
            printErr(pad_buf[0..pad_len]);
        } else {
            printErr("  ");
        }
        printErr(dim);
        printErr(def.description);
        printErr(reset ++ "\n");
    }

    printErr("\n" ++ dim ++ "  Run 'cog debug/send <tool> --help' for tool-specific usage." ++ reset ++ "\n\n");
}

fn printToolHelp(def: *const CliToolDef) void {
    // Header
    printErr(bold ++ "  cog debug/send " ++ reset);
    printErr(bold);
    printErr(def.cli_name);
    printErr(reset ++ " — ");
    printErr(def.description);
    printErr("\n\n");

    // Usage line
    printErr(cyan ++ bold ++ "  Usage" ++ reset ++ "\n");
    printErr("    cog debug/send ");
    printErr(def.cli_name);

    // Show positionals in usage line
    for (def.args) |arg_def| {
        switch (arg_def.kind) {
            .positional_string, .positional_int => {
                printErr(" <");
                printErr(arg_def.json_name);
                printErr(">");
            },
            .positional_file_line => {
                printErr(" <");
                printErr(arg_def.json_name);
                printErr(":line>");
            },
            .collect_strings => {
                printErr(" [-- args...]");
            },
            .collect_ints => {
                printErr(" [ids...]");
            },
            else => {},
        }
    }

    // Show flags hint
    var has_flags = false;
    for (def.args) |arg_def| {
        if (arg_def.flag != null) {
            has_flags = true;
            break;
        }
    }
    if (has_flags) {
        printErr(" " ++ dim ++ "[--flags]" ++ reset);
    }
    printErr("\n\n");

    // Positionals section
    var has_positionals = false;
    for (def.args) |arg_def| {
        switch (arg_def.kind) {
            .positional_string, .positional_int, .positional_file_line, .collect_strings, .collect_ints => {
                has_positionals = true;
                break;
            },
            else => {},
        }
    }

    if (has_positionals) {
        printErr(cyan ++ bold ++ "  Positionals" ++ reset ++ "\n");
        for (def.args) |arg_def| {
            switch (arg_def.kind) {
                .positional_string, .positional_int, .positional_file_line, .collect_strings, .collect_ints => {
                    printErr("    ");
                    printErr(bold);
                    printErr(arg_def.json_name);
                    printErr(reset);
                    const name_len = arg_def.json_name.len;
                    if (name_len < 22) {
                        var pad_buf: [22]u8 = undefined;
                        const pad_len = 22 - name_len;
                        @memset(pad_buf[0..pad_len], ' ');
                        printErr(pad_buf[0..pad_len]);
                    } else {
                        printErr("  ");
                    }
                    printErr(dim);
                    printErr(arg_def.description);
                    printErr(reset ++ "\n");
                },
                else => {},
            }
        }
        printErr("\n");
    }

    // Flags section
    if (has_flags) {
        printErr(cyan ++ bold ++ "  Flags" ++ reset ++ "\n");
        for (def.args) |arg_def| {
            if (arg_def.flag) |flag| {
                printErr("    ");
                printErr(bold);
                printErr(flag);
                printErr(reset);
                const flag_len = flag.len;
                if (flag_len < 22) {
                    var pad_buf: [22]u8 = undefined;
                    const pad_len = 22 - flag_len;
                    @memset(pad_buf[0..pad_len], ' ');
                    printErr(pad_buf[0..pad_len]);
                } else {
                    printErr("  ");
                }
                printErr(dim);
                printErr(arg_def.description);
                printErr(reset ++ "\n");
            }
        }
        printErr("\n");
    }
}

fn findTool(name: []const u8) ?*const CliToolDef {
    for (&cli_tools) |*def| {
        if (std.mem.eql(u8, name, def.cli_name)) return def;
    }
    return null;
}

// ── Daemon Connection ───────────────────────────────────────────────────

fn connectToDaemon(allocator: std.mem.Allocator) !posix.socket_t {
    var path_buf: [128]u8 = undefined;
    const sock_path = daemon_mod.getSocketPath(&path_buf) orelse return error.PathTooLong;

    // Try connecting first
    if (tryConnect(sock_path)) |sock| return sock;

    // Socket doesn't exist or connection refused — start the daemon
    try startDaemon(allocator);

    // Poll for the socket to appear (up to 2 seconds)
    var attempts: u32 = 0;
    while (attempts < 20) : (attempts += 1) {
        posix.nanosleep(0, 100_000_000); // 100ms
        if (tryConnect(sock_path)) |sock| return sock;
    }

    return error.DaemonStartFailed;
}

fn tryConnect(sock_path: []const u8) ?posix.socket_t {
    const sock = posix.socket(posix.AF.UNIX, posix.SOCK.STREAM, 0) catch return null;

    var addr: posix.sockaddr.un = .{ .path = undefined };
    @memset(&addr.path, 0);
    @memcpy(addr.path[0..sock_path.len], sock_path);

    posix.connect(sock, @ptrCast(&addr), @sizeOf(posix.sockaddr.un)) catch {
        posix.close(sock);
        return null;
    };

    return sock;
}

fn startDaemon(allocator: std.mem.Allocator) !void {
    // Get path to self
    var exe_buf: [std.fs.max_path_bytes]u8 = undefined;
    const exe_path = try std.fs.selfExePath(&exe_buf);
    const exe_owned = try allocator.dupe(u8, exe_path);
    defer allocator.free(exe_owned);

    // Spawn: cog debug:serve --daemon
    var child = std.process.Child.init(
        &.{ exe_owned, "debug:serve", "--daemon" },
        allocator,
    );
    child.stdin_behavior = .Close;
    child.stdout_behavior = .Close;
    child.stderr_behavior = .Close;
    child.pgid = 0;

    try child.spawn();
    // Don't wait — the daemon runs in the background
}

// ── Status and Kill Commands ────────────────────────────────────────────

pub fn statusCommand(allocator: std.mem.Allocator) !void {
    var path_buf: [128]u8 = undefined;
    const sock_path = daemon_mod.getSocketPath(&path_buf) orelse {
        printErr("error: could not determine socket path\n");
        return error.Explained;
    };

    // Try to connect and send a sessions query
    const sock = tryConnect(sock_path) orelse {
        writeStdout("{\"running\":false}\n");
        return;
    };
    defer posix.close(sock);

    // Send a sessions query
    const request = "{\"tool\":\"debug_sessions\",\"args\":{}}";
    _ = posix.write(sock, request) catch {
        writeStdout("{\"running\":true,\"sessions\":\"unknown\"}\n");
        return;
    };
    _ = posix.write(sock, "\n") catch {};

    std.posix.shutdown(sock, .send) catch {};

    // Read response
    var resp_buf: [65536]u8 = undefined;
    var total: usize = 0;
    while (total < resp_buf.len) {
        const n = posix.read(sock, resp_buf[total..]) catch break;
        if (n == 0) break;
        total += n;
    }

    if (total > 0) {
        // Wrap in running status
        var aw: Writer.Allocating = .init(allocator);
        defer aw.deinit();
        aw.writer.writeAll("{\"running\":true,\"socket\":\"") catch return;
        aw.writer.writeAll(sock_path) catch return;
        aw.writer.writeAll("\",\"response\":") catch return;
        var resp = resp_buf[0..total];
        if (resp.len > 0 and resp[resp.len - 1] == '\n') resp = resp[0 .. resp.len - 1];
        aw.writer.writeAll(resp) catch return;
        aw.writer.writeByte('}') catch return;
        const output = aw.toOwnedSlice() catch return;
        defer allocator.free(output);
        writeStdout(output);
        writeStdout("\n");
    } else {
        writeStdout("{\"running\":true,\"sessions\":\"unknown\"}\n");
    }
}

pub fn killCommand() !void {
    var pid_buf: [128]u8 = undefined;
    const pid_path = daemon_mod.getPidPath(&pid_buf) orelse {
        printErr("error: could not determine pid path\n");
        return error.Explained;
    };

    // Read PID from file
    var f = std.fs.openFileAbsolute(pid_path, .{}) catch {
        printErr("error: no daemon running (no pid file)\n");
        return error.Explained;
    };
    defer f.close();

    var buf: [32]u8 = undefined;
    const n = f.readAll(&buf) catch {
        printErr("error: could not read pid file\n");
        return error.Explained;
    };

    const pid_str = std.mem.trim(u8, buf[0..n], &[_]u8{ ' ', '\n', '\r', '\t' });
    const pid = std.fmt.parseInt(i32, pid_str, 10) catch {
        printErr("error: invalid pid in pid file\n");
        return error.Explained;
    };

    // Send SIGTERM
    const c_fns = struct {
        extern fn kill(pid: i32, sig: i32) i32;
    };
    const result = c_fns.kill(pid, 15); // SIGTERM = 15
    if (result != 0) {
        printErr("error: failed to send SIGTERM to daemon\n");
        return error.Explained;
    }

    writeStdout("{\"killed\":true}\n");

    // Clean up pid file
    std.fs.deleteFileAbsolute(pid_path) catch {};
}

// ── I/O Helpers ─────────────────────────────────────────────────────────

fn printErr(msg: []const u8) void {
    if (@import("builtin").is_test) return;
    var buf: [4096]u8 = undefined;
    var w = std.fs.File.stderr().writer(&buf);
    w.interface.writeAll(msg) catch {};
    w.interface.flush() catch {};
}

fn writeStdout(msg: []const u8) void {
    if (@import("builtin").is_test) return;
    var buf: [65536]u8 = undefined;
    var w = std.fs.File.stdout().writer(&buf);
    w.interface.writeAll(msg) catch {};
    w.interface.flush() catch {};
}

// ── Tests ───────────────────────────────────────────────────────────────

test "cli tool table has 40 entries" {
    try std.testing.expectEqual(@as(usize, 40), cli_tools.len);
}

test "findTool returns correct definitions" {
    const launch = findTool("launch");
    try std.testing.expect(launch != null);
    try std.testing.expectEqualStrings("debug_launch", launch.?.server_tool);
    try std.testing.expect(launch.?.inject_action == null);

    const bp_set = findTool("breakpoint_set");
    try std.testing.expect(bp_set != null);
    try std.testing.expectEqualStrings("debug_breakpoint", bp_set.?.server_tool);
    try std.testing.expectEqualStrings("set", bp_set.?.inject_action.?);

    const unknown = findTool("unknown");
    try std.testing.expect(unknown == null);
}

test "parseAndBuildRequest handles positional string" {
    const allocator = std.testing.allocator;
    const def = findTool("launch").?;
    const args = [_][:0]const u8{"./my_program"};
    const result = try parseAndBuildRequest(allocator, def, &args);
    defer allocator.free(result);

    // Verify JSON contains the program field
    const parsed = try json.parseFromSlice(json.Value, allocator, result, .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings("debug_launch", parsed.value.object.get("tool").?.string);
    const inner_args = parsed.value.object.get("args").?.object;
    try std.testing.expectEqualStrings("./my_program", inner_args.get("program").?.string);
}

test "parseAndBuildRequest handles file:line positional" {
    const allocator = std.testing.allocator;
    const def = findTool("breakpoint_set").?;
    const args = [_][:0]const u8{ "src/main.c:42", "--session", "session-1" };
    const result = try parseAndBuildRequest(allocator, def, &args);
    defer allocator.free(result);

    const parsed = try json.parseFromSlice(json.Value, allocator, result, .{});
    defer parsed.deinit();
    const inner_args = parsed.value.object.get("args").?.object;
    try std.testing.expectEqualStrings("set", inner_args.get("action").?.string);
    try std.testing.expectEqualStrings("src/main.c", inner_args.get("file").?.string);
    try std.testing.expectEqual(@as(i64, 42), inner_args.get("line").?.integer);
    try std.testing.expectEqualStrings("session-1", inner_args.get("session_id").?.string);
}

test "parseAndBuildRequest handles flags and booleans" {
    const allocator = std.testing.allocator;
    const def = findTool("launch").?;
    const args = [_][:0]const u8{ "./prog", "--stop-on-entry", "--cwd", "/tmp" };
    const result = try parseAndBuildRequest(allocator, def, &args);
    defer allocator.free(result);

    const parsed = try json.parseFromSlice(json.Value, allocator, result, .{});
    defer parsed.deinit();
    const inner_args = parsed.value.object.get("args").?.object;
    try std.testing.expectEqualStrings("./prog", inner_args.get("program").?.string);
    try std.testing.expect(inner_args.get("stop_on_entry").?.bool);
    try std.testing.expectEqualStrings("/tmp", inner_args.get("cwd").?.string);
}

test "parseAndBuildRequest handles collect_strings after --" {
    const allocator = std.testing.allocator;
    const def = findTool("launch").?;
    const args = [_][:0]const u8{ "./prog", "--", "arg1", "arg2", "arg3" };
    const result = try parseAndBuildRequest(allocator, def, &args);
    defer allocator.free(result);

    const parsed = try json.parseFromSlice(json.Value, allocator, result, .{});
    defer parsed.deinit();
    const inner_args = parsed.value.object.get("args").?.object;
    const prog_args = inner_args.get("args").?.array;
    try std.testing.expectEqual(@as(usize, 3), prog_args.items.len);
    try std.testing.expectEqualStrings("arg1", prog_args.items[0].string);
}

test "parseAndBuildRequest handles collect_ints" {
    const allocator = std.testing.allocator;
    const def = findTool("terminate_threads").?;
    const args = [_][:0]const u8{ "--session", "s1", "1", "2", "3" };
    const result = try parseAndBuildRequest(allocator, def, &args);
    defer allocator.free(result);

    const parsed = try json.parseFromSlice(json.Value, allocator, result, .{});
    defer parsed.deinit();
    const inner_args = parsed.value.object.get("args").?.object;
    try std.testing.expectEqualStrings("s1", inner_args.get("session_id").?.string);
    const ids = inner_args.get("thread_ids").?.array;
    try std.testing.expectEqual(@as(usize, 3), ids.items.len);
    try std.testing.expectEqual(@as(i64, 1), ids.items[0].integer);
    try std.testing.expectEqual(@as(i64, 2), ids.items[1].integer);
    try std.testing.expectEqual(@as(i64, 3), ids.items[2].integer);
}

test "parseAndBuildRequest handles no-args tool" {
    const allocator = std.testing.allocator;
    const def = findTool("sessions").?;
    const args = [_][:0]const u8{};
    const result = try parseAndBuildRequest(allocator, def, &args);
    defer allocator.free(result);

    const parsed = try json.parseFromSlice(json.Value, allocator, result, .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings("debug_sessions", parsed.value.object.get("tool").?.string);
}

test "parseAndBuildRequest handles negation flag --no-symbols" {
    const allocator = std.testing.allocator;
    const def = findTool("disassemble").?;
    const args = [_][:0]const u8{ "0x1000", "--no-symbols" };
    const result = try parseAndBuildRequest(allocator, def, &args);
    defer allocator.free(result);

    const parsed = try json.parseFromSlice(json.Value, allocator, result, .{});
    defer parsed.deinit();
    const inner_args = parsed.value.object.get("args").?.object;
    try std.testing.expect(!inner_args.get("resolve_symbols").?.bool);
}
