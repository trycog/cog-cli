const std = @import("std");
const posix = std.posix;
const build_options = @import("build_options");
const paths = @import("paths.zig");
const scip = @import("scip.zig");
const protobuf = @import("protobuf.zig");
const tui = @import("tui.zig");
const help_text = @import("help_text.zig");
const config_mod = @import("config.zig");
const client = @import("client.zig");

// ANSI styles
const cyan = "\x1B[36m";
const bold = "\x1B[1m";
const dim = "\x1B[2m";
const reset = "\x1B[0m";
const green = "\x1B[32m";
const red = "\x1B[31m";

// ── Ctrl+C handling ─────────────────────────────────────────────────────
// Track active child PIDs so Ctrl+C can kill them immediately.
// Uses a watchdog thread that reads stdin in raw mode, bypassing OS signal
// delivery which can be unreliable when the terminal's ISIG flag is off.

const max_active_children = 16;
var g_active_children: [max_active_children]std.atomic.Value(i32) = initChildSlots();

fn initChildSlots() [max_active_children]std.atomic.Value(i32) {
    var slots: [max_active_children]std.atomic.Value(i32) = undefined;
    for (&slots) |*s| s.* = std.atomic.Value(i32).init(0);
    return slots;
}

fn registerChild(pid: i32) void {
    for (&g_active_children) |*slot| {
        if (slot.cmpxchgStrong(0, pid, .monotonic, .monotonic) == null) return;
    }
}

fn unregisterChild(pid: i32) void {
    for (&g_active_children) |*slot| {
        if (slot.cmpxchgStrong(pid, 0, .monotonic, .monotonic) == null) return;
    }
}

fn killAllChildren() void {
    for (&g_active_children) |*slot| {
        const pid = slot.load(.monotonic);
        if (pid > 0) {
            _ = std.c.kill(pid, posix.SIG.KILL);
        }
    }
}

/// Watchdog thread that monitors stdin for Ctrl+C (byte 0x03) in raw mode.
/// More reliable than SIGINT signal handlers because it works regardless of
/// the terminal's ISIG flag state.
const CtrlCWatchdog = struct {
    stop: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    original_termios: posix.termios = undefined,
    has_termios: bool = false,
    fd: posix.fd_t = 0,

    fn start(self: *CtrlCWatchdog) ?std.Thread {
        self.fd = std.fs.File.stdin().handle;
        if (!posix.isatty(self.fd)) return null;

        self.original_termios = posix.tcgetattr(self.fd) catch return null;
        self.has_termios = true;

        var raw = self.original_termios;
        raw.lflag.ICANON = false;
        raw.lflag.ECHO = false;
        raw.lflag.ISIG = false;
        raw.cc[@intFromEnum(std.c.V.MIN)] = 0;
        raw.cc[@intFromEnum(std.c.V.TIME)] = 2; // 200ms timeout
        posix.tcsetattr(self.fd, .NOW, raw) catch return null;

        return std.Thread.spawn(.{}, watchFn, .{self}) catch {
            self.restore();
            return null;
        };
    }

    fn watchFn(self: *CtrlCWatchdog) void {
        while (!self.stop.load(.acquire)) {
            var buf: [1]u8 = undefined;
            const n = posix.read(self.fd, &buf) catch break;
            if (n == 0) continue; // timeout
            if (buf[0] == 3) self.cancel(); // Ctrl+C
        }
    }

    fn cancel(self: *CtrlCWatchdog) noreturn {
        killAllChildren();
        self.restore();
        const msg = "\x1B[0m\n  Cancelled.\n";
        _ = std.c.write(2, msg, msg.len);
        std.c._exit(130);
    }

    fn restore(self: *CtrlCWatchdog) void {
        if (self.has_termios) {
            posix.tcsetattr(self.fd, .NOW, self.original_termios) catch {};
        }
    }

    fn stopAndJoin(self: *CtrlCWatchdog, thread: ?std.Thread) void {
        self.stop.store(true, .release);
        if (thread) |t| t.join();
        self.restore();
    }
};

/// Fallback SIGINT handler for programmatic signals (e.g. kill -INT).
fn installSigintHandler() void {
    const sa = posix.Sigaction{
        .handler = .{ .handler = handleSigint },
        .mask = posix.sigemptyset(),
        .flags = 0,
    };
    posix.sigaction(posix.SIG.INT, &sa, null);
}

fn handleSigint(_: c_int) callconv(.c) void {
    killAllChildren();
    const msg = "\n  Cancelled.\n";
    _ = std.c.write(2, msg, msg.len);
    std.c._exit(130);
}

// ── Reaper process for SIGKILL orphan cleanup ───────────────────────────
// When the parent is killed with `kill -9`, child processes become orphans.
// A reaper is a tiny forked process that blocks on a pipe. The parent holds
// the write end; when the parent dies the kernel closes it, the reaper gets
// EOF and kills the target child.

const ReaperHandle = struct {
    pipe_write_fd: posix.fd_t,
    reaper_pid: posix.pid_t,
};

/// Fork a reaper process that will kill `target_pid` if the parent dies
/// without calling `dismissReaper`. Returns a handle the parent uses to
/// signal normal completion.
fn spawnReaper(target_pid: i32) ?ReaperHandle {
    if (target_pid <= 0) return null;

    const pipe_fds = posix.pipe() catch return null;
    // pipe_fds[0] = read end, pipe_fds[1] = write end

    const pid = posix.fork() catch {
        posix.close(pipe_fds[0]);
        posix.close(pipe_fds[1]);
        return null;
    };

    if (pid == 0) {
        // ── Reaper child process ──
        // Close write end — only the parent should hold it.
        posix.close(pipe_fds[1]);

        // Block until parent writes (normal exit) or pipe breaks (parent killed).
        var buf: [1]u8 = undefined;
        const n = posix.read(pipe_fds[0], &buf) catch 0;
        posix.close(pipe_fds[0]);

        if (n == 0) {
            // EOF — parent died. Kill the target child.
            _ = std.c.kill(target_pid, posix.SIG.KILL);
        }
        // n > 0 → parent dismissed us; target exited normally.
        std.c._exit(0);
    }

    // ── Parent process ──
    posix.close(pipe_fds[0]); // Don't need read end.

    return .{
        .pipe_write_fd = pipe_fds[1],
        .reaper_pid = pid,
    };
}

/// Tell the reaper that the child exited normally (don't kill it),
/// then wait for the reaper to exit to avoid zombies.
fn dismissReaper(handle: ?ReaperHandle) void {
    const h = handle orelse return;
    // Send a byte so the reaper's read() returns n > 0.
    _ = posix.write(h.pipe_write_fd, &[_]u8{0x01}) catch {};
    posix.close(h.pipe_write_fd);
    // Reap the reaper to prevent zombies.
    _ = posix.waitpid(h.reaper_pid, 0);
}

// ── Brain empty check ───────────────────────────────────────────────────
// Calls cog_stats via the brain's MCP endpoint to check if the brain has
// any engrams. Used to detect stale checkpoints after a brain reset.

fn isBrainEmpty(allocator: std.mem.Allocator) bool {
    // Load config silently — no error output if unconfigured.
    const api_key = config_mod.getApiKey(allocator) catch return false;
    defer allocator.free(api_key);

    const cog_content = config_mod.findCogFile(allocator) catch return false;
    defer allocator.free(cog_content);

    const brain_url = config_mod.resolveBrainUrl(allocator, cog_content) catch return false;
    defer allocator.free(brain_url);

    const endpoint = std.fmt.allocPrint(allocator, "{s}/mcp", .{brain_url}) catch return false;
    defer allocator.free(endpoint);

    const body =
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/call\"," ++
        "\"params\":{\"name\":\"cog_stats\",\"arguments\":{}}}";

    const response = client.postRaw(allocator, endpoint, api_key, body) catch return false;
    defer allocator.free(response.body);

    if (response.status_code != 200) return false;

    // Parse JSON-RPC response: {"result":{"content":[{"type":"text","text":"{...}"}]}}
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, response.body, .{}) catch return false;
    defer parsed.deinit();

    const text = extractMcpResultText(parsed.value) orelse return false;

    // Parse the inner JSON for engram count
    const inner = std.json.parseFromSlice(std.json.Value, allocator, text, .{}) catch return false;
    defer inner.deinit();

    if (inner.value != .object) return false;

    if (inner.value.object.get("total_engrams")) |v| {
        return switch (v) {
            .integer => v.integer == 0,
            else => false,
        };
    }

    return false;
}

fn extractMcpResultText(root: std.json.Value) ?[]const u8 {
    if (root != .object) return null;
    const result_val = root.object.get("result") orelse return null;
    if (result_val != .object) return null;
    const content = result_val.object.get("content") orelse return null;
    if (content != .array or content.array.items.len == 0) return null;
    const first = content.array.items[0];
    if (first != .object) return null;
    const text_val = first.object.get("text") orelse return null;
    if (text_val != .string) return null;
    return text_val.string;
}

fn printErr(msg: []const u8) void {
    if (@import("builtin").is_test) return;
    var buf: [4096]u8 = undefined;
    var w = std.fs.File.stderr().writer(&buf);
    w.interface.writeAll(msg) catch {};
    w.interface.flush() catch {};
}

fn printFmtErr(allocator: std.mem.Allocator, comptime fmt: []const u8, args: anytype) void {
    const msg = std.fmt.allocPrint(allocator, fmt, args) catch return;
    defer allocator.free(msg);
    printErr(msg);
}

// ── Agent CLI definitions ───────────────────────────────────────────────
// Only agents that support non-interactive CLI prompting are listed here.

const CliAgent = struct {
    id: []const u8,
    display_name: []const u8,
    cmd_prefix: []const []const u8,
    cmd_suffix: []const []const u8,
    /// Environment variables to unset before spawning (via env -u wrapper).
    env_unset: []const []const u8,
};

const cli_agents = [_]CliAgent{
    .{
        .id = "claude_code",
        .display_name = "Claude Code",
        .cmd_prefix = &.{ "claude", "-p" },
        .cmd_suffix = &.{ "--output-format", "json", "--dangerously-skip-permissions" },
        .env_unset = &.{ "CLAUDECODE", "CLAUDE_CODE_ENTRYPOINT" },
    },
    .{
        .id = "gemini",
        .display_name = "Gemini CLI",
        .cmd_prefix = &.{ "gemini", "-p" },
        .cmd_suffix = &.{ "--output-format", "json", "--yolo" },
        .env_unset = &.{},
    },
    .{
        .id = "codex",
        .display_name = "OpenAI Codex CLI",
        .cmd_prefix = &.{ "codex", "exec" },
        .cmd_suffix = &.{ "--json", "--full-auto" },
        .env_unset = &.{},
    },
    .{
        .id = "amp",
        .display_name = "Amp",
        .cmd_prefix = &.{ "amp", "-x" },
        .cmd_suffix = &.{ "--stream-json", "--dangerously-allow-all" },
        .env_unset = &.{},
    },
    .{
        .id = "goose",
        .display_name = "Goose",
        .cmd_prefix = &.{ "goose", "run", "-t" },
        .cmd_suffix = &.{ "--output-format", "json" },
        .env_unset = &.{},
    },
    .{
        .id = "opencode",
        .display_name = "OpenCode",
        .cmd_prefix = &.{ "opencode", "run" },
        .cmd_suffix = &.{ "--format", "json" },
        .env_unset = &.{},
    },
};

/// Dispatch mem:* subcommands.
pub fn dispatch(allocator: std.mem.Allocator, subcmd: []const u8, args: []const [:0]const u8) !void {
    if (std.mem.eql(u8, subcmd, "mem:bootstrap")) {
        return memBootstrap(allocator, args);
    }

    printErr("error: unknown command '");
    printErr(subcmd);
    printErr("'\nRun " ++ dim ++ "cog mem --help" ++ reset ++ " to see available commands.\n");
    return error.Explained;
}

fn hasFlag(args: []const [:0]const u8, flag: []const u8) bool {
    for (args) |arg| {
        if (std.mem.eql(u8, arg, flag)) return true;
    }
    return false;
}

fn getFlagValue(args: []const [:0]const u8, flag: []const u8) ?[]const u8 {
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg: []const u8 = args[i];
        if (std.mem.eql(u8, arg, flag)) {
            if (i + 1 < args.len) return args[i + 1];
            return null;
        }
        // Handle --flag=value
        if (std.mem.startsWith(u8, arg, flag) and arg.len > flag.len and arg[flag.len] == '=') {
            return arg[flag.len + 1 ..];
        }
    }
    return null;
}

fn memBootstrap(allocator: std.mem.Allocator, args: []const [:0]const u8) !void {
    if (hasFlag(args, "--help") or hasFlag(args, "-h")) {
        tui.header();
        printErr(help_text.mem_bootstrap);
        return;
    }

    tui.header();

    // Parse options
    const concurrency: usize = if (getFlagValue(args, "--concurrency")) |v|
        std.fmt.parseInt(usize, v, 10) catch {
            printErr("error: invalid --concurrency value\n");
            return error.Explained;
        }
    else
        1;

    if (concurrency == 0) {
        printErr("error: --concurrency must be at least 1\n");
        return error.Explained;
    }

    const clean = hasFlag(args, "--clean");
    const debug = hasFlag(args, "--debug");

    // Require SCIP index
    const cog_dir = paths.findCogDir(allocator) catch {
        printErr("error: no .cog directory found. Run " ++ dim ++ "cog code:index" ++ reset ++ " first.\n");
        return error.Explained;
    };
    defer allocator.free(cog_dir);

    const index_path = try std.fmt.allocPrint(allocator, "{s}/index.scip", .{cog_dir});
    defer allocator.free(index_path);

    {
        const index_file = std.fs.openFileAbsolute(index_path, .{}) catch {
            printErr("error: no SCIP index found. Run " ++ dim ++ "cog code:index" ++ reset ++ " first.\n");
            return error.Explained;
        };
        index_file.close();
    }

    // Agent selection menu
    var menu_items: [cli_agents.len + 1]tui.MenuItem = undefined;
    for (cli_agents, 0..) |agent, i| {
        menu_items[i] = .{ .label = agent.display_name };
    }
    menu_items[cli_agents.len] = .{ .label = "Custom command", .is_input_option = true };

    printErr("\n");
    const agent_result = try tui.select(allocator, .{
        .prompt = "Select an agent to run bootstrap:",
        .items = &menu_items,
    });

    const selected_agent: ?*const CliAgent = switch (agent_result) {
        .selected => |idx| if (idx < cli_agents.len) &cli_agents[idx] else null,
        .input => null,
        .back, .cancelled => {
            printErr("  Aborted.\n");
            return;
        },
    };

    // For custom command, extract the user-typed command string
    const custom_cmd: ?[]const u8 = switch (agent_result) {
        .input => |cmd| cmd,
        else => null,
    };

    printErr("\n  " ++ dim ++ "This can take a while depending on the size of your codebase." ++ reset ++ "\n");
    printErr("  " ++ dim ++ "Progress is saved — press Ctrl+C to stop and resume later." ++ reset ++ "\n");

    try runBootstrap(allocator, concurrency, clean, debug, cog_dir, selected_agent, custom_cmd);
}

fn runBootstrap(
    allocator: std.mem.Allocator,
    concurrency: usize,
    clean: bool,
    debug: bool,
    cog_dir: []const u8,
    selected_agent: ?*const CliAgent,
    custom_cmd: ?[]const u8,
) !void {
    // Ctrl+C handling: watchdog thread monitors stdin directly,
    // SIGINT handler is a fallback for programmatic signals.
    installSigintHandler();
    var watchdog = CtrlCWatchdog{};
    const watchdog_thread = watchdog.start();
    defer watchdog.stopAndJoin(watchdog_thread);

    // Get project root (cwd)
    const project_root = try std.fs.cwd().realpathAlloc(allocator, ".");
    defer allocator.free(project_root);

    // Collect files
    printErr("\n" ++ bold ++ "  Collecting files..." ++ reset ++ "\n");
    var files = try collectSourceFiles(allocator, cog_dir);
    defer {
        for (files.items) |f| allocator.free(f);
        files.deinit(allocator);
    }

    if (files.items.len == 0) {
        printErr("  No files found to process.\n\n");
        return;
    }
    printFmtErr(allocator, "  Found {d} files\n", .{files.items.len});

    const checkpoint_path = try std.fmt.allocPrint(allocator, "{s}/bootstrap-checkpoint.json", .{cog_dir});
    defer allocator.free(checkpoint_path);

    if (clean) {
        std.fs.deleteFileAbsolute(checkpoint_path) catch {};
        printErr("  Checkpoint cleared\n");
    } else {
        // If brain is empty but a checkpoint exists, the brain was reset —
        // delete the stale checkpoint so bootstrap starts fresh.
        const checkpoint_exists = blk: {
            const f = std.fs.openFileAbsolute(checkpoint_path, .{}) catch break :blk false;
            f.close();
            break :blk true;
        };
        if (checkpoint_exists and isBrainEmpty(allocator)) {
            std.fs.deleteFileAbsolute(checkpoint_path) catch {};
            printErr("  Brain is empty — checkpoint cleared, starting fresh\n");
        }
    }

    var processed = loadCheckpoint(allocator, checkpoint_path);
    defer {
        var it = processed.keyIterator();
        while (it.next()) |key| allocator.free(key.*);
        processed.deinit(allocator);
    }

    // Filter out already-processed files
    var remaining: std.ArrayListUnmanaged([]const u8) = .empty;
    defer remaining.deinit(allocator);
    for (files.items) |f| {
        if (!processed.contains(f)) {
            try remaining.append(allocator, f);
        }
    }

    if (remaining.items.len == 0) {
        printErr("  All files already processed. Use " ++ dim ++ "--clean" ++ reset ++ " to restart.\n\n");
        return;
    }

    if (processed.count() > 0) {
        printFmtErr(allocator, "  Resuming: {d} remaining ({d} already processed)\n", .{ remaining.items.len, processed.count() });
    }

    // Print agent info
    if (selected_agent) |agent| {
        printFmtErr(allocator, "  Agent: " ++ bold ++ "{s}" ++ reset ++ "\n", .{agent.display_name});
    } else if (custom_cmd) |cmd| {
        printFmtErr(allocator, "  Agent: " ++ bold ++ "{s}" ++ reset ++ "\n", .{cmd});
    }

    const total_files = remaining.items.len;
    const use_tui = !debug and tui.isStderrTty();

    if (use_tui) {
        tui.bootstrapStart("Bootstrapping", total_files);
    } else {
        printFmtErr(allocator, "  Processing {d} files (concurrency={d})\n\n", .{ total_files, concurrency });
    }

    var files_done: usize = 0;
    var errors: usize = 0;
    var total_input_tokens: usize = 0;
    var total_output_tokens: usize = 0;
    var total_cost_microdollars: usize = 0; // cost * 1_000_000

    // Activity ticker — background thread that shows a spinner + elapsed time
    var tui_mutex: std.Thread.Mutex = .{};
    var ticker_ctx = TickerContext{ .mutex = &tui_mutex };
    var ticker_thread: ?std.Thread = null;
    if (use_tui) {
        ticker_thread = std.Thread.spawn(.{}, tickerFn, .{&ticker_ctx}) catch null;
    }

    if (concurrency <= 1) {
        // Sequential processing — one file at a time
        for (remaining.items) |file_path| {
            if (use_tui) {
                tui_mutex.lock();
                ticker_ctx.current_label = file_path;
                ticker_ctx.start_ms = std.time.milliTimestamp();
                tui_mutex.unlock();
            } else {
                printFmtErr(allocator, "  " ++ cyan ++ "[{d}/{d}]" ++ reset ++ " {s}\n", .{
                    files_done + errors + 1,
                    total_files,
                    file_path,
                });
            }

            const result = runFile(allocator, file_path, project_root, selected_agent, custom_cmd, debug);
            if (result.success) {
                files_done += 1;
                total_input_tokens += result.input_tokens;
                total_output_tokens += result.output_tokens;
                total_cost_microdollars += result.cost_microdollars;
                const duped = allocator.dupe(u8, file_path) catch continue;
                processed.put(allocator, duped, {}) catch {
                    allocator.free(duped);
                };
                saveCheckpoint(allocator, checkpoint_path, &processed);
            } else {
                errors += 1;
            }

            if (use_tui) {
                tui_mutex.lock();
                tui.bootstrapUpdate(files_done + errors, total_files, errors, total_input_tokens, total_output_tokens, total_cost_microdollars, file_path);
                ticker_ctx.current_label = "";
                tui_mutex.unlock();
            } else if (result.success) {
                printFmtErr(allocator, "    " ++ green ++ "done" ++ reset ++ " ({d}/{d}) tokens: {d}in/{d}out ${s}\n", .{
                    files_done,
                    total_files,
                    total_input_tokens,
                    total_output_tokens,
                    formatCost(allocator, total_cost_microdollars),
                });
            } else {
                printErr("    " ++ red ++ "failed" ++ reset ++ "\n");
            }
        }
    } else {
        // Concurrent processing — thread pool of `concurrency` workers
        var file_index = std.atomic.Value(usize).init(0);
        var done_count = std.atomic.Value(usize).init(0);
        var error_count = std.atomic.Value(usize).init(0);
        var atomic_input_tokens = std.atomic.Value(usize).init(0);
        var atomic_output_tokens = std.atomic.Value(usize).init(0);
        var atomic_cost = std.atomic.Value(usize).init(0);

        var shared = WorkerShared{
            .file_index = &file_index,
            .done_count = &done_count,
            .error_count = &error_count,
            .atomic_input_tokens = &atomic_input_tokens,
            .atomic_output_tokens = &atomic_output_tokens,
            .atomic_cost = &atomic_cost,
            .remaining = remaining.items,
            .total_files = total_files,
            .project_root = project_root,
            .selected_agent = selected_agent,
            .custom_cmd = custom_cmd,
            .allocator = allocator,
            .checkpoint_path = checkpoint_path,
            .processed = &processed,
            .debug = debug,
            .use_tui = use_tui,
            .tui_mutex = &tui_mutex,
            .ticker = if (use_tui) &ticker_ctx else null,
        };

        // Spawn worker threads
        var threads: std.ArrayListUnmanaged(std.Thread) = .empty;
        defer threads.deinit(allocator);

        const worker_count = @min(concurrency, total_files);
        for (0..worker_count) |_| {
            const thread = std.Thread.spawn(.{}, workerThread, .{&shared}) catch continue;
            try threads.append(allocator, thread);
        }

        // Join all
        for (threads.items) |thread| {
            thread.join();
        }

        files_done = done_count.load(.acquire);
        errors = error_count.load(.acquire);
        total_input_tokens = atomic_input_tokens.load(.acquire);
        total_output_tokens = atomic_output_tokens.load(.acquire);
        total_cost_microdollars = atomic_cost.load(.acquire);
    }

    // Stop ticker before phase 1 finish
    stopTicker(&ticker_thread, &ticker_ctx);

    // Phase 1 finish
    if (use_tui) {
        tui.bootstrapFinish("Bootstrapping", files_done + errors, errors, total_input_tokens, total_output_tokens, total_cost_microdollars);
    } else {
        printErr("\n" ++ bold ++ "  Phase 1: Extraction Summary" ++ reset ++ "\n");
        printFmtErr(allocator, "    Files processed: {d}\n", .{files_done});
        if (errors > 0) {
            printFmtErr(allocator, "    Errors:          {d}\n", .{errors});
        }
        printFmtErr(allocator, "    Input tokens:    {d}\n", .{total_input_tokens});
        printFmtErr(allocator, "    Output tokens:   {d}\n", .{total_output_tokens});
        printFmtErr(allocator, "    Cost:            ${s}\n", .{formatCost(allocator, total_cost_microdollars)});
        printFmtErr(allocator, "    Total processed: {d}/{d}\n", .{ processed.count(), files.items.len });
    }

    // Phase 2: Cross-file association from SCIP index
    if (files_done > 1) {
        // Build cross-file relationship text from SCIP index
        const cross_file = buildCrossFileRelationships(allocator, cog_dir);
        defer if (cross_file) |cf| allocator.free(cf.text);

        if (cross_file) |cf| {
            if (cf.text.len == 0) {
                if (!use_tui) printErr("    No cross-file references found in SCIP index\n");
            } else {
                if (use_tui) {
                    tui.bootstrapPhaseStart("Associating", "Pairs", cf.pair_count);
                    startTicker(&ticker_thread, &ticker_ctx, "Running agent...");
                } else {
                    printErr("\n" ++ bold ++ "  Phase 2: Cross-file associations" ++ reset ++ "\n");
                    printFmtErr(allocator, "    Found {d} cross-file dependency pairs\n", .{cf.pair_count});
                }

                const assoc_result = runAssociationPhase(allocator, project_root, selected_agent, custom_cmd, cf.text, debug);

                stopTicker(&ticker_thread, &ticker_ctx);

                if (assoc_result.success) {
                    total_input_tokens += assoc_result.input_tokens;
                    total_output_tokens += assoc_result.output_tokens;
                    total_cost_microdollars += assoc_result.cost_microdollars;
                }

                if (use_tui) {
                    tui.bootstrapPhaseFinish("Associating", "Pairs", cf.pair_count, assoc_result.input_tokens, assoc_result.output_tokens, assoc_result.cost_microdollars, assoc_result.success);
                    tui.bootstrapTotal(total_input_tokens, total_output_tokens, total_cost_microdollars);
                } else {
                    if (assoc_result.success) {
                        printErr("    " ++ green ++ "done" ++ reset ++ "\n");
                    } else {
                        printErr("    " ++ red ++ "failed" ++ reset ++ "\n");
                    }
                    printErr("\n" ++ bold ++ "  Total" ++ reset ++ "\n");
                    printFmtErr(allocator, "    Input tokens:    {d}\n", .{total_input_tokens});
                    printFmtErr(allocator, "    Output tokens:   {d}\n", .{total_output_tokens});
                    printFmtErr(allocator, "    Cost:            ${s}\n", .{formatCost(allocator, total_cost_microdollars)});
                }
            }
        } else {
            if (!use_tui) printErr("    Could not load SCIP index for cross-file analysis\n");
        }
    }

    printErr("\n");
}

const WorkerShared = struct {
    file_index: *std.atomic.Value(usize),
    done_count: *std.atomic.Value(usize),
    error_count: *std.atomic.Value(usize),
    atomic_input_tokens: *std.atomic.Value(usize),
    atomic_output_tokens: *std.atomic.Value(usize),
    atomic_cost: *std.atomic.Value(usize),
    remaining: []const []const u8,
    total_files: usize,
    project_root: []const u8,
    selected_agent: ?*const CliAgent,
    custom_cmd: ?[]const u8,
    allocator: std.mem.Allocator,
    checkpoint_path: []const u8,
    processed: *std.StringHashMapUnmanaged(void),
    debug: bool,
    use_tui: bool,
    tui_mutex: *std.Thread.Mutex,
    ticker: ?*TickerContext,
};

fn workerThread(shared: *WorkerShared) void {
    while (true) {
        const idx = shared.file_index.fetchAdd(1, .monotonic);
        if (idx >= shared.remaining.len) break;

        const file_path = shared.remaining[idx];

        if (shared.use_tui) {
            if (shared.ticker) |ticker| {
                shared.tui_mutex.lock();
                ticker.current_label = file_path;
                ticker.start_ms = std.time.milliTimestamp();
                shared.tui_mutex.unlock();
            }
        } else {
            printFmtErr(shared.allocator, "  " ++ cyan ++ "[{d}/{d}]" ++ reset ++ " {s}\n", .{
                idx + 1,
                shared.total_files,
                file_path,
            });
        }

        const result = runFile(shared.allocator, file_path, shared.project_root, shared.selected_agent, shared.custom_cmd, shared.debug);
        if (result.success) {
            const done = shared.done_count.fetchAdd(1, .monotonic) + 1;
            _ = shared.atomic_input_tokens.fetchAdd(result.input_tokens, .monotonic);
            _ = shared.atomic_output_tokens.fetchAdd(result.output_tokens, .monotonic);
            _ = shared.atomic_cost.fetchAdd(result.cost_microdollars, .monotonic);
            const duped = shared.allocator.dupe(u8, file_path) catch continue;
            shared.processed.put(shared.allocator, duped, {}) catch {
                shared.allocator.free(duped);
            };
            saveCheckpoint(shared.allocator, shared.checkpoint_path, shared.processed);

            if (shared.use_tui) {
                shared.tui_mutex.lock();
                tui.bootstrapUpdate(
                    done + shared.error_count.load(.acquire),
                    shared.total_files,
                    shared.error_count.load(.acquire),
                    shared.atomic_input_tokens.load(.acquire),
                    shared.atomic_output_tokens.load(.acquire),
                    shared.atomic_cost.load(.acquire),
                    file_path,
                );
                shared.tui_mutex.unlock();
            } else {
                const in_tok = shared.atomic_input_tokens.load(.acquire);
                const out_tok = shared.atomic_output_tokens.load(.acquire);
                const cost = shared.atomic_cost.load(.acquire);
                printFmtErr(shared.allocator, "    " ++ green ++ "done" ++ reset ++ " {s} ({d}/{d}) tokens: {d}in/{d}out ${s}\n", .{
                    file_path,
                    done,
                    shared.total_files,
                    in_tok,
                    out_tok,
                    formatCost(shared.allocator, cost),
                });
            }
        } else {
            const errs = shared.error_count.fetchAdd(1, .monotonic) + 1;

            if (shared.use_tui) {
                shared.tui_mutex.lock();
                tui.bootstrapUpdate(
                    shared.done_count.load(.acquire) + errs,
                    shared.total_files,
                    errs,
                    shared.atomic_input_tokens.load(.acquire),
                    shared.atomic_output_tokens.load(.acquire),
                    shared.atomic_cost.load(.acquire),
                    file_path,
                );
                shared.tui_mutex.unlock();
            } else {
                printFmtErr(shared.allocator, "    " ++ red ++ "failed" ++ reset ++ " {s}\n", .{file_path});
            }
        }
    }
}

// ── Activity ticker ─────────────────────────────────────────────────────
// Background thread that redraws the bottom line of the TUI progress block
// with a spinner + elapsed time, giving clear visual feedback during
// long-running agent invocations.

const TickerContext = struct {
    mutex: *std.Thread.Mutex,
    stop: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    current_label: []const u8 = "",
    start_ms: i64 = 0,
};

const spinner_frames = [_][]const u8{ "\xe2\xa0\x8b", "\xe2\xa0\x99", "\xe2\xa0\xb9", "\xe2\xa0\xb8", "\xe2\xa0\xbc", "\xe2\xa0\xb4", "\xe2\xa0\xa6", "\xe2\xa0\xa7", "\xe2\xa0\x87", "\xe2\xa0\x8f" };

fn tickerFn(ctx: *TickerContext) void {
    var frame: usize = 0;
    while (!ctx.stop.load(.acquire)) {
        std.Thread.sleep(200 * std.time.ns_per_ms);
        if (ctx.stop.load(.acquire)) break;

        ctx.mutex.lock();
        defer ctx.mutex.unlock();

        const label = ctx.current_label;
        const start = ctx.start_ms;
        if (label.len == 0 or start == 0) continue;

        const now = std.time.milliTimestamp();
        const elapsed_ms = now - start;
        const elapsed_s: u64 = if (elapsed_ms > 0) @intCast(@divTrunc(elapsed_ms, 1000)) else 0;

        tui.bootstrapTickLine(spinner_frames[frame % spinner_frames.len], label, elapsed_s);
        frame +%= 1;
    }
}

fn stopTicker(ticker_thread: *?std.Thread, ticker_ctx: *TickerContext) void {
    if (ticker_thread.*) |t| {
        ticker_ctx.stop.store(true, .release);
        t.join();
        ticker_thread.* = null;
    }
}

fn startTicker(ticker_thread: *?std.Thread, ticker_ctx: *TickerContext, label: []const u8) void {
    ticker_ctx.stop = std.atomic.Value(bool).init(false);
    ticker_ctx.current_label = label;
    ticker_ctx.start_ms = std.time.milliTimestamp();
    ticker_thread.* = std.Thread.spawn(.{}, tickerFn, .{ticker_ctx}) catch null;
}

const FileResult = struct {
    success: bool,
    input_tokens: usize,
    output_tokens: usize,
    cost_microdollars: usize, // cost_usd * 1_000_000
};

fn runFile(
    allocator: std.mem.Allocator,
    file_path: []const u8,
    project_root: []const u8,
    selected_agent: ?*const CliAgent,
    custom_cmd: ?[]const u8,
    debug: bool,
) FileResult {
    const fail: FileResult = .{ .success = false, .input_tokens = 0, .output_tokens = 0, .cost_microdollars = 0 };

    // Build prompt: template with file path
    const template = build_options.bootstrap_prompt;
    const prompt = replacePlaceholder(allocator, template, "{file_path}", file_path) catch return fail;
    defer allocator.free(prompt);

    // Build argv
    var argv_buf: std.ArrayListUnmanaged([]const u8) = .empty;
    defer argv_buf.deinit(allocator);

    if (selected_agent) |agent| {
        // Prepend env -u for each env var to unset
        if (agent.env_unset.len > 0) {
            argv_buf.append(allocator, "env") catch return fail;
            for (agent.env_unset) |var_name| {
                argv_buf.append(allocator, "-u") catch return fail;
                argv_buf.append(allocator, var_name) catch return fail;
            }
        }
        for (agent.cmd_prefix) |token| {
            argv_buf.append(allocator, token) catch return fail;
        }
        argv_buf.append(allocator, prompt) catch return fail;
        for (agent.cmd_suffix) |token| {
            argv_buf.append(allocator, token) catch return fail;
        }
    } else if (custom_cmd) |cmd| {
        var cmd_iter = std.mem.splitScalar(u8, cmd, ' ');
        while (cmd_iter.next()) |token| {
            if (token.len > 0) {
                argv_buf.append(allocator, token) catch return fail;
            }
        }
        argv_buf.append(allocator, prompt) catch return fail;
    } else {
        return fail;
    }

    var child = std.process.Child.init(argv_buf.items, allocator);
    child.cwd = project_root;
    child.stderr_behavior = if (debug) .Inherit else .Ignore;
    child.stdout_behavior = .Pipe;

    child.spawn() catch |err| {
        printFmtErr(allocator, "    " ++ red ++ "spawn error: {s}" ++ reset ++ "\n", .{@errorName(err)});
        return fail;
    };
    const child_pid: i32 = child.id;
    if (child_pid > 0) registerChild(child_pid);
    const reaper = spawnReaper(child_pid);

    // Read stdout (JSON output from agents like Claude)
    const stdout_data = if (child.stdout) |stdout|
        stdout.readToEndAlloc(allocator, 10 * 1024 * 1024) catch null
    else
        null;
    defer if (stdout_data) |d| allocator.free(d);

    const term = child.wait() catch |err| {
        if (child_pid > 0) unregisterChild(child_pid);
        dismissReaper(reaper);
        printFmtErr(allocator, "    " ++ red ++ "wait error: {s}" ++ reset ++ "\n", .{@errorName(err)});
        return fail;
    };
    if (child_pid > 0) unregisterChild(child_pid);
    dismissReaper(reaper);

    switch (term) {
        .Exited => |code| {
            if (code != 0) {
                printFmtErr(allocator, "    " ++ red ++ "exited with code {d}" ++ reset ++ "\n", .{code});
                return fail;
            }
        },
        .Signal => |sig| {
            printFmtErr(allocator, "    " ++ red ++ "killed by signal {d}" ++ reset ++ "\n", .{sig});
            return fail;
        },
        else => return fail,
    }

    // Parse token usage from stdout
    const agent_id: ?[]const u8 = if (selected_agent) |a| a.id else null;
    var usage = UsageStats{};
    if (stdout_data) |data| {
        if (data.len > 0 and agent_id != null) {
            usage = parseUsageFromStdout(allocator, agent_id.?, data);
        }
    }

    return .{
        .success = true,
        .input_tokens = usage.input_tokens,
        .output_tokens = usage.output_tokens,
        .cost_microdollars = usage.cost_microdollars,
    };
}

fn runAssociationPhase(
    allocator: std.mem.Allocator,
    project_root: []const u8,
    selected_agent: ?*const CliAgent,
    custom_cmd: ?[]const u8,
    relationships_text: []const u8,
    debug: bool,
) FileResult {
    const fail: FileResult = .{ .success = false, .input_tokens = 0, .output_tokens = 0, .cost_microdollars = 0 };

    // Build prompt from association template with SCIP-derived relationships
    const template = build_options.bootstrap_associate_prompt;
    const prompt = replacePlaceholder(allocator, template, "{relationships}", relationships_text) catch return fail;
    defer allocator.free(prompt);

    // Build argv
    var argv_buf: std.ArrayListUnmanaged([]const u8) = .empty;
    defer argv_buf.deinit(allocator);

    if (selected_agent) |agent| {
        if (agent.env_unset.len > 0) {
            argv_buf.append(allocator, "env") catch return fail;
            for (agent.env_unset) |var_name| {
                argv_buf.append(allocator, "-u") catch return fail;
                argv_buf.append(allocator, var_name) catch return fail;
            }
        }
        for (agent.cmd_prefix) |token| {
            argv_buf.append(allocator, token) catch return fail;
        }
        argv_buf.append(allocator, prompt) catch return fail;
        for (agent.cmd_suffix) |token| {
            argv_buf.append(allocator, token) catch return fail;
        }
    } else if (custom_cmd) |cmd| {
        var cmd_iter = std.mem.splitScalar(u8, cmd, ' ');
        while (cmd_iter.next()) |token| {
            if (token.len > 0) {
                argv_buf.append(allocator, token) catch return fail;
            }
        }
        argv_buf.append(allocator, prompt) catch return fail;
    } else {
        return fail;
    }

    var child = std.process.Child.init(argv_buf.items, allocator);
    child.cwd = project_root;
    child.stderr_behavior = if (debug) .Inherit else .Ignore;
    child.stdout_behavior = .Pipe;

    child.spawn() catch |err| {
        printFmtErr(allocator, "    " ++ red ++ "spawn error: {s}" ++ reset ++ "\n", .{@errorName(err)});
        return fail;
    };
    const assoc_pid: i32 = child.id;
    if (assoc_pid > 0) registerChild(assoc_pid);
    const reaper = spawnReaper(assoc_pid);

    const stdout_data = if (child.stdout) |stdout|
        stdout.readToEndAlloc(allocator, 10 * 1024 * 1024) catch null
    else
        null;
    defer if (stdout_data) |d| allocator.free(d);

    const term = child.wait() catch |err| {
        if (assoc_pid > 0) unregisterChild(assoc_pid);
        dismissReaper(reaper);
        printFmtErr(allocator, "    " ++ red ++ "wait error: {s}" ++ reset ++ "\n", .{@errorName(err)});
        return fail;
    };
    if (assoc_pid > 0) unregisterChild(assoc_pid);
    dismissReaper(reaper);

    switch (term) {
        .Exited => |code| {
            if (code != 0) {
                printFmtErr(allocator, "    " ++ red ++ "exited with code {d}" ++ reset ++ "\n", .{code});
                return fail;
            }
        },
        .Signal => |sig| {
            printFmtErr(allocator, "    " ++ red ++ "killed by signal {d}" ++ reset ++ "\n", .{sig});
            return fail;
        },
        else => return fail,
    }

    // Parse token usage
    const agent_id: ?[]const u8 = if (selected_agent) |a| a.id else null;
    var usage = UsageStats{};
    if (stdout_data) |data| {
        if (data.len > 0 and agent_id != null) {
            usage = parseUsageFromStdout(allocator, agent_id.?, data);
        }
    }

    return .{
        .success = true,
        .input_tokens = usage.input_tokens,
        .output_tokens = usage.output_tokens,
        .cost_microdollars = usage.cost_microdollars,
    };
}

// ── SCIP-based cross-file relationship extraction ───────────────────────

const CrossFileResult = struct {
    text: []u8,
    pair_count: usize,
};

/// Walk the SCIP index to find cross-file symbol references.
/// Returns a human-readable text describing file pairs and their shared symbols,
/// suitable for embedding in the association prompt. Returns null on failure.
fn buildCrossFileRelationships(allocator: std.mem.Allocator, cog_dir: []const u8) ?CrossFileResult {
    const index_path = std.fmt.allocPrint(allocator, "{s}/index.scip", .{cog_dir}) catch return null;
    defer allocator.free(index_path);

    const file = std.fs.openFileAbsolute(index_path, .{}) catch return null;
    defer file.close();

    const data = file.readToEndAlloc(allocator, 256 * 1024 * 1024) catch return null;
    var index = scip.decode(allocator, data) catch {
        allocator.free(data);
        return null;
    };
    defer {
        scip.freeIndex(allocator, &index);
        allocator.free(data);
    }

    // Step 1: Build symbol → defining file map
    // Only track non-local symbols (local symbols are file-scoped)
    var symbol_to_file: std.StringHashMapUnmanaged([]const u8) = .empty;
    defer symbol_to_file.deinit(allocator);

    for (index.documents) |doc| {
        for (doc.occurrences) |occ| {
            if (occ.symbol.len == 0 or std.mem.startsWith(u8, occ.symbol, "local ")) continue;
            if (scip.SymbolRole.isDefinition(occ.symbol_roles)) {
                symbol_to_file.put(allocator, occ.symbol, doc.relative_path) catch continue;
            }
        }
    }

    // Step 2: For each file, find references to symbols defined in other files.
    // Group by (referencing_file, defining_file) pair → list of symbol names.
    const FilePairKey = struct {
        referencing: []const u8,
        defining: []const u8,
    };
    const PairContext = struct {
        pub fn hash(_: @This(), key: FilePairKey) u64 {
            var h = std.hash.Wyhash.init(0);
            h.update(key.referencing);
            h.update("\x00");
            h.update(key.defining);
            return h.final();
        }
        pub fn eql(_: @This(), a: FilePairKey, b: FilePairKey) bool {
            return std.mem.eql(u8, a.referencing, b.referencing) and
                std.mem.eql(u8, a.defining, b.defining);
        }
    };

    var pair_symbols: std.HashMapUnmanaged(
        FilePairKey,
        std.ArrayListUnmanaged([]const u8),
        PairContext,
        80,
    ) = .empty;
    defer {
        var it = pair_symbols.valueIterator();
        while (it.next()) |list| {
            list.deinit(allocator);
        }
        pair_symbols.deinit(allocator);
    }

    for (index.documents) |doc| {
        for (doc.occurrences) |occ| {
            if (occ.symbol.len == 0 or std.mem.startsWith(u8, occ.symbol, "local ")) continue;
            if (scip.SymbolRole.isDefinition(occ.symbol_roles)) continue;

            const defining_file = symbol_to_file.get(occ.symbol) orelse continue;
            if (std.mem.eql(u8, defining_file, doc.relative_path)) continue;

            const key = FilePairKey{
                .referencing = doc.relative_path,
                .defining = defining_file,
            };

            const gop = pair_symbols.getOrPut(allocator, key) catch continue;
            if (!gop.found_existing) {
                gop.value_ptr.* = .empty;
            }

            // Deduplicate symbol names within pair
            const sym_name = scip.extractSymbolName(occ.symbol);
            var found = false;
            for (gop.value_ptr.items) |existing| {
                if (std.mem.eql(u8, existing, sym_name)) {
                    found = true;
                    break;
                }
            }
            if (!found) {
                gop.value_ptr.append(allocator, sym_name) catch continue;
            }
        }
    }

    if (pair_symbols.count() == 0) return .{ .text = allocator.dupe(u8, "") catch return null, .pair_count = 0 };

    // Step 3: Build text output — collect pairs sorted for deterministic output
    const PairEntry = struct {
        key: FilePairKey,
        symbols: []const []const u8,
    };
    var entries: std.ArrayListUnmanaged(PairEntry) = .empty;
    defer entries.deinit(allocator);

    var pair_iter = pair_symbols.iterator();
    while (pair_iter.next()) |entry| {
        entries.append(allocator, .{
            .key = entry.key_ptr.*,
            .symbols = entry.value_ptr.items,
        }) catch continue;
    }

    // Sort by referencing file, then defining file
    std.mem.sort(PairEntry, entries.items, {}, struct {
        fn lessThan(_: void, a: PairEntry, b: PairEntry) bool {
            const ref_cmp = std.mem.order(u8, a.key.referencing, b.key.referencing);
            if (ref_cmp == .lt) return true;
            if (ref_cmp == .gt) return false;
            return std.mem.order(u8, a.key.defining, b.key.defining) == .lt;
        }
    }.lessThan);

    // Build text
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(allocator);

    for (entries.items) |entry| {
        // Header: file pair
        buf.appendSlice(allocator, "## ") catch continue;
        buf.appendSlice(allocator, entry.key.referencing) catch continue;
        buf.appendSlice(allocator, " → ") catch continue;
        buf.appendSlice(allocator, entry.key.defining) catch continue;
        buf.appendSlice(allocator, "\n") catch continue;

        // List shared symbols
        for (entry.symbols) |sym_name| {
            buf.appendSlice(allocator, "- ") catch continue;
            buf.appendSlice(allocator, sym_name) catch continue;
            buf.appendSlice(allocator, "\n") catch continue;
        }
        buf.appendSlice(allocator, "\n") catch continue;
    }

    const pair_count = entries.items.len;
    return .{ .text = buf.toOwnedSlice(allocator) catch return null, .pair_count = pair_count };
}

fn formatCost(allocator: std.mem.Allocator, microdollars: usize) []const u8 {
    const dollars = microdollars / 1_000_000;
    const cents = (microdollars % 1_000_000) / 10_000;
    const frac = (microdollars % 10_000) / 100;
    return std.fmt.allocPrint(allocator, "{d}.{d:0>2}{d:0>2}", .{ dollars, cents, frac }) catch "?.??";
}

// ── Usage parsing per agent ─────────────────────────────────────────────

const UsageStats = struct {
    input_tokens: usize = 0,
    output_tokens: usize = 0,
    cost_microdollars: usize = 0,
};

fn parseUsageFromStdout(allocator: std.mem.Allocator, agent_id: []const u8, data: []const u8) UsageStats {
    if (std.mem.eql(u8, agent_id, "claude_code")) return parseClaudeUsage(allocator, data);
    if (std.mem.eql(u8, agent_id, "gemini")) return parseGeminiUsage(allocator, data);
    if (std.mem.eql(u8, agent_id, "codex")) return parseCodexUsage(allocator, data);
    if (std.mem.eql(u8, agent_id, "amp")) return parseAmpUsage(allocator, data);
    if (std.mem.eql(u8, agent_id, "goose")) return parseGooseUsage(allocator, data);
    if (std.mem.eql(u8, agent_id, "opencode")) return parseOpenCodeUsage(allocator, data);
    return .{};
}

fn jsonInt(val: std.json.Value) usize {
    return switch (val) {
        .integer => @intCast(@max(0, val.integer)),
        .float => @intFromFloat(@max(0.0, val.float)),
        else => 0,
    };
}

fn jsonFloat(val: std.json.Value) f64 {
    return switch (val) {
        .float => val.float,
        .integer => @floatFromInt(val.integer),
        else => 0.0,
    };
}

/// Claude Code: single JSON object with usage.input_tokens, usage.output_tokens,
/// usage.cache_creation_input_tokens, usage.cache_read_input_tokens, total_cost_usd
fn parseClaudeUsage(allocator: std.mem.Allocator, data: []const u8) UsageStats {
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, data, .{}) catch return .{};
    defer parsed.deinit();
    if (parsed.value != .object) return .{};

    var stats = UsageStats{};

    if (parsed.value.object.get("usage")) |usage| {
        if (usage == .object) {
            stats.input_tokens = jsonInt(usage.object.get("input_tokens") orelse .null);
            stats.output_tokens = jsonInt(usage.object.get("output_tokens") orelse .null);
            stats.input_tokens += jsonInt(usage.object.get("cache_creation_input_tokens") orelse .null);
            stats.input_tokens += jsonInt(usage.object.get("cache_read_input_tokens") orelse .null);
        }
    }
    if (parsed.value.object.get("total_cost_usd")) |v| {
        stats.cost_microdollars = @intFromFloat(jsonFloat(v) * 1_000_000.0);
    }
    return stats;
}

/// Gemini CLI: single JSON with stats.models.<model>.tokens.prompt/candidates/cached
fn parseGeminiUsage(allocator: std.mem.Allocator, data: []const u8) UsageStats {
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, data, .{}) catch return .{};
    defer parsed.deinit();
    if (parsed.value != .object) return .{};

    var stats = UsageStats{};

    const stats_obj = parsed.value.object.get("stats") orelse return stats;
    if (stats_obj != .object) return stats;
    const models = stats_obj.object.get("models") orelse return stats;
    if (models != .object) return stats;

    // Sum across all models
    var model_iter = models.object.iterator();
    while (model_iter.next()) |entry| {
        if (entry.value_ptr.* != .object) continue;
        const tokens = entry.value_ptr.object.get("tokens") orelse continue;
        if (tokens != .object) continue;
        stats.input_tokens += jsonInt(tokens.object.get("prompt") orelse .null);
        stats.output_tokens += jsonInt(tokens.object.get("candidates") orelse .null);
    }
    return stats;
}

/// Codex CLI: JSONL stream, sum turn.completed events' usage.input_tokens/output_tokens
fn parseCodexUsage(allocator: std.mem.Allocator, data: []const u8) UsageStats {
    var stats = UsageStats{};
    var line_iter = std.mem.splitScalar(u8, data, '\n');
    while (line_iter.next()) |line| {
        if (line.len == 0) continue;
        const parsed = std.json.parseFromSlice(std.json.Value, allocator, line, .{}) catch continue;
        defer parsed.deinit();
        if (parsed.value != .object) continue;

        const type_val = parsed.value.object.get("type") orelse continue;
        if (type_val != .string) continue;
        if (!std.mem.eql(u8, type_val.string, "turn.completed")) continue;

        const usage = parsed.value.object.get("usage") orelse continue;
        if (usage != .object) continue;
        stats.input_tokens += jsonInt(usage.object.get("input_tokens") orelse .null);
        stats.output_tokens += jsonInt(usage.object.get("output_tokens") orelse .null);
    }
    return stats;
}

/// Amp: JSONL stream, sum assistant messages' usage.input_tokens/output_tokens/cache_*
fn parseAmpUsage(allocator: std.mem.Allocator, data: []const u8) UsageStats {
    var stats = UsageStats{};
    var line_iter = std.mem.splitScalar(u8, data, '\n');
    while (line_iter.next()) |line| {
        if (line.len == 0) continue;
        const parsed = std.json.parseFromSlice(std.json.Value, allocator, line, .{}) catch continue;
        defer parsed.deinit();
        if (parsed.value != .object) continue;

        const type_val = parsed.value.object.get("type") orelse continue;
        if (type_val != .string) continue;
        if (!std.mem.eql(u8, type_val.string, "assistant")) continue;

        const message = parsed.value.object.get("message") orelse continue;
        if (message != .object) continue;
        const usage = message.object.get("usage") orelse continue;
        if (usage != .object) continue;

        stats.input_tokens += jsonInt(usage.object.get("input_tokens") orelse .null);
        stats.input_tokens += jsonInt(usage.object.get("cache_creation_input_tokens") orelse .null);
        stats.input_tokens += jsonInt(usage.object.get("cache_read_input_tokens") orelse .null);
        stats.output_tokens += jsonInt(usage.object.get("output_tokens") orelse .null);
    }
    return stats;
}

/// Goose: single JSON with metadata.total_tokens (no in/out breakdown)
fn parseGooseUsage(allocator: std.mem.Allocator, data: []const u8) UsageStats {
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, data, .{}) catch return .{};
    defer parsed.deinit();
    if (parsed.value != .object) return .{};

    var stats = UsageStats{};
    const metadata = parsed.value.object.get("metadata") orelse return stats;
    if (metadata != .object) return stats;
    // Goose only gives total_tokens — report as input since there's no breakdown
    stats.input_tokens = jsonInt(metadata.object.get("total_tokens") orelse .null);
    return stats;
}

/// OpenCode: JSONL stream, sum step_finish events' part.tokens.input/output/cache.*
/// and part.cost
fn parseOpenCodeUsage(allocator: std.mem.Allocator, data: []const u8) UsageStats {
    var stats = UsageStats{};
    var line_iter = std.mem.splitScalar(u8, data, '\n');
    while (line_iter.next()) |line| {
        if (line.len == 0) continue;
        const parsed = std.json.parseFromSlice(std.json.Value, allocator, line, .{}) catch continue;
        defer parsed.deinit();
        if (parsed.value != .object) continue;

        const type_val = parsed.value.object.get("type") orelse continue;
        if (type_val != .string) continue;
        if (!std.mem.eql(u8, type_val.string, "step_finish")) continue;

        const part = parsed.value.object.get("part") orelse continue;
        if (part != .object) continue;

        // part.cost
        if (part.object.get("cost")) |cost_val| {
            stats.cost_microdollars += @intFromFloat(jsonFloat(cost_val) * 1_000_000.0);
        }

        const tokens = part.object.get("tokens") orelse continue;
        if (tokens != .object) continue;
        stats.input_tokens += jsonInt(tokens.object.get("input") orelse .null);
        stats.output_tokens += jsonInt(tokens.object.get("output") orelse .null);

        // cache.read + cache.write count as input
        if (tokens.object.get("cache")) |cache| {
            if (cache == .object) {
                stats.input_tokens += jsonInt(cache.object.get("read") orelse .null);
                stats.input_tokens += jsonInt(cache.object.get("write") orelse .null);
            }
        }
    }
    return stats;
}

fn replacePlaceholder(allocator: std.mem.Allocator, template: []const u8, placeholder: []const u8, value: []const u8) ![]u8 {
    // Count occurrences
    var count: usize = 0;
    var search_from: usize = 0;
    while (search_from < template.len) {
        const idx = std.mem.indexOfPos(u8, template, search_from, placeholder) orelse break;
        count += 1;
        search_from = idx + placeholder.len;
    }

    if (count == 0) {
        return allocator.dupe(u8, template);
    }

    // Allocate result: original length - (placeholder * count) + (value * count)
    const result_len = template.len - (placeholder.len * count) + (value.len * count);
    const result = try allocator.alloc(u8, result_len);

    var src_pos: usize = 0;
    var dst_pos: usize = 0;
    while (src_pos < template.len) {
        const idx = std.mem.indexOfPos(u8, template, src_pos, placeholder) orelse {
            // Copy remaining
            @memcpy(result[dst_pos..], template[src_pos..]);
            break;
        };
        // Copy before placeholder
        const before_len = idx - src_pos;
        @memcpy(result[dst_pos .. dst_pos + before_len], template[src_pos..idx]);
        dst_pos += before_len;
        // Copy value
        @memcpy(result[dst_pos .. dst_pos + value.len], value);
        dst_pos += value.len;
        src_pos = idx + placeholder.len;
    }

    return result;
}

/// Collect files from SCIP index + doc globs.
fn collectSourceFiles(allocator: std.mem.Allocator, cog_dir: []const u8) !std.ArrayListUnmanaged([]const u8) {
    var files: std.ArrayListUnmanaged([]const u8) = .empty;
    var seen: std.StringHashMapUnmanaged(void) = .empty;
    defer seen.deinit(allocator);

    // 1. Load SCIP index
    loadScipFiles(allocator, cog_dir, &files, &seen);

    // 2. Walk for documentation files
    try walkForDocs(allocator, ".", &files, &seen);

    // 3. Sort alphabetically
    sortFiles(files.items);

    return files;
}

fn loadScipFiles(
    allocator: std.mem.Allocator,
    cog_dir: []const u8,
    files: *std.ArrayListUnmanaged([]const u8),
    seen: *std.StringHashMapUnmanaged(void),
) void {
    const index_path = std.fmt.allocPrint(allocator, "{s}/index.scip", .{cog_dir}) catch return;
    defer allocator.free(index_path);

    const file = std.fs.openFileAbsolute(index_path, .{}) catch return;
    defer file.close();

    const data = file.readToEndAlloc(allocator, 256 * 1024 * 1024) catch return;
    var index = scip.decode(allocator, data) catch {
        allocator.free(data);
        return;
    };
    defer {
        scip.freeIndex(allocator, &index);
        allocator.free(data);
    }

    for (index.documents) |doc| {
        if (doc.relative_path.len > 0 and !seen.contains(doc.relative_path)) {
            const duped = allocator.dupe(u8, doc.relative_path) catch continue;
            files.append(allocator, duped) catch {
                allocator.free(duped);
                continue;
            };
            seen.put(allocator, duped, {}) catch {};
        }
    }
}

/// Recursively collect README*, CHANGELOG*, LICENSE* files.
fn walkForDocs(
    allocator: std.mem.Allocator,
    dir_path: []const u8,
    files: *std.ArrayListUnmanaged([]const u8),
    seen: *std.StringHashMapUnmanaged(void),
) !void {
    var dir = std.fs.cwd().openDir(dir_path, .{ .iterate = true }) catch return;
    defer dir.close();

    var iter = dir.iterate();
    while (try iter.next()) |entry| {
        if (entry.name[0] == '.') continue;
        if (std.mem.eql(u8, entry.name, "node_modules")) continue;
        if (std.mem.eql(u8, entry.name, "vendor")) continue;
        if (std.mem.eql(u8, entry.name, "target")) continue;
        if (std.mem.eql(u8, entry.name, "zig-out")) continue;
        if (std.mem.eql(u8, entry.name, "zig-cache")) continue;
        if (std.mem.eql(u8, entry.name, "grammars")) continue;
        if (std.mem.eql(u8, entry.name, "bench")) continue;

        const child_path = if (std.mem.eql(u8, dir_path, "."))
            try allocator.dupe(u8, entry.name)
        else
            try std.fmt.allocPrint(allocator, "{s}/{s}", .{ dir_path, entry.name });

        if (entry.kind == .directory) {
            try walkForDocs(allocator, child_path, files, seen);
            allocator.free(child_path);
        } else if (entry.kind == .file) {
            if (isDocFile(entry.name) and !seen.contains(child_path)) {
                try files.append(allocator, child_path);
                try seen.put(allocator, child_path, {});
            } else {
                allocator.free(child_path);
            }
        } else {
            allocator.free(child_path);
        }
    }
}

fn isDocFile(name: []const u8) bool {
    if (std.mem.startsWith(u8, name, "README")) return true;
    if (std.mem.startsWith(u8, name, "CHANGELOG")) return true;
    if (std.mem.startsWith(u8, name, "LICENSE")) return true;
    return false;
}

fn sortFiles(items: [][]const u8) void {
    std.mem.sort([]const u8, items, {}, struct {
        fn lessThan(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.order(u8, a, b) == .lt;
        }
    }.lessThan);
}

fn loadCheckpoint(allocator: std.mem.Allocator, checkpoint_path: []const u8) std.StringHashMapUnmanaged(void) {
    var map: std.StringHashMapUnmanaged(void) = .empty;

    const file = std.fs.openFileAbsolute(checkpoint_path, .{}) catch return map;
    defer file.close();

    const data = file.readToEndAlloc(allocator, 4 * 1024 * 1024) catch return map;
    defer allocator.free(data);

    const parsed = std.json.parseFromSlice(std.json.Value, allocator, data, .{}) catch return map;
    defer parsed.deinit();

    if (parsed.value != .object) return map;
    const obj = parsed.value.object;

    const files_val = obj.get("processed_files") orelse return map;
    if (files_val != .array) return map;

    for (files_val.array.items) |item| {
        if (item == .string) {
            const duped = allocator.dupe(u8, item.string) catch continue;
            map.put(allocator, duped, {}) catch {
                allocator.free(duped);
            };
        }
    }

    return map;
}

fn saveCheckpoint(allocator: std.mem.Allocator, checkpoint_path: []const u8, processed: *std.StringHashMapUnmanaged(void)) void {
    // Collect all keys into a sorted slice
    var keys: std.ArrayListUnmanaged([]const u8) = .empty;
    defer keys.deinit(allocator);

    var it = processed.keyIterator();
    while (it.next()) |key| {
        keys.append(allocator, key.*) catch continue;
    }
    sortFiles(keys.items);

    // Build JSON manually
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(allocator);

    buf.appendSlice(allocator, "{\n  \"version\": 1,\n  \"processed_files\": [\n") catch return;

    for (keys.items, 0..) |key, i| {
        buf.appendSlice(allocator, "    \"") catch return;
        for (key) |c| {
            switch (c) {
                '"' => buf.appendSlice(allocator, "\\\"") catch return,
                '\\' => buf.appendSlice(allocator, "\\\\") catch return,
                '\n' => buf.appendSlice(allocator, "\\n") catch return,
                else => buf.append(allocator, c) catch return,
            }
        }
        buf.append(allocator, '"') catch return;
        if (i + 1 < keys.items.len) {
            buf.append(allocator, ',') catch return;
        }
        buf.append(allocator, '\n') catch return;
    }

    buf.appendSlice(allocator, "  ]\n}\n") catch return;

    const file = std.fs.createFileAbsolute(checkpoint_path, .{}) catch return;
    defer file.close();
    file.writeAll(buf.items) catch {};
}

// Tests
test "replacePlaceholder basic" {
    const allocator = std.testing.allocator;
    const result = try replacePlaceholder(allocator, "process {file_path} now", "{file_path}", "src/main.zig");
    defer allocator.free(result);
    try std.testing.expectEqualStrings("process src/main.zig now", result);
}

test "replacePlaceholder multiple occurrences" {
    const allocator = std.testing.allocator;
    const result = try replacePlaceholder(allocator, "{file_path} and {file_path} again", "{file_path}", "a.zig");
    defer allocator.free(result);
    try std.testing.expectEqualStrings("a.zig and a.zig again", result);
}

test "replacePlaceholder no match" {
    const allocator = std.testing.allocator;
    const result = try replacePlaceholder(allocator, "no placeholder here", "{file_path}", "src/main.zig");
    defer allocator.free(result);
    try std.testing.expectEqualStrings("no placeholder here", result);
}

test "isDocFile" {
    try std.testing.expect(isDocFile("README.md"));
    try std.testing.expect(isDocFile("CHANGELOG.md"));
    try std.testing.expect(isDocFile("LICENSE"));
    try std.testing.expect(isDocFile("README"));
    try std.testing.expect(!isDocFile("docs.md"));
    try std.testing.expect(!isDocFile("main.zig"));
    try std.testing.expect(!isDocFile("config.json"));
}

test "sortFiles" {
    var items = [_][]const u8{ "c.zig", "a.zig", "b.zig" };
    sortFiles(&items);
    try std.testing.expectEqualStrings("a.zig", items[0]);
    try std.testing.expectEqualStrings("b.zig", items[1]);
    try std.testing.expectEqualStrings("c.zig", items[2]);
}

test "loadCheckpoint missing file" {
    const allocator = std.testing.allocator;
    var map = loadCheckpoint(allocator, "/tmp/nonexistent-bootstrap-checkpoint.json");
    defer map.deinit(allocator);
    try std.testing.expectEqual(@as(u32, 0), map.count());
}

test "cli_agents count" {
    try std.testing.expectEqual(@as(usize, 6), cli_agents.len);
}

test "cli_agents have non-empty prefix" {
    for (cli_agents) |agent| {
        try std.testing.expect(agent.cmd_prefix.len > 0);
        try std.testing.expect(agent.display_name.len > 0);
        try std.testing.expect(agent.id.len > 0);
    }
}

test "parseClaudeUsage" {
    const allocator = std.testing.allocator;
    const data =
        \\{"type":"result","usage":{"input_tokens":3,"cache_creation_input_tokens":34419,"cache_read_input_tokens":0,"output_tokens":35},"total_cost_usd":0.216}
    ;
    const stats = parseClaudeUsage(allocator, data);
    try std.testing.expectEqual(@as(usize, 34422), stats.input_tokens);
    try std.testing.expectEqual(@as(usize, 35), stats.output_tokens);
    try std.testing.expect(stats.cost_microdollars > 0);
}

test "parseGeminiUsage" {
    const allocator = std.testing.allocator;
    const data =
        \\{"response":"hi","stats":{"models":{"gemini-2.5-pro":{"tokens":{"prompt":3676,"candidates":20,"cached":100}}}}}
    ;
    const stats = parseGeminiUsage(allocator, data);
    try std.testing.expectEqual(@as(usize, 3676), stats.input_tokens);
    try std.testing.expectEqual(@as(usize, 20), stats.output_tokens);
}

test "parseCodexUsage" {
    const allocator = std.testing.allocator;
    const data = "{\"type\":\"turn.started\"}\n{\"type\":\"turn.completed\",\"usage\":{\"input_tokens\":1000,\"output_tokens\":50}}\n";
    const stats = parseCodexUsage(allocator, data);
    try std.testing.expectEqual(@as(usize, 1000), stats.input_tokens);
    try std.testing.expectEqual(@as(usize, 50), stats.output_tokens);
}

test "parseAmpUsage" {
    const allocator = std.testing.allocator;
    const data = "{\"type\":\"assistant\",\"message\":{\"usage\":{\"input_tokens\":500,\"cache_creation_input_tokens\":100,\"cache_read_input_tokens\":200,\"output_tokens\":30}}}\n";
    const stats = parseAmpUsage(allocator, data);
    try std.testing.expectEqual(@as(usize, 800), stats.input_tokens);
    try std.testing.expectEqual(@as(usize, 30), stats.output_tokens);
}

test "parseGooseUsage" {
    const allocator = std.testing.allocator;
    const data =
        \\{"messages":[],"metadata":{"total_tokens":1379,"status":"completed"}}
    ;
    const stats = parseGooseUsage(allocator, data);
    try std.testing.expectEqual(@as(usize, 1379), stats.input_tokens);
    try std.testing.expectEqual(@as(usize, 0), stats.output_tokens);
}

test "parseOpenCodeUsage" {
    const allocator = std.testing.allocator;
    const data = "{\"type\":\"step_finish\",\"part\":{\"cost\":0.003,\"tokens\":{\"input\":22144,\"output\":156,\"cache\":{\"read\":100,\"write\":50}}}}\n";
    const stats = parseOpenCodeUsage(allocator, data);
    try std.testing.expectEqual(@as(usize, 22294), stats.input_tokens);
    try std.testing.expectEqual(@as(usize, 156), stats.output_tokens);
    try std.testing.expect(stats.cost_microdollars > 0);
}

test "parseUsageFromStdout unknown agent" {
    const allocator = std.testing.allocator;
    const stats = parseUsageFromStdout(allocator, "unknown", "{}");
    try std.testing.expectEqual(@as(usize, 0), stats.input_tokens);
}

test "parseUsageFromStdout empty data" {
    const allocator = std.testing.allocator;
    const stats = parseUsageFromStdout(allocator, "claude_code", "");
    try std.testing.expectEqual(@as(usize, 0), stats.input_tokens);
}
