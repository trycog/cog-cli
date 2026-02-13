const std = @import("std");
const json = std.json;
const Writer = std.io.Writer;

pub const ClientError = error{
    Explained,
    OutOfMemory,
    HttpError,
    InvalidResponse,
};

pub fn call(
    allocator: std.mem.Allocator,
    base_url: []const u8,
    api_key: []const u8,
    action: []const u8,
    args_json: []const u8,
) ![]const u8 {
    // Construct URL: {base_url}/{action}
    const url = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ base_url, action });
    defer allocator.free(url);

    return post(allocator, url, api_key, args_json);
}

pub fn post(
    allocator: std.mem.Allocator,
    url: []const u8,
    api_key: []const u8,
    body: []const u8,
) ![]const u8 {
    // Build auth header
    const auth_value = try std.fmt.allocPrint(allocator, "Bearer {s}", .{api_key});
    defer allocator.free(auth_value);

    // Make HTTP request
    var client: std.http.Client = .{ .allocator = allocator };
    defer client.deinit();

    var response_aw: Writer.Allocating = .init(allocator);
    defer response_aw.deinit();

    const result = client.fetch(.{
        .location = .{ .url = url },
        .method = .POST,
        .payload = body,
        .extra_headers = &.{
            .{ .name = "Authorization", .value = auth_value },
            .{ .name = "Content-Type", .value = "application/json" },
            .{ .name = "Accept", .value = "application/json" },
        },
        .response_writer = &response_aw.writer,
    }) catch {
        printErr("error: failed to connect to ");
        printErr(url);
        printErr("\n");
        return error.Explained;
    };

    if (result.status != .ok and result.status != .created) {
        // Try to parse error response body for a message
        const response_body = response_aw.toOwnedSlice() catch {
            var msg_buf: [128]u8 = undefined;
            const msg = std.fmt.bufPrint(&msg_buf, "error: HTTP status {d}\n", .{@intFromEnum(result.status)}) catch "error: HTTP error\n";
            printErr(msg);
            return error.Explained;
        };
        defer allocator.free(response_body);

        if (json.parseFromSlice(json.Value, allocator, response_body, .{})) |parsed| {
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
        const msg = std.fmt.bufPrint(&msg_buf, "error: HTTP status {d}\n", .{@intFromEnum(result.status)}) catch "error: HTTP error\n";
        printErr(msg);
        return error.Explained;
    }

    const response_body = try response_aw.toOwnedSlice();
    defer allocator.free(response_body);

    return parseResponse(allocator, response_body);
}

pub const RawResponse = struct {
    status: std.http.Status,
    body: []const u8,
};

pub fn postRaw(
    allocator: std.mem.Allocator,
    url: []const u8,
    api_key: []const u8,
    body: []const u8,
) !RawResponse {
    const auth_value = try std.fmt.allocPrint(allocator, "Bearer {s}", .{api_key});
    defer allocator.free(auth_value);

    var client: std.http.Client = .{ .allocator = allocator };
    defer client.deinit();

    var response_aw: Writer.Allocating = .init(allocator);
    errdefer response_aw.deinit();

    const result = client.fetch(.{
        .location = .{ .url = url },
        .method = .POST,
        .payload = body,
        .extra_headers = &.{
            .{ .name = "Authorization", .value = auth_value },
            .{ .name = "Content-Type", .value = "application/json" },
            .{ .name = "Accept", .value = "application/json" },
        },
        .response_writer = &response_aw.writer,
    }) catch {
        return error.HttpError;
    };

    return .{
        .status = result.status,
        .body = try response_aw.toOwnedSlice(),
    };
}

pub fn httpGetPublic(allocator: std.mem.Allocator, url: []const u8) ![]const u8 {
    var http_client: std.http.Client = .{ .allocator = allocator };
    defer http_client.deinit();

    var response_aw: Writer.Allocating = .init(allocator);
    defer response_aw.deinit();

    const result = http_client.fetch(.{
        .location = .{ .url = url },
        .method = .GET,
        .response_writer = &response_aw.writer,
    }) catch return error.HttpError;

    if (result.status != .ok) return error.HttpError;

    return response_aw.toOwnedSlice();
}

pub fn httpGet(allocator: std.mem.Allocator, url: []const u8, api_key: []const u8) ![]const u8 {
    const auth_value = try std.fmt.allocPrint(allocator, "Bearer {s}", .{api_key});
    defer allocator.free(auth_value);

    var http_client: std.http.Client = .{ .allocator = allocator };
    defer http_client.deinit();

    var response_aw: Writer.Allocating = .init(allocator);
    defer response_aw.deinit();

    const result = http_client.fetch(.{
        .location = .{ .url = url },
        .method = .GET,
        .extra_headers = &.{
            .{ .name = "Authorization", .value = auth_value },
            .{ .name = "Accept", .value = "application/json" },
        },
        .response_writer = &response_aw.writer,
    }) catch return error.HttpError;

    if (result.status != .ok) return error.HttpError;

    return response_aw.toOwnedSlice();
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

fn writeJsonValue(allocator: std.mem.Allocator, value: json.Value) ![]const u8 {
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

fn printErr(msg: []const u8) void {
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
