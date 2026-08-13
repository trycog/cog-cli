const std = @import("std");
const builtin = @import("builtin");
const debug_log = @import("debug_log.zig");

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
            return std.fmt.allocPrint(allocator, "{s}/.cog", .{current});
        }

        // Stop at project root (.git boundary) — don't escape into parent projects
        const has_git = blk: {
            var git_dir = dir.openDir(".git", .{}) catch break :blk false;
            git_dir.close();
            break :blk true;
        };
        if (has_git) break;

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

    // Create empty settings.json if it doesn't exist
    var cog_dir = std.fs.cwd().openDir(".cog", .{}) catch return error.NoCogDir;
    defer cog_dir.close();
    if (cog_dir.openFile("settings.json", .{})) |f| {
        f.close();
    } else |_| {
        // Doesn't exist — create it
        const f = cog_dir.createFile("settings.json", .{}) catch return error.NoCogDir;
        defer f.close();
        f.writeAll("{}\n") catch {};
    }

    return std.fs.cwd().realpathAlloc(allocator, ".cog");
}

/// Get the global config directory: ~/.config/cog/
pub fn getGlobalConfigDir(allocator: std.mem.Allocator) ![]const u8 {
    const home = std.posix.getenv("HOME") orelse return error.NoHome;
    return std.fmt.allocPrint(allocator, "{s}/.config/cog", .{home});
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
        if (stat.uid != std.posix.geteuid()) {
            debug_log.log("ensurePrivateRuntimeDir: rejected foreign owner for {s}", .{path});
            return error.RuntimeDirWrongOwner;
        }
        if (stat.mode & 0o077 != 0) {
            debug_log.log("ensurePrivateRuntimeDir: restricting permissions on {s}", .{path});
            try dir.chmod(0o700);
        }
    }
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
    const dap_log = try getDapLogPath(allocator);
    defer allocator.free(dap_log);

    try std.testing.expectEqualStrings("daemon.sock", std.fs.path.basename(daemon_socket));
    try std.testing.expectEqualStrings("daemon.pid", std.fs.path.basename(daemon_pid));
    try std.testing.expectEqualStrings("dashboard.sock", std.fs.path.basename(dashboard_socket));
    try std.testing.expectEqualStrings("dap.log", std.fs.path.basename(dap_log));
    try std.testing.expectEqualStrings(runtime_dir, std.fs.path.dirname(daemon_socket).?);
    try std.testing.expectEqualStrings(runtime_dir, std.fs.path.dirname(daemon_pid).?);
    try std.testing.expectEqualStrings(runtime_dir, std.fs.path.dirname(dashboard_socket).?);
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
