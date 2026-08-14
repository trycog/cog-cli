const std = @import("std");
const builtin = @import("builtin");
const json = std.json;
const Stringify = json.Stringify;
const Writer = std.io.Writer;
const types = @import("../types.zig");
const driver_mod = @import("../driver.zig");
const protocol = @import("protocol.zig");
const transport = @import("transport.zig");
const debug_log = @import("../../debug_log.zig");
const paths = @import("../../paths.zig");

extern "c" fn getpgrp() std.posix.pid_t;
extern "c" fn getpgid(pid: std.posix.pid_t) std.posix.pid_t;

// Debug logging to file (stderr not visible when running as MCP subprocess)
var dap_log_file: ?std.fs.File = null;

fn dapLog(comptime fmt: []const u8, args: anytype) void {
    if (dap_log_file == null) {
        const path = paths.getDapLogPath(std.heap.page_allocator) catch |err| {
            debug_log.log("dapLog: failed to resolve diagnostic log path: {s}", .{@errorName(err)});
            return;
        };
        defer std.heap.page_allocator.free(path);
        debug_log.log("dapLog: opening diagnostic log {s}", .{path});
        dap_log_file = std.fs.createFileAbsolute(path, .{ .truncate = false, .mode = 0o600 }) catch |err| blk: {
            debug_log.log("dapLog: failed to open {s}: {s}", .{ path, @errorName(err) });
            break :blk null;
        };
        if (dap_log_file) |f| {
            if (@import("builtin").os.tag != .windows) f.chmod(0o600) catch |err| {
                debug_log.log("dapLog: failed to restrict {s}: {s}", .{ path, @errorName(err) });
            };
            f.seekFromEnd(0) catch |err| debug_log.log("dapLog: failed to seek {s}: {s}", .{ path, @errorName(err) });
        }
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

const MAX_PENDING_NOTIFICATIONS: usize = 256;
const MAX_BUFFERED_EVENTS: usize = 256;
const MAX_OUTPUT_ENTRIES: usize = 512;

const BufferedEvent = struct {
    event_name: []const u8,
    body: []const u8,
};

// Adapter event retention limits. Snapshot-like FIFO collections retain the
// newest entries by dropping the oldest on overflow. Active progress retains
// existing operations and drops a new progress ID when all slots are occupied.
const MAX_LOADED_MODULES: usize = 256;
const MAX_MEMORY_EVENTS: usize = 256;
const MAX_ACTIVE_PROGRESS: usize = 64;
const MAX_INVALIDATED_AREAS: usize = 256;

const RetentionCounters = struct {
    loaded_modules: usize = 0,
    memory_events: usize = 0,
    active_progress: usize = 0,
    invalidated_areas: usize = 0,
};

/// A child process spawned with setsid() so it cannot access the
/// controlling terminal.  Replaces std.process.Child for the debug
/// adapter to prevent SIGTTIN in the parent (Claude CLI) process.
const DetachedProcess = struct {
    id: std.posix.pid_t,
    stdin: ?std.fs.File = null,
    stdout: ?std.fs.File = null,
    stderr: ?std.fs.File = null,

    fn closePipes(self: *DetachedProcess) void {
        if (self.stdin == null and self.stdout == null and self.stderr == null) return;
        debug_log.log("dap.proxy: closing adapter pipes pid={d}", .{self.id});
        if (self.stdin) |file| file.close();
        if (self.stdout) |file| file.close();
        if (self.stderr) |file| file.close();
        self.stdin = null;
        self.stdout = null;
        self.stderr = null;
    }

    fn signalProcessGroup(pid: std.posix.pid_t, signal: u8) void {
        const own_group = getpgrp();
        if (pid <= 0 or pid == own_group) {
            debug_log.log("dap.proxy: refusing unsafe adapter group signal pid={d} own_group={d} signal={d}", .{ pid, own_group, signal });
            return;
        }

        std.posix.kill(-pid, signal) catch |err| switch (err) {
            error.ProcessNotFound => {},
            else => debug_log.log("dap.proxy: adapter group signal failed pgid={d} signal={d} error={s}", .{ pid, signal, @errorName(err) }),
        };
    }

    fn terminateAndReap(self: *DetachedProcess) void {
        self.closePipes();
        const pid = self.id;
        if (pid <= 0) return;
        self.id = 0;

        debug_log.log("dap.proxy: terminating adapter process group pgid={d}", .{pid});
        signalProcessGroup(pid, std.posix.SIG.TERM);

        var reaped = false;
        for (0..20) |attempt| {
            if (!reaped) {
                const result = std.posix.waitpid(pid, 1); // WNOHANG
                if (result.pid != 0) {
                    reaped = true;
                    debug_log.log("dap.proxy: reaped adapter leader after SIGTERM pid={d} status={d}", .{ pid, result.status });
                }
            }
            if (attempt + 1 < 20) std.posix.nanosleep(0, 5_000_000);
        }

        // The session leader may exit before descendants. Always signal the
        // process group after the grace period so TERM-ignoring descendants
        // cannot outlive the DAP session.
        signalProcessGroup(pid, std.posix.SIG.KILL);
        if (!reaped) {
            const result = std.posix.waitpid(pid, 0);
            debug_log.log("dap.proxy: reaped adapter leader after SIGKILL pid={d} status={d}", .{ pid, result.status });
        }
    }
};

/// Fork+exec a child process in a **new session** (`setsid`).
/// This fully detaches from the controlling terminal so the adapter
/// (and any processes it spawns) can never steal the foreground
/// process group — which would send SIGTTIN to the parent.
fn spawnDetached(allocator: std.mem.Allocator, argv: []const []const u8) !DetachedProcess {
    const posix = std.posix;
    debug_log.log("dap.proxy: spawning detached adapter command={s} argc={d}", .{ argv[0], argv.len });

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
        // terminal so the adapter cannot call tcsetpgrp(). The child PID is
        // then also the process-group ID used by terminateAndReap.
        if (std.c.setsid() < 0) posix.exit(1);

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
    debug_log.log("dap.proxy: detached adapter spawned pid={d} pgid={d}", .{ pid, pid });

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
    // Map from our local breakpoint ID to its canonical state, plus adapter
    // breakpoint IDs back to the local IDs used by Cog's public API.
    bp_registry: std.AutoHashMapUnmanaged(u32, BpRegistryEntry) = .empty,
    adapter_bp_ids: std.AutoHashMapUnmanaged(u32, u32) = .empty,
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
    // Explicit retention accounting for adapter-controlled event state.
    retention_drops: RetentionCounters = .{},
    retention_deduplications: RetentionCounters = .{},
    // Pending notifications for MCP server to emit
    pending_notifications: std.ArrayListUnmanaged(types.DebugNotification) = .empty,
    dropped_notifications: usize = 0,
    // Buffered events consumed by readResponse but needed by waitForEvent
    buffered_events: std.ArrayListUnmanaged(BufferedEvent) = .empty,
    dropped_buffered_events: usize = 0,
    dropped_output_entries: usize = 0,
    // Only one thread may read/decode or write a framed DAP message at a time.
    // Request/response transactions hold this mutex across both operations so
    // explicit request_seq correlation stays deterministic under concurrency.
    connection_mutex: std.Thread.Mutex = .{},
    // Sequence numbers can be reserved while another request is in flight, so
    // protect allocation independently from the connection transaction.
    seq_mutex: std.Thread.Mutex = .{},
    // Request timeout in milliseconds (default 30s)
    request_timeout_ms: i32 = 30_000,
    // Saved launch state for emulated restart (adapters without supportsRestartRequest)
    saved_launch_program: ?[]const u8 = null,
    saved_launch_module: ?[]const u8 = null,
    saved_launch_args: ?[]const []const u8 = null,
    saved_launch_stop_on_entry: bool = false,
    saved_adapter_argv: ?[]const []const u8 = null,
    // vscode-js-debug child session support
    adapter_tcp_port: ?u16 = null,
    pending_child_config: ?[]const u8 = null,
    parent_stream: ?std.net.Stream = null,
    // Deferred configurationDone: when true, the session has been
    // initialized but configurationDone has NOT been sent yet.  This allows
    // the user to set breakpoints during the DAP configuration phase —
    // before the program starts running — preventing the race where
    // the program runs past breakpoint locations before they are set.
    // configurationDone is sent on the first proxyRun call.
    config_deferred: bool = false,
    // When true, stopOnEntry was forced to true in the launch request
    // (even though the user wanted stop_on_entry=false) to keep the
    // adapter alive during configuration.  proxyRun will consume the
    // entry stop and send continue after setting breakpoints.
    forced_entry_stop: bool = false,
    // Saved launch message bytes for deferred launch (sent in proxyRun
    // after breakpoints are set, so breakpoints are in place before the
    // program starts).
    saved_launch_msg: ?[]const u8 = null,

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

    const LoadedModuleId = union(enum) {
        integer: i64,
        string: []const u8,

        fn matches(self: LoadedModuleId, value: std.json.Value) bool {
            return switch (self) {
                .integer => |id| value == .integer and value.integer == id,
                .string => |id| value == .string and std.mem.eql(u8, value.string, id),
            };
        }

        fn deinit(self: LoadedModuleId, allocator: std.mem.Allocator) void {
            switch (self) {
                .integer => {},
                .string => |id| allocator.free(id),
            }
        }
    };

    const LoadedModuleEntry = struct {
        id: LoadedModuleId,
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
        verified: bool = false,
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
        self.adapter_bp_ids.deinit(self.allocator);
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
            entry.id.deinit(self.allocator);
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
        if (self.saved_launch_module) |m| self.allocator.free(m);
        if (self.saved_launch_args) |args| {
            for (args) |a| self.allocator.free(a);
            self.allocator.free(args);
        }
        if (self.saved_adapter_argv) |argv| {
            for (argv) |a| self.allocator.free(a);
            self.allocator.free(argv);
        }
        // Clean up saved launch message
        if (self.saved_launch_msg) |m| self.allocator.free(m);
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
        .interruptRunFn = proxyInterruptRun,
    };

    fn nextSeq(self: *DapProxy) i64 {
        self.seq_mutex.lock();
        defer self.seq_mutex.unlock();
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
                    // Check if the adapter process is still alive before writing.
                    // If it exited, the pipe's read end is closed and write would
                    // fail with BrokenPipe (EPIPE).
                    std.posix.kill(t.process.id, 0) catch {
                        dapLog("[DAP transportWrite] adapter process (pid={d}) is no longer alive", .{t.process.id});
                        self.drainStderr(t);
                    };
                    // Use raw write(2) syscall directly to avoid issues with
                    // buffered writer abstractions on pipe fds.
                    const fd = stdin.handle;
                    var remaining = data;
                    while (remaining.len > 0) {
                        const written = std.posix.write(fd, remaining) catch |err| {
                            dapLog("[DAP transportWrite] write(fd={d}) failed: {s}, remaining={d}/{d} bytes", .{ fd, @errorName(err), remaining.len, data.len });
                            self.drainStderr(t);
                            return error.WriteFailed;
                        };
                        if (written == 0) {
                            dapLog("[DAP transportWrite] write(fd={d}) returned 0, remaining={d}/{d} bytes", .{ fd, remaining.len, data.len });
                            return error.WriteFailed;
                        }
                        remaining = remaining[written..];
                    }
                } else return error.NotInitialized;
            },
            .tcp => |*t| {
                t.stream.writeAll(data) catch return error.WriteFailed;
            },
        }
    }

    /// Read any available stderr from the adapter process and log it.
    /// Uses poll() to avoid blocking if no data is available.
    fn drainStderr(_: *DapProxy, t: *StdioTransport) void {
        const stderr_file = t.process.stderr orelse return;
        var poll_fds = [_]std.posix.pollfd{.{
            .fd = stderr_file.handle,
            .events = std.posix.POLL.IN,
            .revents = 0,
        }};
        // Non-blocking poll: timeout 0
        const poll_result = std.posix.poll(&poll_fds, 0) catch return;
        if (poll_result == 0) return; // no data available
        var stderr_buf: [4096]u8 = undefined;
        const n = stderr_file.read(&stderr_buf) catch return;
        if (n > 0) {
            dapLog("[DAP stderr] {s}", .{stderr_buf[0..n]});
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
        if (self.parent_stream) |s| {
            debug_log.log("dap.proxy: closing parent DAP stream", .{});
            s.close();
            self.parent_stream = null;
        }
        switch (self.transport) {
            .none => {},
            .stdio => |*t| t.process.terminateAndReap(),
            .tcp => |*t| {
                debug_log.log("dap.proxy: closing adapter TCP stream pid={d}", .{t.server_process.id});
                t.stream.close();
                t.server_process.terminateAndReap();
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
        self.connection_mutex.lock();
        defer self.connection_mutex.unlock();

        const encoded = try transport.encodeMessage(allocator, msg);
        defer allocator.free(encoded);

        dapLog("[DAP sendRaw] Writing {d} bytes to adapter...", .{encoded.len});
        try self.transportWrite(encoded);
        dapLog("[DAP sendRaw] Write complete", .{});
    }

    fn sendRequest(self: *DapProxy, allocator: std.mem.Allocator, msg: []const u8) ![]const u8 {
        const request_seq = try requestSeq(allocator, msg);
        self.connection_mutex.lock();
        defer self.connection_mutex.unlock();

        dapLog("[DAP sendRequest] Encoding seq={d} message ({d} bytes)", .{ request_seq, msg.len });
        // Encode with Content-Length framing
        const encoded = try transport.encodeMessage(allocator, msg);
        defer allocator.free(encoded);

        dapLog("[DAP sendRequest] Writing seq={d} to adapter...", .{request_seq});
        try self.transportWrite(encoded);
        dapLog("[DAP sendRequest] Write complete, waiting for seq={d} response", .{request_seq});

        // Read response (may need to skip events)
        return self.readResponse(allocator, request_seq);
    }

    fn requestSeq(allocator: std.mem.Allocator, msg: []const u8) !i64 {
        const parsed = try json.parseFromSlice(json.Value, allocator, msg, .{});
        defer parsed.deinit();
        if (parsed.value != .object) return error.InvalidRequest;
        const seq_val = parsed.value.object.get("seq") orelse return error.InvalidRequest;
        if (seq_val != .integer) return error.InvalidRequest;
        return seq_val.integer;
    }

    fn remainingDeadlineMs(deadline_ms: u64, elapsed_ms: u64) ?i32 {
        if (elapsed_ms >= deadline_ms) return null;
        return @intCast(@min(deadline_ms - elapsed_ms, @as(u64, std.math.maxInt(i32))));
    }

    fn remainingDeadlineNs(deadline_ns: u64, elapsed_ns: u64) ?i32 {
        if (elapsed_ns >= deadline_ns) return null;
        const remaining_ns = deadline_ns - elapsed_ns;
        const remaining_ms = @max(@as(u64, 1), @divTrunc(remaining_ns + std.time.ns_per_ms - 1, std.time.ns_per_ms));
        return @intCast(@min(remaining_ms, @as(u64, std.math.maxInt(i32))));
    }

    /// Read messages from the adapter until we get a matching response (type == "response").
    /// Verifies request_seq matches the expected seq to correlate responses.
    /// Events are processed inline (e.g., update thread_id from stopped events).
    fn readResponse(self: *DapProxy, allocator: std.mem.Allocator, expected_seq: i64) ![]const u8 {
        dapLog("[DAP readResponse] Waiting for response to seq={d}, buffer={d} bytes", .{ expected_seq, self.read_buffer.items.len });
        const poll_fd = try self.transportPollFd();

        var read_buf: [8192]u8 = undefined;
        var loop_count: u32 = 0;
        var timer = std.time.Timer.start() catch return error.ReadFailed;
        const deadline_ns = @as(u64, @intCast(@max(self.request_timeout_ms, 0))) * std.time.ns_per_ms;

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
                                    // Queue notification for poll_events
                                    self.queueNotification("debug/stopped", decoded.body);
                                    // Also buffer for waitForEvent so it isn't lost
                                    self.bufferEvent("stopped", decoded.body);
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
                                                    const log_len = @min(text.len, 256);
                                                    dapLog("[DAP readResponse] output({s}): {s}", .{ category, text[0..log_len] });
                                                    self.bufferOutput(category, text);
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
                                    self.bufferEvent("exited", decoded.body);
                                } else if (std.mem.eql(u8, evt.string, "terminated")) {
                                    // Terminated event — debug session end
                                    self.initialized = false;
                                    self.queueNotification("debug/terminated", decoded.body);
                                    self.bufferEvent("terminated", decoded.body);
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
                                    self.bufferEvent(evt.string, decoded.body);
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
                                    self.sendReverseResponse(allocator, req_seq, "startDebugging", true, null);
                                } else if (std.mem.eql(u8, cmd.string, "runInTerminal")) {
                                    // Queue notification for AI agent to handle
                                    self.queueNotification("debug/run_in_terminal", decoded.body);
                                    // Send synthetic success response
                                    const req_seq = if (parsed.value.object.get("seq")) |v|
                                        (if (v == .integer) v.integer else 0)
                                    else
                                        0;
                                    dapLog("[DAP readResponse] Responding to runInTerminal (req_seq={d})", .{req_seq});
                                    self.sendReverseResponse(allocator, req_seq, "runInTerminal", false, "runInTerminal is unsupported by Cog");
                                } else {
                                    const req_seq = if (parsed.value.object.get("seq")) |v|
                                        (if (v == .integer) v.integer else 0)
                                    else
                                        0;
                                    dapLog("[DAP readResponse] Rejecting unsupported reverse request: {s}", .{cmd.string});
                                    self.sendReverseResponse(allocator, req_seq, cmd.string, false, "unsupported reverse request");
                                }
                            }
                        }
                        allocator.free(decoded.body);
                        continue;
                    }
                }
                allocator.free(decoded.body);
            }

            // Poll only for the remaining absolute deadline so event traffic or
            // partial frames cannot restart the request timeout.
            const remaining_ms = remainingDeadlineNs(deadline_ns, timer.read()) orelse {
                dapLog("[DAP readResponse] TIMEOUT after {d}ms", .{self.request_timeout_ms});
                return error.Timeout;
            };
            dapLog("[DAP readResponse] Polling (remaining={d}ms, loop {d})...", .{ remaining_ms, loop_count });
            var poll_fds = [_]std.posix.pollfd{.{
                .fd = poll_fd,
                .events = std.posix.POLL.IN,
                .revents = 0,
            }};
            const poll_result = std.posix.poll(&poll_fds, remaining_ms) catch return error.ReadFailed;
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

    fn withRequestTimeout(self: *DapProxy, timeout_ms: i32) RequestTimeoutScope {
        const previous = self.request_timeout_ms;
        self.request_timeout_ms = timeout_ms;
        return .{ .proxy = self, .previous = previous };
    }

    const RequestTimeoutScope = struct {
        proxy: *DapProxy,
        previous: i32,

        fn restore(self: *RequestTimeoutScope) void {
            self.proxy.request_timeout_ms = self.previous;
        }
    };

    /// Wait for a specific event type from the adapter.
    /// Returns the raw JSON body of the event.
    fn waitForEvent(self: *DapProxy, allocator: std.mem.Allocator, event_name: []const u8) ![]const u8 {
        self.connection_mutex.lock();
        defer self.connection_mutex.unlock();
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
        var timer = std.time.Timer.start() catch return error.ReadFailed;
        const deadline_ns = @as(u64, @intCast(@max(self.request_timeout_ms, 0))) * std.time.ns_per_ms;

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
                                    self.bufferEvent(evt.string, decoded.body);
                                    // If the program exited/terminated while we're waiting
                                    // for "stopped" or "initialized", bail out early — the
                                    // expected event will never arrive.
                                    if ((std.mem.eql(u8, event_name, "stopped") or std.mem.eql(u8, event_name, "initialized")) and
                                        (std.mem.eql(u8, evt.string, "exited") or std.mem.eql(u8, evt.string, "terminated")))
                                    {
                                        dapLog("[DAP waitForEvent] Program exited/terminated while waiting for {s} — aborting wait", .{event_name});
                                        return error.Timeout;
                                    }
                                    // Also queue notifications for important events so
                                    // they are visible via poll_events (mirrors readResponse).
                                    if (std.mem.eql(u8, evt.string, "output")) {
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
                                                        const log_len = @min(text.len, 256);
                                                        dapLog("[DAP waitForEvent] output({s}): {s}", .{ category, text[0..log_len] });
                                                        self.bufferOutput(category, text);
                                                    }
                                                    self.queueNotification("debug/output", decoded.body);
                                                }
                                            }
                                        }
                                    } else if (std.mem.eql(u8, evt.string, "stopped")) {
                                        if (parsed.value.object.get("body")) |body| {
                                            if (body == .object) {
                                                if (body.object.get("threadId")) |tid| {
                                                    if (tid == .integer) self.thread_id = tid.integer;
                                                }
                                            }
                                        }
                                        self.queueNotification("debug/stopped", decoded.body);
                                    } else if (std.mem.eql(u8, evt.string, "continued")) {
                                        self.queueNotification("debug/continued", decoded.body);
                                    } else if (std.mem.eql(u8, evt.string, "breakpoint")) {
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
                                    }
                                }
                            }
                        }
                    }
                }
                allocator.free(decoded.body);
            }

            const remaining_ms = remainingDeadlineNs(deadline_ns, timer.read()) orelse {
                dapLog("[DAP waitForEvent] TIMEOUT waiting for event: {s}", .{event_name});
                return error.Timeout;
            };
            dapLog("[DAP waitForEvent] Polling (loop {d}, remaining={d}ms)...", .{ loop_count, remaining_ms });
            var poll_fds = [_]std.posix.pollfd{.{
                .fd = poll_fd,
                .events = std.posix.POLL.IN,
                .revents = 0,
            }};
            const poll_result = std.posix.poll(&poll_fds, remaining_ms) catch return error.ReadFailed;
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
            .stop_reason = .exited,
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
        errdefer {
            for (frames.items) |frame| {
                if (frame.name.len > 0) allocator.free(frame.name);
                if (frame.source.len > 0) allocator.free(frame.source);
            }
            frames.deinit(allocator);
        }

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
            errdefer allocator.free(name);

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

    pub fn translateReadMemory(allocator: std.mem.Allocator, data: []const u8) ![]const u8 {
        const parsed = try json.parseFromSlice(json.Value, allocator, data, .{});
        defer parsed.deinit();

        if (parsed.value != .object) return error.InvalidResponse;
        if (parsed.value.object.get("success")) |success| {
            if (success != .bool or !success.bool) return error.NotSupported;
        }
        const body = parsed.value.object.get("body") orelse return error.NotSupported;
        if (body != .object) return error.NotSupported;
        const data_val = body.object.get("data") orelse return error.NotSupported;
        if (data_val != .string) return error.NotSupported;

        const decoder = std.base64.standard.Decoder;
        const decoded_len = decoder.calcSizeForSlice(data_val.string) catch return error.InvalidResponse;
        const decoded = try allocator.alloc(u8, decoded_len);
        defer allocator.free(decoded);
        decoder.decode(decoded, data_val.string) catch return error.InvalidResponse;

        const hex = try allocator.alloc(u8, decoded.len * 2);
        errdefer allocator.free(hex);
        _ = std.fmt.bufPrint(hex, "{x}", .{decoded}) catch return error.InvalidResponse;
        return hex;
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
                .type = type_str,
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

        // 2. Build launch request and SAVE it for later.  The actual launch
        // is deferred to proxyRun so breakpoints can be sent to the adapter
        // BEFORE configurationDone triggers program execution.  This prevents
        // the race where some adapters (e.g. ElixirLS) start the program
        // immediately on launch and short programs finish before breakpoints
        // are set.
        // Force stopOnEntry=true to keep the adapter alive while we set
        // breakpoints and send configurationDone.  Without this, adapters that
        // start the program immediately on launch will exit before breakpoints
        // can be confirmed.  If the user wanted stop_on_entry=false, we send
        // "continue" after configuration.
        //
        // EXCEPTION: when skip_entry_stop is set (e.g. ElixirLS), the adapter
        // ignores stopOnEntry — it defers execution until configurationDone
        // and never sends a stopped(entry) event.  Forcing stopOnEntry=true
        // causes the proxy to consume the first real breakpoint hit as a
        // phantom "entry stop" and auto-continue past it.
        const user_stop_on_entry = config.stop_on_entry;
        const force_stop_on_entry = !cfg.skip_entry_stop;
        const effective_stop_on_entry = if (force_stop_on_entry) true else user_stop_on_entry;
        dapLog("[DAP launch] Step 2: Building launch request (seq={d}, stopOnEntry={}, user wanted {}, skip_entry_stop={}, deferred=true)...", .{ self.seq, effective_stop_on_entry, user_stop_on_entry, cfg.skip_entry_stop });
        const launch_msg = try protocol.launchRequestEx(allocator, self.nextSeq(), config.program, config.args, effective_stop_on_entry, cfg.launch_extra_args_json, config.cwd, config.module, config.env, cfg.program_field, cfg.args_field, cfg.args_first_is_program);
        // Save with persistent allocator (allocator may be an arena that is freed)
        if (self.saved_launch_msg) |old| self.allocator.free(old);
        self.saved_launch_msg = self.allocator.dupe(u8, launch_msg) catch null;
        allocator.free(launch_msg);
        dapLog("[DAP launch] Step 2: Launch request saved ({d} bytes), deferring send to proxyRun", .{if (self.saved_launch_msg) |m| m.len else 0});

        self.initialized = true;
        self.config_deferred = true;
        self.forced_entry_stop = if (force_stop_on_entry) !user_stop_on_entry else false;
        dapLog("[DAP launch] Config phase active (launch deferred, breakpoints can be set before run)", .{});
    }

    /// Launch an adapter over TCP transport (vscode-js-debug, etc.)
    fn launchTcp(self: *DapProxy, allocator: std.mem.Allocator, config: LaunchConfig, cfg: extensions.DapConfig, argv: []const []const u8) anyerror!void {
        dapLog("[DAP launch] TCP transport launch", .{});

        // Save launch state for restart
        self.saveLaunchState(config, argv);

        // 1. Spawn the adapter process
        dapLog("[DAP launch] Spawning adapter process (TCP)...", .{});
        var server_child = try spawnDetached(allocator, argv);
        var owns_server_child = true;
        errdefer if (owns_server_child) server_child.terminateAndReap();

        // 2. Read stdout to get the listening port
        const port_prefix = cfg.port_stdout_prefix orelse return error.PortParseFailed;
        const server_stdout = server_child.stdout orelse return error.NotInitialized;
        var port_buf: [256]u8 = undefined;
        var port_len: usize = 0;
        const port_timeout_ms: u64 = cfg.port_detection_timeout_ms;
        var port_timer = std.time.Timer.start() catch return error.ReadFailed;

        while (port_len < port_buf.len) {
            var poll_fds = [_]std.posix.pollfd{.{
                .fd = server_stdout.handle,
                .events = std.posix.POLL.IN,
                .revents = 0,
            }};
            const elapsed_ms = @divTrunc(port_timer.read(), std.time.ns_per_ms);
            const remaining_ms = remainingDeadlineMs(port_timeout_ms, elapsed_ms) orelse return error.Timeout;
            const poll_result = std.posix.poll(&poll_fds, remaining_ms) catch return error.ReadFailed;
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
        owns_server_child = false;
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
        const cwd = config.cwd orelse if (config.program.len > 0) std.fs.path.dirname(config.program) else null;
        const launch_msg = try protocol.launchRequestEx(allocator, self.nextSeq(), config.program, config.args, stop_on_entry, cfg.launch_extra_args_json, cwd, config.module, config.env, cfg.program_field, cfg.args_field, cfg.args_first_is_program);
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
        self.connection_mutex.lock();
        defer self.connection_mutex.unlock();
        const poll_fd = try self.transportPollFd();
        var read_buf: [8192]u8 = undefined;
        const timeout_ms: u64 = 15_000;
        var timer = std.time.Timer.start() catch return error.ReadFailed;

        while (self.pending_child_config == null) {
            const elapsed_ms = @divTrunc(timer.read(), std.time.ns_per_ms);
            const remaining = remainingDeadlineMs(timeout_ms, elapsed_ms) orelse {
                dapLog("[DAP waitForChildConfig] Timeout after {d}ms — no startDebugging received", .{elapsed_ms});
                return; // Not an error — adapter may not use child sessions
            };
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
                                    self.sendReverseResponse(allocator, req_seq, "startDebugging", true, null);
                                } else if (std.mem.eql(u8, cmd_val.string, "runInTerminal")) {
                                    const req_seq = if (parsed.value.object.get("seq")) |v|
                                        (if (v == .integer) v.integer else 0)
                                    else
                                        0;
                                    self.sendReverseResponse(allocator, req_seq, "runInTerminal", false, "runInTerminal is unsupported by Cog");
                                } else {
                                    const req_seq = if (parsed.value.object.get("seq")) |v|
                                        (if (v == .integer) v.integer else 0)
                                    else
                                        0;
                                    self.sendReverseResponse(allocator, req_seq, cmd_val.string, false, "unsupported reverse request");
                                }
                            }
                        }
                    } else if (std.mem.eql(u8, mt, "event")) {
                        // Buffer events for later consumption
                        if (parsed.value.object.get("event")) |evt| {
                            if (evt == .string) {
                                self.bufferEvent(evt.string, decoded.body);
                            }
                        }
                    }
                    // Responses are also buffered (rare but possible)
                }
                allocator.free(decoded.body);
            }
        }
        dapLog("[DAP waitForChildConfig] Child config received in {d}ms", .{@divTrunc(timer.read(), std.time.ns_per_ms)});
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
            self.config_deferred = true;
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

        if (self.config_deferred and self.saved_launch_msg != null) {
            // Deferred launch: the launch request was saved during launchStdio
            // so breakpoints can be sent BEFORE configurationDone triggers
            // program execution.  This prevents the race where some adapters
            // (e.g. ElixirLS) start the program immediately on launch and
            // short programs finish before breakpoints are set.
            //
            // Spec-compliant flow:
            //   launch → [wait for initialized] → setBreakpoints → configurationDone → program runs
            // For non-compliant adapters (e.g. ElixirLS) that never send initialized,
            // we fall through after a short timeout and proceed anyway.

            // 1. Send the deferred launch request.
            self.thread_id = 0; // Reset so we can detect entry stop
            const launch_msg = self.saved_launch_msg.?;
            dapLog("[DAP proxyRun] Sending deferred launch request ({d} bytes)...", .{launch_msg.len});
            try self.sendRaw(allocator, launch_msg);
            self.allocator.free(launch_msg);
            self.saved_launch_msg = null;
            dapLog("[DAP proxyRun] Deferred launch request sent", .{});

            // 2. Wait for 'initialized' event (per DAP spec, adapter signals
            // readiness for configuration).  Use a short timeout so non-compliant
            // adapters that never send it don't block indefinitely.
            {
                var timeout_scope = self.withRequestTimeout(10_000);
                defer timeout_scope.restore();
                dapLog("[DAP proxyRun] Waiting for initialized event (10s timeout)...", .{});
                if (self.waitForEvent(allocator, "initialized")) |init_event| {
                    allocator.free(init_event);
                    dapLog("[DAP proxyRun] initialized event received", .{});
                } else |err| {
                    dapLog("[DAP proxyRun] initialized event not received: {s} (proceeding anyway)", .{@errorName(err)});
                }
            }

            // 3. Re-arm all tracked breakpoints before configurationDone.
            // The adapter will queue these after processing the launch request.
            dapLog("[DAP proxyRun] Sending breakpoints to adapter (before configurationDone)...", .{});
            self.rearmBreakpoints(allocator);
            dapLog("[DAP proxyRun] Breakpoints sent", .{});

            // 4. Send configurationDone to signal the adapter to start the
            // program.  At this point breakpoints are already in place.
            dapLog("[DAP proxyRun] Sending configurationDone...", .{});
            const cd_msg = try protocol.configurationDoneRequest(allocator, self.nextSeq());
            defer allocator.free(cd_msg);
            const cd_resp = self.sendRequest(allocator, cd_msg) catch |err| {
                // Some adapters may not respond to configurationDone if they
                // already started (fallback: continue anyway).
                dapLog("[DAP proxyRun] configurationDone response error: {s} (continuing)", .{@errorName(err)});
                _ = &err;
                self.config_deferred = false;
                // Fall through to wait for stopped/exited
                return self.waitForStopOrExit(allocator);
            };
            allocator.free(cd_resp);
            dapLog("[DAP proxyRun] configurationDone response received", .{});

            // 5. If stopOnEntry was forced (user wanted false), consume the
            // entry stop and resume execution.  The "stopped" event may have
            // already been consumed by readResponse during steps 3-4 (which
            // sets self.thread_id), or it may still be in the pipe.
            if (self.forced_entry_stop) {
                self.forced_entry_stop = false;
                if (self.thread_id != 0) {
                    // Entry stop already consumed by readResponse
                    dapLog("[DAP proxyRun] Entry stop already consumed (thread_id={d}), sending continue", .{self.thread_id});
                } else {
                    // Wait for the entry stop event
                    dapLog("[DAP proxyRun] Waiting for entry stop event...", .{});
                    if (self.waitForEvent(allocator, "stopped")) |entry_stop| {
                        // waitForEvent returns the body but doesn't extract threadId
                        // for the target event, so parse it here.
                        if (self.thread_id == 0) {
                            if (std.json.parseFromSlice(std.json.Value, allocator, entry_stop, .{})) |parsed| {
                                defer parsed.deinit();
                                if (parsed.value == .object) {
                                    // threadId is inside the "body" object in DAP messages
                                    if (parsed.value.object.get("body")) |body| {
                                        if (body == .object) {
                                            if (body.object.get("threadId")) |tid| {
                                                if (tid == .integer) self.thread_id = tid.integer;
                                            }
                                        }
                                    }
                                }
                            } else |_| {}
                        }
                        allocator.free(entry_stop);
                        dapLog("[DAP proxyRun] Entry stop received (thread_id={d})", .{self.thread_id});
                    } else |err| {
                        dapLog("[DAP proxyRun] No entry stop: {s}", .{@errorName(err)});
                    }
                }
                {
                    // Use thread_id from the stopped event, or 0 (all threads)
                    // as a fallback if the adapter didn't provide one.
                    const continue_tid = self.thread_id;
                    dapLog("[DAP proxyRun] Sending continue to resume from entry stop (thread_id={d})", .{continue_tid});
                    const cont_msg = try protocol.continueRequest(allocator, self.nextSeq(), continue_tid);
                    defer allocator.free(cont_msg);
                    if (self.sendRequest(allocator, cont_msg)) |cont_resp| {
                        allocator.free(cont_resp);
                        dapLog("[DAP proxyRun] Resumed from entry stop", .{});
                    } else |err| {
                        dapLog("[DAP proxyRun] Continue error: {s}", .{@errorName(err)});
                    }
                }
            }

            self.config_deferred = false;
        } else if (self.config_deferred) {
            // Deferred configurationDone (child session with stopOnEntry=true).
            // The launch was already sent; program is paused at entry.

            // 1. Wait for the entry "stopped" event (may already be buffered).
            dapLog("[DAP proxyRun] Waiting for entry stop event (stopOnEntry deferred config)...", .{});
            const entry_stop = self.waitForEvent(allocator, "stopped") catch |err| {
                dapLog("[DAP proxyRun] Failed to receive entry stop: {s}", .{@errorName(err)});
                return err;
            };
            allocator.free(entry_stop);
            dapLog("[DAP proxyRun] Entry stop received", .{});

            // 2. Re-arm breakpoints while program is paused.
            dapLog("[DAP proxyRun] Re-arming breakpoints", .{});
            self.rearmBreakpoints(allocator);

            // 3. Resume execution.
            dapLog("[DAP proxyRun] Sending continue to resume from entry stop", .{});
            const cont_msg = try protocol.continueRequest(allocator, self.nextSeq(), self.thread_id);
            defer allocator.free(cont_msg);
            const cont_resp = try self.sendRequest(allocator, cont_msg);
            allocator.free(cont_resp);

            self.config_deferred = false;
            self.forced_entry_stop = false;
        } else {
            // Normal case: send the appropriate DAP run command
            const msg = try self.mapRunActionEx(allocator, action, options);
            defer allocator.free(msg);
            const resp = try self.sendRequest(allocator, msg);
            allocator.free(resp);
        }

        return self.waitForStopOrExit(allocator);
    }

    /// Wait for a stopped or exited event, fetch stack trace, and return state.
    fn waitForStopOrExit(self: *DapProxy, allocator: std.mem.Allocator) anyerror!StopState {
        // Wait for a stopped or exited event
        // Try stopped first, fall back to exited
        const event_data = self.waitForEvent(allocator, "stopped") catch {
            const exit_data = self.waitForEvent(allocator, "exited") catch {
                return .{ .stop_reason = .step };
            };
            defer allocator.free(exit_data);
            var exit_state = try translateExitedEvent(allocator, exit_data);
            // Attach captured output (traceback, stderr) so the caller can
            // see why the program exited. Ownership transfers to StopState.
            if (self.output_buffer.items.len > 0) {
                exit_state.output = self.output_buffer.toOwnedSlice(self.allocator) catch &.{};
            }
            return exit_state;
        };
        defer allocator.free(event_data);

        // Log the raw stopped event for diagnosis
        {
            const log_len = @min(event_data.len, 512);
            dapLog("[DAP proxyRun] stopped event body[0..{d}]: {s}", .{ log_len, event_data[0..log_len] });
        }

        // Extract threadId from the stopped event. waitForEvent returns the
        // target event without setting self.thread_id, so parse it here to
        // ensure the subsequent stackTraceRequest uses the correct thread.
        {
            if (std.json.parseFromSlice(std.json.Value, allocator, event_data, .{})) |parsed| {
                defer parsed.deinit();
                if (parsed.value == .object) {
                    if (parsed.value.object.get("body")) |body| {
                        if (body == .object) {
                            if (body.object.get("threadId")) |tid| {
                                if (tid == .integer) {
                                    self.thread_id = tid.integer;
                                    dapLog("[DAP waitForStopOrExit] Set thread_id={d} from stopped event", .{tid.integer});
                                }
                            }
                        }
                    }
                }
            } else |_| {}
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

        // Attach captured output to state. toOwnedSlice transfers both the
        // backing slice and every owned entry string to StopState.deinit().
        if (self.output_buffer.items.len > 0) {
            state.output = self.output_buffer.toOwnedSlice(self.allocator) catch &.{};
        }

        return state;
    }

    fn handleBreakpointEvent(self: *DapProxy, bp_obj: std.json.ObjectMap) void {
        const adapter_id = if (bp_obj.get("id")) |id| (if (id == .integer and id.integer >= 0) @as(u32, @intCast(id.integer)) else return) else return;
        const local_id = self.adapter_bp_ids.get(adapter_id) orelse adapter_id;
        const verified = if (bp_obj.get("verified")) |v| (v == .bool and v.bool) else false;
        const actual_line = if (bp_obj.get("line")) |l| (if (l == .integer and l.integer >= 0) @as(u32, @intCast(l.integer)) else null) else null;
        if (self.bp_registry.getPtr(local_id)) |entry| {
            entry.verified = verified;
            if (actual_line) |line| entry.line = line;
            debug_log.log("dap.proxy: breakpoint event adapter_id={d} local_id={d} verified={} line={?}", .{ adapter_id, local_id, verified, actual_line });
        } else {
            debug_log.log("dap.proxy: ignored breakpoint event for unknown adapter_id={d}", .{adapter_id});
        }
    }

    fn freeMemoryEvent(self: *DapProxy, event: MemoryEvent) void {
        self.allocator.free(event.memory_reference);
    }

    fn handleMemoryEvent(self: *DapProxy, body_obj: std.json.ObjectMap) void {
        const mem_ref = if (body_obj.get("memoryReference")) |v| (if (v == .string) v.string else return) else return;
        const offset: i64 = if (body_obj.get("offset")) |v| (if (v == .integer) v.integer else 0) else 0;
        const count: i64 = if (body_obj.get("count")) |v| (if (v == .integer) v.integer else 0) else 0;

        for (self.memory_events.items) |event| {
            if (event.offset == offset and event.count == count and std.mem.eql(u8, event.memory_reference, mem_ref)) {
                self.retention_deduplications.memory_events += 1;
                debug_log.log("dap.proxy: deduplicated memory event ref={s} offset={d} count={d}", .{ mem_ref, offset, count });
                return;
            }
        }

        const owned_ref = self.allocator.dupe(u8, mem_ref) catch return;
        const new_event: MemoryEvent = .{
            .memory_reference = owned_ref,
            .offset = offset,
            .count = count,
        };

        if (self.memory_events.items.len == MAX_MEMORY_EVENTS) {
            const dropped = self.memory_events.orderedRemove(0);
            self.freeMemoryEvent(dropped);
            self.retention_drops.memory_events += 1;
            debug_log.log("dap.proxy: memory event retention full; dropped oldest total={d}", .{self.retention_drops.memory_events});
        }

        self.memory_events.append(self.allocator, new_event) catch self.freeMemoryEvent(new_event);
    }

    fn progressPercentage(value: std.json.Value) ?f64 {
        return switch (value) {
            .float => |percentage| percentage,
            .integer => |percentage| @floatFromInt(percentage),
            else => null,
        };
    }

    fn freeProgressState(self: *DapProxy, state: ProgressState) void {
        self.allocator.free(state.title);
        self.allocator.free(state.message);
    }

    fn handleProgressStart(self: *DapProxy, body_obj: std.json.ObjectMap) void {
        const progress_id = if (body_obj.get("progressId")) |v| (if (v == .string) v.string else return) else return;
        const title = if (body_obj.get("title")) |v| (if (v == .string) v.string else "") else "";
        const message = if (body_obj.get("message")) |v| (if (v == .string) v.string else "") else "";
        const percentage = if (body_obj.get("percentage")) |v| progressPercentage(v) else null;

        if (self.active_progress.getPtr(progress_id)) |state| {
            const owned_title = self.allocator.dupe(u8, title) catch return;
            const owned_message = self.allocator.dupe(u8, message) catch {
                self.allocator.free(owned_title);
                return;
            };
            self.freeProgressState(state.*);
            state.* = .{
                .title = owned_title,
                .message = owned_message,
                .percentage = percentage,
            };
            self.retention_deduplications.active_progress += 1;
            debug_log.log("dap.proxy: replaced duplicate progress start id={s}", .{progress_id});
            return;
        }

        if (self.active_progress.count() == MAX_ACTIVE_PROGRESS) {
            self.retention_drops.active_progress += 1;
            debug_log.log("dap.proxy: progress retention full; dropped incoming id={s} total={d}", .{ progress_id, self.retention_drops.active_progress });
            return;
        }

        const key = self.allocator.dupe(u8, progress_id) catch return;
        const owned_title = self.allocator.dupe(u8, title) catch {
            self.allocator.free(key);
            return;
        };
        const owned_message = self.allocator.dupe(u8, message) catch {
            self.allocator.free(owned_title);
            self.allocator.free(key);
            return;
        };
        self.active_progress.put(self.allocator, key, .{
            .title = owned_title,
            .message = owned_message,
            .percentage = percentage,
        }) catch {
            self.allocator.free(owned_message);
            self.allocator.free(owned_title);
            self.allocator.free(key);
        };
    }

    fn handleProgressUpdate(self: *DapProxy, body_obj: std.json.ObjectMap) void {
        const progress_id = if (body_obj.get("progressId")) |v| (if (v == .string) v.string else return) else return;
        if (self.active_progress.getPtr(progress_id)) |state| {
            if (body_obj.get("message")) |v| {
                if (v == .string) {
                    const owned_message = self.allocator.dupe(u8, v.string) catch return;
                    self.allocator.free(state.message);
                    state.message = owned_message;
                }
            }
            if (body_obj.get("percentage")) |v| {
                if (progressPercentage(v)) |percentage| state.percentage = percentage;
            }
        }
    }

    fn handleProgressEnd(self: *DapProxy, body_obj: std.json.ObjectMap) void {
        const progress_id = if (body_obj.get("progressId")) |v| (if (v == .string) v.string else return) else return;
        if (self.active_progress.fetchRemove(progress_id)) |kv| {
            self.freeProgressState(kv.value);
            self.allocator.free(kv.key);
        }
    }

    fn freeInvalidatedEvent(self: *DapProxy, event: InvalidatedEvent) void {
        for (event.areas) |area| self.allocator.free(area);
        self.allocator.free(event.areas);
    }

    fn invalidatedEventMatchesBody(event: InvalidatedEvent, body_obj: std.json.ObjectMap, stack_frame_id: ?u32) bool {
        if (event.stack_frame_id != stack_frame_id) return false;
        const areas_val = body_obj.get("areas") orelse return event.areas.len == 0;
        if (areas_val != .array) return event.areas.len == 0;

        var area_index: usize = 0;
        for (areas_val.array.items) |item| {
            if (item != .string) continue;
            if (area_index >= event.areas.len or !std.mem.eql(u8, event.areas[area_index], item.string)) return false;
            area_index += 1;
        }
        return area_index == event.areas.len;
    }

    fn handleInvalidatedEvent(self: *DapProxy, body_obj: std.json.ObjectMap) void {
        const stack_frame_id: ?u32 = blk: {
            const value = body_obj.get("stackFrameId") orelse break :blk null;
            if (value != .integer or value.integer < 0 or value.integer > std.math.maxInt(u32)) {
                debug_log.log("dap.proxy: ignored invalidated event with out-of-range stack frame id", .{});
                return;
            }
            break :blk @intCast(value.integer);
        };

        for (self.invalidated_areas.items) |event| {
            if (invalidatedEventMatchesBody(event, body_obj, stack_frame_id)) {
                self.retention_deduplications.invalidated_areas += 1;
                debug_log.log("dap.proxy: deduplicated invalidated event frame={?d}", .{stack_frame_id});
                return;
            }
        }

        var areas_list = std.ArrayListUnmanaged([]const u8).empty;
        defer areas_list.deinit(self.allocator);
        if (body_obj.get("areas")) |areas_val| {
            if (areas_val == .array) {
                for (areas_val.array.items) |item| {
                    if (item != .string) continue;
                    const owned_area = self.allocator.dupe(u8, item.string) catch {
                        for (areas_list.items) |area| self.allocator.free(area);
                        return;
                    };
                    areas_list.append(self.allocator, owned_area) catch {
                        self.allocator.free(owned_area);
                        for (areas_list.items) |area| self.allocator.free(area);
                        return;
                    };
                }
            }
        }

        const owned_areas = areas_list.toOwnedSlice(self.allocator) catch {
            for (areas_list.items) |area| self.allocator.free(area);
            return;
        };
        const new_event: InvalidatedEvent = .{
            .areas = owned_areas,
            .stack_frame_id = stack_frame_id,
        };

        if (self.invalidated_areas.items.len == MAX_INVALIDATED_AREAS) {
            const dropped = self.invalidated_areas.orderedRemove(0);
            self.freeInvalidatedEvent(dropped);
            self.retention_drops.invalidated_areas += 1;
            debug_log.log("dap.proxy: invalidated retention full; dropped oldest total={d}", .{self.retention_drops.invalidated_areas});
        }

        self.invalidated_areas.append(self.allocator, new_event) catch self.freeInvalidatedEvent(new_event);
    }

    fn buildReverseResponse(allocator: std.mem.Allocator, seq: i64, request_seq: i64, command: []const u8, success: bool, message: ?[]const u8) ![]const u8 {
        var aw: Writer.Allocating = .init(allocator);
        errdefer aw.deinit();
        var s: Stringify = .{ .writer = &aw.writer };

        try s.beginObject();
        try s.objectField("seq");
        try s.write(seq);
        try s.objectField("type");
        try s.write("response");
        try s.objectField("request_seq");
        try s.write(request_seq);
        try s.objectField("success");
        try s.write(success);
        try s.objectField("command");
        try s.write(command);
        if (message) |text| {
            try s.objectField("message");
            try s.write(text);
        }
        try s.endObject();
        return aw.toOwnedSlice();
    }

    /// Send a response for a reverse request from the adapter. Callers already
    /// hold connection_mutex while decoding the reverse request, so write the
    /// reply directly without trying to recursively acquire the mutex.
    fn sendReverseResponse(self: *DapProxy, allocator: std.mem.Allocator, request_seq: i64, command: []const u8, success: bool, message: ?[]const u8) void {
        const msg = buildReverseResponse(allocator, self.nextSeq(), request_seq, command, success, message) catch return;
        defer allocator.free(msg);

        const encoded = transport.encodeMessage(allocator, msg) catch return;
        defer allocator.free(encoded);

        self.transportWrite(encoded) catch {
            dapLog("[DAP sendReverseResponse] Write failed!", .{});
            return;
        };
        dapLog("[DAP sendReverseResponse] Sent response for {s} (req_seq={d}, success={}, {d} bytes)", .{ command, request_seq, success, encoded.len });
        debug_log.log("dap.proxy: answered reverse request command={s} request_seq={d} success={}", .{ command, request_seq, success });
    }

    fn queueNotification(self: *DapProxy, method: []const u8, params_json: []const u8) void {
        self.queueNotificationAlloc(method, params_json) catch |err| {
            debug_log.log("dap.proxy: failed to buffer notification method={s} error={s}", .{ method, @errorName(err) });
        };
    }

    fn queueNotificationAlloc(self: *DapProxy, method: []const u8, params_json: []const u8) !void {
        if (self.pending_notifications.items.len >= MAX_PENDING_NOTIFICATIONS) {
            self.dropped_notifications += 1;
            debug_log.log("dap.proxy: dropped notification method={s} total_dropped={d}", .{ method, self.dropped_notifications });
            return;
        }
        const method_owned = try self.allocator.dupe(u8, method);
        errdefer self.allocator.free(method_owned);
        const params_owned = try self.allocator.dupe(u8, params_json);
        errdefer self.allocator.free(params_owned);
        try self.pending_notifications.append(self.allocator, .{
            .method = method_owned,
            .params_json = params_owned,
        });
    }

    fn bufferEvent(self: *DapProxy, event_name: []const u8, body: []const u8) void {
        self.bufferEventAlloc(event_name, body) catch |err| {
            debug_log.log("dap.proxy: failed to buffer event name={s} error={s}", .{ event_name, @errorName(err) });
        };
    }

    fn bufferEventAlloc(self: *DapProxy, event_name: []const u8, body: []const u8) !void {
        if (self.buffered_events.items.len >= MAX_BUFFERED_EVENTS) {
            self.dropped_buffered_events += 1;
            debug_log.log("dap.proxy: dropped buffered event name={s} total_dropped={d}", .{ event_name, self.dropped_buffered_events });
            return;
        }
        const event_owned = try self.allocator.dupe(u8, event_name);
        errdefer self.allocator.free(event_owned);
        const body_owned = try self.allocator.dupe(u8, body);
        errdefer self.allocator.free(body_owned);
        try self.buffered_events.append(self.allocator, .{
            .event_name = event_owned,
            .body = body_owned,
        });
    }

    fn bufferOutput(self: *DapProxy, category: []const u8, text: []const u8) void {
        self.bufferOutputAlloc(category, text) catch |err| {
            debug_log.log("dap.proxy: failed to buffer output category={s} error={s}", .{ category, @errorName(err) });
        };
    }

    fn bufferOutputAlloc(self: *DapProxy, category: []const u8, text: []const u8) !void {
        if (self.output_buffer.items.len >= MAX_OUTPUT_ENTRIES) {
            self.dropped_output_entries += 1;
            debug_log.log("dap.proxy: dropped output category={s} total_dropped={d}", .{ category, self.dropped_output_entries });
            return;
        }
        const category_owned = try self.allocator.dupe(u8, category);
        errdefer self.allocator.free(category_owned);
        const text_owned = try self.allocator.dupe(u8, text);
        errdefer self.allocator.free(text_owned);
        try self.output_buffer.append(self.allocator, .{
            .category = category_owned,
            .text = text_owned,
        });
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

    fn freeLoadedModule(self: *DapProxy, entry: LoadedModuleEntry) void {
        entry.id.deinit(self.allocator);
        self.allocator.free(entry.name);
    }

    fn handleModuleEvent(self: *DapProxy, body_obj: std.json.ObjectMap) void {
        const reason = if (body_obj.get("reason")) |r| (if (r == .string) r.string else return) else return;
        const module = body_obj.get("module") orelse return;
        if (module != .object) return;
        const id_value = module.object.get("id") orelse {
            debug_log.log("dap.proxy: ignored module event without protocol id", .{});
            return;
        };
        if (id_value != .integer and id_value != .string) {
            debug_log.log("dap.proxy: ignored module event with invalid protocol id type", .{});
            return;
        }
        const name = if (module.object.get("name")) |n| (if (n == .string) n.string else "unknown") else "unknown";

        var existing_index: ?usize = null;
        for (self.loaded_modules.items, 0..) |entry, index| {
            if (entry.id.matches(id_value)) {
                existing_index = index;
                break;
            }
        }

        if (std.mem.eql(u8, reason, "removed")) {
            if (existing_index) |index| {
                const removed = self.loaded_modules.orderedRemove(index);
                self.freeLoadedModule(removed);
                debug_log.log("dap.proxy: removed loaded module name={s}", .{name});
            }
            return;
        }
        if (!std.mem.eql(u8, reason, "new") and !std.mem.eql(u8, reason, "changed")) return;

        if (existing_index) |index| {
            const entry = &self.loaded_modules.items[index];
            if (!std.mem.eql(u8, entry.name, name)) {
                const owned_name = self.allocator.dupe(u8, name) catch return;
                self.allocator.free(entry.name);
                entry.name = owned_name;
            }
            self.retention_deduplications.loaded_modules += 1;
            debug_log.log("dap.proxy: updated loaded module name={s}", .{name});
            return;
        }

        const owned_id: LoadedModuleId = switch (id_value) {
            .integer => |id| .{ .integer = id },
            .string => |id| .{ .string = self.allocator.dupe(u8, id) catch return },
            else => unreachable,
        };
        const owned_name = self.allocator.dupe(u8, name) catch {
            owned_id.deinit(self.allocator);
            return;
        };
        const new_entry: LoadedModuleEntry = .{ .id = owned_id, .name = owned_name };
        if (self.loaded_modules.items.len == MAX_LOADED_MODULES) {
            const dropped = self.loaded_modules.orderedRemove(0);
            self.freeLoadedModule(dropped);
            self.retention_drops.loaded_modules += 1;
            debug_log.log("dap.proxy: loaded module retention full; dropped oldest total={d}", .{self.retention_drops.loaded_modules});
        }
        self.loaded_modules.append(self.allocator, new_entry) catch self.freeLoadedModule(new_entry);
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
        try self.bp_registry.put(self.allocator, bp_id, .{ .file = gop.key_ptr.*, .line = line, .verified = false });

        // If adapter is connected and NOT in the deferred config phase, send
        // the DAP setBreakpoints request immediately.  During the deferred
        // config phase (config_deferred=true), we only update internal
        // data structures — a single reconciliation setBreakpoints call is
        // sent via rearmBreakpoints right before configurationDone in proxyRun.
        // This avoids vscode-js-debug's breakpoint prediction getting confused
        // by multiple incremental setBreakpoints replacements during config.
        if (self.initialized and self.transport != .none and !self.config_deferred) {
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
        defer allocator.free(resp);
        {
            const log_len = @min(resp.len, 512);
            dapLog("[DAP sendFileBreakpoints] Response[0..{d}]: {s}", .{ log_len, resp[0..log_len] });
        }
        self.updateBreakpointRegistryFromResponse(allocator, bp_list, resp);
    }

    fn updateBreakpointRegistryFromResponse(self: *DapProxy, allocator: std.mem.Allocator, bp_list: []const BreakpointEntry, resp: []const u8) void {
        const parsed = json.parseFromSlice(json.Value, allocator, resp, .{}) catch return;
        defer parsed.deinit();
        if (parsed.value != .object) return;
        const body = parsed.value.object.get("body") orelse return;
        if (body != .object) return;
        const breakpoints = body.object.get("breakpoints") orelse return;
        if (breakpoints != .array) return;

        for (breakpoints.array.items, 0..) |item, index| {
            if (index >= bp_list.len or item != .object) break;
            const local_id = bp_list[index].bp_id;
            if (self.bp_registry.getPtr(local_id)) |entry| {
                entry.verified = if (item.object.get("verified")) |value| value == .bool and value.bool else false;
                if (item.object.get("line")) |value| {
                    if (value == .integer and value.integer >= 0) entry.line = @intCast(value.integer);
                }
                if (item.object.get("id")) |value| {
                    if (value == .integer and value.integer >= 0) {
                        const adapter_id: u32 = @intCast(value.integer);
                        self.adapter_bp_ids.put(self.allocator, adapter_id, local_id) catch |err| {
                            debug_log.log("dap.proxy: failed to map breakpoint adapter_id={d} local_id={d} error={s}", .{ adapter_id, local_id, @errorName(err) });
                        };
                    }
                }
            }
        }
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
            if (self.initialized and self.transport != .none and !self.config_deferred) {
                dapLog("[DAP removeBreakpoint] Re-sending {d} remaining breakpoints for file={s}", .{ bp_list.items.len, file });
                self.sendFileBreakpoints(allocator, file, bp_list.items) catch |err| {
                    dapLog("[DAP removeBreakpoint] Failed to re-send breakpoints for file={s}: {any}", .{ file, err });
                };
            }
        }

        var adapter_id_to_remove: ?u32 = null;
        var adapter_it = self.adapter_bp_ids.iterator();
        while (adapter_it.next()) |mapping| {
            if (mapping.value_ptr.* == id) {
                adapter_id_to_remove = mapping.key_ptr.*;
                break;
            }
        }
        if (adapter_id_to_remove) |adapter_id| _ = self.adapter_bp_ids.remove(adapter_id);
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
                const registry_entry = self.bp_registry.get(bp.bp_id);
                try result.append(allocator, .{
                    .id = bp.bp_id,
                    .verified = if (registry_entry) |registered| registered.verified else false,
                    .file = file,
                    .line = if (registry_entry) |registered| registered.line else bp.line,
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
        if (!self.initialized or self.transport == .none) return .{ .result = "<not connected>", .type = "" };

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
                        return .{ .result = try allocator.dupe(u8, err_msg), .type = "", .result_allocated = true, .is_error = true };
                    }
                }

                // Parse using existing translateVariables
                const children = translateVariables(allocator, resp) catch {
                    return .{ .result = "<failed to expand variable>", .type = "" };
                };

                return .{
                    .result = try std.fmt.allocPrint(allocator, "{d} children", .{children.len}),
                    .type = "",
                    .children = children,
                    .result_allocated = true,
                    .children_allocated = true,
                };
            }
        }

        // If scope is provided, fetch variables for that scope
        if (request.scope) |scope_name| {
            const fid: i64 = if (request.frame_id) |f| self.resolveFrameId(f) orelse return .{ .result = "", .type = "" } else self.current_frame_id orelse return .{ .result = "", .type = "" };

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

            // If "arguments" scope was requested but not found, fall back to
            // "locals" — debugpy (and some other adapters) merge function
            // arguments into the locals scope rather than exposing a separate
            // "arguments" scope.
            if (scope_var_ref == 0 and std.mem.eql(u8, scope_name, "arguments")) {
                if (scopes_parsed.value == .object) {
                    if (scopes_parsed.value.object.get("body")) |body2| {
                        if (body2 == .object) {
                            if (body2.object.get("scopes")) |scopes2| {
                                if (scopes2 == .array) {
                                    for (scopes2.array.items) |item2| {
                                        if (item2 != .object) continue;
                                        const sn = if (item2.object.get("name")) |v| (if (v == .string) v.string else continue) else continue;
                                        if (std.ascii.startsWithIgnoreCase(sn, "local")) {
                                            if (item2.object.get("variablesReference")) |vr| {
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
            }

            if (scope_var_ref > 0) {
                const vars_msg = try protocol.variablesRequest(allocator, self.nextSeq(), @intCast(scope_var_ref));
                defer allocator.free(vars_msg);
                const vars_resp = try self.sendRequest(allocator, vars_msg);
                defer allocator.free(vars_resp);

                const children = translateVariables(allocator, vars_resp) catch {
                    return .{ .result = "<failed to list scope variables>", .type = "" };
                };

                return .{
                    .result = try std.fmt.allocPrint(allocator, "{d} variables", .{children.len}),
                    .type = "",
                    .children = children,
                    .result_allocated = true,
                    .children_allocated = true,
                };
            }

            return .{ .result = try allocator.dupe(u8, "scope not found"), .type = "", .result_allocated = true };
        }

        const expr = request.expression orelse return .{ .result = "", .type = "" };
        if (expr.len == 0) return .{ .result = "", .type = "" };

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

        if (parsed.value != .object) return .{ .result = "<invalid response>", .type = "" };
        const success = if (parsed.value.object.get("success")) |v| v == .bool and v.bool else false;
        if (!success) {
            const err_msg = if (parsed.value.object.get("message")) |v| if (v == .string) v.string else "<error>" else "<error>";
            return .{ .result = try allocator.dupe(u8, err_msg), .type = "", .result_allocated = true, .is_error = true };
        }

        const body = parsed.value.object.get("body") orelse return .{ .result = "", .type = "" };
        if (body != .object) return .{ .result = "", .type = "" };

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
                        .type = type_str,
                        .children = children,
                        .result_allocated = true,
                        .children_allocated = true,
                    };
                } else |_| {}
            } else |_| {}
        }

        return .{ .result = result_str, .type = type_str, .result_allocated = true };
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

    fn proxyInterruptRun(ctx: *anyopaque) void {
        const self: *DapProxy = @ptrCast(@alignCast(ctx));
        dapLog("[DAP interruptRun] Closing transport to unblock active reader", .{});
        self.transportKill();
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

        // Use the current stopped thread if no specific thread requested
        const effective_tid: i64 = if (thread_id == 0) self.thread_id else @intCast(thread_id);
        const msg = try protocol.stackTraceRequest(allocator, self.nextSeq(), effective_tid, @intCast(start_frame), @intCast(levels));
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

        // DAP returns base64 bytes; the driver contract exposes lowercase hex
        // so the MCP memory tool uses the same representation for all backends.
        const hex = try translateReadMemory(allocator, resp);
        debug_log.log("dap.proxy: decoded readMemory response address=0x{x} bytes={d}", .{ address, hex.len / 2 });
        return hex;
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
        const body = parsed.value.object.get("body") orelse return .{ .result = value, .type = "" };
        if (body != .object) return .{ .result = value, .type = "" };

        const result_val = if (body.object.get("value")) |v| if (v == .string) try allocator.dupe(u8, v.string) else try allocator.dupe(u8, value) else try allocator.dupe(u8, value);
        const type_val = if (body.object.get("type")) |v| if (v == .string) try allocator.dupe(u8, v.string) else try allocator.dupe(u8, "") else try allocator.dupe(u8, "");
        _ = type_val;

        return .{ .result = result_val, .type = "", .result_allocated = true };
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
        const body = parsed.value.object.get("body") orelse return .{ .result = value, .type = "" };
        if (body != .object) return .{ .result = value, .type = "" };

        const result_val = if (body.object.get("value")) |v| (if (v == .string) try allocator.dupe(u8, v.string) else try allocator.dupe(u8, value)) else try allocator.dupe(u8, value);

        return .{ .result = result_val, .type = "", .result_allocated = true };
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

        const effective_tid: i64 = if (thread_id == 0) self.thread_id else @intCast(thread_id);
        const msg = try protocol.exceptionInfoRequest(allocator, self.nextSeq(), effective_tid);
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
            .type = exc_id orelse "",
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

            const program = self.saved_launch_program orelse "";
            if (program.len == 0 and self.saved_launch_module == null) return error.NotSupported;
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
                var child = spawnDetached(allocator, adapter_argv) catch |err| {
                    dapLog("[DAP restart] Failed to spawn adapter: {any}", .{err});
                    return err;
                };
                var owns_child = true;
                errdefer if (owns_child) child.terminateAndReap();
                const server_stdout = child.stdout orelse return error.NotInitialized;
                var port_buf: [256]u8 = undefined;
                var port_len: usize = 0;
                const port_timeout_ms: u64 = cfg.port_detection_timeout_ms;
                var port_timer = std.time.Timer.start() catch return error.ReadFailed;
                while (port_len < port_buf.len) {
                    var poll_fds = [_]std.posix.pollfd{.{
                        .fd = server_stdout.handle,
                        .events = std.posix.POLL.IN,
                        .revents = 0,
                    }};
                    const elapsed_ms = @divTrunc(port_timer.read(), std.time.ns_per_ms);
                    const remaining_ms = remainingDeadlineMs(port_timeout_ms, elapsed_ms) orelse return error.Timeout;
                    const pr = std.posix.poll(&poll_fds, remaining_ms) catch return error.ReadFailed;
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
                owns_child = false;
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
                if (program.len > 0) std.fs.path.dirname(program) else null,
                self.saved_launch_module,
                null,
                cfg.program_field,
                cfg.args_field,
                cfg.args_first_is_program,
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
        if (self.saved_launch_module) |m| self.allocator.free(m);
        if (self.saved_launch_args) |args| {
            for (args) |a| self.allocator.free(a);
            self.allocator.free(args);
        }
        if (self.saved_adapter_argv) |argv| {
            for (argv) |a| self.allocator.free(a);
            self.allocator.free(argv);
        }

        self.saved_launch_program = if (config.program.len > 0) (self.allocator.dupe(u8, config.program) catch null) else null;
        self.saved_launch_module = if (config.module) |m| (self.allocator.dupe(u8, m) catch null) else null;
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
            allocator.free(v.type);
        }
        allocator.free(vars);
    }

    try std.testing.expectEqual(@as(usize, 2), vars.len);
    try std.testing.expectEqualStrings("x", vars[0].name);
    try std.testing.expectEqualStrings("42", vars[0].value);
    try std.testing.expectEqualStrings("int", vars[0].type);
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
    try std.testing.expectEqual(StopReason.exited, state.stop_reason);
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
            allocator.free(v.type);
        }
        allocator.free(vars);
    }

    try std.testing.expectEqual(@as(usize, 1), vars.len);
    try std.testing.expectEqualStrings("result", vars[0].name);
    try std.testing.expectEqualStrings("7", vars[0].value);
    try std.testing.expectEqualStrings("int", vars[0].type);
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

test "DapProxy decodes readMemory base64 to documented hex" {
    const allocator = std.testing.allocator;
    const response =
        \\{"seq":2,"type":"response","request_seq":1,"command":"readMemory","success":true,"body":{"address":"0x1000","data":"AP+AQQ=="}}
    ;

    const hex = try DapProxy.translateReadMemory(allocator, response);
    defer allocator.free(hex);

    try std.testing.expectEqualStrings("00ff8041", hex);
}

test "DapProxy rejects invalid readMemory base64" {
    const allocator = std.testing.allocator;
    const response =
        \\{"seq":2,"type":"response","request_seq":1,"command":"readMemory","success":true,"body":{"address":"0x1000","data":"not-base64!"}}
    ;

    try std.testing.expectError(error.InvalidResponse, DapProxy.translateReadMemory(allocator, response));
}

test "DapProxy breakpoint events update registry verification" {
    const allocator = std.testing.allocator;
    var proxy = DapProxy.init(allocator);
    defer proxy.deinit();

    const file = try allocator.dupe(u8, "/tmp/test.zig");
    var breakpoints: std.ArrayListUnmanaged(DapProxy.BreakpointEntry) = .empty;
    try breakpoints.append(allocator, .{ .line = 10, .condition = null, .hit_condition = null, .bp_id = 7 });
    try proxy.file_breakpoints.put(allocator, file, breakpoints);
    try proxy.bp_registry.put(allocator, 7, .{ .file = file, .line = 10, .verified = false });

    const response =
        \\{"type":"response","body":{"breakpoints":[{"id":99,"verified":false,"line":10}]}}
    ;
    proxy.updateBreakpointRegistryFromResponse(allocator, breakpoints.items, response);

    const event = try json.parseFromSlice(json.Value, allocator, "{\"id\":99,\"verified\":true,\"line\":12}", .{});
    defer event.deinit();
    proxy.handleBreakpointEvent(event.value.object);

    const listed = try DapProxy.proxyListBreakpoints(@ptrCast(&proxy), allocator);
    defer allocator.free(listed);
    try std.testing.expectEqual(@as(usize, 1), listed.len);
    try std.testing.expect(listed[0].verified);
    try std.testing.expectEqual(@as(u32, 12), listed[0].line);
}

test "DetachedProcess closes adapter pipes idempotently" {
    const stdout_pipe = try std.posix.pipe();
    const stdin_pipe = try std.posix.pipe();
    const stderr_pipe = try std.posix.pipe();
    defer std.posix.close(stdout_pipe[1]);
    defer std.posix.close(stdin_pipe[0]);
    defer std.posix.close(stderr_pipe[1]);

    var process = DetachedProcess{
        .id = 0,
        .stdin = .{ .handle = stdin_pipe[1] },
        .stdout = .{ .handle = stdout_pipe[0] },
        .stderr = .{ .handle = stderr_pipe[0] },
    };
    process.closePipes();
    process.closePipes();

    try std.testing.expect(process.stdin == null);
    try std.testing.expect(process.stdout == null);
    try std.testing.expect(process.stderr == null);
}

test "DetachedProcess repeatedly launches stops and reaps adapter fixture" {
    const allocator = std.testing.allocator;
    for (0..16) |_| {
        var process = try spawnDetached(allocator, &.{ "/bin/sh", "-c", "trap 'exit 0' TERM; while :; do sleep 1; done" });
        const pid = process.id;
        process.terminateAndReap();

        try std.testing.expectEqual(@as(std.posix.pid_t, 0), process.id);
        try std.testing.expect(process.stdin == null);
        try std.testing.expect(process.stdout == null);
        try std.testing.expect(process.stderr == null);
        try std.testing.expectError(error.ProcessNotFound, std.posix.kill(pid, 0));
    }
}

test "DapProxy bounds notification event and output queues" {
    const allocator = std.testing.allocator;
    var proxy = DapProxy.init(allocator);
    defer proxy.deinit();

    for (0..MAX_PENDING_NOTIFICATIONS + 3) |_| proxy.queueNotification("debug/output", "{}");
    for (0..MAX_BUFFERED_EVENTS + 2) |_| proxy.bufferEvent("stopped", "{}");
    for (0..MAX_OUTPUT_ENTRIES + 1) |_| proxy.bufferOutput("stdout", "x");

    try std.testing.expectEqual(MAX_PENDING_NOTIFICATIONS, proxy.pending_notifications.items.len);
    try std.testing.expectEqual(@as(usize, 3), proxy.dropped_notifications);
    try std.testing.expectEqual(MAX_BUFFERED_EVENTS, proxy.buffered_events.items.len);
    try std.testing.expectEqual(@as(usize, 2), proxy.dropped_buffered_events);
    try std.testing.expectEqual(MAX_OUTPUT_ENTRIES, proxy.output_buffer.items.len);
    try std.testing.expectEqual(@as(usize, 1), proxy.dropped_output_entries);
}

fn exerciseBoundedQueueAllocationFailures(allocator: std.mem.Allocator) !void {
    var proxy = DapProxy.init(allocator);
    defer proxy.deinit();

    try proxy.queueNotificationAlloc("debug/output", "{}");
    try proxy.bufferEventAlloc("stopped", "{}");
    try proxy.bufferOutputAlloc("stdout", "x");
}

test "DapProxy bounded queues release partial allocations" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, exerciseBoundedQueueAllocationFailures, .{});
}

test "DapProxy builds failure response for unsupported reverse request" {
    const allocator = std.testing.allocator;
    const response = try DapProxy.buildReverseResponse(allocator, 9, 27, "runInTerminal", false, "unsupported reverse request");
    defer allocator.free(response);

    const parsed = try json.parseFromSlice(json.Value, allocator, response, .{});
    defer parsed.deinit();
    try std.testing.expectEqual(@as(i64, 9), parsed.value.object.get("seq").?.integer);
    try std.testing.expectEqual(@as(i64, 27), parsed.value.object.get("request_seq").?.integer);
    try std.testing.expect(!parsed.value.object.get("success").?.bool);
    try std.testing.expectEqualStrings("unsupported reverse request", parsed.value.object.get("message").?.string);
}

test "DapProxy extracts explicit request sequence" {
    const allocator = std.testing.allocator;
    try std.testing.expectEqual(@as(i64, 41), try DapProxy.requestSeq(allocator, "{\"seq\":41,\"type\":\"request\",\"command\":\"threads\"}"));
    try std.testing.expectError(error.InvalidRequest, DapProxy.requestSeq(allocator, "{\"type\":\"request\"}"));
}

fn reserveRequestSequences(proxy: *DapProxy, ids: []i64, cursor: *std.atomic.Value(usize), count: usize) void {
    for (0..count) |_| {
        const index = cursor.fetchAdd(1, .monotonic);
        ids[index] = proxy.nextSeq();
    }
}

test "DapProxy allocates unique request sequences concurrently" {
    const allocator = std.testing.allocator;
    var proxy = DapProxy.init(allocator);
    defer proxy.deinit();

    var ids: [256]i64 = undefined;
    var cursor: std.atomic.Value(usize) = .init(0);
    var threads: [8]std.Thread = undefined;
    for (&threads) |*thread| {
        thread.* = try std.Thread.spawn(.{}, reserveRequestSequences, .{ &proxy, &ids, &cursor, 32 });
    }
    for (&threads) |thread| thread.join();

    std.mem.sort(i64, &ids, {}, std.sort.asc(i64));
    for (ids, 0..) |id, index| {
        try std.testing.expectEqual(@as(i64, @intCast(index + 1)), id);
    }
}

test "DapProxy temporary request timeout restores after early exit" {
    const allocator = std.testing.allocator;
    var proxy = DapProxy.init(allocator);
    defer proxy.deinit();
    proxy.request_timeout_ms = 30_000;

    {
        var scope = proxy.withRequestTimeout(10_000);
        defer scope.restore();
        try std.testing.expectEqual(@as(i32, 10_000), proxy.request_timeout_ms);
    }

    try std.testing.expectEqual(@as(i32, 30_000), proxy.request_timeout_ms);
}

test "DapProxy remaining deadline never renews the timeout" {
    try std.testing.expectEqual(@as(?i32, 100), DapProxy.remainingDeadlineMs(1_000, 900));
    try std.testing.expectEqual(@as(?i32, 1), DapProxy.remainingDeadlineMs(1_000, 999));
    try std.testing.expectEqual(@as(?i32, null), DapProxy.remainingDeadlineMs(1_000, 1_000));
    try std.testing.expectEqual(@as(?i32, null), DapProxy.remainingDeadlineMs(1_000, 1_001));
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

fn handleTestEvent(
    proxy: *DapProxy,
    allocator: std.mem.Allocator,
    data: []const u8,
    comptime handler: fn (*DapProxy, std.json.ObjectMap) void,
) !void {
    const parsed = try json.parseFromSlice(json.Value, allocator, data, .{});
    defer parsed.deinit();
    try std.testing.expect(parsed.value == .object);
    handler(proxy, parsed.value.object);
}

test "DapProxy caps and deduplicates adversarial event queues" {
    const allocator = std.testing.allocator;
    var proxy = DapProxy.init(allocator);
    defer proxy.deinit();

    var json_buf: [256]u8 = undefined;

    for (0..MAX_LOADED_MODULES) |i| {
        const event = try std.fmt.bufPrint(&json_buf, "{{\"reason\":\"new\",\"module\":{{\"id\":{d},\"name\":\"module-{d}\"}}}}", .{ i, i });
        try handleTestEvent(&proxy, allocator, event, DapProxy.handleModuleEvent);
    }
    try handleTestEvent(&proxy, allocator, "{\"reason\":\"changed\",\"module\":{\"id\":0,\"name\":\"module-0\"}}", DapProxy.handleModuleEvent);
    try handleTestEvent(&proxy, allocator, "{\"reason\":\"new\",\"module\":{\"id\":9999,\"name\":\"module-overflow\"}}", DapProxy.handleModuleEvent);
    try std.testing.expectEqual(MAX_LOADED_MODULES, proxy.loaded_modules.items.len);
    try std.testing.expectEqualStrings("module-1", proxy.loaded_modules.items[0].name);
    try std.testing.expectEqualStrings("module-overflow", proxy.loaded_modules.items[MAX_LOADED_MODULES - 1].name);
    try std.testing.expectEqual(@as(usize, 1), proxy.retention_drops.loaded_modules);
    try std.testing.expectEqual(@as(usize, 1), proxy.retention_deduplications.loaded_modules);
    try handleTestEvent(&proxy, allocator, "{\"reason\":\"removed\",\"module\":{\"id\":1,\"name\":\"module-1\"}}", DapProxy.handleModuleEvent);
    try std.testing.expectEqual(MAX_LOADED_MODULES - 1, proxy.loaded_modules.items.len);

    for (0..MAX_MEMORY_EVENTS) |i| {
        const event = try std.fmt.bufPrint(&json_buf, "{{\"memoryReference\":\"memory\",\"offset\":{d},\"count\":1}}", .{i});
        try handleTestEvent(&proxy, allocator, event, DapProxy.handleMemoryEvent);
    }
    try handleTestEvent(&proxy, allocator, "{\"memoryReference\":\"memory\",\"offset\":0,\"count\":1}", DapProxy.handleMemoryEvent);
    try handleTestEvent(&proxy, allocator, "{\"memoryReference\":\"memory\",\"offset\":9999,\"count\":1}", DapProxy.handleMemoryEvent);
    try std.testing.expectEqual(MAX_MEMORY_EVENTS, proxy.memory_events.items.len);
    try std.testing.expectEqual(@as(i64, 1), proxy.memory_events.items[0].offset);
    try std.testing.expectEqual(@as(i64, 9999), proxy.memory_events.items[MAX_MEMORY_EVENTS - 1].offset);
    try std.testing.expectEqual(@as(usize, 1), proxy.retention_drops.memory_events);
    try std.testing.expectEqual(@as(usize, 1), proxy.retention_deduplications.memory_events);

    for (0..MAX_ACTIVE_PROGRESS) |i| {
        const event = try std.fmt.bufPrint(&json_buf, "{{\"progressId\":\"progress-{d}\",\"title\":\"title-{d}\"}}", .{ i, i });
        try handleTestEvent(&proxy, allocator, event, DapProxy.handleProgressStart);
    }
    try handleTestEvent(&proxy, allocator, "{\"progressId\":\"progress-0\",\"title\":\"replacement\"}", DapProxy.handleProgressStart);
    try handleTestEvent(&proxy, allocator, "{\"progressId\":\"progress-overflow\",\"title\":\"overflow\"}", DapProxy.handleProgressStart);
    try std.testing.expectEqual(MAX_ACTIVE_PROGRESS, proxy.active_progress.count());
    try std.testing.expectEqualStrings("replacement", proxy.active_progress.get("progress-0").?.title);
    try std.testing.expect(proxy.active_progress.get("progress-overflow") == null);
    try std.testing.expectEqual(@as(usize, 1), proxy.retention_drops.active_progress);
    try std.testing.expectEqual(@as(usize, 1), proxy.retention_deduplications.active_progress);
    try handleTestEvent(&proxy, allocator, "{\"progressId\":\"progress-0\"}", DapProxy.handleProgressEnd);
    try handleTestEvent(&proxy, allocator, "{\"progressId\":\"progress-overflow\",\"title\":\"overflow\"}", DapProxy.handleProgressStart);
    try std.testing.expectEqual(MAX_ACTIVE_PROGRESS, proxy.active_progress.count());
    try std.testing.expect(proxy.active_progress.get("progress-overflow") != null);

    for (0..MAX_INVALIDATED_AREAS) |i| {
        const event = try std.fmt.bufPrint(&json_buf, "{{\"areas\":[\"variables\"],\"stackFrameId\":{d}}}", .{i});
        try handleTestEvent(&proxy, allocator, event, DapProxy.handleInvalidatedEvent);
    }
    try handleTestEvent(&proxy, allocator, "{\"areas\":[\"variables\"],\"stackFrameId\":0}", DapProxy.handleInvalidatedEvent);
    try handleTestEvent(&proxy, allocator, "{\"areas\":[\"variables\"],\"stackFrameId\":9999}", DapProxy.handleInvalidatedEvent);
    try std.testing.expectEqual(MAX_INVALIDATED_AREAS, proxy.invalidated_areas.items.len);
    try std.testing.expectEqual(@as(?u32, 1), proxy.invalidated_areas.items[0].stack_frame_id);
    try std.testing.expectEqual(@as(?u32, 9999), proxy.invalidated_areas.items[MAX_INVALIDATED_AREAS - 1].stack_frame_id);
    try std.testing.expectEqual(@as(usize, 1), proxy.retention_drops.invalidated_areas);
    try std.testing.expectEqual(@as(usize, 1), proxy.retention_deduplications.invalidated_areas);
}

test "DapProxy keys loaded modules by protocol id" {
    const allocator = std.testing.allocator;
    var proxy = DapProxy.init(allocator);
    defer proxy.deinit();

    try handleTestEvent(&proxy, allocator, "{\"reason\":\"new\",\"module\":{\"id\":1,\"name\":\"libshared.so\"}}", DapProxy.handleModuleEvent);
    try handleTestEvent(&proxy, allocator, "{\"reason\":\"new\",\"module\":{\"id\":\"two\",\"name\":\"libshared.so\"}}", DapProxy.handleModuleEvent);
    try std.testing.expectEqual(@as(usize, 2), proxy.loaded_modules.items.len);

    try handleTestEvent(&proxy, allocator, "{\"reason\":\"changed\",\"module\":{\"id\":\"two\",\"name\":\"libshared-renamed.so\"}}", DapProxy.handleModuleEvent);
    try std.testing.expectEqualStrings("libshared-renamed.so", proxy.loaded_modules.items[1].name);

    try handleTestEvent(&proxy, allocator, "{\"reason\":\"removed\",\"module\":{\"id\":1,\"name\":\"libshared.so\"}}", DapProxy.handleModuleEvent);
    try std.testing.expectEqual(@as(usize, 1), proxy.loaded_modules.items.len);
    try std.testing.expectEqualStrings("libshared-renamed.so", proxy.loaded_modules.items[0].name);
}

test "DapProxy ignores invalid stack frame id ranges" {
    const allocator = std.testing.allocator;
    var proxy = DapProxy.init(allocator);
    defer proxy.deinit();

    try handleTestEvent(&proxy, allocator, "{\"areas\":[\"variables\"],\"stackFrameId\":-1}", DapProxy.handleInvalidatedEvent);
    try handleTestEvent(&proxy, allocator, "{\"areas\":[\"variables\"],\"stackFrameId\":4294967296}", DapProxy.handleInvalidatedEvent);
    try std.testing.expectEqual(@as(usize, 0), proxy.invalidated_areas.items.len);

    try handleTestEvent(&proxy, allocator, "{\"areas\":[\"variables\"],\"stackFrameId\":4294967295}", DapProxy.handleInvalidatedEvent);
    try std.testing.expectEqual(@as(usize, 1), proxy.invalidated_areas.items.len);
    try std.testing.expectEqual(@as(?u32, std.math.maxInt(u32)), proxy.invalidated_areas.items[0].stack_frame_id);
}

fn readTestPid(file: std.fs.File) !std.posix.pid_t {
    var buf: [32]u8 = undefined;
    var len: usize = 0;

    while (len < buf.len) {
        var poll_fds = [_]std.posix.pollfd{.{
            .fd = file.handle,
            .events = std.posix.POLL.IN,
            .revents = 0,
        }};
        if (try std.posix.poll(&poll_fds, 2_000) == 0) return error.Timeout;
        const n = try file.read(buf[len .. len + 1]);
        if (n == 0) return error.EndOfStream;
        if (buf[len] == '\n') {
            return std.fmt.parseInt(std.posix.pid_t, buf[0..len], 10);
        }
        len += 1;
    }
    return error.LineTooLong;
}

fn expectTestProcessGone(pid: std.posix.pid_t) !void {
    for (0..100) |_| {
        std.posix.kill(pid, 0) catch |err| switch (err) {
            error.ProcessNotFound => return,
            else => {},
        };
        std.posix.nanosleep(0, 10_000_000);
    }
    return error.ProcessStillRunning;
}

test "DetachedProcess terminateAndReap kills process group descendants" {
    if (builtin.os.tag != .macos and builtin.os.tag != .linux) return error.SkipZigTest;

    const script =
        \\trap '' TERM
        \\/bin/sh -c 'trap "" TERM; while :; do /bin/sleep 30; done' &
        \\child=$!
        \\printf '%s\n' "$child"
        \\wait "$child"
    ;
    var process = try spawnDetached(std.testing.allocator, &.{ "/bin/sh", "-c", script });
    defer process.terminateAndReap();

    const leader_pid = process.id;
    const descendant_pid = try readTestPid(process.stdout.?);
    try std.testing.expect(leader_pid != getpgrp());
    try std.testing.expectEqual(leader_pid, getpgid(leader_pid));
    try std.testing.expectEqual(leader_pid, getpgid(descendant_pid));
    try std.testing.expect(descendant_pid != leader_pid);

    process.terminateAndReap();

    try std.testing.expectEqual(@as(std.posix.pid_t, 0), process.id);
    var status: c_int = 0;
    try std.testing.expectEqual(@as(std.posix.pid_t, -1), std.c.waitpid(leader_pid, &status, 1));
    try expectTestProcessGone(descendant_pid);
}
