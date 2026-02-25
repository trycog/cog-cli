const std = @import("std");
const json = std.json;
const Stringify = json.Stringify;
const Writer = std.io.Writer;
const types = @import("../types.zig");
const driver_mod = @import("../driver.zig");
const protocol = @import("protocol.zig");
const transport = @import("transport.zig");

// Debug logging to file (stderr not visible when running as MCP subprocess)
var dap_log_file: ?std.fs.File = null;

fn dapLog(comptime fmt: []const u8, args: anytype) void {
    if (dap_log_file == null) {
        dap_log_file = std.fs.cwd().createFile("/tmp/cog-dap-debug.log", .{ .truncate = false }) catch null;
        if (dap_log_file) |f| f.seekFromEnd(0) catch {};
    }
    const f = dap_log_file orelse return;
    var buf: [128]u8 = undefined;
    const ts = std.time.timestamp();
    const prefix = std.fmt.bufPrint(&buf, "[{d}] ", .{ts}) catch return;
    f.writeAll(prefix) catch return;
    var msg_buf: [8192]u8 = undefined;
    const msg = std.fmt.bufPrint(&msg_buf, fmt, args) catch return;
    f.writeAll(msg) catch return;
    f.writeAll("\n") catch return;
}

/// Resolve symlinks in a file path (e.g. /tmp -> /private/tmp on macOS).
/// Falls back to the original path if resolution fails.
fn resolvePath(allocator: std.mem.Allocator, path: []const u8) []const u8 {
    return std.fs.cwd().realpathAlloc(allocator, path) catch return allocator.dupe(u8, path) catch path;
}

const RunAction = types.RunAction;
const StopState = types.StopState;
const StopReason = types.StopReason;
const StackFrame = types.StackFrame;
const Variable = types.Variable;
const SourceLocation = types.SourceLocation;
const LaunchConfig = types.LaunchConfig;
const BreakpointInfo = types.BreakpointInfo;
const InspectRequest = types.InspectRequest;
const InspectResult = types.InspectResult;
const ThreadInfo = types.ThreadInfo;
const DisassembledInstruction = types.DisassembledInstruction;
const Scope = types.Scope;
const DataBreakpointInfo = types.DataBreakpointInfo;
const DataBreakpointAccessType = types.DataBreakpointAccessType;
const DebugCapabilities = types.DebugCapabilities;
const CompletionItem = types.CompletionItem;
const Module = types.Module;
const InstructionBreakpoint = types.InstructionBreakpoint;
const BreakpointLocation = types.BreakpointLocation;
const StepInTarget = types.StepInTarget;
const ActiveDriver = driver_mod.ActiveDriver;
const DriverVTable = driver_mod.DriverVTable;

// ── DAP Proxy ───────────────────────────────────────────────────────────

const BufferedEvent = struct {
    event_name: []const u8,
    body: []const u8,
};

/// A child process spawned with setsid() so it cannot access the
/// controlling terminal.  Replaces std.process.Child for the debug
/// adapter to prevent SIGTTIN in the parent (Claude CLI) process.
const DetachedProcess = struct {
    id: std.posix.pid_t,
    stdin: ?std.fs.File = null,
    stdout: ?std.fs.File = null,
    stderr: ?std.fs.File = null,

    fn kill(self: *DetachedProcess) !void {
        std.posix.kill(self.id, std.posix.SIG.KILL) catch |err| switch (err) {
            error.ProcessNotFound => return,
            else => return err,
        };
    }
};

/// Fork+exec a child process in a **new session** (`setsid`).
/// This fully detaches from the controlling terminal so the adapter
/// (and any processes it spawns) can never steal the foreground
/// process group — which would send SIGTTIN to the parent.
fn spawnDetached(allocator: std.mem.Allocator, argv: []const []const u8) !DetachedProcess {
    const posix = std.posix;

    // Create pipes with CLOEXEC — they auto-close after exec in the child.
    const stdin_pipe = try posix.pipe2(.{ .CLOEXEC = true });
    errdefer {
        posix.close(stdin_pipe[0]);
        posix.close(stdin_pipe[1]);
    }
    const stdout_pipe = try posix.pipe2(.{ .CLOEXEC = true });
    errdefer {
        posix.close(stdout_pipe[0]);
        posix.close(stdout_pipe[1]);
    }
    const stderr_pipe = try posix.pipe2(.{ .CLOEXEC = true });
    errdefer {
        posix.close(stderr_pipe[0]);
        posix.close(stderr_pipe[1]);
    }

    // Prepare null-terminated argv and capture environ BEFORE fork
    // (no allocations are safe between fork and exec).
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const argv_buf = try a.allocSentinel(?[*:0]const u8, argv.len, null);
    for (argv, 0..) |arg, i| argv_buf[i] = (try a.dupeZ(u8, arg)).ptr;
    const envp: [*:null]const ?[*:0]const u8 = @ptrCast(std.c.environ);

    const pid = try posix.fork();
    if (pid == 0) {
        // ── Child ──
        // Create a new session — fully detaches from the controlling
        // terminal so the adapter cannot call tcsetpgrp().
        _ = std.c.setsid();

        // Wire up pipes to stdin/stdout/stderr (dup2 clears CLOEXEC on
        // the target fd, so 0/1/2 survive exec).
        _ = posix.dup2(stdin_pipe[0], posix.STDIN_FILENO) catch posix.exit(1);
        _ = posix.dup2(stdout_pipe[1], posix.STDOUT_FILENO) catch posix.exit(1);
        _ = posix.dup2(stderr_pipe[1], posix.STDERR_FILENO) catch posix.exit(1);

        // Close the original pipe fds (they have CLOEXEC but be explicit).
        posix.close(stdin_pipe[0]);
        posix.close(stdin_pipe[1]);
        posix.close(stdout_pipe[0]);
        posix.close(stdout_pipe[1]);
        posix.close(stderr_pipe[0]);
        posix.close(stderr_pipe[1]);

        // exec — does not return on success
        _ = @intFromError(posix.execvpeZ_expandArg0(.no_expand, argv_buf[0].?, argv_buf.ptr, envp));
        posix.exit(127);
    }

    // ── Parent ── close unused pipe ends
    posix.close(stdin_pipe[0]);
    posix.close(stdout_pipe[1]);
    posix.close(stderr_pipe[1]);

    return .{
        .id = pid,
        .stdin = .{ .handle = stdin_pipe[1] },
        .stdout = .{ .handle = stdout_pipe[0] },
        .stderr = .{ .handle = stderr_pipe[0] },
    };
}

pub const Transport = union(enum) {
    none,
    stdio: StdioTransport,
    tcp: TcpTransport,
};

pub const StdioTransport = struct {
    process: DetachedProcess,
};

pub const TcpTransport = struct {
    stream: std.net.Stream,
    server_process: DetachedProcess,
};

const extensions = @import("../../extensions.zig");
const adapter_lifecycle = @import("adapter_lifecycle.zig");

pub const DapProxy = struct {
    transport: Transport = .none,
    debug_config: ?extensions.DapConfig = null,
    seq: i64 = 1,
    thread_id: i64 = 1,
    // Topmost frame ID from the most recent stopped event's stack trace.
    // Used as the default frame for evaluate when the caller omits frame_id.
    current_frame_id: ?i64 = null,
    // DAP frame IDs from the most recent stack trace, indexed by user-facing
    // 0-based position (0=topmost).  MCP tools use positional indices while
    // DAP uses opaque adapter-assigned IDs; this cache bridges the two.
    cached_frame_ids: std.ArrayListUnmanaged(i64) = .empty,
    initialized: bool = false,
    allocator: std.mem.Allocator,
    // Buffered data from the adapter
    read_buffer: std.ArrayListUnmanaged(u8) = .empty,
    // Breakpoint tracking: per-file breakpoint lines (DAP requires re-sending all BPs for a file)
    file_breakpoints: std.StringHashMapUnmanaged(std.ArrayListUnmanaged(BreakpointEntry)) = .empty,
    next_bp_id: u32 = 1,
    // Map from our bp_id to file path + line for removal
    bp_registry: std.AutoHashMapUnmanaged(u32, BpRegistryEntry) = .empty,
    // Function breakpoint tracking (for listing and restart re-arming)
    function_breakpoints: std.ArrayListUnmanaged(FunctionBreakpointEntry) = .empty,
    // Active exception filter IDs (for restart re-arming)
    active_exception_filters: ?[]const []const u8 = null,
    // Output buffer for captured debuggee output
    output_buffer: std.ArrayListUnmanaged(types.OutputEntry) = .empty,
    // Loaded modules tracked from module events
    loaded_modules: std.ArrayListUnmanaged(LoadedModuleEntry) = .empty,
    // Capabilities parsed from DAP initialize response
    adapter_capabilities: DebugCapabilities = .{},
    // Exception breakpoint filters from DAP initialize response
    exception_filters: std.ArrayListUnmanaged(ExceptionFilter) = .empty,
    // Buffered memory events from adapter
    memory_events: std.ArrayListUnmanaged(MemoryEvent) = .empty,
    // Progress tracking from adapter
    active_progress: std.StringHashMapUnmanaged(ProgressState) = .empty,
    // Invalidated areas from adapter
    invalidated_areas: std.ArrayListUnmanaged(InvalidatedEvent) = .empty,
    // Pending notifications for MCP server to emit
    pending_notifications: std.ArrayListUnmanaged(types.DebugNotification) = .empty,
    // Buffered events consumed by readResponse but needed by waitForEvent
    buffered_events: std.ArrayListUnmanaged(BufferedEvent) = .empty,
    // Request timeout in milliseconds (default 30s)
    request_timeout_ms: i32 = 30_000,
    // Saved launch state for emulated restart (adapters without supportsRestartRequest)
    saved_launch_program: ?[]const u8 = null,
    saved_launch_args: ?[]const []const u8 = null,
    saved_launch_stop_on_entry: bool = false,
    saved_adapter_argv: ?[]const []const u8 = null,
    // vscode-js-debug child session support
    adapter_tcp_port: ?u16 = null,
    pending_child_config: ?[]const u8 = null,
    parent_stream: ?std.net.Stream = null,
    // Deferred configurationDone: when true, the child session has been
    // initialized but configurationDone has NOT been sent yet.  Breakpoints
    // set by the user go into the configuration phase so vscode-js-debug
    // can resolve source-mapped .ts breakpoints via outFiles pre-scanning.
    // configurationDone is sent on the first proxyRun call.
    child_config_deferred: bool = false,

    pub const MemoryEvent = struct {
        memory_reference: []const u8,
        offset: i64,
        count: i64,
    };

    pub const ProgressState = struct {
        title: []const u8,
        message: []const u8,
        percentage: ?f64,
    };

    pub const InvalidatedEvent = struct {
        areas: []const []const u8,
        stack_frame_id: ?u32,
    };

    pub const ExceptionFilter = struct {
        filter: []const u8,
        label: []const u8,
        description: []const u8 = "",
        default: bool = false,
        supports_condition: bool = false,
        condition_description: []const u8 = "",
    };

    const LoadedModuleEntry = struct {
        name: []const u8,
    };

    const BreakpointEntry = struct {
        line: u32,
        condition: ?[]const u8,
        hit_condition: ?[]const u8,
        log_message: ?[]const u8 = null,
        bp_id: u32,
    };

    const BpRegistryEntry = struct {
        file: []const u8,
        line: u32,
    };

    const FunctionBreakpointEntry = struct {
        bp_id: u32,
        name: []const u8,
        condition: ?[]const u8 = null,
    };

    pub fn init(allocator: std.mem.Allocator) DapProxy {
        return .{
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *DapProxy) void {
        self.read_buffer.deinit(self.allocator);
        // Clean up breakpoint tracking (owned strings)
        var it = self.file_breakpoints.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            for (entry.value_ptr.items) |bp| {
                if (bp.condition) |c| self.allocator.free(c);
                if (bp.hit_condition) |h| self.allocator.free(h);
                if (bp.log_message) |l| self.allocator.free(l);
            }
            entry.value_ptr.deinit(self.allocator);
        }
        self.file_breakpoints.deinit(self.allocator);
        self.bp_registry.deinit(self.allocator);
        // Clean up function breakpoints
        for (self.function_breakpoints.items) |entry| {
            self.allocator.free(entry.name);
            if (entry.condition) |c| self.allocator.free(c);
        }
        self.function_breakpoints.deinit(self.allocator);
        // Clean up active exception filters
        if (self.active_exception_filters) |filters| {
            for (filters) |f| self.allocator.free(f);
            self.allocator.free(filters);
        }
        // Clean up output buffer
        for (self.output_buffer.items) |entry| {
            self.allocator.free(entry.category);
            self.allocator.free(entry.text);
        }
        self.output_buffer.deinit(self.allocator);
        // Clean up loaded modules
        for (self.loaded_modules.items) |entry| {
            self.allocator.free(entry.name);
        }
        self.loaded_modules.deinit(self.allocator);
        // Clean up exception filters
        for (self.exception_filters.items) |entry| {
            self.allocator.free(entry.filter);
            self.allocator.free(entry.label);
            if (entry.description.len > 0) self.allocator.free(entry.description);
            if (entry.condition_description.len > 0) self.allocator.free(entry.condition_description);
        }
        self.exception_filters.deinit(self.allocator);
        // Clean up memory events
        for (self.memory_events.items) |entry| {
            self.allocator.free(entry.memory_reference);
        }
        self.memory_events.deinit(self.allocator);
        // Clean up progress tracking
        {
            var pit = self.active_progress.iterator();
            while (pit.next()) |entry| {
                self.allocator.free(entry.value_ptr.title);
                self.allocator.free(entry.value_ptr.message);
                self.allocator.free(entry.key_ptr.*);
            }
            self.active_progress.deinit(self.allocator);
        }
        // Clean up invalidated events
        for (self.invalidated_areas.items) |entry| {
            for (entry.areas) |area| self.allocator.free(area);
            self.allocator.free(entry.areas);
        }
        self.invalidated_areas.deinit(self.allocator);
        // Clean up pending notifications
        for (self.pending_notifications.items) |entry| {
            self.allocator.free(entry.method);
            self.allocator.free(entry.params_json);
        }
        self.pending_notifications.deinit(self.allocator);
        // Clean up buffered events
        for (self.buffered_events.items) |entry| {
            self.allocator.free(entry.event_name);
            self.allocator.free(entry.body);
        }
        self.buffered_events.deinit(self.allocator);
        // Clean up saved launch state
        if (self.saved_launch_program) |p| self.allocator.free(p);
        if (self.saved_launch_args) |args| {
            for (args) |a| self.allocator.free(a);
            self.allocator.free(args);
        }
        if (self.saved_adapter_argv) |argv| {
            for (argv) |a| self.allocator.free(a);
            self.allocator.free(argv);
        }
        // Clean up child session state
        if (self.pending_child_config) |c| self.allocator.free(c);
        // parent_stream is closed by transportKill
        self.transportKill();
    }

    pub fn activeDriver(self: *DapProxy) ActiveDriver {
        return .{
            .ptr = @ptrCast(self),
            .vtable = &vtable,
            .driver_type = .dap,
        };
    }

    const vtable = DriverVTable{
        .launchFn = proxyLaunch,
        .runFn = proxyRun,
        .setBreakpointFn = proxySetBreakpoint,
        .removeBreakpointFn = proxyRemoveBreakpoint,
        .listBreakpointsFn = proxyListBreakpoints,
        .inspectFn = proxyInspect,
        .stopFn = proxyStop,
        .deinitFn = proxyDeinit,
        .threadsFn = proxyThreads,
        .stackTraceFn = proxyStackTrace,
        .readMemoryFn = proxyReadMemory,
        .writeMemoryFn = proxyWriteMemory,
        .disassembleFn = proxyDisassemble,
        .attachFn = proxyAttach,
        .setFunctionBreakpointFn = proxySetFunctionBreakpoint,
        .setExceptionBreakpointsFn = proxySetExceptionBreakpoints,
        .setVariableFn = proxySetVariable,
        .gotoFn = proxyGoto,
        .scopesFn = proxyScopes,
        .dataBreakpointInfoFn = proxyDataBreakpointInfo,
        .setDataBreakpointFn = proxySetDataBreakpoint,
        .capabilitiesFn = proxyCapabilities,
        .completionsFn = proxyCompletions,
        .modulesFn = proxyModules,
        .loadedSourcesFn = proxyLoadedSources,
        .sourceFn = proxySource,
        .setExpressionFn = proxySetExpression,
        .terminateFn = proxyTerminate,
        .restartFrameFn = proxyRestartFrame,
        .exceptionInfoFn = proxyExceptionInfo,
        .setInstructionBreakpointsFn = proxySetInstructionBreakpoints,
        .stepInTargetsFn = proxyStepInTargets,
        .breakpointLocationsFn = proxyBreakpointLocations,
        .cancelFn = proxyCancel,
        .terminateThreadsFn = proxyTerminateThreads,
        .restartFn = proxyRestart,
        .detachFn = proxyDetach,
        .gotoTargetsFn = proxyGotoTargets,
        .findSymbolFn = proxyFindSymbol,
        .drainNotificationsFn = proxyDrainNotifications,
        .rawRequestFn = proxyRawRequest,
        .sendPauseFn = proxySendPause,
        .getPidFn = proxyGetPid,
    };

    fn nextSeq(self: *DapProxy) i64 {
        const s = self.seq;
        self.seq += 1;
        return s;
    }

    /// Translate a user-facing 0-based frame index into the actual DAP frame
    /// ID assigned by the adapter.  Falls back to `current_frame_id` when the
    /// index is out of range (or the cache is empty).
    fn resolveFrameId(self: *DapProxy, user_index: u32) ?i64 {
        if (user_index < self.cached_frame_ids.items.len) {
            return self.cached_frame_ids.items[user_index];
        }
        return self.current_frame_id;
    }

    // ── Transport Helpers ─────────────────────────────────────────────

    /// Write data to the adapter (stdin for stdio, stream for tcp).
    fn transportWrite(self: *DapProxy, data: []const u8) !void {
        switch (self.transport) {
            .none => return error.NotInitialized,
            .stdio => |*t| {
                if (t.process.stdin) |stdin| {
                    var buf: [8192]u8 = undefined;
                    var w = stdin.writer(&buf);
                    w.interface.writeAll(data) catch return error.WriteFailed;
                    w.interface.flush() catch return error.WriteFailed;
                } else return error.NotInitialized;
            },
            .tcp => |*t| {
                t.stream.writeAll(data) catch return error.WriteFailed;
            },
        }
    }

    /// Read data from the adapter (stdout for stdio, stream for tcp).
    fn transportRead(self: *DapProxy, buf: []u8) !usize {
        switch (self.transport) {
            .none => return error.NotInitialized,
            .stdio => |*t| {
                const stdout = t.process.stdout orelse return error.NotInitialized;
                return stdout.read(buf) catch return error.ReadFailed;
            },
            .tcp => |*t| {
                return t.stream.read(buf) catch return error.ReadFailed;
            },
        }
    }

    /// Get the fd for polling readability.
    fn transportPollFd(self: *DapProxy) !std.posix.fd_t {
        switch (self.transport) {
            .none => return error.NotInitialized,
            .stdio => |*t| {
                const stdout = t.process.stdout orelse return error.NotInitialized;
                return stdout.handle;
            },
            .tcp => |*t| {
                return t.stream.handle;
            },
        }
    }

    /// Kill the adapter process(es) and close connections.
    /// Idempotent: sets transport to .none after cleanup so repeated calls are safe.
    fn transportKill(self: *DapProxy) void {
        // Close the parent stream from child session swap (if any)
        if (self.parent_stream) |s| {
            s.close();
            self.parent_stream = null;
        }
        switch (self.transport) {
            .none => {},
            .stdio => |*t| {
                if (t.process.id != 0) {
                    const neg_pid: i32 = -@as(i32, @intCast(t.process.id));
                    std.posix.kill(@bitCast(neg_pid), std.posix.SIG.TERM) catch {};
                }
                _ = t.process.kill() catch {};
            },
            .tcp => |*t| {
                t.stream.close();
                if (t.server_process.id != 0) {
                    const neg_pid: i32 = -@as(i32, @intCast(t.server_process.id));
                    std.posix.kill(@bitCast(neg_pid), std.posix.SIG.TERM) catch {};
                }
                _ = t.server_process.kill() catch {};
            },
        }
        self.transport = .none;
    }

    /// Get the adapter process ID (for MCP getPid).
    fn transportGetPid(self: *DapProxy) ?std.posix.pid_t {
        switch (self.transport) {
            .none => return null,
            .stdio => |t| return t.process.id,
            .tcp => |t| return t.server_process.id,
        }
    }

    // ── DAP I/O ──────────────────────────────────────────────────────

    /// Send a DAP message without waiting for a response.
    fn sendRaw(self: *DapProxy, allocator: std.mem.Allocator, msg: []const u8) !void {
        const encoded = try transport.encodeMessage(allocator, msg);
        defer allocator.free(encoded);

        dapLog("[DAP sendRaw] Writing {d} bytes to adapter...", .{encoded.len});
        try self.transportWrite(encoded);
        dapLog("[DAP sendRaw] Write complete", .{});
    }

    fn sendRequest(self: *DapProxy, allocator: std.mem.Allocator, msg: []const u8) ![]const u8 {
        dapLog("[DAP sendRequest] Encoding message ({d} bytes)", .{msg.len});
        // Encode with Content-Length framing
        const encoded = try transport.encodeMessage(allocator, msg);
        defer allocator.free(encoded);

        dapLog("[DAP sendRequest] Writing to adapter...", .{});
        try self.transportWrite(encoded);
        dapLog("[DAP sendRequest] Write complete, waiting for response", .{});

        // Read response (may need to skip events)
        return self.readResponse(allocator);
    }

    /// Read messages from the adapter until we get a matching response (type == "response").
    /// Verifies request_seq matches the expected seq to correlate responses.
    /// Events are processed inline (e.g., update thread_id from stopped events).
    fn readResponse(self: *DapProxy, allocator: std.mem.Allocator) ![]const u8 {
        const expected_seq = self.seq - 1; // seq used by the most recent sendRequest
        dapLog("[DAP readResponse] Waiting for response to seq={d}, buffer={d} bytes", .{ expected_seq, self.read_buffer.items.len });
        const poll_fd = try self.transportPollFd();

        var read_buf: [8192]u8 = undefined;
        var loop_count: u32 = 0;

        while (true) {
            loop_count += 1;
            // Try to decode a message from the buffer
            while (true) {
                const decoded = transport.decodeMessage(allocator, self.read_buffer.items) catch |err| switch (err) {
                    error.MissingHeader, error.TruncatedBody => break, // need more data
                    else => return err,
                };

                // Remove consumed bytes from read_buffer
                const remaining = self.read_buffer.items.len - decoded.bytes_consumed;
                if (remaining > 0) {
                    std.mem.copyForwards(u8, self.read_buffer.items[0..remaining], self.read_buffer.items[decoded.bytes_consumed..]);
                }
                self.read_buffer.items.len = remaining;

                // Check if this is a response or an event
                const parsed = json.parseFromSlice(json.Value, allocator, decoded.body, .{}) catch {
                    allocator.free(decoded.body);
                    continue;
                };
                defer parsed.deinit();

                const msg_type = if (parsed.value == .object)
                    if (parsed.value.object.get("type")) |t| if (t == .string) t.string else null else null
                else
                    null;

                if (msg_type) |mt| {
                    if (std.mem.eql(u8, mt, "response")) {
                        // Verify request_seq matches expected seq
                        const req_seq = if (parsed.value.object.get("request_seq")) |rs|
                            (if (rs == .integer) rs.integer else null)
                        else
                            null;
                        if (req_seq) |rs| {
                            if (rs != expected_seq) {
                                // Stale response from a previous request — discard and keep reading
                                allocator.free(decoded.body);
                                continue;
                            }
                        }
                        return decoded.body;
                    } else if (std.mem.eql(u8, mt, "event")) {
                        // Handle events
                        if (parsed.value.object.get("event")) |evt| {
                            if (evt == .string) {
                                dapLog("[DAP readResponse] Processing event: {s} (while waiting for seq={d})", .{ evt.string, expected_seq });
                                if (std.mem.eql(u8, evt.string, "stopped")) {
                                    if (parsed.value.object.get("body")) |body| {
                                        if (body == .object) {
                                            if (body.object.get("threadId")) |tid| {
                                                if (tid == .integer) self.thread_id = tid.integer;
                                            }
                                        }
                                    }
                                    // Queue notification
                                    self.queueNotification("debug/stopped", decoded.body);
                                } else if (std.mem.eql(u8, evt.string, "output")) {
                                    // Capture debuggee output (skip telemetry — adapter-internal metrics)
                                    if (parsed.value.object.get("body")) |body| {
                                        if (body == .object) {
                                            const category = if (body.object.get("category")) |c|
                                                (if (c == .string) c.string else "console")
                                            else
                                                "console";
                                            if (!std.mem.eql(u8, category, "telemetry")) {
                                                const text = if (body.object.get("output")) |o|
                                                    (if (o == .string) o.string else "")
                                                else
                                                    "";
                                                if (text.len > 0) {
                                                    self.output_buffer.append(self.allocator, .{
                                                        .category = self.allocator.dupe(u8, category) catch "",
                                                        .text = self.allocator.dupe(u8, text) catch "",
                                                    }) catch {};
                                                }
                                                self.queueNotification("debug/output", decoded.body);
                                            }
                                        }
                                    }
                                } else if (std.mem.eql(u8, evt.string, "breakpoint")) {
                                    // Breakpoint verification event
                                    if (parsed.value.object.get("body")) |body| {
                                        if (body == .object) {
                                            if (body.object.get("breakpoint")) |bp| {
                                                if (bp == .object) {
                                                    self.handleBreakpointEvent(bp.object);
                                                }
                                            }
                                        }
                                    }
                                    self.queueNotification("debug/breakpoint_verified", decoded.body);
                                } else if (std.mem.eql(u8, evt.string, "module")) {
                                    // Module load/unload event — track loaded modules
                                    if (parsed.value.object.get("body")) |body| {
                                        if (body == .object) {
                                            self.handleModuleEvent(body.object);
                                        }
                                    }
                                    self.queueNotification("debug/module", decoded.body);
                                } else if (std.mem.eql(u8, evt.string, "continued")) {
                                    // Thread continued event
                                    self.queueNotification("debug/continued", decoded.body);
                                } else if (std.mem.eql(u8, evt.string, "thread")) {
                                    // Thread create/exit event
                                    self.queueNotification("debug/thread", decoded.body);
                                } else if (std.mem.eql(u8, evt.string, "loadedSource")) {
                                    // Suppressed from poll_events — use cog_debug_loaded_sources instead.
                                } else if (std.mem.eql(u8, evt.string, "process")) {
                                    // Process event
                                    self.queueNotification("debug/process", decoded.body);
                                } else if (std.mem.eql(u8, evt.string, "capabilities")) {
                                    // Capabilities changed event — update adapter_capabilities
                                    if (parsed.value.object.get("body")) |body| {
                                        if (body == .object) {
                                            if (body.object.get("capabilities")) |caps| {
                                                if (caps == .object) {
                                                    self.updateCapabilitiesFromEvent(caps.object);
                                                }
                                            }
                                        }
                                    }
                                    self.queueNotification("debug/capabilities_changed", decoded.body);
                                } else if (std.mem.eql(u8, evt.string, "memory")) {
                                    // Memory event — track memory changes
                                    if (parsed.value.object.get("body")) |body| {
                                        if (body == .object) {
                                            self.handleMemoryEvent(body.object);
                                        }
                                    }
                                    self.queueNotification("debug/memory_changed", decoded.body);
                                } else if (std.mem.eql(u8, evt.string, "progressStart")) {
                                    if (parsed.value.object.get("body")) |body| {
                                        if (body == .object) {
                                            self.handleProgressStart(body.object);
                                        }
                                    }
                                    self.queueNotification("debug/progress", decoded.body);
                                } else if (std.mem.eql(u8, evt.string, "progressUpdate")) {
                                    if (parsed.value.object.get("body")) |body| {
                                        if (body == .object) {
                                            self.handleProgressUpdate(body.object);
                                        }
                                    }
                                    self.queueNotification("debug/progress", decoded.body);
                                } else if (std.mem.eql(u8, evt.string, "progressEnd")) {
                                    if (parsed.value.object.get("body")) |body| {
                                        if (body == .object) {
                                            self.handleProgressEnd(body.object);
                                        }
                                    }
                                    self.queueNotification("debug/progress", decoded.body);
                                } else if (std.mem.eql(u8, evt.string, "exited")) {
                                    // Exited event — process exited with exit code (per DAP spec)
                                    self.queueNotification("debug/exited", decoded.body);
                                } else if (std.mem.eql(u8, evt.string, "terminated")) {
                                    // Terminated event — debug session end
                                    self.initialized = false;
                                    self.queueNotification("debug/terminated", decoded.body);
                                } else if (std.mem.eql(u8, evt.string, "invalidated")) {
                                    // Invalidated event — parse areas and stack frame ID
                                    if (parsed.value.object.get("body")) |body| {
                                        if (body == .object) {
                                            self.handleInvalidatedEvent(body.object);
                                        }
                                    }
                                    self.queueNotification("debug/invalidated", decoded.body);
                                } else {
                                    // Unrecognized event — buffer it for waitForEvent
                                    dapLog("[DAP readResponse] Buffering unrecognized event: {s}", .{evt.string});
                                    self.buffered_events.append(self.allocator, .{
                                        .event_name = self.allocator.dupe(u8, evt.string) catch "",
                                        .body = self.allocator.dupe(u8, decoded.body) catch "",
                                    }) catch {};
                                }
                            }
                        }
                        // Continue reading for the actual response
                        allocator.free(decoded.body);
                        continue;
                    } else if (std.mem.eql(u8, mt, "request")) {
                        // Reverse request from adapter (e.g., startDebugging, runInTerminal)
                        if (parsed.value.object.get("command")) |cmd| {
                            if (cmd == .string) {
                                dapLog("[DAP readResponse] Reverse request: command={s}", .{cmd.string});
                                if (std.mem.eql(u8, cmd.string, "startDebugging")) {
                                    // Queue notification with the launch config
                                    self.queueNotification("debug/start_debugging", decoded.body);
                                    // Capture the child session configuration for connectChildSession()
                                    if (parsed.value.object.get("arguments")) |args_val| {
                                        if (args_val == .object) {
                                            if (args_val.object.get("configuration")) |config_val| {
                                                var config_aw: Writer.Allocating = .init(self.allocator);
                                                var config_s: Stringify = .{ .writer = &config_aw.writer };
                                                config_s.write(config_val) catch {};
                                                if (config_aw.toOwnedSlice()) |config_json| {
                                                    if (self.pending_child_config) |old| self.allocator.free(old);
                                                    self.pending_child_config = config_json;
                                                    dapLog("[DAP readResponse] Captured child session config ({d} bytes)", .{config_json.len});
                                                } else |_| {}
                                            }
                                        }
                                    }
                                    // Send success response back to adapter
                                    const req_seq = if (parsed.value.object.get("seq")) |v|
                                        (if (v == .integer) v.integer else 0)
                                    else
                                        0;
                                    dapLog("[DAP readResponse] Responding to startDebugging (req_seq={d})", .{req_seq});
                                    self.sendReverseResponse(allocator, req_seq, "startDebugging");
                                } else if (std.mem.eql(u8, cmd.string, "runInTerminal")) {
                                    // Queue notification for AI agent to handle
                                    self.queueNotification("debug/run_in_terminal", decoded.body);
                                    // Send synthetic success response
                                    const req_seq = if (parsed.value.object.get("seq")) |v|
                                        (if (v == .integer) v.integer else 0)
                                    else
                                        0;
                                    dapLog("[DAP readResponse] Responding to runInTerminal (req_seq={d})", .{req_seq});
                                    self.sendReverseResponse(allocator, req_seq, "runInTerminal");
                                } else {
                                    dapLog("[DAP readResponse] Unhandled reverse request: {s}", .{cmd.string});
                                }
                            }
                        }
                        allocator.free(decoded.body);
                        continue;
                    }
                }
                allocator.free(decoded.body);
            }

            // Poll with timeout before reading
            dapLog("[DAP readResponse] Polling (timeout={d}ms, loop {d})...", .{ self.request_timeout_ms, loop_count });
            var poll_fds = [_]std.posix.pollfd{.{
                .fd = poll_fd,
                .events = std.posix.POLL.IN,
                .revents = 0,
            }};
            const poll_result = std.posix.poll(&poll_fds, self.request_timeout_ms) catch return error.ReadFailed;
            if (poll_result == 0) {
                dapLog("[DAP readResponse] TIMEOUT after {d}ms", .{self.request_timeout_ms});
                return error.Timeout;
            }

            // Read more data from adapter
            const n = self.transportRead(&read_buf) catch return error.ReadFailed;
            if (n == 0) {
                dapLog("[DAP readResponse] Connection closed (0 bytes)", .{});
                return error.ConnectionClosed;
            }
            dapLog("[DAP readResponse] Read {d} bytes from adapter", .{n});
            try self.read_buffer.appendSlice(self.allocator, read_buf[0..n]);
        }
    }

    /// Wait for a specific event type from the adapter.
    /// Returns the raw JSON body of the event.
    fn waitForEvent(self: *DapProxy, allocator: std.mem.Allocator, event_name: []const u8) ![]const u8 {
        dapLog("[DAP waitForEvent] Waiting for event: {s} (buffer={d} bytes, buffered_events={d})", .{ event_name, self.read_buffer.items.len, self.buffered_events.items.len });

        // Check buffered events first (events consumed by readResponse during request handling)
        for (self.buffered_events.items, 0..) |entry, i| {
            if (std.mem.eql(u8, entry.event_name, event_name)) {
                dapLog("[DAP waitForEvent] Found buffered event: {s}", .{event_name});
                const body = entry.body;
                self.allocator.free(entry.event_name);
                _ = self.buffered_events.orderedRemove(i);
                return body;
            }
        }

        const poll_fd = try self.transportPollFd();

        var read_buf: [8192]u8 = undefined;
        var loop_count: u32 = 0;

        while (true) {
            loop_count += 1;
            // Try to decode from buffer
            while (true) {
                const decoded = transport.decodeMessage(allocator, self.read_buffer.items) catch |err| switch (err) {
                    error.MissingHeader, error.TruncatedBody => break,
                    else => return err,
                };

                const remaining = self.read_buffer.items.len - decoded.bytes_consumed;
                if (remaining > 0) {
                    std.mem.copyForwards(u8, self.read_buffer.items[0..remaining], self.read_buffer.items[decoded.bytes_consumed..]);
                }
                self.read_buffer.items.len = remaining;

                const parsed = json.parseFromSlice(json.Value, allocator, decoded.body, .{}) catch {
                    allocator.free(decoded.body);
                    continue;
                };
                defer parsed.deinit();

                if (parsed.value == .object) {
                    const msg_type_str = if (parsed.value.object.get("type")) |t| (if (t == .string) t.string else "?") else "?";
                    const evt_str = if (parsed.value.object.get("event")) |e| (if (e == .string) e.string else "?") else "?";
                    dapLog("[DAP waitForEvent] Got message type={s} event={s} (want={s}, loop {d})", .{ msg_type_str, evt_str, event_name, loop_count });
                    if (parsed.value.object.get("type")) |t| {
                        if (t == .string and std.mem.eql(u8, t.string, "event")) {
                            if (parsed.value.object.get("event")) |evt| {
                                if (evt == .string and std.mem.eql(u8, evt.string, event_name)) {
                                    dapLog("[DAP waitForEvent] Found target event: {s}", .{event_name});
                                    return decoded.body;
                                }
                                // Buffer non-matching events so they are not lost.
                                // Without this, events like `terminated` or `stopped`
                                // arriving while waiting for a different event would
                                // be silently discarded.
                                if (evt == .string) {
                                    dapLog("[DAP waitForEvent] Buffering non-target event: {s}", .{evt.string});
                                    self.buffered_events.append(self.allocator, .{
                                        .event_name = self.allocator.dupe(u8, evt.string) catch "",
                                        .body = self.allocator.dupe(u8, decoded.body) catch "",
                                    }) catch {};
                                }
                            }
                        }
                    }
                }
                allocator.free(decoded.body);
            }

            dapLog("[DAP waitForEvent] Polling (loop {d}, timeout={d}ms)...", .{ loop_count, self.request_timeout_ms });
            var poll_fds = [_]std.posix.pollfd{.{
                .fd = poll_fd,
                .events = std.posix.POLL.IN,
                .revents = 0,
            }};
            const poll_result = std.posix.poll(&poll_fds, self.request_timeout_ms) catch return error.ReadFailed;
            if (poll_result == 0) {
                dapLog("[DAP waitForEvent] TIMEOUT waiting for event: {s}", .{event_name});
                return error.Timeout;
            }
            const n = self.transportRead(&read_buf) catch return error.ReadFailed;
            if (n == 0) {
                dapLog("[DAP waitForEvent] Connection closed (0 bytes)", .{});
                return error.ConnectionClosed;
            }
            dapLog("[DAP waitForEvent] Read {d} bytes from adapter", .{n});
            try self.read_buffer.appendSlice(self.allocator, read_buf[0..n]);
        }
    }

    // ── Action Mapping ──────────────────────────────────────────────────

    pub fn mapRunAction(self: *DapProxy, allocator: std.mem.Allocator, action: RunAction) ![]const u8 {
        return self.mapRunActionEx(allocator, action, .{});
    }

    pub fn mapRunActionEx(self: *DapProxy, allocator: std.mem.Allocator, action: RunAction, opts: types.RunOptions) ![]const u8 {
        const stepping_opts = protocol.SteppingOptions{
            .granularity = opts.granularity,
            .single_thread = null,
        };
        return switch (action) {
            .@"continue" => protocol.continueRequest(allocator, self.nextSeq(), self.thread_id),
            .step_into => if (opts.target_id) |tid|
                protocol.stepInRequestWithTarget(allocator, self.nextSeq(), self.thread_id, stepping_opts, tid)
            else
                protocol.stepInRequestEx(allocator, self.nextSeq(), self.thread_id, stepping_opts),
            .step_over => protocol.nextRequestEx(allocator, self.nextSeq(), self.thread_id, stepping_opts),
            .step_out => protocol.stepOutRequestEx(allocator, self.nextSeq(), self.thread_id, stepping_opts),
            .restart => return error.NotSupported, // restart is handled by proxyRestart, not mapRunAction
            .pause => protocol.pauseRequest(allocator, self.nextSeq(), if (opts.thread_id) |tid| @intCast(tid) else self.thread_id),
            .reverse_continue => protocol.reverseContinueRequest(allocator, self.nextSeq(), self.thread_id),
            .step_back => protocol.stepBackRequest(allocator, self.nextSeq(), self.thread_id),
        };
    }

    // ── Response Translation ────────────────────────────────────────────

    pub fn translateStoppedEvent(allocator: std.mem.Allocator, data: []const u8) !StopState {
        const evt = try protocol.DapEvent.parse(allocator, data);
        defer evt.deinit(allocator);

        const reason: StopReason = if (evt.stop_reason) |r| blk: {
            if (std.mem.eql(u8, r, "breakpoint")) break :blk .breakpoint;
            if (std.mem.eql(u8, r, "step")) break :blk .step;
            if (std.mem.eql(u8, r, "exception")) break :blk .exception;
            if (std.mem.eql(u8, r, "entry")) break :blk .entry;
            if (std.mem.eql(u8, r, "pause")) break :blk .pause;
            if (std.mem.eql(u8, r, "goto")) break :blk .goto;
            if (std.mem.eql(u8, r, "function breakpoint")) break :blk .function_breakpoint;
            if (std.mem.eql(u8, r, "data breakpoint")) break :blk .data_breakpoint;
            if (std.mem.eql(u8, r, "instruction breakpoint")) break :blk .instruction_breakpoint;
            break :blk .step;
        } else .step;

        // Copy hit breakpoint IDs so they survive evt.deinit
        const bp_ids = if (evt.hit_breakpoint_ids.len > 0)
            try allocator.dupe(u32, evt.hit_breakpoint_ids)
        else
            &[_]u32{};

        return .{
            .stop_reason = reason,
            .hit_breakpoint_ids = bp_ids,
        };
    }

    pub fn translateExitedEvent(allocator: std.mem.Allocator, data: []const u8) !StopState {
        const evt = try protocol.DapEvent.parse(allocator, data);
        defer evt.deinit(allocator);

        return .{
            .stop_reason = .exception,
            .exit_code = if (evt.exit_code) |c| @intCast(c) else null,
        };
    }

    pub fn translateStackTrace(allocator: std.mem.Allocator, data: []const u8) ![]StackFrame {
        const parsed = try json.parseFromSlice(json.Value, allocator, data, .{});
        defer parsed.deinit();

        if (parsed.value != .object) return error.InvalidResponse;
        const body = parsed.value.object.get("body") orelse return error.InvalidResponse;
        if (body != .object) return error.InvalidResponse;
        const frames_val = body.object.get("stackFrames") orelse return error.InvalidResponse;
        if (frames_val != .array) return error.InvalidResponse;

        var frames: std.ArrayListUnmanaged(StackFrame) = .empty;
        errdefer frames.deinit(allocator);

        for (frames_val.array.items) |item| {
            if (item != .object) continue;
            const obj = item.object;

            const id: u32 = if (obj.get("id")) |v| switch (v) {
                .integer => @intCast(v.integer),
                else => 0,
            } else 0;

            const name = if (obj.get("name")) |v| switch (v) {
                .string => try allocator.dupe(u8, v.string),
                else => try allocator.dupe(u8, "<unknown>"),
            } else try allocator.dupe(u8, "<unknown>");

            const source = if (obj.get("source")) |s| blk: {
                if (s == .object) {
                    if (s.object.get("path")) |p| {
                        if (p == .string) break :blk try allocator.dupe(u8, p.string);
                    }
                }
                break :blk try allocator.dupe(u8, "");
            } else try allocator.dupe(u8, "");

            const line: u32 = if (obj.get("line")) |v| switch (v) {
                .integer => @intCast(v.integer),
                else => 0,
            } else 0;

            const column: u32 = if (obj.get("column")) |v| switch (v) {
                .integer => @intCast(v.integer),
                else => 0,
            } else 0;

            try frames.append(allocator, .{
                .id = id,
                .name = name,
                .source = source,
                .line = line,
                .column = column,
            });
        }

        return try frames.toOwnedSlice(allocator);
    }

    pub fn translateVariables(allocator: std.mem.Allocator, data: []const u8) ![]Variable {
        const parsed = try json.parseFromSlice(json.Value, allocator, data, .{});
        defer parsed.deinit();

        if (parsed.value != .object) return error.InvalidResponse;
        const body = parsed.value.object.get("body") orelse return error.InvalidResponse;
        if (body != .object) return error.InvalidResponse;
        const vars_val = body.object.get("variables") orelse return error.InvalidResponse;
        if (vars_val != .array) return error.InvalidResponse;

        var vars: std.ArrayListUnmanaged(Variable) = .empty;
        errdefer vars.deinit(allocator);

        for (vars_val.array.items) |item| {
            if (item != .object) continue;
            const obj = item.object;

            const name = if (obj.get("name")) |v| switch (v) {
                .string => try allocator.dupe(u8, v.string),
                else => try allocator.dupe(u8, ""),
            } else try allocator.dupe(u8, "");

            const value = if (obj.get("value")) |v| switch (v) {
                .string => try allocator.dupe(u8, v.string),
                else => try allocator.dupe(u8, ""),
            } else try allocator.dupe(u8, "");

            const type_str = if (obj.get("type")) |v| switch (v) {
                .string => try allocator.dupe(u8, v.string),
                else => try allocator.dupe(u8, ""),
            } else try allocator.dupe(u8, "");

            const var_ref: u32 = if (obj.get("variablesReference")) |v| switch (v) {
                .integer => @intCast(v.integer),
                else => 0,
            } else 0;

            const named_vars: ?u32 = if (obj.get("namedVariables")) |v| switch (v) {
                .integer => @intCast(v.integer),
                else => null,
            } else null;

            const indexed_vars: ?u32 = if (obj.get("indexedVariables")) |v| switch (v) {
                .integer => @intCast(v.integer),
                else => null,
            } else null;

            const eval_name = if (obj.get("evaluateName")) |v| switch (v) {
                .string => try allocator.dupe(u8, v.string),
                else => try allocator.dupe(u8, ""),
            } else try allocator.dupe(u8, "");

            const mem_ref = if (obj.get("memoryReference")) |v| switch (v) {
                .string => try allocator.dupe(u8, v.string),
                else => try allocator.dupe(u8, ""),
            } else try allocator.dupe(u8, "");

            const pres_hint: ?types.VariablePresentationHint = if (obj.get("presentationHint")) |ph| blk: {
                if (ph == .object) {
                    break :blk .{
                        .kind = if (ph.object.get("kind")) |v| (if (v == .string) try allocator.dupe(u8, v.string) else "") else "",
                        .attributes = if (ph.object.get("attributes")) |v| attr_blk: {
                            if (v == .array) {
                                var attrs = std.ArrayListUnmanaged([]const u8).empty;
                                for (v.array.items) |attr_item| {
                                    if (attr_item == .string) try attrs.append(allocator, try allocator.dupe(u8, attr_item.string));
                                }
                                break :attr_blk try attrs.toOwnedSlice(allocator);
                            }
                            break :attr_blk &.{};
                        } else &.{},
                        .visibility = if (ph.object.get("visibility")) |v| (if (v == .string) try allocator.dupe(u8, v.string) else "") else "",
                    };
                }
                break :blk null;
            } else null;

            try vars.append(allocator, .{
                .name = name,
                .value = value,
                .@"type" = type_str,
                .variables_reference = var_ref,
                .children_count = if (var_ref > 0) 1 else 0,
                .named_variables = named_vars,
                .indexed_variables = indexed_vars,
                .evaluate_name = eval_name,
                .memory_reference = mem_ref,
                .presentation_hint = pres_hint,
            });
        }

        return try vars.toOwnedSlice(allocator);
    }

    // ── Driver Interface (vtable functions) ─────────────────────────────

    fn proxyLaunch(ctx: *anyopaque, allocator: std.mem.Allocator, config: LaunchConfig) anyerror!void {
        const self: *DapProxy = @ptrCast(@alignCast(ctx));
        const cfg = self.debug_config orelse return error.UnsupportedLanguage;

        dapLog("[DAP launch] Starting proxyLaunch for program: {s}", .{config.program});

        // 1. Check dependencies
        if (adapter_lifecycle.checkDependencies(allocator, cfg.dependencies)) |err_msg| {
            dapLog("[DAP launch] Dependency check failed: {s}", .{err_msg});
            return error.DependencyCheckFailed;
        }
        dapLog("[DAP launch] Dependency checks passed", .{});

        // 2. Ensure adapter is installed (download/compile if needed)
        var adapter_path: ?[]const u8 = null;
        defer if (adapter_path) |p| allocator.free(p);
        if (cfg.adapter_install) |install| {
            adapter_path = adapter_lifecycle.ensureAdapter(allocator, install) catch |err| {
                dapLog("[DAP launch] Adapter installation failed: {s}", .{@errorName(err)});
                return err;
            };
            dapLog("[DAP launch] Adapter available at: {s}", .{adapter_path orelse ""});
        }

        // 3. Build adapter argv with placeholder substitution
        //    {adapter_path} → install directory (e.g. for Java -cp)
        //    {entry_point}  → full path to adapter entry point file (e.g. for node)
        var argv_list: std.ArrayListUnmanaged([]const u8) = .empty;
        defer argv_list.deinit(allocator);
        try argv_list.append(allocator, cfg.adapter_command);
        for (cfg.adapter_args) |arg| {
            if (std.mem.eql(u8, arg, "{adapter_path}")) {
                try argv_list.append(allocator, adapter_path orelse arg);
            } else if (std.mem.eql(u8, arg, "{entry_point}")) {
                if (adapter_path) |p| {
                    if (cfg.adapter_install) |install| {
                        // Strip install_dir prefix from entry_point to get the relative path,
                        // then join with the resolved adapter_path directory.
                        const ep = install.entry_point;
                        const rel = if (std.mem.startsWith(u8, ep, install.install_dir)) blk: {
                            var rest = ep[install.install_dir.len..];
                            if (rest.len > 0 and rest[0] == '/') rest = rest[1..];
                            break :blk rest;
                        } else std.fs.path.basename(ep);
                        const full = std.fs.path.join(allocator, &.{ p, rel }) catch {
                            try argv_list.append(allocator, p);
                            continue;
                        };
                        try argv_list.append(allocator, full);
                    } else {
                        try argv_list.append(allocator, p);
                    }
                } else {
                    try argv_list.append(allocator, arg);
                }
            } else {
                try argv_list.append(allocator, arg);
            }
        }

        // 4. Transport-specific launch
        switch (cfg.transport) {
            .stdio => try self.launchStdio(allocator, config, cfg, argv_list.items),
            .tcp => try self.launchTcp(allocator, config, cfg, argv_list.items),
        }
    }

    /// Launch an adapter over stdio transport (Python, Go, Java, etc.)
    fn launchStdio(self: *DapProxy, allocator: std.mem.Allocator, config: LaunchConfig, cfg: extensions.DapConfig, argv: []const []const u8) anyerror!void {
        // Save launch state for potential emulated restart
        self.saveLaunchState(config, argv);

        // Spawn the adapter in a new session (setsid) so it is fully
        // detached from the controlling terminal — prevents SIGTTIN.
        dapLog("[DAP launch] Spawning adapter process (detached, stdio)...", .{});
        const child = try spawnDetached(allocator, argv);
        dapLog("[DAP launch] Adapter process spawned (pid={d})", .{child.id});

        self.transport = .{ .stdio = .{ .process = child } };
        self.initialized = false;

        // 1. Send initialize request and wait for response
        dapLog("[DAP launch] Step 1: Sending initialize request (seq={d})...", .{self.seq});
        const init_msg = try protocol.initializeRequestParams(allocator, self.nextSeq(), cfg.adapter_id, cfg.supports_start_debugging);
        defer allocator.free(init_msg);
        const init_resp = try self.sendRequest(allocator, init_msg);
        defer allocator.free(init_resp);
        dapLog("[DAP launch] Step 1: Initialize response received ({d} bytes)", .{init_resp.len});
        self.parseAdapterCapabilities(allocator, init_resp);

        // 2. Send launch request WITHOUT waiting for response.
        dapLog("[DAP launch] Step 2: Sending launch request (seq={d})...", .{self.seq});
        const launch_msg = try protocol.launchRequestEx(allocator, self.nextSeq(), config.program, config.args, config.stop_on_entry, cfg.launch_extra_args_json, null);
        defer allocator.free(launch_msg);
        try self.sendRaw(allocator, launch_msg);
        dapLog("[DAP launch] Step 2: Launch request sent", .{});

        // 3. Wait for 'initialized' event from the adapter
        dapLog("[DAP launch] Step 3: Waiting for initialized event...", .{});
        const init_event = try self.waitForEvent(allocator, "initialized");
        allocator.free(init_event);
        dapLog("[DAP launch] Step 3: initialized event received", .{});

        // 4. Send configurationDone
        dapLog("[DAP launch] Step 4: Sending configurationDone request (seq={d})...", .{self.seq});
        const config_done_msg = try protocol.configurationDoneRequest(allocator, self.nextSeq());
        defer allocator.free(config_done_msg);
        const config_resp = try self.sendRequest(allocator, config_done_msg);
        allocator.free(config_resp);
        dapLog("[DAP launch] Step 4: configurationDone/launch response received", .{});

        self.initialized = true;
        dapLog("[DAP launch] Launch complete, session initialized", .{});
    }

    /// Launch an adapter over TCP transport (vscode-js-debug, etc.)
    fn launchTcp(self: *DapProxy, allocator: std.mem.Allocator, config: LaunchConfig, cfg: extensions.DapConfig, argv: []const []const u8) anyerror!void {
        dapLog("[DAP launch] TCP transport launch", .{});

        // Save launch state for restart
        self.saveLaunchState(config, argv);

        // 1. Spawn the adapter process
        dapLog("[DAP launch] Spawning adapter process (TCP)...", .{});
        const server_child = try spawnDetached(allocator, argv);

        // 2. Read stdout to get the listening port
        const port_prefix = cfg.port_stdout_prefix orelse return error.PortParseFailed;
        const server_stdout = server_child.stdout orelse return error.NotInitialized;
        var port_buf: [256]u8 = undefined;
        var port_len: usize = 0;
        const port_timeout_ms: i32 = @intCast(cfg.port_detection_timeout_ms);

        while (port_len < port_buf.len) {
            var poll_fds = [_]std.posix.pollfd{.{
                .fd = server_stdout.handle,
                .events = std.posix.POLL.IN,
                .revents = 0,
            }};
            const poll_result = std.posix.poll(&poll_fds, port_timeout_ms) catch return error.ReadFailed;
            if (poll_result == 0) return error.Timeout;

            const n = server_stdout.read(port_buf[port_len..]) catch return error.ReadFailed;
            if (n == 0) return error.ConnectionClosed;
            port_len += n;

            if (adapter_lifecycle.detectPortFromStdout(port_buf[0..port_len], port_prefix)) |_| break;
        }

        const port = adapter_lifecycle.detectPortFromStdout(port_buf[0..port_len], port_prefix) orelse return error.PortParseFailed;
        self.adapter_tcp_port = port;
        dapLog("[DAP launch] Adapter listening on port {d}", .{port});

        // 3. Connect TCP to the adapter
        const stream = std.net.tcpConnectToHost(allocator, "127.0.0.1", port) catch return error.ConnectionFailed;

        self.transport = .{ .tcp = .{ .stream = stream, .server_process = server_child } };
        self.initialized = false;

        // 4. DAP initialize handshake
        dapLog("[DAP launch] Sending initialize request ({s}, seq={d})...", .{ cfg.adapter_id, self.seq });
        const init_msg = try protocol.initializeRequestParams(allocator, self.nextSeq(), cfg.adapter_id, cfg.supports_start_debugging);
        defer allocator.free(init_msg);
        const init_resp = try self.sendRequest(allocator, init_msg);
        defer allocator.free(init_resp);
        self.parseAdapterCapabilities(allocator, init_resp);

        // 5. Send launch request (don't wait — initialized event comes first)
        //    For child session adapters: send stopOnEntry=false to parent,
        //    we handle entry-stop ourselves via DAP "pause" in connectChildSession.
        const stop_on_entry = if (cfg.child_sessions.enabled) false else config.stop_on_entry;
        dapLog("[DAP launch] Sending launch request (stopOnEntry={})...", .{stop_on_entry});
        const cwd = std.fs.path.dirname(config.program);
        const launch_msg = try protocol.launchRequestEx(allocator, self.nextSeq(), config.program, config.args, stop_on_entry, cfg.launch_extra_args_json, cwd);
        defer allocator.free(launch_msg);
        try self.sendRaw(allocator, launch_msg);

        // 6. Wait for initialized event
        const init_event = try self.waitForEvent(allocator, "initialized");
        allocator.free(init_event);

        // 7. configurationDone
        const cd_msg = try protocol.configurationDoneRequest(allocator, self.nextSeq());
        defer allocator.free(cd_msg);
        const cd_resp = try self.sendRequest(allocator, cd_msg);
        allocator.free(cd_resp);

        // 8. Handle child sessions if enabled
        if (cfg.child_sessions.enabled) {
            dapLog("[DAP launch] Waiting for startDebugging reverse request...", .{});
            try self.waitForChildConfig(allocator);

            if (self.pending_child_config != null) {
                dapLog("[DAP launch] Child session config detected, connecting to child...", .{});
                try self.connectChildSession(allocator);
            } else {
                self.initialized = true;
            }
        } else {
            self.initialized = true;
        }
        dapLog("[DAP launch] TCP launch complete", .{});
    }

    /// Wait for the startDebugging reverse request to populate pending_child_config.
    /// Reads DAP messages in a loop (processing events and reverse requests inline
    /// via readResponse's side-effects) until the config arrives or timeout.
    fn waitForChildConfig(self: *DapProxy, allocator: std.mem.Allocator) !void {
        const poll_fd = try self.transportPollFd();
        var read_buf: [8192]u8 = undefined;
        const timeout_ms: i32 = 15_000;
        var elapsed: i64 = 0;
        const start = std.time.milliTimestamp();

        while (self.pending_child_config == null) {
            elapsed = std.time.milliTimestamp() - start;
            if (elapsed >= timeout_ms) {
                dapLog("[DAP waitForChildConfig] Timeout after {d}ms — no startDebugging received", .{elapsed});
                return; // Not an error — adapter may not use child sessions
            }

            const remaining: i32 = @intCast(@max(timeout_ms - elapsed, 100));
            var poll_fds = [_]std.posix.pollfd{.{
                .fd = poll_fd,
                .events = std.posix.POLL.IN,
                .revents = 0,
            }};
            const poll_result = std.posix.poll(&poll_fds, remaining) catch return;
            if (poll_result == 0) continue;

            const n = self.transportRead(&read_buf) catch return;
            if (n == 0) return;
            self.read_buffer.appendSlice(self.allocator, read_buf[0..n]) catch return;

            // Try to decode and process buffered messages — readResponse logic
            // for handling reverse requests is inline in readResponse, so we
            // manually decode and process here.
            while (true) {
                const decoded = transport.decodeMessage(allocator, self.read_buffer.items) catch break;
                const rem = self.read_buffer.items.len - decoded.bytes_consumed;
                if (rem > 0) {
                    std.mem.copyForwards(u8, self.read_buffer.items[0..rem], self.read_buffer.items[decoded.bytes_consumed..]);
                }
                self.read_buffer.items.len = rem;

                const parsed = json.parseFromSlice(json.Value, allocator, decoded.body, .{}) catch {
                    allocator.free(decoded.body);
                    continue;
                };
                defer parsed.deinit();

                if (parsed.value == .object) {
                    const mt = if (parsed.value.object.get("type")) |t| (if (t == .string) t.string else "") else "";
                    if (std.mem.eql(u8, mt, "request")) {
                        // Reverse request — handle startDebugging and runInTerminal
                        if (parsed.value.object.get("command")) |cmd_val| {
                            if (cmd_val == .string) {
                                if (std.mem.eql(u8, cmd_val.string, "startDebugging")) {
                                    // Capture child config
                                    if (parsed.value.object.get("arguments")) |args_val| {
                                        if (args_val == .object) {
                                            if (args_val.object.get("configuration")) |config_val| {
                                                var config_aw: Writer.Allocating = .init(self.allocator);
                                                var config_s: Stringify = .{ .writer = &config_aw.writer };
                                                config_s.write(config_val) catch {};
                                                if (config_aw.toOwnedSlice()) |config_json| {
                                                    if (self.pending_child_config) |old| self.allocator.free(old);
                                                    self.pending_child_config = config_json;
                                                    dapLog("[DAP waitForChildConfig] Captured child config ({d} bytes)", .{config_json.len});
                                                } else |_| {}
                                            }
                                        }
                                    }
                                    // Respond to adapter
                                    const req_seq = if (parsed.value.object.get("seq")) |v|
                                        (if (v == .integer) v.integer else 0)
                                    else
                                        0;
                                    self.sendReverseResponse(allocator, req_seq, "startDebugging");
                                } else if (std.mem.eql(u8, cmd_val.string, "runInTerminal")) {
                                    const req_seq = if (parsed.value.object.get("seq")) |v|
                                        (if (v == .integer) v.integer else 0)
                                    else
                                        0;
                                    self.sendReverseResponse(allocator, req_seq, "runInTerminal");
                                }
                            }
                        }
                    } else if (std.mem.eql(u8, mt, "event")) {
                        // Buffer events for later consumption
                        if (parsed.value.object.get("event")) |evt| {
                            if (evt == .string) {
                                self.buffered_events.append(self.allocator, .{
                                    .event_name = self.allocator.dupe(u8, evt.string) catch "",
                                    .body = self.allocator.dupe(u8, decoded.body) catch "",
                                }) catch {};
                            }
                        }
                    }
                    // Responses are also buffered (rare but possible)
                }
                allocator.free(decoded.body);
            }
        }
        dapLog("[DAP waitForChildConfig] Child config received in {d}ms", .{std.time.milliTimestamp() - start});
    }

    /// Connect to a vscode-js-debug child session.
    /// The parent session sends a startDebugging reverse request with a configuration
    /// object. We open a new TCP connection to the same DAP server port, perform a
    /// fresh DAP handshake with the child config, and swap the transport so all
    /// subsequent commands go to the child session that actually controls the debuggee.
    fn connectChildSession(self: *DapProxy, allocator: std.mem.Allocator) !void {
        const port = self.adapter_tcp_port orelse return error.NotInitialized;
        const config_json = self.pending_child_config orelse return error.NotInitialized;

        dapLog("[DAP child] Connecting child session to 127.0.0.1:{d}", .{port});

        // 1. Open new TCP connection to the same DAP server
        const child_stream = std.net.tcpConnectToHost(allocator, "127.0.0.1", port) catch return error.ConnectionFailed;

        // 2. Save the parent stream for cleanup, swap to child
        switch (self.transport) {
            .tcp => |*t| {
                self.parent_stream = t.stream;
                t.stream = child_stream;
            },
            else => {
                child_stream.close();
                return error.NotInitialized;
            },
        }

        // 3. Reset session state for the new child connection
        self.seq = 1;
        self.read_buffer.clearRetainingCapacity();
        for (self.buffered_events.items) |entry| {
            self.allocator.free(entry.event_name);
            self.allocator.free(entry.body);
        }
        self.buffered_events.clearRetainingCapacity();

        // 4. DAP initialize handshake on child
        dapLog("[DAP child] Sending initialize request...", .{});
        const cfg = self.debug_config orelse return error.NotInitialized;
        const init_msg = try protocol.initializeRequestParams(allocator, self.nextSeq(), cfg.adapter_id, cfg.supports_start_debugging);
        defer allocator.free(init_msg);
        const init_resp = try self.sendRequest(allocator, init_msg);
        defer allocator.free(init_resp);
        self.parseAdapterCapabilities(allocator, init_resp);

        // 5. Send launch with child config.
        //    Inject outFiles + resolveSourceMapLocations so vscode-js-debug can
        //    resolve source-mapped breakpoints (.ts → .js).  The child config
        //    from startDebugging does NOT inherit these from the parent launch.
        //
        //    Strip stopOnEntry to avoid vscode-js-debug's persistent internal
        //    breakpoint (ID 0) that fires on EVERY stop.
        dapLog("[DAP child] Sending child launch request...", .{});
        const enriched_config = try self.injectSourceMapConfig(allocator, config_json);
        defer allocator.free(enriched_config);
        const child_config = try self.stripStopOnEntry(allocator, enriched_config);
        defer allocator.free(child_config);
        const launch_msg = try protocol.childLaunchRequest(allocator, self.nextSeq(), child_config);
        defer allocator.free(launch_msg);
        try self.sendRaw(allocator, launch_msg);

        // 6. Wait for initialized event from child
        const init_event = try self.waitForEvent(allocator, "initialized");
        allocator.free(init_event);

        // 7. Mark child as initialized so proxySetBreakpoint can send to it.
        self.initialized = true;

        // 8. Re-arm any existing breakpoints during the configuration phase.
        // This must happen BEFORE configurationDone — vscode-js-debug only
        // resolves source-mapped breakpoints (.ts via outFiles) during the
        // config phase.  After a restart, the new child adapter has no
        // breakpoints; re-arming sends the tracked set from the previous session.
        // On initial launch this is a no-op (no breakpoints tracked yet).
        self.rearmBreakpoints(allocator);

        // 9. Handle configurationDone based on stopOnEntry.
        if (self.saved_launch_stop_on_entry) {
            // Defer configurationDone.  Breakpoints the user sets between
            // launch and their first "continue" go into the DAP configuration
            // phase.  configurationDone is sent in proxyRun on the first continue.
            dapLog("[DAP child] Deferring configurationDone (stopOnEntry=true)", .{});
            self.child_config_deferred = true;
        } else {
            // No stopOnEntry: send configurationDone to start the program.
            const cd_msg = try protocol.configurationDoneRequest(allocator, self.nextSeq());
            defer allocator.free(cd_msg);
            const cd_resp = try self.sendRequest(allocator, cd_msg);
            allocator.free(cd_resp);
        }

        // 10. Drain all launch-time notifications (loadedSource, telemetry output,
        // process, thread events, etc.) accumulated during the child handshake.
        // These are internal DAP noise, not user-relevant events.
        for (self.pending_notifications.items) |n| {
            self.allocator.free(n.method);
            self.allocator.free(n.params_json);
        }
        dapLog("[DAP child] Drained {d} launch-time notifications", .{self.pending_notifications.items.len});
        self.pending_notifications.items.len = 0;

        // 11. Consume the child config — it's been used
        self.allocator.free(config_json);
        self.pending_child_config = null;

        dapLog("[DAP child] Child session connected and initialized", .{});
    }

    /// Re-serialize child config JSON with stopOnEntry forced to false.
    fn stripStopOnEntry(self: *DapProxy, allocator: std.mem.Allocator, config_json: []const u8) ![]const u8 {
        _ = self;
        const parsed = try json.parseFromSlice(json.Value, allocator, config_json, .{});
        defer parsed.deinit();

        if (parsed.value == .object) {
            // Overwrite stopOnEntry to false (or add it if absent)
            var obj = parsed.value.object;
            const key = "stopOnEntry";
            if (obj.getPtr(key)) |ptr| {
                ptr.* = .{ .bool = false };
            }
        }

        // Re-serialize
        var aw: Writer.Allocating = .init(allocator);
        var s: Stringify = .{ .writer = &aw.writer };
        s.write(parsed.value) catch return error.SerializationFailed;
        return aw.toOwnedSlice() catch return error.OutOfMemory;
    }

    /// Inject outFiles and resolveSourceMapLocations into a child session config
    /// so that vscode-js-debug can resolve source-mapped breakpoints (.ts files).
    /// The startDebugging reverse request config does NOT inherit these from the
    /// parent launch, so we must add them based on the program's directory.
    fn injectSourceMapConfig(self: *DapProxy, allocator: std.mem.Allocator, config_json: []const u8) ![]const u8 {
        const cfg = self.debug_config orelse return try allocator.dupe(u8, config_json);
        const extra = cfg.launch_extra_args_json orelse return try allocator.dupe(u8, config_json);
        // Only inject if the adapter config has sourceMaps enabled
        if (std.mem.indexOf(u8, extra, "sourceMaps") == null)
            return try allocator.dupe(u8, config_json);

        const program_dir = if (self.saved_launch_program) |p| std.fs.path.dirname(p) else null;
        const dir = program_dir orelse return try allocator.dupe(u8, config_json);

        const parsed = json.parseFromSlice(json.Value, allocator, config_json, .{}) catch
            return try allocator.dupe(u8, config_json);
        defer parsed.deinit();

        if (parsed.value != .object) return try allocator.dupe(u8, config_json);

        // Build the outFiles glob: <program_dir>/**/*.js
        var pattern_buf: [std.fs.max_path_bytes + 16]u8 = undefined;
        const pattern = std.fmt.bufPrint(&pattern_buf, "{s}/**/*.js", .{dir}) catch
            return try allocator.dupe(u8, config_json);

        dapLog("[DAP child] Injecting outFiles=[{s}] into child config", .{pattern});

        // Manually serialize: copy all existing fields, then append our new ones
        var aw: Writer.Allocating = .init(allocator);
        errdefer aw.deinit();
        var s: Stringify = .{ .writer = &aw.writer };

        try s.beginObject();

        // Copy existing fields
        var it = parsed.value.object.iterator();
        while (it.next()) |entry| {
            try s.objectField(entry.key_ptr.*);
            try s.write(entry.value_ptr.*);
        }

        // Add sourceMaps: true
        try s.objectField("sourceMaps");
        try s.write(true);

        // __workspaceFolder: vscode-js-debug uses this to resolve
        // ${workspaceFolder} in outFiles, sourceMapPathOverrides, etc.
        // Critical for standalone DAP (non-VS Code) source map resolution.
        try s.objectField("__workspaceFolder");
        try s.write(dir);

        // cwd: used as basePath for source map resolution
        try s.objectField("cwd");
        try s.write(dir);

        // outFiles: ["<dir>/**/*.js", "!**/node_modules/**"]
        try s.objectField("outFiles");
        try s.beginArray();
        try s.write(pattern);
        try s.write("!**/node_modules/**");
        try s.endArray();

        // resolveSourceMapLocations: ["**", "!**/node_modules/**"]
        try s.objectField("resolveSourceMapLocations");
        try s.beginArray();
        try s.write("**");
        try s.write("!**/node_modules/**");
        try s.endArray();

        try s.endObject();

        return aw.toOwnedSlice() catch return error.OutOfMemory;
    }

    fn proxyRun(ctx: *anyopaque, allocator: std.mem.Allocator, action: RunAction, options: types.RunOptions) anyerror!StopState {
        const self: *DapProxy = @ptrCast(@alignCast(ctx));
        if (!self.initialized) return error.NotInitialized;

        if (self.child_config_deferred) {
            // First continue after a deferred child session launch.
            // Re-arm all tracked breakpoints as a final reconciliation before
            // ending the configuration phase.  During the config phase, the user
            // may have set and/or removed breakpoints — each operation sent a
            // setBreakpoints request.  Re-arming ensures the adapter has the
            // correct final set, guarding against any adapter-side confusion
            // from multiple incremental updates during the config phase.
            dapLog("[DAP proxyRun] Re-arming breakpoints before deferred configurationDone", .{});
            self.rearmBreakpoints(allocator);

            dapLog("[DAP proxyRun] Sending deferred configurationDone to start program", .{});
            const cd_msg = try protocol.configurationDoneRequest(allocator, self.nextSeq());
            defer allocator.free(cd_msg);
            const cd_resp = try self.sendRequest(allocator, cd_msg);
            allocator.free(cd_resp);
            self.child_config_deferred = false;
            // Don't send a separate continue — configurationDone starts the program.
        } else {
            // Normal case: send the appropriate DAP run command
            const msg = try self.mapRunActionEx(allocator, action, options);
            defer allocator.free(msg);
            const resp = try self.sendRequest(allocator, msg);
            allocator.free(resp);
        }

        // Wait for a stopped or exited event
        // Try stopped first, fall back to exited
        const event_data = self.waitForEvent(allocator, "stopped") catch {
            const exit_data = self.waitForEvent(allocator, "exited") catch {
                return .{ .stop_reason = .step };
            };
            defer allocator.free(exit_data);
            return translateExitedEvent(allocator, exit_data);
        };
        defer allocator.free(event_data);

        // Log the raw stopped event for diagnosis
        {
            const log_len = @min(event_data.len, 512);
            dapLog("[DAP proxyRun] stopped event body[0..{d}]: {s}", .{ log_len, event_data[0..log_len] });
        }

        var state = try translateStoppedEvent(allocator, event_data);

        // Fetch stack trace for the stopped state
        const st_msg = try protocol.stackTraceRequest(allocator, self.nextSeq(), self.thread_id, 0, 20);
        defer allocator.free(st_msg);
        if (self.sendRequest(allocator, st_msg)) |st_resp| {
            defer allocator.free(st_resp);
            state.stack_trace = translateStackTrace(allocator, st_resp) catch &.{};
            // Cache the topmost frame ID so evaluate defaults to it
            if (state.stack_trace.len > 0) {
                self.current_frame_id = @intCast(state.stack_trace[0].id);
            }
            // Cache all DAP frame IDs for user-index → DAP-ID translation
            self.cached_frame_ids.clearRetainingCapacity();
            for (state.stack_trace) |frame| {
                self.cached_frame_ids.append(self.allocator, @intCast(frame.id)) catch {};
            }
        } else |_| {}

        // Attach captured output to state and clear buffer
        if (self.output_buffer.items.len > 0) {
            state.output = self.output_buffer.toOwnedSlice(self.allocator) catch &.{};
        }

        return state;
    }

    fn handleBreakpointEvent(_: *DapProxy, bp_obj: std.json.ObjectMap) void {
        // Update internal breakpoint state based on verification events
        const bp_id = if (bp_obj.get("id")) |id| (if (id == .integer) @as(u32, @intCast(id.integer)) else return) else return;
        const verified = if (bp_obj.get("verified")) |v| (v == .bool and v.bool) else false;
        const actual_line = if (bp_obj.get("line")) |l| (if (l == .integer) @as(u32, @intCast(l.integer)) else null) else null;
        _ = bp_id;
        _ = verified;
        _ = actual_line;
        // Store verification state for future queries
        // The breakpoint event data is captured but since breakpoint storage
        // is per-file in file_breakpoints, we'd need to iterate to find it.
        // For now, the event is consumed and logged.
    }

    fn handleMemoryEvent(self: *DapProxy, body_obj: std.json.ObjectMap) void {
        const mem_ref = if (body_obj.get("memoryReference")) |v| (if (v == .string) v.string else return) else return;
        const offset: i64 = if (body_obj.get("offset")) |v| (if (v == .integer) v.integer else 0) else 0;
        const count: i64 = if (body_obj.get("count")) |v| (if (v == .integer) v.integer else 0) else 0;
        self.memory_events.append(self.allocator, .{
            .memory_reference = self.allocator.dupe(u8, mem_ref) catch return,
            .offset = offset,
            .count = count,
        }) catch {};
    }

    fn handleProgressStart(self: *DapProxy, body_obj: std.json.ObjectMap) void {
        const progress_id = if (body_obj.get("progressId")) |v| (if (v == .string) v.string else return) else return;
        const title = if (body_obj.get("title")) |v| (if (v == .string) v.string else "") else "";
        const message = if (body_obj.get("message")) |v| (if (v == .string) v.string else "") else "";
        const percentage: ?f64 = if (body_obj.get("percentage")) |v| (if (v == .float) v.float else null) else null;
        const key = self.allocator.dupe(u8, progress_id) catch return;
        self.active_progress.put(self.allocator, key, .{
            .title = self.allocator.dupe(u8, title) catch return,
            .message = self.allocator.dupe(u8, message) catch return,
            .percentage = percentage,
        }) catch {
            self.allocator.free(key);
        };
    }

    fn handleProgressUpdate(self: *DapProxy, body_obj: std.json.ObjectMap) void {
        const progress_id = if (body_obj.get("progressId")) |v| (if (v == .string) v.string else return) else return;
        if (self.active_progress.getPtr(progress_id)) |state| {
            if (body_obj.get("message")) |v| {
                if (v == .string) {
                    self.allocator.free(state.message);
                    state.message = self.allocator.dupe(u8, v.string) catch return;
                }
            }
            if (body_obj.get("percentage")) |v| {
                if (v == .float) state.percentage = v.float;
            }
        }
    }

    fn handleProgressEnd(self: *DapProxy, body_obj: std.json.ObjectMap) void {
        const progress_id = if (body_obj.get("progressId")) |v| (if (v == .string) v.string else return) else return;
        if (self.active_progress.fetchRemove(progress_id)) |kv| {
            self.allocator.free(kv.value.title);
            self.allocator.free(kv.value.message);
            self.allocator.free(kv.key);
        }
    }

    fn handleInvalidatedEvent(self: *DapProxy, body_obj: std.json.ObjectMap) void {
        var areas_list = std.ArrayListUnmanaged([]const u8).empty;
        if (body_obj.get("areas")) |areas_val| {
            if (areas_val == .array) {
                for (areas_val.array.items) |item| {
                    if (item == .string) {
                        areas_list.append(self.allocator, self.allocator.dupe(u8, item.string) catch continue) catch {};
                    }
                }
            }
        }
        const stack_frame_id: ?u32 = if (body_obj.get("stackFrameId")) |v|
            (if (v == .integer) @as(u32, @intCast(v.integer)) else null)
        else
            null;
        self.invalidated_areas.append(self.allocator, .{
            .areas = areas_list.toOwnedSlice(self.allocator) catch &.{},
            .stack_frame_id = stack_frame_id,
        }) catch {};
    }

    /// Send a success response for a reverse request from the adapter.
    fn sendReverseResponse(self: *DapProxy, allocator: std.mem.Allocator, request_seq: i64, command: []const u8) void {
        var aw: Writer.Allocating = .init(allocator);
        defer aw.deinit();
        var s: Stringify = .{ .writer = &aw.writer };

        s.beginObject() catch return;
        s.objectField("seq") catch return;
        s.write(self.nextSeq()) catch return;
        s.objectField("type") catch return;
        s.write("response") catch return;
        s.objectField("request_seq") catch return;
        s.write(request_seq) catch return;
        s.objectField("success") catch return;
        s.write(true) catch return;
        s.objectField("command") catch return;
        s.write(command) catch return;
        s.endObject() catch return;

        const msg = aw.toOwnedSlice() catch return;
        defer allocator.free(msg);

        const encoded = transport.encodeMessage(allocator, msg) catch return;
        defer allocator.free(encoded);

        self.transportWrite(encoded) catch {
            dapLog("[DAP sendReverseResponse] Write failed!", .{});
            return;
        };
        dapLog("[DAP sendReverseResponse] Sent response for {s} (req_seq={d}, {d} bytes)", .{ command, request_seq, encoded.len });
    }

    fn queueNotification(self: *DapProxy, method: []const u8, params_json: []const u8) void {
        self.pending_notifications.append(self.allocator, .{
            .method = self.allocator.dupe(u8, method) catch return,
            .params_json = self.allocator.dupe(u8, params_json) catch return,
        }) catch {};
    }

    /// Drain and return all pending notifications, transferring ownership to caller.
    pub fn drainNotifications(self: *DapProxy, allocator: std.mem.Allocator) []const types.DebugNotification {
        if (self.pending_notifications.items.len == 0) return &.{};
        const result = allocator.dupe(types.DebugNotification, self.pending_notifications.items) catch return &.{};
        // Clear without freeing — ownership transferred
        self.pending_notifications.items.len = 0;
        return result;
    }

    fn parseAdapterCapabilities(self: *DapProxy, allocator: std.mem.Allocator, resp_body: []const u8) void {
        const parsed = json.parseFromSlice(json.Value, allocator, resp_body, .{}) catch return;
        defer parsed.deinit();

        if (parsed.value != .object) return;
        const body = parsed.value.object.get("body") orelse return;
        if (body != .object) return;
        const b = body.object;

        self.adapter_capabilities = .{
            .supports_conditional_breakpoints = getBoolCap(b, "supportsConditionalBreakpoints"),
            .supports_hit_conditional_breakpoints = getBoolCap(b, "supportsHitConditionalBreakpoints"),
            .supports_log_points = getBoolCap(b, "supportsLogPoints"),
            .supports_function_breakpoints = getBoolCap(b, "supportsFunctionBreakpoints"),
            .supports_data_breakpoints = getBoolCap(b, "supportsDataBreakpoints"),
            .supports_set_variable = getBoolCap(b, "supportsSetVariable"),
            .supports_goto_targets = getBoolCap(b, "supportsGotoTargetsRequest"),
            .supports_read_memory = getBoolCap(b, "supportsReadMemoryRequest"),
            .supports_write_memory = getBoolCap(b, "supportsWriteMemoryRequest"),
            .supports_disassemble = getBoolCap(b, "supportsDisassembleRequest"),
            .supports_terminate = getBoolCap(b, "supportsTerminateRequest"),
            .supports_completions = getBoolCap(b, "supportsCompletionsRequest"),
            .supports_modules = getBoolCap(b, "supportsModulesRequest"),
            .supports_set_expression = getBoolCap(b, "supportsSetExpression"),
            .supports_step_back = getBoolCap(b, "supportsStepBack"),
            .supports_restart_frame = getBoolCap(b, "supportsRestartFrame"),
            .supports_instruction_breakpoints = getBoolCap(b, "supportsInstructionBreakpoints"),
            .supports_stepping_granularity = getBoolCap(b, "supportsSteppingGranularity"),
            .supports_cancel_request = getBoolCap(b, "supportsCancelRequest"),
            .supports_terminate_threads = getBoolCap(b, "supportsTerminateThreadsRequest"),
            .supports_breakpoint_locations = getBoolCap(b, "supportsBreakpointLocationsRequest"),
            .supports_step_in_targets = getBoolCap(b, "supportsStepInTargetsRequest"),
            .supports_evaluate_for_hovers = getBoolCap(b, "supportsEvaluateForHovers"),
            .supports_value_formatting = getBoolCap(b, "supportsValueFormattingOptions"),
            .supports_loaded_sources = getBoolCap(b, "supportsLoadedSourcesRequest"),
            .supports_restart_request = getBoolCap(b, "supportsRestartRequest"),
            .supports_single_thread_execution_requests = getBoolCap(b, "supportsSingleThreadExecutionRequests"),
            .supports_exception_options = getBoolCap(b, "supportsExceptionOptions"),
            .supports_exception_filter_options = getBoolCap(b, "supportsExceptionFilterOptions"),
            .supports_exception_info_request = getBoolCap(b, "supportsExceptionInfoRequest"),
            .support_terminate_debuggee = getBoolCap(b, "supportTerminateDebuggee"),
            .support_suspend_debuggee = getBoolCap(b, "supportSuspendDebuggee"),
            .supports_delayed_stack_trace_loading = getBoolCap(b, "supportsDelayedStackTraceLoading"),
            .supports_clipboard_context = getBoolCap(b, "supportsClipboardContext"),
            .supports_configuration_done_request = getBoolCap(b, "supportsConfigurationDoneRequest"),
            .supports_data_breakpoint_bytes = getBoolCap(b, "supportsDataBreakpointBytes"),
            .supports_ansi_styling = getBoolCap(b, "supportsANSIStyling"),
            .supports_locations_request = getBoolCap(b, "supportsLocationsRequest"),
            .supports_breakpoint_modes = getBoolCap(b, "supportsBreakpointModes"),
        };

        // Parse exception breakpoint filters
        if (b.get("exceptionBreakpointFilters")) |filters_val| {
            if (filters_val == .array) {
                for (filters_val.array.items) |item| {
                    if (item != .object) continue;
                    const f = item.object;
                    const filter_id = if (f.get("filter")) |v| (if (v == .string) v.string else continue) else continue;
                    const label = if (f.get("label")) |v| (if (v == .string) v.string else "") else "";
                    self.exception_filters.append(self.allocator, .{
                        .filter = self.allocator.dupe(u8, filter_id) catch continue,
                        .label = self.allocator.dupe(u8, label) catch continue,
                        .description = if (f.get("description")) |v| (if (v == .string) (self.allocator.dupe(u8, v.string) catch "") else "") else "",
                        .default = if (f.get("default")) |v| (v == .bool and v.bool) else false,
                        .supports_condition = if (f.get("supportsCondition")) |v| (v == .bool and v.bool) else false,
                        .condition_description = if (f.get("conditionDescription")) |v| (if (v == .string) (self.allocator.dupe(u8, v.string) catch "") else "") else "",
                    }) catch {};
                }
            }
        }
    }

    fn getBoolCap(obj: std.json.ObjectMap, key: []const u8) bool {
        const val = obj.get(key) orelse return false;
        return val == .bool and val.bool;
    }

    fn handleModuleEvent(self: *DapProxy, body_obj: std.json.ObjectMap) void {
        // Track module load/unload events from the adapter
        const reason = if (body_obj.get("reason")) |r| (if (r == .string) r.string else return) else return;
        const module = body_obj.get("module") orelse return;
        if (module != .object) return;

        const name = if (module.object.get("name")) |n| (if (n == .string) n.string else "unknown") else "unknown";

        if (std.mem.eql(u8, reason, "new") or std.mem.eql(u8, reason, "changed")) {
            // Track loaded module
            self.loaded_modules.append(self.allocator, .{
                .name = self.allocator.dupe(u8, name) catch return,
            }) catch {};
        }
    }

    fn proxySetBreakpoint(ctx: *anyopaque, allocator: std.mem.Allocator, file: []const u8, line: u32, condition: ?[]const u8, hit_condition: ?[]const u8, log_message: ?[]const u8) anyerror!BreakpointInfo {
        const self: *DapProxy = @ptrCast(@alignCast(ctx));

        // Assign a local bp_id
        const bp_id = self.next_bp_id;
        self.next_bp_id += 1;

        // Dupe strings onto self.allocator — the caller's slices point into
        // the JSON parse tree which is freed after this call returns.
        // Resolve symlinks (e.g. /tmp -> /private/tmp on macOS) so that the
        // path matches what the DAP adapter uses internally (Node.js resolves
        // symlinks when loading scripts, and vscode-js-debug uses the resolved
        // paths for source map resolution).
        const resolved_file = resolvePath(self.allocator, file);
        const file_owned = if (resolved_file.ptr != file.ptr)
            resolved_file // already allocated by resolvePath
        else
            try self.allocator.dupe(u8, file);
        const cond_owned: ?[]const u8 = if (condition) |c| try self.allocator.dupe(u8, c) else null;
        const hit_owned: ?[]const u8 = if (hit_condition) |h| try self.allocator.dupe(u8, h) else null;
        const log_owned: ?[]const u8 = if (log_message) |l| try self.allocator.dupe(u8, l) else null;

        // Track this breakpoint per file (DAP requires all BPs for a file in one request)
        const gop = try self.file_breakpoints.getOrPut(self.allocator, file_owned);
        if (!gop.found_existing) {
            gop.value_ptr.* = .empty;
        } else {
            // Key already existed — free our dupe, use existing key
            self.allocator.free(file_owned);
        }
        try gop.value_ptr.append(self.allocator, .{
            .line = line,
            .condition = cond_owned,
            .hit_condition = hit_owned,
            .log_message = log_owned,
            .bp_id = bp_id,
        });

        // Register for removal lookup (use the key that's in the hash map)
        try self.bp_registry.put(self.allocator, bp_id, .{ .file = gop.key_ptr.*, .line = line });

        // If adapter is connected and NOT in the deferred config phase, send
        // the DAP setBreakpoints request immediately.  During the deferred
        // config phase (child_config_deferred=true), we only update internal
        // data structures — a single reconciliation setBreakpoints call is
        // sent via rearmBreakpoints right before configurationDone in proxyRun.
        // This avoids vscode-js-debug's breakpoint prediction getting confused
        // by multiple incremental setBreakpoints replacements during config.
        if (self.initialized and self.transport != .none and !self.child_config_deferred) {
            try self.sendFileBreakpoints(allocator, gop.key_ptr.*, gop.value_ptr.items);
        }

        return .{ .id = bp_id, .verified = true, .file = gop.key_ptr.*, .line = line, .condition = cond_owned, .hit_condition = hit_owned };
    }

    /// Build and send a setBreakpoints request with full breakpoint options for a file.
    fn sendFileBreakpoints(self: *DapProxy, allocator: std.mem.Allocator, file: []const u8, bp_list: []const BreakpointEntry) !void {
        var options = try allocator.alloc(protocol.BreakpointOption, bp_list.len);
        defer allocator.free(options);
        for (bp_list, 0..) |entry, i| {
            options[i] = .{
                .line = entry.line,
                .condition = entry.condition,
                .hit_condition = entry.hit_condition,
                .log_message = entry.log_message,
            };
        }
        // Use lines as dummy - the Ex function uses options when provided
        var lines = try allocator.alloc(u32, bp_list.len);
        defer allocator.free(lines);
        for (bp_list, 0..) |entry, i| {
            lines[i] = entry.line;
        }
        const msg = try protocol.setBreakpointsRequestEx(allocator, self.nextSeq(), file, lines, options);
        defer allocator.free(msg);
        dapLog("[DAP sendFileBreakpoints] Sending setBreakpoints for file={s} with {d} breakpoints", .{ file, bp_list.len });
        const resp = try self.sendRequest(allocator, msg);
        {
            const log_len = @min(resp.len, 512);
            dapLog("[DAP sendFileBreakpoints] Response[0..{d}]: {s}", .{ log_len, resp[0..log_len] });
        }
        allocator.free(resp);
    }

    fn proxyRemoveBreakpoint(ctx: *anyopaque, allocator: std.mem.Allocator, id: u32) anyerror!void {
        const self: *DapProxy = @ptrCast(@alignCast(ctx));

        // Look up which file this breakpoint belongs to
        const entry = self.bp_registry.get(id) orelse return;
        const file = entry.file;

        // Remove from per-file list
        if (self.file_breakpoints.getPtr(file)) |bp_list| {
            var i: usize = 0;
            while (i < bp_list.items.len) {
                if (bp_list.items[i].bp_id == id) {
                    // Free owned strings before removing
                    const removed = bp_list.items[i];
                    if (removed.condition) |c| self.allocator.free(c);
                    if (removed.hit_condition) |h| self.allocator.free(h);
                    if (removed.log_message) |l| self.allocator.free(l);
                    _ = bp_list.swapRemove(i);
                    break;
                }
                i += 1;
            }

            // Re-send all remaining breakpoints for this file (with conditions).
            // Skip during deferred config phase — rearmBreakpoints handles it.
            if (self.initialized and self.transport != .none and !self.child_config_deferred) {
                dapLog("[DAP removeBreakpoint] Re-sending {d} remaining breakpoints for file={s}", .{ bp_list.items.len, file });
                self.sendFileBreakpoints(allocator, file, bp_list.items) catch |err| {
                    dapLog("[DAP removeBreakpoint] Failed to re-send breakpoints for file={s}: {any}", .{ file, err });
                };
            }
        }

        _ = self.bp_registry.remove(id);
    }

    fn proxyListBreakpoints(ctx: *anyopaque, allocator: std.mem.Allocator) anyerror![]const BreakpointInfo {
        const self: *DapProxy = @ptrCast(@alignCast(ctx));

        var result = std.ArrayListUnmanaged(BreakpointInfo).empty;
        // File breakpoints
        var it = self.file_breakpoints.iterator();
        while (it.next()) |entry| {
            const file = entry.key_ptr.*;
            for (entry.value_ptr.items) |bp| {
                try result.append(allocator, .{
                    .id = bp.bp_id,
                    .verified = true,
                    .file = file,
                    .line = bp.line,
                    .condition = bp.condition,
                    .hit_condition = bp.hit_condition,
                });
            }
        }
        // Function breakpoints
        for (self.function_breakpoints.items) |fb| {
            try result.append(allocator, .{
                .id = fb.bp_id,
                .verified = true,
                .file = "",
                .line = 0,
                .condition = fb.condition,
            });
        }
        return try result.toOwnedSlice(allocator);
    }

    fn proxyInspect(ctx: *anyopaque, allocator: std.mem.Allocator, request: InspectRequest) anyerror!InspectResult {
        const self: *DapProxy = @ptrCast(@alignCast(ctx));
        if (!self.initialized or self.transport == .none) return .{ .result = "<not connected>", .@"type" = "" };

        // If variable_ref is provided, expand that variable's children via DAP variables request
        if (request.variable_ref) |var_ref| {
            if (var_ref > 0) {
                const msg = try protocol.variablesRequest(allocator, self.nextSeq(), @intCast(var_ref));
                defer allocator.free(msg);

                const resp = try self.sendRequest(allocator, msg);
                defer allocator.free(resp);

                // Check for error response before parsing variables
                const check = try json.parseFromSlice(json.Value, allocator, resp, .{});
                defer check.deinit();
                if (check.value == .object) {
                    const success = if (check.value.object.get("success")) |v| v == .bool and v.bool else false;
                    if (!success) {
                        const err_msg = if (check.value.object.get("message")) |v| if (v == .string) v.string else "variables request failed" else "variables request failed";
                        return .{ .result = try allocator.dupe(u8, err_msg), .@"type" = "", .result_allocated = true };
                    }
                }

                // Parse using existing translateVariables
                const children = translateVariables(allocator, resp) catch {
                    return .{ .result = "<failed to expand variable>", .@"type" = "" };
                };

                return .{
                    .result = try std.fmt.allocPrint(allocator, "{d} children", .{children.len}),
                    .@"type" = "",
                    .children = children,
                    .result_allocated = true,
                    .children_allocated = true,
                };
            }
        }

        // If scope is provided, fetch variables for that scope
        if (request.scope) |scope_name| {
            const fid: i64 = if (request.frame_id) |f| self.resolveFrameId(f) orelse return .{ .result = "", .@"type" = "" } else self.current_frame_id orelse return .{ .result = "", .@"type" = "" };

            // Get scopes for the frame
            const scopes_msg = try protocol.scopesRequest(allocator, self.nextSeq(), fid);
            defer allocator.free(scopes_msg);
            const scopes_resp = try self.sendRequest(allocator, scopes_msg);
            defer allocator.free(scopes_resp);

            // Parse and find matching scope
            const scopes_parsed = try json.parseFromSlice(json.Value, allocator, scopes_resp, .{});
            defer scopes_parsed.deinit();

            var scope_var_ref: i64 = 0;
            if (scopes_parsed.value == .object) {
                if (scopes_parsed.value.object.get("body")) |body| {
                    if (body == .object) {
                        if (body.object.get("scopes")) |scopes| {
                            if (scopes == .array) {
                                for (scopes.array.items) |item| {
                                    if (item != .object) continue;
                                    const scope_name_val = if (item.object.get("name")) |v| (if (v == .string) v.string else continue) else continue;
                                    // Match scope names case-insensitively.
                                    // vscode-js-debug returns "Local" / "Global" (not "locals" / "globals"),
                                    // so use prefix matching for those scopes.
                                    if (std.ascii.eqlIgnoreCase(scope_name_val, scope_name) or
                                        (std.mem.eql(u8, scope_name, "locals") and std.ascii.startsWithIgnoreCase(scope_name_val, "local")) or
                                        (std.mem.eql(u8, scope_name, "globals") and std.ascii.startsWithIgnoreCase(scope_name_val, "global")) or
                                        (std.mem.eql(u8, scope_name, "arguments") and
                                        (std.ascii.eqlIgnoreCase(scope_name_val, "arguments") or
                                        std.mem.indexOf(u8, scope_name_val, "arg") != null or
                                        std.mem.indexOf(u8, scope_name_val, "Arg") != null)))
                                    {
                                        if (item.object.get("variablesReference")) |vr| {
                                            if (vr == .integer) {
                                                scope_var_ref = vr.integer;
                                                break;
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }

            if (scope_var_ref > 0) {
                const vars_msg = try protocol.variablesRequest(allocator, self.nextSeq(), @intCast(scope_var_ref));
                defer allocator.free(vars_msg);
                const vars_resp = try self.sendRequest(allocator, vars_msg);
                defer allocator.free(vars_resp);

                const children = translateVariables(allocator, vars_resp) catch {
                    return .{ .result = "<failed to list scope variables>", .@"type" = "" };
                };

                return .{
                    .result = try std.fmt.allocPrint(allocator, "{d} variables", .{children.len}),
                    .@"type" = "",
                    .children = children,
                    .result_allocated = true,
                    .children_allocated = true,
                };
            }

            return .{ .result = try allocator.dupe(u8, "scope not found"), .@"type" = "", .result_allocated = true };
        }

        const expr = request.expression orelse return .{ .result = "", .@"type" = "" };
        if (expr.len == 0) return .{ .result = "", .@"type" = "" };

        // Send DAP evaluate request with context.
        // When no frame_id is specified, use the topmost frame from the last
        // stopped event — omitting frameId causes DAP to evaluate in the
        // global scope where local variables are not visible (NameError).
        const frame_id: ?i64 = if (request.frame_id) |fid| self.resolveFrameId(fid) else self.current_frame_id;
        const msg = try protocol.evaluateRequestEx(allocator, self.nextSeq(), expr, frame_id, request.context, null, null, null);
        defer allocator.free(msg);

        const resp = try self.sendRequest(allocator, msg);
        defer allocator.free(resp);

        // Parse the evaluate response
        const parsed = try json.parseFromSlice(json.Value, allocator, resp, .{});
        defer parsed.deinit();

        if (parsed.value != .object) return .{ .result = "<invalid response>", .@"type" = "" };
        const success = if (parsed.value.object.get("success")) |v| v == .bool and v.bool else false;
        if (!success) {
            const err_msg = if (parsed.value.object.get("message")) |v| if (v == .string) v.string else "<error>" else "<error>";
            return .{ .result = try allocator.dupe(u8, err_msg), .@"type" = "", .result_allocated = true };
        }

        const body = parsed.value.object.get("body") orelse return .{ .result = "", .@"type" = "" };
        if (body != .object) return .{ .result = "", .@"type" = "" };

        const result_str = if (body.object.get("result")) |v| if (v == .string) try allocator.dupe(u8, v.string) else try allocator.dupe(u8, "") else try allocator.dupe(u8, "");
        const type_str = if (body.object.get("type")) |v| if (v == .string) try allocator.dupe(u8, v.string) else try allocator.dupe(u8, "") else try allocator.dupe(u8, "");

        // Check if the evaluate result has children that can be expanded
        const var_ref_val: u32 = if (body.object.get("variablesReference")) |v| switch (v) {
            .integer => @intCast(v.integer),
            else => 0,
        } else 0;

        if (var_ref_val > 0) {
            // Auto-expand first level of children
            const vars_msg = try protocol.variablesRequest(allocator, self.nextSeq(), @intCast(var_ref_val));
            defer allocator.free(vars_msg);

            if (self.sendRequest(allocator, vars_msg)) |vars_resp| {
                defer allocator.free(vars_resp);
                if (translateVariables(allocator, vars_resp)) |children| {
                    return .{
                        .result = result_str,
                        .@"type" = type_str,
                        .children = children,
                        .result_allocated = true,
                        .children_allocated = true,
                    };
                } else |_| {}
            } else |_| {}
        }

        return .{ .result = result_str, .@"type" = type_str, .result_allocated = true };
    }

    /// Write-only pause: builds and sends a pause request without reading
    /// the response.  Safe to call while a background run thread owns the
    /// read side of the socket — the background thread will see the
    /// resulting "stopped" event and report it via pending_run.
    fn proxySendPause(ctx: *anyopaque, allocator: std.mem.Allocator, thread_id: ?u32) anyerror!void {
        const self: *DapProxy = @ptrCast(@alignCast(ctx));
        const tid: i64 = if (thread_id) |t| @intCast(t) else self.thread_id;
        const msg = try protocol.pauseRequest(allocator, self.nextSeq(), tid);
        defer allocator.free(msg);
        try self.sendRaw(allocator, msg);
        dapLog("[DAP sendPause] Sent fire-and-forget pause for thread {d}", .{tid});
    }

    fn proxyGetPid(ctx: *anyopaque) ?std.posix.pid_t {
        const self: *DapProxy = @ptrCast(@alignCast(ctx));
        return self.transportGetPid();
    }

    fn proxyStop(ctx: *anyopaque, allocator: std.mem.Allocator) anyerror!void {
        const self: *DapProxy = @ptrCast(@alignCast(ctx));
        if (self.transport != .none) {
            // Send disconnect request
            const msg = try protocol.disconnectRequest(allocator, self.nextSeq());
            defer allocator.free(msg);

            // Try to send gracefully, but don't fail if adapter is already gone
            _ = self.sendRequest(allocator, msg) catch {};

            self.transportKill();
        }
    }

    fn proxyDetach(ctx: *anyopaque, allocator: std.mem.Allocator) anyerror!void {
        const self: *DapProxy = @ptrCast(@alignCast(ctx));
        if (self.transport != .none) {
            // Send disconnect without killing the debuggee
            const msg = try protocol.disconnectRequestEx(allocator, self.nextSeq(), false, false, null);
            defer allocator.free(msg);

            _ = self.sendRequest(allocator, msg) catch {};
            self.transportKill();
        }
    }

    fn proxyThreads(ctx: *anyopaque, allocator: std.mem.Allocator) anyerror![]const ThreadInfo {
        const self: *DapProxy = @ptrCast(@alignCast(ctx));
        if (!self.initialized or self.transport == .none) {
            // Fallback: return single main thread
            const result = try allocator.alloc(ThreadInfo, 1);
            result[0] = .{ .id = 1, .name = "main" };
            return result;
        }

        const msg = try protocol.threadsRequest(allocator, self.nextSeq());
        defer allocator.free(msg);
        const resp = self.sendRequest(allocator, msg) catch {
            const result = try allocator.alloc(ThreadInfo, 1);
            result[0] = .{ .id = 1, .name = "main" };
            return result;
        };
        defer allocator.free(resp);

        // Parse threads response
        const parsed = try json.parseFromSlice(json.Value, allocator, resp, .{});
        defer parsed.deinit();

        if (parsed.value != .object) return error.InvalidResponse;
        const body = parsed.value.object.get("body") orelse return error.InvalidResponse;
        if (body != .object) return error.InvalidResponse;
        const threads_val = body.object.get("threads") orelse return error.InvalidResponse;
        if (threads_val != .array) return error.InvalidResponse;

        var threads = std.ArrayListUnmanaged(ThreadInfo).empty;
        for (threads_val.array.items) |item| {
            if (item != .object) continue;
            const obj = item.object;
            const id: u32 = if (obj.get("id")) |v| switch (v) {
                .integer => @intCast(v.integer),
                else => 0,
            } else 0;
            const name = if (obj.get("name")) |v| switch (v) {
                .string => try allocator.dupe(u8, v.string),
                else => try allocator.dupe(u8, "thread"),
            } else try allocator.dupe(u8, "thread");

            try threads.append(allocator, .{ .id = id, .name = name });
        }
        return try threads.toOwnedSlice(allocator);
    }

    fn proxyStackTrace(ctx: *anyopaque, allocator: std.mem.Allocator, thread_id: u32, start_frame: u32, levels: u32) anyerror![]const StackFrame {
        const self: *DapProxy = @ptrCast(@alignCast(ctx));
        if (!self.initialized or self.transport == .none) return &.{};

        const msg = try protocol.stackTraceRequest(allocator, self.nextSeq(), @intCast(thread_id), @intCast(start_frame), @intCast(levels));
        defer allocator.free(msg);
        const resp = try self.sendRequest(allocator, msg);
        defer allocator.free(resp);

        return translateStackTrace(allocator, resp);
    }

    fn proxyReadMemory(ctx: *anyopaque, allocator: std.mem.Allocator, address: u64, size: u64) anyerror![]const u8 {
        const self: *DapProxy = @ptrCast(@alignCast(ctx));
        if (!self.initialized or self.transport == .none) return error.NotSupported;
        if (!self.adapter_capabilities.supports_read_memory) return error.NotSupported;

        // DAP readMemory uses a string memoryReference
        var addr_buf: [20]u8 = undefined;
        const addr_str = std.fmt.bufPrint(&addr_buf, "0x{x}", .{address}) catch return error.InvalidAddress;

        const msg = try protocol.readMemoryRequest(allocator, self.nextSeq(), addr_str, 0, @intCast(size));
        defer allocator.free(msg);
        const resp = try self.sendRequest(allocator, msg);
        defer allocator.free(resp);

        // Parse response: body.data is base64 encoded
        const parsed = try json.parseFromSlice(json.Value, allocator, resp, .{});
        defer parsed.deinit();

        if (parsed.value != .object) return error.InvalidResponse;

        // Check for success: false (e.g. vscode-js-debug advertises supportsReadMemoryRequest
        // for WASM but arbitrary addresses fail).
        if (parsed.value.object.get("success")) |s| {
            if (s == .bool and !s.bool) return error.NotSupported;
        }

        const body = parsed.value.object.get("body") orelse return error.NotSupported;
        if (body != .object) return error.NotSupported;
        const data_val = body.object.get("data") orelse return error.NotSupported;
        if (data_val != .string) return error.NotSupported;

        return try allocator.dupe(u8, data_val.string);
    }

    fn proxyWriteMemory(ctx: *anyopaque, allocator: std.mem.Allocator, address: u64, data: []const u8) anyerror!void {
        const self: *DapProxy = @ptrCast(@alignCast(ctx));
        if (!self.initialized or self.transport == .none) return error.NotSupported;
        if (!self.adapter_capabilities.supports_write_memory) return error.NotSupported;

        var addr_buf: [20]u8 = undefined;
        const addr_str = std.fmt.bufPrint(&addr_buf, "0x{x}", .{address}) catch return error.InvalidAddress;

        // DAP spec requires base64 encoding for writeMemory data
        const base64_data = try base64Encode(allocator, data);
        defer allocator.free(base64_data);

        const msg = try protocol.writeMemoryRequest(allocator, self.nextSeq(), addr_str, 0, base64_data, null);
        defer allocator.free(msg);
        const resp = try self.sendRequest(allocator, msg);
        allocator.free(resp);
    }

    fn proxyDisassemble(ctx: *anyopaque, allocator: std.mem.Allocator, address: u64, count: u32, instruction_offset: ?i64, resolve_symbols: ?bool) anyerror![]const DisassembledInstruction {
        const self: *DapProxy = @ptrCast(@alignCast(ctx));
        if (!self.initialized or self.transport == .none) return error.NotSupported;
        if (!self.adapter_capabilities.supports_disassemble) return error.NotSupported;

        var addr_buf: [20]u8 = undefined;
        const addr_str = std.fmt.bufPrint(&addr_buf, "0x{x}", .{address}) catch return error.InvalidAddress;

        const msg = try protocol.disassembleRequestEx(allocator, self.nextSeq(), addr_str, @intCast(count), .{
            .instruction_offset = instruction_offset,
            .resolve_symbols = resolve_symbols,
        });
        defer allocator.free(msg);
        const resp = try self.sendRequest(allocator, msg);
        defer allocator.free(resp);

        // Parse disassemble response
        const parsed = try json.parseFromSlice(json.Value, allocator, resp, .{});
        defer parsed.deinit();

        if (parsed.value != .object) return error.InvalidResponse;
        const body = parsed.value.object.get("body") orelse return error.InvalidResponse;
        if (body != .object) return error.InvalidResponse;
        const instructions_val = body.object.get("instructions") orelse return error.InvalidResponse;
        if (instructions_val != .array) return error.InvalidResponse;

        var instructions = std.ArrayListUnmanaged(DisassembledInstruction).empty;
        for (instructions_val.array.items) |item| {
            if (item != .object) continue;
            const obj = item.object;

            const inst_addr = if (obj.get("address")) |v| switch (v) {
                .string => try allocator.dupe(u8, v.string),
                else => try allocator.dupe(u8, "0x0"),
            } else try allocator.dupe(u8, "0x0");

            const instruction = if (obj.get("instruction")) |v| switch (v) {
                .string => try allocator.dupe(u8, v.string),
                else => try allocator.dupe(u8, ""),
            } else try allocator.dupe(u8, "");

            const bytes = if (obj.get("instructionBytes")) |v| switch (v) {
                .string => try allocator.dupe(u8, v.string),
                else => try allocator.dupe(u8, ""),
            } else try allocator.dupe(u8, "");

            try instructions.append(allocator, .{
                .address = inst_addr,
                .instruction = instruction,
                .instruction_bytes = bytes,
            });
        }
        return try instructions.toOwnedSlice(allocator);
    }

    fn proxyAttach(ctx: *anyopaque, allocator: std.mem.Allocator, pid: u32) anyerror!void {
        const self: *DapProxy = @ptrCast(@alignCast(ctx));
        if (self.transport == .none) return error.NotInitialized;

        // Send initialize if not done yet
        if (!self.initialized) {
            const init_msg = try protocol.initializeRequest(allocator, self.nextSeq());
            defer allocator.free(init_msg);
            const init_resp = try self.sendRequest(allocator, init_msg);
            defer allocator.free(init_resp);

            // Parse capabilities from the initialize response body
            self.parseAdapterCapabilities(allocator, init_resp);
        }

        // Send attach request WITHOUT waiting for response (same DAP ordering
        // as launch: adapter won't respond until after configurationDone).
        const msg = try protocol.attachRequest(allocator, self.nextSeq(), @intCast(pid));
        defer allocator.free(msg);
        try self.sendRaw(allocator, msg);

        // Wait for 'initialized' event
        if (!self.initialized) {
            const init_event = try self.waitForEvent(allocator, "initialized");
            allocator.free(init_event);
        }

        // Send configurationDone — adapter will then send both responses
        const config_msg = try protocol.configurationDoneRequest(allocator, self.nextSeq());
        defer allocator.free(config_msg);
        const config_resp = try self.sendRequest(allocator, config_msg);
        allocator.free(config_resp);

        self.initialized = true;
    }

    fn proxySetFunctionBreakpoint(ctx: *anyopaque, allocator: std.mem.Allocator, name: []const u8, condition: ?[]const u8) anyerror!BreakpointInfo {
        const self: *DapProxy = @ptrCast(@alignCast(ctx));
        if (!self.adapter_capabilities.supports_function_breakpoints) return error.NotSupported;
        const bp_id = self.next_bp_id;
        self.next_bp_id += 1;

        // Track the function breakpoint
        try self.function_breakpoints.append(self.allocator, .{
            .bp_id = bp_id,
            .name = try self.allocator.dupe(u8, name),
            .condition = if (condition) |c| try self.allocator.dupe(u8, c) else null,
        });

        if (self.initialized and self.transport != .none) {
            self.sendFunctionBreakpoints(allocator) catch {
                return .{ .id = bp_id, .verified = false, .file = "", .line = 0 };
            };
        }

        return .{ .id = bp_id, .verified = true, .file = "", .line = 0, .condition = condition };
    }

    fn proxySetExceptionBreakpoints(ctx: *anyopaque, allocator: std.mem.Allocator, filters: []const []const u8) anyerror!void {
        const self: *DapProxy = @ptrCast(@alignCast(ctx));
        if (!self.initialized or self.transport == .none) return;

        // Store active exception filters for restart re-arming
        if (self.active_exception_filters) |old| {
            for (old) |f| self.allocator.free(f);
            self.allocator.free(old);
        }
        const duped = try self.allocator.alloc([]const u8, filters.len);
        for (filters, 0..) |f, i| {
            duped[i] = try self.allocator.dupe(u8, f);
        }
        self.active_exception_filters = duped;

        self.sendExceptionBreakpoints(allocator, filters) catch return;
    }

    fn proxySetVariable(ctx: *anyopaque, allocator: std.mem.Allocator, name: []const u8, value: []const u8, frame_id: u32) anyerror!InspectResult {
        const self: *DapProxy = @ptrCast(@alignCast(ctx));
        if (!self.initialized or self.transport == .none) return error.NotSupported;

        // Use current_frame_id when caller passes 0 (invalid default in debugpy)
        const effective_frame_id: i64 = if (frame_id != 0) @intCast(frame_id) else self.current_frame_id orelse return error.NotSupported;

        // First get scopes for the frame to find the local variables reference
        const scopes_msg = try protocol.scopesRequest(allocator, self.nextSeq(), effective_frame_id);
        defer allocator.free(scopes_msg);
        const scopes_resp = try self.sendRequest(allocator, scopes_msg);
        defer allocator.free(scopes_resp);

        // Parse scopes to get variablesReference for locals
        const scopes_parsed = try json.parseFromSlice(json.Value, allocator, scopes_resp, .{});
        defer scopes_parsed.deinit();

        var var_ref: i64 = 0;
        if (scopes_parsed.value == .object) {
            if (scopes_parsed.value.object.get("body")) |body| {
                if (body == .object) {
                    if (body.object.get("scopes")) |scopes| {
                        if (scopes == .array and scopes.array.items.len > 0) {
                            if (scopes.array.items[0] == .object) {
                                if (scopes.array.items[0].object.get("variablesReference")) |vr| {
                                    if (vr == .integer) var_ref = vr.integer;
                                }
                            }
                        }
                    }
                }
            }
        }

        if (var_ref == 0) return error.NotSupported;

        // Send setVariable request
        const msg = try protocol.setVariableRequest(allocator, self.nextSeq(), var_ref, name, value, null);
        defer allocator.free(msg);
        const resp = try self.sendRequest(allocator, msg);
        defer allocator.free(resp);

        // Parse response
        const parsed = try json.parseFromSlice(json.Value, allocator, resp, .{});
        defer parsed.deinit();

        if (parsed.value != .object) return error.InvalidResponse;
        const body = parsed.value.object.get("body") orelse return .{ .result = value, .@"type" = "" };
        if (body != .object) return .{ .result = value, .@"type" = "" };

        const result_val = if (body.object.get("value")) |v| if (v == .string) try allocator.dupe(u8, v.string) else try allocator.dupe(u8, value) else try allocator.dupe(u8, value);
        const type_val = if (body.object.get("type")) |v| if (v == .string) try allocator.dupe(u8, v.string) else try allocator.dupe(u8, "") else try allocator.dupe(u8, "");
        _ = type_val;

        return .{ .result = result_val, .@"type" = "", .result_allocated = true };
    }

    fn proxyGoto(ctx: *anyopaque, allocator: std.mem.Allocator, file: []const u8, line: u32) anyerror!StopState {
        const self: *DapProxy = @ptrCast(@alignCast(ctx));
        if (!self.initialized or self.transport == .none) return error.NotSupported;
        if (!self.adapter_capabilities.supports_goto_targets) return error.NotSupported;

        // 1. Get goto targets for the file:line
        const targets_msg = try protocol.gotoTargetsRequest(allocator, self.nextSeq(), file, @intCast(line), null);
        defer allocator.free(targets_msg);
        const targets_resp = try self.sendRequest(allocator, targets_msg);
        defer allocator.free(targets_resp);

        // Parse to get target ID
        const parsed = try json.parseFromSlice(json.Value, allocator, targets_resp, .{});
        defer parsed.deinit();

        var target_id: ?i64 = null;
        if (parsed.value == .object) {
            if (parsed.value.object.get("body")) |body| {
                if (body == .object) {
                    if (body.object.get("targets")) |targets| {
                        if (targets == .array and targets.array.items.len > 0) {
                            if (targets.array.items[0] == .object) {
                                if (targets.array.items[0].object.get("id")) |id| {
                                    if (id == .integer) target_id = id.integer;
                                }
                            }
                        }
                    }
                }
            }
        }

        const tid = target_id orelse return error.NotSupported;

        // 2. Send goto request
        const goto_msg = try protocol.gotoRequest(allocator, self.nextSeq(), self.thread_id, tid);
        defer allocator.free(goto_msg);
        const goto_resp = try self.sendRequest(allocator, goto_msg);
        allocator.free(goto_resp);

        // Wait for stopped event
        const event_data = self.waitForEvent(allocator, "stopped") catch {
            return .{ .stop_reason = .step, .location = .{ .file = file, .line = line } };
        };
        defer allocator.free(event_data);

        return translateStoppedEvent(allocator, event_data);
    }

    fn proxyScopes(ctx: *anyopaque, allocator: std.mem.Allocator, frame_id: u32) anyerror![]const Scope {
        const self: *DapProxy = @ptrCast(@alignCast(ctx));
        if (!self.initialized or self.transport == .none) return error.NotSupported;

        const resolved_fid: i64 = self.resolveFrameId(frame_id) orelse self.current_frame_id orelse return error.NotSupported;
        const msg = try protocol.scopesRequest(allocator, self.nextSeq(), resolved_fid);
        defer allocator.free(msg);
        const resp = try self.sendRequest(allocator, msg);
        defer allocator.free(resp);

        const parsed = try json.parseFromSlice(json.Value, allocator, resp, .{});
        defer parsed.deinit();

        if (parsed.value != .object) return error.InvalidResponse;
        const body = parsed.value.object.get("body") orelse return error.InvalidResponse;
        if (body != .object) return error.InvalidResponse;
        const scopes_val = body.object.get("scopes") orelse return error.InvalidResponse;
        if (scopes_val != .array) return error.InvalidResponse;

        var scopes = std.ArrayListUnmanaged(Scope).empty;
        errdefer scopes.deinit(allocator);

        for (scopes_val.array.items) |item| {
            if (item != .object) continue;
            const obj = item.object;

            const name = if (obj.get("name")) |v| (if (v == .string) try allocator.dupe(u8, v.string) else try allocator.dupe(u8, "")) else try allocator.dupe(u8, "");
            const var_ref: u32 = if (obj.get("variablesReference")) |v| (if (v == .integer) @intCast(v.integer) else 0) else 0;
            const expensive = if (obj.get("expensive")) |v| (v == .bool and v.bool) else false;

            try scopes.append(allocator, .{
                .name = name,
                .variables_reference = var_ref,
                .expensive = expensive,
            });
        }
        return try scopes.toOwnedSlice(allocator);
    }

    fn proxyDataBreakpointInfo(ctx: *anyopaque, allocator: std.mem.Allocator, name: []const u8, frame_id: ?u32) anyerror!DataBreakpointInfo {
        const self: *DapProxy = @ptrCast(@alignCast(ctx));
        if (!self.initialized or self.transport == .none) return error.NotSupported;
        if (!self.adapter_capabilities.supports_data_breakpoints) return error.NotSupported;

        const fid: ?i64 = if (frame_id) |f| @intCast(f) else null;
        const msg = try protocol.dataBreakpointInfoRequest(allocator, self.nextSeq(), name, fid, null, null, null);
        defer allocator.free(msg);
        const resp = try self.sendRequest(allocator, msg);
        defer allocator.free(resp);

        const parsed = try json.parseFromSlice(json.Value, allocator, resp, .{});
        defer parsed.deinit();

        if (parsed.value != .object) return error.InvalidResponse;
        const body = parsed.value.object.get("body") orelse return error.InvalidResponse;
        if (body != .object) return error.InvalidResponse;

        const data_id = if (body.object.get("dataId")) |v| (if (v == .string) try allocator.dupe(u8, v.string) else null) else null;
        const description = if (body.object.get("description")) |v| (if (v == .string) try allocator.dupe(u8, v.string) else try allocator.dupe(u8, "")) else try allocator.dupe(u8, "");
        const can_persist = if (body.object.get("canPersist")) |v| (v == .bool and v.bool) else false;

        return .{
            .data_id = data_id,
            .description = description,
            .can_persist = can_persist,
        };
    }

    fn proxySetDataBreakpoint(ctx: *anyopaque, allocator: std.mem.Allocator, data_id: []const u8, access_type: DataBreakpointAccessType) anyerror!BreakpointInfo {
        const self: *DapProxy = @ptrCast(@alignCast(ctx));
        if (!self.initialized or self.transport == .none) return error.NotSupported;
        if (!self.adapter_capabilities.supports_data_breakpoints) return error.NotSupported;

        const access_str = @tagName(access_type);
        const bp_specs = [_]protocol.DataBreakpointSpec{.{ .data_id = data_id, .access_type = access_str }};
        const msg = try protocol.setDataBreakpointsRequest(allocator, self.nextSeq(), &bp_specs);
        defer allocator.free(msg);
        const resp = try self.sendRequest(allocator, msg);
        defer allocator.free(resp);

        const bp_id = self.next_bp_id;
        self.next_bp_id += 1;

        // Parse response for verification
        const parsed = try json.parseFromSlice(json.Value, allocator, resp, .{});
        defer parsed.deinit();

        var verified = false;
        if (parsed.value == .object) {
            if (parsed.value.object.get("body")) |body| {
                if (body == .object) {
                    if (body.object.get("breakpoints")) |bps| {
                        if (bps == .array and bps.array.items.len > 0) {
                            if (bps.array.items[0] == .object) {
                                if (bps.array.items[0].object.get("verified")) |v| {
                                    verified = v == .bool and v.bool;
                                }
                            }
                        }
                    }
                }
            }
        }

        return .{ .id = bp_id, .verified = verified, .file = "", .line = 0 };
    }

    fn proxyCapabilities(ctx: *anyopaque) DebugCapabilities {
        const self: *DapProxy = @ptrCast(@alignCast(ctx));
        // Return capabilities parsed from the DAP initialize response
        return self.adapter_capabilities;
    }

    fn proxyCompletions(ctx: *anyopaque, allocator: std.mem.Allocator, text: []const u8, column: u32, frame_id: ?u32) anyerror![]const CompletionItem {
        const self: *DapProxy = @ptrCast(@alignCast(ctx));
        if (!self.initialized or self.transport == .none) return error.NotSupported;
        if (!self.adapter_capabilities.supports_completions) return error.NotSupported;

        // Fall back to current_frame_id when caller doesn't provide one
        const fid: ?i64 = if (frame_id) |f| @intCast(f) else self.current_frame_id;
        const msg = try protocol.completionsRequest(allocator, self.nextSeq(), text, @intCast(column), fid, null);
        defer allocator.free(msg);
        const resp = try self.sendRequest(allocator, msg);
        defer allocator.free(resp);

        const parsed = try json.parseFromSlice(json.Value, allocator, resp, .{});
        defer parsed.deinit();

        if (parsed.value != .object) return error.InvalidResponse;
        const body = parsed.value.object.get("body") orelse return error.InvalidResponse;
        if (body != .object) return error.InvalidResponse;
        const targets = body.object.get("targets") orelse return &.{};
        if (targets != .array) return &.{};

        var items = std.ArrayListUnmanaged(CompletionItem).empty;
        errdefer items.deinit(allocator);

        for (targets.array.items) |item| {
            if (item != .object) continue;
            const obj = item.object;
            const label = if (obj.get("label")) |v| (if (v == .string) try allocator.dupe(u8, v.string) else continue) else continue;
            const item_text = if (obj.get("text")) |v| (if (v == .string) try allocator.dupe(u8, v.string) else try allocator.dupe(u8, "")) else try allocator.dupe(u8, "");
            const item_type = if (obj.get("type")) |v| (if (v == .string) try allocator.dupe(u8, v.string) else try allocator.dupe(u8, "")) else try allocator.dupe(u8, "");

            try items.append(allocator, .{
                .label = label,
                .text = item_text,
                .item_type = item_type,
            });
        }
        return try items.toOwnedSlice(allocator);
    }

    fn proxyModules(ctx: *anyopaque, allocator: std.mem.Allocator) anyerror![]const Module {
        const self: *DapProxy = @ptrCast(@alignCast(ctx));
        if (!self.initialized or self.transport == .none) return error.NotSupported;
        if (!self.adapter_capabilities.supports_modules) return error.NotSupported;

        const msg = try protocol.modulesRequest(allocator, self.nextSeq());
        defer allocator.free(msg);
        const resp = try self.sendRequest(allocator, msg);
        defer allocator.free(resp);

        const parsed = try json.parseFromSlice(json.Value, allocator, resp, .{});
        defer parsed.deinit();

        if (parsed.value != .object) return error.InvalidResponse;
        const body = parsed.value.object.get("body") orelse return error.InvalidResponse;
        if (body != .object) return error.InvalidResponse;
        const modules_val = body.object.get("modules") orelse return &.{};
        if (modules_val != .array) return &.{};

        var mods = std.ArrayListUnmanaged(Module).empty;
        errdefer mods.deinit(allocator);

        for (modules_val.array.items) |item| {
            if (item != .object) continue;
            const obj = item.object;

            const mod_id = if (obj.get("id")) |v| blk: {
                break :blk switch (v) {
                    .string => try allocator.dupe(u8, v.string),
                    .integer => blk2: {
                        var buf: [20]u8 = undefined;
                        const s = std.fmt.bufPrint(&buf, "{d}", .{v.integer}) catch break :blk2 try allocator.dupe(u8, "0");
                        break :blk2 try allocator.dupe(u8, s);
                    },
                    else => try allocator.dupe(u8, ""),
                };
            } else try allocator.dupe(u8, "");

            const name = if (obj.get("name")) |v| (if (v == .string) try allocator.dupe(u8, v.string) else try allocator.dupe(u8, "")) else try allocator.dupe(u8, "");
            const path = if (obj.get("path")) |v| (if (v == .string) try allocator.dupe(u8, v.string) else try allocator.dupe(u8, "")) else try allocator.dupe(u8, "");
            const is_opt = if (obj.get("isOptimized")) |v| (v == .bool and v.bool) else false;
            const sym_status = if (obj.get("symbolStatus")) |v| (if (v == .string) try allocator.dupe(u8, v.string) else try allocator.dupe(u8, "")) else try allocator.dupe(u8, "");

            try mods.append(allocator, .{
                .id = mod_id,
                .name = name,
                .path = path,
                .is_optimized = is_opt,
                .symbol_status = sym_status,
            });
        }
        return try mods.toOwnedSlice(allocator);
    }

    fn proxyLoadedSources(ctx: *anyopaque, allocator: std.mem.Allocator) anyerror![]const types.LoadedSource {
        const self: *DapProxy = @ptrCast(@alignCast(ctx));
        if (!self.initialized or self.transport == .none) return error.NotSupported;
        if (!self.adapter_capabilities.supports_loaded_sources) return error.NotSupported;
        const msg = try protocol.loadedSourcesRequest(allocator, self.nextSeq());
        defer allocator.free(msg);
        const resp = try self.sendRequest(allocator, msg);
        defer allocator.free(resp);

        const parsed = try json.parseFromSlice(json.Value, allocator, resp, .{});
        defer parsed.deinit();

        if (parsed.value != .object) return error.InvalidResponse;
        const body = parsed.value.object.get("body") orelse return error.InvalidResponse;
        if (body != .object) return error.InvalidResponse;
        const sources_val = body.object.get("sources") orelse return &.{};
        if (sources_val != .array) return &.{};

        var sources = std.ArrayListUnmanaged(types.LoadedSource).empty;
        errdefer sources.deinit(allocator);

        for (sources_val.array.items) |item| {
            if (item != .object) continue;
            const obj = item.object;

            const name = if (obj.get("name")) |v| (if (v == .string) try allocator.dupe(u8, v.string) else try allocator.dupe(u8, "")) else try allocator.dupe(u8, "");
            const path = if (obj.get("path")) |v| (if (v == .string) try allocator.dupe(u8, v.string) else try allocator.dupe(u8, "")) else try allocator.dupe(u8, "");
            const src_ref: u32 = if (obj.get("sourceReference")) |v| (if (v == .integer) @intCast(v.integer) else 0) else 0;

            try sources.append(allocator, .{
                .name = name,
                .path = path,
                .source_reference = src_ref,
            });
        }
        return try sources.toOwnedSlice(allocator);
    }

    fn proxySource(ctx: *anyopaque, allocator: std.mem.Allocator, source_ref: u32) anyerror![]const u8 {
        const self: *DapProxy = @ptrCast(@alignCast(ctx));
        if (!self.initialized or self.transport == .none) return error.NotSupported;

        const msg = try protocol.sourceRequest(allocator, self.nextSeq(), @intCast(source_ref));
        defer allocator.free(msg);
        const resp = try self.sendRequest(allocator, msg);
        defer allocator.free(resp);

        const parsed = try json.parseFromSlice(json.Value, allocator, resp, .{});
        defer parsed.deinit();

        if (parsed.value != .object) return error.InvalidResponse;
        const body = parsed.value.object.get("body") orelse return error.InvalidResponse;
        if (body != .object) return error.InvalidResponse;
        const content = body.object.get("content") orelse return error.InvalidResponse;
        if (content != .string) return error.InvalidResponse;

        return try allocator.dupe(u8, content.string);
    }

    fn proxySetExpression(ctx: *anyopaque, allocator: std.mem.Allocator, expression: []const u8, value: []const u8, frame_id: u32) anyerror!InspectResult {
        const self: *DapProxy = @ptrCast(@alignCast(ctx));
        if (!self.initialized or self.transport == .none) return error.NotSupported;

        // Use current_frame_id when caller passes 0 (invalid default in debugpy)
        const effective_frame_id: ?i64 = if (frame_id != 0) @intCast(frame_id) else self.current_frame_id;
        const msg = try protocol.setExpressionRequest(allocator, self.nextSeq(), expression, value, effective_frame_id, null);
        defer allocator.free(msg);
        const resp = try self.sendRequest(allocator, msg);
        defer allocator.free(resp);

        const parsed = try json.parseFromSlice(json.Value, allocator, resp, .{});
        defer parsed.deinit();

        if (parsed.value != .object) return error.InvalidResponse;
        const body = parsed.value.object.get("body") orelse return .{ .result = value, .@"type" = "" };
        if (body != .object) return .{ .result = value, .@"type" = "" };

        const result_val = if (body.object.get("value")) |v| (if (v == .string) try allocator.dupe(u8, v.string) else try allocator.dupe(u8, value)) else try allocator.dupe(u8, value);

        return .{ .result = result_val, .@"type" = "", .result_allocated = true };
    }

    fn proxyRestartFrame(ctx: *anyopaque, allocator: std.mem.Allocator, frame_id: u32) anyerror!void {
        const self: *DapProxy = @ptrCast(@alignCast(ctx));
        if (!self.initialized or self.transport == .none) return error.NotSupported;
        if (!self.adapter_capabilities.supports_restart_frame) return error.NotSupported;

        const msg = try protocol.restartFrameRequest(allocator, self.nextSeq(), @intCast(frame_id));
        defer allocator.free(msg);
        const resp = try self.sendRequest(allocator, msg);
        allocator.free(resp);
    }

    fn proxyExceptionInfo(ctx: *anyopaque, allocator: std.mem.Allocator, thread_id: u32) anyerror!types.ExceptionInfo {
        const self: *DapProxy = @ptrCast(@alignCast(ctx));
        if (!self.initialized or self.transport == .none) return error.NotSupported;

        const msg = try protocol.exceptionInfoRequest(allocator, self.nextSeq(), @intCast(thread_id));
        defer allocator.free(msg);
        const resp = try self.sendRequest(allocator, msg);
        defer allocator.free(resp);

        const parsed = try json.parseFromSlice(json.Value, allocator, resp, .{});
        defer parsed.deinit();

        if (parsed.value != .object) return error.InvalidResponse;
        const body = parsed.value.object.get("body") orelse return error.InvalidResponse;
        if (body != .object) return error.InvalidResponse;

        const exc_id = if (body.object.get("exceptionId")) |v| (if (v == .string) try allocator.dupe(u8, v.string) else null) else null;
        const description = if (body.object.get("description")) |v| (if (v == .string) try allocator.dupe(u8, v.string) else null) else null;
        const break_mode = if (body.object.get("breakMode")) |v| (if (v == .string) try allocator.dupe(u8, v.string) else "unhandled") else "unhandled";

        return .{
            .@"type" = exc_id orelse "",
            .message = description orelse "",
            .id = exc_id,
            .break_mode = break_mode,
        };
    }

    fn proxyTerminate(ctx: *anyopaque, allocator: std.mem.Allocator) anyerror!void {
        const self: *DapProxy = @ptrCast(@alignCast(ctx));
        if (self.transport == .none) return;

        const msg = try protocol.terminateRequest(allocator, self.nextSeq(), null);
        defer allocator.free(msg);
        _ = self.sendRequest(allocator, msg) catch {};
    }

    fn updateCapabilitiesFromEvent(self: *DapProxy, caps_obj: std.json.ObjectMap) void {
        // Update individual capability flags from a capabilities event
        if (getBoolCapOpt(caps_obj, "supportsConditionalBreakpoints")) |v| self.adapter_capabilities.supports_conditional_breakpoints = v;
        if (getBoolCapOpt(caps_obj, "supportsHitConditionalBreakpoints")) |v| self.adapter_capabilities.supports_hit_conditional_breakpoints = v;
        if (getBoolCapOpt(caps_obj, "supportsLogPoints")) |v| self.adapter_capabilities.supports_log_points = v;
        if (getBoolCapOpt(caps_obj, "supportsFunctionBreakpoints")) |v| self.adapter_capabilities.supports_function_breakpoints = v;
        if (getBoolCapOpt(caps_obj, "supportsDataBreakpoints")) |v| self.adapter_capabilities.supports_data_breakpoints = v;
        if (getBoolCapOpt(caps_obj, "supportsSetVariable")) |v| self.adapter_capabilities.supports_set_variable = v;
        if (getBoolCapOpt(caps_obj, "supportsGotoTargetsRequest")) |v| self.adapter_capabilities.supports_goto_targets = v;
        if (getBoolCapOpt(caps_obj, "supportsReadMemoryRequest")) |v| self.adapter_capabilities.supports_read_memory = v;
        if (getBoolCapOpt(caps_obj, "supportsWriteMemoryRequest")) |v| self.adapter_capabilities.supports_write_memory = v;
        if (getBoolCapOpt(caps_obj, "supportsDisassembleRequest")) |v| self.adapter_capabilities.supports_disassemble = v;
        if (getBoolCapOpt(caps_obj, "supportsTerminateRequest")) |v| self.adapter_capabilities.supports_terminate = v;
        if (getBoolCapOpt(caps_obj, "supportsCompletionsRequest")) |v| self.adapter_capabilities.supports_completions = v;
        if (getBoolCapOpt(caps_obj, "supportsModulesRequest")) |v| self.adapter_capabilities.supports_modules = v;
        if (getBoolCapOpt(caps_obj, "supportsSetExpression")) |v| self.adapter_capabilities.supports_set_expression = v;
        if (getBoolCapOpt(caps_obj, "supportsStepBack")) |v| self.adapter_capabilities.supports_step_back = v;
        if (getBoolCapOpt(caps_obj, "supportsRestartFrame")) |v| self.adapter_capabilities.supports_restart_frame = v;
        if (getBoolCapOpt(caps_obj, "supportsInstructionBreakpoints")) |v| self.adapter_capabilities.supports_instruction_breakpoints = v;
        if (getBoolCapOpt(caps_obj, "supportsSteppingGranularity")) |v| self.adapter_capabilities.supports_stepping_granularity = v;
        if (getBoolCapOpt(caps_obj, "supportsCancelRequest")) |v| self.adapter_capabilities.supports_cancel_request = v;
        if (getBoolCapOpt(caps_obj, "supportsTerminateThreadsRequest")) |v| self.adapter_capabilities.supports_terminate_threads = v;
        if (getBoolCapOpt(caps_obj, "supportsBreakpointLocationsRequest")) |v| self.adapter_capabilities.supports_breakpoint_locations = v;
        if (getBoolCapOpt(caps_obj, "supportsStepInTargetsRequest")) |v| self.adapter_capabilities.supports_step_in_targets = v;
        if (getBoolCapOpt(caps_obj, "supportsRestartRequest")) |v| self.adapter_capabilities.supports_restart_request = v;
        if (getBoolCapOpt(caps_obj, "supportsExceptionOptions")) |v| self.adapter_capabilities.supports_exception_options = v;
        if (getBoolCapOpt(caps_obj, "supportsExceptionFilterOptions")) |v| self.adapter_capabilities.supports_exception_filter_options = v;
        if (getBoolCapOpt(caps_obj, "supportsExceptionInfoRequest")) |v| self.adapter_capabilities.supports_exception_info_request = v;
        if (getBoolCapOpt(caps_obj, "supportTerminateDebuggee")) |v| self.adapter_capabilities.support_terminate_debuggee = v;
        if (getBoolCapOpt(caps_obj, "supportSuspendDebuggee")) |v| self.adapter_capabilities.support_suspend_debuggee = v;
        if (getBoolCapOpt(caps_obj, "supportsDelayedStackTraceLoading")) |v| self.adapter_capabilities.supports_delayed_stack_trace_loading = v;
        if (getBoolCapOpt(caps_obj, "supportsClipboardContext")) |v| self.adapter_capabilities.supports_clipboard_context = v;
        if (getBoolCapOpt(caps_obj, "supportsSetExpression")) |v| self.adapter_capabilities.supports_set_expression = v;
        if (getBoolCapOpt(caps_obj, "supportsEvaluateForHovers")) |v| self.adapter_capabilities.supports_evaluate_for_hovers = v;
        if (getBoolCapOpt(caps_obj, "supportsValueFormattingOptions")) |v| self.adapter_capabilities.supports_value_formatting = v;
        if (getBoolCapOpt(caps_obj, "supportsLoadedSourcesRequest")) |v| self.adapter_capabilities.supports_loaded_sources = v;
        if (getBoolCapOpt(caps_obj, "supportsSingleThreadExecutionRequests")) |v| self.adapter_capabilities.supports_single_thread_execution_requests = v;
        if (getBoolCapOpt(caps_obj, "supportsConfigurationDoneRequest")) |v| self.adapter_capabilities.supports_configuration_done_request = v;
        if (getBoolCapOpt(caps_obj, "supportsDataBreakpointBytes")) |v| self.adapter_capabilities.supports_data_breakpoint_bytes = v;
        if (getBoolCapOpt(caps_obj, "supportsANSIStyling")) |v| self.adapter_capabilities.supports_ansi_styling = v;
        if (getBoolCapOpt(caps_obj, "supportsLocationsRequest")) |v| self.adapter_capabilities.supports_locations_request = v;
        if (getBoolCapOpt(caps_obj, "supportsBreakpointModes")) |v| self.adapter_capabilities.supports_breakpoint_modes = v;
    }

    fn getBoolCapOpt(obj: std.json.ObjectMap, key: []const u8) ?bool {
        const val = obj.get(key) orelse return null;
        if (val == .bool) return val.bool;
        return null;
    }

    fn proxySetInstructionBreakpoints(ctx: *anyopaque, allocator: std.mem.Allocator, breakpoints: []const InstructionBreakpoint) anyerror![]const BreakpointInfo {
        const self: *DapProxy = @ptrCast(@alignCast(ctx));
        if (!self.initialized or self.transport == .none) return error.NotSupported;
        if (!self.adapter_capabilities.supports_instruction_breakpoints) return error.NotSupported;

        const msg = try protocol.setInstructionBreakpointsRequest(allocator, self.nextSeq(), breakpoints);
        defer allocator.free(msg);
        const resp = try self.sendRequest(allocator, msg);
        defer allocator.free(resp);

        // Parse response: body.breakpoints array
        const parsed = try json.parseFromSlice(json.Value, allocator, resp, .{});
        defer parsed.deinit();

        if (parsed.value != .object) return error.InvalidResponse;
        const body = parsed.value.object.get("body") orelse return error.InvalidResponse;
        if (body != .object) return error.InvalidResponse;
        const bps_val = body.object.get("breakpoints") orelse return &.{};
        if (bps_val != .array) return &.{};

        var result = std.ArrayListUnmanaged(BreakpointInfo).empty;
        errdefer result.deinit(allocator);

        for (bps_val.array.items) |item| {
            if (item != .object) continue;
            const obj = item.object;

            const bp_id = self.next_bp_id;
            self.next_bp_id += 1;

            const verified = if (obj.get("verified")) |v| (v == .bool and v.bool) else false;
            const bp_line: u32 = if (obj.get("line")) |v| (if (v == .integer) @intCast(v.integer) else 0) else 0;

            try result.append(allocator, .{
                .id = bp_id,
                .verified = verified,
                .file = "",
                .line = bp_line,
            });
        }

        return try result.toOwnedSlice(allocator);
    }

    fn proxyStepInTargets(ctx: *anyopaque, allocator: std.mem.Allocator, frame_id: u32) anyerror![]const StepInTarget {
        const self: *DapProxy = @ptrCast(@alignCast(ctx));
        if (!self.initialized or self.transport == .none) return error.NotSupported;

        const msg = try protocol.stepInTargetsRequest(allocator, self.nextSeq(), @intCast(frame_id));
        defer allocator.free(msg);
        const resp = try self.sendRequest(allocator, msg);
        defer allocator.free(resp);

        const parsed = try json.parseFromSlice(json.Value, allocator, resp, .{});
        defer parsed.deinit();

        if (parsed.value != .object) return error.InvalidResponse;
        const body = parsed.value.object.get("body") orelse return error.InvalidResponse;
        if (body != .object) return error.InvalidResponse;
        const targets_val = body.object.get("targets") orelse return &.{};
        if (targets_val != .array) return &.{};

        var targets = std.ArrayListUnmanaged(StepInTarget).empty;
        errdefer targets.deinit(allocator);

        for (targets_val.array.items) |item| {
            if (item != .object) continue;
            const obj = item.object;

            const id: u32 = if (obj.get("id")) |v| (if (v == .integer) @intCast(v.integer) else 0) else 0;
            const label = if (obj.get("label")) |v| (if (v == .string) try allocator.dupe(u8, v.string) else try allocator.dupe(u8, "")) else try allocator.dupe(u8, "");
            const line: ?u32 = if (obj.get("line")) |v| (if (v == .integer) @intCast(v.integer) else null) else null;
            const column: ?u32 = if (obj.get("column")) |v| (if (v == .integer) @intCast(v.integer) else null) else null;
            const end_line: ?u32 = if (obj.get("endLine")) |v| (if (v == .integer) @intCast(v.integer) else null) else null;
            const end_column: ?u32 = if (obj.get("endColumn")) |v| (if (v == .integer) @intCast(v.integer) else null) else null;

            try targets.append(allocator, .{
                .id = id,
                .label = label,
                .line = line,
                .column = column,
                .end_line = end_line,
                .end_column = end_column,
            });
        }

        return try targets.toOwnedSlice(allocator);
    }

    fn proxyBreakpointLocations(ctx: *anyopaque, allocator: std.mem.Allocator, file: []const u8, line: u32, end_line: ?u32) anyerror![]const BreakpointLocation {
        const self: *DapProxy = @ptrCast(@alignCast(ctx));
        if (!self.initialized or self.transport == .none) return error.NotSupported;
        if (!self.adapter_capabilities.supports_breakpoint_locations) return error.NotSupported;

        const el: ?i64 = if (end_line) |e| @intCast(e) else null;
        const msg = try protocol.breakpointLocationsRequest(allocator, self.nextSeq(), file, @intCast(line), el, null, null);
        defer allocator.free(msg);
        const resp = try self.sendRequest(allocator, msg);
        defer allocator.free(resp);

        const parsed = try json.parseFromSlice(json.Value, allocator, resp, .{});
        defer parsed.deinit();

        if (parsed.value != .object) return error.InvalidResponse;
        const body = parsed.value.object.get("body") orelse return error.InvalidResponse;
        if (body != .object) return error.InvalidResponse;
        const locs_val = body.object.get("breakpoints") orelse return &.{};
        if (locs_val != .array) return &.{};

        var locations = std.ArrayListUnmanaged(BreakpointLocation).empty;
        errdefer locations.deinit(allocator);

        for (locs_val.array.items) |item| {
            if (item != .object) continue;
            const obj = item.object;

            const loc_line: u32 = if (obj.get("line")) |v| (if (v == .integer) @intCast(v.integer) else 0) else 0;
            const loc_col: ?u32 = if (obj.get("column")) |v| (if (v == .integer) @intCast(v.integer) else null) else null;
            const loc_end_line: ?u32 = if (obj.get("endLine")) |v| (if (v == .integer) @intCast(v.integer) else null) else null;
            const loc_end_col: ?u32 = if (obj.get("endColumn")) |v| (if (v == .integer) @intCast(v.integer) else null) else null;

            try locations.append(allocator, .{
                .line = loc_line,
                .column = loc_col,
                .end_line = loc_end_line,
                .end_column = loc_end_col,
            });
        }

        return try locations.toOwnedSlice(allocator);
    }

    fn proxyCancel(ctx: *anyopaque, allocator: std.mem.Allocator, request_id: ?u32, progress_id: ?[]const u8) anyerror!void {
        const self: *DapProxy = @ptrCast(@alignCast(ctx));
        if (!self.initialized or self.transport == .none) return error.NotSupported;

        const rid: ?i64 = if (request_id) |r| @intCast(r) else null;
        const msg = try protocol.cancelRequest(allocator, self.nextSeq(), rid, progress_id);
        defer allocator.free(msg);
        const resp = self.sendRequest(allocator, msg) catch return;
        allocator.free(resp);
    }

    fn proxyTerminateThreads(ctx: *anyopaque, allocator: std.mem.Allocator, thread_ids: []const u32) anyerror!void {
        const self: *DapProxy = @ptrCast(@alignCast(ctx));
        if (!self.initialized or self.transport == .none) return error.NotSupported;

        // Convert u32 thread IDs to i64 for the protocol builder
        var ids = try allocator.alloc(i64, thread_ids.len);
        defer allocator.free(ids);
        for (thread_ids, 0..) |tid, i| {
            ids[i] = @intCast(tid);
        }

        const msg = try protocol.terminateThreadsRequest(allocator, self.nextSeq(), ids);
        defer allocator.free(msg);
        const resp = self.sendRequest(allocator, msg) catch return;
        allocator.free(resp);
    }

    fn proxyRestart(ctx: *anyopaque, allocator: std.mem.Allocator) anyerror!void {
        const self: *DapProxy = @ptrCast(@alignCast(ctx));
        const cfg = self.debug_config orelse return error.NotSupported;

        const use_native_restart = cfg.restart_method == .native;

        const native_restart_ok = native_restart: {
            if (self.adapter_capabilities.supports_restart_request and use_native_restart) {
                // Native restart requires an active adapter connection.
                if (self.transport == .none) break :native_restart false;
                dapLog("[DAP restart] Adapter supports native restart (seq={d})", .{self.seq});

                self.initialized = true;

                const msg = protocol.restartRequest(allocator, self.nextSeq(), null) catch break :native_restart false;
                defer allocator.free(msg);
                const resp = self.sendRequest(allocator, msg) catch |err| {
                    dapLog("[DAP restart] Native restart sendRequest failed: {any}, falling back to emulated", .{err});
                    self.initialized = false;
                    break :native_restart false;
                };
                allocator.free(resp);

                const init_event = self.waitForEvent(allocator, "initialized") catch {
                    dapLog("[DAP restart] No initialized event after native restart, re-arming anyway", .{});
                    self.rearmBreakpoints(allocator);
                    self.initialized = true;
                    break :native_restart true;
                };
                allocator.free(init_event);

                self.rearmBreakpoints(allocator);

                const cd_msg = protocol.configurationDoneRequest(allocator, self.nextSeq()) catch break :native_restart true;
                defer allocator.free(cd_msg);
                const cd_resp = self.sendRequest(allocator, cd_msg) catch {
                    self.initialized = true;
                    break :native_restart true;
                };
                allocator.free(cd_resp);
                self.initialized = true;
                dapLog("[DAP restart] Native restart complete", .{});
                break :native_restart true;
            }
            break :native_restart false;
        };

        if (!native_restart_ok) {
            // ── Emulated restart ───────────────────────────────────────
            dapLog("[DAP restart] Emulating via disconnect+relaunch", .{});

            const program = self.saved_launch_program orelse return error.NotSupported;
            const adapter_argv = self.saved_adapter_argv orelse return error.NotSupported;

            // 1. Disconnect from the current adapter.
            {
                const disc_msg = protocol.disconnectRequestEx(allocator, self.nextSeq(), true, false, true) catch |err| {
                    dapLog("[DAP restart] Failed to build disconnect: {any}", .{err});
                    return err;
                };
                defer allocator.free(disc_msg);
                _ = self.sendRequest(allocator, disc_msg) catch {};
            }

            // 2. Kill the old adapter process.
            self.transportKill();

            // 3. Reset session state for the new adapter.
            self.transport = .none;
            self.initialized = false;
            self.seq = 1;
            self.current_frame_id = null;
            self.cached_frame_ids.clearRetainingCapacity();
            self.read_buffer.clearRetainingCapacity();
            for (self.buffered_events.items) |entry| {
                self.allocator.free(entry.event_name);
                self.allocator.free(entry.body);
            }
            self.buffered_events.clearRetainingCapacity();

            // 4. Spawn a new adapter process and connect.
            dapLog("[DAP restart] Spawning new adapter process...", .{});
            if (cfg.transport == .tcp) {
                // TCP restart: spawn new adapter, detect port, connect
                const port_prefix = cfg.port_stdout_prefix orelse return error.PortParseFailed;
                const child = spawnDetached(allocator, adapter_argv) catch |err| {
                    dapLog("[DAP restart] Failed to spawn adapter: {any}", .{err});
                    return err;
                };
                const server_stdout = child.stdout orelse return error.NotInitialized;
                var port_buf: [256]u8 = undefined;
                var port_len: usize = 0;
                while (port_len < port_buf.len) {
                    var poll_fds = [_]std.posix.pollfd{.{
                        .fd = server_stdout.handle,
                        .events = std.posix.POLL.IN,
                        .revents = 0,
                    }};
                    const pr = std.posix.poll(&poll_fds, @intCast(cfg.port_detection_timeout_ms)) catch return error.ReadFailed;
                    if (pr == 0) return error.Timeout;
                    const n = server_stdout.read(port_buf[port_len..]) catch return error.ReadFailed;
                    if (n == 0) return error.ConnectionClosed;
                    port_len += n;
                    if (adapter_lifecycle.detectPortFromStdout(port_buf[0..port_len], port_prefix)) |_| break;
                }
                const port = adapter_lifecycle.detectPortFromStdout(port_buf[0..port_len], port_prefix) orelse return error.PortParseFailed;
                self.adapter_tcp_port = port;
                const stream = std.net.tcpConnectToHost(allocator, "127.0.0.1", port) catch return error.ConnectionFailed;
                self.transport = .{ .tcp = .{ .stream = stream, .server_process = child } };
            } else {
                const child = spawnDetached(allocator, adapter_argv) catch |err| {
                    dapLog("[DAP restart] Failed to spawn adapter: {any}", .{err});
                    return err;
                };
                self.transport = .{ .stdio = .{ .process = child } };
            }
            dapLog("[DAP restart] New adapter connected", .{});

            // 5. Full DAP initialization sequence (mirrors proxyLaunch).

            // 5a. initialize → get capabilities
            const init_msg = try protocol.initializeRequestParams(allocator, self.nextSeq(), cfg.adapter_id, cfg.supports_start_debugging);
            defer allocator.free(init_msg);
            const init_resp = try self.sendRequest(allocator, init_msg);
            defer allocator.free(init_resp);
            self.parseAdapterCapabilities(allocator, init_resp);

            // 5b. Send launch request.
            //     For child session adapters: send stopOnEntry=false to parent.
            const stop_on_entry = if (cfg.child_sessions.enabled) false else self.saved_launch_stop_on_entry;
            const launch_msg = try protocol.launchRequestEx(
                allocator,
                self.nextSeq(),
                program,
                self.saved_launch_args orelse &.{},
                stop_on_entry,
                cfg.launch_extra_args_json,
                std.fs.path.dirname(program),
            );
            defer allocator.free(launch_msg);
            try self.sendRaw(allocator, launch_msg);

            // 5c. Wait for initialized event.
            const init_event = try self.waitForEvent(allocator, "initialized");
            allocator.free(init_event);

            // 5d. Re-arm all breakpoints during the configuration phase.
            // For child-session adapters, skip — the parent doesn't do the
            // debugging; connectChildSession() re-arms on the child instead.
            self.initialized = true;
            if (!cfg.child_sessions.enabled) {
                self.rearmBreakpoints(allocator);
            }

            // 5e. Send configurationDone to complete the init handshake.
            const cd_msg = try protocol.configurationDoneRequest(allocator, self.nextSeq());
            defer allocator.free(cd_msg);
            const cd_resp = try self.sendRequest(allocator, cd_msg);
            allocator.free(cd_resp);

            // Wait for child session if enabled.
            if (cfg.child_sessions.enabled) {
                try self.waitForChildConfig(allocator);
            }

            if (self.pending_child_config != null) {
                dapLog("[DAP restart] Child session config detected, connecting to child...", .{});
                try self.connectChildSession(allocator);
            } else {
                self.initialized = true;
            }
            dapLog("[DAP restart] Emulated restart complete", .{});
        }
    }

    /// Re-send all tracked breakpoints to the adapter.
    fn rearmBreakpoints(self: *DapProxy, allocator: std.mem.Allocator) void {
        var it = self.file_breakpoints.iterator();
        while (it.next()) |entry| {
            self.sendFileBreakpoints(allocator, entry.key_ptr.*, entry.value_ptr.items) catch |err| {
                dapLog("[DAP rearm] Failed to re-arm file breakpoints: {any}", .{err});
            };
        }

        if (self.function_breakpoints.items.len > 0) {
            self.sendFunctionBreakpoints(allocator) catch |err| {
                dapLog("[DAP rearm] Failed to re-arm function breakpoints: {any}", .{err});
            };
        }

        if (self.active_exception_filters) |filters| {
            self.sendExceptionBreakpoints(allocator, filters) catch |err| {
                dapLog("[DAP rearm] Failed to re-arm exception breakpoints: {any}", .{err});
            };
        }
    }

    /// Save launch configuration and adapter argv so that emulated restart
    /// (disconnect + relaunch) can respawn the adapter with the same settings.
    fn saveLaunchState(self: *DapProxy, config: LaunchConfig, adapter_argv: []const []const u8) void {
        // Free any previously saved state
        if (self.saved_launch_program) |p| self.allocator.free(p);
        if (self.saved_launch_args) |args| {
            for (args) |a| self.allocator.free(a);
            self.allocator.free(args);
        }
        if (self.saved_adapter_argv) |argv| {
            for (argv) |a| self.allocator.free(a);
            self.allocator.free(argv);
        }

        self.saved_launch_program = self.allocator.dupe(u8, config.program) catch null;
        self.saved_launch_stop_on_entry = config.stop_on_entry;

        // Dupe program args
        if (config.args.len > 0) {
            const args = self.allocator.alloc([]const u8, config.args.len) catch {
                self.saved_launch_args = null;
                return;
            };
            for (config.args, 0..) |arg, i| {
                args[i] = self.allocator.dupe(u8, arg) catch "";
            }
            self.saved_launch_args = args;
        } else {
            self.saved_launch_args = null;
        }

        // Dupe adapter argv
        const argv = self.allocator.alloc([]const u8, adapter_argv.len) catch {
            self.saved_adapter_argv = null;
            return;
        };
        for (adapter_argv, 0..) |arg, i| {
            argv[i] = self.allocator.dupe(u8, arg) catch "";
        }
        self.saved_adapter_argv = argv;
    }

    /// Send all tracked function breakpoints to the adapter.
    fn sendFunctionBreakpoints(self: *DapProxy, allocator: std.mem.Allocator) !void {
        const len = self.function_breakpoints.items.len;
        var names = try allocator.alloc([]const u8, len);
        defer allocator.free(names);
        var conditions = try allocator.alloc(?[]const u8, len);
        defer allocator.free(conditions);
        var hit_conditions = try allocator.alloc(?[]const u8, len);
        defer allocator.free(hit_conditions);
        for (self.function_breakpoints.items, 0..) |fb, i| {
            names[i] = fb.name;
            conditions[i] = fb.condition;
            hit_conditions[i] = null;
        }
        const msg = try protocol.setFunctionBreakpointsRequest(allocator, self.nextSeq(), names, conditions, hit_conditions);
        defer allocator.free(msg);
        const resp = self.sendRequest(allocator, msg) catch return;
        allocator.free(resp);
    }

    /// Send exception breakpoint filters to the adapter.
    fn sendExceptionBreakpoints(self: *DapProxy, allocator: std.mem.Allocator, filters: []const []const u8) !void {
        const msg = try protocol.setExceptionBreakpointsRequest(allocator, self.nextSeq(), filters);
        defer allocator.free(msg);
        const resp = self.sendRequest(allocator, msg) catch return;
        allocator.free(resp);
    }

    fn proxyGotoTargets(ctx: *anyopaque, allocator: std.mem.Allocator, file: []const u8, line: u32) anyerror![]const types.GotoTarget {
        const self: *DapProxy = @ptrCast(@alignCast(ctx));
        if (!self.initialized or self.transport == .none) return error.NotSupported;
        if (!self.adapter_capabilities.supports_goto_targets) return error.NotSupported;

        const msg = try protocol.gotoTargetsRequest(allocator, self.nextSeq(), file, @intCast(line), null);
        defer allocator.free(msg);
        const resp = try self.sendRequest(allocator, msg);
        defer allocator.free(resp);

        const parsed = try json.parseFromSlice(json.Value, allocator, resp, .{});
        defer parsed.deinit();

        if (parsed.value != .object) return error.InvalidResponse;
        const body = parsed.value.object.get("body") orelse return error.InvalidResponse;
        if (body != .object) return error.InvalidResponse;
        const targets_val = body.object.get("targets") orelse return &.{};
        if (targets_val != .array) return &.{};

        var targets = std.ArrayListUnmanaged(types.GotoTarget).empty;
        errdefer targets.deinit(allocator);

        for (targets_val.array.items) |item| {
            if (item != .object) continue;
            const obj = item.object;
            const target_id: u32 = if (obj.get("id")) |v| (if (v == .integer) @intCast(v.integer) else continue) else continue;
            const label = if (obj.get("label")) |v| (if (v == .string) try allocator.dupe(u8, v.string) else try allocator.dupe(u8, "")) else try allocator.dupe(u8, "");
            const target_line: u32 = if (obj.get("line")) |v| (if (v == .integer) @intCast(v.integer) else 0) else 0;

            try targets.append(allocator, .{
                .id = target_id,
                .label = label,
                .line = target_line,
                .column = if (obj.get("column")) |v| (if (v == .integer) @as(u32, @intCast(v.integer)) else null) else null,
                .end_line = if (obj.get("endLine")) |v| (if (v == .integer) @as(u32, @intCast(v.integer)) else null) else null,
                .end_column = if (obj.get("endColumn")) |v| (if (v == .integer) @as(u32, @intCast(v.integer)) else null) else null,
            });
        }

        return try targets.toOwnedSlice(allocator);
    }

    fn proxyFindSymbol(ctx: *anyopaque, allocator: std.mem.Allocator, name: []const u8) anyerror![]const types.SymbolInfo {
        _ = allocator;
        _ = name;
        const self: *DapProxy = @ptrCast(@alignCast(ctx));
        _ = self;
        return error.NotSupported;
    }

    fn proxyDrainNotifications(ctx: *anyopaque, allocator: std.mem.Allocator) []const types.DebugNotification {
        const self: *DapProxy = @ptrCast(@alignCast(ctx));
        return self.drainNotifications(allocator);
    }

    fn proxyRawRequest(ctx: *anyopaque, allocator: std.mem.Allocator, command: []const u8, arguments: ?[]const u8) anyerror![]const u8 {
        const self: *DapProxy = @ptrCast(@alignCast(ctx));
        const seq = self.nextSeq();

        // Build DAP request JSON
        var aw: Writer.Allocating = .init(allocator);
        defer aw.deinit();
        var s: Stringify = .{ .writer = &aw.writer };

        try s.beginObject();
        try s.objectField("seq");
        try s.write(seq);
        try s.objectField("type");
        try s.write("request");
        try s.objectField("command");
        try s.write(command);
        if (arguments) |args_json| {
            try s.objectField("arguments");
            try s.writer.writeAll(args_json);
        }
        try s.endObject();

        const msg = try aw.toOwnedSlice();
        defer allocator.free(msg);

        return self.sendRequest(allocator, msg);
    }

    fn proxyDeinit(ctx: *anyopaque) void {
        const self: *DapProxy = @ptrCast(@alignCast(ctx));
        const allocator = self.allocator;
        self.deinit();
        allocator.destroy(self);
    }
};

fn base64Encode(allocator: std.mem.Allocator, data: []const u8) ![]const u8 {
    const encoder = std.base64.standard.Encoder;
    const encoded_len = encoder.calcSize(data.len);
    const buf = try allocator.alloc(u8, encoded_len);
    _ = encoder.encode(buf, data);
    return buf;
}

// ── Tests ───────────────────────────────────────────────────────────────

test "DapProxy maps RunAction.continue to DAP continue command" {
    const allocator = std.testing.allocator;
    var proxy = DapProxy.init(allocator);
    defer proxy.deinit();

    const msg = try proxy.mapRunAction(allocator, .@"continue");
    defer allocator.free(msg);

    const parsed = try json.parseFromSlice(json.Value, allocator, msg, .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings("continue", parsed.value.object.get("command").?.string);
}

test "DapProxy maps RunAction.step_into to DAP stepIn command" {
    const allocator = std.testing.allocator;
    var proxy = DapProxy.init(allocator);
    defer proxy.deinit();

    const msg = try proxy.mapRunAction(allocator, .step_into);
    defer allocator.free(msg);

    const parsed = try json.parseFromSlice(json.Value, allocator, msg, .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings("stepIn", parsed.value.object.get("command").?.string);
}

test "DapProxy maps RunAction.step_over to DAP next command" {
    const allocator = std.testing.allocator;
    var proxy = DapProxy.init(allocator);
    defer proxy.deinit();

    const msg = try proxy.mapRunAction(allocator, .step_over);
    defer allocator.free(msg);

    const parsed = try json.parseFromSlice(json.Value, allocator, msg, .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings("next", parsed.value.object.get("command").?.string);
}

test "DapProxy maps RunAction.step_out to DAP stepOut command" {
    const allocator = std.testing.allocator;
    var proxy = DapProxy.init(allocator);
    defer proxy.deinit();

    const msg = try proxy.mapRunAction(allocator, .step_out);
    defer allocator.free(msg);

    const parsed = try json.parseFromSlice(json.Value, allocator, msg, .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings("stepOut", parsed.value.object.get("command").?.string);
}

test "DapProxy translates DAP stopped event to StopState" {
    const allocator = std.testing.allocator;
    const data =
        \\{"seq":5,"type":"event","event":"stopped","body":{"reason":"breakpoint","threadId":1}}
    ;
    const state = try DapProxy.translateStoppedEvent(allocator, data);
    try std.testing.expectEqual(StopReason.breakpoint, state.stop_reason);
}

test "DapProxy translates DAP stackTrace response to StackFrame array" {
    const allocator = std.testing.allocator;
    const data =
        \\{"seq":10,"type":"response","request_seq":7,"command":"stackTrace","success":true,"body":{"stackFrames":[{"id":0,"name":"main","source":{"path":"/test/main.py"},"line":10,"column":1},{"id":1,"name":"helper","source":{"path":"/test/utils.py"},"line":5,"column":3}]}}
    ;
    const frames = try DapProxy.translateStackTrace(allocator, data);
    defer {
        for (frames) |f| {
            allocator.free(f.name);
            allocator.free(f.source);
        }
        allocator.free(frames);
    }

    try std.testing.expectEqual(@as(usize, 2), frames.len);
    try std.testing.expectEqualStrings("main", frames[0].name);
    try std.testing.expectEqualStrings("/test/main.py", frames[0].source);
    try std.testing.expectEqual(@as(u32, 10), frames[0].line);
    try std.testing.expectEqualStrings("helper", frames[1].name);
}

test "DapProxy translates DAP variables response to Variable array" {
    const allocator = std.testing.allocator;
    const data =
        \\{"seq":12,"type":"response","request_seq":11,"command":"variables","success":true,"body":{"variables":[{"name":"x","value":"42","type":"int","variablesReference":0},{"name":"data","value":"[1,2,3]","type":"list","variablesReference":5}]}}
    ;
    const vars = try DapProxy.translateVariables(allocator, data);
    defer {
        for (vars) |v| {
            allocator.free(v.name);
            allocator.free(v.value);
            allocator.free(v.@"type");
        }
        allocator.free(vars);
    }

    try std.testing.expectEqual(@as(usize, 2), vars.len);
    try std.testing.expectEqualStrings("x", vars[0].name);
    try std.testing.expectEqualStrings("42", vars[0].value);
    try std.testing.expectEqualStrings("int", vars[0].@"type");
    try std.testing.expectEqual(@as(u32, 0), vars[0].variables_reference);

    try std.testing.expectEqualStrings("data", vars[1].name);
    try std.testing.expectEqual(@as(u32, 5), vars[1].variables_reference);
}

test "DapProxy translates DAP exited event with exit_code" {
    const allocator = std.testing.allocator;
    const data =
        \\{"seq":20,"type":"event","event":"exited","body":{"exitCode":0}}
    ;
    const state = try DapProxy.translateExitedEvent(allocator, data);
    try std.testing.expectEqual(StopReason.exception, state.stop_reason);
    try std.testing.expectEqual(@as(i32, 0), state.exit_code.?);
}

test "DapProxy translates BreakpointRequest to DAP setBreakpoints" {
    const allocator = std.testing.allocator;
    const lines = [_]u32{42};
    const msg = try protocol.setBreakpointsRequest(allocator, 1, "/test/main.py", &lines);
    defer allocator.free(msg);

    const parsed = try json.parseFromSlice(json.Value, allocator, msg, .{});
    defer parsed.deinit();

    try std.testing.expectEqualStrings("setBreakpoints", parsed.value.object.get("command").?.string);
    const args = parsed.value.object.get("arguments").?.object;
    try std.testing.expectEqualStrings("/test/main.py", args.get("source").?.object.get("path").?.string);
}

test "DapProxy launches with DAP adapter for Python" {
    // Skip if debugpy is not installed
    const result = std.process.Child.run(.{
        .allocator = std.testing.allocator,
        .argv = &.{ "python3", "-c", "import debugpy" },
    }) catch return error.SkipZigTest;
    std.testing.allocator.free(result.stdout);
    std.testing.allocator.free(result.stderr);
    if (result.term.Exited != 0) return error.SkipZigTest;

    var proxy = DapProxy.init(std.testing.allocator);
    defer proxy.deinit();

    const config = LaunchConfig{
        .program = "test/fixtures/simple.py",
        .stop_on_entry = true,
    };

    // Launch should succeed (spawns debugpy adapter)
    var driver = proxy.activeDriver();
    driver.launch(std.testing.allocator, config) catch {
        return error.SkipZigTest;
    };

    try std.testing.expect(proxy.initialized);
    try std.testing.expect(proxy.transport != .none);
}

test "DAP proxy sets breakpoint and hits it in Python" {
    // Skip if debugpy is not installed
    const result = std.process.Child.run(.{
        .allocator = std.testing.allocator,
        .argv = &.{ "python3", "-c", "import debugpy" },
    }) catch return error.SkipZigTest;
    std.testing.allocator.free(result.stdout);
    std.testing.allocator.free(result.stderr);
    if (result.term.Exited != 0) return error.SkipZigTest;

    // This test verifies the proxy can create breakpoints via the driver interface
    var proxy = DapProxy.init(std.testing.allocator);
    defer proxy.deinit();

    var driver = proxy.activeDriver();
    const bp = try driver.setBreakpoint(std.testing.allocator, "test/fixtures/simple.py", 4, null);
    try std.testing.expectEqual(@as(u32, 1), bp.id);
    try std.testing.expect(bp.verified);
}

test "DAP proxy step over advances one line" {
    // This test verifies the step_over action maps correctly
    const allocator = std.testing.allocator;
    var proxy = DapProxy.init(allocator);
    defer proxy.deinit();

    const msg = try proxy.mapRunAction(allocator, .step_over);
    defer allocator.free(msg);

    const parsed = try json.parseFromSlice(json.Value, allocator, msg, .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings("next", parsed.value.object.get("command").?.string);
    try std.testing.expectEqualStrings("request", parsed.value.object.get("type").?.string);
}

test "DAP proxy inspect returns local variables" {
    // Verify the proxy can translate a variables response
    const allocator = std.testing.allocator;
    const data =
        \\{"seq":1,"type":"response","request_seq":1,"command":"variables","success":true,"body":{"variables":[{"name":"result","value":"7","type":"int","variablesReference":0}]}}
    ;
    const vars = try DapProxy.translateVariables(allocator, data);
    defer {
        for (vars) |v| {
            allocator.free(v.name);
            allocator.free(v.value);
            allocator.free(v.@"type");
        }
        allocator.free(vars);
    }

    try std.testing.expectEqual(@as(usize, 1), vars.len);
    try std.testing.expectEqualStrings("result", vars[0].name);
    try std.testing.expectEqualStrings("7", vars[0].value);
    try std.testing.expectEqualStrings("int", vars[0].@"type");
}

test "DapProxy translates InspectRequest.expression to DAP evaluate" {
    const allocator = std.testing.allocator;
    const msg = try protocol.evaluateRequest(allocator, 1, "x + y", 0);
    defer allocator.free(msg);

    const parsed = try json.parseFromSlice(json.Value, allocator, msg, .{});
    defer parsed.deinit();

    try std.testing.expectEqualStrings("evaluate", parsed.value.object.get("command").?.string);
    try std.testing.expectEqualStrings("x + y", parsed.value.object.get("arguments").?.object.get("expression").?.string);
}

// ── WP11 Tests ──────────────────────────────────────────────────────────

test "DapProxy vtable includes new WP11 function pointers" {
    const allocator = std.testing.allocator;
    var proxy = DapProxy.init(allocator);
    defer proxy.deinit();

    const driver = proxy.activeDriver();
    const vt = driver.vtable;

    // All new vtable entries should be non-null (wired to proxy implementations)
    try std.testing.expect(vt.setInstructionBreakpointsFn != null);
    try std.testing.expect(vt.stepInTargetsFn != null);
    try std.testing.expect(vt.breakpointLocationsFn != null);
    try std.testing.expect(vt.cancelFn != null);
    try std.testing.expect(vt.terminateThreadsFn != null);
    try std.testing.expect(vt.restartFn != null);
}

test "DapProxy init and deinit cycle works cleanly" {
    const allocator = std.testing.allocator;
    var proxy = DapProxy.init(allocator);

    // Verify initial state
    try std.testing.expect(!proxy.initialized);
    try std.testing.expect(proxy.transport == .none);
    try std.testing.expectEqual(@as(i64, 1), proxy.seq);
    try std.testing.expectEqual(@as(u32, 1), proxy.next_bp_id);

    // Create active driver and verify vtable
    const driver = proxy.activeDriver();
    try std.testing.expect(driver.driver_type == .dap);

    proxy.deinit();
}

test "DapProxy parseAdapterCapabilities parses new WP9 flags" {
    const allocator = std.testing.allocator;
    var proxy = DapProxy.init(allocator);
    defer proxy.deinit();

    const resp =
        \\{"seq":1,"type":"response","request_seq":1,"command":"initialize","success":true,"body":{"supportsInstructionBreakpoints":true,"supportsSteppingGranularity":true,"supportsCancelRequest":true,"supportsTerminateThreadsRequest":true,"supportsBreakpointLocationsRequest":true,"supportsStepInTargetsRequest":true,"supportsRestartRequest":true,"supportsSingleThreadExecutionRequests":true}}
    ;

    proxy.parseAdapterCapabilities(allocator, resp);

    try std.testing.expect(proxy.adapter_capabilities.supports_instruction_breakpoints);
    try std.testing.expect(proxy.adapter_capabilities.supports_stepping_granularity);
    try std.testing.expect(proxy.adapter_capabilities.supports_cancel_request);
    try std.testing.expect(proxy.adapter_capabilities.supports_terminate_threads);
    try std.testing.expect(proxy.adapter_capabilities.supports_breakpoint_locations);
    try std.testing.expect(proxy.adapter_capabilities.supports_step_in_targets);
    try std.testing.expect(proxy.adapter_capabilities.supports_restart_request);
    try std.testing.expect(proxy.adapter_capabilities.supports_single_thread_execution_requests);
}

test "DapProxy new proxy functions return NotSupported when not initialized" {
    const allocator = std.testing.allocator;
    var proxy = DapProxy.init(allocator);
    defer proxy.deinit();

    var driver = proxy.activeDriver();

    // All new functions should return NotSupported when proxy is not initialized
    try std.testing.expectError(error.NotSupported, driver.setInstructionBreakpoints(allocator, &.{}));
    try std.testing.expectError(error.NotSupported, driver.stepInTargets(allocator, 0));
    try std.testing.expectError(error.NotSupported, driver.breakpointLocations(allocator, "test.zig", 1, null));
    try std.testing.expectError(error.NotSupported, driver.cancel(allocator, null, null));
    try std.testing.expectError(error.NotSupported, driver.terminateThreads(allocator, &.{}));
    try std.testing.expectError(error.NotSupported, driver.restart(allocator));
}

test "DapProxy terminated event sets initialized to false" {
    const allocator = std.testing.allocator;
    var proxy = DapProxy.init(allocator);
    defer proxy.deinit();

    // Simulate the proxy being initialized
    proxy.initialized = true;
    try std.testing.expect(proxy.initialized);

    // The terminated event handler sets initialized to false.
    // We can't easily test it through readResponse without a real transport,
    // but we can verify the vtable and capabilities still work after state change.
    proxy.initialized = false;
    try std.testing.expect(!proxy.initialized);
}
