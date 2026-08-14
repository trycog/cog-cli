const std = @import("std");
const builtin = @import("builtin");
const debug_log = @import("debug_log.zig");
const fs_util = @import("fs_util.zig");

/// Find .cog directory by walking up from cwd.
/// Stops at project boundaries (.git) to avoid escaping the current project.
/// Returns the absolute path to the .cog directory.
pub fn findCogDir(allocator: std.mem.Allocator) ![]const u8 {
    const home = std.posix.getenv("HOME") orelse return error.NoCogDir;

    var current = try std.fs.cwd().realpathAlloc(allocator, ".");
    defer allocator.free(current);

    while (true) {
        debug_log.log("findCogDir: checking {s}", .{current});
        var dir = std.fs.openDirAbsolute(current, .{}) catch {
            // Can't open dir, stop walking
            break;
        };
        defer dir.close();

        // Check for .cog/ directory
        const has_cog_dir = blk: {
            var cog_dir = dir.openDir(".cog", .{}) catch break :blk false;
            cog_dir.close();
            break :blk true;
        };
        if (has_cog_dir) {
            debug_log.log("findCogDir: found at {s}/.cog", .{current});
            const cog_path = try std.fmt.allocPrint(allocator, "{s}/.cog", .{current});
            errdefer allocator.free(cog_path);
            // Every consumer — settings, index.scip, temp paths — resolves
            // through this result, so the trust boundary is enforced here.
            try validateOwnedCogDir(cog_path);
            return cog_path;
        }

        // Stop at project root (.git directory or worktree file) so resolution
        // cannot escape into an enclosing repository.
        const has_git = blk: {
            _ = dir.statFile(".git") catch break :blk false;
            break :blk true;
        };
        if (has_git) {
            debug_log.log("findCogDir: stopped at git boundary {s}", .{current});
            break;
        }

        if (std.mem.eql(u8, current, home)) break;
        const parent = std.fs.path.dirname(current) orelse break;
        if (parent.len == current.len) break;
        const new_current = try allocator.dupe(u8, parent);
        allocator.free(current);
        current = new_current;
    }

    return error.NoCogDir;
}

/// Create .cog/ in cwd if it doesn't exist, with an empty settings.json.
/// Used by code/index to bootstrap without prior `cog init`.
pub fn findOrCreateCogDir(allocator: std.mem.Allocator) ![]const u8 {
    // Always operate on cwd — don't walk up
    std.fs.cwd().makeDir(".cog") catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return error.NoCogDir,
    };

    // A pre-existing `.cog` may be a committed symlink; refuse to write
    // bootstrap state through it or to trust a foreign-owned directory.
    {
        const cwd_path = std.fs.cwd().realpathAlloc(allocator, ".") catch return error.NoCogDir;
        defer allocator.free(cwd_path);
        const cog_path = try std.fs.path.join(allocator, &.{ cwd_path, ".cog" });
        defer allocator.free(cog_path);
        try validateOwnedCogDir(cog_path);
    }

    // Create pretty settings.json if it doesn't exist. Existing settings are
    // never replaced by this bootstrap path.
    var cog_dir = std.fs.cwd().openDir(".cog", .{}) catch return error.NoCogDir;
    defer cog_dir.close();
    cog_dir.access("settings.json", .{}) catch |err| switch (err) {
        error.FileNotFound => {
            debug_log.log("findOrCreateCogDir: creating .cog/settings.json", .{});
            fs_util.writeFileAtomicMode(cog_dir, allocator, "settings.json", "{}\n", 0o600) catch |write_err| {
                debug_log.log("findOrCreateCogDir: failed to create settings.json: {s}", .{@errorName(write_err)});
                return error.NoCogDir;
            };
        },
        else => {
            debug_log.log("findOrCreateCogDir: failed to inspect settings.json: {s}", .{@errorName(err)});
            return error.NoCogDir;
        },
    };

    return std.fs.cwd().realpathAlloc(allocator, ".cog");
}

/// Get the global config directory: ~/.config/cog/
pub fn getGlobalConfigDir(allocator: std.mem.Allocator) ![]const u8 {
    const home = std.posix.getenv("HOME") orelse return error.NoHome;
    return std.fmt.allocPrint(allocator, "{s}/.config/cog", .{home});
}

/// Resolve a private project-local directory for temporary subprocess output.
/// Keeping it under `.cog` lets sandboxed indexers write inside the project.
pub fn getProjectTempDir(allocator: std.mem.Allocator) ![]const u8 {
    const cog_dir = try findCogDir(allocator);
    defer allocator.free(cog_dir);
    try validateOwnedCogDir(cog_dir);

    const temp_dir = try std.fs.path.join(allocator, &.{ cog_dir, "tmp" });
    errdefer allocator.free(temp_dir);
    try ensurePrivateProjectTempDir(temp_dir);
    debug_log.log("getProjectTempDir: using {s}", .{temp_dir});
    return temp_dir;
}

/// Resolve Cog's private runtime directory. XDG_RUNTIME_DIR is used only when
/// it already belongs to the current user and is not group/world accessible.
/// Otherwise Cog falls back to ~/.cache/cog/runtime.
pub fn getRuntimeDir(allocator: std.mem.Allocator) ![]const u8 {
    if (std.posix.getenv("XDG_RUNTIME_DIR")) |xdg_runtime_dir| {
        if (std.fs.path.isAbsolute(xdg_runtime_dir) and try isPrivateOwnedDirectory(xdg_runtime_dir)) {
            const path = try std.fs.path.join(allocator, &.{ xdg_runtime_dir, "cog" });
            errdefer allocator.free(path);
            try ensurePrivateRuntimeDir(path);
            debug_log.log("getRuntimeDir: using XDG runtime directory {s}", .{path});
            return path;
        }
        debug_log.log("getRuntimeDir: rejecting unsafe XDG_RUNTIME_DIR {s}", .{xdg_runtime_dir});
    }

    const home = std.posix.getenv("HOME") orelse return error.NoHome;
    if (!std.fs.path.isAbsolute(home)) {
        debug_log.log("getRuntimeDir: rejecting non-absolute HOME {s}", .{home});
        return error.InvalidHome;
    }
    const path = try std.fs.path.join(allocator, &.{ home, ".cache", "cog", "runtime" });
    errdefer allocator.free(path);
    try ensurePrivateRuntimeDir(path);
    debug_log.log("getRuntimeDir: using fallback runtime directory {s}", .{path});
    return path;
}

/// Resolve a named path inside the private Cog runtime directory.
pub fn getRuntimePath(allocator: std.mem.Allocator, basename: []const u8) ![]const u8 {
    if (std.fs.path.basename(basename).len != basename.len or
        std.mem.eql(u8, basename, ".") or std.mem.eql(u8, basename, ".."))
    {
        return error.InvalidRuntimeBasename;
    }

    const runtime_dir = try getRuntimeDir(allocator);
    defer allocator.free(runtime_dir);
    const path = try std.fs.path.join(allocator, &.{ runtime_dir, basename });
    debug_log.log("getRuntimePath: resolved {s} to {s}", .{ basename, path });
    return path;
}

/// Resolve the debug daemon Unix socket path. Caller owns the returned path.
pub fn getDaemonSocketPath(allocator: std.mem.Allocator) ![]const u8 {
    return getRuntimePath(allocator, "daemon.sock");
}

/// Resolve the debug daemon PID file path. Caller owns the returned path.
pub fn getDaemonPidPath(allocator: std.mem.Allocator) ![]const u8 {
    return getRuntimePath(allocator, "daemon.pid");
}

/// Resolve the debug dashboard Unix socket path. Caller owns the returned path.
pub fn getDashboardSocketPath(allocator: std.mem.Allocator) ![]const u8 {
    return getRuntimePath(allocator, "dashboard.sock");
}

/// Resolve the CLI diagnostic log path. Caller owns the returned path.
pub fn getDiagnosticLogPath(allocator: std.mem.Allocator) ![]const u8 {
    return getRuntimePath(allocator, "cog.log");
}

const LegacyDebugPathKind = enum { daemon_socket, daemon_pid, dashboard_socket };

fn formatLegacyDebugPath(buffer: *[128]u8, kind: LegacyDebugPathKind, uid: std.posix.uid_t) ![]const u8 {
    return switch (kind) {
        .daemon_socket => std.fmt.bufPrint(buffer, "/tmp/cog-debug-{d}.sock", .{uid}),
        .daemon_pid => std.fmt.bufPrint(buffer, "/tmp/cog-debug-{d}.pid", .{uid}),
        .dashboard_socket => std.fmt.bufPrint(buffer, "/tmp/cog-debug-dashboard-{d}.sock", .{uid}),
    };
}

/// Emit a one-release diagnostic for retired shared runtime paths. Cog never
/// opens, trusts, signals through, or removes these nodes.
pub fn logLegacyDebugPaths() void {
    if (builtin.os.tag == .windows) return;

    const kinds = [_]LegacyDebugPathKind{ .daemon_socket, .daemon_pid, .dashboard_socket };
    var buffers: [kinds.len][128]u8 = undefined;
    for (kinds, 0..) |kind, index| {
        const path = formatLegacyDebugPath(&buffers[index], kind, std.posix.geteuid()) catch continue;
        _ = std.posix.fstatat(std.posix.AT.FDCWD, path, std.posix.AT.SYMLINK_NOFOLLOW) catch continue;
        debug_log.log("legacy debug runtime path detected and ignored: {s}; remove it manually after confirming no older Cog process uses it", .{path});
    }
}

/// Resolve the DAP diagnostic log path. Caller owns the returned path.
pub fn getDapLogPath(allocator: std.mem.Allocator) ![]const u8 {
    return getRuntimePath(allocator, "dap.log");
}

/// Ensure a Unix socket pathname leaves room for the required NUL terminator.
pub fn validateUnixSocketPath(path: []const u8) !void {
    const addr: std.posix.sockaddr.un = .{ .path = undefined };
    const capacity = addr.path.len;
    if (path.len >= capacity) {
        debug_log.log("validateUnixSocketPath: rejected {d}-byte path (capacity {d})", .{ path.len, capacity });
        return error.PathTooLong;
    }
    debug_log.log("validateUnixSocketPath: accepted {d}-byte path", .{path.len});
}

/// Held exclusive lock making one process the owner of a runtime socket path.
/// The liveness probe in `removeOwnedSocketIfPresent` narrows but cannot close
/// the same-user probe→unlink→bind race; every Cog starter must take this lock
/// before touching the socket path and hold it for the socket's lifetime, so a
/// second starter can neither steal a mid-bind endpoint nor unlink a
/// successor's socket at teardown.
pub const SocketOwnerLock = struct {
    fd: ?std.posix.fd_t,

    pub fn release(self: *SocketOwnerLock) void {
        if (self.fd) |fd| {
            // Closing the descriptor drops the flock.
            std.posix.close(fd);
            self.fd = null;
        }
    }
};

/// Acquire the exclusive owner lock for a runtime socket path. The lock file
/// lives beside the socket in the private runtime directory and is never
/// deleted, so the flock identity stays stable across owners.
pub fn acquireSocketOwnerLock(allocator: std.mem.Allocator, socket_path: []const u8) !SocketOwnerLock {
    if (builtin.os.tag == .windows) return .{ .fd = null };

    const lock_path = try std.fmt.allocPrint(allocator, "{s}.lock", .{socket_path});
    defer allocator.free(lock_path);

    const fd = try std.posix.open(lock_path, .{ .ACCMODE = .RDWR, .CREAT = true, .CLOEXEC = true }, 0o600);
    errdefer std.posix.close(fd);

    std.posix.flock(fd, std.posix.LOCK.EX | std.posix.LOCK.NB) catch |err| switch (err) {
        error.WouldBlock => {
            debug_log.log("acquireSocketOwnerLock: {s} is owned by another process", .{socket_path});
            return error.SocketOwnedElsewhere;
        },
        else => return err,
    };
    debug_log.log("acquireSocketOwnerLock: acquired {s}", .{lock_path});
    return .{ .fd = fd };
}

/// Remove a stale runtime socket only after proving it is an owned socket node.
/// Runtime directories are private, so the validated node cannot be replaced by
/// another user between this check and unlink. Callers that later bind the path
/// must serialize the whole takeover with `acquireSocketOwnerLock`.
pub fn removeOwnedSocketIfPresent(path: []const u8) !void {
    if (builtin.os.tag == .windows) {
        std.fs.deleteFileAbsolute(path) catch |err| switch (err) {
            error.FileNotFound => {},
            else => return err,
        };
        return;
    }

    const stat = std.posix.fstatat(std.posix.AT.FDCWD, path, std.posix.AT.SYMLINK_NOFOLLOW) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    const kind = stat.mode & std.posix.S.IFMT;
    if (kind == std.posix.S.IFLNK) {
        debug_log.log("removeOwnedSocketIfPresent: rejected symlink {s}", .{path});
        return error.RuntimePathSymlink;
    }
    if (kind != std.posix.S.IFSOCK) {
        debug_log.log("removeOwnedSocketIfPresent: rejected non-socket {s}", .{path});
        return error.RuntimePathNotSocket;
    }
    try validateRuntimeDirectoryOwner(path, stat.uid, std.posix.geteuid());

    if (unixSocketHasListener(path)) {
        debug_log.log("removeOwnedSocketIfPresent: preserving live socket {s}", .{path});
        return error.SocketInUse;
    }

    debug_log.log("removeOwnedSocketIfPresent: removing owned stale socket {s}", .{path});
    try std.fs.deleteFileAbsolute(path);
}

/// Probe whether a Unix socket path still has a live listener. Any ambiguous
/// probe result is treated as live so cleanup never unlinks an endpoint that
/// another same-user process is actively serving.
fn unixSocketHasListener(path: []const u8) bool {
    var address: std.posix.sockaddr.un = .{ .path = undefined };
    if (path.len >= address.path.len) return true;
    @memset(&address.path, 0);
    @memcpy(address.path[0..path.len], path);

    // Non-blocking: a saturated listener backlog must not stall startup, and
    // a connect that would block proves a listener exists anyway.
    const fd = std.posix.socket(std.posix.AF.UNIX, std.posix.SOCK.STREAM | std.posix.SOCK.CLOEXEC | std.posix.SOCK.NONBLOCK, 0) catch |err| {
        debug_log.log("unixSocketHasListener: probe socket failed: {s}; treating {s} as live", .{ @errorName(err), path });
        return true;
    };
    defer std.posix.close(fd);

    std.posix.connect(fd, @ptrCast(&address), @sizeOf(std.posix.sockaddr.un)) catch |err| switch (err) {
        error.ConnectionRefused => {
            debug_log.log("unixSocketHasListener: {s} refused the probe; stale", .{path});
            return false;
        },
        error.FileNotFound => return false,
        error.WouldBlock => {
            debug_log.log("unixSocketHasListener: {s} has a busy listener; live", .{path});
            return true;
        },
        else => {
            debug_log.log("unixSocketHasListener: probe error {s}; treating {s} as live", .{ @errorName(err), path });
            return true;
        },
    };
    debug_log.log("unixSocketHasListener: {s} accepted the probe; live", .{path});
    return true;
}

/// The project `.cog` directory is the trust boundary for temporary paths
/// handed to external indexers, which reopen them by name. Reject a symlinked
/// or foreign-owned `.cog` (a repository can commit `.cog` as a symlink), and
/// clear group/world write bits so no other account can swap entries under it
/// after validation.
fn validateOwnedCogDir(path: []const u8) !void {
    if (builtin.os.tag == .windows) return;

    const stat = try std.posix.fstatat(std.posix.AT.FDCWD, path, std.posix.AT.SYMLINK_NOFOLLOW);
    const kind = stat.mode & std.posix.S.IFMT;
    if (kind == std.posix.S.IFLNK) {
        debug_log.log("validateOwnedCogDir: rejected symlinked .cog {s}", .{path});
        return error.CogDirSymlink;
    }
    if (kind != std.posix.S.IFDIR) {
        debug_log.log("validateOwnedCogDir: rejected non-directory .cog {s}", .{path});
        return error.RuntimePathNotDirectory;
    }

    var dir = std.fs.openDirAbsolute(path, .{ .no_follow = true }) catch |err| {
        debug_log.log("validateOwnedCogDir: cannot open {s}: {s}", .{ path, @errorName(err) });
        return err;
    };
    defer dir.close();

    const open_stat = try std.posix.fstat(dir.fd);
    try validateRuntimeDirectoryOwner(path, open_stat.uid, std.posix.geteuid());
    if (open_stat.mode & 0o022 != 0) {
        debug_log.log("validateOwnedCogDir: clearing group/world write bits on {s}", .{path});
        try dir.chmod(open_stat.mode & 0o777 & ~@as(std.posix.mode_t, 0o022));
    }
}

fn ensurePrivateProjectTempDir(path: []const u8) !void {
    if (!std.fs.path.isAbsolute(path)) return error.InvalidProjectTempPath;

    if (pathExistsNoFollow(path)) {
        try validateRuntimeDirectoryNode(path);
    } else {
        std.fs.cwd().makeDir(path) catch |err| {
            debug_log.log("ensurePrivateProjectTempDir: failed to create {s}: {s}", .{ path, @errorName(err) });
            return err;
        };
    }

    var dir = std.fs.openDirAbsolute(path, .{ .iterate = true, .no_follow = true }) catch |err| {
        debug_log.log("ensurePrivateProjectTempDir: rejected {s}: {s}", .{ path, @errorName(err) });
        return err;
    };
    defer dir.close();

    if (builtin.os.tag != .windows) {
        const stat = try std.posix.fstat(dir.fd);
        try validateRuntimeDirectoryOwner(path, stat.uid, std.posix.geteuid());
        if (stat.mode & 0o077 != 0) try dir.chmod(0o700);
    }
}

fn ensurePrivateRuntimeDir(path: []const u8) !void {
    if (!std.fs.path.isAbsolute(path)) return error.InvalidRuntimePath;
    try validateExistingDirectoryChain(path);

    if (pathExistsNoFollow(path)) {
        try validateRuntimeDirectoryNode(path);
    } else {
        std.fs.cwd().makePath(path) catch |err| {
            debug_log.log("ensurePrivateRuntimeDir: failed to create {s}: {s}", .{ path, @errorName(err) });
            return err;
        };
    }

    var dir = std.fs.openDirAbsolute(path, .{ .iterate = true, .no_follow = true }) catch |err| {
        debug_log.log("ensurePrivateRuntimeDir: rejected {s}: {s}", .{ path, @errorName(err) });
        return err;
    };
    defer dir.close();

    if (builtin.os.tag != .windows) {
        const stat = try std.posix.fstat(dir.fd);
        try validateRuntimeDirectoryOwner(path, stat.uid, std.posix.geteuid());
        if (stat.mode & 0o077 != 0) {
            debug_log.log("ensurePrivateRuntimeDir: restricting permissions on {s}", .{path});
            try dir.chmod(0o700);
        }
    }
}

fn validateRuntimeDirectoryOwner(path: []const u8, actual_uid: std.posix.uid_t, expected_uid: std.posix.uid_t) !void {
    if (actual_uid == expected_uid) return;
    debug_log.log("ensurePrivateRuntimeDir: rejected foreign owner for {s} actual_uid={d} expected_uid={d}", .{ path, actual_uid, expected_uid });
    return error.RuntimeDirWrongOwner;
}

fn validateExistingDirectoryChain(path: []const u8) !void {
    if (builtin.os.tag == .windows) return;

    var iterator = try std.fs.path.componentIterator(path);
    while (iterator.next()) |component| {
        const stat = std.posix.fstatat(std.posix.AT.FDCWD, component.path, std.posix.AT.SYMLINK_NOFOLLOW) catch |err| switch (err) {
            error.FileNotFound => return,
            else => return err,
        };
        const kind = stat.mode & std.posix.S.IFMT;
        if (kind == std.posix.S.IFLNK) {
            debug_log.log("ensurePrivateRuntimeDir: rejected parent symlink {s}", .{component.path});
            return error.RuntimeDirSymlink;
        }
        if (kind != std.posix.S.IFDIR) {
            debug_log.log("ensurePrivateRuntimeDir: rejected non-directory parent {s}", .{component.path});
            return error.RuntimePathNotDirectory;
        }
    }
}

fn isPrivateOwnedDirectory(path: []const u8) !bool {
    if (!std.fs.path.isAbsolute(path)) return false;
    var dir = std.fs.openDirAbsolute(path, .{ .no_follow = true }) catch return false;
    defer dir.close();

    if (builtin.os.tag == .windows) return true;
    const stat = try std.posix.fstat(dir.fd);
    return stat.uid == std.posix.geteuid() and stat.mode & 0o077 == 0;
}

fn pathExistsNoFollow(path: []const u8) bool {
    if (builtin.os.tag == .windows) {
        var dir = std.fs.openDirAbsolute(path, .{ .no_follow = true }) catch return false;
        dir.close();
        return true;
    }
    _ = std.posix.fstatat(std.posix.AT.FDCWD, path, std.posix.AT.SYMLINK_NOFOLLOW) catch return false;
    return true;
}

fn validateRuntimeDirectoryNode(path: []const u8) !void {
    if (builtin.os.tag == .windows) return;
    const stat = try std.posix.fstatat(std.posix.AT.FDCWD, path, std.posix.AT.SYMLINK_NOFOLLOW);
    const kind = stat.mode & std.posix.S.IFMT;
    if (kind == std.posix.S.IFLNK) {
        debug_log.log("ensurePrivateRuntimeDir: rejected symlink {s}", .{path});
        return error.RuntimeDirSymlink;
    }
    if (kind != std.posix.S.IFDIR) {
        debug_log.log("ensurePrivateRuntimeDir: rejected non-directory {s}", .{path});
        return error.RuntimePathNotDirectory;
    }
}

test "findOrCreateCogDir creates pretty settings without replacing existing content" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var original_cwd = try std.fs.cwd().openDir(".", .{});
    defer {
        original_cwd.setAsCwd() catch unreachable;
        original_cwd.close();
    }
    try tmp.dir.setAsCwd();

    const first = try findOrCreateCogDir(allocator);
    allocator.free(first);
    const initial = try std.fs.cwd().readFileAlloc(allocator, ".cog/settings.json", 1024);
    defer allocator.free(initial);
    try std.testing.expectEqualStrings("{}\n", initial);
    if (builtin.os.tag != .windows) {
        const stat = try std.fs.cwd().statFile(".cog/settings.json");
        try std.testing.expectEqual(@as(std.fs.File.Mode, 0o600), stat.mode & 0o777);
    }

    try fs_util.writeFileAtomic(std.fs.cwd(), allocator, ".cog/settings.json", "{\n  \"custom\": true\n}\n");
    const second = try findOrCreateCogDir(allocator);
    allocator.free(second);
    const preserved = try std.fs.cwd().readFileAlloc(allocator, ".cog/settings.json", 1024);
    defer allocator.free(preserved);
    try std.testing.expectEqualStrings("{\n  \"custom\": true\n}\n", preserved);
}

test "getProjectTempDir creates a private directory under .cog" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var original_cwd = try std.fs.cwd().openDir(".", .{});
    defer {
        original_cwd.setAsCwd() catch unreachable;
        original_cwd.close();
    }
    try tmp.dir.makeDir(".cog");
    try tmp.dir.setAsCwd();

    const temp_dir = try getProjectTempDir(allocator);
    defer allocator.free(temp_dir);

    const cog_dir = try std.fs.cwd().realpathAlloc(allocator, ".cog");
    defer allocator.free(cog_dir);
    const expected = try std.fs.path.join(allocator, &.{ cog_dir, "tmp" });
    defer allocator.free(expected);
    try std.testing.expectEqualStrings(expected, temp_dir);

    var dir = try std.fs.openDirAbsolute(temp_dir, .{ .iterate = true });
    defer dir.close();
    const stat = try std.posix.fstat(dir.fd);
    try std.testing.expectEqual(@as(std.fs.File.Mode, 0o700), stat.mode & 0o777);
}

test "findCogDir rejects a symlinked .cog directory" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var original_cwd = try std.fs.cwd().openDir(".", .{});
    defer {
        original_cwd.setAsCwd() catch unreachable;
        original_cwd.close();
    }
    try tmp.dir.makeDir("outside");
    try tmp.dir.symLink("outside", ".cog", .{ .is_directory = true });
    try tmp.dir.setAsCwd();

    try std.testing.expectError(error.CogDirSymlink, findCogDir(allocator));
}

test "findOrCreateCogDir rejects a symlinked .cog directory" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var original_cwd = try std.fs.cwd().openDir(".", .{});
    defer {
        original_cwd.setAsCwd() catch unreachable;
        original_cwd.close();
    }
    // Bootstrap must not write settings.json through a committed symlink.
    try tmp.dir.makeDir("outside");
    try tmp.dir.symLink("outside", ".cog", .{ .is_directory = true });
    try tmp.dir.setAsCwd();

    try std.testing.expectError(error.CogDirSymlink, findOrCreateCogDir(allocator));
    try std.testing.expectError(error.FileNotFound, tmp.dir.access("outside/settings.json", .{}));
}

test "getProjectTempDir rejects a symlinked .cog directory" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var original_cwd = try std.fs.cwd().openDir(".", .{});
    defer {
        original_cwd.setAsCwd() catch unreachable;
        original_cwd.close();
    }
    // A repository can commit `.cog` as a symlink; everything below it would
    // resolve outside the project trust boundary.
    try tmp.dir.makeDir("outside");
    try tmp.dir.symLink("outside", ".cog", .{ .is_directory = true });
    try tmp.dir.setAsCwd();

    try std.testing.expectError(error.CogDirSymlink, getProjectTempDir(allocator));
}

test "getProjectTempDir clears group and world write bits on .cog" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var original_cwd = try std.fs.cwd().openDir(".", .{});
    defer {
        original_cwd.setAsCwd() catch unreachable;
        original_cwd.close();
    }
    try tmp.dir.makeDir(".cog");
    var cog = try tmp.dir.openDir(".cog", .{});
    defer cog.close();
    try cog.chmod(0o777);
    try tmp.dir.setAsCwd();

    const temp_dir = try getProjectTempDir(allocator);
    defer allocator.free(temp_dir);

    // Another account with write access to `.cog` could swap `tmp` out after
    // validation, so the write bits must be gone before the path is trusted.
    const stat = try std.posix.fstat(cog.fd);
    try std.testing.expectEqual(@as(std.posix.mode_t, 0o755), stat.mode & 0o777);
}

test "getProjectTempDir rejects a symlinked temp directory" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var original_cwd = try std.fs.cwd().openDir(".", .{});
    defer {
        original_cwd.setAsCwd() catch unreachable;
        original_cwd.close();
    }
    try tmp.dir.makeDir(".cog");
    try tmp.dir.makeDir("outside");
    try tmp.dir.symLink("../outside", ".cog/tmp", .{ .is_directory = true });
    try tmp.dir.setAsCwd();

    try std.testing.expectError(error.RuntimeDirSymlink, getProjectTempDir(allocator));
}

test "ensurePrivateRuntimeDir creates mode 0700 directories" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(root);
    const runtime_dir = try std.fs.path.join(allocator, &.{ root, "nested", "runtime" });
    defer allocator.free(runtime_dir);

    try ensurePrivateRuntimeDir(runtime_dir);

    var dir = try std.fs.openDirAbsolute(runtime_dir, .{ .iterate = true });
    defer dir.close();
    const stat = try std.posix.fstat(dir.fd);
    try std.testing.expectEqual(std.posix.geteuid(), stat.uid);
    try std.testing.expectEqual(@as(std.fs.File.Mode, 0o700), stat.mode & 0o777);
}

test "ensurePrivateRuntimeDir restricts an existing directory" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.makeDir("runtime");
    var created = try tmp.dir.openDir("runtime", .{ .iterate = true });
    try created.chmod(0o755);
    created.close();

    const runtime_dir = try tmp.dir.realpathAlloc(allocator, "runtime");
    defer allocator.free(runtime_dir);
    try ensurePrivateRuntimeDir(runtime_dir);

    var dir = try std.fs.openDirAbsolute(runtime_dir, .{ .iterate = true });
    defer dir.close();
    const stat = try std.posix.fstat(dir.fd);
    try std.testing.expectEqual(@as(std.fs.File.Mode, 0o700), stat.mode & 0o777);
}

test "ensurePrivateRuntimeDir rejects symlinks" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.makeDir("target");
    try tmp.dir.symLink("target", "runtime", .{ .is_directory = true });
    const root = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(root);
    const runtime_dir = try std.fs.path.join(allocator, &.{ root, "runtime" });
    defer allocator.free(runtime_dir);

    try std.testing.expectError(error.RuntimeDirSymlink, ensurePrivateRuntimeDir(runtime_dir));
}

test "ensurePrivateRuntimeDir rejects a symlinked parent" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.makeDir("outside");
    try tmp.dir.symLink("outside", "cache", .{ .is_directory = true });
    const root = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(root);
    const runtime_dir = try std.fs.path.join(allocator, &.{ root, "cache", "cog", "runtime" });
    defer allocator.free(runtime_dir);

    try std.testing.expectError(error.RuntimeDirSymlink, ensurePrivateRuntimeDir(runtime_dir));
    try std.testing.expectError(error.FileNotFound, tmp.dir.access("outside/cog", .{}));
}

test "runtime directory ownership rejects a foreign uid" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    const effective_uid = std.posix.geteuid();
    const foreign_uid = if (effective_uid == std.math.maxInt(@TypeOf(effective_uid))) effective_uid - 1 else effective_uid + 1;
    try std.testing.expectError(
        error.RuntimeDirWrongOwner,
        validateRuntimeDirectoryOwner("/private/runtime", foreign_uid, effective_uid),
    );
    try validateRuntimeDirectoryOwner("/private/runtime", effective_uid, effective_uid);
}

test "getRuntimeDir ignores an empty XDG runtime path" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const original_home = std.posix.getenv("HOME");
    const original_xdg = std.posix.getenv("XDG_RUNTIME_DIR");
    const home = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(home);
    try setEnv("HOME", home);
    try setEnv("XDG_RUNTIME_DIR", "");
    defer {
        if (original_home) |value| setEnv("HOME", value) catch {} else unsetEnv("HOME");
        if (original_xdg) |value| setEnv("XDG_RUNTIME_DIR", value) catch {} else unsetEnv("XDG_RUNTIME_DIR");
    }

    const runtime_dir = try getRuntimeDir(allocator);
    defer allocator.free(runtime_dir);
    const expected = try std.fs.path.join(allocator, &.{ home, ".cache", "cog", "runtime" });
    defer allocator.free(expected);
    try std.testing.expectEqualStrings(expected, runtime_dir);
}

test "getRuntimeDir ignores a relative XDG runtime path" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const original_home = std.posix.getenv("HOME");
    const original_xdg = std.posix.getenv("XDG_RUNTIME_DIR");
    const home = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(home);
    try setEnv("HOME", home);
    try setEnv("XDG_RUNTIME_DIR", "relative/runtime");
    defer {
        if (original_home) |value| setEnv("HOME", value) catch {} else unsetEnv("HOME");
        if (original_xdg) |value| setEnv("XDG_RUNTIME_DIR", value) catch {} else unsetEnv("XDG_RUNTIME_DIR");
    }

    const runtime_dir = try getRuntimeDir(allocator);
    defer allocator.free(runtime_dir);
    const expected = try std.fs.path.join(allocator, &.{ home, ".cache", "cog", "runtime" });
    defer allocator.free(expected);
    try std.testing.expectEqualStrings(expected, runtime_dir);
}

test "getRuntimePath accepts only basenames" {
    try std.testing.expectError(error.InvalidRuntimeBasename, getRuntimePath(std.testing.allocator, "../daemon.sock"));
    try std.testing.expectError(error.InvalidRuntimeBasename, getRuntimePath(std.testing.allocator, "nested/daemon.sock"));
}

test "legacy debug diagnostics identify the retired shared paths" {
    var buffer: [128]u8 = undefined;
    try std.testing.expectEqualStrings("/tmp/cog-debug-42.sock", try formatLegacyDebugPath(&buffer, .daemon_socket, 42));
    try std.testing.expectEqualStrings("/tmp/cog-debug-42.pid", try formatLegacyDebugPath(&buffer, .daemon_pid, 42));
    try std.testing.expectEqualStrings("/tmp/cog-debug-dashboard-42.sock", try formatLegacyDebugPath(&buffer, .dashboard_socket, 42));
}

test "named runtime paths are allocator-owned private paths" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const original_home = std.posix.getenv("HOME");
    const original_xdg = std.posix.getenv("XDG_RUNTIME_DIR");
    const home = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(home);
    try setEnv("HOME", home);
    unsetEnv("XDG_RUNTIME_DIR");
    defer {
        if (original_home) |value| setEnv("HOME", value) catch {} else unsetEnv("HOME");
        if (original_xdg) |value| setEnv("XDG_RUNTIME_DIR", value) catch {} else unsetEnv("XDG_RUNTIME_DIR");
    }

    const runtime_dir = try getRuntimeDir(allocator);
    defer allocator.free(runtime_dir);
    const daemon_socket = try getDaemonSocketPath(allocator);
    defer allocator.free(daemon_socket);
    const daemon_pid = try getDaemonPidPath(allocator);
    defer allocator.free(daemon_pid);
    const dashboard_socket = try getDashboardSocketPath(allocator);
    defer allocator.free(dashboard_socket);
    const diagnostic_log = try getDiagnosticLogPath(allocator);
    defer allocator.free(diagnostic_log);
    const dap_log = try getDapLogPath(allocator);
    defer allocator.free(dap_log);

    try std.testing.expectEqualStrings("daemon.sock", std.fs.path.basename(daemon_socket));
    try std.testing.expectEqualStrings("daemon.pid", std.fs.path.basename(daemon_pid));
    try std.testing.expectEqualStrings("dashboard.sock", std.fs.path.basename(dashboard_socket));
    try std.testing.expectEqualStrings("cog.log", std.fs.path.basename(diagnostic_log));
    try std.testing.expectEqualStrings("dap.log", std.fs.path.basename(dap_log));
    try std.testing.expectEqualStrings(runtime_dir, std.fs.path.dirname(daemon_socket).?);
    try std.testing.expectEqualStrings(runtime_dir, std.fs.path.dirname(daemon_pid).?);
    try std.testing.expectEqualStrings(runtime_dir, std.fs.path.dirname(dashboard_socket).?);
    try std.testing.expectEqualStrings(runtime_dir, std.fs.path.dirname(diagnostic_log).?);
    try std.testing.expectEqualStrings(runtime_dir, std.fs.path.dirname(dap_log).?);
}

test "unix socket path validation reserves NUL terminator" {
    const addr: std.posix.sockaddr.un = .{ .path = undefined };
    const exact_capacity = try allocatorFilledPath(std.testing.allocator, addr.path.len);
    defer std.testing.allocator.free(exact_capacity);
    const fits = try allocatorFilledPath(std.testing.allocator, addr.path.len - 1);
    defer std.testing.allocator.free(fits);

    try std.testing.expectError(error.PathTooLong, validateUnixSocketPath(exact_capacity));
    try validateUnixSocketPath(fits);
}

test "removeOwnedSocketIfPresent rejects regular files and symlinks" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(.{ .sub_path = "regular", .data = "do not remove\n" });
    try tmp.dir.symLink("regular", "link", .{});

    const regular = try tmp.dir.realpathAlloc(allocator, "regular");
    defer allocator.free(regular);
    const root = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(root);
    const link = try std.fs.path.join(allocator, &.{ root, "link" });
    defer allocator.free(link);

    try std.testing.expectError(error.RuntimePathNotSocket, removeOwnedSocketIfPresent(regular));
    try std.testing.expectError(error.RuntimePathSymlink, removeOwnedSocketIfPresent(link));
    try tmp.dir.access("regular", .{});
    try tmp.dir.access("link", .{});
}

test "removeOwnedSocketIfPresent removes an owned Unix socket" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(root);
    const socket_path = try std.fs.path.join(allocator, &.{ root, "owned.sock" });
    defer allocator.free(socket_path);
    try validateUnixSocketPath(socket_path);

    const socket = try std.posix.socket(std.posix.AF.UNIX, std.posix.SOCK.STREAM, 0);
    defer std.posix.close(socket);
    var address: std.posix.sockaddr.un = .{ .path = undefined };
    @memset(&address.path, 0);
    @memcpy(address.path[0..socket_path.len], socket_path);
    try std.posix.bind(socket, @ptrCast(&address), @sizeOf(std.posix.sockaddr.un));

    try removeOwnedSocketIfPresent(socket_path);
    try std.testing.expectError(error.FileNotFound, std.fs.cwd().access(socket_path, .{}));
}

test "socket owner lock excludes concurrent takeover" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(root);
    const socket_path = try std.fs.path.join(allocator, &.{ root, "owned.sock" });
    defer allocator.free(socket_path);

    var lock = try acquireSocketOwnerLock(allocator, socket_path);
    // flock is per open file description, so a second acquisition conflicts
    // even inside one process.
    try std.testing.expectError(error.SocketOwnedElsewhere, acquireSocketOwnerLock(allocator, socket_path));
    lock.release();

    var second = try acquireSocketOwnerLock(allocator, socket_path);
    second.release();
}

test "removeOwnedSocketIfPresent preserves a live listening socket" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(root);
    const socket_path = try std.fs.path.join(allocator, &.{ root, "live.sock" });
    defer allocator.free(socket_path);
    try validateUnixSocketPath(socket_path);

    const socket = try std.posix.socket(std.posix.AF.UNIX, std.posix.SOCK.STREAM, 0);
    defer std.posix.close(socket);
    var address: std.posix.sockaddr.un = .{ .path = undefined };
    @memset(&address.path, 0);
    @memcpy(address.path[0..socket_path.len], socket_path);
    try std.posix.bind(socket, @ptrCast(&address), @sizeOf(std.posix.sockaddr.un));
    try std.posix.listen(socket, 1);

    // A second same-user process must not unlink an endpoint that another
    // daemon is actively serving.
    try std.testing.expectError(error.SocketInUse, removeOwnedSocketIfPresent(socket_path));
    try tmp.dir.access("live.sock", .{});
}

fn allocatorFilledPath(allocator: std.mem.Allocator, len: usize) ![]u8 {
    const path = try allocator.alloc(u8, len);
    @memset(path, 'x');
    return path;
}

fn setEnv(name: []const u8, value: []const u8) !void {
    const c_fns = struct {
        extern fn setenv([*:0]const u8, [*:0]const u8, c_int) c_int;
    };
    const name_z = try std.testing.allocator.dupeZ(u8, name);
    defer std.testing.allocator.free(name_z);
    const value_z = try std.testing.allocator.dupeZ(u8, value);
    defer std.testing.allocator.free(value_z);
    if (c_fns.setenv(name_z, value_z, 1) != 0) return error.SetEnvFailed;
}

fn unsetEnv(name: []const u8) void {
    const c_fns = struct {
        extern fn unsetenv([*:0]const u8) c_int;
    };
    const name_z = std.testing.allocator.dupeZ(u8, name) catch return;
    defer std.testing.allocator.free(name_z);
    _ = c_fns.unsetenv(name_z);
}

test "findCogDir stops at git file worktree boundary" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.makePath(".cog");
    try tmp.dir.makePath("repo/nested");
    var git_file = try tmp.dir.createFile("repo/.git", .{});
    git_file.close();

    var nested = try tmp.dir.openDir("repo/nested", .{});
    defer nested.close();
    var old_cwd = try std.fs.cwd().openDir(".", .{});
    defer {
        old_cwd.setAsCwd() catch {};
        old_cwd.close();
    }
    try nested.setAsCwd();

    try std.testing.expectError(error.NoCogDir, findCogDir(std.testing.allocator));
}
