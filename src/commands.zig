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
const hooks_mod = @import("hooks.zig");

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

// ── Init Command ────────────────────────────────────────────────────────

pub fn init(allocator: std.mem.Allocator, args: []const [:0]const u8) !void {
    if (hasFlag(args, "--help")) {
        printCommandHelp(help.init);
        return;
    }

    tui.header();

    // Ask which features to set up
    const feature_options = [_]tui.MenuItem{
        .{ .label = "Memory + Tools" },
        .{ .label = "Tools only" },
    };
    const feature_result = try tui.select(allocator, .{
        .prompt = "What would you like to set up?",
        .items = &feature_options,
    });
    const setup_mem = switch (feature_result) {
        .selected => |idx| idx == 0,
        .back, .cancelled => {
            printErr("  Aborted.\n");
            return;
        },
        .input => unreachable,
    };

    if (setup_mem) {
        printErr("\n");
        printErr("  Cog Memory gives your AI agents persistent, associative\n");
        printErr("  memory powered by a knowledge graph with biological\n");
        printErr("  memory dynamics.\n\n");

        // Ask for host (--host flag overrides the interactive prompt)
        const effective_host: []const u8 = if (findFlag(args, "--host")) |h| h else blk: {
            const host_options = [_]tui.MenuItem{
                .{ .label = "trycog.ai" },
                .{ .label = "Custom host", .is_input_option = true },
            };
            const host_result = try tui.select(allocator, .{
                .prompt = "Server host:",
                .items = &host_options,
            });
            break :blk switch (host_result) {
                .selected => "trycog.ai",
                .input => |custom| custom,
                .back, .cancelled => {
                    printErr("  Aborted.\n");
                    return;
                },
            };
        };

        printErr("\n");
        try initBrain(allocator, effective_host);
    }

    tui.separator();

    // Agent multi-select
    var agent_menu_items = agents_mod.toMenuItems();
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

    // Check if any selected agent supports tool permissions
    const any_supports_perms = blk: {
        for (selected_indices) |idx| {
            if (agents_mod.agents[idx].supportsToolPermissions()) break :blk true;
        }
        break :blk false;
    };

    const allow_tools = if (any_supports_perms)
        try tui.confirm("Allow all Cog tools without prompting?")
    else
        false;

    // Process embedded PROMPT.md
    const prompt_content = try processCogMemTags(allocator, build_options.prompt_md, setup_mem);
    defer allocator.free(prompt_content);

    // Track which config files have been written (for dedup)
    var written_mcp: [16][]const u8 = undefined;
    var written_mcp_count: usize = 0;

    // Track which prompt targets have been written (for dedup)
    var written_prompts: [4]agents_mod.PromptTarget = undefined;
    var written_prompts_count: usize = 0;

    // Track which agent files have been written (for dedup)
    var written_agents: [16][]const u8 = undefined;
    var written_agents_count: usize = 0;

    for (selected_indices) |idx| {
        const agent = agents_mod.agents[idx];

        tui.separator();
        printErr("  Setting up ");
        printErr(agent.display_name);
        printErr("...\n");

        // a. Write system prompt to agent's prompt file (dedup by target)
        const prompt_target = agent.prompt_target;
        var prompt_already_written = false;
        for (written_prompts[0..written_prompts_count]) |wt| {
            if (wt == prompt_target) { prompt_already_written = true; break; }
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
            if (written_prompts_count < 4) {
                written_prompts[written_prompts_count] = prompt_target;
                written_prompts_count += 1;
            }
        }

        // b. Configure MCP server (dedup by path)
        if (agent.mcp_path) |mcp_path| {
            var mcp_already_written = false;
            for (written_mcp[0..written_mcp_count]) |wc| {
                if (std.mem.eql(u8, wc, mcp_path)) { mcp_already_written = true; break; }
            }
            if (!mcp_already_written) {
                hooks_mod.configureMcp(allocator, agent) catch {};
                if (agent.mcp_format != .global_only) {
                    printErr("    ");
                    tui.checkmark();
                    printErr(" ");
                    printErr(mcp_path);
                    printErr("\n");
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
                hooks_mod.configureAgentFile(allocator, agent) catch {};
                printErr("    ");
                tui.checkmark();
                printErr(" ");
                printErr(agent_path);
                printErr("\n");
                if (written_agents_count < 16) {
                    written_agents[written_agents_count] = agent_path;
                    written_agents_count += 1;
                }
            }
        }
    }

    // Ensure .cog/ is in .gitignore (only in git repos)
    ensureGitignore(allocator);

    // Code-sign for debug server on macOS
    if (builtin.os.tag == .macos) {
        tui.separator();
        signForDebug(allocator);
    }
}

fn initBrain(allocator: std.mem.Allocator, host: []const u8) !void {
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
        const selection = try selectAccountAndBrain(allocator, accounts_array, host, api_key);
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
) !?AccountBrainSelection {
    // Single account — skip account selection
    if (accounts_array.len == 1) {
        const account = accounts_array[0];
        const slug = getAccountSlug(account) orelse {
            printErr("error: invalid account data\n");
            return error.Explained;
        };
        const brain = try selectBrain(allocator, account, slug, host, api_key);
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

    // Loop: account → brain, Esc on brain returns to account
    while (true) {
        const acct_result = try tui.select(allocator, .{
            .prompt = "Select an account:",
            .items = menu_items.items,
        });
        switch (acct_result) {
            .selected => |idx| {
                const account = accounts_array[idx];
                const slug = getAccountSlug(account) orelse {
                    printErr("error: invalid account data\n");
                    return error.Explained;
                };
                const brain = try selectBrain(allocator, account, slug, host, api_key);
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

    const result = try tui.select(allocator, .{
        .prompt = prompt_text,
        .items = menu_items.items,
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
    var s: Stringify = .{ .writer = &aw.writer };

    try s.beginObject();

    if (existing) |content| {
        if (json.parseFromSlice(json.Value, allocator, content, .{})) |parsed| {
            defer parsed.deinit();

            if (parsed.value == .object) {
                // Copy all non-brain top-level keys
                var top_iter = parsed.value.object.iterator();
                while (top_iter.next()) |entry| {
                    if (std.mem.eql(u8, entry.key_ptr.*, "brain")) continue;
                    try s.objectField(entry.key_ptr.*);
                    try s.write(entry.value_ptr.*);
                }

                // Write brain object, preserving non-url keys from existing brain
                try s.objectField("brain");
                try s.beginObject();

                if (parsed.value.object.get("brain")) |brain| {
                    if (brain == .object) {
                        var brain_iter = brain.object.iterator();
                        while (brain_iter.next()) |entry| {
                            if (std.mem.eql(u8, entry.key_ptr.*, "url")) continue;
                            try s.objectField(entry.key_ptr.*);
                            try s.write(entry.value_ptr.*);
                        }
                    }
                }

                try s.objectField("url");
                try s.write(brain_url);
                try s.endObject();
            } else {
                // Root isn't an object, write fresh brain
                try s.objectField("brain");
                try s.beginObject();
                try s.objectField("url");
                try s.write(brain_url);
                try s.endObject();
            }
        } else |_| {
            // Parse failed, write fresh brain
            try s.objectField("brain");
            try s.beginObject();
            try s.objectField("url");
            try s.write(brain_url);
            try s.endObject();
        }
    } else {
        // No existing file, write fresh
        try s.objectField("brain");
        try s.beginObject();
        try s.objectField("url");
        try s.write(brain_url);
        try s.endObject();
    }

    try s.endObject();

    const new_content = try aw.toOwnedSlice();
    defer allocator.free(new_content);

    printErr("  Writing settings... ");
    try writeCwdFile(".cog/settings.json", new_content);
    tui.checkmark();
    printErr(" .cog/settings.json\n\n");
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

fn ensureGitignore(allocator: std.mem.Allocator) void {
    // Only act in git repos
    std.fs.cwd().access(".git", .{}) catch return;

    const entry = ".cog/";

    const existing = readCwdFile(allocator, ".gitignore");
    defer if (existing) |e| allocator.free(e);

    if (existing) |content| {
        // Check if .cog/ is already listed
        var lines = std.mem.splitScalar(u8, content, '\n');
        while (lines.next()) |line| {
            const trimmed = std.mem.trim(u8, line, &std.ascii.whitespace);
            if (std.mem.eql(u8, trimmed, entry)) return;
        }
        // Append
        const new_content = std.fmt.allocPrint(allocator, "{s}{s}\n", .{
            if (content.len > 0 and content[content.len - 1] != '\n') "\n" else "",
            entry,
        }) catch return;
        defer allocator.free(new_content);

        const file = std.fs.cwd().openFile(".gitignore", .{ .mode = .write_only }) catch return;
        defer file.close();
        file.seekFromEnd(0) catch return;
        var buf: [4096]u8 = undefined;
        var fw = file.writer(&buf);
        fw.interface.writeAll(new_content) catch return;
        fw.interface.flush() catch return;
    } else {
        // Create new .gitignore
        writeCwdFile(".gitignore", entry ++ "\n") catch return;
    }
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

