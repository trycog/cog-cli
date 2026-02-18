const std = @import("std");
const build_options = @import("build_options");
const config_mod = @import("cog").config;
const commands = @import("cog").commands;
const code_intel = @import("cog").code_intel;
const extensions_mod = @import("cog").extensions;
const debug_mod = @import("cog").debug;
const tui = @import("cog").tui;
const help = @import("cog").help_text;

const version = build_options.version;

const Config = config_mod.Config;

// ANSI styles
const cyan = "\x1B[36m";
const bold = "\x1B[1m";
const dim = "\x1B[2m";
const reset = "\x1B[0m";

pub fn main() void {
    mainInner() catch {
        std.process.exit(1);
    };
}

fn mainInner() !void {
    const curl = @import("cog").curl;
    curl.globalInit();
    defer curl.globalCleanup();

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
    const args = args_list.items;

    if (args.len < 2) {
        printHelp();
        return;
    }

    const subcmd: []const u8 = args[1];
    const cmd_args = args[2..];

    // Handle --version
    if (std.mem.eql(u8, subcmd, "--version") or std.mem.eql(u8, subcmd, "-v")) {
        printStdout(version);
        return;
    }

    // Handle --help at top level
    if (std.mem.eql(u8, subcmd, "--help") or std.mem.eql(u8, subcmd, "-h") or std.mem.eql(u8, subcmd, "help")) {
        printHelp();
        return;
    }

    // Handle init command (doesn't need config)
    if (std.mem.eql(u8, subcmd, "init")) {
        try commands.init(allocator, cmd_args);
        return;
    }

    // Handle update command (doesn't need config)
    if (std.mem.eql(u8, subcmd, "update")) {
        try commands.updatePromptAndSkill(allocator, cmd_args);
        return;
    }

    // Handle install command (doesn't need config)
    if (std.mem.eql(u8, subcmd, "install")) {
        if (cmd_args.len == 0 or std.mem.eql(u8, cmd_args[0], "--help") or std.mem.eql(u8, cmd_args[0], "-h")) {
            tui.header();
            printErr(help.install);
            if (cmd_args.len == 0) return error.Explained;
            return;
        }
        try extensions_mod.installExtension(allocator, cmd_args[0]);
        return;
    }

    // Handle group help: cog mem, cog code, cog debug
    if (std.mem.eql(u8, subcmd, "mem")) {
        printMemHelp();
        return;
    }
    if (std.mem.eql(u8, subcmd, "code")) {
        printCodeHelp();
        return;
    }
    if (std.mem.eql(u8, subcmd, "debug")) {
        printDebugHelp();
        return;
    }

    // Handle code/* commands (don't need config — use local .cog/index.scip)
    if (std.mem.startsWith(u8, subcmd, "code/")) {
        try code_intel.dispatch(allocator, subcmd, cmd_args);
        return;
    }

    // Handle debug/* commands (don't need config — local process debugging)
    if (std.mem.startsWith(u8, subcmd, "debug/")) {
        try debug_mod.dispatch(allocator, subcmd, cmd_args);
        return;
    }

    // Validate command before loading config
    const command = resolveCommand(subcmd) orelse {
        printErr("error: unknown command '");
        printErr(subcmd);
        printErr("'\nRun " ++ dim ++ "cog --help" ++ reset ++ " to see available commands.\n");
        return error.Explained;
    };

    // Load config
    const cfg = try Config.load(allocator);
    defer cfg.deinit(allocator);

    // Dispatch
    try command(allocator, cmd_args, cfg);
}

fn printHelp() void {
    tui.header();
    printErr(dim ++ "  v");
    printErr(version);
    printErr(reset ++ "\n\n");
    printErr(
        bold ++ "  Usage: " ++ reset ++ "cog <command> [options]\n"
        ++ "\n"
        ++ cyan ++ bold ++ "  Setup" ++ reset ++ "\n"
        ++ "    " ++ bold ++ "init" ++ reset ++ "                  " ++ dim ++ "Interactive setup for the current directory" ++ reset ++ "\n"
        ++ "    " ++ bold ++ "update" ++ reset ++ "                " ++ dim ++ "Fetch latest system prompt and agent skill" ++ reset ++ "\n"
        ++ "\n"
        ++ cyan ++ bold ++ "  Commands" ++ reset ++ "\n"
        ++ "    " ++ bold ++ "mem" ++ reset ++ "                   " ++ dim ++ "Persistent associative memory" ++ reset ++ "\n"
        ++ "    " ++ bold ++ "code" ++ reset ++ "                  " ++ dim ++ "Code intelligence and indexing" ++ reset ++ "\n"
        ++ "    " ++ bold ++ "debug" ++ reset ++ "                 " ++ dim ++ "Debug server for AI agents" ++ reset ++ "\n"
        ++ "    " ++ bold ++ "install" ++ reset ++ "               " ++ dim ++ "Install a language extension from a git URL" ++ reset ++ "\n"
        ++ "\n"
        ++ dim ++ "  Run 'cog <command> --help' for details on a specific command." ++ reset ++ "\n"
        ++ "\n"
    );
}

fn printMemHelp() void {
    tui.header();
    printErr(
        bold ++ "  cog mem" ++ reset ++ " — Persistent associative memory\n"
        ++ "\n"
        ++ cyan ++ bold ++ "  Read" ++ reset ++ "\n"
        ++ "    " ++ bold ++ "mem/recall" ++ reset ++ "            " ++ dim ++ "Search memory for relevant concepts" ++ reset ++ "\n"
        ++ "    " ++ bold ++ "mem/get" ++ reset ++ "               " ++ dim ++ "Retrieve a specific engram by ID" ++ reset ++ "\n"
        ++ "    " ++ bold ++ "mem/connections" ++ reset ++ "       " ++ dim ++ "List connections from an engram" ++ reset ++ "\n"
        ++ "    " ++ bold ++ "mem/trace" ++ reset ++ "             " ++ dim ++ "Find reasoning path between concepts" ++ reset ++ "\n"
        ++ "    " ++ bold ++ "mem/bulk-recall" ++ reset ++ "       " ++ dim ++ "Search with multiple queries" ++ reset ++ "\n"
        ++ "    " ++ bold ++ "mem/list-short-term" ++ reset ++ "   " ++ dim ++ "List short-term memories pending consolidation" ++ reset ++ "\n"
        ++ "    " ++ bold ++ "mem/stale" ++ reset ++ "             " ++ dim ++ "List synapses approaching staleness" ++ reset ++ "\n"
        ++ "    " ++ bold ++ "mem/stats" ++ reset ++ "             " ++ dim ++ "Get brain statistics" ++ reset ++ "\n"
        ++ "    " ++ bold ++ "mem/orphans" ++ reset ++ "           " ++ dim ++ "List disconnected concepts" ++ reset ++ "\n"
        ++ "    " ++ bold ++ "mem/connectivity" ++ reset ++ "      " ++ dim ++ "Analyze graph connectivity" ++ reset ++ "\n"
        ++ "    " ++ bold ++ "mem/list-terms" ++ reset ++ "        " ++ dim ++ "List all engram terms" ++ reset ++ "\n"
        ++ "\n"
        ++ cyan ++ bold ++ "  Write" ++ reset ++ "\n"
        ++ "    " ++ bold ++ "mem/learn" ++ reset ++ "             " ++ dim ++ "Store a new concept" ++ reset ++ "\n"
        ++ "    " ++ bold ++ "mem/associate" ++ reset ++ "         " ++ dim ++ "Link two concepts" ++ reset ++ "\n"
        ++ "    " ++ bold ++ "mem/bulk-learn" ++ reset ++ "        " ++ dim ++ "Batch store concepts" ++ reset ++ "\n"
        ++ "    " ++ bold ++ "mem/bulk-associate" ++ reset ++ "    " ++ dim ++ "Batch link concepts" ++ reset ++ "\n"
        ++ "    " ++ bold ++ "mem/update" ++ reset ++ "            " ++ dim ++ "Update an existing engram" ++ reset ++ "\n"
        ++ "    " ++ bold ++ "mem/unlink" ++ reset ++ "            " ++ dim ++ "Remove a synapse" ++ reset ++ "\n"
        ++ "    " ++ bold ++ "mem/refactor" ++ reset ++ "          " ++ dim ++ "Update concept via term lookup" ++ reset ++ "\n"
        ++ "    " ++ bold ++ "mem/deprecate" ++ reset ++ "         " ++ dim ++ "Mark a concept as obsolete" ++ reset ++ "\n"
        ++ "    " ++ bold ++ "mem/reinforce" ++ reset ++ "         " ++ dim ++ "Consolidate short-term to long-term" ++ reset ++ "\n"
        ++ "    " ++ bold ++ "mem/flush" ++ reset ++ "             " ++ dim ++ "Delete a short-term memory" ++ reset ++ "\n"
        ++ "    " ++ bold ++ "mem/verify" ++ reset ++ "            " ++ dim ++ "Confirm synapse accuracy" ++ reset ++ "\n"
        ++ "    " ++ bold ++ "mem/meld" ++ reset ++ "              " ++ dim ++ "Create cross-brain connection" ++ reset ++ "\n"
        ++ "\n"
        ++ dim ++ "  Run 'cog mem/<command> --help' for details on a specific command." ++ reset ++ "\n"
        ++ "\n"
    );
}

fn printCodeHelp() void {
    tui.header();
    printErr(
        bold ++ "  cog code" ++ reset ++ " — Code intelligence and indexing\n"
        ++ "\n"
        ++ cyan ++ bold ++ "  Commands" ++ reset ++ "\n"
        ++ "    " ++ bold ++ "code/index" ++ reset ++ "            " ++ dim ++ "Build SCIP code index (per-file incremental)" ++ reset ++ "\n"
        ++ "    " ++ bold ++ "code/query" ++ reset ++ "            " ++ dim ++ "Find definitions, references, symbols, structure" ++ reset ++ "\n"
        ++ "    " ++ bold ++ "code/edit" ++ reset ++ "             " ++ dim ++ "Edit a file and re-index" ++ reset ++ "\n"
        ++ "    " ++ bold ++ "code/create" ++ reset ++ "           " ++ dim ++ "Create a file and index it" ++ reset ++ "\n"
        ++ "    " ++ bold ++ "code/delete" ++ reset ++ "           " ++ dim ++ "Delete a file and remove from index" ++ reset ++ "\n"
        ++ "    " ++ bold ++ "code/rename" ++ reset ++ "           " ++ dim ++ "Rename a file and update index" ++ reset ++ "\n"
        ++ "    " ++ bold ++ "code/status" ++ reset ++ "           " ++ dim ++ "Report index status" ++ reset ++ "\n"
        ++ "\n"
        ++ dim ++ "  Run 'cog code/<command> --help' for details on a specific command." ++ reset ++ "\n"
        ++ "\n"
    );
}

fn printDebugHelp() void {
    tui.header();
    printErr(
        bold ++ "  cog debug" ++ reset ++ " — Debug server for AI agents\n"
        ++ "\n"
        ++ cyan ++ bold ++ "  Server" ++ reset ++ "\n"
        ++ "    " ++ bold ++ "debug/serve" ++ reset ++ "           " ++ dim ++ "Start the debug daemon" ++ reset ++ "\n"
        ++ "    " ++ bold ++ "debug/dashboard" ++ reset ++ "       " ++ dim ++ "Live debug session dashboard" ++ reset ++ "\n"
        ++ "    " ++ bold ++ "debug/status" ++ reset ++ "          " ++ dim ++ "Check daemon status and active sessions" ++ reset ++ "\n"
        ++ "    " ++ bold ++ "debug/kill" ++ reset ++ "            " ++ dim ++ "Stop the debug daemon" ++ reset ++ "\n"
        ++ "    " ++ bold ++ "debug/sign" ++ reset ++ "            " ++ dim ++ "Code-sign binary with debug entitlements (macOS)" ++ reset ++ "\n"
        ++ "\n"
        ++ cyan ++ bold ++ "  Debug Tools" ++ reset ++ "\n"
        ++ "    " ++ bold ++ "debug/send <tool>" ++ reset ++ "     " ++ dim ++ "Send a debug command to the daemon" ++ reset ++ "\n"
        ++ "\n"
        ++ dim ++ "  Run 'cog debug/send --help' to list all debug tools.\n"
        ++ "  Run 'cog debug/send <tool> --help' for tool-specific usage." ++ reset ++ "\n"
        ++ "\n"
    );
}

const CommandFn = *const fn (std.mem.Allocator, []const [:0]const u8, Config) anyerror!void;

fn resolveCommand(name: []const u8) ?CommandFn {
    const map = .{
        .{ "mem/recall", commands.recall },
        .{ "mem/get", commands.get },
        .{ "mem/connections", commands.connections },
        .{ "mem/trace", commands.trace },
        .{ "mem/bulk-recall", commands.bulkRecall },
        .{ "mem/list-short-term", commands.listShortTerm },
        .{ "mem/stale", commands.stale },
        .{ "mem/stats", commands.stats },
        .{ "mem/orphans", commands.orphans },
        .{ "mem/connectivity", commands.connectivity },
        .{ "mem/list-terms", commands.listTerms },
        .{ "mem/learn", commands.learn },
        .{ "mem/associate", commands.associate },
        .{ "mem/bulk-learn", commands.bulkLearn },
        .{ "mem/bulk-associate", commands.bulkAssociate },
        .{ "mem/update", commands.update },
        .{ "mem/unlink", commands.unlink },
        .{ "mem/refactor", commands.refactor },
        .{ "mem/deprecate", commands.deprecate },
        .{ "mem/reinforce", commands.reinforce },
        .{ "mem/flush", commands.flush },
        .{ "mem/verify", commands.verify },
        .{ "mem/meld", commands.meld },
    };
    inline for (map) |entry| {
        if (std.mem.eql(u8, name, entry[0])) return entry[1];
    }
    return null;
}

fn printStdout(msg: []const u8) void {
    var buf: [4096]u8 = undefined;
    var w = std.fs.File.stdout().writer(&buf);
    w.interface.writeAll(msg) catch {};
    w.interface.writeByte('\n') catch {};
    w.interface.flush() catch {};
}

fn printErr(msg: []const u8) void {
    var buf: [4096]u8 = undefined;
    var w = std.fs.File.stderr().writer(&buf);
    w.interface.writeAll(msg) catch {};
    w.interface.flush() catch {};
}
