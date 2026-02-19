const std = @import("std");
const build_options = @import("build_options");
const commands = @import("cog").commands;
const code_intel = @import("cog").code_intel;
const extensions_mod = @import("cog").extensions;
const debug_mod = @import("cog").debug;
const tui = @import("cog").tui;
const help = @import("cog").help_text;

const version = build_options.version;

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
        printHelp();
        return;
    }

    // Handle init command (doesn't need config)
    if (std.mem.eql(u8, subcmd, "init")) {
        try commands.init(allocator, cmd_args);
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

    // Handle mcp command (doesn't need config)
    if (std.mem.eql(u8, subcmd, "mcp")) {
        if (cmd_args.len > 0 and (std.mem.eql(u8, cmd_args[0], "--help") or std.mem.eql(u8, cmd_args[0], "-h") or std.mem.eql(u8, cmd_args[0], "help"))) {
            printMcpHelp();
            return;
        }
        const mcp_mod = @import("cog").mcp;
        try mcp_mod.serve(allocator, version);
        return;
    }

    // Handle group help: cog code, cog debug
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

    // Unknown command
    printErr("error: unknown command '");
    printErr(subcmd);
    printErr("'\nRun " ++ dim ++ "cog --help" ++ reset ++ " to see available commands.\n");
    return error.Explained;
}

fn printHelp() void {
    tui.header();
    printErr(dim ++ "  v");
    printErr(version);
    printErr(reset ++ "\n\n");
    printErr(bold ++ "  Usage: " ++ reset ++ "cog <command> [options]\n" ++ "\n" ++ cyan ++ bold ++ "  Setup" ++ reset ++ "\n" ++ "    " ++ bold ++ "init" ++ reset ++ "                  " ++ dim ++ "Interactive setup for the current directory" ++ reset ++ "\n" ++ "\n" ++ cyan ++ bold ++ "  Commands" ++ reset ++ "\n" ++ "    " ++ bold ++ "code" ++ reset ++ "                  " ++ dim ++ "Code indexing (CLI compatibility)" ++ reset ++ "\n" ++ "    " ++ bold ++ "mcp" ++ reset ++ "                   " ++ dim ++ "MCP server over stdio (primary interface)" ++ reset ++ "\n" ++ "    " ++ bold ++ "debug" ++ reset ++ "                 " ++ dim ++ "Debug daemon utilities" ++ reset ++ "\n" ++ "    " ++ bold ++ "install" ++ reset ++ "               " ++ dim ++ "Install a language extension from a git URL" ++ reset ++ "\n" ++ "\n" ++ dim ++ "  Run 'cog <command> --help' for details on a specific command." ++ reset ++ "\n" ++ "\n");
}

fn printCodeHelp() void {
    tui.header();
    printErr(bold ++ "  cog code" ++ reset ++ " — Code indexing\n" ++ "\n" ++ cyan ++ bold ++ "  Commands" ++ reset ++ "\n" ++ "    " ++ bold ++ "code/index" ++ reset ++ "            " ++ dim ++ "Build SCIP code index (per-file incremental)" ++ reset ++ "\n" ++ "\n" ++ dim ++ "  code/query, code/status, code/edit, code/create, code/delete, and code/rename" ++ reset ++ "\n" ++ dim ++ "  moved to MCP tools (cog_code_*). Run 'cog mcp --help' for MCP usage." ++ reset ++ "\n" ++ "\n");
}

fn printDebugHelp() void {
    tui.header();
    printErr(bold ++ "  cog debug" ++ reset ++ " — Debug daemon utilities\n" ++ "\n" ++ cyan ++ bold ++ "  Server" ++ reset ++ "\n" ++ "    " ++ bold ++ "debug/serve" ++ reset ++ "           " ++ dim ++ "Start the debug daemon" ++ reset ++ "\n" ++ "    " ++ bold ++ "debug/dashboard" ++ reset ++ "       " ++ dim ++ "Live debug session dashboard" ++ reset ++ "\n" ++ "    " ++ bold ++ "debug/status" ++ reset ++ "          " ++ dim ++ "Check daemon status and active sessions" ++ reset ++ "\n" ++ "    " ++ bold ++ "debug/kill" ++ reset ++ "            " ++ dim ++ "Stop the debug daemon" ++ reset ++ "\n" ++ "    " ++ bold ++ "debug/sign" ++ reset ++ "            " ++ dim ++ "Code-sign binary with debug entitlements (macOS)" ++ reset ++ "\n" ++ "\n" ++ dim ++ "  debug/send moved to MCP tools (debug_*). Run 'cog mcp --help'." ++ reset ++ "\n" ++ "\n");
}

fn printMcpHelp() void {
    tui.header();
    printErr(bold ++ "  cog mcp" ++ reset ++ " — MCP server over stdio\n" ++ "\n" ++ bold ++ "  Usage: " ++ reset ++ "cog mcp\n" ++ "\n" ++ dim ++ "  Starts a local Model Context Protocol server on stdio.\n" ++ dim ++ "  This command is intended to be launched by MCP clients.\n" ++ "\n" ++ bold ++ "  Options\n" ++ reset ++ "    " ++ bold ++ "--help, -h" ++ reset ++ "            " ++ dim ++ "Show this help message" ++ reset ++ "\n" ++ "\n");
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
