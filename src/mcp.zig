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

const Config = config_mod.Config;
const DebugServer = debug_server_mod.DebugServer;

// ── MCP Server ──────────────────────────────────────────────────────────

var server_version: []const u8 = "0.0.0";
var shutdown_requested: std.atomic.Value(bool) = std.atomic.Value(bool).init(false);

const Runtime = struct {
    allocator: std.mem.Allocator,
    mem_config: ?Config,
    debug_server: DebugServer,
    code_cache: ?code_intel.CodeIndex = null,

    fn init(allocator: std.mem.Allocator) Runtime {
        return .{
            .allocator = allocator,
            .mem_config = Config.load(allocator) catch null,
            .debug_server = DebugServer.init(allocator),
            .code_cache = null,
        };
    }

    fn deinit(self: *Runtime) void {
        if (self.mem_config) |cfg| cfg.deinit(self.allocator);
        if (self.code_cache) |*ci| ci.deinit(self.allocator);
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
    setupSignalHandler();

    var runtime = Runtime.init(allocator);
    defer runtime.deinit();

    const stdin = std.fs.File.stdin();

    var input_buf: std.ArrayListUnmanaged(u8) = .empty;
    defer input_buf.deinit(allocator);

    var read_buf: [8192]u8 = undefined;

    while (!shutdown_requested.load(.acquire)) {
        if (builtin.os.tag != .windows) {
            var fds = [_]posix.pollfd{.{ .fd = stdin.handle, .events = posix.POLL.IN, .revents = 0 }};
            const poll_result = posix.poll(&fds, 250) catch continue;
            if (poll_result == 0) continue;
            if (fds[0].revents & (posix.POLL.HUP | posix.POLL.ERR) != 0) break;
            if (fds[0].revents & posix.POLL.IN == 0) continue;
        }

        const n = stdin.read(&read_buf) catch break;
        if (n == 0) break;
        if (std.mem.indexOfScalar(u8, read_buf[0..n], 0x03) != null) {
            shutdown_requested.store(true, .release);
            break;
        }
        try input_buf.appendSlice(allocator, read_buf[0..n]);

        while (try nextMessageFromBuffer(allocator, &input_buf)) |msg| {
            defer allocator.free(msg);
            processMessage(&runtime, msg) catch {};
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

fn parseContentLength(headers: []const u8) ?usize {
    var it = std.mem.splitSequence(u8, headers, "\r\n");
    while (it.next()) |line| {
        if (line.len == 0) continue;
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        const name = std.mem.trim(u8, line[0..colon], " \t");
        if (!std.ascii.eqlIgnoreCase(name, "Content-Length")) continue;
        const value = std.mem.trim(u8, line[colon + 1 ..], " \t");
        return std.fmt.parseInt(usize, value, 10) catch null;
    }
    return null;
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
    const bytes = input.items;

    if (std.mem.indexOf(u8, bytes, "\r\n\r\n")) |header_end| {
        const headers = bytes[0..header_end];
        const content_len = parseContentLength(headers) orelse return null;
        const body_start = header_end + 4;
        if (bytes.len < body_start + content_len) return null;
        const msg = try allocator.dupe(u8, bytes[body_start .. body_start + content_len]);
        try drainConsumed(allocator, input, body_start + content_len);
        return msg;
    }

    return null;
}

fn processMessage(runtime: *Runtime, line: []const u8) !void {
    const allocator = runtime.allocator;
    const stdout = std.fs.File.stdout();

    const parsed = json.parseFromSlice(json.Value, allocator, line, .{}) catch {
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

    // Get request id (may be null for notifications)
    const id = root.object.get("id");

    // Dispatch
    if (std.mem.eql(u8, method, "initialize")) {
        try handleInitialize(allocator, id, stdout);
    } else if (std.mem.eql(u8, method, "notifications/initialized")) {
        // No-op notification, no response needed
    } else if (std.mem.eql(u8, method, "shutdown")) {
        try handleShutdown(allocator, id, stdout);
    } else if (std.mem.eql(u8, method, "exit")) {
        shutdown_requested.store(true, .release);
    } else if (std.mem.eql(u8, method, "ping")) {
        try handlePing(allocator, id, stdout);
    } else if (std.mem.eql(u8, method, "tools/list")) {
        try handleToolsList(runtime, id, stdout);
    } else if (std.mem.eql(u8, method, "tools/call")) {
        const params = root.object.get("params");
        try handleToolsCall(runtime, id, params, stdout);
    } else if (std.mem.eql(u8, method, "resources/list")) {
        try handleResourcesList(allocator, id, stdout);
    } else if (std.mem.eql(u8, method, "resources/read")) {
        const params = root.object.get("params");
        try handleResourcesRead(runtime, id, params, stdout);
    } else if (std.mem.eql(u8, method, "prompts/list")) {
        try handlePromptsList(allocator, id, stdout);
    } else if (std.mem.eql(u8, method, "prompts/get")) {
        const params = root.object.get("params");
        try handlePromptsGet(allocator, id, params, stdout);
    } else if (std.mem.eql(u8, method, "notifications/cancelled") or std.mem.eql(u8, method, "notifications/progress")) {
        // Optional notifications; no-op.
    } else {
        if (id != null) {
            try writeError(allocator, id, -32601, "Method not found", stdout);
        }
    }
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
    try s.write("2024-11-05");
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
            error.SymbolNotFound => "Symbol not found",
            error.FileNotFound => "File not found in index",
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
        payload = try callCodeStatus(runtime);
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
    try writeToolDef(s, "cog_code_query", "Find symbol definitions, references, file symbols, or project structure", &.{
        .{ .name = "mode", .typ = "string", .desc = "Query mode: find, refs, symbols, or structure", .required = true },
        .{ .name = "name", .typ = "string", .desc = "Symbol name (for find/refs modes)", .required = false },
        .{ .name = "file", .typ = "string", .desc = "File path (for symbols mode)", .required = false },
        .{ .name = "kind", .typ = "string", .desc = "Filter by symbol kind", .required = false },
        .{ .name = "limit", .typ = "integer", .desc = "Max results to return", .required = false },
    });

    try writeToolDef(s, "cog_code_index", "Build or update the SCIP code index", &.{
        .{ .name = "patterns", .typ = "array", .desc = "Glob patterns to index (default: **/*)", .required = false },
    });

    try writeToolDef(s, "cog_code_edit", "Edit a file with string replacement and re-index", &.{
        .{ .name = "file", .typ = "string", .desc = "File path to edit", .required = true },
        .{ .name = "old_text", .typ = "string", .desc = "Text to find and replace", .required = true },
        .{ .name = "new_text", .typ = "string", .desc = "Replacement text", .required = true },
    });

    try writeToolDef(s, "cog_code_create", "Create a new file and index it", &.{
        .{ .name = "file", .typ = "string", .desc = "File path to create", .required = true },
        .{ .name = "content", .typ = "string", .desc = "File content", .required = false },
    });

    try writeToolDef(s, "cog_code_delete", "Delete a file and remove from index", &.{
        .{ .name = "file", .typ = "string", .desc = "File path to delete", .required = true },
    });

    try writeToolDef(s, "cog_code_rename", "Rename a file and update index", &.{
        .{ .name = "old_path", .typ = "string", .desc = "Current file path", .required = true },
        .{ .name = "new_path", .typ = "string", .desc = "New file path", .required = true },
    });

    try writeToolDef(s, "cog_code_status", "Report index status", &.{});

    if (runtime.hasMemory()) {
        try writeToolDef(s, "cog_mem_recall", "Search memory using spreading activation", &.{
            .{ .name = "query", .typ = "string", .desc = "What to search for", .required = true },
            .{ .name = "limit", .typ = "integer", .desc = "Max seed results (default: 5)", .required = false },
            .{ .name = "predicate_filter", .typ = "array", .desc = "Only include these predicate types", .required = false },
            .{ .name = "exclude_predicates", .typ = "array", .desc = "Exclude these predicate types", .required = false },
            .{ .name = "created_after", .typ = "string", .desc = "ISO 8601 date filter", .required = false },
            .{ .name = "created_before", .typ = "string", .desc = "ISO 8601 date filter", .required = false },
            .{ .name = "strengthen", .typ = "boolean", .desc = "Strengthen retrieved synapses (default: true)", .required = false },
        });

        try writeToolDef(s, "cog_mem_get", "Retrieve a specific engram by ID", &.{
            .{ .name = "engram_id", .typ = "string", .desc = "UUID of the engram", .required = true },
        });

        try writeToolDef(s, "cog_mem_update", "Update an existing engram", &.{
            .{ .name = "engram_id", .typ = "string", .desc = "UUID of the engram", .required = true },
            .{ .name = "term", .typ = "string", .desc = "New term", .required = false },
            .{ .name = "definition", .typ = "string", .desc = "New definition", .required = false },
        });

        try writeToolDef(s, "cog_mem_learn", "Store a new concept", &.{
            .{ .name = "term", .typ = "string", .desc = "Concise canonical name (2-5 words)", .required = true },
            .{ .name = "definition", .typ = "string", .desc = "Your understanding in 1-3 sentences", .required = true },
            .{ .name = "associations", .typ = "array", .desc = "Links to existing concepts", .required = false },
            .{ .name = "chain_to", .typ = "array", .desc = "Create a reasoning chain from this concept", .required = false },
            .{ .name = "long_term", .typ = "boolean", .desc = "Skip short-term phase", .required = false },
        });

        try writeToolDef(s, "cog_mem_associate", "Create a link between two concepts", &.{
            .{ .name = "source_term", .typ = "string", .desc = "Source concept term", .required = false },
            .{ .name = "target_term", .typ = "string", .desc = "Target concept term", .required = false },
            .{ .name = "source_id", .typ = "string", .desc = "Source engram UUID (alternative)", .required = false },
            .{ .name = "target_id", .typ = "string", .desc = "Target engram UUID (alternative)", .required = false },
            .{ .name = "predicate", .typ = "string", .desc = "Relationship type", .required = false },
        });

        try writeToolDef(s, "cog_mem_unlink", "Remove a synapse", &.{
            .{ .name = "synapse_id", .typ = "string", .desc = "UUID of the synapse", .required = true },
        });

        try writeToolDef(s, "cog_mem_verify", "Confirm synapse accuracy", &.{
            .{ .name = "synapse_id", .typ = "string", .desc = "UUID of the synapse", .required = true },
        });

        try writeToolDef(s, "cog_mem_trace", "Find reasoning path between concepts", &.{
            .{ .name = "from_id", .typ = "string", .desc = "UUID of starting concept", .required = true },
            .{ .name = "to_id", .typ = "string", .desc = "UUID of target concept", .required = true },
        });

        try writeToolDef(s, "cog_mem_connections", "List connections from an engram", &.{
            .{ .name = "engram_id", .typ = "string", .desc = "UUID of the engram", .required = true },
            .{ .name = "direction", .typ = "string", .desc = "outgoing, incoming, or both (default: both)", .required = false },
        });

        try writeToolDef(s, "cog_mem_refactor", "Update concept via term lookup", &.{
            .{ .name = "term", .typ = "string", .desc = "Term to find (semantically matched)", .required = true },
            .{ .name = "definition", .typ = "string", .desc = "New definition", .required = true },
        });

        try writeToolDef(s, "cog_mem_deprecate", "Mark a concept as obsolete", &.{
            .{ .name = "term", .typ = "string", .desc = "Term to deprecate (semantically matched)", .required = true },
        });

        try writeToolDef(s, "cog_mem_reinforce", "Consolidate short-term to long-term", &.{
            .{ .name = "engram_id", .typ = "string", .desc = "UUID of the short-term engram", .required = true },
        });

        try writeToolDef(s, "cog_mem_flush", "Delete a short-term memory", &.{
            .{ .name = "engram_id", .typ = "string", .desc = "UUID of the short-term engram", .required = true },
        });

        try writeToolDef(s, "cog_mem_meld", "Create cross-brain connection", &.{
            .{ .name = "target", .typ = "string", .desc = "Brain reference (brain_name, username/brain_name)", .required = true },
            .{ .name = "description", .typ = "string", .desc = "Gates when meld is traversed during recall", .required = false },
        });

        try writeToolDef(s, "cog_mem_bulk_learn", "Batch store concepts", &.{
            .{ .name = "items", .typ = "array", .desc = "Concepts to store (max 100)", .required = true },
            .{ .name = "memory_term", .typ = "string", .desc = "short or long (default: long)", .required = false },
        });

        try writeToolDef(s, "cog_mem_bulk_associate", "Batch link concepts", &.{
            .{ .name = "associations", .typ = "array", .desc = "Associations to create (max 100)", .required = true },
        });

        try writeToolDef(s, "cog_mem_bulk_recall", "Search with multiple queries", &.{
            .{ .name = "queries", .typ = "array", .desc = "Search queries (max 20)", .required = true },
            .{ .name = "limit", .typ = "integer", .desc = "Max seeds per query (default: 3)", .required = false },
        });

        try writeToolDef(s, "cog_mem_list_short_term", "List short-term memories pending consolidation", &.{
            .{ .name = "limit", .typ = "integer", .desc = "Max results (default: 20)", .required = false },
        });

        try writeToolDef(s, "cog_mem_stale", "List synapses approaching staleness", &.{
            .{ .name = "level", .typ = "string", .desc = "warning, critical, deprecated, or all", .required = false },
            .{ .name = "limit", .typ = "integer", .desc = "Max results (default: 20)", .required = false },
        });

        try writeToolDef(s, "cog_mem_stats", "Get brain statistics", &.{});

        try writeToolDef(s, "cog_mem_orphans", "List disconnected concepts", &.{
            .{ .name = "limit", .typ = "integer", .desc = "Max results (default: 50)", .required = false },
        });

        try writeToolDef(s, "cog_mem_connectivity", "Analyze graph connectivity", &.{});

        try writeToolDef(s, "cog_mem_list_terms", "List all engram terms", &.{
            .{ .name = "limit", .typ = "integer", .desc = "Max results (default: 500)", .required = false },
        });
    }

    for (debug_server_mod.tool_definitions) |tool| {
        try writeToolDefWithSchemaJson(allocator, s, tool.name, tool.description, tool.input_schema);
    }
}

fn runtimeCallTool(runtime: *Runtime, tool_name: []const u8, arguments: ?json.Value) ![]const u8 {
    // Code tools
    if (std.mem.eql(u8, tool_name, "cog_code_query")) {
        return callCodeQuery(runtime, arguments);
    } else if (std.mem.eql(u8, tool_name, "cog_code_index")) {
        return callCodeIndex(runtime, arguments);
    } else if (std.mem.eql(u8, tool_name, "cog_code_edit")) {
        return callCodeEdit(runtime, arguments);
    } else if (std.mem.eql(u8, tool_name, "cog_code_create")) {
        return callCodeCreate(runtime, arguments);
    } else if (std.mem.eql(u8, tool_name, "cog_code_delete")) {
        return callCodeDelete(runtime, arguments);
    } else if (std.mem.eql(u8, tool_name, "cog_code_rename")) {
        return callCodeRename(runtime, arguments);
    } else if (std.mem.eql(u8, tool_name, "cog_code_status")) {
        return callCodeStatus(runtime);
    } else if (std.mem.startsWith(u8, tool_name, "debug_")) {
        return callDebugTool(runtime, tool_name, arguments);
    }

    // Memory tools
    const mem_tools = .{
        .{ "cog_mem_recall", "recall" },
        .{ "cog_mem_get", "get" },
        .{ "cog_mem_learn", "learn" },
        .{ "cog_mem_associate", "associate" },
        .{ "cog_mem_update", "update" },
        .{ "cog_mem_unlink", "unlink" },
        .{ "cog_mem_refactor", "refactor" },
        .{ "cog_mem_deprecate", "deprecate" },
        .{ "cog_mem_reinforce", "reinforce" },
        .{ "cog_mem_flush", "flush" },
        .{ "cog_mem_verify", "verify" },
        .{ "cog_mem_meld", "meld" },
        .{ "cog_mem_trace", "trace" },
        .{ "cog_mem_connections", "connections" },
        .{ "cog_mem_bulk_learn", "bulk_learn" },
        .{ "cog_mem_bulk_associate", "bulk_associate" },
        .{ "cog_mem_bulk_recall", "bulk_recall" },
        .{ "cog_mem_list_short_term", "list_short_term" },
        .{ "cog_mem_stale", "stale" },
        .{ "cog_mem_stats", "stats" },
        .{ "cog_mem_orphans", "orphans" },
        .{ "cog_mem_connectivity", "connectivity" },
        .{ "cog_mem_list_terms", "list_terms" },
    };

    inline for (mem_tools) |entry| {
        if (std.mem.eql(u8, tool_name, entry[0])) {
            return callMemApi(runtime, entry[1], arguments);
        }
    }

    return error.Explained;
}

// ── Memory API Handler ──────────────────────────────────────────────────

fn callMemApi(runtime: *Runtime, action: []const u8, arguments: ?json.Value) ![]const u8 {
    const allocator = runtime.allocator;
    const cfg = runtime.mem_config orelse return error.NotConfigured;
    const args_json = if (arguments) |args|
        try client.writeJsonValue(allocator, args)
    else
        try allocator.dupe(u8, "{}");
    defer allocator.free(args_json);
    return client.call(allocator, cfg.url, cfg.api_key, action, args_json);
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
    else if (std.mem.eql(u8, mode_str, "structure"))
        .structure
    else
        return error.Explained;

    const ci = try runtime.ensureCodeCache();
    return code_intel.codeQueryWithLoadedIndex(allocator, ci, .{
        .mode = mode,
        .name = getStr(args, "name"),
        .file = getStr(args, "file"),
        .kind = getStr(args, "kind"),
        .limit = getInt(args, "limit"),
    });
}

fn callCodeIndex(runtime: *Runtime, arguments: ?json.Value) ![]const u8 {
    const allocator = runtime.allocator;
    // Extract patterns array if provided
    if (arguments) |args| {
        if (args.object.get("patterns")) |pats| {
            if (pats == .array) {
                var list: std.ArrayListUnmanaged([]const u8) = .empty;
                defer list.deinit(allocator);
                for (pats.array.items) |item| {
                    if (item == .string) {
                        try list.append(allocator, item.string);
                    }
                }
                if (list.items.len > 0) {
                    const res = try code_intel.codeIndexInner(allocator, list.items);
                    runtime.syncCodeCacheAfterWrite() catch {
                        allocator.free(res);
                        return error.Explained;
                    };
                    return res;
                }
            }
        }
    }
    const res = try code_intel.codeIndexInner(allocator, null);
    runtime.syncCodeCacheAfterWrite() catch {
        allocator.free(res);
        return error.Explained;
    };
    return res;
}

fn callCodeEdit(runtime: *Runtime, arguments: ?json.Value) ![]const u8 {
    const allocator = runtime.allocator;
    const args = arguments orelse return error.Explained;
    const file = getStr(args, "file") orelse return error.MissingFile;
    const old_text = getStr(args, "old_text") orelse return error.Explained;
    const new_text = getStr(args, "new_text") orelse return error.Explained;

    const before = readFileMaybe(allocator, file) orelse return error.Explained;
    defer allocator.free(before);

    const res = try code_intel.codeEditInner(allocator, file, old_text, new_text);
    errdefer allocator.free(res);

    const reindexed = jsonBoolField(allocator, res, "reindexed") orelse false;
    if (!reindexed) {
        _ = writeFileExact(file, before);
        _ = reindexPathsBestEffort(allocator, &.{file});
        return error.Explained;
    }

    runtime.syncCodeCacheAfterWrite() catch {
        _ = writeFileExact(file, before);
        _ = reindexPathsBestEffort(allocator, &.{file});
        allocator.free(res);
        return error.Explained;
    };
    return res;
}

fn callCodeCreate(runtime: *Runtime, arguments: ?json.Value) ![]const u8 {
    const allocator = runtime.allocator;
    const args = arguments orelse return error.Explained;
    const file = getStr(args, "file") orelse return error.MissingFile;
    const content = getStr(args, "content") orelse "";

    const existed_before = fileExists(file);
    const res = try code_intel.codeCreateInner(allocator, file, content);
    errdefer allocator.free(res);

    const reindexed = jsonBoolField(allocator, res, "reindexed") orelse false;
    if (!reindexed) {
        if (!existed_before) _ = deleteFileIfExists(file);
        _ = reindexPathsBestEffort(allocator, &.{file});
        return error.Explained;
    }

    runtime.syncCodeCacheAfterWrite() catch {
        if (!existed_before) _ = deleteFileIfExists(file);
        _ = reindexPathsBestEffort(allocator, &.{file});
        allocator.free(res);
        return error.Explained;
    };
    return res;
}

fn callCodeDelete(runtime: *Runtime, arguments: ?json.Value) ![]const u8 {
    const allocator = runtime.allocator;
    const args = arguments orelse return error.Explained;
    const file = getStr(args, "file") orelse return error.MissingFile;

    const before = readFileMaybe(allocator, file);
    defer if (before) |b| allocator.free(b);

    const res = try code_intel.codeDeleteInner(allocator, file);
    errdefer allocator.free(res);

    const updated = jsonBoolField(allocator, res, "index_updated") orelse false;
    if (!updated) {
        if (before) |b| {
            _ = writeFileExact(file, b);
            _ = reindexPathsBestEffort(allocator, &.{file});
        }
        return error.Explained;
    }

    runtime.syncCodeCacheAfterWrite() catch {
        if (before) |b| {
            _ = writeFileExact(file, b);
            _ = reindexPathsBestEffort(allocator, &.{file});
        }
        allocator.free(res);
        return error.Explained;
    };
    return res;
}

fn callCodeRename(runtime: *Runtime, arguments: ?json.Value) ![]const u8 {
    const allocator = runtime.allocator;
    const args = arguments orelse return error.Explained;
    const old_path = getStr(args, "old_path") orelse return error.Explained;
    const new_path = getStr(args, "new_path") orelse return error.Explained;

    const old_exists_before = fileExists(old_path);
    const new_exists_before = fileExists(new_path);

    const res = try code_intel.codeRenameInner(allocator, old_path, new_path);
    errdefer allocator.free(res);

    const reindexed = jsonBoolField(allocator, res, "reindexed") orelse false;
    if (!reindexed) {
        if (old_exists_before and !new_exists_before and fileExists(new_path)) {
            std.fs.cwd().rename(new_path, old_path) catch {};
            _ = reindexPathsBestEffort(allocator, &.{ old_path, new_path });
        }
        return error.Explained;
    }

    runtime.syncCodeCacheAfterWrite() catch {
        if (old_exists_before and !new_exists_before and fileExists(new_path)) {
            std.fs.cwd().rename(new_path, old_path) catch {};
            _ = reindexPathsBestEffort(allocator, &.{ old_path, new_path });
        }
        allocator.free(res);
        return error.Explained;
    };
    return res;
}

fn callCodeStatus(runtime: *Runtime) ![]const u8 {
    const allocator = runtime.allocator;
    if (runtime.code_cache) |*ci| {
        return code_intel.codeStatusFromLoadedIndex(allocator, ci);
    }
    return code_intel.codeStatusInner(allocator);
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

fn fileExists(path: []const u8) bool {
    std.fs.cwd().access(path, .{}) catch return false;
    return true;
}

fn readFileMaybe(allocator: std.mem.Allocator, path: []const u8) ?[]u8 {
    const file = std.fs.cwd().openFile(path, .{}) catch return null;
    defer file.close();
    return file.readToEndAlloc(allocator, 64 * 1024 * 1024) catch null;
}

fn writeFileExact(path: []const u8, data: []const u8) bool {
    if (std.fs.path.dirname(path)) |parent| {
        std.fs.cwd().makePath(parent) catch {};
    }
    const file = std.fs.cwd().createFile(path, .{}) catch return false;
    defer file.close();
    file.writeAll(data) catch return false;
    return true;
}

fn deleteFileIfExists(path: []const u8) bool {
    std.fs.cwd().deleteFile(path) catch |err| switch (err) {
        error.FileNotFound => return true,
        else => return false,
    };
    return true;
}

fn reindexPathsBestEffort(allocator: std.mem.Allocator, paths: []const []const u8) bool {
    const res = code_intel.codeIndexInner(allocator, paths) catch return false;
    allocator.free(res);
    return true;
}

fn jsonBoolField(allocator: std.mem.Allocator, payload: []const u8, field: []const u8) ?bool {
    const parsed = json.parseFromSlice(json.Value, allocator, payload, .{}) catch return null;
    defer parsed.deinit();
    if (parsed.value != .object) return null;
    const v = parsed.value.object.get(field) orelse return null;
    if (v != .bool) return null;
    return v.bool;
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
    var buf: [8192]u8 = undefined;
    var w = stdout.writer(&buf);
    var header: [128]u8 = undefined;
    const h = std.fmt.bufPrint(&header, "Content-Length: {d}\r\n\r\n", .{data.len}) catch return;
    w.interface.writeAll(h) catch return;
    w.interface.writeAll(data) catch return;
    w.interface.flush() catch return;
}

test "parseContentLength parses header value" {
    try std.testing.expectEqual(@as(?usize, 42), parseContentLength("Content-Length: 42\r\n"));
    try std.testing.expectEqual(@as(?usize, 9), parseContentLength("X-Test: 1\r\ncontent-length: 9\r\n"));
    try std.testing.expectEqual(@as(?usize, null), parseContentLength("X: 1\r\n"));
}

test "nextMessageFromBuffer extracts framed message" {
    const allocator = std.testing.allocator;
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(allocator);

    const body = "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"ping\"}";
    const frame = try std.fmt.allocPrint(allocator, "Content-Length: {d}\r\n\r\n{s}", .{ body.len, body });
    defer allocator.free(frame);
    try buf.appendSlice(allocator, frame);

    const msg = (try nextMessageFromBuffer(allocator, &buf)).?;
    defer allocator.free(msg);
    try std.testing.expectEqualStrings(body, msg);
    try std.testing.expectEqual(@as(usize, 0), buf.items.len);
}

test "nextMessageFromBuffer waits for complete body" {
    const allocator = std.testing.allocator;
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(allocator);

    const partial = "Content-Length: 20\r\n\r\n{\"jsonrpc\":\"2";
    try buf.appendSlice(allocator, partial);
    const msg = try nextMessageFromBuffer(allocator, &buf);
    try std.testing.expect(msg == null);
    try std.testing.expect(buf.items.len == partial.len);
}
