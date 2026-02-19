const std = @import("std");
const json = std.json;
const Stringify = json.Stringify;
const Writer = std.io.Writer;
const agents_mod = @import("agents.zig");

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

// ── Hook Scripts ────────────────────────────────────────────────────────

const block_native_tools_sh =
    \\#!/bin/bash
    \\# Cog: Block native file mutation tools — use cog MCP tools instead
    \\INPUT=$(cat)
    \\TOOL=$(echo "$INPUT" | jq -r '.tool_name // .tool_info.tool_name // empty' 2>/dev/null)
    \\case "$TOOL" in
    \\  Write|Edit|write_file|edit_file)
    \\    echo "Use cog MCP tools (cog_code_edit, cog_code_create) instead of $TOOL. This keeps the code index in sync." >&2
    \\    exit 2 ;;
    \\  *) exit 0 ;;
    \\esac
    \\
;

const reindex_on_change_sh =
    \\#!/bin/bash
    \\# Cog: Auto-reindex files after mutations
    \\INPUT=$(cat)
    \\FILE=$(echo "$INPUT" | jq -r '.tool_input.file_path // empty' 2>/dev/null)
    \\if [ -n "$FILE" ] && [ -f "$FILE" ]; then
    \\  cog code/index "$FILE" 2>/dev/null
    \\fi
    \\exit 0
    \\
;

pub fn generateHookScripts() !void {
    try ensureDir(".cog/hooks");

    try writeCwdFile(".cog/hooks/block-native-tools.sh", block_native_tools_sh);
    // Make executable
    const f1 = std.fs.cwd().openFile(".cog/hooks/block-native-tools.sh", .{ .mode = .read_write }) catch return;
    defer f1.close();
    f1.chmod(0o755) catch {};

    try writeCwdFile(".cog/hooks/reindex-on-change.sh", reindex_on_change_sh);
    const f2 = std.fs.cwd().openFile(".cog/hooks/reindex-on-change.sh", .{ .mode = .read_write }) catch return;
    defer f2.close();
    f2.chmod(0o755) catch {};
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
                    if (std.mem.eql(u8, entry.key_ptr.*, "amp.tools.disable")) continue;
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

    try s.objectField("amp.tools.disable");
    try s.beginArray();
    try s.write("builtin:write_file");
    try s.write("builtin:edit_file");
    try s.endArray();

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

// ── Hooks Config Generation ─────────────────────────────────────────────

pub fn configureHooks(allocator: std.mem.Allocator, agent: agents_mod.Agent) !void {
    const hooks_path = agent.hooks_path orelse return;

    switch (agent.hooks_format) {
        .claude_code => try writeClaudeCodeHooks(allocator, hooks_path),
        .gemini => try writeGeminiHooks(allocator, hooks_path),
        .windsurf => try writeWindsurfHooks(allocator, hooks_path),
        .cursor => try writeCursorHooks(allocator, hooks_path),
        .amp => try writeAmpHooks(allocator, hooks_path),
        .none => {},
    }
}

fn writeClaudeCodeHooks(allocator: std.mem.Allocator, path: []const u8) !void {
    if (std.fs.path.dirname(path)) |parent| {
        try ensureDir(parent);
    }

    const existing = readCwdFile(allocator, path);
    defer if (existing) |e| allocator.free(e);

    var aw: Writer.Allocating = .init(allocator);
    defer aw.deinit();
    var s: Stringify = .{ .writer = &aw.writer };
    try s.beginObject();

    // Preserve existing non-hooks keys
    if (existing) |content| {
        if (json.parseFromSlice(json.Value, allocator, content, .{})) |parsed| {
            defer parsed.deinit();
            if (parsed.value == .object) {
                var iter = parsed.value.object.iterator();
                while (iter.next()) |entry| {
                    if (std.mem.eql(u8, entry.key_ptr.*, "hooks")) continue;
                    try s.objectField(entry.key_ptr.*);
                    try s.write(entry.value_ptr.*);
                }
            }
        } else |_| {}
    }

    try s.objectField("hooks");
    try s.beginObject();

    try s.objectField("PreToolUse");
    try s.beginArray();
    try s.beginObject();
    try s.objectField("matcher");
    try s.write("Write|Edit");
    try s.objectField("hooks");
    try s.beginArray();
    try s.beginObject();
    try s.objectField("type");
    try s.write("command");
    try s.objectField("command");
    try s.write(".cog/hooks/block-native-tools.sh");
    try s.endObject();
    try s.endArray();
    try s.endObject();
    try s.endArray();

    try s.objectField("PostToolUse");
    try s.beginArray();
    try s.beginObject();
    try s.objectField("matcher");
    try s.write("Write|Edit|Bash");
    try s.objectField("hooks");
    try s.beginArray();
    try s.beginObject();
    try s.objectField("type");
    try s.write("command");
    try s.objectField("command");
    try s.write(".cog/hooks/reindex-on-change.sh");
    try s.endObject();
    try s.endArray();
    try s.endObject();
    try s.endArray();

    try s.endObject(); // hooks
    try s.endObject(); // root

    const new_content = try aw.toOwnedSlice();
    defer allocator.free(new_content);
    try writeCwdFile(path, new_content);
}

fn writeGeminiHooks(allocator: std.mem.Allocator, path: []const u8) !void {
    if (std.fs.path.dirname(path)) |parent| {
        try ensureDir(parent);
    }

    const existing = readCwdFile(allocator, path);
    defer if (existing) |e| allocator.free(e);

    var aw: Writer.Allocating = .init(allocator);
    defer aw.deinit();
    var s: Stringify = .{ .writer = &aw.writer };
    try s.beginObject();

    // Preserve existing non-hooks/non-mcpServers keys
    if (existing) |content| {
        if (json.parseFromSlice(json.Value, allocator, content, .{})) |parsed| {
            defer parsed.deinit();
            if (parsed.value == .object) {
                var iter = parsed.value.object.iterator();
                while (iter.next()) |entry| {
                    if (std.mem.eql(u8, entry.key_ptr.*, "hooks")) continue;
                    // Keep mcpServers if already written by configureMcp
                    try s.objectField(entry.key_ptr.*);
                    try s.write(entry.value_ptr.*);
                }
            }
        } else |_| {}
    }

    try s.objectField("hooks");
    try s.beginObject();

    try s.objectField("BeforeTool");
    try s.beginArray();
    try s.beginObject();
    try s.objectField("matcher");
    try s.write("write_file|edit_file");
    try s.objectField("hooks");
    try s.beginArray();
    try s.beginObject();
    try s.objectField("type");
    try s.write("command");
    try s.objectField("command");
    try s.write(".cog/hooks/block-native-tools.sh");
    try s.endObject();
    try s.endArray();
    try s.endObject();
    try s.endArray();

    try s.objectField("AfterTool");
    try s.beginArray();
    try s.beginObject();
    try s.objectField("hooks");
    try s.beginArray();
    try s.beginObject();
    try s.objectField("type");
    try s.write("command");
    try s.objectField("command");
    try s.write(".cog/hooks/reindex-on-change.sh");
    try s.endObject();
    try s.endArray();
    try s.endObject();
    try s.endArray();

    try s.endObject(); // hooks
    try s.endObject(); // root

    const new_content = try aw.toOwnedSlice();
    defer allocator.free(new_content);
    try writeCwdFile(path, new_content);
}

fn writeWindsurfHooks(allocator: std.mem.Allocator, path: []const u8) !void {
    if (std.fs.path.dirname(path)) |parent| {
        try ensureDir(parent);
    }

    var aw: Writer.Allocating = .init(allocator);
    defer aw.deinit();
    var s: Stringify = .{ .writer = &aw.writer };

    try s.beginObject();
    try s.objectField("hooks");
    try s.beginObject();

    try s.objectField("pre_write_code");
    try s.beginArray();
    try s.beginObject();
    try s.objectField("command");
    try s.write(".cog/hooks/block-native-tools.sh");
    try s.endObject();
    try s.endArray();

    try s.objectField("post_write_code");
    try s.beginArray();
    try s.beginObject();
    try s.objectField("command");
    try s.write(".cog/hooks/reindex-on-change.sh");
    try s.endObject();
    try s.endArray();

    try s.endObject();
    try s.endObject();

    const new_content = try aw.toOwnedSlice();
    defer allocator.free(new_content);
    try writeCwdFile(path, new_content);
}

fn writeCursorHooks(allocator: std.mem.Allocator, path: []const u8) !void {
    if (std.fs.path.dirname(path)) |parent| {
        try ensureDir(parent);
    }

    var aw: Writer.Allocating = .init(allocator);
    defer aw.deinit();
    var s: Stringify = .{ .writer = &aw.writer };

    try s.beginObject();
    try s.objectField("version");
    try s.write(@as(i64, 1));
    try s.objectField("hooks");
    try s.beginObject();
    try s.objectField("afterFileEdit");
    try s.beginArray();
    try s.beginObject();
    try s.objectField("command");
    try s.write(".cog/hooks/reindex-on-change.sh");
    try s.endObject();
    try s.endArray();
    try s.endObject();
    try s.endObject();

    const new_content = try aw.toOwnedSlice();
    defer allocator.free(new_content);
    try writeCwdFile(path, new_content);
}

fn writeAmpHooks(allocator: std.mem.Allocator, path: []const u8) !void {
    // Amp hooks are in the same file as MCP config — merge
    if (std.fs.path.dirname(path)) |parent| {
        try ensureDir(parent);
    }

    const existing = readCwdFile(allocator, path);
    defer if (existing) |e| allocator.free(e);

    var aw: Writer.Allocating = .init(allocator);
    defer aw.deinit();
    var s: Stringify = .{ .writer = &aw.writer };
    try s.beginObject();

    // Preserve existing keys except amp.tools.disable (already set by configureMcp)
    if (existing) |content| {
        if (json.parseFromSlice(json.Value, allocator, content, .{})) |parsed| {
            defer parsed.deinit();
            if (parsed.value == .object) {
                var iter = parsed.value.object.iterator();
                while (iter.next()) |entry| {
                    try s.objectField(entry.key_ptr.*);
                    try s.write(entry.value_ptr.*);
                }
            }
        } else |_| {}
    }

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
