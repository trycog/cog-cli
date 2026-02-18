const std = @import("std");
const json = std.json;
const Writer = std.io.Writer;

// ── Constants & Config ─────────────────────────────────────────────────

const OPENROUTER_URL = "https://openrouter.ai/api/v1/chat/completions";
const DEFAULT_MODEL = "anthropic/claude-sonnet-4";
const MAX_AGENT_TURNS = 15;
const REACT_REPO_URL = "https://github.com/facebook/react.git";
const REACT_TAG = "v19.0.0";
const REACT_DIR = "bench/react";
const COG_BINARY = "zig-out/bin/cog";

// ANSI
const cyan = "\x1B[36m";
const bold = "\x1B[1m";
const dim = "\x1B[2m";
const reset = "\x1B[0m";

// ── Types ──────────────────────────────────────────────────────────────

const TestCase = struct {
    name: []const u8,
    question: []const u8,
    cog_mode: []const u8, // e.g. "--find", "--refs", "--symbols"
};

const Metrics = struct {
    wall_time_ms: i64,
    total_tokens: i64,
    prompt_tokens: i64,
    completion_tokens: i64,
    tool_calls: i64,
    rounds: i64,
    answer: []const u8,
    failed: bool,
};

const AgentKind = enum { cog, traditional };

// ── Test Cases ─────────────────────────────────────────────────────────

const test_cases = [_]TestCase{
    .{
        .name = "Find createElement definition",
        .question = "Where is the function createElement defined? Give the file path and line number.",
        .cog_mode = "--find",
    },
    .{
        .name = "Find useState references",
        .question = "What files reference useState? List the file paths.",
        .cog_mode = "--refs",
    },
    .{
        .name = "List ReactFiberWorkLoop symbols",
        .question = "What symbols are defined in packages/react-reconciler/src/ReactFiberWorkLoop.js?",
        .cog_mode = "--symbols",
    },
    .{
        .name = "Find Component class",
        .question = "Where is the Component class defined? Give the file path and line number.",
        .cog_mode = "--find",
    },
    .{
        .name = "Exports from ReactClient.js",
        .question = "What functions are exported from packages/react/src/ReactClient.js?",
        .cog_mode = "--symbols",
    },
};

// ── Tool Definitions (JSON) ────────────────────────────────────────────

const cog_tools_json =
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
    \\}]
;

const traditional_tools_json =
    \\[{
    \\  "type": "function",
    \\  "function": {
    \\    "name": "grep",
    \\    "description": "Search for a pattern in files. Returns matching lines with file paths and line numbers.",
    \\    "parameters": {
    \\      "type": "object",
    \\      "properties": {
    \\        "pattern": {
    \\          "type": "string",
    \\          "description": "Regex pattern to search for"
    \\        },
    \\        "glob": {
    \\          "type": "string",
    \\          "description": "File glob filter, e.g. '*.js'"
    \\        },
    \\        "path": {
    \\          "type": "string",
    \\          "description": "Subdirectory to search in, relative to repo root"
    \\        }
    \\      },
    \\      "required": ["pattern"]
    \\    }
    \\  }
    \\},{
    \\  "type": "function",
    \\  "function": {
    \\    "name": "read_file",
    \\    "description": "Read a file's contents. Returns the text content of the file.",
    \\    "parameters": {
    \\      "type": "object",
    \\      "properties": {
    \\        "path": {
    \\          "type": "string",
    \\          "description": "File path relative to repo root"
    \\        },
    \\        "start_line": {
    \\          "type": "integer",
    \\          "description": "First line to read (1-based, optional)"
    \\        },
    \\        "end_line": {
    \\          "type": "integer",
    \\          "description": "Last line to read (1-based, optional)"
    \\        }
    \\      },
    \\      "required": ["path"]
    \\    }
    \\  }
    \\},{
    \\  "type": "function",
    \\  "function": {
    \\    "name": "list_files",
    \\    "description": "List files matching a pattern in a directory.",
    \\    "parameters": {
    \\      "type": "object",
    \\      "properties": {
    \\        "path": {
    \\          "type": "string",
    \\          "description": "Directory path relative to repo root"
    \\        },
    \\        "pattern": {
    \\          "type": "string",
    \\          "description": "Filename glob pattern, e.g. '*.js'"
    \\        }
    \\      },
    \\      "required": ["path"]
    \\    }
    \\  }
    \\}]
;

// ── JSON Construction ──────────────────────────────────────────────────

fn buildRequestBody(
    allocator: std.mem.Allocator,
    model: []const u8,
    messages: []const MessageEntry,
    tools_json: []const u8,
) ![]const u8 {
    // Build the request JSON manually for control over structure
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

// ── JSON Parsing ───────────────────────────────────────────────────────

const ParsedResponse = struct {
    // Message fields
    content: ?[]const u8,
    tool_calls: []ParsedToolCall,
    finish_reason: []const u8,
    // Usage
    prompt_tokens: i64,
    completion_tokens: i64,
    total_tokens: i64,
};

const ParsedToolCall = struct {
    id: []const u8,
    function_name: []const u8,
    arguments: []const u8,
};

fn parseOpenRouterResponse(allocator: std.mem.Allocator, body: []const u8) !ParsedResponse {
    const parsed = json.parseFromSlice(json.Value, allocator, body, .{}) catch {
        return error.InvalidResponse;
    };
    defer parsed.deinit();

    const root = parsed.value;
    if (root != .object) return error.InvalidResponse;

    // Check for error
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

    // Content
    var content: ?[]const u8 = null;
    if (message.object.get("content")) |c| {
        if (c == .string and c.string.len > 0) {
            content = try allocator.dupe(u8, c.string);
        }
    }

    // Tool calls
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

    // Usage
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

// ── HTTP Client ────────────────────────────────────────────────────────

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

fn executeCogQuery(allocator: std.mem.Allocator, args_json: []const u8) ![]const u8 {
    // Parse the arguments
    const parsed = json.parseFromSlice(json.Value, allocator, args_json, .{}) catch {
        return try allocator.dupe(u8, "error: invalid arguments JSON");
    };
    defer parsed.deinit();

    if (parsed.value != .object) {
        return try allocator.dupe(u8, "error: arguments must be an object");
    }

    const mode_val = parsed.value.object.get("mode") orelse {
        return try allocator.dupe(u8, "error: missing 'mode' parameter");
    };
    const query_val = parsed.value.object.get("query") orelse {
        return try allocator.dupe(u8, "error: missing 'query' parameter");
    };

    const mode = if (mode_val == .string) mode_val.string else return try allocator.dupe(u8, "error: mode must be a string");
    const query = if (query_val == .string) query_val.string else return try allocator.dupe(u8, "error: query must be a string");

    // Shell out to cog binary (need absolute path since cwd will be the React dir)
    const cwd = std.fs.cwd().realpathAlloc(allocator, ".") catch {
        return try allocator.dupe(u8, "error: cannot resolve cwd");
    };
    defer allocator.free(cwd);

    const cog_path = std.fmt.allocPrint(allocator, "{s}/{s}", .{ cwd, COG_BINARY }) catch {
        return try allocator.dupe(u8, "error: cannot build cog path");
    };
    defer allocator.free(cog_path);

    const result = std.process.Child.run(.{
        .allocator = allocator,
        .argv = &.{ cog_path, "code/query", mode, query },
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

    // Truncate if too large
    if (result.stdout.len > 8192) {
        const truncated = try allocator.alloc(u8, 8192 + 20);
        @memcpy(truncated[0..8192], result.stdout[0..8192]);
        @memcpy(truncated[8192..][0..20], "\n... (truncated) ...");
        allocator.free(result.stdout);
        return truncated;
    }

    return result.stdout;
}

fn executeGrep(allocator: std.mem.Allocator, args_json: []const u8) ![]const u8 {
    const parsed = json.parseFromSlice(json.Value, allocator, args_json, .{}) catch {
        return try allocator.dupe(u8, "error: invalid arguments JSON");
    };
    defer parsed.deinit();

    if (parsed.value != .object) {
        return try allocator.dupe(u8, "error: arguments must be an object");
    }

    const pattern_val = parsed.value.object.get("pattern") orelse {
        return try allocator.dupe(u8, "error: missing 'pattern' parameter");
    };
    const pattern = if (pattern_val == .string) pattern_val.string else return try allocator.dupe(u8, "error: pattern must be a string");

    // Build grep command
    var argv: std.ArrayListUnmanaged([]const u8) = .empty;
    defer argv.deinit(allocator);

    try argv.append(allocator, "grep");
    try argv.append(allocator, "-rn");
    try argv.append(allocator, "--max-count=50");

    // Glob filter
    if (parsed.value.object.get("glob")) |glob_val| {
        if (glob_val == .string) {
            const include = try std.fmt.allocPrint(allocator, "--include={s}", .{glob_val.string});
            defer allocator.free(include);
            try argv.append(allocator, include);
        }
    }

    try argv.append(allocator, pattern);

    // Path
    if (parsed.value.object.get("path")) |path_val| {
        if (path_val == .string and path_val.string.len > 0) {
            const full_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ REACT_DIR, path_val.string });
            defer allocator.free(full_path);
            try argv.append(allocator, full_path);
        } else {
            try argv.append(allocator, REACT_DIR);
        }
    } else {
        try argv.append(allocator, REACT_DIR);
    }

    const result = std.process.Child.run(.{
        .allocator = allocator,
        .argv = argv.items,
        .max_output_bytes = 64 * 1024,
    }) catch |err| {
        return try std.fmt.allocPrint(allocator, "error: grep failed: {s}", .{@errorName(err)});
    };
    defer allocator.free(result.stderr);

    if (result.stdout.len == 0) {
        allocator.free(result.stdout);
        return try allocator.dupe(u8, "No matches found.");
    }

    // Truncate
    if (result.stdout.len > 4096) {
        const truncated = try allocator.alloc(u8, 4096 + 20);
        @memcpy(truncated[0..4096], result.stdout[0..4096]);
        @memcpy(truncated[4096..][0..20], "\n... (truncated) ...");
        allocator.free(result.stdout);
        return truncated;
    }

    return result.stdout;
}

fn executeReadFile(allocator: std.mem.Allocator, args_json: []const u8) ![]const u8 {
    const parsed = json.parseFromSlice(json.Value, allocator, args_json, .{}) catch {
        return try allocator.dupe(u8, "error: invalid arguments JSON");
    };
    defer parsed.deinit();

    if (parsed.value != .object) {
        return try allocator.dupe(u8, "error: arguments must be an object");
    }

    const path_val = parsed.value.object.get("path") orelse {
        return try allocator.dupe(u8, "error: missing 'path' parameter");
    };
    const rel_path = if (path_val == .string) path_val.string else return try allocator.dupe(u8, "error: path must be a string");

    const full_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ REACT_DIR, rel_path });
    defer allocator.free(full_path);

    const file = std.fs.cwd().openFile(full_path, .{}) catch |err| {
        return try std.fmt.allocPrint(allocator, "error: cannot open file '{s}': {s}", .{ rel_path, @errorName(err) });
    };
    defer file.close();

    const content = file.readToEndAlloc(allocator, 128 * 1024) catch |err| {
        return try std.fmt.allocPrint(allocator, "error: cannot read file '{s}': {s}", .{ rel_path, @errorName(err) });
    };

    // Handle line range
    var start_line: ?i64 = null;
    var end_line: ?i64 = null;
    if (parsed.value.object.get("start_line")) |v| {
        if (v == .integer) start_line = v.integer;
    }
    if (parsed.value.object.get("end_line")) |v| {
        if (v == .integer) end_line = v.integer;
    }

    if (start_line != null or end_line != null) {
        // Extract line range
        const sl: usize = if (start_line) |s| @intCast(@max(1, s) - 1) else 0;
        const el: usize = if (end_line) |e| @intCast(@max(1, e)) else std.math.maxInt(usize);

        var result_buf: std.ArrayListUnmanaged(u8) = .empty;
        var line_num: usize = 0;
        var line_iter = std.mem.splitScalar(u8, content, '\n');
        while (line_iter.next()) |line| {
            if (line_num >= el) break;
            if (line_num >= sl) {
                var num_buf: [16]u8 = undefined;
                const num_str = std.fmt.bufPrint(&num_buf, "{d}: ", .{line_num + 1}) catch "";
                try result_buf.appendSlice(allocator, num_str);
                try result_buf.appendSlice(allocator, line);
                try result_buf.append(allocator, '\n');
            }
            line_num += 1;
        }
        allocator.free(content);

        const result = try result_buf.toOwnedSlice(allocator);
        if (result.len > 8192) {
            const truncated = try allocator.alloc(u8, 8192 + 20);
            @memcpy(truncated[0..8192], result[0..8192]);
            @memcpy(truncated[8192..][0..20], "\n... (truncated) ...");
            allocator.free(result);
            return truncated;
        }
        return result;
    }

    // Truncate full file if needed
    if (content.len > 8192) {
        const truncated = try allocator.alloc(u8, 8192 + 20);
        @memcpy(truncated[0..8192], content[0..8192]);
        @memcpy(truncated[8192..][0..20], "\n... (truncated) ...");
        allocator.free(content);
        return truncated;
    }

    return content;
}

fn executeListFiles(allocator: std.mem.Allocator, args_json: []const u8) ![]const u8 {
    const parsed = json.parseFromSlice(json.Value, allocator, args_json, .{}) catch {
        return try allocator.dupe(u8, "error: invalid arguments JSON");
    };
    defer parsed.deinit();

    if (parsed.value != .object) {
        return try allocator.dupe(u8, "error: arguments must be an object");
    }

    const path_val = parsed.value.object.get("path") orelse {
        return try allocator.dupe(u8, "error: missing 'path' parameter");
    };
    const rel_path = if (path_val == .string) path_val.string else return try allocator.dupe(u8, "error: path must be a string");

    var argv: std.ArrayListUnmanaged([]const u8) = .empty;
    defer argv.deinit(allocator);

    const search_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ REACT_DIR, rel_path });
    defer allocator.free(search_path);

    try argv.append(allocator, "find");
    try argv.append(allocator, search_path);
    try argv.append(allocator, "-type");
    try argv.append(allocator, "f");

    if (parsed.value.object.get("pattern")) |pattern_val| {
        if (pattern_val == .string) {
            try argv.append(allocator, "-name");
            try argv.append(allocator, pattern_val.string);
        }
    }

    // Limit output
    try argv.append(allocator, "-maxdepth");
    try argv.append(allocator, "5");

    const result = std.process.Child.run(.{
        .allocator = allocator,
        .argv = argv.items,
        .max_output_bytes = 64 * 1024,
    }) catch |err| {
        return try std.fmt.allocPrint(allocator, "error: find failed: {s}", .{@errorName(err)});
    };
    defer allocator.free(result.stderr);

    if (result.stdout.len == 0) {
        allocator.free(result.stdout);
        return try allocator.dupe(u8, "No files found.");
    }

    if (result.stdout.len > 4096) {
        const truncated = try allocator.alloc(u8, 4096 + 20);
        @memcpy(truncated[0..4096], result.stdout[0..4096]);
        @memcpy(truncated[4096..][0..20], "\n... (truncated) ...");
        allocator.free(result.stdout);
        return truncated;
    }

    return result.stdout;
}

fn executeToolCall(allocator: std.mem.Allocator, name: []const u8, arguments: []const u8) ![]const u8 {
    if (std.mem.eql(u8, name, "cog_query")) {
        return executeCogQuery(allocator, arguments);
    } else if (std.mem.eql(u8, name, "grep")) {
        return executeGrep(allocator, arguments);
    } else if (std.mem.eql(u8, name, "read_file")) {
        return executeReadFile(allocator, arguments);
    } else if (std.mem.eql(u8, name, "list_files")) {
        return executeListFiles(allocator, arguments);
    } else {
        return try std.fmt.allocPrint(allocator, "error: unknown tool '{s}'", .{name});
    }
}

// ── Agent Loop ─────────────────────────────────────────────────────────

fn runAgent(
    allocator: std.mem.Allocator,
    api_key: []const u8,
    model: []const u8,
    kind: AgentKind,
    question: []const u8,
) !Metrics {
    // Use an arena for all per-turn allocations (messages, tool results,
    // parsed responses). Everything is freed in bulk when the agent finishes.
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const system_prompt = switch (kind) {
        .cog => "You are a code intelligence assistant. You have access to a cog_query tool that queries a pre-built SCIP code index for a React v19.0.0 codebase. Use it to answer questions about code locations, symbols, and references. Be concise and precise in your answers — give file paths and line numbers when asked.",
        .traditional => "You are a code intelligence assistant. You have access to grep, read_file, and list_files tools to explore a React v19.0.0 codebase. Use them to answer questions about code locations, symbols, and references. Be concise and precise in your answers — give file paths and line numbers when asked.",
    };

    const tools_json = switch (kind) {
        .cog => cog_tools_json,
        .traditional => traditional_tools_json,
    };

    var messages: std.ArrayListUnmanaged(MessageEntry) = .empty;

    // System + user messages
    try messages.append(a, .{ .role = "system", .content = system_prompt });
    try messages.append(a, .{ .role = "user", .content = question });

    var total_tokens: i64 = 0;
    var prompt_tokens: i64 = 0;
    var completion_tokens: i64 = 0;
    var tool_call_count: i64 = 0;
    var rounds: i64 = 0;

    const start_time = std.time.milliTimestamp();

    var turn: usize = 0;
    while (turn < MAX_AGENT_TURNS) : (turn += 1) {
        rounds += 1;

        // Show round progress
        var round_buf: [16]u8 = undefined;
        const round_str = std.fmt.bufPrint(&round_buf, " r{d}", .{rounds}) catch "";
        printErr(dim);
        printErr(round_str);
        printErr(reset);

        // Build request
        const body = try buildRequestBody(a, model, messages.items, tools_json);

        // POST to OpenRouter
        const response_body = openrouterPost(a, api_key, body) catch {
            return .{
                .wall_time_ms = std.time.milliTimestamp() - start_time,
                .total_tokens = total_tokens,
                .prompt_tokens = prompt_tokens,
                .completion_tokens = completion_tokens,
                .tool_calls = tool_call_count,
                .rounds = rounds,
                .answer = "error: HTTP request failed",
                .failed = true,
            };
        };

        // Parse response
        const resp = parseOpenRouterResponse(a, response_body) catch {
            return .{
                .wall_time_ms = std.time.milliTimestamp() - start_time,
                .total_tokens = total_tokens,
                .prompt_tokens = prompt_tokens,
                .completion_tokens = completion_tokens,
                .tool_calls = tool_call_count,
                .rounds = rounds,
                .answer = "error: failed to parse response",
                .failed = true,
            };
        };

        total_tokens += resp.total_tokens;
        prompt_tokens += resp.prompt_tokens;
        completion_tokens += resp.completion_tokens;

        // Check for tool calls
        if (resp.tool_calls.len > 0) {
            // Append the assistant message with tool calls
            var tc_entries: std.ArrayListUnmanaged(ToolCallEntry) = .empty;
            for (resp.tool_calls) |tc| {
                try tc_entries.append(a, .{
                    .id = tc.id,
                    .function_name = tc.function_name,
                    .arguments = tc.arguments,
                });
            }
            try messages.append(a, .{
                .role = "assistant",
                .content = resp.content,
                .tool_calls = try tc_entries.toOwnedSlice(a),
            });

            // Execute each tool call and append results
            for (resp.tool_calls) |tc| {
                tool_call_count += 1;
                const tool_result = executeToolCall(a, tc.function_name, tc.arguments) catch |err| blk: {
                    break :blk try std.fmt.allocPrint(a, "error: tool execution failed: {s}", .{@errorName(err)});
                };

                try messages.append(a, .{
                    .role = "tool",
                    .content = tool_result,
                    .tool_call_id = tc.id,
                });
            }
            continue;
        }

        // No tool calls — this is the final answer
        break;
    }

    const wall_time = std.time.milliTimestamp() - start_time;

    return .{
        .wall_time_ms = wall_time,
        .total_tokens = total_tokens,
        .prompt_tokens = prompt_tokens,
        .completion_tokens = completion_tokens,
        .tool_calls = tool_call_count,
        .rounds = rounds,
        .answer = "",
        .failed = false,
    };
}

// ── Setup ──────────────────────────────────────────────────────────────

fn ensureReactRepo(allocator: std.mem.Allocator) !void {
    // Check if already cloned
    std.fs.cwd().access(REACT_DIR ++ "/package.json", .{}) catch {
        printErr("  Cloning React " ++ REACT_TAG ++ " (shallow)...\n");

        // Spawn with inherited stderr so git progress is visible
        const argv: []const []const u8 = &.{
            "git", "clone", "--depth", "1", "--branch", REACT_TAG,
            "--progress", REACT_REPO_URL, REACT_DIR,
        };
        var child = std.process.Child.init(argv, allocator);
        // stdin/stdout/stderr default to .Inherit — git progress shows through
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

fn ensureCogIndex(allocator: std.mem.Allocator) !void {
    // Check if index exists
    std.fs.cwd().access(REACT_DIR ++ "/.cog/index.scip", .{}) catch {
        printErr("  Building code index...\n\n");

        // Need absolute path to cog binary since cwd will be different
        const cwd = try std.fs.cwd().realpathAlloc(allocator, ".");
        defer allocator.free(cwd);

        const cog_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ cwd, COG_BINARY });
        defer allocator.free(cog_path);

        // Spawn with inherited stderr so the cog progress bar is visible
        const argv: []const []const u8 = &.{ cog_path, "code/index" };
        var child = std.process.Child.init(argv, allocator);
        child.cwd = REACT_DIR;
        // stdin/stdout/stderr default to .Inherit — progress bar shows through
        child.spawn() catch {
            printErr("  error: failed to run cog code/index\n");
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

        printErr("\n");
        return;
    };
}

// ── Results Display ────────────────────────────────────────────────────

fn printResults(model: []const u8, results: []const ResultEntry) void {
    // Header
    printErr("\n");
    printErr("  " ++ cyan ++ bold ++ "┌───────────────────────────────────────────────────────────────────────┐" ++ reset ++ "\n");
    printErr("  " ++ cyan ++ bold ++ "│" ++ reset ++ "  " ++ bold ++ "Results                                                          " ++ reset ++ cyan ++ bold ++ "│" ++ reset ++ "\n");
    printErr("  " ++ cyan ++ bold ++ "│" ++ reset ++ dim ++ "  Model: " ++ reset);
    printErr(model);
    printPad(60 -| model.len);
    printErr(cyan ++ bold ++ "│" ++ reset ++ "\n");
    printErr("  " ++ cyan ++ bold ++ "├────────────────────────────────┬────────┬────────┬─────────┬─────────┤" ++ reset ++ "\n");
    printErr("  " ++ cyan ++ bold ++ "│" ++ reset ++ bold ++ "  Test Case                     " ++ reset ++ cyan ++ bold ++ "│" ++ reset ++ bold ++ " Method " ++ reset ++ cyan ++ bold ++ "│" ++ reset ++ bold ++ "  Time  " ++ reset ++ cyan ++ bold ++ "│" ++ reset ++ bold ++ " Tokens  " ++ reset ++ cyan ++ bold ++ "│" ++ reset ++ bold ++ "  Calls " ++ reset ++ cyan ++ bold ++ "│" ++ reset ++ "\n");
    printErr("  " ++ cyan ++ bold ++ "├────────────────────────────────┼────────┼────────┼─────────┼─────────┤" ++ reset ++ "\n");

    var total_cog_time: i64 = 0;
    var total_trad_time: i64 = 0;
    var total_cog_tokens: i64 = 0;
    var total_trad_tokens: i64 = 0;
    var total_cog_calls: i64 = 0;
    var total_trad_calls: i64 = 0;

    for (results, 0..) |r, idx| {
        total_cog_time += r.cog.wall_time_ms;
        total_trad_time += r.trad.wall_time_ms;
        total_cog_tokens += r.cog.total_tokens;
        total_trad_tokens += r.trad.total_tokens;
        total_cog_calls += r.cog.tool_calls;
        total_trad_calls += r.trad.tool_calls;

        // Test name (truncate to 28 chars)
        const name = r.name;
        const display_name = if (name.len > 28) name[0..28] else name;
        const name_pad = 28 -| display_name.len;

        // Cog row
        printErr("  " ++ cyan ++ bold ++ "│" ++ reset ++ "  ");
        printErr(display_name);
        printPad(name_pad + 2);
        printErr(cyan ++ bold ++ "│" ++ reset);
        printMetricsCell(" Cog  ", r.cog);
        printErr("\n");

        // Traditional row
        printErr("  " ++ cyan ++ bold ++ "│" ++ reset ++ "  ");
        printPad(30);
        printErr(cyan ++ bold ++ "│" ++ reset);
        printMetricsCell(" Agent", r.trad);
        printErr("\n");

        // Separator between test cases (not after last)
        if (idx + 1 < results.len) {
            printErr("  " ++ cyan ++ bold ++ "├────────────────────────────────┼────────┼────────┼─────────┼─────────┤" ++ reset ++ "\n");
        }
    }

    // Totals
    printErr("  " ++ cyan ++ bold ++ "├────────────────────────────────┴────────┴────────┴─────────┴─────────┤" ++ reset ++ "\n");
    printErr("  " ++ cyan ++ bold ++ "│" ++ reset ++ "  " ++ bold ++ "Totals                                                             " ++ reset ++ cyan ++ bold ++ "│" ++ reset ++ "\n");

    // Cog totals
    printErr("  " ++ cyan ++ bold ++ "│" ++ reset ++ "    " ++ cyan ++ "Cog:    " ++ reset);
    printFmtErr("{d:.1}s     {d} tokens     {d} calls", .{
        @as(f64, @floatFromInt(total_cog_time)) / 1000.0,
        total_cog_tokens,
        total_cog_calls,
    });
    printPad(16);
    printErr(cyan ++ bold ++ "│" ++ reset ++ "\n");

    // Agent totals
    printErr("  " ++ cyan ++ bold ++ "│" ++ reset ++ "    " ++ dim ++ "Agent:  " ++ reset);
    printFmtErr("{d:.1}s     {d} tokens     {d} calls", .{
        @as(f64, @floatFromInt(total_trad_time)) / 1000.0,
        total_trad_tokens,
        total_trad_calls,
    });
    printPad(16);
    printErr(cyan ++ bold ++ "│" ++ reset ++ "\n");

    // Savings
    const time_ratio = if (total_cog_time > 0) @as(f64, @floatFromInt(total_trad_time)) / @as(f64, @floatFromInt(total_cog_time)) else 0;
    const token_ratio = if (total_cog_tokens > 0) @as(f64, @floatFromInt(total_trad_tokens)) / @as(f64, @floatFromInt(total_cog_tokens)) else 0;

    printErr("  " ++ cyan ++ bold ++ "│" ++ reset ++ "    " ++ cyan ++ bold ++ "Savings: " ++ reset);
    var ratio_buf: [64]u8 = undefined;
    const ratio_str = std.fmt.bufPrint(&ratio_buf, "{d:.1}x faster, {d:.1}x fewer tokens", .{ time_ratio, token_ratio }) catch "?";
    printErr(ratio_str);
    printPad(60 -| ratio_str.len);
    printErr(cyan ++ bold ++ "│" ++ reset ++ "\n");

    // Bottom border
    printErr("  " ++ cyan ++ bold ++ "└───────────────────────────────────────────────────────────────────────┘" ++ reset ++ "\n\n");
}

fn printMetricsCell(label: []const u8, m: Metrics) void {
    const status = if (m.failed) dim ++ "FAIL" ++ reset else label;
    printErr(" ");
    printErr(status);
    printErr(" ");
    printErr(cyan ++ bold ++ "│" ++ reset);

    // Time
    var time_buf: [16]u8 = undefined;
    const time_str = if (m.wall_time_ms < 1000)
        std.fmt.bufPrint(&time_buf, "{d}ms", .{m.wall_time_ms}) catch "?"
    else
        std.fmt.bufPrint(&time_buf, "{d:.1}s", .{@as(f64, @floatFromInt(m.wall_time_ms)) / 1000.0}) catch "?";
    printPad(8 -| time_str.len);
    printErr(time_str);
    printErr(cyan ++ bold ++ "│" ++ reset);

    // Tokens
    var tok_buf: [16]u8 = undefined;
    const tok_str = if (m.total_tokens >= 1000)
        std.fmt.bufPrint(&tok_buf, "{d:.1}k", .{@as(f64, @floatFromInt(m.total_tokens)) / 1000.0}) catch "?"
    else
        std.fmt.bufPrint(&tok_buf, "{d}", .{m.total_tokens}) catch "?";
    printPad(9 -| tok_str.len);
    printErr(tok_str);
    printErr(cyan ++ bold ++ "│" ++ reset);

    // Calls
    var call_buf: [16]u8 = undefined;
    const call_str = std.fmt.bufPrint(&call_buf, "{d}", .{m.tool_calls}) catch "?";
    printPad(7 -| call_str.len);
    printErr(call_str);
    printErr(" ");
    printErr(cyan ++ bold ++ "│" ++ reset);
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

fn printAgentDone(m: Metrics) void {
    if (m.failed) {
        printErr(" " ++ bold ++ "\xE2\x9C\x97" ++ reset ++ dim ++ " failed" ++ reset ++ "\n");
    } else {
        var buf: [64]u8 = undefined;
        const time_str = if (m.wall_time_ms < 1000)
            std.fmt.bufPrint(&buf, " {d}ms", .{m.wall_time_ms}) catch ""
        else
            std.fmt.bufPrint(&buf, " {d:.1}s", .{@as(f64, @floatFromInt(m.wall_time_ms)) / 1000.0}) catch "";
        printErr(" " ++ cyan ++ "\xE2\x9C\x93" ++ reset);
        printErr(dim);
        printErr(time_str);
        printErr(reset ++ "\n");
    }
}

fn printFmtErr(comptime fmt: []const u8, args: anytype) void {
    var buf: [256]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, fmt, args) catch return;
    printErr(s);
}

// ── Main ───────────────────────────────────────────────────────────────

const ResultEntry = struct {
    name: []const u8,
    cog: Metrics,
    trad: Metrics,
};

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

fn mainInner() !void {
    var gpa: std.heap.GeneralPurposeAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Read config from env, falling back to .env file
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

    // Print header
    printErr("\n  " ++ cyan ++ bold ++ "Benchmark: Cog Index vs Traditional Agent Tools" ++ reset ++ "\n");
    printErr("  " ++ dim ++ "Model: " ++ reset);
    printErr(model);
    printErr("\n\n");

    // Setup
    try ensureReactRepo(allocator);
    printErr("  " ++ cyan ++ "\xE2\x9C\x93" ++ reset ++ " React " ++ REACT_TAG ++ " repo ready\n");

    try ensureCogIndex(allocator);
    printErr("  " ++ cyan ++ "\xE2\x9C\x93" ++ reset ++ " Code index ready\n\n");

    // Run test cases
    var results: [test_cases.len]ResultEntry = undefined;

    for (test_cases, 0..) |tc, i| {
        printErr("  Running: ");
        printErr(tc.name);
        printErr("...\n");

        // Run Cog agent
        printErr("    " ++ dim ++ "Cog agent..." ++ reset);
        const cog_metrics = try runAgent(allocator, api_key, model, .cog, tc.question);
        printAgentDone(cog_metrics);

        // Run Traditional agent
        printErr("    " ++ dim ++ "Traditional agent..." ++ reset);
        const trad_metrics = try runAgent(allocator, api_key, model, .traditional, tc.question);
        printAgentDone(trad_metrics);

        results[i] = .{
            .name = tc.name,
            .cog = cog_metrics,
            .trad = trad_metrics,
        };
    }

    // Display results
    printResults(model, &results);

    // Write JSON to stdout for dashboard consumption
    writeResultsJson(model, &results);
}

// ── Helpers ────────────────────────────────────────────────────────────

fn printErr(msg: []const u8) void {
    var buf: [4096]u8 = undefined;
    var w = std.fs.File.stderr().writer(&buf);
    w.interface.writeAll(msg) catch {};
    w.interface.flush() catch {};
}

const RESULTS_PATH = "bench/results.js";

fn writeResultsJson(model: []const u8, results: []const ResultEntry) void {
    const file = std.fs.cwd().createFile(RESULTS_PATH, .{}) catch {
        printErr("  warning: could not write " ++ RESULTS_PATH ++ "\n");
        return;
    };
    defer file.close();

    var buf: [16384]u8 = undefined;
    var w = file.writer(&buf);
    w.interface.writeAll("const BENCH_DATA = ") catch return;
    writeResultsJsonInner(&w.interface, model, results) catch return;
    w.interface.writeAll(";\n") catch return;
    w.interface.flush() catch {};

    printErr("  " ++ cyan ++ "\xE2\x9C\x93" ++ reset ++ " Results written to " ++ RESULTS_PATH ++ "\n");
    printErr("  " ++ dim ++ "Open bench/dashboard.html to view" ++ reset ++ "\n\n");
}

fn writeResultsJsonInner(w: anytype, model: []const u8, results: []const ResultEntry) !void {
    try w.writeAll("{\"model\":\"");
    try w.writeAll(model);
    try w.writeAll("\",\"results\":[");

    for (results, 0..) |r, i| {
        if (i > 0) try w.writeByte(',');
        try w.writeAll("{\"name\":\"");
        try w.writeAll(r.name);
        try w.writeAll("\",\"cog\":");
        try writeMetricsJson(w, r.cog);
        try w.writeAll(",\"traditional\":");
        try writeMetricsJson(w, r.trad);
        try w.writeByte('}');
    }

    try w.writeAll("]}");
}

fn writeMetricsJson(w: anytype, m: Metrics) !void {
    var num_buf: [32]u8 = undefined;
    try w.writeAll("{\"wall_time_ms\":");
    try w.writeAll(std.fmt.bufPrint(&num_buf, "{d}", .{m.wall_time_ms}) catch "0");
    try w.writeAll(",\"total_tokens\":");
    try w.writeAll(std.fmt.bufPrint(&num_buf, "{d}", .{m.total_tokens}) catch "0");
    try w.writeAll(",\"prompt_tokens\":");
    try w.writeAll(std.fmt.bufPrint(&num_buf, "{d}", .{m.prompt_tokens}) catch "0");
    try w.writeAll(",\"completion_tokens\":");
    try w.writeAll(std.fmt.bufPrint(&num_buf, "{d}", .{m.completion_tokens}) catch "0");
    try w.writeAll(",\"tool_calls\":");
    try w.writeAll(std.fmt.bufPrint(&num_buf, "{d}", .{m.tool_calls}) catch "0");
    try w.writeAll(",\"rounds\":");
    try w.writeAll(std.fmt.bufPrint(&num_buf, "{d}", .{m.rounds}) catch "0");
    try w.writeAll(",\"failed\":");
    try w.writeAll(if (m.failed) "true" else "false");
    try w.writeByte('}');
}
