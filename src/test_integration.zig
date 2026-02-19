const std = @import("std");
const json = std.json;
const Writer = std.io.Writer;

// ── Constants & Config ─────────────────────────────────────────────────

const OPENROUTER_URL = "https://openrouter.ai/api/v1/chat/completions";
const DEFAULT_MODEL = "anthropic/claude-sonnet-4";
const REACT_REPO_URL = "https://github.com/facebook/react.git";
const REACT_TAG = "v19.0.0";
const REACT_DIR = "bench/react";
const COG_BINARY = "zig-out/bin/cog";
const TARGET_FILE = "packages/react/src/ReactHooks.js";
const RENAMED_FILE = "packages/react/src/ReactHooksRenamed.js";
const CREATED_FILE = "packages/react/src/IntegrationTestHelper.js";

// ANSI
const cyan = "\x1B[36m";
const bold = "\x1B[1m";
const dim = "\x1B[2m";
const reset = "\x1B[0m";

// ── Types ──────────────────────────────────────────────────────────────

const StepResult = struct {
    passed: bool,
    elapsed_ms: i64 = 0,
    detail: []const u8 = "",
};

const StepKind = enum { llm, direct };

const TestStep = struct {
    name: []const u8,
    kind: StepKind,
    phase: u8,
};

// ── Message Types (shared with bench_query) ────────────────────────────

const MessageEntry = struct {
    role: []const u8,
    content: ?[]const u8 = null,
    tool_calls: ?[]const ToolCallEntry = null,
    tool_call_id: ?[]const u8 = null,
};

const ToolCallEntry = struct {
    id: []const u8,
    function_name: []const u8,
    arguments: []const u8,
};

const ParsedResponse = struct {
    content: ?[]const u8,
    tool_calls: []ParsedToolCall,
    finish_reason: []const u8,
    prompt_tokens: i64,
    completion_tokens: i64,
    total_tokens: i64,
};

const ParsedToolCall = struct {
    id: []const u8,
    function_name: []const u8,
    arguments: []const u8,
};

// ── Tool Definitions (5 tools for the LLM) ─────────────────────────────

const integration_tools_json =
    \\[{
    \\  "type": "function",
    \\  "function": {
    \\    "name": "cog_query",
    \\    "description": "Query a pre-built SCIP code index. Supports modes: --find <name> to locate symbol definitions, --refs <name> to find references, --symbols <file> to list symbols in a file. Returns JSON with paths and line numbers.",
    \\    "parameters": {
    \\      "type": "object",
    \\      "properties": {
    \\        "mode": {
    \\          "type": "string",
    \\          "enum": ["--find", "--refs", "--symbols"],
    \\          "description": "Query mode"
    \\        },
    \\        "query": {
    \\          "type": "string",
    \\          "description": "Symbol name for --find/--refs, or file path for --symbols"
    \\        }
    \\      },
    \\      "required": ["mode", "query"]
    \\    }
    \\  }
    \\},{
    \\  "type": "function",
    \\  "function": {
    \\    "name": "cog_edit",
    \\    "description": "Edit a file by replacing exact text. The old_text must be unique in the file. After editing, the code index is automatically updated.",
    \\    "parameters": {
    \\      "type": "object",
    \\      "properties": {
    \\        "file": {
    \\          "type": "string",
    \\          "description": "File path relative to repo root"
    \\        },
    \\        "old_text": {
    \\          "type": "string",
    \\          "description": "Exact text to find and replace (must be unique in file)"
    \\        },
    \\        "new_text": {
    \\          "type": "string",
    \\          "description": "Replacement text"
    \\        }
    \\      },
    \\      "required": ["file", "old_text", "new_text"]
    \\    }
    \\  }
    \\},{
    \\  "type": "function",
    \\  "function": {
    \\    "name": "cog_rename",
    \\    "description": "Rename a file and update the code index.",
    \\    "parameters": {
    \\      "type": "object",
    \\      "properties": {
    \\        "old_path": {
    \\          "type": "string",
    \\          "description": "Current file path relative to repo root"
    \\        },
    \\        "new_path": {
    \\          "type": "string",
    \\          "description": "New file path relative to repo root"
    \\        }
    \\      },
    \\      "required": ["old_path", "new_path"]
    \\    }
    \\  }
    \\},{
    \\  "type": "function",
    \\  "function": {
    \\    "name": "cog_delete",
    \\    "description": "Delete a file and remove it from the code index.",
    \\    "parameters": {
    \\      "type": "object",
    \\      "properties": {
    \\        "file": {
    \\          "type": "string",
    \\          "description": "File path relative to repo root to delete"
    \\        }
    \\      },
    \\      "required": ["file"]
    \\    }
    \\  }
    \\},{
    \\  "type": "function",
    \\  "function": {
    \\    "name": "cog_create",
    \\    "description": "Create a new file with the given content and add it to the code index.",
    \\    "parameters": {
    \\      "type": "object",
    \\      "properties": {
    \\        "file": {
    \\          "type": "string",
    \\          "description": "File path relative to repo root"
    \\        },
    \\        "content": {
    \\          "type": "string",
    \\          "description": "File content to write"
    \\        }
    \\      },
    \\      "required": ["file", "content"]
    \\    }
    \\  }
    \\}]
;

// ── JSON Construction (from bench_query.zig) ───────────────────────────

fn buildRequestBody(
    allocator: std.mem.Allocator,
    model: []const u8,
    messages: []const MessageEntry,
    tools_json: []const u8,
) ![]const u8 {
    var aw: Writer.Allocating = .init(allocator);
    errdefer aw.deinit();
    const w = &aw.writer;

    try w.writeAll("{\"model\":\"");
    try writeJsonEscaped(w, model);
    try w.writeAll("\",\"temperature\":0,\"tools\":");
    try w.writeAll(tools_json);
    try w.writeAll(",\"messages\":[");

    for (messages, 0..) |msg, i| {
        if (i > 0) try w.writeByte(',');
        try writeMessage(w, msg);
    }

    try w.writeAll("]}");
    return aw.toOwnedSlice();
}

fn writeMessage(w: anytype, msg: MessageEntry) !void {
    try w.writeAll("{\"role\":\"");
    try writeJsonEscaped(w, msg.role);
    try w.writeByte('"');

    if (msg.content) |content| {
        try w.writeAll(",\"content\":\"");
        try writeJsonEscaped(w, content);
        try w.writeByte('"');
    }

    if (msg.tool_call_id) |id| {
        try w.writeAll(",\"tool_call_id\":\"");
        try writeJsonEscaped(w, id);
        try w.writeByte('"');
    }

    if (msg.tool_calls) |calls| {
        try w.writeAll(",\"tool_calls\":[");
        for (calls, 0..) |tc, i| {
            if (i > 0) try w.writeByte(',');
            try w.writeAll("{\"id\":\"");
            try writeJsonEscaped(w, tc.id);
            try w.writeAll("\",\"type\":\"function\",\"function\":{\"name\":\"");
            try writeJsonEscaped(w, tc.function_name);
            try w.writeAll("\",\"arguments\":\"");
            try writeJsonEscaped(w, tc.arguments);
            try w.writeAll("\"}}");
        }
        try w.writeByte(']');
    }

    try w.writeByte('}');
}

fn writeJsonEscaped(w: anytype, s: []const u8) !void {
    for (s) |c| {
        switch (c) {
            '"' => try w.writeAll("\\\""),
            '\\' => try w.writeAll("\\\\"),
            '\n' => try w.writeAll("\\n"),
            '\r' => try w.writeAll("\\r"),
            '\t' => try w.writeAll("\\t"),
            else => {
                if (c < 0x20) {
                    var buf: [6]u8 = undefined;
                    const esc = std.fmt.bufPrint(&buf, "\\u{x:0>4}", .{c}) catch continue;
                    try w.writeAll(esc);
                } else {
                    try w.writeByte(c);
                }
            },
        }
    }
}

// ── JSON Parsing (from bench_query.zig) ────────────────────────────────

fn parseOpenRouterResponse(allocator: std.mem.Allocator, body: []const u8) !ParsedResponse {
    const parsed = json.parseFromSlice(json.Value, allocator, body, .{}) catch {
        return error.InvalidResponse;
    };
    defer parsed.deinit();

    const root = parsed.value;
    if (root != .object) return error.InvalidResponse;

    if (root.object.get("error")) |err_val| {
        if (err_val == .object) {
            if (err_val.object.get("message")) |msg| {
                if (msg == .string) {
                    printErr("  OpenRouter error: ");
                    printErr(msg.string);
                    printErr("\n");
                }
            }
        }
        return error.InvalidResponse;
    }

    const choices = root.object.get("choices") orelse return error.InvalidResponse;
    if (choices != .array or choices.array.items.len == 0) return error.InvalidResponse;

    const choice = choices.array.items[0];
    if (choice != .object) return error.InvalidResponse;

    const finish_reason_val = choice.object.get("finish_reason") orelse return error.InvalidResponse;
    const finish_reason = if (finish_reason_val == .string) finish_reason_val.string else "unknown";

    const message = choice.object.get("message") orelse return error.InvalidResponse;
    if (message != .object) return error.InvalidResponse;

    var content: ?[]const u8 = null;
    if (message.object.get("content")) |c| {
        if (c == .string and c.string.len > 0) {
            content = try allocator.dupe(u8, c.string);
        }
    }

    var tool_calls_list: std.ArrayListUnmanaged(ParsedToolCall) = .empty;
    if (message.object.get("tool_calls")) |tc_val| {
        if (tc_val == .array) {
            for (tc_val.array.items) |tc| {
                if (tc != .object) continue;
                const id_val = tc.object.get("id") orelse continue;
                const func = tc.object.get("function") orelse continue;
                if (func != .object) continue;
                const name_val = func.object.get("name") orelse continue;
                const args_val = func.object.get("arguments") orelse continue;

                try tool_calls_list.append(allocator, .{
                    .id = try allocator.dupe(u8, if (id_val == .string) id_val.string else ""),
                    .function_name = try allocator.dupe(u8, if (name_val == .string) name_val.string else ""),
                    .arguments = try allocator.dupe(u8, if (args_val == .string) args_val.string else ""),
                });
            }
        }
    }

    var prompt_tokens: i64 = 0;
    var completion_tokens: i64 = 0;
    var total_tokens: i64 = 0;
    if (root.object.get("usage")) |usage| {
        if (usage == .object) {
            if (usage.object.get("prompt_tokens")) |v| {
                if (v == .integer) prompt_tokens = v.integer;
            }
            if (usage.object.get("completion_tokens")) |v| {
                if (v == .integer) completion_tokens = v.integer;
            }
            if (usage.object.get("total_tokens")) |v| {
                if (v == .integer) total_tokens = v.integer;
            }
        }
    }

    return .{
        .content = content,
        .tool_calls = try tool_calls_list.toOwnedSlice(allocator),
        .finish_reason = try allocator.dupe(u8, finish_reason),
        .prompt_tokens = prompt_tokens,
        .completion_tokens = completion_tokens,
        .total_tokens = total_tokens,
    };
}

// ── HTTP Client (from bench_query.zig) ─────────────────────────────────

fn openrouterPost(allocator: std.mem.Allocator, api_key: []const u8, body: []const u8) ![]const u8 {
    const curl_mod = @import("curl").libcurl;
    const auth_header = try std.fmt.allocPrint(allocator, "Authorization: Bearer {s}", .{api_key});
    defer allocator.free(auth_header);

    const handle = curl_mod.curl_easy_init() orelse {
        printErr("  error: failed to init curl\n");
        return error.HttpError;
    };
    defer curl_mod.curl_easy_cleanup(handle);

    const url_z: [*:0]const u8 = OPENROUTER_URL;
    _ = curl_mod.curl_easy_setopt(handle, curl_mod.CURLOPT_URL, url_z);
    _ = curl_mod.curl_easy_setopt(handle, curl_mod.CURLOPT_POST, @as(c_long, 1));
    _ = curl_mod.curl_easy_setopt(handle, curl_mod.CURLOPT_POSTFIELDSIZE, @as(c_long, @intCast(body.len)));
    _ = curl_mod.curl_easy_setopt(handle, curl_mod.CURLOPT_POSTFIELDS, body.ptr);
    _ = curl_mod.curl_easy_setopt(handle, curl_mod.CURLOPT_ACCEPT_ENCODING, @as([*:0]const u8, ""));

    const auth_z = try allocator.dupeZ(u8, auth_header);
    defer allocator.free(auth_z);
    var header_list: ?*curl_mod.struct_curl_slist = null;
    header_list = curl_mod.curl_slist_append(header_list, auth_z.ptr);
    header_list = curl_mod.curl_slist_append(header_list, "Content-Type: application/json");
    header_list = curl_mod.curl_slist_append(header_list, "Accept: application/json");
    defer if (header_list) |hl| curl_mod.curl_slist_free_all(hl);
    _ = curl_mod.curl_easy_setopt(handle, curl_mod.CURLOPT_HTTPHEADER, header_list);

    const WriteData = struct { list: std.ArrayListUnmanaged(u8), alloc: std.mem.Allocator, err: bool };
    var write_data = WriteData{ .list = .empty, .alloc = allocator, .err = false };
    const write_cb = struct {
        fn cb(ptr: [*]const u8, size: usize, nmemb: usize, userdata: *anyopaque) callconv(.c) usize {
            const d: *WriteData = @ptrCast(@alignCast(userdata));
            const total = size * nmemb;
            d.list.appendSlice(d.alloc, ptr[0..total]) catch { d.err = true; return 0; };
            return total;
        }
    }.cb;
    _ = curl_mod.curl_easy_setopt(handle, curl_mod.CURLOPT_WRITEFUNCTION, write_cb);
    _ = curl_mod.curl_easy_setopt(handle, curl_mod.CURLOPT_WRITEDATA, @as(*anyopaque, @ptrCast(&write_data)));

    const res = curl_mod.curl_easy_perform(handle);
    if (res != curl_mod.CURLE_OK) {
        write_data.list.deinit(allocator);
        printErr("  error: failed to connect to OpenRouter\n");
        return error.HttpError;
    }

    var status_code: c_long = 0;
    _ = curl_mod.curl_easy_getinfo(handle, curl_mod.CURLINFO_RESPONSE_CODE, &status_code);

    if (status_code != 200) {
        const resp_body = write_data.list.toOwnedSlice(allocator) catch { write_data.list.deinit(allocator); return error.HttpError; };
        defer allocator.free(resp_body);
        var msg_buf: [128]u8 = undefined;
        const msg = std.fmt.bufPrint(&msg_buf, "  error: HTTP status {d}\n", .{status_code}) catch "  error: HTTP error\n";
        printErr(msg);
        if (json.parseFromSlice(json.Value, allocator, resp_body, .{})) |p| {
            defer p.deinit();
            if (p.value == .object) {
                if (p.value.object.get("error")) |ev| {
                    if (ev == .object) {
                        if (ev.object.get("message")) |mv| {
                            if (mv == .string) {
                                printErr("  ");
                                printErr(mv.string);
                                printErr("\n");
                            }
                        }
                    }
                }
            }
        } else |_| {}
        return error.HttpError;
    }

    return write_data.list.toOwnedSlice(allocator);
}

// ── Tool Execution ─────────────────────────────────────────────────────

fn getCogPath(allocator: std.mem.Allocator) ![]const u8 {
    const cwd = try std.fs.cwd().realpathAlloc(allocator, ".");
    defer allocator.free(cwd);
    return std.fmt.allocPrint(allocator, "{s}/{s}", .{ cwd, COG_BINARY });
}

fn runCogCommand(allocator: std.mem.Allocator, argv: []const []const u8) ![]const u8 {
    const result = std.process.Child.run(.{
        .allocator = allocator,
        .argv = argv,
        .cwd = REACT_DIR,
        .max_output_bytes = 64 * 1024,
    }) catch |err| {
        return try std.fmt.allocPrint(allocator, "error: failed to run cog: {s}", .{@errorName(err)});
    };
    defer allocator.free(result.stderr);

    if (result.stdout.len == 0) {
        defer allocator.free(result.stdout);
        if (result.stderr.len > 0) {
            return try allocator.dupe(u8, result.stderr);
        }
        return try allocator.dupe(u8, "No results found.");
    }

    if (result.stdout.len > 8192) {
        const truncated = try allocator.alloc(u8, 8192 + 20);
        @memcpy(truncated[0..8192], result.stdout[0..8192]);
        @memcpy(truncated[8192..][0..20], "\n... (truncated) ...");
        allocator.free(result.stdout);
        return truncated;
    }

    return result.stdout;
}

fn executeCogQuery(allocator: std.mem.Allocator, args_json: []const u8) ![]const u8 {
    const parsed = json.parseFromSlice(json.Value, allocator, args_json, .{}) catch {
        return try allocator.dupe(u8, "error: invalid arguments JSON");
    };
    defer parsed.deinit();

    if (parsed.value != .object)
        return try allocator.dupe(u8, "error: arguments must be an object");

    const mode_val = parsed.value.object.get("mode") orelse
        return try allocator.dupe(u8, "error: missing 'mode' parameter");
    const query_val = parsed.value.object.get("query") orelse
        return try allocator.dupe(u8, "error: missing 'query' parameter");

    const mode = if (mode_val == .string) mode_val.string else return try allocator.dupe(u8, "error: mode must be a string");
    const query = if (query_val == .string) query_val.string else return try allocator.dupe(u8, "error: query must be a string");

    const cog_path = try getCogPath(allocator);
    defer allocator.free(cog_path);

    return runCogCommand(allocator, &.{ cog_path, "code:query", mode, query });
}

fn executeCogEdit(allocator: std.mem.Allocator, args_json: []const u8) ![]const u8 {
    const parsed = json.parseFromSlice(json.Value, allocator, args_json, .{}) catch {
        return try allocator.dupe(u8, "error: invalid arguments JSON");
    };
    defer parsed.deinit();

    if (parsed.value != .object)
        return try allocator.dupe(u8, "error: arguments must be an object");

    const file_val = parsed.value.object.get("file") orelse
        return try allocator.dupe(u8, "error: missing 'file' parameter");
    const old_val = parsed.value.object.get("old_text") orelse
        return try allocator.dupe(u8, "error: missing 'old_text' parameter");
    const new_val = parsed.value.object.get("new_text") orelse
        return try allocator.dupe(u8, "error: missing 'new_text' parameter");

    const file = if (file_val == .string) file_val.string else return try allocator.dupe(u8, "error: file must be a string");
    const old_text = if (old_val == .string) old_val.string else return try allocator.dupe(u8, "error: old_text must be a string");
    const new_text = if (new_val == .string) new_val.string else return try allocator.dupe(u8, "error: new_text must be a string");

    const cog_path = try getCogPath(allocator);
    defer allocator.free(cog_path);

    return runCogCommand(allocator, &.{ cog_path, "code:edit", file, "--old", old_text, "--new", new_text });
}

fn executeCogRename(allocator: std.mem.Allocator, args_json: []const u8) ![]const u8 {
    const parsed = json.parseFromSlice(json.Value, allocator, args_json, .{}) catch {
        return try allocator.dupe(u8, "error: invalid arguments JSON");
    };
    defer parsed.deinit();

    if (parsed.value != .object)
        return try allocator.dupe(u8, "error: arguments must be an object");

    const old_val = parsed.value.object.get("old_path") orelse
        return try allocator.dupe(u8, "error: missing 'old_path' parameter");
    const new_val = parsed.value.object.get("new_path") orelse
        return try allocator.dupe(u8, "error: missing 'new_path' parameter");

    const old_path = if (old_val == .string) old_val.string else return try allocator.dupe(u8, "error: old_path must be a string");
    const new_path = if (new_val == .string) new_val.string else return try allocator.dupe(u8, "error: new_path must be a string");

    const cog_path = try getCogPath(allocator);
    defer allocator.free(cog_path);

    return runCogCommand(allocator, &.{ cog_path, "code:rename", old_path, "--to", new_path });
}

fn executeCogDelete(allocator: std.mem.Allocator, args_json: []const u8) ![]const u8 {
    const parsed = json.parseFromSlice(json.Value, allocator, args_json, .{}) catch {
        return try allocator.dupe(u8, "error: invalid arguments JSON");
    };
    defer parsed.deinit();

    if (parsed.value != .object)
        return try allocator.dupe(u8, "error: arguments must be an object");

    const file_val = parsed.value.object.get("file") orelse
        return try allocator.dupe(u8, "error: missing 'file' parameter");

    const file = if (file_val == .string) file_val.string else return try allocator.dupe(u8, "error: file must be a string");

    const cog_path = try getCogPath(allocator);
    defer allocator.free(cog_path);

    return runCogCommand(allocator, &.{ cog_path, "code:delete", file });
}

fn executeCogCreate(allocator: std.mem.Allocator, args_json: []const u8) ![]const u8 {
    const parsed = json.parseFromSlice(json.Value, allocator, args_json, .{}) catch {
        return try allocator.dupe(u8, "error: invalid arguments JSON");
    };
    defer parsed.deinit();

    if (parsed.value != .object)
        return try allocator.dupe(u8, "error: arguments must be an object");

    const file_val = parsed.value.object.get("file") orelse
        return try allocator.dupe(u8, "error: missing 'file' parameter");
    const content_val = parsed.value.object.get("content") orelse
        return try allocator.dupe(u8, "error: missing 'content' parameter");

    const file = if (file_val == .string) file_val.string else return try allocator.dupe(u8, "error: file must be a string");
    const content = if (content_val == .string) content_val.string else return try allocator.dupe(u8, "error: content must be a string");

    const cog_path = try getCogPath(allocator);
    defer allocator.free(cog_path);

    return runCogCommand(allocator, &.{ cog_path, "code:create", file, "--content", content });
}

fn executeToolCall(allocator: std.mem.Allocator, name: []const u8, arguments: []const u8) ![]const u8 {
    if (std.mem.eql(u8, name, "cog_query")) {
        return executeCogQuery(allocator, arguments);
    } else if (std.mem.eql(u8, name, "cog_edit")) {
        return executeCogEdit(allocator, arguments);
    } else if (std.mem.eql(u8, name, "cog_rename")) {
        return executeCogRename(allocator, arguments);
    } else if (std.mem.eql(u8, name, "cog_delete")) {
        return executeCogDelete(allocator, arguments);
    } else if (std.mem.eql(u8, name, "cog_create")) {
        return executeCogCreate(allocator, arguments);
    } else {
        return try std.fmt.allocPrint(allocator, "error: unknown tool '{s}'", .{name});
    }
}

// ── Agent Loop (single-turn: get first tool call and return) ───────────

const AgentResult = struct {
    tool_name: []const u8,
    tool_output: []const u8,
    elapsed_ms: i64,
};

fn runSingleTurnAgent(
    allocator: std.mem.Allocator,
    api_key: []const u8,
    model: []const u8,
    prompt: []const u8,
) !AgentResult {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const system_prompt = "You are a code intelligence tool operator. Use exactly the tool specified in the instruction. Do not explain — just call the tool. The codebase is React v19.0.0.";

    const messages: []const MessageEntry = &.{
        .{ .role = "system", .content = system_prompt },
        .{ .role = "user", .content = prompt },
    };

    const start_time = std.time.milliTimestamp();

    const body = try buildRequestBody(a, model, messages, integration_tools_json);
    const response_body = try openrouterPost(a, api_key, body);
    const resp = try parseOpenRouterResponse(a, response_body);

    if (resp.tool_calls.len == 0) {
        return .{
            .tool_name = try allocator.dupe(u8, "none"),
            .tool_output = try allocator.dupe(u8, resp.content orelse "no response"),
            .elapsed_ms = std.time.milliTimestamp() - start_time,
        };
    }

    const tc = resp.tool_calls[0];
    const tool_output = try executeToolCall(a, tc.function_name, tc.arguments);

    const elapsed = std.time.milliTimestamp() - start_time;

    return .{
        .tool_name = try allocator.dupe(u8, tc.function_name),
        .tool_output = try allocator.dupe(u8, tool_output),
        .elapsed_ms = elapsed,
    };
}

// ── Direct Verification Helpers ────────────────────────────────────────

fn directCogQuery(allocator: std.mem.Allocator, mode: []const u8, query: []const u8) ![]const u8 {
    const cog_path = try getCogPath(allocator);
    defer allocator.free(cog_path);

    return runCogCommand(allocator, &.{ cog_path, "code:query", mode, query });
}

fn verifySymbolExists(allocator: std.mem.Allocator, name: []const u8) !bool {
    const output = try directCogQuery(allocator, "--find", name);
    defer allocator.free(output);
    // If the result contains a file path (has a slash), the symbol was found
    return std.mem.indexOf(u8, output, "/") != null;
}

fn verifyFileInIndex(allocator: std.mem.Allocator, path: []const u8) !bool {
    const output = try directCogQuery(allocator, "--symbols", path);
    defer allocator.free(output);
    // If output does NOT contain "error" or "No results", the file is indexed
    if (std.mem.indexOf(u8, output, "error") != null) return false;
    if (std.mem.indexOf(u8, output, "No results") != null) return false;
    if (std.mem.indexOf(u8, output, "not found") != null) return false;
    return output.len > 0;
}

fn verifySymbolInFile(allocator: std.mem.Allocator, path: []const u8, name: []const u8) !bool {
    const output = try directCogQuery(allocator, "--symbols", path);
    defer allocator.free(output);
    return std.mem.indexOf(u8, output, name) != null;
}

fn outputContains(output: []const u8, needle: []const u8) bool {
    return std.mem.indexOf(u8, output, needle) != null;
}

// ── Setup & Cleanup ────────────────────────────────────────────────────

fn ensureReactRepo(allocator: std.mem.Allocator) !void {
    std.fs.cwd().access(REACT_DIR ++ "/package.json", .{}) catch {
        printErr("  Cloning React " ++ REACT_TAG ++ " (shallow)...\n");

        const argv: []const []const u8 = &.{
            "git", "clone", "--depth", "1", "--branch", REACT_TAG,
            "--progress", REACT_REPO_URL, REACT_DIR,
        };
        var child = std.process.Child.init(argv, allocator);
        child.spawn() catch {
            printErr("  error: failed to clone React repo\n");
            return error.SetupFailed;
        };
        const term = child.wait() catch {
            printErr("  error: failed to wait for git clone\n");
            return error.SetupFailed;
        };

        switch (term) {
            .Exited => |code| if (code != 0) {
                printErr("  error: git clone failed\n");
                return error.SetupFailed;
            },
            else => {
                printErr("  error: git clone failed\n");
                return error.SetupFailed;
            },
        }

        return;
    };
}

fn buildCogIndex(allocator: std.mem.Allocator, pattern: ?[]const u8) !void {
    const cog_path = try getCogPath(allocator);
    defer allocator.free(cog_path);

    const argv: []const []const u8 = if (pattern) |p|
        &.{ cog_path, "code:index", p }
    else
        &.{ cog_path, "code:index" };
    var child = std.process.Child.init(argv, allocator);
    child.cwd = REACT_DIR;
    child.spawn() catch {
        printErr("  error: failed to run cog code:index\n");
        return error.SetupFailed;
    };
    const term = child.wait() catch {
        printErr("  error: failed to wait for cog code/index\n");
        return error.SetupFailed;
    };

    switch (term) {
        .Exited => |code| if (code != 0) {
            printErr("  error: cog code/index failed\n");
            return error.SetupFailed;
        },
        else => {
            printErr("  error: cog code/index failed\n");
            return error.SetupFailed;
        },
    }
}

fn gitResetReactRepo(allocator: std.mem.Allocator) void {
    // git checkout -- .
    const checkout_result = std.process.Child.run(.{
        .allocator = allocator,
        .argv = &.{ "git", "checkout", "--", "." },
        .cwd = REACT_DIR,
        .max_output_bytes = 4096,
    }) catch return;
    allocator.free(checkout_result.stdout);
    allocator.free(checkout_result.stderr);

    // git clean -fd
    const clean_result = std.process.Child.run(.{
        .allocator = allocator,
        .argv = &.{ "git", "clean", "-fd" },
        .cwd = REACT_DIR,
        .max_output_bytes = 4096,
    }) catch return;
    allocator.free(clean_result.stdout);
    allocator.free(clean_result.stderr);
}

// ── Output Helpers (from bench_query.zig) ──────────────────────────────

fn printErr(msg: []const u8) void {
    var buf: [4096]u8 = undefined;
    var w = std.fs.File.stderr().writer(&buf);
    w.interface.writeAll(msg) catch {};
    w.interface.flush() catch {};
}

fn printFmtErr(comptime fmt: []const u8, args: anytype) void {
    var buf: [256]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, fmt, args) catch return;
    printErr(s);
}

fn printPad(n: usize) void {
    const spaces = "                                                                ";
    var remaining = n;
    while (remaining > 0) {
        const chunk = @min(remaining, spaces.len);
        printErr(spaces[0..chunk]);
        remaining -= chunk;
    }
}

fn printStepStart(name: []const u8) void {
    printErr("    " ++ dim ++ "… " ++ reset);
    printErr(dim);
    printErr(name);
    printErr(reset);
}

fn printStepResult(name: []const u8, result: StepResult, is_llm: bool) void {
    // Overwrite the "… name" progress line
    printErr("\r\x1B[2K");
    if (result.passed) {
        printErr("    " ++ cyan ++ "\xE2\x9C\x93" ++ reset ++ " ");
    } else {
        printErr("    " ++ bold ++ "\xE2\x9C\x97" ++ reset ++ " ");
    }
    printErr(name);

    if (is_llm and result.elapsed_ms > 0) {
        const name_len = name.len;
        if (name_len < 42) {
            printPad(42 - name_len);
        }
        var time_buf: [32]u8 = undefined;
        const time_str = if (result.elapsed_ms < 1000)
            std.fmt.bufPrint(&time_buf, "{d}ms", .{result.elapsed_ms}) catch "?"
        else
            std.fmt.bufPrint(&time_buf, "{d:.1}s", .{@as(f64, @floatFromInt(result.elapsed_ms)) / 1000.0}) catch "?";
        printErr(dim);
        printErr(time_str);
        printErr(reset);
    }
    printErr("\n");
}

// ── Test Steps ─────────────────────────────────────────────────────────

fn runPhase1(allocator: std.mem.Allocator, api_key: []const u8, model: []const u8, results: *[16]StepResult) void {
    printErr("\n  " ++ bold ++ "Phase 1: Function Rename" ++ reset ++ "\n");

    // Step 1: LLM - Find resolveDispatcher
    {
        printStepStart("Find resolveDispatcher");
        const agent_result = runSingleTurnAgent(
            allocator,
            api_key,
            model,
            "Use the cog_query tool with mode \"--find\" and query \"resolveDispatcher\" to find where resolveDispatcher is defined.",
        ) catch |err| {
            results[0] = .{ .passed = false, .detail = @errorName(err) };
            printStepResult("Find resolveDispatcher", results[0], true);
            return;
        };
        defer allocator.free(agent_result.tool_name);
        defer allocator.free(agent_result.tool_output);

        const passed = std.mem.eql(u8, agent_result.tool_name, "cog_query") and
            outputContains(agent_result.tool_output, "ReactHooks");
        results[0] = .{ .passed = passed, .elapsed_ms = agent_result.elapsed_ms };
        printStepResult("Find resolveDispatcher", results[0], true);
    }

    // Step 2: LLM - Edit: rename function
    {
        printStepStart("Edit: rename to getActiveDispatcher");
        const agent_result = runSingleTurnAgent(
            allocator,
            api_key,
            model,
            "Use the cog_edit tool to edit the file \"" ++ TARGET_FILE ++ "\". Replace the old_text \"function resolveDispatcher()\" with new_text \"function getActiveDispatcher()\".",
        ) catch |err| {
            results[1] = .{ .passed = false, .detail = @errorName(err) };
            printStepResult("Edit: rename to getActiveDispatcher", results[1], true);
            return;
        };
        defer allocator.free(agent_result.tool_name);
        defer allocator.free(agent_result.tool_output);

        const passed = std.mem.eql(u8, agent_result.tool_name, "cog_edit") and
            !outputContains(agent_result.tool_output, "error");
        results[1] = .{ .passed = passed, .elapsed_ms = agent_result.elapsed_ms };
        printStepResult("Edit: rename to getActiveDispatcher", results[1], true);
    }

    // Step 3: Direct - resolveDispatcher should NOT be found
    {
        const found = verifySymbolExists(allocator, "resolveDispatcher") catch false;
        results[2] = .{ .passed = !found };
        printStepResult("Verify: old name not in index", results[2], false);
    }

    // Step 4: Direct - getActiveDispatcher SHOULD be found
    {
        const found = verifySymbolExists(allocator, "getActiveDispatcher") catch false;
        results[3] = .{ .passed = found };
        printStepResult("Verify: new name in index", results[3], false);
    }

    // Step 5: Direct - symbols list should contain getActiveDispatcher
    {
        const found = verifySymbolInFile(allocator, TARGET_FILE, "getActiveDispatcher") catch false;
        results[4] = .{ .passed = found };
        printStepResult("Verify: symbols list updated", results[4], false);
    }
}

fn runPhase2(allocator: std.mem.Allocator, api_key: []const u8, model: []const u8, results: *[16]StepResult) void {
    printErr("\n  " ++ bold ++ "Phase 2: File Rename" ++ reset ++ "\n");

    // Step 6: LLM - Query symbols in ReactHooks.js
    {
        printStepStart("Query symbols in ReactHooks.js");
        const agent_result = runSingleTurnAgent(
            allocator,
            api_key,
            model,
            "Use the cog_query tool with mode \"--symbols\" and query \"" ++ TARGET_FILE ++ "\" to list all symbols defined in that file.",
        ) catch |err| {
            results[5] = .{ .passed = false, .detail = @errorName(err) };
            printStepResult("Query symbols in ReactHooks.js", results[5], true);
            return;
        };
        defer allocator.free(agent_result.tool_name);
        defer allocator.free(agent_result.tool_output);

        const passed = std.mem.eql(u8, agent_result.tool_name, "cog_query") and
            agent_result.tool_output.len > 10;
        results[5] = .{ .passed = passed, .elapsed_ms = agent_result.elapsed_ms };
        printStepResult("Query symbols in ReactHooks.js", results[5], true);
    }

    // Step 7: LLM - Rename file
    {
        printStepStart("Rename to ReactHooksRenamed.js");
        const agent_result = runSingleTurnAgent(
            allocator,
            api_key,
            model,
            "Use the cog_rename tool to rename old_path \"" ++ TARGET_FILE ++ "\" to new_path \"" ++ RENAMED_FILE ++ "\".",
        ) catch |err| {
            results[6] = .{ .passed = false, .detail = @errorName(err) };
            printStepResult("Rename to ReactHooksRenamed.js", results[6], true);
            return;
        };
        defer allocator.free(agent_result.tool_name);
        defer allocator.free(agent_result.tool_output);

        const passed = std.mem.eql(u8, agent_result.tool_name, "cog_rename") and
            !outputContains(agent_result.tool_output, "error");
        results[6] = .{ .passed = passed, .elapsed_ms = agent_result.elapsed_ms };
        printStepResult("Rename to ReactHooksRenamed.js", results[6], true);
    }

    // Step 8: Direct - old path NOT in index
    {
        const found = verifyFileInIndex(allocator, TARGET_FILE) catch false;
        results[7] = .{ .passed = !found };
        printStepResult("Verify: old path not in index", results[7], false);
    }

    // Step 9: Direct - new path IS in index
    {
        const found = verifyFileInIndex(allocator, RENAMED_FILE) catch false;
        results[8] = .{ .passed = found };
        printStepResult("Verify: new path in index", results[8], false);
    }
}

fn runPhase3(allocator: std.mem.Allocator, api_key: []const u8, model: []const u8, results: *[16]StepResult) void {
    printErr("\n  " ++ bold ++ "Phase 3: File Delete" ++ reset ++ "\n");

    // Step 10: LLM - Delete ReactHooksRenamed.js
    {
        printStepStart("Delete ReactHooksRenamed.js");
        const agent_result = runSingleTurnAgent(
            allocator,
            api_key,
            model,
            "Use the cog_delete tool to delete the file \"" ++ RENAMED_FILE ++ "\".",
        ) catch |err| {
            results[9] = .{ .passed = false, .detail = @errorName(err) };
            printStepResult("Delete ReactHooksRenamed.js", results[9], true);
            return;
        };
        defer allocator.free(agent_result.tool_name);
        defer allocator.free(agent_result.tool_output);

        const passed = std.mem.eql(u8, agent_result.tool_name, "cog_delete") and
            !outputContains(agent_result.tool_output, "error");
        results[9] = .{ .passed = passed, .elapsed_ms = agent_result.elapsed_ms };
        printStepResult("Delete ReactHooksRenamed.js", results[9], true);
    }

    // Step 11: Direct - file NOT in index
    {
        const found = verifyFileInIndex(allocator, RENAMED_FILE) catch false;
        results[10] = .{ .passed = !found };
        printStepResult("Verify: file not in index", results[10], false);
    }
}

fn runPhase4(allocator: std.mem.Allocator, api_key: []const u8, model: []const u8, results: *[16]StepResult) void {
    printErr("\n  " ++ bold ++ "Phase 4: Additional Coverage" ++ reset ++ "\n");

    // Step 12: LLM - Query refs for createElement
    {
        printStepStart("Query refs for createElement");
        const agent_result = runSingleTurnAgent(
            allocator,
            api_key,
            model,
            "Use the cog_query tool with mode \"--refs\" and query \"createElement\" to find all references to createElement.",
        ) catch |err| {
            results[11] = .{ .passed = false, .detail = @errorName(err) };
            printStepResult("Query refs for createElement", results[11], true);
            return;
        };
        defer allocator.free(agent_result.tool_name);
        defer allocator.free(agent_result.tool_output);

        const passed = std.mem.eql(u8, agent_result.tool_name, "cog_query") and
            outputContains(agent_result.tool_output, "/");
        results[11] = .{ .passed = passed, .elapsed_ms = agent_result.elapsed_ms };
        printStepResult("Query refs for createElement", results[11], true);
    }

    // Step 13: LLM - Create IntegrationTestHelper.js
    {
        printStepStart("Create IntegrationTestHelper.js");
        const agent_result = runSingleTurnAgent(
            allocator,
            api_key,
            model,
            "Use the cog_create tool to create a file at \"" ++ CREATED_FILE ++ "\" with content \"export function integrationTestHelper() { return 42; }\".",
        ) catch |err| {
            results[12] = .{ .passed = false, .detail = @errorName(err) };
            printStepResult("Create IntegrationTestHelper.js", results[12], true);
            return;
        };
        defer allocator.free(agent_result.tool_name);
        defer allocator.free(agent_result.tool_output);

        const passed = std.mem.eql(u8, agent_result.tool_name, "cog_create") and
            !outputContains(agent_result.tool_output, "error");
        results[12] = .{ .passed = passed, .elapsed_ms = agent_result.elapsed_ms };
        printStepResult("Create IntegrationTestHelper.js", results[12], true);
    }

    // Step 14: Direct - integrationTestHelper found
    {
        const found = verifySymbolExists(allocator, "integrationTestHelper") catch false;
        results[13] = .{ .passed = found };
        printStepResult("Verify: new function in index", results[13], false);
    }

    // Step 15: LLM - Delete IntegrationTestHelper.js
    {
        printStepStart("Delete IntegrationTestHelper.js");
        const agent_result = runSingleTurnAgent(
            allocator,
            api_key,
            model,
            "Use the cog_delete tool to delete the file \"" ++ CREATED_FILE ++ "\".",
        ) catch |err| {
            results[14] = .{ .passed = false, .detail = @errorName(err) };
            printStepResult("Delete IntegrationTestHelper.js", results[14], true);
            return;
        };
        defer allocator.free(agent_result.tool_name);
        defer allocator.free(agent_result.tool_output);

        const passed = std.mem.eql(u8, agent_result.tool_name, "cog_delete") and
            !outputContains(agent_result.tool_output, "error");
        results[14] = .{ .passed = passed, .elapsed_ms = agent_result.elapsed_ms };
        printStepResult("Delete IntegrationTestHelper.js", results[14], true);
    }

    // Step 16: Direct - integrationTestHelper NOT found
    {
        const found = verifySymbolExists(allocator, "integrationTestHelper") catch false;
        results[15] = .{ .passed = !found };
        printStepResult("Verify: function not in index", results[15], false);
    }
}

// ── .env Loading (from bench_query.zig) ────────────────────────────────

fn loadDotEnv(allocator: std.mem.Allocator) !?[]const u8 {
    const file = std.fs.cwd().openFile(".env", .{}) catch return null;
    defer file.close();

    const content = file.readToEndAlloc(allocator, 4096) catch return null;
    defer allocator.free(content);

    var iter = std.mem.splitScalar(u8, content, '\n');
    while (iter.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0 or trimmed[0] == '#') continue;

        if (std.mem.startsWith(u8, trimmed, "OPENROUTER_API_KEY=")) {
            const val = trimmed["OPENROUTER_API_KEY=".len..];
            if (val.len > 0) return try allocator.dupe(u8, val);
        }
    }
    return null;
}

// ── Main ───────────────────────────────────────────────────────────────

pub fn main() void {
    mainInner() catch |err| {
        if (err != error.SetupFailed and err != error.MissingApiKey) {
            var buf: [128]u8 = undefined;
            const msg = std.fmt.bufPrint(&buf, "error: {s}\n", .{@errorName(err)}) catch "error\n";
            printErr(msg);
        }
        std.process.exit(1);
    };
}

fn mainInner() !void {
    var gpa: std.heap.GeneralPurposeAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Read API key
    var api_key_allocated: ?[]const u8 = null;
    defer if (api_key_allocated) |k| allocator.free(k);

    const api_key = std.posix.getenv("OPENROUTER_API_KEY") orelse blk: {
        const from_env = loadDotEnv(allocator) catch null;
        api_key_allocated = from_env;
        break :blk from_env;
    } orelse {
        printErr("\n  " ++ bold ++ "error:" ++ reset ++ " OPENROUTER_API_KEY not found.\n");
        printErr("  Set it as an environment variable or in a .env file.\n\n");
        return error.MissingApiKey;
    };

    const model = std.posix.getenv("OPENROUTER_MODEL") orelse DEFAULT_MODEL;

    // Header
    printErr("\n  " ++ cyan ++ bold ++ "Integration Test: Cog Tool Lifecycle" ++ reset ++ "\n");
    printErr("  " ++ dim ++ "Model: " ++ reset);
    printErr(model);
    printErr("\n\n");

    // Setup
    try ensureReactRepo(allocator);
    printErr("  " ++ cyan ++ "\xE2\x9C\x93" ++ reset ++ " React " ++ REACT_TAG ++ " repo ready\n");

    // Git reset in case previous run was interrupted
    gitResetReactRepo(allocator);

    // Index only the files the test touches
    try buildCogIndex(allocator, "packages/react/src/**/*.js");
    printErr("  " ++ cyan ++ "\xE2\x9C\x93" ++ reset ++ " Code index ready\n");

    // Run all phases
    var results: [16]StepResult = [_]StepResult{.{ .passed = false }} ** 16;

    runPhase1(allocator, api_key, model, &results);
    runPhase2(allocator, api_key, model, &results);
    runPhase3(allocator, api_key, model, &results);
    runPhase4(allocator, api_key, model, &results);

    // Cleanup: restore files, setup handles index sync on next run
    printErr("\n");
    gitResetReactRepo(allocator);

    // Summary
    var passed: usize = 0;
    for (results) |r| {
        if (r.passed) passed += 1;
    }

    printErr("\n  " ++ bold ++ "Results: " ++ reset);
    printFmtErr("{d}/16 passed", .{passed});
    printErr("\n\n");

    if (passed < 16) {
        std.process.exit(1);
    }
}
