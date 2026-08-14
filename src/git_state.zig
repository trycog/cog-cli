//! Cheap git-state sentinel for index reconciliation.
//!
//! A checkout, pull, merge, or rebase rewrites `.git/HEAD`, the active ref,
//! or `.git/index`, so their mtimes form a stamp that changes whenever the
//! working tree may have moved wholesale. The sentinel never spawns git and
//! never reads object data — three stats per check.

const std = @import("std");
const debug_log = @import("debug_log.zig");

const max_git_file_bytes: usize = 64 * 1024;

pub const SyncStamp = struct {
    head_mtime_ns: i128,
    ref_mtime_ns: i128,
    index_mtime_ns: i128,

    pub fn eql(self: SyncStamp, other: SyncStamp) bool {
        return self.head_mtime_ns == other.head_mtime_ns and
            self.ref_mtime_ns == other.ref_mtime_ns and
            self.index_mtime_ns == other.index_mtime_ns;
    }
};

/// Resolve the git directory for a project root. `.git` is either the
/// repository directory itself or, in a linked worktree, a file containing
/// `gitdir: <path>`. Returns null when the project is not a git checkout.
pub fn resolveGitDir(allocator: std.mem.Allocator, project_root: []const u8) ?[]const u8 {
    const dot_git = std.fs.path.join(allocator, &.{ project_root, ".git" }) catch return null;

    const stat = std.fs.cwd().statFile(dot_git) catch {
        allocator.free(dot_git);
        return null;
    };
    if (stat.kind == .directory) return dot_git;
    defer allocator.free(dot_git);

    const content = std.fs.cwd().readFileAlloc(allocator, dot_git, max_git_file_bytes) catch return null;
    defer allocator.free(content);
    const prefix = "gitdir:";
    const trimmed = std.mem.trim(u8, content, " \t\r\n");
    if (!std.mem.startsWith(u8, trimmed, prefix)) return null;
    const target = std.mem.trim(u8, trimmed[prefix.len..], " \t\r\n");
    if (target.len == 0) return null;

    if (std.fs.path.isAbsolute(target)) {
        return allocator.dupe(u8, target) catch null;
    }
    return std.fs.path.join(allocator, &.{ project_root, target }) catch null;
}

/// Capture the current git sentinel stamp, or null when the project is not a
/// git checkout. Missing ref or index files stamp as zero so repositories in
/// unusual states (fresh init, packed refs) still produce a stable value.
pub fn syncStamp(allocator: std.mem.Allocator, project_root: []const u8) ?SyncStamp {
    const git_dir = resolveGitDir(allocator, project_root) orelse return null;
    defer allocator.free(git_dir);

    const head_path = std.fs.path.join(allocator, &.{ git_dir, "HEAD" }) catch return null;
    defer allocator.free(head_path);
    const head_stat = std.fs.cwd().statFile(head_path) catch {
        debug_log.log("git_state.syncStamp: no readable HEAD under {s}", .{git_dir});
        return null;
    };

    var ref_mtime_ns: i128 = 0;
    if (std.fs.cwd().readFileAlloc(allocator, head_path, max_git_file_bytes)) |head_content| {
        defer allocator.free(head_content);
        const trimmed = std.mem.trim(u8, head_content, " \t\r\n");
        const ref_prefix = "ref:";
        if (std.mem.startsWith(u8, trimmed, ref_prefix)) {
            const ref_name = std.mem.trim(u8, trimmed[ref_prefix.len..], " \t\r\n");
            if (ref_name.len > 0 and std.mem.indexOf(u8, ref_name, "..") == null) {
                if (std.fs.path.join(allocator, &.{ git_dir, ref_name })) |ref_path| {
                    defer allocator.free(ref_path);
                    if (std.fs.cwd().statFile(ref_path)) |ref_stat| {
                        ref_mtime_ns = ref_stat.mtime;
                    } else |_| {}
                } else |_| {}
            }
        }
    } else |_| {}

    var index_mtime_ns: i128 = 0;
    const index_path = std.fs.path.join(allocator, &.{ git_dir, "index" }) catch return null;
    defer allocator.free(index_path);
    if (std.fs.cwd().statFile(index_path)) |index_stat| {
        index_mtime_ns = index_stat.mtime;
    } else |_| {}

    return .{
        .head_mtime_ns = head_stat.mtime,
        .ref_mtime_ns = ref_mtime_ns,
        .index_mtime_ns = index_mtime_ns,
    };
}

/// Resolve the commit hash HEAD points at without spawning git: detached
/// HEAD carries the hash directly; a symbolic ref is read from the loose ref
/// file, falling back to packed-refs. Linked worktrees resolve refs through
/// their commondir. Null when the state cannot be resolved from files.
pub fn resolveHeadCommit(allocator: std.mem.Allocator, project_root: []const u8) ?[]const u8 {
    const git_dir = resolveGitDir(allocator, project_root) orelse return null;
    defer allocator.free(git_dir);

    const head_path = std.fs.path.join(allocator, &.{ git_dir, "HEAD" }) catch return null;
    defer allocator.free(head_path);
    const head_content = std.fs.cwd().readFileAlloc(allocator, head_path, max_git_file_bytes) catch return null;
    defer allocator.free(head_content);
    const trimmed = std.mem.trim(u8, head_content, " \t\r\n");

    const ref_prefix = "ref:";
    if (!std.mem.startsWith(u8, trimmed, ref_prefix)) {
        if (!isCommitHash(trimmed)) return null;
        return allocator.dupe(u8, trimmed) catch null;
    }
    const ref_name = std.mem.trim(u8, trimmed[ref_prefix.len..], " \t\r\n");
    if (ref_name.len == 0 or std.mem.indexOf(u8, ref_name, "..") != null) return null;

    if (resolveRefIn(allocator, git_dir, ref_name)) |hash| return hash;

    // Linked worktrees keep refs in the main repository's git directory.
    const commondir_path = std.fs.path.join(allocator, &.{ git_dir, "commondir" }) catch return null;
    defer allocator.free(commondir_path);
    const commondir_content = std.fs.cwd().readFileAlloc(allocator, commondir_path, max_git_file_bytes) catch return null;
    defer allocator.free(commondir_content);
    const common_rel = std.mem.trim(u8, commondir_content, " \t\r\n");
    if (common_rel.len == 0) return null;
    const common_dir = if (std.fs.path.isAbsolute(common_rel))
        allocator.dupe(u8, common_rel) catch return null
    else
        std.fs.path.join(allocator, &.{ git_dir, common_rel }) catch return null;
    defer allocator.free(common_dir);
    return resolveRefIn(allocator, common_dir, ref_name);
}

fn resolveRefIn(allocator: std.mem.Allocator, git_dir: []const u8, ref_name: []const u8) ?[]const u8 {
    const ref_path = std.fs.path.join(allocator, &.{ git_dir, ref_name }) catch return null;
    defer allocator.free(ref_path);
    if (std.fs.cwd().readFileAlloc(allocator, ref_path, max_git_file_bytes)) |ref_content| {
        defer allocator.free(ref_content);
        const hash = std.mem.trim(u8, ref_content, " \t\r\n");
        if (isCommitHash(hash)) return allocator.dupe(u8, hash) catch null;
    } else |_| {}

    const packed_path = std.fs.path.join(allocator, &.{ git_dir, "packed-refs" }) catch return null;
    defer allocator.free(packed_path);
    const packed_content = std.fs.cwd().readFileAlloc(allocator, packed_path, max_git_file_bytes) catch return null;
    defer allocator.free(packed_content);

    var lines = std.mem.splitScalar(u8, packed_content, '\n');
    while (lines.next()) |line| {
        if (line.len == 0 or line[0] == '#' or line[0] == '^') continue;
        const space = std.mem.indexOfScalar(u8, line, ' ') orelse continue;
        const hash = line[0..space];
        const name = std.mem.trim(u8, line[space + 1 ..], " \t\r");
        if (std.mem.eql(u8, name, ref_name) and isCommitHash(hash)) {
            return allocator.dupe(u8, hash) catch null;
        }
    }
    return null;
}

fn isCommitHash(candidate: []const u8) bool {
    if (candidate.len < 40 or candidate.len > 64) return false;
    for (candidate) |byte| {
        switch (byte) {
            '0'...'9', 'a'...'f' => {},
            else => return false,
        }
    }
    return true;
}

/// Drift candidates for the git fast path: everything that moved between the
/// recorded commit and the current worktree, from `git diff` (committed
/// changes) and `git status` (staged, unstaged, and untracked changes).
/// Files git ignores are invisible here, so callers only use this when the
/// pattern set tracks git-visible sources — the stat walk stays the fallback.
pub const Candidates = struct {
    diff_output: []u8,
    status_output: []u8,
    paths: std.ArrayListUnmanaged([]const u8) = .empty,

    pub fn deinit(self: *Candidates, allocator: std.mem.Allocator) void {
        self.paths.deinit(allocator);
        allocator.free(self.diff_output);
        allocator.free(self.status_output);
    }
};

const max_git_output_bytes: usize = 64 * 1024 * 1024;

/// Collect the changed-path candidate set since `old_commit`, or null when
/// git is unavailable, the commit is unknown, or output cannot be parsed —
/// callers then fall back to the full stat walk.
pub fn collectChangedSince(allocator: std.mem.Allocator, project_root: []const u8, old_commit: []const u8) ?Candidates {
    const diff_output = runGit(allocator, project_root, &.{
        "git", "-c", "core.quotepath=false", "diff", "--name-only", "--no-renames", old_commit, "HEAD",
    }) orelse return null;
    const status_output = runGit(allocator, project_root, &.{
        "git", "-c", "core.quotepath=false", "status", "--porcelain=v1", "--untracked-files=all",
    }) orelse {
        allocator.free(diff_output);
        return null;
    };

    var candidates: Candidates = .{ .diff_output = diff_output, .status_output = status_output };
    appendCandidatePaths(allocator, diff_output, status_output, &candidates.paths) catch {
        candidates.deinit(allocator);
        return null;
    };
    debug_log.log("git_state.collectChangedSince: candidates={d}", .{candidates.paths.items.len});
    return candidates;
}

/// Parse diff and porcelain-v1 status output into a deduplicated path list.
/// Slices borrow the output buffers.
pub fn appendCandidatePaths(
    allocator: std.mem.Allocator,
    diff_output: []const u8,
    status_output: []const u8,
    out: *std.ArrayListUnmanaged([]const u8),
) !void {
    var seen: std.StringHashMapUnmanaged(void) = .empty;
    defer seen.deinit(allocator);

    var diff_lines = std.mem.splitScalar(u8, diff_output, '\n');
    while (diff_lines.next()) |line| {
        const path = std.mem.trimRight(u8, line, "\r");
        if (path.len == 0) continue;
        try appendUnique(allocator, &seen, out, path);
    }

    var status_lines = std.mem.splitScalar(u8, status_output, '\n');
    while (status_lines.next()) |line| {
        const trimmed = std.mem.trimRight(u8, line, "\r");
        if (trimmed.len < 4) continue;
        if (std.mem.startsWith(u8, trimmed, "!!")) continue;
        const body = trimmed[3..];
        if (std.mem.indexOf(u8, body, " -> ")) |arrow| {
            try appendUnique(allocator, &seen, out, body[0..arrow]);
            try appendUnique(allocator, &seen, out, body[arrow + 4 ..]);
        } else {
            try appendUnique(allocator, &seen, out, body);
        }
    }
}

fn appendUnique(
    allocator: std.mem.Allocator,
    seen: *std.StringHashMapUnmanaged(void),
    out: *std.ArrayListUnmanaged([]const u8),
    path: []const u8,
) !void {
    const entry = try seen.getOrPut(allocator, path);
    if (entry.found_existing) return;
    try out.append(allocator, path);
}

fn runGit(allocator: std.mem.Allocator, project_root: []const u8, argv: []const []const u8) ?[]u8 {
    const run = std.process.Child.run(.{
        .allocator = allocator,
        .argv = argv,
        .cwd = project_root,
        .max_output_bytes = max_git_output_bytes,
    }) catch |err| {
        debug_log.log("git_state.runGit: spawn failed: {s}", .{@errorName(err)});
        return null;
    };
    allocator.free(run.stderr);
    switch (run.term) {
        .Exited => |code| if (code == 0) return run.stdout,
        else => {},
    }
    debug_log.log("git_state.runGit: {s} failed", .{argv[3]});
    allocator.free(run.stdout);
    return null;
}

test "candidate parsing merges diff and status output" {
    const allocator = std.testing.allocator;
    var out: std.ArrayListUnmanaged([]const u8) = .empty;
    defer out.deinit(allocator);

    const diff = "src/a.go\nsrc/b.go\n";
    const status =
        " M src/b.go\n" ++
        "?? src/new.go\n" ++
        " D src/gone.go\n" ++
        "R  src/old.go -> src/renamed.go\n" ++
        "!! ignored.go\n";
    try appendCandidatePaths(allocator, diff, status, &out);

    const expected = [_][]const u8{ "src/a.go", "src/b.go", "src/new.go", "src/gone.go", "src/old.go", "src/renamed.go" };
    try std.testing.expectEqual(expected.len, out.items.len);
    for (expected, out.items) |want, got| {
        try std.testing.expectEqualStrings(want, got);
    }
}

test "resolveHeadCommit reads loose refs, packed refs, and detached heads" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(root);
    const loose_hash = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
    const packed_hash = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb";

    try tmp.dir.makePath(".git/refs/heads");
    try tmp.dir.writeFile(.{ .sub_path = ".git/HEAD", .data = "ref: refs/heads/main\n" });
    try tmp.dir.writeFile(.{ .sub_path = ".git/refs/heads/main", .data = loose_hash ++ "\n" });

    const loose = resolveHeadCommit(allocator, root) orelse return error.TestUnexpectedResult;
    defer allocator.free(loose);
    try std.testing.expectEqualStrings(loose_hash, loose);

    // Packed-only ref: the loose file is gone after git pack-refs.
    try tmp.dir.deleteFile(".git/refs/heads/main");
    try tmp.dir.writeFile(.{ .sub_path = ".git/packed-refs", .data = "# pack-refs with: peeled fully-peeled sorted \n" ++ packed_hash ++ " refs/heads/main\n" });
    const from_packed = resolveHeadCommit(allocator, root) orelse return error.TestUnexpectedResult;
    defer allocator.free(from_packed);
    try std.testing.expectEqualStrings(packed_hash, from_packed);

    // Detached HEAD carries the hash directly.
    try tmp.dir.writeFile(.{ .sub_path = ".git/HEAD", .data = loose_hash ++ "\n" });
    const detached = resolveHeadCommit(allocator, root) orelse return error.TestUnexpectedResult;
    defer allocator.free(detached);
    try std.testing.expectEqualStrings(loose_hash, detached);
}

test "resolveHeadCommit follows worktree commondirs" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const wt_hash = "cccccccccccccccccccccccccccccccccccccccc";

    try tmp.dir.makePath("repo/.git/refs/heads");
    try tmp.dir.makePath("repo/.git/worktrees/wt");
    try tmp.dir.makePath("wt");
    try tmp.dir.writeFile(.{ .sub_path = "repo/.git/refs/heads/feature", .data = wt_hash ++ "\n" });
    try tmp.dir.writeFile(.{ .sub_path = "repo/.git/worktrees/wt/HEAD", .data = "ref: refs/heads/feature\n" });
    try tmp.dir.writeFile(.{ .sub_path = "repo/.git/worktrees/wt/commondir", .data = "../..\n" });
    try tmp.dir.writeFile(.{ .sub_path = "wt/.git", .data = "gitdir: ../repo/.git/worktrees/wt\n" });

    const worktree_root = try tmp.dir.realpathAlloc(allocator, "wt");
    defer allocator.free(worktree_root);
    const resolved = resolveHeadCommit(allocator, worktree_root) orelse return error.TestUnexpectedResult;
    defer allocator.free(resolved);
    try std.testing.expectEqualStrings(wt_hash, resolved);
}

test "syncStamp reads a repository directory and tracks ref changes" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.makePath(".git/refs/heads");
    try tmp.dir.writeFile(.{ .sub_path = ".git/HEAD", .data = "ref: refs/heads/main\n" });
    try tmp.dir.writeFile(.{ .sub_path = ".git/refs/heads/main", .data = "0123456789abcdef\n" });
    try tmp.dir.writeFile(.{ .sub_path = ".git/index", .data = "DIRC" });

    const root = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(root);

    const first = syncStamp(allocator, root) orelse return error.TestUnexpectedResult;
    try std.testing.expect(first.head_mtime_ns != 0);
    try std.testing.expect(first.ref_mtime_ns != 0);
    try std.testing.expect(first.eql(first));

    // A commit moves the active ref; the stamp must change.
    var ref_file = try tmp.dir.openFile(".git/refs/heads/main", .{});
    defer ref_file.close();
    try ref_file.updateTimes(1_000_000, 1_000_000);
    const second = syncStamp(allocator, root) orelse return error.TestUnexpectedResult;
    try std.testing.expect(!first.eql(second));
}

test "syncStamp resolves linked worktree gitdir files" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.makePath("repo/.git/worktrees/wt");
    try tmp.dir.makePath("wt");
    try tmp.dir.writeFile(.{ .sub_path = "repo/.git/worktrees/wt/HEAD", .data = "ref: refs/heads/feature\n" });
    try tmp.dir.writeFile(.{ .sub_path = "wt/.git", .data = "gitdir: ../repo/.git/worktrees/wt\n" });

    const worktree_root = try tmp.dir.realpathAlloc(allocator, "wt");
    defer allocator.free(worktree_root);

    const stamp = syncStamp(allocator, worktree_root) orelse return error.TestUnexpectedResult;
    try std.testing.expect(stamp.head_mtime_ns != 0);
}

test "syncStamp is null outside git checkouts" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(root);
    try std.testing.expect(syncStamp(allocator, root) == null);

    // A .git file that is not a worktree pointer is not a checkout either.
    try tmp.dir.writeFile(.{ .sub_path = ".git", .data = "not a gitdir pointer\n" });
    try std.testing.expect(syncStamp(allocator, root) == null);
}
