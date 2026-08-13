const std = @import("std");

pub const DEFAULT_MAX_DEPTH: usize = 64;

pub const Options = struct {
    project_root: []const u8,
    patterns: []const []const u8,
    external_roots: []const []const u8 = &.{},
    max_depth: usize = DEFAULT_MAX_DEPTH,
};

pub const MatchedPath = struct {
    logical_path: []const u8,
    physical_path: []const u8,
};

pub const PathMatcher = struct {
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, _: Options) !PathMatcher {
        return .{ .allocator = allocator };
    }

    pub fn deinit(_: *PathMatcher) void {}

    pub fn matches(_: *const PathMatcher, _: []const u8) bool {
        return false;
    }

    pub fn collect(_: *PathMatcher, _: *std.ArrayListUnmanaged(MatchedPath)) !void {}

    pub fn freeMatchedPaths(self: *const PathMatcher, paths: []const MatchedPath) void {
        for (paths) |path| {
            self.allocator.free(path.logical_path);
            self.allocator.free(path.physical_path);
        }
    }
};

fn writeTestFile(dir: std.fs.Dir, path: []const u8, contents: []const u8) !void {
    if (std.fs.path.dirname(path)) |parent| try dir.makePath(parent);
    const file = try dir.createFile(path, .{});
    defer file.close();
    try file.writeAll(contents);
}

fn expectLogicalPaths(expected: []const []const u8, actual: []const MatchedPath) !void {
    try std.testing.expectEqual(expected.len, actual.len);
    for (expected, actual) |expected_path, actual_path| {
        try std.testing.expectEqualStrings(expected_path, actual_path.logical_path);
    }
}

test "PathMatcher applies includes excludes and shared directory policy" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeTestFile(tmp.dir, "src/main.zig", "pub fn main() void {}\n");
    try writeTestFile(tmp.dir, "src/generated/skip.zig", "const skip = true;\n");
    try writeTestFile(tmp.dir, "src/keep.txt", "keep\n");
    try writeTestFile(tmp.dir, "node_modules/pkg/index.zig", "const dependency = true;\n");
    try writeTestFile(tmp.dir, ".hidden/secret.zig", "const secret = true;\n");

    const project_root = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(project_root);

    var matcher = try PathMatcher.init(allocator, .{
        .project_root = project_root,
        .patterns = &.{ "**/*.zig", "!src/generated/**" },
    });
    defer matcher.deinit();

    try std.testing.expect(matcher.matches("src\\main.zig"));
    try std.testing.expect(!matcher.matches("src/generated/skip.zig"));
    try std.testing.expect(!matcher.matches("node_modules/pkg/index.zig"));
    try std.testing.expect(!matcher.matches(".hidden/secret.zig"));

    var paths: std.ArrayListUnmanaged(MatchedPath) = .empty;
    defer {
        matcher.freeMatchedPaths(paths.items);
        paths.deinit(allocator);
    }
    try matcher.collect(&paths);
    try expectLogicalPaths(&.{"src/main.zig"}, paths.items);
}

test "PathMatcher follows project-contained symlinks and rejects external targets by default" {
    const allocator = std.testing.allocator;
    var project = std.testing.tmpDir(.{});
    defer project.cleanup();
    var external = std.testing.tmpDir(.{});
    defer external.cleanup();

    try writeTestFile(project.dir, "packages/app/main.zig", "pub fn main() void {}\n");
    try writeTestFile(external.dir, "outside.zig", "const outside = true;\n");
    const external_root = try external.dir.realpathAlloc(allocator, ".");
    defer allocator.free(external_root);

    try project.dir.symLink("packages/app", "app-link", .{ .is_directory = true });
    try project.dir.symLink(external_root, "outside-link", .{ .is_directory = true });

    const project_root = try project.dir.realpathAlloc(allocator, ".");
    defer allocator.free(project_root);

    var matcher = try PathMatcher.init(allocator, .{
        .project_root = project_root,
        .patterns = &.{"**/*.zig"},
    });
    defer matcher.deinit();

    var paths: std.ArrayListUnmanaged(MatchedPath) = .empty;
    defer {
        matcher.freeMatchedPaths(paths.items);
        paths.deinit(allocator);
    }
    try matcher.collect(&paths);

    try expectLogicalPaths(&.{ "app-link/main.zig", "packages/app/main.zig" }, paths.items);
}

test "PathMatcher external roots opt in symlink targets and direct aliases" {
    const allocator = std.testing.allocator;
    var project = std.testing.tmpDir(.{});
    defer project.cleanup();
    var external = std.testing.tmpDir(.{});
    defer external.cleanup();

    try writeTestFile(external.dir, "lib/shared.zig", "pub const shared = true;\n");
    const external_root = try external.dir.realpathAlloc(allocator, ".");
    defer allocator.free(external_root);
    try project.dir.symLink(external_root, "workspace-shared", .{ .is_directory = true });

    const project_root = try project.dir.realpathAlloc(allocator, ".");
    defer allocator.free(project_root);

    var matcher = try PathMatcher.init(allocator, .{
        .project_root = project_root,
        .patterns = &.{"**/*.zig"},
        .external_roots = &.{external_root},
    });
    defer matcher.deinit();

    var paths: std.ArrayListUnmanaged(MatchedPath) = .empty;
    defer {
        matcher.freeMatchedPaths(paths.items);
        paths.deinit(allocator);
    }
    try matcher.collect(&paths);

    try std.testing.expectEqual(@as(usize, 2), paths.items.len);
    try std.testing.expectEqualStrings("workspace-shared/lib/shared.zig", paths.items[0].logical_path);
    try std.testing.expect(std.mem.startsWith(u8, paths.items[1].logical_path, "@external/"));
    try std.testing.expect(std.mem.endsWith(u8, paths.items[1].logical_path, "/lib/shared.zig"));
    try std.testing.expect(paths.items[1].logical_path[0] != '/');
    try std.testing.expect(std.mem.indexOf(u8, paths.items[1].logical_path, "..") == null);
}

test "PathMatcher rejects canonical boundary prefix tricks" {
    const allocator = std.testing.allocator;
    var sandbox = std.testing.tmpDir(.{});
    defer sandbox.cleanup();

    try writeTestFile(sandbox.dir, "project/main.zig", "pub fn main() void {}\n");
    try writeTestFile(sandbox.dir, "project-escape/escape.zig", "const escape = true;\n");

    const escape_root = try sandbox.dir.realpathAlloc(allocator, "project-escape");
    defer allocator.free(escape_root);
    try sandbox.dir.symLink(escape_root, "project/escape-link", .{ .is_directory = true });

    const project_root = try sandbox.dir.realpathAlloc(allocator, "project");
    defer allocator.free(project_root);

    var matcher = try PathMatcher.init(allocator, .{
        .project_root = project_root,
        .patterns = &.{"**/*.zig"},
    });
    defer matcher.deinit();

    var paths: std.ArrayListUnmanaged(MatchedPath) = .empty;
    defer {
        matcher.freeMatchedPaths(paths.items);
        paths.deinit(allocator);
    }
    try matcher.collect(&paths);
    try expectLogicalPaths(&.{"main.zig"}, paths.items);
}

test "PathMatcher terminates symlink cycles and enforces depth cap" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeTestFile(tmp.dir, "a/b/c/too-deep.zig", "const deep = true;\n");
    try writeTestFile(tmp.dir, "a/shallow.zig", "const shallow = true;\n");
    try tmp.dir.symLink("..", "a/loop", .{ .is_directory = true });

    const project_root = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(project_root);

    var matcher = try PathMatcher.init(allocator, .{
        .project_root = project_root,
        .patterns = &.{"**/*.zig"},
        .max_depth = 2,
    });
    defer matcher.deinit();

    var paths: std.ArrayListUnmanaged(MatchedPath) = .empty;
    defer {
        matcher.freeMatchedPaths(paths.items);
        paths.deinit(allocator);
    }
    try matcher.collect(&paths);
    try expectLogicalPaths(&.{"a/shallow.zig"}, paths.items);
}
