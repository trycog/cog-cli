const std = @import("std");
const json = std.json;
const Stringify = json.Stringify;
const Writer = std.io.Writer;
const agents_mod = @import("agents.zig");
const build_options = @import("build_options");
const debug_log = @import("debug_log.zig");
const fs_util = @import("fs_util.zig");
const tree_sitter_indexer = @import("tree_sitter_indexer.zig");

// ANSI styles
const cyan = "\x1B[36m";
const bold = "\x1B[1m";
const dim = "\x1B[2m";
const reset = "\x1B[0m";

// ── Helpers ─────────────────────────────────────────────────────────────

const max_host_config_bytes: usize = 1048576;

const HostConfigKind = union(enum) {
    json: []const HostConfigField,
    toml,
};

const HostConfigFieldType = enum {
    object,
    array,
};

const HostConfigField = struct {
    name: []const u8,
    expected: HostConfigFieldType,
};

fn printErr(msg: []const u8) void {
    var buf: [4096]u8 = undefined;
    var w = std.fs.File.stderr().writerStreaming(&buf);
    w.interface.writeAll(msg) catch {};
    w.interface.flush() catch {};
}

fn reportHostConfigError(path: []const u8, detail: []const u8) void {
    printErr("  error: host config ");
    printErr(path);
    printErr(" ");
    printErr(detail);
    printErr("; fix or remove the file, then retry\n");
}

fn reportHostConfigFieldTypeError(path: []const u8, field: []const u8, expected: HostConfigFieldType) void {
    printErr("  error: host config ");
    printErr(path);
    printErr(" field '");
    printErr(field);
    printErr("' must be a JSON ");
    printErr(@tagName(expected));
    printErr("; fix or remove the file, then retry\n");
}

fn ensureDir(path: []const u8) !void {
    debug_log.log("hooks.ensureDir: path={s}", .{path});
    std.fs.cwd().makePath(path) catch |err| {
        debug_log.log("hooks.ensureDir: failed path={s} error={s}", .{ path, @errorName(err) });
        printErr("  error: failed to create directory ");
        printErr(path);
        printErr("\n");
        return error.Explained;
    };
}

fn writeCwdFile(filename: []const u8, content: []const u8) !void {
    debug_log.log("hooks.writeCwdFile: path={s} bytes={d}", .{ filename, content.len });
    fs_util.writeFileAtomic(std.fs.cwd(), std.heap.page_allocator, filename, content) catch |err| {
        debug_log.log("hooks.writeCwdFile: failed path={s} error={s}", .{ filename, @errorName(err) });
        printErr("  error: failed to write ");
        printErr(filename);
        printErr("\n");
        return error.Explained;
    };
    debug_log.log("hooks.writeCwdFile: committed path={s}", .{filename});
}

pub fn fileExistsInCwd(path: []const u8) bool {
    const f = std.fs.cwd().openFile(path, .{}) catch return false;
    f.close();
    return true;
}

fn readCwdFile(allocator: std.mem.Allocator, filename: []const u8) !?[]const u8 {
    debug_log.log("hooks.readCwdFile: open path={s}", .{filename});
    const f = std.fs.cwd().openFile(filename, .{}) catch |err| switch (err) {
        error.FileNotFound => {
            debug_log.log("hooks.readCwdFile: missing path={s}", .{filename});
            return null;
        },
        else => {
            debug_log.log("hooks.readCwdFile: unreadable path={s} error={s}", .{ filename, @errorName(err) });
            reportHostConfigError(filename, "could not be read");
            return error.HostConfigUnreadable;
        },
    };
    defer f.close();

    const content = f.readToEndAlloc(allocator, max_host_config_bytes) catch |err| switch (err) {
        error.FileTooBig => {
            debug_log.log("hooks.readCwdFile: oversized path={s} cap={d}", .{ filename, max_host_config_bytes });
            reportHostConfigError(filename, "exceeds the 1 MiB size limit");
            return error.HostConfigTooLarge;
        },
        else => {
            debug_log.log("hooks.readCwdFile: read failed path={s} error={s}", .{ filename, @errorName(err) });
            reportHostConfigError(filename, "could not be read");
            return error.HostConfigUnreadable;
        },
    };
    debug_log.log("hooks.readCwdFile: read path={s} bytes={d}", .{ filename, content.len });
    return content;
}

fn validateHostConfig(path: []const u8, kind: HostConfigKind, content: []const u8) !void {
    debug_log.log("hooks.validateHostConfig: parse path={s} kind={s} bytes={d}", .{ path, @tagName(kind), content.len });
    switch (kind) {
        .json => |field_validations| {
            const parsed = json.parseFromSlice(json.Value, std.heap.page_allocator, content, .{}) catch {
                debug_log.log("hooks.validateHostConfig: malformed path={s} kind=json", .{path});
                reportHostConfigError(path, "contains malformed JSON");
                return error.MalformedHostConfig;
            };
            defer parsed.deinit();
            if (parsed.value != .object) {
                debug_log.log("hooks.validateHostConfig: invalid root path={s} kind=json", .{path});
                reportHostConfigError(path, "must contain a JSON object at the root");
                return error.InvalidHostConfig;
            }

            for (field_validations) |validation| {
                if (parsed.value.object.get(validation.name)) |value| {
                    const valid_type = switch (validation.expected) {
                        .object => value == .object,
                        .array => value == .array,
                    };
                    if (!valid_type) {
                        debug_log.log("hooks.validateHostConfig: invalid field path={s} field={s} expected={s}", .{ path, validation.name, @tagName(validation.expected) });
                        reportHostConfigFieldTypeError(path, validation.name, validation.expected);
                        return error.InvalidHostConfig;
                    }
                }
            }
        },
        .toml => {
            if (!tree_sitter_indexer.isSyntaxValid("toml", content)) {
                debug_log.log("hooks.validateHostConfig: malformed path={s} kind=toml", .{path});
                reportHostConfigError(path, "contains malformed TOML");
                return error.MalformedHostConfig;
            }
        },
    }
    debug_log.log("hooks.validateHostConfig: valid path={s} kind={s}", .{ path, @tagName(kind) });
}

fn readValidatedHostConfig(allocator: std.mem.Allocator, path: []const u8, kind: HostConfigKind) !?[]const u8 {
    const existing = try readCwdFile(allocator, path);
    errdefer if (existing) |content| allocator.free(content);
    if (existing) |content| try validateHostConfig(path, kind, content);
    debug_log.log("hooks.readValidatedHostConfig: decision path={s} state={s}", .{ path, if (existing == null) "missing" else "existing-valid" });
    return existing;
}

fn parseJsonObject(allocator: std.mem.Allocator, content: []const u8) !json.Parsed(json.Value) {
    const parsed = try json.parseFromSlice(json.Value, allocator, content, .{});
    std.debug.assert(parsed.value == .object);
    return parsed;
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

    const fields = [_]HostConfigField{.{ .name = key, .expected = .object }};
    const existing = try readValidatedHostConfig(allocator, path, .{ .json = &fields });
    defer if (existing) |e| allocator.free(e);

    var aw: Writer.Allocating = .init(allocator);
    defer aw.deinit();
    var s: Stringify = .{ .writer = &aw.writer, .options = .{ .whitespace = .indent_2 } };
    try s.beginObject();

    if (existing) |content| {
        if (parseJsonObject(allocator, content)) |parsed| {
            defer parsed.deinit();
            if (parsed.value == .object) {
                var iter = parsed.value.object.iterator();
                while (iter.next()) |entry| {
                    if (std.mem.eql(u8, entry.key_ptr.*, key)) continue;
                    try s.objectField(entry.key_ptr.*);
                    try s.write(entry.value_ptr.*);
                }
            }
        } else |err| return err;
    }

    try s.objectField(key);
    try s.beginObject();

    // Preserve existing entries under the key, except "cog"
    if (existing) |content| {
        if (parseJsonObject(allocator, content)) |parsed| {
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
        } else |err| return err;
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

    const fields = [_]HostConfigField{.{ .name = "mcpServers", .expected = .object }};
    const existing = try readValidatedHostConfig(allocator, path, .{ .json = &fields });
    defer if (existing) |e| allocator.free(e);

    var aw: Writer.Allocating = .init(allocator);
    defer aw.deinit();
    var s: Stringify = .{ .writer = &aw.writer, .options = .{ .whitespace = .indent_2 } };
    try s.beginObject();

    // Preserve existing top-level keys except mcpServers
    if (existing) |content| {
        if (parseJsonObject(allocator, content)) |parsed| {
            defer parsed.deinit();
            if (parsed.value == .object) {
                var iter = parsed.value.object.iterator();
                while (iter.next()) |entry| {
                    if (std.mem.eql(u8, entry.key_ptr.*, "mcpServers")) continue;
                    try s.objectField(entry.key_ptr.*);
                    try s.write(entry.value_ptr.*);
                }
            }
        } else |err| return err;
    }

    try s.objectField("mcpServers");
    try s.beginObject();

    // Preserve existing servers except cog
    if (existing) |content| {
        if (parseJsonObject(allocator, content)) |parsed| {
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
        } else |err| return err;
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

    const fields = [_]HostConfigField{.{ .name = "amp.mcpServers", .expected = .object }};
    const existing = try readValidatedHostConfig(allocator, path, .{ .json = &fields });
    defer if (existing) |e| allocator.free(e);

    var aw: Writer.Allocating = .init(allocator);
    defer aw.deinit();
    var s: Stringify = .{ .writer = &aw.writer, .options = .{ .whitespace = .indent_2 } };
    try s.beginObject();

    if (existing) |content| {
        if (parseJsonObject(allocator, content)) |parsed| {
            defer parsed.deinit();
            if (parsed.value == .object) {
                var iter = parsed.value.object.iterator();
                while (iter.next()) |entry| {
                    if (std.mem.eql(u8, entry.key_ptr.*, "amp.mcpServers")) continue;
                    try s.objectField(entry.key_ptr.*);
                    try s.write(entry.value_ptr.*);
                }
            }
        } else |err| return err;
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
    const fields = [_]HostConfigField{
        .{ .name = "mcp", .expected = .object },
        .{ .name = "plugin", .expected = .array },
    };
    const existing = try readValidatedHostConfig(allocator, path, .{ .json = &fields });
    defer if (existing) |e| allocator.free(e);

    var aw: Writer.Allocating = .init(allocator);
    defer aw.deinit();
    var s: Stringify = .{ .writer = &aw.writer, .options = .{ .whitespace = .indent_2 } };
    try s.beginObject();

    if (existing) |content| {
        if (parseJsonObject(allocator, content)) |parsed| {
            defer parsed.deinit();
            if (parsed.value == .object) {
                var iter = parsed.value.object.iterator();
                while (iter.next()) |entry| {
                    if (std.mem.eql(u8, entry.key_ptr.*, "mcp") or std.mem.eql(u8, entry.key_ptr.*, "plugin")) continue;
                    try s.objectField(entry.key_ptr.*);
                    try s.write(entry.value_ptr.*);
                }
            }
        } else |err| return err;
    }

    try s.objectField("mcp");
    try s.beginObject();

    if (existing) |content| {
        if (parseJsonObject(allocator, content)) |parsed| {
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
        } else |err| return err;
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
        if (parseJsonObject(allocator, content)) |parsed| {
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
        } else |err| return err;
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

    const existing = try readValidatedHostConfig(allocator, path, .toml);
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

    const fields = [_]HostConfigField{
        .{ .name = "permissions", .expected = .object },
        .{ .name = "enabledMcpjsonServers", .expected = .array },
    };
    const existing = try readValidatedHostConfig(allocator, path, .{ .json = &fields });
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
        if (parseJsonObject(allocator, content)) |parsed| {
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
        } else |err| return err;
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

    const fields = [_]HostConfigField{.{ .name = "hooks", .expected = .object }};
    const existing = try readValidatedHostConfig(allocator, path, .{ .json = &fields });
    defer if (existing) |e| allocator.free(e);

    var parsed_holder: ?json.Parsed(json.Value) = null;
    defer if (parsed_holder) |p| p.deinit();

    var existing_hooks: ?json.Value = null;
    if (existing) |content| {
        if (parseJsonObject(allocator, content)) |parsed| {
            parsed_holder = parsed;
            if (parsed.value == .object) {
                existing_hooks = parsed.value.object.get("hooks");
            }
        } else |err| return err;
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
                    try writeClaudeCogHookArray(&s, entry.value_ptr.*, "sh \"$CLAUDE_PROJECT_DIR\"/.claude/hooks/cog-posttooluse-failure.sh", "mcp__cog__.*", 10, null);
                } else if (std.mem.eql(u8, entry.key_ptr.*, "PreCompact")) {
                    wrote_precompact = true;
                    try s.objectField("PreCompact");
                    try writeClaudeCogHookArray(&s, entry.value_ptr.*, "sh \"$CLAUDE_PROJECT_DIR\"/.claude/hooks/cog-precompact.sh", null, 10, "Preserving Cog context...");
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
        try writeClaudeCogHookArray(&s, null, "sh \"$CLAUDE_PROJECT_DIR\"/.claude/hooks/cog-posttooluse-failure.sh", "mcp__cog__.*", 10, null);
    }

    if (!wrote_precompact) {
        try s.objectField("PreCompact");
        try writeClaudeCogHookArray(&s, null, "sh \"$CLAUDE_PROJECT_DIR\"/.claude/hooks/cog-precompact.sh", null, 10, "Preserving Cog context...");
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
    const fields = [_]HostConfigField{.{ .name = "mcpServers", .expected = .object }};
    const existing = (try readValidatedHostConfig(allocator, mcp_path, .{ .json = &fields })) orelse return;
    defer allocator.free(existing);

    const parsed = try parseJsonObject(allocator, existing);
    defer parsed.deinit();

    std.debug.assert(parsed.value == .object);

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

    const fields = [_]HostConfigField{.{ .name = "hooks", .expected = .object }};
    const existing = (try readValidatedHostConfig(allocator, mcp_path, .{ .json = &fields })) orelse return;
    defer allocator.free(existing);

    const parsed = try parseJsonObject(allocator, existing);
    defer parsed.deinit();
    std.debug.assert(parsed.value == .object);

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
    const fields = [_]HostConfigField{.{ .name = "amp.permissions", .expected = .array }};
    const existing = (try readValidatedHostConfig(allocator, mcp_path, .{ .json = &fields })) orelse return;
    defer allocator.free(existing);

    const parsed = try parseJsonObject(allocator, existing);
    defer parsed.deinit();

    std.debug.assert(parsed.value == .object);

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
    const existing = (try readValidatedHostConfig(allocator, mcp_path, .{ .json = &.{} })) orelse return;
    defer allocator.free(existing);

    const parsed = try parseJsonObject(allocator, existing);
    defer parsed.deinit();

    std.debug.assert(parsed.value == .object);

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

pub fn configureSpecialistFile(allocator: std.mem.Allocator, agent: agents_mod.Agent, kind: agents_mod.SpecialistKind) !void {
    debug_log.log("hooks.configureSpecialistFile: agent={s} kind={s}", .{ agent.id, @tagName(kind) });
    if (!agent.capabilities().specialists.supports(kind)) {
        debug_log.log("hooks.configureSpecialistFile: unsupported agent={s} kind={s}", .{ agent.id, @tagName(kind) });
        return;
    }

    switch (kind) {
        .code_query => try configureAgentFile(allocator, agent),
        .debug => try configureDebugAgentFile(allocator, agent),
        .memory => try configureMemAgentFile(allocator, agent),
        .validate => try configureValidateAgentFile(allocator, agent),
        .observe => try configureObserveAgentFile(allocator, agent),
    }
}

pub fn configureAgentFile(allocator: std.mem.Allocator, agent: agents_mod.Agent) !void {
    debug_log.log("hooks.configureAgentFile: agent={s}", .{agent.id});
    const caps = agent.capabilities();
    if (!caps.specialists.supports(.code_query)) return;
    const agent_path = agent.specialistPath(.code_query) orelse return;

    if (caps.subagent_support == .workflow_files) {
        const header = agent.agent_file_header orelse return;
        const instructions = try buildWorkflowSpecialistInstructions(allocator, specialistHostLabel(agent, agent_path), .code_query, build_options.agent_body);
        defer allocator.free(instructions);
        try writeMarkdownAgent(allocator, agent_path, header, instructions);
    } else if (caps.subagent_support == .dedicated_files and caps.specialists.code_query == .config) {
        const header = agent.agent_file_header orelse return;
        const instructions = try buildConfigScopedSpecialistInstructions(allocator, agent.display_name, .code_query, build_options.agent_body);
        defer allocator.free(instructions);
        try writeMarkdownAgent(allocator, agent_path, header, instructions);
    } else if (caps.subagent_support == .dedicated_files and caps.specialists.code_query == .prompt_only) {
        const header = agent.agent_file_header orelse return;
        const instructions = try buildPromptOnlySpecialistInstructions(allocator, specialistHostLabel(agent, agent_path), .code_query, build_options.agent_body);
        defer allocator.free(instructions);
        try writeMarkdownAgent(allocator, agent_path, header, instructions);
    } else if (agent.agent_file_header) |header| {
        try writeMarkdownAgent(allocator, agent_path, header, build_options.agent_body);
    } else if (std.mem.eql(u8, agent.id, "roo")) {
        try writeRooAgent(allocator, agent_path, "cog-code-query", "Cog Code Query", roo_code_query_role);
    }
}

/// Roo stores specialists as shared-config custom modes; its code-query role
/// must quote the same raw-text fallback policy as every other host surface.
const roo_code_query_role = "You are a code index exploration agent. Use cog_code_explore for symbol discovery and file structure, then use cog_code_query refs only when you need call sites. Read source only after the index tells you where to look. Do not use filename guessing or raw file search for code exploration. " ++ agents_mod.specialist_raw_text_fallback_policy ++ " Return concise summaries with file paths and line numbers.";

pub fn configureDebugAgentFile(allocator: std.mem.Allocator, agent: agents_mod.Agent) !void {
    debug_log.log("hooks.configureDebugAgentFile: agent={s}", .{agent.id});
    const caps = agent.capabilities();
    if (!caps.specialists.supports(.debug)) return;
    const debug_path = agent.specialistPath(.debug) orelse return;

    if (caps.subagent_support == .workflow_files) {
        const header = agent.debug_file_header orelse return;
        const instructions = try buildWorkflowSpecialistInstructions(allocator, specialistHostLabel(agent, debug_path), .debug, build_options.debug_agent_body);
        defer allocator.free(instructions);
        try writeMarkdownAgent(allocator, debug_path, header, instructions);
    } else if (caps.subagent_support == .dedicated_files and caps.specialists.debug == .config) {
        const header = agent.debug_file_header orelse return;
        const instructions = try buildConfigScopedSpecialistInstructions(allocator, agent.display_name, .debug, build_options.debug_agent_body);
        defer allocator.free(instructions);
        try writeMarkdownAgent(allocator, debug_path, header, instructions);
    } else if (caps.subagent_support == .dedicated_files and caps.specialists.debug == .prompt_only) {
        const header = agent.debug_file_header orelse return;
        const instructions = try buildPromptOnlySpecialistInstructions(allocator, specialistHostLabel(agent, debug_path), .debug, build_options.debug_agent_body);
        defer allocator.free(instructions);
        try writeMarkdownAgent(allocator, debug_path, header, instructions);
    } else if (agent.debug_file_header) |header| {
        try writeMarkdownAgent(allocator, debug_path, header, build_options.debug_agent_body);
    } else if (std.mem.eql(u8, agent.id, "roo")) {
        try writeRooAgent(allocator, debug_path, "cog-debug", "Cog Debug", "You are a debug subagent. Use cog_debug tools to answer questions about runtime state. Launch a debug session, set breakpoints, run to them, inspect values, then stop. Return only the observed values. Do not suggest fixes.");
    }
}

pub fn configureMemAgentFile(allocator: std.mem.Allocator, agent: agents_mod.Agent) !void {
    debug_log.log("hooks.configureMemAgentFile: agent={s}", .{agent.id});
    const caps = agent.capabilities();
    if (!caps.specialists.supports(.memory)) return;
    const mem_path = agent.specialistPath(.memory) orelse return;

    if (caps.subagent_support == .workflow_files) {
        const header = agent.mem_file_header orelse return;
        const instructions = try buildWorkflowSpecialistInstructions(allocator, specialistHostLabel(agent, mem_path), .memory, build_options.mem_agent_body);
        defer allocator.free(instructions);
        try writeMarkdownAgent(allocator, mem_path, header, instructions);
    } else if (caps.subagent_support == .dedicated_files and caps.specialists.memory == .config) {
        const header = agent.mem_file_header orelse return;
        const instructions = try buildConfigScopedSpecialistInstructions(allocator, agent.display_name, .memory, build_options.mem_agent_body);
        defer allocator.free(instructions);
        try writeMarkdownAgent(allocator, mem_path, header, instructions);
    } else if (caps.subagent_support == .dedicated_files and caps.specialists.memory == .prompt_only) {
        const header = agent.mem_file_header orelse return;
        const instructions = try buildPromptOnlySpecialistInstructions(allocator, specialistHostLabel(agent, mem_path), .memory, build_options.mem_agent_body);
        defer allocator.free(instructions);
        try writeMarkdownAgent(allocator, mem_path, header, instructions);
    } else if (agent.mem_file_header) |header| {
        try writeMarkdownAgent(allocator, mem_path, header, build_options.mem_agent_body);
    } else if (std.mem.eql(u8, agent.id, "roo")) {
        try writeRooAgent(allocator, mem_path, "cog-mem", "Cog Memory", "You are a memory sub-agent for Cog's persistent associative knowledge graph. Start with cog_mem_recall, decide whether memory is sufficient, and only then escalate to cog_code_explore or cog_code_query if memory is insufficient. If exploration teaches something durable, write it back with cog_mem_learn. Before finishing, review short-term memory with cog_mem_list_short_term and validate it with cog_mem_reinforce, cog_mem_verify, or cog_mem_flush. Return concise summaries with engram IDs.");
    }
}

pub fn configureValidateAgentFile(allocator: std.mem.Allocator, agent: agents_mod.Agent) !void {
    debug_log.log("hooks.configureValidateAgentFile: agent={s}", .{agent.id});
    const caps = agent.capabilities();
    if (!caps.specialists.supports(.validate)) return;
    const validate_path = agent.specialistPath(.validate) orelse return;

    if (caps.subagent_support == .workflow_files) {
        const header = agent.validate_file_header orelse return;
        const instructions = try buildWorkflowSpecialistInstructions(allocator, specialistHostLabel(agent, validate_path), .validate, build_options.validate_agent_body);
        defer allocator.free(instructions);
        try writeMarkdownAgent(allocator, validate_path, header, instructions);
    } else if (caps.subagent_support == .dedicated_files and caps.specialists.validate == .config) {
        const header = agent.validate_file_header orelse return;
        const instructions = try buildConfigScopedSpecialistInstructions(allocator, agent.display_name, .validate, build_options.validate_agent_body);
        defer allocator.free(instructions);
        try writeMarkdownAgent(allocator, validate_path, header, instructions);
    } else if (caps.subagent_support == .dedicated_files and caps.specialists.validate == .prompt_only) {
        const header = agent.validate_file_header orelse return;
        const instructions = try buildPromptOnlySpecialistInstructions(allocator, specialistHostLabel(agent, validate_path), .validate, build_options.validate_agent_body);
        defer allocator.free(instructions);
        try writeMarkdownAgent(allocator, validate_path, header, instructions);
    } else if (agent.validate_file_header) |header| {
        try writeMarkdownAgent(allocator, validate_path, header, build_options.validate_agent_body);
    } else if (std.mem.eql(u8, agent.id, "roo")) {
        try writeRooAgent(allocator, validate_path, "cog-mem-validate", "Cog Memory Validate", "You are a post-task memory validation sub-agent. Store durable knowledge from the primary agent's exploration with cog_mem_learn, then consolidate short-term memories with cog_mem_list_short_term and cog_mem_reinforce or cog_mem_flush. Return concise summaries with engram IDs.");
    }
}

const CodexSpecialistKind = enum {
    code_query,
    debug,
    memory,
    validate,
    observe,
};

/// Shared .agents/skills files serve several hosts at once, so their
/// instructions must not name any single host.
fn specialistHostLabel(agent: agents_mod.Agent, path: []const u8) []const u8 {
    if (std.mem.indexOf(u8, path, "skills/") != null) return "this coding agent";
    return agent.display_name;
}

fn buildWorkflowSpecialistInstructions(allocator: std.mem.Allocator, agent_name: []const u8, kind: CodexSpecialistKind, body: []const u8) ![]const u8 {
    const surface = if (std.mem.eql(u8, agent_name, "this coding agent")) "shared skill files" else "workflow files";
    return switch (kind) {
        .code_query => try std.fmt.allocPrint(allocator,
            \\Workflow guidance:
            \\- This host uses {s} rather than hard-scoped subagents.
            \\- Treat this workflow as a read-oriented research specialist inside {s}.
            \\- Start with Cog code intelligence. {s}
            \\- Do not use shell search commands like grep, rg, find, or git grep when Cog code intelligence can answer the question.
            \\- Return concrete paths, symbols, and next actions for the main agent.
            \\
            \\{s}
        , .{ surface, agent_name, agents_mod.specialist_raw_text_fallback_policy, body }),
        .debug => try std.fmt.allocPrint(allocator,
            \\Workflow guidance:
            \\- This host uses {s} rather than hard-scoped subagents.
            \\- Prefer Cog debugger evidence over speculative reasoning.
            \\- Use shell commands only to reproduce the reported issue or run the requested test.
            \\- Return observed runtime facts, not broad rewrite plans.
            \\
            \\{s}
        , .{ surface, body }),
        .memory => try std.fmt.allocPrint(allocator,
            \\Workflow guidance:
            \\- This host uses {s} rather than hard-scoped subagents.
            \\- Use this workflow as the retrieval-first triage path.
            \\- Start with Cog memory recall, decide whether memory is sufficient, and only then escalate to Cog code exploration inside the workflow if memory is insufficient.
            \\- Consolidate durable findings before finishing.
            \\- Keep responses concise, include engram IDs when memory changes, and capture rationale or invariants when they are part of the durable memory.
            \\
            \\{s}
        , .{ surface, body }),
        .validate => try std.fmt.allocPrint(allocator,
            \\Workflow guidance:
            \\- This host uses {s} rather than hard-scoped subagents.
            \\- This workflow handles the full learn-and-consolidate lifecycle in one call.
            \\- Return concise summaries with engram IDs.
            \\
            \\{s}
        , .{ surface, body }),
        .observe => try std.fmt.allocPrint(allocator,
            \\Workflow guidance:
            \\- This host uses {s} rather than hard-scoped subagents.
            \\- Use this workflow for system-level observability (syscalls, GPU, network, cost).
            \\- Start observation sessions, analyze causal chains, and query raw events.
            \\- Use shell commands only to reproduce the target workload.
            \\
            \\{s}
        , .{ surface, body }),
    };
}

fn buildPromptOnlySpecialistInstructions(allocator: std.mem.Allocator, agent_name: []const u8, kind: CodexSpecialistKind, body: []const u8) ![]const u8 {
    return switch (kind) {
        .code_query => try std.fmt.allocPrint(allocator,
            \\Host guidance:
            \\- {s} cannot hard-deny tools per specialist, so treat this as a read-oriented code research role.
            \\- Use Cog code intelligence before any raw file search.
            \\- {s}
            \\- Do not use shell search commands like grep, rg, find, or git grep from this specialist.
            \\- Do not edit files or run shell commands from this specialist.
            \\
            \\{s}
        , .{ agent_name, agents_mod.specialist_raw_text_fallback_policy, body }),
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
        .observe => try std.fmt.allocPrint(allocator,
            \\Host guidance:
            \\- {s} cannot hard-deny tools per specialist, so keep this role focused on system observability.
            \\- Use observe tools for syscall, GPU, network, and cost investigation.
            \\- Use shell commands only to reproduce the target workload.
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
            \\- {s}
            \\- Do not use shell search commands like grep, rg, find, or git grep for code exploration.
            \\
            \\{s}
        , .{ agent_name, agents_mod.specialist_raw_text_fallback_policy, body }),
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
        .observe => try std.fmt.allocPrint(allocator,
            \\Host guidance:
            \\- {s} provides config-level scoping for this observability specialist.
            \\- Use observe tools for syscall, GPU, network, and cost investigation.
            \\- Use shell commands only to reproduce the target workload.
            \\
            \\{s}
        , .{ agent_name, body }),
    };
}

pub fn configureObserveAgentFile(allocator: std.mem.Allocator, agent: agents_mod.Agent) !void {
    debug_log.log("hooks.configureObserveAgentFile: agent={s}", .{agent.id});
    const caps = agent.capabilities();
    if (!caps.specialists.supports(.observe)) return;
    const observe_path = agent.specialistPath(.observe) orelse return;

    if (caps.subagent_support == .workflow_files) {
        const header = agent.observe_file_header orelse return;
        const instructions = try buildWorkflowSpecialistInstructions(allocator, specialistHostLabel(agent, observe_path), .observe, build_options.observe_agent_body);
        defer allocator.free(instructions);
        try writeMarkdownAgent(allocator, observe_path, header, instructions);
    } else if (caps.subagent_support == .dedicated_files and caps.specialists.observe == .config) {
        const header = agent.observe_file_header orelse return;
        const instructions = try buildConfigScopedSpecialistInstructions(allocator, agent.display_name, .observe, build_options.observe_agent_body);
        defer allocator.free(instructions);
        try writeMarkdownAgent(allocator, observe_path, header, instructions);
    } else if (caps.subagent_support == .dedicated_files and caps.specialists.observe == .prompt_only) {
        const header = agent.observe_file_header orelse return;
        const instructions = try buildPromptOnlySpecialistInstructions(allocator, specialistHostLabel(agent, observe_path), .observe, build_options.observe_agent_body);
        defer allocator.free(instructions);
        try writeMarkdownAgent(allocator, observe_path, header, instructions);
    } else if (agent.observe_file_header) |header| {
        try writeMarkdownAgent(allocator, observe_path, header, build_options.observe_agent_body);
    } else if (std.mem.eql(u8, agent.id, "roo")) {
        try writeRooAgent(allocator, observe_path, "cog-observe", "Cog Observe", "You are a system observability sub-agent. Use cog_observe tools to investigate system-level behavior — syscalls, GPU operations, network flows, and costs. Start sessions, analyze causal chains, and query raw events. Return concise reports with observed behavior, causal chains, and timestamps.");
    }
}

pub fn buildMarkdownAgentContent(allocator: std.mem.Allocator, header: []const u8, body: []const u8) ![]const u8 {
    const joined = try std.fmt.allocPrint(allocator, "{s}\n{s}", .{ header, body });
    if (std.mem.indexOf(u8, joined, agents_mod.cog_version_token) == null) return joined;
    defer allocator.free(joined);
    // Skill frontmatter records the generating binary so doctor can report
    // asset drift against the running version.
    return try std.mem.replaceOwned(u8, allocator, joined, agents_mod.cog_version_token, build_options.version);
}

test "buildMarkdownAgentContent stamps the generating version" {
    const allocator = std.testing.allocator;
    const stamped = try buildMarkdownAgentContent(allocator, "---\ncog-version: \"{{COG_VERSION}}\"\n---\n", "body\n");
    defer allocator.free(stamped);
    try std.testing.expect(std.mem.indexOf(u8, stamped, "{{COG_VERSION}}") == null);
    const expected = try std.fmt.allocPrint(allocator, "cog-version: \"{s}\"", .{build_options.version});
    defer allocator.free(expected);
    try std.testing.expect(std.mem.indexOf(u8, stamped, expected) != null);
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

/// Install the always-on workflow skills the kernel prompt points at.
/// Bodies carry the detailed procedures that used to live in the prompt;
/// hosts sharing a skills directory simply overwrite identical content.
pub fn configureWorkflowSkills(allocator: std.mem.Allocator, agent: agents_mod.Agent, memory_enabled: bool) !void {
    debug_log.log("hooks.configureWorkflowSkills: agent={s} memory={any}", .{ agent.id, memory_enabled });
    for (agents_mod.workflow_skills) |skill| {
        if (skill.requires_memory and !memory_enabled) continue;
        const path = try std.fmt.allocPrint(allocator, "{s}/{s}/SKILL.md", .{ agent.skills_dir, skill.name });
        defer allocator.free(path);
        const body = if (std.mem.eql(u8, skill.name, "cog-explore"))
            build_options.explore_skill_body
        else
            build_options.remember_skill_body;
        try writeMarkdownAgent(allocator, path, skill.header, body);
    }
}

fn writeMarkdownAgent(allocator: std.mem.Allocator, path: []const u8, header: []const u8, body: []const u8) !void {
    debug_log.log("hooks.writeMarkdownAgent: path={s}", .{path});
    if (std.fs.path.dirname(path)) |parent| {
        try ensureDir(parent);
    }

    const content = try buildMarkdownAgentContent(allocator, header, body);
    defer allocator.free(content);
    try writeCwdFile(path, content);
}

fn findTomlSectionEnd(content: []const u8, section_start: usize) usize {
    var line_start = std.mem.indexOfScalarPos(u8, content, section_start, '\n') orelse return content.len;
    line_start += 1;

    while (line_start < content.len) {
        const line_end = std.mem.indexOfScalarPos(u8, content, line_start, '\n') orelse content.len;
        const trimmed = std.mem.trim(u8, content[line_start..line_end], &std.ascii.whitespace);
        if (trimmed.len >= 2 and trimmed[0] == '[' and trimmed[trimmed.len - 1] == ']') return line_start;
        line_start = if (line_end < content.len) line_end + 1 else content.len;
    }

    return content.len;
}

fn writeRooAgent(allocator: std.mem.Allocator, path: []const u8, slug: []const u8, name: []const u8, role_definition: []const u8) !void {
    debug_log.log("hooks.writeRooAgent: path={s} slug={s}", .{ path, slug });
    const description = if (std.mem.eql(u8, slug, "cog-code-query"))
        "Explore code structure using the Cog SCIP index"
    else if (std.mem.eql(u8, slug, "cog-debug"))
        "Debug subagent that investigates runtime behavior via cog debugger, code, and memory tools"
    else if (std.mem.eql(u8, slug, "cog-mem"))
        "Memory sub-agent for recall, consolidation, and maintenance"
    else if (std.mem.eql(u8, slug, "cog-mem-validate"))
        "Post-task memory validation — learns durable knowledge and consolidates short-term memories"
    else if (std.mem.eql(u8, slug, "cog-observe"))
        "System observability sub-agent for syscall, GPU, network, and cost investigation"
    else
        name;
    const when_to_use = if (std.mem.eql(u8, slug, "cog-code-query"))
        "Use when you need repository exploration, symbol lookup, or architecture summaries without relying on raw file search."
    else if (std.mem.eql(u8, slug, "cog-debug"))
        "Use for runtime bugs, crashes, or unclear state when debugger evidence is needed instead of static reasoning."
    else if (std.mem.eql(u8, slug, "cog-mem"))
        "Use before broad unfamiliar exploration for recall, and after work to consolidate or clean up memory."
    else if (std.mem.eql(u8, slug, "cog-mem-validate"))
        "Use after work that created durable knowledge or short-term memories that need validation."
    else if (std.mem.eql(u8, slug, "cog-observe"))
        "Use for system-level performance investigations involving syscalls, GPU work, network flows, or resource costs."
    else
        name;
    const custom_instructions = if (std.mem.eql(u8, slug, "cog-code-query"))
        build_options.agent_body
    else if (std.mem.eql(u8, slug, "cog-debug"))
        build_options.debug_agent_body
    else if (std.mem.eql(u8, slug, "cog-mem"))
        build_options.mem_agent_body
    else if (std.mem.eql(u8, slug, "cog-mem-validate"))
        build_options.validate_agent_body
    else if (std.mem.eql(u8, slug, "cog-observe"))
        build_options.observe_agent_body
    else
        role_definition;
    const code_query_groups = [_][]const u8{ "read", "mcp" };
    const debug_groups = [_][]const u8{ "read", "command", "mcp" };
    const mem_groups = [_][]const u8{"mcp"};
    const observe_groups = [_][]const u8{ "read", "command", "mcp" };
    const empty_groups = [_][]const u8{};
    const groups: []const []const u8 = if (std.mem.eql(u8, slug, "cog-code-query"))
        &code_query_groups
    else if (std.mem.eql(u8, slug, "cog-debug"))
        &debug_groups
    else if (std.mem.eql(u8, slug, "cog-mem") or std.mem.eql(u8, slug, "cog-mem-validate"))
        &mem_groups
    else if (std.mem.eql(u8, slug, "cog-observe"))
        &observe_groups
    else
        &empty_groups;

    const fields = [_]HostConfigField{.{ .name = "customModes", .expected = .array }};
    const existing = try readValidatedHostConfig(allocator, path, .{ .json = &fields });
    defer if (existing) |e| allocator.free(e);

    var aw: Writer.Allocating = .init(allocator);
    defer aw.deinit();
    var s: Stringify = .{ .writer = &aw.writer, .options = .{ .whitespace = .indent_2 } };

    try s.beginObject();
    try s.objectField("customModes");
    try s.beginArray();

    var found_existing = false;

    if (existing) |content| {
        if (parseJsonObject(allocator, content)) |parsed| {
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
        } else |err| return err;
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

fn writeHostConfigFixture(path: []const u8, content: []const u8, mode: std.fs.File.Mode) !void {
    if (std.fs.path.dirname(path)) |parent| try std.fs.cwd().makePath(parent);
    const file = try std.fs.cwd().createFile(path, .{ .mode = mode });
    defer file.close();
    try file.writeAll(content);
}

fn expectHostConfigUnchanged(allocator: std.mem.Allocator, path: []const u8, expected: []const u8, mode: std.fs.File.Mode) !void {
    const file = try std.fs.cwd().openFile(path, .{});
    defer file.close();
    const content = try file.readToEndAlloc(allocator, expected.len + 1);
    defer allocator.free(content);
    try std.testing.expectEqualStrings(expected, content);
    if (@import("builtin").os.tag != .windows) {
        const stat = try std.fs.cwd().statFile(path);
        try std.testing.expectEqual(mode, stat.mode & 0o777);
    }
}

fn resetMalformedHostConfig(path: []const u8, content: []const u8) !void {
    std.fs.cwd().deleteFile(path) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };
    try writeHostConfigFixture(path, content, 0o600);
}

test "configureMcp rejects malformed existing configs for every repo-local host" {
    try withTempCwd(struct {
        fn run(allocator: std.mem.Allocator) !void {
            const repo_local_agent_indices = [_]usize{ 0, 1, 2, 4, 5, 6, 8, 9, 10 };
            for (repo_local_agent_indices) |index| {
                const agent = agents_mod.agents[index];
                const path = agent.mcp_path orelse return error.TestUnexpectedResult;
                const malformed = if (agent.mcp_format == .toml) "[broken" else "{broken";
                try writeHostConfigFixture(path, malformed, 0o600);

                try std.testing.expectError(error.MalformedHostConfig, configureMcp(allocator, agent));
                try expectHostConfigUnchanged(allocator, path, malformed, 0o600);
            }
        }
    }.run);
}

test "host permission and runtime mergers reject malformed existing JSON" {
    try withTempCwd(struct {
        fn run(allocator: std.mem.Allocator) !void {
            const malformed = "{broken";
            const permission_agent_indices = [_]usize{ 0, 1, 6, 9 };
            for (permission_agent_indices) |index| {
                const agent = agents_mod.agents[index];
                const path = if (std.mem.eql(u8, agent.id, "claude_code")) ".claude/settings.json" else agent.mcp_path.?;
                try resetMalformedHostConfig(path, malformed);

                try std.testing.expectError(error.MalformedHostConfig, configureToolPermissions(allocator, agent));
                try expectHostConfigUnchanged(allocator, path, malformed, 0o600);
            }

            const runtime_agent_indices = [_]usize{ 0, 1 };
            for (runtime_agent_indices) |index| {
                const agent = agents_mod.agents[index];
                const path = if (std.mem.eql(u8, agent.id, "claude_code")) ".claude/settings.json" else agent.mcp_path.?;
                try resetMalformedHostConfig(path, malformed);

                try std.testing.expectError(error.MalformedHostConfig, configureRuntimePolicy(allocator, agent));
                try expectHostConfigUnchanged(allocator, path, malformed, 0o600);
            }
        }
    }.run);
}

test "shared host config specialist mergers reject malformed existing configs" {
    try withTempCwd(struct {
        fn run(allocator: std.mem.Allocator) !void {
            const roo_path = ".roomodes";
            const slugs = [_][]const u8{ "cog-code-query", "cog-debug", "cog-mem", "cog-mem-validate", "cog-observe" };

            for (slugs) |slug| {
                try resetMalformedHostConfig(roo_path, "{broken");
                try std.testing.expectError(error.MalformedHostConfig, writeRooAgent(allocator, roo_path, slug, "Cog Specialist", "instructions"));
                try expectHostConfigUnchanged(allocator, roo_path, "{broken", 0o600);
            }
        }
    }.run);
}

test "host config readers distinguish missing unreadable and oversized files" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;

    try withTempCwd(struct {
        fn run(allocator: std.mem.Allocator) !void {
            try writeJsonMcp(allocator, "missing.json", "mcpServers");
            try std.testing.expect(fileExistsInCwd("missing.json"));

            const unreadable_content = "{\"keep\":true}";
            const unreadable = try std.fs.cwd().createFile("unreadable.json", .{ .read = true, .mode = 0o600 });
            defer unreadable.close();
            try unreadable.writeAll(unreadable_content);
            try unreadable.chmod(0);
            defer unreadable.chmod(0o600) catch {};

            try std.testing.expectError(error.HostConfigUnreadable, writeJsonMcp(allocator, "unreadable.json", "mcpServers"));
            try unreadable.seekTo(0);
            const retained_unreadable = try unreadable.readToEndAlloc(allocator, unreadable_content.len + 1);
            defer allocator.free(retained_unreadable);
            try std.testing.expectEqualStrings(unreadable_content, retained_unreadable);

            const oversized = try allocator.alloc(u8, 1048577);
            defer allocator.free(oversized);
            @memset(oversized, ' ');
            oversized[0] = '{';
            oversized[oversized.len - 1] = '}';
            try writeHostConfigFixture("oversized.json", oversized, 0o640);

            try std.testing.expectError(error.HostConfigTooLarge, writeJsonMcp(allocator, "oversized.json", "mcpServers"));
            try expectHostConfigUnchanged(allocator, "oversized.json", oversized, 0o640);
        }
    }.run);
}

test "host JSON config mergers reject non-object roots" {
    try withTempCwd(struct {
        fn run(allocator: std.mem.Allocator) !void {
            const invalid_config = "[]";
            try writeHostConfigFixture("config.json", invalid_config, 0o600);

            try std.testing.expectError(error.InvalidHostConfig, writeJsonMcp(allocator, "config.json", "mcpServers"));
            try expectHostConfigUnchanged(allocator, "config.json", invalid_config, 0o600);
        }
    }.run);
}

test "host JSON mergers reject malformed owned fields without overwriting" {
    try withTempCwd(struct {
        fn run(allocator: std.mem.Allocator) !void {
            const mcp_invalid = "{\"mcpServers\":[]}";
            try writeHostConfigFixture("mcp.json", mcp_invalid, 0o640);
            try std.testing.expectError(error.InvalidHostConfig, writeJsonMcp(allocator, "mcp.json", "mcpServers"));
            try expectHostConfigUnchanged(allocator, "mcp.json", mcp_invalid, 0o640);

            const opencode_invalid = "{\"mcp\":[],\"plugin\":{}}";
            try writeHostConfigFixture("opencode.json", opencode_invalid, 0o640);
            try std.testing.expectError(error.InvalidHostConfig, writeJsonOpenCode(allocator, "opencode.json"));
            try expectHostConfigUnchanged(allocator, "opencode.json", opencode_invalid, 0o640);

            const roo_invalid = "{\"customModes\":{}}";
            try writeHostConfigFixture(".roomodes", roo_invalid, 0o640);
            try std.testing.expectError(error.InvalidHostConfig, writeRooAgent(allocator, ".roomodes", "cog-code-query", "Cog Code Query", "instructions"));
            try expectHostConfigUnchanged(allocator, ".roomodes", roo_invalid, 0o640);
        }
    }.run);
}

test "global-only hosts do not read or write repository config" {
    try withTempCwd(struct {
        fn run(allocator: std.mem.Allocator) !void {
            const windsurf = agents_mod.agents[3];
            const goose = agents_mod.agents[7];
            try std.testing.expectEqual(agents_mod.McpFormat.global_only, windsurf.mcp_format);
            try std.testing.expectEqual(agents_mod.McpFormat.global_only, goose.mcp_format);

            try configureMcp(allocator, windsurf);
            try configureMcp(allocator, goose);

            try std.testing.expect(!fileExistsInCwd(".codeium/windsurf/mcp_config.json"));
            try std.testing.expect(!fileExistsInCwd(".config/goose/config.yaml"));
        }
    }.run);
}

test "writeJsonMcp atomically preserves mode and existing content" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;

    try withTempCwd(struct {
        fn run(allocator: std.mem.Allocator) !void {
            const original_content =
                \\{"version":1,"mcpServers":{"foo":{"command":"foo"}}}
            ;
            const original = try std.fs.cwd().createFile(".mcp.json", .{ .read = true, .mode = 0o600 });
            defer original.close();
            try original.writeAll(original_content);
            try original.seekTo(0);

            try writeJsonMcp(allocator, ".mcp.json", "mcpServers");

            const updated = (try readCwdFile(allocator, ".mcp.json")) orelse return error.TestUnexpectedResult;
            defer allocator.free(updated);
            const parsed = try json.parseFromSlice(json.Value, allocator, updated, .{});
            defer parsed.deinit();
            const servers = parsed.value.object.get("mcpServers") orelse return error.TestUnexpectedResult;
            try std.testing.expect(servers.object.get("foo") != null);
            try std.testing.expect(servers.object.get("cog") != null);

            const stat = try std.fs.cwd().statFile(".mcp.json");
            try std.testing.expectEqual(@as(std.fs.File.Mode, 0o600), stat.mode & 0o777);

            const retained_content = try original.readToEndAlloc(allocator, 1048576);
            defer allocator.free(retained_content);
            try std.testing.expectEqualStrings(original_content, retained_content);
        }
    }.run);
}

test "writeJsonMcp preserves existing non-cog entries" {
    try withTempCwd(struct {
        fn run(allocator: std.mem.Allocator) !void {
            const existing =
                \\{"version":1,"mcpServers":{"foo":{"command":"foo"},"cog":{"command":"old","args":["legacy"]}}}
            ;
            try writeCwdFile(".mcp.json", existing);

            try writeJsonMcp(allocator, ".mcp.json", "mcpServers");

            const updated = (try readCwdFile(allocator, ".mcp.json")) orelse return error.TestUnexpectedResult;
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

            const updated = (try readCwdFile(allocator, "opencode.json")) orelse return error.TestUnexpectedResult;
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

            const updated = (try readCwdFile(allocator, "opencode.json")) orelse return error.TestUnexpectedResult;
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

            const content = (try readCwdFile(allocator, "opencode.json")) orelse return error.TestUnexpectedResult;
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

            const content = (try readCwdFile(allocator, "opencode.json")) orelse return error.TestUnexpectedResult;
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

            const content = (try readCwdFile(allocator, "opencode.json")) orelse return error.TestUnexpectedResult;
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

            const content = (try readCwdFile(allocator, "opencode.json")) orelse return error.TestUnexpectedResult;
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

            const content = (try readCwdFile(std.testing.allocator, ".opencode/plugins/cog-override.ts")) orelse return error.TestUnexpectedResult;
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

            const content = (try readCwdFile(std.testing.allocator, ".opencode/plugins/cog-debug.ts")) orelse return error.TestUnexpectedResult;
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

            const content = (try readCwdFile(std.testing.allocator, ".opencode/plugins/cog-memory.ts")) orelse return error.TestUnexpectedResult;
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

            const content = (try readCwdFile(std.testing.allocator, ".claude/hooks/cog-pretooluse.sh")) orelse return error.TestUnexpectedResult;
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

            const content = (try readCwdFile(std.testing.allocator, ".gemini/hooks/cog-before-tool.sh")) orelse return error.TestUnexpectedResult;
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

            const content = (try readCwdFile(std.testing.allocator, ".amp/plugins/cog.ts")) orelse return error.TestUnexpectedResult;
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

/// Order-independent digest of every file below `dir`, so tests can detect
/// whether an installer changed any host state at all.
fn scratchStateDigest(allocator: std.mem.Allocator, dir: std.fs.Dir) !u64 {
    var digest: u64 = 0;
    var walker = try dir.walk(allocator);
    defer walker.deinit();
    while (try walker.next()) |entry| {
        if (entry.kind != .file) continue;
        const content = try entry.dir.readFileAlloc(allocator, entry.basename, max_host_config_bytes);
        defer allocator.free(content);
        var h = std.hash.Wyhash.init(0);
        h.update(entry.path);
        h.update(&[_]u8{0});
        h.update(content);
        digest ^= h.final();
    }
    return digest;
}

test "tool permission installers derive from registry capabilities" {
    try withTempCwd(struct {
        fn run(allocator: std.mem.Allocator) !void {
            var base = try std.fs.cwd().openDir(".", .{});
            defer base.close();

            for (agents_mod.agents) |agent| {
                var scratch = try base.makeOpenPath(agent.id, .{ .iterate = true });
                defer scratch.close();
                try scratch.setAsCwd();
                defer base.setAsCwd() catch {};

                // Init installs the MCP config before tool permissions; mirror
                // that order so permission writers that merge into the MCP
                // config observe the same starting state as a real init run.
                try configureMcp(allocator, agent);
                const before = try scratchStateDigest(allocator, scratch);
                try configureToolPermissions(allocator, agent);
                const after = try scratchStateDigest(allocator, scratch);

                try std.testing.expectEqual(agent.capabilities().auto_tool_permissions, before != after);
            }
        }
    }.run);
}

test "runtime policy installers derive from registry capabilities" {
    for (agents_mod.agents) |agent| {
        const caps = agent.capabilities();
        const expects_assets = caps.runtime_policy_plugins or caps.memory_write_enrichment == .config;
        try std.testing.expectEqual(expects_assets, runtimePolicyAssets(agent).len != 0);
    }

    try withTempCwd(struct {
        fn run(allocator: std.mem.Allocator) !void {
            var base = try std.fs.cwd().openDir(".", .{});
            defer base.close();

            for (agents_mod.agents) |agent| {
                var scratch = try base.makeOpenPath(agent.id, .{ .iterate = true });
                defer scratch.close();
                try scratch.setAsCwd();
                defer base.setAsCwd() catch {};

                try configureRuntimePolicy(allocator, agent);

                var it = scratch.iterate();
                const wrote_config = (try it.next()) != null;
                try std.testing.expectEqual(
                    agent.capabilities().memory_write_enrichment == .config,
                    wrote_config,
                );
            }
        }
    }.run);
}

test "mcp installers derive from registry capabilities" {
    try withTempCwd(struct {
        fn run(allocator: std.mem.Allocator) !void {
            var base = try std.fs.cwd().openDir(".", .{});
            defer base.close();

            for (agents_mod.agents) |agent| {
                var scratch = try base.makeOpenPath(agent.id, .{ .iterate = true });
                defer scratch.close();
                try scratch.setAsCwd();
                defer base.setAsCwd() catch {};

                try configureMcp(allocator, agent);

                if (agent.capabilities().repo_local_mcp) {
                    try std.testing.expect(fileExistsInCwd(agent.mcp_path.?));
                } else {
                    var it = scratch.iterate();
                    try std.testing.expect((try it.next()) == null);
                }
            }
        }
    }.run);
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

            const updated = (try readCwdFile(allocator, "config.toml")) orelse return error.TestUnexpectedResult;
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

            const content = (try readCwdFile(allocator, ".claude/settings.json")) orelse return error.TestUnexpectedResult;
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

            const content = (try readCwdFile(allocator, ".claude/settings.json")) orelse return error.TestUnexpectedResult;
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

            const content = (try readCwdFile(allocator, ".claude/settings.json")) orelse return error.TestUnexpectedResult;
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

            const content = (try readCwdFile(allocator, ".claude/settings.json")) orelse return error.TestUnexpectedResult;
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

            const content = (try readCwdFile(allocator, ".claude/settings.json")) orelse return error.TestUnexpectedResult;
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

            const content = (try readCwdFile(allocator, ".claude/settings.json")) orelse return error.TestUnexpectedResult;
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

            const content = (try readCwdFile(allocator, ".claude/settings.json")) orelse return error.TestUnexpectedResult;
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

            const content = (try readCwdFile(std.testing.allocator, ".claude/hooks/cog-stop-memory.sh")) orelse return error.TestUnexpectedResult;
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

            const content = (try readCwdFile(allocator, ".gemini/settings.json")) orelse return error.TestUnexpectedResult;
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

            const content = (try readCwdFile(allocator, ".gemini/settings.json")) orelse return error.TestUnexpectedResult;
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

            const content = (try readCwdFile(allocator, ".gemini/settings.json")) orelse return error.TestUnexpectedResult;
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

            const content = (try readCwdFile(allocator, ".amp/settings.json")) orelse return error.TestUnexpectedResult;
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

            const content = (try readCwdFile(allocator, ".amp/settings.json")) orelse return error.TestUnexpectedResult;
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

            const content = (try readCwdFile(allocator, ".claude/agents/cog-code-query.md")) orelse return error.TestUnexpectedResult;
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

            const content = (try readCwdFile(allocator, "opencode.json")) orelse return error.TestUnexpectedResult;
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
            const first = (try readCwdFile(allocator, ".test/agent.md")) orelse return error.TestUnexpectedResult;
            defer allocator.free(first);

            try writeMarkdownAgent(allocator, ".test/agent.md", header, build_options.agent_body);
            const second = (try readCwdFile(allocator, ".test/agent.md")) orelse return error.TestUnexpectedResult;
            defer allocator.free(second);

            try std.testing.expectEqualStrings(first, second);
        }
    }.run);
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
            const windsurf = (try readCwdFile(allocator, ".windsurf/skills/cog-code-query/SKILL.md")) orelse return error.TestUnexpectedResult;
            defer allocator.free(windsurf);
            try std.testing.expect(std.mem.indexOf(u8, windsurf, "shared skill files rather than hard-scoped subagents") != null);

            try configureMemAgentFile(allocator, agents_mod.agents[7]); // goose
            const goose = (try readCwdFile(allocator, ".goose/skills/cog-mem/SKILL.md")) orelse return error.TestUnexpectedResult;
            defer allocator.free(goose);
            try std.testing.expect(std.mem.indexOf(u8, goose, "shared skill files rather than hard-scoped subagents") != null);
            try std.testing.expect(std.mem.indexOf(u8, goose, "engram IDs") != null);
        }
    }.run);
}

test "prompt-only dedicated agents get host-specific content" {
    try withTempCwd(struct {
        fn run(allocator: std.mem.Allocator) !void {
            try configureAgentFile(allocator, agents_mod.agents[4]); // cursor
            const cursor = (try readCwdFile(allocator, ".agents/skills/cog-code-query/SKILL.md")) orelse return error.TestUnexpectedResult;
            defer allocator.free(cursor);
            // Shared skill files serve several hosts, so no host name leaks in.
            try std.testing.expect(std.mem.indexOf(u8, cursor, "Cursor") == null);
            try std.testing.expect(std.mem.indexOf(u8, cursor, "shared skill files") != null);
            try std.testing.expect(std.mem.indexOf(u8, cursor, "name: cog-code-query") != null);

            try configureMemAgentFile(allocator, agents_mod.agents[2]); // copilot
            const copilot = (try readCwdFile(allocator, ".agents/skills/cog-mem/SKILL.md")) orelse return error.TestUnexpectedResult;
            defer allocator.free(copilot);
            try std.testing.expect(std.mem.indexOf(u8, copilot, "GitHub Copilot") == null);
            try std.testing.expect(std.mem.indexOf(u8, copilot, "retrieval-first triage path") != null);
        }
    }.run);
}

test "config-scoped dedicated agents get host-specific content" {
    try withTempCwd(struct {
        fn run(allocator: std.mem.Allocator) !void {
            try configureAgentFile(allocator, agents_mod.agents[1]); // gemini
            const query = (try readCwdFile(allocator, ".gemini/agents/cog-code-query.md")) orelse return error.TestUnexpectedResult;
            defer allocator.free(query);
            try std.testing.expect(std.mem.indexOf(u8, query, "Gemini CLI provides config-level tool scoping") != null);

            try configureMemAgentFile(allocator, agents_mod.agents[0]); // claude
            const mem = (try readCwdFile(allocator, ".claude/agents/cog-mem.md")) orelse return error.TestUnexpectedResult;
            defer allocator.free(mem);
            try std.testing.expect(std.mem.indexOf(u8, mem, "config-level scoping for this memory specialist") != null);
            try std.testing.expect(std.mem.indexOf(u8, mem, "engram IDs") != null);
        }
    }.run);
}

test "specialist installers cover every capability in the registry" {
    try withTempCwd(struct {
        fn run(allocator: std.mem.Allocator) !void {
            for (agents_mod.agents) |agent| {
                inline for (std.meta.tags(agents_mod.SpecialistKind)) |kind| {
                    if (agent.capabilities().specialists.supports(kind)) {
                        try configureSpecialistFile(allocator, agent, kind);
                        const path = agent.specialistPath(kind) orelse return error.TestUnexpectedResult;
                        try std.testing.expect(fileExistsInCwd(path));

                        const marker = switch (kind) {
                            .code_query => "You are a code index exploration agent.",
                            .debug => "You are a debugging agent.",
                            .memory => "You are a memory sub-agent",
                            .validate => "You are a post-task memory validation sub-agent.",
                            .observe => "You are a system observability agent.",
                        };
                        const content = (try readCwdFile(allocator, path)) orelse return error.TestUnexpectedResult;
                        defer allocator.free(content);
                        try std.testing.expect(std.mem.indexOf(u8, content, marker) != null);
                    }
                }
            }
        }
    }.run);
}

test "raw-text fallback policy is single-sourced across every host surface" {
    // The shared prompt every host reads carries the canonical policy verbatim.
    try std.testing.expect(std.mem.indexOf(u8, build_options.prompt_md, agents_mod.cog_first_exploration_policy) != null);
    try std.testing.expect(std.mem.indexOf(u8, build_options.prompt_md, agents_mod.prompt_raw_text_fallback_policy) != null);

    // The shared code-query specialist body repeats the same narrow exceptions.
    try std.testing.expect(std.mem.indexOf(u8, build_options.agent_body, agents_mod.raw_text_fallback_exceptions) != null);

    // Every specialist instruction builder repeats the same narrow exceptions,
    // so no host class receives a looser raw-text fallback policy.
    const workflow = try buildWorkflowSpecialistInstructions(std.testing.allocator, "Windsurf", .code_query, build_options.agent_body);
    defer std.testing.allocator.free(workflow);
    try std.testing.expect(std.mem.indexOf(u8, workflow, agents_mod.raw_text_fallback_exceptions) != null);

    const prompt_only = try buildPromptOnlySpecialistInstructions(std.testing.allocator, "Cursor", .code_query, build_options.agent_body);
    defer std.testing.allocator.free(prompt_only);
    try std.testing.expect(std.mem.indexOf(u8, prompt_only, agents_mod.raw_text_fallback_exceptions) != null);

    const config_scoped = try buildConfigScopedSpecialistInstructions(std.testing.allocator, "Claude Code", .code_query, build_options.agent_body);
    defer std.testing.allocator.free(config_scoped);
    try std.testing.expect(std.mem.indexOf(u8, config_scoped, agents_mod.raw_text_fallback_exceptions) != null);

    const shared_skill = try buildWorkflowSpecialistInstructions(std.testing.allocator, "this coding agent", .code_query, build_options.agent_body);
    defer std.testing.allocator.free(shared_skill);
    try std.testing.expect(std.mem.indexOf(u8, shared_skill, agents_mod.raw_text_fallback_exceptions) != null);

    // Roo's shared-config custom mode carries the same exceptions.
    try std.testing.expect(std.mem.indexOf(u8, roo_code_query_role, agents_mod.raw_text_fallback_exceptions) != null);
}

test "writeRooAgent creates .roomodes" {
    try withTempCwd(struct {
        fn run(allocator: std.mem.Allocator) !void {
            try writeRooAgent(allocator, ".roomodes", "cog-code-query", "Cog Code Query", "You are a code index exploration agent.");

            const content = (try readCwdFile(allocator, ".roomodes")) orelse return error.TestUnexpectedResult;
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

            const content = (try readCwdFile(allocator, ".roomodes")) orelse return error.TestUnexpectedResult;
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
            try writeRooAgent(allocator, ".roomodes", "cog-mem-validate", "Cog Memory Validate", "validate role");
            try writeRooAgent(allocator, ".roomodes", "cog-observe", "Cog Observe", "observe role");

            const content = (try readCwdFile(allocator, ".roomodes")) orelse return error.TestUnexpectedResult;
            defer allocator.free(content);

            const parsed = try json.parseFromSlice(json.Value, allocator, content, .{});
            defer parsed.deinit();

            const modes = parsed.value.object.get("customModes") orelse return error.TestUnexpectedResult;
            const debug_mode = modes.array.items[0];
            const mem_mode = modes.array.items[1];
            const validate_mode = modes.array.items[2];
            const observe_mode = modes.array.items[3];

            const debug_groups = debug_mode.object.get("groups") orelse return error.TestUnexpectedResult;
            try std.testing.expectEqual(@as(usize, 3), debug_groups.array.items.len);
            try std.testing.expectEqualStrings("command", debug_groups.array.items[1].string);

            const mem_groups = mem_mode.object.get("groups") orelse return error.TestUnexpectedResult;
            try std.testing.expectEqual(@as(usize, 1), mem_groups.array.items.len);
            try std.testing.expectEqualStrings("mcp", mem_groups.array.items[0].string);

            const validate_groups = validate_mode.object.get("groups") orelse return error.TestUnexpectedResult;
            try std.testing.expectEqual(@as(usize, 1), validate_groups.array.items.len);
            try std.testing.expectEqualStrings("mcp", validate_groups.array.items[0].string);
            try std.testing.expect(std.mem.indexOf(u8, validate_mode.object.get("customInstructions").?.string, "short-term") != null);

            const observe_groups = observe_mode.object.get("groups") orelse return error.TestUnexpectedResult;
            try std.testing.expectEqual(@as(usize, 3), observe_groups.array.items.len);
            try std.testing.expectEqualStrings("command", observe_groups.array.items[1].string);
            try std.testing.expect(std.mem.indexOf(u8, observe_mode.object.get("customInstructions").?.string, "system observability") != null);
        }
    }.run);
}
