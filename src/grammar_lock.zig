const std = @import("std");
const builtin = @import("builtin");
const debug_log = @import("debug_log.zig");

const posix = std.posix;
var child_pgid = std.atomic.Value(i32).init(0);
var pending_signal = std.atomic.Value(i32).init(0);

pub fn main() !void {
    if (builtin.os.tag == .windows) return error.UnsupportedPlatform;

    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const args = try std.process.argsAlloc(allocator);
    if (args.len < 3) return error.InvalidArguments;

    const lock_path = args[1];
    debug_log.log("grammar_lock: opening directory {s}", .{lock_path});
    var lock_dir = try std.fs.cwd().openDir(lock_path, .{});
    defer lock_dir.close();
    const lock_file = std.fs.File{ .handle = lock_dir.fd };
    // The protected process group inherits this descriptor. If the wrapper is
    // hard-killed, the kernel lock therefore remains held until every child
    // that can still mutate setup state has exited.
    _ = try posix.fcntl(lock_file.handle, posix.F.SETFD, 0);

    const acquired = lock_file.tryLock(.exclusive) catch |err| {
        debug_log.log("grammar_lock: failed to lock directory {s}: {s}", .{ lock_path, @errorName(err) });
        return err;
    };
    if (!acquired) {
        debug_log.log("grammar_lock: active owner for directory {s}", .{lock_path});
        std.debug.print("error: grammar setup is already running\n", .{});
        return error.LockUnavailable;
    }
    // Do not explicitly unlock: closing the wrapper descriptor must not release
    // the inherited open-file-description lock while a child is still alive.
    debug_log.log("grammar_lock: acquired directory {s}", .{lock_path});

    installSignalForwarders();
    var child = std.process.Child.init(args[2..], allocator);
    child.stdin_behavior = .Inherit;
    child.stdout_behavior = .Inherit;
    child.stderr_behavior = .Inherit;
    child.pgid = 0;
    try child.spawn();
    const pgid: i32 = @intCast(child.id);
    child_pgid.store(pgid, .release);
    const queued_signal = pending_signal.swap(0, .acq_rel);
    if (queued_signal > 0) posix.kill(-pgid, @intCast(queued_signal)) catch {};
    const term = try child.wait();
    child_pgid.store(0, .release);
    pending_signal.store(0, .release);

    switch (term) {
        .Exited => |code| if (code != 0) std.process.exit(code),
        .Signal => |signal| std.process.exit(@intCast(128 + signal)),
        .Stopped => |signal| std.process.exit(@intCast(128 + signal)),
        .Unknown => |code| std.process.exit(@intCast(code)),
    }
}

fn installSignalForwarders() void {
    const action = posix.Sigaction{
        .handler = .{ .handler = forwardSignal },
        .mask = posix.sigemptyset(),
        .flags = 0,
    };
    posix.sigaction(posix.SIG.INT, &action, null);
    posix.sigaction(posix.SIG.TERM, &action, null);
    posix.sigaction(posix.SIG.HUP, &action, null);
}

fn forwardSignal(signal: c_int) callconv(.c) void {
    var pgid = child_pgid.load(.acquire);
    if (pgid > 0) {
        posix.kill(-pgid, @intCast(signal)) catch {};
        return;
    }

    pending_signal.store(signal, .release);
    // Close the spawn/publication race: either main observes pending_signal,
    // or this second load observes the published process group and forwards it.
    pgid = child_pgid.load(.acquire);
    if (pgid > 0) {
        const pending = pending_signal.swap(0, .acq_rel);
        if (pending > 0) posix.kill(-pgid, @intCast(pending)) catch {};
    }
}

test "an exclusive directory lock rejects a concurrent owner" {
    var temp_dir = std.testing.tmpDir(.{});
    defer temp_dir.cleanup();

    var first_dir = try temp_dir.dir.openDir(".", .{});
    defer first_dir.close();
    const first = std.fs.File{ .handle = first_dir.fd };
    try first.lock(.exclusive);
    defer first.unlock();

    var second_dir = try temp_dir.dir.openDir(".", .{});
    defer second_dir.close();
    const second = std.fs.File{ .handle = second_dir.fd };
    try std.testing.expect(!(try second.tryLock(.exclusive)));
}
