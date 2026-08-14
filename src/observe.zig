pub const types = @import("observe/types.zig");
pub const schema = @import("observe/schema.zig");
pub const server = @import("observe/server.zig");
pub const session = @import("observe/session.zig");

const std = @import("std");
const help = @import("help_text.zig");
const tui = @import("tui.zig");
const debug_log = @import("debug_log.zig");
const settings = @import("settings.zig");

// ANSI styles
const dim = "\x1B[2m";
const reset = "\x1B[0m";

fn printErr(msg: []const u8) void {
    if (@import("builtin").is_test) return;
    var buf: [4096]u8 = undefined;
    var w = std.fs.File.stderr().writerStreaming(&buf);
    w.interface.writeAll(msg) catch {};
    w.interface.flush() catch {};
}

fn printCommandHelp(comptime help_text: []const u8) void {
    tui.header();
    printErr(help_text);
}

pub fn dispatch(allocator: std.mem.Allocator, subcmd: []const u8, args: []const [:0]const u8) !void {
    debug_log.log("observe.dispatch: subcmd={s}", .{subcmd});

    if (std.mem.eql(u8, subcmd, "observe:status")) {
        if (hasFlag(args, "--help") or hasFlag(args, "-h")) {
            printCommandHelp(help.observe_status);
            return;
        }
        printErr("Observe subsystem is not yet available. This feature is under development.\n");
        return;
    }

    if (std.mem.eql(u8, subcmd, "observe:sessions")) {
        if (hasFlag(args, "--help") or hasFlag(args, "-h")) {
            printCommandHelp(help.observe_sessions);
            return;
        }
        printErr("Observe subsystem is not yet available. This feature is under development.\n");
        return;
    }

    if (std.mem.eql(u8, subcmd, "observe:query")) {
        if (hasFlag(args, "--help") or hasFlag(args, "-h")) {
            printCommandHelp(help.observe_query);
            return;
        }
        printErr("Observe subsystem is not yet available. This feature is under development.\n");
        return;
    }

    if (std.mem.eql(u8, subcmd, "observe:export")) {
        if (hasFlag(args, "--help") or hasFlag(args, "-h")) {
            printCommandHelp(help.observe_export);
            return;
        }
        printErr("Observe subsystem is not yet available. This feature is under development.\n");
        return;
    }

    if (std.mem.eql(u8, subcmd, "observe:prune")) {
        if (hasFlag(args, "--help") or hasFlag(args, "-h")) {
            printCommandHelp(help.observe_prune);
            return;
        }
        if (args.len != 0) {
            debug_log.log("observe.prune: rejecting unexpected argument {s}", .{args[0]});
            printErr("error: observe:prune does not accept arguments\n");
            return error.Explained;
        }

        const retention_days = settings.observeRetentionDays(allocator);
        debug_log.log("observe.prune: starting retention_days={d}", .{retention_days});
        var manager = try session.SessionManager.init(allocator);
        defer manager.deinit();
        const pruned = try manager.pruneExpiredSessions(retention_days);
        debug_log.log("observe.prune: completed pruned={d}", .{pruned});

        const message = try std.fmt.allocPrint(
            allocator,
            "Pruned {d} expired finalized observation {s}.\n",
            .{ pruned, if (pruned == 1) "session" else "sessions" },
        );
        defer allocator.free(message);
        printErr(message);
        return;
    }

    printErr("error: unknown command '");
    printErr(subcmd);
    printErr("'\nRun " ++ dim ++ "cog observe" ++ reset ++ " to see available observe commands.\n");
    return error.Explained;
}

fn hasFlag(args: []const [:0]const u8, flag: []const u8) bool {
    for (args) |arg| {
        if (std.mem.eql(u8, arg, flag)) return true;
    }
    return false;
}

test {
    _ = types;
    _ = schema;
    _ = server;
    _ = session;
}
