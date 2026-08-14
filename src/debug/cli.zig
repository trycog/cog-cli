const std = @import("std");
const Writer = std.io.Writer;
const posix = std.posix;
const ipc_identity = @import("ipc_identity.zig");
const debug_log = @import("../debug_log.zig");
const paths = @import("../paths.zig");

fn tryConnect(sock_path: []const u8) ?posix.socket_t {
    paths.validateUnixSocketPath(sock_path) catch |err| {
        debug_log.log("debug.cli.tryConnect: rejected path {s}: {s}", .{ sock_path, @errorName(err) });
        return null;
    };
    debug_log.log("debug.cli.tryConnect: connecting to {s}", .{sock_path});
    const sock = posix.socket(posix.AF.UNIX, posix.SOCK.STREAM | posix.SOCK.CLOEXEC, 0) catch |err| {
        debug_log.log("debug.cli.tryConnect: socket creation failed: {s}", .{@errorName(err)});
        return null;
    };

    var addr: posix.sockaddr.un = .{ .path = undefined };
    @memset(&addr.path, 0);
    @memcpy(addr.path[0..sock_path.len], sock_path);

    posix.connect(sock, @ptrCast(&addr), @sizeOf(posix.sockaddr.un)) catch |err| {
        debug_log.log("debug.cli.tryConnect: connection to {s} failed: {s}", .{ sock_path, @errorName(err) });
        posix.close(sock);
        return null;
    };
    ipc_identity.validatePeerUid(sock) catch |err| {
        debug_log.log("debug.cli.tryConnect: rejected daemon peer: {s}", .{@errorName(err)});
        posix.close(sock);
        return null;
    };

    debug_log.log("debug.cli.tryConnect: connected to authenticated peer at {s}", .{sock_path});
    return sock;
}

pub fn statusCommand(allocator: std.mem.Allocator) !void {
    const sock_path = paths.getDaemonSocketPath(allocator) catch |err| {
        debug_log.log("debug.cli.statusCommand: failed to resolve socket path: {s}", .{@errorName(err)});
        printErr("error: could not determine socket path\n");
        return error.Explained;
    };
    defer allocator.free(sock_path);
    paths.validateUnixSocketPath(sock_path) catch {
        printErr("error: daemon socket path is too long\n");
        return error.Explained;
    };

    const sock = tryConnect(sock_path) orelse {
        writeStdout("{\"running\":false}\n");
        return;
    };
    defer posix.close(sock);

    const request = "{\"tool\":\"debug_sessions\",\"args\":{}}";
    _ = posix.write(sock, request) catch {
        writeStdout("{\"running\":true,\"sessions\":\"unknown\"}\n");
        return;
    };
    _ = posix.write(sock, "\n") catch {};

    std.posix.shutdown(sock, .send) catch {};

    var resp_buf: [65536]u8 = undefined;
    var total: usize = 0;
    while (total < resp_buf.len) {
        const n = posix.read(sock, resp_buf[total..]) catch break;
        if (n == 0) break;
        total += n;
    }

    if (total > 0) {
        var aw: Writer.Allocating = .init(allocator);
        defer aw.deinit();
        aw.writer.writeAll("{\"running\":true,\"socket\":\"") catch return;
        aw.writer.writeAll(sock_path) catch return;
        aw.writer.writeAll("\",\"response\":") catch return;
        var resp = resp_buf[0..total];
        if (resp.len > 0 and resp[resp.len - 1] == '\n') resp = resp[0 .. resp.len - 1];
        aw.writer.writeAll(resp) catch return;
        aw.writer.writeByte('}') catch return;
        const output = aw.toOwnedSlice() catch return;
        defer allocator.free(output);
        writeStdout(output);
        writeStdout("\n");
    } else {
        writeStdout("{\"running\":true,\"sessions\":\"unknown\"}\n");
    }
}

pub fn killCommand(allocator: std.mem.Allocator) !void {
    const pid_path = paths.getDaemonPidPath(allocator) catch |err| {
        debug_log.log("debug.cli.killCommand: failed to resolve PID path: {s}", .{@errorName(err)});
        printErr("error: could not determine pid path\n");
        return error.Explained;
    };
    defer allocator.free(pid_path);

    const pid = ipc_identity.readPidFile(pid_path) catch |err| {
        debug_log.log("debug.cli.killCommand: rejected PID file {s}: {s}", .{ pid_path, @errorName(err) });
        if (err == error.FileNotFound) {
            printErr("error: no daemon running (no pid file)\n");
        } else {
            printErr("error: invalid or unsafe daemon pid file\n");
        }
        return error.Explained;
    };

    ipc_identity.signalValidatedProcess(pid, posix.SIG.TERM) catch |err| {
        debug_log.log("debug kill: refused to signal pid={d}: {s}", .{ pid, @errorName(err) });
        printErr("error: pid file does not identify a live Cog daemon owned by this user\n");
        return error.Explained;
    };

    writeStdout("{\"killed\":true}\n");

    debug_log.log("debug.cli.killCommand: removing {s}", .{pid_path});
    std.fs.deleteFileAbsolute(pid_path) catch |err| switch (err) {
        error.FileNotFound => {},
        else => debug_log.log("debug.cli.killCommand: failed to remove {s}: {s}", .{ pid_path, @errorName(err) }),
    };
}

fn printErr(msg: []const u8) void {
    if (@import("builtin").is_test) return;
    var buf: [4096]u8 = undefined;
    var w = std.fs.File.stderr().writerStreaming(&buf);
    w.interface.writeAll(msg) catch {};
    w.interface.flush() catch {};
}

fn writeStdout(msg: []const u8) void {
    if (@import("builtin").is_test) return;
    var buf: [65536]u8 = undefined;
    var w = std.fs.File.stdout().writerStreaming(&buf);
    w.interface.writeAll(msg) catch {};
    w.interface.flush() catch {};
}
