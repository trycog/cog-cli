const std = @import("std");
const build_options = @import("build_options");
const commands = @import("cog").commands;
const code_intel = @import("cog").code_intel;
const extensions_mod = @import("cog").extensions;
const debug_mod = @import("cog").debug;
const observe_mod = @import("cog").observe;
const debug_log = @import("cog").debug_log;
const settings_mod = @import("cog").settings;
const tui = @import("cog").tui;
const help = @import("cog").help_text;

const version = build_options.version;

// ANSI styles
const cyan = "\x1B[36m";
const bold = "\x1B[1m";
const dim = "\x1B[2m";
const reset = "\x1B[0m";

const ExtInstallOptions = struct {
    git_url: []const u8,
    version: ?[]const u8 = null,
    trust_build: bool = false,
};

const ExtUpdateOptions = struct {
    name: ?[]const u8 = null,
    trust_build: bool = false,
};

const CommandEntry = struct {
    name: []const u8,
    summary: []const u8,
};

const top_level_commands = [_]CommandEntry{
    .{ .name = "init", .summary = "Interactive setup for the current directory" },
    .{ .name = "doctor", .summary = "Validate installation and configuration" },
    .{ .name = "code", .summary = "Code indexing (CLI compatibility)" },
    .{ .name = "mcp", .summary = "MCP server over stdio (primary interface)" },
    .{ .name = "debug", .summary = "Debug daemon utilities" },
    .{ .name = "mem", .summary = "Memory utilities" },
    .{ .name = "ext", .summary = "Extension utilities" },
};

const observe_top_level_command = CommandEntry{ .name = "observe", .summary = "Experimental observation session utilities" };

const top_level_help_aliases = [_][]const u8{ "--help", "-h", "help" };
const top_level_version_aliases = [_][]const u8{ "--version", "-v" };
const legacy_top_level_commands = [_][]const u8{"install"};

const code_commands = [_]CommandEntry{
    .{ .name = "code:index", .summary = "Build SCIP code index (per-file incremental)" },
    .{ .name = "code:sync", .summary = "Reconcile the index with the working tree" },
};

const debug_commands = [_]CommandEntry{
    .{ .name = "debug:serve", .summary = "Start the debug daemon" },
    .{ .name = "debug:dashboard", .summary = "Live debug session dashboard" },
    .{ .name = "debug:status", .summary = "Check daemon status and active sessions" },
    .{ .name = "debug:kill", .summary = "Stop the debug daemon" },
    .{ .name = "debug:sign", .summary = "Code-sign binary with debug entitlements (macOS)" },
};

const observe_commands = [_]CommandEntry{
    .{ .name = "observe:status", .summary = "Show the CLI placeholder status" },
    .{ .name = "observe:sessions", .summary = "Show the CLI placeholder session list" },
    .{ .name = "observe:query", .summary = "Show the CLI placeholder query status" },
    .{ .name = "observe:export", .summary = "Show the CLI placeholder export status" },
    .{ .name = "observe:prune", .summary = "Delete expired finalized observation sessions" },
};

const memory_commands = [_]CommandEntry{
    .{ .name = "mem:bootstrap", .summary = "Scan project files and populate memory" },
    .{ .name = "mem:info", .summary = "Show brain type, path, and memory stats" },
    .{ .name = "mem:upgrade", .summary = "Migrate local brain to hosted memory on trycog.ai" },
};

const extension_commands = [_]CommandEntry{
    .{ .name = "ext:install", .summary = "Install a language extension from GitHub releases" },
    .{ .name = "ext:update", .summary = "Update installed extensions to latest releases" },
};

fn containsCommand(entries: []const CommandEntry, name: []const u8) bool {
    for (entries) |entry| {
        if (std.mem.eql(u8, entry.name, name)) return true;
    }
    return false;
}

fn containsName(names: []const []const u8, name: []const u8) bool {
    for (names) |candidate| {
        if (std.mem.eql(u8, candidate, name)) return true;
    }
    return false;
}

fn isTopLevelCommand(name: []const u8, observe_enabled: bool) bool {
    return containsCommand(&top_level_commands, name) or (observe_enabled and std.mem.eql(u8, name, observe_top_level_command.name));
}

fn isTopLevelDispatchName(name: []const u8, observe_enabled: bool) bool {
    return isTopLevelCommand(name, observe_enabled) or
        containsName(&top_level_help_aliases, name) or
        containsName(&top_level_version_aliases, name) or
        containsName(&legacy_top_level_commands, name) or
        std.mem.eql(u8, name, code_intel.WATCHER_REINDEX_WORKER_COMMAND);
}

fn isGroupDispatchName(entries: []const CommandEntry, name: []const u8) bool {
    return containsCommand(entries, name);
}

fn helpContainsCommand(help_text: []const u8, name: []const u8) bool {
    return std.mem.indexOf(u8, help_text, name) != null;
}

fn appendCommandHelp(allocator: std.mem.Allocator, output: *std.ArrayListUnmanaged(u8), entries: []const CommandEntry) !void {
    for (entries) |entry| {
        try output.writer(allocator).print("    {s}{s}{s}  {s}{s}{s}\n", .{ bold, entry.name, reset, dim, entry.summary, reset });
    }
}

pub fn main() void {
    mainInner() catch {
        std.process.exit(1);
    };
}

fn mainInner() !void {
    var gpa: std.heap.GeneralPurposeAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Collect args
    var args_list: std.ArrayListUnmanaged([:0]const u8) = .empty;
    defer args_list.deinit(allocator);

    var iter = std.process.args();
    while (iter.next()) |arg| {
        try args_list.append(allocator, arg);
    }

    // Scan for --debug flag and strip it from args
    var debug_flag = false;
    {
        var i: usize = 1; // skip argv[0]
        while (i < args_list.items.len) {
            if (std.mem.eql(u8, args_list.items[i], "--debug")) {
                debug_flag = true;
                _ = args_list.orderedRemove(i);
            } else {
                i += 1;
            }
        }
    }

    // Enable debug logging from --debug flag or settings.json {"debug": true}
    if (!debug_flag) {
        if (settings_mod.Settings.load(allocator)) |s| {
            defer s.deinit(allocator);
            if (s.debug) |d| {
                debug_flag = d.log;
            }
        }
    }
    if (debug_flag) {
        debug_log.initFromCwd(allocator, version, args_list.items);
    }
    defer debug_log.deinit();

    const args = args_list.items;

    if (args.len < 2) {
        printHelp(allocator);
        return;
    }

    const subcmd: []const u8 = args[1];
    const cmd_args = args[2..];

    if (std.mem.eql(u8, subcmd, code_intel.WATCHER_REINDEX_WORKER_COMMAND)) {
        debug_log.log("dispatch hidden watcher worker: files={d}", .{cmd_args.len});
        const exit_code = code_intel.runWatcherReindexWorker(allocator, cmd_args) catch |err| {
            debug_log.log("hidden watcher worker: invalid arguments or setup failure: {s}", .{@errorName(err)});
            return err;
        };
        std.process.exit(exit_code);
    }
    if (std.mem.eql(u8, subcmd, code_intel.WATCHER_RESYNC_WORKER_COMMAND)) {
        if (cmd_args.len != 0) return error.InvalidArguments;
        debug_log.log("dispatch hidden watcher resync worker", .{});
        std.process.exit(code_intel.runWatcherResyncWorker(allocator));
    }
    if (std.mem.eql(u8, subcmd, code_intel.SYNC_WORKER_COMMAND)) {
        if (cmd_args.len != 0) return error.InvalidArguments;
        debug_log.log("dispatch hidden index sync worker", .{});
        std.process.exit(code_intel.runSyncWorker(allocator));
    }

    // For non-MCP commands, close the log header now. MCP mode defers
    // the separator until handleInitialize appends client info.
    if (!std.mem.eql(u8, subcmd, "mcp") and debug_flag) {
        debug_log.logHeaderSeparator();
    }

    // Avoid unnecessary startup work for MCP server mode.
    if (!std.mem.eql(u8, subcmd, "mcp")) {
        const curl = @import("cog").curl;
        curl.globalInit();
        defer curl.globalCleanup();
    }

    // Handle --version
    if (std.mem.eql(u8, subcmd, "--version") or std.mem.eql(u8, subcmd, "-v")) {
        printStdout(version);
        return;
    }

    // Handle --help at top level
    if (std.mem.eql(u8, subcmd, "--help") or std.mem.eql(u8, subcmd, "-h") or std.mem.eql(u8, subcmd, "help")) {
        printHelp(allocator);
        return;
    }

    // Handle init command (doesn't need config)
    if (std.mem.eql(u8, subcmd, "init")) {
        try commands.init(allocator, cmd_args);
        return;
    }

    // Handle doctor command (doesn't need config)
    if (std.mem.eql(u8, subcmd, "doctor")) {
        try commands.doctor(allocator, cmd_args);
        return;
    }

    // Handle group help: cog ext
    if (std.mem.eql(u8, subcmd, "ext")) {
        printExtHelp();
        return;
    }

    // Handle ext:* commands (don't need config)
    if (std.mem.startsWith(u8, subcmd, "ext:")) {
        debug_log.log("dispatch extension command: {s}", .{subcmd});
        if (std.mem.eql(u8, subcmd, "ext:install")) {
            if (cmd_args.len == 0 or std.mem.eql(u8, cmd_args[0], "--help") or std.mem.eql(u8, cmd_args[0], "-h")) {
                tui.header();
                printErr(help.ext_install);
                if (cmd_args.len == 0) return error.Explained;
                return;
            }
            const install_options = try parseExtInstallOptions(cmd_args);
            debug_log.log("dispatch ext:install trust_build={}", .{install_options.trust_build});
            try extensions_mod.installExtension(allocator, install_options.git_url, install_options.version, .{
                .trust_build = install_options.trust_build,
            });
            return;
        }
        if (std.mem.eql(u8, subcmd, "ext:update")) {
            if (cmd_args.len > 0 and (std.mem.eql(u8, cmd_args[0], "--help") or std.mem.eql(u8, cmd_args[0], "-h"))) {
                tui.header();
                printErr(help.ext_update);
                return;
            }
            const update_options = try parseExtUpdateOptions(cmd_args);
            debug_log.log("dispatch ext:update trust_build={}", .{update_options.trust_build});
            try extensions_mod.updateExtensions(allocator, update_options.name, .{
                .trust_build = update_options.trust_build,
            });
            return;
        }
        printErr("error: unknown command '");
        printErr(subcmd);
        printErr("'\nRun " ++ dim ++ "cog ext" ++ reset ++ " to see available extension commands.\n");
        return error.Explained;
    }

    // Handle install command (legacy alias)
    if (std.mem.eql(u8, subcmd, "install")) {
        if (cmd_args.len == 0 or std.mem.eql(u8, cmd_args[0], "--help") or std.mem.eql(u8, cmd_args[0], "-h")) {
            tui.header();
            printErr(help.ext_install);
            if (cmd_args.len == 0) return error.Explained;
            return;
        }
        printErr("error: 'cog install' has moved to 'cog ext:install'\n");
        return error.Explained;
    }

    // Handle mcp command (doesn't need config)
    if (std.mem.eql(u8, subcmd, "mcp")) {
        if (cmd_args.len > 0 and (std.mem.eql(u8, cmd_args[0], "--help") or std.mem.eql(u8, cmd_args[0], "-h") or std.mem.eql(u8, cmd_args[0], "help"))) {
            printMcpHelp();
            return;
        }
        const mcp_mod = @import("cog").mcp;
        try mcp_mod.serve(allocator, version, cmd_args);
        return;
    }

    // Handle group help: cog code, cog debug
    if (std.mem.eql(u8, subcmd, "code")) {
        printCodeHelp();
        return;
    }
    if (std.mem.eql(u8, subcmd, "debug")) {
        printDebugHelp(allocator);
        return;
    }

    // Handle code:* commands (don't need config — use local .cog/index.scip)
    if (std.mem.startsWith(u8, subcmd, "code:")) {
        try code_intel.dispatch(allocator, subcmd, cmd_args);
        return;
    }

    // Handle debug:* commands (don't need config — local process debugging)
    if (std.mem.startsWith(u8, subcmd, "debug:")) {
        try debug_mod.dispatch(allocator, subcmd, cmd_args);
        return;
    }

    // Handle observe commands only after explicit opt-in.
    if (std.mem.eql(u8, subcmd, "observe") or std.mem.startsWith(u8, subcmd, "observe:")) {
        const observe_enabled = settings_mod.isObserveEnabled(allocator);
        debug_log.log("main.dispatch: observe_enabled={any} subcmd={s}", .{ observe_enabled, subcmd });
        if (!observe_enabled) {
            printErr("error: " ++ settings_mod.OBSERVE_DISABLED_MESSAGE ++ "\n");
            return error.Explained;
        }
        if (std.mem.eql(u8, subcmd, "observe")) {
            printObserveHelp();
            return;
        }
        try observe_mod.dispatch(allocator, subcmd, cmd_args);
        return;
    }

    // Handle group help: cog mem
    if (std.mem.eql(u8, subcmd, "mem")) {
        printMemHelp();
        return;
    }

    // Handle mem:* commands (don't need config — use claude -p)
    if (std.mem.startsWith(u8, subcmd, "mem:")) {
        const bootstrap_mod = @import("cog").bootstrap;
        try bootstrap_mod.dispatch(allocator, subcmd, cmd_args);
        return;
    }

    // Unknown command
    printErr("error: unknown command '");
    printErr(subcmd);
    printErr("'\nRun " ++ dim ++ "cog --help" ++ reset ++ " to see available commands.\n");
    return error.Explained;
}

fn buildTopLevelHelp(allocator: std.mem.Allocator, observe_enabled: bool) ![]u8 {
    var output: std.ArrayListUnmanaged(u8) = .empty;
    errdefer output.deinit(allocator);
    try output.appendSlice(allocator, bold ++ "  Usage: " ++ reset ++ "cog <command> [options]\n\n" ++ cyan ++ bold ++ "  Setup" ++ reset ++ "\n");
    try appendCommandHelp(allocator, &output, top_level_commands[0..2]);
    try output.appendSlice(allocator, "\n" ++ cyan ++ bold ++ "  Commands" ++ reset ++ "\n");
    try appendCommandHelp(allocator, &output, top_level_commands[2..]);
    if (observe_enabled) try appendCommandHelp(allocator, &output, &.{observe_top_level_command});
    try output.appendSlice(allocator, "\n" ++ cyan ++ bold ++ "  Built-in" ++ reset ++ "\n" ++ comptime code_intel.builtinExtensionList() ++ "\n");
    return output.toOwnedSlice(allocator);
}

fn buildGroupHelp(allocator: std.mem.Allocator, title: []const u8, entries: []const CommandEntry) ![]u8 {
    var output: std.ArrayListUnmanaged(u8) = .empty;
    errdefer output.deinit(allocator);
    try output.writer(allocator).print("{s}  cog {s}{s}\n\n{s}{s}  Commands{s}\n", .{ bold, title, reset, cyan, bold, reset });
    try appendCommandHelp(allocator, &output, entries);
    try output.append(allocator, '\n');
    return output.toOwnedSlice(allocator);
}

fn printHelp(allocator: std.mem.Allocator) void {
    const static_help = buildTopLevelHelp(allocator, settings_mod.isObserveEnabled(allocator)) catch return;
    defer allocator.free(static_help);
    const footer = dim ++ "  Run 'cog <command> --help' for details on a specific command." ++ reset ++ "\n\n";

    const installed_block = code_intel.listInstalledBlock(allocator);
    defer if (installed_block) |b| allocator.free(b);

    tui.header();
    printErr(dim ++ "  v");
    printErr(version);
    printErr(reset ++ "\n\n");
    printErr(static_help);
    if (installed_block) |block| printErr(block);
    printErr(footer);
}

fn printCodeHelp() void {
    const allocator = std.heap.page_allocator;
    const content = buildGroupHelp(allocator, "code — Code indexing", &code_commands) catch return;
    defer allocator.free(content);
    tui.header();
    printErr(content);
}

fn parseExtInstallOptions(args: []const [:0]const u8) !ExtInstallOptions {
    var git_url: ?[]const u8 = null;
    var requested_version: ?[]const u8 = null;
    var trust_build = false;

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--trust-build")) {
            trust_build = true;
            continue;
        }
        if (std.mem.startsWith(u8, arg, "--version=")) {
            const value = arg["--version=".len..];
            if (value.len == 0) {
                printErr("error: --version requires a value\n");
                return error.Explained;
            }
            requested_version = value;
            continue;
        }
        if (std.mem.eql(u8, arg, "--version")) {
            if (i + 1 >= args.len) {
                printErr("error: --version requires a value\n");
                return error.Explained;
            }
            i += 1;
            requested_version = args[i];
            continue;
        }
        if (std.mem.startsWith(u8, arg, "-")) {
            printErr("error: unknown option '");
            printErr(arg);
            printErr("'\n");
            return error.Explained;
        }
        if (git_url != null) {
            printErr("error: expected exactly one extension repository URL\n");
            return error.Explained;
        }
        git_url = arg;
    }

    if (git_url == null) {
        printErr("error: missing extension repository URL\n");
        return error.Explained;
    }

    return .{ .git_url = git_url.?, .version = requested_version, .trust_build = trust_build };
}

fn parseExtUpdateOptions(args: []const [:0]const u8) !ExtUpdateOptions {
    var name: ?[]const u8 = null;
    var trust_build = false;

    for (args) |arg| {
        if (std.mem.eql(u8, arg, "--trust-build")) {
            trust_build = true;
            continue;
        }
        if (std.mem.startsWith(u8, arg, "-")) {
            printErr("error: unknown option '");
            printErr(arg);
            printErr("'\n");
            return error.Explained;
        }
        if (name != null) {
            printErr("error: cog ext:update accepts at most one extension name\n");
            return error.Explained;
        }
        name = arg;
    }

    return .{ .name = name, .trust_build = trust_build };
}

fn printExtHelp() void {
    const allocator = std.heap.page_allocator;
    const content = buildGroupHelp(allocator, "ext — Extension utilities", &extension_commands) catch return;
    defer allocator.free(content);
    tui.header();
    printErr(content);
}

fn printDebugHelp(allocator: std.mem.Allocator) void {
    const static_debug = buildGroupHelp(allocator, "debug — Debug daemon utilities", &debug_commands) catch return;
    defer allocator.free(static_debug);
    const installed_block = code_intel.listInstalledDebugBlock(allocator);
    defer if (installed_block) |b| allocator.free(b);

    tui.header();
    printErr(static_debug);
    printErr(cyan ++ bold ++ "  Built-in" ++ reset ++ "\n" ++ comptime code_intel.builtinDebugExtensionList() ++ "\n");
    if (installed_block) |block| printErr(block);
}

fn printObserveHelp() void {
    const allocator = std.heap.page_allocator;
    const cli_help = buildGroupHelp(allocator, "observe — Experimental observation utilities", &observe_commands) catch return;
    defer allocator.free(cli_help);
    tui.header();
    printErr(cli_help);
    printErr(dim ++ "  Observe capture, query, and export CLI commands remain placeholders.\n" ++ reset ++ "\n" ++ cyan ++ bold ++ "  MCP Tools" ++ reset ++ dim ++ " (available only when observe is enabled)" ++ reset ++ "\n" ++ "    " ++ bold ++ "observe_start" ++ reset ++ "         " ++ dim ++ "Create a session for an implemented backend; automatic capture is not implemented" ++ reset ++ "\n" ++ "    " ++ bold ++ "observe_stop" ++ reset ++ "          " ++ dim ++ "Finalize an existing observation session" ++ reset ++ "\n" ++ "    " ++ bold ++ "observe_events" ++ reset ++ "        " ++ dim ++ "Query stored events from a session" ++ reset ++ "\n" ++ "    " ++ bold ++ "observe_sessions" ++ reset ++ "      " ++ dim ++ "List stored observation sessions" ++ reset ++ "\n" ++ "    " ++ bold ++ "observe_status" ++ reset ++ "        " ++ dim ++ "Report backend availability and session counts" ++ reset ++ "\n" ++ "    " ++ bold ++ "observe_causal_chains" ++ reset ++ " " ++ dim ++ "Query causal chains already stored in a session" ++ reset ++ "\n" ++ "    " ++ bold ++ "observe_query" ++ reset ++ "         " ++ dim ++ "Run bounded read-only SQL against a session database" ++ reset ++ "\n\n");
}

fn printMemHelp() void {
    const allocator = std.heap.page_allocator;
    const content = buildGroupHelp(allocator, "mem — Memory utilities", &memory_commands) catch return;
    defer allocator.free(content);
    tui.header();
    printErr(content);
}

fn printMcpHelp() void {
    tui.header();
    printErr(help.mcp);
}

fn printStdout(msg: []const u8) void {
    var buf: [4096]u8 = undefined;
    var w = std.fs.File.stdout().writerStreaming(&buf);
    w.interface.writeAll(msg) catch {};
    w.interface.writeByte('\n') catch {};
    w.interface.flush() catch {};
}

fn printErr(msg: []const u8) void {
    var buf: [4096]u8 = undefined;
    var w = std.fs.File.stderr().writerStreaming(&buf);
    w.interface.writeAll(msg) catch {};
    w.interface.flush() catch {};
}

test "top-level help and dispatch catalog agree" {
    const allocator = std.testing.allocator;

    inline for (.{ false, true }) |observe_enabled| {
        const help_text = try buildTopLevelHelp(allocator, observe_enabled);
        defer allocator.free(help_text);

        for (top_level_commands) |command| {
            try std.testing.expect(isTopLevelDispatchName(command.name, observe_enabled));
            try std.testing.expect(helpContainsCommand(help_text, command.name));
        }

        try std.testing.expectEqual(
            observe_enabled,
            helpContainsCommand(help_text, observe_top_level_command.name),
        );
        try std.testing.expectEqual(
            observe_enabled,
            isTopLevelDispatchName(observe_top_level_command.name, observe_enabled),
        );
    }
}

test "top-level aliases and compatibility commands are intentional" {
    for (top_level_help_aliases) |alias| {
        try std.testing.expect(isTopLevelDispatchName(alias, false));
    }
    for (top_level_version_aliases) |alias| {
        try std.testing.expect(isTopLevelDispatchName(alias, false));
    }
    for (legacy_top_level_commands) |command| {
        try std.testing.expect(isTopLevelDispatchName(command, false));
    }

    try std.testing.expect(isTopLevelDispatchName(code_intel.WATCHER_REINDEX_WORKER_COMMAND, false));
    try std.testing.expect(!isTopLevelCommand(code_intel.WATCHER_REINDEX_WORKER_COMMAND, false));

    const help_text = try buildTopLevelHelp(std.testing.allocator, false);
    defer std.testing.allocator.free(help_text);
    try std.testing.expect(!helpContainsCommand(help_text, code_intel.WATCHER_REINDEX_WORKER_COMMAND));
    try std.testing.expect(!isTopLevelDispatchName("--help-extra", false));
    try std.testing.expect(!isTopLevelDispatchName("debug:unknown", false));
}

test "group help and dispatch catalogs agree" {
    const groups = .{
        .{ .title = "code — Code indexing", .commands = code_commands[0..] },
        .{ .title = "debug — Debug daemon utilities", .commands = debug_commands[0..] },
        .{ .title = "observe — Experimental observation utilities", .commands = observe_commands[0..] },
        .{ .title = "mem — Memory utilities", .commands = memory_commands[0..] },
        .{ .title = "ext — Extension utilities", .commands = extension_commands[0..] },
    };

    inline for (groups) |group| {
        const help_text = try buildGroupHelp(std.testing.allocator, group.title, group.commands);
        defer std.testing.allocator.free(help_text);

        for (group.commands) |command| {
            try std.testing.expect(isGroupDispatchName(group.commands, command.name));
            try std.testing.expect(helpContainsCommand(help_text, command.name));
        }
    }

    try std.testing.expect(!isGroupDispatchName(&code_commands, "code:query"));
    try std.testing.expect(!isGroupDispatchName(&debug_commands, "debug:send"));
    try std.testing.expect(!isGroupDispatchName(&observe_commands, "observe:start"));
    try std.testing.expect(!isGroupDispatchName(&memory_commands, "mem:recall"));
    try std.testing.expect(!isGroupDispatchName(&extension_commands, "ext:remove"));
}

test "parseExtInstallOptions parses url and version flag" {
    const parsed = try parseExtInstallOptions(&.{
        "https://github.com/trycog/cog-zig",
        "--version=0.75.0",
    });
    try std.testing.expectEqualStrings("https://github.com/trycog/cog-zig", parsed.git_url);
    try std.testing.expect(parsed.version != null);
    try std.testing.expectEqualStrings("0.75.0", parsed.version.?);
}

test "parseExtInstallOptions supports split version flag" {
    const parsed = try parseExtInstallOptions(&.{
        "https://github.com/trycog/cog-zig",
        "--version",
        "0.75.0",
    });
    try std.testing.expect(parsed.version != null);
    try std.testing.expectEqualStrings("0.75.0", parsed.version.?);
    try std.testing.expect(!parsed.trust_build);
}

test "parseExtInstallOptions requires explicit trust build flag" {
    const parsed = try parseExtInstallOptions(&.{
        "--trust-build",
        "https://github.com/trycog/cog-zig",
    });
    try std.testing.expect(parsed.trust_build);
}

test "parseExtUpdateOptions parses optional name and trust build flag" {
    const all = try parseExtUpdateOptions(&.{"--trust-build"});
    try std.testing.expect(all.name == null);
    try std.testing.expect(all.trust_build);

    const one = try parseExtUpdateOptions(&.{ "cog-zig", "--trust-build" });
    try std.testing.expectEqualStrings("cog-zig", one.name.?);
    try std.testing.expect(one.trust_build);
}
