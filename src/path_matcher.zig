const std = @import("std");
const builtin = @import("builtin");
const debug_log = @import("debug_log.zig");

pub const DEFAULT_MAX_DEPTH: usize = 64;

const excluded_directories = [_][]const u8{
    "node_modules",
    "vendor",
    "target",
    "zig-out",
    "zig-cache",
    ".zig-cache",
    "build",
    "dist",
    "__pycache__",
};

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

pub const WatchRoot = struct {
    physical_path: []const u8,
    logical_prefix: []const u8,
};

const Root = struct {
    canonical_path: []const u8,
    logical_prefix: []const u8,
    is_project: bool,
};

const DirectoryIdentity = struct {
    device: u64,
    inode: u64,
};

pub const PathMatcher = struct {
    allocator: std.mem.Allocator,
    project_root: []const u8,
    patterns: []const []const u8,
    roots: []Root,
    max_depth: usize,

    pub fn init(allocator: std.mem.Allocator, options: Options) !PathMatcher {
        const project_root = try std.fs.realpathAlloc(allocator, options.project_root);
        errdefer allocator.free(project_root);

        var roots: std.ArrayListUnmanaged(Root) = .empty;
        errdefer {
            for (roots.items) |root| {
                allocator.free(root.canonical_path);
                allocator.free(root.logical_prefix);
            }
            roots.deinit(allocator);
        }

        try roots.append(allocator, .{
            .canonical_path = try allocator.dupe(u8, project_root),
            .logical_prefix = try allocator.dupe(u8, ""),
            .is_project = true,
        });

        for (options.external_roots) |configured_root| {
            const canonical = resolveConfiguredRoot(allocator, project_root, configured_root) catch |err| {
                debug_log.log("PathMatcher.init: external root {s} rejected: {s}", .{ configured_root, @errorName(err) });
                continue;
            };
            errdefer allocator.free(canonical);
            if (isContainedPath(canonical, project_root)) {
                allocator.free(canonical);
                continue;
            }
            var duplicate = false;
            for (roots.items) |root| {
                if (std.mem.eql(u8, root.canonical_path, canonical)) {
                    duplicate = true;
                    break;
                }
            }
            if (duplicate) {
                allocator.free(canonical);
                continue;
            }

            const alias = try externalAlias(allocator, configured_root, canonical, roots.items);
            try roots.append(allocator, .{
                .canonical_path = canonical,
                .logical_prefix = alias,
                .is_project = false,
            });
            debug_log.log("PathMatcher.init: approved external root {s} as {s}", .{ canonical, alias });
        }

        const patterns = try allocator.alloc([]const u8, options.patterns.len);
        errdefer allocator.free(patterns);
        for (options.patterns, 0..) |pattern, i| {
            patterns[i] = try allocator.dupe(u8, pattern);
            errdefer for (patterns[0 .. i + 1]) |owned| allocator.free(owned);
        }

        debug_log.log("PathMatcher.init: project={s} patterns={d} external_roots={d} max_depth={d}", .{
            project_root,
            patterns.len,
            roots.items.len - 1,
            options.max_depth,
        });
        return .{
            .allocator = allocator,
            .project_root = project_root,
            .patterns = patterns,
            .roots = try roots.toOwnedSlice(allocator),
            .max_depth = options.max_depth,
        };
    }

    pub fn deinit(self: *PathMatcher) void {
        for (self.patterns) |pattern| self.allocator.free(pattern);
        self.allocator.free(self.patterns);
        for (self.roots) |root| {
            self.allocator.free(root.canonical_path);
            self.allocator.free(root.logical_prefix);
        }
        self.allocator.free(self.roots);
        self.allocator.free(self.project_root);
    }

    pub fn matches(self: *const PathMatcher, logical_path: []const u8) bool {
        var path_buf: [std.fs.max_path_bytes]u8 = undefined;
        const normalized = normalizeLogicalPath(logical_path, &path_buf) orelse return false;
        if (isPolicyExcluded(normalized)) return false;

        var included = false;
        for (self.patterns) |pattern| {
            const negative = isNegativePattern(pattern);
            const normalized_pattern = if (negative) pattern[1..] else pattern;
            if (normalized_pattern.len == 0) continue;
            if (!globMatch(normalized_pattern, normalized)) continue;
            if (negative) return false;
            included = true;
        }
        return included;
    }

    pub fn collect(self: *PathMatcher, out: *std.ArrayListUnmanaged(MatchedPath)) !void {
        for (self.roots) |root| {
            var active = std.AutoHashMap(DirectoryIdentity, void).init(self.allocator);
            defer active.deinit();
            try self.walkDirectory(root.canonical_path, root.logical_prefix, 0, &active, out);
        }
        std.mem.sort(MatchedPath, out.items, {}, struct {
            fn lessThan(_: void, a: MatchedPath, b: MatchedPath) bool {
                const a_external = std.mem.startsWith(u8, a.logical_path, "@external/");
                const b_external = std.mem.startsWith(u8, b.logical_path, "@external/");
                if (a_external != b_external) return !a_external;
                return std.mem.order(u8, a.logical_path, b.logical_path) == .lt;
            }
        }.lessThan);
    }

    pub fn watchRoots(self: *const PathMatcher, out: *std.ArrayListUnmanaged(WatchRoot)) !void {
        for (self.roots) |root| {
            try out.append(self.allocator, .{
                .physical_path = try self.allocator.dupe(u8, root.canonical_path),
                .logical_prefix = try self.allocator.dupe(u8, root.logical_prefix),
            });
        }
    }

    pub fn mapPhysicalToLogical(
        self: *const PathMatcher,
        physical_path: []const u8,
        out: *std.ArrayListUnmanaged([]const u8),
    ) !void {
        const canonical = std.fs.realpathAlloc(self.allocator, physical_path) catch try self.allocator.dupe(u8, physical_path);
        defer self.allocator.free(canonical);
        for (self.roots) |root| {
            const suffix = relativeContained(canonical, root.canonical_path) orelse continue;
            const logical = try joinLogical(self.allocator, root.logical_prefix, suffix);
            if (logical.len > 0 and self.matches(logical)) {
                try out.append(self.allocator, logical);
            } else {
                self.allocator.free(logical);
            }
        }
    }

    pub fn freeMatchedPaths(self: *const PathMatcher, paths: []const MatchedPath) void {
        for (paths) |path| {
            self.allocator.free(path.logical_path);
            self.allocator.free(path.physical_path);
        }
    }

    pub fn freeWatchRoots(self: *const PathMatcher, roots: []const WatchRoot) void {
        for (roots) |root| {
            self.allocator.free(root.physical_path);
            self.allocator.free(root.logical_prefix);
        }
    }

    fn walkDirectory(
        self: *PathMatcher,
        physical_dir: []const u8,
        logical_dir: []const u8,
        depth: usize,
        active: *std.AutoHashMap(DirectoryIdentity, void),
        out: *std.ArrayListUnmanaged(MatchedPath),
    ) !void {
        if (depth > self.max_depth) {
            debug_log.log("PathMatcher.walk: depth cap path={s} depth={d}", .{ physical_dir, depth });
            return;
        }

        var dir = std.fs.openDirAbsolute(physical_dir, .{ .iterate = true }) catch |err| {
            debug_log.log("PathMatcher.walk: open {s} failed: {s}", .{ physical_dir, @errorName(err) });
            return;
        };
        defer dir.close();

        const identity = directoryIdentity(dir) catch |err| {
            debug_log.log("PathMatcher.walk: stat {s} failed: {s}", .{ physical_dir, @errorName(err) });
            return;
        };
        if (active.contains(identity)) {
            debug_log.log("PathMatcher.walk: cycle path={s}", .{physical_dir});
            return;
        }
        try active.put(identity, {});
        defer _ = active.remove(identity);

        var iter = dir.iterate();
        while (try iter.next()) |entry| {
            if (entry.name.len == 0 or entry.name[0] == '.') continue;
            if (isExcludedDirectory(entry.name)) continue;

            const physical_child = try std.fs.path.join(self.allocator, &.{ physical_dir, entry.name });
            defer self.allocator.free(physical_child);
            const logical_child = try joinLogical(self.allocator, logical_dir, entry.name);
            defer self.allocator.free(logical_child);

            const canonical_child = std.fs.realpathAlloc(self.allocator, physical_child) catch continue;
            defer self.allocator.free(canonical_child);
            if (!self.isAllowedCanonical(canonical_child)) {
                debug_log.log("PathMatcher.walk: rejected external target logical={s} target={s}", .{ logical_child, canonical_child });
                continue;
            }

            const stat = std.fs.cwd().statFile(canonical_child) catch continue;
            switch (stat.kind) {
                .directory => try self.walkDirectory(canonical_child, logical_child, depth + 1, active, out),
                .file => if (self.matches(logical_child)) {
                    try out.append(self.allocator, .{
                        .logical_path = try self.allocator.dupe(u8, logical_child),
                        .physical_path = try self.allocator.dupe(u8, canonical_child),
                    });
                },
                else => {},
            }
        }
    }

    fn isAllowedCanonical(self: *const PathMatcher, canonical_path: []const u8) bool {
        for (self.roots) |root| {
            if (isContainedPath(canonical_path, root.canonical_path)) return true;
        }
        return false;
    }
};

fn resolveConfiguredRoot(allocator: std.mem.Allocator, project_root: []const u8, configured: []const u8) ![]u8 {
    if (std.fs.path.isAbsolute(configured)) return std.fs.realpathAlloc(allocator, configured);
    const joined = try std.fs.path.join(allocator, &.{ project_root, configured });
    defer allocator.free(joined);
    return std.fs.realpathAlloc(allocator, joined);
}

fn externalAlias(
    allocator: std.mem.Allocator,
    configured: []const u8,
    canonical: []const u8,
    roots: []const Root,
) ![]u8 {
    var base = std.fs.path.basename(configured);
    if (base.len == 0 or std.mem.eql(u8, base, ".") or std.mem.eql(u8, base, "..")) {
        base = std.fs.path.basename(canonical);
    }
    if (base.len == 0) base = "root";

    var candidate = try std.fmt.allocPrint(allocator, "@external/{s}", .{base});
    var suffix: usize = 2;
    while (rootAliasExists(roots, candidate)) : (suffix += 1) {
        allocator.free(candidate);
        candidate = try std.fmt.allocPrint(allocator, "@external/{s}-{d}", .{ base, suffix });
    }
    return candidate;
}

fn rootAliasExists(roots: []const Root, alias: []const u8) bool {
    for (roots) |root| {
        if (std.mem.eql(u8, root.logical_prefix, alias)) return true;
    }
    return false;
}

fn directoryIdentity(dir: std.fs.Dir) !DirectoryIdentity {
    if (builtin.os.tag == .windows or builtin.os.tag == .wasi) {
        const stat = try dir.stat();
        return .{ .device = 0, .inode = @intCast(stat.inode) };
    }
    const stat = try std.posix.fstat(dir.fd);
    return .{
        .device = @intCast(stat.dev),
        .inode = @intCast(stat.ino),
    };
}

pub fn isContainedPath(path: []const u8, root: []const u8) bool {
    if (std.mem.eql(u8, path, root)) return true;
    if (!std.mem.startsWith(u8, path, root)) return false;
    if (root.len == 0) return false;
    if (root[root.len - 1] == std.fs.path.sep) return true;
    return path.len > root.len and path[root.len] == std.fs.path.sep;
}

fn relativeContained(path: []const u8, root: []const u8) ?[]const u8 {
    if (!isContainedPath(path, root)) return null;
    if (path.len == root.len) return "";
    var start = root.len;
    while (start < path.len and (path[start] == '/' or path[start] == '\\')) start += 1;
    return path[start..];
}

fn normalizeLogicalPath(path: []const u8, buf: []u8) ?[]const u8 {
    if (path.len == 0 or path.len > buf.len or std.fs.path.isAbsolute(path)) return null;
    var out_len: usize = 0;
    var component_start: usize = 0;
    var i: usize = 0;
    while (i <= path.len) : (i += 1) {
        if (i < path.len and path[i] != '/' and path[i] != '\\') continue;
        const component = path[component_start..i];
        component_start = i + 1;
        if (component.len == 0 or std.mem.eql(u8, component, ".")) continue;
        if (std.mem.eql(u8, component, "..")) return null;
        if (out_len > 0) {
            buf[out_len] = '/';
            out_len += 1;
        }
        if (out_len + component.len > buf.len) return null;
        @memcpy(buf[out_len .. out_len + component.len], component);
        out_len += component.len;
    }
    if (out_len == 0) return null;
    return buf[0..out_len];
}

fn joinLogical(allocator: std.mem.Allocator, prefix: []const u8, suffix: []const u8) ![]u8 {
    if (prefix.len == 0) return allocator.dupe(u8, suffix);
    if (suffix.len == 0) return allocator.dupe(u8, prefix);
    return std.fmt.allocPrint(allocator, "{s}/{s}", .{ prefix, suffix });
}

fn isPolicyExcluded(path: []const u8) bool {
    var components = std.mem.splitScalar(u8, path, '/');
    while (components.next()) |component| {
        if (component.len == 0) continue;
        if (component[0] == '.') return true;
        if (isExcludedDirectory(component)) return true;
    }
    return false;
}

fn isExcludedDirectory(name: []const u8) bool {
    for (excluded_directories) |excluded| {
        if (std.mem.eql(u8, name, excluded)) return true;
    }
    return false;
}

fn isNegativePattern(pattern: []const u8) bool {
    return pattern.len > 1 and pattern[0] == '!';
}

pub fn globMatch(pattern: []const u8, path: []const u8) bool {
    var pi: usize = 0;
    var si: usize = 0;
    var star_pi: usize = 0;
    var star_si: usize = 0;
    var has_star = false;

    while (si < path.len or pi < pattern.len) {
        if (pi < pattern.len) {
            if (pi + 1 < pattern.len and pattern[pi] == '*' and pattern[pi + 1] == '*') {
                pi += 2;
                if (pi < pattern.len and pattern[pi] == '/') pi += 1;
                if (pi >= pattern.len) return true;
                while (si <= path.len) {
                    if (globMatch(pattern[pi..], path[si..])) return true;
                    if (si < path.len) si += 1 else break;
                }
                return false;
            }
            if (pattern[pi] == '*') {
                star_pi = pi;
                star_si = si;
                has_star = true;
                pi += 1;
                continue;
            }
            if (si < path.len) {
                if (pattern[pi] == '?' and path[si] != '/') {
                    pi += 1;
                    si += 1;
                    continue;
                }
                if (pattern[pi] == path[si]) {
                    pi += 1;
                    si += 1;
                    continue;
                }
            }
        }
        if (has_star and star_si < path.len and path[star_si] != '/') {
            star_si += 1;
            si = star_si;
            pi = star_pi + 1;
            continue;
        }
        return false;
    }
    return true;
}

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
