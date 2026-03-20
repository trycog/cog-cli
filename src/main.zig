const std = @import("std");
const build_options = @import("build_options");
const commands = @import("cog").commands;
const code_intel = @import("cog").code_intel;
const extensions_mod = @import("cog").extensions;
const debug_mod = @import("cog").debug;
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
};

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
            try extensions_mod.installExtension(allocator, install_options.git_url, install_options.version);
            return;
        }
        if (std.mem.eql(u8, subcmd, "ext:update")) {
            if (cmd_args.len > 0 and (std.mem.eql(u8, cmd_args[0], "--help") or std.mem.eql(u8, cmd_args[0], "-h"))) {
                tui.header();
                printErr(help.ext_update);
                return;
            }
            if (cmd_args.len > 1) {
                printErr("error: cog ext:update accepts at most one extension name\n");
                return error.Explained;
            }
            const ext_name = if (cmd_args.len == 1) cmd_args[0] else null;
            try extensions_mod.updateExtensions(allocator, ext_name);
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

fn printHelp(allocator: std.mem.Allocator) void {
    const static_help = bold ++ "  Usage: " ++ reset ++ "cog <command> [options]\n" ++ "\n" ++ cyan ++ bold ++ "  Setup" ++ reset ++ "\n" ++ "    " ++ bold ++ "init" ++ reset ++ "                  " ++ dim ++ "Interactive setup for the current directory" ++ reset ++ "\n" ++ "    " ++ bold ++ "doctor" ++ reset ++ "                " ++ dim ++ "Validate installation and configuration" ++ reset ++ "\n" ++ "\n" ++ cyan ++ bold ++ "  Commands" ++ reset ++ "\n" ++ "    " ++ bold ++ "code" ++ reset ++ "                  " ++ dim ++ "Code indexing (CLI compatibility)" ++ reset ++ "\n" ++ "    " ++ bold ++ "mcp" ++ reset ++ "                   " ++ dim ++ "MCP server over stdio (primary interface)" ++ reset ++ "\n" ++ "    " ++ bold ++ "debug" ++ reset ++ "                 " ++ dim ++ "Debug daemon utilities" ++ reset ++ "\n" ++ "    " ++ bold ++ "mem" ++ reset ++ "                   " ++ dim ++ "Memory utilities" ++ reset ++ "\n" ++ "    " ++ bold ++ "ext" ++ reset ++ "                   " ++ dim ++ "Extension utilities" ++ reset ++ "\n" ++ "\n" ++ cyan ++ bold ++ "  Built-in" ++ reset ++ "\n" ++ comptime code_intel.builtinExtensionList() ++ "\n";

    const footer = dim ++ "  Run 'cog <command> --help' for details on a specific command." ++ reset ++ "\n\n";

    const installed_block = code_intel.listInstalledBlock(allocator);
    defer if (installed_block) |b| allocator.free(b);

    tui.header();
    printErr(dim ++ "  v");
    printErr(version);
    printErr(reset ++ "\n\n");

    if (installed_block) |block| {
        const combined = std.fmt.allocPrint(allocator, "{s}{s}{s}", .{ static_help, block, footer }) catch {
            printErr(static_help);
            printErr(block);
            printErr(footer);
            return;
        };
        defer allocator.free(combined);
        printErr(combined);
    } else {
        printErr(static_help ++ footer);
    }
}

fn printCodeHelp() void {
    tui.header();
    printErr(bold ++ "  cog code" ++ reset ++ " — Code indexing\n" ++ "\n" ++ cyan ++ bold ++ "  Commands" ++ reset ++ "\n" ++ "    " ++ bold ++ "code:index" ++ reset ++ "            " ++ dim ++ "Build SCIP code index (per-file incremental)" ++ reset ++ "\n" ++ "\n");
}

fn parseExtInstallOptions(args: []const [:0]const u8) !ExtInstallOptions {
    var git_url: ?[]const u8 = null;
    var requested_version: ?[]const u8 = null;

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
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

    return .{ .git_url = git_url.?, .version = requested_version };
}

fn printExtHelp() void {
    tui.header();
    printErr(bold ++ "  cog ext" ++ reset ++ " -- Extension utilities\n" ++ "\n" ++ cyan ++ bold ++ "  Commands" ++ reset ++ "\n" ++ "    " ++ bold ++ "ext:install" ++ reset ++ "           " ++ dim ++ "Install a language extension from GitHub releases" ++ reset ++ "\n" ++ "    " ++ bold ++ "ext:update" ++ reset ++ "            " ++ dim ++ "Update installed extensions to latest releases" ++ reset ++ "\n" ++ "\n");
}

fn printDebugHelp(allocator: std.mem.Allocator) void {
    const static_debug = bold ++ "  cog debug" ++ reset ++ " — Debug daemon utilities\n" ++ "\n" ++ cyan ++ bold ++ "  Server" ++ reset ++ "\n" ++ "    " ++ bold ++ "debug:serve" ++ reset ++ "           " ++ dim ++ "Start the debug daemon" ++ reset ++ "\n" ++ "    " ++ bold ++ "debug:dashboard" ++ reset ++ "       " ++ dim ++ "Live debug session dashboard" ++ reset ++ "\n" ++ "    " ++ bold ++ "debug:status" ++ reset ++ "          " ++ dim ++ "Check daemon status and active sessions" ++ reset ++ "\n" ++ "    " ++ bold ++ "debug:kill" ++ reset ++ "            " ++ dim ++ "Stop the debug daemon" ++ reset ++ "\n" ++ "    " ++ bold ++ "debug:sign" ++ reset ++ "            " ++ dim ++ "Code-sign binary with debug entitlements (macOS)" ++ reset ++ "\n" ++ "\n" ++ cyan ++ bold ++ "  Built-in" ++ reset ++ "\n" ++ comptime code_intel.builtinDebugExtensionList() ++ "\n";

    const installed_block = code_intel.listInstalledDebugBlock(allocator);
    defer if (installed_block) |b| allocator.free(b);

    tui.header();
    if (installed_block) |block| {
        const combined = std.fmt.allocPrint(allocator, "{s}{s}", .{ static_debug, block }) catch {
            printErr(static_debug);
            printErr(block);
            return;
        };
        defer allocator.free(combined);
        printErr(combined);
    } else {
        printErr(static_debug);
    }
}

fn printMemHelp() void {
    tui.header();
    printErr(bold ++ "  cog mem" ++ reset ++ " — Memory utilities\n" ++ "\n" ++ cyan ++ bold ++ "  Commands" ++ reset ++ "\n" ++ "    " ++ bold ++ "mem:bootstrap" ++ reset ++ "         " ++ dim ++ "Scan project files and populate memory" ++ reset ++ "\n" ++ "    " ++ bold ++ "mem:info" ++ reset ++ "              " ++ dim ++ "Show brain type, path, and memory stats" ++ reset ++ "\n" ++ "    " ++ bold ++ "mem:upload" ++ reset ++ "            " ++ dim ++ "Upload a local brain to trycog.ai" ++ reset ++ "\n" ++ "    " ++ bold ++ "mem:upgrade" ++ reset ++ "           " ++ dim ++ "Instructions for migrating to hosted brain" ++ reset ++ "\n" ++ "\n");
}

fn printMcpHelp() void {
    tui.header();
    printErr(bold ++ "  cog mcp" ++ reset ++ " — MCP server over stdio\n" ++ "\n" ++ bold ++ "  Usage: " ++ reset ++ "cog mcp [options]\n" ++ "\n" ++ dim ++ "  Starts a local Model Context Protocol server on stdio.\n" ++ dim ++ "  This command is intended to be launched by MCP clients.\n" ++ "\n" ++ bold ++ "  Options\n" ++ reset ++ "    " ++ bold ++ "--help, -h" ++ reset ++ "            " ++ dim ++ "Show this help message\n" ++ reset ++ "    " ++ bold ++ "--debug-tools=TIER" ++ reset ++ "    " ++ dim ++ "Limit exposed debug tools (core, extended, all)\n" ++ "                              core: 7 essential tools (launch, breakpoint, run, inspect, stacktrace, stop, sessions)\n" ++ "                              extended: core + threads, attach, set_variable, watchpoint, exception_info, restart\n" ++ "                              all: all 36 debug tools (default)" ++ reset ++ "\n" ++ "\n");
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
}
