const std = @import("std");
const builtin = @import("builtin");
const json = std.json;
const Stringify = json.Stringify;
const Writer = std.io.Writer;
const posix = std.posix;
const code_intel = @import("code_intel.zig");
const config_mod = @import("config.zig");
const client = @import("client.zig");
const debug_server_mod = @import("debug/server.zig");
const debug_mod = @import("debug.zig");
const watcher_mod = @import("watcher.zig");
const paths = @import("paths.zig");
const debug_log_mod = @import("debug_log.zig");
const memory_mod = @import("memory.zig");
const repo_context_mod = @import("repo_context.zig");
const session_context_mod = @import("session_context.zig");
const memory_envelope_mod = @import("memory_envelope.zig");
const log_server_mod = @import("log_server.zig");

const Config = config_mod.Config;
const DebugServer = debug_server_mod.DebugServer;

// ── MCP Server ──────────────────────────────────────────────────────────

var server_version: []const u8 = "0.0.0";
var shutdown_requested: std.atomic.Value(bool) = std.atomic.Value(bool).init(false);

const RemoteTool = struct {
    name: []const u8, // local name: "mem_recall"
    remote_name: []const u8, // server name: "cog_recall"
    description: []const u8,
    input_schema: []const u8, // raw JSON string
};

const ToolTier = debug_server_mod.ToolTier;
const LogServer = log_server_mod.LogServer;

const Runtime = struct {
    allocator: std.mem.Allocator,
    mem_config: ?Config,
    brain_type: config_mod.BrainType,
    mem_db: ?memory_mod.MemoryDb = null,
    debug_server: DebugServer,
    log_server: LogServer,
    code_cache: ?code_intel.CodeIndex = null,
    remote_tools: ?[]RemoteTool = null,
    mcp_session_id: ?[]const u8 = null,
    session_contexts: std.StringHashMapUnmanaged(session_context_mod.SessionContext) = .empty,
    remote_memory_capabilities: memory_envelope_mod.RemoteMemoryCapabilities = .{},
    repo_context_cache: std.StringHashMapUnmanaged(repo_context_mod.RepoContext) = .empty,
    watcher: ?watcher_mod.Watcher = null,
    debug_tool_tier: ToolTier = .specialist,
    /// Protects code_cache, remote_tools, mcp_session_id, and mem_db from concurrent access.
    mutex: std.Thread.Mutex = .{},

    fn init(allocator: std.mem.Allocator, debug_tool_tier: ToolTier) Runtime {
        const brain = config_mod.resolveBrain(allocator);
        debug_log_mod.log("Runtime.init: brain_type={s}", .{@tagName(brain)});
        return .{
            .allocator = allocator,
            .mem_config = switch (brain) {
                .remote => |r| r,
                else => null,
            },
            .brain_type = brain,
            .mem_db = null,
            .debug_server = DebugServer.init(allocator),
            .log_server = LogServer.init(allocator),
            .code_cache = null,
            .remote_tools = null,
            .mcp_session_id = null,
            .session_contexts = .empty,
            .remote_memory_capabilities = .{},
            .repo_context_cache = .empty,
            .watcher = watcher_mod.Watcher.init(allocator),
            .debug_tool_tier = debug_tool_tier,
        };
    }

    fn deinit(self: *Runtime) void {
        if (self.watcher) |*w| w.deinit();
        self.log_server.deinit();
        if (self.mem_db) |*mdb| mdb.close();
        // brain_type owns the Config when .remote — don't also free via mem_config
        self.brain_type.deinit(self.allocator);
        if (self.code_cache) |*ci| ci.deinit(self.allocator);
        if (self.remote_tools) |tools| {
            for (tools) |tool| {
                self.allocator.free(tool.name);
                self.allocator.free(tool.remote_name);
                self.allocator.free(tool.description);
                self.allocator.free(tool.input_schema);
            }
            self.allocator.free(tools);
        }
        self.remote_memory_capabilities.deinit(self.allocator);
        var session_iter = self.session_contexts.iterator();
        while (session_iter.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            entry.value_ptr.deinit();
        }
        self.session_contexts.deinit(self.allocator);
        var repo_iter = self.repo_context_cache.iterator();
        while (repo_iter.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            entry.value_ptr.deinit(self.allocator);
        }
        self.repo_context_cache.deinit(self.allocator);
        if (self.mcp_session_id) |sid| self.allocator.free(sid);
        self.debug_server.deinit();
    }

    fn hasMemory(self: *const Runtime) bool {
        return self.brain_type != .none;
    }

    fn isLocalBrain(self: *const Runtime) bool {
        return self.brain_type == .local;
    }

    fn ensureMemoryDb(self: *Runtime) !*memory_mod.MemoryDb {
        if (self.mem_db != null) return &self.mem_db.?;
        const local = switch (self.brain_type) {
            .local => |l| l,
            else => return error.NotConfigured,
        };
        debug_log_mod.log("Runtime: lazy-opening local brain at {s}", .{local.path});
        // Convert path to null-terminated
        const path_z = try self.allocator.dupeZ(u8, local.path);
        defer self.allocator.free(path_z);
        self.mem_db = try memory_mod.MemoryDb.open(self.allocator, path_z, local.brain_id);
        return &self.mem_db.?;
    }

    fn ensureCodeCache(self: *Runtime) !*code_intel.CodeIndex {
        if (self.code_cache == null) {
            self.code_cache = try code_intel.loadIndexForRuntime(self.allocator);
        }
        return &self.code_cache.?;
    }

    fn invalidateCodeCache(self: *Runtime) void {
        if (self.code_cache) |*ci| {
            ci.deinit(self.allocator);
            self.code_cache = null;
        }
    }

    fn refreshCodeCache(self: *Runtime) !void {
        self.invalidateCodeCache();
        _ = try self.ensureCodeCache();
    }

    fn syncCodeCacheAfterWrite(self: *Runtime) !void {
        const fresh = code_intel.loadIndexForRuntime(self.allocator) catch {
            // Avoid stale in-memory state if disk changed but reload failed.
            self.invalidateCodeCache();
            return error.Explained;
        };

        if (self.code_cache) |*old| {
            old.deinit(self.allocator);
        }
        self.code_cache = fresh;
    }

    fn currentSessionKey(self: *const Runtime) []const u8 {
        return self.mcp_session_id orelse "local-stdio-session";
    }

    fn ensureSessionContext(self: *Runtime) !*session_context_mod.SessionContext {
        const key = self.currentSessionKey();
        if (self.session_contexts.getPtr(key)) |ctx| return ctx;

        const repo_ctx = try self.resolveRepoContext();
        const workspace_root = try resolveWorkspaceRoot(self.allocator, repo_ctx.cwd);
        defer self.allocator.free(workspace_root);
        const host_agent_id = try detectHostAgentId(self.allocator, workspace_root);
        defer self.allocator.free(host_agent_id);

        const brain_url = if (self.mem_config) |cfg| cfg.brain_url else "file:.cog/brain.db";
        const brain_parts = parseBrainIdentity(brain_url);
        const owned_key = try self.allocator.dupe(u8, key);
        errdefer self.allocator.free(owned_key);
        const ctx = try session_context_mod.initSessionContext(
            self.allocator,
            key,
            host_agent_id,
            workspace_root,
            brain_url,
            if (brain_parts) |parts| parts.namespace else null,
            if (brain_parts) |parts| parts.name else null,
            repo_ctx,
        );
        try self.session_contexts.put(self.allocator, owned_key, ctx);
        debug_log_mod.log("mcp.ensureSessionContext: created session={s}", .{key});
        return self.session_contexts.getPtr(key).?;
    }

    fn resolveRepoContext(self: *Runtime) !*repo_context_mod.RepoContext {
        const cwd = try std.fs.cwd().realpathAlloc(self.allocator, ".");
        defer self.allocator.free(cwd);

        if (self.repo_context_cache.getPtr(cwd)) |cached| return cached;
        const resolved = try repo_context_mod.resolve(self.allocator, cwd);
        const key = try self.allocator.dupe(u8, cwd);
        errdefer self.allocator.free(key);
        try self.repo_context_cache.put(self.allocator, key, resolved);
        debug_log_mod.log("mcp.resolveRepoContext: cached cwd={s}", .{cwd});
        return self.repo_context_cache.getPtr(cwd).?;
    }
};

pub fn serve(allocator: std.mem.Allocator, version: []const u8, args: []const [:0]const u8) !void {
    server_version = version;
    shutdown_requested.store(false, .release);

    // Parse MCP-specific CLI flags
    var debug_tool_tier: ToolTier = .specialist; // default: expose all tools
    for (args) |arg| {
        if (std.mem.startsWith(u8, arg, "--debug-tools=")) {
            const val = arg["--debug-tools=".len..];
            if (std.mem.eql(u8, val, "core")) {
                debug_tool_tier = .core;
            } else if (std.mem.eql(u8, val, "extended")) {
                debug_tool_tier = .extended;
            } else if (std.mem.eql(u8, val, "all")) {
                debug_tool_tier = .specialist;
            }
        }
    }

    // On macOS, ensure debug entitlements are active for task_for_pid().
    // Sign the binary and re-exec so the kernel grants the entitlement.
    // execvpe preserves the same PID and stdio file descriptors, so the
    // MCP client's pipe is unaffected.
    if (builtin.os.tag == .macos) {
        if (std.posix.getenv("COG_DEBUG_SIGNED") == null) {
            debug_mod.ensureDebugEntitlements(allocator) catch {};
            debug_mod.reexecWithEntitlements();
            // If re-exec failed, continue without entitlements
        }
    }

    debug_log_mod.log("mcp.serve: starting version={s} debug_tools={s}", .{ version, @tagName(debug_tool_tier) });
    debugLogInit();
    setupSignalHandler();

    var runtime = Runtime.init(allocator, debug_tool_tier);
    // Start the watcher thread AFTER runtime is in its final stack location.
    // The thread captures a pointer to runtime.watcher, so it must not move.
    if (runtime.watcher != null) {
        runtime.watcher.?.start();
        debugLog("File watcher started", .{});
    }
    debugLog("Runtime initialized, mem_config={s}, entering main loop", .{if (runtime.mem_config != null) "present" else "null"});

    const stdin = std.fs.File.stdin();

    // Thread-safe stdout writer shared by all handler threads
    var stdout_mutex: std.Thread.Mutex = .{};
    const stdout_writer = StdoutWriter{
        .file = std.fs.File.stdout(),
        .mutex = &stdout_mutex,
    };

    var input_buf: std.ArrayListUnmanaged(u8) = .empty;
    defer input_buf.deinit(allocator);

    var read_buf: [8192]u8 = undefined;

    while (!shutdown_requested.load(.acquire)) {
        if (builtin.os.tag != .windows) {
            var fds: [2]posix.pollfd = undefined;
            fds[0] = .{ .fd = stdin.handle, .events = posix.POLL.IN, .revents = 0 };
            var nfds: usize = 1;
            if (runtime.watcher) |*w| {
                fds[1] = .{ .fd = w.getFd(), .events = posix.POLL.IN, .revents = 0 };
                nfds = 2;
            }
            const poll_result = posix.poll(fds[0..nfds], 250) catch continue;
            if (poll_result == 0) continue;

            // Process watcher events if ready
            if (nfds > 1 and fds[1].revents & posix.POLL.IN != 0) {
                processWatcherEvents(&runtime);
            }

            if (fds[0].revents & posix.POLL.ERR != 0) {
                debugLog("poll: POLLERR on stdin, exiting", .{});
                break;
            }
            if (fds[0].revents & posix.POLL.IN == 0) {
                // If stdin is hung up and there's no readable data left,
                // terminate the server loop.
                if (fds[0].revents & posix.POLL.HUP != 0) {
                    debugLog("poll: POLLHUP on stdin, exiting", .{});
                    break;
                }
                continue;
            }
        }

        const n = stdin.read(&read_buf) catch |err| {
            debugLog("stdin read error: {s}", .{@errorName(err)});
            break;
        };
        if (n == 0) {
            debugLog("stdin EOF (read returned 0)", .{});
            break;
        }
        debugLog("Read {d} bytes from stdin", .{n});
        debugLogBytes("RAW stdin bytes: ", read_buf[0..n]);
        if (std.mem.indexOfScalar(u8, read_buf[0..n], 0x03) != null) {
            shutdown_requested.store(true, .release);
            break;
        }
        try input_buf.appendSlice(allocator, read_buf[0..n]);

        while (try nextMessageFromBuffer(allocator, &input_buf)) |msg| {
            // Spawn a handler thread per message for concurrent processing.
            // The thread owns `msg` and frees it when done.
            const thread = std.Thread.spawn(.{}, handleRequest, .{ &runtime, msg, stdout_writer }) catch {
                // If we can't spawn a thread, process inline as fallback
                defer allocator.free(msg);
                processMessage(&runtime, msg, stdout_writer) catch |err| {
                    logErr("MCP processMessage error: ", err);
                    if (err == error.WriteFailure) {
                        shutdown_requested.store(true, .release);
                        break;
                    }
                };
                continue;
            };
            thread.detach();
        }
    }

    debugLog("=== MCP server shutting down ===", .{});

    // Clean up debug sessions before exiting — kills adapter process groups
    // to prevent orphaned debugpy/launcher/debuggee processes.
    runtime.debug_server.deinit();

    debugLogDeinit();

    // Force-exit the process. On macOS the file-watcher thread can get
    // stuck in CFRunLoop's mach_msg2_trap, making thread-join hang
    // indefinitely and leaving an orphaned process.  Since the MCP server
    // holds no resources that need flushing beyond what the OS reclaims on
    // exit, an immediate _exit is the safest shutdown path.
    std.process.exit(0);
}

fn setupSignalHandler() void {
    if (builtin.os.tag == .windows) return;

    const act: posix.Sigaction = .{
        .handler = .{ .handler = sigHandler },
        .mask = posix.sigemptyset(),
        .flags = 0,
    };
    posix.sigaction(posix.SIG.INT, &act, null);
    posix.sigaction(posix.SIG.TERM, &act, null);
    posix.sigaction(posix.SIG.HUP, &act, null);

    // Ignore SIGPIPE so that writes to a closed stdout return
    // error.BrokenPipe instead of killing the process.
    const ign: posix.Sigaction = .{
        .handler = .{ .handler = posix.SIG.IGN },
        .mask = posix.sigemptyset(),
        .flags = 0,
    };
    posix.sigaction(posix.SIG.PIPE, &ign, null);
}

fn sigHandler(_: c_int) callconv(.c) void {
    shutdown_requested.store(true, .release);
}

fn drainConsumed(allocator: std.mem.Allocator, input: *std.ArrayListUnmanaged(u8), consumed: usize) !void {
    if (consumed == 0) return;
    if (consumed >= input.items.len) {
        input.clearRetainingCapacity();
        return;
    }
    const remain = input.items.len - consumed;
    std.mem.copyForwards(u8, input.items[0..remain], input.items[consumed..]);
    input.shrinkRetainingCapacity(remain);
    _ = allocator;
}

fn nextMessageFromBuffer(allocator: std.mem.Allocator, input: *std.ArrayListUnmanaged(u8)) !?[]u8 {
    // MCP stdio transport: messages are newline-delimited JSON.
    // Each message is a single JSON object on one line, terminated by \n.
    const bytes = input.items;
    if (bytes.len == 0) return null;

    // Skip any leading whitespace/newlines between messages.
    var start: usize = 0;
    while (start < bytes.len and (bytes[start] == '\n' or bytes[start] == '\r' or bytes[start] == ' ' or bytes[start] == '\t')) {
        start += 1;
    }
    if (start > 0) {
        try drainConsumed(allocator, input, start);
        if (input.items.len == 0) return null;
    }

    // Find the newline that terminates this JSON message.
    const newline_pos = std.mem.indexOfScalar(u8, input.items, '\n');
    if (newline_pos) |pos| {
        const msg = try allocator.dupe(u8, input.items[0..pos]);
        try drainConsumed(allocator, input, pos + 1);
        return msg;
    }

    // No newline yet — check if the buffer contains a complete JSON object.
    // Some clients send JSON without a trailing newline (e.g. as last message
    // before closing stdin). Try to parse what we have.
    if (input.items.len > 0 and input.items[0] == '{') {
        // Validate it's complete JSON by counting braces.
        var depth: usize = 0;
        var in_string = false;
        var escape = false;
        for (input.items, 0..) |c, i| {
            if (escape) {
                escape = false;
                continue;
            }
            if (c == '\\' and in_string) {
                escape = true;
                continue;
            }
            if (c == '"' and !escape) {
                in_string = !in_string;
                continue;
            }
            if (!in_string) {
                if (c == '{') depth += 1;
                if (c == '}') {
                    depth -= 1;
                    if (depth == 0) {
                        const end = i + 1;
                        const msg = try allocator.dupe(u8, input.items[0..end]);
                        try drainConsumed(allocator, input, end);
                        return msg;
                    }
                }
            }
        }
    }

    // Incomplete message — wait for more data.
    return null;
}

/// Handler thread entry point. Owns `msg` and frees it when done.
fn handleRequest(runtime: *Runtime, msg: []const u8, stdout: StdoutWriter) void {
    defer runtime.allocator.free(msg);
    processMessage(runtime, msg, stdout) catch |err| {
        logErr("MCP processMessage error: ", err);
        if (err == error.WriteFailure) {
            shutdown_requested.store(true, .release);
        }
    };
}

fn processMessage(runtime: *Runtime, line: []const u8, stdout: StdoutWriter) !void {
    const allocator = runtime.allocator;
    debugLogBytes(">>> RECV: ", line);

    const parsed = json.parseFromSlice(json.Value, allocator, line, .{}) catch {
        debugLog("Parse error on incoming message", .{});
        try writeError(allocator, null, -32700, "Parse error", stdout);
        return;
    };
    defer parsed.deinit();

    const root = parsed.value;
    if (root != .object) {
        try writeError(allocator, null, -32600, "Invalid Request", stdout);
        return;
    }

    const method_val = root.object.get("method") orelse {
        try writeError(allocator, null, -32600, "Missing method", stdout);
        return;
    };
    if (method_val != .string) {
        try writeError(allocator, null, -32600, "Method must be string", stdout);
        return;
    }
    const method = method_val.string;
    debugLog("Method: {s}", .{method});

    // Get request id (may be null for notifications)
    const id = root.object.get("id");

    // For requests (id != null), create a ReplyOnce guard that guarantees
    // exactly one response is sent. If the handler returns without responding,
    // the guard's deinit sends a fallback internal error.
    var reply = ReplyOnce.init(allocator, id, stdout);
    defer reply.deinit();

    // Dispatch
    if (std.mem.eql(u8, method, "initialize")) {
        handleInitialize(allocator, &reply) catch |err| {
            reply.sendInternalError(err);
        };
    } else if (std.mem.eql(u8, method, "notifications/initialized")) {
        reply.markNotification(); // No response needed
    } else if (std.mem.eql(u8, method, "shutdown")) {
        handleShutdown(allocator, &reply) catch |err| {
            reply.sendInternalError(err);
        };
    } else if (std.mem.eql(u8, method, "exit")) {
        reply.markNotification(); // No response needed
        shutdown_requested.store(true, .release);
    } else if (std.mem.eql(u8, method, "ping")) {
        handlePing(allocator, &reply) catch |err| {
            reply.sendInternalError(err);
        };
    } else if (std.mem.eql(u8, method, "tools/list")) {
        handleToolsList(runtime, &reply) catch |err| {
            reply.sendInternalError(err);
        };
    } else if (std.mem.eql(u8, method, "tools/call")) {
        const params = root.object.get("params");
        handleToolsCall(runtime, &reply, params) catch |err| {
            reply.sendInternalError(err);
        };
    } else if (std.mem.eql(u8, method, "resources/list")) {
        handleResourcesList(allocator, &reply) catch |err| {
            reply.sendInternalError(err);
        };
    } else if (std.mem.eql(u8, method, "resources/read")) {
        const params = root.object.get("params");
        handleResourcesRead(runtime, &reply, params) catch |err| {
            reply.sendInternalError(err);
        };
    } else if (std.mem.eql(u8, method, "prompts/list")) {
        handlePromptsList(allocator, &reply) catch |err| {
            reply.sendInternalError(err);
        };
    } else if (std.mem.eql(u8, method, "prompts/get")) {
        const params = root.object.get("params");
        handlePromptsGet(allocator, &reply, params) catch |err| {
            reply.sendInternalError(err);
        };
    } else if (std.mem.eql(u8, method, "notifications/cancelled") or std.mem.eql(u8, method, "notifications/progress")) {
        reply.markNotification(); // No response needed
    } else {
        if (id != null) {
            reply.sendError(-32601, "Method not found") catch {};
        } else {
            reply.markNotification();
        }
    }
}

// ── Stdout Writer ───────────────────────────────────────────────────────
//
// Thread-safe wrapper around stdout that serializes all JSON-RPC response
// writes through a mutex. Shared across all handler threads.

const StdoutWriter = struct {
    file: std.fs.File,
    mutex: *std.Thread.Mutex,

    fn writeResponse(self: StdoutWriter, data: []const u8) !void {
        debug_log_mod.log("stdout_writer: acquiring mutex", .{});
        self.mutex.lock();
        defer {
            self.mutex.unlock();
            debug_log_mod.log("stdout_writer: mutex released", .{});
        }
        debug_log_mod.log("stdout_writer: mutex acquired", .{});
        debugLogBytes("<<< SEND: ", data);
        var buf: [8192]u8 = undefined;
        var w = self.file.writerStreaming(&buf);
        w.interface.writeAll(data) catch return error.WriteFailure;
        w.interface.writeAll("\n") catch return error.WriteFailure;
        w.interface.flush() catch return error.WriteFailure;
    }
};

// ── ReplyOnce Guard ─────────────────────────────────────────────────────
//
// Guarantees that every MCP request receives exactly one JSON-RPC response.
// Create one per request, use `defer reply.deinit()`. If no response has been
// sent when deinit runs, a fallback -32603 "Internal error" is emitted.
// For notifications (no id), call `markNotification()` to suppress the guard.

const ReplyOnce = struct {
    allocator: std.mem.Allocator,
    id: ?json.Value,
    stdout: StdoutWriter,
    responded: bool = false,
    is_notification: bool = false,

    fn init(allocator: std.mem.Allocator, id: ?json.Value, stdout: StdoutWriter) ReplyOnce {
        return .{
            .allocator = allocator,
            .id = id,
            .stdout = stdout,
        };
    }

    /// Mark this message as a notification (no response expected).
    fn markNotification(self: *ReplyOnce) void {
        self.is_notification = true;
    }

    /// Send a successful tool result. Sets responded = true.
    fn sendToolResult(self: *ReplyOnce, content: []const u8) !void {
        if (self.responded) return;
        self.responded = true;
        try writeToolResult(self.allocator, self.id, content, self.stdout);
    }

    /// Send a tool-level error (isError=true in MCP result). Sets responded = true.
    fn sendToolError(self: *ReplyOnce, message: []const u8) !void {
        if (self.responded) return;
        self.responded = true;
        try writeToolError(self.allocator, self.id, message, self.stdout);
    }

    /// Send a JSON-RPC error response. Sets responded = true.
    fn sendError(self: *ReplyOnce, code: i32, message: []const u8) !void {
        if (self.responded) return;
        self.responded = true;
        try writeError(self.allocator, self.id, code, message, self.stdout);
    }

    /// Send a pre-formatted raw JSON response. Sets responded = true.
    fn sendRaw(self: *ReplyOnce, data: []const u8) !void {
        if (self.responded) return;
        self.responded = true;
        try self.stdout.writeResponse(data);
    }

    /// Send a -32603 internal error. Used by catch blocks in processMessage.
    fn sendInternalError(self: *ReplyOnce, err: anyerror) void {
        if (self.responded) return;
        if (self.id == null) return;
        debugLog("Handler error: {s}, sending internal error response", .{@errorName(err)});
        self.responded = true;
        writeError(self.allocator, self.id, -32603, "Internal error", self.stdout) catch {};
    }

    /// Destructor — the safety net. If no response was sent for a request,
    /// emit a fallback internal error so the client never hangs.
    fn deinit(self: *ReplyOnce) void {
        if (self.is_notification) return;
        if (self.responded) return;
        if (self.id == null) return;
        debugLog("ReplyOnce: handler returned without responding, sending fallback error", .{});
        writeError(self.allocator, self.id, -32603, "Internal error: no response produced", self.stdout) catch {};
    }
};

fn handleShutdown(allocator: std.mem.Allocator, reply: *ReplyOnce) !void {
    var aw: Writer.Allocating = .init(allocator);
    defer aw.deinit();
    var s: Stringify = .{ .writer = &aw.writer };
    try s.beginObject();
    try s.objectField("jsonrpc");
    try s.write("2.0");
    try writeId(&s, reply.id);
    try s.objectField("result");
    try s.beginObject();
    try s.endObject();
    try s.endObject();
    const result = try aw.toOwnedSlice();
    defer allocator.free(result);
    try reply.sendRaw(result);
    shutdown_requested.store(true, .release);
}

fn handlePing(allocator: std.mem.Allocator, reply: *ReplyOnce) !void {
    var aw: Writer.Allocating = .init(allocator);
    defer aw.deinit();
    var s: Stringify = .{ .writer = &aw.writer };
    try s.beginObject();
    try s.objectField("jsonrpc");
    try s.write("2.0");
    try writeId(&s, reply.id);
    try s.objectField("result");
    try s.beginObject();
    try s.endObject();
    try s.endObject();
    const result = try aw.toOwnedSlice();
    defer allocator.free(result);
    try reply.sendRaw(result);
}

fn handleInitialize(allocator: std.mem.Allocator, reply: *ReplyOnce) !void {
    var aw: Writer.Allocating = .init(allocator);
    defer aw.deinit();
    var s: Stringify = .{ .writer = &aw.writer };

    try s.beginObject();
    try s.objectField("jsonrpc");
    try s.write("2.0");
    try writeId(&s, reply.id);
    try s.objectField("result");
    try s.beginObject();
    try s.objectField("protocolVersion");
    try s.write("2025-11-25");
    try s.objectField("capabilities");
    try s.beginObject();
    try s.objectField("tools");
    try s.beginObject();
    try s.endObject();
    try s.objectField("prompts");
    try s.beginObject();
    try s.endObject();
    try s.objectField("resources");
    try s.beginObject();
    try s.endObject();
    try s.endObject();
    try s.objectField("serverInfo");
    try s.beginObject();
    try s.objectField("name");
    try s.write("cog");
    try s.objectField("version");
    try s.write(server_version);
    try s.endObject();
    try s.endObject();
    try s.endObject();

    const result = try aw.toOwnedSlice();
    defer allocator.free(result);
    try reply.sendRaw(result);
}

fn handleToolsList(runtime: *Runtime, reply: *ReplyOnce) !void {
    const allocator = runtime.allocator;

    // Protect remote_tools discovery/access
    debug_log_mod.log("handleToolsList: acquiring runtime mutex", .{});
    runtime.mutex.lock();
    defer {
        runtime.mutex.unlock();
        debug_log_mod.log("handleToolsList: runtime mutex released", .{});
    }
    debug_log_mod.log("handleToolsList: runtime mutex acquired", .{});

    var aw: Writer.Allocating = .init(allocator);
    defer aw.deinit();
    var s: Stringify = .{ .writer = &aw.writer };

    try s.beginObject();
    try s.objectField("jsonrpc");
    try s.write("2.0");
    try writeId(&s, reply.id);
    try s.objectField("result");
    try s.beginObject();
    try s.objectField("tools");
    try s.beginArray();
    try writeToolCatalog(runtime, allocator, &s);

    try s.endArray();
    try s.endObject();
    try s.endObject();

    const result = try aw.toOwnedSlice();
    defer allocator.free(result);
    try reply.sendRaw(result);
}

fn handleToolsCall(runtime: *Runtime, reply: *ReplyOnce, params: ?json.Value) !void {
    const allocator = runtime.allocator;
    const p = params orelse {
        try reply.sendError(-32602, "Missing params");
        return;
    };
    if (p != .object) {
        try reply.sendError(-32602, "Invalid params");
        return;
    }

    const name_val = p.object.get("name") orelse {
        try reply.sendError(-32602, "Missing tool name");
        return;
    };
    if (name_val != .string) {
        try reply.sendError(-32602, "Tool name must be string");
        return;
    }
    const tool_name = name_val.string;
    debug_log_mod.log("handleToolsCall: {s}", .{tool_name});

    const arguments = if (p.object.get("arguments")) |a| (if (a == .object) a else null) else null;

    debug_log_mod.log("handleToolsCall: acquiring runtime mutex for session context ({s})", .{tool_name});
    runtime.mutex.lock();
    debug_log_mod.log("handleToolsCall: runtime mutex acquired for session context ({s})", .{tool_name});
    _ = runtime.ensureSessionContext() catch {};
    runtime.mutex.unlock();
    debug_log_mod.log("handleToolsCall: runtime mutex released for session context ({s})", .{tool_name});

    // Dispatch tool
    const tool_result = runtimeCallTool(runtime, tool_name, arguments) catch |err| {
        const err_msg = switch (err) {
            error.MissingName => "Missing required parameter: name",
            error.MissingFile => "Missing required parameter: file",
            error.NotConfigured => "Memory not configured. Run 'cog init' with memory enabled.",
            error.IndexUnavailable => "Code index unavailable. Run 'cog code:index' before using Cog code tools.",
            error.Explained => "Operation failed (see stderr)",
            else => "Internal error",
        };
        try reply.sendToolError(err_msg);
        return;
    };
    defer allocator.free(tool_result);

    try reply.sendToolResult(tool_result);
}

fn handlePromptsList(allocator: std.mem.Allocator, reply: *ReplyOnce) !void {
    var aw: Writer.Allocating = .init(allocator);
    defer aw.deinit();
    var s: Stringify = .{ .writer = &aw.writer };

    try s.beginObject();
    try s.objectField("jsonrpc");
    try s.write("2.0");
    try writeId(&s, reply.id);
    try s.objectField("result");
    try s.beginObject();
    try s.objectField("prompts");
    try s.beginArray();
    try s.beginObject();
    try s.objectField("name");
    try s.write("cog_reference");
    try s.objectField("description");
    try s.write("Reference for predicates, staleness checks, and consolidation guidance");
    try s.endObject();
    try s.endArray();
    try s.endObject();
    try s.endObject();

    const result = try aw.toOwnedSlice();
    defer allocator.free(result);
    try reply.sendRaw(result);
}

fn handlePromptsGet(allocator: std.mem.Allocator, reply: *ReplyOnce, params: ?json.Value) !void {
    const p = params orelse {
        try reply.sendError(-32602, "Missing params");
        return;
    };
    if (p != .object) {
        try reply.sendError(-32602, "Invalid params");
        return;
    }
    const name_val = p.object.get("name") orelse {
        try reply.sendError(-32602, "Missing prompt name");
        return;
    };
    if (name_val != .string) {
        try reply.sendError(-32602, "Prompt name must be string");
        return;
    }

    if (!std.mem.eql(u8, name_val.string, "cog_reference")) {
        try reply.sendError(-32602, "Unknown prompt");
        return;
    }

    const prompt_text =
        "Use concise, specific terms and explicit predicates when recording memory. " ++
        "Prefer chain relationships for causality and dependency, and use associations for hub concepts. " ++
        "Validate stale links periodically; reinforce validated memories and flush invalid short-term memories during consolidation.";

    var aw: Writer.Allocating = .init(allocator);
    defer aw.deinit();
    var s: Stringify = .{ .writer = &aw.writer };
    try s.beginObject();
    try s.objectField("jsonrpc");
    try s.write("2.0");
    try writeId(&s, reply.id);
    try s.objectField("result");
    try s.beginObject();
    try s.objectField("description");
    try s.write("Cog memory reference guidance");
    try s.objectField("messages");
    try s.beginArray();
    try s.beginObject();
    try s.objectField("role");
    try s.write("assistant");
    try s.objectField("content");
    try s.beginObject();
    try s.objectField("type");
    try s.write("text");
    try s.objectField("text");
    try s.write(prompt_text);
    try s.endObject();
    try s.endObject();
    try s.endArray();
    try s.endObject();
    try s.endObject();

    const result = try aw.toOwnedSlice();
    defer allocator.free(result);
    try reply.sendRaw(result);
}

fn handleResourcesList(allocator: std.mem.Allocator, reply: *ReplyOnce) !void {
    var aw: Writer.Allocating = .init(allocator);
    defer aw.deinit();
    var s: Stringify = .{ .writer = &aw.writer };

    try s.beginObject();
    try s.objectField("jsonrpc");
    try s.write("2.0");
    try writeId(&s, reply.id);
    try s.objectField("result");
    try s.beginObject();
    try s.objectField("resources");
    try s.beginArray();

    try s.beginObject();
    try s.objectField("uri");
    try s.write("cog://debug/tools");
    try s.objectField("name");
    try s.write("Debug Tool Catalog");
    try s.objectField("description");
    try s.write("All debug_* MCP tools exposed by Cog");
    try s.objectField("mimeType");
    try s.write("application/json");
    try s.endObject();

    try s.beginObject();
    try s.objectField("uri");
    try s.write("cog://tools/catalog");
    try s.objectField("name");
    try s.write("MCP Tool Catalog");
    try s.objectField("description");
    try s.write("All MCP tools currently exposed by this Cog runtime");
    try s.objectField("mimeType");
    try s.write("application/json");
    try s.endObject();

    try s.endArray();
    try s.endObject();
    try s.endObject();

    const result = try aw.toOwnedSlice();
    defer allocator.free(result);
    try reply.sendRaw(result);
}

fn handleResourcesRead(runtime: *Runtime, reply: *ReplyOnce, params: ?json.Value) !void {
    const allocator = runtime.allocator;

    // Protect code_cache and remote_tools access
    debug_log_mod.log("handleResourcesRead: acquiring runtime mutex", .{});
    runtime.mutex.lock();
    defer {
        runtime.mutex.unlock();
        debug_log_mod.log("handleResourcesRead: runtime mutex released", .{});
    }
    debug_log_mod.log("handleResourcesRead: runtime mutex acquired", .{});

    const p = params orelse {
        try reply.sendError(-32602, "Missing params");
        return;
    };
    if (p != .object) {
        try reply.sendError(-32602, "Invalid params");
        return;
    }

    const uri_val = p.object.get("uri") orelse {
        try reply.sendError(-32602, "Missing uri");
        return;
    };
    if (uri_val != .string) {
        try reply.sendError(-32602, "uri must be string");
        return;
    }

    const uri = uri_val.string;
    var payload: []const u8 = undefined;
    const mime: []const u8 = "application/json";

    if (std.mem.eql(u8, uri, "cog://debug/tools")) {
        payload = try buildDebugToolsResourceJson(allocator);
    } else if (std.mem.eql(u8, uri, "cog://tools/catalog")) {
        payload = try buildToolCatalogResourceJson(runtime);
    } else {
        try reply.sendError(-32602, "Unknown resource uri");
        return;
    }
    defer allocator.free(payload);

    var aw: Writer.Allocating = .init(allocator);
    defer aw.deinit();
    var s: Stringify = .{ .writer = &aw.writer };
    try s.beginObject();
    try s.objectField("jsonrpc");
    try s.write("2.0");
    try writeId(&s, reply.id);
    try s.objectField("result");
    try s.beginObject();
    try s.objectField("contents");
    try s.beginArray();
    try s.beginObject();
    try s.objectField("uri");
    try s.write(uri);
    try s.objectField("mimeType");
    try s.write(mime);
    try s.objectField("text");
    try s.write(payload);
    try s.endObject();
    try s.endArray();
    try s.endObject();
    try s.endObject();

    const result = try aw.toOwnedSlice();
    defer allocator.free(result);
    try reply.sendRaw(result);
}

fn buildDebugToolsResourceJson(allocator: std.mem.Allocator) ![]u8 {
    var aw: Writer.Allocating = .init(allocator);
    errdefer aw.deinit();
    var s: Stringify = .{ .writer = &aw.writer };
    try s.beginObject();
    try s.objectField("tools");
    try s.beginArray();
    for (debug_server_mod.tool_definitions) |tool| {
        try s.beginObject();
        try s.objectField("name");
        try s.write(tool.name);
        try s.objectField("description");
        try s.write(tool.description);
        try s.endObject();
    }
    try s.endArray();
    try s.endObject();
    return aw.toOwnedSlice();
}

fn buildToolCatalogResourceJson(runtime: *Runtime) ![]u8 {
    const allocator = runtime.allocator;
    var aw: Writer.Allocating = .init(allocator);
    errdefer aw.deinit();
    var s: Stringify = .{ .writer = &aw.writer };

    try s.beginObject();
    try s.objectField("memory_enabled");
    try s.write(runtime.hasMemory());
    try s.objectField("tools");
    try s.beginArray();
    try writeToolCatalog(runtime, allocator, &s);
    try s.endArray();
    try s.endObject();

    return aw.toOwnedSlice();
}

fn writeToolCatalog(runtime: *Runtime, allocator: std.mem.Allocator, s: *Stringify) !void {
    // All tools are advertised so that host-side sub-agents can discover
    // their schemas via tools/list. The primary agent prompt (PROMPT.md)
    // guides the agent to only use 5 direct memory tools; everything else
    // is accessed through sub-agents (code, debug, memory).

    try writeToolDefWithSchemaJson(allocator, s, "code_query", "Targeted code index query tool. ALWAYS use the 'queries' array to batch multiple queries into a single call — do NOT make sequential code_query calls when they can be combined. Modes: 'find', 'refs', 'symbols', 'imports', 'contains', 'calls', 'callers', 'overview'. Flat parameters (mode, name, file, etc.) are only for genuinely single queries.",
        \\{"type":"object","properties":{"queries":{"type":"array","description":"REQUIRED for multiple queries. Each entry specifies its own mode, name, file, kind, direction, and scope. Always combine sequential code_query calls into one batched call using this array.","items":{"type":"object","properties":{"mode":{"type":"string","description":"Query mode: 'find', 'refs', 'symbols', 'imports', 'contains', 'calls', 'callers', or 'overview'"},"name":{"type":"string","description":"Symbol name (supports glob: '*', '?', '|')"},"file":{"type":"string","description":"File path for file-scoped queries"},"kind":{"type":"string","description":"Filter by symbol kind"},"direction":{"type":"string","description":"'incoming', 'outgoing', or 'both'"},"scope":{"type":"string","description":"Overview scope: 'symbol', 'file', or 'repo'"}},"required":["mode"]}},"mode":{"type":"string","description":"Query mode (single-query only — use 'queries' array for multiple): 'find', 'refs', 'symbols', 'imports', 'contains', 'calls', 'callers', or 'overview'"},"name":{"type":"string","description":"Symbol name (supports glob: '*', '?', '|')"},"file":{"type":"string","description":"File path for file-scoped queries"},"kind":{"type":"string","description":"Filter by symbol kind"},"direction":{"type":"string","description":"'incoming', 'outgoing', or 'both'"},"scope":{"type":"string","description":"Overview scope: 'symbol', 'file', or 'repo'"}}}
    );

    try writeToolDefWithSchemaJson(allocator, s, "code_explore", "Primary code exploration tool. ALWAYS put all candidate symbols into the 'queries' array in a single call — do NOT make sequential code_explore calls when they can be combined. Returns readable plain-text summaries with definition bodies, per-file outlines, and optional architecture sections such as imports, containment, and overview data.",
        \\{"type":"object","properties":{"queries":{"type":"array","description":"REQUIRED. All symbol lookups MUST go into this single array. Do not split symbols across multiple code_explore calls.","items":{"type":"object","properties":{"name":{"type":"string","description":"Symbol name (supports glob: '*init*', 'get*')"},"kind":{"type":"string","description":"Filter by symbol kind (function, struct, method, variable, etc.)"}},"required":["name"]}},"context_lines":{"type":"number","description":"Fallback context lines for simple definitions without braces (default: 15)"},"include_relationships":{"type":"boolean","description":"Include symbol-level relationship summaries such as containment and imports when available"},"include_architecture":{"type":"boolean","description":"Include architecture-oriented summaries. Recommended for repository overview tasks."},"overview_scope":{"type":"string","description":"Architecture summary scope: 'symbol', 'file', or 'repo'"}},"required":["queries"]}
    );

    // Memory tools: local definitions or remote discovery
    if (runtime.hasMemory()) {
        if (runtime.isLocalBrain()) {
            // Emit hardcoded local tool definitions
            for (memory_mod.tool_definitions) |tool| {
                try writeToolDefWithSchemaJson(allocator, s, tool.name, tool.description, tool.input_schema);
            }
        } else {
            // Lazily discover remote memory tools on first tools/list
            if (runtime.remote_tools == null) {
                discoverRemoteTools(runtime) catch |err| {
                    debugLog("Remote tool discovery failed: {s}", .{@errorName(err)});
                };
            }
            if (runtime.remote_tools) |tools| {
                for (tools) |tool| {
                    try writeToolDefWithSchemaJson(allocator, s, tool.name, tool.description, tool.input_schema);
                }
            }
        }
    }

    for (debug_server_mod.tool_definitions) |tool| {
        if (tool.tier.isWithin(runtime.debug_tool_tier)) {
            try writeToolDefWithSchemaJson(allocator, s, tool.name, tool.description, tool.input_schema);
        }
    }

    // Log tools
    for (log_server_mod.tool_definitions) |tool| {
        try writeToolDefWithSchemaJson(allocator, s, tool.name, tool.description, tool.input_schema);
    }
}

fn runtimeCallTool(runtime: *Runtime, tool_name: []const u8, arguments: ?json.Value) ![]const u8 {
    // All non-debug tool paths access shared Runtime state.
    debug_log_mod.log("runtimeCallTool: acquiring mutex for {s}", .{tool_name});
    runtime.mutex.lock();
    debug_log_mod.log("runtimeCallTool: mutex acquired for {s}", .{tool_name});
    defer {
        runtime.mutex.unlock();
        debug_log_mod.log("runtimeCallTool: mutex released for {s}", .{tool_name});
    }

    const session_ctx = try runtime.ensureSessionContext();

    // Debug tools have their own mutex (DebugServer.mutex) — record context first.
    if (std.mem.startsWith(u8, tool_name, "debug_")) {
        const result = try callDebugTool(runtime, tool_name, arguments);
        try session_context_mod.recordToolEvent(session_ctx, tool_name, arguments);
        return result;
    }

    // Code tools
    if (std.mem.eql(u8, tool_name, "code_query")) {
        const result = try callCodeQuery(runtime, arguments);
        try session_context_mod.recordToolEvent(session_ctx, tool_name, arguments);
        return result;
    } else if (std.mem.eql(u8, tool_name, "code_explore")) {
        const result = try callCodeExplore(runtime, arguments);
        try session_context_mod.recordToolEvent(session_ctx, tool_name, arguments);
        return result;
    }

    // Log tools — own mutex (LogServer.mutex)
    if (std.mem.startsWith(u8, tool_name, "log_")) {
        const result = try callLogTool(runtime, tool_name, arguments);
        try session_context_mod.recordToolEvent(session_ctx, tool_name, arguments);
        return result;
    }

    // Memory tools — local SQLite or remote MCP server
    if (std.mem.startsWith(u8, tool_name, "mem_")) {
        if (runtime.isLocalBrain()) {
            const mem_db = runtime.ensureMemoryDb() catch {
                return runtime.allocator.dupe(u8, "Error: failed to open local memory database.");
            };
            const result = try memory_mod.callLocalTool(mem_db, tool_name, arguments);
            try session_context_mod.recordToolEvent(session_ctx, tool_name, arguments);
            return result;
        } else {
            const result = try callRemoteHostedTool(runtime, session_ctx, tool_name, arguments);
            try session_context_mod.recordToolEvent(session_ctx, tool_name, arguments);
            return result;
        }
    }

    return error.Explained;
}

// ── Remote MCP Proxy ────────────────────────────────────────────────────

/// Prefix a remote tool suffix with "mem_".
/// e.g. prefixToolName(alloc, "recall") → "mem_recall"
///      prefixToolName(alloc, "learn") → "mem_learn"
fn prefixToolName(allocator: std.mem.Allocator, suffix: []const u8) ![]const u8 {
    const prefix = "mem_";
    const buf = try allocator.alloc(u8, prefix.len + suffix.len);
    @memcpy(buf[0..prefix.len], prefix);
    @memcpy(buf[prefix.len..], suffix);
    return buf;
}

/// Rewrite cog_xxx tool name references in descriptions to mem_xxx format.
/// e.g. "use cog_reinforce to..." → "use mem_reinforce to..."
///      "use cog_learn with items" → "use mem_learn with items"
fn rewriteToolReferences(allocator: std.mem.Allocator, desc: []const u8) ![]const u8 {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    errdefer buf.deinit(allocator);

    const prefix = "cog_";
    const replacement_prefix = "mem_";
    var i: usize = 0;
    while (i < desc.len) {
        if (desc.len - i >= prefix.len and std.mem.eql(u8, desc[i..][0..prefix.len], prefix)) {
            // Find end of tool name token (alphanumeric + underscore)
            var end = i + prefix.len;
            while (end < desc.len and (std.ascii.isAlphanumeric(desc[end]) or desc[end] == '_')) : (end += 1) {}
            // Write mem_ + the suffix
            try buf.appendSlice(allocator, replacement_prefix);
            try buf.appendSlice(allocator, desc[i + prefix.len .. end]);
            i = end;
        } else {
            try buf.append(allocator, desc[i]);
            i += 1;
        }
    }

    return try buf.toOwnedSlice(allocator);
}

const BrainIdentity = struct {
    namespace: []const u8,
    name: []const u8,
};

fn parseBrainIdentity(brain_url: []const u8) ?BrainIdentity {
    const https_prefix = "https://";
    const http_prefix = "http://";
    const rest = if (std.mem.startsWith(u8, brain_url, https_prefix))
        brain_url[https_prefix.len..]
    else if (std.mem.startsWith(u8, brain_url, http_prefix))
        brain_url[http_prefix.len..]
    else
        return null;

    const first_slash = std.mem.indexOfScalar(u8, rest, '/') orelse return null;
    const path = rest[first_slash + 1 ..];
    const second_slash = std.mem.indexOfScalar(u8, path, '/') orelse return null;
    const namespace = path[0..second_slash];
    const name = path[second_slash + 1 ..];
    if (namespace.len == 0 or name.len == 0) return null;
    return .{ .namespace = namespace, .name = name };
}

fn resolveWorkspaceRoot(allocator: std.mem.Allocator, fallback_cwd: []const u8) ![]const u8 {
    const cog_dir = paths.findCogDir(allocator) catch return allocator.dupe(u8, fallback_cwd);
    defer allocator.free(cog_dir);
    const parent = std.fs.path.dirname(cog_dir) orelse return allocator.dupe(u8, fallback_cwd);
    return allocator.dupe(u8, parent);
}

fn detectHostAgentId(allocator: std.mem.Allocator, workspace_root: []const u8) ![]const u8 {
    const manifest_path = try std.fmt.allocPrint(allocator, "{s}/.cog/client-context.json", .{workspace_root});
    defer allocator.free(manifest_path);
    const file = std.fs.openFileAbsolute(manifest_path, .{}) catch return allocator.dupe(u8, "unknown");
    defer file.close();
    const content = file.readToEndAlloc(allocator, 64 * 1024) catch return allocator.dupe(u8, "unknown");
    defer allocator.free(content);

    const parsed = json.parseFromSlice(json.Value, allocator, content, .{}) catch return allocator.dupe(u8, "unknown");
    defer parsed.deinit();
    if (parsed.value != .object) return allocator.dupe(u8, "unknown");
    const agents_val = parsed.value.object.get("selected_agents") orelse return allocator.dupe(u8, "unknown");
    if (agents_val != .array or agents_val.array.items.len == 0) return allocator.dupe(u8, "unknown");
    if (agents_val.array.items.len == 1 and agents_val.array.items[0] == .string) {
        return allocator.dupe(u8, agents_val.array.items[0].string);
    }
    return allocator.dupe(u8, "multi-host");
}

fn discoverRemoteTools(runtime: *Runtime) !void {
    debug_log_mod.log("discoverRemoteTools: starting", .{});
    const allocator = runtime.allocator;
    const cfg = runtime.mem_config orelse return;

    // Build MCP endpoint URL: {brain_url}/mcp
    const endpoint = try std.fmt.allocPrint(allocator, "{s}/mcp", .{cfg.brain_url});
    defer allocator.free(endpoint);

    // Build JSON-RPC tools/list request
    const body = "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/list\"}";

    const response = try client.mcpCall(allocator, endpoint, cfg.api_key, runtime.mcp_session_id, body);
    defer allocator.free(response.body);

    // Update session ID
    if (response.session_id) |new_sid| {
        if (runtime.mcp_session_id) |old_sid| allocator.free(old_sid);
        runtime.mcp_session_id = new_sid;
    }

    // Parse response: {"jsonrpc":"2.0","id":1,"result":{"tools":[...]}}
    const parsed = json.parseFromSlice(json.Value, allocator, response.body, .{}) catch return error.InvalidResponse;
    defer parsed.deinit();

    const root = parsed.value;
    if (root != .object) return error.InvalidResponse;

    const result_val = root.object.get("result") orelse return error.InvalidResponse;
    if (result_val != .object) return error.InvalidResponse;

    const tools_val = result_val.object.get("tools") orelse return error.InvalidResponse;
    if (tools_val != .array) return error.InvalidResponse;

    const items = tools_val.array.items;
    if (runtime.remote_tools) |tools| {
        for (tools) |tool| {
            allocator.free(tool.name);
            allocator.free(tool.remote_name);
            allocator.free(tool.description);
            allocator.free(tool.input_schema);
        }
        allocator.free(tools);
        runtime.remote_tools = null;
    }
    runtime.remote_memory_capabilities.deinit(allocator);
    runtime.remote_memory_capabilities = .{};

    var tool_list: std.ArrayListUnmanaged(RemoteTool) = .empty;
    try tool_list.ensureTotalCapacity(allocator, @intCast(items.len));
    errdefer {
        for (tool_list.items) |tool| {
            allocator.free(tool.name);
            allocator.free(tool.remote_name);
            allocator.free(tool.description);
            allocator.free(tool.input_schema);
        }
        tool_list.deinit(allocator);
    }

    for (items) |item| {
        if (item != .object) continue;

        const name_val = item.object.get("name") orelse continue;
        if (name_val != .string) continue;
        const remote_name = name_val.string;

        // Only process cog_* tools
        const cog_prefix = "cog_";
        if (!std.mem.startsWith(u8, remote_name, cog_prefix)) continue;

        if (std.mem.eql(u8, remote_name, "cog_assert_record") or std.mem.eql(u8, remote_name, "cog_memory_record") or std.mem.eql(u8, remote_name, "cog_assert_history") or std.mem.eql(u8, remote_name, "cog_rationale_trace") or std.mem.eql(u8, remote_name, "cog_structured_recall")) continue;

        // Rename cog_xxx → mem_xxx
        const suffix = remote_name[cog_prefix.len..];
        const local_name = try prefixToolName(allocator, suffix);
        errdefer allocator.free(local_name);

        const remote_name_dup = try allocator.dupe(u8, remote_name);
        errdefer allocator.free(remote_name_dup);

        const desc_val = item.object.get("description");
        const desc = if (desc_val) |d| (if (d == .string) d.string else "") else "";
        const desc_dup = try rewriteToolReferences(allocator, desc);
        errdefer allocator.free(desc_dup);

        // Serialize inputSchema back to JSON string
        const schema_val = item.object.get("inputSchema");
        const schema_json = if (schema_val) |sv|
            try client.writeJsonValue(allocator, sv)
        else
            try allocator.dupe(u8, "{\"type\":\"object\",\"properties\":{}}");
        errdefer allocator.free(schema_json);

        try tool_list.append(allocator, .{
            .name = local_name,
            .remote_name = remote_name_dup,
            .description = desc_dup,
            .input_schema = schema_json,
        });
    }

    runtime.remote_tools = try tool_list.toOwnedSlice(allocator);
    debugLog("Discovered {d} remote memory tools", .{runtime.remote_tools.?.len});
    debug_log_mod.log("discoverRemoteTools: found {d} tools", .{runtime.remote_tools.?.len});
    debug_log_mod.log(
        "discoverRemoteTools: enhanced_write={s} provenance={any} rationale_trace={any}",
        .{
            if (runtime.remote_memory_capabilities.preferred_write_tool) |value| value else "none",
            runtime.remote_memory_capabilities.supports_provenance_envelopes,
            runtime.remote_memory_capabilities.supports_rationale_trace,
        },
    );
}

fn callRemoteHostedTool(runtime: *Runtime, session_ctx: *session_context_mod.SessionContext, tool_name: []const u8, arguments: ?json.Value) ![]const u8 {
    _ = session_ctx;
    return callRemoteMcpTool(runtime, tool_name, arguments);
}

fn callEnhancedRemoteHostedWrite(runtime: *Runtime, session_ctx: *session_context_mod.SessionContext, tool_name: []const u8, arguments: ?json.Value) ![]const u8 {
    const allocator = runtime.allocator;
    const cfg = runtime.mem_config orelse return error.NotConfigured;
    const endpoint = try std.fmt.allocPrint(allocator, "{s}/mcp", .{cfg.brain_url});
    defer allocator.free(endpoint);

    var write_context = try session_context_mod.buildWriteContext(allocator, session_ctx, tool_name, arguments);
    defer write_context.deinit(allocator);

    const response = try memory_envelope_mod.callEnhancedRemoteWrite(
        allocator,
        endpoint,
        cfg.api_key,
        runtime.mcp_session_id,
        &runtime.remote_memory_capabilities,
        trimMemPrefix(tool_name),
        arguments,
        session_ctx,
        &write_context,
    );
    defer allocator.free(response.body);
    updateRemoteSessionId(runtime, response.session_id);
    return parseRemoteToolTextResponse(allocator, response.body);
}

fn callRemoteMcpTool(runtime: *Runtime, tool_name: []const u8, arguments: ?json.Value) ![]const u8 {
    debug_log_mod.log("callRemoteMcpTool: {s}", .{tool_name});
    const allocator = runtime.allocator;
    const cfg = runtime.mem_config orelse return error.NotConfigured;

    if (runtime.remote_tools == null) {
        try discoverRemoteTools(runtime);
    }

    // Find the matching remote tool
    const tools = runtime.remote_tools orelse return error.NotConfigured;
    var remote_name: ?[]const u8 = null;
    for (tools) |tool| {
        if (std.mem.eql(u8, tool.name, tool_name)) {
            remote_name = tool.remote_name;
            break;
        }
    }
    const rname = remote_name orelse return error.Explained;

    // Build MCP endpoint URL
    const endpoint = try std.fmt.allocPrint(allocator, "{s}/mcp", .{cfg.brain_url});
    defer allocator.free(endpoint);

    const args_json = if (arguments) |args|
        try client.writeJsonValue(allocator, args)
    else
        try allocator.dupe(u8, "{}");
    defer allocator.free(args_json);

    const response = client.mcpCallTool(allocator, endpoint, cfg.api_key, runtime.mcp_session_id, rname, args_json) catch |err| {
        debugLog("MCP tool call failed for {s}: {s}", .{ tool_name, @errorName(err) });
        return error.Explained;
    };
    defer allocator.free(response.body);

    // Update session ID
    updateRemoteSessionId(runtime, response.session_id);
    return parseRemoteToolTextResponse(allocator, response.body);
}

fn updateRemoteSessionId(runtime: *Runtime, new_session_id: ?[]const u8) void {
    if (new_session_id) |new_sid| {
        if (runtime.mcp_session_id) |old_sid| runtime.allocator.free(old_sid);
        runtime.mcp_session_id = new_sid;
    }
}

fn parseRemoteToolTextResponse(allocator: std.mem.Allocator, body: []const u8) ![]const u8 {
    const parsed = json.parseFromSlice(json.Value, allocator, body, .{}) catch return error.Explained;
    defer parsed.deinit();

    const root = parsed.value;
    if (root != .object) return error.Explained;
    if (root.object.get("error")) |err_val| {
        if (err_val == .object) {
            if (err_val.object.get("message")) |msg| {
                if (msg == .string) return allocator.dupe(u8, msg.string);
            }
        }
        return error.Explained;
    }

    const result_val = root.object.get("result") orelse return error.Explained;
    if (result_val != .object) return error.Explained;
    const content_val = result_val.object.get("content") orelse return error.Explained;
    if (content_val != .array) return error.Explained;
    if (content_val.array.items.len == 0) return allocator.dupe(u8, "");
    const first = content_val.array.items[0];
    if (first != .object) return error.Explained;
    const text_val = first.object.get("text") orelse return error.Explained;
    if (text_val != .string) return error.Explained;
    return allocator.dupe(u8, text_val.string);
}

fn trimMemPrefix(tool_name: []const u8) []const u8 {
    return if (std.mem.startsWith(u8, tool_name, "mem_")) tool_name[4..] else tool_name;
}

// ── Code Tool Handlers ──────────────────────────────────────────────────

fn parseMode(mode_str: []const u8) ?code_intel.QueryMode {
    if (std.mem.eql(u8, mode_str, "find")) return .find;
    if (std.mem.eql(u8, mode_str, "refs")) return .refs;
    if (std.mem.eql(u8, mode_str, "symbols")) return .symbols;
    if (std.mem.eql(u8, mode_str, "imports")) return .imports;
    if (std.mem.eql(u8, mode_str, "contains")) return .contains;
    if (std.mem.eql(u8, mode_str, "calls")) return .calls;
    if (std.mem.eql(u8, mode_str, "callers")) return .callers;
    if (std.mem.eql(u8, mode_str, "overview")) return .overview;
    return null;
}

fn parseDirection(dir: []const u8) code_intel.QueryDirection {
    if (std.mem.eql(u8, dir, "incoming")) return .incoming;
    if (std.mem.eql(u8, dir, "both")) return .both;
    return .outgoing;
}

fn parseScope(scope_str: []const u8) code_intel.OverviewScope {
    if (std.mem.eql(u8, scope_str, "repo")) return .repo;
    if (std.mem.eql(u8, scope_str, "file")) return .file;
    return .symbol;
}

fn parseQueryParams(item: json.Value) ?code_intel.QueryParams {
    const mode_str = getStr(item, "mode") orelse return null;
    const mode = parseMode(mode_str) orelse return null;
    return .{
        .mode = mode,
        .name = getStr(item, "name"),
        .file = getStr(item, "file"),
        .kind = getStr(item, "kind"),
        .direction = if (getStr(item, "direction")) |dir| parseDirection(dir) else .outgoing,
        .scope = if (getStr(item, "scope")) |s| parseScope(s) else .symbol,
    };
}

fn callCodeQuery(runtime: *Runtime, arguments: ?json.Value) ![]const u8 {
    const allocator = runtime.allocator;
    const args = arguments orelse return error.Explained;

    if (runtime.code_cache == null and code_intel.queryIndexStatusForRuntime(allocator) != .ready) {
        return error.IndexUnavailable;
    }

    const ci = try runtime.ensureCodeCache();

    // Batch path: queries array
    const queries_val = if (args == .object) args.object.get("queries") else null;
    if (queries_val) |qv| {
        if (qv == .array) {
            var queries: std.ArrayListUnmanaged(code_intel.QueryParams) = .empty;
            defer queries.deinit(allocator);

            for (qv.array.items) |item| {
                if (parseQueryParams(item)) |params| {
                    try queries.append(allocator, params);
                }
            }

            debug_log_mod.log("callCodeQuery: batch mode, parsed {d} queries", .{queries.items.len});
            if (queries.items.len == 0) return error.Explained;

            return code_intel.codeQueryBatchWithLoadedIndex(allocator, ci, queries.items);
        }
    }

    // Single-query path: flat parameters
    const mode_str = getStr(args, "mode") orelse return error.Explained;
    debug_log_mod.log("callCodeQuery: mode={s}", .{mode_str});
    const mode = parseMode(mode_str) orelse return error.Explained;

    return code_intel.codeQueryWithLoadedIndex(allocator, ci, .{
        .mode = mode,
        .name = getStr(args, "name"),
        .file = getStr(args, "file"),
        .kind = getStr(args, "kind"),
        .direction = if (getStr(args, "direction")) |dir| parseDirection(dir) else .outgoing,
        .scope = if (getStr(args, "scope")) |s| parseScope(s) else .symbol,
    });
}

fn callCodeExplore(runtime: *Runtime, arguments: ?json.Value) ![]const u8 {
    const allocator = runtime.allocator;
    const args = arguments orelse return error.Explained;

    const options = code_intel.ExploreOptions{
        .context_lines = getInt(args, "context_lines") orelse 15,
        .include_relationships = getBool(args, "include_relationships") orelse false,
        .include_architecture = getBool(args, "include_architecture") orelse false,
        .overview_scope = blk: {
            const scope_str = getStr(args, "overview_scope") orelse break :blk .symbol;
            if (std.mem.eql(u8, scope_str, "repo")) break :blk .repo;
            if (std.mem.eql(u8, scope_str, "file")) break :blk .file;
            break :blk .symbol;
        },
    };
    debug_log_mod.log("callCodeExplore: context_lines={d} include_relationships={} include_architecture={} overview_scope={s}", .{ options.context_lines, options.include_relationships, options.include_architecture, @tagName(options.overview_scope) });

    // Parse queries array
    const queries_val = if (args == .object) args.object.get("queries") else null;
    const queries_arr = if (queries_val) |v| (if (v == .array) v.array.items else null) else null;
    if (queries_arr == null) return error.Explained;

    var queries: std.ArrayListUnmanaged(code_intel.ExploreQuery) = .empty;
    defer queries.deinit(allocator);

    for (queries_arr.?) |item| {
        const name = getStr(item, "name") orelse continue;
        try queries.append(allocator, .{
            .name = name,
            .kind = getStr(item, "kind"),
        });
    }

    debug_log_mod.log("callCodeExplore: parsed {d} queries", .{queries.items.len});

    if (queries.items.len == 0) return error.Explained;

    if (runtime.code_cache == null and code_intel.queryIndexStatusForRuntime(allocator) != .ready) {
        return error.IndexUnavailable;
    }

    const ci = try runtime.ensureCodeCache();
    return code_intel.codeExploreWithLoadedIndex(allocator, ci, queries.items, options);
}

// ── File Watcher Event Processing ───────────────────────────────────────

fn processWatcherEvents(runtime: *Runtime) void {
    const allocator = runtime.allocator;

    // Step 1: Drain all pending paths under the mutex.
    // The watcher pipe buffer is only safe to read while we hold the lock
    // (prevents a concurrent tool call from triggering a second drain).
    var paths_buf: std.ArrayListUnmanaged([]const u8) = .empty;
    defer {
        for (paths_buf.items) |p| allocator.free(p);
        paths_buf.deinit(allocator);
    }

    {
        debug_log_mod.log("processWatcherEvents: acquiring runtime mutex (drain)", .{});
        runtime.mutex.lock();
        defer {
            runtime.mutex.unlock();
            debug_log_mod.log("processWatcherEvents: runtime mutex released (drain)", .{});
        }
        debug_log_mod.log("processWatcherEvents: runtime mutex acquired (drain)", .{});

        var w = &runtime.watcher.?;
        while (w.drainOne()) |rel_path| {
            const duped = allocator.dupe(u8, rel_path) catch continue;
            paths_buf.append(allocator, duped) catch {
                allocator.free(duped);
                continue;
            };
        }
    }

    if (paths_buf.items.len == 0) return;
    debug_log_mod.log("processWatcherEvents: reindexing {d} files (no mutex held)", .{paths_buf.items.len});

    // Step 2: Reindex each file without holding the runtime mutex.
    // reindexFile/removeFileFromIndex use flock() for disk serialization,
    // so concurrent tool calls can proceed while we do the heavy I/O.
    var changed = false;
    for (paths_buf.items) |path_copy| {
        const exists = blk: {
            std.fs.cwd().access(path_copy, .{}) catch break :blk false;
            break :blk true;
        };
        if (exists) {
            if (code_intel.reindexFile(allocator, path_copy)) {
                debugLog("Watcher: reindexed {s}", .{path_copy});
                changed = true;
            }
        } else {
            if (code_intel.removeFileFromIndex(allocator, path_copy)) {
                debugLog("Watcher: removed {s}", .{path_copy});
                changed = true;
            }
        }
    }

    // Step 3: Re-acquire mutex only to swap the in-memory code cache.
    if (changed) {
        debug_log_mod.log("processWatcherEvents: acquiring runtime mutex (cache swap)", .{});
        runtime.mutex.lock();
        defer {
            runtime.mutex.unlock();
            debug_log_mod.log("processWatcherEvents: runtime mutex released (cache swap)", .{});
        }
        debug_log_mod.log("processWatcherEvents: runtime mutex acquired (cache swap)", .{});
        runtime.syncCodeCacheAfterWrite() catch {};
    }
}

fn callDebugTool(runtime: *Runtime, tool_name: []const u8, arguments: ?json.Value) ![]const u8 {
    debugLog("callDebugTool: dispatching {s}", .{tool_name});
    const allocator = runtime.allocator;
    const result = runtime.debug_server.callTool(allocator, tool_name, arguments) catch return error.Explained;
    debugLog("callDebugTool: {s} returned", .{tool_name});
    return switch (result) {
        .ok => |payload| payload,
        .ok_static => |payload| try allocator.dupe(u8, payload),
        .err => |e| try std.fmt.allocPrint(allocator, "Error {d}: {s}", .{ e.code, e.message }),
    };
}

fn callLogTool(runtime: *Runtime, tool_name: []const u8, arguments: ?json.Value) ![]const u8 {
    debug_log_mod.log("callLogTool: dispatching {s}", .{tool_name});
    const result = runtime.log_server.callTool(tool_name, arguments) catch |err| {
        return try std.fmt.allocPrint(runtime.allocator, "Error: log tool failed: {s}", .{@errorName(err)});
    };
    debug_log_mod.log("callLogTool: {s} returned", .{tool_name});
    return result;
}

// ── JSON Helpers ────────────────────────────────────────────────────────

fn getStr(obj: json.Value, key: []const u8) ?[]const u8 {
    if (obj != .object) return null;
    const val = obj.object.get(key) orelse return null;
    if (val != .string) return null;
    return val.string;
}

fn getInt(obj: json.Value, key: []const u8) ?usize {
    if (obj != .object) return null;
    const val = obj.object.get(key) orelse return null;
    if (val != .integer) return null;
    if (val.integer < 0) return null;
    return @intCast(val.integer);
}

fn getBool(obj: json.Value, key: []const u8) ?bool {
    if (obj != .object) return null;
    const val = obj.object.get(key) orelse return null;
    if (val != .bool) return null;
    return val.bool;
}

const ToolParam = struct {
    name: []const u8,
    typ: []const u8,
    desc: []const u8,
    required: bool,
};

fn writeToolDef(s: *Stringify, name: []const u8, description: []const u8, params: []const ToolParam) !void {
    try s.beginObject();
    try s.objectField("name");
    try s.write(name);
    try s.objectField("description");
    try s.write(description);
    try s.objectField("inputSchema");
    try s.beginObject();
    try s.objectField("type");
    try s.write("object");
    try s.objectField("properties");
    try s.beginObject();
    for (params) |p| {
        try s.objectField(p.name);
        try s.beginObject();
        try s.objectField("type");
        try s.write(p.typ);
        try s.objectField("description");
        try s.write(p.desc);
        try s.endObject();
    }
    try s.endObject();

    // Required array
    var has_required = false;
    for (params) |p| {
        if (p.required) {
            has_required = true;
            break;
        }
    }
    if (has_required) {
        try s.objectField("required");
        try s.beginArray();
        for (params) |p| {
            if (p.required) try s.write(p.name);
        }
        try s.endArray();
    }

    try s.objectField("additionalProperties");
    try s.write(false);
    try s.endObject();
    try s.endObject();
}

fn writeToolDefWithSchemaJson(allocator: std.mem.Allocator, s: *Stringify, name: []const u8, description: []const u8, schema_json: []const u8) !void {
    const parsed = json.parseFromSlice(json.Value, allocator, schema_json, .{}) catch {
        return writeToolDef(s, name, description, &.{});
    };
    defer parsed.deinit();

    try s.beginObject();
    try s.objectField("name");
    try s.write(name);
    try s.objectField("description");
    try s.write(description);
    try s.objectField("inputSchema");
    try s.write(parsed.value);
    try s.endObject();
}

fn writeId(s: *Stringify, id: ?json.Value) !void {
    try s.objectField("id");
    if (id) |v| {
        try s.write(v);
    } else {
        try s.write(null);
    }
}

fn writeToolResult(allocator: std.mem.Allocator, id: ?json.Value, content: []const u8, stdout: StdoutWriter) !void {
    var aw: Writer.Allocating = .init(allocator);
    defer aw.deinit();
    var s: Stringify = .{ .writer = &aw.writer };

    try s.beginObject();
    try s.objectField("jsonrpc");
    try s.write("2.0");
    try writeId(&s, id);
    try s.objectField("result");
    try s.beginObject();
    try s.objectField("content");
    try s.beginArray();
    try s.beginObject();
    try s.objectField("type");
    try s.write("text");
    try s.objectField("text");
    try s.write(content);
    try s.endObject();
    try s.endArray();
    try s.endObject();
    try s.endObject();

    const result = try aw.toOwnedSlice();
    defer allocator.free(result);
    try stdout.writeResponse(result);
}

fn writeToolError(allocator: std.mem.Allocator, id: ?json.Value, message: []const u8, stdout: StdoutWriter) !void {
    var aw: Writer.Allocating = .init(allocator);
    defer aw.deinit();
    var s: Stringify = .{ .writer = &aw.writer };

    try s.beginObject();
    try s.objectField("jsonrpc");
    try s.write("2.0");
    try writeId(&s, id);
    try s.objectField("result");
    try s.beginObject();
    try s.objectField("content");
    try s.beginArray();
    try s.beginObject();
    try s.objectField("type");
    try s.write("text");
    try s.objectField("text");
    try s.write(message);
    try s.endObject();
    try s.endArray();
    try s.objectField("isError");
    try s.write(true);
    try s.endObject();
    try s.endObject();

    const result = try aw.toOwnedSlice();
    defer allocator.free(result);
    try stdout.writeResponse(result);
}

fn writeError(allocator: std.mem.Allocator, id: ?json.Value, code: i32, message: []const u8, stdout: StdoutWriter) !void {
    var aw: Writer.Allocating = .init(allocator);
    defer aw.deinit();
    var s: Stringify = .{ .writer = &aw.writer };

    try s.beginObject();
    try s.objectField("jsonrpc");
    try s.write("2.0");
    try writeId(&s, id);
    try s.objectField("error");
    try s.beginObject();
    try s.objectField("code");
    try s.write(code);
    try s.objectField("message");
    try s.write(message);
    try s.endObject();
    try s.endObject();

    const result = try aw.toOwnedSlice();
    defer allocator.free(result);
    try stdout.writeResponse(result);
}

fn logErr(prefix: []const u8, err: anyerror) void {
    var errbuf: [4096]u8 = undefined;
    var w = std.fs.File.stderr().writerStreaming(&errbuf);
    w.interface.writeAll(prefix) catch {};
    w.interface.writeAll(@errorName(err)) catch {};
    w.interface.writeByte('\n') catch {};
    w.interface.flush() catch {};
}

// ── Debug File Logger ────────────────────────────────────────────────────

var debug_log_file: ?std.fs.File = null;

fn debugLogInit() void {
    debug_log_file = std.fs.cwd().createFile("/tmp/cog-mcp.log", .{ .truncate = false }) catch null;
    if (debug_log_file) |f| {
        f.seekFromEnd(0) catch {};
    }
    debugLog("=== MCP server starting (version {s}) ===", .{server_version});
}

fn debugLogDeinit() void {
    debugLog("=== MCP server shutting down ===", .{});
    if (debug_log_file) |f| f.close();
    debug_log_file = null;
}

fn debugLog(comptime fmt: []const u8, args: anytype) void {
    const f = debug_log_file orelse return;
    var buf: [4096]u8 = undefined;
    const ts = std.time.timestamp();
    const prefix = std.fmt.bufPrint(&buf, "[{d}] ", .{ts}) catch return;
    f.writeAll(prefix) catch return;
    var msg_buf: [8192]u8 = undefined;
    const msg = std.fmt.bufPrint(&msg_buf, fmt, args) catch return;
    f.writeAll(msg) catch return;
    f.writeAll("\n") catch return;
}

fn debugLogBytes(prefix: []const u8, data: []const u8) void {
    const f = debug_log_file orelse return;
    var buf: [128]u8 = undefined;
    const ts = std.time.timestamp();
    const ts_str = std.fmt.bufPrint(&buf, "[{d}] ", .{ts}) catch return;
    f.writeAll(ts_str) catch return;
    f.writeAll(prefix) catch return;
    const max_len: usize = 500;
    if (data.len <= max_len) {
        f.writeAll(data) catch return;
    } else {
        f.writeAll(data[0..max_len]) catch return;
        var trunc_buf: [64]u8 = undefined;
        const trunc_msg = std.fmt.bufPrint(&trunc_buf, "... ({d} bytes total)", .{data.len}) catch return;
        f.writeAll(trunc_msg) catch return;
    }
    f.writeAll("\n") catch return;
}

test "nextMessageFromBuffer extracts newline-delimited JSON" {
    const allocator = std.testing.allocator;
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(allocator);

    const body = "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"ping\"}";
    try buf.appendSlice(allocator, body ++ "\n");

    const msg = (try nextMessageFromBuffer(allocator, &buf)).?;
    defer allocator.free(msg);
    try std.testing.expectEqualStrings(body, msg);
    try std.testing.expectEqual(@as(usize, 0), buf.items.len);
}

test "nextMessageFromBuffer handles multiple messages" {
    const allocator = std.testing.allocator;
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(allocator);

    const msg1 = "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"ping\"}";
    const msg2 = "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"ping\"}";
    try buf.appendSlice(allocator, msg1 ++ "\n" ++ msg2 ++ "\n");

    const result1 = (try nextMessageFromBuffer(allocator, &buf)).?;
    defer allocator.free(result1);
    try std.testing.expectEqualStrings(msg1, result1);

    const result2 = (try nextMessageFromBuffer(allocator, &buf)).?;
    defer allocator.free(result2);
    try std.testing.expectEqualStrings(msg2, result2);

    try std.testing.expectEqual(@as(usize, 0), buf.items.len);
}

test "nextMessageFromBuffer skips leading whitespace" {
    const allocator = std.testing.allocator;
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(allocator);

    const body = "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"ping\"}";
    try buf.appendSlice(allocator, "\n\n  " ++ body ++ "\n");

    const msg = (try nextMessageFromBuffer(allocator, &buf)).?;
    defer allocator.free(msg);
    try std.testing.expectEqualStrings(body, msg);
}

test "nextMessageFromBuffer waits for newline" {
    const allocator = std.testing.allocator;
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(allocator);

    // Incomplete JSON line (no trailing newline) but a complete JSON object
    // should still be extractable via brace counting.
    const body = "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"ping\"}";
    try buf.appendSlice(allocator, body);

    const msg = (try nextMessageFromBuffer(allocator, &buf)).?;
    defer allocator.free(msg);
    try std.testing.expectEqualStrings(body, msg);
}

test "nextMessageFromBuffer returns null for incomplete JSON" {
    const allocator = std.testing.allocator;
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(allocator);

    const partial = "{\"jsonrpc\":\"2.0\",\"id\":1";
    try buf.appendSlice(allocator, partial);
    const msg = try nextMessageFromBuffer(allocator, &buf);
    try std.testing.expect(msg == null);
    try std.testing.expect(buf.items.len == partial.len);
}

fn testRuntime(allocator: std.mem.Allocator) Runtime {
    return .{
        .allocator = allocator,
        .mem_config = null,
        .brain_type = .none,
        .mem_db = null,
        .debug_server = DebugServer.init(allocator),
        .log_server = LogServer.init(allocator),
        .code_cache = null,
        .remote_tools = null,
        .mcp_session_id = null,
        .watcher = null,
        .debug_tool_tier = .specialist,
        .mutex = .{},
    };
}

test "runtimeCallTool rejects code queries when index is unavailable" {
    const allocator = std.testing.allocator;
    var original_cwd = std.fs.cwd().openDir(".", .{}) catch unreachable;
    defer {
        original_cwd.setAsCwd() catch unreachable;
        original_cwd.close();
    }

    var root_dir = try std.fs.openDirAbsolute("/", .{});
    defer root_dir.close();
    try root_dir.setAsCwd();

    var runtime = testRuntime(allocator);
    defer runtime.deinit();

    const parsed = try json.parseFromSlice(json.Value, allocator, "{\"mode\":\"find\",\"name\":\"main\"}", .{});
    defer parsed.deinit();

    try std.testing.expectError(error.IndexUnavailable, runtimeCallTool(&runtime, "code_query", parsed.value));
}
