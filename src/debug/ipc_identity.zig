const std = @import("std");
const builtin = @import("builtin");
const posix = std.posix;
const debug_log = @import("../debug_log.zig");

/// Security-relevant process properties collected before a daemon signal.
pub const ProcessSnapshot = struct {
    alive: bool,
    uid: posix.uid_t,
    executable_matches: bool,
};

/// Reasons a PID cannot be trusted as the current user's Cog daemon.
pub const ProcessValidationError = error{
    ProcessNotAlive,
    ProcessWrongUser,
    ProcessWrongExecutable,
};

/// Apply the platform-independent daemon process identity policy.
pub fn validateProcessSnapshot(snapshot: ProcessSnapshot, expected_uid: posix.uid_t) ProcessValidationError!void {
    if (!snapshot.alive) return error.ProcessNotAlive;
    if (snapshot.uid != expected_uid) return error.ProcessWrongUser;
    if (!snapshot.executable_matches) return error.ProcessWrongExecutable;
}

/// Require a connected Unix socket peer to have the current effective UID.
pub fn validatePeerUid(fd: posix.socket_t) !void {
    const peer_uid = try peerUid(fd);
    const expected_uid = posix.geteuid();
    if (peer_uid != expected_uid) {
        debug_log.log("debug IPC: rejected peer uid={d} expected={d}", .{ peer_uid, expected_uid });
        return error.PeerWrongUser;
    }
    debug_log.log("debug IPC: accepted peer uid={d}", .{peer_uid});
}

fn peerUid(fd: posix.socket_t) !posix.uid_t {
    return switch (builtin.os.tag) {
        .linux => linuxPeerUid(fd),
        .macos => macosPeerUid(fd),
        else => error.UnsupportedPlatform,
    };
}

fn linuxPeerUid(fd: posix.socket_t) !posix.uid_t {
    const UCred = extern struct {
        pid: posix.pid_t,
        uid: posix.uid_t,
        gid: posix.gid_t,
    };
    comptime {
        if (@sizeOf(UCred) != 12) @compileError("Linux ucred layout changed");
    }

    var credentials: UCred = undefined;
    try posix.getsockopt(
        fd,
        posix.SOL.SOCKET,
        std.os.linux.SO.PEERCRED,
        std.mem.asBytes(&credentials),
    );
    return credentials.uid;
}

fn macosPeerUid(fd: posix.socket_t) !posix.uid_t {
    const c_fns = struct {
        extern fn getpeereid(socket: c_int, euid: *posix.uid_t, egid: *posix.gid_t) c_int;
    };

    var uid: posix.uid_t = undefined;
    var gid: posix.gid_t = undefined;
    if (c_fns.getpeereid(fd, &uid, &gid) != 0) return error.PeerCredentialsUnavailable;
    return uid;
}

/// Create or replace a PID file as a no-follow, owner-only regular file.
pub fn writePidFile(path: []const u8, pid: posix.pid_t) !void {
    debug_log.log("debug IPC: opening pid file without symlink following {s}", .{path});
    const fd = try posix.open(path, .{
        .ACCMODE = .WRONLY,
        .CREAT = true,
        .TRUNC = true,
        .NOFOLLOW = true,
        .CLOEXEC = true,
    }, 0o600);
    defer posix.close(fd);

    try posix.fchmod(fd, 0o600);
    var buf: [32]u8 = undefined;
    const value = try std.fmt.bufPrint(&buf, "{d}\n", .{pid});
    try writeAll(fd, value);
    try posix.fsync(fd);
    debug_log.log("debug IPC: wrote pid={d} mode=0600 to {s}", .{ pid, path });
}

/// Read a PID only from a no-follow, current-user, mode-0600 regular file.
pub fn readPidFile(path: []const u8) !posix.pid_t {
    debug_log.log("debug IPC: reading pid file without symlink following {s}", .{path});
    const fd = try posix.open(path, .{
        .ACCMODE = .RDONLY,
        .NOFOLLOW = true,
        .CLOEXEC = true,
    }, 0);
    defer posix.close(fd);

    const stat = try posix.fstat(fd);
    if (stat.uid != posix.geteuid()) return error.PidFileWrongOwner;
    if (stat.mode & posix.S.IFMT != posix.S.IFREG) return error.PidFileNotRegular;
    if (stat.mode & 0o077 != 0) return error.PidFilePermissions;

    var buf: [32]u8 = undefined;
    const n = try posix.read(fd, &buf);
    if (n == 0 or n == buf.len) return error.InvalidPidFile;
    const value = std.mem.trim(u8, buf[0..n], " \n\r\t");
    const pid = try std.fmt.parseInt(posix.pid_t, value, 10);
    if (pid <= 0) return error.InvalidPidFile;
    return pid;
}

/// Prove a live PID belongs to the current UID and executes this Cog image.
pub fn validateProcessIdentity(pid: posix.pid_t) !void {
    const expected_uid = posix.geteuid();
    const snapshot = try processSnapshot(pid);
    validateProcessSnapshot(snapshot, expected_uid) catch |err| {
        debug_log.log("debug IPC: rejected pid={d}: {s}", .{ pid, @errorName(err) });
        return err;
    };
    debug_log.log("debug IPC: validated pid={d} uid={d} executable=cog", .{ pid, snapshot.uid });
}

/// Signal a validated daemon through a PID-reuse-resistant platform handle.
pub fn signalValidatedProcess(pid: posix.pid_t, signal: u8) !void {
    return switch (builtin.os.tag) {
        .linux => signalValidatedLinuxProcess(pid, signal),
        .macos => signalValidatedMacosProcess(pid, signal),
        else => error.UnsupportedPlatform,
    };
}

fn signalValidatedLinuxProcess(pid: posix.pid_t, signal: u8) !void {
    const linux = std.os.linux;
    const open_result = linux.pidfd_open(pid, 0);
    const pidfd = switch (linux.E.init(open_result)) {
        .SUCCESS => @as(posix.fd_t, @intCast(open_result)),
        .SRCH => return error.ProcessNotAlive,
        .NOSYS => {
            debug_log.log("debug IPC: pidfd unavailable; refusing numeric pid signal for pid={d}", .{pid});
            return error.ProcessIdentityUnavailable;
        },
        .PERM, .ACCES => return error.ProcessWrongUser,
        else => |err| return posix.unexpectedErrno(err),
    };
    defer posix.close(pidfd);

    try validateProcessIdentity(pid);
    debug_log.log("debug IPC: signaling validated pidfd for pid={d} signal={d}", .{ pid, signal });
    const send_result = linux.pidfd_send_signal(pidfd, signal, null, 0);
    switch (linux.E.init(send_result)) {
        .SUCCESS => {},
        .SRCH => return error.ProcessNotAlive,
        .PERM, .ACCES => return error.ProcessWrongUser,
        else => |err| return posix.unexpectedErrno(err),
    }
}

fn signalValidatedMacosProcess(pid: posix.pid_t, signal: u8) !void {
    const darwin = std.c;
    const AuditToken = extern struct {
        value: [8]u32,
    };
    const TASK_AUDIT_TOKEN: darwin.natural_t = 15;
    const c_fns = struct {
        extern fn task_name_for_pid(
            target_tport: darwin.mach_port_name_t,
            pid: c_int,
            task_name: *darwin.mach_port_name_t,
        ) darwin.kern_return_t;
        extern fn proc_pidpath_audittoken(token: *AuditToken, buffer: *anyopaque, buffer_size: u32) c_int;
        extern fn proc_signal_with_audittoken(token: *AuditToken, signal: c_int) c_int;
    };
    const AuditTokenToEuidFn = *const fn (AuditToken) callconv(.c) posix.uid_t;
    const AuditTokenToPidFn = *const fn (AuditToken) callconv(.c) posix.pid_t;

    var bsm = std.DynLib.open("/usr/lib/libbsm.dylib") catch {
        debug_log.log("debug IPC: libbsm unavailable for audit-token validation", .{});
        return error.ProcessIdentityUnavailable;
    };
    defer bsm.close();
    const audit_token_to_euid = bsm.lookup(AuditTokenToEuidFn, "audit_token_to_euid") orelse
        return error.ProcessIdentityUnavailable;
    const audit_token_to_pid = bsm.lookup(AuditTokenToPidFn, "audit_token_to_pid") orelse
        return error.ProcessIdentityUnavailable;

    var task_name: darwin.mach_port_name_t = 0;
    if (c_fns.task_name_for_pid(darwin.mach_task_self(), pid, &task_name) != 0) {
        debug_log.log("debug IPC: task identity unavailable for pid={d}", .{pid});
        return error.ProcessNotAlive;
    }
    defer _ = darwin.mach_port_deallocate(darwin.mach_task_self(), task_name);

    var token: AuditToken = undefined;
    var token_count: darwin.mach_msg_type_number_t = @sizeOf(AuditToken) / @sizeOf(darwin.natural_t);
    if (darwin.task_info(task_name, TASK_AUDIT_TOKEN, @ptrCast(&token), &token_count) != 0 or
        token_count != @sizeOf(AuditToken) / @sizeOf(darwin.natural_t))
    {
        debug_log.log("debug IPC: audit token unavailable for pid={d}", .{pid});
        return error.ProcessNotAlive;
    }

    const token_pid = audit_token_to_pid(token);
    const token_uid = audit_token_to_euid(token);
    if (token_pid != pid) return error.ProcessNotAlive;
    if (token_uid != posix.geteuid()) return error.ProcessWrongUser;

    var process_path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const process_path_len = c_fns.proc_pidpath_audittoken(&token, &process_path_buf, process_path_buf.len);
    if (process_path_len <= 0) return error.ProcessWrongExecutable;

    var process_file = std.fs.openFileAbsolute(process_path_buf[0..@intCast(process_path_len)], .{}) catch {
        return error.ProcessWrongExecutable;
    };
    defer process_file.close();
    const self_file = try std.fs.openSelfExe(.{});
    defer self_file.close();
    if (!sameExecutable(try posix.fstat(process_file.handle), try posix.fstat(self_file.handle))) {
        return error.ProcessWrongExecutable;
    }

    debug_log.log("debug IPC: signaling audit-token pid={d} uid={d} signal={d}", .{ pid, token_uid, signal });
    const signal_result = c_fns.proc_signal_with_audittoken(&token, signal);
    switch (posix.errno(signal_result)) {
        .SUCCESS => {},
        .SRCH => return error.ProcessNotAlive,
        .PERM, .ACCES => return error.ProcessWrongUser,
        else => |err| return posix.unexpectedErrno(err),
    }
}

fn processSnapshot(pid: posix.pid_t) !ProcessSnapshot {
    return switch (builtin.os.tag) {
        .linux => linuxProcessSnapshot(pid),
        .macos => macosProcessSnapshot(pid),
        else => error.UnsupportedPlatform,
    };
}

fn linuxProcessSnapshot(pid: posix.pid_t) !ProcessSnapshot {
    var proc_path_buf: [64]u8 = undefined;
    const proc_path = try std.fmt.bufPrint(&proc_path_buf, "/proc/{d}", .{pid});
    const proc_dir_fd = posix.open(proc_path, .{
        .ACCMODE = .RDONLY,
        .DIRECTORY = true,
        .NOFOLLOW = true,
        .CLOEXEC = true,
    }, 0) catch |err| return switch (err) {
        error.FileNotFound, error.ProcessNotFound => .{ .alive = false, .uid = 0, .executable_matches = false },
        else => err,
    };
    defer posix.close(proc_dir_fd);

    const proc_fd = posix.openat(proc_dir_fd, "exe", .{
        .ACCMODE = .RDONLY,
        .CLOEXEC = true,
    }, 0) catch |err| return switch (err) {
        error.FileNotFound, error.ProcessNotFound => .{ .alive = false, .uid = 0, .executable_matches = false },
        else => err,
    };
    defer posix.close(proc_fd);

    const self_file = try std.fs.openSelfExe(.{});
    defer self_file.close();

    const proc_dir_stat = try posix.fstat(proc_dir_fd);
    const proc_stat = try posix.fstat(proc_fd);
    const self_stat = try posix.fstat(self_file.handle);
    return .{
        .alive = true,
        .uid = proc_dir_stat.uid,
        .executable_matches = sameExecutable(proc_stat, self_stat),
    };
}

fn macosProcessSnapshot(pid: posix.pid_t) !ProcessSnapshot {
    const ProcBsdInfo = extern struct {
        pbi_flags: u32,
        pbi_status: u32,
        pbi_xstatus: u32,
        pbi_pid: u32,
        pbi_ppid: u32,
        pbi_uid: posix.uid_t,
        pbi_gid: posix.gid_t,
        pbi_ruid: posix.uid_t,
        pbi_rgid: posix.gid_t,
        pbi_svuid: posix.uid_t,
        pbi_svgid: posix.gid_t,
        rfu_1: u32,
        pbi_comm: [16]u8,
        pbi_name: [32]u8,
        pbi_nfiles: u32,
        pbi_pgid: u32,
        pbi_pjobc: u32,
        e_tdev: u32,
        e_tpgid: u32,
        pbi_nice: i32,
        pbi_start_tvsec: u64,
        pbi_start_tvusec: u64,
    };
    const PROC_PIDTBSDINFO = 3;
    const c_fns = struct {
        extern fn proc_pidinfo(pid: c_int, flavor: c_int, arg: u64, buffer: *anyopaque, buffer_size: c_int) c_int;
        extern fn proc_pidpath(pid: c_int, buffer: *anyopaque, buffer_size: u32) c_int;
    };

    var info: ProcBsdInfo = undefined;
    const info_size = c_fns.proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, @sizeOf(ProcBsdInfo));
    if (info_size != @sizeOf(ProcBsdInfo)) {
        return .{ .alive = false, .uid = 0, .executable_matches = false };
    }

    var process_path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const process_path_len = c_fns.proc_pidpath(pid, &process_path_buf, process_path_buf.len);
    if (process_path_len <= 0) {
        return .{ .alive = true, .uid = info.pbi_uid, .executable_matches = false };
    }

    var process_file = std.fs.openFileAbsolute(process_path_buf[0..@intCast(process_path_len)], .{}) catch {
        return .{ .alive = true, .uid = info.pbi_uid, .executable_matches = false };
    };
    defer process_file.close();
    const self_file = try std.fs.openSelfExe(.{});
    defer self_file.close();

    const process_stat = try posix.fstat(process_file.handle);
    const self_stat = try posix.fstat(self_file.handle);
    return .{
        .alive = true,
        .uid = info.pbi_uid,
        .executable_matches = sameExecutable(process_stat, self_stat),
    };
}

fn sameExecutable(a: posix.Stat, b: posix.Stat) bool {
    return @as(u64, @intCast(a.dev)) == @as(u64, @intCast(b.dev)) and
        @as(u64, @intCast(a.ino)) == @as(u64, @intCast(b.ino));
}

fn writeAll(fd: posix.fd_t, data: []const u8) !void {
    var offset: usize = 0;
    while (offset < data.len) {
        offset += try posix.write(fd, data[offset..]);
    }
}

fn currentPid() posix.pid_t {
    const c_fns = struct {
        extern fn getpid() posix.pid_t;
    };
    return c_fns.getpid();
}

test "validateProcessSnapshot accepts matching live Cog process" {
    try validateProcessSnapshot(.{
        .alive = true,
        .uid = 42,
        .executable_matches = true,
    }, 42);
}

test "validateProcessSnapshot rejects dead process" {
    try std.testing.expectError(error.ProcessNotAlive, validateProcessSnapshot(.{
        .alive = false,
        .uid = 42,
        .executable_matches = true,
    }, 42));
}

test "validateProcessSnapshot rejects foreign user" {
    try std.testing.expectError(error.ProcessWrongUser, validateProcessSnapshot(.{
        .alive = true,
        .uid = 43,
        .executable_matches = true,
    }, 42));
}

test "validateProcessSnapshot rejects foreign executable" {
    try std.testing.expectError(error.ProcessWrongExecutable, validateProcessSnapshot(.{
        .alive = true,
        .uid = 42,
        .executable_matches = false,
    }, 42));
}

test "writePidFile creates mode 0600 regular file and readPidFile parses it" {
    if (builtin.os.tag != .linux and builtin.os.tag != .macos) return error.SkipZigTest;

    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(root);
    const path = try std.fs.path.join(allocator, &.{ root, "daemon.pid" });
    defer allocator.free(path);

    try writePidFile(path, currentPid());
    try std.testing.expectEqual(currentPid(), try readPidFile(path));

    const stat = try std.posix.fstatat(std.posix.AT.FDCWD, path, std.posix.AT.SYMLINK_NOFOLLOW);
    try std.testing.expectEqual(@as(posix.mode_t, posix.S.IFREG), stat.mode & posix.S.IFMT);
    try std.testing.expectEqual(@as(posix.mode_t, 0o600), stat.mode & 0o777);
}

test "readPidFile rejects symlink" {
    if (builtin.os.tag != .linux and builtin.os.tag != .macos) return error.SkipZigTest;

    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(.{ .sub_path = "target.pid", .data = "123\n" });
    try tmp.dir.symLink("target.pid", "daemon.pid", .{});
    const root = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(root);
    const path = try std.fs.path.join(allocator, &.{ root, "daemon.pid" });
    defer allocator.free(path);

    try std.testing.expectError(error.SymLinkLoop, readPidFile(path));
}

test "readPidFile rejects permissive mode" {
    if (builtin.os.tag != .linux and builtin.os.tag != .macos) return error.SkipZigTest;

    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var file = try tmp.dir.createFile("daemon.pid", .{ .mode = 0o644 });
    try file.writeAll("123\n");
    try file.chmod(0o644);
    file.close();
    const root = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(root);
    const path = try std.fs.path.join(allocator, &.{ root, "daemon.pid" });
    defer allocator.free(path);

    try std.testing.expectError(error.PidFilePermissions, readPidFile(path));
}

test "validateProcessIdentity accepts current Cog test executable" {
    if (builtin.os.tag != .linux and builtin.os.tag != .macos) return error.SkipZigTest;
    try validateProcessIdentity(currentPid());
}

test "validateProcessIdentity rejects foreign executable fixture" {
    if (builtin.os.tag != .linux and builtin.os.tag != .macos) return error.SkipZigTest;

    const allocator = std.testing.allocator;
    var child = std.process.Child.init(&.{ "/bin/sh", "-c", "sleep 10" }, allocator);
    try child.spawn();
    defer {
        _ = child.kill() catch {};
        _ = child.wait() catch {};
    }

    // macOS spawn starts through a short-lived helper before exec; wait until
    // process identity reflects the foreign fixture rather than this test image.
    var attempts: u32 = 0;
    while (attempts < 100) : (attempts += 1) {
        if (validateProcessIdentity(child.id)) |_| {
            posix.nanosleep(0, 10_000_000);
        } else |err| {
            try std.testing.expectEqual(error.ProcessWrongExecutable, err);
            return;
        }
    }
    return error.ForeignFixtureDidNotExec;
}

test "signalValidatedProcess binds signal zero to current process identity" {
    if (builtin.os.tag != .linux and builtin.os.tag != .macos) return error.SkipZigTest;
    try signalValidatedProcess(currentPid(), 0);
}

test "signalValidatedProcess rejects foreign executable without signaling it" {
    if (builtin.os.tag != .linux and builtin.os.tag != .macos) return error.SkipZigTest;

    const allocator = std.testing.allocator;
    var child = std.process.Child.init(&.{ "/bin/sh", "-c", "sleep 10" }, allocator);
    try child.spawn();
    defer {
        _ = child.kill() catch {};
        _ = child.wait() catch {};
    }

    var attempts: u32 = 0;
    while (attempts < 100) : (attempts += 1) {
        if (signalValidatedProcess(child.id, 0)) |_| {
            posix.nanosleep(0, 10_000_000);
        } else |err| {
            try std.testing.expectEqual(error.ProcessWrongExecutable, err);
            return;
        }
    }
    return error.ForeignFixtureDidNotExec;
}

test "validatePeerUid accepts same-user Unix socket peer" {
    if (builtin.os.tag != .linux and builtin.os.tag != .macos) return error.SkipZigTest;

    var sockets: [2]posix.socket_t = undefined;
    if (std.c.socketpair(posix.AF.UNIX, posix.SOCK.STREAM, 0, &sockets) != 0) {
        return error.SocketPairFailed;
    }
    defer posix.close(sockets[0]);
    defer posix.close(sockets[1]);

    try validatePeerUid(sockets[0]);
    try validatePeerUid(sockets[1]);
}
