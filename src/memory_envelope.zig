const std = @import("std");
const json = std.json;
const Writer = std.io.Writer;
const builtin = @import("builtin");
const client = @import("client.zig");
const debug_log = @import("debug_log.zig");
const session_context = @import("session_context.zig");

pub const RemoteMemoryCapabilities = struct {
    supports_assertions: bool = false,
    supports_provenance_envelopes: bool = false,
    supports_history: bool = false,
    supports_rationale_trace: bool = false,
    supports_structured_recall: bool = false,
    supports_assertion_write_proxy: bool = false,
    preferred_write_tool: ?[]const u8 = null,

    pub fn deinit(self: *RemoteMemoryCapabilities, allocator: std.mem.Allocator) void {
        if (self.preferred_write_tool) |value| allocator.free(value);
    }

    pub fn clone(self: *const RemoteMemoryCapabilities, allocator: std.mem.Allocator) !RemoteMemoryCapabilities {
        return .{
            .supports_assertions = self.supports_assertions,
            .supports_provenance_envelopes = self.supports_provenance_envelopes,
            .supports_history = self.supports_history,
            .supports_rationale_trace = self.supports_rationale_trace,
            .supports_structured_recall = self.supports_structured_recall,
            .supports_assertion_write_proxy = self.supports_assertion_write_proxy,
            .preferred_write_tool = if (self.preferred_write_tool) |value| try allocator.dupe(u8, value) else null,
        };
    }
};

pub fn isWriteTool(tool_name: []const u8) bool {
    return std.mem.eql(u8, tool_name, "mem_learn") or
        std.mem.eql(u8, tool_name, "mem_associate") or
        std.mem.eql(u8, tool_name, "mem_refactor") or
        std.mem.eql(u8, tool_name, "mem_update") or
        std.mem.eql(u8, tool_name, "mem_deprecate") or
        std.mem.eql(u8, tool_name, "mem_reinforce") or
        std.mem.eql(u8, tool_name, "mem_flush");
}

pub fn supportsEnhancedWrite(capabilities: *const RemoteMemoryCapabilities) bool {
    return capabilities.supports_provenance_envelopes and capabilities.preferred_write_tool != null;
}

pub fn registerCapabilityTool(capabilities: *RemoteMemoryCapabilities, allocator: std.mem.Allocator, remote_name: []const u8) !void {
    if (std.mem.eql(u8, remote_name, "cog_assert_record")) {
        capabilities.supports_assertions = true;
        return;
    }
    if (std.mem.eql(u8, remote_name, "cog_memory_record")) {
        capabilities.supports_provenance_envelopes = true;
        capabilities.supports_assertion_write_proxy = true;
        try setPreferredWriteTool(capabilities, allocator, remote_name);
        return;
    }
    if (std.mem.eql(u8, remote_name, "cog_assert_history")) capabilities.supports_history = true;
    if (std.mem.eql(u8, remote_name, "cog_rationale_trace")) capabilities.supports_rationale_trace = true;
    if (std.mem.eql(u8, remote_name, "cog_structured_recall")) capabilities.supports_structured_recall = true;
}

pub fn buildRemoteWriteEnvelope(
    allocator: std.mem.Allocator,
    operation: []const u8,
    semantic_payload: ?json.Value,
    session: *const session_context.SessionContext,
    write_context: *const session_context.WriteContext,
) ![]const u8 {
    var aw: Writer.Allocating = .init(allocator);
    defer aw.deinit();
    var s: json.Stringify = .{ .writer = &aw.writer };

    try s.beginObject();
    try s.objectField("operation");
    try s.write(operation);

    try s.objectField("semantic_payload");
    if (semantic_payload) |payload| {
        try s.write(payload);
    } else {
        try s.beginObject();
        try s.endObject();
    }

    try s.objectField("provenance");
    try s.beginObject();
    try s.objectField("host_agent");
    try s.write(session.host_agent_id);
    try s.objectField("host_integration");
    try s.write("cog-cli-mcp");
    try s.objectField("workspace_root");
    try s.write(session.workspace_root);
    try s.objectField("repo_root");
    if (session.repo_root) |value| try s.write(value) else try s.write(null);
    try s.objectField("repo_remote_origin");
    if (session.repo_remote_origin) |value| try s.write(value) else try s.write(null);
    try s.objectField("repo_head_sha");
    if (session.repo_head_sha) |value| try s.write(value) else try s.write(null);
    try s.objectField("cwd");
    try s.write(session.cwd);
    try s.objectField("mcp_session_id");
    try s.write(session.session_id);
    try s.objectField("client_version");
    try s.write(if (builtin.is_test) "test" else @import("build_options").version);
    try s.objectField("os");
    try s.write(@tagName(builtin.os.tag));
    try s.objectField("memory_backend");
    try s.write("hosted");
    try s.objectField("brain_url");
    try s.write(session.brain_url);
    try s.objectField("brain_namespace");
    if (session.brain_namespace) |value| try s.write(value) else try s.write(null);
    try s.objectField("brain_name");
    if (session.brain_name) |value| try s.write(value) else try s.write(null);
    try s.objectField("source_channel");
    try s.write(@tagName(write_context.source_channel));
    try s.objectField("source_details");
    try s.write(write_context.source_details);
    try s.endObject();

    try s.objectField("context_hints");
    try s.beginObject();
    try s.objectField("recent_symbols");
    try writeStringArray(&s, write_context.recent_symbols);
    try s.objectField("recent_files");
    try writeStringArray(&s, write_context.recent_files);
    try s.objectField("recent_debug_targets");
    try writeStringArray(&s, write_context.recent_debug_targets);
    try s.objectField("recent_tool_sequence");
    try writeStringArray(&s, write_context.recent_tool_sequence);
    try s.objectField("write_reason_hint");
    try s.write(@tagName(write_context.write_reason_hint));
    try s.objectField("user_provided_fact_recently");
    try s.write(write_context.user_provided_fact_recently);
    try s.objectField("memory_write_count");
    try s.write(session.memory_write_count);
    try s.objectField("code_query_count");
    try s.write(session.code_query_count);
    try s.objectField("debug_activity_count");
    try s.write(session.debug_activity_count);
    try s.endObject();
    try s.endObject();

    debug_log.log("memory_envelope.buildRemoteWriteEnvelope: operation={s} source={s}", .{ operation, @tagName(write_context.source_channel) });
    return aw.toOwnedSlice();
}

pub fn callEnhancedRemoteWrite(
    allocator: std.mem.Allocator,
    endpoint: []const u8,
    api_key: []const u8,
    session_id: ?[]const u8,
    capabilities: *const RemoteMemoryCapabilities,
    operation: []const u8,
    semantic_payload: ?json.Value,
    session: *const session_context.SessionContext,
    write_context: *const session_context.WriteContext,
) !client.McpResponse {
    const remote_tool = capabilities.preferred_write_tool orelse return error.NotSupported;
    const envelope = try buildRemoteWriteEnvelope(allocator, operation, semantic_payload, session, write_context);
    defer allocator.free(envelope);

    debug_log.log("memory_envelope.callEnhancedRemoteWrite: tool={s} operation={s}", .{ remote_tool, operation });
    return client.mcpCallTool(allocator, endpoint, api_key, session_id, remote_tool, envelope);
}

fn setPreferredWriteTool(capabilities: *RemoteMemoryCapabilities, allocator: std.mem.Allocator, remote_name: []const u8) !void {
    if (capabilities.preferred_write_tool) |value| {
        if (std.mem.eql(u8, value, remote_name)) return;
        allocator.free(value);
    }
    capabilities.preferred_write_tool = try allocator.dupe(u8, remote_name);
}

fn writeStringArray(s: *json.Stringify, strings: []const []const u8) !void {
    try s.beginArray();
    for (strings) |value| try s.write(value);
    try s.endArray();
}

test "supportsEnhancedWrite requires provenance and tool" {
    var capabilities = RemoteMemoryCapabilities{};
    defer capabilities.deinit(std.testing.allocator);
    try std.testing.expect(!supportsEnhancedWrite(&capabilities));

    try registerCapabilityTool(&capabilities, std.testing.allocator, "cog_memory_record");
    try std.testing.expect(supportsEnhancedWrite(&capabilities));
}

test "buildRemoteWriteEnvelope includes provenance and hints" {
    var repo_context = @import("repo_context.zig").RepoContext{
        .cwd = try std.testing.allocator.dupe(u8, "/tmp/project"),
        .repo_root = try std.testing.allocator.dupe(u8, "/tmp/project"),
        .repo_remote_origin = try std.testing.allocator.dupe(u8, "git@github.com:trycog/cog-cli.git"),
        .repo_head_sha = try std.testing.allocator.dupe(u8, "abc123"),
        .repo_fingerprint = null,
    };
    defer repo_context.deinit(std.testing.allocator);

    var session = try session_context.initSessionContext(
        std.testing.allocator,
        "sid-1",
        "opencode",
        "/tmp/project",
        "https://trycog.ai/acme/brain",
        "acme",
        "brain",
        &repo_context,
    );
    defer session.deinit();

    const code_args = try json.parseFromSlice(json.Value, std.testing.allocator, "{\"name\":\"Runtime\"}", .{});
    defer code_args.deinit();
    try session_context.recordToolEvent(&session, "code_query", code_args.value);

    const write_args = try json.parseFromSlice(json.Value, std.testing.allocator, "{\"term\":\"Context compiler\",\"definition\":\"because provenance should be attached at write time\"}", .{});
    defer write_args.deinit();

    var write_context = try session_context.buildWriteContext(std.testing.allocator, &session, "mem_learn", write_args.value);
    defer write_context.deinit(std.testing.allocator);

    const envelope = try buildRemoteWriteEnvelope(std.testing.allocator, "learn", write_args.value, &session, &write_context);
    defer std.testing.allocator.free(envelope);

    const parsed = try json.parseFromSlice(json.Value, std.testing.allocator, envelope, .{});
    defer parsed.deinit();
    const provenance = parsed.value.object.get("provenance") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("opencode", provenance.object.get("host_agent").?.string);
    try std.testing.expectEqualStrings("code_exploration", provenance.object.get("source_channel").?.string);

    const hints = parsed.value.object.get("context_hints") orelse return error.TestUnexpectedResult;
    try std.testing.expect(hints.object.get("recent_symbols").?.array.items.len >= 1);
    try std.testing.expectEqualStrings("rationale", hints.object.get("write_reason_hint").?.string);
}
