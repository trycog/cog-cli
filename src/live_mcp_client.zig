const std = @import("std");
const debug_log = @import("debug_log.zig");

pub const QueryMode = enum {
    find,
    refs,
    symbols,

    pub fn parse(raw: []const u8) !QueryMode {
        if (std.mem.eql(u8, raw, "find")) return .find;
        if (std.mem.eql(u8, raw, "refs")) return .refs;
        if (std.mem.eql(u8, raw, "symbols")) return .symbols;
        return error.InvalidQueryMode;
    }

    pub fn parameterName(mode: QueryMode) []const u8 {
        return switch (mode) {
            .find, .refs => "name",
            .symbols => "file",
        };
    }
};

pub fn buildCodeQueryRequest(
    allocator: std.mem.Allocator,
    mode: QueryMode,
    query: []const u8,
) ![]u8 {
    var output: std.io.Writer.Allocating = .init(allocator);
    defer output.deinit();

    var json_writer: std.json.Stringify = .{ .writer = &output.writer };
    try json_writer.beginObject();
    try json_writer.objectField("jsonrpc");
    try json_writer.write("2.0");
    try json_writer.objectField("id");
    try json_writer.write(@as(u8, 1));
    try json_writer.objectField("method");
    try json_writer.write("tools/call");
    try json_writer.objectField("params");
    try json_writer.beginObject();
    try json_writer.objectField("name");
    try json_writer.write("code_query");
    try json_writer.objectField("arguments");
    try json_writer.beginObject();
    try json_writer.objectField("mode");
    try json_writer.write(@tagName(mode));
    try json_writer.objectField(mode.parameterName());
    try json_writer.write(query);
    try json_writer.endObject();
    try json_writer.endObject();
    try json_writer.endObject();
    try output.writer.writeByte('\n');
    return output.toOwnedSlice();
}

pub fn parseToolTextResponse(
    allocator: std.mem.Allocator,
    response: []const u8,
) ![]u8 {
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, response, .{}) catch {
        return error.InvalidMcpResponse;
    };
    defer parsed.deinit();

    if (parsed.value != .object) return error.InvalidMcpResponse;
    const result = parsed.value.object.get("result") orelse return error.InvalidMcpResponse;
    if (result != .object) return error.InvalidMcpResponse;

    if (result.object.get("isError")) |is_error| {
        if (is_error != .bool) return error.InvalidMcpResponse;
        if (is_error.bool) return error.McpToolError;
    }

    const content = result.object.get("content") orelse return error.InvalidMcpResponse;
    if (content != .array or content.array.items.len == 0) return error.InvalidMcpResponse;
    const first = content.array.items[0];
    if (first != .object) return error.InvalidMcpResponse;
    const content_type = first.object.get("type") orelse return error.InvalidMcpResponse;
    const text = first.object.get("text") orelse return error.InvalidMcpResponse;
    if (content_type != .string or !std.mem.eql(u8, content_type.string, "text")) {
        return error.InvalidMcpResponse;
    }
    if (text != .string or text.string.len == 0) return error.InvalidMcpResponse;
    return allocator.dupe(u8, text.string);
}

pub fn isUsableToolOutput(output: []const u8) bool {
    const trimmed = std.mem.trim(u8, output, " \t\r\n");
    if (trimmed.len == 0) return false;

    const failure_markers = [_][]const u8{
        "error:",
        "usage:",
        "no results",
        "not found",
        "removed from cli",
        "index unavailable",
    };
    for (failure_markers) |marker| {
        if (containsIgnoreCase(trimmed, marker)) return false;
    }
    return true;
}

fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (needle.len > haystack.len) return false;
    var start: usize = 0;
    while (start + needle.len <= haystack.len) : (start += 1) {
        var matched = true;
        for (haystack[start .. start + needle.len], needle) |actual, expected| {
            if (std.ascii.toLower(actual) != std.ascii.toLower(expected)) {
                matched = false;
                break;
            }
        }
        if (matched) return true;
    }
    return false;
}

pub fn childExitedSuccessfully(term: std.process.Child.Term) bool {
    return switch (term) {
        .Exited => |code| code == 0,
        else => false,
    };
}

const StderrDrainer = struct {
    file: std.fs.File,

    fn run(self: StderrDrainer) void {
        defer self.file.close();
        var buffer: [4096]u8 = undefined;
        while (self.file.read(&buffer) catch return != 0) {}
    }
};

pub fn runCodeQuery(
    allocator: std.mem.Allocator,
    cog_path: []const u8,
    cwd: []const u8,
    raw_mode: []const u8,
    query: []const u8,
) ![]u8 {
    const mode = try QueryMode.parse(raw_mode);
    const request = try buildCodeQueryRequest(allocator, mode, query);
    defer allocator.free(request);

    debug_log.log("live MCP query: spawning Cog MCP in {s}", .{cwd});
    var child = std.process.Child.init(&.{ cog_path, "mcp" }, allocator);
    child.cwd = cwd;
    child.stdin_behavior = .Pipe;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;
    try child.spawn();

    var waited = false;
    defer if (!waited) {
        _ = child.kill() catch {};
        _ = child.wait() catch {};
    };

    const stderr_file = child.stderr.?;
    child.stderr = null;
    const stderr_thread = std.Thread.spawn(.{}, StderrDrainer.run, .{StderrDrainer{ .file = stderr_file }}) catch |err| {
        stderr_file.close();
        return err;
    };
    defer stderr_thread.join();

    const child_stdin = child.stdin.?;
    child.stdin = null;
    var stdin_open = true;
    defer if (stdin_open) child_stdin.close();
    debug_log.log("live MCP query: writing code_query request", .{});
    try child_stdin.writeAll(request);
    child_stdin.close();
    stdin_open = false;

    const child_stdout = child.stdout.?;
    child.stdout = null;
    defer child_stdout.close();
    const response = try child_stdout.readToEndAlloc(allocator, 64 * 1024);
    errdefer allocator.free(response);

    const term = try child.wait();
    waited = true;
    if (!childExitedSuccessfully(term)) {
        debug_log.log("live MCP query: Cog MCP exited with {s}", .{@tagName(term)});
        return error.McpProcessFailed;
    }
    debug_log.log("live MCP query: received {d} response bytes", .{response.len});

    const text = try parseToolTextResponse(allocator, response);
    allocator.free(response);
    return text;
}

test "query modes match current MCP code_query contract" {
    try std.testing.expectEqual(QueryMode.find, try QueryMode.parse("find"));
    try std.testing.expectEqual(QueryMode.refs, try QueryMode.parse("refs"));
    try std.testing.expectEqual(QueryMode.symbols, try QueryMode.parse("symbols"));
    try std.testing.expectError(error.InvalidQueryMode, QueryMode.parse("--find"));

    try std.testing.expectEqualStrings("name", QueryMode.find.parameterName());
    try std.testing.expectEqualStrings("name", QueryMode.refs.parameterName());
    try std.testing.expectEqualStrings("file", QueryMode.symbols.parameterName());
}

test "MCP code query request uses mode-specific parameters" {
    const find_request = try buildCodeQueryRequest(std.testing.allocator, .find, "resolveDispatcher");
    defer std.testing.allocator.free(find_request);
    const parsed_find = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, find_request, .{});
    defer parsed_find.deinit();
    const find_arguments = parsed_find.value.object.get("params").?.object.get("arguments").?.object;
    try std.testing.expectEqualStrings("resolveDispatcher", find_arguments.get("name").?.string);
    try std.testing.expect(find_arguments.get("file") == null);

    const symbols_request = try buildCodeQueryRequest(std.testing.allocator, .symbols, "packages/react/src/ReactHooks.js");
    defer std.testing.allocator.free(symbols_request);
    const parsed_symbols = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, symbols_request, .{});
    defer parsed_symbols.deinit();
    const symbols_arguments = parsed_symbols.value.object.get("params").?.object.get("arguments").?.object;
    try std.testing.expectEqualStrings("packages/react/src/ReactHooks.js", symbols_arguments.get("file").?.string);
    try std.testing.expect(symbols_arguments.get("name") == null);
}

test "MCP response parser rejects tool errors and malformed content" {
    const success =
        \\{"jsonrpc":"2.0","id":1,"result":{"content":[{"type":"text","text":"definition found"}],"isError":false}}
    ;
    const text = try parseToolTextResponse(std.testing.allocator, success);
    defer std.testing.allocator.free(text);
    try std.testing.expectEqualStrings("definition found", text);

    const tool_error =
        \\{"jsonrpc":"2.0","id":1,"result":{"content":[{"type":"text","text":"Code index unavailable"}],"isError":true}}
    ;
    try std.testing.expectError(error.McpToolError, parseToolTextResponse(std.testing.allocator, tool_error));

    const malformed =
        \\{"jsonrpc":"2.0","id":1,"result":{"content":[]}}
    ;
    try std.testing.expectError(error.InvalidMcpResponse, parseToolTextResponse(std.testing.allocator, malformed));
}

test "tool-output assertions reject command failure text" {
    try std.testing.expect(isUsableToolOutput("definition found at src/file.zig:12"));
    try std.testing.expect(!isUsableToolOutput(""));
    try std.testing.expect(!isUsableToolOutput("error: invalid command"));
    try std.testing.expect(!isUsableToolOutput("Usage: cog code:query"));
    try std.testing.expect(!isUsableToolOutput("No results found."));
    try std.testing.expect(!isUsableToolOutput("symbol not found"));
}

test "child success requires a zero exit code" {
    try std.testing.expect(childExitedSuccessfully(.{ .Exited = 0 }));
    try std.testing.expect(!childExitedSuccessfully(.{ .Exited = 1 }));
    try std.testing.expect(!childExitedSuccessfully(.{ .Signal = 9 }));
}
