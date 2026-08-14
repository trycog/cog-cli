const std = @import("std");

const COG_BINARY = "zig-out/bin/cog";
const TEST_ROOT = ".zig-cache/cli-state";

const CommandCase = struct {
    name: []const u8,
    args: []const []const u8,
};

const read_only_commands = [_]CommandCase{
    .{ .name = "no arguments", .args = &.{} },
    .{ .name = "top-level help", .args = &.{"--help"} },
    .{ .name = "top-level short help", .args = &.{"-h"} },
    .{ .name = "top-level help alias", .args = &.{"help"} },
    .{ .name = "version", .args = &.{"--version"} },
    .{ .name = "short version", .args = &.{"-v"} },
    .{ .name = "code group help", .args = &.{"code"} },
    .{ .name = "code command help", .args = &.{ "code:index", "--help" } },
    .{ .name = "code command short help", .args = &.{ "code:index", "-h" } },
    .{ .name = "debug group help", .args = &.{"debug"} },
    .{ .name = "debug command help", .args = &.{ "debug:serve", "--help" } },
    .{ .name = "memory group help", .args = &.{"mem"} },
    .{ .name = "memory command help", .args = &.{ "mem:bootstrap", "--help" } },
    .{ .name = "extension group help", .args = &.{"ext"} },
    .{ .name = "extension command help", .args = &.{ "ext:install", "--help" } },
    .{ .name = "legacy extension help", .args = &.{ "install", "--help" } },
    .{ .name = "MCP help", .args = &.{ "mcp", "--help" } },
    .{ .name = "init help", .args = &.{ "init", "--help" } },
    .{ .name = "init short help", .args = &.{ "init", "-h" } },
    .{ .name = "doctor help", .args = &.{ "doctor", "--help" } },
};

fn fail(comptime fmt: []const u8, args: anytype) noreturn {
    std.debug.print(fmt, args);
    std.process.exit(1);
}

fn getCogPath(allocator: std.mem.Allocator) ![]const u8 {
    const cwd = try std.fs.cwd().realpathAlloc(allocator, ".");
    defer allocator.free(cwd);
    return std.fmt.allocPrint(allocator, "{s}/{s}", .{ cwd, COG_BINARY });
}

fn recreateTestRoot() !void {
    if (std.fs.cwd().access(TEST_ROOT, .{})) {
        try std.fs.cwd().deleteTree(TEST_ROOT);
    } else |_| {}
    try std.fs.cwd().makePath(TEST_ROOT);
}

fn expectExitedZero(command: CommandCase, result: std.process.Child.RunResult) void {
    switch (result.term) {
        .Exited => |code| {
            if (code == 0) return;
            fail(
                "{s} failed with exit code {d}\nstdout:\n{s}\nstderr:\n{s}\n",
                .{ command.name, code, result.stdout, result.stderr },
            );
        },
        else => fail(
            "{s} terminated unexpectedly\nstdout:\n{s}\nstderr:\n{s}\n",
            .{ command.name, result.stdout, result.stderr },
        ),
    }
}

fn expectNoProjectState(command_name: []const u8) !void {
    var test_root = try std.fs.cwd().openDir(TEST_ROOT, .{ .iterate = true });
    defer test_root.close();

    var entries = test_root.iterate();
    if (try entries.next()) |entry| {
        fail(
            "{s} created unexpected project state at {s}/{s}\n",
            .{ command_name, TEST_ROOT, entry.name },
        );
    }
}

fn runMcpStartupPrivacyRegression(allocator: std.mem.Allocator, cog_path: []const u8) !void {
    try recreateTestRoot();
    var test_root = try std.fs.cwd().openDir(TEST_ROOT, .{});
    defer test_root.close();
    try test_root.makePath(".cog");
    try test_root.makePath("home");
    try test_root.makePath("runtime");
    try test_root.makePath("tmp");
    try test_root.writeFile(.{ .sub_path = ".cog/settings.json", .data = "{}\n" });

    const home = try test_root.realpathAlloc(allocator, "home");
    defer allocator.free(home);
    const runtime = try test_root.realpathAlloc(allocator, "runtime");
    defer allocator.free(runtime);
    const temp = try test_root.realpathAlloc(allocator, "tmp");
    defer allocator.free(temp);

    var env = try std.process.getEnvMap(allocator);
    defer env.deinit();
    try env.put("HOME", home);
    try env.put("XDG_RUNTIME_DIR", runtime);
    try env.put("TMPDIR", temp);

    var child = std.process.Child.init(&.{ cog_path, "mcp" }, allocator);
    child.cwd = TEST_ROOT;
    child.env_map = &env;
    child.stdin_behavior = .Pipe;
    child.stdout_behavior = .Ignore;
    child.stderr_behavior = .Ignore;
    try child.spawn();

    const child_stdin = child.stdin.?;
    child.stdin = null;
    try child_stdin.writeAll(&.{0x03});
    child_stdin.close();

    const term = try child.wait();
    switch (term) {
        .Exited => |code| if (code != 0) fail("MCP startup privacy probe exited with {d}\n", .{code}),
        else => fail("MCP startup privacy probe terminated unexpectedly\n", .{}),
    }

    try std.testing.expectError(error.FileNotFound, test_root.access("tmp/cog-mcp.log", .{}));
    try std.testing.expectError(error.FileNotFound, test_root.access("runtime/cog-mcp.log", .{}));
}

pub fn main() !void {
    var gpa: std.heap.GeneralPurposeAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const cog_path = try getCogPath(allocator);
    defer allocator.free(cog_path);

    for (read_only_commands) |command| {
        try recreateTestRoot();

        const argv = try allocator.alloc([]const u8, command.args.len + 1);
        defer allocator.free(argv);
        argv[0] = cog_path;
        @memcpy(argv[1..], command.args);

        const result = try std.process.Child.run(.{
            .allocator = allocator,
            .argv = argv,
            .cwd = TEST_ROOT,
            .max_output_bytes = 256 * 1024,
        });
        defer allocator.free(result.stdout);
        defer allocator.free(result.stderr);

        expectExitedZero(command, result);
        try expectNoProjectState(command.name);
    }

    try runMcpStartupPrivacyRegression(allocator, cog_path);
    std.debug.print("CLI state isolation and MCP startup privacy tests passed\n", .{});
}
