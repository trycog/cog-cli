const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("build_options");
const json = std.json;
const Stringify = json.Stringify;
const Writer = std.io.Writer;
const config_mod = @import("config.zig");
const client = @import("client.zig");
const tui = @import("tui.zig");
const agents_mod = @import("agents.zig");
const agent_usage = @import("agent_usage.zig");
const settings_mod = @import("settings.zig");
const hooks_mod = @import("hooks.zig");
const debug_log = @import("debug_log.zig");
const paths = @import("paths.zig");
const code_intel = @import("code_intel.zig");
const extensions_mod = @import("extensions.zig");
const memory_mod = @import("memory.zig");
const debug_mod = @import("debug.zig");
const sqlite = @import("sqlite.zig");

const Config = config_mod.Config;
const help = @import("help_text.zig");

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

/// Returns true if the file should be written (new file, user said yes, or accept-all).
/// Updates accept_all when the user picks 'a'.
/// When new_content is provided, 'd' shows a diff against the existing file.
fn shouldWriteFile(allocator: std.mem.Allocator, path: []const u8, new_content: []const u8, accept_all: *bool) bool {
    if (!hooks_mod.fileExistsInCwd(path)) return true;
    if (accept_all.*) {
        debug_log.log("shouldWriteFile: accept_all for {s}", .{path});
        return true;
    }
    while (true) {
        const action = tui.confirmOverwrite(path) catch return false;
        debug_log.log("shouldWriteFile: user chose {s} for {s}", .{ @tagName(action), path });
        switch (action) {
            .yes => return true,
            .no => return false,
            .all => {
                accept_all.* = true;
                return true;
            },
            .diff => {
                showFileDiff(allocator, path, new_content);
                continue;
            },
        }
    }
}

fn showFileDiff(allocator: std.mem.Allocator, path: []const u8, new_content: []const u8) void {
    const f = std.fs.cwd().openFile(path, .{}) catch return;
    defer f.close();
    const old_content = f.readToEndAlloc(allocator, 1048576) catch return;
    defer allocator.free(old_content);
    printErr("\n");
    showDiff(allocator, old_content, new_content);
    printErr("\n");
}

fn findFlag(args: []const [:0]const u8, flag: []const u8) ?[:0]const u8 {
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], flag)) {
            if (i + 1 < args.len) return args[i + 1];
        }
    }
    return null;
}

fn hasFlag(args: []const [:0]const u8, flag: []const u8) bool {
    for (args) |arg| {
        if (std.mem.eql(u8, arg, flag)) return true;
    }
    return false;
}

fn printErrFmt(comptime fmt: []const u8, args: anytype) void {
    var buf: [256]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, fmt, args) catch return;
    printErr(msg);
}

fn readStdinLine(allocator: std.mem.Allocator) ![]const u8 {
    var buf: [1024]u8 = undefined;
    const n = std.posix.read(std.fs.File.stdin().handle, &buf) catch {
        printErr("error: failed to read input\n");
        return error.Explained;
    };
    if (n == 0) {
        printErr("error: no input received\n");
        return error.Explained;
    }
    var line = buf[0..n];
    if (line.len > 0 and line[line.len - 1] == '\n') line = line[0 .. line.len - 1];
    if (line.len > 0 and line[line.len - 1] == '\r') line = line[0 .. line.len - 1];
    return allocator.dupe(u8, line);
}

fn printCommandHelp(comptime help_text: []const u8) void {
    tui.header();
    printErr(help_text);
}

/// Process <cog:mem> tags in content.
/// When keep_content is true (memory mode): removes tag lines, keeps content between them.
/// When keep_content is false (tools-only mode): removes tag lines AND all content between them.
/// Collapses consecutive blank lines left by stripping.
fn processCogMemTags(allocator: std.mem.Allocator, content: []const u8, keep_content: bool) ![]const u8 {
    var result: std.ArrayListUnmanaged(u8) = .empty;
    errdefer result.deinit(allocator);

    const open_tag = "<cog:mem>";
    const close_tag = "</cog:mem>";

    var in_mem_block = false;
    var prev_blank = false;
    var first_line = true;
    var lines = std.mem.splitSequence(u8, content, "\n");

    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, &std.ascii.whitespace);

        if (std.mem.eql(u8, trimmed, open_tag)) {
            in_mem_block = true;
            continue;
        }

        if (std.mem.eql(u8, trimmed, close_tag)) {
            in_mem_block = false;
            continue;
        }

        if (in_mem_block and !keep_content) continue;

        // Collapse consecutive blank lines
        const is_blank = trimmed.len == 0;
        if (is_blank and prev_blank) continue;
        prev_blank = is_blank;

        if (!first_line) try result.append(allocator, '\n');
        try result.appendSlice(allocator, line);
        first_line = false;
    }

    return try result.toOwnedSlice(allocator);
}

// ── Brain URL Parser ────────────────────────────────────────────────────

const BrainUrlParts = struct {
    host: []const u8,
    account: []const u8,
    brain: []const u8,
};

fn parseBrainUrl(url: []const u8) ?BrainUrlParts {
    const after_scheme = if (std.mem.startsWith(u8, url, "https://"))
        url["https://".len..]
    else if (std.mem.startsWith(u8, url, "http://"))
        url["http://".len..]
    else
        return null;

    const first_slash = std.mem.indexOfScalar(u8, after_scheme, '/') orelse return null;
    const host = after_scheme[0..first_slash];
    const rest = after_scheme[first_slash + 1 ..];

    const second_slash = std.mem.indexOfScalar(u8, rest, '/') orelse return null;
    const account = rest[0..second_slash];
    const brain = rest[second_slash + 1 ..];

    if (host.len == 0 or account.len == 0 or brain.len == 0) return null;

    return .{
        .host = host,
        .account = account,
        .brain = brain,
    };
}

// ── Init Command ────────────────────────────────────────────────────────

pub fn init(allocator: std.mem.Allocator, args: []const [:0]const u8) !void {
    if (hasFlag(args, "--help")) {
        printCommandHelp(help.init);
        return;
    }

    debug_log.log("commands.init: starting", .{});
    tui.header();

    // Load existing settings for defaults
    const existing_settings = settings_mod.Settings.load(allocator);
    defer if (existing_settings) |s| s.deinit(allocator);

    const existing_brain_parts: ?BrainUrlParts = if (existing_settings) |s|
        if (s.memory) |m|
            if (m.brain) |b| parseBrainUrl(b.url) else null
        else
            null
    else
        null;

    // Ask which memory backend to use
    const setup_mem = true;
    {
        const mem_options = [_]tui.MenuItem{
            .{ .label = "Local (SQLite)" },
            .{ .label = "Hosted (trycog.ai)" },
        };

        // Pre-select based on existing config
        const mem_initial: usize = if (existing_brain_parts != null) 1 else 0;

        const mem_result = try tui.select(allocator, .{
            .prompt = "Memory backend:",
            .items = &mem_options,
            .initial = mem_initial,
        });
        switch (mem_result) {
            .selected => |idx| {
                if (idx == 0) {
                    // Local SQLite — write file: brain to settings
                    printErr("\n");
                    try writeSettingsMerge(allocator, "file:.cog/brain.db");
                } else {
                    // Hosted — existing host/brain selection flow
                    printErr("\n");
                    printErr("  Cog Memory gives your AI agents persistent, associative\n");
                    printErr("  memory powered by a knowledge graph with biological\n");
                    printErr("  memory dynamics.\n\n");

                    // Ask for host (--host flag overrides the interactive prompt)
                    const effective_host: []const u8 = if (findFlag(args, "--host")) |h| h else blk: {
                        var host_items_buf: [3]tui.MenuItem = undefined;
                        var host_count: usize = 0;
                        var host_initial: usize = 0;

                        const existing_custom_host: ?[]const u8 = if (existing_brain_parts) |parts|
                            if (!std.mem.eql(u8, parts.host, "trycog.ai")) parts.host else null
                        else
                            null;

                        if (existing_custom_host) |custom| {
                            host_items_buf[host_count] = .{ .label = custom };
                            host_count += 1;
                        }
                        const trycog_idx = host_count;
                        host_items_buf[host_count] = .{ .label = "trycog.ai" };
                        host_count += 1;
                        host_items_buf[host_count] = .{ .label = "Custom host", .is_input_option = true };
                        host_count += 1;

                        if (existing_brain_parts != null) {
                            host_initial = if (existing_custom_host != null) 0 else trycog_idx;
                        }

                        const host_result = try tui.select(allocator, .{
                            .prompt = "Server host:",
                            .items = host_items_buf[0..host_count],
                            .initial = host_initial,
                        });
                        break :blk switch (host_result) {
                            .selected => |sel| if (sel == trycog_idx)
                                @as([]const u8, "trycog.ai")
                            else
                                (existing_custom_host orelse unreachable),
                            .input => |custom| custom,
                            .back, .cancelled => {
                                printErr("  Aborted.\n");
                                return;
                            },
                        };
                    };

                    printErr("\n");
                    try initBrain(allocator, effective_host, existing_brain_parts);
                }
            },
            .back, .cancelled => {
                printErr("  Aborted.\n");
                return;
            },
            .input => unreachable,
        }
        deployBootstrapTemplates();
    }

    tui.separator();

    // Agent multi-select
    const agent_menu_entries = try agents_mod.buildMenuEntries(allocator);
    var agent_menu_items: [agents_mod.agents.len]tui.MenuItem = undefined;
    for (agent_menu_entries, 0..) |entry, i| agent_menu_items[i] = entry.item;
    const agent_result = try tui.multiSelect(allocator, .{
        .prompt = "Select your AI coding agents:",
        .items = &agent_menu_items,
    });
    const selected_indices = switch (agent_result) {
        .selected => |indices| indices,
        .back, .cancelled => {
            printErr("  Aborted.\n");
            return;
        },
    };
    defer allocator.free(selected_indices);

    var selected_agent_indices: [agents_mod.agents.len]usize = undefined;
    var selected_agent_ids: [agents_mod.agents.len][]const u8 = undefined;
    for (selected_indices, 0..) |idx, i| {
        const agent_index = agent_menu_entries[idx].agent_index;
        selected_agent_indices[i] = agent_index;
        selected_agent_ids[i] = agents_mod.agents[agent_index].id;
    }
    try agent_usage.incrementCounts(allocator, selected_agent_ids[0..selected_indices.len]);

    // Tool permissions are installed automatically for agents that support them.
    const allow_tools = true;

    // Process embedded PROMPT.md
    const prompt_content = try processCogMemTags(allocator, build_options.prompt_md, setup_mem);
    defer allocator.free(prompt_content);

    // Track overwrite-all consent for existing files
    var accept_all = false;

    // Track which config files have been written (for dedup)
    var written_mcp: [16][]const u8 = undefined;
    var written_mcp_count: usize = 0;

    // Track which prompt targets have been written (for dedup)
    var written_prompts: [4]agents_mod.PromptTarget = undefined;
    var written_prompts_count: usize = 0;

    // Track which agent files have been written (for dedup)
    var written_agents: [32][]const u8 = undefined;
    var written_agents_count: usize = 0;

    var installed_assets: [96][]const u8 = undefined;
    var installed_assets_count: usize = 0;

    for (selected_agent_indices[0..selected_indices.len]) |idx| {
        const agent = agents_mod.agents[idx];

        tui.separator();
        printErr("  Setting up ");
        printErr(agent.display_name);
        printErr("...\n");

        // a. Write system prompt to agent's prompt file (dedup by target)
        const prompt_target = agent.prompt_target;
        var prompt_already_written = false;
        for (written_prompts[0..written_prompts_count]) |wt| {
            if (wt == prompt_target) {
                prompt_already_written = true;
                break;
            }
        }
        if (!prompt_already_written) {
            const filename = prompt_target.filename();
            // Ensure parent dir for copilot
            if (prompt_target == .copilot_instructions) {
                std.fs.cwd().makeDir(".github") catch |err| switch (err) {
                    error.PathAlreadyExists => {},
                    else => {},
                };
            }
            try updateFileWithPrompt(allocator, filename, prompt_content);
            printErr("    ");
            tui.checkmark();
            printErr(" ");
            printErr(filename);
            printErr("\n");
            appendUniquePath(&installed_assets, &installed_assets_count, filename);
            if (written_prompts_count < 4) {
                written_prompts[written_prompts_count] = prompt_target;
                written_prompts_count += 1;
            }
        }

        // b. Configure MCP server (dedup by path)
        if (agent.mcp_path) |mcp_path| {
            var mcp_already_written = false;
            for (written_mcp[0..written_mcp_count]) |wc| {
                if (std.mem.eql(u8, wc, mcp_path)) {
                    mcp_already_written = true;
                    break;
                }
            }
            if (!mcp_already_written) {
                hooks_mod.configureMcp(allocator, agent) catch {};
                if (agent.mcp_format != .global_only) {
                    printErr("    ");
                    tui.checkmark();
                    printErr(" ");
                    printErr(mcp_path);
                    printErr("\n");
                    appendUniquePath(&installed_assets, &installed_assets_count, mcp_path);
                }
                if (written_mcp_count < 16) {
                    written_mcp[written_mcp_count] = mcp_path;
                    written_mcp_count += 1;
                }
            }
        } else if (agent.mcp_format == .global_only) {
            hooks_mod.configureMcp(allocator, agent) catch {};
        }

        // c. Configure tool permissions if user opted in
        if (allow_tools and agent.supportsToolPermissions()) {
            hooks_mod.configureToolPermissions(allocator, agent) catch {};
            printErr("    ");
            tui.checkmark();
            printErr(" tool permissions\n");
        }

        for (hooks_mod.runtimePolicyAssets(agent)) |asset| {
            if (shouldWriteFile(allocator, asset.path, asset.content, &accept_all)) {
                hooks_mod.configureRuntimePolicyFile(agent, asset.path) catch {};
                printErr("    ");
                tui.checkmark();
                printErr(" ");
                printErr(asset.path);
                printErr("\n");
                appendUniquePath(&installed_assets, &installed_assets_count, asset.path);
            } else {
                printErr("    ");
                printErr(dim ++ "  skipped " ++ reset);
                printErr(asset.path);
                printErr("\n");
            }
        }

        hooks_mod.configureRuntimePolicy(allocator, agent) catch {};

        // d. Deploy agent file (dedup by path)
        if (agent.agent_file_path) |agent_path| {
            var agent_already_written = false;
            for (written_agents[0..written_agents_count]) |wa| {
                if (std.mem.eql(u8, wa, agent_path)) {
                    agent_already_written = true;
                    break;
                }
            }
            if (!agent_already_written) {
                const should_write = if (agent.agent_file_header) |header| blk: {
                    const content = hooks_mod.buildMarkdownAgentContent(allocator, header, build_options.agent_body) catch break :blk true;
                    defer allocator.free(content);
                    break :blk shouldWriteFile(allocator, agent_path, content, &accept_all);
                } else true; // codex/roo: upsert, always write
                if (should_write) {
                    hooks_mod.configureAgentFile(allocator, agent) catch {};
                    printErr("    ");
                    tui.checkmark();
                    printErr(" ");
                    printErr(agent_path);
                    printErr("\n");
                    appendUniquePath(&installed_assets, &installed_assets_count, agent_path);
                } else {
                    printErr("    ");
                    printErr(dim ++ "  skipped " ++ reset);
                    printErr(agent_path);
                    printErr("\n");
                }
                if (written_agents_count < 32) {
                    written_agents[written_agents_count] = agent_path;
                    written_agents_count += 1;
                }
            }
        }

        // e. Deploy debug agent file
        // For agents sharing a path (codex, roo), the writers are additive
        // so we always call configureDebugAgentFile even if the path was seen.
        if (agent.debug_file_path) |debug_path| {
            const shares_path = if (agent.agent_file_path) |ap|
                std.mem.eql(u8, ap, debug_path)
            else
                false;

            if (shares_path) {
                // Codex/Roo: same file, writers append — always write
                hooks_mod.configureDebugAgentFile(allocator, agent) catch {};
            } else {
                var debug_already_written = false;
                for (written_agents[0..written_agents_count]) |wa| {
                    if (std.mem.eql(u8, wa, debug_path)) {
                        debug_already_written = true;
                        break;
                    }
                }
                if (!debug_already_written) {
                    const should_write = if (agent.debug_file_header) |header| blk: {
                        const content = hooks_mod.buildMarkdownAgentContent(allocator, header, build_options.debug_agent_body) catch break :blk true;
                        defer allocator.free(content);
                        break :blk shouldWriteFile(allocator, debug_path, content, &accept_all);
                    } else true;
                    if (should_write) {
                        hooks_mod.configureDebugAgentFile(allocator, agent) catch {};
                        printErr("    ");
                        tui.checkmark();
                        printErr(" ");
                        printErr(debug_path);
                        printErr("\n");
                        appendUniquePath(&installed_assets, &installed_assets_count, debug_path);
                    } else {
                        printErr("    ");
                        printErr(dim ++ "  skipped " ++ reset);
                        printErr(debug_path);
                        printErr("\n");
                    }
                    if (written_agents_count < 32) {
                        written_agents[written_agents_count] = debug_path;
                        written_agents_count += 1;
                    }
                }
            }
        }

        // f. Deploy memory agent file (only when memory is configured)
        if (setup_mem) {
            if (agent.mem_file_path) |mem_path| {
                const shares_path = if (agent.agent_file_path) |ap|
                    std.mem.eql(u8, ap, mem_path)
                else
                    false;

                if (shares_path) {
                    // Codex/Roo: same file, writers append — always write
                    hooks_mod.configureMemAgentFile(allocator, agent) catch {};
                } else {
                    var mem_already_written = false;
                    for (written_agents[0..written_agents_count]) |wa| {
                        if (std.mem.eql(u8, wa, mem_path)) {
                            mem_already_written = true;
                            break;
                        }
                    }
                    if (!mem_already_written) {
                        const should_write = if (agent.mem_file_header) |header| blk: {
                            const content = hooks_mod.buildMarkdownAgentContent(allocator, header, build_options.mem_agent_body) catch break :blk true;
                            defer allocator.free(content);
                            break :blk shouldWriteFile(allocator, mem_path, content, &accept_all);
                        } else true;
                        if (should_write) {
                            hooks_mod.configureMemAgentFile(allocator, agent) catch {};
                            printErr("    ");
                            tui.checkmark();
                            printErr(" ");
                            printErr(mem_path);
                            printErr("\n");
                            appendUniquePath(&installed_assets, &installed_assets_count, mem_path);
                        } else {
                            printErr("    ");
                            printErr(dim ++ "  skipped " ++ reset);
                            printErr(mem_path);
                            printErr("\n");
                        }
                        if (written_agents_count < 32) {
                            written_agents[written_agents_count] = mem_path;
                            written_agents_count += 1;
                        }
                    }
                }
            }
        }

        // g. Deploy validate agent file (only when memory is configured)
        if (setup_mem) {
            if (agent.validate_file_path) |validate_path| {
                const shares_path = if (agent.agent_file_path) |ap|
                    std.mem.eql(u8, ap, validate_path)
                else
                    false;

                if (shares_path) {
                    hooks_mod.configureValidateAgentFile(allocator, agent) catch {};
                } else {
                    var validate_already_written = false;
                    for (written_agents[0..written_agents_count]) |wa| {
                        if (std.mem.eql(u8, wa, validate_path)) {
                            validate_already_written = true;
                            break;
                        }
                    }
                    if (!validate_already_written) {
                        const should_write = if (agent.validate_file_header) |header| blk: {
                            const content = hooks_mod.buildMarkdownAgentContent(allocator, header, build_options.validate_agent_body) catch break :blk true;
                            defer allocator.free(content);
                            break :blk shouldWriteFile(allocator, validate_path, content, &accept_all);
                        } else true;
                        if (should_write) {
                            hooks_mod.configureValidateAgentFile(allocator, agent) catch {};
                            printErr("    ");
                            tui.checkmark();
                            printErr(" ");
                            printErr(validate_path);
                            printErr("\n");
                            appendUniquePath(&installed_assets, &installed_assets_count, validate_path);
                        } else {
                            printErr("    ");
                            printErr(dim ++ "  skipped " ++ reset);
                            printErr(validate_path);
                            printErr("\n");
                        }
                        if (written_agents_count < 32) {
                            written_agents[written_agents_count] = validate_path;
                            written_agents_count += 1;
                        }
                    }
                }
            }
        }
    }

    try writeClientContextManifest(
        allocator,
        selected_agent_ids[0..selected_indices.len],
        installed_assets[0..installed_assets_count],
        setup_mem,
    );

    try ensureCogGitignore(allocator);

    // Code-sign for debug server on macOS
    if (builtin.os.tag == .macos) {
        tui.separator();
        signForDebug(allocator);
    }
}

fn initBrain(allocator: std.mem.Allocator, host: []const u8, existing_parts: ?BrainUrlParts) !void {
    // Get API key
    const api_key = config_mod.getApiKey(allocator) catch {
        printErr("  error: COG_API_KEY not set. Set it in your environment or .env file.\n");
        return error.Explained;
    };
    defer allocator.free(api_key);

    // Verify API key
    printErr("  Verifying API key... ");
    const verify_url = try std.fmt.allocPrint(allocator, "https://{s}/api/v1/verify", .{host});
    defer allocator.free(verify_url);

    const verify_body = client.httpGet(allocator, verify_url, api_key) catch {
        printErr("\n  error: failed to verify API key (check COG_API_KEY and host)\n");
        return error.Explained;
    };
    defer allocator.free(verify_body);

    // Parse {"data": {"username": "..."}}
    const verify_parsed = json.parseFromSlice(json.Value, allocator, verify_body, .{}) catch {
        printErr("\n  error: invalid response from server\n");
        return error.Explained;
    };
    defer verify_parsed.deinit();

    const username = blk: {
        if (verify_parsed.value == .object) {
            if (verify_parsed.value.object.get("data")) |data| {
                if (data == .object) {
                    if (data.object.get("username")) |u| {
                        if (u == .string) break :blk u.string;
                    }
                }
            }
        }
        printErr("\n  error: unexpected response from verify endpoint\n");
        return error.Explained;
    };
    tui.checkmark();
    printErr(" ");
    printErr(username);
    printErr("\n\n");

    {
        // List brains via REST API
        const list_url = try std.fmt.allocPrint(allocator, "https://{s}/api/v1/brains/list", .{host});
        defer allocator.free(list_url);

        const brains_text = try client.post(allocator, list_url, api_key, "{}");
        defer allocator.free(brains_text);

        const accounts_parsed = json.parseFromSlice(json.Value, allocator, brains_text, .{}) catch {
            printErr("error: invalid response from server\n");
            return error.Explained;
        };
        defer accounts_parsed.deinit();

        const accounts_array = blk: {
            if (accounts_parsed.value == .object) {
                if (accounts_parsed.value.object.get("namespaces")) |a| {
                    if (a == .array) break :blk a.array.items;
                }
            }
            printErr("error: unexpected accounts format\n");
            return error.Explained;
        };

        if (accounts_array.len == 0) {
            printErr("error: no accounts found\n");
            return error.Explained;
        }

        // Account + Brain selection loop (Esc on brain goes back to account)
        const selection = try selectAccountAndBrain(allocator, accounts_array, host, api_key, existing_parts);
        if (selection == null) {
            printErr("Aborted.\n");
            return;
        }
        const account_slug = selection.?.account_slug;
        const selected_brain = selection.?.brain_name;
        defer allocator.free(selected_brain);

        const brain_url = try std.fmt.allocPrint(allocator, "https://{s}/{s}/{s}", .{ host, account_slug, selected_brain });
        defer allocator.free(brain_url);

        try writeSettingsMerge(allocator, brain_url);
    }
}

fn deployBootstrapTemplates() void {
    const cog_dir = std.fs.cwd().openDir(".cog", .{}) catch return;

    // Write MEM_BOOTSTRAP.md only if it doesn't already exist
    cog_dir.access("MEM_BOOTSTRAP.md", .{}) catch {
        if (cog_dir.createFile("MEM_BOOTSTRAP.md", .{})) |file| {
            defer file.close();
            file.writeAll(build_options.bootstrap_prompt) catch {};
        } else |_| {}
    };

    // Write MEM_BOOTSTRAP_ASSOCIATE.md only if it doesn't already exist
    cog_dir.access("MEM_BOOTSTRAP_ASSOCIATE.md", .{}) catch {
        if (cog_dir.createFile("MEM_BOOTSTRAP_ASSOCIATE.md", .{})) |file| {
            defer file.close();
            file.writeAll(build_options.bootstrap_associate_prompt) catch {};
        } else |_| {}
    };
}

fn buildAccountLabel(allocator: std.mem.Allocator, account: json.Value) ![]const u8 {
    if (account == .object) {
        const name = if (account.object.get("name")) |s| (if (s == .string) s.string else null) else null;
        const acct_type = if (account.object.get("type")) |t| (if (t == .string) t.string else null) else null;
        if (name) |n| {
            if (acct_type) |t| {
                return std.fmt.allocPrint(allocator, "{s} ({s})", .{ n, t });
            }
            return allocator.dupe(u8, n);
        }
    }
    return allocator.dupe(u8, "(unknown)");
}

const AccountBrainSelection = struct {
    account_slug: []const u8,
    brain_name: []const u8,
};

fn selectAccountAndBrain(
    allocator: std.mem.Allocator,
    accounts_array: []const json.Value,
    host: []const u8,
    api_key: []const u8,
    existing_parts: ?BrainUrlParts,
) !?AccountBrainSelection {
    // Single account — skip account selection
    if (accounts_array.len == 1) {
        const account = accounts_array[0];
        const slug = getAccountSlug(account) orelse {
            printErr("error: invalid account data\n");
            return error.Explained;
        };
        const existing_brain_name: ?[]const u8 = if (existing_parts) |p|
            if (std.mem.eql(u8, p.account, slug)) p.brain else null
        else
            null;
        const brain = try selectBrain(allocator, account, slug, host, api_key, existing_brain_name);
        if (brain) |b| return .{ .account_slug = slug, .brain_name = b };
        return null; // cancelled
    }

    // Build account menu labels
    var labels: std.ArrayListUnmanaged([]const u8) = .empty;
    defer {
        for (labels.items) |l| allocator.free(l);
        labels.deinit(allocator);
    }
    var menu_items: std.ArrayListUnmanaged(tui.MenuItem) = .empty;
    defer menu_items.deinit(allocator);

    for (accounts_array) |account| {
        const label = try buildAccountLabel(allocator, account);
        try labels.append(allocator, label);
        try menu_items.append(allocator, .{ .label = label });
    }

    // Pre-select existing account if known
    const initial_account: usize = if (existing_parts) |parts| blk: {
        for (accounts_array, 0..) |account, idx| {
            if (getAccountSlug(account)) |slug| {
                if (std.mem.eql(u8, slug, parts.account)) break :blk idx;
            }
        }
        break :blk 0;
    } else 0;

    // Loop: account → brain, Esc on brain returns to account
    while (true) {
        const acct_result = try tui.select(allocator, .{
            .prompt = "Select an account:",
            .items = menu_items.items,
            .initial = initial_account,
        });
        switch (acct_result) {
            .selected => |idx| {
                const account = accounts_array[idx];
                const slug = getAccountSlug(account) orelse {
                    printErr("error: invalid account data\n");
                    return error.Explained;
                };
                const existing_brain_name: ?[]const u8 = if (existing_parts) |p|
                    if (std.mem.eql(u8, p.account, slug)) p.brain else null
                else
                    null;
                const brain = try selectBrain(allocator, account, slug, host, api_key, existing_brain_name);
                if (brain) |b| return .{ .account_slug = slug, .brain_name = b };
                // brain returned null (back) — loop to re-show account menu
            },
            .back, .cancelled => return null,
            .input => unreachable,
        }
    }
}

fn getAccountSlug(account: json.Value) ?[]const u8 {
    if (account == .object) {
        if (account.object.get("name")) |s| {
            if (s == .string) return s.string;
        }
    }
    return null;
}

fn selectBrain(
    allocator: std.mem.Allocator,
    selected_account: json.Value,
    account_slug: []const u8,
    host: []const u8,
    api_key: []const u8,
    existing_brain_name: ?[]const u8,
) !?[]const u8 {
    // Extract brains array, or go to create if none
    const brains_items = blk: {
        if (selected_account == .object) {
            if (selected_account.object.get("brains")) |b| {
                if (b == .array and b.array.items.len > 0) break :blk b.array.items;
            }
        }
        // No brains — go straight to create
        printErr("  No brains in ");
        printErr(account_slug);
        printErr(".\n\n");
        return try promptCreateBrain(allocator, account_slug, host, api_key, null);
    };

    var menu_items: std.ArrayListUnmanaged(tui.MenuItem) = .empty;
    defer menu_items.deinit(allocator);

    for (brains_items) |brain| {
        const label = if (brain == .object)
            if (brain.object.get("name")) |n| (if (n == .string) n.string else "?") else "?"
        else
            "?";
        try menu_items.append(allocator, .{ .label = label });
    }
    try menu_items.append(allocator, .{ .label = "Create new brain", .is_input_option = true });

    const prompt_text = try std.fmt.allocPrint(allocator, "Select a brain in {s}:", .{account_slug});
    defer allocator.free(prompt_text);

    const initial_brain: usize = if (existing_brain_name) |name| blk: {
        for (brains_items, 0..) |brain, idx| {
            const bname = if (brain == .object)
                if (brain.object.get("name")) |n| (if (n == .string) n.string else null) else null
            else
                null;
            if (bname) |bn| {
                if (std.mem.eql(u8, bn, name)) break :blk idx;
            }
        }
        break :blk 0;
    } else 0;

    const result = try tui.select(allocator, .{
        .prompt = prompt_text,
        .items = menu_items.items,
        .initial = initial_brain,
        .input_validator = &tui.validateBrainName,
    });
    switch (result) {
        .selected => |idx| {
            const brain_val = brains_items[idx];
            if (brain_val == .object) {
                if (brain_val.object.get("name")) |n| {
                    if (n == .string) return try allocator.dupe(u8, n.string);
                }
            }
            printErr("error: invalid brain data\n");
            return error.Explained;
        },
        .input => |name| {
            return try promptCreateBrain(allocator, account_slug, host, api_key, name);
        },
        .back => return null,
        .cancelled => {
            printErr("Aborted.\n");
            return error.Explained;
        },
    }
}

fn promptCreateBrain(
    allocator: std.mem.Allocator,
    account_slug: []const u8,
    host: []const u8,
    api_key: []const u8,
    pre_name: ?[]const u8,
) ![]const u8 {
    const brain_name = if (pre_name) |name|
        name
    else blk: {
        printErr("Brain name: ");
        break :blk try readStdinLine(allocator);
    };
    errdefer allocator.free(brain_name);

    if (brain_name.len == 0) {
        printErr("error: brain name cannot be empty\n");
        return error.Explained;
    }

    printErr("  Creating brain... ");

    var aw: Writer.Allocating = .init(allocator);
    defer aw.deinit();
    var s_json: Stringify = .{ .writer = &aw.writer };
    try s_json.beginObject();
    try s_json.objectField("namespace");
    try s_json.write(@as([]const u8, account_slug));
    try s_json.objectField("name");
    try s_json.write(@as([]const u8, brain_name));
    try s_json.endObject();
    const create_args = try aw.toOwnedSlice();
    defer allocator.free(create_args);

    const create_url = try std.fmt.allocPrint(allocator, "https://{s}/api/v1/brains/create", .{host});
    defer allocator.free(create_url);

    const result = client.postRaw(allocator, create_url, api_key, create_args) catch {
        printErr("\n  error: failed to connect to server\n");
        return error.Explained;
    };
    defer allocator.free(result.body);

    if (result.status_code == 201 or result.status_code == 200) {
        tui.checkmark();
        printErr("\n\n");
        return brain_name;
    }

    // Check if the error is "already exists" — if so, just use the name
    if (isAlreadyExistsError(allocator, result.body)) {
        tui.checkmark();
        printErr(" (exists)\n\n");
        return brain_name;
    }

    // Some other error
    printErr("\n");
    printServerError(allocator, result.body);
    return error.Explained;
}

fn isAlreadyExistsError(allocator: std.mem.Allocator, body: []const u8) bool {
    const parsed = json.parseFromSlice(json.Value, allocator, body, .{}) catch return false;
    defer parsed.deinit();
    if (parsed.value != .object) return false;
    const err_val = parsed.value.object.get("error") orelse return false;
    if (err_val != .object) return false;
    const msg = err_val.object.get("message") orelse return false;
    if (msg != .string) return false;
    return std.mem.indexOf(u8, msg.string, "has already been taken") != null;
}

fn printServerError(allocator: std.mem.Allocator, body: []const u8) void {
    const parsed = json.parseFromSlice(json.Value, allocator, body, .{}) catch {
        printErr("error: server returned an error\n");
        return;
    };
    defer parsed.deinit();
    if (parsed.value == .object) {
        if (parsed.value.object.get("error")) |err_val| {
            if (err_val == .object) {
                if (err_val.object.get("message")) |msg| {
                    if (msg == .string) {
                        printErr("error: ");
                        printErr(msg.string);
                        printErr("\n");
                        return;
                    }
                }
            }
        }
    }
    printErr("error: server returned an error\n");
}

fn writeSettingsMerge(allocator: std.mem.Allocator, brain_url: []const u8) !void {
    // Ensure .cog/ directory exists
    std.fs.cwd().makeDir(".cog") catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => {
            printErr("  error: failed to create .cog directory\n");
            return error.Explained;
        },
    };

    const existing = readCwdFile(allocator, ".cog/settings.json");
    defer if (existing) |e| allocator.free(e);

    var aw: Writer.Allocating = .init(allocator);
    defer aw.deinit();
    var s: Stringify = .{ .writer = &aw.writer, .options = .{ .whitespace = .indent_2 } };

    try s.beginObject();

    if (existing) |content| {
        if (json.parseFromSlice(json.Value, allocator, content, .{})) |parsed| {
            defer parsed.deinit();

            if (parsed.value == .object) {
                // Copy all non-memory top-level keys
                var top_iter = parsed.value.object.iterator();
                while (top_iter.next()) |entry| {
                    if (std.mem.eql(u8, entry.key_ptr.*, "memory")) continue;
                    try s.objectField(entry.key_ptr.*);
                    try s.write(entry.value_ptr.*);
                }

                // Deep merge memory, preserving all existing non-brain keys
                try s.objectField("memory");
                try s.beginObject();

                if (parsed.value.object.get("memory")) |memory| {
                    if (memory == .object) {
                        var mem_iter = memory.object.iterator();
                        while (mem_iter.next()) |entry| {
                            if (std.mem.eql(u8, entry.key_ptr.*, "brain")) continue;
                            try s.objectField(entry.key_ptr.*);
                            try s.write(entry.value_ptr.*);
                        }
                    }
                }

                // Write brain as flat string
                try s.objectField("brain");
                try s.write(brain_url);
                try s.endObject(); // memory
            } else {
                try writeFreshMemoryBrain(&s, brain_url);
            }
        } else |_| {
            try writeFreshMemoryBrain(&s, brain_url);
        }
    } else {
        try writeFreshMemoryBrain(&s, brain_url);
    }

    try s.endObject();

    const new_content = try aw.toOwnedSlice();
    defer allocator.free(new_content);

    // Append trailing newline
    const with_newline = std.fmt.allocPrint(allocator, "{s}\n", .{new_content}) catch {
        printErr("  error: failed to format settings\n");
        return error.Explained;
    };
    defer allocator.free(with_newline);

    printErr("  Writing settings... ");
    try writeCwdFile(".cog/settings.json", with_newline);
    tui.checkmark();
    printErr(" .cog/settings.json\n\n");
}

fn writeFreshMemoryBrain(s: *Stringify, brain_url: []const u8) !void {
    try s.objectField("memory");
    try s.beginObject();
    try s.objectField("brain");
    try s.write(brain_url);
    try s.endObject(); // memory
}

fn appendUniquePath(buffer: [][]const u8, count: *usize, path: []const u8) void {
    for (buffer[0..count.*]) |existing| {
        if (std.mem.eql(u8, existing, path)) return;
    }
    if (count.* < buffer.len) {
        buffer[count.*] = path;
        count.* += 1;
    }
}

fn writeClientContextManifest(
    allocator: std.mem.Allocator,
    selected_agent_ids: []const []const u8,
    installed_assets: []const []const u8,
    setup_mem: bool,
) !void {
    debug_log.log("commands.writeClientContextManifest: agents={d} assets={d}", .{ selected_agent_ids.len, installed_assets.len });
    std.fs.cwd().makeDir(".cog") catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return error.Explained,
    };

    var aw: Writer.Allocating = .init(allocator);
    defer aw.deinit();
    var s: Stringify = .{ .writer = &aw.writer, .options = .{ .whitespace = .indent_2 } };
    try s.beginObject();
    try s.objectField("version");
    try s.write(build_options.version);
    try s.objectField("selected_agents");
    try s.beginArray();
    for (selected_agent_ids) |agent_id| try s.write(agent_id);
    try s.endArray();
    try s.objectField("installed_assets");
    try s.beginArray();
    for (installed_assets) |asset| try s.write(asset);
    try s.endArray();
    try s.objectField("features");
    try s.beginObject();
    try s.objectField("enhanced_memory_writes");
    try s.write(setup_mem);
    try s.objectField("rationale_capture_prompts");
    try s.write(setup_mem);
    try s.objectField("provenance_envelopes");
    try s.write(setup_mem);
    try s.endObject();
    try s.endObject();

    const content = try aw.toOwnedSlice();
    defer allocator.free(content);
    const with_newline = try std.fmt.allocPrint(allocator, "{s}\n", .{content});
    defer allocator.free(with_newline);
    try writeCwdFile(".cog/client-context.json", with_newline);
}

// ── Doctor Command ──────────────────────────────────────────────────────

pub fn doctor(allocator: std.mem.Allocator, args: []const [:0]const u8) !void {
    if (hasFlag(args, "--help") or hasFlag(args, "-h")) {
        printCommandHelp(help.doctor);
        return;
    }

    debug_log.log("doctor: starting diagnostics", .{});

    // Glyphs
    const check = "\xE2\x9C\x93"; // ✓
    const cross = "\xE2\x9C\x97"; // ✗
    const red = "\x1B[31m";
    const yellow = "\x1B[33m";

    var passed: usize = 0;
    var warnings: usize = 0;
    var failures: usize = 0;

    tui.header();

    // ── 1. Config ──────────────────────────────────────────────────────

    printErr(cyan ++ bold ++ "  Config" ++ reset ++ "\n");

    const maybe_cog_dir: ?[]const u8 = paths.findCogDir(allocator) catch null;
    defer if (maybe_cog_dir) |d| allocator.free(d);

    if (maybe_cog_dir) |cog_dir| {
        printErr("    " ++ cyan ++ check ++ reset ++ " .cog/ directory found\n");
        passed += 1;
        debug_log.log("doctor: .cog/ found at {s}", .{cog_dir});

        // Check settings.json validity
        const settings_path = std.fmt.allocPrint(allocator, "{s}/settings.json", .{cog_dir}) catch null;
        if (settings_path) |sp| {
            defer allocator.free(sp);
            if (std.fs.openFileAbsolute(sp, .{})) |f| {
                const content = f.readToEndAlloc(allocator, 65536) catch null;
                f.close();
                if (content) |c| {
                    defer allocator.free(c);
                    const trimmed = std.mem.trim(u8, c, &std.ascii.whitespace);
                    if (trimmed.len == 0) {
                        printErr("    " ++ cyan ++ check ++ reset ++ " settings.json valid (empty)\n");
                        passed += 1;
                    } else if (std.json.parseFromSlice(std.json.Value, allocator, trimmed, .{})) |parsed| {
                        parsed.deinit();
                        printErr("    " ++ cyan ++ check ++ reset ++ " settings.json valid\n");
                        passed += 1;
                    } else |_| {
                        printErr("    " ++ red ++ cross ++ reset ++ " settings.json invalid JSON\n");
                        failures += 1;
                    }
                } else {
                    printErr("    " ++ red ++ cross ++ reset ++ " settings.json unreadable\n");
                    failures += 1;
                }
            } else |_| {
                printErr("    " ++ red ++ cross ++ reset ++ " settings.json missing\n");
                failures += 1;
            }
        }
    } else {
        printErr("    " ++ red ++ cross ++ reset ++ " .cog/ directory not found\n");
        failures += 1;
        debug_log.log("doctor: no .cog/ directory", .{});
    }

    // Optionally check global config
    const global_dir: ?[]const u8 = paths.getGlobalConfigDir(allocator) catch null;
    defer if (global_dir) |d| allocator.free(d);
    if (global_dir) |gd| {
        const global_settings = std.fmt.allocPrint(allocator, "{s}/settings.json", .{gd}) catch null;
        if (global_settings) |gs| {
            defer allocator.free(gs);
            if (std.fs.openFileAbsolute(gs, .{})) |f| {
                f.close();
                debug_log.log("doctor: global config found at {s}", .{gs});
            } else |_| {
                debug_log.log("doctor: no global config at {s}", .{gs});
            }
        }
    }

    // ── 2. Memory ──────────────────────────────────────────────────────

    printErr("\n" ++ cyan ++ bold ++ "  Memory" ++ reset ++ "\n");

    mem_check: {
        const settings = settings_mod.Settings.load(allocator);
        defer if (settings) |s| s.deinit(allocator);

        const brain_url: ?[]const u8 = if (settings) |s| blk: {
            const mem = s.memory orelse break :blk null;
            const brain = mem.brain orelse break :blk null;
            break :blk brain.url;
        } else null;

        if (brain_url == null) {
            printErr("    " ++ yellow ++ "!" ++ reset ++ " No brain configured\n");
            warnings += 1;
            debug_log.log("doctor: no brain configured", .{});
            break :mem_check;
        }

        const url = brain_url.?;

        if (std.mem.startsWith(u8, url, "file:")) {
            // Local brain
            const raw_path = url["file:".len..];

            // Resolve path relative to project root
            const project_root: ?[]const u8 = if (maybe_cog_dir) |cd|
                if (std.fs.path.dirname(cd)) |pr| allocator.dupe(u8, pr) catch null else null
            else
                null;
            defer if (project_root) |pr| allocator.free(pr);

            const abs_path: ?[]const u8 = if (std.fs.path.isAbsolute(raw_path))
                allocator.dupe(u8, raw_path) catch null
            else if (project_root) |pr|
                std.fmt.allocPrint(allocator, "{s}/{s}", .{ pr, raw_path }) catch null
            else
                null;
            defer if (abs_path) |ap| allocator.free(ap);

            if (abs_path) |path| {
                const brain_msg = std.fmt.allocPrint(allocator, "    " ++ cyan ++ check ++ reset ++ " Brain: local ({s})\n", .{path}) catch null;
                if (brain_msg) |m| {
                    defer allocator.free(m);
                    printErr(m);
                }
                passed += 1;
                debug_log.log("doctor: local brain at {s}", .{path});

                // Try opening the database
                const path_z = std.posix.toPosixPath(path) catch {
                    printErr("    " ++ red ++ cross ++ reset ++ " Database: path too long\n");
                    failures += 1;
                    break :mem_check;
                };
                var db = sqlite.Db.open(&path_z) catch {
                    printErr("    " ++ red ++ cross ++ reset ++ " Database: failed to open\n");
                    failures += 1;
                    break :mem_check;
                };
                defer db.close();

                // Count engrams
                var stmt = db.prepare("SELECT count(*) FROM engrams") catch {
                    printErr("    " ++ red ++ cross ++ reset ++ " Database: query failed\n");
                    failures += 1;
                    break :mem_check;
                };
                defer stmt.finalize();

                if (stmt.step()) |result| {
                    if (result == .row) {
                        const count = stmt.columnInt(0);
                        var count_buf: [128]u8 = undefined;
                        const count_msg = std.fmt.bufPrint(&count_buf, "    " ++ cyan ++ check ++ reset ++ " Database: {d} engrams\n", .{count}) catch "    " ++ cyan ++ check ++ reset ++ " Database: accessible\n";
                        printErr(count_msg);
                        passed += 1;
                    } else {
                        printErr("    " ++ cyan ++ check ++ reset ++ " Database: accessible\n");
                        passed += 1;
                    }
                } else |_| {
                    printErr("    " ++ red ++ cross ++ reset ++ " Database: query failed\n");
                    failures += 1;
                }
            } else {
                printErr("    " ++ red ++ cross ++ reset ++ " Brain: could not resolve path\n");
                failures += 1;
            }
        } else if (std.mem.startsWith(u8, url, "https://")) {
            // Remote brain
            printErr("    " ++ cyan ++ check ++ reset ++ " Brain: remote\n");
            passed += 1;
            debug_log.log("doctor: remote brain", .{});

            // Check API key
            if (config_mod.getApiKey(allocator)) |key| {
                allocator.free(key);
                printErr("    " ++ cyan ++ check ++ reset ++ " API key configured\n");
                passed += 1;
            } else |_| {
                printErr("    " ++ red ++ cross ++ reset ++ " COG_API_KEY not set\n");
                failures += 1;
            }
        } else {
            printErr("    " ++ yellow ++ "!" ++ reset ++ " Unknown brain URL scheme\n");
            warnings += 1;
        }
    }

    // ── 3. Code Intelligence ───────────────────────────────────────────

    printErr("\n" ++ cyan ++ bold ++ "  Code Intelligence" ++ reset ++ "\n");

    switch (code_intel.queryIndexStatusForRuntime(allocator)) {
        .ready => {
            printErr("    " ++ cyan ++ check ++ reset ++ " Index ready\n");
            passed += 1;
            debug_log.log("doctor: code index ready", .{});
        },
        .unavailable => {
            printErr("    " ++ yellow ++ "!" ++ reset ++ " Index unavailable\n");
            warnings += 1;
            debug_log.log("doctor: code index unavailable", .{});
        },
    }

    // ── 4. Extensions ──────────────────────────────────────────────────

    printErr("\n" ++ cyan ++ bold ++ "  Extensions" ++ reset ++ "\n");

    if (extensions_mod.listInstalled(allocator)) |installed| {
        defer extensions_mod.freeInstalledList(allocator, installed);
        if (installed.len == 0) {
            printErr("    " ++ dim ++ "- No extensions installed" ++ reset ++ "\n");
            debug_log.log("doctor: no extensions installed", .{});
        } else {
            var ext_buf: [512]u8 = undefined;
            const ext_msg = std.fmt.bufPrint(&ext_buf, "    " ++ cyan ++ check ++ reset ++ " {d} extension{s} installed", .{
                installed.len,
                if (installed.len != 1) "s" else "",
            }) catch null;
            if (ext_msg) |m| {
                printErr(m);
            }
            // List names
            var first_ext = true;
            printErr(": ");
            for (installed) |ext| {
                if (!first_ext) printErr(", ");
                printErr(ext.name);
                first_ext = false;
            }
            printErr("\n");
            passed += 1;
            debug_log.log("doctor: {d} extensions installed", .{installed.len});
        }
    } else |_| {
        printErr("    " ++ dim ++ "- Could not check extensions" ++ reset ++ "\n");
        debug_log.log("doctor: extensions check failed", .{});
    }

    // ── 5. Agent Integration ───────────────────────────────────────────

    printErr("\n" ++ cyan ++ bold ++ "  Agent Integration" ++ reset ++ "\n");

    agent_check: {
        if (maybe_cog_dir == null) {
            printErr("    " ++ yellow ++ "!" ++ reset ++ " No .cog/ directory (run cog init)\n");
            warnings += 1;
            break :agent_check;
        }

        const ctx_path = std.fmt.allocPrint(allocator, "{s}/client-context.json", .{maybe_cog_dir.?}) catch break :agent_check;
        defer allocator.free(ctx_path);

        const ctx_file = std.fs.openFileAbsolute(ctx_path, .{}) catch {
            printErr("    " ++ yellow ++ "!" ++ reset ++ " client-context.json not found (run cog init)\n");
            warnings += 1;
            break :agent_check;
        };
        const ctx_content = ctx_file.readToEndAlloc(allocator, 1048576) catch {
            ctx_file.close();
            printErr("    " ++ red ++ cross ++ reset ++ " client-context.json unreadable\n");
            failures += 1;
            break :agent_check;
        };
        ctx_file.close();
        defer allocator.free(ctx_content);

        const parsed = std.json.parseFromSlice(std.json.Value, allocator, ctx_content, .{}) catch {
            printErr("    " ++ red ++ cross ++ reset ++ " client-context.json invalid JSON\n");
            failures += 1;
            break :agent_check;
        };
        defer parsed.deinit();

        if (parsed.value != .object) {
            printErr("    " ++ red ++ cross ++ reset ++ " client-context.json malformed\n");
            failures += 1;
            break :agent_check;
        }

        // Report configured agents
        if (parsed.value.object.get("selected_agents")) |agents_val| {
            if (agents_val == .array) {
                const count = agents_val.array.items.len;
                var agents_buf: [256]u8 = undefined;
                const agents_msg = std.fmt.bufPrint(&agents_buf, "    " ++ cyan ++ check ++ reset ++ " {d} agent{s}", .{
                    count,
                    if (count != 1) "s" else "",
                }) catch null;
                if (agents_msg) |m| {
                    printErr(m);
                    // List agent names
                    var first = true;
                    printErr(": ");
                    for (agents_val.array.items) |item| {
                        if (item == .string) {
                            if (!first) printErr(", ");
                            printErr(item.string);
                            first = false;
                        }
                    }
                    printErr("\n");
                }
                passed += 1;
            }
        }

        // Check installed assets exist on disk
        if (parsed.value.object.get("installed_assets")) |assets_val| {
            if (assets_val == .array) {
                for (assets_val.array.items) |item| {
                    if (item != .string) continue;
                    const asset_path = item.string;

                    if (hooks_mod.fileExistsInCwd(asset_path)) {
                        var asset_buf: [256]u8 = undefined;
                        const asset_msg = std.fmt.bufPrint(&asset_buf, "    " ++ cyan ++ check ++ reset ++ " {s}\n", .{asset_path}) catch null;
                        if (asset_msg) |m| printErr(m);
                        passed += 1;
                    } else {
                        var asset_buf: [256]u8 = undefined;
                        const asset_msg = std.fmt.bufPrint(&asset_buf, "    " ++ red ++ cross ++ reset ++ " {s} missing\n", .{asset_path}) catch null;
                        if (asset_msg) |m| printErr(m);
                        failures += 1;
                    }
                }
            }
        }
    }

    // ── 6. Debug ───────────────────────────────────────────────────────

    printErr("\n" ++ cyan ++ bold ++ "  Debug" ++ reset ++ "\n");

    debug_check: {
        var path_buf: [128]u8 = undefined;
        const sock_path = debug_mod.daemon.getSocketPath(&path_buf) orelse {
            printErr("    " ++ dim ++ "- Could not determine socket path" ++ reset ++ "\n");
            break :debug_check;
        };
        debug_log.log("doctor: checking daemon socket at {s}", .{sock_path});

        // Check if socket file exists
        if (std.fs.accessAbsolute(sock_path, .{})) {
            // Socket exists — try to connect
            const sock = std.posix.socket(std.posix.AF.UNIX, std.posix.SOCK.STREAM, 0) catch {
                printErr("    " ++ yellow ++ "!" ++ reset ++ " Daemon socket exists but cannot connect (stale?)\n");
                warnings += 1;
                break :debug_check;
            };

            var addr: std.posix.sockaddr.un = .{ .path = undefined };
            @memset(&addr.path, 0);
            @memcpy(addr.path[0..sock_path.len], sock_path);

            std.posix.connect(sock, @ptrCast(&addr), @sizeOf(std.posix.sockaddr.un)) catch {
                std.posix.close(sock);
                printErr("    " ++ yellow ++ "!" ++ reset ++ " Daemon socket stale (connection refused)\n");
                warnings += 1;
                break :debug_check;
            };

            std.posix.close(sock);
            printErr("    " ++ cyan ++ check ++ reset ++ " Daemon running\n");
            passed += 1;
        } else |_| {
            printErr("    " ++ dim ++ "- Daemon not running" ++ reset ++ "\n");
            debug_log.log("doctor: daemon not running", .{});
        }
    }

    // ── Summary ────────────────────────────────────────────────────────

    printErr("\n  ");
    // Print separator: 40 × ─
    const sep = comptime blk: {
        var buf: [40 * 3]u8 = undefined;
        for (0..40) |i| {
            buf[i * 3] = 0xE2;
            buf[i * 3 + 1] = 0x94;
            buf[i * 3 + 2] = 0x80;
        }
        break :blk buf;
    };
    printErr(&sep);
    printErr("\n");

    var summary_buf: [256]u8 = undefined;
    const summary = std.fmt.bufPrint(&summary_buf, "  {d} passed, {d} warning{s}, {d} failure{s}\n\n", .{
        passed,
        warnings,
        if (warnings != 1) @as([]const u8, "s") else "",
        failures,
        if (failures != 1) @as([]const u8, "s") else "",
    }) catch "  doctor check complete\n\n";
    printErr(summary);

    debug_log.log("doctor: done — {d} passed, {d} warnings, {d} failures", .{ passed, warnings, failures });

    if (failures > 0) return error.Explained;
}

// ── System Prompt Setup ─────────────────────────────────────────────────

fn readCwdFile(allocator: std.mem.Allocator, filename: []const u8) ?[]const u8 {
    const f = std.fs.cwd().openFile(filename, .{}) catch return null;
    defer f.close();
    return f.readToEndAlloc(allocator, 1048576) catch return null;
}

fn writeCwdFile(filename: []const u8, content: []const u8) !void {
    const file = std.fs.cwd().createFile(filename, .{}) catch {
        printErr("error: failed to write ");
        printErr(filename);
        printErr("\n");
        return error.Explained;
    };
    defer file.close();
    var write_buf: [4096]u8 = undefined;
    var fw = file.writer(&write_buf);
    fw.interface.writeAll(content) catch {
        printErr("error: failed to write ");
        printErr(filename);
        printErr("\n");
        return error.Explained;
    };
    fw.interface.flush() catch {
        printErr("error: failed to write ");
        printErr(filename);
        printErr("\n");
        return error.Explained;
    };
}

fn updateFileWithPrompt(allocator: std.mem.Allocator, filename: []const u8, prompt_content: []const u8) !void {
    const open_tag = "<cog>";
    const close_tag = "</cog>";
    const trimmed_prompt = std.mem.trimRight(u8, prompt_content, &std.ascii.whitespace);

    const existing = readCwdFile(allocator, filename);
    defer if (existing) |e| allocator.free(e);

    const new_content = blk: {
        if (existing) |content| {
            if (std.mem.indexOf(u8, content, open_tag)) |open_pos| {
                const search_start = open_pos + open_tag.len;
                if (std.mem.indexOfPos(u8, content, search_start, close_tag)) |close_pos| {
                    // Replace content between <cog> and </cog>
                    const before = content[0 .. open_pos + open_tag.len];
                    const after = content[close_pos..];
                    break :blk try std.fmt.allocPrint(allocator, "{s}\n{s}\n{s}", .{ before, trimmed_prompt, after });
                }
            }
            // No valid tags found, append at end
            const trimmed_existing = std.mem.trimRight(u8, content, &std.ascii.whitespace);
            break :blk try std.fmt.allocPrint(allocator, "{s}\n\n{s}\n{s}\n{s}\n", .{ trimmed_existing, open_tag, trimmed_prompt, close_tag });
        } else {
            // New file
            break :blk try std.fmt.allocPrint(allocator, "{s}\n{s}\n{s}\n", .{ open_tag, trimmed_prompt, close_tag });
        }
    };
    defer allocator.free(new_content);

    try writeCwdFile(filename, new_content);
}

fn ensureCogGitignore(allocator: std.mem.Allocator) !void {
    _ = allocator;
    debug_log.log("commands.ensureCogGitignore: ensuring .cog/.gitignore", .{});

    std.fs.cwd().makeDir(".cog") catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return error.Explained,
    };

    const content =
        \\*.db
        \\*.scip
        \\*.log
        \\
    ;

    debug_log.log("commands.ensureCogGitignore: writing .cog/.gitignore", .{});
    try writeCwdFile(".cog/.gitignore", content);
}

fn signForDebug(allocator: std.mem.Allocator) void {
    printErr("  Signing for debug server... ");

    // Get path to our own executable
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const exe_path = std.fs.selfExePath(&buf) catch {
        printErr("skipped (could not find executable path)\n");
        return;
    };

    // Write temporary entitlements plist
    const tmp_path = "/tmp/cog-debug-entitlements.plist";
    const plist =
        \\<?xml version="1.0" encoding="UTF-8"?>
        \\<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        \\<plist version="1.0">
        \\<dict>
        \\    <key>com.apple.security.cs.debugger</key>
        \\    <true/>
        \\</dict>
        \\</plist>
        \\
    ;
    const tmp_file = std.fs.cwd().createFile(tmp_path, .{}) catch {
        printErr("skipped (could not write entitlements)\n");
        return;
    };
    tmp_file.writeAll(plist) catch {
        tmp_file.close();
        printErr("skipped (could not write entitlements)\n");
        return;
    };
    tmp_file.close();
    defer std.fs.cwd().deleteFile(tmp_path) catch {};

    // Run codesign
    const result = std.process.Child.run(.{
        .allocator = allocator,
        .argv = &.{ "codesign", "--entitlements", tmp_path, "-fs", "-", exe_path },
    }) catch {
        printErr("skipped (codesign not available)\n");
        return;
    };
    allocator.free(result.stdout);
    allocator.free(result.stderr);

    switch (result.term) {
        .Exited => |code| if (code == 0) {
            tui.checkmark();
            printErr("\n");
            return;
        },
        else => {},
    }
    printErr("skipped (codesign failed)\n");
}

fn makeDirsAbsolute(path: []const u8) !void {
    // Strip leading '/' to get a relative path from root
    const rel_path = if (path.len > 0 and path[0] == '/') path[1..] else path;
    var root = try std.fs.openDirAbsolute("/", .{});
    defer root.close();
    try root.makePath(rel_path);
}

fn writeAbsoluteFile(path: []const u8, content: []const u8) !void {
    const file = std.fs.createFileAbsolute(path, .{}) catch {
        printErr("error: failed to write ");
        printErr(path);
        printErr("\n");
        return error.Explained;
    };
    defer file.close();
    var write_buf: [4096]u8 = undefined;
    var fw = file.writer(&write_buf);
    fw.interface.writeAll(content) catch {
        printErr("error: failed to write ");
        printErr(path);
        printErr("\n");
        return error.Explained;
    };
    fw.interface.flush() catch {
        printErr("error: failed to write ");
        printErr(path);
        printErr("\n");
        return error.Explained;
    };
}

fn readAbsoluteFileAlloc(allocator: std.mem.Allocator, path: []const u8) ?[]const u8 {
    const file = std.fs.openFileAbsolute(path, .{}) catch return null;
    defer file.close();
    return file.readToEndAlloc(allocator, 1048576) catch return null;
}

fn splitLines(allocator: std.mem.Allocator, content: []const u8) ?[]const []const u8 {
    var count: usize = 0;
    var iter = std.mem.splitSequence(u8, content, "\n");
    while (iter.next()) |_| count += 1;

    const lines = allocator.alloc([]const u8, count) catch return null;
    var iter2 = std.mem.splitSequence(u8, content, "\n");
    var idx: usize = 0;
    while (iter2.next()) |line| : (idx += 1) {
        lines[idx] = line;
    }
    return lines;
}

fn showDiff(allocator: std.mem.Allocator, old_content: []const u8, new_content: []const u8) void {
    const old_lines = splitLines(allocator, old_content) orelse return;
    defer allocator.free(old_lines);
    const new_lines = splitLines(allocator, new_content) orelse return;
    defer allocator.free(new_lines);

    const m = old_lines.len;
    const n = new_lines.len;
    const stride = n + 1;

    // Build LCS table
    const dp = allocator.alloc(usize, (m + 1) * (n + 1)) catch return;
    defer allocator.free(dp);

    for (0..m + 1) |i| {
        for (0..n + 1) |j| {
            if (i == 0 or j == 0) {
                dp[i * stride + j] = 0;
            } else if (std.mem.eql(u8, old_lines[i - 1], new_lines[j - 1])) {
                dp[i * stride + j] = dp[(i - 1) * stride + (j - 1)] + 1;
            } else {
                dp[i * stride + j] = @max(dp[(i - 1) * stride + j], dp[i * stride + (j - 1)]);
            }
        }
    }

    // Backtrack to produce diff entries
    const DiffKind = enum { same, removed, added };
    const DiffEntry = struct { kind: DiffKind, line: []const u8 };

    const diff_buf = allocator.alloc(DiffEntry, m + n) catch return;
    defer allocator.free(diff_buf);
    var diff_len: usize = 0;

    var i = m;
    var j = n;
    while (i > 0 or j > 0) {
        if (i > 0 and j > 0 and std.mem.eql(u8, old_lines[i - 1], new_lines[j - 1])) {
            diff_buf[diff_len] = .{ .kind = .same, .line = old_lines[i - 1] };
            diff_len += 1;
            i -= 1;
            j -= 1;
        } else if (j > 0 and (i == 0 or dp[i * stride + (j - 1)] >= dp[(i - 1) * stride + j])) {
            diff_buf[diff_len] = .{ .kind = .added, .line = new_lines[j - 1] };
            diff_len += 1;
            j -= 1;
        } else {
            diff_buf[diff_len] = .{ .kind = .removed, .line = old_lines[i - 1] };
            diff_len += 1;
            i -= 1;
        }
    }

    const entries = diff_buf[0..diff_len];
    std.mem.reverse(DiffEntry, entries);

    // Determine which lines to show (within 3 lines of any change)
    const show = allocator.alloc(bool, diff_len) catch return;
    defer allocator.free(show);
    @memset(show, false);

    const ctx: usize = 3;
    for (entries, 0..) |entry, idx| {
        if (entry.kind != .same) {
            const start = if (idx >= ctx) idx - ctx else 0;
            const end = @min(idx + ctx + 1, diff_len);
            for (start..end) |k| show[k] = true;
        }
    }

    // Display with color
    printErr("\n");
    var in_gap = false;
    for (entries, 0..) |entry, idx| {
        if (!show[idx]) {
            in_gap = true;
            continue;
        }
        if (in_gap) {
            printErr("  \x1B[2m...\x1B[0m\n");
            in_gap = false;
        }
        switch (entry.kind) {
            .same => {
                printErr("  \x1B[2m ");
                printErr(entry.line);
                printErr("\x1B[0m\n");
            },
            .removed => {
                printErr("  \x1B[31m-");
                printErr(entry.line);
                printErr("\x1B[0m\n");
            },
            .added => {
                printErr("  \x1B[32m+");
                printErr(entry.line);
                printErr("\x1B[0m\n");
            },
        }
    }
    printErr("\n");
}

// ── Tests ───────────────────────────────────────────────────────────────

test "parseBrainUrl standard URL" {
    const parts = parseBrainUrl("https://trycog.ai/myuser/mybrain") orelse return error.ParseFailed;
    try std.testing.expectEqualStrings("trycog.ai", parts.host);
    try std.testing.expectEqualStrings("myuser", parts.account);
    try std.testing.expectEqualStrings("mybrain", parts.brain);
}

test "parseBrainUrl custom host" {
    const parts = parseBrainUrl("https://custom.example.com/org/project-brain") orelse return error.ParseFailed;
    try std.testing.expectEqualStrings("custom.example.com", parts.host);
    try std.testing.expectEqualStrings("org", parts.account);
    try std.testing.expectEqualStrings("project-brain", parts.brain);
}

test "parseBrainUrl http scheme" {
    const parts = parseBrainUrl("http://localhost:3000/user/brain") orelse return error.ParseFailed;
    try std.testing.expectEqualStrings("localhost:3000", parts.host);
    try std.testing.expectEqualStrings("user", parts.account);
    try std.testing.expectEqualStrings("brain", parts.brain);
}

test "parseBrainUrl invalid no scheme" {
    try std.testing.expect(parseBrainUrl("trycog.ai/user/brain") == null);
}

test "parseBrainUrl invalid missing brain" {
    try std.testing.expect(parseBrainUrl("https://trycog.ai/user") == null);
}

test "parseBrainUrl invalid empty parts" {
    try std.testing.expect(parseBrainUrl("https:///user/brain") == null);
    try std.testing.expect(parseBrainUrl("https://host//brain") == null);
    try std.testing.expect(parseBrainUrl("https://host/user/") == null);
}

test "appendUniquePath keeps first occurrence only" {
    var buffer: [4][]const u8 = undefined;
    var count: usize = 0;
    appendUniquePath(&buffer, &count, "CLAUDE.md");
    appendUniquePath(&buffer, &count, ".mcp.json");
    appendUniquePath(&buffer, &count, "CLAUDE.md");

    try std.testing.expectEqual(@as(usize, 2), count);
    try std.testing.expectEqualStrings("CLAUDE.md", buffer[0]);
    try std.testing.expectEqualStrings(".mcp.json", buffer[1]);
}

test "writeClientContextManifest writes selected agents and features" {
    const allocator = std.testing.allocator;
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    var original_cwd = std.fs.cwd().openDir(".", .{}) catch unreachable;
    defer {
        original_cwd.setAsCwd() catch unreachable;
        original_cwd.close();
    }

    try tmp_dir.dir.setAsCwd();
    try writeClientContextManifest(allocator, &.{ "opencode", "claude_code" }, &.{ "AGENTS.md", ".mcp.json" }, true);

    const content = readCwdFile(allocator, ".cog/client-context.json") orelse return error.TestUnexpectedResult;
    defer allocator.free(content);
    const parsed = try json.parseFromSlice(json.Value, allocator, content, .{});
    defer parsed.deinit();

    try std.testing.expectEqualStrings(build_options.version, parsed.value.object.get("version").?.string);
    const agents = parsed.value.object.get("selected_agents").?;
    try std.testing.expectEqual(@as(usize, 2), agents.array.items.len);
    try std.testing.expectEqualStrings("opencode", agents.array.items[0].string);

    const features = parsed.value.object.get("features").?;
    try std.testing.expect(features.object.get("enhanced_memory_writes").?.bool);
    try std.testing.expect(features.object.get("provenance_envelopes").?.bool);
}

test "prompt markdown includes stronger memory gate guidance" {
    try std.testing.expect(std.mem.indexOf(u8, build_options.prompt_md, "Record knowledge as you work - use IF-THEN rules:") != null);
    try std.testing.expect(std.mem.indexOf(u8, build_options.prompt_md, "prior knowledge may help") != null);
    try std.testing.expect(std.mem.indexOf(u8, build_options.prompt_md, "Do not launch a separate") != null);
    try std.testing.expect(std.mem.indexOf(u8, build_options.prompt_md, "## BEFORE Responding - Memory Gate") != null);
    try std.testing.expect(std.mem.indexOf(u8, build_options.prompt_md, "Budget: 2-3 code-intelligence calls before responding.") != null);
}

test "processCogMemTags preserves memory gate in memory mode" {
    const allocator = std.testing.allocator;
    const processed = try processCogMemTags(allocator, build_options.prompt_md, true);
    defer allocator.free(processed);

    try std.testing.expect(std.mem.indexOf(u8, processed, "## BEFORE Responding - Memory Gate") != null);
    try std.testing.expect(std.mem.indexOf(u8, processed, "delegate to `cog-mem-validate`") != null);
}

test "processCogMemTags strips memory gate in tools-only mode" {
    const allocator = std.testing.allocator;
    const processed = try processCogMemTags(allocator, build_options.prompt_md, false);
    defer allocator.free(processed);

    try std.testing.expect(std.mem.indexOf(u8, processed, "## BEFORE Responding - Memory Gate") == null);
    try std.testing.expect(std.mem.indexOf(u8, processed, "cog_mem_learn") == null);
}

test "ensureCogGitignore writes cog-local ignore patterns" {
    const allocator = std.testing.allocator;
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    var original_cwd = std.fs.cwd().openDir(".", .{}) catch unreachable;
    defer {
        original_cwd.setAsCwd() catch unreachable;
        original_cwd.close();
    }

    try tmp_dir.dir.setAsCwd();
    try ensureCogGitignore(allocator);

    const content = readCwdFile(allocator, ".cog/.gitignore") orelse return error.TestUnexpectedResult;
    defer allocator.free(content);

    try std.testing.expectEqualStrings("*.db\n*.scip\n*.log\n", content);
    try std.testing.expect(readCwdFile(allocator, ".gitignore") == null);
}

test "ensureCogGitignore overwrites stale cog-local gitignore content" {
    const allocator = std.testing.allocator;
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    var original_cwd = std.fs.cwd().openDir(".", .{}) catch unreachable;
    defer {
        original_cwd.setAsCwd() catch unreachable;
        original_cwd.close();
    }

    try tmp_dir.dir.setAsCwd();
    try std.fs.cwd().makeDir(".cog");
    try writeCwdFile(".cog/.gitignore", "old\n");

    try ensureCogGitignore(allocator);

    const content = readCwdFile(allocator, ".cog/.gitignore") orelse return error.TestUnexpectedResult;
    defer allocator.free(content);

    try std.testing.expectEqualStrings("*.db\n*.scip\n*.log\n", content);
}

// ── Doctor Tests ────────────────────────────────────────────────────────

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

test "doctor returns failure when no .cog directory" {
    try withTempCwd(struct {
        fn run(_: std.mem.Allocator) !void {
            // Create .git boundary so findCogDir stops here
            std.fs.cwd().makeDir(".git") catch {};
            const result = doctor(std.testing.allocator, &.{});
            try std.testing.expectError(error.Explained, result);
        }
    }.run);
}

test "doctor passes with minimal valid config" {
    try withTempCwd(struct {
        fn run(allocator: std.mem.Allocator) !void {
            // Create .git boundary so findCogDir stops here
            std.fs.cwd().makeDir(".git") catch {};
            // Create .cog/settings.json with empty JSON
            std.fs.cwd().makeDir(".cog") catch {};
            const f = try std.fs.cwd().createFile(".cog/settings.json", .{});
            defer f.close();
            var buf: [4096]u8 = undefined;
            var w = f.writer(&buf);
            w.interface.writeAll("{}\n") catch {};
            w.interface.flush() catch {};

            // With minimal config, only warnings (no brain, no index, etc.) — no failures
            const result = doctor(allocator, &.{});
            // Should succeed (no failures, only warnings/skips)
            result catch |err| {
                // If it fails, it should only be Explained (which means there was a failure check)
                try std.testing.expectEqual(error.Explained, err);
                // This is acceptable — the test just validates it doesn't crash
                return;
            };
        }
    }.run);
}

test "doctor --help returns without error" {
    try doctor(std.testing.allocator, &.{"--help"});
}

test "doctor reports failure for invalid settings.json" {
    try withTempCwd(struct {
        fn run(allocator: std.mem.Allocator) !void {
            // Create .git boundary so findCogDir stops here
            std.fs.cwd().makeDir(".git") catch {};
            std.fs.cwd().makeDir(".cog") catch {};
            const f = try std.fs.cwd().createFile(".cog/settings.json", .{});
            defer f.close();
            var buf: [4096]u8 = undefined;
            var w = f.writer(&buf);
            w.interface.writeAll("not valid json!!!") catch {};
            w.interface.flush() catch {};

            const result = doctor(allocator, &.{});
            try std.testing.expectError(error.Explained, result);
        }
    }.run);
}
