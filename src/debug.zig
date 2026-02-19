pub const types = @import("debug/types.zig");
pub const driver = @import("debug/driver.zig");
pub const session = @import("debug/session.zig");
pub const server = @import("debug/server.zig");
pub const dashboard = @import("debug/dashboard.zig");
pub const dap_protocol = @import("debug/dap/protocol.zig");
pub const dap_transport = @import("debug/dap/transport.zig");
pub const dap_proxy = @import("debug/dap/proxy.zig");
pub const dap_sandbox = @import("debug/dap/sandbox.zig");
pub const dwarf_process = @import("debug/dwarf/process.zig");
pub const dwarf_engine = @import("debug/dwarf/engine.zig");
pub const dwarf_binary_macho = @import("debug/dwarf/binary_macho.zig");
pub const dwarf_binary_elf = @import("debug/dwarf/binary_elf.zig");
pub const dwarf_parser = @import("debug/dwarf/parser.zig");
pub const stack_merge = @import("debug/stack_merge.zig");
pub const dwarf_breakpoints = @import("debug/dwarf/breakpoints.zig");
pub const dwarf_unwind = @import("debug/dwarf/unwind.zig");
pub const dwarf_location = @import("debug/dwarf/location.zig");
pub const dashboard_tui = @import("debug/dashboard_tui.zig");
pub const cli = @import("debug/cli.zig");
pub const daemon = @import("debug/daemon.zig");

const std = @import("std");
const help = @import("help_text.zig");
const tui = @import("tui.zig");

// ANSI styles
const cyan = "\x1B[36m";
const dim = "\x1B[2m";
const reset = "\x1B[0m";

// Unicode glyphs
const check_glyph = "\xE2\x9C\x93"; // ✓

fn printErr(msg: []const u8) void {
    if (@import("builtin").is_test) return;
    var buf: [4096]u8 = undefined;
    var w = std.fs.File.stderr().writer(&buf);
    w.interface.writeAll(msg) catch {};
    w.interface.flush() catch {};
}

fn printCommandHelp(comptime help_text: []const u8) void {
    tui.header();
    printErr(help_text);
}

/// Dispatch debug subcommands.
pub fn dispatch(allocator: std.mem.Allocator, subcmd: []const u8, args: []const [:0]const u8) !void {
    if (std.mem.eql(u8, subcmd, "debug:serve")) return debugServe(allocator, args);
    if (std.mem.eql(u8, subcmd, "debug:sign")) return debugSign(allocator, args);
    if (std.mem.eql(u8, subcmd, "debug:dashboard")) return debugDashboard(allocator, args);
    if (std.mem.eql(u8, subcmd, "debug:status")) return debugStatus(allocator, args);
    if (std.mem.eql(u8, subcmd, "debug:kill")) return debugKill(args);

    // debug:send moved to MCP tools (debug_*).
    if (std.mem.eql(u8, subcmd, "debug:send")) {
        printErr("error: 'debug:send' has been removed from CLI. Use MCP debug_* tools instead.\n");
        printErr("Run " ++ dim ++ "cog mcp --help" ++ reset ++ " for MCP server usage.\n");
        return error.Explained;
    }

    printErr("error: unknown command '");
    printErr(subcmd);
    printErr("'\nRun " ++ dim ++ "cog --help" ++ reset ++ " to see available commands.\n");
    return error.Explained;
}

fn hasFlag(args: []const [:0]const u8, flag: []const u8) bool {
    for (args) |arg| {
        if (std.mem.eql(u8, arg, flag)) return true;
    }
    return false;
}

fn debugSign(allocator: std.mem.Allocator, args: []const [:0]const u8) !void {
    if (hasFlag(args, "--help") or hasFlag(args, "-h")) {
        printCommandHelp(help.debug_sign);
        return;
    }

    try ensureDebugEntitlements(allocator);

    tui.header();
    printErr("  " ++ cyan ++ check_glyph ++ reset ++ " Signed with debug entitlements.\n");
    printErr("  " ++ dim ++ "The debug server can now attach to processes on macOS." ++ reset ++ "\n\n");
}

/// Sign the current executable with debug entitlements (macOS only).
/// Idempotent — safe to call on every debug serve start.
fn ensureDebugEntitlements(allocator: std.mem.Allocator) !void {
    const builtin = @import("builtin");
    if (comptime builtin.os.tag != .macos) return;

    // Get path to this executable
    var exe_buf: [std.fs.max_path_bytes]u8 = undefined;
    const exe_path = std.fs.selfExePath(&exe_buf) catch {
        printErr("error: could not determine executable path\n");
        return error.Explained;
    };

    // Write entitlements to a temp file
    const entitlements_xml =
        \\<?xml version="1.0" encoding="UTF-8"?>
        \\<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        \\<plist version="1.0">
        \\<dict>
        \\    <key>com.apple.security.cs.debugger</key>
        \\    <true/>
        \\</dict>
        \\</plist>
    ;

    var tmp_dir = std.fs.openDirAbsolute("/tmp", .{}) catch {
        printErr("error: could not open /tmp\n");
        return error.Explained;
    };
    defer tmp_dir.close();

    const tmp_name = "cog-debug-entitlements.plist";
    tmp_dir.writeFile(.{ .sub_path = tmp_name, .data = entitlements_xml }) catch {
        printErr("error: could not write entitlements to /tmp\n");
        return error.Explained;
    };
    defer tmp_dir.deleteFile(tmp_name) catch {};

    // Run codesign
    var child = std.process.Child.init(
        &.{ "codesign", "--entitlements", "/tmp/" ++ tmp_name, "--force", "-s", "-", exe_path },
        allocator,
    );
    child.stderr_behavior = .Pipe;
    child.stdout_behavior = .Pipe;

    _ = child.spawnAndWait() catch {
        printErr("error: failed to run codesign\n");
        return error.Explained;
    };
}

/// Re-exec the current process so macOS loads the newly signed entitlements.
/// On macOS, entitlements are checked at process launch — signing the running
/// binary doesn't grant entitlements to the current process. This re-exec
/// replaces the process with a fresh instance that has the entitlements active.
/// Uses COG_DEBUG_SIGNED env var to prevent infinite re-exec.
fn reexecWithEntitlements() void {
    const c_fns = struct {
        extern fn setenv([*:0]const u8, [*:0]const u8, c_int) c_int;
    };
    if (c_fns.setenv("COG_DEBUG_SIGNED", "1", 1) != 0) return;

    var argv_buf: [256:null]?[*:0]const u8 = @splat(null);
    var argc: usize = 0;
    var args_iter = std.process.args();
    while (args_iter.next()) |arg| {
        if (argc >= 255) break;
        argv_buf[argc] = arg.ptr;
        argc += 1;
    }
    if (argc == 0) return;

    std.posix.execvpeZ(
        argv_buf[0].?,
        @ptrCast(&argv_buf),
        @ptrCast(std.c.environ),
    ) catch {};
    // If execvpe fails, fall through — server runs without entitlements
}

fn debugServe(allocator: std.mem.Allocator, args: []const [:0]const u8) !void {
    if (hasFlag(args, "--help") or hasFlag(args, "-h")) {
        printCommandHelp(help.debug_serve);
        return;
    }

    // On macOS, ensure debug entitlements are active.
    // Entitlements are checked at process launch, so if the binary wasn't
    // already signed, we sign it and re-exec to activate them.
    if (@import("builtin").os.tag == .macos) {
        if (std.posix.getenv("COG_DEBUG_SIGNED") == null) {
            ensureDebugEntitlements(allocator) catch {};
            reexecWithEntitlements();
            // If re-exec failed, continue without entitlements
        }
    }

    // Load session idle timeout from settings
    const session_timeout: ?i64 = blk: {
        const settings_mod = @import("settings.zig");
        const settings = settings_mod.Settings.load(allocator) orelse break :blk null;
        defer settings.deinit(allocator);
        const debug_cfg = settings.debug orelse break :blk null;
        break :blk debug_cfg.timeout;
    };

    var d = daemon.DaemonServer.init(allocator, session_timeout);
    defer d.deinit();
    try d.run();
}

fn debugStatus(allocator: std.mem.Allocator, args: []const [:0]const u8) !void {
    if (hasFlag(args, "--help") or hasFlag(args, "-h")) {
        printCommandHelp(help.debug_status);
        return;
    }

    try cli.statusCommand(allocator);
}

fn debugKill(args: []const [:0]const u8) !void {
    if (hasFlag(args, "--help") or hasFlag(args, "-h")) {
        printCommandHelp(help.debug_kill);
        return;
    }

    try cli.killCommand();
}

fn debugDashboard(allocator: std.mem.Allocator, args: []const [:0]const u8) !void {
    if (hasFlag(args, "--help") or hasFlag(args, "-h")) {
        printCommandHelp(help.debug_dashboard);
        return;
    }

    var tui_instance = dashboard_tui.DashboardTui.init(allocator);
    defer tui_instance.deinit();

    try tui_instance.run();
}

test {
    _ = types;
    _ = driver;
    _ = session;
    _ = server;
    _ = dashboard;
    _ = dap_protocol;
    _ = dap_transport;
    _ = dap_proxy;
    _ = dap_sandbox;
    _ = dwarf_process;
    _ = dwarf_engine;
    _ = dwarf_binary_macho;
    _ = dwarf_binary_elf;
    _ = dwarf_parser;
    _ = stack_merge;
    _ = dwarf_breakpoints;
    _ = dwarf_unwind;
    _ = dwarf_location;
    _ = dashboard_tui;
    _ = cli;
    _ = daemon;
}

test "cog debug routes to debug dispatch" {
    // Test that the dispatch function correctly identifies the debug:serve command
    // (without actually starting the server which would block)
    const allocator = std.testing.allocator;

    // An unknown debug subcommand should return Explained error
    const result = dispatch(allocator, "debug:unknown", &.{});
    try std.testing.expectError(error.Explained, result);
}

test "cog debug serve --help prints debug help" {
    // Calling debug:serve with --help should print help and return without error
    const allocator = std.testing.allocator;
    const args = [_][:0]const u8{"--help"};
    // This should not error — it prints help text and returns
    try dispatch(allocator, "debug:serve", &args);
}
