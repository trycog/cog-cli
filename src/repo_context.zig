const std = @import("std");
const debug_log = @import("debug_log.zig");

pub const RepoContext = struct {
    cwd: []const u8,
    repo_root: ?[]const u8,
    repo_remote_origin: ?[]const u8,
    repo_head_sha: ?[]const u8,
    repo_fingerprint: ?[]const u8,

    pub fn deinit(self: *RepoContext, allocator: std.mem.Allocator) void {
        allocator.free(self.cwd);
        if (self.repo_root) |value| allocator.free(value);
        if (self.repo_remote_origin) |value| allocator.free(value);
        if (self.repo_head_sha) |value| allocator.free(value);
        if (self.repo_fingerprint) |value| allocator.free(value);
    }

    pub fn clone(self: *const RepoContext, allocator: std.mem.Allocator) !RepoContext {
        return .{
            .cwd = try allocator.dupe(u8, self.cwd),
            .repo_root = if (self.repo_root) |value| try allocator.dupe(u8, value) else null,
            .repo_remote_origin = if (self.repo_remote_origin) |value| try allocator.dupe(u8, value) else null,
            .repo_head_sha = if (self.repo_head_sha) |value| try allocator.dupe(u8, value) else null,
            .repo_fingerprint = if (self.repo_fingerprint) |value| try allocator.dupe(u8, value) else null,
        };
    }
};

pub fn resolve(allocator: std.mem.Allocator, cwd_override: ?[]const u8) !RepoContext {
    const cwd = if (cwd_override) |value|
        try allocator.dupe(u8, value)
    else
        try std.fs.cwd().realpathAlloc(allocator, ".");
    errdefer allocator.free(cwd);

    debug_log.log("repo_context.resolve: cwd={s}", .{cwd});
    const root = try findRepoRoot(allocator, cwd);
    errdefer if (root) |value| allocator.free(value);

    const remote = if (root) |repo_root|
        try gitOutput(allocator, repo_root, &.{ "config", "--get", "remote.origin.url" })
    else
        null;
    errdefer if (remote) |value| allocator.free(value);

    const sha = if (root) |repo_root|
        try gitOutput(allocator, repo_root, &.{ "rev-parse", "HEAD" })
    else
        null;
    errdefer if (sha) |value| allocator.free(value);

    const fingerprint = if (root != null or remote != null or sha != null)
        try buildFingerprint(allocator, cwd, root, remote, sha)
    else
        null;
    errdefer if (fingerprint) |value| allocator.free(value);

    debug_log.log(
        "repo_context.resolve: repo_root={s} remote={s} sha={s}",
        .{
            if (root) |value| value else "none",
            if (remote) |value| value else "none",
            if (sha) |value| value else "none",
        },
    );

    return .{
        .cwd = cwd,
        .repo_root = root,
        .repo_remote_origin = remote,
        .repo_head_sha = sha,
        .repo_fingerprint = fingerprint,
    };
}

fn findRepoRoot(allocator: std.mem.Allocator, cwd: []const u8) !?[]const u8 {
    var current = try allocator.dupe(u8, cwd);
    defer allocator.free(current);

    while (true) {
        var dir = std.fs.openDirAbsolute(current, .{}) catch break;
        defer dir.close();

        dir.access(".git", .{}) catch {
            const parent = std.fs.path.dirname(current) orelse break;
            if (parent.len == current.len) break;
            const next = try allocator.dupe(u8, parent);
            allocator.free(current);
            current = next;
            continue;
        };

        return @as(?[]const u8, try allocator.dupe(u8, current));
    }

    return null;
}

fn gitOutput(allocator: std.mem.Allocator, repo_root: []const u8, argv: []const []const u8) !?[]const u8 {
    var full_argv = try allocator.alloc([]const u8, argv.len + 1);
    defer allocator.free(full_argv);
    full_argv[0] = "git";
    @memcpy(full_argv[1..], argv);

    const result = std.process.Child.run(.{
        .allocator = allocator,
        .argv = full_argv,
        .cwd = repo_root,
    }) catch |err| {
        debug_log.log("repo_context.gitOutput: spawn failed for {s}: {s}", .{ repo_root, @errorName(err) });
        return null;
    };
    defer allocator.free(result.stderr);

    switch (result.term) {
        .Exited => |code| {
            if (code != 0) {
                allocator.free(result.stdout);
                debug_log.log("repo_context.gitOutput: git exited {d} in {s}", .{ code, repo_root });
                return null;
            }
        },
        else => {
            allocator.free(result.stdout);
            return null;
        },
    }

    const trimmed = std.mem.trim(u8, result.stdout, &std.ascii.whitespace);
    if (trimmed.len == 0) {
        allocator.free(result.stdout);
        return null;
    }

    const output = try allocator.dupe(u8, trimmed);
    allocator.free(result.stdout);
    return output;
}

fn buildFingerprint(
    allocator: std.mem.Allocator,
    cwd: []const u8,
    repo_root: ?[]const u8,
    remote: ?[]const u8,
    sha: ?[]const u8,
) ![]const u8 {
    var hasher = std.hash.Wyhash.init(0);
    hasher.update(cwd);
    hasher.update("\x00");
    if (repo_root) |value| hasher.update(value);
    hasher.update("\x00");
    if (remote) |value| hasher.update(value);
    hasher.update("\x00");
    if (sha) |value| hasher.update(value);
    return std.fmt.allocPrint(allocator, "{x}", .{hasher.final()});
}

test "resolve soft-fails outside git repos" {
    var repo = try resolve(std.testing.allocator, "/");
    defer repo.deinit(std.testing.allocator);

    try std.testing.expect(repo.repo_root == null);
    try std.testing.expect(repo.repo_remote_origin == null);
    try std.testing.expect(repo.repo_head_sha == null);
}

test "resolve finds nested .git directory" {
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    try tmp_dir.dir.makeDir("project");
    try tmp_dir.dir.makeDir("project/.git");
    try tmp_dir.dir.makePath("project/src/nested");

    const nested = try tmp_dir.dir.realpathAlloc(std.testing.allocator, "project/src/nested");
    defer std.testing.allocator.free(nested);

    var repo = try resolve(std.testing.allocator, nested);
    defer repo.deinit(std.testing.allocator);

    const expected_root = try tmp_dir.dir.realpathAlloc(std.testing.allocator, "project");
    defer std.testing.allocator.free(expected_root);
    try std.testing.expectEqualStrings(expected_root, repo.repo_root.?);
}
