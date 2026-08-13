const std = @import("std");
const debug_log = @import("debug_log.zig");

var temp_counter = std.atomic.Value(u64).init(0);

/// Replace a file through a sibling temporary file so readers see either the
/// previous complete contents or the new complete contents.
pub fn writeFileAtomic(dir: std.fs.Dir, allocator: std.mem.Allocator, sub_path: []const u8, data: []const u8) !void {
    const basename = std.fs.path.basename(sub_path);
    const parent_path = std.fs.path.dirname(sub_path);
    var parent = if (parent_path) |path|
        try dir.openDir(path, .{})
    else
        dir;
    defer if (parent_path != null) parent.close();

    const sequence = temp_counter.fetchAdd(1, .monotonic);
    const tmp_name = try std.fmt.allocPrint(allocator, ".{s}.tmp-{d}-{d}", .{ basename, std.time.nanoTimestamp(), sequence });
    defer allocator.free(tmp_name);

    debug_log.log("fs_util.writeFileAtomic: writing {s} via {s}", .{ sub_path, tmp_name });
    var tmp_file = try parent.createFile(tmp_name, .{ .exclusive = true });
    var renamed = false;
    defer {
        tmp_file.close();
        if (!renamed) parent.deleteFile(tmp_name) catch {};
    }

    try tmp_file.writeAll(data);
    try tmp_file.sync();
    try parent.rename(tmp_name, basename);
    renamed = true;
    parent.sync() catch {};
    debug_log.log("fs_util.writeFileAtomic: replaced {s}", .{sub_path});
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
