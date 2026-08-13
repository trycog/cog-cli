const std = @import("std");
const builtin = @import("builtin");
const debug_log = @import("debug_log.zig");

var temp_counter = std.atomic.Value(u64).init(0);

/// Replace a file through a sibling temporary file so readers see either the
/// previous complete contents or the new complete contents. Existing Unix
/// permissions are preserved; callers may select the mode for newly-created
/// files.
pub fn writeFileAtomic(dir: std.fs.Dir, allocator: std.mem.Allocator, sub_path: []const u8, data: []const u8) !void {
    return writeFileAtomicMode(dir, allocator, sub_path, data, std.fs.File.default_mode);
}

pub fn writeFileAtomicMode(
    dir: std.fs.Dir,
    allocator: std.mem.Allocator,
    sub_path: []const u8,
    data: []const u8,
    create_mode: std.fs.File.Mode,
) !void {
    const basename = std.fs.path.basename(sub_path);
    const parent_path = std.fs.path.dirname(sub_path);
    var parent = if (parent_path) |path|
        try dir.openDir(path, .{})
    else
        dir;
    defer if (parent_path != null) parent.close();

    const mode = existingFileMode(parent, basename) catch |err| switch (err) {
        error.FileNotFound => create_mode,
        else => return err,
    };
    const sequence = temp_counter.fetchAdd(1, .monotonic);
    const tmp_name = try std.fmt.allocPrint(allocator, ".{s}.tmp-{d}-{d}", .{ basename, std.time.nanoTimestamp(), sequence });
    defer allocator.free(tmp_name);

    debug_log.log("fs_util.writeFileAtomic: writing {s} via {s}", .{ sub_path, tmp_name });
    var tmp_file = try parent.createFile(tmp_name, .{ .exclusive = true, .mode = mode });
    var renamed = false;
    defer {
        tmp_file.close();
        if (!renamed) parent.deleteFile(tmp_name) catch {};
    }

    try tmp_file.writeAll(data);
    try tmp_file.sync();
    try parent.rename(tmp_name, basename);
    renamed = true;
    try syncDirectory(parent);
    debug_log.log("fs_util.writeFileAtomic: replaced {s}", .{sub_path});
}

fn existingFileMode(parent: std.fs.Dir, basename: []const u8) !std.fs.File.Mode {
    const stat = try parent.statFile(basename);
    return stat.mode;
}

fn syncDirectory(dir: std.fs.Dir) !void {
    if (builtin.os.tag == .windows) return;
    std.posix.fsync(dir.fd) catch |err| {
        debug_log.log("fs_util.syncDirectory: failed to sync directory: {s}", .{@errorName(err)});
        return err;
    };
}

/// Create a uniquely named, mode-restricted file in `dir`. The caller owns the
/// returned name and file, and is responsible for deleting the file when done.
pub fn createSecureTempFile(
    dir: std.fs.Dir,
    allocator: std.mem.Allocator,
    prefix: []const u8,
) !struct { name: []u8, file: std.fs.File } {
    if (std.fs.path.basename(prefix).len != prefix.len or prefix.len == 0) {
        return error.InvalidTempPrefix;
    }

    while (true) {
        const sequence = temp_counter.fetchAdd(1, .monotonic);
        const name = try std.fmt.allocPrint(allocator, ".{s}-{d}-{d}.tmp", .{ prefix, std.time.nanoTimestamp(), sequence });
        const file = dir.createFile(name, .{ .exclusive = true, .mode = 0o600 }) catch |err| switch (err) {
            error.PathAlreadyExists => {
                allocator.free(name);
                continue;
            },
            else => {
                allocator.free(name);
                return err;
            },
        };
        debug_log.log("fs_util.createSecureTempFile: created {s}", .{name});
        return .{ .name = name, .file = file };
    }
}

/// Replace `live_name` with an already staged sibling directory. The previous
/// live directory is retained until promotion succeeds and restored if it does
/// not. The staged directory is left in place on failure for diagnostics or a
/// later retry.
pub fn replaceDirectoryTransactional(
    parent: std.fs.Dir,
    allocator: std.mem.Allocator,
    live_name: []const u8,
    staged_name: []const u8,
) !void {
    if (!isBasename(live_name) or !isBasename(staged_name) or std.mem.eql(u8, live_name, staged_name)) {
        return error.InvalidDirectoryName;
    }

    if (builtin.os.tag != .windows) {
        const staged_stat = std.posix.fstatat(parent.fd, staged_name, std.posix.AT.SYMLINK_NOFOLLOW) catch |err| switch (err) {
            error.FileNotFound => return error.FileNotFound,
            else => return err,
        };
        if (staged_stat.mode & std.posix.S.IFMT != std.posix.S.IFDIR) {
            debug_log.log("fs_util.replaceDirectoryTransactional: rejected non-directory staged path {s}", .{staged_name});
            return error.StagedPathNotDirectory;
        }
    } else {
        var staged_dir = parent.openDir(staged_name, .{ .no_follow = true }) catch |err| switch (err) {
            error.FileNotFound => return error.FileNotFound,
            else => return error.StagedPathNotDirectory,
        };
        staged_dir.close();
    }

    const sequence = temp_counter.fetchAdd(1, .monotonic);
    const backup_name = try std.fmt.allocPrint(allocator, ".{s}.backup-{d}-{d}", .{ live_name, std.time.nanoTimestamp(), sequence });
    defer allocator.free(backup_name);

    var had_live = true;
    parent.rename(live_name, backup_name) catch |err| switch (err) {
        error.FileNotFound => had_live = false,
        else => return err,
    };
    errdefer if (had_live) parent.rename(backup_name, live_name) catch {};

    debug_log.log("fs_util.replaceDirectoryTransactional: promoting {s} to {s}", .{ staged_name, live_name });
    parent.rename(staged_name, live_name) catch |err| {
        debug_log.log("fs_util.replaceDirectoryTransactional: promotion failed for {s}: {s}", .{ live_name, @errorName(err) });
        return err;
    };
    try syncDirectory(parent);

    if (had_live) {
        parent.deleteTree(backup_name) catch |err| {
            debug_log.log("fs_util.replaceDirectoryTransactional: retained backup {s}: {s}", .{ backup_name, @errorName(err) });
            return err;
        };
        try syncDirectory(parent);
    }
    debug_log.log("fs_util.replaceDirectoryTransactional: replaced {s}", .{live_name});
}

fn isBasename(name: []const u8) bool {
    return name.len > 0 and std.fs.path.basename(name).len == name.len and
        !std.mem.eql(u8, name, ".") and !std.mem.eql(u8, name, "..");
}

test "writeFileAtomic creates a file" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeFileAtomic(tmp.dir, allocator, "settings.json", "{\"ok\":true}\n");

    const contents = try tmp.dir.readFileAlloc(allocator, "settings.json", 1024);
    defer allocator.free(contents);
    try std.testing.expectEqualStrings("{\"ok\":true}\n", contents);
}

test "writeFileAtomic replaces complete contents" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{ .sub_path = "settings.json", .data = "old\n" });
    try writeFileAtomic(tmp.dir, allocator, "settings.json", "new\n");

    const contents = try tmp.dir.readFileAlloc(allocator, "settings.json", 1024);
    defer allocator.free(contents);
    try std.testing.expectEqualStrings("new\n", contents);
}

test "writeFileAtomic preserves existing permissions" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;

    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var original = try tmp.dir.createFile("secret.json", .{ .mode = 0o600 });
    original.close();
    try writeFileAtomic(tmp.dir, allocator, "secret.json", "new\n");

    const stat = try tmp.dir.statFile("secret.json");
    try std.testing.expectEqual(@as(std.fs.File.Mode, 0o600), stat.mode & 0o777);
}

test "writeFileAtomicMode applies permissions to a new file" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;

    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeFileAtomicMode(tmp.dir, allocator, "secret.json", "new\n", 0o600);

    const stat = try tmp.dir.statFile("secret.json");
    try std.testing.expectEqual(@as(std.fs.File.Mode, 0o600), stat.mode & 0o777);
}

test "writeFileAtomic preserves write-only permissions" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;

    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var original = try tmp.dir.createFile("secret.json", .{ .mode = 0o200 });
    original.close();
    try writeFileAtomic(tmp.dir, allocator, "secret.json", "new\n");

    const stat = try tmp.dir.statFile("secret.json");
    try std.testing.expectEqual(@as(std.fs.File.Mode, 0o200), stat.mode & 0o777);
}

test "writeFileAtomic leaves the old file when setup fails" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{ .sub_path = "settings.json", .data = "old\n" });
    var failing_allocator = std.testing.FailingAllocator.init(allocator, .{ .fail_index = 0 });
    try std.testing.expectError(
        error.OutOfMemory,
        writeFileAtomic(tmp.dir, failing_allocator.allocator(), "settings.json", "new\n"),
    );

    const contents = try tmp.dir.readFileAlloc(allocator, "settings.json", 1024);
    defer allocator.free(contents);
    try std.testing.expectEqualStrings("old\n", contents);

    var dir = try tmp.dir.openDir(".", .{ .iterate = true });
    defer dir.close();
    var iterator = dir.iterate();
    while (try iterator.next()) |entry| {
        try std.testing.expect(!std.mem.startsWith(u8, entry.name, ".settings.json.tmp-"));
    }
}

test "createSecureTempFile creates unique mode 0600 files" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;

    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var first = try createSecureTempFile(tmp.dir, allocator, "entitlements");
    defer allocator.free(first.name);
    defer tmp.dir.deleteFile(first.name) catch {};
    defer first.file.close();
    var second = try createSecureTempFile(tmp.dir, allocator, "entitlements");
    defer allocator.free(second.name);
    defer tmp.dir.deleteFile(second.name) catch {};
    defer second.file.close();

    try std.testing.expect(!std.mem.eql(u8, first.name, second.name));
    const first_stat = try first.file.stat();
    const second_stat = try second.file.stat();
    try std.testing.expectEqual(@as(std.fs.File.Mode, 0o600), first_stat.mode & 0o777);
    try std.testing.expectEqual(@as(std.fs.File.Mode, 0o600), second_stat.mode & 0o777);
}

test "createSecureTempFile rejects path prefixes" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try std.testing.expectError(error.InvalidTempPrefix, createSecureTempFile(tmp.dir, std.testing.allocator, "nested/file"));
    try std.testing.expectError(error.InvalidTempPrefix, createSecureTempFile(tmp.dir, std.testing.allocator, ""));
}

test "replaceDirectoryTransactional promotes staged contents" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.makeDir("live");
    try tmp.dir.makeDir("staged");
    try tmp.dir.writeFile(.{ .sub_path = "live/version", .data = "old\n" });
    try tmp.dir.writeFile(.{ .sub_path = "staged/version", .data = "new\n" });

    try replaceDirectoryTransactional(tmp.dir, allocator, "live", "staged");

    const version = try tmp.dir.readFileAlloc(allocator, "live/version", 1024);
    defer allocator.free(version);
    try std.testing.expectEqualStrings("new\n", version);
    try std.testing.expectError(error.FileNotFound, tmp.dir.access("staged", .{}));

    var dir = try tmp.dir.openDir(".", .{ .iterate = true });
    defer dir.close();
    var iterator = dir.iterate();
    while (try iterator.next()) |entry| {
        try std.testing.expect(!std.mem.startsWith(u8, entry.name, ".live.backup-"));
    }
}

test "replaceDirectoryTransactional leaves live contents when staging is absent" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.makeDir("live");
    try tmp.dir.writeFile(.{ .sub_path = "live/version", .data = "old\n" });

    try std.testing.expectError(
        error.FileNotFound,
        replaceDirectoryTransactional(tmp.dir, allocator, "live", "missing"),
    );

    const version = try tmp.dir.readFileAlloc(allocator, "live/version", 1024);
    defer allocator.free(version);
    try std.testing.expectEqualStrings("old\n", version);
}

test "replaceDirectoryTransactional rejects a staged symlink" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;

    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.makeDir("live");
    try tmp.dir.makeDir("outside");
    try tmp.dir.writeFile(.{ .sub_path = "live/version", .data = "old\n" });
    try tmp.dir.writeFile(.{ .sub_path = "outside/version", .data = "outside\n" });
    try tmp.dir.symLink("outside", "staged", .{ .is_directory = true });

    try std.testing.expectError(
        error.StagedPathNotDirectory,
        replaceDirectoryTransactional(tmp.dir, allocator, "live", "staged"),
    );

    const version = try tmp.dir.readFileAlloc(allocator, "live/version", 1024);
    defer allocator.free(version);
    try std.testing.expectEqualStrings("old\n", version);
}

test "replaceDirectoryTransactional installs when live is absent" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.makeDir("staged");
    try tmp.dir.writeFile(.{ .sub_path = "staged/version", .data = "new\n" });

    try replaceDirectoryTransactional(tmp.dir, allocator, "live", "staged");

    const version = try tmp.dir.readFileAlloc(allocator, "live/version", 1024);
    defer allocator.free(version);
    try std.testing.expectEqualStrings("new\n", version);
}
