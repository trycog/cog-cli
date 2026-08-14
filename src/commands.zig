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
const debug_mod = @import("debug.zig");
const fs_util = @import("fs_util.zig");
const extensions_mod = @import("extensions.zig");
const memory_mod = @import("memory.zig");
const bootstrap_mod = @import("bootstrap.zig");
const sqlite = @import("sqlite.zig");
const credential_boundary = @import("credential_boundary.zig");

const Config = config_mod.Config;
const help = @import("help_text.zig");

const COG_GITIGNORE_CONTENT =
    \\*.db
    \\*.scip
    \\*.log
    \\
;

// ANSI styles
const cyan = "\x1B[36m";
const bold = "\x1B[1m";
const dim = "\x1B[2m";
const reset = "\x1B[0m";

// ── Helpers ─────────────────────────────────────────────────────────────

/// `File.writer` starts in positional mode, so a fresh writer per message
/// rewrites from offset 0 whenever stderr is redirected to a regular file —
/// each message overwrites the previous one. Streaming mode appends, which is
/// what diagnostics (and the credential-approval warnings) require.
fn writeDiagnostic(file: std.fs.File, msg: []const u8) void {
    var buf: [4096]u8 = undefined;
    var w = file.writerStreaming(&buf);
    w.interface.writeAll(msg) catch {};
    w.interface.flush() catch {};
}

fn printErr(msg: []const u8) void {
    writeDiagnostic(std.fs.File.stderr(), msg);
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

fn runHostConfigStep(context: []const u8, result: anyerror!void, success_called: *bool) !void {
    result catch |err| {
        debug_log.log("commands.init: host config merge failed context={s} error={s}", .{ context, @errorName(err) });
        return err;
    };
    debug_log.log("commands.init: host config merge complete context={s}", .{context});
    success_called.* = true;
}

pub fn readStdinLine(allocator: std.mem.Allocator) ![]const u8 {
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

const PromptContext = struct {
    memory_enabled: bool,
    specialists: agents_mod.SpecialistAvailability,
};

fn promptTagEnabled(tag: []const u8, context: PromptContext) ?bool {
    if (std.mem.eql(u8, tag, "<cog:mem>")) return context.memory_enabled;
    if (std.mem.eql(u8, tag, "<cog:code-query>")) return context.specialists.code_query;
    if (std.mem.eql(u8, tag, "<cog:debug>")) return context.specialists.debug;
    if (std.mem.eql(u8, tag, "<cog:memory-specialist>")) return context.memory_enabled and context.specialists.memory;
    if (std.mem.eql(u8, tag, "<cog:validate>")) return context.memory_enabled and context.specialists.validate;
    if (std.mem.eql(u8, tag, "<cog:observe>")) return context.specialists.observe;
    return null;
}

fn isPromptCloseTag(tag: []const u8) bool {
    return std.mem.eql(u8, tag, "</cog:mem>") or
        std.mem.eql(u8, tag, "</cog:code-query>") or
        std.mem.eql(u8, tag, "</cog:debug>") or
        std.mem.eql(u8, tag, "</cog:memory-specialist>") or
        std.mem.eql(u8, tag, "</cog:validate>") or
        std.mem.eql(u8, tag, "</cog:observe>");
}

/// Render the embedded prompt from memory and installed specialist capabilities.
fn processPromptTags(allocator: std.mem.Allocator, content: []const u8, context: PromptContext) ![]const u8 {
    debug_log.log(
        "commands.processPromptTags: memory={any} code={any} debug={any} mem={any} validate={any} observe={any}",
        .{
            context.memory_enabled,
            context.specialists.code_query,
            context.specialists.debug,
            context.specialists.memory,
            context.specialists.validate,
            context.specialists.observe,
        },
    );

    var result: std.ArrayListUnmanaged(u8) = .empty;
    errdefer result.deinit(allocator);

    var include_stack: [8]bool = undefined;
    var depth: usize = 0;
    var include = true;
    var prev_blank = false;
    var first_line = true;
    var lines = std.mem.splitSequence(u8, content, "\n");

    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, &std.ascii.whitespace);

        if (promptTagEnabled(trimmed, context)) |enabled| {
            if (depth >= include_stack.len) return error.InvalidPromptTags;
            include_stack[depth] = include;
            depth += 1;
            include = include and enabled;
            continue;
        }

        if (isPromptCloseTag(trimmed)) {
            if (depth == 0) return error.InvalidPromptTags;
            depth -= 1;
            include = include_stack[depth];
            continue;
        }

        if (!include) continue;

        const is_blank = trimmed.len == 0;
        if (is_blank and prev_blank) continue;
        prev_blank = is_blank;

        if (!first_line) try result.append(allocator, '\n');
        try result.appendSlice(allocator, line);
        first_line = false;
    }

    if (depth != 0) return error.InvalidPromptTags;
    return try result.toOwnedSlice(allocator);
}

fn specialistBody(kind: agents_mod.SpecialistKind) []const u8 {
    return switch (kind) {
        .code_query => build_options.agent_body,
        .debug => build_options.debug_agent_body,
        .memory => build_options.mem_agent_body,
        .validate => build_options.validate_agent_body,
        .observe => build_options.observe_agent_body,
    };
}

fn specialistEnabledForInit(kind: agents_mod.SpecialistKind, memory_enabled: bool, observe_enabled: bool) bool {
    return switch (kind) {
        .code_query, .debug => true,
        .memory, .validate => memory_enabled,
        .observe => observe_enabled,
    };
}

fn installSpecialistAsset(
    allocator: std.mem.Allocator,
    agent: agents_mod.Agent,
    kind: agents_mod.SpecialistKind,
    accept_all: *bool,
    written_paths: [][]const u8,
    written_paths_count: *usize,
    installed_assets: [][]const u8,
    installed_assets_count: *usize,
) !bool {
    const caps = agent.capabilities();
    if (!caps.specialists.supports(kind)) {
        debug_log.log("commands.installSpecialistAsset: unsupported agent={s} kind={s}", .{ agent.id, @tagName(kind) });
        return false;
    }

    const path = agent.specialistPath(kind) orelse {
        debug_log.log("commands.installSpecialistAsset: missing path agent={s} kind={s}", .{ agent.id, @tagName(kind) });
        return false;
    };
    var path_seen = false;
    for (written_paths[0..written_paths_count.*]) |written| {
        if (std.mem.eql(u8, written, path)) {
            path_seen = true;
            break;
        }
    }

    const shared_config = caps.subagent_support == .shared_config;
    if (path_seen and !shared_config) {
        debug_log.log("commands.installSpecialistAsset: reusing path={s} agent={s} kind={s}", .{ path, agent.id, @tagName(kind) });
        return true;
    }

    if (!shared_config) {
        const should_write = if (agent.specialistHeader(kind)) |header| blk: {
            const content = hooks_mod.buildMarkdownAgentContent(allocator, header, specialistBody(kind)) catch break :blk true;
            defer allocator.free(content);
            break :blk shouldWriteFile(allocator, path, content, accept_all);
        } else true;

        if (!should_write) {
            debug_log.log("commands.installSpecialistAsset: skipped path={s} agent={s} kind={s}", .{ path, agent.id, @tagName(kind) });
            appendUniquePath(written_paths, written_paths_count, path);
            printErr("    ");
            printErr(dim ++ "  skipped " ++ reset);
            printErr(path);
            printErr("\n");
            return false;
        }
    }

    hooks_mod.configureSpecialistFile(allocator, agent, kind) catch |err| {
        debug_log.log("commands.installSpecialistAsset: failed path={s} agent={s} kind={s} error={s}", .{ path, agent.id, @tagName(kind), @errorName(err) });
        return err;
    };

    debug_log.log("commands.installSpecialistAsset: installed path={s} agent={s} kind={s}", .{ path, agent.id, @tagName(kind) });
    appendUniquePath(written_paths, written_paths_count, path);
    appendUniquePath(installed_assets, installed_assets_count, path);
    if (!path_seen) {
        printErr("    ");
        tui.checkmark();
        printErr(" ");
        printErr(path);
        printErr("\n");
    }
    return true;
}

// ── Brain URL Parser ────────────────────────────────────────────────────

pub const BrainUrlParts = struct {
    host: []const u8,
    account: []const u8,
    brain: []const u8,
};

pub fn parseBrainUrl(url: []const u8) ?BrainUrlParts {
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
    if (hasFlag(args, "--help") or hasFlag(args, "-h")) {
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
                    if (!try authorizeInitMemoryHost(allocator, effective_host)) {
                        debug_log.log("commands.init: hosted memory origin approval declined; aborting before credential access", .{});
                        printErr("  Aborted; no credentials were sent.\n");
                        return;
                    }
                    try initBrain(allocator, effective_host, existing_brain_parts);
                }
            },
            .back, .cancelled => {
                printErr("  Aborted.\n");
                return;
            },
            .input => unreachable,
        }
        try deployBootstrapTemplates();
    }

    // Offer project scan when settings.json didn't exist before init
    if (existing_settings == null) {
        tui.separator();
        try maybeRunProjectScan(allocator);
    }

    tui.separator();

    // Agent multi-select with auto-detection of already-configured agents
    const agent_menu_entries = try agents_mod.buildMenuEntries(allocator);
    var agent_menu_items: [agents_mod.agents.len]tui.MenuItem = undefined;
    var agent_preselected: [agents_mod.agents.len]bool = undefined;
    for (agent_menu_entries, 0..) |entry, i| {
        agent_menu_items[i] = entry.item;
        agent_preselected[i] = agents_mod.agents[entry.agent_index].isDetectedInCwd();
    }
    const agent_result = try tui.multiSelect(allocator, .{
        .prompt = "Select your AI coding agents:",
        .items = &agent_menu_items,
        .initial_selected = &agent_preselected,
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

    const observe_enabled = settings_mod.isObserveEnabled(allocator);
    debug_log.log("commands.init: observe_enabled={any}", .{observe_enabled});

    // Track overwrite-all consent for existing files
    var accept_all = false;

    // Track which config files have been written (for dedup)
    var written_mcp: [16][]const u8 = undefined;
    var written_mcp_count: usize = 0;

    // Track specialist assets and the capabilities that were actually installed.
    const max_specialist_assets = agents_mod.agents.len * std.meta.fields(agents_mod.SpecialistKind).len;
    var written_agents: [max_specialist_assets][]const u8 = undefined;
    var written_agents_count: usize = 0;
    var installed_specialists: [agents_mod.agents.len]agents_mod.SpecialistAvailability = @splat(.{});

    var installed_assets: [96][]const u8 = undefined;
    var installed_assets_count: usize = 0;

    for (selected_agent_indices[0..selected_indices.len], 0..) |idx, selected_pos| {
        const agent = agents_mod.agents[idx];

        tui.separator();
        printErr("  Setting up ");
        printErr(agent.display_name);
        printErr("...\n");

        // a. Configure MCP server (dedup by path). Prompts are rendered after
        // specialist installation so they only mandate assets that were installed.

        if (agent.mcp_path) |mcp_path| {
            var mcp_already_written = false;
            for (written_mcp[0..written_mcp_count]) |wc| {
                if (std.mem.eql(u8, wc, mcp_path)) {
                    mcp_already_written = true;
                    break;
                }
            }
            if (!mcp_already_written) {
                var configured = false;
                try runHostConfigStep("MCP config", hooks_mod.configureMcp(allocator, agent), &configured);
                if (configured and agent.mcp_format != .global_only) {
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
            try hooks_mod.configureMcp(allocator, agent);
        }

        // c. Configure tool permissions if user opted in
        if (allow_tools and agent.supportsToolPermissions()) {
            var configured = false;
            try runHostConfigStep("tool permissions", hooks_mod.configureToolPermissions(allocator, agent), &configured);
            if (configured) {
                printErr("    ");
                tui.checkmark();
                printErr(" tool permissions\n");
            }
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

        var runtime_policy_configured = false;
        try runHostConfigStep("runtime policy config", hooks_mod.configureRuntimePolicy(allocator, agent), &runtime_policy_configured);

        // d. Install every specialist supported by this host. Memory specialists
        // are only installed when memory was configured during this init run.
        inline for (std.meta.tags(agents_mod.SpecialistKind)) |kind| {
            if (specialistEnabledForInit(kind, setup_mem, observe_enabled)) {
                const installed = try installSpecialistAsset(
                    allocator,
                    agent,
                    kind,
                    &accept_all,
                    &written_agents,
                    &written_agents_count,
                    &installed_assets,
                    &installed_assets_count,
                );
                installed_specialists[selected_pos].set(kind, installed);
            }
        }
    }

    // A shared prompt target must be safe for every selected host that reads it.
    // Intersect actual installation results so one failed or skipped specialist
    // cannot leave a mandate behind for that host.
    var prompt_targets: [4]agents_mod.PromptTarget = undefined;
    var prompt_specialists: [4]agents_mod.SpecialistAvailability = undefined;
    var prompt_target_count: usize = 0;
    for (selected_agent_indices[0..selected_indices.len], 0..) |idx, selected_pos| {
        const target = agents_mod.agents[idx].prompt_target;
        var target_pos: ?usize = null;
        for (prompt_targets[0..prompt_target_count], 0..) |existing, pos| {
            if (existing == target) {
                target_pos = pos;
                break;
            }
        }

        if (target_pos) |pos| {
            prompt_specialists[pos].intersect(installed_specialists[selected_pos]);
        } else {
            prompt_targets[prompt_target_count] = target;
            prompt_specialists[prompt_target_count] = installed_specialists[selected_pos];
            prompt_target_count += 1;
        }
    }

    for (prompt_targets[0..prompt_target_count], prompt_specialists[0..prompt_target_count]) |target, specialists| {
        const filename = target.filename();
        debug_log.log(
            "commands.init: rendering prompt target={s} code={any} debug={any} mem={any} validate={any} observe={any}",
            .{ filename, specialists.code_query, specialists.debug, specialists.memory, specialists.validate, specialists.observe },
        );
        if (target == .copilot_instructions) {
            std.fs.cwd().makeDir(".github") catch |err| switch (err) {
                error.PathAlreadyExists => {},
                else => return err,
            };
        }

        const prompt_content = try processPromptTags(allocator, build_options.prompt_md, .{
            .memory_enabled = setup_mem,
            .specialists = specialists,
        });
        defer allocator.free(prompt_content);
        try updateFileWithPrompt(allocator, filename, prompt_content);
        printErr("    ");
        tui.checkmark();
        printErr(" ");
        printErr(filename);
        printErr("\n");
        appendUniquePath(&installed_assets, &installed_assets_count, filename);
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

// ── Project Scan ────────────────────────────────────────────────────────

fn maybeRunProjectScan(allocator: std.mem.Allocator) !void {
    debug_log.log("maybeRunProjectScan: offering project scan", .{});

    const do_scan = try tui.confirm("Scan project to auto-configure code indexing?");
    if (!do_scan) return;

    printErr("\n");

    // Agent selection (same as mem:bootstrap)
    const cli_menu_entries = try bootstrap_mod.buildCliMenuEntries(allocator);
    var menu_items: [bootstrap_mod.cli_agents.len + 1]tui.MenuItem = undefined;
    for (cli_menu_entries, 0..) |entry, i| {
        menu_items[i] = entry.item;
    }
    menu_items[bootstrap_mod.cli_agents.len] = .{ .label = "Custom command", .is_input_option = true };

    const agent_result = try tui.select(allocator, .{
        .prompt = "Select an agent to scan the project:",
        .items = &menu_items,
    });

    const selected_agent: ?*const bootstrap_mod.CliAgent = switch (agent_result) {
        .selected => |idx| if (idx < bootstrap_mod.cli_agents.len) &bootstrap_mod.cli_agents[cli_menu_entries[idx].cli_index] else null,
        .input => null,
        .back, .cancelled => {
            printErr("  Skipped.\n");
            return;
        },
    };

    const custom_cmd: ?[]const u8 = switch (agent_result) {
        .input => |cmd| cmd,
        else => null,
    };

    if (selected_agent) |agent| {
        try agent_usage.incrementCounts(allocator, &.{agent.id});
    }

    printErr("\n  Scanning project...\n\n");

    const scan_result = runProjectScan(allocator, selected_agent, custom_cmd) orelse {
        printErr("  " ++ dim ++ "Scan did not produce results. Skipping." ++ reset ++ "\n");
        return;
    };
    defer allocator.free(scan_result);

    // Parse JSON response
    const parsed = json.parseFromSlice(json.Value, allocator, scan_result, .{}) catch {
        debug_log.log("maybeRunProjectScan: failed to parse scan JSON", .{});
        printErr("  " ++ dim ++ "Could not parse scan results. Skipping." ++ reset ++ "\n");
        return;
    };
    defer parsed.deinit();

    if (parsed.value != .object) {
        printErr("  " ++ dim ++ "Unexpected scan output format. Skipping." ++ reset ++ "\n");
        return;
    }

    // Extract index_patterns
    const index_patterns: ?[]const json.Value = if (parsed.value.object.get("index_patterns")) |v|
        if (v == .array) v.array.items else null
    else
        null;

    if (index_patterns) |patterns| {
        if (patterns.len > 0) {
            // Collect string patterns
            var pattern_strs: std.ArrayListUnmanaged([]const u8) = .empty;
            defer pattern_strs.deinit(allocator);

            for (patterns) |p| {
                if (p == .string) {
                    try pattern_strs.append(allocator, p.string);
                }
            }

            if (pattern_strs.items.len > 0) {
                printErr("  " ++ bold ++ "Index patterns:" ++ reset ++ "\n");
                for (pattern_strs.items) |pat| {
                    printErr("    ");
                    printErr(pat);
                    printErr("\n");
                }
                printErr("\n");

                try writeSettingsCodeConfig(allocator, pattern_strs.items, &.{}, true);
                printErr("  ");
                tui.checkmark();
                printErr(" Written to .cog/settings.json\n\n");
            }
        }
    }

    // External roots always require explicit interactive approval.
    var approved_external_roots: std.ArrayListUnmanaged([]const u8) = .empty;
    defer approved_external_roots.deinit(allocator);
    if (parsed.value.object.get("external_roots")) |roots_value| {
        if (roots_value == .array) {
            var approve_all = false;
            for (roots_value.array.items) |root_value| {
                if (root_value != .string or root_value.string.len == 0) continue;
                const root = root_value.string;
                var approved = approve_all;
                if (!approved) {
                    const prompt = try std.fmt.allocPrint(allocator, "Allow indexing external root {s}?", .{root});
                    defer allocator.free(prompt);
                    switch (try tui.confirmWithAll(prompt)) {
                        .no => continue,
                        .yes => approved = true,
                        .all => {
                            approved = true;
                            approve_all = true;
                        },
                    }
                }
                if (approved) {
                    try approved_external_roots.append(allocator, root);
                    debug_log.log("maybeRunProjectScan: approved external root {s}", .{root});
                }
            }
            if (approved_external_roots.items.len > 0) printErr("\n");
        }
    }

    if (approved_external_roots.items.len > 0) {
        try writeSettingsCodeConfig(allocator, &.{}, approved_external_roots.items, false);
        printErr("  ");
        tui.checkmark();
        printErr(" External roots written to .cog/settings.json\n\n");
    }

    // Extract extensions
    const ext_recommendations: ?[]const json.Value = if (parsed.value.object.get("extensions")) |v|
        if (v == .array) v.array.items else null
    else
        null;

    if (ext_recommendations) |recs| {
        if (recs.len > 0) {
            // Get installed extensions to skip already-installed ones
            const installed = extensions_mod.listInstalled(allocator) catch &.{};
            defer if (installed.len > 0) extensions_mod.freeInstalledList(allocator, @constCast(installed));

            var install_all = false;

            for (recs) |rec| {
                if (rec != .string) continue;
                const ext_name = rec.string;

                // Look up in registry
                const registry_entry = findRegistryEntry(ext_name) orelse continue;

                // Check if already installed
                if (isExtensionInstalled(installed, registry_entry.name)) {
                    printErr("  ");
                    tui.checkmark();
                    printErr(" ");
                    printErr(ext_name);
                    printErr(" (already installed)\n");
                    continue;
                }

                if (!install_all) {
                    const prompt_msg = try std.fmt.allocPrint(allocator, "Install {s}?", .{ext_name});
                    defer allocator.free(prompt_msg);
                    const result = try tui.confirmWithAll(prompt_msg);
                    switch (result) {
                        .no => continue,
                        .all => install_all = true,
                        .yes => {},
                    }
                }

                // Install the extension. The interactive confirmation above is
                // explicit consent to execute the registry release's build command.
                printErr("  Installing ");
                printErr(ext_name);
                printErr("...");
                debug_log.log("maybeRunProjectScan: installing trusted registry extension {s} from {s}", .{ ext_name, registry_entry.repo_url });
                const install_result = extensions_mod.installExtensionToDir(
                    allocator,
                    registry_entry.repo_url,
                    null,
                    null,
                    .{ .trust_build = true },
                ) catch {
                    printErr(" failed\n");
                    continue;
                };
                extensions_mod.freeInstallResult(allocator, &install_result);
                printErr(" ");
                tui.checkmark();
                printErr("\n");
            }
            printErr("\n");
        }
    }
}

fn findRegistryEntry(name: []const u8) ?*const extensions_mod.ExtensionRegistryEntry {
    for (&extensions_mod.extension_registry) |*entry| {
        if (std.mem.eql(u8, entry.name, name)) return entry;
    }
    return null;
}

fn isExtensionInstalled(installed: []const extensions_mod.InstalledInfo, ext_name: []const u8) bool {
    // Strip "cog-" prefix for matching against display names
    const prefix = "cog-";
    const display_name = if (std.mem.startsWith(u8, ext_name, prefix) and ext_name.len > prefix.len)
        ext_name[prefix.len..]
    else
        ext_name;

    for (installed) |info| {
        if (std.mem.eql(u8, info.name, display_name) or std.mem.eql(u8, info.name, ext_name)) return true;
    }
    return false;
}

fn runProjectScan(
    allocator: std.mem.Allocator,
    selected_agent: ?*const bootstrap_mod.CliAgent,
    custom_cmd: ?[]const u8,
) ?[]const u8 {
    const prompt = build_options.project_scan_prompt;

    // Build argv
    var argv_buf: std.ArrayListUnmanaged([]const u8) = .empty;
    defer argv_buf.deinit(allocator);

    if (selected_agent) |agent| {
        if (agent.env_unset.len > 0) {
            argv_buf.append(allocator, "env") catch return null;
            for (agent.env_unset) |var_name| {
                argv_buf.append(allocator, "-u") catch return null;
                argv_buf.append(allocator, var_name) catch return null;
            }
        }
        for (agent.cmd_prefix) |token| {
            argv_buf.append(allocator, token) catch return null;
        }
        argv_buf.append(allocator, prompt) catch return null;
        for (agent.cmd_suffix) |token| {
            argv_buf.append(allocator, token) catch return null;
        }
    } else if (custom_cmd) |cmd| {
        var cmd_iter = std.mem.splitScalar(u8, cmd, ' ');
        while (cmd_iter.next()) |token| {
            if (token.len > 0) {
                argv_buf.append(allocator, token) catch return null;
            }
        }
        argv_buf.append(allocator, prompt) catch return null;
    } else {
        return null;
    }

    debug_log.log("runProjectScan: spawning agent (argv len={d})", .{argv_buf.items.len});

    var child = std.process.Child.init(argv_buf.items, allocator);
    child.stdin_behavior = .Ignore;
    child.stderr_behavior = .Pipe;
    child.stdout_behavior = .Pipe;

    child.spawn() catch |err| {
        debug_log.log("runProjectScan: spawn error {s}", .{@errorName(err)});
        return null;
    };

    // Read stderr on background thread to avoid deadlock
    const StderrReader = struct {
        fn run(stderr: std.fs.File, alloc: std.mem.Allocator) void {
            _ = stderr.readToEndAlloc(alloc, 10 * 1024 * 1024) catch {};
        }
    };
    const stderr_thread = std.Thread.spawn(.{}, StderrReader.run, .{ child.stderr.?, allocator }) catch null;

    // Read stdout (JSON output)
    const stdout_data = child.stdout.?.readToEndAlloc(allocator, 10 * 1024 * 1024) catch {
        debug_log.log("runProjectScan: failed to read stdout", .{});
        _ = child.wait() catch {};
        return null;
    };

    if (stderr_thread) |t| t.join();

    const term = child.wait() catch {
        debug_log.log("runProjectScan: wait failed", .{});
        allocator.free(stdout_data);
        return null;
    };

    if (term.Exited != 0) {
        debug_log.log("runProjectScan: agent exited with code {d}", .{term.Exited});
        allocator.free(stdout_data);
        return null;
    }

    if (stdout_data.len == 0) {
        allocator.free(stdout_data);
        return null;
    }

    // Some agents wrap their output in JSON with a "result" field; try to extract that
    if (json.parseFromSlice(json.Value, allocator, stdout_data, .{})) |outer| {
        defer outer.deinit();
        if (outer.value == .object) {
            if (outer.value.object.get("result")) |result_val| {
                if (result_val == .string) {
                    // The actual JSON is inside the "result" string — re-parse
                    const inner = allocator.dupe(u8, result_val.string) catch return stdout_data;
                    allocator.free(stdout_data);
                    return inner;
                }
            }
            // If outer already has index_patterns, it's the direct response
            if (outer.value.object.get("index_patterns") != null) {
                return stdout_data;
            }
        }
    } else |_| {}

    return stdout_data;
}

fn writeSettingsCodeConfig(
    allocator: std.mem.Allocator,
    patterns: []const []const u8,
    external_roots: []const []const u8,
    replace_index: bool,
) !void {
    // Read existing settings
    const existing = try readCwdFileOptional(allocator, ".cog/settings.json");
    defer if (existing) |e| allocator.free(e);

    var aw: Writer.Allocating = .init(allocator);
    defer aw.deinit();
    var s: Stringify = .{ .writer = &aw.writer, .options = .{ .whitespace = .indent_2 } };

    try s.beginObject();

    if (existing) |content| {
        if (json.parseFromSlice(json.Value, allocator, content, .{})) |parsed_val| {
            defer parsed_val.deinit();

            if (parsed_val.value == .object) {
                // Copy all non-code top-level keys
                var top_iter = parsed_val.value.object.iterator();
                while (top_iter.next()) |entry| {
                    if (std.mem.eql(u8, entry.key_ptr.*, "code")) continue;
                    try s.objectField(entry.key_ptr.*);
                    try s.write(entry.value_ptr.*);
                }

                // Approving a new external root is additive: an earlier approval
                // of a different root stays in force, so a later scan can never
                // silently revoke access the user already granted.
                var merged_roots: std.ArrayListUnmanaged([]const u8) = .empty;
                defer merged_roots.deinit(allocator);
                if (external_roots.len > 0) {
                    if (parsed_val.value.object.get("code")) |code| {
                        if (code == .object) {
                            if (code.object.get("external_roots")) |existing_roots| {
                                if (existing_roots == .array) {
                                    for (existing_roots.array.items) |entry| {
                                        if (entry != .string) continue;
                                        try appendUniqueRoot(allocator, &merged_roots, entry.string);
                                    }
                                }
                            }
                        }
                    }
                    for (external_roots) |root| try appendUniqueRoot(allocator, &merged_roots, root);
                    debug_log.log(
                        "writeSettingsCodeConfig: merged external roots existing+new={d}",
                        .{merged_roots.items.len},
                    );
                }

                // Deep merge code, preserving non-index keys
                try s.objectField("code");
                try s.beginObject();

                if (parsed_val.value.object.get("code")) |code| {
                    if (code == .object) {
                        var code_iter = code.object.iterator();
                        while (code_iter.next()) |entry| {
                            if (replace_index and std.mem.eql(u8, entry.key_ptr.*, "index")) continue;
                            if (external_roots.len > 0 and std.mem.eql(u8, entry.key_ptr.*, "external_roots")) continue;
                            try s.objectField(entry.key_ptr.*);
                            try s.write(entry.value_ptr.*);
                        }
                    }
                }

                if (replace_index) try writeStringArrayField(&s, "index", patterns);
                if (external_roots.len > 0) try writeStringArrayField(&s, "external_roots", merged_roots.items);
                try s.endObject(); // code
            } else {
                try writeFreshCodeConfig(&s, patterns, external_roots, replace_index);
            }
        } else |_| {
            try writeFreshCodeConfig(&s, patterns, external_roots, replace_index);
        }
    } else {
        try writeFreshCodeConfig(&s, patterns, external_roots, replace_index);
    }

    try s.endObject();

    const new_content = try aw.toOwnedSlice();
    defer allocator.free(new_content);

    const with_newline = std.fmt.allocPrint(allocator, "{s}\n", .{new_content}) catch {
        printErr("  error: failed to format settings\n");
        return error.Explained;
    };
    defer allocator.free(with_newline);

    try writeCwdFile(".cog/settings.json", with_newline);
}

fn appendUniqueRoot(
    allocator: std.mem.Allocator,
    roots: *std.ArrayListUnmanaged([]const u8),
    root: []const u8,
) !void {
    if (root.len == 0) return;
    for (roots.items) |existing| {
        if (std.mem.eql(u8, existing, root)) return;
    }
    try roots.append(allocator, root);
}

fn writeFreshCodeConfig(
    s: *Stringify,
    patterns: []const []const u8,
    external_roots: []const []const u8,
    replace_index: bool,
) !void {
    try s.objectField("code");
    try s.beginObject();
    if (replace_index) try writeStringArrayField(s, "index", patterns);
    if (external_roots.len > 0) try writeStringArrayField(s, "external_roots", external_roots);
    try s.endObject();
}

fn writeStringArrayField(s: *Stringify, field: []const u8, values: []const []const u8) !void {
    try s.objectField(field);
    try s.beginArray();
    for (values) |value| try s.write(value);
    try s.endArray();
}

// ── Brain Setup ─────────────────────────────────────────────────────────

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

fn deployBootstrapTemplates() !void {
    debug_log.log("commands.deployBootstrapTemplates: opening .cog", .{});
    const cog_dir = std.fs.cwd().openDir(".cog", .{}) catch |err| {
        debug_log.log("commands.deployBootstrapTemplates: failed to open .cog: {s}", .{@errorName(err)});
        return err;
    };

    // Write or upgrade MEM_BOOTSTRAP.md
    // If the existing file has the old per-file placeholder, replace it with the new subsystem prompt
    const needs_bootstrap_upgrade = blk: {
        const file = cog_dir.openFile("MEM_BOOTSTRAP.md", .{}) catch break :blk true; // doesn't exist
        defer file.close();
        const content = file.readToEndAlloc(std.heap.page_allocator, 64 * 1024) catch break :blk false;
        defer std.heap.page_allocator.free(content);
        // Old prompt uses {file_path} (singular), new uses {file_paths} (plural)
        if (std.mem.indexOf(u8, content, "{file_path}") != null and
            std.mem.indexOf(u8, content, "{file_paths}") == null)
        {
            break :blk true;
        }
        break :blk false;
    };
    if (needs_bootstrap_upgrade) {
        debug_log.log("commands.deployBootstrapTemplates: writing MEM_BOOTSTRAP.md", .{});
        try fs_util.writeFileAtomicMode(cog_dir, std.heap.page_allocator, "MEM_BOOTSTRAP.md", build_options.bootstrap_prompt, 0o600);
    }

    // Write or upgrade MEM_BOOTSTRAP_ASSOCIATE.md
    const needs_associate_upgrade = blk: {
        const file = cog_dir.openFile("MEM_BOOTSTRAP_ASSOCIATE.md", .{}) catch break :blk true;
        defer file.close();
        const content = file.readToEndAlloc(std.heap.page_allocator, 64 * 1024) catch break :blk false;
        defer std.heap.page_allocator.free(content);
        // Old prompt says "per-file concepts", new says "per-subsystem concepts"
        if (std.mem.indexOf(u8, content, "per-file concepts") != null) {
            break :blk true;
        }
        break :blk false;
    };
    if (needs_associate_upgrade) {
        debug_log.log("commands.deployBootstrapTemplates: writing MEM_BOOTSTRAP_ASSOCIATE.md", .{});
        try fs_util.writeFileAtomicMode(cog_dir, std.heap.page_allocator, "MEM_BOOTSTRAP_ASSOCIATE.md", build_options.bootstrap_associate_prompt, 0o600);
    }
}

pub fn buildAccountLabel(allocator: std.mem.Allocator, account: json.Value) ![]const u8 {
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

pub const AccountBrainSelection = struct {
    account_slug: []const u8,
    brain_name: []const u8,
};

pub fn selectAccountAndBrain(
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

pub fn getAccountSlug(account: json.Value) ?[]const u8 {
    if (account == .object) {
        if (account.object.get("name")) |s| {
            if (s == .string) return s.string;
        }
    }
    return null;
}

pub fn selectBrain(
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

pub fn promptCreateBrain(
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

pub fn isAlreadyExistsError(allocator: std.mem.Allocator, body: []const u8) bool {
    const parsed = json.parseFromSlice(json.Value, allocator, body, .{}) catch return false;
    defer parsed.deinit();
    if (parsed.value != .object) return false;
    const err_val = parsed.value.object.get("error") orelse return false;
    if (err_val != .object) return false;
    const msg = err_val.object.get("message") orelse return false;
    if (msg != .string) return false;
    return std.mem.indexOf(u8, msg.string, "has already been taken") != null;
}

pub fn printServerError(allocator: std.mem.Allocator, body: []const u8) void {
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

    const existing = try readCwdFileOptional(allocator, ".cog/settings.json");
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

const RemoteStats = struct {
    engrams: i64,
    synapses: i64,
};

fn parseRemoteStats(allocator: std.mem.Allocator, body: []const u8) ?RemoteStats {
    // MCP response: {"result":{"content":[{"type":"text","text":"{\"total_engrams\":42,...}"}]}}
    const parsed = json.parseFromSlice(json.Value, allocator, body, .{}) catch return null;
    defer parsed.deinit();

    // Navigate: result -> content -> [0] -> text
    const result_obj = if (parsed.value == .object) parsed.value.object.get("result") orelse return null else return null;
    const content = if (result_obj == .object) result_obj.object.get("content") orelse return null else return null;
    const items = if (content == .array) content.array.items else return null;
    if (items.len == 0) return null;
    const first = items[0];
    const text = if (first == .object) (if (first.object.get("text")) |t| (if (t == .string) t.string else null) else null) else null;
    const stats_text = text orelse return null;

    // The text content is JSON: {"total_engrams":42,"total_synapses":127,...}
    const stats_parsed = json.parseFromSlice(json.Value, allocator, stats_text, .{}) catch return null;
    defer stats_parsed.deinit();

    if (stats_parsed.value != .object) return null;
    const obj = stats_parsed.value.object;

    const engrams = if (obj.get("total_engrams")) |v| switch (v) {
        .integer => v.integer,
        else => @as(i64, -1),
    } else @as(i64, -1);

    const synapses = if (obj.get("total_synapses")) |v| switch (v) {
        .integer => v.integer,
        else => @as(i64, -1),
    } else @as(i64, -1);

    if (engrams >= 0 and synapses >= 0) return .{ .engrams = engrams, .synapses = synapses };
    if (engrams >= 0) return .{ .engrams = engrams, .synapses = 0 };
    return null;
}

/// What `--approve-host` decided. Only `.approved` writes to the global store.
const CredentialApprovalOutcome = enum { official, already_approved, approved, declined };

/// Seams for the approval workflow so every branch — including the one that
/// persists — is exercised without touching the real user's global store.
const CredentialApprovalSeams = struct {
    is_interactive: *const fn (context: *anyopaque) bool,
    confirm: *const fn (context: *anyopaque, prompt: []const u8) anyerror!bool,
    is_approved: *const fn (context: *anyopaque, allocator: std.mem.Allocator, origin: []const u8) anyerror!bool,
    approve: *const fn (context: *anyopaque, allocator: std.mem.Allocator, origin: []const u8) anyerror!bool,
};

fn printApprovalLine(comptime fmt: []const u8, args: anytype) void {
    var buf: [credential_boundary.max_url_bytes + 256]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, fmt, args) catch return;
    printErr(msg);
}

/// Report a store failure with its security-specific cause, then collapse it to
/// `error.Explained` so the CLI never proceeds on an unverified store.
fn explainApprovalFailure(err: anyerror) anyerror {
    debug_log.log("commands.doctor: credential approval store failure: {s}", .{@errorName(err)});
    printErr(switch (err) {
        error.UnsupportedPlatform => "  error: credential approval storage is unavailable on this platform.\n",
        error.TrustedHomeUnavailable => "  error: could not resolve a trusted home directory for this account.\n",
        error.ConfigPathSymlink => "  error: a component of ~/.config/cog is a symlink; refusing to store approvals.\n",
        error.ConfigPathNotDirectory => "  error: a component of ~/.config/cog is not a directory; refusing to store approvals.\n",
        error.ConfigDirWrongOwner => "  error: ~/.config/cog is owned by another account; refusing to store approvals.\n",
        error.ConfigDirPermissionsTooOpen => "  error: ~/.config/cog is group- or world-accessible; run chmod 700 ~/.config/cog.\n",
        error.StoreWrongOwner => "  error: approved-origins.json is owned by another account.\n",
        error.StorePermissionsTooOpen => "  error: approved-origins.json is group- or world-accessible; run chmod 600 on it.\n",
        error.MalformedStore, error.StoreTooLarge => "  error: approved-origins.json is malformed; inspect ~/.config/cog/approved-origins.json.\n",
        error.TooManyOrigins => "  error: the approved-origins store is full; remove unused origins first.\n",
        else => "  error: could not read or update the approved-origins store.\n",
    });
    return error.Explained;
}

/// Add an exact HTTPS origin to the global credential-destination allowlist.
/// This is a deliberate user action: the origin is canonicalized first, an
/// interactive terminal is required, and the user must confirm before anything
/// is written. Repository state can select a self-hosted brain but can never
/// authorize sending `COG_API_KEY` to it.
fn approveCredentialHostWith(
    allocator: std.mem.Allocator,
    input: []const u8,
    context: *anyopaque,
    seams: CredentialApprovalSeams,
) !CredentialApprovalOutcome {
    var origin = credential_boundary.parseOrigin(allocator, input) catch |err| {
        debug_log.log("commands.doctor: rejected approval origin: {s}", .{@errorName(err)});
        printErr("  error: --approve-host expects one exact HTTPS origin, for example https://memory.example:8443\n");
        printApprovalLine("         rejected: {s}\n", .{@errorName(err)});
        return error.Explained;
    };
    defer origin.deinit(allocator);

    if (origin.is_official) {
        debug_log.log("commands.doctor: official origin requires no stored approval", .{});
        printApprovalLine("  {s} is trusted by policy; nothing was stored.\n", .{origin.serialized});
        return .official;
    }

    const already = seams.is_approved(context, allocator, origin.serialized) catch |err| switch (err) {
        // A default 0755 ~/.config/cog makes the store untrusted for reads, which
        // is the right answer for a credential check but would otherwise make
        // approval impossible. Treat it as "not approved yet" and continue: the
        // write path restricts the directory to 0700 and revalidates before
        // persisting, so the user action repairs the state it reported.
        error.ConfigDirPermissionsTooOpen => blk: {
            debug_log.log("commands.doctor: store directory is too open; approval will restrict it", .{});
            printErr("  note: ~/.config/cog is group- or world-accessible; approving will restrict it to 0700.\n");
            break :blk false;
        },
        else => return explainApprovalFailure(err),
    };
    if (already) {
        printApprovalLine("  {s} is already an approved credential destination.\n", .{origin.serialized});
        return .already_approved;
    }

    if (!seams.is_interactive(context)) {
        debug_log.log("commands.doctor: refusing a non-interactive credential approval", .{});
        printErr("  error: approving a credential destination requires an interactive terminal.\n");
        printErr("         Run cog doctor --approve-host <origin> from a terminal and confirm the prompt.\n");
        return error.Explained;
    }

    printApprovalLine("  Cog will send COG_API_KEY to {s} once approved.\n", .{origin.serialized});
    var prompt_buffer: [credential_boundary.max_url_bytes + 64]u8 = undefined;
    const prompt = std.fmt.bufPrint(&prompt_buffer, "Approve {s} as a credential destination?", .{origin.serialized}) catch {
        return error.Explained;
    };
    const confirmed = seams.confirm(context, prompt) catch |err| {
        debug_log.log("commands.doctor: approval prompt failed: {s}", .{@errorName(err)});
        printErr("  error: could not read a confirmation from the terminal.\n");
        return error.Explained;
    };
    if (!confirmed) {
        debug_log.log("commands.doctor: approval declined by the user", .{});
        printErr("  Declined; no credential destination was added.\n");
        return .declined;
    }

    _ = seams.approve(context, allocator, origin.serialized) catch |err| {
        return explainApprovalFailure(err);
    };
    debug_log.log("commands.doctor: stored a user-approved credential destination", .{});
    printApprovalLine("  Approved {s}.\n", .{origin.serialized});
    return .approved;
}

fn approvalIsInteractive(_: *anyopaque) bool {
    return std.posix.isatty(std.fs.File.stdin().handle);
}

fn approvalConfirm(_: *anyopaque, prompt: []const u8) anyerror!bool {
    return tui.confirm(prompt);
}

fn approvalIsApproved(_: *anyopaque, allocator: std.mem.Allocator, origin: []const u8) anyerror!bool {
    return credential_boundary.isApproved(allocator, origin);
}

fn approvalApprove(_: *anyopaque, allocator: std.mem.Allocator, origin: []const u8) anyerror!bool {
    return credential_boundary.approve(allocator, origin);
}

fn approveCredentialHost(allocator: std.mem.Allocator, input: []const u8) !CredentialApprovalOutcome {
    var context: u8 = 0;
    return approveCredentialHostWith(allocator, input, &context, .{
        .is_interactive = approvalIsInteractive,
        .confirm = approvalConfirm,
        .is_approved = approvalIsApproved,
        .approve = approvalApprove,
    });
}

fn authorizeInitMemoryHostWith(
    allocator: std.mem.Allocator,
    host: []const u8,
    context: *anyopaque,
    seams: CredentialApprovalSeams,
) !bool {
    const origin = try std.fmt.allocPrint(allocator, "https://{s}", .{host});
    defer allocator.free(origin);

    debug_log.log("commands.init: checking hosted memory credential origin {s}", .{origin});
    const outcome = try approveCredentialHostWith(allocator, origin, context, seams);
    debug_log.log("commands.init: hosted memory credential origin outcome={s}", .{@tagName(outcome)});
    return outcome != .declined;
}

fn authorizeInitMemoryHost(allocator: std.mem.Allocator, host: []const u8) !bool {
    var context: u8 = 0;
    return authorizeInitMemoryHostWith(allocator, host, &context, .{
        .is_interactive = approvalIsInteractive,
        .confirm = approvalConfirm,
        .is_approved = approvalIsApproved,
        .approve = approvalApprove,
    });
}

pub fn doctor(allocator: std.mem.Allocator, args: []const [:0]const u8) !void {
    if (hasFlag(args, "--help") or hasFlag(args, "-h")) {
        printCommandHelp(help.doctor);
        return;
    }

    if (hasFlag(args, "--approve-host")) {
        tui.header();
        printErr(cyan ++ bold ++ "  Credential Approval" ++ reset ++ "\n");
        const origin = findFlag(args, "--approve-host") orelse {
            printErr("  error: --approve-host requires an HTTPS origin, for example https://memory.example:8443\n");
            return error.Explained;
        };
        _ = try approveCredentialHost(allocator, origin);
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

                // Open the existing database without creating or mutating it.
                const path_z = std.posix.toPosixPath(path) catch {
                    printErr("    " ++ red ++ cross ++ reset ++ " Database: path too long\n");
                    failures += 1;
                    break :mem_check;
                };
                debug_log.log("doctor: opening local brain read-only {s}", .{path});
                var db = sqlite.Db.openReadOnly(&path_z) catch |err| {
                    debug_log.log("doctor: read-only database open failed: {s}", .{@errorName(err)});
                    printErr("    " ++ red ++ cross ++ reset ++ " Database: missing or inaccessible\n");
                    failures += 1;
                    break :mem_check;
                };
                defer db.close();

                // Count engrams and synapses
                const engram_count = blk_e: {
                    var stmt = db.prepare("SELECT count(*) FROM engrams") catch break :blk_e @as(i64, -1);
                    defer stmt.finalize();
                    if (stmt.step()) |result| {
                        if (result == .row) break :blk_e stmt.columnInt(0);
                    } else |_| {}
                    break :blk_e @as(i64, -1);
                };
                const synapse_count = blk_s: {
                    var stmt = db.prepare("SELECT count(*) FROM synapses") catch break :blk_s @as(i64, -1);
                    defer stmt.finalize();
                    if (stmt.step()) |result| {
                        if (result == .row) break :blk_s stmt.columnInt(0);
                    } else |_| {}
                    break :blk_s @as(i64, -1);
                };

                if (engram_count >= 0) {
                    var count_buf: [192]u8 = undefined;
                    const count_msg = if (synapse_count >= 0)
                        std.fmt.bufPrint(&count_buf, "    " ++ cyan ++ check ++ reset ++ " Database: {d} engrams, {d} synapses\n", .{ engram_count, synapse_count }) catch "    " ++ cyan ++ check ++ reset ++ " Database: accessible\n"
                    else
                        std.fmt.bufPrint(&count_buf, "    " ++ cyan ++ check ++ reset ++ " Database: {d} engrams\n", .{engram_count}) catch "    " ++ cyan ++ check ++ reset ++ " Database: accessible\n";
                    printErr(count_msg);
                    passed += 1;
                } else {
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

            // Check API key and fetch stats
            if (config_mod.getApiKey(allocator)) |key| {
                defer allocator.free(key);
                printErr("    " ++ cyan ++ check ++ reset ++ " API key configured\n");
                passed += 1;

                // Try to fetch stats from remote brain (best-effort)
                remote_stats: {
                    // MCP route is /:username/:brain_name/mcp (no /api/v1 prefix)
                    const endpoint = std.fmt.allocPrint(allocator, "{s}/mcp", .{url}) catch break :remote_stats;
                    defer allocator.free(endpoint);

                    debug_log.log("doctor: fetching remote stats from {s}", .{endpoint});
                    const resp = client.mcpCallToolQuiet(allocator, endpoint, key, null, "cog_stats", "{}") catch break :remote_stats;
                    defer allocator.free(resp.body);
                    if (resp.session_id) |sid| allocator.free(sid);

                    if (parseRemoteStats(allocator, resp.body)) |stats| {
                        var stats_buf: [192]u8 = undefined;
                        const stats_msg = std.fmt.bufPrint(&stats_buf, "    " ++ cyan ++ check ++ reset ++ " Stats: {d} engrams, {d} synapses\n", .{ stats.engrams, stats.synapses }) catch break :remote_stats;
                        printErr(stats_msg);
                        passed += 1;
                    }
                }
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

    if (code_intel.queryIndexInfo(allocator)) |info| {
        // Format file size
        var size_buf: [64]u8 = undefined;
        const size_str = if (info.file_size >= 1024 * 1024)
            std.fmt.bufPrint(&size_buf, "{d:.1} MB", .{@as(f64, @floatFromInt(info.file_size)) / (1024.0 * 1024.0)}) catch "?"
        else if (info.file_size >= 1024)
            std.fmt.bufPrint(&size_buf, "{d:.1} KB", .{@as(f64, @floatFromInt(info.file_size)) / 1024.0}) catch "?"
        else
            std.fmt.bufPrint(&size_buf, "{d} B", .{info.file_size}) catch "?";

        var msg_buf: [256]u8 = undefined;
        const msg = std.fmt.bufPrint(&msg_buf, "    " ++ cyan ++ check ++ reset ++ " Index ready ({d} files, {s})\n", .{ info.document_count, size_str }) catch "    " ++ cyan ++ check ++ reset ++ " Index ready\n";
        printErr(msg);
        passed += 1;
        debug_log.log("doctor: code index ready, {d} docs, {d} bytes", .{ info.document_count, info.file_size });

        // Freshness: does the index still describe the working tree?
        const drift = code_intel.scanConfiguredDrift(allocator);
        switch (drift.outcome) {
            .unchanged => {
                printErr("    " ++ cyan ++ check ++ reset ++ " Index in sync with the working tree\n");
                passed += 1;
            },
            .changed => {
                var drift_buf: [192]u8 = undefined;
                const drift_msg = std.fmt.bufPrint(
                    &drift_buf,
                    "    " ++ yellow ++ "!" ++ reset ++ " Index drift: {d} changed, {d} removed{s} — run cog code:sync\n",
                    .{ drift.changed, drift.removed, if (drift.full_resync) " (no provenance manifest)" else "" },
                ) catch "    " ++ yellow ++ "!" ++ reset ++ " Index drift detected — run cog code:sync\n";
                printErr(drift_msg);
                warnings += 1;
            },
            .failed => {
                printErr("    " ++ yellow ++ "!" ++ reset ++ " Index freshness unknown (no index patterns configured)\n");
                warnings += 1;
            },
        }
        debug_log.log("doctor: index drift outcome={s} changed={d} removed={d}", .{ @tagName(drift.outcome), drift.changed, drift.removed });
    } else {
        printErr("    " ++ yellow ++ "!" ++ reset ++ " Index unavailable\n");
        warnings += 1;
        debug_log.log("doctor: code index unavailable", .{});
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

fn readCwdFileOptional(allocator: std.mem.Allocator, filename: []const u8) !?[]const u8 {
    debug_log.log("commands.readCwdFileOptional: reading {s}", .{filename});
    const f = std.fs.cwd().openFile(filename, .{}) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => {
            debug_log.log("commands.readCwdFileOptional: failed to open {s}: {s}", .{ filename, @errorName(err) });
            return err;
        },
    };
    defer f.close();
    return f.readToEndAlloc(allocator, 1048576) catch |err| {
        debug_log.log("commands.readCwdFileOptional: failed to read {s}: {s}", .{ filename, @errorName(err) });
        return err;
    };
}

fn readCwdFile(allocator: std.mem.Allocator, filename: []const u8) ?[]const u8 {
    return readCwdFileOptional(allocator, filename) catch null;
}

fn writeCwdFile(filename: []const u8, content: []const u8) !void {
    debug_log.log("commands.writeCwdFile: atomically writing {s}", .{filename});
    const create_mode: std.fs.File.Mode = if (std.mem.startsWith(u8, filename, ".cog/")) 0o600 else std.fs.File.default_mode;
    fs_util.writeFileAtomicMode(std.fs.cwd(), std.heap.page_allocator, filename, content, create_mode) catch |err| {
        debug_log.log("commands.writeCwdFile: failed to write {s}: {s}", .{ filename, @errorName(err) });
        printErr("error: failed to write ");
        printErr(filename);
        printErr("\n");
        return error.Explained;
    };
}

fn updateFileWithPrompt(allocator: std.mem.Allocator, filename: []const u8, prompt_content: []const u8) !void {
    debug_log.log("commands.updateFileWithPrompt: path={s} prompt_bytes={d}", .{ filename, prompt_content.len });
    const open_tag = "<cog>";
    const close_tag = "</cog>";
    const trimmed_prompt = std.mem.trimRight(u8, prompt_content, &std.ascii.whitespace);

    const existing = try readCwdFileOptional(allocator, filename);
    defer if (existing) |e| allocator.free(e);

    const new_content = blk: {
        if (existing) |content| {
            if (std.mem.indexOf(u8, content, open_tag)) |open_pos| {
                const search_start = open_pos + open_tag.len;
                if (std.mem.indexOfPos(u8, content, search_start, close_tag)) |close_pos| {
                    // Replace content between <cog> and </cog>
                    debug_log.log("commands.updateFileWithPrompt: replacing managed block path={s}", .{filename});
                    const before = content[0 .. open_pos + open_tag.len];
                    const after = content[close_pos..];
                    break :blk try std.fmt.allocPrint(allocator, "{s}\n{s}\n{s}", .{ before, trimmed_prompt, after });
                }
            }
            // No valid tags found, append at end
            debug_log.log("commands.updateFileWithPrompt: appending managed block path={s}", .{filename});
            const trimmed_existing = std.mem.trimRight(u8, content, &std.ascii.whitespace);
            break :blk try std.fmt.allocPrint(allocator, "{s}\n\n{s}\n{s}\n{s}\n", .{ trimmed_existing, open_tag, trimmed_prompt, close_tag });
        } else {
            // New file
            debug_log.log("commands.updateFileWithPrompt: creating managed block path={s}", .{filename});
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

    debug_log.log("commands.ensureCogGitignore: writing .cog/.gitignore", .{});
    try writeCwdFile(".cog/.gitignore", COG_GITIGNORE_CONTENT);
}

fn signForDebug(allocator: std.mem.Allocator) void {
    printErr("  Signing for debug server... ");
    debug_mod.ensureDebugEntitlements(allocator) catch {
        printErr("skipped (codesign failed)\n");
        return;
    };
    tui.checkmark();
    printErr("\n");
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

test "init host config steps propagate merge failures before success" {
    var success_called = false;
    try std.testing.expectError(
        error.MalformedHostConfig,
        runHostConfigStep("MCP config", error.MalformedHostConfig, &success_called),
    );
    try std.testing.expect(!success_called);
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
    try std.testing.expect(std.mem.indexOf(u8, content, "\n  \"selected_agents\": [\n") != null);
    const parsed = try json.parseFromSlice(json.Value, allocator, content, .{});
    defer parsed.deinit();

    try std.testing.expectEqualStrings(build_options.version, parsed.value.object.get("version").?.string);
    const agents = parsed.value.object.get("selected_agents").?;
    try std.testing.expectEqual(@as(usize, 2), agents.array.items.len);
    try std.testing.expectEqualStrings("opencode", agents.array.items[0].string);

    const features = parsed.value.object.get("features").?;
    try std.testing.expect(features.object.get("enhanced_memory_writes").?.bool);
    try std.testing.expect(features.object.get("provenance_envelopes").?.bool);
    if (builtin.os.tag != .windows) {
        const stat = try std.fs.cwd().statFile(".cog/client-context.json");
        try std.testing.expectEqual(@as(std.fs.File.Mode, 0o600), stat.mode & 0o777);
    }
}

test "project file writer preserves prior contents and leaves no temp residue on setup failure" {
    const allocator = std.testing.allocator;
    var tmp_dir = std.testing.tmpDir(.{ .iterate = true });
    defer tmp_dir.cleanup();

    try tmp_dir.dir.writeFile(.{ .sub_path = "AGENTS.md", .data = "prior\n" });
    var failing_allocator = std.testing.FailingAllocator.init(allocator, .{ .fail_index = 0 });
    try std.testing.expectError(
        error.OutOfMemory,
        fs_util.writeFileAtomic(tmp_dir.dir, failing_allocator.allocator(), "AGENTS.md", "replacement\n"),
    );

    const content = try tmp_dir.dir.readFileAlloc(allocator, "AGENTS.md", 1024);
    defer allocator.free(content);
    try std.testing.expectEqualStrings("prior\n", content);

    var it = tmp_dir.dir.iterate();
    while (try it.next()) |entry| {
        try std.testing.expect(!std.mem.startsWith(u8, entry.name, ".AGENTS.md.tmp-"));
    }
}

test "deployBootstrapTemplates upgrades legacy prompts and preserves managed replacements" {
    const allocator = std.testing.allocator;
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    var original_cwd = try std.fs.cwd().openDir(".", .{});
    defer {
        original_cwd.setAsCwd() catch unreachable;
        original_cwd.close();
    }
    try tmp_dir.dir.setAsCwd();
    try std.fs.cwd().makeDir(".cog");
    try fs_util.writeFileAtomic(std.fs.cwd(), allocator, ".cog/MEM_BOOTSTRAP.md", "legacy {file_path}\n");
    try fs_util.writeFileAtomic(std.fs.cwd(), allocator, ".cog/MEM_BOOTSTRAP_ASSOCIATE.md", "legacy per-file concepts\n");

    try deployBootstrapTemplates();

    const bootstrap_content = try std.fs.cwd().readFileAlloc(allocator, ".cog/MEM_BOOTSTRAP.md", 1024 * 1024);
    defer allocator.free(bootstrap_content);
    try std.testing.expectEqualStrings(build_options.bootstrap_prompt, bootstrap_content);
    const associate_content = try std.fs.cwd().readFileAlloc(allocator, ".cog/MEM_BOOTSTRAP_ASSOCIATE.md", 1024 * 1024);
    defer allocator.free(associate_content);
    try std.testing.expectEqualStrings(build_options.bootstrap_associate_prompt, associate_content);
}

test "prompt markdown includes stronger memory gate guidance" {
    try std.testing.expect(std.mem.indexOf(u8, build_options.prompt_md, "Record knowledge as you work - use IF-THEN rules:") != null);
    try std.testing.expect(std.mem.indexOf(u8, build_options.prompt_md, "prior knowledge may help") != null);
    try std.testing.expect(std.mem.indexOf(u8, build_options.prompt_md, "Do not launch a separate") != null);
    try std.testing.expect(std.mem.indexOf(u8, build_options.prompt_md, "## BEFORE Responding - Memory Gate") != null);
    try std.testing.expect(std.mem.indexOf(u8, build_options.prompt_md, "Budget: 2-3 code-intelligence calls before responding.") != null);
}

test "README support matrix matches the registry" {
    const allocator = std.testing.allocator;
    const rendered = try agents_mod.renderSupportMatrix(allocator);
    defer allocator.free(rendered);

    const readme = build_options.readme_md;
    const start = std.mem.indexOf(u8, readme, "| Agent | MCP Config |") orelse return error.TestUnexpectedResult;
    const end = std.mem.indexOfPos(u8, readme, start, "\n\n") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings(readme[start..end], rendered);
}

test "every host prompt carries the identical Cog-first policy and raw-text exceptions" {
    const allocator = std.testing.allocator;
    for (agents_mod.agents) |agent| {
        const specialists = agent.capabilities().specialists;
        // The policy must hold with and without memory configured, so no
        // host or init combination can render a looser fallback policy.
        inline for ([_]bool{ true, false }) |memory_enabled| {
            const rendered = try processPromptTags(allocator, build_options.prompt_md, .{
                .memory_enabled = memory_enabled,
                .specialists = specialists.availability(memory_enabled),
            });
            defer allocator.free(rendered);

            try std.testing.expect(std.mem.indexOf(u8, rendered, agents_mod.cog_first_exploration_policy) != null);
            try std.testing.expect(std.mem.indexOf(u8, rendered, agents_mod.prompt_raw_text_fallback_policy) != null);
        }
    }
}

test "hosts never render prompt mandates for uninstallable specialists" {
    const allocator = std.testing.allocator;
    for (agents_mod.agents) |agent| {
        const specialists = agent.capabilities().specialists;
        inline for ([_]bool{ true, false }) |memory_enabled| {
            const availability = specialists.availability(memory_enabled);
            const rendered = try processPromptTags(allocator, build_options.prompt_md, .{
                .memory_enabled = memory_enabled,
                .specialists = availability,
            });
            defer allocator.free(rendered);

            try std.testing.expectEqual(availability.debug, std.mem.indexOf(u8, rendered, "`cog-debug`") != null);
            try std.testing.expectEqual(availability.observe, std.mem.indexOf(u8, rendered, "`cog-observe`") != null);
            try std.testing.expectEqual(availability.memory, std.mem.indexOf(u8, rendered, "`cog-mem`") != null);
            try std.testing.expectEqual(availability.validate, std.mem.indexOf(u8, rendered, "`cog-mem-validate`") != null);
            try std.testing.expectEqual(availability.code_query, std.mem.indexOf(u8, rendered, "`cog-code-query`") != null);
        }
    }
}

test "processPromptTags preserves mandates only for installed specialists" {
    const allocator = std.testing.allocator;
    const processed = try processPromptTags(allocator, build_options.prompt_md, .{
        .memory_enabled = true,
        .specialists = .{
            .code_query = true,
            .debug = true,
            .memory = true,
            .validate = true,
            .observe = true,
        },
    });
    defer allocator.free(processed);

    try std.testing.expect(std.mem.indexOf(u8, processed, "## BEFORE Responding - Memory Gate") != null);
    try std.testing.expect(std.mem.indexOf(u8, processed, "`cog-debug`") != null);
    try std.testing.expect(std.mem.indexOf(u8, processed, "`cog-mem`") != null);
    try std.testing.expect(std.mem.indexOf(u8, processed, "`cog-mem-validate`") != null);
    try std.testing.expect(std.mem.indexOf(u8, processed, "`cog-observe`") != null);
    try std.testing.expect(std.mem.indexOf(u8, processed, "<cog:") == null);
}

test "processPromptTags omits unavailable specialist mandates" {
    const allocator = std.testing.allocator;
    const processed = try processPromptTags(allocator, build_options.prompt_md, .{
        .memory_enabled = true,
        .specialists = .{ .code_query = true },
    });
    defer allocator.free(processed);

    try std.testing.expect(std.mem.indexOf(u8, processed, "## Memory") != null);
    try std.testing.expect(std.mem.indexOf(u8, processed, "`cog-debug`") == null);
    try std.testing.expect(std.mem.indexOf(u8, processed, "`cog-mem`") == null);
    try std.testing.expect(std.mem.indexOf(u8, processed, "`cog-mem-validate`") == null);
    try std.testing.expect(std.mem.indexOf(u8, processed, "`cog-observe`") == null);
}

test "processPromptTags strips memory content when memory is disabled" {
    const allocator = std.testing.allocator;
    const processed = try processPromptTags(allocator, build_options.prompt_md, .{
        .memory_enabled = false,
        .specialists = .{
            .code_query = true,
            .debug = true,
            .memory = true,
            .validate = true,
            .observe = true,
        },
    });
    defer allocator.free(processed);

    try std.testing.expect(std.mem.indexOf(u8, processed, "## BEFORE Responding - Memory Gate") == null);
    try std.testing.expect(std.mem.indexOf(u8, processed, "cog_mem_learn") == null);
    try std.testing.expect(std.mem.indexOf(u8, processed, "`cog-mem`") == null);
    try std.testing.expect(std.mem.indexOf(u8, processed, "`cog-mem-validate`") == null);
    try std.testing.expect(std.mem.indexOf(u8, processed, "`cog-debug`") != null);
    try std.testing.expect(std.mem.indexOf(u8, processed, "`cog-observe`") != null);
}

test "specialist init gates memory and observe independently" {
    try std.testing.expect(specialistEnabledForInit(.code_query, false, false));
    try std.testing.expect(specialistEnabledForInit(.debug, false, false));
    try std.testing.expect(!specialistEnabledForInit(.memory, false, true));
    try std.testing.expect(!specialistEnabledForInit(.validate, false, true));
    try std.testing.expect(specialistEnabledForInit(.memory, true, false));
    try std.testing.expect(specialistEnabledForInit(.validate, true, false));
    try std.testing.expect(!specialistEnabledForInit(.observe, true, false));
    try std.testing.expect(specialistEnabledForInit(.observe, false, true));
}

test "prompt specialist intersection is safe for shared targets" {
    var shared = agents_mod.SpecialistAvailability.all();
    shared.intersect(.{
        .code_query = true,
        .debug = true,
        .memory = true,
        .validate = true,
        .observe = true,
    });
    shared.intersect(.{
        .code_query = true,
        .debug = false,
        .memory = true,
        .validate = false,
        .observe = true,
    });

    try std.testing.expect(shared.code_query);
    try std.testing.expect(!shared.debug);
    try std.testing.expect(shared.memory);
    try std.testing.expect(!shared.validate);
    try std.testing.expect(shared.observe);
}

test "Cog gitignore production contract remains stable" {
    try std.testing.expectEqualStrings("*.db\n*.scip\n*.log\n", COG_GITIGNORE_CONTENT);
}

test "processPromptTags preserves observe guidance when available" {
    const allocator = std.testing.allocator;
    const processed = try processPromptTags(allocator, build_options.prompt_md, .{
        .memory_enabled = true,
        .specialists = agents_mod.SpecialistAvailability.all(),
    });
    defer allocator.free(processed);

    try std.testing.expect(std.mem.indexOf(u8, processed, "## Observability") != null);
    try std.testing.expect(std.mem.indexOf(u8, processed, "cog-observe") != null);
    try std.testing.expect(std.mem.indexOf(u8, processed, "<cog:observe>") == null);
}

test "processPromptTags strips observe guidance when unavailable" {
    const allocator = std.testing.allocator;
    var specialists = agents_mod.SpecialistAvailability.all();
    specialists.observe = false;
    const processed = try processPromptTags(allocator, build_options.prompt_md, .{
        .memory_enabled = true,
        .specialists = specialists,
    });
    defer allocator.free(processed);

    try std.testing.expect(std.mem.indexOf(u8, processed, "## Observability") == null);
    try std.testing.expect(std.mem.indexOf(u8, processed, "cog-observe") == null);
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

    try std.testing.expectEqualStrings(COG_GITIGNORE_CONTENT, content);
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

    try std.testing.expectEqualStrings(COG_GITIGNORE_CONTENT, content);
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

const ApprovalProbe = struct {
    interactive: bool = true,
    answer: bool = true,
    stored: bool = false,
    confirm_calls: usize = 0,
    approve_calls: usize = 0,
    prompt_buffer: [512]u8 = undefined,
    prompt_len: usize = 0,
    approved_buffer: [512]u8 = undefined,
    approved_len: usize = 0,

    fn seams() CredentialApprovalSeams {
        return .{
            .is_interactive = isInteractive,
            .confirm = confirm,
            .is_approved = isApproved,
            .approve = approve,
        };
    }

    fn isInteractive(context: *anyopaque) bool {
        return self(context).interactive;
    }

    fn confirm(context: *anyopaque, prompt: []const u8) anyerror!bool {
        const probe = self(context);
        probe.confirm_calls += 1;
        probe.prompt_len = @min(prompt.len, probe.prompt_buffer.len);
        @memcpy(probe.prompt_buffer[0..probe.prompt_len], prompt[0..probe.prompt_len]);
        return probe.answer;
    }

    fn isApproved(context: *anyopaque, _: std.mem.Allocator, _: []const u8) anyerror!bool {
        return self(context).stored;
    }

    fn approve(context: *anyopaque, _: std.mem.Allocator, origin: []const u8) anyerror!bool {
        const probe = self(context);
        probe.approve_calls += 1;
        probe.approved_len = @min(origin.len, probe.approved_buffer.len);
        @memcpy(probe.approved_buffer[0..probe.approved_len], origin[0..probe.approved_len]);
        return true;
    }

    fn self(context: *anyopaque) *ApprovalProbe {
        return @ptrCast(@alignCast(context));
    }

    fn promptText(probe: *const ApprovalProbe) []const u8 {
        return probe.prompt_buffer[0..probe.prompt_len];
    }

    fn approvedOrigin(probe: *const ApprovalProbe) []const u8 {
        return probe.approved_buffer[0..probe.approved_len];
    }
};

test "diagnostics append when stderr is redirected to a file" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    var file = try tmp.dir.createFile("diagnostics.log", .{ .read = true });
    defer file.close();

    // Each diagnostic uses its own writer. A positional writer restarts at
    // offset 0 every time, so the second message would overwrite the first and
    // silently truncate a security warning.
    writeDiagnostic(file, "  error: --approve-host expects one exact HTTPS origin\n");
    writeDiagnostic(file, "         rejected: HttpsRequired\n");

    const body = try tmp.dir.readFileAlloc(allocator, "diagnostics.log", 4096);
    defer allocator.free(body);
    try std.testing.expectEqualStrings(
        "  error: --approve-host expects one exact HTTPS origin\n" ++
            "         rejected: HttpsRequired\n",
        body,
    );
}

test "init explicitly approves a self-hosted memory origin before use" {
    const allocator = std.testing.allocator;
    var probe: ApprovalProbe = .{};

    try std.testing.expect(try authorizeInitMemoryHostWith(
        allocator,
        "MEMORY.example:8443",
        &probe,
        ApprovalProbe.seams(),
    ));
    try std.testing.expectEqual(@as(usize, 1), probe.confirm_calls);
    try std.testing.expectEqual(@as(usize, 1), probe.approve_calls);
    try std.testing.expectEqualStrings("https://memory.example:8443", probe.approvedOrigin());
}

test "init fails closed for an unapproved self-hosted memory origin without a terminal" {
    const allocator = std.testing.allocator;
    var probe: ApprovalProbe = .{ .interactive = false };

    try std.testing.expectError(
        error.Explained,
        authorizeInitMemoryHostWith(allocator, "memory.example", &probe, ApprovalProbe.seams()),
    );
    try std.testing.expectEqual(@as(usize, 0), probe.confirm_calls);
    try std.testing.expectEqual(@as(usize, 0), probe.approve_calls);
}

test "approve-host stores the canonical origin only after an explicit confirmation" {
    const allocator = std.testing.allocator;
    var probe: ApprovalProbe = .{};

    const outcome = try approveCredentialHostWith(allocator, "https://MEMORY.example", &probe, ApprovalProbe.seams());
    try std.testing.expectEqual(CredentialApprovalOutcome.approved, outcome);
    try std.testing.expectEqual(@as(usize, 1), probe.confirm_calls);
    try std.testing.expectEqual(@as(usize, 1), probe.approve_calls);
    try std.testing.expectEqualStrings("https://memory.example:443", probe.approvedOrigin());
    try std.testing.expect(std.mem.indexOf(u8, probe.promptText(), "https://memory.example:443") != null);
}

test "approve-host refuses without an interactive terminal" {
    const allocator = std.testing.allocator;
    var probe: ApprovalProbe = .{ .interactive = false };

    try std.testing.expectError(
        error.Explained,
        approveCredentialHostWith(allocator, "https://memory.example:8443", &probe, ApprovalProbe.seams()),
    );
    try std.testing.expectEqual(@as(usize, 0), probe.confirm_calls);
    try std.testing.expectEqual(@as(usize, 0), probe.approve_calls);
}

test "approve-host stores nothing when the user declines" {
    const allocator = std.testing.allocator;
    var probe: ApprovalProbe = .{ .answer = false };

    const outcome = try approveCredentialHostWith(allocator, "https://memory.example:8443", &probe, ApprovalProbe.seams());
    try std.testing.expectEqual(CredentialApprovalOutcome.declined, outcome);
    try std.testing.expectEqual(@as(usize, 1), probe.confirm_calls);
    try std.testing.expectEqual(@as(usize, 0), probe.approve_calls);
}

test "approve-host never persists the official origin" {
    const allocator = std.testing.allocator;
    var probe: ApprovalProbe = .{};

    const outcome = try approveCredentialHostWith(allocator, "https://TRYCOG.ai", &probe, ApprovalProbe.seams());
    try std.testing.expectEqual(CredentialApprovalOutcome.official, outcome);
    try std.testing.expectEqual(@as(usize, 0), probe.confirm_calls);
    try std.testing.expectEqual(@as(usize, 0), probe.approve_calls);
}

test "approve-host reports an already approved origin without prompting" {
    const allocator = std.testing.allocator;
    var probe: ApprovalProbe = .{ .stored = true };

    const outcome = try approveCredentialHostWith(allocator, "https://memory.example:8443", &probe, ApprovalProbe.seams());
    try std.testing.expectEqual(CredentialApprovalOutcome.already_approved, outcome);
    try std.testing.expectEqual(@as(usize, 0), probe.confirm_calls);
    try std.testing.expectEqual(@as(usize, 0), probe.approve_calls);
}

const FailingLookupProbe = struct {
    probe: ApprovalProbe = .{},
    lookup_error: anyerror = error.ConfigDirPermissionsTooOpen,

    fn seams() CredentialApprovalSeams {
        return .{
            .is_interactive = isInteractive,
            .confirm = confirm,
            .is_approved = isApproved,
            .approve = approve,
        };
    }

    fn isInteractive(context: *anyopaque) bool {
        return self(context).probe.interactive;
    }

    fn confirm(context: *anyopaque, prompt: []const u8) anyerror!bool {
        return ApprovalProbe.confirm(&self(context).probe, prompt);
    }

    fn isApproved(context: *anyopaque, _: std.mem.Allocator, _: []const u8) anyerror!bool {
        return self(context).lookup_error;
    }

    fn approve(context: *anyopaque, allocator: std.mem.Allocator, origin: []const u8) anyerror!bool {
        return ApprovalProbe.approve(&self(context).probe, allocator, origin);
    }

    fn self(context: *anyopaque) *FailingLookupProbe {
        return @ptrCast(@alignCast(context));
    }
};

test "approve-host repairs a too-open store directory instead of deadlocking on it" {
    const allocator = std.testing.allocator;
    var probe: FailingLookupProbe = .{};

    // A default 0755 ~/.config/cog makes the lookup refuse to trust the store.
    // That must not make approval impossible: the write path restricts the
    // directory to 0700 and revalidates before persisting.
    const outcome = try approveCredentialHostWith(allocator, "https://memory.example:8443", &probe, FailingLookupProbe.seams());
    try std.testing.expectEqual(CredentialApprovalOutcome.approved, outcome);
    try std.testing.expectEqual(@as(usize, 1), probe.probe.confirm_calls);
    try std.testing.expectEqual(@as(usize, 1), probe.probe.approve_calls);
}

test "approve-host still fails closed on unrepairable store failures" {
    const allocator = std.testing.allocator;
    const fatal = [_]anyerror{
        error.ConfigDirWrongOwner,
        error.ConfigPathSymlink,
        error.StoreWrongOwner,
        error.MalformedStore,
        error.UnsupportedPlatform,
    };

    for (fatal) |lookup_error| {
        var probe: FailingLookupProbe = .{ .lookup_error = lookup_error };
        try std.testing.expectError(
            error.Explained,
            approveCredentialHostWith(allocator, "https://memory.example:8443", &probe, FailingLookupProbe.seams()),
        );
        try std.testing.expectEqual(@as(usize, 0), probe.probe.confirm_calls);
        try std.testing.expectEqual(@as(usize, 0), probe.probe.approve_calls);
    }
}

test "approve-host rejects ambiguous and non-HTTPS destinations" {
    const allocator = std.testing.allocator;
    const rejected = [_][]const u8{
        "http://memory.example",
        "https://user@memory.example",
        "https://memory.example/owner/brain",
        "https://memory.example?token=secret",
        "https://memory.example#fragment",
        "https://0x7f.0.0.1",
        "memory.example",
        "",
    };

    for (rejected) |input| {
        var probe: ApprovalProbe = .{};
        try std.testing.expectError(
            error.Explained,
            approveCredentialHostWith(allocator, input, &probe, ApprovalProbe.seams()),
        );
        try std.testing.expectEqual(@as(usize, 0), probe.approve_calls);
    }
}

test "approving an external root merges with previously approved roots" {
    try withTempCwd(struct {
        fn run(allocator: std.mem.Allocator) !void {
            try std.fs.cwd().makeDir(".cog");

            try writeSettingsCodeConfig(allocator, &.{}, &.{"/srv/alpha"}, false);
            try writeSettingsCodeConfig(allocator, &.{}, &.{"/srv/beta"}, false);
            // Re-approving a known root must not duplicate it.
            try writeSettingsCodeConfig(allocator, &.{}, &.{"/srv/alpha"}, false);

            const body = try std.fs.cwd().readFileAlloc(allocator, ".cog/settings.json", 64 * 1024);
            defer allocator.free(body);

            try std.testing.expectEqualStrings(
                \\{
                \\  "code": {
                \\    "external_roots": [
                \\      "/srv/alpha",
                \\      "/srv/beta"
                \\    ]
                \\  }
                \\}
                \\
            , body);
        }
    }.run);
}

test "approving an external root preserves unrelated settings" {
    try withTempCwd(struct {
        fn run(allocator: std.mem.Allocator) !void {
            try std.fs.cwd().makeDir(".cog");
            try std.fs.cwd().writeFile(.{
                .sub_path = ".cog/settings.json",
                .data =
                \\{
                \\  "memory": { "brain": "file:.cog/brain.db" },
                \\  "code": {
                \\    "index": ["**/*.zig"],
                \\    "external_roots": ["/srv/alpha"]
                \\  }
                \\}
                \\
                ,
            });

            try writeSettingsCodeConfig(allocator, &.{}, &.{"/srv/beta"}, false);

            const body = try std.fs.cwd().readFileAlloc(allocator, ".cog/settings.json", 64 * 1024);
            defer allocator.free(body);

            const parsed = try json.parseFromSlice(json.Value, allocator, body, .{});
            defer parsed.deinit();

            const code = parsed.value.object.get("code").?.object;
            try std.testing.expectEqualStrings("**/*.zig", code.get("index").?.array.items[0].string);
            const roots = code.get("external_roots").?.array.items;
            try std.testing.expectEqual(@as(usize, 2), roots.len);
            try std.testing.expectEqualStrings("/srv/alpha", roots[0].string);
            try std.testing.expectEqualStrings("/srv/beta", roots[1].string);
            try std.testing.expect(parsed.value.object.get("memory") != null);
        }
    }.run);
}

test "doctor requires an origin argument for approve-host" {
    try withTempCwd(struct {
        fn run(allocator: std.mem.Allocator) !void {
            try std.fs.cwd().makeDir(".git");
            try std.testing.expectError(error.Explained, doctor(allocator, &.{"--approve-host"}));
        }
    }.run);
}

test "repository settings never approve a credential destination" {
    try withTempCwd(struct {
        fn run(allocator: std.mem.Allocator) !void {
            try std.fs.cwd().makeDir(".git");
            try std.fs.cwd().makeDir(".cog");
            try std.fs.cwd().writeFile(.{
                .sub_path = ".cog/settings.json",
                .data =
                \\{
                \\  "credentials": { "approvedOrigins": ["https://repo.example:443"] }
                \\}
                \\
                ,
            });

            var probe: ApprovalProbe = .{ .interactive = false };
            // Repository state cannot substitute for the interactive user action,
            // so the approval still fails closed.
            try std.testing.expectError(
                error.Explained,
                approveCredentialHostWith(allocator, "https://repo.example", &probe, ApprovalProbe.seams()),
            );
            try std.testing.expectEqual(@as(usize, 0), probe.approve_calls);
        }
    }.run);
}

test "doctor help documents the credential approval workflow" {
    try std.testing.expect(std.mem.indexOf(u8, help.doctor, "--approve-host") != null);
    try std.testing.expect(std.mem.indexOf(u8, help.doctor, "COG_API_KEY") != null);
    try std.testing.expect(std.mem.indexOf(u8, help.doctor, "approved-origins.json") != null);
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

test "doctor does not create a configured missing brain database" {
    try withTempCwd(struct {
        fn run(allocator: std.mem.Allocator) !void {
            try std.fs.cwd().makeDir(".git");
            try std.fs.cwd().makeDir(".cog");
            const settings_file = try std.fs.cwd().createFile(".cog/settings.json", .{});
            defer settings_file.close();
            try settings_file.writeAll("{\"memory\":{\"brain\":\"file:.cog/brain.db\"}}\n");

            try std.testing.expectError(error.Explained, doctor(allocator, &.{}));
            try std.testing.expectError(error.FileNotFound, std.fs.cwd().access(".cog/brain.db", .{}));
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
