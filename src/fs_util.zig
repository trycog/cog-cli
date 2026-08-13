const std = @import("std");
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

    const mode = existingFileMode(parent, basename) catch create_mode;
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
    debug_log.log("fs_util.writeFileAtomic: replaced {s}", .{sub_path});
}

fn existingFileMode(parent: std.fs.Dir, basename: []const u8) !std.fs.File.Mode {
    var file = try parent.openFile(basename, .{});
    defer file.close();
    const stat = try file.stat();
    return stat.mode;
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
