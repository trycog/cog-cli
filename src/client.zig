const std = @import("std");
const json = std.json;
const Writer = std.io.Writer;
const curl = @import("curl.zig");
const debug_log = @import("debug_log.zig");

pub const ClientError = error{
    Explained,
    OutOfMemory,
    HttpError,
    InvalidResponse,
};

pub const McpResponse = struct {
    body: []const u8,
    session_id: ?[]const u8,
};

pub fn mcpCallTool(
    allocator: std.mem.Allocator,
    endpoint: []const u8,
    api_key: []const u8,
    session_id: ?[]const u8,
    tool_name: []const u8,
    arguments_json: []const u8,
) !McpResponse {
    var aw: Writer.Allocating = .init(allocator);
    defer aw.deinit();
    var s: json.Stringify = .{ .writer = &aw.writer };

    const parsed_arguments = try json.parseFromSlice(json.Value, allocator, arguments_json, .{});
    defer parsed_arguments.deinit();

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
    try s.write(tool_name);
    try s.objectField("arguments");
    try s.write(parsed_arguments.value);
    try s.endObject();
    try s.endObject();

    const body = try aw.toOwnedSlice();
    defer allocator.free(body);
    return mcpCall(allocator, endpoint, api_key, session_id, body);
}

pub fn mcpCall(
    allocator: std.mem.Allocator,
    endpoint: []const u8,
    api_key: []const u8,
    session_id: ?[]const u8,
    body: []const u8,
) !McpResponse {
    const auth_header = try std.fmt.allocPrint(allocator, "Authorization: Bearer {s}", .{api_key});
    defer allocator.free(auth_header);

    var header_count: usize = 3;
    var session_header: []const u8 = "";
    defer if (session_id != null) allocator.free(session_header);

    if (session_id) |sid| {
        session_header = try std.fmt.allocPrint(allocator, "mcp-session-id: {s}", .{sid});
        header_count = 4;
    }

    var headers_buf: [4][]const u8 = undefined;
    headers_buf[0] = auth_header;
    headers_buf[1] = "Content-Type: application/json";
    headers_buf[2] = "Accept: application/json";
    if (session_id != null) {
        headers_buf[3] = session_header;
    }

    debug_log.log("mcpCall: {s} session={s}", .{ endpoint, if (session_id) |s| s else "none" });
    const result = curl.postCapturingHeaders(allocator, endpoint, headers_buf[0..header_count], body) catch {
        debug_log.log("mcpCall: connection failed to {s}", .{endpoint});
        printErr("error: failed to connect to MCP endpoint\n");
        return error.Explained;
    };
    defer allocator.free(result.body);

    // Extract mcp-session-id from response headers
    var new_session_id: ?[]const u8 = null;
    if (result.headers.len > 0) {
        var lines = std.mem.splitScalar(u8, result.headers, '\n');
        while (lines.next()) |line| {
            const trimmed = std.mem.trim(u8, line, &[_]u8{ '\r', ' ', '\t' });
            const prefix = "mcp-session-id:";
            if (trimmed.len > prefix.len and std.ascii.startsWithIgnoreCase(trimmed, prefix)) {
                const val = std.mem.trim(u8, trimmed[prefix.len..], &[_]u8{ ' ', '\t' });
                if (val.len > 0) {
                    new_session_id = try allocator.dupe(u8, val);
                }
                break;
            }
        }
    }
    allocator.free(result.headers);
    errdefer if (new_session_id) |sid| allocator.free(sid);

    debug_log.log("mcpCall: {s} -> status {d}", .{ endpoint, result.status_code });
    if (result.status_code != 200) {
        if (new_session_id) |sid| allocator.free(sid);
        // Try to extract MCP error message
        if (json.parseFromSlice(json.Value, allocator, result.body, .{})) |parsed| {
            defer parsed.deinit();
            if (parsed.value == .object) {
                if (parsed.value.object.get("error")) |err_val| {
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
            }
        } else |_| {}

        var msg_buf: [128]u8 = undefined;
        const msg = std.fmt.bufPrint(&msg_buf, "error: MCP HTTP status {d}\n", .{result.status_code}) catch "error: MCP HTTP error\n";
        printErr(msg);
        return error.Explained;
    }

    return .{
        .body = try allocator.dupe(u8, result.body),
        .session_id = new_session_id,
    };
}

/// Like mcpCallTool but does not print error messages to stderr.
pub fn mcpCallToolQuiet(
    allocator: std.mem.Allocator,
    endpoint: []const u8,
    api_key: []const u8,
    session_id: ?[]const u8,
    tool_name: []const u8,
    arguments_json: []const u8,
) !McpResponse {
    var aw: Writer.Allocating = .init(allocator);
    defer aw.deinit();
    var s: json.Stringify = .{ .writer = &aw.writer };

    const parsed_arguments = try json.parseFromSlice(json.Value, allocator, arguments_json, .{});
    defer parsed_arguments.deinit();

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
    try s.write(tool_name);
    try s.objectField("arguments");
    try s.write(parsed_arguments.value);
    try s.endObject();
    try s.endObject();

    const body = try aw.toOwnedSlice();
    defer allocator.free(body);
    return mcpCallQuiet(allocator, endpoint, api_key, session_id, body);
}

fn mcpCallQuiet(
    allocator: std.mem.Allocator,
    endpoint: []const u8,
    api_key: []const u8,
    session_id: ?[]const u8,
    body: []const u8,
) !McpResponse {
    const auth_header = try std.fmt.allocPrint(allocator, "Authorization: Bearer {s}", .{api_key});
    defer allocator.free(auth_header);

    var header_count: usize = 3;
    var session_header: []const u8 = "";
    defer if (session_id != null) allocator.free(session_header);

    if (session_id) |sid| {
        session_header = try std.fmt.allocPrint(allocator, "mcp-session-id: {s}", .{sid});
        header_count = 4;
    }

    var headers_buf: [4][]const u8 = undefined;
    headers_buf[0] = auth_header;
    headers_buf[1] = "Content-Type: application/json";
    headers_buf[2] = "Accept: application/json";
    if (session_id != null) {
        headers_buf[3] = session_header;
    }

    debug_log.log("mcpCallQuiet: {s}", .{endpoint});
    const result = curl.postCapturingHeaders(allocator, endpoint, headers_buf[0..header_count], body) catch {
        debug_log.log("mcpCallQuiet: connection failed", .{});
        return error.HttpError;
    };
    defer allocator.free(result.body);

    var new_session_id: ?[]const u8 = null;
    if (result.headers.len > 0) {
        var lines = std.mem.splitScalar(u8, result.headers, '\n');
        while (lines.next()) |line| {
            const trimmed = std.mem.trim(u8, line, &[_]u8{ '\r', ' ', '\t' });
            const prefix = "mcp-session-id:";
            if (trimmed.len > prefix.len and std.ascii.startsWithIgnoreCase(trimmed, prefix)) {
                const val = std.mem.trim(u8, trimmed[prefix.len..], &[_]u8{ ' ', '\t' });
                if (val.len > 0) {
                    new_session_id = try allocator.dupe(u8, val);
                }
                break;
            }
        }
    }
    allocator.free(result.headers);
    errdefer if (new_session_id) |sid| allocator.free(sid);

    if (result.status_code != 200) {
        if (new_session_id) |sid| allocator.free(sid);
        debug_log.log("mcpCallQuiet: status {d}", .{result.status_code});
        return error.HttpError;
    }

    return .{
        .body = try allocator.dupe(u8, result.body),
        .session_id = new_session_id,
    };
}

pub fn post(
    allocator: std.mem.Allocator,
    url: []const u8,
    api_key: []const u8,
    body: []const u8,
) ![]const u8 {
    // Build auth header
    const auth_header = try std.fmt.allocPrint(allocator, "Authorization: Bearer {s}", .{api_key});
    defer allocator.free(auth_header);

    debug_log.log("post: {s} ({d} bytes)", .{ url, body.len });
    const result = curl.post(allocator, url, &.{
        auth_header,
        "Content-Type: application/json",
        "Accept: application/json",
    }, body) catch {
        debug_log.log("post: connection failed to {s}", .{url});
        printErr("error: failed to connect to ");
        printErr(url);
        printErr("\n");
        return error.Explained;
    };

    defer allocator.free(result.body);
    debug_log.log("post: {s} -> status {d}", .{ url, result.status_code });

    if (result.status_code != 200 and result.status_code != 201) {
        if (json.parseFromSlice(json.Value, allocator, result.body, .{})) |parsed| {
            defer parsed.deinit();
            if (parsed.value == .object) {
                if (parsed.value.object.get("error")) |err_val| {
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
            }
        } else |_| {}

        var msg_buf: [128]u8 = undefined;
        const msg = std.fmt.bufPrint(&msg_buf, "error: HTTP status {d}\n", .{result.status_code}) catch "error: HTTP error\n";
        printErr(msg);
        return error.Explained;
    }

    return parseResponse(allocator, result.body);
}

pub const RawResponse = struct {
    status_code: u16,
    body: []const u8,
};

pub fn postRaw(
    allocator: std.mem.Allocator,
    url: []const u8,
    api_key: []const u8,
    body: []const u8,
) !RawResponse {
    const auth_header = try std.fmt.allocPrint(allocator, "Authorization: Bearer {s}", .{api_key});
    defer allocator.free(auth_header);

    const result = curl.post(allocator, url, &.{
        auth_header,
        "Content-Type: application/json",
        "Accept: application/json",
    }, body) catch {
        return error.HttpError;
    };

    return .{
        .status_code = result.status_code,
        .body = result.body,
    };
}

pub fn httpGetPublic(allocator: std.mem.Allocator, url: []const u8) ![]const u8 {
    debug_log.log("httpGetPublic: {s}", .{url});
    const result = curl.get(allocator, url, &.{}) catch return error.HttpError;
    errdefer allocator.free(result.body);

    debug_log.log("httpGetPublic: {s} -> status {d}", .{ url, result.status_code });
    if (result.status_code != 200) {
        allocator.free(result.body);
        return error.HttpError;
    }

    return result.body;
}

pub fn httpGet(allocator: std.mem.Allocator, url: []const u8, api_key: []const u8) ![]const u8 {
    debug_log.log("httpGet: {s}", .{url});
    const auth_header = try std.fmt.allocPrint(allocator, "Authorization: Bearer {s}", .{api_key});
    defer allocator.free(auth_header);

    const result = curl.get(allocator, url, &.{
        auth_header,
        "Accept: application/json",
    }) catch return error.HttpError;
    errdefer allocator.free(result.body);

    debug_log.log("httpGet: {s} -> status {d}", .{ url, result.status_code });
    if (result.status_code != 200) {
        allocator.free(result.body);
        return error.HttpError;
    }

    return result.body;
}

fn parseResponse(allocator: std.mem.Allocator, body: []const u8) ![]const u8 {
    const parsed = json.parseFromSlice(json.Value, allocator, body, .{}) catch {
        printErr("error: invalid JSON response from server\n");
        return error.Explained;
    };
    defer parsed.deinit();

    const root = parsed.value;

    if (root != .object) {
        printErr("error: unexpected response format\n");
        return error.Explained;
    }

    // Check for {"error": {"code": "...", "message": "..."}}
    if (root.object.get("error")) |err_val| {
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
        printErr("error: server returned an error\n");
        return error.Explained;
    }

    // Extract {"data": ...} envelope
    const data_val = root.object.get("data") orelse {
        printErr("error: no data in response\n");
        return error.Explained;
    };

    // Serialize the data value back to JSON string
    return writeJsonValue(allocator, data_val);
}

pub fn writeJsonValue(allocator: std.mem.Allocator, value: json.Value) ![]const u8 {
    var aw: Writer.Allocating = .init(allocator);
    errdefer aw.deinit();

    writeJsonValueTo(&aw.writer, value) catch {
        printErr("error: failed to serialize response\n");
        aw.deinit();
        return error.Explained;
    };

    return aw.toOwnedSlice();
}

fn writeJsonValueTo(w: *Writer, value: json.Value) !void {
    switch (value) {
        .null => try w.writeAll("null"),
        .bool => |b| try w.writeAll(if (b) "true" else "false"),
        .integer => |i| {
            var buf: [32]u8 = undefined;
            const s = std.fmt.bufPrint(&buf, "{d}", .{i}) catch return error.OutOfMemory;
            try w.writeAll(s);
        },
        .float => |f| {
            var buf: [64]u8 = undefined;
            const s = std.fmt.bufPrint(&buf, "{d}", .{f}) catch return error.OutOfMemory;
            try w.writeAll(s);
        },
        .number_string => |s| try w.writeAll(s),
        .string => |s| {
            try w.writeByte('"');
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
            try w.writeByte('"');
        },
        .array => |arr| {
            try w.writeByte('[');
            for (arr.items, 0..) |item, i| {
                if (i > 0) try w.writeByte(',');
                try writeJsonValueTo(w, item);
            }
            try w.writeByte(']');
        },
        .object => |obj| {
            try w.writeByte('{');
            var first = true;
            var iter = obj.iterator();
            while (iter.next()) |entry| {
                if (!first) try w.writeByte(',');
                first = false;
                try w.writeByte('"');
                try w.writeAll(entry.key_ptr.*);
                try w.writeByte('"');
                try w.writeByte(':');
                try writeJsonValueTo(w, entry.value_ptr.*);
            }
            try w.writeByte('}');
        },
    }
}

pub const ApiResponse = struct {
    status_code: u16,
    body: []const u8,
};

/// Authenticated GET request that returns status code and body without printing errors.
pub fn apiGet(allocator: std.mem.Allocator, url: []const u8, api_key: []const u8) !ApiResponse {
    debug_log.log("apiGet: {s}", .{url});
    const auth_header = try std.fmt.allocPrint(allocator, "Authorization: Bearer {s}", .{api_key});
    defer allocator.free(auth_header);

    const result = curl.get(allocator, url, &.{
        auth_header,
        "Accept: application/json",
    }) catch {
        debug_log.log("apiGet: connection failed to {s}", .{url});
        return error.HttpError;
    };

    debug_log.log("apiGet: {s} -> status {d}", .{ url, result.status_code });
    return .{
        .status_code = result.status_code,
        .body = result.body,
    };
}

/// Authenticated POST request that returns status code and body without printing errors.
pub fn apiPost(allocator: std.mem.Allocator, url: []const u8, api_key: []const u8, body: []const u8) !ApiResponse {
    debug_log.log("apiPost: {s} ({d} bytes)", .{ url, body.len });
    const auth_header = try std.fmt.allocPrint(allocator, "Authorization: Bearer {s}", .{api_key});
    defer allocator.free(auth_header);

    const result = curl.post(allocator, url, &.{
        auth_header,
        "Content-Type: application/json",
        "Accept: application/json",
    }, body) catch {
        debug_log.log("apiPost: connection failed to {s}", .{url});
        return error.HttpError;
    };

    debug_log.log("apiPost: {s} -> status {d}", .{ url, result.status_code });
    return .{
        .status_code = result.status_code,
        .body = result.body,
    };
}

fn printErr(msg: []const u8) void {
    if (@import("builtin").is_test) return;
    var buf: [4096]u8 = undefined;
    var w = std.fs.File.stderr().writer(&buf);
    w.interface.writeAll(msg) catch {};
    w.interface.flush() catch {};
}

test "parseResponse success with data envelope" {
    const allocator = std.testing.allocator;
    const response =
        \\{"data":{"count":42,"name":"test"}}
    ;
    const text = try parseResponse(allocator, response);
    defer allocator.free(text);
    // Should return the serialized data object
    const reparsed = try json.parseFromSlice(json.Value, allocator, text, .{});
    defer reparsed.deinit();
    try std.testing.expectEqual(@as(i64, 42), reparsed.value.object.get("count").?.integer);
    try std.testing.expectEqualStrings("test", reparsed.value.object.get("name").?.string);
}

test "parseResponse success with string data" {
    const allocator = std.testing.allocator;
    const response =
        \\{"data":"hello world"}
    ;
    const text = try parseResponse(allocator, response);
    defer allocator.free(text);
    try std.testing.expectEqualStrings("\"hello world\"", text);
}

test "parseResponse error" {
    const allocator = std.testing.allocator;
    const response =
        \\{"error":{"code":"not_found","message":"engram not found"}}
    ;
    const result = parseResponse(allocator, response);
    try std.testing.expectError(error.Explained, result);
}

test "parseResponse success with array data" {
    const allocator = std.testing.allocator;
    const response =
        \\{"data":[1,2,3]}
    ;
    const text = try parseResponse(allocator, response);
    defer allocator.free(text);
    try std.testing.expectEqualStrings("[1,2,3]", text);
}

test "parseResponse success with null data" {
    const allocator = std.testing.allocator;
    const response =
        \\{"data":null}
    ;
    const text = try parseResponse(allocator, response);
    defer allocator.free(text);
    try std.testing.expectEqualStrings("null", text);
}

test "parseResponse success with boolean data" {
    const allocator = std.testing.allocator;
    const response =
        \\{"data":true}
    ;
    const text = try parseResponse(allocator, response);
    defer allocator.free(text);
    try std.testing.expectEqualStrings("true", text);
}

test "mcpCallTool builds tools call body" {
    const allocator = std.testing.allocator;
    const args =
        \\{"operation":"learn"}
    ;

    var aw: Writer.Allocating = .init(allocator);
    defer aw.deinit();
    var s: json.Stringify = .{ .writer = &aw.writer };
    const parsed_arguments = try json.parseFromSlice(json.Value, allocator, args, .{});
    defer parsed_arguments.deinit();
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
    try s.write("cog_memory_record");
    try s.objectField("arguments");
    try s.write(parsed_arguments.value);
    try s.endObject();
    try s.endObject();
    const body = try aw.toOwnedSlice();
    defer allocator.free(body);

    const parsed = try json.parseFromSlice(json.Value, allocator, body, .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings("tools/call", parsed.value.object.get("method").?.string);
    try std.testing.expectEqualStrings("cog_memory_record", parsed.value.object.get("params").?.object.get("name").?.string);
}
