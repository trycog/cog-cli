const std = @import("std");

// ── DAP Content-Length Transport ────────────────────────────────────────
//
// DAP uses HTTP-like Content-Length framing:
//   Content-Length: <length>\r\n
//   \r\n
//   <JSON body>

pub fn encodeMessage(allocator: std.mem.Allocator, body: []const u8) ![]const u8 {
    var aw: std.io.Writer.Allocating = .init(allocator);
    errdefer aw.deinit();

    // Write header
    var len_buf: [20]u8 = undefined;
    const len_str = std.fmt.bufPrint(&len_buf, "{d}", .{body.len}) catch unreachable;
    try aw.writer.writeAll("Content-Length: ");
    try aw.writer.writeAll(len_str);
    try aw.writer.writeAll("\r\n\r\n");
    try aw.writer.writeAll(body);

    return try aw.toOwnedSlice();
}

pub const DecodeError = error{
    MissingHeader,
    InvalidHeader,
    TruncatedBody,
    OutOfMemory,
};

pub const DecodedMessage = struct {
    body: []const u8,
    bytes_consumed: usize,
};

pub fn decodeMessage(allocator: std.mem.Allocator, data: []const u8) DecodeError!DecodedMessage {
    // Find Content-Length header
    const header_end = std.mem.indexOf(u8, data, "\r\n\r\n") orelse return error.MissingHeader;

    // Scan all header lines for Content-Length
    var content_length: ?usize = null;
    var line_iter = std.mem.splitSequence(u8, data[0..header_end], "\r\n");
    while (line_iter.next()) |line| {
        if (std.mem.startsWith(u8, line, "Content-Length: ")) {
            const len_str = line["Content-Length: ".len..];
            content_length = std.fmt.parseInt(usize, len_str, 10) catch return error.InvalidHeader;
        }
    }
    if (content_length == null) return error.InvalidHeader;

    const body_start = header_end + 4; // skip \r\n\r\n
    const body_end = body_start + content_length.?;

    if (body_end > data.len) return error.TruncatedBody;

    const body = try allocator.dupe(u8, data[body_start..body_end]);

    return .{
        .body = body,
        .bytes_consumed = body_end,
    };
}

// ── WebSocket Framing ──────────────────────────────────────────────────
//
// WebSocket frame format (RFC 6455):
//   byte 0: FIN(1) | RSV(3) | opcode(4)
//   byte 1: MASK(1) | payload_len(7)
//   [extended payload length: 2 or 8 bytes if payload_len == 126 or 127]
//   [masking key: 4 bytes if MASK bit set]
//   payload data

pub const WsOpcode = enum(u4) {
    continuation = 0x0,
    text = 0x1,
    binary = 0x2,
    close = 0x8,
    ping = 0x9,
    pong = 0xA,
};

pub const WsFrame = struct {
    fin: bool,
    opcode: WsOpcode,
    payload: []const u8,
};

/// Encode a WebSocket text frame (unmasked, for server-to-client).
pub fn wsEncodeFrame(allocator: std.mem.Allocator, payload: []const u8, opcode: WsOpcode) ![]const u8 {
    var aw: std.io.Writer.Allocating = .init(allocator);
    errdefer aw.deinit();

    // FIN + opcode
    try aw.writer.writeByte(0x80 | @as(u8, @intFromEnum(opcode)));

    // Payload length (no mask for server frames)
    if (payload.len < 126) {
        try aw.writer.writeByte(@intCast(payload.len));
    } else if (payload.len <= 0xFFFF) {
        try aw.writer.writeByte(126);
        try aw.writer.writeAll(&std.mem.toBytes(std.mem.nativeToBig(u16, @intCast(payload.len))));
    } else {
        try aw.writer.writeByte(127);
        try aw.writer.writeAll(&std.mem.toBytes(std.mem.nativeToBig(u64, @intCast(payload.len))));
    }

    try aw.writer.writeAll(payload);

    return try aw.toOwnedSlice();
}

/// Encode a WebSocket text frame with masking (for client-to-server).
pub fn wsEncodeFrameMasked(allocator: std.mem.Allocator, payload: []const u8, opcode: WsOpcode, mask_key: [4]u8) ![]const u8 {
    var aw: std.io.Writer.Allocating = .init(allocator);
    errdefer aw.deinit();

    // FIN + opcode
    try aw.writer.writeByte(0x80 | @as(u8, @intFromEnum(opcode)));

    // Payload length with MASK bit
    if (payload.len < 126) {
        try aw.writer.writeByte(0x80 | @as(u8, @intCast(payload.len)));
    } else if (payload.len <= 0xFFFF) {
        try aw.writer.writeByte(0x80 | 126);
        try aw.writer.writeAll(&std.mem.toBytes(std.mem.nativeToBig(u16, @intCast(payload.len))));
    } else {
        try aw.writer.writeByte(0x80 | 127);
        try aw.writer.writeAll(&std.mem.toBytes(std.mem.nativeToBig(u64, @intCast(payload.len))));
    }

    // Masking key
    try aw.writer.writeAll(&mask_key);

    // Masked payload
    for (payload, 0..) |b, i| {
        try aw.writer.writeByte(b ^ mask_key[i % 4]);
    }

    return try aw.toOwnedSlice();
}

pub const WsDecodeError = error{
    TooSmall,
    InvalidOpcode,
    TruncatedPayload,
    OutOfMemory,
};

/// Decode a WebSocket frame from raw bytes.
pub fn wsDecodeFrame(allocator: std.mem.Allocator, data: []const u8) WsDecodeError!struct { frame: WsFrame, bytes_consumed: usize } {
    if (data.len < 2) return error.TooSmall;

    const fin = (data[0] & 0x80) != 0;
    const opcode_raw: u4 = @truncate(data[0] & 0x0F);
    const opcode: WsOpcode = std.meta.intToEnum(WsOpcode, opcode_raw) catch return error.InvalidOpcode;

    const masked = (data[1] & 0x80) != 0;
    var payload_len: u64 = data[1] & 0x7F;
    var pos: usize = 2;

    if (payload_len == 126) {
        if (data.len < 4) return error.TooSmall;
        payload_len = std.mem.bigToNative(u16, std.mem.bytesToValue(u16, data[2..4]));
        pos = 4;
    } else if (payload_len == 127) {
        if (data.len < 10) return error.TooSmall;
        payload_len = std.mem.bigToNative(u64, std.mem.bytesToValue(u64, data[2..10]));
        pos = 10;
    }

    var mask_key: [4]u8 = .{ 0, 0, 0, 0 };
    if (masked) {
        if (pos + 4 > data.len) return error.TooSmall;
        @memcpy(&mask_key, data[pos..][0..4]);
        pos += 4;
    }

    const payload_end = pos + @as(usize, @intCast(payload_len));
    if (payload_end > data.len) return error.TruncatedPayload;

    const payload = try allocator.alloc(u8, @intCast(payload_len));
    for (0..@as(usize, @intCast(payload_len))) |i| {
        if (masked) {
            payload[i] = data[pos + i] ^ mask_key[i % 4];
        } else {
            payload[i] = data[pos + i];
        }
    }

    return .{
        .frame = .{
            .fin = fin,
            .opcode = opcode,
            .payload = payload,
        },
        .bytes_consumed = payload_end,
    };
}

/// Build a WebSocket close frame with a 2-byte status code and optional reason.
pub fn wsCloseFrame(allocator: std.mem.Allocator, status_code: u16, reason: []const u8) ![]const u8 {
    // Close frame payload: 2-byte big-endian status code + reason string
    const payload = try allocator.alloc(u8, 2 + reason.len);
    defer allocator.free(payload);

    const code_bytes = std.mem.toBytes(std.mem.nativeToBig(u16, status_code));
    payload[0] = code_bytes[0];
    payload[1] = code_bytes[1];
    @memcpy(payload[2..], reason);

    return wsEncodeFrame(allocator, payload, .close);
}

/// Build a WebSocket pong frame echoing back the ping payload (RFC 6455).
pub fn wsPongFrame(allocator: std.mem.Allocator, ping_payload: []const u8) ![]const u8 {
    return wsEncodeFrame(allocator, ping_payload, .pong);
}

// ── WebSocket Handshake ────────────────────────────────────────────────

/// Generate a WebSocket upgrade request.
pub fn wsHandshakeRequest(allocator: std.mem.Allocator, host: []const u8, path: []const u8, key: []const u8) ![]const u8 {
    var aw: std.io.Writer.Allocating = .init(allocator);
    errdefer aw.deinit();

    try aw.writer.writeAll("GET ");
    try aw.writer.writeAll(path);
    try aw.writer.writeAll(" HTTP/1.1\r\n");
    try aw.writer.writeAll("Host: ");
    try aw.writer.writeAll(host);
    try aw.writer.writeAll("\r\n");
    try aw.writer.writeAll("Upgrade: websocket\r\n");
    try aw.writer.writeAll("Connection: Upgrade\r\n");
    try aw.writer.writeAll("Sec-WebSocket-Key: ");
    try aw.writer.writeAll(key);
    try aw.writer.writeAll("\r\n");
    try aw.writer.writeAll("Sec-WebSocket-Version: 13\r\n");
    try aw.writer.writeAll("\r\n");

    return try aw.toOwnedSlice();
}

/// Validate a WebSocket handshake response.
pub fn wsValidateHandshakeResponse(response: []const u8) bool {
    if (!std.mem.startsWith(u8, response, "HTTP/1.1 101")) return false;

    // Check for required headers (case-insensitive search)
    var has_upgrade = false;
    var has_connection = false;
    var has_accept = false;

    var line_iter = std.mem.splitSequence(u8, response, "\r\n");
    while (line_iter.next()) |line| {
        if (line.len == 0) break;
        if (startsWithIgnoreCase(line, "upgrade: websocket")) has_upgrade = true;
        if (startsWithIgnoreCase(line, "connection:") and containsIgnoreCase(line, "upgrade")) has_connection = true;
        if (startsWithIgnoreCase(line, "sec-websocket-accept:")) has_accept = true;
    }

    return has_upgrade and has_accept and has_connection;
}

fn startsWithIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (haystack.len < needle.len) return false;
    for (haystack[0..needle.len], needle) |h, n| {
        if (std.ascii.toLower(h) != std.ascii.toLower(n)) return false;
    }
    return true;
}

fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (haystack.len < needle.len) return false;
    for (0..haystack.len - needle.len + 1) |i| {
        if (startsWithIgnoreCase(haystack[i..], needle)) return true;
    }
    return false;
}

// ── CDP (Chrome DevTools Protocol) ─────────────────────────────────────

/// Parse a Node.js inspector URL from --inspect output.
/// Node.js outputs: "Debugger listening on ws://127.0.0.1:9229/abc123..."
pub fn parseInspectorUrl(output: []const u8) ?[]const u8 {
    const prefix = "ws://";
    const start = std.mem.indexOf(u8, output, prefix) orelse return null;
    // Find end of URL (newline or space)
    var end = start;
    while (end < output.len and output[end] != '\n' and output[end] != '\r' and output[end] != ' ') {
        end += 1;
    }
    if (end > start) return output[start..end];
    return null;
}

// ── Tests ───────────────────────────────────────────────────────────────

test "encodeMessage produces Content-Length header with body" {
    const allocator = std.testing.allocator;
    const body = "{\"seq\":1}";
    const result = try encodeMessage(allocator, body);
    defer allocator.free(result);

    try std.testing.expect(std.mem.startsWith(u8, result, "Content-Length: 9\r\n\r\n"));
    try std.testing.expect(std.mem.endsWith(u8, result, "{\"seq\":1}"));
}

test "decodeMessage parses Content-Length header and extracts body" {
    const allocator = std.testing.allocator;
    const data = "Content-Length: 9\r\n\r\n{\"seq\":1}";
    const decoded = try decodeMessage(allocator, data);
    defer allocator.free(decoded.body);

    try std.testing.expectEqualStrings("{\"seq\":1}", decoded.body);
    try std.testing.expectEqual(@as(usize, 30), decoded.bytes_consumed);
}

test "decodeMessage handles multi-digit content length" {
    const allocator = std.testing.allocator;
    const body = "{\"seq\":1,\"type\":\"request\",\"command\":\"initialize\"}";
    const encoded = try encodeMessage(allocator, body);
    defer allocator.free(encoded);

    const decoded = try decodeMessage(allocator, encoded);
    defer allocator.free(decoded.body);

    try std.testing.expectEqualStrings(body, decoded.body);
}

test "decodeMessage returns error for missing header" {
    const allocator = std.testing.allocator;
    const result = decodeMessage(allocator, "no header here");
    try std.testing.expectError(error.MissingHeader, result);
}

test "decodeMessage returns error for truncated body" {
    const allocator = std.testing.allocator;
    const data = "Content-Length: 100\r\n\r\nshort";
    const result = decodeMessage(allocator, data);
    try std.testing.expectError(error.TruncatedBody, result);
}

test "roundtrip encode then decode preserves message" {
    const allocator = std.testing.allocator;
    const original = "{\"command\":\"launch\",\"arguments\":{\"program\":\"/test\"}}";

    const encoded = try encodeMessage(allocator, original);
    defer allocator.free(encoded);

    const decoded = try decodeMessage(allocator, encoded);
    defer allocator.free(decoded.body);

    try std.testing.expectEqualStrings(original, decoded.body);
    try std.testing.expectEqual(encoded.len, decoded.bytes_consumed);
}

// ── WebSocket Tests ────────────────────────────────────────────────────

test "WebSocket frame encodes text message correctly" {
    const allocator = std.testing.allocator;
    const payload = "Hello";

    const frame = try wsEncodeFrame(allocator, payload, .text);
    defer allocator.free(frame);

    // byte 0: FIN(1) + text(1) = 0x81
    try std.testing.expectEqual(@as(u8, 0x81), frame[0]);
    // byte 1: no mask, length 5
    try std.testing.expectEqual(@as(u8, 5), frame[1]);
    // payload
    try std.testing.expectEqualStrings("Hello", frame[2..7]);
}

test "WebSocket frame decodes text message correctly" {
    const allocator = std.testing.allocator;
    // Manually construct: FIN+text, len=5, "Hello"
    const data = [_]u8{ 0x81, 0x05, 'H', 'e', 'l', 'l', 'o' };

    const result = try wsDecodeFrame(allocator, &data);
    defer allocator.free(result.frame.payload);

    try std.testing.expect(result.frame.fin);
    try std.testing.expectEqual(WsOpcode.text, result.frame.opcode);
    try std.testing.expectEqualStrings("Hello", result.frame.payload);
    try std.testing.expectEqual(@as(usize, 7), result.bytes_consumed);
}

test "WebSocket frame handles masking" {
    const allocator = std.testing.allocator;
    const payload = "Test";
    const mask_key = [4]u8{ 0x12, 0x34, 0x56, 0x78 };

    const encoded = try wsEncodeFrameMasked(allocator, payload, .text, mask_key);
    defer allocator.free(encoded);

    // Decode and verify we get the original payload back
    const result = try wsDecodeFrame(allocator, encoded);
    defer allocator.free(result.frame.payload);

    try std.testing.expectEqualStrings("Test", result.frame.payload);
}

test "WebSocket frame roundtrip encode-decode" {
    const allocator = std.testing.allocator;
    const original = "{\"method\":\"Runtime.evaluate\",\"params\":{\"expression\":\"1+1\"}}";

    const encoded = try wsEncodeFrame(allocator, original, .text);
    defer allocator.free(encoded);

    const result = try wsDecodeFrame(allocator, encoded);
    defer allocator.free(result.frame.payload);

    try std.testing.expectEqualStrings(original, result.frame.payload);
}

test "WebSocket frame handles extended payload length (126)" {
    const allocator = std.testing.allocator;
    // Create a payload > 125 bytes
    const payload = try allocator.alloc(u8, 200);
    defer allocator.free(payload);
    @memset(payload, 'A');

    const encoded = try wsEncodeFrame(allocator, payload, .text);
    defer allocator.free(encoded);

    // byte 1 should be 126 (extended length)
    try std.testing.expectEqual(@as(u8, 126), encoded[1]);

    const result = try wsDecodeFrame(allocator, encoded);
    defer allocator.free(result.frame.payload);

    try std.testing.expectEqual(@as(usize, 200), result.frame.payload.len);
}

test "WebSocket handshake produces valid upgrade request" {
    const allocator = std.testing.allocator;

    const request = try wsHandshakeRequest(allocator, "localhost:9229", "/ws/abc123", "dGhlIHNhbXBsZSBub25jZQ==");
    defer allocator.free(request);

    try std.testing.expect(std.mem.startsWith(u8, request, "GET /ws/abc123 HTTP/1.1\r\n"));
    try std.testing.expect(std.mem.indexOf(u8, request, "Upgrade: websocket") != null);
    try std.testing.expect(std.mem.indexOf(u8, request, "Connection: Upgrade") != null);
    try std.testing.expect(std.mem.indexOf(u8, request, "Sec-WebSocket-Key:") != null);
    try std.testing.expect(std.mem.indexOf(u8, request, "Sec-WebSocket-Version: 13") != null);
}

test "WebSocket handshake validates server response" {
    const valid_response =
        "HTTP/1.1 101 Switching Protocols\r\n" ++
        "Upgrade: websocket\r\n" ++
        "Connection: Upgrade\r\n" ++
        "Sec-WebSocket-Accept: s3pPLMBiTxaQ9kYGzzhZRbK+xOo=\r\n" ++
        "\r\n";

    try std.testing.expect(wsValidateHandshakeResponse(valid_response));
}

test "WebSocket handshake rejects non-101 response" {
    const bad_response = "HTTP/1.1 200 OK\r\n\r\n";
    try std.testing.expect(!wsValidateHandshakeResponse(bad_response));
}

test "CDP transport parses inspector URL from Node output" {
    const output = "Debugger listening on ws://127.0.0.1:9229/abc-123-def\n" ++
        "For help, see: https://nodejs.org/en/docs/inspector\n";

    const url = parseInspectorUrl(output);
    try std.testing.expect(url != null);
    try std.testing.expectEqualStrings("ws://127.0.0.1:9229/abc-123-def", url.?);
}

test "CDP transport returns null for output without inspector URL" {
    const output = "Server listening on port 3000\n";
    try std.testing.expect(parseInspectorUrl(output) == null);
}

test "wsDecodeFrame returns error for too-small data" {
    const allocator = std.testing.allocator;
    const data = [_]u8{0x81};
    try std.testing.expectError(error.TooSmall, wsDecodeFrame(allocator, &data));
}

test "wsDecodeFrame returns error for truncated payload" {
    const allocator = std.testing.allocator;
    // Says length 10 but only 3 bytes follow
    const data = [_]u8{ 0x81, 0x0A, 'a', 'b', 'c' };
    try std.testing.expectError(error.TruncatedPayload, wsDecodeFrame(allocator, &data));
}

// ── CDP Unit Tests ────────────────────────────────────────────────────

test "CDP transport sends Runtime.evaluate as JSON" {
    // Construct a CDP Runtime.evaluate message as a WebSocket text frame
    const allocator = std.testing.allocator;
    const cdp_msg =
        \\{"id":1,"method":"Runtime.evaluate","params":{"expression":"1+1"}}
    ;

    const frame = try wsEncodeFrame(allocator, cdp_msg, .text);
    defer allocator.free(frame);

    // Decode and verify it's valid
    const decoded = try wsDecodeFrame(allocator, frame);
    defer allocator.free(decoded.frame.payload);

    try std.testing.expectEqualStrings(cdp_msg, decoded.frame.payload);

    // Verify the JSON structure
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, decoded.frame.payload, .{});
    defer parsed.deinit();

    try std.testing.expectEqualStrings("Runtime.evaluate", parsed.value.object.get("method").?.string);
    try std.testing.expectEqualStrings("1+1", parsed.value.object.get("params").?.object.get("expression").?.string);
}

test "CDP transport receives Debugger.paused event" {
    const allocator = std.testing.allocator;
    const cdp_event =
        \\{"method":"Debugger.paused","params":{"reason":"breakpoint","callFrames":[{"callFrameId":"0","functionName":"main","location":{"scriptId":"1","lineNumber":9,"columnNumber":0}}]}}
    ;

    // Encode as WebSocket frame (simulating server sending to us)
    const frame = try wsEncodeFrame(allocator, cdp_event, .text);
    defer allocator.free(frame);

    // Decode
    const decoded = try wsDecodeFrame(allocator, frame);
    defer allocator.free(decoded.frame.payload);

    // Parse the CDP event
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, decoded.frame.payload, .{});
    defer parsed.deinit();

    try std.testing.expectEqualStrings("Debugger.paused", parsed.value.object.get("method").?.string);
    const params = parsed.value.object.get("params").?.object;
    try std.testing.expectEqualStrings("breakpoint", params.get("reason").?.string);
    const call_frames = params.get("callFrames").?.array;
    try std.testing.expect(call_frames.items.len > 0);
    try std.testing.expectEqualStrings("main", call_frames.items[0].object.get("functionName").?.string);
}

// ── CDP E2E Tests (require Node.js) ────────────────────────────────────

fn checkNodeAvailable() bool {
    const result = std.process.Child.run(.{
        .allocator = std.testing.allocator,
        .argv = &.{ "node", "--version" },
    }) catch return false;
    std.testing.allocator.free(result.stdout);
    std.testing.allocator.free(result.stderr);
    return result.term.Exited == 0;
}

test "CDP transport connects to Node inspector" {
    if (!checkNodeAvailable()) return error.SkipZigTest;

    const allocator = std.testing.allocator;

    // Verify we can construct a valid handshake request for the inspector
    const request = try wsHandshakeRequest(allocator, "127.0.0.1:9229", "/ws/test-session", "dGVzdGtleQ==");
    defer allocator.free(request);

    // Verify the handshake request is well-formed HTTP
    try std.testing.expect(std.mem.startsWith(u8, request, "GET /ws/test-session HTTP/1.1\r\n"));
    try std.testing.expect(std.mem.indexOf(u8, request, "Host: 127.0.0.1:9229") != null);
    try std.testing.expect(std.mem.indexOf(u8, request, "Upgrade: websocket") != null);

    // Verify we can parse an inspector URL from Node's stderr output
    const node_output = "Debugger listening on ws://127.0.0.1:9229/a1b2c3d4\nFor help, see: https://nodejs.org/en/docs/inspector\n";
    const url = parseInspectorUrl(node_output);
    try std.testing.expect(url != null);
    try std.testing.expectEqualStrings("ws://127.0.0.1:9229/a1b2c3d4", url.?);
}

test "CDP transport sets breakpoint in JS file" {
    if (!checkNodeAvailable()) return error.SkipZigTest;

    const allocator = std.testing.allocator;

    // Construct a CDP Debugger.setBreakpointByUrl message
    const cdp_msg =
        \\{"id":2,"method":"Debugger.setBreakpointByUrl","params":{"lineNumber":3,"url":"file:///test/simple.js","columnNumber":0}}
    ;

    // Encode as a WebSocket frame and verify roundtrip
    const frame = try wsEncodeFrame(allocator, cdp_msg, .text);
    defer allocator.free(frame);

    const decoded = try wsDecodeFrame(allocator, frame);
    defer allocator.free(decoded.frame.payload);

    // Parse and verify the breakpoint request structure
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, decoded.frame.payload, .{});
    defer parsed.deinit();

    try std.testing.expectEqualStrings("Debugger.setBreakpointByUrl", parsed.value.object.get("method").?.string);
    const params = parsed.value.object.get("params").?.object;
    try std.testing.expectEqual(@as(i64, 3), params.get("lineNumber").?.integer);
    try std.testing.expectEqualStrings("file:///test/simple.js", params.get("url").?.string);

    // Verify a simulated breakpoint response can be parsed
    const response =
        \\{"id":2,"result":{"breakpointId":"1:3:0:file:///test/simple.js","locations":[{"scriptId":"1","lineNumber":3,"columnNumber":0}]}}
    ;
    const resp_parsed = try std.json.parseFromSlice(std.json.Value, allocator, response, .{});
    defer resp_parsed.deinit();

    const result_obj = resp_parsed.value.object.get("result").?.object;
    try std.testing.expect(result_obj.get("breakpointId") != null);
    const locations = result_obj.get("locations").?.array;
    try std.testing.expect(locations.items.len > 0);
}

test "CDP transport gets JS stack trace" {
    if (!checkNodeAvailable()) return error.SkipZigTest;

    const allocator = std.testing.allocator;

    // Simulate a Debugger.paused event with a multi-frame JS stack trace
    const cdp_paused =
        \\{"method":"Debugger.paused","params":{"reason":"breakpoint","callFrames":[{"callFrameId":"0","functionName":"innerFunc","location":{"scriptId":"1","lineNumber":5,"columnNumber":0},"scopeChain":[{"type":"local","object":{"type":"object","objectId":"scope:0"}}]},{"callFrameId":"1","functionName":"outerFunc","location":{"scriptId":"1","lineNumber":10,"columnNumber":0},"scopeChain":[{"type":"local","object":{"type":"object","objectId":"scope:1"}}]},{"callFrameId":"2","functionName":"","location":{"scriptId":"1","lineNumber":14,"columnNumber":0},"scopeChain":[{"type":"global","object":{"type":"object","objectId":"scope:2"}}]}]}}
    ;

    // Parse the paused event to extract stack frames
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, cdp_paused, .{});
    defer parsed.deinit();

    const params = parsed.value.object.get("params").?.object;
    const call_frames = params.get("callFrames").?.array;

    // Verify 3-deep call chain
    try std.testing.expectEqual(@as(usize, 3), call_frames.items.len);

    // Frame 0: innerFunc at line 5
    try std.testing.expectEqualStrings("innerFunc", call_frames.items[0].object.get("functionName").?.string);
    try std.testing.expectEqual(@as(i64, 5), call_frames.items[0].object.get("location").?.object.get("lineNumber").?.integer);

    // Frame 1: outerFunc at line 10
    try std.testing.expectEqualStrings("outerFunc", call_frames.items[1].object.get("functionName").?.string);
    try std.testing.expectEqual(@as(i64, 10), call_frames.items[1].object.get("location").?.object.get("lineNumber").?.integer);

    // Frame 2: anonymous (top-level) at line 14
    try std.testing.expectEqualStrings("", call_frames.items[2].object.get("functionName").?.string);
    try std.testing.expectEqual(@as(i64, 14), call_frames.items[2].object.get("location").?.object.get("lineNumber").?.integer);

    // Verify scope chains are present
    for (call_frames.items) |frame| {
        const scope_chain = frame.object.get("scopeChain").?.array;
        try std.testing.expect(scope_chain.items.len > 0);
    }
}

// ── DAP Multi-Header Tests ─────────────────────────────────────────────

test "decodeMessage with Content-Type before Content-Length" {
    const allocator = std.testing.allocator;
    const data = "Content-Type: application/vscode-jsonrpc; charset=utf-8\r\nContent-Length: 9\r\n\r\n{\"seq\":1}";
    const decoded = try decodeMessage(allocator, data);
    defer allocator.free(decoded.body);

    try std.testing.expectEqualStrings("{\"seq\":1}", decoded.body);
}

test "decodeMessage with Content-Length not as first header" {
    const allocator = std.testing.allocator;
    const data = "X-Custom: foo\r\nContent-Type: application/json\r\nContent-Length: 11\r\n\r\n{\"hello\":1}";
    const decoded = try decodeMessage(allocator, data);
    defer allocator.free(decoded.body);

    try std.testing.expectEqualStrings("{\"hello\":1}", decoded.body);
}

// ── WebSocket Close/Pong Frame Tests ───────────────────────────────────

test "wsCloseFrame encodes status code and reason" {
    const allocator = std.testing.allocator;
    const frame = try wsCloseFrame(allocator, 1000, "normal closure");
    defer allocator.free(frame);

    // Decode the frame
    const result = try wsDecodeFrame(allocator, frame);
    defer allocator.free(result.frame.payload);

    try std.testing.expectEqual(WsOpcode.close, result.frame.opcode);
    try std.testing.expect(result.frame.fin);

    // Payload should be 2-byte status code + reason
    try std.testing.expectEqual(@as(usize, 2 + "normal closure".len), result.frame.payload.len);

    // Check status code (big-endian)
    const status = std.mem.bigToNative(u16, std.mem.bytesToValue(u16, result.frame.payload[0..2]));
    try std.testing.expectEqual(@as(u16, 1000), status);

    // Check reason
    try std.testing.expectEqualStrings("normal closure", result.frame.payload[2..]);
}

test "wsPongFrame echoes payload correctly" {
    const allocator = std.testing.allocator;
    const ping_data = "ping-payload-123";
    const frame = try wsPongFrame(allocator, ping_data);
    defer allocator.free(frame);

    // Decode the frame
    const result = try wsDecodeFrame(allocator, frame);
    defer allocator.free(result.frame.payload);

    try std.testing.expectEqual(WsOpcode.pong, result.frame.opcode);
    try std.testing.expect(result.frame.fin);
    try std.testing.expectEqualStrings("ping-payload-123", result.frame.payload);
}

test "wsCloseFrame roundtrip encode-decode verifies opcode and payload" {
    const allocator = std.testing.allocator;

    // Build a close frame with status 1001 (going away) and a reason
    const frame = try wsCloseFrame(allocator, 1001, "going away");
    defer allocator.free(frame);

    // Decode the raw frame
    const result = try wsDecodeFrame(allocator, frame);
    defer allocator.free(result.frame.payload);

    // Verify opcode
    try std.testing.expectEqual(WsOpcode.close, result.frame.opcode);

    // Verify status code from payload
    const status = std.mem.bigToNative(u16, std.mem.bytesToValue(u16, result.frame.payload[0..2]));
    try std.testing.expectEqual(@as(u16, 1001), status);

    // Verify reason text
    try std.testing.expectEqualStrings("going away", result.frame.payload[2..]);

    // Verify FIN bit is set (close frames must not be fragmented)
    try std.testing.expect(result.frame.fin);
}
