const std = @import("std");
const posix = std.posix;
const paths = @import("paths.zig");
const scip = @import("scip.zig");
const protobuf = @import("protobuf.zig");
const tui = @import("tui.zig");
const help_text = @import("help_text.zig");
const config_mod = @import("config.zig");
const client = @import("client.zig");
const settings_mod = @import("settings.zig");
const code_intel = @import("code_intel.zig");
const debug_log = @import("debug_log.zig");
const memory_mod = @import("memory.zig");
const memory_schema = @import("memory_schema.zig");
const sqlite = @import("sqlite.zig");
const agent_usage = @import("agent_usage.zig");

// ANSI styles
const cyan = "\x1B[36m";
const bold = "\x1B[1m";
const dim = "\x1B[2m";
const reset = "\x1B[0m";
const green = "\x1B[32m";
const red = "\x1B[31m";

const max_consecutive_errors = 5;

// ── Ctrl+C handling ─────────────────────────────────────────────────────
// Track active child PIDs so Ctrl+C can kill them immediately.
// Uses a watchdog thread that reads stdin in raw mode, bypassing OS signal
// delivery which can be unreliable when the terminal's ISIG flag is off.

const max_active_children = 16;
var g_active_children: [max_active_children]std.atomic.Value(i32) = initChildSlots();
var g_cancel_requested: std.atomic.Value(bool) = std.atomic.Value(bool).init(false);

fn initChildSlots() [max_active_children]std.atomic.Value(i32) {
    var slots: [max_active_children]std.atomic.Value(i32) = undefined;
    for (&slots) |*s| s.* = std.atomic.Value(i32).init(0);
    return slots;
}

fn registerChild(pid: i32) void {
    for (&g_active_children) |*slot| {
        if (slot.cmpxchgStrong(0, pid, .release, .monotonic) == null) return;
    }
}

fn unregisterChild(pid: i32) void {
    for (&g_active_children) |*slot| {
        if (slot.cmpxchgStrong(pid, 0, .release, .monotonic) == null) return;
    }
}

fn killAllChildren() void {
    for (&g_active_children) |*slot| {
        const pid = slot.load(.acquire);
        if (pid > 0) {
            // Kill the process group first — catches subprocesses spawned by agents
            // (returns ESRCH harmlessly if pid is not a process group leader)
            _ = std.c.kill(-pid, posix.SIG.KILL);
            // Then kill the individual process
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
        g_cancel_requested.store(true, .release);
        killAllChildren();
        // Allow in-flight spawns to complete and register, then kill again.
        // Covers the race between child.spawn() and registerChild().
        std.Thread.sleep(5 * std.time.ns_per_ms);
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
    g_cancel_requested.store(true, .release);
    killAllChildren();
    // Allow in-flight spawns to complete and register, then kill again.
    std.Thread.sleep(5 * std.time.ns_per_ms);
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
    debug_log.log("spawnReaper: target_pid={d}", .{target_pid});

    const pipe_fds = posix.pipe() catch return null;
    // pipe_fds[0] = read end, pipe_fds[1] = write end

    const pid = posix.fork() catch {
        debug_log.log("spawnReaper: fork failed", .{});
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

// ── Per-file timeout ─────────────────────────────────────────────────────
// Kills the child process if it exceeds the allowed time. Runs in a
// background thread, checking every 500ms whether it should fire.

const TimeoutWatcher = struct {
    pid: i32,
    timeout_ms: u64,
    cancelled: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    fired: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    fn watch(self: *TimeoutWatcher) void {
        const interval_ns = 500 * std.time.ns_per_ms;
        var elapsed_ms: u64 = 0;
        while (elapsed_ms < self.timeout_ms) {
            if (self.cancelled.load(.acquire)) return;
            std.Thread.sleep(interval_ns);
            elapsed_ms += 500;
        }
        if (!self.cancelled.load(.acquire)) {
            self.fired.store(true, .release);
            if (self.pid > 0) {
                _ = std.c.kill(self.pid, posix.SIG.KILL);
            }
        }
    }
};

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
    .{
        .id = "pi",
        .display_name = "Pi",
        .cmd_prefix = &.{ "pi", "-p" },
        .cmd_suffix = &.{ "--mode", "json" },
        .env_unset = &.{},
    },
};

const CliMenuEntry = struct {
    cli_index: usize,
    item: tui.MenuItem,
};

fn cliAgentLessThan(counts: *const agent_usage.Counts, lhs_index: usize, rhs_index: usize) bool {
    const lhs = cli_agents[lhs_index];
    const rhs = cli_agents[rhs_index];
    const lhs_count = agent_usage.countFor(counts, lhs.id);
    const rhs_count = agent_usage.countFor(counts, rhs.id);
    if (lhs_count != rhs_count) return lhs_count > rhs_count;
    return std.mem.order(u8, lhs.display_name, rhs.display_name) == .lt;
}

fn buildCliMenuEntries(allocator: std.mem.Allocator) ![cli_agents.len]CliMenuEntry {
    var counts = try agent_usage.loadCounts(allocator);
    defer agent_usage.deinitCounts(allocator, &counts);

    var sorted_indices: [cli_agents.len]usize = undefined;
    for (0..cli_agents.len) |i| sorted_indices[i] = i;

    var i: usize = 1;
    while (i < sorted_indices.len) : (i += 1) {
        const current = sorted_indices[i];
        var j = i;
        while (j > 0 and cliAgentLessThan(&counts, current, sorted_indices[j - 1])) : (j -= 1) {
            sorted_indices[j] = sorted_indices[j - 1];
        }
        sorted_indices[j] = current;
    }

    var entries: [cli_agents.len]CliMenuEntry = undefined;
    for (sorted_indices, 0..) |cli_index, idx| {
        entries[idx] = .{ .cli_index = cli_index, .item = .{ .label = cli_agents[cli_index].display_name } };
    }
    return entries;
}

/// Dispatch mem:* subcommands.
pub fn dispatch(allocator: std.mem.Allocator, subcmd: []const u8, args: []const [:0]const u8) !void {
    debug_log.log("bootstrap.dispatch: {s}", .{subcmd});
    if (std.mem.eql(u8, subcmd, "mem:bootstrap")) {
        return memBootstrap(allocator, args);
    }
    if (std.mem.eql(u8, subcmd, "mem:info")) {
        return memInfo(allocator);
    }
    if (std.mem.eql(u8, subcmd, "mem:upload")) {
        return memUpload(allocator, args);
    }
    if (std.mem.eql(u8, subcmd, "mem:upgrade")) {
        return memUpgrade();
    }

    printErr("error: unknown command '");
    printErr(subcmd);
    printErr("'\nRun " ++ dim ++ "cog mem --help" ++ reset ++ " to see available commands.\n");
    return error.Explained;
}

fn memInfo(allocator: std.mem.Allocator) !void {
    tui.header();
    const brain = config_mod.resolveBrain(allocator);
    defer brain.deinit(allocator);

    switch (brain) {
        .local => |local| {
            printErr(bold ++ "  Brain: " ++ reset ++ "local SQLite\n");
            printErr(dim ++ "  Path:  " ++ reset);
            printErr(local.path);
            printErr("\n");
            printErr(dim ++ "  ID:    " ++ reset);
            printErr(local.brain_id);
            printErr("\n\n");

            // Open DB and show stats
            const path_z = allocator.dupeZ(u8, local.path) catch {
                printErr("  (cannot open database)\n");
                return;
            };
            defer allocator.free(path_z);

            var db = sqlite.Db.open(path_z) catch {
                printErr("  (database not yet created — run a memory tool to initialize)\n");
                return;
            };
            defer db.close();
            memory_schema.ensureSchema(&db) catch {
                printErr("  (schema error)\n");
                return;
            };

            const engrams = countBrainQuery(&db, "SELECT COUNT(*) FROM engrams WHERE brain_id = ?", local.brain_id);
            const synapses = countBrainQuery(&db, "SELECT COUNT(*) FROM synapses WHERE brain_id = ?", local.brain_id);
            const long_term = countBrainQuery(&db, "SELECT COUNT(*) FROM engrams WHERE brain_id = ? AND memory_term = 'long'", local.brain_id);
            const short_term = countBrainQuery(&db, "SELECT COUNT(*) FROM engrams WHERE brain_id = ? AND memory_term = 'short'", local.brain_id);

            var buf: [256]u8 = undefined;
            const stats = std.fmt.bufPrint(&buf, "  {s}Engrams:{s}  {d} ({d} long-term, {d} short-term)\n  {s}Synapses:{s} {d}\n", .{
                bold, reset, engrams,  long_term, short_term,
                bold, reset, synapses,
            }) catch return;
            printErr(stats);
        },
        .remote => |remote| {
            printErr(bold ++ "  Brain: " ++ reset ++ "remote (hosted)\n");
            printErr(dim ++ "  URL:   " ++ reset);
            printErr(remote.brain_url);
            printErr("\n\n");
            printErr(dim ++ "  Visit the web dashboard for detailed stats.\n" ++ reset);
        },
        .none => {
            printErr("  No brain configured.\n");
            printErr(dim ++ "  Run " ++ reset ++ bold ++ "cog init" ++ reset ++ dim ++ " to set up memory.\n" ++ reset);
        },
    }
    printErr("\n");
}

fn countBrainQuery(db: *sqlite.Db, sql: [*:0]const u8, brain_id: []const u8) i64 {
    var stmt = db.prepare(sql) catch return 0;
    defer stmt.finalize();
    stmt.bindText(1, brain_id) catch return 0;
    const result = stmt.step() catch return 0;
    if (result == .row) return stmt.columnInt(0);
    return 0;
}

fn memUpgrade() !void {
    tui.header();
    printErr(bold ++ "  Upgrade to Hosted Memory" ++ reset ++ "\n\n");
    printErr("  Local SQLite brains can be migrated to a hosted brain on trycog.ai\n");
    printErr("  for cross-project memory, team sharing, and AI-powered features.\n\n");
    printErr(cyan ++ bold ++ "  Steps" ++ reset ++ "\n");
    printErr("    1. Sign up at " ++ bold ++ "https://trycog.ai" ++ reset ++ "\n");
    printErr("    2. Run " ++ bold ++ "cog init" ++ reset ++ " and enter your brain URL\n");
    printErr("    3. Use " ++ bold ++ "cog mem:bootstrap" ++ reset ++ " to re-populate from your codebase\n\n");
}

// ── Upload checkpoint ─────────────────────────────────────────────────

const UploadCheckpoint = struct {
    version: u32,
    target_url: []const u8,
    username: []const u8,
    brain_name: []const u8,
    host: []const u8,
    engrams_uploaded: usize,
    total_engrams: usize,
    synapses_uploaded: usize,
    total_synapses: usize,
};

fn loadUploadCheckpoint(allocator: std.mem.Allocator, path: []const u8) ?UploadCheckpoint {
    debug_log.log("loadUploadCheckpoint: {s}", .{path});
    const file = std.fs.cwd().openFile(path, .{}) catch return null;
    defer file.close();
    const content = file.readToEndAlloc(allocator, 65536) catch return null;
    defer allocator.free(content);

    const parsed = std.json.parseFromSlice(std.json.Value, allocator, content, .{}) catch return null;
    defer parsed.deinit();

    if (parsed.value != .object) return null;
    const obj = parsed.value.object;

    const target_url = if (obj.get("target_url")) |v| (if (v == .string) allocator.dupe(u8, v.string) catch return null else return null) else return null;
    errdefer allocator.free(target_url);
    const username = if (obj.get("username")) |v| (if (v == .string) allocator.dupe(u8, v.string) catch return null else return null) else return null;
    errdefer allocator.free(username);
    const brain_name = if (obj.get("brain_name")) |v| (if (v == .string) allocator.dupe(u8, v.string) catch return null else return null) else return null;
    errdefer allocator.free(brain_name);
    const host = if (obj.get("host")) |v| (if (v == .string) allocator.dupe(u8, v.string) catch return null else return null) else return null;

    const eu: usize = if (obj.get("engrams_uploaded")) |v| (if (v == .integer) @intCast(@max(v.integer, 0)) else 0) else 0;
    const te: usize = if (obj.get("total_engrams")) |v| (if (v == .integer) @intCast(@max(v.integer, 0)) else 0) else 0;
    const su: usize = if (obj.get("synapses_uploaded")) |v| (if (v == .integer) @intCast(@max(v.integer, 0)) else 0) else 0;
    const ts: usize = if (obj.get("total_synapses")) |v| (if (v == .integer) @intCast(@max(v.integer, 0)) else 0) else 0;

    return .{
        .version = 1,
        .target_url = target_url,
        .username = username,
        .brain_name = brain_name,
        .host = host,
        .engrams_uploaded = eu,
        .total_engrams = te,
        .synapses_uploaded = su,
        .total_synapses = ts,
    };
}

fn freeUploadCheckpoint(allocator: std.mem.Allocator, cp: *UploadCheckpoint) void {
    allocator.free(cp.target_url);
    allocator.free(cp.username);
    allocator.free(cp.brain_name);
    allocator.free(cp.host);
}

fn saveUploadCheckpoint(allocator: std.mem.Allocator, path: []const u8, cp: *const UploadCheckpoint) void {
    debug_log.log("saveUploadCheckpoint: eu={d} su={d}", .{ cp.engrams_uploaded, cp.synapses_uploaded });
    var aw: std.io.Writer.Allocating = .init(allocator);
    defer aw.deinit();
    var s: std.json.Stringify = .{ .writer = &aw.writer, .options = .{ .whitespace = .indent_2 } };
    s.beginObject() catch return;
    s.objectField("version") catch return;
    s.write(@as(i64, 1)) catch return;
    s.objectField("target_url") catch return;
    s.write(cp.target_url) catch return;
    s.objectField("username") catch return;
    s.write(cp.username) catch return;
    s.objectField("brain_name") catch return;
    s.write(cp.brain_name) catch return;
    s.objectField("host") catch return;
    s.write(cp.host) catch return;
    s.objectField("engrams_uploaded") catch return;
    s.write(@as(i64, @intCast(cp.engrams_uploaded))) catch return;
    s.objectField("total_engrams") catch return;
    s.write(@as(i64, @intCast(cp.total_engrams))) catch return;
    s.objectField("synapses_uploaded") catch return;
    s.write(@as(i64, @intCast(cp.synapses_uploaded))) catch return;
    s.objectField("total_synapses") catch return;
    s.write(@as(i64, @intCast(cp.total_synapses))) catch return;
    s.endObject() catch return;
    const content = aw.toOwnedSlice() catch return;
    defer allocator.free(content);

    const file = std.fs.cwd().createFile(path, .{}) catch return;
    defer file.close();
    var buf: [4096]u8 = undefined;
    var fw = file.writer(&buf);
    fw.interface.writeAll(content) catch return;
    fw.interface.writeAll("\n") catch return;
    fw.interface.flush() catch return;
}

fn deleteUploadCheckpoint(path: []const u8) void {
    debug_log.log("deleteUploadCheckpoint: {s}", .{path});
    std.fs.cwd().deleteFile(path) catch {};
}

// ── mem:upload ────────────────────────────────────────────────────────

fn memUpload(allocator: std.mem.Allocator, args: []const [:0]const u8) !void {
    if (hasFlag(args, "--help") or hasFlag(args, "-h")) {
        tui.header();
        printErr(help_text.mem_upload);
        return;
    }

    tui.header();

    const checkpoint_path = ".cog/upload-checkpoint.json";
    const clean = hasFlag(args, "--clean");

    if (clean) {
        deleteUploadCheckpoint(checkpoint_path);
        printErr("  Checkpoint cleared.\n\n");
    }

    // Step 1: Validate local brain
    debug_log.log("memUpload: resolving brain", .{});
    const brain = config_mod.resolveBrain(allocator);
    defer brain.deinit(allocator);

    const local = switch (brain) {
        .local => |l| l,
        .remote => {
            printErr("  error: mem:upload requires a local brain. Current brain is remote.\n");
            printErr("         Upload is only needed for local SQLite brains.\n");
            return error.Explained;
        },
        .none => {
            printErr("  error: No brain configured. Run " ++ dim ++ "cog init" ++ reset ++ " first.\n");
            return error.Explained;
        },
    };

    // Open SQLite DB
    debug_log.log("memUpload: opening db at {s}", .{local.path});
    const path_z = try allocator.dupeZ(u8, local.path);
    defer allocator.free(path_z);

    var db = sqlite.Db.open(path_z) catch {
        printErr("  error: failed to open local brain database\n");
        return error.Explained;
    };
    defer db.close();
    memory_schema.ensureSchema(&db) catch {
        printErr("  error: failed to initialize database schema\n");
        return error.Explained;
    };

    // Count engrams and synapses
    const total_engrams: usize = @intCast(@max(countBrainQuery(&db, "SELECT count(*) FROM engrams WHERE brain_id = ?", local.brain_id), 0));
    const total_synapses: usize = @intCast(@max(countBrainQuery(&db, "SELECT count(*) FROM synapses WHERE brain_id = ?", local.brain_id), 0));

    if (total_engrams == 0 and total_synapses == 0) {
        printErr("  Local brain is empty. Nothing to upload.\n\n");
        return;
    }

    printErr(bold ++ "  Local brain: " ++ reset);
    printErr(local.path);
    printErr("\n");
    printFmtErr(allocator, "    Engrams: {d} | Synapses: {d}\n\n", .{ total_engrams, total_synapses });

    // Step 2: Validate API key
    debug_log.log("memUpload: getting API key", .{});
    const api_key = config_mod.getApiKey(allocator) catch {
        printErr("  error: COG_API_KEY not set.\n");
        printErr("         Set it in your environment or .env file.\n");
        return error.Explained;
    };
    defer allocator.free(api_key);

    // Determine host
    const host: []const u8 = if (getFlagValue(args, "--host")) |h| h else if (std.posix.getenv("COG_HOST")) |h| h else "trycog.ai";

    // Verify API key
    printErr("  Verifying API key... ");
    const verify_url = try std.fmt.allocPrint(allocator, "https://{s}/api/v1/verify", .{host});
    defer allocator.free(verify_url);

    debug_log.log("memUpload: verifying API key at {s}", .{verify_url});
    const verify_resp = client.apiGet(allocator, verify_url, api_key) catch {
        printErr("\n  error: failed to connect to server\n");
        return error.Explained;
    };
    defer allocator.free(verify_resp.body);

    if (verify_resp.status_code != 200) {
        printErr("\n  error: invalid API key (HTTP ");
        printFmtErr(allocator, "{d})\n", .{verify_resp.status_code});
        return error.Explained;
    }

    // Parse verify response for username
    const verify_parsed = std.json.parseFromSlice(std.json.Value, allocator, verify_resp.body, .{}) catch {
        printErr("\n  error: invalid response from server\n");
        return error.Explained;
    };
    defer verify_parsed.deinit();

    const username = blk: {
        if (verify_parsed.value == .object) {
            if (verify_parsed.value.object.get("data")) |data| {
                if (data == .object) {
                    if (data.object.get("username")) |u| {
                        if (u == .string) break :blk try allocator.dupe(u8, u.string);
                    }
                }
            }
            // Fallback: try top-level username
            if (verify_parsed.value.object.get("username")) |u| {
                if (u == .string) break :blk try allocator.dupe(u8, u.string);
            }
        }
        printErr("\n  error: unexpected response from verify endpoint\n");
        return error.Explained;
    };
    defer allocator.free(username);

    tui.checkmark();
    printErr(" Authenticated as ");
    printErr(username);
    printErr("\n\n");

    // Step 3: Check for upload checkpoint
    var checkpoint: ?UploadCheckpoint = loadUploadCheckpoint(allocator, checkpoint_path);
    defer if (checkpoint) |*cp| freeUploadCheckpoint(allocator, cp);

    var brain_name: []const u8 = undefined;
    var brain_name_owned = false;
    defer if (brain_name_owned) allocator.free(brain_name);

    if (checkpoint) |cp| {
        brain_name = cp.brain_name;
        printFmtErr(allocator, "  Resuming upload to https://{s}/{s}/{s}\n\n", .{ cp.host, cp.username, cp.brain_name });
    } else {
        // Step 4: Prompt for brain name
        var items = [_]tui.MenuItem{
            .{ .label = "Enter brain name", .is_input_option = true },
        };
        const result = try tui.select(allocator, .{
            .prompt = "Brain name for " ++ bold ++ "" ++ reset ++ "" ++ dim ++ "" ++ reset ++ "upload:",
            .items = &items,
            .input_validator = &tui.validateBrainName,
        });
        switch (result) {
            .input => |name| {
                brain_name = name;
                brain_name_owned = true;
            },
            .back, .cancelled => {
                printErr("  Aborted.\n");
                return;
            },
            .selected => {
                printErr("  Aborted.\n");
                return;
            },
        }

        printErr("\n");

        // Step 5: Create remote brain
        debug_log.log("memUpload: creating brain {s}/{s} on {s}", .{ username, brain_name, host });
        printErr("  Creating remote brain... ");

        var aw: std.io.Writer.Allocating = .init(allocator);
        defer aw.deinit();
        var s_json: std.json.Stringify = .{ .writer = &aw.writer };
        try s_json.beginObject();
        try s_json.objectField("namespace");
        try s_json.write(@as([]const u8, username));
        try s_json.objectField("name");
        try s_json.write(@as([]const u8, brain_name));
        try s_json.endObject();
        const create_body = try aw.toOwnedSlice();
        defer allocator.free(create_body);

        const create_url = try std.fmt.allocPrint(allocator, "https://{s}/api/v1/brains/create", .{host});
        defer allocator.free(create_url);

        debug_log.log("memUpload: POST {s}", .{create_url});
        const create_resp = client.apiPost(allocator, create_url, api_key, create_body) catch {
            printErr("\n  error: failed to connect to server\n");
            return error.Explained;
        };
        defer allocator.free(create_resp.body);

        if (create_resp.status_code == 201 or create_resp.status_code == 200) {
            tui.checkmark();
            printErr(" Created\n\n");
        } else if (create_resp.status_code == 422) {
            // Check if "already exists"
            const err_parsed = std.json.parseFromSlice(std.json.Value, allocator, create_resp.body, .{}) catch null;
            defer if (err_parsed) |ep| ep.deinit();

            const is_exists = if (err_parsed) |ep| blk: {
                if (ep.value == .object) {
                    if (ep.value.object.get("error")) |err_val| {
                        if (err_val == .object) {
                            if (err_val.object.get("message")) |msg| {
                                if (msg == .string) {
                                    break :blk std.mem.indexOf(u8, msg.string, "has already been taken") != null;
                                }
                            }
                        }
                    }
                }
                break :blk false;
            } else false;

            if (is_exists) {
                printErr("\n");
                const confirm_msg = try std.fmt.allocPrint(allocator, "Brain '{s}' already exists. Upload to it?", .{brain_name});
                defer allocator.free(confirm_msg);
                const confirmed = try tui.confirm(confirm_msg);
                if (!confirmed) {
                    printErr("  Aborted.\n");
                    return;
                }
                printErr("\n");
            } else {
                printErr("\n  error: failed to create brain (HTTP 422)\n");
                // Print error details if available
                if (err_parsed) |ep| {
                    if (ep.value == .object) {
                        if (ep.value.object.get("error")) |err_val| {
                            if (err_val == .object) {
                                if (err_val.object.get("message")) |msg| {
                                    if (msg == .string) {
                                        printErr("         ");
                                        printErr(msg.string);
                                        printErr("\n");
                                    }
                                }
                            }
                        }
                    }
                }
                return error.Explained;
            }
        } else {
            printFmtErr(allocator, "\n  error: failed to create brain (HTTP {d})\n", .{create_resp.status_code});
            return error.Explained;
        }

        // Initialize checkpoint
        const target_url = try std.fmt.allocPrint(allocator, "https://{s}/{s}/{s}", .{ host, username, brain_name });
        const cp_username = try allocator.dupe(u8, username);
        const cp_brain_name = try allocator.dupe(u8, brain_name);
        const cp_host = try allocator.dupe(u8, host);

        checkpoint = UploadCheckpoint{
            .version = 1,
            .target_url = target_url,
            .username = cp_username,
            .brain_name = cp_brain_name,
            .host = cp_host,
            .engrams_uploaded = 0,
            .total_engrams = total_engrams,
            .synapses_uploaded = 0,
            .total_synapses = total_synapses,
        };
        saveUploadCheckpoint(allocator, checkpoint_path, &checkpoint.?);
    }

    const cp = &checkpoint.?;

    // Step 6: Upload engrams in batches of 50
    const batch_size: usize = 50;

    if (cp.engrams_uploaded < total_engrams) {
        debug_log.log("memUpload: uploading engrams ({d}/{d})", .{ cp.engrams_uploaded, total_engrams });

        // Read all engrams
        var engram_stmt = db.prepare("SELECT id, term, definition, memory_term, weight FROM engrams WHERE brain_id = ?") catch {
            printErr("  error: failed to query engrams\n");
            return error.Explained;
        };
        defer engram_stmt.finalize();
        engram_stmt.bindText(1, local.brain_id) catch {
            printErr("  error: failed to bind brain_id\n");
            return error.Explained;
        };

        const Engram = struct {
            term: []const u8,
            definition: []const u8,
            memory_term: []const u8,
            weight: f64,
        };

        var engrams: std.ArrayListUnmanaged(Engram) = .empty;
        defer {
            for (engrams.items) |e| {
                allocator.free(e.term);
                allocator.free(e.definition);
                allocator.free(e.memory_term);
            }
            engrams.deinit(allocator);
        }

        while (true) {
            const row = engram_stmt.step() catch break;
            if (row != .row) break;
            const term = allocator.dupe(u8, engram_stmt.columnText(1) orelse "") catch continue;
            errdefer allocator.free(term);
            const definition = allocator.dupe(u8, engram_stmt.columnText(2) orelse "") catch {
                allocator.free(term);
                continue;
            };
            errdefer allocator.free(definition);
            const memory_term = allocator.dupe(u8, engram_stmt.columnText(3) orelse "long") catch {
                allocator.free(term);
                allocator.free(definition);
                continue;
            };
            const weight = engram_stmt.columnReal(4);
            engrams.append(allocator, .{ .term = term, .definition = definition, .memory_term = memory_term, .weight = weight }) catch continue;
        }

        // Upload in batches
        var uploaded: usize = cp.engrams_uploaded;
        const bulk_learn_url = try std.fmt.allocPrint(allocator, "https://{s}/api/v1/{s}/{s}/bulk_learn", .{ cp.host, cp.username, cp.brain_name });
        defer allocator.free(bulk_learn_url);

        while (uploaded < engrams.items.len) {
            const end = @min(uploaded + batch_size, engrams.items.len);
            const batch = engrams.items[uploaded..end];

            // Build JSON body
            var batch_aw: std.io.Writer.Allocating = .init(allocator);
            defer batch_aw.deinit();
            var batch_s: std.json.Stringify = .{ .writer = &batch_aw.writer };
            batch_s.beginObject() catch break;
            batch_s.objectField("items") catch break;
            batch_s.beginArray() catch break;
            for (batch) |e| {
                batch_s.beginObject() catch break;
                batch_s.objectField("term") catch break;
                batch_s.write(e.term) catch break;
                batch_s.objectField("definition") catch break;
                batch_s.write(e.definition) catch break;
                batch_s.objectField("memory_term") catch break;
                batch_s.write(e.memory_term) catch break;
                batch_s.endObject() catch break;
            }
            batch_s.endArray() catch break;
            batch_s.endObject() catch break;
            const batch_body = batch_aw.toOwnedSlice() catch break;
            defer allocator.free(batch_body);

            debug_log.log("memUpload: POST bulk_learn batch {d}-{d}", .{ uploaded, end });
            const resp = client.apiPost(allocator, bulk_learn_url, api_key, batch_body) catch {
                printErr("\n  error: failed to upload engram batch\n");
                return error.Explained;
            };
            defer allocator.free(resp.body);

            if (resp.status_code != 200 and resp.status_code != 201) {
                printFmtErr(allocator, "\n  error: bulk_learn failed (HTTP {d})\n", .{resp.status_code});
                return error.Explained;
            }

            uploaded = end;
            cp.engrams_uploaded = uploaded;
            saveUploadCheckpoint(allocator, checkpoint_path, cp);

            // Progress display
            if (tui.isStderrTty()) {
                printFmtErr(allocator, "\r  Uploading engrams... {d}/{d}", .{ uploaded, total_engrams });
            }
        }
        if (tui.isStderrTty()) {
            printErr("\r");
        }
        printErr("  ");
        tui.checkmark();
        printFmtErr(allocator, " Engrams uploaded: {d}\n", .{uploaded});
    } else {
        printErr("  ");
        tui.checkmark();
        printFmtErr(allocator, " Engrams already uploaded: {d}\n", .{cp.engrams_uploaded});
    }

    // Step 7: Upload synapses in batches of 50
    if (cp.synapses_uploaded < total_synapses) {
        debug_log.log("memUpload: uploading synapses ({d}/{d})", .{ cp.synapses_uploaded, total_synapses });

        var synapse_stmt = db.prepare(
            "SELECT s.source_id, s.target_id, s.relation, s.weight, " ++
                "e1.term as source_term, e2.term as target_term " ++
                "FROM synapses s " ++
                "JOIN engrams e1 ON s.source_id = e1.id " ++
                "JOIN engrams e2 ON s.target_id = e2.id " ++
                "WHERE s.brain_id = ?",
        ) catch {
            printErr("  error: failed to query synapses\n");
            return error.Explained;
        };
        defer synapse_stmt.finalize();
        synapse_stmt.bindText(1, local.brain_id) catch {
            printErr("  error: failed to bind brain_id\n");
            return error.Explained;
        };

        const Synapse = struct {
            source_term: []const u8,
            target_term: []const u8,
            relation: []const u8,
            weight: f64,
        };

        var synapses: std.ArrayListUnmanaged(Synapse) = .empty;
        defer {
            for (synapses.items) |s| {
                allocator.free(s.source_term);
                allocator.free(s.target_term);
                allocator.free(s.relation);
            }
            synapses.deinit(allocator);
        }

        while (true) {
            const row = synapse_stmt.step() catch break;
            if (row != .row) break;
            const source_term = allocator.dupe(u8, synapse_stmt.columnText(4) orelse "") catch continue;
            errdefer allocator.free(source_term);
            const target_term = allocator.dupe(u8, synapse_stmt.columnText(5) orelse "") catch {
                allocator.free(source_term);
                continue;
            };
            errdefer allocator.free(target_term);
            const relation = allocator.dupe(u8, synapse_stmt.columnText(2) orelse "related_to") catch {
                allocator.free(source_term);
                allocator.free(target_term);
                continue;
            };
            const weight = synapse_stmt.columnReal(3);
            synapses.append(allocator, .{ .source_term = source_term, .target_term = target_term, .relation = relation, .weight = weight }) catch continue;
        }

        // Upload in batches
        var uploaded: usize = cp.synapses_uploaded;
        const bulk_assoc_url = try std.fmt.allocPrint(allocator, "https://{s}/api/v1/{s}/{s}/bulk_associate", .{ cp.host, cp.username, cp.brain_name });
        defer allocator.free(bulk_assoc_url);

        while (uploaded < synapses.items.len) {
            const end = @min(uploaded + batch_size, synapses.items.len);
            const batch = synapses.items[uploaded..end];

            var batch_aw: std.io.Writer.Allocating = .init(allocator);
            defer batch_aw.deinit();
            var batch_s: std.json.Stringify = .{ .writer = &batch_aw.writer };
            batch_s.beginObject() catch break;
            batch_s.objectField("items") catch break;
            batch_s.beginArray() catch break;
            for (batch) |syn| {
                batch_s.beginObject() catch break;
                batch_s.objectField("source") catch break;
                batch_s.write(syn.source_term) catch break;
                batch_s.objectField("target") catch break;
                batch_s.write(syn.target_term) catch break;
                batch_s.objectField("relation") catch break;
                batch_s.write(syn.relation) catch break;
                batch_s.objectField("weight") catch break;
                batch_s.write(syn.weight) catch break;
                batch_s.endObject() catch break;
            }
            batch_s.endArray() catch break;
            batch_s.endObject() catch break;
            const batch_body = batch_aw.toOwnedSlice() catch break;
            defer allocator.free(batch_body);

            debug_log.log("memUpload: POST bulk_associate batch {d}-{d}", .{ uploaded, end });
            const resp = client.apiPost(allocator, bulk_assoc_url, api_key, batch_body) catch {
                printErr("\n  error: failed to upload synapse batch\n");
                return error.Explained;
            };
            defer allocator.free(resp.body);

            if (resp.status_code != 200 and resp.status_code != 201) {
                printFmtErr(allocator, "\n  error: bulk_associate failed (HTTP {d})\n", .{resp.status_code});
                return error.Explained;
            }

            uploaded = end;
            cp.synapses_uploaded = uploaded;
            saveUploadCheckpoint(allocator, checkpoint_path, cp);

            if (tui.isStderrTty()) {
                printFmtErr(allocator, "\r  Uploading synapses... {d}/{d}", .{ uploaded, total_synapses });
            }
        }
        if (tui.isStderrTty()) {
            printErr("\r");
        }
        printErr("  ");
        tui.checkmark();
        printFmtErr(allocator, " Synapses uploaded: {d}\n", .{uploaded});
    } else {
        printErr("  ");
        tui.checkmark();
        printFmtErr(allocator, " Synapses already uploaded: {d}\n", .{cp.synapses_uploaded});
    }

    // Step 8: Validate
    printErr("\n  Validating... ");
    const stats_url = try std.fmt.allocPrint(allocator, "https://{s}/api/v1/{s}/{s}/stats", .{ cp.host, cp.username, cp.brain_name });
    defer allocator.free(stats_url);

    debug_log.log("memUpload: POST stats at {s}", .{stats_url});
    const stats_resp = client.apiPost(allocator, stats_url, api_key, "{}") catch {
        printErr("skipped (connection error)\n");
        // Non-fatal — continue with settings update
        printErr("\n");
        // Still update settings and clean up
        return memUploadFinalize(allocator, cp, checkpoint_path, local.path);
    };
    defer allocator.free(stats_resp.body);

    if (stats_resp.status_code == 200 or stats_resp.status_code == 201) {
        // Try to parse stats
        const stats_parsed = std.json.parseFromSlice(std.json.Value, allocator, stats_resp.body, .{}) catch null;
        defer if (stats_parsed) |sp| sp.deinit();

        if (stats_parsed) |sp| {
            // Try data envelope first, then top-level
            const stats_obj = if (sp.value == .object)
                if (sp.value.object.get("data")) |d| (if (d == .object) d else sp.value) else sp.value
            else
                sp.value;

            if (stats_obj == .object) {
                const remote_engrams = if (stats_obj.object.get("total_engrams")) |v| (if (v == .integer) v.integer else null) else null;
                const remote_synapses = if (stats_obj.object.get("total_synapses")) |v| (if (v == .integer) v.integer else null) else null;

                if (remote_engrams) |re| {
                    if (remote_synapses) |rs| {
                        tui.checkmark();
                        printFmtErr(allocator, " Remote: {d} engrams, {d} synapses\n", .{ re, rs });
                    } else {
                        tui.checkmark();
                        printFmtErr(allocator, " Remote: {d} engrams\n", .{re});
                    }
                } else {
                    tui.checkmark();
                    printErr(" Validated\n");
                }
            } else {
                tui.checkmark();
                printErr(" Validated\n");
            }
        } else {
            tui.checkmark();
            printErr(" Done\n");
        }
    } else {
        printErr("skipped (HTTP ");
        printFmtErr(allocator, "{d})\n", .{stats_resp.status_code});
    }

    return memUploadFinalize(allocator, cp, checkpoint_path, local.path);
}

fn memUploadFinalize(allocator: std.mem.Allocator, cp: *const UploadCheckpoint, checkpoint_path: []const u8, local_path: []const u8) !void {
    // Step 9: Update settings to point to remote brain
    printErr("\n");
    const brain_url = try std.fmt.allocPrint(allocator, "https://{s}/{s}/{s}", .{ cp.host, cp.username, cp.brain_name });
    defer allocator.free(brain_url);

    try writeSettingsBrainUrl(allocator, brain_url);
    printErr("  ");
    tui.checkmark();
    printErr(" Settings updated: ");
    printErr(brain_url);
    printErr("\n\n");

    // Step 10: Delete checkpoint
    deleteUploadCheckpoint(checkpoint_path);

    // Step 11: Optionally delete local brain
    const del_confirmed = tui.confirm("Delete local brain.db?") catch false;
    if (del_confirmed) {
        std.fs.deleteFileAbsolute(local_path) catch {
            printErr("  warning: failed to delete local brain file\n");
            return;
        };
        printErr("  ");
        tui.checkmark();
        printErr(" Deleted ");
        printErr(local_path);
        printErr("\n");
    }

    printErr("\n  Upload complete.\n\n");
}

/// Write brain URL into .cog/settings.json, preserving other settings.
fn writeSettingsBrainUrl(allocator: std.mem.Allocator, brain_url: []const u8) !void {
    // Ensure .cog/ directory exists
    std.fs.cwd().makeDir(".cog") catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => {
            printErr("  error: failed to create .cog directory\n");
            return error.Explained;
        },
    };

    // Read existing settings
    const existing = blk: {
        const f = std.fs.cwd().openFile(".cog/settings.json", .{}) catch break :blk null;
        defer f.close();
        break :blk f.readToEndAlloc(allocator, 1048576) catch null;
    };
    defer if (existing) |e| allocator.free(e);

    var aw: std.io.Writer.Allocating = .init(allocator);
    defer aw.deinit();
    var s: std.json.Stringify = .{ .writer = &aw.writer, .options = .{ .whitespace = .indent_2 } };

    try s.beginObject();

    if (existing) |content| {
        if (std.json.parseFromSlice(std.json.Value, allocator, content, .{})) |parsed| {
            defer parsed.deinit();

            if (parsed.value == .object) {
                // Copy all non-memory top-level keys
                var top_iter = parsed.value.object.iterator();
                while (top_iter.next()) |entry| {
                    if (std.mem.eql(u8, entry.key_ptr.*, "memory")) continue;
                    try s.objectField(entry.key_ptr.*);
                    try s.write(entry.value_ptr.*);
                }

                // Deep merge memory, preserving all existing non-brain keys
                try s.objectField("memory");
                try s.beginObject();

                if (parsed.value.object.get("memory")) |memory| {
                    if (memory == .object) {
                        var mem_iter = memory.object.iterator();
                        while (mem_iter.next()) |entry| {
                            if (std.mem.eql(u8, entry.key_ptr.*, "brain")) continue;
                            try s.objectField(entry.key_ptr.*);
                            try s.write(entry.value_ptr.*);
                        }
                    }
                }

                // Write brain as object with url field
                try s.objectField("brain");
                try s.beginObject();
                try s.objectField("url");
                try s.write(brain_url);
                try s.endObject(); // brain
                try s.endObject(); // memory
            } else {
                // Not a valid object — write fresh
                try s.objectField("memory");
                try s.beginObject();
                try s.objectField("brain");
                try s.beginObject();
                try s.objectField("url");
                try s.write(brain_url);
                try s.endObject();
                try s.endObject();
            }
        } else |_| {
            try s.objectField("memory");
            try s.beginObject();
            try s.objectField("brain");
            try s.beginObject();
            try s.objectField("url");
            try s.write(brain_url);
            try s.endObject();
            try s.endObject();
        }
    } else {
        try s.objectField("memory");
        try s.beginObject();
        try s.objectField("brain");
        try s.beginObject();
        try s.objectField("url");
        try s.write(brain_url);
        try s.endObject();
        try s.endObject();
    }

    try s.endObject();

    const new_content = try aw.toOwnedSlice();
    defer allocator.free(new_content);

    const with_newline = std.fmt.allocPrint(allocator, "{s}\n", .{new_content}) catch {
        printErr("  error: failed to format settings\n");
        return error.Explained;
    };
    defer allocator.free(with_newline);

    const file = std.fs.cwd().createFile(".cog/settings.json", .{}) catch {
        printErr("  error: failed to write .cog/settings.json\n");
        return error.Explained;
    };
    defer file.close();
    var buf: [4096]u8 = undefined;
    var fw = file.writer(&buf);
    fw.interface.writeAll(with_newline) catch {
        printErr("  error: failed to write .cog/settings.json\n");
        return error.Explained;
    };
    fw.interface.flush() catch {
        printErr("  error: failed to write .cog/settings.json\n");
        return error.Explained;
    };
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

    const timeout_minutes: u64 = if (getFlagValue(args, "--timeout")) |v|
        std.fmt.parseInt(u64, v, 10) catch {
            printErr("error: invalid --timeout value\n");
            return error.Explained;
        }
    else
        10; // default 10 minutes per file

    const timeout_ms: u64 = timeout_minutes * 60 * 1000;

    const clean = hasFlag(args, "--clean");
    const debug = hasFlag(args, "--debug");

    // Require .cog directory
    const cog_dir = paths.findCogDir(allocator) catch {
        printErr("error: no .cog directory found.\n\n");
        printErr("  To prepare your codebase for memory bootstrapping:\n\n");
        printErr("    1. Run " ++ dim ++ "cog init" ++ reset ++ " to create a .cog/ directory\n");
        printErr("    2. Add index patterns to " ++ dim ++ ".cog/settings.json" ++ reset ++ ":\n");
        printErr("       " ++ dim ++ "{\"code\": {\"index\": [\"src/**/*.ts\", \"lib/**/*.py\"]}}" ++ reset ++ "\n");
        printErr("    3. Run " ++ dim ++ "cog code:index" ++ reset ++ " to build the SCIP index\n\n");
        return error.Explained;
    };
    defer allocator.free(cog_dir);

    // Require code.index patterns in settings.json
    const pre_settings = settings_mod.Settings.load(allocator);
    defer if (pre_settings) |s| s.deinit(allocator);
    const has_index_patterns = if (pre_settings) |s| blk: {
        const code = s.code orelse break :blk false;
        const idx = code.index orelse break :blk false;
        break :blk idx.len > 0;
    } else false;

    if (!has_index_patterns) {
        debug_log.log("mem:bootstrap: no code.index patterns in settings.json", .{});
        printErr("error: no " ++ bold ++ "code.index" ++ reset ++ " patterns configured in settings.json.\n\n");
        printErr("  Memory bootstrapping needs to know which files to analyze.\n");
        printErr("  Add index patterns to " ++ dim ++ ".cog/settings.json" ++ reset ++ ":\n\n");
        printErr("    " ++ dim ++ "{" ++ reset ++ "\n");
        printErr("    " ++ dim ++ "  \"code\": {" ++ reset ++ "\n");
        printErr("    " ++ dim ++ "    \"index\": [\"src/**/*.ts\", \"lib/**/*.py\"]" ++ reset ++ "\n");
        printErr("    " ++ dim ++ "  }" ++ reset ++ "\n");
        printErr("    " ++ dim ++ "}" ++ reset ++ "\n\n");
        printErr("  Then run " ++ dim ++ "cog code:index" ++ reset ++ " to build the index.\n\n");
        return error.Explained;
    }

    // Require SCIP index file
    const index_path = try std.fmt.allocPrint(allocator, "{s}/index.scip", .{cog_dir});
    defer allocator.free(index_path);

    {
        const index_file = std.fs.openFileAbsolute(index_path, .{}) catch {
            debug_log.log("mem:bootstrap: index.scip not found at {s}", .{index_path});
            printErr("error: no SCIP index found. Run " ++ dim ++ "cog code:index" ++ reset ++ " to index your codebase first.\n\n");
            return error.Explained;
        };
        const stat = index_file.stat() catch {
            index_file.close();
            printErr("error: could not read SCIP index.\n\n");
            return error.Explained;
        };
        index_file.close();

        if (stat.size == 0) {
            debug_log.log("mem:bootstrap: index.scip is empty (0 bytes)", .{});
            printErr("error: SCIP index is empty — no files have been indexed.\n\n");
            printErr("  Check that your " ++ bold ++ "code.index" ++ reset ++ " patterns in .cog/settings.json\n");
            printErr("  match your source files, then run " ++ dim ++ "cog code:index" ++ reset ++ " again.\n\n");
            return error.Explained;
        }
    }

    // Agent selection menu
    const cli_menu_entries = try buildCliMenuEntries(allocator);
    var menu_items: [cli_agents.len + 1]tui.MenuItem = undefined;
    for (cli_menu_entries, 0..) |entry, i| {
        menu_items[i] = entry.item;
    }
    menu_items[cli_agents.len] = .{ .label = "Custom command", .is_input_option = true };

    printErr("\n");
    const agent_result = try tui.select(allocator, .{
        .prompt = "Select an agent to run bootstrap:",
        .items = &menu_items,
    });

    const selected_agent: ?*const CliAgent = switch (agent_result) {
        .selected => |idx| if (idx < cli_agents.len) &cli_agents[cli_menu_entries[idx].cli_index] else null,
        .input => null,
        .back, .cancelled => {
            printErr("  Aborted.\n");
            return;
        },
    };

    if (selected_agent) |agent| {
        try agent_usage.incrementCounts(allocator, &.{agent.id});
    }

    // For custom command, extract the user-typed command string
    const custom_cmd: ?[]const u8 = switch (agent_result) {
        .input => |cmd| cmd,
        else => null,
    };

    // Warn about cost and get confirmation
    printErr("\n");
    printErr("  " ++ bold ++ "Note:" ++ reset ++ " Bootstrap invokes your agent once per subsystem cluster.\n");
    printErr("  This will consume tokens on your agent's model and may incur costs.\n");
    printErr("  The process can take a while depending on the size of your codebase.\n");
    printErr("  Progress is saved — press Ctrl+C to stop and resume later.\n\n");

    const confirmed = try tui.confirm("Continue?");
    if (!confirmed) {
        printErr("  Aborted.\n");
        return;
    }

    // Load model from settings.json: memory.bootstrap.model (preferred) or memory.model (legacy)
    const settings = settings_mod.Settings.load(allocator);
    defer if (settings) |s| s.deinit(allocator);
    const model: ?[]const u8 = if (settings) |s| blk: {
        const mem = s.memory orelse break :blk null;
        if (mem.bootstrap) |bs| break :blk bs.model;
        break :blk mem.model; // legacy fallback
    } else null;

    try runBootstrap(allocator, concurrency, clean, debug, timeout_ms, cog_dir, selected_agent, custom_cmd, model);
}

fn runBootstrap(
    allocator: std.mem.Allocator,
    concurrency: usize,
    clean: bool,
    debug: bool,
    timeout_ms: u64,
    cog_dir: []const u8,
    selected_agent: ?*const CliAgent,
    custom_cmd: ?[]const u8,
    model: ?[]const u8,
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

    // Build subsystem clusters
    printErr(bold ++ "  Building subsystem clusters..." ++ reset ++ "\n");
    const all_subsystems = buildSubsystemClusters(allocator, files.items, cog_dir) orelse {
        printErr("  " ++ bold ++ "error:" ++ reset ++ " Failed to build subsystem clusters (SCIP index required).\n\n");
        return;
    };
    defer freeSubsystems(allocator, all_subsystems);
    printFmtErr(allocator, "  Built {d} subsystem clusters\n", .{all_subsystems.len});

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

    // Load prompts from .cog/ directory (deployed by `cog init`)
    const bootstrap_prompt = loadCustomPrompt(allocator, cog_dir, "MEM_BOOTSTRAP.md") orelse {
        printErr("  " ++ bold ++ "error:" ++ reset ++ " .cog/MEM_BOOTSTRAP.md not found. Run " ++ dim ++ "cog init" ++ reset ++ " first.\n\n");
        return;
    };
    defer allocator.free(bootstrap_prompt);

    const associate_prompt = loadCustomPrompt(allocator, cog_dir, "MEM_BOOTSTRAP_ASSOCIATE.md") orelse {
        printErr("  " ++ bold ++ "error:" ++ reset ++ " .cog/MEM_BOOTSTRAP_ASSOCIATE.md not found. Run " ++ dim ++ "cog init" ++ reset ++ " first.\n\n");
        return;
    };
    defer allocator.free(associate_prompt);

    // Filter out already-processed subsystems
    var remaining: std.ArrayListUnmanaged(Subsystem) = .empty;
    defer remaining.deinit(allocator);
    for (all_subsystems) |sub| {
        if (!processed.contains(sub.id)) {
            try remaining.append(allocator, sub);
        }
    }

    if (remaining.items.len == 0) {
        printErr("  All subsystems already processed. Use " ++ dim ++ "--clean" ++ reset ++ " to restart.\n\n");
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

    const total_subsystems = all_subsystems.len;
    const already_done = processed.count();
    const use_tui = !debug and tui.isStderrTty();

    // Resolve brain URL for display
    const brain_url_subtitle: ?[]const u8 = blk: {
        const cog_content = config_mod.findCogFile(allocator) catch break :blk null;
        defer allocator.free(cog_content);
        const url = config_mod.resolveBrainUrl(allocator, cog_content) catch break :blk null;
        break :blk url;
    };
    defer if (brain_url_subtitle) |u| allocator.free(u);

    if (use_tui) {
        tui.bootstrapStart("Bootstrapping", total_subsystems, brain_url_subtitle);
        if (already_done > 0) {
            tui.bootstrapUpdate(already_done, total_subsystems, 0, 0, 0, 0, 0);
        }
    } else {
        printFmtErr(allocator, "  Processing {d} subsystems (concurrency={d})\n\n", .{ remaining.items.len, concurrency });
    }

    var subsystems_done: usize = already_done;
    var errors: usize = 0;
    var total_input_tokens: usize = 0;
    var total_output_tokens: usize = 0;
    var total_cost_microdollars: usize = 0; // cost * 1_000_000

    // Activity ticker — background thread that shows a spinner + elapsed time
    var tui_mutex: std.Thread.Mutex = .{};
    var ticker_ctx = TickerContext{ .mutex = &tui_mutex, .num_slots = @min(concurrency, max_ticker_slots) };
    var ticker_thread: ?std.Thread = null;
    if (use_tui) {
        ticker_thread = std.Thread.spawn(.{}, tickerFn, .{&ticker_ctx}) catch null;
    }

    var aborted = false;

    if (concurrency <= 1) {
        // Sequential processing — one subsystem at a time
        var consecutive_errors: usize = 0;
        for (remaining.items) |*subsystem| {
            if (use_tui) {
                tui_mutex.lock();
                _ = ticker_ctx.claimSlot(subsystem.label);
                tui_mutex.unlock();
            } else {
                printFmtErr(allocator, "  " ++ cyan ++ "[{d}/{d}]" ++ reset ++ " {s}\n", .{
                    subsystems_done + errors + 1,
                    total_subsystems,
                    subsystem.label,
                });
            }

            const result = runSubsystem(allocator, subsystem, project_root, selected_agent, custom_cmd, debug, timeout_ms, model, bootstrap_prompt, use_tui);
            if (result.success) {
                subsystems_done += 1;
                consecutive_errors = 0;
                total_input_tokens += result.input_tokens;
                total_output_tokens += result.output_tokens;
                total_cost_microdollars += result.cost_microdollars;
                const duped = allocator.dupe(u8, subsystem.id) catch continue;
                processed.put(allocator, duped, {}) catch {
                    allocator.free(duped);
                };
                saveCheckpoint(allocator, checkpoint_path, &processed, all_subsystems);
            } else {
                errors += 1;
                consecutive_errors += 1;
            }

            if (use_tui) {
                tui_mutex.lock();
                ticker_ctx.releaseSlot(0);
                const tl = ticker_ctx.prev_lines;
                ticker_ctx.prev_lines = 0;
                tui.bootstrapUpdate(subsystems_done + errors, total_subsystems, errors, total_input_tokens, total_output_tokens, total_cost_microdollars, tl);
                tui_mutex.unlock();
            } else if (result.success) {
                printFmtErr(allocator, "    " ++ green ++ "done" ++ reset ++ " ({d}/{d}) tokens: {d}in/{d}out ${s}\n", .{
                    subsystems_done,
                    total_subsystems,
                    total_input_tokens,
                    total_output_tokens,
                    formatCost(allocator, total_cost_microdollars),
                });
            } else {
                printErr("    " ++ red ++ "failed" ++ reset ++ "\n");
            }

            if (consecutive_errors >= max_consecutive_errors) {
                aborted = true;
                break;
            }
        }
    } else {
        // Concurrent processing — thread pool of `concurrency` workers
        var subsystem_index = std.atomic.Value(usize).init(0);
        var done_count = std.atomic.Value(usize).init(already_done);
        var error_count = std.atomic.Value(usize).init(0);
        var atomic_input_tokens = std.atomic.Value(usize).init(0);
        var atomic_output_tokens = std.atomic.Value(usize).init(0);
        var atomic_cost = std.atomic.Value(usize).init(0);
        var abort_flag = std.atomic.Value(bool).init(false);
        var consec_errors = std.atomic.Value(usize).init(0);

        var shared = WorkerShared{
            .file_index = &subsystem_index,
            .done_count = &done_count,
            .error_count = &error_count,
            .atomic_input_tokens = &atomic_input_tokens,
            .atomic_output_tokens = &atomic_output_tokens,
            .atomic_cost = &atomic_cost,
            .abort = &abort_flag,
            .consecutive_errors = &consec_errors,
            .remaining = remaining.items,
            .all_subsystems = all_subsystems,
            .total_subsystems = total_subsystems,
            .project_root = project_root,
            .selected_agent = selected_agent,
            .custom_cmd = custom_cmd,
            .model = model,
            .bootstrap_prompt = bootstrap_prompt,
            .allocator = allocator,
            .checkpoint_path = checkpoint_path,
            .processed = &processed,
            .debug = debug,
            .timeout_ms = timeout_ms,
            .use_tui = use_tui,
            .tui_mutex = &tui_mutex,
            .ticker = if (use_tui) &ticker_ctx else null,
        };

        // Spawn worker threads
        var threads: std.ArrayListUnmanaged(std.Thread) = .empty;
        defer threads.deinit(allocator);

        const worker_count = @min(concurrency, total_subsystems);
        for (0..worker_count) |_| {
            const thread = std.Thread.spawn(.{}, workerThread, .{&shared}) catch continue;
            try threads.append(allocator, thread);
        }

        // Join all
        for (threads.items) |thread| {
            thread.join();
        }

        subsystems_done = done_count.load(.acquire);
        errors = error_count.load(.acquire);
        total_input_tokens = atomic_input_tokens.load(.acquire);
        total_output_tokens = atomic_output_tokens.load(.acquire);
        total_cost_microdollars = atomic_cost.load(.acquire);
        if (abort_flag.load(.acquire)) aborted = true;
    }

    // Stop ticker before phase 1 finish
    const finish_extra_lines = ticker_ctx.prev_lines;
    stopTicker(&ticker_thread, &ticker_ctx);

    if (aborted) {
        printFmtErr(allocator, "\n  " ++ red ++ "Aborting: {d} consecutive failures — possible API rate limit." ++ reset ++ "\n  Resume later with: " ++ dim ++ "cog mem:bootstrap" ++ reset ++ "\n", .{max_consecutive_errors});
    }

    // Phase 1 finish
    if (use_tui) {
        tui.bootstrapFinish("Bootstrapping", subsystems_done + errors, errors, total_input_tokens, total_output_tokens, total_cost_microdollars, finish_extra_lines);
    } else {
        printErr("\n" ++ bold ++ "  Phase 1: Extraction Summary" ++ reset ++ "\n");
        printFmtErr(allocator, "    Subsystems processed: {d}\n", .{subsystems_done});
        if (errors > 0) {
            printFmtErr(allocator, "    Errors:              {d}\n", .{errors});
        }
        printFmtErr(allocator, "    Input tokens:        {d}\n", .{total_input_tokens});
        printFmtErr(allocator, "    Output tokens:       {d}\n", .{total_output_tokens});
        printFmtErr(allocator, "    Cost:                ${s}\n", .{formatCost(allocator, total_cost_microdollars)});
        printFmtErr(allocator, "    Total processed:     {d}/{d}\n", .{ processed.count(), all_subsystems.len });
    }

    // Phase 2: Cross-subsystem association from SCIP index
    if (subsystems_done > 1) {
        // Build cross-file relationship text from SCIP index, filtered to cross-subsystem only
        const cross_file = buildCrossFileRelationships(allocator, cog_dir, all_subsystems);
        defer if (cross_file) |cf| allocator.free(cf.text);

        if (cross_file) |cf| {
            if (cf.text.len == 0) {
                if (!use_tui) printErr("    No cross-subsystem references found in SCIP index\n");
            } else {
                if (use_tui) {
                    tui.bootstrapPhaseStart("Associating", "Pairs", cf.pair_count);
                    startTicker(&ticker_thread, &ticker_ctx, "Running agent...");
                } else {
                    printErr("\n" ++ bold ++ "  Phase 2: Cross-subsystem associations" ++ reset ++ "\n");
                    printFmtErr(allocator, "    Found {d} cross-subsystem dependency pairs\n", .{cf.pair_count});
                }

                const assoc_result = runAssociationPhase(allocator, project_root, selected_agent, custom_cmd, cf.text, debug, timeout_ms, model, associate_prompt, use_tui);

                const phase2_extra = ticker_ctx.prev_lines;
                stopTicker(&ticker_thread, &ticker_ctx);

                if (assoc_result.success) {
                    total_input_tokens += assoc_result.input_tokens;
                    total_output_tokens += assoc_result.output_tokens;
                    total_cost_microdollars += assoc_result.cost_microdollars;
                }

                if (use_tui) {
                    tui.bootstrapPhaseFinish("Associating", "Pairs", cf.pair_count, assoc_result.input_tokens, assoc_result.output_tokens, assoc_result.cost_microdollars, assoc_result.success, phase2_extra);
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
            if (!use_tui) printErr("    Could not load SCIP index for cross-subsystem analysis\n");
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
    abort: *std.atomic.Value(bool),
    consecutive_errors: *std.atomic.Value(usize),
    remaining: []const Subsystem,
    all_subsystems: []const Subsystem,
    total_subsystems: usize,
    project_root: []const u8,
    selected_agent: ?*const CliAgent,
    custom_cmd: ?[]const u8,
    model: ?[]const u8,
    bootstrap_prompt: []const u8,
    allocator: std.mem.Allocator,
    checkpoint_path: []const u8,
    processed: *std.StringHashMapUnmanaged(void),
    debug: bool,
    timeout_ms: u64,
    use_tui: bool,
    tui_mutex: *std.Thread.Mutex,
    ticker: ?*TickerContext,
};

fn workerThread(shared: *WorkerShared) void {
    while (true) {
        if (shared.abort.load(.acquire) or g_cancel_requested.load(.acquire)) break;

        const idx = shared.file_index.fetchAdd(1, .monotonic);
        if (idx >= shared.remaining.len) break;

        const subsystem = &shared.remaining[idx];

        var my_slot: usize = 0;
        if (shared.use_tui) {
            if (shared.ticker) |ticker| {
                shared.tui_mutex.lock();
                my_slot = ticker.claimSlot(subsystem.label);
                shared.tui_mutex.unlock();
            }
        } else {
            printFmtErr(shared.allocator, "  " ++ cyan ++ "[{d}/{d}]" ++ reset ++ " {s}\n", .{
                idx + 1,
                shared.total_subsystems,
                subsystem.label,
            });
        }

        const result = runSubsystem(shared.allocator, subsystem, shared.project_root, shared.selected_agent, shared.custom_cmd, shared.debug, shared.timeout_ms, shared.model, shared.bootstrap_prompt, shared.use_tui);
        if (result.success) {
            shared.consecutive_errors.store(0, .release);
            const done = shared.done_count.fetchAdd(1, .monotonic) + 1;
            _ = shared.atomic_input_tokens.fetchAdd(result.input_tokens, .monotonic);
            _ = shared.atomic_output_tokens.fetchAdd(result.output_tokens, .monotonic);
            _ = shared.atomic_cost.fetchAdd(result.cost_microdollars, .monotonic);
            const duped = shared.allocator.dupe(u8, subsystem.id) catch continue;
            shared.processed.put(shared.allocator, duped, {}) catch {
                shared.allocator.free(duped);
            };
            saveCheckpoint(shared.allocator, shared.checkpoint_path, shared.processed, shared.all_subsystems);

            if (shared.use_tui) {
                shared.tui_mutex.lock();
                if (shared.ticker) |ticker| {
                    ticker.releaseSlot(my_slot);
                    const tl = ticker.prev_lines;
                    ticker.prev_lines = 0;
                    tui.bootstrapUpdate(
                        done + shared.error_count.load(.acquire),
                        shared.total_subsystems,
                        shared.error_count.load(.acquire),
                        shared.atomic_input_tokens.load(.acquire),
                        shared.atomic_output_tokens.load(.acquire),
                        shared.atomic_cost.load(.acquire),
                        tl,
                    );
                }
                shared.tui_mutex.unlock();
            } else {
                const in_tok = shared.atomic_input_tokens.load(.acquire);
                const out_tok = shared.atomic_output_tokens.load(.acquire);
                const cost = shared.atomic_cost.load(.acquire);
                printFmtErr(shared.allocator, "    " ++ green ++ "done" ++ reset ++ " {s} ({d}/{d}) tokens: {d}in/{d}out ${s}\n", .{
                    subsystem.label,
                    done,
                    shared.total_subsystems,
                    in_tok,
                    out_tok,
                    formatCost(shared.allocator, cost),
                });
            }
        } else {
            const consec = shared.consecutive_errors.fetchAdd(1, .monotonic) + 1;
            if (consec >= max_consecutive_errors) {
                shared.abort.store(true, .release);
            }
            const errs = shared.error_count.fetchAdd(1, .monotonic) + 1;

            if (shared.use_tui) {
                shared.tui_mutex.lock();
                if (shared.ticker) |ticker| {
                    ticker.releaseSlot(my_slot);
                    const tl = ticker.prev_lines;
                    ticker.prev_lines = 0;
                    tui.bootstrapUpdate(
                        shared.done_count.load(.acquire) + errs,
                        shared.total_subsystems,
                        errs,
                        shared.atomic_input_tokens.load(.acquire),
                        shared.atomic_output_tokens.load(.acquire),
                        shared.atomic_cost.load(.acquire),
                        tl,
                    );
                }
                shared.tui_mutex.unlock();
            } else {
                printFmtErr(shared.allocator, "    " ++ red ++ "failed" ++ reset ++ " {s}\n", .{subsystem.label});
            }
        }
    }
}

// ── Activity ticker ─────────────────────────────────────────────────────
// Background thread that redraws the active-file lines of the TUI progress
// block. Supports multiple concurrent slots so each worker's file is visible.

const max_ticker_slots = 16;

const TickerSlot = struct {
    label: []const u8 = "",
    start_ms: i64 = 0,
};

const TickerContext = struct {
    mutex: *std.Thread.Mutex,
    stop: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    slots: [max_ticker_slots]TickerSlot = [_]TickerSlot{.{}} ** max_ticker_slots,
    num_slots: usize = 1, // how many slots are available (= concurrency)
    prev_lines: usize = 0, // how many file lines were drawn last tick

    fn claimSlot(self: *TickerContext, label: []const u8) usize {
        for (self.slots[0..self.num_slots], 0..) |*slot, i| {
            if (slot.label.len == 0) {
                slot.label = label;
                slot.start_ms = std.time.milliTimestamp();
                return i;
            }
        }
        // Fallback: overwrite slot 0
        self.slots[0].label = label;
        self.slots[0].start_ms = std.time.milliTimestamp();
        return 0;
    }

    fn releaseSlot(self: *TickerContext, slot_idx: usize) void {
        if (slot_idx < self.num_slots) {
            self.slots[slot_idx] = .{};
        }
    }
};

const spinner_frames = [_][]const u8{ "\xe2\xa0\x8b", "\xe2\xa0\x99", "\xe2\xa0\xb9", "\xe2\xa0\xb8", "\xe2\xa0\xbc", "\xe2\xa0\xb4", "\xe2\xa0\xa6", "\xe2\xa0\xa7", "\xe2\xa0\x87", "\xe2\xa0\x8f" };

fn tickerFn(ctx: *TickerContext) void {
    var frame: usize = 0;
    while (!ctx.stop.load(.acquire)) {
        std.Thread.sleep(200 * std.time.ns_per_ms);
        if (ctx.stop.load(.acquire)) break;

        ctx.mutex.lock();
        defer ctx.mutex.unlock();

        // Count active slots
        var active: usize = 0;
        for (ctx.slots[0..ctx.num_slots]) |slot| {
            if (slot.label.len > 0) active += 1;
        }
        if (active == 0) continue;

        // Clear previous file lines
        if (ctx.prev_lines > 0) {
            tui.clearLines(ctx.prev_lines);
        }

        // Draw one line per active slot
        const now = std.time.milliTimestamp();
        var drawn: usize = 0;
        for (ctx.slots[0..ctx.num_slots]) |slot| {
            if (slot.label.len == 0) continue;
            const elapsed_ms = now - slot.start_ms;
            const elapsed_s: u64 = if (elapsed_ms > 0) @intCast(@divTrunc(elapsed_ms, 1000)) else 0;
            tui.bootstrapTickLine(spinner_frames[frame % spinner_frames.len], slot.label, elapsed_s);
            drawn += 1;
        }
        ctx.prev_lines = drawn;
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
    ticker_ctx.slots[0] = .{ .label = label, .start_ms = std.time.milliTimestamp() };
    ticker_ctx.prev_lines = 0;
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
    timeout_ms: u64,
    model: ?[]const u8,
    bootstrap_prompt: []const u8,
    use_tui: bool,
) FileResult {
    const fail: FileResult = .{ .success = false, .input_tokens = 0, .output_tokens = 0, .cost_microdollars = 0 };

    // Build prompt: template with file path
    const template = bootstrap_prompt;
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
        if (model) |m| {
            argv_buf.append(allocator, "--model") catch return fail;
            argv_buf.append(allocator, m) catch return fail;
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

    // Bail out if cancellation was requested before spawning
    if (g_cancel_requested.load(.acquire)) return fail;

    debug_log.log("runFile: {s} (argv len={d})", .{ file_path, argv_buf.items.len });

    var child = std.process.Child.init(argv_buf.items, allocator);
    child.cwd = project_root;
    child.stdin_behavior = .Ignore; // Prevent children from consuming Ctrl+C bytes on stdin
    child.stderr_behavior = if (debug) .Inherit else .Ignore;
    child.stdout_behavior = .Pipe;
    child.pgid = 0; // Make child its own process group leader for reliable group kill

    child.spawn() catch |err| {
        debug_log.log("runFile: spawn error {s}", .{@errorName(err)});
        if (!use_tui) printFmtErr(allocator, "    " ++ red ++ "spawn error: {s}" ++ reset ++ "\n", .{@errorName(err)});
        return fail;
    };
    const child_pid: i32 = child.id;
    // Register immediately — minimize the window where cancel() can't see this child.
    if (child_pid > 0) registerChild(child_pid);
    debug_log.log("runFile: spawned child pid={d}", .{child_pid});
    const reaper = spawnReaper(child_pid);

    // If cancel arrived during spawn, kill this child immediately
    if (g_cancel_requested.load(.acquire)) {
        if (child_pid > 0) {
            _ = std.c.kill(-child_pid, posix.SIG.KILL);
            _ = std.c.kill(child_pid, posix.SIG.KILL);
            unregisterChild(child_pid);
        }
        dismissReaper(reaper);
        return fail;
    }

    // Start timeout watcher
    var tw = TimeoutWatcher{ .pid = child_pid, .timeout_ms = timeout_ms };
    const tw_thread = if (timeout_ms > 0)
        std.Thread.spawn(.{}, TimeoutWatcher.watch, .{&tw}) catch null
    else
        null;

    // Read stdout (JSON output from agents like Claude)
    const stdout_data = if (child.stdout) |stdout|
        stdout.readToEndAlloc(allocator, 10 * 1024 * 1024) catch null
    else
        null;
    defer if (stdout_data) |d| allocator.free(d);

    const term = child.wait() catch |err| {
        tw.cancelled.store(true, .release);
        if (tw_thread) |t| t.join();
        if (child_pid > 0) unregisterChild(child_pid);
        dismissReaper(reaper);
        if (!use_tui) printFmtErr(allocator, "    " ++ red ++ "wait error: {s}" ++ reset ++ "\n", .{@errorName(err)});
        return fail;
    };
    tw.cancelled.store(true, .release);
    if (tw_thread) |t| t.join();
    if (child_pid > 0) unregisterChild(child_pid);
    dismissReaper(reaper);

    switch (term) {
        .Exited => |code| {
            debug_log.log("runFile: {s} exited code={d}", .{ file_path, code });
            if (code != 0) {
                if (!use_tui) printFmtErr(allocator, "    " ++ red ++ "exited with code {d}" ++ reset ++ "\n", .{code});
                return fail;
            }
        },
        .Signal => |sig| {
            debug_log.log("runFile: {s} killed by signal {d}", .{ file_path, sig });
            if (!use_tui) {
                if (sig == posix.SIG.KILL and tw.fired.load(.acquire)) {
                    printFmtErr(allocator, "    " ++ red ++ "timed out after {d}m" ++ reset ++ "\n", .{timeout_ms / 60_000});
                } else {
                    printFmtErr(allocator, "    " ++ red ++ "killed by signal {d}" ++ reset ++ "\n", .{sig});
                }
            }
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

fn runSubsystem(
    allocator: std.mem.Allocator,
    subsystem: *const Subsystem,
    project_root: []const u8,
    selected_agent: ?*const CliAgent,
    custom_cmd: ?[]const u8,
    debug: bool,
    timeout_ms: u64,
    model: ?[]const u8,
    bootstrap_prompt: []const u8,
    use_tui: bool,
) FileResult {
    const fail: FileResult = .{ .success = false, .input_tokens = 0, .output_tokens = 0, .cost_microdollars = 0 };

    // Build file_paths as newline-joined string of all files in this subsystem
    var file_paths_buf: std.ArrayListUnmanaged(u8) = .empty;
    defer file_paths_buf.deinit(allocator);
    for (subsystem.files, 0..) |f, i| {
        file_paths_buf.appendSlice(allocator, f) catch return fail;
        if (i + 1 < subsystem.files.len) {
            file_paths_buf.append(allocator, '\n') catch return fail;
        }
    }
    const file_paths_str = file_paths_buf.items;

    // Build prompt: template with placeholders replaced
    const template = bootstrap_prompt;
    const prompt1 = replacePlaceholder(allocator, template, "{file_paths}", file_paths_str) catch return fail;
    defer allocator.free(prompt1);
    const prompt2 = replacePlaceholder(allocator, prompt1, "{cross_file_context}", subsystem.cross_file_context) catch return fail;
    defer allocator.free(prompt2);
    const prompt = replacePlaceholder(allocator, prompt2, "{subsystem_label}", subsystem.label) catch return fail;
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
        if (model) |m| {
            argv_buf.append(allocator, "--model") catch return fail;
            argv_buf.append(allocator, m) catch return fail;
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

    // Bail out if cancellation was requested before spawning
    if (g_cancel_requested.load(.acquire)) return fail;

    // Timeout scales with file count, capped at 5x
    const scaled_timeout = timeout_ms * @min(subsystem.files.len, 5);

    debug_log.log("runSubsystem: label={s} id={s} files={d} (argv len={d})", .{ subsystem.label, subsystem.id, subsystem.files.len, argv_buf.items.len });

    var child = std.process.Child.init(argv_buf.items, allocator);
    child.cwd = project_root;
    child.stdin_behavior = .Ignore;
    child.stderr_behavior = if (debug) .Inherit else .Ignore;
    child.stdout_behavior = .Pipe;
    child.pgid = 0;

    child.spawn() catch |err| {
        debug_log.log("runSubsystem: spawn error {s}", .{@errorName(err)});
        if (!use_tui) printFmtErr(allocator, "    " ++ red ++ "spawn error: {s}" ++ reset ++ "\n", .{@errorName(err)});
        return fail;
    };
    const child_pid: i32 = child.id;
    if (child_pid > 0) registerChild(child_pid);
    debug_log.log("runSubsystem: spawned child pid={d}", .{child_pid});
    const reaper = spawnReaper(child_pid);

    // If cancel arrived during spawn, kill this child immediately
    if (g_cancel_requested.load(.acquire)) {
        if (child_pid > 0) {
            _ = std.c.kill(-child_pid, posix.SIG.KILL);
            _ = std.c.kill(child_pid, posix.SIG.KILL);
            unregisterChild(child_pid);
        }
        dismissReaper(reaper);
        return fail;
    }

    // Start timeout watcher
    var tw = TimeoutWatcher{ .pid = child_pid, .timeout_ms = scaled_timeout };
    const tw_thread = if (scaled_timeout > 0)
        std.Thread.spawn(.{}, TimeoutWatcher.watch, .{&tw}) catch null
    else
        null;

    // Read stdout
    const stdout_data = if (child.stdout) |stdout|
        stdout.readToEndAlloc(allocator, 10 * 1024 * 1024) catch null
    else
        null;
    defer if (stdout_data) |d| allocator.free(d);

    const term = child.wait() catch |err| {
        tw.cancelled.store(true, .release);
        if (tw_thread) |t| t.join();
        if (child_pid > 0) unregisterChild(child_pid);
        dismissReaper(reaper);
        if (!use_tui) printFmtErr(allocator, "    " ++ red ++ "wait error: {s}" ++ reset ++ "\n", .{@errorName(err)});
        return fail;
    };
    tw.cancelled.store(true, .release);
    if (tw_thread) |t| t.join();
    if (child_pid > 0) unregisterChild(child_pid);
    dismissReaper(reaper);

    switch (term) {
        .Exited => |code| {
            debug_log.log("runSubsystem: {s} exited code={d}", .{ subsystem.label, code });
            if (code != 0) {
                if (!use_tui) printFmtErr(allocator, "    " ++ red ++ "exited with code {d}" ++ reset ++ "\n", .{code});
                return fail;
            }
        },
        .Signal => |sig| {
            debug_log.log("runSubsystem: {s} killed by signal {d}", .{ subsystem.label, sig });
            if (!use_tui) {
                if (sig == posix.SIG.KILL and tw.fired.load(.acquire)) {
                    printFmtErr(allocator, "    " ++ red ++ "timed out after {d}m" ++ reset ++ "\n", .{scaled_timeout / 60_000});
                } else {
                    printFmtErr(allocator, "    " ++ red ++ "killed by signal {d}" ++ reset ++ "\n", .{sig});
                }
            }
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
    timeout_ms: u64,
    model: ?[]const u8,
    associate_prompt: []const u8,
    use_tui: bool,
) FileResult {
    const fail: FileResult = .{ .success = false, .input_tokens = 0, .output_tokens = 0, .cost_microdollars = 0 };

    // Build prompt from association template with SCIP-derived relationships
    const template = associate_prompt;
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
        if (model) |m| {
            argv_buf.append(allocator, "--model") catch return fail;
            argv_buf.append(allocator, m) catch return fail;
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

    // Bail out if cancellation was requested before spawning
    if (g_cancel_requested.load(.acquire)) return fail;

    var child = std.process.Child.init(argv_buf.items, allocator);
    child.cwd = project_root;
    child.stdin_behavior = .Ignore; // Prevent children from consuming Ctrl+C bytes on stdin
    child.stderr_behavior = if (debug) .Inherit else .Ignore;
    child.stdout_behavior = .Pipe;
    child.pgid = 0; // Make child its own process group leader for reliable group kill

    child.spawn() catch |err| {
        if (!use_tui) printFmtErr(allocator, "    " ++ red ++ "spawn error: {s}" ++ reset ++ "\n", .{@errorName(err)});
        return fail;
    };
    const assoc_pid: i32 = child.id;
    if (assoc_pid > 0) registerChild(assoc_pid);
    const reaper = spawnReaper(assoc_pid);

    // If cancel arrived during spawn, kill this child immediately
    if (g_cancel_requested.load(.acquire)) {
        if (assoc_pid > 0) {
            _ = std.c.kill(-assoc_pid, posix.SIG.KILL);
            _ = std.c.kill(assoc_pid, posix.SIG.KILL);
            unregisterChild(assoc_pid);
        }
        dismissReaper(reaper);
        return fail;
    }

    // Start timeout watcher
    var tw = TimeoutWatcher{ .pid = assoc_pid, .timeout_ms = timeout_ms };
    const tw_thread = if (timeout_ms > 0)
        std.Thread.spawn(.{}, TimeoutWatcher.watch, .{&tw}) catch null
    else
        null;

    const stdout_data = if (child.stdout) |stdout|
        stdout.readToEndAlloc(allocator, 10 * 1024 * 1024) catch null
    else
        null;
    defer if (stdout_data) |d| allocator.free(d);

    const term = child.wait() catch |err| {
        tw.cancelled.store(true, .release);
        if (tw_thread) |t| t.join();
        if (assoc_pid > 0) unregisterChild(assoc_pid);
        dismissReaper(reaper);
        if (!use_tui) printFmtErr(allocator, "    " ++ red ++ "wait error: {s}" ++ reset ++ "\n", .{@errorName(err)});
        return fail;
    };
    tw.cancelled.store(true, .release);
    if (tw_thread) |t| t.join();
    if (assoc_pid > 0) unregisterChild(assoc_pid);
    dismissReaper(reaper);

    switch (term) {
        .Exited => |code| {
            if (code != 0) {
                if (!use_tui) printFmtErr(allocator, "    " ++ red ++ "exited with code {d}" ++ reset ++ "\n", .{code});
                return fail;
            }
        },
        .Signal => |sig| {
            if (!use_tui) {
                if (sig == posix.SIG.KILL and tw.fired.load(.acquire)) {
                    printFmtErr(allocator, "    " ++ red ++ "timed out after {d}m" ++ reset ++ "\n", .{timeout_ms / 60_000});
                } else {
                    printFmtErr(allocator, "    " ++ red ++ "killed by signal {d}" ++ reset ++ "\n", .{sig});
                }
            }
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

// ── Subsystem clustering ────────────────────────────────────────────────

const Subsystem = struct {
    id: []const u8, // 16-char hex hash of sorted file list
    label: []const u8, // human-readable: common directory or "root"
    files: []const []const u8, // sorted file paths
    cross_file_context: []const u8, // intra-cluster cross-file relationships text
};

/// Key for a pair of files, used in cross-file weight graph.
const FilePairKey = struct {
    file_a: []const u8,
    file_b: []const u8,
};

const FilePairContext = struct {
    pub fn hash(_: @This(), key: FilePairKey) u64 {
        var h = std.hash.Wyhash.init(0);
        // Always hash in sorted order for symmetry
        const order = std.mem.order(u8, key.file_a, key.file_b);
        if (order == .lt or order == .eq) {
            h.update(key.file_a);
            h.update("\x00");
            h.update(key.file_b);
        } else {
            h.update(key.file_b);
            h.update("\x00");
            h.update(key.file_a);
        }
        return h.final();
    }
    pub fn eql(_: @This(), a: FilePairKey, b: FilePairKey) bool {
        // Symmetric comparison
        return (std.mem.eql(u8, a.file_a, b.file_a) and std.mem.eql(u8, a.file_b, b.file_b)) or
            (std.mem.eql(u8, a.file_a, b.file_b) and std.mem.eql(u8, a.file_b, b.file_a));
    }
};

/// Group source files into subsystem clusters for batch extraction.
///
/// Algorithm:
/// 1. Seed clusters by directory grouping
/// 2. Build weighted cross-file graph from SCIP
/// 3. Merge small clusters (<3 files) into most-coupled neighbor
/// 4. Split large clusters (>12 files) by subdirectory or alphabetically
/// 5. Generate subsystem IDs and cross-file context per cluster
fn buildSubsystemClusters(allocator: std.mem.Allocator, files: []const []const u8, cog_dir: []const u8) ?[]Subsystem {
    if (files.len == 0) return null;

    // Step 1: Seed by directory
    var dir_groups: std.StringHashMapUnmanaged(std.ArrayListUnmanaged([]const u8)) = .empty;
    defer {
        var vit = dir_groups.valueIterator();
        while (vit.next()) |list| list.deinit(allocator);
        dir_groups.deinit(allocator);
    }

    for (files) |file_path| {
        const dir_name = std.fs.path.dirname(file_path) orelse "root";
        const gop = dir_groups.getOrPut(allocator, dir_name) catch continue;
        if (!gop.found_existing) {
            gop.value_ptr.* = .empty;
        }
        gop.value_ptr.append(allocator, file_path) catch continue;
    }

    debug_log.log("buildSubsystemClusters: seeded {d} directory groups from {d} files", .{ dir_groups.count(), files.len });

    // Step 2: Build weighted cross-file graph from SCIP
    var file_pair_weights: std.HashMapUnmanaged(FilePairKey, usize, FilePairContext, 80) = .empty;
    defer file_pair_weights.deinit(allocator);

    // Also build per-pair symbol lists for cross-file context generation
    const SymbolPairKey = struct {
        referencing: []const u8,
        defining: []const u8,
    };
    const SymbolPairContext = struct {
        pub fn hash(_: @This(), key: @This().KeyType) u64 {
            var h = std.hash.Wyhash.init(0);
            h.update(key.referencing);
            h.update("\x00");
            h.update(key.defining);
            return h.final();
        }
        pub fn eql(_: @This(), a: @This().KeyType, b: @This().KeyType) bool {
            return std.mem.eql(u8, a.referencing, b.referencing) and
                std.mem.eql(u8, a.defining, b.defining);
        }
        const KeyType = SymbolPairKey;
    };
    var pair_symbols_map: std.HashMapUnmanaged(
        SymbolPairKey,
        std.ArrayListUnmanaged([]const u8),
        SymbolPairContext,
        80,
    ) = .empty;
    defer {
        var psit = pair_symbols_map.valueIterator();
        while (psit.next()) |list| list.deinit(allocator);
        pair_symbols_map.deinit(allocator);
    }

    // Load and decode SCIP index
    const index_path = std.fmt.allocPrint(allocator, "{s}/index.scip", .{cog_dir}) catch return null;
    defer allocator.free(index_path);

    const scip_file = std.fs.openFileAbsolute(index_path, .{}) catch {
        debug_log.log("buildSubsystemClusters: cannot open SCIP index", .{});
        return null;
    };
    defer scip_file.close();

    const scip_data = scip_file.readToEndAlloc(allocator, 256 * 1024 * 1024) catch return null;
    var index = scip.decode(allocator, scip_data) catch {
        allocator.free(scip_data);
        return null;
    };
    defer {
        scip.freeIndex(allocator, &index);
        allocator.free(scip_data);
    }

    // Build symbol → defining file map
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

    // Build cross-file weights and symbol lists
    for (index.documents) |doc| {
        for (doc.occurrences) |occ| {
            if (occ.symbol.len == 0 or std.mem.startsWith(u8, occ.symbol, "local ")) continue;
            if (scip.SymbolRole.isDefinition(occ.symbol_roles)) continue;

            const defining_file = symbol_to_file.get(occ.symbol) orelse continue;
            if (std.mem.eql(u8, defining_file, doc.relative_path)) continue;

            // Add weight to the file pair
            const pair_key = FilePairKey{ .file_a = doc.relative_path, .file_b = defining_file };
            const wgop = file_pair_weights.getOrPut(allocator, pair_key) catch continue;
            if (!wgop.found_existing) {
                wgop.value_ptr.* = 0;
            }
            wgop.value_ptr.* += 1;

            // Track symbols for cross-file context
            const sym_key = SymbolPairKey{ .referencing = doc.relative_path, .defining = defining_file };
            const sgop = pair_symbols_map.getOrPut(allocator, sym_key) catch continue;
            if (!sgop.found_existing) {
                sgop.value_ptr.* = .empty;
            }
            const sym_name = scip.extractSymbolName(occ.symbol);
            var sym_found = false;
            for (sgop.value_ptr.items) |existing| {
                if (std.mem.eql(u8, existing, sym_name)) {
                    sym_found = true;
                    break;
                }
            }
            if (!sym_found) {
                sgop.value_ptr.append(allocator, sym_name) catch continue;
            }
        }
    }

    // Step 3: Merge small clusters (<3 files)
    // Convert dir_groups to a mutable cluster list
    const ClusterEntry = struct {
        label: []const u8,
        file_list: std.ArrayListUnmanaged([]const u8),
    };
    var clusters: std.ArrayListUnmanaged(ClusterEntry) = .empty;
    defer {
        for (clusters.items) |*cl| cl.file_list.deinit(allocator);
        clusters.deinit(allocator);
    }

    {
        var dgit = dir_groups.iterator();
        while (dgit.next()) |entry| {
            clusters.append(allocator, .{
                .label = entry.key_ptr.*,
                .file_list = entry.value_ptr.*,
            }) catch continue;
            // Prevent the deferred dir_groups cleanup from double-freeing
            entry.value_ptr.* = .empty;
        }
    }

    // Merge small clusters
    var merge_pass: usize = 0;
    while (merge_pass < 10) : (merge_pass += 1) {
        var merged_any = false;
        var ci: usize = 0;
        while (ci < clusters.items.len) {
            if (clusters.items[ci].file_list.items.len >= 3) {
                ci += 1;
                continue;
            }

            // Find best cluster to merge into
            var best_idx: ?usize = null;
            var best_score: usize = 0;

            for (clusters.items, 0..) |*other, oi| {
                if (oi == ci) continue;
                // Compute coupling score
                var score: usize = 0;
                for (clusters.items[ci].file_list.items) |f1| {
                    for (other.file_list.items) |f2| {
                        const pk = FilePairKey{ .file_a = f1, .file_b = f2 };
                        if (file_pair_weights.getAdapted(pk, FilePairContext{})) |w| {
                            score += w;
                        }
                    }
                }
                if (score > best_score) {
                    best_score = score;
                    best_idx = oi;
                }
            }

            // If no coupling found, merge into cluster with longest shared prefix
            if (best_idx == null and clusters.items.len > 1) {
                var best_prefix_len: usize = 0;
                for (clusters.items, 0..) |*other, oi| {
                    if (oi == ci) continue;
                    const prefix_len = commonPrefixLen(clusters.items[ci].label, other.label);
                    if (prefix_len > best_prefix_len or best_idx == null) {
                        best_prefix_len = prefix_len;
                        best_idx = oi;
                    }
                }
            }

            if (best_idx) |target| {
                debug_log.log("buildSubsystemClusters: merging small cluster '{s}' ({d} files) into '{s}'", .{
                    clusters.items[ci].label,
                    clusters.items[ci].file_list.items.len,
                    clusters.items[target].label,
                });
                // Move files from ci to target
                for (clusters.items[ci].file_list.items) |f| {
                    clusters.items[target].file_list.append(allocator, f) catch continue;
                }
                clusters.items[ci].file_list.clearRetainingCapacity();
                // Remove the empty cluster
                clusters.items[ci].file_list.deinit(allocator);
                _ = clusters.orderedRemove(ci);
                merged_any = true;
                // Don't increment ci — the next cluster slid into this position
            } else {
                ci += 1;
            }
        }
        if (!merged_any) break;
    }

    // Step 4: Split large clusters (>12 files)
    {
        var split_idx: usize = 0;
        while (split_idx < clusters.items.len) {
            if (clusters.items[split_idx].file_list.items.len <= 12) {
                split_idx += 1;
                continue;
            }

            const cluster = &clusters.items[split_idx];
            debug_log.log("buildSubsystemClusters: splitting large cluster '{s}' ({d} files)", .{
                cluster.label,
                cluster.file_list.items.len,
            });

            // Try to split by subdirectory within the cluster
            var sub_dirs: std.StringHashMapUnmanaged(std.ArrayListUnmanaged([]const u8)) = .empty;

            for (cluster.file_list.items) |f| {
                const sub_dir = std.fs.path.dirname(f) orelse "root";
                const sgop2 = sub_dirs.getOrPut(allocator, sub_dir) catch continue;
                if (!sgop2.found_existing) {
                    sgop2.value_ptr.* = .empty;
                }
                sgop2.value_ptr.append(allocator, f) catch continue;
            }

            if (sub_dirs.count() > 1) {
                // Split by subdirectory
                var first = true;
                var sdit2 = sub_dirs.iterator();
                while (sdit2.next()) |entry| {
                    if (first) {
                        // Replace the current cluster
                        cluster.file_list.clearRetainingCapacity();
                        for (entry.value_ptr.items) |f| {
                            cluster.file_list.append(allocator, f) catch continue;
                        }
                        cluster.label = entry.key_ptr.*;
                        entry.value_ptr.clearRetainingCapacity();
                        first = false;
                    } else {
                        // Add new cluster
                        var new_list: std.ArrayListUnmanaged([]const u8) = .empty;
                        for (entry.value_ptr.items) |f| {
                            new_list.append(allocator, f) catch continue;
                        }
                        entry.value_ptr.clearRetainingCapacity();
                        clusters.append(allocator, .{
                            .label = entry.key_ptr.*,
                            .file_list = new_list,
                        }) catch continue;
                    }
                }
            } else {
                // Split alphabetically into groups of ~8
                sortFiles(cluster.file_list.items);
                const total = cluster.file_list.items.len;
                const group_size: usize = 8;

                // Copy all items to a temp list before modifying the cluster
                var all_items: std.ArrayListUnmanaged([]const u8) = .empty;
                for (cluster.file_list.items) |f| {
                    all_items.append(allocator, f) catch continue;
                }

                // Keep first group_size in current cluster
                cluster.file_list.clearRetainingCapacity();
                const first_end = @min(group_size, total);
                for (all_items.items[0..first_end]) |f| {
                    cluster.file_list.append(allocator, f) catch continue;
                }

                var start: usize = first_end;
                while (start < total) {
                    const end_pos = @min(start + group_size, total);
                    var new_list: std.ArrayListUnmanaged([]const u8) = .empty;
                    for (all_items.items[start..end_pos]) |f| {
                        new_list.append(allocator, f) catch continue;
                    }
                    const new_label = if (new_list.items.len > 0)
                        std.fs.path.dirname(new_list.items[0]) orelse "root"
                    else
                        cluster.label;
                    clusters.append(allocator, .{
                        .label = new_label,
                        .file_list = new_list,
                    }) catch continue;
                    start = end_pos;
                }

                all_items.deinit(allocator);
            }

            // Clean up sub_dirs for this iteration
            var sdit_cleanup = sub_dirs.valueIterator();
            while (sdit_cleanup.next()) |list| list.deinit(allocator);
            sub_dirs.deinit(allocator);

            split_idx += 1;
        }
    }

    debug_log.log("buildSubsystemClusters: final cluster count: {d}", .{clusters.items.len});

    // Step 5 & 6: Generate subsystem IDs and cross-file context
    var result: std.ArrayListUnmanaged(Subsystem) = .empty;
    defer result.deinit(allocator);

    for (clusters.items) |*cluster| {
        // Sort files within cluster
        sortFiles(cluster.file_list.items);

        // Generate ID: hash sorted file list
        var hasher = std.hash.Wyhash.init(0);
        for (cluster.file_list.items) |f| {
            hasher.update(f);
            hasher.update("\n");
        }
        const hash_val = hasher.final();

        var id_buf: [16]u8 = undefined;
        const hex_chars = "0123456789abcdef";
        for (0..16) |hi| {
            const shift_amt: u6 = @intCast((15 - hi) * 4);
            id_buf[hi] = hex_chars[@as(usize, @intCast((hash_val >> shift_amt) & 0xf))];
        }
        const id = allocator.dupe(u8, &id_buf) catch continue;

        // Make owned copy of files
        const owned_files = allocator.alloc([]const u8, cluster.file_list.items.len) catch {
            allocator.free(id);
            continue;
        };
        for (cluster.file_list.items, 0..) |f, fi| {
            owned_files[fi] = allocator.dupe(u8, f) catch "";
        }

        // Make owned label
        const label = allocator.dupe(u8, cluster.label) catch {
            allocator.free(id);
            allocator.free(owned_files);
            continue;
        };

        // Generate cross-file context for within-cluster pairs
        const cross_ctx = buildIntraClusterContext(allocator, cluster.file_list.items, &pair_symbols_map);

        result.append(allocator, .{
            .id = id,
            .label = label,
            .files = owned_files,
            .cross_file_context = cross_ctx,
        }) catch {
            allocator.free(id);
            allocator.free(label);
            for (owned_files) |f| allocator.free(f);
            allocator.free(owned_files);
            allocator.free(cross_ctx);
            continue;
        };
    }

    if (result.items.len == 0) return null;

    return result.toOwnedSlice(allocator) catch null;
}

/// Build cross-file context text for files within a single cluster.
fn buildIntraClusterContext(
    allocator: std.mem.Allocator,
    cluster_files: []const []const u8,
    pair_symbols_map: anytype,
) []const u8 {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(allocator);

    // Build a set for O(1) lookup
    var file_set: std.StringHashMapUnmanaged(void) = .empty;
    defer file_set.deinit(allocator);
    for (cluster_files) |f| {
        file_set.put(allocator, f, {}) catch continue;
    }

    // Iterate all pair_symbols entries and emit those where both files are in this cluster
    var psit = pair_symbols_map.iterator();
    while (psit.next()) |entry| {
        const ref_file = entry.key_ptr.referencing;
        const def_file = entry.key_ptr.defining;
        if (!file_set.contains(ref_file) or !file_set.contains(def_file)) continue;

        buf.appendSlice(allocator, "## ") catch continue;
        buf.appendSlice(allocator, ref_file) catch continue;
        buf.appendSlice(allocator, " → ") catch continue;
        buf.appendSlice(allocator, def_file) catch continue;
        buf.appendSlice(allocator, "\n") catch continue;

        for (entry.value_ptr.items) |sym_name| {
            buf.appendSlice(allocator, "- ") catch continue;
            buf.appendSlice(allocator, sym_name) catch continue;
            buf.appendSlice(allocator, "\n") catch continue;
        }
        buf.appendSlice(allocator, "\n") catch continue;
    }

    return allocator.dupe(u8, buf.items) catch allocator.dupe(u8, "") catch "";
}

fn commonPrefixLen(a: []const u8, b: []const u8) usize {
    const min_len = @min(a.len, b.len);
    var i: usize = 0;
    while (i < min_len and a[i] == b[i]) : (i += 1) {}
    return i;
}

/// Free all memory associated with a subsystem slice.
fn freeSubsystems(allocator: std.mem.Allocator, subsystems: []Subsystem) void {
    for (subsystems) |*sub| {
        allocator.free(sub.id);
        allocator.free(sub.label);
        for (sub.files) |f| allocator.free(f);
        allocator.free(sub.files);
        allocator.free(sub.cross_file_context);
    }
    allocator.free(subsystems);
}

// ── SCIP-based cross-file relationship extraction ───────────────────────

const CrossFileResult = struct {
    text: []u8,
    pair_count: usize,
};

/// Walk the SCIP index to find cross-file symbol references.
/// Returns a human-readable text describing file pairs and their shared symbols,
/// suitable for embedding in the association prompt. Returns null on failure.
/// When `subsystems` is non-null, only pairs where the two files are in DIFFERENT
/// subsystems are included (cross-subsystem filtering for Phase 2).
fn buildCrossFileRelationships(allocator: std.mem.Allocator, cog_dir: []const u8, subsystems: ?[]const Subsystem) ?CrossFileResult {
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
    const CfRefPairKey = struct {
        referencing: []const u8,
        defining: []const u8,
    };
    const PairContext = struct {
        pub fn hash(_: @This(), key: CfRefPairKey) u64 {
            var h = std.hash.Wyhash.init(0);
            h.update(key.referencing);
            h.update("\x00");
            h.update(key.defining);
            return h.final();
        }
        pub fn eql(_: @This(), a: CfRefPairKey, b: CfRefPairKey) bool {
            return std.mem.eql(u8, a.referencing, b.referencing) and
                std.mem.eql(u8, a.defining, b.defining);
        }
    };

    var pair_symbols: std.HashMapUnmanaged(
        CfRefPairKey,
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

            const key = CfRefPairKey{
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

    // Build file→subsystem lookup for cross-subsystem filtering
    var file_to_subsystem: std.StringHashMapUnmanaged([]const u8) = .empty;
    defer file_to_subsystem.deinit(allocator);
    if (subsystems) |subs| {
        for (subs) |sub| {
            for (sub.files) |f| {
                file_to_subsystem.put(allocator, f, sub.id) catch continue;
            }
        }
    }

    // Step 3: Build text output — collect pairs sorted for deterministic output
    const CfPairKey = struct {
        referencing: []const u8,
        defining: []const u8,
    };
    const PairEntry = struct {
        key: CfPairKey,
        symbols: []const []const u8,
    };
    var entries: std.ArrayListUnmanaged(PairEntry) = .empty;
    defer entries.deinit(allocator);

    var pair_iter = pair_symbols.iterator();
    while (pair_iter.next()) |entry| {
        // When subsystems filter is active, skip pairs in the same subsystem
        if (subsystems != null) {
            const sub_a = file_to_subsystem.get(entry.key_ptr.referencing);
            const sub_b = file_to_subsystem.get(entry.key_ptr.defining);
            if (sub_a != null and sub_b != null and std.mem.eql(u8, sub_a.?, sub_b.?)) continue;
        }
        entries.append(allocator, .{
            .key = .{ .referencing = entry.key_ptr.referencing, .defining = entry.key_ptr.defining },
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
    // Round to nearest cent (10_000 microdollars = 1 cent)
    const rounded = (microdollars + 5_000) / 10_000;
    const dollars = rounded / 100;
    const cents = rounded % 100;
    return std.fmt.allocPrint(allocator, "{d}.{d:0>2}", .{ dollars, cents }) catch "?.??";
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

/// Collect files for bootstrap using settings.json code.index patterns as the
/// source of truth.  When patterns are defined, only SCIP-indexed files that
/// match a pattern are included — plus any pattern-matched files that aren't
/// in the SCIP index (e.g. "**/*.md").  When no patterns are defined, all
/// SCIP-indexed files are included (backwards-compatible default).
fn collectSourceFiles(allocator: std.mem.Allocator, cog_dir: []const u8) !std.ArrayListUnmanaged([]const u8) {
    var files: std.ArrayListUnmanaged([]const u8) = .empty;
    var seen: std.StringHashMapUnmanaged(void) = .empty;
    defer seen.deinit(allocator);

    const settings = settings_mod.Settings.load(allocator);
    defer if (settings) |s| s.deinit(allocator);

    const patterns = if (settings) |s| if (s.code) |c| c.index else null else null;

    if (patterns) |pats| {
        // Patterns defined — they are the source of truth.
        // 1. Collect SCIP paths but only keep those matching a pattern.
        var scip_paths: std.ArrayListUnmanaged([]const u8) = .empty;
        defer scip_paths.deinit(allocator);
        loadScipFiles(allocator, cog_dir, &scip_paths, &seen);

        for (scip_paths.items) |path| {
            var matched = false;
            for (pats) |pat| {
                if (code_intel.globMatch(pat, path)) {
                    matched = true;
                    break;
                }
            }
            if (matched) {
                files.append(allocator, path) catch {
                    allocator.free(path);
                    continue;
                };
            } else {
                // Remove from seen so pattern collection can re-add if needed
                _ = seen.fetchRemove(path);
                allocator.free(path);
            }
        }

        // 2. Collect additional pattern-matched files not in the SCIP index
        //    (e.g. **/*.md files that have no indexer).
        loadSettingsPatternFiles(allocator, pats, &files, &seen);
    } else {
        // No patterns — include all SCIP-indexed files (legacy behavior).
        loadScipFiles(allocator, cog_dir, &files, &seen);
    }

    // Sort alphabetically
    sortFiles(files.items);

    return files;
}

/// Extract only document paths from the SCIP index without fully decoding it.
/// This avoids allocating occurrences, symbols, and relationships — just scans
/// the protobuf for document relative_path fields (field 2 → sub-field 1).
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
    defer allocator.free(data);

    // Scan top-level Index message for field 2 (documents)
    var dec = protobuf.Decoder.init(data);
    while (dec.hasMore()) {
        const field = dec.readField() catch return;
        if (field.number == 2) {
            // Document — scan for field 1 (relative_path) without decoding the rest
            const doc_data = dec.readLengthDelimited() catch return;
            const path = extractDocumentPath(doc_data) orelse continue;
            if (path.len > 0 and !seen.contains(path)) {
                const duped = allocator.dupe(u8, path) catch continue;
                files.append(allocator, duped) catch {
                    allocator.free(duped);
                    continue;
                };
                seen.put(allocator, duped, {}) catch {};
            }
        } else {
            dec.skipField(field.wire_type) catch return;
        }
    }
}

/// Extract just the relative_path (field 1) from a SCIP Document message.
fn extractDocumentPath(data: []const u8) ?[]const u8 {
    var dec = protobuf.Decoder.init(data);
    while (dec.hasMore()) {
        const field = dec.readField() catch return null;
        if (field.number == 1 and field.wire_type == .LEN) {
            return dec.readString() catch null;
        }
        dec.skipField(field.wire_type) catch return null;
    }
    return null;
}

/// Collect files matching patterns that aren't already in the file list.
fn loadSettingsPatternFiles(
    allocator: std.mem.Allocator,
    patterns: []const []const u8,
    files: *std.ArrayListUnmanaged([]const u8),
    seen: *std.StringHashMapUnmanaged(void),
) void {
    for (patterns) |pattern| {
        var pattern_files: std.ArrayListUnmanaged([]const u8) = .empty;
        defer pattern_files.deinit(allocator);

        code_intel.collectGlobFiles(allocator, pattern, &pattern_files) catch continue;

        for (pattern_files.items) |path| {
            if (!seen.contains(path)) {
                files.append(allocator, path) catch {
                    allocator.free(path);
                    continue;
                };
                seen.put(allocator, path, {}) catch {};
            } else {
                allocator.free(path);
            }
        }
    }
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

    // Check version — v1 is discarded (extraction model changed to subsystems)
    const version_val = obj.get("version") orelse return map;
    const version: i64 = switch (version_val) {
        .integer => version_val.integer,
        else => return map,
    };

    if (version == 1) {
        // v1 checkpoint from per-file model — discard
        debug_log.log("loadCheckpoint: discarding v1 checkpoint (per-file model)", .{});
        return map;
    }

    if (version != 2) return map;

    // v2: parse processed_subsystems array of objects with "id" field
    const subsystems_val = obj.get("processed_subsystems") orelse return map;
    if (subsystems_val != .array) return map;

    for (subsystems_val.array.items) |item| {
        if (item != .object) continue;
        const id_val = item.object.get("id") orelse continue;
        if (id_val != .string) continue;
        const duped = allocator.dupe(u8, id_val.string) catch continue;
        map.put(allocator, duped, {}) catch {
            allocator.free(duped);
        };
    }

    debug_log.log("loadCheckpoint: loaded v2 checkpoint with {d} subsystems", .{map.count()});
    return map;
}

fn saveCheckpoint(allocator: std.mem.Allocator, checkpoint_path: []const u8, processed: *std.StringHashMapUnmanaged(void), all_subsystems: []const Subsystem) void {
    // Build JSON manually in v2 format
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(allocator);

    buf.appendSlice(allocator, "{\n  \"version\": 2,\n  \"processed_subsystems\": [\n") catch return;

    // Collect processed subsystem IDs, sorted for determinism
    var ids: std.ArrayListUnmanaged([]const u8) = .empty;
    defer ids.deinit(allocator);

    var it = processed.keyIterator();
    while (it.next()) |key| {
        ids.append(allocator, key.*) catch continue;
    }
    sortFiles(ids.items);

    for (ids.items, 0..) |id, i| {
        buf.appendSlice(allocator, "    {\"id\": \"") catch return;
        appendJsonEscaped(&buf, allocator, id);
        buf.appendSlice(allocator, "\", \"files\": [") catch return;

        // Find the subsystem with this ID to include its files
        var found_subsystem: ?*const Subsystem = null;
        for (all_subsystems) |*sub| {
            if (std.mem.eql(u8, sub.id, id)) {
                found_subsystem = sub;
                break;
            }
        }

        if (found_subsystem) |sub| {
            for (sub.files, 0..) |file_path, fi| {
                buf.appendSlice(allocator, "\"") catch return;
                appendJsonEscaped(&buf, allocator, file_path);
                buf.appendSlice(allocator, "\"") catch return;
                if (fi + 1 < sub.files.len) {
                    buf.appendSlice(allocator, ", ") catch return;
                }
            }
        }

        buf.appendSlice(allocator, "]}") catch return;
        if (i + 1 < ids.items.len) {
            buf.append(allocator, ',') catch return;
        }
        buf.append(allocator, '\n') catch return;
    }

    buf.appendSlice(allocator, "  ]\n}\n") catch return;

    const file = std.fs.createFileAbsolute(checkpoint_path, .{}) catch return;
    defer file.close();
    file.writeAll(buf.items) catch {};
}

fn appendJsonEscaped(buf: *std.ArrayListUnmanaged(u8), allocator: std.mem.Allocator, s: []const u8) void {
    for (s) |c| {
        switch (c) {
            '"' => buf.appendSlice(allocator, "\\\"") catch return,
            '\\' => buf.appendSlice(allocator, "\\\\") catch return,
            '\n' => buf.appendSlice(allocator, "\\n") catch return,
            else => buf.append(allocator, c) catch return,
        }
    }
}

fn loadCustomPrompt(allocator: std.mem.Allocator, cog_dir: []const u8, filename: []const u8) ?[]const u8 {
    const path = std.fmt.allocPrint(allocator, "{s}/{s}", .{ cog_dir, filename }) catch return null;
    defer allocator.free(path);

    const file = std.fs.openFileAbsolute(path, .{}) catch return null;
    defer file.close();

    const content = file.readToEndAlloc(allocator, 1024 * 1024) catch return null;
    if (content.len == 0) {
        allocator.free(content);
        return null;
    }
    return content;
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
    try std.testing.expectEqual(@as(usize, 7), cli_agents.len);
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

test "buildSubsystemClusters basic" {
    // buildSubsystemClusters returns null when SCIP index doesn't exist,
    // so verify graceful failure with a nonexistent directory.
    const allocator = std.testing.allocator;
    const result = buildSubsystemClusters(allocator, &.{ "src/a.zig", "src/b.zig", "lib/c.zig" }, "/tmp/nonexistent-cog-dir");
    try std.testing.expectEqual(@as(?[]Subsystem, null), result);
}

test "buildSubsystemClusters grouping" {
    // Test the directory grouping helper directly via subsystem ID determinism
    const allocator = std.testing.allocator;

    // With no valid SCIP dir, clusters won't form — this tests the null path
    const result = buildSubsystemClusters(allocator, &.{ "src/a.zig", "src/b.zig", "src/c.zig", "lib/d.zig" }, "/tmp/no-such-dir");
    try std.testing.expectEqual(@as(?[]Subsystem, null), result);
}

test "loadCheckpoint v2 format" {
    const allocator = std.testing.allocator;

    // Write a v2 checkpoint
    const path = "/tmp/test-bootstrap-checkpoint-v2.json";
    const content = "{\"version\": 2, \"processed_subsystems\": [{\"id\": \"abcdef1234567890\", \"files\": [\"src/a.zig\", \"src/b.zig\"]}]}";
    {
        const f = try std.fs.createFileAbsolute(path, .{});
        defer f.close();
        try f.writeAll(content);
    }
    defer std.fs.deleteFileAbsolute(path) catch {};

    var map = loadCheckpoint(allocator, path);
    defer {
        var it = map.keyIterator();
        while (it.next()) |key| allocator.free(key.*);
        map.deinit(allocator);
    }
    try std.testing.expectEqual(@as(u32, 1), map.count());
    try std.testing.expect(map.contains("abcdef1234567890"));
}

test "loadCheckpoint v1 format returns empty" {
    const allocator = std.testing.allocator;

    // Write a v1 checkpoint — should be discarded
    const path = "/tmp/test-bootstrap-checkpoint-v1.json";
    const content = "{\"version\": 1, \"processed_files\": [\"src/a.zig\"]}";
    {
        const f = try std.fs.createFileAbsolute(path, .{});
        defer f.close();
        try f.writeAll(content);
    }
    defer std.fs.deleteFileAbsolute(path) catch {};

    var map = loadCheckpoint(allocator, path);
    defer {
        var it = map.keyIterator();
        while (it.next()) |key| allocator.free(key.*);
        map.deinit(allocator);
    }
    // v1 is discarded — extraction model changed
    try std.testing.expectEqual(@as(u32, 0), map.count());
}
