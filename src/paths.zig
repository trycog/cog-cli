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
        if (try isPrivateOwnedDirectory(xdg_runtime_dir)) {
            const path = try std.fs.path.join(allocator, &.{ xdg_runtime_dir, "cog" });
            errdefer allocator.free(path);
            try ensurePrivateRuntimeDir(path);
            debug_log.log("getRuntimeDir: using XDG runtime directory {s}", .{path});
            return path;
        }
        debug_log.log("getRuntimeDir: rejecting unsafe XDG_RUNTIME_DIR {s}", .{xdg_runtime_dir});
    }

    const home = std.posix.getenv("HOME") orelse return error.NoHome;
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
    return std.fs.path.join(allocator, &.{ runtime_dir, basename });
}

fn ensurePrivateRuntimeDir(path: []const u8) !void {
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

fn isPrivateOwnedDirectory(path: []const u8) !bool {
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

test "getRuntimePath accepts only basenames" {
    try std.testing.expectError(error.InvalidRuntimeBasename, getRuntimePath(std.testing.allocator, "../daemon.sock"));
    try std.testing.expectError(error.InvalidRuntimeBasename, getRuntimePath(std.testing.allocator, "nested/daemon.sock"));
}
