const std = @import("std");
const agents_mod = @import("agents.zig");

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
    // If the shutdown byte cannot be delivered, reap the spawned server
    // instead of leaking it past the failed test.
    errdefer _ = child.kill() catch {};

    const child_stdin = child.stdin.?;
    child.stdin = null;
    {
        errdefer child_stdin.close();
        try child_stdin.writeAll(&.{0x03});
    }
    child_stdin.close();

    const term = try child.wait();
    switch (term) {
        .Exited => |code| if (code != 0) fail("MCP startup privacy probe exited with {d}\n", .{code}),
        else => fail("MCP startup privacy probe terminated unexpectedly\n", .{}),
    }

    // The product's diagnostic file is cog.log, so asserting one hard-coded
    // name would miss a regression; reject any Cog-named file in the isolated
    // temp directory and any log file anywhere under the runtime directory.
    var tmp_dir = try test_root.openDir("tmp", .{ .iterate = true });
    defer tmp_dir.close();
    var tmp_iter = tmp_dir.iterate();
    while (try tmp_iter.next()) |entry| {
        if (std.mem.startsWith(u8, entry.name, "cog")) {
            fail("MCP startup created shared temp state tmp/{s}\n", .{entry.name});
        }
    }

    var runtime_dir = try test_root.openDir("runtime", .{ .iterate = true });
    defer runtime_dir.close();
    var walker = try runtime_dir.walk(allocator);
    defer walker.deinit();
    while (try walker.next()) |entry| {
        if (entry.kind == .file and std.mem.endsWith(u8, entry.basename, ".log")) {
            fail("MCP startup created runtime log {s}\n", .{entry.path});
        }
    }
}

// ── Scratch init coverage for every registry host ───────────────────────

const user_prompt_marker = "Keep me.";
const user_json_marker = "user_preserved_entry";
const user_toml_marker = "[user_section]";

/// 1-based position of the agent in the alphabetical init menu (fresh homes
/// have no selection history, so the menu is sorted by display name).
fn menuNumberFor(target: agents_mod.Agent) usize {
    var number: usize = 1;
    for (agents_mod.agents) |agent| {
        if (std.mem.order(u8, agent.display_name, target.display_name) == .lt) number += 1;
    }
    return number;
}

fn seedFile(dir: std.fs.Dir, path: []const u8, data: []const u8) !void {
    if (std.fs.path.dirname(path)) |parent| try dir.makePath(parent);
    try dir.writeFile(.{ .sub_path = path, .data = data });
}

fn expectJsonFile(allocator: std.mem.Allocator, dir: std.fs.Dir, agent_id: []const u8, path: []const u8) []const u8 {
    const content = dir.readFileAlloc(allocator, path, 4 * 1024 * 1024) catch {
        fail("init[{s}]: expected file {s} is missing or unreadable\n", .{ agent_id, path });
    };
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, content, .{}) catch {
        fail("init[{s}]: {s} is not valid JSON:\n{s}\n", .{ agent_id, path, content });
    };
    if (parsed.value != .object) {
        fail("init[{s}]: {s} must contain a JSON object\n", .{ agent_id, path });
    }
    return content;
}

fn expectContains(agent_id: []const u8, path: []const u8, content: []const u8, needle: []const u8) void {
    if (std.mem.indexOf(u8, content, needle) == null) {
        fail("init[{s}]: {s} is missing expected content \"{s}\":\n{s}\n", .{ agent_id, path, needle, content });
    }
}

fn expectAbsent(dir: std.fs.Dir, agent_id: []const u8, path: []const u8) void {
    if (dir.access(path, .{})) {
        fail("init[{s}]: unexpected foreign host state at {s}\n", .{ agent_id, path });
    } else |_| {}
}

fn pathInSet(set: []const []const u8, path: []const u8) bool {
    for (set) |entry| {
        if (std.mem.eql(u8, entry, path)) return true;
    }
    return false;
}

/// Scratch init runs live outside the repository tree: init discovers project
/// state by walking up from the cwd toward `/`, so a scratch project nested
/// inside this repo would see the repo's own `.cog` directory. The base is
/// per-process inside the system temp dir so parallel or multi-user runs
/// never share scratch state.
fn initScratchBase(allocator: std.mem.Allocator) ![]const u8 {
    const tmp = std.posix.getenv("TMPDIR") orelse "/tmp";
    const trimmed = std.mem.trimRight(u8, tmp, "/");
    return std.fmt.allocPrint(allocator, "{s}/cli-state-scratch-{d}", .{ trimmed, std.c.getpid() });
}

fn runScratchInit(gpa: std.mem.Allocator, scratch_base: []const u8, cog_path: []const u8, agent: agents_mod.Agent) !void {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const root = try std.fmt.allocPrint(arena, "{s}/init-{s}", .{ scratch_base, agent.id });
    if (std.fs.cwd().access(root, .{})) {
        try std.fs.cwd().deleteTree(root);
    } else |_| {}
    for ([_][]const u8{ "project", "home", "runtime", "tmp" }) |sub| {
        const path = try std.fmt.allocPrint(arena, "{s}/{s}", .{ root, sub });
        try std.fs.cwd().makePath(path);
    }

    const project = try std.fs.cwd().realpathAlloc(arena, try std.fmt.allocPrint(arena, "{s}/project", .{root}));
    const home = try std.fs.cwd().realpathAlloc(arena, try std.fmt.allocPrint(arena, "{s}/home", .{root}));
    const runtime = try std.fs.cwd().realpathAlloc(arena, try std.fmt.allocPrint(arena, "{s}/runtime", .{root}));
    const temp = try std.fs.cwd().realpathAlloc(arena, try std.fmt.allocPrint(arena, "{s}/tmp", .{root}));

    var project_dir = try std.fs.cwd().openDir(project, .{});
    defer project_dir.close();

    // Pre-seed user-owned config so the run proves init merges rather than
    // destroys existing files.
    const prompt_file = agent.prompt_target.filename();
    try seedFile(project_dir, prompt_file, "# User notes\n\n" ++ user_prompt_marker ++ "\n");
    if (agent.mcp_path) |mcp_path| {
        switch (agent.mcp_format) {
            .toml => try seedFile(project_dir, mcp_path, user_toml_marker ++ "\nkeep = true\n"),
            else => try seedFile(project_dir, mcp_path, "{\n  \"" ++ user_json_marker ++ "\": {\n    \"keep\": true\n  }\n}\n"),
        }
    }

    var env = try std.process.getEnvMap(arena);
    try env.put("HOME", home);
    try env.put("XDG_RUNTIME_DIR", runtime);
    try env.put("TMPDIR", temp);
    env.remove("COG_OBSERVE_ENABLED");

    var child = std.process.Child.init(&.{ cog_path, "init" }, arena);
    child.cwd = project;
    child.env_map = &env;
    child.stdin_behavior = .Pipe;
    child.stdout_behavior = .Ignore;
    child.stderr_behavior = .Pipe;
    try child.spawn();

    // Drive the non-TTY fallback prompts: memory backend, project scan
    // confirmation, then agent selection by alphabetical menu number. The
    // child answers prompts strictly in stream order, so we always respond to
    // whichever pending marker appears next; a prompt that never appears
    // leaves the child free to exit and the run fails with a clear message.
    const menu_response = try std.fmt.allocPrint(arena, "{d}\n", .{menuNumberFor(agent)});
    const Prompt = struct {
        marker: []const u8,
        response: []const u8,
        answered: bool = false,
    };
    var prompts = [_]Prompt{
        .{ .marker = "  > ", .response = "1\n" },
        .{ .marker = "(y/N)", .response = "n\n" },
        .{ .marker = "Enter numbers separated by commas:", .response = menu_response },
    };

    var stderr_data: std.ArrayListUnmanaged(u8) = .empty;
    var answered: usize = 0;
    var search_from: usize = 0;
    const child_stderr = child.stderr.?;
    var buf: [4096]u8 = undefined;
    while (true) {
        const n = child_stderr.read(&buf) catch 0;
        if (n == 0) break;
        try stderr_data.appendSlice(arena, buf[0..n]);

        while (answered < prompts.len) {
            var next: ?usize = null;
            var next_pos: usize = 0;
            for (&prompts, 0..) |*prompt, prompt_index| {
                if (prompt.answered) continue;
                const pos = std.mem.indexOfPos(u8, stderr_data.items, search_from, prompt.marker) orelse continue;
                if (next == null or pos < next_pos) {
                    next = prompt_index;
                    next_pos = pos;
                }
            }
            const chosen = next orelse break;
            search_from = next_pos + prompts[chosen].marker.len;
            try child.stdin.?.writeAll(prompts[chosen].response);
            prompts[chosen].answered = true;
            answered += 1;
            if (answered == prompts.len) {
                child.stdin.?.close();
                child.stdin = null;
            }
        }
    }

    const term = try child.wait();
    switch (term) {
        .Exited => |code| if (code != 0) {
            fail("init[{s}]: exited with {d}\nstderr:\n{s}\n", .{ agent.id, code, stderr_data.items });
        },
        else => fail("init[{s}]: terminated unexpectedly\nstderr:\n{s}\n", .{ agent.id, stderr_data.items }),
    }
    if (answered != prompts.len) {
        fail("init[{s}]: only {d}/{d} prompts were answered\nstderr:\n{s}\n", .{ agent.id, answered, prompts.len, stderr_data.items });
    }

    // Collect every path this host is expected to own after init.
    var expected_buf: [8][]const u8 = undefined;
    var expected_count: usize = 0;
    expected_buf[expected_count] = prompt_file;
    expected_count += 1;
    if (agent.mcp_path) |mcp_path| {
        expected_buf[expected_count] = mcp_path;
        expected_count += 1;
    }
    const installed_kinds = [_]agents_mod.SpecialistKind{ .code_query, .debug, .memory, .validate };
    for (installed_kinds) |kind| {
        const path = agent.specialistPath(kind) orelse {
            fail("init[{s}]: registry is missing a {s} specialist path\n", .{ agent.id, @tagName(kind) });
        };
        if (!pathInSet(expected_buf[0..expected_count], path)) {
            expected_buf[expected_count] = path;
            expected_count += 1;
        }
    }
    const expected = expected_buf[0..expected_count];

    // The prompt target keeps user content and gains the managed block.
    const prompt_content = project_dir.readFileAlloc(arena, prompt_file, 4 * 1024 * 1024) catch {
        fail("init[{s}]: prompt file {s} is missing\n", .{ agent.id, prompt_file });
    };
    expectContains(agent.id, prompt_file, prompt_content, user_prompt_marker);
    expectContains(agent.id, prompt_file, prompt_content, "<cog>");
    expectContains(agent.id, prompt_file, prompt_content, "</cog>");

    // The MCP config is valid, gains the cog server, and keeps user entries.
    if (agent.mcp_path) |mcp_path| {
        if (agent.mcp_format == .toml) {
            const content = project_dir.readFileAlloc(arena, mcp_path, 4 * 1024 * 1024) catch {
                fail("init[{s}]: expected MCP config {s} is missing\n", .{ agent.id, mcp_path });
            };
            expectContains(agent.id, mcp_path, content, "[mcp_servers.cog]");
            expectContains(agent.id, mcp_path, content, user_toml_marker);
        } else {
            const content = expectJsonFile(arena, project_dir, agent.id, mcp_path);
            expectContains(agent.id, mcp_path, content, "cog");
            expectContains(agent.id, mcp_path, content, user_json_marker);
        }
    }

    // Specialist assets exist with valid syntax; observe stays uninstalled
    // because the feature is disabled by default.
    const caps = agent.capabilities();
    if (caps.subagent_support == .shared_config) {
        const shared_path = agent.specialistPath(.code_query).?;
        if (agent.mcp_format == .toml) {
            const content = project_dir.readFileAlloc(arena, shared_path, 4 * 1024 * 1024) catch {
                fail("init[{s}]: shared specialist config {s} is missing\n", .{ agent.id, shared_path });
            };
            expectContains(agent.id, shared_path, content, "[agents.cog-code-query]");
            expectContains(agent.id, shared_path, content, "[agents.cog-debug]");
            expectContains(agent.id, shared_path, content, "[agents.cog-mem]");
            expectContains(agent.id, shared_path, content, "[agents.cog-mem-validate]");
            if (std.mem.indexOf(u8, content, "[agents.cog-observe]") != null) {
                fail("init[{s}]: observe specialist installed while disabled\n", .{agent.id});
            }
        } else {
            const content = expectJsonFile(arena, project_dir, agent.id, shared_path);
            expectContains(agent.id, shared_path, content, "cog-code-query");
            expectContains(agent.id, shared_path, content, "cog-debug");
            expectContains(agent.id, shared_path, content, "cog-mem");
            expectContains(agent.id, shared_path, content, "cog-mem-validate");
            if (std.mem.indexOf(u8, content, "cog-observe") != null) {
                fail("init[{s}]: observe specialist installed while disabled\n", .{agent.id});
            }
        }
    } else {
        for (installed_kinds) |kind| {
            const path = agent.specialistPath(kind).?;
            const content = project_dir.readFileAlloc(arena, path, 4 * 1024 * 1024) catch {
                fail("init[{s}]: expected specialist file {s} is missing\n", .{ agent.id, path });
            };
            if (!std.mem.startsWith(u8, content, "---")) {
                fail("init[{s}]: specialist file {s} is missing its frontmatter header\n", .{ agent.id, path });
            }
        }
        expectAbsent(project_dir, agent.id, agent.observe_file_path.?);
    }

    // Cog project state exists with valid syntax.
    _ = expectJsonFile(arena, project_dir, agent.id, ".cog/settings.json");
    _ = expectJsonFile(arena, project_dir, agent.id, ".cog/client-context.json");
    project_dir.access(".cog/.gitignore", .{}) catch {
        fail("init[{s}]: .cog/.gitignore was not created\n", .{agent.id});
    };

    // No other host receives any state from this run.
    for (agents_mod.agents) |other| {
        if (std.mem.eql(u8, other.id, agent.id)) continue;

        const candidates_buf: [8]?[]const u8 = .{
            other.mcp_path,
            other.agent_file_path,
            other.debug_file_path,
            other.mem_file_path,
            other.validate_file_path,
            other.observe_file_path,
            other.prompt_target.filename(),
            null,
        };
        for (candidates_buf[0..]) |candidate| {
            const path = candidate orelse continue;
            if (pathInSet(expected, path)) continue;
            expectAbsent(project_dir, agent.id, path);
        }
    }
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

    const scratch_base = try initScratchBase(allocator);
    defer allocator.free(scratch_base);
    for (agents_mod.agents) |agent| {
        try runScratchInit(allocator, scratch_base, cog_path, agent);
        std.debug.print("Scratch init coverage passed for {s}\n", .{agent.id});
    }
    std.fs.cwd().deleteTree(scratch_base) catch {};

    std.debug.print("CLI state isolation, MCP startup privacy, and scratch init tests passed\n", .{});
}
