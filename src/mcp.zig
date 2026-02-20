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
const watcher_mod = @import("watcher.zig");
const paths = @import("paths.zig");

const Config = config_mod.Config;
const DebugServer = debug_server_mod.DebugServer;

// ── MCP Server ──────────────────────────────────────────────────────────

var server_version: []const u8 = "0.0.0";
var shutdown_requested: std.atomic.Value(bool) = std.atomic.Value(bool).init(false);

const RemoteTool = struct {
    name: []const u8, // local name: "cog_mem_recall"
    remote_name: []const u8, // server name: "cog_recall"
    description: []const u8,
    input_schema: []const u8, // raw JSON string
};

const Runtime = struct {
    allocator: std.mem.Allocator,
    mem_config: ?Config,
    debug_server: DebugServer,
    code_cache: ?code_intel.CodeIndex = null,
    remote_tools: ?[]RemoteTool = null,
    mcp_session_id: ?[]const u8 = null,
    watcher: ?watcher_mod.Watcher = null,

    fn init(allocator: std.mem.Allocator) Runtime {
        var rt = Runtime{
            .allocator = allocator,
            .mem_config = Config.load(allocator) catch null,
            .debug_server = DebugServer.init(allocator),
            .code_cache = null,
            .remote_tools = null,
            .mcp_session_id = null,
            .watcher = watcher_mod.Watcher.init(allocator),
        };
        if (rt.watcher != null) {
            rt.watcher.?.start();
            debugLog("File watcher started", .{});
        }
        return rt;
    }

    fn deinit(self: *Runtime) void {
        if (self.watcher) |*w| w.deinit();
        if (self.mem_config) |cfg| cfg.deinit(self.allocator);
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
        if (self.mcp_session_id) |sid| self.allocator.free(sid);
        self.debug_server.deinit();
    }

    fn hasMemory(self: *const Runtime) bool {
        return self.mem_config != null;
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
};

pub fn serve(allocator: std.mem.Allocator, version: []const u8) !void {
    server_version = version;
    shutdown_requested.store(false, .release);
    debugLogInit();
    defer debugLogDeinit();
    setupSignalHandler();

    var runtime = Runtime.init(allocator);
    defer runtime.deinit();
    debugLog("Runtime initialized, mem_config={s}, entering main loop", .{if (runtime.mem_config != null) "present" else "null"});

    const stdin = std.fs.File.stdin();

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
            defer allocator.free(msg);
            processMessage(&runtime, msg) catch |err| {
                logErr("MCP processMessage error: ", err);
            };
        }
    }
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

fn processMessage(runtime: *Runtime, line: []const u8) !void {
    const allocator = runtime.allocator;
    const stdout = std.fs.File.stdout();
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

    // Dispatch
    if (std.mem.eql(u8, method, "initialize")) {
        handleInitialize(allocator, id, stdout) catch {
            writeInternalError(allocator, id, stdout);
        };
    } else if (std.mem.eql(u8, method, "notifications/initialized")) {
        // No-op notification, no response needed
    } else if (std.mem.eql(u8, method, "shutdown")) {
        handleShutdown(allocator, id, stdout) catch {
            writeInternalError(allocator, id, stdout);
        };
    } else if (std.mem.eql(u8, method, "exit")) {
        shutdown_requested.store(true, .release);
    } else if (std.mem.eql(u8, method, "ping")) {
        handlePing(allocator, id, stdout) catch {
            writeInternalError(allocator, id, stdout);
        };
    } else if (std.mem.eql(u8, method, "tools/list")) {
        handleToolsList(runtime, id, stdout) catch {
            writeInternalError(allocator, id, stdout);
        };
    } else if (std.mem.eql(u8, method, "tools/call")) {
        const params = root.object.get("params");
        handleToolsCall(runtime, id, params, stdout) catch {
            writeInternalError(allocator, id, stdout);
        };
    } else if (std.mem.eql(u8, method, "resources/list")) {
        handleResourcesList(allocator, id, stdout) catch {
            writeInternalError(allocator, id, stdout);
        };
    } else if (std.mem.eql(u8, method, "resources/read")) {
        const params = root.object.get("params");
        handleResourcesRead(runtime, id, params, stdout) catch {
            writeInternalError(allocator, id, stdout);
        };
    } else if (std.mem.eql(u8, method, "prompts/list")) {
        handlePromptsList(allocator, id, stdout) catch {
            writeInternalError(allocator, id, stdout);
        };
    } else if (std.mem.eql(u8, method, "prompts/get")) {
        const params = root.object.get("params");
        handlePromptsGet(allocator, id, params, stdout) catch {
            writeInternalError(allocator, id, stdout);
        };
    } else if (std.mem.eql(u8, method, "notifications/cancelled") or std.mem.eql(u8, method, "notifications/progress")) {
        // Optional notifications; no-op.
    } else {
        if (id != null) {
            try writeError(allocator, id, -32601, "Method not found", stdout);
        }
    }
}

fn writeInternalError(allocator: std.mem.Allocator, id: ?json.Value, stdout: std.fs.File) void {
    if (id == null) return;
    writeError(allocator, id, -32603, "Internal error", stdout) catch {};
}

fn handleShutdown(allocator: std.mem.Allocator, id: ?json.Value, stdout: std.fs.File) !void {
    var aw: Writer.Allocating = .init(allocator);
    defer aw.deinit();
    var s: Stringify = .{ .writer = &aw.writer };
    try s.beginObject();
    try s.objectField("jsonrpc");
    try s.write("2.0");
    try writeId(&s, id);
    try s.objectField("result");
    try s.beginObject();
    try s.endObject();
    try s.endObject();
    const result = try aw.toOwnedSlice();
    defer allocator.free(result);
    try writeResponse(stdout, result);
    shutdown_requested.store(true, .release);
}

fn handlePing(allocator: std.mem.Allocator, id: ?json.Value, stdout: std.fs.File) !void {
    var aw: Writer.Allocating = .init(allocator);
    defer aw.deinit();
    var s: Stringify = .{ .writer = &aw.writer };
    try s.beginObject();
    try s.objectField("jsonrpc");
    try s.write("2.0");
    try writeId(&s, id);
    try s.objectField("result");
    try s.beginObject();
    try s.endObject();
    try s.endObject();
    const result = try aw.toOwnedSlice();
    defer allocator.free(result);
    try writeResponse(stdout, result);
}

fn handleInitialize(allocator: std.mem.Allocator, id: ?json.Value, stdout: std.fs.File) !void {
    var aw: Writer.Allocating = .init(allocator);
    defer aw.deinit();
    var s: Stringify = .{ .writer = &aw.writer };

    try s.beginObject();
    try s.objectField("jsonrpc");
    try s.write("2.0");
    try writeId(&s, id);
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
    try writeResponse(stdout, result);
}

fn handleToolsList(runtime: *Runtime, id: ?json.Value, stdout: std.fs.File) !void {
    const allocator = runtime.allocator;
    var aw: Writer.Allocating = .init(allocator);
    defer aw.deinit();
    var s: Stringify = .{ .writer = &aw.writer };

    try s.beginObject();
    try s.objectField("jsonrpc");
    try s.write("2.0");
    try writeId(&s, id);
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
    try writeResponse(stdout, result);
}

fn handleToolsCall(runtime: *Runtime, id: ?json.Value, params: ?json.Value, stdout: std.fs.File) !void {
    const allocator = runtime.allocator;
    const p = params orelse {
        try writeError(allocator, id, -32602, "Missing params", stdout);
        return;
    };
    if (p != .object) {
        try writeError(allocator, id, -32602, "Invalid params", stdout);
        return;
    }

    const name_val = p.object.get("name") orelse {
        try writeError(allocator, id, -32602, "Missing tool name", stdout);
        return;
    };
    if (name_val != .string) {
        try writeError(allocator, id, -32602, "Tool name must be string", stdout);
        return;
    }
    const tool_name = name_val.string;

    const arguments = if (p.object.get("arguments")) |a| (if (a == .object) a else null) else null;

    // Dispatch tool
    const tool_result = runtimeCallTool(runtime, tool_name, arguments) catch |err| {
        const err_msg = switch (err) {
            error.MissingName => "Missing required parameter: name",
            error.MissingFile => "Missing required parameter: file",
            error.NotConfigured => "Memory not configured. Run 'cog init' with memory enabled.",
            error.Explained => "Operation failed (see stderr)",
            else => "Internal error",
        };
        try writeToolError(allocator, id, err_msg, stdout);
        return;
    };
    defer allocator.free(tool_result);

    try writeToolResult(allocator, id, tool_result, stdout);
}

fn handlePromptsList(allocator: std.mem.Allocator, id: ?json.Value, stdout: std.fs.File) !void {
    var aw: Writer.Allocating = .init(allocator);
    defer aw.deinit();
    var s: Stringify = .{ .writer = &aw.writer };

    try s.beginObject();
    try s.objectField("jsonrpc");
    try s.write("2.0");
    try writeId(&s, id);
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
    try writeResponse(stdout, result);
}

fn handlePromptsGet(allocator: std.mem.Allocator, id: ?json.Value, params: ?json.Value, stdout: std.fs.File) !void {
    const p = params orelse {
        try writeError(allocator, id, -32602, "Missing params", stdout);
        return;
    };
    if (p != .object) {
        try writeError(allocator, id, -32602, "Invalid params", stdout);
        return;
    }
    const name_val = p.object.get("name") orelse {
        try writeError(allocator, id, -32602, "Missing prompt name", stdout);
        return;
    };
    if (name_val != .string) {
        try writeError(allocator, id, -32602, "Prompt name must be string", stdout);
        return;
    }

    if (!std.mem.eql(u8, name_val.string, "cog_reference")) {
        try writeError(allocator, id, -32602, "Unknown prompt", stdout);
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
    try writeId(&s, id);
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
    try writeResponse(stdout, result);
}

fn handleResourcesList(allocator: std.mem.Allocator, id: ?json.Value, stdout: std.fs.File) !void {
    var aw: Writer.Allocating = .init(allocator);
    defer aw.deinit();
    var s: Stringify = .{ .writer = &aw.writer };

    try s.beginObject();
    try s.objectField("jsonrpc");
    try s.write("2.0");
    try writeId(&s, id);
    try s.objectField("result");
    try s.beginObject();
    try s.objectField("resources");
    try s.beginArray();

    try s.beginObject();
    try s.objectField("uri");
    try s.write("cog://index/status");
    try s.objectField("name");
    try s.write("Code Index Status");
    try s.objectField("description");
    try s.write("Current code index status and symbol counts");
    try s.objectField("mimeType");
    try s.write("application/json");
    try s.endObject();

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
    try writeResponse(stdout, result);
}

fn handleResourcesRead(runtime: *Runtime, id: ?json.Value, params: ?json.Value, stdout: std.fs.File) !void {
    const allocator = runtime.allocator;
    const p = params orelse {
        try writeError(allocator, id, -32602, "Missing params", stdout);
        return;
    };
    if (p != .object) {
        try writeError(allocator, id, -32602, "Invalid params", stdout);
        return;
    }

    const uri_val = p.object.get("uri") orelse {
        try writeError(allocator, id, -32602, "Missing uri", stdout);
        return;
    };
    if (uri_val != .string) {
        try writeError(allocator, id, -32602, "uri must be string", stdout);
        return;
    }

    const uri = uri_val.string;
    var payload: []const u8 = undefined;
    const mime: []const u8 = "application/json";

    if (std.mem.eql(u8, uri, "cog://index/status")) {
        payload = callCodeStatus(runtime) catch try allocator.dupe(u8, "{\"exists\":false,\"error\":\"status_unavailable\"}");
    } else if (std.mem.eql(u8, uri, "cog://debug/tools")) {
        payload = try buildDebugToolsResourceJson(allocator);
    } else if (std.mem.eql(u8, uri, "cog://tools/catalog")) {
        payload = try buildToolCatalogResourceJson(runtime);
    } else {
        try writeError(allocator, id, -32602, "Unknown resource uri", stdout);
        return;
    }
    defer allocator.free(payload);

    var aw: Writer.Allocating = .init(allocator);
    defer aw.deinit();
    var s: Stringify = .{ .writer = &aw.writer };
    try s.beginObject();
    try s.objectField("jsonrpc");
    try s.write("2.0");
    try writeId(&s, id);
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
    try writeResponse(stdout, result);
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
    try writeToolDef(s, "cog_code_query", "Query the SCIP code index for symbol information. Use mode 'find' to locate where a symbol is defined, 'refs' to find all references to a symbol, or 'symbols' to list all symbols in a specific file.", &.{
        .{ .name = "mode", .typ = "string", .desc = "Query mode: 'find' (locate a symbol's definition), 'refs' (find all references to a symbol), 'symbols' (list all symbols in a file)", .required = true },
        .{ .name = "name", .typ = "string", .desc = "Symbol name to search for (required for find and refs modes). Supports glob patterns: '*' (zero or more chars) and '?' (one char). Examples: '*init*', 'get*', 'Handle?'", .required = false },
        .{ .name = "file", .typ = "string", .desc = "File path filter. Required for symbols mode. Optional for find/refs to scope results to a specific file.", .required = false },
        .{ .name = "kind", .typ = "string", .desc = "Filter results by symbol kind (e.g. function, class, method, variable)", .required = false },
    });

    try writeToolDef(s, "cog_code_status", "Check whether the SCIP code index exists, how many files are indexed, and which languages are covered. Use this to verify the index is available before querying.", &.{});

    try writeToolDefWithSchemaJson(allocator, s, "cog_code_explore",
        "Find multiple symbols by name and return full definition bodies with auto-discovered related symbols. Combines find + read in a single call. Auto-retries failed lookups with glob patterns, reads complete function/struct bodies (not fixed-line windows), and includes related project symbols referenced in the same files. Single call replaces multi-step find + read + follow-up loops.",
        \\{"type":"object","properties":{"queries":{"type":"array","description":"List of symbol queries. Each finds a symbol and returns source code around its definition.","items":{"type":"object","properties":{"name":{"type":"string","description":"Symbol name (supports glob: '*init*', 'get*')"},"kind":{"type":"string","description":"Filter by symbol kind (function, struct, method, variable, etc.)"}},"required":["name"]}},"context_lines":{"type":"number","description":"Fallback context lines for simple definitions without braces (default: 15)"}},"required":["queries"]}
    );

    // Lazily discover remote memory tools on first tools/list
    if (runtime.hasMemory() and runtime.remote_tools == null) {
        discoverRemoteTools(runtime) catch |err| {
            debugLog("Remote tool discovery failed: {s}", .{@errorName(err)});
        };
    }

    if (runtime.remote_tools) |tools| {
        for (tools) |tool| {
            try writeToolDefWithSchemaJson(allocator, s, tool.name, tool.description, tool.input_schema);
        }
    }

    for (debug_server_mod.tool_definitions) |tool| {
        try writeToolDefWithSchemaJson(allocator, s, tool.name, tool.description, tool.input_schema);
    }
}

fn runtimeCallTool(runtime: *Runtime, tool_name: []const u8, arguments: ?json.Value) ![]const u8 {
    // Code tools
    if (std.mem.eql(u8, tool_name, "cog_code_query")) {
        return callCodeQuery(runtime, arguments);
    } else if (std.mem.eql(u8, tool_name, "cog_code_status")) {
        return callCodeStatus(runtime);
    } else if (std.mem.eql(u8, tool_name, "cog_code_explore")) {
        return callCodeExplore(runtime, arguments);
    } else if (std.mem.startsWith(u8, tool_name, "cog_debug_")) {
        return callDebugTool(runtime, tool_name, arguments);
    }

    // Memory tools — proxy to remote MCP server
    if (std.mem.startsWith(u8, tool_name, "cog_mem_")) {
        return callRemoteMcpTool(runtime, tool_name, arguments);
    }

    return error.Explained;
}

// ── Remote MCP Proxy ────────────────────────────────────────────────────

/// Prefix a remote tool suffix with "cog_mem_".
/// e.g. prefixToolName(alloc, "recall") → "cog_mem_recall"
///      prefixToolName(alloc, "bulk_recall") → "cog_mem_bulk_recall"
fn prefixToolName(allocator: std.mem.Allocator, suffix: []const u8) ![]const u8 {
    const prefix = "cog_mem_";
    const buf = try allocator.alloc(u8, prefix.len + suffix.len);
    @memcpy(buf[0..prefix.len], prefix);
    @memcpy(buf[prefix.len..], suffix);
    return buf;
}

/// Rewrite cog_xxx tool name references in descriptions to cog_mem_xxx format.
/// e.g. "use cog_reinforce to..." → "use cog_mem_reinforce to..."
///      "multiple cog_bulk_recall calls" → "multiple cog_mem_bulk_recall calls"
fn rewriteToolReferences(allocator: std.mem.Allocator, desc: []const u8) ![]const u8 {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    errdefer buf.deinit(allocator);

    const prefix = "cog_";
    const replacement_prefix = "cog_mem_";
    var i: usize = 0;
    while (i < desc.len) {
        if (desc.len - i >= prefix.len and std.mem.eql(u8, desc[i..][0..prefix.len], prefix)) {
            // Find end of tool name token (alphanumeric + underscore)
            var end = i + prefix.len;
            while (end < desc.len and (std.ascii.isAlphanumeric(desc[end]) or desc[end] == '_')) : (end += 1) {}
            // Write cog_mem_ + the suffix
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

fn discoverRemoteTools(runtime: *Runtime) !void {
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

        // Rename cog_snake_case → cog:mem.camelCase
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
}

fn callRemoteMcpTool(runtime: *Runtime, tool_name: []const u8, arguments: ?json.Value) ![]const u8 {
    const allocator = runtime.allocator;
    const cfg = runtime.mem_config orelse return error.NotConfigured;

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

    // Build JSON-RPC tools/call request
    var aw: Writer.Allocating = .init(allocator);
    defer aw.deinit();
    var s: Stringify = .{ .writer = &aw.writer };

    try s.beginObject();
    try s.objectField("jsonrpc");
    try s.write("2.0");
    try s.objectField("id");
    try s.write(@as(i64, 1));
    try s.objectField("method");
    try s.write("tools/call");
    try s.objectField("params");
    try s.beginObject();
    try s.objectField("name");
    try s.write(rname);
    try s.objectField("arguments");
    if (arguments) |args| {
        try s.write(args);
    } else {
        try s.beginObject();
        try s.endObject();
    }
    try s.endObject();
    try s.endObject();

    const body = try aw.toOwnedSlice();
    defer allocator.free(body);

    const response = client.mcpCall(allocator, endpoint, cfg.api_key, runtime.mcp_session_id, body) catch |err| {
        debugLog("MCP tool call failed for {s}: {s}", .{ tool_name, @errorName(err) });
        return error.Explained;
    };
    defer allocator.free(response.body);

    // Update session ID
    if (response.session_id) |new_sid| {
        if (runtime.mcp_session_id) |old_sid| allocator.free(old_sid);
        runtime.mcp_session_id = new_sid;
    }

    // Parse response: {"jsonrpc":"2.0","id":1,"result":{"content":[{"type":"text","text":"..."}]}}
    const parsed = json.parseFromSlice(json.Value, allocator, response.body, .{}) catch {
        return error.Explained;
    };
    defer parsed.deinit();

    const root = parsed.value;
    if (root != .object) return error.Explained;

    // Check for MCP error
    if (root.object.get("error")) |err_val| {
        if (err_val == .object) {
            if (err_val.object.get("message")) |msg| {
                if (msg == .string) {
                    return allocator.dupe(u8, msg.string);
                }
            }
        }
        return error.Explained;
    }

    const result_val = root.object.get("result") orelse return error.Explained;
    if (result_val != .object) return error.Explained;

    const content_val = result_val.object.get("content") orelse return error.Explained;
    if (content_val != .array) return error.Explained;

    // Extract text from first content item
    if (content_val.array.items.len == 0) return allocator.dupe(u8, "");
    const first = content_val.array.items[0];
    if (first != .object) return error.Explained;

    const text_val = first.object.get("text") orelse return error.Explained;
    if (text_val != .string) return error.Explained;

    return allocator.dupe(u8, text_val.string);
}

// ── Code Tool Handlers ──────────────────────────────────────────────────

fn callCodeQuery(runtime: *Runtime, arguments: ?json.Value) ![]const u8 {
    const allocator = runtime.allocator;
    const args = arguments orelse return error.Explained;

    const mode_str = getStr(args, "mode") orelse return error.Explained;
    const mode: code_intel.QueryMode = if (std.mem.eql(u8, mode_str, "find"))
        .find
    else if (std.mem.eql(u8, mode_str, "refs"))
        .refs
    else if (std.mem.eql(u8, mode_str, "symbols"))
        .symbols
    else
        return error.Explained;

    const ci = try runtime.ensureCodeCache();
    return code_intel.codeQueryWithLoadedIndex(allocator, ci, .{
        .mode = mode,
        .name = getStr(args, "name"),
        .file = getStr(args, "file"),
        .kind = getStr(args, "kind"),
    });
}

fn callCodeStatus(runtime: *Runtime) ![]const u8 {
    const allocator = runtime.allocator;
    if (runtime.code_cache) |*ci| {
        return code_intel.codeStatusFromLoadedIndex(allocator, ci);
    }
    return code_intel.codeStatusInner(allocator);
}

fn callCodeExplore(runtime: *Runtime, arguments: ?json.Value) ![]const u8 {
    const allocator = runtime.allocator;
    const args = arguments orelse return error.Explained;

    // Parse context_lines (default 15)
    const context_lines: usize = getInt(args, "context_lines") orelse 15;

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

    if (queries.items.len == 0) return error.Explained;

    const ci = try runtime.ensureCodeCache();
    return code_intel.codeExploreWithLoadedIndex(allocator, ci, queries.items, context_lines);
}

// ── File Watcher Event Processing ───────────────────────────────────────

fn processWatcherEvents(runtime: *Runtime) void {
    var w = &runtime.watcher.?;
    var changed = false;
    while (w.drainOne()) |rel_path| {
        // Dupe the path since drainOne's slice is only valid until next call
        const path_copy = runtime.allocator.dupe(u8, rel_path) catch continue;
        defer runtime.allocator.free(path_copy);

        const exists = blk: {
            std.fs.cwd().access(path_copy, .{}) catch break :blk false;
            break :blk true;
        };
        if (exists) {
            if (code_intel.reindexFile(runtime.allocator, path_copy)) {
                debugLog("Watcher: reindexed {s}", .{path_copy});
                changed = true;
            }
        } else {
            if (code_intel.removeFileFromIndex(runtime.allocator, path_copy)) {
                debugLog("Watcher: removed {s}", .{path_copy});
                changed = true;
            }
        }
    }
    if (changed) {
        runtime.syncCodeCacheAfterWrite() catch {};
    }
}

fn callDebugTool(runtime: *Runtime, tool_name: []const u8, arguments: ?json.Value) ![]const u8 {
    const allocator = runtime.allocator;
    const result = runtime.debug_server.callTool(allocator, tool_name, arguments) catch return error.Explained;
    return switch (result) {
        .ok => |payload| payload,
        .ok_static => |payload| try allocator.dupe(u8, payload),
        .err => |e| {
            var aw: Writer.Allocating = .init(allocator);
            errdefer aw.deinit();
            var s: Stringify = .{ .writer = &aw.writer };
            try s.beginObject();
            try s.objectField("code");
            try s.write(e.code);
            try s.objectField("message");
            try s.write(e.message);
            try s.endObject();
            return aw.toOwnedSlice();
        },
    };
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

fn writeToolResult(allocator: std.mem.Allocator, id: ?json.Value, content: []const u8, stdout: std.fs.File) !void {
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
    try writeResponse(stdout, result);
}

fn writeToolError(allocator: std.mem.Allocator, id: ?json.Value, message: []const u8, stdout: std.fs.File) !void {
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
    try writeResponse(stdout, result);
}

fn writeError(allocator: std.mem.Allocator, id: ?json.Value, code: i32, message: []const u8, stdout: std.fs.File) !void {
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
    try writeResponse(stdout, result);
}

fn writeResponse(stdout: std.fs.File, data: []const u8) !void {
    debugLogBytes("<<< SEND: ", data);
    // MCP stdio transport: write bare JSON followed by newline.
    var buf: [8192]u8 = undefined;
    var w = stdout.writerStreaming(&buf);
    w.interface.writeAll(data) catch return error.WriteFailure;
    w.interface.writeAll("\n") catch return error.WriteFailure;
    w.interface.flush() catch return error.WriteFailure;
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
