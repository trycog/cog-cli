const std = @import("std");
const json = std.json;
const Stringify = json.Stringify;
const Writer = std.io.Writer;
const posix = std.posix;
const daemon_mod = @import("daemon.zig");

// ── CLI Tool Definition Table ───────────────────────────────────────────

const CliToolDef = struct {
    cli_name: []const u8, // "debug/send_launch"
    server_tool: []const u8, // "debug_launch"
    inject_action: ?[]const u8, // null or "set"/"remove"/etc.
    description: []const u8,
};

const cli_tools = [_]CliToolDef{
    // Core tools
    .{ .cli_name = "debug/send_launch", .server_tool = "debug_launch", .inject_action = null, .description = "Launch a program under the debugger" },
    .{ .cli_name = "debug/send_stop", .server_tool = "debug_stop", .inject_action = null, .description = "Stop a debug session" },
    .{ .cli_name = "debug/send_attach", .server_tool = "debug_attach", .inject_action = null, .description = "Attach to a running process" },
    .{ .cli_name = "debug/send_restart", .server_tool = "debug_restart", .inject_action = null, .description = "Restart the debug session" },
    .{ .cli_name = "debug/send_sessions", .server_tool = "debug_sessions", .inject_action = null, .description = "List all active debug sessions" },
    // Breakpoint variants
    .{ .cli_name = "debug/send_breakpoint_set", .server_tool = "debug_breakpoint", .inject_action = "set", .description = "Set a line breakpoint" },
    .{ .cli_name = "debug/send_breakpoint_set_function", .server_tool = "debug_breakpoint", .inject_action = "set_function", .description = "Set a function breakpoint" },
    .{ .cli_name = "debug/send_breakpoint_set_exception", .server_tool = "debug_breakpoint", .inject_action = "set_exception", .description = "Set an exception breakpoint" },
    .{ .cli_name = "debug/send_breakpoint_remove", .server_tool = "debug_breakpoint", .inject_action = "remove", .description = "Remove a breakpoint" },
    .{ .cli_name = "debug/send_breakpoint_list", .server_tool = "debug_breakpoint", .inject_action = "list", .description = "List all breakpoints" },
    // Execution
    .{ .cli_name = "debug/send_run", .server_tool = "debug_run", .inject_action = null, .description = "Continue, step, or restart execution" },
    .{ .cli_name = "debug/send_breakpoint_locations", .server_tool = "debug_breakpoint_locations", .inject_action = null, .description = "Query valid breakpoint positions" },
    // Inspection
    .{ .cli_name = "debug/send_inspect", .server_tool = "debug_inspect", .inject_action = null, .description = "Evaluate expressions and inspect variables" },
    .{ .cli_name = "debug/send_set_variable", .server_tool = "debug_set_variable", .inject_action = null, .description = "Set the value of a variable" },
    .{ .cli_name = "debug/send_set_expression", .server_tool = "debug_set_expression", .inject_action = null, .description = "Evaluate and assign an expression" },
    // Threads and stack
    .{ .cli_name = "debug/send_threads", .server_tool = "debug_threads", .inject_action = null, .description = "List threads" },
    .{ .cli_name = "debug/send_stacktrace", .server_tool = "debug_stacktrace", .inject_action = null, .description = "Get stack trace for a thread" },
    .{ .cli_name = "debug/send_scopes", .server_tool = "debug_scopes", .inject_action = null, .description = "List variable scopes for a frame" },
    // Memory and low-level
    .{ .cli_name = "debug/send_memory", .server_tool = "debug_memory", .inject_action = null, .description = "Read or write process memory" },
    .{ .cli_name = "debug/send_disassemble", .server_tool = "debug_disassemble", .inject_action = null, .description = "Disassemble instructions" },
    .{ .cli_name = "debug/send_registers", .server_tool = "debug_registers", .inject_action = null, .description = "Read CPU register values" },
    .{ .cli_name = "debug/send_write_register", .server_tool = "debug_write_register", .inject_action = null, .description = "Write a CPU register value" },
    .{ .cli_name = "debug/send_find_symbol", .server_tool = "debug_find_symbol", .inject_action = null, .description = "Search for symbol definitions" },
    .{ .cli_name = "debug/send_variable_location", .server_tool = "debug_variable_location", .inject_action = null, .description = "Get variable storage location" },
    // Navigation
    .{ .cli_name = "debug/send_goto_targets", .server_tool = "debug_goto_targets", .inject_action = null, .description = "Discover goto target locations" },
    .{ .cli_name = "debug/send_step_in_targets", .server_tool = "debug_step_in_targets", .inject_action = null, .description = "List step-in targets" },
    .{ .cli_name = "debug/send_restart_frame", .server_tool = "debug_restart_frame", .inject_action = null, .description = "Restart from a stack frame" },
    // Breakpoints
    .{ .cli_name = "debug/send_instruction_breakpoint", .server_tool = "debug_instruction_breakpoint", .inject_action = null, .description = "Set instruction-level breakpoints" },
    .{ .cli_name = "debug/send_watchpoint", .server_tool = "debug_watchpoint", .inject_action = null, .description = "Set a data breakpoint" },
    // Capabilities and introspection
    .{ .cli_name = "debug/send_capabilities", .server_tool = "debug_capabilities", .inject_action = null, .description = "Query driver capabilities" },
    .{ .cli_name = "debug/send_modules", .server_tool = "debug_modules", .inject_action = null, .description = "List loaded modules" },
    .{ .cli_name = "debug/send_loaded_sources", .server_tool = "debug_loaded_sources", .inject_action = null, .description = "List available source files" },
    .{ .cli_name = "debug/send_source", .server_tool = "debug_source", .inject_action = null, .description = "Retrieve source code" },
    .{ .cli_name = "debug/send_completions", .server_tool = "debug_completions", .inject_action = null, .description = "Get expression completions" },
    // Exception and events
    .{ .cli_name = "debug/send_exception_info", .server_tool = "debug_exception_info", .inject_action = null, .description = "Get exception information" },
    .{ .cli_name = "debug/send_poll_events", .server_tool = "debug_poll_events", .inject_action = null, .description = "Poll for debug events" },
    // Cancellation
    .{ .cli_name = "debug/send_cancel", .server_tool = "debug_cancel", .inject_action = null, .description = "Cancel a pending request" },
    .{ .cli_name = "debug/send_terminate_threads", .server_tool = "debug_terminate_threads", .inject_action = null, .description = "Terminate specific threads" },
};

// ── CLI Dispatch ────────────────────────────────────────────────────────

pub fn dispatch(allocator: std.mem.Allocator, subcmd: []const u8, args: []const [:0]const u8) !void {
    // Find the matching tool definition
    const def = findTool(subcmd) orelse {
        printErr("error: unknown debug command '");
        printErr(subcmd);
        printErr("'\n");
        return error.Explained;
    };

    // Parse the JSON argument (first positional arg, or "{}" if none)
    const json_arg = if (args.len > 0 and !std.mem.startsWith(u8, args[0], "--"))
        args[0]
    else
        "{}";

    // Parse the JSON
    const parsed = json.parseFromSlice(json.Value, allocator, json_arg, .{}) catch {
        printErr("error: invalid JSON argument\n");
        return error.Explained;
    };
    defer parsed.deinit();

    if (parsed.value != .object) {
        printErr("error: argument must be a JSON object\n");
        return error.Explained;
    }

    // Build the request JSON with optional action injection
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

    // Copy all fields from the parsed JSON
    var it = parsed.value.object.iterator();
    while (it.next()) |entry| {
        try jw.objectField(entry.key_ptr.*);
        try jw.write(entry.value_ptr.*);
    }

    try jw.endObject(); // args
    try jw.endObject(); // root

    const request = try aw.toOwnedSlice();
    defer allocator.free(request);

    // Connect to daemon (auto-start if needed)
    const sock = connectToDaemon(allocator) catch {
        printErr("error: could not connect to debug daemon\n");
        return error.Explained;
    };
    defer posix.close(sock);

    // Send request
    _ = posix.write(sock, request) catch {
        printErr("error: failed to send request to daemon\n");
        return error.Explained;
    };
    _ = posix.write(sock, "\n") catch {};

    // Shutdown write side to signal end of request
    std.posix.shutdown(sock, .send) catch {};

    // Read response
    var resp_buf = std.ArrayListUnmanaged(u8).empty;
    defer resp_buf.deinit(allocator);

    var read_buf: [65536]u8 = undefined;
    while (true) {
        const n = posix.read(sock, &read_buf) catch break;
        if (n == 0) break;
        try resp_buf.appendSlice(allocator, read_buf[0..n]);
    }

    if (resp_buf.items.len == 0) {
        printErr("error: no response from daemon\n");
        return error.Explained;
    }

    // Trim trailing newline
    var response = resp_buf.items;
    if (response.len > 0 and response[response.len - 1] == '\n') response = response[0 .. response.len - 1];

    // Parse the response to check for errors
    const resp_parsed = json.parseFromSlice(json.Value, allocator, response, .{}) catch {
        // If we can't parse, just output it raw
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
            // Error response - write to stderr and exit with error
            if (resp_parsed.value.object.get("error")) |err_val| {
                if (err_val == .object) {
                    if (err_val.object.get("message")) |msg| {
                        if (msg == .string) {
                            printErr("error: ");
                            printErr(msg.string);
                            printErr("\n");
                            return error.Explained;
                        }
                    }
                }
            }
            printErr("error: daemon returned an error\n");
            return error.Explained;
        }
    }

    // Success - extract and print the result field
    if (resp_parsed.value.object.get("result")) |result_val| {
        // Re-serialize the result value
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
        // No result field, output the full response
        writeStdout(response);
        writeStdout("\n");
    }
}

fn findTool(name: []const u8) ?*const CliToolDef {
    for (&cli_tools) |*def| {
        if (std.mem.eql(u8, name, def.cli_name)) return def;
    }
    return null;
}

/// Check if a given subcmd is a known debug/send_* command.
pub fn isCliCommand(subcmd: []const u8) bool {
    return findTool(subcmd) != null;
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

    // Spawn: cog debug/serve --daemon
    var child = std.process.Child.init(
        &.{ exe_owned, "debug/serve", "--daemon" },
        allocator,
    );
    child.stdin_behavior = .Close;
    child.stdout_behavior = .Close;
    child.stderr_behavior = .Close;

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

test "cli tool table has 38 entries" {
    try std.testing.expectEqual(@as(usize, 38), cli_tools.len);
}

test "findTool returns correct definitions" {
    const launch = findTool("debug/send_launch");
    try std.testing.expect(launch != null);
    try std.testing.expectEqualStrings("debug_launch", launch.?.server_tool);
    try std.testing.expect(launch.?.inject_action == null);

    const bp_set = findTool("debug/send_breakpoint_set");
    try std.testing.expect(bp_set != null);
    try std.testing.expectEqualStrings("debug_breakpoint", bp_set.?.server_tool);
    try std.testing.expectEqualStrings("set", bp_set.?.inject_action.?);

    const unknown = findTool("debug/send_unknown");
    try std.testing.expect(unknown == null);
}

test "isCliCommand identifies valid commands" {
    try std.testing.expect(isCliCommand("debug/send_launch"));
    try std.testing.expect(isCliCommand("debug/send_breakpoint_set"));
    try std.testing.expect(isCliCommand("debug/send_poll_events"));
    try std.testing.expect(!isCliCommand("debug/send_unknown"));
    try std.testing.expect(!isCliCommand("debug/serve"));
}
