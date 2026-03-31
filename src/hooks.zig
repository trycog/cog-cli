const std = @import("std");
const json = std.json;
const Stringify = json.Stringify;
const Writer = std.io.Writer;
const agents_mod = @import("agents.zig");
const build_options = @import("build_options");
const debug_log = @import("debug_log.zig");

// ANSI styles
const cyan = "\x1B[36m";
const bold = "\x1B[1m";
const dim = "\x1B[2m";
const reset = "\x1B[0m";

// ── Helpers ─────────────────────────────────────────────────────────────

fn printErr(msg: []const u8) void {
    var buf: [4096]u8 = undefined;
    var w = std.fs.File.stderr().writer(&buf);
    w.interface.writeAll(msg) catch {};
    w.interface.flush() catch {};
}

fn ensureDir(path: []const u8) !void {
    std.fs.cwd().makePath(path) catch {
        printErr("  error: failed to create directory ");
        printErr(path);
        printErr("\n");
        return error.Explained;
    };
}

fn writeCwdFile(filename: []const u8, content: []const u8) !void {
    const file = std.fs.cwd().createFile(filename, .{}) catch {
        printErr("  error: failed to write ");
        printErr(filename);
        printErr("\n");
        return error.Explained;
    };
    defer file.close();
    var write_buf: [4096]u8 = undefined;
    var fw = file.writer(&write_buf);
    fw.interface.writeAll(content) catch {
        printErr("  error: failed to write ");
        printErr(filename);
        printErr("\n");
        return error.Explained;
    };
    fw.interface.flush() catch {
        printErr("  error: failed to write ");
        printErr(filename);
        printErr("\n");
        return error.Explained;
    };
}

pub fn fileExistsInCwd(path: []const u8) bool {
    const f = std.fs.cwd().openFile(path, .{}) catch return false;
    f.close();
    return true;
}

fn readCwdFile(allocator: std.mem.Allocator, filename: []const u8) ?[]const u8 {
    const f = std.fs.cwd().openFile(filename, .{}) catch return null;
    defer f.close();
    return f.readToEndAlloc(allocator, 1048576) catch return null;
}

// ── MCP Config Generation ───────────────────────────────────────────────

pub fn configureMcp(allocator: std.mem.Allocator, agent: agents_mod.Agent) !void {
    const mcp_path = agent.mcp_path orelse return;

    switch (agent.mcp_format) {
        .json_mcpServers => try writeJsonMcp(allocator, mcp_path, "mcpServers"),
        .json_servers => try writeJsonMcp(allocator, mcp_path, "servers"),
        .json_amp => try writeJsonAmp(allocator, mcp_path),
        .json_mcp => try writeJsonOpenCode(allocator, mcp_path),
        .json_pi => try writeJsonPi(allocator, mcp_path),
        .toml => try writeTomlMcp(allocator, mcp_path),
        .global_only => printGlobalMcpInstructions(agent),
    }
}

fn writeJsonMcp(allocator: std.mem.Allocator, path: []const u8, key: []const u8) !void {
    // Ensure parent directory exists
    if (std.fs.path.dirname(path)) |parent| {
        try ensureDir(parent);
    }

    const existing = readCwdFile(allocator, path);
    defer if (existing) |e| allocator.free(e);

    var aw: Writer.Allocating = .init(allocator);
    defer aw.deinit();
    var s: Stringify = .{ .writer = &aw.writer, .options = .{ .whitespace = .indent_2 } };
    try s.beginObject();

    if (existing) |content| {
        if (json.parseFromSlice(json.Value, allocator, content, .{})) |parsed| {
            defer parsed.deinit();
            if (parsed.value == .object) {
                var iter = parsed.value.object.iterator();
                while (iter.next()) |entry| {
                    if (std.mem.eql(u8, entry.key_ptr.*, key)) continue;
                    try s.objectField(entry.key_ptr.*);
                    try s.write(entry.value_ptr.*);
                }
            }
        } else |_| {}
    }

    try s.objectField(key);
    try s.beginObject();

    // Preserve existing entries under the key, except "cog"
    if (existing) |content| {
        if (json.parseFromSlice(json.Value, allocator, content, .{})) |parsed| {
            defer parsed.deinit();
            if (parsed.value == .object) {
                if (parsed.value.object.get(key)) |servers| {
                    if (servers == .object) {
                        var iter = servers.object.iterator();
                        while (iter.next()) |entry| {
                            if (std.mem.eql(u8, entry.key_ptr.*, "cog")) continue;
                            try s.objectField(entry.key_ptr.*);
                            try s.write(entry.value_ptr.*);
                        }
                    }
                }
            }
        } else |_| {}
    }

    const include_stdio_type = std.mem.eql(u8, path, ".mcp.json") or
        std.mem.eql(u8, path, ".cursor/mcp.json") or
        std.mem.eql(u8, path, ".roo/mcp.json");

    // Add cog server entry
    try s.objectField("cog");
    try s.beginObject();
    // For hosts using standard MCP server config, include "type": "stdio"
    if (std.mem.eql(u8, key, "servers") or include_stdio_type) {
        try s.objectField("type");
        try s.write("stdio");
    }
    try s.objectField("command");
    try s.write("cog");
    try s.objectField("args");
    try s.beginArray();
    try s.write("mcp");
    try s.endArray();
    try s.endObject();

    try s.endObject(); // close key object
    try s.endObject(); // close root

    const new_content = try aw.toOwnedSlice();
    defer allocator.free(new_content);
    try writeCwdFile(path, new_content);
}

fn writeJsonPi(allocator: std.mem.Allocator, path: []const u8) !void {
    debug_log.log("hooks.writeJsonPi: path={s}", .{path});
    if (std.fs.path.dirname(path)) |parent| {
        try ensureDir(parent);
    }

    const existing = readCwdFile(allocator, path);
    defer if (existing) |e| allocator.free(e);

    var aw: Writer.Allocating = .init(allocator);
    defer aw.deinit();
    var s: Stringify = .{ .writer = &aw.writer, .options = .{ .whitespace = .indent_2 } };
    try s.beginObject();

    // Preserve existing top-level keys except mcpServers
    if (existing) |content| {
        if (json.parseFromSlice(json.Value, allocator, content, .{})) |parsed| {
            defer parsed.deinit();
            if (parsed.value == .object) {
                var iter = parsed.value.object.iterator();
                while (iter.next()) |entry| {
                    if (std.mem.eql(u8, entry.key_ptr.*, "mcpServers")) continue;
                    try s.objectField(entry.key_ptr.*);
                    try s.write(entry.value_ptr.*);
                }
            }
        } else |_| {}
    }

    try s.objectField("mcpServers");
    try s.beginObject();

    // Preserve existing servers except cog
    if (existing) |content| {
        if (json.parseFromSlice(json.Value, allocator, content, .{})) |parsed| {
            defer parsed.deinit();
            if (parsed.value == .object) {
                if (parsed.value.object.get("mcpServers")) |servers| {
                    if (servers == .object) {
                        var iter = servers.object.iterator();
                        while (iter.next()) |entry| {
                            if (std.mem.eql(u8, entry.key_ptr.*, "cog")) continue;
                            try s.objectField(entry.key_ptr.*);
                            try s.write(entry.value_ptr.*);
                        }
                    }
                }
            }
        } else |_| {}
    }

    // Add cog server entry with directTools so Pi registers tools individually
    // instead of routing through the mcp() proxy.
    try s.objectField("cog");
    try s.beginObject();
    try s.objectField("command");
    try s.write("cog");
    try s.objectField("args");
    try s.beginArray();
    try s.write("mcp");
    try s.endArray();
    try s.objectField("directTools");
    try s.write(true);
    try s.endObject();

    try s.endObject(); // close mcpServers
    try s.endObject(); // close root

    const new_content = try aw.toOwnedSlice();
    defer allocator.free(new_content);
    try writeCwdFile(path, new_content);
}

fn writeJsonAmp(allocator: std.mem.Allocator, path: []const u8) !void {
    if (std.fs.path.dirname(path)) |parent| {
        try ensureDir(parent);
    }

    const existing = readCwdFile(allocator, path);
    defer if (existing) |e| allocator.free(e);

    var aw: Writer.Allocating = .init(allocator);
    defer aw.deinit();
    var s: Stringify = .{ .writer = &aw.writer, .options = .{ .whitespace = .indent_2 } };
    try s.beginObject();

    if (existing) |content| {
        if (json.parseFromSlice(json.Value, allocator, content, .{})) |parsed| {
            defer parsed.deinit();
            if (parsed.value == .object) {
                var iter = parsed.value.object.iterator();
                while (iter.next()) |entry| {
                    if (std.mem.eql(u8, entry.key_ptr.*, "amp.mcpServers")) continue;
                    try s.objectField(entry.key_ptr.*);
                    try s.write(entry.value_ptr.*);
                }
            }
        } else |_| {}
    }

    try s.objectField("amp.mcpServers");
    try s.beginObject();
    try s.objectField("cog");
    try s.beginObject();
    try s.objectField("command");
    try s.write("cog");
    try s.objectField("args");
    try s.beginArray();
    try s.write("mcp");
    try s.endArray();
    try s.endObject();
    try s.endObject();

    try s.endObject();

    const new_content = try aw.toOwnedSlice();
    defer allocator.free(new_content);
    try writeCwdFile(path, new_content);
}

fn writeJsonOpenCode(allocator: std.mem.Allocator, path: []const u8) !void {
    debug_log.log("hooks.writeJsonOpenCode: path={s}", .{path});
    const existing = readCwdFile(allocator, path);
    defer if (existing) |e| allocator.free(e);

    var aw: Writer.Allocating = .init(allocator);
    defer aw.deinit();
    var s: Stringify = .{ .writer = &aw.writer, .options = .{ .whitespace = .indent_2 } };
    try s.beginObject();

    if (existing) |content| {
        if (json.parseFromSlice(json.Value, allocator, content, .{})) |parsed| {
            defer parsed.deinit();
            if (parsed.value == .object) {
                var iter = parsed.value.object.iterator();
                while (iter.next()) |entry| {
                    if (std.mem.eql(u8, entry.key_ptr.*, "mcp") or std.mem.eql(u8, entry.key_ptr.*, "plugin")) continue;
                    try s.objectField(entry.key_ptr.*);
                    try s.write(entry.value_ptr.*);
                }
            }
        } else |_| {}
    }

    try s.objectField("mcp");
    try s.beginObject();

    if (existing) |content| {
        if (json.parseFromSlice(json.Value, allocator, content, .{})) |parsed| {
            defer parsed.deinit();
            if (parsed.value == .object) {
                if (parsed.value.object.get("mcp")) |mcp| {
                    if (mcp == .object) {
                        var iter = mcp.object.iterator();
                        while (iter.next()) |entry| {
                            if (std.mem.eql(u8, entry.key_ptr.*, "cog")) continue;
                            try s.objectField(entry.key_ptr.*);
                            try s.write(entry.value_ptr.*);
                        }
                    }
                }
            }
        } else |_| {}
    }

    try s.objectField("cog");
    try s.beginObject();
    try s.objectField("type");
    try s.write("local");
    try s.objectField("command");
    try s.beginArray();
    try s.write("cog");
    try s.write("mcp");
    try s.endArray();
    try s.endObject();
    try s.endObject();

    try s.objectField("plugin");
    try s.beginArray();

    var already_has_override = false;
    var already_has_memory = false;
    var already_has_debug = false;
    if (existing) |content| {
        if (json.parseFromSlice(json.Value, allocator, content, .{})) |parsed| {
            defer parsed.deinit();
            if (parsed.value == .object) {
                if (parsed.value.object.get("plugin")) |plugins| {
                    if (plugins == .array) {
                        for (plugins.array.items) |item| {
                            if (item == .string and std.mem.eql(u8, item.string, "cog-override")) {
                                already_has_override = true;
                            }
                            if (item == .string and std.mem.eql(u8, item.string, "cog-memory")) {
                                already_has_memory = true;
                            }
                            if (item == .string and std.mem.eql(u8, item.string, "cog-debug")) {
                                already_has_debug = true;
                            }
                            try s.write(item);
                        }
                    }
                }
            }
        } else |_| {}
    }

    if (!already_has_override) {
        try s.write("cog-override");
    }
    if (!already_has_memory) {
        try s.write("cog-memory");
    }
    if (!already_has_debug) {
        try s.write("cog-debug");
    }

    try s.endArray();

    try s.endObject();

    const new_content = try aw.toOwnedSlice();
    defer allocator.free(new_content);
    try writeCwdFile(path, new_content);
}

fn writeTomlMcp(allocator: std.mem.Allocator, path: []const u8) !void {
    if (std.fs.path.dirname(path)) |parent| {
        try ensureDir(parent);
    }

    const existing = readCwdFile(allocator, path);
    defer if (existing) |e| allocator.free(e);

    const toml_section = "\n[mcp_servers.cog]\ncommand = \"cog\"\nargs = [\"mcp\"]\n";

    if (existing) |content| {
        // Check if already has [mcp_servers.cog]
        if (std.mem.indexOf(u8, content, "[mcp_servers.cog]") != null) return;

        // Append
        const new_content = try std.fmt.allocPrint(allocator, "{s}{s}", .{ content, toml_section });
        defer allocator.free(new_content);
        try writeCwdFile(path, new_content);
    } else {
        try writeCwdFile(path, toml_section);
    }
}

fn printGlobalMcpInstructions(agent: agents_mod.Agent) void {
    printErr("  " ++ dim ++ "Note: ");
    printErr(agent.display_name);
    printErr(" requires global MCP configuration.\n");
    if (std.mem.eql(u8, agent.id, "windsurf")) {
        printErr("  Add to ~/.codeium/windsurf/mcp_config.json" ++ reset ++ "\n");
    } else if (std.mem.eql(u8, agent.id, "goose")) {
        printErr("  Add to ~/.config/goose/config.yaml" ++ reset ++ "\n");
    }
}

// ── Tool Permissions ────────────────────────────────────────────────────

pub fn configureToolPermissions(allocator: std.mem.Allocator, agent: agents_mod.Agent) !void {
    debug_log.log("hooks.configureToolPermissions: agent={s}", .{agent.id});
    if (!agent.capabilities().auto_tool_permissions) return;

    if (std.mem.eql(u8, agent.id, "claude_code")) {
        try writeClaudePermissions(allocator);
    } else if (std.mem.eql(u8, agent.id, "gemini")) {
        try writeGeminiTrust(allocator, agent.mcp_path.?);
    } else if (std.mem.eql(u8, agent.id, "amp")) {
        try writeAmpPermissions(allocator, agent.mcp_path.?);
    } else if (std.mem.eql(u8, agent.id, "opencode")) {
        try writeOpenCodePermissions(allocator, agent.mcp_path.?);
    }
}

pub const RuntimePolicyAsset = struct {
    path: []const u8,
    content: []const u8,
};

const opencode_runtime_policy_assets = [_]RuntimePolicyAsset{
    .{ .path = ".opencode/plugins/cog-override.ts", .content = opencode_override_content },
    .{ .path = ".opencode/plugins/cog-memory.ts", .content = opencode_memory_content },
    .{ .path = ".opencode/plugins/cog-debug.ts", .content = opencode_debug_content },
};

const claude_runtime_policy_assets = [_]RuntimePolicyAsset{
    .{ .path = ".claude/hooks/cog-pretooluse.sh", .content = claude_pretooluse_hook_content },
    .{ .path = ".claude/hooks/cog-stop-memory.sh", .content = claude_stop_memory_hook_content },
    .{ .path = ".claude/hooks/cog-posttooluse-failure.sh", .content = claude_posttooluse_failure_hook_content },
    .{ .path = ".claude/hooks/cog-precompact.sh", .content = claude_precompact_hook_content },
};

const gemini_runtime_policy_assets = [_]RuntimePolicyAsset{
    .{ .path = ".gemini/hooks/cog-before-tool.sh", .content = gemini_before_tool_hook_content },
};

const amp_runtime_policy_assets = [_]RuntimePolicyAsset{
    .{ .path = ".amp/plugins/cog.ts", .content = amp_cog_plugin_content },
};

const pi_runtime_policy_assets = [_]RuntimePolicyAsset{
    .{ .path = ".pi/extensions/cog.ts", .content = pi_cog_extension_content },
};

pub fn runtimePolicyAssets(agent: agents_mod.Agent) []const RuntimePolicyAsset {
    if (std.mem.eql(u8, agent.id, "claude_code")) {
        return &claude_runtime_policy_assets;
    }

    if (std.mem.eql(u8, agent.id, "gemini")) {
        return &gemini_runtime_policy_assets;
    }

    if (std.mem.eql(u8, agent.id, "amp")) {
        return &amp_runtime_policy_assets;
    }

    if (std.mem.eql(u8, agent.id, "pi")) {
        return &pi_runtime_policy_assets;
    }

    if (agent.capabilities().runtime_policy_plugins and std.mem.eql(u8, agent.id, "opencode")) {
        return &opencode_runtime_policy_assets;
    }

    return &.{};
}

pub fn configureRuntimePolicyFile(agent: agents_mod.Agent, asset_path: []const u8) !void {
    debug_log.log("hooks.configureRuntimePolicyFile: agent={s} path={s}", .{ agent.id, asset_path });
    if (runtimePolicyAssets(agent).len == 0) return;

    for (runtimePolicyAssets(agent)) |asset| {
        if (std.mem.eql(u8, asset.path, asset_path)) {
            try writeRuntimePolicyAsset(asset.path, asset.content);
            return;
        }
    }
}

pub fn configureRuntimePolicy(allocator: std.mem.Allocator, agent: agents_mod.Agent) !void {
    debug_log.log("hooks.configureRuntimePolicy: agent={s}", .{agent.id});
    if (std.mem.eql(u8, agent.id, "claude_code")) {
        try writeClaudeRuntimeHooks(allocator);
    } else if (std.mem.eql(u8, agent.id, "gemini")) {
        try writeGeminiRuntimeHooks(allocator, agent.mcp_path.?);
    }
}

fn writeClaudePermissions(allocator: std.mem.Allocator) !void {
    debug_log.log("hooks.writeClaudePermissions", .{});
    const path = ".claude/settings.json";
    try ensureDir(".claude");

    const existing = readCwdFile(allocator, path);
    defer if (existing) |e| allocator.free(e);

    var aw: Writer.Allocating = .init(allocator);
    defer aw.deinit();
    var s: Stringify = .{ .writer = &aw.writer, .options = .{ .whitespace = .indent_2 } };
    try s.beginObject();

    var existing_allow: ?json.Value = null;
    var existing_perms: ?json.Value = null;
    var existing_enabled_mcpjson_servers: ?json.Value = null;
    var parsed_holder: ?json.Parsed(json.Value) = null;
    defer if (parsed_holder) |p| p.deinit();

    if (existing) |content| {
        if (json.parseFromSlice(json.Value, allocator, content, .{})) |parsed| {
            parsed_holder = parsed;
            if (parsed.value == .object) {
                // Copy all non-permissions top-level keys
                var iter = parsed.value.object.iterator();
                while (iter.next()) |entry| {
                    if (std.mem.eql(u8, entry.key_ptr.*, "permissions")) continue;
                    if (std.mem.eql(u8, entry.key_ptr.*, "enabledMcpjsonServers")) continue;
                    try s.objectField(entry.key_ptr.*);
                    try s.write(entry.value_ptr.*);
                }
                // Capture existing permissions
                if (parsed.value.object.get("permissions")) |perms| {
                    existing_perms = perms;
                    if (perms == .object) {
                        if (perms.object.get("allow")) |allow| {
                            existing_allow = allow;
                        }
                    }
                }
                if (parsed.value.object.get("enabledMcpjsonServers")) |enabled| {
                    existing_enabled_mcpjson_servers = enabled;
                }
            }
        } else |_| {}
    }

    try s.objectField("permissions");
    try s.beginObject();

    // Copy non-allow keys from existing permissions (e.g. deny)
    if (existing_perms) |perms| {
        if (perms == .object) {
            var iter = perms.object.iterator();
            while (iter.next()) |entry| {
                if (std.mem.eql(u8, entry.key_ptr.*, "allow")) continue;
                try s.objectField(entry.key_ptr.*);
                try s.write(entry.value_ptr.*);
            }
        }
    }

    // Write allow array, preserving existing entries + adding mcp__cog__*
    try s.objectField("allow");
    try s.beginArray();

    const cog_pattern = "mcp__cog__*";
    var already_has_cog = false;

    if (existing_allow) |allow| {
        if (allow == .array) {
            for (allow.array.items) |item| {
                if (item == .string) {
                    if (std.mem.eql(u8, item.string, cog_pattern)) {
                        already_has_cog = true;
                    }
                }
                try s.write(item);
            }
        }
    }

    if (!already_has_cog) {
        try s.write(cog_pattern);
    }

    try s.endArray();
    try s.endObject(); // permissions

    try s.objectField("enabledMcpjsonServers");
    try s.beginArray();

    var already_enabled_cog_server = false;
    if (existing_enabled_mcpjson_servers) |enabled| {
        if (enabled == .array) {
            for (enabled.array.items) |item| {
                if (item == .string and std.mem.eql(u8, item.string, "cog")) {
                    already_enabled_cog_server = true;
                }
                try s.write(item);
            }
        }
    }

    if (!already_enabled_cog_server) {
        try s.write("cog");
    }

    try s.endArray();
    try s.endObject(); // root

    const new_content = try aw.toOwnedSlice();
    defer allocator.free(new_content);
    try writeCwdFile(path, new_content);
}

fn writeClaudeRuntimeHooks(allocator: std.mem.Allocator) !void {
    debug_log.log("hooks.writeClaudeRuntimeHooks", .{});
    const path = ".claude/settings.json";
    try ensureDir(".claude/hooks");

    const existing = readCwdFile(allocator, path);
    defer if (existing) |e| allocator.free(e);

    var parsed_holder: ?json.Parsed(json.Value) = null;
    defer if (parsed_holder) |p| p.deinit();

    var existing_hooks: ?json.Value = null;
    if (existing) |content| {
        if (json.parseFromSlice(json.Value, allocator, content, .{})) |parsed| {
            parsed_holder = parsed;
            if (parsed.value == .object) {
                existing_hooks = parsed.value.object.get("hooks");
            }
        } else |_| {}
    }

    var aw: Writer.Allocating = .init(allocator);
    defer aw.deinit();
    var s: Stringify = .{ .writer = &aw.writer, .options = .{ .whitespace = .indent_2 } };
    try s.beginObject();

    if (parsed_holder) |parsed| {
        if (parsed.value == .object) {
            var iter = parsed.value.object.iterator();
            while (iter.next()) |entry| {
                if (std.mem.eql(u8, entry.key_ptr.*, "hooks")) continue;
                try s.objectField(entry.key_ptr.*);
                try s.write(entry.value_ptr.*);
            }
        }
    }

    try s.objectField("hooks");
    try s.beginObject();

    var wrote_pretooluse = false;
    var wrote_stop = false;
    var wrote_posttooluse_failure = false;
    var wrote_precompact = false;
    if (existing_hooks) |hooks| {
        if (hooks == .object) {
            var iter = hooks.object.iterator();
            while (iter.next()) |entry| {
                if (std.mem.eql(u8, entry.key_ptr.*, "PreToolUse")) {
                    wrote_pretooluse = true;
                    try s.objectField("PreToolUse");
                    try writeClaudePreToolUseHookArray(&s, entry.value_ptr.*);
                } else if (std.mem.eql(u8, entry.key_ptr.*, "Stop")) {
                    wrote_stop = true;
                    try s.objectField("Stop");
                    try writeClaudeStopHookArray(&s, entry.value_ptr.*);
                } else if (std.mem.eql(u8, entry.key_ptr.*, "PostToolUseFailure")) {
                    wrote_posttooluse_failure = true;
                    try s.objectField("PostToolUseFailure");
                    try writeClaudeCogHookArray(&s, entry.value_ptr.*,
                        "sh \"$CLAUDE_PROJECT_DIR\"/.claude/hooks/cog-posttooluse-failure.sh",
                        "mcp__cog__.*", 10, null);
                } else if (std.mem.eql(u8, entry.key_ptr.*, "PreCompact")) {
                    wrote_precompact = true;
                    try s.objectField("PreCompact");
                    try writeClaudeCogHookArray(&s, entry.value_ptr.*,
                        "sh \"$CLAUDE_PROJECT_DIR\"/.claude/hooks/cog-precompact.sh",
                        null, 10, "Preserving Cog context...");
                } else {
                    try s.objectField(entry.key_ptr.*);
                    try s.write(entry.value_ptr.*);
                }
            }
        }
    }

    if (!wrote_pretooluse) {
        try s.objectField("PreToolUse");
        try writeClaudePreToolUseHookArray(&s, null);
    }

    if (!wrote_stop) {
        try s.objectField("Stop");
        try writeClaudeStopHookArray(&s, null);
    }

    if (!wrote_posttooluse_failure) {
        try s.objectField("PostToolUseFailure");
        try writeClaudeCogHookArray(&s, null,
            "sh \"$CLAUDE_PROJECT_DIR\"/.claude/hooks/cog-posttooluse-failure.sh",
            "mcp__cog__.*", 10, null);
    }

    if (!wrote_precompact) {
        try s.objectField("PreCompact");
        try writeClaudeCogHookArray(&s, null,
            "sh \"$CLAUDE_PROJECT_DIR\"/.claude/hooks/cog-precompact.sh",
            null, 10, "Preserving Cog context...");
    }

    try s.endObject();
    try s.endObject();

    const new_content = try aw.toOwnedSlice();
    defer allocator.free(new_content);
    try writeCwdFile(path, new_content);
}

fn writeClaudePreToolUseHookArray(s: *Stringify, existing_value: ?json.Value) !void {
    const command = "sh \"$CLAUDE_PROJECT_DIR\"/.claude/hooks/cog-pretooluse.sh";
    const matcher_value = "Grep|Glob|Bash|Agent|mcp__cog__code_explore|mcp__cog__code_query";
    var already_has_group = false;

    try s.beginArray();
    if (existing_value) |value| {
        if (value == .array) {
            for (value.array.items) |item| {
                // Detect our Cog hook group by command, regardless of matcher value.
                // This lets us upgrade the matcher on re-init without duplicating.
                var is_cog_group = false;
                var has_current_matcher = false;
                if (item == .object) {
                    if (item.object.get("matcher")) |matcher| {
                        if (matcher == .string and std.mem.eql(u8, matcher.string, matcher_value)) {
                            has_current_matcher = true;
                        }
                    }
                    if (item.object.get("hooks")) |hooks| {
                        if (hooks == .array) {
                            for (hooks.array.items) |hook| {
                                if (hook == .object) {
                                    if (hook.object.get("command")) |existing_command| {
                                        if (existing_command == .string and std.mem.eql(u8, existing_command.string, command)) {
                                            is_cog_group = true;
                                        }
                                    }
                                }
                            }
                        }
                    }
                }

                if (is_cog_group) {
                    if (has_current_matcher) {
                        // Already up-to-date — keep as-is
                        already_has_group = true;
                        try s.write(item);
                    }
                    // else: old matcher version — drop it, we'll write the updated group below
                } else {
                    // Not our group — preserve it
                    try s.write(item);
                }
            }
        }
    }

    if (!already_has_group) {
        try s.beginObject();
        try s.objectField("matcher");
        try s.write(matcher_value);
        try s.objectField("hooks");
        try s.beginArray();
        try s.beginObject();
        try s.objectField("type");
        try s.write("command");
        try s.objectField("command");
        try s.write(command);
        try s.objectField("timeout");
        try s.write(30);
        try s.endObject();
        try s.endArray();
        try s.endObject();
    }

    try s.endArray();
}

fn writeClaudeStopHookArray(s: *Stringify, existing_value: ?json.Value) !void {
    debug_log.log("hooks.writeClaudeStopHookArray", .{});
    const command = "sh \"$CLAUDE_PROJECT_DIR\"/.claude/hooks/cog-stop-memory.sh";
    var already_has_hook = false;

    try s.beginArray();
    if (existing_value) |value| {
        if (value == .array) {
            for (value.array.items) |item| {
                if (item == .object) {
                    if (item.object.get("hooks")) |hooks| {
                        if (hooks == .array) {
                            for (hooks.array.items) |hook| {
                                if (hook == .object) {
                                    if (hook.object.get("command")) |existing_command| {
                                        if (existing_command == .string and std.mem.eql(u8, existing_command.string, command)) {
                                            already_has_hook = true;
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
                try s.write(item);
            }
        }
    }

    if (!already_has_hook) {
        try s.beginObject();
        try s.objectField("hooks");
        try s.beginArray();
        try s.beginObject();
        try s.objectField("type");
        try s.write("command");
        try s.objectField("command");
        try s.write(command);
        try s.objectField("timeout");
        try s.write(10);
        try s.objectField("statusMessage");
        try s.write("Verifying memory storage...");
        try s.endObject();
        try s.endArray();
        try s.endObject();
    }

    try s.endArray();
}

/// Generic merge writer for Cog-owned Claude hook arrays.
/// Detects existing Cog groups by command string, preserves non-Cog groups,
/// and creates or updates the Cog group as needed.
fn writeClaudeCogHookArray(
    s: *Stringify,
    existing_value: ?json.Value,
    command: []const u8,
    matcher_value: ?[]const u8,
    timeout: u32,
    status_message: ?[]const u8,
) !void {
    var already_has_hook = false;

    try s.beginArray();
    if (existing_value) |value| {
        if (value == .array) {
            for (value.array.items) |item| {
                var is_cog_group = false;
                if (item == .object) {
                    if (item.object.get("hooks")) |hooks| {
                        if (hooks == .array) {
                            for (hooks.array.items) |hook| {
                                if (hook == .object) {
                                    if (hook.object.get("command")) |existing_command| {
                                        if (existing_command == .string and std.mem.eql(u8, existing_command.string, command)) {
                                            is_cog_group = true;
                                            already_has_hook = true;
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
                if (!is_cog_group) {
                    try s.write(item);
                } else {
                    // Preserve existing Cog group as-is (idempotent)
                    try s.write(item);
                }
            }
        }
    }

    if (!already_has_hook) {
        try s.beginObject();
        if (matcher_value) |m| {
            try s.objectField("matcher");
            try s.write(m);
        }
        try s.objectField("hooks");
        try s.beginArray();
        try s.beginObject();
        try s.objectField("type");
        try s.write("command");
        try s.objectField("command");
        try s.write(command);
        try s.objectField("timeout");
        try s.write(timeout);
        if (status_message) |msg| {
            try s.objectField("statusMessage");
            try s.write(msg);
        }
        try s.endObject();
        try s.endArray();
        try s.endObject();
    }

    try s.endArray();
}

fn writeGeminiTrust(allocator: std.mem.Allocator, mcp_path: []const u8) !void {
    debug_log.log("hooks.writeGeminiTrust: path={s}", .{mcp_path});
    const existing = readCwdFile(allocator, mcp_path) orelse return;
    defer allocator.free(existing);

    const parsed = json.parseFromSlice(json.Value, allocator, existing, .{}) catch return;
    defer parsed.deinit();

    if (parsed.value != .object) return;

    var aw: Writer.Allocating = .init(allocator);
    defer aw.deinit();
    var s: Stringify = .{ .writer = &aw.writer, .options = .{ .whitespace = .indent_2 } };
    try s.beginObject();

    var iter = parsed.value.object.iterator();
    while (iter.next()) |entry| {
        if (std.mem.eql(u8, entry.key_ptr.*, "mcpServers")) {
            // Rewrite mcpServers with trust on cog entry
            try s.objectField("mcpServers");
            try s.beginObject();

            if (entry.value_ptr.* == .object) {
                var srv_iter = entry.value_ptr.object.iterator();
                while (srv_iter.next()) |srv| {
                    try s.objectField(srv.key_ptr.*);
                    if (std.mem.eql(u8, srv.key_ptr.*, "cog") and srv.value_ptr.* == .object) {
                        // Rewrite cog entry with trust: true
                        try s.beginObject();
                        var cog_iter = srv.value_ptr.object.iterator();
                        while (cog_iter.next()) |cog_entry| {
                            if (std.mem.eql(u8, cog_entry.key_ptr.*, "trust")) continue;
                            try s.objectField(cog_entry.key_ptr.*);
                            try s.write(cog_entry.value_ptr.*);
                        }
                        try s.objectField("trust");
                        try s.write(true);
                        try s.endObject();
                    } else {
                        try s.write(srv.value_ptr.*);
                    }
                }
            }

            try s.endObject();
        } else {
            try s.objectField(entry.key_ptr.*);
            try s.write(entry.value_ptr.*);
        }
    }

    try s.endObject();

    const new_content = try aw.toOwnedSlice();
    defer allocator.free(new_content);
    try writeCwdFile(mcp_path, new_content);
}

fn writeGeminiRuntimeHooks(allocator: std.mem.Allocator, mcp_path: []const u8) !void {
    debug_log.log("hooks.writeGeminiRuntimeHooks: path={s}", .{mcp_path});
    try ensureDir(".gemini/hooks");

    const existing = readCwdFile(allocator, mcp_path) orelse return;
    defer allocator.free(existing);

    const parsed = json.parseFromSlice(json.Value, allocator, existing, .{}) catch return;
    defer parsed.deinit();
    if (parsed.value != .object) return;

    var aw: Writer.Allocating = .init(allocator);
    defer aw.deinit();
    var s: Stringify = .{ .writer = &aw.writer, .options = .{ .whitespace = .indent_2 } };
    try s.beginObject();

    var wrote_before_tool = false;
    var iter = parsed.value.object.iterator();
    while (iter.next()) |entry| {
        if (std.mem.eql(u8, entry.key_ptr.*, "hooks")) {
            try s.objectField("hooks");
            if (entry.value_ptr.* == .object) {
                try s.beginObject();
                var hooks_iter = entry.value_ptr.object.iterator();
                while (hooks_iter.next()) |hook_entry| {
                    if (std.mem.eql(u8, hook_entry.key_ptr.*, "BeforeTool")) {
                        wrote_before_tool = true;
                        try s.objectField("BeforeTool");
                        try writeGeminiBeforeToolHookArray(&s, hook_entry.value_ptr.*);
                    } else {
                        try s.objectField(hook_entry.key_ptr.*);
                        try s.write(hook_entry.value_ptr.*);
                    }
                }
                if (!wrote_before_tool) {
                    try s.objectField("BeforeTool");
                    try writeGeminiBeforeToolHookArray(&s, null);
                    wrote_before_tool = true;
                }
                try s.endObject();
            } else {
                try s.beginObject();
                try s.objectField("BeforeTool");
                try writeGeminiBeforeToolHookArray(&s, null);
                wrote_before_tool = true;
                try s.endObject();
            }
        } else {
            try s.objectField(entry.key_ptr.*);
            try s.write(entry.value_ptr.*);
        }
    }

    if (!wrote_before_tool) {
        try s.objectField("hooks");
        try s.beginObject();
        try s.objectField("BeforeTool");
        try writeGeminiBeforeToolHookArray(&s, null);
        try s.endObject();
    }

    try s.endObject();

    const new_content = try aw.toOwnedSlice();
    defer allocator.free(new_content);
    try writeCwdFile(mcp_path, new_content);
}

fn writeGeminiBeforeToolHookArray(s: *Stringify, existing_value: ?json.Value) !void {
    const hook_name = "cog-before-tool";
    const command = "sh .gemini/hooks/cog-before-tool.sh";
    var already_has_hook = false;

    try s.beginArray();
    if (existing_value) |value| {
        if (value == .array) {
            for (value.array.items) |item| {
                if (item == .object) {
                    if (item.object.get("name")) |name| {
                        if (name == .string and std.mem.eql(u8, name.string, hook_name)) {
                            already_has_hook = true;
                        }
                    }
                }
                try s.write(item);
            }
        }
    }

    if (!already_has_hook) {
        try s.beginObject();
        try s.objectField("name");
        try s.write(hook_name);
        try s.objectField("type");
        try s.write("command");
        try s.objectField("command");
        try s.write(command);
        try s.objectField("matcher");
        try s.write(".*");
        try s.objectField("timeout");
        try s.write(30);
        try s.objectField("description");
        try s.write("Prefer Cog code intelligence over raw file search when Cog MCP is configured");
        try s.endObject();
    }

    try s.endArray();
}

fn writeAmpPermissions(allocator: std.mem.Allocator, mcp_path: []const u8) !void {
    debug_log.log("hooks.writeAmpPermissions: path={s}", .{mcp_path});
    const existing = readCwdFile(allocator, mcp_path) orelse return;
    defer allocator.free(existing);

    const parsed = json.parseFromSlice(json.Value, allocator, existing, .{}) catch return;
    defer parsed.deinit();

    if (parsed.value != .object) return;

    var aw: Writer.Allocating = .init(allocator);
    defer aw.deinit();
    var s: Stringify = .{ .writer = &aw.writer, .options = .{ .whitespace = .indent_2 } };
    try s.beginObject();

    // Check if amp.permissions already exists and has our rule
    var existing_perms: ?json.Value = null;
    var already_has_cog = false;

    if (parsed.value.object.get("amp.permissions")) |perms| {
        existing_perms = perms;
        if (perms == .array) {
            for (perms.array.items) |item| {
                if (item == .object) {
                    const tool = item.object.get("tool") orelse continue;
                    if (tool == .string and std.mem.eql(u8, tool.string, "mcp__cog__*")) {
                        already_has_cog = true;
                        break;
                    }
                }
            }
        }
    }

    // Copy all non-permissions top-level keys
    var iter = parsed.value.object.iterator();
    while (iter.next()) |entry| {
        if (std.mem.eql(u8, entry.key_ptr.*, "amp.permissions")) continue;
        try s.objectField(entry.key_ptr.*);
        try s.write(entry.value_ptr.*);
    }

    // Write amp.permissions
    try s.objectField("amp.permissions");
    try s.beginArray();

    if (existing_perms) |perms| {
        if (perms == .array) {
            for (perms.array.items) |item| {
                try s.write(item);
            }
        }
    }

    if (!already_has_cog) {
        try s.beginObject();
        try s.objectField("tool");
        try s.write("mcp__cog__*");
        try s.objectField("action");
        try s.write("allow");
        try s.endObject();
    }

    try s.endArray();
    try s.endObject();

    const new_content = try aw.toOwnedSlice();
    defer allocator.free(new_content);
    try writeCwdFile(mcp_path, new_content);
}

fn writeOpenCodePermissions(allocator: std.mem.Allocator, mcp_path: []const u8) !void {
    debug_log.log("hooks.writeOpenCodePermissions: path={s}", .{mcp_path});
    const existing = readCwdFile(allocator, mcp_path) orelse return;
    defer allocator.free(existing);

    const parsed = json.parseFromSlice(json.Value, allocator, existing, .{}) catch return;
    defer parsed.deinit();

    if (parsed.value != .object) return;

    var aw: Writer.Allocating = .init(allocator);
    defer aw.deinit();
    var s: Stringify = .{ .writer = &aw.writer, .options = .{ .whitespace = .indent_2 } };
    try s.beginObject();

    var existing_permissions: ?json.Value = null;
    var existing_cog_rule: ?json.Value = null;
    var existing_glob_rule: ?json.Value = null;
    var existing_grep_rule: ?json.Value = null;
    var existing_agents: ?json.Value = null;
    var existing_general: ?json.Value = null;
    var existing_general_permissions: ?json.Value = null;
    var existing_general_cog_rule: ?json.Value = null;

    if (parsed.value.object.get("permission")) |perms| {
        existing_permissions = perms;
        if (perms == .object) {
            if (perms.object.get("cog_*")) |rule| {
                existing_cog_rule = rule;
            }
            if (perms.object.get("glob")) |rule| {
                existing_glob_rule = rule;
            }
            if (perms.object.get("grep")) |rule| {
                existing_grep_rule = rule;
            }
        }
    }

    if (parsed.value.object.get("agent")) |agents| {
        existing_agents = agents;
        if (agents == .object) {
            if (agents.object.get("general")) |general| {
                existing_general = general;
                if (general == .object) {
                    if (general.object.get("permission")) |perms| {
                        existing_general_permissions = perms;
                        if (perms == .object) {
                            if (perms.object.get("cog_*")) |rule| {
                                existing_general_cog_rule = rule;
                            }
                        }
                    }
                }
            }
        }
    }

    var iter = parsed.value.object.iterator();
    while (iter.next()) |entry| {
        if (std.mem.eql(u8, entry.key_ptr.*, "permission")) continue;
        if (std.mem.eql(u8, entry.key_ptr.*, "agent")) continue;
        try s.objectField(entry.key_ptr.*);
        try s.write(entry.value_ptr.*);
    }

    try s.objectField("permission");
    if (existing_permissions) |perms| {
        if (perms == .object) {
            try s.beginObject();
            var perms_iter = perms.object.iterator();
            while (perms_iter.next()) |entry| {
                try s.objectField(entry.key_ptr.*);
                try s.write(entry.value_ptr.*);
            }
            if (existing_cog_rule == null) {
                try s.objectField("cog_*");
                try s.write("allow");
            }
            if (existing_glob_rule == null) {
                try s.objectField("glob");
                try s.write("deny");
            }
            if (existing_grep_rule == null) {
                try s.objectField("grep");
                try s.write("deny");
            }
            try s.endObject();
        } else {
            try s.beginObject();
            try s.objectField("*");
            try s.write(perms);
            try s.objectField("cog_*");
            try s.write("allow");
            try s.objectField("glob");
            try s.write("deny");
            try s.objectField("grep");
            try s.write("deny");
            try s.endObject();
        }
    } else {
        try s.beginObject();
        try s.objectField("cog_*");
        try s.write("allow");
        try s.objectField("glob");
        try s.write("deny");
        try s.objectField("grep");
        try s.write("deny");
        try s.endObject();
    }

    try s.objectField("agent");
    if (existing_agents) |agents| {
        if (agents == .object) {
            try s.beginObject();
            var agents_iter = agents.object.iterator();
            while (agents_iter.next()) |entry| {
                if (std.mem.eql(u8, entry.key_ptr.*, "general")) continue;
                try s.objectField(entry.key_ptr.*);
                try s.write(entry.value_ptr.*);
            }

            try s.objectField("general");
            if (existing_general) |general| {
                if (general == .object) {
                    try s.beginObject();
                    var general_iter = general.object.iterator();
                    while (general_iter.next()) |entry| {
                        if (std.mem.eql(u8, entry.key_ptr.*, "permission")) continue;
                        try s.objectField(entry.key_ptr.*);
                        try s.write(entry.value_ptr.*);
                    }

                    try s.objectField("permission");
                    if (existing_general_permissions) |perms| {
                        if (perms == .object) {
                            try s.beginObject();
                            var general_perms_iter = perms.object.iterator();
                            while (general_perms_iter.next()) |entry| {
                                try s.objectField(entry.key_ptr.*);
                                try s.write(entry.value_ptr.*);
                            }
                            if (existing_general_cog_rule == null) {
                                try s.objectField("cog_*");
                                try s.write("allow");
                            }
                            try s.endObject();
                        } else {
                            try s.beginObject();
                            try s.objectField("*");
                            try s.write(perms);
                            try s.objectField("cog_*");
                            try s.write("allow");
                            try s.endObject();
                        }
                    } else {
                        try s.beginObject();
                        try s.objectField("cog_*");
                        try s.write("allow");
                        try s.endObject();
                    }
                    try s.endObject();
                } else {
                    try s.beginObject();
                    try s.objectField("permission");
                    try s.beginObject();
                    try s.objectField("cog_*");
                    try s.write("allow");
                    try s.endObject();
                    try s.endObject();
                }
            } else {
                try s.beginObject();
                try s.objectField("permission");
                try s.beginObject();
                try s.objectField("cog_*");
                try s.write("allow");
                try s.endObject();
                try s.endObject();
            }

            try s.endObject();
        } else {
            try s.beginObject();
            try s.objectField("general");
            try s.beginObject();
            try s.objectField("permission");
            try s.beginObject();
            try s.objectField("cog_*");
            try s.write("allow");
            try s.endObject();
            try s.endObject();
            try s.endObject();
        }
    } else {
        try s.beginObject();
        try s.objectField("general");
        try s.beginObject();
        try s.objectField("permission");
        try s.beginObject();
        try s.objectField("cog_*");
        try s.write("allow");
        try s.endObject();
        try s.endObject();
        try s.endObject();
    }

    try s.endObject();

    const new_content = try aw.toOwnedSlice();
    defer allocator.free(new_content);
    try writeCwdFile(mcp_path, new_content);
}

fn writeOpenCodeOverridePlugin(path: []const u8) !void {
    debug_log.log("hooks.writeOpenCodeOverridePlugin: path={s}", .{path});
    if (std.fs.path.dirname(path)) |parent| {
        try ensureDir(parent);
    }

    try writeCwdFile(path, opencode_override_content);
}

fn writeOpenCodeMemoryPlugin(path: []const u8) !void {
    debug_log.log("hooks.writeOpenCodeMemoryPlugin: path={s}", .{path});
    if (std.fs.path.dirname(path)) |parent| {
        try ensureDir(parent);
    }

    try writeCwdFile(path, opencode_memory_content);
}

fn writeOpenCodeDebugPlugin(path: []const u8) !void {
    debug_log.log("hooks.writeOpenCodeDebugPlugin: path={s}", .{path});
    if (std.fs.path.dirname(path)) |parent| {
        try ensureDir(parent);
    }

    try writeCwdFile(path, opencode_debug_content);
}

// ── Agent File Deployment ────────────────────────────────────────────

pub fn configureAgentFile(allocator: std.mem.Allocator, agent: agents_mod.Agent) !void {
    const agent_path = agent.agent_file_path orelse return;
    const caps = agent.capabilities();

    if (caps.subagent_support == .workflow_files) {
        const header = agent.agent_file_header orelse return;
        const instructions = try buildWorkflowSpecialistInstructions(allocator, agent.display_name, .code_query, build_options.agent_body);
        defer allocator.free(instructions);
        try writeMarkdownAgent(allocator, agent_path, header, instructions);
    } else if (caps.subagent_support == .dedicated_files and caps.code_query_enforcement == .config) {
        const header = agent.agent_file_header orelse return;
        const instructions = try buildConfigScopedSpecialistInstructions(allocator, agent.display_name, .code_query, build_options.agent_body);
        defer allocator.free(instructions);
        try writeMarkdownAgent(allocator, agent_path, header, instructions);
    } else if (caps.subagent_support == .dedicated_files and caps.code_query_enforcement == .prompt_only) {
        const header = agent.agent_file_header orelse return;
        const instructions = try buildPromptOnlySpecialistInstructions(allocator, agent.display_name, .code_query, build_options.agent_body);
        defer allocator.free(instructions);
        try writeMarkdownAgent(allocator, agent_path, header, instructions);
    } else if (agent.agent_file_header) |header| {
        try writeMarkdownAgent(allocator, agent_path, header, build_options.agent_body);
    } else if (std.mem.eql(u8, agent.id, "codex")) {
        const instructions = try buildCodexSpecialistInstructions(allocator, .code_query, build_options.agent_body);
        defer allocator.free(instructions);
        try writeTomlAgent(allocator, agent_path, "cog-code-query", "Explore code structure using the Cog SCIP index", instructions);
    } else if (std.mem.eql(u8, agent.id, "roo")) {
        try writeRooAgent(allocator, agent_path, "cog-code-query", "Cog Code Query", "You are a code index exploration agent. Use cog_code_explore for symbol discovery and file structure, then use cog_code_query refs only when you need call sites. Read source only after the index tells you where to look. Do not use filename guessing or raw file search unless the Cog index is unavailable. Return concise summaries with file paths and line numbers.");
    }
}

pub fn configureDebugAgentFile(allocator: std.mem.Allocator, agent: agents_mod.Agent) !void {
    const debug_path = agent.debug_file_path orelse return;
    const caps = agent.capabilities();

    if (caps.subagent_support == .workflow_files) {
        const header = agent.debug_file_header orelse return;
        const instructions = try buildWorkflowSpecialistInstructions(allocator, agent.display_name, .debug, build_options.debug_agent_body);
        defer allocator.free(instructions);
        try writeMarkdownAgent(allocator, debug_path, header, instructions);
    } else if (caps.subagent_support == .dedicated_files and caps.debug_enforcement == .config) {
        const header = agent.debug_file_header orelse return;
        const instructions = try buildConfigScopedSpecialistInstructions(allocator, agent.display_name, .debug, build_options.debug_agent_body);
        defer allocator.free(instructions);
        try writeMarkdownAgent(allocator, debug_path, header, instructions);
    } else if (caps.subagent_support == .dedicated_files and caps.debug_enforcement == .prompt_only) {
        const header = agent.debug_file_header orelse return;
        const instructions = try buildPromptOnlySpecialistInstructions(allocator, agent.display_name, .debug, build_options.debug_agent_body);
        defer allocator.free(instructions);
        try writeMarkdownAgent(allocator, debug_path, header, instructions);
    } else if (agent.debug_file_header) |header| {
        try writeMarkdownAgent(allocator, debug_path, header, build_options.debug_agent_body);
    } else if (std.mem.eql(u8, agent.id, "codex")) {
        const instructions = try buildCodexSpecialistInstructions(allocator, .debug, build_options.debug_agent_body);
        defer allocator.free(instructions);
        try writeTomlAgent(allocator, debug_path, "cog-debug", "Debug subagent that inspects runtime state via cog debugger tools", instructions);
    } else if (std.mem.eql(u8, agent.id, "roo")) {
        try writeRooAgent(allocator, debug_path, "cog-debug", "Cog Debug", "You are a debug subagent. Use cog_debug tools to answer questions about runtime state. Launch a debug session, set breakpoints, run to them, inspect values, then stop. Return only the observed values. Do not suggest fixes.");
    }
}

pub fn configureMemAgentFile(allocator: std.mem.Allocator, agent: agents_mod.Agent) !void {
    const mem_path = agent.mem_file_path orelse return;
    const caps = agent.capabilities();

    if (caps.subagent_support == .workflow_files) {
        const header = agent.mem_file_header orelse return;
        const instructions = try buildWorkflowSpecialistInstructions(allocator, agent.display_name, .memory, build_options.mem_agent_body);
        defer allocator.free(instructions);
        try writeMarkdownAgent(allocator, mem_path, header, instructions);
    } else if (caps.subagent_support == .dedicated_files and caps.memory_enforcement == .config) {
        const header = agent.mem_file_header orelse return;
        const instructions = try buildConfigScopedSpecialistInstructions(allocator, agent.display_name, .memory, build_options.mem_agent_body);
        defer allocator.free(instructions);
        try writeMarkdownAgent(allocator, mem_path, header, instructions);
    } else if (caps.subagent_support == .dedicated_files and caps.memory_enforcement == .prompt_only) {
        const header = agent.mem_file_header orelse return;
        const instructions = try buildPromptOnlySpecialistInstructions(allocator, agent.display_name, .memory, build_options.mem_agent_body);
        defer allocator.free(instructions);
        try writeMarkdownAgent(allocator, mem_path, header, instructions);
    } else if (agent.mem_file_header) |header| {
        try writeMarkdownAgent(allocator, mem_path, header, build_options.mem_agent_body);
    } else if (std.mem.eql(u8, agent.id, "codex")) {
        const instructions = try buildCodexSpecialistInstructions(allocator, .memory, build_options.mem_agent_body);
        defer allocator.free(instructions);
        try writeTomlAgent(allocator, mem_path, "cog-mem", "Memory sub-agent for recall, consolidation, and maintenance", instructions);
    } else if (std.mem.eql(u8, agent.id, "roo")) {
        try writeRooAgent(allocator, mem_path, "cog-mem", "Cog Memory", "You are a memory sub-agent for Cog's persistent associative knowledge graph. Start with cog_mem_recall, decide whether memory is sufficient, and only then escalate to cog_code_explore or cog_code_query if memory is insufficient. If exploration teaches something durable, write it back with cog_mem_learn. Before finishing, review short-term memory with cog_mem_list_short_term and validate it with cog_mem_reinforce, cog_mem_verify, or cog_mem_flush. Return concise summaries with engram IDs.");
    }
}

pub fn configureValidateAgentFile(allocator: std.mem.Allocator, agent: agents_mod.Agent) !void {
    const validate_path = agent.validate_file_path orelse return;
    const caps = agent.capabilities();

    if (caps.subagent_support == .workflow_files) {
        const header = agent.validate_file_header orelse return;
        const instructions = try buildWorkflowSpecialistInstructions(allocator, agent.display_name, .validate, build_options.validate_agent_body);
        defer allocator.free(instructions);
        try writeMarkdownAgent(allocator, validate_path, header, instructions);
    } else if (caps.subagent_support == .dedicated_files) {
        const header = agent.validate_file_header orelse return;
        try writeMarkdownAgent(allocator, validate_path, header, build_options.validate_agent_body);
    } else if (std.mem.eql(u8, agent.id, "codex")) {
        const instructions = try buildCodexSpecialistInstructions(allocator, .validate, build_options.validate_agent_body);
        defer allocator.free(instructions);
        try writeTomlAgent(allocator, validate_path, "cog-mem-validate", "Post-task memory validation — learns durable knowledge and consolidates short-term memories", instructions);
    } else if (std.mem.eql(u8, agent.id, "roo")) {
        try writeRooAgent(allocator, validate_path, "cog-mem-validate", "Cog Memory Validate", "You are a post-task memory validation sub-agent. Store durable knowledge from the primary agent's exploration with cog_mem_learn, then consolidate short-term memories with cog_mem_list_short_term and cog_mem_reinforce or cog_mem_flush. Return concise summaries with engram IDs.");
    }
}

const CodexSpecialistKind = enum {
    code_query,
    debug,
    memory,
    validate,
};

fn buildCodexSpecialistInstructions(allocator: std.mem.Allocator, kind: CodexSpecialistKind, body: []const u8) ![]const u8 {
    const prelude = switch (kind) {
        .code_query =>
        \\Host guidance:
        \\- Treat this specialist as read-only.
        \\- Use Cog code intelligence before any raw file search.
        \\- Do not use shell search commands like grep, rg, find, or git grep from this specialist.
        \\- Do not edit files or run commands from this specialist.
        \\
        ,
        .debug =>
        \\Host guidance:
        \\- Prefer debugger evidence over speculative fixes.
        \\- Use shell commands only to launch or reproduce the supplied test.
        \\- Do not edit files from this specialist.
        \\
        ,
        .memory =>
        \\Host guidance:
        \\- Use this specialist as the primary retrieval-first path.
        \\- Start with Cog memory recall, decide whether memory is sufficient, and escalate to Cog code exploration inside the specialist only when memory is insufficient.
        \\- Do not edit files from this specialist.
        \\- Return concise recall or consolidation results that the main agent can act on.
        \\
        ,
        .validate =>
        \\Host guidance:
        \\- This specialist handles the full learn-and-consolidate lifecycle in one call.
        \\- Do not edit files or explore code from this specialist.
        \\- Return concise summaries with engram IDs.
        \\
        ,
    };

    return try std.fmt.allocPrint(allocator, "{s}\n{s}", .{ prelude, body });
}

fn buildWorkflowSpecialistInstructions(allocator: std.mem.Allocator, agent_name: []const u8, kind: CodexSpecialistKind, body: []const u8) ![]const u8 {
    return switch (kind) {
        .code_query => try std.fmt.allocPrint(allocator,
            \\Workflow guidance:
            \\- This host uses workflow files rather than hard-scoped subagents.
            \\- Treat this workflow as a read-oriented research specialist inside {s}.
            \\- Start with Cog code intelligence and only fall back to raw file search if the Cog index is unavailable.
            \\- Do not use shell search commands like grep, rg, find, or git grep when Cog code intelligence can answer the question.
            \\- Return concrete paths, symbols, and next actions for the main agent.
            \\
            \\{s}
        , .{ agent_name, body }),
        .debug => try std.fmt.allocPrint(allocator,
            \\Workflow guidance:
            \\- This host uses workflow files rather than hard-scoped subagents.
            \\- Prefer Cog debugger evidence over speculative reasoning.
            \\- Use shell commands only to reproduce the reported issue or run the requested test.
            \\- Return observed runtime facts, not broad rewrite plans.
            \\
            \\{s}
        , .{body}),
        .memory => try std.fmt.allocPrint(allocator,
            \\Workflow guidance:
            \\- This host uses workflow files rather than hard-scoped subagents.
            \\- Use this workflow as the retrieval-first triage path.
            \\- Start with Cog memory recall, decide whether memory is sufficient, and only then escalate to Cog code exploration inside the workflow if memory is insufficient.
            \\- Consolidate durable findings before finishing.
            \\- Keep responses concise, include engram IDs when memory changes, and capture rationale or invariants when they are part of the durable memory.
            \\
            \\{s}
        , .{body}),
        .validate => try std.fmt.allocPrint(allocator,
            \\Workflow guidance:
            \\- This host uses workflow files rather than hard-scoped subagents.
            \\- This workflow handles the full learn-and-consolidate lifecycle in one call.
            \\- Return concise summaries with engram IDs.
            \\
            \\{s}
        , .{body}),
    };
}

fn buildPromptOnlySpecialistInstructions(allocator: std.mem.Allocator, agent_name: []const u8, kind: CodexSpecialistKind, body: []const u8) ![]const u8 {
    return switch (kind) {
        .code_query => try std.fmt.allocPrint(allocator,
            \\Host guidance:
            \\- {s} cannot hard-deny tools per specialist, so treat this as a read-oriented code research role.
            \\- Use Cog code intelligence before any raw file search.
            \\- Do not use shell search commands like grep, rg, find, or git grep from this specialist.
            \\- Do not edit files or run shell commands from this specialist.
            \\
            \\{s}
        , .{ agent_name, body }),
        .debug => try std.fmt.allocPrint(allocator,
            \\Host guidance:
            \\- {s} cannot hard-deny tools per specialist, so keep this role focused on debugger-backed investigation.
            \\- Prefer Cog debugger evidence over speculative reasoning.
            \\- Use command execution only when reproducing the issue or running the requested test.
            \\
            \\{s}
        , .{ agent_name, body }),
        .memory => try std.fmt.allocPrint(allocator,
            \\Host guidance:
            \\- {s} cannot hard-deny tools per specialist, so keep this role focused on Cog memory workflows.
            \\- Use this specialist as the retrieval-first triage path: recall first, decide sufficiency, and only then escalate to Cog code exploration inside the specialist if memory is insufficient.
            \\- Keep recall and consolidation responses concise, include engram IDs when memory changes, and preserve rationale or constraints when they are durable.
            \\
            \\{s}
        , .{ agent_name, body }),
        .validate => try std.fmt.allocPrint(allocator,
            \\Host guidance:
            \\- {s} cannot hard-deny tools per specialist, so keep this role focused on memory validation.
            \\- Handle the full learn-and-consolidate lifecycle in one call.
            \\- Return concise summaries with engram IDs.
            \\
            \\{s}
        , .{ agent_name, body }),
    };
}

fn buildConfigScopedSpecialistInstructions(allocator: std.mem.Allocator, agent_name: []const u8, kind: CodexSpecialistKind, body: []const u8) ![]const u8 {
    return switch (kind) {
        .code_query => try std.fmt.allocPrint(allocator,
            \\Host guidance:
            \\- {s} provides config-level tool scoping for this specialist.
            \\- Stay inside the allowed read and Cog code-intel tools.
            \\- Use Cog code intelligence before any raw file search.
            \\- Do not use shell search commands like grep, rg, find, or git grep for code exploration.
            \\
            \\{s}
        , .{ agent_name, body }),
        .debug => try std.fmt.allocPrint(allocator,
            \\Host guidance:
            \\- {s} provides partial config-level scoping for this specialist.
            \\- Prefer Cog debugger evidence over speculation.
            \\- Use command execution only for reproduction, launch, or the requested test loop.
            \\
            \\{s}
        , .{ agent_name, body }),
        .memory => try std.fmt.allocPrint(allocator,
            \\Host guidance:
            \\- {s} provides config-level scoping for this memory specialist.
            \\- Use this specialist as the retrieval-first triage path: recall first, decide sufficiency, and only then escalate to Cog code exploration inside the specialist if memory is insufficient.
            \\- Keep updates concise.
            \\- Include engram IDs when memory changes, and preserve provenance, rationale, or invariants when the source supports them.
            \\
            \\{s}
        , .{ agent_name, body }),
        .validate => try std.fmt.allocPrint(allocator,
            \\Host guidance:
            \\- {s} provides config-level scoping for this validation specialist.
            \\- Handle the full learn-and-consolidate lifecycle in one call.
            \\- Return concise summaries with engram IDs.
            \\
            \\{s}
        , .{ agent_name, body }),
    };
}

pub fn buildMarkdownAgentContent(allocator: std.mem.Allocator, header: []const u8, body: []const u8) ![]const u8 {
    return try std.fmt.allocPrint(allocator, "{s}\n{s}", .{ header, body });
}

pub const opencode_override_content = build_options.opencode_override_plugin;
pub const opencode_memory_content = build_options.opencode_memory_plugin;
pub const opencode_debug_content = build_options.opencode_debug_plugin;
pub const claude_pretooluse_hook_content = build_options.claude_pretooluse_hook;
pub const claude_stop_memory_hook_content = build_options.claude_stop_memory_hook;
pub const claude_posttooluse_failure_hook_content = build_options.claude_posttooluse_failure_hook;
pub const claude_precompact_hook_content = build_options.claude_precompact_hook;
pub const gemini_before_tool_hook_content = build_options.gemini_before_tool_hook;
pub const amp_cog_plugin_content = build_options.amp_cog_plugin;
pub const pi_cog_extension_content = build_options.pi_cog_extension;

fn writeRuntimePolicyAsset(path: []const u8, content: []const u8) !void {
    debug_log.log("hooks.writeRuntimePolicyAsset: path={s}", .{path});
    if (std.fs.path.dirname(path)) |parent| {
        try ensureDir(parent);
    }

    try writeCwdFile(path, content);
}

fn writeMarkdownAgent(allocator: std.mem.Allocator, path: []const u8, header: []const u8, body: []const u8) !void {
    if (std.fs.path.dirname(path)) |parent| {
        try ensureDir(parent);
    }

    const content = try std.fmt.allocPrint(allocator, "{s}\n{s}", .{ header, body });
    defer allocator.free(content);
    try writeCwdFile(path, content);
}

fn writeTomlAgent(allocator: std.mem.Allocator, path: []const u8, section_name: []const u8, description: []const u8, body: []const u8) !void {
    if (std.fs.path.dirname(path)) |parent| {
        try ensureDir(parent);
    }

    const existing = readCwdFile(allocator, path);
    defer if (existing) |e| allocator.free(e);

    const section_marker = try std.fmt.allocPrint(allocator, "[agents.{s}]", .{section_name});
    defer allocator.free(section_marker);

    if (existing) |content| {
        if (std.mem.indexOf(u8, content, section_marker) != null) return;

        const toml_section = try std.fmt.allocPrint(allocator,
            \\
            \\{s}
            \\description = "{s}"
            \\developer_instructions = """
            \\{s}"""
            \\
        , .{ section_marker, description, body });
        defer allocator.free(toml_section);

        const new_content = try std.fmt.allocPrint(allocator, "{s}{s}", .{ content, toml_section });
        defer allocator.free(new_content);
        try writeCwdFile(path, new_content);
    } else {
        const toml_content = try std.fmt.allocPrint(allocator,
            \\{s}
            \\description = "{s}"
            \\developer_instructions = """
            \\{s}"""
            \\
        , .{ section_marker, description, body });
        defer allocator.free(toml_content);
        try writeCwdFile(path, toml_content);
    }
}

fn writeRooAgent(allocator: std.mem.Allocator, path: []const u8, slug: []const u8, name: []const u8, role_definition: []const u8) !void {
    const description = if (std.mem.eql(u8, slug, "cog-code-query"))
        "Explore code structure using the Cog SCIP index"
    else if (std.mem.eql(u8, slug, "cog-debug"))
        "Debug subagent that investigates runtime behavior via cog debugger, code, and memory tools"
    else if (std.mem.eql(u8, slug, "cog-mem"))
        "Memory sub-agent for recall, consolidation, and maintenance"
    else
        name;
    const when_to_use = if (std.mem.eql(u8, slug, "cog-code-query"))
        "Use when you need repository exploration, symbol lookup, or architecture summaries without relying on raw file search."
    else if (std.mem.eql(u8, slug, "cog-debug"))
        "Use for runtime bugs, crashes, or unclear state when debugger evidence is needed instead of static reasoning."
    else if (std.mem.eql(u8, slug, "cog-mem"))
        "Use before broad unfamiliar exploration for recall, and after work to consolidate or clean up memory."
    else
        name;
    const custom_instructions = if (std.mem.eql(u8, slug, "cog-code-query"))
        build_options.agent_body
    else if (std.mem.eql(u8, slug, "cog-debug"))
        build_options.debug_agent_body
    else if (std.mem.eql(u8, slug, "cog-mem"))
        build_options.mem_agent_body
    else
        role_definition;
    const code_query_groups = [_][]const u8{ "read", "mcp" };
    const debug_groups = [_][]const u8{ "read", "command", "mcp" };
    const mem_groups = [_][]const u8{"mcp"};
    const empty_groups = [_][]const u8{};
    const groups: []const []const u8 = if (std.mem.eql(u8, slug, "cog-code-query"))
        &code_query_groups
    else if (std.mem.eql(u8, slug, "cog-debug"))
        &debug_groups
    else if (std.mem.eql(u8, slug, "cog-mem"))
        &mem_groups
    else
        &empty_groups;

    const existing = readCwdFile(allocator, path);
    defer if (existing) |e| allocator.free(e);

    var aw: Writer.Allocating = .init(allocator);
    defer aw.deinit();
    var s: Stringify = .{ .writer = &aw.writer, .options = .{ .whitespace = .indent_2 } };

    try s.beginObject();
    try s.objectField("customModes");
    try s.beginArray();

    var found_existing = false;

    if (existing) |content| {
        if (json.parseFromSlice(json.Value, allocator, content, .{})) |parsed| {
            defer parsed.deinit();
            if (parsed.value == .object) {
                if (parsed.value.object.get("customModes")) |modes| {
                    if (modes == .array) {
                        for (modes.array.items) |mode| {
                            if (mode == .object) {
                                if (mode.object.get("slug")) |slug_val| {
                                    if (slug_val == .string and std.mem.eql(u8, slug_val.string, slug)) {
                                        found_existing = true;
                                        // Write updated entry
                                        try s.beginObject();
                                        try s.objectField("slug");
                                        try s.write(slug);
                                        try s.objectField("name");
                                        try s.write(name);
                                        try s.objectField("description");
                                        try s.write(description);
                                        try s.objectField("roleDefinition");
                                        try s.write(role_definition);
                                        try s.objectField("whenToUse");
                                        try s.write(when_to_use);
                                        try s.objectField("customInstructions");
                                        try s.write(custom_instructions);
                                        try s.objectField("groups");
                                        try s.beginArray();
                                        for (groups) |group| {
                                            try s.write(group);
                                        }
                                        try s.endArray();
                                        try s.endObject();
                                        continue;
                                    }
                                }
                            }
                            try s.write(mode);
                        }
                    }
                }
            }
        } else |_| {}
    }

    if (!found_existing) {
        try s.beginObject();
        try s.objectField("slug");
        try s.write(slug);
        try s.objectField("name");
        try s.write(name);
        try s.objectField("description");
        try s.write(description);
        try s.objectField("roleDefinition");
        try s.write(role_definition);
        try s.objectField("whenToUse");
        try s.write(when_to_use);
        try s.objectField("customInstructions");
        try s.write(custom_instructions);
        try s.objectField("groups");
        try s.beginArray();
        for (groups) |group| {
            try s.write(group);
        }
        try s.endArray();
        try s.endObject();
    }

    try s.endArray();
    try s.endObject();

    const new_content = try aw.toOwnedSlice();
    defer allocator.free(new_content);
    try writeCwdFile(path, new_content);
}

// ── Tests ───────────────────────────────────────────────────────────────

fn withTempCwd(comptime body: fn (std.mem.Allocator) anyerror!void) !void {
    const allocator = std.testing.allocator;
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    var original_cwd = std.fs.cwd().openDir(".", .{}) catch unreachable;
    defer {
        original_cwd.setAsCwd() catch unreachable;
        original_cwd.close();
    }

    tmp_dir.dir.setAsCwd() catch unreachable;
    try body(allocator);
}

test "writeJsonMcp preserves existing non-cog entries" {
    try withTempCwd(struct {
        fn run(allocator: std.mem.Allocator) !void {
            const existing =
                \\{"version":1,"mcpServers":{"foo":{"command":"foo"},"cog":{"command":"old","args":["legacy"]}}}
            ;
            try writeCwdFile(".mcp.json", existing);

            try writeJsonMcp(allocator, ".mcp.json", "mcpServers");

            const updated = readCwdFile(allocator, ".mcp.json") orelse return error.TestUnexpectedResult;
            defer allocator.free(updated);

            const parsed = try json.parseFromSlice(json.Value, allocator, updated, .{});
            defer parsed.deinit();

            try std.testing.expect(parsed.value == .object);
            const version = parsed.value.object.get("version") orelse return error.TestUnexpectedResult;
            try std.testing.expect(version == .integer);
            try std.testing.expectEqual(@as(i64, 1), version.integer);

            const servers = parsed.value.object.get("mcpServers") orelse return error.TestUnexpectedResult;
            try std.testing.expect(servers == .object);
            try std.testing.expect(servers.object.get("foo") != null);

            const cog = servers.object.get("cog") orelse return error.TestUnexpectedResult;
            try std.testing.expect(cog == .object);
            const typ = cog.object.get("type") orelse return error.TestUnexpectedResult;
            try std.testing.expect(typ == .string);
            try std.testing.expectEqualStrings("stdio", typ.string);
            const command = cog.object.get("command") orelse return error.TestUnexpectedResult;
            try std.testing.expect(command == .string);
            try std.testing.expectEqualStrings("cog", command.string);
        }
    }.run);
}

test "writeJsonOpenCode merges root and rewrites mcp.cog" {
    try withTempCwd(struct {
        fn run(allocator: std.mem.Allocator) !void {
            const existing =
                \\{"theme":"default","plugin":["existing-plugin"],"mcp":{"other":{"type":"remote"},"cog":{"type":"local","command":["old"]}}}
            ;
            try writeCwdFile("opencode.json", existing);

            try writeJsonOpenCode(allocator, "opencode.json");

            const updated = readCwdFile(allocator, "opencode.json") orelse return error.TestUnexpectedResult;
            defer allocator.free(updated);

            const parsed = try json.parseFromSlice(json.Value, allocator, updated, .{});
            defer parsed.deinit();

            try std.testing.expect(parsed.value == .object);
            const theme = parsed.value.object.get("theme") orelse return error.TestUnexpectedResult;
            try std.testing.expect(theme == .string);
            try std.testing.expectEqualStrings("default", theme.string);

            const mcp = parsed.value.object.get("mcp") orelse return error.TestUnexpectedResult;
            try std.testing.expect(mcp == .object);
            try std.testing.expect(mcp.object.get("other") != null);
            const cog = mcp.object.get("cog") orelse return error.TestUnexpectedResult;
            try std.testing.expect(cog == .object);

            const plugins = parsed.value.object.get("plugin") orelse return error.TestUnexpectedResult;
            try std.testing.expect(plugins == .array);
            try std.testing.expectEqual(@as(usize, 4), plugins.array.items.len);
            try std.testing.expectEqualStrings("existing-plugin", plugins.array.items[0].string);
            try std.testing.expectEqualStrings("cog-override", plugins.array.items[1].string);
            try std.testing.expectEqualStrings("cog-memory", plugins.array.items[2].string);
            try std.testing.expectEqualStrings("cog-debug", plugins.array.items[3].string);

            const command = cog.object.get("command") orelse return error.TestUnexpectedResult;
            try std.testing.expect(command == .array);
            try std.testing.expectEqual(@as(usize, 2), command.array.items.len);
            try std.testing.expectEqualStrings("cog", command.array.items[0].string);
            try std.testing.expectEqualStrings("mcp", command.array.items[1].string);
        }
    }.run);
}

test "writeJsonOpenCode is idempotent for plugin registration" {
    try withTempCwd(struct {
        fn run(allocator: std.mem.Allocator) !void {
            try writeJsonOpenCode(allocator, "opencode.json");
            try writeJsonOpenCode(allocator, "opencode.json");

            const updated = readCwdFile(allocator, "opencode.json") orelse return error.TestUnexpectedResult;
            defer allocator.free(updated);

            const parsed = try json.parseFromSlice(json.Value, allocator, updated, .{});
            defer parsed.deinit();

            const plugins = parsed.value.object.get("plugin") orelse return error.TestUnexpectedResult;
            try std.testing.expect(plugins == .array);
            try std.testing.expectEqual(@as(usize, 3), plugins.array.items.len);
            try std.testing.expectEqualStrings("cog-override", plugins.array.items[0].string);
            try std.testing.expectEqualStrings("cog-memory", plugins.array.items[1].string);
            try std.testing.expectEqualStrings("cog-debug", plugins.array.items[2].string);
        }
    }.run);
}

test "writeOpenCodePermissions adds cog allow rule" {
    try withTempCwd(struct {
        fn run(allocator: std.mem.Allocator) !void {
            const existing =
                \\{"mcp":{"cog":{"type":"local","command":["cog","mcp"]}}}
            ;
            try writeCwdFile("opencode.json", existing);

            try writeOpenCodePermissions(allocator, "opencode.json");

            const content = readCwdFile(allocator, "opencode.json") orelse return error.TestUnexpectedResult;
            defer allocator.free(content);

            const parsed = try json.parseFromSlice(json.Value, allocator, content, .{});
            defer parsed.deinit();

            const perms = parsed.value.object.get("permission") orelse return error.TestUnexpectedResult;
            try std.testing.expect(perms == .object);
            const cog_rule = perms.object.get("cog_*") orelse return error.TestUnexpectedResult;
            try std.testing.expect(cog_rule == .string);
            try std.testing.expectEqualStrings("allow", cog_rule.string);
            try std.testing.expectEqualStrings("deny", perms.object.get("glob").?.string);
            try std.testing.expectEqualStrings("deny", perms.object.get("grep").?.string);

            const agents = parsed.value.object.get("agent") orelse return error.TestUnexpectedResult;
            try std.testing.expect(agents == .object);
            const general = agents.object.get("general") orelse return error.TestUnexpectedResult;
            try std.testing.expect(general == .object);
            const general_perms = general.object.get("permission") orelse return error.TestUnexpectedResult;
            try std.testing.expect(general_perms == .object);
            try std.testing.expectEqualStrings("allow", general_perms.object.get("cog_*").?.string);
        }
    }.run);
}

test "writeOpenCodePermissions preserves existing rules" {
    try withTempCwd(struct {
        fn run(allocator: std.mem.Allocator) !void {
            const existing =
                \\{"permission":{"read":"ask"},"theme":"default"}
            ;
            try writeCwdFile("opencode.json", existing);

            try writeOpenCodePermissions(allocator, "opencode.json");

            const content = readCwdFile(allocator, "opencode.json") orelse return error.TestUnexpectedResult;
            defer allocator.free(content);

            const parsed = try json.parseFromSlice(json.Value, allocator, content, .{});
            defer parsed.deinit();

            const theme = parsed.value.object.get("theme") orelse return error.TestUnexpectedResult;
            try std.testing.expectEqualStrings("default", theme.string);

            const perms = parsed.value.object.get("permission") orelse return error.TestUnexpectedResult;
            try std.testing.expect(perms == .object);
            try std.testing.expectEqualStrings("ask", perms.object.get("read").?.string);
            try std.testing.expectEqualStrings("allow", perms.object.get("cog_*").?.string);
            try std.testing.expectEqualStrings("deny", perms.object.get("glob").?.string);
            try std.testing.expectEqualStrings("deny", perms.object.get("grep").?.string);

            const agents = parsed.value.object.get("agent") orelse return error.TestUnexpectedResult;
            try std.testing.expect(agents == .object);
            const general = agents.object.get("general") orelse return error.TestUnexpectedResult;
            try std.testing.expect(general == .object);
            const general_perms = general.object.get("permission") orelse return error.TestUnexpectedResult;
            try std.testing.expect(general_perms == .object);
            try std.testing.expectEqualStrings("allow", general_perms.object.get("cog_*").?.string);
        }
    }.run);
}

test "writeOpenCodePermissions upgrades string permission" {
    try withTempCwd(struct {
        fn run(allocator: std.mem.Allocator) !void {
            const existing =
                \\{"permission":"ask"}
            ;
            try writeCwdFile("opencode.json", existing);

            try writeOpenCodePermissions(allocator, "opencode.json");

            const content = readCwdFile(allocator, "opencode.json") orelse return error.TestUnexpectedResult;
            defer allocator.free(content);

            const parsed = try json.parseFromSlice(json.Value, allocator, content, .{});
            defer parsed.deinit();

            const perms = parsed.value.object.get("permission") orelse return error.TestUnexpectedResult;
            try std.testing.expect(perms == .object);
            try std.testing.expectEqualStrings("ask", perms.object.get("*").?.string);
            try std.testing.expectEqualStrings("allow", perms.object.get("cog_*").?.string);
            try std.testing.expectEqualStrings("deny", perms.object.get("glob").?.string);
            try std.testing.expectEqualStrings("deny", perms.object.get("grep").?.string);

            const agents = parsed.value.object.get("agent") orelse return error.TestUnexpectedResult;
            try std.testing.expect(agents == .object);
            const general = agents.object.get("general") orelse return error.TestUnexpectedResult;
            try std.testing.expect(general == .object);
            const general_perms = general.object.get("permission") orelse return error.TestUnexpectedResult;
            try std.testing.expect(general_perms == .object);
            try std.testing.expectEqualStrings("allow", general_perms.object.get("cog_*").?.string);
        }
    }.run);
}

test "writeOpenCodePermissions preserves general subagent rules" {
    try withTempCwd(struct {
        fn run(allocator: std.mem.Allocator) !void {
            const existing =
                \\{"agent":{"general":{"description":"keep me","permission":{"read":"ask"}}}}
            ;
            try writeCwdFile("opencode.json", existing);

            try writeOpenCodePermissions(allocator, "opencode.json");

            const content = readCwdFile(allocator, "opencode.json") orelse return error.TestUnexpectedResult;
            defer allocator.free(content);

            const parsed = try json.parseFromSlice(json.Value, allocator, content, .{});
            defer parsed.deinit();

            const agents = parsed.value.object.get("agent") orelse return error.TestUnexpectedResult;
            const general = agents.object.get("general") orelse return error.TestUnexpectedResult;
            try std.testing.expectEqualStrings("keep me", general.object.get("description").?.string);

            const general_perms = general.object.get("permission") orelse return error.TestUnexpectedResult;
            try std.testing.expectEqualStrings("ask", general_perms.object.get("read").?.string);
            try std.testing.expectEqualStrings("allow", general_perms.object.get("cog_*").?.string);
        }
    }.run);
}

test "writeOpenCodeOverridePlugin creates strict override plugin" {
    try withTempCwd(struct {
        fn run(allocator: std.mem.Allocator) !void {
            _ = allocator;
            try writeOpenCodeOverridePlugin(".opencode/plugins/cog-override.ts");

            const content = readCwdFile(std.testing.allocator, ".opencode/plugins/cog-override.ts") orelse return error.TestUnexpectedResult;
            defer std.testing.allocator.free(content);

            try std.testing.expect(std.mem.indexOf(u8, content, "\"tool.definition\"") != null);
            try std.testing.expect(std.mem.indexOf(u8, content, "\"tool.execute.before\"") != null);
            try std.testing.expect(std.mem.indexOf(u8, content, "blockedFallbackTools.has(input.tool)") != null);
            try std.testing.expect(std.mem.indexOf(u8, content, "experimental.chat.system.transform") != null);
            try std.testing.expect(std.mem.indexOf(u8, content, "repeated file-scoped architecture queries") != null);
            try std.testing.expect(std.mem.indexOf(u8, content, "cog_code_explore or cog_code_query") != null);
        }
    }.run);
}

test "writeOpenCodeDebugPlugin creates debug workflow plugin" {
    try withTempCwd(struct {
        fn run(allocator: std.mem.Allocator) !void {
            _ = allocator;
            try writeOpenCodeDebugPlugin(".opencode/plugins/cog-debug.ts");

            const content = readCwdFile(std.testing.allocator, ".opencode/plugins/cog-debug.ts") orelse return error.TestUnexpectedResult;
            defer std.testing.allocator.free(content);

            try std.testing.expect(std.mem.indexOf(u8, content, "cog_debug_launch") != null);
            try std.testing.expect(std.mem.indexOf(u8, content, "QUESTION:, HYPOTHESIS:, and TEST:") != null);
            try std.testing.expect(std.mem.indexOf(u8, content, "inspectionRequired") != null);
            try std.testing.expect(std.mem.indexOf(u8, content, "Specialist debug tools") != null);
        }
    }.run);
}

test "writeOpenCodeMemoryPlugin creates provenance-aware memory plugin" {
    try withTempCwd(struct {
        fn run(allocator: std.mem.Allocator) !void {
            _ = allocator;
            try writeOpenCodeMemoryPlugin(".opencode/plugins/cog-memory.ts");

            const content = readCwdFile(std.testing.allocator, ".opencode/plugins/cog-memory.ts") orelse return error.TestUnexpectedResult;
            defer std.testing.allocator.free(content);

            try std.testing.expect(std.mem.indexOf(u8, content, "recentSymbols") != null);
            try std.testing.expect(std.mem.indexOf(u8, content, "Recent Cog evidence") != null);
            try std.testing.expect(std.mem.indexOf(u8, content, "Cog memory quality") != null);
            try std.testing.expect(std.mem.indexOf(u8, content, "pendingConsolidation") != null);
            try std.testing.expect(std.mem.indexOf(u8, content, "delegate to the cog-mem subagent") != null);
            try std.testing.expect(std.mem.indexOf(u8, content, "memoryTriageActive") != null);
            try std.testing.expect(std.mem.indexOf(u8, content, "Do not launch Explore") != null);
        }
    }.run);
}

test "writeRuntimePolicyAsset creates Claude hook asset" {
    try withTempCwd(struct {
        fn run(allocator: std.mem.Allocator) !void {
            _ = allocator;
            try writeRuntimePolicyAsset(".claude/hooks/cog-pretooluse.sh", claude_pretooluse_hook_content);

            const content = readCwdFile(std.testing.allocator, ".claude/hooks/cog-pretooluse.sh") orelse return error.TestUnexpectedResult;
            defer std.testing.allocator.free(content);

            try std.testing.expect(std.mem.indexOf(u8, content, "transcript_path") != null);
            try std.testing.expect(std.mem.indexOf(u8, content, "mcp__cog__code_explore") != null);
            try std.testing.expect(std.mem.indexOf(u8, content, "Use Cog code intelligence tools before raw text search") != null);
            try std.testing.expect(std.mem.indexOf(u8, content, "Cog memory quality") != null);
            try std.testing.expect(std.mem.indexOf(u8, content, "delegate to the cog-mem sub-agent first to check memory") != null);
        }
    }.run);
}

test "writeRuntimePolicyAsset creates Gemini hook asset" {
    try withTempCwd(struct {
        fn run(allocator: std.mem.Allocator) !void {
            _ = allocator;
            try writeRuntimePolicyAsset(".gemini/hooks/cog-before-tool.sh", gemini_before_tool_hook_content);

            const content = readCwdFile(std.testing.allocator, ".gemini/hooks/cog-before-tool.sh") orelse return error.TestUnexpectedResult;
            defer std.testing.allocator.free(content);

            try std.testing.expect(std.mem.indexOf(u8, content, "run_shell_command") != null);
            try std.testing.expect(std.mem.indexOf(u8, content, "Cog policy") != null);
            try std.testing.expect(std.mem.indexOf(u8, content, "Cog memory quality") != null);
        }
    }.run);
}

test "writeRuntimePolicyAsset creates Amp plugin asset" {
    try withTempCwd(struct {
        fn run(allocator: std.mem.Allocator) !void {
            _ = allocator;
            try writeRuntimePolicyAsset(".amp/plugins/cog.ts", amp_cog_plugin_content);

            const content = readCwdFile(std.testing.allocator, ".amp/plugins/cog.ts") orelse return error.TestUnexpectedResult;
            defer std.testing.allocator.free(content);

            try std.testing.expect(std.mem.indexOf(u8, content, "tool.call") != null);
            try std.testing.expect(std.mem.indexOf(u8, content, "tool.result") != null);
            try std.testing.expect(std.mem.indexOf(u8, content, "agent.end") != null);
            try std.testing.expect(std.mem.indexOf(u8, content, "hasCogWorkspaceConfig") != null);
            try std.testing.expect(std.mem.indexOf(u8, content, "pendingConsolidation") != null);
            try std.testing.expect(std.mem.indexOf(u8, content, "Cog memory workflow") != null);
        }
    }.run);
}

test "runtimePolicyAssets stay capability-driven" {
    const claude_assets = runtimePolicyAssets(agents_mod.agents[0]);
    try std.testing.expectEqual(@as(usize, 4), claude_assets.len);
    try std.testing.expectEqualStrings(".claude/hooks/cog-pretooluse.sh", claude_assets[0].path);
    try std.testing.expectEqualStrings(".claude/hooks/cog-stop-memory.sh", claude_assets[1].path);
    try std.testing.expectEqualStrings(".claude/hooks/cog-posttooluse-failure.sh", claude_assets[2].path);
    try std.testing.expectEqualStrings(".claude/hooks/cog-precompact.sh", claude_assets[3].path);

    const gemini_assets = runtimePolicyAssets(agents_mod.agents[1]);
    try std.testing.expectEqual(@as(usize, 1), gemini_assets.len);
    try std.testing.expectEqualStrings(".gemini/hooks/cog-before-tool.sh", gemini_assets[0].path);

    const amp_assets = runtimePolicyAssets(agents_mod.agents[6]);
    try std.testing.expectEqual(@as(usize, 1), amp_assets.len);
    try std.testing.expectEqualStrings(".amp/plugins/cog.ts", amp_assets[0].path);

    const opencode_assets = runtimePolicyAssets(agents_mod.agents[9]);
    try std.testing.expectEqual(@as(usize, 3), opencode_assets.len);
    try std.testing.expectEqualStrings(".opencode/plugins/cog-override.ts", opencode_assets[0].path);
    try std.testing.expectEqual(@as(usize, 0), runtimePolicyAssets(agents_mod.agents[2]).len);
}

test "writeTomlMcp appends once and is idempotent" {
    try withTempCwd(struct {
        fn run(allocator: std.mem.Allocator) !void {
            const initial =
                \\model = "gpt-5"
            ;
            try writeCwdFile("config.toml", initial);

            try writeTomlMcp(allocator, "config.toml");
            try writeTomlMcp(allocator, "config.toml");

            const updated = readCwdFile(allocator, "config.toml") orelse return error.TestUnexpectedResult;
            defer allocator.free(updated);

            const marker = "[mcp_servers.cog]";
            const first = std.mem.indexOf(u8, updated, marker) orelse return error.TestUnexpectedResult;
            const second = std.mem.indexOfPos(u8, updated, first + marker.len, marker);
            try std.testing.expect(second == null);
        }
    }.run);
}

test "writeClaudePermissions creates correct JSON" {
    try withTempCwd(struct {
        fn run(allocator: std.mem.Allocator) !void {
            try writeClaudePermissions(allocator);

            const content = readCwdFile(allocator, ".claude/settings.json") orelse return error.TestUnexpectedResult;
            defer allocator.free(content);

            const parsed = try json.parseFromSlice(json.Value, allocator, content, .{});
            defer parsed.deinit();

            const perms = parsed.value.object.get("permissions") orelse return error.TestUnexpectedResult;
            try std.testing.expect(perms == .object);
            const allow = perms.object.get("allow") orelse return error.TestUnexpectedResult;
            try std.testing.expect(allow == .array);
            try std.testing.expectEqual(@as(usize, 1), allow.array.items.len);
            try std.testing.expectEqualStrings("mcp__cog__*", allow.array.items[0].string);
        }
    }.run);
}

test "writeClaudePermissions merges with existing permissions" {
    try withTempCwd(struct {
        fn run(allocator: std.mem.Allocator) !void {
            std.fs.cwd().makeDir(".claude") catch {};
            const existing =
                \\{"other_key":"value","permissions":{"allow":["Bash(*)"],"deny":["Write(~/)"]}}
            ;
            try writeCwdFile(".claude/settings.json", existing);

            try writeClaudePermissions(allocator);

            const content = readCwdFile(allocator, ".claude/settings.json") orelse return error.TestUnexpectedResult;
            defer allocator.free(content);

            const parsed = try json.parseFromSlice(json.Value, allocator, content, .{});
            defer parsed.deinit();

            // Preserved other_key
            const other = parsed.value.object.get("other_key") orelse return error.TestUnexpectedResult;
            try std.testing.expectEqualStrings("value", other.string);

            const perms = parsed.value.object.get("permissions") orelse return error.TestUnexpectedResult;

            // Preserved deny
            const deny = perms.object.get("deny") orelse return error.TestUnexpectedResult;
            try std.testing.expect(deny == .array);
            try std.testing.expectEqual(@as(usize, 1), deny.array.items.len);

            // allow has both original + cog
            const allow = perms.object.get("allow") orelse return error.TestUnexpectedResult;
            try std.testing.expect(allow == .array);
            try std.testing.expectEqual(@as(usize, 2), allow.array.items.len);
            try std.testing.expectEqualStrings("Bash(*)", allow.array.items[0].string);
            try std.testing.expectEqualStrings("mcp__cog__*", allow.array.items[1].string);
        }
    }.run);
}

test "writeClaudePermissions is idempotent" {
    try withTempCwd(struct {
        fn run(allocator: std.mem.Allocator) !void {
            try writeClaudePermissions(allocator);
            try writeClaudePermissions(allocator);

            const content = readCwdFile(allocator, ".claude/settings.json") orelse return error.TestUnexpectedResult;
            defer allocator.free(content);

            const parsed = try json.parseFromSlice(json.Value, allocator, content, .{});
            defer parsed.deinit();

            const allow = parsed.value.object.get("permissions").?.object.get("allow").?;
            try std.testing.expectEqual(@as(usize, 1), allow.array.items.len);

            const enabled = parsed.value.object.get("enabledMcpjsonServers") orelse return error.TestUnexpectedResult;
            try std.testing.expect(enabled == .array);
            try std.testing.expectEqual(@as(usize, 1), enabled.array.items.len);
            try std.testing.expectEqualStrings("cog", enabled.array.items[0].string);
        }
    }.run);
}

test "writeClaudePermissions preserves existing enabledMcpjsonServers" {
    try withTempCwd(struct {
        fn run(allocator: std.mem.Allocator) !void {
            std.fs.cwd().makeDir(".claude") catch {};
            const existing =
                \\{"enabledMcpjsonServers":["github"]}
            ;
            try writeCwdFile(".claude/settings.json", existing);

            try writeClaudePermissions(allocator);

            const content = readCwdFile(allocator, ".claude/settings.json") orelse return error.TestUnexpectedResult;
            defer allocator.free(content);

            const parsed = try json.parseFromSlice(json.Value, allocator, content, .{});
            defer parsed.deinit();

            const enabled = parsed.value.object.get("enabledMcpjsonServers") orelse return error.TestUnexpectedResult;
            try std.testing.expect(enabled == .array);
            try std.testing.expectEqual(@as(usize, 2), enabled.array.items.len);
            try std.testing.expectEqualStrings("github", enabled.array.items[0].string);
            try std.testing.expectEqualStrings("cog", enabled.array.items[1].string);
        }
    }.run);
}

test "writeClaudeRuntimeHooks adds pretooluse hook" {
    try withTempCwd(struct {
        fn run(allocator: std.mem.Allocator) !void {
            try writeClaudeRuntimeHooks(allocator);

            const content = readCwdFile(allocator, ".claude/settings.json") orelse return error.TestUnexpectedResult;
            defer allocator.free(content);

            const parsed = try json.parseFromSlice(json.Value, allocator, content, .{});
            defer parsed.deinit();

            const hooks = parsed.value.object.get("hooks") orelse return error.TestUnexpectedResult;
            const pretool = hooks.object.get("PreToolUse") orelse return error.TestUnexpectedResult;
            const stop = hooks.object.get("Stop") orelse return error.TestUnexpectedResult;
            try std.testing.expect(pretool == .array);
            try std.testing.expect(stop == .array);
            try std.testing.expectEqual(@as(usize, 1), pretool.array.items.len);
            try std.testing.expectEqual(@as(usize, 1), stop.array.items.len);
            try std.testing.expectEqualStrings("Grep|Glob|Bash|Agent|mcp__cog__code_explore|mcp__cog__code_query", pretool.array.items[0].object.get("matcher").?.string);
            try std.testing.expectEqualStrings("sh \"$CLAUDE_PROJECT_DIR\"/.claude/hooks/cog-stop-memory.sh", stop.array.items[0].object.get("hooks").?.array.items[0].object.get("command").?.string);
        }
    }.run);
}

test "writeClaudeRuntimeHooks preserves existing hooks" {
    try withTempCwd(struct {
        fn run(allocator: std.mem.Allocator) !void {
            std.fs.cwd().makeDir(".claude") catch {};
            const existing =
                \\{"hooks":{"PostToolUse":[{"matcher":"Write","hooks":[{"type":"command","command":"echo keep"}]}]}}
            ;
            try writeCwdFile(".claude/settings.json", existing);

            try writeClaudeRuntimeHooks(allocator);

            const content = readCwdFile(allocator, ".claude/settings.json") orelse return error.TestUnexpectedResult;
            defer allocator.free(content);

            const parsed = try json.parseFromSlice(json.Value, allocator, content, .{});
            defer parsed.deinit();

            const hooks = parsed.value.object.get("hooks") orelse return error.TestUnexpectedResult;
            try std.testing.expect(hooks.object.get("PostToolUse") != null);
            try std.testing.expect(hooks.object.get("PreToolUse") != null);
            try std.testing.expect(hooks.object.get("Stop") != null);
        }
    }.run);
}

test "writeClaudeRuntimeHooks is idempotent for stop hook" {
    try withTempCwd(struct {
        fn run(allocator: std.mem.Allocator) !void {
            try writeClaudeRuntimeHooks(allocator);
            try writeClaudeRuntimeHooks(allocator);

            const content = readCwdFile(allocator, ".claude/settings.json") orelse return error.TestUnexpectedResult;
            defer allocator.free(content);

            const parsed = try json.parseFromSlice(json.Value, allocator, content, .{});
            defer parsed.deinit();

            const stop = parsed.value.object.get("hooks").?.object.get("Stop").?;
            try std.testing.expect(stop == .array);
            try std.testing.expectEqual(@as(usize, 1), stop.array.items.len);
        }
    }.run);
}

test "writeRuntimePolicyAsset creates Claude stop hook asset" {
    try withTempCwd(struct {
        fn run(allocator: std.mem.Allocator) !void {
            _ = allocator;
            try writeRuntimePolicyAsset(".claude/hooks/cog-stop-memory.sh", claude_stop_memory_hook_content);

            const content = readCwdFile(std.testing.allocator, ".claude/hooks/cog-stop-memory.sh") orelse return error.TestUnexpectedResult;
            defer std.testing.allocator.free(content);

            try std.testing.expect(std.mem.indexOf(u8, content, "stop_hook_active") != null);
            try std.testing.expect(std.mem.indexOf(u8, content, "transcript_path") != null);
            try std.testing.expect(std.mem.indexOf(u8, content, "mcp__cog__mem_learn") != null);
            try std.testing.expect(std.mem.indexOf(u8, content, "mcp__cog__mem_list_short_term") != null);
            try std.testing.expect(std.mem.indexOf(u8, content, "mcp__cog__mem_reinforce") != null);
        }
    }.run);
}

test "writeGeminiTrust adds trust field to cog entry" {
    try withTempCwd(struct {
        fn run(allocator: std.mem.Allocator) !void {
            std.fs.cwd().makeDir(".gemini") catch {};
            const existing =
                \\{"mcpServers":{"cog":{"command":"cog","args":["mcp"]},"other":{"command":"other"}}}
            ;
            try writeCwdFile(".gemini/settings.json", existing);

            try writeGeminiTrust(allocator, ".gemini/settings.json");

            const content = readCwdFile(allocator, ".gemini/settings.json") orelse return error.TestUnexpectedResult;
            defer allocator.free(content);

            const parsed = try json.parseFromSlice(json.Value, allocator, content, .{});
            defer parsed.deinit();

            const servers = parsed.value.object.get("mcpServers") orelse return error.TestUnexpectedResult;
            const cog = servers.object.get("cog") orelse return error.TestUnexpectedResult;

            // Has trust: true
            const trust = cog.object.get("trust") orelse return error.TestUnexpectedResult;
            try std.testing.expect(trust == .bool);
            try std.testing.expect(trust.bool);

            // Preserved command
            const cmd = cog.object.get("command") orelse return error.TestUnexpectedResult;
            try std.testing.expectEqualStrings("cog", cmd.string);

            // Other server untouched
            try std.testing.expect(servers.object.get("other") != null);
        }
    }.run);
}

test "writeGeminiRuntimeHooks adds before tool hook" {
    try withTempCwd(struct {
        fn run(allocator: std.mem.Allocator) !void {
            std.fs.cwd().makeDir(".gemini") catch {};
            const existing =
                \\{"mcpServers":{"cog":{"command":"cog","args":["mcp"]}}}
            ;
            try writeCwdFile(".gemini/settings.json", existing);

            try writeGeminiRuntimeHooks(allocator, ".gemini/settings.json");

            const content = readCwdFile(allocator, ".gemini/settings.json") orelse return error.TestUnexpectedResult;
            defer allocator.free(content);

            const parsed = try json.parseFromSlice(json.Value, allocator, content, .{});
            defer parsed.deinit();

            const hooks = parsed.value.object.get("hooks") orelse return error.TestUnexpectedResult;
            const before = hooks.object.get("BeforeTool") orelse return error.TestUnexpectedResult;
            try std.testing.expect(before == .array);
            try std.testing.expectEqualStrings("cog-before-tool", before.array.items[0].object.get("name").?.string);
        }
    }.run);
}

test "writeGeminiRuntimeHooks preserves existing hooks" {
    try withTempCwd(struct {
        fn run(allocator: std.mem.Allocator) !void {
            std.fs.cwd().makeDir(".gemini") catch {};
            const existing =
                \\{"mcpServers":{"cog":{"command":"cog","args":["mcp"]}},"hooks":{"AfterTool":[{"name":"keep-me","type":"command","command":"echo keep"}]}}
            ;
            try writeCwdFile(".gemini/settings.json", existing);

            try writeGeminiRuntimeHooks(allocator, ".gemini/settings.json");

            const content = readCwdFile(allocator, ".gemini/settings.json") orelse return error.TestUnexpectedResult;
            defer allocator.free(content);

            const parsed = try json.parseFromSlice(json.Value, allocator, content, .{});
            defer parsed.deinit();

            const hooks = parsed.value.object.get("hooks") orelse return error.TestUnexpectedResult;
            try std.testing.expect(hooks.object.get("AfterTool") != null);
            try std.testing.expect(hooks.object.get("BeforeTool") != null);
        }
    }.run);
}

test "writeAmpPermissions adds permissions array" {
    try withTempCwd(struct {
        fn run(allocator: std.mem.Allocator) !void {
            std.fs.cwd().makeDir(".amp") catch {};
            const existing =
                \\{"amp.mcpServers":{"cog":{"command":"cog","args":["mcp"]}}}
            ;
            try writeCwdFile(".amp/settings.json", existing);

            try writeAmpPermissions(allocator, ".amp/settings.json");

            const content = readCwdFile(allocator, ".amp/settings.json") orelse return error.TestUnexpectedResult;
            defer allocator.free(content);

            const parsed = try json.parseFromSlice(json.Value, allocator, content, .{});
            defer parsed.deinit();

            // Preserved mcpServers
            try std.testing.expect(parsed.value.object.get("amp.mcpServers") != null);

            // Has amp.permissions
            const perms = parsed.value.object.get("amp.permissions") orelse return error.TestUnexpectedResult;
            try std.testing.expect(perms == .array);
            try std.testing.expectEqual(@as(usize, 1), perms.array.items.len);

            const rule = perms.array.items[0];
            try std.testing.expect(rule == .object);
            const tool = rule.object.get("tool") orelse return error.TestUnexpectedResult;
            try std.testing.expectEqualStrings("mcp__cog__*", tool.string);
            const action = rule.object.get("action") orelse return error.TestUnexpectedResult;
            try std.testing.expectEqualStrings("allow", action.string);
        }
    }.run);
}

test "writeAmpPermissions is idempotent" {
    try withTempCwd(struct {
        fn run(allocator: std.mem.Allocator) !void {
            std.fs.cwd().makeDir(".amp") catch {};
            const existing =
                \\{"amp.mcpServers":{"cog":{"command":"cog","args":["mcp"]}}}
            ;
            try writeCwdFile(".amp/settings.json", existing);

            try writeAmpPermissions(allocator, ".amp/settings.json");
            try writeAmpPermissions(allocator, ".amp/settings.json");

            const content = readCwdFile(allocator, ".amp/settings.json") orelse return error.TestUnexpectedResult;
            defer allocator.free(content);

            const parsed = try json.parseFromSlice(json.Value, allocator, content, .{});
            defer parsed.deinit();

            const perms = parsed.value.object.get("amp.permissions").?;
            try std.testing.expectEqual(@as(usize, 1), perms.array.items.len);
        }
    }.run);
}

test "writeMarkdownAgent creates correct file" {
    try withTempCwd(struct {
        fn run(allocator: std.mem.Allocator) !void {
            const header =
                \\---
                \\name: cog-code-query
                \\description: Test agent
                \\---
            ;

            try writeMarkdownAgent(allocator, ".claude/agents/cog-code-query.md", header, build_options.agent_body);

            const content = readCwdFile(allocator, ".claude/agents/cog-code-query.md") orelse return error.TestUnexpectedResult;
            defer allocator.free(content);

            // Contains the header
            try std.testing.expect(std.mem.indexOf(u8, content, "name: cog-code-query") != null);
            // Contains the body
            try std.testing.expect(std.mem.indexOf(u8, content, "code index exploration agent") != null);
            // Contains workflow content
            try std.testing.expect(std.mem.indexOf(u8, content, "Batch explore") != null);
        }
    }.run);
}

test "writeJsonOpenCode adds cog plugins" {
    try withTempCwd(struct {
        fn run(allocator: std.mem.Allocator) !void {
            const existing =
                \\{"plugin":["existing-plugin"],"mcp":{"other":{"type":"local","command":["other"]}}}
            ;
            try writeCwdFile("opencode.json", existing);

            try writeJsonOpenCode(allocator, "opencode.json");

            const content = readCwdFile(allocator, "opencode.json") orelse return error.TestUnexpectedResult;
            defer allocator.free(content);

            const parsed = try json.parseFromSlice(json.Value, allocator, content, .{});
            defer parsed.deinit();

            const plugins = parsed.value.object.get("plugin") orelse return error.TestUnexpectedResult;
            try std.testing.expect(plugins == .array);

            var has_override = false;
            var has_memory = false;
            var has_existing = false;
            for (plugins.array.items) |item| {
                if (item != .string) continue;
                if (std.mem.eql(u8, item.string, "cog-override")) has_override = true;
                if (std.mem.eql(u8, item.string, "cog-memory")) has_memory = true;
                if (std.mem.eql(u8, item.string, "existing-plugin")) has_existing = true;
            }

            try std.testing.expect(has_override);
            try std.testing.expect(has_memory);
            try std.testing.expect(has_existing);
        }
    }.run);
}

test "writeMarkdownAgent is idempotent" {
    try withTempCwd(struct {
        fn run(allocator: std.mem.Allocator) !void {
            const header =
                \\---
                \\name: cog-code-query
                \\---
            ;

            try writeMarkdownAgent(allocator, ".test/agent.md", header, build_options.agent_body);
            const first = readCwdFile(allocator, ".test/agent.md") orelse return error.TestUnexpectedResult;
            defer allocator.free(first);

            try writeMarkdownAgent(allocator, ".test/agent.md", header, build_options.agent_body);
            const second = readCwdFile(allocator, ".test/agent.md") orelse return error.TestUnexpectedResult;
            defer allocator.free(second);

            try std.testing.expectEqualStrings(first, second);
        }
    }.run);
}

test "writeTomlAgent appends section" {
    try withTempCwd(struct {
        fn run(allocator: std.mem.Allocator) !void {
            const initial =
                \\model = "gpt-5"
                \\
                \\[mcp_servers.cog]
                \\command = "cog"
                \\args = ["mcp"]
            ;
            std.fs.cwd().makeDir(".codex") catch {};
            try writeCwdFile(".codex/config.toml", initial);

            try writeTomlAgent(allocator, ".codex/config.toml", "cog-code-query", "Explore code structure using the Cog SCIP index", build_options.agent_body);

            const content = readCwdFile(allocator, ".codex/config.toml") orelse return error.TestUnexpectedResult;
            defer allocator.free(content);

            // Has the original content
            try std.testing.expect(std.mem.indexOf(u8, content, "model = \"gpt-5\"") != null);
            // Has the agent section
            try std.testing.expect(std.mem.indexOf(u8, content, "[agents.cog-code-query]") != null);
            // Has the description
            try std.testing.expect(std.mem.indexOf(u8, content, "description = \"Explore code structure") != null);
        }
    }.run);
}

test "buildCodexSpecialistInstructions adds host guidance" {
    const code_query = try buildCodexSpecialistInstructions(std.testing.allocator, .code_query, build_options.agent_body);
    defer std.testing.allocator.free(code_query);
    try std.testing.expect(std.mem.indexOf(u8, code_query, "Treat this specialist as read-only") != null);
    try std.testing.expect(std.mem.indexOf(u8, code_query, "Use Cog code intelligence before any raw file search") != null);

    const memory = try buildCodexSpecialistInstructions(std.testing.allocator, .memory, build_options.mem_agent_body);
    defer std.testing.allocator.free(memory);
    try std.testing.expect(std.mem.indexOf(u8, memory, "Start with Cog memory recall") != null);
}

test "buildWorkflowSpecialistInstructions adds workflow guidance" {
    const code_query = try buildWorkflowSpecialistInstructions(std.testing.allocator, "Windsurf", .code_query, build_options.agent_body);
    defer std.testing.allocator.free(code_query);
    try std.testing.expect(std.mem.indexOf(u8, code_query, "workflow files rather than hard-scoped subagents") != null);
    try std.testing.expect(std.mem.indexOf(u8, code_query, "inside Windsurf") != null);

    const memory = try buildWorkflowSpecialistInstructions(std.testing.allocator, "Goose", .memory, build_options.mem_agent_body);
    defer std.testing.allocator.free(memory);
    try std.testing.expect(std.mem.indexOf(u8, memory, "include engram IDs when memory changes") != null);
}

test "buildPromptOnlySpecialistInstructions adds host guidance" {
    const code_query = try buildPromptOnlySpecialistInstructions(std.testing.allocator, "Cursor", .code_query, build_options.agent_body);
    defer std.testing.allocator.free(code_query);
    try std.testing.expect(std.mem.indexOf(u8, code_query, "Cursor cannot hard-deny tools per specialist") != null);
    try std.testing.expect(std.mem.indexOf(u8, code_query, "Do not edit files or run shell commands") != null);

    const memory = try buildPromptOnlySpecialistInstructions(std.testing.allocator, "GitHub Copilot", .memory, build_options.mem_agent_body);
    defer std.testing.allocator.free(memory);
    try std.testing.expect(std.mem.indexOf(u8, memory, "focused on Cog memory workflows") != null);
    try std.testing.expect(std.mem.indexOf(u8, memory, "engram IDs") != null);
}

test "buildConfigScopedSpecialistInstructions adds host guidance" {
    const code_query = try buildConfigScopedSpecialistInstructions(std.testing.allocator, "Gemini CLI", .code_query, build_options.agent_body);
    defer std.testing.allocator.free(code_query);
    try std.testing.expect(std.mem.indexOf(u8, code_query, "Gemini CLI provides config-level tool scoping") != null);
    try std.testing.expect(std.mem.indexOf(u8, code_query, "Stay inside the allowed read and Cog code-intel tools") != null);

    const debug = try buildConfigScopedSpecialistInstructions(std.testing.allocator, "Gemini CLI", .debug, build_options.debug_agent_body);
    defer std.testing.allocator.free(debug);
    try std.testing.expect(std.mem.indexOf(u8, debug, "partial config-level scoping") != null);
    try std.testing.expect(std.mem.indexOf(u8, debug, "requested test loop") != null);
}

test "skill-based prompt-only agents get host-specific content" {
    try withTempCwd(struct {
        fn run(allocator: std.mem.Allocator) !void {
            try configureAgentFile(allocator, agents_mod.agents[3]); // windsurf
            const windsurf = readCwdFile(allocator, ".windsurf/skills/cog-code-query/SKILL.md") orelse return error.TestUnexpectedResult;
            defer allocator.free(windsurf);
            try std.testing.expect(std.mem.indexOf(u8, windsurf, "Windsurf cannot hard-deny tools per specialist") != null);

            try configureMemAgentFile(allocator, agents_mod.agents[7]); // goose
            const goose = readCwdFile(allocator, ".goose/skills/cog-mem/SKILL.md") orelse return error.TestUnexpectedResult;
            defer allocator.free(goose);
            try std.testing.expect(std.mem.indexOf(u8, goose, "Goose cannot hard-deny tools per specialist") != null);
            try std.testing.expect(std.mem.indexOf(u8, goose, "engram IDs") != null);
        }
    }.run);
}

test "prompt-only dedicated agents get host-specific content" {
    try withTempCwd(struct {
        fn run(allocator: std.mem.Allocator) !void {
            try configureAgentFile(allocator, agents_mod.agents[4]); // cursor
            try std.testing.expect(readCwdFile(allocator, ".cursor/agents/cog-code-query.md") == null);

            try configureMemAgentFile(allocator, agents_mod.agents[2]); // copilot
            const copilot = readCwdFile(allocator, ".github/agents/cog-mem.agent.md") orelse return error.TestUnexpectedResult;
            defer allocator.free(copilot);
            try std.testing.expect(std.mem.indexOf(u8, copilot, "GitHub Copilot cannot hard-deny tools per specialist") != null);
        }
    }.run);
}

test "config-scoped dedicated agents get host-specific content" {
    try withTempCwd(struct {
        fn run(allocator: std.mem.Allocator) !void {
            try configureAgentFile(allocator, agents_mod.agents[1]); // gemini
            const query = readCwdFile(allocator, ".gemini/agents/cog-code-query.md") orelse return error.TestUnexpectedResult;
            defer allocator.free(query);
            try std.testing.expect(std.mem.indexOf(u8, query, "Gemini CLI provides config-level tool scoping") != null);

            try configureMemAgentFile(allocator, agents_mod.agents[0]); // claude
            const mem = readCwdFile(allocator, ".claude/agents/cog-mem.md") orelse return error.TestUnexpectedResult;
            defer allocator.free(mem);
            try std.testing.expect(std.mem.indexOf(u8, mem, "config-level scoping for this memory specialist") != null);
            try std.testing.expect(std.mem.indexOf(u8, mem, "engram IDs") != null);
        }
    }.run);
}

test "writeTomlAgent is idempotent" {
    try withTempCwd(struct {
        fn run(allocator: std.mem.Allocator) !void {
            std.fs.cwd().makeDir(".codex") catch {};
            try writeCwdFile(".codex/config.toml", "model = \"gpt-5\"\n");

            try writeTomlAgent(allocator, ".codex/config.toml", "cog-code-query", "Explore code structure using the Cog SCIP index", build_options.agent_body);
            try writeTomlAgent(allocator, ".codex/config.toml", "cog-code-query", "Explore code structure using the Cog SCIP index", build_options.agent_body);

            const content = readCwdFile(allocator, ".codex/config.toml") orelse return error.TestUnexpectedResult;
            defer allocator.free(content);

            const marker = "[agents.cog-code-query]";
            const first = std.mem.indexOf(u8, content, marker) orelse return error.TestUnexpectedResult;
            const second = std.mem.indexOfPos(u8, content, first + marker.len, marker);
            try std.testing.expect(second == null);
        }
    }.run);
}

test "writeRooAgent creates .roomodes" {
    try withTempCwd(struct {
        fn run(allocator: std.mem.Allocator) !void {
            try writeRooAgent(allocator, ".roomodes", "cog-code-query", "Cog Code Query", "You are a code index exploration agent.");

            const content = readCwdFile(allocator, ".roomodes") orelse return error.TestUnexpectedResult;
            defer allocator.free(content);

            const parsed = try json.parseFromSlice(json.Value, allocator, content, .{});
            defer parsed.deinit();

            const modes = parsed.value.object.get("customModes") orelse return error.TestUnexpectedResult;
            try std.testing.expect(modes == .array);
            try std.testing.expectEqual(@as(usize, 1), modes.array.items.len);

            const mode = modes.array.items[0];
            try std.testing.expect(mode == .object);
            const slug = mode.object.get("slug") orelse return error.TestUnexpectedResult;
            try std.testing.expectEqualStrings("cog-code-query", slug.string);
            try std.testing.expectEqualStrings("Explore code structure using the Cog SCIP index", mode.object.get("description").?.string);
            try std.testing.expect(mode.object.get("roleDefinition") != null);
            try std.testing.expect(mode.object.get("customInstructions") != null);

            const groups = mode.object.get("groups") orelse return error.TestUnexpectedResult;
            try std.testing.expect(groups == .array);
            try std.testing.expectEqual(@as(usize, 2), groups.array.items.len);
            try std.testing.expectEqualStrings("read", groups.array.items[0].string);
            try std.testing.expectEqualStrings("mcp", groups.array.items[1].string);
        }
    }.run);
}

test "writeRooAgent merges with existing modes" {
    try withTempCwd(struct {
        fn run(allocator: std.mem.Allocator) !void {
            const existing =
                \\{"customModes":[{"slug":"my-mode","name":"My Mode","roleDefinition":"custom"}]}
            ;
            try writeCwdFile(".roomodes", existing);

            try writeRooAgent(allocator, ".roomodes", "cog-code-query", "Cog Code Query", "You are a code index exploration agent.");

            const content = readCwdFile(allocator, ".roomodes") orelse return error.TestUnexpectedResult;
            defer allocator.free(content);

            const parsed = try json.parseFromSlice(json.Value, allocator, content, .{});
            defer parsed.deinit();

            const modes = parsed.value.object.get("customModes") orelse return error.TestUnexpectedResult;
            try std.testing.expect(modes == .array);
            try std.testing.expectEqual(@as(usize, 2), modes.array.items.len);

            // Original mode preserved
            const first = modes.array.items[0];
            const first_slug = first.object.get("slug") orelse return error.TestUnexpectedResult;
            try std.testing.expectEqualStrings("my-mode", first_slug.string);

            // Cog mode added
            const second = modes.array.items[1];
            const second_slug = second.object.get("slug") orelse return error.TestUnexpectedResult;
            try std.testing.expectEqualStrings("cog-code-query", second_slug.string);
            const second_groups = second.object.get("groups") orelse return error.TestUnexpectedResult;
            try std.testing.expect(second_groups == .array);
            try std.testing.expectEqualStrings("mcp", second_groups.array.items[1].string);
        }
    }.run);
}

test "writeRooAgent assigns mode-specific groups" {
    try withTempCwd(struct {
        fn run(allocator: std.mem.Allocator) !void {
            try writeRooAgent(allocator, ".roomodes", "cog-debug", "Cog Debug", "debug role");
            try writeRooAgent(allocator, ".roomodes", "cog-mem", "Cog Memory", "memory role");

            const content = readCwdFile(allocator, ".roomodes") orelse return error.TestUnexpectedResult;
            defer allocator.free(content);

            const parsed = try json.parseFromSlice(json.Value, allocator, content, .{});
            defer parsed.deinit();

            const modes = parsed.value.object.get("customModes") orelse return error.TestUnexpectedResult;
            const debug_mode = modes.array.items[0];
            const mem_mode = modes.array.items[1];

            const debug_groups = debug_mode.object.get("groups") orelse return error.TestUnexpectedResult;
            try std.testing.expectEqual(@as(usize, 3), debug_groups.array.items.len);
            try std.testing.expectEqualStrings("command", debug_groups.array.items[1].string);

            const mem_groups = mem_mode.object.get("groups") orelse return error.TestUnexpectedResult;
            try std.testing.expectEqual(@as(usize, 1), mem_groups.array.items.len);
            try std.testing.expectEqualStrings("mcp", mem_groups.array.items[0].string);
        }
    }.run);
}
