const std = @import("std");
const json = std.json;
const Stringify = json.Stringify;
const Writer = std.io.Writer;
const agents_mod = @import("agents.zig");
const build_options = @import("build_options");

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
    var s: Stringify = .{ .writer = &aw.writer };
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

    // Add cog server entry
    try s.objectField("cog");
    try s.beginObject();
    // For .vscode/mcp.json (Copilot), include "type": "stdio"
    if (std.mem.eql(u8, key, "servers")) {
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

fn writeJsonAmp(allocator: std.mem.Allocator, path: []const u8) !void {
    if (std.fs.path.dirname(path)) |parent| {
        try ensureDir(parent);
    }

    const existing = readCwdFile(allocator, path);
    defer if (existing) |e| allocator.free(e);

    var aw: Writer.Allocating = .init(allocator);
    defer aw.deinit();
    var s: Stringify = .{ .writer = &aw.writer };
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
    const existing = readCwdFile(allocator, path);
    defer if (existing) |e| allocator.free(e);

    var aw: Writer.Allocating = .init(allocator);
    defer aw.deinit();
    var s: Stringify = .{ .writer = &aw.writer };
    try s.beginObject();

    if (existing) |content| {
        if (json.parseFromSlice(json.Value, allocator, content, .{})) |parsed| {
            defer parsed.deinit();
            if (parsed.value == .object) {
                var iter = parsed.value.object.iterator();
                while (iter.next()) |entry| {
                    if (std.mem.eql(u8, entry.key_ptr.*, "mcp")) continue;
                    try s.objectField(entry.key_ptr.*);
                    try s.write(entry.value_ptr.*);
                }
            }
        } else |_| {}
    }

    try s.objectField("mcp");
    try s.beginObject();
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
    if (std.mem.eql(u8, agent.id, "claude_code")) {
        try writeClaudePermissions(allocator);
    } else if (std.mem.eql(u8, agent.id, "gemini")) {
        try writeGeminiTrust(allocator, agent.mcp_path.?);
    } else if (std.mem.eql(u8, agent.id, "amp")) {
        try writeAmpPermissions(allocator, agent.mcp_path.?);
    }
}

fn writeClaudePermissions(allocator: std.mem.Allocator) !void {
    const path = ".claude/settings.json";
    try ensureDir(".claude");

    const existing = readCwdFile(allocator, path);
    defer if (existing) |e| allocator.free(e);

    var aw: Writer.Allocating = .init(allocator);
    defer aw.deinit();
    var s: Stringify = .{ .writer = &aw.writer };
    try s.beginObject();

    var existing_allow: ?json.Value = null;
    var existing_perms: ?json.Value = null;
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
    try s.endObject(); // root

    const new_content = try aw.toOwnedSlice();
    defer allocator.free(new_content);
    try writeCwdFile(path, new_content);
}

fn writeGeminiTrust(allocator: std.mem.Allocator, mcp_path: []const u8) !void {
    const existing = readCwdFile(allocator, mcp_path) orelse return;
    defer allocator.free(existing);

    const parsed = json.parseFromSlice(json.Value, allocator, existing, .{}) catch return;
    defer parsed.deinit();

    if (parsed.value != .object) return;

    var aw: Writer.Allocating = .init(allocator);
    defer aw.deinit();
    var s: Stringify = .{ .writer = &aw.writer };
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

fn writeAmpPermissions(allocator: std.mem.Allocator, mcp_path: []const u8) !void {
    const existing = readCwdFile(allocator, mcp_path) orelse return;
    defer allocator.free(existing);

    const parsed = json.parseFromSlice(json.Value, allocator, existing, .{}) catch return;
    defer parsed.deinit();

    if (parsed.value != .object) return;

    var aw: Writer.Allocating = .init(allocator);
    defer aw.deinit();
    var s: Stringify = .{ .writer = &aw.writer };
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

// ── Agent File Deployment ────────────────────────────────────────────

pub fn configureAgentFile(allocator: std.mem.Allocator, agent: agents_mod.Agent) !void {
    const agent_path = agent.agent_file_path orelse return;

    if (agent.agent_file_header) |header| {
        try writeMarkdownAgent(allocator, agent_path, header);
    } else if (std.mem.eql(u8, agent.id, "codex")) {
        try writeTomlAgent(allocator, agent_path);
    } else if (std.mem.eql(u8, agent.id, "roo")) {
        try writeRooAgent(allocator, agent_path);
    }
}

fn writeMarkdownAgent(allocator: std.mem.Allocator, path: []const u8, header: []const u8) !void {
    if (std.fs.path.dirname(path)) |parent| {
        try ensureDir(parent);
    }

    const body = build_options.agent_body;
    const content = try std.fmt.allocPrint(allocator, "{s}\n{s}", .{ header, body });
    defer allocator.free(content);
    try writeCwdFile(path, content);
}

fn writeTomlAgent(allocator: std.mem.Allocator, path: []const u8) !void {
    if (std.fs.path.dirname(path)) |parent| {
        try ensureDir(parent);
    }

    const existing = readCwdFile(allocator, path);
    defer if (existing) |e| allocator.free(e);

    const section_marker = "[agents.cog-code-query]";

    if (existing) |content| {
        if (std.mem.indexOf(u8, content, section_marker) != null) return;

        const toml_section = try std.fmt.allocPrint(allocator,
            \\
            \\{s}
            \\description = "Explore code structure using the Cog SCIP index"
            \\developer_instructions = """
            \\{s}"""
            \\
        , .{ section_marker, build_options.agent_body });
        defer allocator.free(toml_section);

        const new_content = try std.fmt.allocPrint(allocator, "{s}{s}", .{ content, toml_section });
        defer allocator.free(new_content);
        try writeCwdFile(path, new_content);
    } else {
        const toml_content = try std.fmt.allocPrint(allocator,
            \\{s}
            \\description = "Explore code structure using the Cog SCIP index"
            \\developer_instructions = """
            \\{s}"""
            \\
        , .{ section_marker, build_options.agent_body });
        defer allocator.free(toml_content);
        try writeCwdFile(path, toml_content);
    }
}

fn writeRooAgent(allocator: std.mem.Allocator, path: []const u8) !void {
    const existing = readCwdFile(allocator, path);
    defer if (existing) |e| allocator.free(e);

    const mode_slug = "cog-code-query";
    const mode_name = "Cog Code Query";
    const role_definition = "You are a code index exploration agent. Use cog_code_query to answer questions about code structure. Always follow this order: 1) find to locate definitions, 2) symbols to understand the file, 3) refs to see usage, 4) Read source only after you know where to look. Never guess filenames. Return concise summaries with file paths and line numbers.";

    var aw: Writer.Allocating = .init(allocator);
    defer aw.deinit();
    var s: Stringify = .{ .writer = &aw.writer };

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
                                    if (slug_val == .string and std.mem.eql(u8, slug_val.string, mode_slug)) {
                                        found_existing = true;
                                        // Write updated entry
                                        try s.beginObject();
                                        try s.objectField("slug");
                                        try s.write(mode_slug);
                                        try s.objectField("name");
                                        try s.write(mode_name);
                                        try s.objectField("roleDefinition");
                                        try s.write(role_definition);
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
        try s.write(mode_slug);
        try s.objectField("name");
        try s.write(mode_name);
        try s.objectField("roleDefinition");
        try s.write(role_definition);
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
                \\{"theme":"default","mcp":{"other":{"type":"remote"},"cog":{"type":"local","command":["old"]}}}
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
            const cog = mcp.object.get("cog") orelse return error.TestUnexpectedResult;
            try std.testing.expect(cog == .object);

            const command = cog.object.get("command") orelse return error.TestUnexpectedResult;
            try std.testing.expect(command == .array);
            try std.testing.expectEqual(@as(usize, 2), command.array.items.len);
            try std.testing.expectEqualStrings("cog", command.array.items[0].string);
            try std.testing.expectEqualStrings("mcp", command.array.items[1].string);
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

            try writeMarkdownAgent(allocator, ".claude/agents/cog-code-query.md", header);

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

test "writeMarkdownAgent is idempotent" {
    try withTempCwd(struct {
        fn run(allocator: std.mem.Allocator) !void {
            const header =
                \\---
                \\name: cog-code-query
                \\---
            ;

            try writeMarkdownAgent(allocator, ".test/agent.md", header);
            const first = readCwdFile(allocator, ".test/agent.md") orelse return error.TestUnexpectedResult;
            defer allocator.free(first);

            try writeMarkdownAgent(allocator, ".test/agent.md", header);
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

            try writeTomlAgent(allocator, ".codex/config.toml");

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

test "writeTomlAgent is idempotent" {
    try withTempCwd(struct {
        fn run(allocator: std.mem.Allocator) !void {
            std.fs.cwd().makeDir(".codex") catch {};
            try writeCwdFile(".codex/config.toml", "model = \"gpt-5\"\n");

            try writeTomlAgent(allocator, ".codex/config.toml");
            try writeTomlAgent(allocator, ".codex/config.toml");

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
            try writeRooAgent(allocator, ".roomodes");

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
            try std.testing.expect(mode.object.get("roleDefinition") != null);
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

            try writeRooAgent(allocator, ".roomodes");

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
        }
    }.run);
}
