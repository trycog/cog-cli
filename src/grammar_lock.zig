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
    // The lock descriptor must outlive main (see below), so it is never
    // closed here; process exit reclaims it. .iterate forces a real
    // O_RDONLY|O_DIRECTORY descriptor: on Linux a plain openDir uses O_PATH,
    // and flock() on an O_PATH descriptor fails with EBADF, which
    // posix.flock treats as unreachable.
    const lock_dir = try std.fs.cwd().openDir(lock_path, .{ .iterate = true });
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
    trace("grammar-lock: lock acquired\n", .{});

    installSignalForwarders();

    // Direct fork/exec instead of std.process.Child: the child must own a
    // fresh process group so signals reach the whole tree, and Zig 0.15.2's
    // spawn error path panics inside an errdefer (destroyPipe on the unused
    // {-1,-1} progress pipe) whenever a child-side step fails, masking the
    // real error — observed on Linux aarch64 CI runners.
    const argv = try allocator.allocSentinel(?[*:0]const u8, args.len - 2, null);
    for (args[2..], 0..) |arg, i| argv[i] = arg.ptr;

    const pid = try posix.fork();
    if (pid == 0) {
        // Child: become a process-group leader, then exec the payload.
        posix.setpgid(0, 0) catch {};
        const envp: [*:null]const ?[*:0]const u8 = @ptrCast(std.os.environ.ptr);
        _ = posix.execvpeZ(argv[0].?, argv.ptr, envp) catch {};
        posix.exit(127);
    }

    debug_log.log("grammar_lock: spawned payload pid={d}", .{pid});
    trace("grammar-lock: spawned pid={d}\n", .{pid});
    child_pgid.store(@intCast(pid), .release);
    const queued_signal = pending_signal.swap(0, .acq_rel);
    if (queued_signal > 0) posix.kill(-pid, @intCast(queued_signal)) catch {};

    const wait_result = posix.waitpid(pid, 0);
    child_pgid.store(0, .release);
    pending_signal.store(0, .release);

    const status = wait_result.status;
    trace("grammar-lock: payload finished status={d}\n", .{status});
    if (posix.W.IFEXITED(status)) {
        std.process.exit(posix.W.EXITSTATUS(status));
    } else if (posix.W.IFSIGNALED(status)) {
        std.process.exit(@intCast(128 + @as(u8, @intCast(posix.W.TERMSIG(status)))));
    } else {
        std.process.exit(1);
    }
}

/// Stderr checkpoints for diagnosing wrapper behavior on CI runners; inert
/// unless COG_GRAMMAR_LOCK_TRACE is set.
fn trace(comptime fmt: []const u8, args: anytype) void {
    if (posix.getenv("COG_GRAMMAR_LOCK_TRACE") == null) return;
    std.debug.print(fmt, args);
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

    // .iterate avoids Linux O_PATH descriptors, which flock() rejects.
    var first_dir = try temp_dir.dir.openDir(".", .{ .iterate = true });
    defer first_dir.close();
    const first = std.fs.File{ .handle = first_dir.fd };
    try first.lock(.exclusive);
    defer first.unlock();

    var second_dir = try temp_dir.dir.openDir(".", .{ .iterate = true });
    defer second_dir.close();
    const second = std.fs.File{ .handle = second_dir.fd };
    try std.testing.expect(!(try second.tryLock(.exclusive)));
}
